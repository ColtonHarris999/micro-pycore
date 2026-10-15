# Shared helpers: value inspection, raw object access, and string building.
#
# Firmware modules are joined into one module after _abi.py (see
# pycore/tools/mpy_build.py), so every const() there folds into this code.
# A firmware function may not store globals: state lives in SYSROOT words.
# Names without a leading underscore become builtins.
from micropython import const
from ._abi import *

HDR_CHARS_ADDR = const(44)       # 4 * HDR_CHARS
HDR_QDESC_ADDR = const(16)       # 4 * HDR_QSTR_DESC
HDR_MAIN_ADDR = const(20)        # 4 * HDR_MAIN_MODULE
HDR_EMPTY_ADDR = const(48)       # 4 * HDR_EMPTY_TUPLE
HDR_FROZEN_ADDR = const(32)      # 4 * HDR_FROZEN
SR_MODS_ADDR = const(536903828)  # SYSROOT + 4 * SR_MODULES
SR_FW0_ADDR = const(536903856)   # SYSROOT + 4 * SR_FW0
SR_EMERG_ADDR = const(536903872)  # SYSROOT + 4 * SR_EMERG
INT32_MIN = const(-2147483648)
FLT_SIGN = const(-2147483648)
OB_ITEROBJ = const(20)
_U32 = 4294967296
# Default-argument sentinel. NULL itself is injected by the linker and is
# not a name the module body can load.
_MISSING = (0,)


def _kind(x):
    if _tag(x) == TAG_OBJECT:
        return _ld(x, 0)
    return 0


def _istype(x):
    return _tag(x) == TAG_OBJECT and _ld(x, 0) == OB_TYPE


def _isstr(x):
    t = _tag(x)
    return t == TAG_QSTR or t == TAG_STR


def _isint(x):
    t = _tag(x)
    return t == TAG_INT or t == TAG_INT64 or (t == TAG_CONTROL and (_pay(x) == CTL_TRUE or _pay(x) == CTL_FALSE))


def _isbool(x):
    return x is True or x is False


def _ismut(x, k):
    return _tag(x) == TAG_MUT and (_pay(x) & 3) == k


def _islist(x):
    return _tag(x) == TAG_MUT and (_pay(x) & 3) == MUT_LIST


def _isdict(x):
    return _tag(x) == TAG_MUT and (_pay(x) & 3) == MUT_DICT


def _isset(x):
    return _tag(x) == TAG_MUT and (_pay(x) & 3) == MUT_SET


def _isbarr(x):
    return _tag(x) == TAG_MUT and (_pay(x) & 3) == MUT_BYTEARRAY


def _isinst(x):
    # A Python-level instance (user class) or an exception object.
    if _tag(x) != TAG_OBJECT:
        return False
    k = _ld(x, 0)
    return k == OB_INSTANCE or k == OB_EXCEPTION


def _isuser(x):
    # An instance of a class made by __build_class__.
    return _isinst(x) and (_ld(_ld(x, 1), 7) & TF_USER) != 0


def _tname(x):
    return _ld(_typeof(x), 4)


def _tflags(t):
    return _ld(t, 7)


def _tid(t):
    return _ld(t, 6)


def _ntype(i):
    # Native type object with type id i.
    return _ld(TYPE_TABLE, i)


def _native_base(t):
    # The first native type in t's mro (object when there is none).
    mro = _ld(t, 5)
    n = _ld(mro, 0)
    i = 0
    while i < n:
        b = _ld(mro, 1 + i)
        if not (_ld(b, 7) & TF_USER):
            return b
        i += 1
    return object


def _strue(x):
    return x is not NULL and x is not None


# ---------------------------------------------------------------------------
# Strings

def _ch(b):
    # One-character str for byte b < 128.
    return _mk(TAG_QSTR, _peek32(_peek32(HDR_CHARS_ADDR) + 4 * b))


def _qstr_ascii(q):
    return _peek32(_peek32(HDR_QDESC_ADDR) + 8 * _pay(q) + 4) >= 0


def _ascii(s):
    # True when every byte of str s is ASCII.
    if _tag(s) == TAG_QSTR:
        return _qstr_ascii(s)
    return (_pay(_ld(s, 1)) & STR_NONASCII) == 0


def _newstr(n):
    return _strnew(n, TAG_STR)


def _fin(s, n):
    # Finish a str built in a buffer of at least n bytes.
    _st(s, 0, n)
    return _strfin(s)


def _cat(a, b):
    la = _slen(a)
    if la == 0:
        return b
    lb = _slen(b)
    if lb == 0:
        return a
    s = _strnew(la + lb, _tag(a) if _tag(a) == TAG_BYTES else TAG_STR)
    _bcopy(s, 0, a, 0, la)
    _bcopy(s, la, b, 0, lb)
    return _strfin(s)


def _join(parts):
    # Concatenate a list or tuple of str values.
    n = 0
    for p in parts:
        n += _slen(p)
    s = _strnew(n, TAG_STR)
    o = 0
    for p in parts:
        k = _slen(p)
        _bcopy(s, o, p, 0, k)
        o += k
    return _strfin(s)


def _s(*parts):
    return _join(parts)


def _substr(s, start, stop, tag):
    # Bytes [start, stop) of s as a new str/bytes with the given tag.
    n = stop - start
    if n <= 0:
        return '' if tag != TAG_BYTES else b''
    if n == 1 and tag != TAG_BYTES:
        b = _peek8(_data(s), start)
        if b < 128:
            return _ch(b)
    r = _strnew(n, tag)
    _bcopy(r, 0, s, start, n)
    return _strfin(r)


def _byte(s, i):
    return _peek8(_data(s), i)


def _streq(a, b):
    n = _slen(a)
    if n != _slen(b):
        return False
    return _bcmp(a, b) == 0


def _find_bytes(s, sub, start, end):
    # Index of sub in s[start:end] (byte offsets), or -1.
    n = _slen(sub)
    if n == 0:
        return start if start <= end else -1
    ds = _data(s)
    dq = _data(sub)
    first = _peek8(dq, 0)
    i = start
    last = end - n
    while i <= last:
        if _peek8(ds, i) == first:
            j = 1
            while j < n and _peek8(ds, i + j) == _peek8(dq, j):
                j += 1
            if j == n:
                return i
        i += 1
    return -1


def _rfind_bytes(s, sub, start, end):
    n = _slen(sub)
    i = end - n
    if n == 0:
        return end if start <= end else -1
    ds = _data(s)
    dq = _data(sub)
    while i >= start:
        j = 0
        while j < n and _peek8(ds, i + j) == _peek8(dq, j):
            j += 1
        if j == n:
            return i
        i -= 1
    return -1


# ---------------------------------------------------------------------------
# Lists and tuples at the word level

def _llen(x):
    return _ld(x, 0)


def _litems(x):
    # Address-like value of the item words of a list.
    return _ld(x, 2)


def _newlist(n):
    # A list of n None-free NULL slots, len n.
    alloc = n if n > 4 else 4
    lst = _alloc(3, TAG_MUT, MUT_LIST)
    items = _alloc(alloc, TAG_CONT, 0)
    _st(lst, 0, n)
    _st(lst, 1, alloc)
    _st(lst, 2, items)
    return lst


def _list_reserve(lst, n):
    # Make room for n items in total.
    alloc = _ld(lst, 1)
    if n <= alloc:
        return
    if alloc == 0:
        alloc = 4
    while alloc < n:
        alloc = alloc * 2
    items = _alloc(alloc, TAG_CONT, 0)
    _wcopy(items, 0, _ld(lst, 2), 0, _ld(lst, 0))
    _st(lst, 2, items)
    _st(lst, 1, alloc)


def _newtuple(n):
    if n == 0:
        return ()
    t = _alloc(n + 1, TAG_TUPLE, 0)
    _st(t, 0, n)
    return t


def _tuple_of_list(lst):
    n = _ld(lst, 0)
    t = _newtuple(n)
    if n:
        _wcopy(t, 1, _ld(lst, 2), 0, n)
    return t


def _list_of_seq(x):
    # list() of a list or tuple, by word copy.
    n = _ld(x, 0)
    lst = _newlist(n)
    if n:
        if _tag(x) == TAG_TUPLE:
            _wcopy(_ld(lst, 2), 0, x, 1, n)
        else:
            _wcopy(_ld(lst, 2), 0, _ld(x, 2), 0, n)
    return lst


def _seq_items(x):
    # (address value, offset) of the items of a list or tuple, for _ld.
    if _tag(x) == TAG_TUPLE:
        return x, 1
    return _ld(x, 2), 0


def _sysget(i):
    return _ld(SYSROOT, i)


def _sysset(i, v):
    _st(SYSROOT, i, v)


def _u32(n):
    if n < 0:
        return n + _U32
    return n


def _tlookup(t, name):
    # First mro entry whose dict holds name, or NULL.
    mro = _ld(t, 5)
    n = _ld(mro, 0)
    i = 0
    while i < n:
        hit = _lookup(_ld(_ld(mro, 1 + i), 2), name)
        if hit is not NULL and hit is not STOP:
            return hit
        i += 1
    return NULL


def _subobj(inst):
    t = _ld(inst, 1)
    if _ld(t, 7) & TF_NATIVE_SUB:
        return _ld(inst, 3)
    return NULL


def _native_sub_new(cls, sub):
    o = _alloc(4, TAG_OBJECT, 0)
    _st(o, 0, OB_INSTANCE)
    _st(o, 1, cls)
    _st(o, 2, NULL)
    _st(o, 3, sub)
    return o


def _native_sub_repr(inst, nb, as_str):
    sub = _subobj(inst)
    if sub is NULL:
        return _s('<', _ld(_ld(inst, 1), 4), ' object at ', _hexaddr(_addr(inst)), '>')
    if as_str:
        return _str(sub)
    return _repr(sub)


def _callattr(f, obj):
    return f(obj)


def _call_member(f, obj, args):
    n = len(args)
    if n == 0:
        return f(obj)
    if n == 1:
        return f(obj, args[0])
    return f(obj, *args)


def _mk_module(name, g):
    m = _alloc(4, TAG_OBJECT, 0)
    _st(m, 0, OB_MODULE)
    _st(m, 1, _ntype(T_MODULE))
    _st(m, 2, g)
    _st(m, 3, name)
    return m
