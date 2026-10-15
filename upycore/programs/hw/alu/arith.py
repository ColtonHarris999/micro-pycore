def add(a, b):
    return a + b


def sub(a, b):
    return a - b


def mul(a, b):
    return a * b


def floordiv(a, b):
    return a // b


def mod(a, b):
    return a % b


def pow_(a, b):
    return a ** b


def neg(a):
    return -a


def pos(a):
    return +a


print(add(2, 3), sub(10, 4), mul(6, 7))
print(floordiv(7, 3), mod(7, 3))
print(floordiv(-7, 3), mod(-7, 3))
print(floordiv(7, -3), mod(7, -3))
print(floordiv(-7, -3), mod(-7, -3))
print(pow_(2, 10), pow_(2, 0), pow_(-2, 3), pow_(0, 0))
print(neg(-5), pos(-5), neg(0))
print(add(True, True), mul(True, 4))
print(mul(1 << 20, 1 << 20))
print(add(-(1 << 40), 3))
print(pow_(2, 40))
n = 3
n += 4
n -= 1
n *= 2
print(n)
