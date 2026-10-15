# Fix `len()` on a non-ASCII str

You are fixing one uPyCore bug. Work from `cursor/hw-fix-base-854d` on a new branch. Do not commit on the base branch.

## Done when

`python3 upycore/tools/hw_tests.py unicode` prints `PASS`, and the `xfail` marker is gone from the `unicode` entry in `upycore/programs/hw_tests.toml`. Remove the marker in the same change. An `XPASS` fails the suite.

Then run `python3 upycore/tools/hw_tests.py --area strings`. `text`, `bytesobj`, and `format` must still pass.

## The test

`upycore/programs/hw/strings/unicode.py` is one line:

```python
print("héllo", len("héllo"), "héllo"[1], "héllo".upper())
```

The golden `upycore/programs/hw/strings/unicode.stdout` is:

```
héllo 5 é HéLLO
```

`é` is U+00E9, two UTF-8 bytes. The character length is 5, not 6. Index 1 is the character `é`, not the continuation byte. `upper()` is `HéLLO`.

The device dies on `len()` before the rest of the line runs:

```
TypeError: object of type 'str' has no len()
```

That text is the `raise` at the bottom of `_len_fb` in `upycore/firmware/seqs.py`. Stdout is empty and the exit status is 1. The golden exit status is 0. Do not edit the program or the golden.

## Cause

ASCII `len` stays in the core. Non-ASCII does not.

In `upycore/rtl/mpy_core.sv`, native `ABI_N_LEN` reads the string info and then:

```systemverilog
S_N_LEN_S: if (si_na && tg(si_v) != ABI_TAG_BYTES && nid == ABI_N_LEN) st <= S_NAT_FB;
           else deliver(vint(si_len), crk);
```

`si_na` is the non-ASCII flag. `S_NAT_FB` calls firmware `_len_fb`. `_len_fb` handles `range`, bytearray, and a few objects. It has no arm for `TAG_STR` or `TAG_QSTR`, so it raises "has no len()".

`si_len` is the byte length (`_slen` in `upycore/tools/mpy_abi.py`). Returning `si_len` for this string would print 6, and the golden would still fail.

## What to implement

`len` of a non-ASCII str is the number of Unicode code points. `_utf8_at` in `upycore/firmware/fmt.py` already decodes one code point and returns how many bytes it consumed. The non-ASCII string iterator in `upycore/firmware/iters.py` (`iterator____next__`) walks the same way.

The index and `upper()` on that same line must also match. If `len` is fixed and the next call still fails, fix that too. This task owns the whole `unicode` program, not only `len`.

ASCII strings must keep the fast core path. `text` prints `len("Hello")` and must stay `5`.

## Rules

- Do not edit the golden.
- Build `mpy-cross` with `variants/upycore/build.sh mpy-cross` if the binary is missing.
