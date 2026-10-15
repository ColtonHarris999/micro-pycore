#!/usr/bin/env python3
"""Host register model for the v1 peripheral block.

This is the oracle for GPIO edge traces and for the UART echo bytes.
The unix ``machine`` module is a different map and is not consulted.
The rules live in ``upycore/docs/mpy_peripherals.md``.
"""

from __future__ import annotations

import sys

SCHED_DEPTH = 8
BLINK_PERIOD = 4
BLINK_TICKS = 20
HOLD_COMPARE = 5
HOLD_STEPS = 3
HOLD_IDLE_STEPS = 5


class Timer:
    """Compare 0 disables the counter. A match reloads the counter to 0."""

    def __init__(self) -> None:
        self.compare = 0
        self.count = 0

    def set_compare(self, period: int) -> None:
        self.compare = period & 0xFFFFFFFF

    def step(self) -> bool:
        if self.compare == 0:
            return False
        nxt = self.count + 1
        if nxt >= self.compare:
            self.count = 0
            return True
        self.count = nxt & 0xFFFFFFFF
        return False


class UartRx:
    """One byte. A second byte while valid sticks overrun bit 30 and is dropped."""

    def __init__(self) -> None:
        self.data = 0
        self.valid = False
        self.overrun = False

    def push(self, byte: int) -> str:
        if self.valid:
            self.overrun = True
            return "drop"
        self.data = byte & 0xFF
        self.valid = True
        return "take"

    def read(self) -> int:
        value = (
            ((1 if self.valid else 0) << 31)
            | ((1 if self.overrun else 0) << 30)
            | (self.data & 0xFF)
        )
        if self.valid:
            self.valid = False
            self.data = 0
        return value

    def clear_overrun(self) -> None:
        self.overrun = False


class Schedule:
    """Depth 8. The push that does not fit raises RuntimeError."""

    def __init__(self) -> None:
        self.q: list[tuple[int, int]] = []

    def push(self, fn: int, arg: int) -> None:
        if len(self.q) >= SCHED_DEPTH:
            raise RuntimeError("schedule queue full")
        self.q.append((fn, arg))

    def pop(self) -> tuple[int, int]:
        return self.q.pop(0)

    @property
    def count(self) -> int:
        return len(self.q)


def gpio_edge_hit(edge_cfg: int, old: int, new: int) -> bool:
    """Pins 0..15. Two bits each: off, rising, falling, both."""
    for pin in range(16):
        mode = (edge_cfg >> (2 * pin)) & 0x3
        rose = ((old >> pin) & 1) == 0 and ((new >> pin) & 1) == 1
        fell = ((old >> pin) & 1) == 1 and ((new >> pin) & 1) == 0
        if mode == 1 and rose:
            return True
        if mode == 2 and fell:
            return True
        if mode == 3 and (rose or fell):
            return True
    return False


def blink_edge_mask(period: int, ticks: int) -> int:
    """Edges of GPIO_OUT bit 0.

    The testbench does one timer step, a non-jump bytecode boundary, then
    one jump. The soft timer callback runs at that jump and toggles the
    pin. Idle clocks between steps are not timer ticks, so they are not
    arguments here.
    """
    timer = Timer()
    timer.set_compare(period)
    pending = False
    mask = 0
    for tick in range(1, ticks + 1):
        if timer.step():
            pending = True
        if pending:
            pending = False
            mask |= 1 << (tick - 1)
    return mask


def hold_count() -> int:
    """A partial count stays put after compare is written to 0."""
    timer = Timer()
    timer.set_compare(HOLD_COMPARE)
    for _ in range(HOLD_STEPS):
        timer.step()
    if timer.count != HOLD_STEPS:
        raise AssertionError(f"count {timer.count} after {HOLD_STEPS} steps")
    timer.set_compare(0)
    for _ in range(HOLD_IDLE_STEPS):
        if timer.step():
            raise AssertionError("disabled timer matched")
    return timer.count


def echo_result() -> tuple[int, int, int]:
    """Bytes that fit are transmitted. One overrun sticks, and 0x43 stays."""
    uart = UartRx()
    tx: list[int] = []
    overruns = 0

    def deliver() -> None:
        nonlocal overruns
        value = uart.read()
        if (value & (1 << 31)) == 0:
            raise AssertionError("echo delivered an empty buffer")
        if value & (1 << 30):
            overruns += 1
        tx.append(value & 0xFF)

    if uart.push(0x41) != "take":
        raise AssertionError("0x41 should fit")
    deliver()
    if uart.push(0x42) != "take":
        raise AssertionError("0x42 should fit")
    deliver()
    if uart.push(0x43) != "take":
        raise AssertionError("0x43 should fit")
    if uart.push(0x44) != "drop":
        raise AssertionError("0x44 should drop")
    deliver()
    follow = uart.read()
    if follow & (1 << 31):
        raise AssertionError("buffer should be empty after the echo")
    if (follow & (1 << 30)) == 0:
        raise AssertionError("overrun should stick across the pop")
    uart.clear_overrun()
    if uart.overrun:
        raise AssertionError("writing bit 30 clears overrun")
    word = 0
    for index, byte in enumerate(tx):
        word |= byte << (8 * index)
    return word, len(tx), overruns


def schedule_raise_at() -> int:
    """Eight pushes fit. The next one is the ninth and raises."""
    sched = Schedule()
    for fn in range(1, SCHED_DEPTH + 1):
        sched.push(fn, 0)
    try:
        sched.push(SCHED_DEPTH + 1, 0)
    except RuntimeError as exc:
        if str(exc) != "schedule queue full":
            raise AssertionError(str(exc)) from exc
        if sched.count != SCHED_DEPTH:
            raise AssertionError("a refused push must leave the ring full")
        first = sched.pop()
        second = sched.pop()
        if first != (1, 0) or second != (2, 0):
            raise AssertionError(f"fifo pop order {(first, second)}")
        if sched.count != SCHED_DEPTH - 2:
            raise AssertionError("two jumps run two callbacks")
        return SCHED_DEPTH + 1
    raise AssertionError("the ninth schedule must raise")


def plusargs() -> str:
    """Numbers the RTL testbench compares against this model."""
    edge_mask = blink_edge_mask(BLINK_PERIOD, BLINK_TICKS)
    off_mask = blink_edge_mask(0, BLINK_TICKS)
    tx_word, tx_n, overrun = echo_result()
    raise_at = schedule_raise_at()
    held = hold_count()
    return (
        f"+BLINK_PERIOD={BLINK_PERIOD} +BLINK_TICKS={BLINK_TICKS} "
        f"+EXPECT_EDGE_MASK={edge_mask} +EXPECT_EDGES={edge_mask.bit_count()} "
        f"+EXPECT_OFF_MASK={off_mask} "
        f"+HOLD_COMPARE={HOLD_COMPARE} +HOLD_STEPS={HOLD_STEPS} "
        f"+HOLD_IDLE_STEPS={HOLD_IDLE_STEPS} +HOLD_COUNT={held} "
        f"+EXPECT_TX_WORD={tx_word} +EXPECT_TXN={tx_n} "
        f"+EXPECT_OVERRUN={overrun} +EXPECT_SCHED_RAISE_AT={raise_at}"
    )


def self_check() -> None:
    mask = blink_edge_mask(BLINK_PERIOD, BLINK_TICKS)
    if mask != 0x88888 or mask.bit_count() != 5:
        raise AssertionError(f"blink mask {mask:#x}")
    if blink_edge_mask(0, BLINK_TICKS) != 0:
        raise AssertionError("compare 0 produced edges")
    if hold_count() != HOLD_STEPS:
        raise AssertionError("disabled timer moved the counter")
    tx_word, tx_n, overrun = echo_result()
    if (tx_word, tx_n, overrun) != (0x434241, 3, 1):
        raise AssertionError(f"echo {(tx_word, tx_n, overrun)}")
    if schedule_raise_at() != 9:
        raise AssertionError("schedule depth drifted")
    if not gpio_edge_hit(0x1, 0x0, 0x1):
        raise AssertionError("rising edge")
    if gpio_edge_hit(0x1, 0x1, 0x0):
        raise AssertionError("rising mode ignored a fall")
    if not gpio_edge_hit(0x2, 0x1, 0x0):
        raise AssertionError("falling edge")
    if not gpio_edge_hit(0x3, 0x0, 0x1) or not gpio_edge_hit(0x3, 0x1, 0x0):
        raise AssertionError("both-edges mode")
    if gpio_edge_hit(0x0, 0x0, 0x1):
        raise AssertionError("off mode")
    # A second byte does not replace the first.
    uart = UartRx()
    uart.push(0x11)
    uart.push(0x22)
    peeked = ((1 << 31) | (1 << 30) | 0x11)
    if uart.read() != peeked:
        raise AssertionError("overrun must keep the first byte")


def main(argv: list[str]) -> int:
    if "--self-check" in argv:
        self_check()
        print("mpy_periph_model self-check ok")
        return 0
    if "--plusargs" in argv:
        print(plusargs())
        return 0
    self_check()
    print(plusargs())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
