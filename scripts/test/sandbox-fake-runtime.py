#!/usr/bin/python3
"""sandbox-fake-runtime.py -- fake driver + runtime process implementing
host-supervisor.py's fixed driver interface (plan.md's "Runtime driver"):
`argv <start.json>`, `state <socket>`, `stop <socket>`. Used only by
sandbox-launcher.test.sh (PR 5 of ystack #463); never installed, never
touches a real hypervisor.

`argv` prints an argv that re-invokes this same file in `run` mode,
carrying the input/export disk paths and the `<socket>` path the host
allocated (`rest.sock`, a single regular file -- so the host's own
remove-only teardown can unlink it exactly like any other launch-path
file). This fake repurposes that one file as a tiny JSON mailbox
(`{"state": "running"|"stopped"|"error", "hardstop": bool}`) instead of
a real AF_UNIX REST socket: the driver interface's own output contract
(`state` prints running/stopped/error; `stop` exits 0 on request
accepted) does not mandate the transport mechanism.

`run` reads `scenario.json` (beside this file, or $YSTACK_FAKE_SCENARIO
-- read only when set, since the driver's own argv/state/stop calls run
under an empty environment, but the runtime process this argv spawns is
launched with the host's own scrubbed environment, so a test can still
steer it by exporting the variable before calling run_launch) to script
its outcome, reads its own input disk (the plan.json frame record) to
compute plan_sha256 exactly as a real guest supervisor would, and writes
the scripted sandbox_guest_report export frame via the host's own frame
codec (imported from host-supervisor.py, at $YSTACK_HOST_SUPERVISOR or
the sibling sandbox/v1/ directory).
"""
import importlib.util
import json
import os
import sys
import time


def load_host_module():
    path = os.environ.get("YSTACK_HOST_SUPERVISOR") or os.path.join(
        os.path.dirname(os.path.realpath(__file__)), "..", "..", "sandbox", "v1", "host-supervisor.py")
    spec = importlib.util.spec_from_file_location("_ystack_fake_host", os.path.realpath(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_scenario():
    path = os.environ.get("YSTACK_FAKE_SCENARIO") or os.path.join(
        os.path.dirname(os.path.realpath(__file__)), "scenario.json")
    with open(path, "rb") as fh:
        return json.loads(fh.read())


def cmd_argv(args):
    # argv/state/stop all run under an empty environment (the fixed driver
    # interface), so load_scenario() always falls back to the default,
    # non-env path here regardless of what a test set $YSTACK_FAKE_SCENARIO
    # to for the "run" stage -- read only for the one test-only knob below.
    try:
        default_scenario = load_scenario()
    except (OSError, ValueError):
        default_scenario = {}
    if default_scenario.get("oversized_argv"):
        # Proves the host's own bounded driver-output reader: this exceeds
        # the fixed 65,536-byte interface cap, so it must be a hard
        # failure (None), never a silent truncation to 65,536 bytes.
        sys.stdout.write("x" * 200000)
        return 0
    with open(args[0], "rb") as fh:
        start = json.loads(fh.read())
    b = start["body"]
    argv = [sys.executable, os.path.realpath(__file__), "run", b["rest_socket"],
            b["export_disk"], b["input_disk"]]
    sys.stdout.write(json.dumps({"argv": argv, "stopped_exit_status": 0},
                                 sort_keys=True, separators=(",", ":")) + "\n")
    return 0


def read_mailbox(socket_path):
    try:
        with open(socket_path, "r") as fh:
            return json.loads(fh.read())
    except (OSError, ValueError):
        return {"state": "error", "hardstop": False}


def write_mailbox(socket_path, state=None, hardstop=None):
    box = read_mailbox(socket_path)
    if state is not None:
        box["state"] = state
    if hardstop is not None:
        box["hardstop"] = hardstop
    tmp = socket_path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(json.dumps(box))
    os.replace(tmp, socket_path)


def cmd_state(args):
    state = read_mailbox(args[0]).get("state")
    sys.stdout.write((state if state in ("running", "stopped", "error") else "error") + "\n")
    return 0


def cmd_stop(args):
    try:
        write_mailbox(args[0], hardstop=True)
    except OSError:
        return 1
    return 0


def cmd_run(args):
    socket_path, export_disk, input_disk = args[0], args[1], args[2]
    hs = load_host_module()
    scenario = load_scenario()
    write_mailbox(socket_path, state="running", hardstop=False)

    ignore_hardstop_ms = scenario.get("ignore_hardstop_ms")
    self_stop_after_ms = scenario.get("self_stop_after_ms")
    hang = scenario.get("action") == "hang"
    stopped_via_hardstop = False
    start = time.monotonic()
    while True:
        elapsed_ms = (time.monotonic() - start) * 1000
        if self_stop_after_ms is not None and elapsed_ms >= self_stop_after_ms:
            break
        if read_mailbox(socket_path).get("hardstop"):
            if ignore_hardstop_ms is None or elapsed_ms >= ignore_hardstop_ms:
                stopped_via_hardstop = True
                break
        elif not hang and self_stop_after_ms is None:
            break  # plain success: nothing scripted to wait for
        if elapsed_ms > 120000:
            break
        time.sleep(0.02)

    if scenario.get("action") == "crash":
        write_mailbox(socket_path, state="error")
        return 1
    if scenario.get("action") == "no_export":
        write_mailbox(socket_path, state="stopped")
        return 0
    if scenario.get("action") == "stopped_then_bad_exit":
        # Proves the host's own driver_reported_error tracking: the
        # mailbox says stopped (driver_state()=="stopped", confirming the
        # tree the same way a clean run does), but the process then exits
        # with an abnormal code anyway -- a runtime that crashes right
        # after writing its own "stopped" report, still an error, never
        # silently accepted as a clean completion.
        write_mailbox(socket_path, state="stopped")
        os._exit(scenario.get("bad_exit_code", 7))
    if stopped_via_hardstop and not scenario.get("hardstop_writes_export"):
        # A real vfkit HardStop forces the VM off before the guest
        # supervisor can sync and power off on its own (R8.1's own
        # export-then-poweroff sequence never completes) -- so a stop the
        # host had to force never leaves a clean export either, matching
        # plan.md/spec.md's class (c): HardStop adds both failure.runtime
        # and failure.observation-unavailable, not failure.runtime alone.
        write_mailbox(socket_path, state="stopped")
        return 0

    with open(input_disk, "rb") as fh:
        input_records = dict(hs.frame_read(fh.read()))
    plan_sha256 = hs.sha256_hex(input_records[b"plan.json"])

    # R8.2's guest report carries exactly these five fields per row --
    # mechanism_id is never one of them (host-supervisor.py's
    # build_limit_rows always uses its own R7.1 fixed mechanism_id
    # constant instead, regardless of what a guest might send).
    limits = {name: {"observed": 0, "observation": "complete", "enforcement": "hard",
                      "reached": False, "resolution": 1}
              for name in ("cpu_time_ms", "memory_bytes", "output_bytes", "process_count",
                            "scratch_bytes")}
    for name, override in scenario.get("limit_overrides", {}).items():
        limits[name].update(override)
    stdout_bytes = scenario.get("stdout", "").encode()
    stderr_bytes = scenario.get("stderr", "").encode()
    evidence_files, evidence_records = [], []
    for ev in scenario.get("evidence", []):
        content = ev["content"].encode()
        evidence_records.append((("evidence/%04d" % ev["index"]).encode(), content))
        evidence_files.append({"index": ev["index"], "name_hex": hs.sha256_hex(content),
                                "size_bytes": len(content)})
    report_body = {
        "evidence_files": evidence_files, "exit_code": scenario.get("exit_code", 0),
        "exit_state": scenario.get("exit_state", "exited"), "limits": limits,
        "plan_sha256": plan_sha256, "stderr_bytes": len(stderr_bytes),
        "stdout_bytes": len(stdout_bytes),
        "tree_deadline_fired": scenario.get("tree_deadline_fired", False),
        "tree_terminated": scenario.get("tree_terminated", True),
        "verifier_started": scenario.get("verifier_started", True),
    }
    report_body.update(scenario.get("report_overrides", {}))
    report_doc = {"body": report_body, "id": "sandbox.guest-report.fixture",
                  "kind": "sandbox_guest_report", "schema_version": 1}
    records = [(b"report.json", hs.canonical(report_doc)), (b"stdout", stdout_bytes),
               (b"stderr", stderr_bytes)] + evidence_records
    if scenario.get("extra_undeclared_evidence"):
        # R8.2's exact evidence inventory: a frame record under evidence/
        # that evidence_files never declared must be caught, not silently
        # ignored (the declared entries alone all still check out fine).
        records.append((b"evidence/9999", b"undeclared"))
    frame = hs.frame_write(records)
    if scenario.get("damage_export"):
        frame = frame[:-1]
    with open(export_disk, "r+b") as fh:
        fh.write(frame)
    write_mailbox(socket_path, state="stopped")
    return 0


def main():
    if len(sys.argv) < 3:
        sys.exit(2)
    handlers = {"argv": cmd_argv, "state": cmd_state, "stop": cmd_stop, "run": cmd_run}
    handler = handlers.get(sys.argv[1])
    if handler is None:
        sys.exit(2)
    sys.exit(handler(sys.argv[2:]))


if __name__ == "__main__":
    main()
