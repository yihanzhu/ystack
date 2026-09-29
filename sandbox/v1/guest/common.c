#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
/* See common.h. */
#include "common.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__linux__)
#include <linux/fs.h>
#include <sys/ioctl.h>
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