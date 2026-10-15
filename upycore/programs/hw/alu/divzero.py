def floordiv(a, b):
    return a // b


def mod(a, b):
    return a % b


def div(a, b):
    return a / b


for name, fn in (("floordiv", floordiv), ("mod", mod), ("div", div)):
    try:
        print(name, fn(1, 0))
    except Exception as e:
        print(name, type(e).__name__, e)
