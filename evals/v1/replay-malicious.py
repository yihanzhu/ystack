#!/usr/bin/python3
import importlib.util
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


def _origin_values(runtime_root, files, storage_rows, identity_context, source_bytes):
    spec = importlib.util.spec_from_file_location(
        "malicious_origin_values", Path(runtime_root) / "shadow/v1/_consumer.py")
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    if "sandbox-export.bin" in files and type(files["sandbox-export.bin"]) is not bytes:
        files = dict(files)
        value = files["sandbox-export.bin"]
        files["sandbox-export.bin"] = value if type(value) is tuple else value.chunks
    return owner._origin_values(files, storage_rows, identity_context, source_bytes)


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


def _guest_wire_values(plan_raw, guest):
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
        if type(row) is not dict or set(row) != set(keys) or len(json.dumps(row, ensure_ascii=False,
                sort_keys=True, separators=(",", ":"), allow_nan=False).encode()) + 1 > 8192:
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
