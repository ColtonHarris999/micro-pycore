#!/usr/bin/env python3
"""Build decoder vectors and check them against mpy-tool.py -xd.

The five fixtures are compiled with mpy-cross v1.29.0. Each instruction's
printed operand is taken from `mpy-tool.py -xd`. The vector file is what
tb_mpy_decode.sv decodes.
"""

import argparse
import importlib.util
import io
import subprocess
import sys
from pathlib import Path


FIXTURES = ("while.py", "def.py", "class.py", "with.py", "for.py")


def load_mpy_tool(root: Path):
    tools = root / "tools"
    sys.path.insert(0, str(tools))
    spec = importlib.util.spec_from_file_location(
        "mpy_tool_v129", tools / "mpy-tool.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.config.native_arch = mod.MP_NATIVE_ARCH_NONE
    mod.config.MICROPY_LONGINT_IMPL = mod.config.MICROPY_LONGINT_IMPL_NONE
    mod.config.MPZ_DIG_SIZE = 16
    return mod


def entry_for(op_cls, op, arg):
    """Named execution entry. Not a new opcode number."""
    if (
        op_cls.MP_BC_LOAD_CONST_SMALL_INT_MULTI
        <= op
        < op_cls.MP_BC_LOAD_CONST_SMALL_INT_MULTI
        + op_cls.MP_BC_LOAD_CONST_SMALL_INT_MULTI_NUM
    ):
        return "LOAD_SMALL_INT"
    if (
        op_cls.MP_BC_LOAD_FAST_MULTI
        <= op
        < op_cls.MP_BC_LOAD_FAST_MULTI + op_cls.MP_BC_LOAD_FAST_MULTI_NUM
    ):
        return "LOAD_FAST"
    if (
        op_cls.MP_BC_STORE_FAST_MULTI
        <= op
        < op_cls.MP_BC_STORE_FAST_MULTI + op_cls.MP_BC_STORE_FAST_MULTI_NUM
    ):
        return "STORE_FAST"
    if (
        op_cls.MP_BC_UNARY_OP_MULTI
        <= op
        < op_cls.MP_BC_UNARY_OP_MULTI + op_cls.MP_BC_UNARY_OP_MULTI_NUM
    ):
        imm = op - op_cls.MP_BC_UNARY_OP_MULTI
        return (
            "UNARY_POSITIVE",
            "UNARY_NEGATIVE",
            "UNARY_INVERT",
            "UNARY_NOT",
        )[imm]
    if (
        op_cls.MP_BC_BINARY_OP_MULTI
        <= op
        < op_cls.MP_BC_BINARY_OP_MULTI + op_cls.MP_BC_BINARY_OP_MULTI_NUM
    ):
        imm = op - op_cls.MP_BC_BINARY_OP_MULTI
        if imm <= 5:
            return "COMPARE_OP"
        if imm == 6:
            return "CONTAINS_OP"
        if imm == 7:
            return "IS_OP"
        if imm == 8:
            return "CHECK_EXC_MATCH"
        return "BINARY_OP"
    table = {
        op_cls.MP_BC_LOAD_CONST_STRING: "LOAD_CONST",
        op_cls.MP_BC_LOAD_CONST_OBJ: "LOAD_CONST",
        op_cls.MP_BC_LOAD_CONST_FALSE: "LOAD_CONST",
        op_cls.MP_BC_LOAD_CONST_NONE: "LOAD_CONST",
        op_cls.MP_BC_LOAD_CONST_TRUE: "LOAD_CONST",
        op_cls.MP_BC_LOAD_NAME: "LOAD_NAME",
        op_cls.MP_BC_LOAD_GLOBAL: "LOAD_GLOBAL",
        op_cls.MP_BC_LOAD_ATTR: "LOAD_ATTR",
        op_cls.MP_BC_LOAD_METHOD: "LOAD_ATTR",
        op_cls.MP_BC_LOAD_SUPER_METHOD: "LOAD_SUPER_METHOD",
        op_cls.MP_BC_LOAD_BUILD_CLASS: "LOAD_BUILD_CLASS",
        op_cls.MP_BC_LOAD_SUBSCR: "LOAD_SUBSCR",
        op_cls.MP_BC_LOAD_NULL: "PUSH_NULL",
        op_cls.MP_BC_STORE_NAME: "STORE_NAME",
        op_cls.MP_BC_STORE_GLOBAL: "STORE_GLOBAL",
        op_cls.MP_BC_STORE_ATTR: "STORE_ATTR",
        op_cls.MP_BC_STORE_SUBSCR: "STORE_SUBSCR",
        op_cls.MP_BC_DELETE_NAME: "DELETE_NAME",
        op_cls.MP_BC_DELETE_GLOBAL: "DELETE_GLOBAL",
        op_cls.MP_BC_IMPORT_NAME: "IMPORT_NAME",
        op_cls.MP_BC_IMPORT_FROM: "IMPORT_FROM",
        op_cls.MP_BC_IMPORT_STAR: "IMPORT_STAR",
        op_cls.MP_BC_MAKE_CLOSURE: "MAKE_CLOSURE",
        op_cls.MP_BC_MAKE_CLOSURE_DEFARGS: "MAKE_CLOSURE_DEFARGS",
        op_cls.MP_BC_LOAD_CONST_SMALL_INT: "LOAD_SMALL_INT",
        op_cls.MP_BC_LOAD_FAST_N: "LOAD_FAST",
        op_cls.MP_BC_LOAD_DEREF: "LOAD_DEREF",
        op_cls.MP_BC_STORE_FAST_N: "STORE_FAST",
        op_cls.MP_BC_STORE_DEREF: "STORE_DEREF",
        op_cls.MP_BC_DELETE_FAST: "DELETE_FAST",
        op_cls.MP_BC_DELETE_DEREF: "DELETE_DEREF",
        op_cls.MP_BC_BUILD_TUPLE: "BUILD_TUPLE",
        op_cls.MP_BC_BUILD_LIST: "BUILD_LIST",
        op_cls.MP_BC_BUILD_MAP: "BUILD_MAP",
        op_cls.MP_BC_BUILD_SET: "BUILD_SET",
        op_cls.MP_BC_BUILD_SLICE: "BUILD_SLICE",
        op_cls.MP_BC_UNPACK_SEQUENCE: "UNPACK_SEQUENCE",
        op_cls.MP_BC_UNPACK_EX: "UNPACK_EX",
        op_cls.MP_BC_MAKE_FUNCTION: "MAKE_FUNCTION",
        op_cls.MP_BC_MAKE_FUNCTION_DEFARGS: "MAKE_FUNCTION_DEFARGS",
        op_cls.MP_BC_RETURN_VALUE: "RETURN_VALUE",
        op_cls.MP_BC_RAISE_LAST: "RAISE_LAST",
        op_cls.MP_BC_RAISE_OBJ: "RAISE_OBJ",
        op_cls.MP_BC_RAISE_FROM: "RAISE_FROM",
        op_cls.MP_BC_YIELD_VALUE: "YIELD_VALUE",
        op_cls.MP_BC_YIELD_FROM: "YIELD_FROM",
        op_cls.MP_BC_UNWIND_JUMP: "UNWIND_JUMP",
        op_cls.MP_BC_JUMP: "JUMP",
        op_cls.MP_BC_POP_JUMP_IF_TRUE: "POP_JUMP_IF_TRUE",
        op_cls.MP_BC_POP_JUMP_IF_FALSE: "POP_JUMP_IF_FALSE",
        op_cls.MP_BC_JUMP_IF_TRUE_OR_POP: "JUMP_IF_TRUE_OR_POP",
        op_cls.MP_BC_JUMP_IF_FALSE_OR_POP: "JUMP_IF_FALSE_OR_POP",
        op_cls.MP_BC_SETUP_WITH: "SETUP_WITH",
        op_cls.MP_BC_SETUP_EXCEPT: "SETUP_EXCEPT",
        op_cls.MP_BC_SETUP_FINALLY: "SETUP_FINALLY",
        op_cls.MP_BC_POP_EXCEPT_JUMP: "POP_EXCEPT_JUMP",
        op_cls.MP_BC_FOR_ITER: "FOR_ITER",
        op_cls.MP_BC_WITH_CLEANUP: "WITH_CLEANUP",
        op_cls.MP_BC_END_FINALLY: "END_FINALLY",
        op_cls.MP_BC_GET_ITER: "GET_ITER",
        op_cls.MP_BC_GET_ITER_STACK: "GET_ITER_STACK",
        op_cls.MP_BC_DUP_TOP: "COPY",
        op_cls.MP_BC_DUP_TOP_TWO: "COPY",
        op_cls.MP_BC_POP_TOP: "POP_TOP",
        op_cls.MP_BC_ROT_TWO: "SWAP",
        op_cls.MP_BC_ROT_THREE: "SWAP",
        op_cls.MP_BC_STORE_MAP: "STORE_MAP",
    }
    if op == op_cls.MP_BC_STORE_COMP:
        kind = arg & 3
        if kind == 0:
            return "LIST_APPEND"
        if kind == 1:
            return "MAP_ADD"
        return "SET_ADD"
    if op in (op_cls.MP_BC_CALL_FUNCTION, op_cls.MP_BC_CALL_METHOD):
        if ((arg >> 8) & 0xFF) != 0:
            return "CALL_KW"
        return "CALL"
    if op in (op_cls.MP_BC_CALL_FUNCTION_VAR_KW, op_cls.MP_BC_CALL_METHOD_VAR_KW):
        return "CALL_FUNCTION_EX"
    return table.get(op, "ILLEGAL")


def folded_immediate(op_cls, op):
    if (
        op_cls.MP_BC_LOAD_CONST_SMALL_INT_MULTI
        <= op
        < op_cls.MP_BC_LOAD_CONST_SMALL_INT_MULTI
        + op_cls.MP_BC_LOAD_CONST_SMALL_INT_MULTI_NUM
    ):
        return op - op_cls.MP_BC_LOAD_CONST_SMALL_INT_MULTI - op_cls.MP_BC_LOAD_CONST_SMALL_INT_MULTI_EXCESS
    if (
        op_cls.MP_BC_LOAD_FAST_MULTI
        <= op
        < op_cls.MP_BC_LOAD_FAST_MULTI + op_cls.MP_BC_LOAD_FAST_MULTI_NUM
    ):
        return op - op_cls.MP_BC_LOAD_FAST_MULTI
    if (
        op_cls.MP_BC_STORE_FAST_MULTI
        <= op
        < op_cls.MP_BC_STORE_FAST_MULTI + op_cls.MP_BC_STORE_FAST_MULTI_NUM
    ):
        return op - op_cls.MP_BC_STORE_FAST_MULTI
    if (
        op_cls.MP_BC_UNARY_OP_MULTI
        <= op
        < op_cls.MP_BC_UNARY_OP_MULTI + op_cls.MP_BC_UNARY_OP_MULTI_NUM
    ):
        return op - op_cls.MP_BC_UNARY_OP_MULTI
    if (
        op_cls.MP_BC_BINARY_OP_MULTI
        <= op
        < op_cls.MP_BC_BINARY_OP_MULTI + op_cls.MP_BC_BINARY_OP_MULTI_NUM
    ):
        return op - op_cls.MP_BC_BINARY_OP_MULTI
    return None


def encode_sig(n_state, n_exc, flags, n_pos, n_kw, n_def):
    """py/bc.h MP_BC_PRELUDE_SIG_ENCODE, then checked with mpy-tool's decoder."""
    s = n_state - 1
    e = n_exc
    f = flags & 0xF
    a = n_pos
    k = n_kw
    d = n_def
    out = bytearray()
    z = ((s & 0xF) << 3) | ((e & 1) << 2) | (a & 3)
    s >>= 4
    e >>= 1
    a >>= 2
    while s or e or f or a or k or d:
        out.append(0x80 | z)
        z = (
            ((f & 1) << 6)
            | ((s & 3) << 4)
            | ((k & 1) << 3)
            | ((a & 1) << 2)
            | ((e & 1) << 1)
            | (d & 1)
        )
        s >>= 2
        e >>= 1
        f >>= 1
        a >>= 1
        k >>= 1
        d >>= 1
    out.append(z)
    return out


def walk(rc):
    yield rc
    for child in rc.children:
        yield from walk(child)


def capture_disassembly(mod, cm):
    buf = io.StringIO()
    saved = sys.stdout
    try:
        sys.stdout = buf
        cm.disassemble()
    finally:
        sys.stdout = saved
    return buf.getvalue()


def instruction_lines(text):
    """Lines mpy-tool.py -d prints for opcodes, in order, per raw code."""
    import re

    blocks = []
    current = None
    prelude_re = re.compile(r"^  prelude: \(([^)]*)\)\s*$")
    insn_re = re.compile(r"^  ([0-9a-f:]+) +(.*)$")
    for line in text.splitlines():
        if line.startswith("simple_name:"):
            name = line.split(":", 1)[1].strip().split()[0]
            current = {"name": name, "prelude": None, "insns": []}
            blocks.append(current)
            continue
        if current is None:
            continue
        pre = prelude_re.match(line)
        if pre:
            current["prelude"] = tuple(int(p.strip()) for p in pre.group(1).split(","))
            continue
        ins = insn_re.match(line)
        if ins and current["prelude"] is not None:
            current["insns"].append((ins.group(1), ins.group(2).rstrip()))
    return blocks


def printed_operand(mapping_name, rest):
    if not rest.startswith(mapping_name):
        raise SystemExit("disassembly name %r does not start with %r" % (rest, mapping_name))
    tail = rest[len(mapping_name) :]
    if tail == "":
        return ""
    if not tail.startswith(" "):
        raise SystemExit("missing operand separator in %r" % rest)
    return tail[1:]


def hex_of(data):
    return "".join("%02x" % b for b in data)


def record_instr(kind, ip, bc, fmt, sz, arg, extra, entry, mod):
    op = bc[0]
    folded = folded_immediate(mod.Opcode, op)
    if folded is not None:
        arg_valid = 1
        arg_out = folded
    elif arg is None:
        arg_valid = 0
        arg_out = 0
    else:
        arg_valid = 1
        arg_out = arg
    if extra is None:
        extra_valid = 0
        extra_out = 0
    else:
        extra_valid = 1
        extra_out = extra
    illegal = 1 if entry == "ILLEGAL" else 0
    payload = hex_of(bc)
    if kind == "I":
        return "I %d %d %d %d %d %d %d %d %s %s" % (
            ip,
            op,
            sz,
            arg_valid,
            arg_out,
            extra_valid,
            extra_out,
            illegal,
            entry,
            payload,
        )
    return "S %d %d %d %d %d %d %d %s %s" % (
        op,
        sz,
        arg_valid,
        arg_out,
        extra_valid,
        extra_out,
        illegal,
        entry,
        payload,
    )


def check_printed(mod, rc, insns):
    """Match mpy-tool.py -xd text to mp_opcode_decode for one raw code."""
    bc = rc.fun_data
    ip = rc.offset_opcodes
    idx = 0
    while ip < len(bc):
        fmt, sz, arg, extra = mod.mp_opcode_decode(bc, ip)
        if idx >= len(insns):
            raise SystemExit("%s: disassembly ended early at ip %d" % (rc.simple_name.str, ip))
        hexpart, rest = insns[idx]
        got = bytes(int(p, 16) for p in hexpart.split(":"))
        if got != bc[ip : ip + sz]:
            raise SystemExit(
                "%s ip %d hex %s != %s"
                % (rc.simple_name.str, ip, hexpart, hex_of(bc[ip : ip + sz]))
            )
        name = mod.Opcode.mapping[bc[ip]]
        printed = printed_operand(name, rest)
        if fmt == mod.MP_BC_FORMAT_QSTR:
            expect = rc.qstr_table[arg].str
        elif bc[ip] == mod.Opcode.MP_BC_LOAD_CONST_OBJ:
            expect = repr(rc.obj_table[arg])
        elif fmt in (mod.MP_BC_FORMAT_VAR_UINT, mod.MP_BC_FORMAT_OFFSET):
            expect = str(arg)
        else:
            expect = ""
        if printed != expect:
            raise SystemExit(
                "%s ip %d printed %r != %r (%s)"
                % (rc.simple_name.str, ip, printed, expect, name)
            )
        ip += sz
        idx += 1
    if idx != len(insns):
        raise SystemExit("%s: %d extra disassembly lines" % (rc.simple_name.str, len(insns) - idx))


def emit_raw(mod, rc, lines):
    sig = rc.prelude_signature
    # n_state is sig[0], the Python value count. Do not scale it.
    lines.append(
        "P %d %d %d %d %d %d %d %d %d %d %d %s"
        % (
            sig[0],
            sig[1],
            sig[2],
            sig[3],
            sig[4],
            sig[5],
            rc.prelude_size[0],
            rc.prelude_size[1],
            rc.offset_opcodes,
            rc.offset_line_info,
            rc.offset_closure_info,
            hex_of(rc.fun_data),
        )
    )
    bc = rc.fun_data
    ip = rc.offset_opcodes
    while ip < len(bc):
        fmt, sz, arg, extra = mod.mp_opcode_decode(bc, ip)
        entry = entry_for(mod.Opcode, bc[ip], 0 if arg is None else arg)
        if entry == "ILLEGAL":
            raise SystemExit("fixture opcode 0x%02x has no execution entry" % bc[ip])
        lines.append(
            record_instr("I", ip, bc[ip : ip + sz], fmt, sz, arg, extra, entry, mod)
        )
        ip += sz


def expect_features(mod, filename, rcs):
    ops = []
    for rc in rcs:
        bc = rc.fun_data
        ip = rc.offset_opcodes
        while ip < len(bc):
            fmt, sz, arg, extra = mod.mp_opcode_decode(bc, ip)
            ops.append((bc[ip], sz, arg, extra, fmt))
            ip += sz
    opcodes = {op for op, _, _, _, _ in ops}

    def has(name):
        return getattr(mod.Opcode, name) in opcodes

    if filename == "while.py":
        if not (has("MP_BC_JUMP") or has("MP_BC_POP_JUMP_IF_TRUE") or has("MP_BC_POP_JUMP_IF_FALSE")):
            raise SystemExit("while fixture has no jump")
        if not any(arg is not None and arg < 0 for _, _, arg, _, fmt in ops if fmt == mod.MP_BC_FORMAT_OFFSET):
            raise SystemExit("while fixture has no backward offset")
        if not any(sz == 3 for _, sz, _, _, fmt in ops if fmt == mod.MP_BC_FORMAT_OFFSET):
            raise SystemExit("while fixture has no 2-byte offset")
        if not any(arg == 1000 for op, _, arg, _, _ in ops if op == mod.Opcode.MP_BC_LOAD_CONST_SMALL_INT):
            raise SystemExit("while fixture did not emit LOAD_CONST_SMALL_INT 1000")
    elif filename == "def.py":
        if not (has("MP_BC_MAKE_CLOSURE") or has("MP_BC_MAKE_FUNCTION")):
            raise SystemExit("def fixture has no function maker")
        if not any(extra is not None and op == mod.Opcode.MP_BC_MAKE_CLOSURE for op, _, _, extra, _ in ops):
            raise SystemExit("def fixture MAKE_CLOSURE has no extra byte")
        if not any(arg == -1000 for op, _, arg, _, _ in ops if op == mod.Opcode.MP_BC_LOAD_CONST_SMALL_INT):
            raise SystemExit("def fixture did not emit LOAD_CONST_SMALL_INT -1000")
    elif filename == "class.py":
        if not has("MP_BC_LOAD_BUILD_CLASS"):
            raise SystemExit("class fixture has no LOAD_BUILD_CLASS")
    elif filename == "with.py":
        if not has("MP_BC_SETUP_WITH") or not has("MP_BC_WITH_CLEANUP"):
            raise SystemExit("with fixture is missing SETUP_WITH or WITH_CLEANUP")
        if not any(
            op == mod.Opcode.MP_BC_UNWIND_JUMP and extra is not None
            for op, _, _, extra, _ in ops
        ):
            raise SystemExit("with fixture UNWIND_JUMP has no extra byte")
        if not any(
            op == mod.Opcode.MP_BC_SETUP_WITH and sz == 3 for op, sz, _, _, _ in ops
        ):
            raise SystemExit("with fixture SETUP_WITH is not a 2-byte offset")
    elif filename == "for.py":
        if not has("MP_BC_FOR_ITER"):
            raise SystemExit("for fixture has no FOR_ITER")
        if not (has("MP_BC_GET_ITER") or has("MP_BC_GET_ITER_STACK")):
            raise SystemExit("for fixture has no GET_ITER")
        if not any(sz == 2 for _, sz, _, _, fmt in ops if fmt == mod.MP_BC_FORMAT_OFFSET):
            raise SystemExit("for fixture has no 1-byte offset")


def synthetic_prelude(mod, lines):
    """Multi-byte signature and size, checked by mpy-tool's prelude decoder."""
    # n_state 20 needs a signature extension. n_info 70 needs a size extension.
    n_state, n_exc, flags = 20, 2, 1
    n_pos, n_kw, n_def = 5, 1, 1
    name_count = 1 + n_pos + n_kw
    line_bytes = 70 - name_count
    if line_bytes < 1:
        raise SystemExit("synthetic n_info too small")
    sig = encode_sig(n_state, n_exc, flags, n_pos, n_kw, n_def)
    size = bytes(mod.encode_prelude_size(70, 2))
    names = bytes([0x01] * name_count)
    line = bytes([0x11] * line_bytes)
    cells = bytes([0x03, 0x04])
    raw = bytes(sig) + size + names + line + cells
    decoded = mod.extract_prelude(raw, 0)
    got_sig = decoded[5]
    got_size = decoded[6]
    if got_sig != (n_state, n_exc, flags, n_pos, n_kw, n_def):
        raise SystemExit("synthetic sig round-trip %s" % (got_sig,))
    if got_size != (70, 2):
        raise SystemExit("synthetic size round-trip %s" % (got_size,))
    # extract_prelude returns offsets; line info ends at the closure.
    if decoded[2] != decoded[3] - line_bytes:
        raise SystemExit("synthetic line-info span is wrong")
    lines.append("# synthetic prelude, multi-byte signature and size")
    lines.append(
        "P %d %d %d %d %d %d %d %d %d %d %d %s"
        % (
            n_state,
            n_exc,
            flags,
            n_pos,
            n_kw,
            n_def,
            70,
            2,
            decoded[4],
            decoded[2],
            decoded[3],
            hex_of(raw),
        )
    )


def payload_for(mod, op):
    O = mod.Opcode
    fmt = (0x000003A4 >> (2 * (op >> 4))) & 3
    if fmt in (mod.MP_BC_FORMAT_QSTR, mod.MP_BC_FORMAT_VAR_UINT):
        if op == O.MP_BC_LOAD_CONST_SMALL_INT:
            return bytes(mod.mp_encode_uint(-1000, signed=True))
        if op in (O.MP_BC_CALL_FUNCTION, O.MP_BC_CALL_METHOD):
            return bytes(mod.mp_encode_uint(0x100))
        return bytes(mod.mp_encode_uint(5))
    if fmt == mod.MP_BC_FORMAT_OFFSET:
        # Two-byte form. Signed opcodes subtract the bias inside mp_opcode_decode.
        return bytes([0x85, 0x01])
    return b""


def synthetic_opcodes(mod, lines):
    O = mod.Opcode
    defined = [op for op in range(256) if entry_for(O, op, 0) != "ILLEGAL"]
    if len(defined) != 207:
        raise SystemExit("expected 207 defined opcodes, got %d" % len(defined))
    lines.append("# one encoding of every defined opcode, args from mp_opcode_decode")
    for op in defined:
        bc = bytearray([op])
        bc.extend(payload_for(mod, op))
        if op & mod.MP_BC_MASK_EXTRA_BYTE == 0:
            bc.append(0x03)
        fmt, sz, arg, extra = mod.mp_opcode_decode(bc, 0)
        if sz != len(bc):
            raise SystemExit("synthetic 0x%02x decoded %d of %d" % (op, sz, len(bc)))
        entry = entry_for(O, op, 0 if arg is None else arg)
        lines.append(record_instr("S", 0, bc, fmt, sz, arg, extra, entry, mod))
    # 1-byte offsets as well as the 2-byte form above.
    for op, raw in (
        (O.MP_BC_JUMP, bytes([O.MP_BC_JUMP, 0x40])),
        (O.MP_BC_FOR_ITER, bytes([O.MP_BC_FOR_ITER, 0x07])),
        (O.MP_BC_POP_JUMP_IF_FALSE, bytes([O.MP_BC_POP_JUMP_IF_FALSE, 0x3F])),
    ):
        fmt, sz, arg, extra = mod.mp_opcode_decode(raw, 0)
        entry = entry_for(O, op, 0 if arg is None else arg)
        lines.append(record_instr("S", 0, raw, fmt, sz, arg, extra, entry, mod))
    # 0x00 is not CACHE. The following LOAD_FAST byte is the extra byte, not
    # the real opcode. 0x45 is JUMP_IF_TRUE_OR_POP, not EXTENDED_ARG.
    for raw in (bytes([0x00, 0xB0]), bytes([0x45, 0x10, 0xB0]), bytes([0xD4]), bytes([0xFA])):
        fmt, sz, arg, extra = mod.mp_opcode_decode(raw, 0)
        entry = entry_for(O, raw[0], 0 if arg is None else arg)
        lines.append("# not CACHE / not EXTENDED_ARG: %s" % hex_of(raw))
        # Keep the trailing byte in the window so a prefix decoder would
        # swallow it. The recorded length is only the real instruction.
        lines.append(record_instr("S", 0, raw, fmt, sz, arg, extra, entry, mod))


def compile_fixtures(mpy_cross, src_dir, out_dir):
    out_dir.mkdir(parents=True, exist_ok=True)
    built = []
    for name in FIXTURES:
        src = src_dir / name
        dst = out_dir / (Path(name).stem + ".mpy")
        subprocess.check_call(
            [
                str(mpy_cross),
                "-msmall-int-bits=31",
                "-O0",
                "-X",
                "emit=bytecode",
                "-o",
                str(dst),
                str(src),
            ]
        )
        header = dst.read_bytes()[:4]
        if header != bytes.fromhex("4d06001f"):
            raise SystemExit("%s header %s is not 4d 06 00 1f" % (dst, header.hex()))
        built.append(dst)
    return built


def find_root(explicit):
    if explicit:
        return Path(explicit)
    for candidate in (Path("vendor/micropython"), Path("/tmp/micropython")):
        if (candidate / "tools" / "mpy-tool.py").is_file():
            return candidate
    raise SystemExit("set MPY_ROOT to a MicroPython v1.29.0 checkout")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=None)
    parser.add_argument("--fixtures", default="upycore/tb/mpy_fixtures")
    parser.add_argument("--out", required=True)
    parser.add_argument("--xd-dir", required=True)
    args = parser.parse_args()
    root = find_root(args.root or __import__("os").environ.get("MPY_ROOT"))
    mpy_cross = root / "mpy-cross" / "build" / "mpy-cross"
    if not mpy_cross.is_file():
        alt = root / "mpy-cross" / "mpy-cross"
        if alt.is_file():
            mpy_cross = alt
        else:
            raise SystemExit("mpy-cross not built under %s" % root)
    tool = root / "tools" / "mpy-tool.py"
    mod = load_mpy_tool(root)
    out_dir = Path(args.xd_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    mpys = compile_fixtures(mpy_cross, Path(args.fixtures), out_dir / "mpy")
    lines = [
        "# n_state is the Python value count from py/bc.h. It is not expanded",
        "# into two-register or four-register slots.",
    ]
    for mpy, src_name in zip(mpys, FIXTURES):
        mod.global_qstrs = mod.GlobalQStrList()
        proc = subprocess.run(
            [sys.executable, str(tool), "-xd", str(mpy)],
            check=True,
            capture_output=True,
            text=True,
        )
        xd_path = out_dir / (Path(src_name).stem + ".xd")
        xd_path.write_text(proc.stdout)
        blocks = instruction_lines(proc.stdout)
        mod.global_qstrs = mod.GlobalQStrList()
        cm = mod.read_mpy(str(mpy))
        rcs = list(walk(cm.raw_code))
        if len(blocks) != len(rcs):
            raise SystemExit(
                "%s: %d disassembly blocks, %d raw codes" % (src_name, len(blocks), len(rcs))
            )
        lines.append("# fixture %s" % src_name)
        for block, rc in zip(blocks, rcs):
            if block["name"] != rc.simple_name.str:
                raise SystemExit("name %s != %s" % (block["name"], rc.simple_name.str))
            if block["prelude"] != tuple(rc.prelude_signature):
                raise SystemExit(
                    "prelude text %s != %s" % (block["prelude"], rc.prelude_signature)
                )
            check_printed(mod, rc, block["insns"])
            lines.append(
                "# %s n_state %d opcode_off %d line %d..%d"
                % (
                    rc.simple_name.str,
                    rc.prelude_signature[0],
                    rc.offset_opcodes,
                    rc.offset_line_info,
                    rc.offset_closure_info,
                )
            )
            emit_raw(mod, rc, lines)
        expect_features(mod, src_name, rcs)
        print(
            "%s: %d raw codes, n_state %s"
            % (src_name, len(rcs), [rc.prelude_signature[0] for rc in rcs])
        )
    synthetic_prelude(mod, lines)
    synthetic_opcodes(mod, lines)
    dest = Path(args.out)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text("\n".join(lines) + "\n")
    print("wrote %s (%d lines)" % (dest, len(lines)))


if __name__ == "__main__":
    main()
