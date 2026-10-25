#!/usr/bin/env python3
"""Inactive, fail-closed consumer for one enforced shadow reproduction."""
from __future__ import annotations

import importlib.util
import ctypes
import errno
import gc
import hashlib
import json
import os
import shutil
import signal
import selectors
import stat
import subprocess
import sys
import sysconfig
import threading
import time
import dataclasses
from pathlib import Path
from typing import Callable, Iterable

SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("ystack_shadow_consumer", SOURCE / "shadow/v1/_consumer.py")
if spec is None or spec.loader is None:
    raise SystemExit("E_RUNTIME")
c = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = c
spec.loader.exec_module(c)

REQUEST_LIMIT = 64 * 1024
STDERR_LIMIT = 64 * 1024
OUTPUT_LIMIT = 1024 * 1024
FRAME_LIMIT = 88_080_384
OVERALL_SECONDS = 1200
EVIDENCE_NAMES = (
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
REQUEST_BODY_KEYS = {"attempt_id", "attempt_number", "incident", "claim", "duty_evaluation",
                     "materialization_input", "qualified_identity", "source_git_dir", "jq",
                     "closure_helper"}
WATCHED_SIGNALS = frozenset((signal.SIGTERM, signal.SIGHUP, signal.SIGINT))
_STARTUP_KEY = object()
_NATIVE_ORIGIN: Path | None = None
_CAPTURE_OWNER = None
_CAPTURE_OWNER_WORK = {}
_CHILD_ROLES = {
    "darwin-acl-uuid-resolution": 1,
    "incident-validation": 2,
    "materializer-input-validation": 3,
    "qualified-identity-validation": 4,
    "materialization": 5,
    "materializer-response-validation": 6,
    "candidate-preparation": 7,
    "candidate-inspection": 8,
    "sandbox-bound-evaluation": 9,
    "sandbox-receipt-check": 10,
    "trace-validation": 11,
    "helper-version": 12,
    "jq-version": 13,
    "sandbox-launch-boundary": 14,
    "darwin-group-membership": 15,
    "write-seed-conversion": 16,
    "write-materialization-input": 17,
    "write-git-inspection": 18,
}


class Refusal(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


class Cancelled(BaseException):
    pass


@dataclasses.dataclass(frozen=True)
class _StartupAdmission:
    key: object
    executable: str
    executable_sha256: str
    version: str
    build: tuple[int, int]
    module_origins: tuple[str, ...]
    census: object
    native: object | None = None
    capture_owner: object | None = None


class _ProcTaskInfo(ctypes.Structure):
    _fields_ = [
        ("pti_virtual_size", ctypes.c_uint64),
        ("pti_resident_size", ctypes.c_uint64),
        ("pti_total_user", ctypes.c_uint64),
        ("pti_total_system", ctypes.c_uint64),
        ("pti_threads_user", ctypes.c_uint64),
        ("pti_threads_system", ctypes.c_uint64),
        ("pti_policy", ctypes.c_int32),
        ("pti_faults", ctypes.c_int32),
        ("pti_pageins", ctypes.c_int32),
        ("pti_cow_faults", ctypes.c_int32),
        ("pti_messages_sent", ctypes.c_int32),
        ("pti_messages_received", ctypes.c_int32),
        ("pti_syscalls_mach", ctypes.c_int32),
        ("pti_syscalls_unix", ctypes.c_int32),
        ("pti_csw", ctypes.c_int32),
        ("pti_threadnum", ctypes.c_int32),
        ("pti_numrunning", ctypes.c_int32),
        ("pti_priority", ctypes.c_int32),
    ]


class _NativeThreadCensus:
    _LINUX_STATUS_LIMIT = 64 * 1024
    _PROC_PIDTASKINFO = 4

    def __init__(self) -> None:
        self._proc_pidinfo = None
        if sys.platform == "darwin":
            library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            function = library.proc_pidinfo
            function.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                 ctypes.c_void_p, ctypes.c_int]
            function.restype = ctypes.c_int
            self._proc_pidinfo = function
        elif not sys.platform.startswith("linux"):
            raise Refusal("E_RUNTIME")

    def observe(self) -> None:
        if self._proc_pidinfo is not None:
            info = _ProcTaskInfo()
            size = ctypes.sizeof(info)
            result = self._proc_pidinfo(os.getpid(), self._PROC_PIDTASKINFO, 0,
                                        ctypes.byref(info), size)
            require(result == size and info.pti_threadnum == 1, "E_RUNTIME")
            return
        fd = None
        failure = None
        raw = bytearray()
        try:
            fd = os.open("/proc/self/status", os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
            while len(raw) <= self._LINUX_STATUS_LIMIT:
                chunk = os.read(fd, min(8192, self._LINUX_STATUS_LIMIT + 1 - len(raw)))
                if not chunk:
                    break
                raw.extend(chunk)
            require(len(raw) <= self._LINUX_STATUS_LIMIT, "E_RUNTIME")
        except BaseException as exc:
            failure = exc
        finally:
            if fd is not None:
                try:
                    os.close(fd)
                except BaseException as exc:
                    if failure is None:
                        failure = exc
        if failure is not None:
            raise Refusal("E_RUNTIME") from failure
        try:
            text = raw.decode("ascii")
            pids = [line for line in text.splitlines() if line.startswith("Pid:")]
            threads = [line for line in text.splitlines() if line.startswith("Threads:")]
            require(len(pids) == 1 and len(threads) == 1
                    and pids[0].split() == ["Pid:", str(os.getpid())]
                    and threads[0].split() == ["Threads:", "1"], "E_RUNTIME")
        except (UnicodeError, ValueError):
            raise Refusal("E_RUNTIME") from None


def _path_below(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _runtime_module_origins() -> tuple[str, ...]:
    stdlib = Path(sysconfig.get_path("stdlib")).resolve(strict=True)
    driver = Path(__file__).resolve(strict=True)
    consumer = (SOURCE / "shadow/v1/_consumer.py").resolve(strict=True)
    writer = SOURCE / "shadow/v1/write-shadow.py"
    origins = []
    for module in tuple(sys.modules.values()):
        if module is sys.modules.get("__main__"):
            continue
        origin = getattr(getattr(module, "__spec__", None), "origin", None)
        if origin in (None, "built-in", "frozen"):
            path_value = getattr(module, "__file__", None)
            if path_value is None:
                continue
            origin = path_value
        if _CAPTURE_OWNER is not None and module is _CAPTURE_OWNER.module:
            require(origin == str(_CAPTURE_OWNER.path)
                    and sys.modules.get(_CAPTURE_OWNER.name) is module
                    and getattr(module, "__loader__", None) is _CAPTURE_OWNER, "E_RUNTIME")
            origins.append(str(_CAPTURE_OWNER.path))
            continue
        path = Path(origin)
        require(path.is_absolute(), "E_RUNTIME")
        resolved = path.resolve(strict=True)
        require(_path_below(resolved, stdlib) or resolved in {driver, consumer, writer, _NATIVE_ORIGIN},
                "E_RUNTIME")
        origins.append(str(resolved))
    return tuple(sorted(set(origins)))


def _runtime_callbacks_clear() -> None:
    require(threading.current_thread() is threading.main_thread()
            and sys.gettrace() is None and sys.getprofile() is None
            and not gc.callbacks, "E_RUNTIME")
    monitoring = getattr(sys, "monitoring", None)
    if monitoring is not None:
        require(all(monitoring.get_tool(index) is None for index in range(6)), "E_RUNTIME")


def _standalone_startup_admission() -> _StartupAdmission:
    require(__name__ == "__main__" and sys.flags.isolated == 1
            and sys.flags.no_site == 1 and sys.flags.dont_write_bytecode == 1,
            "E_RUNTIME")
    require(not any(key.startswith(("LD_", "DYLD_")) for key in os.environ), "E_RUNTIME")
    executable = Path(sys.executable)
    require(executable.is_absolute() and executable.resolve(strict=True) == executable,
            "E_RUNTIME")
    _runtime_callbacks_clear()
    gc.disable()
    held = stable_file(executable)
    try:
        executable_sha256 = held.sha256
        held.recheck("E_RUNTIME")
    finally:
        held.close()
    census = _NativeThreadCensus()
    return _StartupAdmission(_STARTUP_KEY, str(executable), executable_sha256,
                             sys.version, tuple(sys.version_info[:2]),
                             _runtime_module_origins(), census)


def require(value: bool, code: str = "E_RELATION") -> None:
    if not value:
        raise Refusal(code)


def integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def canonical(value: object) -> bytes:
    return c.canonical(value)


def sha(raw: bytes) -> str:
    return c.digest(raw)


def parse(raw: bytes, limit: int = OUTPUT_LIMIT, code: str = "E_SHAPE") -> dict:
    try:
        return c._json(raw, limit, code)
    except c.Refusal as exc:
        raise Refusal(exc.code) from None


def parse_value(raw: bytes, limit: int, code: str = "E_SHAPE") -> object:
    require(len(raw) <= limit, code)
    try:
        value = json.loads(raw, object_pairs_hook=c._unique_object)
        require(canonical(value) == raw, code)
        return value
    except (UnicodeError, ValueError, TypeError, RecursionError):
        raise Refusal(code) from None


def read_regular(path: Path, limit: int, code: str = "E_RUNTIME") -> bytes:
    held = None
    try:
        held = c._open_held(str(path), False, lambda _fd, _state, _ancestor: True, code)
        require(held.before.st_size <= limit, code)
        raw = held.read(limit, code)
        held.recheck(code)
        return raw
    except (OSError, ValueError, c.Refusal):
        raise Refusal(code) from None
    finally:
        if held is not None:
            held.close()


def private_empty(path: Path) -> None:
    try:
        state = path.lstat()
        require(path.is_absolute() and path.resolve() == path and path.is_dir()
                and not path.is_symlink() and (state.st_mode & 0o777) == 0o700
                and not any(path.iterdir()), "E_WORKSPACE")
    except OSError:
        raise Refusal("E_WORKSPACE") from None


def disjoint(paths: list[Path]) -> None:
    normalized = [str(path) for path in paths]
    for index, left in enumerate(normalized):
        for right in normalized[index + 1:]:
            require(left != right and not left.startswith(right + "/")
                    and not right.startswith(left + "/"), "E_WORKSPACE")


def outside(workspaces: list[Path], exclusions: list[Path]) -> None:
    for workspace in workspaces:
        for excluded in exclusions:
            disjoint([workspace, excluded])


@dataclasses.dataclass
class InputSnapshot:
    held: c.HeldPath
    path: Path
    raw: bytes

    def recheck(self) -> None:
        self.held.recheck("E_RELATION")
        require(read_regular(self.path, len(self.raw), "E_RELATION") == self.raw, "E_RELATION")

    def close(self) -> None:
        self.held.close()


@dataclasses.dataclass
class StableFile:
    held: c.HeldPath
    raw: bytes
    recording_work: dict | None = None

    @property
    def sha256(self) -> str:
        return sha(self.raw)

    def recheck(self, code: str = "E_RELATION") -> None:
        if self.recording_work is not None:
            self.recording_work["metadata_passes"] = self.recording_work.get("metadata_passes", 0) + 1
        self.held.recheck(code)
        if self.recording_work is None:
            require(self.held.read(len(self.raw), code) == self.raw, code)
        else:
            c._capture_copy_room(self.recording_work, 4 * len(self.raw), False, case=True, read_only=True)
            current = self.held.read(len(self.raw), code, self.recording_work)
            self.recording_work["read_bytes"] = self.recording_work.get("read_bytes", 0) + len(current) + len(self.raw)
            self.recording_work["equality_bytes"] = self.recording_work.get("equality_bytes", 0) + len(current) + len(self.raw)
            require(current == self.raw, code)

    def close(self) -> None:
        self.held.close()


@dataclasses.dataclass
class StableDirectory:
    held: c.HeldPath

    @staticmethod
    def _leaf_identity(value):
        return value.st_dev, value.st_ino, value.st_uid, value.st_gid, value.st_mode & 0o170777

    def _recording_parent(self):
        self.recheck()
        leaf = self.held.components[-1]
        current = c._metadata(leaf.fd)
        named = c._named_metadata(leaf.name, self.held.components[-2].fd)
        require(self._leaf_identity(current) == self._leaf_identity(leaf.before)
                == self._leaf_identity(named) and c._identity(current) == c._identity(named), "E_WORKSPACE")
        leaf.before = current
        return self.held

    def _retain_preparation(self, anchor, scratch_name, operation, input_raw, response_raw):
        try:
            return anchor.retain_preparation(self._recording_parent(),scratch_name,operation,input_raw,response_raw)
        except (Refusal,c.Refusal,OSError,MemoryError):
            anchor.private_observations["unusable"] = True
            return None

    def recheck(self, code: str = "E_WORKSPACE") -> None:
        for index, component in enumerate(self.held.components):
            current = c._metadata(component.fd)
            named = (current if component.name is None else
                     c._named_metadata(component.name, self.held.components[index - 1].fd))
            if index + 1 == len(self.held.components):
                stable = self._leaf_identity
                require(stable(current) == stable(component.before)
                        and stable(named) == stable(component.before), code)
            else:
                require(c._identity(current) == c._identity(component.before)
                        and c._identity(named) == c._identity(component.before), code)

    def close(self) -> None:
        self.held.close()


@dataclasses.dataclass
class FixedExecutable:
    logical: Path
    aliases: list[tuple[Path, tuple[int, ...], str | None]]
    physical: StableFile

    def recheck(self, code: str = "E_DEPENDENCY") -> None:
        for path, expected, target in self.aliases:
            state = os.lstat(path)
            require(c._identity(state) == expected and state.st_uid == 0, code)
            require(target is not None or not state.st_mode & 0o022, code)
            require((os.readlink(path) if target is not None else None) == target, code)
        require(self.logical.resolve(strict=True) == Path(self.physical.held.path), code)
        self.physical.recheck(code)

    def close(self) -> None:
        self.physical.close()


@dataclasses.dataclass
class FixedSudo:
    fd: int
    before: os.stat_result

    @property
    def sha256(self) -> str:
        return sha(canonical(list(c._identity(self.before))))

    def recheck(self, code: str = "E_DEPENDENCY") -> None:
        current, named = os.fstat(self.fd), os.lstat("/usr/bin/sudo")
        require(c._identity(current) == c._identity(self.before)
                and c._identity(named) == c._identity(self.before)
                and stat.S_ISREG(current.st_mode) and current.st_nlink == 1
                and current.st_uid == 0 and not current.st_mode & 0o022, code)

    def close(self) -> None:
        os.close(self.fd)


def stable_file(path: Path, limit: int = c.EXECUTABLE_LIMIT,
                code: str = "E_DEPENDENCY", allow_hardlinks: bool = False, recording_work=None) -> StableFile:
    held = c._open_held(str(path), False, lambda _fd, _state, _ancestor: True, code,
                       allow_hardlinks)
    try:
        if recording_work is not None:
            c._capture_copy_room(recording_work, 6 * min(limit, held.before.st_size),
                                 False, case=True, read_only=True)
        raw = held.read(limit, code) if recording_work is None else held.read(limit, code, recording_work)
        result = StableFile(held, raw, recording_work)
        result.recheck(code)
        return result
    except BaseException:
        held.close()
        raise


class _CaptureCompletionOwner:
    name = "ystack_capture_completion_owner"

    def __init__(self):
        self.path = SOURCE / "sandbox/v1/host-supervisor.py"
        self.source = self.module = self.loaded = None
        self.work = _CAPTURE_OWNER_WORK
        c._capture_work_values(self.work, "startup-source")
        self.transferred = 0

    def create_module(self, _spec):
        return None

    def exec_module(self, module):
        module.__file__ = str(self.path)
        self.loaded = self.source.raw
        c._capture_copy_room(self.work, 3 * len(self.loaded), False, case=True, read_only=True)
        self.work["read_bytes"] += len(self.loaded)
        code = compile(self.loaded, str(self.path), "exec", dont_inherit=True)
        loaded_sha = sha(self.loaded)
        source_sha = self.source.sha256
        self.work["read_bytes"] += 2 * len(self.loaded)
        require(self.loaded is self.source.raw and loaded_sha == source_sha, "E_RUNTIME")
        exec(code, module.__dict__)

    def initialize(self):
        require(CancellationSignals.active is None and self.name not in sys.modules, "E_RUNTIME")
        self.source = stable_file(self.path, recording_work=self.work)
        spec = importlib.util.spec_from_loader(self.name, self, origin=str(self.path))
        self.module = importlib.util.module_from_spec(spec)
        sys.modules[self.name] = self.module
        self.exec_module(self.module)
        self.source.recheck()
        require(callable(self.module._capture_completion_values), "E_RUNTIME")

    def authenticate(self, anchor):
        self.source.recheck()
        installed = next(item for item in anchor.held if item.path == str(Path(c.ANCHOR)/"host-supervisor.py"))
        c._capture_copy_room(self.work, 4 * len(self.source.raw), False, case=True, read_only=True)
        actual = installed.read(c.EXECUTABLE_LIMIT, "E_STORE", self.work)
        c._capture_copy_room(self.work, len(actual) + len(self.source.raw), False, case=True, read_only=True)
        self.work["read_bytes"] += len(actual) + len(self.source.raw)
        self.work["installed_comparison_bytes"] = self.work.get("installed_comparison_bytes", 0) + len(actual) + len(self.source.raw)
        require(actual == self.source.raw, "E_STORE")
        self.source.recheck()

    def construct(self, anchor, attempt_id, request_raw, capture_raw):
        self.authenticate(anchor)
        c._capture_copy_room(self.work, len(request_raw) + len(capture_raw) + 2048,
                             False, case=True, read_only=True)
        result = self.module._capture_completion_values(attempt_id, request_raw, capture_raw)
        self.work["read_bytes"] += len(request_raw) + len(capture_raw) + 4 * len(result)
        self.source.recheck()
        return result

    def transfer(self, work, case_work):
        delta = self.work["read_bytes"] - self.transferred
        c._capture_copy_room(work, delta, False, read_only=True)
        c._capture_copy_room(case_work, delta, False, case=True, read_only=True)
        work["read_bytes"] += delta
        case_work["read_bytes"] += delta
        self.transferred += delta


def _load_capture_completion_owner():
    global _CAPTURE_OWNER
    candidate = None
    try:
        require(CancellationSignals.active is None and _CAPTURE_OWNER is None, "E_RUNTIME")
        candidate = _CaptureCompletionOwner()
        candidate.initialize()
        _CAPTURE_OWNER = candidate
        return candidate
    except Exception as error:
        if candidate is not None:
            if candidate.module is not None and sys.modules.get(candidate.name) is candidate.module:
                del sys.modules[candidate.name]
            try:
                if candidate.source is not None:
                    candidate.source.close()
            except (OSError, Refusal, c.Refusal) as cleanup_error:
                _CAPTURE_OWNER_WORK["cleanup_error"] = type(cleanup_error).__name__
        _CAPTURE_OWNER_WORK["failure"] = {"category": type(error).__name__, "errno": getattr(error, "errno", None)}
        return None


def _bind_capture_completion_owner(anchor):
    active = CancellationSignals.active
    owner = getattr(getattr(active, "admission", None), "capture_owner", None)
    try:
        require(isinstance(owner, _CaptureCompletionOwner), "E_STORE")
        owner.authenticate(anchor)
        anchor.capture_completion_owner = owner
    except Exception as error:
        anchor.private_observations["unusable"] = True
        anchor.private_observations["completion_owner_failure"] = {
            "category": type(error).__name__, "errno": getattr(error, "errno", None)}


def _close_capture_completion_owner(owner):
    if owner is not None and owner.source is not None:
        try:
            owner.source.close()
        except Exception as error:
            owner.work["cleanup_error"] = {"category": type(error).__name__,
                                            "errno": getattr(error, "errno", None)}


class _DarwinLedger:
    def __init__(self, record_command):
        self.record = record_command

    def record_command(self, role, argv, executable_sha256, component_sha256):
        self.record(role, argv, executable_sha256, component_sha256)

    @staticmethod
    def native_status(native):
        return _native_child_status(native)

    @staticmethod
    def native_pending(status):
        return _native_child_pending(status)

    @staticmethod
    def native_cleanup(native, deadline):
        return _native_child_cleanup(native, deadline)

    @staticmethod
    def native_communicate(native, raw, output_limit, error_limit, timeout):
        child, stdout, stderr = _communicate_native(native, raw, output_limit, error_limit, timeout)
        return child.returncode, stdout, stderr


class _DarwinUUIDResolver(c._DarwinUUIDResolver):
    def __init__(self, python: StableFile, source: StableFile, deadline: float,
                 record_command: Callable[[str, list[str], str, str], None]) -> None:
        self.python, self.source = python, source
        self.deadline, self.record_command = deadline, record_command
        self.owner = c._DarwinChildOwner(python, source, deadline, _DarwinLedger(record_command))

    @property
    def observations_complete(self):
        return self.owner.observations_complete

    def raw_uuid_replies(self):
        return self.owner.raw_uuid_replies()

    def recheck(self) -> None:
        try:
            self.owner.recheck()
        except c.Refusal as exc:
            raise Refusal(exc.code) from exc

    def resolve(self, uuids: list[str]) -> list[dict]:
        try:
            require(len(uuids) <= c.DARWIN_UUID_COUNT_LIMIT
                    and all(c._uuid_hex(value) for value in uuids), "E_ACL")
            if uuids:
                require(CancellationSignals.active is not None, "E_RUNTIME")
            return self.owner.resolve(uuids, CancellationSignals.active)
        except c.Refusal as exc:
            raise Refusal(exc.code) from exc


class _DarwinGroupReader(c._DarwinGroupReader):
    def __init__(self, resolver: _DarwinUUIDResolver) -> None:
        self.resolver = resolver

    def raw_group_replies(self):
        return self.resolver.owner.raw_group_replies()

    def contains(self, gid: int) -> bool:
        try:
            require(integer(gid) and 0 <= gid <= 0xffffffff, "E_ACL")
            require(CancellationSignals.active is not None, "E_RUNTIME")
            return self.resolver.owner.contains(gid, CancellationSignals.active)
        except c.Refusal as exc:
            raise Refusal(exc.code) from exc


def _native_provenance_values(context: dict) -> dict:
    native = context["native_release"]
    return {"context_version": 2,
        "source_sha256": native["source_sha256"],
        "build_script_sha256": native["build_script_sha256"],
        "build_record_sha256": native["build_record_sha256"],
        "binary_locator_sha256": sha(native["binary_path"].encode()),
        "binary_size": native["binary_size"],
        "binary_sha256": native["binary_sha256"],
        "python_locator_sha256": sha(native["python_path"].encode()),
        "python_sha256": native["python_sha256"],
        "python_abi": native["python_abi"],
        "dependency_record_sha256": native["dependency_record_sha256"],
        "loader_mode": native["loader_mode"]}


_NATIVE_CONFIGURATION_KEYS = ("CONFIG_ARGS", "Py_GIL_DISABLED", "Py_DEBUG", "Py_ENABLE_JIT",
    "HAVE_PTHREAD_SIGMASK", "HAVE_BROKEN_PTHREAD_SIGMASK", "HAVE_SIGACTION")


def _native_argv_values(platform, compiler, include, config_include, source, binary):
    platform_flags = (["-bundle", "-undefined", "dynamic_lookup"]
                      if platform == "darwin" else ["-shared"])
    language = "-std=gnu11" if platform == "darwin" else "-std=c11"
    return [compiler, language, "-Wall", "-Wextra", "-Werror", "-O2",
        "-fvisibility=hidden", "-fPIC", "-I" + include, "-I" + config_include,
        *platform_flags, source, "-o", binary]


def _native_runtime_text(value, limit):
    if type(value) is not str or not value or len(value) > limit:
        return False
    size = 0
    for char in value:
        code = ord(char)
        if code == 0 or 0xD800 <= code <= 0xDFFF:
            return False
        size += 1 if code < 128 else 2 if code < 2048 else 3 if code < 65536 else 4
        if size > limit:
            return False
    return True


def _native_runtime_values(values, locators):
    require(type(values) is dict and set(values) == {"platform", "architecture",
        "python_implementation", "python_version", "soabi", "ext_suffix", "configuration"}, "E_RUNTIME")
    require(all(_native_runtime_text(values[key], 128) for key in values if key != "configuration"), "E_RUNTIME")
    configuration = values["configuration"]
    require(type(configuration) is dict and set(configuration) == set(_NATIVE_CONFIGURATION_KEYS)
            and all(value is None or type(value) in (str,int) for value in configuration.values())
            and all(type(value) is not str or not value or _native_runtime_text(value, c.DOCUMENT_LIMIT)
                    for value in configuration.values()), "E_RUNTIME")
    require(type(locators) is dict and set(locators) == {"compiler", "include", "config_include", "source", "binary"}
            and all(_native_runtime_text(value, 4096) for value in locators.values()), "E_RUNTIME")
    return _native_argv_values(values["platform"], **locators)


def _retain_native_runtime(anchor):
    active = CancellationSignals.active
    native = active.native if active is not None else None
    if isinstance(native, _NativeRelease) and hasattr(native, "runtime_values"):
        anchor.private_observations.setdefault("commands", {})["runtime_values"] = [native.runtime_values]
    else:
        anchor.private_observations["unusable"] = True


class _NativeRelease:
    _BUILD_KEYS = {"platform", "architecture", "source_sha256", "build_script_sha256",
        "compiler_path", "compiler_sha256", "compiler_version_sha256", "argv",
        "argv_sha256", "python_path", "python_sha256", "python_implementation",
        "python_version", "soabi", "ext_suffix", "configuration", "output_name",
        "output_size", "output_sha256", "test_build"}

    def __init__(self, context: dict, admission: _StartupAdmission) -> None:
        global _NATIVE_ORIGIN
        native = context["native_release"]
        self.source = stable_file(SOURCE / "shadow/v1/_cancel_release.c")
        self.script = stable_file(SOURCE / "shadow/v1/build-cancel-release.sh")
        self.record = stable_file(Path(native["binary_path"]).parent / "build-record.json",
                                  c.DOCUMENT_LIMIT)
        self.binary = stable_file(Path(native["binary_path"]))
        self.compiler: StableFile | None = None
        try:
            require(self.source.sha256 == native["source_sha256"]
                    and self.script.sha256 == native["build_script_sha256"]
                    and self.record.sha256 == native["build_record_sha256"]
                    and self.binary.sha256 == native["binary_sha256"]
                    and len(self.binary.raw) == native["binary_size"], "E_DEPENDENCY")
            document = parse(self.record.raw, c.DOCUMENT_LIMIT, "E_DEPENDENCY")
            require(set(document) == {"schema_version", "kind", "id", "body"}
                    and document["schema_version"] == 1
                    and document["kind"] == "shadow_cancel_release_build_record"
                    and document["id"] == "shadow.cancel-release.build"
                    and isinstance(document["body"], dict)
                    and set(document["body"]) == self._BUILD_KEYS, "E_DEPENDENCY")
            body = document["body"]
            include_value = sysconfig.get_config_var("INCLUDEPY")
            config_include_value = sysconfig.get_config_var("CONFINCLUDEPY")
            include = os.path.realpath(include_value) if isinstance(include_value, str) else None
            config_include = (os.path.realpath(config_include_value)
                              if isinstance(config_include_value, str) else None)
            extension = sysconfig.get_config_var("EXT_SUFFIX")
            abi = sysconfig.get_config_var("SOABI")
            require(all(isinstance(value, str) and value for value in
                        (include, config_include, extension, abi)), "E_DEPENDENCY")
            compiler_path = Path("/usr/bin/cc").resolve(strict=True)
            self.compiler = stable_file(compiler_path, allow_hardlinks=True)
            expected_argv = _native_argv_values(sys.platform, str(compiler_path), include,
                config_include, str(self.source.held.path), str(self.binary.held.path))
            expected_configuration = {key: sysconfig.get_config_var(key) for key in _NATIVE_CONFIGURATION_KEYS}
            require(body["platform"] == sys.platform
                    and body["architecture"] == (architecture := os.uname().machine)
                    and body["source_sha256"] == self.source.sha256
                    and body["build_script_sha256"] == self.script.sha256
                    and body["compiler_path"] == str(compiler_path)
                    and body["compiler_sha256"] == self.compiler.sha256
                    and c._sha(body["compiler_version_sha256"])
                    and body["argv"] == expected_argv
                    and body["argv_sha256"] == sha(c.canonical(expected_argv))
                    and body["python_path"] == admission.executable == native["python_path"]
                    and body["python_sha256"] == admission.executable_sha256 == native["python_sha256"]
                    and body["python_implementation"] == sys.implementation.name
                    and body["python_version"] == sys.version
                    and body["soabi"] == abi == native["python_abi"]
                    and body["ext_suffix"] == extension
                    and body["configuration"] == expected_configuration
                    and body["output_name"] == Path(native["binary_path"]).name
                    and body["output_size"] == len(self.binary.raw)
                    and body["output_sha256"] == self.binary.sha256
                    and body["test_build"] is False
                    and native["loader_mode"] == "rtld-now-local.v1", "E_DEPENDENCY")
            self.runtime_values = {"values": {"platform":sys.platform,"architecture":architecture,
                "python_implementation":sys.implementation.name,"python_version":sys.version,
                "soabi":abi,"ext_suffix":extension,"configuration":expected_configuration},
                "locators":{"compiler":str(compiler_path),"include":include,"config_include":config_include,
                    "source":str(self.source.held.path),"binary":str(self.binary.held.path)}}
            self.recheck()
            require(_NATIVE_ORIGIN is None and "_cancel_release" not in sys.modules,
                    "E_RUNTIME")
            prior_flags = sys.getdlopenflags()
            try:
                sys.setdlopenflags(os.RTLD_NOW | os.RTLD_LOCAL)
                module_spec = importlib.util.spec_from_file_location(
                    "_cancel_release", self.binary.held.path)
                require(module_spec is not None and module_spec.loader is not None,
                        "E_RUNTIME")
                module = importlib.util.module_from_spec(module_spec)
                sys.modules["_cancel_release"] = module
                module_spec.loader.exec_module(module)
            except BaseException:
                sys.modules.pop("_cancel_release", None)
                raise
            finally:
                sys.setdlopenflags(prior_flags)
            _NATIVE_ORIGIN = Path(self.binary.held.path)
            self.module = module
            self.state = module.prepare_state()
            self.methods = tuple(getattr(self.state, name) for name in (
                "block_entry", "arm_consumer", "checkpoint", "hold_completion", "block_final",
                "rollback_marker", "commit_completion", "abort_release", "outcome", "prepare_child",
                "spawn_child", "child_fds", "close_child_stdin", "close_child_stdout",
                "close_child_stderr", "observe_child_exit", "reap_child",
                "term_child_group", "kill_child_group", "check_child_group",
                "child_status"))
            (self.block_entry, self.arm_consumer, self.checkpoint,
             self.hold_completion, self.block_final, self.rollback_marker,
             self.commit_completion, self.abort_release, self.outcome,
             self.prepare_child, self.spawn_child,
             self.child_fds, self.close_child_stdin, self.close_child_stdout,
             self.close_child_stderr, self.observe_child_exit, self.reap_child,
             self.term_child_group, self.kill_child_group, self.check_child_group,
             self.child_status) = self.methods
            require(type(self.state).__name__ == "NativeState"
                    and self.outcome() == "native-release.pending", "E_RUNTIME")
            self.recheck()
        except BaseException:
            self.close()
            raise

    def recheck(self) -> None:
        self.source.recheck("E_DEPENDENCY")
        self.script.recheck("E_DEPENDENCY")
        self.record.recheck("E_DEPENDENCY")
        self.binary.recheck("E_DEPENDENCY")
        if self.compiler is not None:
            self.compiler.recheck("E_DEPENDENCY")

    def provenance(self, context: dict) -> dict:
        return _native_provenance_values(context)

    def close(self) -> None:
        failure = None
        for name in ("compiler", "binary", "record", "script", "source"):
            item = getattr(self, name, None)
            if item is not None:
                try:
                    item.close()
                except OSError as exc:
                    if failure is None:
                        failure = exc
                    setattr(self, name, None)
                else:
                    setattr(self, name, None)
        if failure is not None:
            raise failure


def stable_directory(path: Path) -> StableDirectory:
    held = c._open_held(str(path), True,
        lambda _fd, state, ancestor: ancestor or (state.st_mode & 0o777) == 0o700,
        "E_WORKSPACE")
    result = StableDirectory(held)
    result.recheck()
    return result


def close_all(items: Iterable[object]) -> None:
    active = sys.exception()
    failure = None
    for item in items:
        if item is None:
            continue
        try:
            item.close()
        except BaseException as exc:
            if failure is None:
                failure = exc
    if failure is not None:
        if active is not None:
            raise active from failure
        raise failure


def fixed_bash() -> FixedExecutable:
    logical = Path("/bin/bash")
    aliases = []
    for path in (Path("/"), Path("/bin"), logical):
        state = os.lstat(path)
        target = os.readlink(path) if path.is_symlink() else None
        require(state.st_uid == 0 and (target is not None or not state.st_mode & 0o022),
                "E_DEPENDENCY")
        aliases.append((path, c._identity(state), target))
    physical_path = logical.resolve(strict=True)
    result = FixedExecutable(logical, aliases, stable_file(physical_path))
    result.recheck()
    return result


def fixed_sudo() -> FixedSudo:
    flags = os.O_NOFOLLOW | getattr(os, "O_EXEC", os.O_RDONLY)
    try:
        fd = os.open("/usr/bin/sudo", flags)
        result = FixedSudo(fd, os.fstat(fd)); result.recheck(); return result
    except BaseException:
        if "fd" in locals(): os.close(fd)
        raise


def snapshot_input(source: Path, target: Path, limit: int) -> InputSnapshot:
    held = c._open_held(str(source), False, lambda _fd, _state, _ancestor: True, "E_RELATION")
    try:
        raw = held.read(limit, "E_RELATION")
        write_exclusive(target, raw)
        result = InputSnapshot(held, target, raw)
        result.recheck()
        return result
    except BaseException:
        held.close()
        raise


def write_exclusive(path: Path, raw: bytes, mode: int = 0o400, sync: bool = False) -> None:
    try:
        CancellationSignals.checkpoint()
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
        try:
            sent = 0
            while sent < len(raw):
                count = os.write(fd, raw[sent:])
                require(count > 0, "E_RUNTIME")
                sent += count
            if sync:
                os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        raise Refusal("E_RUNTIME") from None


def write_exclusive_at(directory: int, name: str, raw: bytes,
                       mode: int = 0o400, sync: bool = False,
                       remove_on_failure: bool = False) -> None:
    require("/" not in name and name not in {"", ".", ".."}, "E_RUNTIME")
    created = False
    try:
        CancellationSignals.checkpoint()
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     mode, dir_fd=directory)
        created = True
        try:
            sent = 0
            while sent < len(raw):
                count = os.write(fd, raw[sent:])
                require(count > 0, "E_RUNTIME")
                sent += count
            if sync:
                os.fsync(fd)
        finally:
            os.close(fd)
    except BaseException as exc:
        if created and remove_on_failure:
            try:
                os.unlink(name, dir_fd=directory)
                os.fsync(directory)
            except OSError: pass
        if isinstance(exc, OSError):
            raise Refusal("E_RUNTIME") from None
        raise


def clean_env(jq_path: Path, scratch: Path) -> dict[str, str]:
    return {"PATH": f"{jq_path.parent}:/usr/bin:/bin", "LC_ALL": "C", "LANG": "C",
            "HOME": str(scratch), "TMPDIR": str(scratch), "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_NO_LAZY_FETCH": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0",
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath",
            "GIT_CONFIG_VALUE_0": str(scratch / "no-hooks")}


def run_bounded(role: str, argv: list[str], *, stdin: bytes = b"", timeout: int = 120,
                output_limit: int = OUTPUT_LIMIT, env: dict[str, str],
                deadline: float | None = None) -> bytes:
    require(all(isinstance(item, str) and item for item in argv), "E_RUNTIME")
    if deadline is not None:
        require(deadline > c._clock_value('shadow/v1/enforced-reproduction.py:765:0',time.monotonic(),'monotonic'), "E_RUNTIME")
    remaining = timeout if deadline is None else min(timeout, deadline - c._clock_value('shadow/v1/enforced-reproduction.py:766:0',time.monotonic(),'monotonic'))
    try:
        child, stdout, stderr = spawn_bounded(role, argv, stdin, output_limit, STDERR_LIMIT,
                                               remaining, env)
    except (OSError, subprocess.SubprocessError):
        raise Refusal("E_RUNTIME") from None
    require(len(stdout) <= output_limit and len(stderr) <= STDERR_LIMIT, "E_LIMIT")
    require(child.returncode == 0 and not stderr, "E_RUNTIME")
    return stdout


def _stop_child(child: subprocess.Popen) -> None:
    end = c._clock_value('shadow/v1/enforced-reproduction.py:778:0',time.monotonic(),'monotonic') + 10
    for sent in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(child.pid, sent)
        except ProcessLookupError:
            pass
        boundary = end if sent == signal.SIGKILL else min(end, c._clock_value('shadow/v1/enforced-reproduction.py:784:0',time.monotonic(),'monotonic') + 5)
        while c._clock_value('shadow/v1/enforced-reproduction.py:785:0',time.monotonic(),'monotonic') < boundary:
            child.poll()
            try:
                os.killpg(child.pid, 0)
            except ProcessLookupError:
                if child.poll() is None:
                    child.wait(timeout=max(0.001, end - c._clock_value('shadow/v1/enforced-reproduction.py:791:0',time.monotonic(),'monotonic')))
                return
            except PermissionError:
                time.sleep(max(0, min(0.02, boundary - c._clock_value('shadow/v1/enforced-reproduction.py:794:0',time.monotonic(),'monotonic'))))
                continue
            time.sleep(max(0, min(0.02, boundary - c._clock_value('shadow/v1/enforced-reproduction.py:796:0',time.monotonic(),'monotonic'))))
    try:
        os.killpg(child.pid, 0)
    except ProcessLookupError:
        if child.poll() is None:
            child.wait(timeout=max(0.001, end - c._clock_value('shadow/v1/enforced-reproduction.py:801:0',time.monotonic(),'monotonic')))
        return
    raise Refusal("E_RUNTIME")


def stop_child(child: subprocess.Popen) -> None:
    previous = signal.pthread_sigmask(signal.SIG_BLOCK,
                                      {signal.SIGTERM, signal.SIGHUP, signal.SIGINT})
    try:
        _stop_child(child)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


@dataclasses.dataclass(frozen=True)
class _NativeChildResult:
    returncode: int


def _native_child_status(native: object) -> tuple[int, ...]:
    value = native.child_status()
    require(isinstance(value, tuple) and len(value) == 49
            and all(type(item) is int for item in value), "E_RUNTIME")
    return value


def _native_child_spec(role: str, argv: list[str], env: dict[str, str]) -> tuple:
    require(role in _CHILD_ROLES and argv and Path(argv[0]).is_absolute()
            and all(type(item) is str and item and "\0" not in item for item in argv)
            and all(type(key) is str and type(value) is str and key and "=" not in key
                    and "\0" not in key and "\0" not in value
                    for key, value in env.items()), "E_RUNTIME")
    if role.startswith("write-"):
        c.validate_writer_argv(role, argv, str(SOURCE))
    executable = os.fsencode(argv[0])
    arguments = tuple(os.fsencode(item) for item in argv)
    environment = tuple(os.fsencode(f"{key}={env[key]}") for key in sorted(env))
    return (_CHILD_ROLES[role], executable, arguments, environment)


def _native_returncode(status: tuple[int, ...]) -> int:
    code, value = status[9], status[10]
    if code == getattr(os, "CLD_EXITED", 1):
        return value
    require(code in {getattr(os, "CLD_KILLED", 2), getattr(os, "CLD_DUMPED", 3)}
            and value > 0, "E_RUNTIME")
    return -value


def _native_child_pending(status: tuple[int, ...]) -> tuple[str, ...]:
    actions = []
    if status[0] not in {0, 4}:
        for tag, name in ((28, "close_child_stdin"), (31, "close_child_stdout"),
                          (37, "close_child_stderr")):
            if status[tag] == 0:
                actions.append(name)
    if status[0] == 3 and not status[17]:
        if status[20] == 0:
            actions.append("term_child_group")
        if status[21] == 0:
            actions.append("kill_child_group")
        if not status[11] and (status[6] == 0 or status[7] == 0):
            actions.append("observe_child_exit")
        if (status[12] == 0 and status[11] and status[20] == status[21] == 1
                and (status[45] == 0 or status[46] == errno.ESRCH)):
            actions.append("reap_child")
    if (status[0] in {3, 4} and not status[18]
            and (status[22] == 0 or status[47] == 0)):
        actions.append("check_child_group")
    return tuple(actions)


def _native_child_cleanup(native: object, deadline: float) -> None:
    first: BaseException | None = None
    def attempt(method) -> bool:
        nonlocal first
        try:
            CancellationSignals.checkpoint()
        except BaseException as exc:
            if first is None:
                first = exc
        try:
            method()
            return True
        except BaseException as exc:
            if first is None:
                first = exc
        return False
    def snapshot():
        nonlocal first
        try:
            return _native_child_status(native)
        except MemoryError as exc:
            if first is None:
                first = exc
            try:
                return _native_child_status(native)
            except BaseException:
                raise first
    status = snapshot()
    if status[0] in {0, 1, 2, 4}:
        if first is not None:
            raise first
        require(status[23] == 0, "E_RUNTIME")
        return
    for name in ("close_child_stdin", "close_child_stdout", "close_child_stderr"):
        if name in _native_child_pending(snapshot()):
            attempt(getattr(native, name))
    status = snapshot()
    if status[0] in {0, 2, 4}:
        if first is not None:
            raise first
        require(status[23] == 0, "E_RUNTIME")
        return
    if "term_child_group" in _native_child_pending(status):
        attempt(native.term_child_group)
    observation_failed = False
    def observe_until(end):
        nonlocal observation_failed
        status = snapshot()
        while (not observation_failed and "observe_child_exit" in _native_child_pending(status)
               and c._clock_value('shadow/v1/enforced-reproduction.py:922:0',time.monotonic(),'monotonic') < end):
            returned = attempt(native.observe_child_exit)
            status = snapshot()
            if not returned:
                observation_failed = True
                break
            if not status[11]:
                time.sleep(min(0.02, max(0, end - c._clock_value('shadow/v1/enforced-reproduction.py:929:0',time.monotonic(),'monotonic'))))
    observe_until(min(deadline, c._clock_value('shadow/v1/enforced-reproduction.py:930:0',time.monotonic(),'monotonic') + 5))
    status = snapshot()
    if "kill_child_group" in _native_child_pending(status):
        attempt(native.kill_child_group)
    observe_until(deadline)
    status = snapshot()
    if "reap_child" in _native_child_pending(status):
        attempt(native.reap_child)
    status = snapshot()
    while ("check_child_group" in _native_child_pending(status)
           and c._clock_value('shadow/v1/enforced-reproduction.py:940:0',time.monotonic(),'monotonic') < deadline):
        returned = attempt(native.check_child_group)
        status = snapshot()
        if not returned:
            break
        if not status[18]:
            time.sleep(min(0.02, max(0, deadline - c._clock_value('shadow/v1/enforced-reproduction.py:946:0',time.monotonic(),'monotonic'))))
    if first is not None:
        raise first
    require(status[17] == status[18] == status[19] == status[24] == 1
            and status[23] == 0, "E_RUNTIME")


def _communicate_native(native: object, input_raw: bytes, stdout_limit: int,
                        stderr_limit: int, timeout: float) -> tuple[_NativeChildResult, bytes, bytes]:
    stdin_fd, stdout_fd, stderr_fd = native.child_fds()
    require(all(type(fd) is int and fd > 2 for fd in
                (stdin_fd, stdout_fd, stderr_fd)), "E_RUNTIME")
    selector = selectors.DefaultSelector()
    output = {stdout_fd: bytearray(), stderr_fd: bytearray()}
    limits = {stdout_fd: stdout_limit, stderr_fd: stderr_limit}
    closes = {stdin_fd: native.close_child_stdin, stdout_fd: native.close_child_stdout,
              stderr_fd: native.close_child_stderr}
    closed: set[int] = set()
    end = c._clock_value('shadow/v1/enforced-reproduction.py:964:0',time.monotonic(),'monotonic') + timeout
    def close_fd(fd: int) -> None:
        if fd not in closed:
            try:
                selector.unregister(fd)
            except KeyError:
                pass
            closes[fd]()
            closed.add(fd)
    failure: BaseException | None = None
    try:
        for fd in (stdin_fd, stdout_fd, stderr_fd):
            os.set_blocking(fd, False)
        selector.register(stdout_fd, selectors.EVENT_READ)
        selector.register(stderr_fd, selectors.EVENT_READ)
        if input_raw:
            selector.register(stdin_fd, selectors.EVENT_WRITE)
        else:
            close_fd(stdin_fd)
        sent = 0
        while selector.get_map():
            CancellationSignals.checkpoint()
            remaining = end - c._clock_value('shadow/v1/enforced-reproduction.py:986:0',time.monotonic(),'monotonic')
            require(remaining > 0, "E_RUNTIME")
            for key, mask in selector.select(min(remaining, 0.1)):
                fd = key.fd
                if fd == stdin_fd and mask & selectors.EVENT_WRITE:
                    try:
                        count = os.write(fd, input_raw[sent:sent + 65536])
                    except BlockingIOError:
                        continue
                    require(count > 0, "E_RUNTIME")
                    sent += count
                    if sent == len(input_raw):
                        close_fd(fd)
                elif mask & selectors.EVENT_READ:
                    try:
                        chunk = os.read(fd, 65536)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        close_fd(fd)
                        continue
                    require(len(output[fd]) + len(chunk) <= limits[fd], "E_LIMIT")
                    output[fd].extend(chunk)
        CancellationSignals.checkpoint()
        status = _native_child_status(native)
        while not status[11]:
            require(c._clock_value('shadow/v1/enforced-reproduction.py:1012:0',time.monotonic(),'monotonic') < end, "E_RUNTIME")
            native.observe_child_exit()
            status = _native_child_status(native)
            if not status[11]:
                time.sleep(min(0.02, max(0, end - c._clock_value('shadow/v1/enforced-reproduction.py:1016:0',time.monotonic(),'monotonic'))))
            CancellationSignals.checkpoint()
        returncode = _native_returncode(status)
        normal = (returncode == 0 and status[6:9] == (1, 0, 0)
                  and status[9] == getattr(os, "CLD_EXITED", 1) and status[10] == 0
                  and status[11] == 1 and status[19] == 1 and status[20:23] == (0, 0, 0)
                  and status[23] == 0)
        if normal:
            native.reap_child()
            status = _native_child_status(native)
            native.check_child_group()
        else:
            _native_child_cleanup(native, end)
        status = _native_child_status(native)
        require(status[17] == 1 and status[18] == 1 and status[19] == 1
                and status[23] == 0 and status[24] == 1, "E_RUNTIME")
        return (_NativeChildResult(returncode), bytes(output[stdout_fd]),
                bytes(output[stderr_fd]))
    except BaseException as exc:
        failure = exc
        raise
    finally:
        try:
            selector.close()
        except BaseException:
            if failure is None:
                raise


def spawn_bounded(role: str, argv: list[str], input_raw: bytes, stdout_limit: int,
                  stderr_limit: int, timeout: float,
                  env: dict[str, str]) -> tuple[_NativeChildResult, bytes, bytes]:
    CancellationSignals.checkpoint()
    active = CancellationSignals.active
    require(active is not None and active.native is not None, "E_RUNTIME")
    native = active.native
    initial = _native_child_status(native)
    require(initial[0] in {0, 4}, "E_RUNTIME")
    attempted = False
    try:
        attempted = True
        native.prepare_child(_native_child_spec(role, argv, env))
        native.spawn_child()
        status = _native_child_status(native)
        require(status[0] == 3 and status[3] == 1 and status[4] == 0
                and status[1] > 0 and status[2] == status[1]
                and status[23] == 0, "E_RUNTIME")
        CancellationSignals.checkpoint()
        return _communicate_native(native, input_raw, stdout_limit, stderr_limit, timeout)
    except BaseException as exc:
        try:
            try:
                status = _native_child_status(native)
            except MemoryError:
                if attempted:
                    _native_child_cleanup(native, c._clock_value('shadow/v1/enforced-reproduction.py:1071:0',time.monotonic(),'monotonic') + 10)
                raise
            if attempted and status[0] == 3 and _native_child_pending(status):
                _native_child_cleanup(native, c._clock_value('shadow/v1/enforced-reproduction.py:1074:0',time.monotonic(),'monotonic') + 10)
        except BaseException as cleanup_exc:
            raise exc from cleanup_exc
        raise


def _close_communication(selector: selectors.BaseSelector | None,
                         stdin: object, stdout: object, stderr: object) -> OSError | None:
    first = None
    attempted: set[int] = set()
    for resource in (selector, stdin, stdout, stderr):
        if resource is None or id(resource) in attempted:
            continue
        attempted.add(id(resource))
        if resource is not selector and getattr(resource, "closed", False):
            continue
        try:
            resource.close()
        except OSError as exc:
            if first is None:
                first = exc
    return first


def communicate_bounded(child: subprocess.Popen, input_raw: bytes, stdout_limit: int,
                        stderr_limit: int, timeout: float, *,
                        cleanup: bool = True) -> tuple[bytes, bytes]:
    selector = None
    body_failure = None
    try:
        selector = selectors.DefaultSelector()
        require(child.stdin is not None and child.stdout is not None and child.stderr is not None,
                "E_RUNTIME")
        stdout_fd, stderr_fd = child.stdout.fileno(), child.stderr.fileno()
        output = {stdout_fd: bytearray(), stderr_fd: bytearray()}
        limits = {stdout_fd: stdout_limit, stderr_fd: stderr_limit}
        for stream in (child.stdin, child.stdout, child.stderr):
            os.set_blocking(stream.fileno(), False)
        selector.register(child.stdout, selectors.EVENT_READ)
        selector.register(child.stderr, selectors.EVENT_READ)
        if input_raw:
            selector.register(child.stdin, selectors.EVENT_WRITE)
        else:
            child.stdin.close()
        sent = 0; end = c._clock_value('shadow/v1/enforced-reproduction.py:1118:0',time.monotonic(),'monotonic') + timeout
        while selector.get_map():
            CancellationSignals.checkpoint()
            remaining = end - c._clock_value('shadow/v1/enforced-reproduction.py:1121:0',time.monotonic(),'monotonic')
            if remaining <= 0:
                raise Refusal("E_RUNTIME")
            ready = selector.select(min(remaining, 0.1))
            if not ready:
                if child.poll() is None:
                    continue
                for key in list(selector.get_map().values()):
                    stream = key.fileobj
                    if stream is child.stdin:
                        selector.unregister(stream); stream.close(); continue
                    try:
                        chunk = os.read(stream.fileno(), 65536)
                    except BlockingIOError:
                        CancellationSignals.checkpoint()
                        continue
                    if not chunk:
                        selector.unregister(stream); stream.close(); continue
                    bucket = output[stream.fileno()]
                    require(len(bucket) + len(chunk) <= limits[stream.fileno()], "E_LIMIT")
                    bucket.extend(chunk)
                continue
            for key, mask in ready:
                stream = key.fileobj
                if stream is child.stdin and mask & selectors.EVENT_WRITE:
                    try:
                        count = os.write(stream.fileno(), input_raw[sent:sent + 65536])
                    except BlockingIOError:
                        CancellationSignals.checkpoint()
                        continue
                    require(count > 0, "E_RUNTIME"); sent += count
                    if sent == len(input_raw):
                        selector.unregister(stream); stream.close()
                elif mask & selectors.EVENT_READ:
                    try:
                        chunk = os.read(stream.fileno(), 65536)
                    except BlockingIOError:
                        CancellationSignals.checkpoint()
                        continue
                    if not chunk:
                        selector.unregister(stream); stream.close(); continue
                    bucket = output[stream.fileno()]
                    require(len(bucket) + len(chunk) <= limits[stream.fileno()], "E_LIMIT")
                    bucket.extend(chunk)
        CancellationSignals.checkpoint()
        try:
            child.wait(timeout=max(0.001, end - c._clock_value('shadow/v1/enforced-reproduction.py:1167:0',time.monotonic(),'monotonic')))
        except subprocess.TimeoutExpired:
            raise Refusal("E_RUNTIME") from None
        CancellationSignals.checkpoint()
        return bytes(output[stdout_fd]), bytes(output[stderr_fd])
    except BaseException as exc:
        body_failure = exc
        if cleanup:
            stop_child(child)
        raise
    finally:
        close_failure = _close_communication(selector, child.stdin, child.stdout, child.stderr)
        if body_failure is None and close_failure is not None:
            raise close_failure


class CancellationSignals:
    active: CancellationSignals | None = None

    def __init__(self, admission: _StartupAdmission | None = None) -> None:
        self.admission = admission
        self.native = admission.native if isinstance(admission, _StartupAdmission) else None
        self.parent: CancellationSignals | None = None
        self.borrowed = False
        self.borrow_depth = 0
        self.completion_confirmed = False
        self.completion_payload: bytes | None = None
        self.caller_exception: BaseException | None = None

    @classmethod
    def checkpoint(cls) -> None:
        if cls.active is None:
            return
        require(cls.active.native is not None, "E_RUNTIME")
        result = cls.active.native.checkpoint()
        if result == "native-checkpoint.cancelled":
            raise Cancelled()
        require(result == "native-checkpoint.clear", "E_RUNTIME")

    @classmethod
    def retain_completion(cls, directory: int) -> bool | None:
        if cls.active is None:
            return None
        require(cls.active.borrow_depth == 0 and cls.active.native is not None, "E_RUNTIME")
        cls.active.native.hold_completion(directory)
        confirmed = cls.active.native.outcome() == "native-release.pending"
        cls.active.completion_confirmed = confirmed
        return confirmed

    @classmethod
    def prepare_completion(cls, payload: bytes) -> None:
        require(cls.active is not None and cls.active.borrow_depth == 0
                and cls.active.completion_confirmed and type(payload) is bytes
                and 0 < len(payload) <= c.DOCUMENT_LIMIT, "E_RUNTIME")
        cls.active.completion_payload = payload

    @staticmethod
    def _remember(first: BaseException | None, exc: BaseException) -> BaseException:
        return first if first is not None else exc

    def __enter__(self) -> CancellationSignals:
        if CancellationSignals.active is not None:
            self.parent = CancellationSignals.active
            self.borrowed = True
            self.parent.borrow_depth += 1
            return self
        require(isinstance(self.admission, _StartupAdmission)
                and self.admission.key is _STARTUP_KEY
                and self.admission.executable == sys.executable
                and self.admission.version == sys.version
                and self.admission.build == tuple(sys.version_info[:2])
                and self.admission.module_origins == _runtime_module_origins()
                and self.native is not None, "E_RUNTIME")
        held_executable = stable_file(Path(self.admission.executable))
        try:
            require(held_executable.sha256 == self.admission.executable_sha256, "E_RUNTIME")
            held_executable.recheck("E_RUNTIME")
        finally:
            held_executable.close()
        self.native.recheck()
        self.admission.census.observe()
        failure = None
        try:
            self.native.block_entry()
            require(self.native.outcome() == "native-release.pending", "E_RUNTIME")
            self.native.arm_consumer()
            require(self.native.outcome() == "native-release.pending", "E_RUNTIME")
            self.parent = CancellationSignals.active
            CancellationSignals.active = self
            return self
        except BaseException as exc:
            failure = exc
            CancellationSignals.active = self.parent
            try:
                self.native.abort_release()
            except BaseException as release_exc:
                failure = self._remember(failure, release_exc)
            raise failure

    def __exit__(self, kind: object, value: object, _traceback: object) -> None:
        if self.borrowed:
            require(self.parent is not None and self.parent.borrow_depth > 0, "E_RUNTIME")
            self.parent.borrow_depth -= 1
            return
        require(self.native is not None, "E_RUNTIME")
        body_failure = value if isinstance(value, BaseException) else None
        failure = body_failure
        if failure is None:
            try:
                require(self.completion_payload is not None and self.completion_confirmed,
                        "E_RUNTIME")
                self.native.block_final()
                require(self.native.outcome() == "native-release.pending", "E_RUNTIME")
                require(self.admission is not None, "E_RUNTIME")
                self.admission.census.observe()
            except BaseException as exc:
                failure = self._remember(failure, exc)
        CancellationSignals.active = self.parent
        if failure is None:
            commit_exception = None
            try:
                self.native.commit_completion(self.completion_payload)
            except BaseException as exc:
                commit_exception = exc
            try:
                native_outcome = self.native.outcome()
            except BaseException as exc:
                self.caller_exception = exc
                if commit_exception is not None:
                    raise exc from commit_exception
                raise
            if commit_exception is not None and native_outcome == "native-release.pending":
                abort_exception = None
                try:
                    self.native.abort_release()
                except BaseException as exc:
                    abort_exception = exc
                try:
                    native_outcome = self.native.outcome()
                except BaseException as exc:
                    self.caller_exception = exc
                    raise exc from (abort_exception if abort_exception is not None
                                    else commit_exception)
                if native_outcome != "native-release.failure":
                    raise Refusal("E_RUNTIME") from (abort_exception if abort_exception is not None
                                                     else commit_exception)
                self.caller_exception = abort_exception or commit_exception
                if abort_exception is not None:
                    raise abort_exception from commit_exception
                raise commit_exception
            if commit_exception is not None and native_outcome == "native-release.success":
                self.caller_exception = commit_exception
                raise commit_exception
            if native_outcome != "native-release.success":
                failure = Refusal("E_RUNTIME")
                if commit_exception is not None:
                    raise failure from commit_exception
        else:
            try:
                self.native.abort_release()
            except BaseException as exc:
                failure = self._remember(failure, exc)
            try:
                if self.native.outcome() != "native-release.failure":
                    failure = self._remember(failure, Refusal("E_RUNTIME"))
            except BaseException as exc:
                self.caller_exception = exc
                raise exc from failure
        if body_failure is None and failure is not None:
            raise failure


def frame_write(records: Iterable[tuple[bytes, bytes]]) -> bytes:
    out = bytearray(b"YSFRAME1")
    measured = hashlib.sha256(b"YSFRAME1")
    for name, content in records:
        require(0 < len(name) <= 255 and name != b"end", "E_LIMIT")
        header = bytes((len(name),)) + name + len(content).to_bytes(8, "big")
        require(len(out) + len(header) + len(content) + 44 <= FRAME_LIMIT, "E_LIMIT")
        out.extend(header); out.extend(content); measured.update(header); measured.update(content)
    end = b"\x03end" + (32).to_bytes(8, "big") + measured.digest()
    require(len(out) + len(end) <= FRAME_LIMIT, "E_LIMIT")
    out.extend(end)
    return bytes(out)


def control(anchor: c.Anchor, evaluation_raw: bytes) -> dict:
    names = ("control_policy", "control_decision", "control_policy_set",
             "evaluator_driver", "evaluator_program")
    return _control_values({name: anchor.installed[name][0] for name in names}, evaluation_raw)


def _control_values(files, evaluation_raw):
    names = ("control_policy", "control_decision", "control_policy_set", "evaluator_driver", "evaluator_program")
    return {name.removeprefix("control_") + "_sha256": sha(files[name]) for name in names} | {
        "sandbox_evaluation_sha256": sha(evaluation_raw)}


def document_ref(raw: bytes) -> dict:
    doc = parse(raw)
    return {"schema_version": doc["schema_version"], "kind": doc["kind"],
            "id": doc["id"], "sha256": sha(raw)}


def make_instruction(incident: dict) -> bytes:
    check = incident.get("body", {}).get("failing_check", {})
    require(set(check) >= {"kind", "path", "expected_sha256"}
            and check["kind"] == "file-digest" and isinstance(check["path"], str)
            and check["path"] and "\n" not in check["path"] and c._sha(check["expected_sha256"]),
            "E_RELATION")
    return ("ystack.file-digest-instruction.v1\npath " + check["path"] + "\nsha256 "
            + check["expected_sha256"] + "\n").encode()


def core_modules(registry_raw: bytes) -> Path:
    registry = parse_value(registry_raw, OUTPUT_LIMIT)
    require(isinstance(registry, list) and registry, "E_RUNTIME")
    generation = registry[-1]["generation_id"]
    path = SOURCE / "core/v2/generations" / generation / "modules"
    require(path.is_dir() and path.resolve() == path, "E_RUNTIME")
    return path


def response_check(input_doc: dict, response_raw: bytes) -> bytes:
    response = parse(response_raw)
    stage_raw = canonical(response["stage_result"])
    payloads = response.get("payloads")
    require(isinstance(payloads, list) and len(payloads) == 1, "E_RELATION")
    receipt_text = payloads[0].get("data")
    require(isinstance(receipt_text, str), "E_RELATION")
    receipt_raw = receipt_text.encode()
    receipt = parse(receipt_raw)
    require(payloads[0].get("sha256") == sha(receipt_raw), "E_RELATION")
    return canonical({"input": input_doc, "response": response,
        "verified_receipt": {"content": receipt, "sha256": sha(receipt_raw)},
        "receipt_utf8": receipt_text, "stage_result_sha256": sha(stage_raw)})


def pair_ref(pair: dict) -> dict:
    content = pair.get("content")
    require(isinstance(content, dict) and set(pair) == {"content", "sha256"}
            and pair["sha256"] == sha(canonical(content)), "E_RELATION")
    return {"schema_version": content.get("schema_version"), "kind": content.get("kind"),
            "id": content.get("id"), "sha256": pair["sha256"]}


def validate_input_relations(input_doc: dict, incident: dict, claim: dict,
                             identity: dict, instruction: bytes) -> None:
    body = input_doc["stage_request"]["content"]["body"]
    revision = incident["body"]["git_revision_ref"]
    require(body.get("target_repository_id") == incident["body"]["target_repository_id"]
            and body.get("target_revision") == {"state": "present", "value": revision}
            and body.get("source", {}).get("value", {}).get("value", {}).get("revision") == revision,
            "E_RELATION")
    require(body.get("environment_ref") == {
        "environment_id": claim.get("id"), "fingerprint_sha256": sha(canonical(claim))},
        "E_RELATION")
    identity_body = identity.get("body")
    require(isinstance(identity_body, dict)
            and identity_body.get("stage_request_ref") == pair_ref(input_doc["stage_request"])
            and identity_body.get("resolved_profile_ref") == pair_ref(input_doc["resolved_profile"])
            and identity_body.get("verification_instructions_ref", {}).get("sha256") == sha(instruction),
            "E_RELATION")
    patch = [row for row in input_doc.get("payloads", [])
             if row.get("input_id") == "input.producer-patch"]
    verified = [row for row in input_doc.get("trust_context", {}).get("verified_payloads", [])
                if row.get("input_id") == "input.producer-patch"]
    require(len(patch) == 1 and len(verified) == 1 and patch[0].get("data") == ""
            and verified[0].get("content", {}).get("data") == "", "E_RELATION")


def require_no_change(response_raw: bytes, incident: dict) -> dict:
    response = parse(response_raw)
    result = response.get("stage_result", {}).get("body", {})
    receipt = parse(response["payloads"][0]["data"].encode())
    revision = incident["body"]["git_revision_ref"]
    source = receipt.get("source")
    candidate = receipt.get("candidate")
    require(isinstance(source, dict) and isinstance(candidate, dict)
            and result.get("outcome") == {"family": "change", "value": "no-change"}
            and receipt.get("changed_paths", {}).get("count") == 0
            and source == {"repository_id": incident["body"]["target_repository_id"],
                           "hash_algorithm": revision["hash_algorithm"],
                           "commit_id": revision["commit_id"], "tree_id": candidate.get("tree_id")}
            and candidate.get("commit_id") == revision["commit_id"]
            and candidate.get("parent_commit_id") == revision["commit_id"], "E_RELATION")
    return receipt


def make_launch(anchor: c.Anchor, request: dict, incident_raw: bytes, evaluation_raw: bytes,
                observation_raw: bytes, record_raw: bytes, manifest_raw: bytes,
                instruction: bytes) -> tuple[bytes, bytes]:
    context = {"environment_id": anchor.config["environment_id"], "store_id": anchor.config["store_id"],
               "registry": anchor.registry[1]}
    _launch_subject_values(context, incident_raw, record_raw, manifest_raw)
    _attempt_id = request["body"]["attempt_id"]
    controls = control(anchor, evaluation_raw)
    control_values = {"context": context, "control": controls}
    entropy = os.urandom(32)
    if hasattr(anchor, "retain_entropy"):
        role = {"shadow_write_request": "write", "shadow_enforced_request": "reproduction"}.get(request.get("kind"))
        if role is not None:
            anchor.retain_entropy(role, entropy)
    return _launch_values(canonical(request), incident_raw, evaluation_raw, observation_raw,
                          record_raw, manifest_raw, instruction, control_values, entropy)


def _launch_subject_values(context, incident_raw, record_raw, manifest_raw):
    incident = parse(incident_raw); prep = parse(record_raw)
    selected = [row for row in context["registry"] if row["environment_id"] == context["environment_id"]]
    require(len(selected) == 1, "E_RELATION")
    source, candidate = prep["source"], prep["candidate"]
    return {"environment_id": context["environment_id"],
        "environment_entry_sha256": sha(canonical(selected[0])),
        "target_repository_id": incident["body"]["target_repository_id"],
        "source": source, "candidate": {"preparation_record_sha256": sha(record_raw),
            "manifest_sha256": sha(manifest_raw), "commit_id": candidate["commit_id"],
            "tree_id": candidate["tree_id"]}, "incident_sha256": sha(incident_raw)}


def _launch_values(request_raw, incident_raw, evaluation_raw, observation_raw, record_raw, manifest_raw,
                    instruction, control_values, entropy):
    require(type(entropy) is bytes and len(entropy) == 32, "E_RELATION")
    request = parse(request_raw)
    context = control_values["context"]
    subject = _launch_subject_values(context, incident_raw, record_raw, manifest_raw)
    body = {"attempt": {"attempt_id": request["body"]["attempt_id"], "attempt_number": 1},
        "control": control_values["control"], "instruction_sha256": sha(instruction),
        "nonce": entropy.hex(), "store_id": context["store_id"], "subject": subject}
    launch = canonical({"schema_version": 1, "kind": "sandbox_launch_request",
                        "id": request["body"]["attempt_id"], "body": body})
    expectation_body = {"attempt": body["attempt"] | {"launch_request_sha256": sha(launch)},
                        "control": body["control"], "store_id": body["store_id"],
                        "subject": subject}
    expectation = canonical({"schema_version": 1, "kind": "sandbox_receipt_expectation",
        "id": request["body"]["attempt_id"], "body": expectation_body})
    return launch, expectation


def _native_launch(anchor: c.Anchor, frame: bytes, deadline: float) -> int:
    argv = ["/usr/bin/sudo", "-n", "-u", f"#{anchor.config['principal_uid']}", "--",
            sys.executable, str(Path(c.ANCHOR) / "host-supervisor.py"), "launch"]
    env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"}
    require(deadline > c._clock_value('shadow/v1/enforced-reproduction.py:1482:0',time.monotonic(),'monotonic'), "E_RUNTIME")
    remaining = min(180, deadline - c._clock_value('shadow/v1/enforced-reproduction.py:1483:0',time.monotonic(),'monotonic'))
    try:
        child, stdout, stderr = spawn_bounded("sandbox-launch-boundary", argv, frame, 0,
                                              STDERR_LIMIT, remaining, env)
    except Refusal:
        raise
    except (OSError, subprocess.SubprocessError):
        raise Refusal("E_RUNTIME") from None
    require(not stdout and len(stderr) <= STDERR_LIMIT, "E_LIMIT")
    return child.returncode


_launch: Callable[[c.Anchor, bytes, float], int] = _native_launch


def payload_result(snapshots: dict[str, bytes], manifest: dict, instruction: bytes,
                   preparation: dict, receipt: dict) -> tuple[bytes, dict]:
    require(snapshots["payload/stdout"] == b"" and snapshots["payload/stderr"] == b"",
            "E_RELATION")
    rows = manifest["body"]["files"]
    require(len(rows) == 1 and bytes.fromhex(rows[0]["name_hex"]) == b"file-digest-result.json",
            "E_RELATION")
    raw = snapshots["payload/evidence/0000"]
    result = parse(raw, 16 * 1024)
    require(set(rows[0]) == {"name_hex", "size_bytes", "sha256"}
            and integer(rows[0]["size_bytes"]) and rows[0]["size_bytes"] == len(raw)
            and rows[0]["sha256"] == sha(raw), "E_RELATION")
    body = receipt.get("body")
    require(isinstance(body, dict) and body.get("lifecycle", {}).get("admission") == "admitted"
            and body.get("lifecycle", {}).get("runtime") == "completed"
            and body.get("lifecycle", {}).get("control_deadline") == "met"
            and body.get("teardown", {}).get("state") == "confirmed"
            and body.get("payload", {}).get("exit_state") == "exited"
            and body.get("payload", {}).get("exit_code") == 0
            and body.get("payload", {}).get("stdout_sha256") == sha(snapshots["payload/stdout"])
            and body.get("payload", {}).get("stderr_sha256") == sha(snapshots["payload/stderr"])
            and body.get("payload", {}).get("evidence_manifest_sha256") == sha(canonical(manifest)),
            "E_RELATION")
    require(set(result) == {"schema_version", "kind", "id", "body"}
            and integer(result["schema_version"]) and result["schema_version"] == 1
            and result["kind"] == "file_digest_verifier_payload"
            and result["id"] == "file-digest-payload", "E_RELATION")
    check = result["body"]
    lines = instruction.decode().splitlines()
    expected_path, expected_sha = lines[1][5:], lines[2][7:]
    entries = {row["path"]: row for row in preparation.get("entries", [])}
    observed = check.get("observed")
    require(set(check) == {"check", "instruction_sha256", "observed", "outcome", "reason_id"}
            and expected_path in entries
            and check.get("check") == {"path": expected_path, "expected_sha256": expected_sha}
            and check.get("instruction_sha256") == sha(instruction)
            and isinstance(observed, dict) and set(observed) == {"sha256", "size_bytes"}
            and integer(observed["size_bytes"])
            and observed == {"sha256": entries[expected_path]["sha256"],
                             "size_bytes": entries[expected_path]["size_bytes"]}, "E_RELATION")
    require((check.get("outcome"), check.get("reason_id")) in
            (("match", "file.match"), ("mismatch", "file.mismatch"))
            and (check["outcome"] == "match") == (observed["sha256"] == expected_sha),
            "E_RELATION")
    return raw, check


def trace_ledger(incident: dict, attempt_id: str, environment_id: str, outcome: str,
                 tool: str | None, evaluation_raw: bytes, checker_raw: bytes) -> bytes:
    incident_ref = {"content_id": "shadow-incident-record",
        "media_type": "application/vnd.ystack.shadow-incident-record+json",
        "sha256": sha(canonical(incident))}
    unavailable = lambda reason: {"state": "unavailable", "reason_id": reason}
    evaluation_ref = {"content_id": "shadow-sandbox-evaluation",
        "media_type": "application/vnd.ystack.control-evaluation+json",
        "sha256": sha(evaluation_raw)}
    checker_ref = {"content_id": "shadow-sandbox-check", "media_type": "application/json",
        "sha256": sha(checker_raw)}
    recorded = lambda value, source=incident_ref: {
        "state": "recorded", "value": value, "source_ref": source}
    not_applicable = {"state": "not-applicable"}
    def facts(stage: str, result: str, tool_id: str | None) -> dict:
        source = evaluation_ref if stage == "stage.shadow-environment" else checker_ref
        return {"adapter": not_applicable, "cost_microunits": unavailable("cost.not-measured"),
            "execution_environment": recorded(environment_id, evaluation_ref),
            "gate": recorded("gate.sandbox-declaration" if source is evaluation_ref
                             else "gate.sandbox-enforcement", source),
            "identity": recorded(incident["body"]["reporter_actor_ref"]),
            "initiative": recorded(incident["id"]), "latency_ms": unavailable("latency.not-measured"),
            "result": recorded(result), "stage": recorded(stage), "status": recorded("status.completed"),
            "task_class": recorded("task.shadow-incident-reproduction"),
            "tool": recorded(tool_id) if tool_id else not_applicable,
            "workflow": recorded("workflow.shadow-incident-reproduction")}
    rows = [("event.shadow-environment", "shadow.environment-satisfied",
             facts("stage.shadow-environment", "result.environment-satisfied", None)),
            ("event.shadow-outcome", "shadow.outcome-recorded",
             facts("stage.shadow-reproduce", "result." + outcome, tool))]
    events, prior = [], None
    for sequence, (identity, event_type, values) in enumerate(rows):
        event = {"schema_version": 1, "kind": "telemetry_trace_event", "id": identity,
            "session_id": incident["id"], "attempt_id": attempt_id,
            "trace_id": "trace.shadow-enforced", "sequence": sequence, "prior_digest": prior,
            "occurred_at": incident["body"]["observed_at"], "event_type": event_type,
            "facts": values}
        prior = sha(canonical(event)); event["record_digest"] = prior; events.append(event)
    return canonical({"schema_version": 1, "kind": "telemetry_trace_ledger",
        "id": "shadow-enforced-trace-ledger", "body": {"session_id": incident["id"],
        "attempt_id": attempt_id, "trace_ids": ["trace.shadow-enforced"], "events": events,
        "seal": {"algorithm": "sha256", "canonicalization": "jq-1.6-sort-compact-line",
                 "event_count": len(events), "first_digest": events[0]["record_digest"],
                 "final_digest": events[-1]["record_digest"]}}})


def seal(output: Path, held_output: StableDirectory, files: dict[str, bytes],
         incident: dict, record_form: str) -> bytes:
    require(set(files) == set(EVIDENCE_NAMES), "E_RELATION")
    directory = held_output.held.fd
    rows = [{"name": name, "size_bytes": len(files[name]), "sha256": sha(files[name])}
            for name in sorted(files)]
    bundle = canonical({"schema_version": 1, "kind": "shadow_consumer_bundle",
        "id": "bundle." + sha(files["incident.json"])[:32], "body": {
            "activation_state": "inactive", "record_form": record_form,
            "incident_sha256": sha(files["incident.json"]),
            "target_revision": incident["body"]["git_revision_ref"], "files": rows}})
    for name in sorted(files):
        CancellationSignals.checkpoint()
        held_output.recheck("E_RELATION")
        write_exclusive_at(directory, name, files[name], sync=True)
    held_output.recheck("E_RELATION")
    require(set(os.listdir(directory)) == set(EVIDENCE_NAMES), "E_RELATION")
    os.fsync(directory)
    retained = CancellationSignals.retain_completion(directory)
    if retained is not True:
        raise Refusal("E_RUNTIME")
    CancellationSignals.prepare_completion(bundle)
    return bundle


def reproduce(request_path: Path, work: Path, output: Path, parent: dict | None = None) -> bytes:
    started = c._clock_value('shadow/v1/enforced-reproduction.py:1617:0',time.monotonic(),'monotonic'); deadline = started + OVERALL_SECONDS
    context = c.capture_parent_context() if parent is None else parent
    work_hold = output_hold = held_store = None
    helper = jq = anchor = bash = python_file = sudo_file = None
    inputs: list[InputSnapshot] = []
    sources: list[StableFile] = []
    try:
        request_source = stable_file(request_path, REQUEST_LIMIT, "E_SHAPE")
        sources.append(request_source); request_raw = request_source.raw
        request = parse(request_raw, REQUEST_LIMIT)
        require(set(request) == {"schema_version", "kind", "id", "body"}
                and integer(request["schema_version"]) and request["schema_version"] == 1
                and request["kind"] == "shadow_enforced_request"
                and c._id(request["id"]) and isinstance(request["body"], dict)
                and set(request["body"]) == REQUEST_BODY_KEYS
                and integer(request["body"]["attempt_number"])
                and request["body"]["attempt_number"] == 1
                and request["body"]["attempt_id"] == request["id"] and c._id(request["id"]), "E_SHAPE")
        paths = {key: Path(request["body"][key])
                 for key in REQUEST_BODY_KEYS - {"attempt_id", "attempt_number"}}
        require(all(path.is_absolute() and path.resolve() == path for path in paths.values()), "E_SHAPE")
        private_empty(work); private_empty(output)
        disjoint([request_path, work, output, *paths.values()])
        require(str(paths["closure_helper"]) == context["helper_path"], "E_RELATION")
        output_hold = stable_directory(output)
        work_hold = stable_directory(work)
        python_file = stable_file(Path(sys.executable))
        consumer_source = stable_file(SOURCE / "shadow/v1/_consumer.py")
        sources.append(consumer_source)
        commands: list[dict] = []
        def record_command(role: str, argv: list[str], executable_sha256: str,
                           component_sha256: str) -> None:
            commands.append({"role": role, "argv_sha256": sha(canonical(argv)),
                "executable_sha256": executable_sha256, "component_sha256": component_sha256})
        resolver = (_DarwinUUIDResolver(python_file, consumer_source, deadline, record_command)
                    if sys.platform == "darwin" else None)
        group_reader = _DarwinGroupReader(resolver) if resolver is not None else None
        anchor = c.load_anchor(resolver, group_reader)
        _bind_capture_completion_owner(anchor)
        _retain_native_runtime(anchor)
        exclusions = [SOURCE, request_path, Path(c.ANCHOR).parent, Path(anchor.config["store_root"]),
                      Path(anchor.config["work_root"]), *paths.values()]
        exclusions.extend(Path(value) for value in anchor.config["installed_files"].values())
        exclusions.extend(Path(value) for key, value in anchor.config["identity_paths"].items()
                          if key != "dyld_cache_files")
        exclusions.extend(Path(value) for value in anchor.config["identity_paths"]["dyld_cache_files"])
        outside([work, output], exclusions)
        names = ["dependencies", "inputs", "candidate", "materializer", "preparation-parent",
                 "preparation-scratch", "response", "response-check", "observation", "launch",
                 "receipt", "evaluation", "checker", "trace", "runtime"]
        for name in names:
            CancellationSignals.checkpoint()
            (work / name).mkdir(mode=0o700)
        deps = work / "dependencies"
        for name in ("helper", "jq"):
            (deps / name).mkdir(mode=0o700)
        for name in (REQUEST_BODY_KEYS - {"attempt_id", "attempt_number", "source_git_dir", "jq",
                                         "closure_helper"}):
            CancellationSignals.checkpoint()
            (work / "inputs" / name).mkdir(mode=0o700)
        helper = c.snapshot_dependency(str(paths["closure_helper"]), context["helper_executable_sha256"],
            context["helper_executable_size"], str(deps / "helper" / "object-closure"), "object-closure")
        jq = c.snapshot_jq(str(paths["jq"]), str(deps / "jq" / "jq"))
        bash = fixed_bash()
        sudo_file = fixed_sudo()
        helper_source = stable_file(SOURCE / "adapters/local-git-materializer/v1/object-closure.c")
        sources.append(helper_source)
        require(helper_source.sha256 == context["helper_source_sha256"], "E_DEPENDENCY")
        helper_source.recheck(); c.verify_helper_source(); helper.recheck(); record_command("helper-version", [helper.snapshot.path, "version"],
            helper.sha256, context["helper_source_sha256"])
        require(run_bounded("helper-version", [helper.snapshot.path, "version"],
                            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"},
                            timeout=10, deadline=deadline)
                == b"ystack-object-closure-v1\n", "E_DEPENDENCY")
        jq.recheck(); record_command("jq-version", [jq.snapshot.path, "--version"], jq.sha256, jq.sha256)
        require(run_bounded("jq-version", [jq.snapshot.path, "--version"],
                            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"},
                            timeout=10, deadline=deadline) == b"jq-1.6\n", "E_DEPENDENCY")
        captured = work / "inputs"
        limits = {"incident": OUTPUT_LIMIT, "claim": OUTPUT_LIMIT, "duty_evaluation": OUTPUT_LIMIT,
                  "qualified_identity": OUTPUT_LIMIT, "materialization_input": 8 * OUTPUT_LIMIT}
        mapped = {}
        for role, limit in limits.items():
            item = snapshot_input(paths[role], captured / role / (role + ".json"), limit)
            inputs.append(item); mapped[role] = item.path
        incident_raw = inputs[0].raw; incident = parse(incident_raw)
        claim_raw = inputs[1].raw; claim = parse(claim_raw); duty_raw = inputs[2].raw
        identity_raw = inputs[3].raw; input_raw = inputs[4].raw
        input_doc = parse(input_raw, 8 * OUTPUT_LIMIT)
        env = clean_env(Path(jq.snapshot.path), work / "runtime")
        registry_source = stable_file(SOURCE / "core/v2/generation-registry.json")
        sources.append(registry_source)
        modules = core_modules(registry_source.raw)
        protocol = SOURCE / "adapters/local-git-materializer/v1/protocol.jq"
        component_paths = {SOURCE / path for path in (
            "shadow/v1/_consumer.py", "shadow/v1/validate-incident.sh",
            "shadow/v1/qualified-identity.jq", "shadow/v1/incident-record.jq",
            "adapters/local-git-materializer/v1/materialize.sh",
            "adapters/local-git-materializer/v1/protocol.jq",
            "scripts/core-contract.sh",
            "preparation/v1/prepare-candidate.py", "control/v1/evaluate-bound-sandbox.sh",
            "control/v1/sandbox-bound-policy.json", "control/v1/sandbox-bound-decision.json",
            "control/v1/control-policy-set-sandbox-bound.json", "control/v1/sandbox-bound.jq",
            "control/v1/validate.sh", "control/v1/policy-set.jq",
            "enforcement/v1/check-sandbox-receipt.sh", "telemetry/v1/validate-trace-ledger.sh",
            "enforcement/v1/sandbox-receipt.jq", "telemetry/v1/trace-ledger.jq")}
        component_paths.add(Path(__file__))
        component_paths.update((modules.parent / "core-ingress.sh", modules.parent / "contracts.jq"))
        component_paths.update(modules.glob("*.jq"))
        component_files = {path: stable_file(path) for path in component_paths}
        sources.extend(component_files.values())
        def execute(role: str, argv: list[str], component: Path, **options: object) -> bytes:
            work_hold.recheck(); output_hold.recheck(); anchor.recheck(); helper.recheck(); jq.recheck()
            for item in inputs: item.recheck()
            for source in sources: source.recheck()
            source = component_files[component]
            if argv[0] == "/bin/bash":
                bash.recheck(); executable_sha = bash.physical.sha256; executable = bash
            elif argv[0] == jq.snapshot.path:
                executable_sha = jq.sha256; executable = jq
            elif argv[0] == sys.executable:
                python_file.recheck(); executable_sha = python_file.sha256; executable = python_file
            else:
                raise Refusal("E_DEPENDENCY")
            record_command(role, argv, executable_sha, source.sha256)
            result = run_bounded(role, argv, **options)
            executable.recheck(); helper.recheck(); jq.recheck()
            for source in sources: source.recheck()
            for item in inputs: item.recheck()
            work_hold.recheck(); output_hold.recheck()
            return result
        incident_validator = SOURCE / "shadow/v1/validate-incident.sh"
        execute("incident-validation", ["/bin/bash", "-p", str(incident_validator), "validate",
            str(mapped["incident"])], incident_validator, env=env, deadline=deadline)
        valid = execute("materializer-input-validation", [jq.snapshot.path, "-L", str(modules),
            "-e", "--arg", "command", "validate-input", "-f", str(protocol),
            str(mapped["materialization_input"])], protocol, env=env, deadline=deadline)
        require(valid.strip() == b"true", "E_RELATION")
        instruction = make_instruction(incident)
        revision = incident["body"]["git_revision_ref"]
        identity_source = SOURCE / "shadow/v1/qualified-identity.jq"
        identity_valid = execute("qualified-identity-validation", [jq.snapshot.path, "-L", str(modules),
            "-r", "--arg", "repository_id", incident["body"]["target_repository_id"],
            "--arg", "hash_algorithm", revision["hash_algorithm"], "--arg", "commit_id",
            revision["commit_id"], "-f", str(identity_source)], identity_source, stdin=identity_raw,
            env=env, deadline=deadline)
        require(identity_valid == b"", "E_RELATION")
        identity = parse(identity_raw)
        validate_input_relations(input_doc, incident, claim, identity, instruction)
        candidate = work / "candidate"; materializer_scratch = work / "materializer"
        target = incident["body"]["target_repository_id"]
        materializer = SOURCE / "adapters/local-git-materializer/v1/materialize.sh"
        response_raw = execute("materialization", ["/bin/bash", "-p", str(materializer),
            "materialize", str(mapped["materialization_input"]), target, str(paths["source_git_dir"]),
            str(candidate), str(materializer_scratch), helper.snapshot.path, jq.snapshot.path],
            materializer, timeout=120, env=env, deadline=deadline)
        response_path = work / "response/materialization-response.json"; write_exclusive(response_path, response_raw)
        check_raw = response_check(input_doc, response_raw); check_path = work / "response-check/response-check.json"
        write_exclusive(check_path, check_raw)
        checked = execute("materializer-response-validation", [jq.snapshot.path, "-L", str(modules), "-e", "--arg", "command",
            "validate-response", "-f", str(protocol), str(check_path)], protocol,
            env=env, deadline=deadline)
        require(checked.strip() == b"true", "E_RELATION")
        materializer_receipt = require_no_change(response_raw, incident)
        prep = work / "preparation-parent/preparation"; prep_scratch = work / "preparation-scratch"
        preparation_source = SOURCE / "preparation/v1/prepare-candidate.py"
        prepare = [sys.executable, "-I", "-S", "-B", str(preparation_source)]
        common = ["--input", str(mapped["materialization_input"]), "--input-sha256", sha(input_raw),
            "--response", str(response_path), "--response-sha256", sha(response_raw),
            "--candidate-repository", str(candidate / "repository.git"), "--output", str(prep),
            "--scratch", str(prep_scratch), "--jq", jq.snapshot.path]
        execute("candidate-preparation", prepare + ["prepare", *common], preparation_source,
                timeout=300, env=env, deadline=deadline)
        work_hold._retain_preparation(anchor,"preparation-scratch","prepare",input_raw,response_raw)
        for child in prep_scratch.iterdir():
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(child)
            else:
                child.unlink()
        execute("candidate-inspection", prepare + ["inspect", *common], preparation_source,
                timeout=300, env=env, deadline=deadline)
        work_hold._retain_preparation(anchor,"preparation-scratch","inspect",input_raw,response_raw)
        record_raw = read_regular(prep / "record.json", 64 * 1024)
        manifest_raw = read_regular(prep / "manifest.json", 2 * OUTPUT_LIMIT)
        manifest = parse(manifest_raw, 2 * OUTPUT_LIMIT)
        observation_raw = c.verifier_observation(anchor, anchor.config["environment_id"], target)
        observation_path = work / "observation/observation.json"; write_exclusive(observation_path, observation_raw)
        evaluator = SOURCE / "control/v1/evaluate-bound-sandbox.sh"
        evaluation_raw = execute("sandbox-bound-evaluation", ["/bin/bash", "-p", str(evaluator),
            "evaluate", str(mapped["duty_evaluation"]), str(mapped["claim"]), str(observation_path)],
            evaluator, env=env, deadline=deadline)
        evaluation = parse(evaluation_raw)
        require(evaluation["body"]["verdict"] == "satisfied", "E_RELATION")
        launch_raw, expectation_raw = make_launch(anchor, request, incident_raw, evaluation_raw,
            observation_raw, record_raw, manifest_raw, instruction)
        launch_path = work / "launch/sandbox-request.json"; expectation_path = work / "launch/sandbox-expectation.json"
        write_exclusive(launch_path, launch_raw, sync=True); write_exclusive(expectation_path, expectation_raw, sync=True)
        directory = os.open(launch_path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(directory)
        finally: os.close(directory)
        def records() -> Iterable[tuple[bytes, bytes]]:
            yield from ((b"request.json", launch_raw), (b"evaluation.json", evaluation_raw),
                (b"incident.json", incident_raw), (b"record.json", record_raw),
                (b"manifest.json", manifest_raw), (b"instruction", instruction))
            for index, row in enumerate(row for row in manifest["entries"] if row["kind"] == "file"):
                require(integer(row.get("size_bytes")) and row["size_bytes"] >= 0, "E_RELATION")
                raw = read_regular(prep / "candidate" / row["path"], row["size_bytes"], "E_RELATION")
                require(len(raw) == row["size_bytes"] and sha(raw) == row["sha256"], "E_RELATION")
                yield f"candidate/{index:05d}".encode(), raw
        frame = frame_write(records())
        anchor.recheck(); helper.recheck(); jq.recheck(); sudo_file.recheck(); python_file.recheck()
        native_argv = ["/usr/bin/sudo", "-n", "-u", f"#{anchor.config['principal_uid']}", "--",
            sys.executable, str(Path(c.ANCHOR) / "host-supervisor.py"), "launch"]
        supervisor = next(item for item in anchor.held if item.path == str(Path(c.ANCHOR) / "host-supervisor.py"))
        supervisor.recheck("E_RELATION")
        record_command("sandbox-launch-boundary", native_argv, sudo_file.sha256,
                       sha(supervisor.read(c.EXECUTABLE_LIMIT, "E_RELATION")))
        launch_status = _launch(anchor, frame, deadline)
        sudo_file.recheck(); python_file.recheck(); supervisor.recheck("E_RELATION")
        require(launch_status == 0, "E_RUNTIME")
        held_store = c._HeldStoreRead(anchor, request["id"])
        snapshots, origin_raw = held_store.snapshots, held_store.observation
        receipt_raw = snapshots["receipt.json"]
        receipt_path = work / "receipt/sandbox-receipt.json"; write_exclusive(receipt_path, receipt_raw)
        evaluation_path = work / "evaluation/sandbox-evaluation.json"; write_exclusive(evaluation_path, evaluation_raw)
        checker_source = SOURCE / "enforcement/v1/check-sandbox-receipt.sh"
        checker_raw = execute("sandbox-receipt-check", ["/bin/bash", "-p", str(checker_source),
            "check-bound", str(receipt_path), str(expectation_path), str(evaluation_path), str(observation_path)],
            checker_source, env=env, deadline=deadline)
        write_exclusive(work / "checker/sandbox-check.json", checker_raw)
        checker = parse(checker_raw)
        require(checker["body"]["check_verdict"] == "valid"
                and checker["body"]["enforcement_verdict"] == "satisfied",
                "E_RELATION")
        if held_store.record_reproduction(request_raw, launch_raw, expectation_raw) is not None:
            try:
                held_store.copy_capture(work_hold._recording_parent(), launch_raw, "reproduction", anchor.recording_work)
            except (Refusal,c.Refusal, OSError, MemoryError):
                anchor.private_observations["unusable"] = True
        evidence_manifest_raw = snapshots["payload/evidence-manifest.json"]
        evidence_manifest = parse(evidence_manifest_raw)
        result_raw, result = payload_result(snapshots, evidence_manifest, instruction, manifest,
                                            parse(receipt_raw))
        outcome = "no-change" if result["outcome"] == "match" else "reproduced"
        trace_raw = trace_ledger(incident, request["id"], claim["id"], outcome,
                                 "tool.verifier", evaluation_raw, checker_raw)
        trace_path = work / "trace/trace-ledger.json"; write_exclusive(trace_path, trace_raw)
        trace_validator = SOURCE / "telemetry/v1/validate-trace-ledger.sh"
        trace_receipt_raw = execute("trace-validation", ["/bin/bash", "-p",
            str(trace_validator), "validate", incident["id"], request["id"], str(trace_path)],
            trace_validator, env=env, deadline=deadline)
        anchor.recheck(); helper.recheck(); jq.recheck(); bash.recheck(); python_file.recheck()
        sudo_file.recheck()
        active_native = (CancellationSignals.active.native
                         if CancellationSignals.active is not None else None)
        require(isinstance(active_native, _NativeRelease), "E_RUNTIME")
        active_native.recheck()
        provenance = canonical({"schema_version": 1, "kind": "shadow_consumer_provenance",
            "id": request["id"], "body": {"activation_state": "inactive", "authority": "none",
            "instruction_utf8": instruction.decode(), "instruction_sha256": sha(instruction),
            "observation": parse(observation_raw), "observation_sha256": sha(observation_raw),
            "helper_source_sha256": context["helper_source_sha256"],
            "helper_build_record_sha256": context["helper_build_record_sha256"],
            "helper_executable_sha256": context["helper_executable_sha256"],
            "consumer_source_sha256": component_files[Path(__file__)].sha256,
            "python_sha256": python_file.sha256,
            "jq_sha256": jq.sha256, "native_release": active_native.provenance(context),
            "commands": commands}})
        identity_ref = {"content_id": "shadow-qualified-identity",
            "media_type": "application/vnd.ystack.qualified-identity+json", "sha256": sha(identity_raw)}
        evaluation_section = {"state": "present", "value": {
            "verdict": evaluation["body"]["verdict"], "reason_ids": evaluation["body"]["reason_ids"],
            "evaluation_ref": {"content_id": "shadow-sandbox-evaluation",
                "media_type": "application/vnd.ystack.control-evaluation+json",
                "sha256": sha(evaluation_raw)}}}
        stage_result = parse(response_raw)["stage_result"]
        materialization = {"state": "present", "value": {
            "adapter_id": "adapter.local-git-materializer.v1",
            "outcome": stage_result["body"]["outcome"]["value"],
            "source": materializer_receipt["source"], "candidate": materializer_receipt["candidate"],
            "stage_result_ref": {"schema_version": 2, "kind": "stage_result",
                "id": stage_result["id"], "sha256": sha(canonical(stage_result))}}}
        execution = {"state": "present", "value": {"tool_id": "tool.verifier",
            "observed_sha256": result["observed"]["sha256"],
            "matches_expected": result["outcome"] == "match"}}
        record = canonical({"schema_version": 1, "kind": "shadow_reproduction_record",
            "id": incident["id"], "body": {"record_form": "enforced-reproduction.v1",
            "activation_state": "inactive", "authority": "none", "deploy_authority": "none",
            "effects": ["caller-disposable-candidate-repository"],
            "evaluation_mode": "observation-only", "shadow": True,
            "qualification": {"state": "unavailable", "reason_id": "shadow.unqualified"},
            "outcome": outcome, "reason_id": ("check.passed-at-revision" if outcome == "no-change"
                                                 else "check.failed-at-revision"),
            "observed_at": incident["body"]["observed_at"],
            "target_repository_id": incident["body"]["target_repository_id"],
            "git_revision_ref": incident["body"]["git_revision_ref"],
            "qualified_identity": identity["body"], "qualified_identity_ref": identity_ref,
            "incident_ref": {"content_id": "shadow-incident-record",
                "media_type": "application/vnd.ystack.shadow-incident-record+json",
                "sha256": sha(incident_raw)},
            "environment": {"environment_id": parse(claim_raw)["id"],
                "claim_ref": {"content_id": "shadow-environment-claim",
                    "media_type": "application/vnd.ystack.control-execution-environment-claim+json",
                    "sha256": sha(claim_raw)},
                "registry_ref": {"content_id": "shadow-environment-registry",
                    "media_type": "application/vnd.ystack.shadow-environment-registry+json",
                    "sha256": sha(anchor.installed["registry"][0])}, "evaluation": evaluation_section},
            "materialization": materialization,
            "check": {"failing_check": incident["body"]["failing_check"], "execution": execution},
            "sandbox": {"state": "satisfied", "reason_id": "shadow.sandbox-satisfied",
                "launch_request_ref": document_ref(launch_raw), "expectation_ref": document_ref(expectation_raw),
                "receipt_ref": document_ref(receipt_raw), "check_ref": document_ref(checker_raw),
                "origin": {"state": "authenticated", "store_id": anchor.config["store_id"],
                    "method": "controlled-storage.v1", "observation_sha256": sha(origin_raw)},
                "payload_ref": {"content_id": "file-digest-result", "media_type": "application/json",
                                "sha256": sha(result_raw)}}, "producer_invocations": 0,
            "consumer_provenance_ref": document_ref(provenance),
            "trace_ledger_ref": {"content_id": "shadow-trace-ledger",
                "media_type": "application/vnd.ystack.telemetry-trace-ledger+json",
                "sha256": sha(trace_raw)}}})
        files = {"incident.json": incident_raw, "claim.json": claim_raw,
            "duty-evaluation.json": duty_raw, "materialization-input.json": input_raw,
            "materialization-response.json": response_raw, "qualified-identity.json": identity_raw,
            "preparation-record.json": record_raw, "preparation-manifest.json": manifest_raw,
            "sandbox-evaluation.json": evaluation_raw, "sandbox-request.json": launch_raw,
            "sandbox-expectation.json": expectation_raw, "sandbox-receipt.json": receipt_raw,
            "sandbox-check.json": checker_raw, "origin-observation.json": origin_raw,
            "payload-stdout.txt": snapshots["payload/stdout"], "payload-stderr.txt": snapshots["payload/stderr"],
            "evidence-manifest.json": evidence_manifest_raw, "file-digest-result.json": result_raw,
            "evaluator-driver.txt": anchor.installed["evaluator_driver"][0],
            "evaluator-program.txt": anchor.installed["evaluator_program"][0],
            "policy.json": anchor.installed["control_policy"][0],
            "decision.json": anchor.installed["control_decision"][0],
            "policy-set.json": anchor.installed["control_policy_set"][0],
            "accepted-identities.json": anchor.installed["accepted_set"][0],
            "registry.json": anchor.installed["registry"][0], "consumer-provenance.json": provenance,
            "shadow-record.json": record, "trace-ledger.json": trace_raw,
            "trace-receipt.json": trace_receipt_raw}
        anchor.seal_recheck(); helper.recheck(); jq.recheck(); bash.recheck(); python_file.recheck()
        sudo_file.recheck()
        active_native.recheck()
        work_hold.recheck(); output_hold.recheck()
        for source in sources: source.recheck()
        for item in inputs: item.recheck()
        held_store.recheck()
        return seal(output, output_hold, files, incident, "enforced-reproduction.v1")
    finally:
        close_all([*reversed(inputs), *reversed(sources), python_file, sudo_file, bash,
                   held_store, anchor, jq, helper, work_hold, output_hold])


def main(argv: list[str], admission: _StartupAdmission | None = None) -> int:
    native = None
    owner = None
    capture_owner = None
    try:
        require(isinstance(admission, _StartupAdmission) and admission.key is _STARTUP_KEY,
                "E_RUNTIME")
        require(len(argv) == 5 and argv[1] == "reproduce", "E_USAGE")
        context = c.capture_parent_context()
        native = _NativeRelease(context, admission)
        capture_owner = _load_capture_completion_owner()
        admission = dataclasses.replace(admission, native=native,
                                        capture_owner=capture_owner,
                                        module_origins=_runtime_module_origins())
        owner = CancellationSignals(admission)
        with owner:
            try:
                reproduce(Path(argv[2]), Path(argv[3]), Path(argv[4]), parent=context)
            except BaseException as exc:
                closing = native
                native = None
                try:
                    closing.close()
                except BaseException as close_exc:
                    raise exc from close_exc
                raise
            closing = native
            native = None
            closing.close()
        return 0
    except BaseException as exc:
        if owner is not None and owner.caller_exception is exc:
            raise
        if isinstance(exc, Cancelled):
            print("E_RUNTIME", file=sys.stderr); return 1
        if isinstance(exc, (Refusal, c.Refusal)):
            print(exc.code if exc.code in {"E_USAGE", "E_RUNTIME", "E_LIMIT", "E_SHAPE",
                  "E_CANONICAL", "E_RELATION", "E_WORKSPACE", "E_PARENT_CONTEXT"}
                  else "E_RUNTIME", file=sys.stderr)
            return 1
        if isinstance(exc, (KeyError, TypeError, ValueError, OSError, json.JSONDecodeError)):
            print("E_RUNTIME", file=sys.stderr); return 1
        raise
    finally:
        try:
            if native is not None:
                native.close()
        finally:
            _close_capture_completion_owner(capture_owner)


if __name__ == "__main__":
    try:
        startup_admission = _standalone_startup_admission()
    except Exception:
        print("E_RUNTIME", file=sys.stderr)
        raise SystemExit(1) from None
    raise SystemExit(main(sys.argv, startup_admission))
