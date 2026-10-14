"""Text of one value, in the form ``print`` writes.

Integers are decimal. ``True``, ``False``, and ``None`` use those spellings.
A ``str`` is its UTF-8 bytes, not a quoted repr. The line form ends with the
newline byte ``0x0A``.
"""

from __future__ import annotations

NEWLINE = 0x0A


def format_value(value: object) -> bytes:
    if isinstance(value, bool):
        return b"True" if value else b"False"
    if value is None:
        return b"None"
    if isinstance(value, int):
        return _format_int(value)
    if isinstance(value, str):
        return value.encode("utf-8")
    raise TypeError("print does not support this value")


def format_print(value: object) -> bytes:
    """``format_value`` plus the newline byte."""
    return format_value(value) + bytes((NEWLINE,))


def _format_int(value: int) -> bytes:
    if value == 0:
        return b"0"
    negative = value < 0
    if negative:
        value = -value
    digits = bytearray()
    while value:
        value, digit = divmod(value, 10)
        digits.append(48 + digit)
    digits.reverse()
    if negative:
        return b"-" + bytes(digits)
    return bytes(digits)
