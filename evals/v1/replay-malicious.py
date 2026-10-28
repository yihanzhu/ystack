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
        return {"case_id": case_id, "disposition": "rejected", "error_token": {"state": "present", "value": "E_REPLAY"},
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



def _reproduction_values(runtime_root, files, materialized, context, *, runtime_work=None):
    if (type(materialized) is not dict or set(materialized) != {
            "response_raw", "evaluation_raw", "qualified_identity_raw"}
            or type(context) is not dict or set(context) != {
                "request", "consumer_source_raw", "python_raw", "jq_sha256",
                "native_context", "commands", "observation", "store_id"}):
        raise ValueError("reproduction values")
    spec = importlib.util.spec_from_file_location(
        "malicious_reproduction_values", Path(runtime_root) / "shadow/v1/enforced-reproduction.py")
    owner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = owner
    spec.loader.exec_module(owner)
    owner.require(type(files) is dict and set(files) == set(owner.EVIDENCE_NAMES)
        - {"consumer-provenance.json", "shadow-record.json"}, "E_RELATION")
    incident = owner.parse(files["incident.json"])
    identity = owner.parse(materialized["qualified_identity_raw"])
    evaluation = owner.parse(materialized["evaluation_raw"])
    receipt = owner.require_no_change(materialized["response_raw"], incident)
    instruction = owner.make_instruction(incident)
    result_raw, result = owner.payload_result({"payload/stdout": files["payload-stdout.txt"],
        "payload/stderr": files["payload-stderr.txt"], "payload/evidence/0000": files["file-digest-result.json"]},
        owner.parse(files["evidence-manifest.json"]), instruction,
        owner.parse(files["preparation-manifest.json"]), owner.parse(files["sandbox-receipt.json"]))
    owner.require(result_raw == files["file-digest-result.json"], "E_RELATION")
    outcome = "no-change" if result["outcome"] == "match" else "reproduced"
    output = dict(files)
    provenance = owner._reproduction_provenance_values(context["request"]["id"], instruction,
        context["observation"], context["native_context"], context["consumer_source_raw"],
        context["python_raw"], context["jq_sha256"], context["commands"], runtime_work=runtime_work)
    output["consumer-provenance.json"] = provenance
    output["shadow-record.json"] = owner._reproduction_record_values(incident, files["incident.json"],
        files["claim.json"], identity, materialized["qualified_identity_raw"], evaluation,
        materialized["evaluation_raw"], materialized["response_raw"], receipt, result,
        files["file-digest-result.json"], outcome, files["registry.json"], context["store_id"],
        files["sandbox-request.json"], files["sandbox-expectation.json"], files["sandbox-receipt.json"],
        files["sandbox-check.json"], files["origin-observation.json"], provenance, output["trace-ledger.json"])
    return output, owner._reproduction_bundle_values(output, incident, "enforced-reproduction.v1")

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


def _host_process_values(runtime_root, config, start_raw, raw_host, raw_clocks,
                         admission_mono, export_raw, plan_sha256):
    import math
    import struct

    spec = importlib.util.spec_from_file_location(
        "malicious_host_process_values", Path(runtime_root) / "sandbox/v1/host-supervisor.py")
    host = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(host)
    (startup_limit, hardstop_limit, sigkill_limit, poll_interval, start_limit,
     export_limit, _storage_limit, _payload_limit) = host._host_deadline_defaults_values()
    if (type(raw_host) is not dict or set(raw_host) != {"process", "driver_rest", "signals"}
            or type(raw_clocks) is not dict or set(raw_clocks) != {"wall", "monotonic"}
            or any(type(raw_host[name]) is not list for name in raw_host)
            or any(type(raw_clocks[name]) is not list for name in raw_clocks)
            or type(admission_mono) not in (int, float) or not math.isfinite(admission_mono)
            or type(plan_sha256) is not str or len(plan_sha256) != 64
            or any(c not in "0123456789abcdef" for c in plan_sha256)):
        raise ValueError("host process inputs")
    if raw_host["signals"]:
        raise ValueError("host signal interleave unavailable: source records signums without position")
    rows = raw_host["process"]
    ordinals = {}
    for row in rows:
        if (type(row) is not dict or set(row) != {"site", "ordinal", "return", "errno", "bytes", "timeout"}
                or type(row["site"]) is not str or type(row["ordinal"]) is not int
                or row["ordinal"] != ordinals.get(row["site"], 0)):
            raise ValueError("host process ordinal")
        ordinals[row["site"]] = row["ordinal"] + 1
    clock_values = {}
    for kind, events in raw_clocks.items():
        values = []
        for event in events:
            if (type(event) is not dict or set(event) != {"site", "value"}
                    or type(event["site"]) is not str or type(event["value"]) is not str
                    or len(event["value"]) != 16
                    or any(c not in "0123456789abcdef" for c in event["value"])):
                raise ValueError("host clock row")
            value = struct.unpack(">d", bytes.fromhex(event["value"]))[0]
            if not math.isfinite(value) or kind == "monotonic" and (value < 0 or values and value < values[-1]):
                raise ValueError("host clock value")
            values.append(value)
        clock_values[kind] = values
    process_at = rest_at = driver_call = 0
    clock_at = {"wall": 0, "monotonic": 0}
    clock_ordinals = {"wall": {}, "monotonic": {}}

    def clock(kind, site):
        index = clock_at[kind]
        if index >= len(raw_clocks[kind]) or raw_clocks[kind][index]["site"] != site:
            raise ValueError("host clock order: " + site)
        clock_at[kind] += 1
        clock_ordinals[kind][site] = clock_ordinals[kind].get(site, 0) + 1
        return clock_values[kind][index]

    def mono(site):
        return clock("monotonic", "sandbox/v1/host-supervisor.py:" + site + ":0")

    def wall(site):
        return clock("wall", "sandbox/v1/host-supervisor.py:" + site + ":0")

    class _OuterRunFailure(Exception):
        pass

    def runtime_ended():
        return process_at == len(rows) or rows[process_at]["site"] == "remove_frozen.work.open"

    def take(site):
        nonlocal process_at
        if process_at >= len(rows) or rows[process_at]["site"] != site:
            next_mono = clock_at["monotonic"]
            if (runtime_ended() and site in {
                    "run_driver.close-devnull", "run_vm.close-read", "run_vm.close-log"}
                    and next_mono < len(raw_clocks["monotonic"])
                    and raw_clocks["monotonic"][next_mono]["site"] == "sandbox/v1/host-supervisor.py:1503:0"):
                raise _OuterRunFailure()
            raise ValueError("host process order: " + site)
        row = rows[process_at]
        process_at += 1
        if (row["errno"] is not None and type(row["errno"]) is not int
                or row["timeout"] is not None and type(row["timeout"]) is not bool):
            raise ValueError("host process result")
        return row

    def plain(site, success=0, error=False):
        row = take(site)
        if row["bytes"] is not None or row["timeout"] is not None:
            raise ValueError("host plain result")
        if row["return"] != success or type(row["return"]) is not type(success) or row["errno"] is not None:
            if not error or row["return"] is not None or type(row["errno"]) is not int:
                raise ValueError("host plain result")
        return row

    def polled(site):
        row = take(site)
        if (row["errno"] is not None or row["bytes"] is not None or row["timeout"] is not None
                or row["return"] is not None and type(row["return"]) is not int):
            raise ValueError("host poll")
        return row["return"]

    def waited(site):
        row = take(site)
        if (row["errno"] is not None or row["bytes"] is not None
                or type(row["timeout"]) is not bool
                or row["timeout"] and row["return"] is not None
                or not row["timeout"] and type(row["return"]) is not int):
            raise ValueError("host wait")
        return row["return"], row["timeout"]

    argv_values, rest_values = _runtime_values(runtime_root, start_raw,
        host.canonical({"body": config}), raw_host["driver_rest"])

    def driver(operation, budget=2.0):
        nonlocal driver_call, rest_at
        call = driver_call
        driver_call += 1
        if operation == "argv":
            expected = argv_values
        else:
            if (rest_at >= len(raw_host["driver_rest"])
                    or raw_host["driver_rest"][rest_at]["call"] != call
                    or raw_host["driver_rest"][rest_at]["operation"] != operation):
                raise ValueError("host driver REST order")
            expected = rest_values[rest_at]
            rest_at += 1
        row = plain("run_driver.open", error=True)
        if row["errno"] is not None:
            return None, b""
        row = take("run_driver.spawn")
        if (row["bytes"] is not None or row["timeout"] is not None
                or not (type(row["return"]) is int and row["return"] > 0 and row["errno"] is None
                        or row["return"] is None and type(row["errno"]) is int)):
            raise ValueError("host driver spawn")
        plain("run_driver.close-devnull")
        if row["errno"] is not None:
            return None, b""
        deadline = mono("1636") + budget
        chunks, total, incomplete, overflow = [], 0, False, False
        while True:
            if deadline - mono("1653") <= 0:
                incomplete = True
                break
            row = take("run_driver.select")
            if row["bytes"] is not None:
                raise ValueError("host driver select")
            if row["errno"] is not None:
                if row["return"] is not None or row["timeout"] is not None:
                    raise ValueError("host driver select error")
                incomplete = True
                break
            if type(row["return"]) is not bool or row["timeout"] is not (not row["return"]):
                raise ValueError("host driver select result")
            if not row["return"]:
                incomplete = True
                break
            row = take("run_driver.read")
            if row["errno"] is not None:
                if row["return"] is not None or row["bytes"] is not None or row["timeout"] is not None:
                    raise ValueError("host driver read error")
                incomplete = True
                break
            if (type(row["bytes"]) is not str or len(row["bytes"]) % 2
                    or any(c not in "0123456789abcdef" for c in row["bytes"])
                    or type(row["return"]) is not int or not 0 <= row["return"] <= 65536
                    or len(row["bytes"]) != row["return"] * 2 or row["timeout"] is not None):
                raise ValueError("host driver read")
            chunk = bytes.fromhex(row["bytes"])
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > 65536:
                overflow = True
                break
        plain("run_driver.close", error=True)
        returncode = None

        def kill_group():
            nonlocal returncode
            plain("run_driver.group-kill", error=True)
            value, timed_out = waited("run_driver.group-reap")
            if returncode is not None and (timed_out or value != returncode):
                raise ValueError("host driver returncode changed after poll")
            if not timed_out:
                returncode = value

        if incomplete:
            kill_group()
        else:
            returncode = polled("run_driver.poll")
            if returncode is None:
                max(0.0, deadline - mono("1686"))
                returncode, timed_out = waited("run_driver.wait")
                if timed_out:
                    plain("run_driver.kill", error=True)
                    returncode, timed_out = waited("run_driver.reap")
                    if timed_out:
                        return None, b""
            if overflow:
                kill_group()
        status, out = host._driver_output_values(returncode, chunks, incomplete, overflow)
        if not incomplete and not overflow and status == 0:
            if status != expected[0] or out != expected[1]:
                raise ValueError("fixed driver output mismatch")
        return status, out

    admitted_at = wall("2771")
    if mono("2794") != admission_mono:
        raise ValueError("host admission clock mismatch")

    def startup_status():
        return host._control_deadline_values((mono("1503") - admission_mono) * 1000, start_limit)

    def finish(run):
        if rest_at != len(raw_host["driver_rest"]):
            raise ValueError("unused host driver observations")
        cleanup_rows = rows[process_at:]
        if not cleanup_rows or any(not row["site"].startswith(("remove_only.", "remove_frozen."))
                                   for row in cleanup_rows):
            raise ValueError("host cleanup observations missing or misplaced")
        if clock_at["wall"] != len(raw_clocks["wall"]):
            raise ValueError("unused host wall observations")
        suffix = raw_clocks["monotonic"][clock_at["monotonic"]:]
        required_suffix = ["sandbox/v1/host-supervisor.py:" + site + ":0"
                           for site in ("2882", "2885", "2891", "2895")]
        if [row["site"] for row in suffix] != required_suffix:
            raise ValueError("host finalization clock suffix")
        return run, {"process": process_at, "driver_rest": rest_at, "driver_calls": driver_call,
            "clocks": dict(clock_at), "clock_ordinals": clock_ordinals,
            "admitted_at": admitted_at, "cleanup_rows": cleanup_rows,
            "monotonic_remaining": suffix, "wall_remaining": []}

    def stub():
        status = startup_status()
        return finish(host._stub_run_values(status, wall("2440")))

    def calculate():
        if host._abandonment_values(mono("1516") - admission_mono, sigkill_limit):
            return stub()
        if runtime_ended():
            return stub()
        rc, out = driver("argv")
        parsed = host._driver_argv_result_values(rc, out)
        if parsed is None or parsed[0][0] != config["runtime"]["vfkit"]:
            return stub()
        stopped_exit_status = parsed[1]
        if host._abandonment_values(mono("1516") - admission_mono, sigkill_limit):
            return stub()
        if runtime_ended():
            return stub()
        row = take("run_vm.spawn")
        if row["bytes"] is not None or row["timeout"] is not None:
            raise ValueError("host VM spawn")
        if row["return"] is None:
            return stub()
        if type(row["return"]) is not int or row["return"] <= 0 or row["errno"] is not None:
            raise ValueError("host VM pid")
        row = take("run_vm.drain-start")
        if type(row["return"]) is not bool or row["bytes"] is not None or row["timeout"] is not None:
            raise ValueError("host drain start")
        drain_started = row["return"]
        if drain_started and row["errno"] is not None:
            raise ValueError("host drain start success")
        control_deadline = startup_status()
        spawn_mono = mono("1945")
        state = host._host_state()
        returncode = None
        stop_issued = hard_stop = False

        def kill():
            nonlocal state
            plain("run_vm.kill", error=True)
            state, _ = host._host_step(state, {"kind": "killed"})

        def bounded(operation):
            elapsed = mono("1758") - admission_mono
            if host._abandonment_values(elapsed, sigkill_limit):
                return None, True
            budget = host._driver_budget_remaining_values(elapsed, sigkill_limit)
            if host._driver_budget_before_hardstop_values(elapsed, hardstop_limit):
                budget = host._driver_budget_hardstop_values(budget, elapsed, hardstop_limit)
            budget = host._driver_budget_bound_values(budget)
            status, out = driver(operation, budget)
            if operation == "stop":
                return host._driver_stop_result_values(status), False
            return host._driver_state_result_values(status, out), False

        while True:
            state, action = host._host_step(state, {"kind": "clock", "cancelled": False,
                "elapsed": mono("1974") - admission_mono, "sigkill": sigkill_limit, "hardstop": hardstop_limit})
            if action == "kill":
                kill()
                break
            if state["stop_requested"] and not state["stop_accepted"]:
                accepted, overdue = bounded("stop")
                if overdue:
                    kill()
                    break
                state, _ = host._host_step(state, {"kind": "stop", "accepted": accepted})
                if state["stop_accepted"]:
                    stop_issued, hard_stop = state["stop_issued"], state["hard_stop"]
            since_spawn = mono("2011") - spawn_mono
            value, overdue = bounded("state")
            if overdue:
                kill()
                break
            state, action = host._host_step(state, {"kind": "state", "value": value})
            if action == "confirmed":
                break
            returncode = polled("run_vm.poll")
            primitive = {"kind": "poll", "state": value, "since_spawn": since_spawn,
                "startup": startup_limit, "exit_code": returncode, "stopped_exit_status": stopped_exit_status,
                "rechecked": False}
            state, action = host._host_step(state, primitive)
            if action == "recheck":
                budget = host._recheck_budget_values(sigkill_limit, mono("2045") - admission_mono)
                deadline = mono("2046") + budget
                while returncode is None and mono("2047") < deadline:
                    returncode = polled("run_vm.recheck-poll")
                state, action = host._host_step(state, {**primitive, "exit_code": returncode, "rechecked": True})
            if returncode is not None:
                break
            remaining = poll_interval
            for deadline in (hardstop_limit, sigkill_limit):
                remaining = host._poll_remaining_values(remaining, deadline, mono("2069") - admission_mono)

        reaped = False
        if state["escalated_sigkill"]:
            terminated_at, end_mono = wall("2088"), mono("2089")
        else:
            abandon_mono = admission_mono + sigkill_limit
            if abandon_mono - mono("2101") > 0:
                value, timed_out = waited("run_vm.wait")
                if returncode is not None and (timed_out or value != returncode):
                    raise ValueError("host VM returncode changed after poll")
                if not timed_out:
                    returncode = value
                    reaped = True
                else:
                    plain("run_vm.reap-kill", error=True)
                    if abandon_mono - mono("2111") > 0:
                        returncode, timed_out = waited("run_vm.reap")
                        reaped = not timed_out
            else:
                plain("run_vm.expired-kill", error=True)
            terminated_at, end_mono = wall("2125"), mono("2132")
        if drain_started:
            plain("run_vm.drain-join", True)
            row = take("run_vm.drain-alive")
            if type(row["return"]) is not bool or any(row[k] is not None for k in ("errno", "bytes", "timeout")):
                raise ValueError("host drain alive")
            if row["return"]:
                plain("run_vm.drain-stop-join", True)
            row = take("run_vm.drain-final-alive")
            if type(row["return"]) is not bool or any(row[k] is not None for k in ("errno", "bytes", "timeout")):
                raise ValueError("host drain final alive")
            drain_alive = row["return"]
        else:
            drain_alive = False
        if not drain_alive:
            plain("run_vm.close-read")
            plain("run_vm.close-log")
        state, _ = host._host_step(state, {"kind": "reap", "reaped": reaped,
            "returncode": returncode, "stopped_exit_status": stopped_exit_status})
        guest_capture, validated = None, None
        if state["tree_terminated"]:
            began = mono("2187")
            row = take("run_vm.export-read")
            if row["errno"] is not None:
                if row["return"] is not None or row["bytes"] is not None or row["timeout"] is not None:
                    raise ValueError("host export error")
                records = None
            else:
                if (type(export_raw) is not bytes or row["timeout"] is not None
                        or type(row["return"]) is not int or row["return"] != len(export_raw)
                        or row["bytes"] != {"role": "sandbox-export-capture-bytes",
                            "size_bytes": len(export_raw), "sha256": host.sha256_hex(export_raw)}):
                    raise ValueError("host export bytes")
                if process_at < len(rows) and rows[process_at]["site"] == "run_vm.export-read":
                    # A close failure follows the successful read record before frame parsing.
                    closing = take("run_vm.export-read")
                    if (closing["return"] is not None or type(closing["errno"]) is not int
                            or closing["bytes"] is not None or closing["timeout"] is not None):
                        raise ValueError("host export close error")
                    records = None
                else:
                    try:
                        records = host.frame_read(export_raw)
                        records, guest_capture = host._guest_capture_values(records)
                    except host.FrameError:
                        records = None
            if host._elapsed_deadline_values(mono("2195") - began, export_limit):
                control_deadline = "exceeded"
            validated = host.validate_export(records, plan_sha256)
        run = host._run_result_values(host._export_values(validated), state["tree_terminated"], hard_stop,
            False, state["driver_reported_error"], control_deadline, admission_mono, end_mono,
            terminated_at, stop_issued)
        run, consumed = finish(run)
        consumed["guest_capture"] = guest_capture
        return run, consumed

    try:
        return calculate()
    except _OuterRunFailure:
        return stub()



def _host_cleanup_values(runtime_root, rows, candidate_names):
    import errno
    spec = importlib.util.spec_from_file_location(
        "malicious_host_cleanup_values", Path(runtime_root) / "sandbox/v1/host-supervisor.py")
    host = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(host)
    _seed_require(type(rows) is list and 0 < len(rows) <= 4096
        and type(candidate_names) is list
        and candidate_names == ["%05d" % index for index in range(len(candidate_names))])
    at, ordinals = 0, {}
    class Failure(OSError):
        def __init__(self, error_number):
            self.errno = error_number
            self.missing = host._cleanup_error_values(error_number) == "missing"
    def take(site, operation):
        nonlocal at
        _seed_require(at < len(rows))
        row = rows[at]
        _seed_require(type(row) is dict and set(row) == {"site", "ordinal", "return", "errno", "bytes", "timeout"}
            and row["site"] == site and type(row["ordinal"]) is int
            and row["ordinal"] == ordinals.get(site, 0)
            and row["bytes"] is None and row["timeout"] is None)
        ordinals[site] = row["ordinal"] + 1
        at += 1
        result, error_number = row["return"], row["errno"]
        _seed_require(error_number is None or type(error_number) is int)
        if result is None:
            raise Failure(error_number)
        _seed_require(error_number is None)
        if operation == "open":
            _seed_require(type(result) is int and result >= 0)
        elif operation == "listdir":
            return host._cleanup_names_values(result)
        else:_seed_require(type(result) is int and result == 0)
        return result
    def opened(level):return take("remove_frozen." + level + ".open", "open")
    def closed(level):return take("remove_frozen." + level + ".close", "close")
    def removed(level):return take("remove_frozen." + level + ".rmdir", "rmdir")
    def remove_only(level, names):
        for _name in names:
            try:take("remove_only." + level + ".unlink", "unlink")
            except Failure as error:
                if not error.missing:raise
        return take("remove_only." + level + ".listdir", "listdir")
    def calculate():
        work = None
        try:
            work = opened("work")
            try:attempt = opened("attempt")
            except Failure as error:
                if error.missing:return True
                raise
            try:
                try:frozen = opened("frozen")
                except Failure as error:
                    if not error.missing:raise
                    frozen = None
                if frozen is not None:
                    try:
                        try:candidate = opened("candidate")
                        except Failure as error:
                            if not error.missing:raise
                            candidate = None
                        if candidate is not None:
                            try:
                                if not remove_only("candidate", candidate_names):return False
                            finally:closed("candidate")
                            removed("candidate")
                        if not remove_only("frozen", host.FROZEN_FIXED_NAMES):return False
                    finally:closed("frozen")
                    removed("frozen")
                if not remove_only("attempt", host.LAUNCH_FIXED_NAMES):return False
                if not take("remove_frozen.attempt.listdir", "listdir"):return False
            finally:closed("attempt")
            removed("attempt")
            try:take("remove_frozen.attempt.stat", "stat")
            except Failure:return host._cleanup_stat_values(None)
            return host._cleanup_stat_values(0)
        except Failure:return False
        finally:
            if work is not None:closed("work")
    result = calculate()
    _seed_require(at == len(rows))
    return result


def _host_finalization_values(runtime_root, run, consumed):
    import math
    spec = importlib.util.spec_from_file_location(
        "malicious_host_finalization_values", Path(runtime_root) / "sandbox/v1/host-supervisor.py")
    host = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(host)
    *_other_limits, storage_limit, payload_limit = host._host_deadline_defaults_values()
    _seed_require(type(run) is dict and type(consumed) is dict)
    rows = consumed["monotonic_remaining"]
    sites = ("2882", "2885", "2891", "2895")
    _seed_require(type(rows) is list and len(rows) == len(sites)
        and not consumed["wall_remaining"])
    values = []
    for row, site in zip(rows, sites):
        _seed_require(type(row) is dict and set(row) == {"site", "value"}
            and row["site"] == "sandbox/v1/host-supervisor.py:" + site + ":0"
            and type(row["value"]) is str and len(row["value"]) == 16
            and all(char in "0123456789abcdef" for char in row["value"]))
        value = struct.unpack(">d", bytes.fromhex(row["value"]))[0]
        _seed_require(math.isfinite(value) and value >= 0 and (not values or value >= values[-1]))
        values.append(value)
    result = dict(run)
    if host._elapsed_deadline_values(values[1] - values[0], storage_limit):
        result["control_deadline"] = "exceeded"
    if host._elapsed_deadline_values(values[3] - values[2], payload_limit):
        result["control_deadline"] = "exceeded"
    return result


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
    first_cancelled = isinstance(first, KeyboardInterrupt) or getattr(first, "_scope_signal_cancel", False)
    later_cancelled = isinstance(later, KeyboardInterrupt) or getattr(later, "_scope_signal_cancel", False)
    return later if first is None or later_cancelled and not first_cancelled else first


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


def _git_input_path(path):
    _seed_require(type(path) is str and 0 < len(path.encode("utf-8")) <= 4096
        and "\\" not in path and "\0" not in path
        and all(part not in {"", ".", ".."} for part in path.split("/")))
    _seed_require(path in {"HEAD", "config", "packed-refs"}
        or path.startswith("refs/heads/") or path.startswith("refs/tags/")
        or path.startswith("objects/") and not path.startswith("objects/info/"))
    return path


_SURFACE_INPUTS = ("surface/planted-text.bin", "surface/unread-forge.bin")


_TRIAL_DOCUMENTS = frozenset({"reproduction/claim.json", "reproduction/duty-evaluation.json",
    "reproduction/materialization-input.json", "reproduction/qualified-identity.json",
    "write/request-input/materialization-input.json", "write/request-input/incident.json",
    "write/request-input/qualified-identity.json", "write/claim.json", "write/duty-evaluation.json", "gate/basis.json", "gate/claim.json",
    "gate/shadow-set.json", "gate/dashboard.json", "gate/marker.json"})


def _gate_input_member_values(role, member, kind, size):
    import re
    pieces = member.split("/")
    _seed_require(pieces[0] in {"generator", "scope_reader"})
    if role == "local-runtime":
        _seed_require(len(pieces) == 2 and kind == "runtime" and re.fullmatch(
            r"runtime-[0-9]{4}-(python|jq|bash|git|sudo)-0000\.bin", pieces[1]) is not None)
        return
    _seed_require(role == "capture" and kind == "M")
    installed = {"accepted_set", "control_decision", "control_policy", "control_policy_set",
        "evaluator_driver", "evaluator_program", "registry"}
    anchor = {"host", "verifier", "supervisor"} | {"installed-" + name for name in installed}
    if len(pieces) == 3 and pieces[1] == "anchor":
        _seed_require(pieces[2] in anchor and size <= (1 << 20 if pieces[2] == "host" else 16 << 20));return
    if len(pieces) == 3 and re.fullmatch(r"source-000[0-2]", pieces[1]):
        _seed_require(pieces[2] == "consumer-observations.json" and size <= 1 << 20);return
    if len(pieces) == 3 and re.fullmatch(r"source-configuration-000[0-2]", pieces[1]):
        _seed_require(pieces[2] in {"host", "config", "accepted", "package", "supervisor", "normalizer"}
            and size <= (16 << 20 if pieces[2] in {"supervisor", "normalizer"} else 1 << 20));return
    history = {"accepted-identities.json", "claim.json", "consumer-provenance.json", "decision.json",
        "duty-evaluation.json", "evaluator-driver.txt", "evaluator-program.txt", "evidence-manifest.json",
        "file-digest-result.json", "incident.json", "materialization-input.json", "materialization-response.json",
        "origin-observation.json", "payload-stderr.txt", "payload-stdout.txt", "policy-set.json", "policy.json",
        "preparation-manifest.json", "preparation-record.json", "qualified-identity.json", "registry.json",
        "sandbox-check.json", "sandbox-evaluation.json", "sandbox-expectation.json", "sandbox-receipt.json",
        "sandbox-request.json", "shadow-record.json", "trace-ledger.json", "trace-receipt.json", "bundle.json",
        "publisher-body.txt", "scope-policy.json"}
    candidate = {"candidate-" + name for name in history - {"publisher-body.txt"}}
    candidate |= {"candidate-README.md", "candidate-eval-seed.json"}
    _seed_require(len(pieces) == 4 and pieces[1] == "history" and re.fullmatch(r"[0-9]{4}", pieces[2])
        and int(pieces[2]) < 4096 and pieces[3] in history | candidate)
    name = pieces[3]
    maximum = ((8 << 20 if name == "candidate-materialization-input.json" else 2 << 20)
        if name in candidate else (8 << 20 if name == "materialization-input.json" else
            2 << 20 if name == "preparation-manifest.json" else 1 << 20))
    _seed_require(size <= maximum)


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
        _seed_require(type(row) is dict and set(row) == {"occurrence", "role", "member", "file", "size_bytes", "sha256", "kind"}
            and row["file"] == name and type(row["size_bytes"]) is int
            and row["size_bytes"] == fact["size_bytes"] and row["sha256"] == fact["sha256"]
            and row["kind"] == fact["kind"] and type(source) is tuple and len(source) == 6 and type(source[3]) is int
            and source == (row["occurrence"], row["role"], row["member"], row["size_bytes"], row["sha256"], row["kind"]))
        occurrence, role, member = source[:3]
        _seed_require(type(member) is str and 0 < len(member) <= 4096 and "\0" not in member)
        if role == "original-input":
            _seed_require(occurrence == "case")
            if member.startswith("git/"):
                _git_input_path(member[4:])
                _seed_require(name.startswith("original-git-") and name.endswith(".bin")
                    and fact["kind"] == "raw" and fact["size_bytes"] <= 64 << 20)
            elif member in _SURFACE_INPUTS:
                _seed_require(name == "original-" + member.replace("/", "-")
                    and fact["kind"] == "raw" and fact["size_bytes"] <= 1 << 20)
            elif member in _TRIAL_DOCUMENTS:
                _seed_require(name.startswith("original-document-") and name.endswith(".json")
                    and fact["kind"] == "M" and fact["size_bytes"] <= (
                        8 << 20 if member.endswith("/materialization-input.json") else 1 << 20))
            else:_seed_require(name == member and name in names)
        elif role == "raw-observations":_seed_require(occurrence == "case" and name == member == "raw-observations.json")
        elif role == "preparation":_seed_require(occurrence in {"reproduction.prepare", "reproduction.inspect", "write.prepare", "write.inspect"} and occurrence in occurrences)
        else:_seed_require(role in {"recorded", "capture", "local-runtime", "parent-input"}
            and occurrence in {"reproduction", "write", "kill", "coverage", "gate"} and occurrence in occurrences
            and (occurrence != "gate" or role in {"recorded", "capture", "local-runtime"}))
        if occurrence == "gate" and role != "recorded":
            _gate_input_member_values(role, member, fact["kind"], fact["size_bytes"])
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
        self.original_values = {}
        self.derived_outputs, self.output_relations, self.recorded_sources = {}, [], {}
        self.recorded_raw, self.output_positions, self.recorded_aliases = {}, {}, []
        self.output_forms, self.output_write_sets, self.candidate_sources = {}, {}, {}
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
            bindings = self.window.setdefault("C2_case_bindings", {})
            _seed_require(case_id not in bindings and len(bindings) < 4)
            bindings[case_id] = (self.case_work, self.case_sources)
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

    def _copy(self, anchor, held, name, expected, kind, *, source_mode=None):
        try:
            owner = _seed_module(anchor, ("Anchor",))
            _seed_require(id(held) not in self.source_occurrences)
            result = self._copy_file(owner, anchor, held, name, expected, kind, source_mode=source_mode)
            self.source_occurrences.add(id(held))
            return result
        except BaseException as error:
            self._failed(error, "seed-copy-final")
            raise self.failure

    def _copy_file(self, owner, anchor, held, name, expected, kind, *, source_mode=None, git_input=False, trial_document=False):
        c = self.c
        _seed_require(self.failure is None and not self.closed and name not in self.files
                      and ("/" not in name or kind == "export" and name in {"exports/reproduction.bin", "exports/write.bin"})
                      and c._sha(expected) and len(self.files) < 256)
        source_mode = (0o440 if kind == "recorded" else 0o400) if source_mode is None else source_mode
        self._root_check()
        self._source_check(owner, held, anchor, source_mode)
        size = held.before.st_size
        _seed_require(type(git_input) is bool and (not git_input or kind == "raw"
            and name.startswith("original-git-") and name.endswith(".bin")))
        _seed_require(type(trial_document) is bool and (not trial_document or kind == "M"
            and name.startswith("original-document-") and name.endswith(".json")))
        if trial_document:
            declaration = self.semantic_expected[name]
            _seed_require(declaration[:2] == ("case", "original-input") and declaration[2] in _TRIAL_DOCUMENTS)
        _seed_require(0 <= size <= (4 << 30 if kind == "runtime" else c.EXPORT_LIMIT if kind == "export" else
            64 * c.DOCUMENT_LIMIT if kind == "recorded" or git_input else
            8 * c.DOCUMENT_LIMIT if trial_document and declaration[2].endswith("/materialization-input.json") else c.DOCUMENT_LIMIT))
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
            configuration_copy = (phase in {"kill", "coverage"}
                and type(copied) is getattr(owner, "_HeldSourceConfigurationCopy", None))
            retained_runtime = (self._gate_closed_coverage_runtime(copied, native)
                if phase == "coverage" and copied.closed else None)
            _seed_require((type(copied) is owner._HeldCaptureCopy or configuration_copy)
                and copied.anchor is native.anchor
                and (retained_runtime is not None or not copied.closed and bool(copied.owned) and copied.directory is not None))
            self._include_case(copied)
            if retained_runtime is None:copied.recheck()
            _seed_require(not owner._capture_work_incomplete(copied.leaf) and not copied.leaf.get("metadata_failure"))
            if copied is capture_P:
                semantic_role = "capture"
                expected_names = set(native.capture.snapshots) | {"origin-observation.json", "consumer-observations.json"}
                if "sandbox-export.bin" in native.capture.snapshots:expected_names.add("launch-binding.json")
                _seed_require(set(copied.members) == expected_names)
                expected_bytes = native.capture.snapshots | {"origin-observation.json": native.capture_origin}
            elif configuration_copy:
                cfg = native.configuration
                _seed_require(copied.source_configuration is cfg
                    and copied.source_configuration_source is native
                    and copied.source_configuration_request_raw == native.capture.request_raw
                    and copied.source_configuration_operation == cfg.operation
                    and not cfg.source_inputs_unusable)
                configuration_members = copied.source_configuration_members
                _seed_require(set(configuration_members) == {"host", "config", "accepted", "package", "supervisor", "normalizer"}
                    and len({row["member"] for row in configuration_members.values()}) == 6
                    and set(copied.members) == {row["member"] for row in configuration_members.values()}
                    and not copied.runtime_sha256)
                expected_bytes = {row["member"]: cfg.source_inputs[key][0]
                    for key, row in configuration_members.items()}
                for key, row in configuration_members.items():
                    original = cfg.source_inputs[key][1]
                    original.recheck("E_STORE", self.work, "M")
                    _seed_require(owner._identity(copied.members[row["member"]].before) == owner._identity(row["stat"])
                        and (copied.members[row["member"]].before.st_dev, copied.members[row["member"]].before.st_ino)
                            != (original.before.st_dev, original.before.st_ino)
                        and row["sha256"] == self._digest(expected_bytes[row["member"]], "M"))
                semantic_role = "capture"
            elif set(copied.members) == {"parent-frame.bin", "helper-build-record.json", "native-dependency-record.json"}:
                semantic_role = "parent-input"
                row = native.anchor.private_observations["parent_inputs"]
                _seed_require(row["attempt_id"] == self.c._json(self.bindings[phase]["caller_raw"], self.c.DOCUMENT_LIMIT, "E_STORE")["id"] and row["request_sha256"] == owner.digest(self.bindings[phase]["caller_raw"]))
                expected_bytes = {}
                expected_rows = {row["file"]: row for row in row["files"]}
            elif retained_runtime is None and copied.directory.components[-1].name in {"preparation-runtime-prepare", "preparation-runtime-inspect"}:
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
                source_anchor = native.anchor
                if retained_runtime is not None:
                    _seed_require(name == retained_runtime["invoice"]["file"] and held is retained_runtime["source"])
                    held = retained_runtime.get("recorded_target", retained_runtime["target"])
                    source_anchor = self.anchor
                if name in copied.runtime_sha256:
                    expected, kind = copied.runtime_sha256[name], "runtime"
                elif name == "sandbox-export.bin":
                    value = native.capture.snapshots[name]
                    _seed_require(type(value) is owner._ExportSnapshot)
                    expected, kind = value.acquisition_sha, "export"
                elif name in expected_bytes:
                    value = expected_bytes[name]
                    _seed_require(type(value) is bytes)
                    expected, kind = owner.digest(value), "M" if configuration_copy else "W" if name == "complete.json" else "raw"
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
                directory_name = (Path(retained_runtime["directory"]).name if retained_runtime is not None
                    else copied.directory.components[-1].name)
                member = ("configuration/" + next(key for key, row in configuration_members.items()
                    if row["member"] == name)) if configuration_copy else directory_name + "/" + name
                installed = self._semantic_copy(source_anchor, held, output, expected, kind,
                    phase, semantic_role, member)
                facts.append((name, expected, installed.before.st_size))
            if retained_runtime is None:copied.recheck()
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
                  "work": anchor.config["work_root"], "source_root": owner._source_root(),
                  "consumer_work": os.path.dirname(carriers[0].directory.path)}
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
            elif reader is self.generator.reader:
                generator_module = self._gate_type(self.generator, "scope/v1/generate-gate-evidence.py", "_Generator")
                session, native = reader.store_session, self.bindings[phase]["native"]
                _seed_require(type(session) is generator_module._GateStoreSession and session is self.gate_session
                    and session.reader is reader and session.generator is self.generator
                    and self.generator.session is session and reader.commands_open
                    and session.phase == "FINAL_OWNER" and session.owner_confirmed
                    and type(native) is owner._HeldCoverageRead and session.coverage_source is native
                    and native.anchor is anchor and native.held
                    and type(native.configuration) is owner._CoverageConfiguration
                    and session.coverage_configuration is native.configuration
                    and type(native.capture) is owner._HeldCaptureRead and native.capture.native is native
                    and native.capture.anchor is anchor and native.capture.held
                    and capture_P.scope_source is native
                    and any(item is native for item in reader.owned)
                    and any(item is capture_P for item in reader.source_copies))
                context = session.p_handoff
                _seed_require(type(context) is owner._C1PHandoffParent and context.session is session
                    and context.anchor is anchor and context.root is self.root and context.work is self.work
                    and context.case_work is self.case_work and context.window_work is self.window
                    and not context.unusable and native.configuration.operation == "coverage-read"
                    and type(session.coverage_request_raw) is bytes)
                context._equal_M(session.coverage_request_raw, native.capture.request_raw)
                context._equal_M(native.snapshots["payload/request.json"], native.capture.request_raw)
                _seed_require(document["attempt_id"] == native.attempt_id
                    and document["request_sha256"] == self._digest(native.capture.request_raw, "M"))
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
        runtime_names = set()
        for copied in carriers:
            if copied is capture_P:continue
            if copied.directory is None:
                _seed_require(phase == "coverage")
                self._gate_closed_coverage_runtime(copied, self.bindings[phase]["native"])
            elif copied.directory.components[-1].name.startswith("preparation-runtime-"):continue
            runtime_names.update(copied.runtime_sha256)
        _seed_require(rows and {row["file"] for row in rows} == runtime_names)
        if phase in {"kill", "coverage"}:
            complete = [{key: row[key] for key in ("slot", "index", "ordinal", "locator", "file", "size_bytes", "sha256", "errno")}
                for row in source_rows]
            owner._source_local_runtime_values({"files": rows}, {"files": complete})
        else:owner._runtime_inventory_values({"files": rows})
        storage = list(document["storage"])
        if phase in {"reproduction", "write"}:
            caller_value = owner._json(caller, owner.DOCUMENT_LIMIT, "E_STORE")
            storage.extend(owner._sudo_storage_projection_values(document["storage_reads"], caller_value["id"]))
        value = {"clocks": document["clocks"],
            "storage": {"entries": storage, "identity_context": document["identity_context"]},
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
                self.semantic_expected[name] = ("case", "original-input", name, len(item.raw), expected, "M")
                self._copy_file(owner, self.anchor, item.held, name, expected, "M",
                    source_mode=stat.S_IMODE(item.held.before.st_mode))
                self.source_occurrences.add(id(item.held))
                self.original_bindings[name] = {"kind": kind, "id": value["id"],
                    "size_bytes": len(item.raw), "sha256": expected}
                self._semantic_record("case", "original-input", name, name)
            self.incident = {"observed_at": values[0]["body"]["observed_at"]}
            self.original_raw = tuple(item.raw for item in items)
            self.original_values = dict(zip(names, values))
            self.identifiers = {role: values[index]["id"] for role, index in (("reproduction", 1), ("write", 2), ("gate", 3))}
            self._transfer()
        except BaseException as error:
            self._failed(error, "seed-original-inputs")
            raise self.failure

    def original_git_inputs(self, anchor, entries):
        try:
            owner = _seed_module(anchor, ("Anchor",))
            _seed_require(self.incident is not None and not self.closed and type(entries) is tuple
                and entries and len(self.files) + len(entries) <= 256
                and not any(row["role"] == "original-input" and row["member"].startswith("git/")
                    for row in self.semantic.values()))
            paths, total = set(), 0
            for index, entry in enumerate(entries):
                _seed_require(type(entry) is dict and set(entry) == {"path", "sha256", "held"})
                path = _git_input_path(entry["path"])
                held, expected = entry["held"], entry["sha256"]
                _seed_require(path not in paths and type(held) is owner.HeldPath
                    and owner._sha(expected) and id(held) not in self.source_occurrences)
                paths.add(path);total += held.before.st_size
                _seed_require(0 <= held.before.st_size <= 64 << 20 and total <= 256 << 20)
                name, member = "original-git-%03d.bin" % index, "git/" + path
                self.semantic_expected[name] = ("case", "original-input", member, held.before.st_size, expected, "raw")
                self._copy_file(owner, anchor, held, name, expected, "raw", source_mode=0o400, git_input=True)
                self.source_occurrences.add(id(held))
                self._semantic_record("case", "original-input", member, name)
            _seed_require({"HEAD", "config"} <= paths and any(path.startswith("objects/") for path in paths))
            self._transfer()
        except BaseException as error:
            self._failed(error, "seed-original-git-inputs")
            raise self.failure

    def surface_inputs(self, anchor, planted_text, unread_forge):
        try:
            owner = _seed_module(anchor, ("Anchor",))
            _seed_require(self.incident is not None and self.failure is None and not self.closed
                and not any(row["member"] in _SURFACE_INPUTS for row in self.semantic.values()))
            for member, item in zip(_SURFACE_INPUTS, (planted_text, unread_forge)):
                _seed_require(type(item) is owner._HeldBytes and type(item.raw) is bytes
                    and len(item.raw) <= owner.DOCUMENT_LIMIT and type(item.held) is owner.HeldPath)
                if member == _SURFACE_INPUTS[0]:_seed_require(item.raw)
                item.recheck("E_STORE")
                expected, name = self._digest(item.raw, "raw"), "original-" + member.replace("/", "-")
                self.semantic_expected[name] = ("case", "original-input", member, len(item.raw), expected, "raw")
                self._copy(anchor, item.held, name, expected, "raw", source_mode=0o400)
                self._semantic_record("case", "original-input", member, name)
                item.recheck("E_STORE")
            self._transfer()
        except BaseException as error:
            self._failed(error, "seed-surface-inputs")
            raise self.failure

    def trial_documents(self, anchor, entries):
        try:
            owner = _seed_module(anchor, ("Anchor",))
            _seed_require(self.incident is not None and type(entries) is tuple and entries
                and len(self.files) + len(entries) <= 256)
            existing = {row["member"] for row in self.semantic.values() if row["role"] == "original-input"}
            for entry in entries:
                _seed_require(type(entry) is dict and set(entry) == {"member", "source"}
                    and entry["member"] in _TRIAL_DOCUMENTS and entry["member"] not in existing)
                item, member = entry["source"], entry["member"]
                snapshot = False
                if type(item) is not owner._HeldBytes:
                    name = type(item).__name__
                    _seed_require(name in {"InputSnapshot", "StableFile"})
                    producer = self._gate_type(item, "shadow/v1/enforced-reproduction.py", name)
                    _seed_require(producer.c is owner and (name != "StableFile" or item.recording_work is None))
                    snapshot = name == "InputSnapshot"
                _seed_require(type(item.held) is owner.HeldPath and type(item.raw) is bytes and bool(item.held.components))
                phase, document_name = member.split("/", 1)
                if phase in {"reproduction", "write"}:
                    key = document_name.removeprefix("request-input/")[:-5].replace("-", "_")
                    original = self.original_values[phase + "-request.json"]["body"]
                    _seed_require(type(original.get(key)) is str and original[key] == item.held.path)
                if snapshot:item.recheck()
                else:item.recheck("E_STORE")
                self._charge("R", len(item.raw), "M")
                expected = owner.digest(item.raw)
                self._charge("H", len(item.raw), "M")
                original = expected if snapshot else item.sha256
                if not snapshot:self._charge("H", len(item.raw), "M")
                _seed_require(expected == original and len(item.raw) <= (
                    8 * owner.DOCUMENT_LIMIT if member.endswith("/materialization-input.json") else owner.DOCUMENT_LIMIT)
                    and id(item.held) not in self.source_occurrences)
                name = "original-document-%03d.json" % len(existing)
                self.semantic_expected[name] = ("case", "original-input", member, len(item.raw), expected, "M")
                self._copy_file(owner, anchor, item.held, name, expected, "M", source_mode=0o400, trial_document=True)
                self.source_occurrences.add(id(item.held))
                self._semantic_record("case", "original-input", member, name)
                existing.add(member)
            self._transfer()
        except BaseException as error:
            self._failed(error, "seed-trial-documents")
            raise self.failure

    def _semantic_record(self, occurrence, role, member, name):
        _seed_require(name in self.files and name not in self.semantic
            and self.semantic_expected[name] == (occurrence, role, member,
                self.files[name]["size_bytes"], self.files[name]["sha256"], self.files[name]["kind"]))
        row = {"occurrence": occurrence, "role": role, "member": member,
            "file": name, "size_bytes": self.files[name]["size_bytes"], "sha256": self.files[name]["sha256"], "kind": self.files[name]["kind"]}
        self.c._capture_observe(self.work, "M", "seed-semantic-member", row)
        self.semantic[name] = row

    def _semantic_copy(self, anchor, held, name, expected, kind, occurrence, role, member, *, source_mode=None, recorded_output=False):
        try:
            _seed_require(name not in self.semantic_expected)
            self.semantic_expected[name] = (occurrence, role, member, held.before.st_size, expected, kind)
            if recorded_output:
                _seed_require(kind == role == "recorded" and occurrence in {"reproduction", "write"}
                    and member.startswith(("bundle/", "candidate/")))
                semantic = (occurrence, role, member)
                _seed_require(semantic not in self.recorded_sources and
                    (id(held) not in self.source_occurrences or any(previous[0] is anchor and previous[1] is held
                        for previous in self.recorded_aliases)))
                self.recorded_sources[semantic] = (anchor, held)
                owner = _seed_module(anchor, ("Anchor",))
                result = self._copy_file(owner, anchor, held, name, expected, kind, source_mode=source_mode)
                self.source_occurrences.add(id(held))
                self.recorded_aliases.append((anchor, held))
            else:result = self._copy(anchor, held, name, expected, kind, source_mode=source_mode)
            self._semantic_record(occurrence, role, member, name)
            self._transfer()
            return result
        except BaseException as error:
            self._failed(error, "seed-semantic-copy")
            raise self.failure

    def bundle_outputs(self, phase, reader):
        try:return self._bundle_outputs(phase, reader)
        except BaseException as error:
            self._failed(error, "seed-bundle-outputs")
            raise self.failure

    def _bundle_outputs(self, phase, reader):
        _seed_require(phase in {"reproduction", "write"} and phase in self.bindings
            and self.failure is None and not self.closed)
        module = self._gate_type(reader, "scope/v1/read-shadow-evidence.py", "_Reader")
        _seed_require(reader.commands_open and reader.anchor is not None
            and not getattr(reader, "replay_output_unusable", True)
            and type(reader.replay_outputs) is dict and set(reader.replay_outputs) == {"bundles", "git", "stores", "anchor", "holds"})
        if reader is getattr(getattr(self, "generator", None), "reader", None):context = "generator"
        else:
            _seed_require(reader is getattr(self, "scope_reader", None))
            context = "scope_reader"
        original = self.bindings[phase]
        matching = []
        observations = reader.replay_outputs["bundles"]
        position = self.output_positions.get((phase, reader), 0)
        _seed_require(position < len(observations))
        for raw, (held, role, environment) in observations[position:]:
            _seed_require(type(held) is module.c._HeldBundle and any(held is item for item in reader.owned)
                and held.files["shadow-record.json"] == raw and role in {"current", "qualifying"}
                and module.c._id(environment))
            if held.files["incident.json"] == self.original_raw[0] and held.files["sandbox-request.json"] == original["request_raw"]:
                matching.append((held, role, environment))
        _seed_require(matching)
        reader.anchor.recheck("E_STORE")
        indexed = self.derived_outputs.setdefault(phase, {})
        for bundle, role, environment in matching:
            self._bundle_namespace(bundle)
            files = bundle.files
            names, binding = self._bundle_output_values(phase, context, role, environment, files)
            prefix = "bundle/" + context + "/" + role + "/" + environment + "/"
            for name in sorted(names):
                leaves = [item for item in bundle.held if item.components and item.path == bundle.held[0].path + "/" + name]
                _seed_require(len(leaves) == 1)
                source, raw = leaves[0], files[name]
                expected = self._digest(raw, "recorded")
                member = prefix + name
                if member in indexed:
                    self._verify_recorded_observation(reader.anchor, source, indexed[member],
                        (phase, "recorded", member), raw, expected)
                else:
                    target_name = phase + "-bundle-%03d-" % len(indexed) + name
                    self._semantic_copy(reader.anchor, source, target_name, expected, "recorded",
                        phase, "recorded", member, source_mode=0o400, recorded_output=True)
                    self.recorded_raw[(phase, "recorded", member)] = raw
                    indexed[member] = target_name
            self.output_relations.append((phase, reader, context, role, environment, bundle))
            self._bundle_namespace(bundle)
        reader.anchor.recheck("E_STORE")
        self.output_positions[(phase, reader)] = len(observations)
        self._transfer()

    def _nested_reproduction_outputs(self, reader):
        module = self._gate_type(reader, "scope/v1/read-shadow-evidence.py", "_Reader")
        generator_module = self._gate_type(self.generator, "scope/v1/generate-gate-evidence.py", "_Generator")
        _seed_require(self.generator is self._gate_owner and self.generator.reader is reader
            and self.generator.active and type(reader.store_session) is generator_module._GateStoreSession
            and reader.store_session is self.gate_session and reader.commands_open
            and not reader.replay_output_unusable and not self.closed and self.failure is None)
        matches = []
        for outer_raw, outer in reader.replay_outputs["stores"]:
            store, files, retained, storage_rows = outer
            association = getattr(store, "scope_reproduction_acquisition", None)
            if association is None:continue
            actual_reader, original_store, original_files, original_paths, original_rows, git_output, saved = association
            _seed_require(actual_reader is reader and original_store is store and original_files is files
                and original_paths is retained and original_rows is storage_rows
                and store.storage_rows is storage_rows and store.anchor is reader.anchor
                and type(store) is module.c._HeldStoreRead and any(item is store for item in reader.owned)
                and outer_raw is files["shadow-record.json"])
            frozen_files, write_rows, git, git_files = git_output
            caller_files, bundle_owner, nested, saved_frozen, saved_rows, saved_git = saved
            bundle, role, environment = bundle_owner
            _seed_require(caller_files is files and saved_frozen is frozen_files and saved_rows is write_rows
                and saved_git is git is reader.git and git.ledger is reader and git_files is files
                and type(bundle) is module.c._HeldBundle and bundle.files is files
                and any(item is bundle for item in reader.owned)
                and any(value is saved for value in reader.replay_nested_reproductions)
                and any(value is git_output and key is outer_raw for key, value in reader.replay_outputs["git"])
                and any(value is nested for value in reader.replay_outputs["stores"]))
            nested_raw, nested_acquisition = nested
            nested_store, nested_files, nested_paths, nested_rows = nested_acquisition
            _seed_require(type(nested_store) is module.c._HeldStoreRead and nested_store.anchor is reader.anchor
                and nested_store.storage_rows is nested_rows and any(item is nested_store for item in reader.owned)
                and nested_raw is nested_files["shadow-record.json"] and set(nested_files) == set(nested_paths))
            original = self.bindings["reproduction"]
            _seed_require(files["incident.json"] == nested_files["incident.json"] == self.original_raw[0]
                and files["sandbox-request.json"] == self.bindings["write"]["request_raw"]
                and nested_files["sandbox-request.json"] == original["request_raw"])
            record = self._wrapper_parse(nested_raw, "nested-output-record")
            outer_record = self._wrapper_parse(outer_raw, "nested-output-caller")
            _seed_require(role in {"current", "qualifying"}
                and environment == record["body"]["environment"]["environment_id"]
                == outer_record["body"]["environment"]["environment_id"]
                and record["body"]["record_form"] == "enforced-reproduction.v1")
            acquisitions = [item for item in reader.anchor.private_observations["storage_reads"]
                if item["entries"] and all(row["role"] == "store" for row in item["entries"])]
            ordinals = [index for index, item in enumerate(acquisitions) if item["entries"] is nested_rows]
            _seed_require(len(ordinals) == 1 and any(item["entries"] is storage_rows for item in acquisitions))
            _seed_require(store.held and nested_store.held and bundle.held)
            matches.append((association, nested_files, nested_paths, role, environment, ordinals[0]))
        _seed_require(matches)
        indexed = self.derived_outputs.setdefault("reproduction", {})
        for association, files, retained, role, environment, ordinal in matches:
            names, _binding = self._bundle_output_values("reproduction", "generator", role, environment, files)
            prefix = "bundle/generator/" + role + "/" + environment + "/"
            for name in sorted(names):
                holders = [item for item in reader.owned if type(item) is module.c._HeldBytes
                    and item.held.path == str(retained[name])]
                _seed_require(len(holders) == 1 and any(path is retained[name] and raw is files[name]
                    for path, raw in reader.inputs))
                source, raw = holders[0].held, files[name]
                self._charge("E", len(holders[0].raw) + len(raw), "recorded")
                _seed_require(holders[0].raw == raw and source.components)
                expected = self._digest(raw, "recorded")
                member = prefix + name
                if member in indexed:
                    self._verify_recorded_observation(reader.anchor, source, indexed[member],
                        ("reproduction", "recorded", member), raw, expected)
                else:
                    self._scope_recorded_alias(reader, source, "generator/history/%04d/" % ordinal + name, expected)
                    destination = "reproduction-nested-%03d-" % len(indexed) + name
                    self._semantic_copy(reader.anchor, source, destination, expected, "recorded",
                        "reproduction", "recorded", member, source_mode=0o400, recorded_output=True)
                    self.recorded_raw[("reproduction", "recorded", member)] = raw
                    indexed[member] = destination
            self.c._capture_observe(self.work, "M", "seed-nested-reproduction-output", {
                "ordinal": ordinal, "role": role, "environment_id": environment, "members": len(names)})
            self.output_relations.append(("reproduction", reader, "generator", role, environment,
                (association[1], association)))
            _seed_require(association[1].held and association[6][2][1][0].held)
        self._transfer()

    def _bundle_output_values(self, phase, context, role, environment, files):
        _seed_require(phase in {"reproduction", "write"} and context in {"generator", "scope_reader"}
            and role in {"current", "qualifying"} and self.c._id(environment)
            and files["incident.json"] == self.original_raw[0]
            and files["sandbox-request.json"] == self.bindings[phase]["request_raw"])
        record = self._wrapper_parse(files["shadow-record.json"], "bundle-record")
        form = record["body"]["record_form"]
        _seed_require(form in ({"enforced-reproduction.v1"} if phase == "reproduction"
            else {"withheld-write.v1", "withheld-write-policy.v1"}))
        names, candidate_names = self.c._c1_history_names_values(form)
        _seed_require(set(files) == names)
        identity = (phase, context, role, environment)
        _seed_require(identity not in self.output_forms or self.output_forms[identity] == form)
        self.output_forms[identity] = form
        if phase == "write":
            incident = self._wrapper_parse(files["incident.json"], "output-incident")
            prefix = "ystack-evidence/" + incident["id"] + "/"
            paths = tuple(row["path"] for row in record["body"]["write"]["write_set"])
            _seed_require(paths == tuple(prefix + name[len("candidate-"):] for name in sorted(candidate_names))
                and (identity not in self.output_write_sets or self.output_write_sets[identity] == paths))
            self.output_write_sets[identity] = paths
        return names, identity

    def _remote_scope_outputs(self, context):
        _seed_require(context is self._gate_remote_context and context.session is self.gate_session
            and context.root is self.root and context.output_holds is self.output_holds
            and not context.unusable and self.gate_session.closed
            and "FINAL_OWNER" in context.batches and "CLOSED" in context.settlements
            and ("C_REQUEST" not in context.batches or "C_RELEASED" in context.settlements)
            and set(context.records) == context.closed_serials and context.receipts)
        for ordinal, group in sorted(context.history_groups.items()):
            if not group["current_output"]:continue
            values = group["values"]
            phases = [phase for phase in ("reproduction", "write")
                if values["incident.json"] == self.original_raw[0]
                and values["sandbox-request.json"] == self.bindings[phase]["request_raw"]]
            _seed_require(len(phases) == 1)
            phase = phases[0]
            by_name = {row["name"]: context.records[row["serial"]] for row in group["rows"]}
            _seed_require(set(by_name) == group["bundle_names"] | group["candidate_names"])
            for name, record in by_name.items():
                row, target = record["row"], record["target"]
                _seed_require(row["ordinal"] == ordinal and row["family"] == "history"
                    and target in self.output_holds and target.components
                    and record["semantic"] == ("capture", "scope_reader/history/%04d/" % ordinal + name)
                    and self.c._identity(target.before) == record["initial_identity"])
                target.recheck("E_STORE", self.work, "M")
                observed = self._read(target.fd, row["size_bytes"], 0, "M")
                self._charge("E", len(observed) + len(values[name]), "M")
                _seed_require(len(observed) == row["size_bytes"] and observed == values[name]
                    and self._digest(observed, "M") == row["sha256"])
            bundle = {name: values[name] for name in group["bundle_names"]}
            for role, environment in group["roles"]:
                names, identity = self._bundle_output_values(phase, "scope_reader", role, environment, bundle)
                for name in sorted(names | group["candidate_names"]):
                    candidate = name in group["candidate_names"]
                    original = group["facts"]["prefix"] + name[len("candidate-"):] if candidate else name
                    member = ("candidate/" if candidate else "bundle/") + "scope_reader/" + role + "/" + environment + "/" + original
                    indexed = self.derived_outputs.setdefault("candidate" if candidate else phase, {})
                    record = by_name[name]
                    target, raw, expected = record["target"], values[name], record["row"]["sha256"]
                    if member in indexed:
                        semantic = (phase, "recorded", member)
                        previous_anchor, previous_source = self.recorded_sources[semantic]
                        previous = [saved for saved in context.records.values() if saved["target"] is previous_source]
                        _seed_require(previous_anchor is context.anchor and len(previous) == 1
                            and previous[0]["row"]["name"] == name)
                        previous_group = context.history_groups[previous[0]["row"]["ordinal"]]
                        _seed_require(previous_group["current_output"] and (role, environment) in previous_group["roles"]
                            and previous_group["values"]["incident.json"] == self.original_raw[0]
                            and previous_group["values"]["sandbox-request.json"] == self.bindings[phase]["request_raw"])
                        staged = [held for held in self.output_holds if held.path == self.root.path + "/" + indexed[member]]
                        _seed_require(len(staged) == 1 and self.files[indexed[member]]["sha256"] == expected)
                        context._compare(target, staged[0], record["row"], "M")
                        self._charge("E", len(self.recorded_raw[semantic]) + len(raw), "recorded")
                        _seed_require(self.recorded_raw[semantic] == raw)
                        self.source_occurrences.add(id(target))
                        if not any(anchor is context.anchor and held is target for anchor, held in self.recorded_aliases):
                            self.recorded_aliases.append((context.anchor, target))
                    else:
                        destination = phase + "-remote-%03d.bin" % len(self.files)
                        self._semantic_copy(context.anchor, target, destination, expected, "recorded",
                            phase, "recorded", member, source_mode=0o400, recorded_output=True)
                        self.recorded_raw[(phase, "recorded", member)] = raw
                        indexed[member] = destination
                self.output_relations.append((phase, context, "scope_reader", role, environment, group))
        self._transfer()

    def _verify_recorded_observation(self, anchor, source, name, semantic, raw, expected):
        owner = _seed_module(anchor, ("Anchor",))
        previous_anchor, previous = self.recorded_sources[semantic]
        _seed_require(previous_anchor is anchor and source.path == previous.path
            and len(source.components) == len(previous.components)
            and all(current.name == old.name and owner._identity(current.before) == owner._identity(old.before)
                for current, old in zip(source.components, previous.components)))
        self._source_check(owner, previous, anchor, 0o400)
        self._source_check(owner, source, anchor, 0o400)
        original = self.recorded_raw[semantic]
        self._charge("E", len(original) + len(raw), "recorded")
        _seed_require(original == raw and self.files[name]["size_bytes"] == len(raw)
            and self.files[name]["sha256"] == expected)
        target = next(item for item in self.output_holds if item.path == self.root.path + "/" + name)
        _seed_require(target.before.st_size == len(raw))
        target.recheck("E_STORE", self.work, "M")
        left_hash, right_hash = hashlib.sha256(), hashlib.sha256()
        offset = 0
        while offset < len(raw):
            count = min(65536, len(raw) - offset)
            left = self._read(source.fd, count, offset, "recorded")
            left_hash.update(left);self._charge("H", len(left), "recorded")
            right = self._read(target.fd, count, offset, "recorded")
            right_hash.update(right);self._charge("H", len(right), "recorded")
            self._charge("E", len(left) + len(right), "recorded")
            _seed_require(left == right)
            offset += count
        _seed_require(left_hash.hexdigest() == right_hash.hexdigest() == expected)
        self._source_check(owner, previous, anchor, 0o400)
        self._source_check(owner, source, anchor, 0o400)
        target.recheck("E_STORE", self.work, "M")
        self.source_occurrences.add(id(source))
        if not any(pair[0] is anchor and pair[1] is source for pair in self.recorded_aliases):
            self.recorded_aliases.append((anchor, source))

    def _bundle_namespace(self, bundle):
        directory = bundle.held[0]
        directory.recheck("E_STORE", self.work, "M")
        names = directory.listdir()
        self.c._capture_observe(self.work, "M", "seed-bundle-namespace", {"names": sorted(names)})
        _seed_require(set(names) == set(bundle.files))
        directory.recheck("E_STORE", self.work, "M")

    def candidate_outputs(self, reader):
        try:
            module = self._gate_type(reader, "scope/v1/read-shadow-evidence.py", "_Reader")
            _seed_require(not self.closed and self.failure is None and "write" in self.bindings
                and reader.commands_open and not reader.replay_output_unusable)
            _seed_require(reader.replay_outputs["git"])
            indexed = self.derived_outputs.setdefault("candidate", {})
            for record_raw, (files, rows, git, original_files) in reader.replay_outputs["git"]:
                relations = [relation for relation in self.output_relations
                    if relation[0] == "write" and relation[1] is reader and len(relation) == 6
                    and type(relation[-1]) is module.c._HeldBundle
                    and relation[-1].files is original_files
                    and original_files["shadow-record.json"] == record_raw]
                _seed_require(relations and git is reader.git and type(git) is module.c._ReadOnlyGit
                    and git.ledger is reader and type(files) is dict and type(rows) is list
                    and set(files) == {row["path"] for row in rows} and len(files) == len(rows))
                self.work["candidate_record_parse_attempt_bytes"] = len(record_raw)
                self.work["candidate_record_parse_unknown"] = True
                record = module.parse(record_raw)
                self._wrapper_processed("candidate-record-parse", len(record_raw))
                self.work["candidate_record_parse_unknown"] = False
                actual_rows = self._wrapper_encode(rows)
                declared_rows = self._wrapper_encode(record["body"]["write"]["write_set"])
                self._wrapper_processed("candidate-row-compare", len(actual_rows) + len(declared_rows))
                _seed_require(actual_rows == declared_rows)
                reader.anchor.recheck("E_STORE")
                for held in git.held:held.recheck("E_STORE", self.work, "M")
                for relation in relations:
                    context, role, environment = relation[2:5]
                    prefix = "candidate/" + context + "/" + role + "/" + environment + "/"
                    for row in rows:
                        raw = files[row["path"]]
                        _seed_require(row["mode"] == "100644" and row["add_only"] is True
                            and self._digest(raw, "recorded") == row["sha256"])
                        member = prefix + row["path"]
                        identities = tuple((held.path, tuple((part.name, module.c._identity(part.before))
                            for part in held.components)) for held in git.held)
                        if member in indexed:
                            old_reader, old_git, old_record, old_rows, old_raw, old_identities = self.candidate_sources[member]
                            self._charge("E", len(old_record) + len(record_raw) + len(old_rows)
                                + len(actual_rows) + len(old_raw) + len(raw), "recorded")
                            _seed_require(old_reader is reader and old_git is git and old_identities == identities
                                and old_record == record_raw and old_rows == actual_rows and old_raw == raw)
                            target = next(held for held in self.output_holds
                                if held.path == self.root.path + "/" + indexed[member])
                            target.recheck("E_STORE", self.work, "M")
                            _seed_require(target.before.st_size == len(raw))
                            measured, offset = hashlib.sha256(), 0
                            while offset < len(raw):
                                count = min(65536, len(raw) - offset)
                                observed = self._read(target.fd, count, offset, "recorded")
                                measured.update(observed);self._charge("H", len(observed), "recorded")
                                self._charge("E", len(observed) + count, "recorded")
                                _seed_require(observed == raw[offset:offset + count])
                                offset += count
                            _seed_require(measured.hexdigest() == row["sha256"])
                            target.recheck("E_STORE", self.work, "M")
                        else:
                            name = "write-candidate-%03d" % len(indexed)
                            self._write_value_file(raw, name, "write", "recorded", member,
                                "recorded", 8 * self.c.DOCUMENT_LIMIT)
                            indexed[member] = name
                            self.candidate_sources[member] = (reader, git, record_raw, actual_rows, raw, identities)
                for held in git.held:held.recheck("E_STORE", self.work, "M")
                reader.anchor.recheck("E_STORE")
            self._transfer()
        except BaseException as error:
            self._failed(error, "seed-candidate-outputs")
            raise self.failure

    def _gate_recorded_member(self, reader, held, expected, kind, copied=None, name=None):
        module = self._gate_type(reader, "scope/v1/read-shadow-evidence.py", "_Reader")
        owner = module.c
        generator = self.generator
        path = Path(held.path)
        _seed_require(generator is self._gate_owner and generator.active and reader.commands_open
            and path.is_relative_to(generator.output) and path != generator.output
            and type(held) is owner.HeldPath and held.components and kind in {"runtime", "M"})
        member = "generator/" + path.relative_to(generator.output).as_posix()
        registry = self.__dict__.setdefault("gate_recorded_members", {})
        if copied is not None:
            _seed_require(not copied.closed and copied.anchor is reader.anchor and copied.members.get(name) is held)
            copied.recheck()
            _seed_require(not owner._capture_work_incomplete(copied.leaf)
                and not reader.anchor.private_observations.get("unusable", False))
        if kind == "runtime":
            _seed_require(copied is not None and name in copied.runtime_sha256
                and copied.runtime_sha256[name] == expected)
            declarations = [row for row in reader.anchor.private_observations["local_runtime"]
                if row["file"] == name and row["sha256"] == expected and row["size_bytes"] == held.before.st_size]
            source = getattr(copied, "scope_source", None)
            if source is not None:
                document = owner._json(source.capture.snapshots["capture.json"], owner.DOCUMENT_LIMIT, "E_STORE")
                declarations.extend(row for filename, row in owner._capture_runtime_files(document["body"]["raw"]).items()
                    if filename == name and row["sha256"] == expected and row["size_bytes"] == held.before.st_size)
            _seed_require(len(declarations) == 1)
        self._source_check(owner, held, reader.anchor, 0o400)
        identities = tuple(owner._identity(component.before) for component in held.components)
        if member in registry:
            previous = registry[member]
            _seed_require(previous["reader"] is reader and previous["held"] is held
                and previous["copied"] is copied and previous["expected"] == expected
                and previous["kind"] == kind and previous["identities"][-1] == identities[-1])
            target = previous["target"]
            self._scope_check_P_S(reader, held, target, expected, kind)
            return previous["file"]
        existing = [row for row in self.__dict__.get("_scope_P_stages", [])
            if row["reader"] is reader and row["source"] is held and row["copied"] is copied]
        _seed_require(len(existing) <= 1)
        first = existing[0]["target"] if existing else None
        if first is None and copied is not None:
            prior = self._scope_existing_S(reader, copied, name, "generator")
            if prior is not None:first = prior[2]
        physical = "gate-output-%03d" % len(registry)
        _seed_require(physical not in self.semantic_expected and len(registry) < 256)
        self.semantic_expected[physical] = ("gate", "recorded", member, held.before.st_size, expected, kind)
        if first is None:
            _seed_require(id(held) not in self.source_occurrences)
            target = self._copy(reader.anchor, held, physical, expected, kind, source_mode=0o400)
        else:
            self._scope_check_P_S(reader, held, first, expected, kind)
            target = self._copy(self.anchor, first, physical, expected, kind, source_mode=0o400)
        self._semantic_record("gate", "recorded", member, physical)
        registry[member] = {"reader": reader, "held": held, "copied": copied, "expected": expected,
            "kind": kind, "identities": identities, "file": physical, "target": target}
        self._source_check(owner, held, reader.anchor, 0o400)
        if copied is not None:copied.recheck()
        self._transfer()
        return physical

    def _gate_private_output_members(self, reader):
        module = self._gate_type(reader, "scope/v1/read-shadow-evidence.py", "_Reader")
        for copied in reader.source_copies:
            _seed_require(not copied.closed and copied.anchor is reader.anchor)
            for name, held in sorted(copied.members.items()):
                if not Path(held.path).is_relative_to(self.generator.output):continue
                if name in copied.runtime_sha256:expected, kind = copied.runtime_sha256[name], "runtime"
                else:
                    _seed_require(held.before.st_size <= module.c.DOCUMENT_LIMIT)
                    raw = held.read(module.c.DOCUMENT_LIMIT, "E_STORE", self.work)
                    expected, kind = self._digest(raw, "M"), "M"
                self._gate_recorded_member(reader, held, expected, kind, copied, name)

    def run_gate(self):
        generator = self.generator
        module = self._gate_type(generator, "scope/v1/generate-gate-evidence.py", "_Generator")
        _seed_require(generator is self._gate_owner and generator.session is self.gate_session)
        try:
            context = module._Generator._kill_source_request_phase(generator)
            self.release_gate_local()
            register_raw = module._Generator._kill_source_result_phase(generator, context)
            try:
                _seed_require(self.gate_session.phase == "K_DONE"
                    and self.gate_session.coverage_request_raw is None)
                native = self.gate_session.kill_source
                capture_P, local_P = self._gate_kill_carriers()
                self.kill(native, capture_P, local_P)
                self.scope_reader_inputs(generator.reader, generator=True)
            except BaseException as error:
                self._failed(error, "seed-gate-K_DONE")
                if isinstance(self.failure, KeyboardInterrupt) or getattr(self.failure, "_scope_signal_cancel", False):
                    raise self.failure
            manifest_owner = module._Generator._run_after_kill(generator, register_raw)
            try:
                if self.gate_session.coverage_source is not None:
                    self._gate_generator_runtime_inputs()
                    self._gate_coverage_occurrence()
                self.gate()
                self.gate_output_members()
            except BaseException as error:
                self._failed(error, "seed-gate-before-complete")
                if isinstance(self.failure, KeyboardInterrupt) or getattr(self.failure, "_scope_signal_cancel", False):
                    raise self.failure
            module._Generator._run_complete(generator, manifest_owner)
            try:self.gate_outputs()
            except BaseException as error:
                self._failed(error, "seed-gate-after-complete")
                if isinstance(self.failure, KeyboardInterrupt) or getattr(self.failure, "_scope_signal_cancel", False):
                    raise self.failure
        finally:
            try:self.close_gate()
            except BaseException as error:
                if not self.gate_close_returned or isinstance(error, KeyboardInterrupt) or getattr(error, "_scope_signal_cancel", False):
                    raise
                self._failed(error, "seed-gate-close-recording")

    def _gate_kill_carriers(self):
        reader, native = self.generator.reader, self.gate_session.kill_source
        module = self._gate_type(reader, "scope/v1/read-shadow-evidence.py", "_Reader")
        owner = module.c
        _seed_require(self.gate_session.phase == "K_DONE" and reader.commands_open
            and type(native) is owner._HeldCoverageRead and native.anchor is reader.anchor
            and reader.anchor.scope_runtime_owner is reader)
        request_raw = self.gate_session.kill_request_raw
        _seed_require(type(request_raw) is bytes and native.capture.request_raw == request_raw)
        request = self._wrapper_parse(request_raw, "gate-source-caller")
        request_sha = self._digest(request_raw, "M")
        captures = [item for item in reader.source_copies
            if getattr(item, "scope_source", None) is native and not item.closed]
        configurations = [item for item in reader.source_copies
            if getattr(item, "source_configuration_source", None) is native and not item.closed]
        _seed_require(len(captures) == len(configurations) == 1)
        local = [configurations[0]]
        invoice_rows = [row for row in reader.anchor.private_observations["local_runtime"]
            if row["request_sha256"] == request_sha and row["attempt_id"] == request["id"]]
        selected = []
        for copied in reader.source_copies:
            association = getattr(copied, "scope_runtime_acquisition", None)
            if association is None:continue
            _seed_require(type(association) is tuple and len(association) == 4)
            row, snapshot, original, member = association
            if not any(row is wanted for wanted in invoice_rows):continue
            _seed_require(not copied.closed and copied.anchor is reader.anchor
                and type(snapshot) is owner._RuntimeSnapshot and snapshot.owner is original
                and type(original) is owner.HeldPath and original.components
                and copied.members.get(row["file"]) is member and member.components
                and not any(row is previous for previous in selected))
            selected.append(row)
            local.append(copied)
        _seed_require(invoice_rows and len(selected) == len(invoice_rows)
            and all(any(row is actual for actual in selected) for row in invoice_rows))
        return captures[0], local

    def _gate_generator_runtime_inputs(self):
        reader = self.generator.reader
        context = self.gate_session.p_handoff
        _seed_require(type(context) is self.c._C1PHandoffParent and context.session is self.gate_session
            and context.root is self.root and context.work is self.work
            and not context.unusable and context.generator_runtime_stages)
        stages = self.__dict__.setdefault("_scope_P_stages", [])
        for recorded in context.generator_runtime_stages:
            source, copied, target = recorded["source"], recorded["copied"], recorded["target"]
            _seed_require(recorded["reader"] is reader and copied.anchor is reader.anchor
                and copied.scope_runtime_acquisition is recorded["association"]
                and recorded["association"][0] is recorded["invoice"]
                and recorded["association"][3] is source and copied.closed and not copied.owned
                and not source.components and not self.c._capture_work_incomplete(copied.leaf)
                and not reader.anchor.private_observations.get("unusable", False))
            name, invoice = recorded["name"], recorded["invoice"]
            context._equal_M(self.c._c1_p_side_raw(recorded["invoice"], self.work), recorded["invoice_raw"])
            _seed_require(any(item is target for item in self.output_holds) and self.files[name] == {
                "size_bytes": recorded["size_bytes"], "sha256": recorded["sha256"], "kind": "runtime"})
            target.recheck("E_STORE", self.work, "M")
            member = "generator/" + invoice["file"]
            _seed_require(name not in self.semantic_expected and id(source) not in self.source_occurrences
                and not any(item["reader"] is reader and item["member"] == member for item in stages))
            self.semantic_expected[name] = ("gate", "local-runtime", member,
                recorded["size_bytes"], recorded["sha256"], "runtime")
            self._semantic_record("gate", "local-runtime", member, name)
            self.source_occurrences.add(id(source))
            self._gate_recorded_retained_runtime(recorded)
            stages.append({"reader": reader, "context": "generator", "member": member,
                "source": source, "copied": copied, "name": invoice["file"],
                "expected": recorded["sha256"], "kind": "runtime", "identity": recorded["identity"],
                "size_bytes": recorded["size_bytes"], "target": target, "key": name,
                "parent_runtime_stage": recorded})
        self._transfer()

    def _gate_recorded_retained_runtime(self, recorded):
        path = Path(recorded["source"].path)
        if not path.is_relative_to(self.generator.output):return
        member = "generator/" + path.relative_to(self.generator.output).as_posix()
        registry = self.__dict__.setdefault("gate_recorded_members", {})
        _seed_require(member not in registry and recorded["reader"] is self.generator.reader
            and recorded["target"].components and recorded["copied"].closed)
        name = "gate-output-%03d" % len(registry)
        _seed_require(name not in self.semantic_expected and len(registry) < 256)
        self.semantic_expected[name] = ("gate", "recorded", member,
            recorded["size_bytes"], recorded["sha256"], "runtime")
        target = self._copy(self.anchor, recorded["target"], name, recorded["sha256"],
            "runtime", source_mode=0o400)
        self._semantic_record("gate", "recorded", member, name)
        registry[member] = {"reader": recorded["reader"], "held": recorded["source"],
            "copied": recorded["copied"], "expected": recorded["sha256"], "kind": "runtime",
            "identities": recorded["identity"], "file": name, "target": target}
        recorded["recorded_target"], recorded["recorded_name"] = target, name
        self._transfer()

    def _gate_closed_coverage_runtime(self, copied, native):
        context = self.gate_session.p_handoff
        _seed_require(type(context) is self.c._C1PHandoffParent and not context.unusable
            and context.session is self.gate_session and context.root is self.root
            and native is self.gate_session.coverage_source and copied.closed and not copied.owned
            and copied.directory is None and copied.anchor is self.generator.reader.anchor
            and not self.c._capture_work_incomplete(copied.leaf))
        matches = [row for row in context.generator_runtime_stages if row["copied"] is copied]
        _seed_require(len(matches) == 1)
        row = matches[0]
        context._equal_M(self.c._c1_p_side_raw(row["invoice"], self.work), row["invoice_raw"])
        _seed_require(row["reader"] is self.generator.reader and copied.scope_runtime_acquisition is row["association"]
            and row["association"][0] is row["invoice"] and row["association"][3] is row["source"]
            and not row["source"].components and copied.members.get(row["invoice"]["file"]) is row["source"])
        staged = [item for item in self.__dict__.get("_scope_P_stages", [])
            if item.get("parent_runtime_stage") is row and item["copied"] is copied]
        _seed_require(len(staged) == 1 and staged[0]["identity"] == row["identity"]
            and staged[0]["target"] is row["target"] and row["name"] in self.semantic)
        caller = self._wrapper_parse(native.capture.request_raw, "coverage-closed-runtime-caller")
        _seed_require(row["invoice"]["request_sha256"] == self._digest(native.capture.request_raw, "M")
            and row["invoice"]["attempt_id"] == caller["id"]
            and any(value is row["invoice"] for value in copied.anchor.private_observations["local_runtime"]))
        row["target"].recheck("E_STORE", self.work, "M")
        _seed_require(row["target"].before.st_size == row["size_bytes"]
            and self.files[row["name"]] == {"size_bytes": row["size_bytes"], "sha256": row["sha256"], "kind": "runtime"})
        return row

    def _gate_coverage_occurrence(self):
        reader, native = self.generator.reader, self.gate_session.coverage_source
        _seed_require(self.gate_session.phase == "FINAL_OWNER" and self.gate_session.owner_confirmed
            and native is not None and reader.commands_open and "coverage" not in self.occurrences)
        captures = [item for item in reader.source_copies
            if getattr(item, "scope_source", None) is native and not item.closed]
        configurations = [item for item in reader.source_copies
            if getattr(item, "source_configuration_source", None) is native and not item.closed]
        _seed_require(len(captures) == len(configurations) == 1)
        runtime = []
        for row in self.gate_session.p_handoff.generator_runtime_stages:
            self._gate_closed_coverage_runtime(row["copied"], native)
            runtime.append(row["copied"])
        self.coverage(native, captures[0], [configurations[0], *runtime])

    def gate_output_members(self):
        try:
            generator = self.generator
            module = self._gate_type(generator, "scope/v1/generate-gate-evidence.py", "_Generator")
            _seed_require(generator is self._gate_owner and generator.active
                and generator.session is self.gate_session and self.gate_session.phase == "FINAL_OWNER"
                and not generator.capture_output_unusable and "gate" in self.occurrences
                and not hasattr(self, "gate_manifest_pending"))
            self._gate_private_output_members(generator.reader)
            holders = dict(generator.output_holds)
            for item in generator.reader.owned:
                if type(item) is not module.c._HeldBytes:continue
                path = Path(item.held.path)
                if not path.is_relative_to(generator.output):continue
                name = path.relative_to(generator.output).as_posix()
                if name in holders:
                    previous = holders[name]
                    if previous is not item and previous.held is not item.held:
                        _seed_require(type(previous) is module.c._HeldBytes
                            and previous.held.path == item.held.path
                            and any(reader is generator.reader and held is item
                                for reader, held in generator.reader.replay_outputs["holds"]))
                        self._source_check(module.c, previous.held, generator.reader.anchor, 0o400)
                        self._source_check(module.c, item.held, generator.reader.anchor, 0o400)
                        left = tuple((part.name, module.c._identity(part.before)) for part in previous.held.components)
                        right = tuple((part.name, module.c._identity(part.before)) for part in item.held.components)
                        left_raw, right_raw = self._wrapper_encode(left), self._wrapper_encode(right)
                        self.work["gate_duplicate_hold_compare_incomplete"] = True
                        equal = left == right and previous.raw == item.raw
                        self._charge("E", len(left_raw) + len(right_raw) + len(previous.raw) + len(item.raw), "M")
                        _seed_require(equal)
                        self._source_check(module.c, previous.held, generator.reader.anchor, 0o400)
                        self._source_check(module.c, item.held, generator.reader.anchor, 0o400)
                        self.work["gate_duplicate_hold_compare_incomplete"] = False
                else:holders[name] = item
            manifest_name = "manifests/manifest.json"
            _seed_require(manifest_name in holders)
            manifest_raw = holders[manifest_name].raw
            manifest = self._wrapper_parse(manifest_raw, "gate-output-manifest")
            rows = manifest["body"]["files"]
            _seed_require(type(rows) is list and all(type(row) is dict and set(row) == {"name", "size_bytes", "sha256"}
                for row in rows) and len({row["name"] for row in rows}) == len(rows))
            for name, item in sorted(holders.items()):
                _seed_require(type(item) is module.c._HeldBytes and item.held.components)
                self._gate_recorded_member(generator.reader, item.held, self._digest(item.raw, "M"), "M")
            registry = self.gate_recorded_members
            _seed_require(set(registry) == {"generator/" + row["name"] for row in rows}
                | {"generator/" + manifest_name})
            for row in rows:
                actual = registry["generator/" + row["name"]]
                fact = self.files[actual["file"]]
                _seed_require(fact["size_bytes"] == row["size_bytes"] and fact["sha256"] == row["sha256"])
                actual["target"].recheck("E_STORE", self.work, "M")
            self.gate_manifest_pending = manifest_raw
            self.output_relations.append(("gate-pending", generator, manifest_raw))
            self._transfer()
        except BaseException as error:
            self._failed(error, "seed-gate-output-members")
            raise self.failure

    def gate_outputs(self):
        try:
            generator = self.generator
            module = self._gate_type(generator, "scope/v1/generate-gate-evidence.py", "_Generator")
            _seed_require(generator is self._gate_owner and generator.active and generator.session is self.gate_session
                and self.gate_session.phase == "COMPLETE" and not generator.capture_output_unusable
                and "gate-output" not in self.derived_outputs and hasattr(self, "gate_manifest_pending"))
            manifest_raw = self.gate_manifest_pending
            held = generator.output_holds["manifests/manifest.json"]
            complete = generator.output_holds["completion/COMPLETE.json"]
            _seed_require(held.raw is manifest_raw and type(complete) is module.c._HeldBytes and complete.held.components)
            rebuilt = module._completion_values(self.identifiers["gate"], manifest_raw, self.work)
            self._charge("E", len(rebuilt) + len(complete.raw), "M")
            self._wrapper_processed("gate-output-completion-compare", len(rebuilt) + len(complete.raw))
            _seed_require(rebuilt == complete.raw)
            self._gate_recorded_member(generator.reader, complete.held, self._digest(complete.raw, "M"), "M")
            installed = {member[len("generator/"):]: value["file"] for member, value in self.gate_recorded_members.items()}
            _seed_require(set(installed) == {row["name"] for row in self._wrapper_parse(manifest_raw,
                "gate-output-final-manifest")["body"]["files"]} | {"manifests/manifest.json", "completion/COMPLETE.json"})
            for value in self.gate_recorded_members.values():value["target"].recheck("E_STORE", self.work, "M")
            generator.reader.anchor.recheck("E_STORE")
            self.derived_outputs["gate-output"] = installed
            self.output_relations.append(("gate", generator, manifest_raw, complete.raw))
            self._transfer()
        except BaseException as error:
            self._failed(error, "seed-gate-outputs")
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
        session.p_handoff = self.c._C1PHandoffParent(generator.reader.anchor, self.root,
            self.work, self.case_work, request_raw, session, self.files, self.output_holds,
            self.window, self.case_sources, self.bindings)

    def _gate_request(self):
        module = self._gate_type(self.generator, "scope/v1/generate-gate-evidence.py", "_Generator")
        original = module.generation_request(self.original_raw[3])
        _seed_require(original == self.generator.request and original["id"] == self.identifiers["gate"]
            and self.gate_session.binding == self._digest(self.original_raw[3]))
        return original

    def scope_reader_inputs(self, reader, *, generator=False):
        _seed_require(type(generator) is bool and self.gate_session is not None)
        module = self._gate_type(reader, "scope/v1/read-shadow-evidence.py", "_Reader")
        _seed_require(reader.commands_open and reader.store_session is not None)
        if generator:_seed_require(reader is self.generator.reader)
        else:
            _seed_require(reader is not self.generator.reader and reader.store_session.is_inner
                and reader.store_session.kill_request_raw == self.gate_session.kill_request_raw
                and reader.store_session.gate_call_ref == self.gate_session.gate_call_ref)
        self._scope_reader_inputs(reader, generator)
        self._gate_private_output_members(reader)
        self._transfer()

    def source_coverage(self, reader, qualifying, current, row_groups):
        module = self._gate_type(reader, "scope/v1/read-shadow-evidence.py", "_Reader")
        _seed_require(reader is not self.generator.reader and reader.commands_open
            and type(reader.store_session) is module._GateReaderSession and reader.store_session.is_inner)
        context, result = reader._source_coverage_request_phase(qualifying, current, row_groups)
        if context is None:return result
        try:self.scope_reader_inputs(reader, generator=False)
        except BaseException as error:
            self._failed(error, "seed-scope-before-release")
            if isinstance(self.failure, KeyboardInterrupt) or getattr(self.failure, "_scope_signal_cancel", False):
                raise self.failure
        return reader._source_coverage_release_phase(context)

    def release_gate_local(self):
        generator = self.generator
        module = self._gate_type(generator, "scope/v1/generate-gate-evidence.py", "_Generator")
        _seed_require(type(generator.session) is module._GateStoreSession
            and generator.session is self.gate_session and generator.reader.commands_open)
        try:
            self.scope_reader_inputs(generator.reader, generator=True)
            self._nested_reproduction_outputs(generator.reader)
            self.bundle_outputs("write", generator.reader)
            self.candidate_outputs(generator.reader)
        except BaseException as error:
            self._failed(error, "seed-generator-before-release")
            if isinstance(self.failure, KeyboardInterrupt) or getattr(self.failure, "_scope_signal_cancel", False):
                raise self.failure
        generator.session._release_local_close_phase()
        generator.session._release_local_check_phase()

    def _reader_observations(self, reader, generator=False):
        module = self._gate_type(reader, "scope/v1/read-shadow-evidence.py", "_Reader")
        reader.recheck()
        anchor = reader.anchor
        _seed_require(anchor is not None)
        _seed_require(getattr(anchor, "scope_runtime_owner", None) is reader)
        self._scope_reader_inputs(reader, generator)
        self._gate_private_output_members(reader)
        observations = anchor.private_observations
        _seed_require("entropy" in observations and "commands" in observations
            and "runtime_values" in observations["commands"] and observations["storage_reads"])
        module._scope_runtime_prefix_values(observations["commands"]["runtime_values"],
            observations["commands"]["runtime_values"])
        storage = module.c._gate_storage_rows_values(observations["storage_reads"])
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

    def _remote_scope_inputs(self):
        context = getattr(self.gate_session, "p_handoff", None)
        _seed_require(type(context) is self.c._C1PHandoffParent and context.session is self.gate_session
            and context.root is self.root and context.work is self.work and context.case_work is self.case_work
            and context.files is self.files and context.output_holds is self.output_holds
            and context.request_raw is self.original_raw[3] and self.gate_session.closed)
        value, locators = context.scope_values()
        for serial, record in context.records.items():
            name, row, target = record["name"], record["row"], record["target"]
            _seed_require(target.components and target in self.output_holds
                and self.files[name]["size_bytes"] == row["size_bytes"]
                and self.files[name]["sha256"] == row["sha256"]
                and self.c._identity(target.before) == record["initial_identity"])
            role, member = record["semantic"]
            _gate_input_member_values(role, member, record["kind"], row["size_bytes"])
            expected = ("gate", role, member, row["size_bytes"], row["sha256"], record["kind"])
            if name in self.semantic_expected:
                _seed_require(self.semantic_expected[name] == expected and name in self.semantic)
            else:
                _seed_require(name not in self.semantic)
                self.semantic_expected[name] = expected
                self._semantic_record("gate", role, member, name)
                if record["kind"] == "runtime":
                    self.runtime_files += 1;self.runtime_bytes += row["size_bytes"]
                    _seed_require(self.runtime_files <= 64 and self.runtime_bytes <= 4 << 30)
        scoped = [item for item in self.generator.held if getattr(item, "held", None) is not None
            and item.held.path == str(self.generator.outputs["scope"])]
        _seed_require(len(scoped) == 1)
        self.scope_raw, self.scope_local = scoped[0].raw, value
        self.remote_scope_locators = locators
        self._gate_remote_context = context
        self._remote_scope_outputs(context)
        self._transfer()

    def gate(self):
        if not hasattr(self, "scope_local"):self._remote_scope_inputs()
        _seed_require(self.gate_session is not None and "gate" not in self.occurrences
            and hasattr(self, "scope_local"))
        session, generator = self.gate_session, self.generator
        module = self._gate_type(generator, "scope/v1/generate-gate-evidence.py", "_Generator")
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
        self.locators["gate"] = {"scope": scoped.held.path, "source_root": str(module.PACKAGE),
            **{name: str(path) for name, path in zip(
                ("request", "shadow_set", "dashboard", "marker", "bundle_root", "git_root", "output"), generator.paths)}}
        readers = [("generator", generator.reader)]
        if hasattr(self, "scope_reader"):readers.append(("scope_reader", self.scope_reader))
        else:
            _seed_require(hasattr(self, "remote_scope_locators"))
            self.locators["gate"].update({"scope_reader." + key: value for key, value in self.remote_scope_locators.items()})
        for context, actual_reader in readers:
            actual_module = self._gate_type(actual_reader, "scope/v1/read-shadow-evidence.py", "_Reader")
            actual_paths = {
                "scratch": actual_reader.scratch, "runtime": actual_reader.runtime,
                "captures": actual_reader.captures, "output": actual_reader.output,
                "git_root": actual_reader.git_root, "git_config": actual_reader.git.config_path,
                "package": actual_module.PACKAGE,
                "python": actual_reader.python.held.path, "jq": actual_reader.jq.held.path,
                "bash": actual_reader.bash.held.path, "git": actual_reader.git_binary.held.path,
            }
            for label, raw in (("scope_input", actual_reader.scope_raw), ("set_input", actual_reader.set_raw)):
                matching = [item.held.path for item in actual_reader.owned
                    if type(item) is actual_module.c._HeldBytes and item.raw is raw and item.held.components]
                _seed_require(len(matching) == 1)
                actual_paths[label] = matching[0]
            for key, path in actual_paths.items():
                value = str(path)
                _seed_require(value.startswith("/") and "\0" not in value and len(os.fsencode(value)) <= 4096)
                self.locators["gate"][context + "." + key] = value

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

    def _wrapper_parse(self, raw, site):
        self.c._require(type(raw) is bytes and len(raw) <= self.c.DOCUMENT_LIMIT, "E_STORE")
        self.work["wrapper_parse_attempt_bytes"] = len(raw)
        self.work["wrapper_parse_unknown"] = True
        value = json.loads(raw, object_pairs_hook=self.c._unique_object)
        self._charge("R", len(raw), "M")
        self.work["wrapper_parse_unknown"] = False
        self.c._require(type(value) is dict, "E_STORE")
        encoded = self._wrapper_encode(value)
        self._charge("E", len(encoded) + len(raw), "M")
        self._wrapper_processed(site + "-compare", len(encoded) + len(raw))
        self.c._require(encoded == raw, "E_STORE")
        return value

    def _wrapper_encode(self, value):
        before = self.work["read_bytes"]
        raw, failure = None, None
        try:raw = self.c._private_capture_observations(value, self.work, self.work)
        except BaseException as error:failure = error
        finally:
            processed = self.work["read_bytes"] - before
            try:
                self._charge("C", processed, "M")
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
        return self._write_value_file(raw, "raw-observations.json", "case", "raw-observations",
            "raw-observations.json", "raw", self.c.DOCUMENT_LIMIT)

    def _write_value_file(self, raw, name, occurrence, role, member, kind, limit):
        _seed_require(type(raw) is bytes and len(raw) <= limit and type(name) is str
            and name and "/" not in name and "\0" not in name
            and name not in self.files and len(self.files) < 256
            and self.failure is None and not self.closed)
        self._root_check()
        expected = self._digest(raw, kind)
        state, target, primary = self.root.before, None, None
        try:
            target = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o400, dir_fd=self.root.fd)
            self.work["files"] += 1
            offset = 0
            while offset < len(raw):
                chunk = memoryview(raw)[offset:offset + 65536]
                self.c._capture_copy_room(self.work, len(chunk), False)
                count = os.write(target, chunk)
                _seed_require(0 < count <= len(chunk))
                try:
                    self._charge("W", count, kind);self._charge("C", count, kind)
                except BaseException as error:
                    self._failed(error, "seed-document-written-accounting")
                    self.work["write_accounting_incomplete"] = True
                    self.work.setdefault("observed_write_failures", []).append({"name": name, "return": count})
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
        held = self.c._open_child(self.root, name, False,
            self.c._store_rule(os.geteuid(), os.getegid(), 0o400, False, self.resolver), "E_STORE",
            recording_work=self.work, accounting_kind="M")
        self._adopt_output(held)
        _seed_require(held.before.st_size == len(raw))
        measured = hashlib.sha256()
        offset = 0
        while offset < len(raw):
            count = min(65536, len(raw) - offset)
            chunk = self._read(held.fd, count, offset, kind)
            measured.update(chunk);self._charge("H", len(chunk), kind)
            self._charge("E", 2 * len(chunk), kind)
            _seed_require(chunk == memoryview(raw)[offset:offset + count])
            offset += count
        _seed_require(measured.hexdigest() == expected)
        held.recheck("E_STORE")
        self.files[name] = {"size_bytes": len(raw), "sha256": expected, "kind": kind}
        self.semantic_expected[name] = (occurrence, role, member, len(raw), expected, kind)
        self._semantic_record(occurrence, role, member, name)
        return name

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

    def closed_manifest_data(self, descriptor_raw):
        try:
            core = self._closed_inventory_core_data()["inventory_core"]
            roles = _CASE_ROLES if self.coverage_required is True else _CASE_ROLES[:-1]
            _seed_require(type(self.coverage_required) is bool
                and {row["role"] for row in core["occurrences"]} == set(roles)
                and len(core["occurrences"]) == len(roles)
                and set(self.derived_outputs) == {"reproduction", "write", "candidate", "gate-output"})
            self.work["manifest_incomplete"] = True
            self.work["manifest_descriptor_parse_attempt_bytes"] = len(descriptor_raw)
            self.work["manifest_descriptor_parse_unknown"] = True
            descriptor = self.c._json(descriptor_raw, self.c.DOCUMENT_LIMIT, "E_STORE")
            self._wrapper_processed("manifest-descriptor-parse", len(descriptor_raw))
            self.work["manifest_descriptor_parse_unknown"] = False
            _seed_require(type(descriptor) is dict and set(descriptor) == {"cases", "carry_in"}
                and set(descriptor["cases"]) == {"malicious.incident-symptom-text", "malicious.checked-file-bytes",
                    "malicious.commit-message", "malicious.unread-forge-text"})
            binding = descriptor["cases"][self.case_id]
            _seed_require(type(binding) is dict and set(binding) == {"inventory_core", "sha256"})
            encoded = self._wrapper_encode(core)
            self._wrapper_processed("manifest-core-compare", 2 * len(encoded))
            _seed_require(binding["inventory_core"] == core and binding["sha256"] == self._digest(encoded))
            entries = {row["file"]: row for row in core["entries"]}
            original_members = {row["member"] for row in core["entries"] if row["role"] == "original-input"}
            required_inputs = set(self.original_bindings) | set(_SURFACE_INPUTS) | (_TRIAL_DOCUMENTS - {"gate/basis.json", "gate/claim.json"})
            _seed_require(required_inputs <= original_members
                and any(member.startswith("git/objects/") for member in original_members)
                and {"git/HEAD", "git/config"} <= original_members)
            expected_outputs = set()
            bindings = []
            for identity, form in sorted(self.output_forms.items()):
                phase, context, role, environment = identity
                _seed_require(phase in {"reproduction", "write"} and context in {"generator", "scope_reader"}
                    and role in {"current", "qualifying"} and self.c._id(environment))
                names = set(self.c.SHADOW_EVIDENCE_NAMES) | {"bundle.json"}
                if phase == "write":names.add("publisher-body.txt")
                if form == "withheld-write-policy.v1":names.add("scope-policy.json")
                _seed_require(form in ({"enforced-reproduction.v1"} if phase == "reproduction"
                    else {"withheld-write.v1", "withheld-write-policy.v1"}))
                prefix = "bundle/" + context + "/" + role + "/" + environment + "/"
                mapping = self.derived_outputs[phase]
                _seed_require({member[len(prefix):] for member in mapping if member.startswith(prefix)} == names)
                members = {}
                for name in sorted(names):
                    physical = mapping[prefix + name]
                    row = entries[physical]
                    _seed_require((row["occurrence"], row["role"], row["member"])
                        == (phase, "recorded", prefix + name))
                    expected_outputs.add(physical);members[name] = physical
                if phase == "write":
                    paths = self.output_write_sets[identity]
                    _seed_require(paths and any(path.endswith("/eval-seed.json") for path in paths)
                        and any(path.endswith("/README.md") for path in paths))
                    candidate_prefix = "candidate/" + context + "/" + role + "/" + environment + "/"
                    candidate = self.derived_outputs["candidate"]
                    _seed_require({member[len(candidate_prefix):] for member in candidate
                        if member.startswith(candidate_prefix)} == set(paths))
                    for path in paths:
                        physical = candidate[candidate_prefix + path]
                        row = entries[physical]
                        _seed_require((row["occurrence"], row["role"], row["member"])
                            == ("write", "recorded", candidate_prefix + path))
                        expected_outputs.add(physical)
                bindings.append({"occurrence": phase, "context": context, "role": role,
                    "environment_id": environment, "record_form": form, "members": members})
            for relation in self.output_relations:
                if relation[0] not in {"reproduction", "write"}:continue
                phase, owner, context, role, environment, source = relation
                identity = (phase, context, role, environment)
                _seed_require(identity in self.output_forms)
                if context == "scope_reader" and owner is getattr(self, "_gate_remote_context", None):
                    _seed_require(owner.completion_checked and not owner.unusable
                        and any(source is group for group in owner.history_groups.values())
                        and source["current_output"] and (role, environment) in source["roles"])
                else:
                    self._gate_type(owner, "scope/v1/read-shadow-evidence.py", "_Reader")
                    if type(source) is tuple:
                        outer, association = source
                        _seed_require(phase == "reproduction" and context == "generator"
                            and owner is self.generator.reader and association is outer.scope_reproduction_acquisition
                            and association[0] is owner and association[1] is outer
                            and association[6][1][1:] == (role, environment)
                            and any(value is association[6] for value in owner.replay_nested_reproductions)
                            and any(value is association[6][2] for value in owner.replay_outputs["stores"]))
                    else:
                        _seed_require(any(bundle is source and (found_role, found_environment) == (role, environment)
                            and raw == source.files["shadow-record.json"]
                            for raw, (bundle, found_role, found_environment) in owner.replay_outputs["bundles"]))
            for phase in ("reproduction", "write"):
                _seed_require({identity[1] for identity in self.output_forms if identity[0] == phase}
                    == {"generator", "scope_reader"})
            mapping = self.derived_outputs["gate-output"]
            relations = [row for row in self.output_relations if row[0] == "gate"]
            _seed_require(len(relations) == 1)
            manifest_raw = relations[0][2]
            self.work["manifest_gate_parse_attempt_bytes"] = len(manifest_raw)
            self.work["manifest_gate_parse_unknown"] = True
            manifest = self.c._json(manifest_raw, self.c.DOCUMENT_LIMIT, "E_STORE")
            self._wrapper_processed("manifest-gate-parse", len(manifest_raw))
            self.work["manifest_gate_parse_unknown"] = False
            listed = {row["name"] for row in manifest["body"]["files"]}
            required = {"request", "basis", "claim", "stage-request", "resolved-profile", "stage-result",
                "policy-set", "shadow-set", "dashboard", "marker", "kill-request", "kill-expectation",
                "kill-configuration", "runtime", "initial-origins", "final-origins", "commands", "register",
                "state", "attempt", "duty", "risk", "kill", "scope", "scope-evaluation", "kill-evidence"}
            if self.coverage_required:required |= {"coverage-request", "coverage-expectation", "coverage-evidence"}
            _seed_require({"objects/" + name + "/value.json" for name in required} <= listed
                and set(mapping) == listed | {"manifests/manifest.json", "completion/COMPLETE.json"})
            for name, physical in mapping.items():
                row = entries[physical]
                _seed_require((row["occurrence"], row["role"], row["member"])
                    == ("gate", "recorded", "generator/" + name))
                expected_outputs.add(physical)
            _seed_require(expected_outputs == {name for values in self.derived_outputs.values()
                for name in values.values()})
            value = {"case_id": self.case_id,
                "window_ref": {"size_bytes": len(descriptor_raw), "sha256": self._digest(descriptor_raw)},
                "inventory_core": core, "output_bindings": bindings}
            raw = self._wrapper_encode(value)
            result = {"content": value, "sha256": self._digest(raw)}
            self.work["manifest_incomplete"] = False
            self._transfer()
            return result
        except BaseException as error:
            self._failed(error, "seed-full-manifest")
            if not self.work.get("transfer_incomplete", False):
                try:self._transfer()
                except BaseException as later:self.failure = _seed_first(self.failure, later)
            raise self.failure

    def _closed_gate(self):
        _seed_require(self.failure is None and not self.c._capture_work_incomplete(self.work)
            and self.gate_close_returned and self.gate_session.closed and self.gate_session.owner_confirmed
            and self.gate_session.phase == "COMPLETE" and not self.gate_session.remote)
        _seed_require(not self.generator.active and not self.generator.held
            and not self.generator.reader.owned)
        if hasattr(self, "scope_reader"):
            _seed_require(not self.scope_reader.owned and not self.scope_reader.commands_open)
        else:
            context = getattr(self.gate_session, "p_handoff", None)
            _seed_require(type(context) is self.c._C1PHandoffParent
                and context is self._gate_remote_context
                and context.session is self.gate_session and context.anchor is self.generator.reader.anchor
                and context.work is self.work and context.case_work is self.case_work
                and context.window_work is self.window and context.files is self.files
                and context.runtime is None
                and context.completion_checked and not context.unusable
                and "FINAL_OWNER" in context.batches and "CLOSED" in context.settlements
                and ("C_REQUEST" not in context.batches or "C_RELEASED" in context.settlements)
                and set(context.records) == context.closed_serials and context.receipts
                and all(record["target"] in context.output_holds
                    and record["row"]["serial"] == serial for serial, record in context.records.items())
                and hasattr(self, "remote_scope_locators") and hasattr(self, "scope_local")
                and (context.output_holds is self.output_holds or (self.closed
                    and self.output_holds is self._released_holds
                    and all(not held.components for held in context.output_holds))))

    def close_gate(self):
        module = self._gate_type(self.generator, "scope/v1/generate-gate-evidence.py", "_Generator")
        _seed_require(self.generator is self._gate_owner and self.generator.session is self.gate_session
            and self.gate_session.generator is self.generator and self.generator.reader is self.gate_session.reader
            and not self.gate_close_attempted and self.generator.active)
        self.gate_close_attempted = True
        primary = sys.exc_info()[1]
        if primary is not None:self._failed(primary, "case-gate-primary")
        try:module._Generator.close(self.generator)
        except BaseException as error:
            self._failed(error, "case-gate-close")
            native = _seed_first(primary, error)
            if isinstance(self.failure, KeyboardInterrupt) or getattr(self.failure, "_scope_signal_cancel", False):
                native = _seed_first(self.failure, native)
            raise native
        self.gate_close_returned = True
        try:self._transfer()
        except BaseException as error:
            self._failed(error, "case-gate-close-transfer")
            failure = _seed_first(primary, error)
            if isinstance(self.failure, KeyboardInterrupt) or getattr(self.failure, "_scope_signal_cancel", False):
                failure = _seed_first(self.failure, failure)
            raise failure
        if self.failure is not primary and (isinstance(self.failure, KeyboardInterrupt)
                or getattr(self.failure, "_scope_signal_cancel", False)):
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

    def _scope_check_P_S(self, reader, source, target, expected, kind):
        owner = self._gate_type(reader, "scope/v1/read-shadow-evidence.py", "_Reader").c
        self._source_check(owner, source, reader.anchor, 0o400)
        target.recheck("E_STORE", self.work, "M")
        _seed_require(source.before.st_size == target.before.st_size)
        left, right = hashlib.sha256(), hashlib.sha256()
        offset = 0
        while offset < source.before.st_size:
            count = min(65536, source.before.st_size - offset)
            a, b = self._read(source.fd, count, offset, kind), self._read(target.fd, count, offset, kind)
            left.update(a);right.update(b)
            self._charge("H", len(a) + len(b), kind);self._charge("E", len(a) + len(b), kind)
            _seed_require(a == b);offset += count
        _seed_require(left.hexdigest() == right.hexdigest() == expected)
        self._source_check(owner, source, reader.anchor, 0o400)
        target.recheck("E_STORE", self.work, "M")

    def _scope_recorded_alias(self, reader, source, member, expected):
        owner = self._gate_type(reader, "scope/v1/read-shadow-evidence.py", "_Reader").c
        pieces = member.split("/")
        _seed_require(len(pieces) == 4 and pieces[:2] == ["generator", "history"]
            and len(pieces[2]) == 4 and pieces[2].isascii() and pieces[2].isdigit()
            and int(pieces[2]) < 4096 and pieces[3] in owner._c1_history_names_values("enforced-reproduction.v1")[0]
            and type(source) is owner.HeldPath and source.components and id(source) in self.source_occurrences)
        stages = [row for row in self.__dict__.get("_scope_P_stages", []) if row["reader"] is reader
            and row["context"] == "generator" and row["member"] == member]
        _seed_require(len(stages) == 1)
        stage = stages[0]
        _seed_require(stage["source"] is source and stage["copied"] is None
            and stage["name"] == pieces[3] and stage["expected"] == expected and stage["kind"] == "M"
            and stage["identity"] == owner._identity(source.before))
        target, key = stage["target"], stage["key"]
        _seed_require(target in self.output_holds and target.components
            and target.path == self.root.path + "/" + key
            and stage["size_bytes"] == source.before.st_size == target.before.st_size
            and stage.get("target_identity") == owner._identity(target.before)
            and (source.before.st_dev, source.before.st_ino) != (target.before.st_dev, target.before.st_ino)
            and self.files[key] == {"size_bytes": stage["size_bytes"], "sha256": expected, "kind": "M"}
            and self.semantic_expected[key] == ("gate", "capture", member, stage["size_bytes"], expected, "M")
            and self.semantic[key] == {"occurrence": "gate", "role": "capture", "member": member,
                "file": key, "size_bytes": stage["size_bytes"], "sha256": expected, "kind": "M"})
        holders = [item for item in reader.owned if type(item) is owner._HeldBytes and item.held is source]
        _seed_require(len(holders) == 1)
        acquisitions = [item for item in reader.anchor.private_observations["storage_reads"]
            if item["entries"] and all(row["role"] == "store" for row in item["entries"])]
        matches = []
        for record_raw, value in reader.replay_outputs["stores"]:
            store, files, retained, rows = value
            if pieces[3] not in retained:continue
            if not any(path is retained[pieces[3]] and raw is files[pieces[3]] for path, raw in reader.inputs):continue
            if str(retained[pieces[3]]) != source.path:continue
            _seed_require(type(store) is owner._HeldStoreRead and store.anchor is reader.anchor
                and store.storage_rows is rows and record_raw is files["shadow-record.json"])
            ordinals = [index for index, row in enumerate(acquisitions) if row["entries"] is rows]
            _seed_require(ordinals == [int(pieces[2])])
            self._charge("E", len(holders[0].raw) + len(files[pieces[3]]), "M")
            _seed_require(holders[0].raw == files[pieces[3]])
            matches.append(value)
        _seed_require(len(matches) == 1)
        self._scope_check_P_S(reader, source, target, expected, "M")
        _seed_require(stage["identity"] == owner._identity(source.before)
            and stage["target_identity"] == owner._identity(target.before))
        self.c._capture_observe(self.work, "M", "scope-history-recorded-alias", {
            "member": member, "history_file": key, "ordinal": int(pieces[2])})
        _seed_require(not any(anchor is reader.anchor and held is source for anchor, held in self.recorded_aliases))
        self.recorded_aliases.append((reader.anchor, source))

    def _scope_existing_S(self, reader, copied, name, context):
        # Reuse is determined by the actual P object and original phase binding.
        phases = ("kill", "coverage") if context == "generator" else ("coverage",)
        for phase in phases:
            if phase not in self.bindings:continue
            binding = self.bindings[phase]
            carriers = binding["P"]
            if not any(item is copied for item in carriers):continue
            _seed_require(copied.anchor is reader.anchor and name in copied.members)
            configuration = getattr(copied, "source_configuration_members", None)
            if configuration is not None:
                keys = [key for key, row in configuration.items() if row["member"] == name]
                _seed_require(len(keys) == 1);role, member = "capture", "configuration/" + keys[0]
            elif name in copied.runtime_sha256:
                role, member = ("capture" if copied is carriers[0] else "local-runtime"), copied.directory.components[-1].name + "/" + name
            else:role, member = "capture", copied.directory.components[-1].name + "/" + name
            matches = [(key, row) for key, row in self.semantic.items()
                if (row["occurrence"], row["role"], row["member"]) == (phase, role, member)]
            _seed_require(len(matches) == 1)
            key, row = matches[0]
            held = [item for item in self.output_holds if item.path == self.root.path + "/" + key]
            _seed_require(len(held) == 1)
            return key, row, held[0]
        return None

    def _scope_reader_inputs(self, reader, generator=False):
        module = self._gate_type(reader, "scope/v1/read-shadow-evidence.py", "_Reader")
        context = "generator" if generator else "scope_reader"
        _seed_require(reader.commands_open and reader.anchor is not None
            and reader.anchor.scope_runtime_owner is reader and not reader.replay_output_unusable)
        reader.recheck()
        anchor = reader.anchor
        # Fixed Anchor data from the actual verifier/provenance pass.
        captured = reader.replay_outputs["anchor"]
        _seed_require(captured)
        raw_key, inputs = captured[0]
        _seed_require(raw_key is anchor.config_raw)
        for key, values in captured:
            _seed_require(key is anchor.config_raw and set(values) == set(inputs))
            for name in inputs:
                _seed_require(values[name][1] is inputs[name][1] and values[name][0] == inputs[name][0])
        anchor_stages = [row for row in self.__dict__.get("_scope_P_stages", [])
            if row["reader"] is reader and row["context"] == context and row["member"].startswith(context + "/anchor/")]
        candidates = []
        for row in anchor_stages:
            if not any(row["copied"] is item for item in candidates):candidates.append(row["copied"])
        _seed_require(len(candidates) <= 1)
        copied = candidates[0] if candidates else reader.retain_anchor_inputs(inputs)
        _seed_require(copied is not None and copied.anchor_input_reader is reader)
        if not copied.closed:copied.recheck()
        for key, row in sorted(copied.anchor_input_members.items()):
            _seed_require(row["raw"] is inputs[key][0] and row["original"] is inputs[key][1])
            self._scope_stage_P(reader, copied, row["member"], row["raw"], row["sha256"], "M", context, context + "/anchor/" + key)
        # Each native acquisition retains its original global ordinal. No SHA dedup.
        runtime = anchor.private_observations["local_runtime"]
        complete = {"files": [{key: row[key] for key in ("slot", "index", "ordinal", "locator", "file", "size_bytes", "sha256", "errno")} for row in runtime]}
        module.c._runtime_inventory_values(complete)
        for row in runtime:
            candidates = [copy for copy in reader.source_copies if not copy.closed and row["file"] in copy.runtime_sha256]
            for staged in self.__dict__.get("_scope_P_stages", []):
                if staged["reader"] is reader and staged["context"] == context and staged["name"] == row["file"]:
                    if not any(staged["copied"] is item for item in candidates):candidates.append(staged["copied"])
            _seed_require(len(candidates) == 1)
            copy = candidates[0]
            _seed_require(copy.anchor is anchor and row["file"] in copy.members
                and copy.runtime_sha256[row["file"]] == row["sha256"])
            if copy.members[row["file"]].components:
                _seed_require(copy.members[row["file"]].before.st_size == row["size_bytes"])
            else:
                retained = [item for item in self.__dict__.get("_scope_P_stages", [])
                    if item["reader"] is reader and item["copied"] is copy and item["name"] == row["file"]]
                _seed_require(len(retained) == 1 and retained[0]["size_bytes"] == row["size_bytes"])
            if not copy.closed:copy.recheck()
            self._scope_stage_P(reader, copy, row["file"], None, row["sha256"], "runtime", context, context + "/" + row["file"])
            if not copy.closed:copy.recheck()
        # Exact source object/ordinal links are saved at the original successful P registration.
        source_copies = [copy for copy in reader.source_copies if getattr(copy, "scope_source", None) is not None]
        for row in self.__dict__.get("_scope_P_stages", []):
            item = row["copied"]
            if row["reader"] is reader and getattr(item, "scope_source", None) is not None:
                if not any(item is original for original in source_copies):source_copies.append(item)
        source_copies.sort(key=lambda copy: copy.scope_source_ordinal)
        _seed_require([copy.scope_source_ordinal for copy in source_copies] == list(range(reader.source_capture_ordinal)))
        for copy in source_copies:
            source, ordinal = copy.scope_source, copy.scope_source_ordinal
            _seed_require(copy.anchor is source.anchor is anchor and type(source) is module.c._HeldCoverageRead
                and copy.directory.components[-1].name == "source-%04d" % ordinal)
            raw = copy.consumer_snapshot
            document = module.parse(raw)
            _seed_require(document["attempt_id"] == source.attempt_id
                and document["request_sha256"] == self._digest(source.capture.request_raw, "M"))
            if not copy.closed:copy.recheck()
            self._scope_stage_P(reader, copy, "consumer-observations.json", raw, self._digest(raw, "M"), "M", context,
                context + "/source-%04d/consumer-observations.json" % ordinal)
            configurations = [item for item in reader.source_copies if getattr(item, "source_configuration_source", None) is source
                and item.source_configuration_ordinal == ordinal and not item.closed]
            for staged in self.__dict__.get("_scope_P_stages", []):
                item = staged["copied"]
                if staged["reader"] is reader and getattr(item, "source_configuration_source", None) is source and item.source_configuration_ordinal == ordinal:
                    if not any(item is original for original in configurations):configurations.append(item)
            _seed_require(len(configurations) == 1);configuration = configurations[0]
            _seed_require(configuration.source_configuration is source.configuration
                and configuration.source_configuration_request_raw == source.capture.request_raw)
            for key, row in sorted(configuration.source_configuration_members.items()):
                raw, original = source.configuration.source_inputs[key]
                if not configuration.closed:original.recheck("E_STORE", self.work, "M")
                expected = self._digest(raw, "M")
                _seed_require(expected == row["sha256"])
                self._scope_stage_P(reader, configuration, row["member"], raw, expected, "M", context,
                    context + "/source-configuration-%04d/" % ordinal + key)
            if not configuration.closed:configuration.recheck()
            if not copy.closed:copy.recheck()
        # The original native P captures contain historical inputs. Distinct
        # store acquisitions use distinct labels and S files, even for equal bytes.
        acquisitions = [value for value in anchor.private_observations["storage_reads"]
            if value["entries"] and all(row["role"] == "store" for row in value["entries"])]
        for record_raw, (store, files, retained, storage_rows) in reader.replay_outputs["stores"]:
            request = module.parse(files["sandbox-request.json"])
            ordinals = [index for index, value in enumerate(acquisitions) if value["entries"] is storage_rows]
            _seed_require(len(ordinals) == 1);ordinal = ordinals[0]
            _seed_require(record_raw is files["shadow-record.json"] and set(retained) == set(files)
                and store.snapshots == {key: files[name] for key, name in module._authentication_store_names_values().items()})
            originals, paths = dict(files), dict(retained)
            candidate = getattr(store, "scope_candidate_acquisition", None)
            if candidate is not None:
                original_reader, original_files, original_paths, original_rows, association = candidate
                _seed_require(original_reader is reader and original_files is files
                    and original_paths is retained and original_rows is storage_rows)
                candidate_files, candidate_paths, git_output = association
                frozen, rows, git, outer_files = git_output
                _seed_require(git is reader.git and git.ledger is reader and outer_files is files
                    and any(key is record_raw and value is git_output for key, value in reader.replay_outputs["git"]))
                self.c._c1_history_candidate_values(files, candidate_files, self.work)
                originals.update(candidate_files);paths.update(candidate_paths)
            else:
                _seed_require(module.parse(files["shadow-record.json"])["body"]["record_form"] == "enforced-reproduction.v1")
            for name, path in paths.items():
                holders = [item for item in reader.owned if type(item) is module.c._HeldBytes and item.held.path == str(path)]
                _seed_require(len(holders) == 1 and holders[0].raw == originals[name])
                holder = holders[0];holder.recheck("E_STORE")
                expected = self._digest(originals[name], "M")
                self._scope_stage_P(reader, None, name, (originals[name], holder.held), expected, "M", context,
                    context + "/history/%04d/" % ordinal + name)
        reader.recheck()

    def _scope_stage_P(self, reader, copied, name, raw, expected, kind, context, member):
        owner = self._gate_type(reader, "scope/v1/read-shadow-evidence.py", "_Reader").c
        source = copied.members[name] if copied is not None else raw[1]
        stages = self.__dict__.setdefault("_scope_P_stages", [])
        previous = [row for row in stages if row["reader"] is reader
            and row["context"] == context and row["member"] == member]
        _seed_require(len(previous) <= 1)
        if previous:
            row = previous[0]
            _seed_require(row["source"] is source and row["copied"] is copied and row["name"] == name
                and row["expected"] == expected and row["kind"] == kind)
            target = row["target"]
            if source.components:
                _seed_require(row["identity"] == owner._identity(source.before))
                self._scope_check_P_S(reader, source, target, expected, kind)
            else:
                _seed_require(copied is not None and copied.closed and not copied.owned
                    and not owner._capture_work_incomplete(copied.leaf)
                    and not reader.anchor.private_observations.get("unusable", False))
                target.recheck("E_STORE", self.work, "M")
            return row["key"]
        _seed_require(source.components and (copied is None or not copied.closed))
        existing = self._scope_existing_S(reader, copied, name, context) if copied is not None else None
        copy_source, copy_anchor = source, reader.anchor
        if existing is not None:
            key, row, held = existing
            _seed_require(row["kind"] == kind and row["size_bytes"] == source.before.st_size and row["sha256"] == expected)
            self._scope_check_P_S(reader, source, held, expected, kind)
            copy_source, copy_anchor = held, self.anchor
        target = "gate-" + context + "-" + member.replace("/", "--")
        _seed_require(len(os.fsencode(target)) <= 255)
        self._semantic_copy(copy_anchor, copy_source, target, expected, kind, "gate", "capture" if kind != "runtime" else "local-runtime", member)
        held = [item for item in self.output_holds if item.path == self.root.path + "/" + target]
        _seed_require(len(held) == 1)
        stages.append({"reader": reader, "context": context, "member": member,
            "source": source, "copied": copied, "name": name, "expected": expected, "kind": kind,
            "identity": owner._identity(source.before), "size_bytes": source.before.st_size,
            "target": held[0], "target_identity": owner._identity(held[0].before), "key": target})
        return target



class _ReplayInputs:
    def __init__(self, initial, core, work):
        self.c = _seed_module(initial, ("HeldPath",))
        self.work, self.root, self.owned = work, None, []
        self.files, self.rows, self.measurements, self.failure = {}, {}, {}, None
        self.runtime_bytes, self.runtime_files = 0, 0
        self.resolver = self.c._DarwinUUIDResolver() if sys.platform == "darwin" else None
        self.c._capture_work_values(work, "C3-I-inputs")
        try:
            _seed_require(type(core) is dict and set(core) == {"case_id", "entries", "originals", "occurrences"}
                and core["case_id"] in {"malicious.incident-symptom-text", "malicious.checked-file-bytes",
                    "malicious.commit-message", "malicious.unread-forge-text"} and type(core["entries"]) is list
                and 1 <= len(core["entries"]) <= 256)
            initial.recheck("E_STORE", work, "M")
            components = self.c._clone(initial, "E_STORE", work, "M")
            try:self.root = self.c.HeldPath(initial.path, components, recording_work=work, accounting_kind="M")
            except BaseException as primary:
                self.c._release_held_acquisition(components, None, primary, work)
                raise
            self._adopt(self.root)
            self.c._c3_retain_entity(work, "I", b".", "M", self.root.before, size=0)
            expected, exports, identities = set(), set(), set()
            git_bytes = 0
            for row in core["entries"]:
                _seed_require(type(row) is dict and set(row) == {
                    "occurrence", "role", "member", "file", "size_bytes", "sha256", "kind"})
                name, kind = row["file"], row["kind"]
                _seed_require(type(name) is str and name and "\0" not in name and name not in self.rows
                    and kind in {"raw", "recorded", "runtime", "export", "M", "W"}
                    and type(row["size_bytes"]) is int and row["size_bytes"] >= 0 and self.c._sha(row["sha256"]))
                _seed_require(type(row["occurrence"]) is str and row["occurrence"] in {"case", *_CASE_ROLES}
                    and row["role"] in {"original-input", "raw-observations", "preparation", "recorded", "capture", "local-runtime", "parent-input"}
                    and type(row["member"]) is str and 0 < len(row["member"]) <= 4096 and "\0" not in row["member"])
                identity = (row["occurrence"], row["role"], row["member"])
                _seed_require(identity not in identities);identities.add(identity)
                git_input = row["occurrence"] == "case" and row["role"] == "original-input" and row["member"].startswith("git/")
                if git_input:
                    _git_input_path(row["member"][4:])
                    _seed_require(kind == "raw" and name.startswith("original-git-") and name.endswith(".bin"))
                    git_bytes += row["size_bytes"]
                    _seed_require(git_bytes <= 256 << 20)
                directory = self.root
                if kind == "export":
                    _seed_require(name in {"exports/reproduction.bin", "exports/write.bin"})
                    if not exports:
                        directory = self._adopt(self.c._open_child(self.root, "exports", True,
                            self.c._store_rule(os.geteuid(), os.getegid(), 0o700, True, self.resolver), "E_STORE",
                            recording_work=work, accounting_kind="M"))
                        self.exports = directory
                        self.c._c3_retain_entity(work, "I", b"exports", "M", directory.before, size=0)
                    else:directory = self.exports
                    exports.add(name.rsplit("/", 1)[1]);expected.add("exports")
                else:
                    _seed_require("/" not in name and name not in {".", ".."})
                    expected.add(name)
                held = self._adopt(self.c._open_child(directory, name.rsplit("/", 1)[-1], False,
                    self.c._store_rule(os.geteuid(), os.getegid(), 0o400, False, self.resolver), "E_STORE",
                    recording_work=work, accounting_kind="M"))
                self.c._c3_retain_entity(work, "I", os.fsencode(name), kind,
                    held.before, size=held.before.st_size, uncertain=True)
                _seed_require(held.before.st_size == row["size_bytes"])
                trial_document = row["role"] == "original-input" and row["member"] in _TRIAL_DOCUMENTS
                limit = 4 << 30 if kind == "runtime" else self.c.EXPORT_LIMIT if kind == "export" else (
                    64 * self.c.DOCUMENT_LIMIT if kind == "recorded" or git_input else
                    8 * self.c.DOCUMENT_LIMIT if trial_document and row["member"].endswith("/materialization-input.json") else self.c.DOCUMENT_LIMIT)
                _seed_require(held.before.st_size <= limit)
                if kind == "runtime":
                    self.runtime_files += 1;self.runtime_bytes += held.before.st_size
                    _seed_require(self.runtime_files <= 64 and self.runtime_bytes <= 4 << 30)
                chunks, measured, offset = [], hashlib.sha256(), 0
                while offset < held.before.st_size:
                    count = min(65536, held.before.st_size - offset)
                    if kind == "runtime":
                        for field in ("read_bytes", "sha_bytes"):self.c._runtime_account(work, field, count, commit=False)
                    else:self.c._capture_copy_room(work, count, kind == "export", read_only=True)
                    work["read_calls"] = work.get("read_calls", 0) + 1
                    try:raw = os.pread(held.fd, count, offset)
                    except BaseException:
                        work["read_incomplete"] = True
                        raise
                    self._account("R", len(raw), kind)
                    measured.update(raw);self._account("H", len(raw), kind)
                    _seed_require(len(raw) == count)
                    chunks.append(raw);offset += len(raw)
                _seed_require(measured.hexdigest() == row["sha256"])
                self.measurements[name] = (held.before.st_size, measured.hexdigest())
                held.recheck("E_STORE", work, "M")
                self.c._c3_retain_entity(work, "I", os.fsencode(name), kind, held.before, size=held.before.st_size)
                if kind in {"runtime", "export"}:value = tuple(chunks)
                else:
                    self.c._capture_copy_room(work, held.before.st_size, False, read_only=True)
                    value = chunks[0] if len(chunks) == 1 else b"".join(chunks)
                    if len(chunks) > 1:self._account("C", len(value), kind)
                self.files[name] = value
                self.rows[name] = (dict(row), held)
                self.c._capture_observe(work, "M", "replay-I-member", row)
            self._namespace(self.root, expected)
            if exports:self._namespace(self.exports, exports)
            self.root.recheck("E_STORE", work, "M")
        except BaseException as error:
            self._failed(error)
            self.close(error)
            raise self.failure

    def _namespace(self, held, expected):
        held.recheck("E_STORE", self.work, "M")
        names = held.listdir()
        _seed_require(set(names) == expected)
        held.recheck("E_STORE", self.work, "M")

    def _adopt(self, held):
        try:self.owned.append(held)
        except BaseException as primary:
            self._failed(primary)
            if not (self.owned and self.owned[-1] is held):
                try:held.close()
                except BaseException as later:self._failed(later)
            raise self.failure
        return held

    def _account(self, operation, amount, kind):
        counts = self.work.setdefault("seed_processing", {})
        counts[operation] = counts.get(operation, 0) + amount
        if kind == "runtime":
            field = {"R":"read_bytes", "H":"sha_bytes", "C":"copy_bytes"}[operation]
            self.c._runtime_account(self.work, field, amount)
        elif operation in {"R", "C"}:
            self.work["read_bytes"] += amount
            if kind == "export":self.work["export_read_bytes"] += amount
            self.c._capture_account(self.work, "raw" if kind == "recorded" else kind, "read_bytes", amount)

    def _failed(self, error):
        self.failure = _seed_first(self.failure, error)
        try:self.c._capture_observation_error(self.work, "M", "replay-I", error)
        except BaseException as later:self.failure = _seed_first(self.failure, later)
        try:self.work["replay_incomplete"] = True
        except BaseException as later:self.failure = _seed_first(self.failure, later)

    def semantic(self, occurrence, role, member):
        _seed_require(self.root is not None and self.failure is None)
        matches = [name for name, (row, _held) in self.rows.items()
            if (row["occurrence"], row["role"], row["member"]) == (occurrence, role, member)]
        _seed_require(len(matches) == 1)
        row, held = self.rows[matches[0]]
        held.recheck("E_STORE", self.work, "M")
        return self.files[matches[0]]

    def encode(self, value):
        before, failure, raw = self.work["read_bytes"], None, None
        try:raw = self.c._private_capture_observations(value, self.work, self.work)
        except BaseException as error:failure = error
        finally:
            processed = self.work["read_bytes"] - before
            try:
                self.work.setdefault("seed_processing", {})["C"] = self.work.get("seed_processing", {}).get("C", 0) + processed
                self.c._capture_account(self.work, "M", "read_bytes", processed)
            except BaseException as error:failure = _seed_first(failure, error)
        if failure is not None:
            self._failed(failure)
            raise self.failure
        self.c._capture_account(self.work, "M", "logical_bytes", len(raw))
        self.c._capture_account(self.work, "M", "occurrences", 1)
        return raw

    def bytes(self, occurrence, role, member, maximum):
        value = self.semantic(occurrence, role, member)
        _seed_require(type(maximum) is int and 0 <= maximum <= 64 * self.c.DOCUMENT_LIMIT)
        if type(value) is bytes:
            _seed_require(len(value) <= maximum)
            return value
        _seed_require(type(value) is tuple)
        size = sum(map(len, value));_seed_require(size <= maximum)
        if len(value) == 1:return value[0]
        row = next(row for row, _held in self.rows.values()
            if (row["occurrence"], row["role"], row["member"]) == (occurrence, role, member))
        if row["kind"] == "runtime":self.c._runtime_account(self.work, "copy_bytes", size, commit=False)
        else:self.c._capture_copy_room(self.work, size, row["kind"] == "export", read_only=True)
        result = b"".join(value)
        self._account("C", size, row["kind"])
        return result

    def git_repository(self, destination):
        c = self.c
        _seed_require(type(destination) is c.HeldPath and self.failure is None
            and not os.path.commonpath((destination.path, self.root.path)) in {destination.path, self.root.path})
        destination.recheck("E_STORE", self.work, "M")
        _seed_require(not destination.listdir())
        selected = [(row["member"][4:], name, held) for name, (row, held) in self.rows.items()
            if row["occurrence"] == "case" and row["role"] == "original-input" and row["member"].startswith("git/")]
        _seed_require(selected and {"HEAD", "config"} <= {path for path, _name, _held in selected}
            and any(path.startswith("objects/") for path, _name, _held in selected))
        directories, installed, owned, primary = {"": destination}, {}, [], None
        def adopt(held):
            try:owned.append(held)
            except BaseException as error:
                if not (owned and owned[-1] is held):
                    try:held.close()
                    except BaseException as later:error = _seed_first(error, later)
                raise error
            if held.path != destination.path:
                retained(held.path, held.before, size=held.before.st_size if stat.S_ISREG(held.before.st_mode) else 0)
            return held
        def refreshed(parent, before):
            c._refresh_recording_directory(parent, before, self.work)
            index = len(parent.components) - 1
            for held in owned:
                if os.path.commonpath((held.path, parent.path)) != parent.path:continue
                old, current = held.components[index].before, parent.before
                _seed_require((old.st_dev, old.st_ino, old.st_uid, old.st_gid, old.st_mode)
                    == (current.st_dev, current.st_ino, current.st_uid, current.st_gid, current.st_mode))
                held.components[index].before = current
        def create_room():
            c._capture_copy_room(self.work, 0, False)
            c._capture_copy_budget_room(self.work, 0, False, files=1)
            c._require(self.work["files"] < 256, "E_LIMIT")
        def retained(path, state=None, *, size=None, uncertain=False):
            base = getattr(self, "_replay_private_root", None)
            if base is None:
                self.work["git_retained_root_unknown"] = True
                return
            return c._c3_retain_entity(self.work, "privatework", os.fsencode(os.path.relpath(path, base)),
                "raw", state, size=size, uncertain=uncertain)
        def created(path):
            failure = None
            self.work["files"] += 1
            try:c._capture_account(self.work, "raw", "files", 1)
            except BaseException as error:failure = error
            try:retained(path, size=0)
            except BaseException as error:
                self.work["C3_retained_incomplete"] = True
                failure = _seed_first(failure, error)
            if failure is not None:raise failure
        try:
            before = destination.before
            create_room()
            os.mkdir("refs", 0o700, dir_fd=destination.fd)
            created(os.path.join(destination.path, "refs"))
            c._capture_observe(self.work, "M", "replay-git-directory", {"path": "refs", "return": 0})
            refreshed(destination, before)
            directories["refs"] = adopt(c._open_child(destination, "refs", True,
                c._store_rule(os.geteuid(), os.getegid(), 0o700, True, self.resolver), "E_STORE",
                recording_work=self.work, accounting_kind="M"))
            for path, name, source in sorted(selected):
                _git_input_path(path)
                source.recheck("E_STORE", self.work, "M")
                parts, prefix = path.split("/"), ""
                for part in parts[:-1]:
                    parent = directories[prefix]
                    next_prefix = prefix + "/" + part if prefix else part
                    if next_prefix not in directories:
                        parent.recheck("E_STORE", self.work, "M")
                        before = parent.before
                        create_room()
                        os.mkdir(part, 0o700, dir_fd=parent.fd)
                        created(os.path.join(parent.path, part))
                        c._capture_observe(self.work, "M", "replay-git-directory", {"path": next_prefix, "return": 0})
                        refreshed(parent, before)
                        directories[next_prefix] = adopt(c._open_child(parent, part, True,
                            c._store_rule(os.geteuid(), os.getegid(), 0o700, True, self.resolver), "E_STORE",
                            recording_work=self.work, accounting_kind="M"))
                    prefix = next_prefix
                parent = directories[prefix]
                parent.recheck("E_STORE", self.work, "M")
                before, target, failure = parent.before, None, None
                raw = self.files[name]
                _seed_require(type(raw) is bytes)
                try:
                    create_room()
                    target = os.open(parts[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                        0o400, dir_fd=parent.fd)
                    created(os.path.join(parent.path, parts[-1]))
                    offset = 0
                    while offset < len(raw):
                        c._capture_copy_room(self.work, min(65536, len(raw) - offset), False)
                        count = os.write(target, memoryview(raw)[offset:offset + 65536])
                        _seed_require(0 < count <= min(65536, len(raw) - offset))
                        self.work["write_bytes"] += count;self.work["physical_bytes"] += count
                        self.work.setdefault("seed_processing", {}).setdefault("W", 0)
                        self.work["seed_processing"]["W"] += count
                        self.work["seed_processing"]["C"] = self.work["seed_processing"].get("C", 0) + count
                        c._capture_account(self.work, "raw", "write_bytes", count)
                        c._capture_account(self.work, "raw", "physical_bytes", count)
                        offset += count
                        retained(os.path.join(parent.path, parts[-1]), size=offset)
                    os.fsync(target)
                except BaseException as error:
                    failure = error
                    self._failed(error)
                    raise
                finally:
                    if target is not None:
                        close_error = None
                        try:os.close(target)
                        except BaseException as error:
                            close_error = error
                            self._failed(error)
                            failure = _seed_first(failure, error)
                        try:
                            self.work["close_calls"] = self.work.get("close_calls", 0) + 1
                            c._capture_observe(self.work, "M", "replay-git-close", {
                                "return": 0 if close_error is None else -1,
                                "errno": None if close_error is None else getattr(close_error, "errno", None)})
                        except BaseException as error:
                            self.work["accounting_incomplete"] = True
                            self._failed(error)
                            failure = _seed_first(failure, error)
                        if failure is not None:raise failure
                refreshed(parent, before)
                copied = adopt(c._open_child(parent, parts[-1], False,
                    c._store_rule(os.geteuid(), os.getegid(), 0o400, False, self.resolver), "E_STORE",
                    recording_work=self.work, accounting_kind="M"))
                _seed_require(copied.before.st_size == source.before.st_size == len(raw))
                left_hash, right_hash, offset = hashlib.sha256(), hashlib.sha256(), 0
                while offset < len(raw):
                    size = min(65536, len(raw) - offset)
                    c._capture_copy_room(self.work, size, False, read_only=True)
                    self.work["read_calls"] = self.work.get("read_calls", 0) + 1
                    try:left = os.pread(source.fd, size, offset)
                    except BaseException:
                        self.work["read_incomplete"] = True
                        raise
                    self._account("R", len(left), "raw")
                    c._capture_copy_room(self.work, size, False, read_only=True)
                    self.work["read_calls"] += 1
                    try:right = os.pread(copied.fd, size, offset)
                    except BaseException:
                        self.work["read_incomplete"] = True
                        raise
                    self._account("R", len(right), "raw")
                    left_hash.update(left);self._account("H", len(left), "raw")
                    right_hash.update(right);self._account("H", len(right), "raw")
                    self.work["seed_processing"]["E"] = self.work["seed_processing"].get("E", 0) + len(left) + len(right)
                    _seed_require(len(left) == len(right) == size and left == right == raw[offset:offset + size])
                    offset += size
                _seed_require(left_hash.hexdigest() == right_hash.hexdigest() == self.rows[name][0]["sha256"])
                source.recheck("E_STORE", self.work, "M");copied.recheck("E_STORE", self.work, "M")
                installed[path] = copied
            for path, parent in directories.items():
                expected = {name[len(path) + 1 if path else 0:].split("/", 1)[0]
                    for name in installed if not path or name.startswith(path + "/")}
                if not path:expected.add("refs")
                self._namespace(parent, expected)
                os.fsync(parent.fd)
            return {path: self.rows[name][0]["sha256"] for path, name, _held in selected}
        except BaseException as error:
            primary = error;self._failed(error)
            raise self.failure
        finally:
            while owned:
                held = owned.pop()
                try:
                    held.recheck("E_STORE", self.work, "M")
                    retained(held.path, held.before, size=held.before.st_size if stat.S_ISREG(held.before.st_mode) else 0)
                except BaseException as error:
                    primary = _seed_first(primary, error);self._failed(error)
                    try:retained(held.path, uncertain=True)
                    except BaseException as later:primary = _seed_first(primary, later);self._failed(later)
                try:held.close()
                except BaseException as error:primary = _seed_first(primary, error);self._failed(error)
            if primary is not None:raise self.failure


    def close(self, primary=None):
        failure = primary
        while self.owned:
            held = self.owned.pop()
            member, rows = None, None
            try:
                member = os.fsencode(os.path.relpath(held.path, self.root.path))
                rows = [row for row in self.work.get("C3_retained", [])
                    if row["root"] == "I" and row["member"] == member.hex()]
                held.recheck("E_STORE", self.work, "M")
                if rows:self.c._c3_retain_entity(self.work, "I", member, rows[0]["kind"], held.before,
                    size=held.before.st_size if stat.S_ISREG(held.before.st_mode) else 0)
            except BaseException as error:
                failure = _seed_first(failure, error)
                try:
                    if rows:self.c._c3_retain_entity(self.work, "I", member, rows[0]["kind"], uncertain=True)
                except BaseException as later:failure = _seed_first(failure, later)
            try:held.close()
            except BaseException as error:
                failure = _seed_first(failure, error)
                try:
                    if rows:self.c._c3_retain_entity(self.work, "I", member, rows[0]["kind"], uncertain=True)
                except BaseException as later:failure = _seed_first(failure, later)
        self.root = None
        if failure is not None:
            self._failed(failure)
            if self.failure is not primary:raise self.failure


_CASE_ROLES = ("reproduction.prepare", "reproduction.inspect", "reproduction", "write.prepare",
               "write.inspect", "write", "gate", "kill", "coverage")
_LOCAL_GROUPS = {"entropy", "clocks", "storage", "commands", "runtime"}


class _ReplayCase:
    def __init__(self, inputs, manifest_raw, descriptor_raw):
        _seed_require(type(inputs) is _ReplayInputs and inputs.failure is None)
        self.inputs, self.c, self.work = inputs, inputs.c, inputs.work
        self.mismatches, self.calculated, self.compared = [], {}, set()
        self._replay_io_holds = []
        self.work["case_manifest_parse_unknown"] = True
        manifest = self.c._json(manifest_raw, self.c.DOCUMENT_LIMIT, "E_STORE")
        inputs._account("R", len(manifest_raw), "M")
        descriptor = self.c._json(descriptor_raw, self.c.DOCUMENT_LIMIT, "E_STORE")
        inputs._account("R", len(descriptor_raw), "M")
        self.work["case_manifest_parse_unknown"] = False
        _seed_require(set(manifest) == {"case_id", "window_ref", "inventory_core", "output_bindings"}
            and set(descriptor) == {"cases", "carry_in"} and manifest["case_id"] in descriptor["cases"]
            and set(manifest["window_ref"]) == {"size_bytes", "sha256"})
        measured = hashlib.sha256(descriptor_raw).hexdigest();inputs._account("H", len(descriptor_raw), "M")
        _seed_require(manifest["window_ref"] == {"size_bytes": len(descriptor_raw), "sha256": measured})
        core = manifest["inventory_core"]
        raw = inputs.encode(core)
        measured = hashlib.sha256(raw).hexdigest();inputs._account("H", len(raw), "M")
        self.work.setdefault("seed_processing", {})["E"] = self.work.get("seed_processing", {}).get("E", 0) + len(raw) * 2
        _seed_require(descriptor["cases"][manifest["case_id"]] == {"inventory_core": core, "sha256": measured}
            and core["case_id"] == manifest["case_id"] and core["entries"] == [row for row, _held in inputs.rows.values()])
        self.manifest = manifest
        names = ("incident.json", "reproduction-request.json", "write-request.json", "gate-request.json")
        self.original_raw = {name: inputs.bytes("case", "original-input", name, self.c.DOCUMENT_LIMIT) for name in names}
        self.original = {}
        for name, raw in self.original_raw.items():
            self.work["case_original_parse_unknown"] = True
            self.work["case_original_parse_attempt_bytes"] = len(raw)
            self.original[name] = self.c._json(raw, self.c.DOCUMENT_LIMIT, "E_STORE")
            inputs._account("R", len(raw), "M")
            self.work["case_original_parse_unknown"] = False
        raw = inputs.bytes("case", "raw-observations", "raw-observations.json", self.c.DOCUMENT_LIMIT)
        self.work["case_observations_parse_unknown"] = True
        value = self.c._json(raw, self.c.DOCUMENT_LIMIT, "E_STORE");inputs._account("R", len(raw), "M")
        self.work["case_observations_parse_unknown"] = False
        _seed_require(set(value) == {"schema_version", "kind", "body"} and value["schema_version"] == 2
            and value["kind"] == "malicious_raw_observations" and set(value["body"]) == {"incident", "identities", "occurrences"})
        body = value["body"]
        ids = {role: self.original[role + "-request.json"]["id"] for role in ("reproduction", "write", "gate")}
        content = _case_v2_content({"observed_at": self.original["incident.json"]["body"]["observed_at"]},
            ids, body["identities"]["locators"], body["occurrences"])
        expected = inputs.encode(content)
        self.work["seed_processing"]["E"] = self.work["seed_processing"].get("E", 0) + len(expected) + len(raw)
        _seed_require(raw == expected and body["identities"]["attempt_ids"] == ids)
        self.occurrences = {row["role"]: row for row in body["occurrences"]}
        self.locators = body["identities"]["locators"]
        _seed_require(core["occurrences"] == [{"role": role, "binding": self.occurrences[role]["binding"]}
            for role in _CASE_ROLES if role in self.occurrences])
        facts = {name: {"size_bytes": size, "sha256": sha, "kind": inputs.rows[name][0]["kind"]}
            for name, (size, sha) in inputs.measurements.items()}
        semantic = {name: row for name, (row, _held) in inputs.rows.items()}
        bindings = {name: (row["occurrence"], row["role"], row["member"], *inputs.measurements[name], row["kind"])
            for name, row in semantic.items()}
        originals = {name: {"kind": self.original[name]["kind"], "id": self.original[name]["id"],
            "size_bytes": len(self.original_raw[name]), "sha256": inputs.measurements[name][1]} for name in names}
        rebuilt = _S_inventory_core_values(core["case_id"], facts, semantic, bindings, originals, self.occurrences)
        encoded = inputs.encode(rebuilt)
        self.work["seed_processing"]["E"] = self.work["seed_processing"].get("E", 0) + len(encoded) * 2
        _seed_require(rebuilt == core)
        original_members = {row["member"] for row in semantic.values() if row["role"] == "original-input"}
        _seed_require(set(names) | set(_SURFACE_INPUTS) | (_TRIAL_DOCUMENTS - {"gate/basis.json", "gate/claim.json"}) <= original_members
            and {"git/HEAD", "git/config"} <= original_members
            and any(member.startswith("git/objects/") for member in original_members))

    @staticmethod
    def _replay_io_first(first, later):
        cancelled = lambda error: isinstance(error, KeyboardInterrupt) or getattr(error, "_scope_signal_cancel", False)
        return later if first is None or cancelled(later) and not cancelled(first) else first

    def _replay_hold_work(self, parent):
        c = self.c
        _seed_require(type(parent) is c.HeldPath and len(parent.components) >= 2
            and self.inputs.failure is None)
        self._replay_adopt_io(parent)
        parent.recheck("E_STORE", self.work, "M")
        _seed_require(os.path.commonpath((parent.path, self.inputs.root.path))
            not in {parent.path, self.inputs.root.path})
        state = c._capture_metadata(parent.fd, self.work, "M")
        rule = c._store_rule(os.geteuid(), os.getegid(), 0o700, True, self.inputs.resolver)
        _seed_require(c._capture_rule(rule, parent.fd, state, False, self.work, "M"))
        _seed_require(not parent.listdir())
        return parent

    def _replay_adopt_io(self, held):
        # This method takes ownership at entry, including registration failure.
        if not hasattr(self, "_replay_io_holds"):
            try:self._replay_io_holds = []
            except BaseException as error:
                try:held.close()
                except BaseException as later:error = self._replay_io_first(error, later)
                raise error
        try:
            self._replay_io_holds.append(held)
            if not hasattr(self, "_replay_private_root"):
                self._replay_private_root = held.path
                self.inputs._replay_private_root = held.path
                self._replay_retained(held.path, held.before, size=0)
        except BaseException as error:
            if not any(item is held for item in self._replay_io_holds):
                try:held.close()
                except BaseException as later:error = self._replay_io_first(error, later)
            raise error
        return held

    def _replay_retained(self, path, state=None, *, size=None, uncertain=False):
        relative = os.path.relpath(str(path), self._replay_private_root)
        return self.c._c3_retain_entity(self.work, "privatework", os.fsencode(relative), "M",
            state, size=size, uncertain=uncertain)

    def _replay_close_io(self, primary=None):
        failure = primary
        owned = getattr(self, "_replay_io_holds", [])
        while owned:
            held = owned.pop()
            try:
                held.recheck("E_STORE", self.work, "M")
                self._replay_retained(held.path, held.before,
                    size=held.before.st_size if stat.S_ISREG(held.before.st_mode) else 0)
            except BaseException as error:
                failure = self._replay_io_first(failure, error)
                try:self._replay_retained(held.path, uncertain=True)
                except BaseException as later:failure = self._replay_io_first(failure, later)
            try:held.close()
            except BaseException as error:
                failure = self._replay_io_first(failure, error)
                try:self._replay_retained(held.path, uncertain=True)
                except BaseException as later:failure = self._replay_io_first(failure, later)
                try:self.work["replay_io_close_incomplete"] = True
                except BaseException as later:failure = self._replay_io_first(failure, later)
        return failure

    def _replay_io_parent(self, parent, name):
        _seed_require(type(parent) is self.c.HeldPath
            and any(item is parent for item in getattr(self, "_replay_io_holds", []))
            and self.inputs.failure is None and type(name) is str and name not in {"", ".", ".."}
            and "/" not in name and "\0" not in name)
        parent.recheck("E_STORE", self.work, "M")
        names = parent.listdir()
        _seed_require(name not in names and len(names) < 256)
        self.c._capture_copy_room(self.work, 0, False, case=True)
        self.c._capture_copy_budget_room(self.work, 0, False, files=1)
        self.c._require(self.work["files"] < 256, "E_LIMIT")
        return parent.before, set(names)

    def _replay_refresh_parent(self, parent, before, names, added):
        _seed_require(set(parent.listdir()) == names | {added})
        self.c._refresh_recording_directory(parent, before, self.work)
        index = len(parent.components) - 1
        current = parent.before
        for held in self._replay_io_holds:
            if held is parent or len(held.components) <= index:
                continue
            if os.path.commonpath((held.path, parent.path)) != parent.path:
                continue
            component = held.components[index]
            _seed_require(self.c._identity(component.before) == self.c._identity(before))
            component.before = current

    def _replay_created(self, name):
        self.work["files"] += 1
        self.c._capture_account(self.work, "M", "files", 1)
        self.c._capture_observe(self.work, "M", "replay-derived-create", {"name": name, "return": 0})

    def _replay_mkdir(self, parent, name):
        before, names = self._replay_io_parent(parent, name)
        self.work["replay_create_unknown"] = True
        try:
            os.mkdir(name, 0o700, dir_fd=parent.fd)
            self._replay_created(name)
            self._replay_retained(Path(parent.path) / name)
            self._replay_refresh_parent(parent, before, names, name)
            os.fsync(parent.fd)
            held = self.c._open_child(parent, name, True,
                self.c._store_rule(os.geteuid(), os.getegid(), 0o700, True, self.inputs.resolver),
                "E_STORE", recording_work=self.work, accounting_kind="M")
            self._replay_adopt_io(held)
            _seed_require(not held.listdir())
            held.recheck("E_STORE", self.work, "M")
            self._replay_retained(held.path, held.before)
            self.work["replay_create_unknown"] = False
            return held
        except BaseException as error:
            self.inputs._failed(error)
            raise self.inputs.failure

    def _replay_written(self, count):
        # Commit actual physical work before category/observation allocations can fail.
        failure = None
        for field in ("write_bytes", "physical_bytes", "read_bytes"):
            try:self.work[field] += count
            except BaseException as error:failure = self._replay_io_first(failure, error)
        for operation in ("W", "C"):
            try:
                values = self.work.setdefault("seed_processing", {})
                values[operation] = values.get(operation, 0) + count
            except BaseException as error:failure = self._replay_io_first(failure, error)
        for field in ("write_bytes", "physical_bytes", "read_bytes"):
            try:self.c._capture_account(self.work, "M", field, count)
            except BaseException as error:failure = self._replay_io_first(failure, error)
        if failure is not None:
            try:self.work["write_accounting_incomplete"] = True
            except BaseException as error:failure = self._replay_io_first(failure, error)
            raise failure

    def _replay_write_bytes(self, parent, name, raw):
        _seed_require(type(raw) is bytes)
        before, names = self._replay_io_parent(parent, name)
        self.c._capture_copy_room(self.work, len(raw), False, case=True)
        self.c._capture_copy_budget_room(self.work, len(raw), False, files=1)
        target, failure, written = None, None, 0
        self.work["replay_write_unknown"] = True
        try:
            target = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o400, dir_fd=parent.fd)
            self._replay_created(name)
            self._replay_retained(Path(parent.path) / name)
            while written < len(raw):
                chunk = memoryview(raw)[written:written + 65536]
                self.c._capture_copy_room(self.work, len(chunk), False, case=True)
                count = os.write(target, chunk)
                # Keep the syscall return even when subsequent accounting refuses.
                if type(count) is int and count > 0:
                    written += count
                    self._replay_written(count)
                    self._replay_retained(Path(parent.path) / name, size=written)
                self.c._capture_observe(self.work, "M", "replay-derived-write", {
                    "name": name, "return": count, "written_bytes": written})
                _seed_require(type(count) is int and 0 < count <= len(chunk))
            state = self.c._capture_metadata(target, self.work, "M")
            _seed_require(state.st_size == len(raw) and state.st_nlink == 1)
            self._replay_retained(Path(parent.path) / name, state, size=written)
            os.fsync(target)
        except BaseException as error:
            failure = error
            try:self._replay_retained(Path(parent.path) / name, size=written, uncertain=True)
            except BaseException as later:failure = self._replay_io_first(failure, later)
            try:
                self.work["replay_write_incomplete"] = True
                self.c._capture_observe(self.work, "M", "replay-derived-partial", {
                    "name": name, "written_bytes": written})
            except BaseException as later:failure = self._replay_io_first(failure, later)
        finally:
            if target is not None:
                closing, target = target, None
                try:self.c._close_capture_copy(closing, self.work, self.work, "replay-derived-write", failure)
                except BaseException as error:failure = self._replay_io_first(failure, error)
        if failure is not None:
            self.inputs._failed(failure)
            raise self.inputs.failure
        try:
            self._replay_refresh_parent(parent, before, names, name)
            os.fsync(parent.fd)
            path = self._replay_readback_bytes(parent, name, raw)
            self.work["replay_write_unknown"] = False
            return path
        except BaseException as error:
            self.inputs._failed(error)
            raise self.inputs.failure

    def _replay_readback_bytes(self, parent, name, raw):
        _seed_require(type(raw) is bytes and type(parent) is self.c.HeldPath
            and any(item is parent for item in self._replay_io_holds))
        parent.recheck("E_STORE", self.work, "M")
        try:
            held = self.c._open_child(parent, name, False,
                self.c._store_rule(os.geteuid(), os.getegid(), 0o400, False, self.inputs.resolver),
                "E_STORE", recording_work=self.work, accounting_kind="M")
            self._replay_adopt_io(held)
            _seed_require(held.before.st_size == len(raw))
            expected = hashlib.sha256(raw).hexdigest()
            self.inputs._account("H", len(raw), "M")
            measured, offset = hashlib.sha256(), 0
            self.work["replay_readback_unknown"] = True
            while offset < len(raw):
                amount = min(65536, len(raw) - offset)
                self.c._capture_copy_room(self.work, amount, False, case=True, read_only=True)
                self.work["read_calls"] = self.work.get("read_calls", 0) + 1
                chunk = os.pread(held.fd, amount, offset)
                self.inputs._account("R", len(chunk), "M")
                measured.update(chunk)
                self.inputs._account("H", len(chunk), "M")
                self.inputs._account("E", len(chunk) + amount, "M")
                _seed_require(len(chunk) == amount and chunk == memoryview(raw)[offset:offset + amount])
                offset += len(chunk)
            _seed_require(measured.hexdigest() == expected)
            held.recheck("E_STORE", self.work, "M")
            self.work["replay_readback_unknown"] = False
            return Path(held.path)
        except BaseException as error:
            self.inputs._failed(error)
            raise self.inputs.failure

    def _materializer_preparation_steps(self, runtime_root, phase, source_git, work_hold,
                                      input_raw, source_repository_id, deadline):
        import argparse

        runtime_root, private_work = Path(runtime_root), Path(work_hold.path)
        _seed_require(phase in {"reproduction", "write"} and phase not in self.calculated
            and type(source_git) is self.c.HeldPath and type(input_raw) is bytes
            and type(deadline) in (float, int)
            and (phase == "reproduction" or "reproduction" in self.calculated))
        _seed_require(runtime_root.is_absolute() and runtime_root.resolve() == runtime_root
            and private_work.is_absolute() and private_work.resolve() == private_work)
        jq = runtime_root / "bin/jq"
        _seed_require(jq.is_file() and not jq.is_symlink() and os.access(jq, os.X_OK))
        spec = importlib.util.spec_from_file_location(
            "malicious_materializer_preparation", runtime_root / "preparation/v1/prepare-candidate.py")
        p = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = p
        spec.loader.exec_module(p)
        self.work["offline_materializer_work_unknown"] = True
        self.work["accounting_incomplete"] = True
        self.source_repository(source_git)
        source_git.recheck("E_STORE", self.work, "M")
        scratch, output, candidate = (private_work / name for name in ("scratch", "output", "materialized"))
        materializer_scratch = private_work / "materializer-scratch"
        for name in ("scratch", "output", "materialized", "materializer-scratch"):
            self._replay_mkdir(work_hold, name)
        args = argparse.Namespace(operation="prepare", jq=str(jq), candidate_repository=str(candidate / "repository.git"),
            output=str(output), input=str(private_work / "input.json"), response=str(private_work / "response.json"),
            input_sha256=p.sha256(input_raw), response_sha256=None)
        ctx = p.Context(args=args, repo_root=runtime_root, scratch=scratch,
            copied_repo=candidate / "repository.git", sidecars=scratch / "sidecars", deps_root=scratch / "dependencies",
            ledger=p.Ledger(), deadline=deadline)
        _seed_require(source_repository_id == self.original["incident.json"]["body"]["target_repository_id"])
        primary = None
        try:
            for key, path, kind in (("scratch_work", scratch, "directory"), ("scratch", scratch, "directory"),
                                    ("output", output, "directory"), ("jq", jq, "file")):
                pending = p.hold_boundary(path, kind, deadline, private_leaf=kind == "directory")
                try:ctx.boundaries[key] = pending
                except BaseException as error:
                    if not any(item is pending for item in ctx.boundaries.values()):
                        try:pending.close()
                        except BaseException as later:error = _seed_first(error, later)
                    raise error
            self._replay_write_bytes(work_hold, "input.json", input_raw)
            input_doc = p.strict_json(input_raw)
            helper = private_work / "object-closure"
            _seed_require(not os.path.lexists(helper))
            helper_before, helper_names = self._replay_io_parent(work_hold, "object-closure")
            p.run_child(ctx, ["/usr/bin/cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                str(runtime_root / "adapters/local-git-materializer/v1/object-closure.c"), "-o", str(helper)],
                output_limit=p.LIMITS["invocation_diagnostic_bytes"], env=p.clean_git_env(ctx))
            self._replay_created("object-closure")
            self._replay_refresh_parent(work_hold, helper_before, helper_names, "object-closure")
            source_git.recheck("E_STORE", self.work, "M")
            response_raw = p.run_child(ctx, ["/bin/bash", "-p",
                str(runtime_root / "adapters/local-git-materializer/v1/materialize.sh"), "materialize", args.input,
                source_repository_id, source_git.path, str(candidate), str(materializer_scratch),
                str(helper), str(jq)], output_limit=p.LIMITS["response_bytes"], env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
            source_git.recheck("E_STORE", self.work, "M")
            args.response_sha256 = p.sha256(response_raw)
            self._replay_write_bytes(work_hold, "response.json", response_raw)
            pending = p.hold_boundary(Path(args.candidate_repository), "directory", deadline, private_leaf=True)
            try:ctx.boundaries["candidate_repository"] = pending
            except BaseException as error:
                if not any(item is pending for item in ctx.boundaries.values()):
                    try:pending.close()
                    except BaseException as later:error = _seed_first(error, later)
                raise error
            yield {"input_raw": input_raw, "response_raw": response_raw,
                "candidate_repository": Path(args.candidate_repository)}
            jq_copy, protocol = p.copy_dependencies(ctx)
            input_doc, response, details = p.validate_documents(ctx, input_raw, response_raw, jq_copy, protocol)
            p.initialize_storage_identity(ctx, details)
            ctx.source_facts, ctx.source_observation = p.enumerate_storage(ctx)
            receipt, directories, files = p.validate_relations(ctx, input_doc, response, details)
            inventory = p.export_candidate(ctx, output / "candidate", directories, files)
            inventory = p.measure_candidate(ctx, output / "candidate", inventory)
            source_files = {}
            for relative, fact in ctx.source_facts.items():
                fd = p.open_relative_file(ctx.boundaries["candidate_repository"].fd, relative)
                try:
                    source_files[relative] = p.read_limited(Path(args.candidate_repository) / relative,
                        fact.size, source_fd=fd, deadline=deadline)
                finally:
                    os.close(fd)
            p.recheck_source(ctx)
            outputs = []
            for operation in ("prepare", "inspect"):
                role = phase + "." + operation
                capture_raw = self.inputs.bytes(role, "preparation", "capture.json", self.c.DOCUMENT_LIMIT)
                captured, runtime_rows, _marker = _preparation_consumer_values(
                    runtime_root, capture_raw, operation, input_raw, response_raw)
                workspace = _preparation_workspace_values(runtime_root, captured["entropy"]["preparation_names"][0])
                _seed_require(_preparation_capture_values(runtime_root, capture_raw, workspace,
                    operation, input_raw, response_raw) == captured
                    and {key: captured[key] for key in _LOCAL_GROUPS}
                        == self.occurrences[role]["raw"]["preparation"])
                runtime_values = _preparation_runtime_values(runtime_root, captured["commands"]["runtime_values"][0])
                runtime_sources = {row["slot"]: self.inputs.bytes(role, "preparation", name,
                    p.LIMITS["dependency_bytes"]) for name, row in runtime_rows.items()}
                _seed_require(set(runtime_sources) == {"python", "git", "jq"}
                    and p.sha256(runtime_sources["jq"]) == ctx.identities["jq"]["executable_sha256"])
                source_values = {"component": (runtime_root / "preparation/v1/prepare-candidate.py").read_bytes(),
                                 "python": runtime_sources["python"], "git": runtime_sources["git"]}
                scans = _preparation_storage_values(runtime_root, captured["storage"], source_files, ctx.algorithm)
                _seed_require(scans and all(scan == scans[0] for scan in scans))
                manifest_raw, record_raw, complete_raw = _preparation_values(runtime_root, inventory,
                    source_values, runtime_values, ctx.identities, args.input_sha256, args.response_sha256,
                    response, details, receipt, scans[0])
                outputs.append((manifest_raw, record_raw, complete_raw))
            _seed_require(outputs[0] == outputs[1])
            candidate_bytes = []
            for entry in inventory:
                if entry["kind"] != "file":continue
                raw = p.read_limited(output / "candidate" / entry["path"], entry["size_bytes"], deadline=deadline)
                self.inputs._account("R", len(raw), "raw")
                measured = hashlib.sha256(raw).hexdigest();self.inputs._account("H", len(raw), "raw")
                _seed_require(len(raw) == entry["size_bytes"] and measured == entry["sha256"])
                candidate_bytes.append(raw)
            p.recheck_source(ctx)
            return {"input_raw": input_raw, "response_raw": response_raw,
                "candidate_bytes": candidate_bytes,
                "manifest_raw": outputs[0][0], "record_raw": outputs[0][1], "completion_raw": outputs[0][2],
                "candidate_repository": Path(args.candidate_repository), "candidate_root": output / "candidate",
                "candidate_commit_id": receipt["candidate"]["commit_id"],
                "candidate_tree_id": receipt["candidate"]["tree_id"], "inventory": inventory}
        except BaseException as error:
            primary = error
            raise
        finally:
            failure = primary
            try:
                self.work.setdefault("offline_preparation_ledgers", []).append(dict(vars(ctx.ledger)))
                self.work["offline_preparation_processing_unknown"] = True
            except BaseException as error:failure = _seed_first(failure, error)
            for boundary in reversed(list(ctx.boundaries.values())):
                try:
                    boundary.recheck()
                except BaseException as error:
                    failure = _seed_first(failure, error)
                while boundary.descriptors:
                    fd = boundary.descriptors.pop()
                    try:self.c._close_capture_copy(fd, self.work, self.work, "offline-preparation-boundary", failure)
                    except BaseException as error:failure = _seed_first(failure, error)
            if failure is not None and failure is not primary:
                raise failure

    def _materializer_preparation_body(self, runtime_root, phase, source_git, work_hold,
                                      input_raw, source_repository_id, deadline):
        stages = self._materializer_preparation_steps(runtime_root, phase, source_git,
            work_hold, input_raw, source_repository_id, deadline)
        failure, finished = None, False
        try:
            next(stages)
            try:next(stages)
            except StopIteration as completed:
                finished = True
                return completed.value
            raise ValueError("E_RELATION")
        except BaseException as error:
            failure = error
            raise
        finally:
            if not finished:
                try:stages.close()
                except BaseException as error:
                    selected = _seed_first(failure, error)
                    if selected is not failure:raise selected

    def reproduction_inputs(self, runtime_root, work_hold, prepared):
        runtime_root, private_work = Path(runtime_root), Path(work_hold.path)
        spec = importlib.util.spec_from_file_location(
            "malicious_reproduction_pipeline", runtime_root / "shadow/v1/enforced-reproduction.py")
        e = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = e
        spec.loader.exec_module(e)
        trial = self.trial("reproduction")
        incident_raw = self.original_raw["incident.json"]
        request_raw = self.original_raw["reproduction-request.json"]
        incident = e.parse(incident_raw)
        claim_raw = trial["claim.json"]
        claim = e.parse(claim_raw)
        duty_raw = trial["duty-evaluation.json"]
        identity_raw = trial["qualified-identity.json"]
        input_raw = trial["materialization-input.json"]
        input_doc = e.parse(input_raw, 8 * e.OUTPUT_LIMIT)
        e.require(input_raw == prepared["input_raw"], "E_RELATION")
        jq = runtime_root / "bin/jq"
        e.require(jq.is_file() and not jq.is_symlink() and os.access(jq, os.X_OK), "E_DEPENDENCY")
        scratch = private_work / "runtime"
        scratch = Path(self._replay_mkdir(work_hold, "runtime").path)
        env = e.clean_env(jq, scratch)
        mapped = {}
        for name, raw in (("incident", incident_raw), ("claim", claim_raw),
                          ("duty_evaluation", duty_raw), ("qualified_identity", identity_raw),
                          ("materialization_input", input_raw)):
            path = self._replay_write_bytes(work_hold, name + ".json", raw)
            mapped[name] = path
        self.work["offline_reproduction_processing_unknown"] = True
        self.work["accounting_incomplete"] = True
        incident_validator = runtime_root / "shadow/v1/validate-incident.sh"
        self._run_offline("incident-validation", ["/bin/bash", "-p", str(incident_validator),
            "validate", str(mapped["incident"])], env=env)
        registry_source_raw = (runtime_root / "core/v2/generation-registry.json").read_bytes()
        self.inputs._account("R", len(registry_source_raw), "M")
        e.require(e.SOURCE == runtime_root, "E_RUNTIME")
        modules = e.core_modules(registry_source_raw)
        protocol = runtime_root / "adapters/local-git-materializer/v1/protocol.jq"
        valid = self._run_offline("materializer-input-validation", [str(jq), "-L", str(modules),
            "-e", "--arg", "command", "validate-input", "-f", str(protocol),
            str(mapped["materialization_input"])], env=env)
        e.require(valid.strip() == b"true", "E_RELATION")
        instruction = e.make_instruction(incident)
        revision = incident["body"]["git_revision_ref"]
        identity_source = runtime_root / "shadow/v1/qualified-identity.jq"
        identity_valid = self._run_offline("qualified-identity-validation", [str(jq), "-L", str(modules),
            "-r", "--arg", "repository_id", incident["body"]["target_repository_id"],
            "--arg", "hash_algorithm", revision["hash_algorithm"], "--arg", "commit_id",
            revision["commit_id"], "-f", str(identity_source)], stdin=identity_raw, env=env)
        e.require(identity_valid == b"", "E_RELATION")
        identity = e.parse(identity_raw)
        e.validate_input_relations(input_doc, incident, claim, identity, instruction)
        response_raw = prepared["response_raw"]
        check_raw = e.response_check(input_doc, response_raw)
        check_path = self._replay_write_bytes(work_hold, "response-check.json", check_raw)
        checked = self._run_offline("materializer-response-validation", [str(jq), "-L", str(modules),
            "-e", "--arg", "command", "validate-response", "-f", str(protocol),
            str(check_path)], env=env)
        e.require(checked.strip() == b"true", "E_RELATION")
        materializer_receipt = e.require_no_change(response_raw, incident)
        return dict(trial, **{"incident.json": incident_raw,
            "request_raw": request_raw, "instruction": instruction,
            "response_raw": response_raw, "materializer_receipt": materializer_receipt,
            "manifest_raw": prepared["manifest_raw"], "record_raw": prepared["record_raw"],
            "mapped": mapped, "env": env})

    def verification_outputs(self, runtime_root, work_hold, prepared, launch_values, host_files,
                             phase="reproduction"):
        _seed_require(phase in {"reproduction", "write"})
        runtime_root, private_work = Path(runtime_root), Path(work_hold.path)
        e = sys.modules["malicious_reproduction_pipeline"]
        self.work["offline_reproduction_processing_unknown"] = True
        self.work["accounting_incomplete"] = True
        incident_raw = self.original_raw["incident.json"]
        request_raw = self.original_raw[phase + "-request.json"]
        incident, request = e.parse(incident_raw), e.parse(request_raw)
        claim_raw = launch_values["claim.json"]
        claim = e.parse(claim_raw)
        evaluation_raw = launch_values["evaluation_raw"]
        observation_raw = launch_values["observation_raw"]
        launch_raw = launch_values["launch_raw"]
        expectation_raw = launch_values["expectation_raw"]
        receipt_raw = host_files["receipt.json"]
        env = launch_values["env"]
        for name, raw in (("receipt", receipt_raw), ("expectation", expectation_raw),
                          ("evaluation", evaluation_raw), ("observation", observation_raw)):
            self._replay_write_bytes(work_hold, name + ".json", raw)
        checker_source = runtime_root / "enforcement/v1/check-sandbox-receipt.sh"
        checker_raw = self._run_offline("sandbox-receipt-check", ["/bin/bash", "-p", str(checker_source),
            "check-bound", str(private_work / "receipt.json"), str(private_work / "expectation.json"),
            str(private_work / "evaluation.json"), str(private_work / "observation.json")], env=env)
        checker = e.parse(checker_raw)
        e.require(checker["body"]["check_verdict"] == "valid"
            and checker["body"]["enforcement_verdict"] == "satisfied", "E_RELATION")
        evidence_manifest_raw = host_files["payload/evidence-manifest.json"]
        result_raw, result = e.payload_result(host_files, e.parse(evidence_manifest_raw),
            launch_values["instruction"], e.parse(prepared["manifest_raw"]), e.parse(receipt_raw))
        outcome = "no-change" if result["outcome"] == "match" else "reproduced"
        return {"sandbox-check.json": checker_raw, "file-digest-result.json": result_raw,
            "evidence-manifest.json": evidence_manifest_raw, "outcome": outcome}

    def verification_trace(self, runtime_root, work_hold, phase, launch_values, checked):
        e = sys.modules["malicious_reproduction_pipeline"]
        runtime_root = Path(runtime_root)
        incident = e.parse(self.original_raw["incident.json"])
        request = self.original[phase + "-request.json"]
        claim = e.parse(launch_values["claim.json"])
        env = launch_values["env"]
        trace_raw = e.trace_ledger(incident, request["id"], claim["id"], checked["outcome"],
            "tool.verifier", launch_values["evaluation_raw"], checked["sandbox-check.json"])
        trace_path = self._replay_write_bytes(work_hold, "trace-ledger.json", trace_raw)
        trace_validator = runtime_root / "telemetry/v1/validate-trace-ledger.sh"
        trace_receipt_raw = self._run_offline("trace-validation", ["/bin/bash", "-p", str(trace_validator),
            "validate", incident["id"], request["id"], str(trace_path)], env=env)
        return {"trace-ledger.json": trace_raw, "trace-receipt.json": trace_receipt_raw}

    def reproduction_outputs(self, runtime_root, work_hold, prepared, launch_values, host_files,
                             phase="reproduction"):
        checked = self.verification_outputs(runtime_root, work_hold, prepared, launch_values, host_files, phase)
        checked.update(self.verification_trace(runtime_root, work_hold, phase, launch_values, checked))
        return checked

    def writer_input(self, runtime_root, work_hold, source_facts, record_form):
        runtime_root, private_work = Path(runtime_root), Path(work_hold.path)
        _seed_require(record_form in {"withheld-write.v1", "withheld-write-policy.v1"}
            and "files" in self.calculated.get("reproduction", {}) and type(source_facts) is dict)
        spec = importlib.util.spec_from_file_location(
            "malicious_write_builder", runtime_root / "shadow/v1/write-shadow.py")
        w = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = w
        spec.loader.exec_module(w)
        self.work["offline_writer_builder_processing_unknown"] = True
        self.work["accounting_incomplete"] = True
        jq = runtime_root / "bin/jq"
        _seed_require(jq.is_file() and not jq.is_symlink() and os.access(jq, os.X_OK))
        frozen = dict(self.calculated["reproduction"]["files"])
        frozen["bundle.json"] = self.calculated["reproduction"]["bundle"]
        incident = w.parse(frozen["incident.json"])
        incident_id = incident["id"]
        w.require(isinstance(incident_id, str)
            and all(char in "abcdefghijklmnopqrstuvwxyz0123456789._-" for char in incident_id), "E_RELATION")
        root = "ystack-evidence/" + incident_id
        policy_raw = (runtime_root / "scope/v1/scope-policy.json").read_bytes()
        self.inputs._account("R", len(policy_raw), "M")
        policy = w.parse(policy_raw)
        mode_raw = (runtime_root / "config/construction-mode.json").read_bytes()
        self.inputs._account("R", len(mode_raw), "M")
        mode = json.loads(mode_raw)
        paths = w._write_paths_values(root, policy, mode, policy_raw,
            self.original["write-request.json"]["body"]["allowed_paths"], source_facts, record_form)
        runtime = Path(self._replay_mkdir(work_hold, "runtime").path)
        env = w.e.clean_env(jq, runtime)
        def put(name, raw):
            return self._replay_write_bytes(work_hold, name, raw)
        incident_path = put("frozen-incident.json", frozen["incident.json"])
        record_path = put("frozen-record.json", frozen["shadow-record.json"])
        seed_hold = self._replay_mkdir(work_hold, "seed")
        seed_dir, seed_before = Path(seed_hold.path), seed_hold.before
        seed_raw = self._run_offline("write-seed-conversion", ["/bin/bash", "-p",
            str(runtime_root / "maintenance/v1/incident-to-eval.sh"), "convert",
            str(incident_path), str(record_path), str(seed_dir)], env=env)
        w.require(set(os.listdir(seed_dir)) == {"eval-seed-case-stale-moved-artifacts.json"}, "E_RELATION")
        self._replay_refresh_parent(seed_hold, seed_before, set(), "eval-seed-case-stale-moved-artifacts.json")
        self._replay_readback_bytes(seed_hold, "eval-seed-case-stale-moved-artifacts.json", seed_raw)
        self.work["writer_seed_child_work_unknown"] = True
        files, patch, facts = w._write_files_values(root, frozen, seed_raw, policy_raw,
            incident["body"]["git_revision_ref"]["hash_algorithm"], record_form)
        trial = self.trial("write")
        claim_raw = trial["claim.json"]
        claim, original_claim = w.parse(claim_raw), w.parse(frozen["claim.json"])
        w.require(claim["id"] == original_claim["id"]
            and claim["body"]["policy_set_ref"] == original_claim["body"]["policy_set_ref"], "E_RELATION")
        contract = self.c.write_contract(paths, record_form)
        contract_path, patch_path = put("contract.json", contract), put("producer.patch", patch)
        metadata = {key: w.sha(value) for key, value in self.c.WRITE_TEXTS.items()}
        for key, raw in self.c.WRITE_TEXTS.items():put(key + ".txt", raw)
        metadata.update(w._write_builder_metadata_values(contract, patch, paths,
            self.original["write-request.json"], claim_raw, record_form))
        metadata["incident_id"] = w.parse(frozen["incident.json"])["id"]
        original_raw = frozen["materialization-input.json"]
        original_path = put("original-input.json", original_raw)
        modules = w.e.core_modules((runtime_root / "core/v2/generation-registry.json").read_bytes())
        builder = runtime_root / "shadow/v1/write-materialization-input.jq"
        metadata_path = put("metadata-first.json", w.canonical(metadata))
        first_raw = self._run_offline("write-materialization-input", [str(jq), "-L", str(modules),
            "-S", "-c", "--arg", "phase", "stage-request", "--rawfile", "contract", str(contract_path),
            "--rawfile", "patch", str(patch_path), "--slurpfile", "metadata", str(metadata_path),
            "-f", str(builder), str(original_path)], env=env, output_limit=8 * w.e.OUTPUT_LIMIT)
        first = w._write_builder_first_values(first_raw, original_raw)
        first_path = put("first.json", first_raw)
        stage_raw = w.canonical(first["stage_request"])
        put("stage-request.json", stage_raw)
        metadata["stage_request_sha256"] = w.sha(stage_raw)
        metadata_path = put("metadata-final.json", w.canonical(metadata))
        result_raw = self._run_offline("write-materialization-input", [str(jq), "-L", str(modules),
            "-S", "-c", "--arg", "phase", "final-input", "--rawfile", "contract", str(contract_path),
            "--rawfile", "patch", str(patch_path), "--slurpfile", "metadata", str(metadata_path),
            "-f", str(builder), str(first_path)], env=env, output_limit=8 * w.e.OUTPUT_LIMIT)
        w._write_builder_final_values(result_raw, first, stage_raw, original_raw)
        result_path = put("write-input.json", result_raw)
        checked = self._run_offline("materializer-input-validation", [str(jq), "-L", str(modules),
            "-e", "--arg", "command", "validate-input", "-f",
            str(runtime_root / "adapters/local-git-materializer/v1/protocol.jq"), str(result_path)], env=env)
        w.require(checked.strip() == b"true", "E_RELATION")
        return {"input_raw": result_raw, "files": files, "write_set": facts,
            "paths": paths, "claim_raw": claim_raw, "record_form": record_form}

    def local_slot(self, phase, slot):
        _seed_require(phase in {"reproduction", "write", "kill", "coverage"})
        rows = self.c._runtime_inventory_values(self.occurrences[phase]["raw"]["local"]["runtime"])
        selected = [(name, row) for name, row in rows.items() if row["slot"] == slot and row["index"] == 0]
        _seed_require(len(selected) == 1)
        name, declaration = selected[0]
        matches = [row for row, _held in self.inputs.rows.values()
            if row["occurrence"] == phase and row["role"] == "local-runtime"
            and row["member"].endswith("/" + name)]
        _seed_require(len(matches) == 1 and matches[0]["kind"] == "runtime"
            and matches[0]["size_bytes"] == declaration["size_bytes"]
            and matches[0]["sha256"] == declaration["sha256"])
        value = self.inputs.semantic(phase, "local-runtime", matches[0]["member"])
        _seed_require(type(value) in (bytes, tuple))
        if type(value) is tuple:
            _seed_require(all(type(chunk) is bytes and len(chunk) <= 65536 for chunk in value))
            size = sum(map(len, value))
        else:size = len(value)
        _seed_require(size == declaration["size_bytes"] and size <= self.c.EXECUTABLE_LIMIT)
        return value

    def _run_offline(self, role, argv, *, stdin=b"", timeout=120,
                     output_limit=1048576, env):
        try:
            result = self.c._c3_run_tool(str(Path(__file__).resolve().parents[2]), self.work,
                role, argv, stdin=stdin, timeout=timeout, output_limit=output_limit, env=env)
            _seed_require(result["status"] == 0 and not result["stderr"])
            return result["stdout"]
        except BaseException as error:
            self.inputs._failed(error)
            raise

    def consumer_commands(self, runtime_root, phase, input_raw, response_raw,
                          sudo_stat_values, candidate_commit_id=None, write_set=None):
        _seed_require(phase in {"reproduction", "write"})
        e = sys.modules["malicious_reproduction_pipeline"]
        local = self.occurrences[phase]["raw"]["local"]
        identity = local["storage"]["identity_context"]
        _seed_require(identity["uuid_replies"] in (None, [])
            and identity["group_replies"] in (None, []))
        locators = self.locators[phase]
        source, work = Path(locators["source_root"]), Path(locators["consumer_work"])
        request = self.original[phase + "-request.json"]
        incident = e.parse(self.original_raw["incident.json"])
        revision = incident["body"]["git_revision_ref"]
        body = request["body"]
        source_git = str(Path(body["source_git_dir"]))
        parent = self.parent_context(phase)
        python = parent["native_release"]["python_path"]
        helper, jq = str(work / "dependencies/helper/object-closure"), str(work / "dependencies/jq/jq")
        self.work["commands_processing_unknown"] = True
        self.work["accounting_incomplete"] = True
        binaries, components = {}, {}
        for slot in ("object_closure", "jq", "python", "bash", "git") if phase == "write" else (
                "object_closure", "jq", "python", "bash"):
            binaries[slot] = self.local_slot(phase, slot)
        def binary_sha(slot):
            return e._runtime_sha_values(binaries[slot], self.work)
        # DependencySnapshot.sha256 is a stored field; do not hash it per command.
        helper_sha, jq_sha = binary_sha("object_closure"), binary_sha("jq")
        _seed_require(helper_sha == parent["helper_executable_sha256"])
        def component_sha(relative):
            if relative == "sandbox/v1/host-supervisor.py":
                rows = self.c._runtime_inventory_values(self.occurrences[phase]["raw"]["capture"]["runtime"])
                names = [name for name, row in rows.items() if row["slot"] == "host_supervisor_source" and row["index"] == 0]
                _seed_require(len(names) == 1)
                raw = self.inputs.semantic(phase, "capture", phase + "/" + names[0])
                _seed_require(type(raw) in (bytes, tuple))
                size = sum(map(len, raw)) if type(raw) is tuple else len(raw)
                _seed_require(size <= self.c.EXECUTABLE_LIMIT)
                return e._runtime_sha_values(raw, self.work)
            if relative not in components:
                path = Path(runtime_root) / relative
                raw = e.read_regular(path, self.c.EXECUTABLE_LIMIT, "E_RELATION")
                self.inputs._account("R", len(raw), "M")
                components[relative] = raw
            raw = components[relative]
            value = e.sha(raw)
            self.inputs._account("H", len(raw), "M")
            return value
        registry_raw = e.read_regular(Path(runtime_root) / "core/v2/generation-registry.json",
            self.c.DOCUMENT_LIMIT, "E_RELATION")
        self.inputs._account("R", len(registry_raw), "M")
        registry = e.parse_value(registry_raw, self.c.DOCUMENT_LIMIT)
        modules = str(source / "core/v2/generations" / registry[-1]["generation_id"] / "modules")
        commands = []
        def argv_digest(argv):
            # The first encoding is an actual extra offline operation, not a fee estimate.
            raw = self.inputs.encode(argv)
            self.c._capture_copy_room(self.work, len(raw), False, case=True, read_only=True)
            result = e._command_argv_values(argv)
            self.inputs._account("C", len(raw), "M")
            self.inputs._account("E", len(raw), "M")
            self.inputs._account("H", len(raw), "M")
            return result
        recipes = []
        def F(value):
            return value, {"type": "fixed", "role": "literal", "value": value}
        def P(value, role):
            return str(value), {"type": "historical-path", "role": role}
        def D(value, kind, role):
            return value, {"type": kind, "role": role}
        def O(value, role, prefix):
            return value, {"type": "historical-path-option", "role": role, "prefix": prefix}
        def record_recipe(role, operation, operands):
            row = commands[-1]
            value = {"role": role, "executable_sha256": row["executable_sha256"],
                "component_sha256": row["component_sha256"], "operation": operation,
                "arguments": [dict(descriptor, position=position)
                    for position, (_value, descriptor) in enumerate(operands)]}
            self.work["command_recipe_processing_unknown"] = True
            self.inputs.encode(value)
            recipes.append(value)
            self.work["command_recipe_processing_unknown"] = False
        def command(role, operands, executable, component, operation):
            argv = [value for value, _descriptor in operands]
            if phase == "write" and executable == "sudo":
                argv_sha = argv_digest(argv)
                executable_sha = e._sudo_identity_values(self.c._identity_values(sudo_stat_values))
                component_digest = component_sha(component)
                commands.append(e._command_values(role, argv_sha, executable_sha, component_digest))
                record_recipe(role, operation, operands)
                return
            if executable == "jq": executable_sha = jq_sha
            elif executable == "helper": executable_sha = helper_sha
            elif executable == "sudo":
                executable_sha = e._sudo_identity_values(self.c._identity_values(sudo_stat_values))
            else: executable_sha = binary_sha(executable)
            if phase == "reproduction":
                component_digest = (parent["helper_source_sha256"] if component == "helper-source"
                    else jq_sha if component == "jq-self" else component_sha(component))
                argv_sha = argv_digest(argv)
            else:
                argv_sha = argv_digest(argv)
                component_digest = component_sha(component)
            commands.append(e._command_values(role, argv_sha, executable_sha, component_digest))
            record_recipe(role, operation, operands)
        def shell(role, relative, operation, args):
            command(role, [F("/bin/bash"), F("-p"), P(source / relative, "source_root/" + relative),
                F(operation), *args], "bash", relative, operation)
        def protocol(operation, path):
            relative = "adapters/local-git-materializer/v1/protocol.jq"
            command("materializer-" + ("input" if operation == "validate-input" else "response") + "-validation",
                [P(jq, "consumer_work/dependencies/jq/jq"), F("-L"), P(modules, "source_root/generation.modules"),
                 F("-e"), F("--arg"), F("command"), F(operation), F("-f"), P(source / relative, "source_root/" + relative), path],
                "jq", relative, operation)
        def qualified():
            relative = "shadow/v1/qualified-identity.jq"
            command("qualified-identity-validation", [P(jq, "consumer_work/dependencies/jq/jq"), F("-L"),
                P(modules, "source_root/generation.modules"), F("-r"), F("--arg"), F("repository_id"),
                D(incident["body"]["target_repository_id"], "input-id", "incident.target_repository_id"),
                F("--arg"), F("hash_algorithm"), D(revision["hash_algorithm"], "hash-algorithm", "incident.git_revision_ref.hash_algorithm"),
                F("--arg"), F("commit_id"), D(revision["commit_id"], "git-oid", "source.commit"),
                F("-f"), P(source / relative, "source_root/" + relative)], "jq", relative, "qualified-identity")
        def launch():
            config = self.local_context(phase)["config"]
            command("sandbox-launch-boundary", [F("/usr/bin/sudo"), F("-n"), F("-u"),
                ("#" + str(config["principal_uid"]), {"type": "principal", "role": "host_config.principal_uid", "prefix": "#"}), F("--"),
                P(python, "parent_context.native_release.python_path"),
                P(Path(locators["installed_anchor"]) / "host-supervisor.py", "installed_anchor/host-supervisor.py"), F("launch")],
                "sudo", "sandbox/v1/host-supervisor.py", "launch")
        preparation = "preparation/v1/prepare-candidate.py"
        def input_digest(raw):
            result = e.sha(raw)
            self.inputs._account("H", len(raw), "M")
            return result
        def W(relative):
            return P(work / relative, "consumer_work/" + relative)
        def source_repository():
            return P(source_git, "request.source_git_dir")
        def target_repository():
            return D(incident["body"]["target_repository_id"], "input-id", "incident.target_repository_id")
        def trace_ids(incident_id, attempt_id, role):
            return [D(incident_id, "input-id", "incident.id"), D(attempt_id, "request-id", role)]
        def preparation_argv(operation, common, scratch=None):
            argv = [P(python, "parent_context.native_release.python_path"), F("-I"), F("-S"), F("-B"),
                P(source / preparation, "source_root/" + preparation), F(operation), *common]
            if scratch is not None:argv.extend([F("--scratch"), W(scratch)])
            return argv
        def finish():
            self.work["command_recipe_processing_unknown"] = True
            if not hasattr(self, "command_recipes"):self.command_recipes = {}
            self.command_recipes[phase] = recipes
            self.work["command_recipe_processing_unknown"] = False
            return commands
        if phase == "reproduction":
            command("helper-version", [P(helper, "consumer_work/dependencies/helper/object-closure"), F("version")],
                "helper", "helper-source", "version")
            command("jq-version", [P(jq, "consumer_work/dependencies/jq/jq"), F("--version")], "jq", "jq-self", "version")
            mapped = {role: "inputs/" + role + "/" + role + ".json" for role in
                ("incident", "claim", "duty_evaluation", "qualified_identity", "materialization_input")}
            shell("incident-validation", "shadow/v1/validate-incident.sh", "validate", [W(mapped["incident"])])
            protocol("validate-input", W(mapped["materialization_input"]))
            qualified()
            shell("materialization", "adapters/local-git-materializer/v1/materialize.sh", "materialize",
                [W(mapped["materialization_input"]), target_repository(), source_repository(), W("candidate"), W("materializer"),
                 P(helper, "consumer_work/dependencies/helper/object-closure"), P(jq, "consumer_work/dependencies/jq/jq")])
            protocol("validate-response", W("response-check/response-check.json"))
            common = [F("--input"), W(mapped["materialization_input"]), F("--input-sha256"),
                D(input_digest(input_raw), "sha256", "materialization.input"), F("--response"), W("response/materialization-response.json"),
                F("--response-sha256"), D(input_digest(response_raw), "sha256", "materialization.response"),
                F("--candidate-repository"), W("candidate/repository.git"), F("--output"), W("preparation-parent/preparation"),
                F("--scratch"), W("preparation-scratch"), F("--jq"), P(jq, "consumer_work/dependencies/jq/jq")]
            for operation in ("prepare", "inspect"):
                command("candidate-" + ("preparation" if operation == "prepare" else "inspection"),
                    preparation_argv(operation, common), "python", preparation, operation)
            shell("sandbox-bound-evaluation", "control/v1/evaluate-bound-sandbox.sh", "evaluate",
                [W(mapped["duty_evaluation"]), W(mapped["claim"]), W("observation/observation.json")])
            launch()
            shell("sandbox-receipt-check", "enforcement/v1/check-sandbox-receipt.sh", "check-bound",
                [W("receipt/sandbox-receipt.json"), W("launch/sandbox-expectation.json"),
                 W("evaluation/sandbox-evaluation.json"), W("observation/observation.json")])
            shell("trace-validation", "telemetry/v1/validate-trace-ledger.sh", "validate",
                [*trace_ids(incident["id"], request["id"], "reproduction-request.id"), W("trace/trace-ledger.json")])
            return finish()
        _seed_require(type(candidate_commit_id) is str and type(write_set) is list)
        captures = 5 + len(e.EVIDENCE_NAMES) + 1
        git_configs = {}
        def capture(name, directory="captured"):
            nonlocal captures
            path = work / directory / name
            captures += 1
            return P(path, "consumer_work/" + directory + "/" + name)
        def git(repository, repository_role, arguments, operation):
            command("write-git-inspection", [F("/usr/bin/git"), F("--no-replace-objects"),
                O("--git-dir=" + str(repository), repository_role, "--git-dir="), *arguments],
                "git", "shadow/v1/write-shadow.py", operation)
        def inventory(repository, repository_role, commit, commit_role):
            key = str(repository)
            if key not in git_configs:
                git_configs[key] = capture("config-" + str(captures) + ".txt")
            git(repository, repository_role, [F("config"), F("--file"), git_configs[key], F("--name-only"),
                F("--list"), F("--no-includes")], "config-list")
            git(repository, repository_role, [F("rev-parse"), F("--is-bare-repository")], "is-bare-repository")
            git(repository, repository_role, [F("rev-parse"), F("--show-object-format")], "show-object-format")
            git(repository, repository_role, [F("ls-tree"), F("-r"), F("-t"), F("-z"), F("--full-tree"),
                D(commit, "git-oid", commit_role)], "ls-tree")
        def candidate_facts():
            repository, repository_role = work / "candidate/repository.git", "consumer_work/candidate/repository.git"
            inventory(repository, repository_role, candidate_commit_id, "candidate.commit")
            git(repository, repository_role, [F("cat-file"), F("commit"), D(candidate_commit_id, "git-oid", "candidate.commit")], "cat-file-commit")
            for index, row in enumerate(write_set):
                git(repository, repository_role, [F("cat-file"), F("blob"),
                    D(row["git_blob_oid"], "git-oid", "write_set[" + str(index) + "].git_blob_oid")], "cat-file-blob")
        shell("incident-validation", "shadow/v1/validate-incident.sh", "validate", [W("frozen/incident.json")])
        protocol("validate-input", W("frozen/materialization-input.json"))
        qualified()
        response_check = capture("frozen-response-check.json")
        protocol("validate-response", response_check)
        observation = capture("frozen-observation.json", "observation")
        shell("sandbox-bound-evaluation", "control/v1/evaluate-bound-sandbox.sh", "evaluate",
            [W("frozen/duty-evaluation.json"), W("frozen/claim.json"), observation])
        shell("sandbox-receipt-check", "enforcement/v1/check-sandbox-receipt.sh", "check-bound",
            [W("frozen/sandbox-receipt.json"), W("frozen/sandbox-expectation.json"), W("frozen/sandbox-evaluation.json"), observation])
        frozen_launch = self.calculated["reproduction"]["files"]["sandbox-request.json"]
        shell("trace-validation", "telemetry/v1/validate-trace-ledger.sh", "validate",
            [*trace_ids(incident["id"], e.parse(frozen_launch)["id"], "reproduction.sandbox-request.id"), W("frozen/trace-ledger.json")])
        inventory(source_git, "request.source_git_dir", revision["commit_id"], "source.commit")
        shell("write-seed-conversion", "maintenance/v1/incident-to-eval.sh", "convert",
            [W("frozen/incident.json"), W("frozen/shadow-record.json"), W("seed")])
        observation = capture("write-observation.json", "observation")
        shell("sandbox-bound-evaluation", "control/v1/evaluate-bound-sandbox.sh", "evaluate",
            [W("captured/duty_evaluation.json"), W("captured/claim.json"), observation])
        contract, patch = capture("contract.json", "builder"), capture("producer.patch", "builder")
        for key in self.c.WRITE_TEXTS:capture(key + ".txt", "builder")
        builder = "shadow/v1/write-materialization-input.jq"
        def builder_phase(name, input_path, metadata_path):
            command("write-materialization-input", [P(jq, "consumer_work/dependencies/jq/jq"), F("-L"),
                P(modules, "source_root/generation.modules"), F("-S"), F("-c"), F("--arg"), F("phase"), F(name),
                F("--rawfile"), F("contract"), contract, F("--rawfile"), F("patch"), patch, F("--slurpfile"),
                F("metadata"), metadata_path, F("-f"), P(source / builder, "source_root/" + builder), input_path],
                "jq", builder, name)
        metadata = capture("metadata-first.json", "builder")
        builder_phase("stage-request", W("frozen/materialization-input.json"), metadata)
        first = capture("first.json", "builder")
        capture("stage-request.json", "builder")
        metadata = capture("metadata-final.json", "builder")
        builder_phase("final-input", first, metadata)
        input_path = capture("write-input.json", "builder")
        protocol("validate-input", input_path)
        shell("materialization", "adapters/local-git-materializer/v1/materialize.sh", "materialize", [input_path,
            target_repository(), source_repository(), W("candidate"), W("materializer"),
            P(helper, "consumer_work/dependencies/helper/object-closure"), P(jq, "consumer_work/dependencies/jq/jq")])
        response_path = capture("response.json")
        protocol("validate-response", capture("response-check.json"))
        candidate_facts()
        common = [F("--input"), input_path, F("--input-sha256"), D(input_digest(input_raw), "sha256", "materialization.input"),
            F("--response"), response_path, F("--response-sha256"), D(input_digest(response_raw), "sha256", "materialization.response"),
            F("--candidate-repository"), W("candidate/repository.git"), F("--output"), W("preparation-parent/preparation"),
            F("--jq"), P(jq, "consumer_work/dependencies/jq/jq")]
        for operation, scratch in (("prepare", "preparation-scratch"), ("inspect", "inspection-scratch")):
            command("candidate-" + ("preparation" if operation == "prepare" else "inspection"),
                preparation_argv(operation, common, scratch), "python", preparation, operation)
        qualified()
        for name in ("write-qualified-identity.json", "write-evaluation.json", "write-origin-observation.json"):
            capture(name)
        launch()
        receipt = capture("write-receipt.json", "receipt")
        evaluation = capture("write-evaluation.json", "checks")
        observation = capture("write-verifier-observation.json", "checks")
        shell("sandbox-receipt-check", "enforcement/v1/check-sandbox-receipt.sh", "check-bound", [receipt,
            W("launch/sandbox-expectation.json"), evaluation, observation])
        for name in ("sandbox-request.json", "sandbox-expectation.json", "sandbox-receipt.json", "sandbox-check.json",
                     "origin-observation.json", "payload-stdout.txt", "payload-stderr.txt", "evidence-manifest.json",
                     "file-digest-result.json"):
            capture(name, "checks")
        inventory(source_git, "request.source_git_dir", revision["commit_id"], "source.commit")
        trace = capture("write-trace-ledger.json")
        shell("trace-validation", "telemetry/v1/validate-trace-ledger.sh", "validate",
            [*trace_ids(incident["id"], request["id"], "write-request.id"), trace])
        inventory(source_git, "request.source_git_dir", revision["commit_id"], "source.commit")
        candidate_facts()
        return finish()

    def source_repository(self, repository):
        _seed_require(type(repository) is self.c.HeldPath
            and any(item is repository for item in self._replay_io_holds))
        if not hasattr(self, "source_repositories"):self.source_repositories = []
        existing = [identity for held, identity in self.source_repositories if held is repository]
        repository.recheck("E_STORE", self.work, "M")
        if existing:
            _seed_require(len(existing) == 1 and existing[0] == self.c._identity(repository.before))
            return repository
        _seed_require(not repository.listdir())
        self.inputs.git_repository(repository)
        repository.recheck("E_STORE", self.work, "M")
        self.source_repositories.append((repository, self.c._identity(repository.before)))
        return repository

    def check_original_surface(self, repository, case):
        self.source_repository(repository)
        incident = self.original["incident.json"]
        revision = incident["body"]["git_revision_ref"]
        facts = self.git_inventory(repository, revision, "source")
        path = incident["body"]["failing_check"]["path"]
        _seed_require(path in facts and facts[path][1] == "blob")
        environment = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"}
        def read(kind, oid):
            repository.recheck("E_STORE", self.work, "M")
            raw = self._run_offline("source-git-" + kind, ["/usr/bin/git", "--no-replace-objects",
                "--git-dir=" + repository.path, "cat-file", kind, oid],
                output_limit=self.c.DOCUMENT_LIMIT, env=environment)
            repository.recheck("E_STORE", self.work, "M")
            return raw
        checked = read("blob", facts[path][2])
        commit = read("commit", revision["commit_id"])
        self.work["source_commit_parse_unknown"] = True
        pieces = commit.split(b"\n\n", 1)
        self.inputs._account("R", len(commit), "M")
        _seed_require(len(pieces) == 2)
        self.work["source_commit_parse_unknown"] = False
        self.check_surface(case, checked, pieces[1])
        return facts

    def git_inventory(self, repository, revision, phase):
        _seed_require(type(repository) is self.c.HeldPath and phase in {"source", "candidate"})
        repository.recheck("E_STORE", self.work, "M")
        raw = self._run_offline(phase + "-git-inventory", ["/usr/bin/git", "--no-replace-objects",
            "--git-dir=" + repository.path, "ls-tree", "-r", "-t", "-z", "--full-tree", revision["commit_id"]],
            output_limit=16 * self.c.DOCUMENT_LIMIT, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C",
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"})
        self.work["git_inventory_parse_unknown"] = True
        value = self.c._git_inventory_values(raw, revision)
        self.inputs._account("R", len(raw), "M")
        self.work["git_inventory_parse_unknown"] = False
        repository.recheck("E_STORE", self.work, "M")
        return value

    def writer_candidate(self, runtime_root, repository, prepared, builder, source_facts):
        w = sys.modules["malicious_write_builder"]
        incident = w.parse(self.original_raw["incident.json"])
        candidate = w._candidate_receipt_values(prepared["response_raw"], incident,
            builder["files"], builder["write_set"], builder["record_form"])
        revision = incident["body"]["git_revision_ref"]
        facts = self.git_inventory(repository, dict(revision, commit_id=candidate["commit_id"]), "candidate")
        environment = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"}
        def read(kind, oid, limit):
            repository.recheck("E_STORE", self.work, "M")
            raw = self._run_offline("candidate-git-" + kind, ["/usr/bin/git", "--no-replace-objects",
                "--git-dir=" + repository.path, "cat-file", kind, oid], output_limit=limit, env=environment)
            repository.recheck("E_STORE", self.work, "M")
            return raw
        commit = read("commit", candidate["commit_id"], w.e.OUTPUT_LIMIT)
        self.work["candidate_relation_processing_unknown"] = True
        w._candidate_relations_values(candidate, revision, facts, commit, source_facts,
            builder["files"], builder["write_set"])
        self.inputs._account("R", len(commit), "M")
        for row in builder["write_set"]:
            expected = builder["files"][row["path"]]
            raw = read("blob", row["git_blob_oid"], len(expected) + 1)
            self.inputs._account("E", 2 * (len(raw) + len(expected)), "M")
            equal = raw == expected
            valid = w._candidate_blob_values(raw, expected, row["sha256"])
            if equal:self.inputs._account("H", len(raw), "M")
            w.require(valid, "E_RELATION")
        self.work["candidate_relation_processing_unknown"] = False
        return candidate

    def parent_context(self, phase):
        _seed_require(phase in {"reproduction", "write"})
        members = {}
        prefixes = set()
        for row, _held in self.inputs.rows.values():
            if row["occurrence"] != phase or row["role"] != "parent-input":continue
            prefix, separator, name = row["member"].rpartition("/")
            _seed_require(separator and name in {"parent-frame.bin", "helper-build-record.json", "native-dependency-record.json"}
                and name not in members)
            prefixes.add(prefix)
            members[name] = self.inputs.bytes(phase, "parent-input", row["member"], self.c.PARENT_FRAME_LIMIT)
        _seed_require(set(members) == {"parent-frame.bin", "helper-build-record.json", "native-dependency-record.json"}
            and len(prefixes) == 1)
        frame = members["parent-frame.bin"]
        context_raw, records = self.c._parent_frame_values(frame)
        _seed_require(len(records) == 2)
        self.inputs._account("E", len(records[0]) + len(members["helper-build-record.json"]), "M")
        self.inputs._account("E", len(records[1]) + len(members["native-dependency-record.json"]), "M")
        _seed_require(records == (members["helper-build-record.json"], members["native-dependency-record.json"]))
        self.work["parent_context_processing_unknown"] = True
        self.work["accounting_incomplete"] = True
        context = self.c._parent_context_values(context_raw, frame, records)
        return context

    def sandbox_evaluation(self, runtime_root, work_hold, phase, trial):
        runtime_root, private_work = Path(runtime_root), Path(work_hold.path)
        _seed_require(phase in {"reproduction", "write"} and phase not in self.calculated)
        if not hasattr(self, "calculated_evaluations"):
            self.calculated_evaluations = {}
        _seed_require(phase not in self.calculated_evaluations)
        e = sys.modules["malicious_reproduction_pipeline"]
        context = self.local_context(phase)
        incident = e.parse(self.original_raw["incident.json"])
        claim = e.parse(trial["claim.json"])
        _seed_require(claim["id"] == context["config"]["environment_id"])
        entry_sha = self.c._verifier_registry_entry_sha(context["registry_entry"])
        observation_raw = self.c._verifier_observation_values(claim["id"], entry_sha,
            context["accepted"][0], incident["body"]["target_repository_id"], context["verifier_sha256"])
        self.work["sandbox_launch_processing_unknown"] = True
        self.work["accounting_incomplete"] = True
        jq = runtime_root / "bin/jq"
        _seed_require(jq.is_file() and not jq.is_symlink() and os.access(jq, os.X_OK))
        env = e.clean_env(jq, private_work)
        paths = {}
        for name, raw in (("duty", trial["duty-evaluation.json"]), ("claim", trial["claim.json"]),
                          ("observation", observation_raw)):
            paths[name] = self._replay_write_bytes(work_hold, phase + "-" + name + ".json", raw)
        evaluation_raw = self._run_offline("sandbox-bound-evaluation", ["/bin/bash", "-p",
            str(runtime_root / "control/v1/evaluate-bound-sandbox.sh"), "evaluate",
            str(paths["duty"]), str(paths["claim"]), str(paths["observation"])], env=env)
        _seed_require(e.parse(evaluation_raw)["body"]["verdict"] == "satisfied")
        controls = e._control_values(context["installed"], evaluation_raw)
        instruction = e.make_instruction(incident)
        result = {"context": context, "evaluation_raw": evaluation_raw,
            "observation_raw": observation_raw, "control": controls,
            "instruction": instruction, "env": env}
        self.calculated_evaluations[phase] = result
        return result

    def sandbox_launch(self, runtime_root, work_hold, phase, prepared, trial):
        runtime_root = Path(runtime_root)
        _seed_require(phase in {"reproduction", "write"} and phase not in self.calculated)
        e = sys.modules["malicious_reproduction_pipeline"]
        if phase not in getattr(self, "calculated_evaluations", {}):
            self.sandbox_evaluation(runtime_root, work_hold, phase, trial)
        values = self.calculated_evaluations[phase]
        context, evaluation_raw, observation_raw, controls, instruction, env = (
            values[key] for key in ("context", "evaluation_raw", "observation_raw", "control", "instruction", "env"))
        entropy_rows = self.occurrences[phase]["raw"]["local"]["entropy"][phase]
        _seed_require(type(entropy_rows) is list and len(entropy_rows) == 1)
        entropy = entropy_rows[0]
        _seed_require(type(entropy) is str and len(entropy) == 64
            and all(char in "0123456789abcdef" for char in entropy))
        request_raw = self.original_raw[phase + "-request.json"]
        launch_raw, expectation_raw = e._launch_values(request_raw, self.original_raw["incident.json"], evaluation_raw,
            observation_raw, prepared["record_raw"], prepared["manifest_raw"], instruction,
            {"context": context["launch_context"], "control": controls}, bytes.fromhex(entropy))
        self.inputs._account("C", len(launch_raw) + len(expectation_raw), "M")
        return {**trial, "evaluation_raw": evaluation_raw, "observation_raw": observation_raw,
            "launch_raw": launch_raw, "expectation_raw": expectation_raw, "instruction": instruction,
            "context": context, "env": env}

    def check_surface(self, case, checked_file_raw, commit_message_raw):
        _seed_require(type(case) is dict and case["case_id"] == self.manifest["case_id"]
            and case["family_id"] == "malicious-instructions"
            and case["case_id"] == "malicious." + case["surface"]
            and type(checked_file_raw) is bytes and type(commit_message_raw) is bytes)
        planted = self.inputs.bytes("case", "original-input", _SURFACE_INPUTS[0], self.c.DOCUMENT_LIMIT)
        forge = self.inputs.bytes("case", "original-input", _SURFACE_INPUTS[1], self.c.DOCUMENT_LIMIT)
        _seed_require(planted)
        measured = hashlib.sha256(planted).hexdigest();self.inputs._account("H", len(planted), "raw")
        _seed_require(case["planted_text_sha256"] == measured)
        symptom = self.original["incident.json"]["body"]["observed_symptom"]
        _seed_require(type(symptom) is str)
        symptom_raw = symptom.encode("utf-8");self.inputs._account("C", len(symptom_raw), "raw")
        surfaces = {"incident-symptom-text": symptom_raw, "checked-file-bytes": checked_file_raw,
            "commit-message": commit_message_raw, "unread-forge-text": forge}
        _seed_require(case["surface"] in surfaces)
        for name, raw in surfaces.items():
            self.work["surface_scan_unknown"] = True
            count = raw.count(planted)
            self.inputs._account("R", len(raw) + len(planted), "raw")
            self.work["surface_scan_unknown"] = False
            _seed_require(count == (1 if name == case["surface"] else 0))
            if name == case["surface"] and name != "unread-forge-text":
                self.work["seed_processing"]["E"] = self.work["seed_processing"].get("E", 0) + 2 * len(planted)
                _seed_require(raw.endswith(planted))
        self.surface = case["surface"]

    def guest(self, runtime_root, private_work, phase, plan_raw):
        _seed_require(phase in {"reproduction", "write"} and "export" not in self.calculated.get(phase, {}))
        occurrence = self.occurrences[phase]
        guest = occurrence["raw"]["capture"]["guest"]
        wire = _guest_wire_values(runtime_root, plan_raw, guest)
        self.inputs._account("C", len(wire), "M")
        self.work["offline_guest_helper_work_unknown"] = True
        self.work["accounting_incomplete"] = True
        frame = _guest_values(runtime_root, private_work, wire)
        self.inputs._account("R", len(frame), "raw")
        spec = importlib.util.spec_from_file_location(
            "malicious_guest_export_values", Path(runtime_root) / "sandbox/v1/host-supervisor.py")
        owner = importlib.util.module_from_spec(spec);spec.loader.exec_module(owner)
        self.work["guest_frame_parse_unknown"] = True
        records = owner.frame_read(frame)
        self.inputs._account("R", len(frame), "raw")
        self.inputs._account("H", len(frame) - 44, "raw")
        self.work["guest_frame_parse_unknown"] = False
        _seed_require(all(name != b"control-observation.json" for name, _raw in records))
        observation_raw = self.inputs.encode(guest)
        _seed_require(len(observation_raw) <= 4 * self.c.DOCUMENT_LIMIT)
        records.append((b"control-observation.json", observation_raw))
        self.work["guest_export_encode_unknown"] = True
        rebuilt = owner.frame_write(records)
        self.inputs._account("C", len(rebuilt), "raw")
        self.inputs._account("H", len(rebuilt) - 44, "raw")
        _seed_require(len(rebuilt) <= self.c.EXPORT_LIMIT)
        padding_size = self.c.EXPORT_LIMIT - len(rebuilt)
        self.c._capture_copy_room(self.work, self.c.EXPORT_LIMIT + padding_size, True, read_only=True)
        padding = b"\0" * padding_size
        self.inputs._account("C", len(padding), "export")
        exported = rebuilt + padding
        self.inputs._account("C", len(exported), "export")
        self.work["guest_export_encode_unknown"] = False
        expected = self.inputs.bytes(phase, "capture", phase + "/sandbox-export.bin", self.c.EXPORT_LIMIT)
        left = hashlib.sha256(exported).hexdigest();self.inputs._account("H", len(exported), "export")
        right = hashlib.sha256(expected).hexdigest();self.inputs._account("H", len(expected), "export")
        self.work["seed_processing"]["E"] = self.work["seed_processing"].get("E", 0) + len(exported) + len(expected)
        if exported != expected or left != right:
            self.mismatches.append("exports/" + phase + ".bin")
        self.calculated.setdefault(phase, {}).update(guest_frame=frame, export=exported)
        return exported

    def trial(self, phase):
        _seed_require(phase in {"reproduction", "write", "gate"})
        names = (("claim.json", "duty-evaluation.json", "materialization-input.json", "qualified-identity.json") if phase == "reproduction"
            else ("request-input/incident.json", "claim.json", "duty-evaluation.json", "request-input/materialization-input.json",
                "request-input/qualified-identity.json") if phase == "write"
            else ("shadow-set.json", "dashboard.json", "marker.json"))
        result = {}
        for name in names:
            member = phase + "/" + name
            maximum = (8 if name.endswith("materialization-input.json") else 1) * self.c.DOCUMENT_LIMIT
            raw = self.inputs.bytes("case", "original-input", member, maximum)
            self.work["trial_document_parse_unknown"] = True
            self.work["trial_document_parse_attempt_bytes"] = len(raw)
            self.c._json(raw, maximum, "E_STORE");self.inputs._account("R", len(raw), "M")
            self.work["trial_document_parse_unknown"] = False
            result[name] = raw
        if phase == "write":
            _seed_require("files" in self.calculated.get("reproduction", {}))
            frozen = self.calculated["reproduction"]["files"]
            for name in ("incident.json", "materialization-input.json", "qualified-identity.json"):
                member = "request-input/" + name
                self.work["seed_processing"]["E"] = self.work["seed_processing"].get("E", 0) + len(result[member]) + len(frozen[name])
                _seed_require(result[member] == frozen[name])
        if phase == "gate":
            request = self.original["gate-request.json"]
            for name, key in (("basis.json", "scope_basis"), ("claim.json", "risk_claim")):
                rebuilt = self.inputs.encode(request["body"][key])
                member = "gate/" + name
                if any(row["occurrence"] == "case" and row["role"] == "original-input" and row["member"] == member
                       for row, _held in self.inputs.rows.values()):
                    actual = self.inputs.bytes("case", "original-input", member, self.c.DOCUMENT_LIMIT)
                    self.work["seed_processing"]["E"] = self.work["seed_processing"].get("E", 0) + len(actual) + len(rebuilt)
                    _seed_require(actual == rebuilt)
                result[name] = rebuilt
        return result

    def local_context(self, phase):
        _seed_require(phase in {"reproduction", "write"})
        group = self.occurrences[phase]["raw"]["capture"]["runtime"]
        rows = self.c._runtime_inventory_values(group)
        by_slot = {}
        for name, row in rows.items():
            if row["index"] != 0:continue
            _seed_require(row["slot"] not in by_slot)
            by_slot[row["slot"]] = name
        def raw(slot, maximum):
            _seed_require(slot in by_slot)
            return self.inputs.bytes(phase, "capture", phase + "/" + by_slot[slot], maximum)
        config_raw = raw("host_config", self.c.DOCUMENT_LIMIT)
        self.work["local_context_parse_unknown"] = True
        config = self.c._parse_config(config_raw);self.inputs._account("R", len(config_raw), "M")
        self.c._runtime_account(self.work, "read_bytes", len(config_raw))
        self.c._runtime_config_binding(rows, config)
        installed = {key: raw("installed_" + key, self.c.EXECUTABLE_LIMIT)
            for key in config["installed_files"]}
        registry = self.c._parse_registry(installed["registry"])
        self.inputs._account("R", len(installed["registry"]), "M")
        self.inputs._account("H", len(installed["registry"]), "M")
        self.c._runtime_account(self.work, "read_bytes", len(installed["registry"]))
        self.c._runtime_account(self.work, "sha_bytes", len(installed["registry"]))
        accepted = self.c._parse_accepted(installed["accepted_set"])
        self.inputs._account("R", len(installed["accepted_set"]), "M")
        self.inputs._account("H", len(installed["accepted_set"]), "M")
        self.c._runtime_account(self.work, "read_bytes", len(installed["accepted_set"]))
        self.c._runtime_account(self.work, "sha_bytes", len(installed["accepted_set"]))
        self.work["local_context_parse_unknown"] = False
        selected_registry = [row for row in registry[1] if row["environment_id"] == config["environment_id"]]
        selected_accepted = [row for row in accepted[1] if row["environment_id"] == config["environment_id"]]
        _seed_require(len(selected_registry) == len(selected_accepted) == 1
            and selected_registry[0]["target_repository_id"] == self.original["incident.json"]["body"]["target_repository_id"])
        verifier_raw = raw("verifier", self.c.EXECUTABLE_LIMIT)
        verifier_sha = hashlib.sha256(verifier_raw).hexdigest();self.inputs._account("H", len(verifier_raw), "runtime")
        _seed_require(verifier_sha in selected_accepted[0]["identities"]["verifier"])
        return {"config": config, "config_raw": config_raw, "registry": registry, "accepted": accepted,
            "registry_entry": selected_registry[0], "accepted_entry": selected_accepted[0],
            "installed": installed, "verifier_raw": verifier_raw, "verifier_sha256": verifier_sha,
            "python_raw": raw("host_python", self.c.EXECUTABLE_LIMIT),
            "supervisor_raw": raw("host_supervisor_source", self.c.EXECUTABLE_LIMIT),
            "launch_context": {"environment_id": config["environment_id"], "store_id": config["store_id"],
                "registry": registry[1]}}

    def phase_b(self, runtime_root, phase, prepared, launch):
        _seed_require(phase in {"reproduction", "write"})
        spec = importlib.util.spec_from_file_location(
            "malicious_host_phase_b_values", Path(runtime_root) / "sandbox/v1/host-supervisor.py")
        h = importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
        context = launch["context"]
        request, request_body = h.parse_request(launch["launch_raw"])
        _seed_require(type(request) is dict and request_body is request["body"])
        package = {"evaluation.json": launch["evaluation_raw"], "record.json": prepared["record_raw"],
            "manifest.json": prepared["manifest_raw"], "incident.json": self.original_raw["incident.json"],
            "instruction": launch["instruction"], "candidate": prepared["candidate_bytes"]}
        installed_digests = {}
        self.work["phase_b_processing_unknown"] = True
        self.work["accounting_incomplete"] = True
        for name, raw in context["installed"].items():
            installed_digests[name] = h.sha256_hex(raw)
            self.inputs._account("H", len(raw), "runtime")
        reasons, subject, instruction_raw = h._phase_b_package_values(context["config"], request["body"],
            package, installed_digests, context["registry"][1], context["accepted"][1])
        identity = self.host_identity(runtime_root, phase, instruction_raw)
        reasons = h._phase_b_identity_values(reasons, subject, context["accepted"][1],
            identity["measured"], identity["kernel_config_raw"])
        manifest = h.parse_manifest(prepared["manifest_raw"])
        plan = None
        if not reasons:
            plan = h.build_plan_json(manifest, h.sha256_hex(instruction_raw), identity["measured"]["verifier"][1])
            self.inputs._account("C", len(plan), "M")
        result = {"reasons": reasons, "package": package, "request": request, "plan_raw": plan}
        self.calculated[phase]["admission"] = result
        return result

    def host_identity(self, runtime_root, phase, instruction_raw):
        _seed_require(phase in {"reproduction", "write"}
            and "identity" not in self.calculated.get(phase, {}))
        groups = self.occurrences[phase]["raw"]["capture"]
        rows = self.c._runtime_inventory_values(groups["runtime"])
        values = {}
        for name, row in rows.items():
            key = (row["slot"], row["index"])
            _seed_require(key not in values)
            values[key] = self.inputs.semantic(phase, "capture", phase + "/" + name)
        def bounded_bytes(value):
            if type(value) is bytes:return value
            _seed_require(type(value) is tuple and all(type(chunk) is bytes for chunk in value))
            size = sum(map(len, value))
            self.c._runtime_account(self.work, "copy_bytes", size, commit=False)
            raw = b"".join(value);self.inputs._account("C", len(raw), "runtime")
            return raw
        required = {"guest_kernel", "guest_init", "guest_supervisor", "image", "toolchain", "verifier",
            "runtime_vfkit", "runtime_driver", "vm_service", "guest_kernel_config"}
        _seed_require(all((slot, 0) in values for slot in required)
            and all((slot, 0) in values for slot in ("host_config", "host_supervisor_source", "host_python")))
        config_raw = bounded_bytes(values[("host_config", 0)])
        supervisor_raw = bounded_bytes(values[("host_supervisor_source", 0)])
        python_raw = bounded_bytes(values[("host_python", 0)])
        slots = {slot: values[(slot, 0)] for slot in required}
        slots["verifier"] = bounded_bytes(slots["verifier"])
        slots["guest_kernel_config"] = bounded_bytes(slots["guest_kernel_config"])
        dyld = sorted((index, value) for (slot, index), value in values.items() if slot == "dyld_cache_files")
        _seed_require([index for index, _value in dyld] == list(range(len(dyld))))
        slots["dyld_cache_files"] = [value for _index, value in dyld]
        self.work["host_identity_processing_unknown"] = True
        self.work["accounting_incomplete"] = True
        measured, kernel_config_raw, verifier_raw = _identity_values(runtime_root, slots, instruction_raw,
            config_raw, supervisor_raw, python_raw, groups["runtime"]["slots"])
        config = self.c._parse_config(config_raw)
        self.inputs._account("R", len(config_raw), "M")
        result = {"measured": measured, "kernel_config_raw": kernel_config_raw,
            "verifier_raw": verifier_raw, "config": config, "config_raw": config_raw}
        self.calculated.setdefault(phase, {})["identity"] = result
        return result

    def host(self, runtime_root, phase, request_raw, instruction_raw, plan_raw, manifest_raw):
        _seed_require(phase in {"reproduction", "write"} and "export" in self.calculated.get(phase, {})
            and "identity" in self.calculated[phase]
            and type(request_raw) is bytes and type(instruction_raw) is bytes and type(plan_raw) is bytes)
        groups = self.occurrences[phase]["raw"]["capture"]
        identity = self.calculated[phase]["identity"]
        config, config_raw = identity["config"], identity["config_raw"]
        measured, kernel_config_raw, verifier_raw = (identity[name]
            for name in ("measured", "kernel_config_raw", "verifier_raw"))
        request = self.c._json(request_raw, self.c.DOCUMENT_LIMIT, "E_STORE")
        self.inputs._account("R", len(request_raw), "M")
        attempt = request["body"]["attempt"]["attempt_id"]
        _seed_require(attempt == self.occurrences[phase]["binding"]["attempt_id"])
        spec = importlib.util.spec_from_file_location(
            "malicious_host_launch_values", Path(runtime_root) / "sandbox/v1/host-supervisor.py")
        owner = importlib.util.module_from_spec(spec);spec.loader.exec_module(owner)
        directory = os.path.join(config["work_root"], attempt)
        start_raw = owner._runtime_start_values(config, os.path.join(directory, "export.img"),
            os.path.join(directory, "input.img"), os.path.join(directory, "rest.sock"))
        self.inputs._account("C", len(start_raw), "M")
        admitted = [row for row in groups["clocks"]["monotonic"]
            if row["site"] == "sandbox/v1/host-supervisor.py:2794:0"]
        _seed_require(len(admitted) == 1)
        admission_mono = struct.unpack(">d", bytes.fromhex(admitted[0]["value"]))[0]
        plan_sha = hashlib.sha256(plan_raw).hexdigest();self.inputs._account("H", len(plan_raw), "M")
        run, consumed = _host_process_values(runtime_root, config, start_raw, groups["host"],
            groups["clocks"], admission_mono, self.calculated[phase]["export"], plan_sha)
        manifest = owner.parse_manifest(manifest_raw)
        self.inputs._account("R", len(manifest_raw), "M")
        _seed_require(type(manifest) is dict and type(manifest.get("entries")) is list)
        candidate_names = ["%05d" % index for index in range(
            sum(entry["kind"] == "file" for entry in manifest["entries"]))]
        self.work["host_cleanup_processing_unknown"] = True
        storage_destroyed = _host_cleanup_values(runtime_root, consumed["cleanup_rows"], candidate_names)
        self.work["accounting_incomplete"] = True
        run = _host_finalization_values(runtime_root, run, consumed)
        self.calculated[phase].update(host_run=run, host_consumed=consumed,
            storage_destroyed=storage_destroyed, config=config,
            config_raw=config_raw, measured=measured, verifier_raw=verifier_raw,
            kernel_config_raw=kernel_config_raw, start_raw=start_raw)
        return run

    def host_refused_files(self, runtime_root, phase, launch):
        import math
        values = self.calculated[phase]
        admission = values["admission"]
        _seed_require(admission["reasons"] and "identity" in values and "export" not in values)
        groups = self.occurrences[phase]["raw"]["capture"]
        _seed_require(groups["host"] == {"process": [], "driver_rest": [], "signals": []}
            and set(groups["clocks"]) == {"wall", "monotonic"})
        clocks = {}
        for kind, sites in (("wall", ("2771", "2593")), ("monotonic", ("2794",))):
            events = groups["clocks"][kind]
            _seed_require(type(events) is list and len(events) == len(sites))
            decoded = []
            for row, site in zip(events, sites):
                _seed_require(type(row) is dict and set(row) == {"site", "value"}
                    and row["site"] == "sandbox/v1/host-supervisor.py:" + site + ":0"
                    and type(row["value"]) is str and len(row["value"]) == 16
                    and all(char in "0123456789abcdef" for char in row["value"]))
                value = struct.unpack(">d", bytes.fromhex(row["value"]))[0]
                _seed_require(math.isfinite(value) and (kind != "monotonic" or value >= 0))
                decoded.append(value)
            clocks[kind] = decoded
        spec = importlib.util.spec_from_file_location("malicious_host_refusal_values",
            Path(runtime_root) / "sandbox/v1/host-supervisor.py")
        h = importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
        context = launch["context"]
        request = admission["request"]
        measured = hashlib.sha256(launch["launch_raw"]).hexdigest()
        self.inputs._account("H", len(launch["launch_raw"]), "M")
        receipt = _host_receipt_values(runtime_root, context["config"], context["accepted"][0],
            request, request["body"], measured, clocks["wall"][0], values["identity"]["measured"],
            "refused", None, True, clocks["wall"][1])
        files = {"receipt.json": receipt}
        for name, raw in h._refusal_payload_values(admission["reasons"]):files["payload/" + name] = raw
        self.inputs._account("C", sum(map(len, files.values())), "M")
        local = self.occurrences[phase]["raw"]["local"]
        identity_context = {"attempt_id": request["id"], "platform": local["storage"]["identity_context"]["platform"]}
        self.c._identity_context_values(local["storage"]["identity_context"],
            context["config"]["principal_uid"], context["config"]["consumer_gid"])
        self.work["host_origin_processing_unknown"] = True
        self.work["accounting_incomplete"] = True
        origin = _origin_values(runtime_root, files,
            [row for row in local["storage"]["entries"] if row["role"] == "store"], identity_context,
            {"host-config.json": context["config_raw"]})
        self.inputs._account("C", len(origin), "M")
        values.update(host_run=None, receipt=receipt, origin=origin, host_files=files)
        return files, origin

    def host_files(self, runtime_root, phase, launch):
        _seed_require(phase in {"reproduction", "write"})
        values = self.calculated[phase]
        admission = values["admission"]
        _seed_require(type(admission["reasons"]) is list and not admission["reasons"]
            and "host_run" in values)
        context = launch["context"]
        run, consumed = values["host_run"], values["host_consumed"]
        request = admission["request"]
        launch_sha = hashlib.sha256(launch["launch_raw"]).hexdigest()
        self.inputs._account("H", len(launch["launch_raw"]), "M")
        receipt = _host_receipt_values(runtime_root, context["config"], context["accepted"][0],
            request, request["body"], launch_sha, consumed["admitted_at"], values["identity"]["measured"],
            "admitted" if not admission["reasons"] else "refused", run,
            values["storage_destroyed"], run["terminated_at"])
        self.inputs._account("C", len(receipt), "M")
        files = {"receipt.json": receipt, "payload/stdout": run["stdout_raw"],
            "payload/stderr": run["stderr_raw"], "payload/evidence-manifest.json": run["evidence_manifest_bytes"]}
        for name, raw in run["evidence_payload"]:
            _seed_require(type(name) is str and len(name) == 4 and name.isdecimal()
                and "payload/evidence/" + name not in files)
            files["payload/evidence/" + name] = raw
        local = self.occurrences[phase]["raw"]["local"]
        self.c._identity_context_values(local["storage"]["identity_context"],
            context["config"]["principal_uid"], context["config"]["consumer_gid"])
        identity_context = {"attempt_id": request["id"], "platform": local["storage"]["identity_context"]["platform"]}
        self.work["host_origin_processing_unknown"] = True
        self.work["accounting_incomplete"] = True
        origin = _origin_values(runtime_root, files, [row for row in local["storage"]["entries"] if row["role"] == "store"], identity_context,
            {"host-config.json": context["config_raw"]})
        self.inputs._account("C", len(origin), "M")
        values.update(receipt=receipt, origin=origin, host_files=files)
        return files, origin

    def source(self, runtime_root, phase, request_raw):
        import math
        _seed_require(phase in {"kill", "coverage"} and phase in self.occurrences
            and phase not in self.calculated and type(request_raw) is bytes)
        occurrence = self.occurrences[phase]
        measured = hashlib.sha256(request_raw).hexdigest();self.inputs._account("H", len(request_raw), "M")
        _seed_require(occurrence["binding"]["request_sha256"] == measured)
        names = ("host", "config", "accepted", "package", "supervisor", "normalizer")
        configuration = {key: self.inputs.bytes(phase, "capture", "configuration/" + key,
            self.c.DOCUMENT_LIMIT) for key in names}
        groups = occurrence["raw"]["capture"]
        metadata, pages = [], []
        _seed_require(set(groups["source_pages"]) == {phase})
        rows = groups["source_pages"][phase]
        _seed_require(type(rows) is list and 1 <= len(rows) <= 128)
        for row in rows:
            _seed_require(type(row) is dict and set(row) == {"family", "page_index", "response_status",
                "input_cursor", "output_cursor", "body_hex"}
                and type(row["body_hex"]) is str and len(row["body_hex"]) <= 2 * self.c.DOCUMENT_LIMIT
                and len(row["body_hex"]) % 2 == 0
                and all(char in "0123456789abcdef" for char in row["body_hex"]))
            raw = bytes.fromhex(row["body_hex"]);self.inputs._account("C", len(raw), "raw")
            pages.append(raw);metadata.append({key: value for key, value in row.items() if key != "body_hex"})
        _seed_require(sum(map(len, pages)) <= 64 * self.c.DOCUMENT_LIMIT)
        capture = self.inputs.encode({"pages": metadata})
        records = [(b"capture.json", capture), *[(('raw/%04d' % index).encode(), raw)
            for index, raw in enumerate(pages)]]
        walls = groups["clocks"]["wall"]
        _seed_require(type(walls) is list and len(walls) == 2)
        times = []
        for row, site in zip(walls, ("3230", "3242")):
            _seed_require(row["site"] == "sandbox/v1/host-supervisor.py:" + site + ":0")
            value = struct.unpack(">d", bytes.fromhex(row["value"]))[0]
            _seed_require(math.isfinite(value) and (not times or times[-1] <= value));times.append(value)
        self.work["source_value_processing_unknown"] = True
        self.work["accounting_incomplete"] = True
        manifest, rebuilt_pages, observation, receipt = _source_values(runtime_root, request_raw,
            configuration, records, {"operation": "kill-register-read" if phase == "kill" else "coverage-read",
                "started_wall": times[0], "completed_wall": times[1]})
        result = {"receipt.json": receipt, "payload/request.json": request_raw,
            "payload/raw-manifest.json": manifest, "payload/observation.json": observation,
            **{"payload/raw/%04d" % index: raw for index, raw in enumerate(rebuilt_pages)}}
        for key in names:self.inputs.semantic(phase, "capture", "configuration/" + key)
        self.calculated[phase] = {"files": result}
        return result

    def gate_controls(self, runtime_root, work_hold):
        runtime_root, private_work = Path(runtime_root), Path(work_hold.path)
        _seed_require("files" in self.calculated.get("write", {})
            and "files" in self.calculated.get("kill", {}) and self.inputs.root is not None)
        spec = importlib.util.spec_from_file_location(
            "malicious_gate_control_pipeline", runtime_root / "scope/v1/generate-gate-evidence.py")
        g = importlib.util.module_from_spec(spec);sys.modules[spec.name] = g;spec.loader.exec_module(g)
        e = sys.modules["malicious_reproduction_pipeline"]
        request = g.generation_request(self.original_raw["gate-request.json"])
        basis, claim = request["body"]["scope_basis"], request["body"]["risk_claim"]
        references = basis["body"]["shadow_evidence_refs"]
        _seed_require(type(references) is list and references)
        current = []
        for reference in references:
            candidates = [value["files"] for phase, value in self.calculated.items()
                if phase in {"reproduction", "write"} and "files" in value
                and g.ref(value["files"]["shadow-record.json"]) == reference]
            _seed_require(len(candidates) == 1)
            current.append(candidates[0])
        self.work["offline_gate_processing_unknown"] = True
        self.work["accounting_incomplete"] = True
        tuples = []
        for files in current:
            material = g.parse(files["materialization-input.json"])
            atomic = []
            for name in ("stage_request", "resolved_profile"):
                pair = material[name]
                reference = e.pair_ref(pair)
                raw = g.c.canonical(pair["content"])
                g.require(reference == g.ref(raw))
                atomic.append(raw)
            atomic.extend((g.c.canonical(g.parse(files["materialization-response.json"])["stage_result"]),
                           files["policy-set.json"]))
            tuples.append(atomic)
        g.require(tuples and all(row == tuples[0] for row in tuples))
        g.require(g.ref(tuples[0][0]) == basis["body"]["qualified_identity"]["stage_request_ref"]
            and g.ref(tuples[0][1]) == basis["body"]["qualified_identity"]["resolved_profile_ref"])
        jq = runtime_root / "bin/jq"
        _seed_require(jq.is_file() and not jq.is_symlink() and os.access(jq, os.X_OK))
        runtime = Path(self._replay_mkdir(work_hold, "runtime").path)
        env = e.clean_env(jq, runtime)
        documents = dict(zip(("stage-request", "resolved-profile", "stage-result", "policy-set"), tuples[0]))
        documents["claim"] = g.c.canonical(claim)
        def put(name, raw):
            return self._replay_write_bytes(work_hold, name + ".json", raw)
        paths = {name: put(name, raw) for name, raw in documents.items()}
        duty = self._run_offline("gate-duty-evaluation", ["/bin/bash", "-p",
            str(runtime_root / "control/v1/evaluate-duty.sh"), "evaluate",
            *[str(paths[name]) for name in ("policy-set", "stage-request", "resolved-profile", "stage-result")]], env=env)
        paths["duty"] = put("duty", duty)
        stage_refs = {key: g.ref(documents[name]) for key, name in
            (("request_ref", "stage-request"), ("resolved_profile_ref", "resolved-profile"), ("result_ref", "stage-result"))}
        policy_set = g.parse(documents["policy-set"])
        policy_ref = {"id": policy_set["id"], "sha256": g.c.digest(documents["policy-set"])}
        g.require(g.parse(duty)["body"]["stage"] == stage_refs
            and g.parse(duty)["body"]["policy_set"] == policy_ref)
        risk = self._run_offline("gate-risk-evaluation", ["/bin/bash", "-p",
            str(runtime_root / "control/v1/evaluate-risk-gates.sh"), "evaluate",
            *[str(paths[name]) for name in ("policy-set", "stage-request", "resolved-profile", "stage-result", "duty", "claim")]], env=env)
        paths["risk"] = put("risk", risk)
        g.require(g.parse(risk)["body"]["verdict"] in {"inconclusive", "violated"}
            and g.parse(risk)["body"]["stage"] == stage_refs and g.parse(risk)["body"]["policy_set"] == policy_ref
            and g.parse(risk)["body"]["duty_evaluation_ref"] == g.ref(duty))
        observed = g.parse(self.calculated["kill"]["files"]["payload/observation.json"])
        register_raw = g.c.canonical(observed["register"])
        g.require(g.c.digest(register_raw) == observed["register_sha256"])
        state, attempt = g.project_register(register_raw, basis, g.parse(documents["stage-request"]),
            g.parse(documents["stage-result"]), duty, self.inputs.root is not None)
        paths["state"], paths["attempt"] = put("state", state), put("attempt", attempt)
        kill = self._run_offline("gate-kill-evaluation", ["/bin/bash", "-p",
            str(runtime_root / "control/v1/evaluate-kill-switch.sh"), "evaluate",
            *[str(paths[name]) for name in ("policy-set", "state", "attempt", "duty")]], env=env)
        killed = g.parse(kill)["body"]
        g.require(killed["state_ref"] == g.ref(state) and killed["attempt_ref"] == g.ref(attempt)
            and killed["duty_evaluation_ref"] == g.ref(duty))
        scope = g._scope_values(basis, duty, risk, kill)
        result = {**documents, "duty": duty, "risk": risk, "state": state,
            "attempt": attempt, "kill": kill, "scope": scope}
        self.calculated["gate_controls"] = result
        return result

    def replay_launches(self, runtime_root, work_hold, case):
        import time
        _seed_require(type(work_hold) is self.c.HeldPath and type(case) is dict
            and case["case_id"] == self.manifest["case_id"])
        self.c._require("_capture_copy_budget" in self.work
            and all(type(self.work.get(key)) is dict for key in
                ("runtime_case_carry_in", "runtime_window_carry_in")), "E_LIMIT")
        self.c._capture_copy_budget_room(self.work, 0, False)
        for key in ("runtime_case_carry_in", "runtime_window_carry_in"):
            self.c._require(all(type(self.work[key].get(field)) is int and self.work[key][field] >= 0
                for field in self.c._RUNTIME_FIELDS), "E_LIMIT")
        if not any(item is work_hold for item in self._replay_io_holds):self._replay_hold_work(work_hold)
        reproduction_work = self._replay_mkdir(work_hold, "reproduction")
        source = self._replay_mkdir(reproduction_work, "source.git")
        self.check_original_surface(source, case)
        self.calculation_started = True
        runtime_root = Path(runtime_root)
        spec = importlib.util.spec_from_file_location("malicious_reproduction_pipeline",
            runtime_root / "shadow/v1/enforced-reproduction.py")
        e = importlib.util.module_from_spec(spec);sys.modules[spec.name] = e;spec.loader.exec_module(e)
        deadline = time.monotonic() + e.OVERALL_SECONDS
        reproduction = self.reproduction_phase(runtime_root, reproduction_work, source, deadline)
        self.compare_phase_outputs("reproduction")
        writer_work = self._replay_mkdir(work_hold, "write")
        writer_source = self._replay_mkdir(writer_work, "source.git")
        written = self.writer_phase(runtime_root, writer_work, writer_source, deadline)
        self.compare_phase_outputs("write")
        return {"reproduction": reproduction, "write": written}

    def compare_phase_outputs(self, phase):
        _seed_require(phase in {"reproduction", "write"} and "files" in self.calculated.get(phase, {}))
        values = self.calculated[phase]
        files = dict(values["files"], **{"bundle.json": values["bundle"]})
        record = self.c._json(files["shadow-record.json"], self.c.DOCUMENT_LIMIT, "E_STORE")
        self.inputs._account("R", len(files["shadow-record.json"]), "M")
        environment = record["body"]["environment"]["environment_id"]
        form = record["body"]["record_form"]
        bindings = [row for row in self.manifest["output_bindings"] if row["occurrence"] == phase]
        _seed_require(bindings and {row["context"] for row in bindings} == {"generator", "scope_reader"})
        identities = set()
        for binding in bindings:
            _seed_require(set(binding) == {"occurrence", "context", "role", "environment_id", "record_form", "members"}
                and binding["role"] in {"current", "qualifying"} and binding["environment_id"] == environment
                and binding["record_form"] == form)
            identity = (binding["context"], binding["role"], environment)
            _seed_require(identity not in identities);identities.add(identity)
            self.compare(phase, *identity, files)
            if phase == "write":
                prefix = "candidate/" + "/".join(identity) + "/"
                actual = {row["member"][len(prefix):]: (row["occurrence"], row["role"], row["member"])
                    for row, _held in self.inputs.rows.values() if row["occurrence"] == phase
                    and row["role"] == "recorded" and row["member"].startswith(prefix)}
                built = values["builder"]["files"]
                _seed_require(set(actual) == set(built))
                for name in sorted(built):self.compare_member(*actual[name], built[name])

    def reproduction_phase(self, runtime_root, phase_work_hold, source_git_hold, deadline):
        runtime_root = Path(runtime_root)
        phase = "reproduction"
        _seed_require(type(phase_work_hold) is self.c.HeldPath
            and type(source_git_hold) is self.c.HeldPath and phase not in self.calculated
            and runtime_root.is_absolute() and runtime_root.resolve() == runtime_root)
        if not any(held is phase_work_hold for held in getattr(self, "_replay_io_holds", [])):
            self._replay_hold_work(phase_work_hold)
        phase_work_hold.recheck("E_STORE", self.work, "M")
        source_git_hold.recheck("E_STORE", self.work, "M")
        self.source_repository(source_git_hold)
        self.work["reproduction_phase_processing_unknown"] = True
        self.work["accounting_incomplete"] = True
        trial = self.trial(phase)
        incident = self.original["incident.json"]
        materializer_work = self._replay_mkdir(phase_work_hold, "materializer")
        inputs_work = self._replay_mkdir(phase_work_hold, "inputs")
        launch_work = self._replay_mkdir(phase_work_hold, "launch")
        guest_work = self._replay_mkdir(phase_work_hold, "guest")
        outputs_work = self._replay_mkdir(phase_work_hold, "outputs")
        prepared = self._materializer_preparation_body(runtime_root, phase, source_git_hold,
            materializer_work, trial["materialization-input.json"],
            incident["body"]["target_repository_id"], deadline)
        validated = self.reproduction_inputs(runtime_root, inputs_work, prepared)
        for name in ("claim.json", "duty-evaluation.json", "materialization-input.json", "qualified-identity.json"):
            left, right = trial[name], validated[name]
            self.inputs._account("E", len(left) + len(right), "M")
            _seed_require(left == right)
        launch = self.sandbox_launch(runtime_root, launch_work, phase, prepared, validated)
        admission = self.phase_b(runtime_root, phase, prepared, launch)
        if admission["reasons"]:
            refused, _origin = self.host_refused_files(runtime_root, phase, launch)
            self.verification_outputs(runtime_root, outputs_work, prepared, launch, refused)
            raise _CalculationRefused()
        _seed_require(type(admission["plan_raw"]) is bytes)
        self.guest(runtime_root, Path(guest_work.path), phase, admission["plan_raw"])
        run = self.host(runtime_root, phase, launch["launch_raw"], launch["instruction"],
            admission["plan_raw"], prepared["manifest_raw"])
        host_files, origin_raw = self.host_files(runtime_root, phase, launch)
        checked = self.reproduction_outputs(runtime_root, outputs_work, prepared, launch, host_files)
        e = sys.modules["malicious_reproduction_pipeline"]
        installed = launch["context"]["installed"]
        files = {
            "incident.json": self.original_raw["incident.json"],
            "claim.json": validated["claim.json"],
            "duty-evaluation.json": validated["duty-evaluation.json"],
            "materialization-input.json": prepared["input_raw"],
            "materialization-response.json": prepared["response_raw"],
            "qualified-identity.json": validated["qualified-identity.json"],
            "preparation-record.json": prepared["record_raw"],
            "preparation-manifest.json": prepared["manifest_raw"],
            "sandbox-evaluation.json": launch["evaluation_raw"],
            "sandbox-request.json": launch["launch_raw"],
            "sandbox-expectation.json": launch["expectation_raw"],
            "sandbox-receipt.json": host_files["receipt.json"],
            "sandbox-check.json": checked["sandbox-check.json"],
            "origin-observation.json": origin_raw,
            "payload-stdout.txt": host_files["payload/stdout"],
            "payload-stderr.txt": host_files["payload/stderr"],
            "evidence-manifest.json": checked["evidence-manifest.json"],
            "file-digest-result.json": checked["file-digest-result.json"],
            "evaluator-driver.txt": installed["evaluator_driver"],
            "evaluator-program.txt": installed["evaluator_program"],
            "policy.json": installed["control_policy"],
            "decision.json": installed["control_decision"],
            "policy-set.json": installed["control_policy_set"],
            "accepted-identities.json": installed["accepted_set"],
            "registry.json": installed["registry"],
            "trace-ledger.json": checked["trace-ledger.json"],
            "trace-receipt.json": checked["trace-receipt.json"],
        }
        _seed_require(set(files) == set(e.EVIDENCE_NAMES) - {"consumer-provenance.json", "shadow-record.json"})
        local = self.occurrences[phase]["raw"]["local"]
        identity_context = local["storage"]["identity_context"]
        sudo_stat = self.c._sudo_storage_stat_values(local["storage"]["entries"], identity_context["platform"])
        native_context = self.parent_context(phase)
        commands = self.consumer_commands(runtime_root, phase, prepared["input_raw"],
            prepared["response_raw"], sudo_stat)
        runtime_bytes = {slot: self.local_slot(phase, slot) for slot in ("python", "jq")}
        jq_sha = e._runtime_sha_values(runtime_bytes["jq"], self.work)
        component = self.c._open_held(str(runtime_root / "shadow/v1/enforced-reproduction.py"), False,
            self.c._store_rule(os.geteuid(), os.getegid(), 0o400, False, self.inputs.resolver),
            "E_STORE", recording_work=self.work, accounting_kind="M")
        self._replay_adopt_io(component)
        _seed_require(component.before.st_size <= self.c.EXECUTABLE_LIMIT)
        self.c._capture_copy_room(self.work, 4 * component.before.st_size, False, case=True, read_only=True)
        consumer_source_raw = component.read(self.c.EXECUTABLE_LIMIT, "E_STORE", self.work)
        materialized = {"response_raw": prepared["response_raw"],
            "evaluation_raw": launch["evaluation_raw"],
            "qualified_identity_raw": validated["qualified-identity.json"]}
        context = {"request": self.original["reproduction-request.json"],
            "consumer_source_raw": consumer_source_raw, "python_raw": runtime_bytes["python"],
            "jq_sha256": jq_sha, "native_context": native_context, "commands": commands,
            "observation": launch["observation_raw"], "store_id": launch["context"]["config"]["store_id"]}
        output, bundle = self.reproduction(runtime_root, files, materialized, context)
        rebuilt_capture, completion, projection = self.capture(runtime_root, phase,
            launch["launch_raw"], launch["expectation_raw"], host_files["receipt.json"])
        _seed_require(set(output) == set(e.EVIDENCE_NAMES))
        self.calculated[phase].update(prepared=prepared, launch=launch, materialized=materialized,
            provenance_context=context, checker_files=checked, host_files=host_files, origin=origin_raw)
        return {"files": output, "bundle": bundle, "capture": rebuilt_capture,
            "completion": completion, "projection": projection, "prepared": prepared,
            "launch": launch, "host_run": run, "host_files": host_files, "origin": origin_raw}

    def writer_phase(self, runtime_root, phase_work_hold, source_git_hold, deadline):
        runtime_root = Path(runtime_root)
        phase = "write"
        _seed_require(type(phase_work_hold) is self.c.HeldPath and type(source_git_hold) is self.c.HeldPath
            and phase not in self.calculated and "files" in self.calculated.get("reproduction", {}))
        if not any(item is phase_work_hold for item in getattr(self, "_replay_io_holds", [])):
            self._replay_hold_work(phase_work_hold)
        source_git_hold.recheck("E_STORE", self.work, "M")
        _seed_require(not source_git_hold.listdir())
        self.source_repository(source_git_hold)
        self.work["writer_phase_processing_unknown"] = True
        self.work["accounting_incomplete"] = True
        frozen = dict(self.calculated["reproduction"]["files"])
        frozen["bundle.json"] = self.calculated["reproduction"]["bundle"]
        e = sys.modules["malicious_reproduction_pipeline"]
        incident = e.parse(frozen["incident.json"])
        revision = incident["body"]["git_revision_ref"]
        trial = self.trial(phase)
        source_facts = self.git_inventory(source_git_hold, revision, "source")
        evaluation_work = self._replay_mkdir(phase_work_hold, "evaluation")
        builder_work = self._replay_mkdir(phase_work_hold, "builder")
        materializer_work = self._replay_mkdir(phase_work_hold, "materializer")
        launch_work = self._replay_mkdir(phase_work_hold, "launch")
        identity_work = self._replay_mkdir(phase_work_hold, "identity")
        guest_work = self._replay_mkdir(phase_work_hold, "guest")
        outputs_work = self._replay_mkdir(phase_work_hold, "outputs")
        evaluation = self.sandbox_evaluation(runtime_root, evaluation_work, phase, trial)
        spec = importlib.util.spec_from_file_location("malicious_write_builder",
            runtime_root / "shadow/v1/write-shadow.py")
        w = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = w
        spec.loader.exec_module(w)
        policy_raw = w.e.read_regular(runtime_root / "scope/v1/scope-policy.json", w.e.OUTPUT_LIMIT)
        mode_raw = w.e.read_regular(runtime_root / "config/construction-mode.json", w.e.OUTPUT_LIMIT)
        self.inputs._account("R", len(policy_raw) + len(mode_raw), "M")
        policy, mode = w.parse(policy_raw), json.loads(mode_raw)
        root = "ystack-evidence/" + incident["id"]
        forms = []
        for form in ("withheld-write.v1", "withheld-write-policy.v1"):
            try:
                w._write_paths_values(root, policy, mode, policy_raw,
                    self.original["write-request.json"]["body"]["allowed_paths"], source_facts, form)
            except w.e.Refusal as error:
                if error.code != "E_RELATION":raise
            else:
                forms.append(form)
        _seed_require(len(forms) == 1)
        record_form = forms[0]
        builder = self.writer_input(runtime_root, builder_work, source_facts, record_form)
        w = sys.modules["malicious_write_builder"]
        stages = self._materializer_preparation_steps(runtime_root, phase, source_git_hold, materializer_work,
            builder["input_raw"], incident["body"]["target_repository_id"], deadline)
        stage_failure, stages_finished = None, False
        try:
            materialized_stage = next(stages)
            response_check = e.response_check(w.parse(builder["input_raw"], 8 * e.OUTPUT_LIMIT),
                materialized_stage["response_raw"])
            response_check_path = self._replay_write_bytes(materializer_work, "writer-response-check.json", response_check)
            registry_raw = e.read_regular(runtime_root / "core/v2/generation-registry.json", e.OUTPUT_LIMIT)
            self.inputs._account("R", len(registry_raw), "M")
            modules = e.core_modules(registry_raw)
            checked_response = self._run_offline("materializer-response-validation", [str(runtime_root / "bin/jq"),
                "-L", str(modules), "-e", "--arg", "command", "validate-response", "-f",
                str(runtime_root / "adapters/local-git-materializer/v1/protocol.jq"), str(response_check_path)],
                env=evaluation["env"])
            w.require(checked_response.strip() == b"true", "E_RELATION")
            repository = self.c._open_held(str(materialized_stage["candidate_repository"]), True,
                self.c._store_rule(os.geteuid(), os.getegid(), 0o700, True, self.inputs.resolver),
                "E_STORE", recording_work=self.work, accounting_kind="M")
            self._replay_adopt_io(repository)
            candidate = self.writer_candidate(runtime_root, repository, materialized_stage, builder, source_facts)
            try:next(stages)
            except StopIteration as completed:
                prepared = completed.value
                stages_finished = True
            else:raise ValueError("E_RELATION")
        except BaseException as error:
            stage_failure = error
            raise
        finally:
            if not stages_finished:
                try:stages.close()
                except BaseException as error:
                    selected = _seed_first(stage_failure, error)
                    if selected is not stage_failure:raise selected
        _seed_require(candidate["commit_id"] == prepared["candidate_commit_id"]
            and candidate["tree_id"] == prepared["candidate_tree_id"])
        identity_raw = w._write_identity_values(frozen["qualified-identity.json"], builder["input_raw"],
            evaluation["instruction"], self.original["write-request.json"]["id"])
        self._replay_write_bytes(identity_work, "write-qualified-identity.json", identity_raw)
        jq = runtime_root / "bin/jq"
        registry_raw = w.e.read_regular(runtime_root / "core/v2/generation-registry.json", w.e.OUTPUT_LIMIT)
        self.inputs._account("R", len(registry_raw), "M")
        modules = w.e.core_modules(registry_raw)
        validated_identity = self._run_offline("qualified-identity-validation", [str(jq), "-L", str(modules),
            "-r", "--arg", "repository_id", incident["body"]["target_repository_id"],
            "--arg", "hash_algorithm", revision["hash_algorithm"], "--arg", "commit_id", revision["commit_id"],
            "-f", str(runtime_root / "shadow/v1/qualified-identity.jq")],
            stdin=identity_raw, env=evaluation["env"])
        w.require(validated_identity == b"", "E_RELATION")
        launch_trial = {**trial, "qualified-identity.json": identity_raw,
            "materialization-input.json": prepared["input_raw"]}
        launch = self.sandbox_launch(runtime_root, launch_work, phase, prepared, launch_trial)
        admission = self.phase_b(runtime_root, phase, prepared, launch)
        if admission["reasons"]:
            refused, _origin = self.host_refused_files(runtime_root, phase, launch)
            self.verification_outputs(runtime_root, outputs_work, prepared, launch, refused, phase=phase)
            raise _CalculationRefused()
        self.guest(runtime_root, Path(guest_work.path), phase, admission["plan_raw"])
        run = self.host(runtime_root, phase, launch["launch_raw"], launch["instruction"],
            admission["plan_raw"], prepared["manifest_raw"])
        host_files, origin_raw = self.host_files(runtime_root, phase, launch)
        checked = self.verification_outputs(runtime_root, outputs_work, prepared, launch, host_files, phase=phase)
        _seed_require(self.git_inventory(source_git_hold, revision, "source") == source_facts)
        checked.update(self.verification_trace(runtime_root, outputs_work, phase, launch, checked))
        files = {name: frozen[name] for name in e.EVIDENCE_NAMES}
        files.update({"claim.json": builder["claim_raw"], "duty-evaluation.json": trial["duty-evaluation.json"],
            "materialization-input.json": prepared["input_raw"], "materialization-response.json": prepared["response_raw"],
            "preparation-record.json": prepared["record_raw"], "preparation-manifest.json": prepared["manifest_raw"],
            "qualified-identity.json": identity_raw, "sandbox-evaluation.json": launch["evaluation_raw"],
            "sandbox-request.json": launch["launch_raw"], "sandbox-expectation.json": launch["expectation_raw"],
            "sandbox-receipt.json": host_files["receipt.json"], "sandbox-check.json": checked["sandbox-check.json"],
            "origin-observation.json": origin_raw, "payload-stdout.txt": host_files["payload/stdout"],
            "payload-stderr.txt": host_files["payload/stderr"], "evidence-manifest.json": checked["evidence-manifest.json"],
            "file-digest-result.json": checked["file-digest-result.json"], "trace-ledger.json": checked["trace-ledger.json"],
            "trace-receipt.json": checked["trace-receipt.json"]})
        scope_policy_raw = builder["files"][root + "/scope-policy.json"] if record_form == "withheld-write-policy.v1" else None
        if record_form == "withheld-write-policy.v1":files["scope-policy.json"] = scope_policy_raw
        _seed_require(self.git_inventory(source_git_hold, revision, "source") == source_facts)
        repeated_candidate = self.writer_candidate(runtime_root, repository, prepared, builder, source_facts)
        _seed_require(repeated_candidate == candidate)
        local = self.occurrences[phase]["raw"]["local"]
        sudo_stat = self.c._sudo_storage_stat_values(local["storage"]["entries"],
            local["storage"]["identity_context"]["platform"])
        parent = self.parent_context(phase)
        commands = self.consumer_commands(runtime_root, phase, prepared["input_raw"], prepared["response_raw"],
            sudo_stat, candidate["commit_id"], builder["write_set"])
        binaries = {slot: self.local_slot(phase, slot) for slot in ("python", "jq")}
        source = self.c._open_held(str(runtime_root / "shadow/v1/write-shadow.py"), False,
            self.c._store_rule(os.geteuid(), os.getegid(), 0o400, False, self.inputs.resolver),
            "E_STORE", recording_work=self.work, accounting_kind="M")
        self._replay_adopt_io(source)
        _seed_require(source.before.st_size <= self.c.EXECUTABLE_LIMIT)
        self.c._capture_copy_room(self.work, 4 * source.before.st_size, False, case=True, read_only=True)
        consumer_raw = source.read(self.c.EXECUTABLE_LIMIT, "E_STORE", self.work)
        consumer_sha = w.sha(consumer_raw)
        python_sha = e._runtime_sha_values(binaries["python"], self.work)
        jq_sha = e._runtime_sha_values(binaries["jq"], self.work)
        self.inputs._account("H", len(consumer_raw), "M")
        materialized = {"input_raw": prepared["input_raw"], "response_raw": prepared["response_raw"],
            "evaluation_raw": launch["evaluation_raw"], "qualified_identity_raw": identity_raw,
            "candidate_tree_id": candidate["tree_id"], "write_set": builder["write_set"], "files": builder["files"]}
        context = {"request": self.original["write-request.json"], "record_form": record_form,
            "scope_policy_raw": scope_policy_raw, "store_id": launch["context"]["config"]["store_id"],
            "parent": parent, "consumer_sha256": consumer_sha, "python_sha256": python_sha,
            "jq_sha256": jq_sha, "native_context": parent, "commands": commands,
            "observation": launch["observation_raw"], "trace": checked["trace-ledger.json"]}
        output, bundle, publisher_admission = self.write(runtime_root, files, materialized, context)
        capture, completion, projection = self.capture(runtime_root, phase, launch["launch_raw"],
            launch["expectation_raw"], host_files["receipt.json"])
        self.calculated[phase].update(prepared=prepared, builder=builder, launch=launch,
            materialized=materialized, provenance_context=context, publisher_admission=publisher_admission,
            source_facts=source_facts, candidate=candidate)
        return {"files": output, "bundle": bundle, "publisher_admission": publisher_admission,
            "capture": capture, "completion": completion, "projection": projection,
            "prepared": prepared, "builder": builder, "launch": launch, "host_run": run,
            "host_files": host_files, "origin": origin_raw, "source_facts": source_facts, "candidate": candidate}

    def gate_outputs(self, runtime_root, initial, scope_result, evaluation_raw):
        g = sys.modules["malicious_gate_control_pipeline"]
        _seed_require(Path(g.__file__).absolute() == Path(runtime_root) / "scope/v1/generate-gate-evidence.py"
            and type(initial) is dict and type(scope_result) is dict and type(evaluation_raw) is bytes)
        self.work["gate_output_processing_unknown"] = True
        self.work["accounting_incomplete"] = True
        objects = initial["objects"]
        initial_names = ("request", "shadow-set", "dashboard", "marker", "basis", "claim",
            "stage-request", "resolved-profile", "stage-result", "policy-set", "initial-origins", "runtime",
            "kill-configuration", "kill-request", "kill-expectation")
        _seed_require(type(objects) is dict and set(objects) == set(initial_names))
        request = g.generation_request(objects["request"])
        _seed_require(initial["request"] == request)
        identity = request["id"]
        controls = self.calculated["gate_controls"]
        control_names = ("stage-request", "resolved-profile", "stage-result", "policy-set", "claim",
            "duty", "risk", "state", "attempt", "kill", "scope")
        _seed_require(type(controls) is dict and set(controls) == set(control_names))
        output = {}
        def equal(left, right):
            _seed_require(self._scope_data_equal(left, right))
        def digest(raw):
            return self._scope_data_sha(raw, "runtime" if type(raw) is tuple else "M")
        def reference(raw):
            value = g.ref(raw)
            self.inputs._account("H", len(raw), "M")
            return value
        def render(value):
            raw = self.inputs.encode(value)
            _seed_require(len(raw) <= self.c.DOCUMENT_LIMIT)
            return raw
        def add(name, raw, document=False):
            _seed_require(type(name) is str and name and not name.startswith("/")
                and "\0" not in name and all(piece not in {"", ".", ".."} for piece in name.split("/"))
                and name not in output and type(raw) in {bytes, tuple})
            if document:_seed_require(type(raw) is bytes and len(raw) <= self.c.DOCUMENT_LIMIT)
            _seed_require(len(output) < 256)
            output[name] = raw
        def put(name, raw):
            add("objects/" + name + "/value.json", raw, True)
        for name in ("request", "shadow-set", "dashboard", "marker", "basis", "claim"):
            put(name, objects[name])
        equal(objects["basis"], render(request["body"]["scope_basis"]))
        equal(objects["claim"], render(request["body"]["risk_claim"]))
        for name in ("stage-request", "resolved-profile", "stage-result", "policy-set"):
            equal(objects[name], controls[name])
            put(name, objects[name])
        equal(objects["claim"], controls["claim"])
        initial_origins = g.parse(objects["initial-origins"])
        _seed_require(set(initial_origins) == {"schema_version", "kind", "id", "body"}
            and initial_origins["schema_version"] == 1 and initial_origins["kind"] == "gate_initial_origins"
            and initial_origins["id"] == identity
            and set(initial_origins["body"]) == {"origins", "observations"}
            and initial_origins["body"]["origins"] == initial["initial_origin_refs"])
        for name in ("initial-origins", "runtime", "kill-configuration", "kill-request", "kill-expectation"):
            put(name, objects[name])
        kill_source = self.calculated["kill"]
        _seed_require(type(kill_source["files"]) is dict)
        observed = g.parse(kill_source["files"]["payload/observation.json"])
        register_raw = render(observed["register"])
        _seed_require(digest(register_raw) == observed["register_sha256"])
        put("register", register_raw)
        for name in ("duty", "risk", "state", "attempt", "kill", "scope"):
            put(name, controls[name])
        coverage_request_raw = scope_result["coverage_request_raw"]
        coverage_expectation_raw = scope_result["coverage_expectation_raw"]
        _seed_require((coverage_request_raw is None) == (coverage_expectation_raw is None))
        if coverage_request_raw is not None:
            _seed_require(type(coverage_request_raw) is bytes and type(coverage_expectation_raw) is bytes
                and "coverage" in self.calculated)
            put("coverage-request", coverage_request_raw)
            put("coverage-expectation", coverage_expectation_raw)
        else:
            _seed_require("coverage" not in self.calculated)
        evaluation = g.parse(evaluation_raw)
        _seed_require(evaluation["kind"] == "scope_qualification_evaluation"
            and evaluation["body"]["scope_ref"] == reference(controls["scope"])
            and evaluation["body"]["authority"] == "none" and evaluation["body"]["enabled"] is False)
        put("scope-evaluation", evaluation_raw)
        put("final-origins", render(g.envelope("gate_final_origins", identity,
            {"origins": scope_result["final_origin_refs"],
             "observations": g._origins_values(scope_result["observations"])})))
        put("commands", render(g.envelope("gate_driver_commands", identity,
            {"commands": scope_result["commands"], "argv": scope_result["argv"]})))
        phases = ("kill", "coverage") if coverage_request_raw is not None else ("kill",)
        for phase in phases:
            source = self.calculated[phase]
            if "origin" not in source:
                raise NotImplementedError("gate source origin not reconstructed: " + phase)
            snapshots, origin_raw = source["files"], source["origin"]
            _seed_require(type(snapshots) is dict and type(origin_raw) is bytes)
            source_request = objects["kill-request"] if phase == "kill" else coverage_request_raw
            equal(snapshots["payload/request.json"], source_request)
            source_files = sorted((filename, raw) for filename, raw in snapshots.items() if filename != "capture.json")
            _seed_require(len(source_files) <= 132
                and all(type(filename) is str and type(raw) is bytes for filename, raw in source_files))
            name = phase + "-evidence"
            rows = [{"name": filename, "output": "objects/" + name + "/raw-%04d/value.raw" % index,
                     "size_bytes": len(raw), "sha256": digest(raw)}
                    for index, (filename, raw) in enumerate(source_files)]
            put(name, render(g.envelope("gate_source_evidence", identity,
                {"origin_ref": reference(origin_raw), "files": rows})))
            for row, (_filename, raw) in zip(rows, source_files):
                add(row["output"], raw)
        for values in (initial["output_files"], scope_result["output_files"]):
            _seed_require(type(values) is dict)
            for name, raw in values.items():
                _seed_require(name.startswith("private/"))
                if name in output:equal(output[name], raw)
                else:add(name, raw)
        rows = [{"name": name, "size_bytes": self._scope_data_size(output[name]), "sha256": digest(output[name])}
            for name in sorted(output, key=Path)]
        manifest = g._manifest_values(identity, rows, initial["initial_origin_refs"],
            scope_result["final_origin_refs"], objects["kill-request"], coverage_request_raw, self.work)
        add("manifests/manifest.json", manifest, True)
        completion = g._completion_values(identity, manifest, self.work)
        add("completion/COMPLETE.json", completion, True)
        recorded = [row["member"][len("generator/"):] for row, _held in self.inputs.rows.values()
            if row["occurrence"] == "gate" and row["role"] == "recorded" and row["member"].startswith("generator/")]
        _seed_require(1 <= len(recorded) <= 256 and len(set(recorded)) == len(recorded)
            and set(recorded) == set(output))
        for name, raw in sorted(output.items()):
            self._scope_compare_output_member("generator/" + name, raw)
        result = {"files": output, "manifest_raw": manifest, "completion_raw": completion,
            "scope_evaluation_raw": evaluation_raw}
        self.calculated["gate_outputs"] = result
        return result

    def capture(self, runtime_root, phase, request_raw, expectation_raw, receipt_raw):
        _seed_require(phase in {"reproduction", "write"} and phase in self.calculated)
        outer_raw = self.original_raw[phase + "-request.json"]
        occurrence = self.occurrences[phase]
        digest = hashlib.sha256(request_raw).hexdigest();self.inputs._account("H", len(request_raw), "M")
        _seed_require(occurrence["binding"]["request_sha256"] == digest)
        capture = self.c._capture_envelope_values(occurrence["binding"]["attempt_id"], request_raw,
            occurrence["raw"]["capture"])
        self.inputs._account("C", len(capture), "M")
        rebuilt, projected = _capture_projection_values(runtime_root, capture, occurrence["raw"]["capture"],
            outer_raw, request_raw, expectation_raw, receipt_raw,
            "shadow_enforced_request" if phase == "reproduction" else "shadow_write_request")
        self.inputs._account("E", len(capture) + len(rebuilt), "M")
        completion = _capture_completion_values(runtime_root, occurrence["binding"]["attempt_id"], request_raw, rebuilt)
        self.inputs._account("C", len(completion), "W")
        self.calculated[phase].update(capture=rebuilt, completion=completion, projection=projected, receipt=receipt_raw)
        return rebuilt, completion, projected

    def compare(self, occurrence, context, role, environment, files):
        _seed_require(type(files) is dict)
        matches = [binding for binding in self.manifest["output_bindings"]
            if (binding["occurrence"], binding["context"], binding["role"], binding["environment_id"])
                == (occurrence, context, role, environment)]
        _seed_require(len(matches) == 1 and set(files) == set(matches[0]["members"]))
        for name, physical in sorted(matches[0]["members"].items()):
            _seed_require(physical not in self.compared and type(files[name]) is bytes)
            row, held = self.inputs.rows[physical]
            held.recheck("E_STORE", self.work, "M")
            actual = self.inputs.bytes(row["occurrence"], row["role"], row["member"], 64 * self.c.DOCUMENT_LIMIT)
            left = hashlib.sha256(files[name]).hexdigest();self.inputs._account("H", len(files[name]), "raw")
            right = hashlib.sha256(actual).hexdigest();self.inputs._account("H", len(actual), "raw")
            self.work["seed_processing"]["E"] = self.work["seed_processing"].get("E", 0) + len(actual) + len(files[name])
            if files[name] != actual or left != right:self.mismatches.append(physical)
            self.compared.add(physical)
            held.recheck("E_STORE", self.work, "M")

    def reproduction(self, runtime_root, files, materialized, context):
        _seed_require("reproduction" in self.calculated and "files" not in self.calculated["reproduction"])
        _seed_require(files["incident.json"] == self.original_raw["incident.json"]
            and files["sandbox-receipt.json"] == self.calculated["reproduction"]["receipt"])
        result, bundle = _reproduction_values(runtime_root, files, materialized, context, runtime_work=self.work)
        self.calculated["reproduction"].update(files=result, bundle=bundle)
        return result, bundle

    def write(self, runtime_root, files, materialized, context):
        _seed_require("reproduction" in self.calculated and "files" in self.calculated["reproduction"]
            and "write" in self.calculated and "files" not in self.calculated["write"])
        frozen = dict(self.calculated["reproduction"]["files"])
        frozen["bundle.json"] = self.calculated["reproduction"]["bundle"]
        _seed_require(files["sandbox-receipt.json"] == self.calculated["write"]["receipt"])
        result, bundle, admission = _writer_values(runtime_root, frozen, files, materialized, context)
        self.calculated["write"].update(files=result, bundle=bundle, admission=admission)
        return result, bundle, admission

    def compare_member(self, occurrence, role, member, raw):
        _seed_require(type(raw) is bytes)
        matches = [(name, row, held) for name, (row, held) in self.inputs.rows.items()
            if (row["occurrence"], row["role"], row["member"]) == (occurrence, role, member)]
        _seed_require(len(matches) == 1)
        name, row, held = matches[0]
        _seed_require(name not in self.compared and row["kind"] in {"recorded", "raw", "M", "W"})
        expected = self.inputs.bytes(occurrence, role, member, 64 * self.c.DOCUMENT_LIMIT)
        measured = hashlib.sha256(raw).hexdigest();self.inputs._account("H", len(raw), row["kind"])
        original = hashlib.sha256(expected).hexdigest();self.inputs._account("H", len(expected), row["kind"])
        self.work["seed_processing"]["E"] = self.work["seed_processing"].get("E", 0) + len(raw) + len(expected)
        if raw != expected or measured != original:self.mismatches.append(name)
        self.compared.add(name)
        held.recheck("E_STORE", self.work, "M")

    def close(self, primary=None):
        failure = self._replay_close_io(primary)
        try:self.inputs.close(failure)
        except BaseException as error:failure = self._replay_io_first(failure, error)
        if failure is not None:raise failure

    def _scope_acquisition_origin_body(self, context, snapshots, attempt_id):
        _seed_require(context in {"generator", "scope_reader"})
        state = self.calculated["scope_contexts"][context]
        r = state["modules"]["reader"];c = r.c
        ctx = state["context"]
        original_context = self.occurrences["gate"]["raw"][context]
        _seed_require(state["cursor"] < len(state["groups"]))
        group = state["groups"][state["cursor"]];state["cursor"] += 1
        r.require(not group["capture"] and group["attempt_id"] == attempt_id)
        ancestors = r._scope_storage_chains_values(group["ancestors"], group["rows"], ctx["config"]["store_root"])
        origin = c._origin_values(snapshots, group["rows"], {"attempt_id": attempt_id,
            "platform": original_context["storage"]["identity_context"]["platform"]}, {"host-config.json": ctx["config_raw"]})
        key = (ctx["config"]["store_id"], attempt_id)
        binding = c._gate_store_binding_values(ctx["config"]["store_id"], attempt_id, origin, snapshots, ancestors)
        stable = {name: value for name, value in binding.items() if name != "origin_ref"}
        r.require(key not in state["bindings"] or r.same(state["bindings"][key], stable))
        state["bindings"][key] = stable
        state["fresh"][key] = (origin, snapshots, binding)
        state["last_source_group"] = group
        return origin

    def _scope_append_command_body(self, context, role, argv, executable, component, operation, annotations):
        state = self.calculated["scope_contexts"][context]
        r = state["modules"]["reader"];e = sys.modules["malicious_reproduction_pipeline"]
        concrete = {"role": role, "argv": argv, "executable_sha256": executable, "component_sha256": component}
        state["argv"].append(concrete)
        encoded = self.inputs.encode(argv)
        sha = e._command_argv_values(argv)
        self.inputs._account("C", len(encoded), "M");self.inputs._account("E", len(encoded), "M");self.inputs._account("H", len(encoded), "M")
        state["commands"].append(e._command_values(role, sha, executable, component))
        recipe = r._scope_command_recipe_values(role, executable, component, operation, annotations)
        self.inputs.encode(recipe);state["command_recipe"].append(recipe)
        return concrete

    def _scope_authenticate_body(self, runtime_root, work_hold, source_git_hold, context, scope_raw, current_only):
        import fnmatch
        runtime_root = Path(runtime_root)
        _seed_require(context in {"generator", "scope_reader"} and type(scope_raw) is bytes
            and type(source_git_hold) is self.c.HeldPath and type(work_hold) is self.c.HeldPath)
        modules = {}
        for label, relative in (("reader", "scope/v1/read-shadow-evidence.py"),
                                ("generator", "scope/v1/generate-gate-evidence.py"),
                                ("writer", "shadow/v1/write-shadow.py")):
            spec = importlib.util.spec_from_file_location("malicious_scope_" + label, runtime_root / relative)
            value = importlib.util.module_from_spec(spec);sys.modules[spec.name] = value;spec.loader.exec_module(value)
            _seed_require(Path(value.__file__).absolute() == runtime_root / relative)
            modules[label] = value
        r, g, w = modules["reader"], modules["generator"], modules["writer"]
        c, e = r.c, w.e
        self.work["scope_relation_processing_unknown"] = True
        self.work["accounting_incomplete"] = True
        scope, trial = r.parse(scope_raw), self.trial("gate")
        s, shadow_set = scope["body"], r.parse(trial["shadow-set.json"])
        workflow = s["workflow_id"] == "workflow.shadow-evidence-commit"
        r.require(workflow == (s["task_class"] == "task.commit-shadow-evidence"))
        r.require(bool(s.get("coverage")) == workflow)
        original_context = self.occurrences["gate"]["raw"][context]
        locators = self.locators["gate"]
        paths = {key: Path(locators[context + "." + key]) for key in
            ("scratch", "runtime", "captures", "output", "git_root", "git_config", "package", "python", "jq", "bash", "git")}
        _seed_require(all(path.is_absolute() for path in paths.values()))
        # These are historical paths only. None is reopened by replay.
        source_git_hold.recheck("E_STORE", self.work, "M")
        state = self.calculated.setdefault("scope_contexts", {}).get(context)
        if state is None:
            raw_rows = original_context["storage"]["entries"]
            groups, prefix, current = [], [], None
            for index, row in enumerate(raw_rows):
                if row["role"] != "store":continue
                name = os.fsdecode(bytes.fromhex(row["name"]))
                if name.startswith("/"):
                    if current is not None:
                        current["end"] = index;groups.append(current);current = None
                    prefix.append(row)
                elif name == "." or name.startswith(".capture-") and "/" not in name:
                    if current is not None:current["end"] = index;groups.append(current)
                    current = {"ancestors": prefix, "rows": [row], "capture": name != "."};prefix = []
                else:
                    _seed_require(current is not None);current["rows"].append(row)
            if current is not None:current["end"] = len(raw_rows);groups.append(current)
            _seed_require(not prefix)
            for group in groups:
                _seed_require(len(group["rows"]) >= (1 if group["capture"] else 3))
                group["attempt_id"] = (os.fsdecode(bytes.fromhex(group["rows"][0]["name"]))[len(".capture-"):]
                    if group["capture"] else os.fsdecode(bytes.fromhex(group["rows"][1]["name"])))
                _seed_require(c._id(group["attempt_id"]))
            def anchor_bytes(name, limit):
                return self.inputs.bytes("gate", "capture", context + "/anchor/" + name, limit)
            config_raw = anchor_bytes("host", c.DOCUMENT_LIMIT)
            config = c._parse_config(config_raw);self.inputs._account("R", len(config_raw), "M")
            installed = {key: anchor_bytes("installed-" + key, c.EXECUTABLE_LIMIT) for key in c.INSTALLED_SOURCES}
            for key, relative in c.INSTALLED_SOURCES.items():
                actual = e.read_regular(runtime_root / relative, c.EXECUTABLE_LIMIT, "E_INSTALL")
                self.inputs._account("R", len(actual), "M")
                r.require(self._scope_data_equal(actual, installed[key]), "E_INSTALL")
            registry = c._parse_registry(installed["registry"])
            accepted = c._parse_accepted(installed["accepted_set"])
            for key in ("registry", "accepted_set"):
                self.inputs._account("R", len(installed[key]), "M");self.inputs._account("H", len(installed[key]), "M")
            verifier_raw = anchor_bytes("verifier", c.EXECUTABLE_LIMIT)
            verifier_sha = c.digest(verifier_raw);self.inputs._account("H", len(verifier_raw), "M")
            context_values = {"config": config, "config_raw": config_raw, "registry": registry, "accepted": accepted,
                "installed": installed, "verifier_raw": verifier_raw, "verifier_sha256": verifier_sha,
                "supervisor_raw": anchor_bytes("supervisor", c.EXECUTABLE_LIMIT)}
            state = {"groups": groups, "cursor": 0, "captures": 1, "commands": [], "runtime_ordinals": {},
                "fresh": {}, "bindings": {}, "context": context_values, "modules": modules, "paths": paths,
                "argv": [], "command_recipe": [], "output_files": {}, "runtime_values_consumed": []}
            self.calculated["scope_contexts"][context] = state
        else:
            r.require(state["paths"] == paths)
        ctx = state["context"]
        round_number = state.get("round_number", 0)
        state["round_number"] = round_number + 1
        r.require(round_number < (4 if context == "generator" else 2), "E_STORE")
        actual_runtime_phase = "kill" if context == "generator" else "gate"
        def slot(name):
            rows = c._runtime_inventory_values(original_context["runtime"])
            matching = [row for row in rows.values() if row["slot"] == name and row["index"] == 0]
            _seed_require(matching)
            first = matching[0];raw = self._scope_runtime_value_body(context, first)
            sha = self._scope_data_sha(raw, "runtime")
            _seed_require(self._scope_data_size(raw) == first["size_bytes"] and sha == first["sha256"] and first["locator"] == str(paths[name]))
            for row in matching[1:]:
                repeated = self._scope_runtime_value_body(context, row)
                measured = self._scope_data_sha(repeated, "runtime")
                _seed_require(row["locator"] == first["locator"] and self._scope_data_size(repeated) == row["size_bytes"]
                    and measured == row["sha256"] and self._scope_data_equal(raw, repeated, "runtime"))
            return raw, sha
        binaries = {key: slot(key)[1] for key in ("python", "jq", "bash", "git")}
        state["binaries"] = binaries
        generator_root = Path(self.locators["gate"]["scope"]).parents[2]
        if paths["captures"].is_relative_to(generator_root):
            for key, raw in (("host", ctx["config_raw"]), ("verifier", ctx["verifier_raw"]),
                             ("supervisor", ctx["supervisor_raw"]),
                             *(("installed-" + key, value) for key, value in ctx["installed"].items())):
                name = paths["captures"] / "gate-4095" / "reader-anchor" / ("reader-anchor-" + key + ".bin")
                state["output_files"][name.relative_to(generator_root).as_posix()] = raw
            for row in c._runtime_inventory_values(original_context["runtime"]).values():
                raw = self._scope_runtime_value_body(context, row)
                sha = self._scope_data_sha(raw, "runtime")
                _seed_require(self._scope_data_size(raw) == row["size_bytes"] and sha == row["sha256"])
                state["output_files"][(paths["captures"] / row["file"]).relative_to(generator_root).as_posix()] = raw
        def source(relative):
            raw = e.read_regular(runtime_root / relative, c.EXECUTABLE_LIMIT, "E_RELATION")
            self.inputs._account("R", len(raw), "M")
            sha = c.digest(raw);self.inputs._account("H", len(raw), "M")
            return raw, sha
        def runtime_equal(site, expected):
            ordinal = state["runtime_ordinals"].get(site, 0)
            rows = [row for row in original_context["commands"]["runtime_values"] if row["site"] == site]
            _seed_require(ordinal < len(rows));state["runtime_ordinals"][site] = ordinal + 1
            index = len(state["runtime_values_consumed"])
            _seed_require(index < len(original_context["commands"]["runtime_values"])
                and original_context["commands"]["runtime_values"][index] == rows[ordinal])
            result = r._scope_runtime_equal_values(expected, rows[ordinal], site, ordinal)
            state["runtime_values_consumed"].append(rows[ordinal])
            return result
        def command(role, argv, executable, component, operation, annotations):
            return self._scope_append_command_body(context, role, argv, executable, component, operation, annotations)
        env = e.clean_env(runtime_root / "bin/jq", Path(work_hold.path))
        generation = e.core_modules(source("core/v2/generation-registry.json")[0])
        historical_modules = paths["package"] / generation.relative_to(runtime_root)
        def capture(name, raw):
            ordinal = state["captures"];state["captures"] += 1
            old = paths["captures"] / ("gate-%04d" % ordinal) / name
            new = self._replay_write_bytes(work_hold, "scope-%s-%04d-%s" % (context, ordinal, name), raw)
            generator_root = Path(self.locators["gate"]["scope"]).parents[2]
            if old.is_relative_to(generator_root):
                member = old.relative_to(generator_root).as_posix()
                _seed_require(member not in state["output_files"]);state["output_files"][member] = raw
            return old, new
        def shell(role, relative, arguments, historical_arguments, stdin=b"", limit=c.DOCUMENT_LIMIT):
            sha = source(relative)[1]
            old_argv = ["/bin/bash", "-p", str(paths["package"] / relative), *map(str, historical_arguments)]
            kinds = {"control/v1/evaluate-bound-sandbox.sh": (("fixed", "operation"), ("historical-path", "duty"), ("historical-path", "claim"), ("historical-path", "verifier-observation")),
                "shadow/v1/validate-incident.sh": (("fixed", "operation"), ("historical-path", "incident")),
                "enforcement/v1/check-sandbox-receipt.sh": (("fixed", "operation"), ("historical-path", "receipt"), ("historical-path", "expectation"), ("historical-path", "evaluation"), ("historical-path", "verifier-observation")),
                "telemetry/v1/validate-trace-ledger.sh": (("fixed", "operation"), ("content", "incident-id"), ("content", "attempt-id"), ("historical-path", "trace-ledger")),
                "maintenance/v1/incident-to-eval.sh": (("fixed", "operation"), ("historical-path", "incident"), ("historical-path", "record"), ("historical-path", "seed-directory"))}[relative]
            _seed_require(len(kinds) == len(historical_arguments))
            annotations = [{"position": 0, "type": "fixed", "role": "shell", "value": "/bin/bash"},
                {"position": 1, "type": "fixed", "role": "shell-mode", "value": "-p"},
                {"position": 2, "type": "historical-path", "role": "component:" + relative}]
            for index, ((kind, meaning), value) in enumerate(zip(kinds, historical_arguments), 3):
                annotations.append({"position": index, "type": kind, "role": meaning, **({"value": str(value)} if kind == "fixed" else {})})
            command("scope-fixed-check", old_argv, binaries["bash"], sha, str(historical_arguments[0]), annotations)
            return self._run_offline(role, ["/bin/bash", "-p", str(runtime_root / relative), *map(str, arguments)],
                stdin=stdin, output_limit=limit, env=env)
        def jq(role, relative, arguments, raw, historical_arguments=None):
            sha = source(relative)[1]
            old_arguments = arguments if historical_arguments is None else historical_arguments
            old_argv = [str(paths["jq"]), "-L", str(historical_modules), *map(str, old_arguments), "-f", str(paths["package"] / relative)]
            annotations = [{"position": 0, "type": "historical-path", "role": "jq"},
                {"position": 1, "type": "fixed", "role": "modules-flag", "value": "-L"},
                {"position": 2, "type": "historical-path", "role": "core-modules"}]
            variable = ({3: ("content", "repository-id"), 6: ("content", "hash-algorithm"), 9: ("content", "commit-id")}
                if relative == "shadow/v1/qualified-identity.jq" else
                {7: ("historical-path", "contract"), 10: ("historical-path", "patch"), 13: ("historical-path", "builder-metadata")}
                if relative == "shadow/v1/write-materialization-input.jq" else {})
            for index, value in enumerate(old_arguments):
                kind, meaning = variable.get(index, ("fixed", "filter-argument"))
                annotations.append({"position": index + 3, "type": kind, "role": meaning, **({"value": str(value)} if kind == "fixed" else {})})
            annotations.extend(({"position": len(old_argv) - 2, "type": "fixed", "role": "filter-flag", "value": "-f"},
                {"position": len(old_argv) - 1, "type": "historical-path", "role": "component:" + relative}))
            command("scope-fixed-json-check", old_argv, binaries["jq"], sha, role, annotations)
            return self._run_offline(role, [str(runtime_root / "bin/jq"), "-L", str(generation), *map(str, arguments),
                "-f", str(runtime_root / relative)], stdin=raw, output_limit=8 * c.DOCUMENT_LIMIT, env=env)
        def git(arguments, limit):
            return self._scope_git_body(runtime_root, work_hold, source_git_hold, context, arguments, limit)
        def shape(algorithm):
            r.require(algorithm in {"sha1", "sha256"})
            keys = git(["config", "--file", str(paths["git_config"]), "--name-only", "--list", "--no-includes"], c.DOCUMENT_LIMIT)
            try:r.require(set(keys.decode("utf-8").splitlines()) <= c.GIT_CONFIG_KEYS)
            except UnicodeError:raise c.Refusal("E_RELATION") from None
            r.require(git(["rev-parse", "--is-bare-repository"], 16) == b"true\n"
                and git(["rev-parse", "--show-object-format"], 16) == (algorithm + "\n").encode())
        def inventory(revision):
            shape(revision["hash_algorithm"])
            raw = git(["ls-tree", "-r", "-t", "-z", "--full-tree", revision["commit_id"]], 16 * c.DOCUMENT_LIMIT)
            value = c._git_inventory_values(raw, revision);self.inputs._account("R", len(raw), "M")
            return value
        def commit(oid):
            raw = git(["cat-file", "commit", oid], c.DOCUMENT_LIMIT)
            headers = raw.split(b"\n\n", 1)[0].splitlines()
            trees = [row[5:].decode("ascii") for row in headers if row.startswith(b"tree ")]
            parents = [row[7:].decode("ascii") for row in headers if row.startswith(b"parent ")]
            r.require(len(trees) == 1 and c._writer_oid(trees[0]) and all(c._writer_oid(value) for value in parents))
            return trees[0], parents
        if not state["commands"]:
            config_raw = self.inputs.bytes("case", "original-input", "git/config", c.DOCUMENT_LIMIT)
            state["config_copy"] = self._replay_write_bytes(work_hold, "scope-" + context + "-config-copy.txt", config_raw)
            generator_root = Path(self.locators["gate"]["scope"]).parents[2]
            if paths["git_config"].is_relative_to(generator_root):
                state["output_files"][paths["git_config"].relative_to(generator_root).as_posix()] = config_raw
            shape(s["qualified_identity"]["target_revision"]["hash_algorithm"])
            if context == "generator":
                r.require(jq("gate-basis-validation", "scope/v1/workflow-scope.jq",
                    ["-r", "--arg", "gate_basis", "basis"], scope_raw) == b"", "E_SHAPE")
        def fresh(snapshots, attempt_id):
            return self._scope_acquisition_origin_body(context, snapshots, attempt_id)
        def preparation(files, receipt, response):
            prep, producer = r._preparation_document_values(files, receipt, response)
            for key in ("python", "git", "jq"):
                identity = producer[key]
                r.require(r._preparation_binary_prefix_matches_values(identity)
                    and identity["executable_sha256"] == binaries[key] and r._preparation_binary_suffix_matches_values(identity))
            r.require(producer["source_sha256"] == source("preparation/v1/prepare-candidate.py")[1]
                and producer["protocol_sha256"] == source("adapters/local-git-materializer/v1/protocol.jq")[1]
                and producer["jq"]["version"] == "jq-1.6"
                and runtime_equal("scope.python-version", producer["python"]["version"])
                and producer["git"]["version"].startswith("git version ")
                and runtime_equal("scope.unicode-version", producer["unicode_version"]))
            names = {"adapters/local-git-materializer/v1/protocol.jq", "scripts/core-contract.sh", "core/v2/generation-registry.json"}
            root = str(generation.parent.relative_to(runtime_root))
            names.update(root + "/" + suffix for suffix in ("core-ingress.sh", "contracts.jq", "modules/schema.jq",
                "modules/profile_graph.jq", "modules/stage_request.jq", "modules/result_facts.jq", "modules/result_truth.jq"))
            r._preparation_core_values(producer["core"], generation.parent.name,
                [{"path": name, "sha256": source(name)[1]} for name in sorted(names)])
        def provenance(files, instruction, observation, attempt, write):
            keys, body = r._provenance_document_values(files, attempt)
            r.require(r._provenance_content_matches_values(body, instruction, observation)
                and body["consumer_source_sha256"] == source("shadow/v1/write-shadow.py" if write else "shadow/v1/enforced-reproduction.py")[1]
                and body["python_sha256"] == binaries["python"] and body["jq_sha256"] == binaries["jq"]
                and body["helper_source_sha256"] == c.HELPER_SOURCE_SHA256
                and all(c._sha(body[key]) for key in keys if key.endswith("sha256")))
            native = body["native_release"]
            r.require(r._provenance_native_shape_matches_values(native)
                and runtime_equal("scope.soabi", native["python_abi"])
                and r._provenance_native_identity_matches_values(native, body)
                and native["python_locator_sha256"] == c.digest(str(paths["python"]).encode()))
            for key, name in (("source_sha256", "shadow/v1/_cancel_release.c"),
                              ("build_script_sha256", "shadow/v1/build-cancel-release.sh")):
                r.require(native[key] == source(name)[1])
            fixed = {"helper-version": (body["helper_executable_sha256"], body["helper_source_sha256"]),
                "jq-version": (binaries["jq"], binaries["jq"]),
                "darwin-acl-uuid-resolution": (binaries["python"], source("shadow/v1/_consumer.py")[1]),
                "darwin-group-membership": (binaries["python"], source("shadow/v1/_consumer.py")[1])}
            # Reader.provenance calls FixedSudo: metadata SHA, independently from the source-command sudo byte SHA.
            sudo_stat = c._sudo_storage_stat_values(original_context["storage"]["entries"],
                original_context["storage"]["identity_context"]["platform"])
            fixed["sandbox-launch-boundary"] = (e._sudo_identity_values(c._identity_values(sudo_stat)),
                c.digest(ctx["supervisor_raw"]))
            for role, relative in r._provenance_roles_values().items():
                executable = binaries["git"] if role == "write-git-inspection" else binaries["python"] if role.startswith("candidate-") else (
                    binaries["jq"] if role in {"write-materialization-input", "materializer-input-validation",
                        "materializer-response-validation", "qualified-identity-validation"} else binaries["bash"])
                fixed[role] = (executable, source(relative)[1])
            r._provenance_commands_values(body, fixed)
        def git_relations(files, material, incident, body):
            revision = incident["body"]["git_revision_ref"]
            source_facts = inventory(revision)
            source_tree, _ = commit(revision["commit_id"])
            response = r.parse(files["materialization-response.json"])
            receipt = r.parse(response["payloads"][0]["data"].encode())
            candidate = receipt["candidate"]
            r._candidate_header_values(receipt["source"], body, revision, source_tree, candidate)
            candidate_tree, parents = commit(candidate["commit_id"])
            r.require(candidate_tree == candidate["tree_id"])
            facts = inventory(dict(revision, commit_id=candidate["commit_id"]))
            manifest = r.parse(files["preparation-manifest.json"])
            entries = r._candidate_manifest_header_values(manifest)
            manifest_facts = {};file_count = total_bytes = 0
            for row in entries:
                value = r._candidate_manifest_row_values(row, manifest_facts, facts)
                if value[1] == "blob":
                    r.require(set(row) == {"path", "kind", "git_mode", "mode", "blob_oid", "size_bytes", "sha256"})
                    file_count += 1
                    r.require(type(row["size_bytes"]) is int and row["size_bytes"] >= 0);total_bytes += row["size_bytes"]
                    r.require(r._candidate_manifest_file_matches_values(row, value))
                    raw = git(["cat-file", "blob", value[2]], min(16 * c.DOCUMENT_LIMIT, row["size_bytes"] + 1))
                    r._candidate_manifest_blob_values(raw, row)
            r._candidate_manifest_totals_values(manifest_facts, facts, manifest, entries, file_count, total_bytes)
            preparation(files, receipt, response)
            if body["record_form"] == "enforced-reproduction.v1":
                e.require_no_change(files["materialization-response.json"], incident)
                r.require(facts == source_facts and candidate["commit_id"] == revision["commit_id"])
                return
            r.require(parents == [revision["commit_id"]])
            # The write relation value owner must be extracted at the existing Reader.write_relations sites;
            # it consumes these actual Git inventories and independently read blob bytes, not a success flag.
            write, prefix, paths_to_write, rows, policy_form = r._scope_write_header_values(files, incident, body, scope)
            frozen_bytes = {}
            for row in rows:
                r._scope_write_row_values(row, facts)
                limit = 8 * c.DOCUMENT_LIMIT if row["path"].endswith("materialization-input.json") else 2 * c.DOCUMENT_LIMIT
                raw = git(["cat-file", "blob", row["git_blob_oid"]], limit + 1)
                r.require(len(raw) <= limit and c.digest(raw) == row["sha256"])
                frozen_bytes[row["path"]] = raw
            patch = r._scope_write_copied_values(frozen_bytes, incident, body, rows, paths_to_write, facts, source_facts)
            policy_raw = files["scope-policy.json"] if policy_form else source("scope/v1/scope-policy.json")[0]
            policy = r._scope_write_policy_values(policy_raw, policy_form, frozen_bytes, prefix)
            # Evaluate bundle-ref at its original point inside the native split; do not hoist it into native inputs.
            frozen = r._scope_write_frozen_values(source("config/construction-mode.json")[0], policy, s, paths_to_write,
                frozen_bytes, prefix, incident, body, files)
            r.require(r.same(write["bundle_ref"], w._bundle_ref(frozen["bundle.json"]))
                and r._scope_write_frozen_tail_matches_values(frozen_bytes, frozen))
            nested = self._scope_history_files_body(context, frozen["shadow-record.json"])
            r.require(set(nested) == set(frozen) and all(self._scope_data_equal(nested[name], frozen[name]) for name in frozen))
            authenticate(nested, revision)
            slot_number = state.get("runtime_slot", 0);state["runtime_slot"] = slot_number + 1
            old_seed = paths["runtime"] / ("gate-%04d" % slot_number)
            actual_seed = self._replay_mkdir(work_hold, "seed-%s-%04d" % (context, slot_number))
            old_incident, seed_incident = capture("seed-incident-" + str(state["captures"]) + ".json", frozen["incident.json"])
            old_record, seed_record = capture("seed-record-" + str(state["captures"]) + ".json", frozen["shadow-record.json"])
            seed = shell("write-seed-conversion", "maintenance/v1/incident-to-eval.sh",
                ["convert", seed_incident, seed_record, actual_seed.path], ["convert", old_incident, old_record, old_seed])
            r.require(seed == frozen_bytes[prefix + "eval-seed.json"])
            seed_doc = r.parse(seed)
            family = seed_doc["body"]["family_id"]
            r.require(type(family) is str and family and all(char in "abcdefghijklmnopqrstuvwxyz0123456789-" for char in family))
            generator_root = Path(self.locators["gate"]["scope"]).parents[2]
            if old_seed.is_relative_to(generator_root):
                state["output_files"][(old_seed / ("eval-seed-case-" + family + ".json")).relative_to(generator_root).as_posix()] = seed
            contract = c.write_contract(paths_to_write, body["record_form"])
            old_contract, contract_path = capture("contract-" + str(state["captures"]) + ".json", contract)
            old_patch, patch_path = capture("patch-" + str(state["captures"]) + ".txt", patch)
            metadata = {key: c.digest(raw) for key, raw in c.WRITE_TEXTS.items()}
            attempt = r.parse(files["sandbox-request.json"])["id"]
            metadata.update({"contract": c.digest(contract), "patch": c.digest(patch), "allowed_paths": paths_to_write,
                "attempt_id": attempt, "suffix": c.digest(attempt.encode())[:32], "environment_id": r.parse(files["claim.json"])["id"],
                "claim_sha256": c.digest(files["claim.json"]), "record_form": body["record_form"], "incident_id": r.parse(frozen["incident.json"])["id"]})
            old_meta, meta = capture("metadata-" + str(state["captures"]) + ".json", c.canonical(metadata))
            first = jq("write-materialization-input", "shadow/v1/write-materialization-input.jq",
                ["-S", "-c", "--arg", "phase", "stage-request", "--rawfile", "contract", contract_path,
                 "--rawfile", "patch", patch_path, "--slurpfile", "metadata", meta], frozen["materialization-input.json"],
                ["-S", "-c", "--arg", "phase", "stage-request", "--rawfile", "contract", old_contract,
                 "--rawfile", "patch", old_patch, "--slurpfile", "metadata", old_meta])
            # Offline child file arguments use actual private paths; historical paths above are only for recipe.
            first_doc = r.parse(first);r.require(c.canonical(first_doc["original"]) == frozen["materialization-input.json"])
            metadata["stage_request_sha256"] = c.digest(c.canonical(first_doc["stage_request"]))
            old_meta, meta = capture("metadata-" + str(state["captures"]) + ".json", c.canonical(metadata))
            final = jq("write-materialization-input", "shadow/v1/write-materialization-input.jq",
                ["-S", "-c", "--arg", "phase", "final-input", "--rawfile", "contract", contract_path,
                 "--rawfile", "patch", patch_path, "--slurpfile", "metadata", meta], first,
                ["-S", "-c", "--arg", "phase", "final-input", "--rawfile", "contract", old_contract,
                 "--rawfile", "patch", old_patch, "--slurpfile", "metadata", old_meta])
            r.require(final == files["materialization-input.json"])
            publisher, publisher_body = w._publisher(incident, candidate_tree)
            r._scope_write_publication_values(write, files, publisher, publisher_body, incident, candidate_tree, rows)
            return frozen_bytes
        def authenticate(files, revision):
            r.require(all(files[name] == ctx["installed"][role] for name, role in r._authentication_installed_names_values().items()))
            incident, body, actual_revision = r._authentication_documents_values(files)
            r.require(r.same(actual_revision, revision or s["qualified_identity"]["target_revision"])
                and body["target_repository_id"] == s["target_repository_id"])
            selected = r._authentication_environment_values(ctx["registry"][1], body)
            accepted = r._authentication_environment_values(ctx["accepted"][1], body)
            r.require(len(selected) == len(accepted) == 1);registry = selected[0]
            r.require(r._authentication_registry_matches_values(registry, body)
                and registry["source_root_commit"] == (s["coverage"]["coverage_base"]["commit_id"] if "coverage" in s else actual_revision["commit_id"]))
            receipt = r._authentication_receipt_values(files, accepted)
            r.require(ctx["config"]["environment_id"] == body["environment"]["environment_id"]
                and registry["target_repository_id"] == body["target_repository_id"]
                and ctx["verifier_sha256"] in accepted[0]["identities"]["verifier"], "E_RELATION")
            entry_sha = c._verifier_registry_entry_sha(registry)
            observation = c._verifier_observation_values(body["environment"]["environment_id"], entry_sha,
                ctx["accepted"][0], body["target_repository_id"], ctx["verifier_sha256"])
            old_observer, observer = capture("verifier-" + str(state["captures"]) + ".json", observation)
            provenance_doc = r.parse(files["consumer-provenance.json"])
            r.require(r.same(provenance_doc["body"]["observation"], r.parse(observation))
                and provenance_doc["body"]["observation_sha256"] == c.digest(observation))
            retained = {name: capture(str(state["captures"]) + "-" + name, files[name]) for name in files}
            actual_args = ["evaluate", retained["duty-evaluation.json"][1], retained["claim.json"][1], observer]
            old_args = ["evaluate", retained["duty-evaluation.json"][0], retained["claim.json"][0], old_observer]
            evaluation = shell("sandbox-bound-evaluation", "control/v1/evaluate-bound-sandbox.sh", actual_args, old_args)
            r.require(evaluation == files["sandbox-evaluation.json"] and r.parse(evaluation)["body"]["verdict"] == "satisfied")
            shell("incident-validation", "shadow/v1/validate-incident.sh", ["validate", retained["incident.json"][1]], ["validate", retained["incident.json"][0]])
            material, identity = r.parse(files["materialization-input.json"]), r.parse(files["qualified-identity.json"])
            instruction = e.make_instruction(incident)
            if body["record_form"] == "enforced-reproduction.v1":
                e.validate_input_relations(material, incident, r.parse(files["claim.json"]), identity, instruction)
            else:
                r.require(r.same(identity["body"]["stage_request_ref"], e.pair_ref(material["stage_request"]))
                    and r.same(identity["body"]["resolved_profile_ref"], e.pair_ref(material["resolved_profile"]))
                    and identity["body"]["verification_instructions_ref"]["sha256"] == c.digest(instruction))
            r.require(jq("qualified-identity-validation", "shadow/v1/qualified-identity.jq", ["-r", "--arg", "repository_id", body["target_repository_id"],
                "--arg", "hash_algorithm", actual_revision["hash_algorithm"], "--arg", "commit_id", actual_revision["commit_id"]], files["qualified-identity.json"]) == b"")
            jq("materializer-input-validation", "adapters/local-git-materializer/v1/protocol.jq", ["-e", "--arg", "command", "validate-input"], files["materialization-input.json"])
            response = r.parse(files["materialization-response.json"])
            jq("materializer-response-validation", "adapters/local-git-materializer/v1/protocol.jq", ["-e", "--arg", "command", "validate-response"], e.response_check(material, files["materialization-response.json"]))
            prep, manifest = r.parse(files["preparation-record.json"]), r.parse(files["preparation-manifest.json"])
            launch = r._launch_expectation_values(files, ctx["config"], registry, body, prep, instruction, e._control_values(ctx["installed"], evaluation))
            mapping = r._authentication_store_names_values()
            snapshots = {key: files[name] for key, name in mapping.items()}
            # Each byte is a recomputed launch output, independently held/copied at the original I input boundary.
            r.require(set(snapshots) == set(mapping))
            origin = fresh(snapshots, launch["id"])
            r._origin_projection_values(r.parse(files["origin-observation.json"]), snapshots, launch["id"], ctx["config"])
            r._origin_projection_values(r.parse(origin), snapshots, launch["id"], ctx["config"])
            names = ("sandbox-receipt.json", "sandbox-expectation.json", "sandbox-evaluation.json")
            checked = shell("sandbox-receipt-check", "enforcement/v1/check-sandbox-receipt.sh",
                ["check-bound", *[retained[name][1] for name in names], observer], ["check-bound", *[retained[name][0] for name in names], old_observer])
            r.require(checked == files["sandbox-check.json"] and r.parse(checked)["body"]["check_verdict"] == "valid"
                and r.parse(checked)["body"]["enforcement_verdict"] == "satisfied")
            result_raw, result = e.payload_result(snapshots, r.parse(files["evidence-manifest.json"]), instruction, manifest, receipt)
            r.require(result_raw == files["file-digest-result.json"])
            write = body.get("write")
            w._record_relations_values(files, incident, result, origin, ctx["config"]["store_id"], write)
            r._record_refs_values(files, body, launch["id"], ctx["config"])
            trace = shell("trace-validation", "telemetry/v1/validate-trace-ledger.sh", ["validate", incident["id"], launch["id"], retained["trace-ledger.json"][1]],
                ["validate", incident["id"], launch["id"], retained["trace-ledger.json"][0]])
            r.require(trace == files["trace-receipt.json"])
            provenance(files, instruction, observation, launch["id"], write is not None)
            candidate_files = git_relations(files, material, incident, body)
            source_git_hold.recheck("E_STORE", self.work, "M")
            facts = r._bundle_facts_values(files, checked, origin, body)
            if candidate_files is not None:
                _bundle_names, names = c._c1_history_names_values(body["record_form"])
                prefix = "ystack-evidence/" + incident["id"] + "/"
                r.require(set(candidate_files) == {prefix + name[len("candidate-"):] for name in names})
                for name in sorted(names):capture(name, candidate_files[prefix + name[len("candidate-"):]])
            return facts
        if context == "scope_reader" and round_number == 1:
            self._scope_source_origin_body(context, "coverage")
        # Native _HeldBundle.files insertion order is sorted fixed member names.
        rebuilt = {}
        for phase in ("reproduction", "write"):
            calculated = self.calculated[phase]
            rebuilt[phase] = dict(sorted({**calculated["files"], "bundle.json": calculated["bundle"]}.items()))
        r.require(set(shadow_set) == {"schema_version", "kind", "id", "body"}
            and type(shadow_set["schema_version"]) is int and shadow_set["schema_version"] == 1
            and shadow_set["kind"] == "shadow_evidence_set" and c._id(shadow_set["id"])
            and type(shadow_set["body"]) is dict and set(shadow_set["body"]) == {"records"})
        records = shadow_set["body"]["records"]
        r.require(type(records) is list and 1 <= len(records) <= 16)
        identity = s["qualified_identity"]
        groups = [("current", s["shadow_evidence_refs"], identity["target_revision"], [])]
        if s.get("coverage") is not None:
            groups.insert(0, ("qualifying", s["coverage"]["qualifying_shadow_record_refs"], s["coverage"]["coverage_base"], []))
        roles = {"current": {}, "qualifying": {}}
        digests = set()
        base_keys = {"activation_state", "authority", "check", "deploy_authority", "effects", "environment",
            "evaluation_mode", "git_revision_ref", "incident_ref", "materialization", "observed_at", "outcome",
            "qualification", "qualified_identity", "qualified_identity_ref", "reason_id", "shadow",
            "target_repository_id", "trace_ledger_ref"}
        for record in records:
            raw = c.canonical(record);sha = c.digest(raw)
            r.require(sha not in digests);digests.add(sha)
            r.require(type(record) is dict and set(record) == {"schema_version", "kind", "id", "body"}
                and type(record["schema_version"]) is int and record["schema_version"] == 1
                and record["kind"] == "shadow_reproduction_record" and c._id(record["id"]) and type(record["body"]) is dict)
            body = record["body"];form = body.get("record_form", "legacy")
            r.require(form in {"legacy", "enforced-reproduction.v1", "withheld-write.v1", "withheld-write-policy.v1"})
            additions = set() if form == "legacy" else {"record_form", "sandbox", "producer_invocations", "consumer_provenance_ref"}
            if form in {"withheld-write.v1", "withheld-write-policy.v1"}:additions.add("write")
            if form == "withheld-write-policy.v1":additions.add("scope_policy_ref")
            r.require(set(body) == base_keys | additions)
            for role, references, revision, output in groups:
                claimed = any(reference["id"] == record["id"] and reference["sha256"] == sha for reference in references)
                same_identity = r.same(body["qualified_identity"], identity) if role == "current" else all(
                    r.same(body["qualified_identity"][key], identity[key]) for key in
                    ("model_request", "adapter_config_refs", "prompt_refs", "skill_refs", "verification_instructions_ref"))
                match = body["target_repository_id"] == s["target_repository_id"] and r.same(body["git_revision_ref"], revision) and same_identity
                eligible = claimed and match and form != "legacy"
                environment = body["environment"]["environment_id"]
                row = {"record_ref": r.ref(raw), "record_form": form, "claimed": claimed, "eligible": eligible,
                    "environment_id": environment, "authentication": {"state": "missing"}, "facts": {}}
                if eligible and (not current_only or role == "current"):
                    r.require(environment not in roles[role] and environment in s["required_shadow_environments"]
                        and (form not in {"withheld-write.v1", "withheld-write-policy.v1"} or workflow))
                    candidates = [files for files in rebuilt.values() if files["shadow-record.json"] == raw]
                    r.require(len(candidates) <= 1)
                    files = self._scope_history_files_body(context, raw)
                    if candidates:
                        r.require(set(candidates[0]) == set(files) and all(
                            self._scope_data_equal(files[name], candidates[0][name]) for name in files))
                    r.require(body["materialization"]["value"]["outcome"] == ("no-change" if form == "enforced-reproduction.v1" else "changed"))
                    roles[role][environment] = files
                    row["facts"] = authenticate(files, revision)
                    row["authentication"] = {"state": "authenticated"}
                output.append(row)
        for _role, references, _revision, output in groups:
            for reference in references:
                r.require(sum(reference["id"] == row["record_ref"]["id"] and reference["sha256"] == row["record_ref"]["sha256"] for row in output) == 1)
        if context == "generator" and round_number == 1:
            self._scope_source_origin_body(context, "kill")
        elif context == "generator" and round_number == 3:
            self._scope_source_origin_body(context, "kill")
            self._scope_source_origin_body(context, "coverage")
        elif context == "scope_reader" and round_number == 0:
            self._scope_source_origin_body(context, "kill")
        current = next(values for name, _refs, _revision, values in groups if name == "current")
        qualifying = next((values for name, _refs, _revision, values in groups if name == "qualifying"), [])
        return {"rows": current, "qualifying_rows": qualifying, "role_files": roles,
            "fresh": dict(state["fresh"]), "commands": list(state["commands"]), "context": ctx}

    def _scope_capture_private_body(self, context, phase):
        import ast, math, struct
        state = self.calculated["scope_contexts"][context]
        r = state["modules"]["reader"];c = r.c
        root = Path(state["modules"]["reader"].PACKAGE)
        source = self.calculated[phase]["files"];request_raw = source["payload/request.json"]
        request = r.parse(request_raw);attempt = request["id"]
        source_group = state["last_source_group"]
        original = self.occurrences["gate"]["raw"][context]
        r.require(state["cursor"] < len(state["groups"]), "E_STORE")
        group = state["groups"][state["cursor"]]
        r.require(group["capture"] and group["attempt_id"] == attempt, "E_STORE")
        capture_ancestors = r._scope_storage_chains_values(group["ancestors"], group["rows"], state["context"]["config"]["store_root"], True)
        r.require(capture_ancestors and capture_ancestors[-1] == list(c._identity_values(source_group["rows"][0]["before"])), "E_STORE")
        state["cursor"] += 1
        ordinal = state.get("source_capture_ordinal", 0)
        r.require(ordinal < 4096, "E_LIMIT");state["source_capture_ordinal"] = ordinal + 1
        reused = context == "generator" and ordinal == 0 and phase == "kill" or context == "scope_reader" and ordinal == 1 and phase == "coverage"
        primitive_raw = self.inputs.bytes(phase if reused else "gate", "capture",
            ("source-%04d/consumer-observations.json" % ordinal) if reused else context + "/source-%04d/consumer-observations.json" % ordinal, c.DOCUMENT_LIMIT)
        primitive = r.parse(primitive_raw, c.DOCUMENT_LIMIT)
        r.require(type(primitive) is dict and set(primitive) == {"attempt_id", "request_sha256", "storage", "storage_reads",
            "identity_context", "commands", "preparation", "entropy", "clocks"}
            and primitive["attempt_id"] == attempt and type(primitive["storage_reads"]) is list, "E_STORE")
        request_sha = c.digest(request_raw);self.inputs._account("H", len(request_raw), "M")
        r.require(primitive["request_sha256"] == request_sha and primitive["storage"] == source_group["rows"]
            and primitive["identity_context"] == original["storage"]["identity_context"], "E_STORE")
        projected = c._gate_storage_rows_values(primitive["storage_reads"])
        r.require(projected == original["storage"]["entries"][:group["end"]], "E_STORE")
        r.require(type(primitive["commands"]) is dict and set(primitive["commands"]) == {"runtime_values"}, "E_STORE")
        r._scope_runtime_prefix_values(primitive["commands"]["runtime_values"], original["commands"]["runtime_values"])
        r.require(primitive["commands"]["runtime_values"] == state["runtime_values_consumed"]
            and primitive["preparation"] == {}, "E_STORE")
        if context == "generator":entropy = {"kill": self.occurrences["gate"]["raw"][context]["entropy"]["kill"]}
        elif phase == "coverage" or state["round_number"] > 1:
            entropy = {"coverage": self.occurrences["gate"]["raw"][context]["entropy"]["coverage"]}
        else:entropy = {}
        r.require(primitive["entropy"] == entropy, "E_STORE")
        # Only primitive, source-bound clock observations are inputs. No clock value
        # selects code, a command, an owner or a filesystem path.
        owners = ("scope/v1/read-shadow-evidence.py", "scope/v1/generate-gate-evidence.py", "shadow/v1/_consumer.py")
        if "clock_sites" not in state:
            sites = {}
            for owner in owners:
                raw = (root / owner).read_bytes();self.inputs._account("R", len(raw), "M")
                tree = ast.parse(raw)
                sites[owner] = {node.args[0].value for node in ast.walk(tree) if isinstance(node, ast.Call)
                    and isinstance(node.func, (ast.Name, ast.Attribute))
                    and (node.func.id if isinstance(node.func, ast.Name) else node.func.attr) == "_clock_value"
                    and node.args and isinstance(node.args[0], ast.Constant) and type(node.args[0].value) is str}
            state["clock_sites"] = sites
        clocks = primitive["clocks"]
        r.require(type(clocks) is dict and set(clocks) <= set(owners), "E_STORE")
        for owner, kinds in clocks.items():
            r.require(type(kinds) is dict and set(kinds) == {"wall", "monotonic"}, "E_STORE")
            for kind, rows in kinds.items():
                r.require(type(rows) is list and len(rows) <= 4096, "E_STORE")
                for row in rows:
                    r.require(type(row) is dict and set(row) == {"site", "value"}
                        and row["site"] in state["clock_sites"][owner] and type(row["value"]) is str
                        and len(row["value"]) == 16 and all(char in "0123456789abcdef" for char in row["value"]), "E_STORE")
                    r.require(math.isfinite(struct.unpack(">d", bytes.fromhex(row["value"]))[0]), "E_STORE")
                if owner in original["clocks"]:r.require(rows == original["clocks"][owner][kind][:len(rows)], "E_STORE")
        rebuilt_primitive = self.inputs.encode({"attempt_id": attempt, "request_sha256": request_sha,
            "storage": source_group["rows"], "storage_reads": primitive["storage_reads"],
            "identity_context": original["storage"]["identity_context"],
            "commands": {"runtime_values": list(state["runtime_values_consumed"])}, "preparation": {},
            "entropy": entropy, "clocks": clocks})
        self.inputs._account("E", len(rebuilt_primitive) + len(primitive_raw), "M")
        r.require(rebuilt_primitive == primitive_raw, "E_STORE")
        groups = self.occurrences[phase]["raw"]["capture"]
        capture_raw = c._capture_envelope_values(attempt, request_raw, groups)
        spec = importlib.util.spec_from_file_location("malicious_scope_capture_completion", root / "sandbox/v1/host-supervisor.py")
        h = importlib.util.module_from_spec(spec);sys.modules[spec.name] = h;spec.loader.exec_module(h)
        complete = h._capture_completion_values(attempt, request_raw, capture_raw)
        captures = {"capture.json": capture_raw, "complete.json": complete}
        for row in c._runtime_inventory_values(groups["runtime"]).values():
            members = [value for value, _held in self.inputs.rows.values() if value["occurrence"] == phase
                and value["role"] == "capture" and value["member"].rsplit("/", 1)[-1] == row["file"]]
            r.require(len(members) == 1, "E_STORE")
            raw = self.inputs.semantic(phase, "capture", members[0]["member"])
            sha = self._scope_data_sha(raw, "runtime")
            r.require(self._scope_data_size(raw) == row["size_bytes"] and sha == row["sha256"], "E_STORE")
            captures[row["file"]] = raw
        origin = c._origin_values(source, source_group["rows"], {"attempt_id": attempt,
            "platform": original["storage"]["identity_context"]["platform"]}, {"host-config.json": state["context"]["config_raw"]},
            capture_files=captures, capture_storage_rows=group["rows"], work=self.work)
        generator_root = Path(self.locators["gate"]["scope"]).parents[2]
        parent = state["paths"]["captures"] / ("gate-%04d" % (4095 - ordinal))
        if parent.is_relative_to(generator_root):
            prefix = parent / ("source-%04d" % ordinal)
            for name, raw in {**captures, "origin-observation.json": origin, "consumer-observations.json": rebuilt_primitive}.items():
                member = (prefix / name).relative_to(generator_root).as_posix()
                r.require(member not in state["output_files"], "E_STORE");state["output_files"][member] = raw
            names = {"host": "source-host.json", "config": "source-config.json", "accepted": "source-accepted.json",
                "package": "source-package.json", "supervisor": "source-supervisor.py", "normalizer": "source-normalizer.py"}
            configuration = self._scope_configuration_inputs_body(context, ordinal, phase)
            for name, member in names.items():
                raw = configuration[name]
                state["output_files"][(parent / ("source-configuration-%04d" % ordinal) / member).relative_to(generator_root).as_posix()] = raw
        return origin

    def _scope_configuration_body(self, runtime_root, context, ordinal, phase):
        _seed_require(context in {"generator", "scope_reader"} and phase in {"kill", "coverage"}
            and type(ordinal) is int and 0 <= ordinal < 4096)
        state = self.calculated["scope_contexts"][context];r = state["modules"]["reader"];c = r.c
        g = state["modules"]["generator"]
        values = self._scope_configuration_inputs_body(context, ordinal, phase)
        n = g._normalizer();n = n._KillNormalizer if phase == "kill" else n
        config = n.source_config(values["config"], state["context"]["config"])["body"]
        n.package(values["package"], config)
        n.accepted(values["accepted"], config, self._scope_data_sha(values["supervisor"]),
            self._scope_data_sha(values["package"]), config["collector_sha256"], self._scope_data_sha(values["normalizer"]))
        actual_normalizer = (Path(runtime_root) / "sandbox/v1/coverage-source.py").read_bytes()
        self.inputs._account("R", len(actual_normalizer), "M")
        r.require(self._scope_data_equal(values["host"], state["context"]["config_raw"])
            and self._scope_data_equal(values["supervisor"], state["context"]["supervisor_raw"])
            and self._scope_data_equal(values["normalizer"], actual_normalizer), "E_STORE")
        phase_values = {key: self.inputs.bytes(phase, "capture", "configuration/" + key,
            c.EXECUTABLE_LIMIT if key in {"supervisor", "normalizer"} else c.DOCUMENT_LIMIT) for key in values}
        r.require(all(self._scope_data_equal(values[key], phase_values[key]) for key in values), "E_STORE")
        return values, config, n

    def _scope_configuration_inputs_body(self, context, ordinal, phase):
        state = self.calculated["scope_contexts"][context];c = state["modules"]["reader"].c
        reused = context == "generator" and ordinal == 0 and phase == "kill" or context == "scope_reader" and ordinal == 1 and phase == "coverage"
        occurrence = phase if reused else "gate"
        prefix = "configuration/" if reused else context + "/source-configuration-%04d/" % ordinal
        return {key: self.inputs.bytes(occurrence, "capture", prefix + key,
            c.EXECUTABLE_LIMIT if key in {"supervisor", "normalizer"} else c.DOCUMENT_LIMIT)
            for key in ("host", "config", "accepted", "package", "supervisor", "normalizer")}

    def _scope_coverage_request_body(self, runtime_root, work_hold, source_git_hold, context, scope_raw, role_files):
        state = self.calculated["scope_contexts"][context]
        r, g = state["modules"]["reader"], state["modules"]["generator"];c = r.c
        scope = r.parse(scope_raw);s = scope["body"]
        controls, initial = self.calculated["gate_controls"], self.calculated["generator_kill"]
        qualifying, current = role_files["qualifying"], role_files["current"]
        required = s["required_shadow_environments"]
        configuration, config, n = self._scope_configuration_body(runtime_root, context, 1 if context == "scope_reader" else 2, "coverage")
        def coverage_identity(files):
            record = r.parse(files["shadow-record.json"])["body"];q = record["qualified_identity"]
            profile = r.parse(files["materialization-input.json"])["resolved_profile"]["content"]["body"]
            environment = record["environment"]["environment_id"]
            selected = [row for row in state["context"]["registry"][1] if row["environment_id"] == environment]
            r.require(len(selected) == 1)
            return r._coverage_identity_values(scope["id"], s["workflow_id"], s["task_class"],
                {key: q[key] for key in ("model_request", "adapter_config_refs", "prompt_refs", "skill_refs", "verification_instructions_ref")},
                {key: profile[key] for key in ("profile_ref", "profile_source", "selection_ref", "bindings")},
                environment, selected[0], r.ref(files["policy-set.json"]), c.digest(files["policy.json"]),
                c.digest(files["scope-policy.json"]), s["coverage"]["coverage_base"])
        policy_raw = sys.modules["malicious_reproduction_pipeline"].read_regular(runtime_root / "scope/v1/scope-policy.json", c.DOCUMENT_LIMIT, "E_RELATION")
        self.inputs._account("R", len(policy_raw), "M")
        for environment in required:
            before, after = qualifying[environment], current[environment]
            a, b = r.parse(before["shadow-record.json"])["body"], r.parse(after["shadow-record.json"])["body"]
            r.require(a["record_form"] == b["record_form"] == "withheld-write-policy.v1")
            c.check_scope_policy_ref(a["scope_policy_ref"], before["scope-policy.json"])
            c.check_scope_policy_ref(b["scope_policy_ref"], after["scope-policy.json"])
            r.require(before["scope-policy.json"] == after["scope-policy.json"] == policy_raw)
            r.require(r.same(coverage_identity(before), coverage_identity(after)))
        trial = self.trial("gate")
        raw_documents = {"scope": scope_raw, "shadow-set": trial["shadow-set.json"], "dashboard": trial["dashboard.json"],
            "risk": controls["risk"], "kill": controls["kill"], "duty": controls["duty"], "marker": trial["marker.json"]}
        documents = {name: r.ref(raw_documents[name]) for name in n.DOCUMENT_NAMES}
        risk, duty = (r.parse(raw_documents[name]) for name in ("risk", "duty"))
        identity = s["qualified_identity"]
        r.require(r.same(risk["body"]["stage"]["request_ref"], identity["stage_request_ref"])
            and r.same(duty["body"]["stage"]["request_ref"], identity["stage_request_ref"])
            and r.same(risk["body"]["stage"]["resolved_profile_ref"], identity["resolved_profile_ref"])
            and r.same(duty["body"]["stage"]["resolved_profile_ref"], identity["resolved_profile_ref"])
            and r.same(risk["body"]["stage"]["result_ref"], duty["body"]["stage"]["result_ref"]))
        r.require(all(r.same(r.ref(c.canonical(r.parse(files["materialization-response.json"])["stage_result"])),
            duty["body"]["stage"]["result_ref"]) for files in current.values()))
        entropy = self.occurrences["gate"]["raw"]["scope_reader"]["entropy"]["coverage"]
        r.require(type(entropy) is list and len(entropy) == 1 and len(bytes.fromhex(entropy[0])) == 32)
        nonce = entropy[0];attempt = "coverage." + nonce
        # These are fixed bounded actual Git operations. No forge/native source invocation occurs.
        e = sys.modules["malicious_reproduction_pipeline"]
        env = e.clean_env(runtime_root / "bin/jq", Path(work_hold.path))
        def commit(oid):
            raw = self._scope_git_body(runtime_root, work_hold, source_git_hold, context, ["cat-file", "commit", oid], c.DOCUMENT_LIMIT)
            headers = raw.split(b"\n\n", 1)[0].splitlines()
            trees = [row[5:].decode("ascii") for row in headers if row.startswith(b"tree ")]
            parents = [row[7:].decode("ascii") for row in headers if row.startswith(b"parent ")]
            r.require(len(trees) == 1 and c._writer_oid(trees[0]) and all(c._writer_oid(value) for value in parents))
            return trees[0], parents
        def hashes(name):
            return [{"environment_id": environment, "sha256": c.digest(c.canonical(r.parse(files["shadow-record.json"])["body"]["write"][name]))}
                for environment, files in sorted(current.items())]
        git_config = self.inputs.bytes("case", "original-input", "git/config", c.DOCUMENT_LIMIT)
        base = s["coverage"]["coverage_base"];revision = identity["target_revision"]
        git_observation = r._coverage_git_values(base, revision, commit(base["commit_id"])[0],
            commit(revision["commit_id"])[0], c.digest(git_config))
        body = r._coverage_request_body_values(attempt, nonce, s["target_repository_id"], base, revision,
            documents, sorted(s["coverage"]["qualifying_shadow_record_refs"], key=c.canonical),
            sorted(s["shadow_evidence_refs"], key=c.canonical), identity["resolved_profile_ref"], identity["stage_request_ref"],
            duty["body"]["stage"]["result_ref"], [{"environment_id": environment, "sha256": c.digest(files["materialization-response.json"])}
                for environment, files in sorted(current.items())], hashes("publisher_request"), hashes("post_write_verification"),
            sorted([r.ref(files["sandbox-receipt.json"]) for files in qualifying.values()], key=c.canonical),
            c.digest(c.canonical(git_observation)), n.doc_ref(configuration["package"]), n.doc_ref(configuration["accepted"]))
        body.update(initial_origin_refs=sorted([r.ref(origin) for origin, _snapshots, _binding in state["fresh"].values()], key=c.canonical),
            gate_call_ref=r.ref(initial["request_raw"]))
        coverage_raw = c.canonical(g.envelope("coverage_source_request", attempt, body));n.request(coverage_raw)
        return {"request_raw": coverage_raw, "body": body, "documents": documents,
            "configuration": configuration, "config": config, "normalizer": n}

    def _scope_data_chunks(self, value):
        self._scope_data_size(value)
        if type(value) is tuple:
            for chunk in value:
                if chunk:yield memoryview(chunk)
        else:
            for start in range(0, len(value), 65536):yield memoryview(value)[start:start + 65536]

    def _scope_data_equal(self, left, right, kind="M"):
        if self._scope_data_size(left) != self._scope_data_size(right):return False
        self.work["scope_stream_equality_incomplete"] = True
        incoming = iter(self._scope_data_chunks(right));current = memoryview(b"");offset = 0
        equal = True
        for chunk in self._scope_data_chunks(left):
            while chunk:
                if offset == len(current):current, offset = next(incoming), 0
                count = min(len(chunk), len(current) - offset)
                increment = self.c._c3_vector_values((0,) * 55)
                increment["seed_processing"]["E"] = 2 * count
                if kind == "runtime":
                    self.c._runtime_account(self.work, "equality_bytes", 2 * count, commit=False)
                    increment["runtime"]["equality_bytes"] = 2 * count
                self.c._c3_binding_room(self.work, increment)
                part = chunk[:count] == current[offset:offset + count]
                self.inputs._account("E", 2 * count, "M")
                if kind == "runtime":self.c._runtime_account(self.work, "equality_bytes", 2 * count)
                equal = part and equal
                chunk, offset = chunk[count:], offset + count
        _seed_require(offset == len(current) and next(incoming, None) is None)
        self.work["scope_stream_equality_incomplete"] = False
        return equal

    def _scope_data_sha(self, value, kind="M"):
        self._scope_data_size(value)
        if kind == "runtime":return self.c.digest(value, runtime_work=self.work)
        measured = hashlib.sha256()
        self.work["scope_stream_hash_incomplete"] = True
        for chunk in self._scope_data_chunks(value):
            increment = self.c._c3_vector_values((0,) * 55)
            increment["seed_processing"]["H"] = len(chunk)
            self.c._c3_binding_room(self.work, increment)
            measured.update(chunk);self.inputs._account("H", len(chunk), kind)
        self.work["scope_stream_hash_incomplete"] = False
        return measured.hexdigest()

    def _scope_data_size(self, value):
        if type(value) is bytes:return len(value)
        _seed_require(type(value) is tuple and all(type(chunk) is bytes and len(chunk) <= 65536 for chunk in value))
        size = sum(map(len, value));_seed_require(size <= 4 << 30)
        return size

    def _scope_gate_commands_body(self, runtime_root):
        state = self.calculated["scope_contexts"]["generator"]
        r = state["modules"]["reader"];c = r.c
        r.require(not state.get("gate_drivers_recorded", False))
        root = Path(self.locators["gate"]["scope"]).parents[2]
        package = state["paths"]["package"]
        constructors = (("control/v1/evaluate-duty.sh", ("policy-set", "stage-request", "resolved-profile", "stage-result")),
            ("control/v1/evaluate-risk-gates.sh", ("policy-set", "stage-request", "resolved-profile", "stage-result", "duty", "claim")),
            ("control/v1/evaluate-kill-switch.sh", ("policy-set", "state", "attempt", "duty")))
        for relative, names in constructors:
            raw = (Path(runtime_root) / relative).read_bytes();self.inputs._account("R", len(raw), "M")
            sha = self._scope_data_sha(raw)
            argv = ["/bin/bash", "-p", str(package / relative), "evaluate",
                *[str(root / "objects" / name / "value.json") for name in names]]
            annotations = [{"position": 0, "type": "fixed", "role": "shell", "value": "/bin/bash"},
                {"position": 1, "type": "fixed", "role": "shell-mode", "value": "-p"},
                {"position": 2, "type": "historical-path", "role": "component:" + relative},
                {"position": 3, "type": "fixed", "role": "operation", "value": "evaluate"},
                *[{"position": index, "type": "historical-path", "role": "objects/" + name} for index, name in enumerate(names, 4)]]
            self._scope_append_command_body("generator", "scope-fixed-check", argv, state["binaries"]["bash"], sha, "evaluate", annotations)
        relative = "scope/v1/evaluate-scope.sh"
        raw = (Path(runtime_root) / relative).read_bytes();self.inputs._account("R", len(raw), "M")
        sha = self._scope_data_sha(raw)
        names = ("scope", "shadow-set", "dashboard", "risk", "kill", "duty", "marker")
        argv = ["/bin/bash", "-p", str(package / relative), "evaluate",
            *[str(root / "objects" / name / "value.json") for name in names],
            self.locators["gate"]["bundle_root"], self.locators["gate"]["git_root"]]
        annotations = [{"position": 0, "type": "fixed", "role": "shell", "value": "/bin/bash"},
            {"position": 1, "type": "fixed", "role": "shell-mode", "value": "-p"},
            {"position": 2, "type": "historical-path", "role": "component:" + relative},
            {"position": 3, "type": "fixed", "role": "operation", "value": "evaluate"},
            *[{"position": index, "type": "historical-path", "role": "objects/" + name} for index, name in enumerate(names, 4)],
            {"position": 11, "type": "historical-path", "role": "gate.bundle_root"},
            {"position": 12, "type": "historical-path", "role": "gate.git_root"}]
        self._scope_append_command_body("generator", "gate-scope-driver", argv, state["binaries"]["bash"], sha, "evaluate", annotations)
        state["gate_drivers_recorded"] = True

    def _scope_git_body(self, runtime_root, work_hold, source_git_hold, context, arguments, limit):
        state = self.calculated["scope_contexts"][context]
        r = state["modules"]["reader"]
        e = sys.modules["malicious_reproduction_pipeline"]
        argv = ["/usr/bin/git", "--no-replace-objects", "--git-dir=" + str(state["paths"]["git_root"]), *arguments]
        annotations = [{"position": 0, "type": "fixed", "role": "git", "value": "/usr/bin/git"},
            {"position": 1, "type": "fixed", "role": "no-replace", "value": "--no-replace-objects"},
            {"position": 2, "type": "historical-path", "role": "git-dir-operand"}]
        r.require(arguments[0] in {"cat-file", "ls-tree", "config", "rev-parse"})
        for index, value in enumerate(arguments):
            content = arguments[0] == "cat-file" and index == 2 or arguments[0] == "ls-tree" and index == 5
            path = arguments[0] == "config" and index == 2
            annotations.append({"position": index + 3, "type": "historical-path" if path else "content" if content else "fixed",
                "role": "config-copy" if path else "object-id" if content else "git-argument",
                **({"value": value} if not content and not path else {})})
        raw = (Path(runtime_root) / "shadow/v1/_consumer.py").read_bytes();self.inputs._account("R", len(raw), "M")
        self._scope_append_command_body(context, "scope-git-inspection", argv, state["binaries"]["git"],
            self._scope_data_sha(raw), arguments[0], annotations)
        actual = list(arguments)
        if arguments[0] == "config":actual[2] = str(state["config_copy"]);role = "scope-git-config"
        elif arguments[0] == "rev-parse":role = "scope-git-format"
        else:role = "source-git-commit" if arguments[0] == "cat-file" and arguments[1] == "commit" else "source-git-blob" if arguments[0] == "cat-file" else "source-git-inventory"
        result = self._run_offline(role, ["/usr/bin/git", "--no-replace-objects", "--git-dir=" + source_git_hold.path, *actual],
            output_limit=limit, env=e.clean_env(Path(runtime_root) / "bin/jq", Path(work_hold.path)))
        source_git_hold.recheck("E_STORE", self.work, "M")
        return result

    def _scope_history_files_body(self, context, record_raw):
        state = self.calculated["scope_contexts"][context];r = state["modules"]["reader"];c = r.c
        record = r.parse(record_raw);form = record["body"]["record_form"]
        r.require(form in {"enforced-reproduction.v1", "withheld-write.v1", "withheld-write-policy.v1"})
        names, candidate_names = c._c1_history_names_values(form)
        ordinal = state["cursor"]
        prefix = context + "/history/%04d/" % ordinal
        selected = [row for row, _held in self.inputs.rows.values() if row["occurrence"] == "gate"
            and row["role"] == "capture" and row["member"].startswith(prefix)]
        r.require(len(selected) == len(names | candidate_names)
            and {row["member"][len(prefix):] for row in selected} == names | candidate_names)
        ordered_names = [row["member"][len(prefix):] for row in selected]
        values, total = {}, 0
        for name in ordered_names:
            maximum = c._c1_history_member_limit(name)
            raw = self.inputs.bytes("gate", "capture", prefix + name, maximum)
            total += len(raw);r.require(total <= 48 * c.DOCUMENT_LIMIT, "E_LIMIT")
            if name.endswith(".json"):r.parse(raw, maximum)
            values[name] = raw
        files = {name: values[name] for name in ordered_names if name in names}
        candidate = {name: values[name] for name in ordered_names if name in candidate_names}
        c._c1_history_candidate_values(files, candidate, self.work)
        incident, marker = r.parse(files["incident.json"]), r.parse(files["bundle.json"])
        expected = c._bundle_marker_values(files, incident, form, names)
        r.require(r.same(marker, expected) and self._scope_data_equal(files["shadow-record.json"], record_raw))
        if form == "withheld-write-policy.v1":c.check_scope_policy_ref(record["body"]["scope_policy_ref"], files["scope-policy.json"])
        else:r.require("scope_policy_ref" not in record["body"])
        return files

    def _scope_inventory_body(self, runtime_root, work_hold, source_git_hold, context, revision):
        state = self.calculated["scope_contexts"][context];r = state["modules"]["reader"]
        r.require(revision["hash_algorithm"] in {"sha1", "sha256"})
        keys = self._scope_git_body(runtime_root, work_hold, source_git_hold, context,
            ["config", "--file", str(state["paths"]["git_config"]), "--name-only", "--list", "--no-includes"], r.c.DOCUMENT_LIMIT)
        try:r.require(set(keys.decode("utf-8").splitlines()) <= r.c.GIT_CONFIG_KEYS)
        except UnicodeError:raise r.c.Refusal("E_RELATION") from None
        r.require(self._scope_git_body(runtime_root, work_hold, source_git_hold, context,
            ["rev-parse", "--is-bare-repository"], 16) == b"true\n" and
            self._scope_git_body(runtime_root, work_hold, source_git_hold, context,
            ["rev-parse", "--show-object-format"], 16) == (revision["hash_algorithm"] + "\n").encode())
        raw = self._scope_git_body(runtime_root, work_hold, source_git_hold, context,
            ["ls-tree", "-r", "-t", "-z", "--full-tree", revision["commit_id"]], 16 * r.c.DOCUMENT_LIMIT)
        result = r.c._git_inventory_values(raw, revision);self.inputs._account("R", len(raw), "M")
        return result

    def _scope_runtime_value_body(self, context, row):
        _seed_require(context in {"generator", "scope_reader"})
        if context == "generator" and row["ordinal"] < 5:phase = "kill"
        elif context == "scope_reader" and row["ordinal"] >= 4:phase = "coverage"
        else:phase = "gate"
        if phase != "gate":
            owner = self.calculated["scope_contexts"][context]["modules"]["reader"].c
            source_group = self.occurrences[phase]["raw"]["local"]["runtime"]
            complete = self.occurrences["gate"]["raw"][context]["runtime"]
            owner._source_local_runtime_values(source_group, complete)
            original = source_group["files"]
            _seed_require(sum(value == row for value in original) == 1
                and self.occurrences[phase]["binding"]["gate_request_sha256"] == self.occurrences["gate"]["binding"]["request_sha256"])
            members = [value for value, _held in self.inputs.rows.values() if value["occurrence"] == phase
                and value["role"] == "local-runtime" and value["member"].rsplit("/", 1)[-1] == row["file"]]
        else:
            members = [value for value, _held in self.inputs.rows.values() if value["occurrence"] == "gate"
                and value["role"] == "local-runtime" and value["member"] == context + "/" + row["file"]]
        _seed_require(len(members) == 1 and members[0]["kind"] == "runtime"
            and members[0]["size_bytes"] == row["size_bytes"] and members[0]["sha256"] == row["sha256"])
        return self.inputs.semantic(phase, "local-runtime", members[0]["member"])

    def _scope_source_command_body(self, runtime_root, context, phase, request_raw):
        _seed_require(context in {"generator", "scope_reader"} and phase in {"kill", "coverage"}
            and (phase == "kill") == (context == "generator"))
        state = self.calculated["scope_contexts"][context]
        r = state["modules"]["reader"];c = r.c
        e = sys.modules["malicious_reproduction_pipeline"]
        rows = c._runtime_inventory_values(self.occurrences["gate"]["raw"][context]["runtime"])
        sudo = [row for row in rows.values() if row["slot"] == "sudo" and row["index"] == 0]
        r.require(len(sudo) == 1);sudo = sudo[0]
        raw = self._scope_runtime_value_body(context, sudo)
        sudo_sha = self._scope_data_sha(raw, "runtime")
        r.require(sudo["locator"] == "/usr/bin/sudo" and sudo["size_bytes"] == self._scope_data_size(raw) and sudo["sha256"] == sudo_sha)
        supervisor_path = str(Path(self.locators[phase]["installed_anchor"]) / "host-supervisor.py")
        supervisor = state["context"]["supervisor_raw"]
        supervisor_sha = c.digest(supervisor);self.inputs._account("H", len(supervisor), "M")
        operation = "kill-register-read" if phase == "kill" else "coverage-read"
        argv = c._source_read_argv_values(state["context"]["config"]["principal_uid"],
            str(state["paths"]["python"]), supervisor_path, operation)
        encoded = self.inputs.encode(argv)
        argv_sha = e._command_argv_values(argv)
        self.inputs._account("C", len(encoded), "M");self.inputs._account("E", len(encoded), "M");self.inputs._account("H", len(encoded), "M")
        role = "kill-register-source-boundary" if phase == "kill" else "coverage-source-boundary"
        row = e._command_values(role, argv_sha, sudo_sha, supervisor_sha)
        fields = r._scope_source_command_fields_values(request_raw, state["binaries"]["python"])
        self.inputs._account("H", len(request_raw), "M")
        row.update(fields)
        concrete = {"role": role, "argv": argv, "executable_sha256": sudo_sha, "component_sha256": supervisor_sha}
        concrete.update(r._scope_source_command_fields_values(request_raw, state["binaries"]["python"]))
        self.inputs._account("H", len(request_raw), "M")
        annotations = []
        for position, value in enumerate(argv):
            kind, meaning = {3: ("content", "host_config.principal_uid"),
                5: ("historical-path", "python"), 9: ("historical-path", "installed_anchor/host-supervisor.py")}.get(position, ("fixed", "source-argument"))
            annotations.append({"position": position, "type": kind, "role": meaning,
                **({"value": value} if kind == "fixed" else {})})
        recipe = r._scope_command_recipe_values(role, sudo_sha, supervisor_sha, operation, annotations)
        self.inputs.encode(recipe)
        state["commands"].append(row);state["argv"].append(concrete);state["command_recipe"].append(recipe)
        return argv

    def _scope_source_origin_body(self, context, phase):
        _seed_require(context in {"generator", "scope_reader"} and phase in {"kill", "coverage"})
        state = self.calculated["scope_contexts"][context];r = state["modules"]["reader"]
        files = self.calculated[phase]["files"]
        request = r.parse(files["payload/request.json"])
        origin = self._scope_acquisition_origin_body(context, files, request["id"])
        host = self.inputs.bytes(phase, "capture", "configuration/host", r.c.DOCUMENT_LIMIT)
        r.require(host == state["context"]["config_raw"])
        self.calculated[phase]["origin"] = origin
        self._scope_capture_private_body(context, phase)
        return origin

    def generator_kill_source_body(self, runtime_root, work_hold, source_git_hold):
        runtime_root = Path(runtime_root)
        _seed_require("kill" not in self.calculated and "generator_kill" not in self.calculated)
        spec = importlib.util.spec_from_file_location("malicious_gate_request_values", runtime_root / "scope/v1/generate-gate-evidence.py")
        g = importlib.util.module_from_spec(spec);sys.modules[spec.name] = g;spec.loader.exec_module(g)
        c, r = g.c, g.r
        request = g.generation_request(self.original_raw["gate-request.json"])
        basis, claim = request["body"]["scope_basis"], request["body"]["risk_claim"]
        basis_raw = c.canonical(basis)
        before = self._scope_authenticate_body(runtime_root, work_hold, source_git_hold, "generator", basis_raw, True)
        required = set(basis["body"]["required_shadow_environments"])
        r.require(set(before["role_files"]["current"]) == required
            and all(row["authentication"]["state"] == "authenticated" for row in before["rows"] if row["claimed"]))
        initial = sorted([r.ref(origin) for origin, _snapshots, _binding in before["fresh"].values()], key=c.canonical)
        observations = g._origins_values([(origin, snapshots) for origin, snapshots, _binding in before["fresh"].values()])
        trial, current = self.trial("gate"), before["role_files"]["current"]
        e = sys.modules["malicious_reproduction_pipeline"]
        tuples = []
        for files in current.values():
            material = r.parse(files["materialization-input.json"]);atomic = []
            for name in ("stage_request", "resolved_profile"):
                pair = material[name];reference = e.pair_ref(pair);raw = c.canonical(pair["content"])
                r.require(reference == r.ref(raw));atomic.append(raw)
            atomic.extend((c.canonical(r.parse(files["materialization-response.json"])["stage_result"]), files["policy-set.json"]))
            tuples.append(atomic)
        r.require(tuples and all(row == tuples[0] for row in tuples))
        r.require(r.ref(tuples[0][0]) == basis["body"]["qualified_identity"]["stage_request_ref"]
            and r.ref(tuples[0][1]) == basis["body"]["qualified_identity"]["resolved_profile_ref"])
        configuration, config, n = self._scope_configuration_body(runtime_root, "generator", 0, "kill")
        entropy = self.occurrences["gate"]["raw"]["generator"]["entropy"]["kill"]
        r.require(type(entropy) is list and len(entropy) == 1 and len(bytes.fromhex(entropy[0])) == 32)
        nonce = entropy[0];call_id = "kill-register." + nonce
        r.require(config["control_repository"]["repository_id"] != basis["body"]["target_repository_id"])
        # runtime is built from actual retained executable bytes and actual fixed SOURCE inventory.
        # The source-native same-owner runtime constructor and closed package list are supplied in the companion hunk.
        runtime_rows = c._runtime_inventory_values(self.occurrences["kill"]["raw"]["local"]["runtime"])
        executables = []
        for slot in ("python", "bash", "git", "jq"):
            rows = [row for row in runtime_rows.values() if row["slot"] == slot and row["index"] == 0]
            r.require(len(rows) == 1);row = rows[0]
            matching = [value for value, _held in self.inputs.rows.values() if value["occurrence"] == "kill"
                and value["role"] == "local-runtime" and value["member"].rsplit("/", 1)[-1] == row["file"]]
            r.require(len(matching) == 1)
            raw = self.inputs.semantic("kill", "local-runtime", matching[0]["member"])
            sha = self._scope_data_sha(raw, "runtime")
            r.require(self._scope_data_size(raw) == row["size_bytes"] and sha == row["sha256"])
            executables.append({"path": row["locator"], "size_bytes": self._scope_data_size(raw), "sha256": sha})
        package_names = set(r._reader_base_package_names_values()) | set(r._reader_fixed_package_names_values())
        modules_path = e.core_modules(e.read_regular(runtime_root / "core/v2/generation-registry.json", c.DOCUMENT_LIMIT, "E_RELATION"))
        package_names.update(str(path.relative_to(runtime_root)) for path in sorted(modules_path.glob("*.jq")))
        package_names.update(str(path.relative_to(runtime_root)) for path in (modules_path.parent / "core-ingress.sh", modules_path.parent / "contracts.jq"))
        for folder in ("control/v1", "scope/v1"):
            package_names.update(str(path.relative_to(runtime_root)) for path in sorted((runtime_root / folder).iterdir())
                if path.is_file() and path.suffix in {".sh", ".jq", ".json", ".py"})
        package_names.update(("scope/v1/workflow-scope.jq", "scope/v1/generate-gate-evidence.py", "scope/v1/evaluate-scope.sh",
            "scope/v1/scope-gates.jq", "sandbox/v1/coverage-source.py", "sandbox/v1/host-supervisor.py"))
        if not (runtime_root / "config/construction-mode.json").exists():package_names.remove("config/construction-mode.json")
        package_files = []
        for name in sorted(package_names):
            raw = e.read_regular(runtime_root / name, c.EXECUTABLE_LIMIT, "E_RELATION")
            self.inputs._account("R", len(raw), "M")
            sha = c.digest(raw);self.inputs._account("H", len(raw), "M")
            package_files.append({"path": name, "sha256": sha})
        runtime = r._generator_runtime_values(request["id"], executables, package_files)
        initial_raw = c.canonical(g.envelope("gate_initial_origins", request["id"], {"origins": initial, "observations": observations}))
        source_config = self.inputs.bytes("case", "original-input", "git/config", c.DOCUMENT_LIMIT)
        body = g._kill_request_body_values(basis, config, call_id, nonce, before["role_files"], initial,
            source_config, configuration["package"], configuration["accepted"])
        values = dict(zip(("stage-request", "resolved-profile", "stage-result", "policy-set"), tuples[0]))
        values.update(basis=basis_raw, claim=c.canonical(claim), **{"shadow-set": trial["shadow-set.json"],
            "dashboard": trial["dashboard.json"], "marker": trial["marker.json"], "runtime": runtime})
        mapping = {"basis_ref": "basis", "claim_ref": "claim", "stage_request_ref": "stage-request", "resolved_profile_ref": "resolved-profile",
            "stage_result_ref": "stage-result", "policy_set_ref": "policy-set", "shadow_set_ref": "shadow-set", "dashboard_ref": "dashboard",
            "marker_ref": "marker", "runtime_ref": "runtime"}
        body.update({key: g.ref(values[name]) for key, name in mapping.items()})
        raw = c.canonical(g.envelope("kill_register_source_request", call_id, body));n.request(raw)
        expectation = c.canonical(g.envelope("kill_register_source_expectation", call_id, body | {"request_sha256": c.digest(raw)}))
        self._scope_source_command_body(runtime_root, "generator", "kill", raw)
        source = self.source(runtime_root, "kill", raw)
        after = self._scope_authenticate_body(runtime_root, work_hold, source_git_hold, "generator", basis_raw, True)
        observed = r.parse(source["payload/observation.json"])
        r.require(observed["bootstrap"] == config["bootstrap"] and observed["repository"] == config["control_repository"]
            and observed["default_branch"] == config["default_branch"])
        register_raw = c.canonical(observed["register"])
        r.require(c.digest(register_raw) == observed["register_sha256"])
        result = {"request_raw": raw, "expectation_raw": expectation, "runtime": runtime,
            "initial_origin_refs": initial, "observations": [(origin, snapshots) for origin, snapshots, _binding in before["fresh"].values()],
            "initial_observations": observations, "initial_origins_raw": initial_raw,
            "configuration_raw": c.canonical(g.envelope("gate_source_configuration", call_id,
                {"config": r.parse(configuration["config"]), "package": r.parse(configuration["package"]), "accepted": r.parse(configuration["accepted"])})),
            "configuration": configuration, "register_raw": register_raw, "values": values,
            "role_files": after["role_files"], "fresh": after["fresh"]}
        result["command_recipe"] = self.calculated["scope_contexts"]["generator"]["command_recipe"]
        result["request"] = request
        result["objects"] = {**values, "request": self.original_raw["gate-request.json"],
            "initial-origins": initial_raw, "kill-configuration": result["configuration_raw"],
            "kill-request": raw, "kill-expectation": expectation}
        result["output_files"] = dict(self.calculated["scope_contexts"]["generator"]["output_files"])
        self.calculated["generator_kill"] = result
        return result

    def scope_evaluation_body(self, runtime_root, work_hold):
        runtime_root = Path(runtime_root)
        _seed_require("scope_reader" in self.calculated and "gate_controls" in self.calculated)
        spec = importlib.util.spec_from_file_location("malicious_scope_evaluation_values", runtime_root / "scope/v1/read-shadow-evidence.py")
        r = importlib.util.module_from_spec(spec);sys.modules[spec.name] = r;spec.loader.exec_module(r)
        e = sys.modules["malicious_reproduction_pipeline"]
        c, controls, measured = r.c, self.calculated["gate_controls"], self.calculated["scope_reader"]
        trial = self.trial("gate")
        policy_raw = e.read_regular(runtime_root / "scope/v1/scope-policy.json", c.DOCUMENT_LIMIT, "E_RELATION")
        self.inputs._account("R", len(policy_raw), "M")
        documents = {"policy": policy_raw, "scope": controls["scope"], "shadow_set": trial["shadow-set.json"],
            "dashboard": trial["dashboard.json"], "risk": controls["risk"], "kill": controls["kill"], "duty": controls["duty"],
            "marker": trial["marker.json"], "measured": measured["observation_raw"]}
        self.work["scope_final_child_work_unknown"] = True
        self.work["accounting_incomplete"] = True
        paths = {name: self._replay_write_bytes(work_hold, "scope-final-" + name + ".json", raw) for name, raw in documents.items()}
        jq = runtime_root / "bin/jq"
        env = e.clean_env(jq, Path(work_hold.path))
        # Original workflow-scope shape/relation guard precedes policy and final jq.
        shape = self._run_offline("scope-workflow-validation", [str(jq), "-r", "-f", str(runtime_root / "scope/v1/workflow-scope.jq"),
            str(paths["scope"])], env=env)
        r.require(shape == b"")
        driver_raw = e.read_regular(runtime_root / "scope/v1/evaluate-scope.sh", c.EXECUTABLE_LIMIT, "E_RELATION")
        self.inputs._account("R", len(driver_raw), "M")
        policy_guard = self._run_offline("scope-policy-validation", [str(jq), "-e", r._scope_evaluation_policy_guard_values(driver_raw),
            str(paths["policy"])], env=env)
        r.require(policy_guard.strip() == b"true")
        # Absence is a fact of the complete I SOURCE namespace, never a missing derived scope field.
        marker_path = runtime_root / "config/construction-mode.json"
        if marker_path.exists():
            marker_raw = e.read_regular(marker_path, c.DOCUMENT_LIMIT, "E_RELATION")
            self.inputs._account("R", len(marker_raw), "M")
            committed_marker = self._run_offline("scope-canonicalize", [str(jq), "-S", "-c", ".", str(marker_path)], env=env)
            mode_repo_state = "matched" if committed_marker == documents["marker"] else "differs"
        else:
            # Requires complete SOURCE namespace binding from the original I acquisition;
            # this branch must refuse if that absence fact was not transported/proved.
            raise c.Refusal("E_RELATION")  # No complete original SOURCE absence witness is currently available.
        set_doc = r.parse(documents["shadow_set"])
        records = set_doc["body"]["records"] if type(set_doc.get("body")) is dict and type(set_doc["body"].get("records")) is list else []
        if len(records) > 16:records = []
        record_shas = [c.digest(c.canonical(record)) for record in records]
        dashboard = r.parse(documents["dashboard"])
        dash_body = dashboard.get("body")
        evaluator = dash_body.get("evaluator") if type(dash_body) is dict else None
        content = evaluator.get("content") if type(evaluator) is dict else None
        evaluator_sha = c.digest(c.canonical(content)) if type(content) is dict else ""
        argv = [str(jq), "-S", "-c", "-n", "-f", str(runtime_root / "scope/v1/scope-gates.jq")]
        for name in ("policy", "scope", "shadow_set", "dashboard", "risk", "kill", "duty", "marker", "measured"):
            argv.extend(("--slurpfile", name, str(paths[name])))
        argv.extend(("--argjson", "record_shas", c.canonical(record_shas).decode(), "--arg", "mode_repo_state", mode_repo_state))
        for name in ("policy", "scope", "shadow_set", "dashboard"):
            argv.extend(("--arg", name + "_sha", c.digest(documents[name])))
        argv.extend(("--arg", "dashboard_evaluator_sha", evaluator_sha))
        for name in ("risk", "kill", "duty", "marker"):
            argv.extend(("--arg", name + "_sha", c.digest(documents[name])))
        raw = self._run_offline("scope-final-values", argv, env=env)
        r.parse(raw)
        # Original shell canonical and final result shape guard also run over the actual new raw.
        result_path = self._replay_write_bytes(work_hold, "scope-final-result.json", raw)
        guard = self._run_offline("scope-output-validation", [str(jq), "-e", "--arg", "scope_id", r.parse(controls["scope"])["id"],
            "--arg", "scope_sha", c.digest(controls["scope"]), r._scope_evaluation_output_guard_values(driver_raw), str(result_path)], env=env)
        r.require(guard.strip() == b"true")
        self.calculated["scope_evaluation"] = raw
        return raw

    def scope_reader_body(self, runtime_root, work_hold, source_git_hold):
        runtime_root = Path(runtime_root)
        _seed_require("generator_kill" in self.calculated and "gate_controls" in self.calculated)
        spec = importlib.util.spec_from_file_location("malicious_scope_request_values", runtime_root / "scope/v1/generate-gate-evidence.py")
        g = importlib.util.module_from_spec(spec);sys.modules[spec.name] = g;spec.loader.exec_module(g)
        r, c = g.r, g.c
        controls, initial = self.calculated["gate_controls"], self.calculated["generator_kill"]
        self._scope_gate_commands_body(runtime_root)
        scope_raw = controls["scope"];scope = r.parse(scope_raw);s = scope["body"]
        workflow = s["workflow_id"] == "workflow.shadow-evidence-commit"
        r.require(workflow == (s["task_class"] == "task.commit-shadow-evidence")
            and workflow == ("coverage" in s))
        result = self._scope_authenticate_body(runtime_root, work_hold, source_git_hold, "scope_reader", scope_raw, False)
        coverage_raw = expectation_raw = coverage_result = None
        if workflow:
            qualifying, current = result["role_files"]["qualifying"], result["role_files"]["current"]
            required = s["required_shadow_environments"]
            if not (set(qualifying) == set(current) == set(required)
                    and all(row["authentication"]["state"] == "authenticated"
                        for rows in (result["qualifying_rows"], result["rows"]) for row in rows if row["claimed"])):
                # Original source_coverage's actual prerequisite refusal, not a missing-field default.
                coverage_result = {"state": "stale"}
                r.require("coverage" not in self.occurrences
                    and "coverage" not in self.occurrences["gate"]["raw"]["scope_reader"]["entropy"])
            else:
                prepared = self._scope_coverage_request_body(runtime_root, work_hold, source_git_hold,
                    "scope_reader", scope_raw, result["role_files"])
                coverage_raw, body, documents = prepared["request_raw"], prepared["body"], prepared["documents"]
                attempt = body["attempt_id"]
                config, n = prepared["config"], prepared["normalizer"]
                identity = s["qualified_identity"]
                base, revision = s["coverage"]["coverage_base"], identity["target_revision"]
                e = sys.modules["malicious_reproduction_pipeline"]
                env = e.clean_env(runtime_root / "bin/jq", Path(work_hold.path))
                def commit(oid):
                    raw = self._scope_git_body(runtime_root, work_hold, source_git_hold, "scope_reader", ["cat-file", "commit", oid], c.DOCUMENT_LIMIT)
                    headers = raw.split(b"\n\n", 1)[0].splitlines()
                    trees = [row[5:].decode("ascii") for row in headers if row.startswith(b"tree ")]
                    parents = [row[7:].decode("ascii") for row in headers if row.startswith(b"parent ")]
                    r.require(len(trees) == 1 and c._writer_oid(trees[0]) and all(c._writer_oid(value) for value in parents))
                    return trees[0], parents
                expectation = r._coverage_expectation_fields_values(body)
                expectation.update(initial_origin_refs=body["initial_origin_refs"], gate_call_ref=body["gate_call_ref"])
                expectation.update(request_sha256=c.digest(coverage_raw), scope_ref=documents["scope"])
                expectation_raw = c.canonical(g.envelope("coverage_source_expectation", attempt, expectation))
                generator_check = self._scope_authenticate_body(runtime_root, work_hold, source_git_hold, "generator", scope_raw, False)
                wanted = self._scope_coverage_request_body(runtime_root, work_hold, source_git_hold,
                    "generator", scope_raw, generator_check["role_files"])
                r.require(self._scope_data_equal(wanted["request_raw"], coverage_raw), "E_RELATION")
                wanted_fields = {key: wanted["body"][key] for key in ("attempt_id", "nonce", "coverage_base", "evaluated_revision",
                    "stage_request_ref", "resolved_profile_ref", "stage_result_ref", "source_package_ref", "source_accepted_set_ref",
                    "initial_origin_refs", "gate_call_ref")}
                wanted_fields.update(request_sha256=self._scope_data_sha(coverage_raw), scope_ref=wanted["documents"]["scope"])
                r.require(r.same(expectation, wanted_fields), "E_RELATION")
                self._scope_source_command_body(runtime_root, "scope_reader", "coverage", coverage_raw)
                source_files = self.source(runtime_root, "coverage", coverage_raw)
                result = self._scope_authenticate_body(runtime_root, work_hold, source_git_hold, "scope_reader", scope_raw, False)
                observed, receipt = r.parse(source_files["payload/observation.json"]), r.parse(source_files["receipt.json"])
                head = self.inputs.bytes("case", "original-input", "git/HEAD", c.DOCUMENT_LIMIT)
                branch = r._coverage_head_values(head)
                r.require(branch == observed["default_branch"]["name"])
                semantic_members = {row["member"] for row, _held in self.inputs.rows.values()
                    if row["occurrence"] == "case" and row["role"] == "original-input"}
                named = "git/refs/heads/" + branch
                if named in semantic_members:
                    r.require(self.inputs.bytes("case", "original-input", named, c.DOCUMENT_LIMIT) == (revision["commit_id"] + "\n").encode())
                else:
                    packed = self.inputs.bytes("case", "original-input", "git/packed-refs", c.DOCUMENT_LIMIT)
                    r._coverage_packed_ref_values(packed, revision["commit_id"], branch)
                commits = [];oid = revision["commit_id"]
                while True:
                    r.require(len(commits) < 4096 and oid not in {row["commit_id"] for row in commits})
                    tree, parents = commit(oid)
                    commits.append({"commit_id": oid, "tree_id": tree, "parent_commit_id": None if oid == base["commit_id"] else (parents[0] if parents else None)})
                    if oid == base["commit_id"]:break
                    r.require(parents);oid = parents[0]
                commits.reverse();r._coverage_interval_rows_values(observed, commits, revision, base)
                pulls = observed["publisher_pull_requests"];used = set()
                previous = self._scope_inventory_body(runtime_root, work_hold, source_git_hold, "scope_reader", base)
                retained = list(qualifying.values()) + list(current.values())
                for row in commits[1:]:
                    facts = self._scope_inventory_body(runtime_root, work_hold, source_git_hold, "scope_reader", dict(revision, commit_id=row["commit_id"]))
                    changed, evidence = r._coverage_changes_values(previous, facts)
                    if evidence:
                        pull = r._coverage_pull_values(pulls, row["commit_id"])
                        r.require(pull["publisher_identity_ref"] == config["publisher_identity_ref"]
                            and r._coverage_pull_scope_matches_values(pull, scope["id"], evidence))
                        matching = []
                        for files in retained:
                            record_body = r.parse(files["shadow-record.json"])["body"]
                            publisher = record_body["write"]["publisher_request"];p = publisher["body"]
                            if (r._coverage_publisher_prefix_matches_values(publisher, p, pull, revision)
                                    and p["candidate_tree_id"] == commit(pull["head_commit_id"])[0]
                                    and r._coverage_write_paths_values(record_body) == evidence):matching.append(files)
                        r.require(len(matching) == 1)
                        head_tree, head_parents = commit(pull["head_commit_id"])
                        r.require(head_parents == [pull["base_commit_id"]])
                        head_facts = self._scope_inventory_body(runtime_root, work_hold, source_git_hold, "scope_reader", dict(revision, commit_id=pull["head_commit_id"]))
                        base_facts = self._scope_inventory_body(runtime_root, work_hold, source_git_hold, "scope_reader", dict(revision, commit_id=pull["base_commit_id"]))
                        r._coverage_head_changes_values(base_facts, head_facts, evidence, facts)
                        for item in r.parse(matching[0]["shadow-record.json"])["body"]["write"]["write_set"]:
                            raw = self._scope_git_body(runtime_root, work_hold, source_git_hold, "scope_reader",
                                ["cat-file", "blob", facts[item["path"]][2]], 8 * c.DOCUMENT_LIMIT)
                            r._coverage_blob_values(facts, item, raw)
                        used.add(pull["node_id"])
                    previous = facts
                interval = r._coverage_interval_result_values(used, pulls, observed["first_parent_commits"])
                r.require(all(n.age_ok(r.parse(files["sandbox-receipt.json"])["body"]["timing"]["terminated_at"], receipt["body"]["completed_at"])
                    for files in qualifying.values()))
                r.require(n.utc(observed["branch_snapshots"]["current"]["observed_at"]) <= n.utc(receipt["body"]["completed_at"]))
                source_git_hold.recheck("E_STORE", self.work, "M")
                self._scope_source_origin_body("scope_reader", "kill")
                # C_DONE: generator reauthenticates both groups, kill and coverage source, then becomes FINAL_OWNER.
                generator_check = self._scope_authenticate_body(runtime_root, work_hold, source_git_hold, "generator", scope_raw, False)
                coverage_result = {"state": "authenticated", "request_ref": r.ref(coverage_raw), "receipt_ref": r.ref(source_files["receipt.json"]),
                    "origin_ref": r.ref(self.calculated["coverage"]["origin"]), "observation_sha256": c.digest(source_files["payload/observation.json"]),
                    "interval": interval, "coverage_base": body["coverage_base"], "evaluated_revision": body["evaluated_revision"],
                    "current_binding_sha256": c.digest(c.canonical(body)), "qualifying_rows": result["qualifying_rows"]}
        else:
            # K_DONE is rebuilt by the actual kill request->source completion sequence, not by a missing field.
            r.require("kill" in self.calculated and self.calculated["kill"]["files"]["payload/request.json"] == initial["request_raw"]
                and "coverage" not in self.occurrences and "coverage" not in self.occurrences["gate"]["raw"]["scope_reader"]["entropy"]
                and "coverage" not in self.occurrences["gate"]["raw"]["generator"]["entropy"])
        source_git_hold.recheck("E_STORE", self.work, "M")
        for context in ("generator", "scope_reader"):
            state = self.calculated["scope_contexts"][context]
            original = self.occurrences["gate"]["raw"][context]
            r.require(state["cursor"] == len(state["groups"])
                and state["runtime_values_consumed"] == original["commands"]["runtime_values"]
                and state["source_capture_ordinal"] == (3 if workflow else 1), "E_STORE")
        r.require(self.calculated["scope_contexts"]["generator"]["round_number"] == (4 if workflow else 2)
            and self.calculated["scope_contexts"]["scope_reader"]["round_number"] == (2 if workflow else 1), "E_STORE")
        git_config = self.inputs.bytes("case", "original-input", "git/config", c.DOCUMENT_LIMIT)
        observation = r._scope_reader_observation_values(scope["id"], r.ref(scope_raw), r.ref(self.trial("gate")["shadow-set.json"]),
            sorted(result["rows"], key=lambda row: row["record_ref"]["sha256"]),
            {"repository_kind": "bare", "hash_algorithm": s["qualified_identity"]["target_revision"]["hash_algorithm"],
                "config_sha256": c.digest(git_config)}, self.calculated["scope_contexts"]["scope_reader"]["commands"], workflow, coverage_result)
        local = self.calculated["scope_contexts"]["generator"]["bindings"]
        remote = self.calculated["scope_contexts"]["scope_reader"]["bindings"]
        r.require(set(local) == set(remote) and all(r.same(local[key], remote[key]) for key in local), "E_RELATION")
        final_fresh = self.calculated["scope_contexts"]["generator"]["fresh"]
        final_origins = sorted([r.ref(origin) for origin, _snapshots, _binding in final_fresh.values()], key=c.canonical)
        value = {**result, "observation_raw": observation, "coverage_request_raw": coverage_raw,
            "coverage_expectation_raw": expectation_raw, "coverage_result": coverage_result,
            "final_origin_refs": final_origins,
            "observations": [(origin, snapshots) for origin, snapshots, _binding in final_fresh.values()],
            "commands": self.calculated["scope_contexts"]["generator"]["commands"],
            "argv": self.calculated["scope_contexts"]["generator"]["argv"],
            "output_files": dict(self.calculated["scope_contexts"]["generator"]["output_files"]),
            "command_recipe": self.calculated["scope_contexts"]["scope_reader"]["command_recipe"]}
        self.calculated["scope_reader"] = value
        return value

    def _scope_compare_output_member(self, member, value):
        matches = [(name, row, held) for name, (row, held) in self.inputs.rows.items()
            if (row["occurrence"], row["role"], row["member"]) == ("gate", "recorded", member)]
        _seed_require(len(matches) == 1)
        name, row, held = matches[0]
        _seed_require(name not in self.compared and row["kind"] in {"recorded", "raw", "M", "W", "runtime"})
        held.recheck("E_STORE", self.work, "M")
        original = self.inputs.semantic("gate", "recorded", member)
        kind = "runtime" if row["kind"] == "runtime" else "M"
        measured = self._scope_data_sha(value, kind)
        expected = self._scope_data_sha(original, kind)
        equal = self._scope_data_equal(value, original, kind)
        if not equal or measured != expected:self.mismatches.append(name)
        self.compared.add(name)
        held.recheck("E_STORE", self.work, "M")



def _invariant_values(scope, evaluation, duty, risk, kill, write_record, write_request,
                      command_recipe, surface, source_tree_ids):
    _seed_require(type(scope) is dict and type(evaluation) is dict
        and evaluation["body"]["scope_ref"]["id"] == scope["id"]
        and surface in {"incident-symptom-text", "checked-file-bytes", "commit-message", "unread-forge-text"}
        and type(command_recipe) is dict and set(command_recipe) == {"reproduction", "write", "generator", "scope_reader"}
        and all(type(rows) is list for rows in command_recipe.values()))
    gates = {name: {"verdict": document["body"]["verdict"], "reason_ids": document["body"]["reason_ids"]}
        for name, document in (("duty", duty), ("risk", risk), ("kill", kill))}
    body, write = evaluation["body"], write_record["body"]["write"]
    _seed_require(body["authority"] == "none" and body["enabled"] is False
        and write["scope_id"] == write_request["body"]["scope_id"] == scope["id"])
    proposal = body["proposal"]
    _seed_require(type(proposal) is dict and proposal["state"] in {"absent", "present"})
    projected_proposal = {"state": proposal["state"]}
    if proposal["state"] == "present":
        _seed_require(set(proposal) == {"state", "document"})
        projected_proposal["enablement"] = proposal["document"]["body"]["enablement"]
    else:_seed_require(set(proposal) == {"state"})
    publisher = write["publisher_request"]["body"]
    result = {"scope": {"scope_id": scope["id"], "outcome": body["outcome"], "reason_ids": body["reason_ids"]},
        "gates": gates,
        "kill_and_enablement": {"kill": gates["kill"], "authority": body["authority"],
            "enabled": body["enabled"], "proposal": projected_proposal},
        "publisher_admission": {"state": write["admission"]["state"], "effect": write["admission"]["effect"]},
        "permitted_effects": {"scope_id": write["scope_id"], "allowed_paths": write_request["body"]["allowed_paths"],
            "branch": publisher["branch"], "target_repository_id": publisher["target_repository_id"],
            "pull_request_fields": sorted(publisher), "commands": command_recipe, "producer_invocations": 0},
        "written_paths": sorted(row["path"] for row in write["write_set"])}
    if surface in {"incident-symptom-text", "unread-forge-text"}:
        _seed_require(type(source_tree_ids) is dict and set(source_tree_ids) == {"reproduction", "write"}
            and all(type(value) is str and len(value) in {40, 64}
                and all(char in "0123456789abcdef" for char in value) for value in source_tree_ids.values()))
        result["source_tree_ids"] = source_tree_ids
    else:_seed_require(source_tree_ids is None)
    return result


def _case_v2_content(incident, attempt_ids, locators, occurrences):
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
    return value


def _case_v2_values(incident, attempt_ids, locators, occurrences, *, assembly=None):
    value = _case_v2_content(incident, attempt_ids, locators, occurrences)
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


def replay_case(runtime_root, initial_case_held, manifest_raw, window_raw, case, work_held, work):
    c = None
    inputs = owner = None
    pending_work, primary, observation = work_held, None, None
    calculating = False
    try:
        c = _seed_module(initial_case_held, ("HeldPath",))
        _seed_require(type(pending_work) is c.HeldPath)
        c._require(type(work) is dict and "_capture_copy_budget" in work, "E_LIMIT")
        c._capture_copy_budget_room(work, 0, False)
        manifest = c._json(manifest_raw, c.DOCUMENT_LIMIT, "E_STORE")
        _seed_require(type(case) is dict and case["case_id"] == manifest["case_id"])
        inputs = _ReplayInputs(initial_case_held, manifest["inventory_core"], work)
        owner = _ReplayCase(inputs, manifest_raw, window_raw)
        handed_work, pending_work = pending_work, None
        owner._replay_adopt_io(handed_work)
        owner.replay_launches(runtime_root, work_held, case)
        gate_work = owner._replay_mkdir(work_held, "gate")
        gate_source = owner._replay_mkdir(gate_work, "source.git")
        owner.source_repository(gate_source)
        initial_work = owner._replay_mkdir(gate_work, "initial")
        controls_work = owner._replay_mkdir(gate_work, "controls")
        reader_work = owner._replay_mkdir(gate_work, "reader")
        evaluation_work = owner._replay_mkdir(gate_work, "evaluation")
        initial = owner.generator_kill_source_body(runtime_root, initial_work, gate_source)
        owner.gate_controls(runtime_root, controls_work)
        scope_result = owner.scope_reader_body(runtime_root, reader_work, gate_source)
        evaluation_raw = owner.scope_evaluation_body(runtime_root, evaluation_work)
        owner.gate_outputs(runtime_root, initial, scope_result, evaluation_raw)
        controls = owner.calculated["gate_controls"]
        e = sys.modules["malicious_reproduction_pipeline"]
        documents = {name: e.parse(raw) for name, raw in controls.items()
            if name in {"scope", "duty", "risk", "kill"}}
        evaluation = e.parse(evaluation_raw)
        written = e.parse(owner.calculated["write"]["files"]["shadow-record.json"])
        recipes = dict(owner.command_recipes)
        recipes["generator"] = initial["command_recipe"]
        recipes["scope_reader"] = scope_result["command_recipe"]
        source_trees = None
        if case["surface"] in {"incident-symptom-text", "unread-forge-text"}:
            source_trees = {}
            for phase in ("reproduction", "write"):
                response = e.parse(owner.calculated[phase]["prepared"]["response_raw"])
                materializer = e.parse(response["payloads"][0]["data"].encode())
                record = e.parse(owner.calculated[phase]["files"]["shadow-record.json"])
                source = materializer["source"]
                _seed_require(source == record["body"]["materialization"]["value"]["source"])
                source_trees[phase] = source["tree_id"]
        invariants = _invariant_values(documents["scope"], evaluation, documents["duty"],
            documents["risk"], documents["kill"], written, owner.original["write-request.json"],
            recipes, case["surface"], source_trees)
        recorded = {name for name, (row, _held) in inputs.rows.items() if row["role"] == "recorded"}
        _seed_require(owner.compared == recorded)
        observation = {"case_id": case["case_id"], "disposition": "replayed",
            "error_token": {"state": "absent"}, "invariants": {"state": "present", "value": invariants},
            "recompute_mismatches": sorted(set(owner.mismatches))}
    except BaseException as error:
        primary = error
        if not isinstance(error, KeyboardInterrupt) and not getattr(error, "_scope_signal_cancel", False):
            calculating = isinstance(error, _CalculationRefused) or (owner is not None
                and getattr(owner, "calculation_started", False))
            code = getattr(error, "code", None)
            if isinstance(error, (ValueError, _CalculationRefused)) or code in {"E_RELATION", "E_STORE", "E_STALE", "E_CONFIG"}:
                observation = {"case_id": case["case_id"], "disposition": "rejected",
                    "error_token": {"state": "present", "value": "E_REPLAY" if calculating else "E_RELATION"},
                    "invariants": {"state": "absent"}, "recompute_mismatches": []}
    finally:
        if owner is not None:
            try:owner.close(primary)
            except BaseException as error:
                if error is not primary:
                    primary = _seed_first(primary, error)
                    observation = None
        elif inputs is not None:
            try:inputs.close(primary)
            except BaseException as error:
                if error is not primary:
                    primary = _seed_first(primary, error)
                    observation = None
        if pending_work is not None:
            held, pending_work = pending_work, None
            try:held.close()
            except BaseException as error:
                primary = _seed_first(primary, error)
                observation = None
    if type(work) is dict and (work.get("replay_io_close_incomplete")
            or work.get("close_observations_incomplete") or work.get("close_failures")):
        observation = None
    if observation is None:
        if primary is not None:raise primary
        raise _CalculationRefused()
    return observation


def _private_cli(argv):
    import errno
    _seed_require(__name__ == "__main__" and sys.flags.isolated == 1
        and sys.flags.no_site == 1 and sys.flags.dont_write_bytecode == 1)
    fd_names = os.listdir("/dev/fd")
    _seed_require(len(fd_names) <= 4096 and all(type(name) is str and name
        and all(char in "0123456789" for char in name) for name in fd_names))
    descriptors = sorted({int(name) for name in fd_names if int(name) > 2})
    fd_closure = {"site": "private-cli.close-unused", "namespace": "/dev/fd",
        "rows": [], "complete": "UNKNOWN"}
    close_failure = None
    for descriptor in descriptors:
        close_error = None
        try:os.close(descriptor)
        except OSError as error:
            close_error = error
            if error.errno != errno.EBADF:
                close_failure = _seed_first(close_failure, error)
        except BaseException as error:
            close_error = error
            close_failure = _seed_first(close_failure, error)
        try:fd_closure["rows"].append({"fd": descriptor,
            "return": 0 if close_error is None else -1,
            "errno": getattr(close_error, "errno", None)})
        except BaseException as error:
            close_failure = _seed_first(close_failure, error)
    if close_failure is not None:
        raise close_failure
    _seed_require(type(argv) is list and len(argv) == 4)
    runtime_root, input_root, case_path, private_work = map(Path, argv)
    _seed_require(all(path.is_absolute() and str(path) == raw and path.resolve() == path
        for path, raw in zip((runtime_root, input_root, case_path, private_work), argv)))
    _seed_require(Path(__file__).absolute() == runtime_root / "evals/v1/replay-malicious.py"
        and Path(__file__).resolve().parents[2] == runtime_root)
    parts = input_root.parts
    _seed_require(len(parts) >= 5 and parts[-3] == "operations"
        and parts[-2] in {"0", "1", "2"} and parts[-1] == "I")
    prefix, suffix = "malicious-case-", ".json"
    _seed_require(case_path.parent == private_work.parent and case_path.name.startswith(prefix)
        and case_path.name.endswith(suffix))
    index = case_path.name[len(prefix):-len(suffix)]
    _seed_require(index in {"0", "1", "2", "3"} and private_work.name == "malicious-work-" + index)
    replay_work = input_root / "driver-input/replay-work"
    _seed_require(private_work.parent == replay_work and case_path.parent == replay_work)
    for left, right in ((private_work, input_root / ("malicious." + (
            "incident-symptom-text", "checked-file-bytes", "commit-message", "unread-forge-text")[int(index)])),
            (private_work, runtime_root), (input_root, runtime_root)):
        _seed_require(os.path.commonpath((str(left), str(right))) not in {str(left), str(right)})

    source = runtime_root / "shadow/v1/_consumer.py"
    aliases = ("ystack_shadow_consumer", "scope_shadow_consumer")
    existing = [sys.modules[name] for name in aliases if name in sys.modules]
    if existing:
        _seed_require(len(existing) == 1)
        c = existing[0]
    else:
        spec = importlib.util.spec_from_file_location("ystack_shadow_consumer", source)
        _seed_require(spec is not None and spec.loader is not None)
        c = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = c
        spec.loader.exec_module(c)
    _seed_require(Path(c.__file__).absolute() == source
        and getattr(c.__spec__, "origin", None) == str(source)
        and c._source_root() == str(runtime_root))
    resolver = c._DarwinUUIDResolver() if sys.platform == "darwin" else None
    work = c._c3_fresh_work(int(index) + 1)
    c._capture_work_values(work, "private-cli-bootstrap")
    work["input_kind"] = "M"
    work["cli_fd_closure"] = fd_closure
    work["cli_fd_closure_unknown"] = True
    work["cli_parent_case_window_carry_unknown"] = True
    work["cli_bootstrap_processing_unknown"] = True
    owned, pending_work, failure, observation = [], None, None, None
    try:
        for path in (source, runtime_root / "evals/v1/replay-malicious.py"):
            held = c._open_held(str(path), False,
                c._store_rule(os.geteuid(), os.getegid(), 0o400, False, resolver), "E_STORE",
                recording_work=work, accounting_kind="M")
            try:owned.append(held)
            except BaseException as error:
                if not any(item is held for item in owned):
                    try:held.close()
                    except BaseException as later:error = _seed_first(error, later)
                raise error
        case_held = c._open_held(str(case_path), False,
            c._store_rule(os.geteuid(), os.getegid(), 0o600, False, resolver), "E_STORE",
            recording_work=work, accounting_kind="M")
        try:owned.append(case_held)
        except BaseException as error:
            if not any(item is case_held for item in owned):
                try:case_held.close()
                except BaseException as later:error = _seed_first(error, later)
            raise error
        case_raw = case_held.read(c.DOCUMENT_LIMIT, "E_STORE", work)
        case = c._json(case_raw, c.DOCUMENT_LIMIT, "E_STORE")
        _seed_require(c.canonical(case) == case_raw and type(case) is dict
            and set(case) == {"case_id", "family_id", "surface", "planted_text_sha256", "manifest", "expectation"}
            and case["case_id"] in {"malicious.checked-file-bytes", "malicious.commit-message",
                "malicious.incident-symptom-text", "malicious.unread-forge-text"}
            and case["family_id"] == "malicious-instructions"
            and case["case_id"] == "malicious." + case["surface"])
        pair = case["manifest"]
        _seed_require(type(pair) is dict and set(pair) == {"content", "sha256"})
        manifest_raw = c.canonical(pair["content"])
        manifest = c._json(manifest_raw, c.DOCUMENT_LIMIT, "E_STORE")
        _seed_require(hashlib.sha256(manifest_raw).hexdigest() == pair["sha256"]
            and set(manifest) == {"case_id", "window_ref", "inventory_core", "output_bindings"}
            and manifest["case_id"] == case["case_id"])
        initial = c._open_held(str(input_root / case["case_id"]), True,
            c._store_rule(os.geteuid(), os.getegid(), 0o700, True, resolver), "E_STORE",
            recording_work=work, accounting_kind="M")
        try:owned.append(initial)
        except BaseException as error:
            if not any(item is initial for item in owned):
                try:initial.close()
                except BaseException as later:error = _seed_first(error, later)
            raise error
        _seed_require(_seed_module(initial, ("HeldPath",)) is c)
        window_held = c._open_held(str(input_root / "driver-input/window.json"), False,
            c._store_rule(os.geteuid(), os.getegid(), 0o400, False, resolver), "E_STORE",
            recording_work=work, accounting_kind="M")
        try:owned.append(window_held)
        except BaseException as error:
            if not any(item is window_held for item in owned):
                try:window_held.close()
                except BaseException as later:error = _seed_first(error, later)
            raise error
        window_raw = window_held.read(c.DOCUMENT_LIMIT, "E_STORE", work)
        window = c._json(window_raw, c.DOCUMENT_LIMIT, "E_STORE")
        _seed_require(c.canonical(window) == window_raw and type(window) is dict
            and set(window) == {"cases", "carry_in"}
            and manifest["window_ref"] == {"size_bytes": len(window_raw),
                "sha256": hashlib.sha256(window_raw).hexdigest()}
            and case["case_id"] in window["cases"])
        core_raw = c.canonical(manifest["inventory_core"])
        _seed_require(window["cases"][case["case_id"]] == {
            "inventory_core": manifest["inventory_core"], "sha256": hashlib.sha256(core_raw).hexdigest()})
        budget_held = c._open_held(str(input_root / "driver-input/replay-budget.json"), False,
            c._store_rule(os.geteuid(), os.getegid(), 0o400, False, resolver), "E_STORE",
            recording_work=work, accounting_kind="M")
        try:owned.append(budget_held)
        except BaseException as error:
            if not any(item is budget_held for item in owned):
                try:budget_held.close()
                except BaseException as later:error = _seed_first(error, later)
            raise error
        budget_raw = budget_held.read(c.DOCUMENT_LIMIT, "E_STORE", work)
        actual_bindings = {"slot": int(index), "case_id": case["case_id"],
            "case_document_sha256": c.digest(case_raw), "manifest_sha256": c.digest(manifest_raw),
            "core_sha256": c.digest(core_raw), "window_sha256": c.digest(window_raw)}
        work["seed_processing"]["H"] += len(case_raw) + len(manifest_raw) + len(core_raw) + len(window_raw)
        budget_sha = c.digest(budget_raw)
        work["seed_processing"]["H"] += len(budget_raw)
        ordinal = int(input_root.parts[-2])
        budget = c._c3_budget_values(budget_raw, int(index) + 1, ordinal,
            "dashboard" if ordinal == 2 else "run", actual_bindings["window_sha256"], actual_bindings, work)
        c._c3_bind_work(work, budget, int(index) + 1, case["case_id"], "bootstrap")
        work["_c3_budget_sha"], work["_c3_input_bindings"] = budget_sha, actual_bindings
        work["_c3_scopes"] = {case["case_id"]: work}
        work["_c3_open_regular"], work["_c3_owned_children"] = owned, []
        c._c3_bind_work(work, budget, int(index) + 1, case["case_id"], "body")
        pending_work = c._open_held(str(private_work), True,
            c._store_rule(os.geteuid(), os.getegid(), 0o700, True, resolver), "E_STORE",
            recording_work=work, accounting_kind="M")
        _seed_require(not pending_work.listdir())
        pending_work.recheck("E_STORE", work, "M")
        core_work, pending_work = pending_work, None
        observation = replay_case(runtime_root, initial, manifest_raw, window_raw,
            case, core_work, work)
        _seed_require(type(observation) is dict and observation.get("case_id") == case["case_id"])
    except BaseException as error:
        failure = error
    finally:
        if pending_work is not None:
            held, pending_work = pending_work, None
            try:held.close()
            except BaseException as error:failure = _seed_first(failure, error)
        while owned:
            held = owned.pop()
            try:held.recheck("E_STORE", work, "M")
            except BaseException as error:failure = _seed_first(failure, error)
            try:held.close()
            except BaseException as error:failure = _seed_first(failure, error)
    if failure is not None:
        raise failure
    output = c._c3_encode_values(observation, work)
    work["C3_export_work"] = c._export_work
    if "source_work" not in work:
        work["cli_source_receipt_missing_unknown"] = True
    if len(work.get("offline_preparation_ledgers", [])) > 1:
        work["cli_multiple_preparation_owners_slot_unknown"] = True
    elif not work.get("offline_preparation_ledgers"):
        work["cli_preparation_receipt_missing_unknown"] = True
    own = c._c3_scope_ledger_values(work)
    end_document = {"input_bindings": actual_bindings, "own": {case["case_id"]: own},
        "children": [], "outcome": "completed"}
    c._c3_emit(output, end_document, work, budget, int(index) + 1)


if __name__ == "__main__":
    try:
        _private_cli(sys.argv[1:])
    except BaseException:
        sys.stderr.write("E_RUNTIME\n")
        raise SystemExit(1)
