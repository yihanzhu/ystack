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
#if defined(YSTACK_PROBE_TEST) && defined(YSTACK_TEST_DISABLE_MADV_REMOVE)
#undef MADV_REMOVE
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
    int errno_guard;
    int expected_errno_before;
    int preserve_errno;
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
static int fixture_modeled_fd2048_open, fixture_modeled_fd2048_queried;
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
    if (fd != s->call.io.fd || length != s->call.io.length) {
        (void)fprintf(stderr,"FAIL write fd=%d/%d length=%zu/%zu\n",fd,s->call.io.fd,length,s->call.io.length);
        if(fd==STDOUT_FILENO&&s->call.io.kind==FX_BYTES_EXACT)
            (void)fprintf(stderr,"ACTUAL %.*sEXPECTED %.*s",(int)length,(const char*)buffer,
                          (int)s->call.io.length,(const char*)s->call.io.bytes);
        fixture_fail("write arguments");
    }
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
    if (returned == 0 && s->stat_mode == 0) fixture_fail("fstat metadata missing");
    if (returned == 0) {
        memset(metadata, 0, sizeof *metadata);
        metadata->st_mode = s->stat_mode;
    }
    return (int)returned;
}

static int fixture_fcntl(int fd, int command)
{
    struct fixture_step *s = fixture_next(FX_FCNTL);
    if (fd == 2048) fixture_modeled_fd2048_queried = 1;
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
    struct fixture_step *s = fixture_next(FX_OPENDIR); long returned; int incoming = errno;
    if (strcmp(path, s->call.directory.path) != 0) fixture_fail("opendir path");
    if (s->errno_guard && incoming != s->expected_errno_before) fixture_fail("opendir incoming errno");
    returned = fixture_return(s);
    if (s->preserve_errno && errno != incoming) fixture_fail("opendir changed errno");
    if (returned < 0) return NULL;
    if (s->call.directory.object >= FIXTURE_OBJECTS) fixture_fail("directory object");
    return (DIR *)(void *)&fixture_directory_tokens[s->call.directory.object];
}

static struct dirent *fixture_readdir(DIR *directory)
{
    struct fixture_step *s = fixture_next(FX_READDIR); int incoming = errno;
    if (s->call.object.object >= FIXTURE_OBJECTS ||
        directory != (DIR *)(void *)&fixture_directory_tokens[s->call.object.object])
        fixture_fail("readdir object");
    if (s->errno_guard && incoming != s->expected_errno_before) fixture_fail("readdir incoming errno");
    if (s->flow == FX_STOP) fixture_stop();
    if (s->returned < 0) { errno = s->error_number; return NULL; }
    if (!s->directory_has_entry) {
        if (s->preserve_errno && errno != incoming) fixture_fail("readdir changed errno");
        return NULL;
    }
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
    if (returned == 0 && s->call.thread.token == (pthread_t)0)
        fixture_fail("pthread_create token missing");
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
static void *fixture_returning_thread(void *argument) { return argument; }
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
               n >= 0 ? (success_expected ? (write_data != NULL && (size_t)n < write_length ?
                                             OUT_INCOMPLETE : OUT_SUCCESS) : OUT_VIOLATION) :
               (write_data != NULL ? (success_expected ? OUT_INCOMPLETE : OUT_VIOLATION) :
                classify_errno(primary)),
               primary, cleanup, n > 0 ? (uint64_t)n : 0U, n > 0 && do_read ? byte : 0U, 0);
}

static int establish_empty(const char *path, int *cleanup_error)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600); ssize_t n; int saved;
    *cleanup_error = 0; if (fd < 0) return errno;
    n = write(fd, "x", 1U);
    saved = n == 1 ? 0 : n < 0 ? errno : EIO;
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
    if (saved != 0) add_record(result, "read", PRE_OK, 1, 0, classify_errno(saved), saved, cleanup, used, request->size, 0);
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
                    0, forged, sizeof forged - 1U, 1);
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

enum obligation_state { OB_RUNTIME, OB_EXTERNAL, OB_BLOCKED };
struct obligation_binding { const char *id; unsigned char family, state, seen; };
static struct obligation_binding obligation_registry[] = {
    {"M01", 0U, OB_RUNTIME, 0U},
    {"M02", 0U, OB_RUNTIME, 0U},
    {"M03", 0U, OB_RUNTIME, 0U},
    {"M04", 0U, OB_RUNTIME, 0U},
    {"M05", 0U, OB_RUNTIME, 0U},
    {"M06", 0U, OB_RUNTIME, 0U},
    {"M07", 0U, OB_RUNTIME, 0U},
    {"M08", 0U, OB_RUNTIME, 0U},
    {"M09", 0U, OB_RUNTIME, 0U},
    {"M10", 0U, OB_RUNTIME, 0U},
    {"M11", 0U, OB_RUNTIME, 0U},
    {"M12", 0U, OB_RUNTIME, 0U},
    {"M13", 0U, OB_RUNTIME, 0U},
    {"M14", 0U, OB_RUNTIME, 0U},
    {"M15", 0U, OB_RUNTIME, 0U},
    {"M16", 0U, OB_RUNTIME, 0U},
    {"M17", 0U, OB_RUNTIME, 0U},
    {"M18", 0U, OB_RUNTIME, 0U},
    {"M19", 0U, OB_RUNTIME, 0U},
    {"M20", 0U, OB_RUNTIME, 0U},
    {"M21", 0U, OB_RUNTIME, 0U},
    {"M22", 0U, OB_RUNTIME, 0U},
    {"M23", 0U, OB_RUNTIME, 0U},
    {"M24", 0U, OB_RUNTIME, 0U},
    {"M25", 0U, OB_RUNTIME, 0U},
    {"M26", 0U, OB_RUNTIME, 0U},
    {"M27", 0U, OB_RUNTIME, 0U},
    {"PAR-empty", 1U, OB_RUNTIME, 0U},
    {"PAR-bad-magic", 1U, OB_RUNTIME, 0U},
    {"PAR-unknown-mode", 1U, OB_RUNTIME, 0U},
    {"PAR-double-space", 1U, OB_RUNTIME, 0U},
    {"PAR-trailing-space", 1U, OB_RUNTIME, 0U},
    {"PAR-leading-space", 1U, OB_RUNTIME, 0U},
    {"PAR-tab-separator", 1U, OB_RUNTIME, 0U},
    {"PAR-missing-lf", 1U, OB_RUNTIME, 0U},
    {"PAR-crlf", 1U, OB_RUNTIME, 0U},
    {"PAR-extra-line", 1U, OB_RUNTIME, 0U},
    {"PAR-trailing-byte", 1U, OB_RUNTIME, 0U},
    {"PAR-embedded-nul", 1U, OB_RUNTIME, 0U},
    {"PAR-non-ascii", 1U, OB_RUNTIME, 0U},
    {"PAR-socket-leading-zero", 1U, OB_RUNTIME, 0U},
    {"PAR-socket-plus", 1U, OB_RUNTIME, 0U},
    {"PAR-socket-negative", 1U, OB_RUNTIME, 0U},
    {"PAR-socket-max-plus-one", 1U, OB_RUNTIME, 0U},
    {"PAR-socket-uint-overflow", 1U, OB_RUNTIME, 0U},
    {"PAR-socket-nondigit", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-candidate-read", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-candidate-write", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-tools-write", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-evidence-read", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-evidence-list", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-evidence-reopen", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-evidence-truncate", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-evidence-link", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-evidence-rename", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-scratch-free", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-scratch-fill", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-output-overflow", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-environment", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-descriptors", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-fork-bomb", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-thread-bomb", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-cpu-spin-32", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-memory-exhaustion", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-sleep", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-signal-supervisor", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-namespace-escape", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-cgroup-escape", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-forged-report-stdout", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-forged-report-evidence", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-socket-0", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-socket-2", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-host-sentinel-0", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-host-sentinel-1", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-host-sentinel-2", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-host-sentinel-4", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-odd-hex", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-nonhex", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-upper-path", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-relative", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-nul-path", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-root-empty-component", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-empty-component", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-trailing-slash", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-dot-component", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-dotdot-component", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-path-too-long", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-size-zero", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-size-too-large", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-size-leading-zero", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-size-plus", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-size-negative", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-size-overflow", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-size-nondigit", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-digest-short", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-digest-long", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-digest-upper", 1U, OB_RUNTIME, 0U},
    {"PAR-host-sentinel-digest-nonhex", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-sibling-sentinel-0", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-sibling-sentinel-1", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-sibling-sentinel-2", 1U, OB_RUNTIME, 0U},
    {"PAR-arity-sibling-sentinel-4", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-odd-hex", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-nonhex", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-upper-path", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-relative", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-nul-path", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-root-empty-component", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-empty-component", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-trailing-slash", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-dot-component", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-dotdot-component", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-path-too-long", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-size-zero", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-size-too-large", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-size-leading-zero", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-size-plus", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-size-negative", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-size-overflow", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-size-nondigit", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-digest-short", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-digest-long", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-digest-upper", 1U, OB_RUNTIME, 0U},
    {"PAR-sibling-sentinel-digest-nonhex", 1U, OB_RUNTIME, 0U},
    {"PAR-cap", 1U, OB_RUNTIME, 0U},
    {"PAR-overflow", 1U, OB_RUNTIME, 0U},
    {"PAR-read-error", 1U, OB_RUNTIME, 0U},
    {"PAR-read-error-after-prefix", 1U, OB_RUNTIME, 0U},
    {"PAR-chunk-eintr", 1U, OB_RUNTIME, 0U},
    {"PAR-initial-eintr", 1U, OB_RUNTIME, 0U},
    {"PAR-valid-cap-limit", 1U, OB_RUNTIME, 0U},
    {"FIX-path", 2U, OB_RUNTIME, 0U},
    {"FIX-missing-call", 2U, OB_RUNTIME, 0U},
    {"FIX-order", 2U, OB_RUNTIME, 0U},
    {"FIX-flags", 2U, OB_RUNTIME, 0U},
    {"FIX-fd", 2U, OB_RUNTIME, 0U},
    {"FIX-length", 2U, OB_RUNTIME, 0U},
    {"FIX-bytes", 2U, OB_RUNTIME, 0U},
    {"FIX-invalid-write-return", 2U, OB_RUNTIME, 0U},
    {"FIX-bad-allocation-object", 2U, OB_RUNTIME, 0U},
    {"FIX-leftover", 2U, OB_RUNTIME, 0U},
    {"FIX-missing-byte-oracle", 2U, OB_RUNTIME, 0U},
    {"FIX-duplicate-live-allocation", 2U, OB_RUNTIME, 0U},
    {"FIX-invalid-free", 2U, OB_RUNTIME, 0U},
    {"FIX-uninitialized-stat", 2U, OB_RUNTIME, 0U},
    {"FIX-uninitialized-thread-token", 2U, OB_RUNTIME, 0U},
    {"FIX-missing-id", 2U, OB_RUNTIME, 0U},
    {"FIX-duplicate-id", 2U, OB_RUNTIME, 0U},
    {"FIX-unknown-id", 2U, OB_RUNTIME, 0U},
    {"FIX-late-guard", 2U, OB_RUNTIME, 0U},
    {"FIX-returning-callback", 2U, OB_RUNTIME, 0U},
    {"FIX-memory-final", 2U, OB_RUNTIME, 0U},
    {"FIX-production-boundary", 2U, OB_RUNTIME, 0U},
    {"FIX-queue-ownership", 2U, OB_RUNTIME, 0U},
    {"OUT-full", 3U, OB_RUNTIME, 0U},
    {"OUT-short-completes", 3U, OB_RUNTIME, 0U},
    {"OUT-eintr", 3U, OB_RUNTIME, 0U},
    {"OUT-zero", 3U, OB_RUNTIME, 0U},
    {"OUT-prefix-error", 3U, OB_RUNTIME, 0U},
    {"OUT-initial-error", 3U, OB_RUNTIME, 0U},
    {"OUT-stop-during-write", 3U, OB_RUNTIME, 0U},
    {"OUT-input-full", 3U, OB_RUNTIME, 0U},
    {"OUT-input-short", 3U, OB_RUNTIME, 0U},
    {"OUT-input-eintr", 3U, OB_RUNTIME, 0U},
    {"OUT-input-zero", 3U, OB_RUNTIME, 0U},
    {"OUT-input-error", 3U, OB_RUNTIME, 0U},
    {"OUT-read-full", 3U, OB_RUNTIME, 0U},
    {"OUT-read-short", 3U, OB_RUNTIME, 0U},
    {"OUT-read-eintr", 3U, OB_RUNTIME, 0U},
    {"OUT-read-zero", 3U, OB_RUNTIME, 0U},
    {"OUT-read-error", 3U, OB_RUNTIME, 0U},
    {"CR-open-EPERM", 4U, OB_RUNTIME, 0U},
    {"CR-open-EACCES", 4U, OB_RUNTIME, 0U},
    {"CR-open-EROFS", 4U, OB_RUNTIME, 0U},
    {"CR-open-EOPNOTSUPP", 4U, OB_RUNTIME, 0U},
    {"CR-open-EIO", 4U, OB_RUNTIME, 0U},
    {"CR-open-ENOENT", 4U, OB_RUNTIME, 0U},
    {"CR-read-byte-close-0", 4U, OB_RUNTIME, 0U},
    {"CR-read-byte-close-EIO", 4U, OB_RUNTIME, 0U},
    {"CR-read-eof-close-0", 4U, OB_RUNTIME, 0U},
    {"CR-read-eof-close-EIO", 4U, OB_RUNTIME, 0U},
    {"CR-read-EPERM-close-0", 4U, OB_RUNTIME, 0U},
    {"CR-read-EPERM-close-EIO", 4U, OB_RUNTIME, 0U},
    {"CR-read-EACCES-close-0", 4U, OB_RUNTIME, 0U},
    {"CR-read-EACCES-close-EIO", 4U, OB_RUNTIME, 0U},
    {"CR-read-EROFS-close-0", 4U, OB_RUNTIME, 0U},
    {"CR-read-EROFS-close-EIO", 4U, OB_RUNTIME, 0U},
    {"CR-read-EOPNOTSUPP-close-0", 4U, OB_RUNTIME, 0U},
    {"CR-read-EOPNOTSUPP-close-EIO", 4U, OB_RUNTIME, 0U},
    {"CR-read-EIO-close-0", 4U, OB_RUNTIME, 0U},
    {"CR-read-EIO-close-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-candidate-write-open-EPERM", 4U, OB_RUNTIME, 0U},
    {"FW-candidate-write-open-EACCES", 4U, OB_RUNTIME, 0U},
    {"FW-candidate-write-open-EROFS", 4U, OB_RUNTIME, 0U},
    {"FW-candidate-write-open-EOPNOTSUPP", 4U, OB_RUNTIME, 0U},
    {"FW-candidate-write-open-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-candidate-write-open-ENOENT", 4U, OB_RUNTIME, 0U},
    {"FW-candidate-write-full-close-0", 4U, OB_RUNTIME, 0U},
    {"FW-candidate-write-full-close-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-candidate-write-zero-close-0", 4U, OB_RUNTIME, 0U},
    {"FW-candidate-write-zero-close-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-candidate-write-EIO-close-0", 4U, OB_RUNTIME, 0U},
    {"FW-candidate-write-EIO-close-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-tools-write-open-EPERM", 4U, OB_RUNTIME, 0U},
    {"FW-tools-write-open-EACCES", 4U, OB_RUNTIME, 0U},
    {"FW-tools-write-open-EROFS", 4U, OB_RUNTIME, 0U},
    {"FW-tools-write-open-EOPNOTSUPP", 4U, OB_RUNTIME, 0U},
    {"FW-tools-write-open-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-tools-write-open-ENOENT", 4U, OB_RUNTIME, 0U},
    {"FW-tools-write-full-close-0", 4U, OB_RUNTIME, 0U},
    {"FW-tools-write-full-close-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-tools-write-zero-close-0", 4U, OB_RUNTIME, 0U},
    {"FW-tools-write-zero-close-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-tools-write-EIO-close-0", 4U, OB_RUNTIME, 0U},
    {"FW-tools-write-EIO-close-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-open-EPERM", 4U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-open-EACCES", 4U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-open-EROFS", 4U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-open-EOPNOTSUPP", 4U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-open-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-open-ENOENT", 4U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-full-close-0", 4U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-full-close-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-zero-close-0", 4U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-zero-close-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-EIO-close-0", 4U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-EIO-close-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-short-close-0", 4U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-short-close-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-open-EPERM", 4U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-open-EACCES", 4U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-open-EROFS", 4U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-open-EOPNOTSUPP", 4U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-open-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-open-ENOENT", 4U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-full-close-0", 4U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-full-close-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-zero-close-0", 4U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-zero-close-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-EIO-close-0", 4U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-EIO-close-EIO", 4U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-short-close-0", 4U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-short-close-EIO", 4U, OB_RUNTIME, 0U},
    {"ESET-read-open-EIO", 5U, OB_RUNTIME, 0U},
    {"ESET-read-open-EPERM", 5U, OB_RUNTIME, 0U},
    {"ESET-read-negative-EIO-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-read-negative-EIO-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-read-negative-EINTR-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-read-negative-EINTR-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-read-zero-prior-0-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-read-zero-prior-0-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-read-zero-prior-EINTR-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-read-zero-prior-EINTR-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-read-zero-prior-EACCES-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-read-zero-prior-EACCES-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-read-setup-close-error", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reopen-EPERM", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reopen-EACCES", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reopen-EROFS", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reopen-EOPNOTSUPP", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reopen-EIO", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reopen-ENOENT", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reached-byte-close-0", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reached-byte-close-EIO", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reached-eof-close-0", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reached-eof-close-EIO", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reached-EPERM-close-0", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reached-EPERM-close-EIO", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reached-EACCES-close-0", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reached-EACCES-close-EIO", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reached-EROFS-close-0", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reached-EROFS-close-EIO", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reached-EOPNOTSUPP-close-0", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reached-EOPNOTSUPP-close-EIO", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reached-EIO-close-0", 5U, OB_RUNTIME, 0U},
    {"EACT-read-reached-EIO-close-EIO", 5U, OB_RUNTIME, 0U},
    {"ESET-reopen-open-EIO", 5U, OB_RUNTIME, 0U},
    {"ESET-reopen-open-EPERM", 5U, OB_RUNTIME, 0U},
    {"ESET-reopen-negative-EIO-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-reopen-negative-EIO-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-reopen-negative-EINTR-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-reopen-negative-EINTR-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-reopen-zero-prior-0-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-reopen-zero-prior-0-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-reopen-zero-prior-EINTR-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-reopen-zero-prior-EINTR-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-reopen-zero-prior-EACCES-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-reopen-zero-prior-EACCES-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-reopen-setup-close-error", 5U, OB_RUNTIME, 0U},
    {"EACT-reopen-EPERM", 5U, OB_RUNTIME, 0U},
    {"EACT-reopen-EACCES", 5U, OB_RUNTIME, 0U},
    {"EACT-reopen-EROFS", 5U, OB_RUNTIME, 0U},
    {"EACT-reopen-EOPNOTSUPP", 5U, OB_RUNTIME, 0U},
    {"EACT-reopen-EIO", 5U, OB_RUNTIME, 0U},
    {"EACT-reopen-ENOENT", 5U, OB_RUNTIME, 0U},
    {"EACT-reopen-success-close-0", 5U, OB_RUNTIME, 0U},
    {"EACT-reopen-success-close-EIO", 5U, OB_RUNTIME, 0U},
    {"ESET-truncate-open-EIO", 5U, OB_RUNTIME, 0U},
    {"ESET-truncate-open-EPERM", 5U, OB_RUNTIME, 0U},
    {"ESET-truncate-negative-EIO-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-truncate-negative-EIO-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-truncate-negative-EINTR-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-truncate-negative-EINTR-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-truncate-zero-prior-0-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-truncate-zero-prior-0-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-truncate-zero-prior-EINTR-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-truncate-zero-prior-EINTR-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-truncate-zero-prior-EACCES-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-truncate-zero-prior-EACCES-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-truncate-setup-close-error", 5U, OB_RUNTIME, 0U},
    {"EACT-truncate-0", 5U, OB_RUNTIME, 0U},
    {"EACT-truncate-EPERM", 5U, OB_RUNTIME, 0U},
    {"EACT-truncate-EACCES", 5U, OB_RUNTIME, 0U},
    {"EACT-truncate-EROFS", 5U, OB_RUNTIME, 0U},
    {"EACT-truncate-EOPNOTSUPP", 5U, OB_RUNTIME, 0U},
    {"EACT-truncate-EIO", 5U, OB_RUNTIME, 0U},
    {"EACT-truncate-ENOENT", 5U, OB_RUNTIME, 0U},
    {"ESET-link-open-EIO", 5U, OB_RUNTIME, 0U},
    {"ESET-link-open-EPERM", 5U, OB_RUNTIME, 0U},
    {"ESET-link-negative-EIO-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-link-negative-EIO-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-link-negative-EINTR-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-link-negative-EINTR-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-link-zero-prior-0-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-link-zero-prior-0-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-link-zero-prior-EINTR-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-link-zero-prior-EINTR-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-link-zero-prior-EACCES-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-link-zero-prior-EACCES-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-link-setup-close-error", 5U, OB_RUNTIME, 0U},
    {"EACT-link-0", 5U, OB_RUNTIME, 0U},
    {"EACT-link-EPERM", 5U, OB_RUNTIME, 0U},
    {"EACT-link-EACCES", 5U, OB_RUNTIME, 0U},
    {"EACT-link-EROFS", 5U, OB_RUNTIME, 0U},
    {"EACT-link-EOPNOTSUPP", 5U, OB_RUNTIME, 0U},
    {"EACT-link-EIO", 5U, OB_RUNTIME, 0U},
    {"EACT-link-ENOENT", 5U, OB_RUNTIME, 0U},
    {"ESET-rename-open-EIO", 5U, OB_RUNTIME, 0U},
    {"ESET-rename-open-EPERM", 5U, OB_RUNTIME, 0U},
    {"ESET-rename-negative-EIO-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-rename-negative-EIO-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-rename-negative-EINTR-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-rename-negative-EINTR-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-rename-zero-prior-0-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-rename-zero-prior-0-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-rename-zero-prior-EINTR-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-rename-zero-prior-EINTR-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-rename-zero-prior-EACCES-close-0", 5U, OB_RUNTIME, 0U},
    {"ESET-rename-zero-prior-EACCES-close-EBADF", 5U, OB_RUNTIME, 0U},
    {"ESET-rename-setup-close-error", 5U, OB_RUNTIME, 0U},
    {"EACT-rename-0", 5U, OB_RUNTIME, 0U},
    {"EACT-rename-EPERM", 5U, OB_RUNTIME, 0U},
    {"EACT-rename-EACCES", 5U, OB_RUNTIME, 0U},
    {"EACT-rename-EROFS", 5U, OB_RUNTIME, 0U},
    {"EACT-rename-EOPNOTSUPP", 5U, OB_RUNTIME, 0U},
    {"EACT-rename-EIO", 5U, OB_RUNTIME, 0U},
    {"EACT-rename-ENOENT", 5U, OB_RUNTIME, 0U},
    {"EL-open-EPERM", 6U, OB_RUNTIME, 0U},
    {"EL-open-EACCES", 6U, OB_RUNTIME, 0U},
    {"EL-open-EROFS", 6U, OB_RUNTIME, 0U},
    {"EL-open-EOPNOTSUPP", 6U, OB_RUNTIME, 0U},
    {"EL-open-EIO", 6U, OB_RUNTIME, 0U},
    {"EL-open-ENOENT", 6U, OB_RUNTIME, 0U},
    {"EL-read-entry-close-0", 6U, OB_RUNTIME, 0U},
    {"EL-read-entry-close-EBADF", 6U, OB_RUNTIME, 0U},
    {"EL-read-eof-prior-EIO-close-0", 6U, OB_RUNTIME, 0U},
    {"EL-read-eof-prior-EIO-close-EBADF", 6U, OB_RUNTIME, 0U},
    {"EL-read-EPERM-close-0", 6U, OB_RUNTIME, 0U},
    {"EL-read-EPERM-close-EBADF", 6U, OB_RUNTIME, 0U},
    {"EL-read-EACCES-close-0", 6U, OB_RUNTIME, 0U},
    {"EL-read-EACCES-close-EBADF", 6U, OB_RUNTIME, 0U},
    {"EL-read-EROFS-close-0", 6U, OB_RUNTIME, 0U},
    {"EL-read-EROFS-close-EBADF", 6U, OB_RUNTIME, 0U},
    {"EL-read-EOPNOTSUPP-close-0", 6U, OB_RUNTIME, 0U},
    {"EL-read-EOPNOTSUPP-close-EBADF", 6U, OB_RUNTIME, 0U},
    {"EL-read-EIO-close-0", 6U, OB_RUNTIME, 0U},
    {"EL-read-EIO-close-EBADF", 6U, OB_RUNTIME, 0U},
    {"FW-candidate-write-reached-EPERM-close-0", 7U, OB_RUNTIME, 0U},
    {"FW-candidate-write-reached-EPERM-close-EIO", 7U, OB_RUNTIME, 0U},
    {"FW-candidate-write-reached-EACCES-close-0", 7U, OB_RUNTIME, 0U},
    {"FW-candidate-write-reached-EACCES-close-EIO", 7U, OB_RUNTIME, 0U},
    {"FW-candidate-write-reached-EROFS-close-0", 7U, OB_RUNTIME, 0U},
    {"FW-candidate-write-reached-EROFS-close-EIO", 7U, OB_RUNTIME, 0U},
    {"FW-candidate-write-reached-EOPNOTSUPP-close-0", 7U, OB_RUNTIME, 0U},
    {"FW-candidate-write-reached-EOPNOTSUPP-close-EIO", 7U, OB_RUNTIME, 0U},
    {"FW-tools-write-reached-EPERM-close-0", 7U, OB_RUNTIME, 0U},
    {"FW-tools-write-reached-EPERM-close-EIO", 7U, OB_RUNTIME, 0U},
    {"FW-tools-write-reached-EACCES-close-0", 7U, OB_RUNTIME, 0U},
    {"FW-tools-write-reached-EACCES-close-EIO", 7U, OB_RUNTIME, 0U},
    {"FW-tools-write-reached-EROFS-close-0", 7U, OB_RUNTIME, 0U},
    {"FW-tools-write-reached-EROFS-close-EIO", 7U, OB_RUNTIME, 0U},
    {"FW-tools-write-reached-EOPNOTSUPP-close-0", 7U, OB_RUNTIME, 0U},
    {"FW-tools-write-reached-EOPNOTSUPP-close-EIO", 7U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-reached-EPERM-close-0", 7U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-reached-EPERM-close-EIO", 7U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-reached-EACCES-close-0", 7U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-reached-EACCES-close-EIO", 7U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-reached-EROFS-close-0", 7U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-reached-EROFS-close-EIO", 7U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-reached-EOPNOTSUPP-close-0", 7U, OB_RUNTIME, 0U},
    {"FW-cgroup-escape-reached-EOPNOTSUPP-close-EIO", 7U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-reached-EPERM-close-0", 7U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-reached-EPERM-close-EIO", 7U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-reached-EACCES-close-0", 7U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-reached-EACCES-close-EIO", 7U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-reached-EROFS-close-0", 7U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-reached-EROFS-close-EIO", 7U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-reached-EOPNOTSUPP-close-0", 7U, OB_RUNTIME, 0U},
    {"FW-forged-report-evidence-reached-EOPNOTSUPP-close-EIO", 7U, OB_RUNTIME, 0U},
    {"SS-ftruncate-open-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-ftruncate-open-EPERM", 8U, OB_RUNTIME, 0U},
    {"SS-ftruncate-zero-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-ftruncate-zero-close-EBADF", 8U, OB_RUNTIME, 0U},
    {"SS-ftruncate-error-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-ftruncate-error-close-EBADF", 8U, OB_RUNTIME, 0U},
    {"SS-ftruncate-full-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-ftruncate-full-close-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-ftruncate-short-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-ftruncate-short-close-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-ftruncate-eintr-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-ftruncate-eintr-close-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-fallocate-open-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-fallocate-open-EPERM", 8U, OB_RUNTIME, 0U},
    {"SS-fallocate-zero-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-fallocate-zero-close-EBADF", 8U, OB_RUNTIME, 0U},
    {"SS-fallocate-error-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-fallocate-error-close-EBADF", 8U, OB_RUNTIME, 0U},
    {"SS-fallocate-full-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-fallocate-full-close-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-fallocate-short-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-fallocate-short-close-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-fallocate-eintr-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-fallocate-eintr-close-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-madv-remove-open-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-madv-remove-open-EPERM", 8U, OB_RUNTIME, 0U},
    {"SS-madv-remove-zero-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-madv-remove-zero-close-EBADF", 8U, OB_RUNTIME, 0U},
    {"SS-madv-remove-error-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-madv-remove-error-close-EBADF", 8U, OB_RUNTIME, 0U},
    {"SS-madv-remove-full-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-madv-remove-full-close-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-madv-remove-short-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-madv-remove-short-close-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-madv-remove-eintr-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-madv-remove-eintr-close-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-path-truncate-open-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-path-truncate-open-EPERM", 8U, OB_RUNTIME, 0U},
    {"SS-path-truncate-zero-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-path-truncate-zero-close-EBADF", 8U, OB_RUNTIME, 0U},
    {"SS-path-truncate-error-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-path-truncate-error-close-EBADF", 8U, OB_RUNTIME, 0U},
    {"SS-path-truncate-full-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-path-truncate-full-close-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-path-truncate-short-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-path-truncate-short-close-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-path-truncate-eintr-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-path-truncate-eintr-close-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-unlink-open-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-unlink-open-EPERM", 8U, OB_RUNTIME, 0U},
    {"SS-unlink-zero-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-unlink-zero-close-EBADF", 8U, OB_RUNTIME, 0U},
    {"SS-unlink-error-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-unlink-error-close-EBADF", 8U, OB_RUNTIME, 0U},
    {"SS-unlink-full-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-unlink-full-close-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-unlink-short-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-unlink-short-close-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-unlink-eintr-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-unlink-eintr-close-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-ftruncate-reopen-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-ftruncate-reopen-EPERM", 8U, OB_RUNTIME, 0U},
    {"SS-fallocate-reopen-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-fallocate-reopen-EPERM", 8U, OB_RUNTIME, 0U},
    {"SS-madv-remove-reopen-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-madv-remove-reopen-EPERM", 8U, OB_RUNTIME, 0U},
    {"SS-madv-remove-mmap-close-0", 8U, OB_RUNTIME, 0U},
    {"SS-madv-remove-mmap-close-EBADF", 8U, OB_RUNTIME, 0U},
    {"SS-rmdir-mkdir-EIO", 8U, OB_RUNTIME, 0U},
    {"SS-rmdir-mkdir-EPERM", 8U, OB_RUNTIME, 0U},
    {"SA-ftruncate-0-0", 9U, OB_RUNTIME, 0U},
    {"SA-ftruncate-0-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-ftruncate-EPERM-0", 9U, OB_RUNTIME, 0U},
    {"SA-ftruncate-EPERM-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-ftruncate-EACCES-0", 9U, OB_RUNTIME, 0U},
    {"SA-ftruncate-EACCES-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-ftruncate-EROFS-0", 9U, OB_RUNTIME, 0U},
    {"SA-ftruncate-EROFS-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-ftruncate-EOPNOTSUPP-0", 9U, OB_RUNTIME, 0U},
    {"SA-ftruncate-EOPNOTSUPP-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-ftruncate-ENOSYS-0", 9U, OB_RUNTIME, 0U},
    {"SA-ftruncate-ENOSYS-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-ftruncate-EIO-0", 9U, OB_RUNTIME, 0U},
    {"SA-ftruncate-EIO-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-fallocate-0-0", 9U, OB_RUNTIME, 0U},
    {"SA-fallocate-0-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-fallocate-EPERM-0", 9U, OB_RUNTIME, 0U},
    {"SA-fallocate-EPERM-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-fallocate-EACCES-0", 9U, OB_RUNTIME, 0U},
    {"SA-fallocate-EACCES-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-fallocate-EROFS-0", 9U, OB_RUNTIME, 0U},
    {"SA-fallocate-EROFS-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-fallocate-EOPNOTSUPP-0", 9U, OB_RUNTIME, 0U},
    {"SA-fallocate-EOPNOTSUPP-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-fallocate-ENOSYS-0", 9U, OB_RUNTIME, 0U},
    {"SA-fallocate-ENOSYS-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-fallocate-EIO-0", 9U, OB_RUNTIME, 0U},
    {"SA-fallocate-EIO-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-0-0", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-0-unmap-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-0-close-EBADF", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-0-both-EIO-then-EBADF", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EPERM-0", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EPERM-unmap-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EPERM-close-EBADF", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EPERM-both-EIO-then-EBADF", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EACCES-0", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EACCES-unmap-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EACCES-close-EBADF", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EACCES-both-EIO-then-EBADF", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EROFS-0", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EROFS-unmap-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EROFS-close-EBADF", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EROFS-both-EIO-then-EBADF", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EOPNOTSUPP-0", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EOPNOTSUPP-unmap-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EOPNOTSUPP-close-EBADF", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EOPNOTSUPP-both-EIO-then-EBADF", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-ENOSYS-0", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-ENOSYS-unmap-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-ENOSYS-close-EBADF", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-ENOSYS-both-EIO-then-EBADF", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EIO-0", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EIO-unmap-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EIO-close-EBADF", 9U, OB_RUNTIME, 0U},
    {"SA-madv-remove-EIO-both-EIO-then-EBADF", 9U, OB_RUNTIME, 0U},
    {"SA-path-truncate-0-0", 9U, OB_RUNTIME, 0U},
    {"SA-path-truncate-EPERM-0", 9U, OB_RUNTIME, 0U},
    {"SA-path-truncate-EACCES-0", 9U, OB_RUNTIME, 0U},
    {"SA-path-truncate-EROFS-0", 9U, OB_RUNTIME, 0U},
    {"SA-path-truncate-EOPNOTSUPP-0", 9U, OB_RUNTIME, 0U},
    {"SA-path-truncate-ENOSYS-0", 9U, OB_RUNTIME, 0U},
    {"SA-path-truncate-EIO-0", 9U, OB_RUNTIME, 0U},
    {"SA-unlink-0-0", 9U, OB_RUNTIME, 0U},
    {"SA-unlink-EPERM-0", 9U, OB_RUNTIME, 0U},
    {"SA-unlink-EACCES-0", 9U, OB_RUNTIME, 0U},
    {"SA-unlink-EROFS-0", 9U, OB_RUNTIME, 0U},
    {"SA-unlink-EOPNOTSUPP-0", 9U, OB_RUNTIME, 0U},
    {"SA-unlink-ENOSYS-0", 9U, OB_RUNTIME, 0U},
    {"SA-unlink-EIO-0", 9U, OB_RUNTIME, 0U},
    {"SA-rmdir-0-0", 9U, OB_RUNTIME, 0U},
    {"SA-rmdir-EPERM-0", 9U, OB_RUNTIME, 0U},
    {"SA-rmdir-EACCES-0", 9U, OB_RUNTIME, 0U},
    {"SA-rmdir-EROFS-0", 9U, OB_RUNTIME, 0U},
    {"SA-rmdir-EOPNOTSUPP-0", 9U, OB_RUNTIME, 0U},
    {"SA-rmdir-ENOSYS-0", 9U, OB_RUNTIME, 0U},
    {"SA-rmdir-EIO-0", 9U, OB_RUNTIME, 0U},
    {"SA-tmpfile-0-0", 9U, OB_RUNTIME, 0U},
    {"SA-tmpfile-0-EIO", 9U, OB_RUNTIME, 0U},
    {"SA-tmpfile-EPERM-0", 9U, OB_RUNTIME, 0U},
    {"SA-tmpfile-EACCES-0", 9U, OB_RUNTIME, 0U},
    {"SA-tmpfile-EROFS-0", 9U, OB_RUNTIME, 0U},
    {"SA-tmpfile-EOPNOTSUPP-0", 9U, OB_RUNTIME, 0U},
    {"SA-tmpfile-ENOSYS-0", 9U, OB_RUNTIME, 0U},
    {"SA-tmpfile-EIO-0", 9U, OB_RUNTIME, 0U},
    {"SF-platform-fallocate", 9U, OB_RUNTIME, 0U},
    {"SF-platform-madv-remove", 9U, OB_RUNTIME, 0U},
    {"SF-platform-tmpfile", 9U, OB_RUNTIME, 0U},
    {"SEN-host-open-ENOENT", 10U, OB_RUNTIME, 0U},
    {"SEN-host-open-ENOTDIR", 10U, OB_RUNTIME, 0U},
    {"SEN-host-open-EPERM", 10U, OB_RUNTIME, 0U},
    {"SEN-host-open-EACCES", 10U, OB_RUNTIME, 0U},
    {"SEN-host-open-EROFS", 10U, OB_RUNTIME, 0U},
    {"SEN-host-open-EOPNOTSUPP", 10U, OB_RUNTIME, 0U},
    {"SEN-host-open-EIO", 10U, OB_RUNTIME, 0U},
    {"SEN-host-stat-error-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-host-wrong-type-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-host-stat-error-close-EBADF", 10U, OB_RUNTIME, 0U},
    {"SEN-host-wrong-type-close-EBADF", 10U, OB_RUNTIME, 0U},
    {"SEN-host-match-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-host-match-close-EIO", 10U, OB_RUNTIME, 0U},
    {"SEN-host-short-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-host-short-close-EIO", 10U, OB_RUNTIME, 0U},
    {"SEN-host-long-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-host-long-close-EIO", 10U, OB_RUNTIME, 0U},
    {"SEN-host-wrong-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-host-wrong-close-EIO", 10U, OB_RUNTIME, 0U},
    {"SEN-host-empty-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-host-empty-close-EIO", 10U, OB_RUNTIME, 0U},
    {"SEN-host-eintr-match-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-host-eintr-match-close-EIO", 10U, OB_RUNTIME, 0U},
    {"SEN-host-short-chunks-match-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-host-short-chunks-match-close-EIO", 10U, OB_RUNTIME, 0U},
    {"SEN-host-read-EIO-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-host-read-EIO-close-EBADF", 10U, OB_RUNTIME, 0U},
    {"SEN-host-read-EACCES-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-host-read-EACCES-close-EBADF", 10U, OB_RUNTIME, 0U},
    {"SEN-host-read-EOPNOTSUPP-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-host-read-EOPNOTSUPP-close-EBADF", 10U, OB_RUNTIME, 0U},
    {"SEN-host-read-prefix-error-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-host-read-prefix-error-close-EBADF", 10U, OB_RUNTIME, 0U},
    {"SEN-host-minimum", 10U, OB_RUNTIME, 0U},
    {"SEN-host-maximum", 10U, OB_RUNTIME, 0U},
    {"SEN-host-size-only-mismatch", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-open-ENOENT", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-open-ENOTDIR", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-open-EPERM", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-open-EACCES", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-open-EROFS", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-open-EOPNOTSUPP", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-open-EIO", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-stat-error-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-wrong-type-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-stat-error-close-EBADF", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-wrong-type-close-EBADF", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-match-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-match-close-EIO", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-short-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-short-close-EIO", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-long-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-long-close-EIO", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-wrong-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-wrong-close-EIO", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-empty-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-empty-close-EIO", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-eintr-match-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-eintr-match-close-EIO", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-short-chunks-match-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-short-chunks-match-close-EIO", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-read-EIO-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-read-EIO-close-EBADF", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-read-EACCES-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-read-EACCES-close-EBADF", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-read-EOPNOTSUPP-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-read-EOPNOTSUPP-close-EBADF", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-read-prefix-error-close-0", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-read-prefix-error-close-EBADF", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-minimum", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-maximum", 10U, OB_RUNTIME, 0U},
    {"SEN-sibling-size-only-mismatch", 10U, OB_RUNTIME, 0U},
    {"SOCK-A-0", 11U, OB_RUNTIME, 0U},
    {"SOCK-A-1", 11U, OB_RUNTIME, 0U},
    {"SOCK-A-2", 11U, OB_RUNTIME, 0U},
    {"SOCK-A-3", 11U, OB_RUNTIME, 0U},
    {"SOCK-A-4", 11U, OB_RUNTIME, 0U},
    {"SOCK-A-5", 11U, OB_RUNTIME, 0U},
    {"SOCK-A-6", 11U, OB_RUNTIME, 0U},
    {"SOCK-A-7", 11U, OB_RUNTIME, 0U},
    {"SOCK-error-EAFNOSUPPORT", 11U, OB_RUNTIME, 0U},
    {"SOCK-error-EPROTONOSUPPORT", 11U, OB_RUNTIME, 0U},
    {"SOCK-error-ESOCKTNOSUPPORT", 11U, OB_RUNTIME, 0U},
    {"SOCK-error-EOPNOTSUPP", 11U, OB_RUNTIME, 0U},
    {"SOCK-error-EACCES", 11U, OB_RUNTIME, 0U},
    {"SOCK-error-EROFS", 11U, OB_RUNTIME, 0U},
    {"SOCK-error-EINVAL", 11U, OB_RUNTIME, 0U},
    {"SOCK-error-ENOSYS", 11U, OB_RUNTIME, 0U},
    {"SOCK-error-EMFILE", 11U, OB_RUNTIME, 0U},
    {"SOCK-success-2-close-0", 11U, OB_RUNTIME, 0U},
    {"SOCK-success-2-close-EIO", 11U, OB_RUNTIME, 0U},
    {"SOCK-success-3-close-0", 11U, OB_RUNTIME, 0U},
    {"SOCK-success-3-close-EIO", 11U, OB_RUNTIME, 0U},
    {"SOCK-success-4-close-0", 11U, OB_RUNTIME, 0U},
    {"SOCK-success-4-close-EIO", 11U, OB_RUNTIME, 0U},
    {"SOCK-success-5-close-0", 11U, OB_RUNTIME, 0U},
    {"SOCK-success-5-close-EIO", 11U, OB_RUNTIME, 0U},
    {"SOCK-prereq-nonlinux", 11U, OB_RUNTIME, 0U},
    {"SOCK-prereq-domain-zero", 11U, OB_RUNTIME, 0U},
    {"SOCK-prereq-domain-negative", 11U, OB_RUNTIME, 0U},
    {"SOCK-prereq-domain-too-large", 11U, OB_RUNTIME, 0U},
    {"SOCK-prereq-missing-cloexec", 11U, OB_RUNTIME, 0U},
    {"SOCK-prereq-outside-small", 11U, OB_RUNTIME, 0U},
    {"SOCK-prereq-parser-upper-outside", 11U, OB_RUNTIME, 0U},
    {"SOCK-missing-netlink", 11U, OB_RUNTIME, 0U},
    {"SOCK-missing-packet", 11U, OB_RUNTIME, 0U},
    {"SOCK-missing-usersock", 11U, OB_RUNTIME, 0U},
    {"SOCK-domain-upper-valid", 11U, OB_RUNTIME, 0U},
    {"SOCK-vsock-absent", 11U, OB_RUNTIME, 0U},
    {"SOCK-kernel12-build8-0", 11U, OB_RUNTIME, 0U},
    {"SOCK-kernel12-build8-1", 11U, OB_RUNTIME, 0U},
    {"SOCK-kernel12-build8-2", 11U, OB_RUNTIME, 0U},
    {"SOCK-kernel12-build8-3", 11U, OB_RUNTIME, 0U},
    {"SOCK-kernel12-build8-4", 11U, OB_RUNTIME, 0U},
    {"SOCK-kernel12-build8-5", 11U, OB_RUNTIME, 0U},
    {"SOCK-kernel12-build8-6", 11U, OB_RUNTIME, 0U},
    {"SOCK-kernel12-build8-7", 11U, OB_RUNTIME, 0U},
    {"SOCK-kernel12-build8-8", 11U, OB_RUNTIME, 0U},
    {"SOCK-kernel12-build8-9", 11U, OB_RUNTIME, 0U},
    {"SOCK-kernel12-build8-10", 11U, OB_RUNTIME, 0U},
    {"SOCK-kernel12-build8-11", 11U, OB_RUNTIME, 0U},
    {"FACT-default-domain_max", 11U, OB_RUNTIME, 0U},
    {"FACT-default-linux_build", 11U, OB_RUNTIME, 0U},
    {"FACT-default-cloexec_available", 11U, OB_RUNTIME, 0U},
    {"FACT-default-cloexec", 11U, OB_RUNTIME, 0U},
    {"FACT-default-netlink_available", 11U, OB_RUNTIME, 0U},
    {"FACT-default-netlink", 11U, OB_RUNTIME, 0U},
    {"FACT-default-usersock_available", 11U, OB_RUNTIME, 0U},
    {"FACT-default-usersock", 11U, OB_RUNTIME, 0U},
    {"FACT-default-packet_available", 11U, OB_RUNTIME, 0U},
    {"FACT-default-packet", 11U, OB_RUNTIME, 0U},
    {"FACT-default-vsock_available", 11U, OB_RUNTIME, 0U},
    {"FACT-default-vsock", 11U, OB_RUNTIME, 0U},
    {"HENTRY-default-0", 11U, OB_RUNTIME, 0U},
    {"HENTRY-default-AF_NETLINK", 11U, OB_RUNTIME, 0U},
    {"HENTRY-default-AF_PACKET", 11U, OB_RUNTIME, 0U},
    {"HENTRY-default-AF_VSOCK", 11U, OB_RUNTIME, 0U},
    {"FACT-no-socket-constants-domain_max", 11U, OB_RUNTIME, 0U},
    {"FACT-no-socket-constants-linux_build", 11U, OB_RUNTIME, 0U},
    {"FACT-no-socket-constants-cloexec_available", 11U, OB_RUNTIME, 0U},
    {"FACT-no-socket-constants-cloexec", 11U, OB_RUNTIME, 0U},
    {"FACT-no-socket-constants-netlink_available", 11U, OB_RUNTIME, 0U},
    {"FACT-no-socket-constants-netlink", 11U, OB_RUNTIME, 0U},
    {"FACT-no-socket-constants-usersock_available", 11U, OB_RUNTIME, 0U},
    {"FACT-no-socket-constants-usersock", 11U, OB_RUNTIME, 0U},
    {"FACT-no-socket-constants-packet_available", 11U, OB_RUNTIME, 0U},
    {"FACT-no-socket-constants-packet", 11U, OB_RUNTIME, 0U},
    {"FACT-no-socket-constants-vsock_available", 11U, OB_RUNTIME, 0U},
    {"FACT-no-socket-constants-vsock", 11U, OB_RUNTIME, 0U},
    {"HENTRY-no-socket-constants-0", 11U, OB_RUNTIME, 0U},
    {"HENTRY-no-socket-constants-AF_NETLINK", 11U, OB_RUNTIME, 0U},
    {"HENTRY-no-socket-constants-AF_PACKET", 11U, OB_RUNTIME, 0U},
    {"HENTRY-no-socket-constants-AF_VSOCK", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-netlink-domain_max", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-netlink-linux_build", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-netlink-cloexec_available", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-netlink-cloexec", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-netlink-netlink_available", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-netlink-netlink", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-netlink-usersock_available", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-netlink-usersock", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-netlink-packet_available", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-netlink-packet", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-netlink-vsock_available", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-netlink-vsock", 11U, OB_RUNTIME, 0U},
    {"HENTRY-mask-netlink-0", 11U, OB_RUNTIME, 0U},
    {"HENTRY-mask-netlink-AF_NETLINK", 11U, OB_RUNTIME, 0U},
    {"HENTRY-mask-netlink-AF_PACKET", 11U, OB_RUNTIME, 0U},
    {"HENTRY-mask-netlink-AF_VSOCK", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-packet-domain_max", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-packet-linux_build", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-packet-cloexec_available", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-packet-cloexec", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-packet-netlink_available", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-packet-netlink", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-packet-usersock_available", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-packet-usersock", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-packet-packet_available", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-packet-packet", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-packet-vsock_available", 11U, OB_RUNTIME, 0U},
    {"FACT-mask-packet-vsock", 11U, OB_RUNTIME, 0U},
    {"HENTRY-mask-packet-0", 11U, OB_RUNTIME, 0U},
    {"HENTRY-mask-packet-AF_NETLINK", 11U, OB_RUNTIME, 0U},
    {"HENTRY-mask-packet-AF_PACKET", 11U, OB_RUNTIME, 0U},
    {"HENTRY-mask-packet-AF_VSOCK", 11U, OB_RUNTIME, 0U},
    {"FD0-regular", 12U, OB_RUNTIME, 0U},
    {"FD0-wrong-type", 12U, OB_RUNTIME, 0U},
    {"FD0-wrong-access", 12U, OB_RUNTIME, 0U},
    {"FD0-read-write", 12U, OB_RUNTIME, 0U},
    {"FD0-missing", 12U, OB_RUNTIME, 0U},
    {"FD0-stat-error", 12U, OB_RUNTIME, 0U},
    {"FD0-fl-error", 12U, OB_RUNTIME, 0U},
    {"FD0-append-observed", 12U, OB_RUNTIME, 0U},
    {"FD1-regular", 12U, OB_RUNTIME, 0U},
    {"FD1-wrong-type", 12U, OB_RUNTIME, 0U},
    {"FD1-wrong-access", 12U, OB_RUNTIME, 0U},
    {"FD1-read-write", 12U, OB_RUNTIME, 0U},
    {"FD1-missing", 12U, OB_RUNTIME, 0U},
    {"FD1-stat-error", 12U, OB_RUNTIME, 0U},
    {"FD1-fl-error", 12U, OB_RUNTIME, 0U},
    {"FD1-missing-append", 12U, OB_RUNTIME, 0U},
    {"FD2-regular", 12U, OB_RUNTIME, 0U},
    {"FD2-wrong-type", 12U, OB_RUNTIME, 0U},
    {"FD2-wrong-access", 12U, OB_RUNTIME, 0U},
    {"FD2-read-write", 12U, OB_RUNTIME, 0U},
    {"FD2-missing", 12U, OB_RUNTIME, 0U},
    {"FD2-stat-error", 12U, OB_RUNTIME, 0U},
    {"FD2-fl-error", 12U, OB_RUNTIME, 0U},
    {"FD2-missing-append", 12U, OB_RUNTIME, 0U},
    {"SCAN-zero", 12U, OB_RUNTIME, 0U},
    {"SCAN-leak3", 12U, OB_RUNTIME, 0U},
    {"SCAN-leak128-lowlimit", 12U, OB_RUNTIME, 0U},
    {"SCAN-two-leaks", 12U, OB_RUNTIME, 0U},
    {"SCAN-error-before", 12U, OB_RUNTIME, 0U},
    {"SCAN-error-after", 12U, OB_RUNTIME, 0U},
    {"SCAN-high-leak2048", 12U, OB_RUNTIME, 0U},
    {"ENV-exact", 13U, OB_RUNTIME, 0U},
    {"ENV-missing", 13U, OB_RUNTIME, 0U},
    {"ENV-extra", 13U, OB_RUNTIME, 0U},
    {"ENV-duplicate", 13U, OB_RUNTIME, 0U},
    {"ENV-wrong-value", 13U, OB_RUNTIME, 0U},
    {"ENV-wrong-order", 13U, OB_RUNTIME, 0U},
    {"ENV-empty", 13U, OB_RUNTIME, 0U},
    {"PID-1-0", 13U, OB_RUNTIME, 0U},
    {"PID-1-1", 13U, OB_RUNTIME, 0U},
    {"PID-7-1", 13U, OB_RUNTIME, 0U},
    {"PID-12-34", 13U, OB_RUNTIME, 0U},
    {"PID-44-55", 13U, OB_RUNTIME, 0U},
    {"NS-linux-0", 14U, OB_RUNTIME, 0U},
    {"NS-linux-EPERM", 14U, OB_RUNTIME, 0U},
    {"NS-linux-EACCES", 14U, OB_RUNTIME, 0U},
    {"NS-linux-EROFS", 14U, OB_RUNTIME, 0U},
    {"NS-linux-EOPNOTSUPP", 14U, OB_RUNTIME, 0U},
    {"NS-linux-EIO", 14U, OB_RUNTIME, 0U},
    {"NS-linux-ENOSYS", 14U, OB_RUNTIME, 0U},
    {"NS-linux-EINVAL", 14U, OB_RUNTIME, 0U},
    {"NS-nonlinux", 14U, OB_RUNTIME, 0U},
    {"RAW-overflow-full", 15U, OB_RUNTIME, 0U},
    {"RAW-overflow-short", 15U, OB_RUNTIME, 0U},
    {"RAW-overflow-eintr", 15U, OB_RUNTIME, 0U},
    {"RAW-overflow-allocation", 15U, OB_RUNTIME, 0U},
    {"RAW-overflow-zero", 15U, OB_RUNTIME, 0U},
    {"RAW-overflow-initial-error", 15U, OB_RUNTIME, 0U},
    {"RAW-overflow-prefix-error", 15U, OB_RUNTIME, 0U},
    {"RAW-overflow-prefix-stop", 15U, OB_RUNTIME, 0U},
    {"RAW-forged-full", 15U, OB_RUNTIME, 0U},
    {"RAW-forged-short", 15U, OB_RUNTIME, 0U},
    {"RAW-forged-eintr", 15U, OB_RUNTIME, 0U},
    {"RAW-forged-zero", 15U, OB_RUNTIME, 0U},
    {"RAW-forged-initial-error", 15U, OB_RUNTIME, 0U},
    {"RAW-forged-prefix-error", 15U, OB_RUNTIME, 0U},
    {"RAW-forged-prefix-stop", 15U, OB_RUNTIME, 0U},
    {"FILL-open-EPERM", 16U, OB_RUNTIME, 0U},
    {"FILL-open-EIO", 16U, OB_RUNTIME, 0U},
    {"FILL-malloc-ENOMEM-close-0", 16U, OB_RUNTIME, 0U},
    {"FILL-malloc-ENOMEM-close-EIO", 16U, OB_RUNTIME, 0U},
    {"FILL-malloc-0-close-0", 16U, OB_RUNTIME, 0U},
    {"FILL-malloc-0-close-EIO", 16U, OB_RUNTIME, 0U},
    {"FILL-full-close-0", 16U, OB_RUNTIME, 0U},
    {"FILL-full-close-EBADF", 16U, OB_RUNTIME, 0U},
    {"FILL-short-close-0", 16U, OB_RUNTIME, 0U},
    {"FILL-short-close-EBADF", 16U, OB_RUNTIME, 0U},
    {"FILL-eintr-close-0", 16U, OB_RUNTIME, 0U},
    {"FILL-eintr-close-EBADF", 16U, OB_RUNTIME, 0U},
    {"FILL-zero-close-0", 16U, OB_RUNTIME, 0U},
    {"FILL-zero-close-EBADF", 16U, OB_RUNTIME, 0U},
    {"FILL-initial-error-close-0", 16U, OB_RUNTIME, 0U},
    {"FILL-initial-error-close-EBADF", 16U, OB_RUNTIME, 0U},
    {"FILL-prefix-error-close-0", 16U, OB_RUNTIME, 0U},
    {"FILL-prefix-error-close-EBADF", 16U, OB_RUNTIME, 0U},
    {"FILL-capacity-error-close-0", 16U, OB_RUNTIME, 0U},
    {"FILL-capacity-error-close-EBADF", 16U, OB_RUNTIME, 0U},
    {"FILL-before-result-stop", 16U, OB_RUNTIME, 0U},
    {"RES-fork-zero", 17U, OB_RUNTIME, 0U},
    {"RES-fork-partial", 17U, OB_RUNTIME, 0U},
    {"RES-fork-child-stop", 17U, OB_RUNTIME, 0U},
    {"RES-fork-parent-stop", 17U, OB_RUNTIME, 0U},
    {"RES-thread-zero", 17U, OB_RUNTIME, 0U},
    {"RES-thread-partial", 17U, OB_RUNTIME, 0U},
    {"RES-thread-callback-stop", 17U, OB_RUNTIME, 0U},
    {"RES-thread-parent-stop", 17U, OB_RUNTIME, 0U},
    {"RES-cpu-zero", 17U, OB_RUNTIME, 0U},
    {"RES-cpu-partial", 17U, OB_RUNTIME, 0U},
    {"RES-cpu-main-stop", 17U, OB_RUNTIME, 0U},
    {"RES-cpu-worker-stop", 17U, OB_RUNTIME, 0U},
    {"RES-memory-zero", 17U, OB_RUNTIME, 0U},
    {"RES-memory-partial", 17U, OB_RUNTIME, 0U},
    {"RES-memory-stop", 17U, OB_RUNTIME, 0U},
    {"RES-sleep-return", 17U, OB_RUNTIME, 0U},
    {"RES-sleep-remainder", 17U, OB_RUNTIME, 0U},
    {"RES-sleep-stop", 17U, OB_RUNTIME, 0U},
    {"ROUT-scratch-fill-partial-error", 18U, OB_RUNTIME, 0U},
    {"ROUT-scratch-fill-partial-stop", 18U, OB_RUNTIME, 0U},
    {"ROUT-fork-bomb-partial-error", 18U, OB_RUNTIME, 0U},
    {"ROUT-fork-bomb-partial-stop", 18U, OB_RUNTIME, 0U},
    {"ROUT-thread-bomb-partial-error", 18U, OB_RUNTIME, 0U},
    {"ROUT-thread-bomb-partial-stop", 18U, OB_RUNTIME, 0U},
    {"ROUT-cpu-spin-32-partial-error", 18U, OB_RUNTIME, 0U},
    {"ROUT-cpu-spin-32-partial-stop", 18U, OB_RUNTIME, 0U},
    {"ROUT-memory-exhaustion-partial-error", 18U, OB_RUNTIME, 0U},
    {"ROUT-memory-exhaustion-partial-stop", 18U, OB_RUNTIME, 0U},
    {"ROUT-sleep-partial-error", 18U, OB_RUNTIME, 0U},
    {"ROUT-sleep-partial-stop", 18U, OB_RUNTIME, 0U},
    {"KEEP-sentinel-minimum-mismatch", 19U, OB_RUNTIME, 0U},
    {"KEEP-sentinel-maximum-mismatch", 19U, OB_RUNTIME, 0U},
    {"KEEP-mmap-failure-close-EIO", 19U, OB_RUNTIME, 0U},
    {"KEEP-fill-short-first-block", 19U, OB_RUNTIME, 0U},
    {"BUILD-missing-init-c", 20U, OB_EXTERNAL, 0U},
    {"BUILD-missing-supervisor-c", 20U, OB_EXTERNAL, 0U},
    {"BUILD-missing-probe-c", 20U, OB_EXTERNAL, 0U},
    {"BUILD-missing-common-c", 20U, OB_EXTERNAL, 0U},
    {"BUILD-missing-common-h", 20U, OB_EXTERNAL, 0U},
    {"BUILD-missing-verifiers-file-digest-v1-verifier-c", 20U, OB_EXTERNAL, 0U},
    {"BUILD-symlink-probe", 20U, OB_EXTERNAL, 0U},
    {"BUILD-target-init", 20U, OB_EXTERNAL, 0U},
    {"BUILD-target-supervisor", 20U, OB_EXTERNAL, 0U},
    {"BUILD-target-probe", 20U, OB_EXTERNAL, 0U},
    {"BUILD-target-verifier", 20U, OB_EXTERNAL, 0U},
    {"BUILD-archive-change", 20U, OB_EXTERNAL, 0U},
    {"BUILD-source-identity", 20U, OB_EXTERNAL, 0U},
    {"BUILD-header-identity", 20U, OB_EXTERNAL, 0U},
    {"BUILD-script-identity", 20U, OB_EXTERNAL, 0U},
    {"BUILD-canonical-record", 20U, OB_EXTERNAL, 0U},
    {"BUILD-private-extraction", 20U, OB_EXTERNAL, 0U},
    {"BUILD-repeat", 20U, OB_EXTERNAL, 0U},
    {"BUILD-archive-traversal", 20U, OB_EXTERNAL, 0U},
    {"BUILD-archive-absolute-path", 20U, OB_EXTERNAL, 0U},
    {"BUILD-archive-symlink", 20U, OB_EXTERNAL, 0U},
    {"BUILD-archive-hardlink", 20U, OB_EXTERNAL, 0U},
    {"BUILD-archive-fifo", 20U, OB_EXTERNAL, 0U},
    {"BUILD-archive-duplicate-member", 20U, OB_EXTERNAL, 0U},
    {"BUILD-archive-second-root", 20U, OB_EXTERNAL, 0U},
    {"BUILD-archive-file-parent-conflict", 20U, OB_EXTERNAL, 0U},
    {"BUILD-invalid-missing", 20U, OB_EXTERNAL, 0U},
    {"BUILD-invalid-symlink", 20U, OB_EXTERNAL, 0U},
    {"BUILD-invalid-corrupt", 20U, OB_EXTERNAL, 0U},
    {"BUILD-invalid-no-zig", 20U, OB_EXTERNAL, 0U},
    {"BUILD-invalid-non-executable-zig", 20U, OB_EXTERNAL, 0U},
    {"BUILD-invalid-no-output", 20U, OB_EXTERNAL, 0U},
    {"BUILD-invalid-symlink-output", 20U, OB_EXTERNAL, 0U},
    {"BUILD-partial-compile", 20U, OB_EXTERNAL, 0U},
    {"BUILD-existing-output", 20U, OB_EXTERNAL, 0U},
    {"BUILD-clean-private", 20U, OB_EXTERNAL, 0U},
    {"IMAGE-two-repeat-images", 20U, OB_EXTERNAL, 0U},
    {"IMAGE-members", 20U, OB_EXTERNAL, 0U},
    {"IMAGE-metadata", 20U, OB_EXTERNAL, 0U},
    {"IMAGE-content", 20U, OB_EXTERNAL, 0U},
    {"IMAGE-existing-image", 20U, OB_EXTERNAL, 0U},
    {"IMAGE-missing-init", 20U, OB_EXTERNAL, 0U},
    {"IMAGE-missing-supervisor", 20U, OB_EXTERNAL, 0U},
    {"INT-FRAME-repeat", 21U, OB_EXTERNAL, 0U},
    {"INT-FRAME-truncations", 21U, OB_EXTERNAL, 0U},
    {"INT-FRAME-tail", 21U, OB_EXTERNAL, 0U},
    {"INT-FRAME-damage", 21U, OB_EXTERNAL, 0U},
    {"INT-FRAME-component-bound", 21U, OB_EXTERNAL, 0U},
    {"INT-PLAN-canonical", 21U, OB_EXTERNAL, 0U},
    {"INT-PLAN-invalid", 21U, OB_EXTERNAL, 0U},
    {"INT-MATERIAL-readme", 21U, OB_EXTERNAL, 0U},
    {"INT-MATERIAL-depth", 21U, OB_EXTERNAL, 0U},
    {"INT-MATERIAL-owner-mode", 21U, OB_EXTERNAL, 0U},
    {"INT-EXEC-argv-env", 21U, OB_EXTERNAL, 0U},
    {"INT-EXEC-fd-modes", 21U, OB_EXTERNAL, 0U},
    {"INT-EXEC-close", 21U, OB_EXTERNAL, 0U},
    {"INT-EXEC-failure", 21U, OB_EXTERNAL, 0U},
    {"INT-EXEC-exit-distinction", 21U, OB_EXTERNAL, 0U},
    {"INT-EXEC-interrupt", 21U, OB_EXTERNAL, 0U},
    {"INT-EXEC-predeath", 21U, OB_EXTERNAL, 0U},
    {"INT-INVENTORY-links", 21U, OB_EXTERNAL, 0U},
    {"INT-INVENTORY-readdir", 21U, OB_EXTERNAL, 0U},
    {"INT-INTEROP-frame-digest", 21U, OB_EXTERNAL, 0U},
    {"PHASE-private-default", 22U, OB_EXTERNAL, 0U},
    {"PHASE-private-NO_SOCKET_CONSTANTS", 22U, OB_EXTERNAL, 0U},
    {"PHASE-private-MASK_NETLINK", 22U, OB_EXTERNAL, 0U},
    {"PHASE-private-MASK_PACKET", 22U, OB_EXTERNAL, 0U},
    {"PHASE-private-no-madv-remove", 22U, OB_EXTERNAL, 0U},
    {"PHASE-private-symbols", 22U, OB_EXTERNAL, 0U},
    {"PHASE-private-sanitizers-Linux", 22U, OB_EXTERNAL, 0U},
    {"PHASE-private-sanitizers-Darwin", 22U, OB_EXTERNAL, 0U},
    {"PHASE-production-init", 22U, OB_EXTERNAL, 0U},
    {"PHASE-production-supervisor", 22U, OB_EXTERNAL, 0U},
    {"PHASE-production-probe", 22U, OB_EXTERNAL, 0U},
    {"PHASE-init-helper", 22U, OB_EXTERNAL, 0U},
    {"PHASE-supervisor-helper", 22U, OB_EXTERNAL, 0U},
    {"PHASE-host-consumer", 22U, OB_EXTERNAL, 0U},
    {"PHASE-Darwin-production-limit", 22U, OB_EXTERNAL, 0U},
    {"SUITE-sandbox-guest", 22U, OB_EXTERNAL, 0U},
    {"SUITE-sandbox-launcher", 22U, OB_EXTERNAL, 0U},
    {"SUITE-sandbox-receipt", 22U, OB_EXTERNAL, 0U},
    {"SUITE-file-digest-verifier", 22U, OB_EXTERNAL, 0U},
    {"SUITE-control-sandbox-policy", 22U, OB_EXTERNAL, 0U},
    {"SUITE-candidate-content-preparation", 22U, OB_EXTERNAL, 0U},
    {"SUITE-shadow-slice", 22U, OB_EXTERNAL, 0U},
    {"SUITE-shadow-assembler", 22U, OB_EXTERNAL, 0U},
    {"SUITE-shadow-self-host-evidence", 22U, OB_EXTERNAL, 0U},
    {"SUITE-scope-qualification", 22U, OB_EXTERNAL, 0U},
    {"SUITE-portable-core-schema", 22U, OB_EXTERNAL, 0U},
    {"PHASE-static-gates", 22U, OB_EXTERNAL, 0U},
    {"PHASE-quick", 22U, OB_EXTERNAL, 0U},
    {"PHASE-full-shard-1", 22U, OB_EXTERNAL, 0U},
    {"PHASE-full-shard-2", 22U, OB_EXTERNAL, 0U},
    {"PHASE-full-shard-3", 22U, OB_EXTERNAL, 0U},
    {"PHASE-full-shard-4", 22U, OB_EXTERNAL, 0U},
    {"PHASE-full-shard-5", 22U, OB_EXTERNAL, 0U},
    {"PHASE-full-shard-6", 22U, OB_EXTERNAL, 0U},
    {"PHASE-full-aggregate", 22U, OB_EXTERNAL, 0U},
    {"PHASE-independent-review", 22U, OB_EXTERNAL, 0U},
    {"NATIVE-arm64", 23U, OB_BLOCKED, 0U},
    {"NATIVE-domain", 23U, OB_BLOCKED, 0U},
    {"NATIVE-sentinel", 23U, OB_BLOCKED, 0U},
    {"NATIVE-fd-census", 23U, OB_BLOCKED, 0U},
    {"NATIVE-signal", 23U, OB_BLOCKED, 0U},
    {"NATIVE-limits", 23U, OB_BLOCKED, 0U},
    {"NATIVE-qualification", 23U, OB_BLOCKED, 0U},
};

static int fixture_failures;
static int fixture_observed_return;
static char **fixture_saved_environment;
static const unsigned char *fixture_expected_output;
static size_t fixture_expected_output_length, fixture_expected_stdout_total;
static int fixture_expected_escape, fixture_expected_return;
static char **fixture_case_environment;
static int fixture_postcheck_kind;
static void fixture_check(int condition, const char *message);

struct case_obligation_alias {
    const char *case_name, *id;
};
static const struct case_obligation_alias case_obligation_aliases[] = {
    {"fixture-rejects-wrong-path", "FIX-path"},
    {"fixture-rejects-missing-step", "FIX-missing-call"},
    {"fixture-rejects-wrong-order", "FIX-order"},
    {"fixture-rejects-wrong-flags", "FIX-flags"},
    {"fixture-rejects-wrong-fd", "FIX-fd"},
    {"fixture-rejects-wrong-length", "FIX-length"},
    {"fixture-rejects-wrong-bytes", "FIX-bytes"},
    {"fixture-rejects-invalid-write-return", "FIX-invalid-write-return"},
    {"fixture-rejects-invalid-object", "FIX-bad-allocation-object"},
    {"fixture-rejects-leftover-step", "FIX-leftover"},
    {"fixture-rejects-missing-write-byte-expectation", "FIX-missing-byte-oracle"},
    {"fixture-rejects-duplicate-live-allocation", "FIX-duplicate-live-allocation"},
    {"fixture-rejects-invalid-free", "FIX-invalid-free"},
    {"fixture-rejects-uninitialized-stat", "FIX-uninitialized-stat"},
    {"fixture-rejects-uninitialized-thread-token", "FIX-uninitialized-thread-token"},
    {"fixture-rejects-returning-callback", "FIX-returning-callback"},
    {"descriptors-zero-leaks", "FD0-regular"},
    {"descriptors-zero-leaks", "FD1-regular"},
    {"descriptors-zero-leaks", "FD2-regular"},
    {"descriptors-zero-leaks", "FD0-append-observed"},
    {"descriptors-zero-leaks", "SCAN-zero"},
    {"descriptors-fd3", "SCAN-leak3"},
    {"descriptors-fd128-softlimit-model", "SCAN-leak128-lowlimit"},
    {"descriptors-two-leaks", "SCAN-two-leaks"},
    {"descriptors-error-before-leak", "SCAN-error-before"},
    {"descriptors-error-after-leak", "SCAN-error-after"},
    {"obligation-descriptors-modeled-fd2048-invisible", "SCAN-high-leak2048"},
    {"descriptor-fd0-nonregular", "FD0-wrong-type"},
    {"descriptor-fd0-wrong-access", "FD0-wrong-access"},
    {"obligation-descriptor-fd0-ordwr", "FD0-read-write"},
    {"descriptor-fd0-missing", "FD0-missing"},
    {"descriptor-fd0-fstat-error", "FD0-stat-error"},
    {"descriptor-fd0-fcntl-error", "FD0-fl-error"},
    {"descriptor-fd1-nonregular", "FD1-wrong-type"},
    {"descriptor-fd1-wrong-access", "FD1-wrong-access"},
    {"obligation-descriptor-fd1-ordwr", "FD1-read-write"},
    {"descriptor-fd1-missing", "FD1-missing"},
    {"descriptor-fd1-fstat-error", "FD1-stat-error"},
    {"descriptor-fd1-fcntl-error", "FD1-fl-error"},
    {"descriptor-fd1-no-append", "FD1-missing-append"},
    {"descriptor-fd2-nonregular", "FD2-wrong-type"},
    {"descriptor-fd2-wrong-access", "FD2-wrong-access"},
    {"obligation-descriptor-fd2-ordwr", "FD2-read-write"},
    {"descriptor-fd2-missing", "FD2-missing"},
    {"descriptor-fd2-fstat-error", "FD2-stat-error"},
    {"descriptor-fd2-fcntl-error", "FD2-fl-error"},
    {"descriptor-fd2-no-append", "FD2-missing-append"},
    {"environment-control", "ENV-exact"},
    {"environment-missing", "ENV-missing"},
    {"environment-extra", "ENV-extra"},
    {"environment-duplicate", "ENV-duplicate"},
    {"environment-wrong", "ENV-wrong-value"},
    {"environment-order", "ENV-wrong-order"},
    {"environment-empty", "ENV-empty"},
    {"pid-private", "PID-1-0"},
    {"pid-self", "PID-1-1"},
    {"pid-orphan", "PID-7-1"},
    {"pid-visible", "PID-12-34"},
    {"pid-unexpected", "PID-44-55"},
    {"obligation-namespace-nonlinux-no-attempt", "NS-nonlinux"},
    {"fork-failure-before-worker", "RES-fork-zero"},
    {"fork-partial-return", "RES-fork-partial"},
    {"fork-child-real-pause-stop", "RES-fork-child-stop"},
    {"fork-parent-stop", "RES-fork-parent-stop"},
    {"thread-failure-before-worker", "RES-thread-zero"},
    {"thread-partial-initialized-tokens", "RES-thread-partial"},
    {"thread-dispatch-real-paused-worker-stop", "RES-thread-callback-stop"},
    {"thread-parent-stop", "RES-thread-parent-stop"},
    {"obligation-cpu-create-failure-after-0", "RES-cpu-zero"},
    {"obligation-cpu-create-failure-after-2", "RES-cpu-partial"},
    {"cpu-full-31-plus-main-worker-stop", "RES-cpu-main-stop"},
    {"cpu-dispatch-real-spinning-worker-stop", "RES-cpu-worker-stop"},
    {"memory-first-allocation-failure", "RES-memory-zero"},
    {"memory-distinct-blocks-partial", "RES-memory-partial"},
    {"obligation-memory-stop-on-later-allocation-before-result", "RES-memory-stop"},
    {"sleep-remainder-loop", "RES-sleep-return"},
    {"sleep-remainder-loop", "RES-sleep-remainder"},
    {"sleep-before-completion-stop", "RES-sleep-stop"},
    {"ROUT-fork-bomb-during-stop", "ROUT-fork-bomb-partial-stop"},
    {"ROUT-thread-bomb-during-stop", "ROUT-thread-bomb-partial-stop"},
    {"ROUT-cpu-spin-32-during-stop", "ROUT-cpu-spin-32-partial-stop"},
    {"ROUT-memory-exhaustion-during-stop", "ROUT-memory-exhaustion-partial-stop"},
    {"ROUT-sleep-during-stop", "ROUT-sleep-partial-stop"},
    {"ROUT-scratch-fill-during-stop", "ROUT-scratch-fill-partial-stop"},
    {"SEN-host-minimum", "KEEP-sentinel-minimum-mismatch"},
    {"SEN-host-maximum", "PAR-valid-cap-limit"},
    {"SEN-host-maximum", "KEEP-sentinel-maximum-mismatch"},
    {"SS-madv-remove-mmap-close-EBADF", "KEEP-mmap-failure-close-EIO"},
    {"FILL-short-close-0", "KEEP-fill-short-first-block"},
    {"obligation-memory-stop-on-later-allocation-before-result", "FIX-memory-final"},
};

static size_t obligation_index(const char *id)
{
    size_t i;
    for (i = 0; i < sizeof obligation_registry / sizeof obligation_registry[0]; i++)
        if (strcmp(id, obligation_registry[i].id) == 0)
            return i;
    return sizeof obligation_registry / sizeof obligation_registry[0];
}

static int obligation_selected(const struct obligation_binding *binding)
{
    const char *id = binding->id;
    if (binding->state != OB_RUNTIME)
        return 0;
#if defined(__linux__)
    if (strcmp(id, "NS-nonlinux") == 0)
        return 0;
#else
    if (strncmp(id, "NS-linux-", 9U) == 0 || strstr(id, "fallocate") != NULL ||
        strstr(id, "tmpfile") != NULL || strcmp(id, "SF-platform-fallocate") == 0 ||
        strcmp(id, "SF-platform-tmpfile") == 0)
        return 0;
#endif
#if !defined(MADV_REMOVE)
    if (strncmp(id, "SS-madv-remove-", 15U) == 0 || strncmp(id, "SA-madv-remove-", 15U) == 0 ||
        strcmp(id, "KEEP-mmap-failure-close-EIO") == 0)
        return 0;
#endif
    if (strncmp(id, "FACT-", 5U) == 0 || strncmp(id, "HENTRY-", 7U) == 0) {
#if defined(YSTACK_TEST_NO_SOCKET_CONSTANTS)
        return strstr(id, "-no-socket-constants-") != NULL;
#elif defined(YSTACK_TEST_MASK_NETLINK)
        return strstr(id, "-mask-netlink-") != NULL;
#elif defined(YSTACK_TEST_MASK_PACKET)
        return strstr(id, "-mask-packet-") != NULL;
#else
        return strstr(id, "-default-") != NULL;
#endif
    }
    return 1;
}

static void obligation_credit(const char *id)
{
    size_t i = obligation_index(id);
    if (i == sizeof obligation_registry / sizeof obligation_registry[0]) {
        fixture_check(0, "unknown obligation credit");
        return;
    }
    if (!obligation_selected(&obligation_registry[i])) {
        fixture_check(0, "inapplicable obligation credit");
        return;
    }
    if (obligation_registry[i].seen != 0U) {
        fixture_check(0, "duplicate obligation credit");
        return;
    }
    obligation_registry[i].seen = 1U;
}

static void credit_ids(const char *const *ids, size_t count, int failures_before)
{
    size_t i;
    if (fixture_failures != failures_before)
        return;
    for (i = 0; i < count; i++)
        obligation_credit(ids[i]);
}

static void finish_obligation_family(unsigned family, int failures_before)
{
    size_t i;
    if (fixture_failures != failures_before)
        return;
    for (i = 0; i < sizeof obligation_registry / sizeof obligation_registry[0]; i++) {
        struct obligation_binding *binding = &obligation_registry[i];
        if (binding->state != OB_RUNTIME || binding->family != family)
            continue;
        if (binding->seen != (unsigned char)obligation_selected(binding)) {
            (void)fprintf(stderr, "FAIL obligation %s selected=%d credits=%u\n", binding->id,
                          obligation_selected(binding), binding->seen);
            fixture_failures++;
        }
        if (obligation_selected(binding) && binding->seen == 1U)
            (void)printf("obligation %s: ok\n", binding->id);
    }
}

static void fixture_check(int condition, const char *message)
{
    if (!condition) {
        (void)fprintf(stderr, "FAIL %s\n", message);
        fixture_failures++;
    }
}

static void fixture_reset(void)
{
    memset(fixture_steps, 0, sizeof fixture_steps);
    fixture_step_count = 0;
    fixture_step_index = 0;
    fixture_capture_length = 0;
    fixture_stdout_total = 0;
    fixture_escape = 0;
    fixture_failure = NULL;
    fixture_expected_output = NULL;
    fixture_expected_output_length = 0;
    fixture_expected_stdout_total = 0;
    fixture_expected_escape = 3;
    fixture_expected_return = 0;
    fixture_socket_override = NULL;
    fixture_case_environment = NULL;
    fixture_postcheck_kind = 0;
    memset(fixture_blocks, 0xa5, sizeof fixture_blocks);
    memset(fixture_block_live, 0, sizeof fixture_block_live);
    memset(fixture_mapping, 0x5a, sizeof fixture_mapping);
    fixture_modeled_fd2048_open = 0;
    fixture_modeled_fd2048_queried = 0;
}

static struct fixture_step *queue_return(enum fixture_op op, long returned, int error_number)
{
    struct fixture_step *s = fixture_push(op);
    s->returned = returned;
    s->error_number = error_number;
    return s;
}

static void queue_read(int fd, size_t requested, const void *bytes, size_t returned)
{
    struct fixture_step *s = queue_return(FX_READ, (long)returned, 0);
    s->call.io.fd = fd;
    s->call.io.length = requested;
    s->read_bytes = bytes;
    s->read_length = returned;
}

static void queue_read_error(int fd, size_t requested, int error_number)
{
    struct fixture_step *s = queue_return(FX_READ, -1, error_number);
    s->call.io.fd = fd;
    s->call.io.length = requested;
}

static void queue_instruction(const char *instruction)
{
    size_t length = strlen(instruction);
    queue_read(STDIN_FILENO, INPUT_CAP + 1U, instruction, length);
    if (length != 0U)
        queue_read(STDIN_FILENO, INPUT_CAP + 1U - length, NULL, 0);
}

static void queue_write_exact(int fd, const void *bytes, size_t length, long returned,
                              int error_number)
{
    struct fixture_step *s = queue_return(FX_WRITE, returned, error_number);
    s->call.io.fd = fd;
    s->call.io.length = length;
    s->call.io.kind = FX_BYTES_EXACT;
    s->call.io.bytes = bytes;
}

static void queue_write_repeat(int fd, unsigned char byte, size_t length, long returned,
                               int error_number)
{
    struct fixture_step *s = queue_return(FX_WRITE, returned, error_number);
    s->call.io.fd = fd;
    s->call.io.length = length;
    s->call.io.kind = FX_BYTES_REPEAT;
    s->call.io.byte = byte;
}

static void queue_open(const char *path, int flags, mode_t mode, int returned, int error_number)
{
    struct fixture_step *s = queue_return(FX_OPEN, returned, error_number);
    s->call.open.path = path;
    s->call.open.flags = flags;
    s->call.open.mode = mode;
}

static void queue_close(int fd, int returned, int error_number)
{
    struct fixture_step *s = queue_return(FX_CLOSE, returned, error_number);
    s->call.close.fd = fd;
}

static void queue_fstat(int fd, mode_t mode, int returned, int error_number)
{
    struct fixture_step *s = queue_return(FX_FSTAT, returned, error_number);
    s->call.fstat.fd = fd;
    s->stat_mode = mode;
}

static void queue_fcntl(int fd, int command, int returned, int error_number)
{
    struct fixture_step *s = queue_return(FX_FCNTL, returned, error_number);
    s->call.fcntl.fd = fd;
    s->call.fcntl.command = command;
}

static size_t oracle_line(char *line, size_t cap, const char *instruction, const char *checks,
                          const char *domain, const struct oracle_record *records, size_t count)
{
    char digest[65];
    size_t used = 0, i;
    int n;
    digest_hex(instruction, strlen(instruction), digest);
    n = snprintf(line, cap, "YSPROBE1 %.*s %s %s %s %zu",
                 (int)(strchr(instruction + 9, ' ') != NULL
                           ? (size_t)(strchr(instruction + 9, ' ') - (instruction + 9))
                           : strcspn(instruction + 9, "\n")),
                 instruction + 9, digest, checks, domain, count);
    if (n < 0 || (size_t)n >= cap)
        fixture_fail("oracle header");
    used = (size_t)n;
    for (i = 0; i < count; i++) {
        const struct oracle_record *r = &records[i];
        n = snprintf(line + used, cap - used, " %s:%s:%d:%d:%s:%d:%d:%llu:%llu:%llu", r->name,
                     r->pre, r->attempted, r->completed, r->outcome, r->error_number,
                     r->cleanup_error, (unsigned long long)r->value[0],
                     (unsigned long long)r->value[1], (unsigned long long)r->value[2]);
        if (n < 0 || (size_t)n >= cap - used)
            fixture_fail("oracle record");
        used += (size_t)n;
    }
    if (used + 1U >= cap)
        fixture_fail("oracle newline");
    line[used++] = '\n';
    line[used] = '\0';
    return used;
}

static void expect_output(const void *bytes, size_t length, int returned)
{
    fixture_expected_output = bytes;
    fixture_expected_output_length = length;
    fixture_expected_stdout_total = length;
    fixture_expected_return = returned;
    queue_write_exact(STDOUT_FILENO, bytes, length, (long)length, 0);
}

static void run_case(const char *name)
{
    extern char **environ;
    int failures_before = fixture_failures;
    fixture_saved_environment = environ;
    if (fixture_case_environment != NULL)
        environ = fixture_case_environment;
    fixture_driver_active = 1;
    if (setjmp(fixture_jump) == 0) {
        fixture_observed_return = probe_main();
        fixture_escape = 3;
    }
    fixture_driver_active = 0;
    environ = fixture_saved_environment;
    fixture_socket_override = NULL;
    if (fixture_expected_escape == 1 && fixture_escape == 3 &&
        fixture_step_index != fixture_step_count) {
        size_t alias;
        if (fixture_failures == failures_before) {
            for (alias = 0;
                 alias < sizeof case_obligation_aliases / sizeof case_obligation_aliases[0];
                 alias++) {
                if (strcmp(name, case_obligation_aliases[alias].case_name) == 0)
                    obligation_credit(case_obligation_aliases[alias].id);
            }
        }
        (void)printf("control %s: rejected\n", name);
        return;
    }
    if (fixture_escape != fixture_expected_escape) {
        (void)fprintf(stderr, "FAIL %s escape=%d expected=%d detail=%s\n", name, fixture_escape,
                      fixture_expected_escape, fixture_failure == NULL ? "none" : fixture_failure);
        fixture_failures++;
    } else if (fixture_escape != 1) {
        fixture_check(fixture_step_index == fixture_step_count, "script fully consumed");
        fixture_check(fixture_stdout_total == fixture_expected_stdout_total, "stdout total");
        if (fixture_expected_output != NULL)
            fixture_check(fixture_capture_length == fixture_expected_output_length &&
                              memcmp(fixture_capture, fixture_expected_output,
                                     fixture_expected_output_length) == 0,
                          "exact stdout bytes");
        if (fixture_escape == 3)
            fixture_check(fixture_observed_return == fixture_expected_return, "exact probe return");
    }
    if (fixture_escape == fixture_expected_escape && fixture_escape != 1 &&
        fixture_postcheck_kind == 2) {
        fixture_check(fixture_modeled_fd2048_open, "modeled fd2048 remains open");
        fixture_check(!fixture_modeled_fd2048_queried, "scan never queried modeled fd2048");
    }
    if (fixture_escape == fixture_expected_escape && fixture_escape != 1 &&
        fixture_postcheck_kind == 1) {
        size_t object, offset;
        for (object = 0; object < 2U; object++)
            for (offset = 0; offset < BLOCK_SIZE; offset++)
                if (fixture_blocks[object][offset] != (offset % 4096U == 0U ? 0U : 0xa5U)) {
                    fixture_check(0, "memory page and guard bytes before credit");
                    object = 2U;
                    break;
                }
    }
    if (fixture_escape == fixture_expected_escape && fixture_escape != 1 &&
        fixture_failures == failures_before) {
        size_t obligation = obligation_index(name);
        size_t alias;
        if (obligation < sizeof obligation_registry / sizeof obligation_registry[0] &&
            obligation_selected(&obligation_registry[obligation]))
            obligation_credit(name);
        for (alias = 0; alias < sizeof case_obligation_aliases / sizeof case_obligation_aliases[0];
             alias++)
            if (strcmp(name, case_obligation_aliases[alias].case_name) == 0)
                obligation_credit(case_obligation_aliases[alias].id);
        (void)printf("case %s: checked\n", name);
    }
    if (fixture_escape == 1 && fixture_expected_escape == 1) {
        size_t alias;
        if (fixture_failures == failures_before)
            for (alias = 0;
                 alias < sizeof case_obligation_aliases / sizeof case_obligation_aliases[0];
                 alias++)
                if (strcmp(name, case_obligation_aliases[alias].case_name) == 0)
                    obligation_credit(case_obligation_aliases[alias].id);
        (void)printf("control %s: rejected\n", name);
    }
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
    fixture_reset();
    queue_instruction(request);
    queue_open("/wrong", O_RDONLY | O_CLOEXEC, 0, 41, 0);
    fixture_expected_escape = 1;
    run_case("fixture-rejects-wrong-path");

    fixture_reset();
    queue_instruction(request);
    fixture_expected_escape = 1;
    run_case("fixture-rejects-missing-step");

    fixture_reset();
    queue_instruction("bad\n");
    queue_write_exact(STDOUT_FILENO, "YSPROBE1 error=input\n", 21U, 22, 0);
    fixture_expected_escape = 1;
    run_case("fixture-rejects-invalid-write-return");

    fixture_reset();
    queue_instruction(request);
    queue_return(FX_CLOSE, 0, 0);
    fixture_expected_escape = 1;
    run_case("fixture-rejects-wrong-order");
    fixture_reset();
    queue_instruction(request);
    queue_open("/sandbox/candidate/README.md", O_WRONLY | O_CLOEXEC, 0, 41, 0);
    fixture_expected_escape = 1;
    run_case("fixture-rejects-wrong-flags");
    fixture_reset();
    queue_instruction(request);
    queue_open("/sandbox/candidate/README.md", O_RDONLY | O_CLOEXEC, 0, 41, 0);
    queue_read(42, 1, "x", 1);
    fixture_expected_escape = 1;
    run_case("fixture-rejects-wrong-fd");
    fixture_reset();
    queue_instruction(request);
    queue_open("/sandbox/candidate/README.md", O_RDONLY | O_CLOEXEC, 0, 41, 0);
    queue_read(41, 2, "xx", 2);
    fixture_expected_escape = 1;
    run_case("fixture-rejects-wrong-length");
    fixture_reset();
    queue_instruction("bad\n");
    queue_write_exact(STDOUT_FILENO, "XXXXXXXXXXXXXXXXXXXXX", 21, 21, 0);
    fixture_expected_escape = 1;
    run_case("fixture-rejects-wrong-bytes");
    fixture_reset();
    queue_instruction("YSPROBE1 output-overflow\n");
    {
        struct fixture_step *s = queue_return(FX_MALLOC, 1, 0);
        s->call.allocation.size = BLOCK_SIZE;
        s->call.allocation.object = FIXTURE_OBJECTS;
    }
    fixture_expected_escape = 1;
    run_case("fixture-rejects-invalid-object");
    fixture_reset();
    queue_instruction("bad\n");
    expect_output("YSPROBE1 error=input\n", 21, 64);
    queue_return(FX_CLOSE, 0, 0);
    fixture_expected_escape = 1;
    run_case("fixture-rejects-leftover-step");

    fixture_reset();
    queue_instruction("bad\n");
    {
        struct fixture_step *s = queue_return(FX_WRITE, 21, 0);
        s->call.io.fd = STDOUT_FILENO;
        s->call.io.length = 21;
    }
    fixture_expected_escape = 1;
    run_case("fixture-rejects-missing-write-byte-expectation");

    fixture_reset();
    queue_instruction("YSPROBE1 output-overflow\n");
    fixture_block_live[0] = 1;
    {
        struct fixture_step *s = queue_return(FX_MALLOC, 1, 0);
        s->call.allocation.size = BLOCK_SIZE;
        s->call.allocation.object = 0;
    }
    fixture_expected_escape = 1;
    run_case("fixture-rejects-duplicate-live-allocation");

    {
        int failures_before = fixture_failures;
        struct fixture_step *step;
        fixture_reset();
        step = queue_return(FX_FREE, 0, 0);
        step->call.object.object = 0;
        fixture_driver_active = 1;
        if (setjmp(fixture_jump) == 0)
            fixture_free(fixture_blocks[0]);
        fixture_driver_active = 0;
        fixture_check(fixture_escape == 1 && fixture_step_index == fixture_step_count,
                      "fixture rejects invalid free before obligation credit");
        if (fixture_failures == failures_before)
            obligation_credit("FIX-invalid-free");
        (void)puts("control fixture-rejects-invalid-free: rejected");
    }

    fixture_reset();
    queue_instruction("YSPROBE1 descriptors\n");
    {
        struct fixture_step *step = queue_return(FX_FSTAT, 0, 0);
        step->call.fstat.fd = 0;
    }
    fixture_expected_escape = 1;
    run_case("fixture-rejects-uninitialized-stat");

    fixture_reset();
    queue_instruction("YSPROBE1 thread-bomb\n");
    {
        struct fixture_step *step = queue_return(FX_PTHREAD_CREATE, 0, 0);
        step->call.thread.entry = paused_thread;
        step->call.thread.argument = NULL;
    }
    fixture_expected_escape = 1;
    run_case("fixture-rejects-uninitialized-thread-token");

    fixture_reset();
    queue_instruction("YSPROBE1 thread-bomb\n");
    {
        struct fixture_step *step = queue_return(FX_PTHREAD_CREATE, 0, 0);
        step->call.thread.entry = fixture_returning_thread;
        step->call.thread.argument = NULL;
        step->call.thread.token = (pthread_t)1;
        step->call.thread.dispatch = 1;
    }
    fixture_expected_escape = 1;
    run_case("fixture-rejects-returning-callback");
}

static void parser_invalid_case(const char *name, const void *bytes, size_t length)
{
    static const char diagnostic[] = "YSPROBE1 error=input\n";
    fixture_reset();
    if (length != 0U)
        queue_read(STDIN_FILENO, INPUT_CAP + 1U, bytes, length);
    if (length <= INPUT_CAP)
        queue_read(STDIN_FILENO, INPUT_CAP + 1U - length, NULL, 0);
    expect_output(diagnostic, sizeof diagnostic - 1U, 64);
    run_case(name);
}

static void parser_cases(void)
{
    static const struct {
        const char *id, *text;
    } fixed[] = {{"PAR-empty", ""},
                 {"PAR-bad-magic", "candidate-read\n"},
                 {"PAR-unknown-mode", "YSPROBE1 unknown\n"},
                 {"PAR-double-space", "YSPROBE1  candidate-read\n"},
                 {"PAR-trailing-space", "YSPROBE1 candidate-read \n"},
                 {"PAR-leading-space", " YSPROBE1 candidate-read\n"},
                 {"PAR-tab-separator", "YSPROBE1\tcandidate-read\n"},
                 {"PAR-missing-lf", "YSPROBE1 candidate-read"},
                 {"PAR-crlf", "YSPROBE1 candidate-read\r\n"},
                 {"PAR-extra-line", "YSPROBE1 candidate-read\nYSPROBE1 environment\n"},
                 {"PAR-trailing-byte", "YSPROBE1 candidate-read\nx"},
                 {"PAR-socket-leading-zero", "YSPROBE1 socket-family 00\n"},
                 {"PAR-socket-plus", "YSPROBE1 socket-family +1\n"},
                 {"PAR-socket-negative", "YSPROBE1 socket-family -1\n"},
                 {"PAR-socket-max-plus-one", "YSPROBE1 socket-family 65536\n"},
                 {"PAR-socket-uint-overflow", "YSPROBE1 socket-family 18446744073709551616\n"},
                 {"PAR-socket-nondigit", "YSPROBE1 socket-family 1x\n"},
                 {"PAR-arity-socket-0", "YSPROBE1 socket-family\n"},
                 {"PAR-arity-socket-2", "YSPROBE1 socket-family 0 1\n"},
                 {"PAR-arity-host-sentinel-0", "YSPROBE1 host-sentinel\n"},
                 {"PAR-arity-host-sentinel-1", "YSPROBE1 host-sentinel 2f78\n"},
                 {"PAR-arity-host-sentinel-2", "YSPROBE1 host-sentinel 2f78 1\n"},
                 {"PAR-arity-host-sentinel-4",
                  "YSPROBE1 host-sentinel 2f78 1 "
                  "0000000000000000000000000000000000000000000000000000000000000000 x\n"},
                 {"PAR-arity-sibling-sentinel-0", "YSPROBE1 sibling-sentinel\n"},
                 {"PAR-arity-sibling-sentinel-1", "YSPROBE1 sibling-sentinel 2f78\n"},
                 {"PAR-arity-sibling-sentinel-2", "YSPROBE1 sibling-sentinel 2f78 1\n"},
                 {"PAR-arity-sibling-sentinel-4",
                  "YSPROBE1 sibling-sentinel 2f78 1 "
                  "0000000000000000000000000000000000000000000000000000000000000000 x\n"}};
    static const char *const zero_modes[] = {"candidate-read",
                                             "candidate-write",
                                             "tools-write",
                                             "evidence-read",
                                             "evidence-list",
                                             "evidence-reopen",
                                             "evidence-truncate",
                                             "evidence-link",
                                             "evidence-rename",
                                             "scratch-free",
                                             "scratch-fill",
                                             "output-overflow",
                                             "environment",
                                             "descriptors",
                                             "fork-bomb",
                                             "thread-bomb",
                                             "cpu-spin-32",
                                             "memory-exhaustion",
                                             "sleep",
                                             "signal-supervisor",
                                             "namespace-escape",
                                             "cgroup-escape",
                                             "forged-report-stdout",
                                             "forged-report-evidence"};
    static const struct {
        const char *suffix, *path, *size, *digest;
    } sentinel_bad[] = {
        {"odd-hex", "2f7", "1", "0000000000000000000000000000000000000000000000000000000000000000"},
        {"nonhex", "2fzz", "1", "0000000000000000000000000000000000000000000000000000000000000000"},
        {"upper-path", "2F78", "1",
         "0000000000000000000000000000000000000000000000000000000000000000"},
        {"relative", "78", "1", "0000000000000000000000000000000000000000000000000000000000000000"},
        {"nul-path", "2f7800", "1",
         "0000000000000000000000000000000000000000000000000000000000000000"},
        {"root-empty-component", "2f", "1",
         "0000000000000000000000000000000000000000000000000000000000000000"},
        {"empty-component", "2f2f78", "1",
         "0000000000000000000000000000000000000000000000000000000000000000"},
        {"trailing-slash", "2f782f", "1",
         "0000000000000000000000000000000000000000000000000000000000000000"},
        {"dot-component", "2f2e", "1",
         "0000000000000000000000000000000000000000000000000000000000000000"},
        {"dotdot-component", "2f782f2e2e", "1",
         "0000000000000000000000000000000000000000000000000000000000000000"},
        {"size-zero", "2f78", "0",
         "0000000000000000000000000000000000000000000000000000000000000000"},
        {"size-too-large", "2f78", "4097",
         "0000000000000000000000000000000000000000000000000000000000000000"},
        {"size-leading-zero", "2f78", "01",
         "0000000000000000000000000000000000000000000000000000000000000000"},
        {"size-plus", "2f78", "+1",
         "0000000000000000000000000000000000000000000000000000000000000000"},
        {"size-negative", "2f78", "-1",
         "0000000000000000000000000000000000000000000000000000000000000000"},
        {"size-overflow", "2f78", "18446744073709551616",
         "0000000000000000000000000000000000000000000000000000000000000000"},
        {"size-nondigit", "2f78", "1x",
         "0000000000000000000000000000000000000000000000000000000000000000"},
        {"digest-short", "2f78", "1",
         "000000000000000000000000000000000000000000000000000000000000000"},
        {"digest-long", "2f78", "1",
         "00000000000000000000000000000000000000000000000000000000000000000"},
        {"digest-upper", "2f78", "1",
         "A000000000000000000000000000000000000000000000000000000000000000"},
        {"digest-nonhex", "2f78", "1",
         "g000000000000000000000000000000000000000000000000000000000000000"}};
    static const unsigned char embedded_nul[] = {'Y', 'S', 0, 'P'};
    static const unsigned char non_ascii[] = "YSPROBE1 candidate-read \200\n";
    static unsigned char boundary[INPUT_CAP + 1U];
    size_t i, role;
    char instruction[INPUT_CAP + 1U], name[128];

    for (i = 0; i < sizeof fixed / sizeof fixed[0]; i++)
        parser_invalid_case(fixed[i].id, fixed[i].text, strlen(fixed[i].text));
    parser_invalid_case("PAR-embedded-nul", embedded_nul, sizeof embedded_nul);
    parser_invalid_case("PAR-non-ascii", non_ascii, sizeof non_ascii - 1U);

    for (i = 0; i < sizeof zero_modes / sizeof zero_modes[0]; i++) {
        (void)snprintf(instruction, sizeof instruction, "YSPROBE1 %s x\n", zero_modes[i]);
        (void)snprintf(name, sizeof name, "PAR-arity-%s", zero_modes[i]);
        parser_invalid_case(name, instruction, strlen(instruction));
    }
    for (role = 0; role < 2U; role++) {
        const char *mode = role == 0U ? "host-sentinel" : "sibling-sentinel";
        for (i = 0; i < sizeof sentinel_bad / sizeof sentinel_bad[0]; i++) {
            (void)snprintf(instruction, sizeof instruction, "YSPROBE1 %s %s %s %s\n", mode,
                           sentinel_bad[i].path, sentinel_bad[i].size, sentinel_bad[i].digest);
            (void)snprintf(name, sizeof name, "PAR-%s-%s", mode, sentinel_bad[i].suffix);
            parser_invalid_case(name, instruction, strlen(instruction));
        }
        memset(instruction, 0, sizeof instruction);
        (void)snprintf(instruction, sizeof instruction, "YSPROBE1 %s 2f", mode);
        for (i = 0; i < 4096U; i++)
            (void)strcat(instruction, "61");
        (void)snprintf(instruction + strlen(instruction), sizeof instruction - strlen(instruction),
                       " 1 0000000000000000000000000000000000000000000000000000000000000000\n");
        (void)snprintf(name, sizeof name, "PAR-%s-path-too-long", mode);
        parser_invalid_case(name, instruction, strlen(instruction));
    }

    memset(boundary, 'x', sizeof boundary);
    parser_invalid_case("PAR-cap", boundary, INPUT_CAP);
    fixture_reset();
    queue_read(STDIN_FILENO, INPUT_CAP + 1U, boundary, INPUT_CAP + 1U);
    expect_output("YSPROBE1 error=input\n", 21U, 64);
    run_case("PAR-overflow");
    fixture_reset();
    queue_read_error(STDIN_FILENO, INPUT_CAP + 1U, EIO);
    expect_output("YSPROBE1 error=read\n", 20U, 64);
    run_case("PAR-read-error");
    fixture_reset();
    queue_read(STDIN_FILENO, INPUT_CAP + 1U, "YSPROBE", 7U);
    queue_read_error(STDIN_FILENO, INPUT_CAP + 1U - 7U, EIO);
    expect_output("YSPROBE1 error=read\n", 20U, 64);
    run_case("PAR-read-error-after-prefix");
}

static void candidate_read_case(const char *id, int open_error, long read_return, int read_error,
                                int close_error)
{
    static const char instruction[] = "YSPROBE1 candidate-read\n";
    char output[512];
    const char *outcome;
    int completed;
    struct oracle_record r;
    if (open_error != 0) {
        outcome = open_error == EPERM || open_error == EACCES || open_error == EROFS ? "refused"
                  : open_error == EOPNOTSUPP                                         ? "unsupported"
                                                                                     : "incomplete";
        completed = open_error == EPERM || open_error == EACCES || open_error == EROFS;
    } else if (read_return >= 0) {
        outcome = "success";
        completed = 1;
    } else {
        outcome = read_error == EPERM || read_error == EACCES || read_error == EROFS ? "refused"
                  : read_error == EOPNOTSUPP                                         ? "unsupported"
                                                                                     : "incomplete";
        completed = read_error == EPERM || read_error == EACCES || read_error == EROFS;
    }
    r = (struct oracle_record){
        "read",
        "ok",
        outcome,
        1,
        completed,
        open_error != 0   ? open_error
        : read_return < 0 ? read_error
                          : 0,
        close_error,
        {read_return > 0 ? (uint64_t)read_return : 0U, read_return > 0 ? (uint64_t)'x' : 0U, 0}};
    fixture_reset();
    queue_instruction(instruction);
    queue_open("/sandbox/candidate/README.md", O_RDONLY | O_CLOEXEC, 0, open_error ? -1 : 41,
               open_error);
    if (!open_error) {
        if (read_return < 0)
            queue_read_error(41, 1U, read_error);
        else
            queue_read(41, 1U, read_return ? "x" : NULL, (size_t)read_return);
        queue_close(41, close_error ? -1 : 0, close_error);
    }
    expect_output(output,
                  oracle_line(output, sizeof output, instruction,
                              completed && close_error == 0 ? "complete" : "incomplete", "none", &r,
                              1U),
                  0);
    run_case(id);
}

static void candidate_cases(void)
{
    static const struct {
        const char *name;
        int error;
    } errors[] = {{"EPERM", EPERM},           {"EACCES", EACCES}, {"EROFS", EROFS},
                  {"EOPNOTSUPP", EOPNOTSUPP}, {"EIO", EIO},       {"ENOENT", ENOENT}};
    static const struct {
        const char *name;
        long returned;
        int error;
    } reads[] = {{"byte", 1, 0},         {"eof", 0, 0},        {"EPERM", -1, EPERM},
                 {"EACCES", -1, EACCES}, {"EROFS", -1, EROFS}, {"EOPNOTSUPP", -1, EOPNOTSUPP},
                 {"EIO", -1, EIO}};
    size_t i, j;
    char id[96];
    for (i = 0; i < sizeof errors / sizeof errors[0]; i++) {
        (void)snprintf(id, sizeof id, "CR-open-%s", errors[i].name);
        candidate_read_case(id, errors[i].error, 0, 0, 0);
    }
    for (i = 0; i < sizeof reads / sizeof reads[0]; i++)
        for (j = 0; j < 2U; j++) {
            (void)snprintf(id, sizeof id, "CR-read-%s-close-%s", reads[i].name, j ? "EIO" : "0");
            candidate_read_case(id, 0, reads[i].returned, reads[i].error, j ? EIO : 0);
        }
    {
        static const char instruction[] = "YSPROBE1 candidate-read\n";
        char output[512];
        struct oracle_record r = {"read", "ok", "success", 1, 1, 0, 0, {1, 'x', 0}};
        const size_t split = 7;
        fixture_reset();
        queue_read(STDIN_FILENO, INPUT_CAP + 1U, instruction, split);
        queue_read_error(STDIN_FILENO, INPUT_CAP + 1U - split, EINTR);
        queue_read(STDIN_FILENO, INPUT_CAP + 1U - split, instruction + split,
                   strlen(instruction) - split);
        queue_read(STDIN_FILENO, INPUT_CAP + 1U - strlen(instruction), NULL, 0);
        queue_open("/sandbox/candidate/README.md", O_RDONLY | O_CLOEXEC, 0, 41, 0);
        queue_read(41, 1, "x", 1);
        queue_close(41, 0, 0);
        expect_output(
            output, oracle_line(output, sizeof output, instruction, "complete", "none", &r, 1), 0);
        run_case("PAR-chunk-eintr");
    }
}

static void output_schedule_case(const char *id, const char *input, int read_failure, int schedule)
{
    static const char input_error[] = "YSPROBE1 error=input\n",
                      read_error[] = "YSPROBE1 error=read\n";
    char output[512];
    size_t length;
    struct oracle_record r = {"read", "ok", "success", 1, 1, 0, 0, {1, 'x', 0}};
    fixture_reset();
    if (read_failure)
        queue_read_error(STDIN_FILENO, INPUT_CAP + 1U, EIO);
    else
        queue_instruction(input);
    if (!read_failure && strcmp(input, "bad\n") != 0) {
        queue_open("/sandbox/candidate/README.md", O_RDONLY | O_CLOEXEC, 0, 41, 0);
        queue_read(41, 1U, "x", 1U);
        queue_close(41, 0, 0);
        length = oracle_line(output, sizeof output, input, "complete", "none", &r, 1);
    } else {
        const char *diagnostic = read_failure ? read_error : input_error;
        length = strlen(diagnostic);
        memcpy(output, diagnostic, length);
    }
    if (schedule == 0)
        expect_output(output, length, read_failure || strcmp(input, "bad\n") == 0 ? 64 : 0);
    else if (schedule == 1) {
        queue_write_exact(STDOUT_FILENO, output, length, 7, 0);
        queue_write_exact(STDOUT_FILENO, output + 7, length - 7, (long)(length - 7), 0);
        fixture_expected_output = (unsigned char *)output;
        fixture_expected_output_length = length;
        fixture_expected_stdout_total = length;
        fixture_expected_return = read_failure || strcmp(input, "bad\n") == 0 ? 64 : 0;
    } else if (schedule == 2) {
        queue_write_exact(STDOUT_FILENO, output, length, -1, EINTR);
        expect_output(output, length, read_failure || strcmp(input, "bad\n") == 0 ? 64 : 0);
    } else if (schedule == 3) {
        queue_write_exact(STDOUT_FILENO, output, length, 0, 0);
        fixture_expected_return = 74;
    } else if (schedule == 4) {
        queue_write_exact(STDOUT_FILENO, output, length, 7, 0);
        queue_write_exact(STDOUT_FILENO, output + 7, length - 7, -1, EIO);
        fixture_expected_output = (unsigned char *)output;
        fixture_expected_output_length = 7;
        fixture_expected_stdout_total = 7;
        fixture_expected_return = 74;
    } else if (schedule == 5) {
        queue_write_exact(STDOUT_FILENO, output, length, -1, EIO);
        fixture_expected_return = 74;
    } else {
        struct fixture_step *x;
        queue_write_exact(STDOUT_FILENO, output, length, 7, 0);
        x = fixture_push(FX_WRITE);
        x->flow = FX_STOP;
        x->call.io.fd = STDOUT_FILENO;
        x->call.io.length = length - 7;
        x->call.io.kind = FX_BYTES_EXACT;
        x->call.io.bytes = (unsigned char *)output + 7;
        fixture_expected_output = (unsigned char *)output;
        fixture_expected_output_length = 7;
        fixture_expected_stdout_total = 7;
        fixture_expected_escape = 2;
    }
    run_case(id);
}

static void result_emission_cases(void)
{
    static const char *const result_ids[] = {
        "OUT-full",          "OUT-short-completes",  "OUT-eintr", "OUT-zero", "OUT-prefix-error",
        "OUT-initial-error", "OUT-stop-during-write"};
    static const int result_schedules[] = {0, 1, 2, 3, 4, 5, 6};
    static const char *const diagnostic_suffix[] = {"full", "short", "eintr", "zero", "error"};
    static const int diagnostic_schedules[] = {0, 1, 2, 3, 4};
    size_t i;
    char id[64];
    for (i = 0; i < 7U; i++)
        output_schedule_case(result_ids[i], "YSPROBE1 candidate-read\n", 0, result_schedules[i]);
    for (i = 0; i < 5U; i++) {
        (void)snprintf(id, sizeof id, "OUT-input-%s", diagnostic_suffix[i]);
        output_schedule_case(id, "bad\n", 0, diagnostic_schedules[i]);
    }
    for (i = 0; i < 5U; i++) {
        (void)snprintf(id, sizeof id, "OUT-read-%s", diagnostic_suffix[i]);
        output_schedule_case(id, "", 1, diagnostic_schedules[i]);
    }
}

static void socket_cases(void)
{
    static const struct {
        const char *name;
        unsigned number;
    } aliases[] = {{"alias-a", 2}, {"alias-b", 2}};
    unsigned family;
    char instruction[64], output[512], name[64];
    fixture_check(aliases[0].number == aliases[1].number,
                  "synthetic aliases share one numeric family");
    for (family = 0; family < 8U; family++) {
        int type = (family == 3U || family == 4U ? SOCK_RAW : SOCK_STREAM) | TEST_CLOEXEC;
        int protocol = family == 3U ? 7 : 0;
        struct oracle_record record = {
            "socket",  "ok",
            "refused", 1,
            1,         EPERM,
            0,         {family, (uint64_t)(unsigned)type, (uint64_t)(unsigned)protocol}};
        fixture_reset();
        set_synthetic_socket_facts(8);
        (void)snprintf(instruction, sizeof instruction, "YSPROBE1 socket-family %u\n", family);
        queue_instruction(instruction);
        {
            struct fixture_step *s = queue_return(FX_SOCKET, -1, EPERM);
            s->call.socket.family = (int)family;
            s->call.socket.type = type;
            s->call.socket.protocol = protocol;
        }
        expect_output(output,
                      oracle_line(output, sizeof output, instruction, "complete",
                                  "linux-build-af-v1/8", &record, 1U),
                      0);
        (void)snprintf(name, sizeof name, "SOCK-A-%u", family);
        run_case(name);
    }

    fixture_reset();
    set_synthetic_socket_facts(8);
    fixture_socket_override_value.netlink_available = 0;
    queue_instruction("YSPROBE1 socket-family 2\n");
    {
        struct oracle_record r = {"socket", "unknown", "unsupported", 0, 0, ENOSYS, 0, {2, 0, 0}};
        expect_output(output,
                      oracle_line(output, sizeof output, "YSPROBE1 socket-family 2\n", "incomplete",
                                  "linux-build-af-v1/8", &r, 1U),
                      0);
    }
    run_case("SOCK-missing-netlink");

    fixture_reset();
    set_synthetic_socket_facts(8);
    fixture_socket_override_value.packet_available = 0;
    queue_instruction("YSPROBE1 socket-family 2\n");
    {
        struct oracle_record r = {"socket", "unknown", "unsupported", 0, 0, ENOSYS, 0, {2, 0, 0}};
        expect_output(output,
                      oracle_line(output, sizeof output, "YSPROBE1 socket-family 2\n", "incomplete",
                                  "linux-build-af-v1/8", &r, 1U),
                      0);
    }
    run_case("SOCK-missing-packet");
}

static void actual_socket_facts_case(void)
{
    struct socket_facts facts = {0}, observed;
    static const char instruction[] = "YSPROBE1 socket-family 0\n";
    char output[512], domain[64];
    struct oracle_record record;
#if defined(__linux__) && !defined(YSTACK_TEST_NO_SOCKET_CONSTANTS)
    facts.linux_build = 1;
#if defined(AF_MAX)
    facts.domain_max = AF_MAX;
#endif
#if defined(SOCK_CLOEXEC)
    facts.cloexec_available = 1;
    facts.cloexec = SOCK_CLOEXEC;
#endif
#if defined(AF_NETLINK) && !defined(YSTACK_TEST_MASK_NETLINK)
    facts.netlink_available = 1;
    facts.netlink = AF_NETLINK;
#endif
#if defined(NETLINK_USERSOCK)
    facts.usersock_available = 1;
    facts.usersock = NETLINK_USERSOCK;
#endif
#if defined(AF_PACKET) && !defined(YSTACK_TEST_MASK_PACKET)
    facts.packet_available = 1;
    facts.packet = AF_PACKET;
#endif
#if defined(AF_VSOCK)
    facts.vsock_available = 1;
    facts.vsock = AF_VSOCK;
#endif
#endif
    observed = build_socket_facts();
    fixture_check(observed.domain_max == facts.domain_max, "socket fact domain_max");
    fixture_check(observed.linux_build == facts.linux_build, "socket fact linux_build");
    fixture_check(observed.cloexec_available == facts.cloexec_available,
                  "socket fact cloexec_available");
    fixture_check(observed.cloexec == facts.cloexec, "socket fact cloexec");
    fixture_check(observed.netlink_available == facts.netlink_available,
                  "socket fact netlink_available");
    fixture_check(observed.netlink == facts.netlink, "socket fact netlink");
    fixture_check(observed.usersock_available == facts.usersock_available,
                  "socket fact usersock_available");
    fixture_check(observed.usersock == facts.usersock, "socket fact usersock");
    fixture_check(observed.packet_available == facts.packet_available,
                  "socket fact packet_available");
    fixture_check(observed.packet == facts.packet, "socket fact packet");
    fixture_check(observed.vsock_available == facts.vsock_available, "socket fact vsock_available");
    fixture_check(observed.vsock == facts.vsock, "socket fact vsock");
    int base_valid = facts.linux_build && facts.cloexec_available && facts.domain_max > 0 &&
                     facts.domain_max <= 65536L;
    fixture_reset();
    queue_instruction(instruction);
    if (!base_valid) {
        record = (struct oracle_record){"socket", "unknown", "incomplete", 0, 0, 0, 0, {0, 0, 0}};
        expect_output(
            output,
            oracle_line(output, sizeof output, instruction, "incomplete", "unknown", &record, 1),
            0);
    } else if (!facts.netlink_available || !facts.packet_available) {
        (void)snprintf(domain, sizeof domain, "linux-build-af-v1/%ld", facts.domain_max);
        record =
            (struct oracle_record){"socket", "unknown", "unsupported", 0, 0, ENOSYS, 0, {0, 0, 0}};
        expect_output(
            output,
            oracle_line(output, sizeof output, instruction, "incomplete", domain, &record, 1), 0);
    } else {
        int type = SOCK_STREAM | facts.cloexec;
        struct fixture_step *s = queue_return(FX_SOCKET, -1, EPERM);
        s->call.socket.family = 0;
        s->call.socket.type = type;
        s->call.socket.protocol = 0;
        (void)snprintf(domain, sizeof domain, "linux-build-af-v1/%ld", facts.domain_max);
        record = (struct oracle_record){
            "socket", "ok", "refused", 1, 1, EPERM, 0, {0, (uint64_t)(unsigned)type, 0}};
        expect_output(
            output, oracle_line(output, sizeof output, instruction, "complete", domain, &record, 1),
            0);
    }
    run_case("socket-actual-header-facts");
    {
#if defined(YSTACK_TEST_NO_SOCKET_CONSTANTS)
        static const char variant[] = "no-socket-constants";
#elif defined(YSTACK_TEST_MASK_NETLINK)
        static const char variant[] = "mask-netlink";
#elif defined(YSTACK_TEST_MASK_PACKET)
        static const char variant[] = "mask-packet";
#else
        static const char variant[] = "default";
#endif
        static const char *const fields[] = {
            "domain_max",        "linux_build", "cloexec_available",  "cloexec",
            "netlink_available", "netlink",     "usersock_available", "usersock",
            "packet_available",  "packet",      "vsock_available",    "vsock"};
        static const char *const entries[] = {"0", "AF_NETLINK", "AF_PACKET", "AF_VSOCK"};
        char id[96];
        size_t k;
        for (k = 0; k < 12; k++) {
            snprintf(id, sizeof id, "FACT-%s-%s", variant, fields[k]);
            obligation_credit(id);
        }
        for (k = 0; k < 4; k++) {
            snprintf(id, sizeof id, "HENTRY-%s-%s", variant, entries[k]);
            obligation_credit(id);
        }
    }
    if (base_valid && facts.netlink_available && facts.packet_available) {
        unsigned families[3] = {(unsigned)facts.netlink, (unsigned)facts.packet,
                                (unsigned)facts.vsock};
        const char *names[3] = {"obligation-socket-actual-netlink-tuple",
                                "obligation-socket-actual-packet-tuple",
                                "obligation-socket-actual-vsock-tuple"};
        size_t i, limit = facts.vsock_available ? 3U : 2U;
        for (i = 0; i < limit; i++) {
            int type = (i < 2U ? SOCK_RAW : SOCK_STREAM) | facts.cloexec;
            int protocol = i == 0U ? facts.usersock : 0;
            struct fixture_step *s;
            if (i == 0U && !facts.usersock_available)
                continue;
            fixture_reset();
            (void)snprintf(domain, sizeof domain, "linux-build-af-v1/%ld", facts.domain_max);
            {
                char tuple_instruction[64];
                (void)snprintf(tuple_instruction, sizeof tuple_instruction,
                               "YSPROBE1 socket-family %u\n", families[i]);
                queue_instruction(tuple_instruction);
                s = queue_return(FX_SOCKET, -1, EPERM);
                s->call.socket.family = (int)families[i];
                s->call.socket.type = type;
                s->call.socket.protocol = protocol;
                record = (struct oracle_record){
                    "socket",
                    "ok",
                    "refused",
                    1,
                    1,
                    EPERM,
                    0,
                    {families[i], (uint64_t)(unsigned)type, (uint64_t)(unsigned)protocol}};
                expect_output(output,
                              oracle_line(output, sizeof output, tuple_instruction, "complete",
                                          domain, &record, 1),
                              0);
                run_case(names[i]);
            }
        }
    }
}

static void socket_outcome_cases(void)
{
    static const struct {
        const char *name, *outcome;
        int error_number;
    } cases[] = {{"SOCK-error-EAFNOSUPPORT", "unsupported", EAFNOSUPPORT},
                 {"SOCK-error-EPROTONOSUPPORT", "unsupported", EPROTONOSUPPORT},
                 {"SOCK-error-ESOCKTNOSUPPORT", "unsupported", ESOCKTNOSUPPORT},
                 {"SOCK-error-EOPNOTSUPP", "unsupported", EOPNOTSUPP},
                 {"SOCK-error-EACCES", "incomplete", EACCES},
                 {"SOCK-error-EROFS", "incomplete", EROFS},
                 {"SOCK-error-EINVAL", "incomplete", EINVAL},
                 {"SOCK-error-ENOSYS", "incomplete", ENOSYS},
                 {"SOCK-error-EMFILE", "incomplete", EMFILE}};
    static const char instruction[] = "YSPROBE1 socket-family 2\n";
    size_t i;
    char output[512];
    for (i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        struct oracle_record r = {"socket",
                                  "ok",
                                  cases[i].outcome,
                                  1,
                                  0,
                                  cases[i].error_number,
                                  0,
                                  {2, (uint64_t)(unsigned)(SOCK_STREAM | TEST_CLOEXEC), 0}};
        struct fixture_step *s;
        fixture_reset();
        set_synthetic_socket_facts(8);
        queue_instruction(instruction);
        s = queue_return(FX_SOCKET, -1, cases[i].error_number);
        s->call.socket.family = 2;
        s->call.socket.type = SOCK_STREAM | TEST_CLOEXEC;
        s->call.socket.protocol = 0;
        expect_output(output,
                      oracle_line(output, sizeof output, instruction, "incomplete",
                                  "linux-build-af-v1/8", &r, 1),
                      0);
        run_case(cases[i].name);
    }
    for (i = 2U; i <= 5U; i++) {
        size_t c;
        for (c = 0; c < 2U; c++) {
            unsigned family = (unsigned)i;
            int type = (family == 3U || family == 4U ? SOCK_RAW : SOCK_STREAM) | TEST_CLOEXEC;
            int protocol = family == 3U ? 7 : 0;
            char tuple_instruction[64], id[64];
            struct oracle_record r = {
                "socket",    "ok",
                "violation", 1,
                1,           0,
                c ? EIO : 0, {family, (uint64_t)(unsigned)type, (uint64_t)(unsigned)protocol}};
            struct fixture_step *x;
            fixture_reset();
            set_synthetic_socket_facts(8);
            snprintf(tuple_instruction, sizeof tuple_instruction, "YSPROBE1 socket-family %u\n",
                     family);
            queue_instruction(tuple_instruction);
            x = queue_return(FX_SOCKET, 42, 0);
            x->call.socket.family = (int)family;
            x->call.socket.type = type;
            x->call.socket.protocol = protocol;
            queue_close(42, c ? -1 : 0, c ? EIO : 0);
            expect_output(output,
                          oracle_line(output, sizeof output, tuple_instruction,
                                      c ? "incomplete" : "complete", "linux-build-af-v1/8", &r, 1),
                          0);
            snprintf(id, sizeof id, "SOCK-success-%u-close-%s", family, c ? "EIO" : "0");
            run_case(id);
        }
    }
}

static void socket_prerequisite_case(const char *name, struct socket_facts facts, unsigned family,
                                     const char *pre, const char *outcome, int error_number)
{
    char instruction[64], output[512], domain[64];
    struct oracle_record r;
    fixture_reset();
    fixture_socket_override_value = facts;
    fixture_socket_override = &fixture_socket_override_value;
    (void)snprintf(instruction, sizeof instruction, "YSPROBE1 socket-family %u\n", family);
    queue_instruction(instruction);
    if (!facts.linux_build || !facts.cloexec_available || facts.domain_max <= 0 ||
        facts.domain_max > 65536L)
        (void)snprintf(domain, sizeof domain, "unknown");
    else
        (void)snprintf(domain, sizeof domain, "linux-build-af-v1/%ld", facts.domain_max);
    r = (struct oracle_record){"socket", pre, outcome, 0, 0, error_number, 0, {family, 0, 0}};
    expect_output(output,
                  oracle_line(output, sizeof output, instruction, "incomplete", domain, &r, 1), 0);
    run_case(name);
}

static void socket_bound_case(const char *id, struct socket_facts f, unsigned family)
{
    char ins[64], out[512], domain[64];
    struct oracle_record r;
    int reachable =
        f.linux_build && f.cloexec_available && f.domain_max > 0 && family < (unsigned)f.domain_max;
    int type =
        (family == (unsigned)f.netlink || family == (unsigned)f.packet ? SOCK_RAW : SOCK_STREAM) |
        f.cloexec;
    int protocol = family == (unsigned)f.netlink ? f.usersock : 0;
    struct fixture_step *x;
    fixture_reset();
    fixture_socket_override_value = f;
    fixture_socket_override = &fixture_socket_override_value;
    snprintf(ins, sizeof ins, "YSPROBE1 socket-family %u\n", family);
    queue_instruction(ins);
    snprintf(domain, sizeof domain, "linux-build-af-v1/%ld", f.domain_max);
    if (reachable) {
        x = queue_return(FX_SOCKET, -1, EPERM);
        x->call.socket.family = (int)family;
        x->call.socket.type = type;
        x->call.socket.protocol = protocol;
        r = (struct oracle_record){
            "socket",  "ok",
            "refused", 1,
            1,         EPERM,
            0,         {family, (uint64_t)(unsigned)type, (uint64_t)(unsigned)protocol}};
    } else
        r = (struct oracle_record){"socket", "unknown", "incomplete", 0, 0, 0, 0, {family, 0, 0}};
    expect_output(
        out,
        oracle_line(out, sizeof out, ins, reachable ? "complete" : "incomplete", domain, &r, 1), 0);
    run_case(id);
}

static void socket_prerequisite_cases(void)
{
    struct socket_facts f;
    unsigned family;
    memset(&f, 0, sizeof f);
    socket_prerequisite_case("SOCK-prereq-nonlinux", f, 0, "unknown", "incomplete", 0);
    set_synthetic_socket_facts(8);
    f = fixture_socket_override_value;
    f.domain_max = 0;
    socket_prerequisite_case("SOCK-prereq-domain-zero", f, 0, "unknown", "incomplete", 0);
    f.domain_max = -1;
    socket_prerequisite_case("SOCK-prereq-domain-negative", f, 0, "unknown", "incomplete", 0);
    f.domain_max = 65537;
    socket_prerequisite_case("SOCK-prereq-domain-too-large", f, 0, "unknown", "incomplete", 0);
    set_synthetic_socket_facts(8);
    f = fixture_socket_override_value;
    f.cloexec_available = 0;
    socket_prerequisite_case("SOCK-prereq-missing-cloexec", f, 0, "unknown", "incomplete", 0);
    set_synthetic_socket_facts(8);
    f = fixture_socket_override_value;
    f.usersock_available = 0;
    socket_prerequisite_case("SOCK-missing-usersock", f, 3, "unknown", "unsupported", ENOSYS);
    set_synthetic_socket_facts(8);
    f = fixture_socket_override_value;
    socket_prerequisite_case("SOCK-prereq-outside-small", f, 8, "unknown", "incomplete", 0);
    socket_prerequisite_case("SOCK-prereq-parser-upper-outside", f, 65535U, "unknown", "incomplete",
                             0);
    f.domain_max = 65536;
    socket_bound_case("SOCK-domain-upper-valid", f, 65535U);
    set_synthetic_socket_facts(8);
    f = fixture_socket_override_value;
    f.vsock_available = 0;
    socket_bound_case("SOCK-vsock-absent", f, 5U);
    set_synthetic_socket_facts(12);
    f = fixture_socket_override_value;
    for (family = 0; family < 12U; family++) {
        char name[64];
        snprintf(name, sizeof name, "SOCK-kernel12-build8-%u", family);
        socket_bound_case(name, f, family);
    }
}

static void descriptor_case(const char *name, int leak3, int leak128, int error_fd,
                            int model_fd2048)
{
    static const char instruction[] = "YSPROBE1 descriptors\n";
    struct oracle_record records[5] = {{"fd0", "ok", "success", 1, 1, 0, 0, {S_IFREG, O_RDONLY, 0}},
                                       {"fd1", "ok", "success", 1, 1, 0, 0, {S_IFREG, O_WRONLY, 1}},
                                       {"fd2", "ok", "success", 1, 1, 0, 0, {S_IFREG, O_WRONLY, 1}},
                                       {"fd-scan", "ok", "success", 1, 1, 0, 0, {3, 1023, 0}},
                                       {"fd-leaks",
                                        "ok",
                                        leak3 || leak128 ? "violation" : "success",
                                        1,
                                        1,
                                        0,
                                        0,
                                        {(uint64_t)(leak3 + leak128),
                                         leak3     ? 3U
                                         : leak128 ? 128U
                                                   : 0U,
                                         0}}};
    char output[1024];
    int fd;
    fixture_reset();
    queue_instruction(instruction);
    fixture_modeled_fd2048_open = model_fd2048;
    if (model_fd2048)
        fixture_postcheck_kind = 2;
    for (fd = 0; fd <= 2; fd++) {
        queue_fstat(fd, S_IFREG | 0600, 0, 0);
        queue_fcntl(fd, F_GETFL, fd == 0 ? O_RDONLY : O_WRONLY | O_APPEND, 0);
    }
    for (fd = FD_SCAN_FIRST; fd <= FD_SCAN_LAST; fd++) {
        int open = (fd == 3 && leak3) || (fd == 128 && leak128);
        if (fd == error_fd) {
            queue_fcntl(fd, F_GETFD, -1, EIO);
            records[3].completed = 0;
            records[3].outcome = "incomplete";
            records[3].error_number = EIO;
            records[3].value[2] = (uint64_t)fd;
            records[4].completed = 0;
            records[4].error_number = EIO;
            if (!leak3 && !leak128)
                records[4].outcome = "incomplete";
            break;
        }
        queue_fcntl(fd, F_GETFD, open ? 0 : -1, open ? 0 : EBADF);
    }
    expect_output(
        output, oracle_line(output, sizeof output, instruction, "incomplete", "none", records, 5U),
        0);
    run_case(name);
}

static void descriptor_cases(void)
{
    descriptor_case("descriptors-zero-leaks", 0, 0, 0, 0);
    descriptor_case("descriptors-fd3", 1, 0, 0, 0);
    descriptor_case("descriptors-fd128-softlimit-model", 0, 1, 0, 0);
    descriptor_case("descriptors-two-leaks", 1, 1, 0, 0);
    descriptor_case("descriptors-error-before-leak", 0, 0, 3, 0);
    descriptor_case("descriptors-error-after-leak", 1, 0, 77, 0);
    descriptor_case("obligation-descriptors-modeled-fd2048-invisible", 0, 0, 0, 1);
}

static void descriptor_metadata_case(const char *name, int target, mode_t mode, int flags,
                                     int fstat_error, int fcntl_error)
{
    static const char instruction[] = "YSPROBE1 descriptors\n";
    struct oracle_record r[5];
    char output[1024];
    int fd, saved = fstat_error != 0 ? fstat_error : fcntl_error;
    fixture_reset();
    queue_instruction(instruction);
    for (fd = 0; fd <= 2; fd++) {
        mode_t current = fd == target ? mode : S_IFREG | 0600;
        int current_flags = fd == target ? flags : (fd == 0 ? O_RDONLY : O_WRONLY | O_APPEND);
        if (fd == target && fstat_error != 0)
            queue_fstat(fd, 0, -1, fstat_error);
        else {
            queue_fstat(fd, current, 0, 0);
            if (fd == target && fcntl_error != 0)
                queue_fcntl(fd, F_GETFL, -1, fcntl_error);
            else
                queue_fcntl(fd, F_GETFL, current_flags, 0);
        }
        r[fd] = (struct oracle_record){
            fd == 0   ? "fd0"
            : fd == 1 ? "fd1"
                      : "fd2",
            "ok",
            saved != 0 && fd == target ? "incomplete"
            : (S_ISREG(current) && ((fd == 0 && (current_flags & O_ACCMODE) == O_RDONLY) ||
                                    (fd != 0 && (current_flags & O_ACCMODE) == O_WRONLY &&
                                     (current_flags & O_APPEND) != 0)))
                ? "success"
                : "violation",
            1,
            saved == 0 || fd != target,
            saved != 0 && fd == target ? saved : 0,
            0,
            {saved != 0 && fd == target ? 0U : (uint64_t)(current & S_IFMT),
             saved != 0 && fd == target ? 0U : (uint64_t)(current_flags & O_ACCMODE),
             saved != 0 && fd == target ? 0U : (uint64_t)((current_flags & O_APPEND) != 0)}};
    }
    for (fd = 3; fd <= 1023; fd++)
        queue_fcntl(fd, F_GETFD, -1, EBADF);
    r[3] = (struct oracle_record){"fd-scan", "ok", "success", 1, 1, 0, 0, {3, 1023, 0}};
    r[4] = (struct oracle_record){"fd-leaks", "ok", "success", 1, 1, 0, 0, {0, 0, 0}};
    expect_output(output,
                  oracle_line(output, sizeof output, instruction, "incomplete", "none", r, 5), 0);
    run_case(name);
}

static void descriptor_metadata_cases(void)
{
    int fd;
    char name[64];
    for (fd = 0; fd <= 2; fd++) {
        (void)snprintf(name, sizeof name, "descriptor-fd%d-nonregular", fd);
        descriptor_metadata_case(name, fd, S_IFDIR | 0700, fd == 0 ? O_RDONLY : O_WRONLY | O_APPEND,
                                 0, 0);
        (void)snprintf(name, sizeof name, "descriptor-fd%d-wrong-access", fd);
        descriptor_metadata_case(name, fd, S_IFREG | 0600, fd == 0 ? O_WRONLY : O_RDONLY, 0, 0);
        (void)snprintf(name, sizeof name, "obligation-descriptor-fd%d-ordwr", fd);
        descriptor_metadata_case(name, fd, S_IFREG | 0600, O_RDWR | (fd == 0 ? 0 : O_APPEND), 0, 0);
        (void)snprintf(name, sizeof name, "descriptor-fd%d-missing", fd);
        descriptor_metadata_case(name, fd, 0, 0, EBADF, 0);
        (void)snprintf(name, sizeof name, "descriptor-fd%d-fstat-error", fd);
        descriptor_metadata_case(name, fd, 0, 0, EIO, 0);
        (void)snprintf(name, sizeof name, "descriptor-fd%d-fcntl-error", fd);
        descriptor_metadata_case(name, fd, S_IFREG | 0600, 0, 0, EIO);
    }
    descriptor_metadata_case("descriptor-fd1-no-append", 1, S_IFREG | 0600, O_WRONLY, 0, 0);
    descriptor_metadata_case("descriptor-fd2-no-append", 2, S_IFREG | 0600, O_WRONLY, 0, 0);
}

static void environment_cases(void)
{
    static char *correct[] = {"LANG=C", "LC_ALL=C", "PATH=/sandbox/tools",
                              "TMPDIR=/sandbox/scratch", NULL};
    static char *missing[] = {"LANG=C", "LC_ALL=C", "PATH=/sandbox/tools", NULL};
    static char *extra[] = {"LANG=C", "LC_ALL=C", "PATH=/sandbox/tools", "TMPDIR=/sandbox/scratch",
                            "X=1",    NULL};
    static char *duplicate[] = {"LANG=C", "LC_ALL=C", "PATH=/sandbox/tools", "PATH=/sandbox/tools",
                                NULL};
    static char *wrong[] = {"LANG=C", "LC_ALL=C", "PATH=/bin", "TMPDIR=/sandbox/scratch", NULL};
    static char *order[] = {"LC_ALL=C", "LANG=C", "PATH=/sandbox/tools", "TMPDIR=/sandbox/scratch",
                            NULL};
    static char *empty[] = {NULL};
    static char **const arrays[] = {correct, missing, extra, duplicate, wrong, order, empty};
    static const char *const names[] = {
        "environment-control", "environment-missing", "environment-extra", "environment-duplicate",
        "environment-wrong",   "environment-order",   "environment-empty"};
    static const char instruction[] = "YSPROBE1 environment\n";
    size_t i;
    char output[512];
    for (i = 0; i < sizeof arrays / sizeof arrays[0]; i++) {
        uint64_t observed = i == 1U ? 3U : i == 2U ? 5U : i == 6U ? 0U : 4U;
        struct oracle_record r = {
            "environment", "ok", i == 0U ? "success" : "violation", 1, 1, 0, 0, {observed, 4, 0}};
        fixture_reset();
        fixture_case_environment = arrays[i];
        queue_instruction(instruction);
        expect_output(
            output, oracle_line(output, sizeof output, instruction, "complete", "none", &r, 1U), 0);
        run_case(names[i]);
    }
}

static void pid_cases(void)
{
    static const struct {
        const char *name;
        pid_t pid, parent;
        int private_relationship;
    } cases[] = {{"pid-private", 1, 0, 1},
                 {"pid-self", 1, 1, 0},
                 {"pid-orphan", 7, 1, 0},
                 {"pid-visible", 12, 34, 0},
                 {"pid-unexpected", 44, 55, 0}};
    static const char instruction[] = "YSPROBE1 signal-supervisor\n";
    size_t i;
    char output[768];
    for (i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        struct oracle_record records[2] = {
            {"relationship",
             "ok",
             cases[i].private_relationship ? "success" : "incomplete",
             1,
             1,
             0,
             0,
             {(uint64_t)cases[i].pid, (uint64_t)cases[i].parent, cases[i].private_relationship}},
            {"supervisor-signal",
             cases[i].private_relationship ? "unknown" : "failed",
             "incomplete",
             0,
             0,
             0,
             0,
             {cases[i].private_relationship ? 1U : 2U, 0, 0}}};
        fixture_reset();
        queue_instruction(instruction);
        queue_return(FX_GETPID, cases[i].pid, 0);
        queue_return(FX_GETPPID, cases[i].parent, 0);
        expect_output(
            output,
            oracle_line(output, sizeof output, instruction, "incomplete", "none", records, 2U), 0);
        run_case(cases[i].name);
    }
}

static void namespace_cases(void)
{
    static const char instruction[] = "YSPROBE1 namespace-escape\n";
#if defined(__linux__)
    static const struct {
        const char *id, *outcome;
        int error, completed;
    } cases[] = {{"0", "violation", 0, 1},
                 {"EPERM", "refused", EPERM, 1},
                 {"EACCES", "refused", EACCES, 1},
                 {"EROFS", "refused", EROFS, 1},
                 {"EOPNOTSUPP", "unsupported", EOPNOTSUPP, 0},
                 {"EIO", "incomplete", EIO, 0},
                 {"ENOSYS", "incomplete", ENOSYS, 0},
                 {"EINVAL", "incomplete", EINVAL, 0}};
#endif
    size_t i;
    char output[512], name[64];
#if defined(__linux__)
    for (i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        struct oracle_record r = {"unshare",      "ok", cases[i].outcome, 1, cases[i].completed,
                                  cases[i].error, 0,    {0, 0, 0}};
        struct fixture_step *s;
        fixture_reset();
        queue_instruction(instruction);
        s = queue_return(FX_UNSHARE, cases[i].error ? -1 : 0, cases[i].error);
        s->call.unshare.flags = CLONE_NEWUSER | CLONE_NEWNS;
        expect_output(output,
                      oracle_line(output, sizeof output, instruction,
                                  cases[i].completed ? "complete" : "incomplete", "none", &r, 1),
                      0);
        (void)snprintf(name, sizeof name, "NS-linux-%s", cases[i].id);
        run_case(name);
    }
#else
    {
        struct oracle_record r = {"unshare", "unknown", "unsupported", 0, 0, ENOSYS, 0, {0, 0, 0}};
        fixture_reset();
        queue_instruction(instruction);
        expect_output(output,
                      oracle_line(output, sizeof output, instruction, "incomplete", "none", &r, 1),
                      0);
        run_case("obligation-namespace-nonlinux-no-attempt");
    }
    (void)i;
    (void)name;
#endif
}

static void sentinel_data_case(const char *mode, const char *id, const char *path, int kind,
                               int close_error)
{
    char digest[65], hex[256], ins[512], out[1024];
    size_t i, expected = kind == 11 ? 6U : kind == 12 ? 1U : 7U;
    const char *bytes = kind == 1    ? "fix"
                        : kind == 2  ? "fixtureX"
                        : kind == 3  ? "xxxxxxx"
                        : kind == 4  ? ""
                        : kind == 12 ? "f"
                                     : "fixture";
    size_t n = strlen(bytes);
    struct oracle_record r[2];
    static const char d[] = "0123456789abcdef";
    digest_hex("fixture", 7, digest);
    for (i = 0; path[i]; i++) {
        unsigned c = (unsigned char)path[i];
        hex[2 * i] = d[c >> 4];
        hex[2 * i + 1] = d[c & 15];
    }
    hex[2 * i] = 0;
    snprintf(ins, sizeof ins, "YSPROBE1 %s %s %zu %s\n", mode, hex, expected, digest);
    r[0] = (struct oracle_record){"open", "ok", "success", 1, 1, 0, 0, {S_IFREG, expected, 0}};
    r[1] = (struct oracle_record){
        "read",
        "ok",
        kind >= 7 && kind <= 10 ? (kind == 8   ? "refused"
                                   : kind == 9 ? "unsupported"
                                               : "incomplete")
                                : (n == expected && n == 7 && kind != 3 ? "success" : "violation"),
        1,
        kind >= 7 && kind <= 10 ? 0 : 1,
        kind >= 7 && kind <= 10 ? (kind == 8   ? EACCES
                                   : kind == 9 ? EOPNOTSUPP
                                               : EIO)
                                : 0,
        close_error,
        {kind == 10                  ? 3U
         : (kind >= 7 && kind <= 10) ? 0U
                                     : n,
         expected, (kind == 0 || kind == 5 || kind == 6 || kind == 11) ? 1U : 0U}};
    fixture_reset();
    queue_instruction(ins);
    queue_open(path, O_RDONLY | O_CLOEXEC, 0, 41, 0);
    queue_fstat(41, S_IFREG | 0600, 0, 0);
    if (kind == 5) {
        queue_read_error(41, expected + 1, EINTR);
        queue_read(41, expected + 1, bytes, n);
        queue_read(41, expected + 1 - n, NULL, 0);
    } else if (kind == 6) {
        queue_read(41, expected + 1, "fi", 2);
        queue_read(41, expected - 1, "xture", 5);
        queue_read(41, 1, NULL, 0);
    } else if (kind == 7 || kind == 8 || kind == 9)
        queue_read_error(41, expected + 1, kind == 7 ? EIO : kind == 8 ? EACCES : EOPNOTSUPP);
    else if (kind == 10) {
        queue_read(41, expected + 1, "fix", 3);
        queue_read_error(41, expected - 2, EIO);
    } else {
        queue_read(41, expected + 1, bytes, n);
        if (n != 0U && n < expected + 1)
            queue_read(41, expected + 1 - n, NULL, 0);
    }
    queue_close(41, close_error ? -1 : 0, close_error);
    expect_output(out,
                  oracle_line(out, sizeof out, ins,
                              close_error || (kind >= 7 && kind <= 10) ? "incomplete" : "complete",
                              "none", r, 2),
                  0);
    run_case(id);
}
static void sentinel_cases(void)
{
    static const char *const roles[] = {"host", "sibling"},
                             *const modes[] = {"host-sentinel", "sibling-sentinel"},
                             *const paths[] = {"/quarantine/host", "/quarantine/sibling"};
    static const char *const shapes[] = {
        "match", "short", "long", "wrong", "empty", "eintr-match", "short-chunks-match"};
    size_t r, k, c;
    char id[128];
    for (r = 0; r < 2; r++) {
        for (k = 0; k < 7; k++)
            for (c = 0; c < 2; c++) {
                snprintf(id, sizeof id, "SEN-%s-%s-close-%s", roles[r], shapes[k], c ? "EIO" : "0");
                sentinel_data_case(modes[r], id, paths[r], (int)k, c ? EIO : 0);
            }
        for (k = 0; k < 3; k++)
            for (c = 0; c < 2; c++) {
                const char *e = k == 0 ? "EIO" : k == 1 ? "EACCES" : "EOPNOTSUPP";
                snprintf(id, sizeof id, "SEN-%s-read-%s-close-%s", roles[r], e, c ? "EBADF" : "0");
                sentinel_data_case(modes[r], id, paths[r], (int)k + 7, c ? EBADF : 0);
            }
        for (c = 0; c < 2; c++) {
            snprintf(id, sizeof id, "SEN-%s-read-prefix-error-close-%s", roles[r],
                     c ? "EBADF" : "0");
            sentinel_data_case(modes[r], id, paths[r], 10, c ? EBADF : 0);
        }
        snprintf(id, sizeof id, "SEN-%s-minimum", roles[r]);
        sentinel_data_case(modes[r], id, "/x", 12, 0);
        snprintf(id, sizeof id, "SEN-%s-size-only-mismatch", roles[r]);
        sentinel_data_case(modes[r], id, paths[r], 11, 0);
    }
}

static void sentinel_maximum_case(void)
{
    static char path[4097], hex[8193], ins[8400], bytes[4096];
    static const char zeros[] = "0000000000000000000000000000000000000000000000000000000000000000";
    size_t role, i;
    char out[1024], id[64];
    path[0] = '/';
    memset(path + 1, 'a', 4095);
    path[4096] = 0;
    memset(bytes, 'x', sizeof bytes);
    for (i = 0; i < 4096; i++) {
        unsigned c = (unsigned char)path[i];
        hex[2 * i] = "0123456789abcdef"[c >> 4];
        hex[2 * i + 1] = "0123456789abcdef"[c & 15];
    }
    hex[8192] = 0;
    for (role = 0; role < 2; role++) {
        struct oracle_record r[2] = {{"open", "ok", "success", 1, 1, 0, 0, {S_IFREG, 4096, 0}},
                                     {"read", "ok", "violation", 1, 1, 0, 0, {4096, 4096, 0}}};
        snprintf(ins, sizeof ins, "YSPROBE1 %s-sentinel %s 4096 %s\n", role ? "sibling" : "host",
                 hex, zeros);
        fixture_reset();
        queue_instruction(ins);
        queue_open(path, O_RDONLY | O_CLOEXEC, 0, 41, 0);
        queue_fstat(41, S_IFREG | 0600, 0, 0);
        queue_read(41, 4097, bytes, 4096);
        queue_read(41, 1, NULL, 0);
        queue_close(41, 0, 0);
        expect_output(out, oracle_line(out, sizeof out, ins, "complete", "none", r, 2), 0);
        snprintf(id, sizeof id, "SEN-%s-maximum", role ? "sibling" : "host");
        run_case(id);
    }
}

static void sentinel_prerequisite_case(const char *mode, const char *name, const char *path,
                                       int open_error, int fstat_error, mode_t file_type,
                                       int close_error)
{
    char digest[65], path_hex[256], instruction[512], output[1024];
    size_t i;
    struct oracle_record r[2];
    static const char digits[] = "0123456789abcdef";
    digest_hex("fixture", 7, digest);
    for (i = 0; path[i] != '\0'; i++) {
        unsigned c = (unsigned char)path[i];
        path_hex[i * 2] = digits[c >> 4];
        path_hex[i * 2 + 1] = digits[c & 15];
    }
    path_hex[i * 2] = '\0';
    (void)snprintf(instruction, sizeof instruction, "YSPROBE1 %s %s 7 %s\n", mode, path_hex,
                   digest);
    fixture_reset();
    queue_instruction(instruction);
    queue_open(path, O_RDONLY | O_CLOEXEC, 0, open_error ? -1 : 41, open_error);
    if (open_error != 0) {
        r[0] = (struct oracle_record){
            "open",
            "ok",
            open_error == ENOENT || open_error == ENOTDIR                        ? "incomplete"
            : open_error == EPERM || open_error == EACCES || open_error == EROFS ? "refused"
            : open_error == EOPNOTSUPP                                           ? "unsupported"
                                                                                 : "incomplete",
            1,
            1,
            open_error,
            0,
            {0, 7, 0}};
        r[1] = (struct oracle_record){"read", "failed", "incomplete", 0, 0, 0, 0, {0, 7, 0}};
    } else if (fstat_error != 0) {
        queue_fstat(41, 0, -1, fstat_error);
        queue_close(41, close_error ? -1 : 0, close_error);
        r[0] = (struct oracle_record){"open", "ok",        "incomplete", 1,
                                      0,      fstat_error, close_error,  {0, 7, 0}};
        r[1] = (struct oracle_record){"read", "failed", "incomplete", 0, 0, 0, 0, {0, 7, 0}};
    } else {
        queue_fstat(41, file_type | 0600, 0, 0);
        queue_close(41, close_error ? -1 : 0, close_error);
        r[0] = (struct oracle_record){"open", "ok", "violation", 1,
                                      1,      0,    close_error, {(uint64_t)file_type, 7, 0}};
        r[1] = (struct oracle_record){"read", "failed", "incomplete", 0, 0, 0, 0, {0, 7, 0}};
    }
    expect_output(output,
                  oracle_line(output, sizeof output, instruction, "incomplete", "none", r, 2), 0);
    run_case(name);
}

static void sentinel_prerequisite_cases(void)
{
    static const char *const roles[] = {"host", "sibling"},
                             *const modes[] = {"host-sentinel", "sibling-sentinel"},
                             *const paths[] = {"/quarantine/host", "/quarantine/sibling"};
    static const struct {
        const char *n;
        int e;
    } errors[] = {{"ENOENT", ENOENT}, {"ENOTDIR", ENOTDIR}, {"EPERM", EPERM},
                  {"EACCES", EACCES}, {"EROFS", EROFS},     {"EOPNOTSUPP", EOPNOTSUPP},
                  {"EIO", EIO}};
    size_t r, i, c;
    char id[128];
    for (r = 0; r < 2; r++) {
        for (i = 0; i < 7; i++) {
            snprintf(id, sizeof id, "SEN-%s-open-%s", roles[r], errors[i].n);
            sentinel_prerequisite_case(modes[r], id, paths[r], errors[i].e, 0, 0, 0);
        }
        for (c = 0; c < 2; c++) {
            snprintf(id, sizeof id, "SEN-%s-stat-error-close-%s", roles[r], c ? "EBADF" : "0");
            sentinel_prerequisite_case(modes[r], id, paths[r], 0, EIO, 0, c ? EBADF : 0);
            snprintf(id, sizeof id, "SEN-%s-wrong-type-close-%s", roles[r], c ? "EBADF" : "0");
            sentinel_prerequisite_case(modes[r], id, paths[r], 0, 0, S_IFDIR, c ? EBADF : 0);
        }
    }
}

static void file_write_case(const char *name, const char *instruction, const char *path,
                            const void *payload, size_t payload_length, int open_error,
                            long write_return, int write_error, int close_error)
{
    char output[768];
    const char *record_name = strstr(name, "cgroup") != NULL                   ? "cgroup-write"
                              : strstr(name, "forged-report-evidence") != NULL ? "forged-evidence"
                                                                               : "create";
    int forbidden = strcmp(record_name, "cgroup-write") == 0 || strcmp(record_name, "create") == 0;
    int completed = open_error != 0
                        ? (open_error == EPERM || open_error == EACCES || open_error == EROFS)
                        : write_return == (long)payload_length;
    const char *outcome =
        open_error != 0
            ? (open_error == EPERM || open_error == EACCES || open_error == EROFS ? "refused"
               : open_error == EOPNOTSUPP                                         ? "unsupported"
                                                                                  : "incomplete")
        : forbidden                                   ? "violation"
        : write_return == (long)payload_length        ? "success"
                                                      : "incomplete";
    struct oracle_record r = {
        record_name, "ok",
        outcome,     1,
        completed,   open_error != 0 ? open_error : write_return < 0 ? write_error : 0,
        close_error, {write_return > 0 ? (uint64_t)write_return : 0, 0, 0}};
    int flags = strcmp(record_name, "cgroup-write") == 0 ? O_WRONLY | O_CLOEXEC
                                                         : O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC;
    mode_t mode = strcmp(record_name, "cgroup-write") == 0 ? 0 : 0600;
    fixture_reset();
    queue_instruction(instruction);
    queue_open(path, flags, mode, open_error == 0 ? 41 : -1, open_error);
    if (open_error == 0) {
        queue_write_exact(41, payload, payload_length, write_return, write_error);
        queue_close(41, close_error == 0 ? 0 : -1, close_error);
    }
    expect_output(output,
                  oracle_line(output, sizeof output, instruction,
                              completed && close_error == 0 ? "complete" : "incomplete", "none", &r,
                              1),
                  0);
    run_case(name);
}

static void file_write_cases(void)
{
    static const char forged[] = "{\"kind\":\"sandbox_guest_report\",\"forged\":true}\n";
    static const struct {
        const char *prefix, *instruction, *path, *payload;
        size_t length;
        int short_case;
    } modes[] = {
        {"candidate-write", "YSPROBE1 candidate-write\n", "/sandbox/candidate/probe-write", "x", 1,
         0},
        {"tools-write", "YSPROBE1 tools-write\n", "/sandbox/tools/probe-write", "x", 1, 0},
        {"cgroup-escape", "YSPROBE1 cgroup-escape\n", "/sys/fs/cgroup/cgroup.procs", "0\n", 2, 1},
        {"forged-report-evidence", "YSPROBE1 forged-report-evidence\n",
         "/sandbox/evidence/forged-report.json", forged, sizeof forged - 1U, 1}};
    static const struct {
        const char *name;
        int error;
    } errors[] = {{"EPERM", EPERM},           {"EACCES", EACCES}, {"EROFS", EROFS},
                  {"EOPNOTSUPP", EOPNOTSUPP}, {"EIO", EIO},       {"ENOENT", ENOENT}};
    static const struct {
        const char *name;
        long returned;
        int error;
    } writes[] = {{"full", -2, 0}, {"zero", 0, 0}, {"EIO", -1, EIO}, {"short", 1, 0}};
    static const struct {
        const char *name;
        int error;
    } reached[] = {
        {"EPERM", EPERM}, {"EACCES", EACCES}, {"EROFS", EROFS}, {"EOPNOTSUPP", EOPNOTSUPP}};
    size_t m, i, c;
    char id[128];
    for (m = 0; m < 4U; m++) {
        for (i = 0; i < 6U; i++) {
            (void)snprintf(id, sizeof id, "FW-%s-open-%s", modes[m].prefix, errors[i].name);
            file_write_case(id, modes[m].instruction, modes[m].path, modes[m].payload,
                            modes[m].length, errors[i].error, 0, 0, 0);
        }
        for (i = 0; i < (modes[m].short_case ? 4U : 3U); i++)
            for (c = 0; c < 2U; c++) {
                long returned =
                    writes[i].returned == -2 ? (long)modes[m].length : writes[i].returned;
                (void)snprintf(id, sizeof id, "FW-%s-%s-close-%s", modes[m].prefix, writes[i].name,
                               c ? "EIO" : "0");
                file_write_case(id, modes[m].instruction, modes[m].path, modes[m].payload,
                                modes[m].length, 0, returned, writes[i].error, c ? EIO : 0);
            }
        for (i = 0; i < 4U; i++)
            for (c = 0; c < 2U; c++) {
                (void)snprintf(id, sizeof id, "FW-%s-reached-%s-close-%s", modes[m].prefix,
                               reached[i].name, c ? "EIO" : "0");
                file_write_case(id, modes[m].instruction, modes[m].path, modes[m].payload,
                                modes[m].length, 0, -1, reached[i].error, c ? EIO : 0);
            }
    }
}

static void queue_establish(const char *path, int fd, const void *bytes, size_t length)
{
    queue_open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600, fd, 0);
    queue_write_exact(fd, bytes, length, (long)length, 0);
    queue_close(fd, 0, 0);
}

static void evidence_setup_case(size_t kind, long write_return, int write_error, int prior_errno,
                                int close_error, const char *id)
{
    static const char *const modes[] = {"evidence-read", "evidence-reopen", "evidence-truncate",
                                        "evidence-link", "evidence-rename"};
    static const char *const records[] = {"read", "reopen", "truncate", "link", "rename"};
    static const char *const paths[] = {
        "/sandbox/evidence/read", "/sandbox/evidence/reopen", "/sandbox/evidence/truncate",
        "/sandbox/evidence/link-source", "/sandbox/evidence/rename-source"};
    char instruction[80], output[768];
    int primary = write_return == 1 ? 0 : write_return < 0 ? write_error : EIO;
    struct oracle_record r = {records[kind], "failed",    "incomplete", 0, 0,
                              primary,       close_error, {0, 0, 0}};
    fixture_reset();
    (void)snprintf(instruction, sizeof instruction, "YSPROBE1 %s\n", modes[kind]);
    queue_instruction(instruction);
    queue_open(paths[kind], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600, 40, 0);
    queue_write_exact(40, "x", 1, write_return, write_error);
    queue_close(40, close_error ? -1 : 0, close_error);
    expect_output(output,
                  oracle_line(output, sizeof output, instruction, "incomplete", "none", &r, 1), 0);
    errno = prior_errno;
    run_case(id);
}

static void evidence_action_case(size_t kind, int reopen_error, long action_return,
                                 int action_error, int close_error, const char *id)
{
    static const char *const modes[] = {"evidence-read", "evidence-reopen", "evidence-truncate",
                                        "evidence-link", "evidence-rename"};
    static const char *const records[] = {"read", "reopen", "truncate", "link", "rename"};
    static const char *const paths[] = {
        "/sandbox/evidence/read", "/sandbox/evidence/reopen", "/sandbox/evidence/truncate",
        "/sandbox/evidence/link-source", "/sandbox/evidence/rename-source"};
    char instruction[80], output[768];
    int primary = reopen_error ? reopen_error : action_return < 0 ? action_error : 0;
    int completed =
        reopen_error != 0
            ? (reopen_error == EPERM || reopen_error == EACCES || reopen_error == EROFS)
            : (action_return >= 0 || primary == EPERM || primary == EACCES || primary == EROFS);
    const char *pre = reopen_error ? "ok" : "ok";
    const char *outcome =
        reopen_error
            ? (reopen_error == EPERM || reopen_error == EACCES || reopen_error == EROFS ? "refused"
               : reopen_error == EOPNOTSUPP ? "unsupported"
                                            : "incomplete")
        : action_return >= 0                                        ? "violation"
        : primary == EPERM || primary == EACCES || primary == EROFS ? "refused"
        : primary == EOPNOTSUPP                                     ? "unsupported"
                                                                    : "incomplete";
    uint64_t value = reopen_error == 0 && action_return >= 0 ? 1U : 0U;
    struct oracle_record r = {records[kind], pre,     outcome,     1,
                              completed,     primary, close_error, {value, 0, 0}};
    fixture_reset();
    (void)snprintf(instruction, sizeof instruction, "YSPROBE1 %s\n", modes[kind]);
    queue_instruction(instruction);
    queue_establish(paths[kind], 40, "x", 1);
    if (kind < 2U) {
        int flags = (kind == 0U ? O_RDONLY : O_WRONLY) | O_CLOEXEC;
        queue_open(paths[kind], flags, 0, reopen_error ? -1 : 41, reopen_error);
        if (!reopen_error) {
            if (kind == 0U) {
                if (action_return > 0)
                    queue_read(41, 1U, "x", 1U);
                else if (action_return == 0)
                    queue_read(41, 1U, NULL, 0U);
                else
                    queue_read_error(41, 1U, action_error);
            }
            queue_close(41, close_error ? -1 : 0, close_error);
        }
    } else if (kind == 2U) {
        struct fixture_step *s = queue_return(FX_TRUNCATE, action_return, action_error);
        s->call.truncate.path = paths[kind];
        s->call.truncate.length = 0;
    } else {
        struct fixture_step *s =
            queue_return(kind == 3U ? FX_LINK : FX_RENAME, action_return, action_error);
        s->call.paths.first = paths[kind];
        s->call.paths.second =
            kind == 3U ? "/sandbox/evidence/link-target" : "/sandbox/evidence/rename-target";
    }
    expect_output(output,
                  oracle_line(output, sizeof output, instruction,
                              completed && !close_error ? "complete" : "incomplete", "none", &r, 1),
                  0);
    run_case(id);
}

static void evidence_matrix(void)
{
    static const char *const labels[] = {"read", "reopen", "truncate", "link", "rename"};
    static const int prior[] = {0, EINTR, EACCES};
    static const char *const prior_name[] = {"0", "EINTR", "EACCES"};
    static const int negative[] = {EIO, EINTR};
    static const char *const negative_name[] = {"EIO", "EINTR"};
    static const int action_errors[] = {EPERM, EACCES, EROFS, EOPNOTSUPP, EIO, ENOENT};
    static const char *const action_names[] = {"EPERM",      "EACCES", "EROFS",
                                               "EOPNOTSUPP", "EIO",    "ENOENT"};
    size_t kind, i, c;
    char id[128];
    {
        static const char instruction[] = "YSPROBE1 evidence-read\n";
        char output[768];
        struct oracle_record r = {"read", "failed", "incomplete", 0, 0, EIO, 0, {0, 0, 0}};
        fixture_reset();
        queue_read_error(STDIN_FILENO, INPUT_CAP + 1U, EINTR);
        queue_read(STDIN_FILENO, INPUT_CAP + 1U, instruction, strlen(instruction));
        queue_read(STDIN_FILENO, INPUT_CAP + 1U - strlen(instruction), NULL, 0);
        queue_open("/sandbox/evidence/read", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600, 40, 0);
        queue_write_exact(40, "x", 1, 0, 0);
        queue_close(40, 0, 0);
        expect_output(output,
                      oracle_line(output, sizeof output, instruction, "incomplete", "none", &r, 1),
                      0);
        run_case("PAR-initial-eintr");
    }
    for (kind = 0; kind < 5U; kind++) {
        for (i = 0; i < 2U; i++) {
            (void)snprintf(id, sizeof id, "ESET-%s-open-%s", labels[kind], i ? "EPERM" : "EIO");
            {
                char instruction[80], output[768];
                int error = i ? EPERM : EIO;
                struct oracle_record r = {labels[kind], "failed", "incomplete", 0, 0,
                                          error,        0,        {0, 0, 0}};
                fixture_reset();
                (void)snprintf(instruction, sizeof instruction, "YSPROBE1 evidence-%s\n",
                               labels[kind]);
                queue_instruction(instruction);
                queue_open(kind == 0U   ? "/sandbox/evidence/read"
                           : kind == 1U ? "/sandbox/evidence/reopen"
                           : kind == 2U ? "/sandbox/evidence/truncate"
                           : kind == 3U ? "/sandbox/evidence/link-source"
                                        : "/sandbox/evidence/rename-source",
                           O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600, -1, error);
                expect_output(
                    output,
                    oracle_line(output, sizeof output, instruction, "incomplete", "none", &r, 1),
                    0);
                run_case(id);
            }
        }
        for (i = 0; i < 2U; i++)
            for (c = 0; c < 2U; c++) {
                (void)snprintf(id, sizeof id, "ESET-%s-negative-%s-close-%s", labels[kind],
                               negative_name[i], c ? "EBADF" : "0");
                evidence_setup_case(kind, -1, negative[i], 0, c ? EBADF : 0, id);
            }
        for (i = 0; i < 3U; i++)
            for (c = 0; c < 2U; c++) {
                (void)snprintf(id, sizeof id, "ESET-%s-zero-prior-%s-close-%s", labels[kind],
                               prior_name[i], c ? "EBADF" : "0");
                evidence_setup_case(kind, 0, 0, prior[i], c ? EBADF : 0, id);
            }
        (void)snprintf(id, sizeof id, "ESET-%s-setup-close-error", labels[kind]);
        evidence_setup_case(kind, 1, 0, 0, EIO, id);

        if (kind == 0U) {
            for (i = 0; i < 6U; i++) {
                (void)snprintf(id, sizeof id, "EACT-read-reopen-%s", action_names[i]);
                evidence_action_case(kind, action_errors[i], 0, 0, 0, id);
            }
            for (i = 0; i < 7U; i++)
                for (c = 0; c < 2U; c++) {
                    const char *shape = i == 0U ? "byte" : i == 1U ? "eof" : action_names[i - 2U];
                    long returned = i == 0U ? 1 : i == 1U ? 0 : -1;
                    int error = i < 2U ? 0 : action_errors[i - 2U];
                    (void)snprintf(id, sizeof id, "EACT-read-reached-%s-close-%s", shape,
                                   c ? "EIO" : "0");
                    evidence_action_case(kind, 0, returned, error, c ? EIO : 0, id);
                }
        } else if (kind == 1U) {
            for (i = 0; i < 6U; i++) {
                (void)snprintf(id, sizeof id, "EACT-reopen-%s", action_names[i]);
                evidence_action_case(kind, action_errors[i], 0, 0, 0, id);
            }
            evidence_action_case(kind, 0, 0, 0, 0, "EACT-reopen-success-close-0");
            evidence_action_case(kind, 0, 0, 0, EIO, "EACT-reopen-success-close-EIO");
        } else {
            evidence_action_case(kind, 0, 0, 0, 0,
                                 kind == 2U   ? "EACT-truncate-0"
                                 : kind == 3U ? "EACT-link-0"
                                              : "EACT-rename-0");
            for (i = 0; i < 6U; i++) {
                (void)snprintf(id, sizeof id, "EACT-%s-%s", labels[kind], action_names[i]);
                evidence_action_case(kind, 0, -1, action_errors[i], 0, id);
            }
        }
    }
}

static void evidence_list_case(const char *id, int open_error, int entry, int read_error,
                               int close_error, int prior_errno, int guarded_eof)
{
    static const char instruction[] = "YSPROBE1 evidence-list\n";
    char output[640];
    struct fixture_step *x;
    const char *outcome =
        open_error || read_error
            ? (open_error == EPERM || open_error == EACCES || open_error == EROFS ||
                       read_error == EPERM || read_error == EACCES || read_error == EROFS
                   ? "refused"
               : open_error == EOPNOTSUPP || read_error == EOPNOTSUPP ? "unsupported"
                                                                      : "incomplete")
            : "violation";
    int primary = open_error ? open_error : read_error,
        completed = !primary || primary == EPERM || primary == EACCES || primary == EROFS;
    struct oracle_record r = {"list", "ok", outcome, 1, completed, primary, close_error, {0, 0, 0}};
    fixture_reset();
    queue_instruction(instruction);
    x = queue_return(FX_OPENDIR, open_error ? -1 : 1, open_error);
    x->call.directory.path = "/sandbox/evidence";
    x->call.directory.object = 0;
    if (guarded_eof) {
        x->errno_guard = 1;
        x->expected_errno_before = prior_errno;
        x->preserve_errno = 1;
    }
    if (!open_error) {
        x = queue_return(FX_READDIR, read_error ? -1 : 0, read_error);
        x->call.object.object = 0;
        x->directory_has_entry = entry;
        if (guarded_eof) {
            x->errno_guard = 1;
            x->expected_errno_before = 0;
            x->preserve_errno = 1;
        }
        x = queue_return(FX_CLOSEDIR, close_error ? -1 : 0, close_error);
        x->call.object.object = 0;
    }
    expect_output(output,
                  oracle_line(output, sizeof output, instruction,
                              completed && !close_error ? "complete" : "incomplete", "none", &r, 1),
                  0);
    errno = prior_errno;
    run_case(id);
}
static void evidence_list_cases(void)
{
    static const struct {
        const char *n;
        int e;
    } errors[] = {{"EPERM", EPERM},           {"EACCES", EACCES}, {"EROFS", EROFS},
                  {"EOPNOTSUPP", EOPNOTSUPP}, {"EIO", EIO},       {"ENOENT", ENOENT}};
    static const struct {
        const char *n;
        int e;
    } reads[] = {{"EPERM", EPERM},
                 {"EACCES", EACCES},
                 {"EROFS", EROFS},
                 {"EOPNOTSUPP", EOPNOTSUPP},
                 {"EIO", EIO}};
    size_t i, c;
    char id[96];
    for (i = 0; i < 6; i++) {
        snprintf(id, sizeof id, "EL-open-%s", errors[i].n);
        evidence_list_case(id, errors[i].e, 0, 0, 0, 0, 0);
    }
    for (c = 0; c < 2; c++) {
        snprintf(id, sizeof id, "EL-read-entry-close-%s", c ? "EBADF" : "0");
        evidence_list_case(id, 0, 1, 0, c ? EBADF : 0, 0, 0);
    }
    for (c = 0; c < 2; c++)
        evidence_list_case(c ? "EL-read-eof-prior-EIO-close-EBADF"
                             : "EL-read-eof-prior-EIO-close-0",
                           0, 0, 0, c ? EBADF : 0, EIO, 1);
    for (i = 0; i < 5; i++)
        for (c = 0; c < 2; c++) {
            snprintf(id, sizeof id, "EL-read-%s-close-%s", reads[i].n, c ? "EBADF" : "0");
            evidence_list_case(id, 0, 0, reads[i].e, c ? EBADF : 0, 0, 0);
        }
}

static void scratch_scenario_case(size_t target, int setup_stage, int setup_primary,
                                  int setup_close, int action_error, int action_cleanup,
                                  const char *case_name)
{
    static const char instruction[] = "YSPROBE1 scratch-free\n";
    static const unsigned char zero[4096] = {0};
    static const char *const paths[] = {"/sandbox/scratch/probe-0", "/sandbox/scratch/probe-1",
                                        "/sandbox/scratch/probe-2", "/sandbox/scratch/probe-3",
                                        "/sandbox/scratch/probe-4"};
    static const char *const names[] = {"ftruncate", "fallocate", "madv-remove", "path-truncate",
                                        "unlink",    "rmdir",     "tmpfile"};
    struct oracle_record r[7];
    char output[2048];
    size_t i;
    int complete = 1;
    fixture_reset();
    queue_instruction(instruction);
    for (i = 0; i < 7U; i++) {
        int selected = i == target, error = selected ? action_error : EPERM;
        int cleanup = selected ? action_cleanup : 0,
            recorded_cleanup = cleanup == EBUSY ? EIO : cleanup;
        r[i] = (struct oracle_record){
            names[i],
            "ok",
            error == 0                                            ? "violation"
            : error == EPERM || error == EACCES || error == EROFS ? "refused"
            : error == EOPNOTSUPP || error == ENOSYS              ? "unsupported"
                                                                  : "incomplete",
            1,
            error == 0 || error == EPERM || error == EACCES || error == EROFS,
            error,
            recorded_cleanup,
            {0, 0, 0}};
#if !defined(__linux__)
        if (i == 1U || i == 6U) {
            r[i] = (struct oracle_record){names[i], "unknown", "unsupported", 0, 0,
                                          ENOSYS,   0,         {0, 0, 0}};
            continue;
        }
#endif
#if !defined(MADV_REMOVE)
        if (i == 2U) {
            r[i] = (struct oracle_record){names[i], "unknown", "unsupported", 0, 0,
                                          ENOSYS,   0,         {0, 0, 0}};
            continue;
        }
#endif
        if (i == 5U) {
            struct fixture_step *s = queue_return(FX_MKDIR, selected && setup_stage == 9 ? -1 : 0,
                                                  selected && setup_stage == 9 ? setup_primary : 0);
            s->call.mkdir.path = "/sandbox/scratch/probe-5";
            s->call.mkdir.mode = 0700;
            if (selected && setup_stage == 9) {
                r[i] = (struct oracle_record){names[i],      "failed", "incomplete", 0, 0,
                                              setup_primary, 0,        {0, 0, 0}};
                continue;
            }
            s = queue_return(FX_RMDIR, error ? -1 : 0, error);
            s->call.path.path = "/sandbox/scratch/probe-5";
            r[i].cleanup_error = 0;
            continue;
        }
        if (i == 6U) {
#if defined(__linux__) && defined(O_TMPFILE)
            queue_open("/sandbox/scratch", O_RDWR | O_TMPFILE | O_CLOEXEC, 0600, error ? -1 : 36,
                       error);
            if (!error)
                queue_close(36, cleanup ? -1 : 0, cleanup);
#endif
            continue;
        }
        if (selected && setup_stage == 1) {
            queue_open(paths[i], O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600, -1, setup_primary);
            r[i] = (struct oracle_record){names[i],      "failed", "incomplete", 0, 0,
                                          setup_primary, 0,        {0, 0, 0}};
            continue;
        }
        queue_open(paths[i], O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600, 20 + (int)i, 0);
        if (selected && setup_stage == 2)
            queue_write_exact(20 + (int)i, zero, sizeof zero, 0, 0);
        else if (selected && setup_stage == 3)
            queue_write_exact(20 + (int)i, zero, sizeof zero, -1, setup_primary);
        else if (selected && setup_stage == 5) {
            queue_write_exact(20 + (int)i, zero, sizeof zero, 17, 0);
            queue_write_exact(20 + (int)i, zero + 17, sizeof zero - 17U, (long)(sizeof zero - 17U),
                              0);
        } else if (selected && setup_stage == 6) {
            queue_write_exact(20 + (int)i, zero, sizeof zero, -1, EINTR);
            queue_write_exact(20 + (int)i, zero, sizeof zero, (long)sizeof zero, 0);
        } else
            queue_write_exact(20 + (int)i, zero, sizeof zero, (long)sizeof zero, 0);
        queue_close(20 + (int)i, selected && setup_close ? -1 : 0, selected ? setup_close : 0);
        if (selected && (setup_stage == 2 || setup_stage == 3 || setup_close)) {
            r[i] = (struct oracle_record){
                names[i],    "failed", "incomplete",
                0,           0,        setup_stage == 2 || setup_stage == 3 ? EIO : 0,
                setup_close, {0, 0, 0}};
            continue;
        }
        if (selected && setup_stage == 7) {
            queue_open(paths[i], O_RDWR | O_CLOEXEC, 0, -1, setup_primary);
            r[i] = (struct oracle_record){names[i],      "failed", "incomplete", 0, 0,
                                          setup_primary, 0,        {0, 0, 0}};
            continue;
        }
        if (i == 0U) {
            struct fixture_step *s;
            queue_open(paths[i], O_RDWR | O_CLOEXEC, 0, 30, 0);
            s = queue_return(FX_FTRUNCATE, error ? -1 : 0, error);
            s->call.ftruncate.fd = 30;
            s->call.ftruncate.length = 0;
            queue_close(30, cleanup ? -1 : 0, cleanup);
        } else if (i == 1U) {
#if defined(__linux__)
            struct fixture_step *s;
            queue_open(paths[i], O_RDWR | O_CLOEXEC, 0, 31, 0);
            s = queue_return(FX_FALLOCATE, error ? -1 : 0, error);
            s->call.fallocate.fd = 31;
            s->call.fallocate.mode = FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE;
            s->call.fallocate.offset = 0;
            s->call.fallocate.length = 1;
            queue_close(31, cleanup ? -1 : 0, cleanup);
#endif
        } else if (i == 2U) {
#if defined(MADV_REMOVE)
            struct fixture_step *s;
            queue_open(paths[i], O_RDWR | O_CLOEXEC, 0, 32, 0);
            if (selected && setup_stage == 8) {
                s = queue_return(FX_MMAP, -1, ENOMEM);
                s->call.mmap.address = NULL;
                s->call.mmap.length = 4096;
                s->call.mmap.protection = PROT_READ | PROT_WRITE;
                s->call.mmap.flags = MAP_SHARED;
                s->call.mmap.fd = 32;
                s->call.mmap.offset = 0;
                queue_close(32, setup_close ? -1 : 0, setup_close);
                r[i] = (struct oracle_record){names[i], "failed", "incomplete", 0,
                                              0,        ENOMEM,   setup_close,  {0, 0, 0}};
                continue;
            }
            s = queue_return(FX_MMAP, 1, 0);
            s->call.mmap.address = NULL;
            s->call.mmap.length = 4096;
            s->call.mmap.protection = PROT_READ | PROT_WRITE;
            s->call.mmap.flags = MAP_SHARED;
            s->call.mmap.fd = 32;
            s->call.mmap.offset = 0;
            s->call.mmap.object = 0;
            s = queue_return(FX_MADVISE, error ? -1 : 0, error);
            s->call.madvise.object = 0;
            s->call.madvise.length = 4096;
            s->call.madvise.advice = MADV_REMOVE;
            s = queue_return(FX_MUNMAP, cleanup == EIO || cleanup == EBUSY ? -1 : 0,
                             cleanup == EIO || cleanup == EBUSY ? EIO : 0);
            s->call.munmap.object = 0;
            s->call.munmap.length = 4096;
            queue_close(32, cleanup == EBADF || cleanup == EBUSY ? -1 : 0,
                        cleanup == EBADF || cleanup == EBUSY ? EBADF : 0);
#endif
        } else if (i == 3U) {
            struct fixture_step *s = queue_return(FX_TRUNCATE, error ? -1 : 0, error);
            s->call.truncate.path = paths[i];
            s->call.truncate.length = 0;
            r[i].cleanup_error = 0;
        } else {
            struct fixture_step *s = queue_return(FX_UNLINK, error ? -1 : 0, error);
            s->call.path.path = paths[i];
            r[i].cleanup_error = 0;
        }
    }
    for (i = 0; i < 7U; i++)
        if (!r[i].completed || r[i].cleanup_error)
            complete = 0;
    expect_output(output,
                  oracle_line(output, sizeof output, instruction,
                              complete ? "complete" : "incomplete", "none", r, 7),
                  0);
    run_case(case_name);
}

static void scratch_setup_failure_cases(void)
{
    static const char *const names[] = {"ftruncate", "fallocate", "madv-remove", "path-truncate",
                                        "unlink"};
    static const char *const kinds[] = {"zero", "error", "full", "short", "eintr"};
    size_t i, k;
    char name[96];
    for (i = 0; i < 5U; i++) {
#if !defined(__linux__)
        if (i == 1U)
            continue;
#endif
#if !defined(MADV_REMOVE)
        if (i == 2U)
            continue;
#endif
        (void)snprintf(name, sizeof name, "SS-%s-open-EIO", names[i]);
        scratch_scenario_case(i, 1, EIO, 0, EPERM, 0, name);
        (void)snprintf(name, sizeof name, "SS-%s-open-EPERM", names[i]);
        scratch_scenario_case(i, 1, EPERM, 0, EPERM, 0, name);
        for (k = 0; k < 5U; k++) {
            int stage = (int)k + 2;
            (void)snprintf(name, sizeof name, "SS-%s-%s-close-0", names[i], kinds[k]);
            scratch_scenario_case(i, stage, EIO, 0, EPERM, 0, name);
            (void)snprintf(name, sizeof name, "SS-%s-%s-close-%s", names[i], kinds[k],
                           k < 2U ? "EBADF" : "EIO");
            scratch_scenario_case(i, stage, EIO, k < 2U ? EBADF : EIO, EPERM, 0, name);
        }
        if (i < 3U) {
            (void)snprintf(name, sizeof name, "SS-%s-reopen-EIO", names[i]);
            scratch_scenario_case(i, 7, EIO, 0, EPERM, 0, name);
            (void)snprintf(name, sizeof name, "SS-%s-reopen-EPERM", names[i]);
            scratch_scenario_case(i, 7, EPERM, 0, EPERM, 0, name);
        }
    }
#if defined(MADV_REMOVE)
    scratch_scenario_case(2U, 8, ENOMEM, 0, EPERM, 0, "SS-madv-remove-mmap-close-0");
    scratch_scenario_case(2U, 8, ENOMEM, EBADF, EPERM, 0, "SS-madv-remove-mmap-close-EBADF");
#endif
    scratch_scenario_case(5U, 9, EIO, 0, EPERM, 0, "SS-rmdir-mkdir-EIO");
    scratch_scenario_case(5U, 9, EPERM, 0, EPERM, 0, "SS-rmdir-mkdir-EPERM");
}

static void scratch_action_case(size_t target, int action_error, int cleanup_error,
                                const char *case_name)
{
    scratch_scenario_case(target, 0, 0, 0, action_error, cleanup_error, case_name);
}

static void scratch_action_cases(void)
{
    static const char *const names[] = {"ftruncate", "fallocate", "madv-remove", "path-truncate",
                                        "unlink",    "rmdir",     "tmpfile"};
    static const struct {
        const char *id;
        int error;
    } variants[] = {{"0", 0},         {"EPERM", EPERM},           {"EACCES", EACCES},
                    {"EROFS", EROFS}, {"EOPNOTSUPP", EOPNOTSUPP}, {"ENOSYS", ENOSYS},
                    {"EIO", EIO}};
    size_t i, v, c;
#if defined(__linux__)
    int failures_before = fixture_failures;
#endif
    char name[96];
    for (i = 0; i < 7U; i++)
        for (v = 0; v < sizeof variants / sizeof variants[0]; v++) {
#if !defined(__linux__)
            if (i == 1U || i == 6U)
                continue;
#endif
#if !defined(MADV_REMOVE)
            if (i == 2U)
                continue;
#endif
            if (i < 2U) {
                for (c = 0; c < 2U; c++) {
                    (void)snprintf(name, sizeof name, "SA-%s-%s-%s", names[i], variants[v].id,
                                   c ? "EIO" : "0");
                    scratch_action_case(i, variants[v].error, c ? EIO : 0, name);
                }
            } else if (i == 2U) {
                static const char *const cleanup[] = {"0", "unmap-EIO", "close-EBADF",
                                                      "both-EIO-then-EBADF"};
                static const int errors[] = {0, EIO, EBADF, EBUSY};
                for (c = 0; c < 4U; c++) {
                    (void)snprintf(name, sizeof name, "SA-%s-%s-%s", names[i], variants[v].id,
                                   cleanup[c]);
                    scratch_action_case(i, variants[v].error, errors[c], name);
                }
            } else {
                (void)snprintf(name, sizeof name, "SA-%s-%s-0", names[i], variants[v].id);
                scratch_action_case(i, variants[v].error, 0, name);
                if (i == 6U && v == 0U)
                    scratch_action_case(i, 0, EIO, "SA-tmpfile-0-EIO");
            }
        }
#if !defined(MADV_REMOVE)
    /* Unavailable MADV_REMOVE: execute only the explicit unsupported record, credited
     * under its own platform id; the per-variant madv-remove cases are inapplicable. */
    scratch_action_case(2U, 0, 0, "SF-platform-madv-remove");
#endif
#if defined(__linux__)
    /* Linux-only platform cases executed above (fallocate i==1, tmpfile i==6) with exact
     * fixture arguments; credit only when every executed case passed. */
    if (fixture_failures == failures_before) {
        obligation_credit("SF-platform-fallocate");
        obligation_credit("SF-platform-tmpfile");
    }
#endif
}

static void raw_output_cases(void)
{
    static const char overflow[] = "YSPROBE1 output-overflow\n",
                      request[] = "YSPROBE1 forged-report-stdout\n";
    static const unsigned char forged[] = "{\"kind\":\"sandbox_guest_report\",\"forged\":true}\n";
    size_t i;
    struct fixture_step *x;
    for (i = 0; i < 8U; i++) {
        fixture_reset();
        queue_instruction(overflow);
        x = queue_return(FX_MALLOC, i == 3 ? -1 : 1, i == 3 ? ENOMEM : 0);
        x->call.allocation.size = BLOCK_SIZE;
        if (i != 3)
            x->call.allocation.object = 0;
        if (i == 0)
            for (size_t b = 0; b < 12; b++)
                queue_write_repeat(1, 'x', BLOCK_SIZE, BLOCK_SIZE, 0);
        else if (i == 1) {
            queue_write_repeat(1, 'x', BLOCK_SIZE, 17, 0);
            for (size_t b = 0; b < 11; b++)
                queue_write_repeat(1, 'x', BLOCK_SIZE, BLOCK_SIZE, 0);
            queue_write_repeat(1, 'x', BLOCK_SIZE - 17, BLOCK_SIZE - 17, 0);
        } else if (i == 2) {
            queue_write_repeat(1, 'x', BLOCK_SIZE, -1, EINTR);
            for (size_t b = 0; b < 12; b++)
                queue_write_repeat(1, 'x', BLOCK_SIZE, BLOCK_SIZE, 0);
        } else if (i == 4)
            queue_write_repeat(1, 'x', BLOCK_SIZE, 0, 0);
        else if (i == 5)
            queue_write_repeat(1, 'x', BLOCK_SIZE, -1, EIO);
        else if (i == 6) {
            queue_write_repeat(1, 'x', BLOCK_SIZE, 17, 0);
            queue_write_repeat(1, 'x', BLOCK_SIZE, -1, EIO);
            fixture_expected_stdout_total = 17;
        } else if (i == 7) {
            queue_write_repeat(1, 'x', BLOCK_SIZE, 17, 0);
            x = fixture_push(FX_WRITE);
            x->flow = FX_STOP;
            x->call.io.fd = 1;
            x->call.io.length = BLOCK_SIZE;
            x->call.io.kind = FX_BYTES_REPEAT;
            x->call.io.byte = 'x';
            fixture_expected_stdout_total = 17;
            fixture_expected_escape = 2;
        }
        if (i != 3 && i != 7) {
            x = queue_return(FX_FREE, 0, 0);
            x->call.object.object = 0;
        }
        fixture_expected_stdout_total = i < 3 ? OUTPUT_ATTEMPT : i == 6 || i == 7 ? 17 : 0;
        fixture_expected_return = i < 3 ? 0 : i == 7 ? 0 : 73;
        run_case((const char *[]){"RAW-overflow-full", "RAW-overflow-short", "RAW-overflow-eintr",
                                  "RAW-overflow-allocation", "RAW-overflow-zero",
                                  "RAW-overflow-initial-error", "RAW-overflow-prefix-error",
                                  "RAW-overflow-prefix-stop"}[i]);
    }
    for (i = 0; i < 7U; i++) {
        size_t n = sizeof forged - 1;
        fixture_reset();
        queue_instruction(request);
        if (i == 0)
            expect_output(forged, n, 0);
        else if (i == 1) {
            queue_write_exact(1, forged, n, 7, 0);
            queue_write_exact(1, forged + 7, n - 7, n - 7, 0);
            fixture_expected_output = forged;
            fixture_expected_output_length = n;
            fixture_expected_stdout_total = n;
        } else if (i == 2) {
            queue_write_exact(1, forged, n, -1, EINTR);
            expect_output(forged, n, 0);
        } else if (i == 3) {
            queue_write_exact(1, forged, n, 0, 0);
            fixture_expected_return = 73;
        } else if (i == 4) {
            queue_write_exact(1, forged, n, -1, EIO);
            fixture_expected_return = 73;
        } else if (i == 5) {
            queue_write_exact(1, forged, n, 7, 0);
            queue_write_exact(1, forged + 7, n - 7, -1, EIO);
            fixture_expected_output = forged;
            fixture_expected_output_length = 7;
            fixture_expected_stdout_total = 7;
            fixture_expected_return = 73;
        } else {
            x = queue_return(FX_WRITE, 7, 0);
            x->call.io.fd = 1;
            x->call.io.length = n;
            x->call.io.kind = FX_BYTES_EXACT;
            x->call.io.bytes = forged;
            x = fixture_push(FX_WRITE);
            x->flow = FX_STOP;
            x->call.io.fd = 1;
            x->call.io.length = n - 7;
            x->call.io.kind = FX_BYTES_EXACT;
            x->call.io.bytes = forged + 7;
            fixture_expected_output = forged;
            fixture_expected_output_length = 7;
            fixture_expected_stdout_total = 7;
            fixture_expected_escape = 2;
        }
        run_case((const char *[]){"RAW-forged-full", "RAW-forged-short", "RAW-forged-eintr",
                                  "RAW-forged-zero", "RAW-forged-initial-error",
                                  "RAW-forged-prefix-error", "RAW-forged-prefix-stop"}[i]);
    }
}

static void scratch_fill_case(const char *id, int kind, int close_error)
{
    static const char ins[] = "YSPROBE1 scratch-fill\n";
    char out[640];
    struct oracle_record r;
    struct fixture_step *x;
    size_t b, actual = 0;
    int primary = 0, attempted = 0, completed = 0;
    fixture_reset();
    queue_instruction(ins);
    queue_open("/sandbox/scratch/fill", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600,
               kind < 0 ? -1 : 41, kind < 0 ? -kind : 0);
    if (kind >= 0) {
        x = queue_return(FX_MALLOC, (kind == 0 || kind == 1) ? -1 : 1, kind == 0 ? ENOMEM : 0);
        x->call.allocation.size = BLOCK_SIZE;
        if (kind > 1)
            x->call.allocation.object = 0;
        if (kind == 0 || kind == 1)
            primary = ENOMEM;
        else {
            attempted = 1;
            if (kind == 2) {
                for (b = 0; b < 32; b++)
                    queue_write_repeat(41, 'x', BLOCK_SIZE, BLOCK_SIZE, 0);
                actual = 32U * BLOCK_SIZE;
                completed = 1;
            } else if (kind == 3) {
                queue_write_repeat(41, 'x', BLOCK_SIZE, 17, 0);
                queue_write_repeat(41, 'x', BLOCK_SIZE, BLOCK_SIZE - 17, 0);
                for (b = 1; b < 32; b++)
                    queue_write_repeat(41, 'x', BLOCK_SIZE, BLOCK_SIZE, 0);
                actual = 32U * BLOCK_SIZE;
                completed = 1;
            } else if (kind == 4) {
                queue_write_repeat(41, 'x', BLOCK_SIZE, -1, EINTR);
                for (b = 0; b < 32; b++)
                    queue_write_repeat(41, 'x', BLOCK_SIZE, BLOCK_SIZE, 0);
                actual = 32U * BLOCK_SIZE;
                completed = 1;
            } else if (kind == 5)
                queue_write_repeat(41, 'x', BLOCK_SIZE, 0, 0), primary = EIO;
            else if (kind == 6)
                queue_write_repeat(41, 'x', BLOCK_SIZE, -1, EIO), primary = EIO;
            else if (kind == 7) {
                queue_write_repeat(41, 'x', BLOCK_SIZE, 17, 0);
                queue_write_repeat(41, 'x', BLOCK_SIZE, -1, EIO);
                actual = 17;
                primary = EIO;
            } else if (kind == 8) {
                queue_write_repeat(41, 'x', BLOCK_SIZE, BLOCK_SIZE, 0);
                queue_write_repeat(41, 'x', BLOCK_SIZE, -1, ENOSPC);
                actual = BLOCK_SIZE;
                primary = ENOSPC;
            } else {
                queue_write_repeat(41, 'x', BLOCK_SIZE, 17, 0);
                x = fixture_push(FX_WRITE);
                x->flow = FX_STOP;
                x->call.io.fd = 41;
                x->call.io.length = BLOCK_SIZE;
                x->call.io.kind = FX_BYTES_REPEAT;
                x->call.io.byte = 'x';
                fixture_expected_escape = 2;
                run_case(id);
                return;
            }
            x = queue_return(FX_FREE, 0, 0);
            x->call.object.object = 0;
        }
        queue_close(41, close_error ? -1 : 0, close_error);
    }
    r = (struct oracle_record){"fill",
                               kind < 2 ? "failed" : "ok",
                               completed ? "success" : "incomplete",
                               attempted,
                               completed,
                               kind < 0 ? -kind : primary,
                               close_error,
                               {actual, 32U * BLOCK_SIZE, 0}};
    expect_output(out,
                  oracle_line(out, sizeof out, ins,
                              completed && !close_error ? "complete" : "incomplete", "none", &r, 1),
                  0);
    run_case(id);
}
static void scratch_fill_cases(void)
{
    static const char *const shapes[] = {"full",          "short",        "eintr",         "zero",
                                         "initial-error", "prefix-error", "capacity-error"};
    size_t i, c;
    char id[96];
    scratch_fill_case("FILL-open-EPERM", -EPERM, 0);
    scratch_fill_case("FILL-open-EIO", -EIO, 0);
    for (i = 0; i < 2; i++)
        for (c = 0; c < 2; c++) {
            snprintf(id, sizeof id, "FILL-malloc-%s-close-%s", i ? "0" : "ENOMEM", c ? "EIO" : "0");
            scratch_fill_case(id, (int)i, c ? EIO : 0);
        }
    for (i = 0; i < 7; i++)
        for (c = 0; c < 2; c++) {
            snprintf(id, sizeof id, "FILL-%s-close-%s", shapes[i], c ? "EBADF" : "0");
            scratch_fill_case(id, (int)i + 2, c ? EBADF : 0);
        }
    scratch_fill_case("FILL-before-result-stop", 9, 0);
}

static void resource_cases(void)
{
    char output[768];
    static const char fork_instruction[] = "YSPROBE1 fork-bomb\n";
    static const char thread_instruction[] = "YSPROBE1 thread-bomb\n";
    static const char memory_instruction[] = "YSPROBE1 memory-exhaustion\n";
    static const char sleep_instruction[] = "YSPROBE1 sleep\n";
    struct oracle_record record;

    fixture_reset();
    queue_instruction(fork_instruction);
    queue_return(FX_FORK, 101, 0);
    queue_return(FX_FORK, 102, 0);
    queue_return(FX_FORK, -1, EAGAIN);
    record = (struct oracle_record){"fork", "ok", "incomplete", 1, 0, EAGAIN, 0, {2, 0, 0}};
    expect_output(
        output,
        oracle_line(output, sizeof output, fork_instruction, "incomplete", "none", &record, 1), 0);
    run_case("fork-partial-return");

    fixture_reset();
    queue_instruction(thread_instruction);
    {
        pthread_t one = (pthread_t)11, two = (pthread_t)22;
        struct fixture_step *s;
        s = queue_return(FX_PTHREAD_CREATE, 0, 0);
        s->call.thread.entry = paused_thread;
        s->call.thread.argument = NULL;
        s->call.thread.token = one;
        s = queue_return(FX_PTHREAD_DETACH, 0, 0);
        s->call.detach.token = one;
        s = queue_return(FX_PTHREAD_CREATE, 0, 0);
        s->call.thread.entry = paused_thread;
        s->call.thread.argument = NULL;
        s->call.thread.token = two;
        s = queue_return(FX_PTHREAD_DETACH, 0, 0);
        s->call.detach.token = two;
        s = queue_return(FX_PTHREAD_CREATE, EAGAIN, 0);
        s->call.thread.entry = paused_thread;
        s->call.thread.argument = NULL;
    }
    record = (struct oracle_record){"thread", "ok", "incomplete", 1, 0, EAGAIN, 0, {2, 0, 0}};
    expect_output(
        output,
        oracle_line(output, sizeof output, thread_instruction, "incomplete", "none", &record, 1),
        0);
    run_case("thread-partial-initialized-tokens");

    fixture_reset();
    queue_instruction(memory_instruction);
    {
        struct fixture_step *s = queue_return(FX_MALLOC, 1, 0);
        s->call.allocation.size = BLOCK_SIZE;
        s->call.allocation.object = 0;
        s = queue_return(FX_MALLOC, 1, 0);
        s->call.allocation.size = BLOCK_SIZE;
        s->call.allocation.object = 1;
        s = queue_return(FX_MALLOC, -1, ENOMEM);
        s->call.allocation.size = BLOCK_SIZE;
    }
    record = (struct oracle_record){"memory", "ok", "incomplete",           1, 0,
                                    ENOMEM,   0,    {2U * BLOCK_SIZE, 0, 0}};
    expect_output(
        output,
        oracle_line(output, sizeof output, memory_instruction, "incomplete", "none", &record, 1),
        0);
    run_case("memory-distinct-blocks-partial");

    fixture_reset();
    queue_instruction(sleep_instruction);
    {
        struct fixture_step *s = queue_return(FX_SLEEP, 20, 0);
        s->call.sleep.seconds = 60;
        s = queue_return(FX_SLEEP, 0, 0);
        s->call.sleep.seconds = 20;
    }
    record = (struct oracle_record){"sleep", "ok", "success", 1, 1, 0, 0, {60, 0, 0}};
    expect_output(
        output,
        oracle_line(output, sizeof output, sleep_instruction, "incomplete", "none", &record, 1), 0);
    run_case("sleep-remainder-loop");

    fixture_reset();
    queue_instruction(thread_instruction);
    {
        struct fixture_step *s = queue_return(FX_PTHREAD_CREATE, 0, 0);
        s->call.thread.entry = paused_thread;
        s->call.thread.argument = NULL;
        s->call.thread.token = (pthread_t)33;
        s->call.thread.dispatch = 1;
        s = queue_return(FX_PAUSE, -1, EINTR);
        s = fixture_push(FX_LOOP);
        s->call.loop.site = 1U;
        s = fixture_push(FX_PAUSE);
        s->flow = FX_STOP;
    }
    fixture_expected_escape = 2;
    run_case("thread-dispatch-real-paused-worker-stop");

    fixture_reset();
    queue_instruction(fork_instruction);
    queue_return(FX_FORK, -1, EAGAIN);
    record = (struct oracle_record){"fork", "ok", "incomplete", 1, 0, EAGAIN, 0, {0, 0, 0}};
    expect_output(
        output,
        oracle_line(output, sizeof output, fork_instruction, "incomplete", "none", &record, 1), 0);
    run_case("fork-failure-before-worker");

    fixture_reset();
    queue_instruction(fork_instruction);
    queue_return(FX_FORK, 0, 0);
    {
        struct fixture_step *s = fixture_push(FX_PAUSE);
        s->flow = FX_STOP;
    }
    fixture_expected_escape = 2;
    run_case("fork-child-real-pause-stop");

    fixture_reset();
    queue_instruction(fork_instruction);
    queue_return(FX_FORK, 101, 0);
    {
        struct fixture_step *s = fixture_push(FX_FORK);
        s->flow = FX_STOP;
    }
    fixture_expected_escape = 2;
    run_case("fork-parent-stop");

    fixture_reset();
    queue_instruction(thread_instruction);
    {
        struct fixture_step *s = queue_return(FX_PTHREAD_CREATE, 0, 0);
        s->call.thread.entry = paused_thread;
        s->call.thread.argument = NULL;
        s->call.thread.token = (pthread_t)44;
        s = queue_return(FX_PTHREAD_DETACH, 0, 0);
        s->call.detach.token = (pthread_t)44;
        s = fixture_push(FX_PTHREAD_CREATE);
        s->flow = FX_STOP;
        s->call.thread.entry = paused_thread;
        s->call.thread.argument = NULL;
    }
    fixture_expected_escape = 2;
    run_case("thread-parent-stop");

    fixture_reset();
    queue_instruction(thread_instruction);
    {
        struct fixture_step *s = queue_return(FX_PTHREAD_CREATE, EAGAIN, 0);
        s->call.thread.entry = paused_thread;
        s->call.thread.argument = NULL;
    }
    record = (struct oracle_record){"thread", "ok", "incomplete", 1, 0, EAGAIN, 0, {0, 0, 0}};
    expect_output(
        output,
        oracle_line(output, sizeof output, thread_instruction, "incomplete", "none", &record, 1),
        0);
    run_case("thread-failure-before-worker");

    fixture_reset();
    queue_instruction("YSPROBE1 cpu-spin-32\n");
    {
        size_t i;
        for (i = 0; i < 31U; i++) {
            struct fixture_step *s = queue_return(FX_PTHREAD_CREATE, 0, 0);
            s->call.thread.entry = spinning_thread;
            s->call.thread.argument = (void *)(uintptr_t)i;
            s->call.thread.token = (pthread_t)(i + 1U);
        }
        {
            struct fixture_step *s = fixture_push(FX_LOOP);
            s->flow = FX_STOP;
            s->call.loop.site = 2U;
            s->call.loop.argument = 31U;
            s->call.loop.iteration = 0;
        }
    }
    fixture_expected_escape = 2;
    run_case("cpu-full-31-plus-main-worker-stop");

    fixture_reset();
    queue_instruction("YSPROBE1 cpu-spin-32\n");
    {
        struct fixture_step *s = queue_return(FX_PTHREAD_CREATE, 0, 0);
        s->call.thread.entry = spinning_thread;
        s->call.thread.argument = NULL;
        s->call.thread.token = (pthread_t)1;
        s->call.thread.dispatch = 1;
        s = fixture_push(FX_LOOP);
        s->flow = FX_STOP;
        s->call.loop.site = 2U;
        s->call.loop.argument = 0;
        s->call.loop.iteration = 0;
    }
    fixture_expected_escape = 2;
    run_case("cpu-dispatch-real-spinning-worker-stop");

    {
        size_t made;
        for (made = 0; made <= 2U; made += 2U) {
            size_t i;
            const char *instruction = "YSPROBE1 cpu-spin-32\n";
            char name[64];
            fixture_reset();
            queue_instruction(instruction);
            for (i = 0; i < made; i++) {
                struct fixture_step *s = queue_return(FX_PTHREAD_CREATE, 0, 0);
                s->call.thread.entry = spinning_thread;
                s->call.thread.argument = (void *)(uintptr_t)i;
                s->call.thread.token = (pthread_t)(i + 1U);
            }
            {
                struct fixture_step *s = queue_return(FX_PTHREAD_CREATE, EAGAIN, 0);
                s->call.thread.entry = spinning_thread;
                s->call.thread.argument = (void *)(uintptr_t)made;
            }
            record =
                (struct oracle_record){"cpu", "ok", "incomplete", 1, 0, EAGAIN, 0, {made, 32, 0}};
            expect_output(
                output,
                oracle_line(output, sizeof output, instruction, "incomplete", "none", &record, 1),
                0);
            (void)snprintf(name, sizeof name, "obligation-cpu-create-failure-after-%zu", made);
            run_case(name);
        }
    }

    fixture_reset();
    queue_instruction(memory_instruction);
    {
        struct fixture_step *s = queue_return(FX_MALLOC, -1, ENOMEM);
        s->call.allocation.size = BLOCK_SIZE;
    }
    record = (struct oracle_record){"memory", "ok", "incomplete", 1, 0, ENOMEM, 0, {0, 0, 0}};
    expect_output(
        output,
        oracle_line(output, sizeof output, memory_instruction, "incomplete", "none", &record, 1),
        0);
    run_case("memory-first-allocation-failure");

    fixture_reset();
    queue_instruction(memory_instruction);
    {
        struct fixture_step *s = queue_return(FX_MALLOC, 1, 0);
        s->call.allocation.size = BLOCK_SIZE;
        s->call.allocation.object = 0;
        s = queue_return(FX_MALLOC, 1, 0);
        s->call.allocation.size = BLOCK_SIZE;
        s->call.allocation.object = 1;
        s = fixture_push(FX_MALLOC);
        s->flow = FX_STOP;
        s->call.allocation.size = BLOCK_SIZE;
        s->call.allocation.object = 2;
    }
    fixture_expected_escape = 2;
    fixture_postcheck_kind = 1;
    run_case("obligation-memory-stop-on-later-allocation-before-result");

    fixture_reset();
    queue_instruction(sleep_instruction);
    {
        struct fixture_step *s = fixture_push(FX_SLEEP);
        s->flow = FX_STOP;
        s->call.sleep.seconds = 60;
    }
    fixture_expected_escape = 2;
    run_case("sleep-before-completion-stop");
}

static void resource_partial_output_cases(void)
{
    static const char *const modes[] = {"fork-bomb",         "thread-bomb", "cpu-spin-32",
                                        "memory-exhaustion", "sleep",       "scratch-fill"};
    static const char *const records[] = {"fork", "thread", "cpu", "memory", "sleep", "fill"};
    size_t i, variant;
    char instruction[64], output[768], name[96];
    for (i = 0; i < 6U; i++)
        for (variant = 0; variant < 2U; variant++) {
            struct oracle_record r = {records[i],
                                      "ok",
                                      i == 4U || i == 5U ? "success" : "incomplete",
                                      1,
                                      i == 4U || i == 5U,
                                      i == 4U || i == 5U ? 0
                                      : i == 3U          ? ENOMEM
                                                         : EAGAIN,
                                      0,
                                      {i == 4U   ? 60U
                                       : i == 5U ? 32U * BLOCK_SIZE
                                                 : 0U,
                                       i == 2U   ? 32U
                                       : i == 5U ? 32U * BLOCK_SIZE
                                                 : 0U,
                                       0}};
            size_t length;
            fixture_reset();
            (void)snprintf(instruction, sizeof instruction, "YSPROBE1 %s\n", modes[i]);
            queue_instruction(instruction);
            if (i == 0U)
                queue_return(FX_FORK, -1, EAGAIN);
            else if (i == 1U || i == 2U) {
                struct fixture_step *s = queue_return(FX_PTHREAD_CREATE, EAGAIN, 0);
                s->call.thread.entry = i == 1U ? paused_thread : spinning_thread;
                s->call.thread.argument = NULL;
            } else if (i == 3U) {
                struct fixture_step *s = queue_return(FX_MALLOC, -1, ENOMEM);
                s->call.allocation.size = BLOCK_SIZE;
            } else if (i == 4U) {
                struct fixture_step *s = queue_return(FX_SLEEP, 0, 0);
                s->call.sleep.seconds = 60;
            } else {
                size_t block;
                struct fixture_step *s;
                queue_open("/sandbox/scratch/fill", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600,
                           41, 0);
                s = queue_return(FX_MALLOC, 1, 0);
                s->call.allocation.size = BLOCK_SIZE;
                s->call.allocation.object = 0;
                for (block = 0; block < 32U; block++)
                    queue_write_repeat(41, 'x', BLOCK_SIZE, BLOCK_SIZE, 0);
                s = queue_return(FX_FREE, 0, 0);
                s->call.object.object = 0;
                queue_close(41, 0, 0);
            }
            length = oracle_line(output, sizeof output, instruction,
                                 i == 5U ? "complete" : "incomplete", "none", &r, 1);
            queue_write_exact(STDOUT_FILENO, output, length, 9, 0);
            if (variant == 0U)
                queue_write_exact(STDOUT_FILENO, output + 9, length - 9, -1, EIO);
            else {
                struct fixture_step *s = fixture_push(FX_WRITE);
                s->flow = FX_STOP;
                s->call.io.fd = STDOUT_FILENO;
                s->call.io.length = length - 9;
                s->call.io.kind = FX_BYTES_EXACT;
                s->call.io.bytes = (const unsigned char *)output + 9;
            }
            fixture_expected_output = (const unsigned char *)output;
            fixture_expected_output_length = 9;
            fixture_expected_stdout_total = 9;
            if (variant == 0U)
                fixture_expected_return = 74;
            else
                fixture_expected_escape = 2;
            (void)snprintf(name, sizeof name, "ROUT-%s-%s", modes[i],
                           variant == 0U ? "partial-error" : "during-stop");
            run_case(name);
        }
}

static void registry_self_controls(void)
{
    size_t count = sizeof obligation_registry / sizeof obligation_registry[0];
    size_t i = obligation_index("PAR-empty"), missing = obligation_index("PAR-bad-magic");
    int failures_before;
    fixture_check(count == 980U, "fixed registry has 980 ids");

    failures_before = fixture_failures;
    fixture_check(obligation_index("not-a-reviewed-obligation") == count,
                  "unknown registry id rejected");
    if (fixture_failures == failures_before)
        obligation_credit("FIX-unknown-id");
    (void)puts("control registry-unknown-id: rejected");

    failures_before = fixture_failures;
    fixture_check(i < count && obligation_registry[i].seen == 0U, "registry starts without credit");
    obligation_registry[i].seen = 1U;
    fixture_check(obligation_registry[i].seen != 0U, "duplicate credit state is detectable");
    obligation_registry[i].seen = 0U;
    if (fixture_failures == failures_before)
        obligation_credit("FIX-duplicate-id");
    (void)puts("control registry-duplicate-id: rejected");

    failures_before = fixture_failures;
    fixture_check(missing < count && obligation_registry[missing].seen == 0U,
                  "missing required id is detectable");
    if (fixture_failures == failures_before)
        obligation_credit("FIX-missing-id");
    (void)puts("control registry-missing-id: rejected");

    failures_before = fixture_failures;
    fixture_failures++;
    {
        const char *ids[] = {"PAR-bad-magic"};
        credit_ids(ids, 1U, failures_before);
    }
    fixture_failures--;
    fixture_check(obligation_registry[missing].seen == 0U,
                  "failed final guard cannot credit an id");
    if (fixture_failures == failures_before)
        obligation_credit("FIX-late-guard");
    (void)puts("control registry-late-guard: rejected");
}

static void verify_obligation_manifest(void)
{
    size_t i, j, runtime = 0, external = 0, blocked = 0;
    fixture_check(sizeof obligation_registry / sizeof obligation_registry[0] == 980U,
                  "required registry count");
    for (i = 0; i < sizeof obligation_registry / sizeof obligation_registry[0]; i++) {
        const struct obligation_binding *binding = &obligation_registry[i];
        fixture_check(binding->id[0] != '\0', "nonempty obligation id");
        for (j = i + 1U; j < sizeof obligation_registry / sizeof obligation_registry[0]; j++)
            fixture_check(strcmp(binding->id, obligation_registry[j].id) != 0,
                          "unique obligation id");
        if (binding->state == OB_RUNTIME) {
            runtime++;
            if (binding->seen != (unsigned char)obligation_selected(binding)) {
                (void)fprintf(stderr, "FAIL manifest %s selected=%d credits=%u\n", binding->id,
                              obligation_selected(binding), binding->seen);
                fixture_failures++;
            }
        } else if (binding->state == OB_EXTERNAL) {
            external++;
            fixture_check(binding->seen == 0U, "external obligation not runtime-credited");
        } else {
            blocked++;
            fixture_check(binding->seen == 0U, "blocked native obligation not credited");
        }
        (void)printf("ledger %s: %s\n", binding->id,
                     binding->state == OB_RUNTIME
                         ? (obligation_selected(binding) ? "executed" : "inapplicable")
                     : binding->state == OB_EXTERNAL ? "external"
                                                     : "blocked");
    }
    fixture_check(runtime == 874U && external == 99U && blocked == 7U,
                  "closed runtime external blocked partition");
}

int main(void)
{
    int before, all_before = fixture_failures;
    (void)fixture_kill;
#if !defined(MADV_REMOVE)
    (void)fixture_mmap;
    (void)fixture_madvise;
    (void)fixture_munmap;
#endif
    before = fixture_failures;
    self_controls();
    registry_self_controls();
    before = fixture_failures;
    parser_cases();
    candidate_cases();
    file_write_cases();
    evidence_matrix();
    sentinel_cases();
    sentinel_maximum_case();
    sentinel_prerequisite_cases();
    finish_obligation_family(1U, before);
    finish_obligation_family(4U, before);
    finish_obligation_family(5U, before);
    finish_obligation_family(7U, before);
    finish_obligation_family(10U, before);
    before = fixture_failures;
    result_emission_cases();
    finish_obligation_family(3U, before);
    before = fixture_failures;
    evidence_list_cases();
    finish_obligation_family(6U, before);
    before = fixture_failures;
    scratch_setup_failure_cases();
    finish_obligation_family(8U, before);
    before = fixture_failures;
    scratch_action_cases();
#if defined(MADV_REMOVE)
    if (obligation_selected(&obligation_registry[obligation_index("SF-platform-madv-remove")]))
        obligation_credit("SF-platform-madv-remove");
#endif
    finish_obligation_family(9U, before);
    before = fixture_failures;
    socket_cases();
    socket_outcome_cases();
    socket_prerequisite_cases();
    actual_socket_facts_case();
    finish_obligation_family(11U, before);
    before = fixture_failures;
    descriptor_cases();
    descriptor_metadata_cases();
    finish_obligation_family(12U, before);
    before = fixture_failures;
    environment_cases();
    pid_cases();
    finish_obligation_family(13U, before);
    before = fixture_failures;
    namespace_cases();
    finish_obligation_family(14U, before);
    before = fixture_failures;
    raw_output_cases();
    finish_obligation_family(15U, before);
    before = fixture_failures;
    scratch_fill_cases();
    finish_obligation_family(16U, before);
    before = fixture_failures;
    resource_cases();
    finish_obligation_family(17U, before);
    before = fixture_failures;
    resource_partial_output_cases();
    finish_obligation_family(18U, before);
    if (fixture_failures == all_before) {
        static const char *const mode_ids[] = {"M01", "M02", "M03", "M04", "M05", "M06", "M07",
                                               "M08", "M09", "M10", "M11", "M12", "M13", "M14",
                                               "M15", "M16", "M17", "M18", "M19", "M20", "M21",
                                               "M22", "M23", "M24", "M25", "M26", "M27"};
        credit_ids(mode_ids, sizeof mode_ids / sizeof mode_ids[0], all_before);
        obligation_credit("FIX-production-boundary");
        obligation_credit("FIX-queue-ownership");
    }
    finish_obligation_family(2U, all_before);
    finish_obligation_family(19U, all_before);
    finish_obligation_family(0U, all_before);
    verify_obligation_manifest();
    if (fixture_failures != 0)
        return 1;
    (void)puts("probe production entry matrix: ok");
    return 0;
}
#else
int main(void) { return probe_main(); }
#endif
