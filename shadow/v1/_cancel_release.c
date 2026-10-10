#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <pthread.h>

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef YSTACK_CANCEL_RELEASE_TESTING
#define YSTACK_CANCEL_RELEASE_TESTING 0
#endif
#ifndef YSTACK_CANCEL_TEST_CASE
#define YSTACK_CANCEL_TEST_CASE 0
#endif

enum result_tag { NOT_RUN = 0, RETURNED = 1 };
enum phase {
    PHASE_PREPARED = 0,
    PHASE_ENTRY_BLOCKED,
    PHASE_CONSUMER,
    PHASE_FINAL_BLOCKED,
    PHASE_RELEASE_RUNNING,
    PHASE_SEALED
};
enum failure_slot {
    FAILURE_NONE = 0,
    FAILURE_ENTRY_MASK,
    FAILURE_RESUME_MASK,
    FAILURE_FINAL_MASK,
    FAILURE_HOLD_DUP,
    FAILURE_HOLD_FSTAT,
    FAILURE_ROLLBACK_UNLINK,
    FAILURE_ROLLBACK_FSYNC,
    FAILURE_FINISH_MASK,
    FAILURE_CLOSE,
    FAILURE_CLOSE_FSTAT,
    FAILURE_CONDITIONAL_CLOSE
};

typedef struct {
    int tag;
    int rc;
    int error_number;
} result_cell;

typedef struct {
    PyObject_HEAD
    enum phase phase;
    enum failure_slot first_failure;
    sigset_t watched;
    sigset_t entry_old;
    sigset_t final_old;
    result_cell entry_mask;
    result_cell resume_mask;
    result_cell final_mask;
    result_cell finish_mask;
    result_cell hold_dup;
    result_cell hold_fstat;
    result_cell rollback_unlink;
    result_cell rollback_fsync;
    result_cell close_result;
    result_cell close_fstat;
    result_cell conditional_close;
    int completion_fd;
    int completion_identity_valid;
    dev_t completion_dev;
    ino_t completion_ino;
    mode_t completion_type;
    int rollback_attempted;
    PyObject *outcome_pending;
    PyObject *outcome_success;
    PyObject *outcome_failure;
    PyObject *outcome_value;
    PyObject *module_ref;
    PyObject *method_refs[7];
} NativeState;

static PyMethodDef state_methods[];
static PyTypeObject NativeStateType = {
    PyVarObject_HEAD_INIT(NULL, 0)
    .tp_name = "_cancel_release.NativeState",
    .tp_basicsize = sizeof(NativeState),
    .tp_flags = Py_TPFLAGS_DEFAULT,
    .tp_methods = state_methods,
    .tp_new = NULL
};

static void
record_result(result_cell *cell, int rc, int error_number)
{
    cell->tag = RETURNED;
    cell->rc = rc;
    cell->error_number = error_number;
}

static void
remember_failure(NativeState *state, enum failure_slot slot)
{
    if (state->first_failure == FAILURE_NONE) {
        state->first_failure = slot;
    }
    state->outcome_value = state->outcome_failure;
}

static int
mask_call(int which, int how, const sigset_t *set, sigset_t *old)
{
#if !YSTACK_CANCEL_RELEASE_TESTING
    (void)which;
#endif
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == which) {
        return EIO;
    }
#endif
    return pthread_sigmask(how, set, old);
}

static int
close_call(int fd, int conditional)
{
#if !YSTACK_CANCEL_RELEASE_TESTING
    (void)conditional;
#endif
#if YSTACK_CANCEL_RELEASE_TESTING
    if (!conditional && (YSTACK_CANCEL_TEST_CASE == 5 ||
            YSTACK_CANCEL_TEST_CASE == 7 || YSTACK_CANCEL_TEST_CASE == 8)) {
        errno = EINTR;
        return -1;
    }
    if (!conditional && YSTACK_CANCEL_TEST_CASE == 6) {
        (void)close(fd);
        errno = EBADF;
        return -1;
    }
#endif
    return close(fd);
}

static int
fstat_call(int fd, struct stat *value)
{
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 7) {
        errno = EIO;
        return -1;
    }
#endif
    int rc = fstat(fd, value);
#if YSTACK_CANCEL_RELEASE_TESTING
    if (rc == 0 && YSTACK_CANCEL_TEST_CASE == 8) {
        value->st_ino ^= (ino_t)1;
    }
#endif
    return rc;
}

static void
rollback_marker(NativeState *state)
{
    int rc;
    int saved_errno;
    if (state->rollback_attempted || state->completion_fd < 0 ||
            !state->completion_identity_valid) {
        return;
    }
    state->rollback_attempted = 1;
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 9) {
        errno = EIO;
        rc = -1;
    }
    else
#endif
    {
        rc = unlinkat(state->completion_fd, "bundle.json", 0);
    }
    saved_errno = rc < 0 ? errno : 0;
    record_result(&state->rollback_unlink, rc, saved_errno);
    if (rc < 0) {
        remember_failure(state, FAILURE_ROLLBACK_UNLINK);
    }
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 10) {
        errno = EIO;
        rc = -1;
    }
    else
#endif
    {
        rc = fsync(state->completion_fd);
    }
    saved_errno = rc < 0 ? errno : 0;
    record_result(&state->rollback_fsync, rc, saved_errno);
    if (rc < 0) {
        remember_failure(state, FAILURE_ROLLBACK_FSYNC);
    }
}

static int
require_phase(NativeState *state, enum phase expected)
{
    if (state->phase != expected) {
        PyErr_SetString(PyExc_RuntimeError, "invalid native cancellation phase");
        return 0;
    }
    return 1;
}

static PyObject *
state_block_entry(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    int rc;
    if (!require_phase(state, PHASE_PREPARED)) {
        return NULL;
    }
    rc = mask_call(1, SIG_BLOCK, &state->watched, &state->entry_old);
    record_result(&state->entry_mask, rc, 0);
    if (rc != 0) {
        remember_failure(state, FAILURE_ENTRY_MASK);
    }
    else {
        state->phase = PHASE_ENTRY_BLOCKED;
#if YSTACK_CANCEL_RELEASE_TESTING
        if (YSTACK_CANCEL_TEST_CASE == 11) {
            (void)raise(SIGTERM);
        }
#endif
    }
    Py_RETURN_NONE;
}

static PyObject *
state_resume_consumer(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    int rc;
    if (!require_phase(state, PHASE_ENTRY_BLOCKED) ||
            state->entry_mask.tag != RETURNED || state->entry_mask.rc != 0) {
        return NULL;
    }
    rc = mask_call(2, SIG_SETMASK, &state->entry_old, NULL);
    record_result(&state->resume_mask, rc, 0);
    if (rc != 0) {
        remember_failure(state, FAILURE_RESUME_MASK);
    }
    else {
        state->phase = PHASE_CONSUMER;
    }
    Py_RETURN_NONE;
}

static PyObject *
state_hold_completion(NativeState *state, PyObject *argument)
{
    long borrowed;
    int owned;
    int saved_errno;
    struct stat value;
    if (!require_phase(state, PHASE_CONSUMER) || !PyLong_CheckExact(argument) ||
            state->completion_fd >= 0) {
        if (!PyErr_Occurred()) {
            PyErr_SetString(PyExc_TypeError, "hold_completion requires one owned directory fd");
        }
        return NULL;
    }
    borrowed = PyLong_AsLong(argument);
    if (borrowed < 0 || borrowed > INT32_MAX || PyErr_Occurred()) {
        return NULL;
    }
#ifdef F_DUPFD_CLOEXEC
    owned = fcntl((int)borrowed, F_DUPFD_CLOEXEC, 0);
#else
    owned = dup((int)borrowed);
    if (owned >= 0 && fcntl(owned, F_SETFD, FD_CLOEXEC) < 0) {
        saved_errno = errno;
        (void)close(owned);
        errno = saved_errno;
        owned = -1;
    }
#endif
    saved_errno = owned < 0 ? errno : 0;
    record_result(&state->hold_dup, owned < 0 ? -1 : 0, saved_errno);
    if (owned < 0) {
        remember_failure(state, FAILURE_HOLD_DUP);
        Py_RETURN_NONE;
    }
    state->completion_fd = owned;
    if (fstat(owned, &value) < 0) {
        saved_errno = errno;
        record_result(&state->hold_fstat, -1, saved_errno);
        remember_failure(state, FAILURE_HOLD_FSTAT);
        Py_RETURN_NONE;
    }
    record_result(&state->hold_fstat, 0, 0);
    state->completion_dev = value.st_dev;
    state->completion_ino = value.st_ino;
    state->completion_type = value.st_mode & S_IFMT;
    state->completion_identity_valid = 1;
    Py_RETURN_NONE;
}

static PyObject *
state_block_final(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    int rc;
    if (!require_phase(state, PHASE_CONSUMER) || state->completion_fd < 0) {
        return NULL;
    }
    rc = mask_call(3, SIG_BLOCK, &state->watched, &state->final_old);
    record_result(&state->final_mask, rc, 0);
    if (rc != 0) {
        remember_failure(state, FAILURE_FINAL_MASK);
    }
    else {
        state->phase = PHASE_FINAL_BLOCKED;
    }
    Py_RETURN_NONE;
}

static PyObject *
state_rollback_marker(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    if (state->phase != PHASE_ENTRY_BLOCKED && state->phase != PHASE_CONSUMER &&
            state->phase != PHASE_FINAL_BLOCKED) {
        PyErr_SetString(PyExc_RuntimeError, "invalid native cancellation phase");
        return NULL;
    }
    rollback_marker(state);
    Py_RETURN_NONE;
}

static PyObject *
state_finish_release(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    const sigset_t *restore = NULL;
    int rc;
    int saved_errno;
    int conditional_rc;
    struct stat value;
    if (state->phase == PHASE_ENTRY_BLOCKED && state->entry_mask.tag == RETURNED &&
            state->entry_mask.rc == 0) {
        restore = &state->entry_old;
    }
    else if (state->phase == PHASE_FINAL_BLOCKED && state->final_mask.tag == RETURNED &&
            state->final_mask.rc == 0) {
        restore = &state->final_old;
    }
    else if (state->phase != PHASE_PREPARED && state->phase != PHASE_CONSUMER) {
        PyErr_SetString(PyExc_RuntimeError, "invalid native cancellation phase");
        return NULL;
    }
    state->phase = PHASE_RELEASE_RUNNING;
    if (state->first_failure != FAILURE_NONE && !state->rollback_attempted) {
        rollback_marker(state);
    }
    if (restore != NULL) {
        rc = mask_call(4, SIG_SETMASK, restore, NULL);
        record_result(&state->finish_mask, rc, 0);
        if (rc != 0) {
            remember_failure(state, FAILURE_FINISH_MASK);
            rollback_marker(state);
        }
    }
    if (state->completion_fd >= 0) {
        rc = close_call(state->completion_fd, 0);
        saved_errno = rc < 0 ? errno : 0;
        record_result(&state->close_result, rc, saved_errno);
        if (rc == 0) {
            state->completion_fd = -1;
            state->completion_identity_valid = 0;
        }
        else {
            remember_failure(state, FAILURE_CLOSE);
            rc = fstat_call(state->completion_fd, &value);
            saved_errno = rc < 0 ? errno : 0;
            record_result(&state->close_fstat, rc, saved_errno);
            if (rc < 0) {
                remember_failure(state, FAILURE_CLOSE_FSTAT);
                state->completion_fd = -1;
                state->completion_identity_valid = 0;
            }
            else if (!state->completion_identity_valid ||
                    value.st_dev != state->completion_dev ||
                    value.st_ino != state->completion_ino ||
                    (value.st_mode & S_IFMT) != state->completion_type) {
                state->completion_fd = -1;
                state->completion_identity_valid = 0;
            }
            else {
                rollback_marker(state);
                conditional_rc = close_call(state->completion_fd, 1);
                saved_errno = conditional_rc < 0 ? errno : 0;
                record_result(&state->conditional_close, conditional_rc, saved_errno);
                if (conditional_rc < 0) {
                    remember_failure(state, FAILURE_CONDITIONAL_CLOSE);
                }
                state->completion_fd = -1;
                state->completion_identity_valid = 0;
            }
        }
    }
    state->phase = PHASE_SEALED;
    if (state->first_failure == FAILURE_NONE) {
        state->outcome_value = state->outcome_success;
    }
    else {
        state->outcome_value = state->outcome_failure;
    }
    Py_INCREF(state->outcome_value);
    return state->outcome_value;
}

static PyObject *
state_outcome(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    Py_INCREF(state->outcome_value);
    return state->outcome_value;
}

static PyMethodDef state_methods[] = {
    {"block_entry", (PyCFunction)state_block_entry, METH_NOARGS, NULL},
    {"resume_consumer", (PyCFunction)state_resume_consumer, METH_NOARGS, NULL},
    {"hold_completion", (PyCFunction)state_hold_completion, METH_O, NULL},
    {"block_final", (PyCFunction)state_block_final, METH_NOARGS, NULL},
    {"rollback_marker", (PyCFunction)state_rollback_marker, METH_NOARGS, NULL},
    {"finish_release", (PyCFunction)state_finish_release, METH_NOARGS, NULL},
    {"outcome", (PyCFunction)state_outcome, METH_NOARGS, NULL},
    {NULL, NULL, 0, NULL}
};

static PyObject *
prepare_state(PyObject *module, PyObject *Py_UNUSED(ignored))
{
    NativeState *state;
    struct sigaction action;
    size_t index;
    static const char *names[] = {
        "block_entry", "resume_consumer", "hold_completion", "block_final",
        "rollback_marker", "finish_release", "outcome"
    };
    state = PyObject_New(NativeState, &NativeStateType);
    if (state == NULL) {
        return NULL;
    }
    memset(((char *)state) + sizeof(PyObject), 0, sizeof(*state) - sizeof(PyObject));
    state->phase = PHASE_PREPARED;
    state->completion_fd = -1;
    if (sigemptyset(&state->watched) != 0 ||
            sigaddset(&state->watched, SIGHUP) != 0 ||
            sigaddset(&state->watched, SIGINT) != 0 ||
            sigaddset(&state->watched, SIGTERM) != 0) {
        Py_DECREF(state);
        return PyErr_SetFromErrno(PyExc_OSError);
    }
    if (sigaction(SIGHUP, NULL, &action) != 0 ||
            sigaction(SIGINT, NULL, &action) != 0 ||
            sigaction(SIGTERM, NULL, &action) != 0) {
        Py_DECREF(state);
        return PyErr_SetFromErrno(PyExc_OSError);
    }
    state->outcome_pending = PyUnicode_InternFromString("native-release.pending");
    state->outcome_success = PyUnicode_InternFromString("native-release.success");
    state->outcome_failure = PyUnicode_InternFromString("native-release.failure");
    if (state->outcome_pending == NULL || state->outcome_success == NULL ||
            state->outcome_failure == NULL) {
        Py_DECREF(state);
        return NULL;
    }
    state->outcome_value = state->outcome_pending;
    state->module_ref = module;
    Py_INCREF(module);
    for (index = 0; index < sizeof(names) / sizeof(names[0]); index++) {
        state->method_refs[index] = PyObject_GetAttrString((PyObject *)state, names[index]);
        if (state->method_refs[index] == NULL) {
            Py_DECREF(state);
            return NULL;
        }
    }
    return (PyObject *)state;
}

static PyMethodDef module_methods[] = {
    {"prepare_state", prepare_state, METH_NOARGS, NULL},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef module_definition = {
    .m_base = PyModuleDef_HEAD_INIT,
    .m_name = "_cancel_release",
    .m_size = -1,
    .m_methods = module_methods
};

PyMODINIT_FUNC
PyInit__cancel_release(void)
{
    PyObject *module;
    if (PyType_Ready(&NativeStateType) < 0) {
        return NULL;
    }
    module = PyModule_Create(&module_definition);
    if (module == NULL) {
        return NULL;
    }
    return module;
}
