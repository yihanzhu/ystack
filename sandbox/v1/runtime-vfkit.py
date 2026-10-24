#!/usr/bin/python3
"""runtime-vfkit.py -- vfkit runtime driver (ystack #463, PR 8 of 9).

Implements plan.md's fixed driver interface, unchanged, as the fake runtime
does: `argv <start.json>`, `state <socket>`, `stop <socket>`. Run by
host-supervisor.py under an empty environment, stdin /dev/null. The
executable named in `argv[0]` is `runtime.vfkit` of the host-config.json
installed beside this file. Never run by any test against a real vfkit.
"""
import http.client
import json
import os
import socket
import sys

COMMAND_LINE = "console= quiet lsm=landlock rdinit=/init"
MEMORY_BYTES = 536870912
SOCKET_PATH_MAX = 103  # vfkit refuses a longer Unix path (pkg/rest/rest.go:17-21,141-142)
START_KEYS = {"command_line", "cpu_count", "export_disk", "initramfs", "input_disk", "kernel",
              "memory_bytes", "rest_socket"}
RUNNING_STATES = {"VirtualMachineStateRunning", "VirtualMachineStateStarting",
                  "VirtualMachineStatePausing", "VirtualMachineStatePaused",
                  "VirtualMachineStateResuming", "VirtualMachineStateStopping"}


def fail():
    sys.exit(1)


def canonical(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True,
                       separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")


def _start_body(start_raw):
    doc = json.loads(start_raw)
    body = doc["body"]
    valid = (doc["kind"] == "sandbox_runtime_start" and doc["schema_version"] == 1
             and set(body) == START_KEYS and body["command_line"] == COMMAND_LINE
             and body["cpu_count"] == 1 and body["memory_bytes"] == MEMORY_BYTES)
    if not valid:
        raise ValueError("start values")
    paths = [body[k] for k in ("export_disk", "initramfs", "input_disk", "kernel", "rest_socket")]
    # vfkit splits option values on commas; a quote or NUL would break them.
    if not all(isinstance(p, str) and p.startswith("/") and not set(p) & {",", '"', "\0"}
                            for p in paths):
        raise ValueError("start paths")
    if len(os.fsencode(body["rest_socket"])) > SOCKET_PATH_MAX:
        raise ValueError("socket path")
    return body


def _argv_values(start_raw, config_raw):
    try:
        body = _start_body(start_raw)
        vfkit = json.loads(config_raw)["body"]["runtime"]["vfkit"]
        if not (isinstance(vfkit, str) and vfkit.startswith("/")):
            raise ValueError("vfkit path")
    except (ValueError, KeyError, TypeError):
        return 1, b"", b""
    bootloader = 'linux,kernel=%s,initrd=%s,cmdline="%s"' % (body["kernel"], body["initramfs"], COMMAND_LINE)
    argv = [vfkit, "--cpus", "1", "--memory", str(MEMORY_BYTES // 1048576),
            "--bootloader", bootloader,
            "--device", "virtio-blk,path=%s,readonly" % body["input_disk"],
            "--device", "virtio-blk,path=%s" % body["export_disk"],
            "--restful-uri", "unix://%s" % body["rest_socket"]]
    return 0, canonical({"argv": argv, "stopped_exit_status": 0}), b""


def _emit(values):
    status, out, err = values
    sys.stdout.buffer.write(out)
    sys.stderr.buffer.write(err)
    return status


def cmd_argv(args):
    if len(args) != 1:
        fail()
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "host-config.json")
    try:
        with open(args[0], "rb") as handle:
            start_raw = handle.read()
        _start_body(start_raw)
        with open(path, "rb") as handle:
            config_raw = handle.read()
    except (OSError, ValueError, KeyError, TypeError):
        fail()
    return _emit(_argv_values(start_raw, config_raw))


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=1.5)
        self.unix_path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.unix_path)


def _capture_rest(reply, error):
    import stat
    magic = b"YSTACK_REST_CAPTURE_V1\n"
    try:
        value = canonical({"reply": reply, "error": error})
    except (ValueError, TypeError, MemoryError):
        return
    for fd in range(3, 256):
        try:
            state = os.fstat(fd)
            if (not stat.S_ISREG(state.st_mode) or state.st_nlink != 0
                    or stat.S_IMODE(state.st_mode) != 0o600 or state.st_uid != os.getuid()
                    or state.st_size != len(magic) or os.pread(fd, len(magic), 0) != magic):
                continue
            os.pwrite(fd, value, len(magic))
            return
        except OSError:
            continue


def rest(path, method, target, body=None):
    """(status, body bytes) or None when the endpoint cannot be reached."""
    conn = UnixConnection(path)
    phase = "request"
    try:
        conn.request(method, target, body=body, headers={"Content-Type": "application/json"} if body else {})
        phase = "getresponse"
        response = conn.getresponse()
        phase = "read"
        raw = response.read(65537)
        _capture_rest({"status": response.status, "body_hex": raw.hex()}, None)
        return response.status, raw
    except (OSError, http.client.HTTPException) as exc:
        _capture_rest(None, {"phase": phase, "category": "OSError" if isinstance(exc, OSError) else "HTTPException",
                             "errno": getattr(exc, "errno", None)})
        return None
    finally:
        conn.close()


def _state_values(status, body, error):
    state = "error"
    if error is None and status == 200 and len(body) <= 65536:
        try:
            name = json.loads(body)["state"]
        except (ValueError, KeyError, TypeError):
            name = None
        if name == "VirtualMachineStateStopped":
            state = "stopped"
        elif name in RUNNING_STATES:
            state = "running"
    return 0, (state + "\n").encode("ascii"), b""


def _stop_values(status, body, error):
    return (0 if error is None and status == 200 else 1), b"", b""


def cmd_state(args):
    if len(args) != 1:
        fail()
    reply = rest(args[0], "GET", "/vm/state")
    return _emit(_state_values(reply[0], reply[1], None) if reply is not None
                 else _state_values(None, b"", True))


def cmd_stop(args):
    if len(args) != 1:
        fail()
    reply = rest(args[0], "POST", "/vm/state", b'{"state":"HardStop"}')
    return _emit(_stop_values(reply[0], reply[1], None) if reply is not None
                 else _stop_values(None, b"", True))


def main():
    handlers = {"argv": cmd_argv, "state": cmd_state, "stop": cmd_stop}
    if len(sys.argv) < 2 or sys.argv[1] not in handlers:
        fail()
    sys.exit(handlers[sys.argv[1]](sys.argv[2:]))


if __name__ == "__main__":
    main()
