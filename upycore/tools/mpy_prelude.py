#!/usr/bin/env python3
"""Bit-interleaved bytecode prelude from the pinned MicroPython ``py/bc.h``.

The signature and the source-info size are not three integers in front of
the opcodes. Each is a variable-length byte whose fields are interleaved.
Source-info bytes and one byte per closure cell follow. The first opcode
is the byte after those.
"""

from __future__ import annotations

from dataclasses import dataclass


# MP_BC_PRELUDE_SIG_DECODE / MP_BC_PRELUDE_SIZE_DECODE in py/bc.h.
# Scope flags that fit in the signature are the low four bits.
SCOPE_FLAG_ALL_SIG = 0x0F


@dataclass(frozen=True)
class Prelude:
    """Decoded prelude. Offsets are relative to the start of ``bytecode``."""

    n_state: int
    n_exc_stack: int
    scope_flags: int
    n_pos_args: int
    n_kwonly_args: int
    n_def_pos_args: int
    n_info: int
    n_cell: int
    # Module qstr-table indexes: simple name, then positional and kw-only names.
    name_qstrs: tuple[int, ...]
    source_info_off: int
    line_info_off: int
    line_info_end: int
    opcode_off: int

    @property
    def line_info_len(self) -> int:
        return self.line_info_end - self.line_info_off

    @property
    def closure_off(self) -> int:
        return self.line_info_end

    @property
    def simple_name(self) -> int:
        return self.name_qstrs[0]


class PreludeError(ValueError):
    """The prelude bytes do not match the layout in ``py/bc.h``."""


def _need(buf: bytes | bytearray | memoryview, index: int) -> int:
    if index < 0 or index >= len(buf):
        raise PreludeError("prelude extends past the bytecode")
    return buf[index]


def decode_signature(buf: bytes | bytearray | memoryview, offset: int = 0) -> tuple[int, int, int, int, int, int, int]:
    """Decode the bit-interleaved signature. Returns fields plus the next offset.

    Layout of the first byte, then each continuation byte (``py/bc.h``):

    - ``xSSSSEAA``
    - ``xFSSKAED`` repeated while the extension bit is set

    ``n_state`` is stored as ``n_state - 1`` and restored here.
    """

    z = _need(buf, offset)
    offset += 1
    # xSSSSEAA
    state = (z >> 3) & 0xF
    exc_stack = (z >> 2) & 0x1
    scope_flags = 0
    pos_args = z & 0x3
    kwonly = 0
    def_pos = 0
    step = 0
    while z & 0x80:
        z = _need(buf, offset)
        offset += 1
        # xFSSKAED
        state |= (z & 0x30) << (2 * step)
        exc_stack |= (z & 0x02) << step
        scope_flags |= ((z & 0x40) >> 6) << step
        pos_args |= (z & 0x4) << step
        kwonly |= ((z & 0x08) >> 3) << step
        def_pos |= (z & 0x1) << step
        step += 1
    return state + 1, exc_stack, scope_flags, pos_args, kwonly, def_pos, offset


def decode_size(buf: bytes | bytearray | memoryview, offset: int) -> tuple[int, int, int]:
    """Decode the bit-interleaved ``xIIIIIIC`` size. Returns ``n_info``, ``n_cell``, next offset."""

    info = 0
    cells = 0
    step = 0
    while True:
        z = _need(buf, offset)
        offset += 1
        cells |= (z & 1) << step
        info |= ((z & 0x7E) >> 1) << (6 * step)
        if not (z & 0x80):
            return info, cells, offset
        step += 1


def _read_varuint(buf: bytes | bytearray | memoryview, offset: int) -> tuple[int, int]:
    value = 0
    while True:
        byte = _need(buf, offset)
        offset += 1
        value = (value << 7) | (byte & 0x7F)
        if not (byte & 0x80):
            return value, offset


def decode_prelude(buf: bytes | bytearray | memoryview, offset: int = 0) -> Prelude:
    """Return the opcode-start offset and the line-info span for one raw code.

    ``line_info_off`` is the first source-line byte. ``line_info_end`` is the
    first closure-cell byte (or the first opcode when there are no cells).
    ``opcode_off`` is the first opcode. Name qstrs sit in the source-info
    section in front of the line-info span and are not opcodes.
    """

    state, exc_stack, scope_flags, pos_args, kwonly, def_pos, cursor = decode_signature(buf, offset)
    info, cells, cursor = decode_size(buf, cursor)
    source_info_off = cursor
    name_count = 1 + pos_args + kwonly
    names: list[int] = []
    for _ in range(name_count):
        qstr_index, cursor = _read_varuint(buf, cursor)
        names.append(qstr_index)
    line_info_off = cursor
    line_info_end = source_info_off + info
    opcode_off = line_info_end + cells
    if info < 0 or cells < 0 or line_info_off > line_info_end:
        raise PreludeError("source-info size does not cover the name qstrs")
    if opcode_off > len(buf):
        raise PreludeError("opcode start is past the bytecode")
    return Prelude(
        n_state=state,
        n_exc_stack=exc_stack,
        scope_flags=scope_flags,
        n_pos_args=pos_args,
        n_kwonly_args=kwonly,
        n_def_pos_args=def_pos,
        n_info=info,
        n_cell=cells,
        name_qstrs=tuple(names),
        source_info_off=source_info_off,
        line_info_off=line_info_off,
        line_info_end=line_info_end,
        opcode_off=opcode_off,
    )


def encode_signature(
    n_state: int,
    n_exc_stack: int,
    scope_flags: int,
    n_pos_args: int,
    n_kwonly_args: int,
    n_def_pos_args: int,
) -> bytes:
    """Inverse of :func:`decode_signature`, matching ``MP_BC_PRELUDE_SIG_ENCODE``."""

    if n_state < 1:
        raise PreludeError("n_state is stored as n_state - 1")
    state = n_state - 1
    exc_stack = n_exc_stack
    scope_flags &= SCOPE_FLAG_ALL_SIG
    pos_args = n_pos_args
    kwonly = n_kwonly_args
    def_pos = n_def_pos_args
    byte = ((state & 0xF) << 3) | ((exc_stack & 1) << 2) | (pos_args & 3)
    state >>= 4
    exc_stack >>= 1
    pos_args >>= 2
    out = bytearray()
    while state or exc_stack or scope_flags or pos_args or kwonly or def_pos:
        out.append(0x80 | byte)
        byte = (
            ((scope_flags & 1) << 6)
            | ((state & 3) << 4)
            | ((kwonly & 1) << 3)
            | ((pos_args & 1) << 2)
            | ((exc_stack & 1) << 1)
            | (def_pos & 1)
        )
        state >>= 2
        exc_stack >>= 1
        scope_flags >>= 1
        pos_args >>= 1
        kwonly >>= 1
        def_pos >>= 1
    out.append(byte)
    return bytes(out)


def encode_size(n_info: int, n_cell: int) -> bytes:
    """Inverse of :func:`decode_size`, matching ``MP_BC_PRELUDE_SIZE_ENCODE``."""

    info = n_info
    cells = n_cell
    out = bytearray()
    while True:
        byte = ((info & 0x3F) << 1) | (cells & 1)
        cells >>= 1
        info >>= 6
        if cells or info:
            byte |= 0x80
        out.append(byte)
        if not (cells or info):
            return bytes(out)
