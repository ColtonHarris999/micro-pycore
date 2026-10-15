print("%s-%d-%x" % ("a", 3, 255))
print("{}-{}".format(1, "b"))
print("{k}-{n}".format(n=2, k="a"))
name = "up"
print(f"n={1 + 2}-{name}")
print("".format())
print("%s" % ("ok",))
try:
    print("%d" % ("x",))
except Exception as e:
    print(type(e).__name__)
