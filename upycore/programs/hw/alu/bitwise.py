def band(a, b):
    return a & b


def bor(a, b):
    return a | b


def bxor(a, b):
    return a ^ b


def shl(a, b):
    return a << b


def shr(a, b):
    return a >> b


def inv(a):
    return ~a


print(band(0b1100, 0b1010), bor(0b1100, 0b1010), bxor(0b1100, 0b1010))
print(shl(1, 4), shl(3, 0), shr(32, 3), shr(-8, 1))
print(inv(0), inv(-1), inv(5))
n = 1
n <<= 3
n |= 2
n &= 14
n ^= 1
print(n)
try:
    print(shl(1, -1))
except Exception as e:
    print(type(e).__name__, e)
try:
    print(shr(1, -2))
except Exception as e:
    print(type(e).__name__, e)
