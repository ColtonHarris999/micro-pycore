# Calls the core does not bind or dispatch itself: _bind, _call, class
# creation, super, and native subclasses.
from ._abi import *


def _argname(names, i):
    return _mk(TAG_QSTR, _peek32(names + 4 * i))


def _find_arg(names, n, key):
    i = 0
    while i < n:
        if _streq(_argname(names, i), key):
            return i
        i += 1
    return -1


def _flat_kw(kw):
    out = []
    if kw is NULL or len(kw) == 0:
        return out
    i = 0
    n = len(kw)
    while i < n:
        k = kw[i]
        v = kw[i + 1]
        i += 2
        if _isint(k) and k == 0:
            d = v if _isdict(v) else _kwdict(v)
            for kk in d:
                out.append(kk)
                out.append(d[kk])
        else:
            out.append(k)
            out.append(v)
    return out


def _blank(n):
    loc = []
    i = 0
    while i < n:
        loc.append(NULL)
        i += 1
    return loc


def _bind(fun, args, kw):
    rc = _ld(fun, 2)
    scope = (_peek32(rc + 4 * RC_SIG) >> 16) & 255
    aw = _peek32(rc + 4 * RC_ARGS)
    npos = aw & 255
    nkwo = (aw >> 8) & 255
    ndef = (aw >> 16) & 255
    names = _peek32(rc + 4 * RC_ARG_NAMES)
    n = len(args)
    varargs = scope & SCOPE_VARARGS
    varkw = scope & SCOPE_VARKEYWORDS
    if n > npos and not varargs:
        _arg_count(npos, n)
    nloc = npos + nkwo + (1 if varargs else 0) + (1 if varkw else 0)
    loc = _blank(nloc)
    take = n if n < npos else npos
    i = 0
    while i < take:
        loc[i] = args[i]
        i += 1
    if varargs:
        rest = n - npos if n > npos else 0
        t = _newtuple(rest)
        i = 0
        while i < rest:
            _st(t, 1 + i, args[npos + i])
            i += 1
        loc[npos + nkwo] = t
    pairs = _flat_kw(kw)
    if not pairs and not (scope & SCOPE_DEFKWARGS):
        if nkwo:
            raise TypeError('function missing keyword-only argument')
        if n < npos - ndef:
            raise TypeError(_s('function missing required positional argument #', _istr(n)))
        defs = _ld(fun, 4)
        i = n
        while i < npos:
            loc[i] = defs[i - (npos - ndef)]
            i += 1
        if varkw:
            loc[npos + nkwo + (1 if varargs else 0)] = _newdict(0)
        return _tuple_of_list(loc)
    extra = []
    i = 0
    while i < len(pairs):
        k = pairs[i]
        v = pairs[i + 1]
        i += 2
        slot = _find_arg(names, npos + nkwo, k)
        if slot < 0:
            if not varkw:
                raise TypeError(_s("unexpected keyword argument '", k, "'"))
            extra.append(k)
            extra.append(v)
        else:
            if loc[slot] is not NULL:
                raise TypeError(_s("function got multiple values for argument '", k, "'"))
            loc[slot] = v
    defs = _ld(fun, 4)
    i = 0
    while i < ndef:
        slot = npos - 1 - i
        if loc[slot] is NULL:
            loc[slot] = defs[ndef - 1 - i]
        i += 1
    i = npos - ndef - 1
    while i >= 0:
        if loc[i] is NULL:
            raise TypeError(_s('function missing required positional argument #', _istr(i)))
        i -= 1
    kwd = _ld(fun, 5)
    i = 0
    while i < nkwo:
        if loc[npos + i] is NULL:
            name = _argname(names, npos + i)
            filled = NULL
            if kwd is not NULL:
                filled = _dget(kwd, name)
            if filled is NULL:
                raise TypeError(_s("function missing required keyword argument '", name, "'"))
            loc[npos + i] = filled
        i += 1
    if varkw:
        d = _newdict(len(extra) // 2)
        i = 0
        while i < len(extra):
            d[extra[i]] = extra[i + 1]
            i += 2
        loc[npos + nkwo + (1 if varargs else 0)] = d
    return _tuple_of_list(loc)


def _call(obj, args, kw):
    f = NULL
    self = NULL
    if _tag(obj) == TAG_OBJECT:
        k = _ld(obj, 0)
        if k == OB_INSTANCE or k == OB_EXCEPTION:
            f = _tlookup(_ld(obj, 1), '__call__')
            self = obj
        elif k == OB_SUPER:
            f = _super_attr(_ld(obj, 2), _ld(obj, 3), '__call__')
            return _apply_obj(f, args, kw)
    if f is NULL:
        raise TypeError(_s("'", _tname(obj), "' object isn't callable"))
    return _apply_call(f, self, args, kw)


def _kw_dict(kw):
    d = {}
    if kw is NULL:
        return d
    i = 0
    while i < len(kw):
        k = kw[i]
        v = kw[i + 1]
        if _isint(k) and k == 0:
            src = v if _isdict(v) else _kwdict(v)
            for kk in src:
                d[kk] = src[kk]
        else:
            d[k] = v
        i += 2
    return d


def _apply_call(f, self, args, kw):
    if kw is NULL or len(kw) == 0:
        return f(self, *args)
    return f(self, *args, **_kw_dict(kw))


def _apply_obj(f, args, kw):
    if kw is NULL or len(kw) == 0:
        return f(*args)
    return f(*args, **_kw_dict(kw))


def _nb_mutable(nb):
    return nb is list or nb is dict or nb is set or nb is bytearray


def _own_init(cls):
    mro = _ld(cls, 5)
    n = _ld(mro, 0)
    i = 0
    while i < n:
        t = _ld(mro, 1 + i)
        if not (_ld(t, 7) & TF_USER):
            return NULL
        f = _lookup(_ld(t, 2), '__init__')
        if f is not NULL and f is not STOP:
            return f
        i += 1
    return NULL


def _nsub_new(cls, *args, **kw):
    nb = _native_base(cls)
    if _nb_mutable(nb):
        sub = nb()
    else:
        sub = nb(*args, **kw)
    inst = _native_sub_new(cls, sub)
    init = _own_init(cls)
    if init is NULL and _nb_mutable(nb):
        init = _lookup(_ld(nb, 2), '__init__')
        if init is STOP:
            init = NULL
    if init is not NULL:
        r = init(inst, *args, **kw)
        if r is not None:
            raise TypeError(_s("__init__() should return None, not '", _tname(r), "'"))
    return inst


def _mro_list(t):
    m = _ld(t, 5)
    n = _ld(m, 0)
    out = []
    i = 0
    while i < n:
        out.append(_ld(m, 1 + i))
        i += 1
    return out


def _c3(cls, bases):
    seqs = []
    for b in bases:
        seqs.append(_mro_list(b))
    base_list = []
    for b in bases:
        base_list.append(b)
    seqs.append(base_list)
    out = [cls]
    guard = 0
    while guard < 64:
        guard += 1
        nonempty = []
        for s in seqs:
            if s:
                nonempty.append(s)
        if not nonempty:
            break
        cand = NULL
        for s in nonempty:
            c = s[0]
            bad = False
            for t in nonempty:
                j = 1
                while j < len(t):
                    if t[j] is c:
                        bad = True
                        break
                    j += 1
                if bad:
                    break
            if not bad:
                cand = c
                break
        if cand is NULL:
            raise TypeError('Cannot create consistent method resolution order (MRO)')
        out.append(cand)
        for s in seqs:
            if s and s[0] is cand:
                s.pop(0)
    return out


def _first_native(bases):
    for b in bases:
        mro = _ld(b, 5)
        i = 0
        n = _ld(mro, 0)
        while i < n:
            t = _ld(mro, 1 + i)
            if not (_ld(t, 7) & TF_USER):
                return t
            i += 1
    return object


def _make_type(name, bases, ns):
    base_l = []
    if not bases:
        base_l.append(object)
    else:
        for b in bases:
            if not _istype(b):
                raise TypeError('bases must be types')
            base_l.append(b)
    cls = _alloc(9, TAG_OBJECT, 0)
    _st(cls, 0, OB_TYPE)
    _st(cls, 1, type)
    _st(cls, 2, ns)
    bt = _newtuple(len(base_l))
    i = 0
    while i < len(base_l):
        _st(bt, 1 + i, base_l[i])
        i += 1
    _st(cls, 3, bt)
    _st(cls, 4, name)
    order = _c3(cls, base_l)
    mt = _newtuple(len(order))
    i = 0
    while i < len(order):
        _st(mt, 1 + i, order[i])
        i += 1
    _st(cls, 5, mt)
    _st(cls, 6, 0)
    flags = TF_USER
    nb = _first_native(base_l)
    exc = False
    for b in base_l:
        if _ld(b, 7) & TF_EXC:
            exc = True
    if exc:
        flags |= TF_EXC
    if nb is not object and not (_ld(nb, 7) & TF_EXC):
        flags |= TF_NATIVE_SUB
    if '__bool__' in ns or '__len__' in ns or (_ld(nb, 7) & TF_TRUTH):
        flags |= TF_TRUTH
    for b in base_l:
        bf = _ld(b, 7)
        if bf & TF_TRUTH:
            flags |= TF_TRUTH
        if bf & TF_SETATTR:
            flags |= TF_SETATTR
        if bf & TF_GETATTR:
            flags |= TF_GETATTR
        if bf & TF_DESC:
            flags |= TF_DESC
        if bf & TF_EQ:
            flags |= TF_EQ
    if '__setattr__' in ns or '__delattr__' in ns:
        flags |= TF_SETATTR
    if '__getattr__' in ns:
        flags |= TF_GETATTR
    if '__eq__' in ns:
        flags |= TF_EQ
    for val in ns.values():
        if _tag(val) == TAG_OBJECT:
            vk = _ld(val, 0)
            if vk == OB_PROPERTY or _tlookup(_ld(val, 1), '__set__') is not NULL:
                flags |= TF_DESC
    custom_new = _lookup(ns, '__new__')
    if custom_new is STOP:
        custom_new = NULL
    make_new = NULL
    if custom_new is not NULL:
        make_new = custom_new
    elif flags & TF_NATIVE_SUB:
        make_new = _nsub_new
    else:
        flags |= TF_INST
    _st(cls, 7, flags)
    _st(cls, 8, make_new if make_new is not NULL else NULL)
    if _lookup(ns, '__module__') is NULL:
        g = _fget(FR_GLOBALS)
        if g is not NULL and _isdict(g):
            mod = _dget(g, '__name__')
            if mod is not NULL:
                ns['__module__'] = mod
    if _lookup(ns, '__qualname__') is NULL:
        ns['__qualname__'] = name
    return cls


def __build_class__(func, name, *bases):
    ns = {}
    cell = _callns(func, ns)
    cls = _make_type(name, bases, ns)
    if _tag(cell) == TAG_OBJECT and _ld(cell, 0) == OB_CELL:
        _st(cell, 2, cls)
    return cls


def _super_attr(typ, obj, name):
    if not _istype(typ):
        raise TypeError('super() argument 1 must be a type')
    mro = _ld(typ, 5)
    n = _ld(mro, 0)
    i = 1
    while i < n:
        b = _ld(mro, 1 + i)
        hit = _lookup(_ld(b, 2), name)
        if hit is not NULL and hit is not STOP:
            k = _kind(hit)
            if k == OB_FUNCTION or k == OB_BUILTIN:
                return _bind_method(hit, obj)
            return _desc_get(hit, obj)
        i += 1
    _attr_error(obj, name)


def _super_method(typ, obj, name):
    return _super_attr(typ, obj, name)


def super____new__(cls, *args):
    if len(args) != 2:
        raise TypeError('super() takes 2 arguments')
    o = _alloc(4, TAG_OBJECT, 0)
    _st(o, 0, OB_SUPER)
    _st(o, 1, cls)
    _st(o, 2, args[0])
    _st(o, 3, args[1])
    return o


def type____new__(cls, *args):
    n = len(args)
    if n == 1:
        return _typeof(args[0])
    if n != 3:
        raise TypeError('type takes 1 or 3 arguments')
    return _make_type(args[0], args[1], args[2])
