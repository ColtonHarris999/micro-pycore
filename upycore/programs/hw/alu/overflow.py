def shl(a, b):
    return a << b


def add(a, b):
    return a + b


def mul(a, b):
    return a * b


def run(fn, a, b):
    try:
        print(fn.__name__, fn(a, b))
    except Exception as e:
        print(fn.__name__, type(e).__name__, e)


run(shl, 1, 63)
run(add, 1 << 62, 1 << 62)
run(mul, 1 << 32, 1 << 32)
