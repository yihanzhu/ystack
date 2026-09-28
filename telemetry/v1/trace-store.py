import errno
import fcntl
import hashlib
import json
import os
import re
import select
import signal
import subprocess
import sys
import zlib

# ---------------------------------------------------------------------------
# Limits (R9). Each is its own module constant so a test wrapper may lower
# one without touching the others. `initialize` bakes the current values
# into store.json; every later call re-checks the store against these same
# module-level values.
# ---------------------------------------------------------------------------

RECORDS_MAX = 1024
LEDGER_BYTES_MAX = 1048576
VALIDATOR_STDOUT_MAX = 16384
VALIDATOR_STDERR_MAX = 4096
RECORD_DOC_MAX = 4096
STORE_DOC_MAX = 4096
TREE_CONTENT_MAX = 1024
COMMIT_CONTENT_MAX = 1024
OBJECT_FILES_MAX = 8192
FS_ENTRIES_MAX = 16384
REGULAR_BYTES_MAX = 268435456
INFLATED_BYTES_MAX = 268435456
LISTING_BYTES_MAX = 1048576
RESERVE_FILES = 6
RESERVE_ENTRIES = 32
RESERVE_BYTES = 3145728

JQ_BIN_MAX = 8388608
VALIDATOR_TIMEOUT = 60
VALIDATOR_TERM_GRACE = 1

# The largest permitted object (a ledger.json blob), header included. Every
# object write and every loose-object/temporary file charges this amount
# against the inflated-bytes counter, matching the delivery ledger's design.
CHARGE_INFLATED = 1048589
# Raw (header + content) bytes above which any object or temporary file on
# disk is refused as corrupt, with slack for the decompression bound check.
MAX_RAW = 1114112
MAX_CONTENT = LEDGER_BYTES_MAX

# The two jq 1.6 release digests the validator itself pins
# (validate-trace-ledger.sh:74-75). A record's jq digest and the running jq
# digest are each accepted only when a member of this set (choice 7).
JQ_DIGESTS = frozenset((
    "5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef",
    "af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44",
))

ID_PATTERN = re.compile(r"[a-z0-9][a-z0-9._:-]{0,127}\Z")
OID_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
MEDIA_TYPE_PATTERN = re.compile(r"[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*\Z")

ROOT_NAMES = ("store.json",)
RECORD_NAMES = ("ledger.json", "record.json", "store.json", "validation.json")
CAPS = {"ledger.json": LEDGER_BYTES_MAX, "record.json": RECORD_DOC_MAX,
        "store.json": STORE_DOC_MAX, "validation.json": VALIDATOR_STDOUT_MAX}

HEAD_BYTES = b"ref: refs/heads/records\n"
CONFIG_BYTES = b"[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = true\n"
AUTHOR = b"ystack trace store <trace-store@invalid> 946684800 +0000"
MESSAGE = b"ystack trace store\n"

DIRECTORIES = {"", "repository.git", "repository.git/objects", "repository.git/refs",
               "repository.git/refs/heads"}
FIXED_FILES = {"store.lock", "repository.git/HEAD", "repository.git/config",
               "repository.git/refs/heads/records", "repository.git/refs/heads/records.lock"}

FORBIDDEN_ENV_PREFIXES = ("GIT_", "XDG_", "PYTHON", "LD_", "DYLD_")

# Raw mode-bit arithmetic in place of the `stat` module, which R2.5's import
# list does not include.
S_IFMT = 0o170000
S_IFDIR = 0o040000
S_IFREG = 0o100000
S_IFLNK = 0o120000


def is_dir(mode):
    return (mode & S_IFMT) == S_IFDIR


def is_reg(mode):
    return (mode & S_IFMT) == S_IFREG


def is_lnk(mode):
    return (mode & S_IFMT) == S_IFLNK


def mode_bits(mode):
    return mode & 0o7777


class Refusal(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def require(condition, code):
    if not condition:
        raise Refusal(code)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    data = (json.dumps(value, sort_keys=True, separators=(",", ":"),
                        ensure_ascii=True, allow_nan=False) + "\n").encode("ascii")
    for byte in data[:-1]:
        require(0x20 <= byte <= 0x7E, "E_RUNTIME")
    return data


def identifier(value, code="E_USAGE"):
    require(type(value) is str and ID_PATTERN.fullmatch(value) is not None, code)


def oid(value, code="E_USAGE"):
    require(type(value) is str and OID_PATTERN.fullmatch(value) is not None, code)


def sha256_field(value, code):
    require(type(value) is str and SHA256_PATTERN.fullmatch(value) is not None, code)


def integer(value, lower, upper, code):
    require(type(value) is int and lower <= value <= upper, code)


def fields(value, expected, code):
    require(type(value) is dict and set(value) == expected, code)


def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def bad_number(_value):
    raise ValueError("unsupported number")


def parse_integer(text):
    if len(text) > 10 or text.startswith("-"):
        raise ValueError("integer range")
    value = int(text)
    if value > 2147483647:
        raise ValueError("integer range")
    return value


def parse(data, cap, code):
    require(0 < len(data) <= cap, code)
    depth = 0
    quoted = False
    escaped = False
    for byte in data:
        require(byte < 128, code)
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
        elif byte == 34:
            quoted = True
        elif byte in (91, 123):
            depth += 1
            require(depth <= 16, code)
        elif byte in (93, 125):
            depth -= 1
            require(depth >= 0, code)
    try:
        value = json.loads(data.decode("ascii"), object_pairs_hook=pairs,
                            parse_int=parse_integer, parse_float=bad_number,
                            parse_constant=bad_number)
        require(canonical(value) == data, code)
        return value
    except (ValueError, UnicodeError, RecursionError, TypeError):
        raise Refusal(code) from None


# ---------------------------------------------------------------------------
# Path and file helpers
# ---------------------------------------------------------------------------

def ancestry(path):
    current = path
    while True:
        yield current
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent


def physical(path, code):
    require(type(path) is str and path.startswith("/") and os.path.normpath(path) == path, code)
    try:
        for component in ancestry(path):
            state = os.lstat(component)
            require(not is_lnk(state.st_mode), code)
    except OSError:
        raise Refusal(code) from None
    return path


def overlaps(first, second):
    return first == second or first.startswith(second + "/") or second.startswith(first + "/")


def fatal_close():
    try:
        os.write(2, b"E_RUNTIME\n")
    finally:
        os._exit(1)


def close_fd(descriptor):
    try:
        os.close(descriptor)
    except OSError:
        fatal_close()


def file_state(state, code):
    require(is_reg(state.st_mode) and state.st_uid == os.getuid() and
            mode_bits(state.st_mode) in (0o400, 0o500, 0o600), code)


def open_regular(path, code):
    before = os.lstat(path)
    file_state(before, code)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        after = os.fstat(descriptor)
        file_state(after, code)
        require((before.st_dev, before.st_ino) == (after.st_dev, after.st_ino), code)
        return descriptor, after
    except BaseException:
        close_fd(descriptor)
        raise


def read_file(path, cap, code):
    descriptor, state = open_regular(path, code)
    try:
        require(state.st_size <= cap, code)
        data = bytearray()
        while len(data) <= cap:
            block = os.read(descriptor, min(65536, cap + 1 - len(data)))
            if not block:
                break
            data.extend(block)
        require(len(data) <= cap and len(data) == state.st_size, code)
        return bytes(data)
    finally:
        close_fd(descriptor)


def read_source_file(path, cap, code):
    """Read a regular file we do not own or control the mode of (LEDGER,
    JQ_BIN, STORAGE_RECEIPT, the validator/program scripts, our own running
    source). No-follow, regular-file-only, size-capped; no uid or mode
    invariant is imposed since these files are not ours to enforce shape on.
    """
    try:
        before = os.lstat(path)
        require(is_reg(before.st_mode), code)
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError:
        raise Refusal(code) from None
    try:
        after = os.fstat(descriptor)
        require(is_reg(after.st_mode), code)
        require((before.st_dev, before.st_ino) == (after.st_dev, after.st_ino), code)
        require(after.st_size <= cap, code)
        data = bytearray()
        while len(data) <= cap:
            block = os.read(descriptor, min(65536, cap + 1 - len(data)))
            if not block:
                break
            data.extend(block)
        require(len(data) <= cap and len(data) == after.st_size, code)
        return bytes(data)
    finally:
        close_fd(descriptor)


def write_all(descriptor, data, code):
    offset = 0
    while offset < len(data):
        try:
            count = os.write(descriptor, data[offset:offset + 65536])
        except InterruptedError:
            continue
        require(type(count) is int and 0 < count <= min(65536, len(data) - offset), code)
        offset += count
    state = os.fstat(descriptor)
    require(is_reg(state.st_mode) and state.st_uid == os.getuid()
            and state.st_nlink == 1 and state.st_size == len(data), code)


def create_exclusive(path, mode):
    return os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                    os.O_NOFOLLOW | os.O_CLOEXEC, mode)


def write_closed(path, data, mode, code):
    descriptor = create_exclusive(path, mode)
    try:
        write_all(descriptor, data, code)
    finally:
        close_fd(descriptor)


def private_directory():
    for _attempt in range(32):
        candidate = "/tmp/ystack-trace-store." + os.urandom(12).hex()
        try:
            os.mkdir(candidate, 0o700)
        except FileExistsError:
            continue
        state = os.lstat(candidate)
        require(is_dir(state.st_mode) and not is_lnk(state.st_mode)
                and state.st_uid == os.getuid() and mode_bits(state.st_mode) == 0o700,
                "E_RUNTIME")
        return candidate
    raise Refusal("E_RUNTIME")


def remove_private_directory(path):
    try:
        for name in os.listdir(os.path.join(path, "bin")):
            try:
                os.unlink(os.path.join(path, "bin", name))
            except OSError:
                pass
        os.rmdir(os.path.join(path, "bin"))
    except OSError:
        pass
    for name in ("ledger.json", "read-ledger.json"):
        try:
            os.unlink(os.path.join(path, name))
        except OSError:
            pass
    try:
        os.rmdir(path)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Git object encode/decode (private writer, R8)
# ---------------------------------------------------------------------------

def decode_object(path, expected_oid):
    descriptor, state = open_regular(path, "E_CORRUPT")
    decoder = zlib.decompressobj()
    raw = bytearray()
    consumed = 0
    try:
        while True:
            compressed = os.read(descriptor, 65536)
            if not compressed:
                break
            consumed += len(compressed)
            require(not decoder.eof, "E_CORRUPT")
            pending = compressed
            while pending:
                prior = len(pending)
                fragment = decoder.decompress(pending, MAX_RAW + 1 - len(raw))
                raw.extend(fragment)
                require(len(raw) <= MAX_RAW, "E_CORRUPT")
                require(not decoder.unused_data, "E_CORRUPT")
                pending = decoder.unconsumed_tail
                require(not pending or fragment or len(pending) < prior, "E_CORRUPT")
        require(consumed == state.st_size and decoder.eof and not decoder.unused_data, "E_CORRUPT")
    except zlib.error:
        raise Refusal("E_CORRUPT") from None
    finally:
        close_fd(descriptor)
    separator = raw.find(0)
    require(0 < separator < 32, "E_CORRUPT")
    header = bytes(raw[:separator])
    match = re.fullmatch(rb"(blob|tree|commit) (0|[1-9][0-9]*)", header)
    require(match is not None, "E_CORRUPT")
    content = bytes(raw[separator + 1:])
    require(int(match.group(2)) == len(content) and len(content) <= MAX_CONTENT, "E_CORRUPT")
    require(hashlib.sha1(raw).hexdigest() == expected_oid, "E_CORRUPT")
    return match.group(1).decode("ascii"), content, len(raw)


def encode_object(kind, content):
    raw = kind.encode("ascii") + b" " + str(len(content)).encode("ascii") + b"\0" + content
    require(len(content) <= MAX_CONTENT and len(raw) <= MAX_RAW, "E_RUNTIME")
    compressor = zlib.compressobj()
    compressed = bytearray()
    for offset in range(0, len(raw), 65536):
        fragment = compressor.compress(raw[offset:offset + 65536])
        require(len(compressed) + len(fragment) <= len(raw) + 1024, "E_RUNTIME")
        compressed.extend(fragment)
    fragment = compressor.flush()
    require(len(compressed) + len(fragment) <= len(raw) + 1024, "E_RUNTIME")
    compressed.extend(fragment)
    return hashlib.sha1(raw).hexdigest(), bytes(compressed), len(raw)


def commit_bytes(tree, parent):
    result = b"tree " + tree.encode("ascii") + b"\n"
    if parent is not None:
        result += b"parent " + parent.encode("ascii") + b"\n"
    return result + b"author " + AUTHOR + b"\ncommitter " + AUTHOR + b"\n\n" + MESSAGE


def parse_commit(content):
    require(len(content) <= COMMIT_CONTENT_MAX, "E_CORRUPT")
    lines = content.split(b"\n")
    require(len(lines) in (6, 7) and lines[0].startswith(b"tree "), "E_CORRUPT")
    try:
        tree = lines[0][5:].decode("ascii")
        oid(tree, "E_CORRUPT")
        parent = None
        if len(lines) == 7:
            require(lines[1].startswith(b"parent "), "E_CORRUPT")
            parent = lines[1][7:].decode("ascii")
            oid(parent, "E_CORRUPT")
        require(commit_bytes(tree, parent) == content, "E_CORRUPT")
        return tree, parent
    except UnicodeError:
        raise Refusal("E_CORRUPT") from None


def tree_bytes(objects, names):
    return b"".join(b"100644 " + name.encode("ascii") + b"\0" + bytes.fromhex(objects[name])
                     for name in names)


def parse_tree(content, names):
    require(len(content) <= TREE_CONTENT_MAX, "E_CORRUPT")
    result = {}
    offset = 0
    for name in names:
        prefix = b"100644 " + name.encode("ascii") + b"\0"
        require(content[offset:offset + len(prefix)] == prefix, "E_CORRUPT")
        offset += len(prefix)
        require(len(content) - offset >= 20, "E_CORRUPT")
        result[name] = content[offset:offset + 20].hex()
        offset += 20
    require(offset == len(content), "E_CORRUPT")
    return result


def parse_root_tree(content):
    return parse_tree(content, ROOT_NAMES)


def parse_record_tree(content):
    return parse_tree(content, RECORD_NAMES)


# ---------------------------------------------------------------------------
# Replaceable step functions (a test wrapper may replace these, or the limit
# constants above, per R12.2; the shipped program never reads an override).
# ---------------------------------------------------------------------------

def snapshot_inputs(ledger_path, jq_path, private_dir):
    ledger_bytes = read_source_file(ledger_path, LEDGER_BYTES_MAX, "E_RUNTIME")
    ledger_sha = digest(ledger_bytes)
    write_closed(os.path.join(private_dir, "ledger.json"), ledger_bytes, 0o400, "E_RUNTIME")
    jq_bytes = read_source_file(jq_path, JQ_BIN_MAX, "E_RUNTIME")
    jq_sha = digest(jq_bytes)
    bin_dir = os.path.join(private_dir, "bin")
    os.mkdir(bin_dir, 0o700)
    jq_target = os.path.join(bin_dir, "jq")
    write_closed(jq_target, jq_bytes, 0o500, "E_RUNTIME")
    return ledger_bytes, ledger_sha, jq_target, jq_sha


def run_validator(validator_path, session_id, attempt_id, snapshot_path, private_dir, jq_dir):
    env = {"PATH": jq_dir + ":/usr/bin:/bin", "LC_ALL": "C", "HOME": "/dev/null"}
    try:
        child = subprocess.Popen(
            ["/bin/bash", validator_path, "validate", session_id, attempt_id, snapshot_path],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, cwd=private_dir, close_fds=True, start_new_session=True)
    except OSError:
        raise Refusal("E_RUNTIME") from None
    out_chunks = []
    err_chunks = []
    out_fd = child.stdout.fileno()
    err_fd = child.stderr.fileno()
    open_fds = {out_fd: out_chunks, err_fd: err_chunks}
    caps = {out_fd: VALIDATOR_STDOUT_MAX, err_fd: VALIDATOR_STDERR_MAX}
    overflow = {out_fd: False, err_fd: False}
    deadline = _clock() + VALIDATOR_TIMEOUT
    terminated = False
    killed = False
    try:
        while open_fds:
            remaining = deadline - _clock()
            if remaining <= 0:
                if not terminated:
                    _kill_group(child.pid, signal.SIGTERM)
                    terminated = True
                    deadline = _clock() + VALIDATOR_TERM_GRACE
                    continue
                if not killed:
                    _kill_group(child.pid, signal.SIGKILL)
                    killed = True
                remaining = 5
            ready, _, _ = select.select(list(open_fds), [], [], min(remaining, 1))
            for fd in ready:
                block = os.read(fd, 65536)
                if not block:
                    del open_fds[fd]
                    continue
                total = sum(len(chunk) for chunk in open_fds[fd]) + len(block)
                if total > caps[fd]:
                    overflow[fd] = True
                    del open_fds[fd]
                    continue
                open_fds[fd].append(block)
        status = child.wait(timeout=5)
    except (subprocess.TimeoutExpired, OSError):
        try:
            _kill_group(child.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            child.wait(timeout=5)
        except Exception:
            pass
        raise Refusal("E_RUNTIME") from None
    finally:
        try:
            child.stdout.close()
        except OSError:
            pass
        try:
            child.stderr.close()
        except OSError:
            pass
    require(not terminated and not killed, "E_RUNTIME")
    require(not overflow[out_fd] and not overflow[err_fd], "E_RUNTIME")
    stdout_bytes = b"".join(out_chunks)
    stderr_bytes = b"".join(err_chunks)
    if status == 0:
        require(not stderr_bytes, "E_RUNTIME")
        return stdout_bytes
    require(status == 1, "E_RUNTIME")
    require(not stdout_bytes, "E_RUNTIME")
    lines = stderr_bytes.split(b"\n")
    require(len(lines) == 2 and lines[1] == b"", "E_RUNTIME")
    try:
        line = lines[0].decode("ascii")
    except UnicodeError:
        raise Refusal("E_RUNTIME") from None
    require(line in ("E_USAGE", "E_RUNTIME", "E_LIMIT", "E_PARSE", "E_CANONICAL",
                      "E_SHAPE", "E_RELATION"), "E_RUNTIME")
    raise Refusal("E_INVALID:" + line)


def _clock():
    # R2.5 restricts imports to a fixed module list that excludes `time`;
    # os.times().elapsed is a monotonically increasing seconds counter
    # available without an extra import.
    return os.times().elapsed


def _kill_group(pid, sig):
    try:
        os.killpg(os.getpgid(pid), sig)
    except OSError:
        pass


def create_object_temporary(directory, compressed):
    descriptor = None
    temporary = None
    for _attempt in range(32):
        temporary = os.path.join(directory, "tmp_obj_" + os.urandom(12).hex())
        try:
            descriptor = create_exclusive(temporary, 0o600)
            break
        except FileExistsError:
            continue
    require(descriptor is not None, "E_RUNTIME")
    try:
        write_all(descriptor, compressed, "E_RUNTIME")
    finally:
        close_fd(descriptor)
    return temporary


def install_object(temporary, final):
    require(not os.path.lexists(final), "E_RUNTIME")
    os.rename(temporary, final)


def acquire_lock(descriptor):
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        if error.errno in (errno.EAGAIN, errno.EACCES):
            raise Refusal("E_BUSY") from None
        raise


def load_chain(store):
    return _load_chain_impl(store)


def create_ref_lock(path):
    return create_exclusive(path, 0o600)


def write_ref_lock(descriptor, commit_id):
    write_all(descriptor, (commit_id + "\n").encode("ascii"), "E_RUNTIME")


def install_ref_lock(temporary, final):
    os.replace(temporary, final)


def emit(data):
    offset = 0
    while offset < len(data):
        try:
            count = os.write(1, data[offset:offset + 65536])
        except InterruptedError:
            continue
        require(type(count) is int and 0 < count <= min(65536, len(data) - offset), "E_RUNTIME")
        offset += count


# ---------------------------------------------------------------------------
# Documents
# ---------------------------------------------------------------------------

def store_document(store_id):
    return {"schema_version": 1, "kind": "telemetry_trace_store", "id": store_id,
            "body": {"layout_version": 1,
                      "records_max": RECORDS_MAX,
                      "ledger_bytes_max": LEDGER_BYTES_MAX,
                      "validator_stdout_max": VALIDATOR_STDOUT_MAX,
                      "validator_stderr_max": VALIDATOR_STDERR_MAX,
                      "record_document_max": RECORD_DOC_MAX,
                      "store_document_max": STORE_DOC_MAX,
                      "tree_content_max": TREE_CONTENT_MAX,
                      "commit_content_max": COMMIT_CONTENT_MAX,
                      "object_files_max": OBJECT_FILES_MAX,
                      "filesystem_entries_max": FS_ENTRIES_MAX,
                      "regular_bytes_max": REGULAR_BYTES_MAX,
                      "inflated_bytes_max": INFLATED_BYTES_MAX,
                      "listing_bytes_max": LISTING_BYTES_MAX,
                      "reserve_object_files": RESERVE_FILES,
                      "reserve_entries": RESERVE_ENTRIES,
                      "reserve_bytes": RESERVE_BYTES}}


STORE_BODY_FIELDS = {"layout_version", "records_max", "ledger_bytes_max", "validator_stdout_max",
                      "validator_stderr_max", "record_document_max", "store_document_max",
                      "tree_content_max", "commit_content_max", "object_files_max",
                      "filesystem_entries_max", "regular_bytes_max", "inflated_bytes_max",
                      "listing_bytes_max", "reserve_object_files", "reserve_entries",
                      "reserve_bytes"}


def validate_store_document(doc, code="E_CORRUPT"):
    fields(doc, {"schema_version", "kind", "id", "body"}, code)
    require(doc["schema_version"] == 1 and doc["kind"] == "telemetry_trace_store", code)
    identifier(doc["id"], code)
    body = doc["body"]
    fields(body, STORE_BODY_FIELDS, code)
    require(body == store_document(doc["id"])["body"], code)


def content_ref(content_id, media_type, sha256):
    return {"content_id": content_id, "media_type": media_type, "sha256": sha256}


def validate_content_ref(value, code):
    fields(value, {"content_id", "media_type", "sha256"}, code)
    identifier(value["content_id"], code)
    require(type(value["media_type"]) is str and
            MEDIA_TYPE_PATTERN.fullmatch(value["media_type"]) is not None, code)
    sha256_field(value["sha256"], code)


def replay_key_document(session_id, attempt_id, final_digest):
    return {"session_id": session_id, "attempt_id": attempt_id, "final_digest": final_digest}


def record_key_of(replay_key):
    return digest(canonical({"attempt_id": replay_key["attempt_id"],
                              "final_digest": replay_key["final_digest"],
                              "session_id": replay_key["session_id"]}))


def validator_document(validator_sha, program_sha, jq_sha):
    return {"validator_sha256": validator_sha, "program_sha256": program_sha,
            "jq_sha256": jq_sha, "jq_version": "jq-1.6"}


def validate_validator_document(value, code):
    fields(value, {"validator_sha256", "program_sha256", "jq_sha256", "jq_version"}, code)
    sha256_field(value["validator_sha256"], code)
    sha256_field(value["program_sha256"], code)
    sha256_field(value["jq_sha256"], code)
    require(value["jq_version"] == "jq-1.6", code)


def record_document(store_id, record_key, replay_key, event_count, ledger_ref,
                     ledger_bytes_len, validation_sha256, validator, store_package_sha256):
    return {"schema_version": 1, "kind": "telemetry_trace_store_record",
            "id": "trace-record." + record_key,
            "body": {"activation_state": "inactive", "authority_effect": "none",
                      "store_id": store_id, "record_key": record_key,
                      "replay_key": replay_key, "event_count": event_count,
                      "ledger_ref": ledger_ref, "ledger_bytes": ledger_bytes_len,
                      "validation_sha256": validation_sha256, "validator": validator,
                      "store_package_sha256": store_package_sha256}}


RECORD_BODY_FIELDS = {"activation_state", "authority_effect", "store_id", "record_key",
                       "replay_key", "event_count", "ledger_ref", "ledger_bytes",
                       "validation_sha256", "validator", "store_package_sha256"}


def validate_record_document(doc, store_id, ledger_bytes, validation_bytes, code="E_CORRUPT"):
    fields(doc, {"schema_version", "kind", "id", "body"}, code)
    require(doc["schema_version"] == 1 and doc["kind"] == "telemetry_trace_store_record", code)
    body = doc["body"]
    fields(body, RECORD_BODY_FIELDS, code)
    require(body["activation_state"] == "inactive" and body["authority_effect"] == "none", code)
    require(body["store_id"] == store_id, code)
    replay_key = body["replay_key"]
    fields(replay_key, {"session_id", "attempt_id", "final_digest"}, code)
    identifier(replay_key["session_id"], code)
    identifier(replay_key["attempt_id"], code)
    sha256_field(replay_key["final_digest"], code)
    require(body["record_key"] == record_key_of(replay_key), code)
    require(doc["id"] == "trace-record." + body["record_key"], code)
    integer(body["event_count"], 0, 256, code)
    validate_content_ref(body["ledger_ref"], code)
    require(body["ledger_ref"]["sha256"] == digest(ledger_bytes), code)
    integer(body["ledger_bytes"], 0, LEDGER_BYTES_MAX, code)
    require(body["ledger_bytes"] == len(ledger_bytes), code)
    require(body["validation_sha256"] == digest(validation_bytes), code)
    validate_validator_document(body["validator"], code)
    sha256_field(body["store_package_sha256"], code)
    return body


def storage_receipt_document(store_id, root_commit, commit_id, record_key, replay_key,
                              record_sha256, ledger_ref, validation_sha256, validator):
    return {"schema_version": 1, "kind": "telemetry_trace_storage_receipt",
            "id": "trace-record." + record_key,
            "body": {"activation_state": "inactive", "authority_effect": "none",
                      "storage_effect": "append-only",
                      "store": {"id": store_id, "root_commit": root_commit},
                      "commit_id": commit_id, "record_key": record_key,
                      "replay_key": replay_key, "record_sha256": record_sha256,
                      "ledger_ref": ledger_ref, "validation_sha256": validation_sha256,
                      "validator": validator}}


RECEIPT_BODY_FIELDS = {"activation_state", "authority_effect", "storage_effect", "store",
                        "commit_id", "record_key", "replay_key", "record_sha256",
                        "ledger_ref", "validation_sha256", "validator"}


def validate_receipt_document(doc, code):
    fields(doc, {"schema_version", "kind", "id", "body"}, code)
    require(doc["schema_version"] == 1 and doc["kind"] == "telemetry_trace_storage_receipt", code)
    body = doc["body"]
    fields(body, RECEIPT_BODY_FIELDS, code)
    require(body["activation_state"] == "inactive" and body["authority_effect"] == "none"
            and body["storage_effect"] == "append-only", code)
    store = body["store"]
    fields(store, {"id", "root_commit"}, code)
    identifier(store["id"], code)
    oid(store["root_commit"], code)
    oid(body["commit_id"], code)
    replay_key = body["replay_key"]
    fields(replay_key, {"session_id", "attempt_id", "final_digest"}, code)
    identifier(replay_key["session_id"], code)
    identifier(replay_key["attempt_id"], code)
    sha256_field(replay_key["final_digest"], code)
    require(body["record_key"] == record_key_of(replay_key), code)
    require(doc["id"] == "trace-record." + body["record_key"], code)
    sha256_field(body["record_sha256"], code)
    validate_content_ref(body["ledger_ref"], code)
    sha256_field(body["validation_sha256"], code)
    validate_validator_document(body["validator"], code)
    return body


def read_document(receipt_sha256, ledger_ref, validation_sha256, tip, record_key):
    return {"schema_version": 1, "kind": "telemetry_trace_store_read",
            "id": "trace-record." + record_key,
            "body": {"storage_receipt_sha256": receipt_sha256, "ledger_ref": ledger_ref,
                      "validation_sha256": validation_sha256, "tip": tip}}


def listing_document(store_id, root_commit, tip, entries):
    return {"schema_version": 1, "kind": "telemetry_trace_store_listing", "id": store_id,
            "body": {"store": {"id": store_id, "root_commit": root_commit}, "tip": tip,
                      "record_count": len(entries), "records": entries}}


# ---------------------------------------------------------------------------
# Store
# ---------------------------------------------------------------------------

def source_root():
    source = os.path.realpath(__file__)
    return os.path.dirname(os.path.dirname(os.path.dirname(source)))


def source_package_sha256():
    data = read_source_file(os.path.realpath(__file__), 1 << 20, "E_RUNTIME")
    return digest(data)


class Store:
    def __init__(self, root):
        self.root = physical(root, "E_BOUNDARY")
        require(not overlaps(self.root, source_root()), "E_BOUNDARY")
        parent = os.path.dirname(self.root)
        for ancestor in ancestry(parent):
            require(not os.path.lexists(os.path.join(ancestor, ".git")), "E_BOUNDARY")
        state = os.lstat(self.root)
        require(is_dir(state.st_mode) and state.st_uid == os.getuid()
                and mode_bits(state.st_mode) == 0o700, "E_BOUNDARY")
        self.lock = None
        self.fresh = False
        self.objects = {}
        self.totals = [0, 0, 0, 0]
        self.tip = None
        self.root_commit = None
        self.store_id = None
        self.store_json_oid = None
        self.records = []
        self.replay_index = {}
        self.reservation_start = None

    def path(self, relative):
        return os.path.join(self.root, relative) if relative else self.root

    def acquire(self, verb):
        lock_path = self.path("store.lock")
        if not os.path.lexists(lock_path):
            require(verb == "initialize", "E_INCOMPLETE")
            with os.scandir(self.root) as entries:
                require(next(entries, None) is None, "E_BOUNDARY")
            descriptor = create_exclusive(lock_path, 0o600)
            self.fresh = True
        else:
            descriptor = os.open(lock_path, os.O_RDWR | os.O_NOFOLLOW |
                                  os.O_NONBLOCK | os.O_CLOEXEC)
            self.fresh = False
        self.lock = descriptor
        state = os.fstat(descriptor)
        require(is_reg(state.st_mode) and state.st_uid == os.getuid(), "E_CORRUPT")
        require(mode_bits(state.st_mode) == 0o600 and state.st_size == 0, "E_CORRUPT")
        before = os.lstat(lock_path)
        require((state.st_dev, state.st_ino) == (before.st_dev, before.st_ino), "E_CORRUPT")
        acquire_lock(descriptor)

    def release(self):
        if self.lock is not None:
            descriptor = self.lock
            self.lock = None
            close_fd(descriptor)

    def check_totals(self):
        require(self.totals[0] <= OBJECT_FILES_MAX and self.totals[1] <= FS_ENTRIES_MAX
                and self.totals[2] <= REGULAR_BYTES_MAX
                and self.totals[3] <= INFLATED_BYTES_MAX, "E_CORRUPT")

    def inventory(self):
        self.objects = {}
        self.totals = [0, 0, 0, 0]
        present = set()
        stack = [("", 0)]
        while stack:
            relative, depth = stack.pop()
            require(depth <= 5, "E_CORRUPT")
            path = self.path(relative)
            state = os.lstat(path)
            self.totals[1] += 1
            self.check_totals()
            require(state.st_uid == os.getuid(), "E_CORRUPT")
            present.add(relative)
            if is_dir(state.st_mode):
                fanout = re.fullmatch(r"repository\.git/objects/[0-9a-f]{2}", relative)
                require(relative in DIRECTORIES or fanout is not None, "E_CORRUPT")
                require(mode_bits(state.st_mode) == 0o700, "E_CORRUPT")
                with os.scandir(path) as entries:
                    for entry in entries:
                        require(len(stack) + self.totals[1] < FS_ENTRIES_MAX + 1, "E_CORRUPT")
                        child = relative + "/" + entry.name if relative else entry.name
                        stack.append((child, depth + 1))
                continue
            require(is_reg(state.st_mode) and state.st_uid == os.getuid(), "E_CORRUPT")
            self.totals[2] += state.st_size
            self.check_totals()
            parts = relative.split("/")
            if relative in FIXED_FILES:
                require(mode_bits(state.st_mode) == 0o600, "E_CORRUPT")
                cap = MAX_RAW if relative.endswith("records.lock") else 256
                require(state.st_size <= cap, "E_CORRUPT")
                if relative == "store.lock":
                    require(state.st_size == 0, "E_CORRUPT")
                continue
            require(len(parts) == 4 and parts[:2] == ["repository.git", "objects"]
                    and re.fullmatch(r"[0-9a-f]{2}", parts[2]) is not None, "E_CORRUPT")
            self.totals[0] += 1
            if re.fullmatch(r"tmp_obj_[0-9a-f]{24}", parts[3]):
                require(state.st_size <= MAX_RAW, "E_CORRUPT")
                self.totals[3] += CHARGE_INFLATED
            else:
                require(re.fullmatch(r"[0-9a-f]{38}", parts[3]) is not None, "E_CORRUPT")
                object_id = parts[2] + parts[3]
                kind, content, raw_size = decode_object(path, object_id)
                self.totals[3] += raw_size
                self.objects[object_id] = (kind, content)
            self.check_totals()
        return present

    def load_object(self, object_id, kind, cap):
        require(object_id in self.objects, "E_CORRUPT")
        actual_kind, content = self.objects[object_id]
        require(actual_kind == kind and len(content) <= cap, "E_CORRUPT")
        return content

    def current_ref(self, absent):
        path = self.path("repository.git/refs/heads/records")
        if not os.path.lexists(path):
            require(absent, "E_CORRUPT")
            return None
        raw = read_file(path, 41, "E_CORRUPT")
        require(re.fullmatch(rb"[0-9a-f]{40}\n", raw) is not None, "E_CORRUPT")
        return raw[:-1].decode("ascii")

    def build(self):
        """Load and fully validate the chain. Returns True if a store is
        published (ref exists), False if the root is empty of everything but
        store.lock (an uninitialized-but-locked root)."""
        present = self.inventory()
        if present == {""} or present == {"", "store.lock"}:
            return False
        require(DIRECTORIES.issubset(present) and
                {"repository.git/HEAD", "repository.git/config",
                 "repository.git/refs/heads/records"}.issubset(present), "E_INCOMPLETE")
        require(read_file(self.path("repository.git/HEAD"), 256, "E_CORRUPT") == HEAD_BYTES,
                "E_CORRUPT")
        require(read_file(self.path("repository.git/config"), 256, "E_CORRUPT") == CONFIG_BYTES,
                "E_CORRUPT")
        self.tip = self.current_ref(absent=False)
        commits = []
        seen = set()
        current = self.tip
        while current is not None:
            require(current not in seen and len(commits) < RECORDS_MAX + 2, "E_CORRUPT")
            seen.add(current)
            tree, parent = parse_commit(self.load_object(current, "commit", COMMIT_CONTENT_MAX))
            commits.append((current, tree, parent))
            current = parent
        self.root_commit = commits[-1][0]
        require(commits[-1][2] is None, "E_CORRUPT")
        records = []
        replay_index = {}
        prior_commit = None
        for index, (commit, tree, parent) in enumerate(reversed(commits)):
            if index == 0:
                require(parent is None, "E_CORRUPT")
                members = parse_root_tree(self.load_object(tree, "tree", TREE_CONTENT_MAX))
                store_doc = parse(self.load_object(members["store.json"], "blob", STORE_DOC_MAX),
                                   STORE_DOC_MAX, "E_CORRUPT")
                validate_store_document(store_doc)
                self.store_id = store_doc["id"]
                self.store_json_oid = members["store.json"]
            else:
                require(parent == prior_commit, "E_CORRUPT")
                members = parse_record_tree(self.load_object(tree, "tree", TREE_CONTENT_MAX))
                require(members["store.json"] == self.store_json_oid, "E_CORRUPT")
                record_doc = parse(self.load_object(members["record.json"], "blob", RECORD_DOC_MAX),
                                    RECORD_DOC_MAX, "E_CORRUPT")
                ledger_bytes = self.load_object(members["ledger.json"], "blob", LEDGER_BYTES_MAX)
                validation_bytes = self.load_object(members["validation.json"], "blob",
                                                     VALIDATOR_STDOUT_MAX)
                body = validate_record_document(record_doc, self.store_id, ledger_bytes,
                                                 validation_bytes)
                key = (body["replay_key"]["session_id"], body["replay_key"]["attempt_id"],
                       body["replay_key"]["final_digest"])
                require(key not in replay_index, "E_CORRUPT")
                record = {
                    "commit_id": commit,
                    "record_key": body["record_key"],
                    "replay_key": body["replay_key"],
                    "event_count": body["event_count"],
                    "ledger_ref": body["ledger_ref"],
                    "validation_sha256": body["validation_sha256"],
                    "validator": body["validator"],
                    "ledger_bytes": ledger_bytes,
                    "validation_bytes": validation_bytes,
                    "record_bytes": canonical(record_doc),
                }
                replay_index[key] = record
                records.append(record)
            prior_commit = commit
        self.records = records
        self.replay_index = replay_index
        return True

    # -- capacity bookkeeping -------------------------------------------------

    def reserve(self):
        require(len(self.records) < RECORDS_MAX, "E_CAPACITY")
        reserve_amounts = (RESERVE_FILES, RESERVE_ENTRIES, RESERVE_BYTES, RESERVE_BYTES)
        hard_caps = (OBJECT_FILES_MAX, FS_ENTRIES_MAX, REGULAR_BYTES_MAX, INFLATED_BYTES_MAX)
        for total, extra, cap in zip(self.totals, reserve_amounts, hard_caps):
            require(total + extra <= cap, "E_CAPACITY")
        self.reservation_start = tuple(self.totals)

    def charge(self, files=0, entries=0, regular=0, inflated=0):
        additions = (files, entries, regular, inflated)
        self.totals = [old + added for old, added in zip(self.totals, additions)]
        self.check_totals()
        require(self.reservation_start is not None, "E_RUNTIME")
        reserve_amounts = (RESERVE_FILES, RESERVE_ENTRIES, RESERVE_BYTES, RESERVE_BYTES)
        require(all(current - start <= allowed for current, start, allowed in
                    zip(self.totals, self.reservation_start, reserve_amounts)), "E_CAPACITY")

    def directory(self, relative):
        path = self.path(relative)
        if os.path.lexists(path):
            state = os.lstat(path)
            require(is_dir(state.st_mode) and state.st_uid == os.getuid()
                    and mode_bits(state.st_mode) == 0o700, "E_CORRUPT")
            return
        self.charge(entries=1)
        os.mkdir(path, 0o700)
        state = os.lstat(path)
        require(mode_bits(state.st_mode) == 0o700 and is_dir(state.st_mode), "E_RUNTIME")

    def initialize_layout(self):
        for relative in ("repository.git", "repository.git/objects", "repository.git/refs",
                          "repository.git/refs/heads"):
            self.directory(relative)
        for relative, data in (("repository.git/HEAD", HEAD_BYTES),
                                ("repository.git/config", CONFIG_BYTES)):
            self.charge(entries=1, regular=len(data))
            write_closed(self.path(relative), data, 0o600, "E_RUNTIME")

    def write_object(self, kind, content):
        object_id, compressed, raw_size = encode_object(kind, content)
        relative = "repository.git/objects/" + object_id[:2]
        final = self.path(relative + "/" + object_id[2:])
        if os.path.lexists(final):
            old_kind, old_content, _ = decode_object(final, object_id)
            require(old_kind == kind and old_content == content, "E_CORRUPT")
            return object_id
        self.directory(relative)
        self.charge(files=1, entries=1, regular=len(compressed), inflated=CHARGE_INFLATED)
        temporary = create_object_temporary(self.path(relative), compressed)
        install_object(temporary, final)
        self.totals[3] += raw_size - CHARGE_INFLATED
        return object_id

    def publish(self, store_id_doc_oid, record_doc, validation_bytes, ledger_bytes, parent):
        record_data = canonical(record_doc)
        validation_data = validation_bytes
        ledger_data = ledger_bytes
        require(len(record_data) <= RECORD_DOC_MAX, "E_RUNTIME")
        require(len(validation_data) <= VALIDATOR_STDOUT_MAX, "E_RUNTIME")
        require(len(ledger_data) <= LEDGER_BYTES_MAX, "E_RUNTIME")
        ledger_oid = self.write_object("blob", ledger_data)
        record_oid = self.write_object("blob", record_data)
        validation_oid = self.write_object("blob", validation_data)
        members = {"ledger.json": ledger_oid, "record.json": record_oid,
                   "store.json": store_id_doc_oid, "validation.json": validation_oid}
        tree = self.write_object("tree", tree_bytes(members, RECORD_NAMES))
        commit = self.write_object("commit", commit_bytes(tree, parent))
        saved_start = self.reservation_start
        self.inventory()
        self.reservation_start = saved_start
        lock_path = self.path("repository.git/refs/heads/records.lock")
        require(not os.path.lexists(lock_path), "E_LOCKED")
        self.charge(entries=1, regular=41)
        descriptor = create_ref_lock(lock_path)
        try:
            require(self.current_ref(absent=False) == parent, "E_STALE")
            write_ref_lock(descriptor, commit)
        finally:
            close_fd(descriptor)
        install_ref_lock(lock_path, self.path("repository.git/refs/heads/records"))
        return commit, record_data


# ---------------------------------------------------------------------------
# Verb boundary checks and implementations
# ---------------------------------------------------------------------------

def check_append_boundary(store, scratch_root, ledger):
    scratch = physical(scratch_root, "E_BOUNDARY")
    require(not overlaps(store.root, scratch), "E_BOUNDARY")
    ledger_path = physical(ledger, "E_BOUNDARY")
    require(ledger_path.startswith(scratch + "/"), "E_BOUNDARY")
    state = os.lstat(ledger_path)
    require(is_reg(state.st_mode), "E_BOUNDARY")


def _load_chain_impl(store):
    return store.build()


def do_initialize(store, store_id):
    store.acquire("initialize")
    if not store.fresh:
        # store.lock pre-existed: either a stale unpublished attempt (K7,
        # permanently E_INCOMPLETE) or a store that already exists here
        # (E_BOUNDARY). Either way this call never builds anything.
        published = load_chain(store)
        raise Refusal("E_BOUNDARY" if published else "E_INCOMPLETE")
    doc = store_document(store_id)
    store.reservation_start = (0, 0, 0, 0)
    store.initialize_layout()
    encoded = canonical(doc)
    require(len(encoded) <= STORE_DOC_MAX, "E_RUNTIME")
    store_oid = store.write_object("blob", encoded)
    tree = store.write_object("tree", tree_bytes({"store.json": store_oid}, ROOT_NAMES))
    commit = store.write_object("commit", commit_bytes(tree, None))
    lock_path = store.path("repository.git/refs/heads/records.lock")
    require(not os.path.lexists(lock_path), "E_LOCKED")
    store.charge(entries=1, regular=41)
    descriptor = create_ref_lock(lock_path)
    try:
        require(store.current_ref(absent=True) is None, "E_STALE")
        write_ref_lock(descriptor, commit)
    finally:
        close_fd(descriptor)
    install_ref_lock(lock_path, store.path("repository.git/refs/heads/records"))
    return listing_document(store_id, commit, commit, [])


def do_append(store, store_id, expected_tip, scratch_root, jq_bin, session_id, attempt_id, ledger):
    raise Refusal("E_RUNTIME")  # not yet built at this commit


def do_read(store, jq_bin, receipt_path, output_path):
    raise Refusal("E_RUNTIME")  # not yet built at this commit


def do_list(store, store_id):
    store.acquire("list")
    published = load_chain(store)
    require(published, "E_INCOMPLETE")
    require(store.store_id == store_id, "E_IDENTITY")
    entries = []
    for record in store.records:
        entries.append({
            "record_key": record["record_key"],
            "replay_key": record["replay_key"],
            "event_count": record["event_count"],
            "commit_id": record["commit_id"],
            "record_sha256": digest(record["record_bytes"]),
            "ledger_ref": {"sha256": record["ledger_ref"]["sha256"]},
        })
    entries.sort(key=lambda entry: (entry["replay_key"]["session_id"],
                                     entry["replay_key"]["attempt_id"],
                                     entry["replay_key"]["final_digest"]))
    require(len(entries) <= RECORDS_MAX, "E_CORRUPT")
    doc = listing_document(store.store_id, store.root_commit, store.tip, entries)
    require(len(canonical(doc)) <= LISTING_BYTES_MAX, "E_CORRUPT")
    return doc


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(argv):
    store = None
    try:
        require(sys.flags.isolated and sys.flags.no_site and sys.flags.dont_write_bytecode,
                "E_RUNTIME")
        for name in os.environ:
            require(not any(name.startswith(prefix) for prefix in FORBIDDEN_ENV_PREFIXES),
                    "E_USAGE")
        require(len(argv) >= 2, "E_USAGE")
        verb = argv[1]
        require(verb in ("initialize", "append", "read", "list"), "E_USAGE")
        os.umask(0o077)
        if verb == "initialize":
            require(len(argv) == 4, "E_USAGE")
            store_root, store_id = argv[2], argv[3]
            identifier(store_id)
            store = Store(store_root)
            result = do_initialize(store, store_id)
        elif verb == "append":
            require(len(argv) == 10, "E_USAGE")
            store_root, store_id, expected_tip, scratch_root, jq_bin, session_id, attempt_id, \
                ledger = argv[2:10]
            identifier(store_id)
            oid(expected_tip)
            identifier(session_id)
            identifier(attempt_id)
            store = Store(store_root)
            check_append_boundary(store, scratch_root, ledger)
            result = do_append(store, store_id, expected_tip, scratch_root, jq_bin, session_id,
                                attempt_id, ledger)
        elif verb == "read":
            require(len(argv) == 6, "E_USAGE")
            store_root, jq_bin, receipt_path, output_path = argv[2:6]
            store = Store(store_root)
            result = do_read(store, jq_bin, receipt_path, output_path)
        else:
            require(len(argv) == 4, "E_USAGE")
            store_root, store_id = argv[2], argv[3]
            identifier(store_id)
            store = Store(store_root)
            result = do_list(store, store_id)
        encoded = canonical(result)
        emit(encoded)
        return 0
    except Refusal as error:
        code = error.code
    except (OSError, ValueError, UnicodeError, RecursionError):
        code = "E_RUNTIME"
    finally:
        if store is not None:
            store.release()
    try:
        os.write(2, (code + "\n").encode("ascii"))
    except OSError:
        pass
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
