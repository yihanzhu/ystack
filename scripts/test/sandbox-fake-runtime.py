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
import signal
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
    if default_scenario.get("argv_marker_path"):
        # findings-477-r6.md finding 1(a): proves the driver's own argv
        # subcommand (hence any spawn) was never invoked at all, for a
        # cancellation pending before run_vm gets this far -- a file
        # that only ever gets created here.
        try:
            open(default_scenario["argv_marker_path"], "w").close()
        except OSError:
            pass
    if default_scenario.get("oversized_argv"):
        # Proves the host's own bounded driver-output reader: this exceeds
        # the fixed 65,536-byte interface cap, so it must be a hard
        # failure (None), never a silent truncation to 65,536 bytes.
        sys.stdout.write("x" * 200000)
        return 0
    if default_scenario.get("bad_argv_exe"):
        # Proves the host's Popen-failure path: a syntactically valid
        # argv response naming an executable that doesn't exist, so
        # subprocess.Popen itself raises OSError (ENOENT) in run_vm.
        sys.stdout.write(json.dumps({"argv": ["/nonexistent/ystack-test-exe-xyz"],
                                      "stopped_exit_status": 0},
                                     sort_keys=True, separators=(",", ":")) + "\n")
        return 0
    if default_scenario.get("deep_nesting_argv"):
        # findings-477-r10.md: bounded-nesting probe (else RecursionError).
        sys.stdout.write("[" * 2000 + "]" * 2000)
        return 0
    if default_scenario.get("nul_in_argv"):
        # findings-477-r10.md: a NUL in argv (else ValueError from Popen).
        sys.stdout.write(json.dumps({"argv": ["/bin/echo", "a\x00b"],
                                      "stopped_exit_status": 0}) + "\n")
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
    # Reads the default, non-env scenario (state/argv/stop run under an
    # empty environment) for slow_state_ms, well under run_driver's own
    # 2,000ms budget so the call still genuinely succeeds.
    try:
        default_scenario = load_scenario()
    except (OSError, ValueError):
        default_scenario = {}
    slow_state_ms = default_scenario.get("slow_state_ms")
    if slow_state_ms:
        time.sleep(slow_state_ms / 1000.0)
    state = read_mailbox(args[0]).get("state")
    state = state if state in ("running", "stopped", "error") else "error"
    sig_name = default_scenario.get("signal_parent_on_stopped")
    if sig_name and state == "stopped":
        # findings-477-r12ci.md: deterministic, cross-platform version of
        # the cancel-during-poll-returns-stopped race (findings-477-r11.md
        # finding r11) -- signals host-supervisor.py's own pid (our
        # parent: the driver is always spawned directly by it) from
        # exactly the state poll that is about to report "stopped", so
        # cancellation is observed only once the "stopped" observation
        # is already in hand, never dependent on how fast the "run"
        # subcommand's own separate process happens to finish relative
        # to host polling on a given platform (a sleep-then-signal
        # pattern that landed inside vs. outside the poll window
        # differently on Linux CI than on macOS).
        os.kill(os.getppid(), getattr(signal, "SIG" + sig_name))
    sys.stdout.write(state + "\n")
    return 0


def cmd_stop(args):
    try:
        default_scenario = load_scenario()
    except (OSError, ValueError):
        default_scenario = {}
    if default_scenario.get("stop_marker_path"):
        # findings-477-r11.md: proves driver_stop() (the "stop"
        # subcommand) was invoked at least once -- a file only ever
        # created here, so its ABSENCE after a run proves zero stop
        # calls occurred, regardless of accept/reject outcome below.
        try:
            open(default_scenario["stop_marker_path"], "w").close()
        except OSError:
            pass
    # findings-477-r6.md finding 1: a real stop call against a REST
    # endpoint nothing is listening on yet must fail (rc != 0), the same
    # way cmd_state's read_mailbox treats a not-yet-created mailbox file
    # as "error" -- write_mailbox would otherwise blindly create it,
    # masking the very rejection host-supervisor.py must retry past.
    if not os.path.exists(args[0]):
        return 1
    # findings-477-r7.md finding 2: slow_stop_ms (the default, non-env
    # scenario, same as slow_state_ms above) lets a test make THIS call
    # itself the slow one, proving the host recomputes its deadline
    # budget fresh before the NEXT blocking call in the same iteration,
    # not a stale pre-stop budget.
    slow_stop_ms = default_scenario.get("slow_stop_ms")
    if slow_stop_ms:
        time.sleep(slow_stop_ms / 1000.0)
    try:
        write_mailbox(args[0], hardstop=True)
    except OSError:
        return 1
    return 0


def cmd_run(args):
    socket_path, export_disk, input_disk = args[0], args[1], args[2]
    hs = load_host_module()
    scenario = load_scenario()
    if scenario.get("run_marker_path"):
        # findings-477-r7.md finding 1: proves the runtime process was
        # actually spawned (Popen exec'd this "run" subcommand) -- a
        # file that only ever gets created here, outside work_root so it
        # survives the attempt directory's own teardown.
        try:
            open(scenario["run_marker_path"], "w").close()
        except OSError:
            pass
    startup_delay_ms = scenario.get("startup_delay_ms")
    if startup_delay_ms:
        # Simulates the REST endpoint not existing yet right after Popen
        # (host-supervisor.py's own bounded-startup-readiness window):
        # the mailbox file itself doesn't exist until this sleep ends, so
        # cmd_state's read_mailbox sees "error" (unavailable) until then.
        time.sleep(startup_delay_ms / 1000.0)
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

    if scenario.get("action") == "exit_no_mailbox":
        # Proves the host's startup-readiness exit-status confirmation:
        # this process exits cleanly (code 0) without ever writing
        # anything to the mailbox at all, so driver_state() only ever
        # sees "error" (the file never exists) -- once past the startup
        # grace period, the host must check proc.poll() itself and
        # confirm the stop from the exit code, not just call it a
        # runtime failure because the endpoint stayed unavailable.
        return 0
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
        if scenario.get("hardstop_exit_no_mailbox"):
            # Exits with stopped_exit_status without ever writing
            # "stopped" to the mailbox at all -- the host must confirm
            # this stop from the process's own exit code (proc.poll()),
            # since driver_state() never reports "stopped" here, and it
            # must accept stopped_exit_status even though HardStop was
            # requested (the runtime honored it and exited cleanly
            # before the next state poll could even see its endpoint).
            return 0
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
        # name_hex is the guest's own evidence FILENAME, hex-encoded --
        # not a content digest (host-supervisor.py's own hex_name_ok, not
        # sha256_ok, validates it): "name" defaults to the real
        # verifier's own evidence filename, file-digest-result.json (44
        # hex characters, nowhere near a 64-character sha256 digest), so
        # the default scenario exercises this by itself.
        name = ev.get("name", "file-digest-result.json")
        name_hex = name.encode().hex()
        if ev.get("name_hex_override") is not None:
            name_hex = ev["name_hex_override"]
        evidence_records.append((("evidence/%04d" % ev["index"]).encode(), content))
        evidence_files.append({"index": ev["index"], "name_hex": name_hex,
                                "size_bytes": len(content)})
    if scenario.get("duplicate_evidence_index") and evidence_files:
        # Two declarations of the same index (a different name_hex, the
        # same single frame record): each index must be required exactly
        # once, never silently deduplicated by name, which would let one
        # exported byte manufacture two payload files and double-count
        # the output sum.
        dup = dict(evidence_files[0])
        dup["name_hex"] = "aa" * len(bytes.fromhex(dup["name_hex"]))
        evidence_files.append(dup)
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
    report_record = hs.canonical(report_doc)
    if scenario.get("raw_report_json_depth"):
        # Bounded-nesting/RecursionError probe: a report.json this deeply
        # nested must be an invalid export, never something that escapes
        # run_vm's own bounded_json_nesting scan or a RecursionError from
        # json.loads itself and aborts the supervisor.
        depth = scenario["raw_report_json_depth"]
        report_record = b"[" * depth + b"]" * depth
    records = [(b"report.json", report_record)]
    if not scenario.get("omit_stdout_record"):
        records.append((b"stdout", stdout_bytes))
    if not scenario.get("omit_stderr_record"):
        records.append((b"stderr", stderr_bytes))
    records += evidence_records
    if scenario.get("duplicate_stdout_record"):
        # A second "stdout" record: the exact frame format (R3.2/R8.1) is
        # closed and has no duplicates -- a naive dict conversion would
        # silently collapse this to its last value instead of refusing.
        records.append((b"stdout", b"duplicate"))
    if scenario.get("unknown_record"):
        records.append((b"unexpected", b"not a fixed record name"))
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
    if scenario.get("hang_after_export"):
        # R5.3's own gate under test: a valid, complete frame is on disk,
        # but the runtime never confirms a stop (never writes "stopped")
        # and instead hangs -- the host must never read/trust this frame
        # just because it happens to be there; it must gate consumption
        # on tree_terminated (a confirmed stop AND a successful reap),
        # not on the frame's own mere presence/validity.
        while True:
            time.sleep(0.02)
    if scenario.get("vanish_mailbox_on_exit"):
        # findings-477-r9.md finding 2: the REST endpoint can disappear
        # entirely on a clean exit (e.g. the runtime removes its own
        # socket/mailbox during its own teardown) rather than ever
        # reporting "stopped" -- the host must still recognize this as
        # a clean, confirmed stop via proc.poll()'s own stopped_exit_status,
        # never a driver failure just because a state poll races ahead
        # of the exit and finds no endpoint at all.
        try:
            os.unlink(socket_path)
        except OSError:
            pass
    else:
        write_mailbox(socket_path, state="stopped")
    exit_delay_ms = scenario.get("exit_delay_ms")
    if exit_delay_ms:
        # Reports "stopped" via the mailbox immediately, but the process
        # itself keeps running a while longer -- so the host's own
        # reap (proc.wait()) genuinely blocks, exercising whether it's
        # correctly bounded by the absolute abandonment deadline rather
        # than a fresh, fixed wait of its own.
        time.sleep(exit_delay_ms / 1000.0)
    slow_drain_ms = scenario.get("slow_drain_ms")
    if slow_drain_ms and os.fork() == 0:
        # findings-477-r12.md finding 3: a grandchild inheriting our own
        # stdout/stderr (the host's log-drain pipe) that outlives OUR own
        # exit -- keeps the host's drain thread blocked on read() (no
        # EOF yet) well past when the host already confirms the stop,
        # proving wall_time_ms is captured before, not after, that drain.
        time.sleep(slow_drain_ms / 1000.0)
        os._exit(0)
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
