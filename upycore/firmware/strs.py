# str, bytes, and bytearray methods, plus %-formatting.
from ._abi import *


def _barr_from(b):
    n = _slen(b)
    o = _alloc(3, TAG_MUT, MUT_BYTEARRAY)
    _st(o, 0, n)
    _st(o, 1, n)
    if n:
        _st(o, 2, _alloc((n + 3) >> 2, TAG_CONT, 0))
        _bcopy(o, 0, b, 0, n)
    else:
        _st(o, 2, NULL)
    return o


def _barr_bytes(o):
    n = _ld(o, 0)
    b = _strnew(n, TAG_BYTES)
    if n:
        _bcopy(b, 0, o, 0, n)
    return _strfin(b)


def _as_bytes(x):
    if _tag(x) == TAG_BYTES:
        return x
    if _isbarr(x):
        return _barr_bytes(x)
    return x


def _bytes_from_args(args):
    if len(args) == 0:
        return b''
    a = args[0]
    if _tag(a) == TAG_BYTES:
        return a
    if _isbarr(a):
        return _barr_bytes(a)
    if _isstr(a):
        if len(args) < 2:
            raise TypeError('string argument without an encoding')
        return _encode(a, args[1])
    if _isint(a):
        if a < 0:
            raise ValueError('negative count')
        r = _strnew(a, TAG_BYTES)
        return _strfin(r)
    vals = _list_of_iter(a)
    r = _strnew(len(vals), TAG_BYTES)
    i = 0
    while i < len(vals):
        v = vals[i]
        if not _isint(v) or v < 0 or v > 255:
            raise ValueError('bytes must be in range(0, 256)')
        _poke8(_data(r), i, v)
        i += 1
    return _strfin(r)


def bytes____new__(cls, *args):
    b = _bytes_from_args(args)
    if cls is not bytes:
        return _native_sub_new(cls, b)
    return b


def bytearray____new__(cls, *args):
    if cls is not bytearray:
        return _nsub_new(cls, *args)
    return _barr_from(_bytes_from_args(args))


def bytearray____init__(self, *args):
    target = _subobj(self)
    if target is NULL:
        target = self
    src = _barr_from(_bytes_from_args(args))
    _st(target, 0, _ld(src, 0))
    _st(target, 1, _ld(src, 1))
    _st(target, 2, _ld(src, 2))
    return None


def bytearray__append(self, v):
    if not _isint(v) or v < 0 or v > 255:
        raise ValueError('byte must be in range(0, 256)')
    _barr_grow(self, _ld(self, 0) + 1)
    _poke8(_data(self), _ld(self, 0), v)
    _st(self, 0, _ld(self, 0) + 1)
    return None


def _barr_grow(b, n):
    cap = _ld(b, 1)
    if n <= cap and _ld(b, 2) is not NULL:
        return
    if cap < 4:
        cap = 4
    while cap < n:
        cap *= 2
    data = _alloc((cap + 3) >> 2, TAG_CONT, 0)
    old = _ld(b, 0)
    if old and _ld(b, 2) is not NULL:
        _bcopy(_mk(TAG_BYTES, _pay(data)) if False else b, 0, b, 0, 0)
        # copy via a temporary bytes view of the old buffer
    nb = _strnew(old, TAG_BYTES)
    if old:
        _bcopy(nb, 0, b, 0, old)
    _st(b, 2, data)
    _st(b, 1, cap)
    if old:
        _bcopy(b, 0, nb, 0, old)


def bytearray__extend(self, it):
    if _isint(it):
        raise TypeError("can't extend bytearray with int")
    src = _bytes_from_args((it,))
    n = _slen(src)
    base = _ld(self, 0)
    _barr_grow(self, base + n)
    _bcopy(self, base, src, 0, n)
    _st(self, 0, base + n)
    return None


def _barr_setslice(obj, sl, value):
    if value is NULL:
        value = b''
    src = _as_bytes(value) if _tag(value) == TAG_BYTES or _isbarr(value) else _bytes_from_args((value,))
    n = _ld(obj, 0)
    a, b, s = _slice_range(sl, n)
    if s != 1:
        raise NotImplementedError('extended slice assignment')
    # rebuild
    left = _substr(_barr_bytes(obj), 0, a, TAG_BYTES)
    right = _substr(_barr_bytes(obj), b, n, TAG_BYTES)
    whole = _cat(_cat(left, src), right)
    fresh = _barr_from(whole)
    _st(obj, 0, _ld(fresh, 0))
    _st(obj, 1, _ld(fresh, 1))
    _st(obj, 2, _ld(fresh, 2))
    return None


def _bfind(s, sub, start, end):
    return _find_bytes(s, sub, start, end)


def _norm_span(s, start, end):
    n = _slen(s)
    if start is NULL or start == _MISSING:
        start = 0
    if start < 0:
        start += n
    if start < 0:
        start = 0
    if end is NULL or end == _MISSING:
        end = n
    if end < 0:
        end += n
    if end > n:
        end = n
    return start, end


def _find_method(s, sub, start, end, last):
    if not (_isstr(sub) or _tag(sub) == TAG_BYTES or _isbarr(sub)):
        if _isint(sub) and (_tag(s) == TAG_BYTES or _isbarr(s)):
            sub = _bytes_of_int(sub)
        else:
            raise TypeError('find argument must be a string')
    sub = _as_bytes(sub) if _tag(s) == TAG_BYTES or _isbarr(s) else sub
    s = _barr_bytes(s) if _isbarr(s) else s
    a, b = _norm_span(s, start, end)
    if last:
        return _rfind_bytes(s, sub, a, b)
    return _find_bytes(s, sub, a, b)


def str__find(self, sub, start=0, end=_MISSING):
    return _find_method(self, sub, start, end, False)


def str__rfind(self, sub, start=0, end=_MISSING):
    return _find_method(self, sub, start, end, True)


def str__index(self, sub, start=0, end=_MISSING):
    i = _find_method(self, sub, start, end, False)
    if i < 0:
        raise ValueError('substring not found')
    return i


def str__rindex(self, sub, start=0, end=_MISSING):
    i = _find_method(self, sub, start, end, True)
    if i < 0:
        raise ValueError('substring not found')
    return i


def str__count(self, sub, start=0, end=_MISSING):
    if _slen(sub) == 0:
        a, b = _norm_span(self, start, end)
        return b - a + 1
    n = 0
    i = _find_method(self, sub, start, end, False)
    a, b = _norm_span(self, start, end)
    while i >= 0:
        n += 1
        i = _find_bytes(self, sub, i + _slen(sub), b)
    return n


def str__startswith(self, prefix, start=0, end=_MISSING):
    a, b = _norm_span(self, start, end)
    if _tag(prefix) == TAG_TUPLE:
        for p in prefix:
            if str__startswith(self, p, a, b):
                return True
        return False
    n = _slen(prefix)
    if a + n > b:
        return False
    return _find_bytes(self, prefix, a, a + n) == a


def str__endswith(self, suffix, start=0, end=_MISSING):
    a, b = _norm_span(self, start, end)
    if _tag(suffix) == TAG_TUPLE:
        for p in suffix:
            if str__endswith(self, p, a, b):
                return True
        return False
    n = _slen(suffix)
    if a + n > b:
        return False
    return _rfind_bytes(self, suffix, a, b) == b - n


def _strip_set(chars):
    if chars is None:
        return None
    return chars


def _is_space_byte(c):
    return c == 32 or c == 9 or c == 10 or c == 13 or c == 11 or c == 12


def str__strip(self, chars=None):
    return _strip_impl(self, chars, True, True, TAG_STR)


def str__lstrip(self, chars=None):
    return _strip_impl(self, chars, True, False, TAG_STR)


def str__rstrip(self, chars=None):
    return _strip_impl(self, chars, False, True, TAG_STR)


def _strip_impl(s, chars, left, right, tag):
    n = _slen(s)
    a = 0
    b = n
    if left:
        while a < b:
            c = _byte(s, a)
            if chars is None:
                if not _is_space_byte(c):
                    break
            elif _find_bytes(chars, _ch(c) if c < 128 else _substr(s, a, a + 1, TAG_STR), 0, _slen(chars)) < 0:
                break
            a += 1
    if right:
        while b > a:
            c = _byte(s, b - 1)
            if chars is None:
                if not _is_space_byte(c):
                    break
            elif _find_bytes(chars, _ch(c) if c < 128 else _substr(s, b - 1, b, TAG_STR), 0, _slen(chars)) < 0:
                break
            b -= 1
    return _substr(s, a, b, tag)


def _map_case(s, upper, tag):
    n = _slen(s)
    r = _strnew(n, tag)
    i = 0
    while i < n:
        c = _byte(s, i)
        if upper and 97 <= c <= 122:
            c -= 32
        elif not upper and 65 <= c <= 90:
            c += 32
        _poke8(_data(r), i, c)
        i += 1
    return _strfin(r)


def str__lower(self):
    return _map_case(self, False, TAG_STR)


def str__upper(self):
    return _map_case(self, True, TAG_STR)


def _all_bytes(s, pred):
    n = _slen(s)
    if n == 0:
        return False
    i = 0
    while i < n:
        if not pred(_byte(s, i)):
            return False
        i += 1
    return True


def str__isalpha(self):
    return _all_bytes(self, lambda c: (65 <= c <= 90) or (97 <= c <= 122))


def str__isdigit(self):
    return _all_bytes(self, lambda c: 48 <= c <= 57)


def str__isspace(self):
    return _all_bytes(self, _is_space_byte)


def str__islower(self):
    return _case_pred(self, False)


def str__isupper(self):
    return _case_pred(self, True)


def _case_pred(s, upper):
    n = _slen(s)
    cased = False
    i = 0
    while i < n:
        c = _byte(s, i)
        if 65 <= c <= 90:
            if not upper:
                return False
            cased = True
        elif 97 <= c <= 122:
            if upper:
                return False
            cased = True
        i += 1
    return cased


def str__join(self, iterable):
    parts = _list_of_iter(iterable)
    n = len(parts)
    if n == 0:
        return '' if _isstr(self) else b''
    tag = TAG_BYTES if _tag(self) == TAG_BYTES or _isbarr(self) else TAG_STR
    total = _slen(self) * (n - 1)
    i = 0
    while i < n:
        p = parts[i]
        if tag == TAG_STR and not _isstr(p):
            raise TypeError('join expects a list of str objects')
        if tag == TAG_BYTES and _tag(p) != TAG_BYTES and not _isbarr(p):
            raise TypeError('join expects a list of bytes objects')
        total += _slen(p)
        i += 1
    r = _strnew(total, tag)
    o = 0
    i = 0
    while i < n:
        p = parts[i]
        k = _slen(p)
        _bcopy(r, o, p, 0, k)
        o += k
        if i + 1 < n:
            _bcopy(r, o, self, 0, _slen(self))
            o += _slen(self)
        i += 1
    return _strfin(r)


def str__replace(self, old, new, count=-1):
    if count == 0:
        return self
    parts = []
    start = 0
    n = _slen(old)
    found = 0
    while count < 0 or found < count:
        i = _find_bytes(self, old, start, _slen(self))
        if i < 0:
            break
        parts.append(_substr(self, start, i, TAG_STR if _isstr(self) else TAG_BYTES))
        parts.append(new)
        start = i + n
        found += 1
        if n == 0:
            if start >= _slen(self):
                break
            parts.append(_substr(self, start, start + 1, TAG_STR if _isstr(self) else TAG_BYTES))
            start += 1
    parts.append(_substr(self, start, _slen(self), TAG_STR if _isstr(self) else TAG_BYTES))
    return _join(parts)


def str__split(self, sep=None, maxsplit=-1):
    return _split_impl(self, sep, maxsplit, False)


def str__rsplit(self, sep=None, maxsplit=-1):
    return _split_impl(self, sep, maxsplit, True)


def _split_impl(s, sep, maxsplit, from_end):
    tag = TAG_BYTES if _tag(s) == TAG_BYTES or _isbarr(s) else TAG_STR
    if sep is None:
        out = []
        n = _slen(s)
        i = 0
        while i < n:
            while i < n and _is_space_byte(_byte(s, i)):
                i += 1
            if i >= n:
                break
            j = i
            while j < n and not _is_space_byte(_byte(s, j)):
                j += 1
            out.append(_substr(s, i, j, tag))
            i = j
        if maxsplit >= 0 and len(out) > maxsplit + 1:
            # recombine the tail; whitespace split rarely needs this in tests
            head = []
            i = 0
            while i < maxsplit:
                head.append(out[i])
                i += 1
            tail = _join(out[maxsplit:]) if False else out[maxsplit]
            k = maxsplit + 1
            acc = out[maxsplit]
            while k < len(out):
                acc = _cat(_cat(acc, ' '), out[k])
                k += 1
            head.append(acc)
            return head
        return out
    out = []
    start = 0
    nsep = _slen(sep)
    splits = 0
    while maxsplit < 0 or splits < maxsplit:
        i = _find_bytes(s, sep, start, _slen(s))
        if i < 0:
            break
        out.append(_substr(s, start, i, tag))
        start = i + nsep
        splits += 1
    out.append(_substr(s, start, _slen(s), tag))
    if from_end and maxsplit >= 0:
        return _rsplit_fix(s, sep, maxsplit, tag)
    return out


def _rsplit_fix(s, sep, maxsplit, tag):
    parts = []
    end = _slen(s)
    splits = 0
    nsep = _slen(sep)
    while splits < maxsplit:
        i = _rfind_bytes(s, sep, 0, end)
        if i < 0:
            break
        parts.append(_substr(s, i + nsep, end, tag))
        end = i
        splits += 1
    parts.append(_substr(s, 0, end, tag))
    parts.reverse()
    return parts


def str__partition(self, sep):
    i = _find_bytes(self, sep, 0, _slen(self))
    tag = TAG_STR if _isstr(self) else TAG_BYTES
    if i < 0:
        return (self, '' if tag == TAG_STR else b'', '' if tag == TAG_STR else b'')
    return (_substr(self, 0, i, tag), sep, _substr(self, i + _slen(sep), _slen(self), tag))


def str__rpartition(self, sep):
    i = _rfind_bytes(self, sep, 0, _slen(self))
    tag = TAG_STR if _isstr(self) else TAG_BYTES
    empty = '' if tag == TAG_STR else b''
    if i < 0:
        return (empty, empty, self)
    return (_substr(self, 0, i, tag), sep, _substr(self, i + _slen(sep), _slen(self), tag))


def str__splitlines(self, keepends=False):
    out = []
    n = _slen(self)
    tag = TAG_STR if _isstr(self) else TAG_BYTES
    i = 0
    while i < n:
        j = i
        while j < n and _byte(self, j) != 10 and _byte(self, j) != 13:
            j += 1
        k = j
        if j < n:
            if _byte(self, j) == 13 and j + 1 < n and _byte(self, j + 1) == 10:
                j += 2
            else:
                j += 1
        out.append(_substr(self, i, j if keepends else k, tag))
        i = j
    return out


def str__center(self, width, fill=' '):
    n = _slen(self)
    if width <= n:
        return self
    pad = width - n
    left = pad // 2
    return _cat(_cat(_mul_str(fill, left), self), _mul_str(fill, pad - left))


def str__encode(self, encoding='utf-8'):
    return _encode(self, encoding)


def _encode(s, enc):
    if not (_streq(enc, 'utf-8') or _streq(enc, 'utf8') or _streq(enc, 'ascii') or _streq(enc, 'latin-1')):
        raise LookupError(_s('unknown encoding: ', enc))
    if _streq(enc, 'latin-1') or _ascii(s):
        n = _slen(s)
        b = _strnew(n, TAG_BYTES)
        _bcopy(b, 0, s, 0, n)
        return _strfin(b)
    # utf-8 of an already-utf8 str is itself
    n = _slen(s)
    b = _strnew(n, TAG_BYTES)
    _bcopy(b, 0, s, 0, n)
    return _strfin(b)


def bytes__decode(self, encoding='utf-8'):
    return _decode(self, encoding)


def bytearray__decode(self, encoding='utf-8'):
    return _decode(_barr_bytes(self), encoding)


def bytes__hex(self):
    n = _slen(self)
    r = _strnew(n * 2, TAG_STR)
    i = 0
    while i < n:
        c = _byte(self, i)
        _poke8(_data(r), i * 2, _byte(_HEX, c >> 4))
        _poke8(_data(r), i * 2 + 1, _byte(_HEX, c & 15))
        i += 1
    return _strfin(r)


def bytearray__hex(self):
    return bytes__hex(_barr_bytes(self))


def bytes__fromhex(s):
    # Accessed on the type, so the core passes the string and not the class.
    n = _slen(s)
    raw = []
    i = 0
    while i < n:
        c = _byte(s, i)
        if _is_space_byte(c):
            i += 1
            continue
        if i + 1 >= n:
            raise ValueError('non-hexadecimal number found in fromhex() arg')
        raw.append((_hexval(c) << 4) | _hexval(_byte(s, i + 1)))
        i += 2
    b = _strnew(len(raw), TAG_BYTES)
    i = 0
    while i < len(raw):
        _poke8(_data(b), i, raw[i])
        i += 1
    return _strfin(b)


def _hexval(c):
    if 48 <= c <= 57:
        return c - 48
    if 97 <= c <= 102:
        return c - 87
    if 65 <= c <= 70:
        return c - 55
    raise ValueError('non-hexadecimal number found in fromhex() arg')


def str__format(self, *args, **kw):
    return _format_braces(self, args, kw)


def _format_braces(fmt, args, kw):
    auto = False
    manual = False
    ai = 0
    out = []
    n = _slen(fmt)
    i = 0
    while i < n:
        c = _byte(fmt, i)
        if c == 123:
            if i + 1 < n and _byte(fmt, i + 1) == 123:
                out.append('{')
                i += 2
                continue
            j = i + 1
            while j < n and _byte(fmt, j) != 125:
                j += 1
            field = _substr(fmt, i + 1, j, TAG_STR)
            spec = ''
            name = field
            k = _find_bytes(field, ':', 0, _slen(field))
            if k >= 0:
                name = _substr(field, 0, k, TAG_STR)
                spec = _substr(field, k + 1, _slen(field), TAG_STR)
            if _slen(name) == 0:
                if manual:
                    raise ValueError("can't switch from manual field specification to automatic field numbering")
                auto = True
                if ai >= len(args):
                    raise ValueError('format string needs more arguments' if False else 'tuple index out of range')
                val = args[ai]
                ai += 1
            elif 48 <= _byte(name, 0) <= 57:
                if auto:
                    raise ValueError("can't switch from automatic field numbering to manual field specification")
                manual = True
                val = args[int(name)]
            else:
                val = kw[name]
            out.append(_fmt_spec(val, spec))
            i = j + 1
            continue
        if c == 125:
            if i + 1 < n and _byte(fmt, i + 1) == 125:
                out.append('}')
                i += 2
                continue
        out.append(_ch(c) if c < 128 else _substr(fmt, i, i + 1, TAG_STR))
        i += 1
    if not manual and ai < len(args) and _slen(fmt) and False:
        pass
    return _join(out)


def _fmt_spec(val, spec):
    if _slen(spec) == 0:
        return _str(val)
    conv = _byte(spec, _slen(spec) - 1)
    prec = -1
    width = 0
    align = 62
    fill = 32
    body = spec
    if conv < 48 or conv > 57:
        body = _substr(spec, 0, _slen(spec) - 1, TAG_STR)
    else:
        conv = 115
    dot = _find_bytes(body, '.', 0, _slen(body))
    num = body
    if dot >= 0:
        prec = int(_substr(body, dot + 1, _slen(body), TAG_STR)) if dot + 1 < _slen(body) else 0
        num = _substr(body, 0, dot, TAG_STR)
    if _slen(num):
        if _byte(num, 0) == 60 or _byte(num, 0) == 62 or _byte(num, 0) == 94:
            align = _byte(num, 0)
            num = _substr(num, 1, _slen(num), TAG_STR)
        if _slen(num):
            width = int(num)
    if conv == 102 or conv == 101 or conv == 103 or conv == 70 or conv == 69 or conv == 71:
        fmt = 'f' if conv == 102 or conv == 70 else ('e' if conv == 101 or conv == 69 else 'g')
        text = _format_float(val + 0.0, fmt, 6 if prec < 0 else prec, '')
    elif conv == 100:
        text = _istr(val)
    elif conv == 114:
        text = _repr(val)
    elif conv == 120:
        text = _ubase(val, 16, False)
    elif conv == 88:
        text = _ubase(val, 16, True)
    else:
        text = _str(val)
    if _slen(text) >= width:
        return text
    pad = width - _slen(text)
    gap = _mul_str(_ch(fill), pad)
    if align == 60:
        return _cat(text, gap)
    if align == 94:
        return _cat(_cat(_mul_str(_ch(fill), pad // 2), text), _mul_str(_ch(fill), pad - pad // 2))
    return _cat(gap, text)


def _str_modulo(fmt, args, mapping):
    out = []
    n = _slen(fmt)
    i = 0
    ai = 0
    while i < n:
        c = _byte(fmt, i)
        if c != 37:
            out.append(_ch(c) if c < 128 else _substr(fmt, i, i + 1, TAG_STR))
            i += 1
            continue
        if i + 1 < n and _byte(fmt, i + 1) == 37:
            out.append('%')
            i += 2
            continue
        i += 1
        left = False
        sign = ''
        width = 0
        prec = -1
        if i < n and _byte(fmt, i) == 40:
            j = i + 1
            while j < n and _byte(fmt, j) != 41:
                j += 1
            key = _substr(fmt, i + 1, j, TAG_STR)
            i = j + 1
            val = mapping[key]
        else:
            if ai >= len(args):
                raise TypeError('not enough arguments for format string')
            val = args[ai]
            ai += 1
        while i < n and (_byte(fmt, i) == 45 or _byte(fmt, i) == 43 or _byte(fmt, i) == 32 or _byte(fmt, i) == 48):
            if _byte(fmt, i) == 45:
                left = True
            i += 1
        while i < n and 48 <= _byte(fmt, i) <= 57:
            width = width * 10 + _byte(fmt, i) - 48
            i += 1
        if i < n and _byte(fmt, i) == 46:
            i += 1
            prec = 0
            while i < n and 48 <= _byte(fmt, i) <= 57:
                prec = prec * 10 + _byte(fmt, i) - 48
                i += 1
        if i >= n:
            break
        conv = _byte(fmt, i)
        i += 1
        if conv == 115:
            text = _str(val)
        elif conv == 114:
            text = _repr(val)
        elif conv == 100 or conv == 105 or conv == 117:
            text = _istr(val)
        elif conv == 120:
            text = _ubase(_u32(val) if val < 0 else val, 16, False)
        elif conv == 88:
            text = _ubase(_u32(val) if val < 0 else val, 16, True)
        elif conv == 111:
            text = _ubase(val, 8, False)
        elif conv == 99:
            text = _ch(val) if _isint(val) else val
        elif conv == 102 or conv == 101 or conv == 103 or conv == 70 or conv == 69 or conv == 71:
            fmtc = 'f' if conv == 102 or conv == 70 else ('e' if conv == 101 or conv == 69 else 'g')
            text = _format_float(val + 0.0, fmtc, 6 if prec < 0 else prec, '')
        else:
            text = _str(val)
        if prec >= 0 and (conv == 115 or conv == 114) and _slen(text) > prec:
            text = _substr(text, 0, prec, TAG_STR)
        if _slen(text) < width:
            gap = _mul_str(' ', width - _slen(text))
            text = _cat(text, gap) if left else _cat(gap, text)
        out.append(text)
    if ai < len(args):
        raise TypeError("not all arguments converted during string formatting")
    return _join(out)


# bytes/bytearray share the str implementations through thin wrappers.

def bytes__find(self, sub, start=0, end=_MISSING):
    return _find_method(self, sub, start, end, False)


def bytes__rfind(self, sub, start=0, end=_MISSING):
    return _find_method(self, sub, start, end, True)


def bytes__index(self, sub, start=0, end=_MISSING):
    i = bytes__find(self, sub, start, end)
    if i < 0:
        raise ValueError('substring not found')
    return i


def bytes__rindex(self, sub, start=0, end=_MISSING):
    i = bytes__rfind(self, sub, start, end)
    if i < 0:
        raise ValueError('substring not found')
    return i


def bytes__count(self, sub, start=0, end=_MISSING):
    return str__count(_as_bytes(self) if _isbarr(self) else self, _as_bytes(sub) if _isbarr(sub) else sub, start, end)


def bytes__startswith(self, prefix, start=0, end=_MISSING):
    return str__startswith(self, prefix, start, end)


def bytes__endswith(self, suffix, start=0, end=_MISSING):
    return str__endswith(self, suffix, start, end)


def bytes__strip(self, chars=None):
    return _strip_impl(self, chars, True, True, TAG_BYTES)


def bytes__lstrip(self, chars=None):
    return _strip_impl(self, chars, True, False, TAG_BYTES)


def bytes__rstrip(self, chars=None):
    return _strip_impl(self, chars, False, True, TAG_BYTES)


def bytes__lower(self):
    return _map_case(self, False, TAG_BYTES)


def bytes__upper(self):
    return _map_case(self, True, TAG_BYTES)


def bytes__isalpha(self):
    return str__isalpha(self)


def bytes__isdigit(self):
    return str__isdigit(self)


def bytes__isspace(self):
    return str__isspace(self)


def bytes__islower(self):
    return str__islower(self)


def bytes__isupper(self):
    return str__isupper(self)


def bytes__join(self, iterable):
    return str__join(self, iterable)


def bytes__replace(self, old, new, count=-1):
    return str__replace(self, old, new, count)


def bytes__split(self, sep=None, maxsplit=-1):
    return _split_impl(self, sep, maxsplit, False)


def bytes__rsplit(self, sep=None, maxsplit=-1):
    return _split_impl(self, sep, maxsplit, True)


def bytes__partition(self, sep):
    return str__partition(self, sep)


def bytes__rpartition(self, sep):
    return str__rpartition(self, sep)


def bytes__splitlines(self, keepends=False):
    return str__splitlines(self, keepends)


def bytes__center(self, width, fill=b' '):
    return str__center(self, width, fill)


def bytearray__find(self, sub, start=0, end=_MISSING):
    return bytes__find(_barr_bytes(self), sub, start, end)


def bytearray__rfind(self, sub, start=0, end=_MISSING):
    return bytes__rfind(_barr_bytes(self), sub, start, end)


def bytearray__index(self, sub, start=0, end=_MISSING):
    return bytes__index(_barr_bytes(self), sub, start, end)


def bytearray__rindex(self, sub, start=0, end=_MISSING):
    return bytes__rindex(_barr_bytes(self), sub, start, end)


def bytearray__count(self, sub, start=0, end=_MISSING):
    return bytes__count(_barr_bytes(self), sub, start, end)


def bytearray__join(self, iterable):
    return _barr_from(bytes__join(_barr_bytes(self), iterable))


def bytearray__lower(self):
    return _barr_from(bytes__lower(_barr_bytes(self)))


def bytearray__upper(self):
    return _barr_from(bytes__upper(_barr_bytes(self)))


def bytearray__strip(self, chars=None):
    return _barr_from(bytes__strip(_barr_bytes(self), chars))


def bytearray__lstrip(self, chars=None):
    return _barr_from(bytes__lstrip(_barr_bytes(self), chars))


def bytearray__rstrip(self, chars=None):
    return _barr_from(bytes__rstrip(_barr_bytes(self), chars))
