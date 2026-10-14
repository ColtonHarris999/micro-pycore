# micro-pycore: the MicroPython pivot plan

Status: **plan.** The pycore import from Track 0 is done: this tree is pycore
`main` @ `43d791a`. Nothing else has started. Written 2026-10-13.

Inputs: [pycore](https://github.com/ColtonHarris999/pycore) `main` @ `43d791a`
(2026-10-13), MicroPython **v1.29.0** (`0fd6c573`, 2026-08-24), and the Cursor
draft plan, merged in [PR #1](https://github.com/ColtonHarris999/micro-pycore/pull/1) as
[`micropython_mcu_plan.md`](micropython_mcu_plan.md). Every number about pycore below
was measured on that commit. Every claim about MicroPython was checked
against that tag's source, not from memory. Section 10 lists the files.

Product framing: micro-pycore is a bytecode-native alternative to an ESP32,
RP2040/RP2350, or STM32 board running MicroPython. It runs MicroPython bytecode
directly, on microcontroller-sized memory, with microcontroller peripherals and
interrupts.

---

## 0. Read this first

### 0.1 Starting point: this tree is pycore `main` @ `43d791a`

This repository started as a one-line `README.md`. The commit "Import pycore
main @ 43d791a" copied pycore's tree from
[`43d791a`](https://github.com/ColtonHarris999/pycore/commit/43d791aab6db610ba1030392d140950b45fa6f4f)
as a snapshot; pycore's history stays in the pycore repository. Until a track
below changes them, every file outside `planning/micropython_pivot_plan.md` is
still the CPython 3.14 machine. Paths in this plan such as `pycore/rtl/…` and
`pycore/docs/…` are paths in this repository.

The Cursor draft was merged in [PR #1](https://github.com/ColtonHarris999/micro-pycore/pull/1) as
[`micropython_mcu_plan.md`](micropython_mcu_plan.md). It is a plan only, with no
code. It assumed a new core in a separate tree, which this import replaces. §9
compares the two.

### 0.2 The plan in one paragraph

**Retarget pycore; don't rewrite it.** Keep pycore's execution engine (the
integer ALU, FPU, container FSMs, call binder, GC, and exception matching),
which together are about 41k lines of tested RTL. Replace the CPython 3.14
front end with a decoder for MicroPython v1.29.0 bytecode. Replace the 16 MB
cache hierarchy with a microcontroller memory map: execute-in-place flash,
256 KB of SRAM, and MMIO. Delete what MicroPython doesn't have. Make
MicroPython's unix port the oracle. Then add what a microcontroller needs:
interrupts, `machine`, `time`, `gc`, and a UART REPL. Rewrite the on-device
compiler to emit MicroPython bytecode. That removes its largest subsystems.

### 0.3 Decisions to confirm (they change the schedule)

| # | Decision | Recommendation | Why | Main alternative |
| --- | --- | --- | --- | --- |
| D1 | Starting point | **Retarget the pycore hart in this repo** | Four weeks is not enough to rebuild dicts, strings, calls, exceptions, and GC in new RTL and verify them | New 32-bit core from scratch (the Cursor draft). It is the right long-term shape, but it can't reach classes, exceptions, and GC by the deadline |
| D2 | How a value is stored in memory | **Stage A:** keep pycore's 32-byte slot for bring-up. **Stage B (weeks 2–4):** an 8-byte packed slot | Each pycore slot is 16 B of value plus 16 B of tag. A list element costs 32 B and a dict entry 96 B; MicroPython's 32-bit ports use 4 B and 8 B. Until that changes, "realistic memory size" can't be claimed | Go straight to MicroPython's 4-byte object word (`MICROPY_OBJ_REPR_A`). That gives exact density parity but requires the most RTL changes. Do it after the deadline |
| D3 | Number model | **64-bit ints that raise `OverflowError`, binary32 float, `complex` kept** | This is MicroPython's `LONGLONG` int mode, which pycore's 64-bit ALU already implements. ESP32 and RP2 use binary32 float, and `time.sleep(0.5)` needs a float. Two perf_bench programs use `complex` | MPZ bigints, the ESP32/RP2 default. That is post-deadline; only `bm_pidigits` needs it |
| D4 | Oracle | **MicroPython v1.29.0 unix port, custom variant** (§3.2) | It's the closest stdout match to an RP2/ESP32 build that can run on a host in CI | Real boards, used for benchmarks but not for CI |
| D5 | On-device compiler | **Rewrite it in place to emit MicroPython bytecode. Ship it as a frozen `.mpy`** | A microcontroller product needs a REPL, and a REPL needs a compiler. MicroPython bytecode removes the compiler's largest subsystems (§2) | Leave it out of v1, as the Cursor draft does |
| D6 | Harts | **One.** Remove excore from the product build | Container growth already runs on the single-hart accelerator. Only `print` still goes through excore | — |
| D7 | Reporting clock | **Synthesized Fmax, plus equal-clock comparisons with each board** | The current 1 GHz assumption is not a microcontroller clock | — |

### 0.4 Questions for you

1. What is the deadline, and what does "publish" mean: a paper submission, a
   public release, or both? §7 assumes a hard date of about **2026-11-13**.
2. How many people (and agents) will work on this in parallel? §7 has eight
   tracks.
3. Can you buy about $40 of boards (Pico, Pico 2, ESP32, ESP32-C3)? §4 depends
   on measuring them.
4. Is the REPL (and therefore the on-device compiler) required by the deadline,
   or a stretch goal? It is the fourth item on the cut list in §7.

---

## 1. Language features

### 1.0 The foundation: MicroPython bytecode on the pycore engine

Every feature below depends on this swap, so it comes first.

MicroPython v1.29.0 defines `.mpy` version **6, sub-version 3**
(`py/persistentcode.h`). A bytecode-only file writes feature byte `0x00`:
`mp_raw_code_save` stores the sub-version only when `cm->has_native` is
set (`py/persistentcode.c`). `mpy-cross` with no `-march` therefore emits
`4d 06 00 1f` for 31-bit small ints. The loader checks sub-version only
when the architecture nibble is not none. The bytecode (`py/bc0.h`) has **72 single opcodes plus
5 multi-opcode ranges**: small-int constants, `LOAD_FAST`, `STORE_FAST`,
`UNARY_OP`, and `BINARY_OP`, each with a small operand folded into the opcode
byte. Instructions are variable-length byte strings. There is no `CACHE` and no
`EXTENDED_ARG`. Names are qstr indexes. A `.mpy` file is a container, not a raw
instruction stream: a four-byte header, one module qstr table, one const
table, then a tree of raw-code objects (`py/persistentcode.h`,
`py/persistentcode.c`). Nested functions, class bodies, and comprehensions
are child raw code. The host tool links a flash image; the RTL fetches
that image and does not parse `.mpy`. Qstr operands stay indexes into the
module table. Ids at or below `QSTR_LAST_STATIC` are stored as ids, and
the image embeds the pin's static list from `py/makeqstrdata.py`. The
prelude in `py/bc.h` is bit-interleaved (signature, then source-info size
and cell count, then source-info bytes and cells). The first opcode is
after those bytes. The decoder returns that offset and the line-info span.
The image tool rejects a non-none architecture. It accepts `*args`,
`**kwargs`, `import`, `from ... import *`, and relative import. Binding
of `*args` and `**kwargs` follows `mp_setup_code_state` in `py/bc.c`:
surplus positionals are a tuple, including the empty tuple when none are
passed, and surplus keywords are a dict when the function has that flag.
That call path is week 2.

| pycore today | What changes | RTL touched |
| --- | --- | --- |
| 40-bit instruction words in 8-byte slots; fetch folds `CACHE`/`EXTENDED_ARG` | Byte-stream fetch with variable-length operands (var-uint, qstr, jump offset). PC is a byte address that can point into flash or SRAM, because code compiled at run time lives in SRAM. An 8-byte fetch buffer absorbs flash wait states | Replace `pycore_fetch.sv` (197 lines), `pycore_imem.sv`, `pycore_code_mem.sv`, and `pycore_code_ram.sv` |
| `pycore_decode.sv` decodes 95 CPython opcodes | New `mpy_decode.sv` that maps each MicroPython opcode onto an existing execution-FSM entry state (table below) | Replace `pycore_decode.sv` (494 lines); edit dispatch in `pycore_core.sv` |
| Code-object metadata word, read by `CALL` and cached in CODC | Decode the MicroPython function prelude: `n_state`, `n_exc_stack`, `scope_flags`, `n_pos_args`, `n_kwonly_args`, `n_def_pos_args`, `n_info`, `n_cell`, the argument-name qstrs (used for keyword binding), and the line-number table (used for tracebacks). Cache the decoded prelude in CODC, keyed by code address | `pycore_call_fsm.svh` (5,267 lines), `pycore_codc.sv` |
| `co_names` strings; the global-name cache is keyed by `{code_addr, namei}` | qstrs. The loader maps each qstr id to an interned string object, so global and attribute lookups compare pointers first. **The static qstr table is part of the `.mpy` ABI** (`static_qstr_list` in `py/makeqstrdata.py`), so the flash image must embed it exactly. Rekey the global-name cache by `{code_addr, qstr}` | `pycore_gic.sv`, the loader |
| CPython 3.14 exception table, searched when an exception is raised | A per-frame exception stack sized by `n_exc_stack`. `SETUP_EXCEPT` and `SETUP_FINALLY` push `{handler_pc, sp}`; a raise pops to the nearest handler. No table search. `UNWIND_JUMP` (`break`, `continue`, or `return` through a `finally`) is the hardest opcode | `pycore_cont_raise.svh` (524), `pycore_cont_exc.svh` (293), `pycore_exc_stack.sv` (222) |
| Defaults stored on the code object, literals only (D10) | `MAKE_FUNCTION_DEFARGS` and `MAKE_CLOSURE_DEFARGS` evaluate defaults when the `def` runs and store them on the function object | `pycore_cont_closure.svh`, call binder |

How MicroPython opcodes map onto the existing engine:

| MicroPython opcode(s) | Existing pycore path |
| --- | --- |
| `LOAD_FAST_MULTI`, `LOAD_FAST_N`, `STORE_FAST_*`, `DELETE_FAST` | `LOAD_FAST` / `STORE_FAST` / `DELETE_FAST` |
| `LOAD_CONST_SMALL_INT(_MULTI)`, `LOAD_CONST_{NONE,TRUE,FALSE,STRING,OBJ}` | `LOAD_SMALL_INT` / `LOAD_CONST` |
| `BINARY_OP_MULTI`. MicroPython folds compares, `in`, `is`, and exception matching into binary-op indexes | `BINARY_OP`, `COMPARE_OP`, `CONTAINS_OP`, `IS_OP`, `CHECK_EXC_MATCH` |
| `UNARY_OP_MULTI` | `UNARY_*`, `TO_BOOL` |
| `LOAD_METHOD` + `CALL_METHOD(_VAR_KW)` | `LOAD_ATTR` (method form) + `CALL` / `CALL_KW` / `CALL_FUNCTION_EX` binder |
| `CALL_FUNCTION(_VAR_KW)`. Keyword arguments are `(qstr, value)` pairs on the stack; the operand is `n_pos \| n_kw << 8` | Same binder. The keyword names come from the stack instead of a tuple |
| `DUP_TOP`, `DUP_TOP_TWO`, `ROT_TWO`, `ROT_THREE`, `POP_TOP` | `COPY` / `SWAP` / `POP_TOP` |
| `GET_ITER`, `GET_ITER_STACK`, `FOR_ITER` | Hybrid `ITER` |
| `STORE_COMP` | `LIST_APPEND` / `SET_ADD` / `MAP_ADD` |
| `BUILD_{TUPLE,LIST,MAP,SET,SLICE}`, `STORE_MAP`, `UNPACK_*`, `LOAD_SUBSCR`, `STORE_SUBSCR` | Container FSMs. `BUILD_SLICE` + `LOAD_SUBSCR` replaces `BINARY_SLICE`, so list and tuple slicing work at run time |
| `JUMP`, `POP_JUMP_IF_*`, `JUMP_IF_*_OR_POP` | `pycore_branch.sv`, plus two keep-or-pop variants |
| `SETUP_*`, `POP_EXCEPT_JUMP`, `END_FINALLY`, `UNWIND_JUMP`, `RAISE_{LAST,OBJ,FROM}`, `WITH_CLEANUP` | New exception-stack unwinder (above) |
| `MAKE_FUNCTION(_DEFARGS)`, `MAKE_CLOSURE(_DEFARGS)`, `LOAD_DEREF`, `STORE_DEREF`, `DELETE_DEREF` | `OBK_FUNCTION` / `OBK_CELL`, with defaults added to the function object |
| `LOAD_BUILD_CLASS`, `LOAD_SUPER_METHOD` | New (§1.1) |
| `IMPORT_NAME`, `IMPORT_FROM`, `IMPORT_STAR` | New (§1.1) |
| `YIELD_VALUE`, `YIELD_FROM` | After the deadline (§1.1) |

**Exit:** a `while` that adds two locals (so `mpy-cross` cannot fold the
add), a `print` of that sum including a negative, a call with defaults, and
a `try`/`except ZeroDivisionError` all produce output identical to the
oracle. `print(1 + 2)` is recorded as a folded const and is not the ALU
test.

### 1.1 Add: MicroPython has it, pycore doesn't

| Feature | Why a microcontroller program needs it | Implementation plan | Wk | Exit test |
| --- | --- | --- | --- | --- |
| Hardware conditions become Python exceptions | Drivers wrap I/O in `try`. In pycore, fatal traps halt the machine | Convert fatal traps to raises through the existing T6 sidecar: `TYPE`→`TypeError`, `DIV_ZERO`→`ZeroDivisionError`, `OVERFLOW`→`OverflowError`, `CALL_FILTER`→`TypeError`, `ATTR_ERROR`→`AttributeError`, sequence `MEM_FAULT`→`IndexError`, dict-miss `MEM_FAULT`→`KeyError`, `VALUE`→`ValueError`, and frame overflow→`RuntimeError("maximum recursion depth exceeded")`. Copy the message text from the oracle | 1–2 | Each converted trap test, rewritten as `try`/`except` + `print`, matches the oracle |
| `MemoryError` | With 256 KB of RAM, running out of memory is normal | GC is always on. If an allocation fails, the opcode aborts before the first architectural commit, the core collects, and the opcode is re-dispatched (`pycore/docs/gc.md`). If it fails again, raise `MemoryError` from a preallocated emergency object. The oracle `-X heapsize` is the GC pool only. Slot size differs from the oracle's 4-byte object until the post-deadline `REPR_A` step, so the tests are a dropped reference that can be allocated again, and one allocation larger than the pool. They do not pin an append index | 2 | Those two programs raise the oracle's exception type and message |
| Missing exception types | `OSError`, `KeyboardInterrupt`, and `MemoryError` show up in nearly every board script | Seed the types the oracle's `dir(builtins)` lists. Today pycore seeds 16 of them and leaves `MemoryError`, `OverflowError`, `OSError`, `KeyboardInterrupt`, `SystemExit`, `GeneratorExit`, `ImportError`, `NotImplementedError`, `EOFError`, `StopAsyncIteration`, and `UnicodeError` absent. Add `.value` and `.errno` attributes to every exception, as MicroPython does | 2 | A generated test of `dir(builtins)` matches the oracle |
| Runtime `class`, inheritance, `super()` | Every driver is a class. pycore only folds module-level classes when it builds the image | Implement `LOAD_BUILD_CLASS` as a ROM `__build_class__`: run the class body with a fresh namespace dict and allocate an `OBK_TYPE`. Use MicroPython's depth-first MRO (not C3). Add `LOAD_SUPER_METHOD` | 3 | A class with a base, `super().__init__`, a property, and a classmethod matches the oracle |
| `import` of `.mpy` modules | One program loads another. `from machine import Pin` is the first line of nearly every script | Add an `OBK_MODULE` object (a globals dict), `sys.modules`, and a frozen-module table in flash (qstr → the `.mpy` `mpy-cross` produced). `import`, `from ... import`, `import ... as`, `import *` (`mp_import_all` in `py/runtime.c`), and a relative import inside a package all match the oracle. A missing name is `ImportError`. Do not rewrite the standard library this month: link its `.mpy` or leave it absent. Built-in modules (`machine`, `time`, `gc`, `micropython`, `sys`) are native. No filesystem yet; import does not open a path | 2–3 | Two frozen modules import each other; `from X import Y`, `import X as Z`, `from X import *`, and `from .other import name` match the oracle. A second import does not re-run the body. A missing module raises `ImportError` |
| `with` | Drivers use it for locks, files, and chip-select | `SETUP_WITH` / `WITH_CLEANUP`, plus `__enter__`/`__exit__` lookup | 3 | `__exit__` runs on a normal exit and on an exception |
| Defaults evaluated when `def` runs | Common in drivers (`def __init__(self, pin=Pin(2))`) | `MAKE_FUNCTION_DEFARGS` (§1.0). Removes pycore restriction D10 | 2 | A non-literal default matches the oracle |
| `*args` and `**kwargs` | Ordinary MicroPython functions use them | Same call setup as the pin (`py/bc.c`). Extra positionals are a tuple. Extra keywords are a dict. Too many positionals without `*args`, or a keyword the signature does not collect, is the oracle's `TypeError` | 2 | `f(1)`, `f(1, 2, 3)`, `f(1, *xs)`, and a `**kwargs` call match the oracle |
| f-strings and `str.format`, `%` formatting | Logging and display | MicroPython's lexer rewrites f-strings into `'...'.format(...)` (`py/lexer.c`), so only `str.format` and `%` are needed at run time. Implement them as ROM firmware | 2–3 | A format-spec corpus matches the oracle |
| `bytes`, `bytearray`, `memoryview`, `struct`, `array` | Every sensor driver uses them, and preallocated buffers are how interrupt handlers avoid allocating | Finish the `BYTES` tag (currently reserved/partial). Make `bytearray` mutable and in place. Add `memoryview` slices without copying. `struct.pack`/`unpack` and `array` as ROM firmware | 3–4 | A driver-style test (pack a register write, unpack a reading) matches the oracle |
| `micropython` module | `const()`, `schedule`, and `alloc_emergency_exception_buf` are standard in interrupt-heavy code | `const()` is compiler-only (§2). `schedule`, `heap_lock`/`heap_unlock`, `alloc_emergency_exception_buf`, `mem_info`, and `kbd_intr` connect to §5 | 3–4 | §5 exit tests |
| `machine` module | This is the product surface | `Pin`, `Timer`, `UART`, `mem8`/`mem16`/`mem32`, `freq`, `reset`, `idle`, `disable_irq`/`enable_irq`, `unique_id`. Later: `PWM`, `ADC`, `I2C`, `SPI`, `WDT` | 3–4 | blink, echo, and debounce (§5) |
| `time` with MicroPython's tick API | Every timing loop uses it | `ticks_ms`/`us`/`cpu`, `ticks_diff`, `ticks_add` (wrapping at MicroPython's tick period), `sleep`, `sleep_ms`, `sleep_us`. The sleeps use the timer and `WFI` instead of busy-waiting | 3 | A `ticks_diff` test across the wrap point |
| `gc` module | `gc.collect()` and `gc.mem_free()` are in most examples | `collect`, `enable`, `disable`, `isenabled`, `mem_free`, `mem_alloc`, `threshold` (§5.5) | 2–3 | `gc.mem_free()` moves the expected way |
| `sys` | `sys.print_exception` is MicroPython-specific, and `sys.implementation._mpy` advertises `.mpy` compatibility | `platform`, `implementation`, `byteorder`, `maxsize`, `exit`, `modules`, `print_exception`, `stdout.write` | 3 | `sys.implementation` matches what we decide to advertise |
| Walrus `:=` | MicroPython accepts it (`MICROPY_PY_ASSIGN_EXPR`); pycore rejects it | Compiler only | 3 | Matches the oracle, including MicroPython's looser comprehension rule |
| `KeyboardInterrupt` from Ctrl-C | Needed to stop a runaway loop at the REPL | A pending exception, checked at the same points as scheduled callbacks (§5.3) | 4 | Ctrl-C stops `while True: pass` |
| REPL, paste mode, raw REPL | This is how people use a MicroPython board, and the raw REPL is what `mpremote` and Thonny speak | §6.3 | 4 | `mpremote run x.py` works against the simulator |
| Generators, `async`/`await`, `asyncio` | `asyncio` is MicroPython's concurrency model | **After the deadline.** MicroPython keeps a generator's frame state in a heap object, which is simpler to make resumable than a CPython frame. Needs `YIELD_VALUE`, `YIELD_FROM`, and generator `throw`/`close`/`pend_throw` | stretch | `bm_nqueens` and `core_yield_from` run |
| `@micropython.native` / `viper` / `asm_*` | Used in speed-critical code | **Not supported:** there is no native emitter. Reject them the way `mpy-cross` does without `-march`. Don't silently ignore `viper`, because viper integers wrap at 32 bits | — | The compile error matches `mpy-cross` |

### 1.2 Remove: pycore has it, MicroPython doesn't (or a microcontroller doesn't need it)

| Item | Where it lives in pycore | Action | Saves |
| --- | --- | --- | --- |
| The CPython 3.14 ISA: `CACHE`/`EXTENDED_ARG` folding, superinstructions, exception tables, the `LOAD_GLOBAL` NULL bit, `COMPARE_OP` packing, `CALL_INTRINSIC_*` | `pycore/targets/pycore.json` (95 opcodes), `pycore_decode.sv`, `pycore_fetch.sv`, `pycore_defs.svh` (3,833 lines, opcode-specific) | Delete along with the decoder swap. New catalog: `targets/mpycore.json` | Decoder area, and the fetch line-folding logic |
| Insertion-order dict sidecar | `order_ptr` in the dict object, 32 B per key (`dict_excore.md`) | Delete. MicroPython dicts aren't ordered (§1.3, row 1) | 32 B per key and one write per insert |
| excore (the second hart: RV32, mailbox, firmware) | `excore/`, `pycore_excore_system.sv` (468 lines), the 33-test `excore` area | Remove from the product build; it stays in pycore. Move `print` to the single hart: ROM `print` formats the text, then stores the bytes to `UART_TX` | A whole second core |
| L1I/L1D/L2 caches and the 16 MB RAM model | `pycore_cache.sv` (1,363), `pycore_cache_lru.sv`, `pycore_mem_hier.sv` (523), `pycore_mem_xbar.sv`, `+MEM_LATENCY` | Replace with execute-in-place flash (wait-state parameter), 1-cycle SRAM, and MMIO | All cache area |
| binary64 float | `pycore_fpu.sv` and friends | Keep the datapath for now and round every result to binary32. Double rounding is harmless for `+ − × ÷ √` because 53 ≥ 2·24 + 2. Shrink the datapath to binary32 after the deadline | Area, after the shrink |
| Unicode case and character classification above U+00FF | STRACC tables (`string_accel.md` §Unicode) | Remove. MicroPython's `str.upper`, `str.lower`, and `isalpha` and friends only handle ASCII. **Confirm on the oracle first** | Table area |
| `exec`/`eval` of CPython code objects, `SEED_CODE`, `bios()`, `_bi_heap_mark`, `_bi_code_mark` | firmware builtins and tools | Delete. GC is always on. `exec(str)` and `eval(str)` go through the new compiler, and compiled code lives in GC-managed buffers | Workarounds that only existed because GC was off |
| Image build from host CPython | `image_from_source.py`, `preprocess.py`, `heap_image.py`, `exception_table.py`, `analyze_bytecode.py`, `measure_pycpython_opcodes.py`, `vendor/pycpython` | Replace with `mpy-cross` plus a flash-image tool. Reuse the `.mpy` reader in MicroPython's `tools/mpy-tool.py` and `tools/manifestfile.py` (MIT licence) | Most of the 18.7k lines in `pycore/tools` |
| CPython cycle-ratio research tooling | `cpython_baseline/`, `research_compare.py`, `research_machines.*` | Replace with §4 | — |
| Builtins MicroPython lacks | 86 ROM builtin modules (2,044 lines) | Diff them against the oracle's `dir(builtins)` and its method lists with a script. Delete anything extra unless it's on an allowlist. Known extras include `int.bit_length` and `str.ljust`/`rjust` (both in MicroPython's "differences from CPython" list), and `aiter`/`anext` | ROM space, and one fewer source of mismatches |
| CPython features never to build | — | `__del__` finalizers, exception chaining (`__cause__`/`__context__`), name mangling, C3 MRO, `__init_subclass__`, `locals()` contents, `match`, `except*` | Keeps scope fixed |

### 1.3 Shared behavior, different edge cases

When these differ, the oracle wins. Every row needs a test whose expected output
comes from the oracle.

| # | Behavior | CPython / pycore today | MicroPython v1.29.0 | Plan |
| --- | --- | --- | --- | --- |
| 1 | **Dict and set iteration order** | Insertion order (pycore keeps a sidecar) | **Hash-table order.** Open addressing with linear probing (`py/map.c`). String hash is djb2 (`h*33 ^ c`) masked to 16 bits (`QSTR_BYTES_IN_HASH=2` at `EXTRA_FEATURES`). A small int hashes to itself. Table sizes grow 0, 2, 4, 6, 8, 10, 12, 17, 23, 29, 37, 47, 59, 73, 97, 127, … So `{3: 'a', 1: 'b'}` prints as `{1: 'b', 3: 'a'}` | Copy `mp_map` and `mp_set` exactly in `pycore_cont_dict.svh`: the hash, the size table, the probe sequence, rehash order, and deleted-slot handling. Build and test a host Python model against the oracle first. **This is the riskiest parity item: one wrong detail changes hundreds of expected outputs** |
| 2 | `list.sort` / `sorted` | Timsort, stable | **Quicksort, not stable** (`py/objlist.c`, which has a TODO about stability) | Port `mp_quicksort` exactly, including its pivot choice, so ties come out in the same order. Replace the ROM `sorted` |
| 3 | Integers | Arbitrary precision; pycore uses 64 bits and *halts* on overflow | `LONGLONG`: 64-bit, raises `OverflowError("result overflows long long storage")` | Keep the ALU. Turn trap 21 into a catchable exception. **Fix the open bug where `print(2**32)` prints `0`** (`compile_limitations.md` §3.2) |
| 4 | Float precision | binary64 | binary32 (`FLOAT_IMPL_FLOAT`), on ESP32, RP2, and STM32 | Round every result (§1.2) |
| 5 | Float to string | Shortest round-trip; pycore can't format floats at all (L-CONV-1) | `MICROPY_FLOAT_FORMAT_IMPL_APPROX` for binary32 (`py/formatfloat.c`), so fewer digits and different rounding | Port `formatfloat.c` to ROM firmware. Test it on the host: run the firmware algorithm under Python on about 100k random binary32 bit patterns and compare with the oracle. This also closes L-CONV-1 |
| 6 | String to float | Correctly rounded | MicroPython's own parser (`py/parsenum.c`) | Port it, and fuzz it the same way |
| 7 | `math` functions | glibc | MicroPython's binary32 `lib/libm` | Port the needed `lib/libm` routines to firmware. Until then, compare at printed precision |
| 8 | Error messages | CPython wording | MicroPython wording at `ERROR_REPORTING_NORMAL`, which ESP32 sets explicitly (e.g. `unsupported types for __add__: 'int', 'str'`) | Copy the strings from the oracle. Tests print `type(e).__name__` and `str(e)` |
| 9 | Uncaught-exception output | Traceback with source lines | `Traceback (most recent call last):` / `File "x.py", line N, in f` / `TypeError: …`, with no source text | Use the prelude's line-number table and a ROM traceback printer |
| 10 | Recursion limit | `RecursionError`; pycore `MEM_FAULT` | `RuntimeError: maximum recursion depth exceeded`; the depth depends on the port | Raise it at the frame-stack limit. Tests check the message, not the depth |
| 11 | Slicing with a step | Supported; pycore rejects it at compile time | `str`, `bytes`, and `tuple` with step ≠ 1 are not implemented, and neither is list store or delete with a step (MicroPython "differences from CPython" list) | Match the oracle: raise the same exception at run time. List and tuple slicing *without* a step now works on the hart (§1.0) |
| 12 | `str` methods and `str.format` fields | Full set | A subset: no `ljust`/`rjust`, no `rsplit(None, n)`, no keyword arguments to `str()`, only `utf-8`/`ascii` encodings, no attribute or subscript fields in `format` | Generate the method list from the oracle and match it |
| 13 | `dict.keys()` | A set-like view | Not set-like | Match |
| 14 | `super()` with multiple inheritance | Cooperative | Calls only one parent | Match |
| 15 | `is` on ints and strings | Implementation-defined | Small ints and qstrs are immediates, so `is` is true more often | Falls out of the design. Tests must not depend on it |
| 16 | `hash()` | Randomized for `str`; pycore doesn't expose it (L-RT-1) | Deterministic djb2 | Expose it, since row 1 needs it anyway |
| 17 | Object addresses in `repr` | — | `<Foo object at 0x…>` | The test harness masks addresses |
| 18 | A generator left unfinished | `__exit__` runs at finalization | `__exit__` never runs | Matters once generators exist |
| 19 | Numeric literal followed by a keyword (`1if x else 2`) | Allowed | A syntax error; MicroPython needs a space | Compiler only |
| 20 | `range` arguments | Unbounded | Must fit in a machine word | Match |

---

## 2. Compiler

### 2.1 What exists

Do not freeze the pin's `py/compile.c`. It is C, and this hart does not run
the C VM. The compiler to retarget is the one already here.

`pycore_firmware/compiler/` is **7,000 lines** written in the pycore subset:
`lexer.py` (667), `parser.py` (2,528), `symtab.py` (641), `codegen.py` (2,440),
`tables.py` (680), `compat.py` (34), and `toy.py` (10). The Cursor draft says
14,000 lines; that number is wrong for `43d791a`. The compiler runs from code
RAM at reset. The resident package is **61,929 slots of 8 B each, about
495 KB**, which is larger than the whole flash budget below. Compiling keeps
**10–16 KB of heap per source line**, so 256 KB of SRAM would compile about 20
lines. It emits CPython 3.14 code objects through
`_bi_code_alloc`/`_bi_code_blit`/`_bi_code_new`.

### 2.2 What switching to MicroPython bytecode removes

| Removed | Why it existed | MicroPython equivalent |
| --- | --- | --- |
| Exception-table assembly: the varint table, `_stk_base` depth accounting, inlined `finally` bodies with holes in the table, the handler-exit `POP_EXCEPT` bookkeeping in `_pyc_fin_emit_from` | CPython 3.14's zero-cost exceptions | `SETUP_EXCEPT`/`SETUP_FINALLY` + `END_FINALLY` + `UNWIND_JUMP`. Each `finally` body is emitted once, not copied to every exit |
| The peephole pass (superinstructions, `is None` jump fusion) | CPython's optimizer | None. MicroPython's multi-opcodes are a choice the emitter makes for slots below 16 |
| `CACHE` adjustments to jump targets, `EXTENDED_ARG`, the `LOAD_GLOBAL` NULL bit (D3), `COMPARE_OP` packing (D4), `PUSH_NULL` and self-or-NULL conventions, the `CALL_KW` names tuple | CPython 3.14 encodings | var-uint operands; `CALL_FUNCTION n_pos \| n_kw<<8` with `(qstr, value)` pairs on the stack; `LOAD_METHOD` |
| f-string code generation (`FORMAT_SIMPLE`, `BUILD_STRING`, `CONVERT_VALUE`) and its 15-byte limit | CPython f-string opcodes | The lexer rewrites the f-string into a `.format(...)` call, as `py/lexer.c` does |
| Building `co_consts`, `co_names`, and `co_varnames` by joining 1-tuples | The hart couldn't run `tuple(list)` | Const table plus qstrs |
| Display slices and negative indexes via `_bi_code_kind` | The hart couldn't slice a list | `BUILD_SLICE` + `LOAD_SUBSCR` |
| The literal-only default rule (D10) | No def-time evaluation | `MAKE_FUNCTION_DEFARGS` |
| `tables.py` (680 lines generated from CPython's `token` module) | The lexer test compares against CPython `tokenize` | A smaller keyword and operator table |

Estimate, not measured: `codegen.py` shrinks from about 2,440 to 1,300 lines.
`parser.py` and `symtab.py` mostly stay, because the grammar and the cell/free
rules are the same. The total goes from about 7,000 to 4,500 lines. Emitted code
shrinks by much more: MicroPython bytecode averages 1–2 bytes per operation,
against an 8-byte slot today.

### 2.3 What is new

| Item | Plan |
| --- | --- |
| Bytecode emitter | MicroPython encodings, multi-opcodes, and variable-length jump offsets. `mpy-cross` measures code size and label offsets in `MP_PASS_CODE_SIZE`, and reruns `MP_PASS_EMIT` if a jump offset needs more bytes (`py/emit.h`, `py/emitbc.c`). Do the same, so the output can be byte-identical to `mpy-cross`. Fallback: always use the widest jump encoding, which gives up byte-identity |
| Prelude encoder | Signature, size info, argument-name qstrs, scope flags, and the line-number table |
| `const()` | Fold `X = const(…)` at compile time. Names starting with `_` that are bound to `const` are never stored, which matches MicroPython |
| Constant folding | Follow MicroPython's parser rules, which are not CPython's D2 rules |
| Grammar now allowed | `class`, `import`, `with`, `:=`, `nonlocal`, non-literal defaults, `raise … from …` (the cause is ignored, as in MicroPython), and annotations (ignored). Generators are accepted only once the hart can run them |
| Acceptance rule (replaces A4/D5) | **The compiler accepts what `mpy-cross` v1.29.0 accepts, within the supported scope, and otherwise raises the same `SyntaxError` text** |
| Packed fields fit in 31 bits | AST and token fields today pack up to 62 bits (`nd_b = nargs \| ndec<<16 \| params<<32`). On this machine anything above 2³⁰ is a heap-allocated long int, so every store would allocate. Split them into fields of 30 bits or less. Retarget `test_packed_node_fields_fit_a_wrapping_int64` to 31 bits |
| Memory budget | **Target: a 200-line module compiles with at most 64 KB of peak heap.** (a) Store the structure-of-arrays tables in `array('i')` or `bytearray`, not lists of value slots; (b) drop the token arrays after parsing; (c) compile and emit one function at a time into the final buffer; (d) intern identifiers as qstrs |
| Output location | Frozen code runs from flash. Compiled code goes into a GC-managed SRAM buffer, which the byte-addressed fetch can execute (§1.0) |
| The compiler ships as frozen `.mpy` | `mpy-cross` compiles the compiler's own Python source. The host-CPython build of the compiler goes away |
| Self-hosting check | The on-device compiler compiles its own source, and the output is **byte-identical to `mpy-cross`** output for the same files. This is simpler and stronger than pycore's planned stage-2 fixpoint |

### 2.4 How the compiler is tested

1. **Host, no Verilator.** Run the compiler under host Python and wrap its
   output in a valid `.mpy` header. Then: (a) diff the bytes against
   `mpy-cross` and track the share of functions that are byte-identical; (b)
   **run the emitted `.mpy` on the oracle** (`micropython -c "import t"`) and
   compare its output with running the source. The MicroPython VM checks our
   bytecode before any RTL exists.
2. **Device.** `compile_suite` becomes "compile on the simulator, run on the
   simulator, compare with the oracle running the same source".
3. **Self-host.** The test from §2.3.

### 2.5 Milestones

| Milestone | Scope | Week |
| --- | --- | --- |
| C1 | Expressions, assignment, `if`/`while`/`for`, calls. Output is a `.mpy` the oracle accepts | 1 |
| C2 | `def`, closures, defaults, `try`/`except`/`finally`, comprehensions | 2 |
| C3 | `class`, `import`, `with`, `const`, `:=`, f-string rewriting; the 31-bit field repacking | 3 |
| C4 | The 64 KB budget; running on the device; connected to the REPL | 4 |

If time runs out, the REPL ships with C2 scope.

---

## 3. Testing infrastructure

### 3.1 What exists (measured at `43d791a`)

- **597 hardware tests** in `pycore/programs/hw_tests.toml`, across 14 areas
  (36 of them are `gc-long` soak tests). The largest areas are `compiler` (84),
  `containers` (81), `gc` (64), `builtins` (53), and `calls` (51).
- Kinds: `run` (host CPython runs `managed_entry()` and the hart must return the
  same int or bool), `trap` (the hart must halt with a given trap code; 75 tests,
  mostly `TYPE`=1 ×27, `MEM_FAULT`=7 ×23, and `CALL_FILTER`=6 ×13), `stdout`
  (10 `.stdout` files), and `container`, `excore`, `coderam`, and `make`.
- Files in `pycore/programs/`: **523** `.py` files (512 at the top level,
  9 in `compile_suite/`, 2 in `type_pairs/`), plus **105 `.hex` and 20
  `.meta` fixtures generated from CPython bytecode** by `gen_*_fixtures.py`.
- 43 host test files. A device-compile suite (9 programs, compared with
  CPython). CI jobs: host-tools, rtl-modules, the per-area hardware matrix,
  compiler-vs-cpython, and caching. Separately, a nightly GC soak run and fuzzer.

### 3.2 The new oracle

- `vendor/micropython` is a submodule pinned to **v1.29.0**.
- The oracle is a custom unix-port variant, `variants/mpycore`, kept in this
  repo:
  - `MICROPY_LONGINT_IMPL_LONGLONG` and `MICROPY_FLOAT_IMPL_FLOAT` (D3)
  - `MICROPY_OBJ_REPR_A`. The upstream `longlong` variant uses `REPR_C`, which
    stores floats in 30 bits and drops 2 mantissa bits. ESP32 and RP2 use
    `REPR_A`, which keeps all 24.
  - `MICROPY_CONFIG_ROM_LEVEL_EXTRA_FEATURES`, the level ESP32, RP2, and STM32
    use
  - `MICROPY_ERROR_REPORTING_NORMAL` (ESP32's setting)
  - Built for 32-bit x86 with `CROSS_COMPILE=i686-linux-gnu-`. This is
    MicroPython's own CI recipe for the `longlong` variant. It gives 31-bit small
    ints and 32-bit object sizes, which `MemoryError` parity needs.
  - Run with `-X heapsize=<target heap>`.
- `MICROPY_SCHEDULER_DEPTH` is 8. The pin's default is 4; ESP32, RP2, and
  STM32 set 8. The "ninth schedule" test matches only when the variant
  sets it.
- `MICROPY_ENABLE_FINALISER` is 0. Extra features and the unix port turn
  finalisers on; a `__del__` that prints would desynchronize stdout.
- `MICROPY_ENABLE_EMERGENCY_EXCEPTION_BUF` is on, and `MICROPY_STACK_CHECK`
  is on, so the recursion test has a unix counterpart
  (`mp_raise_recursion_depth` in `py/runtime.c` is inside that check).
- `MICROPY_PY_BUILTINS_STR_UNICODE` stays at the extra-features default,
  which is on.
- The harness compares stdout and stderr separately, unbuffered, and masks
  addresses in `repr`. Tracebacks are stderr on the unix port.
- `mpy-cross` comes from the same tag, run with `-msmall-int-bits=31`, no
  `-march`, and an explicit `-O0` until a revision says otherwise. That
  binary is built with MPZ, double, and constant folding
  (`mpy-cross/mpconfigport.h`, `py/parse.c`). Overflow, division, and ALU
  tests use runtime values, not folded literals.
- Both are built once in the Docker image and cached in CI.

### 3.3 The new test contract

- **Every test is a stdout test.** A program prints its results. Its expected
  output is `<name>.exp`, generated by the oracle (MicroPython's own
  convention). `make regen-goldens` writes the files, and nobody edits them by
  hand. A CI job named `goldens-fresh` reruns the oracle and fails if the output
  differs.
- **Kinds after the change:**
  - `run`: becomes `stdout`.
  - `trap`: becomes a `try`/`except` that prints the exception, since the hart
    now has to raise the same exception.
  - `halt` (new, small): for conditions that are truly fatal (illegal opcode,
    wrong `.mpy` version, a fault inside an interrupt handler), checked through
    a halt-reason register in the simulator-control window.
  - `periph` (new): stdout plus a peripheral trace (GPIO edges, UART TX timing),
    compared with a host Python model of the registers.
  - `irq` (new): a testbench script injects stimulus, such as RX bytes at cycle
    N or a pin edge at cycle M.
- **Migrating the 523 programs** under `pycore/programs/` uses a script, not hand edits. It rewrites the
  `managed_entry()` wrapper as `print(managed_entry())`, runs each program on
  the oracle, and sorts it into one of four buckets, reporting the count in
  each:
  - (a) runs unchanged: keep, with new expected output
  - (b) the oracle raises because MicroPython lacks the feature: delete or
    rewrite
  - (c) output differs only in dict order or float formatting: keep; this is
    the point of the switch
  - (d) trap tests: convert to `except`
- **Hex fixtures:** generate them from Python sources with `mpy-cross` and the
  flash-image tool. The excore-integration fixtures are deleted along with
  excore.

### 3.4 Tests to add

1. **MicroPython conformance suite.** Run MicroPython's own `tests/basics`,
   `tests/float`, and `tests/micropython` on the simulator, skipping features
   the way `tests/feature_check/` does, and compare with the oracle. Publish the
   pass rate as a dashboard. This costs little and gives a strong number for a
   paper.
2. **Dict and set order:** keys of ints and strings, deletion, and growth
   across every size step.
3. **Float formatting and parsing fuzz** on the host (§1.3, rows 5–6).
4. **`MemoryError` parity** at equal heap size, and the smallest heap at which
   each test still passes (also a benchmark metric, §4.4).
5. **GC always on, at the target heap, for every test.** Every test becomes a
   GC test, and its collection count is recorded.
6. **Interrupts** (§5.7).
7. **`.mpy` loader negative tests:** a wrong version gives
   `ValueError: incompatible .mpy file`, as MicroPython does.
8. **Flash wait-state invariance:** stdout is the same at 0, 1, and 3 wait
   states. This replaces the cache gate.

### 3.5 Tests to scale back or delete

- CPython exception-table tests: `test_exception_table.py` and the D13 /
  `JUMP_BACKWARD_NO_INTERRUPT` cases.
- `CACHE`/`EXTENDED_ARG` fetch tests and the peephole tests (`cs_peephole.py`).
- Insertion-order dict tests, and Unicode case tests above ASCII.
- `test_compiler_tables_fresh` (CPython token tables), `test_pycpython_oracle`,
  `test_measure_pycpython_opcodes`, `test_cpython_baseline`, and
  `test_research_*`.
- The excore assembler and CPU tests, and the `excore` area (33 tests).
- The caching gate (`test-caching`), replaced by item 8 in §3.4.
- Tests of `_bi_heap_mark`/`_bi_code_mark`, `SEED_CODE`, the 15-byte f-string
  limit, and the `managed_entry` integer-return path.
- Float and complex tests are **kept**, with new expected output at binary32.

### 3.6 CI

Keep the existing split, including "a docs-only PR skips the hardware jobs".
Add `oracle-build` (cached), `goldens-fresh` (gating), and `mp-conformance` and
`bench` (nightly, not gating).

---

## 4. Benchmarking

### 4.1 What to drop

pycore's research comparison runs the hart at **1 GHz** against CPython 3.14 on
simulated machines (a 100 MHz Romer machine, gem5 at 1 GHz, and Skylake at
3.4 GHz). Drop the CPython cycle ratio as a headline number, and never assume a
1 GHz clock. The ten-program research set (nbody, fannkuch, and the others)
stays only as a secondary throughput and correctness set, run against the
MicroPython oracle.

### 4.2 The suite: MicroPython's `tests/perf_bench` (v1.29.0)

This is the suite MicroPython's developers use to compare ports and releases.
Each test is parameterized by **N ≈ CPU MHz and M ≈ heap KB**, and
`run-perfbench.py N M` picks the matching parameter set. Use one fixed
parameter set on every device, so all devices run the same workload. The
primary point is **(N, M) = (100, 100)**; add (50, 25) as a small-device point.

| Program | Needs | Earliest milestone |
| --- | --- | --- |
| `bm_fannkuch` | ints, lists | Week 2 |
| `bm_wordcount`, `core_str`, `core_qstr` | strings, dicts | Weeks 2–3 |
| `misc_pystone`, `misc_aes`, `core_locals` | classes | Week 3. **Pystone is the number board comparisons quote** |
| `bm_float`, `misc_raytrace`, `bm_chaos` | float, classes, `math` (`bm_chaos` also `random`) | Weeks 3–4 |
| `misc_mandel`, `bm_fft` | `complex` | Weeks 3–4 (D3 keeps `complex`) |
| `bm_hexiom` | classes, `io` | After the deadline |
| `bm_nqueens`, `core_yield_from` | generators | Stretch |
| `core_import_mpy_*` | importing `.mpy` from storage | After the deadline |
| `bm_pidigits` | arbitrary-precision ints | Not run under `LONGLONG` (it would raise `OverflowError`) |
| `viper_*` | native code emitter | Not applicable, by design |

### 4.3 Reference devices

Buy and flash official v1.29.0 firmware on each. On each board, record
`machine.freq()` and `gc.mem_free()` after boot, and use those as the board's
clock and M. Run with `run-perfbench.py -p -d <port> 100 100`.

| Board | Core | SRAM | Notes |
| --- | --- | --- | --- |
| Raspberry Pi Pico | RP2040, Cortex-M0+ | 264 KB | The main comparison point |
| Raspberry Pi Pico 2 | RP2350, Cortex-M33 (also RISC-V Hazard3) | 520 KB | Run both architectures |
| ESP32 DevKit | Xtensa LX6 | 520 KB | Clock can be set to 80, 160, or 240 MHz |
| ESP32-C3 | RISC-V | 400 KB | A RISC-V comparison point |
| pyboard v1.1 (optional) | STM32F405, Cortex-M4F | 192 KB | The reference board for MicroPython |

Where a board can change its clock, also run it at one shared clock. **Without
hardware,** published numbers are a sanity check only, not headline results:
ArduSimple's table and scruss's January 2025 measurements used different
firmware versions and harnesses.

**Start this in week 1.** Measuring boards doesn't depend on our core.

### 4.4 What we report

1. **Cycles per benchmark** on the simulator: SRAM at 1 cycle, flash wait states
   matched to the clock, heap = M, GC on, Stage-B slots (D2).
2. **Time at a realistic clock:** 48, 100, and 150 MHz, plus the synthesized
   Fmax (item 7).
3. **Performance per MHz:** a fixed workload divided by cycles, set against each
   board's `f × t`. This is the fairest comparison between a bytecode-native
   core and a C interpreter on a general-purpose CPU.
4. **Memory headroom:** the smallest heap at which each benchmark runs. Find it
   by binary search over `+HEAP` on our simulator and `-X heapsize` on the
   32-bit oracle. This answers "realistic memory size" directly.
5. **GC pause:** cycles for `gc.collect()` at heap M, against the board's time.
6. **Interrupt latency:** cycles from a pin edge to the handler's first
   bytecode, plus jitter. On boards, measure with a second GPIO and a logic
   analyzer, or with `time.ticks_cpu()`.
7. **Area and Fmax:** Yosys plus OpenSTA on an open PDK (sky130 or gf180), or an
   FPGA Fmax (Artix-7 or ECP5). Record before and after each removal in §1.2.
   The documented baseline is about 86.5k cells and 4.8k flops.
8. **Code size:** flash bytes for the frozen firmware, against MicroPython's
   firmware image size.

### 4.5 Tooling

A `bench/` runner that does the following:

- (a) Wraps each `perf_bench` test the way `run-perfbench.py` does, compiles it
  with `mpy-cross`, and builds an image.
- (b) Runs the simulator and reads the cycle counter from the
  simulator-control window.
- (c) Runs the boards through `mpremote`.
- (d) Writes `docs/benchmarks.md`, a JSON file, and an SVG chart, reusing the
  report and chart code from `research_compare.py`.

Each benchmark is about 100M simulated cycles, so the job runs nightly and
doesn't gate merges.

---

## 5. Interrupts (and GC driven by interrupts)

### 5.1 What to mimic

- **Hard IRQ.** On real boards, the handler runs right away in interrupt
  context, with the scheduler and the heap locked, so any allocation raises
  `MemoryError`. An uncaught exception prints
  `Uncaught exception in IRQ callback handler` and then the traceback
  (`shared/runtime/mpirq.c`).
- **Soft IRQ and `micropython.schedule`.** Callbacks wait in a queue of depth
  **8** (`MICROPY_SCHEDULER_DEPTH` on ESP32, RP2, and STM32). The VM runs them
  **only at jump opcodes**: `JUMP`, `POP_JUMP_IF_*`, `JUMP_IF_*_OR_POP`,
  `UNWIND_JUMP`, and `POP_EXCEPT_JUMP` (`py/vm.c`, `pending_exception_check`).
  They run one at a time, with the heap unlocked.
- **Pending exceptions** (Ctrl-C → `KeyboardInterrupt`) are raised at the same
  points.

### 5.2 Hardware

The IRQ controller lives in the MMIO window and extends the Cursor draft's
register map. Keep its offsets for `UART_TX`, `UART_RX`, `GPIO_OUT`,
`TIMER_COUNT`, `IRQ_STATUS`, and `IRQ_ENABLE`.

| Register | Meaning |
| --- | --- |
| `IRQ_STATUS` | Pending sources; write 1 to clear |
| `IRQ_ENABLE` | Per-source enable mask |
| `IRQ_HARD` | Per source: 1 = hard delivery, 0 = soft (queued) |
| `IRQ_GIE` | Global enable. `machine.disable_irq()` returns the old value, and `enable_irq(state)` restores it |
| `IRQ_ACTIVE` | Read-only: a hard handler is running |
| `IRQ_TABLE` | Base address of the handler table in SRAM |
| `SCHED_*` | Head and tail of the schedule ring |

Sources in v1: `TIMER0` (compare match), `UART_RX` (byte available),
`GPIO` (per pin: rising, falling, or both), `SOFT`, `GC_REQ`
(internal, §5.5), and `SIM` (testbench stimulus).

These semantics are product choices. The tag has no register at these
offsets. `pycore/docs/mpy_peripherals.md` is where a change lands before
RTL. The merged phase contract records the same rules.

- `UART_RX` is one byte. A read pops it. Bit 31 is data-valid. A second
  byte while that bit is set is dropped, and bit 30 sticks as overrun.
- `TIMER_COUNT` is 32 bits. A write sets the compare period. Zero disables
  the timer. On match the counter returns to zero and the timer IRQ bit
  sets. The phase 5 testbench advances the counter. A cycle-stepped mode
  is a later plusarg, so a blink trace does not move when ALU latency
  changes.
- `GPIO_OUT` is readable. `GPIO_IN` and a per-pin edge register sit at the
  next free offsets (`0x30`, `0x34`). The original six offsets do not move.
  Added IRQ registers (`IRQ_HARD`, `IRQ_GIE`, `IRQ_ACTIVE`, `IRQ_TABLE`,
  `SCHED_HEAD`, `SCHED_TAIL`) start at `0x18`.
- Accepting a callback for a source clears that source's `IRQ_STATUS` bit.
  Write-1-to-clear still works. An edge during the callback sets the bit
  again.
- A store to flash, or an access outside flash, SRAM, and the two MMIO
  windows, halts with a bus-fault reason. An unaligned access halts.

**The handler table** holds one handler object and one argument object per
source (for example, the `Pin` or `Timer` instance).
`Pin.irq(handler, trigger, hard=…)`, `Timer(callback=…)`, and `UART.irq` write
it. **The table is a GC root.**

### 5.3 Delivery

1. **Hard.** A hard IRQ is taken at the **next bytecode boundary**, which is
   the earliest safe point on a core that runs bytecode directly. On entry, the
   hardware saves the PC, the frame pointer, the stack watermark, and the
   exception-stack pointer, then calls `handler(arg)` through the normal call
   FSM. It sets `IRQ_ACTIVE`, `heap_locked`, and `sched_locked`. A
   `RETURN_VALUE` from that frame restores the saved state. If an exception
   escapes the handler, print MicroPython's message and traceback, then disable
   that source; check this behavior against the RP2 port. No nesting in v1;
   two priority levels later.
2. **Soft.** The hardware adds `(handler, arg)` to the schedule ring.
   `micropython.schedule()` writes to the same ring; when the ring is full, it
   raises `RuntimeError("schedule queue full")` (`py/modmicropython.c`). The ring is emptied only at MicroPython's
   jump opcodes (`JUMP`, `POP_JUMP_IF_*`, `JUMP_IF_*_OR_POP`, `UNWIND_JUMP`,
   `POP_EXCEPT_JUMP`), and only when no scheduled callback is already running.
   The callback may allocate. An exception inside it is printed and does not
   unwind the interrupted program (`mp_call_function_1_protected` in
   `py/runtime_utils.c`). After the entry module returns, an armed timer
   keeps the hart polling through `machine.idle` until the testbench budget
   ends. The unix port is the oracle for `schedule` overflow and for
   `print`. Edge traces use the host register model. The unix `machine`
   module does not implement this map.
3. **Pending exception.** `UART_RX` matching `micropython.kbd_intr`'s character
   (Ctrl-C by default) sets a pending `KeyboardInterrupt`, raised at the same
   points.

### 5.4 Latency bound

Hard-IRQ latency is bounded by the longest operation that can't be interrupted:
a multi-cycle opcode (a container command's copy grows with the list's length)
or a GC pause.

- **v1:** state the bound, and measure it (§4.4, item 6).
- **v2:** make the long container commands restartable, using the same "abort
  before commit" rule the GC already uses, and make GC interruptible (§5.5,
  item 3).

### 5.5 GC driven by interrupts

1. **`GC_REQ` interrupt (v1).** The allocator counts bytes allocated since the
   last collection. When the count passes `gc.threshold()` (MicroPython's
   meaning), or free memory drops below a low-water mark, it raises `GC_REQ` as
   a soft source. The collection then happens at the next safe point, *before*
   any allocation fails. Visible behavior is identical to MicroPython's
   threshold collection, and the abort-and-retry path becomes rare.
2. **Collecting while idle (v1).** On `WFI` (`time.sleep_*`, `machine.idle()`),
   if `GC_REQ` is pending or the heap is dirty, the GC engine runs while the
   core waits. A wake-up IRQ during the mark phase discards the marks, which is
   safe because nothing has been freed yet. During the sweep phase, it stops at
   the next block boundary (lazy sweep). The result is GC that hides inside
   sleep. MicroPython on a real board can't do this, because its GC shares the
   CPU with the program. **This is a distinctive paper result.**
3. **Hard IRQ during GC (v2, after the deadline).** Incremental marking with a
   Dijkstra insertion barrier: while `gc_marking` is set, every reference store
   (`STORE_ATTR`, `STORE_SUBSCR`, `STORE_GLOBAL`, list and dict writes) greys
   the stored pointer. In hardware the barrier is a 1-bit check on the store
   path. It cuts hard-IRQ latency during GC from a full collection to one mark
   step.

New GC roots: the handler table, the schedule ring, the pending-exception slot,
the emergency exception buffer, the saved IRQ frame, the builtins dict,
`sys.modules` once import exists, and every live slot of every suspended
frame. A scan of only the value-stack slice below the stack pointer misses
locals in the pin's frame (`py/vm.c` places local 0 at `state[n_state - 1]`).
This hart keeps its own frame layout and still roots every live slot.

### 5.6 Supporting software

- `micropython.heap_lock()`, `heap_unlock()`, and `alloc_emergency_exception_buf(n)`.
  The emergency buffer is a statically reserved exception object, so an
  exception raised while the heap is locked can still be built.
- Copy every message text from the oracle.
- `time.sleep_ms` sets a timer compare and loops on `WFI`; it doesn't
  busy-wait.

### 5.7 Exit tests

| Test | Checks |
| --- | --- |
| `blink` | A timer IRQ toggles `GPIO_OUT`; the testbench counts edges at the period |
| `echo` | A UART RX IRQ schedules a callback that writes TX |
| `debounce` | Pin IRQ plus `ticks_diff` |
| `hard_irq_alloc` | A hard handler that allocates prints the uncaught-exception message for `MemoryError` |
| `sched_full` | The ninth `schedule` raises `RuntimeError: schedule queue full` |
| `ctrl_c` | Ctrl-C stops `while True: pass` with `KeyboardInterrupt` |
| `gc_req` | An allocation loop runs with no abort-and-retry, and its output matches the oracle |
| `irq_latency` | A latency histogram stays under the stated bound |

Where output is deterministic, compare with the oracle: the unix port has
`micropython.schedule`, and its scheduler runs at the same jump points.
Compare timing traces with the host register model.

---

## 6. Everything else we need

1. **Import pycore into this repo (Track 0). Done.** The import is a snapshot
   of `43d791a`, not a history merge, so `git blame` stops at the import
   commit. pycore keeps the full history and stays the record of the CPython
   hart. Trim in reviewable commits, following §1.2.

   The import brought pycore's CI with it:
   - `.github/workflows/all-tests.yml` runs the full hardware matrix on every
     non-docs PR to `main`.
   - `.github/workflows/gc-nightly.yml` runs a daily cron once it is on `main`. By
     the workflow's own estimate, that is about 4.5 hours of runner time a night:
     gc-long 17 minutes, single-core fuzz 80 minutes, two-core fuzz 3 hours.

   Decide whether this repository keeps the nightly run before the
   restructuring makes it meaningless: it tests the 16 MB CPython GC
   configuration.
2. **One plan of record.** The Cursor draft (`micropython_mcu_plan.md`) and
   this plan disagree on six major points (§9). `planning/README.md` names this
   plan the plan of record, and the draft carries a note saying so. The phase
   contract that folds the three reviews is
   `planning/mpy_review/merged_plan.md`. It follows D1–D7. Where a phase gate
   and a week exit meet, the merged plan's mapping table is the join. Keep a
   single roadmap, or agents will advance both at once.
3. **REPL over UART.** The normal REPL, paste mode (Ctrl-E), and **raw REPL**
   (Ctrl-A; Ctrl-D executes; "OK" responses; Ctrl-B leaves). `mpremote` and
   Thonny use the raw REPL. With the simulator's UART exposed on a pty (through
   a Verilator DPI), `mpremote connect /dev/pts/N run x.py` works against the
   simulator. That makes a good demo and an interactive debugging path.
4. **Boot sequence and frozen manifest.** Use MicroPython's `manifest.py`
   (`freeze`, `module`, `require`) through `tools/manifestfile.py`. Boot runs
   `boot.py`, then `main.py`, then the REPL, as MicroPython does. The firmware
   builtins and the compiler are frozen modules too.
5. **No filesystem in v1.** `open` is absent, as on a MicroPython port with no
   VFS. Later: a RAM disk, then littlefs in flash, so user modules can be
   imported.
6. **Memory map.** Keep the Cursor draft's addresses: flash at `0x0000_0000`
   (512 KB), SRAM at `0x2000_0000` (256 KB), MMIO at `0x4000_0000`, and the
   simulator-control window at `0xE000_0000` (simulation only; that address
   is the Cortex-M system region, and this window is not a system-control
   block). Reserve the first 8 bytes of flash so a later `REPR_A` object
   never sits at address 0 or 4 (`MP_OBJ_NULL` and `MP_OBJ_SENTINEL` in a
   non-debug build). The 256 KB SRAM holds the frame reserve, a resized RF
   spill, the schedule ring, the handler table, and the GC pool. The spill
   today is a 256 KB LIFO at `0xF40000` (`pycore/docs/architecture.md`);
   copying it in unchanged leaves no pool. Phase 0 measures `make test-calls`
   (the testbench prints `RF spill_count`) and the frame high-water mark,
   then locks the split in `pycore/docs/mpy_memory_map.md`. `-X heapsize`
   names the pool only. The 8-byte fetch buffer in §1.0 holds instruction
bytes only: it does not cache MMIO, and a flash data load is not an
instruction prefetch.
7. **Synthesis evidence.** "Microcontroller-class" needs an area number and an
   Fmax (§4.4, item 7). Add a synthesis target before the removals start, so
   each removal can be measured.
8. **Naming.** pycore's `GIC` is a *global-name inline cache*. Rename it (for
   example `gncache`) before adding an interrupt controller, so nobody reads it
   as an ARM GIC.
9. **Third-party attribution.** MicroPython is MIT-licensed. Record everything
   we vendor or port in `THIRD_PARTY.md`: `perf_bench`, the `mpy-tool.py`
   reader, `manifestfile.py`, and ports of `formatfloat`, `parsenum`,
   `lib/libm`, `mp_map`, and `mp_quicksort`.
10. **Guardrails for agents.** pycore's `.cursor/skills/bytecode-brief` and
    planning documents point at CPython opcodes. Add an `AGENTS.md` /
    `CLAUDE.md` here with the list of work not to start (CPython opcodes,
    exception tables, insertion-ordered dicts, the 1 GHz comparisons), and a
    pointer to this plan.
11. **Debug tooling.** Retarget `cosim_trace.py` to MicroPython opcode names,
    using the disassembler in `mpy-tool.py`.
12. **The paper's story.** Drop the CPython-ratio claims. New claims:
    performance per MHz against MicroPython on RP2040 and ESP32,
    bytecode-boundary interrupt latency, hardware GC hidden during idle time,
    memory density, and the pass rate on MicroPython's own tests. Update
    `docs/paper/systems/call_fsm.tex` for MicroPython's call shapes.
13. **Later:** `machine.WDT`, `reset_cause`, `lightsleep`, `PWM`, `ADC`, `I2C`,
    `SPI`, a second IRQ priority level, MPZ bigints, generators and `asyncio`,
    and MicroPython's 4-byte object word (the remainder of D2).

---

## 7. Schedule (four weeks, deadline assumed around 2026-11-13)

The tracks run in parallel. Each week ends with a test that later weeks may not
break.

| Track | Week 1 (Oct 14–20) | Week 2 (Oct 21–27) | Week 3 (Oct 28–Nov 3) | Week 4 (Nov 4–10) |
| --- | --- | --- | --- | --- |
| **0: Import and pin** | Import pycore (done); pin MicroPython v1.29.0; build the oracle and `mpy-cross` in Docker; `targets/mpycore.json` | — | — | — |
| **F: Front end** | Byte fetch; MicroPython decode of the integer subset; flash-image tool (reusing the `mpy-tool.py` reader) | Prelude decode for every function kind; qstr tables | — | — |
| **X: Execution** | Calls with positional arguments, return | Defaults, closures, exception stack, trap→exception conversions, `MemoryError`/`OverflowError`, MicroPython dict order | Runtime `class`, `import`, `with`, binary32 float and formatting, `str.format` | `bytes`/`bytearray`/`struct` |
| **M: Memory** | Microcontroller memory map; `UART_TX` print path; excore and caches out of the build | Stage-B 8-byte slot: one shared encode/decode helper | Stage B in every container FSM and in GC tracing | Measure density |
| **C: Compiler** | C1 | C2 | C3 | C4 |
| **T: Tests** | Oracle variant; expected-output pipeline; migration script | Migrate the 523 programs | Conformance dashboard | Every gate green |
| **I: Interrupts** | — | IRQ controller design; GC roots | Timer, GPIO, UART RX; hard and soft delivery | `GC_REQ`, idle GC, Ctrl-C, latency |
| **B: Benchmarks** | **Buy boards; run `perf_bench` on them** | `fannkuch`, `wordcount` on the simulator | `pystone`, `aes`, float tests; synthesis Fmax and area | Full report and figures |
| **R: Product surface** | — | `gc`, `sys` | `machine`, `time`, `micropython` | REPL, raw REPL, `mpremote` |

**End-of-week exit tests**

| Week | Exit test |
| --- | --- |
| 1 | A `while` that adds two locals, a `print` of that sum, and a call match the oracle; `print(1+2)` is not the ALU test; board data is collected |
| 2 | The exceptions, containers, and calls areas are green against the oracle; `bm_fannkuch` runs |
| 3 | blink and echo pass; `misc_pystone` runs; the conformance pass rate is published |
| 4 | Benchmark report and every gate |

The buffer is Nov 11–13.

**Cut list, in order (cut the first item first):**

1. Generators and `asyncio` (already a stretch goal)
2. Raw REPL and `mpremote`
3. Idle-time GC
4. On-device compiler beyond C2
5. The Stage-B slot, reporting density honestly at 32 B per slot

Never cut the oracle switch, exceptions as values, or the benchmark comparison
against boards.

---

## 8. Risks

| Risk | Mitigation |
| --- | --- |
| CPython assumptions spread through 41k lines of RTL (`pycore_defs.svh` alone is 3,833 opcode-specific lines) | Map the decoder onto existing FSM entry states. Spend the first days of week 1 producing the full list of mismatches |
| Stage B touches every container FSM and GC tracing | Write one shared encode/decode helper first, then make mechanical edits. `gc_fuzz.py` and the GC mutation tests catch tracing mistakes |
| Dict order must match exactly | Test a host model of `py/map.c` against the oracle before writing RTL |
| Bit-exact binary32 `math` results | Port `lib/libm`, or compare at printed precision |
| The unix port isn't an RP2 or ESP32 port: its modules, error level, and recursion depth differ | Match the config (§3.2), and spot-check expected outputs on a real Pico |
| The `.mpy` ABI (static qstr list) changes when MicroPython is updated | Stay pinned. Moving to a new tag means a new catalog and a new qstr table |
| Simulator time: about 100M cycles per benchmark | Run benchmarks nightly; don't gate merges on them |
| Two roadmaps at once | §6, item 2 |
| A month is tight | The cut list in §7 |

---

## 9. Relation to the Cursor draft (`micropython_mcu_plan.md`, merged in [PR #1](https://github.com/ColtonHarris999/micro-pycore/pull/1))

**Kept:** pinning one MicroPython release; the unix-port oracle; the memory-map
addresses; the peripheral register offsets; the safe-point GC rule; the
container-accelerator command rule; one exit test per phase; and the rule that
CPython-hart work stays in pycore.

**Changed:**

| Cursor draft | This plan | Reason |
| --- | --- | --- |
| New core from scratch in a sibling `mpycore/` tree; nothing in `pycore/rtl` reused | Import pycore here and retarget it | The deadline (D1) |
| No on-device compiler in v1 | Retarget the compiler; ship it as a frozen `.mpy` | Your requirement, and the REPL (D5) |
| Float and long ints off; 31-bit ints that raise `OverflowError` | binary32 float, 64-bit `LONGLONG` ints, `complex` kept | Binary32 matches ESP32 and RP2. Those boards use MPZ for ints; `LONGLONG` matches the existing ALU, and MPZ stays post-deadline. A 31-bit limit breaks `0xFFFFFFFF` register masks (D3) |
| One schedule queue; all IRQs handled when the next bytecode is dispatched | Hard and soft classes, matching MicroPython's jump-point semantics; `GC_REQ` and idle GC | Matches MicroPython's behavior, and uses interrupts for GC |
| "Cycle counts are recorded, not compared" | Compared against real boards on `perf_bench` | Your requirement |
| Oracle config not specified | A concrete variant (§3.2) | Without one, `MemoryError` and float parity can't be tested |

Several numbers in the draft don't match `43d791a`: it gives RTL as about 82,000
lines and the compiler as about 14,000. The measured figures are 41,994 lines in
`pycore/rtl` (including `attic/`) and 7,000 lines of compiler.

---

## 10. Sources

**MicroPython v1.29.0** (`0fd6c573`):

| File | What it supports in this plan |
| --- | --- |
| `py/persistentcode.h` | `.mpy` version 6.3 |
| `py/bc0.h` | The opcode list |
| `py/vm.c` | Where pending callbacks and exceptions are checked |
| `py/map.c`, `py/qstr.c` | Dict order and the string hash |
| `py/objlist.c` | Unstable quicksort |
| `py/mpconfig.h` | Feature levels, hash width, float format |
| `py/lexer.c` | f-string rewriting |
| `py/compile.c` | Decorator handling |
| `py/objint_longlong.c` | Overflow behavior |
| `shared/runtime/mpirq.c` | IRQ handler locking and the uncaught-exception message |
| `ports/{esp32,rp2,stm32,unix}/mpconfigport.h`, `ports/unix/variants/longlong/` | Port configurations |
| `tools/ci.sh` | The 32-bit build recipe |
| `mpy-cross/main.c` | `-msmall-int-bits` |
| `tests/perf_bench/`, `tests/cpydiff/` | The benchmark suite and the documented differences |

**pycore** (`43d791a`): `README.md`, `pycore/docs/{compiler,compile_limitations,bytecode_support,limitations,object_model,dict_excore,architecture,gc,cpython_benchmarks,research_machines,research_comparison}.md`,
`pycore/targets/pycore.json`, `pycore/programs/hw_tests.toml`, `Makefile`,
`.github/workflows/*.yml`.

**Web:**

- [MicroPython download page, showing the v1.29.0 release date](https://www.micropython.org/download/PCA10031)
- [MicroPython differences from CPython](https://docs.micropython.org/en/v1.25.0/genrst/index.html)
- [Writing interrupt handlers (ISR rules)](https://docs.micropython.org/en/v1.25.0/_sources/reference/isr_rules.rst.txt)
- [ArduSimple: MicroPython platforms benchmarking](https://www.ardusimple.com/micropython-platforms-benchmarking/)
- [scruss: MicroPython benchmarks (Jan 2025)](https://scruss.com/blog/2025/01/21/micropython-benchmarks/)
