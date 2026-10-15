"""Manifest and output-mask checks. These do not boot the simulator."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "upycore" / "tools"))

import hw_tests  # noqa: E402


class MaskTest(unittest.TestCase):
    def test_masks_object_and_function_addresses(self) -> None:
        raw = b"<Foo object at 0x2000abcd> <Foo object at 2000abcd> <function f at 0x10> <cell ab>\n"
        masked = hw_tests.mask_output(raw)
        self.assertNotIn(b"2000abcd", masked)
        self.assertNotIn(b"0x10", masked)
        self.assertIn(b"object at PTR", masked)
        self.assertIn(b"at PTR", masked)
        self.assertIn(b"<cell PTR>", masked)

    def test_leaves_program_text(self) -> None:
        raw = b"hello\n0xff\nadd 5\n"
        self.assertEqual(hw_tests.mask_output(raw), raw)


class ManifestTest(unittest.TestCase):
    def test_every_program_exists_and_names_are_unique(self) -> None:
        tests = hw_tests.load_manifest()
        self.assertGreaterEqual(len(tests), 30)
        names = [t.name for t in tests]
        self.assertEqual(len(names), len(set(names)))
        for t in tests:
            self.assertTrue(t.source.is_file(), t.file)
            for path in t.golden():
                self.assertTrue(path.is_file(), path)
            for spec in t.modules:
                _name, rel = spec.split("=", 1)
                rel = rel.removesuffix(":package")
                self.assertTrue((hw_tests.PROGRAMS / rel).is_file(), spec)

    def test_select_by_area_and_glob(self) -> None:
        tests = hw_tests.load_manifest()
        alu = hw_tests.select(tests, ["alu"], [])
        self.assertTrue(alu)
        self.assertTrue(all(t.area == "alu" for t in alu))
        picked = hw_tests.select(tests, [], ["use_*"])
        self.assertEqual(sorted(t.name for t in picked), ["use_helper", "use_pkg", "use_rel"])

    def test_compare_ignores_addresses_only(self) -> None:
        detail = hw_tests.compare_streams(
            b"<Foo object at 10>\n", b"", 0,
            b"<Foo object at 0x20>\n", b"", 0,
        )
        self.assertEqual(detail, "")
        detail = hw_tests.compare_streams(b"1\n", b"", 0, b"2\n", b"", 0)
        self.assertIn("expected.stdout", detail)
        detail = hw_tests.compare_streams(b"", b"", 1, b"", b"", 0)
        self.assertIn("exit 1", detail)


if __name__ == "__main__":
    unittest.main()
