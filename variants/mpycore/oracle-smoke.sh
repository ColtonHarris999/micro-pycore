#!/bin/sh
# Run the mpycore unix binary against variants/mpycore/smoke.py.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
BIN=${ORACLE_BIN:-$ROOT/build/oracle/src/ports/unix/build-mpycore/micropython}

if [ ! -x "$BIN" ]; then
    echo "oracle binary is not built: $BIN" >&2
    exit 1
fi

"$BIN" "$SCRIPT_DIR/smoke.py"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
"$BIN" -c 'import sys; sys.stdout.write("OUT\n"); sys.stderr.write("ERR\n")' >"$tmp/out" 2>"$tmp/err"
out=$(cat "$tmp/out")
err=$(cat "$tmp/err")
if [ "$out" != "OUT" ] || [ "$err" != "ERR" ]; then
    echo "stdio streams crossed: stdout=$(printf %s "$out") stderr=$(printf %s "$err")" >&2
    exit 1
fi
echo "stdio separate"
