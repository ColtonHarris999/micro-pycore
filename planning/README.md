# Planning

Plans for work that is **not done yet**. The machine as built is documented
under `pycore/docs/`, `excore/docs/`, and `pycore_firmware/builtins/`.

| File | Role |
| --- | --- |
| [`micropython_pivot_plan.md`](micropython_pivot_plan.md) | **The plan of record for micro-pycore:** restructuring this tree from a CPython 3.14 hart into a MicroPython microcontroller core. Read it first. Product decisions D1–D7 and the week schedule live here |
| [`mpy_review/merged_plan.md`](mpy_review/merged_plan.md) | The phase contract. It folds three reviews of the original draft into that draft's section structure, and it follows the pivot plan where the two differ. Implement phases from this file. The value encoding is a 32-bit payload plus a 4-bit tag (pivot plan §0.5). If a phase gate and a pivot week disagree, the pivot decision stands and the merged plan's week-to-phase table is the join |
| [`mpy_review/final_review_report.md`](mpy_review/final_review_report.md) | Inventory, verdicts, and conflict resolutions for those three reviews. The plans `plan_A`, `plan_B`, `plan_C`, and `base_plan` in that directory are the inputs and stay as record |
| [`micropython_mcu_plan.md`](micropython_mcu_plan.md) | The earlier MicroPython draft, merged in [PR #1](https://github.com/ColtonHarris999/micro-pycore/pull/1). It assumed a new core in a separate tree; this tree now retargets pycore instead. Kept for reference. Do not implement from it. Where it disagrees with the pivot plan, the pivot plan governs (pivot plan §9) |
| [`master_plan.md`](master_plan.md) | Inherited from pycore: the CPython-hart roadmap. Superseded by the pivot plan; take an item from it only if the pivot plan keeps that item |
| [`cleanup_report.md`](cleanup_report.md) | Simplification and dead-code backlog, written as independent work items for agents |
| [`accelerator_split_plan.md`](accelerator_split_plan.md) | Container accelerator, console `print`, `bytes`, startup accelerator config and excore fallbacks, and the excore as emulator (track 5 of the master plan) |
| [`cpython_baseline_bytecode.md`](cpython_baseline_bytecode.md) | Opcode inventory of the measured CPython baseline suite. No new hart opcode is required |
| [`old/`](old/) | Archived designs and plans. Code comments cite them by section (`compiler_design.md §6.1`), so they stay in the repo |

## Graduated

| File | As-built doc | Why it is still here |
| --- | --- | --- |
| [`gc_plan.md`](gc_plan.md), [`gc_progress.md`](gc_progress.md) | [`pycore/docs/gc.md`](../pycore/docs/gc.md) | `tools/gc_acceptance.py` and the task hook read them at this path; move both to `old/` once nothing reads them |

## Rules

- When a plan lands, move it to `old/`, add an `Archived` note at the top
  that points to the as-built doc, and copy anything still open into
  `master_plan.md`. Do not keep a "graduated" plan at the top level,
  except as listed under Graduated below.
- Do not duplicate opcode, type, or builtin tables here. Link to
  `pycore/docs/bytecode_support.md`, `pycore/docs/exception_support.md`,
  `pycore/targets/pycore.json`, and `pycore_firmware/builtins/builtins.md`.
- When you finish a `cleanup_report.md` item, delete its entry in the same
  PR. The report should only ever list open work.

GitHub CI skips the hardware suite when a PR or push only touches markdown,
`planning/`, licenses, or similar non-build paths (including `pycore/docs/`
and `excore/docs/`). If you also touch RTL, programs, tools, the `Makefile`,
Docker, or workflow files, the split jobs run as usual.
