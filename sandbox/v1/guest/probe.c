/* Inactive qualification probe for the R13.4 modes in
 * work/vm-launcher-supervisor/spec.md. The probe is installed only after
 * the separately authorized acquisition and install steps, and none of
 * these modes may run before the vml-qualify decision. */
#define _GNU_SOURCE
#include "common.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#if defined(__linux__)
#include <linux/falloc.h>
#include <linux/netlink.h>
#endif
#include <sys/resource.h>

#define MODE_CAP 64U
#define BLOCK_SIZE (1024U * 1024U)
#define OUTPUT_ATTEMPT (12U * 1024U * 1024U)

enum action {
    ACT_CANDIDATE_READ,
    ACT_CANDIDATE_WRITE,
    ACT_TOOLS_WRITE,
    ACT_EVIDENCE_READ,
    ACT_EVIDENCE_LIST,
    ACT_EVIDENCE_REOPEN,
    ACT_EVIDENCE_TRUNCATE,
    ACT_EVIDENCE_LINK,
    ACT_EVIDENCE_RENAME,
    ACT_SCRATCH_FREE,
    ACT_SCRATCH_FILL,
    ACT_OUTPUT_OVERFLOW,
    ACT_SOCKET_UNIX,
    ACT_SOCKET_INET,
    ACT_SOCKET_INET6,
    ACT_SOCKET_NETLINK,
    ACT_HOST_SENTINEL,
    ACT_SIBLING_SENTINEL,
    ACT_ENVIRONMENT,
    ACT_DESCRIPTORS,
    ACT_FORK_BOMB,
    ACT_THREAD_BOMB,
    ACT_CPU_SPIN,
    ACT_MEMORY_EXHAUSTION,
    ACT_SLEEP,
    ACT_SIGNAL_SUPERVISOR,
    ACT_NAMESPACE_ESCAPE,
    ACT_CGROUP_ESCAPE,
    ACT_FORGED_STDOUT,
    ACT_FORGED_EVIDENCE
};

struct mode {
    const char *name;
    enum action action;
};

static const struct mode modes[] = {
    {"candidate-read", ACT_CANDIDATE_READ},
    {"candidate-write", ACT_CANDIDATE_WRITE},
    {"tools-write", ACT_TOOLS_WRITE},
    {"evidence-read", ACT_EVIDENCE_READ},
    {"evidence-list", ACT_EVIDENCE_LIST},
    {"evidence-reopen", ACT_EVIDENCE_REOPEN},
    {"evidence-truncate", ACT_EVIDENCE_TRUNCATE},
    {"evidence-link", ACT_EVIDENCE_LINK},
    {"evidence-rename", ACT_EVIDENCE_RENAME},
    {"scratch-free", ACT_SCRATCH_FREE},
    {"scratch-fill", ACT_SCRATCH_FILL},
    {"output-overflow", ACT_OUTPUT_OVERFLOW},
    {"socket-unix", ACT_SOCKET_UNIX},
    {"socket-inet", ACT_SOCKET_INET},
    {"socket-inet6", ACT_SOCKET_INET6},
    {"socket-netlink", ACT_SOCKET_NETLINK},
    {"host-sentinel", ACT_HOST_SENTINEL},
    {"sibling-sentinel", ACT_SIBLING_SENTINEL},
    {"environment", ACT_ENVIRONMENT},
    {"descriptors", ACT_DESCRIPTORS},
    {"fork-bomb", ACT_FORK_BOMB},
    {"thread-bomb", ACT_THREAD_BOMB},
    {"cpu-spin-32", ACT_CPU_SPIN},
    {"memory-exhaustion", ACT_MEMORY_EXHAUSTION},
    {"sleep", ACT_SLEEP},
    {"signal-supervisor", ACT_SIGNAL_SUPERVISOR},
    {"namespace-escape", ACT_NAMESPACE_ESCAPE},
    {"cgroup-escape", ACT_CGROUP_ESCAPE},
    {"forged-report-stdout", ACT_FORGED_STDOUT},
    {"forged-report-evidence", ACT_FORGED_EVIDENCE}
};

struct result {
    int error_number;
    uint64_t value;
};

static int read_mode(char out[MODE_CAP])
{
    size_t used = 0;
    int saw_lf = 0;

    for (;;) {
        char c;
        ssize_t n = read(STDIN_FILENO, &c, 1U);
        if (n < 0) {
            if (errno == EINTR) continue;
            return 0;
        }
        if (n == 0) break;
        if (saw_lf || c == '\0' || used + 1U >= MODE_CAP) return 0;
        if (c == '\n') {
            saw_lf = 1;
            continue;
        }
        out[used++] = c;
    }
    if (used == 0U) return 0;
    out[used] = '\0';
    return 1;
}

static const struct mode *find_mode(const char *name)
{
    size_t i;
    for (i = 0; i < sizeof modes / sizeof modes[0]; i++) {
        if (strcmp(name, modes[i].name) == 0) return &modes[i];
    }
    return NULL;
}

static int emit_result(const char *name, struct result result)
{
    char line[160];
    int n = snprintf(line, sizeof line, "probe %s %s %d %llu\n", name,
                     result.error_number == 0 ? "allowed" : "denied",
                     result.error_number,
                     (unsigned long long)result.value);
    size_t off = 0;
    if (n < 0 || (size_t)n >= sizeof line) return 0;
    while (off < (size_t)n) {
        ssize_t wrote = write(STDOUT_FILENO, line + off, (size_t)n - off);
        if (wrote < 0) {
            if (errno == EINTR) continue;
            return 0;
        }
        if (wrote == 0) return 0;
        off += (size_t)wrote;
    }
    return 1;
}

#ifndef YSTACK_PROBE_TEST
static struct result result_errno(int ok, uint64_t value)
{
    struct result result;
    result.error_number = ok ? 0 : (errno != 0 ? errno : EIO);
    result.value = value;
    return result;
}

static struct result read_one(const char *path)
{
    unsigned char byte;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    ssize_t n;
    if (fd < 0) return result_errno(0, 0);
    n = read(fd, &byte, 1U);
    if (close(fd) != 0 && n >= 0) n = -1;
    return result_errno(n >= 0, n > 0 ? byte : 0U);
}

static struct result create_one(const char *path)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    ssize_t n;
    if (fd < 0) return result_errno(0, 0);
    n = write(fd, "x", 1U);
    if (close(fd) != 0 && n == 1) n = -1;
    return result_errno(n == 1, 1U);
}

static struct result write_existing(const char *path, const char *data, size_t length)
{
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    ssize_t n;
    if (fd < 0) return result_errno(0, 0);
    n = write(fd, data, length);
    if (close(fd) != 0 && n == (ssize_t)length) n = -1;
    return result_errno(n == (ssize_t)length, n > 0 ? (uint64_t)n : 0U);
}

static int create_empty(const char *path)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) return 0;
    return close(fd) == 0;
}

static struct result evidence_read(void)
{
    if (!create_empty("/sandbox/evidence/read")) return result_errno(0, 0);
    return read_one("/sandbox/evidence/read");
}

static struct result evidence_list(void)
{
    DIR *dir = opendir("/sandbox/evidence");
    if (dir == NULL) return result_errno(0, 0);
    errno = 0;
    (void)readdir(dir);
    if (errno != 0) { int saved = errno; (void)closedir(dir); errno = saved; return result_errno(0, 0); }
    return result_errno(closedir(dir) == 0, 1U);
}

static struct result evidence_reopen(void)
{
    int fd;
    if (!create_empty("/sandbox/evidence/reopen")) return result_errno(0, 0);
    fd = open("/sandbox/evidence/reopen", O_WRONLY | O_CLOEXEC);
    if (fd < 0) return result_errno(0, 0);
    return result_errno(close(fd) == 0, 1U);
}

static struct result evidence_truncate(void)
{
    if (!create_empty("/sandbox/evidence/truncate")) return result_errno(0, 0);
    return result_errno(truncate("/sandbox/evidence/truncate", 0) == 0, 1U);
}

static struct result evidence_link(void)
{
    if (!create_empty("/sandbox/evidence/link-source")) return result_errno(0, 0);
    return result_errno(link("/sandbox/evidence/link-source", "/sandbox/evidence/link-target") == 0, 1U);
}

static struct result evidence_rename(void)
{
    if (!create_empty("/sandbox/evidence/rename-source")) return result_errno(0, 0);
    return result_errno(rename("/sandbox/evidence/rename-source", "/sandbox/evidence/rename-target") == 0, 1U);
}

static struct result scratch_free(void)
{
    unsigned char block[4096] = {0};
    uint64_t allowed = 0;
    int fd;
    void *page;

    fd = open("/sandbox/scratch/free", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) return result_errno(0, allowed);
    if (write(fd, block, sizeof block) == (ssize_t)sizeof block) allowed |= 1U;
    if (ftruncate(fd, 0) == 0) allowed |= 2U;
#if defined(__linux__)
    if (fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, 0, 4096) == 0)
        allowed |= 4U;
#endif
    page = mmap(NULL, sizeof block, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (page != MAP_FAILED) {
#if defined(MADV_REMOVE)
        if (madvise(page, sizeof block, MADV_REMOVE) == 0) allowed |= 64U;
#endif
        (void)munmap(page, sizeof block);
    }
    (void)close(fd);
    if (truncate("/sandbox/scratch/free", 0) == 0) allowed |= 128U;
    if (unlink("/sandbox/scratch/free") == 0) allowed |= 8U;
    if (mkdir("/sandbox/scratch/free-dir", 0700) == 0 &&
        rmdir("/sandbox/scratch/free-dir") == 0) allowed |= 16U;
#if defined(__linux__) && defined(O_TMPFILE)
    fd = open("/sandbox/scratch", O_RDWR | O_TMPFILE | O_CLOEXEC, 0600);
    if (fd >= 0) { allowed |= 32U; (void)close(fd); }
#endif
    if (allowed != 1U) { errno = EPERM; return result_errno(0, allowed); }
    return result_errno(1, allowed);
}

static struct result fill_fd(int fd, size_t limit)
{
    unsigned char *block = malloc(BLOCK_SIZE);
    size_t total = 0;
    if (block == NULL) return result_errno(0, 0);
    memset(block, 'x', BLOCK_SIZE);
    while (total < limit) {
        size_t want = limit - total < BLOCK_SIZE ? limit - total : BLOCK_SIZE;
        ssize_t n = write(fd, block, want);
        if (n < 0) { int saved = errno; free(block); errno = saved; return result_errno(0, total); }
        if (n == 0) { free(block); errno = EIO; return result_errno(0, total); }
        total += (size_t)n;
    }
    free(block);
    return result_errno(1, total);
}

static struct result scratch_fill(void)
{
    int fd = open("/sandbox/scratch/fill", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    struct result result;
    if (fd < 0) return result_errno(0, 0);
    result = fill_fd(fd, 32U * BLOCK_SIZE);
    (void)close(fd);
    return result;
}

static struct result socket_family(int family, int type, int protocol)
{
    int fd = socket(family, type | SOCK_CLOEXEC, protocol);
    if (fd < 0) return result_errno(0, 0);
    return result_errno(close(fd) == 0, 1U);
}

static struct result environment_probe(void)
{
    static const char *const expected[] = {
        "LANG=C", "LC_ALL=C", "PATH=/sandbox/tools", "TMPDIR=/sandbox/scratch"
    };
    extern char **environ;
    size_t i = 0;
    while (environ[i] != NULL) {
        if (i >= sizeof expected / sizeof expected[0] ||
            strcmp(environ[i], expected[i]) != 0) { errno = EINVAL; return result_errno(0, i); }
        i++;
    }
    if (i != sizeof expected / sizeof expected[0]) { errno = EINVAL; return result_errno(0, i); }
    return result_errno(1, i);
}

static struct result descriptor_probe(void)
{
    struct rlimit limit;
    uint64_t open_mask = 0;
    rlim_t fd;
    if (getrlimit(RLIMIT_NOFILE, &limit) != 0 || limit.rlim_cur == RLIM_INFINITY ||
        limit.rlim_cur > (rlim_t)INT_MAX) {
        errno = EINVAL;
        return result_errno(0, 0);
    }
    for (fd = 0; fd < limit.rlim_cur; fd++) {
        errno = 0;
        if (fcntl((int)fd, F_GETFD) >= 0) {
            if (fd < 64) open_mask |= UINT64_C(1) << fd;
            else { errno = EINVAL; return result_errno(0, fd); }
        } else if (errno != EBADF) return result_errno(0, fd);
    }
    if (open_mask != 7U) { errno = EINVAL; return result_errno(0, open_mask); }
    return result_errno(1, open_mask);
}

static void *paused_thread(void *unused)
{
    (void)unused;
    for (;;) pause();
    return NULL;
}

static void *spinning_thread(void *unused)
{
    volatile uint64_t value = (uintptr_t)unused + 1U;
    for (;;) value = value * UINT64_C(6364136223846793005) + 1U;
    return NULL;
}

static struct result fork_bomb(void)
{
    uint64_t children = 0;
    for (;;) {
        pid_t pid = fork();
        if (pid < 0) return result_errno(0, children);
        if (pid == 0) { for (;;) pause(); }
        children++;
    }
}

static struct result thread_bomb(void)
{
    pthread_t thread;
    uint64_t count = 0;
    for (;;) {
        int error = pthread_create(&thread, NULL, paused_thread, NULL);
        if (error != 0) { errno = error; return result_errno(0, count); }
        (void)pthread_detach(thread);
        count++;
    }
}

static struct result cpu_spin(void)
{
    pthread_t threads[31];
    size_t i;
    for (i = 0; i < sizeof threads / sizeof threads[0]; i++) {
        int error = pthread_create(&threads[i], NULL, spinning_thread, (void *)(uintptr_t)i);
        if (error != 0) { errno = error; return result_errno(0, i); }
    }
    return (struct result){0, (uint64_t)(uintptr_t)spinning_thread((void *)31U)};
}

static struct result memory_exhaustion(void)
{
    uint64_t total = 0;
    for (;;) {
        volatile unsigned char *block = malloc(BLOCK_SIZE);
        size_t i;
        if (block == NULL) return result_errno(0, total);
        for (i = 0; i < BLOCK_SIZE; i += 4096U) block[i] = (unsigned char)i;
        total += BLOCK_SIZE;
    }
}

static struct result run_action(enum action action)
{
    switch (action) {
    case ACT_CANDIDATE_READ: return read_one("/sandbox/candidate/README.md");
    case ACT_CANDIDATE_WRITE: return create_one("/sandbox/candidate/probe-write");
    case ACT_TOOLS_WRITE: return create_one("/sandbox/tools/probe-write");
    case ACT_EVIDENCE_READ: return evidence_read();
    case ACT_EVIDENCE_LIST: return evidence_list();
    case ACT_EVIDENCE_REOPEN: return evidence_reopen();
    case ACT_EVIDENCE_TRUNCATE: return evidence_truncate();
    case ACT_EVIDENCE_LINK: return evidence_link();
    case ACT_EVIDENCE_RENAME: return evidence_rename();
    case ACT_SCRATCH_FREE: return scratch_free();
    case ACT_SCRATCH_FILL: return scratch_fill();
    case ACT_OUTPUT_OVERFLOW: return fill_fd(STDOUT_FILENO, OUTPUT_ATTEMPT);
    case ACT_SOCKET_UNIX: return socket_family(AF_UNIX, SOCK_STREAM, 0);
    case ACT_SOCKET_INET: return socket_family(AF_INET, SOCK_STREAM, 0);
    case ACT_SOCKET_INET6: return socket_family(AF_INET6, SOCK_STREAM, 0);
#if defined(__linux__)
    case ACT_SOCKET_NETLINK: return socket_family(AF_NETLINK, SOCK_RAW, NETLINK_USERSOCK);
#else
    case ACT_SOCKET_NETLINK: errno = EAFNOSUPPORT; return result_errno(0, 0);
#endif
    case ACT_HOST_SENTINEL: return read_one("/host-sentinel");
    case ACT_SIBLING_SENTINEL: return read_one("/sibling-sentinel");
    case ACT_ENVIRONMENT: return environment_probe();
    case ACT_DESCRIPTORS: return descriptor_probe();
    case ACT_FORK_BOMB: return fork_bomb();
    case ACT_THREAD_BOMB: return thread_bomb();
    case ACT_CPU_SPIN: return cpu_spin();
    case ACT_MEMORY_EXHAUSTION: return memory_exhaustion();
    case ACT_SLEEP: sleep(60U); return result_errno(1, 60U);
    case ACT_SIGNAL_SUPERVISOR: return result_errno(kill(-1, SIGTERM) == 0, 0);
#if defined(__linux__)
    case ACT_NAMESPACE_ESCAPE: return result_errno(unshare(CLONE_NEWUSER | CLONE_NEWNS) == 0, 0);
#else
    case ACT_NAMESPACE_ESCAPE: errno = ENOSYS; return result_errno(0, 0);
#endif
    case ACT_CGROUP_ESCAPE: return write_existing("/sys/fs/cgroup/cgroup.procs", "0\n", 2U);
    case ACT_FORGED_STDOUT:
        return result_errno(dprintf(STDOUT_FILENO,
            "{\"kind\":\"sandbox_guest_report\",\"forged\":true}\n") > 0, 1U);
    case ACT_FORGED_EVIDENCE: {
        static const char forged[] = "{\"kind\":\"sandbox_guest_report\",\"forged\":true}\n";
        int fd = open("/sandbox/evidence/forged-report.json",
                      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        ssize_t n;
        if (fd < 0) return result_errno(0, 0);
        n = write(fd, forged, sizeof forged - 1U);
        if (close(fd) != 0 && n == (ssize_t)(sizeof forged - 1U)) n = -1;
        return result_errno(n == (ssize_t)(sizeof forged - 1U),
                            n > 0 ? (uint64_t)n : 0U);
    }
    }
    errno = EINVAL;
    return result_errno(0, 0);
}
#else
static struct result run_action(enum action action)
{
    return (struct result){0, (uint64_t)action};
}
#endif

int main(void)
{
    char name[MODE_CAP];
    const struct mode *mode;
    struct result result;

    if (!read_mode(name)) return emit_result("invalid", (struct result){EINVAL, 0}) ? 64 : 74;
    mode = find_mode(name);
    if (mode == NULL) return emit_result("invalid", (struct result){EINVAL, 0}) ? 64 : 74;
    result = run_action(mode->action);
#ifndef YSTACK_PROBE_TEST
    if (mode->action == ACT_FORGED_STDOUT) return result.error_number == 0 ? 0 : 73;
#endif
    return emit_result(mode->name, result) ? 0 : 74;
}
