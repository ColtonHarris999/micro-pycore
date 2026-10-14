"""MMIO model for the product UART.

A store to ``UART_TX`` commits bits 7:0 as one printed byte. There is no
baud generator and no FIFO.
"""

from __future__ import annotations

MMIO_BASE = 0x40000000
UART_TX_OFFSET = 0x00
UART_TX = MMIO_BASE + UART_TX_OFFSET

_stores: list[tuple[int, int]] = []


def reset() -> None:
    _stores.clear()


def store(address: int, value: int) -> None:
    """Committed word store. ``UART_TX`` keeps bits 7:0."""
    if address != UART_TX:
        raise ValueError(f"store is not UART_TX: {address:#x}")
    _stores.append((address, value & 0xFF))


def stores() -> tuple[tuple[int, int], ...]:
    return tuple(_stores)


def tx_bytes() -> bytes:
    return bytes(byte for _address, byte in _stores)
