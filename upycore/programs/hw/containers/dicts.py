d = {3: "a", 1: "b"}
print(d)
print(list(d), list(d.values()), list(d.items()))
d["c"] = 4
d[1] = "z"
print(d.get("c"), d.get("missing", 0))
print(d.pop(3), d)
print("c" in d, 3 in d)
d.setdefault("k", 5)
d.update({2: "y"})
print(d)
print(d.popitem())
e = d.copy()
d.clear()
print(d, e)
print({1: "i", True: "t", False: "f", 0: "z"})
try:
    print({}["nope"])
except Exception as exc:
    print(type(exc).__name__, exc.args)
del e["c"]
print(e)
print(sorted({"b": 1, "a": 2, "c": 3}))
