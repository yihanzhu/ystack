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
        path = Path(origin)
        require(path.is_absolute(), "E_RUNTIME")
        resolved = path.resolve(strict=True)
        require(_path_below(resolved, stdlib) or resolved in {driver, consumer}, "E_RUNTIME")
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

    @property
    def sha256(self) -> str:
        return sha(self.raw)

    def recheck(self, code: str = "E_RELATION") -> None:
        self.held.recheck(code)
        require(self.held.read(len(self.raw), code) == self.raw, code)

    def close(self) -> None:
        self.held.close()


@dataclasses.dataclass
class StableDirectory:
    held: c.HeldPath

    def recheck(self, code: str = "E_WORKSPACE") -> None:
        for index, component in enumerate(self.held.components):
            current = c._metadata(component.fd)
            named = (current if component.name is None else
                     c._named_metadata(component.name, self.held.components[index - 1].fd))
            if index + 1 == len(self.held.components):
                stable = lambda value: (value.st_dev, value.st_ino, value.st_uid, value.st_gid,
                                        value.st_mode & 0o170777)
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
                code: str = "E_DEPENDENCY") -> StableFile:
    held = c._open_held(str(path), False, lambda _fd, _state, _ancestor: True, code)
    try:
        raw = held.read(limit, code)
        result = StableFile(held, raw)
        result.recheck(code)
        return result
    except BaseException:
        held.close()
        raise


class _DarwinUUIDResolver(c._DarwinUUIDResolver):
    def __init__(self, python: StableFile, source: StableFile, deadline: float) -> None:
        self.python = python
        self.source = source
        self.deadline = deadline
        expected_source = (SOURCE / "shadow/v1/_consumer.py").resolve(strict=True)
        require(Path(self.python.held.path) == Path(sys.executable)
                and Path(self.source.held.path) == expected_source, "E_DEPENDENCY")
        self.recheck()

    def recheck(self) -> None:
        self.python.recheck("E_DEPENDENCY")
        self.source.recheck("E_DEPENDENCY")
        require(Path(sys.executable).resolve(strict=True) == Path(self.python.held.path)
                and (SOURCE / "shadow/v1/_consumer.py").resolve(strict=True)
                == Path(self.source.held.path), "E_DEPENDENCY")

    def resolve(self, uuids: list[str]) -> list[dict]:
        require(len(uuids) <= c.DARWIN_UUID_COUNT_LIMIT
                and all(c._uuid_hex(value) for value in uuids), "E_ACL")
        if not uuids:
            return []
        self.recheck()
        argv = [str(self.python.held.path), "-I", "-S", "-B", str(self.source.held.path),
                "_resolve-darwin-uuids"]
        env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"}
        output = run_bounded(argv, stdin=c.canonical(uuids), timeout=10,
                             output_limit=c.DARWIN_UUID_OUTPUT_LIMIT, env=env,
                             deadline=self.deadline)
        self.recheck()
        rows = c._json_array(output, c.DARWIN_UUID_OUTPUT_LIMIT, "E_ACL")
        require(len(rows) == len(uuids), "E_ACL")
        for uuid, row in zip(uuids, rows):
            require(isinstance(row, dict) and set(row) == {"uuid", "status", "kind", "id"}
                    and row["uuid"] == uuid, "E_ACL")
            if row["status"] == "resolved":
                require(row["kind"] in ("user", "group") and integer(row["id"])
                        and 0 <= row["id"] <= 0xffffffff, "E_ACL")
            else:
                require(row["status"] == "unresolved" and row["kind"] is None
                        and row["id"] is None, "E_ACL")
        return rows


def stable_directory(path: Path) -> StableDirectory:
    held = c._open_held(str(path), True,
        lambda _fd, state, ancestor: ancestor or (state.st_mode & 0o777) == 0o700,
        "E_WORKSPACE")
    result = StableDirectory(held)
    result.recheck()
    return result


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


def run_bounded(argv: list[str], *, stdin: bytes = b"", timeout: int = 120,
                output_limit: int = OUTPUT_LIMIT, env: dict[str, str],
                deadline: float | None = None) -> bytes:
    require(all(isinstance(item, str) and item for item in argv), "E_RUNTIME")
    if deadline is not None:
        require(deadline > time.monotonic(), "E_RUNTIME")
    remaining = timeout if deadline is None else min(timeout, deadline - time.monotonic())
    try:
        child, stdout, stderr = spawn_bounded(argv, stdin, output_limit, STDERR_LIMIT,
                                               remaining, env)
    except (OSError, subprocess.SubprocessError):
        raise Refusal("E_RUNTIME") from None
    require(len(stdout) <= output_limit and len(stderr) <= STDERR_LIMIT, "E_LIMIT")
    require(child.returncode == 0 and not stderr, "E_RUNTIME")
    return stdout


def _stop_child(child: subprocess.Popen) -> None:
    end = time.monotonic() + 10
    for sent in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(child.pid, sent)
        except ProcessLookupError:
            pass
        boundary = end if sent == signal.SIGKILL else min(end, time.monotonic() + 5)
        while time.monotonic() < boundary:
            child.poll()
            try:
                os.killpg(child.pid, 0)
            except ProcessLookupError:
                if child.poll() is None:
                    child.wait(timeout=max(0.001, end - time.monotonic()))
                return
            except PermissionError:
                time.sleep(min(0.02, boundary - time.monotonic()))
                continue
            time.sleep(min(0.02, boundary - time.monotonic()))
    try:
        os.killpg(child.pid, 0)
    except ProcessLookupError:
        if child.poll() is None:
            child.wait(timeout=max(0.001, end - time.monotonic()))
        return
    raise Refusal("E_RUNTIME")


def stop_child(child: subprocess.Popen) -> None:
    previous = signal.pthread_sigmask(signal.SIG_BLOCK,
                                      {signal.SIGTERM, signal.SIGHUP, signal.SIGINT})
    try:
        _stop_child(child)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def spawn_bounded(argv: list[str], input_raw: bytes, stdout_limit: int, stderr_limit: int,
                  timeout: float, env: dict[str, str]) -> tuple[subprocess.Popen, bytes, bytes]:
    CancellationSignals.checkpoint()
    child = None
    try:
        child = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, env=env, close_fds=True,
                                 start_new_session=True)
        CancellationSignals.checkpoint()
        stdout, stderr = communicate_bounded(child, input_raw, stdout_limit, stderr_limit,
                                              timeout, cleanup=False)
        return child, stdout, stderr
    except BaseException:
        if child is not None:
            stop_child(child)
        raise


def communicate_bounded(child: subprocess.Popen, input_raw: bytes, stdout_limit: int,
                        stderr_limit: int, timeout: float, *,
                        cleanup: bool = True) -> tuple[bytes, bytes]:
    selector = None
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
        sent = 0; end = time.monotonic() + timeout
        while selector.get_map():
            CancellationSignals.checkpoint()
            remaining = end - time.monotonic()
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
            child.wait(timeout=max(0.001, end - time.monotonic()))
        except subprocess.TimeoutExpired:
            raise Refusal("E_RUNTIME") from None
        CancellationSignals.checkpoint()
        return bytes(output[stdout_fd]), bytes(output[stderr_fd])
    except BaseException:
        if cleanup:
            stop_child(child)
        raise
    finally:
        if selector is not None:
            selector.close()
        for stream in (child.stdin, child.stdout, child.stderr):
            if stream is not None and not stream.closed:
                stream.close()


class CancellationSignals:
    active: CancellationSignals | None = None

    def __init__(self, admission: _StartupAdmission | None = None) -> None:
        self.admission = admission
        self.previous: dict[int, object] = {}
        self.requested = False
        self.parent: CancellationSignals | None = None
        self.completion: int | None = None
        self.read_fd: int | None = None
        self.write_fd: int | None = None
        self.borrowed = False
        self.rollback_attempted = False
        self.borrow_depth = 0

    @classmethod
    def checkpoint(cls) -> None:
        if cls.active is not None and cls.active.requested:
            raise Cancelled()

    @classmethod
    def retain_completion(cls, directory: int) -> bool:
        if cls.active is None:
            return False
        require(cls.active.borrow_depth == 0, "E_RUNTIME")
        require(cls.active.completion is None, "E_RUNTIME")
        cls.active.completion = directory
        return True

    @staticmethod
    def _remember(first: BaseException | None, exc: BaseException) -> BaseException:
        return first if first is not None else exc

    def _rollback(self, failure: BaseException | None) -> BaseException | None:
        if self.completion is None or self.rollback_attempted:
            return failure
        self.rollback_attempted = True
        try:
            os.unlink("bundle.json", dir_fd=self.completion)
        except BaseException as exc:
            failure = self._remember(failure, exc)
        try:
            os.fsync(self.completion)
        except BaseException as exc:
            failure = self._remember(failure, exc)
        return failure

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
                and self.admission.module_origins == _runtime_module_origins(), "E_RUNTIME")
        held_executable = stable_file(Path(self.admission.executable))
        try:
            require(held_executable.sha256 == self.admission.executable_sha256, "E_RUNTIME")
            held_executable.recheck("E_RUNTIME")
        finally:
            held_executable.close()
        self.admission.census.observe()

        def cancel(_signum: int, _frame: object) -> None:
            self.requested = True

        original_mask = None
        installed_handlers: list[int] = []
        wakeup_installed = False
        failure = None
        try:
            original_mask = signal.pthread_sigmask(signal.SIG_BLOCK, WATCHED_SIGNALS)
            for sent in WATCHED_SIGNALS:
                self.previous[sent] = signal.getsignal(sent)
            self.read_fd, self.write_fd = os.pipe()
            for descriptor in (self.read_fd, self.write_fd):
                os.set_blocking(descriptor, False)
                os.set_inheritable(descriptor, False)
            prior = signal.set_wakeup_fd(self.write_fd, warn_on_full_buffer=False)
            wakeup_installed = True
            require(prior == -1, "E_RUNTIME")
            for sent in WATCHED_SIGNALS:
                signal.signal(sent, cancel)
                installed_handlers.append(sent)
            self.parent = CancellationSignals.active
            CancellationSignals.active = self
            signal.pthread_sigmask(signal.SIG_SETMASK, original_mask)
            return self
        except BaseException as exc:
            failure = exc
            for sent in reversed(installed_handlers):
                try:
                    signal.signal(sent, self.previous[sent])
                except BaseException as release_exc:
                    failure = self._remember(failure, release_exc)
            if wakeup_installed:
                try:
                    signal.set_wakeup_fd(-1, warn_on_full_buffer=True)
                except BaseException as release_exc:
                    failure = self._remember(failure, release_exc)
            CancellationSignals.active = self.parent
            for descriptor in (self.write_fd, self.read_fd):
                if descriptor is not None:
                    try:
                        os.close(descriptor)
                    except BaseException as release_exc:
                        failure = self._remember(failure, release_exc)
            if original_mask is not None:
                try:
                    signal.pthread_sigmask(signal.SIG_SETMASK, original_mask)
                except BaseException as release_exc:
                    failure = self._remember(failure, release_exc)
            raise failure

    def __exit__(self, kind: object, _value: object, _traceback: object) -> None:
        if self.borrowed:
            require(self.parent is not None and self.parent.borrow_depth > 0, "E_RUNTIME")
            self.parent.borrow_depth -= 1
            return
        failure = None
        caller_mask = None
        uncertain = False
        pending: set[signal.Signals] = set()
        decision_made = False
        abort = True
        try:
            caller_mask = signal.pthread_sigmask(signal.SIG_BLOCK, WATCHED_SIGNALS)
            try:
                require(self.admission is not None, "E_RUNTIME")
                self.admission.census.observe()
            except BaseException as exc:
                failure = exc
            try:
                require(self.read_fd is not None, "E_RUNTIME")
                observed = os.read(self.read_fd, 1)
                uncertain = True
                if observed:
                    self.requested = True
            except OSError as exc:
                if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                    uncertain = True
                    failure = self._remember(failure, exc)
            except BaseException as exc:
                uncertain = True
                failure = self._remember(failure, exc)
            try:
                pending = set(signal.sigpending()) & WATCHED_SIGNALS
            except BaseException as exc:
                failure = self._remember(failure, exc)
            abort = kind is not None or self.requested or uncertain or bool(pending) or failure is not None
            decision_made = True
            if abort:
                failure = self._rollback(failure)
        except BaseException as exc:
            failure = self._remember(failure, exc)
            failure = self._rollback(failure)
        finally:
            for sent in WATCHED_SIGNALS:
                try:
                    signal.signal(sent, self.previous[sent])
                except BaseException as exc:
                    failure = self._remember(failure, exc)
            try:
                signal.set_wakeup_fd(-1, warn_on_full_buffer=True)
            except BaseException as exc:
                failure = self._remember(failure, exc)
            CancellationSignals.active = self.parent
            for descriptor in (self.write_fd, self.read_fd):
                if descriptor is not None:
                    try:
                        os.close(descriptor)
                    except BaseException as exc:
                        failure = self._remember(failure, exc)
            if failure is not None and decision_made and not abort:
                failure = self._rollback(failure)
                abort = True
            post_l_exception = None
            if caller_mask is not None:
                try:
                    signal.pthread_sigmask(signal.SIG_SETMASK, caller_mask)
                except OSError as exc:
                    failure = self._remember(failure, exc)
                    abort = True
                    failure = self._rollback(failure)
                except BaseException as exc:
                    post_l_exception = exc
            if self.completion is not None:
                try:
                    os.close(self.completion)
                except BaseException as exc:
                    failure = self._remember(failure, exc)
                    abort = True
                    failure = self._rollback(failure)
            if post_l_exception is not None and failure is None:
                raise post_l_exception
        if failure is not None:
            raise failure
        if kind is None and abort:
            raise Cancelled()


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
    return {name.removeprefix("control_") + "_sha256": anchor.installed[name][1]
            for name in names} | {"sandbox_evaluation_sha256": sha(evaluation_raw)}


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
    incident = parse(incident_raw); prep = parse(record_raw)
    selected = [row for row in anchor.registry[1]
                if row["environment_id"] == anchor.config["environment_id"]]
    require(len(selected) == 1, "E_RELATION")
    source, candidate = prep["source"], prep["candidate"]
    subject = {"environment_id": anchor.config["environment_id"],
        "environment_entry_sha256": sha(canonical(selected[0])),
        "target_repository_id": incident["body"]["target_repository_id"],
        "source": source, "candidate": {"preparation_record_sha256": sha(record_raw),
            "manifest_sha256": sha(manifest_raw), "commit_id": candidate["commit_id"],
            "tree_id": candidate["tree_id"]}, "incident_sha256": sha(incident_raw)}
    body = {"attempt": {"attempt_id": request["body"]["attempt_id"], "attempt_number": 1},
        "control": control(anchor, evaluation_raw), "instruction_sha256": sha(instruction),
        "nonce": os.urandom(32).hex(), "store_id": anchor.config["store_id"], "subject": subject}
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
    require(deadline > time.monotonic(), "E_RUNTIME")
    remaining = min(180, deadline - time.monotonic())
    try:
        child, stdout, stderr = spawn_bounded(argv, frame, 0, STDERR_LIMIT, remaining, env)
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
    directory = os.dup(held_output.held.fd)
    rows = [{"name": name, "size_bytes": len(files[name]), "sha256": sha(files[name])}
            for name in sorted(files)]
    bundle = canonical({"schema_version": 1, "kind": "shadow_consumer_bundle",
        "id": "bundle." + sha(files["incident.json"])[:32], "body": {
            "activation_state": "inactive", "record_form": record_form,
            "incident_sha256": sha(files["incident.json"]),
            "target_revision": incident["body"]["git_revision_ref"], "files": rows}})
    marker_written = False
    retained = False
    try:
        for name in sorted(files):
            CancellationSignals.checkpoint()
            held_output.recheck("E_RELATION")
            write_exclusive_at(directory, name, files[name], sync=True)
        held_output.recheck("E_RELATION")
        require(set(os.listdir(directory)) == set(EVIDENCE_NAMES), "E_RELATION")
        os.fsync(directory)
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK,
                                               {signal.SIGTERM, signal.SIGHUP, signal.SIGINT})
        try:
            write_exclusive_at(directory, "bundle.json", bundle, sync=True, remove_on_failure=True)
            marker_written = True
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        CancellationSignals.checkpoint()
        held_output.recheck("E_RELATION")
        require(set(os.listdir(directory)) == set(EVIDENCE_NAMES) | {"bundle.json"}, "E_RELATION")
        os.fsync(directory)
        CancellationSignals.checkpoint()
        retained = CancellationSignals.retain_completion(directory)
    except BaseException as exc:
        if marker_written:
            try:
                os.unlink("bundle.json", dir_fd=directory)
                os.fsync(directory)
            except OSError:
                pass
        if isinstance(exc, OSError):
            raise Refusal("E_RUNTIME") from None
        raise
    finally:
        if not retained:
            os.close(directory)
    return bundle


def reproduce(request_path: Path, work: Path, output: Path, parent: dict | None = None) -> bytes:
    started = time.monotonic(); deadline = started + OVERALL_SECONDS
    context = c.capture_parent_context() if parent is None else parent
    work_hold = output_hold = None
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
        resolver = (_DarwinUUIDResolver(python_file, consumer_source, deadline)
                    if sys.platform == "darwin" else None)
        anchor = c.load_anchor(resolver)
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
        commands: list[dict] = []
        def record_command(role: str, argv: list[str], executable_sha256: str,
                           component_sha256: str) -> None:
            commands.append({"role": role, "argv_sha256": sha(canonical(argv)),
                "executable_sha256": executable_sha256, "component_sha256": component_sha256})
        helper_source.recheck(); c.verify_helper_source(); helper.recheck(); record_command("helper-version", [helper.snapshot.path, "version"],
            helper.sha256, context["helper_source_sha256"])
        c.probe_dependency(helper, ["version"], b"ystack-object-closure-v1\n")
        jq.recheck(); record_command("jq-version", [jq.snapshot.path, "--version"], jq.sha256, jq.sha256)
        c.probe_dependency(jq, ["--version"], b"jq-1.6\n")
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
            result = run_bounded(argv, **options)
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
        for child in prep_scratch.iterdir():
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(child)
            else:
                child.unlink()
        execute("candidate-inspection", prepare + ["inspect", *common], preparation_source,
                timeout=300, env=env, deadline=deadline)
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
            for index, row in enumerate(manifest["entries"]):
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
        snapshots, origin_raw = c.read_store_attempt(anchor, request["id"])
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
        provenance = canonical({"schema_version": 1, "kind": "shadow_consumer_provenance",
            "id": request["id"], "body": {"activation_state": "inactive", "authority": "none",
            "instruction_utf8": instruction.decode(), "instruction_sha256": sha(instruction),
            "observation": parse(observation_raw), "observation_sha256": sha(observation_raw),
            "helper_source_sha256": context["helper_source_sha256"],
            "helper_build_record_sha256": context["helper_build_record_sha256"],
            "helper_executable_sha256": context["helper_executable_sha256"],
            "consumer_source_sha256": component_files[Path(__file__)].sha256,
            "python_sha256": python_file.sha256,
            "jq_sha256": jq.sha256, "commands": commands}})
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
        anchor.recheck(); helper.recheck(); jq.recheck(); bash.recheck(); python_file.recheck()
        sudo_file.recheck()
        work_hold.recheck(); output_hold.recheck()
        for source in sources: source.recheck()
        for item in inputs: item.recheck()
        return seal(output, output_hold, files, incident, "enforced-reproduction.v1")
    finally:
        for item in reversed(inputs): item.close()
        for source in reversed(sources): source.close()
        if python_file is not None: python_file.close()
        if sudo_file is not None: sudo_file.close()
        if bash is not None: bash.close()
        if anchor is not None: anchor.close()
        if jq is not None: jq.close()
        if helper is not None: helper.close()
        if work_hold is not None: work_hold.close()
        if output_hold is not None: output_hold.close()


def main(argv: list[str], admission: _StartupAdmission | None = None) -> int:
    try:
        require(isinstance(admission, _StartupAdmission) and admission.key is _STARTUP_KEY,
                "E_RUNTIME")
        require(len(argv) == 5 and argv[1] == "reproduce", "E_USAGE")
        with CancellationSignals(admission):
            reproduce(Path(argv[2]), Path(argv[3]), Path(argv[4]))
        return 0
    except Cancelled:
        print("E_RUNTIME", file=sys.stderr); return 1
    except (Refusal, c.Refusal) as exc:
        print(exc.code if exc.code in {"E_USAGE", "E_RUNTIME", "E_LIMIT", "E_SHAPE",
              "E_CANONICAL", "E_RELATION", "E_WORKSPACE"} else "E_RUNTIME", file=sys.stderr)
        return 1
    except (KeyError, TypeError, ValueError, OSError, json.JSONDecodeError):
        print("E_RUNTIME", file=sys.stderr); return 1


if __name__ == "__main__":
    try:
        startup_admission = _standalone_startup_admission()
    except Exception:
        print("E_RUNTIME", file=sys.stderr)
        raise SystemExit(1) from None
    raise SystemExit(main(sys.argv, startup_admission))
