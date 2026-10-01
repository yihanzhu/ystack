#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif

/*
 * Test-only driver for sandbox/v1/guest/common.c (ystack #463, PRs 1-2).
 * See scripts/test/sandbox-guest.test.sh, work/vm-launcher-supervisor/
 * plan.md ("PR 1", "PR 2"). Not built or run in production.
 *
 * usage:
 *   sandbox-guest-harness frame-write <out> [<name>=<file> ...]
 *   sandbox-guest-harness frame-read <in> <dir> [input|export] [--capacity=N]
 *   sandbox-guest-harness digest <file>
 *   sandbox-guest-harness path-ok <file>
 *   sandbox-guest-harness plan <plan.json>
 *   sandbox-guest-harness materialize <plan.json> <candidate-dir> <out-dir> <uid> <gid>
 *   sandbox-guest-harness inventory <dir>
 *   sandbox-guest-harness exec-report <self-path> <instruction> <stdout-file> <stderr-file>
 *   sandbox-guest-harness verify ...  (R6.4 wiring reporter; not for direct use)
 */

#include "../../sandbox/v1/guest/common.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static void die(const char *code) { (void)fprintf(stderr, "%s\n", code); exit(1); }
static void usage(void) { (void)fprintf(stderr, "E_USAGE\n"); exit(2); }

static unsigned char *read_whole_file(const char *path, size_t *len_out)
{
    int fd = open(path, O_RDONLY);
    struct stat st;
    unsigned char *buf;
    size_t total = 0;
    if (fd < 0) die("E_FRAME_IO");
    if (fstat(fd, &st) != 0 || st.st_size < 0) die("E_FRAME_IO");
    buf = malloc((size_t)st.st_size + 1U);
    if (buf == NULL) die("E_FRAME_IO");
    while (total < (size_t)st.st_size) {
        ssize_t n = read(fd, buf + total, (size_t)st.st_size - total);
        if (n < 0) { if (errno == EINTR) continue; die("E_FRAME_IO"); }
        if (n == 0) break;
        total += (size_t)n;
    }
    (void)close(fd);
    *len_out = total;
    return buf;
}

static int cmd_frame_write(int argc, char **argv)
{
    int fd = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, 0644);
    struct ys_frame_writer w;
    int i;
    if (argc < 3) usage();
    if (fd < 0) die("E_FRAME_IO");
    if (!ys_frame_writer_open(&w, fd)) die("E_FRAME_IO");
    for (i = 3; i < argc; i++) {
        char *eq = strchr(argv[i], '=');
        unsigned char *content;
        size_t content_len = 0;
        enum ys_frame_status status;
        if (eq == NULL) { (void)close(fd); usage(); }
        content = read_whole_file(eq + 1, &content_len);
        status = ys_frame_writer_put(&w, argv[i], (size_t)(eq - argv[i]), content, content_len);
        free(content);
        if (status != YS_FRAME_OK) { (void)close(fd); die(ys_frame_status_str(status)); }
    }
    if (ys_frame_writer_close(&w) != YS_FRAME_OK) { (void)close(fd); die("E_FRAME_IO"); }
    if (close(fd) != 0) die("E_FRAME_IO");
    return 0;
}

/* Creates every missing directory component of "<dir>/<name>"'s dirname
 * (not the file itself), so nested indexed names (e.g. "candidate/00000")
 * need no preceding explicit "candidate/" entry. */
static void mkdir_parents(const char *dir, const char *name, char *full, size_t full_cap)
{
    size_t i;
    int n = snprintf(full, full_cap, "%s/%s", dir, name);
    if (n < 0 || (size_t)n >= full_cap) die("E_FRAME_IO");
    for (i = strlen(dir) + 1U; full[i] != '\0'; i++) {
        if (full[i] == '/') {
            full[i] = '\0';
            if (mkdir(full, 0755) != 0 && errno != EEXIST) die("E_FRAME_IO");
            full[i] = '/';
        }
    }
}

static void write_record_file(const char *dir, const struct ys_frame_record *rec)
{
    char full[4096];
    int fd;
    size_t written = 0;
    mkdir_parents(dir, rec->name, full, sizeof full);
    fd = open(full, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0) die("E_FRAME_IO");
    while (written < rec->length) {
        ssize_t r = write(fd, rec->content + written, (size_t)rec->length - written);
        if (r < 0) { if (errno == EINTR) continue; (void)close(fd); die("E_FRAME_IO"); }
        written += (size_t)r;
    }
    if (close(fd) != 0) die("E_FRAME_IO");
}

/* frame-read <in> <dir> [input|export] [--capacity=N]: --capacity overrides
 * ys_frame_descriptor_capacity's auto-detected size (proves the reader
 * trusts the given capacity, not a regular file's real st_size). */
static int cmd_frame_read(int argc, char **argv)
{
    int fd, i, have_set = 0, have_cap = 0;
    struct ys_frame_reader r;
    struct ys_record_set_state set_state;
    enum ys_frame_status status;
    off_t capacity = 0;

    if (argc < 4) usage();
    for (i = 4; i < argc; i++) {
        if (strcmp(argv[i], "input") == 0) { ys_record_set_init(&set_state, YS_RECORD_SET_INPUT); have_set = 1; }
        else if (strcmp(argv[i], "export") == 0) { ys_record_set_init(&set_state, YS_RECORD_SET_EXPORT); have_set = 1; }
        else if (strncmp(argv[i], "--capacity=", 11U) == 0) { capacity = (off_t)strtoll(argv[i] + 11, NULL, 10); have_cap = 1; }
        else usage();
    }

    fd = open(argv[2], O_RDONLY);
    if (fd < 0) die("E_FRAME_IO");
    if (!have_cap) {
        status = ys_frame_descriptor_capacity(fd, &capacity);
        if (status != YS_FRAME_OK) die(ys_frame_status_str(status));
    }
    status = ys_frame_reader_open(&r, fd, capacity);
    if (status != YS_FRAME_OK) die(ys_frame_status_str(status));
    if (mkdir(argv[3], 0755) != 0) die("E_FRAME_IO");

    for (;;) {
        struct ys_frame_record record;
        status = ys_frame_reader_next(&r, &record);
        if (status != YS_FRAME_OK) die(ys_frame_status_str(status));
        if (record.is_end) {
            if (have_set) {
                status = ys_record_set_finish(&set_state);
                if (status != YS_FRAME_OK) die(ys_frame_status_str(status));
            }
            break;
        }
        if (have_set) {
            uint32_t index;
            status = ys_record_set_advance(&set_state, record.name, record.name_len, &index);
            if (status != YS_FRAME_OK) { free(record.content); die(ys_frame_status_str(status)); }
        }
        write_record_file(argv[3], &record);
        free(record.content);
    }
    (void)close(fd);
    return 0;
}

static int cmd_digest(int argc, char **argv)
{
    unsigned char *buf, digest[32];
    size_t len;
    char hex[65];
    if (argc != 3) usage();
    buf = read_whole_file(argv[2], &len);
    ys_sha256_bytes(buf, len, digest);
    free(buf);
    ys_hex_encode(digest, sizeof digest, hex);
    (void)printf("%s\n", hex);
    return 0;
}

/* path-ok <file>: ys_path_range_ok on the file's raw bytes as one path. */
static int cmd_path_ok(int argc, char **argv)
{
    unsigned char *buf;
    size_t len;
    int ok;
    if (argc != 3) usage();
    buf = read_whole_file(argv[2], &len);
    ok = ys_path_range_ok(buf, len);
    free(buf);
    if (!ok) die("E_PATH_REJECTED");
    return 0;
}

/* plan <plan.json>: parses per R5.2; prints the entry count on success. */
static int cmd_plan(int argc, char **argv)
{
    unsigned char *buf;
    size_t len;
    struct ys_guest_plan plan;
    enum ys_plan_status status;
    if (argc != 3) usage();
    buf = read_whole_file(argv[2], &len);
    status = ys_plan_parse(buf, len, &plan);
    free(buf);
    if (status != YS_PLAN_OK) die(ys_plan_status_str(status));
    (void)printf("%zu\n", plan.entry_count);
    ys_plan_free(&plan);
    return 0;
}

/* materialize <plan.json> <candidate-dir> <out-dir> <uid> <gid>:
 * <candidate-dir> holds "candidate/%05zu" files (a frame-read input-set
 * extraction); <out-dir> must not already exist. */
static int cmd_materialize(int argc, char **argv)
{
    unsigned char *buf;
    size_t len, i, file_count = 0, fi = 0;
    struct ys_guest_plan plan;
    enum ys_plan_status status;
    unsigned char **contents;
    size_t *lengths;
    int outfd;
    uid_t uid;
    gid_t gid;
    if (argc != 7) usage();
    buf = read_whole_file(argv[2], &len);
    status = ys_plan_parse(buf, len, &plan);
    free(buf);
    if (status != YS_PLAN_OK) die(ys_plan_status_str(status));
    for (i = 0; i < plan.entry_count; i++)
        if (plan.entries[i].is_file) file_count++;
    contents = malloc((file_count == 0U ? 1U : file_count) * sizeof *contents);
    lengths = malloc((file_count == 0U ? 1U : file_count) * sizeof *lengths);
    if (contents == NULL || lengths == NULL) die("E_FRAME_IO");
    for (i = 0; i < plan.entry_count; i++) {
        char path[512];
        if (!plan.entries[i].is_file) continue;
        (void)snprintf(path, sizeof path, "%s/candidate/%05zu", argv[3], fi);
        contents[fi] = read_whole_file(path, &lengths[fi]);
        fi++;
    }
    uid = (uid_t)strtoul(argv[5], NULL, 10);
    gid = (gid_t)strtoul(argv[6], NULL, 10);
    if (mkdir(argv[4], 0700) != 0) die("E_FRAME_IO");
    outfd = open(argv[4], O_RDONLY | O_DIRECTORY);
    if (outfd < 0) die("E_FRAME_IO");
    status = ys_plan_materialize(outfd, uid, gid, &plan,
                                  (const unsigned char *const *)contents, lengths);
    if (status != YS_PLAN_OK) die(ys_plan_status_str(status));
    return 0;
}

/* inventory <dir> [fail-at-N]: R8.1 export inventory; prints each evidence
 * file's name on its own line, in the frame's evidence/<nnnn> order.
 * fail-at-N is only meaningful in a -DYSTACK_TEST_FAULT_INJECT build: it
 * makes the Nth readdir() call inside ys_evidence_inventory fail. */
static int cmd_inventory(int argc, char **argv)
{
    int fd;
    char **names;
    size_t count, i;
    enum ys_plan_status status;
    if (argc != 3 && argc != 4) usage();
#ifdef YSTACK_TEST_FAULT_INJECT
    ys_test_readdir_fail_at = (argc == 4) ? (size_t)strtoul(argv[3], NULL, 10) : 0U;
#else
    if (argc == 4) usage();
#endif
    fd = open(argv[2], O_RDONLY | O_DIRECTORY);
    if (fd < 0) die("E_FRAME_IO");
    status = ys_evidence_inventory(fd, &names, &count);
    if (status != YS_PLAN_OK) die(ys_plan_status_str(status));
    for (i = 0; i < count; i++) { (void)printf("%s\n", names[i]); free(names[i]); }
    free(names);
    return 0;
}

/* exec-report <self-path> <instruction> <stdout-file> <stderr-file>
 * [overlap|lowlimit|closefail]: forks, calls ys_exec with R6.4's fixed
 * argv (argv[0] = <self-path>, so the child re-enters this binary as
 * "verify ..." and reports what it received); the parent leaves one extra
 * fd open so the child's "every other descriptor closed" check is
 * non-vacuous. "overlap": forces stdout_fd to literally be fd 0 (the
 * instruction's own destination) first, reproducing a caller-supplied
 * overlap. "lowlimit": forces the marker fd to 128, then lowers the soft
 * RLIMIT_NOFILE to 64 (hard limit untouched), reproducing a descriptor a
 * limit-bounded sweep would miss. "closefail" (fault-injection build
 * only): makes ys_exec's own enumeration fail, so this expects the child
 * to exit 126 (refused, execve never reached), not 0. */
static int cmd_exec_report(int argc, char **argv)
{
    int instruction_fd, stdout_fd, stderr_fd, marker_fd, status;
    int want_refusal = 0;
    pid_t pid;
    const char *report_argv[7];
    if (argc != 6 && argc != 7) usage();
    if (argc == 7 && strcmp(argv[6], "overlap") != 0 && strcmp(argv[6], "lowlimit") != 0 &&
        strcmp(argv[6], "closefail") != 0) usage();
    instruction_fd = open(argv[3], O_RDONLY);
    stdout_fd = open(argv[4], O_WRONLY | O_CREAT | O_APPEND, 0600);
    stderr_fd = open(argv[5], O_WRONLY | O_CREAT | O_APPEND, 0600);
    marker_fd = open("/dev/null", O_RDONLY);
    if (instruction_fd < 0 || stdout_fd < 0 || stderr_fd < 0 || marker_fd < 0) die("E_FRAME_IO");
    if (argc == 7 && strcmp(argv[6], "overlap") == 0) {
        if (dup2(stdout_fd, 0) < 0) die("E_FRAME_IO");
        (void)close(stdout_fd);
        stdout_fd = 0;
    }
    if (argc == 7 && strcmp(argv[6], "lowlimit") == 0) {
        struct rlimit rl;
        if (dup2(marker_fd, 128) < 0) die("E_FRAME_IO");
        (void)close(marker_fd);
        marker_fd = 128;
        if (getrlimit(RLIMIT_NOFILE, &rl) != 0) die("E_FRAME_IO");
        rl.rlim_cur = 64;
        if (setrlimit(RLIMIT_NOFILE, &rl) != 0) die("E_FRAME_IO");
    }
    if (argc == 7 && strcmp(argv[6], "closefail") == 0) {
#ifdef YSTACK_TEST_FAULT_INJECT
        ys_test_close_all_fail = 1;
        want_refusal = 1;
#else
        die("E_USAGE"); /* only meaningful in the -DYSTACK_TEST_FAULT_INJECT build */
#endif
    }
    report_argv[0] = argv[2];
    report_argv[1] = YS_PLAN_ARGV[1]; report_argv[2] = YS_PLAN_ARGV[2];
    report_argv[3] = YS_PLAN_ARGV[3]; report_argv[4] = YS_PLAN_ARGV[4];
    report_argv[5] = YS_PLAN_ARGV[5]; report_argv[6] = NULL;
    pid = fork();
    if (pid < 0) die("E_FRAME_IO");
    if (pid == 0) {
        ys_exec(report_argv, YS_PLAN_ENVIRONMENT, instruction_fd, stdout_fd, stderr_fd);
        _exit(127);
    }
    (void)close(instruction_fd); (void)close(stdout_fd); (void)close(stderr_fd); (void)close(marker_fd);
    if (waitpid(pid, &status, 0) < 0 || !WIFEXITED(status)) die("E_FRAME_IO");
    if (want_refusal) {
        if (WEXITSTATUS(status) != 126) die("E_FRAME_IO");
    } else if (WEXITSTATUS(status) != 0) {
        die("E_FRAME_IO");
    }
    return 0;
}

/* Every open descriptor >= 3, via ys_walk_fds (the same exhaustive
 * enumeration ys_exec's own Darwin close path uses): -1 if the walk could
 * not be confirmed complete, so the caller never reports a clean "0" for
 * an enumeration that actually failed (fail closed). */
static void count_visitor(int fd, void *ctx) { (void)fd; (*(int *)ctx)++; }

static int count_extra_fds(void)
{
    int count = 0;
    return ys_walk_fds(3, count_visitor, &count) ? count : -1;
}

/* The R6.4 wiring reporter: entered only via ys_exec from cmd_exec_report
 * (argv[1] is then literally "verify", R6.4's own first argument), so
 * reaching here with that exact argv is itself part of the proof. Writes
 * one line per check to fd 1 (the wired, append-only stdout capture). */
static int cmd_verify_report(int argc, char **argv)
{
    int argv_ok = (argc == 6 && strcmp(argv[2], YS_PLAN_ARGV[2]) == 0 &&
                   strcmp(argv[3], YS_PLAN_ARGV[3]) == 0 && strcmp(argv[4], YS_PLAN_ARGV[4]) == 0 &&
                   strcmp(argv[5], YS_PLAN_ARGV[5]) == 0);
    int env_ok, fd0_ok, fd1_ok, fd2_ok, extra, fl1, fl2;
    struct stat st;
    char **e;
    int count = 0, i;

    for (e = environ; *e != NULL; e++) count++;
    env_ok = (count == 4);
    for (i = 0; env_ok && i < 4; i++) {
        int seen = 0, j;
        for (j = 0; environ[j] != NULL; j++)
            if (strcmp(environ[j], YS_PLAN_ENVIRONMENT[i]) == 0) { seen = 1; break; }
        if (!seen) env_ok = 0;
    }
    fd0_ok = (fstat(0, &st) == 0 && S_ISREG(st.st_mode) && lseek(0, 0, SEEK_CUR) == 0);
    fl1 = fcntl(1, F_GETFL); fl2 = fcntl(2, F_GETFL);
    fd1_ok = (fl1 >= 0 && (fl1 & O_ACCMODE) == O_WRONLY && (fl1 & O_APPEND) != 0);
    fd2_ok = (fl2 >= 0 && (fl2 & O_ACCMODE) == O_WRONLY && (fl2 & O_APPEND) != 0);
    extra = count_extra_fds();

    (void)dprintf(1, "argv:%s\n", argv_ok ? "ok" : "fail");
    (void)dprintf(1, "env:%s\n", env_ok ? "ok" : "fail");
    (void)dprintf(1, "fd0:%s\n", fd0_ok ? "ok" : "fail");
    (void)dprintf(1, "fd1:%s\n", fd1_ok ? "ok" : "fail");
    (void)dprintf(1, "fd2:%s\n", fd2_ok ? "ok" : "fail");
    if (extra < 0) (void)dprintf(1, "extra_fds:enum-failed\n");
    else (void)dprintf(1, "extra_fds:%d\n", extra);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) usage();
    if (strcmp(argv[1], "frame-write") == 0) return cmd_frame_write(argc, argv);
    if (strcmp(argv[1], "frame-read") == 0) return cmd_frame_read(argc, argv);
    if (strcmp(argv[1], "digest") == 0) return cmd_digest(argc, argv);
    if (strcmp(argv[1], "path-ok") == 0) return cmd_path_ok(argc, argv);
    if (strcmp(argv[1], "plan") == 0) return cmd_plan(argc, argv);
    if (strcmp(argv[1], "materialize") == 0) return cmd_materialize(argc, argv);
    if (strcmp(argv[1], "inventory") == 0) return cmd_inventory(argc, argv);
    if (strcmp(argv[1], "exec-report") == 0) return cmd_exec_report(argc, argv);
    if (strcmp(argv[1], "verify") == 0) return cmd_verify_report(argc, argv);
    usage();
    return 2;
}
