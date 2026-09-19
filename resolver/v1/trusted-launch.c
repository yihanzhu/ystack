/* copy-begin scripts/test/portable-profile-resolution-launcher.c:1-17 at f4de7e48c688b6adb3669f69a221d2aa7bf43b15 */
#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
/* copy-end */

/* deviation 2: <dirent.h> is needed unconditionally on both platforms for the
   startup /dev/fd enumeration this step adds (R5), not only under __linux__ as
   the copied launcher has it below for process_group_count's /proc walk. This
   splits the original :1-43 copy span in two around this one inserted line --
   :1-17 above (the plain includes, unaffected) and :19-43 below (the platform
   block and constants, unaffected) -- rather than widen either span silently.
   The launcher's own blank separator line 18 is not part of either span: it
   sits between them and is replaced by this comment block and the two new
   includes, so neither sub-span claims it. The step-1 copy-identity check for
   :1-43 must move to checking the two sub-spans with this line between them. */
#include <dirent.h>

/* step 4 (deviation 6): <sys/select.h> is needed for the bounded wait every branch
   of the installed handler uses (spec R2's twenty-iteration 50 ms wait) -- the
   copied launcher installs no handler and never waits this way. Added here beside
   the other new-code include above rather than inside either copied span below. */
#include <sys/select.h>

/* copy-begin scripts/test/portable-profile-resolution-launcher.c:19-43 at f4de7e48c688b6adb3669f69a221d2aa7bf43b15 */
#if defined(__linux__)
#include <dirent.h>
#elif defined(__APPLE__)
#include <libproc.h>
#include <mach/vm_prot.h>
#include <sys/proc_info.h>
#endif

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif
#define PROCESS_LIMIT 32U
#define INVOCATION_SECONDS 300
#define ERROR_BYTES_MAX 256U
#define ADDRESS_SPACE_LIMIT UINT64_C(536870912)

enum stop_reason {
    STOP_NONE = 0,
    STOP_PROCESS,
    STOP_MEMORY,
    STOP_TIME
};
/* copy-end */

/* copy-begin scripts/test/portable-profile-resolution-launcher.c:45-82 at f4de7e48c688b6adb3669f69a221d2aa7bf43b15 */
static int set_limit(int resource, rlim_t value) {
    struct rlimit limit = {value, value};
    return setrlimit(resource, &limit);
}

static int regular_absolute(const char *path, int executable) {
    struct stat state;
    if (path == NULL || path[0] != '/' || lstat(path, &state) != 0 ||
        !S_ISREG(state.st_mode) || S_ISLNK(state.st_mode)) {
        return 0;
    }
    return !executable || access(path, X_OK) == 0;
}

static char *environment_value(const char *name, const char *value) {
    size_t size = strlen(name) + strlen(value) + 2;
    char *entry = malloc(size);
    if (entry == NULL || snprintf(entry, size, "%s=%s", name, value) < 0) {
        free(entry);
        return NULL;
    }
    return entry;
}

static int write_all(int descriptor, const char *bytes, size_t length) {
    size_t offset = 0U;
    while (offset < length) {
        ssize_t written = write(descriptor, bytes + offset, length - offset);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            return -1;
        }
        offset += (size_t)written;
    }
    return 0;
}
/* copy-end */

/* deviation 7: stream_file/empty_regular_file/sanitized_error move from path-based
   open()/lstat() (portable-profile-resolution-launcher.c:84-165) onto the descriptors
   the parent already created and checked with openat(..., O_CREAT|O_EXCL|O_NOFOLLOW)
   (R5, R7) -- no path is resolved a second time between the parent's own creation of
   child.stdout/child.stderr and its later read of them. The two files are opened
   O_RDWR by the caller (below) rather than O_WRONLY, so the same descriptor that was
   written by the resolver child is rewound with lseek and read back here. This is one
   named deviation covering all three functions, not three; adapted rather than copied,
   so no copy-begin/copy-end wraps it. */
static int stream_file(int descriptor, int output) {
    char buffer[16384];
    struct stat state;
    if (fstat(descriptor, &state) != 0 || !S_ISREG(state.st_mode) ||
        lseek(descriptor, 0, SEEK_SET) != 0) {
        return -1;
    }
    for (;;) {
        ssize_t count = read(descriptor, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count < 0 ||
            (count > 0 && write_all(output, buffer, (size_t)count) != 0)) {
            return -1;
        }
        if (count == 0) {
            break;
        }
    }
    return 0;
}

static int empty_regular_file(int descriptor) {
    struct stat state;
    return fstat(descriptor, &state) == 0 && S_ISREG(state.st_mode) &&
           state.st_size == 0;
}

static int sanitized_error(int descriptor) {
    char bytes[ERROR_BYTES_MAX + 1U];
    ssize_t count;
    char *space;
    if (lseek(descriptor, 0, SEEK_SET) != 0) {
        return 0;
    }
    count = read(descriptor, bytes, ERROR_BYTES_MAX + 1U);
    if (count <= 0 || count > (ssize_t)ERROR_BYTES_MAX ||
        bytes[count - 1] != '\n') {
        return 0;
    }
    bytes[count] = '\0';
    if (strchr(bytes, '\n') != bytes + count - 1) {
        return 0;
    }
    space = strchr(bytes, ' ');
    if (space != NULL) {
        *space = '\0';
    } else {
        bytes[count - 1] = '\0';
    }
    if (strcmp(bytes, "E_USAGE") != 0 && strcmp(bytes, "E_INPUT") != 0 &&
        strcmp(bytes, "E_RUNTIME") != 0 && strcmp(bytes, "E_PARSE") != 0 &&
        strcmp(bytes, "E_CANONICAL") != 0 && strcmp(bytes, "E_LIMIT") != 0 &&
        strcmp(bytes, "E_SHAPE") != 0 && strcmp(bytes, "E_REF") != 0 &&
        strcmp(bytes, "E_RELATION") != 0 && strcmp(bytes, "E_REPOSITORY") != 0 &&
        strcmp(bytes, "E_OBJECT") != 0) {
        return 0;
    }
    if (space != NULL) {
        *space = ' ';
    } else {
        bytes[count - 1] = '\n';
    }
    for (ssize_t index = 0; index < count - 1; index++) {
        unsigned char character = (unsigned char)bytes[index];
        if (!(character == ' ' || character == '-' || character == '_' ||
              (character >= '0' && character <= '9') ||
              (character >= 'A' && character <= 'Z') ||
              (character >= 'a' && character <= 'z'))) {
            return 0;
        }
    }
    return write_all(STDERR_FILENO, bytes, (size_t)count) == 0;
}

/* copy-begin scripts/test/portable-profile-resolution-launcher.c:167-174 at f4de7e48c688b6adb3669f69a221d2aa7bf43b15 */
static int monotonic_seconds(time_t *seconds) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return -1;
    }
    *seconds = now.tv_sec;
    return 0;
}
/* copy-end */

/* copy-begin scripts/test/portable-profile-resolution-launcher.c:176-386 at f4de7e48c688b6adb3669f69a221d2aa7bf43b15 */
#if defined(__linux__)
static unsigned process_group_count(pid_t group) {
    DIR *directory = opendir("/proc");
    struct dirent *entry;
    unsigned count = 0U;
    if (directory == NULL) {
        return PROCESS_LIMIT + 1U;
    }
    for (;;) {
        char path[64];
        char line[4096];
        char *end;
        FILE *stream;
        long observed_group;
        char state;
        long parent;
        errno = 0;
        entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0) {
                count = PROCESS_LIMIT + 1U;
            }
            break;
        }
        if (entry->d_name[0] < '0' || entry->d_name[0] > '9' ||
            strlen(entry->d_name) > 20U) {
            continue;
        }
        int path_length = snprintf(path, sizeof(path), "/proc/%s/stat", entry->d_name);
        if (path_length < 0 || (size_t)path_length >= sizeof(path)) {
            count = PROCESS_LIMIT + 1U;
            break;
        }
        stream = fopen(path, "r");
        if (stream == NULL) {
            continue;
        }
        if (fgets(line, sizeof(line), stream) == NULL) {
            (void)fclose(stream);
            continue;
        }
        (void)fclose(stream);
        end = strrchr(line, ')');
        if (end == NULL || sscanf(end + 1, " %c %ld %ld", &state, &parent,
                                  &observed_group) != 3) {
            continue;
        }
        (void)state;
        (void)parent;
        if ((pid_t)observed_group == group) {
            count++;
        }
    }
    (void)closedir(directory);
    return count;
}
#elif defined(__APPLE__)
static unsigned process_group_count(pid_t group) {
    for (unsigned attempt = 0U; attempt < 3U; attempt++) {
        int estimated = proc_listallpids(NULL, 0);
        pid_t *processes;
        int observed;
        unsigned count = 0U;
        if (estimated <= 0 || estimated > 1048576) {
            return PROCESS_LIMIT + 1U;
        }
        estimated += 64;
        processes = calloc((size_t)estimated, sizeof(*processes));
        if (processes == NULL) {
            return PROCESS_LIMIT + 1U;
        }
        observed = proc_listallpids(processes,
                                   estimated * (int)sizeof(*processes));
        if (observed < 0) {
            free(processes);
            return PROCESS_LIMIT + 1U;
        }
        if (observed < estimated) {
            for (int index = 0; index < observed; index++) {
                if (processes[index] > 0 && getpgid(processes[index]) == group) {
                    count++;
                }
            }
            free(processes);
            return count;
        }
        free(processes);
    }
    return PROCESS_LIMIT + 1U;
}
#else
static unsigned process_group_count(pid_t group) {
    (void)group;
    return PROCESS_LIMIT + 1U;
}
#endif

#if defined(__APPLE__)
static int darwin_private_virtual_size(pid_t process, uint64_t *total) {
    struct proc_taskinfo task;
    uint64_t address = 0U;
    uint64_t bytes = 0U;
    unsigned regions = 0U;
    int task_size = proc_pidinfo(process, PROC_PIDTASKINFO, 0, &task,
                                 (int)sizeof(task));
    if (task_size != (int)sizeof(task)) {
        return -1;
    }
    for (;;) {
        struct proc_regioninfo region;
        int region_size = proc_pidinfo(process, PROC_PIDREGIONINFO, address,
                                       &region, (int)sizeof(region));
        int charge = 0;
        if (region_size == 0) {
            break;
        }
        if (region_size != (int)sizeof(region) || region.pri_size == 0U ||
            region.pri_address < address ||
            UINT64_MAX - region.pri_address < region.pri_size ||
            ++regions > 1048576U) {
            return -1;
        }
        /* Shared read-only mappings are host state. Private and writable regions spend the bound. */
        switch (region.pri_share_mode) {
        case SM_PRIVATE:
        case SM_PRIVATE_ALIASED:
        case SM_LARGE_PAGE:
            charge = 1;
            break;
        case SM_COW:
        case SM_EMPTY:
            charge = (region.pri_protection & VM_PROT_WRITE) != 0U;
            break;
        case SM_SHARED:
        case SM_TRUESHARED:
        case SM_SHARED_ALIASED:
            break;
        default:
            return -1;
        }
        if (charge != 0) {
            if (UINT64_MAX - bytes < region.pri_size) {
                return -1;
            }
            bytes += region.pri_size;
            if (bytes > ADDRESS_SPACE_LIMIT) {
                *total = bytes;
                return 0;
            }
        }
        address = region.pri_address + region.pri_size;
    }
    if (bytes > task.pti_virtual_size) {
        return -1;
    }
    *total = bytes;
    return 0;
}

static int process_group_address_space_exceeded(pid_t group) {
    for (unsigned attempt = 0U; attempt < 3U; attempt++) {
        int estimated = proc_listallpids(NULL, 0);
        pid_t *processes;
        int observed;
        if (estimated <= 0 || estimated > 1048576) {
            return -1;
        }
        estimated += 64;
        processes = calloc((size_t)estimated, sizeof(*processes));
        if (processes == NULL) {
            return -1;
        }
        observed = proc_listallpids(processes,
                                   estimated * (int)sizeof(*processes));
        if (observed < 0) {
            free(processes);
            return -1;
        }
        if (observed < estimated) {
            for (int index = 0; index < observed; index++) {
                uint64_t private_virtual_size = 0U;
                pid_t process = processes[index];
                if (process <= 0 || getpgid(process) != group) {
                    continue;
                }
                if (darwin_private_virtual_size(process,
                                                &private_virtual_size) != 0) {
                    if (getpgid(process) == group) {
                        free(processes);
                        return -1;
                    }
                    continue;
                }
                if (private_virtual_size > ADDRESS_SPACE_LIMIT) {
                    free(processes);
                    return 1;
                }
            }
            free(processes);
            return 0;
        }
        free(processes);
    }
    return -1;
}
#else
static int process_group_address_space_exceeded(pid_t group) {
    (void)group;
    return 0;
}
#endif
/* copy-end */

/* copy-begin scripts/test/portable-profile-resolution-launcher.c:388-398 at f4de7e48c688b6adb3669f69a221d2aa7bf43b15 */
static int apply_child_limits(void) {
    if (set_limit(RLIMIT_CPU, 300) != 0 ||
#if !defined(__APPLE__)
        set_limit(RLIMIT_AS, 536870912) != 0 ||
#endif
        set_limit(RLIMIT_FSIZE, 67108864) != 0 ||
        set_limit(RLIMIT_NOFILE, 64) != 0) {
        return -1;
    }
    return 0;
}
/* copy-end */

/* --- step 3: startup descriptor close (deviation 2), output/.run/helper/binary/jq/awk
   checks by descriptor identity (deviations 3/4), the eight parent-pinned blob ids plus
   the jq SHA-256 and jq-1.6 probes under a fixed envp (deviations 4/8), all new code --
   the copied launcher has none of this. Every fork here goes through run_pinned_child()
   so step 4 has one place to wrap in the block/publish/reap region (deviation 6). */

#define YSTACK_CLOSE_RANGE_CAP 65536
#define YSTACK_PARENT_PIN_COUNT 8U
#define YSTACK_DARWIN_AWK_SHIM_LENGTH 35U
#define YSTACK_DIR_ENTRY_MAX 8U
#define YSTACK_DIR_NAME_MAX 256U

/* deviation 2 (startup half): opendir("/dev/fd"), close every numeric entry except
   0/1/2 and the stream's own fd, refuse E_RUNTIME if opendir itself fails; then sweep
   3..ceiling as a belt, ceiling being the finite hard RLIMIT_NOFILE or else
   _SC_OPEN_MAX, capped at 65536, never the caller's rlim_cur (R5). */
static int close_inherited_descriptors(void) {
    DIR *stream = opendir("/dev/fd");
    struct dirent *entry;
    int stream_fd;
    struct rlimit limit;
    long ceiling;
    int fd;

    if (stream == NULL) {
        return -1;
    }
    stream_fd = dirfd(stream);
    for (;;) {
        int number;
        char *end;
        errno = 0;
        entry = readdir(stream);
        if (entry == NULL) {
            if (errno != 0) {
                (void)closedir(stream);
                return -1;
            }
            break;
        }
        if (entry->d_name[0] < '0' || entry->d_name[0] > '9') {
            continue;
        }
        number = (int)strtol(entry->d_name, &end, 10);
        if (end == entry->d_name || *end != '\0') {
            continue;
        }
        if (number == 0 || number == 1 || number == 2 ||
            (stream_fd >= 0 && number == stream_fd)) {
            continue;
        }
        (void)close(number);
    }
    (void)closedir(stream);

    if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_max != RLIM_INFINITY) {
        ceiling = (limit.rlim_max > (rlim_t)YSTACK_CLOSE_RANGE_CAP)
                      ? (long)YSTACK_CLOSE_RANGE_CAP
                      : (long)limit.rlim_max;
    } else {
        long open_max = sysconf(_SC_OPEN_MAX);
        ceiling = (open_max <= 0 || open_max > YSTACK_CLOSE_RANGE_CAP)
                      ? (long)YSTACK_CLOSE_RANGE_CAP
                      : open_max;
    }
    for (fd = 3; fd < (int)ceiling; fd++) {
        (void)close(fd);
    }
    return 0;
}

/* --- step 4: signal ownership as its own reviewable block (deviation 6, new code --
   the copied launcher installs no handler at all; see spec R2, "Signals: the parent
   owns process-group termination"). `g_pgid` names the resolver's process group
   while anything in it may still be alive; `g_pre_child` names the one pre-resolver
   child running right now. Both are `volatile sig_atomic_t`, touched by main-flow
   code only under the three-signal block below, and read by the one installed
   handler with no block of its own: POSIX keeps all three signals blocked for the
   whole handler body through the mask the handler is registered with. */

static volatile sig_atomic_t g_pgid = 0;
static volatile sig_atomic_t g_pre_child = 0;

#define YSTACK_SIGNAL_TABLE_SIZE 32

/* Fills `set` with exactly SIGINT/SIGTERM/SIGHUP -- the one set every block/publish/
   reap region below blocks and every handler below is masked with. */
static void ystack_three_signals(sigset_t *set) {
    sigemptyset(set);
    sigaddset(set, SIGINT);
    sigaddset(set, SIGTERM);
    sigaddset(set, SIGHUP);
}

/* Blocks SIGINT/SIGTERM/SIGHUP, saving the previous mask in `*saved`. Opens every
   fork-publish and every tracked-reap region below. */
static int ystack_block_three(sigset_t *saved) {
    sigset_t mask;
    ystack_three_signals(&mask);
    return sigprocmask(SIG_BLOCK, &mask, saved);
}

/* Restores a mask `ystack_block_three` saved. Closes every region it opened. */
static void ystack_restore_mask(const sigset_t *saved) {
    (void)sigprocmask(SIG_SETMASK, saved, NULL);
}

/* Child-side reset shared by every fork this file performs: dispositions back to
   default first, while the inherited block is still held, then the mask restored
   last -- the fixed order spec R2 requires, so a signal already pending on the
   child cannot run the parent's inherited handler from inside the child before the
   child's own execve. SIGPIPE is included because the parent leaves it ignored
   (below) and that one disposition, unlike the other three, is inherited across
   execve. */
static void ystack_reset_child_dispositions(const sigset_t *saved) {
    struct sigaction dfl;
    memset(&dfl, 0, sizeof(dfl));
    dfl.sa_handler = SIG_DFL;
    (void)sigaction(SIGINT, &dfl, NULL);
    (void)sigaction(SIGTERM, &dfl, NULL);
    (void)sigaction(SIGHUP, &dfl, NULL);
    (void)sigaction(SIGPIPE, &dfl, NULL);
    (void)sigprocmask(SIG_SETMASK, saved, NULL);
}

/* Async-signal-safe: a table lookup, no call, and no search -- the three entries
   this parent ever registers a handler for. */
static const char *const YSTACK_SIGNAL_NAME[YSTACK_SIGNAL_TABLE_SIZE] = {
    [SIGINT] = "INT",
    [SIGTERM] = "TERM",
    [SIGHUP] = "HUP",
};

/* Async-signal-safe hand-written decimal rendering (no snprintf, per spec R2):
   writes `value`'s digits into `buffer` (capacity `capacity`) and returns the digit
   count. `value` is always non-negative here (a pid). */
static size_t ystack_render_decimal(long value, char *buffer, size_t capacity) {
    char digits[24];
    size_t count = 0U;
    unsigned long magnitude = (value < 0) ? 0UL : (unsigned long)value;
    size_t i;

    if (magnitude == 0UL) {
        digits[count++] = '0';
    } else {
        while (magnitude > 0UL && count < sizeof(digits)) {
            digits[count++] = (char)('0' + (magnitude % 10UL));
            magnitude /= 10UL;
        }
    }
    if (count > capacity) {
        count = capacity;
    }
    for (i = 0U; i < count; i++) {
        buffer[i] = digits[count - 1U - i];
    }
    return count;
}

/* The one handler this file registers for INT/TERM/HUP (spec R2). Every call in it
   is checked by name against POSIX.1-2017's async-signal-safe list (XSH 2.4.3):
   kill, waitpid, select, fcntl, write and _exit, plus memcpy in the diagnostic
   assembly below. No snprintf, malloc, free, fprintf, printf, strerror, nanosleep
   or usleep. It runs at most once in the life of the parent: every branch below
   ends in _exit, so a sibling signal held by the mask during this body is discarded
   with the process rather than delivered afterward. Never kill(0, ...) or
   kill(-0, ...): both forms would signal the caller's own process group, and there
   is no case here where that is the right thing to do -- `target` is only ever a
   pid this parent itself forked and published. */
static void ystack_terminate_handler(int sig) {
    pid_t target = 0;
    int is_group = 0;
    int reaped = 0;

    if (g_pgid != 0) {
        target = (pid_t)g_pgid;
        is_group = 1;
    } else if (g_pre_child != 0) {
        target = (pid_t)g_pre_child;
        is_group = 0;
    }

    if (target != 0) {
        int status;
        int i;
        (void)kill(is_group ? -target : target, SIGTERM);
        for (i = 0; i < 20; i++) {
            struct timeval tv;
            if (waitpid(target, &status, WNOHANG) == target) {
                reaped = 1;
                break;
            }
            tv.tv_sec = 0;
            tv.tv_usec = 50000;
            (void)select(0, NULL, NULL, NULL, &tv);
        }
        if (is_group) {
            /* Unconditional: survivors in the group are the entire reason a group
               kill exists, and the handler cannot scan the process table for them
               (not on the async-signal-safe list). */
            (void)kill(-target, SIGKILL);
            if (!reaped) {
                (void)waitpid(target, &status, 0);
            }
        } else if (!reaped) {
            (void)kill(target, SIGKILL);
            (void)waitpid(target, &status, 0);
        }
    }

    {
        char buf[64];
        size_t len = 0U;
        const char *name = (sig >= 0 && sig < YSTACK_SIGNAL_TABLE_SIZE)
                                ? YSTACK_SIGNAL_NAME[sig]
                                : NULL;
        int flags;

        if (name != NULL) {
            size_t name_len = strlen(name);
            memcpy(buf + len, "parent-signal: ", 15U);
            len += 15U;
            memcpy(buf + len, name, name_len);
            len += name_len;
            if (target != 0 && is_group) {
                memcpy(buf + len, " group ", 7U);
                len += 7U;
                len += ystack_render_decimal((long)target, buf + len,
                                             sizeof(buf) - len - 1U);
            } else {
                memcpy(buf + len, " no-runtime", 11U);
                len += 11U;
            }
            buf[len++] = '\n';
        }

        flags = fcntl(STDERR_FILENO, F_GETFL, 0);
        if (flags != -1) {
            (void)fcntl(STDERR_FILENO, F_SETFL, flags | O_NONBLOCK);
        }
        if (name != NULL) {
            (void)write(STDERR_FILENO, buf, len);
        }
        if (flags != -1) {
            (void)fcntl(STDERR_FILENO, F_SETFL, flags);
        }
    }

    _exit(128 + sig);
}

/* Registers the three handlers as the first statements of main (after umask(077),
   spec R5/R2) and ignores SIGPIPE beside them. Each handler's mask covers all three
   signals, not only the one delivered, so a sibling signal that arrives mid-handler
   is held rather than run; neither SA_RESTART nor SA_SIGINFO is set. */
static int ystack_install_signal_handlers(void) {
    struct sigaction action;
    struct sigaction ignore_action;
    sigset_t mask;

    ystack_three_signals(&mask);
    memset(&action, 0, sizeof(action));
    action.sa_handler = ystack_terminate_handler;
    action.sa_mask = mask;
    action.sa_flags = 0;
    if (sigaction(SIGINT, &action, NULL) != 0 ||
        sigaction(SIGTERM, &action, NULL) != 0 ||
        sigaction(SIGHUP, &action, NULL) != 0) {
        return -1;
    }
    memset(&ignore_action, 0, sizeof(ignore_action));
    ignore_action.sa_handler = SIG_IGN;
    if (sigaction(SIGPIPE, &ignore_action, NULL) != 0) {
        return -1;
    }
    return 0;
}

/* R7: the fixed envp every pre-resolver child runs under -- never the caller's
   environ, on any exec this file performs before the resolver's own. */
static char *const FIXED_CHILD_ENVP[3] = {
    (char *)"PATH=/usr/bin:/bin", (char *)"LC_ALL=C", NULL
};

/* Forks program under FIXED_CHILD_ENVP, writes `input` to its stdin (closing to signal
   EOF), reads its whole stdout into `output` (refusing on overflow), and waits for it.
   Every one of the ten pre-resolver children in this file goes through here, so step 4
   has one place to add the block/publish/reap region (deviation 6). */
static int run_pinned_child(const char *program, char *const argv[],
                            const unsigned char *input, size_t input_length,
                            char *output, size_t output_capacity, size_t *output_length) {
    int in_pipe[2];
    int out_pipe[2];
    pid_t child;
    int status = 0;
    int write_failed = 0;
    int read_failed = 0;
    size_t total = 0U;

    if (pipe(in_pipe) != 0) {
        return -1;
    }
    if (pipe(out_pipe) != 0) {
        (void)close(in_pipe[0]);
        (void)close(in_pipe[1]);
        return -1;
    }
    /* deviation 6: this fork and its reap below are one of the ten pre-resolver
       children the block/publish/reap region wraps (spec R2) -- block, fork, then
       in the parent publish `g_pre_child` and restore before anything else runs;
       in the child reset dispositions and restore the mask before the exec. */
    {
        sigset_t saved;
        (void)ystack_block_three(&saved);
        child = fork();
        if (child < 0) {
            ystack_restore_mask(&saved);
            (void)close(in_pipe[0]);
            (void)close(in_pipe[1]);
            (void)close(out_pipe[0]);
            (void)close(out_pipe[1]);
            return -1;
        }
        if (child == 0) {
            ystack_reset_child_dispositions(&saved);
            if (dup2(in_pipe[0], STDIN_FILENO) < 0 ||
                dup2(out_pipe[1], STDOUT_FILENO) < 0) {
                _exit(127);
            }
            (void)close(in_pipe[0]);
            (void)close(in_pipe[1]);
            (void)close(out_pipe[0]);
            (void)close(out_pipe[1]);
            execve(program, argv, FIXED_CHILD_ENVP);
            _exit(127);
        }
        g_pre_child = child;
        ystack_restore_mask(&saved);
    }
    (void)close(in_pipe[0]);
    (void)close(out_pipe[1]);
    if (input_length > 0U &&
        write_all(in_pipe[1], (const char *)input, input_length) != 0) {
        write_failed = 1;
    }
    (void)close(in_pipe[1]);
    for (;;) {
        char buffer[4096];
        ssize_t count = read(out_pipe[0], buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count < 0) {
            read_failed = 1;
            break;
        }
        if (count == 0) {
            break;
        }
        if (total + (size_t)count <= output_capacity) {
            memcpy(output + total, buffer, (size_t)count);
        } else {
            read_failed = 1;
        }
        total += (size_t)count;
    }
    (void)close(out_pipe[0]);
    /* deviation 6: block, reap, zero `g_pre_child`, restore -- the id is never left
       readable as a process this parent has already given back to the kernel. */
    {
        sigset_t saved;
        (void)ystack_block_three(&saved);
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
        }
        g_pre_child = 0;
        ystack_restore_mask(&saved);
    }
    if (write_failed || read_failed || total > output_capacity ||
        !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        return -1;
    }
    *output_length = total;
    return 0;
}

/* Compares the first whitespace-delimited token of `buffer` against `pinned`. */
static int first_token_equals(const char *buffer, size_t length,
                              const char *pinned, size_t pinned_length) {
    size_t token_length = 0U;
    while (token_length < length && buffer[token_length] != ' ' &&
           buffer[token_length] != '\t' && buffer[token_length] != '\n') {
        token_length++;
    }
    return token_length == pinned_length &&
           memcmp(buffer, pinned, pinned_length) == 0;
}

#if defined(__APPLE__)
static const char *const SHA1_PROGRAM = "/usr/bin/shasum";
static char *const SHA1_ARGV[] = {
    (char *)"/usr/bin/shasum", (char *)"-a", (char *)"1", NULL
};
static const char *const SHA256_PROGRAM = "/usr/bin/shasum";
static char *const SHA256_ARGV[] = {
    (char *)"/usr/bin/shasum", (char *)"-a", (char *)"256", NULL
};
static const char *const BOUND_JQ_SHA256 =
    "5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef";
#else
static const char *const SHA1_PROGRAM = "/usr/bin/sha1sum";
static char *const SHA1_ARGV[] = { (char *)"/usr/bin/sha1sum", NULL };
static const char *const SHA256_PROGRAM = "/usr/bin/sha256sum";
static char *const SHA256_ARGV[] = { (char *)"/usr/bin/sha256sum", NULL };
static const char *const BOUND_JQ_SHA256 =
    "af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44";
#endif

/* R5's parent-pinned set of eight files -- the runtime file (argv[2] itself), the
   library it sources, the resolver jq program, and the five jq modules under the
   pinned generation's modules/ -- each pinned to its git blob id, computed the way
   R5 requires (SHA-1 over "blob <size>\0" then the bytes, no git). Pinned at
   origin/main 7c0263728fe6b3d104dc088d0d9f6242472729d4, verified against
   `git hash-object` on each path at that commit. */
static const char *const PARENT_PIN_BLOB_HEX[YSTACK_PARENT_PIN_COUNT] = {
    "54e174128a9f2f1a13ea17794d54696698b72eec", /* resolver/v1/profile-resolve-runtime.sh (argv[2]) */
    "4cb098be3de6bc00406315a8944d54b17231e98c", /* scripts/lib/profile-resolution.sh */
    "9004cb7bd38fc165d8b1414786a520af23cfb9b3", /* resolver/v1/profile-resolution.jq */
    "e2bc03a2b6d1ed1119ffd794981b06c6f59f46f8", /* core/.../modules/schema.jq */
    "e3633b25b890ce68024fba682f0f50606429f020", /* core/.../modules/profile_graph.jq */
    "aff5cf1b87efac8cb95918ec5dc240a055277f52", /* core/.../modules/stage_request.jq */
    "cfc3ed3b1c3d714412a6dffc85accaabb98cf3df", /* core/.../modules/result_facts.jq */
    "6af6f42d9afb073fbc892646fe9cd899f7057700", /* core/.../modules/result_truth.jq */
};

/* The parent's own copies of the library's generation and schema-major constants
   (scripts/lib/profile-resolution.sh:5,11), equal to the accepted, pinned
   scripts/core-contract.sh's PORTABLE_CORE_GENERATION (R5). Not read from the
   library at run time -- a stale copy is caught by the library's own blob pin above. */
static const char *const PARENT_CORE_GENERATION =
    "g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43";
static const char *const PARENT_SCHEMA_MAJOR = "2";
static const char *const PARENT_MODULE_NAMES[5] = {
    "schema", "profile_graph", "stage_request", "result_facts", "result_truth"
};

/* The runtime's own repository-root rule, "${dir%/resolver/v1}"
   (resolver/v1/profile-resolve-runtime.sh:9-10), applied to argv[2]'s directory. */
static int repo_root_from_runtime(const char *runtime_path, char *buffer,
                                  size_t buffer_size) {
    static const char SUFFIX[] = "/resolver/v1";
    size_t suffix_length = sizeof(SUFFIX) - 1U;
    const char *slash = strrchr(runtime_path, '/');
    size_t dir_length;
    if (slash == NULL) {
        return -1;
    }
    dir_length = (size_t)(slash - runtime_path);
    if (dir_length >= buffer_size) {
        return -1;
    }
    memcpy(buffer, runtime_path, dir_length);
    buffer[dir_length] = '\0';
    if (dir_length >= suffix_length &&
        strcmp(buffer + (dir_length - suffix_length), SUFFIX) == 0) {
        buffer[dir_length - suffix_length] = '\0';
    }
    return 0;
}

static int build_pin_path(size_t index, const char *repo_root,
                          const char *runtime_path, char *buffer,
                          size_t buffer_size) {
    int written;
    if (index == 0U) {
        written = snprintf(buffer, buffer_size, "%s", runtime_path);
    } else if (index == 1U) {
        written = snprintf(buffer, buffer_size,
                           "%s/scripts/lib/profile-resolution.sh", repo_root);
    } else if (index == 2U) {
        written = snprintf(buffer, buffer_size,
                           "%s/resolver/v1/profile-resolution.jq", repo_root);
    } else {
        written = snprintf(buffer, buffer_size,
                           "%s/core/v%s/generations/%s/modules/%s.jq", repo_root,
                           PARENT_SCHEMA_MAJOR, PARENT_CORE_GENERATION,
                           PARENT_MODULE_NAMES[index - 3U]);
    }
    return (written > 0 && (size_t)written < buffer_size) ? 0 : -1;
}

/* R5/R7: git blob id of the file at `path` against `pinned_hex`, computed by the
   parent itself -- fstat for the size, then the header and the bytes written to the
   platform SHA-1 tool's stdin, never git. */
static int check_blob_pin(const char *path, const char *pinned_hex) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    struct stat state;
    unsigned char *combined;
    size_t header_length;
    size_t total;
    char header[64];
    char digest[256];
    size_t digest_length = 0U;
    int ok;

    if (fd < 0 || fstat(fd, &state) != 0 || !S_ISREG(state.st_mode)) {
        if (fd >= 0) {
            (void)close(fd);
        }
        return -1;
    }
    total = (size_t)state.st_size;
    {
        int header_written =
            snprintf(header, sizeof(header), "blob %zu", total);
        if (header_written < 0 || (size_t)header_written >= sizeof(header)) {
            (void)close(fd);
            return -1;
        }
        header_length = (size_t)header_written;
    }
    combined = malloc(header_length + 1U + total);
    if (combined == NULL) {
        (void)close(fd);
        return -1;
    }
    memcpy(combined, header, header_length);
    combined[header_length] = '\0';
    {
        size_t offset = 0U;
        while (offset < total) {
            ssize_t count =
                read(fd, combined + header_length + 1U + offset, total - offset);
            if (count < 0 && errno == EINTR) {
                continue;
            }
            if (count <= 0) {
                (void)close(fd);
                free(combined);
                return -1;
            }
            offset += (size_t)count;
        }
    }
    (void)close(fd);
    ok = run_pinned_child(SHA1_PROGRAM, SHA1_ARGV, combined,
                          header_length + 1U + total, digest, sizeof(digest),
                          &digest_length) == 0 &&
         first_token_equals(digest, digest_length, pinned_hex, strlen(pinned_hex));
    free(combined);
    return ok ? 0 : -1;
}

/* R5/R7: SHA-256 of the bound jq against this platform's pin, same mechanism as
   check_blob_pin but with no "blob <size>\0" header -- a plain file digest. */
static int check_jq_sha256(const char *jq_path) {
    int fd = open(jq_path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    struct stat state;
    unsigned char *bytes;
    size_t total;
    char digest[256];
    size_t digest_length = 0U;
    int ok;

    if (fd < 0 || fstat(fd, &state) != 0 || !S_ISREG(state.st_mode)) {
        if (fd >= 0) {
            (void)close(fd);
        }
        return -1;
    }
    total = (size_t)state.st_size;
    bytes = malloc(total > 0U ? total : 1U);
    if (bytes == NULL) {
        (void)close(fd);
        return -1;
    }
    {
        size_t offset = 0U;
        while (offset < total) {
            ssize_t count = read(fd, bytes + offset, total - offset);
            if (count < 0 && errno == EINTR) {
                continue;
            }
            if (count <= 0) {
                (void)close(fd);
                free(bytes);
                return -1;
            }
            offset += (size_t)count;
        }
    }
    (void)close(fd);
    ok = run_pinned_child(SHA256_PROGRAM, SHA256_ARGV, bytes, total, digest,
                          sizeof(digest), &digest_length) == 0 &&
         first_token_equals(digest, digest_length, BOUND_JQ_SHA256,
                            strlen(BOUND_JQ_SHA256));
    free(bytes);
    return ok ? 0 : -1;
}

/* R5/R7: the jq --version probe, under the same fixed envp as every other
   pre-resolver child (R7); no download, no PATH search. */
static int check_jq_version(const char *jq_path) {
    char *const probe_argv[3] = { (char *)jq_path, (char *)"--version", NULL };
    char output[64];
    size_t output_length = 0U;
    size_t trimmed;
    if (run_pinned_child(jq_path, probe_argv, NULL, 0U, output, sizeof(output),
                         &output_length) != 0) {
        return -1;
    }
    trimmed = output_length;
    if (trimmed > 0U && output[trimmed - 1U] == '\n') {
        trimmed--;
    }
    return (trimmed == strlen("jq-1.6") &&
            memcmp(output, "jq-1.6", trimmed) == 0)
               ? 0
               : -1;
}

#if defined(__linux__)
/* R5: on Linux, .run/awk must be byte-identical to /usr/bin/awk, following that
   platform path's own symlinks (Debian/Ubuntu route it through
   /etc/alternatives); .run/awk itself keeps its O_NOFOLLOW. */
static int check_run_directory_awk(int run_fd) {
    int copy_fd = openat(run_fd, "awk", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    int system_fd = -1;
    struct stat copy_state;
    struct stat system_state;
    int ok = -1;

    if (copy_fd < 0 || fstat(copy_fd, &copy_state) != 0 ||
        !S_ISREG(copy_state.st_mode) || copy_state.st_uid != geteuid() ||
        (copy_state.st_mode & 07777U) != 0500U) {
        if (copy_fd >= 0) {
            (void)close(copy_fd);
        }
        return -1;
    }
    system_fd = open("/usr/bin/awk", O_RDONLY | O_CLOEXEC);
    if (system_fd < 0 || fstat(system_fd, &system_state) != 0 ||
        !S_ISREG(system_state.st_mode) ||
        copy_state.st_size != system_state.st_size) {
        (void)close(copy_fd);
        if (system_fd >= 0) {
            (void)close(system_fd);
        }
        return -1;
    }
    {
        char buffer_a[8192];
        char buffer_b[8192];
        ok = 0;
        for (;;) {
            ssize_t read_a = read(copy_fd, buffer_a, sizeof(buffer_a));
            size_t filled_b = 0U;
            if (read_a < 0 && errno == EINTR) {
                continue;
            }
            if (read_a < 0) {
                ok = -1;
                break;
            }
            if (read_a == 0) {
                break;
            }
            while (filled_b < (size_t)read_a) {
                ssize_t read_b = read(system_fd, buffer_b + filled_b,
                                      (size_t)read_a - filled_b);
                if (read_b < 0 && errno == EINTR) {
                    continue;
                }
                if (read_b <= 0) {
                    ok = -1;
                    break;
                }
                filled_b += (size_t)read_b;
            }
            if (ok != 0) {
                break;
            }
            if (memcmp(buffer_a, buffer_b, (size_t)read_a) != 0) {
                ok = -1;
                break;
            }
        }
    }
    (void)close(copy_fd);
    (void)close(system_fd);
    return ok;
}
#else
/* R5: on Darwin, .run/awk must equal the exact 35-byte two-line shim the entry
   writes -- held here as a constant, so neither shipped file opens the host awk. */
static const char DARWIN_AWK_SHIM[] = "#!/bin/bash\nexec /usr/bin/awk \"$@\"\n";

static int check_run_directory_awk(int run_fd) {
    int copy_fd = openat(run_fd, "awk", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat copy_state;
    char buffer[YSTACK_DARWIN_AWK_SHIM_LENGTH];
    size_t total = 0U;

    if (copy_fd < 0 || fstat(copy_fd, &copy_state) != 0 ||
        !S_ISREG(copy_state.st_mode) || copy_state.st_uid != geteuid() ||
        (copy_state.st_mode & 07777U) != 0500U ||
        copy_state.st_size != (off_t)YSTACK_DARWIN_AWK_SHIM_LENGTH) {
        if (copy_fd >= 0) {
            (void)close(copy_fd);
        }
        return -1;
    }
    while (total < YSTACK_DARWIN_AWK_SHIM_LENGTH) {
        ssize_t count = read(copy_fd, buffer + total,
                             YSTACK_DARWIN_AWK_SHIM_LENGTH - total);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            (void)close(copy_fd);
            return -1;
        }
        total += (size_t)count;
    }
    (void)close(copy_fd);
    return memcmp(buffer, DARWIN_AWK_SHIM, YSTACK_DARWIN_AWK_SHIM_LENGTH) == 0
              ? 0
              : -1;
}
#endif

/* Lists a directory's entries (skipping "." and "..") through fdopendir on a dup of
   `fd`, so `fd` itself stays open for the caller (R5's fdopendir(dup(fd)) discipline). */
struct ystack_dir_listing {
    char names[YSTACK_DIR_ENTRY_MAX][YSTACK_DIR_NAME_MAX];
    size_t count;
};

static int list_directory(int fd, struct ystack_dir_listing *list) {
    int dup_fd = dup(fd);
    DIR *stream;
    struct dirent *entry;
    list->count = 0U;
    if (dup_fd < 0) {
        return -1;
    }
    stream = fdopendir(dup_fd);
    if (stream == NULL) {
        (void)close(dup_fd);
        return -1;
    }
    for (;;) {
        errno = 0;
        entry = readdir(stream);
        if (entry == NULL) {
            if (errno != 0) {
                (void)closedir(stream);
                return -1;
            }
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        if (list->count >= YSTACK_DIR_ENTRY_MAX ||
            strlen(entry->d_name) >= YSTACK_DIR_NAME_MAX) {
            (void)closedir(stream);
            return -1;
        }
        strcpy(list->names[list->count], entry->d_name);
        list->count++;
    }
    (void)closedir(stream);
    return 0;
}

/* True iff `list` holds exactly `required_count` entries and each one matches a
   distinct name in `required` -- a duplicate in `required` (a basename collision
   with one of the fixed reserved names) can then never be fully matched. */
static int list_contains_only(const struct ystack_dir_listing *list,
                              const char *const *required,
                              size_t required_count) {
    unsigned matched_mask = 0U;
    size_t i;
    size_t j;
    if (list->count != required_count || required_count > (8U * sizeof(unsigned))) {
        return 0;
    }
    for (i = 0U; i < list->count; i++) {
        int found = 0;
        for (j = 0U; j < required_count; j++) {
            if ((matched_mask & (1U << j)) == 0U &&
                strcmp(list->names[i], required[j]) == 0) {
                matched_mask |= (1U << j);
                found = 1;
                break;
            }
        }
        if (!found) {
            return 0;
        }
    }
    return matched_mask == ((required_count == 0U)
                                ? 0U
                                : ((1U << required_count) - 1U));
}

/* deviation 7 (continued): supervise() takes the checked output-directory descriptor
   in place of a sandbox path string, creates child.stdout/child.stderr with
   openat(..., O_CREAT|O_EXCL|O_NOFOLLOW) relative to it (0600, O_RDWR so the parent
   can read them back through the same descriptor), and keeps both descriptors open
   for the life of the run instead of closing them right after fork the way
   portable-profile-resolution-launcher.c:483-484 does -- the copied code re-opened
   by path afterward, which this deviation removes everywhere. Adapted rather than
   copied; no copy-begin/copy-end wraps this function, only the two small pieces
   inside it noted below that are still byte-identical to the source. */
static int supervise(int output_fd, const char *program, char *const child_argv[],
                     char *const child_env[]) {
    int stdout_fd = -1;
    int stderr_fd = -1;
    pid_t child;
    int status = 0;
    int result;
    enum stop_reason stopped = STOP_NONE;
    unsigned memory_scan_failures = 0U;
    time_t started;
    struct timespec interval = {0, 10000000L};
    /* deviation 6: set when the poll loop's own reap has already blocked the three
       signals and is carrying that block into the cleanup below it (spec R2's
       "the blocked region ... runs on through the survivor check and through any
       kill of the surviving group"). */
    sigset_t reap_saved;
    int reap_mask_held = 0;

    stdout_fd = openat(output_fd, "child.stdout",
                       O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    stderr_fd = openat(output_fd, "child.stderr",
                       O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (stdout_fd < 0 || stderr_fd < 0 || monotonic_seconds(&started) != 0) {
        if (stdout_fd >= 0) {
            (void)close(stdout_fd);
        }
        if (stderr_fd >= 0) {
            (void)close(stderr_fd);
        }
        fputs("E_RUNTIME unexpected\n", stderr);
        return 70;
    }
    /* deviation 6: block before the fork, publish `g_pgid` only once setpgid has
       been tried and the child is known, restore before anything else in this
       function can run (spec R2). The setpgid-failure kill/reap below sits inside
       this same block, before `g_pgid` is ever assigned, so it reaps under a block
       already held and leaves `g_pgid` at 0. */
    {
        sigset_t saved;
        (void)ystack_block_three(&saved);
        child = fork();
        if (child < 0) {
            ystack_restore_mask(&saved);
            (void)close(stdout_fd);
            (void)close(stderr_fd);
            fputs("E_RUNTIME unexpected\n", stderr);
            return 70;
        }
        if (child == 0) {
            ystack_reset_child_dispositions(&saved);
            if (setpgid(0, 0) != 0 || dup2(stdout_fd, STDOUT_FILENO) < 0 ||
                dup2(stderr_fd, STDERR_FILENO) < 0 || close(stdout_fd) != 0 ||
                close(stderr_fd) != 0 || apply_child_limits() != 0) {
                _exit(75);
            }
            /* deviation 2 (resolver-child half): close every inherited descriptor
               above 2 here, before execve, the same way main()'s startup close does
               it (R3/R5) -- under the block this whole region holds until the
               restore above already ran in this child. */
            if (close_inherited_descriptors() != 0) {
                _exit(75);
            }
            execve(program, child_argv, child_env);
            _exit(70);
        }
        if (setpgid(child, child) != 0 && errno != EACCES && errno != ESRCH) {
            (void)kill(child, SIGKILL);
            (void)waitpid(child, &status, 0);
            ystack_restore_mask(&saved);
            (void)close(stdout_fd);
            (void)close(stderr_fd);
            fputs("E_RUNTIME unexpected\n", stderr);
            return 70;
        }
        g_pgid = child;
        ystack_restore_mask(&saved);
    }
    /* deviation 9: the runtime-pgid diagnostic sits outside the block above (a
       write that can block must never share a region with the fork it is reporting
       on -- spec R2) and under its own short three-signal block, after the restore
       and before the poll loop starts. */
    {
        sigset_t saved;
        char buf[48];
        int len;
        int flags;

        len = snprintf(buf, sizeof(buf), "runtime-pgid: %ld\n", (long)child);
        if (len < 0) {
            len = 0;
        } else if ((size_t)len > sizeof(buf)) {
            len = (int)sizeof(buf);
        }
        (void)ystack_block_three(&saved);
        flags = fcntl(STDERR_FILENO, F_GETFL, 0);
        if (flags != -1) {
            (void)fcntl(STDERR_FILENO, F_SETFL, flags | O_NONBLOCK);
        }
        (void)write(STDERR_FILENO, buf, (size_t)len);
        if (flags != -1) {
            (void)fcntl(STDERR_FILENO, F_SETFL, flags);
        }
        ystack_restore_mask(&saved);
    }
    /* Adapted from scripts/test/portable-profile-resolution-launcher.c:456-489 at
       f4de7e48c688b6adb3669f69a221d2aa7bf43b15 (deviation 6): the four checks below
       and the nanosleep are unchanged, but the reap itself now runs blocked, and
       the block stays held through the survivor check the moment this loop actually
       reaps the child (spec R2) -- copy-begin/copy-end no longer applies to this
       loop, the way it already does not apply to the rest of this function (see the
       note above supervise()). */
    for (;;) {
        sigset_t poll_saved;
        pid_t observed;
        time_t now;

        (void)ystack_block_three(&poll_saved);
        observed = waitpid(child, &status, WNOHANG);
        if (observed == child) {
            if (process_group_count(child) > 0U) {
                stopped = STOP_PROCESS;
            }
            reap_saved = poll_saved;
            reap_mask_held = 1;
            break;
        }
        ystack_restore_mask(&poll_saved);
        if (observed < 0 && errno != EINTR) {
            stopped = STOP_PROCESS;
            break;
        }
        if (process_group_count(child) > PROCESS_LIMIT) {
            stopped = STOP_PROCESS;
            break;
        }
        {
            int memory_state = process_group_address_space_exceeded(child);
            if (memory_state > 0 ||
                (memory_state < 0 && ++memory_scan_failures >= 3U)) {
                stopped = STOP_MEMORY;
                break;
            }
            if (memory_state == 0) {
                memory_scan_failures = 0U;
            }
        }
        if (monotonic_seconds(&now) != 0 || now - started >= INVOCATION_SECONDS) {
            stopped = STOP_TIME;
            break;
        }
        (void)nanosleep(&interval, NULL);
    }
    if (stopped != STOP_NONE) {
        /* deviation 6: the limit path is blocked the same way the reap path is, so
           the two cannot drift -- reuse the block the loop already holds if this
           break came from the reap-with-survivors case, else open a fresh one. */
        sigset_t cleanup_saved;
        if (reap_mask_held) {
            cleanup_saved = reap_saved;
        } else {
            (void)ystack_block_three(&cleanup_saved);
        }
        (void)kill(-child, SIGKILL);
        (void)kill(child, SIGKILL);
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
        }
        g_pgid = 0;
        ystack_restore_mask(&cleanup_saved);
        (void)close(stdout_fd);
        (void)close(stderr_fd);
        if (stopped == STOP_TIME) {
            fputs("E_LIMIT time-limit\n", stderr);
        } else if (stopped == STOP_PROCESS) {
            fputs("E_LIMIT process-limit\n", stderr);
        } else {
            fputs("E_LIMIT resource-limit\n", stderr);
        }
        return 75;
    }
    /* deviation 6: stopped == STOP_NONE means the loop's own reap found no
       survivors -- clear `g_pgid` and restore the mask the loop is still holding
       (spec R2: "pgid is cleared last of all", after the survivor check finds
       nothing left to kill). */
    g_pgid = 0;
    ystack_restore_mask(&reap_saved);
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0 &&
        empty_regular_file(stderr_fd)) {
        result = stream_file(stdout_fd, STDOUT_FILENO);
        (void)close(stdout_fd);
        (void)close(stderr_fd);
        if (result != 0) {
            fputs("E_RUNTIME unexpected\n", stderr);
            return 70;
        }
        return 0;
    }
    if (WIFSIGNALED(status) &&
        (WTERMSIG(status) == SIGXCPU || WTERMSIG(status) == SIGXFSZ ||
         WTERMSIG(status) == SIGKILL)) {
        (void)close(stdout_fd);
        (void)close(stderr_fd);
        fputs("E_LIMIT resource-limit\n", stderr);
        return 75;
    }
    if (empty_regular_file(stdout_fd) && sanitized_error(stderr_fd)) {
        result = WIFEXITED(status) ? WEXITSTATUS(status) : 75;
        (void)close(stdout_fd);
        (void)close(stderr_fd);
        return result;
    }
    if (WIFEXITED(status) && WEXITSTATUS(status) == 75 &&
        empty_regular_file(stderr_fd)) {
        (void)close(stdout_fd);
        (void)close(stderr_fd);
        fputs("E_LIMIT resource-limit\n", stderr);
        return 75;
    }
    if (!empty_regular_file(stdout_fd)) {
        (void)close(stdout_fd);
        (void)close(stderr_fd);
        fputs("E_RUNTIME unexpected\n", stderr);
        return 70;
    }
    (void)close(stdout_fd);
    (void)close(stderr_fd);
    fputs("E_RUNTIME unexpected\n", stderr);
    return 70;
}

/* copy-begin scripts/test/portable-profile-resolution-launcher.c:534-541 at f4de7e48c688b6adb3669f69a221d2aa7bf43b15 */
int main(int argc, char **argv) {
    char *child_argv[6];
    char *child_env[12];
    char home[PATH_MAX];
    char temp[PATH_MAX];
    char tool_path[PATH_MAX];
    char path_value[PATH_MAX + 32];
    char *slash;
/* copy-end */
    /* deviation 3/4/7: `sandbox` (a path string) is replaced by `out_fd`, the
       checked output-directory descriptor everything from here on is relative to
       (R5/R7); declared here rather than inside the check block below because it
       must live through to the final supervise() call. run_fd/run_state (opened on
       the run-directory argument, argv[8]) outlive their own check block too, since
       the helper/binary/jq/awk/pin checks that follow all read through run_fd. */
    int out_fd = -1;
    int run_fd = -1;
    struct stat run_state;
    /* removed: scripts/test/portable-profile-resolution-launcher.c:543-544
       (remove_helper, git_wall_test) -- test-only state for the argv modes stripped
       below (plan step 2: "Remove test modes 547-631, both test variables 686-689"). */
/* copy-begin scripts/test/portable-profile-resolution-launcher.c:545 at f4de7e48c688b6adb3669f69a221d2aa7bf43b15 */
    size_t child_env_count = 8U;
/* copy-end */

    /* deviation 10: umask(077) before any check or creation (R5). The copied launcher
       has no umask call anywhere in its 702 lines -- the test harness set one for the
       whole suite instead (portable-profile-resolution.test.sh:5). */
    umask(077);

    /* deviation 6: register the INT/TERM/HUP handlers and ignore SIGPIPE among
       main's first statements, per R5's "after umask(077) and after the handler
       registrations, before the first pin, the first fork and the first creation" --
       and before R2's own statement that the window in which a signal still finds
       the default disposition should be as small as a process start. */
    if (ystack_install_signal_handlers() != 0) {
        fputs("E_RUNTIME unexpected\n", stderr);
        return 70;
    }

    /* deviation 2 (startup half): close every inherited descriptor above 2 before any
       check, pin or fork (R5). The matching resolver-child close before execve (the
       other half of this deviation, inside supervise()'s fork branch) is handled
       there under the block/publish/reap region deviation 6 wraps around that
       fork. */
    if (close_inherited_descriptors() != 0) {
        fputs("E_RUNTIME unexpected\n", stderr);
        return 70;
    }

    /*
     * removed: scripts/test/portable-profile-resolution-launcher.c:547-631 -- the
     * trap-child / limit-child / limit-control / loader-control argv modes are test-only
     * scaffolding for exercising supervise()'s limits directly (plan step 2: "Remove
     * test modes 547-631").
     */

    /* adapted from scripts/test/portable-profile-resolution-launcher.c:632-639 at
       f4de7e48c688b6adb3669f69a221d2aa7bf43b15 -- the remove_helper/git_wall_test
       disjuncts are gone with the argv modes removed above, and argc widens to 9 for the
       real parent's <resolve> <runtime> <helper> <jq> <request> <map> <output> <run>
       shape (plan step 2: "the internal parent argument positions derived from the
       copied launch: resolve, runtime, helper, bound jq, request, map, followed by
       output and run directory"). Request/map keep only the copied leading-slash shape
       check here (portable-profile-resolution-launcher.c:636); their regular/non-symlink
       refinement (deviation 5) moved out of this E_USAGE bucket in step 3 -- see below --
       because R5 lists it as an E_RUNTIME refusal and R10's group-2 cases assert exactly
       that on stderr, not E_USAGE. */
    if (argc != 9 || strcmp(argv[1], "resolve") != 0 ||
        !regular_absolute(argv[2], 0) || !regular_absolute(argv[3], 1) ||
        !regular_absolute(argv[4], 1) ||
        argv[5][0] != '/' || argv[6][0] != '/' ||
        argv[7][0] != '/' || argv[8][0] != '/') {
        fputs("E_USAGE\n", stderr);
        return 64;
    }

    /* deviation 1: runtime (argv[2]) additionally needs an exact mode-0644 check (R5).
       The E_USAGE branch above stays for malformed invocation; a mode mismatch on an
       otherwise well-formed invocation is E_RUNTIME, per the copied binding failures
       below. */
    {
        struct stat runtime_state;
        if (stat(argv[2], &runtime_state) != 0 ||
            (runtime_state.st_mode & 07777U) != 0644U) {
            fputs("E_RUNTIME binding\n", stderr);
            return 70;
        }
    }

    /* deviation 5 (moved here in step 3, see the note above): request/map must be
       absolute regular non-symlink files -- an E_RUNTIME refusal on an otherwise
       well-formed (E_USAGE-clean) invocation, per R5 and R10's group-2 cases for a
       non-absolute or symlinked request/map. */
    if (!regular_absolute(argv[5], 0) || !regular_absolute(argv[6], 0)) {
        fputs("E_RUNTIME binding\n", stderr);
        return 70;
    }

    /* R5, in its fixed order: output path-length guard; opened output owner/mode/
       listing and .run identity by descriptor; run-directory mode, its exact entry
       set, the helper and compiled-parent checks, jq identity and .run/awk, all
       against that same run-directory descriptor; the eight parent-pinned blob ids;
       the jq SHA-256 and jq-1.6 checks. Only once every one of those has passed does
       the parent create anything (deviation 7's fd-relative home/tmp, below). */

    /* deviation 3: the length guard on the output path runs before anything else in
       this block, so an overlong output path is refused without the parent even
       looking for .run (R5). */
    if (strlen(argv[7]) > PATH_MAX - 16) {
        fputs("E_RUNTIME binding\n", stderr);
        return 70;
    }

    /* deviation 4: output directory, opened and checked by descriptor -- owner,
       mode 0700, and its entry set is exactly {".run"} -- then .run's own identity
       proved against the run-directory argument by st_dev/st_ino on descriptors
       neither one lets a symlink resolve through (R5). */
    {
        struct stat out_state;
        struct stat run_state_via_output;
        int run_fd_via_output;
        struct ystack_dir_listing output_listing;
        static const char *const OUTPUT_REQUIRED[1] = { ".run" };

        out_fd = open(argv[7], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (out_fd < 0 || fstat(out_fd, &out_state) != 0 ||
            !S_ISDIR(out_state.st_mode) || out_state.st_uid != geteuid() ||
            (out_state.st_mode & 07777U) != 0700U) {
            if (out_fd >= 0) {
                (void)close(out_fd);
            }
            fputs("E_RUNTIME output\n", stderr);
            return 70;
        }
        if (list_directory(out_fd, &output_listing) != 0 ||
            !list_contains_only(&output_listing, OUTPUT_REQUIRED, 1U)) {
            (void)close(out_fd);
            fputs("E_RUNTIME output\n", stderr);
            return 70;
        }
        if (fstatat(out_fd, ".run", &run_state_via_output, AT_SYMLINK_NOFOLLOW) != 0 ||
            !S_ISDIR(run_state_via_output.st_mode)) {
            (void)close(out_fd);
            fputs("E_RUNTIME output\n", stderr);
            return 70;
        }
        run_fd_via_output =
            openat(out_fd, ".run", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        run_fd = open(argv[8], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (run_fd_via_output < 0 || run_fd < 0 ||
            fstat(run_fd_via_output, &run_state_via_output) != 0 ||
            fstat(run_fd, &run_state) != 0 ||
            run_state_via_output.st_dev != run_state.st_dev ||
            run_state_via_output.st_ino != run_state.st_ino) {
            if (run_fd_via_output >= 0) {
                (void)close(run_fd_via_output);
            }
            if (run_fd >= 0) {
                (void)close(run_fd);
            }
            (void)close(out_fd);
            fputs("E_RUNTIME output\n", stderr);
            return 70;
        }
        /* .run's identity is proved; later checks use run_fd (opened on the
           run-directory argument), per R5. */
        (void)close(run_fd_via_output);
    }

    /* R5: the run directory itself -- caller-owned, mode exactly 0500. */
    if (!S_ISDIR(run_state.st_mode) || run_state.st_uid != geteuid() ||
        (run_state.st_mode & 07777U) != 0500U) {
        (void)close(run_fd);
        (void)close(out_fd);
        fputs("E_RUNTIME run-directory\n", stderr);
        return 70;
    }

    /* R5: the run directory's entry set is exactly {trusted-launch, <helper
       basename>, jq, awk} -- a missing name, an extra entry, or a basename
       collision with one of the three fixed names all refuse via
       list_contains_only's exact-match requirement. */
    {
        const char *helper_basename = strrchr(argv[3], '/');
        char helper_basename_storage[YSTACK_DIR_NAME_MAX];
        const char *run_required[4];
        struct ystack_dir_listing run_listing;

        helper_basename = (helper_basename != NULL) ? helper_basename + 1 : argv[3];
        if (strlen(helper_basename) >= sizeof(helper_basename_storage)) {
            (void)close(run_fd);
            (void)close(out_fd);
            fputs("E_RUNTIME run-directory\n", stderr);
            return 70;
        }
        strcpy(helper_basename_storage, helper_basename);
        run_required[0] = "trusted-launch";
        run_required[1] = helper_basename_storage;
        run_required[2] = "jq";
        run_required[3] = "awk";
        if (list_directory(run_fd, &run_listing) != 0 ||
            !list_contains_only(&run_listing, run_required, 4U)) {
            (void)close(run_fd);
            (void)close(out_fd);
            fputs("E_RUNTIME run-directory\n", stderr);
            return 70;
        }

        /* R5: the compiled parent binary and the helper -- regular, caller-owned,
           mode exactly 0500, opened relative to run_fd. */
        {
            int self_fd =
                openat(run_fd, "trusted-launch", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
            int helper_fd = openat(run_fd, helper_basename_storage,
                                   O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
            struct stat self_state;
            struct stat helper_state;
            int ok = self_fd >= 0 && helper_fd >= 0 &&
                     fstat(self_fd, &self_state) == 0 &&
                     fstat(helper_fd, &helper_state) == 0 &&
                     S_ISREG(self_state.st_mode) && S_ISREG(helper_state.st_mode) &&
                     self_state.st_uid == geteuid() &&
                     helper_state.st_uid == geteuid() &&
                     (self_state.st_mode & 07777U) == 0500U &&
                     (helper_state.st_mode & 07777U) == 0500U;
            if (self_fd >= 0) {
                (void)close(self_fd);
            }
            if (helper_fd >= 0) {
                (void)close(helper_fd);
            }
            if (!ok) {
                (void)close(run_fd);
                (void)close(out_fd);
                fputs("E_RUNTIME run-directory\n", stderr);
                return 70;
            }
        }

        /* R5: helper identity -- argv[3] is the path this process actually binds
           into YSTACK_RESOLVER_HELPER and execs later; the check above only proved
           that *some* file named helper_basename_storage inside run_fd is a
           caller-owned mode-0500 regular file, not that argv[3] names that same
           object. An external executable sharing the basename would pass that
           check while a different, uninspected file is what actually runs. Bind
           argv[3] to the checked run_fd entry exactly as jq's identity check does
           below: same object (st_dev/st_ino) and the argument's containing
           directory must be run_fd itself. */
        {
            const char *helper_arg_basename = strrchr(argv[3], '/');
            char helper_dir[PATH_MAX];
            size_t helper_dir_length;
            int run_helper_fd;
            int arg_helper_fd;
            int helper_dir_fd;
            struct stat run_helper_state;
            struct stat arg_helper_state;
            struct stat helper_dir_state;
            int helper_identity_ok;

            helper_arg_basename =
                (helper_arg_basename != NULL) ? helper_arg_basename + 1 : argv[3];
            helper_dir_length = (size_t)(helper_arg_basename - argv[3]);
            if (strcmp(helper_arg_basename, helper_basename_storage) != 0 ||
                helper_dir_length == 0U || helper_dir_length >= sizeof(helper_dir)) {
                (void)close(run_fd);
                (void)close(out_fd);
                fputs("E_RUNTIME run-directory\n", stderr);
                return 70;
            }
            memcpy(helper_dir, argv[3], helper_dir_length - 1U);
            helper_dir[helper_dir_length - 1U] = '\0';

            run_helper_fd = openat(run_fd, helper_basename_storage,
                                   O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
            arg_helper_fd = open(argv[3], O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
            helper_dir_fd =
                open(helper_dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            helper_identity_ok = run_helper_fd >= 0 && arg_helper_fd >= 0 &&
                     helper_dir_fd >= 0 &&
                     fstat(run_helper_fd, &run_helper_state) == 0 &&
                     fstat(arg_helper_fd, &arg_helper_state) == 0 &&
                     fstat(helper_dir_fd, &helper_dir_state) == 0 &&
                     run_helper_state.st_dev == arg_helper_state.st_dev &&
                     run_helper_state.st_ino == arg_helper_state.st_ino &&
                     helper_dir_state.st_dev == run_state.st_dev &&
                     helper_dir_state.st_ino == run_state.st_ino;
            if (run_helper_fd >= 0) {
                (void)close(run_helper_fd);
            }
            if (arg_helper_fd >= 0) {
                (void)close(arg_helper_fd);
            }
            if (helper_dir_fd >= 0) {
                (void)close(helper_dir_fd);
            }
            if (!helper_identity_ok) {
                (void)close(run_fd);
                (void)close(out_fd);
                fputs("E_RUNTIME run-directory\n", stderr);
                return 70;
            }
        }
    }

    /* R5: jq identity -- the argument's basename must be exactly "jq", the object
       at run_fd/"jq" and the object the argument names must be the same object, and
       the argument's containing directory must be run_fd itself. File identity
       alone is insufficient (a hardlink elsewhere shares the inode but not the
       directory), so both are required. */
    {
        const char *jq_basename = strrchr(argv[4], '/');
        char jq_dir[PATH_MAX];
        size_t jq_dir_length;
        int run_jq_fd;
        int arg_jq_fd;
        int jq_dir_fd;
        struct stat run_jq_state;
        struct stat arg_jq_state;
        struct stat jq_dir_state;
        int identity_ok;

        jq_basename = (jq_basename != NULL) ? jq_basename + 1 : argv[4];
        jq_dir_length = (size_t)(jq_basename - argv[4]);
        if (strcmp(jq_basename, "jq") != 0 || jq_dir_length == 0U ||
            jq_dir_length >= sizeof(jq_dir)) {
            (void)close(run_fd);
            (void)close(out_fd);
            fputs("E_RUNTIME jq\n", stderr);
            return 70;
        }
        memcpy(jq_dir, argv[4], jq_dir_length - 1U);
        jq_dir[jq_dir_length - 1U] = '\0';

        run_jq_fd = openat(run_fd, "jq", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        arg_jq_fd = open(argv[4], O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        jq_dir_fd = open(jq_dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        identity_ok = run_jq_fd >= 0 && arg_jq_fd >= 0 && jq_dir_fd >= 0 &&
                     fstat(run_jq_fd, &run_jq_state) == 0 &&
                     fstat(arg_jq_fd, &arg_jq_state) == 0 &&
                     fstat(jq_dir_fd, &jq_dir_state) == 0 &&
                     run_jq_state.st_dev == arg_jq_state.st_dev &&
                     run_jq_state.st_ino == arg_jq_state.st_ino &&
                     jq_dir_state.st_dev == run_state.st_dev &&
                     jq_dir_state.st_ino == run_state.st_ino;
        if (run_jq_fd >= 0) {
            (void)close(run_jq_fd);
        }
        if (arg_jq_fd >= 0) {
            (void)close(arg_jq_fd);
        }
        if (jq_dir_fd >= 0) {
            (void)close(jq_dir_fd);
        }
        if (!identity_ok) {
            (void)close(run_fd);
            (void)close(out_fd);
            fputs("E_RUNTIME jq\n", stderr);
            return 70;
        }
    }

    /* R5: .run/awk -- regular, caller-owned, mode exactly 0500, and byte-identical
       to the trusted reference for this platform. */
    if (check_run_directory_awk(run_fd) != 0) {
        (void)close(run_fd);
        (void)close(out_fd);
        fputs("E_RUNTIME awk\n", stderr);
        return 70;
    }

    /* R5/R7: the eight parent-pinned files, by computed git blob id -- the runtime
       file (argv[2] itself), the library, the resolver jq program, and the five jq
       modules under the pinned generation's modules/. */
    {
        char repo_root[PATH_MAX];
        size_t index;
        if (repo_root_from_runtime(argv[2], repo_root, sizeof(repo_root)) != 0) {
            (void)close(run_fd);
            (void)close(out_fd);
            fputs("E_RUNTIME pin\n", stderr);
            return 70;
        }
        for (index = 0U; index < YSTACK_PARENT_PIN_COUNT; index++) {
            char pin_path[PATH_MAX];
            if (build_pin_path(index, repo_root, argv[2], pin_path,
                               sizeof(pin_path)) != 0 ||
                check_blob_pin(pin_path, PARENT_PIN_BLOB_HEX[index]) != 0) {
                (void)close(run_fd);
                (void)close(out_fd);
                fputs("E_RUNTIME pin\n", stderr);
                return 70;
            }
        }
    }

    /* R5/R7: the bound jq's platform SHA-256 digest, then its jq-1.6 identity. */
    if (check_jq_sha256(argv[4]) != 0 || check_jq_version(argv[4]) != 0) {
        (void)close(run_fd);
        (void)close(out_fd);
        fputs("E_RUNTIME jq\n", stderr);
        return 70;
    }

    /* Every check above is done; the resolver reaches these objects through the
       path strings in its own environment (R3), not through this descriptor. */
    (void)close(run_fd);

    /* deviation 7: home and tmp are created relative to out_fd (mkdirat) rather
       than mkdir-by-path; home/temp still hold path strings because HOME/TMPDIR in
       the resolver's environment are strings it resolves by name (the stated
       residual -- R5/R7). */
    if (snprintf(home, sizeof(home), "%s/home", argv[7]) < 0 ||
        snprintf(temp, sizeof(temp), "%s/tmp", argv[7]) < 0 ||
        mkdirat(out_fd, "home", 0700) != 0 || mkdirat(out_fd, "tmp", 0700) != 0) {
        (void)close(out_fd);
        fputs("E_RUNTIME unexpected\n", stderr);
        return 70;
    }

/* copy-begin scripts/test/portable-profile-resolution-launcher.c:652-657 at f4de7e48c688b6adb3669f69a221d2aa7bf43b15 */
    child_argv[0] = "/bin/bash";
    child_argv[1] = argv[2];
    child_argv[2] = "resolve";
    child_argv[3] = argv[5];
    child_argv[4] = argv[6];
    child_argv[5] = NULL;
/* copy-end */

/* copy-begin scripts/test/portable-profile-resolution-launcher.c:659-685 at f4de7e48c688b6adb3669f69a221d2aa7bf43b15 */
    child_env[0] = environment_value("HOME", home);
    child_env[1] = environment_value("TMPDIR", temp);
    child_env[2] = strdup("LC_ALL=C");
    if (strlen(argv[4]) >= sizeof(tool_path)) {
        fputs("E_RUNTIME binding\n", stderr);
        return 70;
    }
    strcpy(tool_path, argv[4]);
    slash = strrchr(tool_path, '/');
    if (slash == NULL || slash == tool_path) {
        fputs("E_RUNTIME binding\n", stderr);
        return 70;
    }
    *slash = '\0';
    if (snprintf(path_value, sizeof(path_value), "%s:/usr/bin:/bin", tool_path) < 0) {
        fputs("E_RUNTIME binding\n", stderr);
        return 70;
    }
    child_env[3] = environment_value("PATH", path_value);
    child_env[4] = strdup("YSTACK_RESOLVER_TRUSTED=1");
    child_env[5] = environment_value("YSTACK_RESOLVER_HELPER", argv[3]);
    child_env[6] = environment_value("YSTACK_RESOLVER_JQ", argv[4]);
    child_env[7] = strdup("GIT_TERMINAL_PROMPT=0");
#if defined(__APPLE__)
    /* Avoid Darwin's fixed nano arena before measuring the 512 MiB process bound. */
    child_env[child_env_count++] = strdup("MallocNanoZone=0");
#endif
/* copy-end */

    /*
     * removed: scripts/test/portable-profile-resolution-launcher.c:686-689 -- the
     * git_wall_test-only YSTACK_RESOLVER_TEST_GIT_WALL_SECONDS / YSTACK_RESOLVER_TEST_GIT_STOP
     * env entries (plan step 2: "Remove ... both test variables 686-689").
     *
     * step 3 TODO: deviation 8 (fixed-envp pre-resolver children for the blob-id, SHA-256
     * and jq --version pins) is unrelated new code, not a replacement for these removed
     * lines -- it lands earlier in main, before the sandbox stub above, once the checked
     * output/run descriptors exist to read from.
     */

/* copy-begin scripts/test/portable-profile-resolution-launcher.c:690-696 at f4de7e48c688b6adb3669f69a221d2aa7bf43b15 */
    child_env[child_env_count] = NULL;
    for (size_t index = 0; index < child_env_count; index++) {
        if (child_env[index] == NULL) {
            fputs("E_RUNTIME unexpected\n", stderr);
            return 70;
        }
    }
/* copy-end */

    /*
     * removed: scripts/test/portable-profile-resolution-launcher.c:697-700 -- the
     * remove_helper-only unlink of the helper binary (plan step 2: "Remove ... the
     * missing-helper test action").
     */

    /* deviation 9: the runtime-pgid diagnostic is written inside supervise() itself,
       right after that function's own fork/publish/restore region -- `child` (the
       resolver's pid, which is also its process group id) is not known until that
       fork runs, so the write cannot happen out here. */

    /* adapted from scripts/test/portable-profile-resolution-launcher.c:701-702 --
       deviation 7 passes out_fd instead of a sandbox path, and out_fd (opened by
       this function, not by supervise()) is closed here after it returns. */
    {
        int status = supervise(out_fd, "/bin/bash", child_argv, child_env);
        (void)close(out_fd);
        return status;
    }
}
