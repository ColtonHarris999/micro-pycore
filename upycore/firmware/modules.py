# sys, gc, micropython, and import.
from ._abi import *


def _sys_exit(code=None):
    raise SystemExit(code)


def _sys_print_exception(exc, file=None):
    _print_tb(exc, NULL if file is None else file)
    return None


def _gc_collect():
    if _sysget(SR_FW4) is False:
        return None
    _gc()
    return None


def _gc_enable():
    _sysset(SR_FW4, True)
    return None


def _gc_disable():
    _sysset(SR_FW4, False)
    return None


def _gc_isenabled():
    return _sysget(SR_FW4) is not False


def _gc_mem_free():
    return _gcinfo(0)


def _gc_mem_alloc():
    return _gcinfo(1) - _gcinfo(0)


def _gc_threshold(amount=_MISSING):
    return -1


def _mp_const(x):
    return x


def _mp_opt(level=_MISSING):
    return 0


def _mp_total():
    return _gcinfo(1)


def _mp_current():
    return _gc_mem_alloc()


def _mp_peak():
    return _gc_mem_alloc()


def _mp_info():
    return None


def _mp_stack():
    return 0


def _mp_lock():
    return None


def _mp_unlock():
    return None


def _mp_kbd(i):
    return None


def _mp_qstr():
    return (0, 0)


def _mp_sched(func, arg):
    func(arg)
    return None


def _build_sys(filename):
    impl = _mk_module('', {
        'name': 'upycore',
        'version': (1, 29, 0, ''),
        '_machine': 'upycore',
        '_mpy': 1798,
    })
    g = {
        'argv': [filename],
        'byteorder': 'little',
        'maxsize': 1073741823 * 2 + 1,
        'platform': 'upycore',
        'version': '3.4.0; MicroPython 062cf49b48 on 2026-10-14',
        'version_info': (3, 4, 0),
        'implementation': impl,
        'modules': _sysget(SR_MODULES),
        'path': ['.', '.frozen'],
        'executable': '',
        'exit': _sys_exit,
        'print_exception': _sys_print_exception,
        'exc_info': _sys_exc_info,
    }
    return _mk_module('sys', g)


def _sys_exc_info():
    return (None, None, None)


def _build_gc():
    return _mk_module('gc', {
        'collect': _gc_collect,
        'disable': _gc_disable,
        'enable': _gc_enable,
        'isenabled': _gc_isenabled,
        'mem_alloc': _gc_mem_alloc,
        'mem_free': _gc_mem_free,
        'threshold': _gc_threshold,
    })


def _build_mp():
    return _mk_module('micropython', {
        'const': _mp_const,
        'opt_level': _mp_opt,
        'mem_total': _mp_total,
        'mem_current': _mp_current,
        'mem_peak': _mp_peak,
        'mem_info': _mp_info,
        'stack_use': _mp_stack,
        'heap_lock': _mp_lock,
        'heap_unlock': _mp_unlock,
        'kbd_intr': _mp_kbd,
        'qstr_info': _mp_qstr,
        'schedule': _mp_sched,
    })


def _dot_parts(name):
    out = []
    start = 0
    n = _slen(name)
    i = 0
    while i <= n:
        if i == n or _byte(name, i) == 46:
            if i > start:
                out.append(_substr(name, start, i, TAG_STR))
            start = i + 1
        i += 1
    return out


def _join_dots(parts):
    if not parts:
        return ''
    s = parts[0]
    i = 1
    while i < len(parts):
        s = _cat(_cat(s, '.'), parts[i])
        i += 1
    return s


def _rel_name(name, level, globs):
    base = ''
    if globs is not NULL and _isdict(globs):
        pkg = _dget(globs, '__package__')
        if pkg is NULL or pkg is None or pkg == '':
            pkg = _dget(globs, '__name__')
        if pkg is not NULL and pkg is not None and pkg != '':
            base = pkg
    parts = _dot_parts(base)
    while level > 0 and parts:
        parts.pop()
        level -= 1
    if name is not None and name != '':
        for p in _dot_parts(name):
            parts.append(p)
    return _join_dots(parts)


# Bit 1 of a module descriptor's flags word. The linker sets it for __init__.py.
_MD_FLAG_PACKAGE = 2


def _load_mod(name):
    if _streq(name, 'sys'):
        return _sysget(SR_FW1)
    if _streq(name, 'gc'):
        return _sysget(SR_FW2)
    if _streq(name, 'micropython'):
        return _sysget(SR_FW3)
    mods = _sysget(SR_MODULES)
    hit = _dget(mods, name)
    if hit is not NULL:
        return hit
    nat = _dget(_NATIVE_MODULES, name)
    if nat is not NULL:
        return nat
    fr = _dget(_FROZEN, name)
    if fr is NULL:
        return NULL
    g = {'__name__': name}
    g['__file__'] = _mk(TAG_QSTR, _peek32(fr + 4 * MD_SOURCE_FILE))
    # A package can hold submodules. __path__ is what marks it as one.
    if _peek32(fr + 4 * MD_FLAGS) & _MD_FLAG_PACKAGE:
        g['__path__'] = name
    mod = _mk_module(name, g)
    mods[name] = mod
    _callns(fr, g)
    return mod


def _import(name, fromlist, level, globs):
    if level:
        name = _rel_name(name, level, globs)
    # import a.b.c walks each level. fromlist is None for a plain import,
    # which binds the top-level package; any other fromlist returns the leaf.
    parts = _dot_parts(name)
    top = NULL
    parent = NULL
    acc = ''
    i = 0
    n = len(parts)
    while i < n:
        comp = parts[i]
        if i == 0:
            full = comp
        else:
            full = _cat(_cat(acc, '.'), comp)
        if parent is not NULL and _dget(_ld(parent, 2), '__path__') is NULL:
            raise ImportError(_s("no module named '", full, "'"))
        mod = _load_mod(full)
        if mod is NULL:
            raise ImportError(_s("no module named '", full, "'"))
        if parent is not NULL:
            _ld(parent, 2)[comp] = mod
        if top is NULL:
            top = mod
        parent = mod
        acc = full
        i += 1
    if top is NULL:
        raise ImportError(_s("no module named '", name, "'"))
    if fromlist is None:
        return top
    return parent


def _import_from(mod, name):
    g = _ld(mod, 2)
    hit = _dget(g, name)
    if hit is NULL:
        # A package may expose a submodule that is not yet an attribute.
        sub = _cat(_cat(_ld(mod, 3), '.'), name)
        try:
            hit = _import(sub, (), 0, NULL)
        except ImportError:
            hit = NULL
        if hit is NULL:
            raise ImportError(_s("can't import name ", name))
        g[name] = hit
    return hit


def _import_star(mod, loc):
    g = _ld(mod, 2)
    for k in g:
        if _slen(k) and _byte(k, 0) != 95:
            loc[k] = g[k]
    return None
