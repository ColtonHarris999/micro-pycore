# MicroPython microcontroller core

Status: **plan, not started.** Audit snapshot: [pycore](https://github.com/ColtonHarris999/pycore) `main` @ `371dc007f9`, 2026-10-13.

A review against MicroPython v1.29.0 is in [Review findings](#review-findings) (2026-10-14). Those are open holes. They are not v1 locks. Two descriptions that were false for any release this plan would pin — the prelude layout, and the phase 1 decoder that followed it — are corrected in place below.

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
The unix port of that tag is the oracle only with the config overlay in
[Review findings](#review-findings). The stock `standard` variant does
not match the locks below. `mpy-cross` from that tag emits the bytecode.
These properties are stable across recent releases; the exact opcode
numbers and bit-masks are not, so they are read from the tag rather than
written here.

- **Bytecode** is a variable-length byte stream. The first byte is the
  opcode. Small immediates and some local indexes are folded into the
  opcode by the multi-opcode scheme. Other operands are a qstr-table
  index, a vuint, one extra byte, or a 1- or 2-byte branch displacement.
  Branch displacements are not vuints and are not `EXTENDED_ARG`. A
  function body starts with the bit-packed prelude in the pin's `py/bc.h`:
  a signature (`n_state` stored as `n_state - 1`, exception-stack depth,
  scope flags, positional count, keyword-only count, default-positional
  count), then a second packed varuint (`n_info`, `n_cell`), then source info and
  closure cells, and only then the opcodes. The persistent file is `.mpy`.
  There is no `CACHE` opcode. `.mpy` version 6 stopped recording an inline
  map-lookup cache in the header; phase 0 still has to confirm the pinned
  tag does not emit one.
- **Names** are qstrs, integer indexes into a pool of interned strings.
  Globals and attributes key on qstr. String literals are qstrs too
  (`LOAD_CONST_STRING`); a heap `str` is the result of an operation that
  builds one, not the only representation of text.
- **The object word** on a 32-bit port is `MICROPY_OBJ_REPR_A` in
  `py/obj.h`: a small int, a qstr, a handful of immediates (`None`,
  `False`, `True`), or a pointer to a heap object. v1 copies that encoding.
- **Small int** is 31 bits in a 32-bit word. With long integers disabled
  (`MICROPY_LONGINT_IMPL_NONE`), overflow raises `OverflowError`.
- **Float and complex** are compile-time options. v1 leaves both off.
  Strings are UTF-8, in the qstr and heap-`str` forms under Names.
  Indexing by byte or by code point is a review finding, not a lock.
- **GC is always on.** Allocation failure collects. The collector is
  mark-sweep over one heap, with a side table of per-block state. Roots
  are explicit on this core (the SRAM stack, globals, and the few live
  machine registers).
- **Libraries are frozen modules** in flash. `import` loads a frozen
  `.mpy`. The on-device compiler is a build option and is large; v1
  leaves it out. The host cross-compiler is the toolchain.
- **Peripherals** are the `machine` module: Pin, UART, SPI, I2C, Timer.
  v1 builds UART, GPIO, and one timer. SPI and I2C wait until a program
  needs them.
- **Interrupts** do not run arbitrary Python inside the latch. A pending
  IRQ is observed at a bytecode boundary. `micropython.schedule` runs a
  frozen callback there. The latch path does not allocate.
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
`.mpy` version against the submodule headers. This repository has no
CPython hart to rebuild; that gate stays in pycore.

### Phase 1 — Flash image and oracle harness

- Host tool reads a `.mpy` from `mpy-cross` and links an absolute flash
  image at `0x0000_0000`: qstr pool (static ids and string data), const
  objects v1 accepts, child raw code, and bytecode. The RTL fetches that
  image and does not parse `.mpy`.
- A diff harness runs the same source on the configured unix oracle and
  stores stdout and stderr separately. The stock `standard` variant is
  not that oracle; see Review findings.
- Prelude decoder for the pinned `py/bc.h` layout, not three separate
  varints: signature, size, source info (block name, argument names,
  line-number bytes), closure cells, then opcodes. Covered by a host test
  per function kind the v1 call path accepts (module body, plain function,
  function with defaults if the pinned emitter produces them). The same
  test must accept a child raw-code object, which is how a `def` is stored,
  and must reject a native or viper raw-code kind.

**Exit.** A frozen function that returns `1 + 2` has a decoded prelude.
A second fixture with a branch, a static qstr, a non-static qstr, a small
int outside the multi-opcode window, and a child function disassembles
to the same operands as the pin's `tools/mpy-tool.py -xd`. No simulator
yet.

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
  holds, and from retaining an object the unix port would free only when
  the test is a stdout test. Stdout tests do not catch a missed root that
  happens to survive until halt; phase 3 includes one test that allocates
  past a dropped reference and checks that a later allocation succeeds.
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

Reviewed 2026-10-14 against MicroPython **v1.29.0** (`py/bc.h`, `py/bc0.h`,
`py/obj.h`, `py/persistentcode.c`, `py/vm.c`, `py/runtime0.h`,
`mpy-cross/main.c`, `ports/unix` `standard` variant). Phase 0 has not
pinned a tag. v1.29.0 is the latest stable release on that date, and the
bytecode facts below have been stable since the bit-packed prelude (1.12)
and `.mpy` 6.3 (1.23). If phase 0 pins a different tag, re-check the
header comment in `py/persistentcode.h` before dropping any item.

The prelude paragraph and the phase 1 decoder bullet were wrong in the
first draft (they described a pre-1.12 layout). They are corrected above,
along with the phase 1 image-tool bullet and its exit fixtures. The
encoding details in this section are still the spec those bullets point
at. Everything that follows, other than those corrections, is still open.

### The stock unix port cannot be the oracle

The v1 lock says the oracle is the pinned unix port and that stdout is
the comparison. The `standard` unix variant is a different machine from
the locks in this file:

| Lock here | Stock `standard` unix, and `mpy-cross` |
| --- | --- |
| 32-bit `OBJ_REPR_A`, 31-bit small int | On an LP64 host the unix word is 64 bits, so the small int is 63 bits. `mpy-cross` does default `-msmall-int-bits` to 31, and the `.mpy` header records that. A 64-bit runtime still accepts the file (`31 <= 63`) and then does not overflow where v1 must |
| Long int off, overflow is `OverflowError` | Unix sets `MICROPY_LONGINT_IMPL_MPZ`. `mpy-cross` is built with mpz too, and that switch is not dynamic. Const-folding therefore emits a decimal bigint object for `1 << 40` |
| Float off | Unix sets `MICROPY_FLOAT_IMPL_DOUBLE`. `mpy-cross` is built with double and will emit a float const |
| Strings | Extra-features unix indexes `str` by Unicode code point. The RTL cost of that is not in phase 3 |

There is no stock variant that matches the locks. Phase 0 has to add one,
or an equivalent `mpconfigport.h` overlay, and build it **ILP32** (`-m32`
or a 32-bit cross toolchain). The variant turns long int off, float off,
and picks one Unicode setting. Phase 3 either implements code-point
indexing or the variant sets `MICROPY_PY_BUILTINS_STR_UNICODE` to 0 and
every str test is ASCII. "Strings are UTF-8" does not decide this, and
code-point indexing is a large amount of RTL to discover in the middle of
the container phase.

`mpy-cross` and that variant are different compilers even at one tag.
`mpy-cross` const-folds with mpz and double; the longint-none compiler
raises at compile time. Overflow tests have to be runtime values (`a + b`),
not literals the cross compiler folds into a const pool. The harness
invokes `mpy-cross` with `-msmall-int-bits=31`, `-X emit=bytecode`, no
`-march`, and an explicit `-O`. Default `-O0` keeps `assert` and source
lines; raising `-O` changes semantics.

Stdout alone is the wrong capture:

- Unhandled exceptions go to **stderr** (`MICROPY_ERROR_PRINTER`). Phase 4
  writes the traceback to `UART_TX`. The diff has to define which device
  bytes correspond to stdout and which to stderr.
- Block-buffered stdout can reorder a `print` behind a traceback. The
  oracle run is unbuffered, and the two streams are compared separately.
- `print` of a function, class, or default instance repr contains an
  address. Those lines will not match. Exit tests print values, not
  reprs of heap objects.
- Exception text depends on `MICROPY_ERROR_REPORTING`. The unix `standard`
  variant is `DETAILED`. The overlay has to pick the same level or the
  phase 4 diff compares two wordings.
- A script that hits the end exits. A blink loop does not. The phase 5
  oracle run has to be bounded (N ticks, then stop). The unix port will
  not finish an infinite program, and it has no view of `GPIO_OUT`.

### Phase 2's exit tests do not fit in phase 2's scope

`print(1 + 2)` and a counted loop are not a closed subset of "load/store
local, small-int ALU, jumps, positional call".

- `print` is a global builtin, not a store to `UART_TX` and not an
  immediate. `LOAD_GLOBAL` looks up the module dict and then a separate
  builtins dict. The builtins dict holds ROM function objects. Phase 2
  needs that second dict and a native call convention: one ROM object,
  a small-int argument, a return of `None`, no allocation, and the
  characters of the decimal plus `\n` written to `UART_TX`. `sep`, `end`,
  `file`, and multi-argument `print` are not required for the exit test
  and have no phase.
- An expression statement needs `POP_TOP`. The module then loads `None`
  and executes `RETURN_VALUE`.
- Module-level names are `LOAD_NAME` / `STORE_NAME`, not `LOAD_FAST`.
  Fast locals exist only inside a function. A counted loop at module
  level uses the module dict. The same loop inside a function needs
  `MAKE_FUNCTION`, a **child raw-code** (not an entry in the const object
  table), `LOAD_FAST` / `STORE_FAST`, and `CALL_FUNCTION`.
- The "no heap" and "module dict of immediates" lines contradict "call a
  frozen function". A function object is not an immediate. Frames are
  not free either: `mp_code_state_t` is variable length (`n_state` value
  slots plus an exception stack). Resolution that keeps phase 2 free of
  a GC heap: the image tool emits frozen function objects into flash,
  the module dict is a fixed SRAM table, and frames come out of a
  reserved SRAM stack that is not collected. `MAKE_FUNCTION` of a closure
  cannot be done that way, because cells are mutable. That is an argument
  for keeping closures out of phase 2, not for pretending a call needs
  no stored function.
- `for i in range(n)` is not the counted loop this phase can run. It
  needs the `range` type (a heap object), `GET_ITER_STACK` (the iterator
  occupies `MP_OBJ_ITER_BUF_NSLOTS` value slots), and `FOR_ITER`.
  Termination is the sentinel `MP_OBJ_STOP_ITERATION`, which a non-debug
  build aliases to `MP_OBJ_NULL`, not a raised `StopIteration`. The phase
  2 program is a `while`.
- `CALL_FUNCTION`'s operand packs positional count in the low 8 bits and
  keyword count in the next 8, even when the keyword count is zero.
  `LOAD_METHOD` / `CALL_METHOD` use a null self slot (`MP_OBJ_NULL`) to
  mean "this was not a method". Phase 0 records those stack effects from
  the pin's `py/vm.c`. v1 has no phase that implements a non-zero keyword
  count, `*args`, or `**kwargs`. Phase 5's Python API has to be
  positional, or keyword calls land in the middle of the peripheral work
  with no phase of their own.
- Small-int multi-opcodes in v1.29 cover a biased window of 64 values
  (excess 16, so `-16`..`47`). `1` and `2` sit in that window. A second
  phase 2 program has to load a small int outside it (signed 7-bit vuint,
  sign in bit 6 of the first operand byte) and a negative. Otherwise the
  exit test never leaves the multi-opcode form.
- Binary opcodes the emitter actually emits include inplace ops, true
  division, floor division, modulo, shifts, power, `in`, `is`, and
  `exception match`. True division is not floor division; with float off
  it raises. Floor division, modulo, shifts, and power raise
  `ZeroDivisionError`, `OverflowError`, or `ValueError`. Shipping those
  in phase 2 as traps, and teaching them to raise in phase 4, repeats
  the CPython hart's trap-to-exception retrofit. Phase 2's ALU is add,
  subtract, and compare. The other sub-ops arrive with the exception
  phase. Compare results are `True` and `False`, whose immediate payloads
  in `OBJ_REPR_A` are 3 and 1, not the integers 1 and 0. `True + 1` is 2
  only after a bool-to-int conversion that phase 2 does not have unless
  a test needs it.
- A mismatch of argument count, an illegal opcode, an unsupported scope
  flag (`GENERATOR`, `VARARGS`, `VARKEYWORDS`, `DEFKWARGS`), or a native
  raw-code kind halts with a distinct sim-control reason. It does not
  skip a byte and continue.

### The loader is a larger tool than phase 1 describes

Phase 1 links a flash image, but the bytes inside a v1.29.0 `.mpy` are
more specific than "a qstr pool and some consts". From
`py/persistentcode.c`:

- Header is `M`, major version, feature byte (sub-version in bits 1..0,
  native arch in bits 5..2, arch-flags vuint present in bit 6), then the
  small-int bit width. Reject arch other than `NONE`, arch-flags present,
  major version mismatch, and `header[3] > 31`. Sub-version is not what
  makes bytecode compatible: the pin's own loader ignores sub-version for
  bytecode-only files. Encoding changes bump the major version. The
  catalog still records the sub-version.
- Qstr data is a vuint length. Bit 0 set means a **static qstr id**
  (`length >> 1`) whose bytes are not in the file. The id is defined by
  the pin's generated qstr list, and ids up through `MP_QSTR_zip` are
  that static prefix (`QSTR_LAST_STATIC` in `persistentcode.c`). `print`
  is reached through this encoding. Bit 0 clear means `length >> 1` bytes
  of UTF-8 plus a null. The image tool and the ROM builtin table have to
  use one assignment of ids, taken from that generated list. A private
  numbering will not resolve `LOAD_GLOBAL` of `print`.
- Const objects are a type byte plus a payload. The type byte is not only
  immediates. v1.29.0 has none, false, true, ellipsis, str, bytes, int,
  float, complex, and tuple. Int and float payloads are **decimal text**,
  not binary words. Ellipsis is a ROM singleton, not an `OBJ_REPR_A`
  immediate. Empty bytes and empty tuple are singletons. Float, complex,
  and an int that does not fit in 31 bits are rejected, not loaded as
  small ints.
- A nested `def` is a child raw-code element (kind in the low 2 bits of
  the length vuint, has-children in bit 2), not an `obj_table` entry.
  `MAKE_FUNCTION` indexes `child_table`. `LOAD_CONST_OBJ` indexes
  `obj_table`. One "const pool" conflates the two.
- The host tool links a flash image at `0x0000_0000` and the RTL fetches
  that image. The RTL does not contain a `.mpy` parser. Function objects,
  type objects, and immutable consts (immediates, qstrs, tuples of those,
  bytecode) live in flash and are immortal. A flash object must not point
  at a heap object, because flash is not updated by GC. Mutable containers
  are built at run time.
- `tools/mpy-tool.py -xd` from the pin is the independent decoder the
  phase 1 tests diff against. A hand-written prelude check of `1 + 2`
  can pass with an empty object table and no branch. The exit fixtures
  need a branch (so the 1-byte and 2-byte displacement decoders run), a
  qstr that is static and one that is not, a small int outside the
  multi-opcode window, a tuple const, and a child function.
- Several modules are a later image revision, not a second format. Phase
  1's image has a module directory of one entry (name qstr, flash
  offset). Phase 4 adds entries. Qstr ids are assigned once for the whole
  image, which is what `mpy-tool.py` does when it freezes more than one
  file.

### Work that has no phase

Opcode families below are named so a phase can own them. Numbers stay in
`mpycore/targets/mpycore.json`, copied from the pin, per the rule at the
top of this file.

| Surface | Why it is not optional for the exits as written | Where it has to go |
| --- | --- | --- |
| `POP_TOP`, `LOAD_CONST_NONE`, `RETURN_VALUE`, `LOAD_GLOBAL`, native `print` | Phase 2's `print(1 + 2)` | Phase 2 |
| `MAKE_FUNCTION`, child raw code, `LOAD_FAST` / `STORE_FAST`, `LOAD_NAME` / `STORE_NAME` | A called function, or a module-level loop | Phase 2, with the frame rule above |
| `BUILD_LIST` / `MAP` / `TUPLE`, `STORE_MAP`, `LOAD_SUBSCR` / `STORE_SUBSCR` | Containers that are not only grown by a hidden FSM | Phase 3 |
| `LOAD_METHOD` + `CALL_METHOD` for **native** methods (`list.append`) | Phase 3's append loop. This is not the phase 4 user bound-method object | Phase 3 |
| `GET_ITER`, `GET_ITER_STACK`, `FOR_ITER`, `range` | Any test written as `for` | Phase 3, and not the phase 2 loop |
| `SETUP_EXCEPT`, `SETUP_FINALLY`, `SETUP_WITH`, `END_FINALLY`, `WITH_CLEANUP`, `POP_EXCEPT_JUMP`, `RAISE_*`, `UNWIND_JUMP` | `try` and `with`. `with` is the finally protocol plus `__exit__` returning true to swallow. `return` or `break` inside `with` is `UNWIND_JUMP` | Phase 4 |
| `LOAD_BUILD_CLASS` and the native `__build_class__` | A class is this call sequence, not one opcode | Phase 4 |
| `IMPORT_NAME` and `IMPORT_FROM` | `from machine import Pin`, plus a frozen second module. `import *` can stay out | Phase 4 for frozen modules; the native `machine` module is phase 5 |
| Closures: `MAKE_CLOSURE`, `LOAD_DEREF` / `STORE_DEREF`, cells | Nested `def`, `lambda`, comprehensions, and `super()` (the `__class__` cell). None of these is in phase 6 either. The phase 4 class test and the phase 5 callback have to be module-level functions that do not use `super()`, or phase 4 blocks on a closure phase that does not exist | New phase, before comprehensions and before `super()` |
| Defaults: `MAKE_FUNCTION_DEFARGS` | Phase 1 decodes them and no phase applies them | The closure/call phase, or phase 4 if a test calls a function with an omitted default |
| `UNPACK_SEQUENCE`, slices, `set`, `bytearray` | Easy to emit by accident (`a, b = ...`, `buf[1:4]`, a set literal). v1 rejects the opcode until a phase owns it | Explicit non-goals until a phase is added |
| Keyword calls and `*args` / `**kwargs` | Scope flags and `CALL_FUNCTION_VAR_KW` | Non-goal in v1. Machine constructors stay positional |

Also missing from the exception list, and required for the unix port to
match once the corresponding opcode exists: `ValueError` (negative
shift), `NameError`, `UnboundLocalError`, `ImportError`, `RuntimeError`,
`RecursionError`. `StopIteration` is user-visible for `next()`, and a
different sentinel inside `FOR_ITER`.

Attribute lookup and Python `dict` are different maps. Instance and
module attributes key on qstr. A `dict` keys on arbitrary objects, uses
the pin's hash, and preserves insertion order. Printing `d` or relying
on `list(d)` will not match the oracle if the hash or the order differs.
Phase 3 can avoid that by printing looked-up values, but then the order
rule is still a hole the first dict test will fall into.

`__name__` on the entry module is `"__main__"`, set by the loader, not by
bytecode. `__build_class__`, native exception types, and `machine` are
ROM modules in a builtin table. `sys.modules` caches imports. None of
that is in phase 4's "`import` of another frozen module" sentence.

### GC, frames, and the 256 KB

Phase 3's root set (one live stack, module globals, object registers) is
short of the roots that will exist by phase 5:

- Every suspended frame, not only the top one: value slots, the pending
  exception, and each exception-stack entry's saved exception.
- The builtins dict, the module dict, and `sys.modules`.
- The schedule queue, once phase 5 adds it, and the emergency
  `MemoryError` object.
- ROM type objects and flash consts are not collected. The scanner's
  heap range is the SRAM heap window. `MP_OBJ_NULL` is 0 and
  `MP_OBJ_SENTINEL` is 4 in a non-debug build; both have the low bits of
  an object pointer. A scanner that traces every word with clear low bits
  will chase them. Flash pointers and the bytecode `ip` are interior
  pointers into the flash window and are not heap roots.

Uninitialized SRAM is not a safe root. The pin zero-fills a new frame.
Zero is `MP_OBJ_NULL`, which is safe only because it is outside the heap
range.

Object pointers are 4-byte aligned (`OBJ_REPR_A` uses the low two bits).
The small-int range is asymmetric: `-2**30` fits, `2**30` does not, and
negating the minimum overflows.

An allocating opcode is restartable. Abort means the value stack still
holds the inputs, no pointer to a partial object is reachable, and
redispatch runs the same opcode. A list grow that has allocated a new
array and not finished the copy rolls back or finishes; it does not
publish the new array and then GC. That is the CA rule and the safe-point
rule applied together. They can be implemented so they contradict each
other if the FSM links the new storage first.

`MemoryError` when the heap is already full cannot allocate the exception
object. Unix `standard` sets `MICROPY_ENABLE_EMERGENCY_EXCEPTION_BUF`.
v1 needs a preallocated `MemoryError` or the phase 3 OOM test dies in the
raiser instead of raising. Finalizers (`__del__`) are off unless a later
phase turns them on. Unix `standard` has them on; the oracle overlay
turns them off so a collected object does not grow a callback the device
will not run.

The 256 KB window is SRAM, not the GC heap, once frames and the module
dict live there. The oracle `-X heapsize=` matches the **heap** region
only. Phase 2 locks the split (reserved frame arena versus heap base and
length) before phase 3 writes the collector. "Same heap size raises
`MemoryError` the same way" is false under two allocators: block size,
list overallocation, and fragmentation move the failure. The phase 3
tests that can actually match are a dropped reference that makes a later
allocation succeed, and one allocation larger than the heap. An Nth
`append` that happens to exhaust 256 KB will not be stable.

Dict and list layout may differ from the C structs. Behavior still
includes ordered dicts and the pin's hashes if any test prints a dict.
The type word, or an equivalent tag the scanner can trust, has to exist
or the collector cannot know which fields are pointers. "Layout may
differ" does not remove that.

### Interrupts, idle, and the peripheral spec

The runtime section mixes the hard IRQ with `micropython.schedule`.

- The latch runs native code only. It sets a pending bit and queues a
  callback. It does not allocate, and it does not run Python.
- The queued callback is ordinary bytecode. It may allocate. GC at that
  point is a normal safe point. Forbidding allocation in the callback,
  as phase 5 does, makes `MemoryError` the result of a normal ISR pattern
  (append a received byte) and is stricter than the pin. Depth of the
  queue is the pin's `MICROPY_SCHEDULER_DEPTH` (4 on the default extra
  features config). Overflow policy is missing: drop the new callback, or
  coalesce to one pending callback per IRQ source. Pick one before RTL.
- The poll point in the pin is a jump opcode, taken or not (`py/vm.c`
  reaches `pending_exception_check` from the jump family only).
  Straight-line opcodes do not poll. Polling every bytecode is a tighter
  choice and is legal if documented. IRQ interleaving will not match the
  unix port. Do not use the unix port as the IRQ oracle.
- A callback that raises is reported and does not replace the interrupted
  program, matching `mp_call_function_1_protected`. Phase 5 currently says
  the failure is a normal exception, which reads as if it unwinds the
  main program.
- Callbacks do not nest. A second IRQ during a callback stays pending and
  runs after the callback returns. The root set includes the suspended
  main frames for the whole call.
- Who clears `IRQ_STATUS` is unspecified. If the callback is expected to
  write-1-to-clear and forgets, the next bytecode runs the callback
  forever. v1 rule that should be written down: dequeue of a source
  clears that bit, and an edge during the callback sets it again.
- After the entry module returns, a program that armed a timer has to
  still poll. Otherwise `main` that registers a callback and returns
  halts before the first tick, and the blink exit never sees an edge.
  Either the hart idles and polls after the module returns, or the exit
  program is required to sit in `while True`. The second burns a simulate
  cycle per spin. `machine.idle()` as "advance the testbench to the next
  enabled IRQ" keeps the test finite. The timer is testbench-advanced,
  not a cycle-counted free run, or the blink trace changes every time the
  ALU's latency changes.
- Unix has `machine.mem32` and a Pin base class. It does not implement
  this memory map, and it will not toggle the simulator's `GPIO_OUT`.
  Phase 5 needs a written Python API (positional `machine.Pin`,
  `machine.UART`, `machine.Timer`), a **Python shim** on the oracle's
  path that produces the stdout, and a native module on the device that
  produces the same stdout and the MMIO trace. "Import a frozen module"
  does not build `machine`, because `machine` is native. The shim and the
  native module are the same spec.
- `TIMER_COUNT` says read the counter and write the compare, under one
  name, with no width, no clock source, and no match-versus-overflow
  rule. `UART_RX` does not say whether a read pops the byte. v1 has a
  one-byte RX buffer, pop on read, data-valid in bit 31, and overrun
  drops the newest byte. TX has no baud and no FIFO: a committed store
  prints the byte, as `CONSOLE_TX` did. GPIO is output-only; the blink
  test watches bit 0. Reserved MMIO reads as 0. A store to flash, or a
  load/store outside flash, SRAM, and the two MMIO windows, halts with a
  bus-fault reason rather than becoming a Python exception.
- The immutability sentence says phase 5 may not move "these four"
  registers. The table has six rows. All six offsets stay. New registers,
  if any, start at `0x18`.

`mpycore/docs/peripherals.md` is the right page for the register rules.
The IRQ and idle rules belong in `mpycore/docs/interrupts.md`, which the
doc table did not list.

### Phase 6's on-device compiler does not exist in the form described

MicroPython's compiler is `py/compile.c` and `py/emitbc.c`. It is C. This
hart executes bytecode only, and the non-goals forbid a second core
running the C VM. Freezing "a MicroPython compiler" into flash is not a
repackage of the pin. The choices are a new compiler written in the
Python subset this core actually runs, or dropping on-device `compile()`
and keeping the REPL on the host. The 14,000-line CPython compiler is
correctly rejected. The C compiler of the pin is not a substitute that
can be frozen.

Closures are the hole in front of generators, not a sub-bullet of them.
`uasyncio` is a frozen Python library on top of generators, and its size
counts against the 512 KB flash. Phase 6 should say that before anyone
treats "async" as a frame-layout change only.

A later fetch buffer must not cache MMIO and must not treat a flash data
load as an instruction prefetch into SRAM. The bus decoder is part of
phase 2, because consts and qstr bytes are read from the same flash the
PC executes.

### This repository is not the pycore tree

Phase 0's exit says `make` of the CPython hart is untouched, and the test
contract binds `make test-hw`, `make test-compiler-vs-cpython`, and the
planning-only CI skip. Those gates live in
[pycore](https://github.com/ColtonHarris999/pycore), not here. This
repository has no CPython simulator to keep green. Keeping pycore's gates
green remains a rule for changes that land there. It is not an exit test
of a PR in this repo. The first CI this repo needs is the phase 0 host
test, then one simulator job when `mpycore/rtl` appears.

`mpycore/` as a directory under this repo is what the path convention
already says. `vendor/micropython` stays at the repo root, beside
`mpycore/`, not inside it.

### Test and doc gaps

Phase 2's simulator needs a trace (PC, opcode name, stack depth) before
stdout mismatches are debuggable. Stdout against the configured oracle is
still the acceptance check.

Phase 0's catalog records, from the pin, for each opcode the v1 phases
claim: operand format, stack effect, and the phase number or `reject`.
It also records the prelude fields, the `.mpy` const type bytes, the
static-qstr rule, `MP_OBJ_ITER_BUF_NSLOTS`, and the mpconfig overlay.
Disassembly of one compiled `while`, one `def`, one `class`, one `with`,
and one `for` is a fixture, so the opcode set is what the emitter emits
and not a hand-made subset that no compiler produces.

Pages to add to the doc table:

| Page | Phase |
| --- | --- |
| `mpycore/docs/bytecode.md` | 1 |
| `mpycore/docs/object_model.md` | 2, extended in 3 |
| `mpycore/docs/exceptions.md` | 4 |
| `mpycore/docs/interrupts.md` | 5 |

`object_model.md` is where the native-call convention and the two maps
(qstr attributes versus Python `dict`) get written down. `architecture.md`
alone will not carry that.

The line-count expectation ("much smaller than 82,000") is about the
datapath width and the missing cache, FPU, and second hart. Phases 3 and
4 are a language runtime: maps, a restartable allocator, class creation,
and import. That work is the schedule risk, not the 31-bit ALU.

## Test contract

- **Host.** Image tool and prelude decoder under `mpycore/`. No Verilator.
  The CPython `make test-host` job stays as it is. A docs-only change to
  this plan does not run it.
- **Device.** One shared `mpycore` simulator. Programs under
  `mpycore/programs/`. Each exit test in phases 2–5 is a named program
  whose stdout (and, in phase 5, peripheral trace) is checked.
- **Oracle binary.** The pinned unix port, invoked by the harness with a
  heap limit of 256 KB from phase 3 onward.
- **CPython suite.** `make test-hw`, `make test-compiler-vs-cpython`, and
  `make test-caching` remain the CPython hart's gates. `mpycore` work does
  not weaken them. v1 has no cache, so the CPython caching gate is not a
  `mpycore` gate. The `mpycore` memory gate is: SRAM latency fixed at 1,
  flash wait-state 1, and the phase exit programs match.
- **CI.** Follow the existing split: a PR that touches only `planning/`
  and markdown skips the hardware jobs. The first PR that adds
  `mpycore/rtl` or a simulator adds a job for the phase's exit test and
  does not rebuild the CPython simulators to do it.

## Doc contract

When a phase lands, add the as-built page under `mpycore/docs/` and point
this plan's phase row at it. Do not describe `mpycore` behavior in
`pycore/docs/`. Do not extend `pycore.json` with MicroPython opcodes.

The first pages, written with the phase that makes them true:

| Page | Phase |
| --- | --- |
| `mpycore/docs/memory_map.md` | 0 |
| `mpycore/docs/bytecode.md` | 1 |
| `mpycore/docs/image.md` | 1 |
| `mpycore/docs/architecture.md` | 2 |
| `mpycore/docs/object_model.md` | 2, extended in 3 |
| `mpycore/docs/gc.md` | 3 |
| `mpycore/docs/exceptions.md` | 4 |
| `mpycore/docs/peripherals.md` | 5 |
| `mpycore/docs/interrupts.md` | 5 |
