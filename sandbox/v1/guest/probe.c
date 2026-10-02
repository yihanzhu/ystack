/* Inactive qualification probe for R13.4. Its output is untrusted payload. */
#define _GNU_SOURCE
#include "common.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#if defined(__linux__)
#include <linux/falloc.h>
#include <linux/netlink.h>
#include <linux/if_packet.h>
#endif

#define INPUT_CAP 9216U
#define RESULT_CAP 8192U
#define PATH_CAP 4097U
#define RECORD_CAP 32U
#define BLOCK_SIZE (1024U * 1024U)
#define OUTPUT_ATTEMPT (12U * 1024U * 1024U)
#define FD_SCAN_FIRST 3
#define FD_SCAN_LAST 1023
#define TEST_CLOEXEC 0x40000000
#if defined(YSTACK_PROBE_TEST) && defined(YSTACK_TEST_ENABLE_MADV_REMOVE) && !defined(MADV_REMOVE)
#define MADV_REMOVE 9
#endif

enum action {
    ACT_CANDIDATE_READ, ACT_CANDIDATE_WRITE, ACT_TOOLS_WRITE,
    ACT_EVIDENCE_READ, ACT_EVIDENCE_LIST, ACT_EVIDENCE_REOPEN,
    ACT_EVIDENCE_TRUNCATE, ACT_EVIDENCE_LINK, ACT_EVIDENCE_RENAME,
    ACT_SCRATCH_FREE, ACT_SCRATCH_FILL, ACT_OUTPUT_OVERFLOW,
    ACT_SOCKET_FAMILY, ACT_HOST_SENTINEL, ACT_SIBLING_SENTINEL,
    ACT_ENVIRONMENT, ACT_DESCRIPTORS, ACT_FORK_BOMB, ACT_THREAD_BOMB,
    ACT_CPU_SPIN, ACT_MEMORY_EXHAUSTION, ACT_SLEEP, ACT_SIGNAL_SUPERVISOR,
    ACT_NAMESPACE_ESCAPE, ACT_CGROUP_ESCAPE, ACT_FORGED_STDOUT,
    ACT_FORGED_EVIDENCE
};

struct mode { const char *name; enum action action; unsigned parameters; };
static const struct mode modes[] = {
    {"candidate-read", ACT_CANDIDATE_READ, 0},
    {"candidate-write", ACT_CANDIDATE_WRITE, 0}, {"tools-write", ACT_TOOLS_WRITE, 0},
    {"evidence-read", ACT_EVIDENCE_READ, 0}, {"evidence-list", ACT_EVIDENCE_LIST, 0},
    {"evidence-reopen", ACT_EVIDENCE_REOPEN, 0},
    {"evidence-truncate", ACT_EVIDENCE_TRUNCATE, 0},
    {"evidence-link", ACT_EVIDENCE_LINK, 0}, {"evidence-rename", ACT_EVIDENCE_RENAME, 0},
    {"scratch-free", ACT_SCRATCH_FREE, 0}, {"scratch-fill", ACT_SCRATCH_FILL, 0},
    {"output-overflow", ACT_OUTPUT_OVERFLOW, 0},
    {"socket-family", ACT_SOCKET_FAMILY, 1},
    {"host-sentinel", ACT_HOST_SENTINEL, 3},
    {"sibling-sentinel", ACT_SIBLING_SENTINEL, 3},
    {"environment", ACT_ENVIRONMENT, 0}, {"descriptors", ACT_DESCRIPTORS, 0},
    {"fork-bomb", ACT_FORK_BOMB, 0}, {"thread-bomb", ACT_THREAD_BOMB, 0},
    {"cpu-spin-32", ACT_CPU_SPIN, 0}, {"memory-exhaustion", ACT_MEMORY_EXHAUSTION, 0},
    {"sleep", ACT_SLEEP, 0}, {"signal-supervisor", ACT_SIGNAL_SUPERVISOR, 0},
    {"namespace-escape", ACT_NAMESPACE_ESCAPE, 0}, {"cgroup-escape", ACT_CGROUP_ESCAPE, 0},
    {"forged-report-stdout", ACT_FORGED_STDOUT, 0},
    {"forged-report-evidence", ACT_FORGED_EVIDENCE, 0}
};

/* Closed result-record meanings. The three values are numeric observations,
 * never verdicts. File operations use bytes, first byte, zero. Evidence
 * mutations use successful-operation count, zero, zero. Sentinel read uses
 * bytes read, expected size, digest-match. Descriptor fd0-fd2 records use file
 * type bits, access mode, append-present; fd-scan uses first fd, last fd and
 * failed fd or zero; fd-leaks uses observed count, first leak or zero and zero.
 * A count before a scan error is a lower bound. Socket uses family, type and protocol. Environment uses observed
 * and expected counts. Resource records use achieved bytes/workers/seconds,
 * requested target, zero. Signal uses probe pid, observed parent pid, zero.
 * Scratch records have no numeric payload. Escape and forged-evidence records
 * use transferred bytes, zero, zero. The fixed check-name inventory is:
 *
 * candidate-read                         read
 * candidate-write, tools-write           create
 * evidence-read                          read
 * evidence-list                          list
 * evidence-reopen                        reopen
 * evidence-truncate                      truncate
 * evidence-link                          link
 * evidence-rename                        rename
 * scratch-free                           ftruncate, fallocate, madv-remove,
 *                                        path-truncate, unlink, rmdir, tmpfile
 * scratch-fill                           fill
 * socket-family                          socket
 * host-sentinel, sibling-sentinel        open, read
 * environment                            environment
 * descriptors                            fd0, fd1, fd2, fd-scan, fd-leaks
 * fork-bomb                              fork
 * thread-bomb                            thread
 * cpu-spin-32                            cpu
 * memory-exhaustion                      memory
 * sleep                                  sleep
 * signal-supervisor                      relationship, supervisor-signal
 * namespace-escape                       unshare
 * cgroup-escape                          cgroup-write
 * forged-report-evidence                 forged-evidence
 *
 * output-overflow and forged-report-stdout are raw-payload modes and have no
 * result records. Every other returning mode emits exactly the static set
 * above, including failed, unavailable and unattempted subchecks. */

enum prerequisite { PRE_OK, PRE_FAILED, PRE_UNKNOWN };
enum outcome { OUT_SUCCESS, OUT_REFUSED, OUT_UNSUPPORTED, OUT_INCOMPLETE, OUT_VIOLATION };
struct record {
    const char *name;
    enum prerequisite prerequisite;
    int attempted, completed;
    enum outcome outcome;
    int error_number, cleanup_error;
    uint64_t value[3];
};
struct result {
    struct record records[RECORD_CAP];
    size_t count;
    int force_incomplete;
    const char *domain;
    unsigned domain_max;
};
struct request {
    unsigned char bytes[INPUT_CAP]; size_t length;
    const struct mode *mode; char path[PATH_CAP]; uint64_t size;
    unsigned char expected_digest[32]; unsigned family;
    char instruction_digest[65];
};

struct socket_facts {
    long domain_max;
    int linux_build, cloexec_available, cloexec;
    int netlink_available, netlink, usersock_available, usersock;
    int packet_available, packet, vsock_available, vsock;
};

static const char *const pre_names[] = {"ok", "failed", "unknown"};
static const char *const outcome_names[] = {"success", "refused", "unsupported", "incomplete", "violation"};

static void digest_hex(const void *bytes, size_t length, char out[65])
{
    static const char hex[] = "0123456789abcdef";
    unsigned char digest[32]; size_t i;
    ys_sha256_bytes(bytes, length, digest);
    for (i = 0; i < 32U; i++) { out[i * 2U] = hex[digest[i] >> 4]; out[i * 2U + 1U] = hex[digest[i] & 15U]; }
    out[64] = '\0';
}

static const struct mode *find_mode(const char *name)
{
    size_t i;
    for (i = 0; i < sizeof modes / sizeof modes[0]; i++)
        if (strcmp(name, modes[i].name) == 0) return &modes[i];
    return NULL;
}

static int canonical_uint(const char *text, uint64_t max, uint64_t *value)
{
    uint64_t n = 0; const unsigned char *p = (const unsigned char *)text;
    if (*p == '\0' || (*p == '0' && p[1] != '\0')) return 0;
    for (; *p != '\0'; p++) {
        unsigned digit;
        if (*p < '0' || *p > '9') return 0;
        digit = (unsigned)(*p - '0');
        if (n > (max - digit) / 10U) return 0;
        n = n * 10U + digit;
    }
    *value = n; return 1;
}

static int hex_value(unsigned char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static int decode_hex(const char *text, unsigned char *out, size_t cap, size_t *length)
{
    size_t n = strlen(text), i;
    if ((n & 1U) != 0U || n / 2U > cap) return 0;
    for (i = 0; i < n; i += 2U) {
        int hi = hex_value((unsigned char)text[i]), lo = hex_value((unsigned char)text[i + 1U]);
        if (hi < 0 || lo < 0) return 0;
        out[i / 2U] = (unsigned char)((hi << 4) | lo);
    }
    *length = n / 2U; return 1;
}

static int valid_absolute_path(const char *path, size_t length)
{
    size_t start = 1U, i;
    if (length == 0U || length > 4096U || path[0] != '/' || path[length] != '\0') return 0;
    for (i = 1U; i <= length; i++) {
        if (i < length && path[i] == '\0') return 0;
        if (i == length || path[i] == '/') {
            size_t n = i - start;
            if (n == 0U || (n == 1U && path[start] == '.') ||
                (n == 2U && path[start] == '.' && path[start + 1U] == '.')) return 0;
            start = i + 1U;
        }
    }
    return 1;
}

static int parse_request_bytes(const unsigned char *bytes, size_t length, struct request *request)
{
    char work[INPUT_CAP + 1U]; char *fields[6], *p; unsigned count = 0; size_t i, decoded;
    uint64_t number;
    memset(request, 0, sizeof *request);
    if (length == 0U || length > INPUT_CAP || bytes[length - 1U] != '\n') return 0;
    for (i = 0; i < length; i++)
        if (bytes[i] == 0U || bytes[i] == '\r' || (bytes[i] != '\n' && (bytes[i] < 0x20U || bytes[i] > 0x7eU)) ||
            (bytes[i] == '\n' && i != length - 1U)) return 0;
    memcpy(work, bytes, length - 1U); work[length - 1U] = '\0';
    if (work[0] == ' ' || (length > 1U && work[length - 2U] == ' ')) return 0;
    p = work;
    while (p != NULL) {
        char *space;
        if (count == sizeof fields / sizeof fields[0]) return 0;
        fields[count++] = p; space = strchr(p, ' ');
        if (space == NULL) p = NULL;
        else { if (space[1] == ' ' || space[1] == '\0') return 0; *space = '\0'; p = space + 1U; }
    }
    if (count < 2U || strcmp(fields[0], "YSPROBE1") != 0) return 0;
    request->mode = find_mode(fields[1]);
    if (request->mode == NULL || count != 2U + request->mode->parameters) return 0;
    if (request->mode->action == ACT_SOCKET_FAMILY) {
        if (!canonical_uint(fields[2], 65535U, &number)) return 0;
        request->family = (unsigned)number;
    } else if (request->mode->action == ACT_HOST_SENTINEL || request->mode->action == ACT_SIBLING_SENTINEL) {
        if (!decode_hex(fields[2], (unsigned char *)request->path, 4096U, &decoded)) return 0;
        request->path[decoded] = '\0';
        if (!valid_absolute_path(request->path, decoded) || !canonical_uint(fields[3], 4096U, &number) || number == 0U ||
            strlen(fields[4]) != 64U || !decode_hex(fields[4], request->expected_digest, 32U, &decoded) || decoded != 32U) return 0;
        request->size = number;
    }
    memcpy(request->bytes, bytes, length); request->length = length;
    digest_hex(bytes, length, request->instruction_digest);
    return 1;
}

#ifdef YSTACK_PROBE_TEST
#include <setjmp.h>

enum fixture_op {
    FX_OPEN, FX_CLOSE, FX_READ, FX_WRITE, FX_FSTAT, FX_FCNTL,
    FX_TRUNCATE, FX_FTRUNCATE, FX_FALLOCATE, FX_LINK, FX_RENAME,
    FX_MKDIR, FX_RMDIR, FX_UNLINK, FX_OPENDIR, FX_READDIR, FX_CLOSEDIR,
    FX_SOCKET, FX_GETPID, FX_GETPPID, FX_KILL, FX_UNSHARE,
    FX_MALLOC, FX_FREE, FX_MMAP, FX_MADVISE, FX_MUNMAP, FX_FORK,
    FX_PTHREAD_CREATE, FX_PTHREAD_DETACH, FX_SLEEP, FX_PAUSE, FX_LOOP
};

enum fixture_flow { FX_RETURN, FX_STOP };
enum fixture_bytes { FX_BYTES_NONE, FX_BYTES_EXACT, FX_BYTES_REPEAT };

struct fixture_step {
    enum fixture_op op;
    enum fixture_flow flow;
    long returned;
    int error_number;
    union {
        struct { const char *path; int flags; mode_t mode; } open;
        struct { int fd; } close;
        struct { int fd; size_t length; enum fixture_bytes kind; const unsigned char *bytes; unsigned char byte; } io;
        struct { int fd; mode_t mode; } fstat;
        struct { int fd; int command; } fcntl;
        struct { const char *path; off_t length; } truncate;
        struct { int fd; off_t length; } ftruncate;
        struct { int fd; int mode; off_t offset; off_t length; } fallocate;
        struct { const char *first; const char *second; } paths;
        struct { const char *path; mode_t mode; } mkdir;
        struct { const char *path; } path;
        struct { const char *path; unsigned object; } directory;
        struct { unsigned object; } object;
        struct { int family; int type; int protocol; } socket;
        struct { pid_t pid; int signal_number; } kill;
        struct { int flags; } unshare;
        struct { size_t size; unsigned object; } allocation;
        struct { void *address; size_t length; int protection; int flags; int fd; off_t offset; unsigned object; } mmap;
        struct { unsigned object; size_t length; int advice; } madvise;
        struct { unsigned object; size_t length; } munmap;
        struct { pthread_t token; const pthread_attr_t *attributes; void *(*entry)(void *); void *argument; int dispatch; } thread;
        struct { pthread_t token; } detach;
        struct { unsigned seconds; } sleep;
        struct { unsigned site; uintptr_t argument; uint64_t iteration; } loop;
    } call;
    const unsigned char *read_bytes;
    size_t read_length;
    mode_t stat_mode;
    struct dirent directory_entry;
    int directory_has_entry;
};

#define FIXTURE_STEP_CAP 4096U
#define FIXTURE_CAPTURE_CAP (RESULT_CAP * 2U)
#define FIXTURE_OBJECTS 4U
static struct fixture_step fixture_steps[FIXTURE_STEP_CAP];
static size_t fixture_step_count, fixture_step_index;
static unsigned char fixture_capture[FIXTURE_CAPTURE_CAP];
static size_t fixture_capture_length, fixture_stdout_total;
static unsigned char fixture_blocks[FIXTURE_OBJECTS][BLOCK_SIZE];
static unsigned char fixture_block_live[FIXTURE_OBJECTS];
static unsigned char fixture_mapping[4096];
static unsigned char fixture_directory_tokens[FIXTURE_OBJECTS];
static jmp_buf fixture_jump;
static int fixture_driver_active;
static int fixture_escape;
static const char *fixture_failure;
static struct socket_facts fixture_socket_override_value;
static const struct socket_facts *fixture_socket_override;

static void fixture_escape_now(int reason, const char *message)
{
    fixture_escape = reason;
    fixture_failure = message;
    if (!fixture_driver_active) abort();
    longjmp(fixture_jump, 1);
}

static void fixture_fail(const char *message) { fixture_escape_now(1, message); }
static void fixture_stop(void) { fixture_escape_now(2, NULL); }

static struct fixture_step *fixture_push(enum fixture_op op)
{
    struct fixture_step *step;
    if (fixture_step_count >= FIXTURE_STEP_CAP) fixture_fail("step capacity");
    step = &fixture_steps[fixture_step_count++];
    memset(step, 0, sizeof *step); step->op = op;
    return step;
}

static struct fixture_step *fixture_next(enum fixture_op op)
{
    struct fixture_step *step;
    if (fixture_step_index >= fixture_step_count) fixture_fail("unexpected call after script end");
    step = &fixture_steps[fixture_step_index++];
    if (step->op != op) fixture_fail("wrong call order");
    return step;
}

static long fixture_return(struct fixture_step *step)
{
    if (step->flow == FX_STOP) fixture_stop();
    if (step->returned < 0) errno = step->error_number;
    return step->returned;
}

static int fixture_open(const char *path, int flags, mode_t mode)
{
    struct fixture_step *s = fixture_next(FX_OPEN);
    if (strcmp(path, s->call.open.path) != 0 || flags != s->call.open.flags || mode != s->call.open.mode)
        fixture_fail("open arguments");
    return (int)fixture_return(s);
}

static int fixture_close(int fd)
{
    struct fixture_step *s = fixture_next(FX_CLOSE);
    if (fd != s->call.close.fd) fixture_fail("close fd");
    return (int)fixture_return(s);
}

static ssize_t fixture_read(int fd, void *buffer, size_t length)
{
    struct fixture_step *s = fixture_next(FX_READ); long returned;
    if (fd != s->call.io.fd || length != s->call.io.length) fixture_fail("read arguments");
    returned = fixture_return(s);
    if (returned > (long)length || (returned > 0 && s->read_length != (size_t)returned))
        fixture_fail("read result length");
    if (returned > 0) {
        if (s->read_bytes == NULL) fixture_fail("read bytes missing");
        memcpy(buffer, s->read_bytes, (size_t)returned);
    }
    return (ssize_t)returned;
}

static ssize_t fixture_write(int fd, const void *buffer, size_t length)
{
    struct fixture_step *s = fixture_next(FX_WRITE); long returned; size_t i;
    if (fd != s->call.io.fd || length != s->call.io.length) fixture_fail("write arguments");
    if (s->call.io.kind == FX_BYTES_NONE) fixture_fail("write expectation missing");
    if (s->call.io.kind == FX_BYTES_EXACT &&
        (s->call.io.bytes == NULL || memcmp(buffer, s->call.io.bytes, length) != 0))
        fixture_fail("write bytes");
    if (s->call.io.kind == FX_BYTES_REPEAT)
        for (i = 0; i < length; i++) if (((const unsigned char *)buffer)[i] != s->call.io.byte)
            fixture_fail("write repeated byte");
    returned = fixture_return(s);
    if (returned > (long)length) fixture_fail("write result length");
    if (fd == STDOUT_FILENO && returned > 0) {
        size_t take = (size_t)returned;
        fixture_stdout_total += take;
        if (fixture_capture_length + take <= FIXTURE_CAPTURE_CAP) {
            memcpy(fixture_capture + fixture_capture_length, buffer, take);
            fixture_capture_length += take;
        }
    }
    return (ssize_t)returned;
}

static int fixture_fstat(int fd, struct stat *metadata)
{
    struct fixture_step *s = fixture_next(FX_FSTAT); long returned;
    if (fd != s->call.fstat.fd || metadata == NULL) fixture_fail("fstat arguments");
    returned = fixture_return(s);
    if (returned == 0) { memset(metadata, 0, sizeof *metadata); metadata->st_mode = s->stat_mode; }
    return (int)returned;
}

static int fixture_fcntl(int fd, int command)
{
    struct fixture_step *s = fixture_next(FX_FCNTL);
    if (fd != s->call.fcntl.fd || command != s->call.fcntl.command) fixture_fail("fcntl arguments");
    return (int)fixture_return(s);
}

static int fixture_truncate(const char *path, off_t length)
{
    struct fixture_step *s = fixture_next(FX_TRUNCATE);
    if (strcmp(path, s->call.truncate.path) != 0 || length != s->call.truncate.length) fixture_fail("truncate arguments");
    return (int)fixture_return(s);
}

static int fixture_ftruncate(int fd, off_t length)
{
    struct fixture_step *s = fixture_next(FX_FTRUNCATE);
    if (fd != s->call.ftruncate.fd || length != s->call.ftruncate.length) fixture_fail("ftruncate arguments");
    return (int)fixture_return(s);
}

#if defined(__linux__)
static int fixture_fallocate(int fd, int mode, off_t offset, off_t length)
{
    struct fixture_step *s = fixture_next(FX_FALLOCATE);
    if (fd != s->call.fallocate.fd || mode != s->call.fallocate.mode ||
        offset != s->call.fallocate.offset || length != s->call.fallocate.length)
        fixture_fail("fallocate arguments");
    return (int)fixture_return(s);
}
#endif

static int fixture_two_paths(enum fixture_op op, const char *first, const char *second)
{
    struct fixture_step *s = fixture_next(op);
    if (strcmp(first, s->call.paths.first) != 0 || strcmp(second, s->call.paths.second) != 0)
        fixture_fail("two-path arguments");
    return (int)fixture_return(s);
}

static int fixture_link(const char *first, const char *second) { return fixture_two_paths(FX_LINK, first, second); }
static int fixture_rename(const char *first, const char *second) { return fixture_two_paths(FX_RENAME, first, second); }

static int fixture_mkdir(const char *path, mode_t mode)
{
    struct fixture_step *s = fixture_next(FX_MKDIR);
    if (strcmp(path, s->call.mkdir.path) != 0 || mode != s->call.mkdir.mode) fixture_fail("mkdir arguments");
    return (int)fixture_return(s);
}

static int fixture_one_path(enum fixture_op op, const char *path)
{
    struct fixture_step *s = fixture_next(op);
    if (strcmp(path, s->call.path.path) != 0) fixture_fail("path argument");
    return (int)fixture_return(s);
}
static int fixture_rmdir(const char *path) { return fixture_one_path(FX_RMDIR, path); }
static int fixture_unlink(const char *path) { return fixture_one_path(FX_UNLINK, path); }

static DIR *fixture_opendir(const char *path)
{
    struct fixture_step *s = fixture_next(FX_OPENDIR); long returned;
    if (strcmp(path, s->call.directory.path) != 0) fixture_fail("opendir path");
    returned = fixture_return(s);
    if (returned < 0) return NULL;
    if (s->call.directory.object >= FIXTURE_OBJECTS) fixture_fail("directory object");
    return (DIR *)(void *)&fixture_directory_tokens[s->call.directory.object];
}

static struct dirent *fixture_readdir(DIR *directory)
{
    struct fixture_step *s = fixture_next(FX_READDIR);
    if (s->call.object.object >= FIXTURE_OBJECTS ||
        directory != (DIR *)(void *)&fixture_directory_tokens[s->call.object.object])
        fixture_fail("readdir object");
    if (s->flow == FX_STOP) fixture_stop();
    if (s->returned < 0) { errno = s->error_number; return NULL; }
    if (!s->directory_has_entry) { errno = 0; return NULL; }
    return &s->directory_entry;
}

static int fixture_closedir(DIR *directory)
{
    struct fixture_step *s = fixture_next(FX_CLOSEDIR);
    if (s->call.object.object >= FIXTURE_OBJECTS ||
        directory != (DIR *)(void *)&fixture_directory_tokens[s->call.object.object])
        fixture_fail("closedir object");
    return (int)fixture_return(s);
}

static int fixture_socket(int family, int type, int protocol)
{
    struct fixture_step *s = fixture_next(FX_SOCKET);
    if (family != s->call.socket.family || type != s->call.socket.type || protocol != s->call.socket.protocol)
        fixture_fail("socket arguments");
    return (int)fixture_return(s);
}

static pid_t fixture_getpid(void) { return (pid_t)fixture_return(fixture_next(FX_GETPID)); }
static pid_t fixture_getppid(void) { return (pid_t)fixture_return(fixture_next(FX_GETPPID)); }
static int fixture_kill(pid_t pid, int signal_number)
{
    struct fixture_step *s = fixture_next(FX_KILL);
    if (pid != s->call.kill.pid || signal_number != s->call.kill.signal_number) fixture_fail("kill arguments");
    fixture_fail("kill is forbidden in probe cases"); return -1;
}

#if defined(__linux__)
static int fixture_unshare(int flags)
{
    struct fixture_step *s = fixture_next(FX_UNSHARE);
    if (flags != s->call.unshare.flags) fixture_fail("unshare flags");
    return (int)fixture_return(s);
}
#endif

static void *fixture_malloc(size_t size)
{
    struct fixture_step *s = fixture_next(FX_MALLOC); long returned;
    if (size != s->call.allocation.size) fixture_fail("malloc size");
    returned = fixture_return(s);
    if (returned < 0) return NULL;
    if (s->call.allocation.object >= FIXTURE_OBJECTS) fixture_fail("malloc object");
    if (fixture_block_live[s->call.allocation.object]) fixture_fail("duplicate live allocation");
    fixture_block_live[s->call.allocation.object] = 1;
    return fixture_blocks[s->call.allocation.object];
}

static void fixture_free(void *memory)
{
    struct fixture_step *s = fixture_next(FX_FREE);
    if (s->call.object.object >= FIXTURE_OBJECTS || memory != fixture_blocks[s->call.object.object])
        fixture_fail("free object");
    if (!fixture_block_live[s->call.object.object]) fixture_fail("invalid free");
    fixture_block_live[s->call.object.object] = 0;
    (void)fixture_return(s);
}

static void *fixture_mmap(void *address, size_t length, int protection, int flags, int fd, off_t offset)
{
    struct fixture_step *s = fixture_next(FX_MMAP); long returned;
    if (address != s->call.mmap.address || length != s->call.mmap.length || protection != s->call.mmap.protection ||
        flags != s->call.mmap.flags || fd != s->call.mmap.fd || offset != s->call.mmap.offset)
        fixture_fail("mmap arguments");
    returned = fixture_return(s);
    if (returned < 0) return MAP_FAILED;
    if (s->call.mmap.object != 0U) fixture_fail("mapping object");
    return fixture_mapping;
}

static int fixture_madvise(void *address, size_t length, int advice)
{
    struct fixture_step *s = fixture_next(FX_MADVISE);
    if (s->call.madvise.object != 0U || address != fixture_mapping || length != s->call.madvise.length ||
        advice != s->call.madvise.advice) fixture_fail("madvise arguments");
    return (int)fixture_return(s);
}

static int fixture_munmap(void *address, size_t length)
{
    struct fixture_step *s = fixture_next(FX_MUNMAP);
    if (s->call.munmap.object != 0U || address != fixture_mapping || length != s->call.munmap.length)
        fixture_fail("munmap arguments");
    return (int)fixture_return(s);
}

static pid_t fixture_fork(void) { return (pid_t)fixture_return(fixture_next(FX_FORK)); }

static int fixture_pthread_create(pthread_t *thread, const pthread_attr_t *attributes,
                                  void *(*entry)(void *), void *argument)
{
    struct fixture_step *s = fixture_next(FX_PTHREAD_CREATE); long returned;
    if (thread == NULL || attributes != s->call.thread.attributes || entry != s->call.thread.entry ||
        argument != s->call.thread.argument) fixture_fail("pthread_create arguments");
    returned = fixture_return(s);
    if (returned == 0) *thread = s->call.thread.token;
    if (returned == 0 && s->call.thread.dispatch) {
        (void)entry(argument);
        fixture_fail("worker callback returned");
    }
    return (int)returned;
}

static int fixture_pthread_detach(pthread_t thread)
{
    struct fixture_step *s = fixture_next(FX_PTHREAD_DETACH);
    if (memcmp(&thread, &s->call.detach.token, sizeof thread) != 0) fixture_fail("pthread_detach token");
    return (int)fixture_return(s);
}

static unsigned fixture_sleep(unsigned seconds)
{
    struct fixture_step *s = fixture_next(FX_SLEEP);
    if (seconds != s->call.sleep.seconds) fixture_fail("sleep seconds");
    return (unsigned)fixture_return(s);
}

static int fixture_pause(void) { return (int)fixture_return(fixture_next(FX_PAUSE)); }
static void fixture_loop(unsigned site, uintptr_t argument, uint64_t iteration)
{
    struct fixture_step *s = fixture_next(FX_LOOP);
    if (site != s->call.loop.site || argument != s->call.loop.argument || iteration != s->call.loop.iteration)
        fixture_fail("loop checkpoint");
    (void)fixture_return(s);
}

#define open(path, flags, mode) fixture_open((path), (flags), (mode))
#define close(fd) fixture_close((fd))
#define read(fd, buffer, length) fixture_read((fd), (buffer), (length))
#define write(fd, buffer, length) fixture_write((fd), (buffer), (length))
#define fstat(fd, metadata) fixture_fstat((fd), (metadata))
#define fcntl(fd, command) fixture_fcntl((fd), (command))
#define truncate(path, length) fixture_truncate((path), (length))
#define ftruncate(fd, length) fixture_ftruncate((fd), (length))
#if defined(__linux__)
#define fallocate(fd, mode, offset, length) fixture_fallocate((fd), (mode), (offset), (length))
#endif
#define link(first, second) fixture_link((first), (second))
#define rename(first, second) fixture_rename((first), (second))
#define mkdir(path, mode) fixture_mkdir((path), (mode))
#define rmdir(path) fixture_rmdir((path))
#define unlink(path) fixture_unlink((path))
#define opendir(path) fixture_opendir((path))
#define readdir(directory) fixture_readdir((directory))
#define closedir(directory) fixture_closedir((directory))
#define socket(family, type, protocol) fixture_socket((family), (type), (protocol))
#define getpid() fixture_getpid()
#define getppid() fixture_getppid()
#define kill(pid, signal_number) fixture_kill((pid), (signal_number))
#if defined(__linux__)
#define unshare(flags) fixture_unshare((flags))
#endif
#define malloc(size) fixture_malloc((size))
#define free(memory) fixture_free((memory))
#define mmap(address, length, protection, flags, fd, offset) fixture_mmap((address), (length), (protection), (flags), (fd), (offset))
#define madvise(address, length, advice) fixture_madvise((address), (length), (advice))
#define munmap(address, length) fixture_munmap((address), (length))
#define fork() fixture_fork()
#define pthread_create(thread, attributes, entry, argument) fixture_pthread_create((thread), (attributes), (entry), (argument))
#define pthread_detach(thread) fixture_pthread_detach((thread))
#define sleep(seconds) fixture_sleep((seconds))
#define pause() fixture_pause()
#define TEST_LOOP(site, argument, iteration) fixture_loop((site), (argument), (iteration))
#else
#define TEST_LOOP(site, argument, iteration) ((void)0)
#endif

static int read_request(struct request *request)
{
    unsigned char bytes[INPUT_CAP + 1U]; size_t used = 0;
    for (;;) {
        ssize_t n = read(STDIN_FILENO, bytes + used, sizeof bytes - used);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        if (n == 0) break;
        used += (size_t)n; if (used == sizeof bytes) return 0;
    }
    return parse_request_bytes(bytes, used, request) ? 1 : 0;
}

static void add_record(struct result *result, const char *name, enum prerequisite pre,
                       int attempted, int completed, enum outcome outcome, int error_number,
                       int cleanup_error, uint64_t v1, uint64_t v2, uint64_t v3)
{
    struct record *r;
    if (result->count >= RECORD_CAP) abort();
    r = &result->records[result->count++]; r->name = name; r->prerequisite = pre;
    r->attempted = attempted; r->completed = completed; r->outcome = outcome;
    r->error_number = error_number; r->cleanup_error = cleanup_error;
    r->value[0] = v1; r->value[1] = v2; r->value[2] = v3;
}

static enum outcome classify_errno(int error_number)
{
    if (error_number == EPERM || error_number == EACCES || error_number == EROFS) return OUT_REFUSED;
    if (error_number == EAFNOSUPPORT || error_number == EPROTONOSUPPORT || error_number == ESOCKTNOSUPPORT ||
        error_number == EOPNOTSUPP) return OUT_UNSUPPORTED;
    return OUT_INCOMPLETE;
}

static int result_complete(const struct result *result)
{
    size_t i;
    if (result->force_incomplete) return 0;
    for (i = 0; i < result->count; i++)
        if (result->records[i].prerequisite != PRE_OK || !result->records[i].attempted ||
            !result->records[i].completed || result->records[i].outcome == OUT_INCOMPLETE ||
            result->records[i].outcome == OUT_UNSUPPORTED ||
            result->records[i].cleanup_error != 0) return 0;
    return 1;
}

static int appendf(char *line, size_t *used, const char *format, ...)
{
    va_list args; int n;
    if (*used >= RESULT_CAP) return 0;
    va_start(args, format); n = vsnprintf(line + *used, RESULT_CAP - *used, format, args); va_end(args);
    if (n < 0 || (size_t)n >= RESULT_CAP - *used) return 0;
    *used += (size_t)n; return 1;
}

static int write_all(int fd, const void *data, size_t length)
{
    size_t off = 0;
    while (off < length) {
        ssize_t n = write(fd, (const unsigned char *)data + off, length - off);
        if (n < 0) { if (errno == EINTR) continue; return 0; }
        if (n == 0) return 0;
        off += (size_t)n;
    }
    return 1;
}

static int format_result(const struct request *request, const struct result *result,
                         char line[RESULT_CAP], size_t *line_length)
{
    size_t used = 0, i; const char *domain = "none"; char domain_buf[48];
    if (result->domain != NULL) domain = result->domain;
    else if (request->mode->action == ACT_SOCKET_FAMILY) {
        if (result->domain_max == 0U) domain = "unknown";
        else { (void)snprintf(domain_buf, sizeof domain_buf, "linux-build-af-v1/%u", result->domain_max); domain = domain_buf; }
    }
    if (!appendf(line, &used, "YSPROBE1 %s %s %s %s %zu", request->mode->name,
                 request->instruction_digest, result_complete(result) ? "complete" : "incomplete",
                 domain, result->count)) return 0;
    for (i = 0; i < result->count; i++) {
        const struct record *r = &result->records[i];
        if (!appendf(line, &used, " %s:%s:%d:%d:%s:%d:%d:%llu:%llu:%llu", r->name,
                     pre_names[r->prerequisite], r->attempted, r->completed,
                     outcome_names[r->outcome], r->error_number, r->cleanup_error,
                     (unsigned long long)r->value[0], (unsigned long long)r->value[1],
                     (unsigned long long)r->value[2])) return 0;
    }
    if (!appendf(line, &used, "\n")) return 0;
    *line_length = used; return 1;
}

static int emit_result(const struct request *request, const struct result *result)
{
    char line[RESULT_CAP]; size_t length;
    return format_result(request, result, line, &length) && write_all(STDOUT_FILENO, line, length);
}


static void file_action(struct result *result, const char *name, const char *path, int flags,
                        mode_t mode, int do_read, const void *write_data, size_t write_length,
                        int success_expected)
{
    int fd = open(path, flags, mode), primary = 0, cleanup = 0; ssize_t n = -1; unsigned char byte;
    if (fd < 0) {
        enum outcome outcome = classify_errno(errno); primary = errno;
        add_record(result, name, PRE_OK, 1, outcome == OUT_REFUSED, outcome,
                   primary, 0, 0, 0, 0); return;
    }
    if (do_read) n = read(fd, &byte, 1U);
    else if (write_data != NULL) n = write(fd, write_data, write_length);
    else n = 0;
    if (n < 0) primary = errno;
    if (close(fd) != 0) cleanup = errno;
    add_record(result, name, PRE_OK, 1,
               do_read ? (n >= 0 || primary == EPERM || primary == EACCES || primary == EROFS) :
               write_data != NULL ? (size_t)(n < 0 ? 0 : n) == write_length : 1,
               n >= 0 ? (success_expected ? OUT_SUCCESS : OUT_VIOLATION) :
               (!success_expected && write_data != NULL ? OUT_VIOLATION : classify_errno(primary)),
               primary, cleanup, n > 0 ? (uint64_t)n : 0U, n > 0 && do_read ? byte : 0U, 0);
}

static int establish_empty(const char *path, int *cleanup_error)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600); ssize_t n; int saved;
    *cleanup_error = 0; if (fd < 0) return errno;
    n = write(fd, "x", 1U); saved = n == 1 ? 0 : (errno != 0 ? errno : EIO);
    if (close(fd) != 0) *cleanup_error = errno;
    return saved;
}

static int establish_block(const char *path, int *cleanup_error)
{
    unsigned char block[4096] = {0}; size_t offset = 0; int saved = 0;
    int fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    *cleanup_error = 0; if (fd < 0) return errno;
    while (offset < sizeof block) {
        ssize_t n = write(fd, block + offset, sizeof block - offset);
        if (n < 0) { if (errno == EINTR) continue; saved = errno; break; }
        if (n == 0) { saved = EIO; break; }
        offset += (size_t)n;
    }
    if (close(fd) != 0) *cleanup_error = errno;
    return saved;
}

static void evidence_unary(struct result *result, const char *name, const char *path, int kind)
{
    int setup_cleanup = 0, setup = establish_empty(path, &setup_cleanup), rc = -1, saved = 0, cleanup = 0;
    if (setup != 0 || setup_cleanup != 0) {
        add_record(result, name, PRE_FAILED, 0, 0, OUT_INCOMPLETE, setup, setup_cleanup, 0, 0, 0); return;
    }
    if (kind == 0) { int fd = open(path, O_RDONLY | O_CLOEXEC, 0); unsigned char byte;
        if (fd >= 0) { rc = (int)read(fd, &byte, 1U); if (rc < 0) saved = errno; if (close(fd) != 0) cleanup = errno; }
        else saved = errno;
    } else if (kind == 1) { int fd = open(path, O_WRONLY | O_CLOEXEC, 0); if (fd >= 0) { rc = 0; if (close(fd) != 0) cleanup = errno; } else saved = errno; }
    else if (kind == 2) { rc = truncate(path, 0); if (rc != 0) saved = errno; }
    else if (kind == 3) { rc = link(path, "/sandbox/evidence/link-target"); if (rc != 0) saved = errno; }
    else { rc = rename(path, "/sandbox/evidence/rename-target"); if (rc != 0) saved = errno; }
    add_record(result, name, PRE_OK, 1,
               rc >= 0 || saved == EPERM || saved == EACCES || saved == EROFS,
               rc >= 0 ? OUT_VIOLATION : classify_errno(saved), saved,
               cleanup, rc >= 0 ? 1U : 0U, 0, 0);
}

static void sentinel_action(const struct request *request, struct result *result)
{
    unsigned char data[4097], digest[32];
    struct stat metadata;
    size_t used = 0;
    int fd, saved = 0, cleanup = 0;
    ssize_t n;
    fd = open(request->path, O_RDONLY | O_CLOEXEC, 0);
    if (fd < 0) {
        saved = errno;
        add_record(result, "open", PRE_OK, 1, 1,
                   saved == ENOENT || saved == ENOTDIR ? OUT_INCOMPLETE : classify_errno(saved),
                   saved, 0, 0, request->size, 0);
        add_record(result, "read", PRE_FAILED, 0, 0, OUT_INCOMPLETE,
                   0, 0, 0, request->size, 0);
        return;
    }
    if (fstat(fd, &metadata) != 0) {
        saved = errno;
        if (close(fd) != 0) cleanup = errno;
        add_record(result, "open", PRE_OK, 1, 0, OUT_INCOMPLETE,
                   saved, cleanup, 0, request->size, 0);
        add_record(result, "read", PRE_FAILED, 0, 0, OUT_INCOMPLETE,
                   0, 0, 0, request->size, 0);
        return;
    }
    if (!S_ISREG(metadata.st_mode)) {
        if (close(fd) != 0) cleanup = errno;
        add_record(result, "open", PRE_OK, 1, 1, OUT_VIOLATION,
                   0, cleanup, (uint64_t)(metadata.st_mode & S_IFMT), request->size, 0);
        add_record(result, "read", PRE_FAILED, 0, 0, OUT_INCOMPLETE,
                   0, 0, 0, request->size, 0);
        return;
    }
    add_record(result, "open", PRE_OK, 1, 1, OUT_SUCCESS,
               0, 0, (uint64_t)(metadata.st_mode & S_IFMT), request->size, 0);
    while (used < request->size + 1U) {
        n = read(fd, data + used, (size_t)request->size + 1U - used);
        if (n < 0) { if (errno == EINTR) continue; saved = errno; break; }
        if (n == 0) break;
        used += (size_t)n;
    }
    if (close(fd) != 0) cleanup = errno;
    if (saved != 0) add_record(result, "read", PRE_OK, 1, 0, OUT_INCOMPLETE, saved, cleanup, used, request->size, 0);
    else {
        ys_sha256_bytes(data, used, digest);
        add_record(result, "read", PRE_OK, 1, 1,
                   used == request->size && memcmp(digest, request->expected_digest, 32U) == 0 ? OUT_SUCCESS : OUT_VIOLATION,
                   0, cleanup, used, request->size, memcmp(digest, request->expected_digest, 32U) == 0);
    }
}

static void descriptor_action(struct result *result)
{
    int fd, leaks = 0, first = 0, failed = 0, scan_error = 0;
    for (fd = 0; fd <= 2; fd++) {
        struct stat st; int flags, saved = 0, correct;
        if (fstat(fd, &st) != 0) saved = errno;
        flags = saved == 0 ? fcntl(fd, F_GETFL) : -1;
        if (flags < 0 && saved == 0) saved = errno;
        correct = saved == 0 && S_ISREG(st.st_mode) &&
            (fd == 0 ? ((flags & O_ACCMODE) == O_RDONLY) : ((flags & O_ACCMODE) == O_WRONLY && (flags & O_APPEND) != 0));
        add_record(result, fd == 0 ? "fd0" : fd == 1 ? "fd1" : "fd2", PRE_OK, 1,
                   saved == 0, saved != 0 ? OUT_INCOMPLETE : correct ? OUT_SUCCESS : OUT_VIOLATION,
                   saved, 0, saved == 0 ? (uint64_t)(st.st_mode & S_IFMT) : 0U,
                   saved == 0 ? (uint64_t)(flags & O_ACCMODE) : 0U,
                   saved == 0 ? (uint64_t)((flags & O_APPEND) != 0) : 0U);
    }
    for (fd = FD_SCAN_FIRST; fd <= FD_SCAN_LAST; fd++) {
        int rc; errno = 0; rc = fcntl(fd, F_GETFD);
        if (rc >= 0) { if (leaks == 0) first = fd; leaks++; }
        else if (errno != EBADF) { failed = fd; scan_error = errno; break; }
    }
    add_record(result, "fd-scan", PRE_OK, 1, scan_error == 0,
               scan_error == 0 ? OUT_SUCCESS : OUT_INCOMPLETE, scan_error, 0,
               FD_SCAN_FIRST, FD_SCAN_LAST, (uint64_t)failed);
    add_record(result, "fd-leaks", PRE_OK, 1, scan_error == 0,
               leaks != 0 ? OUT_VIOLATION : scan_error == 0 ? OUT_SUCCESS : OUT_INCOMPLETE,
               scan_error, 0, (uint64_t)leaks, (uint64_t)first, 0);
    result->force_incomplete = 1;
}

static struct socket_facts build_socket_facts(void)
{
    struct socket_facts facts = {0};
#if defined(__linux__) && !defined(YSTACK_TEST_NO_SOCKET_CONSTANTS)
    facts.linux_build = 1;
#if defined(AF_MAX)
    facts.domain_max = AF_MAX;
#endif
#if defined(SOCK_CLOEXEC)
    facts.cloexec_available = 1; facts.cloexec = SOCK_CLOEXEC;
#endif
#if defined(AF_NETLINK) && !defined(YSTACK_TEST_MASK_NETLINK)
    facts.netlink_available = 1; facts.netlink = AF_NETLINK;
#endif
#if defined(NETLINK_USERSOCK)
    facts.usersock_available = 1; facts.usersock = NETLINK_USERSOCK;
#endif
#if defined(AF_PACKET) && !defined(YSTACK_TEST_MASK_PACKET)
    facts.packet_available = 1; facts.packet = AF_PACKET;
#endif
#if defined(AF_VSOCK)
    facts.vsock_available = 1; facts.vsock = AF_VSOCK;
#endif
#endif
#ifdef YSTACK_PROBE_TEST
    if (fixture_socket_override != NULL) return *fixture_socket_override;
#endif
    return facts;
}

static void socket_action(const struct request *request, struct result *result)
{
    struct socket_facts facts = build_socket_facts();
    int type, protocol = 0, fd, saved = 0, cleanup = 0, completed;
    if (!facts.linux_build || !facts.cloexec_available || facts.domain_max <= 0 || facts.domain_max > 65536L) {
        result->domain = "unknown"; result->force_incomplete = 1;
        add_record(result, "socket", PRE_UNKNOWN, 0, 0, OUT_INCOMPLETE, 0, 0,
                   request->family, 0, 0); return;
    }
    result->domain_max = (unsigned)facts.domain_max;
    if (request->family >= (unsigned long)facts.domain_max) { add_record(result, "socket", PRE_UNKNOWN, 0, 0, OUT_INCOMPLETE, 0, 0,
        request->family, 0, 0); result->force_incomplete = 1; return; }
    if (!facts.netlink_available || !facts.packet_available) {
        add_record(result, "socket", PRE_UNKNOWN, 0, 0, OUT_UNSUPPORTED, ENOSYS, 0,
                   request->family, 0, 0); result->force_incomplete = 1; return;
    }
    type = SOCK_STREAM | facts.cloexec;
    if (facts.netlink_available && request->family == (unsigned)facts.netlink) {
        if (!facts.usersock_available) {
            add_record(result, "socket", PRE_UNKNOWN, 0, 0, OUT_UNSUPPORTED, ENOSYS, 0,
                       request->family, 0, 0); result->force_incomplete = 1; return;
        }
        type = SOCK_RAW | facts.cloexec; protocol = facts.usersock;
    } else if (facts.packet_available && request->family == (unsigned)facts.packet) {
        type = SOCK_RAW | facts.cloexec;
    } else if (facts.vsock_available && request->family == (unsigned)facts.vsock) {
        type = SOCK_STREAM | facts.cloexec;
    }
    fd = socket((int)request->family, type, protocol);
    if (fd < 0) saved = errno; else if (close(fd) != 0) cleanup = errno;
    completed = fd >= 0 || saved == EPERM;
    add_record(result, "socket", PRE_OK, 1, completed,
               fd >= 0 ? OUT_VIOLATION : saved == EPERM ? OUT_REFUSED :
               (saved == EAFNOSUPPORT || saved == EPROTONOSUPPORT || saved == ESOCKTNOSUPPORT || saved == EOPNOTSUPP) ? OUT_UNSUPPORTED : OUT_INCOMPLETE,
               saved, cleanup,
               request->family, (uint64_t)(unsigned)type, (uint64_t)(unsigned)protocol);
}

static void signal_action(struct result *result)
{
    pid_t pid = getpid(), parent = getppid();
    int private_relationship = pid == 1 && parent == 0;
    add_record(result, "relationship", PRE_OK, 1, 1,
               private_relationship ? OUT_SUCCESS : OUT_INCOMPLETE,
               0, 0, (uint64_t)pid, (uint64_t)parent,
               private_relationship ? 1U : 0U);
    add_record(result, "supervisor-signal",
               private_relationship ? PRE_UNKNOWN : PRE_FAILED,
               0, 0, OUT_INCOMPLETE, 0, 0,
               private_relationship ? 1U : 2U, 0, 0);
    result->force_incomplete = 1;
}

static int stream_payload(size_t target)
{
    unsigned char *block = malloc(BLOCK_SIZE);
    size_t total = 0;
    if (block == NULL) return 73;
    memset(block, 'x', BLOCK_SIZE);
    while (total < target) {
        size_t want = target - total < BLOCK_SIZE ? target - total : BLOCK_SIZE;
        ssize_t n = write(STDOUT_FILENO, block, want);
        if (n < 0) {
            if (errno == EINTR) continue;
            free(block);
            return 73;
        }
        if (n == 0) {
            free(block);
            return 73;
        }
        total += (size_t)n;
    }
    free(block);
    return 0;
}

static void *paused_thread(void *unused)
{
    (void)unused;
    for (;;) {
        (void)pause();
        TEST_LOOP(1U, 0U, 0U);
    }
    return NULL;
}
static void *spinning_thread(void *unused)
{
    volatile uint64_t value = (uintptr_t)unused + 1U;
#ifdef YSTACK_PROBE_TEST
    uint64_t iteration = 0;
#endif
    for (;;) {
        value = value * UINT64_C(6364136223846793005) + 1U;
#ifdef YSTACK_PROBE_TEST
        TEST_LOOP(2U, (uintptr_t)unused, iteration++);
#else
        TEST_LOOP(2U, (uintptr_t)unused, 0U);
#endif
    }
    return NULL;
}

static void resource_action(enum action action, struct result *result)
{
    uint64_t count = 0;
    if (action == ACT_FORK_BOMB) {
        for (;;) {
            pid_t pid = fork();
            if (pid < 0) break;
            if (pid == 0) for (;;) pause();
            count++;
        }
        add_record(result, "fork", PRE_OK, 1, 0, OUT_INCOMPLETE,
                   errno, 0, count, 0, 0);
    } else if (action == ACT_THREAD_BOMB) {
        for (;;) {
            pthread_t thread;
            int error = pthread_create(&thread, NULL, paused_thread, NULL);
            if (error != 0) {
                errno = error;
                break;
            }
            (void)pthread_detach(thread);
            count++;
        }
        add_record(result, "thread", PRE_OK, 1, 0, OUT_INCOMPLETE,
                   errno, 0, count, 0, 0);
    } else if (action == ACT_CPU_SPIN) {
        pthread_t threads[31];
        size_t i;
        for (i = 0; i < 31U; i++) {
            int error = pthread_create(&threads[i], NULL, spinning_thread,
                                       (void *)(uintptr_t)i);
            if (error != 0) {
                add_record(result, "cpu", PRE_OK, 1, 0, OUT_INCOMPLETE,
                           error, 0, i, 32, 0);
                return;
            }
        }
        (void)spinning_thread((void *)31U);
    } else if (action == ACT_MEMORY_EXHAUSTION) {
        for (;;) {
            volatile unsigned char *block = malloc(BLOCK_SIZE);
            size_t i;
            if (block == NULL) break;
            for (i = 0; i < BLOCK_SIZE; i += 4096U)
                block[i] = (unsigned char)i;
            count += BLOCK_SIZE;
        }
        add_record(result, "memory", PRE_OK, 1, 0, OUT_INCOMPLETE,
                   errno, 0, count, 0, 0);
    } else {
        unsigned left = 60U;
        while (left != 0U) left = sleep(left);
        add_record(result, "sleep", PRE_OK, 1, 1, OUT_SUCCESS,
                   0, 0, 60, 0, 0);
    }
    result->force_incomplete = 1;
}

static void scratch_fill_action(struct result *result)
{
    int fd = open("/sandbox/scratch/fill", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    unsigned char *block;
    uint64_t total = 0;
    int saved = 0, cleanup = 0;
    if (fd < 0) {
        add_record(result, "fill", PRE_FAILED, 0, 0, OUT_INCOMPLETE,
                   errno, 0, 0, 32U * BLOCK_SIZE, 0);
        return;
    }
    block = malloc(BLOCK_SIZE);
    if (block == NULL) {
        saved = errno != 0 ? errno : ENOMEM;
        if (close(fd) != 0) cleanup = errno;
        add_record(result, "fill", PRE_FAILED, 0, 0, OUT_INCOMPLETE,
                   saved, cleanup, 0, 32U * BLOCK_SIZE, 0);
        return;
    }
    memset(block, 'x', BLOCK_SIZE);
    while (total < 32U * BLOCK_SIZE) {
        size_t want = (size_t)(32U * BLOCK_SIZE - total);
        ssize_t n;
        if (want > BLOCK_SIZE) want = BLOCK_SIZE;
        n = write(fd, block, want);
        if (n < 0) {
            if (errno == EINTR) continue;
            saved = errno;
            break;
        }
        if (n == 0) {
            saved = EIO;
            break;
        }
        total += (uint64_t)n;
    }
    free(block);
    if (close(fd) != 0) cleanup = errno;
    add_record(result, "fill", PRE_OK, 1, saved == 0,
               saved == 0 ? OUT_SUCCESS : OUT_INCOMPLETE,
               saved, cleanup, total, 32U * BLOCK_SIZE, 0);
}

static void scratch_action(struct result *result)
{
    static const char *const names[] = {"ftruncate", "fallocate", "madv-remove", "path-truncate", "unlink", "rmdir", "tmpfile"};
    size_t i;
    for (i = 0; i < sizeof names / sizeof names[0]; i++) {
        char path[96];
        int fd = -1, setup = 0, rc = -1, saved = 0, cleanup = 0, attempted = 0;
        (void)snprintf(path, sizeof path, "/sandbox/scratch/probe-%zu", i);
        if (i == 5U) {
            if (mkdir(path, 0700) != 0) setup = errno;
            if (setup == 0) {
                attempted = 1;
                rc = rmdir(path);
                if (rc != 0) saved = errno;
            }
        } else if (i == 6U) {
#if defined(__linux__) && defined(O_TMPFILE)
            attempted = 1;
            fd = open("/sandbox/scratch", O_RDWR | O_TMPFILE | O_CLOEXEC, 0600);
            if (fd < 0) saved = errno;
            else {
                rc = 0;
                if (close(fd) != 0) cleanup = errno;
            }
            setup = 0;
#else
            add_record(result, names[i], PRE_UNKNOWN, 0, 0, OUT_UNSUPPORTED,
                       ENOSYS, 0, 0, 0, 0);
            continue;
#endif
        } else {
#if !defined(__linux__)
            if (i == 1U) {
                add_record(result, names[i], PRE_UNKNOWN, 0, 0, OUT_UNSUPPORTED,
                           ENOSYS, 0, 0, 0, 0);
                continue;
            }
#endif
#if !defined(MADV_REMOVE)
            if (i == 2U) {
                add_record(result, names[i], PRE_UNKNOWN, 0, 0, OUT_UNSUPPORTED,
                           ENOSYS, 0, 0, 0, 0);
                continue;
            }
#endif
            setup = establish_block(path, &cleanup);
            if (setup == 0 && cleanup == 0) {
                if (i == 0U) {
                    fd = open(path, O_RDWR | O_CLOEXEC, 0);
                    if (fd < 0) setup = errno;
                    else {
                        attempted = 1;
                        rc = ftruncate(fd, 0);
                        if (rc != 0) saved = errno;
                        if (close(fd) != 0 && cleanup == 0) cleanup = errno;
                    }
                } else if (i == 1U) {
#if defined(__linux__)
                    fd = open(path, O_RDWR | O_CLOEXEC, 0);
                    if (fd < 0) setup = errno;
                    else {
                        attempted = 1;
                        rc = fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
                                       0, 1);
                        if (rc != 0) saved = errno;
                        if (close(fd) != 0 && cleanup == 0) cleanup = errno;
                    }
#endif
                } else if (i == 2U) {
#if defined(MADV_REMOVE)
                    void *page;
                    fd = open(path, O_RDWR | O_CLOEXEC, 0);
                    if (fd < 0) setup = errno;
                    else {
                        page = mmap(NULL, 4096U, PROT_READ | PROT_WRITE,
                                    MAP_SHARED, fd, 0);
                        if (page == MAP_FAILED) setup = errno;
                        else {
                            attempted = 1;
                            rc = madvise(page, 4096U, MADV_REMOVE);
                            if (rc != 0) saved = errno;
                            if (munmap(page, 4096U) != 0 && cleanup == 0)
                                cleanup = errno;
                        }
                        if (close(fd) != 0 && cleanup == 0)
                            cleanup = errno;
                    }
#endif
                } else if (i == 3U) {
                    attempted = 1;
                    rc = truncate(path, 0);
                    if (rc != 0) saved = errno;
                } else {
                    attempted = 1;
                    rc = unlink(path);
                    if (rc != 0) saved = errno;
                }
            }
        }
        if (setup != 0 || (!attempted && cleanup != 0)) {
            add_record(result, names[i], PRE_FAILED, 0, 0, OUT_INCOMPLETE,
                       setup, cleanup, 0, 0, 0);
        } else {
            enum outcome outcome = rc == 0 ? OUT_VIOLATION :
                (saved == ENOSYS ? OUT_UNSUPPORTED : classify_errno(saved));
            int completed = rc == 0 || saved == EPERM || saved == EACCES || saved == EROFS;
            add_record(result, names[i], PRE_OK, attempted, completed, outcome,
                       saved, cleanup, 0, 0, 0);
        }
    }
}

static void run_action(const struct request *request, struct result *result)
{
    memset(result, 0, sizeof *result);
    switch (request->mode->action) {
    case ACT_CANDIDATE_READ:
        file_action(result, "read", "/sandbox/candidate/README.md",
                    O_RDONLY | O_CLOEXEC, 0, 1, NULL, 0, 1);
        break;
    case ACT_CANDIDATE_WRITE:
        file_action(result, "create", "/sandbox/candidate/probe-write",
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600,
                    0, "x", 1, 0);
        break;
    case ACT_TOOLS_WRITE:
        file_action(result, "create", "/sandbox/tools/probe-write",
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600,
                    0, "x", 1, 0);
        break;
    case ACT_EVIDENCE_READ:
        evidence_unary(result, "read", "/sandbox/evidence/read", 0);
        break;
    case ACT_EVIDENCE_REOPEN:
        evidence_unary(result, "reopen", "/sandbox/evidence/reopen", 1);
        break;
    case ACT_EVIDENCE_TRUNCATE:
        evidence_unary(result, "truncate", "/sandbox/evidence/truncate", 2);
        break;
    case ACT_EVIDENCE_LINK:
        evidence_unary(result, "link", "/sandbox/evidence/link-source", 3);
        break;
    case ACT_EVIDENCE_RENAME:
        evidence_unary(result, "rename", "/sandbox/evidence/rename-source", 4);
        break;
    case ACT_EVIDENCE_LIST: {
        DIR *directory = opendir("/sandbox/evidence");
        int saved = 0, cleanup = 0, rc = -1;
        if (directory == NULL) saved = errno;
        else {
            errno = 0;
            (void)readdir(directory);
            if (errno != 0) saved = errno;
            else rc = 0;
            if (closedir(directory) != 0) cleanup = errno;
        }
        add_record(result, "list", PRE_OK, 1,
                   rc == 0 || saved == EPERM || saved == EACCES || saved == EROFS,
                   rc == 0 ? OUT_VIOLATION : classify_errno(saved),
                   saved, cleanup, 0, 0, 0);
        break;
    }
    case ACT_SCRATCH_FREE:
        scratch_action(result);
        break;
    case ACT_SCRATCH_FILL:
        scratch_fill_action(result);
        break;
    case ACT_OUTPUT_OVERFLOW:
        break;
    case ACT_SOCKET_FAMILY:
        socket_action(request, result);
        break;
    case ACT_HOST_SENTINEL:
    case ACT_SIBLING_SENTINEL:
        sentinel_action(request, result);
        break;
    case ACT_ENVIRONMENT: {
        static const char *const expected[] = {
            "LANG=C", "LC_ALL=C", "PATH=/sandbox/tools", "TMPDIR=/sandbox/scratch"
        };
        extern char **environ;
        size_t index = 0;
        int correct = 1;
        while (environ[index] != NULL) {
            if (index >= sizeof expected / sizeof expected[0] ||
                strcmp(environ[index], expected[index]) != 0) correct = 0;
            index++;
        }
        if (index != sizeof expected / sizeof expected[0]) correct = 0;
        add_record(result, "environment", PRE_OK, 1, 1,
                   correct ? OUT_SUCCESS : OUT_VIOLATION,
                   0, 0, index, sizeof expected / sizeof expected[0], 0);
        break;
    }
    case ACT_DESCRIPTORS:
        descriptor_action(result);
        break;
    case ACT_SIGNAL_SUPERVISOR:
        signal_action(result);
        break;
    case ACT_NAMESPACE_ESCAPE:
#if defined(__linux__)
        { int rc = unshare(CLONE_NEWUSER | CLONE_NEWNS), saved = rc == 0 ? 0 : errno;
          enum outcome outcome = rc == 0 ? OUT_VIOLATION : classify_errno(saved);
          add_record(result, "unshare", PRE_OK, 1, rc == 0 || outcome == OUT_REFUSED, outcome,
                     saved, 0, 0, 0, 0); }
#else
        add_record(result, "unshare", PRE_UNKNOWN, 0, 0, OUT_UNSUPPORTED, ENOSYS, 0, 0, 0, 0);
#endif
        break;
    case ACT_CGROUP_ESCAPE:
        file_action(result, "cgroup-write", "/sys/fs/cgroup/cgroup.procs",
                    O_WRONLY | O_CLOEXEC, 0, 0, "0\n", 2, 0);
        break;
    case ACT_FORGED_EVIDENCE: {
        static const char forged[] =
            "{\"kind\":\"sandbox_guest_report\",\"forged\":true}\n";
        file_action(result, "forged-evidence",
                    "/sandbox/evidence/forged-report.json",
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600,
                    0, forged, sizeof forged - 1U, 0);
        break;
    }
    case ACT_FORK_BOMB:
    case ACT_THREAD_BOMB:
    case ACT_CPU_SPIN:
    case ACT_MEMORY_EXHAUSTION:
    case ACT_SLEEP:
        resource_action(request->mode->action, result);
        break;
    case ACT_FORGED_STDOUT:
        break;
    }
}

static int probe_main(void)
{
    static const char input_error[] = "YSPROBE1 error=input\n", read_error[] = "YSPROBE1 error=read\n";
    static const char forged[] = "{\"kind\":\"sandbox_guest_report\",\"forged\":true}\n";
    struct request request; struct result result; int parsed = read_request(&request);
    if (parsed <= 0) { const char *line = parsed < 0 ? read_error : input_error; return write_all(STDOUT_FILENO, line, strlen(line)) ? 64 : 74; }
    if (request.mode->action == ACT_OUTPUT_OVERFLOW) return stream_payload(OUTPUT_ATTEMPT);
    if (request.mode->action == ACT_FORGED_STDOUT) return write_all(STDOUT_FILENO, forged, sizeof forged - 1U) ? 0 : 73;
    run_action(&request, &result); return emit_result(&request, &result) ? 0 : 74;
}

#ifdef YSTACK_PROBE_TEST
struct oracle_record {
    const char *name, *pre, *outcome;
    int attempted, completed, error_number, cleanup_error;
    uint64_t value[3];
};

static int fixture_failures;
static int fixture_observed_return;
static char **fixture_saved_environment;
static const unsigned char *fixture_expected_output;
static size_t fixture_expected_output_length, fixture_expected_stdout_total;
static int fixture_expected_escape, fixture_expected_return;
static char **fixture_case_environment;
static char covered_obligations[256][128];
static size_t covered_obligation_count;

static void cover_obligation(const char *id)
{
    size_t i;
    if(strncmp(id,"obligation-",11U)!=0)return;
    for(i=0;i<covered_obligation_count;i++)if(strcmp(id,covered_obligations[i])==0)fixture_fail("duplicate obligation id");
    if(covered_obligation_count>=sizeof covered_obligations/sizeof covered_obligations[0])fixture_fail("obligation capacity");
    if(strlen(id)>=sizeof covered_obligations[0])fixture_fail("obligation id length");
    (void)strcpy(covered_obligations[covered_obligation_count++],id);
}

static void fixture_check(int condition, const char *message)
{
    if (!condition) { (void)fprintf(stderr, "FAIL %s\n", message); fixture_failures++; }
}

static void fixture_reset(void)
{
    memset(fixture_steps, 0, sizeof fixture_steps);
    fixture_step_count = 0; fixture_step_index = 0;
    fixture_capture_length = 0; fixture_stdout_total = 0;
    fixture_escape = 0; fixture_failure = NULL;
    fixture_expected_output = NULL; fixture_expected_output_length = 0;
    fixture_expected_stdout_total = 0; fixture_expected_escape = 3;
    fixture_expected_return = 0; fixture_socket_override = NULL;
    fixture_case_environment = NULL;
    memset(fixture_blocks, 0xa5, sizeof fixture_blocks);
    memset(fixture_block_live, 0, sizeof fixture_block_live);
    memset(fixture_mapping, 0x5a, sizeof fixture_mapping);
}

static struct fixture_step *queue_return(enum fixture_op op, long returned, int error_number)
{
    struct fixture_step *s = fixture_push(op);
    s->returned = returned; s->error_number = error_number; return s;
}

static void queue_read(int fd, size_t requested, const void *bytes, size_t returned)
{
    struct fixture_step *s = queue_return(FX_READ, (long)returned, 0);
    s->call.io.fd = fd; s->call.io.length = requested;
    s->read_bytes = bytes; s->read_length = returned;
}

static void queue_read_error(int fd, size_t requested, int error_number)
{
    struct fixture_step *s = queue_return(FX_READ, -1, error_number);
    s->call.io.fd = fd; s->call.io.length = requested;
}

static void queue_instruction(const char *instruction)
{
    size_t length = strlen(instruction);
    queue_read(STDIN_FILENO, INPUT_CAP + 1U, instruction, length);
    if (length != 0U) queue_read(STDIN_FILENO, INPUT_CAP + 1U - length, NULL, 0);
}

static void queue_write_exact(int fd, const void *bytes, size_t length, long returned, int error_number)
{
    struct fixture_step *s = queue_return(FX_WRITE, returned, error_number);
    s->call.io.fd = fd; s->call.io.length = length;
    s->call.io.kind = FX_BYTES_EXACT; s->call.io.bytes = bytes;
}

static void queue_write_repeat(int fd, unsigned char byte, size_t length, long returned, int error_number)
{
    struct fixture_step *s = queue_return(FX_WRITE, returned, error_number);
    s->call.io.fd = fd; s->call.io.length = length;
    s->call.io.kind = FX_BYTES_REPEAT; s->call.io.byte = byte;
}

static void queue_open(const char *path, int flags, mode_t mode, int returned, int error_number)
{
    struct fixture_step *s = queue_return(FX_OPEN, returned, error_number);
    s->call.open.path = path; s->call.open.flags = flags; s->call.open.mode = mode;
}

static void queue_close(int fd, int returned, int error_number)
{
    struct fixture_step *s = queue_return(FX_CLOSE, returned, error_number);
    s->call.close.fd = fd;
}

static void queue_fstat(int fd, mode_t mode, int returned, int error_number)
{
    struct fixture_step *s = queue_return(FX_FSTAT, returned, error_number);
    s->call.fstat.fd = fd; s->stat_mode = mode;
}

static void queue_fcntl(int fd, int command, int returned, int error_number)
{
    struct fixture_step *s = queue_return(FX_FCNTL, returned, error_number);
    s->call.fcntl.fd = fd; s->call.fcntl.command = command;
}

static size_t oracle_line(char *line, size_t cap, const char *instruction,
                          const char *checks, const char *domain,
                          const struct oracle_record *records, size_t count)
{
    char digest[65]; size_t used = 0, i; int n;
    digest_hex(instruction, strlen(instruction), digest);
    n = snprintf(line, cap, "YSPROBE1 %.*s %s %s %s %zu", (int)(strchr(instruction + 9, ' ') != NULL ?
        (size_t)(strchr(instruction + 9, ' ') - (instruction + 9)) : strcspn(instruction + 9, "\n")),
        instruction + 9, digest, checks, domain, count);
    if (n < 0 || (size_t)n >= cap) fixture_fail("oracle header");
    used = (size_t)n;
    for (i = 0; i < count; i++) {
        const struct oracle_record *r = &records[i];
        n = snprintf(line + used, cap - used,
            " %s:%s:%d:%d:%s:%d:%d:%llu:%llu:%llu", r->name, r->pre,
            r->attempted, r->completed, r->outcome, r->error_number, r->cleanup_error,
            (unsigned long long)r->value[0], (unsigned long long)r->value[1],
            (unsigned long long)r->value[2]);
        if (n < 0 || (size_t)n >= cap - used) fixture_fail("oracle record");
        used += (size_t)n;
    }
    if (used + 1U >= cap) fixture_fail("oracle newline");
    line[used++] = '\n'; line[used] = '\0'; return used;
}

static void expect_output(const void *bytes, size_t length, int returned)
{
    fixture_expected_output = bytes; fixture_expected_output_length = length;
    fixture_expected_stdout_total = length; fixture_expected_return = returned;
    queue_write_exact(STDOUT_FILENO, bytes, length, (long)length, 0);
}

static void run_case(const char *name)
{
    extern char **environ;
    int failures_before = fixture_failures;
    fixture_saved_environment = environ;
    if (fixture_case_environment != NULL) environ = fixture_case_environment;
    fixture_driver_active = 1;
    if (setjmp(fixture_jump) == 0) {
        fixture_observed_return = probe_main();
        fixture_escape = 3;
    }
    fixture_driver_active = 0;
    environ = fixture_saved_environment;
    fixture_socket_override = NULL;
    if(fixture_expected_escape==1&&fixture_escape==3&&fixture_step_index!=fixture_step_count){
        (void)printf("control %s: rejected\n",name);return;
    }
    if (fixture_escape != fixture_expected_escape) {
        (void)fprintf(stderr, "FAIL %s escape=%d expected=%d detail=%s\n", name,
                      fixture_escape, fixture_expected_escape,
                      fixture_failure == NULL ? "none" : fixture_failure);
        fixture_failures++;
    } else if (fixture_escape != 1) {
        fixture_check(fixture_step_index == fixture_step_count, "script fully consumed");
        fixture_check(fixture_stdout_total == fixture_expected_stdout_total, "stdout total");
        if (fixture_expected_output != NULL)
            fixture_check(fixture_capture_length == fixture_expected_output_length &&
                memcmp(fixture_capture, fixture_expected_output, fixture_expected_output_length) == 0,
                "exact stdout bytes");
        if (fixture_escape == 3)
            fixture_check(fixture_observed_return == fixture_expected_return, "exact probe return");
    }
    if (fixture_escape == fixture_expected_escape && fixture_escape != 1 &&
        fixture_failures == failures_before) {
        (void)printf("case %s: ok\n", name);
        cover_obligation(name);
    }
    if(fixture_escape==1&&fixture_expected_escape==1)(void)printf("control %s: rejected\n",name);
}

static void set_synthetic_socket_facts(long bound)
{
    memset(&fixture_socket_override_value, 0, sizeof fixture_socket_override_value);
    fixture_socket_override_value.linux_build = 1;
    fixture_socket_override_value.domain_max = bound;
    fixture_socket_override_value.cloexec_available = 1;
    fixture_socket_override_value.cloexec = TEST_CLOEXEC;
    fixture_socket_override_value.netlink_available = 1;
    fixture_socket_override_value.netlink = 3;
    fixture_socket_override_value.usersock_available = 1;
    fixture_socket_override_value.usersock = 7;
    fixture_socket_override_value.packet_available = 1;
    fixture_socket_override_value.packet = 4;
    fixture_socket_override_value.vsock_available = 1;
    fixture_socket_override_value.vsock = 5;
    fixture_socket_override = &fixture_socket_override_value;
}

static void self_controls(void)
{
    static const char request[] = "YSPROBE1 candidate-read\n";
    fixture_reset(); queue_instruction(request);
    queue_open("/wrong", O_RDONLY | O_CLOEXEC, 0, 41, 0);
    fixture_expected_escape = 1; run_case("fixture-rejects-wrong-path");

    fixture_reset(); queue_instruction(request);
    fixture_expected_escape = 1; run_case("fixture-rejects-missing-step");

    fixture_reset(); queue_instruction("bad\n");
    queue_write_exact(STDOUT_FILENO, "YSPROBE1 error=input\n", 21U, 22, 0);
    fixture_expected_escape = 1; run_case("fixture-rejects-invalid-write-return");

    fixture_reset();queue_instruction(request);queue_return(FX_CLOSE,0,0);
    fixture_expected_escape=1;run_case("fixture-rejects-wrong-order");
    fixture_reset();queue_instruction(request);queue_open("/sandbox/candidate/README.md",O_WRONLY|O_CLOEXEC,0,41,0);
    fixture_expected_escape=1;run_case("fixture-rejects-wrong-flags");
    fixture_reset();queue_instruction(request);queue_open("/sandbox/candidate/README.md",O_RDONLY|O_CLOEXEC,0,41,0);queue_read(42,1,"x",1);
    fixture_expected_escape=1;run_case("fixture-rejects-wrong-fd");
    fixture_reset();queue_instruction(request);queue_open("/sandbox/candidate/README.md",O_RDONLY|O_CLOEXEC,0,41,0);queue_read(41,2,"xx",2);
    fixture_expected_escape=1;run_case("fixture-rejects-wrong-length");
    fixture_reset();queue_instruction("bad\n");queue_write_exact(STDOUT_FILENO,"XXXXXXXXXXXXXXXXXXXXX",21,21,0);
    fixture_expected_escape=1;run_case("fixture-rejects-wrong-bytes");
    fixture_reset();queue_instruction("YSPROBE1 output-overflow\n");
    {struct fixture_step*s=queue_return(FX_MALLOC,1,0);s->call.allocation.size=BLOCK_SIZE;s->call.allocation.object=FIXTURE_OBJECTS;}
    fixture_expected_escape=1;run_case("fixture-rejects-invalid-object");
    fixture_reset();queue_instruction("bad\n");expect_output("YSPROBE1 error=input\n",21,64);queue_return(FX_CLOSE,0,0);
    fixture_expected_escape=1;run_case("fixture-rejects-leftover-step");
}

static void parser_cases(void)
{
    static const char *const invalid[] = {
        "", "candidate-read\n", "YSPROBE1 unknown\n", "YSPROBE1 candidate-read x\n",
        "YSPROBE1  candidate-read\n", "YSPROBE1 candidate-read \n", "YSPROBE1 candidate-read\r\n",
        "YSPROBE1 candidate-read\nextra", "YSPROBE1 socket-family 00\n", "YSPROBE1 socket-family +1\n",
        "YSPROBE1 socket-family 65536\n", "YSPROBE1 host-sentinel 2f2e 1 0000000000000000000000000000000000000000000000000000000000000000\n"
        ,"YSPROBE1 host-sentinel 2f78 0 0000000000000000000000000000000000000000000000000000000000000000\n"
        ,"YSPROBE1 host-sentinel 2f78 4097 0000000000000000000000000000000000000000000000000000000000000000\n"
        ,"YSPROBE1 host-sentinel 2f78 1 A000000000000000000000000000000000000000000000000000000000000000\n"
    };
    static const char diagnostic[] = "YSPROBE1 error=input\n";
    size_t i; char name[64];
    for (i = 0; i < sizeof invalid / sizeof invalid[0]; i++) {
        fixture_reset(); queue_instruction(invalid[i]); expect_output(diagnostic, sizeof diagnostic - 1U, 64);
        (void)snprintf(name, sizeof name, "input-invalid-%zu", i); run_case(name);
    }
    fixture_reset(); queue_read_error(STDIN_FILENO, INPUT_CAP + 1U, EIO);
    expect_output("YSPROBE1 error=read\n", 20U, 64); run_case("input-read-error");
    {
        static unsigned char boundary[INPUT_CAP+1U];
        memset(boundary,'x',sizeof boundary);
        fixture_reset();queue_read(STDIN_FILENO,INPUT_CAP+1U,boundary,INPUT_CAP);
        queue_read(STDIN_FILENO,1U,NULL,0);expect_output(diagnostic,sizeof diagnostic-1U,64);
        run_case("input-exact-transport-cap-invalid-grammar");
        fixture_reset();queue_read(STDIN_FILENO,INPUT_CAP+1U,boundary,INPUT_CAP+1U);
        expect_output(diagnostic,sizeof diagnostic-1U,64);run_case("input-cap-plus-one");
        boundary[0]='Y';boundary[1]='S';boundary[2]=0;boundary[3]='P';
        fixture_reset();queue_read(STDIN_FILENO,INPUT_CAP+1U,boundary,4U);
        queue_read(STDIN_FILENO,INPUT_CAP-3U,NULL,0);expect_output(diagnostic,sizeof diagnostic-1U,64);
        run_case("input-embedded-nul");
    }
}

static void candidate_cases(void)
{
    static const char instruction[] = "YSPROBE1 candidate-read\n";
    static const struct { const char *name, *outcome, *checks; int error_number, completed, close_error; } cases[] = {
        {"candidate-read-success", "success", "complete", 0, 1, 0},
        {"candidate-read-eperm", "refused", "complete", EPERM, 1, 0},
        {"candidate-read-eperm-close", "refused", "incomplete", EPERM, 1, EIO},
        {"candidate-read-eacces", "refused", "complete", EACCES, 1, 0},
        {"candidate-read-erofs", "refused", "complete", EROFS, 1, 0},
        {"candidate-read-success-close-error", "success", "incomplete", 0, 1, EIO},
        {"candidate-read-eopnotsupp", "unsupported", "incomplete", EOPNOTSUPP, 0, 0},
        {"candidate-read-eio", "incomplete", "incomplete", EIO, 0, 0}
    };
    size_t i; char output[512];
    for (i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        struct oracle_record record = {"read", "ok", cases[i].outcome, 1, cases[i].completed,
            cases[i].error_number, cases[i].close_error, {cases[i].error_number == 0 ? 1U : 0U,
            cases[i].error_number == 0 ? (uint64_t)'x' : 0U, 0}};
        fixture_reset(); queue_instruction(instruction);
        queue_open("/sandbox/candidate/README.md", O_RDONLY | O_CLOEXEC, 0, 41, 0);
        if (cases[i].error_number == 0) queue_read(41, 1U, "x", 1U);
        else queue_read_error(41, 1U, cases[i].error_number);
        queue_close(41, cases[i].close_error == 0 ? 0 : -1, cases[i].close_error);
        expect_output(output, oracle_line(output, sizeof output, instruction, cases[i].checks, "none", &record, 1U), 0);
        run_case(cases[i].name);
    }
    for(i=0;i<2U;i++) {
        int error_number=i==0?ENOENT:EACCES;
        struct oracle_record record={"read","ok",i==0?"incomplete":"refused",1,i!=0,error_number,0,{0,0,0}};
        fixture_reset();queue_instruction(instruction);queue_open("/sandbox/candidate/README.md",O_RDONLY|O_CLOEXEC,0,-1,error_number);
        expect_output(output,oracle_line(output,sizeof output,instruction,i==0?"incomplete":"complete","none",&record,1),0);
        run_case(i==0?"candidate-read-open-missing":"candidate-read-open-refused");
    }
    {
        struct oracle_record record={"read","ok","success",1,1,0,0,{0,0,0}};
        fixture_reset();queue_instruction(instruction);queue_open("/sandbox/candidate/README.md",O_RDONLY|O_CLOEXEC,0,41,0);
        queue_read(41,1,NULL,0);queue_close(41,0,0);
        expect_output(output,oracle_line(output,sizeof output,instruction,"complete","none",&record,1),0);
        run_case("candidate-read-eof");
    }
    {
        struct oracle_record record={"read","ok","success",1,1,0,0,{1,'x',0}};
        const size_t split=7;char output[512];
        fixture_reset();queue_read(STDIN_FILENO,INPUT_CAP+1U,instruction,split);
        queue_read_error(STDIN_FILENO,INPUT_CAP+1U-split,EINTR);
        queue_read(STDIN_FILENO,INPUT_CAP+1U-split,instruction+split,strlen(instruction)-split);
        queue_read(STDIN_FILENO,INPUT_CAP+1U-strlen(instruction),NULL,0);
        queue_open("/sandbox/candidate/README.md",O_RDONLY|O_CLOEXEC,0,41,0);queue_read(41,1,"x",1);queue_close(41,0,0);
        expect_output(output,oracle_line(output,sizeof output,instruction,"complete","none",&record,1),0);
        run_case("obligation-input-chunked-eintr-valid-entry");
    }
}

static void result_emission_cases(void)
{
    static const char instruction[]="YSPROBE1 candidate-read\n";char output[512];size_t length;
    struct oracle_record r={"read","ok","success",1,1,0,0,{1,'x',0}};
    int kind;
    for(kind=0;kind<4;kind++) {
        fixture_reset();queue_instruction(instruction);queue_open("/sandbox/candidate/README.md",O_RDONLY|O_CLOEXEC,0,41,0);
        queue_read(41,1U,"x",1U);queue_close(41,0,0);
        length=oracle_line(output,sizeof output,instruction,"complete","none",&r,1);
        if(kind==0){queue_write_exact(STDOUT_FILENO,output,length,7,0);queue_write_exact(STDOUT_FILENO,output+7,length-7,(long)(length-7),0);fixture_expected_output=(const unsigned char*)output;fixture_expected_output_length=length;fixture_expected_stdout_total=length;}
        else if(kind==1){queue_write_exact(STDOUT_FILENO,output,length,-1,EINTR);expect_output(output,length,0);}
        else if(kind==2){queue_write_exact(STDOUT_FILENO,output,length,0,0);fixture_expected_return=74;}
        else {queue_write_exact(STDOUT_FILENO,output,length,7,0);queue_write_exact(STDOUT_FILENO,output+7,length-7,-1,EIO);fixture_expected_output=(const unsigned char*)output;fixture_expected_output_length=7;fixture_expected_stdout_total=7;fixture_expected_return=74;}
        run_case(kind==0?"result-short-then-full":kind==1?"result-eintr-retry":kind==2?"result-zero-write":"result-prefix-error");
    }
    fixture_reset();queue_instruction("bad\n");queue_write_exact(STDOUT_FILENO,"YSPROBE1 error=input\n",21,7,0);
    queue_write_exact(STDOUT_FILENO,&"YSPROBE1 error=input\n"[7],14,-1,EIO);
    fixture_expected_output=(const unsigned char*)"YSPROBE1 error=input\n";fixture_expected_output_length=7;
    fixture_expected_stdout_total=7;fixture_expected_return=74;run_case("diagnostic-prefix-error");
}

static void socket_cases(void)
{
    static const struct {const char *name;unsigned number;} aliases[]={{"alias-a",2},{"alias-b",2}};
    unsigned family; char instruction[64], output[512], name[64];
    fixture_check(aliases[0].number==aliases[1].number,"synthetic aliases share one numeric family");
    for (family = 0; family < 8U; family++) {
        int type = (family == 3U || family == 4U ? SOCK_RAW : SOCK_STREAM) | TEST_CLOEXEC;
        int protocol = family == 3U ? 7 : 0;
        struct oracle_record record = {"socket", "ok", "refused", 1, 1, EPERM, 0,
            {family, (uint64_t)(unsigned)type, (uint64_t)(unsigned)protocol}};
        fixture_reset(); set_synthetic_socket_facts(8);
        (void)snprintf(instruction, sizeof instruction, "YSPROBE1 socket-family %u\n", family);
        queue_instruction(instruction);
        { struct fixture_step *s = queue_return(FX_SOCKET, -1, EPERM);
          s->call.socket.family = (int)family; s->call.socket.type = type; s->call.socket.protocol = protocol; }
        expect_output(output, oracle_line(output, sizeof output, instruction, "complete", "linux-build-af-v1/8", &record, 1U), 0);
        if(family==2U)(void)snprintf(name,sizeof name,"obligation-socket-synthetic-alias-single-numeric");
        else (void)snprintf(name, sizeof name, "socket-family-%u-eperm", family);
        run_case(name);
    }

    fixture_reset(); set_synthetic_socket_facts(8); fixture_socket_override_value.netlink_available = 0;
    queue_instruction("YSPROBE1 socket-family 2\n");
    { struct oracle_record r = {"socket", "unknown", "unsupported", 0, 0, ENOSYS, 0, {2,0,0}};
      expect_output(output, oracle_line(output, sizeof output, "YSPROBE1 socket-family 2\n", "incomplete", "linux-build-af-v1/8", &r, 1U), 0); }
    run_case("socket-missing-netlink-identity");

    fixture_reset(); set_synthetic_socket_facts(8); fixture_socket_override_value.packet_available = 0;
    queue_instruction("YSPROBE1 socket-family 2\n");
    { struct oracle_record r = {"socket", "unknown", "unsupported", 0, 0, ENOSYS, 0, {2,0,0}};
      expect_output(output, oracle_line(output, sizeof output, "YSPROBE1 socket-family 2\n", "incomplete", "linux-build-af-v1/8", &r, 1U), 0); }
    run_case("socket-missing-packet-identity");
}

static void actual_socket_facts_case(void)
{
    struct socket_facts facts={0};
    static const char instruction[] = "YSPROBE1 socket-family 0\n";
    char output[512], domain[64]; struct oracle_record record;
#if defined(__linux__) && !defined(YSTACK_TEST_NO_SOCKET_CONSTANTS)
    facts.linux_build=1;
#if defined(AF_MAX)
    facts.domain_max=AF_MAX;
#endif
#if defined(SOCK_CLOEXEC)
    facts.cloexec_available=1;facts.cloexec=SOCK_CLOEXEC;
#endif
#if defined(AF_NETLINK) && !defined(YSTACK_TEST_MASK_NETLINK)
    facts.netlink_available=1;facts.netlink=AF_NETLINK;
#endif
#if defined(NETLINK_USERSOCK)
    facts.usersock_available=1;facts.usersock=NETLINK_USERSOCK;
#endif
#if defined(AF_PACKET) && !defined(YSTACK_TEST_MASK_PACKET)
    facts.packet_available=1;facts.packet=AF_PACKET;
#endif
#if defined(AF_VSOCK)
    facts.vsock_available=1;facts.vsock=AF_VSOCK;
#endif
#endif
    int base_valid = facts.linux_build && facts.cloexec_available &&
        facts.domain_max > 0 && facts.domain_max <= 65536L;
    fixture_reset(); queue_instruction(instruction);
    if (!base_valid) {
        record=(struct oracle_record){"socket","unknown","incomplete",0,0,0,0,{0,0,0}};
        expect_output(output,oracle_line(output,sizeof output,instruction,"incomplete","unknown",&record,1),0);
    } else if (!facts.netlink_available || !facts.packet_available) {
        (void)snprintf(domain,sizeof domain,"linux-build-af-v1/%ld",facts.domain_max);
        record=(struct oracle_record){"socket","unknown","unsupported",0,0,ENOSYS,0,{0,0,0}};
        expect_output(output,oracle_line(output,sizeof output,instruction,"incomplete",domain,&record,1),0);
    } else {
        int type=SOCK_STREAM|facts.cloexec;
        struct fixture_step *s=queue_return(FX_SOCKET,-1,EPERM);
        s->call.socket.family=0;s->call.socket.type=type;s->call.socket.protocol=0;
        (void)snprintf(domain,sizeof domain,"linux-build-af-v1/%ld",facts.domain_max);
        record=(struct oracle_record){"socket","ok","refused",1,1,EPERM,0,{0,(uint64_t)(unsigned)type,0}};
        expect_output(output,oracle_line(output,sizeof output,instruction,"complete",domain,&record,1),0);
    }
    run_case("socket-actual-header-facts");
    if(base_valid&&facts.netlink_available&&facts.packet_available) {
        unsigned families[3]={(unsigned)facts.netlink,(unsigned)facts.packet,(unsigned)facts.vsock};
        const char*names[3]={"obligation-socket-actual-netlink-tuple","obligation-socket-actual-packet-tuple","obligation-socket-actual-vsock-tuple"};
        size_t i,limit=facts.vsock_available?3U:2U;
        for(i=0;i<limit;i++) {
            int type=(i<2U?SOCK_RAW:SOCK_STREAM)|facts.cloexec;
            int protocol=i==0U?facts.usersock:0;struct fixture_step*s;
            if(i==0U&&!facts.usersock_available)continue;
            fixture_reset();(void)snprintf(domain,sizeof domain,"linux-build-af-v1/%ld",facts.domain_max);
            {char tuple_instruction[64];(void)snprintf(tuple_instruction,sizeof tuple_instruction,"YSPROBE1 socket-family %u\n",families[i]);queue_instruction(tuple_instruction);
             s=queue_return(FX_SOCKET,-1,EPERM);s->call.socket.family=(int)families[i];s->call.socket.type=type;s->call.socket.protocol=protocol;
             record=(struct oracle_record){"socket","ok","refused",1,1,EPERM,0,{families[i],(uint64_t)(unsigned)type,(uint64_t)(unsigned)protocol}};
             expect_output(output,oracle_line(output,sizeof output,tuple_instruction,"complete",domain,&record,1),0);run_case(names[i]);}
        }
    }
}

static void socket_outcome_cases(void)
{
    static const struct {const char *name,*outcome;int error_number;} cases[]={
        {"socket-eafnosupport","unsupported",EAFNOSUPPORT},
        {"socket-eprotonosupport","unsupported",EPROTONOSUPPORT},
        {"socket-esocktnosupport","unsupported",ESOCKTNOSUPPORT},
        {"socket-eopnotsupp","unsupported",EOPNOTSUPP},
        {"socket-eacces","incomplete",EACCES},{"socket-erofs","incomplete",EROFS},
        {"socket-einval","incomplete",EINVAL},{"socket-enosys","incomplete",ENOSYS},
        {"socket-resource-error","incomplete",EMFILE}};
    static const char instruction[]="YSPROBE1 socket-family 2\n";
    size_t i; char output[512];
    for(i=0;i<sizeof cases/sizeof cases[0];i++) {
        struct oracle_record r={"socket","ok",cases[i].outcome,1,0,cases[i].error_number,0,
            {2,(uint64_t)(unsigned)(SOCK_STREAM|TEST_CLOEXEC),0}};
        struct fixture_step*s;fixture_reset();set_synthetic_socket_facts(8);queue_instruction(instruction);
        s=queue_return(FX_SOCKET,-1,cases[i].error_number);s->call.socket.family=2;
        s->call.socket.type=SOCK_STREAM|TEST_CLOEXEC;s->call.socket.protocol=0;
        expect_output(output,oracle_line(output,sizeof output,instruction,"incomplete","linux-build-af-v1/8",&r,1),0);
        run_case(cases[i].name);
    }
    for(i=0;i<2U;i++) {
        struct oracle_record r={"socket","ok","violation",1,1,0,i==0?0:EIO,
            {2,(uint64_t)(unsigned)(SOCK_STREAM|TEST_CLOEXEC),0}};
        struct fixture_step*s;fixture_reset();set_synthetic_socket_facts(8);queue_instruction(instruction);
        s=queue_return(FX_SOCKET,42,0);s->call.socket.family=2;
        s->call.socket.type=SOCK_STREAM|TEST_CLOEXEC;s->call.socket.protocol=0;
        queue_close(42,i==0?0:-1,i==0?0:EIO);
        expect_output(output,oracle_line(output,sizeof output,instruction,i==0?"complete":"incomplete","linux-build-af-v1/8",&r,1),0);
        run_case(i==0?"socket-success":"socket-success-close-error");
    }
}

static void socket_prerequisite_case(const char *name,struct socket_facts facts,unsigned family,
                                     const char *pre,const char *outcome,int error_number)
{
    char instruction[64],output[512],domain[64];struct oracle_record r;
    fixture_reset();fixture_socket_override_value=facts;fixture_socket_override=&fixture_socket_override_value;
    (void)snprintf(instruction,sizeof instruction,"YSPROBE1 socket-family %u\n",family);queue_instruction(instruction);
    if(!facts.linux_build||!facts.cloexec_available||facts.domain_max<=0||facts.domain_max>65536L)
        (void)snprintf(domain,sizeof domain,"unknown");
    else (void)snprintf(domain,sizeof domain,"linux-build-af-v1/%ld",facts.domain_max);
    r=(struct oracle_record){"socket",pre,outcome,0,0,error_number,0,{family,0,0}};
    expect_output(output,oracle_line(output,sizeof output,instruction,"incomplete",domain,&r,1),0);run_case(name);
}

static void socket_prerequisite_cases(void)
{
    struct socket_facts f;unsigned family;
    memset(&f,0,sizeof f);socket_prerequisite_case("socket-nonlinux-facts",f,0,"unknown","incomplete",0);
    set_synthetic_socket_facts(8);f=fixture_socket_override_value;f.domain_max=0;
    socket_prerequisite_case("socket-domain-zero",f,0,"unknown","incomplete",0);
    f.domain_max=-1;socket_prerequisite_case("socket-domain-negative",f,0,"unknown","incomplete",0);
    f.domain_max=65537;socket_prerequisite_case("socket-domain-too-large",f,0,"unknown","incomplete",0);
    set_synthetic_socket_facts(8);f=fixture_socket_override_value;f.cloexec_available=0;
    socket_prerequisite_case("socket-missing-cloexec",f,0,"unknown","incomplete",0);
    set_synthetic_socket_facts(8);f=fixture_socket_override_value;f.usersock_available=0;
    socket_prerequisite_case("socket-missing-netlink-protocol",f,3,"unknown","unsupported",ENOSYS);
    set_synthetic_socket_facts(8);f=fixture_socket_override_value;
    socket_prerequisite_case("socket-outside-bound",f,8,"unknown","incomplete",0);
    socket_prerequisite_case("obligation-socket-parser-canonical-65535",f,65535U,"unknown","incomplete",0);
    for(family=8;family<12U;family++) {
        char name[64];(void)snprintf(name,sizeof name,"socket-larger-kernel-tail-%u",family);
        socket_prerequisite_case(name,f,family,"unknown","incomplete",0);
    }
}

static void descriptor_case(const char *name, int leak3, int leak128, int error_fd)
{
    static const char instruction[] = "YSPROBE1 descriptors\n";
    struct oracle_record records[5] = {
        {"fd0","ok","success",1,1,0,0,{S_IFREG,O_RDONLY,0}},
        {"fd1","ok","success",1,1,0,0,{S_IFREG,O_WRONLY,1}},
        {"fd2","ok","success",1,1,0,0,{S_IFREG,O_WRONLY,1}},
        {"fd-scan","ok","success",1,1,0,0,{3,1023,0}},
        {"fd-leaks","ok",leak3 || leak128 ? "violation" : "success",1,1,0,0,
            {(uint64_t)(leak3 + leak128), leak3 ? 3U : leak128 ? 128U : 0U,0}}
    };
    char output[1024]; int fd;
    fixture_reset(); queue_instruction(instruction);
    for (fd = 0; fd <= 2; fd++) {
        queue_fstat(fd, S_IFREG | 0600, 0, 0);
        queue_fcntl(fd, F_GETFL, fd == 0 ? O_RDONLY : O_WRONLY | O_APPEND, 0);
    }
    for (fd = FD_SCAN_FIRST; fd <= FD_SCAN_LAST; fd++) {
        int open = (fd == 3 && leak3) || (fd == 128 && leak128);
        if (fd == error_fd) {
            queue_fcntl(fd, F_GETFD, -1, EIO);
            records[3].completed = 0; records[3].outcome = "incomplete";
            records[3].error_number = EIO; records[3].value[2] = (uint64_t)fd;
            records[4].completed = 0; records[4].error_number = EIO;
            if (!leak3 && !leak128) records[4].outcome = "incomplete";
            break;
        }
        queue_fcntl(fd, F_GETFD, open ? 0 : -1, open ? 0 : EBADF);
    }
    expect_output(output, oracle_line(output, sizeof output, instruction, "incomplete", "none", records, 5U), 0);
    run_case(name);
}

static void descriptor_cases(void)
{
    descriptor_case("descriptors-zero-leaks", 0, 0, 0);
    descriptor_case("descriptors-fd3", 1, 0, 0);
    descriptor_case("descriptors-fd128-softlimit-model", 0, 1, 0);
    descriptor_case("descriptors-two-leaks", 1, 1, 0);
    descriptor_case("descriptors-error-before-leak", 0, 0, 3);
    descriptor_case("descriptors-error-after-leak", 1, 0, 77);
    fixture_check(2048>FD_SCAN_LAST,"modeled high descriptor lies outside declared scan");
    descriptor_case("obligation-descriptors-modeled-fd2048-invisible",0,0,0);
}

static void descriptor_metadata_case(const char *name, int target, mode_t mode,
                                     int flags, int fstat_error, int fcntl_error)
{
    static const char instruction[]="YSPROBE1 descriptors\n"; struct oracle_record r[5];
    char output[1024]; int fd, saved=fstat_error!=0?fstat_error:fcntl_error;
    fixture_reset();queue_instruction(instruction);
    for(fd=0;fd<=2;fd++) {
        mode_t current=fd==target?mode:S_IFREG|0600;
        int current_flags=fd==target?flags:(fd==0?O_RDONLY:O_WRONLY|O_APPEND);
        if(fd==target&&fstat_error!=0) queue_fstat(fd,0,-1,fstat_error);
        else {queue_fstat(fd,current,0,0); if(fd==target&&fcntl_error!=0) queue_fcntl(fd,F_GETFL,-1,fcntl_error); else queue_fcntl(fd,F_GETFL,current_flags,0);}
        r[fd]=(struct oracle_record){fd==0?"fd0":fd==1?"fd1":"fd2","ok",
            saved!=0&&fd==target?"incomplete":
            (S_ISREG(current)&&((fd==0&&(current_flags&O_ACCMODE)==O_RDONLY)||
             (fd!=0&&(current_flags&O_ACCMODE)==O_WRONLY&&(current_flags&O_APPEND)!=0)))?"success":"violation",
            1,saved==0||fd!=target,saved!=0&&fd==target?saved:0,0,
            {saved!=0&&fd==target?0U:(uint64_t)(current&S_IFMT),
             saved!=0&&fd==target?0U:(uint64_t)(current_flags&O_ACCMODE),
             saved!=0&&fd==target?0U:(uint64_t)((current_flags&O_APPEND)!=0)}};
    }
    for(fd=3;fd<=1023;fd++) queue_fcntl(fd,F_GETFD,-1,EBADF);
    r[3]=(struct oracle_record){"fd-scan","ok","success",1,1,0,0,{3,1023,0}};
    r[4]=(struct oracle_record){"fd-leaks","ok","success",1,1,0,0,{0,0,0}};
    expect_output(output,oracle_line(output,sizeof output,instruction,"incomplete","none",r,5),0);
    run_case(name);
}

static void descriptor_metadata_cases(void)
{
    int fd; char name[64];
    for(fd=0;fd<=2;fd++) {
        (void)snprintf(name,sizeof name,"descriptor-fd%d-nonregular",fd);
        descriptor_metadata_case(name,fd,S_IFDIR|0700,fd==0?O_RDONLY:O_WRONLY|O_APPEND,0,0);
        (void)snprintf(name,sizeof name,"descriptor-fd%d-wrong-access",fd);
        descriptor_metadata_case(name,fd,S_IFREG|0600,fd==0?O_WRONLY:O_RDONLY,0,0);
        (void)snprintf(name,sizeof name,"obligation-descriptor-fd%d-ordwr",fd);
        descriptor_metadata_case(name,fd,S_IFREG|0600,O_RDWR|(fd==0?0:O_APPEND),0,0);
        (void)snprintf(name,sizeof name,"descriptor-fd%d-missing",fd);
        descriptor_metadata_case(name,fd,0,0,EBADF,0);
        (void)snprintf(name,sizeof name,"descriptor-fd%d-fstat-error",fd);
        descriptor_metadata_case(name,fd,0,0,EIO,0);
        (void)snprintf(name,sizeof name,"descriptor-fd%d-fcntl-error",fd);
        descriptor_metadata_case(name,fd,S_IFREG|0600,0,0,EIO);
    }
    descriptor_metadata_case("descriptor-fd1-no-append",1,S_IFREG|0600,O_WRONLY,0,0);
    descriptor_metadata_case("descriptor-fd2-no-append",2,S_IFREG|0600,O_WRONLY,0,0);
}

static void environment_cases(void)
{
    static char *correct[] = {"LANG=C","LC_ALL=C","PATH=/sandbox/tools","TMPDIR=/sandbox/scratch",NULL};
    static char *missing[] = {"LANG=C","LC_ALL=C","PATH=/sandbox/tools",NULL};
    static char *extra[] = {"LANG=C","LC_ALL=C","PATH=/sandbox/tools","TMPDIR=/sandbox/scratch","X=1",NULL};
    static char *duplicate[] = {"LANG=C","LC_ALL=C","PATH=/sandbox/tools","PATH=/sandbox/tools",NULL};
    static char *wrong[] = {"LANG=C","LC_ALL=C","PATH=/bin","TMPDIR=/sandbox/scratch",NULL};
    static char *order[] = {"LC_ALL=C","LANG=C","PATH=/sandbox/tools","TMPDIR=/sandbox/scratch",NULL};
    static char **const arrays[] = {correct,missing,extra,duplicate,wrong,order};
    static const char *const names[] = {"environment-control","environment-missing","environment-extra",
        "environment-duplicate","environment-wrong","environment-order"};
    static const char instruction[] = "YSPROBE1 environment\n";
    size_t i; char output[512];
    for (i = 0; i < sizeof arrays / sizeof arrays[0]; i++) {
        uint64_t observed = i == 1U ? 3U : i == 2U ? 5U : 4U;
        struct oracle_record r = {"environment","ok",i == 0U ? "success" : "violation",1,1,0,0,{observed,4,0}};
        fixture_reset(); fixture_case_environment = arrays[i]; queue_instruction(instruction);
        expect_output(output, oracle_line(output, sizeof output, instruction, "complete", "none", &r, 1U), 0);
        run_case(names[i]);
    }
}

static void pid_cases(void)
{
    static const struct { const char *name; pid_t pid, parent; int private_relationship; } cases[] = {
        {"pid-private",1,0,1},{"pid-self",1,1,0},{"pid-orphan",7,1,0},
        {"pid-visible",12,34,0},{"pid-unexpected",44,55,0}
    };
    static const char instruction[] = "YSPROBE1 signal-supervisor\n";
    size_t i; char output[768];
    for (i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        struct oracle_record records[2] = {
            {"relationship","ok",cases[i].private_relationship ? "success" : "incomplete",1,1,0,0,
                {(uint64_t)cases[i].pid,(uint64_t)cases[i].parent,cases[i].private_relationship}},
            {"supervisor-signal",cases[i].private_relationship ? "unknown" : "failed","incomplete",0,0,0,0,
                {cases[i].private_relationship ? 1U : 2U,0,0}}
        };
        fixture_reset(); queue_instruction(instruction);
        queue_return(FX_GETPID, cases[i].pid, 0); queue_return(FX_GETPPID, cases[i].parent, 0);
        expect_output(output, oracle_line(output, sizeof output, instruction, "incomplete", "none", records, 2U), 0);
        run_case(cases[i].name);
    }
}

static void namespace_cases(void)
{
    static const char instruction[]="YSPROBE1 namespace-escape\n";
#if defined(__linux__)
    static const struct {const char *id,*outcome;int error,completed;} cases[]={
        {"success","violation",0,1},{"eperm","refused",EPERM,1},
        {"eacces","refused",EACCES,1},{"erofs","refused",EROFS,1},
        {"unsupported","unsupported",EOPNOTSUPP,0},{"eio","incomplete",EIO,0},
        {"enosys","unsupported",ENOSYS,0}};
#endif
    size_t i;char output[512],name[64];
#if defined(__linux__)
    for(i=0;i<sizeof cases/sizeof cases[0];i++) {
        struct oracle_record r={"unshare","ok",cases[i].outcome,1,cases[i].completed,cases[i].error,0,{0,0,0}};
        struct fixture_step*s;fixture_reset();queue_instruction(instruction);
        s=queue_return(FX_UNSHARE,cases[i].error?-1:0,cases[i].error);s->call.unshare.flags=CLONE_NEWUSER|CLONE_NEWNS;
        expect_output(output,oracle_line(output,sizeof output,instruction,cases[i].completed?"complete":"incomplete","none",&r,1),0);
        (void)snprintf(name,sizeof name,"obligation-namespace-%s",cases[i].id);run_case(name);
    }
#else
    {struct oracle_record r={"unshare","unknown","unsupported",0,0,ENOSYS,0,{0,0,0}};
     fixture_reset();queue_instruction(instruction);expect_output(output,oracle_line(output,sizeof output,instruction,"incomplete","none",&r,1),0);run_case("obligation-namespace-nonlinux-no-attempt");}
    (void)i;(void)name;
#endif
}

static void sentinel_case(const char *mode, const char *name, const char *path, const char *bytes,
                          size_t expected_size, const char *read_outcome, int read_error, int close_error)
{
    char digest[65], path_hex[256], instruction[512], output[1024]; size_t i, length = strlen(bytes);
    struct oracle_record records[2]; static const char digits[] = "0123456789abcdef";
    digest_hex("fixture", 7U, digest);
    for (i = 0; path[i] != '\0'; i++) { unsigned c = (unsigned char)path[i]; path_hex[i*2]=digits[c>>4]; path_hex[i*2+1]=digits[c&15]; }
    path_hex[i*2] = '\0';
    (void)snprintf(instruction, sizeof instruction, "YSPROBE1 %s %s %zu %s\n", mode, path_hex, expected_size, digest);
    records[0] = (struct oracle_record){"open","ok","success",1,1,0,0,{S_IFREG,expected_size,0}};
    records[1] = (struct oracle_record){"read","ok",read_outcome,1,read_error == 0,read_error,close_error,
        {read_error == 0 ? length : 0U,expected_size,read_error == 0 && length == expected_size &&
         length == 7U && memcmp(bytes,"fixture",7U)==0}};
    fixture_reset(); queue_instruction(instruction); queue_open(path, O_RDONLY | O_CLOEXEC, 0, 41, 0);
    queue_fstat(41, S_IFREG | 0600, 0, 0);
    if (read_error == 0) { queue_read(41, expected_size + 1U, bytes, length); if (length < expected_size + 1U) queue_read(41, expected_size + 1U - length, NULL, 0); }
    else queue_read_error(41, expected_size + 1U, read_error);
    queue_close(41, close_error == 0 ? 0 : -1, close_error);
    expect_output(output, oracle_line(output, sizeof output, instruction, close_error == 0 && read_error == 0 ? "complete" : "incomplete", "none", records, 2U), 0);
    run_case(name);
}

static void sentinel_cases(void)
{
    sentinel_case("host-sentinel","sentinel-host-match","/quarantine/host","fixture",7,"success",0,0);
    sentinel_case("sibling-sentinel","sentinel-sibling-match","/quarantine/sibling","fixture",7,"success",0,0);
    sentinel_case("host-sentinel","sentinel-read-error","/quarantine/host","fixture",7,"incomplete",EIO,0);
    sentinel_case("host-sentinel","sentinel-close-error","/quarantine/host","fixture",7,"success",0,EIO);
    sentinel_case("host-sentinel","sentinel-host-short","/quarantine/host","fix",7,"violation",0,0);
    sentinel_case("host-sentinel","sentinel-host-long","/quarantine/host","fixtureX",7,"violation",0,0);
    sentinel_case("host-sentinel","sentinel-host-wrong-content","/quarantine/host","xxxxxxx",7,"violation",0,0);
    sentinel_case("sibling-sentinel","sentinel-sibling-short","/quarantine/sibling","fix",7,"violation",0,0);
    sentinel_case("sibling-sentinel","sentinel-sibling-long","/quarantine/sibling","fixtureX",7,"violation",0,0);
    sentinel_case("sibling-sentinel","sentinel-sibling-wrong-content","/quarantine/sibling","xxxxxxx",7,"violation",0,0);
    sentinel_case("host-sentinel","obligation-sentinel-minimum-path-size","/x","f",1,"violation",0,0);
}

static void sentinel_maximum_case(void)
{
    static char path[4097],path_hex[8193],instruction[8400],bytes[4096];
    static const char zeros[]="0000000000000000000000000000000000000000000000000000000000000000";
    struct oracle_record r[2]={{"open","ok","success",1,1,0,0,{S_IFREG,4096,0}},
      {"read","ok","violation",1,1,0,0,{4096,4096,0}}};
    char output[1024];size_t i;
    path[0]='/';memset(path+1,'a',4095);path[4096]='\0';memset(bytes,'x',sizeof bytes);
    for(i=0;i<4096;i++){unsigned c=(unsigned char)path[i];path_hex[i*2]="0123456789abcdef"[c>>4];path_hex[i*2+1]="0123456789abcdef"[c&15];}path_hex[8192]='\0';
    (void)snprintf(instruction,sizeof instruction,"YSPROBE1 host-sentinel %s 4096 %s\n",path_hex,zeros);
    fixture_reset();queue_instruction(instruction);queue_open(path,O_RDONLY|O_CLOEXEC,0,41,0);queue_fstat(41,S_IFREG|0600,0,0);
    queue_read(41,4097,bytes,4096);queue_read(41,1,NULL,0);queue_close(41,0,0);
    expect_output(output,oracle_line(output,sizeof output,instruction,"complete","none",r,2),0);
    run_case("obligation-sentinel-maximum-path-size");
}

static void sentinel_prerequisite_case(const char *mode,const char *name,const char *path,
                                       int open_error,int fstat_error,mode_t file_type,int close_error)
{
    char digest[65],path_hex[256],instruction[512],output[1024];size_t i;
    struct oracle_record r[2];static const char digits[]="0123456789abcdef";
    digest_hex("fixture",7,digest);
    for(i=0;path[i]!='\0';i++){unsigned c=(unsigned char)path[i];path_hex[i*2]=digits[c>>4];path_hex[i*2+1]=digits[c&15];}
    path_hex[i*2]='\0';(void)snprintf(instruction,sizeof instruction,"YSPROBE1 %s %s 7 %s\n",mode,path_hex,digest);
    fixture_reset();queue_instruction(instruction);queue_open(path,O_RDONLY|O_CLOEXEC,0,open_error?-1:41,open_error);
    if(open_error!=0) {
        r[0]=(struct oracle_record){"open","ok",open_error==ENOENT||open_error==ENOTDIR?"incomplete":
            open_error==EPERM||open_error==EACCES||open_error==EROFS?"refused":"incomplete",1,1,open_error,0,{0,7,0}};
        r[1]=(struct oracle_record){"read","failed","incomplete",0,0,0,0,{0,7,0}};
    } else if(fstat_error!=0) {
        queue_fstat(41,0,-1,fstat_error);queue_close(41,close_error?-1:0,close_error);
        r[0]=(struct oracle_record){"open","ok","incomplete",1,0,fstat_error,close_error,{0,7,0}};
        r[1]=(struct oracle_record){"read","failed","incomplete",0,0,0,0,{0,7,0}};
    } else {
        queue_fstat(41,file_type|0600,0,0);queue_close(41,close_error?-1:0,close_error);
        r[0]=(struct oracle_record){"open","ok","violation",1,1,0,close_error,{(uint64_t)file_type,7,0}};
        r[1]=(struct oracle_record){"read","failed","incomplete",0,0,0,0,{0,7,0}};
    }
    expect_output(output,oracle_line(output,sizeof output,instruction,"incomplete","none",r,2),0);
    run_case(name);
}

static void sentinel_prerequisite_cases(void)
{
    sentinel_prerequisite_case("host-sentinel","sentinel-host-absent","/quarantine/host",ENOENT,0,0,0);
    sentinel_prerequisite_case("host-sentinel","sentinel-host-permission","/quarantine/host",EACCES,0,0,0);
    sentinel_prerequisite_case("host-sentinel","sentinel-host-fstat-error","/quarantine/host",0,EIO,0,EBADF);
    sentinel_prerequisite_case("host-sentinel","sentinel-host-wrong-type","/quarantine/host",0,0,S_IFDIR,0);
    sentinel_prerequisite_case("sibling-sentinel","sentinel-sibling-absent","/quarantine/sibling",ENOENT,0,0,0);
    sentinel_prerequisite_case("sibling-sentinel","sentinel-sibling-permission","/quarantine/sibling",EPERM,0,0,0);
    sentinel_prerequisite_case("sibling-sentinel","sentinel-sibling-fstat-error","/quarantine/sibling",0,EIO,0,EBADF);
    sentinel_prerequisite_case("sibling-sentinel","sentinel-sibling-wrong-type","/quarantine/sibling",0,0,S_IFDIR,0);
}

static void file_write_case(const char *name, const char *instruction, const char *path,
                            const void *payload, size_t payload_length, int open_error,
                            long write_return, int write_error, int close_error)
{
    char output[768]; const char *record_name = strstr(name, "cgroup") != NULL ? "cgroup-write" :
        strstr(name, "forged-evidence") != NULL ? "forged-evidence" : "create";
    int forbidden = strcmp(record_name, "cgroup-write") == 0 || strcmp(record_name, "create") == 0;
    int completed = open_error != 0 ? (open_error == EPERM || open_error == EACCES || open_error == EROFS) :
        write_return == (long)payload_length;
    const char *outcome = open_error != 0 ? "refused" : forbidden || strcmp(record_name,"forged-evidence") == 0 ? "violation" : "success";
    struct oracle_record r = {record_name,"ok",outcome,1,completed,
        open_error != 0 ? open_error : write_return < 0 ? write_error : 0,close_error,
        {write_return > 0 ? (uint64_t)write_return : 0,0,0}};
    int flags = strcmp(record_name,"cgroup-write") == 0 ? O_WRONLY | O_CLOEXEC :
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC;
    mode_t mode = strcmp(record_name,"cgroup-write") == 0 ? 0 : 0600;
    fixture_reset(); queue_instruction(instruction);
    queue_open(path, flags, mode, open_error == 0 ? 41 : -1, open_error);
    if (open_error == 0) {
        queue_write_exact(41,payload,payload_length,write_return,write_error);
        queue_close(41,close_error == 0 ? 0 : -1,close_error);
    }
    expect_output(output,oracle_line(output,sizeof output,instruction,
        completed && close_error == 0 ? "complete" : "incomplete","none",&r,1),0);
    run_case(name);
}

static void file_write_cases(void)
{
    static const char forged[] = "{\"kind\":\"sandbox_guest_report\",\"forged\":true}\n";
    file_write_case("candidate-write-refused","YSPROBE1 candidate-write\n","/sandbox/candidate/probe-write","x",1,EPERM,0,0,0);
    file_write_case("candidate-write-success","YSPROBE1 candidate-write\n","/sandbox/candidate/probe-write","x",1,0,1,0,0);
    file_write_case("candidate-write-zero","YSPROBE1 candidate-write\n","/sandbox/candidate/probe-write","x",1,0,0,0,0);
    file_write_case("candidate-write-error","YSPROBE1 candidate-write\n","/sandbox/candidate/probe-write","x",1,0,-1,EIO,0);
    file_write_case("candidate-write-close-error","YSPROBE1 candidate-write\n","/sandbox/candidate/probe-write","x",1,0,1,0,EBADF);
    file_write_case("tools-write-refused","YSPROBE1 tools-write\n","/sandbox/tools/probe-write","x",1,EACCES,0,0,0);
    file_write_case("tools-write-success","YSPROBE1 tools-write\n","/sandbox/tools/probe-write","x",1,0,1,0,0);
    file_write_case("tools-write-short","YSPROBE1 tools-write\n","/sandbox/tools/probe-write","x",1,0,0,0,0);
    file_write_case("tools-write-error","YSPROBE1 tools-write\n","/sandbox/tools/probe-write","x",1,0,-1,EIO,0);
    file_write_case("tools-write-close-error","YSPROBE1 tools-write\n","/sandbox/tools/probe-write","x",1,0,1,0,EIO);
    file_write_case("cgroup-write-refused","YSPROBE1 cgroup-escape\n","/sys/fs/cgroup/cgroup.procs","0\n",2,EACCES,0,0,0);
    file_write_case("cgroup-write-success","YSPROBE1 cgroup-escape\n","/sys/fs/cgroup/cgroup.procs","0\n",2,0,2,0,0);
    file_write_case("cgroup-write-short","YSPROBE1 cgroup-escape\n","/sys/fs/cgroup/cgroup.procs","0\n",2,0,1,0,0);
    file_write_case("cgroup-write-error","YSPROBE1 cgroup-escape\n","/sys/fs/cgroup/cgroup.procs","0\n",2,0,-1,EIO,0);
    file_write_case("cgroup-write-close-error","YSPROBE1 cgroup-escape\n","/sys/fs/cgroup/cgroup.procs","0\n",2,0,2,0,EIO);
    file_write_case("forged-evidence-refused","YSPROBE1 forged-report-evidence\n","/sandbox/evidence/forged-report.json",
                    forged,sizeof forged-1U,EROFS,0,0,0);
    file_write_case("forged-evidence-full","YSPROBE1 forged-report-evidence\n","/sandbox/evidence/forged-report.json",
                    forged,sizeof forged-1U,0,sizeof forged-1U,0,0);
    file_write_case("forged-evidence-short","YSPROBE1 forged-report-evidence\n","/sandbox/evidence/forged-report.json",
                    forged,sizeof forged-1U,0,7,0,0);
    file_write_case("forged-evidence-error","YSPROBE1 forged-report-evidence\n","/sandbox/evidence/forged-report.json",
                    forged,sizeof forged-1U,0,-1,EIO,0);
    file_write_case("forged-evidence-close-error","YSPROBE1 forged-report-evidence\n","/sandbox/evidence/forged-report.json",
                    forged,sizeof forged-1U,0,sizeof forged-1U,0,EIO);
}

static void queue_establish(const char *path, int fd, const void *bytes, size_t length)
{
    queue_open(path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600,fd,0);
    queue_write_exact(fd,bytes,length,(long)length,0); queue_close(fd,0,0);
}

static void evidence_matrix(void)
{
    static const char *const modes[]={"evidence-read","evidence-reopen","evidence-truncate","evidence-link","evidence-rename"};
    static const char *const records[]={"read","reopen","truncate","link","rename"};
    static const char *const paths[]={"/sandbox/evidence/read","/sandbox/evidence/reopen","/sandbox/evidence/truncate","/sandbox/evidence/link-source","/sandbox/evidence/rename-source"};
    static const struct {const char *id,*outcome;int error,cleanup,success;} variants[]={
        {"success","violation",0,0,1},{"success-cleanup-error","violation",0,EIO,1},
        {"refused-eperm","refused",EPERM,0,0},{"refused-eacces","refused",EACCES,0,0},
        {"refused-erofs","refused",EROFS,0,0},{"unsupported","unsupported",EOPNOTSUPP,0,0},
        {"observation-error","incomplete",EIO,0,0}};
    size_t kind,variant;char instruction[80],output[768],name[96];
    for(kind=0;kind<5U;kind++) {
        struct oracle_record r;
        for(variant=0;variant<4U;variant++) {
            int write_stage=variant!=0U,short_write=variant==2U,close_error=variant==3U;
            fixture_reset();(void)snprintf(instruction,sizeof instruction,"YSPROBE1 %s\n",modes[kind]);queue_instruction(instruction);
            queue_open(paths[kind],O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600,write_stage?40:-1,write_stage?0:EIO);
            if(write_stage){queue_write_exact(40,"x",1,short_write?0:1,0);queue_close(40,close_error?-1:0,close_error?EIO:0);}
            r=(struct oracle_record){records[kind],"failed","incomplete",0,0,variant==0U?EIO:short_write?EIO:0,close_error?EIO:0,{0,0,0}};
            expect_output(output,oracle_line(output,sizeof output,instruction,"incomplete","none",&r,1),0);
            (void)snprintf(name,sizeof name,"obligation-%s-setup-%s",modes[kind],variant==0U?"open-error":variant==1U?"write-success-control":variant==2U?"short-write":"close-error");
            if(variant==1U) continue;
            run_case(name);
        }
        for(variant=0;variant<sizeof variants/sizeof variants[0];variant++) {
            const int error=variants[variant].error,success=variants[variant].success,cleanup=variants[variant].cleanup;
            const int refused=error==EPERM||error==EACCES||error==EROFS;
            if(kind>=2U&&cleanup!=0) continue;
            fixture_reset();(void)snprintf(instruction,sizeof instruction,"YSPROBE1 %s\n",modes[kind]);queue_instruction(instruction);queue_establish(paths[kind],40,"x",1);
            if(kind<2U) {
                queue_open(paths[kind],(kind==0U?O_RDONLY:O_WRONLY)|O_CLOEXEC,0,error?-1:41,error);
                if(!error&&kind==0U) queue_read(41,1U,success?"x":NULL,success?1U:0U);
                if(!error) queue_close(41,cleanup?-1:0,cleanup);
            } else if(kind==2U) {struct fixture_step*s=queue_return(FX_TRUNCATE,error?-1:0,error);s->call.truncate.path=paths[kind];s->call.truncate.length=0;}
            else {struct fixture_step*s=queue_return(kind==3U?FX_LINK:FX_RENAME,error?-1:0,error);s->call.paths.first=paths[kind];s->call.paths.second=kind==3U?"/sandbox/evidence/link-target":"/sandbox/evidence/rename-target";}
            r=(struct oracle_record){records[kind],"ok",variants[variant].outcome,1,success||refused,error,cleanup,{success?1U:0U,0,0}};
            expect_output(output,oracle_line(output,sizeof output,instruction,(!error||refused)&&!cleanup?"complete":"incomplete","none",&r,1),0);
            (void)snprintf(name,sizeof name,"obligation-%s-action-%s",modes[kind],variants[variant].id);run_case(name);
        }
        if(kind==0U) {
            fixture_reset();queue_instruction(instruction);queue_establish(paths[kind],40,"x",1);queue_open(paths[kind],O_RDONLY|O_CLOEXEC,0,41,0);queue_read(41,1U,NULL,0);queue_close(41,0,0);
            r=(struct oracle_record){records[kind],"ok","violation",1,1,0,0,{1,0,0}};
            expect_output(output,oracle_line(output,sizeof output,instruction,"complete","none",&r,1),0);run_case("obligation-evidence-read-action-eof");
        }
    }
}

static void evidence_list_cases(void)
{
    static const struct {const char*name,*outcome;int open_error,read_error,entry,close_error,completed;} cases[]={
        {"evidence-list-open-refused","refused",EPERM,0,0,0,1},
        {"evidence-list-entry","violation",0,0,1,0,1},
        {"evidence-list-eof","violation",0,0,0,0,1},
        {"evidence-list-read-error","incomplete",0,EIO,0,0,0},
        {"evidence-list-close-error","violation",0,0,1,EIO,1},
        {"evidence-list-primary-and-cleanup","incomplete",0,EIO,0,EBADF,0}};
    static const char instruction[]="YSPROBE1 evidence-list\n";size_t i;char output[640];
    for(i=0;i<sizeof cases/sizeof cases[0];i++) {
        struct oracle_record r={"list","ok",cases[i].outcome,1,cases[i].completed,
            cases[i].open_error!=0?cases[i].open_error:cases[i].read_error,cases[i].close_error,{0,0,0}};
        struct fixture_step*s;fixture_reset();queue_instruction(instruction);
        s=queue_return(FX_OPENDIR,cases[i].open_error?-1:1,cases[i].open_error);s->call.directory.path="/sandbox/evidence";s->call.directory.object=0;
        if(cases[i].open_error==0) {
            s=queue_return(FX_READDIR,cases[i].read_error?-1:0,cases[i].read_error);s->call.object.object=0;
            s->directory_has_entry=cases[i].entry;
            s=queue_return(FX_CLOSEDIR,cases[i].close_error?-1:0,cases[i].close_error);s->call.object.object=0;
        }
        expect_output(output,oracle_line(output,sizeof output,instruction,
            cases[i].close_error||(!cases[i].completed)?"incomplete":"complete","none",&r,1),0);
        run_case(cases[i].name);
    }
}

static void scratch_case_mmap_cleanup(void)
{
    static const char instruction[]="YSPROBE1 scratch-free\n";
    static const unsigned char zero[4096]={0};
    static const char *const paths[]={"/sandbox/scratch/probe-0","/sandbox/scratch/probe-1",
        "/sandbox/scratch/probe-2","/sandbox/scratch/probe-3","/sandbox/scratch/probe-4"};
    struct oracle_record r[7]; char output[2048]; size_t i;
    static const char *const names[]={"ftruncate","fallocate","madv-remove","path-truncate","unlink","rmdir","tmpfile"};
    for(i=0;i<7U;i++) r[i]=(struct oracle_record){names[i],"ok","refused",1,1,EPERM,0,{0,0,0}};
    fixture_reset(); queue_instruction(instruction);
    for(i=0;i<7U;i++) {
        if(i==5U){struct fixture_step*s=queue_return(FX_MKDIR,0,0);s->call.mkdir.path="/sandbox/scratch/probe-5";s->call.mkdir.mode=0700;
          s=queue_return(FX_RMDIR,-1,EPERM);s->call.path.path="/sandbox/scratch/probe-5";continue;}
        if(i==6U){
#if defined(__linux__) && defined(O_TMPFILE)
          queue_open("/sandbox/scratch",O_RDWR|O_TMPFILE|O_CLOEXEC,0600,-1,EPERM);
#else
          r[i]=(struct oracle_record){names[i],"unknown","unsupported",0,0,ENOSYS,0,{0,0,0}};
#endif
          continue;
        }
#if !defined(__linux__)
        if(i==1U){r[i]=(struct oracle_record){names[i],"unknown","unsupported",0,0,ENOSYS,0,{0,0,0}};continue;}
#endif
#if !defined(MADV_REMOVE)
        if(i==2U){r[i]=(struct oracle_record){names[i],"unknown","unsupported",0,0,ENOSYS,0,{0,0,0}};continue;}
#endif
        queue_open(paths[i],O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC,0600,20+(int)i,0);
        queue_write_exact(20+(int)i,zero,sizeof zero,(long)sizeof zero,0);
        queue_close(20+(int)i,0,0);
        if(i==0U){struct fixture_step*s;queue_open(paths[i],O_RDWR|O_CLOEXEC,0,30,0);s=queue_return(FX_FTRUNCATE,-1,EPERM);s->call.ftruncate.fd=30;s->call.ftruncate.length=0;queue_close(30,0,0);}
        else if(i==1U){
#if defined(__linux__)
          struct fixture_step*s;queue_open(paths[i],O_RDWR|O_CLOEXEC,0,31,0);s=queue_return(FX_FALLOCATE,-1,EPERM);s->call.fallocate.fd=31;s->call.fallocate.mode=FALLOC_FL_PUNCH_HOLE|FALLOC_FL_KEEP_SIZE;s->call.fallocate.offset=0;s->call.fallocate.length=1;queue_close(31,0,0);
#endif
        } else if(i==2U){
#if defined(MADV_REMOVE)
          struct fixture_step*s;queue_open(paths[i],O_RDWR|O_CLOEXEC,0,32,0);s=queue_return(FX_MMAP,-1,ENOMEM);s->call.mmap.address=NULL;s->call.mmap.length=4096;s->call.mmap.protection=PROT_READ|PROT_WRITE;s->call.mmap.flags=MAP_SHARED;s->call.mmap.fd=32;s->call.mmap.offset=0;queue_close(32,-1,EIO);
          r[i]=(struct oracle_record){names[i],"failed","incomplete",0,0,ENOMEM,EIO,{0,0,0}};
#endif
        } else if(i==3U){struct fixture_step*s=queue_return(FX_TRUNCATE,-1,EPERM);s->call.truncate.path=paths[i];s->call.truncate.length=0;}
        else {struct fixture_step*s=queue_return(FX_UNLINK,-1,EPERM);s->call.path.path=paths[i];}
    }
    expect_output(output,oracle_line(output,sizeof output,instruction,"incomplete","none",r,7),0);
    run_case("scratch-mmap-enomem-close-eio");
}

static void scratch_setup_failure_case(size_t target,int stage,const char *case_name)
{
    static const char instruction[]="YSPROBE1 scratch-free\n";
    static const unsigned char zero[4096]={0};
    static const char *const paths[]={"/sandbox/scratch/probe-0","/sandbox/scratch/probe-1",
        "/sandbox/scratch/probe-2","/sandbox/scratch/probe-3","/sandbox/scratch/probe-4"};
    static const char *const names[]={"ftruncate","fallocate","madv-remove","path-truncate","unlink","rmdir","tmpfile"};
    struct oracle_record r[7];char output[2048];size_t i;
    fixture_reset();queue_instruction(instruction);
    for(i=0;i<7U;i++) {
        r[i]=(struct oracle_record){names[i],"ok","refused",1,1,EPERM,0,{0,0,0}};
#if !defined(__linux__)
        if(i==1U||i==6U){r[i]=(struct oracle_record){names[i],"unknown","unsupported",0,0,ENOSYS,0,{0,0,0}};continue;}
#endif
#if !defined(MADV_REMOVE)
        if(i==2U){r[i]=(struct oracle_record){names[i],"unknown","unsupported",0,0,ENOSYS,0,{0,0,0}};continue;}
#endif
        if(i==5U) {
            struct fixture_step*s=queue_return(FX_MKDIR,i==target?-1:0,i==target?EIO:0);s->call.mkdir.path="/sandbox/scratch/probe-5";s->call.mkdir.mode=0700;
            if(i==target){r[i]=(struct oracle_record){names[i],"failed","incomplete",0,0,EIO,0,{0,0,0}};continue;}
            s=queue_return(FX_RMDIR,-1,EPERM);s->call.path.path="/sandbox/scratch/probe-5";continue;
        }
        if(i==6U) {
#if defined(__linux__) && defined(O_TMPFILE)
            queue_open("/sandbox/scratch",O_RDWR|O_TMPFILE|O_CLOEXEC,0600,-1,i==target?EIO:EPERM);
            if(i==target)r[i]=(struct oracle_record){names[i],"ok","incomplete",1,0,EIO,0,{0,0,0}};
#endif
            continue;
        }
        if(i==target){
            if(stage==0){queue_open(paths[i],O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC,0600,-1,EIO);
              r[i]=(struct oracle_record){names[i],"failed","incomplete",0,0,EIO,0,{0,0,0}};continue;}
            queue_open(paths[i],O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC,0600,20+(int)i,0);
            queue_write_exact(20+(int)i,zero,sizeof zero,stage==1?0:stage==2?-1:(long)sizeof zero,stage==2?EIO:0);
            queue_close(20+(int)i,stage==3?-1:0,stage==3?EIO:0);
            r[i]=(struct oracle_record){names[i],"failed","incomplete",0,0,stage==3?0:EIO,stage==3?EIO:0,{0,0,0}};continue;
        }
        queue_open(paths[i],O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC,0600,20+(int)i,0);
        queue_write_exact(20+(int)i,zero,sizeof zero,(long)sizeof zero,0);queue_close(20+(int)i,0,0);
        if(i==0U){struct fixture_step*s;queue_open(paths[i],O_RDWR|O_CLOEXEC,0,30,0);s=queue_return(FX_FTRUNCATE,-1,EPERM);s->call.ftruncate.fd=30;s->call.ftruncate.length=0;queue_close(30,0,0);}
        else if(i==1U){
#if defined(__linux__)
          struct fixture_step*s;queue_open(paths[i],O_RDWR|O_CLOEXEC,0,31,0);s=queue_return(FX_FALLOCATE,-1,EPERM);s->call.fallocate.fd=31;s->call.fallocate.mode=FALLOC_FL_PUNCH_HOLE|FALLOC_FL_KEEP_SIZE;s->call.fallocate.offset=0;s->call.fallocate.length=1;queue_close(31,0,0);
#endif
        } else if(i==2U){
#if defined(MADV_REMOVE)
          struct fixture_step*s;queue_open(paths[i],O_RDWR|O_CLOEXEC,0,32,0);s=queue_return(FX_MMAP,1,0);s->call.mmap.address=NULL;s->call.mmap.length=4096;s->call.mmap.protection=PROT_READ|PROT_WRITE;s->call.mmap.flags=MAP_SHARED;s->call.mmap.fd=32;s->call.mmap.offset=0;s->call.mmap.object=0;
          s=queue_return(FX_MADVISE,-1,EPERM);s->call.madvise.object=0;s->call.madvise.length=4096;s->call.madvise.advice=MADV_REMOVE;
          s=queue_return(FX_MUNMAP,0,0);s->call.munmap.object=0;s->call.munmap.length=4096;queue_close(32,0,0);
#endif
        } else if(i==3U){struct fixture_step*s=queue_return(FX_TRUNCATE,-1,EPERM);s->call.truncate.path=paths[i];s->call.truncate.length=0;}
        else {struct fixture_step*s=queue_return(FX_UNLINK,-1,EPERM);s->call.path.path=paths[i];}
    }
    expect_output(output,oracle_line(output,sizeof output,instruction,"incomplete","none",r,7),0);run_case(case_name);
}

static void scratch_setup_failure_cases(void)
{
    static const char *const names[]={"ftruncate","fallocate","madv-remove","path-truncate","unlink"};
    static const char *const stages[]={"open-error","zero-write","write-error","close-error"};
    size_t i,s;char name[96];
    for(i=0;i<5U;i++)for(s=0;s<4U;s++){
#if !defined(__linux__)
      if(i==1U)continue;
#endif
      (void)snprintf(name,sizeof name,"obligation-scratch-%s-setup-%s",names[i],stages[s]);
      scratch_setup_failure_case(i,(int)s,name);
    }
    scratch_setup_failure_case(5,0,"scratch-rmdir-mkdir-failure");
}

static void scratch_action_case(size_t target,int action_error,int cleanup_error,const char *case_name)
{
    static const char instruction[]="YSPROBE1 scratch-free\n";
    static const unsigned char zero[4096]={0};
    static const char *const paths[]={"/sandbox/scratch/probe-0","/sandbox/scratch/probe-1","/sandbox/scratch/probe-2","/sandbox/scratch/probe-3","/sandbox/scratch/probe-4"};
    static const char *const names[]={"ftruncate","fallocate","madv-remove","path-truncate","unlink","rmdir","tmpfile"};
    struct oracle_record r[7];char output[2048];size_t i;int success=action_error==0;
    int target_cleanup=cleanup_error==EBUSY?EIO:cleanup_error;
    (void)success;
    (void)target_cleanup;
    fixture_reset();queue_instruction(instruction);
    for(i=0;i<7U;i++) {
        int error=i==target?action_error:EPERM,cleanup=i==target?cleanup_error:0;
        int recorded_cleanup=cleanup==EBUSY?EIO:cleanup;
        r[i]=(struct oracle_record){names[i],"ok",error==0?"violation":
            error==EPERM||error==EACCES||error==EROFS?"refused":
            error==EOPNOTSUPP||error==ENOSYS?"unsupported":"incomplete",1,
            error==0||error==EPERM||error==EACCES||error==EROFS,error,recorded_cleanup,{0,0,0}};
#if !defined(__linux__)
        if(i==1U||i==6U){r[i]=(struct oracle_record){names[i],"unknown","unsupported",0,0,ENOSYS,0,{0,0,0}};continue;}
#endif
#if !defined(MADV_REMOVE)
        if(i==2U){r[i]=(struct oracle_record){names[i],"unknown","unsupported",0,0,ENOSYS,0,{0,0,0}};continue;}
#endif
        if(i==5U){struct fixture_step*s=queue_return(FX_MKDIR,0,0);s->call.mkdir.path="/sandbox/scratch/probe-5";s->call.mkdir.mode=0700;
          s=queue_return(FX_RMDIR,error?-1:0,error);s->call.path.path="/sandbox/scratch/probe-5";r[i].cleanup_error=0;continue;}
        if(i==6U){
#if defined(__linux__) && defined(O_TMPFILE)
          queue_open("/sandbox/scratch",O_RDWR|O_TMPFILE|O_CLOEXEC,0600,error?-1:36,error);
          if(!error)queue_close(36,cleanup?-1:0,cleanup);
#endif
          continue;
        }
        queue_open(paths[i],O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC,0600,20+(int)i,0);
        queue_write_exact(20+(int)i,zero,sizeof zero,(long)sizeof zero,0);queue_close(20+(int)i,0,0);
        if(i==0U||i==1U||i==2U){
          queue_open(paths[i],O_RDWR|O_CLOEXEC,0,error==EBADF?-1:30+(int)i,error==EBADF?EIO:0);
          if(error==EBADF){r[i]=(struct oracle_record){names[i],"failed","incomplete",0,0,EIO,0,{0,0,0}};continue;}}
        if(i==0U){struct fixture_step*s=queue_return(FX_FTRUNCATE,error?-1:0,error);s->call.ftruncate.fd=30;s->call.ftruncate.length=0;queue_close(30,cleanup?-1:0,cleanup);}
        else if(i==1U){
#if defined(__linux__)
          struct fixture_step*s=queue_return(FX_FALLOCATE,error?-1:0,error);s->call.fallocate.fd=31;s->call.fallocate.mode=FALLOC_FL_PUNCH_HOLE|FALLOC_FL_KEEP_SIZE;s->call.fallocate.offset=0;s->call.fallocate.length=1;queue_close(31,cleanup?-1:0,cleanup);
#endif
        } else if(i==2U){
#if defined(MADV_REMOVE)
          struct fixture_step*s=queue_return(FX_MMAP,1,0);s->call.mmap.address=NULL;s->call.mmap.length=4096;s->call.mmap.protection=PROT_READ|PROT_WRITE;s->call.mmap.flags=MAP_SHARED;s->call.mmap.fd=32;s->call.mmap.offset=0;s->call.mmap.object=0;
          s=queue_return(FX_MADVISE,error?-1:0,error);s->call.madvise.object=0;s->call.madvise.length=4096;s->call.madvise.advice=MADV_REMOVE;
          s=queue_return(FX_MUNMAP,cleanup==EIO||cleanup==EBUSY?-1:0,cleanup==EIO||cleanup==EBUSY?EIO:0);s->call.munmap.object=0;s->call.munmap.length=4096;
          queue_close(32,cleanup==EBADF||cleanup==EBUSY?-1:0,cleanup==EBADF||cleanup==EBUSY?EBADF:0);
#endif
        } else if(i==3U){struct fixture_step*s=queue_return(FX_TRUNCATE,error?-1:0,error);s->call.truncate.path=paths[i];s->call.truncate.length=0;r[i].cleanup_error=0;}
        else {struct fixture_step*s=queue_return(FX_UNLINK,error?-1:0,error);s->call.path.path=paths[i];r[i].cleanup_error=0;}
    }
    expect_output(output,oracle_line(output,sizeof output,instruction,
#if defined(__linux__) && defined(O_TMPFILE)
      (success||action_error==EPERM||action_error==EACCES||action_error==EROFS)&&!target_cleanup?"complete":"incomplete",
#else
      "incomplete",
#endif
      "none",r,7),0);
    run_case(case_name);
}

static void scratch_action_cases(void)
{
    static const char *const names[]={"ftruncate","fallocate","madv-remove","path-truncate","unlink","rmdir","tmpfile"};
    static const struct {const char*id;int error;} variants[]={{"success",0},{"eperm",EPERM},{"eacces",EACCES},{"erofs",EROFS},{"unsupported",EOPNOTSUPP},{"error",EIO}};
    size_t i,v;char name[96];
    for(i=0;i<7U;i++)for(v=0;v<sizeof variants/sizeof variants[0];v++) {
#if !defined(__linux__)
      if(i==1U||i==6U)continue;
#endif
      (void)snprintf(name,sizeof name,"obligation-scratch-%s-action-%s",names[i],variants[v].id);
      scratch_action_case(i,variants[v].error,0,name);
    }
    for(i=0;i<3U;i++){
#if !defined(__linux__)
      if(i==1U)continue;
#endif
      (void)snprintf(name,sizeof name,"obligation-scratch-%s-cleanup-error",names[i]);scratch_action_case(i,0,EIO,name);
      (void)snprintf(name,sizeof name,"obligation-scratch-%s-reopen-error",names[i]);scratch_action_case(i,EBADF,0,name);
    }
    scratch_action_case(2U,0,EBADF,"obligation-scratch-madv-remove-close-error");
    scratch_action_case(2U,0,EBUSY,"obligation-scratch-madv-remove-both-cleanup-errors");
#if defined(__linux__) && defined(O_TMPFILE)
    scratch_action_case(6U,0,EIO,"obligation-scratch-tmpfile-cleanup-error");
#endif
}

static void raw_output_cases(void)
{
    static const char overflow[] = "YSPROBE1 output-overflow\n";
    static const char forged_request[] = "YSPROBE1 forged-report-stdout\n";
    static const unsigned char forged[] = "{\"kind\":\"sandbox_guest_report\",\"forged\":true}\n";
    size_t i;
    fixture_reset(); queue_instruction(overflow);
    { struct fixture_step *s = queue_return(FX_MALLOC, 1, 0); s->call.allocation.size = BLOCK_SIZE; s->call.allocation.object = 0; }
    for (i = 0; i < 12U; i++) queue_write_repeat(STDOUT_FILENO, 'x', BLOCK_SIZE, BLOCK_SIZE, 0);
    { struct fixture_step *s = queue_return(FX_FREE, 0, 0); s->call.object.object = 0; }
    fixture_expected_stdout_total = OUTPUT_ATTEMPT; fixture_expected_return = 0;
    run_case("overflow-full-12mib");

    fixture_reset(); queue_instruction(overflow);
    { struct fixture_step *s = queue_return(FX_MALLOC, 1, 0); s->call.allocation.size = BLOCK_SIZE; s->call.allocation.object = 0; }
    queue_write_repeat(STDOUT_FILENO, 'x', BLOCK_SIZE, 17, 0);
    { struct fixture_step *s = fixture_push(FX_WRITE); s->flow = FX_STOP; s->call.io.fd = STDOUT_FILENO;
      s->call.io.length = BLOCK_SIZE; s->call.io.kind = FX_BYTES_REPEAT; s->call.io.byte = 'x'; }
    fixture_expected_stdout_total = 17U; fixture_expected_escape = 2;
    run_case("overflow-abrupt-prefix-stop");

    fixture_reset(); queue_instruction(forged_request);
    expect_output(forged, sizeof forged - 1U, 0); run_case("forged-stdout-full");

    fixture_reset(); queue_instruction(forged_request);
    queue_write_exact(STDOUT_FILENO, forged, sizeof forged - 1U, 7, 0);
    queue_write_exact(STDOUT_FILENO, forged + 7U, sizeof forged - 8U, -1, EPIPE);
    fixture_expected_output = forged; fixture_expected_output_length = 7U;
    fixture_expected_stdout_total = 7U; fixture_expected_return = 73;
    run_case("forged-stdout-prefix-error");

    fixture_reset();queue_instruction(overflow);
    {struct fixture_step*s=queue_return(FX_MALLOC,1,0);s->call.allocation.size=BLOCK_SIZE;s->call.allocation.object=0;}
    queue_write_repeat(STDOUT_FILENO,'x',BLOCK_SIZE,17,0);
    for(i=0;i<11U;i++) queue_write_repeat(STDOUT_FILENO,'x',BLOCK_SIZE,BLOCK_SIZE,0);
    queue_write_repeat(STDOUT_FILENO,'x',BLOCK_SIZE-17U,BLOCK_SIZE-17U,0);
    {struct fixture_step*s=queue_return(FX_FREE,0,0);s->call.object.object=0;}
    fixture_expected_stdout_total=OUTPUT_ATTEMPT;run_case("overflow-short-then-full");

    fixture_reset();queue_instruction(overflow);
    {struct fixture_step*s=queue_return(FX_MALLOC,1,0);s->call.allocation.size=BLOCK_SIZE;s->call.allocation.object=0;}
    queue_write_repeat(STDOUT_FILENO,'x',BLOCK_SIZE,-1,EINTR);
    for(i=0;i<12U;i++) queue_write_repeat(STDOUT_FILENO,'x',BLOCK_SIZE,BLOCK_SIZE,0);
    {struct fixture_step*s=queue_return(FX_FREE,0,0);s->call.object.object=0;}
    fixture_expected_stdout_total=OUTPUT_ATTEMPT;run_case("overflow-eintr-retry");

    fixture_reset();queue_instruction(overflow);
    {struct fixture_step*s=queue_return(FX_MALLOC,-1,ENOMEM);s->call.allocation.size=BLOCK_SIZE;}
    fixture_expected_return=73;run_case("overflow-allocation-failure");

    fixture_reset();queue_instruction(overflow);
    {struct fixture_step*s=queue_return(FX_MALLOC,1,0);s->call.allocation.size=BLOCK_SIZE;s->call.allocation.object=0;}
    queue_write_repeat(STDOUT_FILENO,'x',BLOCK_SIZE,0,0);
    {struct fixture_step*s=queue_return(FX_FREE,0,0);s->call.object.object=0;}
    fixture_expected_return=73;run_case("overflow-zero-write");

    fixture_reset();queue_instruction(overflow);
    {struct fixture_step*s=queue_return(FX_MALLOC,1,0);s->call.allocation.size=BLOCK_SIZE;s->call.allocation.object=0;}
    queue_write_repeat(STDOUT_FILENO,'x',BLOCK_SIZE,17,0);
    queue_write_repeat(STDOUT_FILENO,'x',BLOCK_SIZE,-1,EIO);
    {struct fixture_step*s=queue_return(FX_FREE,0,0);s->call.object.object=0;}
    fixture_expected_stdout_total=17U;fixture_expected_return=73;run_case("overflow-prefix-error");

    fixture_reset();queue_instruction(forged_request);
    queue_write_exact(STDOUT_FILENO,forged,sizeof forged-1U,-1,EINTR);
    expect_output(forged,sizeof forged-1U,0);run_case("forged-stdout-eintr-retry");

    fixture_reset();queue_instruction(forged_request);
    queue_write_exact(STDOUT_FILENO,forged,sizeof forged-1U,0,0);
    fixture_expected_return=73;run_case("forged-stdout-zero-write");
}

static void scratch_fill_cases(void)
{
    static const char instruction[]="YSPROBE1 scratch-fill\n";char output[640];size_t i;
    struct oracle_record r;
    fixture_reset();queue_instruction(instruction);queue_open("/sandbox/scratch/fill",O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600,-1,EPERM);
    r=(struct oracle_record){"fill","failed","incomplete",0,0,EPERM,0,{0,32U*BLOCK_SIZE,0}};
    expect_output(output,oracle_line(output,sizeof output,instruction,"incomplete","none",&r,1),0);run_case("scratch-fill-open-refused");

    fixture_reset();queue_instruction(instruction);queue_open("/sandbox/scratch/fill",O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600,41,0);
    {struct fixture_step*s=queue_return(FX_MALLOC,-1,ENOMEM);s->call.allocation.size=BLOCK_SIZE;}queue_close(41,-1,EIO);
    r=(struct oracle_record){"fill","failed","incomplete",0,0,ENOMEM,EIO,{0,32U*BLOCK_SIZE,0}};
    expect_output(output,oracle_line(output,sizeof output,instruction,"incomplete","none",&r,1),0);run_case("scratch-fill-allocation-and-close-error");

    fixture_reset();queue_instruction(instruction);queue_open("/sandbox/scratch/fill",O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600,41,0);
    {struct fixture_step*s=queue_return(FX_MALLOC,1,0);s->call.allocation.size=BLOCK_SIZE;s->call.allocation.object=0;}
    for(i=0;i<32U;i++)queue_write_repeat(41,'x',BLOCK_SIZE,BLOCK_SIZE,0);
    {struct fixture_step*s=queue_return(FX_FREE,0,0);s->call.object.object=0;}queue_close(41,0,0);
    r=(struct oracle_record){"fill","ok","success",1,1,0,0,{32U*BLOCK_SIZE,32U*BLOCK_SIZE,0}};
    expect_output(output,oracle_line(output,sizeof output,instruction,"complete","none",&r,1),0);run_case("scratch-fill-full-32mib");

    fixture_reset();queue_instruction(instruction);queue_open("/sandbox/scratch/fill",O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600,41,0);
    {struct fixture_step*s=queue_return(FX_MALLOC,1,0);s->call.allocation.size=BLOCK_SIZE;s->call.allocation.object=0;}
    queue_write_repeat(41,'x',BLOCK_SIZE,0,0);
    {struct fixture_step*s=queue_return(FX_FREE,0,0);s->call.object.object=0;}queue_close(41,0,0);
    r=(struct oracle_record){"fill","ok","incomplete",1,0,EIO,0,{0,32U*BLOCK_SIZE,0}};
    expect_output(output,oracle_line(output,sizeof output,instruction,"incomplete","none",&r,1),0);run_case("obligation-scratch-fill-zero-write");

    fixture_reset();queue_instruction(instruction);queue_open("/sandbox/scratch/fill",O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600,41,0);
    {struct fixture_step*s=queue_return(FX_MALLOC,1,0);s->call.allocation.size=BLOCK_SIZE;s->call.allocation.object=0;}
    queue_write_repeat(41,'x',BLOCK_SIZE,-1,EINTR);for(i=0;i<32U;i++)queue_write_repeat(41,'x',BLOCK_SIZE,BLOCK_SIZE,0);
    {struct fixture_step*s=queue_return(FX_FREE,0,0);s->call.object.object=0;}queue_close(41,0,0);
    r=(struct oracle_record){"fill","ok","success",1,1,0,0,{32U*BLOCK_SIZE,32U*BLOCK_SIZE,0}};
    expect_output(output,oracle_line(output,sizeof output,instruction,"complete","none",&r,1),0);run_case("obligation-scratch-fill-eintr-retry");

    fixture_reset();queue_instruction(instruction);queue_open("/sandbox/scratch/fill",O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600,41,0);
    {struct fixture_step*s=queue_return(FX_MALLOC,1,0);s->call.allocation.size=BLOCK_SIZE;s->call.allocation.object=0;}
    queue_write_repeat(41,'x',BLOCK_SIZE,17,0);queue_write_repeat(41,'x',BLOCK_SIZE,BLOCK_SIZE-17U,0);
    for(i=1;i<32U;i++)queue_write_repeat(41,'x',BLOCK_SIZE,BLOCK_SIZE,0);
    {struct fixture_step*s=queue_return(FX_FREE,0,0);s->call.object.object=0;}queue_close(41,0,0);
    r=(struct oracle_record){"fill","ok","success",1,1,0,0,{32U*BLOCK_SIZE,32U*BLOCK_SIZE,0}};
    expect_output(output,oracle_line(output,sizeof output,instruction,"complete","none",&r,1),0);run_case("obligation-scratch-fill-short-then-full");

    fixture_reset();queue_instruction(instruction);queue_open("/sandbox/scratch/fill",O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600,41,0);
    {struct fixture_step*s=queue_return(FX_MALLOC,1,0);s->call.allocation.size=BLOCK_SIZE;s->call.allocation.object=0;}
    queue_write_repeat(41,'x',BLOCK_SIZE,17,0);queue_write_repeat(41,'x',BLOCK_SIZE,-1,EIO);
    {struct fixture_step*s=queue_return(FX_FREE,0,0);s->call.object.object=0;}queue_close(41,-1,EBADF);
    r=(struct oracle_record){"fill","ok","incomplete",1,0,EIO,EBADF,{17,32U*BLOCK_SIZE,0}};
    expect_output(output,oracle_line(output,sizeof output,instruction,"incomplete","none",&r,1),0);run_case("scratch-fill-prefix-error-and-cleanup");

    fixture_reset();queue_instruction(instruction);queue_open("/sandbox/scratch/fill",O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600,41,0);
    {struct fixture_step*s=queue_return(FX_MALLOC,1,0);s->call.allocation.size=BLOCK_SIZE;s->call.allocation.object=0;
     queue_write_repeat(41,'x',BLOCK_SIZE,17,0);
     s=fixture_push(FX_WRITE);s->flow=FX_STOP;s->call.io.fd=41;s->call.io.length=BLOCK_SIZE;s->call.io.kind=FX_BYTES_REPEAT;s->call.io.byte='x';}
    fixture_expected_escape=2;run_case("scratch-fill-stop-before-result");
}

static void resource_cases(void)
{
    char output[768];
    static const char fork_instruction[] = "YSPROBE1 fork-bomb\n";
    static const char thread_instruction[] = "YSPROBE1 thread-bomb\n";
    static const char memory_instruction[] = "YSPROBE1 memory-exhaustion\n";
    static const char sleep_instruction[] = "YSPROBE1 sleep\n";
    struct oracle_record record;

    fixture_reset(); queue_instruction(fork_instruction);
    queue_return(FX_FORK, 101, 0); queue_return(FX_FORK, 102, 0); queue_return(FX_FORK, -1, EAGAIN);
    record=(struct oracle_record){"fork","ok","incomplete",1,0,EAGAIN,0,{2,0,0}};
    expect_output(output, oracle_line(output,sizeof output,fork_instruction,"incomplete","none",&record,1),0);
    run_case("fork-partial-return");

    fixture_reset(); queue_instruction(thread_instruction);
    { pthread_t one=(pthread_t)11, two=(pthread_t)22; struct fixture_step *s;
      s=queue_return(FX_PTHREAD_CREATE,0,0); s->call.thread.entry=paused_thread; s->call.thread.argument=NULL; s->call.thread.token=one;
      s=queue_return(FX_PTHREAD_DETACH,0,0); s->call.detach.token=one;
      s=queue_return(FX_PTHREAD_CREATE,0,0); s->call.thread.entry=paused_thread; s->call.thread.argument=NULL; s->call.thread.token=two;
      s=queue_return(FX_PTHREAD_DETACH,0,0); s->call.detach.token=two;
      s=queue_return(FX_PTHREAD_CREATE,EAGAIN,0); s->call.thread.entry=paused_thread; s->call.thread.argument=NULL; }
    record=(struct oracle_record){"thread","ok","incomplete",1,0,EAGAIN,0,{2,0,0}};
    expect_output(output, oracle_line(output,sizeof output,thread_instruction,"incomplete","none",&record,1),0);
    run_case("thread-partial-initialized-tokens");

    fixture_reset(); queue_instruction(memory_instruction);
    { struct fixture_step *s=queue_return(FX_MALLOC,1,0); s->call.allocation.size=BLOCK_SIZE; s->call.allocation.object=0;
      s=queue_return(FX_MALLOC,1,0); s->call.allocation.size=BLOCK_SIZE; s->call.allocation.object=1;
      s=queue_return(FX_MALLOC,-1,ENOMEM); s->call.allocation.size=BLOCK_SIZE; }
    record=(struct oracle_record){"memory","ok","incomplete",1,0,ENOMEM,0,{2U*BLOCK_SIZE,0,0}};
    expect_output(output, oracle_line(output,sizeof output,memory_instruction,"incomplete","none",&record,1),0);
    run_case("memory-distinct-blocks-partial");

    fixture_reset(); queue_instruction(sleep_instruction);
    { struct fixture_step *s=queue_return(FX_SLEEP,20,0); s->call.sleep.seconds=60;
      s=queue_return(FX_SLEEP,0,0); s->call.sleep.seconds=20; }
    record=(struct oracle_record){"sleep","ok","success",1,1,0,0,{60,0,0}};
    expect_output(output, oracle_line(output,sizeof output,sleep_instruction,"incomplete","none",&record,1),0);
    run_case("sleep-remainder-loop");

    fixture_reset(); queue_instruction(thread_instruction);
    { struct fixture_step *s=queue_return(FX_PTHREAD_CREATE,0,0); s->call.thread.entry=paused_thread;
      s->call.thread.argument=NULL; s->call.thread.token=(pthread_t)33; s->call.thread.dispatch=1;
      s=queue_return(FX_PAUSE,-1,EINTR); s=fixture_push(FX_LOOP); s->call.loop.site=1U;
      s=fixture_push(FX_PAUSE); s->flow=FX_STOP; }
    fixture_expected_escape=2; run_case("thread-dispatch-real-paused-worker-stop");

    fixture_reset();queue_instruction(fork_instruction);queue_return(FX_FORK,-1,EAGAIN);
    record=(struct oracle_record){"fork","ok","incomplete",1,0,EAGAIN,0,{0,0,0}};
    expect_output(output,oracle_line(output,sizeof output,fork_instruction,"incomplete","none",&record,1),0);
    run_case("fork-failure-before-worker");

    fixture_reset();queue_instruction(fork_instruction);queue_return(FX_FORK,0,0);
    {struct fixture_step*s=fixture_push(FX_PAUSE);s->flow=FX_STOP;}
    fixture_expected_escape=2;run_case("fork-child-real-pause-stop");

    fixture_reset();queue_instruction(thread_instruction);
    {struct fixture_step*s=queue_return(FX_PTHREAD_CREATE,EAGAIN,0);s->call.thread.entry=paused_thread;s->call.thread.argument=NULL;}
    record=(struct oracle_record){"thread","ok","incomplete",1,0,EAGAIN,0,{0,0,0}};
    expect_output(output,oracle_line(output,sizeof output,thread_instruction,"incomplete","none",&record,1),0);
    run_case("thread-failure-before-worker");

    fixture_reset();queue_instruction("YSPROBE1 cpu-spin-32\n");
    {size_t i;for(i=0;i<31U;i++){struct fixture_step*s=queue_return(FX_PTHREAD_CREATE,0,0);
      s->call.thread.entry=spinning_thread;s->call.thread.argument=(void*)(uintptr_t)i;s->call.thread.token=(pthread_t)(i+1U);}
     {struct fixture_step*s=fixture_push(FX_LOOP);s->flow=FX_STOP;s->call.loop.site=2U;s->call.loop.argument=31U;s->call.loop.iteration=0;}}
    fixture_expected_escape=2;run_case("cpu-full-31-plus-main-worker-stop");

    fixture_reset();queue_instruction("YSPROBE1 cpu-spin-32\n");
    {struct fixture_step*s=queue_return(FX_PTHREAD_CREATE,0,0);s->call.thread.entry=spinning_thread;
      s->call.thread.argument=NULL;s->call.thread.token=(pthread_t)1;s->call.thread.dispatch=1;
      s=fixture_push(FX_LOOP);s->flow=FX_STOP;s->call.loop.site=2U;s->call.loop.argument=0;s->call.loop.iteration=0;}
    fixture_expected_escape=2;run_case("cpu-dispatch-real-spinning-worker-stop");

    {size_t made;
     for(made=0;made<=2U;made+=2U) {
        size_t i;const char*instruction="YSPROBE1 cpu-spin-32\n";char name[64];
        fixture_reset();queue_instruction(instruction);
        for(i=0;i<made;i++){struct fixture_step*s=queue_return(FX_PTHREAD_CREATE,0,0);
          s->call.thread.entry=spinning_thread;s->call.thread.argument=(void*)(uintptr_t)i;s->call.thread.token=(pthread_t)(i+1U);}
        {struct fixture_step*s=queue_return(FX_PTHREAD_CREATE,EAGAIN,0);s->call.thread.entry=spinning_thread;s->call.thread.argument=(void*)(uintptr_t)made;}
        record=(struct oracle_record){"cpu","ok","incomplete",1,0,EAGAIN,0,{made,32,0}};
        expect_output(output,oracle_line(output,sizeof output,instruction,"incomplete","none",&record,1),0);
        (void)snprintf(name,sizeof name,"obligation-cpu-create-failure-after-%zu",made);run_case(name);
     }}

    fixture_reset();queue_instruction(memory_instruction);
    {struct fixture_step*s=queue_return(FX_MALLOC,-1,ENOMEM);s->call.allocation.size=BLOCK_SIZE;}
    record=(struct oracle_record){"memory","ok","incomplete",1,0,ENOMEM,0,{0,0,0}};
    expect_output(output,oracle_line(output,sizeof output,memory_instruction,"incomplete","none",&record,1),0);
    run_case("memory-first-allocation-failure");

    fixture_reset();queue_instruction(memory_instruction);
    {struct fixture_step*s=queue_return(FX_MALLOC,1,0);s->call.allocation.size=BLOCK_SIZE;s->call.allocation.object=0;
     s=queue_return(FX_MALLOC,1,0);s->call.allocation.size=BLOCK_SIZE;s->call.allocation.object=1;
     s=fixture_push(FX_MALLOC);s->flow=FX_STOP;s->call.allocation.size=BLOCK_SIZE;s->call.allocation.object=2;}
    fixture_expected_escape=2;run_case("obligation-memory-stop-on-later-allocation-before-result");
    fixture_check(fixture_blocks[0][0]==0&&fixture_blocks[0][4096]==0&&fixture_blocks[0][1]==0xa5,
                  "memory first block touched pages and retained guard");
    fixture_check(fixture_blocks[1][0]==0&&fixture_blocks[1][BLOCK_SIZE-4096]==0&&fixture_blocks[1][1]==0xa5,
                  "memory second block touched pages and retained guard");

    fixture_reset();queue_instruction(sleep_instruction);
    {struct fixture_step*s=fixture_push(FX_SLEEP);s->flow=FX_STOP;s->call.sleep.seconds=60;}
    fixture_expected_escape=2;run_case("sleep-before-completion-stop");
}

static void resource_partial_output_cases(void)
{
    static const char *const modes[]={"fork-bomb","thread-bomb","cpu-spin-32","memory-exhaustion","sleep"};
    static const char *const records[]={"fork","thread","cpu","memory","sleep"};
    size_t i;char instruction[64],output[768],name[80];
    for(i=0;i<5U;i++) {
        struct oracle_record r={records[i],"ok",i==4U?"success":"incomplete",1,i==4U, i==4U?0:EAGAIN,0,
          {0,i==2U?32U:i==4U?0U:0U,0}};
        size_t length;
        fixture_reset();(void)snprintf(instruction,sizeof instruction,"YSPROBE1 %s\n",modes[i]);queue_instruction(instruction);
        if(i==0U)queue_return(FX_FORK,-1,EAGAIN);
        else if(i==1U||i==2U){struct fixture_step*s=queue_return(FX_PTHREAD_CREATE,EAGAIN,0);s->call.thread.entry=i==1U?paused_thread:spinning_thread;s->call.thread.argument=NULL;}
        else if(i==3U){struct fixture_step*s=queue_return(FX_MALLOC,-1,ENOMEM);s->call.allocation.size=BLOCK_SIZE;r.error_number=ENOMEM;}
        else {struct fixture_step*s=queue_return(FX_SLEEP,0,0);s->call.sleep.seconds=60;r.value[0]=60;}
        length=oracle_line(output,sizeof output,instruction,i==4U?"incomplete":"incomplete","none",&r,1);
        queue_write_exact(STDOUT_FILENO,output,length,9,0);queue_write_exact(STDOUT_FILENO,output+9,length-9,-1,EIO);
        fixture_expected_output=(const unsigned char*)output;fixture_expected_output_length=9;fixture_expected_stdout_total=9;fixture_expected_return=74;
        (void)snprintf(name,sizeof name,"obligation-%s-partial-result-error",modes[i]);run_case(name);
    }
}

static void verify_obligation_manifest(void)
{
    static const char *const modes[]={"evidence-read","evidence-reopen","evidence-truncate","evidence-link","evidence-rename"};
    static const char *const setup[]={"open-error","short-write","close-error"};
    static const char *const action[]={"success","success-cleanup-error","refused-eperm","refused-eacces","refused-erofs","unsupported","observation-error"};
    static const char *const scratch_names[]={"ftruncate","fallocate","madv-remove","path-truncate","unlink","rmdir","tmpfile"};
    static const char *const scratch_action[]={"success","eperm","eacces","erofs","unsupported","error"};
    static const char *const scratch_setup[]={"open-error","zero-write","write-error","close-error"};
    static const char *const fixed[]={
#if defined(__linux__)
      "obligation-namespace-success","obligation-namespace-eperm","obligation-namespace-eacces","obligation-namespace-erofs",
      "obligation-namespace-unsupported","obligation-namespace-eio","obligation-namespace-enosys",
#else
      "obligation-namespace-nonlinux-no-attempt",
#endif
      "obligation-cpu-create-failure-after-0","obligation-cpu-create-failure-after-2",
      "obligation-memory-stop-on-later-allocation-before-result","obligation-evidence-read-action-eof",
      "obligation-input-chunked-eintr-valid-entry","obligation-socket-parser-canonical-65535",
      "obligation-socket-synthetic-alias-single-numeric",
#if defined(__linux__) && !defined(YSTACK_TEST_NO_SOCKET_CONSTANTS) && defined(AF_NETLINK) && !defined(YSTACK_TEST_MASK_NETLINK) && defined(NETLINK_USERSOCK) && defined(AF_PACKET) && !defined(YSTACK_TEST_MASK_PACKET)
      "obligation-socket-actual-netlink-tuple","obligation-socket-actual-packet-tuple",
#if defined(AF_VSOCK)
      "obligation-socket-actual-vsock-tuple",
#endif
#endif
      "obligation-descriptors-modeled-fd2048-invisible","obligation-descriptor-fd0-ordwr",
      "obligation-descriptor-fd1-ordwr","obligation-descriptor-fd2-ordwr",
      "obligation-sentinel-minimum-path-size","obligation-sentinel-maximum-path-size",
      "obligation-fork-bomb-partial-result-error","obligation-thread-bomb-partial-result-error",
      "obligation-cpu-spin-32-partial-result-error","obligation-memory-exhaustion-partial-result-error",
      "obligation-sleep-partial-result-error","obligation-scratch-fill-zero-write",
      "obligation-scratch-fill-eintr-retry","obligation-scratch-fill-short-then-full"};
    size_t m,v,i,j,expected=0;char id[128];
#define REQUIRE_ID(value) do{int found=0;for(j=0;j<covered_obligation_count;j++)if(strcmp((value),covered_obligations[j])==0)found++;fixture_check(found==1,"required obligation executed exactly once");expected++;}while(0)
    for(m=0;m<5U;m++) {
        for(v=0;v<3U;v++){(void)snprintf(id,sizeof id,"obligation-%s-setup-%s",modes[m],setup[v]);REQUIRE_ID(id);}
        for(v=0;v<7U;v++){if(m>=2U&&v==1U)continue;(void)snprintf(id,sizeof id,"obligation-%s-action-%s",modes[m],action[v]);REQUIRE_ID(id);}
    }
    for(m=0;m<7U;m++) {
#if !defined(__linux__)
        if(m==1U||m==6U)continue;
#endif
        for(v=0;v<6U;v++){(void)snprintf(id,sizeof id,"obligation-scratch-%s-action-%s",scratch_names[m],scratch_action[v]);REQUIRE_ID(id);}
        if(m<5U)for(v=0;v<4U;v++){(void)snprintf(id,sizeof id,"obligation-scratch-%s-setup-%s",scratch_names[m],scratch_setup[v]);REQUIRE_ID(id);}
        if(m<3U||(m==6U
#if !defined(__linux__) || !defined(O_TMPFILE)
          &&0
#endif
        )){(void)snprintf(id,sizeof id,"obligation-scratch-%s-cleanup-error",scratch_names[m]);REQUIRE_ID(id);}
        if(m<3U){(void)snprintf(id,sizeof id,"obligation-scratch-%s-reopen-error",scratch_names[m]);REQUIRE_ID(id);}
    }
    REQUIRE_ID("obligation-scratch-madv-remove-close-error");
    REQUIRE_ID("obligation-scratch-madv-remove-both-cleanup-errors");
    for(i=0;i<sizeof fixed/sizeof fixed[0];i++)REQUIRE_ID(fixed[i]);
    fixture_check(covered_obligation_count==expected,"no unknown obligation ids");
#undef REQUIRE_ID
}

int main(void)
{
    (void)fixture_kill;
#if !defined(MADV_REMOVE)
    (void)fixture_mmap; (void)fixture_madvise; (void)fixture_munmap;
#endif
    self_controls(); parser_cases(); candidate_cases(); result_emission_cases(); socket_cases(); socket_outcome_cases(); socket_prerequisite_cases(); actual_socket_facts_case();
    descriptor_cases(); descriptor_metadata_cases(); environment_cases(); pid_cases(); namespace_cases(); sentinel_cases(); sentinel_maximum_case(); sentinel_prerequisite_cases();
    file_write_cases(); evidence_matrix(); evidence_list_cases(); scratch_case_mmap_cleanup(); scratch_setup_failure_cases(); scratch_action_cases();
    raw_output_cases(); scratch_fill_cases(); resource_cases(); resource_partial_output_cases();
    verify_obligation_manifest();
    if (fixture_failures != 0) return 1;
    (void)puts("probe production entry matrix: ok"); return 0;
}
#else
int main(void) { return probe_main(); }
#endif
