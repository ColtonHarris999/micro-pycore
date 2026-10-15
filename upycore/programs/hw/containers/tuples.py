t = (1, "a", 1)
print(t, len(t), t[0], t[-1], t[1:])
print(t.count(1), t.index("a"))
print(t + (3,), (4,) * 2)
print(1 in t, "b" in t)
a, b = (10, 20)
print(a, b)
try:
    t[0] = 1
except Exception as e:
    print(type(e).__name__)
    print("item assignment" in str(e))
print(tuple([1, 2, 3]), tuple("ab"))
print(())
