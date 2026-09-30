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
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/fanotify.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/reboot.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

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
    if (ys_frame_descriptor_capacity(fd, &cap) != YS_FRAME_OK) return 0;
    if (ys_frame_reader_open(&r, fd, cap) != YS_FRAME_OK) return 0;
    ys_record_set_init(&set, YS_RECORD_SET_INPUT);
    for (;;) {
        struct ys_frame_record rec;
        enum ys_frame_status st;
        uint32_t index;
        memset(&rec, 0, sizeof rec);
        st = ys_frame_reader_next(&r, &rec);
        if (st != YS_FRAME_OK) return 0;
        if (rec.is_end) return 1;
        st = ys_record_set_advance(&set, rec.name, rec.name_len, &index);
        if (st != YS_FRAME_OK) { free(rec.content); return 0; }
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
                size_t *lg = realloc(out->candidate_lens, nc * sizeof *lg);
                if (cg == NULL || lg == NULL) { free(rec.content); return 0; }
                out->candidates = cg; out->candidate_lens = lg; cand_cap = nc;
            }
            out->candidates[index] = take_content(&rec, &out->candidate_lens[index]);
            if (index + 1U > out->candidate_count) out->candidate_count = index + 1U;
        }
        free(rec.content);
    }
}

/* --- tmpfs mounts ----------------------------------------------------------
 * Every guest tmpfs is sized with slack beyond the raw file-byte total: a
 * tmpfs charges directory entries and inode metadata against its own
 * `size=` budget in page units, so "sized for exactly its files" (R5.5)
 * still needs room for the directory tree a manifest with subdirectories
 * materializes -- one page per directory is a generous, fixed allowance. */
#define TMPFS_PAGE 4096ULL

static int mount_tmpfs(const char *target, uint64_t size_bytes, uint64_t nr_inodes)
{
    char opts[128];
    int n = snprintf(opts, sizeof opts, "size=%llu,nr_inodes=%llu,mode=0700",
                      (unsigned long long)size_bytes, (unsigned long long)nr_inodes);
    if (n < 0 || (size_t)n >= sizeof opts) return 0;
    return mount("tmpfs", target, "tmpfs", MS_NOSUID, opts) == 0;
}

static int mkdir_p(const char *path, mode_t mode)
{
    if (mkdir(path, mode) == 0) return 1;
    return errno == EEXIST;
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

static int drop_all_capabilities(void)
{
    int i;
    for (i = 0; i <= 63; i++) (void)prctl(PR_CAPBSET_DROP, i, 0, 0, 0);
#ifndef YS_NO_CAPSET
    {
        struct ys_cap_header hdr = { YS_CAP_VERSION_3, 0 };
        struct ys_cap_data data[2];
        memset(data, 0, sizeof data);
        return syscall(SYS_capset, &hdr, data) == 0;
    }
#else
    return 0;
#endif
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
};
static void sb_push(struct seccomp_prog_builder *b, struct sock_filter f)
{
    if (b->n < YS_SECCOMP_MAX_INSN) b->insn[b->n++] = f;
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
#ifndef O_TMPFILE
#define O_TMPFILE 020200000
#endif
#define YS_CLONE_NEWMASK \
    (CLONE_NEWNS | CLONE_NEWCGROUP | CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWUSER | \
     CLONE_NEWPID | CLONE_NEWNET)
#ifndef MADV_REMOVE
#define MADV_REMOVE 9
#endif

static int apply_seccomp(void)
{
    struct seccomp_prog_builder b;
    struct sock_fprog prog;
    b.n = 0;
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
    add_deny_if_arg_set(&b, __NR_openat, 2, O_TMPFILE);
#endif
#ifdef __NR_madvise
    add_deny_if_arg_set(&b, __NR_madvise, 2, MADV_REMOVE);
#endif
#ifdef __NR_clone
    add_deny_if_arg_set(&b, __NR_clone, 0, YS_CLONE_NEWMASK);
#endif
    sb_push(&b, (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW));
    prog.len = (unsigned short)b.n;
    prog.filter = b.insn;
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return 0;
    return prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog) == 0;
}

/* The child, after clone3: pivot into the tmpfs root the parent already
 * fully prepared (R6.1), drop identity, apply Landlock and seccomp, then
 * ys_exec's the verifier (R6.4). Writes one byte to `started_fd` right
 * before that call -- the parent's only signal that setup reached the
 * exec wiring, since ys_exec itself never returns either way. Does not
 * return: every path ends in ys_exec or _exit(125). */
static void child_main(int instruction_fd, int stdout_fd, int stderr_fd, int started_fd)
{
    if (chdir(NEWROOT_DIR) != 0) _exit(125);
    if (syscall(SYS_pivot_root, ".", ".") != 0) _exit(125);
    if (umount2(".", MNT_DETACH) != 0) _exit(125);
    if (chdir("/") != 0) _exit(125);
    if (setgroups(0, NULL) != 0) _exit(125);
    if (setresgid(GUEST_GID, GUEST_GID, GUEST_GID) != 0) _exit(125);
    if (!drop_all_capabilities()) _exit(125);
    if (setresuid(GUEST_UID, GUEST_UID, GUEST_UID) != 0) _exit(125);
    {
        struct rlimit core, rt;
        core.rlim_cur = 0; core.rlim_max = 0;
        rt.rlim_cur = 0; rt.rlim_max = 0;
        if (setrlimit(RLIMIT_CORE, &core) != 0) _exit(125);
        if (setrlimit(RLIMIT_RTPRIO, &rt) != 0) _exit(125);
    }
    {
        struct sched_param sp;
        memset(&sp, 0, sizeof sp);
        if (sched_setscheduler(0, SCHED_OTHER, &sp) != 0) _exit(125);
    }
    if (!apply_landlock()) _exit(125);
    if (!apply_seccomp()) _exit(125);
    (void)write(started_fd, "K", 1);
    ys_exec(YS_PLAN_ARGV, YS_PLAN_ENVIRONMENT, instruction_fd, stdout_fd, stderr_fd);
    _exit(125); /* unreached: ys_exec never returns */
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

static size_t append_row(char *buf, size_t cap, size_t pos, const char *name,
                          const struct guest_row *r)
{
    int n;
    if (r->observation != NULL && strcmp(r->observation, "unavailable") == 0)
        n = snprintf(buf + pos, cap - pos,
                      "\"%s\":{\"enforcement\":\"%s\",\"observation\":\"unavailable\","
                      "\"observed\":null,\"reached\":false,\"resolution\":%llu}",
                      name, r->enforcement, (unsigned long long)r->resolution);
    else
        n = snprintf(buf + pos, cap - pos,
                      "\"%s\":{\"enforcement\":\"%s\",\"observation\":\"%s\","
                      "\"observed\":%llu,\"reached\":%s,\"resolution\":%llu}",
                      name, r->enforcement, r->observation, (unsigned long long)r->observed,
                      r->reached ? "true" : "false", (unsigned long long)r->resolution);
    return (n < 0) ? pos : pos + (size_t)n;
}

/* Builds the canonical report.json bytes into a malloc'd buffer (caller
 * frees). Returns NULL only on an internal buffer-sizing failure -- every
 * field is already bounded (hex digests, small integers, a short,
 * evidence-count-bounded array), so that should not happen in practice. */
static char *build_report_json(const char plan_sha256_hex[65],
                                const struct report_state *s, size_t *len_out)
{
    size_t cap = 8192 + s->evidence_count * 96U;
    char *buf = malloc(cap);
    size_t pos = 0;
    size_t i;
    int n;
    if (buf == NULL) return NULL;
    n = snprintf(buf + pos, cap - pos, "{\"body\":{\"evidence_files\":[");
    pos += (size_t)n;
    for (i = 0; i < s->evidence_count; i++) {
        char hex[513];
        size_t namelen = strlen(s->evidence_names[i]);
        struct stat st;
        char path[300];
        if (namelen > 255U) namelen = 255U;
        ys_hex_encode((const unsigned char *)s->evidence_names[i], namelen, hex);
        hex[namelen * 2U] = '\0';
        snprintf(path, sizeof path, "%s/%s", EVIDENCE_SUBDIR, s->evidence_names[i]);
        if (stat(path, &st) != 0) st.st_size = 0;
        n = snprintf(buf + pos, cap - pos, "%s{\"index\":%zu,\"name_hex\":\"%s\",\"size_bytes\":%lld}",
                      (i == 0U) ? "" : ",", i, hex, (long long)st.st_size);
        pos += (size_t)n;
    }
    n = snprintf(buf + pos, cap - pos, "],");
    pos += (size_t)n;
    if (s->exit_signaled)
        n = snprintf(buf + pos, cap - pos, "\"exit_code\":null,\"exit_state\":\"signaled\",");
    else
        n = snprintf(buf + pos, cap - pos, "\"exit_code\":%d,\"exit_state\":\"exited\",",
                      s->exit_code);
    pos += (size_t)n;
    n = snprintf(buf + pos, cap - pos, "\"limits\":{");
    pos += (size_t)n;
    pos = append_row(buf, cap, pos, "cpu_time_ms", &s->cpu);
    n = snprintf(buf + pos, cap - pos, ",");
    pos += (size_t)n;
    pos = append_row(buf, cap, pos, "memory_bytes", &s->memory);
    n = snprintf(buf + pos, cap - pos, ",");
    pos += (size_t)n;
    pos = append_row(buf, cap, pos, "output_bytes", &s->output);
    n = snprintf(buf + pos, cap - pos, ",");
    pos += (size_t)n;
    pos = append_row(buf, cap, pos, "process_count", &s->tasks);
    n = snprintf(buf + pos, cap - pos, ",");
    pos += (size_t)n;
    pos = append_row(buf, cap, pos, "scratch_bytes", &s->scratch);
    n = snprintf(buf + pos, cap - pos,
                  "},\"plan_sha256\":\"%.64s\",\"stderr_bytes\":%llu,\"stdout_bytes\":%llu,"
                  "\"tree_deadline_fired\":%s,\"tree_terminated\":%s,\"verifier_started\":%s},"
                  "\"kind\":\"sandbox_guest_report\",\"schema_version\":1}\n",
                  plan_sha256_hex, (unsigned long long)s->stderr_bytes,
                  (unsigned long long)s->stdout_bytes, s->tree_deadline_fired ? "true" : "false",
                  s->tree_terminated ? "true" : "false", s->verifier_started ? "true" : "false");
    pos += (size_t)n;
    *len_out = pos;
    return buf;
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

static int fanotify_open_mark(struct fanotify_state *fs)
{
#if defined(SYS_fanotify_init) && defined(SYS_fanotify_mark)
    fs->fd = (int)syscall(SYS_fanotify_init, FAN_CLASS_CONTENT | FAN_CLOEXEC, O_RDONLY);
    if (fs->fd < 0) return 0;
    if (syscall(SYS_fanotify_mark, fs->fd, FAN_MARK_ADD | FAN_MARK_FILESYSTEM, (uint64_t)FAN_OPEN_PERM,
                AT_FDCWD, OUTPUT_DIR) != 0) {
        (void)close(fs->fd);
        return 0;
    }
    return 1;
#else
    (void)fs;
    return 0;
#endif
}

static int inode_already_seen(struct fanotify_state *fs, dev_t dev, ino_t ino)
{
    size_t i;
    for (i = 0; i < fs->seen_count; i++)
        if (fs->seen[i].dev == dev && fs->seen[i].ino == ino) return 1;
    if (fs->seen_count < 256U) fs->seen[fs->seen_count++] = (struct seen_inode){ dev, ino };
    return 0;
}

/* Reads and answers every pending permission event; called whenever
 * poll() reports the fanotify fd readable. Approves the first open of an
 * empty (size 0) regular file's inode, denies every other open --
 * including a second open of a file this same rule already approved once
 * (R7.1: "allows only the first open of an empty inode"). */
static void fanotify_service(struct fanotify_state *fs)
{
    char buf[4096];
    ssize_t len = read(fs->fd, buf, sizeof buf);
    struct fanotify_event_metadata *m;
    if (len <= 0) return;
    for (m = (struct fanotify_event_metadata *)buf; FAN_EVENT_OK(m, len); m = FAN_EVENT_NEXT(m, len)) {
        struct fanotify_response resp;
        struct stat st;
        int allow = 0;
        if (m->fd >= 0) {
            if (fstat(m->fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size == 0 &&
                !inode_already_seen(fs, st.st_dev, st.st_ino))
                allow = 1;
            resp.fd = m->fd;
            resp.response = allow ? FAN_ALLOW : FAN_DENY;
            (void)write(fs->fd, &resp, sizeof resp);
            (void)close(m->fd);
        }
    }
}

/* Puts `len` bytes of `data` into a private, anonymous, seekable file (the
 * instruction copy R6.4 wires to the verifier's fd 0): memfd_create when
 * the kernel has it, else an O_TMPFILE regular file unlinked from the
 * start (both leave nothing else able to open it by path). Returns a
 * descriptor already lseek'd back to offset 0, or -1. */
static int memfd_or_tmpfile(const unsigned char *data, size_t len)
{
    int fd = -1;
#if defined(SYS_memfd_create)
    fd = (int)syscall(SYS_memfd_create, "instr", 0U);
#endif
    if (fd < 0) fd = open("/ys", O_RDWR | O_TMPFILE | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    {
        size_t written = 0;
        while (written < len) {
            ssize_t n = write(fd, data + written, len - written);
            if (n < 0) { (void)close(fd); return -1; }
            written += (size_t)n;
        }
    }
    if (lseek(fd, 0, SEEK_SET) != 0) { (void)close(fd); return -1; }
    return fd;
}

/* --- main ------------------------------------------------------------------ */
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
    int started_pipe[2];
    pid_t child_pid = -1;
    struct timespec t0, tnow;
    uint64_t deadline_ms;

    memset(&rs, 0, sizeof rs);
    fan.fd = -1;

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

    /* candidate tmpfs: materialized, then finalized read-only (R5.5). */
    {
        uint64_t total = 0;
        size_t dirs = 1, files = 0;
        for (i = 0; i < plan.entry_count; i++) {
            if (plan.entries[i].is_file) { total += plan.entries[i].size_bytes; files++; }
            else dirs++;
        }
        if (!mkdir_p(CANDIDATE_DIR, 0700) ||
            !mount_tmpfs(CANDIDATE_DIR, total + dirs * TMPFS_PAGE, files + dirs + 1U))
            goto export_partial;
        cand_fd = open(CANDIDATE_DIR, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (cand_fd < 0 ||
            ys_plan_materialize(cand_fd, GUEST_UID, GUEST_GID, &plan,
                                 (const unsigned char *const *)in.candidates, in.candidate_lens) !=
                YS_PLAN_OK)
            goto export_partial;
        (void)close(cand_fd);
        if (!remount_ro(CANDIDATE_DIR, MS_NOEXEC)) goto export_partial;
    }
    /* tools tmpfs: the verifier only, root-owned, read-only+executable. */
    if (!mkdir_p(TOOLS_DIR, 0700) ||
        !mount_tmpfs(TOOLS_DIR, in.verifier_len + TMPFS_PAGE, 2U))
        goto export_partial;
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
    if (!mkdir_p(NEWROOT_DIR, 0700) || !mount_tmpfs(NEWROOT_DIR, 5U * TMPFS_PAGE, 10U) ||
        !mkdir_p(NEWROOT_DIR "/sandbox", 0500))
        goto export_partial;
    if (!bind_into_newroot(CANDIDATE_DIR, "candidate", 1, 1) ||
        !bind_into_newroot(TOOLS_DIR, "tools", 1, 0) ||
        !bind_into_newroot(SCRATCH_DIR, "scratch", 0, 1) ||
        !bind_into_newroot(EVIDENCE_SUBDIR, "evidence", 0, 1))
        goto export_partial;

    {
        int outfd = openat(AT_FDCWD, OUTPUT_DIR "/stdout", O_WRONLY | O_CREAT | O_EXCL | O_APPEND, 0600);
        int errfd = openat(AT_FDCWD, OUTPUT_DIR "/stderr", O_WRONLY | O_CREAT | O_EXCL | O_APPEND, 0600);
        int instr_fd = memfd_or_tmpfile(in.instruction, in.instruction_len);
        if (outfd < 0 || errfd < 0 || instr_fd < 0) goto export_partial;
        instr_priv_fd = instr_fd;
        if (!fanotify_open_mark(&fan)) goto export_partial;
        if (pipe2(started_pipe, O_CLOEXEC) != 0) goto export_partial;
        child_pid = ys_clone3_into_cgroup(cg.cgroup_fd);
        if (child_pid == 0) {
            (void)close(started_pipe[0]);
            child_main(instr_priv_fd, outfd, errfd, started_pipe[1]);
            _exit(125);
        }
        (void)close(outfd); (void)close(errfd); (void)close(instr_priv_fd);
        (void)close(started_pipe[1]);
        if (child_pid < 0) goto export_partial;
        {
            char sentinel = 0;
            rs.verifier_started = (read(started_pipe[0], &sentinel, 1) == 1 && sentinel == 'K');
            (void)close(started_pipe[0]);
        }
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
        if (fan.fd >= 0) {
            struct pollfd pfd = { fan.fd, POLLIN, 0 };
            if (poll(&pfd, 1, (int)(remaining_ms > 200 ? 200 : remaining_ms)) > 0 &&
                (pfd.revents & POLLIN))
                fanotify_service(&fan);
        } else {
            struct timespec ts = { 0, 200000000L };
            nanosleep(&ts, NULL);
        }
        r = waitpid(child_pid, &status, WNOHANG);
        if (r == child_pid) {
            rs.tree_terminated = (cgroup_populated() == 0);
            if (!rs.tree_terminated) {
                int tries;
                for (tries = 0; tries < 50 && cgroup_populated() != 0; tries++) {
                    struct timespec ts = { 0, 100000000L };
                    nanosleep(&ts, NULL);
                }
                rs.tree_terminated = (cgroup_populated() == 0);
            }
            if (WIFEXITED(status)) { rs.exit_signaled = 0; rs.exit_code = WEXITSTATUS(status); }
            else { rs.exit_signaled = 1; }
            goto reaped;
        }
    }
    /* Deadline path: wait for cgroup.events populated 0, then reap. */
    {
        int tries, status;
        for (tries = 0; tries < 400 && cgroup_populated() != 0; tries++) {
            struct timespec ts = { 0, 100000000L };
            nanosleep(&ts, NULL);
        }
        rs.tree_terminated = (cgroup_populated() == 0);
        if (waitpid(child_pid, &status, 0) == child_pid) {
            if (WIFEXITED(status)) { rs.exit_signaled = 0; rs.exit_code = WEXITSTATUS(status); }
            else { rs.exit_signaled = 1; }
        }
    }
reaped:
    if (fan.fd >= 0) { (void)close(fan.fd); fan.fd = -1; } /* closed before export (R7.1) */

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
                        (void)ys_frame_writer_put(&w, "report.json", 11U, report, report_len);
                        (void)ys_frame_writer_put(&w, "stdout", 6U, stdout_buf, got1);
                        (void)ys_frame_writer_put(&w, "stderr", 6U, stderr_buf, got2);
                        for (i = 0; i < rs.evidence_count; i++) {
                            char name[16];
                            char path[300];
                            struct stat st;
                            unsigned char *buf;
                            int fd;
                            snprintf(name, sizeof name, "evidence/%04zu", i);
                            snprintf(path, sizeof path, "%s/%s", EVIDENCE_SUBDIR, rs.evidence_names[i]);
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
                                    (void)ys_frame_writer_put(&w, name, strlen(name), buf, got);
                                    free(buf);
                                }
                            }
                            if (fd >= 0) (void)close(fd);
                        }
                    }
                    if (sfd >= 0) (void)close(sfd);
                    if (efd >= 0) (void)close(efd);
                    free(stdout_buf); free(stderr_buf);
                    (void)ys_frame_writer_close(&w);
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
