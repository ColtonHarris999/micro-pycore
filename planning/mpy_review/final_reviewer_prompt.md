# Final reviewer prompt: merge three plan reviews into one

Copy everything below the line into a fresh agent on branch `mpy_translation`.

---

You are the final reviewer for the MicroPython translation plan of this repository (micro-pycore, a retarget of the pycore CPython 3.14 bytecode CPU to MicroPython on a microcontroller-style core). Three independent reviewers each reviewed the same draft plan and appended findings. Your job is to assess their work critically and produce one merged plan.

## Inputs (all under `planning/mpy_review/`)

| Label | File | Meaning |
| --- | --- | --- |
| Base | `base_plan.md` | The draft all three reviewers started from (`planning/micropython_mcu_plan.md` on `main`) |
| Plan A | `plan_A.md`, `plan_A.diff` | Reviewer A's full revised plan, and its diff against the base |
| Plan B | `plan_B.md`, `plan_B.diff` | Reviewer B's full revised plan, and its diff against the base |
| Plan C | `plan_C.md`, `plan_C.diff` | Reviewer C's full revised plan, and its diff against the base |

Read the `.diff` files first to see what each reviewer changed, then the full plans for context.

## Critical context the reviewers did not have

The reviewers worked on a stale checkout containing only three files. They never saw the real tree (about 1100 files). This branch has it. Concretely:

1. `planning/micropython_pivot_plan.md` is now the plan of record. `planning/README.md` states that the pivot plan governs wherever it disagrees with `micropython_mcu_plan.md`. The base draft assumes a new core in a separate `mpycore/` tree. The pivot plan retargets this tree in place. Reconcile every reviewer finding against the pivot plan.
2. The reviewers' claims about the code (RTL, firmware, tests, Makefile targets, docs, file paths, line numbers, sizes) were made without access to it, or by reading the pycore repository remotely. Treat each as unverified. Check it against the files in this tree before you accept it.
3. Other planning files exist that the reviewers did not see: `master_plan.md`, `cleanup_report.md`, `accelerator_split_plan.md`, `gc_plan.md`, `cpython_baseline_bytecode.md`, and `planning/old/`.

## Your tasks

1. **Inventory.** Build a table of every distinct finding across A, B and C. For each, record which reviewers raised it (A, B, C), the plan phase or section it touches, and its severity (blocker, significant, minor).
2. **Assess each finding.** Mark it one of: confirmed (you verified it against this tree or the MicroPython sources), rejected (wrong or already addressed, with the reason), or unverifiable (needs hardware, a pinned MicroPython checkout, or outside data). Cite the file and line you checked. Do not decide by majority vote. A finding raised by one reviewer can be right and one raised by all three can be wrong.
3. **Resolve conflicts.** Where reviewers disagree (for example on opcode set, memory map, GC strategy, interrupt model, scope of v1, phase order or exit tests), pick one answer and give the reason. If the evidence does not decide it, say so and list the cheapest experiment that would.
4. **Reconcile with the pivot plan.** List each place where the merged plan and `micropython_pivot_plan.md` differ. Prefer the pivot plan's structure. Propose edits to the pivot plan for any confirmed finding it lacks, and do not leave the two plans contradicting each other.
5. **Produce the merged plan.** Write it to `planning/mpy_review/merged_plan.md`:
   - Keep one coherent document in the base plan's section structure. Do not append three review sections.
   - Fold confirmed findings into the phase text, locks, risks and test contract they belong to. Remove the "Review findings" appendix pattern. Keep a short changelog table that maps each folded finding to its origin (A, B, C).
   - Every phase must have an objective exit test that a command can run, with the expected result.
   - Keep the doc's rule against copying MicroPython opcode lists or bit masks into prose. They come from the pinned release.
6. **Report.** Write `planning/mpy_review/final_review_report.md` with the inventory, verdicts, conflict resolutions, pivot-plan differences, and a list of open questions for the human owner.
7. **Land it.** Update `planning/README.md` so it lists the merged plan and says how it relates to the pivot plan. Do not delete `plan_A/B/C` or `base_plan`. Commit in logical steps and push to the current branch.

## Rules

- Do not modify RTL, firmware or tests. This is a planning task.
- Do not invent facts about MicroPython internals. Where you need one, say which file in the pinned release (`py/bc.h`, `py/obj.h`, `py/persistentcode.h`, and so on) would settle it.
- Be specific. A finding without a file, a phase, or a testable claim is not done.
- State plainly anything you could not verify, rather than smoothing it over.
