#!/usr/bin/env python3
"""Link a pinned-mpy-cross ``.mpy`` into a flash image at ``0x0000_0000``.

The RTL fetches this image. It does not parse ``.mpy``. Bytecode qstr and
const operands stay indexes into the module tables. Static qstr ids at or
below ``QSTR_LAST_STATIC`` are the pin's ids. A bytecode-only file is
accepted at any sub-version, including 0. A non-none architecture, native
or viper raw code, and an integer literal outside signed 64-bit are link
errors.
"""

from __future__ import annotations

import argparse
import difflib
import os
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from mpy_catalog import VENDOR_ROOT, Catalog, verify_against_pin
from mpy_file import FMT_OFFSET, FMT_QSTR, MpyError, MpyModule, RawCode, decode_opcode, disassemble, read_mpy
from mpy_prelude import decode_prelude, decode_signature, decode_size, encode_signature, encode_size


HEADER_BYTES = 48
RAW_WORDS = 20
MODULE_WORDS = 8


def qstr_hash(data: bytes) -> int:
    """djb2 masked to the extra-features hash width (2 bytes). Zero becomes 1."""

    value = 5381
    for byte in data:
        value = ((value * 33) ^ byte) & 0xFFFFFFFFFFFFFFFF
    value &= 0xFFFF
    return value or 1


def _u32(value: int) -> bytes:
    return struct.pack("<I", value & 0xFFFFFFFF)


class QstrPool:
    def __init__(self, catalog: Catalog) -> None:
        self.catalog = catalog
        self.dynamic: list[str] = []
        self._dynamic_ids: dict[str, int] = {}

    def intern(self, text: str) -> int:
        static = self.catalog.find_static_id(text)
        if static is not None:
            return static
        existing = self._dynamic_ids.get(text)
        if existing is not None:
            return existing
        qstr_id = self.catalog.qstr_last_static + 1 + len(self.dynamic)
        self.dynamic.append(text)
        self._dynamic_ids[text] = qstr_id
        return qstr_id

    def text(self, qstr_id: int) -> str:
        if qstr_id == 0:
            return ""
        if qstr_id <= self.catalog.qstr_last_static:
            return self.catalog.static_qstr(qstr_id)
        return self.dynamic[qstr_id - self.catalog.qstr_last_static - 1]

    @property
    def count(self) -> int:
        return self.catalog.qstr_last_static + 1 + len(self.dynamic)


@dataclass
class ObjRec:
    kind: str
    addr: int = 0
    data_off: int = 0
    length: int = 0
    hash: int = 0
    slots: tuple[int, ...] = ()
    raw: bytes = b""


@dataclass
class ImageParts:
    catalog: Catalog
    buf: bytearray = field(default_factory=bytearray)
    objects: list[ObjRec] = field(default_factory=list)
    slots: list[tuple[int, object]] = field(default_factory=list)
    qstr_desc_off: int = 0
    module_dir_off: int = 0
    tagged_base: int = 0
    tag_nibble_off: int = 0
    module_count: int = 0
    qstr_count: int = 0
    qstr_last_static: int = 0

    def align(self) -> None:
        while len(self.buf) % 4:
            self.buf.append(0)

    def add(self, data: bytes) -> int:
        offset = len(self.buf)
        self.buf.extend(data)
        return offset

    def add_slot(self, tag: int, payload: object) -> int:
        self.slots.append((tag, payload))
        return len(self.slots) - 1


def _check_state(raw: RawCode, catalog: Catalog) -> None:
    assert raw.prelude is not None
    limit = catalog.register_file_entries
    if raw.prelude.n_state > limit:
        raise MpyError(f"n_state {raw.prelude.n_state} does not fit in {limit} registers")
    for child in raw.children:
        _check_state(child, catalog)


def _int_slots(value: int, catalog: Catalog, tags: dict[str, int]) -> list[tuple[int, int]]:
    limit = 1 << (catalog.int_bits - 1)
    if value < -limit or value > limit - 1:
        raise MpyError(f"rejected integer literal {value} outside signed 64-bit")
    if -0x80000000 <= value <= 0x7FFFFFFF:
        return [(tags["INT"], value & 0xFFFFFFFF)]
    return [
        (tags["INT64"], value & 0xFFFFFFFF),
        (tags["CONT"], (value >> 32) & 0xFFFFFFFF),
    ]


def link_modules(modules: list[MpyModule], catalog: Catalog) -> bytes:
    """Link one or more modules. Phase 1 passes a single module."""

    if not modules:
        raise MpyError("no module to link")
    for module in modules:
        _check_state(module.raw, catalog)

    tags = catalog.tags
    control = catalog.control_kinds
    parts = ImageParts(catalog=catalog, buf=bytearray(HEADER_BYTES))
    pool = QstrPool(catalog)
    module_ids = [[pool.intern(text) for text in module.qstrs] for module in modules]

    str_keys: dict[str, int] = {}
    bytes_keys: dict[bytes, int] = {}
    empty_tuple: int | None = None
    ellipsis_key: int | None = None

    def encode(value: object) -> int:
        nonlocal empty_tuple, ellipsis_key
        if value is None:
            return parts.add_slot(tags["CONTROL"], control["none"])
        if value is False:
            return parts.add_slot(tags["CONTROL"], control["false"])
        if value is True:
            return parts.add_slot(tags["CONTROL"], control["true"])
        if value is Ellipsis:
            if ellipsis_key is None:
                ellipsis_key = len(parts.objects)
                parts.objects.append(ObjRec(kind="ellipsis"))
            return parts.add_slot(tags["OBJECT"], ("obj", ellipsis_key))
        if isinstance(value, int) and not isinstance(value, bool):
            encoded = _int_slots(value, catalog, tags)
            first = parts.add_slot(*encoded[0])
            for extra in encoded[1:]:
                parts.add_slot(*extra)
            return first
        if isinstance(value, str):
            if value == "":
                return parts.add_slot(tags["QSTR"], pool.intern(""))
            key = str_keys.get(value)
            if key is None:
                raw = value.encode("utf-8")
                key = len(parts.objects)
                str_keys[value] = key
                parts.objects.append(ObjRec(kind="str", length=len(raw), hash=qstr_hash(raw), raw=raw))
            return parts.add_slot(tags["STR"], ("obj", key))
        if isinstance(value, bytes):
            key = bytes_keys.get(value)
            if key is None:
                key = len(parts.objects)
                bytes_keys[value] = key
                parts.objects.append(ObjRec(kind="bytes", length=len(value), raw=value))
            return parts.add_slot(tags["BYTES"], ("obj", key))
        if isinstance(value, tuple):
            indexes = tuple(encode(item) for item in value)
            if not indexes:
                if empty_tuple is None:
                    empty_tuple = len(parts.objects)
                    parts.objects.append(ObjRec(kind="tuple", length=0, slots=()))
                key = empty_tuple
            else:
                key = len(parts.objects)
                parts.objects.append(ObjRec(kind="tuple", length=len(indexes), slots=indexes))
            return parts.add_slot(tags["TUPLE"], ("obj", key))
        raise MpyError(f"rejected const kind {type(value).__name__}")

    obj_slots = [[encode(obj) for obj in module.objs] for module in modules]

    # Byte payloads first: qstrs, then const str/bytes. No tag nibbles on them.
    qstr_data_off = [0] * pool.count
    qstr_len = [0] * pool.count
    qstr_hashed = [0] * pool.count
    for qstr_id in range(1, pool.count):
        raw = pool.text(qstr_id).encode("utf-8")
        qstr_len[qstr_id] = len(raw)
        qstr_hashed[qstr_id] = qstr_hash(raw)
        qstr_data_off[qstr_id] = parts.add(raw + b"\0")
    for obj in parts.objects:
        if obj.kind in ("str", "bytes"):
            obj.data_off = parts.add(obj.raw + b"\0")

    parts.align()
    parts.qstr_desc_off = len(parts.buf)
    for qstr_id in range(pool.count):
        parts.buf.extend(_u32(qstr_hashed[qstr_id]))
        parts.buf.extend(_u32(qstr_len[qstr_id]))
        parts.buf.extend(_u32(qstr_data_off[qstr_id]))

    parts.align()
    for obj in parts.objects:
        obj.addr = len(parts.buf)
        if obj.kind == "str":
            parts.buf.extend(_u32(obj.length))
            parts.buf.extend(_u32(obj.hash))
            parts.buf.extend(_u32(obj.data_off))
        elif obj.kind == "bytes":
            parts.buf.extend(_u32(obj.length))
            parts.buf.extend(_u32(obj.data_off))
        elif obj.kind == "tuple":
            parts.buf.extend(_u32(obj.length))
            for index in obj.slots:
                parts.buf.extend(_u32(index))
        elif obj.kind == "ellipsis":
            parts.buf.extend(_u32(catalog.object_kinds["ellipsis"]))
        else:
            raise MpyError(f"internal object {obj.kind}")
        if obj.addr in catalog.pointer_forbidden:
            raise MpyError(f"object landed on reserved address {obj.addr}")

    def place_raw(raw: RawCode, qstr_ids: list[int]) -> int:
        assert raw.prelude is not None
        child_offs = [place_raw(child, qstr_ids) for child in raw.children]
        parts.align()
        bytecode_off = parts.add(raw.fun_data)
        parts.align()
        if child_offs:
            children_off = parts.add(b"".join(_u32(off) for off in child_offs))
        else:
            children_off = 0
        prelude = raw.prelude
        words = [
            int(catalog.data["image"]["bytecode_kind"]),
            bytecode_off,
            len(raw.fun_data),
            bytecode_off + prelude.opcode_off,
            bytecode_off + prelude.line_info_off,
            prelude.line_info_len,
            prelude.n_state,
            prelude.n_exc_stack,
            prelude.scope_flags,
            prelude.n_pos_args,
            prelude.n_kwonly_args,
            prelude.n_def_pos_args,
            prelude.n_info,
            prelude.n_cell,
            qstr_ids[prelude.simple_name],
            len(raw.children),
            children_off,
            bytecode_off + prelude.line_info_end,
            prelude.opcode_off,
            0,
        ]
        if len(words) != RAW_WORDS:
            raise MpyError("raw-code descriptor width changed")
        parts.align()
        return parts.add(b"".join(_u32(word) for word in words))

    entries: list[bytes] = []
    for module, qstr_ids, slots in zip(modules, module_ids, obj_slots):
        parts.align()
        qstr_ids_off = parts.add(b"".join(_u32(qstr_id) for qstr_id in qstr_ids))
        parts.align()
        obj_slots_off = parts.add(b"".join(_u32(index) for index in slots)) if slots else 0
        raw_off = place_raw(module.raw, qstr_ids)
        entry = [
            qstr_ids[0],
            len(qstr_ids),
            qstr_ids_off,
            len(slots),
            obj_slots_off,
            raw_off,
            0,
            0,
        ]
        if len(entry) != MODULE_WORDS:
            raise MpyError("module entry width changed")
        entries.append(b"".join(_u32(word) for word in entry))

    parts.align()
    parts.module_dir_off = parts.add(b"".join(entries))
    parts.module_count = len(modules)

    parts.align()
    parts.tagged_base = len(parts.buf) if parts.slots else 0
    forbidden = catalog.pointer_forbidden
    pointer_tags = {tags["STR"], tags["TUPLE"], tags["BYTES"], tags["OBJECT"]}
    for tag, payload in parts.slots:
        if isinstance(payload, tuple):
            addr = parts.objects[payload[1]].addr
            if addr in forbidden or addr < catalog.reserved_prefix:
                raise MpyError(f"pointer payload {addr} collides with the reserved prefix")
            word = addr
        else:
            word = int(payload)
            if tag in pointer_tags and (word in forbidden or word < catalog.reserved_prefix):
                raise MpyError(f"pointer payload {word} collides with the reserved prefix")
        parts.buf.extend(_u32(word))
    if parts.slots:
        parts.tag_nibble_off = parts.add(_pack_nibbles([tag for tag, _ in parts.slots]))
    parts.align()

    image_size = len(parts.buf)
    words = [
        int.from_bytes(b"UPMI", "little"),
        int(catalog.data["image"]["version"]),
        image_size,
        catalog.qstr_last_static,
        pool.count,
        parts.qstr_desc_off,
        parts.module_count,
        parts.module_dir_off,
        parts.tagged_base,
        len(parts.slots),
        parts.tag_nibble_off,
        HEADER_BYTES,
    ]
    if len(words) * 4 != HEADER_BYTES:
        raise MpyError("image header width changed")
    for index, word in enumerate(words):
        struct.pack_into("<I", parts.buf, index * 4, word & 0xFFFFFFFF)
    parts.qstr_count = pool.count
    parts.qstr_last_static = catalog.qstr_last_static
    return bytes(parts.buf)


def _pack_nibbles(tags: list[int]) -> bytes:
    out = bytearray(((len(tags) + 7) // 8) * 4)
    for index, tag in enumerate(tags):
        word_index = index // 8
        shift = (index % 8) * 4
        base = word_index * 4
        value = int.from_bytes(out[base : base + 4], "little")
        value |= (tag & 0xF) << shift
        out[base : base + 4] = value.to_bytes(4, "little")
    return bytes(out)


def link_mpy(data: bytes, filename: str, catalog: Catalog | None = None) -> bytes:
    catalog = catalog or Catalog.load()
    return link_modules([read_mpy(data, filename, catalog)], catalog)


class ImageView:
    def __init__(self, data: bytes) -> None:
        self.data = data

    def u32(self, offset: int) -> int:
        return struct.unpack_from("<I", self.data, offset)[0]

    @property
    def magic(self) -> int:
        return self.u32(0)

    @property
    def version(self) -> int:
        return self.u32(4) & 0xFFFF

    @property
    def image_size(self) -> int:
        return self.u32(8)

    @property
    def qstr_last_static(self) -> int:
        return self.u32(12)

    @property
    def qstr_count(self) -> int:
        return self.u32(16)

    @property
    def qstr_desc_off(self) -> int:
        return self.u32(20)

    @property
    def module_count(self) -> int:
        return self.u32(24)

    @property
    def module_dir_off(self) -> int:
        return self.u32(28)

    @property
    def tagged_base(self) -> int:
        return self.u32(32)

    @property
    def tagged_count(self) -> int:
        return self.u32(36)

    @property
    def tag_nibble_off(self) -> int:
        return self.u32(40)

    @property
    def header_bytes(self) -> int:
        return self.u32(44)

    def qstr_desc(self, qstr_id: int) -> tuple[int, int, int]:
        base = self.qstr_desc_off + qstr_id * 12
        return self.u32(base), self.u32(base + 4), self.u32(base + 8)

    def module(self, index: int) -> tuple[int, int, int, int, int, int]:
        base = self.module_dir_off + index * MODULE_WORDS * 4
        return tuple(self.u32(base + word * 4) for word in range(6))  # type: ignore[return-value]

    def raw_words(self, offset: int) -> list[int]:
        return [self.u32(offset + word * 4) for word in range(RAW_WORDS)]

    def tag_at(self, index: int) -> int:
        word = self.u32(self.tag_nibble_off + (index // 8) * 4)
        return (word >> ((index % 8) * 4)) & 0xF

    def payload_at(self, index: int) -> int:
        return self.u32(self.tagged_base + index * 4)


def _walk_raw(raw: RawCode):
    yield raw
    for child in raw.children:
        yield from _walk_raw(child)


def _check_linked(image: bytes, module: MpyModule, catalog: Catalog) -> None:
    view = ImageView(image)
    if view.magic != int.from_bytes(b"UPMI", "little"):
        raise MpyError("image magic is not UPMI")
    if view.version != 1 or view.header_bytes != HEADER_BYTES:
        raise MpyError("image header version is wrong")
    if view.image_size != len(image):
        raise MpyError("image size does not match the buffer")
    if view.module_count != 1:
        raise MpyError("phase 1 image must have one module directory entry")
    if view.qstr_last_static != catalog.qstr_last_static:
        raise MpyError("image static-qstr limit does not match the catalog")
    if view.tagged_count and (view.tagged_base < catalog.reserved_prefix or view.tagged_base % 4):
        raise MpyError("tagged const pool overlaps the reserved prefix")
    for qstr_id in range(1, catalog.qstr_last_static + 1):
        _hash, length, data_off = view.qstr_desc(qstr_id)
        text = catalog.static_qstr(qstr_id).encode("utf-8")
        if image[data_off : data_off + length] != text or image[data_off + length] != 0:
            raise MpyError(f"static qstr {qstr_id} bytes do not match the snapshot")
        if _hash != qstr_hash(text):
            raise MpyError(f"static qstr {qstr_id} hash does not match djb2")

    name_qstr, n_qstr, qstr_ids_off, n_obj, obj_slots_off, raw_off = view.module(0)
    if n_qstr != len(module.qstrs) or n_obj != len(module.objs):
        raise MpyError("module table width does not match the .mpy")
    id_table = [view.u32(qstr_ids_off + index * 4) for index in range(n_qstr)]
    if name_qstr != id_table[0]:
        raise MpyError("module name qstr is not the source-file qstr")
    for index, text in enumerate(module.qstrs):
        static = catalog.find_static_id(text)
        if static is not None and id_table[index] != static:
            raise MpyError(f"static qstr {text!r} was not stored as its id")
        if static is None and id_table[index] <= catalog.qstr_last_static:
            raise MpyError(f"non-static qstr {text!r} reused a static id")
        _hash, length, data_off = view.qstr_desc(id_table[index])
        if image[data_off : data_off + length] != text.encode("utf-8"):
            raise MpyError(f"qstr id for {text!r} does not point at those bytes")

    slot_of = [view.u32(obj_slots_off + index * 4) for index in range(n_obj)] if n_obj else []
    tags = catalog.tags
    for index, obj in enumerate(module.objs):
        _expect_value(view, image, slot_of[index], obj, tags, catalog)

    def check_raw(raw: RawCode, offset: int) -> None:
        assert raw.prelude is not None
        words = view.raw_words(offset)
        bytecode_off, bytecode_len = words[1], words[2]
        if image[bytecode_off : bytecode_off + bytecode_len] != raw.fun_data:
            raise MpyError("bytecode in the image is not the .mpy bytes")
        if words[3] != bytecode_off + raw.prelude.opcode_off:
            raise MpyError("opcode-start offset does not match the prelude decoder")
        if words[4] != bytecode_off + raw.prelude.line_info_off or words[5] != raw.prelude.line_info_len:
            raise MpyError("line-info span does not match the prelude decoder")
        if words[17] != bytecode_off + raw.prelude.line_info_end:
            raise MpyError("closure start does not follow the line-info span")
        if words[18] != raw.prelude.opcode_off:
            raise MpyError("relative opcode start was not stored")
        # Re-decode the copied bytes. A short decoder would report a different opcode start.
        again = decode_prelude(image[bytecode_off : bytecode_off + bytecode_len])
        if again.opcode_off != raw.prelude.opcode_off or again.line_info_len != raw.prelude.line_info_len:
            raise MpyError("prelude decoder disagrees with itself on the image bytes")
        child_ids = []
        if raw.children:
            child_ids = [view.u32(words[16] + index * 4) for index in range(len(raw.children))]
        if len(child_ids) != words[15]:
            raise MpyError("child count does not match the raw-code descriptor")
        for child, child_off in zip(raw.children, child_ids):
            check_raw(child, child_off)

    check_raw(module.raw, raw_off)

    # Operands are still module-table indexes: a qstr operand fits the table,
    # and the bytecode bytes were not rewritten to global ids.
    for raw in _walk_raw(module.raw):
        assert raw.prelude is not None
        ip = raw.prelude.opcode_off
        while ip < len(raw.fun_data):
            op = decode_opcode(raw.fun_data, ip, catalog)
            if op.fmt == FMT_QSTR:
                assert op.arg is not None
                if op.arg >= n_qstr:
                    raise MpyError("qstr operand is not a module-table index")
            ip += op.size


def _expect_value(view: ImageView, image: bytes, slot: int, obj: object, tags: dict[str, int], catalog: Catalog) -> None:
    tag = view.tag_at(slot)
    payload = view.payload_at(slot)
    if obj is None:
        if tag != tags["CONTROL"] or payload != catalog.control_kinds["none"]:
            raise MpyError("None const is not CONTROL/none")
        return
    if obj is False:
        if tag != tags["CONTROL"] or payload != catalog.control_kinds["false"]:
            raise MpyError("False const is not CONTROL/false")
        return
    if obj is True:
        if tag != tags["CONTROL"] or payload != catalog.control_kinds["true"]:
            raise MpyError("True const is not CONTROL/true")
        return
    if obj is Ellipsis:
        if tag != tags["OBJECT"] or view.u32(payload) != catalog.object_kinds["ellipsis"]:
            raise MpyError("ellipsis const is not the ROM singleton")
        return
    if isinstance(obj, int) and not isinstance(obj, bool):
        if -0x80000000 <= obj <= 0x7FFFFFFF:
            decoded = payload if payload < 0x80000000 else payload - 0x100000000
            if tag != tags["INT"] or decoded != obj:
                raise MpyError(f"int const {obj} was not stored as INT")
            return
        hi_tag = view.tag_at(slot + 1)
        hi = view.payload_at(slot + 1)
        value = payload | (hi << 32)
        if value >= (1 << 63):
            value -= 1 << 64
        if tag != tags["INT64"] or hi_tag != tags["CONT"] or value != obj:
            raise MpyError(f"int const {obj} was not stored as INT64")
        return
    if isinstance(obj, str):
        if obj == "":
            if tag != tags["QSTR"] or payload != catalog.find_static_id(""):
                raise MpyError("empty str const is not the empty qstr")
            return
        if tag != tags["STR"]:
            raise MpyError("str const is not a STR pointer")
        length, _hash, data_off = view.u32(payload), view.u32(payload + 4), view.u32(payload + 8)
        if image[data_off : data_off + length].decode("utf-8") != obj:
            raise MpyError("str const bytes do not match")
        return
    if isinstance(obj, bytes):
        if tag != tags["BYTES"]:
            raise MpyError("bytes const is not a BYTES pointer")
        length, data_off = view.u32(payload), view.u32(payload + 4)
        if image[data_off : data_off + length] != obj:
            raise MpyError("bytes const bytes do not match")
        return
    if isinstance(obj, tuple):
        if tag != tags["TUPLE"]:
            raise MpyError("tuple const is not a TUPLE pointer")
        length = view.u32(payload)
        if length != len(obj):
            raise MpyError("tuple const length does not match")
        for index, item in enumerate(obj):
            _expect_value(view, image, view.u32(payload + 4 + index * 4), item, tags, catalog)
        return
    raise MpyError(f"unchecked const {obj!r}")


def _prelude_roundtrip() -> None:
    samples = [
        (1, 0, 0, 0, 0, 0, 1, 0),
        (3, 0, 0, 1, 0, 0, 5, 1),
        (8, 0, 0, 0, 0, 0, 40, 0),
        (200, 20, 0xF, 40, 10, 8, 1000, 30),
        (2, 3, 0x6, 0, 0, 0, 63, 0),
        (2, 3, 0x6, 0, 0, 0, 64, 2),
    ]
    for state, exc, flags, pos, kw, default, info, cells in samples:
        sig = encode_signature(state, exc, flags, pos, kw, default)
        size = encode_size(info, cells)
        got_state, got_exc, got_flags, got_pos, got_kw, got_def, sig_end = decode_signature(sig)
        if (got_state, got_exc, got_flags, got_pos, got_kw, got_def, sig_end) != (
            state,
            exc,
            flags,
            pos,
            kw,
            default,
            len(sig),
        ):
            raise MpyError("prelude signature round-trip failed")
        blob = sig + size + b"\x00" * (info + cells)
        got_info, got_cells, size_end = decode_size(blob, len(sig))
        if (got_info, got_cells, size_end) != (info, cells, len(sig) + len(size)):
            raise MpyError("prelude size round-trip failed")


def _fixture_features(module: MpyModule, catalog: Catalog) -> set[str]:
    found: set[str] = set()
    static = set(catalog.static_qstrs)
    if any(text in static for text in module.qstrs):
        found.add("static-qstr")
    if any(text not in static for text in module.qstrs):
        found.add("non-static-qstr")
    if any(isinstance(obj, tuple) for obj in module.objs):
        found.add("tuple")
    if module.raw.children:
        found.add("child")
    small_op = next(row.opcode for row in catalog.opcodes if row.name == "LOAD_CONST_SMALL_INT")
    window = catalog.data["bytecode"]["windows"]["small_int"]
    excess = int(window["excess"])
    count = int(window["count"])
    for raw in _walk_raw(module.raw):
        assert raw.prelude is not None
        ip = raw.prelude.opcode_off
        while ip < len(raw.fun_data):
            op = decode_opcode(raw.fun_data, ip, catalog)
            if op.opcode == small_op and op.arg is not None:
                if op.arg < -excess or op.arg >= count - excess:
                    found.add("small-int")
            if op.fmt == FMT_OFFSET:
                # One opcode byte plus one or two offset bytes. An extra byte
                # belongs to UNWIND_JUMP, which this scan still counts as a branch.
                offset_bytes = op.size - 1 - (1 if op.extra is not None else 0)
                if offset_bytes == 1:
                    found.add("jump-1")
                elif offset_bytes == 2:
                    found.add("jump-2")
                found.add("branch")
            ip += op.size
    return found


def _diff_disassembly(mpy_path: Path, catalog: Catalog) -> None:
    data = mpy_path.read_bytes()
    module = read_mpy(data, str(mpy_path), catalog)
    ours = disassemble(module, catalog)
    tool = VENDOR_ROOT / "tools" / "mpy-tool.py"
    proc = subprocess.run(
        [sys.executable, str(tool), "-xd", str(mpy_path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise MpyError(proc.stderr.strip() or "mpy-tool.py -xd failed")
    marker = "mpy_source_file:"
    start = proc.stdout.find(marker)
    if start < 0:
        raise MpyError("mpy-tool.py -xd produced no disassembly")
    theirs = proc.stdout[start:]
    if theirs != ours:
        diff = "".join(
            difflib.unified_diff(
                theirs.splitlines(keepends=True),
                ours.splitlines(keepends=True),
                fromfile="mpy-tool.py -xd",
                tofile="mpy_image.py",
            )
        )
        raise MpyError(f"disassembly mismatch for {mpy_path.name}\n{diff}")
    image = link_mpy(data, str(mpy_path), catalog)
    _check_linked(image, module, catalog)


def ensure_mpy_cross() -> Path:
    binary = Path("/tmp/upycore-mpy-cross/mpy-cross")
    if binary.is_file():
        return binary
    proc = subprocess.run(
        [
            "make",
            "-C",
            str(VENDOR_ROOT / "mpy-cross"),
            "BUILD=/tmp/upycore-mpy-cross",
            "-j",
            str(os.cpu_count() or 1),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        raise MpyError(detail or "mpy-cross build failed")
    if not binary.is_file():
        raise MpyError(f"mpy-cross was not built at {binary}")
    return binary


def compile_mpy(mpy_cross: Path, source: Path, dest: Path, march: str | None = None) -> None:
    command = [
        str(mpy_cross),
        "-msmall-int-bits=31",
        "-O0",
        "-s",
        source.name,
        "-o",
        str(dest),
    ]
    if march:
        command.append(f"-march={march}")
    command.append(str(source))
    proc = subprocess.run(command, check=False, capture_output=True, text=True)
    if proc.returncode != 0:
        raise MpyError(proc.stderr.strip() or f"mpy-cross failed on {source.name}")


def _directives(text: str) -> dict[str, str]:
    found: dict[str, str] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("# expect:"):
            found["expect"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("# march:"):
            found["march"] = stripped.split(":", 1)[1].strip()
    return found


def _compile_checked(mpy_cross: Path, source: Path, march: str | None) -> bytes:
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / (source.stem + ".mpy")
        compile_mpy(mpy_cross, source, dest, march)
        fresh = dest.read_bytes()
    committed = source.with_suffix(".mpy")
    if committed.is_file() and committed.read_bytes() != fresh:
        raise MpyError(
            f"{committed.name} was not produced by mpy-cross -msmall-int-bits=31 -O0"
            + (f" -march={march}" if march else "")
            + f" -s {source.name}"
        )
    if not committed.is_file():
        committed.write_bytes(fresh)
    return fresh


def _expect_link_error(data: bytes, filename: str, catalog: Catalog, token: str) -> None:
    try:
        link_mpy(data, filename, catalog)
    except MpyError as exc:
        if token not in str(exc):
            raise MpyError(f"error {exc} does not contain {token!r}") from exc
        return
    raise MpyError(f"link succeeded but was expected to fail with {token!r}")


def check_directory(directory: Path) -> int:
    catalog = Catalog.load()
    verify_against_pin(catalog)
    _prelude_roundtrip()
    mpy_cross = ensure_mpy_cross()
    if not directory.is_dir():
        raise MpyError(f"not a directory: {directory}")

    required = {"branch", "static-qstr", "non-static-qstr", "small-int", "tuple", "child", "jump-1", "jump-2"}
    seen: set[str] = set()
    good = 0
    native_named = False
    for source in sorted(directory.glob("*.py")):
        meta = _directives(source.read_text(encoding="utf-8"))
        march = meta.get("march")
        expect = meta.get("expect")
        if source.name.startswith("native_"):
            march = march or source.stem.split("_", 1)[1]
            try:
                arch_token = catalog.architectures[catalog.architectures.index(march.upper())]
            except ValueError as exc:
                raise MpyError(f"{source.name} march {march} is not a pinned architecture") from exc
            data = _compile_checked(mpy_cross, source, march)
            try:
                link_mpy(data, str(source.with_suffix(".mpy")), catalog)
            except MpyError as exc:
                message = str(exc)
                if arch_token not in message:
                    raise MpyError(f"{source.name} error {message!r} does not name {arch_token}") from exc
                native_named = True
                continue
            raise MpyError(f"{source.name} linked despite architecture {arch_token}")
        data = _compile_checked(mpy_cross, source, march)
        mpy_path = source.with_suffix(".mpy")
        if expect:
            try:
                link_mpy(data, str(mpy_path), catalog)
            except MpyError as exc:
                if expect not in str(exc):
                    raise MpyError(f"{source.name} error {exc} does not contain {expect!r}") from exc
                continue
            raise MpyError(f"{source.name} linked but was expected to fail with {expect!r}")
        _diff_disassembly(mpy_path, catalog)
        module = read_mpy(data, str(mpy_path), catalog)
        seen |= _fixture_features(module, catalog)
        # Sub-version 0 is what bytecode-only mpy-cross writes. Also accept 1 and 3.
        if module.sub_version != 0:
            raise MpyError(f"{source.name} bytecode-only sub-version is {module.sub_version}, expected 0")
        for sub in (0, 1, 3):
            patched = bytearray(data)
            patched[2] = sub
            linked = link_mpy(bytes(patched), str(mpy_path), catalog)
            if not linked.startswith(b"UPMI"):
                raise MpyError("sub-version patch did not link")
        patched = bytearray(data)
        patched[2] = (2 << 2) | 0  # X64, sub-version 0
        try:
            link_mpy(bytes(patched), str(mpy_path), catalog)
        except MpyError as exc:
            if "X64" not in str(exc):
                raise MpyError(f"patched architecture error {exc} does not name X64") from exc
        else:
            raise MpyError("bytecode with an X64 architecture nibble was accepted")
        rejected = bytearray(data)
        rejected[1] = 5
        _expect_link_error(bytes(rejected), str(mpy_path), catalog, "major version")
        rejected = bytearray(data)
        rejected[2] = 0x40
        _expect_link_error(bytes(rejected), str(mpy_path), catalog, "architecture flags")
        rejected = bytearray(data)
        rejected[3] = catalog.small_int_bits + 1
        _expect_link_error(bytes(rejected), str(mpy_path), catalog, "small-int width")
        good += 1

    missing = required - seen
    if missing:
        raise MpyError(f"phase 1 fixtures are missing {', '.join(sorted(missing))}")
    if not native_named:
        raise MpyError("phase 1 fixtures have no native-arch rejection")
    if good < 1:
        raise MpyError("phase 1 fixtures have no bytecode file")
    print("mpy-image: ok")
    print("fixtures: " + " ".join(sorted(seen)))
    print("sub-version: accepted 0")
    print("native-arch: rejected")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="*", help=".mpy files to link")
    parser.add_argument("-o", "--output", help="write the linked image to this path")
    parser.add_argument("--disassemble", action="store_true", help="print .mpy disassembly")
    parser.add_argument("--check", metavar="DIR", help="check a phase fixture directory")
    args = parser.parse_args(argv)
    try:
        if args.check:
            return check_directory(Path(args.check))
        if not args.inputs:
            parser.error("pass a .mpy file or --check DIR")
        catalog = Catalog.load()
        if len(args.inputs) != 1 and args.output:
            parser.error("-o writes one image")
        for item in args.inputs:
            path = Path(item)
            data = path.read_bytes()
            if args.disassemble:
                sys.stdout.write(disassemble(read_mpy(data, str(path), catalog), catalog))
                continue
            image = link_mpy(data, str(path), catalog)
            dest = Path(args.output) if args.output else path.with_suffix(".img")
            dest.write_bytes(image)
            print(f"linked {dest} ({len(image)} bytes)")
        return 0
    except MpyError as exc:
        print(exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
