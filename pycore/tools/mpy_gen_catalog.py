#!/usr/bin/env python3
"""Write ``pycore/targets/mpycore.json`` from the pinned MicroPython headers.

Opcode numbers live in the JSON catalog. They are not copied into planning docs.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VENDOR = ROOT / "vendor" / "micropython"
OUT = ROOT / "pycore" / "targets" / "mpycore.json"

QSTR_O = 0x10
VINT_E = 0x20
VINT_O = 0x30
JUMP_E = 0x40
BYTE_O = 0x50
BYTE_E = 0x60

FORMAT_MAGIC = 0x000003A4
EXTRA_BYTE_MASK = 0x9E
FORMAT_NAME = {0: "byte", 1: "qstr", 2: "varuint", 3: "offset"}

# Stack effects are the net change in Python value-stack depth from py/vm.c.
# Variable effects name the operand the depth depends on.
NAMED: list[tuple[str, int, str, int | str]] = [
    ("LOAD_CONST_FALSE", BYTE_O + 0x00, "+1", 2),
    ("LOAD_CONST_NONE", BYTE_O + 0x01, "+1", 2),
    ("LOAD_CONST_TRUE", BYTE_O + 0x02, "+1", 2),
    ("LOAD_CONST_SMALL_INT", VINT_E + 0x02, "+1", 2),
    ("LOAD_CONST_STRING", QSTR_O + 0x00, "+1", 2),
    ("LOAD_CONST_OBJ", VINT_E + 0x03, "+1", 3),
    ("LOAD_NULL", BYTE_O + 0x03, "+1", 3),
    ("LOAD_FAST_N", VINT_E + 0x04, "+1", 2),
    ("LOAD_DEREF", VINT_E + 0x05, "+1", 4),
    ("LOAD_NAME", QSTR_O + 0x01, "+1", 2),
    ("LOAD_GLOBAL", QSTR_O + 0x02, "+1", 2),
    ("LOAD_ATTR", QSTR_O + 0x03, "0", 4),
    ("LOAD_METHOD", QSTR_O + 0x04, "+1", 3),
    ("LOAD_SUPER_METHOD", QSTR_O + 0x05, "-1", 4),
    ("LOAD_BUILD_CLASS", BYTE_O + 0x04, "+1", 4),
    ("LOAD_SUBSCR", BYTE_O + 0x05, "-1", 3),
    ("STORE_FAST_N", VINT_E + 0x06, "-1", 2),
    ("STORE_DEREF", VINT_E + 0x07, "-1", 4),
    ("STORE_NAME", QSTR_O + 0x06, "-1", 2),
    ("STORE_GLOBAL", QSTR_O + 0x07, "-1", 2),
    ("STORE_ATTR", QSTR_O + 0x08, "-2", 4),
    ("STORE_SUBSCR", BYTE_O + 0x06, "-3", 3),
    ("DELETE_FAST", VINT_E + 0x08, "0", 2),
    ("DELETE_DEREF", VINT_E + 0x09, "0", 4),
    ("DELETE_NAME", QSTR_O + 0x09, "0", 2),
    ("DELETE_GLOBAL", QSTR_O + 0x0A, "0", 2),
    ("DUP_TOP", BYTE_O + 0x07, "+1", 2),
    ("DUP_TOP_TWO", BYTE_O + 0x08, "+2", 2),
    ("POP_TOP", BYTE_O + 0x09, "-1", 2),
    ("ROT_TWO", BYTE_O + 0x0A, "0", 2),
    ("ROT_THREE", BYTE_O + 0x0B, "0", 2),
    ("UNWIND_JUMP", JUMP_E + 0x00, "variable", 4),
    ("JUMP", JUMP_E + 0x02, "0", 2),
    ("POP_JUMP_IF_TRUE", JUMP_E + 0x03, "-1", 2),
    ("POP_JUMP_IF_FALSE", JUMP_E + 0x04, "-1", 2),
    ("JUMP_IF_TRUE_OR_POP", JUMP_E + 0x05, "0 or -1", 2),
    ("JUMP_IF_FALSE_OR_POP", JUMP_E + 0x06, "0 or -1", 2),
    ("SETUP_WITH", JUMP_E + 0x07, "+2", 4),
    ("SETUP_EXCEPT", JUMP_E + 0x08, "0", 4),
    ("SETUP_FINALLY", JUMP_E + 0x09, "0", 4),
    ("POP_EXCEPT_JUMP", JUMP_E + 0x0A, "0", 4),
    ("FOR_ITER", JUMP_E + 0x0B, "variable", 3),
    ("WITH_CLEANUP", BYTE_O + 0x0C, "variable", 4),
    ("END_FINALLY", BYTE_O + 0x0D, "variable", 4),
    ("GET_ITER", BYTE_O + 0x0E, "0", 3),
    ("GET_ITER_STACK", BYTE_O + 0x0F, "+3", 3),
    ("BUILD_TUPLE", VINT_E + 0x0A, "1-n", 3),
    ("BUILD_LIST", VINT_E + 0x0B, "1-n", 3),
    ("BUILD_MAP", VINT_E + 0x0C, "+1", 3),
    ("STORE_MAP", BYTE_E + 0x02, "-2", 3),
    ("BUILD_SET", VINT_E + 0x0D, "1-n", 3),
    ("BUILD_SLICE", VINT_E + 0x0E, "1-n", 3),
    ("STORE_COMP", VINT_E + 0x0F, "list/set -1, dict -2", 3),
    ("UNPACK_SEQUENCE", VINT_O + 0x00, "n-1", 3),
    ("UNPACK_EX", VINT_O + 0x01, "n_left+n_right", 3),
    ("RETURN_VALUE", BYTE_E + 0x03, "-1", 2),
    ("RAISE_LAST", BYTE_E + 0x04, "0", 4),
    ("RAISE_OBJ", BYTE_E + 0x05, "0", 4),
    ("RAISE_FROM", BYTE_E + 0x06, "-1", 4),
    ("YIELD_VALUE", BYTE_E + 0x07, "0", "reject"),
    ("YIELD_FROM", BYTE_E + 0x08, "variable", "reject"),
    ("MAKE_FUNCTION", VINT_O + 0x02, "+1", 2),
    ("MAKE_FUNCTION_DEFARGS", VINT_O + 0x03, "-1", 4),
    ("MAKE_CLOSURE", VINT_E + 0x00, "1-n_closed", 4),
    ("MAKE_CLOSURE_DEFARGS", VINT_E + 0x01, "-(1+n_closed)", 4),
    ("CALL_FUNCTION", VINT_O + 0x04, "-(n_pos+2*n_kw)", 2),
    ("CALL_METHOD", VINT_O + 0x06, "-(n_pos+2*n_kw+1)", 3),
    ("CALL_FUNCTION_VAR_KW", VINT_O + 0x05, "-(n_pos+2*n_kw+1)", 4),
    ("CALL_METHOD_VAR_KW", VINT_O + 0x07, "-(n_pos+2*n_kw+2)", 4),
    ("IMPORT_NAME", QSTR_O + 0x0B, "-1", 4),
    ("IMPORT_FROM", QSTR_O + 0x0C, "+1", 4),
    ("IMPORT_STAR", BYTE_E + 0x09, "-1", 4),
]

SIGNED_OFFSETS = {"UNWIND_JUMP", "JUMP", "POP_JUMP_IF_TRUE", "POP_JUMP_IF_FALSE"}

UNARY = ("__pos__", "__neg__", "__invert__", "<not>")
BINARY = (
    "__lt__",
    "__gt__",
    "__eq__",
    "__le__",
    "__ge__",
    "__ne__",
    "<in>",
    "<is>",
    "<exception match>",
    "__ior__",
    "__ixor__",
    "__iand__",
    "__ilshift__",
    "__irshift__",
    "__iadd__",
    "__isub__",
    "__imul__",
    "__imatmul__",
    "__ifloordiv__",
    "__itruediv__",
    "__imod__",
    "__ipow__",
    "__or__",
    "__xor__",
    "__and__",
    "__lshift__",
    "__rshift__",
    "__add__",
    "__sub__",
    "__mul__",
    "__matmul__",
    "__floordiv__",
    "__truediv__",
    "__mod__",
    "__pow__",
)
# Compares, add, and subtract are the phase 2 integer subset. The other
# binary sub-ops arrive with the exception and float work.
BINARY_PHASE2 = {0, 1, 2, 3, 4, 5, 27, 28}


def _row(name: str, opcode: int, stack: str, phase: int | str) -> dict:
    fmt = FORMAT_NAME[(FORMAT_MAGIC >> (2 * (opcode >> 4))) & 3]
    return {
        "name": name,
        "opcode": opcode,
        "format": fmt,
        "stack_effect": stack,
        "phase": phase,
        "signed": name in SIGNED_OFFSETS or name == "LOAD_CONST_SMALL_INT",
        "extra_byte": (opcode & EXTRA_BYTE_MASK) == 0,
    }


def build() -> dict:
    sys.path.insert(0, str(VENDOR / "py"))
    import makeqstrdata as qstrs

    static = list(qstrs.static_qstr_list)
    opcodes: list[dict] = []
    for name, opcode, stack, phase in NAMED:
        opcodes.append(_row(name, opcode, stack, phase))

    small_base = 0x70
    for index in range(64):
        opcodes.append(
            _row(
                "LOAD_CONST_SMALL_INT %d" % (index - 16),
                small_base + index,
                "+1",
                2,
            )
        )
    for index in range(16):
        opcodes.append(_row("LOAD_FAST %d" % index, 0xB0 + index, "+1", 2))
        opcodes.append(_row("STORE_FAST %d" % index, 0xC0 + index, "-1", 2))
    for index, method in enumerate(UNARY):
        opcodes.append(_row("UNARY_OP %d %s" % (index, method), 0xD0 + index, "0", 2))
    for index, method in enumerate(BINARY):
        phase: int | str = 2 if index in BINARY_PHASE2 else 4
        opcodes.append(_row("BINARY_OP %d %s" % (index, method), 0xD7 + index, "-1", phase))

    signed_offset_opcodes = [row["opcode"] for row in opcodes if row["name"] in SIGNED_OFFSETS]

    return {
        "name": "mpycore",
        "pin": {
            "version": "1.29.0",
            "commit": "0fd6c573ea815774668bbb16b8e197c8822368b2",
        },
        "mpy": {
            "version": 6,
            "sub_version": 3,
            "bytecode_only_feature_byte": 0,
            "small_int_bits": 31,
            "sample_header": "4d06001f",
            "qstr_last_static": len(static),
            "qstr_last_static_name": "zip",
            "feature": {
                "sub_version_mask": 3,
                "arch_shift": 2,
                "arch_mask": 47,
                "flags_bit": 64,
            },
        },
        "runtime": {
            "int_bits": 64,
            "register_file_entries": 64,
            "flash_base": 0,
            "reserved_prefix": 8,
            "pointer_forbidden": [0, 4],
            "qstr_bytes_in_hash": 2,
            "qstr_bytes_in_len": 1,
        },
        "architectures": [
            "NONE",
            "X86",
            "X64",
            "ARMV6",
            "ARMV6M",
            "ARMV7M",
            "ARMV7EM",
            "ARMV7EMSP",
            "ARMV7EMDP",
            "XTENSA",
            "XTENSAWIN",
            "RV32IMC",
            "RV64IMC",
        ],
        "raw_code_kinds": {
            "bytecode": 2,
            "native": 3,
            "viper": 4,
            "asm": 5,
        },
        "const_kinds": {
            "fun_table": {"id": 0, "phase": "reject", "reason": "native"},
            "none": {"id": 1, "phase": 1},
            "false": {"id": 2, "phase": 1},
            "true": {"id": 3, "phase": 1},
            "ellipsis": {"id": 4, "phase": 1},
            "str": {"id": 5, "phase": 1},
            "bytes": {"id": 6, "phase": 1},
            "int": {"id": 7, "phase": 1, "reject_outside": "signed-64"},
            "float": {"id": 8, "phase": "reject", "until": 4},
            "complex": {"id": 9, "phase": "reject", "until": 4},
            "tuple": {"id": 10, "phase": 1},
        },
        "immediates": {"none": 0, "false": 1, "true": 3},
        "control_kinds": {
            "empty": 0,
            "none": 1,
            "null": 2,
            "tombstone": 3,
            "false": 4,
            "true": 5,
        },
        "tags": [
            {"tag": 0, "name": "CONTROL", "registers": 1},
            {"tag": 1, "name": "INT", "registers": 1},
            {"tag": 2, "name": "INT64", "registers": 2},
            {"tag": 3, "name": "FLOAT", "registers": 1},
            {"tag": 4, "name": "COMPLEX", "registers": 2},
            {"tag": 5, "name": "reserved", "registers": 0},
            {"tag": 6, "name": "QSTR", "registers": 1},
            {"tag": 7, "name": "SHORT_STR", "registers": 4},
            {"tag": 8, "name": "STR", "registers": 1},
            {"tag": 9, "name": "TUPLE", "registers": 1},
            {"tag": 10, "name": "MUT_COLLEC", "registers": 1},
            {"tag": 11, "name": "RANGE", "registers": 1},
            {"tag": 12, "name": "ITER", "registers": 1},
            {"tag": 13, "name": "BYTES", "registers": 1},
            {"tag": 14, "name": "OBJECT", "registers": 1},
            {"tag": 15, "name": "CONT", "registers": 1},
        ],
        "object_kinds": {
            "instance": 1,
            "type": 2,
            "bound_method": 3,
            "builtin": 4,
            "exception": 6,
            "cell": 7,
            "function": 8,
            "module": 11,
            "ellipsis": 12,
        },
        "prelude": {
            "encoding": "bit-interleaved",
            "signature_fields": [
                "n_state",
                "n_exc_stack",
                "scope_flags",
                "n_pos_args",
                "n_kwonly_args",
                "n_def_pos_args",
            ],
            "size_fields": ["n_info", "n_cell"],
            "source_info": ["simple_name", "arg_names", "line_info"],
            "after_source_info": ["closure_cells", "opcodes"],
            "scope_flags": {
                "generator": 1,
                "varkeywords": 2,
                "varargs": 4,
                "defkwargs": 8,
            },
        },
        "bytecode": {
            "format_magic": FORMAT_MAGIC,
            "extra_byte_mask": EXTRA_BYTE_MASK,
            "signed_offset_opcodes": signed_offset_opcodes,
            "windows": {
                "small_int": {"base": small_base, "count": 64, "excess": 16},
                "load_fast": {"base": 0xB0, "count": 16},
                "store_fast": {"base": 0xC0, "count": 16},
                "unary": {"base": 0xD0, "count": len(UNARY), "names": list(UNARY)},
                "binary": {"base": 0xD7, "count": len(BINARY), "names": list(BINARY)},
            },
            "opcodes": opcodes,
        },
        "image": {
            "magic": "UPMI",
            "version": 1,
            "header_bytes": 48,
            "bytecode_kind": 0,
            "qstr_desc_words": 3,
            "module_entry_words": 8,
            "raw_code_words": 20,
        },
        "static_qstrs": static,
    }


def main() -> None:
    payload = build()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {OUT} ({len(payload['bytecode']['opcodes'])} opcodes, {len(payload['static_qstrs'])} static qstrs)")


if __name__ == "__main__":
    main()
