# Fix float values so `floats` matches the oracle

You are fixing one uPyCore bug. Work from `cursor/hw-fix-base-854d` on a new branch. Do not commit on the base branch.

## Done when

`python3 upycore/tools/hw_tests.py floats` prints `PASS`, and the `xfail` marker is gone from the `floats` entry in `upycore/programs/hw_tests.toml`. An `XPASS` means the program matches the golden and the marker is still there. That fails the suite. Remove the marker in the same change.

Then run `python3 upycore/tools/hw_tests.py --area alu`. Every other alu test that is not `complex` must still pass. Leave the `complex` xfail alone.

## The test

`upycore/programs/hw/alu/floats.py` prints literals, runtime `+ - * /`, `float()` of digit strings, `int()` of those floats, comparisons, `abs`, and `round`. The golden is `upycore/programs/hw/alu/floats.stdout`:

```
1.5 -2.0 0.0
0.75 1.0 8.0 0.25
0.5 1.5
3.5 -0.25 3 -3
True True True
1.5 2 1.2
```

The device last printed:

```
1.048576 -1.0485862 0.0
0.2621542 0.5242982 4.1943142 0.1310822
0.2621542 0.5242982
1.0485862 -0.0655462 3 -3
True True True
1.048576 2 0.5242982
```

`int(3.9)` and `int(-3.9)` already match (`3` and `-3`). The three comparisons already match (`True True True`). `round(2.5)` already matches (`2`). The printed text of the float values does not. Do not edit the program or the golden to hide that.

## Where to look

- `upycore/firmware/floatfmt.py`: `_format_float` and `_float_repr`. `print` of a float goes through `_float_repr`.
- `upycore/tools/mpy_link.py`: `encode_const` stores a float literal as binary32 bits. A wrong const would also break `int(3.9)`, which currently matches, so check the printer before rewriting the linker.
- `upycore/rtl/mpy_core.sv` around `S_NUM_PUT` and `upycore/rtl/upycore_fpu.sv`: runtime `+ - * /`. The README says multiply and divide drop fraction bits on values that are not dyadic rationals. This test uses dyadic values (`0.5`, `0.25`, `1.5`, `2.0`, `4.0`) and they still print wrong. Prove whether the bits are wrong or only the decimal text is wrong before changing the FPU. `int()` and the comparisons are the evidence that many of the bits are already right.

## Rules

- The oracle is MicroPython v1.29.0, the `upycore` unix variant. Goldens were generated from it. Do not regenerate them unless you have rebuilt that oracle and the output is identical.
- Do not remove the `complex` xfail. That is a different task. If the shared printer is the bug, fix it here. Complex may start passing. Leave its marker in place.
- `floats` is slow on the current device (about 18 million cycles). Keep `cycles = 30_000_000` unless the fixed run needs more.
- Build `mpy-cross` with `variants/upycore/build.sh mpy-cross` if `build/oracle/src/mpy-cross/build/mpy-cross` is missing. The test runner verilates the simulator itself.
