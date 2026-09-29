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

/* Sequential reader over a descriptor of known total size (fstat'd at
 * open). One record per call; is_end means the digest and zero-only tail
 * are already checked and no further call is valid. */
enum ys_frame_status ys_frame_reader_open(struct ys_frame_reader *r, int fd);
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

#endif
