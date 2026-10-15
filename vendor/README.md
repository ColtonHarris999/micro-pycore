# Vendored third-party sources

| Path | Upstream | Role |
| --- | --- | --- |
| `micropython/` | [micropython/micropython](https://github.com/micropython/micropython) tag **v1.29.0** (`0fd6c573`) | Pinned bytecode, `mpy-cross`, `tools/mpy-tool.py`, and the unix oracle. The flash-image tool reads this tree; the RTL does not. The variant lives in this repo at `variants/upycore`, not in the submodule. |

`make oracle-header` builds `mpy-cross` from that tag and prints `header: 4d 06 00 1f` for a bytecode-only compile (`-msmall-int-bits=31`, no `-march`, `-O0`). `make oracle` also builds the 32-bit unix variant and runs `variants/upycore/smoke.py`. `Dockerfile.oracle` builds both into one image. The submodule checkout is not patched; `variants/upycore/unix-port.patch` is applied to the build tree.

Licence: MicroPython is MIT. This tree vendors it unmodified.

Clone with the pin:

```bash
git clone --recurse-submodules <this-repo>
# or, after a plain clone:
git submodule update --init --recursive
```
