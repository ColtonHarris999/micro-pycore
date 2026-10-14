# MicroPython garbage collection

Status: the tracer and the pool allocator are `pycore/rtl/mpy_gc.sv`.
They are not wired into `pycore_core`. The imported collector
(`pycore/rtl/pycore_gc.sv`, described in [`gc.md`](gc.md)) still serves
the 128-bit CPython encoding and is unchanged.

The encoding is planning/micropython_pivot_plan.md §0.5 and §0.6. Tag
numbers live in `pycore/rtl/mpy_defs.svh`. They are not the codes in
`pycore_defs.svh`.

## Words

SRAM and the register file store a 32-bit payload and a 4-bit tag
nibble. Slot `i` is the word at `data_base + 4*i`. Nibble `i` sits in a
side array, eight nibbles to a word. The collector reads the nibble
before it uses the payload. A payload is an address only when the nibble
is a pointer tag.

Pointer tags are `STR`, `TUPLE`, `MUT_COLLEC`, `RANGE`, `ITER`, `BYTES`,
and `OBJECT`. Everything else is immediate:

| Tag | Followed? |
| --- | --- |
| `CONTROL` | no. Kinds in `payload[3:0]` are empty, `None`, null, dict tombstone, `False` (4), `True` (5) |
| `INT` | no |
| `INT64` | no. The high half is a `CONT` word |
| `FLOAT` | no |
| `COMPLEX` | no. The imaginary half is a `CONT` word |
| reserved `0101` | no |
| `QSTR` | no |
| `SHORT_STR` | no. The extra bytes are `CONT` words |
| `CONT` | no. Not a value on its own |

`False` and `True` are `CONTROL` kinds. A bool word is not a pointer,
even when the rest of the payload looks like an address. `MUT_COLLEC`
is the exception among pointer tags: the address is the payload with the
low 2 bits cleared. Those bits are the kind, and the object itself is
4-byte aligned.

| Low bits | Kind |
| --- | --- |
| `00` | list |
| `01` | dict |
| `10` | set |
| `11` | bytearray |

Flash bytecode and UTF-8 have no nibbles. A frozen tuple uses this same
word-plus-nibble layout and is presented through the root list. A ROM
record whose fields are not tagged is not walked by this tracer; the
image names the heap pointers that record owns. An address outside the
pool (flash, a null, the emergency object) is not swept. The emergency
object is still scanned, so a heap child it owns stays live.

## Heap objects

Scalar header fields are counts, hashes, capacities, or the object kind.
The tracer does not follow them. A field the layout calls a pointer is
followed only when its nibble is a pointer tag, and a `MUT_COLLEC` nibble
still clears the low 2 bits. The field, not that nibble, chooses the
child shape: a value array, a byte buffer, or a Python object. Value
slots (tuple elements, list items, dict entries, object fields, roots)
are Python values. Their own tag selects the object layout.

| Object | Words | What is traced |
| --- | --- | --- |
| list | length, item-array pointer | `length` tagged words in the array |
| dict | used count in `[30:0]`, bit 31 object indicator, allocated slots, entry-table pointer, types-table pointer | each entry is a key then a value, for every allocated slot. The types table is traced only when bit 31 is set |
| set | same header as dict | one tagged word per allocated slot. Types table same rule as dict |
| bytearray | length, capacity, buffer pointer | the buffer is marked and not scanned |
| `TUPLE` | length, then elements | the elements |
| `STR` | byte length, hash, byte-buffer pointer | the buffer is marked and not scanned |
| `BYTES` | length, buffer pointer | the buffer is marked and not scanned |
| `RANGE` | start, stop, step | those three values |
| `ITER` | iterable, index | those two values |

`OBJECT` word 0 is the kind. It is not a pointer. Word 1 is the type
pointer, or 0 when there is none, and it is gated by its nibble like any
other value. Fields start at word 2. The kind selects how many:

| Kind | Value | Fields |
| --- | --- | --- |
| `INSTANCE` | 1 | `__dict__` |
| `TYPE` | 2 | `tp_dict`, `tp_base`, `tp_name`, `tp_hash` |
| `BOUND_METHOD` | 3 | function, self |
| `BUILTIN` | 4 | builtin id, bound self |
| `EXCEPTION` | 6 | exception type, `args` tuple |
| `CELL` | 7 | contents |
| `FUNCTION` | 8 | code pointer, closure tuple |
| `MODULE` | 11 | globals dict |

An unknown kind marks the object and traces the type word only. `tp_hash`
is a value: empty `CONTROL` for the default hash, `None` for unhashable,
or a function pointer. A code pointer into flash is an immediate or an
out-of-pool address, so it is not swept.

The allocator's granule is 4 bytes. The mark bit sits on the head
granule. A pointer that is not a head is not a live object. Sweep drops
an unmarked head and every granule of its span. Reachable objects are
marked from roots before that sweep; a cycle stops because a marked head
is not scanned twice.

## Allocation and `MemoryError`

The product collector is always on. If a request does not fit, the opcode
aborts before the first architectural commit, the core collects, and the
opcode is re-dispatched. That is the same rule as [`gc.md`](gc.md): no
used-bit is set and no word is zeroed on the miss. `alloc_aborted_o`
pulses, then the engine collects and searches again with the same size.

A second miss returns `emergency_addr_i` and raises `alloc_memerr_o`.
The emergency object is allocated before user code, not by the failing
opcode. This module never builds it. It is rooted on every collection,
so a copy that lives in the pool is not swept. The unit test places it
outside the pool and checks that the failure path returns that address
with the pool untouched.

The oracle `-X heapsize` is this pool only, not the whole 256 KB SRAM.
A list slot is 4 bytes plus a nibble, and a wide value occupies extra
slots. The tests are a dropped reference that can be allocated again,
and one allocation larger than the pool. They do not pin the append
index where a list growth fails.

A grant is first-fit. The successful commit zeroes the new span and
tags it `CONTROL` empty. `free_bytes_o` is the unmarked free space after
the sweep or the grant.

## Roots

`root_base_i` / `root_count_i` is a contiguous array of tagged slots.
The core fills it with every root, not only the value-stack slice below
the stack pointer (MicroPython's `fastn` sits at `state[n_state - 1]`):

- every live slot of every suspended frame, locals included
- saved exception words on the exception stack
- module globals, the builtins dict, and `sys.modules` once import exists
- machine registers that hold object words
- the schedule ring and the handler table
- the pending-exception slot
- the emergency exception object (also forced from `emergency_addr_i`)

The function object on the frame is what keeps a heap function alive.
Flash bytecode is not a root.

## Mark stack

The stack is `STACK_DEPTH` entries on chip (32 in the unit testbench).
A child that does not fit sets `stack_overflow_o` and is left unmarked.
The rescan list in [`gc.md`](gc.md) is still the overflow rule of the
imported engine. This module does not replace that engine, and the unit
tests fit in the on-chip stack.

## Testbench

`make pycore-mpy-gc` runs `pycore/tb/tb_mpy_gc.sv` on a 64-byte pool.

- An `INSTANCE` keeps the tuple in its one field. A pointer planted in
  the next word does not keep that object. The pool is full, the next
  4-byte request aborts with no store, collection runs, and the grant
  is the dropped block.
- A rooted tuple holds `FLOAT`, `CONT`, `True`, `False`, `INT`, `INT64`,
  `COMPLEX`, `QSTR`, and `SHORT_STR`, each naming a decoy. The decoys
  are reusable afterward. `False`'s payload is one decoy's address.
  `True`'s low nibble is the kind; clearing it would name the other.
- A 128-byte request on the 64-byte pool collects once and returns the
  emergency object. The pool is not written. A later small grant comes
  from the pool, not from that object.
- A `FUNCTION` keeps its closure and not a poison word past field 1.
- A dict pointer with the low bits set walks the aligned object, and
  the entry value stays live.
