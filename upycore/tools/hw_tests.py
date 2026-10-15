#!/usr/bin/env python3
"""Run the hardware tests in ``upycore/programs/hw_tests.toml``.

Each test is a MicroPython program. The host compiles it with ``mpy-cross``
or the vendored uPy2 compiler (``--compiler mpyc``), links that bytecode
and the firmware into a flash image, and the simulator boots the image.
The firmware itself is always compiled with ``mpy-cross``. ``_boot`` calls
the program. The host then compares stdout, stderr, and the exit status
with the golden files next to the source. Those files are the unix
oracle's output (``make regen-goldens``).

Object addresses in ``repr`` are masked before the compare, so a live
pointer may differ from the oracle's.

Usage::

    python3 upycore/tools/hw_tests.py                  # every test
    python3 upycore/tools/hw_tests.py --area alu
    python3 upycore/tools/hw_tests.py 'dict*' --jobs 2
    python3 upycore/tools/hw_tests.py --list
    python3 upycore/tools/hw_tests.py --regen          # rewrite goldens
    python3 upycore/tools/hw_tests.py --check-goldens  # oracle must match goldens
    python3 upycore/tools/hw_tests.py --compiler mpyc  # same suite, uPy2 compiler
"""

from __future__ import annotations

import argparse
import difflib
import fnmatch
import os
import re
import subprocess
import sys
import threading
import time
import tomllib
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "upycore" / "tools"))

import mpy_build as build  # noqa: E402

MANIFEST = ROOT / "upycore" / "programs" / "hw_tests.toml"
PROGRAMS = ROOT / "upycore" / "programs"

# Addresses inside repr. The hex digits are the only part that may differ.
_ADDR_RES = (
    re.compile(rb"object at 0x[0-9a-fA-F]+"),
    re.compile(rb"object at [0-9a-fA-F]+"),
    re.compile(rb"at 0x[0-9a-fA-F]+"),
    re.compile(rb"<cell 0x[0-9a-fA-F]+>"),
    re.compile(rb"<cell [0-9a-fA-F]+>"),
)


def mask_output(data: bytes) -> bytes:
    """Replace pointer text in a console stream. The surrounding words stay."""

    for pattern in _ADDR_RES:
        data = pattern.sub(_mask_match, data)
    return data


def _mask_match(m: re.Match[bytes]) -> bytes:
    text = m.group(0)
    # The token is not hex, so a later pattern does not rewrite it.
    if text.startswith(b"object at"):
        return b"object at PTR"
    if text.startswith(b"at 0x"):
        return b"at PTR"
    if text.startswith(b"<cell"):
        return b"<cell PTR>"
    return b"PTR"


@dataclass
class Test:
    name: str
    area: str
    file: str
    cycles: int = 20_000_000
    modules: tuple[str, ...] = ()
    xfail: str | None = None
    heapsize: int | None = None
    timeout: float = 180
    # The unix pyexec prints an uncaught traceback on stdout. The device
    # prints it on stderr. Goldens store the device's stream.
    uncaught: bool = False
    # The unix port has no filesystem imports. These goldens are the
    # frozen-module result and are not rewritten from the oracle.
    oracle: bool = True

    @property
    def source(self) -> Path:
        return PROGRAMS / self.file

    def golden(self) -> tuple[Path, Path, Path]:
        src = self.source
        return src.with_suffix(".stdout"), src.with_suffix(".stderr"), src.with_suffix(".exit")


@dataclass
class Outcome:
    test: Test
    passed: bool
    detail: str = ""
    cycles: int | None = None
    halt: str = ""

    @property
    def expected_fail(self) -> bool:
        return bool(self.test.xfail) and not self.passed

    @property
    def ok(self) -> bool:
        return self.passed != bool(self.test.xfail)


def load_manifest(path: Path = MANIFEST) -> list[Test]:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    tests: list[Test] = []
    seen: set[str] = set()
    for area, entries in data.items():
        if not isinstance(entries, dict):
            raise SystemExit(f"hw_tests: {area!r} is not a table of tests")
        for name, fields in entries.items():
            if name in seen:
                raise SystemExit(f"hw_tests: duplicate test name {name!r}")
            seen.add(name)
            fields = dict(fields or {})
            if "modules" in fields:
                fields["modules"] = tuple(fields["modules"])
            rel = fields.pop("file", f"hw/{area}/{name}.py")
            try:
                tests.append(Test(name=name, area=area, file=rel, **fields))
            except TypeError as exc:
                raise SystemExit(f"hw_tests: {area}/{name}: {exc}") from exc
    return tests


def areas_of(tests: list[Test]) -> list[str]:
    out: list[str] = []
    for t in tests:
        if t.area not in out:
            out.append(t.area)
    return out


def select(tests: list[Test], areas: list[str], names: list[str]) -> list[Test]:
    known = set(areas_of(tests))
    for a in areas:
        if a != "all" and a not in known:
            raise SystemExit(f"hw_tests: unknown area {a!r} (areas: {', '.join(sorted(known))})")
    picked = tests
    if areas and "all" not in areas:
        picked = [t for t in picked if t.area in areas]
    if names:
        picked = [t for t in picked if any(fnmatch.fnmatch(t.name, n) for n in names)]
    return picked


def oracle_ready() -> bool:
    return build.ORACLE.is_file() and os.access(build.ORACLE, os.X_OK)


def _diff(kind: str, got: bytes, want: bytes) -> str:
    lines = list(difflib.unified_diff(
        want.decode("utf-8", "replace").splitlines(True),
        got.decode("utf-8", "replace").splitlines(True),
        fromfile=f"expected.{kind}",
        tofile=f"device.{kind}",
        n=2,
    ))
    text = "".join(lines)
    if len(text) > 2000:
        text = text[:2000] + "\n... diff truncated\n"
    return text


def _read_golden(t: Test) -> tuple[bytes, bytes, int]:
    out_p, err_p, exit_p = t.golden()
    missing = [p.name for p in (out_p, err_p, exit_p) if not p.exists()]
    if missing:
        raise FileNotFoundError(
            f"missing golden {', '.join(missing)} (make regen-goldens)"
        )
    code_text = exit_p.read_text(encoding="utf-8").strip()
    return out_p.read_bytes(), err_p.read_bytes(), int(code_text)


def _write_golden(t: Test, stdout: bytes, stderr: bytes, code: int) -> None:
    out_p, err_p, exit_p = t.golden()
    out_p.write_bytes(stdout)
    err_p.write_bytes(stderr)
    exit_p.write_text(f"{code}\n", encoding="utf-8")


def run_oracle(t: Test) -> tuple[bytes, bytes, int]:
    if not oracle_ready():
        raise SystemExit(
            f"hw_tests: oracle not built at {build.ORACLE} (make oracle)"
        )
    cmd = [str(build.ORACLE)]
    if t.heapsize is not None:
        cmd.append(f"-X heapsize={t.heapsize}")
    cmd.append(t.source.name)
    proc = subprocess.run(
        cmd, cwd=t.source.parent, capture_output=True, timeout=t.timeout,
    )
    stdout, stderr, code = proc.stdout, proc.stderr, proc.returncode
    if t.uncaught and stderr == b"" and stdout.startswith(b"Traceback"):
        stderr, stdout = stdout, b""
    return stdout, stderr, code


def _modules(t: Test) -> dict[str, Path]:
    mods: dict[str, Path] = {}
    for spec in t.modules:
        if "=" not in spec:
            raise RuntimeError(f"{t.name}: module spec {spec!r} is not name=path")
        name, rel = spec.split("=", 1)
        rel = rel.removesuffix(":package")
        path = PROGRAMS / rel
        if not path.is_file():
            raise RuntimeError(f"{t.name}: missing module {path}")
        mods[name] = path
    return mods


def compare_streams(
    got_out: bytes, got_err: bytes, got_code: int | None,
    want_out: bytes, want_err: bytes, want_code: int,
) -> str:
    """Empty string when the masked streams and the exit status match."""

    if got_code is None:
        return "device did not exit"
    parts: list[str] = []
    if mask_output(got_out) != mask_output(want_out):
        parts.append(_diff("stdout", mask_output(got_out), mask_output(want_out)))
    if mask_output(got_err) != mask_output(want_err):
        parts.append(_diff("stderr", mask_output(got_err), mask_output(want_err)))
    if got_code != want_code:
        parts.append(f"exit {got_code}, expected {want_code}\n")
    return "".join(parts)


def run_device(t: Test, compiler: str = "mpy-cross") -> Outcome:
    if not t.source.is_file():
        return Outcome(t, False, f"missing {t.source}")
    work = (ROOT / "build" / ("hw-mpyc" if compiler == "mpyc" else "hw")) / t.name
    try:
        image = build.build_program(t.source, work, t.source.name, _modules(t), compiler)
        res = build.run_image(image, max_cycles=t.cycles, timeout=t.timeout)
    except build.BuildError as exc:
        text = str(exc).strip().splitlines()
        return Outcome(t, False, text[-1] if text else "build failed")
    except subprocess.TimeoutExpired:
        return Outcome(t, False, f"runner timeout after {t.timeout:.0f}s", halt="TIMEOUT")
    try:
        want_out, want_err, want_code = _read_golden(t)
    except FileNotFoundError as exc:
        return Outcome(t, False, str(exc), cycles=res.cycles, halt=res.halt)
    detail = compare_streams(res.stdout, res.stderr, res.exit_code, want_out, want_err, want_code)
    if detail:
        if res.exit_code is None:
            detail = f"{res.halt} value={res.value:#x} cycles={res.cycles}\n" + detail
        return Outcome(t, False, detail.strip(), cycles=res.cycles, halt=res.halt)
    return Outcome(t, True, cycles=res.cycles, halt=res.halt)


def status_word(o: Outcome) -> str:
    if o.test.xfail:
        return "XFAIL" if not o.passed else "XPASS"
    return "PASS" if o.passed else "FAIL"


def _echo(line: str) -> None:
    print(line, flush=True)


def run_tests(tests: list[Test], jobs: int, compiler: str = "mpy-cross") -> list[Outcome]:
    if not build.MPY_CROSS.is_file():
        raise SystemExit(
            f"hw_tests: mpy-cross not found at {build.MPY_CROSS} "
            "(variants/upycore/build.sh mpy-cross)"
        )
    build.build_sim()
    build.build_firmware()
    lock = threading.Lock()
    results: list[Outcome] = []

    def work(t: Test) -> None:
        o = run_device(t, compiler)
        with lock:
            results.append(o)
            cyc = f"cycles={o.cycles}" if o.cycles is not None else ""
            why = ""
            if not o.passed:
                first = o.detail.splitlines()[0] if o.detail else ""
                why = first
            if o.test.xfail and not o.passed:
                why = f"{why} (known: {o.test.xfail})".strip()
            _echo(f"{status_word(o):<5} {t.area}/{t.name}  {cyc} {why}".rstrip())

    with ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        list(pool.map(work, tests))
    order = {t.name: i for i, t in enumerate(tests)}
    results.sort(key=lambda o: order[o.test.name])
    return results


def regen(tests: list[Test]) -> int:
    failed = 0
    for t in tests:
        if not t.oracle:
            print(f"SKIP  {t.area}/{t.name}  golden is not taken from the oracle", flush=True)
            continue
        if not t.source.is_file():
            print(f"FAIL  {t.area}/{t.name}  missing {t.source}", flush=True)
            failed += 1
            continue
        try:
            stdout, stderr, code = run_oracle(t)
        except subprocess.TimeoutExpired:
            print(f"FAIL  {t.area}/{t.name}  oracle timeout", flush=True)
            failed += 1
            continue
        _write_golden(t, stdout, stderr, code)
        print(f"WROTE {t.area}/{t.name}  exit={code} stdout={len(stdout)} stderr={len(stderr)}", flush=True)
    return 1 if failed else 0


def check_goldens(tests: list[Test]) -> int:
    failed = 0
    for t in tests:
        if not t.oracle:
            print(f"SKIP  {t.area}/{t.name}  golden is not taken from the oracle", flush=True)
            continue
        try:
            got = run_oracle(t)
            want = _read_golden(t)
        except (subprocess.TimeoutExpired, FileNotFoundError, SystemExit) as exc:
            print(f"FAIL  {t.area}/{t.name}  {exc}", flush=True)
            failed += 1
            continue
        # Goldens are the oracle's bytes. An exact match is required; the
        # address mask is only for the device, whose pointers differ.
        exact = got == want
        masked = compare_streams(got[0], got[1], got[2], want[0], want[1], want[2])
        if exact:
            print(f"PASS  {t.area}/{t.name}", flush=True)
            continue
        if not masked:
            print(f"FAIL  {t.area}/{t.name}  golden differs only by an address; regen it", flush=True)
        else:
            print(f"FAIL  {t.area}/{t.name}\n{masked}", flush=True)
        failed += 1
    return 1 if failed else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("names", nargs="*", help="test names or globs")
    ap.add_argument("--area", action="append", default=[], help="area to run; 'all' for every area")
    ap.add_argument("--jobs", "-j", type=int, default=os.cpu_count() or 2)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--regen", action="store_true", help="rewrite golden files from the oracle")
    ap.add_argument("--check-goldens", action="store_true", help="fail if the oracle disagrees with the goldens")
    ap.add_argument("--compiler", choices=("mpy-cross", "mpyc"), default="mpy-cross",
                    help="compiler for the test program and its frozen modules")
    args = ap.parse_args(argv)

    tests = load_manifest()
    if not (args.area or args.names) and not args.list:
        args.area = ["all"]
    if args.list and not args.area and not args.names:
        args.area = ["all"]
    picked = select(tests, args.area, args.names)
    if args.list:
        for t in picked:
            mark = "  (xfail)" if t.xfail else ""
            print(f"{t.area:<12} {t.name:<20} {t.file}{mark}")
        print(f"{len(picked)} test(s)")
        return 0
    if not picked:
        print("hw_tests: nothing selected", file=sys.stderr)
        return 1

    if args.regen:
        return regen(picked)
    if args.check_goldens:
        return check_goldens(picked)

    print(f"hw_tests: {len(picked)} test(s), {args.jobs} job(s), compiler {args.compiler}", flush=True)
    start = time.monotonic()
    results = run_tests(picked, args.jobs, args.compiler)
    elapsed = time.monotonic() - start
    failed = [o for o in results if not o.ok]
    xfailed = [o for o in results if o.expected_fail]
    by_area: dict[str, list[int]] = {}
    for o in results:
        slot = by_area.setdefault(o.test.area, [0, 0, 0])
        slot[2 if o.expected_fail else 0 if o.ok else 1] += 1
    print()
    for area in areas_of(picked):
        passed, nfail, nx = by_area.get(area, [0, 0, 0])
        extra = f"  {nx} known" if nx else ""
        print(f"  {area:<12} {passed:>3} passed  {nfail:>3} failed{extra}")
    print(
        f"hw_tests: {len(results) - len(failed) - len(xfailed)} of {len(results)} passed"
        + (f", {len(xfailed)} failed as expected" if xfailed else "")
        + f" in {elapsed:.0f}s"
    )
    if failed:
        for o in failed:
            why = "passed but is marked xfail; remove the marker" if o.passed else o.detail
            print(f"\nFAILED {o.test.area}/{o.test.name}\n{why}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
