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
#if defined(YSTACK_PROBE_TEST) && !defined(SOCK_CLOEXEC)
#define SOCK_CLOEXEC 0
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
 * first leak. Socket uses family, type and protocol. Environment uses observed
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
 * descriptors                            fd0, fd1, fd2, fd-scan
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

#ifdef YSTACK_PROBE_TEST
/* This boundary replaces only low-level operations. Parser, action selection,
 * iteration, accounting, classification and result production stay unchanged. */
enum test_scenario {
    TEST_DEFAULT, TEST_FILE_SUCCESS, TEST_FILE_REFUSED, TEST_FILE_READ_ERROR,
    TEST_FILE_CLEANUP_ERROR, TEST_SENTINEL_MATCH, TEST_SENTINEL_MISMATCH,
    TEST_SENTINEL_ABSENT, TEST_SENTINEL_WRONG_TYPE, TEST_SENTINEL_METADATA_ERROR,
    TEST_DESCRIPTOR_VALID, TEST_DESCRIPTOR_WRONG,
    TEST_DESCRIPTOR_BAD_ACCESS, TEST_DESCRIPTOR_MISSING_APPEND,
    TEST_DESCRIPTOR_MISSING, TEST_DESCRIPTOR_METADATA_ERROR,
    TEST_DESCRIPTOR_LEAK3, TEST_DESCRIPTOR_LEAK128, TEST_DESCRIPTOR_SCAN_ERROR,
    TEST_SOCKET_REFUSED, TEST_SOCKET_SUCCESS, TEST_SOCKET_UNSUPPORTED,
    TEST_SOCKET_INVALID, TEST_SOCKET_CLOSE_ERROR, TEST_WRITE_SHORT,
    TEST_WRITE_EINTR, TEST_WRITE_ZERO, TEST_WRITE_ERROR, TEST_WRITE_PREFIX_ERROR,
    TEST_ALLOC_FAIL, TEST_RESOURCE_PARTIAL, TEST_OPERATION_REFUSED, TEST_OPERATION_CLEANUP,
    TEST_SCRATCH_MMAP_FAIL, TEST_SCRATCH_MKDIR_FAIL
};

struct test_state {
    enum test_scenario scenario;
    unsigned char bytes[4097];
    size_t byte_count, read_offset;
    uint64_t write_requested, write_returned;
    unsigned write_calls, open_calls, read_calls, close_calls, socket_calls;
    unsigned worker_calls, allocation_calls, sleep_calls;
    int socket_family, socket_type, socket_protocol;
    pid_t pid, parent;
    unsigned char captured[128]; size_t captured_length;
};
static struct test_state test_state;
static unsigned char test_allocation[BLOCK_SIZE];

static void test_reset(enum test_scenario scenario)
{
    memset(&test_state, 0, sizeof test_state);
    test_state.scenario = scenario;
    test_state.pid = 1;
    test_state.parent = 0;
}

static int test_open(const char *path, int flags, mode_t mode)
{
    (void)path; (void)flags; (void)mode; test_state.open_calls++;
    if (test_state.scenario == TEST_FILE_REFUSED) { errno = EPERM; return -1; }
    if (test_state.scenario == TEST_SENTINEL_ABSENT) { errno = ENOENT; return -1; }
    if (test_state.scenario == TEST_OPERATION_REFUSED && test_state.open_calls > 1U) {
        errno = EPERM; return -1;
    }
    return 41;
}

static ssize_t test_read(int fd, void *buffer, size_t length)
{
    size_t left, take; (void)fd; test_state.read_calls++;
    if (test_state.scenario == TEST_FILE_READ_ERROR) { errno = EIO; return -1; }
    left = test_state.byte_count - test_state.read_offset;
    if (left == 0U) return 0;
    take = left < length ? left : length;
    memcpy(buffer, test_state.bytes + test_state.read_offset, take); test_state.read_offset += take;
    return (ssize_t)take;
}

static ssize_t test_write(int fd, const void *buffer, size_t length)
{
    size_t returned = length, room, copy; (void)fd;
    test_state.write_calls++; test_state.write_requested += length;
    if (test_state.scenario == TEST_WRITE_EINTR && test_state.write_calls == 1U) { errno = EINTR; return -1; }
    if (test_state.scenario == TEST_WRITE_ZERO) return 0;
    if (test_state.scenario == TEST_WRITE_ERROR) { errno = EIO; return -1; }
    if (test_state.scenario == TEST_WRITE_PREFIX_ERROR) {
        if (test_state.write_calls > 1U) { errno = EPIPE; return -1; }
        returned = returned > 31U ? 31U : returned;
    }
    if (test_state.scenario == TEST_WRITE_SHORT && returned > 17U) returned = 17U;
    room = sizeof test_state.captured - test_state.captured_length;
    copy = returned < room ? returned : room;
    if (copy != 0U) { memcpy(test_state.captured + test_state.captured_length, buffer, copy); test_state.captured_length += copy; }
    test_state.write_returned += returned; return (ssize_t)returned;
}

static int test_close(int fd)
{
    (void)fd; test_state.close_calls++;
    if (test_state.scenario == TEST_FILE_CLEANUP_ERROR || test_state.scenario == TEST_SOCKET_CLOSE_ERROR) {
        errno = EIO; return -1;
    }
    if (test_state.scenario == TEST_OPERATION_CLEANUP && test_state.close_calls > 1U) {
        errno = EIO; return -1;
    }
    return 0;
}

static int test_fstat(int fd, struct stat *st)
{
    if (test_state.scenario == TEST_SENTINEL_METADATA_ERROR && fd == 41) {
        errno = EIO;
        return -1;
    }
    if (test_state.scenario == TEST_DESCRIPTOR_MISSING && fd == 2) { errno = EBADF; return -1; }
    if (test_state.scenario == TEST_DESCRIPTOR_METADATA_ERROR && fd == 1) { errno = EIO; return -1; }
    memset(st, 0, sizeof *st); st->st_mode = S_IFREG | 0600;
    if (test_state.scenario == TEST_SENTINEL_WRONG_TYPE && fd == 41)
        st->st_mode = S_IFDIR | 0700;
    if (test_state.scenario == TEST_DESCRIPTOR_WRONG && fd == 0) st->st_mode = S_IFDIR | 0700;
    return 0;
}

static int test_fcntl(int fd, int command)
{
    if (command == F_GETFL) {
        if (fd == 0) return test_state.scenario == TEST_DESCRIPTOR_BAD_ACCESS ? O_WRONLY : O_RDONLY;
        if (test_state.scenario == TEST_DESCRIPTOR_WRONG && fd == 1) return O_WRONLY;
        if (test_state.scenario == TEST_DESCRIPTOR_MISSING_APPEND && fd == 2) return O_WRONLY;
        return O_WRONLY | O_APPEND;
    }
    if (test_state.scenario == TEST_DESCRIPTOR_LEAK3 && fd == 3) return 0;
    if (test_state.scenario == TEST_DESCRIPTOR_LEAK128 && fd == 128) return 0;
    if (test_state.scenario == TEST_DESCRIPTOR_SCAN_ERROR && fd == 77) { errno = EIO; return -1; }
    errno = EBADF; return -1;
}

static int test_socket(int family, int type, int protocol)
{
    test_state.socket_calls++; test_state.socket_family = family;
    test_state.socket_type = type; test_state.socket_protocol = protocol;
    if (test_state.scenario == TEST_SOCKET_SUCCESS || test_state.scenario == TEST_SOCKET_CLOSE_ERROR) return 42;
    if (test_state.scenario == TEST_SOCKET_UNSUPPORTED) errno = EAFNOSUPPORT;
    else if (test_state.scenario == TEST_SOCKET_INVALID) errno = EINVAL;
    else errno = EPERM;
    return -1;
}

static int test_truncate(const char *path, off_t length) { (void)path; (void)length; errno = EPERM; return -1; }
static int test_link(const char *oldpath, const char *newpath) { (void)oldpath; (void)newpath; errno = EPERM; return -1; }
static int test_rename(const char *oldpath, const char *newpath) { (void)oldpath; (void)newpath; errno = EPERM; return -1; }
static int test_mkdir(const char *path, mode_t mode)
{
    (void)path; (void)mode;
    if (test_state.scenario == TEST_SCRATCH_MKDIR_FAIL) { errno = ENOSPC; return -1; }
    return 0;
}
static int test_rmdir(const char *path) { (void)path; errno = EPERM; return -1; }
static int test_unlink(const char *path) { (void)path; errno = EPERM; return -1; }
static pid_t test_getpid(void) { return test_state.pid; }
static pid_t test_getppid(void) { return test_state.parent; }
static DIR *test_opendir(const char *path) { (void)path; return (DIR *)(void *)&test_state; }
static struct dirent *test_readdir(DIR *dir) { (void)dir; errno = EPERM; return NULL; }
static int test_closedir(DIR *dir) { (void)dir; return 0; }
#if defined(__linux__)
static int test_unshare(int flags) { (void)flags; errno = EPERM; return -1; }
#endif
static void *test_malloc(size_t size)
{
    test_state.allocation_calls++;
    if (test_state.scenario == TEST_ALLOC_FAIL ||
        (test_state.scenario == TEST_RESOURCE_PARTIAL && test_state.allocation_calls > 2U)) {
        errno = ENOMEM;
        return NULL;
    }
    if (test_state.scenario == TEST_RESOURCE_PARTIAL) return test_allocation;
    return malloc(size);
}
static void test_free(void *memory)
{
    if (memory != test_allocation) free(memory);
}
static pid_t test_fork(void)
{
    test_state.worker_calls++;
    if (test_state.worker_calls > 3U) { errno = EAGAIN; return -1; }
    return (pid_t)(100U + test_state.worker_calls);
}
static int test_pthread_create(pthread_t *thread, const pthread_attr_t *attributes,
                               void *(*entry)(void *), void *argument)
{
    (void)thread; (void)attributes; (void)entry; (void)argument;
    test_state.worker_calls++;
    return test_state.worker_calls > 3U ? EAGAIN : 0;
}
static int test_pthread_detach(pthread_t thread) { (void)thread; return 0; }
static unsigned test_sleep(unsigned seconds) { (void)seconds; test_state.sleep_calls++; return 0; }
static int test_ftruncate(int fd, off_t length) { (void)fd; (void)length; errno = EPERM; return -1; }
#if defined(__linux__)
static int test_fallocate(int fd, int mode, off_t offset, off_t length)
{ (void)fd; (void)mode; (void)offset; (void)length; errno = EPERM; return -1; }
#endif
#if defined(MADV_REMOVE)
static void *test_mmap(void *address, size_t length, int protection, int flags, int fd, off_t offset)
{
    (void)address; (void)length; (void)protection; (void)flags; (void)fd; (void)offset;
    if (test_state.scenario == TEST_SCRATCH_MMAP_FAIL) { errno = ENOMEM; return MAP_FAILED; }
    return (void *)test_state.bytes;
}
static int test_madvise(void *address, size_t length, int advice)
{ (void)address; (void)length; (void)advice; errno = EPERM; return -1; }
static int test_munmap(void *address, size_t length) { (void)address; (void)length; return 0; }
#endif

#define open(path, flags, mode) test_open((path), (flags), (mode))
#define read(fd, buffer, length) test_read((fd), (buffer), (length))
#define write(fd, buffer, length) test_write((fd), (buffer), (length))
#define close(fd) test_close((fd))
#define fstat(fd, st) test_fstat((fd), (st))
#define fcntl(fd, command) test_fcntl((fd), (command))
#define socket(family, type, protocol) test_socket((family), (type), (protocol))
#define truncate(path, length) test_truncate((path), (length))
#define link(oldpath, newpath) test_link((oldpath), (newpath))
#define rename(oldpath, newpath) test_rename((oldpath), (newpath))
#define mkdir(path, mode) test_mkdir((path), (mode))
#define rmdir(path) test_rmdir((path))
#define unlink(path) test_unlink((path))
#define getpid() test_getpid()
#define getppid() test_getppid()
#define opendir(path) test_opendir((path))
#define readdir(dir) test_readdir((dir))
#define closedir(dir) test_closedir((dir))
#if defined(__linux__)
#define unshare(flags) test_unshare((flags))
#endif
#define malloc(size) test_malloc((size))
#define free(memory) test_free((memory))
#define fork() test_fork()
#define pthread_create(thread, attributes, entry, argument) test_pthread_create((thread), (attributes), (entry), (argument))
#define pthread_detach(thread) test_pthread_detach((thread))
#define sleep(seconds) test_sleep((seconds))
#define ftruncate(fd, length) test_ftruncate((fd), (length))
#if defined(__linux__)
#define fallocate(fd, mode, offset, length) test_fallocate((fd), (mode), (offset), (length))
#endif
#if defined(MADV_REMOVE)
#define mmap(address, length, protection, flags, fd, offset) test_mmap((address), (length), (protection), (flags), (fd), (offset))
#define madvise(address, length, advice) test_madvise((address), (length), (advice))
#define munmap(address, length) test_munmap((address), (length))
#endif
#endif

static int payload_write_all(int fd, const void *data, size_t length)
{
    size_t offset = 0;
    while (offset < length) {
        ssize_t n = write(fd, (const unsigned char *)data + offset, length - offset);
        if (n < 0) { if (errno == EINTR) continue; return 0; }
        if (n == 0) return 0;
        offset += (size_t)n;
    }
    return 1;
}

static void file_action(struct result *result, const char *name, const char *path, int flags,
                        mode_t mode, int do_read, const void *write_data, size_t write_length,
                        int success_expected)
{
    int fd = open(path, flags, mode), primary = 0, cleanup = 0; ssize_t n = -1; unsigned char byte;
    if (fd < 0) { primary = errno; add_record(result, name, PRE_OK, 1, 1, classify_errno(primary), primary, 0, 0, 0, 0); return; }
    if (do_read) n = read(fd, &byte, 1U);
    else if (write_data != NULL) n = write(fd, write_data, write_length);
    else n = 0;
    if (n < 0) primary = errno;
    if (close(fd) != 0) cleanup = errno;
    add_record(result, name, PRE_OK, 1, n >= 0, n >= 0 ? (success_expected ? OUT_SUCCESS : OUT_VIOLATION) : classify_errno(primary),
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
    add_record(result, name, PRE_OK, 1, rc >= 0, rc >= 0 ? OUT_VIOLATION : classify_errno(saved), saved,
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
        if (n == 0) break; used += (size_t)n;
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
    int fd, leaks = 0, first = 0;
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
        else if (errno != EBADF) { add_record(result, "fd-scan", PRE_OK, 1, 0, OUT_INCOMPLETE, errno, 0,
            FD_SCAN_FIRST, FD_SCAN_LAST, (uint64_t)fd); result->force_incomplete = 1; return; }
    }
    add_record(result, "fd-scan", PRE_OK, 1, 1, leaks == 0 ? OUT_INCOMPLETE : OUT_VIOLATION, 0, 0,
               FD_SCAN_FIRST, FD_SCAN_LAST, leaks == 0 ? 0U : (uint64_t)first);
    result->force_incomplete = 1;
}

static void socket_action(const struct request *request, struct result *result)
{
#if (defined(__linux__) && defined(AF_MAX)) || defined(YSTACK_PROBE_TEST)
    int type = SOCK_STREAM | SOCK_CLOEXEC, protocol = 0, fd, saved = 0, cleanup = 0;
#ifdef YSTACK_PROBE_TEST
    const unsigned domain_max = 8U;
#else
    const unsigned domain_max = AF_MAX;
#endif
    result->domain_max = domain_max;
    if (request->family >= domain_max) { add_record(result, "socket", PRE_UNKNOWN, 0, 0, OUT_INCOMPLETE, 0, 0,
        request->family, 0, 0); result->force_incomplete = 1; return; }
#ifdef YSTACK_PROBE_TEST
    if (request->family == 3U) { type = SOCK_RAW | SOCK_CLOEXEC; protocol = 7; }
    if (request->family == 4U) { type = SOCK_RAW | SOCK_CLOEXEC; protocol = 0; }
#endif
#ifdef AF_NETLINK
    if (request->family == AF_NETLINK) { type = SOCK_RAW | SOCK_CLOEXEC; protocol = NETLINK_USERSOCK; }
#endif
#ifdef AF_PACKET
    if (request->family == AF_PACKET) { type = SOCK_RAW | SOCK_CLOEXEC; protocol = 0; }
#endif
    fd = socket((int)request->family, type, protocol);
    if (fd < 0) saved = errno; else if (close(fd) != 0) cleanup = errno;
    add_record(result, "socket", PRE_OK, 1, 1, fd >= 0 ? OUT_VIOLATION : classify_errno(saved), saved, cleanup,
               request->family, (uint64_t)(unsigned)type, (uint64_t)(unsigned)protocol);
#else
    (void)request; result->domain = "unknown"; result->force_incomplete = 1;
    add_record(result, "socket", PRE_UNKNOWN, 0, 0, OUT_INCOMPLETE, 0, 0, 0, 0, 0);
#endif
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
#ifdef YSTACK_PROBE_TEST
    return NULL;
#else
    for (;;) pause();
#endif
}
static void *spinning_thread(void *unused)
{
#ifdef YSTACK_PROBE_TEST
    return unused;
#else
    volatile uint64_t value = (uintptr_t)unused + 1U;
    for (;;) value = value * UINT64_C(6364136223846793005) + 1U;
#endif
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
        int fd, setup_cleanup = 0, setup, rc = -1, saved = 0, cleanup = 0;
        (void)snprintf(path, sizeof path, "/sandbox/scratch/probe-%zu", i);
        if (i == 5U) {
            if (mkdir(path, 0700) != 0) setup = errno;
            else setup = 0;
            if (setup == 0) {
                rc = rmdir(path);
                if (rc != 0) saved = errno;
            }
        } else if (i == 6U) {
#if defined(__linux__) && defined(O_TMPFILE)
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
            setup = establish_block(path, &setup_cleanup);
            if (setup == 0 && setup_cleanup == 0) {
                if (i == 0U) {
                    fd = open(path, O_RDWR | O_CLOEXEC, 0);
                    if (fd < 0) saved = errno;
                    else {
                        rc = ftruncate(fd, 0);
                        if (rc != 0) saved = errno;
                        if (close(fd) != 0) cleanup = errno;
                    }
                } else if (i == 1U) {
#if defined(__linux__)
                    fd = open(path, O_RDWR | O_CLOEXEC, 0);
                    if (fd < 0) saved = errno;
                    else {
                        rc = fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
                                       0, 1);
                        if (rc != 0) saved = errno;
                        if (close(fd) != 0) cleanup = errno;
                    }
#else
                    saved = ENOSYS;
#endif
                } else if (i == 2U) {
#if defined(MADV_REMOVE)
                    void *page;
                    fd = open(path, O_RDWR | O_CLOEXEC, 0);
                    if (fd < 0) saved = errno;
                    else {
                        page = mmap(NULL, 4096U, PROT_READ | PROT_WRITE,
                                    MAP_SHARED, fd, 0);
                        if (page == MAP_FAILED) saved = errno;
                        else {
                            rc = madvise(page, 4096U, MADV_REMOVE);
                            if (rc != 0) saved = errno;
                            if (munmap(page, 4096U) != 0 && cleanup == 0)
                                cleanup = errno;
                        }
                        if (close(fd) != 0 && cleanup == 0)
                            cleanup = errno;
                    }
#else
                    saved = ENOSYS;
#endif
                } else if (i == 3U) {
                    rc = truncate(path, 0);
                    if (rc != 0) saved = errno;
                } else {
                    rc = unlink(path);
                    if (rc != 0) saved = errno;
                }
            }
        }
        if (setup != 0 || setup_cleanup != 0) {
            add_record(result, names[i], PRE_FAILED, 0, 0, OUT_INCOMPLETE,
                       setup, setup_cleanup, 0, 0, 0);
        } else {
            enum outcome outcome = rc == 0 ? OUT_VIOLATION :
                (saved == ENOSYS ? OUT_UNSUPPORTED : classify_errno(saved));
            add_record(result, names[i], PRE_OK, 1, rc == 0, outcome,
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
        add_record(result, "list", PRE_OK, 1, rc == 0,
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
          add_record(result, "unshare", PRE_OK, 1, rc == 0, rc == 0 ? OUT_VIOLATION : classify_errno(saved),
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
    if (request.mode->action == ACT_FORGED_STDOUT) return payload_write_all(STDOUT_FILENO, forged, sizeof forged - 1U) ? 0 : 73;
    run_action(&request, &result); return emit_result(&request, &result) ? 0 : 74;
}

#ifdef YSTACK_PROBE_TEST
static int failures;
static void check(int condition, const char *name) { if (!condition) { fprintf(stderr, "FAIL %s\n", name); failures++; } }
static void make_request(const char *text, struct request *request)
{
    check(parse_request_bytes((const unsigned char *)text, strlen(text), request), "fixture request parses");
}
static void parser_tests(void)
{
    struct request r; char input[10000]; size_t i;
    static const char *const good[] = {"YSPROBE1 candidate-read\n", "YSPROBE1 socket-family 0\n",
        "YSPROBE1 socket-family 65535\n",
        "YSPROBE1 host-sentinel 2f782f79 1 0000000000000000000000000000000000000000000000000000000000000000\n"};
    static const char *const bad[] = {"", "candidate-read\n", "YSPROBE1 unknown\n", "YSPROBE1 candidate-read x\n",
        "YSPROBE1  candidate-read\n", "YSPROBE1 candidate-read \n", "YSPROBE1 candidate-read\r\n",
        "YSPROBE1 candidate-read\nextra", "YSPROBE1 socket-family 00\n", "YSPROBE1 socket-family +1\n",
        "YSPROBE1 socket-family 65536\n", "YSPROBE1 host-sentinel 2F78 1 0000000000000000000000000000000000000000000000000000000000000000\n",
        "YSPROBE1 host-sentinel 2f2e 1 0000000000000000000000000000000000000000000000000000000000000000\n",
        "YSPROBE1 host-sentinel 2f78 0 0000000000000000000000000000000000000000000000000000000000000000\n"};
    for (i = 0; i < sizeof good / sizeof good[0]; i++) check(parse_request_bytes((const unsigned char *)good[i], strlen(good[i]), &r), "valid parser case");
    for (i = 0; i < sizeof bad / sizeof bad[0]; i++) check(!parse_request_bytes((const unsigned char *)bad[i], strlen(bad[i]), &r), "invalid parser case");
    memset(input, 'a', sizeof input); memcpy(input, "YSPROBE1 candidate-read", 23); input[INPUT_CAP - 1U] = '\n';
    check(!parse_request_bytes((const unsigned char *)input, INPUT_CAP, &r), "input cap");
    for (i = 0; i < sizeof modes / sizeof modes[0]; i++) {
        if (modes[i].parameters == 0U) { (void)snprintf(input, sizeof input, "YSPROBE1 %s\n", modes[i].name);
            check(parse_request_bytes((const unsigned char *)input, strlen(input), &r) && r.mode == &modes[i], "closed mode"); }
    }

    {
        char path[4097], hexpath[8193], request_text[INPUT_CAP + 1U];
        static const char digits[] = "0123456789abcdef"; size_t n;
        path[0] = '/'; memset(path + 1, 'a', 4095U); path[4096] = '\0';
        for (n = 0; n < 4096U; n++) { unsigned char c = (unsigned char)path[n];
            hexpath[n * 2U] = digits[c >> 4]; hexpath[n * 2U + 1U] = digits[c & 15U]; }
        hexpath[8192] = '\0';
        (void)snprintf(request_text, sizeof request_text,
            "YSPROBE1 sibling-sentinel %s 4096 0000000000000000000000000000000000000000000000000000000000000000\n",
            hexpath);
        check(parse_request_bytes((const unsigned char *)request_text, strlen(request_text), &r) &&
              strlen(r.path) == 4096U && r.size == 4096U, "maximum sentinel path and size");
    }

    {
        static const char *const path_bad[] = {
            "YSPROBE1 host-sentinel 78 1 0000000000000000000000000000000000000000000000000000000000000000\n",
            "YSPROBE1 host-sentinel 2f 1 0000000000000000000000000000000000000000000000000000000000000000\n",
            "YSPROBE1 host-sentinel 2f782f 1 0000000000000000000000000000000000000000000000000000000000000000\n",
            "YSPROBE1 host-sentinel 2f782f2e2f79 1 0000000000000000000000000000000000000000000000000000000000000000\n",
            "YSPROBE1 host-sentinel 2f782f2e2e2f79 1 0000000000000000000000000000000000000000000000000000000000000000\n",
            "YSPROBE1 host-sentinel 2f780079 1 0000000000000000000000000000000000000000000000000000000000000000\n",
            "YSPROBE1 host-sentinel 2f78 4097 0000000000000000000000000000000000000000000000000000000000000000\n",
            "YSPROBE1 host-sentinel 2f78 1 fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\n",
            "YSPROBE1 host-sentinel 2f78 1 F000000000000000000000000000000000000000000000000000000000000000\n"
        };
        for (i = 0; i < sizeof path_bad / sizeof path_bad[0]; i++)
            check(!parse_request_bytes((const unsigned char *)path_bad[i], strlen(path_bad[i]), &r),
                  "invalid sentinel binding rejected");
    }
}

static void parser_action_boundary_tests(void)
{
    static const char *const invalid[] = {
        "YSPROBE1 candidate-read extra\n",
        "YSPROBE1 socket-family\n",
        "YSPROBE1 socket-family 1 extra\n",
        "YSPROBE1 socket-family 18446744073709551615\n",
        "YSPROBE1 host-sentinel\n",
        "YSPROBE1 host-sentinel 2f78 1\n",
        "YSPROBE1 host-sentinel 2f78 1 0000000000000000000000000000000000000000000000000000000000000000 extra\n",
        "YSPROBE1 sibling-sentinel 2f78 01 0000000000000000000000000000000000000000000000000000000000000000\n"
    };
    struct request request;
    size_t i;
    for (i = 0; i < sizeof invalid / sizeof invalid[0]; i++) {
        test_reset(TEST_DEFAULT);
        check(!parse_request_bytes((const unsigned char *)invalid[i], strlen(invalid[i]), &request),
              "parser rejects before action boundary");
        check(test_state.open_calls == 0U && test_state.read_calls == 0U &&
              test_state.write_calls == 0U && test_state.socket_calls == 0U,
              "parse failure performs no low-level operation");
    }

    {
        const char *instruction = "YSPROBE1 candidate-read\n";
        char expected[65];
        make_request(instruction, &request);
        digest_hex(instruction, strlen(instruction), expected);
        check(strcmp(request.instruction_digest, expected) == 0,
              "result binding hashes exact admitted instruction including LF");
    }

    {
        unsigned char bytes[] = "YSPROBE1 candidate-read\n";
        size_t length = sizeof bytes - 1U;
        bytes[2] = 0U;
        check(!parse_request_bytes(bytes, length, &request),
              "embedded NUL rejected before action");
        bytes[2] = (unsigned char)'P';
        bytes[4] = 0x7fU;
        check(!parse_request_bytes(bytes, length, &request),
              "non-ASCII DEL rejected before action");
        bytes[4] = (unsigned char)'O';
        bytes[length - 1U] = (unsigned char)'x';
        check(!parse_request_bytes(bytes, length, &request),
              "missing final LF rejected before action");
    }

    {
        unsigned char bytes[] = {'Y','S','P','R','O','B','E','1',' ',
            'c','a','n','d','i','d','a','t','e','-','r','e','a','d','\n','x','\n'};
        check(!parse_request_bytes(bytes, sizeof bytes, &request),
              "second input line rejected before action");
    }
}
static void result_tests(void)
{
    struct request q; struct result r; const char *s = "YSPROBE1 signal-supervisor\n";
    check(parse_request_bytes((const unsigned char *)s, strlen(s), &q), "signal parse");
    memset(&r, 0, sizeof r);
    signal_action(&r);
    check(r.count == 2U && !r.records[1].attempted && r.force_incomplete,
          "signal never guesses target");
    memset(&r, 0, sizeof r); add_record(&r, "x", PRE_OK, 1, 1, OUT_VIOLATION, 0, EIO, 1, 2, 3);
    check(!result_complete(&r) && r.records[0].outcome == OUT_VIOLATION, "cleanup does not erase primary");
    check(classify_errno(EPERM) == OUT_REFUSED && classify_errno(EAFNOSUPPORT) == OUT_UNSUPPORTED && classify_errno(EINVAL) == OUT_INCOMPLETE, "errno classes");

    {
        char line[RESULT_CAP]; size_t length = 0;
        memset(&r, 0, sizeof r); r.domain = "none";
        add_record(&r, "read", PRE_OK, 1, 1, OUT_REFUSED, EPERM, 0, 4, 5, 6);
        check(format_result(&q, &r, line, &length), "bounded result formats");
        check(length < RESULT_CAP && line[length - 1U] == '\n' &&
              memchr(line, '\n', length - 1U) == NULL, "result is exactly one bounded line");
        check(strstr(line, " read:ok:1:1:refused:") != NULL, "result contains closed record fields");
    }

    {
        char line[RESULT_CAP]; size_t length = 0, i;
        memset(&r, 0, sizeof r); r.force_incomplete = 1; r.domain_max = 8U;
        q.mode = find_mode("socket-family"); strcpy(q.instruction_digest,
            "0000000000000000000000000000000000000000000000000000000000000000");
        for (i = 0; i < RECORD_CAP; i++)
            add_record(&r, "socket", PRE_OK, 1, 1, OUT_REFUSED, EPERM, 0, i, 1, 0);
        check(format_result(&q, &r, line, &length) && length < RESULT_CAP,
              "maximum static record set fits formatter bound");
        check(strstr(line, " incomplete linux-build-af-v1/8 32 ") != NULL,
              "domain and incomplete state are explicit");
    }
}

static void file_action_tests(void)
{
    struct request q; struct result r;
    make_request("YSPROBE1 candidate-read\n", &q);
    test_reset(TEST_FILE_SUCCESS); test_state.bytes[0] = 'x'; test_state.byte_count = 1U;
    run_action(&q, &r);
    check(r.count == 1U && r.records[0].outcome == OUT_SUCCESS && r.records[0].completed,
          "candidate readable control");
    check(test_state.open_calls == 1U && test_state.read_calls == 1U && test_state.close_calls == 1U,
          "candidate real action call order");

    test_reset(TEST_FILE_REFUSED); run_action(&q, &r);
    check(r.records[0].outcome == OUT_REFUSED && r.records[0].error_number == EPERM,
          "candidate read refusal preserved");

    test_reset(TEST_FILE_READ_ERROR); run_action(&q, &r);
    check(r.records[0].outcome == OUT_INCOMPLETE && !r.records[0].completed && r.records[0].error_number == EIO,
          "candidate read error incomplete");

    test_reset(TEST_FILE_CLEANUP_ERROR); test_state.bytes[0] = 'x'; test_state.byte_count = 1U;
    run_action(&q, &r);
    check(r.records[0].outcome == OUT_SUCCESS && r.records[0].cleanup_error == EIO && !result_complete(&r),
          "cleanup error does not replace candidate outcome");

    make_request("YSPROBE1 candidate-write\n", &q);
    test_reset(TEST_FILE_SUCCESS); run_action(&q, &r);
    check(r.records[0].outcome == OUT_VIOLATION && r.records[0].value[0] == 1U,
          "unexpected candidate write visible");
    test_reset(TEST_FILE_REFUSED); run_action(&q, &r);
    check(r.records[0].outcome == OUT_REFUSED && r.records[0].attempted,
          "candidate write denial is attempted refusal");
}

static void sentinel_tests(void)
{
    static const unsigned char expected[] = "fixture";
    char digest[65], instruction[512]; struct request q; struct result r;
    digest_hex(expected, sizeof expected - 1U, digest);
    (void)snprintf(instruction, sizeof instruction,
        "YSPROBE1 host-sentinel 2f71756172616e74696e652f686f7374 %zu %s\n",
        sizeof expected - 1U, digest);
    make_request(instruction, &q);

    test_reset(TEST_SENTINEL_MATCH); memcpy(test_state.bytes, expected, sizeof expected - 1U);
    test_state.byte_count = sizeof expected - 1U; run_action(&q, &r);
    check(r.count == 2U && r.records[0].outcome == OUT_SUCCESS &&
          r.records[1].outcome == OUT_SUCCESS && r.records[1].value[0] == sizeof expected - 1U &&
          r.records[1].value[2] == 1U, "sentinel path size digest match");

    test_reset(TEST_SENTINEL_MISMATCH); memcpy(test_state.bytes, "wrong!!", 7U);
    test_state.byte_count = 7U; run_action(&q, &r);
    check(r.records[1].outcome == OUT_VIOLATION && r.records[1].value[2] == 0U,
          "readable sentinel digest mismatch violation");

    test_reset(TEST_SENTINEL_MISMATCH); memcpy(test_state.bytes, expected, sizeof expected - 1U);
    test_state.bytes[sizeof expected - 1U] = '!'; test_state.byte_count = sizeof expected;
    run_action(&q, &r);
    check(r.records[1].outcome == OUT_VIOLATION && r.records[1].value[0] == sizeof expected,
          "readable sentinel extra byte violation");

    test_reset(TEST_SENTINEL_ABSENT); run_action(&q, &r);
    check(r.records[0].outcome == OUT_INCOMPLETE && r.records[0].error_number == ENOENT,
          "absent sentinel records namespace view only");

    test_reset(TEST_FILE_REFUSED); run_action(&q, &r);
    check(r.records[0].outcome == OUT_REFUSED && r.records[0].error_number == EPERM,
          "sentinel permission refusal distinct");

    test_reset(TEST_FILE_READ_ERROR); run_action(&q, &r);
    check(r.records[1].outcome == OUT_INCOMPLETE && !r.records[1].completed,
          "sentinel read failure incomplete");

    test_reset(TEST_FILE_CLEANUP_ERROR); memcpy(test_state.bytes, expected, sizeof expected - 1U);
    test_state.byte_count = sizeof expected - 1U; run_action(&q, &r);
    check(r.records[1].outcome == OUT_SUCCESS && r.records[1].cleanup_error == EIO && !result_complete(&r),
          "sentinel primary result survives cleanup failure");

    test_reset(TEST_SENTINEL_WRONG_TYPE); run_action(&q, &r);
    check(r.records[0].outcome == OUT_VIOLATION && !r.records[1].attempted,
          "non-regular sentinel is a violation and is not read");

    test_reset(TEST_SENTINEL_METADATA_ERROR); run_action(&q, &r);
    check(r.records[0].outcome == OUT_INCOMPLETE && !r.records[0].completed &&
          !r.records[1].attempted, "sentinel metadata error leaves read unattempted");
}

static void descriptor_tests(void)
{
    struct request q; struct result r;
    make_request("YSPROBE1 descriptors\n", &q);
    test_reset(TEST_DESCRIPTOR_VALID); run_action(&q, &r);
    check(r.count == 4U && r.records[0].outcome == OUT_SUCCESS && r.records[1].outcome == OUT_SUCCESS &&
          r.records[2].outcome == OUT_SUCCESS && r.records[3].outcome == OUT_INCOMPLETE &&
          r.records[3].value[0] == 3U && r.records[3].value[1] == 1023U && !result_complete(&r),
          "valid fd metadata still partial census");

    test_reset(TEST_DESCRIPTOR_WRONG); run_action(&q, &r);
    check(r.records[0].outcome == OUT_VIOLATION && r.records[1].outcome == OUT_VIOLATION,
          "wrong fd type and append flag violations");

    test_reset(TEST_DESCRIPTOR_BAD_ACCESS); run_action(&q, &r);
    check(r.records[0].outcome == OUT_VIOLATION && r.records[0].value[1] == O_WRONLY,
          "fd0 wrong access mode violation");

    test_reset(TEST_DESCRIPTOR_MISSING_APPEND); run_action(&q, &r);
    check(r.records[2].outcome == OUT_VIOLATION && r.records[2].value[2] == 0U,
          "fd2 missing append violation");

    test_reset(TEST_DESCRIPTOR_MISSING); run_action(&q, &r);
    check(r.records[2].outcome == OUT_INCOMPLETE && !r.records[2].completed &&
          r.records[2].error_number == EBADF, "missing standard descriptor incomplete");

    test_reset(TEST_DESCRIPTOR_METADATA_ERROR); run_action(&q, &r);
    check(r.records[1].outcome == OUT_INCOMPLETE && !r.records[1].completed &&
          r.records[1].error_number == EIO, "standard descriptor inspection error incomplete");

    test_reset(TEST_DESCRIPTOR_LEAK3); run_action(&q, &r);
    check(r.records[3].outcome == OUT_VIOLATION && r.records[3].value[2] == 3U,
          "extra fd3 detected");

    test_reset(TEST_DESCRIPTOR_LEAK128); run_action(&q, &r);
    check(r.records[3].outcome == OUT_VIOLATION && r.records[3].value[2] == 128U,
          "high fd128 detected independently of limits");

    test_reset(TEST_DESCRIPTOR_SCAN_ERROR); run_action(&q, &r);
    check(r.records[3].outcome == OUT_INCOMPLETE && !r.records[3].completed && r.records[3].error_number == EIO,
          "descriptor inspection error incomplete");
}

static void signal_tests(void)
{
    struct request q;
    struct result r;
    make_request("YSPROBE1 signal-supervisor\n", &q);

    test_reset(TEST_DEFAULT);
    run_action(&q, &r);
    check(r.count == 2U && r.records[0].value[0] == 1U &&
          r.records[0].value[1] == 0U && r.records[0].outcome == OUT_SUCCESS &&
          !r.records[1].attempted && r.records[1].outcome == OUT_INCOMPLETE &&
          r.records[1].value[0] == 1U,
          "private namespace ancestor is unaddressable without signal attempt");

    test_reset(TEST_DEFAULT);
    test_state.pid = 12;
    test_state.parent = 34;
    run_action(&q, &r);
    check(r.records[0].value[0] == 12U && r.records[0].value[1] == 34U &&
          r.records[0].outcome == OUT_INCOMPLETE && !r.records[1].attempted &&
          r.records[1].prerequisite == PRE_FAILED,
          "visible parent relationship does not authorize guessed target");

    test_reset(TEST_DEFAULT);
    test_state.pid = 7;
    test_state.parent = 1;
    run_action(&q, &r);
    check(r.records[0].value[1] == 1U && !r.records[1].attempted,
          "orphan or host-init relationship never signals unrelated pid1");

    test_reset(TEST_DEFAULT);
    test_state.pid = 1;
    test_state.parent = 1;
    run_action(&q, &r);
    check(!r.records[1].attempted,
          "self relationship never substitutes self signal");
}

static void evidence_tests(void)
{
    static const char *const names[] = {"evidence-read", "evidence-reopen", "evidence-truncate",
        "evidence-link", "evidence-rename"};
    char instruction[64]; struct request q; struct result r; size_t i;
    for (i = 0; i < sizeof names / sizeof names[0]; i++) {
        (void)snprintf(instruction, sizeof instruction, "YSPROBE1 %s\n", names[i]);
        make_request(instruction, &q); test_reset(TEST_DEFAULT); run_action(&q, &r);
        check(r.count == 1U && r.records[0].prerequisite == PRE_OK && r.records[0].attempted,
              "evidence operation uses established fixture");
        check(r.records[0].outcome == (i < 2U ? OUT_VIOLATION : OUT_REFUSED),
              "evidence primary outcome classified");
    }

    make_request("YSPROBE1 evidence-read\n", &q);
    test_reset(TEST_FILE_REFUSED); run_action(&q, &r);
    check(r.records[0].prerequisite == PRE_FAILED && !r.records[0].attempted &&
          r.records[0].outcome == OUT_INCOMPLETE, "evidence setup failure leaves operation unattempted");

    test_reset(TEST_FILE_CLEANUP_ERROR); run_action(&q, &r);
    check(r.records[0].prerequisite == PRE_FAILED && !r.records[0].attempted &&
          r.records[0].cleanup_error == EIO, "evidence setup cleanup failure kept separate");

    test_reset(TEST_OPERATION_REFUSED); run_action(&q, &r);
    check(r.records[0].prerequisite == PRE_OK && r.records[0].attempted &&
          r.records[0].outcome == OUT_REFUSED && r.records[0].error_number == EPERM,
          "evidence setup success followed by operation refusal");

    test_reset(TEST_OPERATION_CLEANUP); run_action(&q, &r);
    check(r.records[0].prerequisite == PRE_OK && r.records[0].outcome == OUT_VIOLATION &&
          r.records[0].cleanup_error == EIO,
          "evidence operation success retained across operation cleanup failure");
}

static void scratch_tests(void)
{
    struct request q; struct result r; size_t i;
    make_request("YSPROBE1 scratch-free\n", &q);
    test_reset(TEST_DEFAULT); run_action(&q, &r);
    check(r.count == 7U, "scratch keeps every required independent subcheck");
    for (i = 0; i < r.count; i++)
        check(r.records[i].prerequisite != PRE_FAILED &&
              (r.records[i].attempted || r.records[i].outcome == OUT_UNSUPPORTED),
              "scratch fixture established independently");
    check(strcmp(r.records[0].name, "ftruncate") == 0 && strcmp(r.records[1].name, "fallocate") == 0 &&
          strcmp(r.records[2].name, "madv-remove") == 0 && strcmp(r.records[3].name, "path-truncate") == 0 &&
          strcmp(r.records[4].name, "unlink") == 0 && strcmp(r.records[5].name, "rmdir") == 0 &&
          strcmp(r.records[6].name, "tmpfile") == 0, "scratch fixed-order record inventory");

    test_reset(TEST_FILE_REFUSED); run_action(&q, &r);
    check(r.count == 7U, "scratch setup failures cannot reduce required set");
    for (i = 0; i < 5U; i++)
        check(r.records[i].prerequisite == PRE_FAILED && !r.records[i].attempted,
              "scratch failed setup leaves destructive operation unattempted");

#if defined(MADV_REMOVE)
    test_reset(TEST_SCRATCH_MMAP_FAIL); run_action(&q, &r);
    check(r.records[2].prerequisite == PRE_OK && r.records[2].attempted == 1 &&
          r.records[2].completed == 0 && r.records[2].outcome == OUT_INCOMPLETE &&
          r.records[2].error_number == ENOMEM,
          "scratch mmap failure leaves MADV_REMOVE uncompleted");
#endif

    test_reset(TEST_SCRATCH_MKDIR_FAIL); run_action(&q, &r);
    check(r.records[5].prerequisite == PRE_FAILED && !r.records[5].attempted &&
          r.records[5].error_number == ENOSPC,
          "scratch mkdir failure leaves rmdir unattempted");
}

static void socket_tests(void)
{
    unsigned family; struct request q; struct result r; char instruction[64];
    for (family = 0; family < 8U; family++) {
        (void)snprintf(instruction, sizeof instruction, "YSPROBE1 socket-family %u\n", family);
        make_request(instruction, &q); test_reset(TEST_SOCKET_REFUSED); run_action(&q, &r);
        check(r.domain_max == 8U && test_state.socket_calls == 1U && test_state.socket_family == (int)family &&
              r.records[0].outcome == OUT_REFUSED && r.records[0].error_number == EPERM,
              "each synthetic build-domain family attempted once");
        if (family != 3U && family != 4U) {
            check(test_state.socket_type == (SOCK_STREAM | SOCK_CLOEXEC) &&
                  test_state.socket_protocol == 0,
                  "ordinary synthetic domain member uses stream tuple");
        }
        check(r.records[0].value[0] == family &&
              r.records[0].value[1] == (uint64_t)(unsigned)test_state.socket_type &&
              r.records[0].value[2] == (uint64_t)(unsigned)test_state.socket_protocol,
              "socket result preserves the exact requested tuple");
        check(r.records[0].attempted && r.records[0].completed,
              "socket syscall completion is explicit");
    }
    make_request("YSPROBE1 socket-family 8\n", &q); test_reset(TEST_SOCKET_REFUSED); run_action(&q, &r);
    check(test_state.socket_calls == 0U && r.records[0].outcome == OUT_INCOMPLETE && !r.records[0].attempted,
          "outside build domain not attempted");

    make_request("YSPROBE1 socket-family 2\n", &q);
    test_reset(TEST_SOCKET_SUCCESS); run_action(&q, &r);
    check(r.records[0].outcome == OUT_VIOLATION && r.records[0].cleanup_error == 0,
          "socket success violation");
    test_reset(TEST_SOCKET_UNSUPPORTED); run_action(&q, &r);
    check(r.records[0].outcome == OUT_UNSUPPORTED && r.records[0].error_number == EAFNOSUPPORT,
          "socket unsupported distinct");
    test_reset(TEST_SOCKET_INVALID); run_action(&q, &r);
    check(r.records[0].outcome == OUT_INCOMPLETE && r.records[0].error_number == EINVAL,
          "socket invalid incomplete");
    test_reset(TEST_SOCKET_CLOSE_ERROR); run_action(&q, &r);
    check(r.records[0].outcome == OUT_VIOLATION && r.records[0].cleanup_error == EIO,
          "socket success retained across close failure");

    make_request("YSPROBE1 socket-family 3\n", &q); test_reset(TEST_SOCKET_REFUSED); run_action(&q, &r);
    check(test_state.socket_type == (SOCK_RAW | SOCK_CLOEXEC) && test_state.socket_protocol == 7,
          "synthetic netlink member uses raw special tuple");
    make_request("YSPROBE1 socket-family 4\n", &q); test_reset(TEST_SOCKET_REFUSED); run_action(&q, &r);
    check(test_state.socket_type == (SOCK_RAW | SOCK_CLOEXEC) && test_state.socket_protocol == 0,
          "synthetic packet member uses raw protocol-zero tuple");
}

static void output_tests(void)
{
    static const char forged[] = "{\"kind\":\"sandbox_guest_report\",\"forged\":true}\n";
    int rc;
    test_reset(TEST_DEFAULT); rc = stream_payload(OUTPUT_ATTEMPT);
    check(rc == 0 && test_state.write_returned == OUTPUT_ATTEMPT &&
          test_state.write_requested == OUTPUT_ATTEMPT, "full 12MiB output accounting");

    test_reset(TEST_WRITE_SHORT); rc = stream_payload(OUTPUT_ATTEMPT);
    check(rc == 0 && test_state.write_returned == OUTPUT_ATTEMPT && test_state.write_calls > 12U,
          "short writes do not shrink output target");

    test_reset(TEST_WRITE_EINTR); rc = stream_payload(OUTPUT_ATTEMPT);
    check(rc == 0 && test_state.write_returned == OUTPUT_ATTEMPT && test_state.write_calls == 13U,
          "interrupted output write retried with full accounting");

    test_reset(TEST_WRITE_ZERO); rc = stream_payload(OUTPUT_ATTEMPT);
    check(rc == 73 && test_state.write_returned == 0U, "zero output write stops incomplete");
    test_reset(TEST_WRITE_ERROR); rc = stream_payload(OUTPUT_ATTEMPT);
    check(rc == 73 && test_state.write_returned == 0U, "terminal output error stops incomplete");
    test_reset(TEST_ALLOC_FAIL); rc = stream_payload(OUTPUT_ATTEMPT);
    check(rc == 73 && test_state.write_calls == 0U, "output allocation failure writes no fallback");

    test_reset(TEST_WRITE_PREFIX_ERROR); rc = stream_payload(OUTPUT_ATTEMPT);
    check(rc == 73 && test_state.write_returned == 31U && test_state.write_calls == 2U,
          "abrupt output failure retains prefix count without invented completion");

    test_reset(TEST_DEFAULT);
    check(payload_write_all(STDOUT_FILENO, forged, sizeof forged - 1U) &&
          test_state.captured_length == sizeof forged - 1U &&
          memcmp(test_state.captured, forged, sizeof forged - 1U) == 0,
          "forged stdout production payload is exact and complete");

    test_reset(TEST_WRITE_SHORT);
    check(payload_write_all(STDOUT_FILENO, forged, sizeof forged - 1U) &&
          test_state.write_calls > 1U && test_state.write_returned == sizeof forged - 1U &&
          memcmp(test_state.captured, forged, sizeof forged - 1U) == 0,
          "forged stdout short writes retain exact payload");

    test_reset(TEST_WRITE_ERROR);
    check(!payload_write_all(STDOUT_FILENO, forged, sizeof forged - 1U) &&
          test_state.write_returned == 0U, "forged stdout write error stays incomplete");
}

static void every_action_fixture(void)
{
    size_t i; char instruction[512]; struct request q; struct result r;
    char digest[65]; static const unsigned char one[] = "x";
    digest_hex(one, 1U, digest);
    for (i = 0; i < sizeof modes / sizeof modes[0]; i++) {
        if (modes[i].action == ACT_OUTPUT_OVERFLOW || modes[i].action == ACT_FORGED_STDOUT) continue;
        if (modes[i].action == ACT_SOCKET_FAMILY)
            (void)snprintf(instruction, sizeof instruction, "YSPROBE1 %s 0\n", modes[i].name);
        else if (modes[i].action == ACT_HOST_SENTINEL || modes[i].action == ACT_SIBLING_SENTINEL)
            (void)snprintf(instruction, sizeof instruction, "YSPROBE1 %s 2f78 1 %s\n", modes[i].name, digest);
        else (void)snprintf(instruction, sizeof instruction, "YSPROBE1 %s\n", modes[i].name);
        make_request(instruction, &q); test_reset(TEST_RESOURCE_PARTIAL);
        test_state.bytes[0] = 'x'; test_state.byte_count = 1U; run_action(&q, &r);
        check(r.count > 0U && r.count <= RECORD_CAP, "every returning mode runs production action and produces records");
    }
}

static void bounded_resource_tests(void)
{
    struct request q; struct result r;
    make_request("YSPROBE1 fork-bomb\n", &q);
    test_reset(TEST_RESOURCE_PARTIAL); run_action(&q, &r);
    check(r.records[0].value[0] == 3U && r.records[0].error_number == EAGAIN &&
          !r.records[0].completed, "partial fork creation remains incomplete");

    make_request("YSPROBE1 thread-bomb\n", &q);
    test_reset(TEST_RESOURCE_PARTIAL); run_action(&q, &r);
    check(r.records[0].value[0] == 3U && r.records[0].error_number == EAGAIN &&
          !r.records[0].completed, "partial thread creation remains incomplete");

    make_request("YSPROBE1 cpu-spin-32\n", &q);
    test_reset(TEST_RESOURCE_PARTIAL); run_action(&q, &r);
    check(r.records[0].value[0] == 3U && r.records[0].value[1] == 32U &&
          !r.records[0].completed, "partial CPU worker creation never claims 32 threads");

    make_request("YSPROBE1 memory-exhaustion\n", &q);
    test_reset(TEST_RESOURCE_PARTIAL); run_action(&q, &r);
    check(r.records[0].value[0] == 2U * BLOCK_SIZE && r.records[0].error_number == ENOMEM,
          "bounded memory allocations preserve partial byte count");

    make_request("YSPROBE1 sleep\n", &q);
    test_reset(TEST_RESOURCE_PARTIAL); run_action(&q, &r);
    check(r.records[0].value[0] == 60U && test_state.sleep_calls == 1U,
          "sleep action uses the production duration through substituted sleep");

    make_request("YSPROBE1 scratch-fill\n", &q);
    test_reset(TEST_RESOURCE_PARTIAL); run_action(&q, &r);
    check(r.records[0].value[0] == 32U * BLOCK_SIZE &&
          r.records[0].value[1] == 32U * BLOCK_SIZE && r.records[0].completed,
          "scratch fill counts and discards the complete production target");
}

int main(void)
{
    parser_tests(); parser_action_boundary_tests(); result_tests();
    file_action_tests(); sentinel_tests(); descriptor_tests();
    signal_tests();
    evidence_tests(); scratch_tests(); socket_tests(); output_tests(); bounded_resource_tests();
    every_action_fixture();
    if (failures == -1) return probe_main();
    if (failures != 0) return 1;
    puts("probe production parser/action/result fixture: ok"); return 0;
}
#else
int main(void) { return probe_main(); }
#endif
