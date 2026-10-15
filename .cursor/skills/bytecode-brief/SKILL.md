---
name: bytecode-brief
description: >-
  Brief on one MicroPython v1.29.0 bytecode for uPyCore: catalog row plus
  where the hart handles it. Use when the user asks about a specific opcode,
  mentions "bytecode brief", or names an opcode like LOAD_FAST or BINARY_OP.
disable-model-invocation: true
---

# Bytecode Brief

Answer with **only** the template below. No preamble, no closing summary.

## Before writing

1. **MicroPython v1.29.0** — read the opcode's row in `upycore/targets/upycore.json` (`name`, `opcode`, `format`, `stack_effect`, `phase`). One short paragraph on what the bytecode does. Stay with the catalog and `upycore/docs/mpy_bytecode.md`; do not invent a CPython 3.14 encoding.
2. **uPyCore status** — grep `upycore/rtl/mpy_decode.sv` and `upycore/rtl/mpy_core.sv` for the opcode. Say which phase the catalog assigns and whether the hart executes it, leaves it to firmware, or rejects it.
3. If the name is not in the catalog, say so and stop.

## Output template

```markdown
## `{OPCODE}`

| | |
|---|---|
| **Opcode** | `{decimal from the catalog}` |
| **Format** | `{byte \| qstr \| varuint \| offset \| ...}` |
| **Stack** | `{stack_effect}` |
| **Phase** | `{phase}` |

### MicroPython

{One paragraph: operand shape and stack effect from the catalog.}

### uPyCore

{One paragraph: where decode or the core handles it, or that it is still firmware-only.}
```

## Style rules

- Exactly two body sections: **MicroPython** and **uPyCore**.
- Each body section is **one paragraph**.
- Use catalog values, not guesses.
