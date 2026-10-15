#!/usr/bin/env python3
"""Build and run MicroPython programs on the uPyCore mpy_soc simulation.

The flow is: firmware sources (upycore/firmware/*.py) are joined into
one module and compiled with mpy-cross; the program is compiled the same
way; mpy_link.py joins both into a flash image; the Verilator build of
tb_mpy_soc runs it and writes stdout and stderr to files.

Usage::

    mpy_build.py sim                 build the simulator
    mpy_build.py fw                  build the firmware .mpy
    mpy_build.py run prog.py [-v]    build and run one program
    mpy_build.py oracle prog.py      run the program on the MicroPython oracle

``run`` prints the program's stdout and stderr and exits with its exit
status, like the oracle's unix port does.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "upycore" / "tools"))

import mpy_abi as abi  # noqa: E402

BUILD = ROOT / "build" / "mpy"
FW_SRC = ROOT / "upycore" / "firmware"
ORACLE_SRC = ROOT / "build" / "oracle" / "src"
MPY_CROSS = Path(os.environ.get("MPY_CROSS", ORACLE_SRC / "mpy-cross" / "build" / "mpy-cross"))
ORACLE = Path(os.environ.get("MPY_ORACLE", ORACLE_SRC / "ports" / "unix" / "build-upycore" / "micropython"))
SIM_DIR = ROOT / "build" / "mpy_soc"
SIM = SIM_DIR / "obj" / "Vtb_mpy_soc"
MPY_CROSS_FLAGS = ["-msmall-int-bits=31", "-O0"]

# Firmware modules in link order. _abi.py comes first so its const() names
# fold into every later module.
FW_ORDER = [
    "_abi.py", "base.py", "errors.py", "fmt.py", "floatfmt.py", "ops.py",
    "attrs.py", "calls.py", "iters.py", "strs.py", "seqs.py", "dicts.py",
    "builtins.py", "modules.py", "boot.py",
]

RTL = [
    "upycore/rtl/upycore_umul_seq.sv", "upycore/rtl/upycore_udiv_seq.sv",
    "upycore/rtl/upycore_int_alu.sv", "upycore/rtl/upycore_mul.sv", "upycore/rtl/upycore_div.sv",
    "upycore/rtl/upycore_ipow.sv", "upycore/rtl/upycore_fp_add.sv", "upycore/rtl/upycore_fp_mul.sv",
    "upycore/rtl/upycore_fp_divrem.sv", "upycore/rtl/upycore_fp_pow.sv", "upycore/rtl/upycore_fpu.sv",
    "upycore/rtl/mpy_alu.sv", "upycore/rtl/mpy_decode.sv", "upycore/rtl/mpy_core.sv",
    "upycore/rtl/mpy_gc.sv", "upycore/rtl/mpy_mem.sv", "upycore/rtl/mpy_soc.sv",
    "upycore/tb/tb_mpy_soc.sv",
]
RTL_INCLUDES = [
    "upycore/rtl/mpy_abi.svh", "upycore/rtl/mpy_defs.svh", "upycore/rtl/upycore_defs.svh",
    "upycore/rtl/upycore_fp_defs.svh", "upycore/rtl/upycore_fp_pow_rom.svh",
]

HALT_NAMES = {v: k for k, v in abi.HALT.items()}


class BuildError(Exception):
    pass


def _newer(target: Path, sources: list[Path]) -> bool:
    if not target.exists():
        return True
    t = target.stat().st_mtime
    return any(s.stat().st_mtime > t for s in sources)


def build_sim(force: bool = False, quiet: bool = True) -> Path:
    """Verilate tb_mpy_soc when any RTL source is newer than the binary."""

    sources = [ROOT / p for p in RTL + RTL_INCLUDES]
    if not force and not _newer(SIM, sources):
        return SIM
    (SIM_DIR / "obj").mkdir(parents=True, exist_ok=True)
    cmd = [
        os.environ.get("VERILATOR", "verilator"), "-sv", "--binary", "--timing",
        "--timescale", "1ns/1ps", "-O3", "--x-assign", "fast", "--x-initial", "fast",
        f"+incdir+{ROOT / 'upycore' / 'rtl'}", "-y", str(ROOT / "upycore" / "rtl"),
        "--top-module", "tb_mpy_soc",
        "--Mdir", str(SIM_DIR / "obj"), "-Wno-fatal", "-Wno-WIDTH", "-Wno-UNUSED",
        "-Wno-CASEINCOMPLETE", "-Wno-BLKSEQ", "-Wno-TIMESCALEMOD", "-j", str(os.cpu_count() or 4),
    ] + [str(s) for s in sources if s.suffix == ".sv"]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        raise BuildError("verilator failed:\n" + r.stdout[-4000:] + r.stderr[-4000:])
    if not quiet:
        print(f"built {SIM.relative_to(ROOT)}")
    return SIM


def mpy_cross(src: Path, out: Path, source_name: str) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(
        [str(MPY_CROSS), *MPY_CROSS_FLAGS, "-s", source_name, "-o", str(out), str(src)],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise BuildError(f"mpy-cross {src}:\n{r.stdout}{r.stderr}")


_FW_IMPORT = re.compile(r"^\s*from\s+(\.?_abi|micropython)\s+import\s+")


def firmware_source() -> str:
    parts = []
    for i, name in enumerate(FW_ORDER):
        path = FW_SRC / name
        if not path.exists():
            continue
        lines = path.read_text().splitlines()
        if i > 0:
            lines = [ln for ln in lines if not _FW_IMPORT.match(ln)]
        parts.append(f"# ---- {name} ----")
        parts.extend(lines)
    return "\n".join(parts) + "\n"


def build_firmware(out_dir: Path = BUILD / "fw") -> Path:
    """Join and compile the firmware; returns the .mpy path."""

    out_dir.mkdir(parents=True, exist_ok=True)
    src = out_dir / "fw.py"
    mpy = out_dir / "fw.mpy"
    text = firmware_source()
    if not src.exists() or src.read_text() != text:
        src.write_text(text)
    if _newer(mpy, [src, MPY_CROSS]):
        mpy_cross(src, mpy, "_fw.py")
    return mpy


def link(main_mpy: Path, fw_mpy: Path, out: Path, modules: list[str] | None = None) -> Path:
    cmd = [sys.executable, str(ROOT / "upycore" / "tools" / "mpy_link.py"),
           "--main", str(main_mpy), "--fw", str(fw_mpy), "-o", str(out)]
    for m in modules or []:
        cmd += ["--module", m]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise BuildError(f"link failed:\n{r.stdout}{r.stderr}")
    return out


@dataclass
class SimResult:
    stdout: bytes
    stderr: bytes
    halt: str            # CLEAN, SYSEXIT, UNCAUGHT, ..., or TIMEOUT
    value: int
    cycles: int
    ops: int
    gc: int
    log: str

    @property
    def exit_code(self) -> int | None:
        """The unix port's exit status, or None when the core crashed."""

        if self.halt == "CLEAN":
            return 0
        if self.halt == "SYSEXIT":
            return self.value & 0xFF
        return None


_HALT_RE = re.compile(r"MPY_HALT code=(\d+) value=([0-9a-f]+) cycles=(\d+) ops=(\d+) gc=(\d+)")
_TIMEOUT_RE = re.compile(r"MPY_TIMEOUT cycles=(\d+) ops=(\d+) gc=(\d+)")


def run_image(image: Path, max_cycles: int = 50_000_000, trace: bool = False,
              timeout: float | None = None) -> SimResult:
    out = Path(f"{image}.stdout")
    err = Path(f"{image}.stderr")
    cmd = [str(SIM), f"+IMAGE={image}.hex", f"+TAGS={image}.tags.hex",
           f"+STDOUT={out}", f"+STDERR={err}", f"+MAX_CYCLES={max_cycles}"]
    if trace:
        cmd.append("+TRACE=1")
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    log = r.stdout + r.stderr
    stdout = out.read_bytes() if out.exists() else b""
    stderr = err.read_bytes() if err.exists() else b""
    m = _HALT_RE.search(log)
    if m:
        code = int(m.group(1))
        return SimResult(stdout, stderr, HALT_NAMES.get(code, str(code)), int(m.group(2), 16),
                         int(m.group(3)), int(m.group(4)), int(m.group(5)), log)
    m = _TIMEOUT_RE.search(log)
    if m:
        return SimResult(stdout, stderr, "TIMEOUT", 0, int(m.group(1)), int(m.group(2)), int(m.group(3)), log)
    return SimResult(stdout, stderr, "NO_RESULT", 0, 0, 0, 0, log)


def build_program(src: Path, work: Path, source_name: str | None = None,
                  modules: dict[str, Path] | None = None) -> Path:
    """Compile and link one program (plus frozen modules); returns the image prefix."""

    work.mkdir(parents=True, exist_ok=True)
    fw = build_firmware()
    name = source_name or src.name
    main_mpy = work / "main.mpy"
    mpy_cross(src, main_mpy, name)
    specs = []
    for mname, mpath in (modules or {}).items():
        mm = work / (mname.replace(".", "_") + ".mpy")
        mpy_cross(mpath, mm, mpath.name if mpath.name != "__init__.py" else f"{mname.replace('.', '/')}/__init__.py")
        kind = ":package" if mpath.name == "__init__.py" else ""
        specs.append(f"{mname}={mm}{kind}")
    return link(main_mpy, fw, work / "image", specs)


def run_oracle(src: Path, cwd: Path | None = None, timeout: float = 60) -> tuple[bytes, bytes, int]:
    r = subprocess.run([str(ORACLE), src.name], cwd=cwd or src.parent, capture_output=True, timeout=timeout)
    return r.stdout, r.stderr, r.returncode


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("sim")
    sub.add_parser("fw")
    rp = sub.add_parser("run")
    rp.add_argument("src", type=Path)
    rp.add_argument("--max-cycles", type=int, default=50_000_000)
    rp.add_argument("--trace", action="store_true")
    rp.add_argument("-v", "--verbose", action="store_true", help="print the halt line")
    rp.add_argument("--work", type=Path, default=None)
    op = sub.add_parser("oracle")
    op.add_argument("src", type=Path)
    args = ap.parse_args(argv)
    try:
        if args.cmd == "sim":
            build_sim(force=True, quiet=False)
            return 0
        if args.cmd == "fw":
            print(build_firmware())
            return 0
        if args.cmd == "oracle":
            out, err, rc = run_oracle(args.src.resolve())
            sys.stdout.buffer.write(out)
            sys.stderr.buffer.write(err)
            return rc
        build_sim()
        work = args.work or BUILD / "run" / args.src.stem
        image = build_program(args.src.resolve(), work)
        res = run_image(image, args.max_cycles, args.trace)
    except BuildError as exc:
        print(exc, file=sys.stderr)
        return 2
    if args.trace:
        sys.stdout.write("\n".join(ln for ln in res.log.splitlines() if ln.startswith("TRACE")) + "\n")
    sys.stdout.buffer.write(res.stdout)
    sys.stdout.flush()
    sys.stderr.buffer.write(res.stderr)
    if args.verbose or res.exit_code is None:
        print(f"[{res.halt} value={res.value:#x} cycles={res.cycles} ops={res.ops} gc={res.gc}]", file=sys.stderr)
    return res.exit_code if res.exit_code is not None else 3


if __name__ == "__main__":
    raise SystemExit(main())
