import helper
from helper import VALUE, add
import helper as h

print(helper.VALUE, VALUE, add(20, 22), h.mul(6, 7))
from helper import *
print(mul(2, 3))
try:
    import no_such_mod_xyz
except ImportError as e:
    print(type(e).__name__, e)
