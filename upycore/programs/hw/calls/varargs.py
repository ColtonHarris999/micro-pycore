def gather(*args, **kw):
    return (args, kw)


print(gather(1, 2, b=3, a=4))


def explicit(a, b, c=0):
    return (a, b, c)


print(explicit(*[1, 2], c=3))
print(explicit(1, **{"b": 2, "c": 4}))


def method(obj, *args):
    return obj + sum(args)


print(method(*[10, 1, 2, 3]))


class Box:
    def __init__(self, n):
        self.n = n

    def add(self, *args, **kw):
        extra = args[0] if args else 0
        return self.n + extra + kw.get("k", 0)


print(Box(5).add(2, k=3))
print(Box.add(Box(1), 4))
