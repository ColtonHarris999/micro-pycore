#!/usr/bin/env python3
"""Read a v6 ``.mpy`` container. Bytecode operands stay module-table indexes."""

from __future__ import annotations

from binascii import hexlify
from dataclasses import dataclass, field

from mpy_catalog import Catalog
from mpy_prelude import Prelude, decode_prelude


FMT_BYTE = 0
FMT_QSTR = 1
FMT_VARUINT = 2
FMT_OFFSET = 3

# emitglue.h. The .mpy length word stores ``kind - MP_CODE_BYTECODE`` in its low bits.
CODE_BYTECODE = 2
CODE_NATIVE = 3
CODE_VIPER = 4
CODE_ASM = 5

KIND_NAME = {
    CODE_BYTECODE: "bytecode",
    CODE_NATIVE: "native",
    CODE_VIPER: "viper",
    CODE_ASM: "asm",
}


class MpyError(Exception):
    """A ``.mpy`` file cannot be linked into a flash image."""


class FunTable:
    def __repr__(self) -> str:
        return "mp_fun_table"


@dataclass
class DecodedOp:
    offset: int
    opcode: int
    fmt: int
    size: int
    arg: int | None
    extra: int | None


@dataclass
class RawCode:
    kind: int
    fun_data: bytes
    prelude: Prelude | None
    children: list[RawCode] = field(default_factory=list)

    @property
    def kind_name(self) -> str:
        return KIND_NAME.get(self.kind, str(self.kind))


@dataclass
class MpyModule:
    filename: str
    header: bytes
    arch: int
    arch_name: str
    sub_version: int
    small_int_bits: int
    qstrs: list[str]
    objs: list[object]
    raw: RawCode


class Reader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.pos = 0

    def read_byte(self) -> int:
        if self.pos >= len(self.data):
            raise MpyError("truncated .mpy file")
        value = self.data[self.pos]
        self.pos += 1
        return value

    def read_bytes(self, count: int) -> bytes:
        end = self.pos + count
        if count < 0 or end > len(self.data):
            raise MpyError("truncated .mpy file")
        chunk = self.data[self.pos : end]
        self.pos = end
        return chunk

    def read_uint(self) -> int:
        value = 0
        while True:
            byte = self.read_byte()
            value = (value << 7) | (byte & 0x7F)
            if not (byte & 0x80):
                return value


def hexlify_to_str(blob: bytes) -> str:
    return str(hexlify(blob, ":"), "ascii")


def _int_fits(catalog: Catalog, value: int) -> bool:
    limit = 1 << (catalog.int_bits - 1)
    return -limit <= value <= limit - 1


def read_qstr(reader: Reader, catalog: Catalog) -> str:
    length = reader.read_uint()
    if length & 1:
        return catalog.static_qstr(length >> 1)
    length >>= 1
    text = str(reader.read_bytes(length), "utf-8")
    reader.read_byte()
    return text


def read_obj(reader: Reader, catalog: Catalog) -> object:
    kind = reader.read_byte()
    kinds = catalog.const_kinds
    if kind == kinds["fun_table"]["id"]:
        return FunTable()
    if kind == kinds["none"]["id"]:
        return None
    if kind == kinds["false"]["id"]:
        return False
    if kind == kinds["true"]["id"]:
        return True
    if kind == kinds["ellipsis"]["id"]:
        return Ellipsis
    if kind == kinds["tuple"]["id"]:
        count = reader.read_uint()
        return tuple(read_obj(reader, catalog) for _ in range(count))

    length = reader.read_uint()
    if length == 0 and kind == kinds["bytes"]["id"]:
        reader.read_byte()
        return b""
    payload = reader.read_bytes(length)
    if kind in (kinds["str"]["id"], kinds["bytes"]["id"]):
        reader.read_byte()
        if kind == kinds["str"]["id"]:
            return str(payload, "utf-8")
        return payload
    if kind == kinds["int"]["id"]:
        value = int(str(payload, "ascii"), 10)
        if not _int_fits(catalog, value):
            raise MpyError(f"rejected integer literal {value} outside signed 64-bit")
        return value
    if kind == kinds["float"]["id"]:
        raise MpyError("rejected const kind float")
    if kind == kinds["complex"]["id"]:
        raise MpyError("rejected const kind complex")
    raise MpyError(f"rejected const kind {kind}")


def read_raw_code(reader: Reader, catalog: Catalog, arch: int, arch_name: str) -> RawCode:
    kind_len = reader.read_uint()
    kind = (kind_len & 3) + CODE_BYTECODE
    has_children = bool(kind_len & 4)
    fun_len = kind_len >> 3
    fun_data = reader.read_bytes(fun_len)
    if kind != CODE_BYTECODE:
        kind_name = KIND_NAME.get(kind, str(kind))
        if arch != 0:
            raise MpyError(f"rejected architecture {arch_name} raw code {kind_name}")
        raise MpyError(f"rejected raw code {kind_name}")
    try:
        prelude = decode_prelude(fun_data)
    except ValueError as exc:
        raise MpyError(f"bad prelude: {exc}") from exc
    children: list[RawCode] = []
    if has_children:
        count = reader.read_uint()
        for _ in range(count):
            children.append(read_raw_code(reader, catalog, arch, arch_name))
    return RawCode(kind=kind, fun_data=fun_data, prelude=prelude, children=children)


def read_mpy(data: bytes, filename: str, catalog: Catalog) -> MpyModule:
    """Parse one bytecode ``.mpy``. A non-none architecture is a link error."""

    reader = Reader(data)
    header = reader.read_bytes(4)
    if header[0] != ord("M"):
        raise MpyError("not a valid .mpy file")
    if header[1] != catalog.mpy_version:
        raise MpyError(f"rejected major version {header[1]}")
    feature = catalog.feature
    arch = (header[2] >> int(feature["arch_shift"])) & int(feature["arch_mask"])
    sub_version = header[2] & int(feature["sub_version_mask"])
    arch_name = catalog.arch_name(arch)
    if header[3] > catalog.small_int_bits:
        raise MpyError(f"rejected small-int width {header[3]}")
    if header[2] & int(feature["flags_bit"]):
        flags = reader.read_uint()
        if arch != 0:
            raise MpyError(f"rejected architecture {arch_name} flags {flags}")
        raise MpyError("rejected architecture flags")
    qstr_count = reader.read_uint()
    obj_count = reader.read_uint()
    qstrs = [read_qstr(reader, catalog) for _ in range(qstr_count)]
    objs = [read_obj(reader, catalog) for _ in range(obj_count)]
    raw = read_raw_code(reader, catalog, arch, arch_name)
    if arch != 0:
        raise MpyError(f"rejected architecture {arch_name}")
    if reader.pos != len(data):
        raise MpyError("trailing bytes after raw code")
    return MpyModule(
        filename=filename,
        header=header,
        arch=arch,
        arch_name=arch_name,
        sub_version=sub_version,
        small_int_bits=header[3],
        qstrs=qstrs,
        objs=objs,
        raw=raw,
    )


def decode_opcode(bc: bytes, ip: int, catalog: Catalog) -> DecodedOp:
    if ip >= len(bc):
        raise MpyError("opcode starts past the bytecode")
    opcode = bc[ip]
    fmt = (catalog.format_magic >> (2 * (opcode >> 4))) & 3
    cursor = ip + 1
    arg: int | None = None
    extra: int | None = None
    small_int = _opcode_named(catalog, "LOAD_CONST_SMALL_INT")
    try:
        if fmt in (FMT_QSTR, FMT_VARUINT):
            arg = bc[cursor] & 0x7F
            if opcode == small_int and arg & 0x40:
                arg |= -1 << 7
            while bc[cursor] & 0x80:
                cursor += 1
                arg = (arg << 7) | (bc[cursor] & 0x7F)
            cursor += 1
        elif fmt == FMT_OFFSET:
            if bc[cursor] & 0x80 == 0:
                arg = bc[cursor]
                cursor += 1
                if opcode in catalog.signed_offsets:
                    arg -= 0x40
            else:
                arg = (bc[cursor] & 0x7F) | (bc[cursor + 1] << 7)
                cursor += 2
                if opcode in catalog.signed_offsets:
                    arg -= 0x4000
        if opcode & catalog.extra_byte_mask == 0:
            extra = bc[cursor]
            cursor += 1
    except IndexError as exc:
        raise MpyError("truncated opcode") from exc
    return DecodedOp(ip, opcode, fmt, cursor - ip, arg, extra)


def _qstr_text(module: MpyModule, index: int) -> str:
    if index < 0 or index >= len(module.qstrs):
        raise MpyError(f"qstr index {index} is outside the module table")
    return module.qstrs[index]


def _disassemble_raw(lines: list[str], module: MpyModule, raw: RawCode, catalog: Catalog) -> None:
    assert raw.prelude is not None
    bc = raw.fun_data
    prelude = raw.prelude
    lines.append(f"simple_name: {_qstr_text(module, prelude.simple_name)}")
    lines.append(f"  raw bytecode: {len(bc)} {hexlify_to_str(bc)}")
    signature = (
        prelude.n_state,
        prelude.n_exc_stack,
        prelude.scope_flags,
        prelude.n_pos_args,
        prelude.n_kwonly_args,
        prelude.n_def_pos_args,
    )
    lines.append(f"  prelude: {signature}")
    arg_names = [_qstr_text(module, index) for index in prelude.name_qstrs[1:]]
    lines.append(f"  args: {arg_names}")
    line_through_opcodes = bc[prelude.line_info_off : prelude.opcode_off]
    lines.append(f"  line info: {hexlify_to_str(line_through_opcodes)}")
    load_const_obj = _opcode_named(catalog, "LOAD_CONST_OBJ")
    ip = prelude.opcode_off
    while ip < len(bc):
        op = decode_opcode(bc, ip, catalog)
        if op.opcode == load_const_obj:
            assert op.arg is not None
            if op.arg < 0 or op.arg >= len(module.objs):
                raise MpyError(f"const index {op.arg} is outside the object table")
            arg_text: object = repr(module.objs[op.arg])
        elif op.fmt == FMT_QSTR:
            assert op.arg is not None
            arg_text = _qstr_text(module, op.arg)
        elif op.fmt in (FMT_VARUINT, FMT_OFFSET):
            arg_text = op.arg
        else:
            arg_text = ""
        pre = "  %-11s %s" % (hexlify_to_str(bc[ip : ip + op.size]), catalog.opcode_name(op.opcode))
        lines.append(f"{pre} {arg_text}")
        ip += op.size
    child_names = []
    for child in raw.children:
        assert child.prelude is not None
        child_names.append(_qstr_text(module, child.prelude.simple_name))
    rendered = "  children: ["
    for index, name in enumerate(child_names):
        if index:
            rendered += ", "
        rendered += name
    rendered += "]"
    lines.append(rendered)
    for child in raw.children:
        _disassemble_raw(lines, module, child, catalog)


def _opcode_named(catalog: Catalog, name: str) -> int:
    for row in catalog.opcodes:
        if row.name == name:
            return row.opcode
    raise MpyError(f"catalog is missing {name}")


def disassemble(module: MpyModule, catalog: Catalog) -> str:
    """Match ``tools/mpy-tool.py -d`` text, including the trailing spaces it prints."""

    lines = [
        f"mpy_source_file: {module.filename}",
        f"source_file: {module.qstrs[0]}",
        f"header: {hexlify_to_str(module.header)}",
        f"arch: {module.arch_name}",
        f"qstr_table[{len(module.qstrs)}]:",
    ]
    for qstr in module.qstrs:
        lines.append(f"    {qstr}")
    lines.append(f"obj_table: {module.objs}")
    _disassemble_raw(lines, module, module.raw, catalog)
    return "\n".join(lines) + "\n"
