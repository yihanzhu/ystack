#!/usr/bin/env python3
"""Private trust primitives for the inactive shadow consumer."""
from __future__ import annotations
import ctypes
import dataclasses
import errno
import fcntl
import hashlib
import json
import os
import stat
import subprocess
import sys
from typing import Callable

ANCHOR = "/usr/local/libexec/ystack-sandbox/v1/supervisor"
HELPER_SOURCE = "adapters/local-git-materializer/v1/object-closure.c"
HELPER_SOURCE_SHA256 = "f1616b908c97e8a091029c24b3f2e1f8827171cbdee4d47195c66afd3e961e27"
PARENT_LIMIT, DOCUMENT_LIMIT = 16 * 1024, 1024 * 1024
EXECUTABLE_LIMIT, OUTPUT_LIMIT = 16 * 1024 * 1024, 10 * 1024 * 1024
JQ_SHA256 = {"darwin": "5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef",
             "linux": "af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44"}
HASH_KEYS = ("helper_source_sha256", "helper_build_record_sha256", "helper_executable_sha256")
CONFIG_KEYS = {"consumer_gid", "environment_id", "identity_paths", "installed_files",
               "principal_uid", "runtime", "store_id", "store_root", "work_root"}
IDENTITY_KEYS = {"guest_init", "guest_kernel", "guest_kernel_config", "guest_supervisor",
                 "host_runtime", "host_supervisor", "image", "toolchain", "verifier",
                 "vm_service", "dyld_cache_files"}
INSTALLED_SOURCES = {
    "accepted_set": "enforcement/v1/accepted-identities.json",
    "control_decision": "control/v1/sandbox-bound-decision.json",
    "control_policy": "control/v1/sandbox-bound-policy.json",
    "control_policy_set": "control/v1/control-policy-set-sandbox-bound.json",
    "evaluator_driver": "control/v1/evaluate-bound-sandbox.sh",
    "evaluator_program": "control/v1/sandbox-bound.jq",
    "registry": "shadow/v1/shadow-environments.json",
}
IDENTITY_SLOTS = {"host_runtime", "guest_kernel", "guest_kernel_config", "guest_init", "image",
                  "host_supervisor", "guest_supervisor", "verifier", "toolchain",
                  "verification_instructions"}
MECHANISMS = {"cpu_time_ms", "memory_bytes", "output_bytes", "process_count",
              "scratch_bytes", "wall_time_ms"}
DARWIN_UUID_INPUT_LIMIT = 16 * 1024
DARWIN_UUID_OUTPUT_LIMIT = 32 * 1024
DARWIN_UUID_COUNT_LIMIT = 128
DARWIN_SYSTEM_C = "/usr/lib/libSystem.B.dylib"

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

def _integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)

def _sha(value: object) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)

def _id(value: object) -> bool:
    first = "abcdefghijklmnopqrstuvwxyz0123456789"
    rest = first + "._:-"
    return (isinstance(value, str) and 1 <= len(value) <= 128 and value[0] in first
            and all(char in rest for char in value))

def _physical(path: object) -> bool:
    return isinstance(path, str) and path.startswith("/") and os.path.normpath(path) == path

def _unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result

def _json(raw: bytes, maximum: int, code: str) -> dict:
    _require(len(raw) <= maximum, code)
    try:
        value = json.loads(raw, object_pairs_hook=_unique_object)
        _require(isinstance(value, dict) and canonical(value) == raw, code)
    except (UnicodeDecodeError, UnicodeEncodeError, ValueError, TypeError, RecursionError):
        raise Refusal(code) from None
    return value

def _json_array(raw: bytes, maximum: int, code: str) -> list:
    _require(len(raw) <= maximum, code)
    try:
        value = json.loads(raw, object_pairs_hook=_unique_object)
        _require(isinstance(value, list) and canonical(value) == raw, code)
    except (UnicodeDecodeError, UnicodeEncodeError, ValueError, TypeError, RecursionError):
        raise Refusal(code) from None
    return value

def _uuid_hex(value: object) -> bool:
    return (isinstance(value, str) and len(value) == 32
            and all(char in "0123456789abcdef" for char in value))

class _DarwinACLFunctions:
    def __init__(self) -> None:
        library = ctypes.CDLL(DARWIN_SYSTEM_C, use_errno=True)
        library.acl_get_fd_np.restype = ctypes.c_void_p
        library.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        library.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                          ctypes.POINTER(ctypes.c_void_p)]
        library.acl_get_tag_type.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
        library.acl_get_qualifier.restype = ctypes.c_void_p
        library.acl_get_qualifier.argtypes = [ctypes.c_void_p]
        library.acl_get_permset.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
        library.acl_get_perm_np.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        library.acl_free.argtypes = [ctypes.c_void_p]
        self.library = library

_DARWIN_ACL_FUNCTIONS = _DarwinACLFunctions() if sys.platform == "darwin" else None

class _DarwinUUIDResolver:
    def resolve(self, uuids: list[str]) -> list[dict]:
        raise NotImplementedError

def _metadata(fd: int) -> os.stat_result:
    """Private OS observation seam used only by in-process fixtures."""
    return os.fstat(fd)

def _named_metadata(name: str, parent_fd: int) -> os.stat_result:
    """Private no-follow name observation seam used only by in-process fixtures."""
    return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)

def _identity(value: os.stat_result) -> tuple[int, ...]:
    return (value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode), value.st_uid, value.st_gid,
            stat.S_IMODE(value.st_mode), value.st_nlink, value.st_size,
            value.st_mtime_ns, value.st_ctime_ns)

Rule = Callable[[int, os.stat_result, bool], bool]

@dataclasses.dataclass
class HeldComponent:
    fd: int
    name: str | None
    before: os.stat_result
    rule: Rule
    ancestor: bool

@dataclasses.dataclass
class HeldPath:
    path: str
    components: list[HeldComponent]

    @property
    def fd(self) -> int:
        return self.components[-1].fd

    @property
    def before(self) -> os.stat_result:
        return self.components[-1].before

    def recheck(self, code: str) -> None:
        for index, component in enumerate(self.components):
            try:
                current = _metadata(component.fd)
                named = (current if component.name is None else
                         _named_metadata(component.name, self.components[index - 1].fd))
            except (OSError, ValueError):
                raise Refusal(code) from None
            expected = _identity(component.before)
            _require(_identity(current) == expected and _identity(named) == expected, code)
            _require(component.rule(component.fd, current, component.ancestor), code)
            try:
                after = _metadata(component.fd)
                after_named = (after if component.name is None else
                               _named_metadata(component.name, self.components[index - 1].fd))
            except (OSError, ValueError):
                raise Refusal(code) from None
            _require(_identity(after) == expected and _identity(after_named) == expected, code)

    def read(self, maximum: int, code: str) -> bytes:
        self.recheck(code)
        chunks, total = [], 0
        try:
            os.lseek(self.fd, 0, os.SEEK_SET)
            while True:
                chunk = os.read(self.fd, min(65536, maximum + 1 - total))
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                _require(total <= maximum, code)
        except (OSError, ValueError):
            raise Refusal(code) from None
        self.recheck(code)
        return b"".join(chunks)

    def read_exact(self, length: int, code: str) -> bytes:
        self.recheck(code)
        chunks, remaining = [], length
        try:
            os.lseek(self.fd, 0, os.SEEK_SET)
            while remaining:
                chunk = os.read(self.fd, min(65536, remaining))
                _require(bool(chunk), code)
                chunks.append(chunk)
                remaining -= len(chunk)
        except (OSError, ValueError):
            raise Refusal(code) from None
        self.recheck(code)
        return b"".join(chunks)

    def close(self) -> None:
        for component in reversed(self.components):
            try:
                os.close(component.fd)
            except OSError:
                pass
        self.components.clear()

def _clone(parent: HeldPath, code: str) -> list[HeldComponent]:
    rows = []
    try:
        parent.recheck(code)
        for row in parent.components:
            rows.append(HeldComponent(os.dup(row.fd), row.name, row.before, row.rule, row.ancestor))
        return rows
    except (OSError, Refusal):
        for row in reversed(rows):
            os.close(row.fd)
        raise Refusal(code) from None

def _open_held(path: str, directory: bool, rule: Rule, code: str) -> HeldPath:
    _require(_physical(path) and path != "/", code)
    parts = path.split("/")[1:]
    _require(all(part not in ("", ".", "..") for part in parts), code)
    rows: list[HeldComponent] = []
    try:
        fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        state = _metadata(fd)
        rows.append(HeldComponent(fd, None, state, rule, True))
        _require(rule(fd, state, True), code)
        for index, name in enumerate(parts):
            last = index == len(parts) - 1
            flags = os.O_RDONLY | os.O_NOFOLLOW
            if not last or directory:
                flags |= os.O_DIRECTORY
            elif hasattr(os, "O_NONBLOCK"):
                flags |= os.O_NONBLOCK
            fd = os.open(name, flags, dir_fd=rows[-1].fd)
            state = _metadata(fd)
            rows.append(HeldComponent(fd, name, state, rule, not last))
            _require(rule(fd, state, not last), code)
        state = rows[-1].before
        _require((directory and stat.S_ISDIR(state.st_mode)) or
                 (not directory and stat.S_ISREG(state.st_mode) and state.st_nlink == 1), code)
        result = HeldPath(path, rows)
        result.recheck(code)
        return result
    except (OSError, ValueError, Refusal):
        for row in reversed(rows):
            os.close(row.fd)
        raise Refusal(code) from None

def _open_child(parent: HeldPath, name: str, directory: bool, rule: Rule, code: str) -> HeldPath:
    _require(isinstance(name, str) and name and "/" not in name and name not in (".", ".."), code)
    rows = _clone(parent, code)
    try:
        flags = os.O_RDONLY | os.O_NOFOLLOW | (os.O_DIRECTORY if directory else 0)
        if not directory and hasattr(os, "O_NONBLOCK"):
            flags |= os.O_NONBLOCK
        fd = os.open(name, flags, dir_fd=rows[-1].fd)
        state = _metadata(fd)
        rows.append(HeldComponent(fd, name, state, rule, False))
        _require(rule(fd, state, False), code)
        _require((directory and stat.S_ISDIR(state.st_mode)) or
                 (not directory and stat.S_ISREG(state.st_mode) and state.st_nlink == 1), code)
        result = HeldPath(parent.path + "/" + name, rows)
        result.recheck(code)
        return result
    except (OSError, ValueError, Refusal):
        for row in reversed(rows):
            os.close(row.fd)
        raise Refusal(code) from None

def _linux_acl_xattr(fd: int, name: str) -> list[tuple[int, int, int]] | None:
    try:
        raw = os.getxattr(fd, name)
    except OSError as exc:
        if exc.errno in (errno.ENODATA, getattr(errno, "ENOATTR", errno.ENODATA)):
            return None
        raise
    _require(len(raw) >= 4 and raw[:4] == b"\x02\x00\x00\x00" and (len(raw) - 4) % 8 == 0,
             "E_ACL")
    return [(int.from_bytes(raw[i:i + 2], "little"), int.from_bytes(raw[i + 2:i + 4], "little"),
             int.from_bytes(raw[i + 4:i + 8], "little")) for i in range(4, len(raw), 8)]

def _darwin_acl(fd: int, resolver: _DarwinUUIDResolver | None) -> list[tuple[int, int | None, int]]:
    _require(isinstance(resolver, _DarwinUUIDResolver), "E_ACL")
    _require(_DARWIN_ACL_FUNCTIONS is not None, "E_ACL")
    lib = _DARWIN_ACL_FUNCTIONS.library
    ctypes.set_errno(0)
    acl = lib.acl_get_fd_np(fd, 0x100)
    if not acl:
        if ctypes.get_errno() == errno.ENOENT:
            return []
        raise OSError(ctypes.get_errno(), "acl_get_fd_np")
    captured: list[tuple[int, str, int]] = []
    entry, selector = ctypes.c_void_p(), 0
    try:
        while True:
            ctypes.set_errno(0)
            rc = lib.acl_get_entry(acl, selector, ctypes.byref(entry))
            if rc != 0:
                if ctypes.get_errno() != 0:
                    raise OSError(ctypes.get_errno(), "acl_get_entry")
                break
            selector = -1
            tag, perms = ctypes.c_int(), ctypes.c_void_p()
            if lib.acl_get_tag_type(entry, ctypes.byref(tag)) != 0:
                raise OSError(ctypes.get_errno(), "acl_get_tag_type")
            if lib.acl_get_permset(entry, ctypes.byref(perms)) != 0:
                raise OSError(ctypes.get_errno(), "acl_get_permset")
            bits = 0
            for shift in range(1, 14):
                ctypes.set_errno(0)
                present = lib.acl_get_perm_np(perms, 1 << shift)
                if present not in (0, 1):
                    raise OSError(ctypes.get_errno() or errno.EIO, "acl_get_perm_np")
                if present:
                    bits |= 1 << shift
            ctypes.set_errno(0)
            qualifier = lib.acl_get_qualifier(entry)
            if not qualifier:
                raise OSError(ctypes.get_errno() or errno.EIO, "acl_get_qualifier")
            uuid = ctypes.string_at(qualifier, 16)
            if lib.acl_free(qualifier) != 0:
                raise OSError(ctypes.get_errno() or errno.EIO, "acl_free")
            captured.append((tag.value, uuid.hex(), bits))
            _require(len(captured) <= DARWIN_UUID_COUNT_LIMIT, "E_ACL")
    finally:
        if lib.acl_free(acl) != 0:
            raise OSError(ctypes.get_errno() or errno.EIO, "acl_free")
    resolved = resolver.resolve([uuid for _tag, uuid, _bits in captured])
    _require(isinstance(resolved, list) and len(resolved) == len(captured), "E_ACL")
    rows = []
    for (tag, uuid, bits), result in zip(captured, resolved):
        _require(isinstance(result, dict) and set(result) == {"uuid", "status", "kind", "id"}
                 and result["uuid"] == uuid, "E_ACL")
        if result["status"] == "resolved":
            _require(result["kind"] in ("user", "group") and _integer(result["id"])
                     and 0 <= result["id"] <= 0xffffffff, "E_ACL")
            identifier = result["id"] if result["kind"] == "user" else None
        else:
            _require(result["status"] == "unresolved" and result["kind"] is None
                     and result["id"] is None, "E_ACL")
            identifier = None
        rows.append((tag, identifier, bits))
    return rows

def _acl_state(fd: int, resolver: _DarwinUUIDResolver | None = None) -> tuple[object, object | None]:
    """Private OS observation seam returning access and default ACLs."""
    if sys.platform == "darwin":
        return _darwin_acl(fd, resolver), None
    return (_linux_acl_xattr(fd, "system.posix_acl_access"),
            _linux_acl_xattr(fd, "system.posix_acl_default"))

def _linux_install_acl_ok(entries: list[tuple[int, int, int]] | None) -> bool:
    return entries is None or not any(tag in (0x02, 0x08) or (tag == 0x10 and perms & 2)
                                      for tag, perms, _identifier in entries)

def _root_rule(resolver: _DarwinUUIDResolver | None = None) -> Rule:
    def check(fd: int, state: os.stat_result, _ancestor: bool) -> bool:
        if state.st_uid != 0 or state.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            return False
        try:
            access, default = _acl_state(fd, resolver)
        except (OSError, Refusal):
            return False
        if sys.platform != "darwin":
            return _linux_install_acl_ok(access) and _linux_install_acl_ok(default)
        dangerous = sum(1 << n for n in (2, 4, 5, 6, 8, 10, 12, 13))
        return not any(tag == 1 and identifier != 0 and bits & dangerous
                       for tag, identifier, bits in access)
    return check

def _installed_rule(principal_uid: int, resolver: _DarwinUUIDResolver | None = None) -> Rule:
    def check(fd: int, state: os.stat_result, _ancestor: bool) -> bool:
        if state.st_uid not in (0, principal_uid) or state.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            return False
        try:
            access, default = _acl_state(fd, resolver)
        except (OSError, Refusal):
            return False
        if sys.platform != "darwin":
            return _linux_install_acl_ok(access) and _linux_install_acl_ok(default)
        dangerous = sum(1 << n for n in (2, 4, 5, 6, 8, 10, 12, 13))
        return not any(tag == 1 and bits & dangerous and identifier not in (0, principal_uid)
                       for tag, identifier, bits in access)
    return check

def _store_rule(uid: int, gid: int, mode: int, directory: bool,
                resolver: _DarwinUUIDResolver | None = None) -> Rule:
    def check(fd: int, state: os.stat_result, ancestor: bool) -> bool:
        if ancestor:
            return True
        try:
            access, default = _acl_state(fd, resolver)
        except (OSError, Refusal):
            return False
        kind = stat.S_ISDIR(state.st_mode) if directory else stat.S_ISREG(state.st_mode)
        acl_absent = access == [] if sys.platform == "darwin" else access is None and default is None
        return (kind and state.st_uid == uid and state.st_gid == gid and stat.S_IMODE(state.st_mode) == mode
                and acl_absent)
    return check

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

def capture_parent_context(fd: int = 3) -> dict:
    try:
        flags, before = fcntl.fcntl(fd, fcntl.F_GETFL), _metadata(fd)
        _require(flags & os.O_ACCMODE == os.O_RDONLY and stat.S_ISREG(before.st_mode), "E_PARENT_CONTEXT")
        raw = _read_plain_fd(fd, PARENT_LIMIT)
        after = _metadata(fd)
    except (OSError, ValueError, Refusal):
        raise Refusal("E_PARENT_CONTEXT") from None
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
    _require(_identity(before) == _identity(after), "E_PARENT_CONTEXT")
    doc = _json(raw, PARENT_LIMIT, "E_PARENT_CONTEXT")
    _require(set(doc) == {"schema_version", "kind", "id", "body"} and _integer(doc["schema_version"])
             and doc["schema_version"] == 1 and doc["kind"] == "shadow_consumer_parent_context"
             and doc["id"] == "shadow.parent", "E_PARENT_CONTEXT")
    body = doc["body"]
    _require(isinstance(body, dict) and set(body) == set(HASH_KEYS) | {"helper_executable_size", "helper_path"}
             and all(_sha(body[key]) for key in HASH_KEYS), "E_PARENT_CONTEXT")
    _require(_integer(body["helper_executable_size"]) and 0 < body["helper_executable_size"] <= EXECUTABLE_LIMIT
             and _physical(body["helper_path"]) and body["helper_source_sha256"] == HELPER_SOURCE_SHA256,
             "E_PARENT_CONTEXT")
    return body

@dataclasses.dataclass
class DependencySnapshot:
    original: HeldPath
    snapshot: HeldPath
    sha256: str
    size: int
    def recheck(self) -> None:
        self.original.recheck("E_DEPENDENCY")
        raw = self.snapshot.read(self.size, "E_DEPENDENCY")
        _require(len(raw) == self.size and digest(raw) == self.sha256, "E_DEPENDENCY")
    def close(self) -> None:
        self.original.close()
        self.snapshot.close()

def snapshot_dependency(path: str, expected_sha256: str, expected_size: int,
                        private_dir: str, name: str) -> DependencySnapshot:
    _require(_sha(expected_sha256) and _integer(expected_size) and 0 < expected_size <= EXECUTABLE_LIMIT,
             "E_DEPENDENCY")
    _require(_physical(private_dir) and name not in ("", ".", "..") and "/" not in name
             and not path.startswith(private_dir + "/"), "E_DEPENDENCY")
    original = parent = directory = None
    try:
        parent_path, directory_name = os.path.split(private_dir)
        parent = _open_held(parent_path, True, lambda _fd, _state, _ancestor: True, "E_DEPENDENCY")
        os.mkdir(directory_name, 0o700, dir_fd=parent.fd)
        parent.components[-1].before = _metadata(parent.fd)
        directory = _open_child(parent, directory_name, True,
                                lambda _fd, state, ancestor: ancestor or stat.S_IMODE(state.st_mode) == 0o700,
                                "E_DEPENDENCY")
        original = _open_held(path, False, lambda _fd, _state, _ancestor: True, "E_DEPENDENCY")
        raw = original.read(expected_size, "E_DEPENDENCY")
        _require(len(raw) == expected_size and digest(raw) == expected_sha256, "E_DEPENDENCY")
        try:
            out = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                          0o500, dir_fd=directory.fd)
            try:
                written = 0
                while written < len(raw):
                    count = os.write(out, raw[written:])
                    _require(count > 0, "E_DEPENDENCY")
                    written += count
                os.fsync(out)
            finally:
                os.close(out)
            os.fchmod(directory.fd, 0o500)
            os.fsync(directory.fd)
        finally:
            directory.close()
            directory = None
        snapshot = _open_held(os.path.join(private_dir, name), False,
                              lambda _fd, state, ancestor: ancestor or stat.S_IMODE(state.st_mode) == 0o500,
                              "E_DEPENDENCY")
        parent.close()
        return DependencySnapshot(original, snapshot, expected_sha256, expected_size)
    except (OSError, ValueError, Refusal):
        if directory:
            directory.close()
        if original:
            original.close()
        if parent:
            parent.close()
        raise Refusal("E_DEPENDENCY") from None

def probe_dependency(snapshot: DependencySnapshot, arguments: list[str], expected_stdout: bytes) -> None:
    snapshot.recheck()
    try:
        result = subprocess.run([snapshot.snapshot.path, *arguments], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
                                env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"},
                                close_fds=True, check=False)
    except (OSError, subprocess.SubprocessError):
        raise Refusal("E_DEPENDENCY") from None
    _require(result.returncode == 0 and result.stdout == expected_stdout and result.stderr == b"",
             "E_DEPENDENCY")
    snapshot.recheck()

def snapshot_jq(path: str, private_dir: str) -> DependencySnapshot:
    expected = JQ_SHA256.get(sys.platform)
    _require(expected is not None, "E_DEPENDENCY")
    held = _open_held(path, False, lambda _fd, _state, _ancestor: True, "E_DEPENDENCY")
    try:
        size = held.before.st_size
    finally:
        held.close()
    return snapshot_dependency(path, expected, size, private_dir, "jq")

def _source_root() -> str:
    module = os.path.abspath(__file__)
    root = os.path.dirname(os.path.dirname(os.path.dirname(module)))
    _require(os.path.realpath(module) == module and os.path.realpath(root) == root, "E_INSTALL")
    return root

def isolated_python_argv() -> list[str]:
    executable = sys.executable
    module = os.path.join(_source_root(), "shadow/v1/_consumer.py")
    _require(_physical(executable) and os.path.realpath(executable) == executable, "E_DEPENDENCY")
    held = _open_held(module, False, lambda _fd, _state, _ancestor: True, "E_DEPENDENCY")
    held.close()
    return [executable, "-I", "-S", "-B", module]

def verify_helper_source() -> None:
    source = _open_held(os.path.join(_source_root(), HELPER_SOURCE), False,
                        lambda _fd, _state, _ancestor: True, "E_DEPENDENCY")
    try:
        _require(digest(source.read(DOCUMENT_LIMIT, "E_DEPENDENCY")) == HELPER_SOURCE_SHA256,
                 "E_DEPENDENCY")
    finally:
        source.close()

def _parse_config(raw: bytes) -> dict:
    doc = _json(raw, DOCUMENT_LIMIT, "E_CONFIG")
    _require(set(doc) == {"schema_version", "kind", "id", "body"}
             and _integer(doc["schema_version"]) and doc["schema_version"] == 1
             and doc["kind"] == "sandbox_host_config", "E_CONFIG")
    body = doc["body"]
    _require(isinstance(body, dict) and set(body) == CONFIG_KEYS
             and _integer(body["principal_uid"]) and body["principal_uid"] >= 0
             and _integer(body["consumer_gid"]) and body["consumer_gid"] >= 0
             and isinstance(body["store_id"], str) and body["store_id"]
             and isinstance(body["environment_id"], str) and body["environment_id"], "E_CONFIG")
    _require(isinstance(body["runtime"], dict) and set(body["runtime"]) == {"driver", "vfkit"}
             and all(_physical(body["runtime"][key]) for key in body["runtime"]), "E_CONFIG")
    for key in ("store_root", "work_root"):
        value = body[key]
        _require(_physical(value) and value != "/sandbox" and not value.startswith("/sandbox/"),
                 "E_CONFIG")
    paths = body["identity_paths"]
    installed = body["installed_files"]
    _require(isinstance(paths, dict) and set(paths) == IDENTITY_KEYS
             and isinstance(installed, dict) and set(installed) == set(INSTALLED_SOURCES), "E_CONFIG")
    for key, value in paths.items():
        if key == "dyld_cache_files":
            _require(isinstance(value, list) and value and all(_physical(path) for path in value),
                     "E_CONFIG")
        else:
            _require(_physical(value), "E_CONFIG")
    _require(all(_physical(path) for path in installed.values()), "E_CONFIG")
    all_paths = list(installed.values()) + [value for key, value in paths.items()
                                            if key != "dyld_cache_files"] + paths["dyld_cache_files"]
    _require(len(all_paths) == len(set(all_paths)), "E_CONFIG")
    return body

def _digest_list(value: object) -> bool:
    return (isinstance(value, list) and 1 <= len(value) <= 8 and value == sorted(set(value))
            and all(_sha(item) and item not in ("0" * 64, "1" * 64) for item in value))

def _id_list(value: object) -> bool:
    return (isinstance(value, list) and 1 <= len(value) <= 8 and value == sorted(set(value))
            and all(_id(item) for item in value))

def _parse_registry(raw: bytes) -> tuple[str, list[dict]]:
    doc = _json(raw, DOCUMENT_LIMIT, "E_INSTALL")
    body = doc.get("body")
    _require(set(doc) == {"schema_version", "kind", "id", "body"}
             and _integer(doc["schema_version"]) and doc["schema_version"] == 1
             and doc["kind"] == "shadow_environment_registry"
             and doc["id"] == "shadow.environments.v1" and isinstance(body, dict)
             and set(body) == {"activation_state", "environments", "registry_version"}
             and body["activation_state"] == "inactive" and body["registry_version"] == "v1"
             and isinstance(body["environments"], list), "E_INSTALL")
    keys = {"description", "environment_id", "evidence_scope", "proof_state",
            "source_root_commit", "target_repository_id"}
    for row in body["environments"]:
        _require(isinstance(row, dict) and set(row) == keys and _id(row["environment_id"])
                 and _id(row["target_repository_id"])
                 and all(isinstance(row[key], str) for key in
                         ("description", "evidence_scope", "proof_state"))
                 and isinstance(row["source_root_commit"], str)
                 and len(row["source_root_commit"]) == 40
                 and all(c in "0123456789abcdef" for c in row["source_root_commit"]), "E_INSTALL")
    return digest(raw), body["environments"]

def _parse_accepted(raw: bytes) -> tuple[str, list[dict]]:
    doc = _json(raw, DOCUMENT_LIMIT, "E_INSTALL")
    body = doc.get("body")
    _require(set(doc) == {"schema_version", "kind", "id", "body"}
             and _integer(doc["schema_version"]) and doc["schema_version"] == 1
             and doc["kind"] == "sandbox_accepted_identity_set"
             and doc["id"] == "sandbox.accepted-identities.v1" and isinstance(body, dict)
             and set(body) == {"activation_state", "environments", "set_version"}
             and body["activation_state"] == "inactive" and body["set_version"] == "v1"
             and isinstance(body["environments"], list), "E_INSTALL")
    keys = {"environment_id", "identities", "mechanisms", "scratch_bytes"}
    for row in body["environments"]:
        _require(isinstance(row, dict) and set(row) == keys and _id(row["environment_id"])
                 and _integer(row["scratch_bytes"]) and row["scratch_bytes"] > 0
                 and isinstance(row["identities"], dict)
                 and set(row["identities"]) == IDENTITY_SLOTS
                 and all(_digest_list(value) for value in row["identities"].values())
                 and isinstance(row["mechanisms"], dict) and set(row["mechanisms"]) == MECHANISMS
                 and all(_id_list(value) for value in row["mechanisms"].values()), "E_INSTALL")
    return digest(raw), body["environments"]

@dataclasses.dataclass
class Anchor:
    config: dict
    config_raw: bytes
    held: list[HeldPath]
    installed: dict[str, tuple[bytes, str]]
    registry: tuple[str, list[dict]]
    accepted: tuple[str, list[dict]]
    resolver: _DarwinUUIDResolver | None
    def recheck(self, code: str = "E_INSTALL") -> None:
        for item in self.held:
            item.recheck(code)
    def close(self) -> None:
        for item in reversed(self.held):
            item.close()

def load_anchor(resolver: _DarwinUUIDResolver | None = None) -> Anchor:
    held: list[HeldPath] = []
    try:
        if sys.platform == "darwin":
            _require(isinstance(resolver, _DarwinUUIDResolver), "E_INSTALL")
        root_rule = _root_rule(resolver)
        anchor = _open_held(ANCHOR, True, root_rule, "E_INSTALL")
        held.append(anchor)
        config_file = _open_child(anchor, "host-config.json", False, root_rule, "E_CONFIG")
        held.append(config_file)
        script = _open_child(anchor, "host-supervisor.py", False, root_rule, "E_INSTALL")
        held.append(script)
        config_raw = config_file.read(DOCUMENT_LIMIT, "E_CONFIG")
        config = _parse_config(config_raw)
        uid, gid = config["principal_uid"], config["consumer_gid"]
        _require(uid > 0 and uid not in (os.getuid(), os.geteuid())
                 and gid in set(os.getgroups()) | {os.getgid(), os.getegid()}, "E_CONFIG")
        installed: dict[str, tuple[bytes, str]] = {}
        source_root = _source_root()
        for role, source_name in INSTALLED_SOURCES.items():
            source = _open_held(os.path.join(source_root, source_name), False,
                                lambda _fd, _state, _ancestor: True, "E_INSTALL")
            held.append(source)
            target = _open_held(config["installed_files"][role], False,
                                _installed_rule(uid, resolver), "E_INSTALL")
            held.append(target)
            source_raw = source.read(EXECUTABLE_LIMIT, "E_INSTALL")
            target_raw = target.read(EXECUTABLE_LIMIT, "E_INSTALL")
            _require(source_raw == target_raw, "E_INSTALL")
            installed[role] = (target_raw, digest(target_raw))
        for path in (config["identity_paths"]["verifier"], sys.executable):
            held.append(_open_held(path, False, _installed_rule(uid, resolver), "E_INSTALL"))
        registry = _parse_registry(installed["registry"][0])
        accepted = _parse_accepted(installed["accepted_set"][0])
        result = Anchor(config, config_raw, held, installed, registry, accepted, resolver)
        result.recheck()
        return result
    except BaseException:
        for item in reversed(held):
            item.close()
        raise

def verifier_observation(anchor: Anchor, environment_id: str, target_repository_id: str) -> bytes:
    anchor.recheck("E_RELATION")
    _require(anchor.config["environment_id"] == environment_id, "E_RELATION")
    registry = [row for row in anchor.registry[1] if row["environment_id"] == environment_id]
    accepted = [row for row in anchor.accepted[1] if row["environment_id"] == environment_id]
    _require(len(registry) == 1 and len(accepted) == 1
             and registry[0]["target_repository_id"] == target_repository_id, "E_RELATION")
    verifier = next(item for item in anchor.held
                    if item.path == anchor.config["identity_paths"]["verifier"])
    verifier_raw = verifier.read(EXECUTABLE_LIMIT, "E_RELATION")
    verifier_sha = digest(verifier_raw)
    _require(verifier_sha in accepted[0]["identities"]["verifier"], "E_RELATION")
    anchor.recheck("E_RELATION")
    return canonical({"schema_version": 1, "kind": "sandbox_verifier_observation",
                      "id": "sandbox.observation.verifier", "body": {
                          "environment_id": environment_id,
                          "environment_entry_sha256": digest(canonical(registry[0])),
                          "accepted_set_sha256": anchor.accepted[0],
                          "target_repository_id": target_repository_id,
                          "verifier_sha256": verifier_sha}})

def _observation(item: HeldPath, relative: str, raw: bytes | None = None) -> dict:
    state = item.before
    row = {"name": relative, "device": state.st_dev, "inode": state.st_ino,
           "mode": stat.S_IMODE(state.st_mode), "uid": state.st_uid, "gid": state.st_gid,
           "kind": "directory" if stat.S_ISDIR(state.st_mode) else "file",
           "metadata_before": list(_identity(state)),
           "metadata_after": list(_identity(_metadata(item.fd)))}
    if raw is not None:
        row.update({"size": len(raw), "sha256": digest(raw)})
    return row

def _hex_name(value: object) -> bool:
    return (isinstance(value, str) and bool(value) and len(value) % 2 == 0
            and len(value) <= 510 and all(char in "0123456789abcdef" for char in value))

def read_store_attempt(anchor: Anchor, attempt_id: str) -> tuple[dict[str, bytes], bytes]:
    _require(_id(attempt_id), "E_STORE")
    anchor.recheck("E_STORE")
    uid, gid = anchor.config["principal_uid"], anchor.config["consumer_gid"]
    root = anchor.config["store_root"]
    opened: list[HeldPath] = []
    snapshots: dict[str, bytes] = {}
    observations: list[dict] = []
    try:
        store = _open_held(root, True, _store_rule(uid, gid, 0o750, True, anchor.resolver), "E_STORE")
        opened.append(store)
        attempt = _open_child(store, attempt_id, True,
                              _store_rule(uid, gid, 0o750, True, anchor.resolver), "E_STORE")
        opened.append(attempt)
        payload = _open_child(attempt, "payload", True,
                              _store_rule(uid, gid, 0o750, True, anchor.resolver), "E_STORE")
        opened.append(payload)
        observations.extend((_observation(store, "."), _observation(attempt, attempt_id),
                             _observation(payload, "payload")))
        attempt_names = set(os.listdir(attempt.fd))
        _require(attempt_names == {"payload", "receipt.json"}, "E_STORE")
        payload_names = set(os.listdir(payload.fd))
        fixed = {"stdout", "stderr", "evidence-manifest.json"}
        optional = ({"refusal.json"} if "refusal.json" in payload_names else set())
        evidence_present = "evidence" in payload_names
        _require(payload_names == fixed | optional | ({"evidence"} if evidence_present else set()),
                 "E_STORE")
        files: list[tuple[HeldPath, str]] = []
        receipt = _open_child(attempt, "receipt.json", False,
                              _store_rule(uid, gid, 0o440, False, anchor.resolver), "E_STORE")
        opened.append(receipt); files.append((receipt, "receipt.json"))
        for name in sorted(fixed | optional):
            item = _open_child(payload, name, False,
                               _store_rule(uid, gid, 0o440, False, anchor.resolver), "E_STORE")
            opened.append(item); files.append((item, "payload/" + name))
        manifest_item = next(item for item, name in files if name == "payload/evidence-manifest.json")
        manifest_raw = manifest_item.read(DOCUMENT_LIMIT, "E_STORE")
        manifest = _json(manifest_raw, DOCUMENT_LIMIT, "E_STORE")
        body = manifest.get("body")
        rows = body.get("files") if isinstance(body, dict) else None
        _require(set(manifest) == {"schema_version", "kind", "id", "body"}
                 and _integer(manifest["schema_version"]) and manifest["schema_version"] == 1
                 and manifest["kind"] == "sandbox_evidence_manifest"
                 and manifest["id"] == "evidence-manifest" and isinstance(body, dict)
                 and set(body) == {"files"} and isinstance(rows, list) and len(rows) <= 10000,
                 "E_STORE")
        _require(all(isinstance(row, dict) and set(row) == {"name_hex", "sha256", "size_bytes"}
                     and _hex_name(row["name_hex"]) and _sha(row["sha256"])
                     and _integer(row["size_bytes"]) and 0 <= row["size_bytes"] <= OUTPUT_LIMIT
                     for row in rows), "E_STORE")
        _require(rows == sorted(rows, key=lambda row: row["name_hex"])
                 and len({row["name_hex"] for row in rows}) == len(rows), "E_STORE")
        expected_evidence = [f"{index:04d}" for index in range(len(rows))]
        _require(evidence_present == bool(rows), "E_STORE")
        if rows:
            evidence = _open_child(payload, "evidence", True,
                                   _store_rule(uid, gid, 0o750, True, anchor.resolver), "E_STORE")
            opened.append(evidence); observations.append(_observation(evidence, "payload/evidence"))
            _require(sorted(os.listdir(evidence.fd)) == expected_evidence, "E_STORE")
            for name in expected_evidence:
                item = _open_child(evidence, name, False,
                                   _store_rule(uid, gid, 0o440, False, anchor.resolver), "E_STORE")
                opened.append(item); files.append((item, "payload/evidence/" + name))
        output_files = [(item, name) for item, name in files
                        if name in ("payload/stdout", "payload/stderr")
                        or name.startswith("payload/evidence/")]
        _require(sum(item.before.st_size for item, _name in output_files) <= OUTPUT_LIMIT, "E_STORE")
        remaining = OUTPUT_LIMIT
        for item, name in files:
            output_name = (name in ("payload/stdout", "payload/stderr")
                           or name.startswith("payload/evidence/"))
            maximum = (remaining if output_name else
                       DOCUMENT_LIMIT if name in ("receipt.json", "payload/evidence-manifest.json")
                       else OUTPUT_LIMIT)
            _require(item.before.st_size <= maximum, "E_STORE")
            raw = manifest_raw if item is manifest_item else item.read_exact(item.before.st_size, "E_STORE")
            _require(len(raw) == item.before.st_size, "E_STORE")
            snapshots[name] = raw
            observations.append(_observation(item, name, raw))
            if output_name:
                remaining -= len(raw)
        for index, row in enumerate(rows):
            raw = snapshots[f"payload/evidence/{index:04d}"]
            _require(len(raw) == row["size_bytes"] and digest(raw) == row["sha256"], "E_STORE")
        _require(set(os.listdir(attempt.fd)) == attempt_names
                 and set(os.listdir(payload.fd)) == payload_names, "E_STORE")
        if rows:
            _require(sorted(os.listdir(evidence.fd)) == expected_evidence, "E_STORE")
        for item in opened:
            item.recheck("E_STORE")
        anchor.recheck("E_STORE")
        observation = canonical({"schema_version": 1, "kind": "shadow_origin_observation",
                                 "id": attempt_id, "body": {"store_id": anchor.config["store_id"],
                                     "attempt_id": attempt_id, "entries": observations,
                                     "result": "authenticated"}})
        return snapshots, observation
    finally:
        for item in reversed(opened):
            item.close()

def _read_resolver_input() -> bytes:
    raw = bytearray()
    while len(raw) <= DARWIN_UUID_INPUT_LIMIT:
        part = os.read(0, min(4096, DARWIN_UUID_INPUT_LIMIT + 1 - len(raw)))
        if not part:
            break
        raw.extend(part)
    _require(len(raw) <= DARWIN_UUID_INPUT_LIMIT, "E_ACL")
    return bytes(raw)

def _resolve_darwin_uuids() -> bytes:
    _require(sys.platform == "darwin" and _DARWIN_ACL_FUNCTIONS is not None, "E_ACL")
    uuids = _json_array(_read_resolver_input(), DARWIN_UUID_INPUT_LIMIT, "E_ACL")
    _require(len(uuids) <= DARWIN_UUID_COUNT_LIMIT and all(_uuid_hex(item) for item in uuids),
             "E_ACL")
    function = _DARWIN_ACL_FUNCTIONS.library.mbr_uuid_to_id
    function.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint32),
                         ctypes.POINTER(ctypes.c_int)]
    function.restype = ctypes.c_int
    rows = []
    for uuid in uuids:
        value, kind = ctypes.c_uint32(), ctypes.c_int()
        ctypes.set_errno(0)
        result = function(bytes.fromhex(uuid), ctypes.byref(value), ctypes.byref(kind))
        if result == 0:
            _require(kind.value in (0, 1), "E_ACL")
            rows.append({"uuid": uuid, "status": "resolved",
                         "kind": "user" if kind.value == 0 else "group", "id": value.value})
        else:
            error = ctypes.get_errno() or result
            _require(error in (errno.ENOENT, errno.ESRCH, errno.EIO), "E_ACL")
            rows.append({"uuid": uuid, "status": "unresolved", "kind": None, "id": None})
    output = canonical(rows)
    _require(len(output) <= DARWIN_UUID_OUTPUT_LIMIT, "E_ACL")
    return output

def _resolver_main(argv: list[str]) -> int:
    try:
        _require(argv == [argv[0], "_resolve-darwin-uuids"] and sys.flags.isolated == 1
                 and sys.flags.no_site == 1 and sys.flags.dont_write_bytecode == 1, "E_ACL")
        output = _resolve_darwin_uuids()
        sent = 0
        while sent < len(output):
            count = os.write(1, output[sent:])
            _require(count > 0, "E_ACL")
            sent += count
        return 0
    except (Refusal, OSError, ValueError):
        return 1

if __name__ == "__main__":
    raise SystemExit(_resolver_main(sys.argv))
