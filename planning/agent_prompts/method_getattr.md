# Fix `getattr` and `hasattr` for list methods

You are fixing one uPyCore bug. Work from `cursor/hw-fix-base-854d` on a new branch. Do not commit on the base branch.

## Done when

`python3 upycore/tools/hw_tests.py method_getattr` prints `PASS`, and the `xfail` marker is gone from the `method_getattr` entry in `upycore/programs/hw_tests.toml`. Remove the marker in the same change. An `XPASS` fails the suite.

Then run `python3 upycore/tools/hw_tests.py --area builtins` and `python3 upycore/tools/hw_tests.py classes`. `classes` calls `getattr` on an instance and must still pass. `builtin_fns` must still pass.

## The test

`upycore/programs/hw/builtins/method_getattr.py`:

```python
a = [1]
print(hasattr(a, "append"))
try:
    print(getattr(a, "append")(2), a)
except Exception as exc:
    print(type(exc).__name__, exc)
```

The golden `upycore/programs/hw/builtins/method_getattr.stdout` is:

```
True
None [1, 2]
```

`hasattr` is true. `getattr(a, "append")` returns a bound method. Calling it with `2` returns `None` and the list is `[1, 2]`.

The device raises `AttributeError: 'list' object has no attribute 'append'`. A direct call `a.append(2)` already works. `upycore/programs/hw/containers/lists.py` covers that and must keep passing. Do not edit this program or its golden.

## Cause

`getattr` and `hasattr` in `upycore/firmware/builtins.py` call `_load_attr`. For a list, the tag is `TAG_MUT`, not `TAG_OBJECT`, so `_load_attr` falls through to `_getattr` in `upycore/firmware/attrs.py`. `_getattr` raises as soon as the tag is not `TAG_OBJECT`. It never looks up `append` on the list type.

A method call does not use that function. `LOAD_METHOD` / `LOAD_ATTR` in `upycore/rtl/mpy_core.sv` enter `S_AT`. For a non-object, `S_AT` takes the type (`S_AT_NT`) and walks the MRO (`S_AT_MRO` through `S_AT_VK`). A function found there is a method (`at_kind == 2`) and is bound.

`_load_attr` already does the instance and module cases. The missing case is a native container: list, and the same shape for tuple, str, bytes, dict, and set. Look up the type the way `S_AT_NT` does, find the attribute, and bind a function with `_desc_get` so the result is callable as `method(2)`.

`hasattr` only catches `AttributeError`. After the lookup works it returns `True` without a separate change.

## Rules

- Do not edit the golden.
- Do not special-case the string `"append"`. The lookup has to work for list methods in general.
- Build `mpy-cross` with `variants/upycore/build.sh mpy-cross` if the binary is missing.
