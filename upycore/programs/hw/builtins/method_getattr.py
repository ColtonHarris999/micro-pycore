a = [1]
print(hasattr(a, "append"))
try:
    print(getattr(a, "append")(2), a)
except Exception as exc:
    print(type(exc).__name__, exc)
