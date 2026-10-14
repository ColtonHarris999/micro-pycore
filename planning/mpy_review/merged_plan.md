# MicroPython microcontroller core

Status: **phase contract, reconciled 2026-10-14.** The product decisions
are [`micropython_pivot_plan.md`](../micropython_pivot_plan.md) (D1–D7 and
§9). This file is the phase text those decisions run on. It folds the
three reviews of the original draft. The original draft stays at
[`micropython_mcu_plan.md`](../micropython_mcu_plan.md). The review
inventory is [`final_review_report.md`](final_review_report.md).

The pin is MicroPython **v1.29.0** (`0fd6c573`). Opcode numbers, operand
layouts, and object bit-masks are read from that tag into
`pycore/targets/mpycore.json`. They are not copied into this file.

Owner decision, 2026-10-14: cover as much of that pin as this month can
run. One `.mpy` module loads another the way the unix oracle does, and
`*args` binds the way the pin binds it. The standard library is not
rewritten this month. The deferral list is in
[Coverage this month](#coverage-this-month).

## Where the truth lives

```text
planning/micropython_pivot_plan.md     product decisions and the week schedule
planning/mpy_review/merged_plan.md     this phase contract
        │
        ▼
pycore/targets/mpycore.json            catalog copied from the pin (phase 0)
vendor/micropython                     the pin, as a submodule (phase 0)
pycore/docs/mpy_*.md                   the retarget, written as each phase lands
        │
        ▼
pycore/docs/*                          the CPython hart as it stands today
```

Paths in this file are paths in this repository. The tree is the pycore
import at `43d791a`. There is no separate `mpycore/` tree.

## What is being built

Retarget the hart that is already in this repository. Keep its integer
ALU, container FSMs, call binder, GC, and exception machinery. Replace
the CPython 3.14 front end with a decoder for the pinned MicroPython
bytecode. Replace the 16 MB cache hierarchy with execute-in-place flash,
256 KB of SRAM, and MMIO. The unix port of the pin, built as the variant
in [v1 locks](#v1-locks), is the stdout and stderr oracle. Interrupts,
`machine`, `time`, `gc`, and a UART REPL come after the bytecode runs.
The on-device compiler is the Python compiler already in
`pycore_firmware/compiler/`, retargeted to emit this bytecode and shipped
as a frozen `.mpy`.

The pivot plan's weeks run several tracks at once. The phases below are
the gates those weeks have to pass. A later track may prepare docs and
host tools before the previous gate is green. A gate, once green, stays
green.

| Pivot week | Gate that week must pass |
| --- | --- |
| 1 | Phase 2 |
| 2 | Phase 3, and the exception, closure, and default-argument parts of phase 4 |
| 3 | The rest of phase 4, and blink plus echo from phase 5 |
| 4 | Phase 6 through the REPL cut line in the pivot plan §7 |

## Audit of the machine at `43d791a`

Measured in this tree, which is that import. The draft's audit commit
`371dc007` is three commits earlier (pycore PR #155) and is the ancestor
of this snapshot.

| Fact | Where |
| --- | --- |
| Value 128 bits, tag 4 bits, entry 132 bits | `PYCORE_VAL_WIDTH`, `PYCORE_TAG_WIDTH` in `pycore/rtl/pycore_defs.svh` |
| Register file 256 entries, live window 240 | `PYCORE_RF_DEPTH` in the same header |
| RF spill LIFO is 256 KB at `0xF40000` | `pycore/docs/memory_hierarchy.md` |
| Frame stack is 32 KB, 1024 descriptors, at `0xF01000` | `pycore/docs/architecture.md` |
| 95 catalogued opcodes: 70 `execute`, 8 `partial`, 13 `trap`, 3 `reject`, 1 `strip` | `pycore/targets/pycore.json` |
| RTL is 41,994 lines under `pycore/rtl`, including `attic/` | counted in this tree |
| `pycore_defs.svh` is 3,833 lines. `pycore_core.sv` is 4,935 | counted in this tree |
| Compiler is 7,000 lines under `pycore_firmware/compiler/` | counted in this tree |
| 86 Python files under `pycore_firmware/builtins/` | counted in this tree |
| 597 hardware tests in 14 areas of `pycore/programs/hw_tests.toml`, plus gate tables | counted in this tree |
| 523 `.py` files under `pycore/programs/` (512 at the top level, 11 in subdirectories); 105 `.hex` and 20 `.meta` fixtures | counted in this tree |
| `make test-host`, `make test-hw`, `make test-compiler-vs-cpython`, and `make test-caching` exist | `Makefile` |
| Docs-only and `planning/` changes skip the hardware jobs | `.github/workflows/all-tests.yml` |
| Container commands finish in the cycle they report data ready, and the hart stays frozen for the command | `pycore/docs/container_accel.md` |
| GC aborts an instruction before its first architectural commit, collects, and re-dispatches | `pycore/docs/gc.md` |
| The only console register today is `CONSOLE_TX` at `0xF0` | `excore/docs/mmio_map.md` |
| Synthesis cited for the hart is about 86.5k cells / 4.8k flops | `pycore/docs/limitations.md` |

The spill LIFO is the same size as the whole MCU SRAM. Phase 0 resizes
it. Copying it in unchanged would leave no GC pool.

## MicroPython, as the target runtime

Phase 0 checks out v1.29.0 at `vendor/micropython`. `mpy-cross` from that
checkout emits the bytecode. The properties below are what phase 0's
catalog has to record from the tag. The names of the source files are the
stable part. The numeric encodings are not.

- **The `.mpy` file is a container.** A four-byte header, then one qstr
  table and one const-object table for the module, then a tree of raw-code
  objects. A nested `def`, a class body, and a comprehension are child raw
  code. They are not entries in the const-object table. The RTL fetches a
  flash image the host tool has linked. It does not parse `.mpy`.
- **Bytecode operands are indexes into that module's tables.** With
  persistent code enabled, a qstr operand indexes the module qstr table
  and `LOAD_CONST_OBJ` indexes the const table. `MAKE_FUNCTION` indexes
  the child raw-code table. The bytes are not rewritten at run time. Ids
  at or below the pin's `QSTR_LAST_STATIC` (`py/persistentcode.c`) are
  stored as ids. Phase 0 snapshots the static list from
  `py/makeqstrdata.py` and the image tool uses those ids.
- **A function body starts with the bit-interleaved prelude in
  `py/bc.h`.** The signature carries state count, exception-stack depth,
  scope flags, and the argument counts. A second interleaved value carries
  the source-info length and the closure-cell count. Source-info bytes and
  one byte per cell follow. The first opcode is after those bytes. A
  decoder that stops at "state, exception stack, flags" fetches source
  info as code. Phase 1's decoder returns the opcode-start offset and the
  line-info span.
- **There is no `CACHE` opcode and no `EXTENDED_ARG` word.** `.mpy` version
  6 stopped using the old inline map-cache flag in the header
  (`py/persistentcode.h`).
- **The header check is the pin's loader.** Major version must match.
  Sub-version is checked when the architecture nibble is not none.
  Bytecode-only files are not rejected for sub-version alone, and the
  pinned `mpy-cross` writes feature byte `0x00` for them (`4d 06 00 1f`
  at 31-bit small ints). The source macro `MPY_SUB_VERSION` is 3; that
  value is written only into a native file. The small-int
  width in the header has to fit the runtime. v1's image tool also rejects
  any architecture other than none, an architecture-flags value, a raw-code
  kind other than bytecode, and const kinds the running phase does not
  execute (float and complex consts wait until phase 4; an int that does
  not fit the runtime integer width is a link error).
- **Names** are qstrs. Globals and attributes key on qstr. String literals
  in bytecode are qstrs (`LOAD_CONST_STRING`). A heap `str` is the result
  of an operation that builds one.
- **The v1 object word is the hart's existing slot** (D2): 32 bytes through
  bring-up, then an 8-byte packed slot. MicroPython's 4-byte `REPR_A` word
  is the post-deadline density step. The oracle still uses `REPR_A`, so
  stdout matches a 32-bit port. When that density step lands, a ROM object
  must not be placed at address 0 or 4: in a non-debug build those words
  are `MP_OBJ_NULL` and `MP_OBJ_SENTINEL` (`py/obj.h`), and
  `MP_OBJ_STOP_ITERATION` is the null word. The GC follows a pointer only
  when it addresses a block head in the SRAM heap window.
- **Integers** are the hart's 64-bit datapath, in MicroPython's `LONGLONG`
  mode (D3). Overflow raises `OverflowError`. Small ints inside the oracle's
  32-bit `REPR_A` word are 31 bits; a value that does not fit promotes to
  the 64-bit int. ESP32 and RP2 default to MPZ, which stays after the
  deadline. `mpy-cross` is built with MPZ and double even when the runtime
  is not (`mpy-cross/mpconfigport.h`), and constant folding is on. A test
  of overflow, division, or an add uses runtime values. A literal expression
  the cross compiler can fold is a const object, not an ALU program.
- **Float** is IEEE binary32. **Complex** stays. Both match D3. The CPython
  binary64 unit remains in the tree until the shrink after the deadline;
  every float result the oracle sees is rounded to binary32.
- **Strings** are UTF-8. The oracle leaves
  `MICROPY_PY_BUILTINS_STR_UNICODE` at the extra-features default, which is
  on, so indexing follows the pin's Unicode path. Case conversion above
  ASCII is checked against the oracle before any table is deleted.
- **GC is always on.** The rule is the one in `pycore/docs/gc.md`: an
  allocation that does not fit aborts the opcode before the first
  architectural commit, the core collects, and the opcode is
  re-dispatched. The C VM collects inside the allocator after earlier
  writes in the same opcode (`py/gc.c`). Porting that order would commit
  state the abort rule then has to undo. Container commands keep the
  current rule: the object is finished before a reader sees it.
- **Libraries** are frozen `.mpy` modules in flash, plus native modules
  for `machine`, `time`, `gc`, `micropython`, and `sys`. `import` runs
  another module's bytecode. `machine` is not a frozen `.mpy`. The
  standard library is linked from `.mpy` the pinned `mpy-cross` produced,
  or it is absent. It is not rewritten this month.
- **Interrupts.** A hard IRQ is taken at the next bytecode boundary with
  the heap locked, so an allocation in that handler raises `MemoryError`.
  A soft IRQ and `micropython.schedule` queue `(function, argument)` and
  the VM runs one callback at the pin's jump opcodes (`py/vm.c`,
  `pending_exception_check`). The callback may allocate. It does not nest.
  An exception in a scheduled callback is printed and does not unwind the
  interrupted program (`mp_call_function_1_protected` in
  `py/runtime_utils.c`). The latch itself does not allocate and does not
  run Python.
- **The schedule depth** for v1 is 8, matching ESP32, RP2, and STM32. The
  pin's default is 4 (`py/mpconfig.h`). The oracle variant sets 8. A full
  queue raises `RuntimeError` from `micropython.schedule`.
- **Generators and `asyncio`** stay after the deadline, as in the pivot
  plan. Closures and defaults are in phase 4, before a scheduled callback
  is allowed to be a nested function and before `super()`.

`mpy-cross` is invoked with `-msmall-int-bits=31`, no `-march`, and an
explicit `-O0` until a revision says otherwise. A distro `mpy-cross` is
the wrong bytecode.

## Coverage this month

A program the pinned `mpy-cross` accepts and the unix oracle runs is in
scope, unless it needs something on the deferral list. The image tool
rejects native code, viper, and inline asm. It accepts `*args`,
`**kwargs`, `import`, `from ... import`, `from ... import *`, and
relative import.

Import looks up a frozen module table. There is no filesystem this month,
so a loose `.mpy` on a host path is linked into that table by the image
tool. It is not opened at run time. `sys.modules` caches the module, and
a second import does not run the body again. A missing name raises
`ImportError` with the pin's message (`py/builtinimport.c`). `import *`
is `IMPORT_STAR`, which calls `mp_import_all` (`py/runtime.c`): the names
in `__all__` when that list exists, otherwise the public names that do
not start with `_`.

`*args` follows `mp_setup_code_state` in `py/bc.c`. Extra positional
arguments become a tuple. A call that passes no extras still binds the
empty tuple. A function without the varargs scope flag raises the
oracle's `TypeError` when it is given too many positionals. `**kwargs`
is the same function: surplus keywords go in a dict when the callable
has that flag, and a keyword the signature does not accept raises the
oracle's `TypeError` when it does not. Both are phase 4, not an
image-build reject.

Still deferred, and the only reasons to reject a program the oracle would
run:

| Deferred | Why it waits |
| --- | --- |
| Rewriting the standard library | This month links `.mpy` or leaves the module absent. It does not reimplement `json`, `os`, `re`, and the rest |
| Filesystem and `open` | Import uses the frozen table. A VFS is later |
| Native, viper, inline asm | No native emitter |
| Generators, `async`, `asyncio` | After the deadline, as in the pivot plan |
| MPZ | After the deadline. `LONGLONG` is the v1 int |
| Finalisers and weakrefs | Off on the oracle variant and on the hart |

## v1 locks

Changing one of these is a revision of this file and of the pivot plan
together.

| Lock | Choice |
| --- | --- |
| Tree | This repository. Retarget `pycore/rtl` in place. No second core tree |
| Pin | MicroPython v1.29.0. Catalog in `pycore/targets/mpycore.json` |
| Oracle | The unix port built as the variant below, 32-bit (`i686-linux-gnu-` or the pin's own 32-bit CI recipe). Stdout and stderr compared separately, addresses masked |
| Variant | `LONGLONG`, binary32 float, `REPR_A`, extra-features ROM level, error reporting normal, scheduler depth 8, finalisers off, emergency exception buffer on, stack check on. Unicode `str` left at the extra-features default |
| Toolchain | `mpy-cross` from the pin, flags above. New flash-image tool. `tools/mpy-tool.py` from the pin is the independent decoder |
| Object word | D2. Stage A: existing 32-byte slot. Stage B: 8-byte packed slot, during phase 3. `REPR_A` after the deadline |
| Integers | 64-bit `LONGLONG`. Overflow is `OverflowError`. MPZ is later |
| Float, complex | binary32 float and complex on |
| Code memory | Flash, byte-addressed, execute in place. PC is a byte address. Runtime-compiled code lives in SRAM and is also byte-addressed. The 8-byte fetch buffer holds instruction bytes only |
| Data memory | 256 KB SRAM. The split below. The GC pool is the only region `-X heapsize` names |
| GC | Always on. Abort before the first architectural commit, then re-dispatch. Finalisers off |
| Harts | One. `print` stores bytes to `UART_TX` on this hart |
| Interrupts | Hard at the next bytecode boundary, heap locked. Soft at the pin's jump opcodes, heap unlocked, depth 8 |
| Compiler on device | The existing Python compiler, retargeted. `py/compile.c` is not frozen into flash |
| Success metric | Stdout and stderr match the oracle. Cycles are recorded and, in the benchmark track, compared with boards on `perf_bench` |

### Oracle variant

The stock `standard` unix variant is a different machine: on a 64-bit host
the `REPR_A` small int is 63 bits, long ints are MPZ, float is double,
error reporting is detailed, finalisers are on, and the default heap is
`1MB * sizeof(mp_uint_t) / 4` (`ports/unix/main.c`,
`ports/unix/variants/mpconfigvariant_common.h`). The upstream `longlong`
variant uses `REPR_C`. Phase 0 adds `variants/mpycore` in this repo, as
the pivot plan §3.2 describes, plus the depth, finaliser, emergency
buffer, and stack-check settings in the lock table.

From phase 3 the harness passes `-X heapsize` equal to the GC pool only.
Programs under test do not print `sys.platform` or `sys.implementation`
unless both sides are pinned to the same strings. The oracle run is
unbuffered. Tracebacks are stderr on the unix port
(`MICROPY_ERROR_PRINTER`) and a distinct channel on `UART_TX` in the
simulator. The diff says which bytes are which.

### Memory map

| Window | Base | Size | Contents |
| --- | --- | ---: | --- |
| Flash | `0x0000_0000` | 512 KB | linked image: frozen bytecode, qstr pool, builtin objects |
| SRAM | `0x2000_0000` | 256 KB | frame reserve, resized RF spill, schedule ring, handler table, GC pool |
| MMIO | `0x4000_0000` | 4 KB | UART, GPIO, timer, IRQ |
| Sim control | `0xE000_0000` | 256 B | halt reason, cycle counter. Simulation only |

The first 8 bytes of flash are reserved, so a later `REPR_A` pointer never
aliases the null word or the sentinel word.

SRAM is 1-cycle. Flash has a wait-state parameter, default 1. There is no
L2 and no 16 MB backing store in the programming model. The fetch path
keeps an 8-byte buffer so a multi-byte opcode pays the flash wait state
on the first byte of the group (pivot plan §1.0). That buffer holds
instruction bytes only. It does not cache MMIO, and a data load from
flash is not an instruction prefetch.

Phase 0 locks the SRAM split in `pycore/docs/mpy_memory_map.md` after
measuring it. The frame region today is 32 KB and the spill region is
256 KB (`pycore/docs/architecture.md`). The spill is resized down. The
measurement is the calls area (`make test-calls`), which already prints
`RF spill_count` from the testbench, plus the frame high-water mark. The
reserve is that high-water mark plus the schedule ring and the handler
table. The GC pool is the remainder. Until that page lands, no other
phase hard-codes a pool size.

### Peripheral registers (v1)

Word offsets from `0x4000_0000`. The six rows that were in the draft stay
at these offsets. Added registers start at `0x18`.

| Offset | Name | Rule |
| --- | --- | --- |
| `0x00` | `UART_TX` | A committed store of bits 7:0 prints that byte. No baud and no FIFO |
| `0x04` | `UART_RX` | One-byte buffer. A read returns bits 7:0 and pops the byte. Bit 31 is data-valid. A second byte that arrives while bit 31 is set is dropped, and bit 30 sticks as overrun. Writing 1 to bit 30 clears overrun |
| `0x08` | `GPIO_OUT` | Read/write. A blink toggles with a read-modify-write |
| `0x0C` | `TIMER_COUNT` | Read the counter. A write sets the compare period. Zero disables the timer. On match the counter returns to zero and the timer IRQ bit sets. The phase 5 testbench advances the counter; a cycle-stepped mode is a later plusarg |
| `0x10` | `IRQ_STATUS` | Read pending. Write 1 to clear. Accepting a callback for a source also clears that source. An edge during the callback sets the bit again |
| `0x14` | `IRQ_ENABLE` | Mask. Bit 0 timer, bit 1 UART RX, bit 2 GPIO |
| `0x18` | `IRQ_HARD` | Per source. 1 delivers hard, 0 delivers soft |
| `0x1C` | `IRQ_GIE` | Global enable. `machine.disable_irq` returns the old value |
| `0x20` | `IRQ_ACTIVE` | Read-only. A hard handler is running |
| `0x24` | `IRQ_TABLE` | Base of the handler table in SRAM. One function and one argument per source. The table is a GC root |
| `0x28` | `SCHED_HEAD` | Schedule ring head |
| `0x2C` | `SCHED_TAIL` | Schedule ring tail |
| `0x30` | `GPIO_IN` | Input word. The testbench writes it. Pin IRQ uses this |
| `0x34` | `GPIO_EDGE` | Two bits per pin, low pin in the low bits: off, rising, falling, both |

`GPIO_IN` and `GPIO_EDGE` are in v1 because the pivot plan's debounce test
needs a pin IRQ. Direction control beyond "output word plus input word"
waits.

Little-endian. A store to flash, or a load or store outside flash, SRAM,
and the two MMIO windows, halts with the bus-fault reason. v1 SRAM and
MMIO accesses are words, except the UART data byte. An unaligned access
halts.

`CONSOLE_TX` at `0xF0` remains until `print` moves to `UART_TX`. The
sim-control window is not a Cortex-M system-control block. It stays
simulation-only even if a later bus also has a Cortex-M.

Halt reasons, as names in the sim-control page: clean return, uncaught
exception, unsupported opcode, bad image, flash store, unaligned access,
bus fault, stack overflow, step limit.

The overrun bit and the testbench timer tick are choices so the echo and
blink tests have a stable expected trace. They are not MicroPython
register facts. `pycore/docs/mpy_peripherals.md` is where a change to
either choice is written down before the RTL.

## Disposition of the current tree

| Piece | Disposition |
| --- | --- |
| `pycore/rtl` execution engine: ALU, container FSMs, call binder, GC, exception match | **Keep and retarget.** The new work is the bytecode decoder and the memory map |
| Safe-point GC rule in `pycore/docs/gc.md` | **Keep.** Extend the root set in phase 3 |
| CA command rule in `pycore/docs/container_accel.md` | **Keep.** The same FSM, on the slot width D2 is using that week |
| 64-bit integer datapath | **Keep.** Trap 21 becomes `OverflowError` |
| `CONSOLE_TX` "a store is a printed byte" | **Reuse the idea** at `UART_TX` |
| L1/L2, 16 MB RAM, excore in the product build | **Remove from the product build.** Sources stay until the replacement gate is green |
| binary64 FPU | **Keep the datapath for now.** Round results to binary32. Shrink after the deadline |
| On-device Python compiler | **Retarget** to this bytecode. Ship as a frozen `.mpy` |
| `py/compile.c` and `py/parse.c` from the pin | **Do not freeze.** This hart does not run the C VM |
| CPython 3.14 decoder, `CACHE` / `EXTENDED_ARG`, exception tables | **Replace** with the MicroPython decoder and the exception stack |
| Insertion-order dict sidecar | **Remove** once the hash-order model matches the oracle |
| `image_from_source.py` and the CPython image tools | **Replace** with `mpy-cross` and the flash-image tool |
| `planning/master_plan.md`, `planning/gc_plan.md`, `planning/accelerator_split_plan.md` | **CPython-hart history.** Take an item only when this plan or the pivot plan names it |

## Phases

### Phase 0 — Pin the release and the SRAM budget

Docs, catalog, submodule, oracle variant. No RTL edit.

- Add `vendor/micropython` at v1.29.0.
- Write `pycore/targets/mpycore.json` with the `.mpy` version and
  sub-version read from `py/persistentcode.h`, the object-word masks read
  from `py/obj.h`, and one row per opcode from `py/bc.h` and `py/bc0.h`:
  operand format, stack effect, and a phase number or `reject`. Record the
  prelude field names and the const-kind reject list. Record the immediate
  ids of `None`, `False`, and `True` from the pin.
- Snapshot the static qstr list.
- Add the `mpycore` unix variant and build `mpy-cross` from the same
  commit.
- Write `pycore/docs/mpy_memory_map.md` with the windows above and the
  measured SRAM split.
- Disassemble one `while`, one `def`, one `class`, one `with`, and one
  `for` with `mpy-cross` and keep the dumps as fixtures, so the catalog
  matches the emitter.

**Exit.** `python3 pycore/tools/mpy_pin_check.py` exits 0 and prints
`mpy-version: 6.3` equal to `MPY_VERSION` and `MPY_SUB_VERSION` in
`vendor/micropython/py/persistentcode.h`, plus `static-qstr: ok`.
`make test-calls` has been run and `pycore/docs/mpy_memory_map.md` records
the spill high-water mark and the resulting GC pool size.
`git diff --exit-code -- pycore/rtl` is empty for this phase's commit.

### Phase 1 — Flash image and prelude

- The host tool reads a `.mpy` from the pinned `mpy-cross` and links a
  flash image at `0x0000_0000`: static qstrs, the module qstr table, const
  objects this phase accepts, the child raw-code tree, and bytecode. The
  image has a module directory of one entry. Phase 4 adds entries. Qstr
  ids are assigned once for the whole image.
- The prelude decoder implements `py/bc.h` and returns the opcode-start
  offset and the line-info span.
- A native or viper raw-code kind, a bad major version, a small-int width
  the runtime cannot hold, and a float or complex const are link errors
  that name the rejected kind. A bytecode-only file with a different
  sub-version is accepted. The catalog still records the sub-version.

**Exit.** `python3 pycore/tools/mpy_image.py --check pycore/programs/mpy/phase1`
exits 0. The fixture set contains a branch, a static qstr, a non-static
qstr, a small int outside the multi-opcode window, a tuple const, and a
child function. Its disassembly matches
`python3 vendor/micropython/tools/mpy-tool.py -xd` on the same `.mpy`.
A second fixture with a native architecture exits non-zero and the error
names the architecture. No simulator yet.

### Phase 2 — Bytecode front end on the existing engine

Byte fetch, MicroPython decode of the integer subset, the prelude cache,
and `print` of an int through `UART_TX`. The call path is the existing
call FSM. Frames come out of the reserved frame region. This phase does
not change the GC heap policy.

In scope: load and store of locals and of module globals, small-int
constants including a value outside the multi-opcode window, add,
subtract, and compare, jumps, a positional call, `return`, `POP_TOP`.
`print` is the ROM builtin: it finds `print` in the builtins dict, writes
the decimal text and the newline, and returns `None`.

Out of this phase: container growth, classes, `import`, `with`, closures,
generators, and a `for` over `range`. The counted loop is a `while` on a
local. `for` arrives with iterators in phase 3.

**Exit.** `make test-mpy-phase2` exits 0. The program is a `while` that
adds two locals, one of them negative, then prints the sum. Stdout matches
the oracle, including the newline byte. A second program is a positional
call whose return value is printed. The simulator prints the cycle count.
A trace mode prints the PC, the opcode name, and the stack depth; the
acceptance check is the stdout diff, not the trace.
`python3 vendor/micropython/mpy-cross/mpy-cross -O0` on `print(1 + 2)` is
recorded as a folded const, and that program is not the ALU test.

### Phase 3 — Containers, dict order, GC

- Heap objects for `str`, `bytes`, `list`, `tuple`, `dict`, and `set`.
  Layout may differ from both the 32-byte stride and MicroPython's C
  structs. Observable order and printed values match the oracle.
- Dict and set order are the pin's hash table: open addressing, the growth
  table in `py/map.c`, djb2 string hashes masked to the width
  `MICROPY_QSTR_BYTES_IN_HASH` has at extra features, deleted slots as the
  sentinel. A host model of that map is checked against the oracle before
  the RTL changes. `OrderedDict` is the ordered case; a normal `dict` is
  not.
- List growth follows the command rule. The oracle doubles a full list and
  uses a minimum allocation of four slots (`py/objlist.c`). Matching the
  printed contents is required. Matching the append index where
  `MemoryError` fires is not, while the slot size differs from the
  oracle's.
- Mark-sweep stays always on. Roots, written in `pycore/docs/mpy_gc.md`
  before the engine change: every live slot of every suspended frame
  (locals included, not only the value-stack slice below the stack
  pointer), the exception stack's saved exception words, module globals,
  the builtins dict, `sys.modules` once import exists, machine registers
  that hold object words, the schedule ring, the handler table, the
  pending-exception slot, and the emergency exception object. Flash
  bytecode and ROM objects are not collected. The function object on the
  frame is what keeps a heap function alive.
- The mark-stack overflow behavior stays the rescan rule already in
  `pycore/docs/gc.md`. A deep live chain is a phase 3 test. The pin's own
  collector uses a fixed stack of `MICROPY_ALLOC_GC_STACK_SIZE` and
  rescans; this hart does not switch to that stack.
- `MemoryError` is raised from a preallocated emergency object. A dropped
  reference can be allocated again. One allocation larger than the GC pool
  raises `MemoryError`. The oracle is run with `-X heapsize` equal to that
  pool.
- Stage B's 8-byte slot lands in this phase, behind one shared
  encode/decode helper, as the pivot plan's memory track describes.
- `LOAD_METHOD` / `CALL_METHOD` for a native method such as `list.append`,
  `LOAD_SUBSCR` / `STORE_SUBSCR`, and `GET_ITER` / `FOR_ITER` / `range` are
  in this phase. `for` is not a generator. End of iteration is the
  stop-iteration word, which a non-debug build aliases to the null word.

**Exit.** `make test-mpy-phase3` exits 0. An append loop matches oracle
stdout. A program that allocates and drops references then allocates again
succeeds. A program that asks for one object larger than the pool raises
`MemoryError` and the message matches the oracle. A dict and a set of
int and string keys print in the oracle's order. `make test-gc` still
passes on the CPython configuration until the product build drops it.

### Phase 4 — Exceptions, classes, import, with

- Hardware traps that are Python exceptions on the oracle become raises:
  `TypeError`, `ZeroDivisionError`, `OverflowError`, `IndexError`,
  `KeyError`, `MemoryError`, `AttributeError`, `ValueError`. The message
  text is copied from the oracle at normal error reporting.
- Also seeded, because ordinary programs raise them: `NameError`,
  `RuntimeError`, `ImportError`, `AssertionError`, `StopIteration`,
  `OSError`, `KeyboardInterrupt`, `SystemExit`, `NotImplementedError`, and
  the `Exception` / `BaseException` roots. An unassigned local raises
  `NameError`. A failed frame allocation raises `RuntimeError` with the
  pin's recursion message (`mp_raise_recursion_depth` in `py/runtime.c`),
  and the test checks the message, not the depth.
- An uncaught exception prints the pin's traceback, using the prelude
  line-info span, on the stderr channel, then halts with the uncaught
  reason. A clean return uses a different halt reason. Default instance
  reprs contain addresses; the diff masks them. `id()` is not part of any
  expected output.
- `with` runs `__enter__` and `__exit__` on the success path, on an
  exception path, and on an `__exit__` that swallows. `return` or `break`
  inside `with` or `finally` is `UNWIND_JUMP`.
- Runtime `class` is `LOAD_BUILD_CLASS` and the ROM `__build_class__`.
  The exit class has one base, an `__init__`, and a method. `super()` is
  in this phase and needs the `__class__` cell, so closures land in this
  phase first. Multiple inheritance and metaclasses are out of the exit
  test.
- Closures (`MAKE_CLOSURE`, `LOAD_DEREF` / `STORE_DEREF`, cells) and
  defaults (`MAKE_FUNCTION_DEFARGS`, including a non-literal default) are
  in this phase. Keyword calls are the existing binder: the operand
  carries a positional count and a keyword count, and keywords sit on the
  stack as qstr/value pairs. `*args` and `**kwargs` are in this phase and
  match [Coverage this month](#coverage-this-month). A scheduled callback
  in phase 5 is a module-level function or a closure this phase can
  already build.
- `import` loads another `.mpy` module and runs it. The forms are
  `import m`, `from m import name`, `from m import *`, `import m as z`,
  and a relative import inside a package. One module object per name,
  cached so the body runs once. `__name__` is `"__main__"` on the entry
  module and the module's name on every other. Two frozen modules may
  import each other. A name that is not in the frozen table and is not a
  native module raises `ImportError`. This phase does not rewrite
  standard-library sources. It runs the `.mpy` the image tool linked.
- binary32 float results and `str.format`, including the f-string rewrite
  the pin's lexer does (`py/lexer.c`), land here. Float text is the pin's
  binary32 formatter, tested on the host before it is firmware.

**Exit.** `make test-mpy-phase4` exits 0. One flash image holds the
modules below. Stdout matches the oracle on each program.

- A class with a base and a method, a caught `ZeroDivisionError`, and a
  `with` on the success path and on a swallowed exception.
- Module `a` imports module `b` and calls a function defined in `b`.
  `from b import *` binds `b`'s public names and does not bind `_private`.
  Importing `b` again does not run its body a second time. Importing a
  name that was not linked raises `ImportError` with the oracle's
  message. Package `pkg` contains `pkg.sub`, and `from .other import x`
  inside `pkg.sub` binds `x`.
- `def f(a, *rest)` printed for `f(1)`, `f(1, 2, 3)`, and `f(1, *xs)`
  matches the oracle, including the empty tuple. `def g(*a, **k)` printed
  for a call with extra keywords matches the oracle. A call that passes
  too many positionals to a function without `*args`, or a keyword that
  function does not accept and does not collect with `**kwargs`, raises
  the oracle's `TypeError`.
- A second program divides by zero with no handler: the traceback channel
  matches the oracle text with addresses masked, and the halt reason is
  the uncaught reason. A clean return of the first program uses the
  clean-return reason.

### Phase 5 — Microcontroller surface

- The registers in the table above, the native `machine` module (`Pin`,
  `UART`, `Timer`, `mem32`, `idle`, `disable_irq` / `enable_irq`), and the
  `time` tick functions the pivot plan §1.1 names.
- The unix port's `machine` module is not this map. Edge checks use the
  host model in `pycore/docs/mpy_peripherals.md`, written before the RTL.
  `print` still uses the unix oracle.
- Hard delivery and soft delivery follow the locks. A hard handler that
  allocates prints the pin's uncaught-IRQ message for `MemoryError` and
  does not unwind the main program. A soft callback may allocate, takes
  one argument, and does not nest. The ninth `micropython.schedule` raises
  `RuntimeError`.
- After the entry module returns, a program that armed a timer keeps
  polling until the testbench tick budget ends, via `machine.idle`. The
  blink program is bounded by that budget.
- `KeyboardInterrupt` from the configured interrupt character is raised at
  the same jump points as a soft callback.

**Exit.** `make test-mpy-phase5` exits 0. Blink: the testbench counts
`GPIO_OUT` edges at the programmed period. Echo: RX bytes that fit come
back on TX, and one overrun sets bit 30 while leaving the unread byte.
`sched_full` raises on the ninth schedule and the message matches the
oracle. `hard_irq_alloc` prints the uncaught-IRQ `MemoryError` text. The
edge trace matches the host register model. The unix port is not asked to
finish an infinite loop.

### Phase 6 — Compiler, REPL, and what waits

The compiler track from the pivot plan §2 runs here. `py/compile.c` is not
a source that can be frozen. The acceptance rule is the pivot plan's: the
compiler accepts what `mpy-cross` v1.29.0 accepts inside the supported
scope, and otherwise raises the same `SyntaxError` text.

**Exit.** `python3 pycore_firmware/compiler/test_mpy_emit.py --milestone C1`
exits 0: the wrapped `.mpy` run on the oracle prints the same stdout as
the source. The later rows are the same command at C2 and C3, then
`make test-mpy-repl` for the raw REPL. Each row's expected result is in
the table.

| Milestone | Exit command | Expected result |
| --- | --- | --- |
| C1 expressions, assignment, `if` / `while` / `for`, calls | `python3 pycore_firmware/compiler/test_mpy_emit.py --milestone C1` | The wrapped `.mpy` runs on the oracle with the same stdout as the source. Byte-identity with `mpy-cross` is reported, not required yet |
| C2 `def`, closures, defaults, `*args` / `**kwargs`, `try` / `except` / `finally`, comprehensions | the same command with `--milestone C2` | Same oracle stdout rule, including the phase 4 `*args` program |
| C3 `class`, `import`, `with`, `const`, `:=`, f-string rewriting | `--milestone C3` | Same rule, and the class and import programs from phase 4 compile on the host |
| C4 device and REPL | `make test-mpy-repl` | The simulator's UART accepts the raw REPL sequence the pivot plan §6 describes, and `mpremote` against that pty runs a phase 4 program |

If the calendar runs out, the REPL ships with C2 scope, which is the pivot
plan's cut line.

These stay unstarted until a program needs them. Landing one does not
start the next.

| Item | Trigger | Constraint |
| --- | --- | --- |
| Generators, `async`, `asyncio` | After the deadline | `YIELD_VALUE` and `YIELD_FROM`. `uasyncio` is a frozen library and counts against the 512 KB flash. Its `.mpy` can be linked later; it is not rewritten this month |
| SPI, I2C, ADC, PWM, WDT | A driver needs the registers | New offsets past `0x34`. The same IRQ rule |
| MPZ | A benchmark needs `bm_pidigits` | Post-deadline. `LONGLONG` stays the v1 int |
| 4-byte `REPR_A` slot | Density work after the deadline | Honor the address 0 and 4 reservation |
| Wider than the 8-byte fetch buffer | A measurement shows the 8-byte buffer missing | Still instruction bytes only. It does not cache MMIO |

## What stays in force on the CPython configuration

Until a phase's exit replaces a CPython gate, that gate still runs.
`make test-hw` and `make test-compiler-vs-cpython` are gates of this
repository today. A phase that removes a subsystem deletes or rewrites
the tests in the same change and says so. New CPython opcode work, new
exception-table work, and new insertion-order dict work do not start.
`planning/cleanup_report.md` still applies to code this plan has not
retargeted.

## Non-goals

- Executing CPython 3.14 wordcode on the product build.
- Bit-identical heap layouts with MicroPython's C structs.
- A second core that runs the MicroPython C VM, and freezing `py/compile.c`.
- `__del__` finalisers, weak references, and `id()` in expected output.
- A filesystem and `open` in v1. Import uses the frozen `.mpy` table.
- Rewriting the MicroPython standard library this month. Absent modules
  raise `ImportError`.
- Threads.
- `@micropython.native`, viper, and inline asm. The image tool rejects
  them. The compile error matches `mpy-cross` without `-march`.
- Matching CPython cycle ratios, and assuming a 1 GHz clock.
- `match` and `except *`.

## Risks

- **The prelude and the `.mpy` container are easy to decode short.** Phase
  1 diffs against `mpy-tool.py` before any RTL fetches a byte.
- **`mpy-cross` folds literals and is built with MPZ and double.** Runtime
  tests use non-constant operands. The phase 2 exit is a `while`.
- **Dict order is a hash, and one wrong detail changes many expected
  outputs.** The host model lands before the RTL.
- **Slot size and the GC pool differ from the unix heap.** `MemoryError`
  tests are the dropped-reference test and one oversize allocation. They
  do not pin an append index.
- **The 256 KB spill does not fit in 256 KB SRAM.** Phase 0 measures a
  smaller spill. Skipping that measurement leaves no heap.
- **Roots.** A scan of the value-stack slice below the stack pointer misses
  locals in the pin's frame (`py/vm.c` sets `fastn` at
  `state[n_state - 1]`). This hart keeps its own frames and roots every
  live slot. The phase 3 dropped-reference test is what catches a missed
  root that stdout would hide.
- **Two roadmaps.** The pivot plan governs product decisions. This file
  governs the phase gates. The original draft does not.
- **The unix port is not a board.** The variant closes the config gap.
  Timing traces use the host register model. A Pico remains the spot check
  in the pivot plan §8.

## Test contract

- **Host.** Phase 0 and phase 1 commands above. No Verilator. A change
  that touches only `planning/` and markdown does not add a simulator job
  (`.github/workflows/all-tests.yml`).
- **Device.** One simulator. Programs under `pycore/programs/mpy/`. Each
  exit from phase 2 on is the `make test-mpy-phaseN` target above.
- **Oracle.** The variant in the lock table. From phase 3, `-X heapsize`
  equals the GC pool in `pycore/docs/mpy_memory_map.md`.
- **CPython suite.** Stays green until the phase that replaces it deletes
  or rewrites those tests in the same change. v1 has no cache. The memory
  gate that replaces `make test-caching` is flash wait states 0, 1, and 3
  with the same stdout.
- **Allow-list.** Each phase names the upstream `tests/basics` programs it
  runs, and later `tests/micropython`. A program outside the opcode
  allow-list fails at image build with the opcode name in the error.
- **CI.** The first commit that adds a phase's RTL also adds that phase's
  make target to the hardware workflow. `oracle-build` and `goldens-fresh`
  are the pivot plan §3.6 jobs.

## Doc contract

New pages, written with the phase that makes them true. They do not
overwrite the CPython pages in `pycore/docs/`.

| Page | Phase |
| --- | --- |
| `pycore/docs/mpy_memory_map.md` | 0 |
| `pycore/docs/mpy_image.md` | 1 |
| `pycore/docs/mpy_bytecode.md` | 1 |
| `pycore/docs/mpy_gc.md` | 3 |
| `pycore/docs/mpy_exceptions.md` | 4 |
| `pycore/docs/mpy_peripherals.md` | 5 |
| `pycore/docs/mpy_interrupts.md` | 5 |

`mpy_image.md` records the const-kind reject list and the static-qstr
snapshot. `mpy_bytecode.md` records operand format and stack effect by
pointing at the JSON catalog. `mpy_peripherals.md` is the register model
the testbench and the RTL both implement.

## Changelog

Findings are identified in [`final_review_report.md`](final_review_report.md).
This table is where each one landed. Rejected findings are in the report
and are absent from the phase text above.

| Finding | Reviewers | Where it landed |
| --- | --- | --- |
| F01 Stock unix port is the wrong oracle | A, B, C | v1 locks, oracle variant |
| F02 `.mpy` container and bit-interleaved prelude | A, B, C | Target runtime, phase 1 |
| F03 Phase 2 exits need a builtin, a `while`, and an unfolded add | A, B, C | Phase 2 exit |
| F04 Draft left closures, methods, iterators, `with` unowned | A, B, C | Phases 3 and 4 |
| F05 Immediates, null word, frame slots as roots | A, B, C | Locks, memory map, phase 3 roots |
| F06 GC abort rule, pool versus SRAM, emergency `MemoryError` | A, B, C | Locks, phase 3 exit |
| F07 Register semantics, hard versus soft IRQ, native `machine` | A, B, C | Peripheral table, phase 5 |
| F08 Cannot freeze `py/compile.c`; compiler line count | A, C | Phase 6, audit |
| F10 Filesystem, threads, native code, finalisers, `id()` | A, C | Non-goals |
| F11 Missing doc pages | A, C | Doc contract |
| F12 "These four" registers; draft line counts | A | Audit, peripheral table |
| F13 Qstr operands stay indexes | A, B | Target runtime |
| F14 Dict and set hash order | B; A and C disagreed | Phase 3 |
| F15 `mpy-cross` folds constants and is built with MPZ and double | B, C | Target runtime, phase 2 |
| F16 Sub-version is not a bytecode compatibility check | A, C | Phase 1 |
| F17 `True + 1` is 2; immediate ids are not those integers | A, C | Phase 0 catalog, phase 4 |
| F18 Unicode `str` stays at the extra-features default | C | Target runtime |
| F19 Sim-control window is simulation-only | A | Memory map |
| F20 Fetch buffer is instruction bytes only | C | Memory map |
| F21 Opcode trace while debugging phase 2 | C | Phase 2 exit |
| F22 Recursion is `RuntimeError` | B, C | Phase 4 |
| F26 A returning `main` must still poll; blink is bounded | C | Phase 5 |
| F27 Unix `machine` is not the MMIO oracle | B, C | Phase 5 |
| Owner, 2026-10-14 | — | `.mpy` import, including `import *` and relative import, is phase 4. `*args` and `**kwargs` match `py/bc.c`. The standard library is not rewritten this month |
