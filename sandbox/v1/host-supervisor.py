#!/usr/bin/env python3
"""host-supervisor.py -- VM launcher and supervisor, host half (ystack #463).
PR 3 of 9: the R10.1 ACL walk, host configuration, the store root (R2.3 of
work/enforcement-evidence-binding/spec.md), package/request phase A (R3,
R4.1), the R10.2 store writer and R10.3 receipt/outcome. Until PR 5 an
admitted attempt ends at one stub receipt: the runtime never started. See
work/vm-launcher-supervisor/spec.md. Inactive: no hypervisor invocation, no
installation, no network, no sudo; this launches nothing.

Also exposes frame-write/frame-read/digest, matching
scripts/test/sandbox-guest-harness.c's own subcommands, so the test suite
can cross-check this module's YSFRAME1 codec against the guest's C one.
"""
import ctypes
import ctypes.util
import errno
import hashlib
import json
import os
import stat
import sys
import time

# --- canonical JSON, matching preparation/v1/prepare-candidate.py:281-284 --
def canonical(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True,
                        separators=(",", ":"), allow_nan=False).encode("utf-8") + b"\n")


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


ALL_ONES = "f" * 64
ALL_ZEROS = "0" * 64


def placeholder(value):
    return value in (ALL_ONES, ALL_ZEROS)


class Refusal(Exception):
    """A phase A error: exit 65 with `code` alone on stderr, nothing in the store."""
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def refuse(code):
    raise Refusal(code)


def require(condition, code):
    if not condition:
        refuse(code)


# --- YSFRAME1 (R3.2): shared wire format with the guest's common.c -------
FRAME_MAGIC = b"YSFRAME1"
FRAME_END = b"end"


class FrameError(Exception):
    pass


def frame_write(records):
    """records: [(name: bytes, content: bytes)]; returns the full frame bytes."""
    out = bytearray(FRAME_MAGIC)
    digest = hashlib.sha256(FRAME_MAGIC)
    for name, content in records:
        if len(name) > 255 or name == FRAME_END:
            raise FrameError("E_FRAME_NAME")
        header = bytes([len(name)]) + name + len(content).to_bytes(8, "big")
        out += header
        out += content
        digest.update(header)
        digest.update(content)
    out += bytes([len(FRAME_END)]) + FRAME_END + (32).to_bytes(8, "big") + digest.digest()
    return bytes(out)


def frame_read(data):
    """Returns [(name: bytes, content: bytes)] (no "end"); raises FrameError."""
    n = len(data)
    if n < len(FRAME_MAGIC):
        raise FrameError("E_FRAME_TRUNCATED")
    if data[:len(FRAME_MAGIC)] != FRAME_MAGIC:
        raise FrameError("E_FRAME_MAGIC")
    pos = len(FRAME_MAGIC)
    digest = hashlib.sha256(FRAME_MAGIC)
    records = []
    while True:
        if pos + 1 > n:
            raise FrameError("E_FRAME_TRUNCATED")
        name_len = data[pos]
        if pos + 1 + name_len > n:
            raise FrameError("E_FRAME_TRUNCATED")
        name = data[pos + 1:pos + 1 + name_len]
        if pos + 1 + name_len + 8 > n:
            raise FrameError("E_FRAME_TRUNCATED")
        len_field = data[pos + 1 + name_len:pos + 1 + name_len + 8]
        length = int.from_bytes(len_field, "big")
        content_off = pos + 1 + name_len + 8
        if length > n - content_off:
            raise FrameError("E_FRAME_TRUNCATED")
        if name == FRAME_END:
            if length != 32:
                raise FrameError("E_FRAME_DIGEST")
            if data[content_off:content_off + 32] != digest.digest():
                raise FrameError("E_FRAME_DIGEST")
            if any(b != 0 for b in data[content_off + 32:]):
                raise FrameError("E_FRAME_TAIL")
            return records
        content = data[content_off:content_off + length]
        header = bytes([name_len]) + name + len_field
        digest.update(header)
        digest.update(content)
        records.append((name, content))
        pos = content_off + length


# --- R3.3 package record-name set: fixed names in order, then candidate/<n> -
PACKAGE_FIXED = (b"request.json", b"evaluation.json", b"incident.json",
                  b"record.json", b"manifest.json", b"instruction")


def parse_package(data):
    try:
        records = frame_read(data)
    except FrameError:
        refuse("E_PACKAGE")
    if len(records) < len(PACKAGE_FIXED):
        refuse("E_PACKAGE")
    for i, fixed in enumerate(PACKAGE_FIXED):
        if records[i][0] != fixed:
            refuse("E_PACKAGE")
    candidates = []
    for i in range(len(PACKAGE_FIXED), len(records)):
        expected = ("candidate/%05d" % (i - len(PACKAGE_FIXED))).encode()
        if records[i][0] != expected:
            refuse("E_PACKAGE")
        candidates.append(records[i][1])
    named = {name.decode(): content for name, content in records[:len(PACKAGE_FIXED)]}
    named["candidate"] = candidates
    return named


# --- macOS ACL (R10.1, R10.2): acl_get_fd_np(ACL_TYPE_EXTENDED) via ctypes -
ACL_TYPE_EXTENDED = 0x100
ACL_FIRST_ENTRY, ACL_NEXT_ENTRY = 0, 1
ACL_EXTENDED_ALLOW = 1
ID_TYPE_UID = 0
# WRITE_DATA|APPEND_DATA|DELETE|DELETE_CHILD|WRITE_ATTRIBUTES|WRITE_EXTATTRIBUTES|
# WRITE_SECURITY|CHANGE_OWNER (bits 2,4,5,6,8,10,12,13); read/execute bits excluded.
DARWIN_DANGEROUS_BITS = (1 << 2) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 8) | (1 << 10) | (1 << 12) | (1 << 13)

_libc = None


def _darwin_libc():
    global _libc
    if _libc is not None:
        return _libc
    lib = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    lib.acl_get_fd_np.restype = ctypes.c_void_p
    lib.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    lib.acl_get_entry.restype = ctypes.c_int
    lib.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    lib.acl_get_tag_type.restype = ctypes.c_int
    lib.acl_get_tag_type.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    lib.acl_get_qualifier.restype = ctypes.c_void_p
    lib.acl_get_qualifier.argtypes = [ctypes.c_void_p]
    lib.acl_get_permset.restype = ctypes.c_int
    lib.acl_get_permset.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
    lib.acl_get_perm_np.restype = ctypes.c_int
    lib.acl_get_perm_np.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    lib.acl_free.restype = ctypes.c_int
    lib.acl_free.argtypes = [ctypes.c_void_p]
    lib.mbr_uuid_to_id.restype = ctypes.c_int
    lib.mbr_uuid_to_id.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_int)]
    _libc = lib
    return lib


def darwin_acl_entries(fd):
    """[(tag, id_type_or_None, id_or_None, perm_bits)]; None id means the
    qualifier's GUID could not be resolved to a uid/gid (treated as "some
    other principal" by every caller). Raises OSError if the ACL itself
    cannot be read (a real error, not simply "no ACL present")."""
    lib = _darwin_libc()
    ctypes.set_errno(0)
    acl = lib.acl_get_fd_np(fd, ACL_TYPE_EXTENDED)
    if not acl:
        err = ctypes.get_errno()
        if err == errno.ENOENT:
            return []
        raise OSError(err, "acl_get_fd_np")
    entries = []
    try:
        entry = ctypes.c_void_p()
        rc = lib.acl_get_entry(acl, ACL_FIRST_ENTRY, ctypes.byref(entry))
        while rc == 0:
            tag = ctypes.c_int()
            lib.acl_get_tag_type(entry, ctypes.byref(tag))
            id_type, id_value = None, None
            qual = lib.acl_get_qualifier(entry)
            if qual:
                guid = ctypes.string_at(qual, 16)
                idbuf, typebuf = ctypes.c_uint32(), ctypes.c_int()
                if lib.mbr_uuid_to_id(guid, ctypes.byref(idbuf), ctypes.byref(typebuf)) == 0:
                    id_type, id_value = typebuf.value, idbuf.value
            permset = ctypes.c_void_p()
            lib.acl_get_permset(entry, ctypes.byref(permset))
            bits = 0
            for shift in range(1, 14):
                bit = 1 << shift
                if lib.acl_get_perm_np(permset, bit):
                    bits |= bit
            entries.append((tag.value, id_type, id_value, bits))
            rc = lib.acl_get_entry(acl, ACL_NEXT_ENTRY, ctypes.byref(entry))
    finally:
        lib.acl_free(acl)
    return entries


def darwin_install_acl_ok(entries, principal_uid):
    for tag, id_type, id_value, bits in entries:
        if tag != ACL_EXTENDED_ALLOW or bits & DARWIN_DANGEROUS_BITS == 0:
            continue
        if id_type == ID_TYPE_UID and id_value in (0, principal_uid):
            continue
        return False
    return True


# --- Linux POSIX.1e ACL xattrs (R10.1): named entries or a write mask fail -
LINUX_ACL_USER, LINUX_ACL_GROUP, LINUX_ACL_MASK = 0x02, 0x08, 0x10
LINUX_ACL_WRITE = 0x02


def linux_read_acl_xattr(fd, name):
    try:
        return os.getxattr(fd, name)
    except OSError as exc:
        if exc.errno in (errno.ENODATA, errno.ENOTSUP, errno.EOPNOTSUPP, errno.ERANGE):
            return None
        raise


def linux_acl_ok(xattr_bytes):
    """Any named-user/named-group entry fails outright (R10.1 is stricter
    than effective permission by design); so does a mask granting write."""
    if not xattr_bytes:
        return True
    if len(xattr_bytes) < 4 or (len(xattr_bytes) - 4) % 8 != 0:
        return False
    for off in range(4, len(xattr_bytes), 8):
        tag = int.from_bytes(xattr_bytes[off:off + 2], "little")
        perm = int.from_bytes(xattr_bytes[off + 2:off + 4], "little")
        if tag in (LINUX_ACL_USER, LINUX_ACL_GROUP):
            return False
        if tag == LINUX_ACL_MASK and perm & LINUX_ACL_WRITE:
            return False
    return True


def linux_install_acl_ok(fd):
    for name in ("system.posix_acl_access", "system.posix_acl_default"):
        if not linux_acl_ok(linux_read_acl_xattr(fd, name)):
            return False
    return True


# --- R10.1 walk: install directory, its ancestors, listed files, their
# ancestors. Darwin: no dangerous ACL grant to any principal but uid 0 /
# principal_uid. Linux: no named entry, no write-granting mask. An ACL that
# cannot be read fails. ---------------------------------------------------
def check_acl(path, principal_uid):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        refuse("E_INSTALL_ACL")
    try:
        if sys.platform == "darwin":
            try:
                ok = darwin_install_acl_ok(darwin_acl_entries(fd), principal_uid)
            except OSError:
                ok = False
        else:
            ok = linux_install_acl_ok(fd)
    finally:
        os.close(fd)
    if not ok:
        refuse("E_INSTALL_ACL")


def ancestors(path):
    parts = []
    cur = path
    while True:
        parent = os.path.dirname(cur)
        if parent == cur:
            parts.append(cur)
            break
        parts.append(parent)
        cur = parent
    return parts


def with_ancestors(paths):
    """Each path itself (checked with O_NOFOLLOW: it must be a real file, not
    a symlink) plus its containing directory's *resolved* ancestor chain.
    Resolving first matters on macOS, where /var, /tmp and /etc are
    themselves symlinks (to /private/var etc.): walking the raw string
    ancestors of an ordinary path would otherwise flag that top-level
    symlink as if it were part of the trusted tree, on every host."""
    seen = []
    known = set()
    for path in paths:
        real_dir = os.path.realpath(os.path.dirname(path))
        for candidate in [path, real_dir] + ancestors(real_dir):
            if candidate not in known:
                known.add(candidate)
                seen.append(candidate)
    return seen


def acl_walk(paths, principal_uid):
    for candidate in with_ancestors(paths):
        check_acl(candidate, principal_uid)


def owner_mode_ok(state, principal_uid):
    if state.st_uid not in (0, principal_uid):
        return False
    return state.st_mode & (stat.S_IWGRP | stat.S_IWOTH) == 0


def check_owner_mode_walk(paths, principal_uid):
    for candidate in with_ancestors(paths):
        try:
            state = os.lstat(candidate)
        except OSError:
            refuse("E_CONFIG")
        if stat.S_ISLNK(state.st_mode) or not owner_mode_ok(state, principal_uid):
            refuse("E_CONFIG")


# --- host-config.json (R10.1) ---------------------------------------------
IDENTITY_PATH_KEYS = ("guest_init", "guest_kernel", "guest_kernel_config", "guest_supervisor",
                      "host_runtime", "host_supervisor", "image", "toolchain", "verifier")
INSTALLED_FILE_KEYS = ("accepted_set", "control_decision", "control_policy", "control_policy_set",
                       "evaluator_driver", "evaluator_program", "registry")


def is_abs_path(value):
    return isinstance(value, str) and value.startswith("/")


def load_config(install_dir):
    config_path = os.path.join(install_dir, "host-config.json")
    try:
        with open(config_path, "rb") as handle:
            raw = handle.read()
    except OSError:
        refuse("E_CONFIG")
    try:
        doc = json.loads(raw)
    except ValueError:
        refuse("E_CONFIG")
    require(isinstance(doc, dict) and set(doc) == {"body", "id", "kind", "schema_version"}, "E_CONFIG")
    require(doc.get("kind") == "sandbox_host_config" and doc.get("schema_version") == 1, "E_CONFIG")
    body = doc.get("body")
    require(isinstance(body, dict) and set(body) == {
        "consumer_gid", "environment_id", "identity_paths", "installed_files",
        "principal_uid", "runtime", "store_id", "store_root", "work_root"}, "E_CONFIG")
    require(isinstance(body["principal_uid"], int) and body["principal_uid"] >= 0, "E_CONFIG")
    require(isinstance(body["consumer_gid"], int) and body["consumer_gid"] >= 0, "E_CONFIG")
    for key in ("store_id", "environment_id"):
        require(isinstance(body[key], str) and body[key], "E_CONFIG")
    for key in ("store_root", "work_root"):
        require(is_abs_path(body[key]) and not (body[key] == "/sandbox" or body[key].startswith("/sandbox/")),
                "E_CONFIG")
    runtime = body["runtime"]
    require(isinstance(runtime, dict) and set(runtime) == {"driver", "vfkit"}, "E_CONFIG")
    require(is_abs_path(runtime["driver"]) and is_abs_path(runtime["vfkit"]), "E_CONFIG")
    identity_paths = body["identity_paths"]
    require(isinstance(identity_paths, dict) and set(identity_paths) == set(IDENTITY_PATH_KEYS), "E_CONFIG")
    for value in identity_paths.values():
        require(is_abs_path(value), "E_CONFIG")
    installed_files = body["installed_files"]
    require(isinstance(installed_files, dict) and set(installed_files) == set(INSTALLED_FILE_KEYS), "E_CONFIG")
    for value in installed_files.values():
        require(is_abs_path(value), "E_CONFIG")
    require(canonical(doc) == raw, "E_CONFIG")
    return body


def check_accepted_set(path):
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError:
        refuse("E_CONFIG")
    try:
        doc = json.loads(raw)
    except ValueError:
        refuse("E_CONFIG")
    require(canonical(doc) == raw, "E_CONFIG")
    body = doc.get("body") if isinstance(doc, dict) else None
    require(isinstance(body, dict) and isinstance(body.get("environments"), list), "E_CONFIG")
    for env in body["environments"]:
        identities = env.get("identities") if isinstance(env, dict) else None
        if not isinstance(identities, dict):
            continue
        for digests in identities.values():
            if isinstance(digests, list) and any(placeholder(d) for d in digests if isinstance(d, str)):
                refuse("E_CONFIG")


# --- store root (enforcement-evidence-binding spec.md R2.3) ---------------
def check_store_root(store_root, principal_uid, consumer_gid):
    try:
        fd = os.open(store_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError:
        refuse("E_STORE")
    try:
        state = os.fstat(fd)
        ok = (stat.S_ISDIR(state.st_mode) and state.st_uid == principal_uid and
              state.st_gid == consumer_gid and stat.S_IMODE(state.st_mode) == 0o750)
        if ok:
            if sys.platform == "darwin":
                try:
                    ok = darwin_acl_entries(fd) == []
                except OSError:
                    ok = False
            else:
                ok = linux_install_acl_ok(fd) and linux_read_acl_xattr(fd, "system.posix_acl_access") is None \
                    and linux_read_acl_xattr(fd, "system.posix_acl_default") is None
    finally:
        os.close(fd)
    require(ok, "E_STORE")


# --- R3.1 request shape (phase A: shape only, no cross-referencing) -------
CONTROL_KEYS = {"decision_sha256", "evaluator_driver_sha256", "evaluator_program_sha256",
                "policy_sha256", "policy_set_sha256", "sandbox_evaluation_sha256"}
SOURCE_KEYS = {"repository_id", "hash_algorithm", "commit_id", "tree_id"}
CANDIDATE_KEYS = {"preparation_record_sha256", "manifest_sha256", "commit_id", "tree_id"}
SUBJECT_KEYS = {"environment_id", "environment_entry_sha256", "target_repository_id",
                "source", "candidate", "incident_sha256"}


def sha256_ok(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def id_ok(value):
    if not isinstance(value, str) or not (1 <= len(value) <= 128):
        return False
    alphabet = "abcdefghijklmnopqrstuvwxyz0123456789._:-"
    return value[0] in "abcdefghijklmnopqrstuvwxyz0123456789" and all(c in alphabet for c in value)


def parse_request(raw):
    try:
        doc = json.loads(raw)
    except ValueError:
        refuse("E_PACKAGE")
    require(isinstance(doc, dict) and set(doc) == {"body", "id", "kind", "schema_version"}, "E_PACKAGE")
    require(doc.get("kind") == "sandbox_launch_request" and doc.get("schema_version") == 1, "E_PACKAGE")
    require(id_ok(doc.get("id", "")), "E_PACKAGE")
    body = doc.get("body")
    require(isinstance(body, dict) and set(body) == {
        "attempt", "control", "instruction_sha256", "nonce", "store_id", "subject"}, "E_PACKAGE")
    attempt = body["attempt"]
    require(isinstance(attempt, dict) and set(attempt) == {"attempt_id", "attempt_number"}, "E_PACKAGE")
    require(id_ok(attempt["attempt_id"]), "E_PACKAGE")
    require(isinstance(attempt["attempt_number"], int) and 1 <= attempt["attempt_number"] <= 1024, "E_PACKAGE")
    control = body["control"]
    require(isinstance(control, dict) and set(control) == CONTROL_KEYS, "E_PACKAGE")
    for value in control.values():
        require(sha256_ok(value), "E_PACKAGE")
    require(sha256_ok(body["instruction_sha256"]), "E_PACKAGE")
    nonce = body["nonce"]
    require(isinstance(nonce, str) and len(nonce) == 64 and all(c in "0123456789abcdef" for c in nonce),
            "E_PACKAGE")
    require(id_ok(body["store_id"]), "E_PACKAGE")
    subject = body["subject"]
    require(isinstance(subject, dict) and set(subject) == SUBJECT_KEYS, "E_PACKAGE")
    require(id_ok(subject["environment_id"]), "E_PACKAGE")
    require(sha256_ok(subject["environment_entry_sha256"]), "E_PACKAGE")
    require(id_ok(subject["target_repository_id"]), "E_PACKAGE")
    source = subject["source"]
    require(isinstance(source, dict) and set(source) == SOURCE_KEYS, "E_PACKAGE")
    require(id_ok(source["repository_id"]) and source["hash_algorithm"] in ("sha1", "sha256"), "E_PACKAGE")
    candidate = subject["candidate"]
    require(isinstance(candidate, dict) and set(candidate) == CANDIDATE_KEYS, "E_PACKAGE")
    require(sha256_ok(candidate["preparation_record_sha256"]) and sha256_ok(candidate["manifest_sha256"]),
            "E_PACKAGE")
    require(sha256_ok(subject["incident_sha256"]), "E_PACKAGE")
    require(canonical(doc) == raw, "E_PACKAGE")
    return doc, body


# --- R10.2 store writer: O_CREAT|O_EXCL relative to a directory fd, fsync,
# then the final mode; directories 0750, files 0440. --------------------
def mkdir_excl(parent_fd, name, uid, gid):
    os.mkdir(name, mode=0o700, dir_fd=parent_fd)
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    try:
        os.fchown(fd, uid, gid)
        os.fchmod(fd, 0o750)
        os.fsync(fd)
    except BaseException:
        os.close(fd)
        raise
    return fd


def write_excl(parent_fd, name, data, uid, gid):
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode=0o600, dir_fd=parent_fd)
    try:
        written = 0
        while written < len(data):
            written += os.write(fd, data[written:])
        os.fchown(fd, uid, gid)
        os.fchmod(fd, 0o440)
        os.fsync(fd)
    finally:
        os.close(fd)


def write_store(store_root, attempt_id, uid, gid, receipt_bytes, payload):
    store_fd = os.open(store_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        try:
            attempt_fd = mkdir_excl(store_fd, attempt_id, uid, gid)
        except FileExistsError:
            refuse("E_ATTEMPT_EXISTS")
        try:
            payload_fd = mkdir_excl(attempt_fd, "payload", uid, gid)
            try:
                for name, data in payload:
                    write_excl(payload_fd, name, data, uid, gid)
                os.fsync(payload_fd)
            finally:
                os.close(payload_fd)
            write_excl(attempt_fd, "receipt.json", receipt_bytes, uid, gid)
            os.fsync(attempt_fd)
        finally:
            os.close(attempt_fd)
        os.fsync(store_fd)
    finally:
        os.close(store_fd)


# --- R9.4/R10.3: the PR 3 stub receipt for an admitted attempt whose
# runtime never started (no launch path exists before PR 5). --------------
LIMIT_ROWS = (
    ("cpu_time_ms", 30000, "guest-supervisor"),
    ("wall_time_ms", 60000, "host-supervisor"),
    ("memory_bytes", 536870912, "guest-supervisor"),
    ("output_bytes", 10485760, "guest-supervisor"),
    ("process_count", 32, "guest-supervisor"),
    ("scratch_bytes", 16777216, "guest-supervisor"),
)
IDENTITY_SLOTS = ("host_runtime", "guest_kernel", "guest_kernel_config", "guest_init", "image",
                   "host_supervisor", "guest_supervisor", "verifier", "toolchain",
                   "verification_instructions")


def utc_stamp(seconds):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(seconds))


def empty_sha256():
    return sha256_hex(b"")


LIMIT_REASON = {"cpu_time_ms": "limit.cpu-time-reached", "wall_time_ms": "limit.wall-time-reached",
                "memory_bytes": "limit.memory-reached", "output_bytes": "limit.output-reached",
                "process_count": "limit.process-count-reached", "scratch_bytes": "limit.scratch-reached"}


def derive_outcome(body):
    """R8: the failure set from recorded fields only, else violated/satisfied."""
    failures = set()
    if body["lifecycle"]["admission"] == "refused":
        failures.add("failure.launch-refused")
    if body["lifecycle"]["runtime"] == "error":
        failures.add("failure.runtime")
    if body["lifecycle"]["control_deadline"] == "exceeded":
        failures.add("failure.supervisor-timeout")
    if body["teardown"]["state"] != "confirmed":
        failures.add("failure.teardown")
    if (any(v["state"] == "unobserved" for v in body["identities"].values())
            or any(v["observation"] in ("partial", "unavailable") for v in body["limits"].values())):
        failures.add("failure.observation-unavailable")
    if any(v["enforcement"] in ("none", "unknown") for v in body["limits"].values()):
        failures.add("failure.enforcement-unavailable")
    if failures:
        return {"verdict": "failed", "reason_ids": sorted(failures)}
    reached = [name for name, row in body["limits"].items() if row["reached"]]
    if reached:
        return {"verdict": "violated", "reason_ids": sorted(LIMIT_REASON[name] for name in reached)}
    return {"verdict": "satisfied", "reason_ids": ["enforcement.satisfied"]}


def build_stub_receipt(config, accepted_set_sha256, request_doc, request_body,
                        launch_request_sha256, admitted_at):
    now = time.time()
    identities = {slot: {"state": "unobserved", "reason_id": "launch.identity-missing"}
                  for slot in IDENTITY_SLOTS}
    limits = {}
    for name, bound, observer in LIMIT_ROWS:
        limits[name] = {"bound": bound, "observed": None, "resolution": 1,
                        "observation": "unavailable", "enforcement": "unknown",
                        "reached": False, "mechanism_id": "mechanism.unmeasured",
                        "observer": observer}
    empty = empty_sha256()
    body = {
        "attempt": {"attempt_id": request_body["attempt"]["attempt_id"],
                    "attempt_number": request_body["attempt"]["attempt_number"],
                    "launch_request_sha256": launch_request_sha256},
        "contract_version": "v1",
        "control": dict(request_body["control"]),
        "identities": identities,
        "lifecycle": {"admission": "admitted", "runtime": "error", "control_deadline": "met"},
        "limits": limits,
        "origin": {"producer_role": "host-supervisor", "store_id": config["store_id"],
                   "accepted_set_sha256": accepted_set_sha256},
        "payload": {"stdout_sha256": empty, "stderr_sha256": empty,
                    "evidence_manifest_sha256": empty, "exit_state": "not-started",
                    "exit_code": None},
        "subject": dict(request_body["subject"]),
        "teardown": {"state": "confirmed", "tree_terminated": True, "storage_destroyed": True},
        "timing": {"admitted_at": utc_stamp(admitted_at), "terminated_at": utc_stamp(now)},
    }
    body["outcome"] = derive_outcome(body)
    doc = {"body": body, "id": "receipt." + launch_request_sha256,
           "kind": "sandbox_enforcement_receipt", "schema_version": 1}
    return canonical(doc)


# --- phase A: the launch entry point --------------------------------------
def install_directory():
    return os.path.dirname(os.path.realpath(__file__))


def fixed_acl_targets(install_dir):
    targets = [install_dir, os.path.join(install_dir, "host-config.json")]
    for name in sorted(os.listdir(install_dir)):
        if name.endswith(".py"):
            targets.append(os.path.join(install_dir, name))
    return targets


def run_launch(argv):
    # R10.1: the ACL walk is checked before anything else, usage included.
    # This process itself runs as the principal (directly under sudo, R13.3;
    # the same account under test, R15.1), so os.getuid() *is* the
    # principal for this first pass -- config is not loaded yet to name one.
    install_dir = install_directory()
    fixed_targets = fixed_acl_targets(install_dir)
    acl_walk(fixed_targets, os.getuid())
    require(os.getuid() != 0 and argv == ["launch"], "E_USAGE")
    config = load_config(install_dir)
    principal_uid = config["principal_uid"]
    require(principal_uid == os.getuid(), "E_CONFIG")
    config_named = (list(config["identity_paths"].values()) + list(config["installed_files"].values())
                    + [config["runtime"]["vfkit"]])
    acl_walk(config_named, principal_uid)
    check_owner_mode_walk(fixed_targets + config_named, principal_uid)
    check_accepted_set(config["installed_files"]["accepted_set"])
    check_store_root(config["store_root"], principal_uid, config["consumer_gid"])

    raw = sys.stdin.buffer.read(88080384 + 1)
    require(len(raw) <= 88080384, "E_PACKAGE")
    package = parse_package(raw)
    request_doc, request_body = parse_request(package["request.json"])
    launch_request_sha256 = sha256_hex(package["request.json"])
    require(request_body["store_id"] == config["store_id"], "E_STORE_ID")

    nonce_bytes = bytes.fromhex(request_body["nonce"])
    nonce_dir = os.path.join(config["work_root"], "nonces")
    os.makedirs(nonce_dir, exist_ok=True)
    nonce_path = os.path.join(nonce_dir, sha256_hex(nonce_bytes))
    try:
        fd = os.open(nonce_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.close(fd)
    except FileExistsError:
        refuse("E_NONCE_REUSED")

    if os.path.lexists(os.path.join(config["store_root"], request_body["attempt"]["attempt_id"])):
        refuse("E_ATTEMPT_EXISTS")

    admitted_at = time.time()
    with open(config["installed_files"]["accepted_set"], "rb") as handle:
        accepted_set_sha256 = sha256_hex(handle.read())
    receipt_bytes = build_stub_receipt(config, accepted_set_sha256, request_doc, request_body,
                                        launch_request_sha256, admitted_at)
    payload = [("stdout", b""), ("stderr", b""),
               ("evidence-manifest.json", canonical({"body": {"files": []},
                                                      "id": "evidence-manifest",
                                                      "kind": "sandbox_evidence_manifest",
                                                      "schema_version": 1}))]
    try:
        write_store(config["store_root"], request_body["attempt"]["attempt_id"],
                    principal_uid, config["consumer_gid"], receipt_bytes, payload)
    except Refusal:
        raise
    except OSError:
        sys.stderr.write("E_STORE_WRITE\n")
        sys.exit(70)


# --- test-only frame subcommands, mirroring sandbox-guest-harness.c ------
def cmd_frame_write(argv):
    if len(argv) < 1:
        sys.exit(2)
    records = []
    for arg in argv[1:]:
        name, _, path = arg.partition("=")
        with open(path, "rb") as handle:
            records.append((name.encode(), handle.read()))
    with open(argv[0], "xb") as out:
        out.write(frame_write(records))


def cmd_frame_read(argv):
    if len(argv) < 2:
        sys.exit(2)
    with open(argv[0], "rb") as handle:
        data = handle.read()
    try:
        records = frame_read(data)
    except FrameError as exc:
        sys.stderr.write(str(exc) + "\n")
        sys.exit(1)
    out_dir = argv[1]
    os.mkdir(out_dir, 0o755)
    for name, content in records:
        rel = name.decode()
        full = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "xb") as handle:
            handle.write(content)


def cmd_digest(argv):
    with open(argv[0], "rb") as handle:
        sys.stdout.write(sha256_hex(handle.read()) + "\n")


TEST_ONLY_COMMANDS = ("frame-write", "frame-read", "digest")


def main():
    # Only the three test-only tools bypass the launch path entirely (they
    # are not the production invocation R3.4/R10.1 govern at all). Anything
    # else -- no arguments, "launch", or any other argv -- goes through
    # run_launch, whose R10.1 ACL walk runs before it even looks at argv
    # (checked before anything else, usage included).
    if len(sys.argv) >= 2 and sys.argv[1] in TEST_ONLY_COMMANDS:
        command, rest = sys.argv[1], sys.argv[2:]
        if command == "frame-write":
            cmd_frame_write(rest)
        elif command == "frame-read":
            cmd_frame_read(rest)
        else:
            cmd_digest(rest)
        return
    try:
        run_launch(sys.argv[1:])
    except Refusal as exc:
        sys.stderr.write(exc.code + "\n")
        sys.exit(65)
    sys.exit(0)


if __name__ == "__main__":
    main()
