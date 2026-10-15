# Builtins that are not a native type's method.
from ._abi import *


def _object____init___fb(self, *args, **kw):
    return None


def _new__object_fb(cls, *args, **kw):
    if kw:
        _no_kw()
    _arg_count(0, len(args))


def _isinstance_fb(obj, cls):
    if _tag(cls) == TAG_TUPLE:
        for c in cls:
            if not _istype(c):
                raise TypeError('isinstance() arg 2 must be a type or a tuple of types')
            if isinstance(obj, c):
                return True
        return False
    if not _istype(cls):
        raise TypeError('isinstance() arg 2 must be a type or a tuple of types')
    return _issub(_typeof(obj), cls)


def _id_fb(*args):
    if len(args) != 1:
        _arg_count(1, len(args))
    return _pay(args[0])


def bool____new__(cls, x=False):
    v = True if x else False
    if cls is not bool:
        return _native_sub_new(cls, v)
    return v


def _parse_int(text, base):
    if base != 0 and (base < 2 or base > 36):
        raise ValueError('int() arg 2 must be >= 2 and <= 36')
    n = _slen(text)
    i = 0
    while i < n and _byte(text, i) <= 32:
        i += 1
    if i >= n:
        raise ValueError(_s('invalid syntax for integer with base ', _istr(10 if base == 0 else base)))
    neg = False
    c = _byte(text, i)
    if c == 43 or c == 45:
        neg = c == 45
        i += 1
    if base == 0:
        base = 10
        if i + 1 < n and _byte(text, i) == 48:
            p = _byte(text, i + 1)
            if p == 120 or p == 88:
                base = 16
                i += 2
            elif p == 111 or p == 79:
                base = 8
                i += 2
            elif p == 98 or p == 66:
                base = 2
                i += 2
    val = 0
    anyd = False
    while i < n:
        c = _byte(text, i)
        if c <= 32:
            break
        if 48 <= c <= 57:
            d = c - 48
        elif 97 <= c <= 122:
            d = c - 87
        elif 65 <= c <= 90:
            d = c - 55
        elif c == 95:
            i += 1
            continue
        else:
            raise ValueError(_s('invalid syntax for integer with base ', _istr(base)))
        if d >= base:
            raise ValueError(_s('invalid syntax for integer with base ', _istr(base)))
        val = val * base + d
        anyd = True
        i += 1
    while i < n:
        if _byte(text, i) > 32:
            raise ValueError(_s('invalid syntax for integer with base ', _istr(base)))
        i += 1
    if not anyd:
        raise ValueError(_s('invalid syntax for integer with base ', _istr(base)))
    if neg:
        return -val
    return val


def _int_value(args):
    if len(args) == 0:
        return 0
    if len(args) > 2:
        _arg_count(2, len(args))
    x = args[0]
    base = 10 if len(args) == 1 else args[1]
    if len(args) == 2 and not _isstr(x) and _tag(x) != TAG_BYTES and not _isbarr(x):
        raise TypeError("int() can't convert non-string with explicit base")
    if x is True:
        return 1
    if x is False:
        return 0
    if _tag(x) == TAG_INT or _tag(x) == TAG_INT64:
        return x
    if _tag(x) == TAG_FLOAT:
        i = _ftoi(x)
        if i is STOP:
            raise OverflowError("overflow converting float to int")
        return i
    if _isstr(x):
        return _parse_int(x, base)
    if _tag(x) == TAG_BYTES or _isbarr(x):
        return _parse_int(_decode(_barr_bytes(x) if _isbarr(x) else x, 'utf-8'), base)
    if _tag(x) == TAG_OBJECT:
        f = _tlookup(_ld(x, 1), '__int__')
        if f is NULL:
            f = _tlookup(_ld(x, 1), '__index__')
        if f is not NULL:
            return _call_member(f, x, ())
    raise TypeError(_s("can't convert ", _tname(x), ' to int'))


def int____new__(cls, *args):
    v = _int_value(args)
    if cls is not int:
        return _native_sub_new(cls, v)
    return v


def int__to_bytes(self, length, byteorder='little'):
    if length < 0:
        raise ValueError('length argument must be non-negative')
    n = self
    neg = n < 0
    if neg:
        n = -n
    b = _strnew(length, TAG_BYTES)
    little = _streq(byteorder, 'little')
    i = 0
    while i < length:
        _poke8(_data(b), i if little else length - 1 - i, n & 255)
        n >>= 8
        i += 1
    if n:
        raise OverflowError('int too big to convert')
    if neg:
        # two's complement
        i = 0
        carry = 1
        while i < length:
            at = i if little else length - 1 - i
            v = ((~_byte(b, at)) & 255) + carry
            _poke8(_data(b), at, v & 255)
            carry = 1 if v > 255 else 0
            i += 1
    return _strfin(b)


def _int_from_bytes(cls, data, byteorder='little'):
    if _isstr(data):
        raise TypeError("cannot convert 'str' object to bytes")
    b = _barr_bytes(data) if _isbarr(data) else data
    if _tag(b) != TAG_BYTES:
        b = _bytes_from_args((data,))
    n = 0
    little = _streq(byteorder, 'little')
    ln = _slen(b)
    i = 0
    while i < ln:
        n = (n << 8) | _byte(b, i if not little else ln - 1 - i)
        i += 1
    if cls is not int:
        return cls(n)
    return n


def abs(x):
    if _tag(x) == TAG_COMPLEX or (_tag(x) == TAG_OBJECT and _ld(x, 0) == OB_INSTANCE):
        return _unop(UNOP_ABS, x)
    if x < 0:
        return -x
    return x


def all(iterable):
    for x in iterable:
        if not x:
            return False
    return True


def any(iterable):
    for x in iterable:
        if x:
            return True
    return False


def chr(i):
    if i < 0 or i > 1114111:
        raise ValueError('chr() arg not in range(0x110000)')
    return _chr_code(i)


def ord(c):
    if _tag(c) == TAG_BYTES or _isbarr(c):
        if _slen(c) != 1:
            raise TypeError('ord() expected a character, but string of length %d found' if False else 'ord() expected a character')
        return _byte(c, 0)
    if not _isstr(c):
        raise TypeError('ord() expected string of length 1')
    n = _slen(c)
    if n == 0:
        raise TypeError('ord() expected a character, but string of length 0 found')
    cp, k = _utf8_at(_data(c), 0)
    if k != n:
        raise TypeError(_s('ord() expected a character, but string of length ', _istr(n), ' found'))
    return cp


def bin(n):
    return _int_base(n, 2, '0b', False)


def hex(n):
    return _int_base(n, 16, '0x', False)


def oct(n):
    return _int_base(n, 8, '0o', False)


def divmod(a, b):
    return (a // b, a % b)


def pow(x, y, z=_MISSING):
    v = x ** y
    if z == _MISSING:
        return v
    return v % z


def round(number, ndigits=_MISSING):
    if _tag(number) == TAG_OBJECT:
        f = _tlookup(_ld(number, 1), '__round__')
        if f is not NULL:
            if ndigits == _MISSING:
                return _call_member(f, number, ())
            return _call_member(f, number, (ndigits,))
    x = number + 0.0
    if ndigits == _MISSING:
        # round half to even
        base = _floor(x)
        diff = x - base
        if diff > 0.5:
            return base + 1
        if diff < 0.5:
            return _ftoi(base) if _ftoi(base) is not STOP else base
        i = _ftoi(base)
        if i is STOP:
            return base
        if i & 1:
            return i + 1
        return i
    p = 10.0 ** ndigits
    return round(x * p) / p


def _minmax(args, kw, is_max):
    key = None
    default = NULL
    have_default = False
    if kw:
        for k in kw:
            if _streq(k, 'key'):
                key = kw[k]
            elif _streq(k, 'default'):
                default = kw[k]
                have_default = True
            else:
                raise TypeError(_s("unexpected keyword argument '", k, "'"))
    if len(args) == 0:
        _arg_count(1, 0)
    if len(args) == 1:
        it = args[0]
        best = NULL
        for x in it:
            kx = x if key is None else key(x)
            if best is NULL or ((kx > best[0]) if is_max else (kx < best[0])):
                best = (kx, x)
        if best is NULL:
            if have_default:
                return default
            raise ValueError('arg is an empty sequence')
        return best[1]
    best = NULL
    for x in args:
        kx = x if key is None else key(x)
        if best is NULL or ((kx > best[0]) if is_max else (kx < best[0])):
            best = (kx, x)
    return best[1]


def min(*args, **kw):
    return _minmax(args, kw, False)


def max(*args, **kw):
    return _minmax(args, kw, True)


def sum(iterable, start=0):
    for x in iterable:
        start = start + x
    return start


def sorted(iterable, key=None, reverse=False):
    lst = list(iterable)
    list__sort(lst, key, reverse)
    return lst


def hash(obj):
    return _hashv(obj)


def callable(obj):
    if _tag(obj) != TAG_OBJECT:
        return False
    k = _ld(obj, 0)
    if k == OB_FUNCTION or k == OB_BUILTIN or k == OB_BOUND_METHOD or k == OB_TYPE or k == OB_CLASSMETHOD:
        return True
    if k == OB_INSTANCE or k == OB_EXCEPTION:
        return _tlookup(_ld(obj, 1), '__call__') is not NULL
    return False


def issubclass(cls, classinfo):
    if not _istype(cls):
        raise TypeError('issubclass() arg 1 must be a class')
    if _istype(classinfo):
        return _issub(cls, classinfo)
    if _tag(classinfo) == TAG_TUPLE:
        for c in classinfo:
            if not _istype(c):
                raise TypeError('issubclass() arg 2 must be a class or a tuple of classes')
            if _issub(cls, c):
                return True
        return False
    raise TypeError('issubclass() arg 2 must be a class or a tuple of classes')


def _load_attr(obj, name):
    spec = _special_attr(obj, name)
    if spec is not NULL:
        return spec
    t = _tag(obj)
    if t == TAG_OBJECT:
        k = _ld(obj, 0)
        if k == OB_INSTANCE or k == OB_EXCEPTION:
            d = _ld(obj, 2 if k == OB_INSTANCE else 4)
            if d is not NULL:
                hit = _dget(d, name)
                if hit is not NULL:
                    return hit
            found = _tlookup(_ld(obj, 1), name)
            if found is not NULL:
                return _desc_get(found, obj)
        elif k == OB_MODULE or k == OB_TYPE:
            hit = _lookup(_ld(obj, 2), name)
            if hit is not NULL and hit is not STOP:
                if k == OB_TYPE:
                    return _desc_get(hit, obj)
                return hit
            if k == OB_TYPE:
                found = _tlookup(obj, name)
                if found is not NULL:
                    return _desc_get(found, obj)
        else:
            found = _tlookup(_ld(obj, 1), name)
            if found is not NULL:
                return _desc_get(found, obj)
    elif t == TAG_MUT or t == TAG_TUPLE or t == TAG_BYTES or _isstr(obj):
        # Native containers are not objects. LOAD_ATTR takes the type
        # (S_AT_NT) and binds a function found there.
        found = _tlookup(_typeof(obj), name)
        if found is not NULL:
            return _desc_get(found, obj)
    return _getattr(obj, name)


def getattr(obj, name, default=_MISSING):
    if not _isstr(name):
        raise TypeError('attribute name must be string')
    try:
        return _load_attr(obj, name)
    except AttributeError:
        if default == _MISSING:
            raise
        return default


def hasattr(obj, name):
    try:
        _load_attr(obj, name)
        return True
    except AttributeError:
        return False


def setattr(obj, name, value):
    _setattr(obj, name, value)
    return None


def delattr(obj, name):
    _setattr(obj, name, NULL)
    return None


def globals():
    return _fget(FR_GLOBALS)


def locals():
    loc = _fget(FR_LOCALS)
    if loc is not NULL:
        return loc
    return _fget(FR_GLOBALS)


def dir(*args):
    if len(args) == 0:
        return sorted(globals())
    if len(args) != 1:
        _arg_count(1, len(args))
    obj = args[0]
    names = []
    seen = {}
    if _tag(obj) == TAG_OBJECT:
        k = _ld(obj, 0)
        if k == OB_INSTANCE or k == OB_EXCEPTION:
            d = _ld(obj, 2 if k == OB_INSTANCE else 4)
            if d is not NULL:
                for n in d:
                    names.append(n)
                    seen[n] = True
            mro = _ld(_ld(obj, 1), 5)
        elif k == OB_TYPE:
            mro = _ld(obj, 5)
        elif k == OB_MODULE:
            for n in _ld(obj, 2):
                names.append(n)
            return sorted(names)
        else:
            mro = _ld(_ld(obj, 1), 5)
        i = 0
        n = _ld(mro, 0)
        while i < n:
            d = _ld(_ld(mro, 1 + i), 2)
            for key in d:
                if _dget(seen, key) is NULL:
                    names.append(key)
                    seen[key] = True
            i += 1
    return sorted(names)


def iter(obj, sentinel=_MISSING):
    if sentinel == _MISSING:
        return _getiter(obj)
    o = _alloc(5, TAG_OBJECT, 0)
    _st(o, 0, OB_ITEROBJ)
    _st(o, 1, _ntype(T_ITERATOR))
    _st(o, 2, obj)
    _st(o, 3, sentinel)
    _st(o, 4, 1)
    return o


def next(*args):
    n = len(args)
    if n < 1 or n > 2:
        _arg_count(1, n)
    try:
        return _pull(args[0])
    except StopIteration:
        if n == 2:
            return args[1]
        raise


def repr(obj):
    return _repr(obj)


def property____new__(cls, fget=None, fset=None, fdel=None):
    p = _alloc(5, TAG_OBJECT, 0)
    _st(p, 0, OB_PROPERTY)
    _st(p, 1, cls)
    _st(p, 2, NULL if fget is None else fget)
    _st(p, 3, NULL if fset is None else fset)
    _st(p, 4, NULL if fdel is None else fdel)
    return p


def property__getter(self, fget):
    return property(fget, _ld(self, 3), _ld(self, 4))


def property__setter(self, fset):
    return property(_ld(self, 2), fset, _ld(self, 4))


def property__deleter(self, fdel):
    return property(_ld(self, 2), _ld(self, 3), fdel)


def staticmethod____new__(cls, fn):
    o = _alloc(3, TAG_OBJECT, 0)
    _st(o, 0, OB_STATICMETHOD)
    _st(o, 1, cls)
    _st(o, 2, fn)
    return o


def classmethod____new__(cls, fn):
    o = _alloc(3, TAG_OBJECT, 0)
    _st(o, 0, OB_CLASSMETHOD)
    _st(o, 1, cls)
    _st(o, 2, fn)
    return o


def eval(*args, **kw):
    raise NotImplementedError('eval')


def exec(*args, **kw):
    raise NotImplementedError('exec')


def compile(*args, **kw):
    raise NotImplementedError('compile')


def open(*args, **kw):
    raise OSError('open')


def input(*args, **kw):
    raise OSError('input')


def help(*args):
    return None


def __import__(name, globals=None, locals=None, fromlist=(), level=0):
    g = globals if _isdict(globals) else {}
    return _import(name, fromlist, level, g)
