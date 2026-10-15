def make(r, i):
    return complex(r, i)


print(1 + 2j)
print(make(1.5, -2.0))
c = 3 + 0j
print(c.real, c.imag)
print((1 + 2j) + (3 + 4j))
print((2 + 0j) * (3 + 0j))
