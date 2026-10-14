# expect: viper
# march: x64
import micropython


@micropython.viper
def inc(x: int) -> int:
    return x + 1
