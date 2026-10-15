def show(x):
    print(bool(x), True if x else False, not x)


show(0)
show(1)
show(-1)
show("")
show("a")
show([])
show([0])
show(())
show((0,))
show({})
show({1: 2})
show(set())
show({0})
show(None)
show(True)
show(False)


def side(n):
    print("eval", n)
    return n


print("and", side(0) and side(1))
print("or", side(1) or side(2))
print("and2", side(2) and side(3))
print("or2", side(0) or side(4))
