class A:
    n = 1

    def __init__(self, x):
        self.x = x

    def m(self, y):
        return self.x + y

    @staticmethod
    def s(z):
        return z + 1

    @classmethod
    def c(cls):
        return cls.n


obj = A(3)
print(obj.m(4), A.s(5), A.c(), obj.x)
print(isinstance(obj, A), issubclass(A, object), A.__name__)
print(obj.__class__.__name__)
obj.y = 8
print(obj.y)
del obj.y
try:
    print(obj.y)
except Exception as e:
    print(type(e).__name__)
found = []
for name in ("m", "s", "c", "nope"):
    if hasattr(A, name):
        found.append(name)
print(found)
print(getattr(obj, "x"), getattr(obj, "missing", 0))
setattr(obj, "x", 6)
print(obj.x)
