// uPyCore unix oracle. Included from ports/unix/mpconfigport.h before the
// port's own defaults. Settings match planning/micropython_pivot_plan.md §3.2.

#define MICROPY_LONGINT_IMPL           (MICROPY_LONGINT_IMPL_LONGLONG)
#define MICROPY_FLOAT_IMPL             (MICROPY_FLOAT_IMPL_FLOAT)
#define MICROPY_OBJ_REPR               (MICROPY_OBJ_REPR_A)
#define MICROPY_CONFIG_ROM_LEVEL       (MICROPY_CONFIG_ROM_LEVEL_EXTRA_FEATURES)
#define MICROPY_ERROR_REPORTING        (MICROPY_ERROR_REPORTING_NORMAL)

// ESP32, RP2, and STM32. The pin's default is 4.
#define MICROPY_SCHEDULER_DEPTH        (8)

// Extra features and the unix port turn finalisers on. A __del__ that
// prints would desynchronize stdout. Posix VFS needs a finaliser, so the
// VFS readers stay off. MICROPY_READER_POSIX still runs a script file.
// Stdio objects are variants/mpycore/stdio.c, one fd each.
#define MICROPY_ENABLE_FINALISER       (0)
#define MICROPY_VFS_POSIX              (0)
#define MICROPY_READER_VFS             (0)

// The common unix variant header turns the emergency buffer on as well.
#define MICROPY_ENABLE_EMERGENCY_EXCEPTION_BUF (1)
#define MICROPY_STACK_CHECK            (1)

#define MICROPY_PY_SYS_PLATFORM        "upycore"
#define MICROPY_PY_SYS_IMPLEMENTATION_NAME MP_QSTR_upycore

// Unicode str stays at the extra-features default (on). Do not set
// MICROPY_PY_BUILTINS_STR_UNICODE here.

#include "mpconfigvariant_common.h"
