import sys

print(sys.platform)
print(sys.implementation.name)
print(sys.byteorder)
print(sys.maxsize)
print(sys.implementation.version)
print(sys.argv[0])
print(sys.version_info)
print("sys" in sys.modules)

try:
    sys.exit(0)
except SystemExit as e:
    print("caught", e.args)

print("still")
sys.exit(None)
