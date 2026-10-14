"""Host model for the phase-5 peripheral map.

Edge masks come from this model. The unix ``machine`` module is not used.
"""

from __future__ import annotations

import unittest

from pycore.tools.mpy_periph_model import (
    blink_edge_mask,
    echo_result,
    plusargs,
    schedule_raise_at,
    self_check,
)


class MpyPeriphModelTest(unittest.TestCase):
    def test_self_check(self) -> None:
        self_check()

    def test_plusargs_match_the_model(self) -> None:
        text = plusargs()
        mask = blink_edge_mask(4, 20)
        tx_word, tx_n, overrun = echo_result()
        self.assertIn(f"+EXPECT_EDGE_MASK={mask}", text)
        self.assertIn("+EXPECT_OFF_MASK=0", text)
        self.assertIn(f"+EXPECT_TX_WORD={tx_word}", text)
        self.assertIn(f"+EXPECT_TXN={tx_n}", text)
        self.assertIn(f"+EXPECT_OVERRUN={overrun}", text)
        self.assertIn(f"+EXPECT_SCHED_RAISE_AT={schedule_raise_at()}", text)
        self.assertEqual(overrun, 1)
        self.assertEqual(tx_n, 3)


if __name__ == "__main__":
    unittest.main()
