def lt(a, b):
    return a < b


def le(a, b):
    return a <= b


def gt(a, b):
    return a > b


def ge(a, b):
    return a >= b


def eq(a, b):
    return a == b


def ne(a, b):
    return a != b


print(lt(1, 2), lt(2, 2), lt(3, 2))
print(le(1, 2), le(2, 2), gt(3, 2), ge(2, 2))
print(eq(1, 1), eq(1, True), ne(1, 2), ne(0, False))
print(1 < 2 < 3, 1 < 2 > 3, 3 > 2 > 1)
print(eq(1 << 40, 1 << 40), lt(-(1 << 40), 0))
print(None is None, True is True, False is False, None is not True)
print(1 is 1, [] is not [])
print("a" < "b", "abc" == "abc", "ab" != "abc")
