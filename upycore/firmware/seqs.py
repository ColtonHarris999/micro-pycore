# Lists, tuples, and ranges.
from ._abi import *


def _list_of_iter(x):
    if _islist(x):
        return _list_of_seq(x)
    if _tag(x) == TAG_TUPLE:
        return _list_of_seq(x)
    if _isstr(x) or _tag(x) == TAG_BYTES or _isbarr(x):
        out = []
        for ch in x:
            out.append(ch)
        return out
    out = []
    for a in x:
        out.append(a)
    return out


def _list_extend(lst, it):
    if it is lst:
        it = _list_of_seq(lst)
    for a in it:
        lst.append(a)
    return None


def list____new__(cls, *args):
    if cls is not list:
        return _nsub_new(cls, *args)
    if len(args) > 1:
        _arg_count(1, len(args))
    lst = _newlist(0)
    _st(lst, 0, 0)
    if args:
        _list_extend(lst, args[0])
    return lst


def list____init__(self, *args):
    if len(args) > 1:
        _arg_count(1, len(args))
    target = _subobj(self)
    if target is NULL:
        target = self
    if args:
        _list_extend(target, args[0])
    return None


def _list__append_fb(self, *args):
    _arg_count(2, 1 + len(args))


def list__clear(self):
    _st(self, 0, 0)
    return None


def list__copy(self):
    return _list_of_seq(self)


def list__count(self, value):
    n = 0
    for a in self:
        if a == value:
            n += 1
    return n


def list__extend(self, iterable):
    return _list_extend(self, iterable)


def list__index(self, value, start=0, stop=_MISSING):
    n = _ld(self, 0)
    if start < 0:
        start += n
        if start < 0:
            start = 0
    if stop == _MISSING:
        stop = n
    elif stop < 0:
        stop += n
    items = _ld(self, 2)
    i = start
    while i < stop and i < n:
        if _ld(items, i) == value:
            return i
        i += 1
    raise ValueError(_s(_repr(value), ' is not in list'))


def list__insert(self, index, value):
    n = _ld(self, 0)
    if index < 0:
        index += n
        if index < 0:
            index = 0
    if index > n:
        index = n
    _list_reserve(self, n + 1)
    items = _ld(self, 2)
    i = n
    while i > index:
        _st(items, i, _ld(items, i - 1))
        i -= 1
    _st(items, index, value)
    _st(self, 0, n + 1)
    return None


def list__pop(self, index=-1):
    n = _ld(self, 0)
    if n == 0:
        raise IndexError('pop from empty list')
    if index < 0:
        index += n
    if index < 0 or index >= n:
        raise IndexError('pop index out of range')
    items = _ld(self, 2)
    v = _ld(items, index)
    i = index
    while i < n - 1:
        _st(items, i, _ld(items, i + 1))
        i += 1
    _st(self, 0, n - 1)
    return v


def list__remove(self, value):
    i = list__index(self, value)
    list__pop(self, i)
    return None


def list__reverse(self):
    items = _ld(self, 2)
    a = 0
    b = _ld(self, 0) - 1
    while a < b:
        t = _ld(items, a)
        _st(items, a, _ld(items, b))
        _st(items, b, t)
        a += 1
        b -= 1
    return None


def list__sort(self, key=None, reverse=False):
    n = _ld(self, 0)
    items = _ld(self, 2)
    keys = None
    if key is not None:
        keys = _newlist(n)
        i = 0
        while i < n:
            _st(_ld(keys, 2), i, key(_ld(items, i)))
            i += 1
    i = 1
    while i < n:
        j = i
        while j > 0:
            if keys is None:
                a = _ld(items, j - 1)
                b = _ld(items, j)
            else:
                a = _ld(_ld(keys, 2), j - 1)
                b = _ld(_ld(keys, 2), j)
            swap = (b < a) if not reverse else (a < b)
            if not swap:
                break
            t = _ld(items, j - 1)
            _st(items, j - 1, _ld(items, j))
            _st(items, j, t)
            if keys is not None:
                kt = _ld(_ld(keys, 2), j - 1)
                _st(_ld(keys, 2), j - 1, _ld(_ld(keys, 2), j))
                _st(_ld(keys, 2), j, kt)
            j -= 1
        i += 1
    return None


def tuple____new__(cls, *args):
    if len(args) > 1:
        _arg_count(1, len(args))
    if len(args) == 0:
        t = ()
    elif _tag(args[0]) == TAG_TUPLE and cls is tuple:
        t = args[0]
    else:
        t = _tuple_of_list(_list_of_iter(args[0]))
    if cls is not tuple:
        return _native_sub_new(cls, t)
    return t


def tuple__count(self, value):
    n = 0
    for a in self:
        if a == value:
            n += 1
    return n


def tuple__index(self, value, start=0, stop=_MISSING):
    n = _ld(self, 0)
    if start < 0:
        start += n
    if stop == _MISSING:
        stop = n
    elif stop < 0:
        stop += n
    i = start
    while i < stop and i < n:
        if _ld(self, 1 + i) == value:
            return i
        i += 1
    raise ValueError(_s(_repr(value), ' is not in tuple'))


def _range_len(r):
    start = _ld(r, 0)
    stop = _ld(r, 1)
    step = _ld(r, 2)
    if step > 0:
        if start >= stop:
            return 0
        return (stop - start - 1) // step + 1
    if step < 0:
        if start <= stop:
            return 0
        return (start - stop - 1) // (-step) + 1
    raise ValueError('zero step')


def _range_at(r, i):
    n = _range_len(r)
    if i < 0:
        i += n
    if i < 0 or i >= n:
        raise IndexError('range index out of range')
    return _ld(r, 0) + i * _ld(r, 2)


def _range_slice(r, sl):
    n = _range_len(r)
    a, b, s = _slice_range(sl, n)
    start = _ld(r, 0)
    step = _ld(r, 2)
    ns = start + a * step
    nstep = step * s
    nstop = start + b * step
    return range(ns, nstop, nstep)


def _new__range_fb(*args):
    raise TypeError("unsupported argument type for range")


def _len_fb(x):
    t = _tag(x)
    if t == TAG_RANGE:
        return _range_len(x)
    if _isbarr(x):
        return _ld(x, 0)
    if _isstr(x):
        return _utf8_len(x)
    if t == TAG_OBJECT:
        k = _ld(x, 0)
        if k == OB_DICT_VIEW:
            return _ld(_ld(x, 2), 0)
        if k == OB_INSTANCE or k == OB_EXCEPTION:
            f = _tlookup(_ld(x, 1), '__len__')
            if f is not NULL:
                return _call_member(f, x, ())
            sub = _subobj(x)
            if sub is not NULL:
                return len(sub)
    raise TypeError(_s("object of type '", _tname(x), "' has no len()"))
