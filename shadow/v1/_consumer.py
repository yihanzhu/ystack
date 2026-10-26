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
import struct
import subprocess
import sys
import selectors
import signal
import time
from typing import Callable

ANCHOR = "/usr/local/libexec/ystack-sandbox/v1/supervisor"
HELPER_SOURCE = "adapters/local-git-materializer/v1/object-closure.c"
HELPER_SOURCE_SHA256 = "f1616b908c97e8a091029c24b3f2e1f8827171cbdee4d47195c66afd3e961e27"
PARENT_LIMIT, DOCUMENT_LIMIT = 16 * 1024, 1024 * 1024
PARENT_FRAME_MAGIC = b"YSRAW16\0"
PARENT_FRAME_LIMIT = 20 + PARENT_LIMIT + 2 * DOCUMENT_LIMIT
CAPTURE_LIMIT = DOCUMENT_LIMIT
EXPORT_LIMIT = 12 * DOCUMENT_LIMIT
EXECUTABLE_LIMIT, OUTPUT_LIMIT = 16 * 1024 * 1024, 10 * 1024 * 1024
JQ_SHA256 = {"darwin": "5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef",
             "linux": "af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44"}
HASH_KEYS = ("helper_source_sha256", "helper_build_record_sha256", "helper_executable_sha256")
NATIVE_RELEASE_KEYS = {"source_sha256", "build_script_sha256", "build_record_sha256",
                       "binary_path", "binary_size", "binary_sha256", "python_path",
                       "python_sha256", "python_abi", "dependency_record_sha256",
                       "loader_mode"}
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
_clock_observations = {}
_clock_complete = True


def _clock_value(site, value, kind):
    global _clock_complete
    owner = site.rsplit(":", 2)[0]
    rows = _clock_observations.setdefault(owner, {"wall": [], "monotonic": []})
    if len(rows["wall"]) + len(rows["monotonic"]) >= 4096:
        _clock_complete = False
    else:
        rows[kind].append({"site": site, "value": struct.pack(">d", value).hex()})
    return value

class Refusal(Exception):
    def __init__(self, code: str, *, os_errno: int | None = None):
        super().__init__(code)
        self.code = code
        self.os_errno = os_errno

def _require(value: bool, code: str) -> None:
    if not value:
        raise Refusal(code)

def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                      allow_nan=False).encode("utf-8") + b"\n"

def digest(data: bytes) -> str:
    if isinstance(data, (_ExportSnapshot, _RuntimeSnapshot)):
        return data.sha256()
    return hashlib.sha256(data).hexdigest()


_export_work = {}


def _export_read_charge(site, amount, *, call=False):
    _require(type(amount) is int and amount >= 0, "E_LIMIT")
    row = _export_work.setdefault(site, {"calls": 0, "read_bytes": 0})
    total = sum(value["read_bytes"] for value in _export_work.values())
    _require(total + amount <= 1536 * DOCUMENT_LIMIT, "E_LIMIT")
    row["calls"] += int(call)
    row["read_bytes"] += amount


@dataclasses.dataclass(frozen=True, eq=False)
class _ExportSnapshot:
    chunks: tuple[bytes, ...]
    owner: object
    acquisition_sha: str
    size: int = dataclasses.field(init=False)

    def __post_init__(self):
        object.__setattr__(self, "chunks", tuple(self.chunks))
        object.__setattr__(self, "size", sum(map(len, self.chunks)))
        _require(self.size <= EXPORT_LIMIT and all(type(chunk) is bytes and len(chunk) <= 65536
                                                  for chunk in self.chunks), "E_STORE")

    def __len__(self):
        return self.size

    def sha256(self):
        _export_read_charge("consumer.independent-sha", 0, call=True)
        measured = hashlib.sha256()
        for chunk in self.chunks:
            _export_read_charge("consumer.independent-sha", len(chunk))
            measured.update(chunk)
        return measured.hexdigest()

    def __eq__(self, other):
        if not isinstance(other, (_ExportSnapshot, bytes, bytearray, memoryview)):
            return NotImplemented
        if len(self) != len(other):
            return False
        _export_read_charge("consumer.whole-equality", 0, call=True)
        right = iter(other.chunks) if isinstance(other, _ExportSnapshot) else iter((other,))
        current, offset = memoryview(b""), 0
        for chunk in self.chunks:
            left = memoryview(chunk)
            while left:
                if offset == len(current):
                    current, offset = memoryview(next(right)), 0
                size = min(len(left), len(current) - offset)
                _export_read_charge("consumer.whole-equality", size * 2)
                if left[:size] != current[offset:offset + size]:
                    return False
                left, offset = left[size:], offset + size
        return True

    def recheck(self, item, code):
        _require(self.owner is item and item.before.st_size == self.size, code)
        item.recheck(code)
        _export_read_charge("consumer.completion-reread", 0, call=True)
        measured = hashlib.sha256()
        try:
            os.lseek(item.fd, 0, os.SEEK_SET)
            for chunk in self.chunks:
                expected = memoryview(chunk)
                while expected:
                    _require(sum(value["read_bytes"] for value in _export_work.values())
                             + len(expected) * 2 <= 1536 * DOCUMENT_LIMIT, "E_LIMIT")
                    current = os.read(item.fd, len(expected))
                    _require(bool(current), code)
                    _export_read_charge("consumer.completion-reread", len(current) * 2)
                    _require(current == expected[:len(current)], code)
                    measured.update(current)
                    expected = expected[len(current):]
        except (OSError, ValueError):
            raise Refusal(code) from None
        _require(measured.hexdigest() == self.acquisition_sha, code)
        item.recheck(code)


def _read_export_snapshot(item, code):
    item.recheck(code)
    _require(0 <= item.before.st_size <= EXPORT_LIMIT, code)
    chunks, remaining, measured = [], item.before.st_size, hashlib.sha256()
    _export_read_charge("consumer.held-acquisition", 0, call=True)
    try:
        os.lseek(item.fd, 0, os.SEEK_SET)
        while remaining:
            _require(sum(value["read_bytes"] for value in _export_work.values())
                     + min(65536, remaining) <= 1536 * DOCUMENT_LIMIT, "E_LIMIT")
            chunk = os.read(item.fd, min(65536, remaining))
            _require(bool(chunk), code)
            _export_read_charge("consumer.held-acquisition", len(chunk))
            measured.update(chunk)
            chunks.append(chunk)
            remaining -= len(chunk)
    except (OSError, ValueError):
        raise Refusal(code) from None
    item.recheck(code)
    return _ExportSnapshot(chunks, item, measured.hexdigest())

_RUNTIME_FIELDS = {"logical_bytes": 4 << 30, "files": 64, "physical_bytes": 24 << 30,
    "physical_files": 384, "read_bytes": 104 << 30, "write_bytes": 20 << 30,
    "sha_bytes": 80 << 30, "equality_bytes": 56 << 30, "copy_bytes": 20 << 30}
_RUNTIME_ROLES = {"guest_kernel", "guest_init", "guest_supervisor", "image", "toolchain", "verifier",
    "guest_kernel_config", "runtime_vfkit", "runtime_driver", "vm_service", "dyld_cache_files",
    "host_config", "host_supervisor_source", "host_python", "preparation_source", "python", "git", "jq"}
_RUNTIME_ROLES |= {"installed_" + name for name in ("accepted_set", "registry", "control_policy",
    "control_decision", "control_policy_set", "evaluator_driver", "evaluator_program")}


def _runtime_account(work, field, amount, *, window=False):
    _require(field in _RUNTIME_FIELDS and type(amount) is int and amount >= 0, "E_LIMIT")
    counts = work.setdefault("runtime", {})
    limit = _RUNTIME_FIELDS[field] * (4 if window else 1)
    current = counts.get(field, 0)
    _require(type(current) is int and current >= 0 and current + amount <= limit, "E_LIMIT")
    counts[field] = current + amount


def _runtime_inventory_values(group):
    _require(type(group) is dict and set(group) in ({"files"}, {"slots", "files"})
             and type(group.get("files")) is list and 1 <= len(group["files"]) <= 64, "E_STORE")
    names, total = set(), 0
    for ordinal, row in enumerate(group["files"]):
        _require(type(row) is dict and set(row) == {"slot", "index", "ordinal", "locator", "file",
            "size_bytes", "sha256", "errno"} and type(row["slot"]) is str
            and row["slot"] in _RUNTIME_ROLES and type(row["index"]) is int and 0 <= row["index"] < 64
            and (row["slot"] == "dyld_cache_files" or row["index"] == 0)
            and type(row["ordinal"]) is int and row["ordinal"] == ordinal
            and _physical(row["locator"]) and "\0" not in row["locator"]
            and not any(0xd800 <= ord(char) <= 0xdfff for char in row["locator"])
            and len(os.fsencode(row["locator"])) <= 4096
            and type(row["size_bytes"]) is int and 0 <= row["size_bytes"] <= 4 << 30
            and _sha(row["sha256"]) and row["errno"] is None, "E_STORE")
        _require(row["file"] == "runtime-" + str(ordinal).zfill(4) + "-" + row["slot"]
                 + "-" + str(row["index"]).zfill(4) + ".bin" and row["file"] not in names, "E_STORE")
        names.add(row["file"]);total += row["size_bytes"]
        _require(total <= 4 << 30, "E_LIMIT")
    return {row["file"]: row for row in group["files"]}


def _runtime_config_binding(rows, config):
    expected = dict(config["identity_paths"])
    expected.update(runtime_vfkit=config["runtime"]["vfkit"], runtime_driver=config["runtime"]["driver"])
    expected.update({"installed_" + key: value for key, value in config["installed_files"].items()})
    expected.update(host_config=os.path.join(ANCHOR, "host-config.json"),
                    host_supervisor_source=os.path.join(ANCHOR, "host-supervisor.py"))
    for row in rows.values():
        if row["slot"] not in expected:
            continue
        locator = expected[row["slot"]]
        if row["slot"] == "dyld_cache_files":
            _require(row["index"] < len(locator), "E_STORE")
            locator = locator[row["index"]]
        _require(row["locator"] == locator, "E_STORE")


def _capture_runtime_files(groups):
    runtime = groups.get("runtime")
    return {} if runtime is None else _runtime_inventory_values(runtime)


def _copy_runtime_file(directory, name, snapshot, work, resolver):
    _require(isinstance(snapshot, _RuntimeSnapshot), "E_STORE")
    writer = reader = None
    failure = None
    try:
        _require(work.get("runtime", {}).get("physical_files", 0) < _RUNTIME_FIELDS["physical_files"], "E_LIMIT")
        writer = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=directory)
        _runtime_account(work, "physical_files", 1)
        for chunk in snapshot.chunks:
            view = memoryview(chunk)
            while view:
                amount = min(len(view), 65536)
                counts = work.get("runtime", {})
                _require(all(counts.get(field, 0) + amount <= _RUNTIME_FIELDS[field]
                             for field in ("write_bytes", "physical_bytes", "copy_bytes")), "E_LIMIT")
                sent = os.write(writer, view[:amount])
                _require(type(sent) is int and 0 < sent <= amount, "E_STORE")
                for field in ("write_bytes", "physical_bytes", "copy_bytes"):
                    _runtime_account(work, field, sent)
                view = view[sent:]
        os.fchmod(writer, 0o400);os.fsync(writer)
        closing, writer = writer, None
        _close_capture_copy(closing, work, work, name, None)
        reader = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        before = _metadata(reader)
        _require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
                 and before.st_uid == os.geteuid() and before.st_gid == os.getegid()
                 and stat.S_IMODE(before.st_mode) == 0o400 and before.st_size == len(snapshot), "E_STORE")
        access, default = _acl_state(reader, resolver)
        _require(access == [] if sys.platform == "darwin" else access is None and default is None, "E_STORE")
        left_hash, right_hash, offset = hashlib.sha256(), hashlib.sha256(), 0
        snapshot.owner.recheck("E_STORE")
        while offset < len(snapshot):
            count = min(65536, len(snapshot) - offset)
            counts = work.get("runtime", {})
            _require(all(counts.get(field, 0) + 2 * count <= _RUNTIME_FIELDS[field]
                         for field in ("read_bytes", "sha_bytes", "equality_bytes")), "E_LIMIT")
            left = os.pread(snapshot.owner.fd, count, offset)
            _runtime_account(work, "read_bytes", len(left))
            right = os.pread(reader, count, offset)
            _runtime_account(work, "read_bytes", len(right))
            left_hash.update(left);right_hash.update(right)
            _runtime_account(work, "sha_bytes", len(left) + len(right))
            _runtime_account(work, "equality_bytes", len(left) + len(right))
            _require(len(left) == len(right) == count and left == right, "E_STORE")
            offset += count
        _require(left_hash.hexdigest() == right_hash.hexdigest() == snapshot.acquisition_sha, "E_STORE")
        snapshot.owner.recheck("E_STORE")
        _require(_identity(before) == _identity(_metadata(reader))
                 == _identity(_named_metadata(name, directory)), "E_STORE")
    except BaseException as error:
        failure = error
        try:
            work["runtime_incomplete"] = True
            work.setdefault("runtime_copy_failure", {"category": type(error).__name__,
                "errno": getattr(error, "os_errno", getattr(error, "errno", None))})
        except MemoryError:
            pass
        raise
    finally:
        for fd in (reader, writer):
            if fd is not None:
                try:_close_capture_copy(fd, work, work, name, failure)
                except BaseException as error:
                    if failure is None:
                        failure = error
                    elif getattr(error, "_scope_signal_cancel", False) and not getattr(failure, "_scope_signal_cancel", False):
                        failure = error
        if failure is not None:
            raise failure


class _RuntimeSnapshot:
    def __init__(self, owner, work):
        self.owner, self.work, self.size = owner, work, owner.before.st_size
        _require(0 <= self.size <= 4 << 30, "E_LIMIT")
        _runtime_account(work, "logical_bytes", self.size)
        _runtime_account(work, "files", 1)
        _runtime_account(work, "physical_bytes", self.size)
        _runtime_account(work, "physical_files", 1)
        self.acquisition_sha = None
        self.acquisition_sha = self.sha256()

    def __len__(self):
        return self.size

    @property
    def chunks(self):
        self.owner.recheck("E_STORE")
        measured, offset = hashlib.sha256(), 0
        while offset < self.size:
            count = min(65536, self.size - offset)
            limits = self.work.get("runtime", {})
            _require(limits.get("read_bytes", 0) + count <= _RUNTIME_FIELDS["read_bytes"]
                     and limits.get("sha_bytes", 0) + count <= _RUNTIME_FIELDS["sha_bytes"], "E_LIMIT")
            try:
                chunk = os.pread(self.owner.fd, count, offset)
            except OSError as error:
                self.work["runtime_incomplete"] = True
                if getattr(error, "_scope_signal_cancel", False):raise
                raise Refusal("E_STORE", os_errno=error.errno) from None
            _runtime_account(self.work, "read_bytes", len(chunk))
            measured.update(chunk);_runtime_account(self.work, "sha_bytes", len(chunk))
            _require(len(chunk) == count, "E_STORE")
            offset += len(chunk)
            yield chunk
        self.owner.recheck("E_STORE")
        self.last_digest = measured.hexdigest()
        if self.acquisition_sha is not None:
            _require(self.last_digest == self.acquisition_sha, "E_STORE")

    def sha256(self):
        for _chunk in self.chunks:
            pass
        return self.last_digest

    def recheck(self, item, code):
        _require(item is self.owner and item.before.st_size == self.size, code)
        _require(self.sha256() == self.acquisition_sha, code)


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

    def raw_uuid_replies(self):
        return None

class _DarwinGroupReader:
    def contains(self, gid: int) -> bool:
        raise NotImplementedError

    def raw_group_replies(self):
        return None

def _metadata(fd: int) -> os.stat_result:
    """Private OS observation seam used only by in-process fixtures."""
    return os.fstat(fd)

def _named_metadata(name: str, parent_fd: int) -> os.stat_result:
    """Private no-follow name observation seam used only by in-process fixtures."""
    return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)

def _stat_values(value: os.stat_result) -> dict:
    return {key: getattr(value, "st_" + key) for key in
            ("dev", "ino", "mode", "uid", "gid", "nlink", "size", "mtime_ns", "ctime_ns")}


def _identity_values(value: dict) -> tuple[int, ...]:
    _require(type(value) is dict and set(value) == {
        "dev", "ino", "mode", "uid", "gid", "nlink", "size", "mtime_ns", "ctime_ns"}
        and all(type(number) is int for number in value.values()), "E_STORE")
    return (value["dev"], value["ino"], stat.S_IFMT(value["mode"]), value["uid"], value["gid"],
            stat.S_IMODE(value["mode"]), value["nlink"], value["size"], value["mtime_ns"], value["ctime_ns"])


def _identity(value: os.stat_result) -> tuple[int, ...]:
    return _identity_values(_stat_values(value))

Rule = Callable[[int, os.stat_result, bool], bool]

@dataclasses.dataclass
class HeldComponent:
    fd: int
    name: str | None
    before: os.stat_result
    rule: Rule
    ancestor: bool
    after: os.stat_result | None = None
    named_after: os.stat_result | None = None

@dataclasses.dataclass
class HeldPath:
    path: str
    components: list[HeldComponent]
    directory_names: list[str] | None = None
    recording_work: dict | None = None
    accounting_kind: str | None = None

    def listdir(self):
        names = os.listdir(self.fd)
        self.directory_names = [os.fsencode(name).hex() for name in names]
        if self.recording_work is not None:
            _capture_observe(self.recording_work, self.accounting_kind, "listdir", {
                "fd": self.fd, "names": self.directory_names})
        return names

    @property
    def fd(self) -> int:
        return self.components[-1].fd

    @property
    def before(self) -> os.stat_result:
        return self.components[-1].before

    def recheck(self, code: str, recording_work=None, accounting_kind=None) -> None:
        work = self.recording_work if recording_work is None else recording_work
        kind = accounting_kind or self.accounting_kind or (work.get("metadata_kind", "unresolved") if work is not None else None)
        for index, component in enumerate(self.components):
            try:
                current = _capture_metadata(component.fd, work, kind)
                named = (current if component.name is None else
                         _capture_named_metadata(component.name, self.components[index - 1].fd, work, kind))
            except (OSError, ValueError) as error:
                if getattr(error, "_scope_signal_cancel", False):
                    raise
                raise Refusal(code) from None
            expected = _identity(component.before)
            _require(_identity(current) == expected and _identity(named) == expected, code)
            _require(_capture_rule(component.rule, component.fd, current, component.ancestor, work, kind), code)
            try:
                after = _capture_metadata(component.fd, work, kind)
                after_named = (after if component.name is None else
                               _capture_named_metadata(component.name, self.components[index - 1].fd, work, kind))
            except (OSError, ValueError) as error:
                if getattr(error, "_scope_signal_cancel", False):
                    raise
                raise Refusal(code) from None
            _require(_identity(after) == expected and _identity(after_named) == expected, code)
            component.after, component.named_after = after, after_named

    def seal_recheck(self, code: str) -> None:
        for index, component in enumerate(self.components):
            try:
                current = _metadata(component.fd)
                named = (current if component.name is None else
                         _named_metadata(component.name, self.components[index - 1].fd))
            except (OSError, ValueError) as error:
                if getattr(error, "_scope_signal_cancel", False):
                    raise
                raise Refusal(code) from None
            expected = _identity(component.before)
            _require(_identity(current) == expected and _identity(named) == expected, code)
            component.after, component.named_after = current, named

    def read(self, maximum: int, code: str, recording_work=None) -> bytes:
        if recording_work is not None:
            recording_work["metadata_passes"] = recording_work.get("metadata_passes", 0) + 1
        self.recheck(code) if recording_work is None else self.recheck(code, recording_work)
        chunks, total = [], 0
        try:
            os.lseek(self.fd, 0, os.SEEK_SET)
            while True:
                if recording_work is not None:
                    if total == self.before.st_size:
                        break
                    _capture_copy_room(recording_work, total + 2 * min(65536, maximum + 1 - total),
                                       False, case=True, read_only=True)
                    recording_work["read_calls"] = recording_work.get("read_calls", 0) + 1
                chunk = os.read(self.fd, min(65536, maximum + 1 - total))
                if not chunk:
                    break
                if recording_work is not None:
                    recording_work["read_bytes"] = recording_work.get("read_bytes", 0) + len(chunk)
                    _capture_account(recording_work, recording_work.get("input_kind", "raw"), "read_bytes", len(chunk))
                chunks.append(chunk)
                total += len(chunk)
                _require(total <= maximum, code)
        except (OSError, ValueError) as error:
            if recording_work is not None:
                recording_work["read_error"] = {"category": type(error).__name__, "errno": getattr(error, "errno", None)}
                recording_work["read_incomplete"] = True
                if getattr(error, "_scope_signal_cancel", False):
                    raise
            raise Refusal(code) from None
        if recording_work is not None:
            recording_work["metadata_passes"] = recording_work.get("metadata_passes", 0) + 1
        self.recheck(code) if recording_work is None else self.recheck(code, recording_work)
        if recording_work is not None:
            _capture_copy_room(recording_work, total, False, case=True, read_only=True)
            recording_work["read_bytes"] = recording_work.get("read_bytes", 0) + total
            recording_work["join_bytes"] = recording_work.get("join_bytes", 0) + total
            _capture_account(recording_work, recording_work.get("input_kind", "raw"), "read_bytes", total)
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
        failure = None
        for component in reversed(self.components):
            close_error = None
            try:
                os.close(component.fd)
            except OSError as exc:
                close_error = exc
                if failure is None or (getattr(exc, "_scope_signal_cancel", False)
                                       and not getattr(failure, "_scope_signal_cancel", False)):
                    failure = exc
            if self.recording_work is not None:
                try:
                    self.recording_work["held_close_calls"] = self.recording_work.get("held_close_calls", 0) + 1
                    _capture_observe(self.recording_work, "M", "held-close", {
                        "return": 0 if close_error is None else -1,
                        "errno": None if close_error is None else close_error.errno})
                except (OSError, ValueError, TypeError, Refusal, MemoryError) as observed:
                    try:self.recording_work["accounting_incomplete"] = True
                    except MemoryError:pass
                    if getattr(observed, "_scope_signal_cancel", False) and not getattr(failure, "_scope_signal_cancel", False):
                        failure = observed
        self.components.clear()
        if failure is not None:
            raise failure

def _close_components(rows: list[HeldComponent], failure: BaseException | None = None) -> None:
    while rows:
        row = rows.pop()
        try:
            os.close(row.fd)
        except OSError as exc:
            if failure is None or (getattr(exc, "_scope_signal_cancel", False)
                                   and not getattr(failure, "_scope_signal_cancel", False)):
                failure = exc
    if failure is not None:
        raise failure

def _close_paths(items: list[HeldPath]) -> None:
    failure = None
    while items:
        item = items.pop()
        try:
            item.close()
        except OSError as exc:
            if failure is None or (getattr(exc, "_scope_signal_cancel", False)
                                   and not getattr(failure, "_scope_signal_cancel", False)):
                failure = exc
    if failure is not None:
        raise failure

def _clone(parent: HeldPath, code: str, recording_work=None, accounting_kind=None) -> list[HeldComponent]:
    rows = []
    try:
        parent.recheck(code) if recording_work is None else parent.recheck(code, recording_work, accounting_kind)
        for row in parent.components:
            rows.append(HeldComponent(os.dup(row.fd), row.name, row.before, row.rule, row.ancestor))
            if recording_work is not None:
                _capture_observe(recording_work, accounting_kind, "dup", {"source_fd": row.fd, "fd": rows[-1].fd})
        return rows
    except BaseException as exc:
        try:
            _close_components(rows, exc)
        except Refusal:
            raise
        except OSError as error:
            if getattr(error, "_scope_signal_cancel", False):
                raise
            raise Refusal(code, os_errno=error.errno) from None

def _open_held(path: str, directory: bool, rule: Rule, code: str,
               allow_hardlinks: bool = False, recording_work=None, accounting_kind=None) -> HeldPath:
    _require(_physical(path) and path != "/", code)
    parts = path.split("/")[1:]
    _require(all(part not in ("", ".", "..") for part in parts), code)
    rows: list[HeldComponent] = []
    try:
        fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        state = _metadata(fd)
        rows.append(HeldComponent(fd, None, state, rule, True))
        if recording_work is not None:_capture_observe(recording_work, accounting_kind, "fstat", {"fd": fd, "stat": _stat_values(state)})
        _require(_capture_rule(rule, fd, state, True, recording_work, accounting_kind), code)
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
            if recording_work is not None:_capture_observe(recording_work, accounting_kind, "fstat", {"fd": fd, "stat": _stat_values(state)})
            _require(_capture_rule(rule, fd, state, not last, recording_work, accounting_kind), code)
        state = rows[-1].before
        _require((directory and stat.S_ISDIR(state.st_mode)) or
                 (not directory and stat.S_ISREG(state.st_mode)
                  and (allow_hardlinks or state.st_nlink == 1)), code)
        result = HeldPath(path, rows, recording_work=recording_work, accounting_kind=accounting_kind)
        result.recheck(code)
        return result
    except BaseException as exc:
        try:
            _close_components(rows, exc)
        except Refusal:
            raise
        except (OSError, ValueError) as error:
            if getattr(error, "_scope_signal_cancel", False):
                raise
            raise Refusal(code, os_errno=getattr(error, "errno", None)) from None

def _open_child(parent: HeldPath, name: str, directory: bool, rule: Rule, code: str, *, recording_work=None, accounting_kind=None) -> HeldPath:
    _require(isinstance(name, str) and name and "/" not in name and name not in (".", ".."), code)
    rows = _clone(parent, code, recording_work, accounting_kind)
    try:
        flags = os.O_RDONLY | os.O_NOFOLLOW | (os.O_DIRECTORY if directory else 0)
        if not directory and hasattr(os, "O_NONBLOCK"):
            flags |= os.O_NONBLOCK
        fd = os.open(name, flags, dir_fd=rows[-1].fd)
        state = _metadata(fd)
        rows.append(HeldComponent(fd, name, state, rule, False))
        if recording_work is not None:_capture_observe(recording_work, accounting_kind, "fstat", {"fd": fd, "stat": _stat_values(state)})
        _require(_capture_rule(rule, fd, state, False, recording_work, accounting_kind), code)
        _require((directory and stat.S_ISDIR(state.st_mode)) or
                 (not directory and stat.S_ISREG(state.st_mode) and state.st_nlink == 1), code)
        result = HeldPath(parent.path + "/" + name, rows, recording_work=recording_work, accounting_kind=accounting_kind)
        result.recheck(code)
        return result
    except BaseException as exc:
        try:
            _close_components(rows, exc)
        except Refusal:
            raise
        except (OSError, ValueError) as error:
            if getattr(error, "_scope_signal_cancel", False):
                raise
            raise Refusal(code, os_errno=getattr(error, "errno", None)) from None

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
    captured: list[tuple[int, str, int]] = []
    entry, selector = ctypes.c_void_p(), 0
    tag, perms = ctypes.c_int(), ctypes.c_void_p()
    ctypes.set_errno(0)
    acl = lib.acl_get_fd_np(fd, 0x100)
    if not acl:
        if ctypes.get_errno() == errno.ENOENT:
            return []
        raise OSError(ctypes.get_errno(), "acl_get_fd_np")
    try:
        while True:
            ctypes.set_errno(0)
            rc = lib.acl_get_entry(acl, selector, ctypes.byref(entry))
            entry_errno = ctypes.get_errno()
            if rc != 0:
                if rc == -1 and entry_errno == errno.EINVAL and selector == -1 and captured:
                    break
                raise OSError(entry_errno or errno.EIO, "acl_get_entry")
            selector = -1
            tag.value, perms.value = 0, None
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
            try:
                uuid = ctypes.string_at(qualifier, 16)
                captured.append((tag.value, uuid.hex(), bits))
            finally:
                if lib.acl_free(qualifier) != 0:
                    raise OSError(ctypes.get_errno() or errno.EIO, "acl_free")
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


def _installed_acl_values(platform, access, default, principals):
    if platform != "darwin":
        return _linux_install_acl_ok(access) and _linux_install_acl_ok(default)
    dangerous = (1 << 2) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 8) | (1 << 10) | (1 << 12) | (1 << 13)
    return not any(tag == 1 and identifier not in principals and bits & dangerous
                   for tag, identifier, bits in access)


def _store_values(uid, gid, mode, directory, state, access, default, platform):
    kind = stat.S_ISDIR(state["mode"]) if directory else stat.S_ISREG(state["mode"])
    acl_absent = access == [] if platform == "darwin" else access is None and default is None
    return (kind and state["uid"] == uid and state["gid"] == gid
            and stat.S_IMODE(state["mode"]) == mode and acl_absent)

def _root_rule(resolver: _DarwinUUIDResolver | None = None) -> Rule:
    def check(fd: int, state: os.stat_result, _ancestor: bool) -> bool:
        if state.st_uid != 0 or state.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            return False
        try:
            access, default = _acl_state(fd, resolver)
        except (OSError, Refusal) as error:
            if getattr(error, "_scope_signal_cancel", False):
                raise
            return False
        check.observations[fd] = (access, default)
        return _installed_acl_values(sys.platform, access, default, (0,))
    check.observations = {}
    return check

def _installed_rule(principal_uid: int, resolver: _DarwinUUIDResolver | None = None) -> Rule:
    def check(fd: int, state: os.stat_result, _ancestor: bool) -> bool:
        if state.st_uid not in (0, principal_uid) or state.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            return False
        try:
            access, default = _acl_state(fd, resolver)
        except (OSError, Refusal) as error:
            if getattr(error, "_scope_signal_cancel", False):
                raise
            return False
        check.observations[fd] = (access, default)
        return _installed_acl_values(sys.platform, access, default, (0, principal_uid))
    check.observations = {}
    return check

def _store_rule(uid: int, gid: int, mode: int, directory: bool,
                resolver: _DarwinUUIDResolver | None = None) -> Rule:
    def check(fd: int, state: os.stat_result, ancestor: bool) -> bool:
        if ancestor:
            return True
        try:
            access, default = _acl_state(fd, resolver)
        except (OSError, Refusal) as error:
            if getattr(error, "_scope_signal_cancel", False):
                raise
            return False
        check.observations[fd] = (access, default)
        return _store_values(uid, gid, mode, directory, _stat_values(state), access, default, sys.platform)
    check.observations = {}
    return check

def _read_parent_fd(fd: int) -> bytes:
    os.lseek(fd, 0, os.SEEK_SET)
    chunks, total, prefix, maximum = [], 0, b"", PARENT_LIMIT
    while True:
        part = os.read(fd, min(65536, maximum + 1 - total))
        if not part:
            return b"".join(chunks)
        chunks.append(part)
        total += len(part)
        if len(prefix) < 8:
            prefix += part[:8 - len(prefix)]
            if prefix == PARENT_FRAME_MAGIC:
                maximum = PARENT_FRAME_LIMIT
        _require(total <= maximum, "E_LIMIT")

class _ParentContext(dict):
    def __init__(self, body, context_raw, frame_raw, records):
        super().__init__(body)
        self.context_raw = context_raw
        self.frame_raw = frame_raw
        self.runtime_records = records


def _parent_frame_values(raw):
    if not raw.startswith(PARENT_FRAME_MAGIC):
        _require(len(raw) <= PARENT_LIMIT, "E_PARENT_CONTEXT")
        return raw, ()
    _require(20 <= len(raw) <= PARENT_FRAME_LIMIT, "E_PARENT_CONTEXT")
    lengths = struct.unpack("!III", raw[8:20])
    _require(0 < lengths[0] <= PARENT_LIMIT
             and all(0 < length <= DOCUMENT_LIMIT for length in lengths[1:])
             and 20 + sum(lengths) == len(raw), "E_PARENT_CONTEXT")
    end = 20 + lengths[0]
    context = raw[20:end]
    helper = raw[end:end + lengths[1]]
    dependency = raw[end + lengths[1]:]
    _require(helper != dependency, "E_PARENT_CONTEXT")
    return context, (helper, dependency)


def capture_parent_context(fd: int = 3) -> dict:
    try:
        flags, before = fcntl.fcntl(fd, fcntl.F_GETFL), _metadata(fd)
        _require(flags & os.O_ACCMODE == os.O_RDONLY and stat.S_ISREG(before.st_mode), "E_PARENT_CONTEXT")
        frame_raw = _read_parent_fd(fd)
        after = _metadata(fd)
    except (OSError, ValueError, Refusal):
        raise Refusal("E_PARENT_CONTEXT") from None
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
    _require(_identity(before) == _identity(after), "E_PARENT_CONTEXT")
    raw, records = _parent_frame_values(frame_raw)
    return _parent_context_values(raw, frame_raw, records)


def _parent_context_values(raw, frame_raw, records):
    doc = _json(raw, PARENT_LIMIT, "E_PARENT_CONTEXT")
    _require(set(doc) == {"schema_version", "kind", "id", "body"} and _integer(doc["schema_version"])
             and doc["schema_version"] == 2 and doc["kind"] == "shadow_consumer_parent_context"
             and doc["id"] == "shadow.parent", "E_PARENT_CONTEXT")
    body = doc["body"]
    _require(isinstance(body, dict) and set(body) == set(HASH_KEYS) | {
                 "helper_executable_size", "helper_path", "native_release"}
             and all(_sha(body[key]) for key in HASH_KEYS), "E_PARENT_CONTEXT")
    _require(_integer(body["helper_executable_size"]) and 0 < body["helper_executable_size"] <= EXECUTABLE_LIMIT
             and _physical(body["helper_path"]) and body["helper_source_sha256"] == HELPER_SOURCE_SHA256,
             "E_PARENT_CONTEXT")
    native = body["native_release"]
    _require(isinstance(native, dict) and set(native) == NATIVE_RELEASE_KEYS
             and all(_sha(native[key]) for key in ("source_sha256", "build_script_sha256",
                 "build_record_sha256", "binary_sha256", "python_sha256",
                 "dependency_record_sha256"))
             and _physical(native["binary_path"]) and _physical(native["python_path"])
             and _integer(native["binary_size"]) and 1 <= native["binary_size"] <= EXECUTABLE_LIMIT
             and isinstance(native["python_abi"], str) and 1 <= len(native["python_abi"]) <= 128
             and all(0x20 <= ord(char) <= 0x7e for char in native["python_abi"])
             and native["loader_mode"] == "rtld-now-local.v1", "E_PARENT_CONTEXT")
    if records:
        helper, dependency = records
        for record in records:
            _require(0 < len(record) <= DOCUMENT_LIMIT, "E_PARENT_CONTEXT")
            try:
                parsed = json.loads(record, object_pairs_hook=_unique_object)
                _require(canonical(parsed) == record, "E_PARENT_CONTEXT")
            except (UnicodeDecodeError, UnicodeEncodeError, ValueError, TypeError, RecursionError):
                raise Refusal("E_PARENT_CONTEXT") from None
        _require(digest(helper) == body["helper_build_record_sha256"]
                 and digest(dependency) == native["dependency_record_sha256"], "E_PARENT_CONTEXT")
    return _ParentContext(body, raw, frame_raw, records)

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
        failure = None
        for item in (self.original, self.snapshot):
            try:
                item.close()
            except OSError as exc:
                if failure is None:
                    failure = exc
        if failure is not None:
            raise failure

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

def _preparation_capture_binding_values(raw, operation, input_raw, response_raw):
    _require(operation in {"prepare", "inspect"}, "E_STORE")
    value = _json(raw, DOCUMENT_LIMIT, "E_STORE")
    _require(set(value) == {"operation", "binding", "entropy", "clocks", "storage", "commands", "runtime", "complete"}
             and value["complete"] is True and value["operation"] == operation
             and value["binding"] == {"input_sha256": digest(input_raw), "response_sha256": digest(response_raw)}, "E_STORE")
    runtime = _runtime_inventory_values(value["runtime"])
    _require(len(runtime) == 4 and {row["slot"] for row in runtime.values()}
             == {"preparation_source", "python", "git", "jq"}, "E_STORE")
    return value, runtime, ".runtime-complete-" + digest(raw)


def _preparation_seal_values(name, expected, before, after, named, uid, gid, access, default, platform, contents):
    _require(name == expected and contents == [] and type(contents) is list
             and _identity_values(before) == _identity_values(after) == _identity_values(named)
             and before["nlink"] > 0
             and _store_values(uid, gid, 0o700, True, before, access, default, platform), "E_STORE")
    return True


def _refresh_recording_directory(item, before, work):
    current = _capture_metadata(item.fd, work, "M")
    component = item.components[-1]
    named = _capture_named_metadata(component.name, item.components[-2].fd, work, "M")
    stable = lambda value: (value.st_dev, value.st_ino, value.st_uid, value.st_gid, value.st_mode)
    _require(stable(current) == stable(before) and _identity(current) == _identity(named)
             and _capture_rule(component.rule, item.fd, current, False, work, "M"), "E_STORE")
    component.before = current
    component.after, component.named_after = current, named


def _copy_preparation_document(directory, raw, work, resolver):
    _require(type(raw) is bytes and len(raw) <= DOCUMENT_LIMIT, "E_STORE")
    target = reader = None
    failure = None
    try:
        _capture_copy_room(work, len(raw), False, case=True)
        target = os.open("capture.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=directory)
        work["files"] += 1
        view = memoryview(raw)
        while view:
            chunk = view[:65536]
            _capture_copy_room(work, len(chunk), False, case=True)
            sent = os.write(target, chunk)
            _require(type(sent) is int and 0 < sent <= len(chunk), "E_STORE")
            for field in ("read_bytes", "write_bytes", "physical_bytes"):work[field] += sent
            view = view[sent:]
        os.fchmod(target, 0o400);os.fsync(target)
        closing, target = target, None
        _close_capture_copy(closing, work, work, "preparation-capture-writer", None)
        reader = os.open("capture.json", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
        before = _metadata(reader)
        _require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                 and before.st_gid == os.getegid() and before.st_nlink == 1
                 and stat.S_IMODE(before.st_mode) == 0o400 and before.st_size == len(raw), "E_STORE")
        access, default = _acl_state(reader, resolver)
        _require(access == [] if sys.platform == "darwin" else access is None and default is None, "E_STORE")
        offset = 0
        while offset < len(raw):
            count = min(65536, len(raw) - offset)
            _capture_copy_room(work, 3 * count, False, case=True, read_only=True)
            chunk = os.pread(reader, count, offset)
            work["read_bytes"] += 3 * len(chunk)
            _require(len(chunk) == count and chunk == memoryview(raw)[offset:offset + count], "E_STORE")
            offset += count
        _require(_identity(before) == _identity(_metadata(reader))
                 == _identity(_named_metadata("capture.json", directory)), "E_STORE")
    except BaseException as error:
        failure = error
        work["preparation_document_incomplete"] = True
        raise
    finally:
        for fd in (reader, target):
            if fd is not None:
                try:_close_capture_copy(fd, work, work, "preparation-document-close", failure)
                except BaseException as error:
                    if failure is None or getattr(error, "_scope_signal_cancel", False) and not getattr(failure, "_scope_signal_cancel", False):
                        failure = error
        if failure is not None:raise failure


@dataclasses.dataclass
class Anchor:
    config: dict
    config_raw: bytes
    held: list[HeldPath]
    installed: dict[str, tuple[bytes, str]]
    registry: tuple[str, list[dict]]
    accepted: tuple[str, list[dict]]
    resolver: _DarwinUUIDResolver | None
    identity_context: dict | None = None
    private_observations: dict = dataclasses.field(default_factory=dict)
    storage_entry_count: int = 0
    recording_work: dict = dataclasses.field(default_factory=dict)

    def retain_preparation(self, parent, scratch_name, operation, input_raw, response_raw, caller_raw):
        _require(scratch_name in {"preparation-scratch", "inspection-scratch"}
                 and operation in {"prepare", "inspect"}, "E_STORE")
        opened, storage_rows, runtime_leaf = [], [], {}
        _capture_work_values(runtime_leaf, "preparation:" + operation)
        self.recording_work.setdefault("preparation_leaves", []).append(runtime_leaf)
        failure, case_work = None, None
        failures = (Refusal, OSError, ValueError, TypeError, MemoryError, ImportError)
        try:
            caller = _json(caller_raw, DOCUMENT_LIMIT, "E_STORE")
            _require(caller.get("kind") in {"shadow_enforced_request", "shadow_write_request"}
                     and _id(caller.get("id")), "E_STORE")
            uid, gid = os.geteuid(), os.getegid()
            case_key = str(parent.before.st_dev) + ":" + str(parent.before.st_ino)
            case_work = _capture_work_values(self.recording_work, case_key)
            parent.recheck("E_STORE")
            parent_before = parent.before
            destination_name = "preparation-runtime-" + operation
            os.mkdir(destination_name, 0o700, dir_fd=parent.fd)
            _refresh_recording_directory(parent, parent_before, runtime_leaf)
            destination = _open_child(parent, destination_name, True,
                _store_rule(uid, gid, 0o700, True, self.resolver), "E_STORE",
                recording_work=runtime_leaf, accounting_kind="M")
            opened.append(destination)
            destination_before = destination.before
            root = _open_child(parent, scratch_name, True, _store_rule(uid, gid, 0o700, True, self.resolver),
                               "E_STORE", recording_work=runtime_leaf, accounting_kind="M")
            opened.append(root)
            names = root.listdir()
            _require(len(names) <= 128, "E_STORE")
            candidates = []
            for name in sorted(names):
                _require(name.startswith("candidate-preparation-") and len(name[len("candidate-preparation-"):]) == 16
                         and all(char in "0123456789abcdef" for char in name[len("candidate-preparation-"):]), "E_STORE")
                directory = _open_child(root, name, True, _store_rule(uid, gid, 0o700, True, self.resolver),
                                       "E_STORE", recording_work=runtime_leaf, accounting_kind="M")
                opened.append(directory)
                try:
                    item = _open_child(directory, "capture.json", False, _store_rule(uid, gid, 0o400, False, self.resolver),
                                       "E_STORE", recording_work=runtime_leaf, accounting_kind="M")
                except Refusal as error:
                    if error.os_errno == errno.ENOENT:continue
                    raise
                opened.append(item)
                raw = item.read(DOCUMENT_LIMIT, "E_STORE", runtime_leaf)
                _capture_copy_room(runtime_leaf, 7 * len(raw), False, case=True, read_only=True)
                runtime_leaf["read_bytes"] += 7 * len(raw)
                value, runtime_files, expected_seal = _preparation_capture_binding_values(raw, operation, input_raw, response_raw)
                listed = set(directory.listdir())
                runtime_leaf["read_bytes"] += len(raw)
                _require({entry for entry in listed if entry.startswith(".runtime-complete")}
                         == {expected_seal} and {entry for entry in listed if entry.startswith("runtime-")}
                         == set(runtime_files), "E_STORE")
                seal = _open_child(directory, expected_seal, True, _store_rule(uid, gid, 0o700, True, self.resolver),
                                   "E_STORE", recording_work=runtime_leaf, accounting_kind="M")
                opened.append(seal)
                contents = seal.listdir()
                seal.recheck("E_STORE")
                last = seal.components[-1]
                access, default = last.rule.observations[seal.fd]
                _preparation_seal_values(last.name, expected_seal, _stat_values(last.before),
                    _stat_values(last.after), _stat_values(last.named_after), uid, gid, access, default,
                    sys.platform, contents)
                _observation(directory, "preparation/" + operation, storage_rows=storage_rows)
                _observation(item, "preparation/" + operation + "/capture.json", raw, storage_rows=storage_rows)
                _observation(seal, "preparation/" + operation + "/" + expected_seal, storage_rows=storage_rows)
                for filename in sorted(runtime_files):
                    source = _open_child(directory, filename, False, _store_rule(uid, gid, 0o400, False, self.resolver),
                                         "E_STORE", recording_work=runtime_leaf, accounting_kind="M")
                    opened.append(source)
                    snapshot = _RuntimeSnapshot(source, runtime_leaf)
                    _require(len(snapshot) == runtime_files[filename]["size_bytes"]
                             and snapshot.acquisition_sha == runtime_files[filename]["sha256"], "E_STORE")
                    _observation(source, "preparation/" + operation + "/" + filename, snapshot, storage_rows=storage_rows)
                    _require(snapshot.sha256() == runtime_files[filename]["sha256"], "E_STORE")
                    _copy_runtime_file(destination.fd, filename, snapshot, runtime_leaf, self.resolver)
                _copy_preparation_document(destination.fd, raw, runtime_leaf, self.resolver)
                _refresh_recording_directory(destination, destination_before, runtime_leaf)
                _require(set(destination.listdir()) == set(runtime_files) | {"capture.json"}, "E_STORE")
                os.fsync(destination.fd);os.fsync(parent.fd)
                item.recheck("E_STORE");seal.recheck("E_STORE");directory.recheck("E_STORE")
                self.retain_storage_reads(caller["id"], opened, storage_rows)
                candidates.append(value)
            _require(len(candidates) == 1, "E_STORE")
            root.recheck("E_STORE")
            values = self.private_observations.setdefault("preparation", {})
            _require(operation not in values, "E_STORE")
            values[operation] = candidates[0]
            return candidates[0]
        except BaseException as error:
            failure = error
            self.private_observations["unusable"] = True
            runtime_leaf["failure"] = {"category": type(error).__name__, "errno": getattr(error, "os_errno", getattr(error, "errno", None))}
            if getattr(error, "_scope_signal_cancel", False) or not isinstance(error, failures):raise
            return None
        finally:
            try:_close_paths(opened)
            except (OSError, Refusal, MemoryError) as error:
                self.private_observations["unusable"] = True
                runtime_leaf["release_failure"] = {"category": type(error).__name__, "errno": getattr(error, "errno", None)}
                if getattr(error, "_scope_signal_cancel", False) and not getattr(failure, "_scope_signal_cancel", False):raise
            finally:
                if case_work is not None:
                    try:
                        _capture_transfer_work(runtime_leaf, self.recording_work, case_work)
                        _capture_accounting_receipt(self)
                    except Exception as error:
                        self.private_observations["unusable"] = True
                        runtime_leaf["transfer_incomplete"] = True
                        if getattr(error, "_scope_signal_cancel", False) and not getattr(failure, "_scope_signal_cancel", False):raise

    def copy_runtime_slots(self, parent, slots, work):
        fixed = {key: self.config["identity_paths"][key] for key in
            ("guest_kernel", "guest_init", "guest_supervisor", "image", "toolchain", "verifier",
             "guest_kernel_config", "vm_service", "dyld_cache_files")}
        fixed.update(runtime_vfkit=self.config["runtime"]["vfkit"],
                     runtime_driver=self.config["runtime"]["driver"])
        _require(type(slots) is dict and set(slots) == set(fixed)
                 and type(slots["dyld_cache_files"]) is list
                 and len(slots["dyld_cache_files"]) == len(fixed["dyld_cache_files"]), "E_STORE")
        _require(len(slots) - 1 + len(slots["dyld_cache_files"]) <= 64, "E_LIMIT")
        selected = []
        for role in sorted(fixed):
            items = slots[role] if role == "dyld_cache_files" else [slots[role]]
            paths = fixed[role] if role == "dyld_cache_files" else [fixed[role]]
            for index, (item, path) in enumerate(zip(items, paths)):
                _require(isinstance(item, HeldPath) and item.path == path
                         and stat.S_ISREG(item.before.st_mode), "E_STORE")
                selected.append((role, index, item))
        _require(len(selected) <= 64 and sum(item.before.st_size for _, _, item in selected)
                 <= 4 * 1024 * 1024 * 1024, "E_LIMIT")
        parent.recheck("E_STORE")
        state = _metadata(parent.fd)
        _require(state.st_uid == os.geteuid() and stat.S_ISDIR(state.st_mode)
                 and stat.S_IMODE(state.st_mode) == 0o700, "E_STORE")
        work.setdefault("runtime_read_bytes", 0)
        work.setdefault("runtime_write_bytes", 0)
        work.setdefault("runtime_physical_bytes", 0)
        work.setdefault("runtime_files", 0)
        _require(all(type(work[key]) is int and work[key] >= 0 for key in
            ("runtime_read_bytes", "runtime_write_bytes", "runtime_physical_bytes", "runtime_files")), "E_LIMIT")
        os.mkdir("qualified-runtime", 0o700, dir_fd=parent.fd)
        after_parent = _metadata(parent.fd)
        _require((after_parent.st_dev, after_parent.st_ino, after_parent.st_uid, after_parent.st_gid,
                  after_parent.st_mode) == (state.st_dev, state.st_ino, state.st_uid, state.st_gid, state.st_mode), "E_STORE")
        parent.components[-1].before = after_parent
        directory = os.open("qualified-runtime", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent.fd)
        directory_failure = None
        try:
            manifest = []
            directory_state = _metadata(directory)
            _require(_store_values(os.geteuid(), os.getegid(), 0o700, True,
                _stat_values(directory_state), *_acl_state(directory, self.resolver), sys.platform), "E_STORE")
            for role, index, source in selected:
                source.recheck("E_STORE")
                length = source.before.st_size
                _require(0 <= length <= 4 * 1024 * 1024 * 1024
                         and work["runtime_files"] < 64, "E_LIMIT")
                name = role + (f".{index:04d}" if role == "dyld_cache_files" else "")
                target = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                 0o600, dir_fd=directory)
                file_failure = None
                try:
                    work["runtime_files"] += 1
                    total, measured = 0, hashlib.sha256()
                    os.lseek(source.fd, 0, os.SEEK_SET)
                    while total < length:
                        count = min(65536, length - total)
                        _require(work["runtime_physical_bytes"] + count <= 4 * 1024 * 1024 * 1024, "E_LIMIT")
                        chunk = os.read(source.fd, count)
                        work["runtime_read_bytes"] += len(chunk)
                        _require(bool(chunk), "E_STORE")
                        measured.update(chunk)
                        view = memoryview(chunk)
                        while view:
                            sent = os.write(target, view)
                            _require(0 < sent <= len(view), "E_STORE")
                            work["runtime_write_bytes"] += sent
                            work["runtime_physical_bytes"] += sent
                            view = view[sent:]
                        total += len(chunk)
                    os.fchmod(target, 0o400)
                    os.fsync(target)
                    target_state = _metadata(target)
                    _require(stat.S_ISREG(target_state.st_mode) and target_state.st_uid == os.geteuid()
                             and target_state.st_gid == os.getegid()
                             and target_state.st_nlink == 1 and target_state.st_size == length
                             and stat.S_IMODE(target_state.st_mode) == 0o400
                             and _identity(target_state) == _identity(_named_metadata(name, directory)), "E_STORE")
                    _require(_store_values(os.geteuid(), os.getegid(), 0o400, False,
                        _stat_values(target_state), *_acl_state(target, self.resolver), sys.platform), "E_STORE")
                    _require(_identity(target_state) == _identity(_metadata(target))
                             == _identity(_named_metadata(name, directory)), "E_STORE")
                except BaseException as error:
                    file_failure = error
                    raise
                finally:
                    _close_capture_copy(target, work, work, "qualified-runtime/" + name, file_failure)
                source.recheck("E_STORE")
                manifest.append({"slot": role, "index": index, "locator": source.path,
                    "size_bytes": total, "sha256": measured.hexdigest()})
            os.fsync(directory)
            os.fsync(parent.fd)
            final_directory = _metadata(directory)
            _require((directory_state.st_dev, directory_state.st_ino, directory_state.st_uid,
                      directory_state.st_gid, directory_state.st_mode) ==
                     (final_directory.st_dev, final_directory.st_ino, final_directory.st_uid,
                      final_directory.st_gid, final_directory.st_mode)
                     and _identity(final_directory) == _identity(_named_metadata("qualified-runtime", parent.fd)), "E_STORE")
            parent.recheck("E_STORE")
            return manifest
        except BaseException as error:
            directory_failure = error
            if isinstance(error, MemoryError):
                work["runtime_accounting_incomplete"] = True
            raise
        finally:
            _close_capture_copy(directory, work, work, "qualified-runtime", directory_failure)

    def retain_storage(self, attempt_id, rows, failure, held=()):
        count = len(rows) + sum(len(item.components) for item in held)
        if self.storage_entry_count + count > 65536:
            self.private_observations["unusable"] = True
            return
        self.storage_entry_count += count
        error = None
        if failure is not None:
            self.private_observations["unusable"] = True
            error = {"category": type(failure).__name__,
                     "errno": getattr(failure, "os_errno", getattr(failure, "errno", None)),
                     "code": getattr(failure, "code", None)}
        acquired = []
        for item in held:
            components = []
            for component in item.components:
                row = {"name": None if component.name is None else os.fsencode(component.name).hex(),
                       "before": _stat_values(component.before),
                       "after": None if component.after is None else _stat_values(component.after),
                       "named_after": None if component.named_after is None else _stat_values(component.named_after)}
                observed_acl = getattr(component.rule, "observations", {}).get(component.fd)
                if observed_acl is not None:
                    row.update(access_acl=observed_acl[0], default_acl=observed_acl[1])
                components.append(row)
            acquired.append({"path": os.fsencode(item.path).hex(), "components": components})
        self.private_observations.setdefault("storage_reads", []).append(
            {"attempt_id": attempt_id, "entries": rows, "held": acquired, "error": error})

    def retain_entropy(self, role, value):
        _require(role in {"reproduction", "write", "kill", "coverage"}
                 and type(value) is bytes and len(value) == 32, "E_RUNTIME")
        values = self.private_observations.setdefault("entropy", {}).setdefault(role, [])
        if len(values) >= 4096:
            self.private_observations["unusable"] = True
        else:
            values.append(value.hex())

    def recheck(self, code: str = "E_INSTALL") -> None:
        for item in self.held:
            item.recheck(code)
    def seal_recheck(self, code: str = "E_INSTALL") -> None:
        for item in self.held:
            item.seal_recheck(code)
    def close(self) -> None:
        failure = None
        for item in reversed(self.held):
            try:
                item.close()
            except OSError as exc:
                if failure is None:
                    failure = exc
        if failure is not None:
            raise failure

def _principal_identity_values(principal_uid, real_uid, effective_uid):
    return principal_uid > 0 and principal_uid not in (real_uid, effective_uid)


def _group_context_values(gid, primary_groups, groups):
    return gid in primary_groups or groups is not None and gid in groups


def _anchor_identity_context(uid, gid, resolver, group_reader):
    _require(uid > 0, "E_CONFIG")
    real_uid, effective_uid = os.getuid(), os.geteuid()
    _require(_principal_identity_values(uid, real_uid, effective_uid), "E_CONFIG")
    primary_groups = (os.getgid(), os.getegid())
    groups = None
    member = _group_context_values(gid, primary_groups, groups)
    if not member:
        if group_reader is not None:
            member = group_reader.contains(gid)
        else:
            groups = os.getgroups()
            member = _group_context_values(gid, primary_groups, groups)
    _require(member, "E_CONFIG")
    return {"uid": real_uid, "euid": effective_uid, "gid": primary_groups[0], "egid": primary_groups[1],
        "groups": groups, "platform": sys.platform,
        "uuid_replies": resolver.raw_uuid_replies() if resolver is not None else None,
        "group_replies": group_reader.raw_group_replies() if group_reader is not None else None}


def _identity_context_values(context, principal_uid, consumer_gid):
    _require(type(context) is dict and set(context) == {"uid", "euid", "gid", "egid", "groups",
        "platform", "uuid_replies", "group_replies"} and type(context["platform"]) is str
             and context["platform"] in {"darwin", "linux"}, "E_CONFIG")
    _require(all(type(context[key]) is int and 0 <= context[key] <= 0xffffffff
                 for key in ("uid", "euid", "gid", "egid")), "E_CONFIG")
    _require(type(principal_uid) is int and type(consumer_gid) is int
             and _principal_identity_values(principal_uid, context["uid"], context["euid"]), "E_CONFIG")
    groups = context["groups"]
    _require(groups is None or type(groups) is list and len(groups) <= DOCUMENT_LIMIT
             and all(type(value) is int and 0 <= value <= 0xffffffff for value in groups), "E_CONFIG")
    primary = (context["gid"], context["egid"])
    member = _group_context_values(consumer_gid, primary, groups)
    group_replies = context["group_replies"]
    if not member and groups is None:
        _require(context["platform"] == "darwin" and type(group_replies) is list
                 and len(group_replies) == 1 and type(group_replies[0]) is dict
                 and set(group_replies[0]) == {"gid", "bytes"}
                 and group_replies[0]["gid"] == consumer_gid, "E_CONFIG")
        raw = group_replies[0]["bytes"]
        _require(type(raw) is str and len(raw) <= 32 and len(raw) % 2 == 0
                 and all(char in "0123456789abcdef" for char in raw), "E_CONFIG")
        member = _group_reply_values(consumer_gid, bytes.fromhex(raw))
    else:
        _require(group_replies in (None, []), "E_CONFIG")
    _require(member, "E_CONFIG")
    replies = context["uuid_replies"]
    _require(replies is None or context["platform"] == "darwin" and type(replies) is list
             and len(replies) <= 4096, "E_CONFIG")
    for row in replies or []:
        _require(type(row) is dict and set(row) == {"uuids", "bytes"}
                 and type(row["uuids"]) is list and bool(row["uuids"])
                 and type(row["bytes"]) is str and len(row["bytes"]) <= 2 * DARWIN_UUID_OUTPUT_LIMIT
                 and len(row["bytes"]) % 2 == 0
                 and all(char in "0123456789abcdef" for char in row["bytes"]), "E_CONFIG")
        _uuid_reply_values(row["uuids"], bytes.fromhex(row["bytes"]))
    return context


def load_anchor(resolver: _DarwinUUIDResolver | None = None,
                group_reader: _DarwinGroupReader | None = None) -> Anchor:
    held: list[HeldPath] = []
    try:
        if sys.platform == "darwin":
            _require(isinstance(resolver, _DarwinUUIDResolver), "E_INSTALL")
            _require(isinstance(group_reader, _DarwinGroupReader), "E_INSTALL")
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
        identity_context = _anchor_identity_context(uid, gid, resolver, group_reader)
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
        result.identity_context = identity_context
        result.recheck()
        return result
    except BaseException as exc:
        try:
            _close_paths(held)
        except OSError as close_exc:
            raise exc from close_exc
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

def _observation(item: HeldPath, relative: str, raw: bytes | None = None, *, storage_rows=None) -> dict:
    after = _capture_metadata(item.fd, item.recording_work, item.accounting_kind)
    if storage_rows is not None:
        component = item.components[-1]
        acl = getattr(component.rule, "observations", {}).get(item.fd)
        _require(component.named_after is not None and acl is not None, "E_STORE")
        storage_rows.append({"role": "store", "name": os.fsencode(relative).hex(),
            "before": _stat_values(item.before), "after": _stat_values(after),
            "named_after": _stat_values(component.named_after),
            "access_acl": acl[0], "default_acl": acl[1],
            "directory_names": item.directory_names, "read_error": None})
        if item.recording_work is not None:
            _capture_observe(item.recording_work, item.accounting_kind, "storage-row", storage_rows[-1])
    acquired = isinstance(raw, (_ExportSnapshot, _RuntimeSnapshot))
    if acquired:
        _require(raw.owner is item and len(raw) == item.before.st_size, "E_STORE")
    return _observation_values(relative, _stat_values(item.before), _stat_values(after), raw,
                               acquisition=acquired)


def _observation_values(relative, before, after, raw=None, *, acquisition=False):
    row = {"name": relative, "device": before["dev"], "inode": before["ino"],
           "mode": stat.S_IMODE(before["mode"]), "uid": before["uid"], "gid": before["gid"],
           "kind": "directory" if stat.S_ISDIR(before["mode"]) else "file",
           "metadata_before": list(_identity_values(before)),
           "metadata_after": list(_identity_values(after))}
    if raw is not None:
        row.update({"size": len(raw), "sha256": raw.acquisition_sha if acquisition else digest(raw)})
    return row


def _origin_values(files, storage_rows, identity_context, source_bytes, *,
                   capture_files=None, capture_storage_rows=None):
    _require(type(identity_context) is dict and set(identity_context) == {"attempt_id", "platform"}
             and type(identity_context["platform"]) is str
             and identity_context["platform"] in {"linux", "darwin"}, "E_STORE")
    def name_value(value):
        _require(type(value) is str and len(value) % 2 == 0
                 and all(char in "0123456789abcdef" for char in value), "E_STORE")
        return bytes.fromhex(value).decode("utf-8", "surrogateescape")
    if type(files.get("sandbox-export.bin")) is tuple:
        files = dict(files)
        files["sandbox-export.bin"] = _ExportSnapshot(files["sandbox-export.bin"], None, None)
    config = _parse_config(source_bytes["host-config.json"])
    attempt_id, platform = identity_context["attempt_id"], identity_context["platform"]
    source_payload = "payload/request.json" in files
    capture_directory = ".capture-" + attempt_id
    if capture_files is not None:
        _require(type(capture_files) is dict and {"capture.json", "complete.json"} <= set(capture_files)
                 and type(capture_storage_rows) is list, "E_STORE")
        capture_document = _json(capture_files["capture.json"], DOCUMENT_LIMIT, "E_STORE")
        _require(type(capture_document.get("body")) is dict
                 and type(capture_document["body"].get("raw")) is dict, "E_STORE")
        runtime_files = _capture_runtime_files(capture_document["body"]["raw"])
        _require(set(capture_files) in ({"capture.json", "complete.json"} | set(runtime_files),
            {"capture.json", "complete.json", "sandbox-export.bin"} | set(runtime_files)), "E_STORE")
        if type(capture_files.get("sandbox-export.bin")) is tuple:
            capture_files = dict(capture_files)
            capture_files["sandbox-export.bin"] = _ExportSnapshot(capture_files["sandbox-export.bin"], None, None)
        files = dict(files) | {capture_directory + "/" + name: raw for name, raw in capture_files.items()}
        storage_rows = storage_rows + capture_storage_rows
    else:
        _require(capture_storage_rows is None, "E_STORE")
    _require(type(storage_rows) is list and len(storage_rows) <= 65536 and _id(attempt_id), "E_STORE")
    observations, names = [], set()
    for row in storage_rows:
        _require(type(row) is dict and set(row) == {"role", "name", "before", "after", "named_after",
            "access_acl", "default_acl", "directory_names", "read_error"}
            and row["role"] == "store" and row["read_error"] is None, "E_STORE")
        name = name_value(row["name"])
        _require(name not in names, "E_STORE"); names.add(name)
        before = row["before"]
        _require(_identity_values(before) == _identity_values(row["after"])
                 == _identity_values(row["named_after"]), "E_STORE")
        file = name in files
        _require(_store_values(config["principal_uid"], config["consumer_gid"], 0o440 if file else 0o750,
            not file, before, row["access_acl"], row["default_acl"], platform), "E_STORE")
        if file:
            _require(before["nlink"] == 1 and before["size"] == len(files[name]), "E_STORE")
        listed = row["directory_names"]
        if listed is not None:
            _require(type(listed) is list and len(listed) <= 65536, "E_STORE")
            listed_names = {name_value(value) for value in listed}
            _require(len(listed) == len(listed_names), "E_STORE")
            if name == attempt_id:
                _require(listed_names == _attempt_names(files), "E_STORE")
            elif capture_files is not None and name == capture_directory:
                _require(listed_names == set(capture_files), "E_STORE")
            elif name == "payload":
                _require(listed_names == {key.split("/")[1] for key in files if key.startswith("payload/")}, "E_STORE")
            elif name == "payload/evidence":
                _require(listed_names == {key.split("/")[2] for key in files if key.startswith("payload/evidence/")}, "E_STORE")
            elif source_payload and name == "payload/raw":
                _require(listed_names == {key.split("/")[2] for key in files if key.startswith("payload/raw/")}, "E_STORE")
            elif name == ".":
                _require(attempt_id in listed_names, "E_STORE")
        observations.append(_observation_values(name, before, row["after"], files[name] if file else None))
    directories = {".", attempt_id, "payload"} | ({"payload/raw"} if source_payload else
        {"payload/evidence"} if any(name.startswith("payload/evidence/") for name in files) else set())
    if capture_files is not None:
        directories.add(capture_directory)
    _require(names == set(files) | directories, "E_STORE")
    return canonical({"schema_version": 1, "kind": "shadow_origin_observation", "id": attempt_id,
        "body": {"store_id": config["store_id"], "attempt_id": attempt_id,
                 "entries": observations, "result": "authenticated"}})

def _hex_name(value: object) -> bool:
    return (isinstance(value, str) and bool(value) and len(value) % 2 == 0
            and len(value) <= 510 and all(char in "0123456789abcdef" for char in value))

def _attempt_names(snapshots):
    return {"receipt.json", "payload"}


def _capture_export_reference(groups, *, final=False):
    host = groups.get("host", {})
    _require(type(host) is dict, "E_STORE")
    rows = host.get("process", [])
    _require(type(rows) is list and len(rows) <= 4096, "E_STORE")
    reference, reached = None, False
    for row in rows:
        _require(type(row) is dict, "E_STORE")
        value = row.get("bytes")
        if row.get("site") != "run_vm.export-read":
            _require(type(value) is not dict, "E_STORE")
            continue
        _require(set(row) == {"site", "ordinal", "return", "errno", "bytes", "timeout"}
                 and type(row["ordinal"]) is int and row["ordinal"] == 0
                 and row["timeout"] is None and not reached, "E_STORE")
        reached = True
        if value is None:
            _require(row["return"] is None and type(row["errno"]) is int
                     and row["errno"] > 0, "E_STORE")
            continue
        keys = {"role", "size_bytes", "sha256"} | ({"launch"} if final else set())
        _require(type(value) is dict and set(value) == keys
                 and value["role"] == ("sandbox-export-bytes" if final else "sandbox-export-capture-bytes")
                 and (not final or type(value["launch"]) is str and value["launch"] in {"reproduction", "write"})
                 and type(value["size_bytes"]) is int and 0 <= value["size_bytes"] <= EXPORT_LIMIT
                 and _sha(value["sha256"]) and row["errno"] is None
                 and type(row["return"]) is int and row["return"] == value["size_bytes"], "E_STORE")
        reference = value
    return reference


def _capture_export_binding(groups, snapshots, *, launch=None, source=False, final=False):
    _require(final or launch is None, "E_STORE")
    reference = _capture_export_reference(groups, final=final)
    present = "sandbox-export.bin" in snapshots
    _require(present == (reference is not None) and (not source or not present), "E_STORE")
    if reference is not None:
        raw = snapshots["sandbox-export.bin"]
        measured = raw.acquisition_sha if isinstance(raw, _ExportSnapshot) else digest(raw)
        _require(len(raw) == reference["size_bytes"] and measured == reference["sha256"]
                 and (launch is None or reference["launch"] == launch), "E_STORE")
    return reference


def _capture_envelope(raw, attempt_id, request_sha256, *, seed=False):
    value = _json(raw, CAPTURE_LIMIT, "E_STORE")
    _require(set(value) == {"schema_version", "kind", "id", "body"}
             and type(value["schema_version"]) is int and value["schema_version"] == 1
             and value["kind"] == "malicious_source_capture" and value["id"] == attempt_id
             and type(value["body"]) is dict, "E_STORE")
    body = value["body"]
    _require(set(body) == {"request_sha256", "raw", "complete"}
             and body["request_sha256"] == request_sha256 and _sha(request_sha256)
             and type(body["complete"]) is bool and type(body["raw"]) is dict
             and set(body["raw"]) <= {"host", "guest", "source_pages", "clocks", "runtime"}
             and all(type(group) is dict for group in body["raw"].values())
             and canonical(value) == raw, "E_STORE")
    if seed:
        _require(body["complete"] and bool(body["raw"]), "E_STORE")
    groups = body["raw"]
    _capture_export_reference(groups)
    remaining = {name: group for name, group in groups.items() if name not in {"host", "guest"}}
    _require(len(canonical(remaining)) <= 4 * DOCUMENT_LIMIT
             and all(len(canonical(groups[name])) <= 4 * DOCUMENT_LIMIT
                     for name in ("host", "guest") if name in groups), "E_STORE")
    return body["raw"]


def _capture_for_replay(snapshots, attempt_id, request_raw):
    _require("capture.json" in snapshots, "E_STORE")
    groups = _capture_envelope(snapshots["capture.json"], attempt_id, digest(request_raw), seed=True)
    _capture_export_binding(groups, snapshots)
    runtime = _capture_runtime_files(groups)
    _require(set(snapshots) == {"capture.json", "complete.json"} | set(runtime)
             | ({"sandbox-export.bin"} if _capture_export_reference(groups) is not None else set()), "E_STORE")
    for name, row in runtime.items():
        raw = snapshots[name]
        measured = raw.acquisition_sha if isinstance(raw, _RuntimeSnapshot) else digest(raw)
        _require(len(raw) == row["size_bytes"] and measured == row["sha256"], "E_STORE")
    return groups


def _launch_capture_values(capture_raw, outer_raw, launch_raw, expectation_raw, receipt_raw, kind):
    _require(kind in {"shadow_enforced_request", "shadow_write_request"}, "E_STORE")
    outer = _json(outer_raw, DOCUMENT_LIMIT, "E_STORE")
    launch = _json(launch_raw, DOCUMENT_LIMIT, "E_STORE")
    expectation = _json(expectation_raw, DOCUMENT_LIMIT, "E_STORE")
    receipt = _json(receipt_raw, DOCUMENT_LIMIT, "E_STORE")
    for value, expected_kind in ((outer, kind), (launch, "sandbox_launch_request"),
                                  (expectation, "sandbox_receipt_expectation"),
                                  (receipt, "sandbox_enforcement_receipt")):
        _require(set(value) == {"schema_version", "kind", "id", "body"}
                 and type(value["schema_version"]) is int and value["schema_version"] == 1
                 and value["kind"] == expected_kind and type(value["body"]) is dict, "E_STORE")
    attempt_id = outer["body"].get("attempt_id")
    _require(_id(attempt_id) and outer["id"] == attempt_id and launch["id"] == attempt_id
             and expectation["id"] == attempt_id, "E_STORE")
    attempt = {"attempt_id": attempt_id, "attempt_number": 1}
    bound = attempt | {"launch_request_sha256": digest(launch_raw)}
    _require(launch["body"].get("attempt") == attempt
             and receipt["body"].get("attempt") == bound
             and expectation["body"].get("attempt") == bound
             and receipt["id"] == "receipt." + bound["launch_request_sha256"], "E_STORE")
    for key in ("control", "subject"):
        _require(key in launch["body"] and launch["body"][key] == expectation["body"].get(key)
                 == receipt["body"].get(key), "E_STORE")
    _require(type(receipt["body"].get("origin")) is dict
             and launch["body"].get("store_id") == expectation["body"].get("store_id")
             == receipt["body"]["origin"].get("store_id"), "E_STORE")
    groups = _capture_envelope(capture_raw, attempt_id, bound["launch_request_sha256"], seed=True)
    rebuilt = _capture_envelope_values(attempt_id, launch_raw, groups)
    _require(rebuilt == capture_raw, "E_STORE")
    reference = _capture_export_reference(groups)
    if reference is None:
        return groups
    final_reference = reference | {"role": "sandbox-export-bytes",
        "launch": "reproduction" if kind == "shadow_enforced_request" else "write"}
    projected = groups | {"host": groups["host"] | {"process": [
        row | {"bytes": final_reference} if row["site"] == "run_vm.export-read" else row
        for row in groups["host"]["process"]]}}
    _capture_export_reference(projected, final=True)
    return projected


def _capture_envelope_values(attempt_id, launch_raw, groups):
    return canonical({"schema_version": 1, "kind": "malicious_source_capture", "id": attempt_id,
        "body": {"request_sha256": digest(launch_raw), "raw": groups, "complete": True}})


def _capture_work_values(work, case_key):
    fields = ("files","read_bytes","write_bytes","physical_bytes","export_read_bytes",
              "export_write_bytes","export_physical_bytes","export_files")
    for key in fields:work.setdefault(key,0)
    work.setdefault("calls",{})
    return work.setdefault("cases",{}).setdefault(case_key,{key:0 for key in fields})


def _capture_copy_room(work, amount, exported, *, case=False, read_only=False):
    fields = ("read_bytes", "write_bytes", "physical_bytes",
              "export_read_bytes", "export_write_bytes", "export_physical_bytes")
    _require(all(type(work[key]) is int and work[key] >= 0 for key in fields), "E_LIMIT")
    limits = (512, 256, 256, 384, 192, 192) if case else (2048, 1024, 1024, 1536, 768, 768)
    _require(all(work[key] + (amount if (index < 3 or exported) and (not read_only or index in (0,3)) else 0)
                 <= limit * DOCUMENT_LIMIT for index, (key, limit) in enumerate(zip(fields, limits))), "E_LIMIT")
    nonexport = (128, 64, 64) if case else (512, 256, 256)
    _require(all(0 <= work[key] - work["export_" + key]
                 and work[key] - work["export_" + key] + (amount if not exported and (not read_only or index == 0) else 0)
                 <= limit * DOCUMENT_LIMIT for index,(key, limit) in enumerate(zip(fields[:3], nonexport))), "E_LIMIT")


def _capture_rule(rule, fd, state, ancestor, work, kind):
    if work is None:
        return rule(fd, state, ancestor)
    previous = getattr(rule, "observations", {}).get(fd)
    accepted = rule(fd, state, ancestor)
    current = getattr(rule, "observations", {}).get(fd)
    if current is not None and current is not previous:
        _capture_observe(work, kind, "acl", {"access": current[0], "default": current[1]})
    elif not accepted:
        work["accounting_incomplete"] = True
    return accepted


def _capture_observe(work, kind, site, value, case_work=None):
    if work is None:
        return
    kind = kind or "unresolved"
    work["observation_calls"] = work.get("observation_calls", 0) + 1
    row = {"owner": work.get("accounting_owner", "recorder"), "ordinal": work["observation_calls"],
           "kind": kind, "site": site, "value": value}
    before = work["read_bytes"]
    try:
        case_work = work if case_work is None else case_work
        encoded = _private_capture_observations(row, work, case_work)
        _capture_account(work, kind, "read_bytes", work["read_bytes"] - before)
        _capture_account(work, kind, "logical_bytes", len(encoded))
        _capture_account(work, kind, "occurrences", 1)
        work.setdefault("accounting_rows", []).append(row)
        if case_work is not work:
            case_work["observation_calls"] = case_work.get("observation_calls", 0) + 1
            _capture_account(case_work, kind, "read_bytes", work["read_bytes"] - before)
            _capture_account(case_work, kind, "logical_bytes", len(encoded))
            _capture_account(case_work, kind, "occurrences", 1)
            case_work.setdefault("accounting_rows", []).append(row)
        if kind == "unresolved":
            work["M_classification_incomplete"] = True
            case_work["M_classification_incomplete"] = True
    except BaseException:
        for counter in (work, case_work):
            if counter is not None:
                try:counter["accounting_incomplete"] = True
                except MemoryError:pass
        raise


def _capture_observation_error(work, kind, site, error):
    if work is None:
        return
    try:
        work.setdefault("metadata_failure", {"site": site, "errno": getattr(error, "errno", None),
            "category": type(error).__name__})
        _capture_observe(work, kind, site, {"return": -1, "errno": getattr(error, "errno", None),
            "category": type(error).__name__})
    except (OSError, ValueError, TypeError, Refusal, MemoryError) as observed:
        try:work["accounting_incomplete"] = True
        except MemoryError:pass
        if getattr(observed, "_scope_signal_cancel", False) and not getattr(error, "_scope_signal_cancel", False):
            raise


def _capture_metadata(fd, work, kind):
    try:
        value = _metadata(fd)
    except (OSError, ValueError) as error:
        _capture_observation_error(work, kind, "fstat-error", error)
        raise
    if work is not None:_capture_observe(work, kind, "fstat", {"fd": fd, "stat": _stat_values(value)})
    return value


def _capture_named_metadata(name, parent_fd, work, kind):
    try:
        value = _named_metadata(name, parent_fd)
    except (OSError, ValueError) as error:
        _capture_observation_error(work, kind, "stat-nofollow-error", error)
        raise
    if work is not None:_capture_observe(work, kind, "stat-nofollow", {"parent_fd": parent_fd, "name": os.fsencode(name).hex(), "stat": _stat_values(value)})
    return value


def _capture_accounting_receipt(anchor):
    work = anchor.recording_work
    receipt = anchor.private_observations.setdefault("accounting", {})
    receipt["transferred_totals"] = {field: work.get(field, 0) for field in
        ("read_bytes", "write_bytes", "physical_bytes", "files", "export_read_bytes",
         "export_write_bytes", "export_physical_bytes", "export_files", "close_calls", "held_close_calls", "observation_calls")}
    receipt["classes"] = work.get("accounting", {})
    classified = sum(values.get("read_bytes", 0) for values in receipt["classes"].values())
    receipt["unclassified_recorded_read_bytes"] = receipt["transferred_totals"]["read_bytes"] - receipt["transferred_totals"]["export_read_bytes"] - classified
    receipt["cases"] = work.get("cases", {})
    receipt["observations"] = work.get("accounting_rows", [])
    receipt["failures"] = work.get("leaf_failures", [])
    receipt["incomplete"] = {key: value for key, value in work.items()
        if (key.endswith("incomplete") or key in {"transfer_incomplete", "M_classification_incomplete"}) and value}
    receipt["runtime"] = work.get("runtime", {})
    receipt["runtime_Q"] = "UNKNOWN: complete original native operation counts are not available"
    receipt["host_publication_work"] = "UNKNOWN: private host work is not transported by the existing capture envelope"
    receipt["complete"] = False
    return receipt


def _capture_account(work, kind, field, amount):
    _require(kind in {"L", "W", "M", "raw", "unresolved"}
             and field in {"logical_bytes", "read_bytes", "write_bytes", "physical_bytes", "files", "occurrences"}
             and type(amount) is int and amount >= 0, "E_LIMIT")
    categories = work.setdefault("accounting", {})
    values = categories.setdefault(kind, {})
    values[field] = values.get(field, 0) + amount
    if kind == "unresolved":work["M_classification_incomplete"] = True


def _capture_transfer_work(source, work, case_work):
    _require(not source.get("transfer_incomplete", False), "E_LIMIT")
    target = source.get("transfer_target")
    _require(target is None or target == id(work), "E_LIMIT")
    fields = ("read_bytes", "write_bytes", "physical_bytes", "files", "export_read_bytes",
              "export_write_bytes", "export_physical_bytes", "export_files", "close_calls", "held_close_calls", "observation_calls")
    deltas = {}
    for field in fields:
        current, transferred = source.get(field, 0), source.get("transferred_" + field, 0)
        _require(type(current) is int and type(transferred) is int and current >= transferred >= 0, "E_LIMIT")
        deltas[field] = current - transferred
    runtime_deltas = {}
    for field, amount in source.get("runtime", {}).items():
        _require(field in _RUNTIME_FIELDS and type(amount) is int and amount >= 0, "E_LIMIT")
        prior = source.get("transferred_runtime", {}).get(field, 0)
        _require(type(prior) is int and 0 <= prior <= amount, "E_LIMIT")
        runtime_deltas[field] = amount - prior
    for counter, window in ((work, True), (case_work, False)):
        for field, amount in runtime_deltas.items():
            _require(counter.get("runtime", {}).get(field, 0) + amount
                     <= _RUNTIME_FIELDS[field] * (4 if window else 1), "E_LIMIT")
    category_deltas = []
    for kind, values in source.get("accounting", {}).items():
        previous = source.get("transferred_accounting", {}).get(kind, {})
        for field, amount in values.items():
            prior = previous.get(field, 0)
            _require(type(amount) is int and type(prior) is int and amount >= prior >= 0, "E_LIMIT")
            category_deltas.append((kind, field, amount - prior))
    for counter, per_case in ((work, False), (case_work, True)):
        candidate = dict(counter)
        for field, delta in deltas.items():candidate[field] = candidate.get(field, 0) + delta
        _capture_copy_room(candidate, 0, False, case=per_case)
        _require(candidate.get("files", 0) <= 256
                 and candidate.get("export_files", 0) <= (16 if per_case else 64), "E_LIMIT")
    try:
        source["transfer_target"] = id(work)
        for field, delta in deltas.items():
            if delta:
                work[field] = work.get(field, 0) + delta
                case_work[field] = case_work.get(field, 0) + delta
            source["transferred_" + field] = source.get(field, 0)
        for field, delta in runtime_deltas.items():
            if delta:
                _runtime_account(work, field, delta, window=True)
                _runtime_account(case_work, field, delta)
            source.setdefault("transferred_runtime", {})[field] = source["runtime"][field]
        for kind, field, delta in category_deltas:
            if delta:
                _capture_account(work, kind, field, delta)
                _capture_account(case_work, kind, field, delta)
            source.setdefault("transferred_accounting", {}).setdefault(kind, {})[field] = source["accounting"][kind][field]
        for flag in [key for key in source if key.endswith("incomplete") or key == "M_classification_incomplete"]:
            if source.get(flag, False):
                work[flag] = True
                case_work[flag] = True
        for name in ("failure", "metadata_failure", "read_error", "copy_failure", "cleanup_errno"):
            if name in source and source.get("transferred_failures", {}).get(name) is not source[name]:
                row = {"field": name, "value": source[name]}
                work.setdefault("leaf_failures", []).append(row)
                case_work.setdefault("leaf_failures", []).append(row)
                source.setdefault("transferred_failures", {})[name] = source[name]
        for name in ("close_failures", "accounting_rows"):
            rows = source.get(name, [])
            start = source.get("transferred_" + name, 0)
            _require(type(start) is int and 0 <= start <= len(rows), "E_LIMIT")
            if len(rows) > start:
                work.setdefault(name, []).extend(rows[start:])
                case_work.setdefault(name, []).extend(rows[start:])
            source["transferred_" + name] = len(rows)
    except BaseException:
        for counter in (source, work, case_work):
            try:counter["transfer_incomplete"] = True
            except MemoryError:pass
        raise
    return deltas["read_bytes"]


def _close_capture_copy(fd, work, case_work, site, failure):
    close_error = None
    try:
        os.close(fd)
    except OSError as error:
        close_error = error
    try:
        for counts in ((work,) if case_work is work else (work, case_work)):
            counts["close_calls"] = counts.get("close_calls", 0) + 1
        if "read_bytes" in work:
            _capture_observe(work, "M", "close", {"site": site, "return": 0 if close_error is None else -1,
                "errno": None if close_error is None else close_error.errno}, case_work)
        if close_error is not None:
            rows = work.setdefault("close_failures", [])
            if len(rows) < 4096:
                rows.append({"site": site, "category": type(close_error).__name__, "errno": close_error.errno})
            else:
                work["close_observations_incomplete"] = True
    except (OSError, ValueError, TypeError, Refusal, MemoryError) as observed:
        try:
            work["close_observations_incomplete"] = True
        except MemoryError:
            pass
        if (getattr(observed, "_scope_signal_cancel", False)
                and not getattr(failure, "_scope_signal_cancel", False)
                and not getattr(close_error, "_scope_signal_cancel", False)):
            raise
        if failure is None and close_error is None:
            raise
    if close_error is not None and (failure is None or
            getattr(close_error, "_scope_signal_cancel", False) and not getattr(failure, "_scope_signal_cancel", False)):
        raise close_error


def _private_capture_observations(value, work, case_work):
    encoded = bytearray()
    reserved = 0
    encoder = json.JSONEncoder(ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)
    for piece in encoder.iterencode(value):
        _require(len(piece) <= DOCUMENT_LIMIT, "E_LIMIT")
        size = sum(1 if ord(char) < 128 else 2 if ord(char) < 2048 else
                   3 if ord(char) < 65536 else 4 for char in piece)
        _require(len(encoded) + size + 1 <= DOCUMENT_LIMIT, "E_LIMIT")
        for counter, limit, nonexport in ((work, 2048, 512), (case_work, 512, 128)):
            _require(counter["read_bytes"] + reserved + size * 3 + 1 <= limit * DOCUMENT_LIMIT
                     and counter["read_bytes"] - counter["export_read_bytes"] + reserved
                     + size * 3 + 1 <= nonexport * DOCUMENT_LIMIT, "E_LIMIT")
        raw = piece.encode("utf-8")
        encoded.extend(raw)
        for counts in ((work,) if work is case_work else (work, case_work)):
            counts["read_bytes"] += size
        reserved += size * 2
    result = bytes(encoded)
    for counts in ((work,) if work is case_work else (work, case_work)):
        counts["read_bytes"] += len(encoded)
    result += b"\n"
    for counts in ((work,) if work is case_work else (work, case_work)):
        counts["read_bytes"] += len(encoded) + 1
    work["calls"]["consumer-json-buffer"] = work["calls"].get("consumer-json-buffer", 0) + 1
    return result


class _HeldCaptureRead:
    def __init__(self, native, request_raw, *, source=False):
        self.native, self.anchor = native, native.anchor
        self.attempt_id, self.request_raw = native.attempt_id, request_raw
        self.held, self.snapshots, self.storage_rows = [], {}, []
        self.work, self.transferred = {}, 0
        _capture_work_values(self.work, self.attempt_id)
        self.work["accounting_owner"] = "capture:" + self.attempt_id
        native.capture_work = self.work
        self.directory_name = ".capture-" + self.attempt_id
        try:
            store = next(item for item in native.held if item.path == self.anchor.config["store_root"])
            uid, gid = self.anchor.config["principal_uid"], self.anchor.config["consumer_gid"]
            directory = _open_child(store, self.directory_name, True,
                _store_rule(uid, gid, 0o750, True, self.anchor.resolver), "E_STORE",
                recording_work=self.work, accounting_kind="M")
            self.held.append(directory)
            self.names = set(directory.listdir())
            _require({"capture.json", "complete.json"} <= self.names and len(self.names) <= 67
                and (not source or "sandbox-export.bin" not in self.names), "E_STORE")
            _require(all(name in {"capture.json", "complete.json", "sandbox-export.bin"}
                         or name.startswith("runtime-") and name.endswith(".bin") and "/" not in name
                         for name in self.names), "E_STORE")
            runtime_files = {}
            _observation(directory, self.directory_name, storage_rows=self.storage_rows)
            for name in sorted(self.names):
                item = _open_child(directory, name, False,
                    _store_rule(uid, gid, 0o440, False, self.anchor.resolver), "E_STORE",
                    recording_work=self.work, accounting_kind="M" if name == "complete.json" else "unresolved")
                self.held.append(item)
                runtime_file = name in runtime_files
                maximum = 4 << 30 if runtime_file else EXPORT_LIMIT if name == "sandbox-export.bin" else 512 if name == "complete.json" else DOCUMENT_LIMIT
                _require(item.before.st_size <= maximum, "E_STORE")
                self.work["input_kind"] = "W" if name == "complete.json" else "raw"
                raw = (_RuntimeSnapshot(item, self.work) if runtime_file else
                       _read_export_snapshot(item, "E_STORE") if name == "sandbox-export.bin" else
                       item.read(maximum, "E_STORE", self.work))
                self.snapshots[name] = raw
                if name == "capture.json":
                    groups = _capture_envelope(raw, self.attempt_id, digest(request_raw), seed=True)
                    runtime_files = _capture_runtime_files(groups)
                    _runtime_config_binding(runtime_files, self.anchor.config)
                    expected_names = {"capture.json", "complete.json"} | set(runtime_files)
                    if _capture_export_reference(groups) is not None:expected_names.add("sandbox-export.bin")
                    _require(self.names == expected_names, "E_STORE")
                if runtime_file:
                    _require(len(raw) == runtime_files[name]["size_bytes"]
                             and raw.acquisition_sha == runtime_files[name]["sha256"], "E_STORE")
                if name == "complete.json":_capture_account(self.work, "W", "logical_bytes", len(raw))
                elif name == "capture.json":_capture_account(self.work, "raw", "logical_bytes", len(raw))
                _observation(item, self.directory_name + "/" + name, raw, storage_rows=self.storage_rows)
                if not isinstance(raw, (_ExportSnapshot, _RuntimeSnapshot)):
                    self.work["read_bytes"] += len(raw)
                    _capture_account(self.work, "W" if name == "complete.json" else "raw", "read_bytes", len(raw))
            groups = _capture_envelope(self.snapshots["capture.json"], self.attempt_id,
                                       digest(request_raw), seed=True)
            _capture_export_binding(groups, self.snapshots, source=source)
            owner = getattr(self.anchor, "capture_completion_owner", None)
            _require(owner is not None, "E_STORE")
            self.completion_owner = owner
            expected = owner.construct(self.anchor, self.attempt_id, request_raw, self.snapshots["capture.json"])
            _capture_copy_room(self.work, 4 * len(self.snapshots["complete.json"]),
                               False, case=True, read_only=True)
            self.work["read_bytes"] += 4 * len(self.snapshots["complete.json"])
            _capture_account(self.work, "W", "read_bytes", 4 * len(self.snapshots["complete.json"]))
            _json(self.snapshots["complete.json"], 512, "E_STORE")
            _capture_copy_room(self.work, len(expected) + len(self.snapshots["complete.json"]),
                               False, case=True, read_only=True)
            self.work["read_bytes"] += len(expected) + len(self.snapshots["complete.json"])
            _capture_account(self.work, "W", "read_bytes", len(expected) + len(self.snapshots["complete.json"]))
            _require(expected == self.snapshots["complete.json"], "E_STORE")
            self.recheck(metadata_only=True)
        except BaseException as error:
            self.work["failure"] = {"category": type(error).__name__,
                "errno": getattr(error, "os_errno", getattr(error, "errno", None))}
            try:
                self.close()
            except OSError as cleanup_error:
                self.work["cleanup_errno"] = cleanup_error.errno
                if (getattr(cleanup_error, "_scope_signal_cancel", False)
                        and not getattr(error, "_scope_signal_cancel", False)):
                    raise
            raise

    def recheck(self, code="E_STORE", *, metadata_only=False):
        for item in self.held:
            item.recheck(code)
            if stat.S_ISDIR(item.before.st_mode):
                _require(set(item.listdir()) == self.names, code)
            elif not metadata_only:
                raw = self.snapshots[os.path.basename(item.path)]
                if isinstance(raw, (_ExportSnapshot, _RuntimeSnapshot)):
                    raw.recheck(item, code)
                else:
                    self.work["input_kind"] = "W" if os.path.basename(item.path) == "complete.json" else "raw"
                    current = item.read(len(raw), code, self.work)
                    _capture_copy_room(self.work, len(current) + len(raw), False, case=True, read_only=True)
                    self.work["read_bytes"] += len(current) + len(raw)
                    _capture_account(self.work, self.work["input_kind"], "read_bytes", len(current) + len(raw))
                    _require(current == raw, code)

    def transfer(self, work, case_work):
        self.transfer_target = (work, case_work)
        self.transferred += _capture_transfer_work(self.work, work, case_work)

    def close(self):
        held, self.held = self.held, []
        failure = None
        try:
            _close_paths(held)
        except BaseException as error:
            failure = error
            raise
        finally:
            cancellation = failure if getattr(failure, "_scope_signal_cancel", False) else None
            stage = "binding"
            try:
                target = getattr(self, "transfer_target", None)
                if target is None:
                    work = self.anchor.recording_work
                    case_work = _capture_work_values(work, "unassigned:" + self.attempt_id)
                    work["accounting_incomplete"] = True
                else:
                    work, case_work = target
                stage = "transfer"
                self.transferred += _capture_transfer_work(self.work, work, case_work)
                stage = "receipt"
                _capture_accounting_receipt(self.anchor)
            except Exception as error:
                if getattr(error, "_scope_signal_cancel", False) and cancellation is None:
                    cancellation = error
                try:
                    self.anchor.private_observations["unusable"] = True
                    self.work["close_tail_incomplete"] = True
                    self.work.setdefault("close_tail_failure", {"stage": stage, "category": type(error).__name__,
                        "errno": getattr(error, "errno", None), "marked_cancel": bool(getattr(error, "_scope_signal_cancel", False)),
                        "primary_category": None if failure is None else type(failure).__name__,
                        "primary_errno": getattr(failure, "errno", None)})
                except Exception as observed:
                    if getattr(observed, "_scope_signal_cancel", False) and cancellation is None:
                        cancellation = observed
                if cancellation is not None and cancellation is not failure:
                    raise cancellation


class _HeldStoreRead:
    def __init__(self, anchor: Anchor, attempt_id: str) -> None:
        self.anchor, self.attempt_id = anchor, attempt_id
        self.held: list[HeldPath] = []
        self.snapshots, self.observation = read_store_attempt(anchor, attempt_id, _owner=self)

    def record_reproduction(self, outer_raw, launch_raw, expectation_raw):
        return self._record_launch(outer_raw, launch_raw, expectation_raw, "shadow_enforced_request")

    def record_write(self, outer_raw, launch_raw, expectation_raw):
        return self._record_launch(outer_raw, launch_raw, expectation_raw, "shadow_write_request")

    def _record_launch(self, outer_raw, launch_raw, expectation_raw, kind):
        try:
            if not hasattr(self, "capture"):
                self.capture = _HeldCaptureRead(self, launch_raw)
            else:
                _require(self.capture.request_raw == launch_raw and bool(self.capture.held), "E_STORE")
                self.capture.recheck(metadata_only=True)
            groups = _launch_capture_values(self.capture.snapshots["capture.json"], outer_raw,
                launch_raw, expectation_raw, self.snapshots["receipt.json"], kind)
            self.launch_binding = {"outer": _json(outer_raw, DOCUMENT_LIMIT, "E_STORE"),
                "launch": _json(launch_raw, DOCUMENT_LIMIT, "E_STORE"),
                "expectation": _json(expectation_raw, DOCUMENT_LIMIT, "E_STORE"),
                "receipt": _json(self.snapshots["receipt.json"], DOCUMENT_LIMIT, "E_STORE")}
            self.projected_capture = groups
            if not hasattr(self, "capture_origin"):
                self.capture.work["origin_incomplete"] = True
                self.capture_origin = _origin_values(self.snapshots, self.storage_rows,
                    {"attempt_id": self.attempt_id, "platform": sys.platform},
                    {"host-config.json": self.anchor.config_raw}, capture_files=self.capture.snapshots,
                    capture_storage_rows=self.capture.storage_rows)
                for name, raw in self.capture.snapshots.items():
                    if name != "sandbox-export.bin" and not isinstance(raw, _RuntimeSnapshot):
                        self.capture.work["read_bytes"] += len(raw)
                        _capture_account(self.capture.work, "W" if name == "complete.json" else "raw", "read_bytes", len(raw))
                self.capture.work["origin_incomplete"] = False
            return groups
        except Exception as error:
            self.anchor.private_observations["unusable"] = True
            self.anchor.private_observations["capture_failure"] = {
                "category": type(error).__name__,
                "errno": getattr(error, "os_errno", getattr(error, "errno", None))}
            if hasattr(self, "capture"):
                try:
                    self.capture.close()
                except OSError as cleanup_error:
                    self.capture_work["cleanup_errno"] = cleanup_error.errno
                    if (getattr(cleanup_error, "_scope_signal_cancel", False)
                            and not getattr(error, "_scope_signal_cancel", False)):
                        raise
            if getattr(error, "_scope_signal_cancel", False):
                raise
            return None

    def recheck(self, code: str = "E_STALE") -> None:
        self.anchor.recheck(code)
        for item in self.held:
            item.recheck(code)
            relative = os.path.relpath(item.path, self.anchor.config["store_root"])
            if stat.S_ISREG(item.before.st_mode):
                name = relative[len(self.attempt_id) + 1:]
                _require(name in self.snapshots, code)
                if name == "sandbox-export.bin":
                    self.snapshots[name].recheck(item, code)
                else:
                    _require(item.read(len(self.snapshots[name]), code) == self.snapshots[name], code)
            else:
                names = set(item.listdir())
                if relative == ".":
                    _require(self.attempt_id in names, code)
                elif relative == self.attempt_id:
                    _require(names == _attempt_names(self.snapshots), code)
                elif relative == self.attempt_id + "/payload":
                    expected = {name.split("/")[1] for name in self.snapshots if name.startswith("payload/")}
                    _require(names == expected, code)
                elif relative == self.attempt_id + "/payload/evidence":
                    _require(names == {name.split("/")[2] for name in self.snapshots
                                       if name.startswith("payload/evidence/")}, code)
        if hasattr(self, "capture"):
            try:
                self.capture.recheck(code)
            except Exception as error:
                self.anchor.private_observations["unusable"] = True
                if getattr(error, "_scope_signal_cancel", False):
                    raise

    def close(self) -> None:
        held, self.held = self.held, []
        try:
            _close_paths(held)
        finally:
            if hasattr(self, "capture"):
                try:
                    self.capture.close()
                except OSError as error:
                    self.anchor.private_observations["unusable"] = True
                    if getattr(error, "_scope_signal_cancel", False):
                        raise

    def copy_capture(self, parent, request_raw, launch, work):
        _require(type(launch) is str and launch in {"reproduction", "write"}, "E_STORE")
        return self._copy_capture(parent, request_raw, launch, work)

    def _copy_capture(self, parent, request_raw, launch, work):
        _require(isinstance(parent, HeldPath) and len(parent.components) > 1
                 and bool(self.held) and type(work) is dict, "E_STORE")
        capture_snapshots = self.capture.snapshots
        _capture_for_replay(capture_snapshots, self.attempt_id, request_raw)
        _require(len(self.observation) <= DOCUMENT_LIMIT, "E_LIMIT")
        _require(type(self.anchor.identity_context) is dict
                 and not self.anchor.private_observations.get("unusable", False)
                 and _clock_complete
                 and getattr(self.anchor.resolver, "observations_complete", True), "E_STORE")
        parent.recheck("E_STORE")
        state = _metadata(parent.fd)
        _require(stat.S_ISDIR(state.st_mode) and state.st_uid == os.geteuid()
                 and stat.S_IMODE(state.st_mode) == 0o700, "E_STORE")
        access, default = _acl_state(parent.fd, self.anchor.resolver)
        _require(access == [] if sys.platform == "darwin" else access is None and default is None, "E_STORE")
        work.setdefault("files", 0)
        work.setdefault("read_bytes", 0)
        work.setdefault("write_bytes", 0)
        work.setdefault("physical_bytes", 0)
        work.setdefault("export_read_bytes", 0)
        work.setdefault("export_write_bytes", 0)
        work.setdefault("export_physical_bytes", 0)
        work.setdefault("export_files", 0)
        work.setdefault("calls", {})
        case_state = (parent.components[-2].before if isinstance(self, _HeldCoverageRead)
                      and parent.components[-1].name.startswith("gate-") else state)
        case_key = str(case_state.st_dev) + ":" + str(case_state.st_ino)
        case_work = work.setdefault("cases", {}).setdefault(case_key,
            {key: 0 for key in ("files", "read_bytes", "write_bytes", "physical_bytes",
                               "export_read_bytes", "export_write_bytes", "export_physical_bytes", "export_files")})
        _capture_copy_room(work, 0, False)
        _capture_copy_room(case_work, 0, False, case=True)
        completion_owner = getattr(self.anchor, "capture_completion_owner", None)
        _require(completion_owner is not None and completion_owner is self.capture.completion_owner
                 and self.capture.anchor is self.anchor, "E_STORE")
        completion_owner.transfer(work, case_work)
        self.capture.transfer(work, case_work)
        before_encoding = work["read_bytes"]
        consumer_raw = _private_capture_observations({"attempt_id": self.attempt_id,
            "request_sha256": digest(request_raw),
            "storage": self.storage_rows,
            "storage_reads": self.anchor.private_observations.get("storage_reads", []),
            "identity_context": self.anchor.identity_context,
            "commands": self.anchor.private_observations.get("commands",{}),
            "preparation": self.anchor.private_observations.get("preparation",{}),
            "entropy": self.anchor.private_observations.get("entropy", {}),
            "clocks": _clock_observations}, work, case_work)
        for counter in (work, case_work):
            _capture_account(counter, "unresolved", "read_bytes", work["read_bytes"] - before_encoding)
        binding_raw = None
        if "sandbox-export.bin" in capture_snapshots:
            _require(hasattr(self, "launch_binding") and hasattr(self, "projected_capture"), "E_STORE")
            expected_launch = ("reproduction" if self.launch_binding["outer"]["kind"]
                               == "shadow_enforced_request" else "write")
            _require(launch == expected_launch, "E_STORE")
            before_encoding = work["read_bytes"]
            binding_raw = _private_capture_observations(self.launch_binding |
                {"raw": self.projected_capture}, work, case_work)
            for counter in (work, case_work):
                _capture_account(counter, "unresolved", "read_bytes", work["read_bytes"] - before_encoding)
        os.mkdir(launch, 0o700, dir_fd=parent.fd)
        after_parent = _metadata(parent.fd)
        _require((after_parent.st_dev, after_parent.st_ino, after_parent.st_uid, after_parent.st_gid,
                  after_parent.st_mode) == (state.st_dev, state.st_ino, state.st_uid, state.st_gid, state.st_mode)
                 and _identity(after_parent) == _identity(_named_metadata(
                     parent.components[-1].name, parent.components[-2].fd)), "E_STORE")
        parent.components[-1].before = after_parent
        directory = os.open(launch, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent.fd)
        directory_failure = None
        try:
            directory_state = _metadata(directory)
            _require(stat.S_ISDIR(directory_state.st_mode) and directory_state.st_uid == os.geteuid()
                     and stat.S_IMODE(directory_state.st_mode) == 0o700, "E_STORE")
            def write(name, chunks, exported=False):
                _require(work["files"] < 256 and case_work["files"] < 256
                         and (not exported or work["export_files"] < 64 and case_work["export_files"] < 16), "E_LIMIT")
                target = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                 0o600, dir_fd=directory)
                size = 0
                file_failure = None
                try:
                    work["files"] += 1
                    case_work["files"] += 1
                    work["export_files"] += int(exported)
                    case_work["export_files"] += int(exported)
                    work["calls"][name] = work["calls"].get(name, 0) + 1
                    if not exported:
                        kind = "W" if name == "complete.json" else "raw" if name == "capture.json" else "unresolved"
                        _capture_account(work, kind, "files", 1)
                        _capture_account(case_work, kind, "files", 1)
                    for chunk in chunks:
                        view = memoryview(chunk)
                        while view:
                            bounded = view[:65536]
                            amount = len(bounded)
                            _capture_copy_room(work, amount, exported)
                            _capture_copy_room(case_work, amount, exported, case=True)
                            count = os.write(target, bounded)
                            _require(0 < count <= amount, "E_STORE")
                            size += count
                            for key in ("read_bytes", "write_bytes", "physical_bytes"):
                                work[key] += count
                                case_work[key] += count
                                if exported:
                                    work["export_" + key] += count
                                    case_work["export_" + key] += count
                            if not exported:
                                for counter in (work, case_work):
                                    for field in ("read_bytes", "write_bytes", "physical_bytes"):
                                        _capture_account(counter, kind, field, count)
                            view = view[count:]
                    os.fchmod(target, 0o400)
                    os.fsync(target)
                    final = _metadata(target)
                    named = _named_metadata(name, directory)
                    _require(stat.S_ISREG(final.st_mode) and final.st_uid == os.geteuid()
                             and final.st_nlink == 1 and final.st_size == size
                             and stat.S_IMODE(final.st_mode) == 0o400
                             and _identity(final) == _identity(named), "E_STORE")
                except BaseException as error:
                    file_failure = error
                    try:
                        work.setdefault("copy_failure", {"site": name, "category": type(error).__name__,
                            "errno": getattr(error, "os_errno", getattr(error, "errno", None))})
                        if isinstance(error, MemoryError):
                            work["copy_accounting_incomplete"] = True
                    except MemoryError:
                        raise error
                    raise
                finally:
                    _close_capture_copy(target, work, case_work, name, file_failure)
            write("capture.json", (capture_snapshots["capture.json"],))
            write("complete.json", (capture_snapshots["complete.json"],))
            for runtime_name in sorted(_capture_runtime_files(_capture_for_replay(
                    capture_snapshots, self.attempt_id, request_raw))):
                _copy_runtime_file(directory, runtime_name, capture_snapshots[runtime_name],
                                   self.capture.work, self.anchor.resolver)
            self.capture.transfer(work, case_work)
            if "sandbox-export.bin" in capture_snapshots:
                write("sandbox-export.bin", capture_snapshots["sandbox-export.bin"].chunks, True)
            write("origin-observation.json", (self.capture_origin,))
            write("consumer-observations.json", (consumer_raw,))
            if binding_raw is not None:
                write("launch-binding.json", (binding_raw,))
            os.fsync(directory)
            os.fsync(parent.fd)
            final_directory = _metadata(directory)
            named_directory = _named_metadata(launch, parent.fd)
            _require((final_directory.st_dev, final_directory.st_ino, final_directory.st_uid,
                      final_directory.st_mode) == (directory_state.st_dev, directory_state.st_ino,
                                                   directory_state.st_uid, directory_state.st_mode)
                     and _identity(final_directory) == _identity(named_directory), "E_STORE")
            parent.recheck("E_STORE")
        except BaseException as error:
            directory_failure = error
            try:
                work.setdefault("copy_failure", {"site": launch, "category": type(error).__name__,
                    "errno": getattr(error, "os_errno", getattr(error, "errno", None))})
                if isinstance(error, MemoryError):
                    work["copy_accounting_incomplete"] = True
            except MemoryError:
                raise error
            raise
        finally:
            _close_capture_copy(directory, work, case_work, launch, directory_failure)


def read_store_attempt(anchor: Anchor, attempt_id: str, *,
                       _owner: _HeldStoreRead | None = None) -> tuple[dict[str, bytes], bytes]:
    _require(_id(attempt_id) and (_owner is None or isinstance(_owner, _HeldStoreRead)), "E_STORE")
    anchor.recheck("E_STORE")
    uid, gid = anchor.config["principal_uid"], anchor.config["consumer_gid"]
    root = anchor.config["store_root"]
    opened: list[HeldPath] = []
    snapshots: dict[str, bytes] = {}
    observations: list[dict] = []
    storage_rows = []
    failure = None
    try:
        store = _open_held(root, True, _store_rule(uid, gid, 0o750, True, anchor.resolver), "E_STORE")
        opened.append(store)
        attempt = _open_child(store, attempt_id, True,
                              _store_rule(uid, gid, 0o750, True, anchor.resolver), "E_STORE")
        opened.append(attempt)
        payload = _open_child(attempt, "payload", True,
                              _store_rule(uid, gid, 0o750, True, anchor.resolver), "E_STORE")
        opened.append(payload)
        observations.extend((_observation(store, ".", storage_rows=storage_rows),
                             _observation(attempt, attempt_id, storage_rows=storage_rows),
                             _observation(payload, "payload", storage_rows=storage_rows)))
        attempt_names = set(attempt.listdir())
        _require(attempt_names == {"payload", "receipt.json"}, "E_STORE")
        payload_names = set(payload.listdir())
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
            opened.append(evidence); observations.append(_observation(evidence, "payload/evidence", storage_rows=storage_rows))
            _require(sorted(evidence.listdir()) == expected_evidence, "E_STORE")
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
            observations.append(_observation(item, name, raw, storage_rows=storage_rows))
            if output_name:
                remaining -= len(raw)
        for index, row in enumerate(rows):
            raw = snapshots[f"payload/evidence/{index:04d}"]
            _require(len(raw) == row["size_bytes"] and digest(raw) == row["sha256"], "E_STORE")
        _require(set(attempt.listdir()) == attempt_names
                 and set(payload.listdir()) == payload_names, "E_STORE")
        if rows:
            _require(sorted(evidence.listdir()) == expected_evidence, "E_STORE")
        for item in opened:
            item.recheck("E_STORE")
            relative = os.path.relpath(item.path, root)
            if relative.startswith(attempt_id + "/"):
                relative = relative[len(attempt_id) + 1:]
            for row in storage_rows:
                if row["name"] == os.fsencode(relative).hex():
                    row["directory_names"] = item.directory_names
        anchor.recheck("E_STORE")
        observation = _origin_values(snapshots, storage_rows,
            {"attempt_id": attempt_id, "platform": sys.platform}, {"host-config.json": anchor.config_raw})
        if _owner is not None:
            _owner.held, opened = opened, []
            _owner.storage_rows = storage_rows
        return snapshots, observation
    except BaseException as exc:
        failure = exc
        raise
    finally:
        if hasattr(anchor, "retain_storage"):
            try:
                anchor.retain_storage(attempt_id, storage_rows, failure,
                                      opened if opened else _owner.held if _owner is not None else ())
            except MemoryError:
                anchor.private_observations["unusable"] = True
        try:
            _close_paths(opened)
        except OSError:
            if failure is None:
                raise

class _CoverageConfiguration:
    def __init__(self, anchor, operation="coverage-read"):
        _require(operation in {"coverage-read", "kill-register-read"}, "E_CONFIG")
        self.operation = operation
        prefix = "coverage-source" if operation == "coverage-read" else "kill-register-source"
        import importlib.util
        self.anchor, self.held = anchor, []
        try:
            root = next(item for item in anchor.held if item.path == ANCHOR)
            rule = _root_rule(anchor.resolver)
            def child(name):
                item = _open_child(root, name, False, rule, "E_CONFIG")
                self.held.append(item)
                return item.read(DOCUMENT_LIMIT, "E_CONFIG")
            self.config_raw = child(prefix + "-config.json")
            self.accepted_raw = child(prefix + "-accepted-identities.json")
            normalizer = _open_child(root, "coverage-source.py", False, rule, "E_INSTALL")
            self.held.append(normalizer)
            normalizer_raw = normalizer.read(EXECUTABLE_LIMIT, "E_INSTALL")
            source = _open_held(os.path.join(_source_root(), "sandbox/v1/coverage-source.py"), False,
                                lambda _fd, _state, _ancestor: True, "E_INSTALL")
            self.held.append(source)
            _require(source.read(EXECUTABLE_LIMIT, "E_INSTALL") == normalizer_raw, "E_INSTALL")
            spec = importlib.util.spec_from_file_location("scope_coverage_source", normalizer.path)
            _require(spec is not None and spec.loader is not None, "E_INSTALL")
            self.normalizer = importlib.util.module_from_spec(spec)
            exec(compile(normalizer_raw, normalizer.path, "exec"), self.normalizer.__dict__)
            n = self.normalizer if operation == "coverage-read" else self.normalizer._KillNormalizer
            self.normalizer = n
            self.config = n.source_config(self.config_raw, anchor.config)["body"]
            _require(self.config["accepted_set_path"] == ANCHOR + "/" + prefix + "-accepted-identities.json", "E_CONFIG")
            package_file = _open_held(self.config["source_package_path"], False, rule, "E_INSTALL")
            self.held.append(package_file)
            self.package_raw = package_file.read(DOCUMENT_LIMIT, "E_INSTALL")
            package = n.package(self.package_raw, self.config)
            for row in package["body"]["files"]:
                item = _open_held(row["path"], False, rule, "E_INSTALL")
                self.held.append(item)
                raw = item.read(EXECUTABLE_LIMIT if row["role"] == "collector" else DOCUMENT_LIMIT, "E_INSTALL")
                _require(digest(raw) == row["sha256"], "E_INSTALL")
                if row["role"] == "normalizer":
                    _require(row["path"] == normalizer.path and raw == normalizer_raw, "E_INSTALL")
                elif row["role"].startswith("schema."):
                    n.query_schema(raw, row["role"][7:])
                elif row["role"] == "collector":
                    _require(item.before.st_mode & 0o111 != 0, "E_INSTALL")
            supervisor = next(item for item in anchor.held if item.path == ANCHOR + "/host-supervisor.py")
            supervisor_raw = supervisor.read(EXECUTABLE_LIMIT, "E_INSTALL")
            repo_supervisor = _open_held(os.path.join(_source_root(), "sandbox/v1/host-supervisor.py"), False,
                                       lambda _fd, _state, _ancestor: True, "E_INSTALL")
            self.held.append(repo_supervisor)
            _require(repo_supervisor.read(EXECUTABLE_LIMIT, "E_INSTALL") == supervisor_raw, "E_INSTALL")
            n.accepted(self.accepted_raw, self.config, digest(supervisor_raw), digest(self.package_raw),
                       self.config["collector_sha256"], digest(normalizer_raw))
            self.identity = n.source_identity(self.config, self.accepted_raw, digest(supervisor_raw), digest(normalizer_raw))
            self.hashes = {item.path: digest(item.read(EXECUTABLE_LIMIT, "E_INSTALL")) for item in self.held}
            self.recheck()
        except BaseException:
            self.close()
            raise

    def recheck(self, code="E_STALE"):
        self.anchor.recheck(code)
        for item in self.held:
            item.recheck(code)
            if stat.S_ISREG(item.before.st_mode):
                _require(digest(item.read(EXECUTABLE_LIMIT, code)) == self.hashes[item.path], code)

    def close(self):
        held, self.held = self.held, []
        _close_paths(held)


def load_coverage_configuration(anchor, operation="coverage-read"):
    _require(operation in {"coverage-read", "kill-register-read"}, "E_CONFIG")
    prefix = "coverage-source" if operation == "coverage-read" else "kill-register-source"
    root = next(item for item in anchor.held if item.path == ANCHOR)
    names = set(root.listdir())
    optional = {prefix + "-config.json", prefix + "-accepted-identities.json"}
    if not (names & optional):
        return None
    _require(optional <= names, "E_CONFIG")
    return _CoverageConfiguration(anchor, operation)


class _HeldCoverageRead(_HeldStoreRead):
    def __init__(self, anchor, configuration, request_raw):
        self.anchor, self.configuration = anchor, configuration
        self.attempt_id = configuration.normalizer.request(request_raw)["id"]
        self.held = []
        self.snapshots, self.observation = read_coverage_attempt(anchor, configuration, request_raw, _owner=self)
        try:
            self.record_source(request_raw)
        except BaseException as error:
            try:
                self.close()
            except OSError as cleanup_error:
                anchor.private_observations["source_constructor_cleanup_errno"] = cleanup_error.errno
                if (getattr(cleanup_error, "_scope_signal_cancel", False)
                        and not getattr(error, "_scope_signal_cancel", False)):
                    raise
            raise

    def record_source(self, request_raw):
        try:
            _require(request_raw == self.snapshots["payload/request.json"], "E_STORE")
            self.capture = _HeldCaptureRead(self, request_raw, source=True)
            self.capture_origin = _origin_values(self.snapshots, self.storage_rows,
                {"attempt_id": self.attempt_id, "platform": sys.platform},
                {"host-config.json": self.anchor.config_raw}, capture_files=self.capture.snapshots,
                capture_storage_rows=self.capture.storage_rows)
            return self.capture
        except Exception as error:
            self.anchor.private_observations["unusable"] = True
            self.anchor.private_observations["source_capture_failure"] = {
                "category": type(error).__name__,
                "errno": getattr(error, "os_errno", getattr(error, "errno", None))}
            if hasattr(self, "capture"):
                try:
                    self.capture.close()
                except OSError as cleanup_error:
                    self.capture_work["cleanup_errno"] = cleanup_error.errno
                    if (getattr(cleanup_error, "_scope_signal_cancel", False)
                            and not getattr(error, "_scope_signal_cancel", False)):
                        raise
            if getattr(error, "_scope_signal_cancel", False):
                raise
            return None

    def copy_source_capture(self, parent, ordinal, work):
        _require(type(ordinal) is int and 0 <= ordinal < 4096, "E_LIMIT")
        _capture_export_binding(_capture_for_replay(self.capture.snapshots, self.attempt_id,
            self.snapshots["payload/request.json"]), self.capture.snapshots, source=True)
        return self._copy_capture(parent, self.snapshots["payload/request.json"],
                                  "source-%04d" % ordinal, work)

    def recheck(self, code="E_STALE"):
        super().recheck(code)
        self.configuration.recheck(code)
        raw = next(item for item in self.held if item.path.endswith("/payload/raw"))
        _require(set(raw.listdir()) == {name.rsplit("/", 1)[1] for name in self.snapshots
                                            if name.startswith("payload/raw/")}, code)


def read_coverage_attempt(anchor, configuration, request_raw, *, _owner=None):
    n = configuration.normalizer
    requested = n.request(request_raw)
    attempt_id = requested["id"]
    _require(_owner is None or isinstance(_owner, _HeldCoverageRead), "E_STORE")
    uid, gid = anchor.config["principal_uid"], anchor.config["consumer_gid"]
    opened, snapshots, storage_rows = [], {}, []
    try:
        configuration.recheck("E_STORE")
        store = _open_held(anchor.config["store_root"], True, _store_rule(uid, gid, 0o750, True, anchor.resolver), "E_STORE")
        opened.append(store)
        _observation(store, ".", storage_rows=storage_rows)
        def directory(parent, name, relative):
            item = _open_child(parent, name, True, _store_rule(uid, gid, 0o750, True, anchor.resolver), "E_STORE")
            opened.append(item)
            _observation(item, relative, storage_rows=storage_rows)
            return item
        attempt = directory(store, attempt_id, attempt_id)
        payload = directory(attempt, "payload", "payload")
        raw_dir = directory(payload, "raw", "payload/raw")
        attempt_names = set(attempt.listdir())
        _require(attempt_names == {"receipt.json", "payload"}
                 and set(payload.listdir()) == {"request.json", "raw-manifest.json", "observation.json", "raw"}, "E_STORE")
        names = sorted(raw_dir.listdir())
        _require(len(n.FAMILIES) <= len(names) <= n.PAGE_LIMIT and names == [f"{index:04d}" for index in range(len(names))], "E_STORE")
        total = 0
        fixed = [(attempt, "receipt.json", "receipt.json"),
                 *[(payload, name, "payload/" + name) for name in ("request.json", "raw-manifest.json", "observation.json")],
                 *[(raw_dir, name, "payload/raw/" + name) for name in names]]
        for parent, name, relative in fixed:
            item = _open_child(parent, name, False, _store_rule(uid, gid, 0o440, False, anchor.resolver), "E_STORE")
            opened.append(item)
            raw = item.read(DOCUMENT_LIMIT, "E_STORE")
            snapshots[relative] = raw
            _observation(item, relative, storage_rows=storage_rows)
            if relative.startswith("payload/raw/"):
                total += len(raw)
                _require(total <= n.RAW_LIMIT, "E_STORE")
        _require(snapshots["payload/request.json"] == request_raw, "E_STORE")
        rebuilt = n.normalize(snapshots["payload/raw-manifest.json"],
            [snapshots["payload/raw/" + name] for name in names], request_raw)
        _require(rebuilt == snapshots["payload/observation.json"], "E_STORE")
        n.receipt(snapshots["receipt.json"], request_raw, anchor.config, configuration.identity,
                  snapshots["payload/raw-manifest.json"], rebuilt)
        _require(set(attempt.listdir()) == attempt_names, "E_STALE")
        for item in opened:
            item.recheck("E_STALE")
            relative = os.path.relpath(item.path, anchor.config["store_root"])
            if relative.startswith(attempt_id + "/"):
                relative = relative[len(attempt_id) + 1:]
            for row in storage_rows:
                if row["name"] == os.fsencode(relative).hex():
                    row["directory_names"] = item.directory_names
        configuration.recheck("E_STALE")
        origin = _origin_values(snapshots, storage_rows,
            {"attempt_id": attempt_id, "platform": sys.platform}, {"host-config.json": anchor.config_raw})
        if _owner is not None:
            _owner.held, opened = opened, []
            _owner.storage_rows = storage_rows
        return snapshots, origin
    finally:
        _close_paths(opened)


def _closed_scope_child(argv: list[str], env: dict[str, str], owner) -> None:
    _require(type(argv) is list and argv and all(type(value) is str and value and "\0" not in value
                                               for value in argv), "E_RUNTIME")
    python = [owner.python.held.path, "-I", "-S", "-B", owner.source.held.path]
    if argv[:-1] == python and argv[-1] in {"_resolve-darwin-uuids", "_read-darwin-group"}:
        _require(env == {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"}, "E_RUNTIME")
        return
    ledger = owner.ledger
    gate = getattr(owner, "_gate_invocation", None)
    if gate is not None and argv == gate:
        _require(env == ledger.environment() and len(argv) == 13
                 and argv[:4] == ["/bin/bash", "-p", os.path.join(_source_root(), "scope/v1/evaluate-scope.sh"), "evaluate"]
                 and all(_physical(path) for path in argv[4:]), "E_RUNTIME")
        return
    coverage = getattr(owner, "_coverage_invocation", None)
    if coverage is not None and argv == coverage:
        _require(env == {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"}, "E_RUNTIME")
        return
    _require(hasattr(ledger, "environment") and env == ledger.environment(), "E_RUNTIME")
    root = _source_root()
    if argv[0] == "/usr/bin/git":
        _require(len(argv) >= 4 and argv[1] == "--no-replace-objects"
                 and argv[2].startswith("--git-dir=") and _physical(argv[2][10:]), "E_RUNTIME")
        args = argv[3:]
        fixed = args in (["rev-parse", "--is-bare-repository"], ["rev-parse", "--show-object-format"])
        config = (len(args) == 6 and args[0:2] == ["config", "--file"] and _physical(args[2])
                  and args[3:] == ["--name-only", "--list", "--no-includes"])
        tree = len(args) == 6 and args[:5] == ["ls-tree", "-r", "-t", "-z", "--full-tree"] and _writer_oid(args[5])
        obj = len(args) == 3 and args[0] == "cat-file" and args[1] in {"commit", "blob"} and _writer_oid(args[2])
        _require(fixed or config or tree or obj, "E_RUNTIME")
        return
    if argv[:2] == ["/bin/bash", "-p"]:
        scripts = {"control/v1/evaluate-duty.sh": ("evaluate", 4),
            "control/v1/evaluate-risk-gates.sh": ("evaluate", 6),
            "control/v1/evaluate-kill-switch.sh": ("evaluate", 4),
            "control/v1/evaluate-bound-sandbox.sh": ("evaluate", 3),
            "shadow/v1/validate-incident.sh": ("validate", 1),
            "enforcement/v1/check-sandbox-receipt.sh": ("check-bound", 4),
            "maintenance/v1/incident-to-eval.sh": ("convert", 3)}
        for relative, (operation, count) in scripts.items():
            if argv[2:4] == [os.path.join(root, relative), operation]:
                _require(len(argv) == 4 + count and all(_physical(path) for path in argv[4:]), "E_RUNTIME")
                return
        _require(len(argv) == 7 and argv[2:4] == [os.path.join(root, "telemetry/v1/validate-trace-ledger.sh"), "validate"]
                 and _id(argv[4]) and _id(argv[5]) and _physical(argv[6]), "E_RUNTIME")
        return
    _require(argv[0] == ledger.jq.held.path and ledger.jq.sha256 == JQ_SHA256[sys.platform]
             and argv[1:3] == ["-L", str(ledger.modules)] and argv[-2] == "-f"
             and argv[-1] in {os.path.join(root, relative) for relative in (
                 "shadow/v1/qualified-identity.jq", "adapters/local-git-materializer/v1/protocol.jq",
                 "shadow/v1/write-materialization-input.jq", "scope/v1/workflow-scope.jq")}, "E_RUNTIME")
    args = argv[3:-2]
    program = os.path.basename(argv[-1])
    if program == "workflow-scope.jq":
        _require(args == ["-r", "--arg", "gate_basis", "basis"], "E_RUNTIME")
    elif program == "qualified-identity.jq":
        _require(len(args) == 10 and args[:3] == ["-r", "--arg", "repository_id"]
                 and _id(args[3]) and args[4:6] == ["--arg", "hash_algorithm"]
                 and args[6] in {"sha1", "sha256"} and args[7:9] == ["--arg", "commit_id"]
                 and _writer_oid(args[9]), "E_RUNTIME")
    elif program == "protocol.jq":
        _require(len(args) == 4 and args[:3] == ["-e", "--arg", "command"]
                 and args[3] in {"validate-input", "validate-response"}, "E_RUNTIME")
    else:
        _require(len(args) == 14 and args[:4] == ["-S", "-c", "--arg", "phase"]
                 and args[4] in {"stage-request", "final-input"}
                 and args[5:7] == ["--rawfile", "contract"] and _physical(args[7])
                 and args[8:10] == ["--rawfile", "patch"] and _physical(args[10])
                 and args[11:13] == ["--slurpfile", "metadata"] and _physical(args[13]), "E_RUNTIME")


@dataclasses.dataclass
class _HeldBytes:
    held: HeldPath
    raw: bytes

    @property
    def sha256(self) -> str:
        return digest(self.raw)

    def recheck(self, code: str = "E_STALE") -> None:
        self.held.recheck(code)
        _require(self.held.read(len(self.raw), code) == self.raw, code)

    def close(self) -> None:
        self.held.close()


def _hold_bytes(path: str, limit: int, code: str = "E_RELATION", hardlinks=False) -> _HeldBytes:
    held = _open_held(path, False, lambda _fd, _state, _ancestor: True, code,
                      allow_hardlinks=hardlinks)
    try:
        return _HeldBytes(held, held.read(limit, code))
    except BaseException:
        held.close()
        raise


def _uuid_reply_values(uuids, output):
    _require(type(uuids) is list and len(uuids) <= DARWIN_UUID_COUNT_LIMIT
             and all(_uuid_hex(value) for value in uuids), "E_ACL")
    rows = _json_array(output, DARWIN_UUID_OUTPUT_LIMIT, "E_ACL")
    _require(len(rows) == len(uuids), "E_ACL")
    for uuid, row in zip(uuids, rows):
        _require(type(row) is dict and set(row) == {"uuid", "status", "kind", "id"}
                 and row["uuid"] == uuid, "E_ACL")
        if row["status"] == "resolved":
            _require(type(row["kind"]) is str and row["kind"] in {"user", "group"} and _integer(row["id"])
                     and 0 <= row["id"] <= 0xffffffff, "E_ACL")
        else:
            _require(row["status"] == "unresolved" and row["kind"] is None
                     and row["id"] is None, "E_ACL")
    return rows


def _group_reply_values(gid, output):
    _require(_integer(gid) and 0 <= gid <= 0xffffffff, "E_ACL")
    _require(output in (canonical([]), canonical([gid])), "E_ACL")
    return output == canonical([gid])


class _DarwinChildOwner(_DarwinUUIDResolver, _DarwinGroupReader):
    def raw_uuid_replies(self):
        return self.uuid_replies

    def raw_group_replies(self):
        return self.group_replies

    def __init__(self, python, source, deadline: float, ledger) -> None:
        self.python, self.source = python, source
        self.deadline, self.ledger = deadline, ledger
        self.context = None
        self.uuid_replies = []
        self.group_replies = []
        self.observation_bytes = 0
        self.observations_complete = True
        self.recheck()

    def _retain_identity_reply(self, rows, metadata, output):
        cost = len(canonical(metadata | {"bytes": ""})) + 2 * len(output)
        if self.observation_bytes + cost > 4 * DOCUMENT_LIMIT:
            self.observations_complete = False
            return
        rows.append(metadata | {"bytes": output.hex()})
        self.observation_bytes += cost

    def recheck(self) -> None:
        self.python.recheck("E_DEPENDENCY")
        self.source.recheck("E_DEPENDENCY")
        _require(self.python.held.path == sys.executable
                 and os.path.realpath(sys.executable) == sys.executable
                 and self.source.held.path == os.path.join(_source_root(), "shadow/v1/_consumer.py"),
                 "E_DEPENDENCY")

    def _checkpoint(self) -> None:
        if self.context is not None:
            self.context.checkpoint()

    def _fixed(self, operation: str, raw: bytes, cap: int, context=None) -> bytes:
        _require(operation in {"_resolve-darwin-uuids", "_read-darwin-group"}, "E_RUNTIME")
        self.context = context
        self.recheck()
        role = "darwin-acl-uuid-resolution" if operation == "_resolve-darwin-uuids" else "darwin-group-membership"
        argv = [self.python.held.path, "-I", "-S", "-B", self.source.held.path, operation]
        self.ledger.record_command(role, argv, self.python.sha256, self.source.sha256)
        env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"}
        remaining = min(10, self.deadline - _clock_value('shadow/v1/_consumer.py:1274:0',time.monotonic(),'monotonic'))
        _require(remaining > 0, "E_RUNTIME")
        if context is None:
            output = self._foreground(argv, raw, cap, 65536, remaining, env)
        else:
            native = context.native
            _require(native is not None and self.ledger.native_status(native)[0] in {0, 4}, "E_RUNTIME")
            self._checkpoint()
            attempted = False
            try:
                attempted = True
                native.prepare_child((1 if operation == "_resolve-darwin-uuids" else 15,
                    os.fsencode(argv[0]), tuple(os.fsencode(item) for item in argv),
                    tuple(os.fsencode(f"{key}={env[key]}") for key in sorted(env))))
                native.spawn_child()
                status = self.ledger.native_status(native)
                _require(status[0] == 3 and status[3] == 1 and status[4] == 0
                         and status[1] > 0 and status[2] == status[1] and status[23] == 0, "E_RUNTIME")
                self._checkpoint()
                result, output, error = self.ledger.native_communicate(native, raw, cap, 65536, remaining)
                _require(type(result) is int and result == 0 and not error, "E_RUNTIME")
            except BaseException as exc:
                try:
                    try:
                        status = self.ledger.native_status(native)
                    except MemoryError:
                        if attempted:
                            self.ledger.native_cleanup(native, _clock_value('shadow/v1/_consumer.py:1301:0',time.monotonic(),'monotonic') + 10)
                        raise
                    if attempted and status[0] == 3 and self.ledger.native_pending(status):
                        self.ledger.native_cleanup(native, _clock_value('shadow/v1/_consumer.py:1304:0',time.monotonic(),'monotonic') + 10)
                except BaseException as cleanup_exc:
                    raise exc from cleanup_exc
                raise
        self.recheck()
        return output

    def resolve(self, uuids: list[str], context=None) -> list[dict]:
        _require(type(uuids) is list and len(uuids) <= DARWIN_UUID_COUNT_LIMIT
                 and all(_uuid_hex(value) for value in uuids), "E_ACL")
        if not uuids:
            return []
        output = self._fixed("_resolve-darwin-uuids", canonical(uuids), DARWIN_UUID_OUTPUT_LIMIT, context)
        self._retain_identity_reply(self.uuid_replies, {"uuids": list(uuids)}, output)
        return _uuid_reply_values(uuids, output)

    def contains(self, gid: int, context=None) -> bool:
        _require(_integer(gid) and 0 <= gid <= 0xffffffff, "E_ACL")
        output = self._fixed("_read-darwin-group", canonical({"gid": gid}), 16, context)
        self._retain_identity_reply(self.group_replies, {"gid": gid}, output)
        return _group_reply_values(gid, output)

    def coverage_source(self, request_raw):
        return self._source_read(request_raw, "coverage-read")

    def kill_register_source(self, request_raw):
        return self._source_read(request_raw, "kill-register-read")

    def _source_read(self, request_raw, operation):
        _require(operation in {"coverage-read", "kill-register-read"}, "E_RUNTIME")
        ledger = self.ledger
        anchor = ledger.anchor_for()
        configuration = ledger.coverage_configuration if operation == "coverage-read" else ledger.kill_configuration
        _require(isinstance(configuration, _CoverageConfiguration), "E_RUNTIME")
        configuration.normalizer.request(request_raw)
        sudo = _hold_bytes("/usr/bin/sudo", EXECUTABLE_LIMIT, "E_DEPENDENCY", hardlinks=True)
        try:
            _require(sudo.held.path == "/usr/bin/sudo", "E_DEPENDENCY")
            supervisor = next(item for item in anchor.held if item.path == ANCHOR + "/host-supervisor.py")
            supervisor_sha = digest(supervisor.read(EXECUTABLE_LIMIT, "E_DEPENDENCY"))
            argv = ["/usr/bin/sudo", "-n", "-u", "#" + str(anchor.config["principal_uid"]), "--",
                    self.python.held.path, "-I", "-S", "-B", supervisor.path, operation]
            self.recheck()
            sudo.recheck("E_DEPENDENCY")
            configuration.recheck()
            ledger.record_source_command(argv, request_raw, sudo.sha256, self.python.sha256, supervisor_sha)
            self._coverage_invocation = argv
            try:
                result = self._foreground(argv, request_raw, 0, 16384,
                    min(120, self.deadline - _clock_value('shadow/v1/_consumer.py:1363:0',time.monotonic(),'monotonic')),
                    {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"})
            finally:
                self._coverage_invocation = None
            _require(result == b"", "E_RUNTIME")
            self.recheck()
            sudo.recheck("E_DEPENDENCY")
            configuration.recheck()
            _require(digest(supervisor.read(EXECUTABLE_LIMIT, "E_STALE")) == supervisor_sha, "E_STALE")
        finally:
            sudo.close()

    def gate_scope(self, arguments, session):
        _require(type(arguments) is list and len(arguments) == 9 and all(_physical(path) for path in arguments), "E_RUNTIME")
        argv = ["/bin/bash", "-p", os.path.join(_source_root(), "scope/v1/evaluate-scope.sh"), "evaluate", *arguments]
        self._gate_invocation, self._gate_session = argv, session
        try:
            self.ledger.record_command("gate-scope-driver", argv, self.ledger.bash.sha256,
                                       self.ledger.package_sources["scope/v1/evaluate-scope.sh"].sha256)
            return self._foreground(argv, b"", DOCUMENT_LIMIT, 65536,
                min(300, self.deadline - _clock_value('shadow/v1/_consumer.py:1383:0',time.monotonic(),'monotonic')), self.ledger.environment())
        finally:
            self._gate_invocation = self._gate_session = None

    def _foreground(self, argv, raw, cap, error_cap, timeout, env):
        _closed_scope_child(argv, env, self)
        source = getattr(self, "_coverage_invocation", None)
        _require(0 < timeout <= (300 if argv == getattr(self, "_gate_invocation", None) else 120) and type(cap) is int
                 and ((source is not None and argv == source and cap == 0 and error_cap == 16384)
                      or (source is None and 0 < cap <= 16 * DOCUMENT_LIMIT and error_cap == 65536)), "E_RUNTIME")
        inherited = getattr(self.ledger, "store_session", None) is not None
        end = min(_clock_value('shadow/v1/_consumer.py:1394:0',time.monotonic(),'monotonic') + timeout, self.deadline - 10) if inherited else _clock_value('shadow/v1/_consumer.py:1394:1',time.monotonic(),'monotonic') + timeout
        _require(end > _clock_value('shadow/v1/_consumer.py:1395:0',time.monotonic(),'monotonic'), "E_RUNTIME")
        previous = signal.pthread_sigmask(signal.SIG_BLOCK,
                                          {signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
        child = None
        selector = selectors.DefaultSelector()
        cancelled = [False]
        old_handlers = {}
        def observe_signal(_number, _frame):
            cancelled[0] = True
        try:
            for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                old_handlers[number] = signal.signal(number, observe_signal)
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)
            _require(not cancelled[0], "E_RUNTIME")
            gate = (getattr(self, "_gate_session", None)
                    if argv == getattr(self, "_gate_invocation", None) else None)
            saved_fd = None
            if gate is not None:
                try:
                    saved_fd = os.dup(6)
                except OSError:
                    pass
                os.dup2(gate.child_socket.fileno(), 6, inheritable=True)
            try:
                child = subprocess.Popen(argv, pass_fds=((6,) if gate is not None else ()), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, env=env, close_fds=True, start_new_session=True)
            finally:
                if gate is not None:
                    if saved_fd is None:
                        os.close(6)
                    else:
                        os.dup2(saved_fd, 6)
                        os.close(saved_fd)
            if gate is not None:
                gate.child_socket.close()
                selector.register(gate.wire.sock, selectors.EVENT_READ)
            outputs = {child.stdout.fileno(): bytearray(), child.stderr.fileno(): bytearray()}
            limits = {child.stdout.fileno(): cap, child.stderr.fileno(): error_cap}
            for stream in (child.stdin, child.stdout, child.stderr):
                os.set_blocking(stream.fileno(), False)
            selector.register(child.stdout, selectors.EVENT_READ)
            selector.register(child.stderr, selectors.EVENT_READ)
            if raw:
                selector.register(child.stdin, selectors.EVENT_WRITE)
            else:
                child.stdin.close()
            sent = 0
            while selector.get_map():
                _require(not cancelled[0] and _clock_value('shadow/v1/_consumer.py:1443:0',time.monotonic(),'monotonic') < end, "E_RUNTIME")
                for key, events in selector.select(min(0.1, max(0, end - _clock_value('shadow/v1/_consumer.py:1444:0',time.monotonic(),'monotonic')))):
                    stream = key.fileobj
                    if gate is not None and stream is gate.wire.sock:
                        gate.pump()
                        while not gate.closed and gate.wire.pending():
                            gate.pump()
                        if gate.closed:
                            selector.unregister(stream)
                        continue
                    if stream is child.stdin:
                        try:
                            count = os.write(stream.fileno(), raw[sent:sent + 65536])
                        except BlockingIOError:
                            continue
                        _require(count > 0, "E_RUNTIME")
                        sent += count
                        if sent == len(raw):
                            selector.unregister(stream)
                            stream.close()
                    else:
                        try:
                            chunk = os.read(stream.fileno(), 65536)
                        except BlockingIOError:
                            continue
                        if not chunk:
                            selector.unregister(stream)
                            stream.close()
                        else:
                            bucket = outputs[key.fd]
                            _require(len(bucket) + len(chunk) <= limits[key.fd], "E_LIMIT")
                            bucket.extend(chunk)
            result = child.wait(timeout=max(0.001, end - _clock_value('shadow/v1/_consumer.py:1475:0',time.monotonic(),'monotonic')))
            _require(not cancelled[0] and result == 0, "E_RUNTIME")
            try:
                os.killpg(child.pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise Refusal("E_RUNTIME")
            if gate is not None:
                _require(gate.closed and not gate.wire.buffer, "E_RUNTIME")
                gate.wire.sock.settimeout(max(0.001, min(1, self.deadline - _clock_value('shadow/v1/_consumer.py:1485:0',time.monotonic(),'monotonic'))))
                _require(gate.wire.sock.recv(1) == b"", "E_RUNTIME")
            stdout, stderr = list(outputs.values())
            _require(not stderr, "E_RUNTIME")
            return bytes(stdout)
        except BaseException as exc:
            cleanup_errors = []
            if child is not None:
                cleanup_end = min(self.deadline, _clock_value('shadow/v1/_consumer.py:1493:0',time.monotonic(),'monotonic') + 10) if inherited else _clock_value('shadow/v1/_consumer.py:1493:1',time.monotonic(),'monotonic') + 10
                try:
                    try:
                        os.killpg(child.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    if child.returncode is None:
                        try:
                            child.wait(timeout=max(0.001, min(2, cleanup_end - _clock_value('shadow/v1/_consumer.py:1501:0',time.monotonic(),'monotonic'))))
                        except subprocess.TimeoutExpired:
                            pass
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    if child.returncode is None:
                        child.wait(timeout=max(0.001, cleanup_end - _clock_value('shadow/v1/_consumer.py:1509:0',time.monotonic(),'monotonic')))
                    while True:
                        try:
                            os.killpg(child.pid, 0)
                        except ProcessLookupError:
                            break
                        _require(_clock_value('shadow/v1/_consumer.py:1515:0',time.monotonic(),'monotonic') < cleanup_end, "E_RUNTIME")
                        time.sleep(min(0.01, max(0, cleanup_end - _clock_value('shadow/v1/_consumer.py:1516:0',time.monotonic(),'monotonic'))))
                except BaseException as cleanup_exc:
                    cleanup_errors.append(cleanup_exc)
            if cleanup_errors:
                cause = None
                retained = [exc]
                for cleanup_exc in cleanup_errors:
                    if any(cleanup_exc is prior for prior in retained):
                        continue
                    cleanup_exc.__cause__ = cause
                    cause = cleanup_exc
                    retained.append(cleanup_exc)
                if cause is not None:
                    raise exc from cause
            raise
        finally:
            signal.pthread_sigmask(signal.SIG_BLOCK,
                                    {signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
            try:
                selector.close()
                if child is not None:
                    for stream in (child.stdin, child.stdout, child.stderr):
                        if stream is not None and not stream.closed:
                            stream.close()
                for number, handler in old_handlers.items():
                    signal.signal(number, handler)
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous)



SHADOW_EVIDENCE_NAMES = (
    "accepted-identities.json", "claim.json", "consumer-provenance.json", "decision.json",
    "duty-evaluation.json", "evaluator-driver.txt", "evaluator-program.txt",
    "evidence-manifest.json", "file-digest-result.json", "incident.json",
    "materialization-input.json", "materialization-response.json", "origin-observation.json",
    "payload-stderr.txt", "payload-stdout.txt", "policy-set.json", "policy.json",
    "preparation-manifest.json", "preparation-record.json", "qualified-identity.json",
    "registry.json", "sandbox-check.json", "sandbox-evaluation.json",
    "sandbox-expectation.json", "sandbox-receipt.json", "sandbox-request.json",
    "shadow-record.json", "trace-ledger.json", "trace-receipt.json",
)

class _HeldBundle:
    def __init__(self, parent: HeldPath, name: str, form: str) -> None:
        _require(form in {"enforced-reproduction.v1", "withheld-write.v1", "withheld-write-policy.v1"}, "E_RELATION")
        self.held: list[HeldPath] = []
        self.files: dict[str, bytes] = {}
        self.names = set(SHADOW_EVIDENCE_NAMES) | {"bundle.json"}
        if form in {"withheld-write.v1", "withheld-write-policy.v1"}:
            self.names.add("publisher-body.txt")
        if form == "withheld-write-policy.v1":
            self.names.add("scope-policy.json")
        try:
            directory = _open_child(parent, name, True,
                                    lambda _fd, _state, _ancestor: True, "E_RELATION")
            self.held.append(directory)
            _require(set(directory.listdir()) == self.names, "E_RELATION")
            total = 0
            for filename in sorted(self.names):
                item = _open_child(directory, filename, False,
                                   lambda _fd, _state, _ancestor: True, "E_RELATION")
                self.held.append(item)
                limit = (8 * DOCUMENT_LIMIT if filename == "materialization-input.json" else
                         2 * DOCUMENT_LIMIT if filename == "preparation-manifest.json" else DOCUMENT_LIMIT)
                raw = item.read(limit, "E_STALE")
                total += len(raw)
                _require(total <= 48 * DOCUMENT_LIMIT, "E_LIMIT")
                if filename.endswith(".json"):
                    _json(raw, limit, "E_RELATION")
                self.files[filename] = raw
            incident = _json(self.files["incident.json"], DOCUMENT_LIMIT, "E_RELATION")
            marker = _json(self.files["bundle.json"], DOCUMENT_LIMIT, "E_RELATION")
            expected = {"schema_version": 1, "kind": "shadow_consumer_bundle",
                "id": "bundle." + digest(self.files["incident.json"])[:32], "body": {
                    "activation_state": "inactive", "record_form": form,
                    "incident_sha256": digest(self.files["incident.json"]),
                    "target_revision": incident["body"]["git_revision_ref"],
                    "files": [{"name": filename, "size_bytes": len(self.files[filename]),
                               "sha256": digest(self.files[filename])}
                              for filename in sorted(self.names - {"bundle.json"})]}}
            _require(canonical(marker) == canonical(expected), "E_RELATION")
            record = _json(self.files["shadow-record.json"], DOCUMENT_LIMIT, "E_RELATION")
            _require(record["body"]["record_form"] == form, "E_RELATION")
            if form == "withheld-write-policy.v1":
                check_scope_policy_ref(record["body"].get("scope_policy_ref"), self.files["scope-policy.json"])
            else:
                _require("scope_policy_ref" not in record["body"], "E_RELATION")
            self.recheck()
        except BaseException:
            self.close()
            raise

    def recheck(self, code: str = "E_STALE") -> None:
        _require(set(self.held[0].listdir()) == self.names, code)
        for item in self.held:
            item.recheck(code)
        for item in self.held[1:]:
            filename = os.path.basename(item.path)
            _require(item.read(len(self.files[filename]), code) == self.files[filename], code)

    def close(self) -> None:
        held, self.held = self.held, []
        _close_paths(held)


GIT_CONFIG_KEYS = {"core.repositoryformatversion", "core.filemode", "core.bare",
                   "core.logallrefupdates", "core.ignorecase", "core.precomposeunicode",
                   "extensions.objectformat"}

class _ReadOnlyGit:
    """Held bare object database with only the child-5 inspection commands."""
    def __init__(self, repository: str, ledger) -> None:
        self.repository = repository
        self.ledger = ledger
        self.held: list[HeldPath] = []
        try:
            config = _open_held(os.path.join(repository, "config"), False,
                                lambda _fd, _state, _ancestor: True, "E_RELATION")
            try:
                self.config = config.read(DOCUMENT_LIMIT, "E_RELATION")
            finally:
                config.close()
            self.config_path = str(ledger.capture("config-" + str(len(ledger.inputs)) + ".txt",
                                                self.config))
            for path, directory, hardlinks in (
                    (repository, True, False),
                    (os.path.join(repository, "objects"), True, False),
                    (os.path.join(repository, "config"), False, False),
                    ("/usr/bin/git", False, True)):
                item = _open_held(path, directory, lambda _fd, _state, _ancestor: True,
                                  "E_RELATION", allow_hardlinks=hardlinks)
                self.held.append(item)
            self.recheck()
        except BaseException:
            self.close()
            raise

    def recheck(self, code: str = "E_RELATION") -> None:
        for item in self.held:
            item.recheck(code)
        _require(self.held[2].read(DOCUMENT_LIMIT, code) == self.config, code)
        forbidden = ("commondir", "shallow", "info/grafts", "objects/info/alternates", "refs/replace")
        _require(not any(os.path.lexists(os.path.join(self.repository, name))
                         for name in forbidden), code)
        worktrees = os.path.join(self.repository, "worktrees")
        _require(not os.path.lexists(worktrees) or
                 (os.path.isdir(worktrees) and not os.listdir(worktrees)), code)
        pack = os.path.join(self.repository, "objects/pack")
        _require(not os.path.lexists(pack) or
                 (os.path.isdir(pack) and not any(name.endswith(".promisor")
                                                for name in os.listdir(pack))), code)

    def read(self, arguments: list[str], limit: int) -> bytes:
        fixed = arguments in (["config", "--file", self.config_path, "--name-only", "--list", "--no-includes"],
                              ["rev-parse", "--is-bare-repository"],
                              ["rev-parse", "--show-object-format"])
        tree = (len(arguments) == 6 and arguments[:5] ==
                ["ls-tree", "-r", "-t", "-z", "--full-tree"] and _writer_oid(arguments[5]))
        obj = (len(arguments) == 3 and arguments[0] == "cat-file"
               and arguments[1] in {"commit", "blob"} and _writer_oid(arguments[2]))
        _require((fixed or tree or obj) and type(limit) is int
                 and 0 < limit <= 16 * DOCUMENT_LIMIT, "E_RELATION")
        self.recheck()
        raw = self.ledger.execute_git(["/usr/bin/git", "--no-replace-objects",
                                      "--git-dir=" + self.repository, *arguments], limit)
        self.recheck()
        _require(len(raw) <= limit, "E_LIMIT")
        return raw

    def shape(self, algorithm: str) -> None:
        _require(algorithm in {"sha1", "sha256"}, "E_RELATION")
        keys = self.read(["config", "--file", self.config_path, "--name-only", "--list", "--no-includes"],
                         DOCUMENT_LIMIT)
        try:
            _require(set(keys.decode("utf-8").splitlines()) <= GIT_CONFIG_KEYS, "E_RELATION")
        except UnicodeError:
            raise Refusal("E_RELATION") from None
        _require(self.read(["rev-parse", "--is-bare-repository"], 16) == b"true\n"
                 and self.read(["rev-parse", "--show-object-format"], 16)
                 == (algorithm + "\n").encode(), "E_RELATION")

    def inventory(self, revision: dict) -> dict:
        self.shape(revision["hash_algorithm"])
        raw = self.read(["ls-tree", "-r", "-t", "-z", "--full-tree", revision["commit_id"]],
                        16 * DOCUMENT_LIMIT)
        _require(not raw or raw.endswith(b"\0"), "E_RELATION")
        facts = {}
        try:
            for line in raw.split(b"\0")[:-1]:
                header, name = line.split(b"\t", 1)
                mode, kind, oid = header.decode("ascii").split(" ")
                path = name.decode("utf-8")
                _require(path not in facts and _writer_oid(oid)
                         and len(oid) == (40 if revision["hash_algorithm"] == "sha1" else 64),
                         "E_RELATION")
                facts[path] = (mode, kind, oid)
        except (UnicodeError, ValueError):
            raise Refusal("E_RELATION") from None
        return facts

    def close(self) -> None:
        owned, self.held = self.held, []
        _close_paths(owned)


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

def _read_darwin_group() -> bytes:
    _require(sys.platform == "darwin", "E_ACL")
    raw = bytearray()
    while len(raw) <= 32:
        part = os.read(0, min(33 - len(raw), 4096))
        if not part:
            break
        raw.extend(part)
    _require(len(raw) <= 32, "E_ACL")
    body = _json(bytes(raw), 32, "E_ACL")
    _require(set(body) == {"gid"} and _integer(body["gid"])
             and 0 <= body["gid"] <= 0xffffffff and canonical(body) == bytes(raw), "E_ACL")
    gid = body["gid"]
    output = canonical([gid] if gid in os.getgroups() else [])
    _require(len(output) <= 16, "E_ACL")
    return output

def _resolver_main(argv: list[str]) -> int:
    try:
        _require(len(argv) == 2 and argv[1] in
                 ("_resolve-darwin-uuids", "_read-darwin-group") and sys.flags.isolated == 1
                 and sys.flags.no_site == 1 and sys.flags.dont_write_bytecode == 1, "E_ACL")
        output = (_resolve_darwin_uuids() if argv[1] == "_resolve-darwin-uuids"
                  else _read_darwin_group())
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


def validate_writer_argv(role: str, argv: list[str], source: str) -> None:
    def physical(value: str) -> bool:
        return _physical(value) and os.path.realpath(value) == value
    if role == "write-seed-conversion":
        valid = (len(argv) == 7 and argv[:4] == ["/bin/bash", "-p",
            source + "/maintenance/v1/incident-to-eval.sh", "convert"]
            and all(physical(value) for value in argv[4:]))
    elif role == "write-materialization-input":
        valid = (len(argv) == 20 and physical(argv[0]) and argv[0].endswith("/jq")
            and argv[1] == "-L" and physical(argv[2])
            and argv[3:7] == ["-S", "-c", "--arg", "phase"]
            and argv[7] in {"stage-request", "final-input"}
            and argv[8:10] == ["--rawfile", "contract"] and physical(argv[10])
            and argv[11:13] == ["--rawfile", "patch"] and physical(argv[13])
            and argv[14:16] == ["--slurpfile", "metadata"] and physical(argv[16])
            and argv[17:19] == ["-f", source + "/shadow/v1/write-materialization-input.jq"]
            and physical(argv[19]))
    elif role == "write-git-inspection":
        valid = (len(argv) >= 5 and argv[:2] == ["/usr/bin/git", "--no-replace-objects"]
                 and argv[2].startswith("--git-dir=") and physical(argv[2][10:]))
        args = argv[3:]
        valid = valid and (
            (len(args) == 6 and args[:2] == ["config", "--file"]
             and physical(args[2]) and args[3:] == ["--name-only", "--list", "--no-includes"])
            or args in (["rev-parse", "--is-bare-repository"],
                       ["rev-parse", "--show-object-format"])
            or (len(args) == 6 and args[:5] == ["ls-tree", "-r", "-t", "-z", "--full-tree"]
                and _writer_oid(args[5]))
            or (len(args) == 3 and args[:2] in (["cat-file", "commit"], ["cat-file", "blob"])
                and _writer_oid(args[2])))
    else:
        valid = False
    _require(valid, "E_RELATION")


def _writer_oid(value: object) -> bool:
    return isinstance(value, str) and len(value) in {40, 64} and all(
        char in "0123456789abcdef" for char in value)


def write_path_ok(path: object, policy: dict, mode: dict) -> bool:
    if not isinstance(path, str) or not 1 <= len(path.encode()) <= 4096:
        return False
    if path.startswith("/") or "\\" in path or any(ord(char) < 32 or ord(char) == 127 for char in path):
        return False
    parts = path.split("/")
    if len(parts) > 64 or any(part in {"", ".", ".."} or part.lower() in {".git", ".ystack"}
                             or part.endswith((".", " ")) for part in parts):
        return False
    rules = policy["body"]
    folded = [part.lower() for part in parts]
    if any(part in rules["protected_path_segments"] for part in folded):
        return False
    if len(parts) == 1 and path in rules["protected_root_files"]:
        return False
    prefixes = rules["protected_path_prefixes"] + mode["forbidden_prefixes"]
    if any(path.startswith(prefix) or path == prefix.rstrip("/") for prefix in prefixes):
        return False
    return path not in mode["forbidden_paths"]


def evidence_patch(files: dict[str, bytes], algorithm: str, record_form="withheld-write.v1") -> tuple[bytes, list[dict]]:
    _require(record_form in {"withheld-write.v1", "withheld-write-policy.v1"}, "E_RELATION")
    _require(algorithm in {"sha1", "sha256"} and len(files) == (33 if record_form == "withheld-write-policy.v1" else 32), "E_RELATION")
    chunks = []
    facts = []
    for path, raw in sorted(files.items()):
        _require(isinstance(raw, bytes) and b"\0" not in raw, "E_RELATION")
        try:
            text = raw.decode("utf-8")
        except UnicodeError:
            raise Refusal("E_RELATION") from None
        _require(not any(ord(char) < 32 and char not in "\n\r\t" for char in text), "E_RELATION")
        oid = hashlib.new(algorithm, ("blob " + str(len(raw)) + "\0").encode() + raw).hexdigest()
        header = (f"diff --git a/{path} b/{path}\nnew file mode 100644\n"
                  f"index {'0' * len(oid)}..{oid}\n--- /dev/null\n+++ b/{path}\n")
        lines = raw.split(b"\n")
        if raw:
            if raw.endswith(b"\n"):
                lines.pop()
            header += f"@@ -0,0 +1,{len(lines)} @@\n"
        patch = header.encode() + b"".join(b"+" + line + b"\n" for line in lines if raw)
        if raw and not raw.endswith(b"\n"):
            patch += b"\\ No newline at end of file\n"
        chunks.append(patch)
        _require(sum(map(len, chunks)) <= 1_048_576, "E_LIMIT")
        facts.append({"path": path, "mode": "100644", "sha256": digest(raw),
                      "git_blob_oid": oid, "add_only": True})
    return b"".join(chunks), facts


def scope_policy_ref(raw: bytes) -> dict:
    _require(type(raw) is bytes and 1 <= len(raw) <= DOCUMENT_LIMIT, "E_RELATION")
    _json(raw, DOCUMENT_LIMIT, "E_RELATION")
    return {"name": "scope-policy.json", "size_bytes": len(raw), "sha256": digest(raw)}


def check_scope_policy_ref(value: object, raw: bytes) -> None:
    _require(type(value) is dict and set(value) == {"name", "size_bytes", "sha256"}
             and _integer(value["size_bytes"]) and 1 <= value["size_bytes"] <= DOCUMENT_LIMIT
             and value["name"] == "scope-policy.json" and _sha(value["sha256"]), "E_RELATION")
    _require(canonical(value) == canonical(scope_policy_ref(raw)), "E_RELATION")


def write_contract(paths: list[str], record_form="withheld-write.v1") -> bytes:
    _require(record_form in {"withheld-write.v1", "withheld-write-policy.v1"}, "E_RELATION")
    return canonical({"schema_version": 1, "kind": "local_git_materialization_contract",
        "allowed_paths": paths, "max_patch_bytes": 1_048_576, "max_changed_paths": 33 if record_form == "withheld-write-policy.v1" else 32,
        "allowed_modes": ["100644", "100755"], "allow_binary_patch": False,
        "allow_symlinks": False, "allow_submodules": False, "candidate_repository_kind": "bare"})


WRITE_TEXTS = {
    "finish": b"Finish after all planned evidence files exist in the disposable candidate.\n",
    "verify": b"Verify every planned path, mode and byte digest, then run the fixed incident check.\n",
    "output_contract": b"Add only the listed evidence files; preserve all existing target files.\n",
    "policy": b"Routine candidate-only evidence preparation. Network and publication are denied.\n",
}


class _GateWire:
    """Bounded private frames on the generator's inherited socket, never a CLI input."""
    def __init__(self, sock, deadline, call_id=None, nonce=None, binding=None):
        self.sock, self.deadline = sock, deadline
        self.call_id, self.nonce, self.binding = call_id, nonce, binding
        self.sent = self.received = 0
        self.sent_bytes = self.received_bytes = 0
        self.buffer = bytearray()

    def send(self, phase, body):
        import struct
        _require(type(phase) is str and type(body) is dict, "E_RUNTIME")
        self.sent += 1
        raw = canonical({"version": 1, "call_id": self.call_id, "nonce": self.nonce,
            "sequence": self.sent, "phase": phase, "binding": self.binding, "body": body})
        _require(len(raw) <= DOCUMENT_LIMIT and _clock_value('shadow/v1/_consumer.py:1930:0',time.monotonic(),'monotonic') < self.deadline, "E_RUNTIME")
        self.sent_bytes += len(raw)
        _require(self.sent_bytes <= 64 * DOCUMENT_LIMIT, "E_LIMIT")
        self.sock.settimeout(max(0.001, self.deadline - _clock_value('shadow/v1/_consumer.py:1933:0',time.monotonic(),'monotonic')))
        self.sock.sendall(struct.pack("!I", len(raw)) + raw)

    def receive(self):
        import struct
        while len(self.buffer) < 4 or len(self.buffer) < 4 + struct.unpack("!I", self.buffer[:4])[0]:
            _require(_clock_value('shadow/v1/_consumer.py:1939:0',time.monotonic(),'monotonic') < self.deadline, "E_RUNTIME")
            self.sock.settimeout(max(0.001, self.deadline - _clock_value('shadow/v1/_consumer.py:1940:0',time.monotonic(),'monotonic')))
            chunk = self.sock.recv(65536)
            _require(bool(chunk), "E_RUNTIME")
            self.buffer.extend(chunk)
            if len(self.buffer) >= 4:
                _require(0 < struct.unpack("!I", self.buffer[:4])[0] <= DOCUMENT_LIMIT, "E_LIMIT")
        size = struct.unpack("!I", self.buffer[:4])[0]
        raw = bytes(self.buffer[4:4 + size]); del self.buffer[:4 + size]
        self.received_bytes += len(raw)
        _require(self.received_bytes <= 64 * DOCUMENT_LIMIT, "E_LIMIT")
        row = _json(raw, DOCUMENT_LIMIT, "E_RUNTIME")
        _require(set(row) == {"version", "call_id", "nonce", "sequence", "phase", "binding", "body"}
                 and type(row["version"]) is int and row["version"] == 1
                 and type(row["sequence"]) is int and row["sequence"] == self.received + 1
                 and type(row["body"]) is dict and type(row["phase"]) is str, "E_RUNTIME")
        if self.call_id is None:
            _require(row["phase"] == "INIT" and _id(row["call_id"]) and _sha(row["nonce"]) and _sha(row["binding"]), "E_RUNTIME")
            self.call_id, self.nonce, self.binding = row["call_id"], row["nonce"], row["binding"]
        _require((row["call_id"], row["nonce"], row["binding"]) ==
                 (self.call_id, self.nonce, self.binding), "E_RUNTIME")
        self.received += 1
        return row["phase"], row["body"]

    def pending(self):
        import struct
        return len(self.buffer) >= 4 and len(self.buffer) >= 4 + struct.unpack("!I", self.buffer[:4])[0]

    def exchange(self, phase, body):
        self.send(phase, body)
        reply, result = self.receive()
        _require(reply == phase + "_ACK", "E_RUNTIME")
        return result


def _gate_store_binding(item):
    _require(isinstance(item, _HeldStoreRead), "E_STORE")
    item.recheck()
    origin = _json(item.observation, DOCUMENT_LIMIT, "E_STORE")
    entries = []
    for row in origin["body"]["entries"]:
        row = dict(row)
        if row["name"] == ".":
            # A sibling changes only root bookkeeping between separate acquisitions.
            row["metadata_before"] = row["metadata_before"][:6]
            row["metadata_after"] = row["metadata_after"][:6]
        entries.append(row)
    return {"store_id": item.anchor.config["store_id"], "attempt_id": item.attempt_id,
        "ancestors": [list(_identity(component.before)) for component in item.held[0].components[:-1]],
        "entries": entries, "snapshots": [{"name": name, "size": len(raw), "sha256": digest(raw)}
            for name, raw in sorted(item.snapshots.items())],
        "origin_ref": {"schema_version": 1, "kind": origin["kind"], "id": origin["id"], "sha256": digest(item.observation)}}
