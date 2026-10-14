#!/usr/bin/env python3
"""Link user and firmware ``.mpy`` files into a v2 flash image for mpy_core.

The image layout, every object layout, and every id the core hard-codes
come from ``mpy_abi.py``; pycore/docs/mpy_image.md describes the result.

Usage::

    mpy_link.py --main build/x/main.mpy --fw build/fw/fw.mpy -o build/x/image
    mpy_link.py --main main.mpy --module pkg=pkg/__init__.mpy:package \\
        --module pkg.sub=pkg/sub.mpy --fw fw.mpy -o image

Outputs ``<out>.hex`` (one flash word per line), ``<out>.tags.hex`` (eight
packed tag nibbles per line) and ``<out>.map.json`` (raw-code addresses and
names, for the trace mode and the firmware's own tests).
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import mpy_abi as abi  # noqa: E402
from mpy_catalog import Catalog  # noqa: E402
from mpy_file import (  # noqa: E402
    ComplexConst,
    FloatConst,
    MpyError,
    MpyModule,
    RawCode,
    decode_opcode,
    read_mpy,
)

FLASH_BYTES = 512 * 1024
T = abi.TAG
NULL = (T["CONTROL"], abi.CTL["NULL"])
NONE = (T["CONTROL"], abi.CTL["NONE"])
FALSE = (T["CONTROL"], abi.CTL["FALSE"])
TRUE = (T["CONTROL"], abi.CTL["TRUE"])

HASH_SIZES = [
    0, 2, 4, 6, 8, 10, 12, 17, 23, 29, 37, 47, 59, 73, 97, 127, 167, 223, 293,
    389, 521, 691, 919, 1223, 1627, 2161, 3229, 4831, 7243, 10861, 16273,
    24407, 36607, 54907,
]


class LinkError(Exception):
    pass


# ---------------------------------------------------------------------------
# binary32 helpers. The oracle's parser (py/parsenum.c, FORMAT_IMPL_APPROX)
# works in binary32; this reproduces it so a float const matches the oracle.

def f32(x: float) -> float:
    try:
        return struct.unpack("<f", struct.pack("<f", x))[0]
    except OverflowError:
        return math.copysign(math.inf, x)


def f32_bits(x: float) -> int:
    try:
        return struct.unpack("<I", struct.pack("<f", x))[0]
    except OverflowError:
        return 0x7F800000 | (0x80000000 if x < 0 else 0)


def bits_f32(b: int) -> float:
    return struct.unpack("<f", struct.pack("<I", b & 0xFFFFFFFF))[0]


def mp_decimal_exp(num: float, dec_exp: int) -> float:
    if dec_exp == 0 or num == 0.0:
        return num
    bits = f32_bits(num)
    bits = (bits & ~(0xFF << 23)) | ((((bits >> 23) & 0xFF) + dec_exp) & 0xFF) << 23
    res = bits_f32(bits)
    if -10 <= dec_exp < 0:
        return f32(res / f32(5.0 ** -dec_exp))
    try:
        p = f32(float(5 ** dec_exp)) if dec_exp >= 0 else f32(5.0 ** dec_exp)
    except OverflowError:
        p = math.inf
    return f32(res * p)


def mp_parse_float(text: str) -> float:
    s = text.strip().lower()
    neg = s.startswith("-")
    if s[:1] in "+-":
        s = s[1:]
    if s in ("inf", "infinity"):
        return -math.inf if neg else math.inf
    if s == "nan":
        return math.nan
    mantissa_max = 0x19999998
    mantissa = 0
    exp_val = 0
    exp_extra = 0
    tz_int = tz_frac = 0
    state = "int"
    exp_neg = False
    i = 0
    while i < len(s):
        c = s[i]
        i += 1
        if c.isdigit():
            d = ord(c) - 48
            if state == "exp":
                exp_val = 10 * exp_val + d
            elif d == 0 or mantissa >= mantissa_max:
                if state == "int":
                    tz_int += 1
                else:
                    tz_frac += 1
            else:
                def accept(m: int, dig: int, where: str) -> int:
                    nonlocal exp_extra
                    if m < mantissa_max:
                        if where == "frac":
                            exp_extra -= 1
                        return 10 * m + dig
                    if where == "int":
                        exp_extra += 1
                    return m
                while tz_int:
                    mantissa = accept(mantissa, 0, "int")
                    tz_int -= 1
                while tz_frac:
                    mantissa = accept(mantissa, 0, "frac")
                    tz_frac -= 1
                mantissa = accept(mantissa, d, state)
        elif state == "int" and c == ".":
            state = "frac"
        elif state != "exp" and c == "e":
            state = "exp"
            if i < len(s) and s[i] in "+-":
                exp_neg = s[i] == "-"
                i += 1
        else:
            break
    if exp_neg:
        exp_val = -exp_val
    exp_val += exp_extra + tz_int
    value = mp_decimal_exp(f32(float(mantissa)), exp_val)
    return -value if neg else value


# ---------------------------------------------------------------------------

@dataclass
class Fun:
    """A firmware function the module body made with MAKE_FUNCTION."""

    rc: RawCode
    defaults: object = None
    kwdefaults: object = None
    addr: int | None = None


@dataclass
class ModuleInfo:
    name: str
    mpy: MpyModule
    source_file: str
    firmware: bool = False
    package: bool = False
    md_addr: int = 0
    qstr_ids: list[int] = field(default_factory=list)
    rc_addr: dict[int, int] = field(default_factory=dict)


class Image:
    def __init__(self) -> None:
        self.words: list[int] = [0] * (abi.IMAGE_DATA_BASE // 4)
        self.tags: dict[int, int] = {}
        self.qstrs: list[str] = list(abi.core_qstr_order())
        self.qstr_id: dict[str, int] = {}
        for i, q in enumerate(self.qstrs):
            self.qstr_id.setdefault(q, i)
        self.rom_cache: dict[object, tuple[int, int]] = {}
        self.symbols: dict[str, int] = {}
        self.rc_names: dict[int, str] = {}

    # -- raw words ----------------------------------------------------------
    def here(self) -> int:
        return 4 * len(self.words)

    def alloc(self, nwords: int) -> int:
        addr = self.here()
        self.words.extend([0] * nwords)
        return addr

    def set(self, addr: int, value: tuple[int, int] | int) -> None:
        if isinstance(value, tuple):
            tag, pay = value
            self.words[addr // 4] = pay & 0xFFFFFFFF
            if tag:
                self.tags[addr // 4] = tag
            else:
                self.tags.pop(addr // 4, None)
        else:
            self.words[addr // 4] = value & 0xFFFFFFFF

    def emit_words(self, values: list) -> int:
        addr = self.alloc(len(values))
        for i, v in enumerate(values):
            self.set(addr + 4 * i, v)
        return addr

    def emit_bytes(self, data: bytes) -> int:
        addr = self.here()
        padded = data + b"\0" * (-len(data) % 4)
        for i in range(0, len(padded), 4):
            self.words.append(int.from_bytes(padded[i : i + 4], "little"))
        if not data:
            self.words.append(0)
        return addr

    # -- qstrs --------------------------------------------------------------
    def qstr(self, text: str) -> int:
        if text not in self.qstr_id:
            self.qstr_id[text] = len(self.qstrs)
            self.qstrs.append(text)
        return self.qstr_id[text]

    def qval(self, text: str) -> tuple[int, int]:
        return (T["QSTR"], self.qstr(text))


def type_val(img: Image, name: str) -> tuple[int, int]:
    return (T["OBJECT"], img.symbols[f"type:{name}"])


def mut(addr: int, kind: str) -> tuple[int, int]:
    return (T["MUT"], addr | abi.MUT[kind])


def key_hash(img: Image, key: tuple[int, int]) -> int:
    tag, pay = key
    if tag == T["QSTR"]:
        return abi.qstr_hash(img.qstrs[pay].encode())
    raise LinkError(f"ROM dict key tag {tag} is not hashable at link time")


def next_alloc(n: int) -> int:
    for size in HASH_SIZES:
        if size >= n:
            return size
    x = n
    return (x + x // 2) | 1


def emit_dict(img: Image, items: list[tuple[tuple[int, int], tuple[int, int]]], rom: bool = True) -> tuple[int, int]:
    """ROM dict with the pin's open-addressing layout (py/map.c)."""

    n = len(items)
    alloc = next_alloc(n + n // 2 + 1) if n else 0
    table = [NULL, NULL] * alloc
    used = 0
    for key, value in items:
        pos = key_hash(img, key) % alloc
        while table[2 * pos] != NULL:
            if table[2 * pos] == key:
                raise LinkError(f"duplicate ROM dict key {img.qstrs[key[1]] if key[0] == T['QSTR'] else key}")
            pos = (pos + 1) % alloc
        table[2 * pos] = key
        table[2 * pos + 1] = value
        used += 1
    taddr = img.emit_words(table) if alloc else 0
    hdr = img.emit_words([
        (T["INT"], used),
        (T["INT"], alloc),
        (T["CONT"], taddr) if alloc else NULL,
        (T["INT"], abi.DICT_FLAG_ROM if rom else 0),
    ])
    return mut(hdr, "DICT")


def emit_str(img: Image, text: str | bytes, tag: str = "STR") -> tuple[int, int]:
    data = text.encode() if isinstance(text, str) else text
    key = (tag, data)
    if key in img.rom_cache:
        return img.rom_cache[key]
    addr = img.alloc(abi.STR_HDR_WORDS)
    baddr = img.emit_bytes(data)
    img.set(addr, (T["INT"], len(data)))
    ascii_flag = 0 if all(b < 0x80 for b in data) else abi.STR_NONASCII
    img.set(addr + 4, (T["INT"], abi.qstr_hash(data) | ascii_flag))
    img.set(addr + 8, (T["CONT"], baddr))
    img.rom_cache[key] = (T[tag], addr)
    return img.rom_cache[key]


def emit_tuple(img: Image, items: list[tuple[int, int]]) -> tuple[int, int]:
    if not items and "empty_tuple" in img.symbols:
        return (T["TUPLE"], img.symbols["empty_tuple"])
    addr = img.emit_words([(T["INT"], len(items))] + list(items))
    return (T["TUPLE"], addr)


def emit_box(img: Image, tag: str, lo: int, hi: int) -> tuple[int, int]:
    addr = img.emit_words([lo, hi])
    return (T[tag], addr)


def encode_const(img: Image, value: object) -> tuple[int, int]:
    if value is None:
        return NONE
    if value is True:
        return TRUE
    if value is False:
        return FALSE
    if value is Ellipsis:
        return (T["OBJECT"], img.symbols["ellipsis"])
    if isinstance(value, int):
        if -(1 << 31) <= value < (1 << 31):
            return (T["INT"], value & 0xFFFFFFFF)
        if not -(1 << 63) <= value < (1 << 63):
            raise LinkError(f"integer const {value} outside signed 64-bit")
        u = value & ((1 << 64) - 1)
        return emit_box(img, "INT64", u & 0xFFFFFFFF, u >> 32)
    if isinstance(value, FloatConst):
        return (T["FLOAT"], f32_bits(mp_parse_float(value.text)))
    if isinstance(value, float):
        return (T["FLOAT"], f32_bits(value))
    if isinstance(value, ComplexConst):
        text = value.text.rstrip("j")
        im = mp_parse_float(text) if text else 0.0
        return emit_box(img, "COMPLEX", 0, f32_bits(im))
    if isinstance(value, complex):
        return emit_box(img, "COMPLEX", f32_bits(value.real), f32_bits(value.imag))
    if isinstance(value, str):
        return emit_str(img, value)
    if isinstance(value, bytes):
        return emit_str(img, value, "BYTES")
    if isinstance(value, tuple):
        return emit_tuple(img, [encode_const(img, v) for v in value])
    raise LinkError(f"cannot place const {value!r}")


# ---------------------------------------------------------------------------
# Modules and raw codes.

def _cells(rc: RawCode) -> list[int]:
    p = rc.prelude
    assert p is not None
    return list(rc.fun_data[p.closure_off : p.closure_off + p.n_cell])


def place_module(img: Image, mod: ModuleInfo, catalog: Catalog) -> None:
    mpy = mod.mpy
    mod.qstr_ids = [img.qstr(q) for q in mpy.qstrs]
    qaddr = img.emit_words(mod.qstr_ids)
    consts = [encode_const(img, obj) for obj in mpy.objs]
    caddr = img.emit_words(consts) if consts else 0
    md = img.alloc(abi.MD_WORDS)
    mod.md_addr = md
    src_q = img.qstr(mod.source_file)
    flags = (abi.MD_FLAG_FIRMWARE if mod.firmware else 0) | (abi.MD_FLAG_PACKAGE if mod.package else 0)
    package = mod.name if mod.package else mod.name.rpartition(".")[0]
    img.set(md + 4 * abi.MD["QSTRS"], qaddr)
    img.set(md + 4 * abi.MD["CONSTS"], caddr)
    img.set(md + 4 * abi.MD["NAME"], img.qstr(mod.name))
    img.set(md + 4 * abi.MD["SOURCE_FILE"], src_q)
    img.set(md + 4 * abi.MD["FLAGS"], flags)
    img.set(md + 4 * abi.MD["PACKAGE"], img.qstr(package))
    raw_addr = place_raw(img, mod, mpy.raw, catalog)
    img.set(md + 4 * abi.MD["RAW"], raw_addr)


def place_raw(img: Image, mod: ModuleInfo, rc: RawCode, catalog: Catalog) -> int:
    p = rc.prelude
    assert p is not None
    if p.n_state > 64:
        raise LinkError(f"{mod.source_file}: function needs {p.n_state} state slots; the core has 64")
    if p.n_exc_stack > abi.FRAME_EXC_ENTRIES:
        raise LinkError(f"{mod.source_file}: function nests {p.n_exc_stack} exception blocks; the frame holds {abi.FRAME_EXC_ENTRIES}")
    children = [place_raw(img, mod, child, catalog) for child in rc.children]
    for op in iter_ops(rc, catalog):
        if op.opcode in (0x67, 0x68):  # YIELD_VALUE, YIELD_FROM
            pass  # accepted; the core raises at the call of a generator function
    bc = img.emit_bytes(rc.fun_data)
    names = [mod.qstr_ids[i] for i in p.name_qstrs[1:]]
    naddr = img.emit_words(names) if names else 0
    cells = _cells(rc)
    celladdr = img.emit_words(cells) if cells else 0
    chaddr = img.emit_words(children) if children else 0
    flags = (abi.RC_FLAG_FIRMWARE if mod.firmware else 0) | (
        abi.RC_FLAG_GENERATOR if p.scope_flags & abi.SCOPE_GENERATOR else 0)
    addr = img.emit_words([
        bc + p.opcode_off,
        p.n_state | (p.n_exc_stack << 8) | (p.scope_flags << 16) | (flags << 24),
        p.n_pos_args | (p.n_kwonly_args << 8) | (p.n_def_pos_args << 16) | (p.n_cell << 24),
        naddr,
        celladdr,
        0,  # MODULE, patched below
        chaddr,
        mod.qstr_ids[p.simple_name],
        bc,
        bc + p.line_info_off,
        bc + p.line_info_end,
        img.qstr(mod.source_file),
    ])
    img.set(addr + 4 * abi.RC["MODULE"], mod.md_addr)
    mod.rc_addr[id(rc)] = addr
    img.rc_names[addr] = f"{mod.name}:{img.qstrs[mod.qstr_ids[p.simple_name]]}"
    return addr


def iter_ops(rc: RawCode, catalog: Catalog):
    p = rc.prelude
    assert p is not None
    ip = p.opcode_off
    while ip < len(rc.fun_data):
        op = decode_opcode(rc.fun_data, ip, catalog)
        yield op
        ip += op.size


# ---------------------------------------------------------------------------
# Firmware: run the module body symbolically. It may only define functions
# and constants; everything else is a link error.

class _Import:
    def __init__(self, name: str) -> None:
        self.name = name


def eval_firmware_body(mod: ModuleInfo, catalog: Catalog) -> dict[str, object]:
    mpy = mod.mpy
    names: dict[str, object] = {}
    stack: list[object] = []
    q = mpy.qstrs
    for op in iter_ops(mpy.raw, catalog):
        o = op.opcode
        if o == 0x50:
            stack.append(False)
        elif o == 0x51:
            stack.append(None)
        elif o == 0x52:
            stack.append(True)
        elif o == 0x53:
            stack.append(NULL)
        elif o == 0x22:
            stack.append(op.arg)
        elif 0x70 <= o < 0xB0:
            stack.append(o - 0x80)
        elif o == 0x10:
            stack.append(q[op.arg])
        elif o == 0x23:
            stack.append(mpy.objs[op.arg])
        elif o == 0x2A:
            n = op.arg
            items = stack[len(stack) - n:] if n else []
            del stack[len(stack) - n:]
            stack.append(tuple(items))
        elif o == 0x2C:
            stack.append({})
        elif o == 0x62:
            key = stack.pop()
            value = stack.pop()
            stack[-1][key] = value
        elif o == 0x32:
            stack.append(Fun(mpy.raw.children[op.arg]))
        elif o == 0x33:
            kw = stack.pop()
            pos = stack.pop()
            stack.append(Fun(mpy.raw.children[op.arg],
                             None if pos == NULL else pos,
                             None if kw == NULL else kw))
        elif o == 0x16:
            names[q[op.arg]] = stack.pop()
        elif o == 0x11:
            stack.append(names[q[op.arg]])
        elif o == 0x1B:
            stack.pop()
            stack.pop()
            stack.append(_Import(q[op.arg]))
        elif o == 0x1C:
            stack.append(_Import(q[op.arg]))
        elif o == 0x59:
            stack.pop()
        elif o == 0x63:
            break
        else:
            raise LinkError(f"firmware module body uses {catalog.opcode_name(o)}; only defs and constants are allowed")
    return {k: v for k, v in names.items() if not isinstance(v, _Import)}


# ---------------------------------------------------------------------------

def link(main: Path, modules: list[tuple[str, Path, bool]], fw: Path, out: Path,
         main_name: str = "__main__", pool_bytes: int = 0) -> dict:
    catalog = Catalog.load()
    img = Image()

    def load(path: Path, name: str, firmware: bool = False, package: bool = False) -> ModuleInfo:
        data = path.read_bytes()
        mpy = read_mpy(data, str(path), catalog, numeric=True)
        return ModuleInfo(name=name, mpy=mpy, source_file=mpy.qstrs[0], firmware=firmware, package=package)

    try:
        fw_mod = load(fw, "_fw", firmware=True)
        main_mod = load(main, main_name)
        user_mods = [load(p, name, package=pkg) for name, p, pkg in modules]
    except MpyError as exc:
        raise LinkError(str(exc)) from exc

    fw_names = eval_firmware_body(fw_mod, catalog)

    # Fixed singletons first so consts can refer to them.
    img.symbols["empty_tuple"] = img.emit_words([(T["INT"], 0)])
    for name in ("ellipsis", "notimpl"):
        img.symbols[name] = img.alloc(2)

    # Type objects: allocate now, fill once dicts exist.
    for tname in abi.TYPES:
        img.symbols[f"type:{tname}"] = img.alloc(abi.OBJ_WORDS["TYPE"])
        img.set(abi.TYPE_TABLE_BASE + 4 * abi.TYPE_ID[tname], img.symbols[f"type:{tname}"])
    img.set(img.symbols["ellipsis"], (T["INT"], abi.OB["ELLIPSIS"]))
    img.set(img.symbols["ellipsis"] + 4, type_val(img, "ellipsis"))
    img.set(img.symbols["notimpl"], (T["INT"], abi.OB["NOTIMPL"]))
    img.set(img.symbols["notimpl"] + 4, type_val(img, "NotImplementedType"))

    for q in abi.BINOP_NAMES:
        if q:
            img.qstr(q)
    for c in range(128):
        img.qstr(chr(c))

    # Modules: firmware first, then the user modules.
    place_module(img, fw_mod, catalog)
    place_module(img, main_mod, catalog)
    for m in user_mods:
        place_module(img, m, catalog)

    # Firmware globals. Functions become ROM FUNCTION objects; the globals
    # dict is allocated empty first so each function can point at it.
    fw_globals_hdr = img.alloc(abi.DICT_WORDS)
    fw_globals = mut(fw_globals_hdr, "DICT")
    fun_type = type_val(img, "function")

    def emit_value(v: object) -> tuple[int, int]:
        if isinstance(v, Fun):
            if v.addr is None:
                defaults = encode_const(img, v.defaults) if v.defaults is not None else NULL
                kwd = NULL
                if v.kwdefaults:
                    kwd = emit_dict(img, [(img.qval(k), emit_value(x)) for k, x in v.kwdefaults.items()])
                v.addr = img.emit_words([
                    (T["INT"], abi.OB["FUNCTION"]), fun_type,
                    (T["INT"], fw_mod.rc_addr[id(v.rc)]), NULL, defaults, kwd, fw_globals,
                ])
            return (T["OBJECT"], v.addr)
        if isinstance(v, tuple) and len(v) == 2 and v == NULL:
            return NULL
        return encode_const(img, v)

    builtin_type = type_val(img, "builtin_function")

    def emit_native(name: str, fallback: tuple[int, int] = NULL) -> tuple[int, int]:
        short = name.split(".")[-1]
        addr = img.emit_words([
            (T["INT"], abi.OB["BUILTIN"]), builtin_type,
            (T["INT"], abi.NATIVE_ID[name]), fallback, img.qval(short),
        ])
        return (T["OBJECT"], addr)

    fw_items: dict[str, tuple[int, int]] = {}
    type_methods: dict[str, dict[str, tuple[int, int]]] = {t: {} for t in abi.TYPES}
    module_attrs: dict[str, dict[str, tuple[int, int]]] = {}
    for name, v in fw_names.items():
        val = emit_value(v)
        fw_items[name] = val
        if name.startswith("mod_"):
            mname, _, attr = name[4:].partition("__")
            module_attrs.setdefault(mname, {})[attr] = val
            continue
        tname, sep, meth = name.partition("__")
        if sep and tname in type_methods and meth:
            type_methods[tname][meth] = val

    natives: dict[str, tuple[int, int]] = {}
    for nname in abi.NATIVES:
        fb = NULL
        short = nname.split(".")[-1]
        fb_name = "_" + nname.replace(".", "__") + "_fb" if "." in nname else "_" + short.lstrip("_") + "_fb"
        if fb_name in fw_items:
            fb = fw_items[fb_name]
        val = emit_native(nname, fb)
        natives[nname] = val
        if "." in nname and not nname.startswith("new."):
            tname, meth = nname.split(".", 1)
            type_methods[tname][meth] = val
        elif nname.startswith("_"):
            fw_items[nname] = val

    # Type objects.
    def mro_of(tname: str) -> list[str]:
        chain = [tname]
        while True:
            base = abi.EXC_BASES.get(chain[-1]) or abi.NATIVE_BASES.get(chain[-1])
            if not base or base == "object":
                break
            chain.append(base)
        return chain

    for tname in abi.TYPES:
        addr = img.symbols[f"type:{tname}"]
        methods = type_methods[tname]
        dict_val = emit_dict(img, [(img.qval(k), v) for k, v in methods.items()])
        base = abi.EXC_BASES.get(tname) or abi.NATIVE_BASES.get(tname)
        if tname == "object":
            bases = emit_tuple(img, [])
        else:
            bases = emit_tuple(img, [type_val(img, base or "object")])
        mro = emit_tuple(img, [type_val(img, t) for t in mro_of(tname)])
        flags = 0
        if tname in abi.EXC_BASES:
            flags |= abi.TF["INST"] | abi.TF["EXC"]
        make_new = NULL
        if f"new.{tname}" in natives:
            make_new = natives[f"new.{tname}"]
        elif f"{tname}____new__" in fw_items or "__new__" in methods:
            make_new = methods.get("__new__", fw_items.get(f"{tname}____new__", NULL))
        print_name = abi.TYPE_PRINT_NAME.get(tname, tname)
        img.set(addr, (T["INT"], abi.OB["TYPE"]))
        img.set(addr + 4, type_val(img, "type"))
        img.set(addr + 8, dict_val)
        img.set(addr + 12, bases)
        img.set(addr + 16, img.qval(print_name))
        img.set(addr + 20, mro)
        img.set(addr + 24, (T["INT"], abi.TYPE_ID[tname]))
        img.set(addr + 28, (T["INT"], flags))
        img.set(addr + 32, make_new)

    # Native modules defined by the firmware (mod_<name>__<attr>).
    mod_type = type_val(img, "module")
    native_mods = []
    for mname, attrs in module_attrs.items():
        g = emit_dict(img, [(img.qval("__name__"), img.qval(mname))] + [(img.qval(k), v) for k, v in attrs.items()])
        maddr = img.emit_words([(T["INT"], abi.OB["MODULE"]), mod_type, g, img.qval(mname)])
        native_mods.append((img.qval(mname), (T["OBJECT"], maddr)))
    fw_items["_NATIVE_MODULES"] = emit_dict(img, native_mods)

    # Frozen user modules.
    frozen = emit_dict(img, [(img.qval(m.name), (T["INT"], m.md_addr)) for m in user_mods])
    fw_items["_FROZEN"] = frozen

    # Builtins.
    builtins: list[tuple[tuple[int, int], tuple[int, int]]] = []
    for tname in abi.PUBLIC_TYPES:
        builtins.append((img.qval(tname), type_val(img, tname)))
    for nname in abi.NATIVES:
        if not nname.startswith("_") and "." not in nname:
            builtins.append((img.qval(nname), natives[nname]))
    seen = {img.qstrs[k[1]] for k, _ in builtins}
    for name, val in fw_items.items():
        if name.startswith("_") or "__" in name.strip("_") or name.startswith("mod_") or name in seen:
            continue
        if name.isupper():
            continue
        builtins.append((img.qval(name), val))
    if "__build_class__" in fw_items:
        builtins.append((img.qval("__build_class__"), fw_items["__build_class__"]))
    if "__import__" in fw_items:
        builtins.append((img.qval("__import__"), fw_items["__import__"]))
    builtins.append((img.qval("__name__"), img.qval("builtins")))
    builtins.append((img.qval("NotImplemented"), (T["OBJECT"], img.symbols["notimpl"])))
    builtins.append((img.qval("Ellipsis"), (T["OBJECT"], img.symbols["ellipsis"])))
    builtins_dict = emit_dict(img, builtins)
    fw_items["_BUILTINS"] = builtins_dict

    # Fill the firmware globals dict in place.
    fwd = emit_dict(img, [(img.qval(k), v) for k, v in fw_items.items()])
    for i in range(abi.DICT_WORDS):
        img.set(fw_globals_hdr + 4 * i, (img.tags.get((fwd[1] & ~3) // 4 + i, 0), img.words[(fwd[1] & ~3) // 4 + i]))

    hooks = []
    for h in abi.HOOKS:
        if h in fw_items:
            hooks.append(fw_items[h])
        else:
            hooks.append(NULL)
    hooks_addr = img.emit_words(hooks)
    if hooks[abi.HOOK_ID["_boot"]] == NULL:
        raise LinkError("firmware has no _boot")

    msgs = []
    for name, tname, text in abi.MSGS:
        msgs.append(emit_tuple(img, [img.qval(text)] if text is not None else []))
    msgs_addr = img.emit_words(msgs)

    chars_addr = img.emit_words([img.qstr(chr(c)) for c in range(128)])

    # Qstr pool last: every qstr is known now.
    descs = []
    for text in img.qstrs:
        data = text.encode()
        if len(data) > 0xFFFF:
            raise LinkError("qstr longer than 64 KB")
        baddr = img.emit_bytes(data)
        descs.append(abi.qstr_hash(data) | (len(data) << 16))
        descs.append(baddr | (0 if all(b < 0x80 for b in data) else abi.QDESC_NONASCII))
    desc_addr = img.emit_words(descs)

    hdr = abi.HDR
    img.set(4 * hdr["MAGIC"], abi.IMAGE_MAGIC)
    img.set(4 * hdr["VERSION"], abi.IMAGE_VERSION)
    img.set(4 * hdr["QSTR_COUNT"], len(img.qstrs))
    img.set(4 * hdr["QSTR_DESC"], desc_addr)
    img.set(4 * hdr["MAIN_MODULE"], main_mod.md_addr)
    img.set(4 * hdr["BUILTINS"], builtins_dict[1] & ~3)
    img.set(4 * hdr["FW_GLOBALS"], fw_globals_hdr)
    img.set(4 * hdr["FROZEN"], frozen[1] & ~3)
    img.set(4 * hdr["HOOKS"], hooks_addr)
    img.set(4 * hdr["MSGS"], msgs_addr)
    img.set(4 * hdr["CHARS"], chars_addr)
    img.set(4 * hdr["EMPTY_TUPLE"], img.symbols["empty_tuple"])
    img.set(4 * hdr["FW_MODULE"], fw_mod.md_addr)
    img.set(4 * hdr["POOL_BYTES"], pool_bytes)
    img.set(4 * hdr["IMAGE_BYTES"], img.here())

    if img.here() > FLASH_BYTES:
        raise LinkError(f"image is {img.here()} bytes; flash is {FLASH_BYTES}")

    out.parent.mkdir(parents=True, exist_ok=True)
    nwords = len(img.words)
    nwords += -nwords % 8
    words = img.words + [0] * (nwords - len(img.words))
    Path(f"{out}.hex").write_text("".join(f"{w:08x}\n" for w in words))
    tag_lines = []
    for base in range(0, nwords, 8):
        packed = 0
        for i in range(8):
            packed |= (img.tags.get(base + i, 0) & 0xF) << (4 * i)
        tag_lines.append(f"{packed:08x}\n")
    Path(f"{out}.tags.hex").write_text("".join(tag_lines))
    info = {
        "image_bytes": img.here(),
        "qstrs": len(img.qstrs),
        "rc": {f"{a:#x}": n for a, n in sorted(img.rc_names.items())},
        "main_md": main_mod.md_addr,
    }
    Path(f"{out}.map.json").write_text(json.dumps(info, indent=1) + "\n")
    return info


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--main", required=True, type=Path)
    parser.add_argument("--module", action="append", default=[],
                        help="NAME=PATH[:package] for a frozen module")
    parser.add_argument("--fw", required=True, type=Path)
    parser.add_argument("-o", "--out", required=True, type=Path)
    args = parser.parse_args(argv)
    modules = []
    for spec in args.module:
        name, _, rest = spec.partition("=")
        path, _, kind = rest.partition(":")
        modules.append((name, Path(path), kind == "package"))
    try:
        info = link(args.main, modules, args.fw, args.out)
    except LinkError as exc:
        print(f"mpy_link: {exc}", file=sys.stderr)
        return 1
    print(f"mpy_link: {info['image_bytes']} bytes, {info['qstrs']} qstrs -> {args.out}.hex")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
