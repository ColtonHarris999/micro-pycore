# Binary and unary operators the core leaves to the firmware: the generic
# path of mp_binary_op (py/runtime.c) with each native type's binary_op,
# equality (mp_obj_equal_not_equal), hashing, and truth.
from ._abi import *

# mp_binary_op_method_name, indexed by op. The oracle only names __iadd__
# and __isub__ among the in-place ops. 36..48 are the reflected ops.
_OPNAMES = (
    '__lt__', '__gt__', '__eq__', '__le__', '__ge__', '__ne__', '', '', '',
    '', '', '', '', '', '__iadd__', '__isub__', '', '', '', '', '', '',
    '__or__', '__xor__', '__and__', '__lshift__', '__rshift__', '__add__',
    '__sub__', '__mul__', '__matmul__', '__floordiv__', '__truediv__',
    '__mod__', '__pow__', '__contains__',
    '__ror__', '__rxor__', '__rand__', '__rlshift__', '__rrshift__', '__radd__',
    '__rsub__', '__rmul__', '__rmatmul__', '__rfloordiv__', '__rtruediv__',
    '__rmod__', '__rpow__',
)
BINOP_REVERSE_OR = const(36)
BINOP_REVERSE_POWER = const(48)


def _binop_name(op):
    return _OPNAMES[op]


def _apply(op, a, b):
    # Run binary op `op` through the core (and back here when it must).
    if op == BINOP_ADD or op == BINOP_INPLACE_ADD:
        return a + b
    if op == BINOP_SUBTRACT or op == BINOP_INPLACE_SUBTRACT:
        return a - b
    if op == BINOP_MULTIPLY or op == BINOP_INPLACE_MULTIPLY:
        return a * b
    if op == BINOP_LESS:
        return a < b
    if op == BINOP_MORE:
        return a > b
    if op == BINOP_LESS_EQUAL:
        return a <= b
    if op == BINOP_MORE_EQUAL:
        return a >= b
    if op == BINOP_EQUAL:
        return a == b
    if op == BINOP_NOT_EQUAL:
        return a != b
    if op == BINOP_TRUE_DIVIDE or op == BINOP_INPLACE_TRUE_DIVIDE:
        return a / b
    if op == BINOP_FLOOR_DIVIDE or op == BINOP_INPLACE_FLOOR_DIVIDE:
        return a // b
    if op == BINOP_MODULO or op == BINOP_INPLACE_MODULO:
        return a % b
    if op == BINOP_POWER or op == BINOP_INPLACE_POWER:
        return a ** b
    if op == BINOP_OR or op == BINOP_INPLACE_OR:
        return a | b
    if op == BINOP_XOR or op == BINOP_INPLACE_XOR:
        return a ^ b
    if op == BINOP_AND or op == BINOP_INPLACE_AND:
        return a & b
    if op == BINOP_LSHIFT or op == BINOP_INPLACE_LSHIFT:
        return a << b
    if op == BINOP_RSHIFT or op == BINOP_INPLACE_RSHIFT:
        return a >> b
    if op == BINOP_IN:
        return a in b
    if op == BINOP_MAT_MULTIPLY or op == BINOP_INPLACE_MAT_MULTIPLY:
        return a @ b
    return _binop(op, a, b)


def _small(x):
    # An oracle small int: 31-bit signed.
    return _tag(x) == TAG_INT and -1073741824 <= x <= 1073741823


def _isnum(x):
    t = _tag(x)
    return t == TAG_INT or t == TAG_INT64 or t == TAG_FLOAT or t == TAG_COMPLEX or x is True or x is False


def _binop(op, a, b):
    if op == BINOP_IS:
        return a is b
    if op == BINOP_EQUAL:
        return _equal(a, b)
    if op == BINOP_NOT_EQUAL:
        return not _equal(a, b)
    if op == BINOP_EXCEPTION_MATCH:
        return _exc_match(a, b)
    if _small(a):
        tb = _tag(b)
        if tb == TAG_INT or tb == TAG_FLOAT or tb == TAG_COMPLEX:
            r = _num_binop(op, a, b)
            if r is NULL:
                _unsupported_bin(op, a, b)
            return r
    if op == BINOP_IN:
        op = BINOP_CONTAINS
        a, b = b, a
    while True:
        r = _type_binop(op, a, b)
        if r is not NULL:
            return r
        if BINOP_INPLACE_OR <= op <= BINOP_INPLACE_POWER:
            op += BINOP_OR - BINOP_INPLACE_OR
            continue
        if BINOP_OR <= op <= BINOP_POWER:
            a, b = b, a
            op += BINOP_REVERSE_OR - BINOP_OR
            continue
        if op >= BINOP_REVERSE_OR:
            a, b = b, a
            op -= BINOP_REVERSE_OR - BINOP_OR
        break
    if op == BINOP_CONTAINS:
        for x in a:
            if _equal(x, b):
                return True
        return False
    _unsupported_bin(op, a, b)


def _exc_match(a, b):
    if _isexc_type(b):
        return _exc_is(a, b)
    if _tag(b) == TAG_TUPLE:
        for t in b:
            if not _isexc_type(t):
                _unsupported_bin(BINOP_EXCEPTION_MATCH, a, b)
            if _exc_is(a, t):
                return True
        return False
    _unsupported_bin(BINOP_EXCEPTION_MATCH, a, b)


def _isexc_type(t):
    return _istype(t) and (_ld(t, 7) & TF_EXC) != 0


def _exc_is(e, t):
    # mp_obj_exception_match: e may be an instance or a type.
    if _istype(e):
        return _issub(e, t)
    return _issub(_typeof(e), t)


def _issub(a, b):
    if a is b or b is object:
        return True
    mro = _ld(a, 5)
    n = _ld(mro, 0)
    i = 0
    while i < n:
        if _ld(mro, 1 + i) is b:
            return True
        i += 1
    return False


def _type_binop(op, a, b):
    t = _tag(a)
    if t == TAG_INT or t == TAG_INT64:
        return _int_binop(op, a, b)
    if t == TAG_CONTROL:
        if a is True or a is False:
            return _binop(op, 1 if a is True else 0, b)
        return NULL
    if t == TAG_FLOAT or t == TAG_COMPLEX:
        return _num_binop(op, a, b)
    if t == TAG_QSTR or t == TAG_STR or t == TAG_BYTES:
        return _str_binop(op, a, b)
    if t == TAG_TUPLE:
        return _tuple_binop(op, a, b)
    if t == TAG_MUT:
        k = _pay(a) & 3
        if k == MUT_LIST:
            return _list_binop(op, a, b)
        if k == MUT_DICT:
            return _dict_binop(op, a, b)
        if k == MUT_SET:
            return _set_binop(op, a, b)
        return _barr_binop(op, a, b)
    if t == TAG_OBJECT:
        k = _ld(a, 0)
        if k == OB_INSTANCE or k == OB_EXCEPTION:
            if _ld(_ld(a, 1), 7) & TF_USER:
                return _inst_binop(op, a, b)
            return NULL
        if k == OB_DICT_VIEW:
            if _ld(a, 3) != 0 or op != BINOP_CONTAINS:
                return NULL
            return _dict_binop(op, _ld(a, 2), b)
    return NULL


def _int_binop(op, a, b):
    # mp_obj_int_binary_op_extra_cases; plain int arithmetic is the core's.
    if b is False:
        return _apply(op, a, 0)
    if b is True:
        return _apply(op, a, 1)
    tb = _tag(b)
    if tb == TAG_FLOAT or tb == TAG_COMPLEX:
        return _num_binop(op, a, b)
    if op == BINOP_MULTIPLY:
        if tb == TAG_QSTR or tb == TAG_STR or tb == TAG_BYTES or tb == TAG_TUPLE or _islist(b):
            return _apply(op, b, a)
    return NULL


def _seq_cmp(op, ia, na, ib, nb, oa, ob):
    # mp_seq_cmp_objs over word arrays (address value, offset).
    if op == BINOP_EQUAL and na != nb:
        return False
    if op == BINOP_LESS or op == BINOP_LESS_EQUAL:
        ia, ib = ib, ia
        na, nb = nb, na
        oa, ob = ob, oa
        op = BINOP_MORE if op == BINOP_LESS else BINOP_MORE_EQUAL
    n = na if na < nb else nb
    i = 0
    while i < n:
        x = _ld(ia, oa + i)
        y = _ld(ib, ob + i)
        if not _equal(x, y):
            if op == BINOP_EQUAL:
                return False
            return _apply(op, x, y) is True
        i += 1
    if na != nb:
        if na < nb:
            return False
    elif op == BINOP_MORE:
        return False
    return True


def _tuple_binop(op, a, b):
    if op == BINOP_ADD or op == BINOP_INPLACE_ADD:
        if _tag(b) != TAG_TUPLE:
            return NULL
        na = _ld(a, 0)
        nb = _ld(b, 0)
        r = _newtuple(na + nb)
        if na + nb:
            _wcopy(r, 1, a, 1, na)
            _wcopy(r, 1 + na, b, 1, nb)
        return r
    if op == BINOP_MULTIPLY or op == BINOP_INPLACE_MULTIPLY:
        n = _int_maybe(b)
        if n is NULL:
            return NULL
        na = _ld(a, 0)
        if n <= 0 or na == 0:
            return ()
        r = _newtuple(na * n)
        i = 0
        while i < n:
            _wcopy(r, 1 + i * na, a, 1, na)
            i += 1
        return r
    if op <= BINOP_MORE_EQUAL and op != BINOP_NOT_EQUAL:
        if _tag(b) != TAG_TUPLE:
            return NULL
        return _seq_cmp(op, a, _ld(a, 0), b, _ld(b, 0), 1, 1)
    return NULL


def _list_binop(op, a, b):
    if op == BINOP_ADD:
        if not _islist(b):
            return NULL
        na = _ld(a, 0)
        nb = _ld(b, 0)
        r = _newlist(na + nb)
        _wcopy(_ld(r, 2), 0, _ld(a, 2), 0, na)
        _wcopy(_ld(r, 2), na, _ld(b, 2), 0, nb)
        return r
    if op == BINOP_INPLACE_ADD:
        _list_extend(a, b)
        return a
    if op == BINOP_MULTIPLY:
        n = _int_maybe(b)
        if n is NULL:
            return NULL
        if n < 0:
            n = 0
        na = _ld(a, 0)
        r = _newlist(na * n)
        i = 0
        while i < n:
            _wcopy(_ld(r, 2), i * na, _ld(a, 2), 0, na)
            i += 1
        return r
    if op <= BINOP_MORE_EQUAL and op != BINOP_NOT_EQUAL:
        if not _islist(b):
            if op == BINOP_EQUAL:
                return False
            return NULL
        return _seq_cmp(op, _ld(a, 2), _ld(a, 0), _ld(b, 2), _ld(b, 0), 0, 0)
    return NULL


def _int_maybe(x):
    # mp_obj_get_int_maybe: ints and bools; else NULL.
    t = _tag(x)
    if t == TAG_INT or t == TAG_INT64:
        return x
    if x is True:
        return 1
    if x is False:
        return 0
    return NULL


def _bytes_cmp(op, a, b):
    c = _bcmp(a, b)
    if op == BINOP_EQUAL:
        return c == 0
    if op == BINOP_LESS:
        return c < 0
    if op == BINOP_LESS_EQUAL:
        return c <= 0
    if op == BINOP_MORE:
        return c > 0
    return c >= 0


def _str_binop(op, a, b):
    if op == BINOP_MODULO:
        if _tag(b) == TAG_TUPLE:
            return _str_modulo(a, b, NULL)
        if _isdict(b):
            return _str_modulo(a, (b,), b)
        return _str_modulo(a, (b,), NULL)
    if op == BINOP_MULTIPLY:
        n = _int_maybe(b)
        if n is NULL:
            return NULL
        return _mul_str(a, n)
    isb = _tag(a) == TAG_BYTES
    tb = _tag(b)
    if isb:
        if tb != TAG_BYTES:
            if _isbarr(b):
                b = _barr_bytes(b)
            else:
                return NULL
    elif tb != TAG_QSTR and tb != TAG_STR:
        if op == BINOP_CONTAINS:
            raise TypeError(_s("can't convert '", _tname(b), "' object to str implicitly"))
        return NULL
    if op == BINOP_ADD or op == BINOP_INPLACE_ADD:
        return _cat(a, b)
    if op == BINOP_CONTAINS:
        return _find_bytes(a, b, 0, _slen(a)) >= 0
    if op == BINOP_EQUAL or op == BINOP_LESS or op == BINOP_LESS_EQUAL or op == BINOP_MORE or op == BINOP_MORE_EQUAL:
        return _bytes_cmp(op, a, b)
    return NULL


def _dict_binop(op, a, b):
    if op == BINOP_CONTAINS:
        return _dget(a, b) is not NULL
    if op == BINOP_EQUAL:
        if not _isdict(b):
            return False
        if _ld(a, 0) != _ld(b, 0):
            return False
        for k, v in a.items():
            w = _dget(b, k)
            if w is NULL or not _equal(v, w):
                return False
        return True
    if op == BINOP_OR or op == BINOP_INPLACE_OR:
        if not _isdict(b):
            return NULL
        if op == BINOP_OR:
            a = dict__copy(a)
        dict__update(a, b)
        return a
    return NULL


def _isanyset(x):
    return _tag(x) == TAG_MUT and (_pay(x) & 3) == MUT_SET


def _set_binop(op, a, b):
    update = (_ld(a, 3) & SET_FLAG_FROZEN) == 0
    if op != BINOP_CONTAINS and not _isanyset(b):
        return NULL
    if op == BINOP_OR:
        return set__union(a, b)
    if op == BINOP_XOR:
        return set__symmetric_difference(a, b)
    if op == BINOP_AND:
        return set__intersection(a, b)
    if op == BINOP_SUBTRACT:
        return set__difference(a, b)
    if op == BINOP_INPLACE_OR:
        if update:
            set__update(a, b)
            return a
        return set__union(a, b)
    if op == BINOP_INPLACE_XOR:
        if update:
            set__symmetric_difference_update(a, b)
            return a
        return set__symmetric_difference(a, b)
    if op == BINOP_INPLACE_AND:
        r = _set_intersect(a, b, update)
        return a if update else r
    if op == BINOP_INPLACE_SUBTRACT:
        return _set_diff(a, (b,), update)
    if op == BINOP_LESS:
        return _set_subset(a, b, True)
    if op == BINOP_MORE:
        return _set_subset(b, a, True)
    if op == BINOP_EQUAL:
        if _ld(a, 0) != _ld(b, 0):
            return False
        return _set_subset(a, b, False)
    if op == BINOP_LESS_EQUAL:
        return _set_subset(a, b, False)
    if op == BINOP_MORE_EQUAL:
        return _set_subset(b, a, False)
    if op == BINOP_CONTAINS:
        return _sfind(a, b) >= 0
    return NULL


def _barr_binop(op, a, b):
    # array.c's binary_op for bytearray.
    if op == BINOP_ADD:
        bb = _buf_bytes(b)
        if bb is NULL:
            return NULL
        return _barr_from(_cat(_barr_bytes(a), bb))
    if op == BINOP_INPLACE_ADD:
        bytearray__extend(a, b)
        return a
    if op == BINOP_CONTAINS:
        bb = _buf_bytes(b)
        if bb is NULL:
            if _isint(b):
                return _find_bytes(_barr_bytes(a), _bytes_of_int(b), 0, _ld(a, 0)) >= 0
            return False
        return _find_bytes(_barr_bytes(a), bb, 0, _ld(a, 0)) >= 0
    if op == BINOP_EQUAL:
        bb = _buf_bytes(b)
        if bb is NULL:
            return False
        return _streq(_barr_bytes(a), bb)
    if op == BINOP_MULTIPLY:
        n = _int_maybe(b)
        if n is NULL:
            return NULL
        return _barr_from(_mul_str(_barr_bytes(a), n))
    return NULL


def _buf_bytes(x):
    # The bytes of an object with the buffer protocol, or NULL.
    if _tag(x) == TAG_BYTES:
        return x
    if _isbarr(x):
        return _barr_bytes(x)
    return NULL


def _bytes_of_int(n):
    b = _strnew(1, TAG_BYTES)
    _poke8(_data(b), 0, n & 255)
    return _strfin(b)


def _inst_binop(op, a, b):
    # instance_binary_op (py/objtype.c).
    while True:
        name = _OPNAMES[op]
        f = NULL
        if _slen(name):
            f = _tlookup(_ld(a, 1), name)
        if f is NULL:
            nb = _native_base(_ld(a, 1))
            if nb is not object and _ld(a, 0) == OB_INSTANCE:
                sub = _subobj(a)
                if sub is not NULL:
                    return _apply(op, sub, b)
            if BINOP_INPLACE_OR <= op <= BINOP_INPLACE_POWER:
                op += BINOP_OR - BINOP_INPLACE_OR
                continue
            return NULL
        r = _call_member(f, a, (b,))
        if op == BINOP_CONTAINS:
            return _truth(r)
        if r is NotImplemented:
            return NULL
        return r


# ---------------------------------------------------------------------------
# Numbers the core hands over: complex arithmetic and the float/complex mix.

def _cparts(x):
    # (re, im) floats of an int, float, or complex; NULL for anything else.
    t = _tag(x)
    if t == TAG_COMPLEX:
        return _mk(TAG_FLOAT, _pay(_ld(x, 0))), _mk(TAG_FLOAT, _pay(_ld(x, 1)))
    if t == TAG_FLOAT:
        return x, 0.0
    if t == TAG_INT or t == TAG_INT64:
        return x + 0.0, 0.0
    if x is True:
        return 1.0, 0.0
    if x is False:
        return 0.0, 0.0
    return NULL


def _complex(re, im):
    c = _alloc(2, TAG_COMPLEX, 0)
    _st(c, 0, _pay(re))
    _st(c, 1, _pay(im))
    return c


def _num_binop(op, a, b):
    # mp_obj_float_binary_op / mp_obj_complex_binary_op for operands the
    # core could not do itself.
    if _tag(a) != TAG_COMPLEX and _tag(b) != TAG_COMPLEX:
        # float op that the ALU refused: bitwise ops, matmul, or a negative
        # base to a fractional power.
        if _tag(b) == TAG_FLOAT or _tag(a) == TAG_FLOAT:
            pb = _cparts(b)
            if pb is NULL:
                return NULL
            if op == BINOP_POWER or op == BINOP_INPLACE_POWER:
                fa = a + 0.0
                fb = pb[0]
                if fa < 0 and fb != _floor(fb):
                    return _cpow(fa, 0.0, fb, 0.0)
            return NULL
        return NULL
    pa = _cparts(a)
    pb = _cparts(b)
    if pa is NULL or pb is NULL:
        return NULL
    ar, ai = pa
    br, bi = pb
    if op == BINOP_ADD or op == BINOP_INPLACE_ADD:
        return _complex(ar + br, ai + bi)
    if op == BINOP_SUBTRACT or op == BINOP_INPLACE_SUBTRACT:
        return _complex(ar - br, ai - bi)
    if op == BINOP_MULTIPLY or op == BINOP_INPLACE_MULTIPLY:
        return _complex(ar * br - ai * bi, ar * bi + ai * br)
    if op == BINOP_TRUE_DIVIDE or op == BINOP_INPLACE_TRUE_DIVIDE:
        if bi == 0.0:
            if br == 0.0:
                raise ZeroDivisionError('complex divide by zero')
            return _complex(ar / br, ai / br)
        if br == 0.0:
            return _complex(ai / bi, -ar / bi)
        d = br * br + bi * bi
        return _complex((ar * br + ai * bi) / d, (ai * br - ar * bi) / d)
    if op == BINOP_POWER or op == BINOP_INPLACE_POWER:
        return _cpow(ar, ai, br, bi)
    if op == BINOP_EQUAL:
        return ar == br and ai == bi
    if op == BINOP_FLOOR_DIVIDE or op == BINOP_INPLACE_FLOOR_DIVIDE or op == BINOP_MODULO or op == BINOP_INPLACE_MODULO:
        raise TypeError("can't truncate-divide a complex number")
    return NULL


def _cpow(ar, ai, br, bi):
    # py/objcomplex.c: z1**z2 = exp(z2*ln(z1))
    if br == 0.0 and bi == 0.0:
        return _complex(1.0, 0.0)
    if ar == 0.0 and ai == 0.0:
        if bi != 0.0 or br < 0:
            raise ZeroDivisionError('0.0 to a complex power')
        return _complex(0.0, 0.0)
    ln1 = _flog(ar * ar + ai * ai)
    ln1 = 0.5 * ln1
    ln2 = _fatan2(ai, ar)
    x3 = br * ln1 - bi * ln2
    y3 = br * ln2 + bi * ln1
    mag = _fexp(x3)
    return _complex(mag * _fcos(y3), mag * _fsin(y3))


def _floor(x):
    i = _ftoi(x)
    if i is STOP:
        return x
    f = i + 0.0
    if f > x:
        f -= 1.0
    return f


# ---------------------------------------------------------------------------
# Equality, ordering and hashing

def _equal(a, b):
    ta = _tag(a)
    if a is b and ta != TAG_FLOAT and ta != TAG_COMPLEX:
        return True
    if a is None or b is None:
        return False
    if ta == TAG_INT:
        if _tag(b) == TAG_INT:
            return False
        a, b = b, a
        ta = _tag(a)
    if ta == TAG_QSTR or ta == TAG_STR:
        if _isstr(b):
            return _streq(a, b)
        return False
    if _isstr(b):
        return False
    if _isnum(a) and _isnum(b):
        if ta == TAG_COMPLEX or _tag(b) == TAG_COMPLEX:
            pa = _cparts(a)
            pb = _cparts(b)
            return pa[0] == pb[0] and pa[1] == pb[1]
        return a == b
    r = _type_binop(BINOP_EQUAL, a, b)
    if r is not NULL:
        return _truth(r) if r is not True and r is not False else r
    return a is b


def _hashv(x):
    # Python-level hash(x) as an int, raising for unhashable values.
    h = _hash(x)
    if h is not STOP:
        return h
    t = _tag(x)
    if t == TAG_FLOAT:
        return _fhash(x)
    if t == TAG_COMPLEX:
        re, im = _cparts(x)
        return _fhash(re) ^ _fhash(im)
    if t == TAG_TUPLE:
        h = 12345
        n = _ld(x, 0)
        i = 0
        while i < n:
            h += _hashv(_ld(x, 1 + i))
            i += 1
        return _sx31(h)
    if t == TAG_RANGE or t == TAG_ITER:
        return _sx31(_pay(x) >> 1)
    if t == TAG_MUT:
        if _isset(x) and (_ld(x, 3) & SET_FLAG_FROZEN):
            h = 54321
            for k in x:
                h += _hashv(k)
            return _sx31(h)
        _unsupported_un('__hash__', x)
    if t == TAG_OBJECT:
        k = _ld(x, 0)
        if k == OB_INSTANCE or k == OB_EXCEPTION:
            tt = _ld(x, 1)
            if _ld(tt, 7) & TF_USER:
                f = _tlookup(tt, '__hash__')
                if f is not NULL:
                    if f is None:
                        _unsupported_un('__hash__', x)
                    r = _call_member(f, x, ())
                    return _sx31(r)
                if _tlookup(tt, '__eq__') is not NULL:
                    _unsupported_un('__hash__', x)
            return _sx31(_pay(x) >> 1)
        return _sx31(_pay(x) >> 1)
    _unsupported_un('__hash__', x)


def _sx31(h):
    h = h & 0x7FFFFFFF
    if h >= 0x40000000:
        h -= 0x80000000
    return h


def _fhash(f):
    # (mp_int_t)f on the oracle's x87: out-of-range and nan give INT_MIN,
    # and MP_OBJ_NEW_SMALL_INT keeps 31 bits of that.
    i = _ftoi(f)
    if i is STOP or i > 2147483647 or i < -2147483648:
        return 0
    return _sx31(i)


# ---------------------------------------------------------------------------
# Unary ops and truth

def _unop(op, x):
    t = _tag(x)
    if op == UNOP_BOOL:
        return _truth(x)
    if op == UNOP_HASH:
        return _hashv(x)
    if op == UNOP_LEN:
        return len(x)
    if x is True or x is False:
        return _unop(op, 1 if x is True else 0)
    if t == TAG_COMPLEX:
        re, im = _cparts(x)
        if op == UNOP_POSITIVE:
            return x
        if op == UNOP_NEGATIVE:
            return _complex(-re, -im)
        if op == UNOP_ABS:
            return _fsqrt(re * re + im * im)
    if t == TAG_FLOAT and op == UNOP_ABS:
        return -x if x < 0 or (x == 0 and _pay(x) < 0) else x
    if (t == TAG_INT or t == TAG_INT64) and op == UNOP_ABS:
        return -x if x < 0 else x
    if t == TAG_OBJECT and _isuser(x):
        name = ('__pos__', '__neg__', '__invert__', '', '', '', '', '__abs__')[op]
        f = _tlookup(_ld(x, 1), name)
        if f is not NULL:
            return _call_member(f, x, ())
        sub = _subobj(x)
        if sub is not NULL:
            return _unop(op, sub)
    name = ('__pos__', '__neg__', '__invert__', '', '', '', '', '__abs__')[op]
    _unsupported_un(name, x)


def _truth(x):
    # mp_obj_is_true for what the core cannot judge.
    t = _tag(x)
    if t == TAG_CONTROL:
        return x is True
    if t == TAG_INT:
        return x != 0
    if t == TAG_FLOAT:
        return x != 0.0
    if t == TAG_COMPLEX:
        re, im = _cparts(x)
        return re != 0.0 or im != 0.0
    if t == TAG_QSTR or t == TAG_STR or t == TAG_BYTES:
        return _slen(x) != 0
    if t == TAG_TUPLE or t == TAG_MUT:
        return _ld(x, 0) != 0
    if t == TAG_RANGE:
        return _range_len(x) != 0
    if t == TAG_OBJECT:
        k = _ld(x, 0)
        if (k == OB_INSTANCE or k == OB_EXCEPTION) and _isuser(x):
            tt = _ld(x, 1)
            f = _tlookup(tt, '__bool__')
            if f is not NULL:
                r = _call_member(f, x, ())
                return r is True or (r is not False and _truth(r))
            f = _tlookup(tt, '__len__')
            if f is not NULL:
                r = _call_member(f, x, ())
                return r != 0
            sub = _subobj(x)
            if sub is not NULL:
                return _truth(sub)
        return True
    return True
