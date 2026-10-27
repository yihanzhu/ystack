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

int ys_write_count_values(ssize_t count, size_t requested, int close_result)
{
    return close_result == 0 && count == (ssize_t)requested;
}

int ys_setup_write_text(const struct ys_plan_limits *lim, size_t slot, char *text, size_t capacity)
{
    int count;
    if (slot == 0U) count = snprintf(text, capacity, "%llu 100000\n", (unsigned long long)lim->cpu_max);
    else if (slot == 1U) count = snprintf(text, capacity, "%llu\n", (unsigned long long)lim->cpu_max_burst);
    else if (slot == 2U) count = snprintf(text, capacity, "%llu\n", (unsigned long long)lim->bandwidth_slice_us);
    else if (slot == 3U) count = snprintf(text, capacity, "%llu\n", (unsigned long long)lim->pids_max);
    else return 0;
    return count >= 0 && (size_t)count < capacity;
}

int ys_setup_presence_values(const struct ys_plan_limits *lim,
                              const struct ys_setup_observations *raw,
                              uint64_t write_mask, uint64_t read_mask)
{
    uint64_t expected_writes = 9U, expected_reads = 0U;
    size_t i;
    if (raw->writes[0] && ys_readback_matches(raw->reads[0], raw->readbacks[0], lim->cpu_max)) {
        expected_writes |= 2U;
        if (raw->writes[1] && ys_readback_matches(raw->reads[1], raw->readbacks[1], lim->cpu_max_burst))
            expected_writes |= 4U;
    }
    for (i = 0; i < 4U; i++) {
        uint64_t bit = 1ULL << i;
        if ((raw->writes[i] != 0 && raw->writes[i] != 1) ||
            (raw->reads[i] != 0 && raw->reads[i] != 1)) return 0;
        if ((expected_writes & bit) && raw->writes[i]) expected_reads |= bit;
        if (!(expected_writes & bit) && raw->writes[i]) return 0;
        if (!(expected_reads & bit) && (raw->reads[i] || raw->readbacks[i][0] != '\0')) return 0;
    }
    return write_mask == expected_writes && read_mask == expected_reads;
}

int ys_counter_presence_values(int memory_peak_ok, int pids_peak_ok, uint64_t events_mask)
{
    return events_mask == (uint64_t)((memory_peak_ok ? 1U : 0U) | (pids_peak_ok ? 2U : 0U));
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

static void capture_fragment(struct ys_control_capture *capture, const char *row, size_t length, int control)
{
    struct json_writer writer = { capture->bytes, capture->length, capture->capacity };
    int saved = errno;
    if (capture->incomplete || capture->count >= (control ? 4096U : 65536U) || (control && length > 8192U) ||
        length + 1U > 4U * 1024U * 1024U - capture->length) {
        capture->incomplete = 1;
        errno = saved;
        return;
    }
    if (!json_reserve(&writer, length + 1U)) {
        capture->incomplete = 1;
    } else {
        if (capture->count != 0U) writer.buf[writer.len++] = ',';
        memcpy(writer.buf + writer.len, row, length);
        writer.len += length;
        writer.buf[writer.len] = '\0';
        capture->count++;
    }
    capture->bytes = writer.buf;
    capture->length = writer.len;
    capture->capacity = writer.cap;
    errno = saved;
}

static void capture_row(struct ys_control_capture *capture, const char *row, size_t length)
{
    capture_fragment(capture, row, length, 1);
}

void ys_capture_statvfs(struct ys_control_capture *capture, const char *site,
                             int result, int error_number, const struct statvfs *sv)
{
    char row[512], error[32];
    int n, saved = errno;
    if (result < 0) snprintf(error, sizeof error, "%d", error_number);
    else strcpy(error, "null");
    if (result < 0)
        n = snprintf(row, sizeof row, "\"%s\":{\"errno\":%s,\"return\":%d,\"stat\":null}", site, error, result);
    else
        n = snprintf(row, sizeof row, "\"%s\":{\"errno\":null,\"return\":%d,\"stat\":{\"f_bfree\":%llu,\"f_blocks\":%llu,\"f_files\":%llu,\"f_frsize\":%llu}}",
            site, result, (unsigned long long)sv->f_bfree, (unsigned long long)sv->f_blocks,
            (unsigned long long)sv->f_files, (unsigned long long)sv->f_frsize);
    if (n < 0 || (size_t)n >= sizeof row) capture->incomplete = 1;
    else ys_capture_raw(capture, row, (size_t)n);
    errno = saved;
}

void ys_capture_stat(struct ys_control_capture *capture, const char *site,
                          int result, int error_number, const struct stat *st)
{
    char row[768];
    int n, saved = errno;
    if (result < 0)
        n = snprintf(row, sizeof row, "\"%s\":{\"errno\":%d,\"return\":%d,\"stat\":null}", site, error_number, result);
    else
        n = snprintf(row, sizeof row, "\"%s\":{\"errno\":null,\"return\":%d,\"stat\":{\"dev\":%llu,\"gid\":%llu,\"ino\":%llu,\"mode\":%llu,\"nlink\":%llu,\"size\":%lld,\"uid\":%llu}}",
            site, result, (unsigned long long)st->st_dev, (unsigned long long)st->st_gid,
            (unsigned long long)st->st_ino, (unsigned long long)st->st_mode,
            (unsigned long long)st->st_nlink, (long long)st->st_size, (unsigned long long)st->st_uid);
    if (n < 0 || (size_t)n >= sizeof row) capture->incomplete = 1;
    else ys_capture_raw(capture, row, (size_t)n);
    errno = saved;
}

void ys_capture_evidence_entry(const char *name, int result, int error_number,
                                     const struct stat *st, void *context)
{
    struct ys_evidence_capture *state = context;
    struct ys_control_capture *capture = state->capture;
    char site[80];
    if (name == NULL) {
        ys_capture_io(capture, "directory", error_number != 0 ? -1 : result, error_number, "", 0U);
        return;
    }
    if (state->count >= 10000U) { capture->incomplete = 1; return; }
    snprintf(site, sizeof site, "entry_%04zu_name", state->count);
    ys_capture_io(capture, site, 0, 0, name, strlen(name));
    snprintf(site, sizeof site, "entry_%04zu_stat", state->count++);
    ys_capture_stat(capture, site, result, error_number, st);
}

void ys_capture_raw(struct ys_control_capture *capture, const char *row, size_t length)
{
    size_t at = 0, end, key_length;
    char *key_end;
    int saved = errno;
    if (capture->incomplete || length < 4U || row[0] != '\"' ||
        (key_end = strchr(row + 1, '\"')) == NULL) { capture->incomplete = 1; return; }
    key_length = (size_t)(key_end - row) + 1U;
    if (capture->length != 0U &&
        strncmp(row, capture->bytes + capture->raw_cursor, key_length) > 0)
        at = capture->raw_cursor;
    while (at < capture->length) {
        int comparison = strncmp(row, capture->bytes + at, key_length);
        int depth = 0, string = 0, escaped = 0;
        if (comparison == 0 && capture->bytes[at + key_length] == ':') {
            capture->incomplete = 1; errno = saved; return;
        }
        if (comparison < 0) break;
        for (end = at; end < capture->length; end++) {
            char c = capture->bytes[end];
            if (string) {
                if (escaped) escaped = 0;
                else if (c == '\\') escaped = 1;
                else if (c == '\"') string = 0;
            } else if (c == '\"') string = 1;
            else if (c == '{' || c == '[') depth++;
            else if (c == '}' || c == ']') depth--;
            else if (c == ',' && depth == 0) break;
        }
        at = end < capture->length ? end + 1U : end;
    }
    {
        size_t previous = capture->length;
        capture_fragment(capture, row, length, 0);
        if (!capture->incomplete && at < previous) {
            char *copy = malloc(length + 1U);
            if (copy == NULL) capture->incomplete = 1;
            else {
                memcpy(copy, row, length); copy[length] = ',';
                memmove(capture->bytes + at + length + 1U, capture->bytes + at, previous - at);
                memcpy(capture->bytes + at, copy, length + 1U);
                free(copy);
            }
        }
        if (!capture->incomplete) capture->raw_cursor = at;
    }
    errno = saved;
}

void ys_capture_io(struct ys_control_capture *capture, const char *name, long long result,
                     int error_number, const void *bytes, size_t length)
{
    struct json_writer writer = {0};
    char *hex, error[32];
    int saved = errno, overhead;
    if (result < 0) snprintf(error, sizeof error, "%d", error_number);
    else strcpy(error, "null");
    overhead = snprintf(NULL, 0, "\"%s\":{\"bytes\":\"\",\"errno\":%s,\"return\":%lld}", name, error, result);
    if (capture->incomplete || overhead < 0 || capture->length > 4U * 1024U * 1024U ||
        length > 2U * 1024U * 1024U ||
        length * 2U + (size_t)overhead + (capture->count ? 1U : 0U) > 4U * 1024U * 1024U - capture->length) {
        capture->incomplete = 1; errno = saved; return;
    }
    hex = malloc(length * 2U + 1U);
    if (hex == NULL) { capture->incomplete = 1; errno = saved; return; }
    ys_hex_encode(bytes, length, hex); hex[length * 2U] = '\0';
    if (!json_appendf(&writer, "\"%s\":{\"bytes\":\"%s\",\"errno\":", name, hex) ||
        !(result < 0 ? json_appendf(&writer, "%d", error_number) : json_appendf(&writer, "null")) ||
        !json_appendf(&writer, ",\"return\":%lld}", result))
        capture->incomplete = 1;
    else ys_capture_raw(capture, writer.buf, writer.len);
    free(writer.buf); free(hex); errno = saved;
}

int ys_capture_fits(const struct ys_frame_writer *frame, off_t capacity, size_t length)
{
    return frame->offset >= 0 && capacity >= frame->offset &&
        length <= 4U * 1024U * 1024U &&
        (uint64_t)(capacity - frame->offset) >= (uint64_t)length + 77U;
}

char *ys_capture_document(const struct ys_control_capture *setup,
                           const struct ys_control_capture *control,
                           const struct ys_control_capture *counters, size_t *length)
{
    struct json_writer writer = {0};
    if (setup->incomplete || control->incomplete || counters->incomplete ||
        setup->length + control->length + counters->length > 4U * 1024U * 1024U -
            (sizeof "{\"control\":[],\"counters\":{},\"setup\":{}}\n" - 1U))
        return NULL;
    if (!json_appendf(&writer, "{\"control\":[%s],\"counters\":{%s},\"setup\":{%s}}\n",
        control->bytes ? control->bytes : "", counters->bytes ? counters->bytes : "",
        setup->bytes ? setup->bytes : "")) { free(writer.buf); return NULL; }
    *length = writer.len;
    return writer.buf;
}

void ys_capture_now(struct ys_control_capture *capture, int ok, const struct timespec *now,
                    int error_number)
{
    char row[256], error[32];
    int count;
    if (ok) strcpy(error, "null");
    else (void)snprintf(error, sizeof error, "%d", error_number);
    if (ok)
        count = snprintf(row, sizeof row, "{\"errno\":null,\"nsec\":%lld,\"sec\":%lld,\"tag\":\"now\"}",
                         (long long)now->tv_nsec, (long long)now->tv_sec);
    else
        count = snprintf(row, sizeof row, "{\"errno\":%s,\"nsec\":null,\"sec\":null,\"tag\":\"now\"}", error);
    if (count < 0 || (size_t)count >= sizeof row) capture->incomplete = 1;
    else capture_row(capture, row, (size_t)count);
}

void ys_capture_launch(struct ys_control_capture *capture, pid_t pid, int error_number)
{
    char row[128], error[32];
    int count;
    if (pid >= 0) strcpy(error, "null");
    else (void)snprintf(error, sizeof error, "%d", error_number);
    count = snprintf(row, sizeof row, "{\"errno\":%s,\"pid\":%lld,\"tag\":\"launch\"}", error, (long long)pid);
    if (count < 0 || (size_t)count >= sizeof row) capture->incomplete = 1;
    else capture_row(capture, row, (size_t)count);
}

void ys_capture_population(struct ys_control_capture *capture, ssize_t count, const char *bytes,
                           int error_number)
{
    char row[768], error[32], hex[513];
    int length;
    size_t size = count > 0 ? (size_t)count : 0U;
    if (size > 256U) { capture->incomplete = 1; return; }
    ys_hex_encode((const unsigned char *)bytes, size, hex); hex[size * 2U] = '\0';
    if (count >= 0) strcpy(error, "null");
    else (void)snprintf(error, sizeof error, "%d", error_number);
    length = snprintf(row, sizeof row, "{\"bytes\":\"%s\",\"errno\":%s,\"tag\":\"population\"}", hex, error);
    if (length < 0 || (size_t)length >= sizeof row) capture->incomplete = 1;
    else capture_row(capture, row, (size_t)length);
}

void ys_capture_kill(struct ys_control_capture *capture, int result, int error_number)
{
    char row[128], error[32];
    int length;
    if (result) strcpy(error, "null");
    else (void)snprintf(error, sizeof error, "%d", error_number);
    length = snprintf(row, sizeof row, "{\"errno\":%s,\"return\":%d,\"tag\":\"kill\"}", error, result);
    if (length < 0 || (size_t)length >= sizeof row) capture->incomplete = 1;
    else capture_row(capture, row, (size_t)length);
}

void ys_capture_fan_reply(struct ys_control_capture *capture, ssize_t result, int error_number)
{
    char row[160], error[32];
    int n;
    if (result < 0) snprintf(error, sizeof error, "%d", error_number);
    else strcpy(error, "null");
    n = snprintf(row, sizeof row, "{\"errno\":%s,\"return\":%lld,\"tag\":\"fan-reply\"}", error, (long long)result);
    if (n < 0 || (size_t)n >= sizeof row) capture->incomplete = 1;
    else capture_row(capture, row, (size_t)n);
}

void ys_capture_controls(struct ys_control_capture *capture, const struct ys_control_capture *rows)
{
    size_t at = 0;
    if (rows->incomplete) capture->incomplete = 1;
    while (!capture->incomplete && at < rows->length) {
        const char *end = strchr(rows->bytes + at, '}');
        if (end == NULL) { capture->incomplete = 1; return; }
        capture_row(capture, rows->bytes + at, (size_t)(end - rows->bytes) - at + 1U);
        at = (size_t)(end - rows->bytes) + 2U;
    }
}

void ys_capture_fan_read(struct ys_control_capture *capture, ssize_t result, int error_number,
                          const unsigned char *bytes, const struct ys_fan_stat *stats, size_t count)
{
    struct json_writer writer = {0};
    char hex[8193], error[32];
    size_t size = result > 0 ? (size_t)result : 0U, i;
    int saved = errno, prefix, suffix;
    if (size > 4096U || count > 170U) { capture->incomplete = 1; return; }
    ys_hex_encode(bytes, size, hex); hex[size * 2U] = '\0';
    if (result < 0) snprintf(error, sizeof error, "%d", error_number);
    else strcpy(error, "null");
    prefix = snprintf(NULL, 0, "{\"bytes\":\"%s\",\"errno\":%s,\"events\":[", hex, error);
    suffix = snprintf(NULL, 0, "],\"return\":%lld,\"tag\":\"fan-read\"}", (long long)result);
    if (prefix < 0 || suffix < 0 || (size_t)prefix + (size_t)suffix > 8192U ||
        !json_appendf(&writer, "{\"bytes\":\"%s\",\"errno\":%s,\"events\":[", hex, error)) goto fail;
    for (i = 0; i < count; i++) {
        struct ys_control_capture stat = {0};
        ys_capture_stat(&stat, "stat", stats[i].result, stats[i].error_number, &stats[i].value);
        int required;
        required = snprintf(NULL, 0, "%s{\"fd\":%d,%s}", i ? "," : "", stats[i].fd, stat.bytes ? stat.bytes : "");
        if (stat.incomplete || required < 0 || writer.len + (size_t)required + (size_t)suffix > 8192U ||
            !json_appendf(&writer, "%s{\"fd\":%d,%s}",
                                             i ? "," : "", stats[i].fd, stat.bytes)) {
            free(stat.bytes); goto fail;
        }
        free(stat.bytes);
    }
    if (!json_appendf(&writer, "],\"return\":%lld,\"tag\":\"fan-read\"}", (long long)result)) goto fail;
    capture_row(capture, writer.buf, writer.len);
    free(writer.buf); errno = saved; return;
fail:
    capture->incomplete = 1; free(writer.buf); errno = saved;
}

void ys_capture_event(struct ys_control_capture *capture, const struct ys_controller_event *event)
{
    char row[1024], error[32], hex[sizeof event->bytes * 2U + 1U];
    int count = -1, failed = 0;
    switch (event->action) {
    case YS_ACTION_NOW:
        ys_capture_now(capture, event->value, &event->now, event->error_number);
        return;
    case YS_ACTION_POLL: failed = event->value < 0; break;
    case YS_ACTION_WAIT: failed = event->waited < 0; break;
    case YS_ACTION_EXEC_READ: failed = event->read_count < 0; break;
    default: return;
    }
    if (!failed) strcpy(error, "null");
    else (void)snprintf(error, sizeof error, "%d", event->error_number);
    if (event->action == YS_ACTION_POLL) {
        struct json_writer writer = {0};
        size_t i;
        if (event->fd_count > 2U || !json_appendf(&writer,
                "{\"count\":%d,\"errno\":%s,\"revents\":[", event->value, error)) {
            capture->incomplete = 1; free(writer.buf); return;
        }
        for (i = 0; i < event->fd_count; i++) {
            if ((event->fd_roles[i] != 1 && event->fd_roles[i] != 2) ||
                !json_appendf(&writer, "%s{\"revents\":%d,\"role\":\"%s\"}",
                i ? "," : "", event->revents[i], event->fd_roles[i] == 1 ? "fan" : "exec")) {
                capture->incomplete = 1; free(writer.buf); return;
            }
        }
        if (!json_appendf(&writer, "],\"tag\":\"poll\"}")) capture->incomplete = 1;
        else capture_row(capture, writer.buf, writer.len);
        free(writer.buf); return;
    }
    else if (event->action == YS_ACTION_WAIT)
        count = snprintf(row, sizeof row,
            "{\"errno\":%s,\"pid\":%lld,\"status\":%d,\"tag\":\"wait\"}",
            error, (long long)event->waited, event->wait_status);
    else {
        size_t length = event->read_count > 0 ? (size_t)event->read_count : 0U;
        if (length > sizeof event->bytes) { capture->incomplete = 1; return; }
        ys_hex_encode(event->bytes, length, hex); hex[length * 2U] = '\0';
        count = snprintf(row, sizeof row,
            "{\"bytes\":\"%s\",\"eof\":%s,\"errno\":%s,\"tag\":\"exec-read\"}",
            hex, event->read_count == 0 ? "true" : "false", error);
    }
    if (count < 0 || (size_t)count >= sizeof row) capture->incomplete = 1;
    else capture_row(capture, row, (size_t)count);
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
    uint64_t write_mask = 0, read_mask = 0, events_mask = 0;
    int strict_capture = 0, memory_peak_ok = 0, pids_peak_ok = 0;
    int ok, inventory_ok, result = 1, plan_loaded = 0;
    (void)argv;
    memset(&report, 0, sizeof report); memset(&setup, 0, sizeof setup);
    if (argc != 1 || !value_read(&reader, magic, sizeof magic)) goto done;
    strict_capture = memcmp(magic, "YSVAL02\n", 8) == 0;
    if (!strict_capture && memcmp(magic, "YSVAL01\n", 8) != 0) goto done;
    plan_length = (size_t)value_uint(&reader);
    if (plan_length > 16U * 1024U * 1024U) goto done;
    plan_raw = malloc(plan_length == 0U ? 1U : plan_length);
    if (plan_raw == NULL || !value_read(&reader, plan_raw, plan_length) ||
        ys_plan_parse(plan_raw, plan_length, &plan) != YS_PLAN_OK) goto done;
    plan_loaded = 1;
    ys_sha256_bytes(plan_raw, plan_length, digest); ys_hex_encode(digest, sizeof digest, plan_hex);
    if (strict_capture) {
        write_mask = value_uint(&reader); read_mask = value_uint(&reader);
        int64_t initial_page_size;
        uint64_t candidate_bytes, candidate_inodes;
        events_mask = value_uint(&reader);
        initial_page_size = value_int(&reader);
        if (initial_page_size <= 0 ||
            !ys_candidate_geometry(&plan, (uint64_t)initial_page_size,
                                   &candidate_bytes, &candidate_inodes)) goto done;
    }
    for (i = 0; i < 4U; i++) {
        if (strict_capture) {
            char text[64];
            int64_t count = value_int(&reader), closed = value_int(&reader);
            if (!ys_setup_write_text(&plan.limits, i, text, sizeof text) || count < -1 ||
                count > (int64_t)strlen(text) || (closed != 0 && closed != -1)) goto done;
            setup.writes[i] = ys_write_count_values((ssize_t)count, strlen(text), (int)closed);
        } else setup.writes[i] = (int)value_uint(&reader);
        setup.reads[i] = (int)value_uint(&reader);
        value_text(&reader, setup.readbacks[i], sizeof setup.readbacks[i]);
    }
    setup.meminfo_ok = (int)value_uint(&reader); value_text(&reader, setup.meminfo, sizeof setup.meminfo);
    setup.output_ok = (int)value_uint(&reader);
    setup.output_blocks = value_uint(&reader); setup.output_fragment = value_uint(&reader); setup.output_files = value_uint(&reader);
    setup.scratch_ok = (int)value_uint(&reader);
    setup.scratch_blocks = value_uint(&reader); setup.scratch_fragment = value_uint(&reader); setup.scratch_files = value_uint(&reader);
    page_size = value_uint(&reader);
    if (strict_capture && !ys_setup_presence_values(&plan.limits, &setup, write_mask, read_mask)) goto done;
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
    ok = ys_u64_values(ok, peak, &value); memory_peak_ok = ok;
    value_text(&reader, events, sizeof events);
    ys_memory_values(&report.memory, report.tree_terminated, ok, value, events, 536870912ULL);
    ok = (int)value_uint(&reader); value_text(&reader, peak, sizeof peak);
    ok = ys_u64_values(ok, peak, &value); pids_peak_ok = ok;
    value_text(&reader, events, sizeof events);
    ys_tasks_values(&report.tasks, report.tree_terminated, ok, value, events, plan.limits.pids_max);
    if (strict_capture && !ys_counter_presence_values(memory_peak_ok, pids_peak_ok, events_mask)) goto done;
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
