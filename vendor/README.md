# Vendored third-party sources

| Path | Upstream | Role |
| --- | --- | --- |
| `pycpython/` | [ColtonHarris999/PyCPython](https://github.com/ColtonHarris999/PyCPython) (branch `claude/cpython-3-14-compile-frontend-4o4fcz`) | CPython 3.14.7 `compile()` pipeline reimplemented in pure Python. Host-side oracle and algorithm source for the on-device compiler. **Not executed on the hart as-is.** |
| `micropython/` | [micropython/micropython](https://github.com/micropython/micropython) tag **v1.29.0** (`0fd6c573`) | Pinned bytecode and unix oracle. The variant lives in this repo at `variants/mpycore`, not in the submodule. |

`make oracle-header` builds `mpy-cross` from that tag and prints `header: 4d 06 00 1f` for a bytecode-only compile (`-msmall-int-bits=31`, no `-march`, `-O0`). `make oracle` also builds the 32-bit unix variant and runs `variants/mpycore/smoke.py`. `Dockerfile.oracle` builds both into one image. The submodule checkout is not patched; `variants/mpycore/unix-port.patch` is applied to the build tree.

Pin and provenance: [`pycore_firmware/THIRD_PARTY.md`](../pycore_firmware/THIRD_PARTY.md).
The on-device compiler built from it: [`pycore/docs/compiler.md`](../pycore/docs/compiler.md).

Clone with submodules:

```bash
git clone --recurse-submodules <this-repo>
# or, after a plain clone:
git submodule update --init --recursive
```
