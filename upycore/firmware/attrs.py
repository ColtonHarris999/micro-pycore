# Attribute and subscript fallbacks. The core resolves instance dicts and
# plain methods itself; everything else (descriptors, special names, slices,
# __getitem__) comes through these hooks.
from ._abi import *


def _bind_method(fun, self):
    k = _kind(fun)
    if k != OB_FUNCTION and k != OB_BUILTIN:
        return fun
    m = _alloc(4, TAG_OBJECT, 0)
    _st(m, 0, OB_BOUND_METHOD)
    _st(m, 1, _ntype(T_BOUND_METHOD))
    _st(m, 2, fun)
    _st(m, 3, self)
    return m


def _desc_get(desc, obj):
    k = _kind(desc)
    if k == OB_FUNCTION or k == OB_BUILTIN:
        if _istype(obj):
            return desc
        return _bind_method(desc, obj)
    if k == OB_PROPERTY:
        if _istype(obj):
            return desc
        fget = _ld(desc, 2)
        if fget is NULL:
            raise AttributeError('unreadable attribute')
        return fget(obj)
    if k == OB_STATICMETHOD:
        return _ld(desc, 2)
    if k == OB_CLASSMETHOD:
        owner = obj if _istype(obj) else _ld(obj, 1)
        return _bind_method(_ld(desc, 2), owner)
    get = _tlookup(_ld(desc, 1), '__get__')
    if get is NULL:
        return desc
    if _istype(obj):
        return _call_member(get, desc, (None, obj))
    return _call_member(get, desc, (obj, _ld(obj, 1)))


def _special_attr(obj, name):
    t = _tag(obj)
    if t == TAG_RANGE:
        if _streq(name, 'start'):
            return _ld(obj, 0)
        if _streq(name, 'stop'):
            return _ld(obj, 1)
        if _streq(name, 'step'):
            return _ld(obj, 2)
        return NULL
    if t == TAG_COMPLEX:
        if _streq(name, 'real'):
            return _mk(TAG_FLOAT, _pay(_ld(obj, 0)))
        if _streq(name, 'imag'):
            return _mk(TAG_FLOAT, _pay(_ld(obj, 1)))
        return NULL
    if t != TAG_OBJECT:
        return NULL
    k = _ld(obj, 0)
    if k == OB_TYPE:
        if _streq(name, '__name__') or _streq(name, '__qualname__'):
            hit = _lookup(_ld(obj, 2), name)
            if hit is not NULL and hit is not STOP:
                return hit
            return _ld(obj, 4)
        if _streq(name, '__bases__'):
            return _ld(obj, 3)
        if _streq(name, '__dict__'):
            return dict__copy(_ld(obj, 2))
        if _streq(name, '__module__'):
            hit = _lookup(_ld(obj, 2), name)
            if hit is not NULL and hit is not STOP:
                return hit
            return NULL
    if k == OB_INSTANCE or k == OB_EXCEPTION:
        if _streq(name, '__class__'):
            return _ld(obj, 1)
        if _streq(name, '__dict__'):
            d = _ld(obj, 2 if k == OB_INSTANCE else 4)
            if d is NULL:
                d = {}
                _st(obj, 2 if k == OB_INSTANCE else 4, d)
            return d
        if k == OB_EXCEPTION and _streq(name, 'args'):
            return _ld(obj, 2)
        if k == OB_EXCEPTION and (_streq(name, 'value') or _streq(name, 'errno')):
            args = _ld(obj, 2)
            if len(args) == 0:
                return None
            return args[0]
    if k == OB_FUNCTION or k == OB_BUILTIN:
        if _streq(name, '__name__'):
            if k == OB_BUILTIN:
                return _ld(obj, 4)
            return _rc_name(obj)
        return NULL
    if k == OB_BOUND_METHOD:
        if _streq(name, '__name__'):
            return _getattr(_ld(obj, 2), '__name__')
        return NULL
    if k == OB_SUPER:
        return _super_attr(_ld(obj, 2), _ld(obj, 3), name)
    if k == OB_MODULE:
        return NULL
    typ = obj if _istype(obj) else (_ld(obj, 1) if _tag(obj) == TAG_OBJECT else NULL)
    if typ is not NULL and _istype(typ):
        if _streq(name, 'fromkeys') and _issub(typ, dict):
            return _bind_method(_dict_fromkeys, typ)
        if _streq(name, 'from_bytes') and _issub(typ, int):
            return _bind_method(_int_from_bytes, typ)
    return NULL


def _getattr(obj, name):
    spec = _special_attr(obj, name)
    if spec is not NULL:
        return spec
    if _tag(obj) != TAG_OBJECT:
        _attr_error(obj, name)
    if _istype(obj):
        found = _tlookup(obj, name)
        if found is not NULL:
            return _desc_get(found, obj)
        _attr_error(obj, name)
    k = _ld(obj, 0)
    if k == OB_INSTANCE or k == OB_EXCEPTION:
        found = _tlookup(_ld(obj, 1), name)
        if found is not NULL:
            return _desc_get(found, obj)
        if not (_streq(name, '__setattr__') or _streq(name, '__delattr__')):
            g = _tlookup(_ld(obj, 1), '__getattr__')
            if g is not NULL:
                return _call_member(g, obj, (name,))
    elif k == OB_MODULE:
        pass
    else:
        found = _tlookup(_ld(obj, 1), name)
        if found is not NULL:
            return _desc_get(found, obj)
    _attr_error(obj, name)


def _inst_dict(obj):
    k = _ld(obj, 0)
    slot = 4 if k == OB_EXCEPTION else 2
    d = _ld(obj, slot)
    if d is NULL:
        d = {}
        _st(obj, slot, d)
    return d


def _setattr(obj, name, value):
    if _tag(obj) != TAG_OBJECT:
        _attr_error(obj, name)
    k = _ld(obj, 0)
    if k == OB_MODULE or k == OB_TYPE:
        d = _ld(obj, 2)
        if _ld(d, 3) & DICT_FLAG_ROM:
            _attr_error(obj, name)
        if value is NULL:
            if _lookup(d, name) is NULL:
                _attr_error(obj, name)
            del d[name]
        else:
            d[name] = value
        return None
    if k != OB_INSTANCE and k != OB_EXCEPTION:
        _attr_error(obj, name)
    t = _ld(obj, 1)
    if value is NULL:
        f = _tlookup(t, '__delattr__')
        if f is not NULL and _ld(_ld(f, 1) if _kind(f) == OB_FUNCTION else t, 7) & TF_USER:
            return _call_member(f, obj, (name,))
    else:
        f = _tlookup(t, '__setattr__')
        if f is not NULL:
            owner = _ld(f, 1) if _kind(f) == OB_FUNCTION else NULL
            if owner is not NULL and (_ld(owner, 7) & TF_USER):
                return _call_member(f, obj, (name, value))
    found = _tlookup(t, name)
    if found is not NULL and _kind(found) == OB_PROPERTY:
        if value is NULL:
            fdel = _ld(found, 4)
            if fdel is NULL:
                raise AttributeError("can't delete attribute")
            return fdel(obj)
        fset = _ld(found, 3)
        if fset is NULL:
            raise AttributeError("can't set attribute")
        return fset(obj, value)
    if found is not NULL and value is not NULL:
        setter = _tlookup(_ld(found, 1), '__set__')
        if setter is not NULL:
            return _call_member(setter, found, (obj, value))
    if found is not NULL and value is NULL:
        deleter = _tlookup(_ld(found, 1), '__delete__')
        if deleter is not NULL:
            return _call_member(deleter, found, (obj,))
    d = _inst_dict(obj)
    if value is NULL:
        if _lookup(d, name) is NULL:
            _attr_error(obj, name)
        del d[name]
    else:
        d[name] = value
    return None


def _as_index(x, what):
    if _isbool(x):
        return 1 if x else 0
    if _tag(x) == TAG_INT or _tag(x) == TAG_INT64:
        return x
    if _tag(x) == TAG_OBJECT:
        f = _tlookup(_ld(x, 1), '__index__')
        if f is not NULL:
            v = _call_member(f, x, ())
            if _tag(v) == TAG_INT or _tag(v) == TAG_INT64:
                return v
    _index_type(what, x)


def _clamp(i, n, step):
    if i < 0:
        i += n
        if step > 0 and i < 0:
            return 0
        if step < 0 and i < -1:
            return -1
    if step > 0 and i > n:
        return n
    if step < 0 and i >= n:
        return n - 1
    return i


def _slice_range(sl, n):
    step = _ld(sl, 4)
    if step is None:
        step = 1
    else:
        step = _as_index(step, 'slice')
        if step == 0:
            raise ValueError("slice step can't be zero")
    start = _ld(sl, 2)
    stop = _ld(sl, 3)
    if step > 0:
        start = 0 if start is None else _clamp(_as_index(start, 'slice'), n, step)
        stop = n if stop is None else _clamp(_as_index(stop, 'slice'), n, step)
    else:
        start = n - 1 if start is None else _clamp(_as_index(start, 'slice'), n, step)
        stop = -1 if stop is None else _clamp(_as_index(stop, 'slice'), n, step)
    return start, stop, step


def _slice_len(start, stop, step):
    if step > 0:
        if start >= stop:
            return 0
        return (stop - start - 1) // step + 1
    if start <= stop:
        return 0
    return (start - stop - 1) // (-step) + 1


def _subscr(obj, index):
    t = _tag(obj)
    if _isdict(obj):
        v = _dget(obj, index)
        if v is NULL:
            raise KeyError(index)
        return v
    if _kind(index) == OB_SLICE or (_tag(index) == TAG_OBJECT and _ld(index, 0) == OB_SLICE):
        return _getslice(obj, index)
    if t == TAG_STR or t == TAG_QSTR or t == TAG_BYTES or _isbarr(obj):
        if not _isint(index) and index is not True and index is not False:
            _index_type('string' if t != TAG_BYTES and not _isbarr(obj) else 'bytes', index)
        return _seq_at(obj, _as_index(index, obj))
    if t == TAG_TUPLE or _islist(obj):
        return _seq_at(obj, _as_index(index, obj))
    if t == TAG_RANGE:
        return _range_at(obj, _as_index(index, obj))
    if _isinst(obj):
        sub = _subobj(obj)
        if sub is not NULL and not (_ld(_ld(obj, 1), 7) & TF_USER and _tlookup(_ld(obj, 1), '__getitem__') is not NULL):
            # A user __getitem__ wins; otherwise the native payload answers.
            f = _tlookup(_ld(obj, 1), '__getitem__')
            if f is NULL:
                return _subscr(sub, index)
        f = _tlookup(_ld(obj, 1), '__getitem__')
        if f is not NULL:
            return _call_member(f, obj, (index,))
    if t == TAG_OBJECT:
        f = _tlookup(_ld(obj, 1), '__getitem__')
        if f is not NULL:
            return _call_member(f, obj, (index,))
    raise TypeError(_s("'", _tname(obj), "' object isn't subscriptable"))


def _seq_at(obj, i):
    n = _slen(obj) if _tag(obj) != TAG_TUPLE and not _islist(obj) else _ld(obj, 0)
    if i < 0:
        i += n
    if i < 0 or i >= n:
        if _isstr(obj):
            raise IndexError('string index out of range')
        if _tag(obj) == TAG_BYTES or _isbarr(obj):
            raise IndexError('bytes index out of range')
        if _tag(obj) == TAG_TUPLE:
            raise IndexError('tuple index out of range')
        raise IndexError('list index out of range')
    if _isstr(obj):
        b = _byte(obj, i)
        if b < 128:
            return _ch(b)
        return _substr(obj, i, i + 1, TAG_STR)
    if _tag(obj) == TAG_BYTES or _isbarr(obj):
        return _byte(obj, i)
    base, off = _seq_items(obj)
    return _ld(base, off + i)


def _getslice(obj, sl):
    t = _tag(obj)
    if _isstr(obj) or t == TAG_BYTES or _isbarr(obj):
        n = _slen(obj)
        a, b, s = _slice_range(sl, n)
        m = _slice_len(a, b, s)
        tag = TAG_BYTES if t == TAG_BYTES or _isbarr(obj) else TAG_STR
        r = _strnew(m, tag)
        i = 0
        p = a
        while i < m:
            _poke8(_data(r), i, _byte(obj, p))
            p += s
            i += 1
        out = _strfin(r)
        if _isbarr(obj):
            return _barr_from(out)
        return out
    if t == TAG_TUPLE or _islist(obj):
        n = _ld(obj, 0)
        a, b, s = _slice_range(sl, n)
        m = _slice_len(a, b, s)
        base, off = _seq_items(obj)
        if _islist(obj):
            r = _newlist(m)
            i = 0
            p = a
            while i < m:
                _st(_ld(r, 2), i, _ld(base, off + p))
                p += s
                i += 1
            return r
        r = _newtuple(m)
        i = 0
        p = a
        while i < m:
            _st(r, 1 + i, _ld(base, off + p))
            p += s
            i += 1
        return r
    if t == TAG_RANGE:
        return _range_slice(obj, sl)
    if _isinst(obj):
        f = _tlookup(_ld(obj, 1), '__getitem__')
        if f is not NULL:
            return _call_member(f, obj, (sl,))
        sub = _subobj(obj)
        if sub is not NULL:
            return _subscr(sub, sl)
    raise TypeError(_s("'", _tname(obj), "' object isn't subscriptable"))


def _setsubscr(obj, index, value):
    if _islist(obj):
        if _tag(index) == TAG_OBJECT and _ld(index, 0) == OB_SLICE:
            return _list_setslice(obj, index, value)
        i = _as_index(index, obj)
        n = _ld(obj, 0)
        if i < 0:
            i += n
        if i < 0 or i >= n:
            raise IndexError('list index out of range')
        if value is NULL:
            return _list_del(obj, i)
        _st(_ld(obj, 2), i, value)
        return None
    if _isbarr(obj):
        if _tag(index) == TAG_OBJECT and _ld(index, 0) == OB_SLICE:
            return _barr_setslice(obj, index, value)
        i = _as_index(index, obj)
        n = _ld(obj, 0)
        if i < 0:
            i += n
        if i < 0 or i >= n:
            raise IndexError('bytes index out of range')
        if value is NULL:
            raise TypeError("bytearray doesn't support item deletion")
        _poke8(_data(obj), i, _as_index(value, obj) & 255)
        return None
    if _isdict(obj):
        if value is NULL:
            _map_del(obj, index, False)
        else:
            _map_put(obj, index, value, False)
        return None
    if _isinst(obj):
        if value is NULL:
            f = _tlookup(_ld(obj, 1), '__delitem__')
            if f is not NULL:
                return _call_member(f, obj, (index,))
        else:
            f = _tlookup(_ld(obj, 1), '__setitem__')
            if f is not NULL:
                return _call_member(f, obj, (index, value))
        sub = _subobj(obj)
        if sub is not NULL:
            return _setsubscr(sub, index, value)
    if value is NULL:
        raise TypeError(_s("'", _tname(obj), "' object doesn't support item deletion"))
    raise TypeError(_s("'", _tname(obj), "' object does not support item assignment"))


def _list_del(lst, i):
    n = _ld(lst, 0)
    items = _ld(lst, 2)
    while i < n - 1:
        _st(items, i, _ld(items, i + 1))
        i += 1
    _st(lst, 0, n - 1)
    return None


def _list_setslice(lst, sl, value):
    n = _ld(lst, 0)
    a, b, s = _slice_range(sl, n)
    if s != 1:
        raise NotImplementedError('extended slice assignment')
    if value is NULL:
        value = ()
    src = _list_of_iter(value)
    m = _ld(src, 0)
    span = b - a
    newn = n - span + m
    _list_reserve(lst, newn)
    items = _ld(lst, 2)
    if m != span:
        if m < span:
            i = a + m
            while i < newn:
                _st(items, i, _ld(items, i + (span - m)))
                i += 1
        else:
            i = newn - 1
            while i >= a + m:
                _st(items, i, _ld(items, i - (m - span)))
                i -= 1
    i = 0
    while i < m:
        _st(items, a + i, _ld(_ld(src, 2), i))
        i += 1
    _st(lst, 0, newn)
    return None
