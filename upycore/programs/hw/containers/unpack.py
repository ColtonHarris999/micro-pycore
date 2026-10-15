a, b, c = [1, 2, 3]
print(a, b, c)
a, *rest, c = [1, 2, 3, 4, 5]
print(a, rest, c)
a, *rest = (9, 8)
print(a, rest)
(a, b), c = [(1, 2), 3]
print(a, b, c)
print([i * i for i in range(6) if i % 2])
print({i: i * i for i in range(4)})
print({i % 3 for i in range(7)})
print([x + y for x in (1, 2) for y in (10, 20)])
