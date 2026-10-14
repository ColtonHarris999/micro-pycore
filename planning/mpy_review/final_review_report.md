# Final review of the MicroPython translation plan

Date: 2026-10-14. Branch: `mpy_translation`.

The three reviews in this directory were written against
`planning/micropython_mcu_plan.md` on a checkout that did not contain the
imported tree. This report checks each finding against this tree and
against MicroPython v1.29.0 at `0fd6c573` (cloned for this review; not
vendored). The phase contract is [`merged_plan.md`](merged_plan.md). The
plan of record for product decisions remains
[`../micropython_pivot_plan.md`](../micropython_pivot_plan.md).

## Owner decision, 2026-10-14

After this review, the owner required three things:

1. One `.mpy` module loads another the way the pin does, including
   `import *` and relative import. The standard library is not rewritten
   this month. Frozen `.mpy` is linked into the image; a missing module
   raises `ImportError`. There is no filesystem this month.
2. `*args` and `**kwargs` match `mp_setup_code_state` in `py/bc.c`.
3. The month aims at as much of the pinned oracle as will run. The
   deferral list is in the merged plan's coverage section.

The conflict section below is the review's earlier, narrower resolution.
The plans now follow this decision. Open question 5 is answered.

A finding is confirmed only when a file in this tree or in that tag
supports it. Majority among A, B, and C is not a vote.

## How to read the reviewers

All three deleted the draft's supersession banner and kept the assumption
that v1 is a new core in a separate `mpycore/` tree, with 31-bit ints,
float off, and no on-device compiler. That banner is the first 13 lines of
[`base_plan.md`](base_plan.md). The pivot plan had already replaced those
four choices (D1, D3, D5, and §9). Where a reviewer's repair is right for
the draft and wrong for the pivot, the verdict says so.

## Inventory and verdicts

Severity is blocker (an implementer would build the wrong machine),
significant (a gate would fail or a behavior would be unspecified), or
minor.

| ID | Finding | Who | Where | Severity | Verdict |
| --- | --- | --- | --- | --- | --- |
| F01 | The stock unix port is not the v1 oracle | A §1, B F1, C "stock unix" | Phase 0, locks | Blocker | Confirmed for the draft. The repair in the merged plan is the pivot's variant, not long-int-off / float-off |
| F02 | `.mpy` is a container; the prelude is bit-interleaved; the first opcode is after source info | A §2, B F2, C loader section | Phase 1 | Blocker | Confirmed |
| F03 | `print(1 + 2)`, a call, and `for`/`range` do not fit a no-heap integer phase | A §3, B F3, C "phase 2" | Phase 2 | Significant | Confirmed as a test-design hole. The "no heap, so no call" cut is rejected under D1 |
| F04 | Closures, methods, iterators, slices, `with`, keywords, and `super()` have no phase in the draft | A §4, B F3 and F5, C "work that has no phase" | Phases 3–6 | Significant | Confirmed for the draft. The pivot already assigns them. See conflicts |
| F05 | Object immediates, the null word, and frame roots | A §5, B F2 and F3, C GC section | Phases 2–3 | Significant | Confirmed as facts about the pin. Immediate `REPR_A` as the v1 word is rejected (D2) |
| F06 | GC abort rule, 256 KB versus the heap, roots, mark stack, emergency `MemoryError`, finalisers | A §6, B F4, C GC section | Phase 3 | Blocker | Split. See below |
| F07 | Peripheral table is not a Python binding; IRQ versus `schedule`; "these four" | A §7, B F6, C interrupts | Phase 5 | Significant | Confirmed as underspecified. Hard versus soft follows the pivot |
| F08 | On-device compiler cannot be a freeze of `py/compile.c` | A §8, C "phase 6" | Phase 6 | Significant | Confirmed that `py/compile.c` cannot be frozen. Dropping the compiler is rejected (D5) |
| F09 | This repository has no CPython hart and no `make test-hw` | A §9, B F7, C "not the pycore tree" | Phase 0, test contract | Blocker if believed | Rejected |
| F10 | Add filesystem, threads, REPL, native/viper, finalisers, weakrefs, `id()` to non-goals | A §10, C | Non-goals | Minor | Split. REPL as a non-goal is rejected |
| F11 | Add object, exception, interrupt, and bytecode doc pages | A §11, C | Doc contract | Minor | Confirmed, with paths under `pycore/docs/` |
| F12 | Draft line counts, "these four" registers, prelude sentence, `371dc007` | A §12 | Audit | Minor | Confirmed, except the mark-stack "already failed" clause inside F06 |
| F13 | Bytecode qstr operands are table indexes; v6 does not patch them | A §2, B F2 | Phase 1 | Significant | Confirmed |
| F14 | Dict order | A §4 says insertion order; C says insertion order; B F4 says hash order | Phase 3 | Blocker | A and C rejected. B confirmed |
| F15 | `mpy-cross` constant-folds and is built with MPZ and double | B F1, C | Phases 0–2 | Significant | Confirmed |
| F16 | The loader ignores sub-version on bytecode-only files | A §2, C | Phase 1 | Significant | Confirmed |
| F17 | `True`/`False` immediate ids versus `True + 1 == 2` | A §3, C | Phase 2 | Minor | Both descriptions confirmed. They are not a conflict |
| F18 | Extra-features `str` indexes by Unicode code point | C | Phase 3 | Significant | Confirmed that the flag is on. The algorithm is the pin's `py/objstr.c` |
| F19 | `0xE000_0000` collides with the Cortex-M system control space | A §7 | Memory map | Minor | Kept as a sim-only window. The address stays |
| F20 | A later fetch buffer must not cache MMIO | C | Phase 2 fetch | Minor | The constraint is accepted. "No buffer in v1" is rejected; the pivot plan already specifies an 8-byte instruction buffer |
| F21 | Phase 2 needs an opcode trace | C | Phase 2 | Minor | Accepted. The pivot already names retargeting `cosim_trace.py` |
| F22 | Recursion is `RuntimeError`, not `MemoryError` | B F4, C | Phase 4 | Significant | Confirmed for the message. B's `py/objfun.c` citation was not found |
| F26 | After `main` returns, an armed timer must still be polled; blink must be bounded | C | Phase 5 | Significant | Confirmed as a hole |
| F27 | Unix `machine` does not implement this MMIO map | B F6, C | Phase 5 | Significant | Confirmed as a plan gap |

F23 and F24 below are not reviewer findings. They showed up while checking
the pivot plan against this tree.

### F01 — Oracle config

Confirmed against the tag:

- `ports/unix/variants/standard/mpconfigvariant.h` sets extra features.
- `ports/unix/variants/mpconfigvariant_common.h` lines 40–51 and 86–87
  default float to double, long int to MPZ, and error reporting to
  detailed.
- `ports/unix/mpconfigport.h` line 118 forces finalisers on.
- `ports/unix/main.c` line 67 sets the default heap to
  `1024 * 1024 * (sizeof(mp_uint_t) / 4)`, which is 2 MB when
  `mp_uint_t` is 8 bytes.
- `ports/unix/variants/longlong/mpconfigvariant.h` lines 31–38 use
  `LONGLONG`, binary32, and `REPR_C`.
- `py/obj.h` lines 86–90: a small int is the word shifted right by 1, so
  the width follows `mp_int_t`. A 64-bit process does not give a 31-bit
  small int.

The pivot plan §3.2 already specifies a 32-bit `REPR_A` variant with
`LONGLONG`, binary32, extra features, and normal error reporting. That
variant matches D3. The reviewers' overlay (long int off, float off) would
make `/` a type error and would not run the float benchmarks. It is the
right repair only for the draft's locks, which D3 replaced.

The variant in §3.2 was still missing three settings the tag requires:

- `MICROPY_SCHEDULER_DEPTH` defaults to 4 at `py/mpconfig.h` lines
  1232–1233. ESP32, RP2, and STM32 set 8. The pivot's "ninth schedule"
  test matches 8 only if the variant sets it.
- `MICROPY_ENABLE_FINALISER` is on at extra features (`py/mpconfig.h`
  lines 795–796) and forced on by the unix port. The pivot plan §1.2
  forbids `__del__`. The variant has to turn finalisers off or a
  finaliser that prints will desynchronize stdout.
- Uncaught exceptions go to `MICROPY_ERROR_PRINTER`. The draft compared
  stdout only.

Those three are now in the merged plan's lock table and in the pivot plan
§3.2.

### F02 — Image and prelude

Confirmed in the tag, and absent as an encoding description from the
draft's phase 1:

- `py/persistentcode.h` lines 33–38: version 6, sub-version 3. Lines 40–44:
  version 6 reused the old map-cache bits as the sub-version.
- `py/persistentcode.h` lines 123–133: const kinds include child function
  tables, ellipsis, str, bytes, int, float, complex, and tuple.
- `py/persistentcode.c` lines 464–515: header check, then one qstr table
  and one object table, then raw code.
- `py/persistentcode.c` line 48: `QSTR_LAST_STATIC` is `MP_QSTR_zip`.
  Line 573 stores those as ids.
- `py/bc.h` lines 32–62: the signature and the size are bit-interleaved,
  then source info and cells, then bytecode. The comment is the spec.
  The bit masks in the macros are deliberately not copied into the plan.

The pivot plan §1.0 lists the prelude fields and says to cache them in
CODC. It does not say the encoding is interleaved, or that source-info
bytes sit in front of the first opcode. A decoder written from the pivot
text alone can still fetch those bytes as opcodes. The merged plan phase
1 and the pivot plan §1.0 now say that.

### F03 — Phase 2 exits

Confirmed in the tag:

- `mpy-cross/mpconfigport.h` line 56 turns constant folding on. `py/parse.c`
  `fold_constants` (from line 744) folds `+`, `-`, `*`, `/`, `%`, `//`,
  and `**`. `print(1 + 2)` does not execute an add.
- `py/vm.c` around the call entry (line 984 in the stackless path, and the
  comment at lines 992–993): the call operand packs a positional count and
  a keyword count.
- `GET_ITER`, `FOR_ITER`, and `range` are real opcodes (`py/bc0.h`). A
  `for` loop is not the phase 2 `while`.
- `mp_setup_code_state` in `py/bc.c` line 324 sets `sp` to
  `&state[0] - 1`. Locals and the value stack are one array.

Under D1 the call FSM, the frame region, and the heap already exist, so
"phase 2 may not allocate a function object" is not a v1 cut. The merged
plan keeps the call and requires the ALU test to be a `while` on locals.
The pivot week-1 exit line is updated the same way.

### F04 — Unowned features

Confirmed that the draft's phases never name `LOAD_METHOD`,
`GET_ITER` / `FOR_ITER`, `UNWIND_JUMP`, closures, or keyword calls. The
pivot plan §1.0 maps those opcodes onto existing FSMs and §1.1 gives
weeks. The merged plan assigns them to phases 3 and 4.

Two reviewer recommendations are rejected because they contradict that
map:

- Keyword calls and `*args` as a v1 non-goal (C). Keyword calls stay,
  because the binder already takes them. The review left `*args` /
  `**kwargs` as an image-build reject. The owner decision at the top of
  this report puts them in phase 4.
- Leaving `super()`, properties, and f-strings unnamed (A, C). The pivot
  week-3 exit includes a property, a classmethod, and `super()`. F-strings
  are the lexer rewrite in `py/lexer.c` line 352, plus `str.format`.

`super()` needs the `__class__` cell. Closures are phase 4, before that
exit. The pivot week order already does this (closures in week 2, class
in week 3). The merged plan says it in the phase 4 text.

### F05 — Immediates and frames

Confirmed in `py/obj.h`:

- Lines 75–77, non-debug: `MP_OBJ_NULL` and `MP_OBJ_STOP_ITERATION` are
  word 0. `MP_OBJ_SENTINEL` is word 4.
- Lines 926–928, when immediate objects are on (true for `REPR_A`,
  `py/mpconfig.h` line 170): `None` is immediate 0, `False` is 1, `True`
  is 3. They are not a dense 0, 1, 2.
- Lines 86–90 and 125–127: a pointer object's low bits are `00`.

`py/objbool.c` lines 82–84 implement binary ops on bool by converting to
a small int, so `True + 1` is 2. A's arithmetic claim and C's encoding
claim are both true.

D2 keeps the hart's slot through the deadline. The merged plan records
the `REPR_A` facts as oracle and post-deadline constraints, including the
reservation of flash addresses 0 and 4. It does not require the stage-A
RTL to use those immediate ids.

`py/vm.c` lines 214 and 284: local 0 is `state[n_state - 1]`. A root scan
of "words from the stack base through SP" misses locals. This hart's
collector already walks frames (`pycore/docs/gc.md` lines 199–207). The
merged plan requires every live slot, and does not require copying
`mp_code_state_t` into RTL.

### F06 — GC

Split verdict.

**Abort, then re-dispatch. Confirmed as the rule to keep.**
`pycore/docs/gc.md` lines 16–17 and 431–432: an allocation that does not
fit aborts before the first architectural commit, then the instruction is
re-dispatched. B is right that the C VM does not do this: `py/gc.c`
collects inside the allocator, and `py/objlist.c` lines 231–236 publish a
grown array inside `list.append`. Replacing the hart's rule with "stall
and retry only the allocation" would be a new contract. The merged plan
keeps the hart's rule and requires allocating opcodes to fail before they
commit. That is the constraint B actually established.

**Same append index raises `MemoryError`. Rejected while slots differ.**
The pivot plan §1.1 said the same program hits `MemoryError` at the same
heap size. D2's slots are 32 bytes, then 8. The oracle's GC block is
`4 * MP_BYTES_PER_OBJ_WORD` (`py/mpconfig.h` lines 250–251), so 16 bytes
on the 32-bit oracle. List growth has its own overallocation (`LIST_MIN_ALLOC`
is 4 at `py/objlist.c` line 40). Those cannot fail on the same append.
The merged plan's tests are a dropped reference that can be reused, and
one allocation larger than the pool. The pivot sentence is corrected.

**256 KB is SRAM, not the pool. Confirmed, and sharper than the reviews.**
The reviews said the window also holds frames. This tree's RF spill is
already 256 KB at `0xF40000` (`pycore/docs/memory_hierarchy.md`, and
`pycore/docs/architecture.md` lines 459–462). Moving that spill into the
MCU SRAM unchanged leaves no pool. Phase 0 measures `make test-calls`
(the testbench prints `RF spill_count`) and resizes the spill. The frame
region today is 32 KB at `0xF01000`.

**Mark stack "has already failed". Rejected.**
A cites `pycore/docs/gc.md`. That page's mark-stack section (lines 78–96)
describes a rescan list that terminates, and lines 604–606 keep
`gc-wide-live-list` as a passing guard, not an open failure. The pin's
stack size default is 64 (`py/mpconfig.h` lines 255–256) and `py/gc.c`
line 622 rescans when `gc_stack_overflow` is set. This hart keeps its own
rescan design. The phase 3 deep-chain test stays.

**Emergency object and finalisers. Confirmed.**
`MICROPY_ENABLE_EMERGENCY_EXCEPTION_BUF` defaults to 0 (`py/mpconfig.h`
lines 831–832). The variant turns it on. The OOM path uses a preallocated
`MemoryError` so raising it does not allocate. Finalisers are off on both
sides, as above.

**Roots. Confirmed as an extension.**
The pivot plan §5.5 adds the handler table, the schedule ring, the
pending-exception slot, the emergency buffer, and the saved IRQ frame.
The reviews add the builtins dict, `sys.modules`, and every frame slot.
The merged plan lists all of them. `MP_REGISTER_ROOT_POINTER` on the
schedule queue is `py/scheduler.c` line 210.

### F07 — Peripherals and IRQs

Confirmed that the draft's register table does not say whether a UART
read pops, what an overrun does, how wide the timer is, or which Python
object performs the store. The sentence above the table said "these four"
while the table has six rows (`base_plan.md` peripheral section). A
corrected the sentence. The six offsets stay.

Delivery, confirmed in the tag:

- `py/vm.c` lines 572–611, 721, and 813–818: `pending_exception_check` is
  reached from `JUMP`, `POP_JUMP_IF_TRUE`, `POP_JUMP_IF_FALSE`,
  `JUMP_IF_TRUE_OR_POP`, `JUMP_IF_FALSE_OR_POP`, `UNWIND_JUMP`, and
  `POP_EXCEPT_JUMP`. The comment at lines 1341–1345 says this is after a
  branch, not after every opcode. `FOR_ITER` dispatches without that
  check (line 810).
- `shared/runtime/mpirq.c` line 85 locks the GC in a hard handler. Line
  91 prints `Uncaught exception in IRQ callback handler`.
- `py/scheduler.c` lines 109–115 run at most one Python callback, via
  `mp_call_function_1_protected`. `py/runtime_utils.c` lines 30–38 print
  that callback's exception and return. They do not raise into the
  caller. `py/modmicropython.c` line 183 raises `schedule queue full`.
- Depth: default 4 (`py/mpconfig.h` 1232–1233); ESP32
  `ports/esp32/mpconfigport.h` line 73, RP2
  `ports/rp2/mpconfigport.h` line 131, and STM32
  `ports/stm32/mpconfigport.h` line 82 set 8. The depth must be a power
  of two (`py/scheduler.c` lines 70–71).

A's "run the callback at the next opcode boundary and let it allocate"
matches neither the hard path nor the soft path. The pivot plan §5.3
already splits them. The merged plan follows that split. Soft callbacks
may allocate. Hard callbacks may not. Polling every bytecode for soft
IRQs is rejected. Hard IRQs at the next bytecode boundary stay, because
this core has no interrupt context inside an opcode; the unix port is not
the timing oracle for that choice.

The UART overrun policy and the timer tick source are not in the tag.
See [Conflicts](#conflicts).

GPIO input is in v1. The pivot plan's debounce exit needs a pin IRQ.
Reviewers who left GPIO as output-only were describing the draft, which
the pivot had already widened.

### F08 — Compiler

Confirmed:

- The pin's compiler is `py/compile.c` and `py/parse.c`. This hart executes
  bytecode. Freezing those C files would require a second machine the
  non-goals forbid.
- `pycore_firmware/compiler/*.py` is 7,000 lines in this tree (lexer 667,
  parser 2,528, symtab 641, codegen 2,440, tables 680, compat 34, toy 10).
  The draft's 14,000 is wrong here. The pivot plan §2.1 already says so.
- RTL under `pycore/rtl` is 41,994 lines including `attic/`, not about
  82,000.

D5 keeps the Python compiler and retargets it. The merged plan's phase 6
is that track. "Leave the compiler out of v1" is the draft, and the pivot
already rejected it.

### F09 — This repository

Rejected. The reviewers did not have the import.

- `Makefile` lines 241, 260, 263, and 266 define `test-host`, `test-hw`,
  `test-caching`, and `test-compiler-vs-cpython`.
- `.github/workflows/all-tests.yml` lines 75–87 skip hardware when the diff
  is markdown, `planning/`, or a license file. That is the split the draft
  described, and it exists here.
- `.github/workflows/gc-nightly.yml` exists.
- `pycore/rtl/pycore_core.sv` is 4,935 lines. `mpycore/` does not exist.
- The import commit on this branch is `2614379`, snapshot `43d791a`.

The draft's phase 0 exit, "`make` of the CPython hart is untouched", is a
real command in this tree. It is the wrong exit for a retarget: phase 0
must not edit RTL, and later phases edit it on purpose. The merged plan
says that.

### F10 — Non-goals

| Proposed non-goal | Verdict |
| --- | --- |
| Filesystem and `open` | Already the pivot plan §6 item 5 |
| Threads | Already the draft and the pivot plan |
| Native, viper, inline asm | Already the pivot plan §1.1. The image tool rejects a non-none architecture as well |
| Finalisers | Already the pivot plan §1.2. The oracle variant now says it |
| `id()` in expected output | Accepted. The builtin may exist. No test prints it |
| Weakrefs | Accepted as off in v1. Not verified against a specific test that would need them |
| REPL, `input`, `sys.stdin` | Rejected as a non-goal. D5 and the pivot plan §6 item 3 require a UART REPL. Unix stdin stays absent |

### F11 — Docs

Accepted, and moved. The reviews invented `mpycore/docs/`. The pages in
the merged plan are `pycore/docs/mpy_*.md`, so they do not overwrite the
CPython pages.

### F12 — Audit nits

- `371dc007` is pycore's merge of PR #155 on 2026-10-11. `43d791a` is
  three commits later (2026-10-13) and contains it. Confirmed with the
  pycore GitHub API. This tree matches the later snapshot's line counts.
- "These four" versus six registers: confirmed in `base_plan.md`.
- The draft prelude sentence (state, exception stack, flags, then bytes)
  does not match `py/bc.h`. Confirmed.
- `pycore/docs/container_accel.md` line 10: data ready and container ready
  are the same cycle, and the core stays frozen. Confirmed in this tree.
  A's note that porting `pycore_ca.sv` would bring 132-bit entries is
  consistent with `PYCORE_ENTRY_WIDTH` in `pycore/rtl/pycore_defs.svh`
  lines 4–6. The disposition is to keep the FSM and the rule, which is
  the pivot plan, not to copy the file into a new core.

Opcode catalog: `pycore/targets/pycore.json` has 95 opcodes, 70 execute,
8 partial, 13 trap, 3 reject, 1 strip. The draft's audit table is right
about that and wrong about the line counts.

`py/bc0.h` has 72 single-opcode macros from `MP_BC_LOAD_CONST_FALSE`
through `MP_BC_IMPORT_STAR`, plus the five `*_MULTI` ranges. The pivot
plan's "72 plus 5" matches this tag. `MP_BINARY_OP_NUM_BYTECODE` is
`MP_BINARY_OP_POWER + 1`, and `POWER` is the 35th enumerator in
`py/runtime0.h` (index 34). A's "35 binary ops" is the bytecode group.
The plan does not copy that number; phase 0's JSON does.

### F13 — Do not patch bytecode

Confirmed by the version-6 header comment in `py/persistentcode.h` lines
40–44 and by `DECODE` using the module tables (B's citation of
`py/vm.c` matches the file's qstr and obj tables). The merged plan picks
the side table: operands stay as the emitter wrote them, the static pool
is embedded, and the image tool materializes the tables. Patching bytecode
to global qstr ids is the rejected alternative.

### F14 — Dict order

Rejected for A and for C. Confirmed for B and for the pivot plan.

- `py/map.c` lines 89–100: `mp_map_init` clears `is_ordered`.
- `py/objdict.c` lines 114–121: a normal `dict` stays unordered.
  `is_ordered` is set for `OrderedDict` when that type exists.
- `py/objdict.c` `dict_print` walks slots. Print order is slot order.
- `py/map.c` lines 64–73: the growth table begins
  0, 2, 4, 6, 8, 10, 12, 17, 23, 29, 37. The pivot plan §1.3 quotes it.
- `py/qstr.c` lines 65–68: djb2, `hash * 33 ^ byte`.
  `py/mpconfig.h` lines 373–375: two hash bytes at extra features.

A's "dict order is insertion order and is observable with any layout" is
false for a normal dict. C's "preserves insertion order" is the same
mistake. Sets use the same probe sequence. Phase 3 copies the map and
checks a host model before RTL.

### F15 — Cross compiler

Confirmed. `mpy-cross/main.c` line 317 defaults `small_int_bits` to 31.
`mpy-cross/mpconfigport.h` lines 71 and 77 select MPZ and double.
Folding is on (F03). An overflow test written as `1 << 40` becomes a
const. The merged plan requires runtime operands and records the folded
`print(1 + 2)` so nobody uses it as the ALU test.

### F16 — Sub-version

Confirmed. `py/persistentcode.c` lines 472–476 reject a sub-version
mismatch only when `arch != MP_NATIVE_ARCH_NONE`. The header comment at
`py/persistentcode.h` lines 33–36 says the same thing. A wrong major
version or a small-int width greater than the runtime's is
`ValueError: incompatible .mpy file` (line 476). The pivot plan's
negative test should say major version. Phase 1 now does.

### F17 — Bool

See F05. No plan change beyond "phase 0 records the immediate ids from
the pin" and "bool arithmetic matches the oracle".

### F18 — Unicode strings

`py/mpconfig.h` lines 1369–1370 turn
`MICROPY_PY_BUILTINS_STR_UNICODE` on at basic features and above, so the
extra-features oracle has it on. `py/objstr.c` includes `py/unicode.h` and
has a code-point path (for example line 1075, `utf8_charlen`). This review
did not re-derive the indexer. The merged plan leaves the flag on and
compares string tests to the oracle. Turning the flag off to avoid the
RTL, which C offered, would make the oracle a different language from
ESP32 and RP2 at extra features. Case conversion above ASCII stays the
pivot plan's "confirm on the oracle first" item. That confirmation has
not been run here.

### F19 — Sim-control address

The address is the draft's and the pivot plan's. It is in the Cortex-M
system region by the usual ARM map. Nothing in this tree uses it as a
system-control block. The merged plan keeps the address and says the
window is simulation-only. No experiment is required unless a later bus
also contains a Cortex-M.

### F20 — Fetch buffer

The draft leaves a fetch buffer out of v1. The pivot plan §1.0 already
puts an 8-byte buffer on the fetch path so flash wait states are absorbed.
That buffer stands. C's constraint stands with it: the buffer holds
instruction bytes only, it does not cache MMIO, and a data load from flash
is not an instruction prefetch. Phase 2's bus decoder is what fetches
opcodes and what loads qstr bytes from the same flash.

### F21 — Trace

Accepted as a simulator mode in the phase 2 exit. Acceptance remains the
stdout diff. The pivot plan §6 item 11 already points at `cosim_trace.py`
and `mpy-tool.py`.

### F22 — Recursion

`py/runtime.c` lines 1784–1787: `mp_raise_recursion_depth` raises
`RuntimeError` with the qstr for "maximum recursion depth exceeded", and
only when `MICROPY_STACK_CHECK` is on. Callers include `py/vm.c` line 972
and `py/stackctrl.c` line 65. A search of `py/objfun.c` for that message
found nothing. B's statement of the observable error is right; the file
citation is not. The pivot plan §1.3 row 10 already matches the message.
The merged plan repeats it so a failed frame allocation is not reported
as `MemoryError`.

### F26 and F27 — Phase 5 oracle

The unix port will not finish `while True`, and it has no view of this
`GPIO_OUT`. The pivot plan §5.7 already compares edges to a host model
and names blink, echo, and `sched_full`. It does not say what happens
when the entry module returns after arming a timer. C is right that a
halt-on-return misses the first tick. Phase 5 now idles until the
testbench budget ends.

`machine` on the device is a native module (pivot plan §1.1). A frozen
`.mpy` does not implement the registers. The unix `machine` module is a
different peripheral model. Phase 5's edge oracle is the host model.

## Conflicts

### Separate tree versus retarget

A, B, and C all kept a new `mpycore/` core and wrote phase 0 as "do not
touch the CPython hart". The pivot plan D1 and §9 retarget this tree.
This tree contains the hart (F09). The merged plan follows D1. The
reviewers' phase text is still useful once paths are rewritten: the image
format, the oracle variant, and the exit programs do not depend on
throwing away `pycore/rtl`.

### Integer and float model

The draft and all three reviews: 31-bit small int, long int off, float
off, overflow is `OverflowError` at 31 bits. The pivot plan D3: 64-bit
`LONGLONG`, binary32, complex kept, MPZ later.

D3 stands. The ALU is 64 bits today (`PYCORE_VAL_WIDTH` is 128, and the
integer path is the existing one the pivot plan measured). ESP32 and RP2
use binary32 (`ports/esp32/mpconfigport.h` line 69,
`ports/rp2/mpconfigport.h` lines 128–129) and MPZ
(`ports/esp32/mpconfigport.h` line 65,
`ports/rp2/mpconfigport.h` line 127), not `LONGLONG`. The pivot plan D3
already says MPZ is the board default and is post-deadline. The §9 cell
that said the integer choice "matches ESP32/RP2" does not. That cell is
corrected. `py/objint_longlong.c` line 48 is the overflow text
`result overflows long long storage`. `py/objint.c` line 341 is
`small int overflow`, which applies when long ints are off. v1 matches
the long-long text.

True division with float on returns a float. The reviewers' "`/` is
`TypeError`" is true only for their rejected config.

### Object word

The reviews copy `REPR_A` into v1. D2 keeps the 32-byte slot, then an
8-byte slot, and leaves the 4-byte word until after the deadline. D2
stands, because the container FSMs and the GC tracer key off the current
slot. F05's encoding facts are recorded for the oracle and for that later
step. They are not a v1 RTL encoding.

### GC strategy

B: stall inside the opcode and retry the allocation. A and C: restart the
opcode, with C requiring that a partial object is not published. The hart:
abort before the first architectural commit, then re-dispatch
(`pycore/docs/gc.md`).

The hart's rule stands. It is the stricter form of C's constraint and it
is already tested. B's description of `py/gc.c` is why a straight port of
list growth would violate it. The merged plan says the FSM fails before
commit.

Exact `MemoryError` parity at one heap size does not stand. See F06.

### Dict order

A and C: insertion order. B and the pivot plan: hash order. Hash order
stands (F14).

### IRQ model

| Question | A | B | C | Resolution |
| --- | --- | --- | --- | --- |
| When does a soft callback run? | Next opcode boundary | Jump opcodes | Jump opcodes, or every opcode if documented | Jump opcodes, matching `py/vm.c` |
| May the callback allocate? | Yes, and the draft's ban is dropped | Yes | Yes for the queued callback | Soft yes. Hard no (`mpirq.c` locks the GC) |
| Queue depth | Pin default, stated as 4 | 4, power of two | 4 at extra features | 8, the ESP32/RP2/STM32 value. The default 4 is why the variant must set it |
| Who is the IRQ oracle? | — | Not the unix `machine` module | Not the unix port for interleaving | Host register model for edges. Unix variant for `schedule` overflow and for `print` |

### UART overrun and timer tick

The evidence does not decide these. The tag has no register named
`UART_RX` at `0x4000_0004`. A said to pick overwrite or drop. C picked
drop-newest, pop-on-read, and a testbench-advanced timer so the blink
trace does not move when ALU latency changes. B listed the missing
sentences and did not pick a policy.

The merged plan locks, as product choices rather than MicroPython facts:

- Pop on read. One-byte buffer. A second byte is dropped and bit 30 sticks.
- The phase 5 timer advances when the testbench says so. Compare 0
  disables the timer. Match reloads the counter to 0 and sets the IRQ bit.

The cheapest experiment is a host model of the register file, no RTL, and
two scripts: one pushes two bytes before a read, and one runs the blink
callback at two different fake ALU latencies. If the edge counts differ
across latencies, the testbench tick is what keeps the test stable. If a
later cycle-accurate mode is needed, it is a plusarg, not the phase 5
gate. Changing the overrun policy is a one-line edit to
`pycore/docs/mpy_peripherals.md` before the RTL exists.

### Phase order

The reviews kept the draft's serial phases and put float, long ints, and
the compiler in phase 6. The pivot plan runs tracks in parallel and puts
float and `LONGLONG` in the main line. The merged plan keeps the phase
headings and maps them onto the pivot weeks (the table at the top of
`merged_plan.md`). Float is phase 4. The 64-bit int is the phase 2 ALU.
Phase 6 is the compiler and the REPL.

### v1 scope of `import *`, relative import, and `*args`

C named them as non-goals. The pivot plan's opcode map includes
`IMPORT_STAR` and the var-keyword calls. The first import exit in the
pivot plan, at the time of the review, was two modules, `from` import,
and `import as`. It did not show `import *`.

The review's resolution was to keep those three out of the v1 exit tests.
The owner reversed that on 2026-10-14. Phase 4 now runs them, and the
image tool accepts the bytecode. `*args` is a tuple of surplus
positionals, including the empty tuple (`py/bc.c`). `import *` is
`mp_import_all` (`py/runtime.c`). The standard library is still not
rewritten this month.

## Reconciliation with the pivot plan

The merged plan follows the pivot plan on D1 through D7, the week
schedule, the peripheral base addresses, the hard/soft split, hash-order
dicts, and the compiler track. Edits applied to the pivot plan so the two
files agree:

| Pivot location | What was wrong or missing | Edit |
| --- | --- | --- |
| §1.0 | Prelude fields named, encoding and opcode-start offset not | Paragraph added. No bit masks copied |
| §1.0 exit and §7 week 1 | `print(1 + 2)` can be a folded const | The ALU exit is a `while` on locals |
| §1.1 `MemoryError` row | "Same heap size" pins an allocation index the slot size cannot match | Coarse tests and a preallocated emergency object |
| §2.1 | "Do not freeze `py/compile.c`" was only implied | Sentence added |
| §3.1 | "512 `.py` programs" | 523 files, 512 at the top level |
| §3.2 | Variant missed depth 8, finalisers off, emergency buffer, stderr, folding | Bullets added |
| §5.2–§5.3 | Register semantics, auto-clear on delivery, soft-callback exceptions | Paragraphs added |
| §5.5 | Roots missed frame slots, builtins, `sys.modules` | Sentence added |
| §6 item 2 | No pointer at the merged phase contract | Sentence added |
| §6 item 6 | Moving the 256 KB spill into 256 KB SRAM leaves no pool; flash address 0 aliases the null word | Split and the 8-byte reservation |
| §9 | "Matches ESP32/RP2" for the integer model | Boards use MPZ; `LONGLONG` matches the ALU |

Remaining differences, and why they are not contradictions:

- The pivot plan is organized as tracks and weeks. The merged plan is
  organized as the draft's phases. The mapping table in the merged plan
  is the join. A week may run several phases' host work; the gate for
  that week is the table.
- The pivot plan §4 still owns benchmarks, boards, and the paper. The
  merged plan does not restate them.
- The pivot plan §5.5 idle-time GC and the `GC_REQ` interrupt stay pivot
  text. The merged plan's phase 3 uses the abort rule and
  `gc.threshold` behavior the pivot plan already equates to `GC_REQ`.
  Phase 5 names `machine.idle`. It does not reopen the idle-GC design.
- The merged plan locks UART overrun and the testbench timer tick. The
  pivot plan now states the same rules in §5.2. They are marked as
  product choices.
- `import *`, relative import, and `*args` were catalogued as `reject`
  at the end of the review. The owner decision above puts them in phase 4
  on both plans. The standard library stays unrewritten, and import still
  uses the frozen table rather than a filesystem.

## Gaps found in this tree

These were not in A, B, or C.

**F23. ESP32 and RP2 use MPZ.** Citations in the integer-model conflict
above. D3 already defers MPZ. Only the §9 wording overclaimed.

**F24. The spill is the whole SRAM budget.** `pycore/docs/architecture.md`
lines 459–462 and `pycore/docs/memory_hierarchy.md`. The pivot plan §6
item 6 said to move that region into the 256 KB SRAM. Phase 0 now
measures and shrinks it.

**F25. Program count.** 512 `.py` files sit directly in `pycore/programs/`.
Nine more are in `compile_suite/` and two in `type_pairs/`. The pivot
plan's 512 is the top-level count. Hardware tests are 597 across the 14
area tables, matching the pivot plan, once the `gate.*` tables are
excluded.

## What this review did not verify

- No simulator was run. `make test-calls` is the phase 0 measurement and
  was not executed here.
- Unicode indexing beyond the feature flag and the presence of
  `utf8_charlen` in `py/objstr.c`.
- The exact site that turns a failed frame allocation into
  `mp_raise_recursion_depth`, other than the callers listed under F22.
- Whether `MICROPY_STACK_CHECK` is on in the unix variant this plan will
  build. The recursion message exists only inside that ifdef
  (`py/runtime.c` lines 1784–1788). Phase 0's variant has to turn the
  check on or the phase 4 recursion test has nothing to match.
- Board numbers, Fmax, and flash-wait behavior on real pins.
- That `43d791a`'s tree bytes equal this import, beyond the line counts
  and the facts cited above. The import commit says it is that snapshot.
- MicroPython `master` after v1.29.0. A cited `master`. B and C cited
  v1.29.0. This review used v1.29.0, which is the pin. A claim that is
  true only on later `master` is not a v1 lock.

## Open questions for the owner

1. The pivot plan §0.4 questions are still open: what the deadline's
   "publish" means, how many people work in parallel, whether the boards
   get bought, and whether the REPL is required or is the cut-list item.
2. MPZ versus `LONGLONG` for the first public benchmark. D3 keeps
   `LONGLONG` because the ALU already does it and because `bm_pidigits` is
   the program that needs MPZ. ESP32 and RP2 will not match integer
   overflow or very large ints until MPZ lands. Say if that comparison has
   to be exact before the deadline.
3. The SRAM split is a measurement (`make test-calls`), not a number in
   this review. If the high-water mark plus a heap that runs `pystone` at
   M=100 does not fit in 256 KB, D2's stage B has to move earlier than
   week 2. That is the experiment.
4. UART overrun (drop newest, sticky bit 30) and the testbench timer tick
   are choices. The host-model experiment in the conflict section is the
   time to change them, before RTL.
5. Answered 2026-10-14. `import *`, relative import, and `*args` /
   `**kwargs` are in phase 4. The standard library is not rewritten this
   month, and there is still no filesystem. Say if import must also open
   a `.mpy` from storage before the month ends.
6. Idle-time GC and `GC_REQ` stay in the pivot plan and are not re-specified
   here. They are cut-list item 3. No change unless you want them in the
   phase 5 gate.
7. `MICROPY_STACK_CHECK` is on in the oracle variant so the phase 4
   recursion message has a unix counterpart (`py/runtime.c` raises it only
   inside that check). Say if you want that check off and the hart-only
   limit instead.
