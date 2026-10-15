# Binary32 float formatting and parsing (py/formatfloat.c, py/parsenum.c,
# APPROX). Powers of five are the binary32 values of 5**n, so decimal_exp
# matches the host model that was checked against the oracle's repr.
from ._abi import *

_MM = const(429496728)
_POW5 = (
    1065353216, 1084227584, 1103626240, 1123680256, 1142702080, 1162039296,
    1182016512, 1201182336, 1220459552, 1240361768, 1259668217, 1278886839,
    1298715813, 1318159591, 1337320993, 1357078441, 1376656330, 1395761852,
    1415449451, 1435158307, 1454209260, 1473828647, 1493665400, 1512663062,
    1532215836, 1552177489, 1571123110, 1590610831, 1610694457, 1629589256,
    1649013450, 1669099388, 1688061358, 1707423513, 1727431903, 1746539276,
    1765840846, 1785773506, 1805022873, 1824265280, 1844123984, 1863512018,
    1882696646, 1902483128, 1922006579, 1941134784, 1960850735, 1980506430,
    1999579533, 2019226608, 2039011446, 2058030740, 2077610553, 2097521507,
    2116488252,
)
_POW5N = (
    1045220557, 1025758986, 1006834287, 986822423, 967296428, 948320189,
    928432021, 908840055, 889811039, 870049535,
)
_LOG10_2 = 0.3010299956639812


def _frombits(b):
    if b >= _U32 // 2:
        b = b - _U32
    return _mk(TAG_FLOAT, b)


def _pow5(n):
    if n >= 0:
        if n >= len(_POW5):
            return _frombits(2139095040)
        return _frombits(_POW5[n])
    if -n <= len(_POW5N):
        return _frombits(_POW5N[-n - 1])
    return 0.0


# decimal_exp multiplies by a power of five, in binary32, as the oracle does.
def _decimal_exp(num, e):
    if e == 0 or num == 0.0:
        return num
    b = _u32(_pay(num))
    exp = ((b >> 23) & 255) + e
    b = (b & ~(255 << 23)) | ((exp & 255) << 23)
    r = _frombits(b)
    if -10 <= e < 0:
        return r / _pow5(-e)
    return r * _pow5(e)


def _fkind(f):
    # 0 finite, 1 inf, 2 nan.
    b = _u32(_pay(f))
    if ((b >> 23) & 255) != 255:
        return 0
    if (b & 8388607) == 0:
        return 1
    return 2


def _ff_parse(s):
    # The check parser inside mp_format_float. s is the digits it just emitted.
    mant = 0
    exp_val = 0
    extra = 0
    tzi = 0
    tzf = 0
    st = 0
    neg = False
    eneg = False
    i = 0
    n = _slen(s)
    if n and _byte(s, 0) == 45:
        neg = True
        i = 1
    while i < n:
        c = _byte(s, i)
        i += 1
        if 48 <= c <= 57:
            d = c - 48
            if st == 2:
                exp_val = 10 * exp_val + d
            elif d == 0 or mant >= _MM:
                if st == 0:
                    tzi += 1
                else:
                    tzf += 1
            else:
                z = tzi
                w = 0
                while w < 2:
                    k = z if w == 0 else tzf
                    while k:
                        if mant < _MM:
                            if w == 1:
                                extra -= 1
                            mant = 10 * mant
                        elif w == 0:
                            extra += 1
                        k -= 1
                    w += 1
                tzi = 0
                tzf = 0
                if mant < _MM:
                    if st == 1:
                        extra -= 1
                    mant = 10 * mant + d
                elif st == 0:
                    extra += 1
        elif st == 0 and c == 46:
            st = 1
        elif st != 2 and (c == 101 or c == 69):
            st = 2
            if i < n and (_byte(s, i) == 43 or _byte(s, i) == 45):
                eneg = _byte(s, i) == 45
                i += 1
            else:
                eneg = False
        else:
            break
    if st == 2 and eneg:
        exp_val = -exp_val
    exp_val += extra + tzi
    v = _decimal_exp(mant + 0.0, exp_val)
    if neg:
        return -v
    return v


def _fmt_mantissa(mant, cap, prefix, ndig, max_exp_zeros, trailing, dec, e, mode_g, mode_f, mode_e):
    if mant and mant >= cap:
        if mode_f:
            ndig += 1
            dec += 1
        else:
            mant //= 10
            e += 1
    s = prefix
    if mode_g and e != 0:
        if e >= 0:
            if e < max_exp_zeros:
                dec += e
                if dec >= ndig:
                    trailing = dec - (ndig - 1)
                e = 0
        elif e >= -4:
            cnt = 0
            while e < 0 and mant % 10 == 0:
                mant //= 10
                cnt += 1
                e += 1
            ndig -= cnt
            s = _cat(s, '0.')
            s = _cat(s, _mul_str('0', cnt - e - 1))
            dec = 255
            e = 0
    digs = ''
    m = mant
    i = 0
    while i < ndig:
        digs = _cat(_ch(48 + m % 10), digs)
        m //= 10
        i += 1
    dot = dec >= 255
    if dec + 1 < ndig:
        dot = True
        digs = _cat(_substr(digs, 0, dec + 1, TAG_STR), _cat('.', _substr(digs, dec + 1, ndig, TAG_STR)))
    s = _cat(s, digs)
    if trailing:
        dec -= ndig - 1
        while trailing:
            trailing -= 1
            if dec == 0:
                s = _cat(s, '.')
                dot = True
            dec -= 1
            s = _cat(s, '0')
    if mode_g and dot:
        while _slen(s) and _byte(s, _slen(s) - 1) == 48:
            s = _substr(s, 0, _slen(s) - 1, TAG_STR)
        if _slen(s) and _byte(s, _slen(s) - 1) == 46:
            s = _substr(s, 0, _slen(s) - 1, TAG_STR)
    if (e != 0 or mode_e) and not mode_f:
        s = _cat(s, 'e')
        if e >= 0:
            s = _cat(s, '+')
        else:
            s = _cat(s, '-')
            e = -e
        if e >= 100:
            s = _cat(s, _ch(48 + e // 100))
        s = _cat(s, _ch(48 + (e // 10) % 10))
        s = _cat(s, _ch(48 + e % 10))
    return s, e


def _format_float(f, fmt, prec, sign):
    buf_size = 33
    if _pay(f) < 0 and _fkind(f) != 2:
        f = -f
        sign = '-'
    if sign:
        buf_size -= 1
    kind = _fkind(f)
    if kind == 1:
        return _cat(sign, 'inf')
    if kind == 2:
        return _cat(sign, 'nan')
    mode_f = fmt == 'f'
    mode_g = fmt == 'g'
    mode_e = not mode_f and not mode_g
    if prec < 0:
        prec = 6
    max_exp_zeros = prec if prec < buf_size - 3 else buf_size - 3
    if prec == 99:
        prec = 9
        max_exp_zeros = 16
    e = 0
    if f != 0.0:
        expval = ((_u32(_pay(f)) >> 23) & 255) - 127
        e = _ftoi(expval * _LOG10_2)
        if e is STOP:
            e = 0
        pos = not (_u32(_pay(f)) < 1065353216)
        ub = _decimal_exp(1.0, e + (1 if pos else 0))
        while (f >= ub) == pos:
            e += 1 if pos else -1
            ub = _decimal_exp(1.0, e + (1 if pos else 0))
    if mode_f and e > 0 and e + prec + 2 > buf_size:
        mode_f = False
        mode_g = True
        prec += 1
    max_digits = prec
    lead_zeros = 0
    trail_zeros = 0
    if mode_f:
        if max_digits > buf_size - 3:
            max_digits = buf_size - 3
        if e < 0:
            if max_digits > 2 and e < -2:
                lead_zeros = (-e if -e < max_digits else max_digits) - 2
                max_digits -= lead_zeros
            else:
                max_digits += 1
        else:
            max_digits += e + 1
    elif not mode_g or max_digits == 0:
        max_digits += 1
    if max_digits > 9:
        trail_zeros = max_digits - 9
        max_digits = 9
    overhead = 3 if mode_f else 7
    if trail_zeros > buf_size - max_digits - overhead:
        trail_zeros = buf_size - max_digits - overhead
    ndig = 6 if 6 < max_digits else max_digits
    while True:
        prefix = ''
        extra_zeros = trail_zeros + (max_digits - ndig)
        dec = 0
        if f == 0.0:
            decexp = 0
        elif mode_f:
            decexp = ndig - 1
            if e < 0:
                if lead_zeros > 0:
                    prefix = _cat('0.', _mul_str('0', lead_zeros))
                    decexp += lead_zeros + 1
                    dec = 255
                else:
                    dec = 0
            else:
                decexp -= e
                dec = e
        else:
            decexp = ndig - e - 1
        cap = 10 ** ndig
        mant = 1
        if ndig > 6 and decexp > 1:
            if ndig > 7 and decexp > 2:
                mant = 100
                decexp -= 2
            else:
                mant = 10
                decexp -= 1
        mf = _decimal_exp(f, decexp)
        iv = _ftoi(mf + 0.5)
        if iv is STOP:
            iv = _ftoi(mf)
            if iv is STOP:
                iv = 0
        mant = (mant * iv) & (_U32 - 1)
        out, e2 = _fmt_mantissa(mant, cap, prefix, ndig, max_exp_zeros, extra_zeros, dec, e, mode_g, mode_f, mode_e)
        e = e2
        check = _ff_parse(out)
        diff = check - f
        best_diff = diff
        best = mant
        if diff == 0.0:
            return _cat(sign, out)
        err = 1
        if ndig > 6:
            err <<= 3 * (ndig - 6)
        runs = 12
        retry = False
        while runs > 0:
            runs -= 1
            if _pay(diff) < 0:
                mant += err
            else:
                mant -= err
            out, e2 = _fmt_mantissa(mant, cap, prefix, ndig, max_exp_zeros, extra_zeros, dec, e, mode_g, mode_f, mode_e)
            check = _ff_parse(out)
            diff = check - f
            if diff == 0.0:
                return _cat(sign, out)
            ad = diff if _pay(diff) >= 0 else -diff
            bd = best_diff if _pay(best_diff) >= 0 else -best_diff
            delta = ad - bd
            if _pay(delta) < 0 or (delta == 0.0 and mant % 10 == 0):
                best_diff = diff
                best = mant
            if err > 1:
                err >>= 1
            else:
                if ndig < max_digits:
                    ndig += 1
                    retry = True
                    break
                if mant != best:
                    out, e2 = _fmt_mantissa(best, cap, prefix, ndig, max_exp_zeros, extra_zeros, dec, e, mode_g, mode_f, mode_e)
                return _cat(sign, out)
        if not retry:
            return _cat(sign, out)


def _float_repr(f):
    s = _format_float(f, 'g', 99, '')
    n = _slen(s)
    i = 0
    dot = False
    exp = False
    nan = False
    while i < n:
        c = _byte(s, i)
        if c == 46:
            dot = True
        elif c == 101 or c == 69:
            exp = True
        elif c == 110:
            nan = True
        i += 1
    if not dot and not exp and not nan:
        return _cat(s, '.0')
    return s


def _complex_repr(c):
    re, im = _cparts(c)
    if re != 0.0 or _pay(re) < 0:
        rr = _format_float(re, 'g', 6, '')
        ir = _format_float(im, 'g', 6, '+')
        return _s('(', rr, ir, 'j)')
    return _cat(_format_float(im, 'g', 6, ''), 'j')


def _skip_ws(s, i):
    n = _slen(s)
    while i < n and _byte(s, i) <= 32:
        i += 1
    return i


def _parse_float(s):
    n = _slen(s)
    i = _skip_ws(s, 0)
    if i >= n:
        raise ValueError('invalid syntax for number')
    neg = False
    if _byte(s, i) == 43 or _byte(s, i) == 45:
        neg = _byte(s, i) == 45
        i += 1
    rest = _substr(s, i, n, TAG_STR)
    low = rest
    # inf / nan, then the digit parser. Trailing space is allowed.
    if _slen(rest) >= 3 and (_streq(_substr(rest, 0, 3, TAG_STR), 'inf') or _streq(_substr(rest, 0, 3, TAG_STR), 'nan') or _streq(_substr(rest, 0, 3, TAG_STR), 'INF') or _streq(_substr(rest, 0, 3, TAG_STR), 'NaN')):
        word = _substr(rest, 0, 3, TAG_STR)
        j = 3
        if _slen(rest) >= 8 and (_streq(_substr(rest, 0, 8, TAG_STR), 'infinity') or _streq(_substr(rest, 0, 8, TAG_STR), 'INFINITY')):
            j = 8
            word = 'inf'
        k = _skip_ws(rest, j)
        if k != _slen(rest):
            raise ValueError('invalid syntax for number')
        if _byte(word, 0) == 110 or _byte(word, 0) == 78:
            return _frombits(2143289344)
        return _frombits(4286578688 if neg else 2139095040)
    v = _ff_parse(_substr(s, i, n, TAG_STR))
    # _ff_parse stops at the first bad byte; reject if leftover is not space.
    # Re-scan digits the same way and require only trailing space.
    j = i
    saw = False
    exp = False
    if j < n and (_byte(s, j) == 43 or _byte(s, j) == 45):
        j += 1
    while j < n:
        c = _byte(s, j)
        if 48 <= c <= 57 or c == 46 or c == 101 or c == 69 or c == 43 or c == 45:
            if 48 <= c <= 57 or c == 46:
                saw = True
            j += 1
        else:
            break
    if not saw or _skip_ws(s, j) != n:
        raise ValueError('invalid syntax for number')
    if neg:
        return -v
    return v


def float____new__(cls, *args):
    n = len(args)
    if n > 1:
        _arg_count(1, n)
    if n == 0:
        v = 0.0
    else:
        a = args[0]
        t = _tag(a)
        if t == TAG_FLOAT:
            v = a
        elif _isint(a):
            v = a + 0.0
        elif _isstr(a):
            v = _parse_float(a)
        elif t == TAG_OBJECT:
            f = _tlookup(_ld(a, 1), '__float__')
            if f is NULL:
                raise TypeError(_s("can't convert ", _tname(a), " to float"))
            v = _call_member(f, a, ())
        else:
            raise TypeError(_s("can't convert ", _tname(a), " to float"))
    if cls is not float:
        return _native_sub_new(cls, v)
    return v


def complex____new__(cls, *args):
    n = len(args)
    if n > 2:
        _arg_count(2, n)
    re = 0.0
    im = 0.0
    if n == 1 and _isstr(args[0]):
        return _parse_complex(args[0]) if cls is complex else _native_sub_new(cls, _parse_complex(args[0]))
    if n >= 1:
        a = args[0]
        if _tag(a) == TAG_COMPLEX:
            re, im = _cparts(a)
        else:
            re = float(a)
    if n == 2:
        im = float(args[1])
    c = _complex(re, im)
    if cls is not complex:
        return _native_sub_new(cls, c)
    return c


def _parse_complex(s):
    n = _slen(s)
    i = _skip_ws(s, 0)
    j = n
    while j > i and _byte(s, j - 1) <= 32:
        j -= 1
    if j > i and (_byte(s, j - 1) == 106 or _byte(s, j - 1) == 74):
        j -= 1
        body = _substr(s, i, j, TAG_STR)
        # real+imag without the trailing j. Split at the last + or - that
        # isn't the leading sign and isn't the exponent sign.
        k = _slen(body) - 1
        split = -1
        while k > 0:
            c = _byte(body, k)
            if c == 43 or c == 45:
                p = _byte(body, k - 1)
                if p != 101 and p != 69:
                    split = k
                    break
            k -= 1
        if split < 0:
            return _complex(0.0, _parse_float(body))
        return _complex(_parse_float(_substr(body, 0, split, TAG_STR)), _parse_float(_substr(body, split, _slen(body), TAG_STR)))
    return _complex(_parse_float(_substr(s, i, j, TAG_STR)), 0.0)


# ---------------------------------------------------------------------------
# libm-ish helpers for complex **. Binary32 range reduction; accurate enough
# for the values the arithmetic tests print.

def _fsqrt(x):
    if x < 0.0:
        return _frombits(2143289344)
    if x == 0.0:
        return x
    g = x
    if g > 1.0:
        g = x * 0.5
    i = 0
    while i < 12:
        g = (g + x / g) * 0.5
        i += 1
    return g


def _fexp(x):
    if x > 88.0:
        return _frombits(2139095040)
    if x < -100.0:
        return 0.0
    # e**x = 2**(x/ln2) via a short series on the fractional part.
    n = _ftoi(x * 1.44269504 + (0.5 if x >= 0.0 else -0.5))
    if n is STOP:
        n = 0
    f = x - n * 0.693147182
    t = 1.0
    a = 1.0
    k = 1
    while k < 12:
        a = a * f / k
        t = t + a
        k += 1
    return t * _frombits((127 + n) << 23) if -126 <= n <= 127 else (t * (2.0 ** n))


def _flog(x):
    if x < 0.0:
        return _frombits(2143289344)
    if x == 0.0:
        return -_frombits(2139095040)
    b = _u32(_pay(x))
    exp = ((b >> 23) & 255) - 127
    m = _frombits((b & 8388607) | 1065353216)
    # ln(m) for m in [1, 2): ln(1+z), z in [0, 1)
    z = m - 1.0
    zp = z
    s = z
    k = 2
    sign = -1.0
    while k < 16:
        zp = zp * z
        s = s + sign * zp / k
        sign = -sign
        k += 1
    return s + exp * 0.693147182


def _fatan(x):
    neg = _pay(x) < 0
    if neg:
        x = -x
    flip = x > 1.0
    if flip:
        x = 1.0 / x
    z = x
    zp = x
    s = x
    k = 1
    sign = -1.0
    while k < 12:
        zp = zp * x * x
        s = s + sign * zp / (2 * k + 1)
        sign = -sign
        k += 1
    if flip:
        s = 1.57079637 - s
    if neg:
        return -s
    return s


def _fatan2(y, x):
    if x > 0.0:
        return _fatan(y / x)
    if x < 0.0:
        a = _fatan(y / x)
        if _pay(y) < 0 or (y == 0.0 and _pay(y) < 0):
            return a - 3.14159274
        return a + 3.14159274
    if y > 0.0:
        return 1.57079637
    if y < 0.0:
        return -1.57079637
    return 0.0


def _fsin(x):
    # Reduce to [-pi, pi] with a 2*pi multiply.
    t = x * 0.159154937
    n = _ftoi(t + (0.5 if t >= 0.0 else -0.5))
    if n is STOP:
        n = 0
    x = x - n * 6.28318548
    z = x
    zp = x
    s = x
    k = 1
    sign = -1.0
    while k < 8:
        zp = zp * x * x
        s = s + sign * zp / ((2 * k) * (2 * k + 1))
        sign = -sign
        k += 1
    return s


def _fcos(x):
    return _fsin(x + 1.57079637)
