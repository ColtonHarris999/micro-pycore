#!/usr/bin/env python3
"""Compare the vendored uPy2 compiler with mpy-cross on the hardware suite.

Each suite program and frozen module is compiled both ways. The ``.mpy``
bytes must match, except for the float-spelling difference recorded in
uPy2's ``DEVIATIONS.md`` (the two spellings parse as the same float and
nothing else in the file differs). A file ``mpy-cross`` rejects must be
rejected by ``mpyc`` too.

    python3 upycore/tools/compiler_suite.py
    python3 upycore/tools/compiler_suite.py --nstate
"""

from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "upycore" / "tools"))

import hw_tests  # noqa: E402
import mpy_build as build  # noqa: E402
from mpy_catalog import Catalog  # noqa: E402
from mpy_file import read_mpy  # noqa: E402
from mpy_prelude import decode_prelude  # noqa: E402


def _mpyc():
    build._ensure_mpyc()
    from mpyc import mpy_format as MPY
    from mpyc.compile import CompileError, compile_source
    from mpyc.parser import ParseError
    return MPY, compile_source, (CompileError, ParseError)


def _compile_both(path: Path, source_name: str) -> tuple[bytes | None, bytes | None, str]:
    """Return (mpy-cross bytes, mpyc bytes, note). A side is None when that compiler rejects."""

    MPY, compile_source, errors = _mpyc()
    cross_err = ""
    try:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "o.mpy"
            build.mpy_cross(path, out, source_name)
            ref = out.read_bytes()
    except build.BuildError as exc:
        ref = None
        cross_err = str(exc).strip().splitlines()[-1]
    try:
        mine = compile_source(path.read_text(encoding="utf-8"), source_name, "exec", 0)
    except errors as exc:
        mine = None
        if ref is None:
            return None, None, "rejected by both"
        return ref, None, f"mpyc rejected ({exc})"
    if ref is None:
        return None, mine, f"mpy-cross rejected ({cross_err})"
    if mine == ref:
        return ref, mine, "exact"
    if _float_spelling_only(MPY, mine, ref):
        return ref, mine, "float-spelling"
    return ref, mine, "differ"


def _float_spelling_only(MPY, mine: bytes, ref: bytes) -> bool:
    try:
        a = MPY.decode(mine)
        b = MPY.decode(ref)
    except Exception:
        return False
    if a.qstrs != b.qstrs or a.small_int_bits != b.small_int_bits or len(a.objs) != len(b.objs):
        return False
    if MPY.encode_raw_code_bytes(a.raw_code) != MPY.encode_raw_code_bytes(b.raw_code):
        return False
    differing = 0
    for x, y in zip(a.objs, b.objs):
        if x == y:
            continue
        if x.kind != MPY.OBJ_FLOAT or y.kind != MPY.OBJ_FLOAT:
            return False
        if float(x.payload) != float(y.payload):
            return False
        differing += 1
    return differing > 0


def suite_sources() -> list[tuple[str, Path]]:
    """Unique ``(source name, path)`` pairs the hardware suite compiles."""

    seen: dict[str, Path] = {}
    for t in hw_tests.load_manifest():
        seen.setdefault(t.source.name, t.source)
        for spec in t.modules:
            name, rel = spec.split("=", 1)
            rel = rel.removesuffix(":package")
            path = hw_tests.PROGRAMS / rel
            source_name = path.name if path.name != "__init__.py" else f"{name.replace('.', '/')}/__init__.py"
            seen.setdefault(source_name, path)
    return sorted(seen.items())


def max_n_state(data: bytes) -> tuple[int, str]:
    catalog = Catalog.load()
    mod = read_mpy(data, "<mpyc>", catalog, numeric=True)

    def walk(raw, label: str) -> tuple[int, str]:
        prelude = raw.prelude or decode_prelude(raw.fun_data)
        best = (prelude.n_state, label)
        for i, child in enumerate(raw.children):
            got = walk(child, f"{label}.{i}")
            if got[0] > best[0]:
                best = got
        return best

    return walk(mod.raw, mod.qstrs[1] if len(mod.qstrs) > 1 else "<module>")


def report_nstate() -> int:
    """Compile every mpyc module with mpy-cross and report the widest n_state."""

    root = build.ROOT / "vendor" / "upy2" / "mpyc"
    over = []
    widest = (0, "")
    for path in sorted(root.glob("*.py")):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "o.mpy"
            try:
                build.mpy_cross(path, out, path.name)
            except build.BuildError as exc:
                print(f"NSTATE  {path.name}  mpy-cross rejected: {exc}")
                return 1
            n, where = max_n_state(out.read_bytes())
        mark = ""
        if n > 64:
            over.append((path.name, n, where))
            mark = "  OVER"
        if n > widest[0]:
            widest = (n, path.name)
        print(f"NSTATE  {path.name:<20} {n:>3}{mark}")
    print(f"n_state widest: {widest[0]} in {widest[1]}")
    if over:
        print(f"{len(over)} compiler module(s) have a function past the 64-entry register file")
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--nstate", action="store_true", help="also audit n_state of mpyc/*.py")
    args = ap.parse_args(argv)
    if not build.MPY_CROSS.is_file():
        print(f"compiler_suite: mpy-cross missing at {build.MPY_CROSS}", file=sys.stderr)
        return 1
    counts = {"exact": 0, "float-spelling": 0, "differ": 0, "rejected by both": 0}
    bad = 0
    for source_name, path in suite_sources():
        _ref, _mine, note = _compile_both(path, source_name)
        if note in counts:
            counts[note] += 1
            if note == "differ":
                bad += 1
                print(f"DIFFER {source_name}")
            elif note == "float-spelling":
                print(f"FLOAT {source_name}")
        else:
            bad += 1
            print(f"FAIL  {source_name}  {note}")
    files = len(suite_sources())
    print(
        f"compiler_suite: {files} file(s), {counts['exact']} byte-exact, "
        f"{counts['float-spelling']} float spelling, {counts['differ']} differ, "
        f"{counts['rejected by both']} rejected by both"
    )
    rc = 1 if bad else 0
    if args.nstate:
        rc = report_nstate() or rc
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
