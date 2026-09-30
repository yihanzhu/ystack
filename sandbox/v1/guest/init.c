/* Guest init (PID 1), VM launcher and supervisor (ystack #463), PR 6 of 9.
 * See work/vm-launcher-supervisor/plan.md ("PR 6") and spec.md R5.5: "init
 * mounts proc, sysfs, devtmpfs and cgroup2 and execs supervisor." Nothing
 * else: no shell, no other process, no signal handling beyond the kernel's
 * own default disposition for PID 1. Inactive: nothing here runs outside a
 * guest VM this concern does not boot (R14.1). Linux-only: this is the
 * kernel's `rdinit=/init` target, never compiled or run on any other
 * platform (the plan's compile gate for this file is named Linux-only on
 * Darwin; see scripts/test/sandbox-guest.test.sh). */
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

/* One mount per line: source, target, filesystem type, flags, data. Order
 * matters only in that each target directory must already exist -- all
 * four are pre-created below, so it does not otherwise. */
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

static void die(const char *what)
{
    /* No stderr destination exists yet worth writing to (no export disk
     * has been opened, and this failure precedes the supervisor that would
     * do so) -- fprintf on the console the kernel already attached to fd 2
     * is this init's only reporting channel, exactly like any other
     * early-boot failure the kernel command line's "quiet" already
     * suppresses everything past. */
    fprintf(stderr, "init: %s failed\n", what);
    _exit(1);
}

int main(void)
{
    static const char *const DIRS[4] = { "/proc", "/sys", "/dev", "/sys/fs/cgroup" };
    size_t i;

    if (getpid() != 1) die("not running as pid 1");
    for (i = 0; i < 4; i++) {
        if (mkdir(DIRS[i], 0555) != 0 && errno != EEXIST) die("mkdir");
        if (mount(MOUNTS[i].source, MOUNTS[i].target, MOUNTS[i].fstype, MOUNTS[i].flags,
                   MOUNTS[i].data) != 0)
            die("mount");
    }
    /* execve, not a fork+exec: init never runs anything else, and the
     * supervisor becomes pid 1 in its place (still outside any namespace
     * of its own -- it creates one only for the verifier tree, R6.1). */
    {
        static char *const argv[] = { (char *)"/supervisor", NULL };
        static char *const envp[] = { NULL };
        execve("/supervisor", argv, envp);
    }
    die("execve /supervisor");
    return 1;
}
