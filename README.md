# micro-pycore

A 32-bit CPU whose instruction set is a pinned MicroPython bytecode.
Data memory is tightly coupled SRAM. Peripherals are memory-mapped.
Programs boot as frozen `.mpy` modules.

The roadmap is [`planning/micropython_mcu_plan.md`](planning/micropython_mcu_plan.md).
It is the plan that was written on pycore branch
`cursor/micropython-mcu-plan-3b27`, moved here so the new core has its
own tree. Phase 0 has not started.

The CPython 3.14 research hart stays in
[pycore](https://github.com/ColtonHarris999/pycore). This repository is
the sibling core that plan calls `mpycore/`.
