"""Import of native modules.

Built-in modules are native. This slice provides ``sys`` only. The standard
library is not rewritten: a name that is not native is absent. Import does
not open a path. A missing name raises ``ImportError`` with the pin's
normal-reporting message.
"""

from __future__ import annotations

from . import sys as sys_module

_NATIVE: dict[str, object] = {"sys": sys_module}


def import_name(name: str, level: int = 0) -> object:
    if not isinstance(name, str):
        raise TypeError("module name must be a str")
    if level != 0 or name.startswith("."):
        raise ImportError("can't perform relative import")
    loaded = sys_module.modules.get(name)
    if loaded is not None:
        return loaded
    native = _NATIVE.get(name)
    if native is not None:
        sys_module.modules[name] = native
        return native
    raise ImportError(f"no module named '{name}'")
