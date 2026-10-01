/* Guest supervisor, VM launcher and supervisor (ystack #463), PR 6 of 9.
 * See work/vm-launcher-supervisor/plan.md ("PR 6") and spec.md R2.5,
 * R5.5-R9.1: reads the input disk plan and candidate, materializes the
 * candidate/tools/output/scratch tmpfs, builds the tree cgroup (R7.1),
 * clone3's the verifier into new namespaces with its identity dropped
 * (R6.1), applies Landlock (R6.2) and seccomp (R6.3), wires argv/env/fds
 * (R6.4), enforces the 40,000 ms tree deadline with a fanotify first-open
 * rule on the evidence tmpfs (R7.1's output_bytes row), collects the five
 * guest-reported limit rows (R7.3), writes report.json plus stdout/stderr/
 * evidence to the export disk (R8), syncs and powers off (R9.1).
 *
 * Inactive: nothing here runs outside a guest VM this concern does not
 * boot (R14.1); the honest limits of what is proven before native
 * qualification are R15.4's. Linux-only, like init.c: never built on a
 * non-Linux host (see scripts/test/sandbox-guest.test.sh, which names the
 * compile of this file Linux-only on Darwin). Every UAPI syscall number
 * used below is guarded by `#if defined(SYS_x)` (the sandbox-guest common
 * code's own close_range precedent) so a syscall CI's headers do not yet
 * define degrades to a reported setup failure rather than a build error;
 * a seccomp deny-list entry aarch64 itself lacks a number for (mknod) is
 * added to the filter only `#ifdef __NR_mknod`. */
#if !defined(__linux__)
#error "sandbox/v1/guest/supervisor.c is a Linux guest supervisor; it is never built on a non-Linux host"
#endif

#define _GNU_SOURCE
#include "common.h"
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <limits.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/fanotify.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/reboot.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef SECCOMP_RET_ACTION_FULL
#define SECCOMP_RET_ACTION_FULL 0xffff0000U
#endif

/* --- disk layout (R5.4): the two virtio-blk devices, in the order the
 * vfkit argv (plan.md "Interfaces fixed by this plan") attaches them --
 * input first, read-only, then export, read-write. Linux enumerates
 * virtio-blk devices in PCI probe order, which follows device-declaration
 * order for the one hypervisor front end this concern uses (vfkit). ---- */
#define INPUT_DEVICE "/dev/vda"
#define EXPORT_DEVICE "/dev/vdb"

/* Supervisor-side paths (this process's own, original mount namespace) for
 * the four guest tmpfs mounts, and the pivot_root staging tree the child
 * process (R6.1) is handed a prepared copy of via bind mounts made before
 * clone3 -- so the child itself never has to mount anything at all. */
#define CANDIDATE_DIR "/ys/candidate"
#define TOOLS_DIR "/ys/tools"
#define SCRATCH_DIR "/ys/scratch"
#define OUTPUT_DIR "/ys/output"
#define EVIDENCE_SUBDIR "/ys/output/evidence"
#define NEWROOT_DIR "/ys/newroot"
#define CGROUP_ROOT "/sys/fs/cgroup"
#define TREE_CGROUP "/sys/fs/cgroup/tree"

#define GUEST_UID 65534U
#define GUEST_GID 65534U
/* R7.1's cpu_time_ms bound is a fixed host constant
 * (sandbox/v1/host-supervisor.py's LIMIT_ROWS), not a plan.json field: the
 * plan carries the cgroup quota inputs (cpu_max, the percentage; cpu_max_
 * burst; bandwidth_slice_us) but no millisecond ceiling of its own, since
 * enforcement stays "none" either way (R7.2). Kept in sync by comment,
 * exactly like the host's own hardcoded value. */
#define CPU_TIME_BOUND_MS 30000ULL
#define GUEST_MEMORY_BYTES 536870912ULL

static void die(const char *what)
{
    fprintf(stderr, "supervisor: %s: %s\n", what, strerror(errno));
    _exit(1);
}

static int write_file(const char *path, const char *data, size_t len)
{
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    ssize_t n;
    if (fd < 0) return 0;
    n = write(fd, data, len);
    if (close(fd) != 0) return 0;
    return n == (ssize_t)len;
}

static int write_str(const char *path, const char *s) { return write_file(path, s, strlen(s)); }

/* Reads a whole regular file (bounded by `cap`) for a readback/counter
 * check; returns bytes read, or -1. Never used on the multi-megabyte
 * export streams (read_whole_alloc, below, handles those). */
static ssize_t read_file(const char *path, char *buf, size_t cap)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    ssize_t n;
    if (fd < 0) return -1;
    n = read(fd, buf, cap - 1);
    (void)close(fd);
    if (n < 0) return -1;
    buf[n] = '\0';
    return n;
}

static int read_u64(const char *path, uint64_t *out)
{
    char buf[128];
    if (read_file(path, buf, sizeof buf) < 0) return 0;
    *out = strtoull(buf, NULL, 10);
    return 1;
}

/* True iff `path`'s first token equals `want` exactly (a cgroup R7.1
 * parameter's own readback: "45000 100000" must be read back matching
 * what was written, not merely parsed and re-derived). */
static int file_starts_with_u64(const char *path, uint64_t want)
{
    uint64_t got;
    return read_u64(path, &got) && got == want;
}

/* --- reading the whole input frame into memory ---------------------------- */
struct loaded_input {
    unsigned char *plan_bytes;
    size_t plan_len;
    unsigned char *instruction;
    size_t instruction_len;
    unsigned char *verifier;
    size_t verifier_len;
    unsigned char **candidates;
    size_t *candidate_lens;
    size_t candidate_count;
};

static void loaded_input_free(struct loaded_input *input)
{
    size_t i;
    free(input->plan_bytes); free(input->instruction); free(input->verifier);
    for (i = 0; i < input->candidate_count; i++) free(input->candidates[i]);
    free(input->candidates); free(input->candidate_lens);
    memset(input, 0, sizeof *input);
}

static unsigned char *take_content(struct ys_frame_record *rec, size_t *len_out)
{
    unsigned char *p = rec->content;
    *len_out = (size_t)rec->length;
    rec->content = NULL;
    return p;
}

/* Reads every record of the input set (R5.2) off `fd` in order, handing
 * ownership of each record's malloc'd bytes into `out`. Returns 0 on any
 * frame or record-set violation (truncation, digest, name, index); the
 * caller treats that exactly like a damaged input disk -- setup fails,
 * nothing is exported (there is no verifier to have "started"). */
static int load_input(int fd, struct loaded_input *out)
{
    struct ys_frame_reader r;
    struct ys_record_set_state set;
    off_t cap;
    size_t cand_cap = 0;
    memset(out, 0, sizeof *out);
    if (ys_frame_descriptor_capacity(fd, &cap) != YS_FRAME_OK) goto fail;
    if (ys_frame_reader_open(&r, fd, cap) != YS_FRAME_OK) goto fail;
    ys_record_set_init(&set, YS_RECORD_SET_INPUT);
    for (;;) {
        struct ys_frame_record rec;
        enum ys_frame_status st;
        uint32_t index;
        memset(&rec, 0, sizeof rec);
        st = ys_frame_reader_next(&r, &rec);
        if (st != YS_FRAME_OK) goto fail;
        if (rec.is_end) {
            if (ys_record_set_finish(&set) == YS_FRAME_OK) return 1;
            goto fail;
        }
        st = ys_record_set_advance(&set, rec.name, rec.name_len, &index);
        if (st != YS_FRAME_OK) { free(rec.content); goto fail; }
        if (rec.name_len == 9U && memcmp(rec.name, "plan.json", 9U) == 0) {
            out->plan_bytes = take_content(&rec, &out->plan_len);
        } else if (rec.name_len == 11U && memcmp(rec.name, "instruction", 11U) == 0) {
            out->instruction = take_content(&rec, &out->instruction_len);
        } else if (rec.name_len == 8U && memcmp(rec.name, "verifier", 8U) == 0) {
            out->verifier = take_content(&rec, &out->verifier_len);
        } else {
            if (index >= cand_cap) {
                size_t nc = (cand_cap == 0U) ? 8U : cand_cap * 2U;
                unsigned char **cg = realloc(out->candidates, nc * sizeof *cg);
                size_t *lg;
                if (cg == NULL) { free(rec.content); goto fail; }
                out->candidates = cg;
                lg = realloc(out->candidate_lens, nc * sizeof *lg);
                if (lg == NULL) { free(rec.content); goto fail; }
                out->candidate_lens = lg; cand_cap = nc;
            }
            out->candidates[index] = take_content(&rec, &out->candidate_lens[index]);
            if (index + 1U > out->candidate_count) out->candidate_count = index + 1U;
        }
        free(rec.content);
    }
fail:
    loaded_input_free(out);
    return 0;
}

static int candidate_count_matches(const struct ys_guest_plan *plan, size_t candidate_count)
{
    size_t files = 0, i;
    for (i = 0; i < plan->entry_count; i++) {
        if (plan->entries[i].is_file) {
            if (files == SIZE_MAX) return 0;
            files++;
        }
    }
    return files == candidate_count;
}

/* --- tmpfs mounts ----------------------------------------------------------
 * Every guest tmpfs is sized with slack beyond the raw file-byte total: a
 * tmpfs charges directory entries and inode metadata against its own
 * `size=` budget in page units, so "sized for exactly its files" (R5.5)
 * still needs room for the directory tree a manifest with subdirectories
 * materializes -- one page per directory is a generous, fixed allowance. */
static int mount_tmpfs(const char *target, uint64_t size_bytes, uint64_t nr_inodes)
{
    char opts[128];
    int n = snprintf(opts, sizeof opts, "size=%llu,nr_inodes=%llu,mode=0700",
                      (unsigned long long)size_bytes, (unsigned long long)nr_inodes);
    if (n < 0 || (size_t)n >= sizeof opts) return 0;
    return mount("tmpfs", target, "tmpfs", MS_NOSUID, opts) == 0;
}

static int checked_add_u64(uint64_t a, uint64_t b, uint64_t *out)
{
    if (UINT64_MAX - a < b) return 0;
    *out = a + b;
    return 1;
}

static int checked_mul_u64(uint64_t a, uint64_t b, uint64_t *out)
{
    if (a != 0U && b > UINT64_MAX / a) return 0;
    *out = a * b;
    return 1;
}

static int rounded_allocation(uint64_t bytes, uint64_t page_size, uint64_t *out)
{
    uint64_t with_slack;
    if (page_size == 0U) return 0;
    if (bytes == 0U) { *out = 0U; return 1; }
    if (!checked_add_u64(bytes, page_size - 1U, &with_slack)) return 0;
    *out = (with_slack / page_size) * page_size;
    return 1;
}

static int candidate_geometry(const struct ys_guest_plan *plan, uint64_t page_size,
                              uint64_t *size_bytes, uint64_t *nr_inodes)
{
    uint64_t data = 0U, directories = 1U, metadata, rounded;
    size_t i;
    for (i = 0; i < plan->entry_count; i++) {
        if (plan->entries[i].is_file) {
            if (!rounded_allocation(plan->entries[i].size_bytes, page_size, &rounded) ||
                !checked_add_u64(data, rounded, &data))
                return 0;
        } else if (!checked_add_u64(directories, 1U, &directories)) {
            return 0;
        }
    }
    /* One page per directory covers tmpfs directory-entry and inode metadata. */
    if (!checked_mul_u64(directories, page_size, &metadata) ||
        !checked_add_u64(data, metadata, size_bytes))
        return 0;
    if (*size_bytes == 0U) *size_bytes = page_size;
    if (plan->entry_count == SIZE_MAX ||
        !checked_add_u64(1U, (uint64_t)plan->entry_count, nr_inodes))
        return 0;
    return *nr_inodes > 0U;
}

static int mkdir_p(const char *path, mode_t mode)
{
    if (mkdir(path, mode) == 0) return 1;
    return errno == EEXIST;
}

static int make_searchable_read_only(const char *path)
{
    return chmod(path, 0555) == 0;
}

/* MS_REMOUNT|MS_BIND scopes the new flags to this one mountpoint (the
 * classic "mount -o remount,bind,ro" idiom, which applies to any existing
 * mount, not only one created by an earlier bind): every flag meant to
 * persist -- MS_NOSUID here, since every R6.1 mount needs it -- must be
 * repeated, or this remount silently drops it rather than merely adding
 * MS_RDONLY on top of what was there. */
static int remount_ro(const char *target, unsigned long extra)
{
    return mount(NULL, target, NULL, MS_REMOUNT | MS_BIND | MS_NOSUID | MS_RDONLY | extra, NULL) ==
           0;
}

/* Binds `src` (an already-mounted, already-finalized tmpfs in this
 * process's own namespace) onto `<NEWROOT_DIR>/sandbox/<leaf>` (R6.1's and
 * R6.4's fixed `/sandbox/...` paths -- the argv, PATH and TMPDIR wiring in
 * common.c's YS_PLAN_ARGV/YS_PLAN_ENVIRONMENT all assume this exact tree),
 * then tightens the bind's own flags to R6.1's per-mount set (a bind
 * mount's flags are set on the bind itself, not inherited from the source
 * mount). `ro` also requests MS_RDONLY; `noexec` also requests MS_NOEXEC.
 * Both mounts exist afterward in this process's namespace;
 * clone3(CLONE_NEWNS) below hands the child a private copy of the whole
 * tree, bind included. */
static int bind_into_newroot(const char *src, const char *leaf, int ro, int noexec)
{
    char dst[256];
    unsigned long flags = MS_NOSUID | MS_NODEV;
    int n = snprintf(dst, sizeof dst, "%s/sandbox/%s", NEWROOT_DIR, leaf);
    if (n < 0 || (size_t)n >= sizeof dst) return 0;
    if (!mkdir_p(dst, 0500)) return 0;
    if (mount(src, dst, NULL, MS_BIND, NULL) != 0) return 0;
    if (ro) flags |= MS_RDONLY;
    if (noexec) flags |= MS_NOEXEC;
    return mount(NULL, dst, NULL, MS_REMOUNT | MS_BIND | flags, NULL) == 0;
}

/* --- R7.1: the tree cgroup -------------------------------------------------
 * Enables the three controllers this concern uses in the cgroup2 root,
 * creates the tree cgroup, writes every R7.1 parameter this component
 * configures and reads each one back: `enforcement: "hard"` for a row
 * requires every configured parameter to have been confirmed this way
 * (R7.3), never merely written. */
struct cgroup_setup {
    int cpu_hard, pids_hard, memory_hard, output_hard, scratch_hard;
    int cgroup_fd;
};

/* /proc/meminfo's first line is "MemTotal:%8lu kB\n". */
static int read_u64_kb(const char *path, uint64_t *out)
{
    char buf[256];
    const char *p;
    if (read_file(path, buf, sizeof buf) < 0) return 0;
    p = strchr(buf, ':');
    if (p == NULL) return 0;
    *out = strtoull(p + 1, NULL, 10);
    return 1;
}

static int setup_cgroup(const struct ys_plan_limits *lim, struct cgroup_setup *out)
{
    char buf[64];
    uint64_t mem_total_kb = 0;
    memset(out, 0, sizeof *out);
    out->cgroup_fd = -1;
    if (!write_str(CGROUP_ROOT "/cgroup.subtree_control", "+cpu +pids +memory\n")) return 0;
    if (!mkdir_p(TREE_CGROUP, 0755)) return 0;
    snprintf(buf, sizeof buf, "%llu 100000\n", (unsigned long long)lim->cpu_max);
    if (write_str(TREE_CGROUP "/cpu.max", buf) &&
        file_starts_with_u64(TREE_CGROUP "/cpu.max", lim->cpu_max)) {
        snprintf(buf, sizeof buf, "%llu\n", (unsigned long long)lim->cpu_max_burst);
        if (write_str(TREE_CGROUP "/cpu.max.burst", buf) &&
            file_starts_with_u64(TREE_CGROUP "/cpu.max.burst", lim->cpu_max_burst)) {
            snprintf(buf, sizeof buf, "%llu\n", (unsigned long long)lim->bandwidth_slice_us);
            if (write_str("/proc/sys/kernel/sched_cfs_bandwidth_slice_us", buf) &&
                file_starts_with_u64("/proc/sys/kernel/sched_cfs_bandwidth_slice_us",
                                      lim->bandwidth_slice_us))
                out->cpu_hard = 1;
        }
    }
    snprintf(buf, sizeof buf, "%llu\n", (unsigned long long)lim->pids_max);
    if (write_str(TREE_CGROUP "/pids.max", buf) &&
        file_starts_with_u64(TREE_CGROUP "/pids.max", lim->pids_max))
        out->pids_hard = 1;
    /* memory_bytes (R7 table): the configured "parameter" is the guest's
     * own fixed RAM ceiling (there is no per-tree memory.max this concern
     * sets: the bound is the VM's shape, R5.4), confirmed by reading it
     * back from the kernel rather than trusting the boot command line. */
    if (read_u64_kb("/proc/meminfo", &mem_total_kb) && mem_total_kb * 1024ULL <= GUEST_MEMORY_BYTES)
        out->memory_hard = 1;
    {
        struct statvfs sv;
        if (statvfs(OUTPUT_DIR, &sv) == 0 &&
            (uint64_t)sv.f_blocks * sv.f_frsize == lim->output_tmpfs_bytes &&
            (uint64_t)sv.f_files == lim->output_inodes)
            out->output_hard = 1;
        if (statvfs(SCRATCH_DIR, &sv) == 0 &&
            (uint64_t)sv.f_blocks * sv.f_frsize == lim->scratch_bytes &&
            (uint64_t)sv.f_files == lim->scratch_inodes)
            out->scratch_hard = 1;
    }
    out->cgroup_fd = open(TREE_CGROUP, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    return out->cgroup_fd >= 0;
}

static int cgroup_populated(void)
{
    char buf[256];
    char *line;
    if (read_file(TREE_CGROUP "/cgroup.events", buf, sizeof buf) < 0) return -1;
    line = strstr(buf, "populated ");
    if (line == NULL) return -1;
    return (line[10] == '0') ? 0 : 1;
}

#ifdef YSTACK_SUPERVISOR_TEST
static int (*ys_test_population_reader)(void);
#endif

static int confirm_tree_terminated(unsigned attempts)
{
    unsigned i;
    for (i = 0; i < attempts; i++) {
        int populated;
#ifdef YSTACK_SUPERVISOR_TEST
        populated = ys_test_population_reader != NULL ? ys_test_population_reader() : -1;
#else
        populated = cgroup_populated();
#endif
        if (populated < 0) return 0;
        if (populated == 0) return 1;
#ifndef YSTACK_SUPERVISOR_TEST
        {
            struct timespec ts = { 0, 100000000L };
            nanosleep(&ts, NULL);
        }
#endif
    }
    return 0;
}

/* --- clone3 (R6.1) ---------------------------------------------------------
 * This concern's own clone_args, not the system header's: CI's kernel
 * headers may predate the `cgroup` field (Linux 5.7, CLONE_ARGS_SIZE_VER2)
 * even where <linux/sched.h> already has an older `struct clone_args`, so
 * relying on that struct's layout would silently misplace every field
 * after it. The kernel's copy_struct_from_user accepts any size up to what
 * it knows, zero-extending what a shorter caller struct would have; this
 * one is exactly the version-2 (88-byte) shape clone3(2) documents. */
struct ys_clone_args {
    uint64_t flags, pidfd, child_tid, parent_tid, exit_signal, stack, stack_size, tls, set_tid,
        set_tid_size, cgroup;
};
#ifndef CLONE_INTO_CGROUP
#define CLONE_INTO_CGROUP 0x200000000ULL
#endif
#ifndef CLONE_NEWCGROUP
#define CLONE_NEWCGROUP 0x02000000
#endif

static pid_t ys_clone3_into_cgroup(int cgroup_fd)
{
#if defined(SYS_clone3)
    struct ys_clone_args args;
    memset(&args, 0, sizeof args);
    args.flags = CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWNET | CLONE_NEWIPC | CLONE_NEWUTS |
                 CLONE_INTO_CGROUP;
    args.exit_signal = SIGCHLD;
    args.cgroup = (uint64_t)cgroup_fd;
    return (pid_t)syscall(SYS_clone3, &args, sizeof args);
#else
    (void)cgroup_fd;
    errno = ENOSYS;
    return -1;
#endif
}

/* --- child setup: pivot_root, identity drop, Landlock, seccomp ------------ */
#ifndef SYS_capset
#define YS_NO_CAPSET 1
#endif
struct ys_cap_header { uint32_t version; int pid; };
struct ys_cap_data { uint32_t effective, permitted, inheritable; };
#define YS_CAP_VERSION_3 0x20080522U

static int drop_bounding_capabilities(void)
{
    int i;
    for (i = 0; i <= 63; i++) {
        int present = prctl(PR_CAPBSET_READ, i, 0, 0, 0);
        if (present < 0) {
            if (errno == EINVAL) break;
            return 0;
        }
        if (present != 0 && prctl(PR_CAPBSET_DROP, i, 0, 0, 0) != 0) return 0;
    }
    return 1;
}

static int clear_all_capabilities(void)
{
#ifndef YS_NO_CAPSET
    {
        struct ys_cap_header hdr = { YS_CAP_VERSION_3, 0 };
        struct ys_cap_data data[2];
        memset(data, 0, sizeof data);
        if (syscall(SYS_capset, &hdr, data) != 0) return 0;
        return prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) == 0;
    }
#else
    return 0;
#endif
}

static int final_privilege_state_ok(void)
{
#if defined(SYS_capget)
    struct ys_cap_header hdr = { YS_CAP_VERSION_3, 0 };
    struct ys_cap_data data[2];
    gid_t groups[1];
    int i;
    memset(data, 0xff, sizeof data);
    if (getuid() != GUEST_UID || geteuid() != GUEST_UID || getgid() != GUEST_GID ||
        getegid() != GUEST_GID || getgroups(1, groups) != 0 ||
        syscall(SYS_capget, &hdr, data) != 0 || prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) != 1)
        return 0;
    for (i = 0; i < 2; i++)
        if (data[i].effective != 0U || data[i].permitted != 0U || data[i].inheritable != 0U)
            return 0;
    for (i = 0; i <= 63; i++) {
        int present = prctl(PR_CAPBSET_READ, i, 0, 0, 0);
        if (present < 0) {
            if (errno == EINVAL) break;
            return 0;
        }
        if (present != 0) return 0;
    }
    return 1;
#else
    return 0;
#endif
}

enum privilege_step {
    PRIV_CLEAR_GROUPS,
    PRIV_SET_GIDS,
    PRIV_DROP_BOUNDING,
    PRIV_SET_UIDS,
    PRIV_CLEAR_CAPS,
    PRIV_NO_NEW_PRIVS,
    PRIV_VERIFY
};

static int actual_privilege_step(enum privilege_step step, void *unused)
{
    (void)unused;
    switch (step) {
    case PRIV_CLEAR_GROUPS: return setgroups(0, NULL) == 0;
    case PRIV_SET_GIDS: return setresgid(GUEST_GID, GUEST_GID, GUEST_GID) == 0;
    case PRIV_DROP_BOUNDING: return drop_bounding_capabilities();
    case PRIV_SET_UIDS: return setresuid(GUEST_UID, GUEST_UID, GUEST_UID) == 0;
    case PRIV_CLEAR_CAPS: return clear_all_capabilities();
    case PRIV_NO_NEW_PRIVS: return prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0;
    case PRIV_VERIFY: return final_privilege_state_ok();
    }
    return 0;
}

static int run_privilege_sequence(int (*perform)(enum privilege_step, void *), void *ctx)
{
    static const enum privilege_step order[] = {
        PRIV_CLEAR_GROUPS, PRIV_SET_GIDS, PRIV_DROP_BOUNDING, PRIV_SET_UIDS,
        PRIV_CLEAR_CAPS, PRIV_NO_NEW_PRIVS, PRIV_VERIFY
    };
    size_t i;
    for (i = 0; i < sizeof order / sizeof order[0]; i++)
        if (!perform(order[i], ctx)) return 0;
    return 1;
}

/* Landlock (R6.2): this concern's own attr/rule structs (not
 * <linux/landlock.h>'s), so an older installed header that predates ABI 6's
 * `scoped` ruleset-attr field never mis-sizes the syscall's own copy --
 * the kernel accepts any struct at least as large as the ABI version it
 * implements and zero-extends the rest (landlock_create_ruleset(2)). */
struct ys_landlock_ruleset_attr { uint64_t handled_access_fs, handled_access_net, scoped; };
struct ys_landlock_path_beneath_attr { uint64_t allowed_access; int32_t parent_fd; };
#define YS_LL_RULE_PATH_BENEATH 1U
#define YS_LL_FS_EXECUTE (1ULL << 0)
#define YS_LL_FS_WRITE_FILE (1ULL << 1)
#define YS_LL_FS_READ_FILE (1ULL << 2)
#define YS_LL_FS_READ_DIR (1ULL << 3)
#define YS_LL_FS_REMOVE_DIR (1ULL << 4)
#define YS_LL_FS_REMOVE_FILE (1ULL << 5)
#define YS_LL_FS_MAKE_CHAR (1ULL << 6)
#define YS_LL_FS_MAKE_DIR (1ULL << 7)
#define YS_LL_FS_MAKE_REG (1ULL << 8)
#define YS_LL_FS_MAKE_SOCK (1ULL << 9)
#define YS_LL_FS_MAKE_FIFO (1ULL << 10)
#define YS_LL_FS_MAKE_BLOCK (1ULL << 11)
#define YS_LL_FS_MAKE_SYM (1ULL << 12)
#define YS_LL_FS_REFER (1ULL << 13)
#define YS_LL_FS_TRUNCATE (1ULL << 14)
#define YS_LL_FS_IOCTL_DEV (1ULL << 15)
#define YS_LL_FS_ALL_ABI5 \
    (YS_LL_FS_EXECUTE | YS_LL_FS_WRITE_FILE | YS_LL_FS_READ_FILE | YS_LL_FS_READ_DIR | \
     YS_LL_FS_REMOVE_DIR | YS_LL_FS_REMOVE_FILE | YS_LL_FS_MAKE_CHAR | YS_LL_FS_MAKE_DIR | \
     YS_LL_FS_MAKE_REG | YS_LL_FS_MAKE_SOCK | YS_LL_FS_MAKE_FIFO | YS_LL_FS_MAKE_BLOCK | \
     YS_LL_FS_MAKE_SYM | YS_LL_FS_REFER | YS_LL_FS_TRUNCATE | YS_LL_FS_IOCTL_DEV)
/* ABI 6 scopes: newer than CI's <linux/landlock.h> may define (plan.md
 * "Host code is stdlib ... UAPI constants newer than CI's headers"). */
#ifndef YS_LL_SCOPE_ABSTRACT_UNIX_SOCKET
#define YS_LL_SCOPE_ABSTRACT_UNIX_SOCKET (1ULL << 0)
#endif
#ifndef YS_LL_SCOPE_SIGNAL
#define YS_LL_SCOPE_SIGNAL (1ULL << 1)
#endif

static int landlock_grant(int ruleset_fd, const char *path, uint64_t access)
{
#if defined(SYS_landlock_add_rule)
    struct ys_landlock_path_beneath_attr attr;
    int pfd = open(path, O_PATH | O_CLOEXEC);
    int rc;
    if (pfd < 0) return 0;
    attr.allowed_access = access;
    attr.parent_fd = pfd;
    rc = (int)syscall(SYS_landlock_add_rule, ruleset_fd, YS_LL_RULE_PATH_BENEATH, &attr, 0);
    (void)close(pfd);
    return rc == 0;
#else
    (void)ruleset_fd; (void)path; (void)access;
    return 0;
#endif
}

/* Grants exactly the four per-directory right sets of R6.2, over every FS
 * right through Landlock ABI 5 (R6.2: "handling every filesystem right of
 * ABI 6"; ABI 6 itself adds only the scopes below, no new FS right) plus
 * scoped abstract Unix sockets and signals. */
static int apply_landlock(void)
{
#if defined(SYS_landlock_create_ruleset) && defined(SYS_landlock_restrict_self)
    struct ys_landlock_ruleset_attr attr;
    int fd;
    memset(&attr, 0, sizeof attr);
    attr.handled_access_fs = YS_LL_FS_ALL_ABI5;
    attr.scoped = YS_LL_SCOPE_ABSTRACT_UNIX_SOCKET | YS_LL_SCOPE_SIGNAL;
    fd = (int)syscall(SYS_landlock_create_ruleset, &attr, sizeof attr, 0);
    if (fd < 0) return 0;
    if (!landlock_grant(fd, "/sandbox/candidate", YS_LL_FS_READ_FILE | YS_LL_FS_READ_DIR) ||
        !landlock_grant(fd, "/sandbox/tools",
                         YS_LL_FS_EXECUTE | YS_LL_FS_READ_FILE | YS_LL_FS_READ_DIR) ||
        !landlock_grant(fd, "/sandbox/scratch", YS_LL_FS_READ_FILE | YS_LL_FS_READ_DIR |
                                           YS_LL_FS_WRITE_FILE | YS_LL_FS_MAKE_REG |
                                           YS_LL_FS_MAKE_DIR) ||
        !landlock_grant(fd, "/sandbox/evidence", YS_LL_FS_WRITE_FILE | YS_LL_FS_MAKE_REG)) {
        (void)close(fd);
        return 0;
    }
    if (syscall(SYS_landlock_restrict_self, fd, 0) != 0) { (void)close(fd); return 0; }
    (void)close(fd);
    return 1;
#else
    return 0;
#endif
}

/* seccomp (R6.3): default allow, EPERM for the closed list, checked only
 * for AUDIT_ARCH_AARCH64 (any other reporting architecture is refused
 * outright rather than falling through to the allow default, since a
 * syscall number is only meaningful within its own arch's table). Built
 * as a linear "if nr == X then EPERM" chain: `add_deny` appends one
 * self-contained two-instruction pair per syscall, so no jump-offset
 * arithmetic threads through the whole list. Three entries additionally
 * gate on one argument (openat's O_TMPFILE, madvise's MADV_REMOVE, clone's
 * CLONE_NEW* mask); each reloads the syscall number afterward since
 * loading an argument overwrites the accumulator the plain checks rely on. */
#define YS_SECCOMP_MAX_INSN 512
struct seccomp_prog_builder {
    struct sock_filter insn[YS_SECCOMP_MAX_INSN];
    size_t n;
    int failed;
};
static void sb_push(struct seccomp_prog_builder *b, struct sock_filter f)
{
    if (b->n < YS_SECCOMP_MAX_INSN) b->insn[b->n++] = f;
    else b->failed = 1;
}
static void add_deny(struct seccomp_prog_builder *b, uint32_t nr)
{
    sb_push(b, (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
             (unsigned)offsetof(struct seccomp_data, nr)));
    sb_push(b, (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, nr, 0, 1));
    sb_push(b, (struct sock_filter)BPF_STMT(BPF_RET | BPF_K,
             SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)));
}
static void add_deny_if_arg_set(struct seccomp_prog_builder *b, uint32_t nr, unsigned arg_index,
                                 uint32_t mask)
{
    unsigned arg_off = (unsigned)offsetof(struct seccomp_data, args[arg_index]);
    sb_push(b, (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
             (unsigned)offsetof(struct seccomp_data, nr)));
    sb_push(b, (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, nr, 0, 4));
    sb_push(b, (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, arg_off));
    sb_push(b, (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, mask, 0, 1));
    sb_push(b, (struct sock_filter)BPF_STMT(BPF_RET | BPF_K,
             SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)));
    sb_push(b, (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
             (unsigned)offsetof(struct seccomp_data, nr))); /* re-arm for the next check */
}

static void add_deny_if_arg_mask_eq(struct seccomp_prog_builder *b, uint32_t nr,
                                    unsigned arg_index, uint32_t mask)
{
    unsigned arg_off = (unsigned)offsetof(struct seccomp_data, args[arg_index]);
    sb_push(b, (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
             (unsigned)offsetof(struct seccomp_data, nr)));
    sb_push(b, (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, nr, 0, 5));
    sb_push(b, (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, arg_off));
    sb_push(b, (struct sock_filter)BPF_STMT(BPF_ALU | BPF_AND | BPF_K, mask));
    sb_push(b, (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, mask, 0, 1));
    sb_push(b, (struct sock_filter)BPF_STMT(BPF_RET | BPF_K,
             SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)));
    sb_push(b, (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
             (unsigned)offsetof(struct seccomp_data, nr)));
}

static void add_deny_if_arg_eq(struct seccomp_prog_builder *b, uint32_t nr, unsigned arg_index,
                               uint32_t value)
{
    unsigned arg_off = (unsigned)offsetof(struct seccomp_data, args[arg_index]);
    sb_push(b, (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
             (unsigned)offsetof(struct seccomp_data, nr)));
    sb_push(b, (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, nr, 0, 4));
    sb_push(b, (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, arg_off));
    sb_push(b, (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, value, 0, 1));
    sb_push(b, (struct sock_filter)BPF_STMT(BPF_RET | BPF_K,
             SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)));
    sb_push(b, (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
             (unsigned)offsetof(struct seccomp_data, nr)));
}
#ifndef O_TMPFILE
#define O_TMPFILE 020200000
#endif
#define YS_CLONE_NEWMASK \
    (CLONE_NEWNS | CLONE_NEWCGROUP | CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWUSER | \
     CLONE_NEWPID | CLONE_NEWNET)
#ifndef MADV_REMOVE
#define MADV_REMOVE 9
#endif

static int build_seccomp_filter(struct seccomp_prog_builder *out)
{
    struct seccomp_prog_builder b;
    b.n = 0;
    b.failed = 0;
    sb_push(&b, (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
             (unsigned)offsetof(struct seccomp_data, arch)));
    sb_push(&b, (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_AARCH64, 1, 0));
    sb_push(&b, (struct sock_filter)BPF_STMT(BPF_RET | BPF_K,
             SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)));
#ifdef __NR_socket
    add_deny(&b, __NR_socket);
#endif
#ifdef __NR_socketpair
    add_deny(&b, __NR_socketpair);
#endif
#ifdef __NR_mknod
    add_deny(&b, __NR_mknod); /* absent on aarch64 (plan.md: filtered only where defined) */
#endif
#ifdef __NR_mknodat
    add_deny(&b, __NR_mknodat);
#endif
#ifdef __NR_fallocate
    add_deny(&b, __NR_fallocate);
#endif
#ifdef __NR_truncate
    add_deny(&b, __NR_truncate);
#endif
#ifdef __NR_ftruncate
    add_deny(&b, __NR_ftruncate);
#endif
#ifdef __NR_lseek
    add_deny(&b, __NR_lseek);
#endif
#ifdef __NR_pwrite64
    add_deny(&b, __NR_pwrite64);
#endif
#ifdef __NR_pwritev
    add_deny(&b, __NR_pwritev);
#endif
#ifdef __NR_pwritev2
    add_deny(&b, __NR_pwritev2);
#endif
#ifdef __NR_openat2
    add_deny(&b, __NR_openat2);
#endif
#ifdef __NR_open_by_handle_at
    add_deny(&b, __NR_open_by_handle_at);
#endif
#ifdef __NR_name_to_handle_at
    add_deny(&b, __NR_name_to_handle_at);
#endif
#ifdef __NR_splice
    add_deny(&b, __NR_splice);
#endif
#ifdef __NR_vmsplice
    add_deny(&b, __NR_vmsplice);
#endif
#ifdef __NR_tee
    add_deny(&b, __NR_tee);
#endif
#ifdef __NR_sendfile
    add_deny(&b, __NR_sendfile);
#endif
#ifdef __NR_copy_file_range
    add_deny(&b, __NR_copy_file_range);
#endif
#ifdef __NR_io_uring_setup
    add_deny(&b, __NR_io_uring_setup);
#endif
#ifdef __NR_io_uring_enter
    add_deny(&b, __NR_io_uring_enter);
#endif
#ifdef __NR_io_uring_register
    add_deny(&b, __NR_io_uring_register);
#endif
#ifdef __NR_io_setup
    add_deny(&b, __NR_io_setup);
#endif
#ifdef __NR_io_submit
    add_deny(&b, __NR_io_submit);
#endif
#ifdef __NR_userfaultfd
    add_deny(&b, __NR_userfaultfd);
#endif
#ifdef __NR_perf_event_open
    add_deny(&b, __NR_perf_event_open);
#endif
#ifdef __NR_bpf
    add_deny(&b, __NR_bpf);
#endif
#ifdef __NR_ptrace
    add_deny(&b, __NR_ptrace);
#endif
#ifdef __NR_process_vm_readv
    add_deny(&b, __NR_process_vm_readv);
#endif
#ifdef __NR_process_vm_writev
    add_deny(&b, __NR_process_vm_writev);
#endif
#ifdef __NR_linkat
    add_deny(&b, __NR_linkat);
#endif
#ifdef __NR_symlinkat
    add_deny(&b, __NR_symlinkat);
#endif
#ifdef __NR_mount
    add_deny(&b, __NR_mount);
#endif
#ifdef __NR_umount2
    add_deny(&b, __NR_umount2);
#endif
#ifdef __NR_pivot_root
    add_deny(&b, __NR_pivot_root);
#endif
#ifdef __NR_move_mount
    add_deny(&b, __NR_move_mount);
#endif
#ifdef __NR_open_tree
    add_deny(&b, __NR_open_tree);
#endif
#ifdef __NR_fsopen
    add_deny(&b, __NR_fsopen);
#endif
#ifdef __NR_fsmount
    add_deny(&b, __NR_fsmount);
#endif
#ifdef __NR_unshare
    add_deny(&b, __NR_unshare);
#endif
#ifdef __NR_setns
    add_deny(&b, __NR_setns);
#endif
#ifdef __NR_clone3
    add_deny(&b, __NR_clone3);
#endif
#ifdef __NR_keyctl
    add_deny(&b, __NR_keyctl);
#endif
#ifdef __NR_add_key
    add_deny(&b, __NR_add_key);
#endif
#ifdef __NR_request_key
    add_deny(&b, __NR_request_key);
#endif
#ifdef __NR_acct
    add_deny(&b, __NR_acct);
#endif
#ifdef __NR_swapon
    add_deny(&b, __NR_swapon);
#endif
#ifdef __NR_openat
    add_deny_if_arg_mask_eq(&b, __NR_openat, 2, O_TMPFILE);
#endif
#ifdef __NR_madvise
    add_deny_if_arg_eq(&b, __NR_madvise, 2, MADV_REMOVE);
#endif
#ifdef __NR_clone
    add_deny_if_arg_set(&b, __NR_clone, 0, YS_CLONE_NEWMASK);
#endif
    sb_push(&b, (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW));
    if (b.failed || b.n > USHRT_MAX) return 0;
    *out = b;
    return 1;
}

static int apply_seccomp(void)
{
    struct seccomp_prog_builder b;
    struct sock_fprog prog;
    if (!build_seccomp_filter(&b)) return 0;
    prog.len = (unsigned short)b.n;
    prog.filter = b.insn;
    return prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog) == 0;
}

/* The child reports every setup refusal through the close-on-exec outcome
 * channel. Successful exec closes that channel before verifier code runs. */
static void child_refuse(int outcome_fd, int error_number)
{
    ys_exec_report_failure(outcome_fd, YS_EXEC_PHASE_CHILD_SETUP, error_number);
    _exit(125);
}

static void child_main(int instruction_fd, int stdout_fd, int stderr_fd, int outcome_fd)
{
    if (chdir(NEWROOT_DIR) != 0) child_refuse(outcome_fd, errno);
    if (syscall(SYS_pivot_root, ".", ".") != 0) child_refuse(outcome_fd, errno);
    if (umount2(".", MNT_DETACH) != 0) child_refuse(outcome_fd, errno);
    if (chdir("/") != 0) child_refuse(outcome_fd, errno);
    if (!run_privilege_sequence(actual_privilege_step, NULL)) child_refuse(outcome_fd, errno);
    {
        struct rlimit core, rt;
        core.rlim_cur = 0; core.rlim_max = 0;
        rt.rlim_cur = 0; rt.rlim_max = 0;
        if (setrlimit(RLIMIT_CORE, &core) != 0) child_refuse(outcome_fd, errno);
        if (setrlimit(RLIMIT_RTPRIO, &rt) != 0) child_refuse(outcome_fd, errno);
    }
    {
        struct sched_param sp;
        memset(&sp, 0, sizeof sp);
        if (sched_setscheduler(0, SCHED_OTHER, &sp) != 0) child_refuse(outcome_fd, errno);
    }
    if (!apply_landlock()) child_refuse(outcome_fd, errno);
    if (!apply_seccomp()) child_refuse(outcome_fd, errno);
    ys_exec(YS_PLAN_ARGV, YS_PLAN_ENVIRONMENT, instruction_fd, stdout_fd, stderr_fd,
            outcome_fd);
    _exit(125); /* unreached: ys_exec never returns */
}

struct exec_channel_state {
    unsigned char bytes[2U * sizeof(struct ys_exec_outcome)];
    size_t length;
    int eof;
    int invalid;
};

static int drain_exec_channel(int fd, struct exec_channel_state *state)
{
    for (;;) {
        ssize_t n;
        if (state->length == sizeof state->bytes) { state->invalid = 1; return 0; }
        n = read(fd, state->bytes + state->length, sizeof state->bytes - state->length);
        if (n > 0) { state->length += (size_t)n; continue; }
        if (n == 0) { state->eof = 1; return 1; }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 1;
        state->invalid = 1;
        return 0;
    }
}

static int exec_channel_confirms_execution(const struct exec_channel_state *state,
                                           int child_status)
{
    struct ys_exec_outcome first;
    if (state->invalid || !state->eof || state->length != sizeof first ||
        !WIFEXITED(child_status))
        return 0;
    memcpy(&first, state->bytes, sizeof first);
    return first.kind == YS_EXEC_READY && first.phase == YS_EXEC_PHASE_EXECVE &&
           first.reserved == 0 && first.error_number == 0;
}

static int execution_was_verified(const struct exec_channel_state *state, int child_status,
                                  int child_reaped, int tree_terminated,
                                  int tree_deadline_fired, int containment_failure)
{
    return child_reaped && tree_terminated && !tree_deadline_fired &&
           !containment_failure && exec_channel_confirms_execution(state, child_status);
}

/* --- report.json (R8.2) ---------------------------------------------------
 * Keys sorted exactly as host-supervisor.py's own validate_export checks
 * them (its set comparison is order-blind, but this matches the repo's
 * canonical-JSON convention throughout). Bounded, hand-built: no general
 * string escaping is needed anywhere in this document (every string field
 * is hex). */
struct guest_row { uint64_t observed; const char *observation, *enforcement; int reached;
                    uint64_t resolution; };
struct report_state {
    int verifier_started, tree_deadline_fired, tree_terminated;
    int exit_signaled; int exit_code;
    uint64_t stdout_bytes, stderr_bytes;
    struct guest_row cpu, memory, output, tasks, scratch;
    char **evidence_names; size_t evidence_count;
};

struct json_writer { char *buf; size_t len, cap; };

#ifdef YSTACK_SUPERVISOR_TEST
static size_t ys_test_report_cap_limit;
static int ys_test_report_sizes;
static int ys_test_format_failure;
#endif

static int evidence_file_size(const char *path, off_t *size_out)
{
#ifdef YSTACK_SUPERVISOR_TEST
    if (ys_test_report_sizes) { *size_out = (off_t)strlen(path); return 1; }
#endif
    {
        struct stat st;
        if (stat(path, &st) != 0 || st.st_size < 0) return 0;
        *size_out = st.st_size;
        return 1;
    }
}

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
static char *build_report_json(const char plan_sha256_hex[65],
                                const struct report_state *s, size_t *len_out)
{
    struct json_writer w = { NULL, 0U, 0U };
    size_t i;
    if (s->evidence_count > 10000U) goto fail;
    if (!json_appendf(&w, "{\"body\":{\"evidence_files\":[")) goto fail;
    for (i = 0; i < s->evidence_count; i++) {
        char hex[513];
        size_t namelen = strlen(s->evidence_names[i]);
        off_t file_size;
        char path[300];
        int path_len;
        if (namelen > 255U) goto fail;
        ys_hex_encode((const unsigned char *)s->evidence_names[i], namelen, hex);
        hex[namelen * 2U] = '\0';
        path_len = snprintf(path, sizeof path, "%s/%s", EVIDENCE_SUBDIR, s->evidence_names[i]);
        if (path_len < 0 || (size_t)path_len >= sizeof path) goto fail;
        if (!evidence_file_size(path, &file_size)) goto fail;
        if (!json_appendf(&w, "%s{\"index\":%zu,\"name_hex\":\"%s\",\"size_bytes\":%lld}",
                          (i == 0U) ? "" : ",", i, hex, (long long)file_size))
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

/* --- fanotify first-open rule (R7.1's output_bytes row, R8.1) -------------
 * One FAN_OPEN_PERM mark on the output tmpfs's superblock (FAN_MARK_
 * FILESYSTEM, not FAN_MARK_MOUNT: a filesystem mark is keyed to the
 * superblock, so it still applies after clone3(CLONE_NEWNS) hands the
 * child a private copy of the mount table -- a mount-keyed mark is not
 * guaranteed to follow a namespace copy the same way). stdout and stderr
 * are opened once, by this process, before the mark is even added, so
 * only the verifier's own opens under /sandbox/evidence are ever
 * evaluated. Tracks already-opened inodes in a fixed-size table sized to
 * the plan's own output_inodes bound. */
struct seen_inode { dev_t dev; ino_t ino; };
struct fanotify_state {
    int fd;
    struct seen_inode seen[256];
    size_t seen_count;
};

static void fanotify_state_init(struct fanotify_state *fs)
{
    memset(fs, 0, sizeof *fs);
    fs->fd = -1;
}

static int fanotify_open_mark(struct fanotify_state *fs)
{
#if defined(SYS_fanotify_init) && defined(SYS_fanotify_mark)
    fanotify_state_init(fs);
    fs->fd = (int)syscall(SYS_fanotify_init, FAN_CLASS_CONTENT | FAN_CLOEXEC, O_RDONLY);
    if (fs->fd < 0) return 0;
    if (syscall(SYS_fanotify_mark, fs->fd, FAN_MARK_ADD | FAN_MARK_FILESYSTEM, (uint64_t)FAN_OPEN_PERM,
                AT_FDCWD, OUTPUT_DIR) != 0) {
        (void)close(fs->fd);
        fs->fd = -1;
        return 0;
    }
    return 1;
#else
    (void)fs;
    return 0;
#endif
}

static int inode_history_record(struct fanotify_state *fs, dev_t dev, ino_t ino)
{
    size_t i;
    for (i = 0; i < fs->seen_count; i++)
        if (fs->seen[i].dev == dev && fs->seen[i].ino == ino) return 0;
    if (fs->seen_count >= sizeof fs->seen / sizeof fs->seen[0]) return 0;
    fs->seen[fs->seen_count++] = (struct seen_inode){ dev, ino };
    return 1;
}

/* Reads and answers every pending permission event; called whenever
 * poll() reports the fanotify fd readable. Approves the first open of an
 * empty (size 0) regular file's inode, denies every other open --
 * including a second open of a file this same rule already approved once
 * (R7.1: "allows only the first open of an empty inode"). */
static int fanotify_service(struct fanotify_state *fs)
{
    char buf[4096];
    ssize_t len;
    struct fanotify_event_metadata *m;
    do { len = read(fs->fd, buf, sizeof buf); } while (len < 0 && errno == EINTR);
    if (len <= 0) return 0;
    for (m = (struct fanotify_event_metadata *)buf; FAN_EVENT_OK(m, len); m = FAN_EVENT_NEXT(m, len)) {
        struct fanotify_response resp;
        struct stat st;
        int allow = 0;
        if (m->fd >= 0) {
            if (fstat(m->fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size == 0 &&
                inode_history_record(fs, st.st_dev, st.st_ino))
                allow = 1;
            resp.fd = m->fd;
            resp.response = allow ? FAN_ALLOW : FAN_DENY;
            {
                const unsigned char *bytes = (const unsigned char *)&resp;
                size_t written = 0;
                while (written < sizeof resp) {
                    ssize_t n = write(fs->fd, bytes + written, sizeof resp - written);
                    if (n < 0 && errno == EINTR) continue;
                    if (n <= 0) { (void)close(m->fd); return 0; }
                    written += (size_t)n;
                }
            }
            (void)close(m->fd);
        } else return 0;
    }
    return 1;
}

/* Writes the instruction in the supervisor-only /ys tmpfs, closes that
 * writable description, reopens it read-only, and unlinks the name. */
static int readonly_instruction_at(int dirfd, const unsigned char *data, size_t len)
{
    static const char name[] = ".instruction";
    int write_fd = openat(dirfd, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    int read_fd = -1;
    if (write_fd < 0) return -1;
    {
        size_t written = 0;
        while (written < len) {
            ssize_t n = write(write_fd, data + written, len - written);
            if (n < 0) { if (errno == EINTR) continue; goto fail; }
            if (n == 0) goto fail;
            written += (size_t)n;
        }
    }
    if (fsync(write_fd) != 0 || close(write_fd) != 0) { write_fd = -1; goto fail; }
    write_fd = -1;
    read_fd = openat(dirfd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (read_fd < 0 || unlinkat(dirfd, name, 0) != 0) goto fail;
    return read_fd;
fail:
    if (write_fd >= 0) (void)close(write_fd);
    if (read_fd >= 0) (void)close(read_fd);
    (void)unlinkat(dirfd, name, 0);
    return -1;
}

/* --- main ------------------------------------------------------------------ */
#ifndef YSTACK_SUPERVISOR_TEST
int main(void)
{
    int input_fd, export_fd, instr_priv_fd, cand_fd, tools_fd;
    struct loaded_input in;
    struct ys_guest_plan plan;
    unsigned char digest[32];
    char hex[65];
    struct cgroup_setup cg;
    struct fanotify_state fan;
    struct report_state rs;
    size_t i;
    int outcome_pipe[2] = { -1, -1 };
    struct exec_channel_state outcome;
    int child_status = 0;
    int child_reaped = 0;
    int containment_failure = 0;
    pid_t child_pid = -1;
    struct timespec t0, tnow;
    uint64_t deadline_ms, page_size;
    long measured_page_size;

    memset(&rs, 0, sizeof rs);
    memset(&outcome, 0, sizeof outcome);
    fanotify_state_init(&fan);

    if (getpid() != 1) die("not running as pid 1 (init should have exec'd us directly)");
    input_fd = open(INPUT_DEVICE, O_RDONLY | O_CLOEXEC);
    if (input_fd < 0 || !load_input(input_fd, &in)) goto poweroff; /* no valid report to write */
    if (ys_plan_parse(in.plan_bytes, in.plan_len, &plan) != YS_PLAN_OK) goto poweroff;
    ys_sha256_bytes(in.instruction, in.instruction_len, digest);
    ys_hex_encode(digest, sizeof digest, hex);
    if (memcmp(hex, plan.instruction_sha256_hex, 64U) != 0) goto poweroff;
    ys_sha256_bytes(in.verifier, in.verifier_len, digest);
    ys_hex_encode(digest, sizeof digest, hex);
    if (memcmp(hex, plan.verifier_sha256_hex, 64U) != 0) goto poweroff;
    ys_sha256_bytes(in.plan_bytes, in.plan_len, digest);
    ys_hex_encode(digest, sizeof digest, hex);
    hex[64] = '\0';

    if (!mkdir_p("/ys", 0700)) goto export_partial;
    deadline_ms = plan.limits.tree_deadline_ms;
    measured_page_size = sysconf(_SC_PAGESIZE);
    if (measured_page_size <= 0) goto export_partial;
    page_size = (uint64_t)measured_page_size;

    /* candidate tmpfs: materialized, then finalized read-only (R5.5). */
    {
        uint64_t total, inodes;
        if (!candidate_count_matches(&plan, in.candidate_count) ||
            !candidate_geometry(&plan, page_size, &total, &inodes)) goto export_partial;
        if (!mkdir_p(CANDIDATE_DIR, 0700) ||
            !mount_tmpfs(CANDIDATE_DIR, total, inodes))
            goto export_partial;
        cand_fd = open(CANDIDATE_DIR, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (cand_fd < 0 ||
            ys_plan_materialize(cand_fd, GUEST_UID, GUEST_GID, &plan,
                                 (const unsigned char *const *)in.candidates, in.candidate_lens) !=
                YS_PLAN_OK)
            goto export_partial;
        (void)close(cand_fd);
        if (!make_searchable_read_only(CANDIDATE_DIR)) goto export_partial;
        if (!remount_ro(CANDIDATE_DIR, MS_NOEXEC)) goto export_partial;
    }
    /* tools tmpfs: the verifier only, root-owned, read-only+executable. */
    {
        uint64_t verifier_allocation, tools_size;
        if (!rounded_allocation((uint64_t)in.verifier_len, page_size, &verifier_allocation) ||
            !checked_add_u64(verifier_allocation, page_size, &tools_size) ||
            !mkdir_p(TOOLS_DIR, 0700) || !mount_tmpfs(TOOLS_DIR, tools_size, 2U))
            goto export_partial;
    }
    tools_fd = open(TOOLS_DIR, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (tools_fd < 0) goto export_partial;
    {
        int vfd = openat(tools_fd, "verifier", O_WRONLY | O_CREAT | O_EXCL, 0500);
        size_t written = 0;
        if (vfd < 0) goto export_partial;
        while (written < in.verifier_len) {
            ssize_t n = write(vfd, in.verifier + written, in.verifier_len - written);
            if (n < 0) { (void)close(vfd); goto export_partial; }
            written += (size_t)n;
        }
        if (fchown(vfd, 0, 0) != 0 || fchmod(vfd, 0555) != 0 || close(vfd) != 0)
            goto export_partial;
    }
    (void)close(tools_fd);
    if (!make_searchable_read_only(TOOLS_DIR)) goto export_partial;
    if (!remount_ro(TOOLS_DIR, 0)) goto export_partial;

    /* output tmpfs (stdout, stderr, evidence/) and scratch tmpfs. */
    if (!mkdir_p(OUTPUT_DIR, 0700) ||
        !mount_tmpfs(OUTPUT_DIR, plan.limits.output_tmpfs_bytes, plan.limits.output_inodes) ||
        !mkdir_p(EVIDENCE_SUBDIR, 0700) || chown(EVIDENCE_SUBDIR, GUEST_UID, GUEST_GID) != 0)
        goto export_partial;
    if (!mkdir_p(SCRATCH_DIR, 0700) ||
        !mount_tmpfs(SCRATCH_DIR, plan.limits.scratch_bytes, plan.limits.scratch_inodes) ||
        chown(SCRATCH_DIR, GUEST_UID, GUEST_GID) != 0)
        goto export_partial;

    if (!setup_cgroup(&plan.limits, &cg)) goto export_partial;
    rs.cpu.enforcement = "none"; /* R7.2: always, unconditionally */
    rs.cpu.resolution = 1; /* cpu.stat usage_usec rounded up to ms */
    rs.memory.enforcement = cg.memory_hard ? "hard" : "unknown";
    rs.memory.resolution = (uint64_t)sysconf(_SC_PAGESIZE);
    rs.output.enforcement = cg.output_hard ? "hard" : "unknown";
    rs.output.resolution = 1; /* summed stream/evidence file sizes, byte-exact */
    rs.tasks.enforcement = cg.pids_hard ? "hard" : "unknown";
    rs.tasks.resolution = 1; /* pids.peak */
    rs.scratch.enforcement = cg.scratch_hard ? "hard" : "unknown";
    rs.scratch.resolution = 4096; /* statvfs f_frsize is confirmed below; a safe default */

    /* R6.1's tmpfs root, prepared entirely before clone3 so the child does
     * nothing but pivot into it. Everything lives under /sandbox (R6.1,
     * R6.4's fixed argv/PATH/TMPDIR), so the new root itself holds nothing
     * but that one directory. */
    if (!mkdir_p(NEWROOT_DIR, 0700) || !mount_tmpfs(NEWROOT_DIR, 5U * page_size, 10U) ||
        !make_searchable_read_only(NEWROOT_DIR) || !mkdir_p(NEWROOT_DIR "/sandbox", 0555) ||
        !make_searchable_read_only(NEWROOT_DIR "/sandbox"))
        goto export_partial;
    if (!bind_into_newroot(CANDIDATE_DIR, "candidate", 1, 1) ||
        !bind_into_newroot(TOOLS_DIR, "tools", 1, 0) ||
        !bind_into_newroot(SCRATCH_DIR, "scratch", 0, 1) ||
        !bind_into_newroot(EVIDENCE_SUBDIR, "evidence", 0, 1))
        goto export_partial;

    {
        int outfd = openat(AT_FDCWD, OUTPUT_DIR "/stdout", O_WRONLY | O_CREAT | O_EXCL | O_APPEND, 0600);
        int errfd = openat(AT_FDCWD, OUTPUT_DIR "/stderr", O_WRONLY | O_CREAT | O_EXCL | O_APPEND, 0600);
        int ysfd = open("/ys", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        int instr_fd = ysfd < 0 ? -1 : readonly_instruction_at(ysfd, in.instruction, in.instruction_len);
        if (ysfd >= 0) (void)close(ysfd);
        if (outfd < 0 || errfd < 0 || instr_fd < 0) goto export_partial;
        instr_priv_fd = instr_fd;
        if (!fanotify_open_mark(&fan)) goto export_partial;
        if (pipe2(outcome_pipe, O_CLOEXEC) != 0) goto export_partial;
        if (fcntl(outcome_pipe[0], F_SETFL, O_NONBLOCK) != 0) goto export_partial;
        child_pid = ys_clone3_into_cgroup(cg.cgroup_fd);
        if (child_pid == 0) {
            (void)close(outcome_pipe[0]);
            child_main(instr_priv_fd, outfd, errfd, outcome_pipe[1]);
            _exit(125);
        }
        (void)close(outfd); (void)close(errfd); (void)close(instr_priv_fd);
        (void)close(outcome_pipe[1]);
        outcome_pipe[1] = -1;
        if (child_pid < 0) goto export_partial;
    }

    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        int status;
        pid_t r;
        long remaining_ms;
        clock_gettime(CLOCK_MONOTONIC, &tnow);
        remaining_ms = (long)deadline_ms -
                       (long)((tnow.tv_sec - t0.tv_sec) * 1000 + (tnow.tv_nsec - t0.tv_nsec) / 1000000);
        if (remaining_ms <= 0) {
            rs.tree_deadline_fired = 1;
            (void)write_str(TREE_CGROUP "/cgroup.kill", "1");
            break;
        }
        {
            struct pollfd pfds[2];
            nfds_t count = 0;
            if (fan.fd >= 0) pfds[count++] = (struct pollfd){ fan.fd, POLLIN, 0 };
            if (outcome_pipe[0] >= 0 && !outcome.eof)
                pfds[count++] = (struct pollfd){ outcome_pipe[0], POLLIN | POLLHUP, 0 };
            if (poll(pfds, count, (int)(remaining_ms > 200 ? 200 : remaining_ms)) > 0) {
                nfds_t p;
                for (p = 0; p < count; p++) {
                    if (pfds[p].fd == fan.fd && (pfds[p].revents & POLLIN) &&
                        !fanotify_service(&fan)) {
                        containment_failure = 1;
                        (void)write_str(TREE_CGROUP "/cgroup.kill", "1");
                    }
                    if (pfds[p].fd == outcome_pipe[0] &&
                        (pfds[p].revents & (POLLIN | POLLHUP)))
                        (void)drain_exec_channel(outcome_pipe[0], &outcome);
                }
            }
            if (containment_failure) break;
        }
        r = waitpid(child_pid, &status, WNOHANG);
        if (r == child_pid) {
            rs.tree_terminated = confirm_tree_terminated(51U);
            child_status = status;
            child_reaped = 1;
            if (WIFEXITED(status)) { rs.exit_signaled = 0; rs.exit_code = WEXITSTATUS(status); }
            else { rs.exit_signaled = 1; }
            goto reaped;
        }
    }
    /* Deadline path: wait for cgroup.events populated 0, then reap. */
    {
        int status;
        rs.tree_terminated = confirm_tree_terminated(401U);
        if (waitpid(child_pid, &status, 0) == child_pid) {
            child_status = status;
            child_reaped = 1;
            if (WIFEXITED(status)) { rs.exit_signaled = 0; rs.exit_code = WEXITSTATUS(status); }
            else { rs.exit_signaled = 1; }
        }
    }
reaped:
    if (outcome_pipe[0] >= 0) {
        (void)drain_exec_channel(outcome_pipe[0], &outcome);
        (void)close(outcome_pipe[0]);
        outcome_pipe[0] = -1;
    }
    rs.verifier_started = execution_was_verified(&outcome, child_status, child_reaped,
                                                  rs.tree_terminated,
                                                  rs.tree_deadline_fired,
                                                  containment_failure);
    if (!rs.tree_terminated || containment_failure) goto poweroff;
    if (fan.fd >= 0) { (void)close(fan.fd); fan.fd = -1; }

    /* Counters, collected only after confirmed termination (R7.3
     * "complete" requires it); otherwise every row this loop has not
     * already marked "none" stays "unavailable". */
    {
        const char *obs = rs.tree_terminated ? "complete" : "unavailable";
        uint64_t v;
        rs.cpu.observation = obs;
        if (rs.tree_terminated) {
            char buf[256];
            char *p = (read_file(TREE_CGROUP "/cpu.stat", buf, sizeof buf) >= 0)
                          ? strstr(buf, "usage_usec ")
                          : NULL;
            if (p != NULL) {
                uint64_t usec = strtoull(p + 11, NULL, 10);
                rs.cpu.observed = (usec + 999ULL) / 1000ULL; /* rounded up to ms */
                rs.cpu.reached = rs.cpu.observed >= CPU_TIME_BOUND_MS;
            } else {
                rs.cpu.observation = "unavailable";
            }
        } else {
            rs.cpu.observation = "unavailable";
        }

        rs.memory.observation = obs;
        if (rs.tree_terminated && read_u64(TREE_CGROUP "/memory.peak", &v)) {
            char events[256];
            rs.memory.observed = v;
            rs.memory.reached = v >= GUEST_MEMORY_BYTES;
            if (read_file(TREE_CGROUP "/memory.events", events, sizeof events) >= 0) {
                char *p = strstr(events, "oom_kill ");
                if (p != NULL && strtoull(p + 9, NULL, 10) > 0) rs.memory.reached = 1;
            }
        } else {
            rs.memory.observation = "unavailable";
        }

        rs.tasks.observation = obs;
        if (rs.tree_terminated && read_u64(TREE_CGROUP "/pids.peak", &v)) {
            char events[256];
            rs.tasks.observed = v;
            rs.tasks.reached = v >= plan.limits.pids_max;
            if (read_file(TREE_CGROUP "/pids.events", events, sizeof events) >= 0) {
                char *p = strstr(events, "max ");
                if (p != NULL && strtoull(p + 4, NULL, 10) > 0) rs.tasks.reached = 1;
            }
        } else {
            rs.tasks.observation = "unavailable";
        }

        if (rs.tree_terminated) {
            struct stat st;
            struct statvfs sv;
            uint64_t total_bytes = 0;
            if (stat(OUTPUT_DIR "/stdout", &st) == 0) rs.stdout_bytes = (uint64_t)st.st_size;
            if (stat(OUTPUT_DIR "/stderr", &st) == 0) rs.stderr_bytes = (uint64_t)st.st_size;
            total_bytes = rs.stdout_bytes + rs.stderr_bytes;
            if (ys_evidence_inventory(open(EVIDENCE_SUBDIR, O_RDONLY | O_DIRECTORY | O_CLOEXEC),
                                       &rs.evidence_names, &rs.evidence_count) == YS_PLAN_OK) {
                for (i = 0; i < rs.evidence_count; i++) {
                    char p[300];
                    snprintf(p, sizeof p, "%s/%s", EVIDENCE_SUBDIR, rs.evidence_names[i]);
                    if (stat(p, &st) == 0) total_bytes += (uint64_t)st.st_size;
                }
                rs.output.observation = "complete";
            } else {
                rs.output.observation = "partial"; /* a hard-link alias or read failure */
            }
            rs.output.observed = total_bytes;
            if (statvfs(OUTPUT_DIR, &sv) == 0)
                rs.output.reached = (sv.f_bfree == 0) || total_bytes >= plan.limits.output_tmpfs_bytes;
            if (statvfs(SCRATCH_DIR, &sv) == 0) {
                rs.scratch.observed = ((uint64_t)sv.f_blocks - sv.f_bfree) * sv.f_frsize;
                rs.scratch.resolution = (uint64_t)sv.f_frsize;
                rs.scratch.observation = "complete";
                rs.scratch.reached = (sv.f_bfree == 0) || rs.scratch.observed >= plan.limits.scratch_bytes;
            } else {
                rs.scratch.observation = "unavailable";
            }
        } else {
            rs.output.observation = "unavailable";
            rs.scratch.observation = "unavailable";
        }
    }

export_partial:
    /* Only a verifier that actually started produces a legal report.json
     * (R8.2's exit_state has no "not started" value); otherwise nothing is
     * exported and the host reads a damaged/absent frame (R8.2, R9.5). */
    if (rs.verifier_started) {
        export_fd = open(EXPORT_DEVICE, O_RDWR | O_CLOEXEC);
        if (export_fd >= 0) {
            size_t report_len;
            char *report = build_report_json(hex, &rs, &report_len);
            if (report != NULL) {
                struct ys_frame_writer w;
                if (ys_frame_writer_open(&w, export_fd) != 0) {
                    unsigned char *stdout_buf, *stderr_buf;
                    int frame_ok = 0;
                    int sfd = open(OUTPUT_DIR "/stdout", O_RDONLY | O_CLOEXEC);
                    int efd = open(OUTPUT_DIR "/stderr", O_RDONLY | O_CLOEXEC);
                    stdout_buf = malloc(rs.stdout_bytes ? rs.stdout_bytes : 1U);
                    stderr_buf = malloc(rs.stderr_bytes ? rs.stderr_bytes : 1U);
                    if (sfd >= 0 && efd >= 0 && stdout_buf != NULL && stderr_buf != NULL) {
                        size_t got1 = 0, got2 = 0;
                        while (got1 < rs.stdout_bytes) {
                            ssize_t n = read(sfd, stdout_buf + got1, rs.stdout_bytes - got1);
                            if (n <= 0) break;
                            got1 += (size_t)n;
                        }
                        while (got2 < rs.stderr_bytes) {
                            ssize_t n = read(efd, stderr_buf + got2, rs.stderr_bytes - got2);
                            if (n <= 0) break;
                            got2 += (size_t)n;
                        }
                        frame_ok = got1 == rs.stdout_bytes && got2 == rs.stderr_bytes &&
                            ys_frame_writer_put(&w, "report.json", 11U, report, report_len) ==
                                YS_FRAME_OK &&
                            ys_frame_writer_put(&w, "stdout", 6U, stdout_buf, got1) == YS_FRAME_OK &&
                            ys_frame_writer_put(&w, "stderr", 6U, stderr_buf, got2) == YS_FRAME_OK;
                        for (i = 0; frame_ok && i < rs.evidence_count; i++) {
                            char name[32];
                            char path[300];
                            struct stat st;
                            unsigned char *buf;
                            int fd;
                            int name_len = snprintf(name, sizeof name, "evidence/%04zu", i);
                            int path_len;
                            if (i > 9999U || name_len < 0 || (size_t)name_len >= sizeof name) {
                                frame_ok = 0; break;
                            }
                            path_len = snprintf(path, sizeof path, "%s/%s", EVIDENCE_SUBDIR,
                                                rs.evidence_names[i]);
                            if (path_len < 0 || (size_t)path_len >= sizeof path) {
                                frame_ok = 0; break;
                            }
                            fd = open(path, O_RDONLY | O_CLOEXEC);
                            if (fd >= 0 && fstat(fd, &st) == 0) {
                                buf = malloc(st.st_size ? (size_t)st.st_size : 1U);
                                if (buf != NULL) {
                                    size_t got = 0;
                                    while ((off_t)got < st.st_size) {
                                        ssize_t n = read(fd, buf + got, (size_t)st.st_size - got);
                                        if (n <= 0) break;
                                        got += (size_t)n;
                                    }
                                    if ((off_t)got != st.st_size ||
                                        ys_frame_writer_put(&w, name, (size_t)name_len, buf, got) !=
                                            YS_FRAME_OK)
                                        frame_ok = 0;
                                    free(buf);
                                } else frame_ok = 0;
                            } else frame_ok = 0;
                            if (fd >= 0) (void)close(fd);
                        }
                    }
                    if (sfd >= 0) (void)close(sfd);
                    if (efd >= 0) (void)close(efd);
                    free(stdout_buf); free(stderr_buf);
                    if (frame_ok && ys_frame_writer_close(&w) != YS_FRAME_OK) frame_ok = 0;
                }
                free(report);
            }
            (void)fsync(export_fd);
            (void)close(export_fd);
        }
    }

poweroff:
    sync();
    (void)reboot(RB_POWER_OFF);
    return 0;
}
#else
struct privilege_test_state { enum privilege_step seen[8]; size_t count; int fail_at; };

static int record_privilege_step(enum privilege_step step, void *opaque)
{
    struct privilege_test_state *state = opaque;
    state->seen[state->count++] = step;
    return (int)step != state->fail_at;
}

static uint32_t evaluate_filter(const struct seccomp_prog_builder *b,
                                const struct seccomp_data *data)
{
    uint32_t accumulator = 0U;
    size_t pc = 0U;
    while (pc < b->n) {
        const struct sock_filter *instruction = &b->insn[pc];
        switch (BPF_CLASS(instruction->code)) {
        case BPF_LD:
            if (instruction->k > sizeof *data - sizeof accumulator) return 0U;
            memcpy(&accumulator, (const unsigned char *)data + instruction->k,
                   sizeof accumulator);
            pc++;
            break;
        case BPF_ALU:
            if (BPF_OP(instruction->code) != BPF_AND) return 0U;
            accumulator &= instruction->k;
            pc++;
            break;
        case BPF_JMP: {
            int condition;
            if (BPF_OP(instruction->code) == BPF_JEQ) condition = accumulator == instruction->k;
            else if (BPF_OP(instruction->code) == BPF_JSET)
                condition = (accumulator & instruction->k) != 0U;
            else return 0U;
            pc += 1U + (condition ? instruction->jt : instruction->jf);
            break;
        }
        case BPF_RET:
            return instruction->k;
        default:
            return 0U;
        }
    }
    return 0U;
}

static uint32_t filter_result(const struct seccomp_prog_builder *b, uint32_t arch, int nr,
                              unsigned arg_index, uint64_t arg)
{
    struct seccomp_data data;
    memset(&data, 0, sizeof data);
    data.arch = arch;
    data.nr = nr;
    data.args[arg_index] = arg;
    return evaluate_filter(b, &data);
}

static int filter_denies(const struct seccomp_prog_builder *b, int nr, unsigned arg_index,
                         uint64_t arg)
{
    uint32_t result = filter_result(b, AUDIT_ARCH_AARCH64, nr, arg_index, arg);
    return (result & SECCOMP_RET_ACTION_FULL) == SECCOMP_RET_ERRNO;
}

static int test_report_writer(void)
{
    struct report_state state;
    char *names[61];
    char plan_digest[65];
    char *report;
    size_t length, i;
    memset(&state, 0, sizeof state);
    memset(plan_digest, 'a', 64U);
    plan_digest[64] = '\0';
    state.verifier_started = 1;
    state.tree_terminated = 1;
    state.cpu = (struct guest_row){ 1U, "complete", "none", 0, 1U };
    state.memory = (struct guest_row){ 2U, "complete", "hard", 0, 4096U };
    state.output = (struct guest_row){ 3U, "complete", "hard", 0, 1U };
    state.tasks = (struct guest_row){ 4U, "complete", "hard", 0, 1U };
    state.scratch = (struct guest_row){ 5U, "complete", "hard", 0, 4096U };
    state.evidence_names = names;
    state.evidence_count = sizeof names / sizeof names[0];
    for (i = 0; i < state.evidence_count; i++) {
        names[i] = malloc(256U);
        if (names[i] == NULL) return 0;
        memset(names[i], 'a' + (int)(i % 26U), 255U);
        names[i][252] = (char)('0' + (i / 10U));
        names[i][253] = (char)('0' + (i % 10U));
        names[i][254] = 'z';
        names[i][255] = '\0';
    }
    ys_test_report_sizes = 1;
    report = build_report_json(plan_digest, &state, &length);
    if (report == NULL || length <= 8192U || report[length] != '\0' || report[length - 1U] != '\n' ||
        strstr(report, "\"index\":31") == NULL ||
        strstr(report, "\"id\":\"sandbox.guest-report.v1\"") == NULL) {
        free(report);
        return 0;
    }
    free(report);
    ys_test_format_failure = 1;
    report = build_report_json(plan_digest, &state, &length);
    ys_test_format_failure = 0;
    if (report != NULL) { free(report); return 0; }
    ys_test_report_cap_limit = 1024U;
    report = build_report_json(plan_digest, &state, &length);
    ys_test_report_cap_limit = 0U;
    for (i = 0; i < state.evidence_count; i++) free(names[i]);
    if (report != NULL) { free(report); return 0; }
    memset(&state, 0, sizeof state);
    state.verifier_started = 1;
    state.exit_signaled = 1;
    state.cpu = (struct guest_row){ 0U, "unavailable", "none", 0, 1U };
    state.memory = (struct guest_row){ 0U, "unavailable", "hard", 0, 4096U };
    state.output = (struct guest_row){ 0U, "unavailable", "hard", 0, 1U };
    state.tasks = (struct guest_row){ 0U, "unavailable", "hard", 0, 1U };
    state.scratch = (struct guest_row){ 0U, "unavailable", "hard", 0, 4096U };
    report = build_report_json(plan_digest, &state, &length);
    if (report == NULL || strstr(report, "\"exit_code\":null") == NULL ||
        strstr(report, "\"observed\":null") == NULL) {
        free(report);
        return 0;
    }
    free(report);
    state.evidence_names = names;
    state.evidence_count = 1U;
    names[0] = malloc(257U);
    if (names[0] == NULL) return 0;
    memset(names[0], 'x', 256U);
    names[0][256] = '\0';
    report = build_report_json(plan_digest, &state, &length);
    free(names[0]);
    if (report != NULL) { free(report); return 0; }
    names[0] = (char *)"missing-evidence";
    ys_test_report_sizes = 0;
    report = build_report_json(plan_digest, &state, &length);
    if (report != NULL) { free(report); return 0; }
    return 1;
}

static int test_fanotify_history(void)
{
    struct fanotify_state state;
    size_t i;
    memset(&state, 0xa5, sizeof state);
    fanotify_state_init(&state);
    if (state.fd != -1 || state.seen_count != 0U) return 0;
    if (!inode_history_record(&state, 1, 1) || inode_history_record(&state, 1, 1)) return 0;
    for (i = 1; i < sizeof state.seen / sizeof state.seen[0]; i++)
        if (!inode_history_record(&state, 1, (ino_t)(i + 1U))) return 0;
    return state.seen_count == 256U && !inode_history_record(&state, 1, 9999);
}

static int join_path(char *out, size_t cap, const char *parent, const char *leaf);

static int fanotify_decision(struct fanotify_state *state, int peer, int event_fd,
                             uint32_t expected)
{
    struct fanotify_event_metadata event;
    struct fanotify_response response;
    if (event_fd < 0) return 0;
    memset(&event, 0, sizeof event);
    event.event_len = FAN_EVENT_METADATA_LEN;
    event.vers = FANOTIFY_METADATA_VERSION;
    event.metadata_len = FAN_EVENT_METADATA_LEN;
    event.mask = FAN_OPEN_PERM;
    event.fd = event_fd;
    if (write(peer, &event, sizeof event) != (ssize_t)sizeof event ||
        !fanotify_service(state) ||
        read(peer, &response, sizeof response) != (ssize_t)sizeof response)
        return 0;
    return response.fd == event_fd && response.response == expected;
}

static int test_fanotify_service(const char *directory)
{
    char empty_path[512], full_path[512];
    struct fanotify_state state;
    int sockets[2], empty_fd, full_fd;
    if (!join_path(empty_path, sizeof empty_path, directory, "fan-empty") ||
        !join_path(full_path, sizeof full_path, directory, "fan-full") ||
        socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0)
        return 0;
    empty_fd = open(empty_path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    full_fd = open(full_path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (empty_fd < 0 || full_fd < 0 || write(full_fd, "x", 1) != 1) return 0;
    fanotify_state_init(&state);
    state.fd = sockets[0];
    if (!fanotify_decision(&state, sockets[1], dup(empty_fd), FAN_ALLOW) ||
        !fanotify_decision(&state, sockets[1], dup(empty_fd), FAN_DENY) ||
        !fanotify_decision(&state, sockets[1], dup(full_fd), FAN_DENY))
        return 0;
    (void)close(empty_fd); (void)close(full_fd);
    (void)close(sockets[0]); (void)close(sockets[1]);
    return 1;
}

static int test_checked_arithmetic(void)
{
    uint64_t result;
    if (!checked_add_u64(0U, 0U, &result) || result != 0U ||
        !checked_add_u64(UINT64_MAX - 1U, 1U, &result) || result != UINT64_MAX ||
        checked_add_u64(UINT64_MAX, 1U, &result))
        return 0;
    if (!checked_mul_u64(0U, UINT64_MAX, &result) || result != 0U ||
        !checked_mul_u64(UINT64_MAX, 1U, &result) || result != UINT64_MAX ||
        checked_mul_u64(UINT64_MAX, 2U, &result))
        return 0;
    if (!rounded_allocation(1U, 65536U, &result) || result != 65536U ||
        !rounded_allocation(65536U, 65536U, &result) || result != 65536U ||
        !rounded_allocation(65537U, 65536U, &result) || result != 131072U ||
        rounded_allocation(UINT64_MAX, 65536U, &result))
        return 0;
    return 1;
}

static int test_geometry(void)
{
    struct ys_plan_entry entries[10];
    struct ys_guest_plan plan;
    uint64_t size, inodes;
    size_t i;
    memset(entries, 0, sizeof entries);
    memset(&plan, 0, sizeof plan);
    plan.entries = entries;
    plan.entry_count = 10U;
    for (i = 0; i < 10U; i++) { entries[i].is_file = 1; entries[i].size_bytes = 1U; }
    if (!candidate_geometry(&plan, 16384U, &size, &inodes) ||
        size != 11U * 16384U || inodes != 11U)
        return 0;
    plan.entry_count = 0U;
    if (!candidate_geometry(&plan, 8192U, &size, &inodes) || size != 8192U || inodes != 1U)
        return 0;
    plan.entry_count = 1U;
    entries[0].size_bytes = 8192U;
    if (!candidate_geometry(&plan, 8192U, &size, &inodes) || size != 16384U || inodes != 2U)
        return 0;
    entries[0].size_bytes = UINT64_MAX;
    if (candidate_geometry(&plan, 8192U, &size, &inodes)) return 0;
    entries[0].size_bytes = 8193U;
    entries[1].is_file = 0;
    plan.entry_count = 2U;
    if (!candidate_geometry(&plan, 8192U, &size, &inodes) ||
        size != 4U * 8192U || inodes != 3U)
        return 0;
    if (candidate_geometry(&plan, 0U, &size, &inodes)) return 0;
    if (!candidate_count_matches(&plan, 1U) || candidate_count_matches(&plan, 0U) ||
        candidate_count_matches(&plan, 2U))
        return 0;
    plan.entry_count = 0U;
    return candidate_count_matches(&plan, 0U);
}

static int write_input_test_frame(int fd, int omit_verifier, size_t candidates)
{
    struct ys_frame_writer writer;
    size_t i;
    if (!ys_frame_writer_open(&writer, fd) ||
        ys_frame_writer_put(&writer, "plan.json", 9U, "{}", 2U) != YS_FRAME_OK ||
        ys_frame_writer_put(&writer, "instruction", 11U, "x", 1U) != YS_FRAME_OK)
        return 0;
    if (!omit_verifier &&
        ys_frame_writer_put(&writer, "verifier", 8U, "v", 1U) != YS_FRAME_OK)
        return 0;
    for (i = 0; i < candidates; i++) {
        char name[15];
        int n = snprintf(name, sizeof name, "candidate/%04zu", i);
        if (n != 14 || ys_frame_writer_put(&writer, name, 14U, "c", 1U) != YS_FRAME_OK)
            return 0;
    }
    return ys_frame_writer_close(&writer) == YS_FRAME_OK;
}

static int test_input_loading(const char *directory)
{
    char good[512], missing[512];
    struct loaded_input input;
    int fd;
    if (!join_path(good, sizeof good, directory, "input-good") ||
        !join_path(missing, sizeof missing, directory, "input-missing"))
        return 0;
    fd = open(good, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0 || !write_input_test_frame(fd, 0, 2U) || lseek(fd, 0, SEEK_SET) != 0 ||
        !load_input(fd, &input) || input.candidate_count != 2U) return 0;
    loaded_input_free(&input);
    (void)close(fd);
    fd = open(missing, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0 || !write_input_test_frame(fd, 1, 0U) || lseek(fd, 0, SEEK_SET) != 0 ||
        load_input(fd, &input)) return 0;
    (void)close(fd);
    return 1;
}

static int test_instruction_descriptor(const char *directory)
{
    static const unsigned char content[] = "instruction bytes";
    unsigned char readback[sizeof content];
    struct stat st;
    int dirfd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    int fd, flags;
    if (dirfd < 0) return 0;
    fd = readonly_instruction_at(dirfd, content, sizeof content - 1U);
    (void)close(dirfd);
    if (fd < 0) return 0;
    flags = fcntl(fd, F_GETFL);
    if (flags < 0 || (flags & O_ACCMODE) != O_RDONLY || fstat(fd, &st) != 0 ||
        !S_ISREG(st.st_mode) || write(fd, "x", 1) != -1 || errno != EBADF ||
        read(fd, readback, sizeof content - 1U) != (ssize_t)(sizeof content - 1U) ||
        memcmp(readback, content, sizeof content - 1U) != 0) {
        (void)close(fd);
        return 0;
    }
    (void)close(fd);
    dirfd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dirfd < 0) return 0;
    fd = readonly_instruction_at(dirfd, content, 0U);
    (void)close(dirfd);
    if (fd < 0 || fstat(fd, &st) != 0 || st.st_size != 0 || write(fd, "x", 1) != -1 ||
        errno != EBADF) {
        if (fd >= 0) (void)close(fd);
        return 0;
    }
    (void)close(fd);
    dirfd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dirfd < 0) return 0;
    fd = openat(dirfd, ".instruction", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0 || close(fd) != 0 || readonly_instruction_at(dirfd, content,
        sizeof content - 1U) != -1 || unlinkat(dirfd, ".instruction", 0) != 0) {
        if (fd >= 0) (void)close(fd);
        (void)close(dirfd);
        return 0;
    }
    (void)close(dirfd);
    return 1;
}

static int test_privilege_order(void)
{
    static const enum privilege_step expected[] = {
        PRIV_CLEAR_GROUPS, PRIV_SET_GIDS, PRIV_DROP_BOUNDING, PRIV_SET_UIDS,
        PRIV_CLEAR_CAPS, PRIV_NO_NEW_PRIVS, PRIV_VERIFY
    };
    struct privilege_test_state state;
    size_t i;
    memset(&state, 0, sizeof state);
    state.fail_at = -1;
    if (!run_privilege_sequence(record_privilege_step, &state) ||
        state.count != sizeof expected / sizeof expected[0] ||
        memcmp(state.seen, expected, sizeof expected) != 0)
        return 0;
    for (i = 0; i < sizeof expected / sizeof expected[0]; i++) {
        memset(&state, 0, sizeof state);
        state.fail_at = (int)expected[i];
        if (run_privilege_sequence(record_privilege_step, &state) || state.count != i + 1U)
            return 0;
    }
    return 1;
}

static int child_succeeded(pid_t child)
{
    int status;
    return waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static int test_actual_privilege_state(void)
{
    pid_t child;
    if (geteuid() != 0) {
        (void)printf("SKIP: actual uid/gid/capability drop needs uid 0 in the isolated test environment\n");
        return 1;
    }
    child = fork();
    if (child < 0) return 0;
    if (child == 0) _exit(run_privilege_sequence(actual_privilege_step, NULL) ? 0 : 1);
    return child_succeeded(child);
}

static int join_path(char *out, size_t cap, const char *parent, const char *leaf)
{
    int length = snprintf(out, cap, "%s/%s", parent, leaf);
    return length >= 0 && (size_t)length < cap;
}

static int test_searchable_ancestors(const char *base)
{
    char sandbox[512], candidate[512], tools[512], verifier[512], unwanted[512];
    int fd;
    pid_t child;
    if (!join_path(sandbox, sizeof sandbox, base, "sandbox") ||
        !join_path(candidate, sizeof candidate, sandbox, "candidate") ||
        !join_path(tools, sizeof tools, sandbox, "tools") ||
        !join_path(verifier, sizeof verifier, tools, "verifier") ||
        !join_path(unwanted, sizeof unwanted, candidate, "unwanted"))
        return 0;
    if (mkdir(sandbox, 0700) != 0 || mkdir(candidate, 0700) != 0 || mkdir(tools, 0700) != 0)
        return 0;
    fd = open(verifier, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0555);
    if (fd < 0 || write(fd, "tool", 4) != 4 || close(fd) != 0 || chmod(verifier, 0555) != 0 ||
        !make_searchable_read_only(base) || !make_searchable_read_only(sandbox) ||
        !make_searchable_read_only(candidate) || !make_searchable_read_only(tools))
        return 0;
    child = fork();
    if (child < 0) return 0;
    if (child == 0) {
        int candidate_fd, tool_fd, denied_fd;
        if (geteuid() == 0 && (setgroups(0, NULL) != 0 ||
            setresgid(GUEST_GID, GUEST_GID, GUEST_GID) != 0 ||
            setresuid(GUEST_UID, GUEST_UID, GUEST_UID) != 0))
            _exit(2);
        candidate_fd = open(candidate, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        tool_fd = open(verifier, O_RDONLY | O_CLOEXEC);
        denied_fd = open(unwanted, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (denied_fd >= 0) { (void)close(denied_fd); _exit(3); }
        if (candidate_fd < 0 || tool_fd < 0) _exit(4);
        (void)close(candidate_fd);
        (void)close(tool_fd);
        _exit(0);
    }
    if (geteuid() != 0)
        (void)printf("SKIP: ancestor access used enforced 0555 modes but actual uid 65534 needs uid 0\n");
    return child_succeeded(child);
}

static int test_filter(void)
{
    struct seccomp_prog_builder builder;
    static const int direct_denials[] = {
#ifdef __NR_socket
        __NR_socket,
#endif
#ifdef __NR_socketpair
        __NR_socketpair,
#endif
#ifdef __NR_mknod
        __NR_mknod,
#endif
#ifdef __NR_mknodat
        __NR_mknodat,
#endif
#ifdef __NR_fallocate
        __NR_fallocate,
#endif
#ifdef __NR_truncate
        __NR_truncate,
#endif
#ifdef __NR_ftruncate
        __NR_ftruncate,
#endif
#ifdef __NR_lseek
        __NR_lseek,
#endif
#ifdef __NR_pwrite64
        __NR_pwrite64,
#endif
#ifdef __NR_pwritev
        __NR_pwritev,
#endif
#ifdef __NR_pwritev2
        __NR_pwritev2,
#endif
#ifdef __NR_openat2
        __NR_openat2,
#endif
#ifdef __NR_open_by_handle_at
        __NR_open_by_handle_at,
#endif
#ifdef __NR_name_to_handle_at
        __NR_name_to_handle_at,
#endif
#ifdef __NR_splice
        __NR_splice,
#endif
#ifdef __NR_vmsplice
        __NR_vmsplice,
#endif
#ifdef __NR_tee
        __NR_tee,
#endif
#ifdef __NR_sendfile
        __NR_sendfile,
#endif
#ifdef __NR_copy_file_range
        __NR_copy_file_range,
#endif
#ifdef __NR_io_uring_setup
        __NR_io_uring_setup,
#endif
#ifdef __NR_io_uring_enter
        __NR_io_uring_enter,
#endif
#ifdef __NR_io_uring_register
        __NR_io_uring_register,
#endif
#ifdef __NR_io_setup
        __NR_io_setup,
#endif
#ifdef __NR_io_submit
        __NR_io_submit,
#endif
#ifdef __NR_userfaultfd
        __NR_userfaultfd,
#endif
#ifdef __NR_perf_event_open
        __NR_perf_event_open,
#endif
#ifdef __NR_bpf
        __NR_bpf,
#endif
#ifdef __NR_ptrace
        __NR_ptrace,
#endif
#ifdef __NR_process_vm_readv
        __NR_process_vm_readv,
#endif
#ifdef __NR_process_vm_writev
        __NR_process_vm_writev,
#endif
#ifdef __NR_linkat
        __NR_linkat,
#endif
#ifdef __NR_symlinkat
        __NR_symlinkat,
#endif
#ifdef __NR_mount
        __NR_mount,
#endif
#ifdef __NR_umount2
        __NR_umount2,
#endif
#ifdef __NR_pivot_root
        __NR_pivot_root,
#endif
#ifdef __NR_move_mount
        __NR_move_mount,
#endif
#ifdef __NR_open_tree
        __NR_open_tree,
#endif
#ifdef __NR_fsopen
        __NR_fsopen,
#endif
#ifdef __NR_fsmount
        __NR_fsmount,
#endif
#ifdef __NR_unshare
        __NR_unshare,
#endif
#ifdef __NR_setns
        __NR_setns,
#endif
#ifdef __NR_clone3
        __NR_clone3,
#endif
#ifdef __NR_keyctl
        __NR_keyctl,
#endif
#ifdef __NR_add_key
        __NR_add_key,
#endif
#ifdef __NR_request_key
        __NR_request_key,
#endif
#ifdef __NR_acct
        __NR_acct,
#endif
#ifdef __NR_swapon
        __NR_swapon,
#endif
    };
    size_t i;
    if (!build_seccomp_filter(&builder) || builder.failed || builder.n == 0U) return 0;
    builder.n = YS_SECCOMP_MAX_INSN;
    builder.failed = 0;
    sb_push(&builder, (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW));
    if (!builder.failed || !build_seccomp_filter(&builder)) return 0;
    for (i = 0; i < sizeof direct_denials / sizeof direct_denials[0]; i++)
        if (!filter_denies(&builder, direct_denials[i], 0U, 0U)) return 0;
#ifdef __NR_read
    if (filter_denies(&builder, __NR_read, 0U, 0U)) return 0;
#endif
#ifdef __NR_openat
    if (filter_denies(&builder, __NR_openat, 2U, O_RDONLY | O_DIRECTORY) ||
        !filter_denies(&builder, __NR_openat, 2U, O_TMPFILE | O_RDWR))
        return 0;
#endif
#ifdef __NR_madvise
    if (!filter_denies(&builder, __NR_madvise, 2U, MADV_REMOVE) ||
        filter_denies(&builder, __NR_madvise, 2U, MADV_REMOVE | 16U))
        return 0;
#endif
#ifdef __NR_clone
    if (filter_denies(&builder, __NR_clone, 0U, SIGCHLD) ||
        !filter_denies(&builder, __NR_clone, 0U, CLONE_NEWNS | SIGCHLD))
        return 0;
#endif
    if ((filter_result(&builder, 0U, 0, 0U, 0U) & SECCOMP_RET_ACTION_FULL) !=
        SECCOMP_RET_ERRNO)
        return 0;
    return 1;
}

static int test_exec_classification(void)
{
    struct exec_channel_state state;
    struct ys_exec_outcome ready = { YS_EXEC_READY, YS_EXEC_PHASE_EXECVE, 0U, 0 };
    struct ys_exec_outcome failure = { YS_EXEC_FAILURE, YS_EXEC_PHASE_EXECVE, 0U, ENOENT };
    int exited0 = 0 << 8;
    int exited126 = 126 << 8;
    int exited127 = 127 << 8;
    memset(&state, 0, sizeof state);
    memcpy(state.bytes, &ready, sizeof ready);
    state.length = sizeof ready; state.eof = 1;
    if (!exec_channel_confirms_execution(&state, exited0) ||
        !exec_channel_confirms_execution(&state, exited126) ||
        !exec_channel_confirms_execution(&state, exited127))
        return 0;
    if (!execution_was_verified(&state, exited0, 1, 1, 0, 0) ||
        execution_was_verified(&state, exited0, 1, 1, 1, 0) ||
        execution_was_verified(&state, exited0, 1, 1, 0, 1) ||
        execution_was_verified(&state, exited0, 0, 1, 0, 0) ||
        execution_was_verified(&state, exited0, 1, 0, 0, 0))
        return 0;
    if (exec_channel_confirms_execution(&state, SIGKILL) ||
        (state.eof = 0, exec_channel_confirms_execution(&state, exited0)))
        return 0;
    state.eof = 1; state.length--;
    if (exec_channel_confirms_execution(&state, exited0)) return 0;
    state.length = sizeof ready; state.invalid = 1;
    if (exec_channel_confirms_execution(&state, exited0)) return 0;
    state.invalid = 0;
    memcpy(state.bytes, &failure, sizeof failure);
    if (exec_channel_confirms_execution(&state, exited127)) return 0;
    memcpy(state.bytes, &ready, sizeof ready);
    memcpy(state.bytes + sizeof ready, &failure, sizeof failure);
    state.length = sizeof ready + sizeof failure;
    if (exec_channel_confirms_execution(&state, exited127)) return 0;
    memcpy(state.bytes, &ready, sizeof ready); state.length = sizeof ready;
    state.bytes[2] = 1U;
    return !exec_channel_confirms_execution(&state, exited0);
}

static int population_mode, population_calls;
static int test_population_read(void)
{
    population_calls++;
    if (population_mode < 0) return -1;
    if (population_mode == 0) return 0;
    return population_mode == 1 ? 1 : (population_calls < 3 ? 1 : 0);
}

static int test_termination_confirmation(void)
{
    ys_test_population_reader = test_population_read;
    population_mode = 0; population_calls = 0;
    if (!confirm_tree_terminated(4U) || population_calls != 1) return 0;
    population_mode = -1; population_calls = 0;
    if (confirm_tree_terminated(4U) || population_calls != 1) return 0;
    population_mode = 1; population_calls = 0;
    if (confirm_tree_terminated(4U) || population_calls != 4) return 0;
    population_mode = 2; population_calls = 0;
    if (!confirm_tree_terminated(4U) || population_calls != 3) return 0;
    ys_test_population_reader = NULL;
    return 1;
}

static int write_validation_report(const char *path)
{
    struct report_state state;
    char digest[65];
    char *report;
    size_t length;
    FILE *stream;
    memset(&state, 0, sizeof state);
    memset(digest, 'a', 64U); digest[64] = '\0';
    state.verifier_started = 1; state.tree_terminated = 1;
    state.cpu = (struct guest_row){ 0U, "complete", "none", 0, 1U };
    state.memory = (struct guest_row){ 0U, "complete", "hard", 0, 4096U };
    state.output = (struct guest_row){ 0U, "complete", "hard", 0, 1U };
    state.tasks = (struct guest_row){ 0U, "complete", "hard", 0, 1U };
    state.scratch = (struct guest_row){ 0U, "complete", "hard", 0, 4096U };
    report = build_report_json(digest, &state, &length);
    if (report == NULL) return 0;
    stream = fopen(path, "wb");
    if (stream == NULL) { free(report); return 0; }
    {
        int ok = fwrite(report, 1, length, stream) == length;
        if (fclose(stream) != 0) ok = 0;
        if (!ok) {
            free(report);
            return 0;
        }
    }
    free(report);
    return 1;
}

int main(int argc, char **argv)
{
    if (argc != 2 && argc != 3) return 2;
    if (!test_report_writer() || !test_fanotify_history() || !test_fanotify_service(argv[1]) ||
        !test_checked_arithmetic() || !test_input_loading(argv[1]) ||
        !test_geometry() ||
        !test_instruction_descriptor(argv[1]) || !test_privilege_order() ||
        !test_actual_privilege_state() || !test_searchable_ancestors(argv[1]) || !test_filter() ||
        !test_exec_classification() || !test_termination_confirmation())
        return 1;
    if (argc == 3 && !write_validation_report(argv[2])) return 1;
    (void)printf("production supervisor helpers: report, fanotify, geometry, instruction, privilege order, traversal, filter: ok\n");
    return 0;
}
#endif
