def classify(x):
    if x < 0:
        return "neg"
    elif x == 0:
        return "zero"
    else:
        return "pos"


print(classify(-2), classify(0), classify(4))
print("yes" if 1 else "no", "yes" if 0 else "no")
a = 1
if a == 1:
    print("one")
elif a == 2:
    print("two")
else:
    print("other")
a = 2
if a == 1:
    print("one")
elif a == 2:
    print("two")
else:
    print("other")
