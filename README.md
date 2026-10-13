# micro-pycore

A microcontroller-class CPU whose instruction set is MicroPython bytecode,
intended as an alternative to an ESP32, Pico, or STM32 board running
MicroPython. It is being built by retargeting the
[pycore](https://github.com/ColtonHarris999/pycore) CPython 3.14 bytecode CPU.

This repository does not contain pycore's code yet. The roadmap, including the
step that imports it, is
[`planning/micropython_pivot_plan.md`](planning/micropython_pivot_plan.md).
