class A:
    def __init__(self):
        self.x = 1

    def f(self):
        return "A" + str(self.x)


class B(A):
    def __init__(self):
        super().__init__()
        self.y = 2

    def f(self):
        return "B" + super().f() + str(self.y)


class C(A):
    def f(self):
        return "C" + super().f()


class D(B, C):
    def f(self):
        return "D" + super().f()


print(B().f(), B().x, B().y)
print(isinstance(B(), A), issubclass(B, A), issubclass(A, B))
print(D().f())
bases = []
for base in D.__bases__:
    bases.append(base.__name__)
print(tuple(bases))
bases = []
for base in B.__bases__:
    bases.append(base.__name__)
print(tuple(bases))
