def make(n):
    def inc(x):
        return x + n

    def bump():
        nonlocal n
        n += 1
        return n

    return inc, bump


inc, bump = make(10)
print(inc(3), bump(), inc(3))

fs = []
for i in range(3):
    fs.append(lambda i=i: i)
print([f() for f in fs])


def depth(n):
    if n == 0:
        return "bottom"
    return depth(n - 1) + str(n)


print(depth(4))
