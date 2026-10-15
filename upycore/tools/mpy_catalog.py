#!/usr/bin/env python3
"""Load ``upycore/targets/upycore.json`` and check it against the pin."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
CATALOG_PATH = REPO_ROOT / "upycore" / "targets" / "upycore.json"
VENDOR_ROOT = REPO_ROOT / "vendor" / "micropython"


class CatalogError(RuntimeError):
    pass


@dataclass
class Opcode:
    name: str
    opcode: int
    fmt: str
    stack_effect: str
    phase: int | str
    signed: bool = False
    extra_byte: bool = False


@dataclass
class Catalog:
    data: dict
    opcodes: list[Opcode]
    by_opcode: dict[int, Opcode]
    names: list[str] = field(default_factory=list)

    @classmethod
    def load(cls, path: Path | None = None) -> Catalog:
        path = path or CATALOG_PATH
        data = json.loads(path.read_text(encoding="utf-8"))
        opcodes = [
            Opcode(
                name=row["name"],
                opcode=row["opcode"],
                fmt=row["format"],
                stack_effect=str(row["stack_effect"]),
                phase=row["phase"],
                signed=bool(row.get("signed", False)),
                extra_byte=bool(row.get("extra_byte", False)),
            )
            for row in data["bytecode"]["opcodes"]
        ]
        by_opcode: dict[int, Opcode] = {}
        names = ["unknown"] * 256
        for row in opcodes:
            if row.opcode in by_opcode:
                raise CatalogError(f"duplicate opcode {row.opcode}")
            by_opcode[row.opcode] = row
            names[row.opcode] = row.name
        catalog = cls(data=data, opcodes=opcodes, by_opcode=by_opcode, names=names)
        catalog._check_format_magic()
        return catalog

    def _check_format_magic(self) -> None:
        magic = self.format_magic
        fmt_of = {"byte": 0, "qstr": 1, "varuint": 2, "offset": 3}
        for row in self.opcodes:
            got = (magic >> (2 * (row.opcode >> 4))) & 3
            if got != fmt_of[row.fmt]:
                raise CatalogError(
                    f"{row.name} format {row.fmt} does not match the bytecode format word"
                )
            extra = (row.opcode & self.extra_byte_mask) == 0
            if extra != row.extra_byte:
                raise CatalogError(f"{row.name} extra-byte flag does not match the mask")

    @property
    def mpy_version(self) -> int:
        return int(self.data["mpy"]["version"])

    @property
    def mpy_sub_version(self) -> int:
        return int(self.data["mpy"]["sub_version"])

    @property
    def small_int_bits(self) -> int:
        return int(self.data["mpy"]["small_int_bits"])

    @property
    def sample_header(self) -> str:
        return self.data["mpy"]["sample_header"]

    @property
    def qstr_last_static(self) -> int:
        return int(self.data["mpy"]["qstr_last_static"])

    @property
    def static_qstrs(self) -> list[str]:
        return list(self.data["static_qstrs"])

    @property
    def architectures(self) -> list[str]:
        return list(self.data["architectures"])

    @property
    def format_magic(self) -> int:
        return int(self.data["bytecode"]["format_magic"])

    @property
    def extra_byte_mask(self) -> int:
        return int(self.data["bytecode"]["extra_byte_mask"])

    @property
    def signed_offsets(self) -> set[int]:
        return {int(op) for op in self.data["bytecode"]["signed_offset_opcodes"]}

    @property
    def int_bits(self) -> int:
        return int(self.data["runtime"]["int_bits"])

    @property
    def register_file_entries(self) -> int:
        return int(self.data["runtime"]["register_file_entries"])

    @property
    def flash_base(self) -> int:
        return int(self.data["runtime"]["flash_base"])

    @property
    def reserved_prefix(self) -> int:
        return int(self.data["runtime"]["reserved_prefix"])

    @property
    def pointer_forbidden(self) -> set[int]:
        return {int(v) for v in self.data["runtime"]["pointer_forbidden"]}

    @property
    def const_kinds(self) -> dict[str, dict]:
        return self.data["const_kinds"]

    @property
    def tags(self) -> dict[str, int]:
        return {row["name"]: int(row["tag"]) for row in self.data["tags"]}

    @property
    def control_kinds(self) -> dict[str, int]:
        return {name: int(value) for name, value in self.data["control_kinds"].items()}

    @property
    def object_kinds(self) -> dict[str, int]:
        return {name: int(value) for name, value in self.data["object_kinds"].items()}

    @property
    def raw_code_kinds(self) -> dict[str, int]:
        return {name: int(value) for name, value in self.data["raw_code_kinds"].items()}

    @property
    def feature(self) -> dict:
        return self.data["mpy"]["feature"]

    def arch_name(self, arch: int) -> str:
        if 0 <= arch < len(self.architectures):
            return self.architectures[arch]
        return "UNKNOWN"

    def opcode_name(self, opcode: int) -> str:
        if 0 <= opcode < 256:
            return self.names[opcode]
        return "unknown"

    def static_qstr(self, qstr_id: int) -> str:
        if qstr_id == 0:
            raise CatalogError("qstr id 0 is null")
        if qstr_id > self.qstr_last_static:
            raise CatalogError(f"qstr id {qstr_id} is not static")
        return self.static_qstrs[qstr_id - 1]

    def find_static_id(self, text: str) -> int | None:
        try:
            return self.static_qstrs.index(text) + 1
        except ValueError:
            return None


_DEFINE = re.compile(r"^\s*#define\s+(MP_[A-Z0-9_]+)\s+(.+?)\s*(?://.*)?$")


def _strip_comment(text: str) -> str:
    if "//" in text:
        text = text.split("//", 1)[0]
    return text.strip()


def _parse_simple_defines(path: Path) -> dict[str, int]:
    """Evaluate ``#define NAME (OTHER + 0xNN)`` chains from one header."""

    values: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = _DEFINE.match(line)
        if not match:
            continue
        name, expr = match.group(1), _strip_comment(match.group(2))
        if expr.startswith("(") and expr.endswith(")"):
            expr = expr[1:-1].strip()
        expr = expr.replace("(", "").replace(")", "")
        parts = [part.strip() for part in expr.split("+")]
        total = 0
        ok = True
        for part in parts:
            if re.fullmatch(r"0x[0-9A-Fa-f]+|\d+", part):
                total += int(part, 0)
            elif part in values:
                total += values[part]
            else:
                ok = False
                break
        if ok:
            values[name] = total
    return values


def verify_against_pin(catalog: Catalog, vendor: Path | None = None) -> None:
    """Raise CatalogError when the JSON disagrees with the pinned sources."""

    vendor = vendor or VENDOR_ROOT
    persistent = (vendor / "py" / "persistentcode.h").read_text(encoding="utf-8")
    version = re.search(r"#define\s+MPY_VERSION\s+(\d+)", persistent)
    sub = re.search(r"#define\s+MPY_SUB_VERSION\s+(\d+)", persistent)
    if version is None or sub is None:
        raise CatalogError("persistentcode.h is missing MPY_VERSION")
    if int(version.group(1)) != catalog.mpy_version or int(sub.group(1)) != catalog.mpy_sub_version:
        raise CatalogError("catalog .mpy version does not match persistentcode.h")

    defines = _parse_simple_defines(vendor / "py" / "bc0.h")
    for row in catalog.opcodes:
        macro = "MP_BC_" + row.name
        if macro in defines and defines[macro] != row.opcode:
            raise CatalogError(f"{macro} is {defines[macro]} in bc0.h and {row.opcode} in the catalog")

    # Multi-opcode windows are named with a suffix in the catalog. Check the bases.
    windows = catalog.data["bytecode"]["windows"]
    for key, macro in (
        ("small_int", "MP_BC_LOAD_CONST_SMALL_INT_MULTI"),
        ("load_fast", "MP_BC_LOAD_FAST_MULTI"),
        ("store_fast", "MP_BC_STORE_FAST_MULTI"),
        ("unary", "MP_BC_UNARY_OP_MULTI"),
        ("binary", "MP_BC_BINARY_OP_MULTI"),
    ):
        if defines[macro] != int(windows[key]["base"]):
            raise CatalogError(f"{macro} does not match the catalog window")

    import sys

    sys.path.insert(0, str(vendor / "py"))
    try:
        import makeqstrdata as qstrs
    finally:
        sys.path.pop(0)
    if list(qstrs.static_qstr_list) != catalog.static_qstrs:
        raise CatalogError("static qstr snapshot does not match py/makeqstrdata.py")
    if catalog.qstr_last_static != len(catalog.static_qstrs):
        raise CatalogError("qstr_last_static is not the id of the last static qstr")
    if catalog.static_qstrs[-1] != "zip":
        raise CatalogError("static qstr list does not end at zip")

    enum = re.search(
        r"enum\s*\{(?P<body>.*?MP_PERSISTENT_OBJ_TUPLE\s*,)\s*\}",
        persistent,
        re.S,
    )
    if enum is None:
        raise CatalogError("const-kind enum missing from persistentcode.h")
    kind_names = re.findall(r"MP_PERSISTENT_OBJ_([A-Z0-9_]+)", enum.group("body"))
    catalog_kinds = catalog.const_kinds
    for index, name in enumerate(kind_names):
        key = name.lower()
        if key not in catalog_kinds or int(catalog_kinds[key]["id"]) != index:
            raise CatalogError(f"const kind {name} is not catalog id {index}")
