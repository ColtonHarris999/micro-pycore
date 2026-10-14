"""Native ``sys`` module.

``platform`` and ``implementation.name`` are ``upycore``.
``implementation._mpy`` is the pin's compatibility integer.
"""

from __future__ import annotations

from .encoding import SYS_IMPLEMENTATION_MPY
from .format import format_value
from .uart import UART_TX, store

_MISSING = object()


class Implementation:
    name = "upycore"
    _mpy = SYS_IMPLEMENTATION_MPY


class Stdout:
    """``sys.stdout``. ``write`` stores each byte to ``UART_TX``."""

    def write(self, data: str | bytes) -> int:
        if isinstance(data, str):
            raw = data.encode("utf-8")
        elif isinstance(data, (bytes, bytearray)):
            raw = bytes(data)
        else:
            raise TypeError("stdout.write expects str or bytes")
        for byte in raw:
            store(UART_TX, byte)
        return len(raw)


def _arg_text(arg: object) -> str:
    if isinstance(arg, str):
        return arg
    if arg is None or isinstance(arg, bool) or isinstance(arg, int):
        return format_value(arg).decode("ascii")
    return str(arg)


def _exception_text(exc: BaseException) -> str:
    name = type(exc).__name__
    args = getattr(exc, "args", ())
    if len(args) == 0:
        return name
    if len(args) == 1:
        return name + ": " + _arg_text(args[0])
    inner = ", ".join(_arg_text(arg) for arg in args)
    return name + ": (" + inner + ")"


def exit(code: object = _MISSING) -> None:
    """Raise ``SystemExit``. No argument raises it with no args."""
    if code is _MISSING:
        raise SystemExit
    raise SystemExit(code)


def print_exception(exc: BaseException, file: object | None = None) -> None:
    """Write the exception line and a newline. The default stream is ``stdout``."""
    if not isinstance(exc, BaseException):
        raise TypeError("print_exception argument must be an exception")
    stream = stdout if file is None else file
    write = getattr(stream, "write", None)
    if not callable(write):
        raise TypeError("print_exception stream has no write")
    write(_exception_text(exc) + "\n")


# py/objint_longlong.c stores MP_SSIZE_MAX. This port is 32-bit.
_MP_SSIZE_MAX = (1 << 31) - 1

platform = "upycore"
byteorder = "little"
maxsize = _MP_SSIZE_MAX
implementation = Implementation()
stdout = Stdout()
modules: dict[str, object] = {}


def _register_self() -> None:
    import sys as host_sys

    modules["sys"] = host_sys.modules[__name__]


_register_self()
