#!/usr/bin/env bash
# Idempotent bootstrap for the PyCore two-core simulator.
# Ubuntu 24.04's Verilator package is 5.020, which cannot compile this RTL.
# Python 3.14 is required to emit the bytecode the hart executes.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

if [ "$(id -u)" -eq 0 ]; then
  SUDO=()
else
  SUDO=(sudo)
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

"${SUDO[@]}" apt-get update
"${SUDO[@]}" apt-get install -y --no-install-recommends \
  build-essential \
  ca-certificates \
  curl \
  git \
  libbz2-dev \
  libffi-dev \
  liblzma-dev \
  libreadline-dev \
  libsqlite3-dev \
  libssl-dev \
  libstdc++-14-dev \
  make \
  perl \
  pkg-config \
  python3 \
  python3-venv \
  uuid-dev \
  valgrind \
  zlib1g-dev

# Official CPython, linked against libpython. A second copy of
# _PyEval_EvalFrameDefault inside the python binary makes Callgrind rename
# the live function, and the host baseline then reports zero interpret cycles.
python_layout_ok() {
  local py
  py="$(command -v python3.14 2>/dev/null || true)"
  [[ -n "${py}" ]] || return 1
  if readelf -Ws "${py}" | awk '/_PyEval_EvalFrameDefault/ && $4 == "FUNC" && $5 != "UND" { found = 1 } END { exit !found }'; then
    return 1
  fi
  local resolved
  resolved="$(ldd "${py}" | awk '/libpython3\.14/{print $3; exit}')"
  [[ -n "${resolved}" && "${resolved}" == /usr/local/lib/* ]] || return 1
  python3.14 - <<'PY'
import sysconfig
from pathlib import Path
libdir = Path(sysconfig.get_config_var("LIBDIR") or "")
ldlib = sysconfig.get_config_var("LDLIBRARY") or "libpython3.14.so"
names = [ldlib, f"{ldlib}.1.0", "libpython3.14.so.1.0", "libpython3.14.so"]
raise SystemExit(0 if any((libdir / name).is_file() for name in names) else 1)
PY
}

if ! python_layout_ok; then
  py_version="3.14.8"
  src="$(mktemp -d)"
  curl -fsSL "https://www.python.org/ftp/python/${py_version}/Python-${py_version}.tgz" \
    | tar -xz -C "${src}"
  (
    cd "${src}/Python-${py_version}"
    ./configure --prefix=/usr/local --enable-shared --with-ensurepip=no
    make -j"$(nproc)"
    "${SUDO[@]}" make altinstall
  )
  "${SUDO[@]}" rm -rf "${src}"
  echo "/usr/local/lib" | "${SUDO[@]}" tee /etc/ld.so.conf.d/usr-local.conf >/dev/null
  "${SUDO[@]}" ldconfig
  hash -r
fi

WHEEL="${ROOT}/verilator-5.48.0-py3-none-manylinux_2_17_x86_64.manylinux2014_x86_64.whl"
PREFIX=/opt/verilator

if [[ ! -x "${PREFIX}/bin/verilator_bin" ]]; then
  if [[ ! -f "${WHEEL}" ]]; then
    echo "verilator wheel missing: ${WHEEL}" >&2
    exit 1
  fi
  tmp="$(mktemp -d)"
  python3 - "${WHEEL}" "${tmp}" <<'PY'
import sys
import zipfile
from pathlib import Path

wheel, dest = sys.argv[1], Path(sys.argv[2])
with zipfile.ZipFile(wheel) as zf:
    for name in zf.namelist():
        if name.startswith("verilator/bin/") or name.startswith("verilator/include/"):
            zf.extract(name, dest)
PY
  "${SUDO[@]}" rm -rf "${PREFIX}"
  "${SUDO[@]}" mkdir -p "${PREFIX}"
  "${SUDO[@]}" cp -a "${tmp}/verilator/bin" "${tmp}/verilator/include" "${PREFIX}/"
  "${SUDO[@]}" chmod -R a+rX "${PREFIX}"
  "${SUDO[@]}" chmod a+x \
    "${PREFIX}/bin/verilator" \
    "${PREFIX}/bin/verilator_bin" \
    "${PREFIX}/bin/verilator_includer"
  rm -rf "${tmp}"
fi

"${SUDO[@]}" ln -sfn "${PREFIX}/bin/verilator" /usr/local/bin/verilator
# /usr/bin/c++ is clang. The wheel's precompiled-header rules follow GCC
# (empty CFG_GCH_IF_CLANG), so the model build must use g++.
"${SUDO[@]}" ln -sfn /usr/bin/g++ /usr/local/bin/c++
# The wheel's verilated.mk was configured on a GCC toolset that enables
# coroutines by default. g++ 13 needs these flags or <coroutine> fails.
"${SUDO[@]}" sed -i \
  -e 's/^CFG_CXXFLAGS_STD = .*/CFG_CXXFLAGS_STD = -std=c++20/' \
  -e 's/^CFG_CXXFLAGS_COROUTINES = .*/CFG_CXXFLAGS_COROUTINES = -fcoroutines/' \
  -e 's/^CFG_CXXFLAGS_PCH_I = .*/CFG_CXXFLAGS_PCH_I = -include/' \
  -e 's/^CFG_LDLIBS_THREADS = .*/CFG_LDLIBS_THREADS = -latomic -pthread/' \
  "${PREFIX}/include/verilated.mk"
echo '#include <cstdint>' | c++ -fsyntax-only -x c++ -

if [[ -f .gitmodules ]]; then
  git submodule update --init --recursive
fi

echo "verilator: $(verilator --version)"
echo "python3.14: $(python3.14 --version)"
echo "python3: $(python3 --version)"
test -f vendor/pycpython/pycpython/compile.py
