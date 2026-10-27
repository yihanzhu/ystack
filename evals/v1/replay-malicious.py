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



def _reproduction_values(runtime_root, files, materialized, context):
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
        context["python_raw"], context["jq_sha256"], context["commands"])
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
            and (occurrence != "gate" or role == "recorded"))
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
            _seed_require((type(copied) is owner._HeldCaptureCopy or configuration_copy)
                and copied.anchor is native.anchor
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
                member = ("configuration/" + next(key for key, row in configuration_members.items()
                    if row["member"] == name)) if configuration_copy else copied.directory.components[-1].name + "/" + name
                installed = self._semantic_copy(native.anchor, held, output, expected, kind,
                    phase, semantic_role, member)
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
                _seed_require(kind == role == "recorded" and occurrence in {"reproduction", "write"} and member.startswith("bundle/"))
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
            and type(reader.replay_outputs) is dict and set(reader.replay_outputs) == {"bundles", "git", "stores"})
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
            record = self._wrapper_parse(files["shadow-record.json"], "bundle-record")
            expected_form = "enforced-reproduction.v1" if phase == "reproduction" else record["body"]["record_form"]
            _seed_require(record["body"]["record_form"] == expected_form
                and expected_form in ({"enforced-reproduction.v1"} if phase == "reproduction"
                    else {"withheld-write.v1", "withheld-write-policy.v1"}))
            names = set(module.c.SHADOW_EVIDENCE_NAMES) | {"bundle.json"}
            if phase == "write":names.add("publisher-body.txt")
            if expected_form == "withheld-write-policy.v1":names.add("scope-policy.json")
            _seed_require(set(files) == names)
            binding = (phase, context, role, environment)
            _seed_require(binding not in self.output_forms or self.output_forms[binding] == expected_form)
            self.output_forms[binding] = expected_form
            if phase == "write":
                paths = tuple(row["path"] for row in record["body"]["write"]["write_set"])
                _seed_require(len(set(paths)) == len(paths)
                    and (binding not in self.output_write_sets or self.output_write_sets[binding] == paths))
                self.output_write_sets[binding] = paths
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

    def gate_outputs(self):
        try:
            generator = self.generator
            module = self._gate_type(generator, "scope/v1/generate-gate-evidence.py", "_Generator")
            _seed_require(generator is self._gate_owner and generator.active
                and generator.session is self.gate_session and self.gate_session.phase == "COMPLETE"
                and not generator.capture_output_unusable and type(generator.output_holds) is dict
                and "gate" in self.occurrences and "gate-output" not in self.derived_outputs)
            generator.reader.anchor.recheck("E_STORE")
            holders = dict(generator.output_holds)
            for item in generator.reader.owned:
                if type(item) is not module.c._HeldBytes:continue
                path = Path(item.held.path)
                if generator.output not in path.parents:continue
                name = path.relative_to(generator.output).as_posix()
                if name in holders:
                    previous = holders[name]
                    _seed_require(previous.raw == item.raw
                        and module.c._identity(previous.held.before) == module.c._identity(item.held.before))
                else:holders[name] = item
            manifest_name, complete_name = "manifests/manifest.json", "completion/COMPLETE.json"
            _seed_require(manifest_name in holders and complete_name in holders)
            manifest_raw, complete_raw = holders[manifest_name].raw, holders[complete_name].raw
            manifest = self._wrapper_parse(manifest_raw, "gate-output-manifest")
            rows = manifest["body"]["files"]
            _seed_require(type(rows) is list and all(type(row) is dict
                and set(row) == {"name", "size_bytes", "sha256"} for row in rows)
                and len({row["name"] for row in rows}) == len(rows)
                and set(holders) == {row["name"] for row in rows} | {manifest_name, complete_name})
            rebuilt = module._completion_values(self.identifiers["gate"], manifest_raw, self.work)
            self._charge("E", len(rebuilt) + len(complete_raw), "M")
            self._wrapper_processed("gate-output-completion-compare", len(rebuilt) + len(complete_raw))
            _seed_require(rebuilt == complete_raw)
            indexed = {row["name"]: row for row in rows}
            installed = {}
            for index, name in enumerate(sorted(holders)):
                item = holders[name]
                _seed_require(type(item) is module.c._HeldBytes and item.raw is not None
                    and item.held.components and item.held.path == str(generator.output / name))
                item.recheck("E_STORE")
                expected = self._digest(item.raw, "recorded")
                if name in indexed:
                    _seed_require(indexed[name]["size_bytes"] == len(item.raw)
                        and indexed[name]["sha256"] == expected)
                destination = "gate-output-%03d" % index
                self._semantic_copy(generator.reader.anchor, item.held, destination, expected,
                    "recorded", "gate", "recorded", "generator/" + name, source_mode=0o400)
                installed[name] = destination
            generator.reader.anchor.recheck("E_STORE")
            self.derived_outputs["gate-output"] = installed
            self.output_relations.append(("gate", generator, manifest_raw, complete_raw))
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
        self.locators["gate"] = {"scope": scoped.held.path, "source_root": str(module.PACKAGE),
            **{name: str(path) for name, path in zip(
                ("request", "shadow_set", "dashboard", "marker", "bundle_root", "git_root", "output"), generator.paths)}}
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
            readers = {relation[1] for relation in self.output_relations if relation[0] in {"reproduction", "write"}}
            for reader in readers:
                for record_raw, (bundle, role, environment) in reader.replay_outputs["bundles"]:
                    _seed_require(any(relation[1] is reader and relation[-1] is bundle
                        and relation[3:5] == (role, environment) for relation in self.output_relations
                        if relation[0] in {"reproduction", "write"}))
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
                    else:directory = self.exports
                    exports.add(name.rsplit("/", 1)[1]);expected.add("exports")
                else:
                    _seed_require("/" not in name and name not in {".", ".."})
                    expected.add(name)
                held = self._adopt(self.c._open_child(directory, name.rsplit("/", 1)[-1], False,
                    self.c._store_rule(os.geteuid(), os.getegid(), 0o400, False, self.resolver), "E_STORE",
                    recording_work=work, accounting_kind="M"))
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
        def created():
            self.work["files"] += 1
            c._capture_account(self.work, "raw", "files", 1)
        try:
            before = destination.before
            create_room()
            os.mkdir("refs", 0o700, dir_fd=destination.fd)
            created()
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
                        created()
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
                    created()
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
                try:held.recheck("E_STORE", self.work, "M")
                except BaseException as error:primary = _seed_first(primary, error);self._failed(error)
                try:held.close()
                except BaseException as error:primary = _seed_first(primary, error);self._failed(error)
            if primary is not None:raise self.failure


    def close(self, primary=None):
        failure = primary
        while self.owned:
            held = self.owned.pop()
            try:held.recheck("E_STORE", self.work, "M")
            except BaseException as error:failure = _seed_first(failure, error)
            try:held.close()
            except BaseException as error:failure = _seed_first(failure, error)
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
        try:self._replay_io_holds.append(held)
        except BaseException as error:
            if not any(item is held for item in self._replay_io_holds):
                try:held.close()
                except BaseException as later:error = self._replay_io_first(error, later)
            raise error
        return held

    def _replay_close_io(self, primary=None):
        failure = primary
        owned = getattr(self, "_replay_io_holds", [])
        while owned:
            held = owned.pop()
            try:held.close()
            except BaseException as error:
                failure = self._replay_io_first(failure, error)
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
            self._replay_refresh_parent(parent, before, names, name)
            os.fsync(parent.fd)
            held = self.c._open_child(parent, name, True,
                self.c._store_rule(os.geteuid(), os.getegid(), 0o700, True, self.inputs.resolver),
                "E_STORE", recording_work=self.work, accounting_kind="M")
            self._replay_adopt_io(held)
            _seed_require(not held.listdir())
            held.recheck("E_STORE", self.work, "M")
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
            while written < len(raw):
                chunk = memoryview(raw)[written:written + 65536]
                self.c._capture_copy_room(self.work, len(chunk), False, case=True)
                count = os.write(target, chunk)
                # Keep the syscall return even when subsequent accounting refuses.
                if type(count) is int and count > 0:
                    written += count
                    self._replay_written(count)
                self.c._capture_observe(self.work, "M", "replay-derived-write", {
                    "name": name, "return": count, "written_bytes": written})
                _seed_require(type(count) is int and 0 < count <= len(chunk))
            state = self.c._capture_metadata(target, self.work, "M")
            _seed_require(state.st_size == len(raw) and state.st_nlink == 1)
            os.fsync(target)
        except BaseException as error:
            failure = error
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
        return self.inputs.bytes(phase, "local-runtime", matches[0]["member"], self.c.EXECUTABLE_LIMIT)

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
            raw = self.local_slot(phase, slot)
            if type(raw) is tuple:
                _seed_require(all(type(chunk) is bytes for chunk in raw))
                size = sum(map(len, raw))
                self.c._runtime_account(self.work, "copy_bytes", size, commit=False)
                raw = b"".join(raw)
                self.inputs._account("C", len(raw), "runtime")
            _seed_require(type(raw) is bytes)
            binaries[slot] = raw
        def binary_sha(slot):
            raw = binaries[slot]
            self.c._runtime_account(self.work, "sha_bytes", len(raw), commit=False)
            value = e.sha(raw)
            self.inputs._account("H", len(raw), "runtime")
            return value
        # DependencySnapshot.sha256 is a stored field; do not hash it per command.
        helper_sha, jq_sha = binary_sha("object_closure"), binary_sha("jq")
        _seed_require(helper_sha == parent["helper_executable_sha256"])
        def component_sha(relative):
            if relative == "sandbox/v1/host-supervisor.py":
                rows = self.c._runtime_inventory_values(self.occurrences[phase]["raw"]["capture"]["runtime"])
                names = [name for name, row in rows.items() if row["slot"] == "host_supervisor_source" and row["index"] == 0]
                _seed_require(len(names) == 1)
                raw = self.inputs.bytes(phase, "capture", phase + "/" + names[0], self.c.EXECUTABLE_LIMIT)
                if type(raw) is tuple:
                    _seed_require(all(type(chunk) is bytes for chunk in raw))
                    size = sum(map(len, raw))
                    self.c._runtime_account(self.work, "copy_bytes", size, commit=False)
                    raw = b"".join(raw)
                    self.inputs._account("C", len(raw), "runtime")
                _seed_require(type(raw) is bytes)
                value = e.sha(raw)
                self.inputs._account("H", len(raw), "runtime")
                return value
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
        runtime_bytes = {}
        for slot in ("python", "jq"):
            value = self.local_slot(phase, slot)
            if type(value) is tuple:
                _seed_require(all(type(chunk) is bytes for chunk in value))
                size = sum(map(len, value))
                self.c._runtime_account(self.work, "copy_bytes", size, commit=False)
                value = b"".join(value)
                self.inputs._account("C", len(value), "runtime")
            _seed_require(type(value) is bytes)
            runtime_bytes[slot] = value
        jq_sha = e.sha(runtime_bytes["jq"])
        self.inputs._account("H", len(runtime_bytes["jq"]), "runtime")
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
        binaries = {}
        for slot in ("python", "jq"):
            value = self.local_slot(phase, slot)
            if type(value) is tuple:
                _seed_require(all(type(chunk) is bytes for chunk in value))
                self.c._runtime_account(self.work, "copy_bytes", sum(map(len, value)), commit=False)
                value = b"".join(value)
                self.inputs._account("C", len(value), "runtime")
            _seed_require(type(value) is bytes)
            binaries[slot] = value
        source = self.c._open_held(str(runtime_root / "shadow/v1/write-shadow.py"), False,
            self.c._store_rule(os.geteuid(), os.getegid(), 0o400, False, self.inputs.resolver),
            "E_STORE", recording_work=self.work, accounting_kind="M")
        self._replay_adopt_io(source)
        _seed_require(source.before.st_size <= self.c.EXECUTABLE_LIMIT)
        self.c._capture_copy_room(self.work, 4 * source.before.st_size, False, case=True, read_only=True)
        consumer_raw = source.read(self.c.EXECUTABLE_LIMIT, "E_STORE", self.work)
        consumer_sha, python_sha, jq_sha = w.sha(consumer_raw), w.sha(binaries["python"]), w.sha(binaries["jq"])
        self.inputs._account("H", len(consumer_raw), "M")
        self.inputs._account("H", len(binaries["python"]) + len(binaries["jq"]), "runtime")
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
            _seed_require(type(left) is bytes and type(right) is bytes)
            self.inputs._account("E", len(left) + len(right), "M")
            _seed_require(left == right)
        def digest(raw):
            value = g.c.digest(raw)
            self.inputs._account("H", len(raw), "M")
            return value
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
                and name not in output and type(raw) is bytes)
            if document:_seed_require(len(raw) <= self.c.DOCUMENT_LIMIT)
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
        rows = [{"name": name, "size_bytes": len(output[name]), "sha256": digest(output[name])}
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
            self.compare_member("gate", "recorded", "generator/" + name, raw)
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
        result, bundle = _reproduction_values(runtime_root, files, materialized, context)
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
    raw_receipt = c._capture_accounting_values(work, {})
    receipts = {"raw": raw_receipt, "export": dict(c._export_work),
        "source": {"state": "unknown"}, "preparation": {"state": "unknown"}, "Q": {"state": "unknown"}}
    unknown = [key for key, value in work.items() if (key.endswith("_unknown") or key.endswith("incomplete")) and value]
    own = c._c3_ledger_values(work, receipts, work.get("C3_retained", []),
        work.get("C3_tool_errors", []), unknown)
    end_document = {"input_bindings": actual_bindings, "own": {case["case_id"]: own},
        "children": [], "outcome": "completed"}
    c._c3_emit(output, end_document, work, budget, int(index) + 1)


if __name__ == "__main__":
    try:
        _private_cli(sys.argv[1:])
    except BaseException:
        sys.stderr.write("E_RUNTIME\n")
        raise SystemExit(1)
