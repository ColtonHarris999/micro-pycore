# Fix set iteration order so `set_order` matches the oracle

You are fixing one uPyCore bug. Work from `cursor/hw-fix-base-854d` on a new branch. Do not commit on the base branch.

## Done when

`python3 upycore/tools/hw_tests.py set_order` prints `PASS`, and the `xfail` marker is gone from the `set_order` entry in `upycore/programs/hw_tests.toml`. Remove the marker in the same change. An `XPASS` fails the suite.

Then run `python3 upycore/tools/hw_tests.py --area containers`. `sets`, `dicts`, `lists`, `tuples`, and `unpack` must still pass. `sets` prints sorted elements, so it will not catch an order regression. `dicts` prints raw dict order and already matches the oracle. Do not change dict insertion to make sets match.

## The test

`upycore/programs/hw/containers/set_order.py` prints two sets. The golden is `upycore/programs/hw/containers/set_order.stdout`:

```
{3, 1, 2}
{2, 3, 4, 8}
```

The second line is `{1, 2, 3, 4} ^ {1, 8}`. The device last printed:

```
{1, 2, 3}
{4, 8, 2, 3}
```

The elements are right. The order is wrong. Do not sort the test or edit the golden.

## Where to look

Set displays are not built like dict displays.

- A dict literal is pre-sized. `S_BM_A` in `upycore/rtl/mpy_core.sv` allocates the map with `arg` slots. Those dicts already print in the oracle's order. `upycore/programs/hw/containers/dicts.py` is the lock. Leave that path alone.
- A set display is `S_BSET_R` in the same file. It calls firmware `_dictop(0, tuple, ...)`.
- `_dictop` in `upycore/firmware/dicts.py` does `_newset(0)` and then `_map_put` for each element. An empty set grows on the first inserts. That growth, the hash, and the probe are what the oracle's iteration order depends on.
- Iteration is `S_IT_DL` / `S_IT_DK` in `mpy_core.sv`. A set slot is one word (`it_i << 2`). A dict slot is a key and a value (`it_i << 3`). `_set_repr` in `upycore/firmware/fmt.py` walks `for k in s`, which uses that iterator.

The oracle is MicroPython v1.29.0. Match its set map: initial size, growth table, hash of a small int, and the order of a linear probe. The size table in `dicts.py` (`_SIZES`) is already the MicroPython table. The bug is more likely the empty-set growth or the `is_set=True` probe than the size list itself.

`upycore/programs/hw/containers/sets.py` checks the set algebra with `sorted()`. Keep it passing.

## Rules

- Do not edit the golden.
- Do not weaken `set_order.py` into a sorted comparison. The raw print is the test.
- Build `mpy-cross` with `variants/upycore/build.sh mpy-cross` if the binary is missing.
