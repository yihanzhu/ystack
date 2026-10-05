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


def configured_vfkit():
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "host-config.json")
    try:
        with open(path, "rb") as handle:
            vfkit = json.loads(handle.read())["body"]["runtime"]["vfkit"]
    except (OSError, ValueError, KeyError, TypeError):
        fail()
    if not (isinstance(vfkit, str) and vfkit.startswith("/")):
        fail()
    return vfkit


def cmd_argv(args):
    if len(args) != 1:
        fail()
    try:
        with open(args[0], "rb") as handle:
            doc = json.loads(handle.read())
        body = doc["body"]
        valid = (doc["kind"] == "sandbox_runtime_start" and doc["schema_version"] == 1
                 and set(body) == START_KEYS and body["command_line"] == COMMAND_LINE
                 and body["cpu_count"] == 1 and body["memory_bytes"] == MEMORY_BYTES)
    except (OSError, ValueError, KeyError, TypeError):
        fail()
    if not valid:
        fail()
    paths = [body[k] for k in ("export_disk", "initramfs", "input_disk", "kernel", "rest_socket")]
    # vfkit splits option values on commas; a quote or NUL would break them.
    if not all(isinstance(p, str) and p.startswith("/") and not set(p) & {",", '"', "\0"}
                            for p in paths):
        fail()
    if len(os.fsencode(body["rest_socket"])) > SOCKET_PATH_MAX:
        fail()
    bootloader = 'linux,kernel=%s,initrd=%s,cmdline="%s"' % (body["kernel"], body["initramfs"], COMMAND_LINE)
    argv = [configured_vfkit(), "--cpus", "1", "--memory", str(MEMORY_BYTES // 1048576),
            "--bootloader", bootloader,
            "--device", "virtio-blk,path=%s,readonly" % body["input_disk"],
            "--device", "virtio-blk,path=%s" % body["export_disk"],
            "--restful-uri", "unix://%s" % body["rest_socket"]]
    sys.stdout.buffer.write(canonical({"argv": argv, "stopped_exit_status": 0}))
    return 0


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=1.5)
        self.unix_path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.unix_path)


def rest(path, method, target, body=None):
    """(status, body bytes) or None when the endpoint cannot be reached."""
    conn = UnixConnection(path)
    try:
        conn.request(method, target, body=body, headers={"Content-Type": "application/json"} if body else {})
        response = conn.getresponse()
        return response.status, response.read(65537)
    except (OSError, http.client.HTTPException):
        return None
    finally:
        conn.close()


def cmd_state(args):
    if len(args) != 1:
        fail()
    reply = rest(args[0], "GET", "/vm/state")
    state = "error"
    if reply is not None and reply[0] == 200 and len(reply[1]) <= 65536:
        try:
            name = json.loads(reply[1])["state"]
        except (ValueError, KeyError, TypeError):
            name = None
        if name == "VirtualMachineStateStopped":
            state = "stopped"
        elif name in RUNNING_STATES:
            state = "running"
    sys.stdout.write(state + "\n")
    return 0


def cmd_stop(args):
    if len(args) != 1:
        fail()
    reply = rest(args[0], "POST", "/vm/state", b'{"state":"HardStop"}')
    return 0 if reply is not None and reply[0] == 200 else 1


def main():
    handlers = {"argv": cmd_argv, "state": cmd_state, "stop": cmd_stop}
    if len(sys.argv) < 2 or sys.argv[1] not in handlers:
        fail()
    sys.exit(handlers[sys.argv[1]](sys.argv[2:]))


if __name__ == "__main__":
    main()
