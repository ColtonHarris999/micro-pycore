"""`.mpy` compatibility word for the v1.29.0 pin.

``sys.implementation._mpy`` is the integer ``modsys.c`` stores:
``MPY_FILE_HEADER_INT | MPY_FILE_ARCH_FLAGS`` from ``py/persistentcode.h``.
With no native emitter the architecture is ``MP_NATIVE_ARCH_NONE`` and the
architecture-flags word is 0, so the value is version 6 with sub-version 3
in the feature byte.

That integer does not carry the small-int width. The loader compares header
byte 3 with ``MP_SMALL_INT_BITS``. On this 32-bit port that width is 31.
``mp_raw_code_save`` writes the sub-version only when the file has native
code, so a bytecode-only file is ``4d 06 00 1f``.
"""

from __future__ import annotations

MPY_VERSION = 6
MPY_SUB_VERSION = 3
MP_NATIVE_ARCH_NONE = 0
MP_SMALL_INT_BITS = 31


def mpy_feature_encode_sub_version(version: int) -> int:
    return version


def mpy_feature_encode_arch(arch: int) -> int:
    return arch << 2


def mpy_feature_decode_sub_version(feat: int) -> int:
    return feat & 3


def mpy_feature_decode_arch(feat: int) -> int:
    return (feat >> 2) & 0x2F


# No native emitter: MPY_FEATURE_ARCH is MP_NATIVE_ARCH_NONE.
MPY_FEATURE_ARCH = MP_NATIVE_ARCH_NONE
MPY_FILE_ARCH_FLAGS = 0

MPY_FILE_HEADER_INT = MPY_VERSION | (
    (
        mpy_feature_encode_sub_version(MPY_SUB_VERSION)
        | mpy_feature_encode_arch(MPY_FEATURE_ARCH)
    )
    << 8
)

# The integer stored on sys.implementation._mpy.
SYS_IMPLEMENTATION_MPY = MPY_FILE_HEADER_INT | MPY_FILE_ARCH_FLAGS


def mpy_version(mpy: int) -> int:
    return mpy & 0xFF


def mpy_arch(mpy: int) -> int:
    """Native architecture, using the pin docs' shift ``(mpy >> 10) & 0x0F``."""
    return (mpy >> 10) & 0x0F


def bytecode_header() -> bytes:
    """Four-byte header of a bytecode-only file with 31-bit small ints."""
    return bytes((0x4D, MPY_VERSION, 0x00, MP_SMALL_INT_BITS))


def advertised(mpy: int = SYS_IMPLEMENTATION_MPY) -> tuple[int, int, int]:
    """Bytecode version, architecture, and small-int width this runtime advertises.

    Version and architecture come from ``_mpy``. Small-int width is
    ``MP_SMALL_INT_BITS``, the width the pin's loader checks against
    header byte 3.
    """
    return (mpy_version(mpy), mpy_arch(mpy), MP_SMALL_INT_BITS)
