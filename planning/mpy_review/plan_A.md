# MicroPython microcontroller core

Status: **plan, not started.** Audit snapshot: [pycore](https://github.com/ColtonHarris999/pycore) `main` @ `371dc007f9`, 2026-10-13.
Review: holes found 2026-10-14, recorded in [Review findings](#review-findings). Where a finding names a phase, that finding is part of the phase until the phase text is revised.

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
  multi-opcode groups). The others take a qstr index, a varuint, or a
  1- or 2-byte branch offset, selected by `MP_BC_FORMAT` in the tag's
  `py/bc0.h`. A function body starts with the bit-interleaved prelude in
  `py/bc.h` (state, exception-stack depth, scope flags, argument counts),
  then source-info and closure bytes, then the opcodes. The persistent
  file is `.mpy`. There is no `CACHE` opcode and no `EXTENDED_ARG` word.
  [Finding 2](#2-the-mpy-image-is-larger-than-phase-1-says) is the list
  phase 0's catalog has to record.
- **Names** are qstrs, integer indexes into a pool of interned strings.
  Globals and attributes key on qstr.
- **The object word** on a 32-bit port is `MICROPY_OBJ_REPR_A` in
  `py/obj.h`: a small int, a qstr, a handful of immediates (`None`,
  `False`, `True`), or a pointer to a heap object. v1 copies that encoding.
- **Small int** is 31 bits in a 32-bit word. With long integers disabled
  (`MICROPY_LONGINT_IMPL_NONE`), overflow raises `OverflowError`.
- **Float and complex** are compile-time options. v1 leaves both off.
  Strings are UTF-8. Identifiers are qstrs; other strings are heap objects.
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
is not allowed to move these six.

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
simulator. Holes in this scope are [Review findings](#review-findings);
an implementer follows the finding where it names a phase.

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
`.mpy` version against the submodule headers. `make` of the CPython hart
is untouched.

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
- A filesystem or `open`, threads, `input` and the REPL, `sys.stdin`,
  `@micropython.native` / viper / inline asm, finalisers, weakrefs, and
  `id()`. SPI, I2C, and ADC stay in phase 6. [Finding 10](#10-non-goals-to-add).

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
| `mpycore/docs/image.md` | 1 |
| `mpycore/docs/architecture.md` | 2 |
| `mpycore/docs/object_model.md` | 2, extended in 3 |
| `mpycore/docs/calling.md` | 2 |
| `mpycore/docs/builtins.md` | 2, extended each phase |
| `mpycore/docs/gc.md` | 3 |
| `mpycore/docs/exceptions.md` | 4 |
| `mpycore/docs/peripherals.md` | 5 |

## Review findings

Holes found 2026-10-14 against current MicroPython `master` (`.mpy` 6.3:
`py/bc.h`, `py/bc0.h`, `py/persistentcode.h`, `py/obj.h`,
`mpy-cross/mpconfigport.h`, `ports/unix`) and against pycore `371dc007`.
The phase text above is the original scope. A finding here is an open hole
in that scope.

### 1. The oracle build is a different machine from v1

The stock unix port does not implement the v1 locks, so stdout against
that binary will not match a core that does.

| Stock unix port (`variants/standard`) | v1 lock |
| --- | --- |
| `MICROPY_LONGINT_IMPL_MPZ` | Long int off. Overflow is `OverflowError` |
| `MICROPY_FLOAT_IMPL_DOUBLE` | Float off. With float compiled out, `/` is a `TypeError` (`unsupported types for ...`). With float on, `/` returns a float |
| 64-bit `MICROPY_OBJ_REPR_A`. Small int is 63 bits because `mp_int_t` is pointer-sized | 31-bit small int in a 32-bit word. Range is `-2**30 .. 2**30-1` |
| GC block is `4 * sizeof(word)` = 32 bytes | A 32-bit repr A block is 16 bytes |
| Heap is separate from the C stack. `-X heapsize=256k` sizes that heap only | 256 KB SRAM also holds call frames and the schedule slots |
| Finalisers, scheduler, asyncio, VFS, and a unix `machine` are on | Most of those are out of v1 |
| Uncaught tracebacks go to stderr (`mp_obj_print_exception` on `mp_stderr_print`). Exit status is 1, and `SystemExit` is the `FORCED_EXIT` encoding in `ports/unix/main.c` | The harness as written stores stdout |
| `MICROPY_ERROR_REPORTING_DETAILED` | Message text changes with the reporting level |

`mpy-cross` defaults `small_int_bits` to 31, which is the right header
byte, and it is built with mpz and double. An int literal that does not
fit in 31 bits, and any float literal, is a const object in the `.mpy`.
The stock unix port executes both.

Phase 0 records a config next to the tag:

- A checked-in mpconfig fragment: long int off, float off, complex off,
  repr A, 32-bit `mp_int_t`, GC on, finalisers off, async off, the
  scheduler depth from [finding 7](#7-peripherals-irqs-and-the-machine-module).
  The unix oracle is built from that fragment. The core implements the
  same fragment.
- `mpy-cross` is built from the same submodule commit in CI. A distro
  `mpy-cross` is the wrong bytecode.
- Flags locked with the tag: `-msmall-int-bits=31`, no `-march` (bytecode,
  arch `NONE`), `-O0` until a revision says otherwise. Header byte 3
  (small-int bits) is a field in `mpycore.json`, beside version and
  sub-version.
- Upstream's loader ignores sub-version on bytecode-only files. It checks
  sub-version only when the arch nibble is not `NONE`, and it rejects the
  file when `header[3] > MP_SMALL_INT_BITS`. The loader's acceptance test
  is the major version plus the small-int width. This plan still treats
  the pinned tag as the ISA, and CI builds `mpy-cross` from that tag.
- From phase 3 the oracle heap flag is the GC heap only. SRAM is that heap
  plus the call-stack reserve and the alloc table
  ([finding 6](#6-gc)).
- The diff includes stderr once phase 4 prints tracebacks, and it includes
  the process exit status.

Right shifts follow the pin's small-int path, which caps a shift count at
`mp_int_t` width minus one. That width has to be 32 on the oracle or large
shifts diverge.

### 2. The `.mpy` image is larger than phase 1 says

Phase 1's layout ("qstr pool, const objects that are immediates or qstrs,
raw bytecode") cannot represent the function its own exit test decodes.
`def f(): return 1 + 2` is a child raw-code element. The container, from
`persistentcode.h` and the `.mpy` file docs:

- Four-byte header: `'M'`, major, feature/arch/minor, small-int bits. Bit 6
  of the feature byte means an architecture-flags vuint follows. v1 rejects
  arch other than `NONE` at image build. That is `@micropython.native`,
  viper, and inline asm.
- One file-level qstr table and one const-object table, shared by every
  nested raw code.
- With `MICROPY_EMIT_BYTECODE_USES_QSTR_TABLE` (on for persistent code),
  qstr operands in the bytecode are indices into that file-level table.
  Execute-in-place leaves the bytecode bytes as the writer emitted them
  and materializes the table. Patching the bytecode to global qstr ids is
  the other legal design; the plan has to pick one.
- Qstrs with id `<= MP_QSTR_zip` (`QSTR_LAST_STATIC`) are stored as the id
  alone. They assume the runtime has the static list `makeqstrdata.py`
  generated for that `mpy-cross`. Phase 0 snapshots that list. The image
  tool uses it as the low ids.
- Const kinds the writer emits: child raw code (`MP_PERSISTENT_OBJ_FUN_TABLE`),
  `None` / `False` / `True` / ellipsis, `str`, `bytes`, `int`, `tuple`,
  and, because this `mpy-cross` has them, `float` and `complex`. v1 accepts
  a kind only in the phase that executes it. Float, complex, and mpz ints
  are a named image-build error. Dropping one is a wrong program.
- Each raw code is a vuint (kind, length, has-children), the code bytes,
  then its children. Bytecode is the only kind v1 loads.
- The prelude is the bit-interleave in `MP_BC_PRELUDE_SIG_DECODE`:
  `n_state`, `n_exc_stack`, scope flags, `n_pos_args`, `n_kwonly_args`,
  `n_def_pos_args`. A second interleave is `n_info` and `n_cell`. Then
  `n_info` source-info bytes (simple name, argument names, line-number
  encoding) and `n_cell` closure bytes. The first opcode is after those.
  Phase 1's decoder returns all of them, including the opcode-start offset
  and the line-info span. Phase 4 tracebacks use the line-info span. A
  decoder that stops at "state, exception stack, flags" fetches source-info
  bytes as opcodes.
- The four prelude scope-flag bits are generator, `**kwargs`, `*args`,
  and a keyword-default dict (`MP_SCOPE_FLAG_DEFKWARGS`). Positional
  defaults are the separate `n_def_pos_args` field. Any of these that the
  current phase does not implement is an image-build reject.
- The image is a table of frozen modules plus an entry qstr, including
  while only one module exists. Phase 4 import then adds a module. It
  does not invent a second file format.
- The decoder's oracle is the submodule's `tools/mpy-tool.py -xd`. A
  round-trip through the same parser that just wrote the dump does not
  catch a shared mistake.

Phase 0's opcode catalog records a format per opcode: multi-opcode
immediate (`LOAD_CONST_SMALL_INT` covers −16..47, `LOAD_FAST` /
`STORE_FAST` cover 0..15, plus unary and binary groups), or byte / qstr /
varuint / offset. Offsets are one byte or two, and the signed ones are
biased. `UNWIND_JUMP` and the closure makers carry one extra byte. The PC
and the IRQ check advance on an opcode boundary, after those bytes.

### 3. Phase 2 requires a call and forbids the objects a call needs

`print(1 + 2)` is `LOAD_GLOBAL print`, two small-int loads, a binary op,
`CALL_FUNCTION`, `POP_TOP`, load `None`, return. `print` is a ROM builtin.
This core has no C function pointer to call. The CPython hart's `BI_*`
call ids were that mechanism, and the disposition table leaves them on
that hart without naming a replacement.

Phase 2 locks a native-builtin call. A ROM object carries a type tag the
call FSM recognizes and a builtin number. Phase 5's MMIO stores use the
same mechanism. Bytecode has no raw pointer load, so `machine.Pin` and
`machine.mem32` are builtins that perform the store. The builtin set for
each phase is `mpycore/docs/builtins.md`.

`LOAD_GLOBAL` searches the module dict and then the builtins dict. A
module dict of immediates does not contain `print`. Reset is part of this
phase: PC at the first opcode of the entry module, one code state on the
stack, builtins and `__name__` already installed.

`def` plus a call is `MAKE_FUNCTION` on a child raw code. Upstream
allocates a function object there (bytecode pointer, globals, defaults).
Phase 2 lists that call as in scope and lists heap allocation as out of
scope. The phase picks one of these, and the exit test uses that one:

- The module body is the only Python callable. The only call is native
  `print`. `def` arrives in phase 3 with the function object.
- Or a frozen function with no defaults, no free variables, and no keyword
  arguments is a ROM function whose globals pointer is the single module
  dict filled at reset. `MAKE_FUNCTION` of anything else is an image-build
  reject.

The counted loop is a `while` on small ints. `for i in range(n)` allocates
a `range` and emits `GET_ITER` / `FOR_ITER`, which [finding 4](#4-language-features-that-no-phase-owns)
places in phase 3.

The integer subset includes the opcodes ordinary expressions emit:

- `POP_TOP`, `DUP_TOP`, `DUP_TOP_TWO`, `ROT_TWO`, `ROT_THREE`.
- Inplace binary ops. `+=` is a different opcode byte from `+`. Upstream's
  bytecode binary-op group has 35 entries, inplace included.
- `//` and `%`, using Python's floor-division sign (`mp_small_int_floor_divide`
  / `mp_small_int_modulo` in the pin). Division by zero halts with a sim
  reason until phase 4 makes it `ZeroDivisionError`. `/` is `TypeError`
  while float is off.
- Shifts, invert, and power. A negative shift is `ValueError`. A negative
  power is `ValueError` (`negative power with no float support`) while
  float is off. `(-2**30) // -1` and unary minus of `-2**30` overflow.
- Compare results are the `True` / `False` immediates. `is` / `is not` are
  identity. `POP_JUMP_IF_*` uses truthiness. `and` / `or` are
  `JUMP_IF_*_OR_POP`.
- `True` and `False` are integers. `True + True` is `2`.
- Until phase 4, small-int overflow halts with a sim reason. After it, the
  reason is `OverflowError`.

pycore's floor-division sign rules are the rules to reimplement at 31
bits. The 64-bit datapath and the overflow-to-bigint trap stay on that
hart.

### 4. Language features that no phase owns

The pinned `mpy-cross` emits these for ordinary programs. Each one is
either given a phase here or rejected by name at image build. Until
phase 4, an opcode the running phase does not implement halts with the
unsupported-opcode reason. From phase 4 the same case raises
`NotImplementedError` with the pin's message (`opcode`), which is what
`vm.c`'s default dispatch does.

| Feature | Why it is in scope | Phase |
| --- | --- | --- |
| `LOAD_METHOD` / `CALL_METHOD`, and the all-zero method sentinel | The phase 3 exit test appends to a list. `LOAD_METHOD` pushes `(method, self)` or `(builtin, MP_OBJ_NULL)`. `CALL_METHOD` tells those apart | Phase 3. Phase 4's bound-method work is the allocating `LOAD_ATTR` path. The emitter uses both |
| `LOAD_SUBSCR` / `STORE_SUBSCR`, `BUILD_SLICE` | `xs[i]` and slices | Phase 3 |
| `UNPACK_SEQUENCE` / `UNPACK_EX` | `a, b = ...` | Named in phase 3 or 4 |
| `GET_ITER`, `FOR_ITER`, `GET_ITER_STACK`, `range` | A `for` loop is not a generator. End of iteration is the `MP_OBJ_STOP_ITERATION` word, which is the all-zero word, and it is not a raised `StopIteration` | Phase 3, ahead of the phase 6 generator work |
| `STORE_COMP` and comprehensions | Inlined in this bytecode | Phase 3 if list displays are in; otherwise an image-build reject |
| Closures: `MAKE_CLOSURE`, `LOAD_DEREF` / `STORE_DEREF`, cells | Nested functions and callbacks that capture locals. Phase 2 excludes them, and no later phase takes them | Its own phase, before a scheduled callback is allowed to be a closure |
| Keyword arguments and defaults | The call varuint packs the positional count in the low 8 bits and the keyword count in the next 8. Keywords sit on the stack as `(qstr, value)` pairs. The prelude already carries `n_def_pos_args` | Phase 4, or a reject when the prelude or the call encoding has them |
| `*args` / `**kwargs` | `CALL_FUNCTION_VAR_KW`, `CALL_METHOD_VAR_KW` | A later row, named |
| `super()` | `LOAD_SUPER_METHOD` | Phase 4 or a later row, named |
| `del`, `pop` | Dict and set deletion use tombstones (`MP_OBJ_SENTINEL`) | Named with the opcode that deletes |
| `set` | Iteration order follows the hash table. A printed set matches the oracle only when the hash and the growth thresholds match. Dict order is insertion order and is observable with any layout | Dict order is part of phase 3. Set stays out until the hash is specified |
| `bytearray` | Mutable buffers for drivers. `bytes` is immutable | Phase 3 or 5 |
| f-strings and t-strings | This `mpy-cross` enables `MICROPY_PY_FSTRINGS` and `MICROPY_PY_TSTRINGS`. They desugar into calls and builds no phase lists | Image-build reject until a phase owns the opcodes |
| `property` and descriptors | On at the unix port's feature level | A later row, named |

Phase 4 `import` includes: one module object per name, cached for the
second import; `from m import name`; `__name__` set on the module; a
missing module is `ImportError`. `import *` and circular import are in
that exit test or named as later.

### 5. Runtime shape the phases assume and never specify

Repr A is the object word, as the lock says. These consequences go in
`mpycore/docs/object_model.md` with the masks:

- A pointer object's low bits are `00`, so every object is 4-byte aligned.
  The first word is a type pointer. Builtin and type objects live in flash.
- The all-zero word is `MP_OBJ_NULL` and `MP_OBJ_STOP_ITERATION`. It is not
  `None`. `None`, `False`, and `True` are immediates. GC does not follow a
  zero word. An empty local, an empty map slot, and the end of an iterator
  are that word.
- `MP_OBJ_SENTINEL` is the word `4` when debug sentinels are off, which is
  the v1 config. SRAM starts at `0x2000_0000`, so `4` is never a heap
  pointer. Tombstones use it.
- `bool` is an integer immediate.

Phase 3 may use a different struct layout from the C VM and still has to
implement the slots the opcodes call: unary, binary, subscript, attribute,
call, iter, next, and print. Method lookup walks the type dict. Object
identity is the pointer: `a = []; b = a; b.append(1)` prints `[1]` for `a`.

One activation record matches `mp_code_state_t`. The header holds the
function object, ip, value sp, exception-stack index, and globals. Then
`n_state` object words, then `n_exc_stack` entries of `(handler_ip,
val_sp, prev_exc)` placed immediately after that array (`vm.c` takes
`exc_stack` as `state + n_state`). Decoded `n_state` already includes
locals and stack depth. Locals sit at the high end: `fastn =
&state[n_state - 1]` is local 0, and local `i` is `fastn[-i]`. The value
stack grows upward from `state[0]` (`PUSH` is `*++sp`, and
`mp_setup_code_state` sets `sp` to `&state[0] - 1`). Locals and the value
stack grow toward each other. A root scan of "the words from a stack base
through SP" misses every local. The root is the whole `state[0 ..
n_state)` of each live frame, plus `prev_exc` in the exception entries.
An SP that reaches a live local is a simulator halt. Nested calls chain
these records in the SRAM reserve outside the GC heap, so the phase 3
heap limit is the same byte count the oracle's `-X heapsize` uses.

Exception handlers are pushed by `SETUP_EXCEPT`, `SETUP_FINALLY`, and
`SETUP_WITH`. This bytecode has no CPython exception table, and pycore's
table walk does not execute it. `END_FINALLY` and `WITH_CLEANUP`
distinguish no exception, re-raise, and an unwinding return or jump.
`UNWIND_JUMP` is how `break`, `continue`, and `return` leave a `with` or
`finally`. The phase 4 exit test (`with`, plus a caught
`ZeroDivisionError`) runs that path. `mpycore/docs/exceptions.md` is the
page that writes the entries down.

`except` walks base types, so an exception is an instance with `.args`,
and constructing one allocates. Phase 4's type list is missing the ones
ordinary programs raise: `NameError`, `ValueError`, `RuntimeError`,
`ImportError`, `AssertionError`, `StopIteration`, and the `Exception` /
`BaseException` roots. `LOAD_FAST` of an unassigned local raises
`NameError` (`local variable referenced before assignment` in `vm.c`),
which is the message to match. `RAISE_LAST` and `RAISE_FROM` are in
phase 4 or are a named reject.

An uncaught exception prints the pin's message text and a traceback from
the prelude line info, then halts. The harness compares that text on
stderr. Default instance repr contains the address (`<C object at 0x...>`).
The diff canonicalizes those addresses, and the phase 4 program can avoid
printing a default repr. `id()` stays out of v1.

Allocating the traceback can itself fail. The unix oracle keeps
`MICROPY_ENABLE_EMERGENCY_EXCEPTION_BUF`. v1 has a fixed non-GC buffer for
that case, or an out-of-memory traceback is a silent halt. Pick one in
`exceptions.md`.

Recursion depth is a locked integer on the oracle (stack check) and on the
core, and the error is `RuntimeError`. The SRAM reserve holds that many
maximum-sized frames. A deeper call raises, and does not write the heap.

### 6. GC

The safe-point rule (abort the opcode with no architectural commit,
collect, retry) is the hardware shape. The collector still has to match
this bytecode's mark-sweep:

- Roots, written in `mpycore/docs/gc.md` before the engine: the live
  code-state chain (the whole `state[]` array of each frame, not only the
  value-stack slice below SP, plus `prev_exc`), module globals,
  the builtins dict, `sys.modules` once import exists, the schedule slots
  and IRQ callback slots once phase 5 exists, and every pointer register
  of the container FSM, including a buffer that has been allocated and not
  yet published. The dropped-reference test in the risks section does not
  cover the FSM register.
- Mark follows a word only when it addresses a block head in the SRAM heap
  window. Type pointers and bytecode live in flash. The VM does not root
  an interior pointer. A conservative scan of every SRAM word is a
  different collector and is not the v1 rule.
- 256 KB is the SRAM size. Lock the split: call-stack reserve, schedule
  queue, then the GC region. The alloc table is 2 bits per block and the
  block is 16 bytes, inside the GC region, matching upstream. The oracle
  heap byte count is that region. Usable blocks are what the `MemoryError`
  test compares. A 64-bit unix heap with 32-byte blocks will not raise on
  the same program.
- Upstream also collects when `MICROPY_GC_ALLOC_THRESHOLD` is crossed, not
  only when an allocation does not fit. The core uses the same threshold
  policy as the oracle build. Otherwise one side survives a program the
  other rejects.
- A collection that does not free a large enough block raises
  `MemoryError`. Publish of a grown container is the last write, and the
  new buffer is reachable from a root before any collection point inside
  the command.
- Mark-stack overflow has a defined behavior. Upstream uses a fixed stack
  (`MICROPY_ALLOC_GC_STACK_SIZE`, default 64) and rescans the heap when it
  overflows. A deep live chain is a phase 3 test. The CPython hart's
  collector has already failed this way (`pycore/docs/gc.md` mark-stack
  note).
- Finalisers and weakrefs are off on the core and on the oracle. A
  `__del__` that prints would desynchronize stdout.
- v1 qstrs live in flash. Runtime code does not intern, and the qstr pool
  is not a GC root. A later `getattr` of a dynamic string changes this.
- The bytecode ip points into the middle of a flash function. The function
  object on the code state is the root that keeps a heap function alive.
  Flash bytecode itself is not collected.

### 7. Peripherals, IRQs, and the `machine` module

The register table has six words. The sentence above it now locks all
six; the original text said four.

The phase 5 host model and the RTL share these semantics, which the
register table does not state:

- Little-endian. A store to flash halts. v1 SRAM and MMIO accesses are
  words, except the UART data byte. An unaligned access halts.
- `GPIO_OUT` is readable, so a blink can toggle through a
  read-modify-write. GPIO input, direction, and pin IRQ are out of v1.
- `TIMER_COUNT` needs a width, a definition of a tick (cycle, or a
  testbench step), whether a match reloads the counter, and whether the
  match sets a sticky IRQ bit that write-1-to-clear acknowledges. Compare
  value 0 needs a meaning. "Write reloads the compare" leaves those open.
- `UART_RX` is one byte plus a valid bit. A second byte that arrives
  before the read either overwrites or is dropped, and the IRQ-pending
  rule for that case is fixed. There is no FIFO, baud, or TX-ready bit.
  `print` and the echo program share `UART_TX`, so the echo's expected
  stream includes any `print` bytes.
- The flash wait state is paid per byte fetched. A multi-byte opcode pays
  it on every extra byte. v1 has no fetch buffer, as the lock says.

The latch and `micropython.schedule` are different events. Phase 5's text
runs the callback from the latch and then forbids it to allocate.

- The latch sets a status bit. It does not run Python and does not
  allocate.
- At the next opcode boundary the core may run one queued callback as a
  normal call. That call may allocate and may call other functions.
  "Callbacks do not nest" means a second IRQ waits until the callback
  returns.
- A callback that appends to a list is legal. Treating allocation as
  `MemoryError` makes the blink test pass and makes a driver callback
  fail. That diverges from MicroPython; the phase 5 text drops that rule.
- Queue entries are `(function, argument)`. Upstream's default depth is 4
  (`MICROPY_SCHEDULER_DEPTH`). v1 locks a depth. A full queue raises
  `RuntimeError`, which is what `micropython.schedule` does.
- No MMIO register holds the Python callable. A builtin stores it, and
  that slot is a GC root ([finding 6](#6-gc)). The timer callback is
  invoked with the timer object. Phase 5 therefore includes the slice of
  `machine.Timer`, `machine.Pin`, and `machine.UART` that the blink and
  echo programs call. Unix `machine` is a different peripheral model
  (`machine.mem*` and a host pin). The host model of these registers is
  the oracle for edges; the unix port remains the oracle for `print`.
- `time.ticks_ms` and `time.sleep_ms` are how MCU programs wait. Phase 5
  adds a `time` builtin driven by this counter, or phase 6 gains a row
  for it beside SPI.
- A container command and a collection are one opcode for interrupt
  purposes, so IRQ latency includes a list grow. Combined with a one-byte
  RX register, the overrun rule above is what makes that testable.

`0xE000_0000` is the Cortex-M system control space. This map uses a
Cortex-M-shaped split and parks sim control there. The window stays
sim-only, and it is not a system-control block on a bus that also has a
Cortex-M.

Halt reasons are an enum in the sim-control page: normal return, uncaught
exception, unsupported opcode, flash store, unaligned access, stack
overflow, step limit. Phase 5's tests read them.

### 8. Phase 6 compiler

The upstream compiler is `py/compile.c` and `py/parse.c`. It is C. This
core executes bytecode, and a second core that runs the C VM is a
non-goal, so there is no MicroPython compiler to freeze into flash. A
phase 6 on-device compiler is a Python program that emits the pinned
bytecode (upstream does not ship one), or the item leaves the product.
The CPython compiler being the wrong source is already stated and is not
sufficient. A REPL also needs line input and `sys.stdin`, which v1 does
not have.

Float, when a program needs it, is IEEE binary32
(`MICROPY_FLOAT_IMPL_FLOAT`). That phase rebuilds the oracle with the same
implementation. The unix default is double, and float text will not match
across that gap. The CPython binary64 unit stays on the other hart.

### 9. Tests and CI in this repository

This repository has no `make test-hw` and no hardware job. Those gates
stay on pycore. Phase 0's exit line that the CPython hart's `make` is
untouched is a constraint on that repository. This repository's phase 0
exit is the `mpycore.json` unit test, the static-qstr snapshot, and a
`mpy-cross` built from the submodule.

The test contract for this tree:

- Each phase has an allow-list of upstream `tests/basics` programs (later
  `tests/micropython` as well), run on the configured oracle and on the
  simulator. The named exit programs stay. They are not the coverage.
- A program outside the opcode allow-list fails at image build, with the
  opcode name in the error.
- Integer programs cover the overflow bounds, unary minus of the minimum
  small int, floor-division signs, `//` and `%` by `-1` and by `0`,
  shifts, `True + 1`, and `is None`.
- Phase 3 keeps the dropped-reference allocation test from the risks
  section and adds a deep live chain for the mark stack.
- A planning-only PR builds nothing. The first PR that adds RTL runs that
  phase's exit test and its allow-list. The job builds `mpy-cross` and the
  configured unix port from `vendor/micropython`.
- `tools/mpy-tool.py` from that submodule is the decoder oracle
  ([finding 2](#2-the-mpy-image-is-larger-than-phase-1-says)).

### 10. Non-goals to add

Added to [Non-goals](#non-goals): filesystem and `open`, threads, `input`
and the REPL, `sys.stdin`, native / viper / inline asm, finalisers,
weakrefs, and `id()`. SPI, I2C, and ADC were already phase 6.

### 11. Doc pages

Added to the [doc contract](#doc-contract): `object_model.md` and
`calling.md` and `builtins.md` with phase 2, `exceptions.md` with phase 4.
`image.md` also records the const-kind reject list and the static qstr
snapshot.

### 12. Audit notes that did not change a disposition

- pycore `371dc007` is the merge of PR #155 on 2026-10-11. The plan's
  "2026-10-13" date is the audit, and the commit id is right.
- `pycore/docs/container_accel.md` at that commit matches the disposition:
  data ready and container ready are the same cycle, and the hart stays
  frozen for the command. The new FSM still follows that rule on 32-bit
  object words. Porting `pycore_ca.sv` would bring the 132-bit entries.
- The prelude sentence in the original "MicroPython, as the target
  runtime" section described an older fixed-field prelude. It is corrected
  above to the `py/bc.h` interleave. The peripheral lock said "these four"
  over a six-register table; the lock is the six registers.
