# expect: ARMV7M
# march: armv7m
import micropython


@micropython.asm_thumb
def ident(r0):
    mov(r0, r0)
