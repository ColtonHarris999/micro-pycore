def add(a, b):
    def inner():
        return (a, b, -1000)
    return inner()
