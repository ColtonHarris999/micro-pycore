class E(ValueError):
    pass


try:
    raise E("boom")
except ValueError as e:
    print(type(e).__name__, e, e.args)
    print(isinstance(e, E), isinstance(e, Exception), isinstance(e, KeyError))

try:
    raise E()
except E as e:
    print("empty", type(e).__name__, e.args)
