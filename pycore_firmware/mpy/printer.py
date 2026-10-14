"""``print`` stores formatted bytes to ``UART_TX`` on this hart."""

from __future__ import annotations

from .format import format_print
from .uart import UART_TX, store


def print(value: object) -> None:
    """Format ``value`` and store each byte, including the newline, to ``UART_TX``."""
    for byte in format_print(value):
        store(UART_TX, byte)
    return None
