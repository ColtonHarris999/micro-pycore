def child(n):
    return n


def outer(x):
    def inner():
        return x

    return inner


limit = 100
acc = 0
marker = "phase1_marker"
pair = (1, 2, "phase1_marker")
hi = 2 ** 63 - 1
lo = -2 ** 63
mid = 2 ** 30
wide = 2 ** 40
dots = ...
blob = b"ab"
neg = -100
while acc < limit:
    acc = acc + child(1)
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    acc = acc + 1
    if acc > limit:
        acc = acc - 1
    else:
        acc = acc + 0
print(acc, pair, marker, wide, neg, outer(acc), hi, lo, mid, dots, blob)
