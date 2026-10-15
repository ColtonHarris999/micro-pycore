n = 0
acc = 0
while n < 5:
    n += 1
    if n == 2:
        continue
    if n == 4:
        break
    acc += n
else:
    acc = -1
print(n, acc)

n = 0
while n < 3:
    n += 1
else:
    print("while-else", n)

i = 0
while i < 2:
    j = 0
    while j < 2:
        print(i, j)
        j += 1
    i += 1
