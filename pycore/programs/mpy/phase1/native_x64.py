import micropython


@micropython.native
def add_one(x):
    return x + 1
