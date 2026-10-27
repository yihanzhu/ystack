#!/usr/bin/python3
import importlib.util
import hashlib
import os
import stat
import json
from pathlib import Path
import struct
import subprocess
import sys


class _CalculationRefused(Exception):
    def observation(self, case_id):
        return {"case_id": case_id, "disposition": "rejected", "error_token": "E_REPLAY",
                "invariants": {"state": "absent"}, "recompute_mismatches": []}


def _launch_values(runtime_root, request_raw, incident_raw, evaluation_raw, observation_raw,
                    record_raw, manifest_raw, instruction, control_values, entropy):
    spec = importlib.util.spec_from_file_location(
        "malicious_launch_values", Path(runtime_root) / "shadow/v1/enforced-reproduction.py")
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    return owner._launch_values(request_raw, incident_raw, evaluation_raw, observation_raw,
        record_raw, manifest_raw, instruction, control_values, entropy)


def _native_runtime_values(runtime_root, values, locators):
    spec = importlib.util.spec_from_file_location(
        "malicious_native_runtime_values",Path(runtime_root)/"shadow/v1/enforced-reproduction.py")
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    return owner._native_runtime_values(values, locators)


def _preparation_consumer_values(runtime_root, raw, operation, input_raw, response_raw):
    spec = importlib.util.spec_from_file_location(
        "malicious_preparation_consumer_values", Path(runtime_root)/"shadow/v1/_consumer.py")
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    return owner._preparation_capture_binding_values(raw, operation, input_raw, response_raw)


def _preparation_seal_values(runtime_root, name, expected, before, after, named, uid, gid,
                             access, default, platform, contents):
    spec = importlib.util.spec_from_file_location(
        "malicious_preparation_seal_values", Path(runtime_root)/"shadow/v1/_consumer.py")
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    return owner._preparation_seal_values(name, expected, before, after, named, uid, gid,
                                           access, default, platform, contents)


def _preparation_capture_values(runtime_root, raw, workspace, operation, input_raw, response_raw):
    spec = importlib.util.spec_from_file_location(
        "malicious_preparation_capture_values",Path(runtime_root)/"preparation/v1/prepare-candidate.py")
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    return owner._preparation_capture_values(raw,workspace,operation,owner.sha256(input_raw),owner.sha256(response_raw))


def _preparation_runtime_values(runtime_root, value):
    spec = importlib.util.spec_from_file_location(
        "malicious_preparation_runtime_values",Path(runtime_root)/"preparation/v1/prepare-candidate.py")
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    return owner._preparation_runtime_values(value)


def _preparation_storage_values(runtime_root, events, source_files, algorithm):
    spec = importlib.util.spec_from_file_location(
        "malicious_preparation_storage_values",Path(runtime_root)/"preparation/v1/prepare-candidate.py")
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    return owner._preparation_storage_values(events,source_files,algorithm)


def _preparation_workspace_values(runtime_root, rows):
    spec = importlib.util.spec_from_file_location(
        "malicious_workspace_values", Path(runtime_root) / "preparation/v1/prepare-candidate.py")
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    return owner._preparation_workspace_values(rows)


def _preparation_values(runtime_root, inventory, source_bytes, runtime_values, identities,
                         input_sha256, response_sha256, response, details, receipt, storage_observation):
    spec = importlib.util.spec_from_file_location(
        "malicious_preparation_values", Path(runtime_root) / "preparation/v1/prepare-candidate.py")
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    measured = owner._producer_source_values(source_bytes["component"], source_bytes["python"], source_bytes["git"])
    producer = owner._producer_values(measured, runtime_values["git_version"], runtime_values["python_version"],
                                      runtime_values["unicode_version"], identities)
    manifest = owner.canonical(owner.manifest_for(inventory))
    record = owner.canonical(owner._record_values(input_sha256, response_sha256, response, details,
        receipt, manifest, storage_observation, producer))
    return manifest, record, owner.completion_envelope(record, manifest)


def _capture_completion_values(runtime_root, attempt_id, request_raw, capture_raw):
    spec = importlib.util.spec_from_file_location(
        "malicious_capture_completion_values", Path(runtime_root)/"sandbox/v1/host-supervisor.py")
    owner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(owner)
    return owner._capture_completion_values(attempt_id, request_raw, capture_raw)


def _capture_projection_values(runtime_root, capture_raw, groups, outer_raw, launch_raw,
                               expectation_raw, receipt_raw, kind):
    spec = importlib.util.spec_from_file_location(
        "malicious_capture_values", Path(runtime_root) / "shadow/v1/_consumer.py")
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    outer = owner._json(outer_raw, owner.DOCUMENT_LIMIT, "E_STORE")
    rebuilt = owner._capture_envelope_values(outer["body"]["attempt_id"], launch_raw, groups)
    owner._require(rebuilt == capture_raw, "E_STORE")
    projected = owner._launch_capture_values(rebuilt, outer_raw, launch_raw,
                                            expectation_raw, receipt_raw, kind)
    return rebuilt, projected


def _reproduction_capture_values(runtime_root, capture_raw, groups, outer_raw, launch_raw,
                                 expectation_raw, receipt_raw):
    return _capture_projection_values(runtime_root, capture_raw, groups, outer_raw, launch_raw,
        expectation_raw, receipt_raw, "shadow_enforced_request")


def _write_capture_values(runtime_root, capture_raw, groups, outer_raw, launch_raw,
                          expectation_raw, receipt_raw):
    return _capture_projection_values(runtime_root, capture_raw, groups, outer_raw, launch_raw,
        expectation_raw, receipt_raw, "shadow_write_request")


def _origin_values(runtime_root, files, storage_rows, identity_context, source_bytes, *,
                   capture_files=None, capture_storage_rows=None):
    spec = importlib.util.spec_from_file_location(
        "malicious_origin_values", Path(runtime_root) / "shadow/v1/_consumer.py")
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    if "sandbox-export.bin" in files and type(files["sandbox-export.bin"]) is not bytes:
        files = dict(files)
        value = files["sandbox-export.bin"]
        files["sandbox-export.bin"] = value if type(value) is tuple else value.chunks
    if capture_files is not None and "sandbox-export.bin" in capture_files:
        capture_files = dict(capture_files)
        value = capture_files["sandbox-export.bin"]
        capture_files["sandbox-export.bin"] = value if type(value) in (tuple, bytes) else value.chunks
    return owner._origin_values(files, storage_rows, identity_context, source_bytes,
        capture_files=capture_files, capture_storage_rows=capture_storage_rows)


def _source_values(runtime_root, request_raw, configuration_bytes, pages, primitive_values):
    spec = importlib.util.spec_from_file_location(
        "malicious_source_values", Path(runtime_root) / "sandbox/v1/coverage-source.py")
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    return owner._source_values(request_raw, configuration_bytes, pages, primitive_values)


def _writer_values(runtime_root, frozen, files, materialized, context):
    if (type(materialized) is not dict or set(materialized) != {
            "input_raw", "response_raw", "evaluation_raw", "qualified_identity_raw",
            "candidate_tree_id", "write_set", "files"}
            or type(context) is not dict or set(context) != {
                "request", "record_form", "scope_policy_raw", "store_id", "parent",
                "consumer_sha256", "python_sha256", "jq_sha256", "native_context", "commands",
                "observation", "trace"}):
        raise ValueError("writer values")
    spec = importlib.util.spec_from_file_location(
        "malicious_writer_values", Path(runtime_root) / "shadow/v1/write-shadow.py")
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    incident = owner.parse(frozen["incident.json"])
    publisher, publisher_body = owner._publisher(incident, materialized["candidate_tree_id"])
    stage = owner.parse(materialized["input_raw"], 8 * owner.e.OUTPUT_LIMIT)["stage_request"]["content"]["body"]
    write = owner._write_section_values(frozen["bundle.json"], context["request"]["body"]["scope_id"],
        stage, materialized["write_set"], publisher, incident["body"]["git_revision_ref"],
        materialized["candidate_tree_id"])
    output = dict(files)
    output["publisher-body.txt"] = publisher_body
    admission, _, _ = owner._admission_values(context["request"], context["record_form"],
        materialized["input_raw"], materialized["candidate_tree_id"], materialized["write_set"],
        materialized["files"], frozen, output, write, context["scope_policy_raw"])
    provenance = owner._write_provenance_values(context["request"]["id"], owner.e.make_instruction(incident),
        context["observation"], context["parent"], context["consumer_sha256"], context["python_sha256"],
        context["jq_sha256"], owner.e._native_provenance_values(context["native_context"]), context["commands"])
    output["consumer-provenance.json"] = provenance
    output["shadow-record.json"] = owner._outer_record_values(context["store_id"], materialized["response_raw"],
        materialized["evaluation_raw"], materialized["qualified_identity_raw"], frozen, output, write,
        provenance, context["trace"], context["record_form"])
    return output, owner._bundle_values(output, incident, context["record_form"]), admission


def _gate_values(runtime_root, inputs):
    if type(inputs) is not dict or set(inputs) != {"basis", "register", "stage_request", "result",
            "duty", "risk", "kill", "active", "id", "files", "initial_origins", "final_origins",
            "kill_request", "coverage_request", "observations"}:
        raise ValueError("gate values")
    spec = importlib.util.spec_from_file_location(
        "malicious_gate_values", Path(runtime_root) / "scope/v1/generate-gate-evidence.py")
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    state, attempt = owner.project_register(inputs["register"], inputs["basis"], inputs["stage_request"],
        inputs["result"], inputs["duty"], inputs["active"])
    scope = owner._scope_values(inputs["basis"], inputs["duty"], inputs["risk"], inputs["kill"])
    manifest = owner._manifest_values(inputs["id"], inputs["files"], inputs["initial_origins"],
        inputs["final_origins"], inputs["kill_request"], inputs["coverage_request"])
    return {"state": state, "attempt": attempt, "scope": scope,
        "origins": owner._origins_values(inputs["observations"]), "manifest": manifest,
        "complete": owner._completion_values(inputs["id"], manifest)}


def _identity_context_values(runtime_root, context, principal_uid, consumer_gid):
    spec = importlib.util.spec_from_file_location(
        "malicious_identity_context_values", Path(runtime_root) / "shadow/v1/_consumer.py")
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    return owner._identity_context_values(context, principal_uid, consumer_gid)


def _identity_values(runtime_root, slots, instruction_raw, config_raw, supervisor_raw, python_raw,
                      read_observations=None):
    spec = importlib.util.spec_from_file_location(
        "malicious_identity_values", Path(runtime_root) / "sandbox/v1/host-supervisor.py")
    owner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(owner)
    return owner._runtime_identity_values(slots, instruction_raw, config_raw, supervisor_raw, python_raw,
                                          read_observations)


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
            records, _ = owner._guest_capture_values(records)
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


def _guest_wire_values(runtime_root, plan_raw, guest):
    spec = importlib.util.spec_from_file_location(
        "malicious_guest_capture_size", Path(runtime_root)/"sandbox/v1/host-supervisor.py")
    size_owner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(size_owner)
    if type(plan_raw) is not bytes or type(guest) is not dict or set(guest) != {"setup", "control", "counters"}:
        raise ValueError("guest observations")
    setup, control, counters = guest["setup"], guest["control"], guest["counters"]
    if type(setup) is not dict or type(counters) is not dict or type(control) is not list or not 1 <= len(control) <= 4096:
        raise ValueError("guest groups")
    used = {"setup": set(), "counters": set()}
    groups = {"setup": setup, "counters": counters}
    wire = bytearray(b"YSVAL02\n")

    def integer(value, low=-(1 << 63), high=(1 << 63) - 1):
        if type(value) is not int or not low <= value <= high:
            raise ValueError("guest integer")
        return value

    def put(value, signed=False):
        integer(value, -(1 << 63) if signed else 0, (1 << 63) - 1 if signed else (1 << 64) - 1)
        if len(wire) + 8 > 16 * 1024 * 1024:
            raise ValueError("guest wire bound")
        wire.extend(struct.pack(">q" if signed else ">Q", value))

    def blob(value):
        if type(value) is not bytes or len(wire) + 8 + len(value) > 16 * 1024 * 1024:
            raise ValueError("guest blob bound")
        put(len(value)); wire.extend(value)

    def unhex(value, maximum):
        if (type(value) is not str or len(value) > maximum * 2 or len(value) % 2
                or any(char not in "0123456789abcdef" for char in value)):
            raise ValueError("guest bytes")
        return bytes.fromhex(value)

    def errno_value(value):
        return 0 if value is None else integer(value, 1, (1 << 31) - 1)

    def take(group, name, keys):
        value = groups[group].get(name)
        if name in used[group] or type(value) is not dict or set(value) != set(keys):
            raise ValueError("guest observation " + name)
        used[group].add(name)
        return value

    def io(group, name, maximum=0, count_bytes=False):
        row = take(group, name, {"bytes", "errno", "return"})
        result = integer(row["return"])
        error = errno_value(row["errno"])
        raw = unhex(row["bytes"], maximum)
        if (result < 0) != bool(error) or result < 0 and raw or count_bytes and result >= 0 and result != len(raw):
            raise ValueError("guest I/O result")
        return result, raw

    def read(group, name, maximum, optional=False):
        if name + "_open" not in groups[group]:
            if optional:
                return False, b""
            raise ValueError("guest missing read " + name)
        opened, _ = io(group, name + "_open")
        if opened < 0:
            return False, b""
        result, raw = io(group, name, maximum, True)
        closed, _ = io(group, name + "_close")
        if closed not in (0, -1):
            raise ValueError("guest close")
        return result >= 0, raw

    def metadata(group, name, filesystem=False):
        row = take(group, name, {"errno", "return", "stat"})
        result = integer(row["return"], -1, 0)
        error = errno_value(row["errno"])
        keys = {"f_blocks", "f_bfree", "f_frsize", "f_files"} if filesystem else {"dev", "ino", "mode", "uid", "gid", "nlink", "size"}
        if result == -1:
            if not error or row["stat"] is not None:
                raise ValueError("guest failed stat")
            return False, None
        if error or type(row["stat"]) is not dict or set(row["stat"]) != keys:
            raise ValueError("guest stat")
        for value in row["stat"].values():
            integer(value, 0, (1 << 64) - 1)
        return True, row["stat"]

    blob(plan_raw)
    names = ("cpu_max", "cpu_max_burst", "bandwidth_slice_us", "pids_max")
    put(sum(1 << index for index, name in enumerate(names) if name + "_write_open" in setup))
    put(sum(1 << index for index, name in enumerate(names) if name + "_open" in setup))
    put(sum(1 << index for index, name in enumerate(("memory_events", "pids_events")) if name + "_open" in counters))
    initial_page_size, _ = io("setup", "page_size")
    put(initial_page_size, True)
    for name in names:
        count = closed = -1
        if name + "_write_open" in setup:
            opened, _ = io("setup", name + "_write_open")
            if opened >= 0:
                count, _ = io("setup", name + "_write")
                closed, _ = io("setup", name + "_write_close")
                if closed not in (0, -1):
                    raise ValueError("guest write close")
        put(count, True); put(closed, True)
        ok, raw = read("setup", name, 127, True)
        put(int(ok)); blob(raw)
    ok, raw = read("setup", "meminfo", 255)
    put(int(ok)); blob(raw)
    for name in ("output", "scratch"):
        ok, values = metadata("setup", name, True)
        put(int(ok))
        for key in ("f_blocks", "f_frsize", "f_files"):
            put(values[key] if ok else 0)
    page_size, _ = io("setup", "report_page_size")
    put(page_size & ((1 << 64) - 1))
    for name in ("subtree_control_write_open", "subtree_control_write", "subtree_control_write_close", "cgroup_open"):
        io("setup", name)

    def row_shape(row, keys):
        if (type(row) is not dict or set(row) != set(keys)
                or size_owner._capture_size(row, 8191) + 1 > 8192):
            raise ValueError("guest control row")

    def now(row):
        row_shape(row, {"tag", "sec", "nsec", "errno"})
        error = errno_value(row["errno"])
        if error:
            if row["sec"] is not None or row["nsec"] is not None:
                raise ValueError("guest failed clock")
            return False, 0, 0, error
        return True, integer(row["sec"]), integer(row["nsec"], 0, 999999999), 0

    if control[0].get("tag") != "now":
        raise ValueError("guest initial clock")
    ok, sec, nsec, _ = now(control[0])
    put(int(ok)); put(sec, True); put(nsec, True)
    if not ok:
        if len(control) != 1 or counters:
            raise ValueError("guest unused observations")
    else:
        if len(control) < 2:
            raise ValueError("guest missing launch")
        launch = control[1]
        row_shape(launch, {"tag", "pid", "errno"})
        if launch["tag"] != "launch":
            raise ValueError("guest launch")
        pid = integer(launch["pid"], -(1 << 31), (1 << 31) - 1)
        error = errno_value(launch["errno"])
        if (pid < 0) != bool(error):
            raise ValueError("guest launch errno")
        put(pid, True); put(error, True)
        if pid <= 0:
            if len(control) != 2 or counters:
                raise ValueError("guest unused launch observations")
        else:
            roles = [item["role"] for row in control[2:] if row.get("tag") == "poll" for item in row.get("revents", [])]
            has_fan = "fan" in roles if roles else True
            put(0 if has_fan else -1, True)
            put(sum(row.get("tag") != "fan-reply" for row in control[2:]))
            index = 2
            while index < len(control):
                row = control[index]; tag = row.get("tag"); index += 1
                if tag == "now":
                    ok, sec, nsec, error = now(row)
                    put(0); put(int(ok)); put(sec, True); put(nsec, True); put(error, True)
                elif tag == "poll":
                    row_shape(row, {"tag", "count", "errno", "revents"})
                    error = errno_value(row["errno"]); count = integer(row["count"], -1, 2)
                    if (count < 0) != bool(error) or type(row["revents"]) is not list or len(row["revents"]) > 2:
                        raise ValueError("guest poll")
                    seen = []
                    for item in row["revents"]:
                        if type(item) is not dict or set(item) != {"role", "revents"} or item["role"] not in {"fan", "exec"} or item["role"] in seen:
                            raise ValueError("guest poll roles")
                        seen.append(item["role"])
                        integer(item["revents"], -(1 << 15), (1 << 15) - 1)
                    if seen != [role for role in ("fan", "exec") if role in seen] or ("fan" in seen) != has_fan:
                        raise ValueError("guest poll order")
                    values = [item["revents"] for item in row["revents"]]
                    put(1); put(count, True); put(error, True)
                    put(values[0] & 65535 if values else 0); put(values[1] & 65535 if len(values) == 2 else 0)
                elif tag == "wait":
                    row_shape(row, {"tag", "pid", "status", "errno"})
                    waited = integer(row["pid"], -(1 << 31), (1 << 31) - 1); error = errno_value(row["errno"])
                    if (waited < 0) != bool(error):
                        raise ValueError("guest wait")
                    put(2); put(waited, True); put(integer(row["status"], -(1 << 31), (1 << 31) - 1), True); put(error, True)
                elif tag == "population":
                    row_shape(row, {"tag", "bytes", "errno"})
                    error = errno_value(row["errno"]); raw = unhex(row["bytes"], 255)
                    if error and raw:
                        raise ValueError("guest population")
                    put(3); put(int(not error)); blob(raw)
                elif tag == "exec-read":
                    row_shape(row, {"tag", "bytes", "eof", "errno"})
                    error = errno_value(row["errno"]); raw = unhex(row["bytes"], 32)
                    if type(row["eof"]) is not bool or error and (raw or row["eof"]) or not error and row["eof"] != (not raw):
                        raise ValueError("guest exec channel")
                    put(4); put(-1 if error else len(raw), True); put(error, True); blob(raw)
                elif tag == "kill":
                    row_shape(row, {"tag", "return", "errno"})
                    result = integer(row["return"], 0, 1)
                    if result and row["errno"] is not None or not result and row["errno"] is None:
                        raise ValueError("guest kill errno")
                    error = 0 if row["errno"] is None else integer(row["errno"], 0, (1 << 31) - 1)
                    put(6); put(result, True); put(error, True)
                elif tag == "fan-read":
                    row_shape(row, {"tag", "bytes", "errno", "return", "events"})
                    result = integer(row["return"], -1, 4096); error = errno_value(row["errno"]); raw = unhex(row["bytes"], 4096)
                    if (result < 0) != bool(error) or len(raw) != max(0, result) or type(row["events"]) is not list or len(row["events"]) > 256:
                        raise ValueError("guest fan read")
                    put(5); put(result, True); put(error, True); blob(raw)
                    for event in row["events"]:
                        if type(event) is not dict or set(event) != {"fd", "stat"}:
                            raise ValueError("guest fan event")
                        integer(event["fd"], 0, (1 << 31) - 1)
                        temporary = {"event": event["stat"]}
                        groups["fan"] = temporary; used["fan"] = set()
                        ok, values = metadata("fan", "event")
                        put(0 if ok else -1, True)
                        put(values["mode"] if ok else 0); put(values["size"] if ok else 0, True)
                        put(values["dev"] if ok else 0); put(values["ino"] if ok else 0)
                        written = 0
                        while written < 8:
                            if index >= len(control):
                                raise ValueError("guest missing fan reply")
                            reply = control[index]; index += 1
                            row_shape(reply, {"tag", "errno", "return"})
                            if reply["tag"] != "fan-reply":
                                raise ValueError("guest fan reply order")
                            count = integer(reply["return"], -1, 8); error = errno_value(reply["errno"])
                            if (count < 0) != bool(error) or count > 8 - written:
                                raise ValueError("guest fan reply")
                            put(9); put(count, True); put(error, True)
                            if count <= 0:
                                break
                            written += count
                else:
                    raise ValueError("guest control tag")
    if counters:
        for name, maximum in (("cpu_stat", 255), ("memory_peak", 127), ("pids_peak", 127)):
            ok, raw = read("counters", name, maximum)
            put(int(ok)); blob(raw)
            if name != "cpu_stat":
                _, events = read("counters", "memory_events" if name == "memory_peak" else "pids_events", 255, True)
                blob(events)
        for name in ("stdout", "stderr"):
            ok, values = metadata("counters", name)
            put(int(ok)); put(values["size"] if ok else 0)
            _, raw = io("counters", name + "_bytes", 10 * 1024 * 1024, True)
            blob(raw)
        entries = 0
        while "entry_%04d_name" % entries in counters:
            entries += 1
            if entries > 10000:
                raise ValueError("guest evidence entries")
        put(entries)
        for index in range(entries):
            _, name = io("counters", "entry_%04d_name" % index, 255, True)
            if not name or b"\0" in name or b"/" in name:
                raise ValueError("guest evidence name")
            blob(name)
            ok, values = metadata("counters", "entry_%04d_stat" % index)
            put(int(ok)); put(values["mode"] if ok else 0); put(values["ino"] if ok else 0); put(values["nlink"] if ok else 0)
        directory, _ = io("counters", "directory")
        put(0 if directory >= 0 else 1, True)
        index = 0
        while "evidence_%04d_size" % index in counters:
            if index >= 10000:
                raise ValueError("guest evidence payloads")
            ok, values = metadata("counters", "evidence_%04d_size" % index)
            put(int(ok)); put(values["size"] if ok else 0)
            ok, values = metadata("counters", "evidence_%04d_report_stat" % index)
            put(int(ok)); put(values["size"] if ok else 0)
            exported, export_stat = metadata("counters", "evidence_%04d_export_stat" % index)
            count, raw = io("counters", "evidence_%04d_bytes" % index, 10 * 1024 * 1024, True)
            if not exported or count != export_stat["size"]:
                raise ValueError("guest evidence export")
            blob(raw); index += 1
        ok, values = metadata("counters", "output", True)
        put(int(ok)); put(values["f_bfree"] if ok else 0)
        ok, values = metadata("counters", "scratch", True)
        put(int(ok))
        for key in ("f_blocks", "f_bfree", "f_frsize"):
            put(values[key] if ok else 0)
    if used["setup"] != set(setup) or used["counters"] != set(counters):
        raise ValueError("guest unused fields")
    return bytes(wire)


def _guest_values(runtime_root, private_work, guest_wire):
    if type(guest_wire) is not bytes or len(guest_wire) > 16 * 1024 * 1024 or not guest_wire.startswith((b"YSVAL01\n", b"YSVAL02\n")):
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


def _seed_require(value):
    if not value:
        raise ValueError("E_RELATION")


def _seed_first(first, later):
    if first is None or (getattr(later, "_scope_signal_cancel", False)
                         and not getattr(first, "_scope_signal_cancel", False)):
        return later
    return first


def _seed_module(value, names):
    source = Path(__file__).resolve().parents[2] / "shadow/v1/_consumer.py"
    matches = []
    for name in ("ystack_shadow_consumer", "scope_shadow_consumer"):
        module = sys.modules.get(name)
        if module is None:
            continue
        if any(type(value) is getattr(module, member) for member in names):
            _seed_require(Path(module.__file__).absolute() == source
                and getattr(module.__spec__, "origin", None) == str(source)
                and module._source_root() == str(source.parents[2]))
            matches.append(module)
    _seed_require(len(matches) == 1)
    return matches[0]


def _S_inventory_core_values(case_id, files, semantic, expected, originals, occurrences):
    _seed_require(case_id in {"malicious.incident-symptom-text", "malicious.checked-file-bytes",
        "malicious.commit-message", "malicious.unread-forge-text"})
    _seed_require(all(type(value) is dict for value in (files, semantic, expected, originals, occurrences))
        and 1 <= len(files) <= 256 and set(files) == set(semantic) == set(expected))
    names = ("incident.json", "reproduction-request.json", "write-request.json", "gate-request.json")
    kinds = ("shadow_incident_record", "shadow_enforced_request", "shadow_write_request", "scope_gate_generation_request")
    _seed_require(set(originals) == set(names) and set(names) <= set(files)
        and set(occurrences) <= set(_CASE_ROLES))
    entries, identities = [], set()
    for name in sorted(files):
        fact, row, source = files[name], semantic[name], expected[name]
        _seed_require(type(name) is str and 0 < len(name) <= 4096
            and all(part not in {"", ".", ".."} for part in name.split("/")))
        _seed_require(type(fact) is dict and set(fact) == {"size_bytes", "sha256", "kind"}
            and fact["kind"] in {"recorded", "runtime", "export", "raw", "M", "W"}
            and type(fact["size_bytes"]) is int and 0 <= fact["size_bytes"] <= 4 << 30
            and type(fact["sha256"]) is str and len(fact["sha256"]) == 64
            and all(char in "0123456789abcdef" for char in fact["sha256"]))
        _seed_require(type(row) is dict and set(row) == {"occurrence", "role", "member", "file", "size_bytes", "sha256"}
            and row["file"] == name and type(row["size_bytes"]) is int
            and row["size_bytes"] == fact["size_bytes"] and row["sha256"] == fact["sha256"]
            and type(source) is tuple and len(source) == 5 and type(source[3]) is int
            and source == (row["occurrence"], row["role"], row["member"], row["size_bytes"], row["sha256"]))
        occurrence, role, member = source[:3]
        _seed_require(type(member) is str and 0 < len(member) <= 4096 and "\0" not in member)
        if role == "original-input":_seed_require(occurrence == "case" and name == member and name in names)
        elif role == "raw-observations":_seed_require(occurrence == "case" and name == member == "raw-observations.json")
        elif role == "preparation":_seed_require(occurrence in {"reproduction.prepare", "reproduction.inspect", "write.prepare", "write.inspect"} and occurrence in occurrences)
        else:_seed_require(role in {"recorded", "capture", "local-runtime", "parent-input"}
            and occurrence in {"reproduction", "write", "kill", "coverage"} and occurrence in occurrences)
        identity = (occurrence, role, member)
        _seed_require(identity not in identities);identities.add(identity)
        entries.append(dict(row))
    for name, kind in zip(names, kinds):
        original = originals[name]
        _seed_require(type(original) is dict and set(original) == {"kind", "id", "size_bytes", "sha256"}
            and original["kind"] == kind and type(original["id"]) is str and original["id"]
            and original["size_bytes"] == files[name]["size_bytes"] and original["sha256"] == files[name]["sha256"]
            and semantic[name]["role"] == "original-input")
    bindings = []
    for role in _CASE_ROLES:
        if role not in occurrences:continue
        occurrence = occurrences[role]
        _seed_require(type(occurrence) is dict and set(occurrence) == {"role", "binding", "raw"}
            and occurrence["role"] == role and type(occurrence["binding"]) is dict)
        binding = occurrence["binding"]
        if role in {"gate", "kill", "coverage"}:
            key = "request_sha256" if role == "gate" else "gate_request_sha256"
            _seed_require(binding[key] == originals["gate-request.json"]["sha256"])
        else:
            launch = role.split(".")[0]
            original = originals[launch + "-request.json"]
            _seed_require(binding["outer_request_sha256"] == original["sha256"] and binding["attempt_id"] == original["id"])
        bindings.append({"role": role, "binding": dict(binding)})
    return {"case_id": case_id, "entries": entries, "originals": {name: dict(originals[name]) for name in names},
        "occurrences": bindings}


class _SeedAssembly:

    def __init__(self, destination, anchor, case_id, window_work, case_work):
        self.c = _seed_module(destination, ("HeldPath",))
        c = self.c
        _seed_require(type(anchor) is c.Anchor)
        self.anchor, self.resolver = anchor, anchor.resolver
        c._require(case_id in {"malicious.incident-symptom-text", "malicious.checked-file-bytes",
            "malicious.commit-message", "malicious.unread-forge-text"} and type(window_work) is dict,
            "E_STORE")
        self.case_id, self.window = case_id, window_work
        self.work, self.files, self.stages, self.output_holds = {}, {}, [], []
        self.semantic, self.semantic_expected, self.original_bindings = {}, {}, {}
        self.root, self.failure, self.closed, self.raw = None, None, False, None
        self.exports = None
        self._released_holds = []
        self.occurrences, self.bindings, self.closed_stages = {}, {}, set()
        self.gate_session, self.coverage_required = None, None
        self._gate_owner = None
        self.gate_close_attempted, self.gate_close_returned = False, False
        self.incident, self.identifiers, self.locators = None, {}, {}
        c._capture_work_values(self.work, "C1-seed")
        _seed_require(type(case_work) is dict and any(case_work is value for value in window_work.get("cases", {}).values()))
        self.case_work = case_work
        self.case_sources = [case_work]
        cases = window_work.setdefault("C1_cases", [])
        _seed_require(case_id not in cases and len(cases) < 4)
        cases.append(case_id)
        self.work["runtime_case_carry_in"] = self.case_work.setdefault("runtime", {})
        self.work["runtime_window_carry_in"] = window_work.setdefault("runtime", {})
        self.runtime_bytes, self.runtime_files, self.source_occurrences = 0, 0, set()
        try:
            destination.recheck("E_STORE")
            _seed_require(not destination.listdir())
            rows = c._clone(destination, "E_STORE", self.work, "M")
            try:self.root = c.HeldPath(destination.path, rows, recording_work=self.work, accounting_kind="M")
            except BaseException as primary:
                c._release_held_acquisition(rows, None, primary, self.work)
                raise
            self._root_check()
            self._transfer()
        except BaseException as error:
            self._failed(error, "seed-open")
            self.close(error)
            raise

    def _failed(self, error, site):
        self.failure = _seed_first(self.failure, error)
        try:self.work["seed_incomplete"] = True
        except MemoryError as later:self.failure = _seed_first(self.failure, later)
        try:self.c._capture_observation_error(self.work, "M", site, error)
        except BaseException as later:self.failure = _seed_first(self.failure, later)

    def _transfer(self):
        try:
            self.c._capture_transfer_work(self.work, self.window, self.case_work)
            previous = self.work.setdefault("transferred_seed_processing", {})
            for field, current in self.work.get("seed_processing", {}).items():
                delta = current - previous.get(field, 0)
                _seed_require(delta >= 0)
                for target in (self.window, self.case_work):
                    counts = target.setdefault("seed_processing", {})
                    counts[field] = counts.get(field, 0) + delta
                previous[field] = current
        except BaseException as error:
            self.work["transfer_incomplete"] = True
            self._failed(error, "seed-transfer")
            raise self.failure

    def _root_check(self):
        c = self.c
        self.root.recheck("E_STORE")
        before = c._capture_metadata(self.root.fd, self.work, "M")
        access, default = c._acl_state(self.root.fd, self.resolver)
        c._capture_observe(self.work, "M", "seed-root-acl", {"access": access, "default": default})
        _seed_require(c._store_values(os.geteuid(), os.getegid(), 0o700, True,
            c._stat_values(before), access, default, sys.platform))
        _seed_require(c._identity(before) == c._identity(self.root.before))

    def _include_case(self, copied):
        _seed_require(copied.work is self.window
            and any(copied.case_work is value for value in self.window.get("cases", {}).values()))
        if not any(copied.case_work is value for value in self.case_sources):
            self.case_sources.append(copied.case_work)

    def _runtime(self, field, amount, *, commit=True):
        counts = {}
        for source in self.case_sources:
            for key, value in source.get("runtime", {}).items():
                _seed_require(key in self.c._RUNTIME_FIELDS and type(value) is int and value >= 0)
                counts[key] = counts.get(key, 0) + value
        self.work["runtime_case_carry_in"] = counts
        self.c._runtime_account(self.work, field, amount, commit=commit)

    def _charge(self, field, amount, kind):
        c = self.c
        _seed_require(type(amount) is int and amount >= 0)
        counts = self.work.setdefault("seed_processing", {})
        counts[field] = counts.get(field, 0) + amount
        if kind == "runtime":
            mapping = {"R": "read_bytes", "W": "write_bytes", "H": "sha_bytes",
                       "E": "equality_bytes", "C": "copy_bytes"}
            self._runtime(mapping[field], amount)
        if kind == "runtime":
            if field == "W":self._runtime("physical_bytes", amount)
            return
        if field in {"R", "W"}:
            c._capture_copy_room(self.work, amount, kind == "export")
            self.work["read_bytes" if field == "R" else "write_bytes"] += amount
            if field == "W":self.work["physical_bytes"] += amount
            if kind == "export":
                self.work["export_read_bytes" if field == "R" else "export_write_bytes"] += amount
                if field == "W":self.work["export_physical_bytes"] += amount
            elif kind != "runtime":
                category = "raw" if kind == "recorded" else kind
                c._capture_account(self.work, category, "read_bytes" if field == "R" else "write_bytes", amount)
                if field == "W":c._capture_account(self.work, category, "physical_bytes", amount)

    def _read(self, fd, size, offset, kind):
        if kind == "runtime":self._runtime("read_bytes", size, commit=False)
        else:self.c._capture_copy_room(self.work, size, kind == "export")
        try:raw = os.pread(fd, size, offset)
        except BaseException:
            self.work["read_incomplete"] = True
            raise
        self._charge("R", len(raw), kind)
        _seed_require(len(raw) == size)
        return raw

    def _close_fd(self, fd, primary=None):
        failure = primary
        error = None
        try:os.close(fd)
        except BaseException as later:
            error = later
            failure = _seed_first(failure, later)
        try:
            self.work["close_calls"] = self.work.get("close_calls", 0) + 1
            self.c._capture_observe(self.work, "M", "seed-close", {"return": 0 if error is None else -1,
                "errno": None if error is None else getattr(error, "errno", None)})
        except BaseException as later:failure = _seed_first(failure, later)
        if failure is not None:
            self._failed(failure, "seed-close")
            if failure is not primary:raise failure

    def _source_check(self, owner, held, anchor, mode=0o400):
        _seed_require(type(held) is owner.HeldPath and bool(held.components))
        held.recheck("E_STORE", self.work, "M")
        _seed_require(stat.S_ISREG(held.before.st_mode) and held.before.st_nlink == 1
                      and stat.S_IMODE(held.before.st_mode) == mode)
        access, default = owner._acl_state(held.fd, anchor.resolver)
        self.c._capture_observe(self.work, "M", "seed-source-acl", {"access": access, "default": default})
        _seed_require(access == [] if sys.platform == "darwin" else access is None and default is None)
        held.recheck("E_STORE", self.work, "M")

    def _copy(self, anchor, held, name, expected, kind):
        try:
            owner = _seed_module(anchor, ("Anchor",))
            _seed_require(id(held) not in self.source_occurrences)
            result = self._copy_file(owner, anchor, held, name, expected, kind)
            self.source_occurrences.add(id(held))
            return result
        except BaseException as error:
            self._failed(error, "seed-copy-final")
            raise self.failure

    def _copy_file(self, owner, anchor, held, name, expected, kind, *, source_mode=None):
        c = self.c
        _seed_require(self.failure is None and not self.closed and name not in self.files
                      and ("/" not in name or kind == "export" and name in {"exports/reproduction.bin", "exports/write.bin"})
                      and c._sha(expected) and len(self.files) < 256)
        source_mode = (0o440 if kind == "recorded" else 0o400) if source_mode is None else source_mode
        self._root_check()
        self._source_check(owner, held, anchor, source_mode)
        size = held.before.st_size
        _seed_require(0 <= size <= (4 << 30 if kind == "runtime" else c.EXPORT_LIMIT if kind == "export" else 64 * c.DOCUMENT_LIMIT if kind == "recorded" else c.DOCUMENT_LIMIT))
        if kind == "runtime":
            _seed_require(self.runtime_files < 64 and self.runtime_bytes + size <= 4 << 30)
            self._runtime("physical_files", 1, commit=False)
        directory = self._exports() if kind == "export" else self.root
        filename = name.rsplit("/", 1)[-1]
        state = directory.before
        primary, target = None, None
        measured = hashlib.sha256()
        try:
            target = os.open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o400, dir_fd=directory.fd)
            if kind != "runtime":self.work["files"] += 1
            if kind == "export":self.work["export_files"] += 1
            if kind == "runtime":self._runtime("physical_files", 1)
            offset = 0
            while offset < size:
                raw = self._read(held.fd, min(65536, size - offset), offset, kind)
                if kind == "runtime":self._runtime("sha_bytes", len(raw), commit=False)
                measured.update(raw);self._charge("H", len(raw), kind)
                view = memoryview(raw)
                while view:
                    amount = min(len(view), 65536)
                    if kind == "runtime":
                        for field in ("write_bytes", "physical_bytes", "copy_bytes"):
                            self._runtime(field, amount, commit=False)
                    else:c._capture_copy_room(self.work, amount, kind == "export")
                    count = os.write(target, view[:65536])
                    _seed_require(0 < count <= min(len(view), 65536))
                    try:
                        self._charge("W", count, kind);self._charge("C", count, kind)
                    except BaseException as error:
                        self._failed(error, "seed-written-accounting")
                        try:
                            self.work["write_accounting_incomplete"] = True
                            self.work.setdefault("observed_write_failures", []).append({"name": name, "return": count})
                        except BaseException as later:self._failed(later, "seed-written-accounting-log")
                        raise self.failure
                    view = view[count:]
                offset += len(raw)
            _seed_require(measured.hexdigest() == expected)
            os.fsync(target)
        except BaseException as error:
            primary = error
            self._failed(error, "seed-copy")
            raise
        finally:
            if target is not None:self._close_fd(target, primary)
        self._refresh_S(state, directory)
        os.fsync(directory.fd)
        installed = c._open_child(directory, filename, False,
            c._store_rule(os.geteuid(), os.getegid(), 0o400, False, self.resolver), "E_STORE",
            recording_work=self.work, accounting_kind="M")
        self._adopt_output(installed)
        _seed_require(installed.before.st_size == size)
        left_hash, right_hash = hashlib.sha256(), hashlib.sha256()
        self._source_check(owner, held, anchor, source_mode)
        installed.recheck("E_STORE")
        offset = 0
        while offset < size:
            count = min(65536, size - offset)
            left = self._read(held.fd, count, offset, kind)
            right = self._read(installed.fd, count, offset, kind)
            if kind == "runtime":
                self._runtime("sha_bytes", len(left) + len(right), commit=False)
                self._runtime("equality_bytes", len(left) + len(right), commit=False)
            left_hash.update(left);right_hash.update(right)
            self._charge("H", len(left) + len(right), kind)
            self._charge("E", len(left) + len(right), kind)
            _seed_require(left == right)
            offset += count
        _seed_require(left_hash.hexdigest() == right_hash.hexdigest() == measured.hexdigest() == expected)
        self._source_check(owner, held, anchor, source_mode)
        installed.recheck("E_STORE")
        self.files[name] = {"size_bytes": size, "sha256": expected, "kind": kind}
        if kind == "runtime":
            self.runtime_files += 1;self.runtime_bytes += size
        self._transfer()
        return installed

    def _adopt_output(self, held):
        try:self.output_holds.append(held)
        except BaseException as primary:
            self._failed(primary, "seed-hold-registration")
            if not (self.output_holds and self.output_holds[-1] is held):
                try:held.close()
                except BaseException as later:self._failed(later, "seed-hold-registration-close")
            raise self.failure

    def _refresh_S(self, state, directory=None):
        directory = self.root if directory is None else directory
        self.c._refresh_recording_directory(directory, state, self.work)
        index = len(directory.components) - 1
        for previous in self.output_holds:
            if os.path.commonpath((previous.path, directory.path)) != directory.path:continue
            before = previous.components[index].before
            current = directory.before
            _seed_require((before.st_dev, before.st_ino, before.st_uid, before.st_gid, before.st_mode)
                == (current.st_dev, current.st_ino, current.st_uid, current.st_gid, current.st_mode))
            previous.components[index].before = current

    def _exports(self):
        if self.exports is None:
            self._root_check()
            before = self.root.before
            os.mkdir("exports", 0o700, dir_fd=self.root.fd)
            self.c._capture_observe(self.work, "M", "seed-export-directory", {"return": 0, "errno": None})
            self._refresh_S(before)
            held = self.c._open_child(self.root, "exports", True,
                self.c._store_rule(os.geteuid(), os.getegid(), 0o700, True, self.resolver), "E_STORE",
                recording_work=self.work, accounting_kind="M")
            self._adopt_output(held)
            self.exports = held
        self.exports.recheck("E_STORE")
        return self.exports

    def _native(self, native, phase):
        owner = _seed_module(native, ("_HeldStoreRead", "_HeldCoverageRead"))
        _seed_require(type(native.anchor) is owner.Anchor and bool(native.held)
            and type(native.capture) is owner._HeldCaptureRead
            and native.capture.native is native and native.capture.anchor is native.anchor
            and native.capture.attempt_id == native.attempt_id
            and type(native.capture.request_raw) is bytes and bool(native.capture.held))
        if phase in {"kill", "coverage"}:_seed_require(type(native) is owner._HeldCoverageRead)
        else:_seed_require(type(native) is owner._HeldStoreRead)
        native.recheck("E_STORE")
        groups = owner._capture_for_replay(native.capture.snapshots, native.attempt_id, native.capture.request_raw)
        completion = native.capture.completion_owner
        _seed_require(completion is native.anchor.capture_completion_owner
            and completion.module is sys.modules.get("ystack_capture_completion_owner")
            and completion.module.__loader__ is completion)
        expected = completion.construct(native.anchor, native.attempt_id,
            native.capture.request_raw, native.capture.snapshots["capture.json"])
        completion.transfer(self.window, self.case_work)
        _seed_require(expected == native.capture.snapshots["complete.json"])
        return owner, groups

    def _P_files(self, owner, phase, native, capture_P, local_P):
        _seed_require(type(capture_P) is owner._HeldCaptureCopy and capture_P.anchor is native.anchor
            and not capture_P.closed and capture_P.directory is not None)
        if phase in {"reproduction", "write"}:
            _seed_require(capture_P.directory.components[-1].name == phase)
        else:
            _seed_require(capture_P.directory.components[-1].name.startswith("source-")
                and len(capture_P.directory.components[-1].name) == 11
                and all(char in "0123456789" for char in capture_P.directory.components[-1].name[7:])
                and int(capture_P.directory.components[-1].name[7:]) < 4096)
        _seed_require(type(local_P) in (list, tuple) and len(local_P) <= 64)
        carriers = [capture_P, *local_P]
        _seed_require(len({id(item) for item in carriers}) == len(carriers))
        facts, bindings = [], []
        for index, copied in enumerate(carriers):
            _seed_require(type(copied) is owner._HeldCaptureCopy and copied.anchor is native.anchor
                and not copied.closed and bool(copied.owned) and copied.directory is not None)
            self._include_case(copied)
            copied.recheck()
            _seed_require(not owner._capture_work_incomplete(copied.leaf) and not copied.leaf.get("metadata_failure"))
            if copied is capture_P:
                semantic_role = "capture"
                expected_names = set(native.capture.snapshots) | {"origin-observation.json", "consumer-observations.json"}
                if "sandbox-export.bin" in native.capture.snapshots:expected_names.add("launch-binding.json")
                _seed_require(set(copied.members) == expected_names)
                expected_bytes = native.capture.snapshots | {"origin-observation.json": native.capture_origin}
            elif set(copied.members) == {"parent-frame.bin", "helper-build-record.json", "native-dependency-record.json"}:
                semantic_role = "parent-input"
                row = native.anchor.private_observations["parent_inputs"]
                _seed_require(row["attempt_id"] == self.c._json(self.bindings[phase]["caller_raw"], self.c.DOCUMENT_LIMIT, "E_STORE")["id"] and row["request_sha256"] == owner.digest(self.bindings[phase]["caller_raw"]))
                expected_bytes = {}
                expected_rows = {row["file"]: row for row in row["files"]}
            elif copied.directory.components[-1].name in {"preparation-runtime-prepare", "preparation-runtime-inspect"}:
                operation = copied.directory.components[-1].name.rsplit("-", 1)[1]
                previous = self.bindings[phase + "." + operation]
                _seed_require(previous["P"][0] is copied)
                continue
            else:
                semantic_role = "local-runtime"
                expected_bytes = {}
                rows = native.anchor.private_observations["local_runtime"]
                caller = self.bindings[phase]["caller_raw"]
                expected_rows = {row["file"]: row for row in rows
                    if row["attempt_id"] == self.c._json(caller, self.c.DOCUMENT_LIMIT, "E_STORE")["id"]
                    and row["request_sha256"] == owner.digest(caller)}
                _seed_require(set(copied.members) <= set(expected_rows) and copied.runtime_sha256)
            for name, held in sorted(copied.members.items()):
                _seed_require(type(name) is str and "/" not in name and type(held) is owner.HeldPath)
                if name in copied.runtime_sha256:
                    expected, kind = copied.runtime_sha256[name], "runtime"
                elif name == "sandbox-export.bin":
                    value = native.capture.snapshots[name]
                    _seed_require(type(value) is owner._ExportSnapshot)
                    expected, kind = value.acquisition_sha, "export"
                elif name in expected_bytes:
                    value = expected_bytes[name]
                    _seed_require(type(value) is bytes)
                    expected, kind = owner.digest(value), "W" if name == "complete.json" else "raw"
                elif name in {"consumer-observations.json", "launch-binding.json"}:
                    value = held.read(owner.DOCUMENT_LIMIT, "E_STORE", self.work)
                    parsed = owner._json(value, owner.DOCUMENT_LIMIT, "E_STORE")
                    _seed_require(owner.canonical(parsed) == value and parsed["attempt_id"] == native.attempt_id
                        and parsed["request_sha256"] == owner.digest(native.capture.request_raw))
                    expected, kind = owner.digest(value), "M"
                else:
                    _seed_require(name in expected_rows and held.before.st_size == expected_rows[name]["size_bytes"])
                    expected, kind = expected_rows[name]["sha256"], "M"
                output = "exports/" + phase + ".bin" if kind == "export" else phase + "-" + str(index).zfill(2) + "-" + name
                installed = self._semantic_copy(native.anchor, held, output, expected, kind,
                    phase, semantic_role, copied.directory.components[-1].name + "/" + name)
                facts.append((name, expected, installed.before.st_size))
            copied.recheck()
        if phase in {"reproduction", "write"}:
            _seed_require(all(phase + "." + operation in self.bindings for operation in ("prepare", "inspect")))
            _seed_require(any(set(item.members) == {"parent-frame.bin", "helper-build-record.json", "native-dependency-record.json"}
                              for item in local_P))
        return carriers, bindings, facts

    def _stage(self, phase, native, capture_P, local_P, outer_raw=None, expectation_raw=None):
        _seed_require(self.failure is None and not self.closed and phase not in self.occurrences)
        if phase in {"reproduction", "write"}:
            _seed_require(phase + ".inspect" in self.occurrences)
        else:_seed_require(self.gate_session is not None)
        try:
            owner, groups = self._native(native, phase)
            request_raw = native.capture.request_raw
            if phase in {"reproduction", "write"}:
                _seed_require(type(outer_raw) is bytes and type(expectation_raw) is bytes)
                kind = "shadow_enforced_request" if phase == "reproduction" else "shadow_write_request"
                projected = owner._launch_capture_values(native.capture.snapshots["capture.json"], outer_raw,
                    request_raw, expectation_raw, native.snapshots["receipt.json"], kind)
                _seed_require(projected == native.projected_capture)
            else:
                _seed_require(type(native.configuration) is owner._CoverageConfiguration)
                native.configuration.normalizer.request(request_raw)
                original = self.gate_session.kill_request_raw if phase == "kill" else self.gate_session.coverage_request_raw
                _seed_require(original == request_raw and native.snapshots["payload/request.json"] == request_raw
                    and ((phase == "kill" and native.configuration.operation == "kill-register-read")
                         or (phase == "coverage" and native.configuration.operation == "coverage-read")))
            for index, (name, raw) in enumerate(sorted(native.snapshots.items())):
                _seed_require(type(raw) is bytes)
                expected_path = os.path.join(native.anchor.config["store_root"], native.attempt_id, name)
                matches = [item for item in native.held if item.path == expected_path]
                _seed_require(len(matches) == 1)
                self._semantic_copy(native.anchor, matches[0], phase + "-recorded-" + str(index).zfill(3) + ".bin",
                    self._digest(raw), "recorded", phase, "recorded", name)
            self.bindings[phase] = {"caller_raw": outer_raw if outer_raw is not None else request_raw}
            carriers, bindings, facts = self._P_files(owner, phase, native, capture_P, local_P)
            self.stages.append({"phase": phase, "native": native, "owner": owner, "groups": groups,
                "P": carriers, "T": bindings, "facts": facts, "request_raw": request_raw,
                "outer_raw": outer_raw, "expectation_raw": expectation_raw})
            self.stages[-1]["caller_raw"] = outer_raw if outer_raw is not None else request_raw
            self.bindings[phase] = self.stages[-1]
            local = self._local(owner, native.anchor, capture_P, phase, local_P)
            if phase in {"reproduction", "write"}:
                outer = owner._json(outer_raw, owner.DOCUMENT_LIMIT, "E_STORE")
                self.identifiers[phase] = outer["id"]
                binding = {"attempt_id": outer["id"], "outer_request_sha256": self._digest(outer_raw),
                    "request_sha256": self._digest(request_raw), "operation": "launch"}
            else:
                binding = {"gate_request_sha256": self.gate_session.binding, "attempt_id": native.attempt_id,
                    "request_sha256": self._digest(request_raw),
                    "operation": "kill-register-read" if phase == "kill" else "coverage-read"}
            self.occurrences[phase] = {"role": phase, "binding": binding, "raw": {"local": local, "capture": groups}}
            self.locators[phase] = self._locators(owner, native.anchor, carriers)
            self._transfer()
        except BaseException as error:
            self._failed(error, "seed-stage-" + phase)
            raise self.failure

    def reproduction(self, native, capture_P, local_P, outer_raw, expectation_raw):
        self._stage("reproduction", native, capture_P, local_P, outer_raw, expectation_raw)

    def write(self, native, capture_P, local_P, outer_raw, expectation_raw):
        self._stage("write", native, capture_P, local_P, outer_raw, expectation_raw)

    def kill(self, native, capture_P, local_P):
        self._stage("kill", native, capture_P, local_P)
        self.kill_terminal_phase = (self.gate_session.phase, self.gate_session.coverage_request_raw)

    def coverage(self, native, capture_P, local_P):
        self._stage("coverage", native, capture_P, local_P)

    def _digest(self, raw, kind="raw"):
        _seed_require(type(raw) is bytes)
        self._charge("H", len(raw), kind)
        return self.c.digest(raw)

    def _locators(self, owner, anchor, carriers):
        values = {"installed_anchor": owner.ANCHOR, "store": anchor.config["store_root"],
                  "work": anchor.config["work_root"]}
        for copied in carriers:
            for row in anchor.private_observations.get("local_runtime", []):
                if row["file"] in copied.members:
                    values[row["slot"] + "." + str(row["ordinal"])] = row["locator"]
        for name, value in values.items():
            _seed_require(type(value) is str and value.startswith("/") and "\0" not in value
                          and len(os.fsencode(value)) <= 4096)
        return values

    def _consumer_snapshot(self, owner, anchor, capture_P, phase):
        _seed_require(type(capture_P) is owner._HeldCaptureCopy and capture_P.anchor is anchor
            and not capture_P.closed and type(capture_P.consumer_snapshot) is bytes)
        held = capture_P.members["consumer-observations.json"]
        raw = held.read(owner.DOCUMENT_LIMIT, "E_STORE", self.work)
        document = owner._json(raw, owner.DOCUMENT_LIMIT, "E_STORE")
        equal = raw == capture_P.consumer_snapshot
        self._wrapper_processed("consumer-snapshot-compare", len(raw) + len(capture_P.consumer_snapshot))
        _seed_require(equal and document["identity_context"] == anchor.identity_context)
        captured_storage = document["storage_reads"]
        current_storage = anchor.private_observations.get("storage_reads", [])
        _seed_require(type(captured_storage) is list and captured_storage == current_storage[:len(captured_storage)])
        if phase in {"kill", "coverage"}:
            reader = getattr(anchor, "scope_runtime_owner", None)
            module = self._gate_type(reader, "scope/v1/read-shadow-evidence.py", "_Reader")
            _seed_require(reader.anchor is anchor)
            if phase == "kill":_seed_require(reader is self.generator.reader)
            else:
                remote = reader.store_session
                _seed_require(type(remote) is module._GateReaderSession and remote.is_inner
                    and remote.kill_request_raw == self.gate_session.kill_request_raw
                    and remote.gate_call_ref == self.gate_session.gate_call_ref)
            module._scope_runtime_prefix_values(document["commands"]["runtime_values"],
                anchor.private_observations["commands"]["runtime_values"])
        else:_seed_require(document["commands"] == anchor.private_observations["commands"])
        return document

    def _local(self, owner, anchor, capture_P, phase, carriers):
        document = self._consumer_snapshot(owner, anchor, capture_P, phase)
        source_rows = anchor.private_observations["local_runtime"]
        caller = self.bindings[phase]["caller_raw"]
        rows = [{key: row[key] for key in ("slot", "index", "ordinal", "locator", "file", "size_bytes", "sha256", "errno")}
            for row in source_rows if row["request_sha256"] == owner.digest(caller)]
        _seed_require(rows and {row["file"] for row in rows}
            == {name for copied in carriers if copied is not capture_P
                and not copied.directory.components[-1].name.startswith("preparation-runtime-")
                for name in copied.runtime_sha256})
        owner._runtime_inventory_values({"files": rows})
        value = {"clocks": document["clocks"],
            "storage": {"entries": document["storage"], "identity_context": document["identity_context"]},
            "commands": document["commands"], "runtime": {"files": rows}}
        _seed_require("runtime_values" in value["commands"])
        if phase in {"reproduction", "write"}:
            _seed_require(phase in document["entropy"] and document["entropy"] == anchor.private_observations["entropy"])
            value["entropy"] = document["entropy"]
        return value

    def _preparation(self, launch, operation, copied, source, outer_raw, input_raw, response_raw):
        role = launch + "." + operation
        _seed_require(not self.closed and self.failure is None and role not in self.occurrences)
        if launch == "write":_seed_require("reproduction" in self.occurrences)
        if operation == "inspect":_seed_require(launch + ".prepare" in self.occurrences)
        try:
            owner = _seed_module(source, ("_HeldPreparationSources",))
            _seed_require(type(copied) is owner._HeldCaptureCopy and not copied.closed
                and copied.anchor is source.anchor and type(source.anchor) is owner.Anchor
                and source in copied.T_companions and not source.closed and source.stable)
            self._include_case(copied)
            outer = owner._json(outer_raw, owner.DOCUMENT_LIMIT, "E_STORE")
            _seed_require(outer["kind"] == ("shadow_enforced_request" if launch == "reproduction" else "shadow_write_request")
                and owner._id(outer["id"]))
            binding = source.binding
            _seed_require(binding["operation"] == operation and binding["input_raw"] == input_raw
                and binding["response_raw"] == response_raw and binding["capture_sha256"] == self._digest(binding["capture_raw"]))
            value, runtime, marker = owner._preparation_capture_binding_values(
                binding["capture_raw"], operation, input_raw, response_raw)
            workspace = _preparation_workspace_values(Path(__file__).resolve().parents[2], value["entropy"]["preparation_names"][0])
            _seed_require(_preparation_capture_values(Path(__file__).resolve().parents[2], binding["capture_raw"],
                workspace, operation, input_raw, response_raw) == value)
            _seed_require(marker == binding["marker"] and set(copied.members) == {"capture.json"} | set(runtime)
                and copied.runtime_sha256 == {name: row["sha256"] for name, row in runtime.items()})
            source.recheck();copied.recheck()
            _seed_require(source.stable and not source.failed and not owner._capture_work_incomplete(source.leaf)
                and not owner._capture_work_incomplete(copied.leaf))
            for name, held in sorted(copied.members.items()):
                expected = binding["capture_sha256"] if name == "capture.json" else runtime[name]["sha256"]
                self._semantic_copy(source.anchor, held, role + "-" + name, expected,
                    "raw" if name == "capture.json" else "runtime", role, "preparation", name)
            source.recheck();copied.recheck()
            _seed_require(source.stable and not source.failed)
            self.occurrences[role] = {"role": role,
                "binding": {"attempt_id": outer["id"], "outer_request_sha256": self._digest(outer_raw),
                    "input_sha256": self._digest(input_raw), "response_sha256": self._digest(response_raw),
                    "operation": operation},
                "raw": {"preparation": {key: value[key] for key in _LOCAL_GROUPS}}}
            self.locators[role] = {"scratch": source.directory.path, "work": copied.directory.path}
            self.locators[role].update({row["slot"]: row["locator"] for row in runtime.values()})
            self.bindings[role] = {"P": [copied], "T": [source], "owner": owner,
                "native": None, "caller_raw": outer_raw, "anchor": source.anchor}
            self._transfer()
        except BaseException as error:
            self._failed(error, "seed-" + role)
            raise self.failure

    def reproduction_prepare(self, copied, source, outer_raw, input_raw, response_raw):
        self._preparation("reproduction", "prepare", copied, source, outer_raw, input_raw, response_raw)

    def reproduction_inspect(self, copied, source, outer_raw, input_raw, response_raw):
        self._preparation("reproduction", "inspect", copied, source, outer_raw, input_raw, response_raw)

    def write_prepare(self, copied, source, outer_raw, input_raw, response_raw):
        self._preparation("write", "prepare", copied, source, outer_raw, input_raw, response_raw)

    def write_inspect(self, copied, source, outer_raw, input_raw, response_raw):
        self._preparation("write", "inspect", copied, source, outer_raw, input_raw, response_raw)

    def original_inputs(self, incident, reproduction_request, write_request, gate_request):
        _seed_require(not self.closed and self.incident is None)
        items = (incident, reproduction_request, write_request, gate_request)
        values = []
        try:
            for item in items:
                owner = _seed_module(item, ("_HeldBytes",))
                _seed_require(type(item.held) is owner.HeldPath and type(item.raw) is bytes)
                item.recheck("E_STORE")
                self._charge("R", len(item.raw), "M");self._charge("E", 2 * len(item.raw), "M")
                measured, original = owner.digest(item.raw), item.sha256
                self._charge("H", 2 * len(item.raw), "M")
                _seed_require(measured == original)
                self.work["original_parse_attempt_bytes"] = len(item.raw)
                self.work["original_parse_unknown"] = True
                values.append(owner._json(item.raw, owner.DOCUMENT_LIMIT, "E_STORE"))
                self._wrapper_processed("original-input-parse", len(item.raw))
                self.work["original_parse_unknown"] = False
            names = ("incident.json", "reproduction-request.json", "write-request.json", "gate-request.json")
            kinds = ("shadow_incident_record", "shadow_enforced_request", "shadow_write_request", "scope_gate_generation_request")
            for item, value, name, kind in zip(items, values, names, kinds):
                _seed_require(value["kind"] == kind and self.c._id(value["id"]))
                owner = _seed_module(item, ("_HeldBytes",))
                expected = self._digest(item.raw)
                _seed_require(id(item.held) not in self.source_occurrences)
                self.semantic_expected[name] = ("case", "original-input", name, len(item.raw), expected)
                self._copy_file(owner, self.anchor, item.held, name, expected, "M",
                    source_mode=stat.S_IMODE(item.held.before.st_mode))
                self.source_occurrences.add(id(item.held))
                self.original_bindings[name] = {"kind": kind, "id": value["id"],
                    "size_bytes": len(item.raw), "sha256": expected}
                self._semantic_record("case", "original-input", name, name)
            self.incident = {"observed_at": values[0]["body"]["observed_at"]}
            self.original_raw = tuple(item.raw for item in items)
            self.identifiers = {role: values[index]["id"] for role, index in (("reproduction", 1), ("write", 2), ("gate", 3))}
            self._transfer()
        except BaseException as error:
            self._failed(error, "seed-original-inputs")
            raise self.failure

    def _semantic_record(self, occurrence, role, member, name):
        _seed_require(name in self.files and name not in self.semantic
            and self.semantic_expected[name] == (occurrence, role, member,
                self.files[name]["size_bytes"], self.files[name]["sha256"]))
        row = {"occurrence": occurrence, "role": role, "member": member,
            "file": name, "size_bytes": self.files[name]["size_bytes"], "sha256": self.files[name]["sha256"]}
        self.c._capture_observe(self.work, "M", "seed-semantic-member", row)
        self.semantic[name] = row

    def _semantic_copy(self, anchor, held, name, expected, kind, occurrence, role, member):
        try:
            _seed_require(name not in self.semantic_expected)
            self.semantic_expected[name] = (occurrence, role, member, held.before.st_size, expected)
            result = self._copy(anchor, held, name, expected, kind)
            self._semantic_record(occurrence, role, member, name)
            self._transfer()
            return result
        except BaseException as error:
            self._failed(error, "seed-semantic-copy")
            raise self.failure

    def _gate_type(self, value, relative, name):
        module = sys.modules.get(type(value).__module__)
        expected = Path(__file__).resolve().parents[2] / relative
        _seed_require(module is not None and getattr(module, name, None) is type(value)
            and Path(module.__file__).absolute() == expected
            and getattr(getattr(module, "__spec__", None), "origin", module.__file__) == str(expected))
        return module

    def gate_start(self, generator):
        _seed_require("write" in self.occurrences and self.gate_session is None)
        self._bind_gate(generator)

    def _bind_gate(self, generator):
        _seed_require(self.gate_session is None)
        module = self._gate_type(generator, "scope/v1/generate-gate-evidence.py", "_Generator")
        session = generator.session
        _seed_require(type(session) is module._GateStoreSession and session.generator is generator
            and session.reader is generator.reader and not session.closed
            and session.call_id == self.identifiers["gate"])
        request_raw = self.original_raw[3]
        _seed_require(module.generation_request(request_raw) == generator.request
            and session.binding == self._digest(request_raw))
        generator.check()
        self.gate_session, self.generator = session, generator
        self._gate_owner = generator

    def _gate_request(self):
        module = self._gate_type(self.generator, "scope/v1/generate-gate-evidence.py", "_Generator")
        original = module.generation_request(self.original_raw[3])
        _seed_require(original == self.generator.request and original["id"] == self.identifiers["gate"]
            and self.gate_session.binding == self._digest(self.original_raw[3]))
        return original

    def _reader_observations(self, reader, generator=False):
        module = self._gate_type(reader, "scope/v1/read-shadow-evidence.py", "_Reader")
        reader.recheck()
        anchor = reader.anchor
        _seed_require(anchor is not None)
        _seed_require(getattr(anchor, "scope_runtime_owner", None) is reader)
        observations = anchor.private_observations
        _seed_require("entropy" in observations and "commands" in observations
            and "runtime_values" in observations["commands"] and observations["storage_reads"])
        module._scope_runtime_prefix_values(observations["commands"]["runtime_values"],
            observations["commands"]["runtime_values"])
        storage = [row for acquired in observations["storage_reads"] for row in acquired["entries"]]
        owners = ("scope/v1/generate-gate-evidence.py", "scope/v1/read-shadow-evidence.py") if generator else ("scope/v1/read-shadow-evidence.py",)
        _seed_require(all(path in module.c._clock_observations for path in owners))
        clocks = {path: module.c._clock_observations[path] for path in owners}
        runtime = {"files": [{key: row[key] for key in ("slot", "index", "ordinal", "locator", "file", "size_bytes", "sha256", "errno")}
            for row in observations["local_runtime"]]}
        module.c._runtime_inventory_values(runtime)
        value = {"entropy": observations["entropy"], "commands": observations["commands"],
            "storage": {"entries": storage, "identity_context": anchor.identity_context},
            "clocks": clocks, "runtime": runtime}
        host = sys.modules.get("ystack_capture_completion_owner")
        _seed_require(host is not None and host.__loader__.module is host
            and host._capture_size(value, self.c.DOCUMENT_LIMIT - 1) + 1 <= self.c.DOCUMENT_LIMIT)
        raw = host.canonical(value)
        self.work["read_bytes"] += 3 * len(raw)
        self.c._capture_account(self.work, "M", "read_bytes", 3 * len(raw))
        return self.c._json(raw, self.c.DOCUMENT_LIMIT, "E_STORE")

    def scope_reader_observations(self, reader):
        _seed_require(self.gate_session is not None and not hasattr(self, "scope_reader"))
        module = self._gate_type(reader, "scope/v1/read-shadow-evidence.py", "_Reader")
        remote = reader.store_session
        _seed_require(type(remote) is module._GateReaderSession and remote.is_inner
            and reader is not self.generator.reader
            and remote.kill_request_raw == self.gate_session.kill_request_raw
            and remote.gate_call_ref == self.gate_session.gate_call_ref)
        self.scope_local = self._reader_observations(reader)
        self.scope_raw, self.scope_reader = reader.scope_raw, reader
        self._transfer()

    def gate(self):
        _seed_require(self.gate_session is not None and "gate" not in self.occurrences
            and hasattr(self, "scope_local"))
        session, generator = self.gate_session, self.generator
        generator.check()
        scoped = next(item for item in generator.held if getattr(item, "held", None) is not None
            and item.held.path == str(generator.outputs["scope"]))
        evaluated = next(item for item in generator.held if getattr(item, "held", None) is not None
            and item.held.path == str(generator.outputs["scope-evaluation"]))
        _seed_require(scoped.raw == self.scope_raw)
        result = self.c._json(evaluated.raw, self.c.DOCUMENT_LIMIT, "E_STORE")
        _seed_require(result["kind"] == "scope_qualification_evaluation"
            and result["body"]["scope_ref"]["sha256"] == self._digest(self.scope_raw)
            and session.phase == "FINAL_OWNER" and session.owner_confirmed)
        original_scope = self.c._json(self.scope_raw, self.c.DOCUMENT_LIMIT, "E_STORE")["body"]
        coverage = original_scope["workflow_id"] == "workflow.shadow-evidence-commit"
        _seed_require(coverage == (original_scope["task_class"] == "task.commit-shadow-evidence")
            and coverage == ("coverage" in original_scope)
            and coverage == ("coverage" in result["body"]["evidence"]))
        if not coverage:
            _seed_require(self.kill_terminal_phase == ("K_DONE", None)
                and session.coverage_request_raw is None and "coverage" not in self.occurrences
                and "coverage" not in self.scope_local["entropy"])
        else:
            _seed_require(session.coverage_request_raw is not None and "coverage" in self.occurrences
                and "coverage" in self.scope_local["entropy"])
        self.coverage_required = coverage
        contexts = {"generator": self._reader_observations(generator.reader, True),
                    "scope_reader": self.scope_local}
        original = self._gate_request()
        self.occurrences["gate"] = {"role": "gate", "binding": {"request_id": original["id"],
            "request_sha256": session.binding}, "raw": contexts}
        self.locators["gate"] = {"request": str(generator.paths[0]), "scope": scoped.held.path}
        self._transfer()

    def document(self):
        try:return self._document()
        except BaseException as error:
            self._failed(error, "seed-document")
            raise self.failure

    def _document(self):
        _seed_require(self.failure is None and not self.closed and self.incident is not None
            and self.coverage_required is not None)
        roles = _CASE_ROLES if self.coverage_required else _CASE_ROLES[:-1]
        _seed_require(set(self.occurrences) == set(roles) and set(self.locators) == set(roles))
        for role in ("reproduction", "write"):
            _seed_require(self.bindings[role]["caller_raw"] == self.original_raw[1 if role == "reproduction" else 2])
        rows = [self.occurrences[role] for role in roles]
        self.work["wrapper_incomplete"] = True
        raw = _case_v2_values(self.incident, self.identifiers, self.locators, rows, assembly=self)
        _case_v2_validate(raw, self.incident, self.identifiers, self.locators, rows, assembly=self)
        self.work["wrapper_incomplete"] = False
        self._write_document(raw)
        self.raw = raw
        self._transfer()
        return raw

    def _wrapper_processed(self, site, amount):
        _seed_require(type(amount) is int and amount >= 0)
        self.work["read_bytes"] += amount
        self.c._capture_account(self.work, "M", "read_bytes", amount)
        self.work.setdefault("wrapper_steps", []).append({"site": site, "input_bytes": amount})
        self.c._capture_copy_room(self.work, 0, False, read_only=True)

    def _wrapper_encode(self, value):
        before = self.work["read_bytes"]
        raw, failure = None, None
        try:raw = self.c._private_capture_observations(value, self.work, self.work)
        except BaseException as error:failure = error
        finally:
            processed = self.work["read_bytes"] - before
            try:
                self.c._capture_account(self.work, "M", "read_bytes", processed)
            except BaseException as error:failure = _seed_first(failure, error)
        if failure is not None:
            self._failed(failure, "case-wrapper-encode")
            raise self.failure
        self.c._capture_account(self.work, "M", "logical_bytes", len(raw))
        self.c._capture_account(self.work, "M", "occurrences", 1)
        self.work.setdefault("wrapper_steps", []).append({"site": "encode", "output_bytes": len(raw),
            "processing_bytes": processed})
        return raw

    def _write_document(self, raw):
        _seed_require(type(raw) is bytes and len(raw) <= self.c.DOCUMENT_LIMIT
            and "raw-observations.json" not in self.files and len(self.files) < 256
            and self.failure is None and not self.closed)
        self._root_check()
        expected = self._digest(raw)
        state, target, primary = self.root.before, None, None
        try:
            target = os.open("raw-observations.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o400, dir_fd=self.root.fd)
            self.work["files"] += 1
            offset = 0
            while offset < len(raw):
                chunk = memoryview(raw)[offset:offset + 65536]
                self.c._capture_copy_room(self.work, len(chunk), False)
                count = os.write(target, chunk)
                _seed_require(0 < count <= len(chunk))
                try:
                    self._charge("W", count, "raw");self._charge("C", count, "raw")
                except BaseException as error:
                    self._failed(error, "seed-document-written-accounting")
                    self.work["write_accounting_incomplete"] = True
                    self.work.setdefault("observed_write_failures", []).append({"name": "raw-observations.json", "return": count})
                    raise self.failure
                offset += count
            os.fsync(target)
        except BaseException as error:
            primary = error
            self._failed(error, "seed-document-write")
            raise self.failure
        finally:
            if target is not None:self._close_fd(target, primary)
        self._refresh_S(state)
        os.fsync(self.root.fd)
        held = self.c._open_child(self.root, "raw-observations.json", False,
            self.c._store_rule(os.geteuid(), os.getegid(), 0o400, False, self.resolver), "E_STORE",
            recording_work=self.work, accounting_kind="M")
        self._adopt_output(held)
        _seed_require(held.before.st_size == len(raw))
        measured = hashlib.sha256()
        offset = 0
        while offset < len(raw):
            count = min(65536, len(raw) - offset)
            chunk = self._read(held.fd, count, offset, "raw")
            measured.update(chunk);self._charge("H", len(chunk), "raw")
            self._charge("E", 2 * len(chunk), "raw")
            _seed_require(chunk == memoryview(raw)[offset:offset + count])
            offset += count
        _seed_require(measured.hexdigest() == expected)
        held.recheck("E_STORE")
        self.files["raw-observations.json"] = {"size_bytes": len(raw), "sha256": expected, "kind": "raw"}
        self.semantic_expected["raw-observations.json"] = ("case", "raw-observations", "raw-observations.json", len(raw), expected)
        self._semantic_record("case", "raw-observations", "raw-observations.json", "raw-observations.json")

    def closed_occurrence(self, role):
        _seed_require(role in self.bindings and role not in self.closed_stages)
        stage = self.bindings[role]
        _seed_require(all(item.closed and not item.owned for item in stage["P"])
            and all(item.closed and item.close_complete for item in stage["T"]))
        native = stage["native"]
        if native is not None:
            _seed_require(not native.held and not native.capture.held)
        _seed_require(all(not stage["owner"]._capture_work_incomplete(item.leaf) for item in stage["P"]))
        self.closed_stages.add(role)
        self._transfer()

    def closed_pending(self):
        _seed_require(self.raw is not None and self.closed and self.failure is None)
        _seed_require(set(self.bindings) == set(self.occurrences) - {"gate"}
            and set(self.bindings) == self.closed_stages)
        self._closed_gate()
        _seed_require(not self.c._capture_work_incomplete(self.work))
        return self.raw

    def closed_inventory_core(self):
        self.closed_pending()
        return self._closed_inventory_core_data()

    def _closed_inventory_core_data(self):
        _seed_require(self.closed and self.root is None and not self.output_holds and self.failure is None)
        try:
            self.work["inventory_incomplete"] = True
            core = _S_inventory_core_values(self.case_id, self.files, self.semantic,
                self.semantic_expected, self.original_bindings, self.occurrences)
            raw = self._wrapper_encode(core)
            self._wrapper_processed("inventory-shape", len(raw))
            measured = self._digest(raw)
            self.work["inventory_parse_attempt_bytes"] = len(raw)
            self.work["inventory_parse_unknown"] = True
            decoded = json.loads(raw)
            self._wrapper_processed("inventory-parse", len(raw))
            self.work["inventory_parse_unknown"] = False
            equal = decoded == core
            self._wrapper_processed("inventory-compare", 2 * len(raw))
            _seed_require(equal)
            self.work["inventory_incomplete"] = False
            self._transfer()
            return {"inventory_core": decoded, "sha256": measured}
        except BaseException as error:
            self._failed(error, "seed-inventory-core")
            try:
                if self.work.get("inventory_parse_unknown", False):self.work["inventory_parse_incomplete"] = True
            except BaseException as later:self._failed(later, "seed-inventory-unknown")
            if not self.work.get("transfer_incomplete", False):
                try:self._transfer()
                except BaseException as later:self.failure = _seed_first(self.failure, later)
            if self.work.get("transfer_incomplete", False):
                for counter in (self.window, self.case_work):
                    try:counter["transfer_incomplete"] = True
                    except BaseException as later:self._failed(later, "seed-inventory-transfer-state")
            raise self.failure

    def _closed_gate(self):
        _seed_require(self.failure is None and not self.c._capture_work_incomplete(self.work)
            and self.gate_close_returned and self.gate_session.closed and self.gate_session.owner_confirmed
            and self.gate_session.phase == "COMPLETE" and not self.gate_session.remote)
        _seed_require(not self.generator.active and not self.generator.held
            and not self.generator.reader.owned and not self.scope_reader.owned
            and not self.scope_reader.commands_open)

    def close_gate(self):
        module = self._gate_type(self.generator, "scope/v1/generate-gate-evidence.py", "_Generator")
        _seed_require(self.generator is self._gate_owner and self.generator.session is self.gate_session
            and self.gate_session.generator is self.generator and self.generator.reader is self.gate_session.reader
            and not self.gate_close_attempted and self.generator.active)
        self.gate_close_attempted = True
        primary = sys.exc_info()[1]
        if primary is not None:self.failure = _seed_first(self.failure, primary)
        try:
            module._Generator.close(self.generator)
            self.gate_close_returned = True
            if primary is not None:self._failed(primary, "case-gate-primary")
            self._transfer()
        except BaseException as error:
            self._failed(error, "case-gate-close")
            raise self.failure

    def _namespace_check(self):
        self._root_check()
        names = {name for name in self.files if "/" not in name}
        if self.exports is not None:
            names.add("exports")
            self.exports.recheck("E_STORE")
            expected = {name.split("/", 1)[1] for name in self.files if name.startswith("exports/")}
            _seed_require(set(self.exports.listdir()) == expected)
            self.exports.recheck("E_STORE")
        _seed_require(set(self.root.listdir()) == names)
        self.root.recheck("E_STORE")

    def close(self, primary=None):
        if self.closed:return
        self.closed = True
        failure = _seed_first(primary if primary is not None else sys.exc_info()[1], self.failure)
        if failure is None:
            try:self._namespace_check()
            except BaseException as later:failure = _seed_first(failure, later)
        holds, self.output_holds = self.output_holds, self._released_holds
        for held in reversed(holds):
            if failure is None:
                try:held.recheck("E_STORE")
                except BaseException as later:failure = _seed_first(failure, later)
            try:held.close()
            except BaseException as later:failure = _seed_first(failure, later)
        root, self.root = self.root, None
        if root is not None:
            try:root.close()
            except BaseException as later:failure = _seed_first(failure, later)
        if failure is not None:self._failed(failure, "seed-final-close")
        try:self._transfer()
        except BaseException as later:failure = _seed_first(failure, later)
        if failure is not None:
            self.failure = _seed_first(self.failure, failure)
            if self.failure is not primary:raise self.failure


_CASE_ROLES = ("reproduction.prepare", "reproduction.inspect", "reproduction", "write.prepare",
               "write.inspect", "write", "gate", "kill", "coverage")
_LOCAL_GROUPS = {"entropy", "clocks", "storage", "commands", "runtime"}


def _case_v2_values(incident, attempt_ids, locators, occurrences, *, assembly=None):
    _seed_require(type(incident) is dict and set(incident) == {"observed_at"}
        and type(incident["observed_at"]) is str and 0 < len(incident["observed_at"]) <= 128)
    _seed_require(type(attempt_ids) is dict and set(attempt_ids) == {"reproduction", "write", "gate"}
        and all(type(value) is str and 0 < len(value) <= 128 for value in attempt_ids.values()))
    _seed_require(type(occurrences) is list and len(occurrences) in {8, 9})
    roles = [entry.get("role") if type(entry) is dict else None for entry in occurrences]
    _seed_require(tuple(roles) == _CASE_ROLES[:len(roles)])
    _seed_require(type(locators) is dict and set(locators) == set(roles))
    for role, values in locators.items():
        _seed_require(type(values) is dict and bool(values) and len(values) <= 256)
        for key, value in values.items():
            _seed_require(type(key) is str and bool(key) and type(value) is str
                and value.startswith("/") and "\0" not in value
                and len(value.encode("utf-8")) <= 4096)
    bindings = {}
    for entry in occurrences:
        _seed_require(set(entry) == {"role", "binding", "raw"})
        role, binding, raw = entry["role"], entry["binding"], entry["raw"]
        _seed_require(type(binding) is dict and type(raw) is dict)
        if role.endswith((".prepare", ".inspect")):
            launch, operation = role.split(".")
            expected_keys = {"attempt_id", "outer_request_sha256", "input_sha256", "response_sha256", "operation"}
            _seed_require(set(binding) == expected_keys and binding["operation"] == operation
                and binding["attempt_id"] == attempt_ids[launch] and set(raw) == {"preparation"})
            _seed_require(type(raw["preparation"]) is dict and set(raw["preparation"]) == _LOCAL_GROUPS)
        elif role in {"reproduction", "write"}:
            _seed_require(set(binding) == {"attempt_id", "outer_request_sha256", "request_sha256", "operation"}
                and binding["operation"] == "launch" and binding["attempt_id"] == attempt_ids[role]
                and set(raw) == {"local", "capture"})
            _seed_require(type(raw["local"]) is dict and set(raw["local"]) == _LOCAL_GROUPS)
            _seed_require(type(raw["capture"]) is dict and set(raw["capture"]) <= {"host", "guest", "clocks", "runtime"}
                and {"host", "clocks"} <= set(raw["capture"]))
        elif role == "gate":
            _seed_require(set(binding) == {"request_id", "request_sha256"}
                and binding["request_id"] == attempt_ids["gate"] and set(raw) == {"generator", "scope_reader"})
            for value in raw.values():_seed_require(type(value) is dict and set(value) == _LOCAL_GROUPS)
        else:
            operation = "kill-register-read" if role == "kill" else "coverage-read"
            _seed_require(set(binding) == {"gate_request_sha256", "attempt_id", "request_sha256", "operation"}
                and binding["operation"] == operation and set(raw) == {"local", "capture"})
            _seed_require(type(raw["local"]) is dict and set(raw["local"]) == _LOCAL_GROUPS - {"entropy"})
            _seed_require(type(raw["capture"]) is dict and set(raw["capture"]) <= {"source_pages", "clocks", "runtime"}
                and {"source_pages", "clocks"} <= set(raw["capture"]))
            _seed_require(set(raw["capture"]["source_pages"]) == {role})
        for name, value in binding.items():
            if name.endswith("sha256"):
                _seed_require(type(value) is str and len(value) == 64 and all(c in "0123456789abcdef" for c in value))
        for name, value in raw.items():
            _seed_require(type(value) is dict)
            for group, observations in value.items():
                _seed_require(type(observations) is (list if name == "preparation" and group == "storage" else dict))
        bindings[role] = binding
    for launch in ("reproduction", "write"):
        for operation in ("prepare", "inspect"):
            _seed_require(bindings[launch + "." + operation]["outer_request_sha256"]
                          == bindings[launch]["outer_request_sha256"])
    for source in ("kill", "coverage"):
        if source in bindings:
            _seed_require(bindings[source]["gate_request_sha256"] == bindings["gate"]["request_sha256"])
    value = {"schema_version": 2, "kind": "malicious_raw_observations", "body": {
        "incident": incident, "identities": {"attempt_ids": attempt_ids, "locators": locators},
        "occurrences": occurrences}}
    host = sys.modules.get("ystack_capture_completion_owner")
    source = Path(__file__).resolve().parents[2] / "sandbox/v1/host-supervisor.py"
    _seed_require(host is not None and getattr(host.__spec__, "origin", None) == str(source)
        and getattr(host.__loader__, "module", None) is host
        and getattr(host.__loader__, "loaded", None) is not None)
    measured = host._capture_size(value, 1024 * 1024 - 1) + 1
    _seed_require(measured <= 1024 * 1024)
    if assembly is not None:
        _seed_require(type(assembly) is _SeedAssembly)
        assembly._wrapper_processed("shape", measured)
        assembly._wrapper_processed("size", measured)
        return assembly._wrapper_encode(value)
    return host.canonical(value)


def _case_v2_validate(raw, incident, attempt_ids, locators, occurrences, *, assembly=None):
    _seed_require(type(raw) is bytes and len(raw) <= 1024 * 1024)
    expected = _case_v2_values(incident, attempt_ids, locators, occurrences, assembly=assembly)
    equal = raw == expected
    if assembly is not None:assembly._wrapper_processed("compare", len(raw) + len(expected))
    _seed_require(equal)
    value = json.loads(raw)
    if assembly is not None:assembly._wrapper_processed("parse", len(raw))
    return value
