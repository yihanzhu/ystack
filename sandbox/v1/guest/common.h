#ifndef YSTACK_SANDBOX_GUEST_COMMON_H
#define YSTACK_SANDBOX_GUEST_COMMON_H

/* Shared guest code, VM launcher and supervisor (ystack #463), PR 1 of 9:
 * FIPS 180-4 SHA-256, the YSFRAME1 frame codec (R3.2) and the input (R5.2)
 * / export (R8.1) record-name sets. See work/vm-launcher-supervisor/
 * spec.md, plan.md. Inactive: nothing here runs against a real guest. */

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

struct ys_sha256_ctx {
    uint32_t state[8];
    uint64_t total_bits;
    unsigned char buffer[64];
    size_t buffered;
};

void ys_sha256_init(struct ys_sha256_ctx *ctx);
void ys_sha256_update(struct ys_sha256_ctx *ctx, const void *data, size_t len);
void ys_sha256_final(struct ys_sha256_ctx *ctx, unsigned char out[32]);
void ys_sha256_bytes(const void *data, size_t len, unsigned char out[32]);
void ys_hex_encode(const unsigned char *in, size_t len, char *out);

/* YSFRAME1 (R3.2): magic, records of {1-byte name length, name, 8-byte
 * big-endian length, bytes}, then "end" whose 32-byte content is the
 * SHA-256 of everything before it; every byte after "end" must be zero.
 * Authenticates nothing about names: detects only truncation/damage. */
#define YS_FRAME_MAGIC "YSFRAME1"
#define YS_FRAME_MAGIC_LEN 8U
#define YS_FRAME_NAME_MAX 255U
#define YS_FRAME_DIGEST_LEN 32U
#define YS_FRAME_END_NAME "end"

enum ys_frame_status {
    YS_FRAME_OK = 0, YS_FRAME_ERR_MAGIC, YS_FRAME_ERR_TRUNCATED, YS_FRAME_ERR_DIGEST,
    YS_FRAME_ERR_TAIL, YS_FRAME_ERR_NAME, YS_FRAME_ERR_INDEX, YS_FRAME_ERR_MISSING,
    YS_FRAME_ERR_IO
};

const char *ys_frame_status_str(enum ys_frame_status status);

/* content is malloc'd by ys_frame_reader_next (NULL if length 0); caller
 * frees it. For "end", content is NULL and is_end is set: by then the
 * digest and zero tail are already verified. */
struct ys_frame_record {
    char name[YS_FRAME_NAME_MAX + 1U];
    size_t name_len;
    uint64_t length;
    unsigned char *content;
    int is_end;
};

struct ys_frame_writer { int fd; struct ys_sha256_ctx digest; off_t offset; int closed; };

/* Writer is purely mechanical (so tests can build malformed frames too): it
 * only enforces the 1-byte name-length limit and refuses a record literally
 * named "end" (ys_frame_writer_close appends the real one). */
int ys_frame_writer_open(struct ys_frame_writer *w, int fd);
enum ys_frame_status ys_frame_writer_put(struct ys_frame_writer *w, const char *name,
                                          size_t name_len, const void *data, size_t len);
enum ys_frame_status ys_frame_writer_close(struct ys_frame_writer *w);

struct ys_frame_reader {
    int fd; off_t total_size; off_t offset; struct ys_sha256_ctx digest; int done;
};

/* fstat's a regular file, or (Linux) ioctl(BLKGETSIZE64)'s a block device
 * (the input/export disks are block devices in the guest, whose fstat
 * st_size is 0); any other descriptor type is refused. Callers open a
 * reader with this capacity, not raw st_size. */
enum ys_frame_status ys_frame_descriptor_capacity(int fd, off_t *capacity_out);

/* Sequential reader over a descriptor of the given total capacity. One
 * record per call; is_end means the digest and zero-only tail are already
 * checked and no further call is valid. */
enum ys_frame_status ys_frame_reader_open(struct ys_frame_reader *r, int fd, off_t capacity);
enum ys_frame_status ys_frame_reader_next(struct ys_frame_reader *r, struct ys_frame_record *rec);

/* R5.2 / R8.1: fixed leading names in order, then a zero-padded,
 * contiguous-from-0 indexed name, then "end" (checked by the reader). */
enum ys_record_set { YS_RECORD_SET_INPUT, YS_RECORD_SET_EXPORT };
struct ys_record_set_state { enum ys_record_set set; unsigned step; uint32_t next_index; };

void ys_record_set_init(struct ys_record_set_state *state, enum ys_record_set set);
/* Called once per non-"end" record, in reader order. *index_out is the
 * parsed index for an indexed record, else 0. */
enum ys_frame_status ys_record_set_advance(struct ys_record_set_state *state, const char *name,
                                            size_t len, uint32_t *index_out);
/* Called once "end" is reached: confirms every mandatory name was seen. */
enum ys_frame_status ys_record_set_finish(const struct ys_record_set_state *state);

/* Strict UTF-8 and the preparation path range (candidate-content-
 * preparation spec.md:262-270): <=4,096 bytes, <=64 components (<=255
 * bytes each); no absolute/empty path, empty/"."/".." component,
 * backslash, C0/C1 control byte, case-insensitive ".git" component, or a
 * component ending in "." or " ". Manifest-wide checks (duplicates,
 * Unicode aliasing) are not this layer's job. */
int ys_utf8_validate(const unsigned char *s, size_t len, int *has_control);
int ys_path_range_ok(const unsigned char *path, size_t len);

/* PR 2: sandbox_guest_plan (R5.2) parsing, R5.5 materialization, R6.4
 * wiring, R8.1 export inventory. Canonical form only (no whitespace, keys
 * sorted, one trailing LF): `{"body":{"argv":<fixed>,"entries":[...],
 * "environment":<fixed>,"instruction_sha256":<hex>,"limits":{...9 R7.1
 * fields...},"verifier_sha256":<hex>},"kind":"sandbox_guest_plan",
 * "schema_version":1}\n`. `argv` and `environment` are R6.4's fixed wiring
 * (YS_PLAN_ARGV / YS_PLAN_ENVIRONMENT below) and are matched literally, not
 * decoded: the plan never varies them. */
#define YS_PLAN_ARGV0 "/sandbox/tools/verifier"
extern const char *const YS_PLAN_ARGV[7]; /* argv0..argv5, NULL */
extern const char *const YS_PLAN_ENVIRONMENT[5]; /* 4 entries, NULL */

enum ys_plan_status { YS_PLAN_OK = 0, YS_PLAN_ERR_SCHEMA, YS_PLAN_ERR_LIMIT, YS_PLAN_ERR_IO };
const char *ys_plan_status_str(enum ys_plan_status status);

struct ys_plan_limits {
    uint64_t bandwidth_slice_us, cpu_max, cpu_max_burst, output_inodes, output_tmpfs_bytes,
        pids_max, scratch_bytes, scratch_inodes, tree_deadline_ms;
};

/* One manifest entry. Directories carry no digest or size (R3.2/R5.2:
 * "directories with null digest and size"); the n-th file entry (0-based,
 * directories not counted) is frame record candidate/<n>. */
struct ys_plan_entry {
    int is_file;
    char mode[5];
    unsigned char path[4096];
    size_t path_len;
    unsigned char sha256_hex[65];
    uint64_t size_bytes;
};

struct ys_guest_plan {
    struct ys_plan_entry *entries;
    size_t entry_count;
    unsigned char instruction_sha256_hex[65];
    struct ys_plan_limits limits;
    unsigned char verifier_sha256_hex[65];
};

/* Parses and validates `bytes[0..len)` per the shape above; unknown,
 * missing, duplicate or misordered keys, a disallowed escape (anything
 * `json.dumps(ensure_ascii=False)` would not itself emit) or a type/range
 * mismatch is YS_PLAN_ERR_SCHEMA. On success, plan->entries is malloc'd
 * (caller calls ys_plan_free). */
enum ys_plan_status ys_plan_parse(const unsigned char *bytes, size_t len,
                                   struct ys_guest_plan *plan);
void ys_plan_free(struct ys_guest_plan *plan);

/* R5.5 materialization under directory descriptor `dirfd`: entries in plan
 * order, each path walked one component at a time (never as one long
 * string: a 4,096-byte candidate path exceeds PATH_MAX on every POSIX
 * host). A directory is mkdirat'd then fchownat'd to uid:gid, mode 0500; a
 * file is openat'd (O_CREAT|O_EXCL), written from
 * file_contents[fi]/file_lengths[fi] (fi = that entry's file index),
 * fchown'd to uid:gid and fchmod'd to its exact manifest mode, after
 * checking its written size and SHA-256 against the entry. Every path is
 * plan-relative (ys_path_range_ok already checked by the parser). */
enum ys_plan_status ys_plan_materialize(int dirfd, uid_t uid, gid_t gid,
                                         const struct ys_guest_plan *plan,
                                         const unsigned char *const *file_contents,
                                         const size_t *file_lengths);

/* Walks the real descriptor table (Linux /proc/self/fd, Darwin /dev/fd;
 * never a numeric guess), calling visit(fd, ctx) per open fd >= lowfd. 1
 * if complete, 0 if not confirmed complete (fail-closed, e.g. a test's
 * own "every other descriptor closed" check). Shared by ys_exec's Darwin
 * close path and anything checking its work. */
int ys_walk_fds(int lowfd, void (*visit)(int fd, void *ctx), void *ctx);

/* R6.4 wiring: execve's `argv` with `envp`, fd 0 the instruction (a regular
 * file opened read-only from `instruction_fd`, which must be seekable to
 * offset 0), fd 1 and 2 duplicated from `stdout_fd`/`stderr_fd` (opened
 * O_WRONLY|O_APPEND by the caller), every other descriptor above 2 closed
 * exhaustively first (Linux close_range; Darwin, this harness's own build
 * only, a /dev/fd walk -- no numeric-sweep fallback either way, since a
 * capped sweep is not exhaustive and a lowered rlimit does not close an
 * fd already open past it). Refuses (_exit(126)) instead of proceeding to
 * execve if that closure cannot be confirmed. Does not return on success. */
void ys_exec(const char *const *argv, const char *const *envp, int instruction_fd,
             int stdout_fd, int stderr_fd);

/* R8.1 export inventory: every regular file directly under `dirfd`, sorted
 * by name, becomes evidence/<index>; refuses (YS_PLAN_ERR_SCHEMA) if any
 * has link count other than 1 or shares an inode with another (a
 * same-directory hard-link alias), since either means the evidence set is
 * not what it claims to be. `names_out[i]` (malloc'd, caller frees each and
 * the array) receives the i-th file's name in that order. */
enum ys_plan_status ys_evidence_inventory(int dirfd, char ***names_out, size_t *count_out);

#ifdef YSTACK_TEST_FAULT_INJECT
/* Test-only hook, compiled only when this translation unit is built with
 * -DYSTACK_TEST_FAULT_INJECT (never in a production build): when non-zero,
 * the Nth readdir() call inside ys_evidence_inventory fails with ENOMEM
 * instead of returning a real dirent, so the test suite can prove the
 * readdir-failure path (otherwise untriggerable deterministically). */
extern size_t ys_test_readdir_fail_at;
/* When non-zero, ys_exec's close_all_from refuses immediately (as if
 * close_range/the /dev/fd walk itself had failed), so the test suite can
 * prove ys_exec fails closed (_exit(126), execve never reached) rather
 * than silently proceeding when exhaustive closure can't be confirmed. */
extern int ys_test_close_all_fail;
#endif

#endif
