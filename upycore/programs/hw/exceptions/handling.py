try:
    print(1 // 0)
except ZeroDivisionError as e:
    print("zero", type(e).__name__, e)
except Exception as e:
    print("other", type(e).__name__, e)

try:
    raise ValueError("x")
except ArithmeticError:
    print("arith")
except ValueError as e:
    print("value", type(e).__name__, e.args)
else:
    print("else")
finally:
    print("fin")

try:
    print("ok")
except Exception:
    print("caught")
else:
    print("else2")
finally:
    print("fin2")

try:
    try:
        raise KeyError("k")
    except KeyError:
        print("inner")
        raise
except KeyError as e:
    print("outer", e.args)

try:
    assert False, "nope"
except AssertionError as e:
    print(type(e).__name__, e)

print(repr(ValueError("x")))
print(str(IndexError("i")))
