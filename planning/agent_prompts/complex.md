# Fix complex values so `complex` matches the oracle

You are fixing one uPyCore bug. Work from `cursor/hw-fix-base-854d` on a new branch. Do not commit on the base branch.

## Done when

`python3 upycore/tools/hw_tests.py complex` prints `PASS`, and the `xfail` marker is gone from the `complex` entry in `upycore/programs/hw_tests.toml`. An `XPASS` means the program matches and the marker is still there. Remove the marker in the same change.

Then run `python3 upycore/tools/hw_tests.py --area alu`. Leave the `floats` xfail in place unless that test also passes because of a complex-only fix. Do not delete the `floats` marker just to make the area look green.

## The test

`upycore/programs/hw/alu/complex.py` prints a complex literal, `complex(real, imag)`, `.real` and `.imag`, addition, and multiplication. The golden is `upycore/programs/hw/alu/complex.stdout`:

```
(1+2j)
(1.5-2j)
3.0 0.0
(4+6j)
(6+0j)
```

The device last printed:

```
(0.65536+1.31072j)
(1.31072-1.31072j)
1.0485862 0.0
(1.31072+2.62144j)
(2.62144+0j)
```

Do not edit the program or the golden.

## Where to look

- `upycore/firmware/floatfmt.py`: `_complex_repr` and `_cparts`. Real and imag are formatted with `_format_float(..., 'g', 6, ...)`. The same function prints ordinary floats, and that printer is also wrong (see `planning/agent_prompts/float.md`). `1.0485862` shows up both as `float("3.5")` and as the real part of `3+0j`.
- `upycore/firmware/attrs.py`: `_special_attr` for `TAG_COMPLEX` returns `.real` and `.imag`.
- `upycore/tools/mpy_link.py`: `encode_const` for `ComplexConst`. A literal `1+2j` is one const. Confirm the real and imag bits before assuming the arithmetic is wrong.
- `upycore/rtl/upycore_fpu.sv` and the complex arms in `upycore/rtl/mpy_core.sv`: addition and multiplication of two complex values.

Separate a bad decimal rendering from bad complex bits. `.real` of `3+0j` should be the float `3.0`. If that float's bits are correct and only `_format_float` is wrong, fix the printer. That file is shared with the float task. Change the printer if complex cannot match without it, and say so in the pull request. Do not revert a float-task change that landed on the same lines.

## Rules

- Do not edit `upycore/programs/hw/alu/complex.stdout`.
- Keep `cycles = 30_000_000`.
- Build `mpy-cross` with `variants/upycore/build.sh mpy-cross` if the binary is missing. The runner builds the simulator.
