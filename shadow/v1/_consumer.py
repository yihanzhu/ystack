#!/usr/bin/env python3
"""Private trust primitives for the inactive shadow consumer.

This module authenticates inputs to later consumer slices.  It does not launch a
VM, run the materializer, or publish evidence.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import dataclasses
import errno
import fcntl
import hashlib
import json
import os
import stat
import sys
from typing import Callable


ANCHOR = "/usr/local/libexec/ystack-sandbox/v1/supervisor"
HELPER_SOURCE_SHA256 = "f1616b908c97e8a091029c24b3f2e1f8827171cbdee4d47195c66afd3e961e27"
HELPER_SOURCE = "adapters/local-git-materializer/v1/object-closure.c"
PARENT_LIMIT = 16 * 1024
DOCUMENT_LIMIT = 1024 * 1024
HELPER_LIMIT = 16 * 1024 * 1024
JQ_SHA256 = {"darwin": "5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef",
             "linux": "af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44"}
HASH_KEYS = ("helper_source_sha256", "helper_build_record_sha256", "helper_executable_sha256")
CONFIG_KEYS = {
    "consumer_gid", "environment_id", "identity_paths", "installed_files",
    "principal_uid", "runtime", "store_id", "store_root", "work_root",
}
IDENTITY_KEYS = {
    "guest_init", "guest_kernel", "guest_kernel_config", "guest_supervisor",
    "host_runtime", "host_supervisor", "image", "toolchain", "verifier",
    "vm_service", "dyld_cache_files",
}
INSTALLED_KEYS = {
    "accepted_set", "control_decision", "control_policy", "control_policy_set",
    "evaluator_driver", "evaluator_program", "registry",
}


class Refusal(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code

def _require(value: bool, code: str) -> None:
    if not value:
        raise Refusal(code)
def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                      allow_nan=False).encode("utf-8") + b"\n"
def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha(value: object) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)
def _id(value: object) -> bool:
    return isinstance(value, str) and 1 <= len(value) <= 128 and value[0].isalnum() and all(c.isalnum() or c in "._-" for c in value)
def _json(raw: bytes, maximum: int, code: str) -> dict:
    _require(len(raw) <= maximum, code)
    try:
        value = json.loads(raw, object_pairs_hook=_unique_object)
        _require(isinstance(value, dict) and canonical(value) == raw, code)
    except (UnicodeDecodeError, ValueError, TypeError, RecursionError):
        raise Refusal(code) from None
    return value

def _unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result

def _identity(st: os.stat_result) -> tuple[int, ...]:
    return (st.st_dev, st.st_ino, stat.S_IFMT(st.st_mode), st.st_uid, st.st_gid,
            stat.S_IMODE(st.st_mode), st.st_nlink, st.st_size,
            st.st_mtime_ns, st.st_ctime_ns)

@dataclasses.dataclass
class HeldFile:
    path: str
    fds: list[int]
    name: str
    before: os.stat_result

    @property
    def fd(self) -> int:
        return self.fds[-1]

    def read(self, maximum: int, code: str) -> bytes:
        before = os.fstat(self.fd)
        _require(_identity(before) == _identity(self.before), code)
        try:
            os.lseek(self.fd, 0, os.SEEK_SET)
            chunks, total = [], 0
            while True:
                chunk = os.read(self.fd, min(65536, maximum + 1 - total))
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                _require(total <= maximum, code)
        except OSError:
            raise Refusal(code) from None
        self.recheck(code)
        return b"".join(chunks)

    def recheck(self, code: str) -> None:
        try:
            current = os.fstat(self.fd)
            named = os.stat(self.name, dir_fd=self.fds[-2], follow_symlinks=False)
        except OSError:
            raise Refusal(code) from None
        expected = _identity(self.before)
        _require(_identity(current) == expected and _identity(named) == expected, code)

    def close(self) -> None:
        for fd in reversed(self.fds):
            try:
                os.close(fd)
            except OSError:
                pass
        self.fds.clear()

def _open_held(path: str, directory: bool, rule: Callable[[int, os.stat_result, bool], bool],
               code: str) -> HeldFile:
    _require(isinstance(path, str) and path.startswith("/") and path != "/", code)
    parts = path.split("/")[1:]
    _require(all(p not in ("", ".", "..") for p in parts), code)
    fds = []
    try:
        fds.append(os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW))
        _require(rule(fds[0], os.fstat(fds[0]), True), code)
        for index, part in enumerate(parts):
            last = index == len(parts) - 1
            flags = os.O_RDONLY | os.O_NOFOLLOW
            if not last or directory:
                flags |= os.O_DIRECTORY
            fd = os.open(part, flags, dir_fd=fds[-1])
            fds.append(fd)
            st = os.fstat(fd)
            _require(rule(fd, st, not last), code)
        st = os.fstat(fds[-1])
        _require((directory and stat.S_ISDIR(st.st_mode)) or
                 (not directory and stat.S_ISREG(st.st_mode) and st.st_nlink == 1), code)
        return HeldFile(path, fds, parts[-1], st)
    except (OSError, ValueError, Refusal):
        for fd in reversed(fds):
            os.close(fd)
        raise Refusal(code) from None

def _open_child(parent: HeldFile, name: str, directory: bool,
                rule: Callable[[int, os.stat_result, bool], bool], code: str) -> HeldFile:
    _require(name and "/" not in name and name not in (".", ".."), code)
    fds = []
    try:
        parent.recheck(code)
        parent_fd = os.dup(parent.fd)
        fds.append(parent_fd)
        flags = os.O_RDONLY | os.O_NOFOLLOW | (os.O_DIRECTORY if directory else 0)
        fd = os.open(name, flags, dir_fd=parent_fd)
        fds.append(fd)
        st = os.fstat(fd)
        _require(rule(fd, st, False), code)
        _require((directory and stat.S_ISDIR(st.st_mode)) or
                 (not directory and stat.S_ISREG(st.st_mode) and st.st_nlink == 1), code)
        return HeldFile(parent.path + "/" + name, fds, name, st)
    except (OSError, ValueError, Refusal):
        for fd in reversed(fds):
            os.close(fd)
        raise Refusal(code) from None

def _linux_acl(fd: int) -> list[tuple[int, int, int]]:
    try:
        raw = os.getxattr(fd, "system.posix_acl_access")
    except OSError as exc:
        if exc.errno in (errno.ENODATA, getattr(errno, "ENOATTR", errno.ENODATA)):
            return []
        raise
    _require(len(raw) >= 4 and raw[:4] == b"\x02\x00\x00\x00" and (len(raw) - 4) % 8 == 0,
             "E_ACL")
    return [(int.from_bytes(raw[i:i + 2], "little"),
             int.from_bytes(raw[i + 2:i + 4], "little"),
             int.from_bytes(raw[i + 4:i + 8], "little")) for i in range(4, len(raw), 8)]

def _darwin_acl(fd: int) -> list[tuple[int, int | None, int]]:
    lib = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    lib.acl_get_fd_np.restype = ctypes.c_void_p
    lib.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    lib.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    lib.acl_get_tag_type.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    lib.acl_get_qualifier.restype = ctypes.c_void_p
    lib.acl_get_qualifier.argtypes = [ctypes.c_void_p]
    lib.acl_get_permset.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
    lib.acl_get_perm_np.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    lib.mbr_uuid_to_id.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint32),
                                   ctypes.POINTER(ctypes.c_int)]
    lib.acl_free.argtypes = [ctypes.c_void_p]
    acl = lib.acl_get_fd_np(fd, 0x100)
    if not acl:
        if ctypes.get_errno() == errno.ENOENT:
            return []
        raise OSError(ctypes.get_errno(), "acl_get_fd_np")
    entries, entry = [], ctypes.c_void_p()
    try:
        rc = lib.acl_get_entry(acl, 0, ctypes.byref(entry))
        while rc == 0:
            tag, perms = ctypes.c_int(), ctypes.c_void_p()
            lib.acl_get_tag_type(entry, ctypes.byref(tag))
            lib.acl_get_permset(entry, ctypes.byref(perms))
            bits = sum(1 << n for n in range(1, 14) if lib.acl_get_perm_np(perms, 1 << n))
            identifier = None
            qualifier = lib.acl_get_qualifier(entry)
            if qualifier:
                value, kind = ctypes.c_uint32(), ctypes.c_int()
                uuid = ctypes.string_at(qualifier, 16)
                if lib.mbr_uuid_to_id(uuid, ctypes.byref(value), ctypes.byref(kind)) == 0 and kind.value == 0:
                    identifier = value.value
                lib.acl_free(qualifier)
            entries.append((tag.value, identifier, bits))
            _require(len(entries) <= 128, "E_ACL")
            rc = lib.acl_get_entry(acl, -1, ctypes.byref(entry))
    finally:
        lib.acl_free(acl)
    return entries

def _acl(fd: int) -> list[tuple[int, int | None, int]]:
    return _darwin_acl(fd) if sys.platform == "darwin" else _linux_acl(fd)


def _root_rule(fd: int, st: os.stat_result, _ancestor: bool) -> bool:
    if st.st_uid != 0 or st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        return False
    try:
        entries = _acl(fd)
    except (OSError, Refusal):
        return False
    if sys.platform == "darwin":
        dangerous = sum(1 << n for n in (2, 4, 5, 6, 8, 10, 12, 13))
        return not any(tag == 1 and identifier != 0 and bits & dangerous for tag, identifier, bits in entries)
    return not any((tag in (0x02, 0x08)) or (tag == 0x10 and perms & 2)
                   for tag, perms, _identifier in entries)


def _installed_rule(principal_uid: int) -> Callable[[int, os.stat_result, bool], bool]:
    def check(fd: int, st: os.stat_result, _ancestor: bool) -> bool:
        if st.st_uid not in (0, principal_uid) or st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            return False
        try:
            return _root_rule_acl(fd, principal_uid)
        except (OSError, Refusal):
            return False
    return check

def _root_rule_acl(fd: int, principal_uid: int) -> bool:
    entries = _acl(fd)
    if sys.platform != "darwin":
        return not any((tag == 0x08) or (tag == 0x10 and perms & 2) or
                       (tag == 0x02 and identifier not in (0, principal_uid))
                       for tag, perms, identifier in entries)
    dangerous = sum(1 << n for n in (2, 4, 5, 6, 8, 10, 12, 13))
    return not any(tag == 1 and bits & dangerous and identifier not in (0, principal_uid)
                   for tag, identifier, bits in entries)

def _store_rule(uid: int, gid: int, mode: int, directory: bool) -> Callable[[int, os.stat_result, bool], bool]:
    def check(fd: int, st: os.stat_result, ancestor: bool) -> bool:
        if ancestor:
            return True
        try:
            no_acl = _acl(fd) == []
        except (OSError, Refusal):
            return False
        kind = stat.S_ISDIR(st.st_mode) if directory else stat.S_ISREG(st.st_mode)
        return kind and st.st_uid == uid and st.st_gid == gid and stat.S_IMODE(st.st_mode) == mode and no_acl
    return check

def capture_parent_context(fd: int = 3) -> dict:
    try:
        flags, before = fcntl.fcntl(fd, fcntl.F_GETFL), os.fstat(fd)
        _require(flags & os.O_ACCMODE == os.O_RDONLY and stat.S_ISREG(before.st_mode), "E_PARENT_CONTEXT")
        raw = _read_plain_fd(fd, PARENT_LIMIT)
        after = os.fstat(fd)
    except (OSError, ValueError, Refusal):
        raise Refusal("E_PARENT_CONTEXT") from None
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
    _require(_identity(before) == _identity(after), "E_PARENT_CONTEXT")
    doc = _json(raw, PARENT_LIMIT, "E_PARENT_CONTEXT")
    _require(set(doc) == {"schema_version", "kind", "id", "body"} and doc["schema_version"] == 1
             and doc["kind"] == "shadow_consumer_parent_context" and doc["id"] == "shadow.parent",
             "E_PARENT_CONTEXT")
    body = doc["body"]
    _require(isinstance(body, dict) and set(body) == set(HASH_KEYS) | {"helper_executable_size", "helper_path"},
             "E_PARENT_CONTEXT")
    _require(all(_sha(body[k]) for k in HASH_KEYS), "E_PARENT_CONTEXT")
    size = body["helper_executable_size"]
    _require(isinstance(size, int) and not isinstance(size, bool) and 0 < size <= HELPER_LIMIT,
             "E_PARENT_CONTEXT")
    path = body["helper_path"]
    _require(isinstance(path, str) and path.startswith("/") and os.path.normpath(path) == path,
             "E_PARENT_CONTEXT")
    _require(body["helper_source_sha256"] == HELPER_SOURCE_SHA256, "E_PARENT_CONTEXT")
    return body

def _read_plain_fd(fd: int, maximum: int) -> bytes:
    os.lseek(fd, 0, os.SEEK_SET)
    chunks, total = [], 0
    while True:
        part = os.read(fd, min(65536, maximum + 1 - total))
        if not part:
            return b"".join(chunks)
        chunks.append(part)
        total += len(part)
        _require(total <= maximum, "E_LIMIT")

@dataclasses.dataclass
class DependencySnapshot:
    original: HeldFile
    snapshot: HeldFile
    sha256: str
    size: int

    def recheck(self) -> None:
        self.original.recheck("E_DEPENDENCY")
        self.snapshot.recheck("E_DEPENDENCY")
        _require(digest(self.snapshot.read(self.size, "E_DEPENDENCY")) == self.sha256,
                 "E_DEPENDENCY")

    def close(self) -> None:
        self.original.close()
        self.snapshot.close()

def snapshot_dependency(path: str, expected_sha256: str, expected_size: int,
                        private_dir: str, name: str) -> DependencySnapshot:
    _require(_sha(expected_sha256) and 0 < expected_size <= HELPER_LIMIT, "E_DEPENDENCY")
    original = _open_held(path, False, lambda _fd, _st, _a: True, "E_DEPENDENCY")
    try:
        raw = original.read(expected_size, "E_DEPENDENCY")
        _require(len(raw) == expected_size and digest(raw) == expected_sha256, "E_DEPENDENCY")
        parent_path, directory_name = os.path.split(private_dir)
        parent = _open_held(parent_path, True, lambda _fd, _st, _a: True, "E_DEPENDENCY")
        try:
            os.mkdir(directory_name, 0o700, dir_fd=parent.fd)
            directory_fd = os.open(directory_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                   dir_fd=parent.fd)
            out = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                          0o500, dir_fd=directory_fd)
            try:
                written = 0
                while written < len(raw):
                    count = os.write(out, raw[written:])
                    _require(count > 0, "E_DEPENDENCY")
                    written += count
                os.fsync(out)
            finally:
                os.close(out)
            os.fchmod(directory_fd, 0o500)
            os.fsync(directory_fd)
        finally:
            if 'directory_fd' in locals():
                os.close(directory_fd)
            parent.close()
        snap = _open_held(os.path.join(private_dir, name), False,
                          lambda _fd, st, ancestor: ancestor or stat.S_IMODE(st.st_mode) == 0o500,
                          "E_DEPENDENCY")
        return DependencySnapshot(original, snap, expected_sha256, expected_size)
    except (OSError, ValueError, Refusal):
        original.close()
        raise Refusal("E_DEPENDENCY") from None
    except BaseException:
        original.close()
        raise

def verify_helper_source(source_root: str) -> None:
    source = _open_held(os.path.join(source_root, HELPER_SOURCE), False,
                        lambda _fd, _st, _a: True, "E_DEPENDENCY")
    try:
        _require(digest(source.read(DOCUMENT_LIMIT, "E_DEPENDENCY")) == HELPER_SOURCE_SHA256,
                 "E_DEPENDENCY")
    finally:
        source.close()

def snapshot_jq(path: str, private_dir: str) -> DependencySnapshot:
    expected = JQ_SHA256.get(sys.platform)
    _require(expected is not None, "E_DEPENDENCY")
    held = _open_held(path, False, lambda _fd, _st, _a: True, "E_DEPENDENCY")
    try:
        size = held.before.st_size
    finally:
        held.close()
    return snapshot_dependency(path, expected, size, private_dir, "jq")

def isolated_python_argv(source_root: str) -> list[str]:
    executable = sys.executable
    module = os.path.join(source_root, "shadow/v1/_consumer.py")
    _require(os.path.isabs(executable) and os.path.realpath(executable) == executable and
             os.path.isabs(source_root) and os.path.realpath(source_root) == source_root and
             os.path.realpath(module) == module, "E_DEPENDENCY")
    held = _open_held(module, False, lambda _fd, _st, _a: True, "E_DEPENDENCY")
    held.close()
    return [executable, "-I", "-S", "-B", module]

@dataclasses.dataclass
class Anchor:
    config: dict
    config_raw: bytes
    held: list[HeldFile]

    def recheck(self) -> None:
        for item in self.held:
            item.recheck("E_INSTALL")

    def close(self) -> None:
        for item in self.held:
            item.close()

def load_anchor() -> Anchor:
    anchor = _open_held(ANCHOR, True, _root_rule, "E_INSTALL")
    config = script = None
    try:
        config = _open_held(ANCHOR + "/host-config.json", False, _root_rule, "E_CONFIG")
        script = _open_held(ANCHOR + "/host-supervisor.py", False, _root_rule, "E_INSTALL")
        raw = config.read(DOCUMENT_LIMIT, "E_CONFIG")
        body = _parse_config(raw)
        uid, gid = body["principal_uid"], body["consumer_gid"]
        _require(uid > 0 and uid not in (os.getuid(), os.geteuid()), "E_CONFIG")
        _require(gid in os.getgroups() or gid in (os.getgid(), os.getegid()), "E_CONFIG")
        held = [anchor, config, script]
        for path in list(body["installed_files"].values()) + [body["identity_paths"]["verifier"]]:
            held.append(_open_held(path, False, _installed_rule(uid), "E_INSTALL"))
        held.append(_open_held(sys.executable, False, _installed_rule(uid), "E_INSTALL"))
        return Anchor(body, raw, held)
    except BaseException:
        for item in (script, config, anchor):
            if item:
                item.close()
        raise

def _parse_config(raw: bytes) -> dict:
    doc = _json(raw, DOCUMENT_LIMIT, "E_CONFIG")
    _require(set(doc) == {"schema_version", "kind", "id", "body"} and doc["schema_version"] == 1
             and doc["kind"] == "sandbox_host_config", "E_CONFIG")
    body = doc["body"]
    _require(isinstance(body, dict) and set(body) == CONFIG_KEYS, "E_CONFIG")
    _require(isinstance(body["principal_uid"], int) and not isinstance(body["principal_uid"], bool)
             and isinstance(body["consumer_gid"], int) and not isinstance(body["consumer_gid"], bool),
             "E_CONFIG")
    _require(_id(body["store_id"]) and _id(body["environment_id"]), "E_CONFIG")
    _require(isinstance(body["runtime"], dict) and set(body["runtime"]) == {"driver", "vfkit"}
             and isinstance(body["identity_paths"], dict)
             and isinstance(body["installed_files"], dict), "E_CONFIG")
    _require(set(body["identity_paths"]) == IDENTITY_KEYS and set(body["installed_files"]) == INSTALLED_KEYS,
             "E_CONFIG")
    paths = [body["store_root"], body["work_root"], body["runtime"].get("driver"),
             body["runtime"].get("vfkit")] + list(body["installed_files"].values())
    paths += [v for k, v in body["identity_paths"].items() if k != "dyld_cache_files"]
    _require(all(isinstance(p, str) and p.startswith("/") for p in paths), "E_CONFIG")
    caches = body["identity_paths"]["dyld_cache_files"]
    _require(isinstance(caches, list) and caches and all(isinstance(p, str) and p.startswith("/") for p in caches),
             "E_CONFIG")
    all_paths = list(body["installed_files"].values()) + [v for k, v in body["identity_paths"].items()
                                                            if k != "dyld_cache_files"] + caches
    _require(len(all_paths) == len(set(all_paths)), "E_CONFIG")
    return body

def _entry(held: HeldFile, relative: str, raw: bytes) -> dict:
    st = held.before
    return {"name": relative, "before": list(_identity(st)), "after": list(_identity(os.fstat(held.fd))),
            "size": len(raw), "sha256": digest(raw)}

def read_store_attempt(anchor: Anchor, attempt_id: str) -> tuple[dict[str, bytes], bytes]:
    _require(_id(attempt_id), "E_STORE")
    anchor.recheck()
    uid, gid = anchor.config["principal_uid"], anchor.config["consumer_gid"]
    root = anchor.config["store_root"]
    opened: list[HeldFile] = []
    snapshots: dict[str, bytes] = {}
    observations = []
    snapshot_files: list[HeldFile] = []
    try:
        store = _open_held(root, True, _store_rule(uid, gid, 0o750, True), "E_STORE")
        opened.append(store)
        attempt = _open_child(store, attempt_id, True, _store_rule(uid, gid, 0o750, True), "E_STORE")
        opened.append(attempt)
        payload = _open_child(attempt, "payload", True, _store_rule(uid, gid, 0o750, True), "E_STORE")
        opened.append(payload)
        payload_path = root + "/" + attempt_id + "/payload"
        expected = {"stdout", "stderr", "evidence-manifest.json"}
        names = set(os.listdir(payload.fd))
        _require(expected <= names and names <= expected | {"refusal.json", "evidence"}, "E_STORE")
        receipt = _open_child(attempt, "receipt.json", False, _store_rule(uid, gid, 0o440, False), "E_STORE")
        opened.append(receipt)
        snapshot_files.append(receipt)
        for name in sorted(expected | ({"refusal.json"} if "refusal.json" in names else set())):
            item = _open_child(payload, name, False, _store_rule(uid, gid, 0o440, False), "E_STORE")
            opened.append(item)
            snapshot_files.append(item)
        manifest_item = next(item for item in opened if item.path.endswith("/evidence-manifest.json"))
        manifest_raw = manifest_item.read(DOCUMENT_LIMIT, "E_STORE")
        manifest = _json(manifest_raw, DOCUMENT_LIMIT, "E_STORE")
        manifest_body = manifest.get("body")
        files = manifest_body.get("files") if isinstance(manifest_body, dict) else None
        _require(set(manifest) == {"schema_version", "kind", "id", "body"}
                 and manifest["schema_version"] == 1 and manifest["kind"] == "sandbox_evidence_manifest"
                 and manifest["id"] == "evidence-manifest" and isinstance(manifest_body, dict)
                 and set(manifest_body) == {"files"}
                 and isinstance(files, list) and len(files) <= 10000, "E_STORE")
        wanted = [f"{i:04d}" for i in range(len(files))]
        _require(all(isinstance(row, dict) and set(row) == {"name_hex", "sha256", "size_bytes"}
                     and _sha(row["sha256"]) and isinstance(row["name_hex"], str)
                     and isinstance(row["size_bytes"], int) and not isinstance(row["size_bytes"], bool)
                     and 0 <= row["size_bytes"] <= 10485760 for row in files), "E_STORE")
        _require(files == sorted(files, key=lambda row: row["name_hex"])
                 and len({row["name_hex"] for row in files}) == len(files), "E_STORE")
        if wanted:
            _require("evidence" in names, "E_STORE")
            evidence_dir = _open_child(payload, "evidence", True,
                                       _store_rule(uid, gid, 0o750, True), "E_STORE")
            opened.append(evidence_dir)
            _require(sorted(os.listdir(evidence_dir.fd)) == wanted, "E_STORE")
            for name in wanted:
                item = _open_child(evidence_dir, name, False,
                                   _store_rule(uid, gid, 0o440, False), "E_STORE")
                opened.append(item)
                snapshot_files.append(item)
        else:
            _require("evidence" not in names, "E_STORE")
        for item in snapshot_files:
            relative = os.path.relpath(item.path, root + "/" + attempt_id)
            maximum = DOCUMENT_LIMIT if relative == "receipt.json" else 16 * 1024 * 1024
            raw = manifest_raw if item is manifest_item else item.read(maximum, "E_STORE")
            snapshots[relative] = raw
            observations.append(_entry(item, relative, raw))
        for index, row in enumerate(files):
            raw = snapshots["payload/evidence/%04d" % index]
            _require(len(raw) == row["size_bytes"] and digest(raw) == row["sha256"], "E_STORE")
        for item in opened:
            item.recheck("E_STORE")
        anchor.recheck()
        observation = {"schema_version": 1, "kind": "shadow_origin_observation",
                       "id": attempt_id, "body": {"store_id": anchor.config["store_id"],
                       "attempt_id": attempt_id, "entries": observations, "result": "authenticated"}}
        return snapshots, canonical(observation)
    finally:
        for item in reversed(opened):
            item.close()
