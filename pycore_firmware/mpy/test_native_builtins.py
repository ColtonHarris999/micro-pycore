"""Host tests for the first native builtins.

The formatter prints 1, -1, True, False, and None with the newline byte.
``sys.platform`` reads ``upycore``.
"""

from __future__ import annotations

import builtins
import unittest
from pathlib import Path

from pycore_firmware.mpy import format_print, import_name, print, sys
from pycore_firmware.mpy.encoding import (
    MP_NATIVE_ARCH_NONE,
    MP_SMALL_INT_BITS,
    MPY_SUB_VERSION,
    SYS_IMPLEMENTATION_MPY,
    advertised,
    bytecode_header,
    mpy_arch,
    mpy_feature_decode_arch,
    mpy_feature_decode_sub_version,
    mpy_version,
)
from pycore_firmware.mpy.uart import UART_TX, reset, stores, tx_bytes


class NativeBuiltinTest(unittest.TestCase):
    def setUp(self) -> None:
        reset()
        sys.modules.clear()
        sys.modules["sys"] = sys

    def test_formatter_prints_immediates_with_newline(self) -> None:
        self.assertEqual(UART_TX, 0x40000000)
        cases = (
            (1, b"1\n"),
            (-1, b"-1\n"),
            (True, b"True\n"),
            (False, b"False\n"),
            (None, b"None\n"),
            (0, b"0\n"),
            (10, b"10\n"),
            (-42, b"-42\n"),
        )
        for value, expected in cases:
            self.assertEqual(format_print(value), expected)
            self.assertEqual(expected[-1], 0x0A)
            reset()
            self.assertIsNone(print(value))
            logged = stores()
            self.assertEqual(len(logged), len(expected))
            self.assertEqual(tx_bytes(), expected)
            self.assertTrue(all(address == UART_TX for address, _byte in logged))
            self.assertEqual(logged[-1], (UART_TX, 0x0A))
        reset()
        for value in (1, -1, True, False, None):
            print(value)
        self.assertEqual(tx_bytes(), b"1\n-1\nTrue\nFalse\nNone\n")

    def test_platform_upycore(self) -> None:
        self.assertEqual(sys.platform, "upycore")
        self.assertEqual(sys.implementation.name, "upycore")

    def test_mpy_advertises_pin_encoding(self) -> None:
        mpy = sys.implementation._mpy
        self.assertEqual(mpy, SYS_IMPLEMENTATION_MPY)
        self.assertEqual(mpy, 0x0306)
        self.assertEqual(mpy_version(mpy), 6)
        self.assertEqual(mpy_arch(mpy), MP_NATIVE_ARCH_NONE)
        feature = (mpy >> 8) & 0xFF
        self.assertEqual(mpy_feature_decode_arch(feature), MP_NATIVE_ARCH_NONE)
        self.assertEqual(mpy_feature_decode_sub_version(feature), MPY_SUB_VERSION)
        self.assertEqual(mpy >> 16, 0)
        self.assertEqual(MP_SMALL_INT_BITS, 31)
        self.assertEqual(bytecode_header(), b"\x4d\x06\x00\x1f")
        self.assertEqual(advertised(mpy), (6, MP_NATIVE_ARCH_NONE, 31))

    def test_missing_import_raises_import_error(self) -> None:
        opened: list[object] = []
        real_open = builtins.open

        def guard(*args: object, **kwargs: object) -> object:
            opened.append(args)
            raise AssertionError("import opened a path")

        builtins.open = guard  # type: ignore[assignment]
        try:
            for name in ("json", "os", "re", "math", "time", "machine"):
                with self.assertRaises(ImportError) as caught:
                    import_name(name)
                self.assertEqual(str(caught.exception), f"no module named '{name}'")
                self.assertNotIn(name, sys.modules)
            with self.assertRaises(ImportError) as relative:
                import_name("other", level=1)
            self.assertEqual(str(relative.exception), "can't perform relative import")
        finally:
            builtins.open = real_open
        self.assertEqual(opened, [])

    def test_import_sys_is_cached(self) -> None:
        first = import_name("sys")
        self.assertIs(first, sys)
        self.assertEqual(first.platform, "upycore")
        sentinel = object()
        sys.modules["sys"] = sentinel
        second = import_name("sys")
        self.assertIs(second, sentinel)
        del sys.modules["sys"]
        restored = import_name("sys")
        self.assertIs(restored, sys)
        self.assertIs(sys.modules["sys"], sys)

    def test_stdout_write_stores_uart_tx(self) -> None:
        n = sys.stdout.write("upycore")
        self.assertEqual(n, 7)
        self.assertEqual(tx_bytes(), b"upycore")
        self.assertTrue(all(address == UART_TX for address, _byte in stores()))

    def test_exit_and_print_exception(self) -> None:
        with self.assertRaises(SystemExit) as caught:
            sys.exit()
        self.assertEqual(caught.exception.args, ())
        sys.print_exception(ImportError("no module named 'json'"))
        self.assertEqual(tx_bytes(), b"ImportError: no module named 'json'\n")

    def test_sources_do_not_call_the_second_hart(self) -> None:
        root = Path(__file__).resolve().parent
        forbidden = ("ex" + "core", "_bi_" + "print", "CONSOLE_" + "TX")
        for path in root.glob("*.py"):
            if path.name.startswith("test_"):
                continue
            text = path.read_text(encoding="utf-8")
            for word in forbidden:
                self.assertNotIn(word, text, path.name)


if __name__ == "__main__":
    unittest.main()
