# Iterators: the object _getiter returns, and enumerate/zip/map/filter/reversed.
from ._abi import *


def _mk_riter(seq, kind, extra):
    it = _alloc(4, TAG_ITER, 0)
    _st(it, 0, seq)
    _st(it, 1, 0)
    _st(it, 2, extra)
    _st(it, 3, kind)
    return it


def _getiter(x):
    t = _tag(x)
    if t == TAG_ITER:
        return x
    if t == TAG_TUPLE or t == TAG_BYTES or _islist(x) or _isbarr(x):
        return _mk_riter(x, IT_SEQ, 0)
    if _isdict(x):
        return _mk_riter(x, IT_DICT, 0)
    if _isset(x):
        return _mk_riter(x, IT_SET, 0)
    if t == TAG_RANGE:
        it = _alloc(4, TAG_ITER, 0)
        _st(it, 0, _ld(x, 0))
        _st(it, 1, _ld(x, 1))
        _st(it, 2, _ld(x, 2))
        _st(it, 3, IT_RANGE)
        return it
    if _isstr(x):
        if _ascii(x):
            return _mk_riter(x, IT_STR, 0)
        return _str_iter(x)
    if t == TAG_OBJECT:
        k = _ld(x, 0)
        if k == OB_DICT_VIEW:
            return _mk_riter(_ld(x, 2), IT_DICT, _ld(x, 3))
        if k == OB_ITEROBJ:
            return x
        typ = _ld(x, 1)
        f = _tlookup(typ, '__iter__')
        if f is not NULL:
            return _call_member(f, x, ())
        if _tlookup(typ, '__next__') is not NULL:
            return x
        sub = _subobj(x)
        if sub is not NULL:
            return _getiter(sub)
    _not_iterable(x)


def _tuple(x):
    if _tag(x) == TAG_TUPLE:
        return x
    return _tuple_of_list(_list_of_iter(x))


def _unpack(x, arg, ex):
    seq = _list_of_iter(x)
    n = len(seq)
    if ex:
        nleft = arg & 255
        nright = (arg >> 8) & 255
        if n < nleft + nright:
            raise ValueError(_s('need more than ', _istr(n), ' values to unpack'))
        out = []
        i = 0
        while i < nleft:
            out.append(seq[i])
            i += 1
        mid = []
        while i < n - nright:
            mid.append(seq[i])
            i += 1
        out.append(mid)
        while i < n:
            out.append(seq[i])
            i += 1
        return _tuple_of_list(out)
    if n < arg:
        raise ValueError(_s('need more than ', _istr(n), ' values to unpack'))
    if n > arg:
        raise ValueError(_s('too many values to unpack (expected ', _istr(arg), ')'))
    return _tuple_of_list(seq)


def _pull(it):
    if _tag(it) == TAG_ITER:
        v = _inext(it)
        if v is STOP:
            raise StopIteration()
        return v
    if _tag(it) != TAG_OBJECT:
        raise TypeError(_s("'", _tname(it), "' object is not an iterator"))
    f = _tlookup(_ld(it, 1), '__next__')
    if f is NULL:
        raise TypeError(_s("'", _tname(it), "' object is not an iterator"))
    return _call_member(f, it, ())


def _str_iter(s):
    o = _alloc(5, TAG_OBJECT, 0)
    _st(o, 0, OB_ITEROBJ)
    _st(o, 1, _ntype(T_ITERATOR))
    _st(o, 2, s)
    _st(o, 3, 0)
    return o


def iterator____next__(self):
    if _ld(self, 4) == 1:
        v = _ld(self, 2)()
        if v == _ld(self, 3):
            raise StopIteration()
        return v
    s = _ld(self, 2)
    i = _ld(self, 3)
    n = _slen(s)
    if i >= n:
        raise StopIteration()
    c, k = _utf8_at(_data(s), i)
    _st(self, 3, i + k)
    return _chr_code(c)


def enumerate____new__(cls, iterable, start=0):
    o = _alloc(5, TAG_OBJECT, 0)
    _st(o, 0, OB_ITEROBJ)
    _st(o, 1, cls)
    _st(o, 2, iter(iterable))
    _st(o, 3, start)
    return o


def enumerate____next__(self):
    v = _pull(_ld(self, 2))
    n = _ld(self, 3)
    _st(self, 3, n + 1)
    return (n, v)


def _iter_list(args):
    its = _newlist(len(args))
    i = 0
    while i < len(args):
        _st(_ld(its, 2), i, iter(args[i]))
        i += 1
    return its


def zip____new__(cls, *args):
    o = _alloc(4, TAG_OBJECT, 0)
    _st(o, 0, OB_ITEROBJ)
    _st(o, 1, cls)
    _st(o, 2, _iter_list(args))
    return o


def zip____next__(self):
    its = _ld(self, 2)
    n = _ld(its, 0)
    t = _newtuple(n)
    i = 0
    while i < n:
        _st(t, 1 + i, _pull(_ld(_ld(its, 2), i)))
        i += 1
    return t


def map____new__(cls, func, *args):
    o = _alloc(5, TAG_OBJECT, 0)
    _st(o, 0, OB_ITEROBJ)
    _st(o, 1, cls)
    _st(o, 2, func)
    _st(o, 3, _iter_list(args))
    return o


def map____next__(self):
    its = _ld(self, 3)
    n = _ld(its, 0)
    args = _newtuple(n)
    i = 0
    while i < n:
        _st(args, 1 + i, _pull(_ld(_ld(its, 2), i)))
        i += 1
    return _ld(self, 2)(*args)


def filter____new__(cls, func, iterable):
    o = _alloc(5, TAG_OBJECT, 0)
    _st(o, 0, OB_ITEROBJ)
    _st(o, 1, cls)
    _st(o, 2, func)
    _st(o, 3, iter(iterable))
    return o


def filter____next__(self):
    func = _ld(self, 2)
    it = _ld(self, 3)
    while True:
        v = _pull(it)
        if func is None:
            ok = True if v else False
        else:
            ok = True if func(v) else False
        if ok:
            return v


def reversed____new__(cls, seq):
    if _tag(seq) == TAG_OBJECT:
        f = _tlookup(_ld(seq, 1), '__reversed__')
        if f is not NULL:
            return _call_member(f, seq, ())
    n = len(seq)
    o = _alloc(5, TAG_OBJECT, 0)
    _st(o, 0, OB_ITEROBJ)
    _st(o, 1, cls)
    _st(o, 2, seq)
    _st(o, 3, n - 1)
    return o


def reversed____next__(self):
    i = _ld(self, 3)
    if i < 0:
        raise StopIteration()
    v = _ld(self, 2)[i]
    _st(self, 3, i - 1)
    return v


def _chr_code(c):
    if c < 128:
        return _ch(c)
    # UTF-8 encode one code point into a fresh str.
    if c < 0x800:
        n = 2
    elif c < 0x10000:
        n = 3
    else:
        n = 4
    s = _strnew(n, TAG_STR)
    d = _data(s)
    if n == 2:
        _poke8(d, 0, 0xC0 | (c >> 6))
        _poke8(d, 1, 0x80 | (c & 0x3F))
    elif n == 3:
        _poke8(d, 0, 0xE0 | (c >> 12))
        _poke8(d, 1, 0x80 | ((c >> 6) & 0x3F))
        _poke8(d, 2, 0x80 | (c & 0x3F))
    else:
        _poke8(d, 0, 0xF0 | (c >> 18))
        _poke8(d, 1, 0x80 | ((c >> 12) & 0x3F))
        _poke8(d, 2, 0x80 | ((c >> 6) & 0x3F))
        _poke8(d, 3, 0x80 | (c & 0x3F))
    return _strfin(s)
