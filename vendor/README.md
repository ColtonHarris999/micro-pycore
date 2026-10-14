# Vendored third-party sources

| Path | Upstream | Role |
| --- | --- | --- |
| `pycpython/` | [ColtonHarris999/PyCPython](https://github.com/ColtonHarris999/PyCPython) (branch `claude/cpython-3-14-compile-frontend-4o4fcz`) | CPython 3.14.7 `compile()` pipeline reimplemented in pure Python. Host-side oracle and algorithm source for the on-device compiler. **Not executed on the hart as-is.** |
| `micropython/` | [micropython/micropython](https://github.com/micropython/micropython) v1.29.0 (`0fd6c573`) | Pinned bytecode, `mpy-cross`, and `tools/mpy-tool.py`. The flash-image tool reads this tree; the RTL does not. |

Pin and provenance: [`pycore_firmware/THIRD_PARTY.md`](../pycore_firmware/THIRD_PARTY.md).
The on-device compiler built from it: [`pycore/docs/compiler.md`](../pycore/docs/compiler.md).

Clone with submodules:

```bash
git clone --recurse-submodules <this-repo>
# or, after a plain clone:
git submodule update --init --recursive
```
