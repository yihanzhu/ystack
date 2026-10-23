/* Linux rdinit for the inactive VM guest described by #463. */
#if !defined(__linux__)
#error "sandbox/v1/guest/init.c is a Linux guest init (rdinit=/init); it is never built on a non-Linux host"
#endif

#define _GNU_SOURCE /* MS_* mount flags, mount(2) itself under strict POSIX
                     * feature guards on some libcs. */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

struct init_mount {
    const char *source;
    const char *target;
    const char *fstype;
    unsigned long flags;
    const char *data;
};

static const struct init_mount MOUNTS[4] = {
    { "proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL },
    { "sysfs", "/sys", "sysfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL },
    /* devtmpfs is normally kernel-populated regardless of the mount call's
     * own flags; it is mounted here (not left implicit) so its absence is
     * an init failure, not a silent gap the supervisor would discover
     * later trying to open a device node. */
    { "devtmpfs", "/dev", "devtmpfs", MS_NOSUID, NULL },
    /* The unified (cgroup2) hierarchy: no controller is enabled here --
     * that is the supervisor's own R7.1 setup, done from a process that
     * can also read back what it wrote. */
    { "cgroup2", "/sys/fs/cgroup", "cgroup2", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL },
};

enum init_result { INIT_OK, INIT_NOT_PID1, INIT_MKDIR_FAILED, INIT_MOUNT_FAILED,
                   INIT_EXEC_FAILED };

struct init_operations {
    pid_t (*get_pid)(void);
    int (*make_dir)(const char *, mode_t);
    int (*mount_fs)(const char *, const char *, const char *, unsigned long, const void *);
    int (*exec_supervisor)(const char *, char *const[], char *const[]);
};

static enum init_result run_init(const struct init_operations *ops)
{
    static const char *const dirs[4] = { "/proc", "/sys", "/dev", "/sys/fs/cgroup" };
    static char *const argv[] = { (char *)"/supervisor", NULL };
    static char *const envp[] = { NULL };
    size_t i;
    if (ops->get_pid() != 1) return INIT_NOT_PID1;
    for (i = 0; i < 4; i++) {
        if (ops->make_dir(dirs[i], 0555) != 0 && errno != EEXIST)
            return INIT_MKDIR_FAILED;
        if (ops->mount_fs(MOUNTS[i].source, MOUNTS[i].target, MOUNTS[i].fstype,
                          MOUNTS[i].flags, MOUNTS[i].data) != 0)
            return INIT_MOUNT_FAILED;
    }
    if (ops->exec_supervisor("/supervisor", argv, envp) != 0) return INIT_EXEC_FAILED;
    return INIT_OK;
}

#ifndef YSTACK_INIT_TEST
static void die(const char *what)
{
    fprintf(stderr, "init: %s failed\n", what);
    _exit(1);
}

int main(void)
{
    static const struct init_operations ops = { getpid, mkdir, mount, execve };
    enum init_result result = run_init(&ops);
    if (result == INIT_NOT_PID1) die("not running as pid 1");
    if (result == INIT_MKDIR_FAILED) die("mkdir");
    if (result == INIT_MOUNT_FAILED) die("mount");
    if (result == INIT_EXEC_FAILED) die("execve /supervisor");
    return 1;
}
#else
static int test_step, test_fail_step;
static pid_t test_getpid(void) { return test_fail_step == 1 ? 2 : 1; }
static int test_mkdir(const char *path, mode_t mode)
{
    (void)path; (void)mode;
    test_step++;
    if (test_step == test_fail_step) { errno = EIO; return -1; }
    return 0;
}
static int test_mount(const char *source, const char *target, const char *fstype,
                      unsigned long flags, const void *data)
{
    size_t index = (size_t)((test_step - 2) / 2);
    (void)data;
    if (index >= 4U || strcmp(source, MOUNTS[index].source) != 0 ||
        strcmp(target, MOUNTS[index].target) != 0 || strcmp(fstype, MOUNTS[index].fstype) != 0 ||
        flags != MOUNTS[index].flags)
        return -1;
    test_step++;
    if (test_step == test_fail_step) { errno = EIO; return -1; }
    return 0;
}
static int test_exec(const char *path, char *const argv[], char *const envp[])
{
    test_step++;
    if (strcmp(path, "/supervisor") != 0 || strcmp(argv[0], path) != 0 || argv[1] != NULL ||
        envp[0] != NULL)
        return -1;
    if (test_step == test_fail_step) { errno = ENOENT; return -1; }
    return 0;
}
int main(void)
{
    static const struct init_operations ops = { test_getpid, test_mkdir, test_mount, test_exec };
    int failure;
    test_step = 1; test_fail_step = 0;
    if (run_init(&ops) != INIT_OK || test_step != 10) return 1;
    for (failure = 1; failure <= 10; failure++) {
        enum init_result result;
        enum init_result expected;
        test_step = 1; test_fail_step = failure;
        result = run_init(&ops);
        if (failure == 1) expected = INIT_NOT_PID1;
        else if (failure == 10) expected = INIT_EXEC_FAILED;
        else if ((failure & 1) == 0) expected = INIT_MKDIR_FAILED;
        else expected = INIT_MOUNT_FAILED;
        if (result != expected || test_step != failure) return 1;
    }
    (void)puts("production init setup order, failures and exec handoff: ok");
    return 0;
}
#endif
