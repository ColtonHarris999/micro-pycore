# Flash image

Phase 1 links a `.mpy` from the pinned `mpy-cross` into one little-endian
image whose byte 0 is flash address `0x0000_0000`. The RTL fetches that
image. It does not parse `.mpy`.

The catalog is [`pycore/targets/mpycore.json`](../targets/mpycore.json).
The static qstr snapshot and the const-kind list live there. This page
records how the linker uses them.

## What the linker accepts

`mpy-cross` is invoked as `-msmall-int-bits=31 -O0` with no `-march`.
A bytecode-only file from that compiler has feature byte `0x00`
(header `4d 06 00 1f`). The catalog still records sub-version 3.
Phase 1 rejects every non-none architecture, and it does not reject a
bytecode-only file for its sub-version. Sub-version 0, 1, and 3 all link.

Rejected, and the error names the thing rejected:

| Input | Error names |
| --- | --- |
| Major version other than the catalog version | `major version` |
| Architecture nibble other than none | the architecture name (`X64`, `ARMV7M`, …) |
| Architecture-flags bit in the feature byte | `architecture flags` |
| Small-int width above the catalog width | `small-int width` |
| Raw code kind native, viper, or asm | `native`, `viper`, or `asm` |
| Const kind float or complex | `float` or `complex` |
| Const kind fun table | `fun_table` |
| Integer literal outside signed 64-bit | `integer literal` and the decimal value |

Accepted const kinds: `None`, `False`, `True`, ellipsis, `str`, `bytes`,
an int that fits signed 64-bit, and `tuple` of those. `*args`,
`**kwargs`, and import are not link errors. A function whose `n_state`
exceeds the 64-entry register file is a link error.

## Qstrs

Ids `1` through `qstr_last_static` are the pin's static list, in order.
Id 0 is null and has no bytes. `zip` is the last static id. A module
qstr that the `.mpy` stored as a static id is stored as that same id.
Any other string is interned once for the whole image and receives the
next id above the static list.

Bytecode operands are not rewritten. A qstr operand stays an index into
that module's qstr table. `LOAD_CONST_OBJ` stays an index into that
module's const table. `MAKE_FUNCTION` stays an index into that raw
code's child table. The module table maps those indexes to image qstr ids.

## Value layout

Flash data words are 32 bits. A Python value is a payload word plus a
4-bit tag in a side array. Slot `i` is the word at `tagged_base + 4*i`.
Its tag is nibble `i`: bits `[3:0]` of the first tag word hold slot 0,
and eight tags fill one word. Bytecode and UTF-8 have no nibbles.

The tag numbers and CONTROL kinds are the catalog's `tags` and
`control_kinds`. An int that fits signed 32-bit is one `INT` slot. A
wider signed 64-bit int is an `INT64` slot and the next slot, tagged
`CONT`, holds the high 32 bits. `None`, `False`, and `True` are
`CONTROL` slots. A const `str`, `bytes`, `tuple`, or ellipsis is one
slot whose payload is the address of a ROM object.

ROM objects use fixed fields and do not tag every field. Element slots
of a tuple are tagged; the length word is not. A djb2 hash that masks
to zero is stored as 1.

| Object | Words |
| --- | --- |
| `str` | byte length, djb2 hash masked to 16 bits, pointer to UTF-8 and a NUL |
| `bytes` | byte length, pointer to the bytes and a NUL |
| `tuple` | element count, then one tagged-slot index per element |
| ellipsis | the catalog's `object_kinds.ellipsis` |

Empty `bytes` and the empty tuple are one shared object each. The empty
string is the static empty qstr. Hashing matches `qstr_compute_hash` at
the extra-features width of two hash bytes.

The first 8 bytes of the image are the magic and version word. No object
address is 0 or 4.

## Image header

Twelve little-endian words at address 0.

| Word | Field |
| --- | --- |
| 0 | Magic `UPMI` |
| 1 | Version in bits 15:0. Bits 31:16 are flags and are 0 |
| 2 | Image size in bytes |
| 3 | `qstr_last_static` |
| 4 | `qstr_count`, including the null id |
| 5 | Offset of the qstr descriptor array |
| 6 | `module_count` (1 in phase 1) |
| 7 | Offset of the module directory |
| 8 | `tagged_base`, or 0 when there are no tagged slots |
| 9 | `tagged_count` |
| 10 | Offset of the tag-nibble array, or 0 when there are no tagged slots |
| 11 | Header size, 48 |

A qstr descriptor is three words: hash, byte length, offset of the
UTF-8. Descriptor 0 is all zeros. Descriptors are indexed by qstr id.

A module-directory entry is eight words. Phase 4 appends entries; it
does not invent a second format. Qstr ids stay assigned once for the image.

| Word | Field |
| --- | --- |
| 0 | Global qstr id of the source name |
| 1 | Number of module qstr-table entries |
| 2 | Offset of that table (one global qstr id per `.mpy` index) |
| 3 | Number of const objects |
| 4 | Offset of the const-slot index table, or 0 when empty |
| 5 | Offset of the module body's raw-code descriptor |
| 6 | Reserved 0 |
| 7 | Reserved 0 |

A raw-code descriptor is twenty words. The bytecode bytes are the `.mpy`
bytes, prelude included.

| Word | Field |
| --- | --- |
| 0 | 0, bytecode |
| 1 | Offset of the bytecode bytes |
| 2 | Bytecode length |
| 3 | Absolute address of the first opcode |
| 4 | Absolute address of the line-info span |
| 5 | Length of the line-info span, in bytes |
| 6 | `n_state` |
| 7 | `n_exc_stack` |
| 8 | `scope_flags` |
| 9 | `n_pos_args` |
| 10 | `n_kwonly_args` |
| 11 | `n_def_pos_args` |
| 12 | `n_info` |
| 13 | `n_cell` |
| 14 | Global qstr id of the simple name |
| 15 | Child count |
| 16 | Offset of the child-descriptor offset array, or 0 |
| 17 | Absolute address of the first closure byte |
| 18 | Opcode start relative to the bytecode |
| 19 | Reserved 0 |

The line-info span is the source-line bytes only. Closure cells sit
after it and before the first opcode. The host decoder that fills words
3, 4, 5, and 17 is `pycore/tools/mpy_prelude.py`.
