#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
/* See common.h. */
#include "common.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__linux__)
#include <linux/fs.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#endif

/* --- SHA-256 (FIPS 180-4) ------------------------------------------------ */
static const uint32_t SHA256_K[64] = {
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U,
    0x923f82a4U, 0xab1c5ed5U, 0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
    0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U, 0xe49b69c1U, 0xefbe4786U,
    0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
    0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U,
    0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
    0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U, 0xa2bfe8a1U, 0xa81a664bU,
    0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
    0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU,
    0x5b9cca4fU, 0x682e6ff3U, 0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
    0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U
};
static uint32_t rotr32(uint32_t v, unsigned b) { return (v >> b) | (v << (32U - b)); }
static void sha256_compress(struct ys_sha256_ctx *ctx, const unsigned char block[64])
{
    uint32_t w[64], a, b, c, d, e, f, g, h;
    unsigned i;
    for (i = 0; i < 16; i++)
        w[i] = ((uint32_t)block[i * 4] << 24) | ((uint32_t)block[i * 4 + 1] << 16) |
               ((uint32_t)block[i * 4 + 2] << 8) | (uint32_t)block[i * 4 + 3];
    for (i = 16; i < 64; i++) {
        uint32_t s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    a = ctx->state[0]; b = ctx->state[1]; c = ctx->state[2]; d = ctx->state[3];
    e = ctx->state[4]; f = ctx->state[5]; g = ctx->state[6]; h = ctx->state[7];
    for (i = 0; i < 64; i++) {
        uint32_t s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
        uint32_t ch = (e & f) ^ ((~e) & g);
        uint32_t t1 = h + s1 + ch + SHA256_K[i] + w[i];
        uint32_t s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = s0 + maj;
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    ctx->state[0] += a; ctx->state[1] += b; ctx->state[2] += c; ctx->state[3] += d;
    ctx->state[4] += e; ctx->state[5] += f; ctx->state[6] += g; ctx->state[7] += h;
}
void ys_sha256_init(struct ys_sha256_ctx *ctx)
{
    ctx->state[0] = 0x6a09e667U; ctx->state[1] = 0xbb67ae85U; ctx->state[2] = 0x3c6ef372U;
    ctx->state[3] = 0xa54ff53aU; ctx->state[4] = 0x510e527fU; ctx->state[5] = 0x9b05688cU;
    ctx->state[6] = 0x1f83d9abU; ctx->state[7] = 0x5be0cd19U;
    ctx->total_bits = 0; ctx->buffered = 0;
}
void ys_sha256_update(struct ys_sha256_ctx *ctx, const void *data, size_t len)
{
    const unsigned char *p = data;
    ctx->total_bits += (uint64_t)len * 8U;
    while (len > 0) {
        size_t take = 64U - ctx->buffered;
        if (take > len) take = len;
        memcpy(ctx->buffer + ctx->buffered, p, take);
        ctx->buffered += take; p += take; len -= take;
        if (ctx->buffered == 64U) { sha256_compress(ctx, ctx->buffer); ctx->buffered = 0; }
    }
}
void ys_sha256_final(struct ys_sha256_ctx *ctx, unsigned char out[32])
{
    unsigned char pad[72];
    uint64_t total_bits = ctx->total_bits;
    size_t pad_len = (ctx->buffered < 56U) ? 56U - ctx->buffered : 120U - ctx->buffered;
    unsigned i;
    pad[0] = 0x80;
    for (i = 1; i < pad_len; i++) pad[i] = 0x00;
    ys_sha256_update(ctx, pad, pad_len);
    ctx->total_bits = total_bits;
    for (i = 0; i < 8; i++) pad[i] = (unsigned char)(total_bits >> (56U - 8U * i));
    /* buffered is now exactly 56: append the 8-byte bit length and compress. */
    memcpy(ctx->buffer + ctx->buffered, pad, 8U);
    ctx->buffered += 8U;
    sha256_compress(ctx, ctx->buffer);
    for (i = 0; i < 8; i++) {
        out[i * 4] = (unsigned char)(ctx->state[i] >> 24);
        out[i * 4 + 1] = (unsigned char)(ctx->state[i] >> 16);
        out[i * 4 + 2] = (unsigned char)(ctx->state[i] >> 8);
        out[i * 4 + 3] = (unsigned char)(ctx->state[i]);
    }
}
void ys_sha256_bytes(const void *data, size_t len, unsigned char out[32])
{
    struct ys_sha256_ctx ctx;
    ys_sha256_init(&ctx); ys_sha256_update(&ctx, data, len); ys_sha256_final(&ctx, out);
}
void ys_hex_encode(const unsigned char *in, size_t len, char *out)
{
    static const char digits[] = "0123456789abcdef";
    size_t i;
    for (i = 0; i < len; i++) {
        out[i * 2] = digits[(in[i] >> 4) & 0x0FU];
        out[i * 2 + 1] = digits[in[i] & 0x0FU];
    }
    out[len * 2] = '\0';
}

/* --- YSFRAME1 -------------------------------------------------------------- */
const char *ys_frame_status_str(enum ys_frame_status status)
{
    static const char *const table[] = {
        "ok", "E_FRAME_MAGIC", "E_FRAME_TRUNCATED", "E_FRAME_DIGEST", "E_FRAME_TAIL",
        "E_FRAME_NAME", "E_FRAME_INDEX", "E_FRAME_MISSING", "E_FRAME_IO"
    };
    return ((unsigned)status < sizeof table / sizeof table[0]) ? table[status] : "E_FRAME_UNKNOWN";
}
static int full_write(int fd, const void *data, size_t len)
{
    const unsigned char *p = data;
    size_t written = 0;
    while (written < len) {
        ssize_t n = write(fd, p + written, len - written);
        if (n < 0) { if (errno == EINTR) continue; return 0; }
        written += (size_t)n;
    }
    return 1;
}
static void encode_be64(uint64_t v, unsigned char out[8])
{
    unsigned i;
    for (i = 0; i < 8U; i++) out[i] = (unsigned char)(v >> (56U - 8U * i));
}
static uint64_t decode_be64(const unsigned char in[8])
{
    uint64_t v = 0;
    unsigned i;
    for (i = 0; i < 8U; i++) v = (v << 8) | (uint64_t)in[i];
    return v;
}
int ys_frame_writer_open(struct ys_frame_writer *w, int fd)
{
    w->fd = fd; w->offset = 0; w->closed = 0;
    ys_sha256_init(&w->digest);
    if (!full_write(fd, YS_FRAME_MAGIC, YS_FRAME_MAGIC_LEN)) return 0;
    ys_sha256_update(&w->digest, YS_FRAME_MAGIC, YS_FRAME_MAGIC_LEN);
    w->offset += (off_t)YS_FRAME_MAGIC_LEN;
    return 1;
}
enum ys_frame_status ys_frame_writer_put(struct ys_frame_writer *w, const char *name,
                                          size_t name_len, const void *data, size_t len)
{
    unsigned char name_len_byte, len_field[8];
    if (w->closed) return YS_FRAME_ERR_IO;
    if (name_len > YS_FRAME_NAME_MAX) return YS_FRAME_ERR_NAME;
    if (name_len == strlen(YS_FRAME_END_NAME) && memcmp(name, YS_FRAME_END_NAME, name_len) == 0)
        return YS_FRAME_ERR_NAME;
    name_len_byte = (unsigned char)name_len;
    encode_be64((uint64_t)len, len_field);
    if (!full_write(w->fd, &name_len_byte, 1U) ||
        (name_len > 0 && !full_write(w->fd, name, name_len)) ||
        !full_write(w->fd, len_field, 8U) || (len > 0 && !full_write(w->fd, data, len)))
        return YS_FRAME_ERR_IO;
    ys_sha256_update(&w->digest, &name_len_byte, 1U);
    if (name_len > 0) ys_sha256_update(&w->digest, name, name_len);
    ys_sha256_update(&w->digest, len_field, 8U);
    if (len > 0) ys_sha256_update(&w->digest, data, len);
    w->offset += (off_t)(1U + name_len + 8U + len);
    return YS_FRAME_OK;
}
enum ys_frame_status ys_frame_writer_close(struct ys_frame_writer *w)
{
    unsigned char digest[YS_FRAME_DIGEST_LEN], len_field[8];
    unsigned char name_len_byte = (unsigned char)strlen(YS_FRAME_END_NAME);
    if (w->closed) return YS_FRAME_ERR_IO;
    ys_sha256_final(&w->digest, digest);
    encode_be64((uint64_t)YS_FRAME_DIGEST_LEN, len_field);
    if (!full_write(w->fd, &name_len_byte, 1U) ||
        !full_write(w->fd, YS_FRAME_END_NAME, name_len_byte) ||
        !full_write(w->fd, len_field, 8U) || !full_write(w->fd, digest, YS_FRAME_DIGEST_LEN))
        return YS_FRAME_ERR_IO;
    w->offset += (off_t)(1U + name_len_byte + 8U + YS_FRAME_DIGEST_LEN);
    w->closed = 1;
    return YS_FRAME_OK;
}
/* Exact pread; a short read here (bounds already checked by the caller) is
 * always YS_FRAME_ERR_IO, never an ordinary truncation. */
static int read_exact(int fd, off_t offset, void *buf, size_t len)
{
    unsigned char *p = buf;
    size_t got = 0;
    while (got < len) {
        ssize_t n = pread(fd, p + got, len - got, offset + (off_t)got);
        if (n < 0) { if (errno == EINTR) continue; return 0; }
        if (n == 0) return 0;
        got += (size_t)n;
    }
    return 1;
}
/* Regular file: st_size. Linux block device (the guest's input/export
 * disks; fstat's st_size is 0 there): BLKGETSIZE64. Anything else: refused. */
enum ys_frame_status ys_frame_descriptor_capacity(int fd, off_t *capacity_out)
{
    struct stat st;
    if (fstat(fd, &st) != 0) return YS_FRAME_ERR_IO;
    if (S_ISREG(st.st_mode)) { *capacity_out = st.st_size; return YS_FRAME_OK; }
#if defined(__linux__)
    if (S_ISBLK(st.st_mode)) {
        uint64_t bytes;
        if (ioctl(fd, BLKGETSIZE64, &bytes) != 0) return YS_FRAME_ERR_IO;
        *capacity_out = (off_t)bytes;
        return YS_FRAME_OK;
    }
#endif
    return YS_FRAME_ERR_IO;
}
enum ys_frame_status ys_frame_reader_open(struct ys_frame_reader *r, int fd, off_t capacity)
{
    unsigned char magic[YS_FRAME_MAGIC_LEN];
    r->fd = fd; r->offset = 0; r->done = 0;
    ys_sha256_init(&r->digest);
    r->total_size = capacity;
    if (r->total_size < (off_t)YS_FRAME_MAGIC_LEN) return YS_FRAME_ERR_TRUNCATED;
    if (!read_exact(fd, 0, magic, YS_FRAME_MAGIC_LEN)) return YS_FRAME_ERR_IO;
    if (memcmp(magic, YS_FRAME_MAGIC, YS_FRAME_MAGIC_LEN) != 0) return YS_FRAME_ERR_MAGIC;
    ys_sha256_update(&r->digest, magic, YS_FRAME_MAGIC_LEN);
    r->offset = (off_t)YS_FRAME_MAGIC_LEN;
    return YS_FRAME_OK;
}
/* Every remaining byte to total_size must be zero (R3.2). */
static enum ys_frame_status check_zero_tail(int fd, off_t offset, off_t total_size)
{
    unsigned char buf[4096];
    while (offset < total_size) {
        size_t want = (size_t)(total_size - offset), i;
        if (want > sizeof buf) want = sizeof buf;
        if (!read_exact(fd, offset, buf, want)) return YS_FRAME_ERR_IO;
        for (i = 0; i < want; i++)
            if (buf[i] != 0x00U) return YS_FRAME_ERR_TAIL;
        offset += (off_t)want;
    }
    return YS_FRAME_OK;
}
static enum ys_frame_status finish_end_record(struct ys_frame_reader *r, off_t content_offset,
                                               struct ys_frame_record *rec)
{
    unsigned char expected[YS_FRAME_DIGEST_LEN], observed[YS_FRAME_DIGEST_LEN];
    enum ys_frame_status tail_status;
    if (!read_exact(r->fd, content_offset, observed, YS_FRAME_DIGEST_LEN)) return YS_FRAME_ERR_IO;
    ys_sha256_final(&r->digest, expected);
    if (memcmp(expected, observed, YS_FRAME_DIGEST_LEN) != 0) return YS_FRAME_ERR_DIGEST;
    tail_status = check_zero_tail(r->fd, content_offset + YS_FRAME_DIGEST_LEN, r->total_size);
    if (tail_status != YS_FRAME_OK) return tail_status;
    rec->is_end = 1; rec->length = 0; r->done = 1;
    return YS_FRAME_OK;
}
enum ys_frame_status ys_frame_reader_next(struct ys_frame_reader *r, struct ys_frame_record *rec)
{
    unsigned char name_len_byte, len_field[8];
    uint64_t length;
    off_t content_offset;
    int is_end;
    rec->content = NULL; rec->length = 0; rec->name_len = 0; rec->is_end = 0;
    if (r->done) return YS_FRAME_ERR_IO;
    if (r->offset + 1 > r->total_size) return YS_FRAME_ERR_TRUNCATED;
    if (!read_exact(r->fd, r->offset, &name_len_byte, 1U)) return YS_FRAME_ERR_IO;
    if (r->offset + 1 + (off_t)name_len_byte > r->total_size) return YS_FRAME_ERR_TRUNCATED;
    if (name_len_byte > 0 && !read_exact(r->fd, r->offset + 1, rec->name, name_len_byte))
        return YS_FRAME_ERR_IO;
    rec->name[name_len_byte] = '\0'; rec->name_len = name_len_byte;
    if (r->offset + 1 + (off_t)name_len_byte + 8 > r->total_size) return YS_FRAME_ERR_TRUNCATED;
    if (!read_exact(r->fd, r->offset + 1 + name_len_byte, len_field, 8U)) return YS_FRAME_ERR_IO;
    length = decode_be64(len_field);
    content_offset = r->offset + 1 + name_len_byte + 8;
    if (length > (uint64_t)(r->total_size - content_offset)) return YS_FRAME_ERR_TRUNCATED;
    is_end = (name_len_byte == strlen(YS_FRAME_END_NAME) &&
              memcmp(rec->name, YS_FRAME_END_NAME, name_len_byte) == 0);
    if (is_end) {
        if (length != YS_FRAME_DIGEST_LEN) return YS_FRAME_ERR_DIGEST;
        return finish_end_record(r, content_offset, rec);
    }
    if (length > 0) {
        rec->content = malloc((size_t)length);
        if (rec->content == NULL) return YS_FRAME_ERR_IO;
        if (!read_exact(r->fd, content_offset, rec->content, (size_t)length)) {
            free(rec->content); rec->content = NULL;
            return YS_FRAME_ERR_IO;
        }
    }
    rec->length = length;
    ys_sha256_update(&r->digest, &name_len_byte, 1U);
    if (name_len_byte > 0) ys_sha256_update(&r->digest, rec->name, name_len_byte);
    ys_sha256_update(&r->digest, len_field, 8U);
    if (length > 0) ys_sha256_update(&r->digest, rec->content, (size_t)length);
    r->offset = content_offset + (off_t)length;
    return YS_FRAME_OK;
}

/* --- R5.2 / R8.1 record-name sets ------------------------------------------ */
struct fixed_names {
    const char *names[3];
    const char *indexed_prefix;
    size_t indexed_prefix_len;
    unsigned indexed_digits;
};
static const struct fixed_names INPUT_NAMES =
    { { "plan.json", "instruction", "verifier" }, "candidate/", 10U, 5U };
static const struct fixed_names EXPORT_NAMES =
    { { "report.json", "stdout", "stderr" }, "evidence/", 9U, 4U };
static const struct fixed_names *names_for(enum ys_record_set set)
{
    return (set == YS_RECORD_SET_INPUT) ? &INPUT_NAMES : &EXPORT_NAMES;
}
static int name_equals(const char *name, size_t len, const char *literal)
{
    size_t lit_len = strlen(literal);
    return len == lit_len && memcmp(name, literal, lit_len) == 0;
}
/* "<prefix><digits>", exactly `digits` decimal digits, zero-padded
 * (leading zeros required). 1 and *index_out on match, else 0. */
static int parse_indexed_name(const struct fixed_names *fn, const char *name, size_t len,
                               uint32_t *index_out)
{
    size_t i;
    uint32_t value = 0;
    if (len != fn->indexed_prefix_len + fn->indexed_digits) return 0;
    if (memcmp(name, fn->indexed_prefix, fn->indexed_prefix_len) != 0) return 0;
    for (i = 0; i < fn->indexed_digits; i++) {
        unsigned char c = (unsigned char)name[fn->indexed_prefix_len + i];
        if (c < '0' || c > '9') return 0;
        value = value * 10U + (uint32_t)(c - '0');
    }
    *index_out = value;
    return 1;
}
void ys_record_set_init(struct ys_record_set_state *state, enum ys_record_set set)
{
    state->set = set; state->step = 0; state->next_index = 0;
}
enum ys_frame_status ys_record_set_advance(struct ys_record_set_state *state, const char *name,
                                            size_t len, uint32_t *index_out)
{
    const struct fixed_names *fn = names_for(state->set);
    uint32_t index;
    *index_out = 0;
    if (state->step < 3U) {
        if (!name_equals(name, len, fn->names[state->step])) return YS_FRAME_ERR_NAME;
        state->step += 1U;
        if (state->step == 3U) state->next_index = 0;
        return YS_FRAME_OK;
    }
    if (!parse_indexed_name(fn, name, len, &index)) return YS_FRAME_ERR_NAME;
    if (index != state->next_index) return YS_FRAME_ERR_INDEX;
    state->next_index += 1U;
    *index_out = index;
    return YS_FRAME_OK;
}
enum ys_frame_status ys_record_set_finish(const struct ys_record_set_state *state)
{
    return (state->step >= 3U) ? YS_FRAME_OK : YS_FRAME_ERR_MISSING;
}

/* --- Strict UTF-8 and the preparation path range --------------------------- */
static int utf8_decode_one(const unsigned char *s, size_t len, size_t i, size_t *consumed,
                            uint32_t *cp)
{
    unsigned char b0 = s[i], b1, b2, b3, lo, hi;
    if (b0 < 0x80U) { *cp = b0; *consumed = 1; return 1; }
    if (b0 >= 0xC2U && b0 <= 0xDFU) {
        if (i + 1 >= len) return 0;
        b1 = s[i + 1];
        if (b1 < 0x80U || b1 > 0xBFU) return 0;
        *cp = ((uint32_t)(b0 & 0x1FU) << 6) | (uint32_t)(b1 & 0x3FU); *consumed = 2; return 1;
    }
    if (b0 >= 0xE0U && b0 <= 0xEFU) {
        lo = (b0 == 0xE0U) ? 0xA0U : 0x80U; hi = (b0 == 0xEDU) ? 0x9FU : 0xBFU;
        if (i + 2 >= len) return 0;
        b1 = s[i + 1]; b2 = s[i + 2];
        if (b1 < lo || b1 > hi || b2 < 0x80U || b2 > 0xBFU) return 0;
        *cp = ((uint32_t)(b0 & 0x0FU) << 12) | ((uint32_t)(b1 & 0x3FU) << 6) | (uint32_t)(b2 & 0x3FU);
        *consumed = 3; return 1;
    }
    if (b0 >= 0xF0U && b0 <= 0xF4U) {
        lo = (b0 == 0xF0U) ? 0x90U : 0x80U; hi = (b0 == 0xF4U) ? 0x8FU : 0xBFU;
        if (i + 3 >= len) return 0;
        b1 = s[i + 1]; b2 = s[i + 2]; b3 = s[i + 3];
        if (b1 < lo || b1 > hi || b2 < 0x80U || b2 > 0xBFU || b3 < 0x80U || b3 > 0xBFU) return 0;
        *cp = ((uint32_t)(b0 & 0x07U) << 18) | ((uint32_t)(b1 & 0x3FU) << 12) |
              ((uint32_t)(b2 & 0x3FU) << 6) | (uint32_t)(b3 & 0x3FU);
        *consumed = 4; return 1;
    }
    return 0;
}
static int is_control_codepoint(uint32_t cp)
{
    return cp <= 0x001FU || (cp >= 0x007FU && cp <= 0x009FU);
}
int ys_utf8_validate(const unsigned char *s, size_t len, int *has_control)
{
    size_t i = 0;
    *has_control = 0;
    while (i < len) {
        uint32_t cp;
        size_t consumed;
        if (!utf8_decode_one(s, len, i, &consumed, &cp)) return 0;
        if (is_control_codepoint(cp)) *has_control = 1;
        i += consumed;
    }
    return 1;
}
struct path_component { size_t offset, length; };
static int split_path_components(const unsigned char *path, size_t len,
                                  struct path_component *comps, size_t cap, size_t *count)
{
    size_t start = 0, n = 0, i;
    for (i = 0; i <= len; i++) {
        if (i == len || path[i] == '/') {
            if (n >= cap) return 0;
            comps[n].offset = start; comps[n].length = i - start; n++;
            start = i + 1;
        }
    }
    *count = n;
    return 1;
}
static int path_component_ok(const unsigned char *path, struct path_component c)
{
    unsigned char last;
    if (c.length == 0 || c.length > 255U) return 0;
    if (c.length == 1U && path[c.offset] == '.') return 0;
    if (c.length == 2U && path[c.offset] == '.' && path[c.offset + 1] == '.') return 0;
    if (c.length == 4U) {
        unsigned char b[4];
        size_t k;
        for (k = 0; k < 4U; k++) {
            unsigned char ch = path[c.offset + k];
            b[k] = (ch >= 'A' && ch <= 'Z') ? (unsigned char)(ch + 32) : ch;
        }
        if (b[0] == '.' && b[1] == 'g' && b[2] == 'i' && b[3] == 't') return 0;
    }
    last = path[c.offset + c.length - 1U];
    return last != '.' && last != ' ';
}
int ys_path_range_ok(const unsigned char *path, size_t len)
{
    struct path_component comps[64];
    size_t count, i;
    int has_control;
    if (len < 1U || len > 4096U) return 0;
    if (!ys_utf8_validate(path, len, &has_control) || has_control) return 0;
    for (i = 0; i < len; i++)
        if (path[i] == '\\') return 0;
    if (path[0] == '/') return 0;
    if (!split_path_components(path, len, comps, 64U, &count)) return 0;
    if (count < 1U || count > 64U) return 0;
    for (i = 0; i < count; i++)
        if (!path_component_ok(path, comps[i])) return 0;
    return 1;
}

/* --- PR 2: sandbox_guest_plan (R5.2), R5.5 materialization, R6.4 wiring,
 * R8.1 inventory ------------------------------------------------------- */
const char *const YS_PLAN_ARGV[7] = {
    YS_PLAN_ARGV0, "verify", "--candidate", "/sandbox/candidate", "--evidence",
    "/sandbox/evidence", NULL
};
const char *const YS_PLAN_ENVIRONMENT[5] = {
    "LANG=C", "LC_ALL=C", "PATH=/sandbox/tools", "TMPDIR=/sandbox/scratch", NULL
};
#define YS_PLAN_ARGV_JSON \
    "[\"" YS_PLAN_ARGV0 "\",\"verify\",\"--candidate\",\"/sandbox/candidate\"," \
    "\"--evidence\",\"/sandbox/evidence\"]"
#define YS_PLAN_ENVIRONMENT_JSON \
    "[\"LANG=C\",\"LC_ALL=C\",\"PATH=/sandbox/tools\",\"TMPDIR=/sandbox/scratch\"]"
const char *ys_plan_status_str(enum ys_plan_status status)
{
    static const char *const table[] = { "ok", "E_PLAN_SCHEMA", "E_PLAN_LIMIT", "E_PLAN_IO" };
    return ((unsigned)status < sizeof table / sizeof table[0]) ? table[status] : "E_PLAN_UNKNOWN";
}
/* Matches a literal byte string exactly at *pos. */
static int json_expect(const unsigned char *buf, size_t len, size_t *pos, const char *lit)
{
    size_t n = strlen(lit);
    if (*pos + n > len || memcmp(buf + *pos, lit, n) != 0) return 0;
    *pos += n;
    return 1;
}
static int hex_nibble(unsigned char c) { return (c >= '0' && c <= '9') ? (int)(c - '0') : -1; }
/* A `"`-delimited JSON string: decodes exactly the escapes
 * `json.dumps(ensure_ascii=False)` emits (\", \\, \b, \f, \n, \r, \t, or
 * \u00XX for the remaining C0 controls); any other escape, an unescaped
 * control byte, or invalid UTF-8 in a literal run is refused. */
static int json_parse_string(const unsigned char *buf, size_t len, size_t *pos,
                              unsigned char *out, size_t out_cap, size_t *out_len)
{
    size_t i = *pos, n = 0;
    int ok;
    if (i >= len || buf[i] != '"') return 0;
    i++;
    while (i < len && buf[i] != '"') {
        unsigned char c = buf[i];
        if (c < 0x20U) return 0;
        if (c == '\\') {
            i++;
            if (i >= len) return 0;
            switch (buf[i]) {
                case '"': c = '"'; i++; break;
                case '\\': c = '\\'; i++; break;
                case 'b': c = 0x08U; i++; break;
                case 'f': c = 0x0CU; i++; break;
                case 'n': c = 0x0AU; i++; break;
                case 'r': c = 0x0DU; i++; break;
                case 't': c = 0x09U; i++; break;
                case 'u': {
                    int hi, lo;
                    if (i + 4 >= len || buf[i + 1] != '0' || buf[i + 2] != '0') return 0;
                    hi = hex_nibble(buf[i + 3]); lo = hex_nibble(buf[i + 4]);
                    if (hi < 0 || lo < 0) return 0;
                    c = (unsigned char)(hi * 16 + lo);
                    if (c == 0x08U || c == 0x09U || c == 0x0AU || c == 0x0CU || c == 0x0DU ||
                        c > 0x1FU) return 0; /* those five use the short form instead */
                    i += 5;
                    break;
                }
                default: return 0;
            }
        } else {
            i++;
        }
        if (n >= out_cap) return 0;
        out[n++] = c;
    }
    if (i >= len || buf[i] != '"') return 0;
    *pos = i + 1;
    *out_len = n;
    ok = ys_utf8_validate(out, n, &(int){0});
    return ok;
}
static int json_parse_uint(const unsigned char *buf, size_t len, size_t *pos, uint64_t *out)
{
    size_t i = *pos;
    uint64_t v = 0;
    if (i >= len || buf[i] < '0' || buf[i] > '9') return 0;
    if (buf[i] == '0') {
        i++;
    } else {
        while (i < len && buf[i] >= '0' && buf[i] <= '9') {
            unsigned d = (unsigned)(buf[i] - '0');
            if (v > (UINT64_MAX - d) / 10U) return 0;
            v = v * 10U + d;
            i++;
        }
    }
    *pos = i;
    *out = v;
    return 1;
}
static int parse_hex64(const unsigned char *buf, size_t len, size_t *pos, unsigned char out[65])
{
    unsigned char s[65];
    size_t n, i;
    if (!json_parse_string(buf, len, pos, s, sizeof s, &n) || n != 64U) return 0;
    for (i = 0; i < 64U; i++) {
        unsigned char c = s[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return 0;
    }
    memcpy(out, s, 64U);
    out[64] = '\0';
    return 1;
}
static int parse_entry(const unsigned char *buf, size_t len, size_t *pos, struct ys_plan_entry *e)
{
    unsigned char kind[16], mode[8];
    size_t kind_len, mode_len;
    if (!json_expect(buf, len, pos, "{\"kind\":")) return 0;
    if (!json_parse_string(buf, len, pos, kind, sizeof kind, &kind_len)) return 0;
    if (kind_len == 4U && memcmp(kind, "file", 4U) == 0) e->is_file = 1;
    else if (kind_len == 9U && memcmp(kind, "directory", 9U) == 0) e->is_file = 0;
    else return 0;
    if (!json_expect(buf, len, pos, ",\"mode\":")) return 0;
    if (!json_parse_string(buf, len, pos, mode, sizeof mode, &mode_len) || mode_len != 4U) return 0;
    memcpy(e->mode, mode, 4U);
    e->mode[4] = '\0';
    if (e->is_file) {
        if (strcmp(e->mode, "0400") != 0 && strcmp(e->mode, "0500") != 0) return 0;
    } else if (strcmp(e->mode, "0500") != 0) {
        return 0;
    }
    if (!json_expect(buf, len, pos, ",\"path\":")) return 0;
    if (!json_parse_string(buf, len, pos, e->path, sizeof e->path, &e->path_len)) return 0;
    if (!ys_path_range_ok(e->path, e->path_len)) return 0;
    if (!json_expect(buf, len, pos, ",\"sha256\":")) return 0;
    if (e->is_file) {
        if (!parse_hex64(buf, len, pos, e->sha256_hex)) return 0;
    } else if (!json_expect(buf, len, pos, "null")) {
        return 0;
    }
    if (!json_expect(buf, len, pos, ",\"size_bytes\":")) return 0;
    if (e->is_file) {
        if (!json_parse_uint(buf, len, pos, &e->size_bytes)) return 0;
    } else if (!json_expect(buf, len, pos, "null")) {
        return 0;
    }
    return json_expect(buf, len, pos, "}");
}
enum ys_plan_status ys_plan_parse(const unsigned char *bytes, size_t len,
                                   struct ys_guest_plan *plan)
{
    size_t pos = 0, count = 0, cap = 0;
    struct ys_plan_entry *entries = NULL;
    memset(plan, 0, sizeof *plan);
    if (!json_expect(bytes, len, &pos, "{\"body\":{\"argv\":" YS_PLAN_ARGV_JSON ",\"entries\":["))
        goto fail;
    if (pos < len && bytes[pos] != ']') {
        for (;;) {
            struct ys_plan_entry e;
            memset(&e, 0, sizeof e);
            if (!parse_entry(bytes, len, &pos, &e)) goto fail;
            if (count == cap) {
                size_t new_cap = (cap == 0U) ? 8U : cap * 2U;
                struct ys_plan_entry *grown = realloc(entries, new_cap * sizeof *grown);
                if (grown == NULL) { free(entries); return YS_PLAN_ERR_IO; }
                entries = grown; cap = new_cap;
            }
            entries[count++] = e;
            if (pos < len && bytes[pos] == ',') { pos++; continue; }
            break;
        }
    }
    if (!json_expect(bytes, len, &pos,
                      "],\"environment\":" YS_PLAN_ENVIRONMENT_JSON ",\"instruction_sha256\":"))
        goto fail;
    if (!parse_hex64(bytes, len, &pos, plan->instruction_sha256_hex)) goto fail;
    if (!json_expect(bytes, len, &pos, ",\"limits\":{")) goto fail;
    {
        static const char *const names[9] = {
            "bandwidth_slice_us", "cpu_max", "cpu_max_burst", "output_inodes",
            "output_tmpfs_bytes", "pids_max", "scratch_bytes", "scratch_inodes",
            "tree_deadline_ms"
        };
        uint64_t *const slots[9] = {
            &plan->limits.bandwidth_slice_us, &plan->limits.cpu_max, &plan->limits.cpu_max_burst,
            &plan->limits.output_inodes, &plan->limits.output_tmpfs_bytes, &plan->limits.pids_max,
            &plan->limits.scratch_bytes, &plan->limits.scratch_inodes, &plan->limits.tree_deadline_ms
        };
        unsigned i;
        for (i = 0; i < 9U; i++) {
            if (i > 0U && !json_expect(bytes, len, &pos, ",")) goto fail;
            if (!json_expect(bytes, len, &pos, "\"") || !json_expect(bytes, len, &pos, names[i]) ||
                !json_expect(bytes, len, &pos, "\":")) goto fail;
            if (!json_parse_uint(bytes, len, &pos, slots[i])) goto fail;
        }
    }
    if (!json_expect(bytes, len, &pos, "},\"verifier_sha256\":")) goto fail;
    if (!parse_hex64(bytes, len, &pos, plan->verifier_sha256_hex)) goto fail;
    if (!json_expect(bytes, len, &pos, "},\"kind\":\"sandbox_guest_plan\",\"schema_version\":1}\n"))
        goto fail;
    if (pos != len) goto fail;
    plan->entries = entries;
    plan->entry_count = count;
    return YS_PLAN_OK;
fail:
    free(entries);
    return YS_PLAN_ERR_SCHEMA;
}
void ys_plan_free(struct ys_guest_plan *plan)
{
    free(plan->entries);
    plan->entries = NULL;
    plan->entry_count = 0;
}
/* Splits `path` into its parent directory and leaf component, walking from
 * `dirfd` one component at a time (never handing the kernel a long
 * concatenated string): a 4,096-byte, 64-component candidate path easily
 * exceeds PATH_MAX (1024-4096 depending on platform) as one string even
 * though every individual component is far under the 255-byte limit.
 * Returns an fd for the parent (which the caller must close unless it
 * equals `dirfd`, meaning `path` had no parent components) with `leaf` set
 * to the final component, or -1 on any error. */
static int open_parent_dir(int dirfd, const unsigned char *path, size_t path_len,
                            char *leaf, size_t leaf_cap)
{
    int cur = dirfd, opened = 0;
    size_t start = 0, i;
    for (i = 0; i <= path_len; i++) {
        if (i != path_len && path[i] != '/') continue;
        {
            size_t clen = i - start;
            if (i == path_len) {
                if (clen >= leaf_cap) { if (opened) (void)close(cur); return -1; }
                memcpy(leaf, path + start, clen);
                leaf[clen] = '\0';
                return cur;
            }
            {
                char comp[256];
                int next;
                if (clen >= sizeof comp) { if (opened) (void)close(cur); return -1; }
                memcpy(comp, path + start, clen);
                comp[clen] = '\0';
                next = openat(cur, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
                if (opened) (void)close(cur);
                if (next < 0) return -1;
                cur = next; opened = 1;
            }
        }
        start = i + 1;
    }
    return -1;
}
/* Directories are created 0700 (temporarily writable, so a later sibling
 * or child entry can still be created inside one) and tightened to their
 * manifest mode 0500 only in a second pass over the same list, after every
 * file is written; a file needs no such deferral since content is written
 * through the fd this function itself just opened, never a later create. */
enum ys_plan_status ys_plan_materialize(int dirfd, uid_t uid, gid_t gid,
                                         const struct ys_guest_plan *plan,
                                         const unsigned char *const *file_contents,
                                         const size_t *file_lengths)
{
    size_t i, fi = 0;
    for (i = 0; i < plan->entry_count; i++) {
        const struct ys_plan_entry *e = &plan->entries[i];
        char leaf[256];
        int pfd = open_parent_dir(dirfd, e->path, e->path_len, leaf, sizeof leaf);
        if (pfd < 0) return YS_PLAN_ERR_IO;
        if (!e->is_file) {
            int rc = (mkdirat(pfd, leaf, 0700) == 0) && (fchownat(pfd, leaf, uid, gid, 0) == 0);
            if (pfd != dirfd) (void)close(pfd);
            if (!rc) return YS_PLAN_ERR_IO;
            continue;
        }
        {
            size_t flen = file_lengths[fi];
            const unsigned char *data = file_contents[fi];
            unsigned char digest[32];
            char hex[65];
            int fd;
            size_t written = 0;
            mode_t mode;
            if (flen != e->size_bytes) { if (pfd != dirfd) (void)close(pfd); return YS_PLAN_ERR_SCHEMA; }
            ys_sha256_bytes(data, flen, digest);
            ys_hex_encode(digest, sizeof digest, hex);
            if (memcmp(hex, e->sha256_hex, 64U) != 0) {
                if (pfd != dirfd) (void)close(pfd);
                return YS_PLAN_ERR_SCHEMA;
            }
            fd = openat(pfd, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
            if (pfd != dirfd) (void)close(pfd);
            if (fd < 0) return YS_PLAN_ERR_IO;
            while (written < flen) {
                ssize_t n = write(fd, data + written, flen - written);
                if (n < 0) { if (errno == EINTR) continue; (void)close(fd); return YS_PLAN_ERR_IO; }
                written += (size_t)n;
            }
            if (fchown(fd, uid, gid) != 0) { (void)close(fd); return YS_PLAN_ERR_IO; }
            mode = (strcmp(e->mode, "0500") == 0) ? (mode_t)0500 : (mode_t)0400;
            if (fchmod(fd, mode) != 0) { (void)close(fd); return YS_PLAN_ERR_IO; }
            if (close(fd) != 0) return YS_PLAN_ERR_IO;
            fi++;
        }
    }
    for (i = 0; i < plan->entry_count; i++) {
        const struct ys_plan_entry *e = &plan->entries[i];
        char leaf[256];
        int pfd, rc;
        if (e->is_file) continue;
        pfd = open_parent_dir(dirfd, e->path, e->path_len, leaf, sizeof leaf);
        if (pfd < 0) return YS_PLAN_ERR_IO;
        rc = fchmodat(pfd, leaf, 0500, 0);
        if (pfd != dirfd) (void)close(pfd);
        if (rc != 0) return YS_PLAN_ERR_IO;
    }
    return YS_PLAN_OK;
}
#ifdef YSTACK_TEST_FAULT_INJECT
int ys_test_close_all_fail = 0;
#endif
/* Walks the real descriptor table (Linux /proc/self/fd, Darwin /dev/fd;
 * never a numeric guess), calling visit(fd, ctx) per open fd >= lowfd
 * (excluding the walk's own dir fd). 1 if complete, 0 if the directory
 * could not be opened or a readdir() itself failed (errno-checked per
 * call): either way the caller cannot trust it saw every descriptor. */
int ys_walk_fds(int lowfd, void (*visit)(int fd, void *ctx), void *ctx)
{
#if defined(__linux__)
    static const char *const fd_dir = "/proc/self/fd";
#else
    static const char *const fd_dir = "/dev/fd";
#endif
    DIR *stream = opendir(fd_dir);
    int stream_fd;
    struct dirent *entry;
    if (stream == NULL) return 0;
    stream_fd = dirfd(stream);
    for (;;) {
        int number;
        char *end;
        errno = 0;
        entry = readdir(stream);
        if (entry == NULL) {
            if (errno != 0) { (void)closedir(stream); return 0; }
            break;
        }
        if (entry->d_name[0] < '0' || entry->d_name[0] > '9') continue;
        number = (int)strtol(entry->d_name, &end, 10);
        if (end == entry->d_name || *end != '\0') continue;
        if (number < lowfd || (stream_fd >= 0 && number == stream_fd)) continue;
        visit(number, ctx);
    }
    (void)closedir(stream);
    return 1;
}
static void close_visitor(int fd, void *ctx) { (void)ctx; (void)close(fd); }
/* Closes every open descriptor >= lowfd, exhaustively, or fails (1/0): a
 * capped numeric sweep is not exhaustive and a lowered rlimit never closes
 * an fd already open past it, so there is no sweep fallback. Linux:
 * close_range, the one atomic exhaustive primitive. Darwin (this harness's
 * own build only; the guest is Linux-only): ys_walk_fds. Neither falls
 * back to the other. */
static int close_all_from(int lowfd)
{
#ifdef YSTACK_TEST_FAULT_INJECT
    if (ys_test_close_all_fail) return 0;
#endif
#if defined(__linux__)
#if defined(SYS_close_range)
    return syscall(SYS_close_range, (unsigned)lowfd, ~0U, 0U) == 0;
#else
    (void)lowfd;
    return 0; /* the pinned kernel's headers must define close_range */
#endif
#elif defined(__APPLE__)
    return ys_walk_fds(lowfd, close_visitor, NULL);
#else
    (void)lowfd;
    return 0;
#endif
}
void ys_exec(const char *const *argv, const char *const *envp, int instruction_fd,
             int stdout_fd, int stderr_fd)
{
    int in_fd, out_fd, err_fd;
    /* Each source is preserved on its own fresh fd (>=3) before any dup2
     * into 0/1/2: a caller-supplied overlap (e.g. stdout_fd == 0, the
     * instruction's own destination) would otherwise have its source
     * clobbered by an earlier dup2 in this same call, silently wiring the
     * wrong stream. F_DUPFD_CLOEXEC also keeps a temporary from surviving
     * a failed execve past close_all_from below. */
    in_fd = fcntl(instruction_fd, F_DUPFD_CLOEXEC, 3);
    out_fd = fcntl(stdout_fd, F_DUPFD_CLOEXEC, 3);
    err_fd = fcntl(stderr_fd, F_DUPFD_CLOEXEC, 3);
    if (in_fd < 0 || out_fd < 0 || err_fd < 0) _exit(126);
    if (dup2(in_fd, 0) < 0 || dup2(out_fd, 1) < 0 || dup2(err_fd, 2) < 0) _exit(126);
    (void)close(in_fd); (void)close(out_fd); (void)close(err_fd);
    if (!close_all_from(3)) _exit(126); /* cannot confirm every descriptor is closed */
    execve(argv[0], (char *const *)(const void *)argv, (char *const *)(const void *)envp);
    _exit(127);
}
#ifdef YSTACK_TEST_FAULT_INJECT
size_t ys_test_readdir_fail_at = 0;
#endif
struct evidence_row { char *name; ino_t ino; };
static int cmp_evidence_row(const void *a, const void *b)
{
    const struct evidence_row *ra = a, *rb = b;
    return strcmp(ra->name, rb->name);
}
enum ys_plan_status ys_evidence_inventory(int dirfd, char ***names_out, size_t *count_out)
{
    DIR *dh;
    struct dirent *de;
    struct evidence_row *rows = NULL;
    size_t count = 0, cap = 0, i;
    char **names;
    int refused = 0;
    dh = fdopendir(dirfd);
    if (dh == NULL) return YS_PLAN_ERR_IO;
    for (;;) {
        struct stat st;
        errno = 0;
#ifdef YSTACK_TEST_FAULT_INJECT
        if (ys_test_readdir_fail_at != 0 && --ys_test_readdir_fail_at == 0) {
            de = NULL;
            errno = ENOMEM;
        } else {
            de = readdir(dh);
        }
#else
        de = readdir(dh);
#endif
        if (de == NULL) {
            if (errno != 0) goto io_fail; /* a real readdir() failure, not end-of-directory */
            break;
        }
        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0) continue;
        if (fstatat(dirfd, de->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) goto io_fail;
        if (!S_ISREG(st.st_mode)) continue;
        if (count == cap) {
            size_t nc = (cap == 0U) ? 8U : cap * 2U;
            struct evidence_row *grown = realloc(rows, nc * sizeof *grown);
            if (grown == NULL) goto io_fail;
            rows = grown; cap = nc;
        }
        rows[count].name = strdup(de->d_name);
        if (rows[count].name == NULL) goto io_fail;
        rows[count].ino = st.st_ino;
        if (st.st_nlink != (nlink_t)1) refused = 1;
        count++;
    }
    closedir(dh);
    qsort(rows, count, sizeof *rows, cmp_evidence_row);
    for (i = 0; i + 1 < count && !refused; i++)
        if (rows[i].ino == rows[i + 1].ino) refused = 1;
    if (refused) {
        for (i = 0; i < count; i++) free(rows[i].name);
        free(rows);
        return YS_PLAN_ERR_SCHEMA;
    }
    names = malloc((count == 0U ? 1U : count) * sizeof *names);
    if (names == NULL) {
        for (i = 0; i < count; i++) free(rows[i].name);
        free(rows);
        return YS_PLAN_ERR_IO;
    }
    for (i = 0; i < count; i++) names[i] = rows[i].name;
    free(rows);
    *names_out = names;
    *count_out = count;
    return YS_PLAN_OK;
io_fail:
    closedir(dh);
    for (i = 0; i < count; i++) free(rows[i].name);
    free(rows);
    return YS_PLAN_ERR_IO;
}