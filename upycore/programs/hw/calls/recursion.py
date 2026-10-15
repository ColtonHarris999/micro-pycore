def rec():
    return rec()


try:
    rec()
    print("returned")
except Exception as e:
    print(type(e).__name__)
    print(e)
