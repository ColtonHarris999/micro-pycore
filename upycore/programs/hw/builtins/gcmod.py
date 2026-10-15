import gc

print(gc.isenabled())
gc.disable()
print(gc.isenabled())
gc.enable()
print(gc.isenabled())
before = gc.mem_free()
blob = [0] * 200
mid = gc.mem_free()
print(mid < before)
del blob
gc.collect()
print(gc.mem_free() > mid)
print(gc.mem_alloc() >= 0)
print(gc.mem_free() >= 0)
