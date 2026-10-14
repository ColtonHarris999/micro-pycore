"""First native builtins for uPyCore: ``print``, ``sys``, and import."""

from __future__ import annotations

from . import sys
from .format import format_print, format_value
from .importer import import_name
from .printer import print

__all__ = [
    "format_print",
    "format_value",
    "import_name",
    "print",
    "sys",
]
