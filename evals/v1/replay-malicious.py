#!/usr/bin/python3
import importlib.util
from pathlib import Path
import struct
import subprocess


class _CalculationRefused(Exception):
    def observation(self, case_id):
        return {"case_id": case_id, "disposition": "rejected", "error_token": "E_REPLAY",
                "invariants": {"state": "absent"}, "recompute_mismatches": []}


def _runtime_values(runtime_root, start_raw, config_raw, driver_rest):
    spec = importlib.util.spec_from_file_location(
        "malicious_runtime_values", Path(runtime_root) / "sandbox/v1/runtime-vfkit.py")
    owner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(owner)
    if type(driver_rest) is not list or len(driver_rest) > 4096:
        raise ValueError("driver observations")
    argv = owner._argv_values(start_raw, config_raw)
    results = []
    for index, row in enumerate(driver_rest, 1):
        if (type(row) is not dict or set(row) != {"call", "operation", "reply", "error"}
                or type(row["call"]) is not int or row["call"] != index
                or row["operation"] not in ("state", "stop")):
            raise ValueError("driver call")
        reply, error = row["reply"], row["error"]
        if (reply is None) == (error is None):
            raise ValueError("driver result")
        if reply is not None:
            if (type(reply) is not dict or set(reply) != {"status", "body_hex"}
                    or type(reply["status"]) is not int or not 100 <= reply["status"] <= 999
                    or type(reply["body_hex"]) is not str or len(reply["body_hex"]) > 131074
                    or len(reply["body_hex"]) % 2
                    or any(c not in "0123456789abcdef" for c in reply["body_hex"])):
                raise ValueError("driver reply")
            status, body = reply["status"], bytes.fromhex(reply["body_hex"])
        else:
            if (type(error) is not dict or set(error) != {"phase", "category", "errno"}
                    or error["phase"] not in ("request", "getresponse", "read")
                    or error["category"] not in ("OSError", "HTTPException")
                    or not (error["errno"] is None or type(error["errno"]) is int
                            and -(1 << 31) <= error["errno"] < (1 << 31))):
                raise ValueError("driver error")
            status, body = None, b""
        if row["operation"] == "state":
            try:
                result = owner._state_values(status, body, error)
            except TypeError as exc:
                raise _CalculationRefused() from exc
            results.append(result)
        else:
            results.append(owner._stop_values(status, body, error))
    return argv, results


def _host_values(runtime_root, steps, pipe_results):
    spec = importlib.util.spec_from_file_location(
        "malicious_host_values", Path(runtime_root) / "sandbox/v1/host-supervisor.py")
    owner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(owner)
    if type(steps) is not list or len(steps) > 4096 or type(pipe_results) is not list or len(pipe_results) > 4096:
        raise ValueError("host observations")
    state = owner._host_state()
    transitions = []
    for step in steps:
        state, action = owner._host_step(state, step)
        transitions.append((state, action))
    pipes = [owner._driver_output_values(row["returncode"], row["chunks"],
                                          row["incomplete"], row["overflow"])
             for row in pipe_results]
    return state, transitions, pipes


def _host_result_values(runtime_root, steps, export_raw, plan_sha256, control_deadline,
                        admission_mono, end_mono, terminated_at):
    spec = importlib.util.spec_from_file_location(
        "malicious_host_result_values", Path(runtime_root) / "sandbox/v1/host-supervisor.py")
    owner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(owner)
    state, _, _ = _host_values(runtime_root, steps, [])
    validated = None
    if state["tree_terminated"]:
        try:
            records = owner.frame_read(export_raw)
        except owner.FrameError:
            records = None
        validated = owner.validate_export(records, plan_sha256)
    return owner._run_result_values(
        owner._export_values(validated), state["tree_terminated"], state["hard_stop"], state["cancelled"],
        state["driver_reported_error"], control_deadline, admission_mono, end_mono,
        terminated_at, state["stop_issued"])


def _host_stub_values(runtime_root, control_deadline, terminated_at):
    spec = importlib.util.spec_from_file_location(
        "malicious_host_stub_values", Path(runtime_root) / "sandbox/v1/host-supervisor.py")
    owner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(owner)
    return owner._stub_run_values(control_deadline, terminated_at)


def _host_receipt_values(runtime_root, config, accepted_set_sha256, request_doc, request_body,
                         launch_request_sha256, admitted_at, measured, admission, run,
                         storage_destroyed, terminated_at):
    spec = importlib.util.spec_from_file_location(
        "malicious_host_receipt_values", Path(runtime_root) / "sandbox/v1/host-supervisor.py")
    owner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(owner)
    return owner._receipt_values(
        config, accepted_set_sha256, request_doc, request_body, launch_request_sha256,
        admitted_at, owner.identities_for_receipt(measured), admission, run,
        storage_destroyed, terminated_at)


def _verifier_values(runtime_root, private_work, instruction_raw, file_raw):
    if (type(instruction_raw) is not bytes or len(instruction_raw) > 4209
            or type(file_raw) is not bytes or len(file_raw) > 1048577):
        raise ValueError("verifier bytes")
    helper = Path(private_work) / "verifier-values"
    if helper.exists() or helper.is_symlink():
        raise ValueError("verifier work")
    built = subprocess.run([
        "/usr/bin/cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
        "-DYSTACK_VERIFIER_VALUES_ONLY",
        str(Path(runtime_root) / "verifiers/file-digest/v1/verifier.c"), "-o", str(helper)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env={"LC_ALL": "C", "PATH": "/usr/bin:/bin", "TMPDIR": str(private_work)}, timeout=30)
    if built.returncode != 0:
        raise ValueError(("verifier value build", built.returncode, built.stdout, built.stderr))
    wire = (b"YSFDV01\n" + struct.pack(">I", len(instruction_raw)) + instruction_raw
            + struct.pack(">I", len(file_raw)) + file_raw)
    result = subprocess.run([str(helper)], input=wire, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env={}, timeout=10)
    if result.returncode != 0 or result.stderr or not result.stdout or len(result.stdout) > 20000:
        raise ValueError("verifier value result")
    return result.stdout


def _guest_values(runtime_root, private_work, guest_wire):
    if type(guest_wire) is not bytes or len(guest_wire) > 16 * 1024 * 1024 or not guest_wire.startswith(b"YSVAL01\n"):
        raise ValueError("guest values")
    helper = Path(private_work) / "guest-values"
    if helper.exists() or helper.is_symlink():
        raise ValueError("guest work")
    guest = Path(runtime_root) / "sandbox/v1/guest"
    built = subprocess.run([
        "/usr/bin/cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
        "-DYSTACK_COMMON_VALUES_ONLY", "-DYSTACK_OBSERVATION_VALUES_MAIN", "-I" + str(guest),
        str(guest / "observation-values.c"), str(guest / "common.c"), "-o", str(helper)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env={"LC_ALL": "C", "PATH": "/usr/bin:/bin", "TMPDIR": str(private_work)}, timeout=30)
    if built.returncode != 0:
        raise ValueError(("guest value build", built.returncode, built.stdout, built.stderr))
    result = subprocess.run([str(helper)], input=guest_wire, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env={}, timeout=10)
    if result.returncode != 0 or result.stderr or len(result.stdout) > 20 * 1024 * 1024:
        raise ValueError("guest value result")
    return result.stdout
