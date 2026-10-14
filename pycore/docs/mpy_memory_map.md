# uPyCore memory map

Value layout for the MicroPython hart. The CPython map in
[`architecture.md`](architecture.md) stays with that hart. This page is the
one later phases read for the GC pool size.

A value is a 4-bit tag beside a 32-bit payload. The register file is one
36-bit array, 64 entries. A read of an index returns the tag and the payload
together. SRAM and flash data words are 32 bits and are byte-addressed. The
tag does not sit in the word. Slot `i` of a region is the word at
`data_base + 4*i`, and nibble `i` of a side array. Eight tags fill one
32-bit word. Lane 0 is bits `[3:0]`. A store that does not ask for the tag
leaves the nibble as it was.

There is no DRAM. There is no L1 and no L2. SRAM is one cycle. Flash adds
`MPY_FLASH_WAIT_STATES` (default 1) on top of that cycle. The 8-byte fetch
buffer is instruction bytes only. It is not part of this data map.

## Tag table

Locked by the pivot plan. Tag `0101` is reserved.

| Tag | Name | Registers | Payload |
| --- | --- | --- | --- |
| `0000` | CONTROL | 1 | `[3:0]` kind: `0` empty, `1` `None`, `2` null / end of iteration, `3` dict tombstone, `4` `False`, `5` `True` |
| `0001` | INT | 1 | Signed 32-bit. Bytecode small-ints stay in the 31-bit range |
| `0010` | INT64 | 2 | Low 32 bits, then a `CONT` register with the high 32 bits |
| `0011` | FLOAT | 1 | IEEE binary32 |
| `0100` | COMPLEX | 2 | Real binary32, then a `CONT` register with the imaginary binary32 |
| `0101` | reserved | — | Not assigned |
| `0110` | QSTR | 1 | Interned-string id |
| `0111` | SHORT_STR | 4 | Length in the first payload's low byte, then up to 15 bytes across this register and three `CONT` registers |
| `1000` | STR | 1 | Pointer. Length, hash, and bytes live in the object |
| `1001` | TUPLE | 1 | Pointer |
| `1010` | MUT_COLLEC | 1 | Pointer. Low 2 bits are `0` list, `1` dict, `2` set, `3` bytearray. The address clears those bits |
| `1011` | RANGE | 1 | Pointer to start, stop, step |
| `1100` | ITER | 1 | Pointer to the iterable and the index |
| `1101` | BYTES | 1 | Pointer to an immutable `bytes` |
| `1110` | OBJECT | 1 | Pointer. Word 0 is the kind |
| `1111` | CONT | 1 | Extra entry of INT64, COMPLEX, or SHORT_STR |

`False` and `True` are CONTROL kinds 4 and 5. Arithmetic and dict hashing
use them as int 0 and int 1. They are not pointers. CONTROL, INT, INT64,
FLOAT, COMPLEX, QSTR, SHORT_STR, CONT, and the reserved code are not
pointers. STR, TUPLE, MUT_COLLEC, RANGE, ITER, BYTES, and OBJECT are.

A `MUT_COLLEC` address is the payload with bits `[1:0]` cleared. Objects
are 4-byte aligned, so those bits are otherwise zero. Other pointers use
all 32 payload bits. The tag says what the pointer is.

`n_state` counts Python values. Call setup expands INT64 and COMPLEX to two
physical registers and SHORT_STR to four. The compiler emits stock bytecode
and does not encode that expansion.

SHORT_STR bytes sit after the length. The head word is
`{byte2, byte1, byte0, length}`. Each `CONT` word holds the next four bytes,
low byte first. A length above 15 is rejected.

OBJECT kinds in word 0, matching pycore where pycore has that kind:

| Kind | Value |
| --- | ---: |
| INSTANCE | 1 |
| TYPE | 2 |
| BOUND_METHOD | 3 |
| BUILTIN | 4 |
| EXCEPTION | 6 |
| CELL | 7 |
| FUNCTION | 8 |
| MODULE | 11 |

Word 1 is the type pointer, or 0. Fields start at word 2. Heap words are
32-bit payloads with a tag nibble each. There is no 32-byte stride.

## Windows

| Window | Base | Size | Contents |
| --- | --- | ---: | --- |
| Flash | `0x0000_0000` | 512 KB | Linked image. First 8 bytes reserved |
| SRAM | `0x2000_0000` | 256 KB | Frame reserve, schedule ring, handler table, GC pool |
| MMIO | `0x4000_0000` | 4 KB | UART, GPIO, timer, IRQ |
| Sim control | `0xE000_0000` | 256 B | Halt reason, cycle counter. Simulation only |

An address outside these windows is a bus fault. `0x00F4_0000` is outside
them: the old 256 KB register spill does not move into this map. A store to
flash faults. An unaligned word faults. A load of flash byte 0 or 4 returns
zero; those bytes stay reserved so a pointer payload is never 0 or 4.

`-X heapsize` names the GC pool only.

### SRAM

| Region | Base | Window | Used |
| --- | --- | ---: | --- |
| Frame reserve | `0x2000_0000` | 16 KB | 32 frame records |
| Schedule ring | `0x2000_4000` | 64 B | 8 entries of function, argument |
| Handler table | `0x2000_4040` | 64 B | 48 B: 6 sources, function and argument each |
| GC pool | `0x2000_4080` | 245632 B (`0x3BF80`) | The rest of the 256 KB |

The pool ends at `0x2004_0000`. Sources, in order: timer, UART RX, GPIO,
soft, `GC_REQ`, sim. The handler table is a GC root. The schedule depth is
8. The ring and the table are tagged slots; their nibbles live in the SRAM
side array.

### Frame record

Stride 512 bytes. Thirty-two records fill the 16 KB reserve.

| Offset | Size | Contents |
| --- | ---: | --- |
| `0x000` | 256 B | 64 payload words. Slot `i` at `+ 4*i` |
| `0x100` | 32 B | 8 packed tag words. Nibble `i` is lane `i % 8` of word `i / 8` |
| `0x120` | 16 B | Return PC, `n_state`, frame index, zero |
| `0x130` | 208 B | Padding inside the stride |

A spill writes every physical register. Payload bytes plus tag bytes plus
the header for 32 frames are 9728 bytes, inside the 16 KB. Tags for these
slots are the packed words in the record, not a second copy. Tags for every
other SRAM slot are the side array, which is not its own address window and
is not subtracted from the pool. A list slot is 4 bytes of pool plus one
nibble.

The call stack is 32 frames. A 33rd spill faults. Software reports
`RuntimeError: maximum recursion depth exceeded`.

### MMIO offsets

Offsets from `0x4000_0000`. `mpy_mem` decodes the window and stores words.
UART, timer, and IRQ side effects are not in that module.

| Offset | Name |
| --- | --- |
| `0x00` | `UART_TX` |
| `0x04` | `UART_RX` |
| `0x08` | `GPIO_OUT` |
| `0x0C` | `TIMER_COUNT` |
| `0x10` | `IRQ_STATUS` |
| `0x14` | `IRQ_ENABLE` |
| `0x18` | `IRQ_HARD` |
| `0x1C` | `IRQ_GIE` |
| `0x20` | `IRQ_ACTIVE` |
| `0x24` | `IRQ_TABLE` |
| `0x28` | `SCHED_HEAD` |
| `0x2C` | `SCHED_TAIL` |
| `0x30` | `GPIO_IN` |
| `0x34` | `GPIO_EDGE` |

The sim-control page is not a Cortex-M system-control block. Halt names
for that page: clean return, uncaught exception, unsupported opcode, bad
image, flash store, unaligned access, bus fault, stack overflow, step limit.

## Where the constants live

`pycore/rtl/mpy_defs.svh` holds the tag table, the widths, and this map.
`pycore/rtl/mpy_regfile.sv` is the 64-entry array. `pycore/rtl/mpy_mem.sv`
is flash, SRAM, the frame spill, and the other two windows. The CPython
files `pycore_defs.svh` and `pycore_core.sv` are unchanged.

`make mpy-value` reads and writes every tag, spills one frame as payload
words plus packed nibbles, and prints each `MUT_COLLEC` address with the
low bits cleared.
