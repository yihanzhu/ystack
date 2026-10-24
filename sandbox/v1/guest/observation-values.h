#ifndef YSTACK_OBSERVATION_VALUES_H
#define YSTACK_OBSERVATION_VALUES_H
#include "common.h"
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <time.h>
#include <sys/statvfs.h>

struct guest_row { uint64_t observed; const char *observation, *enforcement; int reached;
                    uint64_t resolution; };
struct report_state {
    int verifier_started, tree_deadline_fired, tree_terminated;
    int exit_signaled; int exit_code;
    uint64_t stdout_bytes, stderr_bytes;
    struct guest_row cpu, memory, output, tasks, scratch;
    char **evidence_names; size_t evidence_count;
};

struct ys_setup_observations {
    int writes[4], reads[4], meminfo_ok, output_ok, scratch_ok;
    char readbacks[4][128], meminfo[256];
    uint64_t output_blocks, output_fragment, output_files;
    uint64_t scratch_blocks, scratch_fragment, scratch_files;
};
struct ys_setup_flags { int cpu_hard, pids_hard, memory_hard, output_hard, scratch_hard; };
int ys_u64_values(int read_ok, const char *bytes, uint64_t *value);
int ys_readback_matches(int read_ok, const char *bytes, uint64_t expected);
int ys_write_count_values(ssize_t count, size_t requested, int close_result);
int ys_setup_write_text(const struct ys_plan_limits *limits, size_t slot, char *text, size_t capacity);
int ys_setup_presence_values(const struct ys_plan_limits *limits,
                              const struct ys_setup_observations *raw,
                              uint64_t write_mask, uint64_t read_mask);
int ys_counter_presence_values(int memory_peak_ok, int pids_peak_ok, uint64_t events_mask);
void ys_setup_values(const struct ys_plan_limits *limits, const struct ys_setup_observations *raw,
                      uint64_t memory_bound, struct ys_setup_flags *flags);
void ys_report_setup_values(struct report_state *state, const struct ys_setup_flags *flags,
                             uint64_t page_size);

int ys_checked_add_u64(uint64_t a, uint64_t b, uint64_t *out);
int ys_checked_mul_u64(uint64_t a, uint64_t b, uint64_t *out);
int ys_rounded_allocation(uint64_t bytes, uint64_t page_size, uint64_t *out);
int ys_candidate_geometry(const struct ys_guest_plan *plan, uint64_t page_size,
                          uint64_t *size_bytes, uint64_t *nr_inodes);
char *ys_build_report_json(const char plan_sha256_hex[65], const struct report_state *state,
                           const uint64_t *evidence_sizes, size_t *length);
void ys_cpu_values(struct guest_row *row, int terminated, const char *cpu_stat, uint64_t bound);
void ys_memory_values(struct guest_row *row, int terminated, int peak_ok, uint64_t peak,
                      const char *events, uint64_t bound);
void ys_tasks_values(struct guest_row *row, int terminated, int peak_ok, uint64_t peak,
                     const char *events, uint64_t bound);
void ys_output_values(struct guest_row *row, int inventory_ok, uint64_t total,
                      int filesystem_ok, uint64_t free_blocks, uint64_t bound);
void ys_scratch_values(struct guest_row *row, int filesystem_ok, uint64_t blocks,
                       uint64_t free_blocks, uint64_t fragment_size, uint64_t bound);
struct exec_channel_state {
    unsigned char bytes[sizeof(struct ys_exec_outcome) * 2U];
    size_t length;
    int eof, invalid;
};
enum controller_branch { CONTROLLER_FAILURE, CONTROLLER_NORMAL };
struct controller_result {
    int child_status, child_reaped, tree_terminated, deadline_fired;
    int containment_failure, kill_failed, verifier_started;
};
enum ys_controller_action {
    YS_ACTION_NOW, YS_ACTION_POLL, YS_ACTION_WAIT, YS_ACTION_POPULATION,
    YS_ACTION_EXEC_READ, YS_ACTION_FAN_READ, YS_ACTION_KILL, YS_ACTION_TICK_NOW,
    YS_ACTION_DONE
};
struct ys_controller_event {
    enum ys_controller_action action;
    int value, error_number, wait_status;
    pid_t waited;
    struct timespec now;
    short revents[2];
    size_t fd_count;
    int fd_roles[2];
    ssize_t read_count;
    unsigned char bytes[sizeof(struct ys_exec_outcome) * 2U];
};
struct ys_control_capture {
    char *bytes;
    size_t length, capacity, count, raw_cursor;
    int incomplete;
};
void ys_capture_stat(struct ys_control_capture *capture, const char *site,
                       int result, int error_number, const struct stat *st);
void ys_capture_statvfs(struct ys_control_capture *capture, const char *site,
                          int result, int error_number, const struct statvfs *sv);
struct ys_evidence_capture { struct ys_control_capture *capture; size_t count; };
void ys_capture_evidence_entry(const char *name, int result, int error_number,
                                 const struct stat *st, void *context);
void ys_capture_raw(struct ys_control_capture *capture, const char *row, size_t length);
void ys_capture_io(struct ys_control_capture *capture, const char *name, long long result,
                     int error_number, const void *bytes, size_t length);
int ys_capture_fits(const struct ys_frame_writer *frame, off_t capacity, size_t length);
char *ys_capture_document(const struct ys_control_capture *setup,
                           const struct ys_control_capture *control,
                           const struct ys_control_capture *counters, size_t *length);
void ys_capture_now(struct ys_control_capture *capture, int ok, const struct timespec *now, int error_number);
void ys_capture_launch(struct ys_control_capture *capture, pid_t pid, int error_number);
void ys_capture_event(struct ys_control_capture *capture, const struct ys_controller_event *event);
void ys_capture_population(struct ys_control_capture *capture, ssize_t count, const char *bytes, int error_number);
struct ys_fan_stat { int fd, result, error_number; struct stat value; };
void ys_capture_fan_read(struct ys_control_capture *capture, ssize_t result, int error_number,
                          const unsigned char *bytes, const struct ys_fan_stat *stats, size_t count);
void ys_capture_fan_reply(struct ys_control_capture *capture, ssize_t result, int error_number);
void ys_capture_controls(struct ys_control_capture *capture, const struct ys_control_capture *rows);
void ys_capture_kill(struct ys_control_capture *capture, int result, int error_number);
struct ys_controller_state {
    int phase, has_fan, remaining, polled;
    size_t count, current;
    short revents[2];
    pid_t child, waited;
    int status;
    struct timespec deadline;
    struct exec_channel_state outcome;
    struct controller_result result;
    enum controller_branch branch;
    enum ys_controller_action expected;
};
int ys_deadline_after_ms(const struct timespec *start, uint64_t milliseconds, struct timespec *deadline);
int ys_launch_pid_valid(pid_t child);
struct seen_inode { dev_t dev; ino_t ino; };
int ys_inode_history_record(struct seen_inode seen[256], size_t *count, dev_t dev, ino_t ino);
int ys_fan_open_values(struct seen_inode seen[256], size_t *count, int stat_result,
                       mode_t mode, int64_t size, dev_t dev, ino_t ino);
int ys_population_values(int read_ok, const char *bytes);
int ys_fan_next(const unsigned char *bytes, size_t length, size_t offset, int *event_fd, size_t *next);
int ys_deadline_remaining(const struct timespec *deadline, int ok, const struct timespec *now, int *milliseconds);
int ys_exec_read_values(struct exec_channel_state *state, ssize_t count, int error_number,
                        const unsigned char *bytes);
int ys_execution_was_verified(const struct exec_channel_state *state, int status,
                              int reaped, int terminated, int deadline, int containment);
void ys_controller_init(struct ys_controller_state *state, pid_t child, int has_fan,
                         const struct timespec *deadline);
enum ys_controller_action ys_controller_step(struct ys_controller_state *state,
                                               const struct ys_controller_event *event);
#ifdef YSTACK_SUPERVISOR_TEST
extern size_t ys_test_report_cap_limit;
extern int ys_test_format_failure;
#endif
#endif
