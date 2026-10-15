class P:
    def __init__(self):
        self._v = 1

    @property
    def v(self):
        return self._v

    @v.setter
    def v(self, x):
        self._v = x + 1


p = P()
print(p.v)
p.v = 3
print(p.v)
print(type(P.v).__name__)
