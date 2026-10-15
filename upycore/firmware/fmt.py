# str(), repr(), print(), and integer formatting (py/objstr.c, py/mpprint.c).
from ._abi import *

_HEX = '0123456789abcdef'


def _istr(n):
    # Decimal text of an int (INT or INT64).
    if 0 <= n < 10:
        return _ch(48 + n)
    buf = _newstr(21)
    d = _data(buf)
    i = 21
    if n < 0:
        while n:
            r = n % -10
            _poke8(d, i - 1, 48 - r)
            i -= 1
            n = (n - r) // 10
        _poke8(d, i - 1, 45)
        i -= 1
    else:
        while n:
            r = n % 10
            _poke8(d, i - 1, 48 + r)
            i -= 1
            n = n // 10
    _bcopy(buf, 0, buf, i, 21 - i)
    return _fin(buf, 21 - i)


def _ubase(n, base, upper):
    # Digits of n >= 0 in base 2, 8, or 16.
    if n == 0:
        return '0'
    buf = _newstr(64)
    d = _data(buf)
    i = 64
    while n:
        r = n % base
        c = _byte(_HEX, r)
        if upper and c >= 97:
            c -= 32
        _poke8(d, i - 1, c)
        i -= 1
        n = n // base
    _bcopy(buf, 0, buf, i, 64 - i)
    return _fin(buf, 64 - i)


def _int_base(n, base, prefix, upper):
    if n < 0:
        if n == -9223372036854775807 - 1:
            # The magnitude does not fit; split off the last digit.
            q = -(n // base)
            r = n % base
            body = _cat(_ubase(q - (1 if r else 0), base, upper), _ubase((base - r) % base, base, upper))
            return _s('-', prefix, body)
        return _s('-', prefix, _ubase(-n, base, upper))
    return _cat(prefix, _ubase(n, base, upper))


def _hexaddr(a):
    # %p of an address: lower-case hex, no prefix.
    return _ubase(a & 0x7FFFFFFF if a >= 0 else a + 4294967296, 16, False)


def _addr(x):
    a = _pay(x)
    if a < 0:
        a += 4294967296
    return a


# ---------------------------------------------------------------------------
# str and bytes repr

def _str_repr(s, is_bytes):
    n = _slen(s)
    d = _data(s)
    sq = False
    dq = False
    i = 0
    while i < n and not dq:
        c = _peek8(d, i)
        if c == 39:
            sq = True
        elif c == 34:
            dq = True
        i += 1
    quote = 34 if (sq and not dq) else 39
    if not is_bytes and not _ascii(s):
        return _ustr_repr(s, quote)
    # Worst case every byte becomes \xNN.
    buf = _newstr(4 * n + 2)
    o = _data(buf)
    _poke8(o, 0, quote)
    j = 1
    i = 0
    while i < n:
        c = _peek8(d, i)
        if c == quote or c == 92:
            _poke8(o, j, 92)
            _poke8(o, j + 1, c)
            j += 2
        elif c >= 32 and c != 127 and (not is_bytes or c < 128):
            _poke8(o, j, c)
            j += 1
        elif c == 10:
            _poke8(o, j, 92)
            _poke8(o, j + 1, 110)
            j += 2
        elif c == 13:
            _poke8(o, j, 92)
            _poke8(o, j + 1, 114)
            j += 2
        elif c == 9:
            _poke8(o, j, 92)
            _poke8(o, j + 1, 116)
            j += 2
        else:
            _poke8(o, j, 92)
            _poke8(o, j + 1, 120)
            _poke8(o, j + 2, _byte(_HEX, c >> 4))
            _poke8(o, j + 3, _byte(_HEX, c & 15))
            j += 4
        i += 1
    _poke8(o, j, quote)
    return _fin(buf, j + 1)


def _ustr_repr(s, quote):
    parts = [_ch(quote)]
    n = _slen(s)
    d = _data(s)
    i = 0
    while i < n:
        c, k = _utf8_at(d, i)
        i += k
        if c == quote or c == 92:
            parts.append(_s('\\', _ch(c)))
        elif 32 <= c <= 126:
            parts.append(_ch(c))
        elif c == 10:
            parts.append('\\n')
        elif c == 13:
            parts.append('\\r')
        elif c == 9:
            parts.append('\\t')
        elif c < 0x100:
            parts.append(_s('\\x', _zpad(_ubase(c, 16, False), 2)))
        elif c < 0x10000:
            parts.append(_s('\\u', _zpad(_ubase(c, 16, False), 4)))
        else:
            parts.append(_s('\\U', _zpad(_ubase(c, 16, False), 8)))
    parts.append(_ch(quote))
    return _join(parts)


def _zpad(s, n):
    k = _slen(s)
    if k >= n:
        return s
    return _cat(_mul_str('0', n - k), s)


def _mul_str(s, n):
    k = _slen(s)
    if n <= 0 or k == 0:
        return '' if _tag(s) != TAG_BYTES else b''
    if n == 1:
        return s
    r = _strnew(k * n, TAG_BYTES if _tag(s) == TAG_BYTES else TAG_STR)
    i = 0
    while i < n:
        _bcopy(r, i * k, s, 0, k)
        i += 1
    return _strfin(r)


def _utf8_at(d, i):
    # (code point, byte count) of the UTF-8 sequence at d + i.
    c = _peek8(d, i)
    if c < 0x80:
        return c, 1
    if c < 0xE0:
        return ((c & 0x1F) << 6) | (_peek8(d, i + 1) & 0x3F), 2
    if c < 0xF0:
        return ((c & 0x0F) << 12) | ((_peek8(d, i + 1) & 0x3F) << 6) | (_peek8(d, i + 2) & 0x3F), 3
    return (((c & 0x07) << 18) | ((_peek8(d, i + 1) & 0x3F) << 12) |
            ((_peek8(d, i + 2) & 0x3F) << 6) | (_peek8(d, i + 3) & 0x3F)), 4


def _utf8_len(s):
    # Code points in s. _slen is the byte length.
    n = _slen(s)
    d = _data(s)
    i = 0
    k = 0
    while i < n:
        _cp, w = _utf8_at(d, i)
        i += w
        k += 1
    return k


def _ustr_at(s, i):
    # Code point i of a non-ASCII str, as a one-character str.
    n = _utf8_len(s)
    if i < 0:
        i += n
    if i < 0 or i >= n:
        raise IndexError('string index out of range')
    d = _data(s)
    p = 0
    k = 0
    while k < i:
        _cp, w = _utf8_at(d, p)
        p += w
        k += 1
    c, w = _utf8_at(d, p)
    if c < 128:
        return _ch(c)
    return _substr(s, p, p + w, TAG_STR)


# ---------------------------------------------------------------------------
# repr / str

def _seq_repr(x, open_, close, one_comma):
    if _tag(x) == TAG_TUPLE:
        base = x
        off = 1
    else:
        base = _ld(x, 2)
        off = 0
    n = _ld(x, 0)
    if n == 0:
        return _cat(open_, close)
    parts = [open_]
    i = 0
    while i < n:
        if i:
            parts.append(', ')
        parts.append(_repr(_ld(base, off + i)))
        i += 1
    if n == 1 and one_comma:
        parts.append(',')
    parts.append(close)
    return _join(parts)


def _dict_repr(d):
    parts = ['{']
    first = True
    for k, v in d.items():
        if not first:
            parts.append(', ')
        first = False
        parts.append(_repr(k))
        parts.append(': ')
        parts.append(_repr(v))
    parts.append('}')
    return _join(parts)


def _set_repr(s):
    frozen = (_ld(s, 3) & SET_FLAG_FROZEN) != 0
    if _ld(s, 0) == 0:
        return 'frozenset()' if frozen else 'set()'
    parts = ['frozenset({' if frozen else '{']
    first = True
    for k in s:
        if not first:
            parts.append(', ')
        first = False
        parts.append(_repr(k))
    parts.append('})' if frozen else '}')
    return _join(parts)


def _exc_args_str(e):
    args = _ld(e, 2)
    n = len(args)
    if n == 0:
        return ''
    if n == 1:
        if _issub(_ld(e, 1), _ntype(T_KEYERROR)):
            return _repr(args[0])
        return _str(args[0])
    return _seq_repr(args, '(', ')', True)


def _exc_repr_native(e):
    return _cat(_tname(e), _seq_repr(_ld(e, 2), '(', ')', True))


def _user_method(x, name):
    # A __str__/__repr__ defined by a user class above any native base.
    mro = _ld(_ld(x, 1), 5)
    n = _ld(mro, 0)
    i = 0
    while i < n:
        t = _ld(mro, 1 + i)
        if not (_ld(t, 7) & TF_USER):
            return NULL
        f = _lookup(_ld(t, 2), name)
        if f is not NULL:
            return f
        i += 1
    return NULL


def _obj_repr(x, as_str):
    k = _ld(x, 0)
    if k == OB_INSTANCE or k == OB_EXCEPTION:
        t = _ld(x, 1)
        if _ld(t, 7) & TF_USER:
            nb = _native_base(t)
            if as_str:
                f = _user_method(x, '__str__')
                if f is not NULL:
                    return _str(_callattr(f, x))
            f = _user_method(x, '__repr__')
            if f is not NULL and (not as_str or nb is object):
                return _str(_callattr(f, x))
            if k == OB_EXCEPTION or (nb is not object and (_tflags(nb) & TF_EXC)):
                if as_str:
                    return _exc_args_str(x)
                return _exc_repr_native(x)
            if nb is not object:
                return _native_sub_repr(x, nb, as_str)
            return _s('<', _ld(t, 4), ' object at ', _hexaddr(_addr(x)), '>')
        if k == OB_EXCEPTION:
            if as_str:
                return _exc_args_str(x)
            return _exc_repr_native(x)
        return _s('<', _ld(t, 4), ' object at ', _hexaddr(_addr(x)), '>')
    if k == OB_TYPE:
        return _s("<class '", _ld(x, 4), "'>")
    if k == OB_FUNCTION:
        if _peek32(_ld(x, 2) + 4 * RC_SIG) >> 24 & RC_FLAG_FIRMWARE:
            return '<function>'
        return _s('<function ', _rc_name(x), ' at 0x', _hexaddr(_addr(x)), '>')
    if k == OB_BUILTIN:
        return '<function>'
    if k == OB_BOUND_METHOD:
        return '<bound_method>'
    if k == OB_MODULE:
        return _s("<module '", _ld(x, 3), "'>")
    if k == OB_ELLIPSIS:
        return 'Ellipsis'
    if k == OB_NOTIMPL:
        return 'NotImplemented'
    if k == OB_SLICE:
        return _s('slice(', _repr(_ld(x, 2)), ', ', _repr(_ld(x, 3)), ', ', _repr(_ld(x, 4)), ')')
    if k == OB_PROPERTY:
        return '<property>'
    if k == OB_STATICMETHOD:
        return '<staticmethod>'
    if k == OB_CLASSMETHOD:
        return '<classmethod>'
    if k == OB_CELL:
        return _s('<cell ', _hexaddr(_addr(x)), '>')
    if k == OB_DICT_VIEW:
        vk = _ld(x, 3)
        name = 'dict_keys' if vk == 0 else ('dict_values' if vk == 1 else 'dict_items')
        return _s(name, '(', _seq_repr(list(x), '[', ']', False), ')')
    if k == OB_SUPER:
        return '<super>'
    t = _ld(x, 1)
    return _s('<', _ld(t, 4), '>')


def _rc_name(f):
    rc = _ld(f, 2)
    return _mk(TAG_QSTR, _peek32(rc + 4 * RC_NAME))


def _repr(x):
    t = _tag(x)
    if t == TAG_QSTR or t == TAG_STR:
        return _str_repr(x, False)
    if t == TAG_INT or t == TAG_INT64:
        return _istr(x)
    if t == TAG_CONTROL:
        if x is None:
            return 'None'
        if x is True:
            return 'True'
        if x is False:
            return 'False'
        return '<null>'
    if t == TAG_FLOAT:
        return _float_repr(x)
    if t == TAG_COMPLEX:
        return _complex_repr(x)
    if t == TAG_TUPLE:
        return _seq_repr(x, '(', ')', True)
    if t == TAG_MUT:
        k = _pay(x) & 3
        if k == MUT_LIST:
            return _seq_repr(x, '[', ']', False)
        if k == MUT_DICT:
            return _dict_repr(x)
        if k == MUT_SET:
            return _set_repr(x)
        return _s('bytearray(', _str_repr(_barr_bytes(x), True), ')')
    if t == TAG_BYTES:
        return _cat('b', _str_repr(x, True))
    if t == TAG_RANGE:
        step = _ld(x, 2)
        if step == 1:
            return _s('range(', _istr(_ld(x, 0)), ', ', _istr(_ld(x, 1)), ')')
        return _s('range(', _istr(_ld(x, 0)), ', ', _istr(_ld(x, 1)), ', ', _istr(step), ')')
    if t == TAG_ITER:
        return '<iterator>'
    if t == TAG_OBJECT:
        return _obj_repr(x, False)
    return '<?>'


def _str(x):
    t = _tag(x)
    if t == TAG_QSTR or t == TAG_STR:
        return x
    if t == TAG_OBJECT:
        return _obj_repr(x, True)
    return _repr(x)


def repr(obj):
    return _repr(obj)


def str____new__(cls, *args):
    n = len(args)
    if n == 0:
        r = ''
    elif n == 1:
        r = _str(args[0])
    else:
        r = _decode(args[0], args[1])
    if cls is not str:
        return _native_sub_new(cls, r)
    return r


def _decode(b, enc):
    if not _isstr(enc):
        raise TypeError(_s("argument should be a 'str' not a '", _tname(enc), "'"))
    if not (_streq(enc, 'utf-8') or _streq(enc, 'utf8') or _streq(enc, 'ascii') or _streq(enc, 'latin-1')):
        raise LookupError(_s('unknown encoding: ', enc))
    if _isbarr(b):
        b = _barr_bytes(b)
    if _tag(b) != TAG_BYTES:
        raise TypeError("string argument without an encoding" if _isstr(b) else "object with buffer protocol required")
    n = _slen(b)
    r = _strnew(n, TAG_STR)
    _bcopy(r, 0, b, 0, n)
    return _strfin(r)


def print(*args, **kw):
    sep = ' '
    end = '\n'
    out = _wr
    if kw:
        for k, v in kw.items():
            if _streq(k, 'sep'):
                if v is not None:
                    sep = v
            elif _streq(k, 'end'):
                if v is not None:
                    end = v
            elif _streq(k, 'file'):
                if v is not None:
                    out = _stream_writer(v)
            elif _streq(k, 'flush'):
                pass
            else:
                raise TypeError('extra keyword arguments given')
    first = True
    for a in args:
        if not first:
            out(sep)
        first = False
        out(_str(a))
    out(end)


def _stream_writer(f):
    if f is mod_sys__stderr:
        return _we
    if f is mod_sys__stdout:
        return _wr
    w = getattr(f, 'write')
    return w
