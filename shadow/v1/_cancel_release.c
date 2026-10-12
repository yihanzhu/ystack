#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <pthread.h>

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
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
    PHASE_COMMIT_RUNNING,
    PHASE_RELEASE_RUNNING,
    PHASE_SEALED
};
enum decision { DECISION_UNDECIDED = 0, DECISION_ABORT, DECISION_COMPLETED };
enum failure_slot {
    FAILURE_NONE = 0,
    FAILURE_ENTRY_MASK,
    FAILURE_ARM_PIPE,
    FAILURE_ARM_FLAGS,
    FAILURE_ARM_ACTION,
    FAILURE_CHECKPOINT_PENDING,
    FAILURE_CHECKPOINT_MEMBER,
    FAILURE_FINAL_MASK,
    FAILURE_HOLD_DUP,
    FAILURE_HOLD_FSTAT,
    FAILURE_MARKER_OPEN,
    FAILURE_MARKER_WRITE,
    FAILURE_MARKER_FSYNC,
    FAILURE_MARKER_CLOSE,
    FAILURE_DIRECTORY_FSYNC,
    FAILURE_PIPE_OBSERVE,
    FAILURE_FINAL_PENDING,
    FAILURE_FINAL_MEMBER,
    FAILURE_ACTION_RESTORE,
    FAILURE_PIPE_CLOSE,
    FAILURE_ROLLBACK_UNLINK,
    FAILURE_ROLLBACK_FSYNC,
    FAILURE_FINISH_MASK,
    FAILURE_CLOSE,
    FAILURE_CLOSE_FSTAT,
    FAILURE_CONDITIONAL_CLOSE,
    FAILURE_CHILD_PREPARE,
    FAILURE_CHILD_SPAWN,
    FAILURE_CHILD_STDIN_CLOSE,
    FAILURE_CHILD_STDOUT_CLOSE,
    FAILURE_CHILD_STDERR_CLOSE,
    FAILURE_CHILD_OBSERVE,
    FAILURE_CHILD_TERM,
    FAILURE_CHILD_KILL,
    FAILURE_CHILD_GROUP,
    FAILURE_CHILD_REAP
};

enum child_spawn_state { CHILD_EMPTY = 0, CHILD_PREPARED, CHILD_NO_CHILD, CHILD_OWNED,
    CHILD_COMPLETE };

typedef struct {
    int tag;
    int rc;
    int error_number;
} result_cell;

#define CHILD_ARG_COUNT 128
#define CHILD_ENV_COUNT 128
#define CHILD_ARG_BYTES (16 * 1024)
#define CHILD_ENV_BYTES (32 * 1024)
#define WATCHED_COUNT 3
#define PAYLOAD_LIMIT (1024 * 1024)

typedef struct {
    enum child_spawn_state state;
    int role;
    pid_t pid;
    pid_t pgid;
    int fds[6];
    unsigned char fd_owned[6];
    unsigned char fd_attempted[6];
    result_cell fd_result[6];
    result_cell spawn;
    result_cell observe;
    result_cell reap;
    result_cell term;
    result_cell kill;
    result_cell group;
    siginfo_t observed_info;
    siginfo_t reaped_info;
    int exit_observed;
    int leader_reaped;
    int group_absent;
    int pipes_complete;
    int term_required;
    int kill_required;
    int first_error;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    sigset_t parent_mask;
    int actions_ready;
    int attributes_ready;
    char executable[4096];
    char argv_bytes[CHILD_ARG_BYTES];
    char env_bytes[CHILD_ENV_BYTES];
    char *argv[CHILD_ARG_COUNT + 1];
    char *environment[CHILD_ENV_COUNT + 1];
    size_t argc;
    size_t envc;
    PyObject *fd_tuple;
} child_record;

typedef struct {
    PyObject_HEAD
    enum phase phase;
    enum decision decision;
    enum failure_slot first_failure;
    sigset_t watched;
    sigset_t entry_old;
    struct sigaction old_actions[WATCHED_COUNT];
    unsigned char action_installed[WATCHED_COUNT];
    unsigned char action_restore_attempted[WATCHED_COUNT];
    result_cell action_install[WATCHED_COUNT];
    result_cell action_restore[WATCHED_COUNT];
    result_cell entry_mask;
    result_cell checkpoint_pending;
    result_cell checkpoint_member[WATCHED_COUNT];
    result_cell final_mask;
    result_cell final_pending;
    result_cell final_member[WATCHED_COUNT];
    result_cell hold_dup;
    result_cell hold_fstat;
    result_cell marker_open;
    result_cell marker_write;
    result_cell marker_fsync;
    result_cell marker_close;
    result_cell directory_fsync;
    result_cell pipe_observe;
    result_cell pipe_close[2];
    result_cell rollback_unlink;
    result_cell rollback_fsync;
    result_cell finish_mask;
    result_cell close_result;
    result_cell close_fstat;
    result_cell conditional_close;
    volatile sig_atomic_t cancelled;
    int signal_pipe[2];
    unsigned char pipe_owned[2];
    int marker_fd;
    int marker_owned;
    int marker_created;
    int completion_fd;
    int completion_identity_valid;
    dev_t completion_dev;
    ino_t completion_ino;
    mode_t completion_type;
    int rollback_attempted;
    PyObject *payload;
    const char *payload_bytes;
    Py_ssize_t payload_length;
    child_record child;
    PyObject *checkpoint_clear;
    PyObject *checkpoint_cancelled;
    PyObject *checkpoint_failure;
    PyObject *outcome_pending;
    PyObject *outcome_success;
    PyObject *outcome_failure;
    PyObject *outcome_value;
    PyObject *module_ref;
    PyObject *method_refs[24];
} NativeState;

static NativeState *active_state;
static const int watched_signals[WATCHED_COUNT] = { SIGHUP, SIGINT, SIGTERM };
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
    if (state->first_failure == FAILURE_NONE) state->first_failure = slot;
    state->decision = DECISION_ABORT;
    state->outcome_value = state->outcome_failure;
}

static int
mask_call(int which, int how, const sigset_t *set, sigset_t *old)
{
#if !YSTACK_CANCEL_RELEASE_TESTING
    (void)which;
#endif
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == which) return EIO;
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
duplicate_call(int fd)
{
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 12) { errno = EIO; return -1; }
#endif
#ifdef F_DUPFD_CLOEXEC
    return fcntl(fd, F_DUPFD_CLOEXEC, 0);
#else
    return dup(fd);
#endif
}

static int
fstat_call(int fd, struct stat *value)
{
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 7) { errno = EIO; return -1; }
#endif
    int rc = fstat(fd, value);
#if YSTACK_CANCEL_RELEASE_TESTING
    if (rc == 0 && YSTACK_CANCEL_TEST_CASE == 8) value->st_ino ^= (ino_t)1;
#endif
    return rc;
}

static int
hold_fstat_call(int fd, struct stat *value)
{
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 13) { errno = EIO; return -1; }
#endif
    return fstat(fd, value);
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
static void
child_remember_error(child_record *child, enum failure_slot slot)
{
    if (child->first_error == FAILURE_NONE) {
        child->first_error = slot;
    }
}

static void
child_refresh_complete(child_record *child)
{
    size_t index;
    child->pipes_complete = 1;
    for (index = 0; index < 6; index++) {
        if (child->fd_owned[index]) child->pipes_complete = 0;
    }
    if (child->leader_reaped && child->group_absent && child->pipes_complete) {
        child->state = CHILD_COMPLETE;
    }
}

static void
child_close_raw(child_record *child, size_t index)
{
    if (child->fd_owned[index]) {
        int rc;
        int saved_errno;
        child->fd_attempted[index] = 1;
        rc = close(child->fds[index]);
        saved_errno = rc < 0 ? errno : 0;
        record_result(&child->fd_result[index], rc, saved_errno);
        if (rc == 0) child->fd_owned[index] = 0;
        else child_remember_error(child, FAILURE_CHILD_PREPARE);
    }
}

static void
child_release_prepared(child_record *child)
{
    size_t index;
    int remains = 0;
    int rc;
    if (child->actions_ready) {
        rc = posix_spawn_file_actions_destroy(&child->actions);
        child->actions_ready = 0;
        if (rc != 0) child_remember_error(child, FAILURE_CHILD_PREPARE);
    }
    if (child->attributes_ready) {
        rc = posix_spawnattr_destroy(&child->attributes);
        child->attributes_ready = 0;
        if (rc != 0) child_remember_error(child, FAILURE_CHILD_PREPARE);
    }
    for (index = 0; index < 6; index++) {
        child_close_raw(child, index);
        if (child->fd_owned[index]) remains = 1;
    }
    child->pipes_complete = !remains;
    child->state = remains ? CHILD_NO_CHILD : CHILD_EMPTY;
}

static int
copy_child_vector(PyObject *value, char *storage, size_t storage_size,
    char **pointers, size_t pointer_count, size_t *count_out, int environment)
{
    Py_ssize_t count;
    Py_ssize_t index;
    size_t used = 0;
    if (!PyTuple_CheckExact(value)) {
        return 0;
    }
    count = PyTuple_GET_SIZE(value);
    if (count < (environment ? 0 : 1) || (size_t)count > pointer_count) {
        return 0;
    }
    for (index = 0; index < count; index++) {
        PyObject *item = PyTuple_GET_ITEM(value, index);
        char *bytes;
        Py_ssize_t length;
        if (!PyBytes_CheckExact(item) || PyBytes_AsStringAndSize(item, &bytes, &length) < 0 ||
                length <= 0 || memchr(bytes, '\0', (size_t)length) != NULL ||
                (environment && memchr(bytes, '=', (size_t)length) == NULL) ||
                (size_t)length + 1 > storage_size - used) {
            PyErr_Clear();
            return 0;
        }
        memcpy(storage + used, bytes, (size_t)length);
        storage[used + (size_t)length] = '\0';
        pointers[index] = storage + used;
        used += (size_t)length + 1;
    }
    pointers[count] = NULL;
    *count_out = (size_t)count;
    return 1;
}

static int
child_environment_allowed(int role, char **environment, size_t count)
{
    static const char *general[] = {
        "GIT_CONFIG_COUNT=1", "GIT_CONFIG_GLOBAL=/dev/null",
        "GIT_CONFIG_KEY_0=core.hooksPath", "GIT_CONFIG_NOSYSTEM=1",
        "GIT_CONFIG_VALUE_0=", "GIT_NO_LAZY_FETCH=1", "GIT_NO_REPLACE_OBJECTS=1",
        "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0", "HOME=", "LANG=C",
        "LC_ALL=C", "PATH=", "TMPDIR="
    };
    size_t index;
    if (role == 1 || role >= 12) {
        return count == 3 && strcmp(environment[0], "LANG=C") == 0 &&
            strcmp(environment[1], "LC_ALL=C") == 0 &&
            strcmp(environment[2], "PATH=/usr/bin:/bin") == 0;
    }
    if (count != sizeof(general) / sizeof(general[0])) return 0;
    for (index = 0; index < count; index++) {
        size_t length = strlen(general[index]);
        if (strncmp(environment[index], general[index], length) != 0) return 0;
        if ((index == 4 || index == 9 || index == 13) &&
                environment[index][length] != '/') return 0;
        if (index == 12) {
            const char *suffix = strstr(environment[index] + length, ":/usr/bin:/bin");
            if (environment[index][length] != '/' || suffix == NULL ||
                    strcmp(suffix, ":/usr/bin:/bin") != 0) return 0;
        }
    }
    return 1;
}

#if defined(__APPLE__)
static int
darwin_filter_absent(int before_spawn)
{
    struct stat value;
    int rc;
    (void)before_spawn;
#if YSTACK_CANCEL_RELEASE_TESTING
    if ((YSTACK_CANCEL_TEST_CASE == 49 && !before_spawn) ||
            (YSTACK_CANCEL_TEST_CASE == 50 && before_spawn)) {
        errno = before_spawn ? ELOOP : EACCES;
        return 0;
    }
#endif
    rc = lstat("/usr/local/share/posix_spawn_filtering_rules", &value);
    if (rc < 0 && errno == ENOENT) return 1;
    if (rc == 0) errno = EEXIST;
    return 0;
}
#endif

static int
child_platform_admitted(void)
{
#if YSTACK_CANCEL_RELEASE_TESTING
#if defined(__APPLE__)
    return darwin_filter_absent(0);
#else
    return 1;
#endif
#elif defined(__linux__)
#if defined(POSIX_SPAWN_SETSID)
    return 1;
#else
    return 0;
#endif
#elif defined(__APPLE__)
    return darwin_filter_absent(0);
#else
    return 0;
#endif
}

static PyObject *
state_prepare_child(NativeState *state, PyObject *argument)
{
    child_record *child = &state->child;
    PyObject *role_object;
    PyObject *executable_object;
    PyObject *argv_object;
    PyObject *environment_object;
    char *executable;
    Py_ssize_t executable_length;
    long role;
    int pairs[2];
    int rc;
    short flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
    sigset_t defaults;
    size_t index;
    if (!require_phase(state, PHASE_CONSUMER) ||
            (child->state != CHILD_EMPTY && child->state != CHILD_COMPLETE)) {
        if (!PyErr_Occurred()) PyErr_SetString(PyExc_RuntimeError, "child state is not empty");
        return NULL;
    }
    if (!child_platform_admitted()) {
        PyErr_SetString(PyExc_RuntimeError, "native child platform contract is unavailable");
        return NULL;
    }
    if (child->state == CHILD_COMPLETE) {
        Py_CLEAR(child->fd_tuple);
        memset(child, 0, sizeof(*child));
        for (index = 0; index < 6; index++) child->fds[index] = -1;
    }
    if (!PyTuple_CheckExact(argument) || PyTuple_GET_SIZE(argument) != 4) {
        PyErr_SetString(PyExc_TypeError, "prepare_child requires one closed child tuple");
        return NULL;
    }
    role_object = PyTuple_GET_ITEM(argument, 0);
    executable_object = PyTuple_GET_ITEM(argument, 1);
    argv_object = PyTuple_GET_ITEM(argument, 2);
    environment_object = PyTuple_GET_ITEM(argument, 3);
    if (!PyLong_CheckExact(role_object) || !PyBytes_CheckExact(executable_object)) {
        PyErr_SetString(PyExc_TypeError, "invalid child role or executable");
        return NULL;
    }
    role = PyLong_AsLong(role_object);
    if (role < 1 || role > 16 || PyErr_Occurred() ||
            PyBytes_AsStringAndSize(executable_object, &executable, &executable_length) < 0 ||
            executable_length < 2 || executable[0] != '/' ||
            (size_t)executable_length >= sizeof(child->executable) ||
            memchr(executable, '\0', (size_t)executable_length) != NULL ||
            !copy_child_vector(argv_object, child->argv_bytes, sizeof(child->argv_bytes),
                child->argv, CHILD_ARG_COUNT, &child->argc, 0) ||
            !copy_child_vector(environment_object, child->env_bytes, sizeof(child->env_bytes),
                child->environment, CHILD_ENV_COUNT, &child->envc, 1) ||
            !child_environment_allowed((int)role, child->environment, child->envc) ||
            strlen(child->argv[0]) != (size_t)executable_length ||
            memcmp(child->argv[0], executable, (size_t)executable_length) != 0) {
        PyErr_Clear();
        PyErr_SetString(PyExc_ValueError, "child tuple is outside the fixed contract");
        return NULL;
    }
    memcpy(child->executable, executable, (size_t)executable_length);
    child->executable[executable_length] = '\0';
    child->role = (int)role;
    for (index = 0; index < 3; index++) {
        if (pipe(pairs) < 0) {
            goto prepare_failed;
        }
        child->fds[index * 2] = pairs[0];
        child->fd_owned[index * 2] = 1;
        child->fds[index * 2 + 1] = pairs[1];
        child->fd_owned[index * 2 + 1] = 1;
        if (pairs[0] <= STDERR_FILENO || pairs[1] <= STDERR_FILENO) {
            errno = EBADF;
            goto prepare_failed;
        }
        if (fcntl(pairs[0], F_SETFD, FD_CLOEXEC) < 0 ||
                fcntl(pairs[1], F_SETFD, FD_CLOEXEC) < 0) {
            goto prepare_failed;
        }
#if YSTACK_CANCEL_RELEASE_TESTING
        if (YSTACK_CANCEL_TEST_CASE == 21 + (int)index) {
            errno = EIO;
            goto prepare_failed;
        }
#endif
    }
    rc = posix_spawnattr_init(&child->attributes);
    if (rc != 0) { errno = rc; goto prepare_failed; }
    child->attributes_ready = 1;
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 24) { errno = EIO; goto prepare_failed; }
#endif
    memcpy(&child->parent_mask, &state->entry_old, sizeof(child->parent_mask));
    if (sigemptyset(&defaults) != 0 ||
            sigaddset(&defaults, SIGHUP) != 0 || sigaddset(&defaults, SIGINT) != 0 ||
            sigaddset(&defaults, SIGTERM) != 0 || sigaddset(&defaults, SIGPIPE) != 0) {
        goto prepare_failed;
    }
#ifdef POSIX_SPAWN_SETSID
    flags |= POSIX_SPAWN_SETSID;
#else
    errno = ENOTSUP;
    goto prepare_failed;
#endif
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    rc = posix_spawnattr_setflags(&child->attributes, flags);
    if (rc == 0) rc = posix_spawnattr_setsigmask(&child->attributes, &child->parent_mask);
    if (rc == 0) rc = posix_spawnattr_setsigdefault(&child->attributes, &defaults);
    if (rc != 0) { errno = rc; goto prepare_failed; }
    rc = posix_spawn_file_actions_init(&child->actions);
    if (rc != 0) { errno = rc; goto prepare_failed; }
    child->actions_ready = 1;
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 25) { errno = EIO; goto prepare_failed; }
#endif
    rc = posix_spawn_file_actions_adddup2(&child->actions, child->fds[0], STDIN_FILENO);
    if (rc == 0) rc = posix_spawn_file_actions_adddup2(&child->actions, child->fds[3], STDOUT_FILENO);
    if (rc == 0) rc = posix_spawn_file_actions_adddup2(&child->actions, child->fds[5], STDERR_FILENO);
    for (index = 0; rc == 0 && index < 6; index++) {
        rc = posix_spawn_file_actions_addclose(&child->actions, child->fds[index]);
    }
#if defined(__linux__)
#if YSTACK_CANCEL_RELEASE_TESTING
    if (rc == 0 && YSTACK_CANCEL_TEST_CASE == 35) rc = EIO;
    else
#endif
    if (rc == 0) rc = posix_spawn_file_actions_addclosefrom_np(&child->actions, 3);
#endif
    if (rc != 0) { errno = rc; goto prepare_failed; }
    child->fd_tuple = PyTuple_New(3);
    if (child->fd_tuple == NULL) goto prepare_failed;
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 26) {
        PyErr_NoMemory();
        goto prepare_failed;
    }
#endif
    for (index = 0; index < 3; index++) {
        static const size_t parents[3] = {1, 2, 4};
        PyObject *fd_value = PyLong_FromLong(child->fds[parents[index]]);
        if (fd_value == NULL) goto prepare_failed;
        PyTuple_SET_ITEM(child->fd_tuple, (Py_ssize_t)index, fd_value);
    }
    child->state = CHILD_PREPARED;
    Py_RETURN_NONE;

prepare_failed:
    child_remember_error(child, FAILURE_CHILD_PREPARE);
    child_release_prepared(child);
    Py_CLEAR(child->fd_tuple);
    if (!PyErr_Occurred()) PyErr_SetFromErrno(PyExc_OSError);
    return NULL;
}

static PyObject *
state_spawn_child(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    child_record *child = &state->child;
    size_t index;
    int rc;
    if (!require_phase(state, PHASE_CONSUMER) || child->state != CHILD_PREPARED) {
        if (!PyErr_Occurred()) PyErr_SetString(PyExc_RuntimeError, "child is not prepared");
        return NULL;
    }
#if defined(__APPLE__)
    if (!darwin_filter_absent(1)) {
        int saved_errno = errno;
        child_remember_error(child, FAILURE_CHILD_SPAWN);
        child_release_prepared(child);
        child->state = CHILD_NO_CHILD;
        Py_CLEAR(child->fd_tuple);
        errno = saved_errno;
        PyErr_SetFromErrno(PyExc_OSError);
        return NULL;
    }
#endif
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 27) rc = EIO;
    else
#endif
    rc = posix_spawn(&child->pid, child->executable, &child->actions,
        &child->attributes, child->argv, child->environment);
    record_result(&child->spawn, rc, rc);
    if (rc == 0) {
        child->pgid = child->pid;
        child->state = CHILD_OWNED;
        child->term_required = 0;
        child->kill_required = 0;
    }
    else {
        child->pid = 0;
        child->pgid = 0;
        child->state = CHILD_NO_CHILD;
        child_remember_error(child, FAILURE_CHILD_SPAWN);
    }
    if (child->actions_ready) {
        int destroy_rc = posix_spawn_file_actions_destroy(&child->actions);
        child->actions_ready = 0;
        if (destroy_rc != 0) child_remember_error(child, FAILURE_CHILD_PREPARE);
    }
    if (child->attributes_ready) {
        int destroy_rc = posix_spawnattr_destroy(&child->attributes);
        child->attributes_ready = 0;
        if (destroy_rc != 0) child_remember_error(child, FAILURE_CHILD_PREPARE);
    }
    if (rc == 0) {
        child_close_raw(child, 0);
        child_close_raw(child, 3);
        child_close_raw(child, 5);
    }
    else {
        for (index = 0; index < 6; index++) child_close_raw(child, index);
        child->pipes_complete = 1;
        for (index = 0; index < 6; index++) {
            if (child->fd_owned[index]) child->pipes_complete = 0;
        }
    }
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 28 && rc == 0) {
        PyErr_SetString(PyExc_RuntimeError, "simulated lost spawn return");
        return NULL;
    }
#endif
    Py_RETURN_NONE;
}

static PyObject *
state_child_fds(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    if (state->child.state != CHILD_OWNED || state->child.fd_tuple == NULL) {
        PyErr_SetString(PyExc_RuntimeError, "child fds are unavailable");
        return NULL;
    }
    Py_INCREF(state->child.fd_tuple);
    return state->child.fd_tuple;
}

static PyObject *
close_child_parent_fd(NativeState *state, size_t index, enum failure_slot failure)
{
    child_record *child = &state->child;
    int rc;
    int saved_errno;
    if (child->fd_attempted[index] && child->fd_result[index].tag == RETURNED &&
            child->fd_result[index].rc == 0) {
        Py_RETURN_NONE;
    }
    if (child->state == CHILD_EMPTY || child->state == CHILD_COMPLETE ||
            child->fd_attempted[index]) {
        PyErr_SetString(PyExc_RuntimeError, "child pipe close is unavailable");
        return NULL;
    }
    child->fd_attempted[index] = 1;
    if (!child->fd_owned[index]) {
        record_result(&child->fd_result[index], 0, 0);
        child_refresh_complete(child);
        Py_RETURN_NONE;
    }
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 32 && index == 1) {
        rc = -1;
        errno = EIO;
    }
    else
#endif
    rc = close(child->fds[index]);
    saved_errno = rc < 0 ? errno : 0;
    record_result(&child->fd_result[index], rc, saved_errno);
    if (rc == 0) child->fd_owned[index] = 0;
    else child_remember_error(child, failure);
    child_refresh_complete(child);
    Py_RETURN_NONE;
}

static PyObject *state_close_child_stdin(NativeState *state, PyObject *Py_UNUSED(ignored))
{ return close_child_parent_fd(state, 1, FAILURE_CHILD_STDIN_CLOSE); }
static PyObject *state_close_child_stdout(NativeState *state, PyObject *Py_UNUSED(ignored))
{ return close_child_parent_fd(state, 2, FAILURE_CHILD_STDOUT_CLOSE); }
static PyObject *state_close_child_stderr(NativeState *state, PyObject *Py_UNUSED(ignored))
{ return close_child_parent_fd(state, 4, FAILURE_CHILD_STDERR_CLOSE); }

static PyObject *
state_observe_child_exit(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    child_record *child = &state->child;
    siginfo_t info;
    int rc;
    int saved_errno;
    if (child->state != CHILD_OWNED || child->leader_reaped ||
            (child->observe.tag == RETURNED &&
             (child->observe.rc != 0 || child->exit_observed))) {
        PyErr_SetString(PyExc_RuntimeError, "child exit observation is unavailable");
        return NULL;
    }
    memset(&info, 0, sizeof(info));
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 31) {
        rc = -1;
        errno = EIO;
    }
    else
#endif
    rc = waitid(P_PID, (id_t)child->pid, &info, WEXITED | WNOHANG | WNOWAIT);
    saved_errno = rc < 0 ? errno : 0;
    record_result(&child->observe, rc, saved_errno);
    child->observed_info = info;
    if (rc < 0) child_remember_error(child, FAILURE_CHILD_OBSERVE);
    else if (info.si_pid == child->pid) child->exit_observed = 1;
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 29 && rc == 0) {
        PyErr_SetString(PyExc_RuntimeError, "simulated lost observe return");
        return NULL;
    }
#endif
    Py_RETURN_NONE;
}

static PyObject *
signal_child_group(NativeState *state, int sent, result_cell *cell,
    enum failure_slot failure, int *required)
{
    child_record *child = &state->child;
    int rc;
    int saved_errno;
    if (child->state != CHILD_OWNED || child->leader_reaped || cell->tag == RETURNED ||
            child->pgid <= 0) {
        PyErr_SetString(PyExc_RuntimeError, "child group signal is unavailable");
        return NULL;
    }
    *required = 1;
    if (sent == SIGTERM) child->kill_required = 1;
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 33 && sent == SIGKILL && child->exit_observed) {
        rc = -1;
        errno = ESRCH;
    }
    else
#endif
    rc = kill(-child->pgid, sent);
    saved_errno = rc < 0 ? errno : 0;
    record_result(cell, rc, saved_errno);
    if (rc < 0 && saved_errno != ESRCH) child_remember_error(child, failure);
    Py_RETURN_NONE;
}

static PyObject *state_term_child_group(NativeState *state, PyObject *Py_UNUSED(ignored))
{ return signal_child_group(state, SIGTERM, &state->child.term,
    FAILURE_CHILD_TERM, &state->child.term_required); }
static PyObject *state_kill_child_group(NativeState *state, PyObject *Py_UNUSED(ignored))
{ return signal_child_group(state, SIGKILL, &state->child.kill,
    FAILURE_CHILD_KILL, &state->child.kill_required); }

static PyObject *
state_check_child_group(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    child_record *child = &state->child;
    int rc;
    int saved_errno;
    if ((child->state != CHILD_OWNED && child->state != CHILD_COMPLETE) ||
            (child->group.tag == RETURNED &&
             (child->group.rc != 0 || child->group_absent)) || child->pgid <= 0) {
        PyErr_SetString(PyExc_RuntimeError, "child group check is unavailable");
        return NULL;
    }
    rc = kill(-child->pgid, 0);
    saved_errno = rc < 0 ? errno : 0;
    record_result(&child->group, rc, saved_errno);
    if (rc < 0 && saved_errno == ESRCH) child->group_absent = 1;
    else if (rc < 0)
        child_remember_error(child, FAILURE_CHILD_GROUP);
    child_refresh_complete(child);
    Py_RETURN_NONE;
}

static PyObject *
state_reap_child(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    child_record *child = &state->child;
    siginfo_t info;
    int rc;
    int saved_errno;
    if (child->state != CHILD_OWNED || child->leader_reaped ||
            child->reap.tag == RETURNED || !child->exit_observed ||
            (child->term_required && child->term.tag != RETURNED) ||
            (child->kill_required && (child->kill.tag != RETURNED ||
             (child->kill.rc != 0 && child->kill.error_number != ESRCH)))) {
        PyErr_SetString(PyExc_RuntimeError, "child reap is unavailable");
        return NULL;
    }
    memset(&info, 0, sizeof(info));
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 34) {
        static int test_reap_calls;
        test_reap_calls++;
        rc = -1;
        errno = test_reap_calls == 1 ? EIO : EALREADY;
    }
    else
#endif
    rc = waitid(P_PID, (id_t)child->pid, &info, WEXITED);
    saved_errno = rc < 0 ? errno : 0;
    record_result(&child->reap, rc, saved_errno);
    child->reaped_info = info;
    if (rc == 0 && info.si_pid == child->pid) child->leader_reaped = 1;
    else child_remember_error(child, FAILURE_CHILD_REAP);
    child_refresh_complete(child);
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 30 && rc == 0 && child->leader_reaped) {
        PyErr_SetString(PyExc_RuntimeError, "simulated lost reap return");
        return NULL;
    }
#endif
    Py_RETURN_NONE;
}

static PyObject *
state_child_status(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    child_record *child = &state->child;
    return Py_BuildValue("(iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii)",
        child->state, child->pid, child->pgid, child->spawn.tag, child->spawn.rc,
        child->spawn.error_number, child->observe.tag, child->observe.rc,
        child->observe.error_number, child->observed_info.si_code,
        child->observed_info.si_status, child->exit_observed, child->reap.tag,
        child->reap.rc, child->reap.error_number, child->reaped_info.si_code,
        child->reaped_info.si_status, child->leader_reaped, child->group_absent,
        child->pipes_complete, child->term.tag, child->kill.tag, child->group.tag,
        child->first_error, child->state == CHILD_COMPLETE,
        child->fd_result[0].tag, child->fd_result[0].rc, child->fd_result[0].error_number,
        child->fd_result[1].tag, child->fd_result[1].rc, child->fd_result[1].error_number,
        child->fd_result[2].tag, child->fd_result[2].rc, child->fd_result[2].error_number,
        child->fd_result[3].tag, child->fd_result[3].rc, child->fd_result[3].error_number,
        child->fd_result[4].tag, child->fd_result[4].rc, child->fd_result[4].error_number,
        child->fd_result[5].tag, child->fd_result[5].rc, child->fd_result[5].error_number,
        child->term.rc, child->term.error_number, child->kill.rc,
        child->kill.error_number, child->group.rc, child->group.error_number);
}

static void
watched_handler(int sent)
{
    NativeState *state = active_state;
    int saved_errno = errno;
    unsigned char value = 1;
    (void)sent;
    if (state != NULL) {
        state->cancelled = 1;
        if (state->signal_pipe[1] >= 0) {
            ssize_t write_result = write(state->signal_pipe[1], &value, 1);
            (void)write_result;
        }
    }
    errno = saved_errno;
}

static void
rollback_marker(NativeState *state)
{
    int rc;
    int saved_errno;
    if (state->rollback_attempted || !state->marker_created || state->completion_fd < 0 ||
            !state->completion_identity_valid) return;
    state->rollback_attempted = 1;
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 9) { errno = EIO; rc = -1; }
    else
#endif
    rc = unlinkat(state->completion_fd, "bundle.json", 0);
    saved_errno = rc < 0 ? errno : 0;
    record_result(&state->rollback_unlink, rc, saved_errno);
    if (rc < 0) remember_failure(state, FAILURE_ROLLBACK_UNLINK);
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 10) { errno = EIO; rc = -1; }
    else
#endif
    rc = fsync(state->completion_fd);
    saved_errno = rc < 0 ? errno : 0;
    record_result(&state->rollback_fsync, rc, saved_errno);
    if (rc < 0) remember_failure(state, FAILURE_ROLLBACK_FSYNC);
}

static void
close_marker(NativeState *state)
{
    int rc;
    int saved_errno;
    if (!state->marker_owned) return;
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 42) { errno = EIO; rc = -1; }
    else
#endif
    rc = close(state->marker_fd);
    saved_errno = rc < 0 ? errno : 0;
    record_result(&state->marker_close, rc, saved_errno);
    state->marker_owned = 0;
    state->marker_fd = -1;
    if (rc < 0) remember_failure(state, FAILURE_MARKER_CLOSE);
}

static void
release_native(NativeState *state)
{
    size_t index;
    int rc;
    int saved_errno;
    int actions_restored = 1;
    int conditional_rc;
    struct stat value;
    state->phase = PHASE_RELEASE_RUNNING;
    if (state->child.state == CHILD_PREPARED || state->child.state == CHILD_NO_CHILD) {
        child_release_prepared(&state->child);
        Py_CLEAR(state->child.fd_tuple);
    }
    if (state->decision == DECISION_ABORT || state->first_failure != FAILURE_NONE) rollback_marker(state);
    for (index = WATCHED_COUNT; index > 0; index--) {
        size_t item = index - 1;
        if (!state->action_installed[item] || state->action_restore_attempted[item]) continue;
        state->action_restore_attempted[item] = 1;
#if YSTACK_CANCEL_RELEASE_TESTING
        if (YSTACK_CANCEL_TEST_CASE == 45 + (int)item) { errno = EIO; rc = -1; }
        else
#endif
        rc = sigaction(watched_signals[item], &state->old_actions[item], NULL);
        saved_errno = rc < 0 ? errno : 0;
        record_result(&state->action_restore[item], rc, saved_errno);
        if (rc == 0) state->action_installed[item] = 0;
        else { actions_restored = 0; remember_failure(state, FAILURE_ACTION_RESTORE); rollback_marker(state); }
    }
    for (index = 0; index < WATCHED_COUNT; index++) {
        if (state->action_installed[index]) actions_restored = 0;
    }
    if (actions_restored) {
        active_state = NULL;
        for (index = 0; index < 2; index++) {
            if (!state->pipe_owned[index]) continue;
            rc = close(state->signal_pipe[index]);
            saved_errno = rc < 0 ? errno : 0;
            record_result(&state->pipe_close[index], rc, saved_errno);
            state->pipe_owned[index] = 0;
            state->signal_pipe[index] = -1;
            if (rc < 0) { remember_failure(state, FAILURE_PIPE_CLOSE); rollback_marker(state); }
        }
    }
    if (state->entry_mask.tag == RETURNED && state->entry_mask.rc == 0) {
        rc = mask_call(4, SIG_SETMASK, &state->entry_old, NULL);
        record_result(&state->finish_mask, rc, 0);
        if (rc != 0) { remember_failure(state, FAILURE_FINISH_MASK); rollback_marker(state); }
    }
    if (state->completion_fd >= 0) {
        rc = close_call(state->completion_fd, 0);
        saved_errno = rc < 0 ? errno : 0;
        record_result(&state->close_result, rc, saved_errno);
        if (rc == 0) {
            state->completion_fd = -1;
            state->completion_identity_valid = 0;
        } else {
            remember_failure(state, FAILURE_CLOSE);
            rc = fstat_call(state->completion_fd, &value);
            saved_errno = rc < 0 ? errno : 0;
            record_result(&state->close_fstat, rc, saved_errno);
            if (rc < 0) {
                remember_failure(state, FAILURE_CLOSE_FSTAT);
                state->completion_fd = -1;
                state->completion_identity_valid = 0;
            } else if (!state->completion_identity_valid || value.st_dev != state->completion_dev ||
                    value.st_ino != state->completion_ino ||
                    (value.st_mode & S_IFMT) != state->completion_type) {
                state->completion_fd = -1;
                state->completion_identity_valid = 0;
            } else {
                rollback_marker(state);
                conditional_rc = close_call(state->completion_fd, 1);
                saved_errno = conditional_rc < 0 ? errno : 0;
                record_result(&state->conditional_close, conditional_rc, saved_errno);
                if (conditional_rc < 0) remember_failure(state, FAILURE_CONDITIONAL_CLOSE);
                state->completion_fd = -1;
                state->completion_identity_valid = 0;
            }
        }
    }
    state->phase = PHASE_SEALED;
    if (state->first_failure == FAILURE_NONE && state->decision == DECISION_COMPLETED)
        state->outcome_value = state->outcome_success;
    else
        state->outcome_value = state->outcome_failure;
}

static PyObject *
state_block_entry(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    int rc;
    if (!require_phase(state, PHASE_PREPARED)) return NULL;
    rc = mask_call(1, SIG_BLOCK, &state->watched, &state->entry_old);
    record_result(&state->entry_mask, rc, 0);
    if (rc != 0) remember_failure(state, FAILURE_ENTRY_MASK);
    else state->phase = PHASE_ENTRY_BLOCKED;
    Py_RETURN_NONE;
}

static PyObject *
state_arm_consumer(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    struct sigaction action;
    size_t index;
    int rc;
    int saved_errno;
    if (!require_phase(state, PHASE_ENTRY_BLOCKED) || state->entry_mask.rc != 0) return NULL;
    if (pipe(state->signal_pipe) < 0) {
        record_result(&state->pipe_close[0], -1, errno);
        remember_failure(state, FAILURE_ARM_PIPE);
        Py_RETURN_NONE;
    }
    state->pipe_owned[0] = state->pipe_owned[1] = 1;
    for (index = 0; index < 2; index++) {
        int flags = fcntl(state->signal_pipe[index], F_GETFL);
        if (flags < 0 || fcntl(state->signal_pipe[index], F_SETFL, flags | O_NONBLOCK) < 0 ||
                fcntl(state->signal_pipe[index], F_SETFD, FD_CLOEXEC) < 0) {
            remember_failure(state, FAILURE_ARM_FLAGS);
            Py_RETURN_NONE;
        }
    }
    memset(&action, 0, sizeof(action));
    action.sa_handler = watched_handler;
    action.sa_mask = state->watched;
    action.sa_flags = 0;
    active_state = state;
    for (index = 0; index < WATCHED_COUNT; index++) {
#if YSTACK_CANCEL_RELEASE_TESTING
        if (YSTACK_CANCEL_TEST_CASE == 36 + (int)index) { errno = EIO; rc = -1; }
        else
#endif
        rc = sigaction(watched_signals[index], &action, &state->old_actions[index]);
        saved_errno = rc < 0 ? errno : 0;
        record_result(&state->action_install[index], rc, saved_errno);
        if (rc < 0) { remember_failure(state, FAILURE_ARM_ACTION); Py_RETURN_NONE; }
        state->action_installed[index] = 1;
    }
    state->phase = PHASE_CONSUMER;
    Py_RETURN_NONE;
}

static PyObject *
checkpoint_result(NativeState *state)
{
    PyObject *value = state->checkpoint_clear;
    if (state->first_failure != FAILURE_NONE) value = state->checkpoint_failure;
    else if (state->cancelled) value = state->checkpoint_cancelled;
    Py_INCREF(value);
    return value;
}

static PyObject *
state_checkpoint(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    sigset_t pending;
    size_t index;
    int rc;
    int saved_errno;
    if (state->phase != PHASE_CONSUMER && state->phase != PHASE_FINAL_BLOCKED) {
        PyErr_SetString(PyExc_RuntimeError, "checkpoint is unavailable");
        return NULL;
    }
    if (state->checkpoint_pending.tag == RETURNED && state->checkpoint_pending.rc != 0)
        return checkpoint_result(state);
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 39) { errno = EIO; rc = -1; }
    else
#endif
    rc = sigpending(&pending);
    saved_errno = rc < 0 ? errno : 0;
    record_result(&state->checkpoint_pending, rc, saved_errno);
    if (rc < 0) { remember_failure(state, FAILURE_CHECKPOINT_PENDING); return checkpoint_result(state); }
    for (index = 0; index < WATCHED_COUNT; index++) {
#if YSTACK_CANCEL_RELEASE_TESTING
        if (YSTACK_CANCEL_TEST_CASE == 40 && index == 1) rc = -1;
        else
#endif
        rc = sigismember(&pending, watched_signals[index]);
        record_result(&state->checkpoint_member[index], rc, rc < 0 ? errno : 0);
        if (rc < 0) { remember_failure(state, FAILURE_CHECKPOINT_MEMBER); break; }
        if (rc == 1) state->cancelled = 1;
    }
    return checkpoint_result(state);
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
        if (!PyErr_Occurred()) PyErr_SetString(PyExc_TypeError, "hold_completion requires one owned directory fd");
        return NULL;
    }
    borrowed = PyLong_AsLong(argument);
    if (borrowed < 0 || borrowed > INT32_MAX || PyErr_Occurred()) return NULL;
    owned = duplicate_call((int)borrowed);
#ifndef F_DUPFD_CLOEXEC
    if (owned >= 0 && fcntl(owned, F_SETFD, FD_CLOEXEC) < 0) {
        saved_errno = errno; (void)close(owned); errno = saved_errno; owned = -1;
    }
#endif
    saved_errno = owned < 0 ? errno : 0;
    record_result(&state->hold_dup, owned < 0 ? -1 : 0, saved_errno);
    if (owned < 0) { remember_failure(state, FAILURE_HOLD_DUP); Py_RETURN_NONE; }
    state->completion_fd = owned;
    if (hold_fstat_call(owned, &value) < 0) {
        record_result(&state->hold_fstat, -1, errno);
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
    if (!require_phase(state, PHASE_CONSUMER) || state->completion_fd < 0 ||
            !state->completion_identity_valid) {
        if (!PyErr_Occurred()) PyErr_SetString(PyExc_RuntimeError, "completion ownership is unavailable");
        return NULL;
    }
    rc = mask_call(2, SIG_BLOCK, &state->watched, NULL);
    record_result(&state->final_mask, rc, 0);
    if (rc != 0) remember_failure(state, FAILURE_FINAL_MASK);
    else state->phase = PHASE_FINAL_BLOCKED;
    Py_RETURN_NONE;
}

static PyObject *
state_rollback_marker(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    if (state->phase == PHASE_SEALED) {
        PyErr_SetString(PyExc_RuntimeError, "native state is sealed");
        return NULL;
    }
    rollback_marker(state);
    Py_RETURN_NONE;
}

static PyObject *
state_abort_release(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    if (state->phase == PHASE_SEALED) {
        Py_INCREF(state->outcome_value);
        return state->outcome_value;
    }
    state->decision = DECISION_ABORT;
    release_native(state);
    Py_INCREF(state->outcome_value);
    return state->outcome_value;
}

static PyObject *
state_commit_completion(NativeState *state, PyObject *argument)
{
    sigset_t pending;
    unsigned char observed;
    ssize_t amount;
    size_t index;
    int rc;
    int saved_errno;
    if (!require_phase(state, PHASE_FINAL_BLOCKED) || state->first_failure != FAILURE_NONE ||
            state->decision != DECISION_UNDECIDED || !PyBytes_CheckExact(argument)) {
        if (!PyErr_Occurred()) PyErr_SetString(PyExc_RuntimeError, "completion commit is unavailable");
        return NULL;
    }
    state->payload_length = PyBytes_GET_SIZE(argument);
    if (state->payload_length <= 0 || state->payload_length > PAYLOAD_LIMIT) {
        PyErr_SetString(PyExc_ValueError, "completion payload is outside the fixed bound");
        return NULL;
    }
    state->payload = argument;
    Py_INCREF(argument);
    state->payload_bytes = PyBytes_AS_STRING(argument);
    state->phase = PHASE_COMMIT_RUNNING;
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 41) { errno = EIO; state->marker_fd = -1; }
    else
#endif
    state->marker_fd = openat(state->completion_fd, "bundle.json",
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    saved_errno = state->marker_fd < 0 ? errno : 0;
    record_result(&state->marker_open, state->marker_fd < 0 ? -1 : 0, saved_errno);
    if (state->marker_fd < 0) remember_failure(state, FAILURE_MARKER_OPEN);
    else { state->marker_owned = 1; state->marker_created = 1; }
    if (state->first_failure == FAILURE_NONE) {
#if YSTACK_CANCEL_RELEASE_TESTING
        if (YSTACK_CANCEL_TEST_CASE == 43) amount = state->payload_length - 1;
        else if (YSTACK_CANCEL_TEST_CASE == 44) { errno = EINTR; amount = -1; }
        else
#endif
        amount = write(state->marker_fd, state->payload_bytes, (size_t)state->payload_length);
        saved_errno = amount < 0 ? errno : 0;
        state->marker_write.tag = RETURNED;
        state->marker_write.rc = amount == state->payload_length ? 0 : -1;
        state->marker_write.error_number = saved_errno;
        if (amount != state->payload_length) remember_failure(state, FAILURE_MARKER_WRITE);
    }
    if (state->first_failure == FAILURE_NONE) {
        rc = fsync(state->marker_fd);
        saved_errno = rc < 0 ? errno : 0;
        record_result(&state->marker_fsync, rc, saved_errno);
        if (rc < 0) remember_failure(state, FAILURE_MARKER_FSYNC);
    }
    close_marker(state);
    if (state->first_failure == FAILURE_NONE) {
        rc = fsync(state->completion_fd);
        saved_errno = rc < 0 ? errno : 0;
        record_result(&state->directory_fsync, rc, saved_errno);
        if (rc < 0) remember_failure(state, FAILURE_DIRECTORY_FSYNC);
    }
    if (state->first_failure == FAILURE_NONE) {
        amount = read(state->signal_pipe[0], &observed, 1);
        saved_errno = amount < 0 ? errno : 0;
        state->pipe_observe.tag = RETURNED;
        state->pipe_observe.rc = (int)amount;
        state->pipe_observe.error_number = saved_errno;
        if (!(amount < 0 && (saved_errno == EAGAIN || saved_errno == EWOULDBLOCK)))
            remember_failure(state, FAILURE_PIPE_OBSERVE);
    }
    if (state->first_failure == FAILURE_NONE && state->cancelled)
        remember_failure(state, FAILURE_PIPE_OBSERVE);
    if (state->first_failure == FAILURE_NONE) {
        rc = sigpending(&pending);
        saved_errno = rc < 0 ? errno : 0;
        record_result(&state->final_pending, rc, saved_errno);
        if (rc < 0) remember_failure(state, FAILURE_FINAL_PENDING);
        else for (index = 0; index < WATCHED_COUNT; index++) {
            rc = sigismember(&pending, watched_signals[index]);
            record_result(&state->final_member[index], rc, rc < 0 ? errno : 0);
            if (rc < 0) { remember_failure(state, FAILURE_FINAL_MEMBER); break; }
            if (rc == 1) { state->cancelled = 1; remember_failure(state, FAILURE_FINAL_MEMBER); break; }
        }
    }
    if (state->first_failure == FAILURE_NONE) state->decision = DECISION_COMPLETED;
    else state->decision = DECISION_ABORT;
    release_native(state);
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
    {"arm_consumer", (PyCFunction)state_arm_consumer, METH_NOARGS, NULL},
    {"checkpoint", (PyCFunction)state_checkpoint, METH_NOARGS, NULL},
    {"hold_completion", (PyCFunction)state_hold_completion, METH_O, NULL},
    {"block_final", (PyCFunction)state_block_final, METH_NOARGS, NULL},
    {"rollback_marker", (PyCFunction)state_rollback_marker, METH_NOARGS, NULL},
    {"commit_completion", (PyCFunction)state_commit_completion, METH_O, NULL},
    {"abort_release", (PyCFunction)state_abort_release, METH_NOARGS, NULL},
    {"outcome", (PyCFunction)state_outcome, METH_NOARGS, NULL},
    {"prepare_child", (PyCFunction)state_prepare_child, METH_O, NULL},
    {"spawn_child", (PyCFunction)state_spawn_child, METH_NOARGS, NULL},
    {"child_fds", (PyCFunction)state_child_fds, METH_NOARGS, NULL},
    {"close_child_stdin", (PyCFunction)state_close_child_stdin, METH_NOARGS, NULL},
    {"close_child_stdout", (PyCFunction)state_close_child_stdout, METH_NOARGS, NULL},
    {"close_child_stderr", (PyCFunction)state_close_child_stderr, METH_NOARGS, NULL},
    {"observe_child_exit", (PyCFunction)state_observe_child_exit, METH_NOARGS, NULL},
    {"reap_child", (PyCFunction)state_reap_child, METH_NOARGS, NULL},
    {"term_child_group", (PyCFunction)state_term_child_group, METH_NOARGS, NULL},
    {"kill_child_group", (PyCFunction)state_kill_child_group, METH_NOARGS, NULL},
    {"check_child_group", (PyCFunction)state_check_child_group, METH_NOARGS, NULL},
    {"child_status", (PyCFunction)state_child_status, METH_NOARGS, NULL},
    {NULL, NULL, 0, NULL}
};

static PyObject *
prepare_state(PyObject *module, PyObject *Py_UNUSED(ignored))
{
    NativeState *state;
    size_t index;
    static const char *names[] = {
        "block_entry", "arm_consumer", "checkpoint", "hold_completion", "block_final",
        "rollback_marker", "commit_completion", "abort_release", "outcome", "prepare_child",
        "spawn_child", "child_fds", "close_child_stdin", "close_child_stdout",
        "close_child_stderr", "observe_child_exit", "reap_child", "term_child_group",
        "kill_child_group", "check_child_group", "child_status"
    };
    if (active_state != NULL) {
        PyErr_SetString(PyExc_RuntimeError, "native cancellation owner already exists");
        return NULL;
    }
    state = PyObject_New(NativeState, &NativeStateType);
    if (state == NULL) return NULL;
    memset(((char *)state) + sizeof(PyObject), 0, sizeof(*state) - sizeof(PyObject));
    state->phase = PHASE_PREPARED;
    state->completion_fd = -1;
    state->marker_fd = -1;
    state->signal_pipe[0] = state->signal_pipe[1] = -1;
    state->child.state = CHILD_EMPTY;
    for (index = 0; index < 6; index++) state->child.fds[index] = -1;
    if (sigemptyset(&state->watched) != 0 || sigaddset(&state->watched, SIGHUP) != 0 ||
            sigaddset(&state->watched, SIGINT) != 0 || sigaddset(&state->watched, SIGTERM) != 0) {
        Py_DECREF(state);
        return PyErr_SetFromErrno(PyExc_OSError);
    }
    state->checkpoint_clear = PyUnicode_InternFromString("native-checkpoint.clear");
    state->checkpoint_cancelled = PyUnicode_InternFromString("native-checkpoint.cancelled");
    state->checkpoint_failure = PyUnicode_InternFromString("native-checkpoint.failure");
    state->outcome_pending = PyUnicode_InternFromString("native-release.pending");
    state->outcome_success = PyUnicode_InternFromString("native-release.success");
    state->outcome_failure = PyUnicode_InternFromString("native-release.failure");
    if (state->checkpoint_clear == NULL || state->checkpoint_cancelled == NULL ||
            state->checkpoint_failure == NULL || state->outcome_pending == NULL ||
            state->outcome_success == NULL || state->outcome_failure == NULL) {
        Py_DECREF(state);
        return NULL;
    }
    state->outcome_value = state->outcome_pending;
    state->module_ref = module;
    Py_INCREF(module);
    for (index = 0; index < sizeof(names) / sizeof(names[0]); index++) {
        state->method_refs[index] = PyObject_GetAttrString((PyObject *)state, names[index]);
        if (state->method_refs[index] == NULL) { Py_DECREF(state); return NULL; }
    }
    return (PyObject *)state;
}

static PyMethodDef module_methods[] = {
    {"prepare_state", prepare_state, METH_NOARGS, NULL},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef module_definition = {
    PyModuleDef_HEAD_INIT,
    .m_name = "_cancel_release",
    .m_size = -1,
    .m_methods = module_methods
};

PyMODINIT_FUNC
PyInit__cancel_release(void)
{
    PyObject *module;
    if (PyType_Ready(&NativeStateType) < 0) return NULL;
    module = PyModule_Create(&module_definition);
    if (module == NULL) return NULL;
    return module;
}
