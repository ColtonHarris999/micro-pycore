#!/bin/sh
# Build the pinned MicroPython tree: host mpy-cross, then the 32-bit
# mpycore unix variant. The pin checkout stays clean; the patch is applied
# to a copy under build/oracle/src, or in place when MPY_SRC is set.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
VARIANT="$SCRIPT_DIR"
PIN="$ROOT/vendor/micropython"
WORK="${MPY_SRC:-$ROOT/build/oracle/src}"
CROSS="${ORACLE_CROSS_COMPILE:-i686-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"

usage() {
    echo "usage: build.sh {prepare|mpy-cross|variant|header|smoke}" >&2
    exit 2
}

ensure_patch() {
    if patch -d "$WORK" -p1 --reverse --dry-run --batch --forward \
        < "$VARIANT/unix-port.patch" >/dev/null 2>&1; then
        return 0
    fi
    patch -d "$WORK" -p1 --forward --batch < "$VARIANT/unix-port.patch"
}

prepare() {
    if [ -n "${MPY_SRC:-}" ]; then
        WORK="$MPY_SRC"
    else
        if [ ! -d "$PIN/py" ]; then
            echo "missing pin: $PIN" >&2
            exit 1
        fi
        pin_sha=$(git -C "$PIN" rev-parse HEAD)
        patch_sha=$(sha256sum "$VARIANT/unix-port.patch" | awk '{print $1}')
        stamp="$ROOT/build/oracle/src.stamp"
        want="$pin_sha $patch_sha"
        if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$want" ] || [ ! -d "$WORK/py" ]; then
            rm -rf "$WORK"
            mkdir -p "$WORK"
            tar -C "$PIN" --exclude .git -cf - . | tar -C "$WORK" -xf -
            mkdir -p "$ROOT/build/oracle"
            printf '%s\n' "$want" > "$stamp"
        fi
    fi
    if [ ! -d "$WORK/py" ]; then
        echo "missing MicroPython tree: $WORK" >&2
        exit 1
    fi
    ensure_patch
}

build_mpy_cross() {
    prepare
    make -C "$WORK/mpy-cross" -j"$JOBS"
}

build_variant() {
    prepare
    if ! command -v "${CROSS}gcc" >/dev/null 2>&1; then
        echo "missing ${CROSS}gcc (the pin's i686 unix recipe)" >&2
        exit 1
    fi
    # Object files do not depend on the variant header, so drop the build
    # when the variant or the port patch changes.
    variant_id=$(cat "$VARIANT/mpconfigvariant.h" "$VARIANT/mpconfigvariant.mk" "$VARIANT/unix-port.patch" "$VARIANT/stdio.c" | sha256sum | awk '{print $1}')
    variant_stamp="$ROOT/build/oracle/variant.stamp"
    mkdir -p "$ROOT/build/oracle"
    if [ ! -f "$variant_stamp" ] || [ "$(cat "$variant_stamp")" != "$variant_id" ]; then
        rm -rf "$WORK/ports/unix/build-mpycore"
        printf '%s\n' "$variant_id" > "$variant_stamp"
    fi
    make -C "$WORK/ports/unix" -j"$JOBS" \
        VARIANT_DIR="$VARIANT" \
        CROSS_COMPILE="$CROSS"
}

cmd=${1:-}
case "$cmd" in
    prepare)
        prepare
        ;;
    mpy-cross)
        build_mpy_cross
        ;;
    variant)
        build_variant
        ;;
    header)
        build_mpy_cross
        MPY_CROSS="$WORK/mpy-cross/build/mpy-cross" \
            MPY_PIN_H="$WORK/py/persistentcode.h" \
            "$VARIANT/oracle-header.sh"
        ;;
    smoke)
        build_variant
        ORACLE_BIN="$WORK/ports/unix/build-mpycore/micropython" \
            "$VARIANT/oracle-smoke.sh"
        ;;
    *)
        usage
        ;;
esac
