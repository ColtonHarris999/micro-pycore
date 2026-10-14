# MicroPython bytecode

The pinned bytecode is MicroPython v1.29.0. Operand format, stack
effect, and the phase that executes each opcode are rows in
[`pycore/targets/mpycore.json`](../targets/mpycore.json), copied from
`py/bc.h` and `py/bc0.h`. This page does not repeat those numbers.

There is no `CACHE` opcode and no `EXTENDED_ARG` word. An instruction is
a byte plus a variable-length operand: nothing, a qstr index, an
unsigned or signed varuint, or a relative jump offset of one or two
bytes. A few instructions carry one extra byte after that operand.
Jump offsets are applied after the offset bytes have been consumed.
Signed offsets are biased. Multi-opcode ranges fold a small immediate
into the opcode byte: a window of small ints, the first locals for load
and store, and the unary and binary groups.

With persistent code, a qstr operand indexes the module qstr table and
`LOAD_CONST_OBJ` indexes the module const table. `MAKE_FUNCTION` indexes
the child raw-code table. The bytes are not patched at run time.

## Prelude

A function body starts with the bit-interleaved prelude in `py/bc.h`.
The signature carries `n_state`, `n_exc_stack`, the four scope-flag bits,
`n_pos_args`, `n_kwonly_args`, and `n_def_pos_args`. `n_state` counts
Python values and is stored as `n_state - 1`. A second interleaved value
carries the source-info length and the closure-cell count. The
source-info bytes are the simple name, the argument names, and the
line-number encoding. One byte per cell follows. The first opcode is
the next byte.

`pycore/tools/mpy_prelude.py` returns that opcode-start offset and the
line-info span. The span starts after the name qstrs and ends at the
first closure byte, so the line-number bytes are not fetched as code.
Phase 4 tracebacks use the span. The four scope-flag bits are generator,
`**kwargs`, `*args`, and a keyword-default dict. Positional defaults are
`n_def_pos_args`, not one of those bits.

## Phase 1 check

`python3 pycore/tools/mpy_image.py --check pycore/programs/mpy/phase1`
compiles each fixture with the pinned `mpy-cross`, diffs the
disassembly against `vendor/micropython/tools/mpy-tool.py -xd` on the
same `.mpy`, and links a flash image. The fixture set has a branch with
both offset sizes, a static qstr, a non-static qstr, a small int outside
the multi-opcode window, a tuple const, and a child function. A
native-architecture fixture fails the link, and the error names that
architecture.
