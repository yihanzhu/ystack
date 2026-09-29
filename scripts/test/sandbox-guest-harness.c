#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif

/*
 * Test-only driver for sandbox/v1/guest/common.c (ystack #463, PR 1 of 9).
 * See scripts/test/sandbox-guest.test.sh, work/vm-launcher-supervisor/
 * plan.md ("PR 1"). Not built or run in production.
 *
 * usage:
 *   sandbox-guest-harness frame-write <out> [<name>=<file> ...]
 *   sandbox-guest-harness frame-read <in> <dir> [input|export]
 *   sandbox-guest-harness digest <file>
 */

#include "../../sandbox/v1/guest/common.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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

int main(int argc, char **argv)
{
    if (argc < 2) usage();
    if (strcmp(argv[1], "frame-write") == 0) return cmd_frame_write(argc, argv);
    if (strcmp(argv[1], "frame-read") == 0) return cmd_frame_read(argc, argv);
    if (strcmp(argv[1], "digest") == 0) return cmd_digest(argc, argv);
    if (strcmp(argv[1], "path-ok") == 0) return cmd_path_ok(argc, argv);
    usage();
    return 2;
}
