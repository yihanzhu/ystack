#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <pthread.h>

#include <errno.h>
#include <stdbool.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <malloc/malloc.h>
#include <ptrauth.h>
#if !__has_feature(ptrauth_intrinsics)
#error ptrauth intrinsics are required
#endif
#if __has_feature(ptrauth_calls)
#error the ordinary arm64 calling ABI is required
#endif
#endif

#ifndef YSTACK_CANCEL_RELEASE_TESTING
#define YSTACK_CANCEL_RELEASE_TESTING 0
#endif
#ifndef YSTACK_CANCEL_TEST_CASE
#define YSTACK_CANCEL_TEST_CASE 0
#endif

enum result_tag { NOT_RUN = 0, RETURNED = 1 };
enum phase {
    PHASE_PREPARED = 0,
    PHASE_ENTRY_BLOCKED,
    PHASE_CONSUMER,
    PHASE_FINAL_BLOCKED,
    PHASE_RELEASE_RUNNING,
    PHASE_SEALED
};
enum failure_slot {
    FAILURE_NONE = 0,
    FAILURE_ENTRY_MASK,
    FAILURE_ALLOCATOR_DRIFT,
    FAILURE_RESUME_MASK,
    FAILURE_FINAL_MASK,
    FAILURE_HOLD_DUP,
    FAILURE_HOLD_FSTAT,
    FAILURE_ROLLBACK_UNLINK,
    FAILURE_ROLLBACK_FSYNC,
    FAILURE_FINISH_MASK,
    FAILURE_CLOSE,
    FAILURE_CLOSE_FSTAT,
    FAILURE_CONDITIONAL_CLOSE
};

typedef struct {
    int tag;
    int rc;
    int error_number;
} result_cell;

typedef struct {
    uint32_t version;
    uint32_t status;
    uint32_t reason;
    uint32_t identity_bits;
    uint32_t zone_count;
    uint32_t zone_version;
    uint8_t slowpath;
    uint8_t reserved[7];
    uint64_t zone0;
    uint64_t logger;
    uint64_t claimed_address;
    uint64_t try_free_default;
    uint64_t malloc_type_malloc;
    uint64_t malloc_type_realloc;
} ObservationV1;

typedef struct {
    uint8_t count;
    uint8_t reserved[7];
    uint64_t zone;
    uint64_t begin;
    uint64_t end;
    uint8_t values[255];
    uint8_t tail;
} XzmClassSnapshot;

typedef struct {
    PyMemAllocatorEx raw;
    PyMemAllocatorEx mem;
    PyMemAllocatorEx obj;
    PyObjectArenaAllocator arena;
} PythonAllocatorSnapshot;

_Static_assert(sizeof(ObservationV1) == 80, "ObservationV1 size");
_Static_assert(offsetof(ObservationV1, slowpath) == 24, "ObservationV1 slowpath");
_Static_assert(offsetof(ObservationV1, zone0) == 32, "ObservationV1 addresses");
_Static_assert(sizeof(XzmClassSnapshot) == 288, "XzmClassSnapshot size");
_Static_assert(offsetof(XzmClassSnapshot, zone) == 8, "XzmClassSnapshot zone");
_Static_assert(offsetof(XzmClassSnapshot, values) == 32, "XzmClassSnapshot values");
_Static_assert(sizeof(PythonAllocatorSnapshot) == 144, "Python allocator snapshot size");
_Static_assert(offsetof(PythonAllocatorSnapshot, mem) == 40, "MEM allocator offset");
_Static_assert(offsetof(PythonAllocatorSnapshot, obj) == 80, "OBJ allocator offset");
_Static_assert(offsetof(PythonAllocatorSnapshot, arena) == 120, "arena allocator offset");

#if defined(__APPLE__)
_Static_assert(offsetof(malloc_zone_t, claimed_address) == 0x88, "claimed_address layout");
_Static_assert(offsetof(malloc_zone_t, try_free_default) == 0x90, "try_free_default layout");
_Static_assert(offsetof(malloc_zone_t, malloc_type_malloc) == 0xa0, "typed malloc layout");
_Static_assert(offsetof(malloc_zone_t, malloc_type_realloc) == 0xb0, "typed realloc layout");

typedef struct {
    uintptr_t begin;
    uintptr_t end;
} readable_range;

typedef struct {
    malloc_zone_t ***zones_storage;
    uint32_t *count_storage;
    void **logger_storage;
    uint8_t *slowpath_storage;
    uint32_t (*random_uniform)(uint32_t);
    bool (*shared_cache_uuid)(uint8_t[16]);
    uintptr_t malloc_base;
    uintptr_t python_base;
    readable_range zones_storage_range;
    readable_range count_storage_range;
    readable_range logger_storage_range;
    readable_range slowpath_storage_range;
    readable_range zones_range;
    readable_range zone_range;
    readable_range table_range;
    int ready;
} allocator_binding;

static allocator_binding allocator;

enum observation_reason {
    OBSERVATION_OK = 0,
    OBSERVATION_BINDING = 1,
    OBSERVATION_IDENTITY = 2,
    OBSERVATION_MAPPING = 3,
    OBSERVATION_PROFILE = 4,
    OBSERVATION_TARGET = 5,
    OBSERVATION_LAYOUT = 6,
    OBSERVATION_RANDOMIZED = 7,
    OBSERVATION_PYTHON = 8,
    OBSERVATION_DRIFT = 9
};

static int
range_contains(const readable_range *range, const void *pointer, size_t length)
{
    uintptr_t address = (uintptr_t)pointer;
    return address >= range->begin && length <= UINTPTR_MAX - address &&
        address + length <= range->end;
}

static int
capture_readable_range(const void *pointer, size_t length, readable_range *range)
{
    mach_vm_address_t query = (mach_vm_address_t)(uintptr_t)pointer;
    mach_vm_address_t begin = query;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = mach_vm_region(mach_task_self(), &begin, &size,
        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) {
        (void)mach_port_deallocate(mach_task_self(), object);
    }
    if (result != KERN_SUCCESS || !(info.protection & VM_PROT_READ) ||
            begin > query || size > UINTPTR_MAX - begin ||
            length > UINTPTR_MAX - query || query + length > begin + size) {
        return 0;
    }
    range->begin = (uintptr_t)begin;
    range->end = (uintptr_t)(begin + size);
    return 1;
}

static int
image_uuid(const void *base, const uint8_t expected[16])
{
    const struct mach_header_64 *header = base;
    const uint8_t *cursor;
    uint32_t index;
    readable_range commands;
    if (header == NULL || !capture_readable_range(header, sizeof(*header), &commands) ||
            header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64 ||
            header->sizeofcmds > 1024 * 1024 ||
            !capture_readable_range(header, sizeof(*header) + header->sizeofcmds, &commands)) {
        return 0;
    }
    cursor = (const uint8_t *)(header + 1);
    for (index = 0; index < header->ncmds; index++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) ||
                command->cmdsize > UINTPTR_MAX - (uintptr_t)cursor ||
                cursor + command->cmdsize > (const uint8_t *)(header + 1) + header->sizeofcmds) {
            return 0;
        }
        if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuid = (const struct uuid_command *)command;
            return memcmp(uuid->uuid, expected, 16) == 0;
        }
        cursor += command->cmdsize;
    }
    return 0;
}

static int
bind_allocator(void)
{
    static const uint8_t cache_uuid[16] = {
        0x42,0x18,0x85,0xd7,0x01,0xcc,0x36,0x29,0xb5,0x9b,0x6a,0x06,0x8d,0xb3,0x44,0x20};
    static const uint8_t malloc_uuid[16] = {
        0x79,0x7c,0x42,0x77,0x18,0xa2,0x36,0x5f,0x8f,0xc9,0x95,0x7c,0x37,0x1a,0x02,0xa4};
    static const uint8_t python_uuid[16] = {
        0x3a,0x57,0xdb,0x8c,0x0f,0x45,0x3d,0x16,0x88,0xca,0x37,0xca,0x36,0xd8,0x69,0xce};
    static const uint8_t libc_uuid[16] = {
        0xaf,0x20,0x49,0x63,0xe3,0x50,0x39,0xa8,0x9e,0x50,0x16,0x81,0xdb,0xc4,0x13,0x3d};
    Dl_info malloc_info;
    Dl_info python_info;
    Dl_info random_info;
    malloc_zone_t **zones;
    malloc_zone_t *zone;
    uintptr_t table_begin;
    uintptr_t table_end;
    uint8_t count;
    uint8_t observed_cache_uuid[16];
    memset(&allocator, 0, sizeof(allocator));
    dlerror();
    allocator.zones_storage = (malloc_zone_t ***)dlsym(RTLD_DEFAULT, "malloc_zones");
    if (dlerror() != NULL) return 0;
    allocator.count_storage = (uint32_t *)dlsym(RTLD_DEFAULT, "malloc_num_zones");
    if (dlerror() != NULL) return 0;
    allocator.logger_storage = (void **)dlsym(RTLD_DEFAULT, "malloc_logger");
    if (dlerror() != NULL) return 0;
    allocator.random_uniform = (uint32_t (*)(uint32_t))dlsym(RTLD_DEFAULT,
        "arc4random_uniform");
    if (dlerror() != NULL || allocator.random_uniform == NULL) return 0;
    allocator.shared_cache_uuid = (bool (*)(uint8_t[16]))dlsym(RTLD_DEFAULT,
        "_dyld_get_shared_cache_uuid");
    if (dlerror() != NULL || allocator.shared_cache_uuid == NULL) return 0;
    allocator.slowpath_storage = (uint8_t *)allocator.logger_storage + 0x20;
    if (!dladdr(allocator.zones_storage, &malloc_info) || malloc_info.dli_fbase == NULL ||
            !dladdr((void *)(uintptr_t)PyMem_GetAllocator, &python_info) ||
            python_info.dli_fbase == NULL ||
            !dladdr((void *)(uintptr_t)allocator.random_uniform, &random_info) ||
            random_info.dli_fbase == NULL || random_info.dli_saddr == NULL ||
            !image_uuid(malloc_info.dli_fbase, malloc_uuid) ||
            !image_uuid(python_info.dli_fbase, python_uuid) ||
            !image_uuid(random_info.dli_fbase, libc_uuid) ||
            !allocator.shared_cache_uuid(observed_cache_uuid) ||
            memcmp(observed_cache_uuid, cache_uuid, sizeof(cache_uuid)) != 0) return 0;
    allocator.malloc_base = (uintptr_t)malloc_info.dli_fbase;
    allocator.python_base = (uintptr_t)python_info.dli_fbase;
    if ((uintptr_t)(void *)(uintptr_t)PyMem_GetAllocator != allocator.python_base + 0xcca84 ||
            (uintptr_t)(void *)(uintptr_t)PyObject_GetArenaAllocator != allocator.python_base + 0xccc10 ||
            (uintptr_t)(void *)(uintptr_t)allocator.random_uniform !=
                (uintptr_t)random_info.dli_fbase + 0x12cd4 ||
            (uintptr_t)random_info.dli_saddr !=
                (uintptr_t)(void *)(uintptr_t)allocator.random_uniform ||
            !capture_readable_range(allocator.zones_storage, sizeof(*allocator.zones_storage),
                &allocator.zones_storage_range) ||
            !capture_readable_range(allocator.count_storage, sizeof(*allocator.count_storage),
                &allocator.count_storage_range) ||
            !capture_readable_range(allocator.logger_storage, sizeof(*allocator.logger_storage),
                &allocator.logger_storage_range) ||
            !capture_readable_range(allocator.slowpath_storage, 1,
                &allocator.slowpath_storage_range)) return 0;
    zones = *allocator.zones_storage;
    if (*allocator.count_storage != 2 || zones == NULL ||
            !capture_readable_range(zones, 2 * sizeof(*zones), &allocator.zones_range)) return 0;
    zone = zones[0];
    if (zone == NULL || !capture_readable_range(zone, 0x268, &allocator.zone_range)) return 0;
    count = *((uint8_t *)zone + 0xd2);
    memcpy(&table_begin, (uint8_t *)zone + 0xd8, sizeof(table_begin));
    memcpy(&table_end, (uint8_t *)zone + 0xe0, sizeof(table_end));
    if (count == 0 || table_begin != (uintptr_t)zone + 0x268 ||
            (uintptr_t)count > (UINTPTR_MAX - table_begin) / 0x60 ||
            table_end != table_begin + (uintptr_t)count * 0x60 ||
            !capture_readable_range((void *)table_begin, table_end - table_begin,
                &allocator.table_range)) return 0;
    allocator.ready = 1;
    return 1;
}
#endif

typedef struct {
    PyObject_HEAD
    enum phase phase;
    enum failure_slot first_failure;
    sigset_t watched;
    sigset_t entry_old;
    sigset_t final_old;
    result_cell entry_mask;
    result_cell resume_mask;
    result_cell final_mask;
    result_cell finish_mask;
    result_cell hold_dup;
    result_cell hold_fstat;
    result_cell rollback_unlink;
    result_cell rollback_fsync;
    result_cell close_result;
    result_cell close_fstat;
    result_cell conditional_close;
    int completion_fd;
    int completion_identity_valid;
    dev_t completion_dev;
    ino_t completion_ino;
    mode_t completion_type;
    int rollback_attempted;
    int allocator_observed;
    uint64_t xzm_f0;
    ObservationV1 observation;
    XzmClassSnapshot xzm_snapshot;
    PythonAllocatorSnapshot python_snapshot;
    PyObject *outcome_pending;
    PyObject *outcome_success;
    PyObject *outcome_failure;
    PyObject *outcome_value;
    PyObject *module_ref;
    PyObject *method_refs[8];
} NativeState;

static PyMethodDef state_methods[];
static PyTypeObject NativeStateType = {
    PyVarObject_HEAD_INIT(NULL, 0)
    .tp_name = "_cancel_release.NativeState",
    .tp_basicsize = sizeof(NativeState),
    .tp_flags = Py_TPFLAGS_DEFAULT,
    .tp_methods = state_methods,
    .tp_new = NULL
};

static void
record_result(result_cell *cell, int rc, int error_number)
{
    cell->tag = RETURNED;
    cell->rc = rc;
    cell->error_number = error_number;
}

static void
remember_failure(NativeState *state, enum failure_slot slot)
{
    if (state->first_failure == FAILURE_NONE) {
        state->first_failure = slot;
    }
    state->outcome_value = state->outcome_failure;
}

static int
mask_call(int which, int how, const sigset_t *set, sigset_t *old)
{
#if !YSTACK_CANCEL_RELEASE_TESTING
    (void)which;
#endif
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == which) {
        return EIO;
    }
#endif
    return pthread_sigmask(how, set, old);
}

static int
close_call(int fd, int conditional)
{
#if !YSTACK_CANCEL_RELEASE_TESTING
    (void)conditional;
#endif
#if YSTACK_CANCEL_RELEASE_TESTING
    if (!conditional && (YSTACK_CANCEL_TEST_CASE == 5 ||
            YSTACK_CANCEL_TEST_CASE == 7 || YSTACK_CANCEL_TEST_CASE == 8)) {
        errno = EINTR;
        return -1;
    }
    if (!conditional && YSTACK_CANCEL_TEST_CASE == 6) {
        (void)close(fd);
        errno = EBADF;
        return -1;
    }
#endif
    return close(fd);
}

static int
duplicate_call(int fd)
{
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 12) {
        errno = EIO;
        return -1;
    }
#endif
#ifdef F_DUPFD_CLOEXEC
    return fcntl(fd, F_DUPFD_CLOEXEC, 0);
#else
    return dup(fd);
#endif
}

static int
fstat_call(int fd, struct stat *value)
{
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 7) {
        errno = EIO;
        return -1;
    }
#endif
    int rc = fstat(fd, value);
#if YSTACK_CANCEL_RELEASE_TESTING
    if (rc == 0 && YSTACK_CANCEL_TEST_CASE == 8) {
        value->st_ino ^= (ino_t)1;
    }
#endif
    return rc;
}

static int
hold_fstat_call(int fd, struct stat *value)
{
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 13) {
        errno = EIO;
        return -1;
    }
#endif
    return fstat(fd, value);
}

static void
rollback_marker(NativeState *state)
{
    int rc;
    int saved_errno;
    if (state->rollback_attempted || state->completion_fd < 0 ||
            !state->completion_identity_valid) {
        return;
    }
    state->rollback_attempted = 1;
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 9) {
        errno = EIO;
        rc = -1;
    }
    else
#endif
    {
        rc = unlinkat(state->completion_fd, "bundle.json", 0);
    }
    saved_errno = rc < 0 ? errno : 0;
    record_result(&state->rollback_unlink, rc, saved_errno);
    if (rc < 0) {
        remember_failure(state, FAILURE_ROLLBACK_UNLINK);
    }
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 10) {
        errno = EIO;
        rc = -1;
    }
    else
#endif
    {
        rc = fsync(state->completion_fd);
    }
    saved_errno = rc < 0 ? errno : 0;
    record_result(&state->rollback_fsync, rc, saved_errno);
    if (rc < 0) {
        remember_failure(state, FAILURE_ROLLBACK_FSYNC);
    }
}

static int
require_phase(NativeState *state, enum phase expected)
{
    if (state->phase != expected) {
        PyErr_SetString(PyExc_RuntimeError, "invalid native cancellation phase");
        return 0;
    }
    return 1;
}

#if defined(__APPLE__)
static uintptr_t
authenticate_claimed(malloc_zone_t *zone)
{
    typeof(zone->claimed_address) value = zone->claimed_address;
    if (value == NULL) return 0;
    return (uintptr_t)ptrauth_auth_data(ptrauth_nop_cast(void *, value),
        ptrauth_key_process_independent_code,
#if YSTACK_CANCEL_RELEASE_TESTING && YSTACK_CANCEL_TEST_CASE == 16
        ptrauth_string_discriminator("malloc_zone_fn.try_free_default"));
#else
        ptrauth_string_discriminator("malloc_zone_fn.claimed_address"));
#endif
}

static int
zone_slot_is_readable(malloc_zone_t *zone, size_t offset)
{
    uintptr_t address = (uintptr_t)zone;
    return address <= UINTPTR_MAX - offset &&
        ((address + offset) & (sizeof(void *) - 1)) == 0 &&
        range_contains(&allocator.zone_range, (uint8_t *)zone + offset, sizeof(void *));
}

static uintptr_t
authenticate_try_free(malloc_zone_t *zone)
{
    typeof(zone->try_free_default) value = zone->try_free_default;
    if (value == NULL) return 0;
    return (uintptr_t)ptrauth_auth_data(ptrauth_nop_cast(void *, value),
        ptrauth_key_process_independent_code,
        ptrauth_string_discriminator("malloc_zone_fn.try_free_default"));
}

static uintptr_t
authenticate_typed_malloc(malloc_zone_t *zone)
{
    typeof(zone->malloc_type_malloc) value = zone->malloc_type_malloc;
    if (value == NULL) return 0;
    return (uintptr_t)ptrauth_auth_data(ptrauth_nop_cast(void *, value),
        ptrauth_key_process_independent_code,
        ptrauth_string_discriminator("malloc_zone_fn.malloc_type_malloc"));
}

static uintptr_t
authenticate_typed_realloc(malloc_zone_t *zone)
{
    typeof(zone->malloc_type_realloc) value = zone->malloc_type_realloc;
    if (value == NULL) return 0;
    return (uintptr_t)ptrauth_auth_data(ptrauth_nop_cast(void *, value),
        ptrauth_key_process_independent_code,
        ptrauth_string_discriminator("malloc_zone_fn.malloc_type_realloc"));
}

static uintptr_t
function_address(void (*function)(void))
{
    union { void (*function)(void); uintptr_t value; } bits;
    bits.function = function;
    return bits.value;
}

static int
python_profile_matches(const PythonAllocatorSnapshot *snapshot)
{
    uintptr_t base = allocator.python_base;
    return snapshot->raw.ctx == NULL && snapshot->mem.ctx == NULL &&
        snapshot->obj.ctx == NULL && snapshot->arena.ctx == NULL &&
        function_address((void (*)(void))snapshot->raw.malloc) == base + 0xcbf90 &&
        function_address((void (*)(void))snapshot->raw.calloc) == base + 0xcbf9c &&
        function_address((void (*)(void))snapshot->raw.realloc) == base + 0xcbfbc &&
        function_address((void (*)(void))snapshot->raw.free) == base + 0xcbfd0 &&
        function_address((void (*)(void))snapshot->mem.malloc) == base + 0xcd460 &&
        function_address((void (*)(void))snapshot->mem.calloc) == base + 0xcd8c4 &&
        function_address((void (*)(void))snapshot->mem.realloc) == base + 0xcdbc0 &&
        function_address((void (*)(void))snapshot->mem.free) == base + 0xcd980 &&
        function_address((void (*)(void))snapshot->obj.malloc) == base + 0xcd460 &&
        function_address((void (*)(void))snapshot->obj.calloc) == base + 0xcd8c4 &&
        function_address((void (*)(void))snapshot->obj.realloc) == base + 0xcdbc0 &&
        function_address((void (*)(void))snapshot->obj.free) == base + 0xcd980 &&
        function_address((void (*)(void))snapshot->arena.alloc) == base + 0xcc1a0 &&
        function_address((void (*)(void))snapshot->arena.free) == base + 0xcc1d0;
}

static int
capture_allocator_observation(NativeState *state)
{
    malloc_zone_t **zones;
    malloc_zone_t *zone;
    uintptr_t parent;
    uintptr_t begin;
    uintptr_t end;
    uint8_t count;
    uint8_t index;
    uint64_t f0;
    ObservationV1 *record = &state->observation;
    XzmClassSnapshot *snapshot = &state->xzm_snapshot;
    memset(record, 0, sizeof(*record));
    memset(snapshot, 0, sizeof(*snapshot));
    memset(&state->python_snapshot, 0, sizeof(state->python_snapshot));
    record->version = 1;
    if (!allocator.ready) { record->reason = OBSERVATION_BINDING; return 0; }
    (void)allocator.random_uniform(UINT32_MAX);
    if (!range_contains(&allocator.zones_storage_range, allocator.zones_storage,
                sizeof(*allocator.zones_storage)) ||
            !range_contains(&allocator.count_storage_range, allocator.count_storage,
                sizeof(*allocator.count_storage)) ||
            !range_contains(&allocator.logger_storage_range, allocator.logger_storage,
                sizeof(*allocator.logger_storage)) ||
            !range_contains(&allocator.slowpath_storage_range, allocator.slowpath_storage, 1)) {
        record->reason = OBSERVATION_MAPPING; return 0;
    }
    zones = *allocator.zones_storage;
    if (*allocator.count_storage != 2 || zones == NULL ||
            !range_contains(&allocator.zones_range, zones, 2 * sizeof(*zones))) {
        record->reason = OBSERVATION_PROFILE; return 0;
    }
    zone = zones[0];
    record->zone_count = *allocator.count_storage;
    record->zone0 = (uint64_t)(uintptr_t)zone;
    record->logger = (uint64_t)(uintptr_t)*allocator.logger_storage;
    record->slowpath = *allocator.slowpath_storage;
    if (zone == NULL || !range_contains(&allocator.zone_range, zone, 0x268) ||
            zone->version != 16 || record->logger != 0 || record->slowpath != 0) {
        record->reason = OBSERVATION_PROFILE; return 0;
    }
    record->zone_version = zone->version;
    if (!zone_slot_is_readable(zone, offsetof(malloc_zone_t, claimed_address)) ||
            !zone_slot_is_readable(zone, offsetof(malloc_zone_t, try_free_default)) ||
            !zone_slot_is_readable(zone, offsetof(malloc_zone_t, malloc_type_malloc)) ||
            !zone_slot_is_readable(zone, offsetof(malloc_zone_t, malloc_type_realloc))) {
        record->reason = OBSERVATION_MAPPING; return 0;
    }
    record->claimed_address = authenticate_claimed(zone);
    record->try_free_default = authenticate_try_free(zone);
    record->malloc_type_malloc = authenticate_typed_malloc(zone);
    record->malloc_type_realloc = authenticate_typed_realloc(zone);
    if (record->claimed_address != allocator.malloc_base + 0x3021c) {
        record->reason = 10; return 0;
    }
    if (record->try_free_default != allocator.malloc_base + 0x3b67c
#if YSTACK_CANCEL_RELEASE_TESTING
            && record->try_free_default != allocator.malloc_base + 0x3b64c
#endif
            ) {
        record->reason = 11; return 0;
    }
    if (record->malloc_type_malloc != allocator.malloc_base + 0x3a5e8
#if YSTACK_CANCEL_RELEASE_TESTING
            && record->malloc_type_malloc != allocator.malloc_base + 0x3a528
#endif
            ) {
        record->reason = 12; return 0;
    }
    if (record->malloc_type_realloc != allocator.malloc_base + 0x30328) {
        record->reason = 13; return 0;
    }
    memcpy(&parent, (uint8_t *)zone + 0x100, sizeof(parent));
    count = *((uint8_t *)zone + 0xd2);
    memcpy(&begin, (uint8_t *)zone + 0xd8, sizeof(begin));
    memcpy(&end, (uint8_t *)zone + 0xe0, sizeof(end));
    if (parent != 0 || count == 0 || begin != (uintptr_t)zone + 0x268 ||
            (uintptr_t)count > (UINTPTR_MAX - begin) / 0x60 ||
            end != begin + (uintptr_t)count * 0x60 ||
            !range_contains(&allocator.table_range, (void *)begin, end - begin)) {
        record->reason = OBSERVATION_LAYOUT; return 0;
    }
    if ((uintptr_t)zone > UINTPTR_MAX - 0xf0 ||
            (((uintptr_t)zone + 0xf0) & (sizeof(f0) - 1)) != 0 ||
            !range_contains(&allocator.zone_range, (uint8_t *)zone + 0xf0, sizeof(f0))) {
        record->reason = OBSERVATION_LAYOUT; return 0;
    }
    memcpy(&f0, (uint8_t *)zone + 0xf0, sizeof(f0));
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 15) f0 = 1;
#endif
    if (f0 != 0) { record->reason = OBSERVATION_PROFILE; return 0; }
    state->xzm_f0 = f0;
    snapshot->count = count;
    snapshot->zone = (uint64_t)(uintptr_t)zone;
    snapshot->begin = begin;
    snapshot->end = end;
    for (index = 0; index < count; index++) {
        snapshot->values[index] = *((uint8_t *)begin + (size_t)index * 0x60 + 0x58);
        if (snapshot->values[index] == 1) {
            record->reason = OBSERVATION_RANDOMIZED; return 0;
        }
    }
    PyMem_GetAllocator(PYMEM_DOMAIN_RAW, &state->python_snapshot.raw);
    PyMem_GetAllocator(PYMEM_DOMAIN_MEM, &state->python_snapshot.mem);
    PyMem_GetAllocator(PYMEM_DOMAIN_OBJ, &state->python_snapshot.obj);
    PyObject_GetArenaAllocator(&state->python_snapshot.arena);
    if (!python_profile_matches(&state->python_snapshot)) {
        record->reason = OBSERVATION_PYTHON; return 0;
    }
    if (*allocator.zones_storage != zones || *allocator.count_storage != 2 ||
            zones[0] != zone || zone->version != 16 || *allocator.logger_storage != NULL ||
            *allocator.slowpath_storage != 0) {
        record->reason = OBSERVATION_DRIFT; return 0;
    }
    record->identity_bits = 0x0f;
    record->status = 1;
    return 1;
}

static int
allocator_snapshot_matches(NativeState *state)
{
    malloc_zone_t **zones;
    malloc_zone_t *zone;
    uintptr_t parent;
    uintptr_t begin;
    uintptr_t end;
    uint8_t count;
    uint8_t index;
    uint64_t f0;
    if (!state->allocator_observed || !allocator.ready) return 0;
    if (!range_contains(&allocator.zones_storage_range, allocator.zones_storage,
                sizeof(*allocator.zones_storage)) ||
            !range_contains(&allocator.count_storage_range, allocator.count_storage,
                sizeof(*allocator.count_storage)) ||
            !range_contains(&allocator.logger_storage_range, allocator.logger_storage,
                sizeof(*allocator.logger_storage)) ||
            !range_contains(&allocator.slowpath_storage_range, allocator.slowpath_storage, 1)) return 0;
    zones = *allocator.zones_storage;
    if (zones == NULL || *allocator.count_storage != state->observation.zone_count ||
            !range_contains(&allocator.zones_range, zones,
                state->observation.zone_count * sizeof(*zones)) ||
            zones[0] != (malloc_zone_t *)(uintptr_t)state->observation.zone0 ||
            *allocator.logger_storage != (void *)(uintptr_t)state->observation.logger ||
            *allocator.slowpath_storage != state->observation.slowpath) return 0;
    zone = zones[0];
    if (!range_contains(&allocator.zone_range, zone, 0x268) ||
            !range_contains(&allocator.table_range,
                (void *)(uintptr_t)state->xzm_snapshot.begin,
                state->xzm_snapshot.end - state->xzm_snapshot.begin)) return 0;
    memcpy(&parent, (uint8_t *)zone + 0x100, sizeof(parent));
    count = *((uint8_t *)zone + 0xd2);
    memcpy(&begin, (uint8_t *)zone + 0xd8, sizeof(begin));
    memcpy(&end, (uint8_t *)zone + 0xe0, sizeof(end));
    if (parent != 0 || count != state->xzm_snapshot.count ||
            begin != state->xzm_snapshot.begin || end != state->xzm_snapshot.end ||
            zone->version != state->observation.zone_version) return 0;
    if ((uintptr_t)zone > UINTPTR_MAX - 0xf0 ||
            (((uintptr_t)zone + 0xf0) & (sizeof(f0) - 1)) != 0 ||
            !range_contains(&allocator.zone_range, (uint8_t *)zone + 0xf0, sizeof(f0))) return 0;
    memcpy(&f0, (uint8_t *)zone + 0xf0, sizeof(f0));
#if YSTACK_CANCEL_RELEASE_TESTING
    if (YSTACK_CANCEL_TEST_CASE == 14) f0 = 1;
#endif
    if (f0 != state->xzm_f0 || f0 != 0) return 0;
    for (index = 0; index < count; index++) {
        if (*((uint8_t *)begin + (size_t)index * 0x60 + 0x58) !=
                state->xzm_snapshot.values[index]) return 0;
    }
    return 1;
}
#endif

static PyObject *
state_observe_allocator_admission(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    if (!require_phase(state, PHASE_PREPARED) || state->allocator_observed) {
        if (!PyErr_Occurred()) PyErr_SetString(PyExc_RuntimeError, "allocator observation already ran");
        return NULL;
    }
#if defined(__APPLE__)
    if (!capture_allocator_observation(state)) {
        static const char *reasons[] = {
            "allocator admission refused", "allocator binding refused",
            "allocator identity refused", "allocator mapping refused",
            "allocator profile refused", "allocator target refused",
            "allocator layout refused", "allocator randomization refused",
            "python allocator refused", "allocator drift refused",
            "claimed target refused", "try-free target refused",
            "typed malloc target refused", "typed realloc target refused"
        };
        uint32_t reason = state->observation.reason;
        PyErr_SetString(PyExc_RuntimeError,
            reason < sizeof(reasons) / sizeof(reasons[0]) ? reasons[reason] : reasons[0]);
        return NULL;
    }
#else
    memset(&state->observation, 0, sizeof(state->observation));
    state->observation.version = 1;
    state->observation.status = 1;
#endif
    state->allocator_observed = 1;
    Py_RETURN_NONE;
}

static PyObject *
state_block_entry(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    int rc;
    if (!require_phase(state, PHASE_PREPARED)) {
        return NULL;
    }
#if defined(__APPLE__)
    if (!state->allocator_observed) {
        PyErr_SetString(PyExc_RuntimeError, "allocator observation is required");
        return NULL;
    }
#endif
    rc = mask_call(1, SIG_BLOCK, &state->watched, &state->entry_old);
    record_result(&state->entry_mask, rc, 0);
    if (rc != 0) {
        remember_failure(state, FAILURE_ENTRY_MASK);
    }
    else {
        state->phase = PHASE_ENTRY_BLOCKED;
#if YSTACK_CANCEL_RELEASE_TESTING
        if (YSTACK_CANCEL_TEST_CASE == 11) {
            (void)raise(SIGTERM);
        }
#endif
    }
    Py_RETURN_NONE;
}

static PyObject *
state_resume_consumer(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    int rc;
    if (!require_phase(state, PHASE_ENTRY_BLOCKED) ||
            state->entry_mask.tag != RETURNED || state->entry_mask.rc != 0) {
        return NULL;
    }
    rc = mask_call(2, SIG_SETMASK, &state->entry_old, NULL);
    record_result(&state->resume_mask, rc, 0);
    if (rc != 0) {
        remember_failure(state, FAILURE_RESUME_MASK);
    }
    else {
        state->phase = PHASE_CONSUMER;
    }
    Py_RETURN_NONE;
}

static PyObject *
state_hold_completion(NativeState *state, PyObject *argument)
{
    long borrowed;
    int owned;
    int saved_errno;
    struct stat value;
    if (!require_phase(state, PHASE_CONSUMER) || !PyLong_CheckExact(argument) ||
            state->completion_fd >= 0) {
        if (!PyErr_Occurred()) {
            PyErr_SetString(PyExc_TypeError, "hold_completion requires one owned directory fd");
        }
        return NULL;
    }
    borrowed = PyLong_AsLong(argument);
    if (borrowed < 0 || borrowed > INT32_MAX || PyErr_Occurred()) {
        return NULL;
    }
    owned = duplicate_call((int)borrowed);
#ifndef F_DUPFD_CLOEXEC
    if (owned >= 0 && fcntl(owned, F_SETFD, FD_CLOEXEC) < 0) {
        saved_errno = errno;
        (void)close(owned);
        errno = saved_errno;
        owned = -1;
    }
#endif
    saved_errno = owned < 0 ? errno : 0;
    record_result(&state->hold_dup, owned < 0 ? -1 : 0, saved_errno);
    if (owned < 0) {
        remember_failure(state, FAILURE_HOLD_DUP);
        Py_RETURN_NONE;
    }
    state->completion_fd = owned;
    if (hold_fstat_call(owned, &value) < 0) {
        saved_errno = errno;
        record_result(&state->hold_fstat, -1, saved_errno);
        remember_failure(state, FAILURE_HOLD_FSTAT);
        Py_RETURN_NONE;
    }
    record_result(&state->hold_fstat, 0, 0);
    state->completion_dev = value.st_dev;
    state->completion_ino = value.st_ino;
    state->completion_type = value.st_mode & S_IFMT;
    state->completion_identity_valid = 1;
    Py_RETURN_NONE;
}

static PyObject *
state_block_final(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    int rc;
    if (!require_phase(state, PHASE_CONSUMER)) {
        return NULL;
    }
    if (state->completion_fd < 0) {
        PyErr_SetString(PyExc_RuntimeError, "completion ownership is unavailable");
        return NULL;
    }
#if defined(__APPLE__)
    if (!allocator_snapshot_matches(state)) {
        remember_failure(state, FAILURE_ALLOCATOR_DRIFT);
    }
#endif
    rc = mask_call(3, SIG_BLOCK, &state->watched, &state->final_old);
    record_result(&state->final_mask, rc, 0);
    if (rc != 0) {
        remember_failure(state, FAILURE_FINAL_MASK);
    }
    else {
        state->phase = PHASE_FINAL_BLOCKED;
    }
    Py_RETURN_NONE;
}

static PyObject *
state_rollback_marker(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    if (state->phase != PHASE_ENTRY_BLOCKED && state->phase != PHASE_CONSUMER &&
            state->phase != PHASE_FINAL_BLOCKED) {
        PyErr_SetString(PyExc_RuntimeError, "invalid native cancellation phase");
        return NULL;
    }
    rollback_marker(state);
    Py_RETURN_NONE;
}

static PyObject *
state_finish_release(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    const sigset_t *restore = NULL;
    int rc;
    int saved_errno;
    int conditional_rc;
    struct stat value;
    if (state->phase == PHASE_ENTRY_BLOCKED && state->entry_mask.tag == RETURNED &&
            state->entry_mask.rc == 0) {
        restore = &state->entry_old;
    }
    else if (state->phase == PHASE_FINAL_BLOCKED && state->final_mask.tag == RETURNED &&
            state->final_mask.rc == 0) {
        restore = &state->final_old;
    }
    else if (state->phase != PHASE_PREPARED && state->phase != PHASE_CONSUMER) {
        PyErr_SetString(PyExc_RuntimeError, "invalid native cancellation phase");
        return NULL;
    }
    state->phase = PHASE_RELEASE_RUNNING;
    if (state->first_failure != FAILURE_NONE && !state->rollback_attempted) {
        rollback_marker(state);
    }
    if (restore != NULL) {
        rc = mask_call(4, SIG_SETMASK, restore, NULL);
        record_result(&state->finish_mask, rc, 0);
        if (rc != 0) {
            remember_failure(state, FAILURE_FINISH_MASK);
            rollback_marker(state);
        }
    }
    if (state->completion_fd >= 0) {
        rc = close_call(state->completion_fd, 0);
        saved_errno = rc < 0 ? errno : 0;
        record_result(&state->close_result, rc, saved_errno);
        if (rc == 0) {
            state->completion_fd = -1;
            state->completion_identity_valid = 0;
        }
        else {
            remember_failure(state, FAILURE_CLOSE);
            rc = fstat_call(state->completion_fd, &value);
            saved_errno = rc < 0 ? errno : 0;
            record_result(&state->close_fstat, rc, saved_errno);
            if (rc < 0) {
                remember_failure(state, FAILURE_CLOSE_FSTAT);
                state->completion_fd = -1;
                state->completion_identity_valid = 0;
            }
            else if (!state->completion_identity_valid ||
                    value.st_dev != state->completion_dev ||
                    value.st_ino != state->completion_ino ||
                    (value.st_mode & S_IFMT) != state->completion_type) {
                state->completion_fd = -1;
                state->completion_identity_valid = 0;
            }
            else {
                rollback_marker(state);
                conditional_rc = close_call(state->completion_fd, 1);
                saved_errno = conditional_rc < 0 ? errno : 0;
                record_result(&state->conditional_close, conditional_rc, saved_errno);
                if (conditional_rc < 0) {
                    remember_failure(state, FAILURE_CONDITIONAL_CLOSE);
                }
                state->completion_fd = -1;
                state->completion_identity_valid = 0;
            }
        }
    }
    state->phase = PHASE_SEALED;
    if (state->first_failure == FAILURE_NONE) {
        state->outcome_value = state->outcome_success;
    }
    else {
        state->outcome_value = state->outcome_failure;
    }
    Py_INCREF(state->outcome_value);
    return state->outcome_value;
}

static PyObject *
state_outcome(NativeState *state, PyObject *Py_UNUSED(ignored))
{
    Py_INCREF(state->outcome_value);
    return state->outcome_value;
}

static PyMethodDef state_methods[] = {
    {"observe_allocator_admission", (PyCFunction)state_observe_allocator_admission,
        METH_NOARGS, NULL},
    {"block_entry", (PyCFunction)state_block_entry, METH_NOARGS, NULL},
    {"resume_consumer", (PyCFunction)state_resume_consumer, METH_NOARGS, NULL},
    {"hold_completion", (PyCFunction)state_hold_completion, METH_O, NULL},
    {"block_final", (PyCFunction)state_block_final, METH_NOARGS, NULL},
    {"rollback_marker", (PyCFunction)state_rollback_marker, METH_NOARGS, NULL},
    {"finish_release", (PyCFunction)state_finish_release, METH_NOARGS, NULL},
    {"outcome", (PyCFunction)state_outcome, METH_NOARGS, NULL},
    {NULL, NULL, 0, NULL}
};

static PyObject *
prepare_state(PyObject *module, PyObject *Py_UNUSED(ignored))
{
    NativeState *state;
    struct sigaction action;
    size_t index;
    static const char *names[] = {
        "observe_allocator_admission", "block_entry", "resume_consumer", "hold_completion", "block_final",
        "rollback_marker", "finish_release", "outcome"
    };
    state = PyObject_New(NativeState, &NativeStateType);
    if (state == NULL) {
        return NULL;
    }
    memset(((char *)state) + sizeof(PyObject), 0, sizeof(*state) - sizeof(PyObject));
    state->phase = PHASE_PREPARED;
    state->completion_fd = -1;
    if (sigemptyset(&state->watched) != 0 ||
            sigaddset(&state->watched, SIGHUP) != 0 ||
            sigaddset(&state->watched, SIGINT) != 0 ||
            sigaddset(&state->watched, SIGTERM) != 0) {
        Py_DECREF(state);
        return PyErr_SetFromErrno(PyExc_OSError);
    }
    if (sigaction(SIGHUP, NULL, &action) != 0 ||
            sigaction(SIGINT, NULL, &action) != 0 ||
            sigaction(SIGTERM, NULL, &action) != 0) {
        Py_DECREF(state);
        return PyErr_SetFromErrno(PyExc_OSError);
    }
    state->outcome_pending = PyUnicode_InternFromString("native-release.pending");
    state->outcome_success = PyUnicode_InternFromString("native-release.success");
    state->outcome_failure = PyUnicode_InternFromString("native-release.failure");
    if (state->outcome_pending == NULL || state->outcome_success == NULL ||
            state->outcome_failure == NULL) {
        Py_DECREF(state);
        return NULL;
    }
    state->outcome_value = state->outcome_pending;
    state->module_ref = module;
    Py_INCREF(module);
    for (index = 0; index < sizeof(names) / sizeof(names[0]); index++) {
        state->method_refs[index] = PyObject_GetAttrString((PyObject *)state, names[index]);
        if (state->method_refs[index] == NULL) {
            Py_DECREF(state);
            return NULL;
        }
    }
    return (PyObject *)state;
}

static PyMethodDef module_methods[] = {
    {"prepare_state", prepare_state, METH_NOARGS, NULL},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef module_definition = {
    .m_base = PyModuleDef_HEAD_INIT,
    .m_name = "_cancel_release",
    .m_size = -1,
    .m_methods = module_methods
};

PyMODINIT_FUNC
PyInit__cancel_release(void)
{
    PyObject *module;
    if (PyType_Ready(&NativeStateType) < 0) {
        return NULL;
    }
#if defined(__APPLE__)
    (void)bind_allocator();
#endif
    module = PyModule_Create(&module_definition);
    if (module == NULL) {
        return NULL;
    }
    return module;
}
