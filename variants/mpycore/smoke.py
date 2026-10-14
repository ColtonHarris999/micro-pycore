# Identity and lock checks for the mpycore unix oracle.
import gc
import micropython
import struct
import sys


def fail(msg):
    print(msg)
    raise SystemExit(1)


print("platform", sys.platform)
print("name", sys.implementation.name)
if sys.platform != "upycore":
    fail("platform")
if sys.implementation.name != "upycore":
    fail("name")

pointer = struct.calcsize("P")
print("pointer", pointer)
if pointer != 4:
    fail("pointer")

# binary32, not double: 2**24+1 is not a float32 value.
binary32 = float(2 ** 24 + 1) == float(2 ** 24)
print("binary32", binary32)
if not binary32:
    fail("binary32")

# REPR_A keeps the low mantissa bits that REPR_C drops.
low_bit = struct.unpack("<f", struct.pack("<I", 0x3F800001))[0]
print("repr_a", low_bit != 1.0)
if low_bit == 1.0:
    fail("repr_a")

try:
    _overflow = 1 << 63
    fail("longlong")
except OverflowError:
    print("longlong", "OverflowError")

seen = []


class Finaliser:
    def __del__(self):
        seen.append(1)


obj = Finaliser()
del obj
gc.collect()
gc.collect()
print("finaliser", len(seen))
if len(seen) != 0:
    fail("finaliser")

accepted = [-1]
kind = [""]


def leaf(_arg):
    return None


def pump(_arg):
    count = 0
    try:
        for _i in range(32):
            micropython.schedule(leaf, None)
            count += 1
    except RuntimeError:
        accepted[0] = count
        kind[0] = "RuntimeError"
    else:
        accepted[0] = count
        kind[0] = ""


micropython.schedule(pump, None)
for _i in range(64):
    pass
print("schedule", accepted[0], kind[0])
if accepted[0] != 8 or kind[0] != "RuntimeError":
    fail("schedule")


def rec():
    return rec()


try:
    rec()
    fail("stack")
except RuntimeError:
    print("stack", "RuntimeError")

print("smoke", "ok")
