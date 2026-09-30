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


def is_int(value):
    """bool subclasses int in Python, so every JSON integer field must
    exclude it explicitly, or {"schema_version": true} passes as 1."""
    return isinstance(value, int) and not isinstance(value, bool)


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
ACL_FIRST_ENTRY, ACL_NEXT_ENTRY = 0, -1  # <sys/acl.h>; NEXT is -1, not 1
ACL_EXTENDED_ALLOW = 1
MAX_DARWIN_ACL_ENTRIES = 128
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
    GUID could not be resolved (treated as "some other principal"). Raises
    OSError if the ACL can't be read (a real error, not "no ACL present")."""
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
            if len(entries) > MAX_DARWIN_ACL_ENTRIES:
                raise OSError(0, "too many ACL entries")
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
    access) -- lets a test anchor the walk on a host where neither /tmp
    nor $HOME reach "/" cleanly; unset, the product still walks from "/"."""
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
    too. The target's own owner/mode is the caller's choice (secure_walk)."""
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
                      "host_runtime", "host_supervisor", "image", "toolchain", "verifier",
                      "vm_service", "dyld_cache_files")
INSTALLED_FILE_KEYS = ("accepted_set", "control_decision", "control_policy", "control_policy_set",
                       "evaluator_driver", "evaluator_program", "registry")


def is_abs_path(value):
    return isinstance(value, str) and value.startswith("/")


def load_config(config_fd):
    """Reads host-config.json through the fd secure_walk already validated
    (never a fresh open() of the path string -- see secure_ancestor_fds).
    Returns (body, raw) -- the raw bytes feed the host_supervisor composite's
    own config_sha256 (R2.3), so this must not re-read the file elsewhere."""
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
    require(doc.get("kind") == "sandbox_host_config" and is_int(doc.get("schema_version")) and doc.get("schema_version") == 1, "E_CONFIG")
    body = doc.get("body")
    require(isinstance(body, dict) and set(body) == {
        "consumer_gid", "environment_id", "identity_paths", "installed_files",
        "principal_uid", "runtime", "store_id", "store_root", "work_root"}, "E_CONFIG")
    require(is_int(body["principal_uid"]) and body["principal_uid"] >= 0, "E_CONFIG")
    require(is_int(body["consumer_gid"]) and body["consumer_gid"] >= 0, "E_CONFIG")
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
    for key, value in identity_paths.items():
        if key == "dyld_cache_files":
            # Split arm64e shared caches have several subcache files --
            # every one goes through the R10.1 walk and into the
            # host_runtime composite; at least one is required.
            require(isinstance(value, list) and len(value) >= 1
                    and all(is_abs_path(v) for v in value), "E_CONFIG")
        else:
            require(is_abs_path(value), "E_CONFIG")
    installed_files = body["installed_files"]
    require(isinstance(installed_files, dict) and set(installed_files) == set(INSTALLED_FILE_KEYS), "E_CONFIG")
    for value in installed_files.values():
        require(is_abs_path(value), "E_CONFIG")
    require_canonical(doc, raw)
    return body, raw


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
    if not (is_int(scratch_bytes) and scratch_bytes > 0):
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
    require_canonical(doc, raw)
    require(isinstance(doc, dict) and set(doc) == {"body", "id", "kind", "schema_version"}, "E_CONFIG")
    require(doc.get("kind") == "sandbox_accepted_identity_set" and is_int(doc.get("schema_version")) and doc.get("schema_version") == 1, "E_CONFIG")
    require(doc.get("id") == "sandbox.accepted-identities.v1", "E_CONFIG")
    body = doc.get("body")
    require(isinstance(body, dict) and set(body) == {"activation_state", "environments", "set_version"},
            "E_CONFIG")
    require(body.get("activation_state") == "inactive" and body.get("set_version") == "v1", "E_CONFIG")
    environments = body["environments"]
    require(isinstance(environments, list) and all(accepted_entry_shape_ok(env) for env in environments),
            "E_CONFIG")
    return sha256_hex(raw), environments


def entry_for(environments, environment_id):
    for entry in environments:
        if entry.get("environment_id") == environment_id:
            return entry
    return None


def registry_entry_shape_ok(entry):
    if not (isinstance(entry, dict) and set(entry) == {
            "description", "environment_id", "evidence_scope", "proof_state",
            "source_root_commit", "target_repository_id"}):
        return False
    return (id_ok(entry["environment_id"]) and id_ok(entry["target_repository_id"])
            and isinstance(entry["description"], str) and isinstance(entry["evidence_scope"], str)
            and isinstance(entry["proof_state"], str) and isinstance(entry["source_root_commit"], str)
            and len(entry["source_root_commit"]) == 40
            and all(c in "0123456789abcdef" for c in entry["source_root_commit"]))


def read_all(fd):
    """Reads the whole already-open, already-validated fd from its start
    (never a fresh open() of the path string). Only for the small
    documents that need their actual bytes parsed (a kernel .config, host-
    config.json, the registry, the accepted set) -- see sha256_fd for a
    large identity file where only the digest is ever needed. Raises
    OSError on any read failure (e.g. the path names a directory) --
    every caller outside measure_identities' own try/except must catch
    it, via read_all_or_refuse below, never letting it escape uncaught."""
    os.lseek(fd, 0, os.SEEK_SET)
    chunks = []
    while True:
        chunk = os.read(fd, 1048576)
        if not chunk:
            break
        chunks.append(chunk)
    return b"".join(chunks)


def read_all_or_refuse(fd):
    try:
        return read_all(fd)
    except OSError:
        refuse("E_CONFIG")


def require_canonical(doc, raw):
    """A malformed but json.loads-able doc (NaN, a lone surrogate) makes
    canonical() itself raise -- never let that escape uncaught either."""
    try:
        ok = canonical(doc) == raw
    except (ValueError, UnicodeEncodeError):
        ok = False
    require(ok, "E_CONFIG")


def sha256_fd(fd):
    """Streams the fd through hashlib.sha256 in fixed-size chunks, never
    accumulating its bytes -- an identity file (a shared-cache subcache,
    a kernel image) can be multi-gigabyte on a real host, and only its
    digest is ever needed."""
    os.lseek(fd, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    while True:
        chunk = os.read(fd, 1048576)
        if not chunk:
            break
        digest.update(chunk)
    return digest.hexdigest()


def load_registry(fd):
    """Reads, bounds, canonical- and shape-checks the installed registry
    (R10.1 already trusts its ACL/ownership) and returns body["environments"].
    Malformed bytes (unbalanced, NaN, a lone surrogate) refuse E_CONFIG --
    this is an installed config file, never E_PACKAGE (the request's own
    code) and never an uncaught exception escaping from canonical()."""
    try:
        raw = read_all(fd)
        bounded_json_nesting(raw)
        doc = json.loads(raw)
    except (OSError, Refusal, ValueError, RecursionError, UnicodeEncodeError):
        refuse("E_CONFIG")
    require_canonical(doc, raw)
    require(isinstance(doc, dict) and set(doc) == {"body", "id", "kind", "schema_version"}, "E_CONFIG")
    require(doc.get("kind") == "shadow_environment_registry" and is_int(doc.get("schema_version"))
            and doc.get("schema_version") == 1 and id_ok(doc.get("id")), "E_CONFIG")
    body = doc.get("body")
    require(isinstance(body, dict) and set(body) == {"activation_state", "environments", "registry_version"},
            "E_CONFIG")
    # Mirrors sandbox-receipt.jq:373-377's registry_body_schema exactly:
    # both leaf fields are strings, not just present.
    require(isinstance(body["activation_state"], str) and isinstance(body["registry_version"], str),
            "E_CONFIG")
    environments = body["environments"]
    require(isinstance(environments, list) and all(registry_entry_shape_ok(e) for e in environments), "E_CONFIG")
    return environments


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


# --- R2.4: the closed kernel build-config `=y` set (identity_paths'
# guest_kernel_config installed bytes are that config's own text; its
# digest is also the slot's R2.3 measurement -- see measure_identities). --
KERNEL_REQUIRED_OPTIONS = (
    "CONFIG_PCI", "CONFIG_PCI_HOST_GENERIC", "CONFIG_VIRTIO", "CONFIG_VIRTIO_PCI",
    "CONFIG_VIRTIO_BLK", "CONFIG_BLK_DEV_INITRD", "CONFIG_DEVTMPFS", "CONFIG_PROC_FS",
    "CONFIG_SYSFS", "CONFIG_TMPFS", "CONFIG_CGROUPS", "CONFIG_MEMCG",
    "CONFIG_CGROUP_PIDS", "CONFIG_CGROUP_SCHED", "CONFIG_FAIR_GROUP_SCHED",
    "CONFIG_CFS_BANDWIDTH", "CONFIG_PID_NS", "CONFIG_NET_NS", "CONFIG_SECCOMP",
    "CONFIG_SECCOMP_FILTER", "CONFIG_SECURITY_LANDLOCK", "CONFIG_FANOTIFY",
    "CONFIG_FANOTIFY_ACCESS_PERMISSIONS",
)
KERNEL_HZ_OPTIONS = ("CONFIG_HZ_250", "CONFIG_HZ_300", "CONFIG_HZ_1000")


def kernel_config_values(text):
    """{option: value} for every "CONFIG_FOO=value" line; an absent or
    commented-out ("# CONFIG_FOO is not set") option is simply missing."""
    values = {}
    for line in text.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if not line.startswith("CONFIG_") or "=" not in line:
            continue
        name, _, value = line.partition("=")
        values[name.strip()] = value.strip()
    return values


def kernel_config_ok(text):
    values = kernel_config_values(text)
    if any(values.get(opt) != "y" for opt in KERNEL_REQUIRED_OPTIONS):
        return False
    hz_on = [opt for opt in KERNEL_HZ_OPTIONS if values.get(opt) == "y"]
    return len(hz_on) == 1


# --- R3.1 request shape (phase A: shape only, no cross-referencing) -------
REQUEST_JSON_DEPTH = 32  # matches prepare-candidate.py's own LIMITS["json_depth"]


def bounded_json_nesting(data):
    """Non-recursive brace/bracket scan (mirrors prepare-candidate.py's own
    bounded_json_nesting): caps nesting before json.loads ever recurses."""
    depth = 0
    in_string = False
    escaped = False
    for byte in data:
        if in_string:
            if escaped:
                escaped = False
            elif byte == 0x5C:
                escaped = True
            elif byte == 0x22:
                in_string = False
            continue
        if byte == 0x22:
            in_string = True
        elif byte in (0x7B, 0x5B):
            depth += 1
            if depth > REQUEST_JSON_DEPTH:
                refuse("E_PACKAGE")
        elif byte in (0x7D, 0x5D):
            depth -= 1
    if in_string or depth != 0:
        refuse("E_PACKAGE")


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
    bounded_json_nesting(raw)
    try:
        doc = json.loads(raw)
    except ValueError:
        refuse("E_PACKAGE")
    except RecursionError:
        refuse("E_PACKAGE")
    require(isinstance(doc, dict) and set(doc) == {"body", "id", "kind", "schema_version"}, "E_PACKAGE")
    require(doc.get("kind") == "sandbox_launch_request" and is_int(doc.get("schema_version")) and doc.get("schema_version") == 1, "E_PACKAGE")
    require(id_ok(doc.get("id", "")), "E_PACKAGE")
    body = doc.get("body")
    require(isinstance(body, dict) and set(body) == {
        "attempt", "control", "instruction_sha256", "nonce", "store_id", "subject"}, "E_PACKAGE")
    attempt = body["attempt"]
    require(isinstance(attempt, dict) and set(attempt) == {"attempt_id", "attempt_number"}, "E_PACKAGE")
    require(id_ok(attempt["attempt_id"]), "E_PACKAGE")
    attempt_number = attempt["attempt_number"]
    require(is_int(attempt_number) and 1 <= attempt_number <= 1024, "E_PACKAGE")
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


# --- R4.2 phase B: every admission reason, from the frozen package and
# the installed/registry/accepted-set content already read through
# validated fds (never a fresh open() of any path). ------------------------
CANDIDATE_EXPORT_BYTES = 64 * 1024 * 1024  # preparation/v1/prepare-candidate.py:54
INCIDENT_BODY_KEYS = {"deploy_authority", "failing_check", "git_revision_ref", "observed_at",
                       "observed_symptom", "reporter_actor_ref", "target_repository_id"}


def phase_b_json_ok(raw):
    """Non-raising bounded-nesting check for phase B document parsers: a
    malformed document (unbalanced, NaN, a lone surrogate, too deep) must
    still yield an invalid-document result -- never let it, or json.loads/
    canonical's own exceptions, escape past the attempt directory phase B
    has already claimed exclusively, refusing E_PACKAGE with no receipt."""
    try:
        bounded_json_nesting(raw)
        return True
    except Refusal:
        return False


def parse_record(raw):
    """record.json (candidate_content_preparation): flat, no body/id/kind
    envelope (preparation/v1/prepare-candidate.py's make_record). None if
    it doesn't even parse as an object."""
    if not phase_b_json_ok(raw):
        return None
    try:
        doc = json.loads(raw)
    except (ValueError, RecursionError):
        return None
    return doc if isinstance(doc, dict) else None


def parse_manifest(raw):
    """manifest.json (candidate_content_manifest): flat; None unless it is
    canonical (R4.2's "manifest not canonical")."""
    if not phase_b_json_ok(raw):
        return None
    try:
        doc = json.loads(raw)
        if not isinstance(doc, dict) or canonical(doc) != raw:
            return None
    except (ValueError, RecursionError, UnicodeEncodeError):
        return None
    return doc


INCIDENT_ENVELOPE_KEYS = {"body", "id", "kind", "schema_version"}


def parse_incident(raw):
    """incident.json (shadow_incident_record): returns body only if
    canonical, with exactly shadow/v1/incident-record.jq:54-59's envelope
    keys (no more, no fewer) and exactly its body keys -- R4.2 checks only
    the binding fields, not the full shadow schema."""
    if not phase_b_json_ok(raw):
        return None
    try:
        doc = json.loads(raw)
        if not isinstance(doc, dict) or canonical(doc) != raw:
            return None
    except (ValueError, RecursionError, UnicodeEncodeError):
        return None
    if set(doc) != INCIDENT_ENVELOPE_KEYS:
        return None
    if doc.get("kind") != "shadow_incident_record" or not is_int(doc.get("schema_version")) \
            or doc.get("schema_version") != 1:
        return None
    body = doc.get("body")
    return body if isinstance(body, dict) and set(body) == INCIDENT_BODY_KEYS else None


def evaluation_satisfied(raw, control):
    """Mirrors sandbox-receipt.jq's is_evaluation_not_satisfied, against
    the receipt's own (request-echoed) control block."""
    if not phase_b_json_ok(raw):
        return False
    try:
        doc = json.loads(raw)
    except (ValueError, RecursionError, UnicodeEncodeError):
        return False
    if not isinstance(doc, dict) or doc.get("kind") != "sandbox_policy_evaluation" \
            or not is_int(doc.get("schema_version")) or doc.get("schema_version") != 1:
        return False
    body = doc.get("body")
    if not isinstance(body, dict) or body.get("verdict") != "satisfied":
        return False

    def ref_sha(key):
        ref = body.get(key)
        return ref.get("sha256") if isinstance(ref, dict) else None

    return (ref_sha("policy_set") == control["policy_set_sha256"]
            and ref_sha("policy_ref") == control["policy_sha256"]
            and ref_sha("decision_ref") == control["decision_sha256"])


# preparation/v1/prepare-candidate.py:1662-1677's closed manifest-entry
# shape: kind is "file" or "directory" only, mode is "0400"/"0500" for a
# file or "0500" for a directory -- anything else (an unsupported kind
# such as a symlink, or an out-of-set mode such as "0777") must not be
# silently filtered out before candidate/<n> selection.
MANIFEST_ENTRY_MODES = {"file": {"0400", "0500"}, "directory": {"0500"}}


def manifest_entries_ok(entries):
    if not isinstance(entries, list):
        return False
    for e in entries:
        if not isinstance(e, dict):
            return False
        kind, mode = e.get("kind"), e.get("mode")
        # Type-checked first: an unhashable kind/mode (a list, a dict)
        # would otherwise raise TypeError on the "in" checks below.
        if not (isinstance(kind, str) and isinstance(mode, str)):
            return False
        if kind not in MANIFEST_ENTRY_MODES or mode not in MANIFEST_ENTRY_MODES[kind]:
            return False
    return True


def candidate_reasons(manifest, candidates):
    """launch.candidate-mismatch / launch.candidate-oversize: the manifest's
    file entries (in order) against the package's candidate/<n> records --
    R3.3's n-th file entry is record candidate/<n>."""
    reasons = set()
    if sum(len(c) for c in candidates) > CANDIDATE_EXPORT_BYTES:
        reasons.add("launch.candidate-oversize")
    entries = manifest.get("entries") if isinstance(manifest, dict) else None
    if not isinstance(entries, list):
        reasons.add("launch.candidate-mismatch")
        return reasons
    if not manifest_entries_ok(entries):
        reasons.add("launch.manifest-mismatch")
        return reasons
    file_entries = [e for e in entries if e["kind"] == "file"]
    if len(file_entries) != len(candidates):
        reasons.add("launch.candidate-mismatch")
        return reasons
    for entry, content in zip(file_entries, candidates):
        if entry.get("size_bytes") != len(content) or entry.get("sha256") != sha256_hex(content):
            reasons.add("launch.candidate-mismatch")
            break
    return reasons


def subject_mismatch(record, incident_raw, incident_body, subject):
    """launch.subject-mismatch: record source/candidate fields, and the
    incident's own digest, target_repository_id and git_revision_ref."""
    if record is None or record.get("source") != subject["source"]:
        return True
    candidate = record.get("candidate")
    if not isinstance(candidate, dict) or candidate.get("commit_id") != subject["candidate"]["commit_id"] \
            or candidate.get("tree_id") != subject["candidate"]["tree_id"]:
        return True
    if sha256_hex(incident_raw) != subject["incident_sha256"] or incident_body is None:
        return True
    if incident_body["target_repository_id"] != subject["target_repository_id"]:
        return True
    expected_ref = {"repository_id": subject["source"]["repository_id"],
                     "hash_algorithm": subject["source"]["hash_algorithm"],
                     "commit_id": subject["source"]["commit_id"]}
    return incident_body["git_revision_ref"] != expected_ref


def record_manifest_reasons(record_raw, record, manifest_raw, manifest, subject):
    reasons = set()
    if sha256_hex(record_raw) != subject["candidate"]["preparation_record_sha256"]:
        reasons.add("launch.record-mismatch")
    manifest_sha = sha256_hex(manifest_raw)
    record_manifest_sha = record.get("manifest_sha256") if record is not None else None
    if manifest is None or manifest_sha != record_manifest_sha \
            or manifest_sha != subject["candidate"]["manifest_sha256"]:
        reasons.add("launch.manifest-mismatch")
    return reasons


def control_mismatch(control, installed_digests, evaluation_raw):
    return (control["policy_sha256"] != installed_digests["control_policy"]
            or control["decision_sha256"] != installed_digests["control_decision"]
            or control["policy_set_sha256"] != installed_digests["control_policy_set"]
            or control["evaluator_driver_sha256"] != installed_digests["evaluator_driver"]
            or control["evaluator_program_sha256"] != installed_digests["evaluator_program"]
            or control["sandbox_evaluation_sha256"] != sha256_hex(evaluation_raw))


def environment_unlisted(config, registry_environments, accepted_environments, subject):
    if subject["environment_id"] != config["environment_id"]:
        return True
    registry_entry = entry_for(registry_environments, subject["environment_id"])
    if registry_entry is None or entry_for(accepted_environments, subject["environment_id"]) is None:
        return True
    if sha256_hex(canonical(registry_entry)) != subject["environment_entry_sha256"]:
        return True
    return registry_entry["target_repository_id"] != subject["target_repository_id"]


# R2.3's guest_kernel_config composite has no spec-named device list; the
# closed VM shape (R5.4) names exactly two virtio-blk devices, input
# read-only and export read-write -- used here as a defensible closed
# representation (judgment call, flagged in the PR).
KERNEL_CONFIG_DEVICES = ["virtio-blk,readonly", "virtio-blk"]


def measure_identities(identity_fds, instruction_raw, host_config_raw, host_supervisor_raw,
                        python_raw):
    """R2.3: every slot's measured digest is the SHA-256 of its installed
    bytes, read through the fd secure_walk already validated (never a
    fresh open()) -- except host_runtime, guest_kernel_config and host_
    supervisor, each the SHA-256 of a canonical composite over their own
    several constituent bytes (spec.md:60-73's table); verification_
    instructions comes from the package's own instruction record.
    ("observed", digest) normally; ("unobserved", None) only if a
    constituent's bytes could not be read at all (launch.identity-missing)
    -- an observed-but-unaccepted digest is still "observed". Also returns
    the raw guest_kernel_config bytes (or None), so kernel_config_ok reuses
    this single read instead of a second one through the same fd."""
    # Test-only: a real read failure on an already-R10.1-validated fd (same
    # fd the walk just opened, no re-open by path) has no natural trigger
    # short of a genuine I/O fault, so a named slot can be forced
    # "unreadable" here without touching any file's real permissions.
    forced_unreadable = os.environ.get("YSTACK_TEST_IDENTITY_UNREADABLE")

    def read_slot(slot):
        if slot == forced_unreadable:
            return None
        try:
            return read_all(identity_fds[slot])
        except OSError:
            return None

    def hash_slot(slot):
        # Streamed (sha256_fd), never a full read: this slot's bytes are
        # never needed, only their digest.
        if slot == forced_unreadable:
            return None
        try:
            return sha256_fd(identity_fds[slot])
        except OSError:
            return None

    def hash_slot_list(slot):
        if slot == forced_unreadable:
            return None
        try:
            return [sha256_fd(fd) for fd in identity_fds[slot]]
        except OSError:
            return None

    def observe(raw):
        return ("observed", sha256_hex(raw)) if raw is not None else ("unobserved", None)

    def observe_digest(digest):
        return ("observed", digest) if digest is not None else ("unobserved", None)

    result = {slot: observe_digest(hash_slot(slot)) for slot in
              ("guest_kernel", "guest_init", "guest_supervisor", "image", "verifier", "toolchain")}

    constituents = [hash_slot(slot) for slot in ("runtime_vfkit", "runtime_driver", "vm_service")]
    dyld_cache_digests = hash_slot_list("dyld_cache_files")
    if None in constituents or dyld_cache_digests is None:
        result["host_runtime"] = ("unobserved", None)
    else:
        files = [{"path": n, "sha256": d} for n, d in
                 zip(("vfkit", "driver", "vm_service"), constituents)]
        files += [{"path": "dyld_cache.%d" % i, "sha256": d}
                  for i, d in enumerate(dyld_cache_digests)]
        result["host_runtime"] = observe(canonical({"files": files}))

    kernel_config_raw = read_slot("guest_kernel_config")
    if kernel_config_raw is None:
        result["guest_kernel_config"] = ("unobserved", None)
    else:
        result["guest_kernel_config"] = observe(canonical({
            "command_line": "console= quiet lsm=landlock rdinit=/init", "cpu_count": 1,
            "devices": KERNEL_CONFIG_DEVICES,
            "kernel_build_config_sha256": sha256_hex(kernel_config_raw),
            "memory_bytes": 536870912}))

    if None in (host_config_raw, host_supervisor_raw, python_raw):
        result["host_supervisor"] = ("unobserved", None)
    else:
        result["host_supervisor"] = observe(canonical({
            "config_sha256": sha256_hex(host_config_raw),
            "files": [{"path": "host-supervisor.py", "sha256": sha256_hex(host_supervisor_raw)}],
            "python_sha256": sha256_hex(python_raw)}))

    result["verification_instructions"] = ("observed", sha256_hex(instruction_raw))
    return result, kernel_config_raw


def phase_b_reasons(config, request_body, package, identity_fds, installed_digests,
                     registry_environments, accepted_environments, host_config_raw,
                     host_supervisor_raw, python_raw):
    """Every R4.2 reason, sorted and unique, plus the measured identities
    dict for the receipt. Collects every applicable reason (not just the
    first), matching the receipt's own sorted-unique reason_ids."""
    subject, control = request_body["subject"], request_body["control"]
    reasons = set()
    if environment_unlisted(config, registry_environments, accepted_environments, subject):
        reasons.add("launch.environment-unlisted")
    if control_mismatch(control, installed_digests, package["evaluation.json"]):
        reasons.add("launch.control-mismatch")
    if not evaluation_satisfied(package["evaluation.json"], control):
        reasons.add("launch.evaluation-not-satisfied")
    record = parse_record(package["record.json"])
    manifest = parse_manifest(package["manifest.json"])
    incident_body = parse_incident(package["incident.json"])
    reasons |= record_manifest_reasons(package["record.json"], record,
                                        package["manifest.json"], manifest, subject)
    if subject_mismatch(record, package["incident.json"], incident_body, subject):
        reasons.add("launch.subject-mismatch")
    reasons |= candidate_reasons(manifest, package["candidate"])
    instruction_raw = package["instruction"]
    if sha256_hex(instruction_raw) != request_body["instruction_sha256"]:
        reasons.add("launch.instruction-mismatch")
    measured, kernel_config_raw = measure_identities(identity_fds, instruction_raw, host_config_raw,
                                                       host_supervisor_raw, python_raw)
    if any(state == "unobserved" for state, _ in measured.values()):
        reasons.add("launch.identity-missing")
    if kernel_config_raw is not None and not kernel_config_ok(kernel_config_raw):
        reasons.add("launch.kernel-config")
    accepted_entry = entry_for(accepted_environments, subject["environment_id"])
    if accepted_entry is not None:
        accepted_identities = accepted_entry["identities"]
        if any(state == "observed" and digest not in accepted_identities[slot]
               for slot, (state, digest) in measured.items() if slot != "verification_instructions"):
            reasons.add("launch.identity-unaccepted")
        if measured["verification_instructions"][1] not in accepted_identities["verification_instructions"]:
            reasons.add("launch.instruction-unaccepted")
    return sorted(reasons), measured


# --- R5.1 freeze by copy: package bytes copied into supervisor-owned files
# under work_root, exclusively, before anything else touches them again. --
FROZEN_FIXED_NAMES = ("record.json", "manifest.json", "instruction")
# Fixed work_root names (nonces/, the replay markers) an attempt_id must
# never collide with -- reserved (E_PACKAGE) up front.
RESERVED_WORK_ROOT_NAMES = frozenset({"nonces"})


def freeze_by_copy(config, attempt_id, uid, gid, package):
    """R5.1. Returns the candidate/ filenames it created -- the only
    variable-count entries -- so teardown removes exactly what this
    attempt made, never whatever a directory listing happens to find."""
    work_fd = os.open(config["work_root"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        try:
            attempt_work_fd = mkdir_excl(work_fd, attempt_id, uid, gid)
        except FileExistsError:
            # Never ours to touch: refuse before anything is written, so
            # no cleanup path can run against it (unlike a genuine
            # mid-freeze write failure below).
            refuse("E_ATTEMPT_EXISTS")
        try:
            frozen_fd = mkdir_excl(attempt_work_fd, "frozen", uid, gid)
            try:
                for name in FROZEN_FIXED_NAMES:
                    write_excl(frozen_fd, name, package[name], uid, gid)
                if os.environ.get("YSTACK_TEST_FREEZE_FAIL"):
                    raise OSError("test-only simulated freeze failure")
                if os.environ.get("YSTACK_TEST_PLANT_EXTRA_FILE"):
                    write_excl(frozen_fd, "unexpected.txt", b"x", uid, gid)
                candidate_names = ["%05d" % i for i in range(len(package["candidate"]))]
                candidate_fd = mkdir_excl(frozen_fd, "candidate", uid, gid)
                try:
                    for name, content in zip(candidate_names, package["candidate"]):
                        write_excl(candidate_fd, name, content, uid, gid)
                    os.fsync(candidate_fd)
                finally:
                    os.close(candidate_fd)
                os.fsync(frozen_fd)
            finally:
                os.close(frozen_fd)
            os.fsync(attempt_work_fd)
        finally:
            os.close(attempt_work_fd)
        os.fsync(work_fd)
    finally:
        os.close(work_fd)
    return candidate_names


def remove_only(dir_fd, created_names):
    """Unlinks exactly the names this attempt is known to have created,
    never anything a directory listing happens to find (R9.3's security
    boundary): an unexpected survivor is left in place, reported by the
    caller re-checking the directory."""
    for name in created_names:
        try:
            os.unlink(name, dir_fd=dir_fd)
        except FileNotFoundError:
            pass
    return not os.listdir(dir_fd)


def remove_frozen(work_root, attempt_id, candidate_names):
    """Removes exactly the entries freeze_by_copy created -- the frozen/
    files, candidate/, frozen/ itself and the attempt's own <work_root>/
    <attempt_id> directory -- and verifies absence at each level (R9.3:
    storage_destroyed is true iff the host removed exactly the entries it
    created and lstat then confirms absence; an unexpected entry is left
    in place and makes it false, never silently unlinked)."""
    if os.environ.get("YSTACK_TEST_TEARDOWN_FAIL"):
        return False
    # Bounded to this exact shape at every level; a level missing
    # entirely is skipped, never a listing of arbitrary contents.
    work_fd = None
    try:
        work_fd = os.open(work_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            attempt_fd = os.open(attempt_id, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=work_fd)
        except FileNotFoundError:
            return True
        try:
            try:
                frozen_fd = os.open("frozen", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=attempt_fd)
            except FileNotFoundError:
                frozen_fd = None
            if frozen_fd is not None:
                try:
                    try:
                        candidate_fd = os.open("candidate", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                                dir_fd=frozen_fd)
                    except FileNotFoundError:
                        candidate_fd = None
                    if candidate_fd is not None:
                        try:
                            if not remove_only(candidate_fd, candidate_names):
                                return False
                        finally:
                            os.close(candidate_fd)
                        os.rmdir("candidate", dir_fd=frozen_fd)
                    if not remove_only(frozen_fd, FROZEN_FIXED_NAMES):
                        return False
                finally:
                    os.close(frozen_fd)
                os.rmdir("frozen", dir_fd=attempt_fd)
            if os.listdir(attempt_fd):
                return False
        finally:
            os.close(attempt_fd)
        os.rmdir(attempt_id, dir_fd=work_fd)
        try:
            os.stat(attempt_id, dir_fd=work_fd, follow_symlinks=False)
        except OSError:
            return True
        return False
    except OSError:
        return False
    finally:
        if work_fd is not None:
            os.close(work_fd)


# --- R10.2 store writer: O_CREAT|O_EXCL relative to a directory fd, fsync,
# then the final mode; directories 0750, files 0440. --------------------
def mkdir_excl(parent_fd, name, uid, gid):
    os.mkdir(name, mode=0o700, dir_fd=parent_fd)
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    try:
        if name == os.environ.get("YSTACK_TEST_MKDIR_FINALIZE_FAIL"):
            raise OSError("test-only simulated finalize failure")
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


def work_root_attempt_exists(work_root, attempt_id):
    """A work_root/<attempt_id> collision (no store entry) must refuse
    E_ATTEMPT_EXISTS before the store is ever claimed -- checked, not
    removed; freeze_by_copy's own exclusive mkdir remains the
    post-admission path for anything created after this check."""
    fd = os.open(work_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.stat(attempt_id, dir_fd=fd, follow_symlinks=False)
        return True
    except OSError:
        return False
    finally:
        os.close(fd)


def create_attempt_dir(store_fd, uid, gid, attempt_id):
    """R4.2: 'the attempt directory is created exclusively, then every
    check below runs' -- so phase B's checks run only once this attempt id
    is exclusively claimed. Rechecks store_fd's own state first (held open
    since check_store_root; a store_root replaced after admission cannot
    redirect this)."""
    require(store_root_state_ok(store_fd, uid, gid), "E_STORE")
    try:
        return mkdir_excl(store_fd, attempt_id, uid, gid)
    except FileExistsError:
        refuse("E_ATTEMPT_EXISTS")


def write_attempt_result(store_fd, attempt_fd, uid, gid, receipt_bytes, payload):
    """Writes payload/ and receipt.json into the already-claimed attempt_fd,
    then fsyncs up to the store root."""
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


def identities_for_receipt(measured):
    """R4.2: an observed slot (even an unaccepted digest -- the receipt
    "records the digest of the bytes actually supplied") is {state,sha256};
    only an unreadable slot is unobserved, with launch.identity-missing."""
    result = {}
    for slot in IDENTITY_SLOTS:
        state, digest = measured[slot]
        if state == "observed":
            result[slot] = {"state": "observed", "sha256": digest}
        else:
            result[slot] = {"state": "unobserved", "reason_id": "launch.identity-missing"}
    return result


def build_receipt(config, accepted_set_sha256, request_doc, request_body, launch_request_sha256,
                   admitted_at, evidence_manifest_sha256, identities, admission, runtime,
                   storage_destroyed=True):
    now = time.time()
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
        "lifecycle": {"admission": admission, "runtime": runtime, "control_deadline": "met"},
        "limits": limits,
        "origin": {"producer_role": "host-supervisor", "store_id": config["store_id"],
                   "accepted_set_sha256": accepted_set_sha256},
        "payload": {"stdout_sha256": empty, "stderr_sha256": empty,
                    "evidence_manifest_sha256": evidence_manifest_sha256, "exit_state": "not-started",
                    "exit_code": None},
        "subject": dict(request_body["subject"]),
        "teardown": {"state": "confirmed" if storage_destroyed else "failed",
                     "tree_terminated": True, "storage_destroyed": storage_destroyed},
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
    config, config_raw = load_config(fixed_fds[config_path])
    principal_uid = config["principal_uid"]
    require(principal_uid == os.getuid(), "E_CONFIG")
    for fd in fixed_fds.values():
        if not owner_mode_fd_ok(fd, principal_uid):
            refuse("E_CONFIG")
    # host-supervisor.py's own installed bytes feed the host_supervisor
    # composite (R2.3); its fd is read and retained before the generic
    # close, never re-opened by path.
    host_supervisor_path = os.path.join(install_dir, "host-supervisor.py")
    host_supervisor_raw = read_all_or_refuse(fixed_fds[host_supervisor_path])
    for fd in fixed_fds.values():
        os.close(fd)
    # The interpreter path is measured too (R2.3's host_supervisor slot),
    # so it goes through the same R10.1 walk as everything else installed.
    # sys.executable can itself be a symlink (a version shim, common with
    # both system and third-party interpreters); the walk requires an
    # already-physical path (same convention as install_directory's own
    # realpath), so it is resolved once, here, before validation.
    python_raw = read_all_or_refuse(secure_walk(os.path.realpath(sys.executable), principal_uid,
                                                 check_mode=True))
    # Every identity_paths and control-related installed_files fd is kept
    # open (R2.3/R4.2 read their content below, through these same fds --
    # never a fresh open() of the path string); runtime.vfkit/driver are
    # kept open too now (host_runtime composite constituents), under the
    # same identity_fds dict so the existing close loop covers them.
    identity_fds = {slot: secure_walk(path, principal_uid, check_mode=True)
                     for slot, path in config["identity_paths"].items()
                     if slot != "dyld_cache_files"}
    identity_fds["dyld_cache_files"] = [secure_walk(p, principal_uid, check_mode=True)
                                         for p in config["identity_paths"]["dyld_cache_files"]]
    identity_fds["runtime_vfkit"] = secure_walk(config["runtime"]["vfkit"], principal_uid,
                                                 check_mode=True)
    identity_fds["runtime_driver"] = secure_walk(config["runtime"]["driver"], principal_uid,
                                                  check_mode=True)
    installed_fds = {name: secure_walk(path, principal_uid, check_mode=True)
                      for name, path in config["installed_files"].items()}
    accepted_set_sha256, accepted_environments = check_accepted_set(installed_fds.pop("accepted_set"))
    registry_environments = load_registry(installed_fds.pop("registry"))
    installed_digests = {}
    for name in ("control_policy", "control_decision", "control_policy_set",
                 "evaluator_driver", "evaluator_program"):
        fd = installed_fds.pop(name)
        installed_digests[name] = sha256_hex(read_all_or_refuse(fd))
        os.close(fd)
    for fd in installed_fds.values():
        os.close(fd)
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
    # Reserved before the nonce is touched -- see RESERVED_WORK_ROOT_NAMES.
    attempt_id = request_body["attempt"]["attempt_id"]
    require(attempt_id not in RESERVED_WORK_ROOT_NAMES, "E_PACKAGE")
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
        os.stat(attempt_id, dir_fd=store_fd, follow_symlinks=False)
    except OSError:
        pass
    else:
        refuse("E_ATTEMPT_EXISTS")
    # Checked (never removed) before the store is claimed: a work_root
    # collision with no store entry must not surface as a bare freeze
    # failure after admission (an orphan store dir, no receipt).
    require(not work_root_attempt_exists(config["work_root"], attempt_id), "E_ATTEMPT_EXISTS")

    # R4.2: the attempt directory is created exclusively, then every phase B
    # check runs. From here on, any OSError (including a finalization
    # failure right after mkdir_excl, or the store write itself) is
    # E_STORE_WRITE/exit 70, never a bare traceback (R10.4).
    try:
        attempt_fd = create_attempt_dir(store_fd, principal_uid, config["consumer_gid"], attempt_id)
        admitted_at = time.time()
        reason_ids, measured = phase_b_reasons(config, request_body, package, identity_fds,
                                                installed_digests, registry_environments,
                                                accepted_environments, config_raw,
                                                host_supervisor_raw, python_raw)
        for fd in identity_fds.values():
            for f in (fd if isinstance(fd, list) else [fd]):
                os.close(f)
        identities = identities_for_receipt(measured)
        # R8.3: built once, reused for both the receipt digest and the write.
        evidence_manifest_bytes = canonical({"body": {"files": []}, "id": "evidence-manifest",
                                              "kind": "sandbox_evidence_manifest", "schema_version": 1})
        evidence_manifest_sha256 = sha256_hex(evidence_manifest_bytes)
        payload = [("stdout", b""), ("stderr", b""),
                   ("evidence-manifest.json", evidence_manifest_bytes)]
        if reason_ids:
            # R9.3: no-launch receipt -- refused, runtime "completed" (nothing
            # ran, so nothing errored), payload/refusal.json alongside it.
            receipt_bytes = build_receipt(config, accepted_set_sha256, request_doc, request_body,
                                           launch_request_sha256, admitted_at, evidence_manifest_sha256,
                                           identities, "refused", "completed")
            payload.append(("refusal.json", canonical({"reason_ids": reason_ids})))
        else:
            # R5.1: freeze by copy before anything else -- still PR 3's own
            # R9.4 stub past this point (no runtime exists before PR 5), so the
            # frozen copies are the attempt's only work_root storage; R9.3's
            # "storage_destroyed follows the removal of its package copies"
            # applies here too -- they are removed and the removal verified
            # before the receipt can honestly claim storage_destroyed: true.
            # A freeze failure itself (ENOSPC, a write error, a name collision)
            # must never escape as a traceback with a claimed store dir and no
            # receipt (R10.4): clean up whatever this attempt's own directory
            # holds and still write an honest failed-teardown receipt below --
            # only a receipt-write failure itself exits 70.
            try:
                candidate_names = freeze_by_copy(config, attempt_id, principal_uid,
                                                  config["consumer_gid"], package)
            except OSError:
                # A genuine mid-freeze write failure: the candidate count is
                # still known from the package, so the same exact-inventory
                # removal the success path uses applies here too.
                candidate_names = ["%05d" % i for i in range(len(package["candidate"]))]
                storage_destroyed = remove_frozen(config["work_root"], attempt_id, candidate_names)
            else:
                storage_destroyed = remove_frozen(config["work_root"], attempt_id, candidate_names)
            receipt_bytes = build_receipt(config, accepted_set_sha256, request_doc, request_body,
                                           launch_request_sha256, admitted_at, evidence_manifest_sha256,
                                           identities, "admitted", "error", storage_destroyed)
        write_attempt_result(store_fd, attempt_fd, principal_uid, config["consumer_gid"],
                              receipt_bytes, payload)
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
