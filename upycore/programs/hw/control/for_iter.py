out = []
for n in range(4):
    if n == 1:
        continue
    if n == 3:
        break
    out.append(n)
else:
    out.append("else")
print(out)

out = []
for n in range(2):
    out.append(n)
else:
    out.append("else")
print(out)

print(list(range(0)))
print(list(range(4)))
print(list(range(1, 6, 2)))
print(list(range(5, 0, -2)))
print(list(range(3, 3)))
try:
    print(list(range(1, 5, 0)))
except Exception as e:
    print(type(e).__name__, e)

print([c for c in "ab"])
print([x for x in (1, 2, 3)])
print([k for k in {2: "a", 1: "b"}])
print(list(range(2, 11, 3)))

r = range(1, 8, 3)
print(r.start, r.stop, r.step, len(r), r[0], r[-1])
