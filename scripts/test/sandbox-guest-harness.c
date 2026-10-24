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
#include "../../sandbox/v1/guest/observation-values.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
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
    int instruction_fd, stdout_fd, stderr_fd, marker_fd, status, outcome_pipe[2];
    struct ys_exec_outcome outcomes[2];
    ssize_t outcome_bytes;
    int want_refusal = 0, expected_exit = 0, want_exec_failure = 0, want_report_failure = 0;
    int want_pre_exec_death = 0, want_post_ready_death = 0;
    pid_t pid;
    const char *report_argv[7];
    if (argc != 6 && argc != 7) usage();
    if (argc == 7 && strcmp(argv[6], "overlap") != 0 && strcmp(argv[6], "lowlimit") != 0 &&
        strcmp(argv[6], "closefail") != 0 && strcmp(argv[6], "exit126") != 0 &&
        strcmp(argv[6], "exit127") != 0 && strcmp(argv[6], "execfail") != 0 &&
        strcmp(argv[6], "eintr") != 0 && strcmp(argv[6], "reportfail") != 0 &&
        strcmp(argv[6], "predeath") != 0 && strcmp(argv[6], "afterreadydeath") != 0) usage();
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
    if (argc == 7 && strcmp(argv[6], "exit126") == 0) expected_exit = 126;
    if (argc == 7 && strcmp(argv[6], "exit127") == 0) expected_exit = 127;
    if (argc == 7 && strcmp(argv[6], "execfail") == 0) want_exec_failure = 1;
    if (argc == 7 && strcmp(argv[6], "predeath") == 0) want_pre_exec_death = 1;
    if (argc == 7 && strcmp(argv[6], "afterreadydeath") == 0) want_post_ready_death = 1;
#ifdef YSTACK_TEST_FAULT_INJECT
    if (argc == 7 && strcmp(argv[6], "eintr") == 0) ys_test_outcome_write_mode = 1;
    if (argc == 7 && strcmp(argv[6], "reportfail") == 0) {
        ys_test_close_all_fail = 1;
        ys_test_outcome_write_mode = 2;
        want_report_failure = 1;
    }
#endif
    report_argv[0] = want_exec_failure ? "/definitely/missing/ystack-verifier" : argv[2];
    report_argv[1] = YS_PLAN_ARGV[1]; report_argv[2] = YS_PLAN_ARGV[2];
    report_argv[3] = YS_PLAN_ARGV[3]; report_argv[4] = YS_PLAN_ARGV[4];
    report_argv[5] = YS_PLAN_ARGV[5]; report_argv[6] = NULL;
    if (pipe(outcome_pipe) != 0) die("E_FRAME_IO");
    pid = fork();
    if (pid < 0) die("E_FRAME_IO");
    if (pid == 0) {
        (void)close(outcome_pipe[0]);
        if (want_pre_exec_death) abort();
        if (want_post_ready_death) {
            struct ys_exec_outcome ready = {
                YS_EXEC_READY, YS_EXEC_PHASE_EXECVE, 0U, 0
            };
            if (write(outcome_pipe[1], &ready, sizeof ready) != (ssize_t)sizeof ready)
                _exit(125);
            abort();
        }
        ys_exec(report_argv, YS_PLAN_ENVIRONMENT, instruction_fd, stdout_fd, stderr_fd,
                outcome_pipe[1]);
        _exit(127);
    }
    (void)close(outcome_pipe[1]);
    (void)close(instruction_fd); (void)close(stdout_fd); (void)close(stderr_fd); (void)close(marker_fd);
    if (waitpid(pid, &status, 0) < 0) die("E_FRAME_IO");
    outcome_bytes = read(outcome_pipe[0], outcomes, sizeof outcomes);
    (void)close(outcome_pipe[0]);
    if (want_pre_exec_death) {
        if (!WIFSIGNALED(status) || outcome_bytes != 0) die("E_FRAME_IO");
    } else if (want_post_ready_death) {
        if (!WIFSIGNALED(status) || outcome_bytes != (ssize_t)sizeof outcomes[0] ||
            outcomes[0].kind != YS_EXEC_READY) die("E_FRAME_IO");
    } else if (want_report_failure) {
        if (!WIFSIGNALED(status) || outcome_bytes != 0) die("E_FRAME_IO");
    } else if (!WIFEXITED(status)) {
        die("E_FRAME_IO");
    } else if (want_refusal) {
        if (WEXITSTATUS(status) != 126 || outcome_bytes != (ssize_t)sizeof outcomes[0] ||
            outcomes[0].kind != YS_EXEC_FAILURE || outcomes[0].phase != YS_EXEC_PHASE_CLOSE)
            die("E_FRAME_IO");
    } else if (want_exec_failure) {
        if (WEXITSTATUS(status) != 127 || outcome_bytes != (ssize_t)sizeof outcomes ||
            outcomes[0].kind != YS_EXEC_READY || outcomes[1].kind != YS_EXEC_FAILURE ||
            outcomes[1].phase != YS_EXEC_PHASE_EXECVE)
            die("E_FRAME_IO");
    } else if (WEXITSTATUS(status) != expected_exit) {
        die("E_FRAME_IO");
    } else if (outcome_bytes != (ssize_t)sizeof outcomes[0] ||
               outcomes[0].kind != YS_EXEC_READY) {
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
    int env_ok, fd0_ok, fd1_ok, fd2_ok, extra, fl0, fl1, fl2;
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
    fl0 = fcntl(0, F_GETFL);
    errno = 0;
    fd0_ok = (fstat(0, &st) == 0 && S_ISREG(st.st_mode) && lseek(0, 0, SEEK_CUR) == 0 &&
              fl0 >= 0 && (fl0 & O_ACCMODE) == O_RDONLY && write(0, "x", 1) == -1 &&
              errno == EBADF);
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
    if (strstr(argv[0], "exit126") != NULL) return 126;
    if (strstr(argv[0], "exit127") != NULL) return 127;
    return 0;
}

static int cmd_observation_values(void)
{
    struct guest_row row = {0, "unavailable", "none", 0, 1};
    uint64_t rounded;
    int variant;
    if (!ys_rounded_allocation(4097U, 4096U, &rounded) || rounded != 8192U ||
        ys_rounded_allocation(UINT64_MAX, 4096U, &rounded)) return 1;
    ys_cpu_values(&row, 1, "usage_usec 1001\n", 2U);
    if (row.observed != 2U || !row.reached || strcmp(row.observation, "complete") != 0) return 1;
    ys_cpu_values(&row, 0, "usage_usec 1001\n", 2U);
    if (strcmp(row.observation, "unavailable") != 0) return 1;
    ys_memory_values(&row, 1, 1, 1U, "oom_kill 1\n", 2U);
    if (row.observed != 1U || !row.reached) return 1;
    ys_tasks_values(&row, 1, 1, 1U, "max 0\n", 2U);
    if (row.reached) return 1;
    ys_output_values(&row, 0, 2U, 1, 1U, 2U);
    if (!row.reached || strcmp(row.observation, "partial") != 0) return 1;
    ys_scratch_values(&row, 1, 3U, 1U, 4096U, 8192U);
    if (row.observed != 8192U || !row.reached || row.resolution != 4096U) return 1;
    if (ys_launch_pid_valid(0) || ys_launch_pid_valid(-1) || !ys_launch_pid_valid(17)) return 1;
    {
        struct ys_plan_limits limits = {0};
        struct ys_setup_observations raw = {0};
        size_t i;
        uint64_t parsed;
        char text[64];
        limits.cpu_max = 45000; limits.cpu_max_burst = 0;
        limits.bandwidth_slice_us = 1000; limits.pids_max = 64;
        for (i = 0; i < 4U; i++) {
            raw.writes[i] = raw.reads[i] = 1;
            if (!ys_setup_write_text(&limits, i, text, sizeof text)) return 1;
            if (i == 0U) strcpy(raw.readbacks[i], "45000 100000\n");
            else strcpy(raw.readbacks[i], text);
            if (!ys_write_count_values((ssize_t)strlen(text), strlen(text), 0) ||
                ys_write_count_values((ssize_t)strlen(text) - 1, strlen(text), 0) ||
                ys_write_count_values((ssize_t)strlen(text), strlen(text), -1)) return 1;
        }
        if (!ys_setup_presence_values(&limits, &raw, 15, 15) ||
            ys_setup_presence_values(&limits, &raw, 14, 15) ||
            ys_setup_presence_values(&limits, &raw, 15, 14) ||
            ys_setup_presence_values(&limits, &raw, 31, 15) ||
            ys_setup_presence_values(&limits, &raw, 15, 31)) return 1;
        raw.writes[1] = raw.writes[2] = raw.reads[1] = raw.reads[2] = 0;
        raw.readbacks[1][0] = raw.readbacks[2][0] = '\0';
        raw.reads[0] = 0; raw.readbacks[0][0] = '\0';
        if (!ys_setup_presence_values(&limits, &raw, 9, 9) ||
            ys_setup_presence_values(&limits, &raw, 9, 8) ||
            ys_setup_presence_values(&limits, &raw, 11, 9)) return 1;
        raw.writes[0] = 0;
        if (!ys_setup_presence_values(&limits, &raw, 9, 8) ||
            ys_setup_presence_values(&limits, &raw, 9, 9)) return 1;
        if (!ys_u64_values(1, "not numeric", &parsed) || parsed != 0 ||
            !ys_counter_presence_values(1, 0, 1) || ys_counter_presence_values(1, 0, 0) ||
            ys_counter_presence_values(1, 0, 3) || !ys_counter_presence_values(0, 1, 2) ||
            !ys_counter_presence_values(0, 0, 0)) return 1;
    }
    for (variant = 0; variant < 4; variant++) {
        struct ys_controller_state state;
        struct timespec deadline = {1, 0};
        enum ys_controller_action action = YS_ACTION_NOW;
        size_t calls = 0;
        int waits = 0, reads = 0;
        ys_controller_init(&state, 17, 0, &deadline);
        while (action != YS_ACTION_DONE && calls++ < 100U) {
            struct ys_controller_event event;
            memset(&event, 0, sizeof event);
            event.action = action == YS_ACTION_TICK_NOW ? YS_ACTION_NOW : action;
            event.value = 1;
            if (event.action == YS_ACTION_NOW) {
                event.now.tv_nsec = (long)calls;
                if (variant == 2 && calls > 20U) event.now.tv_sec = 1;
                if (variant == 3 && waits == 1) event.error_number = EINTR;
            }
            else if (action == YS_ACTION_POLL) event.revents[0] = POLLIN | POLLHUP;
            else if (action == YS_ACTION_WAIT) {
                event.waited = variant == 1 && waits++ == 0 ? 0 : variant == 2 ? 18 : 17;
                if (variant == 3 && waits++ == 0) { event.waited = -1; event.error_number = EINTR; }
            } else if (action == YS_ACTION_POPULATION) event.value = 0;
            else if (action == YS_ACTION_EXEC_READ) {
                if (reads++ == 0) {
                    struct ys_exec_outcome ready = { YS_EXEC_READY, YS_EXEC_PHASE_EXECVE, 0, 0 };
                    event.read_count = (ssize_t)sizeof ready;
                    memcpy(event.bytes, &ready, sizeof ready);
                }
            }
            action = ys_controller_step(&state, &event);
        }
        if (action != YS_ACTION_DONE || state.result.verifier_started != (variant != 2) ||
            state.result.child_reaped != (variant != 2) ||
            (state.branch == CONTROLLER_NORMAL) != (variant != 2)) return 1;
    }
    {
        struct ys_control_capture capture = {0};
        struct timespec now = {12, 34};
        struct ys_controller_event event;
        size_t saved_length;
        ys_capture_now(&capture, 1, &now, 0);
        ys_capture_launch(&capture, -1, EAGAIN);
        memset(&event, 0, sizeof event);
        event.action = YS_ACTION_WAIT; event.waited = -1; event.error_number = EINTR;
        ys_capture_event(&capture, &event);
        if (capture.incomplete || capture.count != 3U || capture.bytes == NULL ||
            strstr(capture.bytes, "\"sec\":12") == NULL ||
            strstr(capture.bytes, "\"pid\":-1,\"tag\":\"launch\"") == NULL ||
            strstr(capture.bytes, "\"pid\":-1,\"status\":0,\"tag\":\"wait\"") == NULL) {
            free(capture.bytes); return 1;
        }
        ys_capture_now(&capture, 0, NULL, EIO);
        if (strstr(capture.bytes, "\"nsec\":null,\"sec\":null") == NULL) {
            free(capture.bytes); return 1;
        }
        while (capture.count < 4096U) ys_capture_launch(&capture, 17, 0);
        saved_length = capture.length;
        ys_capture_launch(&capture, 18, 0);
        if (!capture.incomplete || capture.count != 4096U || capture.length != saved_length) {
            free(capture.bytes); return 1;
        }
        free(capture.bytes);
    }
    puts("guest value owner: counters, geometry, launch, wait zero/matching/wrong/EINTR, bounded primitive capture: ok");
    return 0;
}

static int cmd_inventory_capture(int argc, char **argv)
{
    struct ys_control_capture setup = {0}, control = {0}, counters = {0};
    struct ys_evidence_capture observation = { &counters, 0 };
    char **names = NULL, *json;
    size_t count = 0, length, i;
    int dirfd;
    enum ys_plan_status result;
    if (argc != 3) return 2;
    dirfd = open(argv[2], O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    result = ys_evidence_inventory_observed(dirfd, &names, &count,
                                             ys_capture_evidence_entry, &observation);
    json = ys_capture_document(&setup, &control, &counters, &length);
    if (json != NULL) { puts(json); free(json); }
    for (i = 0; i < count; i++) free(names[i]);
    free(names); free(counters.bytes);
    return result == YS_PLAN_OK && json != NULL ? 0 : 1;
}

static int capture_report_frame(const char *capture, size_t capture_length, unsigned char digest[32])
{
    struct ys_setup_observations raw = {0};
    struct ys_setup_flags flags;
    struct ys_plan_limits limits = {0};
    struct report_state report = {0};
    struct ys_frame_writer writer;
    struct ys_frame_reader reader;
    FILE *file = tmpfile();
    char plan_hash[65], *json;
    size_t length, index = 0;
    int fd, result = 0;
    if (file == NULL) return 0;
    fd = fileno(file);
    memset(plan_hash, '0', 64U); plan_hash[64] = '\0';
    raw.meminfo_ok = 1; strcpy(raw.meminfo, "MemTotal: 100 kB\n");
    ys_setup_values(&limits, &raw, 536870912ULL, &flags);
    ys_report_setup_values(&report, &flags, 4096);
    report.verifier_started = report.tree_terminated = 1;
    ys_cpu_values(&report.cpu, 1, "usage_usec 1001\n", 30000);
    ys_memory_values(&report.memory, 1, 1, 4096, "oom_kill 0\n", 536870912ULL);
    ys_tasks_values(&report.tasks, 1, 1, 1, "max 0\n", 64);
    ys_output_values(&report.output, 1, 0, 1, 9, 40960);
    ys_scratch_values(&report.scratch, 1, 10, 9, 4096, 40960);
    json = ys_build_report_json(plan_hash, &report, NULL, &length);
    if (json == NULL) goto done;
    if (strstr(json, "\"cpu_time_ms\":{\"enforcement\":\"none\",\"observation\":\"complete\",\"observed\":2") == NULL) goto free_json;
    ys_sha256_bytes(json, length, digest);
    if (!ys_frame_writer_open(&writer, fd) ||
        ys_frame_writer_put(&writer, "report.json", 11U, json, length) != YS_FRAME_OK ||
        ys_frame_writer_put(&writer, "stdout", 6U, "", 0U) != YS_FRAME_OK ||
        ys_frame_writer_put(&writer, "stderr", 6U, "", 0U) != YS_FRAME_OK) goto free_json;
    if (capture != NULL && ys_frame_writer_put(&writer, "control-observation.json", 24U,
                                               capture, capture_length) != YS_FRAME_OK) goto free_json;
    if (ys_frame_writer_close(&writer) != YS_FRAME_OK ||
        ys_frame_reader_open(&reader, fd, writer.offset) != YS_FRAME_OK) goto free_json;
    for (;;) {
        struct ys_frame_record record;
        static const char *const names[] = {"report.json", "stdout", "stderr", "control-observation.json"};
        if (ys_frame_reader_next(&reader, &record) != YS_FRAME_OK) goto free_json;
        if (record.is_end) break;
        if (index >= (capture ? 4U : 3U) || strcmp(record.name, names[index]) != 0 ||
            (index == 0U && (record.length != length || memcmp(record.content, json, length) != 0)) ||
            (index == 3U && (record.length != capture_length || memcmp(record.content, capture, capture_length) != 0))) {
            free(record.content); goto free_json;
        }
        index++; free(record.content);
    }
    result = index == (capture ? 4U : 3U);
free_json:
    free(json);
done:
    fclose(file); return result;
}

static int cmd_observation_capture(void)
{
    struct ys_control_capture setup = {0}, control = {0}, counters = {0};
    struct ys_controller_event event;
    struct ys_frame_writer frame;
    struct timespec now = {12, 34};
    struct statvfs sv;
    struct stat st;
    struct ys_fan_stat fan;
    char *json, *large;
    unsigned char with_capture[32], without_capture[32];
    size_t length, overhead = sizeof "{\"control\":[],\"counters\":{},\"setup\":{}}" - 1U;
    memset(&sv, 0, sizeof sv); memset(&st, 0, sizeof st);
    sv.f_blocks = 10; sv.f_bfree = 9; sv.f_frsize = 4096; sv.f_files = 3;
    st.st_mode = S_IFREG | 0600; st.st_size = 2; st.st_nlink = 1;
    errno = EBUSY;
    ys_capture_io(&setup, "z_read", -1, EIO, "", 0);
    ys_capture_io(&setup, "a_read", 2, 0, "{}", 2);
    ys_capture_statvfs(&setup, "output", 0, 0, &sv);
    ys_capture_stat(&counters, "stdout", 0, 0, &st);
    ys_capture_now(&control, 1, &now, 0);
    ys_capture_launch(&control, 17, 0);
    memset(&event, 0, sizeof event); event.action = YS_ACTION_POLL;
    event.value = 1; event.fd_count = 1; event.fd_roles[0] = 2; event.revents[0] = POLLIN;
    ys_capture_event(&control, &event);
    ys_capture_population(&control, 12, "populated 0\n", 0);
    memset(&fan, 0, sizeof fan); fan.fd = 27; fan.result = -1; fan.error_number = EIO;
    ys_capture_fan_read(&control, -1, EINTR, NULL, &fan, 0);
    ys_capture_fan_reply(&control, -1, EIO);
    ys_capture_kill(&control, 0, EIO);
    json = ys_capture_document(&setup, &control, &counters, &length);
    if (json == NULL || errno != EBUSY || strstr(json, "\"role\":\"exec\"") == NULL ||
        strstr(json, "\"errno\":5,\"return\":-1,\"tag\":\"fan-reply\"") == NULL ||
        strstr(json, "\"setup\":{\"a_read\"") == NULL || strlen(json) != length) return 1;
    if (!capture_report_frame(json, length, with_capture)) return 1;
    puts(json); free(json);
    ys_capture_io(&setup, "a_read", 0, 0, "", 0);
    json = ys_capture_document(&setup, &control, &counters, &length);
    if (!setup.incomplete || json != NULL ||
        !capture_report_frame(NULL, 0U, without_capture) ||
        memcmp(with_capture, without_capture, sizeof with_capture) != 0) return 1;
    free(setup.bytes); free(control.bytes); free(counters.bytes);
    memset(&setup, 0, sizeof setup); memset(&control, 0, sizeof control); memset(&counters, 0, sizeof counters);
    large = malloc(4U * 1024U * 1024U + 1U);
    if (large == NULL) return 1;
    length = 4U * 1024U * 1024U - overhead;
    memcpy(large, "\"padding\":\"", 11U);
    memset(large + 11U, 'a', length - 12U); large[length - 1U] = '\"'; large[length] = '\0';
    ys_capture_raw(&setup, large, length);
    json = ys_capture_document(&setup, &control, &counters, &length);
    if (json == NULL || length != 4U * 1024U * 1024U) return 1;
    free(json);
    memset(&frame, 0, sizeof frame); frame.offset = 123;
    if (!ys_capture_fits(&frame, (off_t)(123U + length + 77U), length) ||
        ys_capture_fits(&frame, (off_t)(123U + length + 76U), length)) return 1;
    ys_capture_io(&counters, "extra", 0, 0, "", 0);
    if (ys_capture_document(&setup, &control, &counters, &length) != NULL ||
        !capture_report_frame(NULL, 0U, without_capture) ||
        memcmp(with_capture, without_capture, sizeof with_capture) != 0) return 1;
    free(large); free(setup.bytes); free(counters.bytes);
    memset(&control, 0, sizeof control);
    large = calloc(4096U, 1);
    if (large == NULL) return 1;
    ys_capture_fan_read(&control, 4062, 0, (const unsigned char *)large, NULL, 0);
    if (control.incomplete || control.length != 8192U || control.count != 1U) return 1;
    ys_capture_fan_read(&control, 4063, 0, (const unsigned char *)large, NULL, 0);
    if (!control.incomplete || control.length != 8192U || control.count != 1U) return 1;
    free(large); free(control.bytes);
    memset(&counters, 0, sizeof counters);
    {
        struct ys_evidence_capture evidence = { &counters, 9999U };
        size_t before;
        ys_capture_evidence_entry("last", 0, 0, &st, &evidence);
        if (counters.incomplete || evidence.count != 10000U) return 1;
        before = counters.length;
        ys_capture_evidence_entry("extra", 0, 0, &st, &evidence);
        if (!counters.incomplete || counters.length != before || evidence.count != 10000U) return 1;
    }
    free(counters.bytes);
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
    if (strcmp(argv[1], "observation-values") == 0 && argc == 2) return cmd_observation_values();
    if (strcmp(argv[1], "observation-capture") == 0 && argc == 2) return cmd_observation_capture();
    if (strcmp(argv[1], "inventory-capture") == 0) return cmd_inventory_capture(argc, argv);
    usage();
    return 2;
}
