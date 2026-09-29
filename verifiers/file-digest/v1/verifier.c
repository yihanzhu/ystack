#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif

/*
 * Fixed file-digest verifier (ystack #437).
 *
 * A straight line: check argv and environment, read and frame the
 * instruction on fd 0, validate the path, walk the candidate without
 * following links, classify before opening, read bounded bytes, hash,
 * compare, and write one canonical payload exclusively. See
 * work/fixed-file-digest-verifier/spec.md for the full contract; this
 * file implements it and nothing else. It is inactive: nothing here
 * runs it against a real sandbox, accepts its digest, or grants it
 * authority.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

extern char **environ;

#ifndef YSTACK_SANDBOX_ROOT
#define YSTACK_SANDBOX_ROOT "/sandbox"
#endif

#define CANDIDATE_ROOT YSTACK_SANDBOX_ROOT "/candidate"
#define EVIDENCE_DIR YSTACK_SANDBOX_ROOT "/evidence"
#define EVIDENCE_RESULT_PATH YSTACK_SANDBOX_ROOT "/evidence/file-digest-result.json"
#define TOOLS_DIR YSTACK_SANDBOX_ROOT "/tools"
#define SCRATCH_DIR YSTACK_SANDBOX_ROOT "/scratch"
#define EXPECTED_LANG "LANG=C"
#define EXPECTED_LC_ALL "LC_ALL=C"
#define EXPECTED_PATH "PATH=" TOOLS_DIR
#define EXPECTED_TMPDIR "TMPDIR=" SCRATCH_DIR

#define INSTRUCTION_HEADER "ystack.file-digest-instruction.v1"
#define INSTRUCTION_READ_LIMIT 4209U
#define MAX_PATH_BYTES 4096U
#define MAX_PATH_COMPONENTS 64U
#define MAX_CANDIDATE_BYTES 1048576U
#define CANDIDATE_READ_LIMIT (MAX_CANDIDATE_BYTES + 1U)
#define PAYLOAD_BUFFER_SIZE 20000U

/* ---------------------------------------------------------------------- */
/* SHA-256 (FIPS 180-4), streaming over a context.                        */

struct sha256_ctx {
    uint32_t state[8];
    uint64_t total_bits;
    unsigned char buffer[64];
    size_t buffered;
};

static const uint32_t SHA256_K[64] = {
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U,
    0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
    0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
    0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
    0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
    0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
    0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
    0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
    0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
    0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
    0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U,
    0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
    0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U,
    0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
    0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
    0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U
};

static uint32_t rotr32(uint32_t value, unsigned bits)
{
    return (value >> bits) | (value << (32U - bits));
}

static void sha256_compress(struct sha256_ctx *ctx, const unsigned char block[64])
{
    uint32_t w[64];
    uint32_t a, b, c, d, e, f, g, h;
    unsigned i;

    for (i = 0; i < 16; i++) {
        w[i] = ((uint32_t)block[i * 4] << 24) | ((uint32_t)block[i * 4 + 1] << 16) |
               ((uint32_t)block[i * 4 + 2] << 8) | (uint32_t)block[i * 4 + 3];
    }
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
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }

    ctx->state[0] += a; ctx->state[1] += b; ctx->state[2] += c; ctx->state[3] += d;
    ctx->state[4] += e; ctx->state[5] += f; ctx->state[6] += g; ctx->state[7] += h;
}

static void sha256_init(struct sha256_ctx *ctx)
{
    ctx->state[0] = 0x6a09e667U; ctx->state[1] = 0xbb67ae85U;
    ctx->state[2] = 0x3c6ef372U; ctx->state[3] = 0xa54ff53aU;
    ctx->state[4] = 0x510e527fU; ctx->state[5] = 0x9b05688cU;
    ctx->state[6] = 0x1f83d9abU; ctx->state[7] = 0x5be0cd19U;
    ctx->total_bits = 0;
    ctx->buffered = 0;
}

static void sha256_update(struct sha256_ctx *ctx, const unsigned char *data, size_t len)
{
    ctx->total_bits += (uint64_t)len * 8U;
    while (len > 0) {
        size_t take = 64U - ctx->buffered;
        if (take > len) take = len;
        memcpy(ctx->buffer + ctx->buffered, data, take);
        ctx->buffered += take;
        data += take;
        len -= take;
        if (ctx->buffered == 64U) {
            sha256_compress(ctx, ctx->buffer);
            ctx->buffered = 0;
        }
    }
}

static void sha256_final(struct sha256_ctx *ctx, unsigned char out[32])
{
    unsigned char pad[72];
    size_t pad_len;
    uint64_t total_bits = ctx->total_bits;
    unsigned i;

    pad[0] = 0x80;
    if (ctx->buffered < 56U) {
        pad_len = 56U - ctx->buffered;
    } else {
        pad_len = 120U - ctx->buffered;
    }
    for (i = 1; i < pad_len; i++) pad[i] = 0x00;
    sha256_update(ctx, pad, pad_len);
    ctx->total_bits = total_bits;

    for (i = 0; i < 8; i++) {
        pad[i] = (unsigned char)(total_bits >> (56U - 8U * i));
    }
    /* ctx->buffered is now exactly 56: append the 8-byte big-endian bit
     * length directly and compress the final block. */
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

static void sha256_bytes(const unsigned char *data, size_t len, unsigned char out[32])
{
    struct sha256_ctx ctx;
    sha256_init(&ctx);
    sha256_update(&ctx, data, len);
    sha256_final(&ctx, out);
}

static void hex_encode(const unsigned char *in, size_t len, char *out)
{
    static const char digits[] = "0123456789abcdef";
    size_t i;
    for (i = 0; i < len; i++) {
        out[i * 2] = digits[(in[i] >> 4) & 0x0FU];
        out[i * 2 + 1] = digits[in[i] & 0x0FU];
    }
    out[len * 2] = '\0';
}

/* ---------------------------------------------------------------------- */
/* R2. Invocation and environment.                                         */

static int argv_ok(int argc, char **argv)
{
    if (argc != 6) return 0;
    if (strcmp(argv[1], "verify") != 0) return 0;
    if (strcmp(argv[2], "--candidate") != 0) return 0;
    if (strcmp(argv[3], CANDIDATE_ROOT) != 0) return 0;
    if (strcmp(argv[4], "--evidence") != 0) return 0;
    if (strcmp(argv[5], EVIDENCE_DIR) != 0) return 0;
    return 1;
}

static int environment_ok(char **envp)
{
    static const char *const expected[4] = {
        EXPECTED_LANG, EXPECTED_LC_ALL, EXPECTED_PATH, EXPECTED_TMPDIR
    };
    int seen[4] = { 0, 0, 0, 0 };
    size_t count = 0;
    char **e;

    for (e = envp; *e != NULL; e++) {
        int i;
        int matched = 0;
        count++;
        for (i = 0; i < 4; i++) {
            if (!seen[i] && strcmp(*e, expected[i]) == 0) {
                seen[i] = 1;
                matched = 1;
                break;
            }
        }
        if (!matched) return 0;
    }
    if (count != 4U) return 0;
    return seen[0] && seen[1] && seen[2] && seen[3];
}

static void refuse_invocation(const char *code)
{
    (void)dprintf(STDERR_FILENO, "%s\n", code);
    exit(64);
}

/* ---------------------------------------------------------------------- */
/* UTF-8 decoding (shortest form only) for R3.3 and R4.                    */

static int utf8_decode_one(const unsigned char *s, size_t len, size_t i, size_t *consumed,
                            uint32_t *cp)
{
    unsigned char b0 = s[i];

    if (b0 < 0x80U) {
        *cp = b0;
        *consumed = 1;
        return 1;
    }
    if (b0 >= 0xC2U && b0 <= 0xDFU) {
        unsigned char b1;
        if (i + 1 >= len) return 0;
        b1 = s[i + 1];
        if (b1 < 0x80U || b1 > 0xBFU) return 0;
        *cp = ((uint32_t)(b0 & 0x1FU) << 6) | (uint32_t)(b1 & 0x3FU);
        *consumed = 2;
        return 1;
    }
    if (b0 >= 0xE0U && b0 <= 0xEFU) {
        unsigned char b1, b2;
        unsigned char lo = (b0 == 0xE0U) ? 0xA0U : 0x80U;
        unsigned char hi = (b0 == 0xEDU) ? 0x9FU : 0xBFU;
        if (i + 2 >= len) return 0;
        b1 = s[i + 1];
        b2 = s[i + 2];
        if (b1 < lo || b1 > hi) return 0;
        if (b2 < 0x80U || b2 > 0xBFU) return 0;
        *cp = ((uint32_t)(b0 & 0x0FU) << 12) | ((uint32_t)(b1 & 0x3FU) << 6) |
              (uint32_t)(b2 & 0x3FU);
        *consumed = 3;
        return 1;
    }
    if (b0 >= 0xF0U && b0 <= 0xF4U) {
        unsigned char b1, b2, b3;
        unsigned char lo = (b0 == 0xF0U) ? 0x90U : 0x80U;
        unsigned char hi = (b0 == 0xF4U) ? 0x8FU : 0xBFU;
        if (i + 3 >= len) return 0;
        b1 = s[i + 1];
        b2 = s[i + 2];
        b3 = s[i + 3];
        if (b1 < lo || b1 > hi) return 0;
        if (b2 < 0x80U || b2 > 0xBFU) return 0;
        if (b3 < 0x80U || b3 > 0xBFU) return 0;
        *cp = ((uint32_t)(b0 & 0x07U) << 18) | ((uint32_t)(b1 & 0x3FU) << 12) |
              ((uint32_t)(b2 & 0x3FU) << 6) | (uint32_t)(b3 & 0x3FU);
        *consumed = 4;
        return 1;
    }
    return 0;
}

static int is_control_codepoint(uint32_t cp)
{
    if (cp <= 0x001FU) return 1;
    if (cp >= 0x007FU && cp <= 0x009FU) return 1;
    return 0;
}

static int utf8_validate(const unsigned char *s, size_t len, int *has_control)
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

/* ---------------------------------------------------------------------- */
/* R4. Path rules.                                                         */

struct component {
    size_t offset;
    size_t length;
};

static int split_components(const unsigned char *path, size_t len, struct component *comps,
                             size_t *count)
{
    size_t start = 0;
    size_t n = 0;
    size_t i;

    for (i = 0; i <= len; i++) {
        if (i == len || path[i] == '/') {
            if (n >= MAX_PATH_COMPONENTS) return 0;
            comps[n].offset = start;
            comps[n].length = i - start;
            n++;
            start = i + 1;
        }
    }
    *count = n;
    return 1;
}

static int component_ok(const unsigned char *path, struct component c)
{
    unsigned char last;

    if (c.length == 0) return 0;
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
    if (last == '.' || last == ' ') return 0;
    return 1;
}

static int path_r4_ok(const unsigned char *path, size_t len, int has_control,
                       struct component *comps, size_t *count)
{
    size_t i;

    if (len < 1U || len > MAX_PATH_BYTES) return 0;
    if (has_control) return 0;
    for (i = 0; i < len; i++) {
        if (path[i] == '\\') return 0;
    }
    if (path[0] == '/') return 0;
    if (!split_components(path, len, comps, count)) return 0;
    if (*count < 1U || *count > MAX_PATH_COMPONENTS) return 0;
    for (i = 0; i < *count; i++) {
        if (!component_ok(path, comps[i])) return 0;
    }
    return 1;
}

/* ---------------------------------------------------------------------- */
/* Payload assembly (R6).                                                  */

static size_t append_bytes(unsigned char *out, size_t pos, const void *data, size_t len)
{
    memcpy(out + pos, data, len);
    return pos + len;
}

static size_t append_str(unsigned char *out, size_t pos, const char *s)
{
    return append_bytes(out, pos, s, strlen(s));
}

static size_t append_json_escaped(unsigned char *out, size_t pos, const unsigned char *s,
                                   size_t len)
{
    size_t i;
    for (i = 0; i < len; i++) {
        if (s[i] == '"') {
            out[pos++] = '\\';
            out[pos++] = '"';
        } else {
            out[pos++] = s[i];
        }
    }
    return pos;
}

/*
 * Builds the exact canonical `jq -S -c` bytes for the payload and returns
 * its length. `reason_id` is NULL for match/mismatch. `check_path`/
 * `check_path_len`/`expected_hex` are only used when `have_check` is set.
 * `instruction_hex` is NULL when I is null. `observed_hex`/`observed_size`
 * are only used when `have_observed` is set.
 */
static size_t build_payload(unsigned char *out, const char *outcome, const char *reason_id,
                             int have_check, const unsigned char *check_path,
                             size_t check_path_len, const char *expected_hex,
                             const char *instruction_hex, int have_observed,
                             const char *observed_hex, size_t observed_size)
{
    size_t pos = 0;
    char number[32];

    pos = append_str(out, pos, "{\"body\":{\"check\":");
    if (have_check) {
        pos = append_str(out, pos, "{\"expected_sha256\":\"");
        pos = append_str(out, pos, expected_hex);
        pos = append_str(out, pos, "\",\"path\":\"");
        pos = append_json_escaped(out, pos, check_path, check_path_len);
        pos = append_str(out, pos, "\"}");
    } else {
        pos = append_str(out, pos, "null");
    }

    pos = append_str(out, pos, ",\"instruction_sha256\":");
    if (instruction_hex != NULL) {
        pos = append_str(out, pos, "\"");
        pos = append_str(out, pos, instruction_hex);
        pos = append_str(out, pos, "\"");
    } else {
        pos = append_str(out, pos, "null");
    }

    pos = append_str(out, pos, ",\"observed\":");
    if (have_observed) {
        pos = append_str(out, pos, "{\"sha256\":\"");
        pos = append_str(out, pos, observed_hex);
        pos = append_str(out, pos, "\",\"size_bytes\":");
        (void)snprintf(number, sizeof number, "%zu", observed_size);
        pos = append_str(out, pos, number);
        pos = append_str(out, pos, "}");
    } else {
        pos = append_str(out, pos, "null");
    }

    pos = append_str(out, pos, ",\"outcome\":\"");
    pos = append_str(out, pos, outcome);
    pos = append_str(out, pos, "\",\"reason_id\":");
    if (reason_id != NULL) {
        pos = append_str(out, pos, "\"");
        pos = append_str(out, pos, reason_id);
        pos = append_str(out, pos, "\"");
    } else {
        pos = append_str(out, pos, "null");
    }

    pos = append_str(out, pos,
        "},\"id\":\"file-digest-payload\",\"kind\":\"file_digest_verifier_payload\","
        "\"schema_version\":1}\n");
    return pos;
}

static void die_output(const char *code)
{
    (void)dprintf(STDERR_FILENO, "%s\n", code);
    exit(73);
}

static void write_payload(const unsigned char *bytes, size_t len)
{
    int fd = open(EVIDENCE_RESULT_PATH, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0400);
    size_t written = 0;

    if (fd < 0) {
        if (errno == EEXIST) die_output("E_OUTPUT_COLLISION");
        die_output("E_OUTPUT");
    }
    while (written < len) {
        ssize_t n = write(fd, bytes + written, len - written);
        if (n < 0) {
            if (errno == EINTR) continue;
            (void)close(fd);
            die_output("E_OUTPUT");
        }
        written += (size_t)n;
    }
    if (fsync(fd) != 0) {
        (void)close(fd);
        die_output("E_OUTPUT");
    }
    if (close(fd) != 0) {
        die_output("E_OUTPUT");
    }
    exit(0);
}

/* ---------------------------------------------------------------------- */
/* R5. Reading the candidate file.                                        */

#if defined(__APPLE__)
#define YSTACK_MTIME_NSEC(st) ((st).st_mtimespec.tv_nsec)
#else
#define YSTACK_MTIME_NSEC(st) ((st).st_mtim.tv_nsec)
#endif

static unsigned char candidate_buffer[CANDIDATE_READ_LIMIT];

static const char *read_candidate(const unsigned char *path, size_t path_len,
                                   struct component *comps, size_t comp_count,
                                   int *have_observed, char *observed_hex,
                                   size_t *observed_size)
{
    int rootfd;
    int dirfd;
    size_t idx;
    const char *reason = NULL;

    *have_observed = 0;

    rootfd = open(CANDIDATE_ROOT, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (rootfd < 0) return "file.read-error";

    dirfd = rootfd;
    for (idx = 0; idx < comp_count && reason == NULL; idx++) {
        char comp[MAX_PATH_BYTES + 1U];
        int is_final = (idx + 1U == comp_count);
        struct stat st;

        memcpy(comp, path + comps[idx].offset, comps[idx].length);
        comp[comps[idx].length] = '\0';

        if (fstatat(dirfd, comp, &st, AT_SYMLINK_NOFOLLOW) != 0) {
            reason = (errno == ENOENT) ? "file.missing" : "file.read-error";
            break;
        }
        if (S_ISLNK(st.st_mode)) {
            reason = "file.symlink";
            break;
        }
        if (!is_final) {
            int newfd;
            if (!S_ISDIR(st.st_mode)) {
                reason = "file.not-regular";
                break;
            }
            newfd = openat(dirfd, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
            if (newfd < 0) {
                reason = (errno == ENOENT) ? "file.missing" : "file.read-error";
                break;
            }
            if (dirfd != rootfd) (void)close(dirfd);
            dirfd = newfd;
        } else {
            int filefd;
            struct stat opened;
            struct stat reread;
            size_t total = 0;
            int read_error = 0;

            if (!S_ISREG(st.st_mode)) {
                reason = "file.not-regular";
                break;
            }
            if ((uint64_t)st.st_size > (uint64_t)MAX_CANDIDATE_BYTES) {
                reason = "file.oversize";
                break;
            }

            filefd = openat(dirfd, comp, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY);
            if (filefd < 0) {
                reason = "file.read-error";
                break;
            }
            if (fstat(filefd, &opened) != 0) {
                (void)close(filefd);
                reason = "file.read-error";
                break;
            }
            if (opened.st_dev != st.st_dev || opened.st_ino != st.st_ino ||
                !S_ISREG(opened.st_mode) || opened.st_size != st.st_size) {
                (void)close(filefd);
                reason = "file.changed";
                break;
            }

            {
                /*
                 * Bound the read by this file's own recorded size plus one,
                 * not by the fixed buffer capacity: a file that grows after
                 * classification must be caught as file.size-mismatch (or
                 * file.changed on re-fstat) rather than read past its
                 * expected length. opened.st_size is at most
                 * MAX_CANDIDATE_BYTES (checked above via st.st_size, which
                 * opened.st_size was just confirmed to equal), so
                 * read_limit never exceeds CANDIDATE_READ_LIMIT.
                 */
                size_t read_limit = (size_t)opened.st_size + 1U;
                while (total < read_limit) {
                    ssize_t r = read(filefd, candidate_buffer + total, read_limit - total);
                    if (r < 0) {
                        if (errno == EINTR) continue;
                        read_error = 1;
                        break;
                    }
                    if (r == 0) break;
                    total += (size_t)r;
                }
            }
            if (read_error) {
                (void)close(filefd);
                reason = "file.read-error";
                break;
            }
            if (total != (size_t)opened.st_size) {
                (void)close(filefd);
                reason = "file.size-mismatch";
                break;
            }
            if (fstat(filefd, &reread) != 0) {
                (void)close(filefd);
                reason = "file.read-error";
                break;
            }
            (void)close(filefd);
            if (reread.st_dev != opened.st_dev || reread.st_ino != opened.st_ino ||
                reread.st_size != opened.st_size || reread.st_mtime != opened.st_mtime ||
                YSTACK_MTIME_NSEC(reread) != YSTACK_MTIME_NSEC(opened)) {
                reason = "file.changed";
                break;
            }

            {
                unsigned char digest[32];
                sha256_bytes(candidate_buffer, total, digest);
                hex_encode(digest, sizeof digest, observed_hex);
                *observed_size = total;
                *have_observed = 1;
            }
        }
    }

    if (dirfd != rootfd) (void)close(dirfd);
    (void)close(rootfd);
    (void)path_len;
    return reason;
}

/* ---------------------------------------------------------------------- */
/* R3. Instruction transport and framing.                                 */

static unsigned char instruction_buffer[INSTRUCTION_READ_LIMIT];

int main(int argc, char **argv)
{
    struct stat fd0_stat;
    size_t n = 0;
    const char *outcome = "refused";
    const char *reason_id = NULL;
    int have_check = 0;
    unsigned char check_path[MAX_PATH_BYTES];
    size_t check_path_len = 0;
    char expected_hex[65];
    char instruction_hex_storage[65];
    const char *instruction_hex = NULL;
    int have_observed = 0;
    char observed_hex[65];
    size_t observed_size = 0;
    unsigned char payload_out[PAYLOAD_BUFFER_SIZE];
    size_t payload_len;

    if (!argv_ok(argc, argv)) refuse_invocation("E_USAGE");
    if (!environment_ok(environ)) refuse_invocation("E_ENVIRONMENT");

    if (fstat(0, &fd0_stat) != 0 || !S_ISREG(fd0_stat.st_mode)) {
        outcome = "refused";
        reason_id = "instruction.transport-rejected";
        goto write_result;
    }

    for (;;) {
        ssize_t r;
        if (n == INSTRUCTION_READ_LIMIT) break;
        r = read(0, instruction_buffer + n, INSTRUCTION_READ_LIMIT - n);
        if (r < 0) {
            if (errno == EINTR) continue;
            outcome = "refused";
            reason_id = "instruction.transport-rejected";
            goto write_result;
        }
        if (r == 0) break;
        n += (size_t)r;
    }

    if (n == INSTRUCTION_READ_LIMIT) {
        outcome = "refused";
        reason_id = "instruction.oversize";
        goto write_result;
    }

    {
        unsigned char digest[32];
        sha256_bytes(instruction_buffer, n, digest);
        hex_encode(digest, sizeof digest, instruction_hex_storage);
        instruction_hex = instruction_hex_storage;
    }

    {
        size_t lf[3];
        size_t lf_count = 0;
        size_t i;
        int malformed = 0;
        size_t line2_len, line3_len;
        size_t path_off, path_len, digest_off, digest_len;
        int has_control = 0;

        for (i = 0; i < n && lf_count < 3U; i++) {
            if (instruction_buffer[i] == '\n') lf[lf_count++] = i;
        }
        if (lf_count < 3U) {
            outcome = "refused";
            reason_id = "instruction.malformed";
            goto write_result;
        }
        if (n > lf[2] + 1U) {
            outcome = "refused";
            reason_id = "instruction.trailing";
            goto write_result;
        }

        if (lf[0] != strlen(INSTRUCTION_HEADER) ||
            memcmp(instruction_buffer, INSTRUCTION_HEADER, lf[0]) != 0) {
            malformed = 1;
        }

        line2_len = lf[1] - lf[0] - 1U;
        if (!malformed && (line2_len < 5U || memcmp(instruction_buffer + lf[0] + 1U, "path ", 5U) != 0)) {
            malformed = 1;
        }

        line3_len = lf[2] - lf[1] - 1U;
        if (!malformed && (line3_len < 7U || memcmp(instruction_buffer + lf[1] + 1U, "sha256 ", 7U) != 0)) {
            malformed = 1;
        }

        if (!malformed) {
            for (i = 0; i < n; i++) {
                if (instruction_buffer[i] == '\r' || instruction_buffer[i] == '\0') {
                    malformed = 1;
                    break;
                }
            }
        }
        if (!malformed && lf[0] > 0U && instruction_buffer[lf[0] - 1U] == ' ') malformed = 1;
        if (!malformed && line2_len > 0U && instruction_buffer[lf[1] - 1U] == ' ') malformed = 1;
        if (!malformed && line3_len > 0U && instruction_buffer[lf[2] - 1U] == ' ') malformed = 1;

        path_off = lf[0] + 1U + 5U;
        path_len = line2_len - 5U;
        digest_off = lf[1] + 1U + 7U;
        digest_len = line3_len - 7U;

        if (!malformed) {
            if (digest_len != 64U) {
                malformed = 1;
            } else {
                for (i = 0; i < 64U; i++) {
                    unsigned char c = instruction_buffer[digest_off + i];
                    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
                        malformed = 1;
                        break;
                    }
                }
            }
        }

        if (!malformed && !utf8_validate(instruction_buffer + path_off, path_len, &has_control)) {
            malformed = 1;
        }

        if (malformed) {
            outcome = "refused";
            reason_id = "instruction.malformed";
            goto write_result;
        }

        {
            struct component comps[MAX_PATH_COMPONENTS];
            size_t comp_count = 0;

            if (!path_r4_ok(instruction_buffer + path_off, path_len, has_control, comps,
                             &comp_count)) {
                outcome = "refused";
                reason_id = "instruction.path-rejected";
                goto write_result;
            }

            have_check = 1;
            memcpy(check_path, instruction_buffer + path_off, path_len);
            check_path_len = path_len;
            memcpy(expected_hex, instruction_buffer + digest_off, 64U);
            expected_hex[64] = '\0';

            {
                const char *walk_reason = read_candidate(check_path, check_path_len, comps,
                                                          comp_count, &have_observed,
                                                          observed_hex, &observed_size);
                if (walk_reason != NULL) {
                    outcome = "refused";
                    reason_id = walk_reason;
                } else if (strcmp(observed_hex, expected_hex) == 0) {
                    outcome = "match";
                    reason_id = "file.match";
                } else {
                    outcome = "mismatch";
                    reason_id = "file.mismatch";
                }
            }
        }
    }

write_result:
    payload_len = build_payload(payload_out, outcome, reason_id, have_check, check_path,
                                 check_path_len, expected_hex, instruction_hex, have_observed,
                                 observed_hex, observed_size);
    write_payload(payload_out, payload_len);
    return 0;
}
