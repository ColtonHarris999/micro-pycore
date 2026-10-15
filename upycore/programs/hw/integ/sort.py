def sort(a):
    n = len(a)
    i = 0
    while i < n:
        j = 0
        while j < n - 1 - i:
            if a[j] > a[j + 1]:
                a[j], a[j + 1] = a[j + 1], a[j]
            j += 1
        i += 1
    return a


print(sort([3, 1, 4, 1, 5, 9, 2, 6]))
print(sort([]))
print(sort(["b", "a", "c"]))
