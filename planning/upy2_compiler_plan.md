# Incorporating the uPy2 compiler

Status: **plan.** The hart runs `.mpy` from host `mpy-cross`. `compile`, `exec`, and `eval` raise `NotImplementedError`. The compiler that replaces that host step already exists, in [uPy2](https://github.com/ColtonHarris999/uPy2) at `72bfd5c145215ea76815a2ffa9762a7995784bd1` (`mpyc/`, MicroPython v1.29.0 bytecode).

This plan is the join. uPy2 owns the compiler and its corpus. This repo owns the runtime the compiler runs on, and the loader that turns the compiler's `.mpy` bytes into a call the hart can make. Both sides change. The changes are listed separately so a compiler fix lands in uPy2 and a runtime fix lands here.

The pivot plan's compiler section (`micropython_pivot_plan.md` §2) and merged plan phase 6 described a compiler that had not been written yet. uPy2 is that compiler. Where this file gives a number, it is measured in uPy2's README at that commit, on a 32-bit unix build unless a row says otherwise.

## 1. What uPy2 already is

`mpyc` is a port of MicroPython's own lexer, parser, scope analysis, and emitter, written in the MicroPython subset. Recursion is banned. The parser, the walker, and the emitter keep their stacks in `array('i')` or `bytearray`. `tools/lint_frames.py --budget 32` is the static check. The deepest chain it reports is 13 frames.

End to end, 2148 of 2149 corpus files compile to the same bytes as `mpy-cross` from tag v1.29.0. The one difference is a float spelling that reads back as the same value (`DEVIATIONS.md` D2). Files the oracle rejects are rejected here too. The compiler compiled by its own bytecode reaches a fixed point: 25 of 25 of its modules, and 1475 corpus files, byte-identical across the bootstrap stages.

| Measured on the 32-bit unix port | Value |
| --- | --- |
| Source | 25 modules, 9682 lines, 346 KB |
| `.mpy` | 119 KB (122133 bytes) |
| Frozen flash cost, on that port | 125 KB of code, plus 102 KB `.rodata` and 25 KB of const tables in the unix build |
| Heap to import it, frozen | 24.6 KB, 35.5 KB once the first compile has filled its caches |
| Heap for a 150–260 line library module | 21.0 KB min, 26.5 KB median, 61.0 KB worst |
| Heap for the largest compiler module (`grammar.py`) | 102.3 KB |

The 64 KB design budget holds for ordinary user modules. Six of the compiler's own modules still miss it (`grammar.py`, `emitbc.py`, `parser.py`, `lexer.py`, `compile_expr.py`, and `compile_defn.py`). Self-compilation of those six is not required to ship `compile()` for user code.

## 2. What this hart already provides

- Fetch is by byte address. `mpy_region` accepts a flash address and an SRAM address, so a raw-code pointer into the GC pool is a legal PC. There is no second fetch path to build.
- The register file has 64 entries. The linker already rejects a function whose `n_state` exceeds that.
- The frame stack is 32 KB. The compiler's own lint stays inside 13 frames.
- SRAM is 256 KB. The GC pool is `MPY_GC_POOL_BYTES` in `upycore/rtl/mpy_defs.svh`: everything after the frame reserve and the root windows, about 223 KB.
- Flash is 512 KB.
- Classes, closures, `try`/`except`/`finally`, comprehensions, relative-import name joining, and frozen modules are on the hart. `use_helper` in the hardware suite imports a frozen module. `mpyc/__init__.py` is a docstring only, so the package-global failure in `use_pkg` does not by itself block `import mpyc.lexer`.
- `compile`, `exec`, and `eval` are the three stubs in `upycore/firmware/builtins.py`.

## 3. The gap

The compiler emits a v6 `.mpy` container. The hart does not parse `.mpy`. Host `mpy_link.py` does, and it writes a flash image. A program compiled on the device never goes through that linker.

So the incorporation is four pieces:

1. The compiler runs on the hart, frozen, and returns `.mpy` bytes.
2. A device loader in the firmware reads those bytes and builds the same raw-code, const, and qstr objects the host linker builds, in the GC pool.
3. `exec` starts a frame at that raw code. `compile` is (1) then (2). `eval` is `compile` of an expression, then `exec`.
4. The qstr table can grow. Today every qstr id is assigned when the image is linked. A compiled module invents strings the image has never seen.

Until (2) and (4) exist, freezing `mpyc` does not make `compile()` work. Do not start by dropping the package into `upycore/firmware/`.

## 4. Changes in uPy2

These stay in the uPy2 repository. This tree vendors a pin. A change that makes the corpus diverge from `mpy-cross` without a row in `DEVIATIONS.md` does not land.

### 4.1 Pin the device, not the unix port

`mpyc/qstr_pool.py` is generated from the unix port and is documented there as a stand-in (773 entries). The device's static list is the catalog's, ids 0 through 165, ending at `zip`, plus whatever qstrs the frozen firmware and the frozen compiler add.

Regenerate the pool from this tree's linked image, not from the unix port. `tools/gen_qstr_pool.py` already takes a `qstrdefs.generated.h`. The host differential tests keep using `tests/oracle_qstr_pool.py` (mpy-cross's pool). On-device output is compared against a compiler that was given the device pool. uPy2 already records that 42 corpus files (1.9%) change trees when the pool changes. Those 42 are not byte-identity failures.

### 4.2 Binary32 constant identity

`parsetree.py` and `floatfmt.py` call `struct.pack` of an IEEE double (`<d` and `>d`) to name a float's bits. The hart's float is binary32. A double key is the wrong identity: two source spellings that become the same binary32 must be one const, and a spelling that does not fit binary32 must be the value the loader will store.

Replace those packs with the 32-bit pattern. Keep the exact decimal speller in `floatfmt.py`. D2 stays: a spelling that reads back as the same value is not a miss, and a spelling that changes the value is. Add the binary32 rule as a new deviation row. The 32-bit unix oracle is the read-back check, because host `mpy-cross` is built with a wider float and will not spell every const the way a binary32 compiler does.

`struct` itself should leave the compiler. The hart has no `struct` module. The two call sites are the whole use. Shifts and masks are enough, and they remove a module the firmware would otherwise have to grow.

### 4.3 `n_state` of 64

The unix port has no 64-entry register file. This hart does, and the linker refuses a function past it. Before the package is frozen, compile every `mpyc/*.py` with the pinned `mpy-cross` (`-msmall-int-bits=31 -O0`) and read `n_state` with `upycore/tools/mpy_prelude.py`. Split any function that does not fit. That split is a compiler change. It is independent of the frame linter: a function can be one frame and still need 80 state slots.

### 4.4 The six modules over 64 KB

Leave them for the self-host milestone. User compiles are inside the budget, and the pool is about 223 KB, so a 102 KB compile of `grammar.py` may fit even though it misses 64 KB. Measure that on the simulator before splitting. If it does not fit, move `grammar.py`'s rule tables out of the function that walks them. That is the split uPy2 already names. Do not recombine the walker. One file peaked at 348.8 KB.

### 4.5 What the compiler must not start using

The hart rejects `YIELD_VALUE` and `YIELD_FROM`. The compiler does not emit them for its own source, and it must not gain a generator. `len` of a non-ASCII string currently falls into firmware and raises. The lexer accepts identifiers whose first byte is `>= 0x80`. If a compiler path takes `len` of such a string, that is a uPy2 bug to fix after the runtime `len` fix, or to avoid until that fix lands. Set displays are not used to order emitted bytes. Do not add one. Dict order on the hart matches the oracle. Set order does not, and a set iterated into the bytecode would break byte-identity.

## 5. Changes in uPyCore

### 5.1 `array`

`array('i')`, `array('I')`, and `array('H')` are the compiler's memory. They are not a Python list of boxed ints. A list would blow the 64 KB budget. The compiler was measured with `array`.

Add an `array` module with those three typecodes: construct from an iterable, index, slice, append, extend, and the buffer the compiler already uses. Store the items in one heap buffer, the same shape as a bytearray. `array` is a reasonable native type next to `bytearray`. A first version can be firmware over a byte buffer if the indexing stays correct for signed 32-bit. The hardware suite gets one program that builds an `array('i')`, mutates it, and prints the values. That program is the gate for this step, and it runs before any of `mpyc` is frozen.

### 5.2 Frozen package imports

`mpyc` is a package of 25 modules. They import with `from . import ...`. `_import` already joins a relative name from `__name__` when `__package__` is missing. Prove it with a hardware test shaped like the compiler, not like `use_pkg`:

- `pkg/__init__.py` is empty of assignments, as `mpyc/__init__.py` is.
- `pkg/a.py` does `from . import b` and calls a function in `b`.
- Both modules are frozen, `pkg` as a package.

`use_helper` already covers a single frozen module. `use_pkg` covers a package body that assigns a string global, and that assignment is an open bug. The compiler's `__init__.py` does not do that assignment. The new test is the one that has to pass. If relative import fails, fix `_import` and the module object's `__package__` before touching the compiler.

### 5.3 The device loader

A new firmware function takes the bytes `mpyc` encoded and returns a callable raw code. It is the on-device half of `mpy_link.py` and `mpy_prelude.py`:

- Header `4d 06 00 1f`. Reject a native, viper, or asm architecture the way the host linker does.
- Qstrs. Ids 1 through 165 are the static list. Any other string is interned into a RAM table that extends the image table. Ids already in the image are reused.
- Consts. `None`, `False`, `True`, ellipsis, str, bytes, a signed 64-bit int, a binary32 float, a complex, and tuples of those. An int outside signed 64-bit is a compile error in uPy2 (D1) and a load error if one arrives anyway.
- Raw code. Prelude, bytecode, line info, children, closure bytes. The bytecode lives in a GC-visible buffer in the pool. The raw-code descriptor is the same twenty-word layout the host linker writes, so the call path does not grow a second format.
- The buffer and every const it points at are roots for as long as the code object is reachable.

The host linker stays the path for the firmware and for `make test`. The device loader is only for code that did not exist when the image was built.

### 5.4 `compile`, `exec`, `eval`

`compile(source, filename, mode)` calls the frozen compiler and then the loader. `mode` is `"exec"` or `"eval"`, matching MicroPython. `exec(code)` with a code object from `compile` calls that raw code in the caller's globals. `exec(source)` compiles and then calls. `eval` is the expression form.

An exception raised in the compiled code uses the existing traceback path. The filename is the string passed to `compile`, so a hardware test can lock the traceback text.

`compile` of a syntax error raises the compiler's `SyntaxError` text. That text is part of the uPy2 corpus. Do not rewrite it in the firmware.

### 5.5 Freezing

Freeze `mpyc/*.py` only. `tools/` and `tests/` stay on the host. The image is the firmware plus `mpyc` as frozen modules, linked by `mpy_link.py`, which already accepts `--module`.

Budget check, measured on a built image, before the freeze is kept:

| Item | Ceiling |
| --- | --- |
| Flash image | 512 KB, firmware included |
| Heap after `import mpyc` | the unix measurement is 24.6 KB. Re-measure on the simulator. A large miss means a loader or qstr-table leak, not a reason to rewrite the compiler |
| Heap for the hardware-suite programs compiled on device | 64 KB, the uPy2 user-module budget |
| `n_state` | 64, from §4.3 |

### 5.6 Runtime bugs that are not on this path

The hardware suite's six `xfail`s are tracked in `planning/agent_prompts/`. They do not all block the compiler.

| Failure | Effect on the compiler |
| --- | --- |
| Float and complex printing | None for emitted bytes. `mpyc/floatfmt.py` spells constants itself. The runtime printer is only what `print` does after the code runs |
| Set iteration order | None, as long as `mpyc` does not iterate a set into the bytecode. Do not add that |
| `len` of a non-ASCII str | Blocks a source that takes `len` of such a string. The lexer accepts those identifiers. Fix `len` before claiming non-ASCII sources compile |
| `getattr` of a list method | Not the compiler's `getattr`. The walker calls `getattr` on its own instance and on the emitter. That path already serves instance attributes in `classes`. Add one hardware test, `getattr` of a method on a user class, and fix it if it fails |
| Frozen package global | `mpyc/__init__.py` binds nothing. The relative-import test in §5.2 is the real gate |

## 6. Optimizations, in order

Do these when a measurement says so, not before the first on-device compile.

1. **Collector pressure.** uPy2 measured 0.3–1.8 MB of allocation on a parse when it did not collect, against tens of KB live. On this hart that is a long series of collections. Profile one 200-line compile (`cycles` and `gc` from the halt line). If the compile is dominated by collections, the allocations to remove are the ones uPy2 already names: the per-node child list and the constant-key tuples. That is a uPy2 change.
2. **The six oversized modules**, only if on-device self-compilation is in scope and the 223 KB pool cannot hold them. Tables out of `grammar.py` first.
3. **Flash wait states on the frozen compiler.** The compiler executes in place from flash. A later, measured, change can copy a hot raw code into SRAM. Do not build a cache for it.
4. **Qstr table growth.** Appending one string at a time during a compile reallocates the table. A compile of a large module should reserve. Measure first.

Do not spend the first change on a faster FPU or on set order. Neither one decides whether `compile()` works.

## 7. Tests

Host tests stay in uPy2. `tests/test_compile.py` against this tree's `mpy-cross`, with the device qstr pool for the on-device configuration and the mpy-cross pool for the byte-identity configuration. D1 (ints outside signed 64-bit) and D2 (float spelling) stay accepted differences.

Device tests are hardware-suite programs. Each one compiles a source string and prints the result of running it. The golden is the unix oracle running that same source, not the compiler's stdout. Byte-identity is reported beside that, and it is required only for the files that do not fall under D1, D2, or the qstr-pool difference.

| Program | What it locks |
| --- | --- |
| `array('i')` mutate and print | §5.1, before the compiler is frozen |
| `from . import` across two frozen modules | §5.2 |
| `getattr` of a method on a user class | §5.6 |
| `compile` of `print(1 + 2)`, then the value | loader and `exec` |
| `compile` of a `def`, a `for`, a `try`, and a class | the constructs the suite already runs when `mpy-cross` emits them |
| a syntax error | the compiler's `SyntaxError` text, on stderr, exit status 1 |
| one 200-line module | heap high-water under 64 KB, from `gc.mem_alloc` around the compile |

The self-host check is last: the on-device compiler compiles one of its own small modules, and the `.mpy` bytes match the host compiler given the same qstr pool. The six modules over 64 KB are not in that check until §4.4 says they fit.

## 8. Order of work

| Step | Where | Exit |
| --- | --- | --- |
| 1. Vendor uPy2 at `72bfd5c` | this repo, `vendor/upy2` | The pin builds under host CPython against this tree's `mpy-cross` |
| 2. `array` | firmware | The new hardware test passes |
| 3. Relative frozen import | firmware | The package test in §5.2 passes |
| 4. `n_state` audit and splits | uPy2 | Every frozen function links |
| 5. Binary32 const keys, drop `struct` | uPy2 | Host corpus still matches, with D2 updated |
| 6. Device qstr pool | uPy2, generated from this image | Host tests pass with the device pool. The 42 pool-sensitive files are listed, not failed |
| 7. Device loader and dynamic qstrs | firmware | A hand-built `.mpy` of `print(1)` runs from SRAM and prints `1` |
| 8. `compile` / `exec` / `eval` | firmware, frozen `mpyc` | The compile hardware tests pass, and the flash image is under 512 KB |
| 9. Heap measurement | simulator | The 200-line module is under 64 KB live. Record the halt line |
| 10. Self-host of one small module | both | Bytes match the host compiler |

Steps 2, 3, and 7 are this repo. Steps 4, 5, and 6 are uPy2. Step 1 is the pin. Step 8 cannot start until 2, 3, 6, and 7 are done. Step 4 can run beside them. It only has to finish before the freeze in step 8.
