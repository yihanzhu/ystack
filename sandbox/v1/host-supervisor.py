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


ALL_ONES = "1" * 64  # matches enforcement/v1/sandbox-receipt.jq's all_ones_sha
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
    # R3.3: incident.json (the shadow_incident_record) is capped at 262,144
    # bytes, checked here so an oversize incident record is refused E_PACKAGE
    # before the nonce is ever consumed.
    if len(named["incident.json"]) > 262144:
        refuse("E_PACKAGE")
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


# --- R10.1 walk: install directory, ancestors, listed files, their
# ancestors -- each opened component by component from "/" via openat()+
# O_NOFOLLOW, never realpath or a plain os.open of the path string:
# resolving the parent first drops the directory that held a symlink
# (even an attacker-writable one) from the walk and follows it through.
# Refusing any symlink component anywhere closes that; a configured path
# must already be physical/symlink-free (`cd -P`), as check-sandbox-
# receipt.sh's own physical_regular requires. Darwin: no dangerous ACL
# grant but uid 0 / principal_uid. Linux: no named entry, no write mask.
# Later reads of validated content go through the fd this walk returns.
def trust_root_fd():
    """Test-only: YSTACK_SANDBOX_TRUST_ROOT, honored only for a directory
    already owned by the invoking uid and not group/other-writable (an
    attacker who could satisfy that already has the principal's own
    access). Lets a test anchor the walk below a directory it made clean
    itself on a host where neither /tmp nor $HOME reach "/" cleanly; unset,
    the product check still walks from "/" as always."""
    root = os.environ.get("YSTACK_SANDBOX_TRUST_ROOT")
    if not root:
        return None, None
    try:
        fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError:
        return None, None
    state = os.fstat(fd)
    if state.st_uid != os.getuid() or state.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        os.close(fd)
        return None, None
    return os.path.normpath(root), fd


def secure_ancestor_fds(path, principal_uid):
    """Opens every component and validates it as opened: the R10.1 ACL on
    every fd, and -- for every ancestor, never deferred -- the owner/mode
    too (otherwise only caught by luck, if some other path crosses it).
    The target's own owner/mode is the caller's choice (see secure_walk)."""
    if not (isinstance(path, str) and path.startswith("/")):
        refuse("E_INSTALL_ACL")
    parts = [p for p in path.split("/") if p and p != "."]
    if ".." in parts:
        refuse("E_INSTALL_ACL")
    anchor_root, anchor_fd = trust_root_fd()
    if anchor_root and (path == anchor_root or path.startswith(anchor_root + "/")):
        fds = [anchor_fd]
        parts = parts[len([p for p in anchor_root.split("/") if p]):]
    else:
        if anchor_fd is not None:
            os.close(anchor_fd)
        fds = [os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)]
    check_acl_fd(fds[0], principal_uid)
    if parts and not owner_mode_fd_ok(fds[0], principal_uid):
        os.close(fds[0])
        refuse("E_CONFIG")
    for i, part in enumerate(parts):
        is_last = i == len(parts) - 1
        flags = os.O_RDONLY | os.O_NOFOLLOW
        if not is_last:
            flags |= os.O_DIRECTORY
        try:
            fd = os.open(part, flags, dir_fd=fds[-1])
        except OSError:
            for f in fds:
                os.close(f)
            refuse("E_INSTALL_ACL")
        fds.append(fd)
        check_acl_fd(fd, principal_uid)
        if not is_last and not owner_mode_fd_ok(fd, principal_uid):
            for f in fds:
                os.close(f)
            refuse("E_CONFIG")
    return fds


def check_acl_fd(fd, principal_uid):
    if sys.platform == "darwin":
        try:
            ok = darwin_install_acl_ok(darwin_acl_entries(fd), principal_uid)
        except OSError:
            ok = False
    else:
        ok = linux_install_acl_ok(fd)
    if not ok:
        refuse("E_INSTALL_ACL")


def owner_mode_ok(state, principal_uid):
    if state.st_uid not in (0, principal_uid):
        return False
    return state.st_mode & (stat.S_IWGRP | stat.S_IWOTH) == 0


def owner_mode_fd_ok(fd, principal_uid):
    state = os.fstat(fd)
    return not stat.S_ISLNK(state.st_mode) and owner_mode_ok(state, principal_uid)


def secure_walk(path, principal_uid, check_mode):
    """Ancestors already validated by secure_ancestor_fds; the target's own
    owner/mode is checked here only when check_mode. Closes ancestor fds,
    returns the validated target fd."""
    fds = secure_ancestor_fds(path, principal_uid)
    if check_mode and not owner_mode_fd_ok(fds[-1], principal_uid):
        for f in fds:
            os.close(f)
        refuse("E_CONFIG")
    for f in fds[:-1]:
        os.close(f)
    return fds[-1]


# Ancestor fds of the trusted install root, pinned open (never closed) for
# the process lifetime -- see run_launch's own use, below.
_trusted_root_fds = []

# --- host-config.json (R10.1) ---------------------------------------------
IDENTITY_PATH_KEYS = ("guest_init", "guest_kernel", "guest_kernel_config", "guest_supervisor",
                      "host_runtime", "host_supervisor", "image", "toolchain", "verifier")
INSTALLED_FILE_KEYS = ("accepted_set", "control_decision", "control_policy", "control_policy_set",
                       "evaluator_driver", "evaluator_program", "registry")


def is_abs_path(value):
    return isinstance(value, str) and value.startswith("/")


def load_config(config_fd):
    """Reads host-config.json through the fd secure_walk already validated
    (never a fresh open() of the path string -- see secure_ancestor_fds)."""
    try:
        dup_fd = os.dup(config_fd)
    except OSError:
        refuse("E_CONFIG")
    try:
        with os.fdopen(dup_fd, "rb") as handle:
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


def digest_list_ok(value):
    """Mirrors sandbox-receipt.jq's digest_list_ok: 1-8 sha256 digests, none
    a placeholder, sorted and unique."""
    if not (isinstance(value, list) and 1 <= len(value) <= 8
            and all(sha256_ok(v) for v in value) and not any(placeholder(v) for v in value)):
        return False
    return value == sorted(set(value)) and len(value) == len(set(value))


def id_list_ok(value):
    """Mirrors sandbox-receipt.jq's id_list_ok: 1-8 ids, sorted and unique."""
    if not (isinstance(value, list) and 1 <= len(value) <= 8):
        return False
    if not all(id_ok(v) for v in value):
        return False
    return value == sorted(set(value)) and len(value) == len(set(value))


def accepted_entry_shape_ok(env):
    if not (isinstance(env, dict) and set(env) == {"environment_id", "identities", "mechanisms",
                                                     "scratch_bytes"}):
        return False
    if not id_ok(env["environment_id"]):
        return False
    scratch_bytes = env["scratch_bytes"]
    if not (isinstance(scratch_bytes, int) and not isinstance(scratch_bytes, bool) and scratch_bytes > 0):
        return False
    identities = env["identities"]
    if not (isinstance(identities, dict) and set(identities) == set(IDENTITY_SLOTS)):
        return False
    if not all(digest_list_ok(identities[slot]) for slot in IDENTITY_SLOTS):
        return False
    mechanisms = env["mechanisms"]
    limit_row_names = {row[0] for row in LIMIT_ROWS}
    if not (isinstance(mechanisms, dict) and set(mechanisms) == limit_row_names):
        return False
    return all(id_list_ok(mechanisms[row]) for row in limit_row_names)


def check_accepted_set(fd):
    """Mirrors fixed_accepted_shape_ok in full; reads the already-validated
    fd and returns sha256_hex(raw) for accepted_set_sha256 (no path re-read)."""
    try:
        with os.fdopen(fd, "rb") as handle:
            raw = handle.read()
    except OSError:
        refuse("E_CONFIG")
    try:
        doc = json.loads(raw)
    except ValueError:
        refuse("E_CONFIG")
    require(canonical(doc) == raw, "E_CONFIG")
    require(isinstance(doc, dict) and set(doc) == {"body", "id", "kind", "schema_version"}, "E_CONFIG")
    require(doc.get("kind") == "sandbox_accepted_identity_set" and doc.get("schema_version") == 1,
            "E_CONFIG")
    require(doc.get("id") == "sandbox.accepted-identities.v1", "E_CONFIG")
    body = doc.get("body")
    require(isinstance(body, dict) and set(body) == {"activation_state", "environments", "set_version"},
            "E_CONFIG")
    require(body.get("activation_state") == "inactive" and body.get("set_version") == "v1", "E_CONFIG")
    environments = body["environments"]
    require(isinstance(environments, list) and all(accepted_entry_shape_ok(env) for env in environments),
            "E_CONFIG")
    return sha256_hex(raw)


# --- store root (enforcement-evidence-binding spec.md R2.3) ---------------
def store_root_state_ok(fd, principal_uid, consumer_gid):
    """R2.3 store-root shape check against an already-open fd, reused to
    admit and again right before every write (never a fresh open())."""
    state = os.fstat(fd)
    ok = (stat.S_ISDIR(state.st_mode) and state.st_uid == principal_uid and
          state.st_gid == consumer_gid and stat.S_IMODE(state.st_mode) == 0o750)
    if not ok:
        return False
    if sys.platform == "darwin":
        try:
            return darwin_acl_entries(fd) == []
        except OSError:
            return False
    return (linux_install_acl_ok(fd) and linux_read_acl_xattr(fd, "system.posix_acl_access") is None
            and linux_read_acl_xattr(fd, "system.posix_acl_default") is None)


def check_store_root(store_root, principal_uid, consumer_gid):
    """Opens store_root by path exactly once (no earlier fd exists) and
    returns the open, validated fd to hold through the store write."""
    try:
        fd = os.open(store_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError:
        refuse("E_STORE")
    if not store_root_state_ok(fd, principal_uid, consumer_gid):
        os.close(fd)
        refuse("E_STORE")
    return fd


# --- R3.1 request shape (phase A: shape only, no cross-referencing) -------
CONTROL_KEYS = {"decision_sha256", "evaluator_driver_sha256", "evaluator_program_sha256",
                "policy_sha256", "policy_set_sha256", "sandbox_evaluation_sha256"}
SOURCE_KEYS = {"repository_id", "hash_algorithm", "commit_id", "tree_id"}
CANDIDATE_KEYS = {"preparation_record_sha256", "manifest_sha256", "commit_id", "tree_id"}
SUBJECT_KEYS = {"environment_id", "environment_entry_sha256", "target_repository_id",
                "source", "candidate", "incident_sha256"}


def sha256_ok(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def oid_ok(value, hash_algorithm):
    """Lowercase hex of the length hash_algorithm selects (40/sha1, 64/sha256);
    matches sandbox-receipt.jq's oid_ok for source/candidate commit_id/tree_id."""
    if not isinstance(value, str):
        return False
    length = {"sha1": 40, "sha256": 64}.get(hash_algorithm)
    if length is None:
        return False
    return len(value) == length and all(c in "0123456789abcdef" for c in value)


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
    attempt_number = attempt["attempt_number"]
    require(isinstance(attempt_number, int) and not isinstance(attempt_number, bool)
            and 1 <= attempt_number <= 1024, "E_PACKAGE")
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
    hash_algorithm = source["hash_algorithm"]
    require(oid_ok(source.get("commit_id"), hash_algorithm) and oid_ok(source.get("tree_id"), hash_algorithm),
            "E_PACKAGE")
    candidate = subject["candidate"]
    require(isinstance(candidate, dict) and set(candidate) == CANDIDATE_KEYS, "E_PACKAGE")
    require(sha256_ok(candidate["preparation_record_sha256"]) and sha256_ok(candidate["manifest_sha256"]),
            "E_PACKAGE")
    require(oid_ok(candidate.get("commit_id"), hash_algorithm) and oid_ok(candidate.get("tree_id"), hash_algorithm),
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


def write_store(store_fd, uid, gid, attempt_id, receipt_bytes, payload):
    """Writes through store_fd, held open since check_store_root and
    rechecked here, so a store_root replaced after admission cannot redirect."""
    require(store_root_state_ok(store_fd, uid, gid), "E_STORE")
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
                        launch_request_sha256, admitted_at, evidence_manifest_sha256):
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
                    "evidence_manifest_sha256": evidence_manifest_sha256, "exit_state": "not-started",
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


def test_hook_swap_store_ancestor(target):
    """Test-only (env-var gated at the call site; a real launch never
    triggers this): renames validated `target` aside and symlinks its old
    name to a sibling the test pre-creates, standing in for the path being
    replaced between the store-root check and the write."""
    os.rename(target, target + ".ystack-test-orig")
    os.symlink(target + ".ystack-test-swapped", target)


def run_launch(argv):
    # R10.1: the ACL walk is checked before anything else, usage included.
    # This process itself runs as the principal (directly under sudo, R13.3;
    # the same account under test, R15.1), so os.getuid() *is* the
    # principal for this first pass -- config is not loaded yet to name one.
    install_dir = install_directory()
    fixed_targets = fixed_acl_targets(install_dir)
    config_path = os.path.join(install_dir, "host-config.json")
    # fds stay open: host-config.json is read below through the very fd
    # validated here, and the owner/mode pass can fstat them, not re-walk.
    fixed_fds = {}
    for path in fixed_targets:
        if path == install_dir:
            # Pinned open in _trusted_root_fds; other targets just re-walk it.
            root_fds = secure_ancestor_fds(path, os.getuid())
            _trusted_root_fds.extend(root_fds[:-1])
            fixed_fds[path] = root_fds[-1]
        else:
            fixed_fds[path] = secure_walk(path, os.getuid(), check_mode=False)
    require(os.getuid() != 0 and argv == ["launch"], "E_USAGE")
    config = load_config(fixed_fds[config_path])
    principal_uid = config["principal_uid"]
    require(principal_uid == os.getuid(), "E_CONFIG")
    for fd in fixed_fds.values():
        if not owner_mode_fd_ok(fd, principal_uid):
            refuse("E_CONFIG")
    for fd in fixed_fds.values():
        os.close(fd)
    config_named = (list(config["identity_paths"].values()) + list(config["installed_files"].values())
                    + [config["runtime"]["vfkit"]])
    accepted_set_path = config["installed_files"]["accepted_set"]
    accepted_set_fd = None
    for path in config_named:
        fd = secure_walk(path, principal_uid, check_mode=True)
        if path == accepted_set_path and accepted_set_fd is None:
            accepted_set_fd = fd
        else:
            os.close(fd)
    accepted_set_sha256 = check_accepted_set(accepted_set_fd)
    store_fd = check_store_root(config["store_root"], principal_uid, config["consumer_gid"])
    if os.environ.get("YSTACK_TEST_SWAP_STORE_ANCESTOR"):
        test_hook_swap_store_ancestor(config["store_root"])

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

    # fstatat on store_fd, not a path string; any OSError means "not found".
    try:
        os.stat(request_body["attempt"]["attempt_id"], dir_fd=store_fd, follow_symlinks=False)
    except OSError:
        pass
    else:
        refuse("E_ATTEMPT_EXISTS")

    admitted_at = time.time()
    # R8.3: built once, reused for both the receipt digest and the write.
    evidence_manifest_bytes = canonical({"body": {"files": []}, "id": "evidence-manifest",
                                          "kind": "sandbox_evidence_manifest", "schema_version": 1})
    evidence_manifest_sha256 = sha256_hex(evidence_manifest_bytes)
    receipt_bytes = build_stub_receipt(config, accepted_set_sha256, request_doc, request_body,
                                        launch_request_sha256, admitted_at, evidence_manifest_sha256)
    payload = [("stdout", b""), ("stderr", b""),
               ("evidence-manifest.json", evidence_manifest_bytes)]
    try:
        write_store(store_fd, principal_uid, config["consumer_gid"],
                    request_body["attempt"]["attempt_id"], receipt_bytes, payload)
    except Refusal:
        raise
    except OSError:
        sys.stderr.write("E_STORE_WRITE\n")
        sys.exit(70)
    finally:
        os.close(store_fd)


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
