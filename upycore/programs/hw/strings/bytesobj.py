b = b"ABc"
print(b, b[0], b[1:], len(b), b.lower(), b.upper())
print(b.find(b"B"), b.count(b"A"), b.startswith(b"AB"))
print(b.decode(), bytes([65, 66, 67]), b"ab".hex())
ba = bytearray(b"ab")
ba.append(99)
ba.extend(b"d")
print(bytes(ba), bytes(ba))
ba[0] = 65
print(bytes(ba))
print(b"a" + b"b", b"ab" * 2, b"a" in b"cat")
print(repr(b"a'b"), bytes(bytearray()))
try:
    print(b"ab"[5])
except Exception as e:
    print(type(e).__name__, e)
