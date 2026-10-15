def show(s):
    print(sorted(s))


s = {3, 1, 2}
show(s)
s.add(2)
s.add(4)
print(sorted(s), 2 in s, 9 in s)
print(sorted(s.union({5, 1})), sorted(s.intersection({1, 4, 9})), sorted(s.difference({1})))
print(sorted(s.symmetric_difference({1, 8})))
t = s.copy()
s.remove(1)
s.discard(100)
show(s)
print(t.issubset(s), s.issubset(t), t.issuperset(s))
print(s.isdisjoint({9}), s.isdisjoint({4}))
u = s.copy()
u.update({7})
show(u)
print(set(), len(set()))
print(sorted({True, 1, False, 0}))
try:
    s.remove(100)
except Exception as e:
    print(type(e).__name__, e)
n = len(s)
popped = s.pop()
print(popped in t, len(s) == n - 1)
s.clear()
show(s)
