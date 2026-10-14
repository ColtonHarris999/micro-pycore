#!/bin/sh
# Compile one bytecode-only file with the pinned mpy-cross and print its
# header. Invocation is -msmall-int-bits=31 and -O0, and does not pass
# -march. MPY_SUB_VERSION is checked in the source and in a native file;
# a bytecode-only file does not carry it.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

MPY_CROSS=${MPY_CROSS:-$ROOT/build/oracle/src/mpy-cross/build/mpy-cross}
MPY_PIN_H=${MPY_PIN_H:-$ROOT/vendor/micropython/py/persistentcode.h}

if [ ! -x "$MPY_CROSS" ]; then
    echo "mpy-cross is not built: $MPY_CROSS" >&2
    exit 1
fi
if [ ! -f "$MPY_PIN_H" ]; then
    echo "missing persistentcode.h: $MPY_PIN_H" >&2
    exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/sample.py" <<'PY'
def add(a, b):
    return a + b
PY

# Bytecode only. No -march.
"$MPY_CROSS" -msmall-int-bits=31 -O0 -o "$tmp/sample.mpy" "$tmp/sample.py"
# Native emitter, so the sub-version macro is written into the feature byte.
# -march alone does not select the emitter.
"$MPY_CROSS" -msmall-int-bits=31 -O0 -march=x86 -X emit=native -o "$tmp/native.mpy" "$tmp/sample.py"

python3 - "$tmp/sample.mpy" "$tmp/native.mpy" "$MPY_PIN_H" <<'PY'
import pathlib
import re
import sys

mpy_path, native_path, pin_path = sys.argv[1:]
text = pathlib.Path(pin_path).read_text()


def macro(name):
    match = re.search(rf"^#define {name} (\d+)\s*$", text, re.M)
    if not match:
        sys.exit(f"missing {name} in {pin_path}")
    return int(match.group(1))


version = macro("MPY_VERSION")
sub = macro("MPY_SUB_VERSION")
if (version, sub) != (6, 3):
    sys.exit(f"mpy-version: {version}.{sub}")

bytecode = pathlib.Path(mpy_path).read_bytes()[:4]
native = pathlib.Path(native_path).read_bytes()[:4]


def show(blob):
    return " ".join(f"{byte:02x}" for byte in blob)


expected = bytes.fromhex("4d06001f")
if bytecode != expected:
    sys.exit(f"bytecode header {show(bytecode)}")
if native[0] != 0x4D or native[1] != version or native[3] != 0x1F:
    sys.exit(f"native header {show(native)}")
arch = (native[2] >> 2) & 0x2F
if (native[2] & 3) != sub or arch == 0:
    sys.exit(
        f"native feature {native[2]:02x} does not carry sub-version {sub}"
    )
if (bytecode[2] & 3) != 0:
    sys.exit("sub-version leaked into the bytecode-only file")
print("header:", show(bytecode))
PY
