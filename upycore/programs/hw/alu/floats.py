def add(a, b):
    return a + b


def sub(a, b):
    return a - b


def mul(a, b):
    return a * b


def div(a, b):
    return a / b


print(1.5, -2.0, 0.0)
print(add(0.5, 0.25), sub(1.5, 0.5), mul(2.0, 4.0), div(1.0, 4.0))
print(div(1, 2), div(3, 2))
print(float("3.5"), float("-0.25"), int(3.9), int(-3.9))
print(1.0 == 1, 1.5 > 1, 0.0 == False)
print(abs(-1.5), round(2.5), round(1.25, 1))
