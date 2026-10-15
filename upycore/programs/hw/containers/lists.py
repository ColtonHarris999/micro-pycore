a = []
a.append(1)
a.append(2)
a.extend([3, 4])
print(a)
print(a[0], a[-1], a[1:3], a[:2], a[2:])
a[1] = 9
print(a)
a[1:3] = [7]
print(a)
print(a.pop(), a)
a.insert(0, 5)
print(a)
print(a.count(5), a.index(7))
b = a.copy()
a.reverse()
print(a, b)
a.remove(5)
print(a)
a.sort()
print(a)
print(a + [8, 8], [1, 2] * 3)
print(1 in a, 100 in a, len(a))
a.clear()
print(a)
try:
    print([1, 2][5])
except Exception as e:
    print(type(e).__name__, e)
a = [1]
a.pop()
try:
    print(a.pop())
except Exception as e:
    print("pop", type(e).__name__, e)
del b[0]
print(b)
