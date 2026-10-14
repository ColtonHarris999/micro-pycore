// stdin, stdout, and stderr for the mpycore unix oracle.
//
// The stock unix port implements these as posix VFS files. That type needs
// finalisers, which this variant turns off. These objects write each fd
// themselves, so stderr stays off stdout.

#include <errno.h>
#include <poll.h>
#include <unistd.h>

#include "py/mphal.h"
#include "py/obj.h"
#include "py/runtime.h"
#include "py/stream.h"

typedef struct _sys_stdio_obj_t {
    mp_obj_base_t base;
    int fd;
} sys_stdio_obj_t;

static mp_uint_t stdio_read(mp_obj_t self_in, void *buf, mp_uint_t size, int *errcode) {
    sys_stdio_obj_t *self = MP_OBJ_TO_PTR(self_in);
    if (self->fd != STDIN_FILENO) {
        *errcode = MP_EPERM;
        return MP_STREAM_ERROR;
    }
    ssize_t n;
    MP_HAL_RETRY_SYSCALL(n, read(self->fd, buf, size), {
        *errcode = err;
        return MP_STREAM_ERROR;
    });
    return (mp_uint_t)n;
}

static mp_uint_t stdio_write(mp_obj_t self_in, const void *buf, mp_uint_t size, int *errcode) {
    sys_stdio_obj_t *self = MP_OBJ_TO_PTR(self_in);
    if (self->fd == STDIN_FILENO) {
        *errcode = MP_EPERM;
        return MP_STREAM_ERROR;
    }
    ssize_t n;
    MP_HAL_RETRY_SYSCALL(n, write(self->fd, buf, size), {
        *errcode = err;
        return MP_STREAM_ERROR;
    });
    return (mp_uint_t)n;
}

static mp_uint_t stdio_ioctl(mp_obj_t self_in, mp_uint_t request, uintptr_t arg, int *errcode) {
    sys_stdio_obj_t *self = MP_OBJ_TO_PTR(self_in);
    if (request == MP_STREAM_CLOSE) {
        return 0;
    }
    if (request == MP_STREAM_POLL) {
        struct pollfd pfd;
        pfd.fd = self->fd;
        pfd.events = 0;
        pfd.revents = 0;
        if (arg & MP_STREAM_POLL_RD) {
            pfd.events |= POLLIN;
        }
        if (arg & MP_STREAM_POLL_WR) {
            pfd.events |= POLLOUT;
        }
        int n;
        MP_HAL_RETRY_SYSCALL(n, poll(&pfd, 1, 0), {
            *errcode = err;
            return MP_STREAM_ERROR;
        });
        mp_uint_t ret = 0;
        if (pfd.revents & (POLLIN | POLLHUP)) {
            ret |= MP_STREAM_POLL_RD;
        }
        if (pfd.revents & POLLOUT) {
            ret |= MP_STREAM_POLL_WR;
        }
        if (pfd.revents & POLLERR) {
            ret |= MP_STREAM_POLL_ERR;
        }
        if (pfd.revents & POLLHUP) {
            ret |= MP_STREAM_POLL_HUP;
        }
        if (pfd.revents & POLLNVAL) {
            ret |= MP_STREAM_POLL_NVAL;
        }
        return ret;
    }
    *errcode = MP_EINVAL;
    return MP_STREAM_ERROR;
}

static const mp_rom_map_elem_t stdio_locals_dict_table[] = {
    { MP_ROM_QSTR(MP_QSTR_read), MP_ROM_PTR(&mp_stream_read_obj) },
    { MP_ROM_QSTR(MP_QSTR_readinto), MP_ROM_PTR(&mp_stream_readinto_obj) },
    { MP_ROM_QSTR(MP_QSTR_readline), MP_ROM_PTR(&mp_stream_unbuffered_readline_obj) },
    { MP_ROM_QSTR(MP_QSTR_readlines), MP_ROM_PTR(&mp_stream_unbuffered_readlines_obj) },
    { MP_ROM_QSTR(MP_QSTR_write), MP_ROM_PTR(&mp_stream_write_obj) },
    { MP_ROM_QSTR(MP_QSTR_close), MP_ROM_PTR(&mp_identity_obj) },
    { MP_ROM_QSTR(MP_QSTR___enter__), MP_ROM_PTR(&mp_identity_obj) },
    { MP_ROM_QSTR(MP_QSTR___exit__), MP_ROM_PTR(&mp_stream___exit___obj) },
};

static MP_DEFINE_CONST_DICT(stdio_locals_dict, stdio_locals_dict_table);

static const mp_stream_p_t stdio_fileio_stream_p = {
    .read = stdio_read,
    .write = stdio_write,
    .ioctl = stdio_ioctl,
};

static MP_DEFINE_CONST_OBJ_TYPE(
    stdio_fileio_type,
    MP_QSTR_FileIO,
    MP_TYPE_FLAG_ITER_IS_STREAM,
    protocol, &stdio_fileio_stream_p,
    locals_dict, &stdio_locals_dict
    );

static const mp_stream_p_t stdio_textio_stream_p = {
    .read = stdio_read,
    .write = stdio_write,
    .ioctl = stdio_ioctl,
    .is_text = true,
};

#if MICROPY_PY_SYS_STDIO_BUFFER
static sys_stdio_obj_t mp_sys_stdin_buffer_obj;
static sys_stdio_obj_t mp_sys_stdout_buffer_obj;
static sys_stdio_obj_t mp_sys_stderr_buffer_obj;
#endif

sys_stdio_obj_t mp_sys_stdin_obj;
sys_stdio_obj_t mp_sys_stdout_obj;
sys_stdio_obj_t mp_sys_stderr_obj;

#if MICROPY_PY_SYS_STDIO_BUFFER
static void stdio_textio_attr(mp_obj_t self_in, qstr attr, mp_obj_t *dest) {
    if (dest[0] != MP_OBJ_NULL) {
        return;
    }
    if (attr == MP_QSTR_buffer) {
        if (MP_OBJ_TO_PTR(self_in) == &mp_sys_stdin_obj) {
            dest[0] = MP_OBJ_FROM_PTR(&mp_sys_stdin_buffer_obj);
            return;
        }
        if (MP_OBJ_TO_PTR(self_in) == &mp_sys_stdout_obj) {
            dest[0] = MP_OBJ_FROM_PTR(&mp_sys_stdout_buffer_obj);
            return;
        }
        if (MP_OBJ_TO_PTR(self_in) == &mp_sys_stderr_obj) {
            dest[0] = MP_OBJ_FROM_PTR(&mp_sys_stderr_buffer_obj);
            return;
        }
    }
    dest[1] = MP_OBJ_SENTINEL;
}
#define STDIO_TEXTIO_ATTR attr, stdio_textio_attr,
#else
#define STDIO_TEXTIO_ATTR
#endif

static MP_DEFINE_CONST_OBJ_TYPE(
    stdio_textio_type,
    MP_QSTR_TextIOWrapper,
    MP_TYPE_FLAG_ITER_IS_STREAM,
    STDIO_TEXTIO_ATTR
    protocol, &stdio_textio_stream_p,
    locals_dict, &stdio_locals_dict
    );

#if MICROPY_PY_SYS_STDIO_BUFFER
static sys_stdio_obj_t mp_sys_stdin_buffer_obj = {{&stdio_fileio_type}, STDIN_FILENO};
static sys_stdio_obj_t mp_sys_stdout_buffer_obj = {{&stdio_fileio_type}, STDOUT_FILENO};
static sys_stdio_obj_t mp_sys_stderr_buffer_obj = {{&stdio_fileio_type}, STDERR_FILENO};
#endif

sys_stdio_obj_t mp_sys_stdin_obj = {{&stdio_textio_type}, STDIN_FILENO};
sys_stdio_obj_t mp_sys_stdout_obj = {{&stdio_textio_type}, STDOUT_FILENO};
sys_stdio_obj_t mp_sys_stderr_obj = {{&stdio_textio_type}, STDERR_FILENO};
