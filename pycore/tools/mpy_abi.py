#!/usr/bin/env python3
"""The flash-image ABI shared by the linker, the firmware, and the core RTL.

This file is the single source of truth. ``mpy_abi.py --sv`` writes
``pycore/rtl/mpy_abi.svh``; ``mpy_abi.py --check`` fails when that file is
stale. Everything the core reads from flash at a fixed place, every object
kind and native type id, every RTL builtin id, and the qstr ids the core
hard-codes are listed here. pycore/docs/mpy_core.md explains each table.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SV_PATH = REPO_ROOT / "pycore" / "rtl" / "mpy_abi.svh"
PY_PATH = REPO_ROOT / "pycore_firmware" / "mpy" / "fw" / "_abi.py"

IMAGE_MAGIC = 0x324D5055  # "UPM2" little-endian
IMAGE_VERSION = 2

# ---------------------------------------------------------------------------
# Flash header: word i sits at byte 4*i. The first 8 bytes are the magic and
# the version, so no object starts below 8.
HDR = {
    "MAGIC": 0,
    "VERSION": 1,
    "IMAGE_BYTES": 2,
    "QSTR_COUNT": 3,
    "QSTR_DESC": 4,       # 2 words per qstr: [hash | len << 16], [byte address]
    "MAIN_MODULE": 5,     # module descriptor of __main__
    "BUILTINS": 6,        # ROM dict: the builtins namespace
    "FW_GLOBALS": 7,      # ROM dict: globals of every firmware function
    "FROZEN": 8,          # ROM dict: module name qstr -> INT(module descriptor)
    "HOOKS": 9,           # tagged array of firmware functions the core calls
    "MSGS": 10,           # tagged array of ROM args tuples for fixed messages
    "CHARS": 11,          # word array: ASCII code -> qstr id of that 1-char str
    "EMPTY_TUPLE": 12,
    "FW_MODULE": 13,      # module descriptor of the firmware
    "POOL_BYTES": 14,     # GC pool size the image was linked for (0: default)
    "FLAGS": 15,
}
HEADER_WORDS = 16

# Native type table at a fixed flash address so the core never reads the
# header to find a type: TYPE_TABLE_BASE + 4 * type_id.
TYPE_TABLE_BASE = 0x40
TYPE_TABLE_WORDS = 96
IMAGE_DATA_BASE = TYPE_TABLE_BASE + 4 * TYPE_TABLE_WORDS

# Raw-code descriptor (one per function, class body, comprehension, module).
RC = {
    "OP_START": 0,        # byte address of the first opcode
    "SIG": 1,             # n_state | n_exc_stack << 8 | scope_flags << 16 | flags << 24
    "ARGS": 2,            # n_pos | n_kwonly << 8 | n_def_pos << 16 | n_cell << 24
    "ARG_NAMES": 3,       # word array of global qstr ids, n_pos + n_kwonly
    "CELLS": 4,           # word array of local indexes, n_cell
    "MODULE": 5,          # module descriptor
    "CHILDREN": 6,        # word array of raw-code descriptors
    "NAME": 7,            # global qstr id of the simple name
    "BC_START": 8,        # byte address of the prelude
    "LINE_INFO": 9,       # byte address of the first line-info byte
    "LINE_INFO_END": 10,  # byte address after the line info
    "SOURCE_FILE": 11,    # global qstr id
}
RC_WORDS = 12
RC_FLAG_FIRMWARE = 0x01   # frame is hidden from tracebacks
RC_FLAG_GENERATOR = 0x02

SCOPE_GENERATOR = 0x01
SCOPE_VARKEYWORDS = 0x02
SCOPE_VARARGS = 0x04
SCOPE_DEFKWARGS = 0x08

# Module descriptor.
MD = {
    "QSTRS": 0,           # word array: module qstr index -> global qstr id
    "CONSTS": 1,          # tagged slot array: module const index -> value
    "NAME": 2,            # global qstr id of the module name
    "RAW": 3,             # top-level raw-code descriptor
    "SOURCE_FILE": 4,
    "FLAGS": 5,           # bit 0 firmware, bit 1 package
    "PACKAGE": 6,         # qstr of the package the module's relative imports start from
}
MD_WORDS = 7
MD_FLAG_FIRMWARE = 1
MD_FLAG_PACKAGE = 2

# ---------------------------------------------------------------------------
# Tags and CONTROL kinds (pivot plan §0.5, revised in pycore/docs/mpy_core.md:
# INT64 and COMPLEX are pointers to two-word boxes).
TAG = {
    "CONTROL": 0, "INT": 1, "INT64": 2, "FLOAT": 3, "COMPLEX": 4,
    "RESERVED": 5, "QSTR": 6, "SHORT_STR": 7, "STR": 8, "TUPLE": 9,
    "MUT": 10, "RANGE": 11, "ITER": 12, "BYTES": 13, "OBJECT": 14,
    "CONT": 15,
}
CTL = {"NULL": 0, "NONE": 1, "STOP": 2, "TOMB": 3, "FALSE": 4, "TRUE": 5}
MUT = {"LIST": 0, "DICT": 1, "SET": 2, "BYTEARRAY": 3}

# Word counts of the fixed-size heap layouts (pycore/docs/mpy_core.md).
LIST_WORDS = 3        # [0] len [1] alloc [2] items
DICT_WORDS = 4        # [0] used [1] alloc [2] table [3] flags
SET_WORDS = 4         # same as dict; table has one word per slot
STR_HDR_WORDS = 3     # [0] len [1] hash [2] data address; bytes follow
RANGE_WORDS = 3
ITER_WORDS = 4
BOX_WORDS = 2         # INT64 [lo, hi], COMPLEX [re, im]

DICT_FLAG_ROM = 1
SET_FLAG_FROZEN = 2

# OBJECT word 0. Word 1 is always the type object.
OB = {
    "INSTANCE": 1,       # [2] __dict__
    "TYPE": 2,           # [2] dict [3] bases [4] name [5] mro [6] id [7] flags [8] make_new
    "BOUND_METHOD": 3,   # [2] function [3] self
    "BUILTIN": 4,        # [2] native id [3] fallback callable [4] name qstr
    "EXCEPTION": 6,      # [2] args tuple [3] traceback list [4] __dict__
    "CELL": 7,           # [2] contents
    "FUNCTION": 8,       # [2] raw code [3] closure tuple [4] defaults tuple
                         # [5] kw defaults dict [6] globals dict
    "MODULE": 11,        # [2] globals dict [3] name qstr
    "ELLIPSIS": 12,
    "SLICE": 13,         # [2] start [3] stop [4] step
    "PROPERTY": 14,      # [2] fget [3] fset [4] fdel
    "STATICMETHOD": 15,  # [2] function
    "CLASSMETHOD": 16,   # [2] function
    "DICT_VIEW": 17,     # [2] dict [3] kind (0 keys, 1 values, 2 items)
    "SUPER": 18,         # [2] type [3] object
    "NOTIMPL": 19,
}
OBJ_WORDS = {
    "INSTANCE": 3, "TYPE": 9, "BOUND_METHOD": 4, "BUILTIN": 5,
    "EXCEPTION": 5, "CELL": 3, "FUNCTION": 7, "MODULE": 4, "ELLIPSIS": 2,
    "SLICE": 5, "PROPERTY": 5, "STATICMETHOD": 3, "CLASSMETHOD": 3,
    "DICT_VIEW": 4, "SUPER": 4, "NOTIMPL": 2,
}

# TYPE word 7.
TF = {
    "INST": 0x01,     # the core instantiates it: INSTANCE or EXCEPTION, then __init__
    "EXC": 0x02,      # instances are EXCEPTION objects
    "USER": 0x04,     # built by __build_class__
    "EQ": 0x08,       # __eq__ somewhere in the mro: == goes to the firmware
    "TRUTH": 0x10,    # __bool__ or __len__ in the mro
    "NATIVE_SUB": 0x20,  # user subclass of a native type other than object/exceptions
    "SETATTR": 0x40,  # __setattr__ or __delattr__ in the mro
    "DESC": 0x80,     # a property or other data descriptor in the mro
    "GETATTR": 0x100, # __getattr__ in the mro (attribute misses go to the firmware)
}

# STR/BYTES word 1 is the 16-bit hash; bit 30 marks data that is not all
# ASCII, so the core leaves len() and indexing to the firmware. A qstr
# descriptor carries the same flag in bit 31 of its address word.
STR_NONASCII = 1 << 30
QDESC_NONASCII = 1 << 31

# Four-slot for-loop buffer (GET_ITER_STACK) and heap ITER objects share one
# layout: [0] iterable or current value, [1] index or stop, [2] step or
# sub-kind, [3] kind.
IT = {
    "SEQ": 0,        # list, tuple, bytes, bytearray: [0] seq [1] index
    "RANGE": 1,      # [0] next value [1] stop [2] step
    "DICT": 2,       # [0] dict [1] slot index [2] 0 keys, 1 values, 2 items
    "SET": 3,        # [0] set [1] slot index
    "PYOBJ": 4,      # [0] object with __next__
    "STR": 5,        # [0] str or qstr [1] byte index
    "HEAPITER": 6,   # [0] heap ITER object; its own four words hold the state
}

# ---------------------------------------------------------------------------
# Native type ids: the core finds TYPE_TABLE[id]. Order matters only here.
TYPES = [
    "object", "type", "NoneType", "bool", "int", "float", "complex", "str",
    "bytes", "bytearray", "tuple", "list", "dict", "set", "frozenset",
    "range", "iterator", "function", "bound_method", "builtin_function",
    "module", "cell", "slice", "property", "staticmethod", "classmethod",
    "dict_view", "super", "ellipsis", "NotImplementedType", "generator",
    "closure", "enumerate", "zip", "map", "filter", "reversed",
    # Exceptions. The hierarchy is in EXC_BASES.
    "BaseException", "Exception", "ArithmeticError", "AssertionError",
    "AttributeError", "EOFError", "GeneratorExit", "ImportError",
    "IndentationError", "IndexError", "KeyError", "KeyboardInterrupt",
    "LookupError", "MemoryError", "NameError", "NotImplementedError",
    "OSError", "OverflowError", "RuntimeError", "StopIteration",
    "SyntaxError", "SystemExit", "TypeError", "ValueError",
    "ZeroDivisionError", "StopAsyncIteration", "UnicodeError",
]
TYPE_ID = {name: i + 1 for i, name in enumerate(TYPES)}
assert len(TYPES) + 1 <= TYPE_TABLE_WORDS

EXC_BASES = {
    "BaseException": "object",
    "Exception": "BaseException",
    "GeneratorExit": "BaseException",
    "KeyboardInterrupt": "BaseException",
    "SystemExit": "BaseException",
    "ArithmeticError": "Exception",
    "AssertionError": "Exception",
    "AttributeError": "Exception",
    "EOFError": "Exception",
    "ImportError": "Exception",
    "LookupError": "Exception",
    "MemoryError": "Exception",
    "NameError": "Exception",
    "OSError": "Exception",
    "RuntimeError": "Exception",
    "StopAsyncIteration": "Exception",
    "StopIteration": "Exception",
    "SyntaxError": "Exception",
    "TypeError": "Exception",
    "ValueError": "Exception",
    "OverflowError": "ArithmeticError",
    "ZeroDivisionError": "ArithmeticError",
    "IndentationError": "SyntaxError",
    "IndexError": "LookupError",
    "KeyError": "LookupError",
    "NotImplementedError": "RuntimeError",
    "UnicodeError": "ValueError",
}
NATIVE_BASES = {"bool": "int"}
FIRST_EXC_TYPE = TYPE_ID["BaseException"]

# Names the type prints with when it differs from the table key.
TYPE_PRINT_NAME = {
    "builtin_function": "function",
    "closure": "closure",
}

# Types callable from Python and found in the builtins dict.
PUBLIC_TYPES = [
    "object", "type", "bool", "int", "float", "complex", "str", "bytes",
    "bytearray", "tuple", "list", "dict", "set", "frozenset", "range",
    "slice", "property", "staticmethod", "classmethod", "super",
    "enumerate", "zip", "map", "filter", "reversed",
] + [t for t in TYPES if t in EXC_BASES]

# ---------------------------------------------------------------------------
# RTL builtins: BUILTIN objects carry one of these ids. A name without a dot
# is a builtin (public) or a firmware primitive (leading underscore). A
# "type.method" name lives in that native type's dict. "new.T" is the
# constructor in TYPE word 8. When a native cannot handle its arguments it
# calls the BUILTIN's fallback (word 3) with the same arguments.
NATIVES = [
    # public builtins with an RTL fast path
    "len", "isinstance", "id",
    # firmware primitives (pycore_firmware/mpy/fw/README.md lists signatures)
    "_wr",       # _wr(s): bytes of a str/bytes/qstr, or one byte (int), to stdout
    "_we",       # _we(s): the same to stderr
    "_halt",     # _halt(code)
    "_tag",      # _tag(x) -> int tag nibble
    "_pay",      # _pay(x) -> unsigned 32-bit payload
    "_mk",       # _mk(tag, payload) -> value
    "_ld",       # _ld(p, i) -> tagged word i of object/address p
    "_st",       # _st(p, i, v)
    "_peek8",    # _peek8(p, off) -> byte
    "_poke8",    # _poke8(p, off, b)
    "_peek32",   # _peek32(addr) -> unsigned raw word
    "_alloc",    # _alloc(nwords, tag, low) -> zeroed block tagged {tag, addr | low}
    "_typeof",   # _typeof(x) -> type object
    "_callns",   # _callns(code, ns): run a function or module descriptor (INT) with locals ns
    "_wcopy",    # _wcopy(dst, doff, src, soff, n): tagged words
    "_bcopy",    # _bcopy(dst, doff, src, soff, n): bytes (offsets from the data start)
    "_strnew",   # _strnew(nbytes, tag) -> STR/BYTES with zeroed data, hash unset
    "_strfin",   # _strfin(s) -> s with hash and ASCII flag computed
    "_lookup",   # _lookup(d, key) -> value or NULL (simple keys; complex keys -> STOP)
    "_ticks",    # _ticks() -> cycle counter (31 bits)
    "_gc",       # _gc(): collect now
    "_gcinfo",   # _gcinfo(which) -> 0 free blocks, 1 total blocks, 2 collections
    "_ftoi",     # _ftoi(f) -> int (truncate); STOP for nan/inf
    "_inext",    # _inext(it) -> next item of an RTL-steppable iterator or STOP
    "_bcmp",     # _bcmp(a, b) -> <0, 0, >0 (str/bytes/qstr byte compare)
    "_hash",     # _hash(x) -> hash of a simple key, or STOP
    "_data",     # _data(s) -> INT address of the bytes of a str/bytes/qstr
    "_slen",     # _slen(s) -> byte length of a str/bytes/qstr
    # type methods
    "list.append", "object.__init__", "BaseException.__init__",
    # constructors
    "new.range", "new.object",
]
NATIVE_ID = {name: i for i, name in enumerate(NATIVES)}

# Firmware hook table: the core calls these firmware functions by index.
HOOKS = [
    "_boot",          # _boot(): run __main__, report an uncaught exception
    "_raise",         # _raise(code, a, b): build and raise a formatted error
    "_binop",         # _binop(op, lhs, rhs): every binary op the RTL does not do
    "_unop",          # _unop(op, x)
    "_truth",         # _truth(x): bool for objects the RTL cannot judge
    "_getattr",       # _getattr(obj, name): attribute fallback and AttributeError
    "_setattr",       # _setattr(obj, name, value): store fallback (value NULL: delete)
    "_subscr",        # _subscr(obj, index): load fallback
    "_setsubscr",     # _setsubscr(obj, index, value): store fallback (value NULL: delete)
    "_getiter",       # _getiter(x): an iterator the RTL can step
    "_tuple",         # _tuple(x): any iterable to a tuple (star arguments)
    "_dictop",        # _dictop(op, d, key, value): dict/set ops on keys the RTL cannot hash
    "_import",        # _import(name, fromlist, level, globals)
    "_import_from",   # _import_from(module, name)
    "_import_star",   # _import_star(module, locals)
    "_unpack",        # _unpack(x, before, after): a tuple of exactly the unpacked items
    "_kwdict",        # _kwdict(x): a ** argument that is not a dict, to a dict
    "__build_class__",
    "_call",          # _call(obj, args, kw): callables the RTL cannot call
    "_irq_uncaught",
    "_bind",          # _bind(fun, args, kw): locals tuple for a call the RTL cannot bind
    "_super_method",  # _super_method(type, obj, name): super().name
    "_warn",          # _warn(code): print a runtime warning to stderr
]
HOOK_ID = {name: i for i, name in enumerate(HOOKS)}

# _raise codes. The firmware formats the message with the oracle's text.
ERR = [
    "NAME",             # a: qstr name
    "NOT_CALLABLE",     # a: object
    "NOT_ITERABLE",     # a: object
    "NOT_ITERATOR",     # a: object
    "UNHASHABLE",       # a: object
    "ARG_COUNT",        # a: expected, b: given
    "ARG_MISSING_POS",  # a: count
    "ARG_KW_UNEXPECTED",# a: name
    "ARG_KW_MULTIPLE",  # a: name
    "ARG_KW_MISSING",   # a: name
    "ARG_KWONLY",       #
    "ARG_MISSING_N",    # a: positional number (1-based)
    "KEY",              # a: key
    "ATTR",             # a: object, b: name
    "NOT_EXC",          # raise of a non-exception
    "IMPORT_NAME",      # a: name qstr
    "INIT_NONE",        # a: returned object
    "UNSUPPORTED_BIN",  # a: op, b: lhs (c: rhs passed in a tuple)
    "BUILTIN_ARGS",     # a: name qstr, b: count
    "MEMORY",           # a: requested bytes
    "INDEX_TYPE",       # a: container, b: index
    "NO_KW",            # a: name: function doesn't take keyword arguments
    "GENERATOR",        # generators are not supported
    "SUPER",
    "CANT_CREATE",      # a: type
    "STAR_ARGS",        # too many arguments for the argument buffer
    "NOT_TYPE",         # isinstance() arg 2
    "INTERNAL",
]
ERR_ID = {name: i for i, name in enumerate(ERR)}

# Fixed messages: (name, exception type, text). The core raises these with a
# ROM args tuple and no firmware frame.
MSGS = [
    ("EMPTY", "Exception", None),
    ("RECURSION", "RuntimeError", "maximum recursion depth exceeded"),
    ("DIV_ZERO", "ZeroDivisionError", "divide by zero"),
    ("OVERFLOW", "OverflowError", "result overflows long long storage"),
    ("LIST_INDEX", "IndexError", "list index out of range"),
    ("TUPLE_INDEX", "IndexError", "tuple index out of range"),
    ("STR_INDEX", "IndexError", "string index out of range"),
    ("LOCAL_UNBOUND", "NameError", "local variable referenced before assignment"),
    ("NEG_SHIFT", "ValueError", "negative shift count"),
    ("NO_ACTIVE_EXC", "RuntimeError", "no active exception to reraise"),
    ("ZERO_STEP", "ValueError", "zero step"),
    ("STOP_ITER", "StopIteration", None),
    ("MEMORY", "MemoryError", None),
    ("ASSERT", "AssertionError", None),
    ("BYTES_INDEX", "IndexError", "bytes index out of range"),
    ("RANGE_INDEX", "IndexError", "range index out of range"),
    ("POP_EMPTY", "IndexError", "pop from empty list"),
    ("HEAP_LOCKED", "MemoryError", "memory allocation failed, heap is locked"),
    ("SCHED_FULL", "RuntimeError", "schedule queue full"),
    ("KBD", "KeyboardInterrupt", None),
]
MSG_ID = {name: i for i, (name, _, _) in enumerate(MSGS)}

# ---------------------------------------------------------------------------
# Qstrs the core hard-codes. Names in the pin's static list keep the pin's
# id; the rest are assigned right after the static block, in this order.
CORE_QSTRS = [
    "", "<module>", "__init__", "__name__", "__main__", "__next__",
    "__iter__", "__len__", "__call__", "__enter__", "__exit__",
    "__getitem__", "__setitem__", "__delitem__", "__hash__", "__repr__",
    "__str__", "__class__", "__module__", "__qualname__", "__new__",
    "__getattr__", "__bool__", "__contains__", "__dict__", "__all__",
    "__build_class__", "__eq__", "__setattr__", "__delattr__", "args",
    "value", "__path__", "__bases__", "__file__", "self",
    "__get__", "__set__", "__delete__", "__import__", "__doc__",
    "builtins",
]

# Binary op dunder names, indexed by bytecode binary op (py/runtime0.h).
BINOP_NAMES = [
    "__lt__", "__gt__", "__eq__", "__le__", "__ge__", "__ne__", "__contains__",
    None, None,
    "__ior__", "__ixor__", "__iand__", "__ilshift__", "__irshift__",
    "__iadd__", "__isub__", "__imul__", "__imatmul__", "__ifloordiv__",
    "__itruediv__", "__imod__", "__ipow__",
    "__or__", "__xor__", "__and__", "__lshift__", "__rshift__", "__add__",
    "__sub__", "__mul__", "__matmul__", "__floordiv__", "__truediv__",
    "__mod__", "__pow__",
]
BINOP = {
    "LESS": 0, "MORE": 1, "EQUAL": 2, "LESS_EQUAL": 3, "MORE_EQUAL": 4,
    "NOT_EQUAL": 5, "IN": 6, "IS": 7, "EXCEPTION_MATCH": 8,
    "INPLACE_OR": 9, "INPLACE_XOR": 10, "INPLACE_AND": 11,
    "INPLACE_LSHIFT": 12, "INPLACE_RSHIFT": 13, "INPLACE_ADD": 14,
    "INPLACE_SUBTRACT": 15, "INPLACE_MULTIPLY": 16, "INPLACE_MAT_MULTIPLY": 17,
    "INPLACE_FLOOR_DIVIDE": 18, "INPLACE_TRUE_DIVIDE": 19, "INPLACE_MODULO": 20,
    "INPLACE_POWER": 21,
    "OR": 22, "XOR": 23, "AND": 24, "LSHIFT": 25, "RSHIFT": 26, "ADD": 27,
    "SUBTRACT": 28, "MULTIPLY": 29, "MAT_MULTIPLY": 30, "FLOOR_DIVIDE": 31,
    "TRUE_DIVIDE": 32, "MODULO": 33, "POWER": 34,
    # Not bytecode ops; the firmware and the RTL ALU use them.
    "CONTAINS": 35, "REVERSE_BASE": 36,
}
UNOP = {
    "POSITIVE": 0, "NEGATIVE": 1, "INVERT": 2, "NOT": 3, "BOOL": 4,
    "LEN": 5, "HASH": 6, "ABS": 7,
}

# ---------------------------------------------------------------------------
# SRAM map beyond pycore/docs/mpy_memory_map.md: the system root area and the
# argument staging buffer sit between the handler table and the GC pool.
SRAM_BASE = 0x2000_0000
SRAM_BYTES = 0x0004_0000
FRAME_BASE = SRAM_BASE
FRAME_BYTES = 0x8000      # frame stack; a call that would cross the end raises RuntimeError
SCHED_BASE = SRAM_BASE + FRAME_BYTES
HANDLER_BASE = SCHED_BASE + 0x40
SYSROOT_BASE = HANDLER_BASE + 0x40
SYSROOT_WORDS = 32
ARGBUF_BASE = SYSROOT_BASE + 4 * SYSROOT_WORDS
ARGBUF_WORDS = 256
ARGBUF_ARGS = 32          # first argument word; words 1..31 take prepended self and cells
GC_POOL_BASE = ARGBUF_BASE + 4 * ARGBUF_WORDS
GC_POOL_BYTES = SRAM_BASE + SRAM_BYTES - GC_POOL_BASE
GC_BLOCK_BYTES = 16

# System root words (all tagged, all GC roots).
SR = {
    "CUR_EXC": 0,       # exception being propagated
    "T0": 1, "T1": 2, "T2": 3, "T3": 4,   # core temporaries parked for a collection
    "MODULES": 5,       # sys.modules dict
    "MAIN": 6,          # __main__ module object
    "IRQ_EXC": 7,
    "T4": 8, "T5": 9, "T6": 10, "T7": 11,
    "FW0": 12, "FW1": 13, "FW2": 14, "FW3": 15,  # firmware state (_sysget/_sysset)
    "EMERG": 16,        # inline MemoryError object: words 16..20
    "FW4": 24, "FW5": 25, "FW6": 26, "FW7": 27,
}
EMERG_WORDS = 5

# Frame records sit back to back from FRAME_BASE (pycore/docs/mpy_core.md):
# a 16-word header, n_state state words, then 3 words per exception block.
# Raw header words carry tag 0, so the collector skips them.
FR = {
    "PREV": 0,       # raw: base of the caller's record
    "RC": 1,         # raw: raw-code descriptor
    "PC": 2,         # raw: resume address
    "OP_PC": 3,      # raw: address of the opcode being executed
    "STATE": 4,      # raw: sp | exc_sp << 8 | n_state << 16 | flags << 24
    "KIND": 5,       # raw: rk | cont << 8 | n_exc << 16
    "GLOBALS": 6,    # tagged
    "LOCALS": 7,     # tagged (dict for module and class bodies, else NULL)
    "FUN": 8,        # tagged: the function object being run
    "AUX": 9,        # tagged: continuation data
    "AUX2": 10,      # tagged
    "AUX3": 11,      # tagged
    "QBASE": 12,     # raw: module qstr table
    "CBASE": 13,     # raw: module const table
}
FRAME_HDR_WORDS = 16
FRAME_EXC_WORDS = 3       # handler, val_sp | finally << 31, prev_exc (tagged)
FRAME_EXC_ENTRIES = 16

# Return kinds: what happens to the value a frame returns.
RK = ["PUSH", "DISCARD", "CONT", "HALT", "PUSH_NULL"]
RK_ID = {name: i for i, name in enumerate(RK)}

# Continuations a caller frame waits in (FR CONT).
CONT = [
    "REDISPATCH",    # push the value, re-run the opcode at op_pc
    "REPLACE",       # write the value to stack slot AUX, re-run the opcode (AUX2: override)
    "INIT",          # __init__ returned: must be None, push AUX (the instance)
    "WITH_ENTER",    # __enter__ returned: push the finally block (AUX: handler), push the value
    "WITH_NONE",     # __exit__ returned on the normal path: push None
    "WITH_UNWIND",   # __exit__ returned on an unwind: push AUX, AUX2
    "WITH_EXC",      # __exit__ returned on an exception (AUX): swallow or re-raise
    "UNPACK",        # _unpack returned a tuple: push its items in reverse
    "RAISE",         # the value is an exception to raise
    "TRUTH",         # _truth returned a bool for the opcode at op_pc; re-run it
    "WITH_TRUTH",    # _truth of an __exit__ result: swallow or re-raise AUX
    "POP2_PUSH",     # drop two stack items, push the value
    "FOR_NEXT",      # __next__ returned: STOP ends the loop (AUX: exit pc), else push
    "GETITER",       # __iter__/_getiter returned: an iterator for slot AUX, re-run
    "INIT_ARGS",     # __init__ of an exception subclass returned: must be None, push AUX
    "BIND",          # _bind returned the locals tuple of this frame: store them and start
]

# One-shot overrides the REPLACE/GETITER/TRUTH continuations hand to the
# re-run opcode.
OVR = {"NONE": 0, "PYOBJ": 1, "TRUE": 2, "FALSE": 3}
CONT_ID = {name: i for i, name in enumerate(CONT)}

# Sim-control page words (0xE000_0000).
SIM_BASE = 0xE000_0000
SIM = {"HALT": 0, "STDERR": 1, "STDOUT": 2, "CYCLES": 3, "TRACE": 4}

HALT = {
    "CLEAN": 0, "UNCAUGHT": 1, "BAD_OPCODE": 2, "BAD_IMAGE": 3,
    "FLASH_STORE": 4, "UNALIGNED": 5, "BUS": 6, "STACK": 7, "STEP": 8,
    "INTERNAL": 9, "SYSEXIT": 10,
}


def _sv_lines() -> list[str]:
    out = [
        "// Generated by pycore/tools/mpy_abi.py --sv. Do not edit.",
        "`ifndef MPY_ABI_SVH",
        "`define MPY_ABI_SVH",
        "",
        f"localparam logic [31:0] ABI_IMAGE_MAGIC = 32'h{IMAGE_MAGIC:08X};",
        f"localparam logic [31:0] ABI_IMAGE_VERSION = 32'd{IMAGE_VERSION};",
        f"localparam logic [31:0] ABI_TYPE_TABLE = 32'h{TYPE_TABLE_BASE:08X};",
        "",
    ]

    def block(prefix: str, table: dict[str, int], width: int = 32) -> None:
        for name, value in table.items():
            out.append(f"localparam logic [{width - 1}:0] {prefix}{name} = {width}'d{value};")
        out.append("")

    block("ABI_TAG_", TAG, 4)
    block("ABI_CTL_", CTL)
    block("ABI_MUT_", MUT, 2)
    block("ABI_OVR_", OVR, 2)
    block("ABI_HDR_", HDR)
    block("ABI_RC_", RC)
    block("ABI_MD_", MD)
    block("ABI_OB_", OB)
    block("ABI_TF_", TF)
    block("ABI_IT_", IT)
    block("ABI_T_", {_sv_name(name): i for name, i in TYPE_ID.items()}, 8)
    block("ABI_N_", {_sv_name(n): i for n, i in NATIVE_ID.items()}, 8)
    block("ABI_HOOK_", {_sv_name(n): i for n, i in HOOK_ID.items()}, 8)
    block("ABI_ERR_", ERR_ID, 8)
    block("ABI_MSG_", MSG_ID, 8)
    block("ABI_MSGT_", {name: TYPE_ID[t] for name, t, _ in MSGS}, 8)
    block("ABI_SR_", SR, 8)
    block("ABI_FR_", FR, 8)
    block("ABI_RK_", RK_ID, 4)
    block("ABI_CONT_", CONT_ID, 8)
    block("ABI_SIM_", SIM, 8)
    block("ABI_HALT_", HALT, 4)
    block("ABI_BINOP_", BINOP, 8)
    block("ABI_UNOP_", UNOP, 8)
    scalars = {
        "RC_WORDS": RC_WORDS, "MD_WORDS": MD_WORDS,
        "FRAME_EXC_ENTRIES": FRAME_EXC_ENTRIES, "FIRST_EXC_TYPE": FIRST_EXC_TYPE,
        "SYSROOT_WORDS": SYSROOT_WORDS, "ARGBUF_WORDS": ARGBUF_WORDS,
        "ARGBUF_ARGS": ARGBUF_ARGS, "GC_POOL_BYTES": GC_POOL_BYTES,
        "GC_BLOCK_BYTES": GC_BLOCK_BYTES, "FRAME_BYTES": FRAME_BYTES,
        "FRAME_HDR_WORDS": FRAME_HDR_WORDS, "FRAME_EXC_WORDS": FRAME_EXC_WORDS,
        "EMERG_WORDS": EMERG_WORDS, "HEADER_WORDS": HEADER_WORDS,
        "SCOPE_GENERATOR": SCOPE_GENERATOR, "SCOPE_VARKEYWORDS": SCOPE_VARKEYWORDS,
        "SCOPE_VARARGS": SCOPE_VARARGS, "SCOPE_DEFKWARGS": SCOPE_DEFKWARGS,
        "RC_FLAG_FIRMWARE": RC_FLAG_FIRMWARE, "RC_FLAG_GENERATOR": RC_FLAG_GENERATOR,
        "DICT_FLAG_ROM": DICT_FLAG_ROM, "SET_FLAG_FROZEN": SET_FLAG_FROZEN,
        "LIST_WORDS": LIST_WORDS, "DICT_WORDS": DICT_WORDS,
        "STR_HDR_WORDS": STR_HDR_WORDS, "ITER_WORDS": ITER_WORDS,
        "N_TYPES": len(TYPES), "N_NATIVES": len(NATIVES),
    }
    for name, value in scalars.items():
        out.append(f"localparam int ABI_{name} = {value};")
    addrs = {
        "SYSROOT_BASE": SYSROOT_BASE, "ARGBUF_BASE": ARGBUF_BASE,
        "GC_POOL_BASE": GC_POOL_BASE, "FRAME_BASE": FRAME_BASE,
        "SCHED_BASE": SCHED_BASE, "HANDLER_BASE": HANDLER_BASE,
        "SIM_BASE": SIM_BASE, "SRAM_BASE": SRAM_BASE,
        "SRAM_END": SRAM_BASE + SRAM_BYTES, "FRAME_END": FRAME_BASE + FRAME_BYTES,
        "STR_NONASCII": STR_NONASCII, "QDESC_NONASCII": QDESC_NONASCII,
    }
    for name, value in addrs.items():
        out.append(f"localparam logic [31:0] ABI_{name} = 32'h{value:08X};")
    out.append("")
    for name in CORE_QSTRS:
        out.append(f"localparam logic [31:0] ABI_Q_{_q_name(name)} = 32'd{core_qstr_id(name)};")
    out.append("")
    out.append("`endif")
    return out


def _py_lines() -> list[str]:
    """Constants the firmware imports by name (pycore_firmware/mpy/fw/_abi.py)."""

    out = ["# Generated by pycore/tools/mpy_abi.py --sv. Do not edit."]

    def block(prefix: str, table: dict[str, int]) -> None:
        for name, value in table.items():
            out.append(f"{prefix}{name} = const({value})")

    out.append("from micropython import const")
    block("TAG_", TAG)
    block("CTL_", CTL)
    block("MUT_", MUT)
    block("OB_", OB)
    block("TF_", TF)
    block("IT_", IT)
    block("T_", {_sv_name(name): i for name, i in TYPE_ID.items()})
    block("ERR_", ERR_ID)
    block("SR_", SR)
    block("BINOP_", BINOP)
    block("UNOP_", UNOP)
    block("HDR_", HDR)
    block("RC_", RC)
    block("MD_", MD)
    block("FR_", FR)
    block("SCOPE_", {"GENERATOR": SCOPE_GENERATOR, "VARKEYWORDS": SCOPE_VARKEYWORDS,
                     "VARARGS": SCOPE_VARARGS, "DEFKWARGS": SCOPE_DEFKWARGS})
    out.append(f"FRAME_HDR_WORDS = const({FRAME_HDR_WORDS})")
    out.append(f"SYSROOT = const({SYSROOT_BASE})")
    out.append(f"STR_NONASCII = const({STR_NONASCII})")
    out.append(f"FIRST_EXC_TYPE = const({FIRST_EXC_TYPE})")
    out.append(f"N_TYPES = const({len(TYPES)})")
    out.append(f"TYPE_TABLE = const({TYPE_TABLE_BASE})")
    out.append(f"DICT_FLAG_ROM = const({DICT_FLAG_ROM})")
    out.append(f"SET_FLAG_FROZEN = const({SET_FLAG_FROZEN})")
    out.append(f"RC_FLAG_FIRMWARE = const({RC_FLAG_FIRMWARE})")
    out.append(f"GC_POOL_BYTES = const({GC_POOL_BYTES})")
    return out


def _sv_name(name: str) -> str:
    text = name.replace(".", "_").upper()
    while "__" in text:
        text = text.replace("__", "_")
    return text.strip("_") or "X"


def _q_name(name: str) -> str:
    if name == "":
        return "EMPTY"
    if name == "<module>":
        return "MODULE_NAME"
    return name.strip("_").upper() + ("_D" if name.startswith("__") else "")


def _check_unique() -> None:
    for label, names in (
        ("type", list(TYPE_ID)),
        ("native", NATIVES),
        ("hook", HOOKS),
    ):
        seen: dict[str, str] = {}
        for name in names:
            key = _sv_name(name)
            if key in seen:
                raise SystemExit(f"{label} names {seen[key]!r} and {name!r} collide as {key}")
            seen[key] = name
    q = [_q_name(n) for n in CORE_QSTRS]
    if len(set(q)) != len(q):
        raise SystemExit("core qstr names collide")


_STATIC: list[str] | None = None


def static_qstrs() -> list[str]:
    global _STATIC
    if _STATIC is None:
        import json

        catalog = json.loads((REPO_ROOT / "pycore" / "targets" / "mpycore.json").read_text())
        _STATIC = list(catalog["static_qstrs"])
    return _STATIC


def core_qstr_order() -> list[str]:
    """Static qstrs (pin ids), then the non-static core qstrs."""

    static = static_qstrs()
    extra = [q for q in CORE_QSTRS if q not in static]
    extra += [q for q in BINOP_NAMES if q and q not in static and q not in extra]
    return static + extra


def core_qstr_id(name: str) -> int:
    return core_qstr_order().index(name)


def qstr_hash(data: bytes) -> int:
    h = 5381
    for b in data:
        h = ((h << 5) + h) ^ b
    h &= 0xFFFF
    return h or 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sv", action="store_true", help="write mpy_abi.svh and the firmware _abi.py")
    parser.add_argument("--check", action="store_true", help="fail if either generated file is stale")
    args = parser.parse_args(argv)
    _check_unique()
    sv_text = "\n".join(_sv_lines()) + "\n"
    py_text = "\n".join(_py_lines()) + "\n"
    if args.sv:
        SV_PATH.write_text(sv_text)
        PY_PATH.parent.mkdir(parents=True, exist_ok=True)
        PY_PATH.write_text(py_text)
        print(f"wrote {SV_PATH.relative_to(REPO_ROOT)} and {PY_PATH.relative_to(REPO_ROOT)}")
        return 0
    if args.check:
        stale = [p for p, t in ((SV_PATH, sv_text), (PY_PATH, py_text)) if not p.exists() or p.read_text() != t]
        if stale:
            names = ", ".join(str(p.relative_to(REPO_ROOT)) for p in stale)
            print(f"{names} stale: run python3 pycore/tools/mpy_abi.py --sv", file=sys.stderr)
            return 1
        print("mpy-abi: ok")
        return 0
    parser.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
