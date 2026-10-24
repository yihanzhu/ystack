#define _POSIX_C_SOURCE 200809L
#include "observation-values.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <sys/wait.h>
#include <sys/stat.h>

int ys_u64_values(int read_ok, const char *bytes, uint64_t *value)
{
    if (!read_ok) return 0;
    *value = strtoull(bytes, NULL, 10);
    return 1;
}

int ys_readback_matches(int read_ok, const char *bytes, uint64_t expected)
{
    uint64_t value;
    return ys_u64_values(read_ok, bytes, &value) && value == expected;
}

void ys_setup_values(const struct ys_plan_limits *lim, const struct ys_setup_observations *raw,
                      uint64_t memory_bound, struct ys_setup_flags *flags)
{
    const char *mem;
    memset(flags, 0, sizeof *flags);
    flags->cpu_hard = raw->writes[0] && ys_readback_matches(raw->reads[0], raw->readbacks[0], lim->cpu_max) &&
        raw->writes[1] && ys_readback_matches(raw->reads[1], raw->readbacks[1], lim->cpu_max_burst) &&
        raw->writes[2] && ys_readback_matches(raw->reads[2], raw->readbacks[2], lim->bandwidth_slice_us);
    flags->pids_hard = raw->writes[3] && ys_readback_matches(raw->reads[3], raw->readbacks[3], lim->pids_max);
    mem = raw->meminfo_ok ? strchr(raw->meminfo, ':') : NULL;
    flags->memory_hard = mem != NULL && strtoull(mem + 1, NULL, 10) * 1024ULL <= memory_bound;
    flags->output_hard = raw->output_ok && raw->output_blocks * raw->output_fragment == lim->output_tmpfs_bytes
        && raw->output_files == lim->output_inodes;
    flags->scratch_hard = raw->scratch_ok && raw->scratch_blocks * raw->scratch_fragment == lim->scratch_bytes
        && raw->scratch_files == lim->scratch_inodes;
}

void ys_report_setup_values(struct report_state *s, const struct ys_setup_flags *flags, uint64_t page_size)
{
    s->cpu.enforcement = "none"; s->cpu.resolution = 1;
    s->memory.enforcement = flags->memory_hard ? "hard" : "unknown"; s->memory.resolution = page_size;
    s->output.enforcement = flags->output_hard ? "hard" : "unknown"; s->output.resolution = 1;
    s->tasks.enforcement = flags->pids_hard ? "hard" : "unknown"; s->tasks.resolution = 1;
    s->scratch.enforcement = flags->scratch_hard ? "hard" : "unknown"; s->scratch.resolution = 4096;
}

int ys_inode_history_record(struct seen_inode seen[256], size_t *count, dev_t dev, ino_t ino)
{
    size_t i;
    for (i = 0; i < *count; i++)
        if (seen[i].dev == dev && seen[i].ino == ino) return 0;
    if (*count >= 256U) return 0;
    seen[(*count)++] = (struct seen_inode){dev, ino};
    return 1;
}

int ys_fan_open_values(struct seen_inode seen[256], size_t *count, int stat_result,
                       mode_t mode, int64_t size, dev_t dev, ino_t ino)
{
    return stat_result == 0 && S_ISREG(mode) && size == 0 && ys_inode_history_record(seen, count, dev, ino);
}

int ys_population_values(int read_ok, const char *bytes)
{
    const char *line;
    if (!read_ok) return -1;
    line = strstr(bytes, "populated ");
    if (line == NULL) return -1;
    return line[10] == '0' ? 0 : 1;
}

int ys_fan_next(const unsigned char *bytes, size_t length, size_t offset, int *event_fd, size_t *next)
{
    struct metadata {
        uint32_t event_len;
        uint8_t version, reserved;
        uint16_t metadata_len;
        uint64_t mask;
        int32_t fd, pid;
    } row;
    _Static_assert(sizeof row == 24U, "fanotify metadata layout");
    if (offset > length || length - offset < sizeof row) return 0;
    memcpy(&row, bytes + offset, sizeof row);
    if (row.event_len < sizeof row || row.event_len > length - offset) return 0;
    *event_fd = row.fd;
    *next = offset + row.event_len;
    return 1;
}

int ys_deadline_after_ms(const struct timespec *start, uint64_t milliseconds, struct timespec *deadline)
{
    uint64_t seconds = milliseconds / 1000U;
    uint64_t nanoseconds = (milliseconds % 1000U) * 1000000U + (uint64_t)start->tv_nsec;
    uint64_t carry = nanoseconds / 1000000000U;
    if (start->tv_sec < 0 || start->tv_nsec < 0 || start->tv_nsec >= 1000000000L ||
        seconds > (uint64_t)INT64_MAX - (uint64_t)start->tv_sec ||
        carry > (uint64_t)INT64_MAX - (uint64_t)start->tv_sec - seconds) return 0;
    deadline->tv_sec = start->tv_sec + (time_t)seconds + (time_t)carry;
    deadline->tv_nsec = (long)(nanoseconds % 1000000000U);
    return deadline->tv_sec >= start->tv_sec;
}

int ys_deadline_remaining(const struct timespec *deadline, int ok, const struct timespec *now,
                           int *milliseconds)
{
    int64_t seconds, nanoseconds, value;
    if (!ok) return -1;
    if (now->tv_sec > deadline->tv_sec ||
        (now->tv_sec == deadline->tv_sec && now->tv_nsec >= deadline->tv_nsec)) return 0;
    seconds = (int64_t)deadline->tv_sec - (int64_t)now->tv_sec;
    nanoseconds = (int64_t)deadline->tv_nsec - (int64_t)now->tv_nsec;
    if (nanoseconds < 0) { seconds--; nanoseconds += 1000000000; }
    if (seconds > INT_MAX / 1000) value = INT_MAX;
    else {
        value = seconds * 1000 + (nanoseconds + 999999) / 1000000;
        if (value > INT_MAX) value = INT_MAX;
    }
    *milliseconds = (int)value;
    return 1;
}

int ys_exec_read_values(struct exec_channel_state *state, ssize_t count, int error_number,
                        const unsigned char *bytes)
{
    if (state->length == sizeof state->bytes) { state->invalid = 1; return -1; }
    if (count > 0) {
        if ((size_t)count > sizeof state->bytes - state->length) { state->invalid = 1; return -1; }
        memcpy(state->bytes + state->length, bytes, (size_t)count);
        state->length += (size_t)count;
        return 1;
    }
    if (count == 0) { state->eof = 1; return 0; }
    if (error_number == EINTR || error_number == EAGAIN || error_number == EWOULDBLOCK) return 0;
    state->invalid = 1;
    return -1;
}

int ys_execution_was_verified(const struct exec_channel_state *state, int status,
                              int reaped, int terminated, int deadline, int containment)
{
    struct ys_exec_outcome first;
    if (!reaped || !terminated || deadline || containment || state->invalid || !state->eof ||
        state->length != sizeof first || !WIFEXITED(status)) return 0;
    memcpy(&first, state->bytes, sizeof first);
    return first.kind == YS_EXEC_READY && first.phase == YS_EXEC_PHASE_EXECVE &&
           first.reserved == 0 && first.error_number == 0;
}

enum controller_phase {
    C_TOP_NOW, C_POLL, C_POST_POLL_NOW, C_FD, C_FAN, C_EXEC, C_POST_FD_NOW,
    C_WAIT, C_POST_WAIT_NOW, C_POP_NOW, C_POP, C_FINAL_EXEC, C_FINAL_NOW,
    C_FAILURE, C_KILL, C_CLEAN_NOW, C_CLEAN_WAIT, C_CLEAN_POP, C_DONE
};

int ys_launch_pid_valid(pid_t child) { return child > 0; }

static enum ys_controller_action controller_next(struct ys_controller_state *s, int phase,
                                                   enum ys_controller_action action)
{ s->phase = phase; s->expected = action; return action; }

void ys_controller_init(struct ys_controller_state *s, pid_t child, int has_fan,
                         const struct timespec *deadline)
{
    memset(s, 0, sizeof *s);
    s->child = child;
    s->has_fan = has_fan;
    s->deadline = *deadline;
    s->expected = YS_ACTION_NOW;
}

enum ys_controller_action ys_controller_step(struct ys_controller_state *s,
                                               const struct ys_controller_event *e)
{
    int time_state = 1, read_state;
    if (e == NULL || e->action != s->expected || s->phase == C_DONE) {
        s->branch = CONTROLLER_FAILURE;
        return controller_next(s, C_DONE, YS_ACTION_DONE);
    }
    if (e->action == YS_ACTION_NOW) {
        time_state = ys_deadline_remaining(&s->deadline, e->value, &e->now, &s->remaining);
        if (time_state <= 0) {
            if (time_state == 0) s->result.deadline_fired = 1;
            if (s->phase == C_CLEAN_NOW) return controller_next(s, C_DONE, YS_ACTION_DONE);
            s->phase = C_FAILURE;
        }
    }
    for (;;) {
        switch (s->phase) {
        case C_TOP_NOW:
            s->count = (size_t)s->has_fan + (s->outcome.eof ? 0U : 1U);
            return controller_next(s, C_POLL, YS_ACTION_POLL);
        case C_POLL:
            s->polled = e->value;
            memcpy(s->revents, e->revents, sizeof s->revents);
            return controller_next(s, C_POST_POLL_NOW, YS_ACTION_NOW);
        case C_POST_POLL_NOW:
            if (s->polled < 0) {
                if (e->error_number == EINTR) return controller_next(s, C_TOP_NOW, YS_ACTION_NOW);
                s->phase = C_FAILURE; continue;
            }
            s->current = 0;
            s->phase = C_FD;
            continue;
        case C_FD:
            if (s->current == s->count) return controller_next(s, C_WAIT, YS_ACTION_WAIT);
            if (s->has_fan && s->current == 0U) {
                if (s->revents[s->current] & (POLLERR | POLLHUP | POLLNVAL)) {
                    s->phase = C_FAILURE; continue;
                }
                if (s->revents[s->current] & POLLIN)
                    return controller_next(s, C_FAN, YS_ACTION_FAN_READ);
            } else {
                if (s->revents[s->current] & (POLLERR | POLLNVAL)) {
                    s->phase = C_FAILURE; continue;
                }
                if (s->revents[s->current] & (POLLIN | POLLHUP)) {
                    if (s->outcome.length == sizeof s->outcome.bytes) {
                        s->outcome.invalid = 1; s->phase = C_FAILURE; continue;
                    }
                    return controller_next(s, C_EXEC, YS_ACTION_EXEC_READ);
                }
            }
            return controller_next(s, C_POST_FD_NOW, YS_ACTION_NOW);
        case C_FAN:
            if (!e->value) { s->phase = C_FAILURE; continue; }
            return controller_next(s, C_POST_FD_NOW, YS_ACTION_NOW);
        case C_EXEC:
        case C_FINAL_EXEC:
            read_state = ys_exec_read_values(&s->outcome, e->read_count, e->error_number, e->bytes);
            if (read_state < 0) { s->phase = C_FAILURE; continue; }
            if (read_state > 0) {
                if (s->outcome.length == sizeof s->outcome.bytes) {
                    s->outcome.invalid = 1; s->phase = C_FAILURE; continue;
                }
                s->expected = YS_ACTION_EXEC_READ;
                return YS_ACTION_EXEC_READ;
            }
            return controller_next(s, s->phase == C_EXEC ? C_POST_FD_NOW : C_FINAL_NOW, YS_ACTION_NOW);
        case C_POST_FD_NOW:
            s->current++;
            s->phase = C_FD;
            continue;
        case C_WAIT:
            s->waited = e->waited; s->status = e->wait_status;
            return controller_next(s, C_POST_WAIT_NOW, YS_ACTION_NOW);
        case C_POST_WAIT_NOW:
            if (s->waited < 0) {
                if (e->error_number == EINTR) return controller_next(s, C_TOP_NOW, YS_ACTION_NOW);
                s->phase = C_FAILURE; continue;
            }
            if (s->waited == 0) return controller_next(s, C_TOP_NOW, YS_ACTION_NOW);
            if (s->waited != s->child) { s->phase = C_FAILURE; continue; }
            s->result.child_reaped = 1; s->result.child_status = s->status;
            return controller_next(s, C_POP_NOW, YS_ACTION_NOW);
        case C_POP_NOW:
            return controller_next(s, C_POP, YS_ACTION_POPULATION);
        case C_POP:
            if (e->value < 0) { s->phase = C_FAILURE; continue; }
            if (e->value == 0) {
                s->result.tree_terminated = 1;
                if (s->outcome.length == sizeof s->outcome.bytes) {
                    s->outcome.invalid = 1; s->phase = C_FAILURE; continue;
                }
                return controller_next(s, C_FINAL_EXEC, YS_ACTION_EXEC_READ);
            }
            s->phase = C_POP_NOW; s->expected = YS_ACTION_NOW;
            return YS_ACTION_TICK_NOW;
        case C_FINAL_NOW:
            s->result.verifier_started = ys_execution_was_verified(&s->outcome, s->status, 1, 1, 0, 0);
            s->branch = s->result.verifier_started ? CONTROLLER_NORMAL : CONTROLLER_FAILURE;
            return controller_next(s, C_DONE, YS_ACTION_DONE);
        case C_FAILURE:
            s->result.containment_failure = 1;
            return controller_next(s, C_KILL, YS_ACTION_KILL);
        case C_KILL:
            if (!e->value) s->result.kill_failed = 1;
            return controller_next(s, C_CLEAN_NOW, YS_ACTION_NOW);
        case C_CLEAN_NOW:
            if (!s->result.child_reaped) return controller_next(s, C_CLEAN_WAIT, YS_ACTION_WAIT);
            return controller_next(s, C_CLEAN_POP, YS_ACTION_POPULATION);
        case C_CLEAN_WAIT:
            if (e->waited == s->child) {
                s->result.child_reaped = 1; s->result.child_status = e->wait_status;
            } else if (e->waited < 0 && e->error_number != EINTR)
                return controller_next(s, C_DONE, YS_ACTION_DONE);
            return controller_next(s, C_CLEAN_POP, YS_ACTION_POPULATION);
        case C_CLEAN_POP:
            if (e->value < 0) return controller_next(s, C_DONE, YS_ACTION_DONE);
            if (e->value == 0) s->result.tree_terminated = 1;
            if (s->result.child_reaped && s->result.tree_terminated)
                return controller_next(s, C_DONE, YS_ACTION_DONE);
            s->phase = C_CLEAN_NOW; s->expected = YS_ACTION_NOW;
            return YS_ACTION_TICK_NOW;
        default:
            s->branch = CONTROLLER_FAILURE;
            return controller_next(s, C_DONE, YS_ACTION_DONE);
        }
    }
}

void ys_cpu_values(struct guest_row *row, int terminated, const char *cpu_stat, uint64_t bound)
{
    const char *usage = cpu_stat == NULL ? NULL : strstr(cpu_stat, "usage_usec ");
    row->observation = "unavailable";
    if (terminated && usage != NULL) {
        uint64_t usec = strtoull(usage + 11, NULL, 10);
        row->observed = (usec + 999ULL) / 1000ULL;
        row->reached = row->observed >= bound;
        row->observation = "complete";
    }
}

static void peak_values(struct guest_row *row, int terminated, int peak_ok, uint64_t peak,
                         const char *events, const char *field, uint64_t bound)
{
    const char *event;
    row->observation = "unavailable";
    if (!terminated || !peak_ok) return;
    row->observed = peak;
    row->reached = peak >= bound;
    row->observation = "complete";
    event = events == NULL ? NULL : strstr(events, field);
    if (event != NULL && strtoull(event + strlen(field), NULL, 10) > 0) row->reached = 1;
}

void ys_memory_values(struct guest_row *row, int terminated, int peak_ok, uint64_t peak,
                      const char *events, uint64_t bound)
{ peak_values(row, terminated, peak_ok, peak, events, "oom_kill ", bound); }

void ys_tasks_values(struct guest_row *row, int terminated, int peak_ok, uint64_t peak,
                     const char *events, uint64_t bound)
{ peak_values(row, terminated, peak_ok, peak, events, "max ", bound); }

void ys_output_values(struct guest_row *row, int inventory_ok, uint64_t total,
                      int filesystem_ok, uint64_t free_blocks, uint64_t bound)
{
    row->observation = inventory_ok ? "complete" : "partial";
    row->observed = total;
    if (filesystem_ok) row->reached = free_blocks == 0U || total >= bound;
}

void ys_scratch_values(struct guest_row *row, int filesystem_ok, uint64_t blocks,
                       uint64_t free_blocks, uint64_t fragment_size, uint64_t bound)
{
    if (!filesystem_ok) { row->observation = "unavailable"; return; }
    row->observed = (blocks - free_blocks) * fragment_size;
    row->resolution = fragment_size;
    row->observation = "complete";
    row->reached = free_blocks == 0U || row->observed >= bound;
}

int ys_checked_add_u64(uint64_t a, uint64_t b, uint64_t *out)
{
    if (UINT64_MAX - a < b) return 0;
    *out = a + b;
    return 1;
}

int ys_checked_mul_u64(uint64_t a, uint64_t b, uint64_t *out)
{
    if (a != 0U && b > UINT64_MAX / a) return 0;
    *out = a * b;
    return 1;
}

int ys_rounded_allocation(uint64_t bytes, uint64_t page_size, uint64_t *out)
{
    uint64_t with_slack;
    if (page_size == 0U) return 0;
    if (bytes == 0U) { *out = 0U; return 1; }
    if (!ys_checked_add_u64(bytes, page_size - 1U, &with_slack)) return 0;
    *out = (with_slack / page_size) * page_size;
    return 1;
}

int ys_candidate_geometry(const struct ys_guest_plan *plan, uint64_t page_size,
                              uint64_t *size_bytes, uint64_t *nr_inodes)
{
    uint64_t data = 0U, directories = 1U, metadata, rounded;
    size_t i;
    for (i = 0; i < plan->entry_count; i++) {
        if (plan->entries[i].is_file) {
            if (!ys_rounded_allocation(plan->entries[i].size_bytes, page_size, &rounded) ||
                !ys_checked_add_u64(data, rounded, &data))
                return 0;
        } else if (!ys_checked_add_u64(directories, 1U, &directories)) {
            return 0;
        }
    }
    /* One page per directory covers tmpfs directory-entry and inode metadata. */
    if (!ys_checked_mul_u64(directories, page_size, &metadata) ||
        !ys_checked_add_u64(data, metadata, size_bytes))
        return 0;
    if (*size_bytes == 0U) *size_bytes = page_size;
    if (plan->entry_count == SIZE_MAX ||
        !ys_checked_add_u64(1U, (uint64_t)plan->entry_count, nr_inodes))
        return 0;
    return *nr_inodes > 0U;
}

struct json_writer { char *buf; size_t len, cap; };

#ifdef YSTACK_SUPERVISOR_TEST
size_t ys_test_report_cap_limit;
int ys_test_format_failure;
#endif

static int json_reserve(struct json_writer *w, size_t additional)
{
    size_t needed, next;
    char *grown;
    if (SIZE_MAX - w->len <= additional) return 0;
    needed = w->len + additional + 1U;
    if (needed <= w->cap) return 1;
    next = w->cap == 0U ? 1024U : w->cap;
    while (next < needed) {
        if (next > SIZE_MAX / 2U) { next = needed; break; }
        next *= 2U;
    }
#ifdef YSTACK_SUPERVISOR_TEST
    if (ys_test_report_cap_limit != 0U && next > ys_test_report_cap_limit) return 0;
#endif
    grown = realloc(w->buf, next);
    if (grown == NULL) return 0;
    w->buf = grown;
    w->cap = next;
    return 1;
}

static int json_appendf(struct json_writer *w, const char *format, ...)
{
    va_list ap, copy;
    int required, written;
    va_start(ap, format);
#ifdef YSTACK_SUPERVISOR_TEST
    if (ys_test_format_failure) { va_end(ap); return 0; }
#endif
    va_copy(copy, ap);
    required = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (required < 0 || !json_reserve(w, (size_t)required)) { va_end(ap); return 0; }
    written = vsnprintf(w->buf + w->len, w->cap - w->len, format, ap);
    va_end(ap);
    if (written != required || (size_t)written >= w->cap - w->len) return 0;
    w->len += (size_t)written;
    return 1;
}

static int append_row(struct json_writer *w, const char *name, const struct guest_row *r)
{
    if (r->observation != NULL && strcmp(r->observation, "unavailable") == 0)
        return json_appendf(w,
                            "\"%s\":{\"enforcement\":\"%s\",\"observation\":\"unavailable\","
                            "\"observed\":null,\"reached\":false,\"resolution\":%llu}",
                            name, r->enforcement, (unsigned long long)r->resolution);
    return json_appendf(w,
                        "\"%s\":{\"enforcement\":\"%s\",\"observation\":\"%s\","
                        "\"observed\":%llu,\"reached\":%s,\"resolution\":%llu}",
                        name, r->enforcement, r->observation,
                        (unsigned long long)r->observed, r->reached ? "true" : "false",
                        (unsigned long long)r->resolution);
}

/* Builds the canonical report.json bytes into a malloc'd buffer (caller
 * frees). Missing evidence metadata, invalid names and any formatting or
 * allocation failure abort the report rather than emitting partial JSON. */
char *ys_build_report_json(const char plan_sha256_hex[65],
                                const struct report_state *s, const uint64_t *evidence_sizes, size_t *len_out)
{
    struct json_writer w = { NULL, 0U, 0U };
    size_t i;
    if (s->evidence_count > 10000U) goto fail;
    if (!json_appendf(&w, "{\"body\":{\"evidence_files\":[")) goto fail;
    for (i = 0; i < s->evidence_count; i++) {
        char hex[513];
        size_t namelen = strlen(s->evidence_names[i]);
        if (namelen > 255U) goto fail;
        ys_hex_encode((const unsigned char *)s->evidence_names[i], namelen, hex);
        hex[namelen * 2U] = '\0';
        if (evidence_sizes == NULL) goto fail;
        if (!json_appendf(&w, "%s{\"index\":%zu,\"name_hex\":\"%s\",\"size_bytes\":%lld}",
                          (i == 0U) ? "" : ",", i, hex, (long long)evidence_sizes[i]))
            goto fail;
    }
    if (!json_appendf(&w, "],")) goto fail;
    if (s->exit_signaled)
        { if (!json_appendf(&w, "\"exit_code\":null,\"exit_state\":\"signaled\",")) goto fail; }
    else
        { if (!json_appendf(&w, "\"exit_code\":%d,\"exit_state\":\"exited\",", s->exit_code)) goto fail; }
    if (!json_appendf(&w, "\"limits\":{") ||
        !append_row(&w, "cpu_time_ms", &s->cpu) || !json_appendf(&w, ",") ||
        !append_row(&w, "memory_bytes", &s->memory) || !json_appendf(&w, ",") ||
        !append_row(&w, "output_bytes", &s->output) || !json_appendf(&w, ",") ||
        !append_row(&w, "process_count", &s->tasks) || !json_appendf(&w, ",") ||
        !append_row(&w, "scratch_bytes", &s->scratch) ||
        !json_appendf(&w,
                      "},\"plan_sha256\":\"%.64s\",\"stderr_bytes\":%llu,\"stdout_bytes\":%llu,"
                      "\"tree_deadline_fired\":%s,\"tree_terminated\":%s,\"verifier_started\":%s},"
                      "\"id\":\"sandbox.guest-report.v1\",\"kind\":\"sandbox_guest_report\","
                      "\"schema_version\":1}\n",
                      plan_sha256_hex, (unsigned long long)s->stderr_bytes,
                      (unsigned long long)s->stdout_bytes,
                      s->tree_deadline_fired ? "true" : "false",
                      s->tree_terminated ? "true" : "false",
                      s->verifier_started ? "true" : "false"))
        goto fail;
    *len_out = w.len;
    return w.buf;
fail:
    free(w.buf);
    return NULL;
}

#ifdef YSTACK_OBSERVATION_VALUES_MAIN
struct value_reader { size_t bytes; int failed; };

static int value_read(struct value_reader *r, void *out, size_t count)
{
    size_t offset = 0;
    if (r->failed || count > 16U * 1024U * 1024U - r->bytes) { r->failed = 1; return 0; }
    r->bytes += count;
    while (offset < count) {
        size_t got = fread((unsigned char *)out + offset, 1, count - offset, stdin);
        if (got == 0) { r->failed = 1; return 0; }
        offset += got;
    }
    return 1;
}

static uint64_t value_uint(struct value_reader *r)
{
    unsigned char bytes[8];
    uint64_t value = 0;
    size_t i;
    if (!value_read(r, bytes, sizeof bytes)) return 0;
    for (i = 0; i < sizeof bytes; i++) value = (value << 8) | bytes[i];
    return value;
}

static int64_t value_int(struct value_reader *r)
{
    uint64_t raw = value_uint(r);
    return raw <= INT64_MAX ? (int64_t)raw : -(int64_t)(~raw) - 1;
}

static size_t value_blob(struct value_reader *r, unsigned char *out, size_t capacity)
{
    uint64_t count = value_uint(r);
    if (count > capacity || !value_read(r, out, (size_t)count)) { r->failed = 1; return 0; }
    return (size_t)count;
}

static void value_text(struct value_reader *r, char *out, size_t capacity)
{
    size_t length = value_blob(r, (unsigned char *)out, capacity - 1U);
    out[length] = '\0';
}

static int value_fan(struct value_reader *r, struct seen_inode seen[256], size_t *seen_count)
{
    unsigned char raw[4096];
    int64_t result = value_int(r), error_number = value_int(r);
    size_t length = value_blob(r, raw, sizeof raw), offset = 0, next;
    int fd;
    if (result < 0 && (error_number == EINTR || error_number == EAGAIN || error_number == EWOULDBLOCK))
        return length == 0U;
    if (result <= 0) return 0;
    if ((uint64_t)result != length) { r->failed = 1; return 0; }
    while (ys_fan_next(raw, length, offset, &fd, &next)) {
        int stat_result, allow;
        mode_t mode;
        int64_t size;
        dev_t dev;
        ino_t ino;
        size_t written = 0;
        if (fd < 0) return 0;
        stat_result = (int)value_int(r);
        mode = (mode_t)value_uint(r); size = value_int(r);
        dev = (dev_t)value_uint(r); ino = (ino_t)value_uint(r);
        allow = ys_fan_open_values(seen, seen_count, stat_result, mode, size, dev, ino);
        (void)allow;
        while (written < 8U) {
            int64_t count;
            if (value_uint(r) != 9U) { r->failed = 1; return 0; }
            count = value_int(r); error_number = value_int(r);
            if (count < 0 && error_number == EINTR) return 0;
            if (count <= 0) return 0;
            if ((uint64_t)count > 8U - written) { r->failed = 1; return 0; }
            written += (size_t)count;
        }
        offset = next;
    }
    return 1;
}

static int value_controller(struct value_reader *r, const struct ys_guest_plan *plan,
                             struct controller_result *out)
{
    struct timespec start, deadline;
    struct ys_controller_state state;
    struct seen_inode seen[256];
    size_t seen_count = 0, count, index;
    enum ys_controller_action action = YS_ACTION_NOW;
    int now_ok = (int)value_uint(r), fan_fd;
    pid_t child;
    start.tv_sec = (time_t)value_int(r); start.tv_nsec = (long)value_int(r);
    memset(out, 0, sizeof *out);
    if (!now_ok || !ys_deadline_after_ms(&start, plan->limits.tree_deadline_ms, &deadline)) return !r->failed;
    child = (pid_t)value_int(r);
    (void)value_int(r);
    if (!ys_launch_pid_valid(child)) return !r->failed;
    fan_fd = (int)value_int(r);
    count = (size_t)value_uint(r);
    if (count > 4096U) { r->failed = 1; return 0; }
    ys_controller_init(&state, child, fan_fd >= 0, &deadline);
    for (index = 0; index < count; index++) {
        struct ys_controller_event event;
        uint64_t tag = value_uint(r);
        memset(&event, 0, sizeof event);
        event.action = action == YS_ACTION_TICK_NOW ? YS_ACTION_NOW : action;
        if (action == YS_ACTION_DONE || tag != (uint64_t)event.action) { r->failed = 1; return 0; }
        switch (event.action) {
        case YS_ACTION_NOW:
            event.value = (int)value_uint(r);
            event.now.tv_sec = (time_t)value_int(r); event.now.tv_nsec = (long)value_int(r);
            event.error_number = (int)value_int(r);
            break;
        case YS_ACTION_POLL:
            event.value = (int)value_int(r); event.error_number = (int)value_int(r);
            event.revents[0] = (short)value_uint(r); event.revents[1] = (short)value_uint(r);
            break;
        case YS_ACTION_WAIT:
            event.waited = (pid_t)value_int(r); event.wait_status = (int)value_int(r);
            event.error_number = (int)value_int(r);
            break;
        case YS_ACTION_POPULATION:
            {
                char population[256];
                int ok = (int)value_uint(r);
                value_text(r, population, sizeof population);
                event.value = ys_population_values(ok, population);
            }
            break;
        case YS_ACTION_EXEC_READ:
            {
                size_t length;
                event.read_count = (ssize_t)value_int(r); event.error_number = (int)value_int(r);
                length = value_blob(r, event.bytes, sizeof event.bytes);
                if ((event.read_count > 0 && (uint64_t)event.read_count != length) ||
                    (event.read_count <= 0 && length != 0U)) r->failed = 1;
            }
            break;
        case YS_ACTION_FAN_READ:
            event.value = value_fan(r, seen, &seen_count);
            break;
        case YS_ACTION_KILL:
            event.value = (int)value_int(r); event.error_number = (int)value_int(r);
            break;
        default: r->failed = 1; return 0;
        }
        if (r->failed) return 0;
        action = ys_controller_step(&state, &event);
    }
    if (action != YS_ACTION_DONE) { r->failed = 1; return 0; }
    *out = state.result;
    return 1;
}

int main(int argc, char **argv)
{
    struct value_reader reader = {0, 0};
    struct ys_guest_plan plan;
    struct ys_setup_observations setup;
    struct ys_setup_flags flags;
    struct controller_result control;
    struct report_state report;
    struct ys_frame_writer frame;
    unsigned char magic[8], digest[32], *plan_raw = NULL, *streams[2] = {NULL, NULL};
    unsigned char **content = NULL;
    size_t *content_lengths = NULL, stream_lengths[2] = {0, 0};
    uint64_t *sizes = NULL;
    struct ys_evidence_row *rows = NULL;
    size_t row_count = 0, evidence_count = 0, plan_length, i, j, length;
    char **names = NULL, plan_hex[65], cpu[256], peak[128], events[256];
    char *json = NULL;
    uint64_t page_size, total, value = 0, blocks, free_blocks, fragment;
    int ok, inventory_ok, result = 1, plan_loaded = 0;
    (void)argv;
    memset(&report, 0, sizeof report); memset(&setup, 0, sizeof setup);
    if (argc != 1 || !value_read(&reader, magic, sizeof magic) || memcmp(magic, "YSVAL01\n", 8) != 0) goto done;
    plan_length = (size_t)value_uint(&reader);
    if (plan_length > 16U * 1024U * 1024U) goto done;
    plan_raw = malloc(plan_length == 0U ? 1U : plan_length);
    if (plan_raw == NULL || !value_read(&reader, plan_raw, plan_length) ||
        ys_plan_parse(plan_raw, plan_length, &plan) != YS_PLAN_OK) goto done;
    plan_loaded = 1;
    ys_sha256_bytes(plan_raw, plan_length, digest); ys_hex_encode(digest, sizeof digest, plan_hex);
    for (i = 0; i < 4U; i++) {
        setup.writes[i] = (int)value_uint(&reader); setup.reads[i] = (int)value_uint(&reader);
        value_text(&reader, setup.readbacks[i], sizeof setup.readbacks[i]);
    }
    setup.meminfo_ok = (int)value_uint(&reader); value_text(&reader, setup.meminfo, sizeof setup.meminfo);
    setup.output_ok = (int)value_uint(&reader);
    setup.output_blocks = value_uint(&reader); setup.output_fragment = value_uint(&reader); setup.output_files = value_uint(&reader);
    setup.scratch_ok = (int)value_uint(&reader);
    setup.scratch_blocks = value_uint(&reader); setup.scratch_fragment = value_uint(&reader); setup.scratch_files = value_uint(&reader);
    page_size = value_uint(&reader);
    ys_setup_values(&plan.limits, &setup, 536870912ULL, &flags);
    ys_report_setup_values(&report, &flags, page_size);
    if (!value_controller(&reader, &plan, &control) || reader.failed) goto done;
    report.verifier_started = control.verifier_started;
    report.tree_terminated = control.tree_terminated; report.tree_deadline_fired = control.deadline_fired;
    if (!report.verifier_started) {
        if (fgetc(stdin) != EOF || ferror(stdin)) goto done;
        result = 0; goto done;
    }
    if (WIFEXITED(control.child_status)) report.exit_code = WEXITSTATUS(control.child_status);
    else report.exit_signaled = 1;
    ok = (int)value_uint(&reader); value_text(&reader, cpu, sizeof cpu);
    ys_cpu_values(&report.cpu, report.tree_terminated, ok ? cpu : NULL, 30000ULL);
    ok = (int)value_uint(&reader); value_text(&reader, peak, sizeof peak);
    ok = ys_u64_values(ok, peak, &value);
    value_text(&reader, events, sizeof events);
    ys_memory_values(&report.memory, report.tree_terminated, ok, value, events, 536870912ULL);
    ok = (int)value_uint(&reader); value_text(&reader, peak, sizeof peak);
    ok = ys_u64_values(ok, peak, &value);
    value_text(&reader, events, sizeof events);
    ys_tasks_values(&report.tasks, report.tree_terminated, ok, value, events, plan.limits.pids_max);
    for (i = 0; i < 2U; i++) {
        ok = (int)value_uint(&reader); value = value_uint(&reader);
        if (ok) { if (i == 0U) report.stdout_bytes = value; else report.stderr_bytes = value; }
        stream_lengths[i] = (size_t)value_uint(&reader);
        if (stream_lengths[i] > 10U * 1024U * 1024U) goto done;
        streams[i] = malloc(stream_lengths[i] == 0U ? 1U : stream_lengths[i]);
        if (streams[i] == NULL || !value_read(&reader, streams[i], stream_lengths[i])) goto done;
    }
    evidence_count = (size_t)value_uint(&reader);
    if (evidence_count > 10000U) goto done;
    rows = calloc(evidence_count == 0U ? 1U : evidence_count, sizeof *rows);
    content = calloc(evidence_count == 0U ? 1U : evidence_count, sizeof *content);
    content_lengths = calloc(evidence_count == 0U ? 1U : evidence_count, sizeof *content_lengths);
    sizes = calloc(evidence_count == 0U ? 1U : evidence_count, sizeof *sizes);
    if (rows == NULL || content == NULL || content_lengths == NULL || sizes == NULL) goto done;
    inventory_ok = 1;
    for (i = 0; i < evidence_count; i++) {
        char name[256];
        mode_t mode;
        int stat_ok;
        value_text(&reader, name, sizeof name);
        if (name[0] == '\0' || strchr(name, '/') != NULL) goto done;
        stat_ok = (int)value_uint(&reader); mode = (mode_t)value_uint(&reader);
        rows[row_count].ino = (ino_t)value_uint(&reader); rows[row_count].links = (nlink_t)value_uint(&reader);
        if (!stat_ok) inventory_ok = 0;
        if (ys_evidence_entry_values(mode)) {
            rows[row_count].name = strdup(name);
            if (rows[row_count].name == NULL) goto done;
            row_count++;
        }
    }
    if (value_int(&reader) != 0) inventory_ok = 0;
    if (inventory_ok) {
        inventory_ok = ys_evidence_values(rows, row_count, &names, &report.evidence_count) == YS_PLAN_OK;
        rows = NULL; row_count = 0;
    }
    report.evidence_names = names;
    total = report.stdout_bytes + report.stderr_bytes;
    if (inventory_ok) for (i = 0; i < report.evidence_count; i++) {
        ok = (int)value_uint(&reader); value = value_uint(&reader);
        if (ok) total += value;
        if (value_uint(&reader) == 0U) goto done;
        sizes[i] = value_uint(&reader);
        content_lengths[i] = (size_t)value_uint(&reader);
        if (content_lengths[i] > 10U * 1024U * 1024U) goto done;
        content[i] = malloc(content_lengths[i] == 0U ? 1U : content_lengths[i]);
        if (content[i] == NULL || !value_read(&reader, content[i], content_lengths[i])) goto done;
    }
    ok = (int)value_uint(&reader); free_blocks = value_uint(&reader);
    ys_output_values(&report.output, inventory_ok, total, ok, free_blocks, plan.limits.output_tmpfs_bytes);
    ok = (int)value_uint(&reader); blocks = value_uint(&reader); free_blocks = value_uint(&reader); fragment = value_uint(&reader);
    ys_scratch_values(&report.scratch, ok, blocks, free_blocks, fragment, plan.limits.scratch_bytes);
    if (reader.failed || fgetc(stdin) != EOF || ferror(stdin)) goto done;
    json = ys_build_report_json(plan_hex, &report, sizes, &length);
    if (json == NULL || ys_frame_writer_open(&frame, 1) == 0 ||
        ys_frame_writer_put(&frame, "report.json", 11U, json, length) != YS_FRAME_OK ||
        ys_frame_writer_put(&frame, "stdout", 6U, streams[0], stream_lengths[0]) != YS_FRAME_OK ||
        ys_frame_writer_put(&frame, "stderr", 6U, streams[1], stream_lengths[1]) != YS_FRAME_OK) goto done;
    for (i = 0; i < report.evidence_count; i++) {
        char name[32];
        int count = snprintf(name, sizeof name, "evidence/%04zu", i);
        if (count < 0 || (size_t)count >= sizeof name ||
            ys_frame_writer_put(&frame, name, (size_t)count, content[i], content_lengths[i]) != YS_FRAME_OK) goto done;
    }
    result = ys_frame_writer_close(&frame) == YS_FRAME_OK ? 0 : 1;
done:
    if (rows != NULL) { for (j = 0; j < row_count; j++) free(rows[j].name); free(rows); }
    if (names != NULL) { for (j = 0; j < report.evidence_count; j++) free(names[j]); free(names); }
    for (j = 0; j < evidence_count; j++) if (content != NULL) free(content[j]);
    free(content); free(content_lengths); free(sizes); free(json); free(plan_raw);
    free(streams[0]); free(streams[1]);
    if (plan_loaded) ys_plan_free(&plan);
    return result;
}
#endif
