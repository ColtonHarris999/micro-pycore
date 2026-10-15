# Exceptions the core asks for (the _raise hook) and the firmware's own
# error helpers. Message texts are the oracle's (py/*.c MP_ERROR_TEXT).
from ._abi import *


def _q(name):
    # Quote a name the way '%q' messages do.
    return _s("'", name, "'")


def _typeerr(*parts):
    raise TypeError(_join(parts))


def _valerr(*parts):
    raise ValueError(_join(parts))


def _attr_error(obj, name):
    if _istype(obj):
        raise AttributeError(_s("type object '", _ld(obj, 4), "' has no attribute '", name, "'"))
    if _kind(obj) == OB_MODULE:
        raise AttributeError(_s("'", _tname(obj), "' object has no attribute '", name, "'"))
    raise AttributeError(_s("'", _tname(obj), "' object has no attribute '", name, "'"))


def _unsupported_bin(op, a, b):
    raise TypeError(_s("unsupported types for ", _binop_name(op), ": '", _tname(a), "', '", _tname(b), "'"))


def _unsupported_un(name, x):
    raise TypeError(_s("unsupported type for ", name, ": '", _tname(x), "'"))


def _arg_count(expected, given):
    raise TypeError(_s("function takes ", _istr(expected), " positional arguments but ",
                       _istr(given), " were given"))


def _no_kw():
    raise TypeError("function doesn't take keyword arguments")


def _check_args(args, kw, lo, hi):
    # mp_arg_check_num for a firmware builtin with *args, **kw.
    if kw:
        _no_kw()
    n = len(args)
    if n < lo:
        if lo == hi:
            _arg_count(lo, n)
        raise TypeError(_s("function missing ", _istr(lo - n), " required positional arguments"))
    if n > hi:
        if lo == hi:
            _arg_count(lo, n)
        raise TypeError(_s("function expected at most ", _istr(hi), " arguments, got ", _istr(n)))


def _not_iterable(x):
    raise TypeError(_s("'", _tname(x), "' object isn't iterable"))


def _index_type(container, index):
    if _isstr(container):
        raise TypeError(_s("string indices must be integers, not ", _tname(index)))
    raise TypeError(_s(_tname(container), " indices must be integers, not ", _tname(index)))


def _raise(code, a, b):
    if code == ERR_NAME:
        raise NameError(_s("name '", a, "' isn't defined"))
    if code == ERR_NOT_CALLABLE:
        raise TypeError(_s("'", _tname(a), "' object isn't callable"))
    if code == ERR_NOT_ITERABLE:
        _not_iterable(a)
    if code == ERR_NOT_ITERATOR:
        raise TypeError(_s("'", _tname(a), "' object isn't an iterator"))
    if code == ERR_UNHASHABLE:
        _unsupported_un('__hash__', a)
    if code == ERR_ARG_COUNT:
        _arg_count(a, b)
    if code == ERR_ARG_MISSING_POS:
        raise TypeError(_s("function missing ", _istr(a), " required positional arguments"))
    if code == ERR_ARG_KW_UNEXPECTED:
        raise TypeError(_s("unexpected keyword argument '", a, "'"))
    if code == ERR_ARG_KW_MULTIPLE:
        raise TypeError(_s("function got multiple values for argument '", a, "'"))
    if code == ERR_ARG_KW_MISSING:
        raise TypeError(_s("function missing required keyword argument '", a, "'"))
    if code == ERR_ARG_KWONLY:
        raise TypeError("function missing keyword-only argument")
    if code == ERR_ARG_MISSING_N:
        raise TypeError(_s("function missing required positional argument #", _istr(a)))
    if code == ERR_KEY:
        raise KeyError(a)
    if code == ERR_ATTR:
        _attr_error(a, b)
    if code == ERR_NOT_EXC:
        raise TypeError("exceptions must derive from BaseException")
    if code == ERR_IMPORT_NAME:
        raise ImportError(_s("can't import name ", a))
    if code == ERR_INIT_NONE:
        raise TypeError(_s("__init__() should return None, not '", _tname(a), "'"))
    if code == ERR_UNSUPPORTED_BIN:
        _unsupported_bin(a, b[0], b[1])
    if code == ERR_BUILTIN_ARGS:
        raise TypeError(_s(a, "() takes the wrong number of arguments"))
    if code == ERR_MEMORY:
        raise MemoryError(_s("memory allocation failed, allocating ", _istr(a), " bytes"))
    if code == ERR_INDEX_TYPE:
        _index_type(a, b)
    if code == ERR_NO_KW:
        _no_kw()
    if code == ERR_GENERATOR:
        raise NotImplementedError("generators aren't supported")
    if code == ERR_CANT_CREATE:
        raise TypeError(_s("can't create '", _ld(a, 4), "' instances"))
    if code == ERR_STAR_ARGS:
        raise RuntimeError("too many arguments")
    if code == ERR_NOT_TYPE:
        raise TypeError("issubclass() arg 2 must be a class or a tuple of classes")
    raise RuntimeError(_s("internal error ", _istr(code)))
