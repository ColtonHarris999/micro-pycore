# uPyCore

uPyCore is a microcontroller-class CPU whose instruction set is MicroPython
bytecode. Programs are MicroPython source. Host `mpy-cross` compiles them to
`.mpy`, the linker packs firmware and the program into a flash image, and the
Verilator model of `mpy_soc` runs that image. There is no on-device compiler.

The unix oracle is MicroPython v1.29.0 built as the `upycore` variant
(`sys.platform` and `sys.implementation.name` are `upycore`).

## Run a program

Requires Python 3 and Verilator 5.032 or newer. `make test` builds `mpy-cross`
from `vendor/micropython` when the binary is missing.

```bash
make test
python3 upycore/tools/mpy_build.py run upycore/programs/hello.py
python3 upycore/tools/mpy_build.py oracle upycore/programs/hello.py
```

`run` prints the program's stdout and stderr and exits with the program's
status. `oracle` runs the same file on the unix port. Build that port with
`make oracle` (needs `i686-linux-gnu-gcc`).

## Layout

| Path | Role |
| --- | --- |
| `upycore/rtl` | Hart, datapath, memory, and collector |
| `upycore/firmware` | Device firmware, MicroPython source joined into one `.mpy` |
| `upycore/tools` | Image linker, ABI tables, and `mpy_build.py` |
| `upycore/programs` | Example programs |
| `upycore/targets/upycore.json` | Pinned bytecode catalog |
| `variants/upycore` | 32-bit unix oracle |
| `vendor/micropython` | MicroPython v1.29.0 pin |
| `planning/` | Design history for the move off the CPython hart |

Clone with the MicroPython pin:

```bash
git clone --recurse-submodules <this-repo>
```

`make test` covers a hello program and a raised `ValueError`.
