class Gate:
    def __enter__(self):
        print("enter")
        return "body"

    def __exit__(self, et, ev, tb):
        print("exit", None if et is None else et.__name__)
        return False


with Gate() as value:
    print(value)

class Swallow:
    def __enter__(self):
        return 1

    def __exit__(self, et, ev, tb):
        print("swallow", None if et is None else et.__name__)
        return True


with Swallow():
    raise ValueError("x")
print("continued")
