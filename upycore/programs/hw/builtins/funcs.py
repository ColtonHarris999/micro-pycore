print(abs(-4), abs(0), all([1, 2]), all([1, 0]), any([0, 1]), any([0, 0]))
print(chr(65), ord("A"), bin(5), hex(255), oct(8))
print(divmod(7, 3), divmod(-7, 3), pow(2, 5), pow(2, 5, 3))
print(min(3, 1, 2), max(3, 1, 2), min([3, 1]), sum([1, 2, 3], 10))
print(sorted([3, 1, 2], reverse=True))
print(list(enumerate("ab", 1)))
print(list(zip([1, 2], "abc")))
print(list(map(lambda n: n + 1, [1, 2, 3])))
print(list(filter(lambda n: n % 2, range(5))))
print(list(reversed([1, 2, 3])))
print(isinstance(1, int), isinstance(True, int), issubclass(bool, int))
print(callable(len), callable(1), hash("abc"), hash(5), hash(True))
print(int("  -12 "), int("ff", 16), int(True), bool(""), bool("x"))
print(repr([1, "a"]), str(10), len(b"ab"), len(range(3)))
it = iter([4, 5])
print(next(it), next(it))
try:
    print(next(it))
except StopIteration:
    print("stop")
print(next(iter([]), "end"))
class Box:
    def __init__(self):
        self.n = 3


box = Box()
print(hasattr(box, "n"), getattr(box, "n"), getattr(box, "missing", 0))
setattr(box, "n", 4)
print(box.n)
print(... is ...)
print(id(box) == id(box), id(box) != id([]))
