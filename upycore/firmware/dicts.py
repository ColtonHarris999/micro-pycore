# Dicts and sets, including the map the core cannot hash itself.
from ._abi import *

_SIZES = (
    0, 2, 4, 6, 8, 10, 12, 17, 23, 29, 37, 47, 59, 73, 97, 127, 167, 223, 293,
    389, 521, 691, 919, 1223, 1627, 2161, 3229, 4831, 7243, 10861, 16273,
    24407, 36607, 54907,
)


def _next_alloc(x):
    r = (x + (x >> 1)) | 1
    i = len(_SIZES) - 1
    while i >= 0:
        if _SIZES[i] >= x:
            r = _SIZES[i]
        i -= 1
    return r


def _newdict(n):
    d = _alloc(4, TAG_MUT, MUT_DICT)
    _st(d, 0, 0)
    _st(d, 1, n)
    _st(d, 2, _alloc(n * 2, TAG_CONT, 0) if n else NULL)
    _st(d, 3, 0)
    return d


def _newset(n):
    s = _alloc(4, TAG_MUT, MUT_SET)
    _st(s, 0, 0)
    _st(s, 1, n)
    _st(s, 2, _alloc(n, TAG_CONT, 0) if n else NULL)
    _st(s, 3, 0)
    return s


def _tomb():
    return _mk(TAG_CONTROL, CTL_TOMB)


def _is_tomb(k):
    return _tag(k) == TAG_CONTROL and _pay(k) == CTL_TOMB


def _hmod(h, n):
    if h < 0:
        h += _U32
    return h % n


def _uhash(k):
    h = _hash(k)
    if h is STOP:
        h = _hashv(k)
    return h


def _keyeq(a, b):
    if a is b:
        return True
    if _isstr(a) or _isstr(b) or _tag(a) == TAG_BYTES or _tag(b) == TAG_BYTES:
        if (_isstr(a) and _isstr(b)) or (_tag(a) == TAG_BYTES and _tag(b) == TAG_BYTES):
            return _streq(a, b)
        return False
    if _isint(a) and _isint(b):
        return a == b
    return _equal(a, b)


def _slot(tab, pos, is_set):
    return _ld(tab, pos if is_set else pos * 2)


def _map_insert_new(c, k, v, is_set):
    n = _ld(c, 1)
    tab = _ld(c, 2)
    pos = _hmod(_uhash(k), n)
    while True:
        cur = _slot(tab, pos, is_set)
        if cur is NULL or _is_tomb(cur):
            at = pos if is_set else pos * 2
            _st(tab, at, k)
            if not is_set:
                _st(tab, at + 1, v)
            _st(c, 0, _ld(c, 0) + 1)
            return
        pos += 1
        if pos == n:
            pos = 0


def _map_grow(c, is_set):
    old_n = _ld(c, 1)
    old = _ld(c, 2)
    n = _next_alloc(old_n + 1)
    tab = _alloc(n if is_set else n * 2, TAG_CONT, 0)
    _st(c, 1, n)
    _st(c, 2, tab)
    _st(c, 0, 0)
    if old is NULL:
        return
    i = 0
    while i < old_n:
        k = _ld(old, i if is_set else i * 2)
        if k is not NULL and not _is_tomb(k):
            v = NULL if is_set else _ld(old, i * 2 + 1)
            _map_insert_new(c, k, v, is_set)
        i += 1


def _map_put(c, k, v, is_set):
    if is_set:
        if _ld(c, 3) & SET_FLAG_FROZEN:
            raise TypeError('cannot modify frozen set')
    elif _ld(c, 3) & DICT_FLAG_ROM:
        raise TypeError('cannot modify read-only dict')
    if _ld(c, 1) == 0:
        _map_grow(c, is_set)
    n = _ld(c, 1)
    tab = _ld(c, 2)
    pos = _hmod(_uhash(k), n)
    start = pos
    avail = -1
    while True:
        cur = _slot(tab, pos, is_set)
        if cur is NULL:
            at = (avail if avail >= 0 else pos)
            at = at if is_set else at * 2
            _st(tab, at, k)
            if not is_set:
                _st(tab, at + 1, v)
            _st(c, 0, _ld(c, 0) + 1)
            return None
        if _is_tomb(cur):
            if avail < 0:
                avail = pos
        elif _keyeq(cur, k):
            if not is_set:
                _st(tab, (pos * 2) + 1, v)
            return None
        pos += 1
        if pos == n:
            pos = 0
        if pos == start:
            if avail >= 0:
                at = avail if is_set else avail * 2
                _st(tab, at, k)
                if not is_set:
                    _st(tab, at + 1, v)
                _st(c, 0, _ld(c, 0) + 1)
                return None
            _map_grow(c, is_set)
            return _map_put(c, k, v, is_set)


def _map_find(c, k, is_set):
    n = _ld(c, 1)
    if n == 0:
        return -1
    tab = _ld(c, 2)
    pos = _hmod(_uhash(k), n)
    start = pos
    while True:
        cur = _slot(tab, pos, is_set)
        if cur is NULL:
            return -1
        if not _is_tomb(cur) and _keyeq(cur, k):
            return pos
        pos += 1
        if pos == n:
            pos = 0
        if pos == start:
            return -1


def _dget(d, k):
    hit = _lookup(d, k)
    if hit is not STOP:
        return hit
    pos = _map_find(d, k, False)
    if pos < 0:
        return NULL
    return _ld(_ld(d, 2), pos * 2 + 1)


def _sfind(s, k):
    hit = _lookup(s, k)
    if hit is not STOP:
        return 0 if hit is not NULL else -1
    return _map_find(s, k, True)


def _map_del(c, k, is_set):
    pos = _map_find(c, k, is_set)
    if pos < 0:
        raise KeyError(k)
    n = _ld(c, 1)
    tab = _ld(c, 2)
    nxt = 0 if pos + 1 == n else pos + 1
    nxtv = _slot(tab, nxt, is_set)
    at = pos if is_set else pos * 2
    _st(tab, at, NULL if nxtv is NULL else _tomb())
    if not is_set:
        _st(tab, at + 1, NULL)
    _st(c, 0, _ld(c, 0) - 1)
    return None


def _dictop(op, a, b, c):
    if op == 0:
        # mp_obj_new_set: alloc is the item count, not an empty map that grows.
        s = _newset(len(a))
        for k in a:
            _map_put(s, k, NULL, True)
        return s
    if op == 2:
        _map_put(a, b, NULL, True)
        return None
    _map_put(a, b, c, False)
    return None


def _kwdict(x):
    if _isdict(x):
        return dict__copy(x)
    d = {}
    keys = NULL
    if _tag(x) == TAG_OBJECT:
        keys = _tlookup(_ld(x, 1), 'keys')
    if keys is not NULL:
        for k in _call_member(keys, x, ()):
            d[k] = x[k]
        return d
    raise TypeError(_s("'", _tname(x), "' object is not a mapping"))


def _view(d, kind):
    o = _alloc(4, TAG_OBJECT, 0)
    _st(o, 0, OB_DICT_VIEW)
    _st(o, 1, _ntype(T_DICT_VIEW))
    _st(o, 2, d)
    _st(o, 3, kind)
    return o


def dict____new__(cls, *args, **kw):
    if cls is not dict:
        return _nsub_new(cls, *args, **kw)
    d = {}
    if args or kw:
        dict__update(d, *args, **kw)
    return d


def dict____init__(self, *args, **kw):
    target = _subobj(self)
    if target is NULL:
        target = self
    if len(args) > 1:
        _arg_count(1, len(args))
    if args:
        dict__update(target, args[0])
    if kw:
        dict__update(target, kw)
    return None


def dict__clear(self):
    _st(self, 0, 0)
    _st(self, 1, 0)
    _st(self, 2, NULL)
    return None


def dict__copy(self):
    n = _ld(self, 1)
    d = _newdict(n)
    if n:
        _wcopy(_ld(d, 2), 0, _ld(self, 2), 0, n * 2)
    _st(d, 0, _ld(self, 0))
    return d


def dict__get(self, key, default=None):
    v = _dget(self, key)
    if v is NULL:
        return default
    return v


def dict__keys(self):
    return _view(self, 0)


def dict__values(self):
    return _view(self, 1)


def dict__items(self):
    return _view(self, 2)


def dict__pop(self, key, default=_MISSING):
    v = _dget(self, key)
    if v is NULL:
        if default == _MISSING:
            raise KeyError(key)
        return default
    _map_del(self, key, False)
    return v


def dict__popitem(self):
    n = _ld(self, 1)
    tab = _ld(self, 2)
    i = 0
    while i < n:
        k = _ld(tab, i * 2)
        if k is not NULL and not _is_tomb(k):
            v = _ld(tab, i * 2 + 1)
            _map_del(self, k, False)
            return (k, v)
        i += 1
    raise KeyError('popitem(): dictionary is empty')


def dict__setdefault(self, key, default=None):
    v = _dget(self, key)
    if v is not NULL:
        return v
    self[key] = default
    return default


def dict__update(self, *args, **kw):
    if len(args) > 1:
        _arg_count(1, len(args))
    if args:
        other = args[0]
        if _isdict(other):
            for k in other:
                self[k] = other[k]
        elif _tag(other) == TAG_OBJECT and _tlookup(_ld(other, 1), 'keys') is not NULL:
            for k in other.keys():
                self[k] = other[k]
        else:
            for item in other:
                self[item[0]] = item[1]
    if kw:
        for k in kw:
            self[k] = kw[k]
    return None


def dict____delitem__(self, key):
    _map_del(self, key, False)
    return None


def dict____getitem__(self, key):
    v = _dget(self, key)
    if v is NULL:
        raise KeyError(key)
    return v


def dict____setitem__(self, key, value):
    self[key] = value
    return None


def _dict_fromkeys(cls, iterable, value=None):
    d = cls()
    for k in iterable:
        d[k] = value
    return d


def _set_freeze(s, like):
    if _ld(like, 3) & SET_FLAG_FROZEN:
        _st(s, 3, SET_FLAG_FROZEN)
    return s


def _set_add_iter(dst, src):
    for k in src:
        _map_put(dst, k, NULL, True)


def set__add(self, key):
    _map_put(self, key, NULL, True)
    return None


def set__clear(self):
    _st(self, 0, 0)
    _st(self, 1, 0)
    _st(self, 2, NULL)
    return None


def _set_clone(s):
    # Slot-for-slot copy. Reinserting would rehash and change iteration order.
    n = _ld(s, 1)
    r = _newset(n)
    if n:
        _wcopy(_ld(r, 2), 0, _ld(s, 2), 0, n)
    _st(r, 0, _ld(s, 0))
    return r


def _set_toggle(s, k):
    # ADD_IF_NOT_FOUND_OR_REMOVE_IF_FOUND, one probe's worth of either path.
    if _map_find(s, k, True) >= 0:
        _map_del(s, k, True)
    else:
        _map_put(s, k, NULL, True)


def set__copy(self):
    return _set_freeze(_set_clone(self), self)


def frozenset__copy(self):
    return set__copy(self)


def set__pop(self):
    n = _ld(self, 1)
    tab = _ld(self, 2)
    i = 0
    while tab is not NULL and i < n:
        k = _ld(tab, i)
        if k is not NULL and not _is_tomb(k):
            _map_del(self, k, True)
            return k
        i += 1
    raise KeyError('pop from an empty set')


def set__remove(self, key):
    _map_del(self, key, True)
    return None


def set__discard(self, key):
    if _sfind(self, key) >= 0:
        _map_del(self, key, True)
    return None


def set__update(self, *args):
    for a in args:
        _set_add_iter(self, a)
    return None


def set__union(self, *args):
    r = _newset(0)
    _set_add_iter(r, self)
    for a in args:
        _set_add_iter(r, a)
    return _set_freeze(r, self)


def frozenset__union(self, *args):
    return set__union(self, *args)


def set__intersection(self, *args):
    r = _newset(0)
    for k in self:
        ok = True
        for a in args:
            if k not in a:
                ok = False
                break
        if ok:
            _map_put(r, k, NULL, True)
    return _set_freeze(r, self)


def frozenset__intersection(self, *args):
    return set__intersection(self, *args)


def set__difference(self, *args):
    r = _newset(0)
    for k in self:
        drop = False
        for a in args:
            if k in a:
                drop = True
                break
        if not drop:
            _map_put(r, k, NULL, True)
    return _set_freeze(r, self)


def frozenset__difference(self, *args):
    return set__difference(self, *args)


def set__symmetric_difference(self, other):
    r = _set_clone(self)
    for k in other:
        _set_toggle(r, k)
    return _set_freeze(r, self)


def frozenset__symmetric_difference(self, other):
    return set__symmetric_difference(self, other)


def set__symmetric_difference_update(self, other):
    for k in other:
        _set_toggle(self, k)
    return None


def set__difference_update(self, *args):
    _set_diff(self, args, True)
    return None


def set__intersection_update(self, *args):
    other = args[0] if args else self
    _set_intersect(self, other, True)
    return None


def set__isdisjoint(self, other):
    for k in self:
        if k in other:
            return False
    return True


def frozenset__isdisjoint(self, other):
    return set__isdisjoint(self, other)


def set__issubset(self, other):
    return _set_subset(self, other, False)


def frozenset__issubset(self, other):
    return _set_subset(self, other, False)


def set__issuperset(self, other):
    return _set_subset(other, self, False)


def frozenset__issuperset(self, other):
    return _set_subset(other, self, False)


def _set_subset(a, b, proper):
    if proper and _ld(a, 0) >= _ld(b, 0):
        return False
    if _ld(a, 0) > _ld(b, 0) and _isanyset(b):
        return False
    for k in a:
        if k not in b:
            return False
    return True


def _set_diff(a, others, update):
    if not update:
        return set__difference(a, *others)
    drop = []
    for k in a:
        for o in others:
            if k in o:
                drop.append(k)
                break
    for k in drop:
        _map_del(a, k, True)
    return a


def _set_intersect(a, b, update):
    if not update:
        return set__intersection(a, b)
    drop = []
    for k in a:
        if k not in b:
            drop.append(k)
    for k in drop:
        _map_del(a, k, True)
    return a


def set____contains__(self, key):
    return _sfind(self, key) >= 0


def frozenset____contains__(self, key):
    return _sfind(self, key) >= 0


def set____new__(cls, *args):
    if cls is not set:
        return _nsub_new(cls, *args)
    s = _newset(0)
    if args:
        _set_add_iter(s, args[0])
    return s


def set____init__(self, *args):
    if len(args) > 1:
        _arg_count(1, len(args))
    target = _subobj(self)
    if target is NULL:
        target = self
    if args:
        _set_add_iter(target, args[0])
    return None


def frozenset____new__(cls, *args):
    s = _newset(0)
    if args:
        _set_add_iter(s, args[0])
    _st(s, 3, SET_FLAG_FROZEN)
    if cls is not frozenset:
        return _native_sub_new(cls, s)
    return s
