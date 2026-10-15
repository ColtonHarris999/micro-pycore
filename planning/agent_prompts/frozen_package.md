# Fix a frozen package so its body binds globals

You are fixing one uPyCore bug. Work from `cursor/hw-fix-base-854d` on a new branch. Do not commit on the base branch.

## Done when

`python3 upycore/tools/hw_tests.py use_pkg` prints `PASS`, and the `xfail` marker is gone from the `use_pkg` entry in `upycore/programs/hw_tests.toml`. Remove only the `xfail` field. Leave `oracle = false`. An `XPASS` fails the suite.

Then run `python3 upycore/tools/hw_tests.py --area modules`. `import_missing` and `use_helper` must still pass.

## The test

`upycore/programs/hw/modules/use_pkg.py`:

```python
import pkg
import pkg.sub
from pkg.sub import VALUE

print(pkg.TAG, pkg.sub.VALUE, VALUE)
```

The package body `upycore/programs/hw/modules/pkg/__init__.py` is `TAG = "pkg"`. The submodule `upycore/programs/hw/modules/pkg/sub.py` is `VALUE = 4`.

The golden is hand-written, not from the unix oracle:

```
pkg 4 4
```

`use_pkg.stderr` is empty and `use_pkg.exit` is `0`. The unix port in this tree has no filesystem importer (`MICROPY_VFS_POSIX` is off), so `make regen-goldens` skips this test. Do not regenerate it. Do not point it at the oracle.

The device reaches the print and then fails:

```
AttributeError: 'module' object has no attribute 'TAG'
```

`import pkg` does not raise. The module object exists. `TAG` is not on it. `from pkg.sub import VALUE` ran far enough to get to that print, so the submodule import itself is not the first failure. Do not edit the test or the golden.

## What is already known

`use_helper` passes. That frozen module is not a package. Its body stores an int and two functions (`VALUE = 7`, `def add`, `def mul`), and `helper.VALUE` works.

`mpy-cross -msmall-int-bits=31 -O0` compiles the package body to:

```
LOAD_CONST_STRING  pkg
STORE_NAME         TAG
LOAD_CONST_NONE
RETURN_VALUE
```

The qstr table is `pkg/__init__.py`, `<module>`, `pkg`, `TAG`. The string const index is `pkg`. The name index is `TAG`.

The linker sets `MD_FLAG_PACKAGE` in `upycore/tools/mpy_link.py` (`place_module`). Nothing in `upycore/rtl` reads that flag. The import path is `_import` in `upycore/firmware/modules.py`: it builds a module, stores it in `sys.modules`, and `_callns` runs the body in that module's globals dict. The same path is used for `helper`.

Two differences are still open. Isolate them before rewriting import.

1. Package versus plain module. The flag is stored and unused. `__init__.py` is still the module body.
2. `STORE_NAME` of a string const versus `STORE_NAME` of a small int. `helper` never stores a string global. `sub.py` stores an int, and `from pkg.sub import VALUE` got far enough to suggest that store worked.

`STORE_NAME` is opcode 22 (`0x16`) in `upycore/targets/upycore.json`. In `upycore/rtl/mpy_core.sv` that opcode and `STORE_GLOBAL` (`0x17`) share state `S_SN_R`. A module body has no locals, so the store goes to the globals dict. Confirm the body actually runs `LOAD_CONST_STRING` and `STORE_NAME`, and that the key written into the module dict is the qstr `TAG`.

## Rules

- Keep `oracle = false` on `use_pkg`.
- Do not edit `use_pkg.stdout`, `use_pkg.stderr`, or `use_pkg.exit`.
- A temporary experiment is fine while you isolate the bug. Do not leave it in the tree unless it is a real test with a golden.
- Build `mpy-cross` with `variants/upycore/build.sh mpy-cross` if the binary is missing.
