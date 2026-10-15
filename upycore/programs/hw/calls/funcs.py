def add(a, b=2, c=3):
    return (a, b, c)


print(add(1), add(1, 9), add(1, c=8), add(1, 4, 5))


def star(a, *, b):
    return (a, b)


print(star(1, b=2))
try:
    print(star(1, 2))
except Exception as e:
    print(type(e).__name__, e)


def later(n=1 + 2):
    return n


print(later(), later(9))
print((lambda x, y=1: x + y)(4))
print((lambda x, y=1: x + y)(4, 3))


def outer(n):
    def inner(x):
        return x + n
    return inner


print(outer(10)(3), outer(1)(2))


g = 1


def setg(v):
    global g
    g = v


setg(5)
print(g)


def nest():
    x = 1

    def inner():
        nonlocal x
        x += 2
        return x

    return inner()


print(nest())
