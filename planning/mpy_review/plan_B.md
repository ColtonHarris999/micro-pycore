# MicroPython microcontroller core

Status: **plan, not started.** Audit snapshot: [pycore](https://github.com/ColtonHarris999/pycore) `main` @ `371dc007f9`, 2026-10-13.
Review: [findings](#review-findings) against MicroPython `v1.29.0`, 2026-10-14. Those findings are open. Where one disagrees with a phase bullet, the finding wins until a later revision of the locks accepts or rejects it.

This file moved here from pycore branch `cursor/micropython-mcu-plan-3b27`
(`bbcd1d9328`). This repository is the sibling tree that plan calls
`mpycore/`. Paths below that start with `mpycore/` are directories in
this repository. Paths that start with `pycore/`, `excore/`, or
`pycore_firmware/` are paths in the pycore repository. The CPython hart
is not copied here, and nothing in `pycore/rtl/` is retargeted in place.

The product use case is changing from a CPython 3.14 bytecode research CPU
to **MicroPython on a microcontroller-style core**. This file is the
roadmap for that switch. The CPython hart stays in pycore and stays
green. New feature work happens in this repository.

[pycore `planning/master_plan.md`](https://github.com/ColtonHarris999/pycore/blob/371dc007f9499ff537b8451f8688b83e731d2e1d/planning/master_plan.md)
remains the leftover list for the CPython hart. Do not start a track
there unless this plan says the hart still needs it.

## Where the truth lives

```text
planning/micropython_mcu_plan.md   this switch (product direction), in this repo
pycore planning/master_plan.md     leftover CPython-hart work, frozen for features
        │
        ▼
mpycore/docs/*                     the new machine, written as each phase lands
mpycore/targets/mpycore.json       opcode / repr / memory-map catalog (phase 0)
vendor/micropython                 pinned oracle (phase 0 submodule)
        │
        ▼
pycore/docs/*                      the CPython hart as built; still accurate
```

Do not copy MicroPython opcode lists or object bit-masks into this file.
Phase 0 records them from the pinned release's `py/bc.h`, `py/obj.h`, and
`py/persistentcode.h` into `mpycore/targets/mpycore.json`.

## What is being built

A 32-bit core whose instruction stream is a pinned MicroPython bytecode,
whose data memory is a few hundred kilobytes of tightly coupled SRAM, and
whose peripherals are memory-mapped. Programs arrive as frozen `.mpy`
modules. The golden output is that release's unix port.

v1 is a single hart. Container growth is a command FSM on that hart. A
timer or UART interrupt is noticed at the next bytecode boundary and runs
a frozen callback. Float, long integers, an on-device compiler, and
generators are later decisions, each with its own exit test.

## Audit of the machine at `371dc00`

The hart that exists is a research CPU. Its ISA is a CPython 3.14
wordcode subset. These are the facts the switch has to account for.

### Datapath and instruction encoding

| Fact | Where |
| --- | --- |
| Value is 128 bits, tag is 4 bits, register entry is 132 bits | `PYCORE_VAL_WIDTH`, `PYCORE_TAG_WIDTH` in `pycore/rtl/pycore_defs.svh` |
| Register file is 256 entries, live window 240, spill to a 256 KB LIFO at `0xF40000` | `PYCORE_RF_DEPTH`, `memory_hierarchy.md` data map |
| One instruction is a 40-bit word in an 8-byte slot: `arg[31:0]` then `opcode[7:0]` | `format_imem_slot` in `pycore/tools/encoding.py` |
| Fetch folds `CACHE` and `EXTENDED_ARG` inside a 64-byte line | `pycore/docs/memory_hierarchy.md` |
| 95 catalogued opcodes: 70 `execute`, 8 `partial`, 13 `trap`, 3 `reject`, 1 `strip` | `pycore/targets/pycore.json`, `bytecode_support.md` |
| Documented synthesis of the hart: about 86.5k cells / 4.8k flops. The power unit alone is about 19.7k cells | `pycore/docs/limitations.md` L-ALU-4 |

### Memory

| Region | Size | Role |
| --- | ---: | --- |
| L1I / L1D | 8 KB, 4-way, 64 B lines | 1-cycle hit |
| L2 | 128 KB, 8-way | 8-cycle hit, unified |
| Data window | 16 MB | heap from `0x440` to `0xF00000` (~15 MB free after the boot image) |
| Code ROM | 8192 slots | firmware builtins |
| Code RAM | 131072 slots (1 MB of slot bytes) | on-device compiler and `exec` |
| Behavioral RAM | 16 MB | `+MEM_LATENCY=` model, CI default 4 |

GC is a precise mark-sweep collector, off unless `+GC_EN=1`. It collects
only at an instruction boundary, and only after the allocating instruction
has aborted before its first architectural commit (`pycore/docs/gc.md`).
The on-chip mark bitmap for the 16 MB heap is 120 KB.

### The rest of the system

- **Second hart.** `excore/` is an RV32 core. Recoverable traps cross
  `trap_mailbox.sv`. Fatal traps halt. The contract is "finish the
  semantic effect," and the trap fires before commit
  (`pycore/docs/architecture.md`).
- **Container accelerator.** `pycore_ca.sv` now performs list append /
  extend / delete and dict / set growth on the Python hart. Data-ready
  and container-ready are the same cycle, and the hart stays frozen for
  the command (`pycore/docs/container_accel.md`, landed in #154). The
  mailbox path is still the fallback and still owns console `print`.
- **On-device compiler.** `pycore_firmware/compiler/` is about 14,000
  lines of the Python subset. It tokenizes, parses, and emits CPython
  3.14 wordcode. `master_plan.md` recorded the resident package at
  56,469 code slots on an older snapshot. `compile()` keeps roughly
  10–16 KB of heap per source line.
- **Builtins.** 86 firmware modules under `pycore_firmware/builtins/`,
  about 4,000 lines, plus native `BI_*` ids in the CALL FSM. Many modules
  are unseeded stubs.
- **Objects.** Sixteen 4-bit tags. Heap objects under `PY_TAG_OBJECT`
  use a 16-byte header and 32-byte field stride (`pycore/docs/object_model.md`).
  Strings are a separate tag plus STRACC (`pycore_str_accel.sv`, about
  2,800 lines).
- **Language the hart actually runs.** Functions, closures, module-level
  classes folded at image build, containers, `try`/`except`/`finally` on
  the CPython 3.14 exception table, ROM `compile` / `exec` / `eval`.
  Missing for an MCU program: `import`, runtime `class`, `with`,
  generators, and catchable `TypeError` / `ZeroDivisionError` /
  `IndexError` / `KeyError` from hardware traps (`planning/master_plan.md`
  tracks 2 and 3).
- **Oracle and tests.** Host CPython 3.14 builds images and is the stdout
  oracle (`make run-file`, `make test-compiler-vs-cpython`). About 520
  programs live under `pycore/programs/`. RTL is about 82,000 lines of
  SystemVerilog including headers. `pycore_defs.svh` alone is about 3,800
  lines and is included across the core.
- **The only peripheral.** `CONSOLE_TX` at `0xF0` accepts one output byte
  (`excore/docs/mmio_map.md`). There is no GPIO, timer, UART RX, or IRQ
  line into the Python hart.

### What that shape costs

The research machine is large because each CPython value can be a 64-bit
int, a binary64, a complex, or a heap handle, and because the comparison
point is a desktop interpreter with a cache hierarchy. An MCU program
does not need that value width, that cache model, or opcode-for-opcode
identity with CPython 3.14. The pieces that match an MCU are smaller:
collect at a safe point before commit, finish a container command before
anyone observes the object, and treat MMIO as a store.

## MicroPython, as the target runtime

Phase 0 pins one stable release as a submodule at `vendor/micropython`.
The unix port of that tag is the oracle. `mpy-cross` from that tag emits
the bytecode. These properties are stable across recent releases; the
exact opcode numbers and bit-masks are not, so they are read from the tag
rather than written here.

- **Bytecode** is a variable-length byte stream. The first byte is the
  opcode. Some opcodes fold a small immediate into the opcode byte (the
  multi-opcode ranges). Every other operand is a variable-length unsigned
  integer, a relative jump, or a qstr index into that module's table. A
  function body starts with the bit-interleaved prelude in the tag's
  `py/bc.h`: stack depth, exception-stack depth, scope flags, argument
  counts, then source-info and closure-cell bytes, then the opcodes. The
  first opcode is not at a fixed offset. The persistent file is `.mpy`.
  There is no `CACHE` opcode and no `EXTENDED_ARG` word. v6 bytecode is
  not rewritten at run time. Finding F2 is the loader contract.
- **Names** are qstrs, integer indexes into a pool of interned strings.
  Globals and attributes key on qstr. A bytecode operand is an index into
  the module's qstr table, not a global id and not a pointer. Static ids
  at or below the tag's `QSTR_LAST_STATIC` are shared with `mpy-cross`
  and are stored as ids, not as text.
- **The object word** on a 32-bit port is `MICROPY_OBJ_REPR_A` in
  `py/obj.h`: a small int, a qstr, a handful of immediates (`None`,
  `False`, `True`), or a pointer to a heap object. v1 copies that encoding.
- **Small int** is 31 bits in a 32-bit word. With long integers disabled
  (`MICROPY_LONGINT_IMPL_NONE`), overflow raises `OverflowError`.
- **Float and complex** are compile-time options. v1 leaves both off.
  Strings are UTF-8. Identifiers are qstrs; other strings are heap objects.
- **GC is always on.** Allocation failure collects. The collector is
  mark-sweep over one heap, with a side table of per-block state. Roots
  are explicit on this core. Finding F4 is the root set and the stall
  rule. The C VM does not abort an opcode and re-dispatch it.
- **Libraries are frozen modules** in flash. `import` loads a frozen
  `.mpy`. The on-device compiler is a build option and is large; v1
  leaves it out. The host cross-compiler is the toolchain.
- **Peripherals** are the `machine` module: Pin, UART, SPI, I2C, Timer.
  v1 builds UART, GPIO, and one timer. SPI and I2C wait until a program
  needs them.
- **Interrupts** do not run arbitrary Python inside the latch. A pending
  IRQ is latched in the peripheral block. `micropython.schedule` queues a
  callback for the VM's pending check. The latch path does not allocate.
  Finding F6 is the queue depth, the callback argument, and the fact that
  the callback itself may allocate.
- **Concurrency** in the ecosystem is cooperative (`asyncio`). Threads are
  out of v1. Generators and `async` change the frame layout, so they are
  their own later phase.

## v1 locks

These are decided. Changing one is a revision of this plan, not a local
RTL tweak.

| Lock | Choice |
| --- | --- |
| Tree | `mpycore/`. No `ifdef` inside `pycore_core.sv` |
| Oracle | Pinned MicroPython unix port, stdout compare |
| Toolchain | That tag's `mpy-cross`. New flash-image tool. `image_from_source.py` stays on the CPython path |
| Object word | 32-bit `MICROPY_OBJ_REPR_A`, masks copied from the tag's `py/obj.h` |
| Integers | 31-bit small int. Overflow raises `OverflowError` |
| Float, complex, long int | Off |
| Code memory | Flash, byte-addressed, execute in place. PC is a byte address |
| Data memory | One SRAM. The Python stack is an array of object words inside it |
| GC | Always on. Safe point is a bytecode boundary, after an aborted opcode with no architectural commit |
| Harts | One. Slow container work is a command FSM on this hart |
| Interrupts | Latched in the peripheral block. Handled at dispatch. One schedule queue of frozen callbacks |
| Compiler on device | Absent |
| Success metric | Stdout matches the unix port. Cycle counts are recorded. They are not a ratio against CPython |

Finding F4 replaces the GC row's "abort, then re-dispatch" with a stall
inside the allocating opcode. The row stays so the original choice remains
visible. Finding F1 replaces "the unix port" with a 32-bit build of that
port configured like v1.

### Memory map

Addresses follow the split used by Cortex-M memory maps: code low, SRAM
at `0x2000_0000`, peripherals at `0x4000_0000`. Sizes are the v1 product
point. A smaller SRAM is a later parameter, after a program has run at
256 KB.

| Window | Base | Size | Contents |
| --- | --- | ---: | --- |
| Flash | `0x0000_0000` | 512 KB | frozen `.mpy`, qstr pool, builtin bytecode |
| SRAM | `0x2000_0000` | 256 KB | GC heap, value stack, exception stack |
| MMIO | `0x4000_0000` | 4 KB | UART TX/RX, GPIO, timer, IRQ pending and enable |
| Sim control | `0xE000_0000` | 256 B | halt reason, cycle counter. Simulation only |

SRAM is 1-cycle. Flash has a wait-state parameter defaulting to 1 in
simulation. There is no L2 and no 16 MB backing RAM in the programming
model. A one-line fetch buffer may be added later if flash wait states
show up in a measurement; it is not part of v1.

### Peripheral registers (v1)

Word offsets from `0x4000_0000`. Phase 5 is allowed to add registers. It
is not allowed to move these four.

| Offset | Name | Access |
| --- | --- | --- |
| `0x00` | `UART_TX` | write `[7:0]`; the simulator prints the byte |
| `0x04` | `UART_RX` | read `[7:0]`; bit 31 is data-valid |
| `0x08` | `GPIO_OUT` | write the output word |
| `0x0C` | `TIMER_COUNT` | read free-running counter; write reloads the compare |
| `0x10` | `IRQ_STATUS` | read pending, write-1-to-clear |
| `0x14` | `IRQ_ENABLE` | read/write mask. Bit 0 timer, bit 1 UART RX |

`CONSOLE_TX` at `0xF0` stays on the CPython hart. The new UART is a
different register on a different map.

## Disposition of the current tree

| Piece | Disposition |
| --- | --- |
| Verilator flow, one shared simulator, plusargs, program-vs-oracle tests | **Reuse the shape.** New target name, new oracle binary |
| Safe-point GC rule in `pycore/docs/gc.md` (abort, then collect, then re-dispatch) | **Reuse the rule.** New engine, new root set, 256 KB heap |
| CA command rule in `pycore/docs/container_accel.md` (finish the object before a reader sees it; hart frozen in v1) | **Reuse the rule.** New FSM over 32-bit object words |
| Integer add / sub / compare algorithms | **Rewrite at 31 bits.** The 64-bit units and the overflow-to-bigint trap do not come along |
| `CONSOLE_TX` as "a store is a printed byte" | **Reuse the idea** at `UART_TX` |
| `pycore.json`, 40-bit slots, 132-bit RF, frame descriptors, GIC, CODC | **Stay with the CPython hart** |
| L1/L2, 16 MB RAM model, STRACC, FPU, complex, `pycore_fp_pow.sv` | **Stay with the CPython hart** |
| `excore/` RV32, mailbox, container firmware | **Stay with the CPython hart.** v1 has no second ISA |
| On-device compiler, `image_from_source.py`, CPython exception tables | **Stay with the CPython hart** |
| `planning/accelerator_split_plan.md` | **CPython-hart design.** Its console-as-a-store idea is already extracted above. The container-accelerator follow-ons are not MCU work |
| `code_loading.md` §4 relocation format | **CPython code-object format.** Frozen `.mpy` is a different loader |
| Research cycle ratios vs CPython (`pycore/docs/research_comparison.md`) | **Historical for the CPython hart.** The new scoreboard is stdout against the unix port |

`pycore_core.sv` (about 4,900 lines), `pycore_defs.svh`, and the container
FSMs are opcode-specific. They are not a source base for `mpycore`. The
new core is a new fetch, decode, stack, and call FSM. Expected v1 RTL is
the integer subset plus GC plus three peripherals, which is a much smaller
machine than 82,000 lines.

## Phases

Each phase ends with a test that a later phase is not allowed to break.
Host tests do not need Verilator. Device tests share one `mpycore`
simulator.

### Phase 0 — Pin the release

Docs, catalog, submodule. No RTL.

- Add `vendor/micropython` at one stable tag. Record the tag, the `.mpy`
  version, and the sub-version from that tag's `py/persistentcode.h` in
  `mpycore/targets/mpycore.json`.
- Copy object-word masks from that tag's `py/obj.h` into the same JSON.
- List v1 opcode families by the names in that tag's `py/bc.h`: load and
  store of locals and globals, small-int const, jumps, unary and binary
  ops that v1 implements as small-int only, call, return, and the prelude
  fields the call path reads. Families that wait (import, class, yield,
  with) are listed as `later` with the phase number.
- Write `mpycore/docs/memory_map.md` with the table in "Memory map" above.
- The CPython hart's `planning/master_plan.md` stays in pycore. Phase 0
  does not edit that file and does not delete CPython tracks.

**Exit.** `mpycore.json` round-trips a unit test that checks the recorded
`.mpy` version against the submodule headers. Phase 0 does not edit
pycore. Finding F8 is part of this exit. The CPython hart's `make` is
not a check this repository can run.

### Phase 1 — Flash image and oracle harness

- Host tool reads a `.mpy` from `mpy-cross` and lays out flash: qstr
  pool, const objects that are immediates or qstrs, raw bytecode.
- A diff harness runs the same source on the unix port and stores stdout.
- Prelude decoder: state size, exception-stack size, flags. Covered by a
  host test per function kind the v1 call path accepts (module body, plain
  function, function with defaults if the pinned emitter produces them).

**Exit.** A frozen function that returns `1 + 2` has a decoded prelude and
a const pool the host test can print. No simulator yet.

### Phase 2 — Integer core

New RTL: byte fetch, decode, SRAM stack pointer, small-int ALU, jumps,
call and return using the prelude, `print` of a small int via `UART_TX`.

In scope: load/store local, load const small int, binary arithmetic and
compare on small ints, unconditional and conditional jumps, call of a
frozen function with positional arguments, return.

Out of this phase: heap allocation, GC, globals beyond a single module
dict of immediates, closures, classes.

**Exit.** Frozen sources for `print(1 + 2)` and a counted loop match the
unix port's stdout on the simulator. Cycle count is printed and not
compared to CPython.

### Phase 3 — Heap, containers, GC

- Heap objects for `str`, `bytes`, `list`, `tuple`, `dict`, keyed the way
  the pinned runtime behaves. Layout may differ from CPython's 32-byte
  stride and from MicroPython's C structs; behavior is what the unix port
  checks.
- Mark-sweep, always on, over the 256 KB SRAM. An allocation that does not
  fit aborts the bytecode before commit, collects, and re-dispatches.
  Roots are the live stack slice, the module globals, and machine registers
  that hold object words. Document that root set in `mpycore/docs/gc.md`
  before writing the engine.
- List and dict growth is a command FSM on this hart: double, copy, finish
  the insert, then report the command done. The hart is frozen for the
  command, matching today's CA stage A0.

**Exit.** Appending in a loop grows the list and matches unix-port
stdout. A loop that allocates and drops references stays inside 256 KB
and matches stdout. A program that retains more than the heap raises
`MemoryError` the way the unix port does with a heap of the same size
(the unix port is run with a matching heap limit).

### Phase 4 — The language an MCU program uses

- Exceptions are values. `raise` and `except` work. Hardware results that
  are Python exceptions on the unix port are Python exceptions here:
  `TypeError`, `ZeroDivisionError`, `OverflowError`, `IndexError`,
  `KeyError`, `MemoryError`, `AttributeError`. Unhandled exception halts
  the simulator with a reason code and a traceback written to `UART_TX`.
- Runtime classes and bound methods, to the extent the pinned bytecode
  emits them.
- `import` of another frozen module in the same flash image.
- `with`, because drivers use it and the bytecode support is a small
  number of opcodes once exceptions exist.

**Exit.** One flash image with two modules: a class with a method, a
`try`/`except` around a divide by zero, and a `with` that calls `__enter__`
and `__exit__`. Stdout matches the unix port.

### Phase 5 — Microcontroller surface

- GPIO, UART RX, one timer, the IRQ registers in the table above.
- At bytecode dispatch, if an enabled IRQ is pending, the core runs the
  scheduled frozen callback to completion (v1 callbacks do not nest), then
  continues. The latch does not allocate. A callback that would allocate
  raises `MemoryError` at the first allocating opcode, which is a normal
  exception, not a halt inside the peripheral block.
- Simulator peripheral model: a testbench can push RX bytes and advance
  the timer.

**Exit.** A frozen blink program toggles `GPIO_OUT` on the timer IRQ and
the testbench observes the edges. An echo program copies UART RX to
UART TX. Both match a host model of the same registers driven by the
unix port's output where the program also `print`s.

### Phase 6 — Separate decisions

Each item is unstarted until a program needs it. Landing one does not
imply the next.

| Item | Trigger | Constraint |
| --- | --- | --- |
| Single-precision float | A frozen program contains a float const or a float opcode the emitter actually emits | New unit. The CPython binary64 FPU and `pycore_fp_pow.sv` stay where they are |
| Long integers | A program overflows 31 bits and the product requirement is "compute it" rather than `OverflowError` | Heap representation and software arithmetic. Small-int fast path stays |
| Generators and `async` | A program needs `uasyncio`-style concurrency beyond a timer callback | New frame state. Do this before promising a scheduler richer than phase 5 |
| On-device compiler | A REPL must accept source text | A MicroPython compiler frozen into flash, emitting the pinned bytecode. The 14,000-line CPython compiler is the wrong source |
| SPI, I2C, ADC | A driver needs the registers | Same MMIO window, new offsets, same IRQ rule |
| Fetch buffer | A measurement shows flash wait states dominating a real program | One line. This does not introduce an L2 |

## What stays frozen on the CPython hart

Bugfixes that keep `make test-hw` and `make test-compiler-vs-cpython`
green still land. The following feature work does not start:

- Self-hosting `compile()`, further grammar, and the module loader in
  `master_plan.md` track 1.
- Trap-to-exception tracks T6–T12 and new CPython opcodes in tracks 2 and 3.
  The same user-visible goals (catchable `TypeError`, classes, `import`,
  `with`) are phases 4 and 5 of this plan, on the new bytecode.
- Remaining accelerator-split phases aimed at the CPython hart.
- Turning the 16 MB collector on by default, and the bigint / complex-pow
  lifts in `pycore/docs/limitations.md`.
- New ROM builtins whose only purpose is CPython dict coverage.

`planning/cleanup_report.md` still applies to the CPython tree. It is not
a source of `mpycore` tasks.

## Non-goals

- Executing CPython 3.14 wordcode on `mpycore`.
- Bit-identical heap layouts with MicroPython's C structs. The unix port
  compares observable results.
- A second general-purpose core that runs the MicroPython C VM. `excore/`
  is already an RV32; the product is a bytecode hart with MCU memory and
  peripherals.
- Deleting the CPython hart, its tests, or `docs/paper/`. Those remain the
  record of the research machine.
- FPGA board bring-up. Simulation is the acceptance environment, the same
  rule as `pycore/docs/architecture.md`.
- Matching CPython cycle ratios, or keeping `make run-file`'s on-device
  `compile()` as the demo. The new demo is a frozen `.mpy` plus UART output.
- `match`, `except*`, format-spec f-strings, and the CPython descriptor
  protocol. If the pinned MicroPython accepts a program, v1 still only
  claims the phases above.

## Risks

- **Bytecode moves between releases.** Mitigation is the pin. A second
  release is a new JSON catalog and a new submodule commit, not a runtime
  flag.
- **The loader is the fragile host tool.** `.mpy` const encoding and the
  prelude have to match the tag's writer. Phase 1 tests decode against
  that writer before any RTL fetches a byte.
- **Roots.** MicroPython's C port scans a C stack. This core has an
  explicit root set. Writing that set down in phase 3, before the engine,
  is what keeps the collector from freeing an object the unix port still
  holds. Stdout tests do not catch a missed root that happens to survive
  until halt; phase 3 includes one test that allocates past a dropped
  reference and checks that a later allocation succeeds. Finding F4
  extends that root set to every live frame, the exception stack, the
  builtins dict, and the schedule queue, and it drops opcode re-dispatch.
- **256 KB will not hold the current on-device compiler.** That is the
  point of leaving it on the CPython hart. Phase 6's compiler, if it
  happens, has to fit in flash and use the 256 KB heap.
- **Two roadmaps.** Agents will keep opening CPython opcode work. The
  stop-list above is the constraint. That work stays in pycore.
- **CA and excore both exist today.** v1 follows the CA's single-hart
  command shape. Porting `pycore_ca.sv` itself would drag in 132-bit
  entries and the 16 MB heap pointer. The new FSM is new RTL that follows
  the written rule.

## Review findings

Reviewed 2026-10-14 against MicroPython `v1.29.0` (`py/bc.h`, `py/bc0.h`,
`py/obj.h`, `py/persistentcode.c`, `py/vm.c`, `py/gc.c`, `py/objfun.c`,
`py/objlist.c`, `py/runtime.c`, `py/smallint.c`, `py/modbuiltins.c`,
`py/scheduler.c`, `ports/unix`, `mpy-cross`). This plan has not pinned a
tag. The citations are the current stable line, so phase 0 still has to
read them from whatever tag it pins. Nothing here copies an opcode number
or an object mask into the catalog.

### F1. The oracle is a configured 32-bit build, not a default unix port

`ports/unix` on a 64-bit host uses `MICROPY_OBJ_REPR_A` in a 64-bit word,
so small ints are 63 bits. `ports/unix/variants/mpconfigvariant_common.h`
defaults float to IEEE binary64 and long ints to `MICROPY_LONGINT_IMPL_MPZ`.
`ports/unix/main.c` sets the default heap to `1MB * sizeof(mp_uint_t) / 4`,
which is 2MB on that host. Finalisers are on. `MICROPY_ENABLE_PYSTACK` is
off, so the Python stack is the C stack and is not part of the GC heap.
Unhandled exceptions go to stderr (`MICROPY_ERROR_PRINTER`).
`sys.platform` is `linux`.

`print(1 + 2)` matches that binary. A program that overflows 31 bits,
divides with `/`, prints a traceback, or exhausts memory does not. The
phase 2 exit test does not catch the mismatch.

`mpy-cross` already defaults to 31-bit small ints and to bytecode-only
(`mpy-cross/main.c`: `small_int_bits = 31`, native arch none unless
`-march` is passed). The same binary still has double and mpz turned on,
and `MICROPY_COMP_CONST_FOLDING` folds numeric expressions in
`py/parse.c` (`fold_constants` covers `+ - * / % //` and `**`). A folded
`1 / 2` or `2 ** 40` is stored as `MP_PERSISTENT_OBJ_FLOAT` or
`MP_PERSISTENT_OBJ_INT`. The image tool rejects those encodings in v1,
and the unix oracle is built so that it rejects the same source.

Phase 0 records one config fragment and uses it three ways.

- `mpy-cross` flags: `-msmall-int-bits=31`, no `-march`.
- Unix oracle: `mp_int_t` is 32 bits, long int none, float none, complex
  none, finalisers off, one pinned `MICROPY_ERROR_REPORTING`, one pinned
  scheduler depth. v1.29 has no 32-bit `REPR_A` that runs in a 64-bit
  process. `REPR_C` requires float. The oracle is a 32-bit compile, not
  `make` in `ports/unix`.
- RTL: the same integer width, the same rejected const kinds, the same
  error strings. With long ints disabled, overflow text is
  `small int overflow` (`py/objint.c`). Terse and detailed reporting do
  not share strings.

The harness compares stdout and stderr separately. Tracebacks are not
stdout. Programs under test do not print `sys.platform` or
`sys.implementation` unless those strings are pinned to the same values
on both sides.

### F2. `.mpy` is a container, and bytecode operands are indices

Execute-in-place fits v6 bytecode. The bytes are not patched at run time.
The old map-cache flag is gone from the v6 header. Mapping a raw `.mpy`
file in as the instruction stream does not.

The file is a header (`M`, version, feature/arch byte, small-int bits),
an optional architecture-flags vuint, one qstr table, one const-object
table, then a tree of raw-code objects (`py/persistentcode.c`). Each raw
code can have children. A class body (`SCOPE_CLASS` in `py/compile.c`),
a nested `def`, and a comprehension (`SCOPE_LIST_COMP`) are children, not
more bytes in the parent. Phase 1's "qstr pool, immediate consts, raw
bytecode" drops the per-module tables and the child tree. Phase 4's
second module is a second `.mpy` with its own tables.

When persistent code is enabled, `MICROPY_EMIT_BYTECODE_USES_QSTR_TABLE`
is on and `DECODE_QSTR` in `py/vm.c` indexes the module's `qstr_table`.
`LOAD_CONST_OBJ` indexes `obj_table`. `MAKE_FUNCTION` indexes
`child_table`. Static qstrs at or below `QSTR_LAST_STATIC`
(`MP_QSTR_zip` in v1.29) are stored as ids, not as UTF-8. The image ships
the tag's static pool from `makeqstrdata.py` at those ids. `print` is
resolved through that pool.

The prelude is not three integers in front of the opcodes. `py/bc.h`
interleaves `n_state - 1`, `n_exc_stack`, four scope flags, `n_pos_args`,
`n_kwonly_args`, and `n_def_pos_args` into one vuint, then interleaves
source-info size and closure-cell count into a second vuint, then the
source-info bytes (function name, argument names, line numbers) and one
byte per cell. A decoder that stops at "state size, exception-stack size,
flags" fetches source info as code. Phase 4 tracebacks need the
line-number bytes. The scope flags that change the call sequence are
`MP_SCOPE_FLAG_VARARGS`, `MP_SCOPE_FLAG_VARKEYWORDS`, and
`MP_SCOPE_FLAG_DEFKWARGS` (`py/runtime0.h`). No phase owns them.

Const tags the image tool accepts or rejects explicitly: `None`, `False`,
`True`, ellipsis, str, bytes, int, float, complex, tuple, and, for native
files, the fun table. Ellipsis, `()`, and `b''` are ROM singletons, not
immediates (`py/obj.h`). v1 rejects float, complex, a non-small int, and
any raw code whose kind is not bytecode, including a header whose arch
byte is not `MP_NATIVE_ARCH_NONE`. `@micropython.native`, viper, and
inline asm are that reject, not a silent fall-through.

`MP_OBJ_NULL` is the word 0, and `MP_OBJ_SENTINEL` is the word 4, unless
the debug sentinels are on (`py/obj.h`). Unbound locals, `LOAD_NULL` (the
stack value that means "not a method"), and `MP_OBJ_STOP_ITERATION` are
this zero word. A ROM object cannot sit at flash address 0 or 4. The GC
does not trace a zero word. Under `MICROPY_OBJ_IMMEDIATE_OBJS`, `True` is
not the immediate after `False` (v1.29 uses immediate ids 0, 1, and 3).
Phase 0 copies the three ids from the tag instead of assuming they are
dense.

### F3. The machine is a stack frame, not a stack pointer next to a register file

Locals and the expression stack are one array of `n_state` object words.
Local 0 is `state[n_state - 1]`. The stack pointer starts at `state - 1`
and grows upward (`mp_setup_code_state` in `py/bc.c`). The exception
stack is a second array of `mp_exc_stack_t` after those words: a bytecode
address, a tagged value-stack pointer (bit 1 marks `setup_with` /
`setup_finally`), and the previous exception. It is not an array of
object words. `objfun.c` sizes the variable part as
`n_state * sizeof(mp_obj_t) + n_exc_stack * sizeof(mp_exc_stack_t)`, plus
the code-state header (function, ip, sp, depths, globals).

Jump offsets apply after the offset bytes have been consumed
(`DECODE_SLABEL` / `DECODE_ULABEL`, then `ip += offset`). `UNWIND_JUMP`
carries an extra byte after the offset. `CALL_FUNCTION`'s varuint packs
the positional count in the low 8 bits and the keyword count in the next
8 (`py/vm.c`).

Phase 0's catalog is not implementable as a list of family names. Each
opcode needs the operand format from `py/bc0.h`, the multi-opcode
immediate if it has one, the stack effect, and a v1 disposition.

`MAKE_FUNCTION` allocates a function object at run time even when the raw
code is in flash. Phase 2 excludes heap allocation. Its counted-loop exit
test allocates anyway if the loop is written with `def`. A module-level
`while` uses `STORE_NAME` on the module dict instead. `print` is not an
entry in that dict. `LOAD_GLOBAL` finds `mp_builtin_print` in the builtins
dict (`py/modbuiltins.c`). That builtin writes the decimal text of each
argument, then `sep`, then `end` (`\n` by default), and returns `None`,
which the caller pops. A UART store of the integer is not `print`.

`mpy-cross` folds `1 + 2` to the constant 3. `print(1 + 2)` does not
execute the ALU. The counted loop has to be a `while` on a local or a
global. It is not a `for` over `range`: `GET_ITER`, `FOR_ITER`, and the
`range` type are outside phase 2. It is not a comprehension: a
comprehension is a child raw code.

No phase owns default arguments (`MAKE_FUNCTION_DEFARGS`), keyword calls,
`*args` / `**kwargs`, closures (`LOAD_DEREF`, cells, `MAKE_CLOSURE`), or
comprehensions. Closures are also absent from phase 6. A timer callback
written as a nested `def` or a `lambda` needs them. v1 either restricts
scheduled callbacks to module-level functions, or it grows a phase for
closures before phase 5 promises those callbacks.

### F4. Abort-and-redispatch does not fit this bytecode, and 256 KB is not one heap

The C VM collects inside `gc_alloc` (`py/gc.c`), which opcodes call after
they have already pushed, popped, or written. It does not roll the opcode
back and run it again. List append doubles a full item array (`alloc * 2`
in `py/objlist.c`). Extend grows by `len + extra + 4`. The minimum
allocation is 4 slots. The list object and the item array are separate
heap objects. A restartable opcode would have to leave the stack and the
heap unchanged until every allocation succeeded. `BUILD_*`, `CALL_*`,
`MAKE_FUNCTION`, and `SETUP_WITH` do not have that shape.

Keep the safe point. Replace "abort the opcode and re-dispatch" with a
stall inside the opcode. Roots at that stall are: every live frame's
`state[0:n_state]`, the exception stack's `prev_exc` and the objects
still covered by the tagged `val_sp`, module globals, the builtins dict,
the schedule queue, and any object word held in the FSM. Collect, then
retry the allocation. Do not retry the opcode. Words outside the GC pool
are not marked, including flash ROM objects and the zero word.
`VERIFY_PTR` is that range check. Frozen constants must not point from
ROM at a RAM object. Nothing else would keep that RAM object alive.

The 256 KB window cannot stay one region if `MemoryError` is supposed to
agree with `-X heapsize=`.

| Region | Unix port | This plan today |
| --- | --- | --- |
| GC pool, including the 2-bit alloc table | the `-X heapsize=` bytes, tables inside the pool | lumped into 256 KB with the stacks |
| Python frames | C stack, unless pystack is enabled | lumped into the same 256 KB |
| Emergency exception | `mp_emergency_exception_obj`, plus a buffer when enabled | not in the map |
| Mark stack | `MICROPY_ALLOC_GC_STACK_SIZE` | not in the map |

On a 32-bit build a GC block is 16 bytes (`MICROPY_BYTES_PER_GC_BLOCK`).
The alloc table is two bits per block and sits at the front of the pool.
The unix port's finaliser table shrinks the pool further. v1 has no
`__del__`, so the oracle builds with finalisers off. Otherwise the two
heaps fail on different programs.

Phase 3 currently requires both of these: heap layout may differ from
MicroPython's C structs, and `MemoryError` is raised the way the unix port
raises it at the same size. Header size, list overallocation, and the
alloc table pick the byte where allocation fails. Dict printing is the
same kind of leak. A normal dict is a hash map. `mp_map_init` clears
`is_ordered`, and `dict_print` walks slots. `print(d)` matches only when
the hash, the growth rule, and the qstr-key path match, or when the tests
never print a dict and never iterate one.

Use the unix port as the stdout oracle for values. For memory, put an
explicit GC pool in the map, run the oracle with `-X heapsize` equal to
that pool, and enable `MICROPY_ENABLE_PYSTACK` at the frame region's size.
The phase 3 tests stay coarse. A dropped reference can be allocated again.
A program that retains much more than the pool raises `MemoryError`. The
tests do not require the same failing allocation. Reserve a preallocated
emergency `MemoryError` so the failure path does not itself allocate.
`objfun.c` turns a failed frame allocation into
`RuntimeError: maximum recursion depth exceeded` rather than
`MemoryError`. The core does the same, or a recursion test will not match.

Small-int arithmetic is the `MP_SMALL_INT_FITS` check in `py/smallint.h`
after the operation, not a 31-bit wrap. Unary minus and abs of the minimum
small int overflow. Floor division and modulo go through
`mp_small_int_floor_divide` and `mp_small_int_modulo`
(`py/smallint.c`: the remainder takes the sign of the divisor). A negative
shift raises `ValueError`. Power is a loop that can overflow. True
division is absent from the small-int switch when float is off, and it
then fails as an unsupported operator. In-place ops on small ints are the
same arithmetic. The disposition table brings add, sub, and compare
across. Phase 2's "binary arithmetic" is this wider set.

### F5. Phase 4 is several runtimes, and one program does not lock them

`LOAD_BUILD_CLASS` pushes `mp_builtin___build_class__` (`py/modbuiltins.c`).
That builtin calls the class-body function, then calls
`type(name, bases, locals)`. The opcode is one byte. The class
implementation is `type` plus the body call. A body that captures
`__class__` returns a cell, which is a closure. A class with one base, an
`__init__`, and a method that does not use `super()` does not need that
cell. Multiple inheritance, `super()` (`LOAD_SUPER_METHOD`), and
metaclasses are not part of the exit test, and they are not named as out
of scope. Name them out of scope, or the phase has no edge.

`with` is `SETUP_WITH` and `WITH_CLEANUP` in `py/vm.c`. The VM calls
`__enter__`, keeps `__exit__` and the context manager on the stack, and
later calls `__exit__` with the exception triple. A true result swallows
the exception. `return` inside `with` or `finally` uses `UNWIND_JUMP` to
run handlers that are not active yet. A program that only checks that
both methods ran leaves that protocol untested. The exit program takes
the normal path and the exception path, including an `__exit__` that
swallows.

`import` is `IMPORT_NAME`, `IMPORT_FROM`, and `IMPORT_STAR`, a
`sys.modules` entry so the body runs once, and `__name__` (`__main__` on
the entry module, the module's name on the other). Relative imports need
a package. v1 rejects them. The entry point, the flash table of frozen
modules, and a clean return from the entry module are unspecified. A
`while True` program does not return. Device tests need a cycle limit or
a halt write.

Exception objects allocate. The type list in phase 4 is the right list,
and it depends on the emergency object from F4. Line numbers come from
the prelude. Phase 2 has no exception path, so its programs do not divide
by zero. Phase 4 is where that result becomes `ZeroDivisionError`.

`set`, `slice`, and `bytearray` are how MCU code builds buffers and
views. `BUILD_SET` and `BUILD_SLICE` exist. No phase mentions them. v1
should say they wait.

### F6. Phase 5 has a register map and no Python binding

A frozen program cannot store to `0x4000_0000` unless a builtin does.
The target-runtime section names `machine.Pin`, `machine.UART`, and
`machine.Timer`. Phase 5 then lists registers and a blink program that
toggles `GPIO_OUT`. Those are not yet one feature. Phase 5 names the
constructors, the constants (`Pin.OUT`), and the methods that perform the
accesses (`Pin.value`, `UART.read` / `UART.write`, `Timer.init`), and it
says whether `machine.mem32` exists. The unix port's `machine` module is
not this map. Edge checks use a host model of these registers. That model
is written into `mpycore/docs/peripherals.md` before the RTL, the same
order `gc.md` has before the collector.

The register table is not yet that model. `UART_RX` does not say whether
a read pops the byte, what a read returns when bit 31 is clear, or what
an overrun does. `TIMER_COUNT` is both a free-running counter and a
compare reload, with no clock, no auto-reload rule, and no level-versus-edge
rule for the IRQ. `GPIO_OUT` has no input and no direction. That is a
blink output. It is not a GPIO peripheral.

The IRQ rule also diverges from the runtime the oracle implements.
`micropython.schedule(function, arg)` in `py/scheduler.c` queues one call
with one argument. `MICROPY_SCHEDULER_DEPTH` defaults to 4 and has to be a
power of two. A full queue raises `RuntimeError: schedule queue full`.
The VM inspects the queue on branch opcodes (`pending_exception_check` in
`py/vm.c`), not on every byte. A native builtin that loops without calling
the pending check starves the queue. Hard-IRQ context locks the GC, and
`gc_alloc` returns NULL while that lock is held. The scheduled callback
itself is ordinary Python and may allocate. Forbidding allocation inside
the callback rejects a handler that appends to a list, and it will not
match the unix port.

v1 keeps the latch non-allocating, enqueues a module-level function plus
one argument, and runs that callback as a normal call. The callback may
allocate. It does not nest. `KeyboardInterrupt` as a pending exception is
a different path and is unspecified. A later REPL needs it. It is not
part of the phase 5 exit.

### F7. This repository does not contain the CPython hart

The plan was written inside pycore and then moved. Its test contract
originally named `make test-host`, `make test-hw`,
`make test-compiler-vs-cpython`, and `make test-caching`, and a CI split
that skips hardware jobs when a PR only touches markdown. Those jobs are
not in this tree. Phase 0's original exit, "the CPython `make` is
untouched," is not a check this repository can run. The test contract and
the phase 0 exit below are updated to match. This repo's CI grows the
phase exit the plan already names, starting with the first PR that adds
a simulator. Keeping the CPython hart green remains a rule for changes
that land in pycore.

The Verilator flow this plan reuses is in that other tree too. Phase 2's
exit assumes a simulator that loads flash, captures `UART_TX`, prints a
cycle count, and stops a runaway. That harness is part of phase 2.

### F8. Add these checks to the phase exits

These do not add phases. A single happy-path program will not catch them.

| Phase | Add to the exit |
| --- | --- |
| 0 | The config fragment and `mpy-cross` flags from F1. Static qstr id of `print`. Operand format and stack effect per opcode. Immediate ids for `None`, `False`, and `True`. A reject list for native code, float, complex, and non-small int constants. |
| 1 | Decode past source info to the first opcode. One child raw code. Per-module qstr and const tables. A mismatched header is an error. Show that folded `1 + 2` is a constant, so it is not later used as the ALU test. |
| 2 | A `while` whose add is not a constant fold. A positional call that uses the return value. `print` of a negative small int, including the newline byte. No divide-by-zero. |
| 3 | A dropped reference can be allocated again. Data retained well past the pool raises `MemoryError` through the emergency object. Dict print is either locked to MicroPython's map or left out of the oracle. |
| 4 | One base class with `__init__` and a method. `with` on the success path and on a swallowed exception. `import` runs the second module once and sets `__name__`. An unhandled exception writes a traceback to `UART_TX` and halts with a reason distinct from a clean return. |
| 5 | Named `machine` calls, not a bare store. RX-pop and timer-match rules in `peripherals.md` before RTL. The callback takes one argument, may allocate, and does not nest. A full schedule queue raises `RuntimeError`. |

## Test contract

- **Host.** Image tool and prelude decoder under `mpycore/`. No Verilator.
  A docs-only change to this plan does not add a simulator job. The
  CPython `make test-host` job is a pycore job. It is not in this
  repository. See finding F7.
- **Device.** One shared `mpycore` simulator. Programs under
  `mpycore/programs/`. Each exit test in phases 2–5 is a named program
  whose stdout (and, in phase 5, peripheral trace) is checked.
- **Oracle binary.** The pinned unix port, built as the 32-bit v1 config
  in finding F1. From phase 3 onward the harness passes `-X heapsize`
  equal to the GC pool in the memory map, not the whole SRAM window.
  Finding F4 splits that window.
- **CPython suite.** `make test-hw`, `make test-compiler-vs-cpython`, and
  `make test-caching` are gates of the pycore repository. This repository
  does not run them, and `mpycore` work does not weaken them by editing
  that tree. v1 has no cache, so the CPython caching gate is not an
  `mpycore` gate. The `mpycore` memory gate is: SRAM latency fixed at 1,
  flash wait-state 1, and the phase exit programs match.
- **CI.** This repository starts without hardware jobs. The first PR that
  adds `mpycore/rtl` or a simulator adds a job for the phase's exit test.
  That job does not build the CPython hart. A PR that only touches
  `planning/` and markdown does not add one.

## Doc contract

When a phase lands, add the as-built page under `mpycore/docs/` and point
this plan's phase row at it. Do not describe `mpycore` behavior in
`pycore/docs/`. Do not extend `pycore.json` with MicroPython opcodes.

The first pages, written with the phase that makes them true:

| Page | Phase |
| --- | --- |
| `mpycore/docs/memory_map.md` | 0 |
| `mpycore/docs/image.md` | 1 |
| `mpycore/docs/architecture.md` | 2 |
| `mpycore/docs/gc.md` | 3 |
| `mpycore/docs/peripherals.md` | 5 |
