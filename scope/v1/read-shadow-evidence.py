#!/usr/bin/env python3
"""Private fixed-package reader for inactive scope evidence."""
from __future__ import annotations
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import sys
import sysconfig
import time
import unicodedata

PACKAGE = Path(__file__).absolute().parents[2]
SOURCE = PACKAGE / "shadow/v1/_consumer.py"
_entry_clock = time.monotonic()
DEADLINE = _entry_clock + 300
_spec = importlib.util.spec_from_file_location("scope_shadow_consumer", SOURCE)
if _spec is None or _spec.loader is None or SOURCE.resolve() != SOURCE:
    raise SystemExit("E_RUNTIME")
c = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = c
_spec.loader.exec_module(c)
c._clock_value('scope/v1/read-shadow-evidence.py:18:0', _entry_clock, 'monotonic')


def require(value, code="E_RELATION"):
    c._require(value, code)


def parse(raw, limit=8 * c.DOCUMENT_LIMIT):
    return c._json(raw, limit, "E_RELATION")


def same(left, right):
    return c.canonical(left) == c.canonical(right)


_SCOPE_RUNTIME_SITES = ("scope.soabi", "scope.python-version", "scope.unicode-version")


def _scope_runtime_value_values(row, site, ordinal):
    require(site in _SCOPE_RUNTIME_SITES and type(ordinal) is int and ordinal >= 0)
    require(type(row) is dict and set(row) == {"site", "ordinal", "value"}
            and row["site"] == site and type(row["ordinal"]) is int and row["ordinal"] == ordinal)
    value = row["value"]
    require((site == "scope.soabi" and value is None) or
            (type(value) is str and 0 < len(value.encode("utf-8")) <= 128
             and all(0x20 <= ord(char) <= 0x7e for char in value)))
    return value


def _scope_runtime_equal_values(expected, row, site, ordinal):
    return expected == _scope_runtime_value_values(row, site, ordinal)


def _scope_runtime_prefix_values(rows, observed):
    require(type(rows) is list and type(observed) is list and len(rows) <= len(observed) <= 4096)
    ordinals = {site: 0 for site in _SCOPE_RUNTIME_SITES}
    for row, original in zip(rows, observed):
        require(type(original) is dict and original.get("site") in ordinals and row == original)
        site = original["site"]
        _scope_runtime_value_values(row, site, ordinals[site])
        ordinals[site] += 1
    return rows


def ref(raw):
    document = parse(raw)
    return {"schema_version": document["schema_version"], "kind": document["kind"],
            "id": document["id"], "sha256": c.digest(raw)}


def _scope_reader_observation_values(scope_id, scope_ref, shadow_set_ref, sorted_rows,
                                     git_values, commands, workflow, coverage_result):
    result = {"schema_version": 1, "kind": "scope_shadow_evidence_observation", "id": scope_id,
        "body": {"scope_ref": scope_ref, "shadow_set_ref": shadow_set_ref,
            "rows": sorted_rows, "git": git_values, "commands": commands,
            **({"coverage": coverage_result} if workflow else {})}}
    return c.canonical(result)


def _authentication_installed_names_values():
    return {"accepted-identities.json": "accepted_set", "registry.json": "registry",
        "evaluator-driver.txt": "evaluator_driver", "evaluator-program.txt": "evaluator_program",
        "policy.json": "control_policy", "decision.json": "control_decision", "policy-set.json": "control_policy_set"}


def _authentication_store_names_values():
    return {"receipt.json": "sandbox-receipt.json", "payload/stdout": "payload-stdout.txt",
        "payload/stderr": "payload-stderr.txt", "payload/evidence-manifest.json": "evidence-manifest.json",
        "payload/evidence/0000": "file-digest-result.json"}


def _authentication_registry_matches_values(registry, body):
    return (registry["proof_state"] == "native-qualified"
            and registry["target_repository_id"] == body["target_repository_id"])


def _provenance_document_values(files, attempt):
    document = parse(files["consumer-provenance.json"])
    keys = {"activation_state", "authority", "instruction_utf8", "instruction_sha256",
        "observation", "observation_sha256", "native_release", "commands", "helper_source_sha256",
        "helper_build_record_sha256", "helper_executable_sha256", "consumer_source_sha256", "python_sha256", "jq_sha256"}
    require(set(document) == {"schema_version", "kind", "id", "body"}
            and type(document["schema_version"]) is int and document["schema_version"] == 1
            and document["kind"] == "shadow_consumer_provenance" and document["id"] == attempt
            and type(document["body"]) is dict and set(document["body"]) == keys)
    body = document["body"]
    return keys, body


def _provenance_content_matches_values(body, instruction, observation):
    return (body["activation_state"] == "inactive" and body["authority"] == "none"
            and type(body["instruction_utf8"]) is str and body["instruction_utf8"].encode() == instruction
            and body["instruction_sha256"] == c.digest(instruction)
            and same(body["observation"], parse(observation)) and body["observation_sha256"] == c.digest(observation))


def _provenance_native_shape_matches_values(native):
    hashes = {"source_sha256", "build_script_sha256", "build_record_sha256", "binary_locator_sha256",
              "binary_sha256", "python_locator_sha256", "python_sha256", "dependency_record_sha256"}
    return (type(native) is dict and set(native) == hashes | {"context_version", "binary_size", "python_abi", "loader_mode"}
            and type(native["context_version"]) is int and native["context_version"] == 2
            and all(c._sha(native[key]) for key in hashes)
            and type(native["binary_size"]) is int and 0 < native["binary_size"] <= c.EXECUTABLE_LIMIT
            and native["loader_mode"] == "rtld-now-local.v1" and type(native["python_abi"]) is str)


def _provenance_native_identity_matches_values(native, body):
    return (1 <= len(native["python_abi"]) <= 128
                and all(0x20 <= ord(char) <= 0x7e for char in native["python_abi"])
                and native["python_sha256"] == body["python_sha256"])


def _provenance_roles_values():
    return {
        "incident-validation": "shadow/v1/validate-incident.sh", "materialization": "adapters/local-git-materializer/v1/materialize.sh",
        "sandbox-bound-evaluation": "control/v1/evaluate-bound-sandbox.sh",
        "sandbox-receipt-check": "enforcement/v1/check-sandbox-receipt.sh",
        "trace-validation": "telemetry/v1/validate-trace-ledger.sh",
        "write-seed-conversion": "maintenance/v1/incident-to-eval.sh",
        "write-materialization-input": "shadow/v1/write-materialization-input.jq",
        "write-git-inspection": "shadow/v1/write-shadow.py",
        "materializer-input-validation": "adapters/local-git-materializer/v1/protocol.jq",
        "materializer-response-validation": "adapters/local-git-materializer/v1/protocol.jq",
        "qualified-identity-validation": "shadow/v1/qualified-identity.jq",
        "candidate-preparation": "preparation/v1/prepare-candidate.py", "candidate-inspection": "preparation/v1/prepare-candidate.py"}


def _provenance_commands_values(body, fixed):
    commands = body["commands"]
    require(type(commands) is list and 1 <= len(commands) <= 4096)
    for row in commands:
        require(type(row) is dict and set(row) == {"role", "argv_sha256", "executable_sha256", "component_sha256"}
                and type(row["role"]) is str and row["role"] in fixed
                and all(c._sha(row[key]) for key in ("argv_sha256", "executable_sha256", "component_sha256"))
                and (row["executable_sha256"], row["component_sha256"]) == fixed[row["role"]])
    return commands


def _authentication_documents_values(files):
    incident, record = parse(files["incident.json"]), parse(files["shadow-record.json"])
    body, revision = record["body"], incident["body"]["git_revision_ref"]
    return incident, body, revision


def _authentication_environment_values(rows, body):
    return [row for row in rows if row["environment_id"] == body["environment"]["environment_id"]]


def _authentication_receipt_values(files, accepted):
    receipt = parse(files["sandbox-receipt.json"])
    for slot, value in receipt["body"]["identities"].items():
        require(set(value) == {"state", "sha256"} and value["state"] == "observed"
                and value["sha256"] in accepted[0]["identities"][slot])
    require(set(receipt["body"]["identities"]) == c.IDENTITY_SLOTS)
    return receipt


def _origin_projection_values(document, snapshots, attempt_id, config):
    require(set(document) == {"schema_version", "kind", "id", "body"}
            and type(document["schema_version"]) is int and document["schema_version"] == 1
            and document["kind"] == "shadow_origin_observation" and document["id"] == attempt_id)
    body = document["body"]
    require(set(body) == {"store_id", "attempt_id", "entries", "result"}
            and body["store_id"] == config["store_id"] and body["attempt_id"] == attempt_id
            and body["result"] == "authenticated" and type(body["entries"]) is list)
    directory_names = {".", attempt_id, "payload", "payload/evidence"}
    expected = set(snapshots) | directory_names
    names = []
    for row in body["entries"]:
        require(type(row) is dict)
        names.append(row.get("name"))
        file = row.get("kind") == "file"
        require(set(row) == {"name", "device", "inode", "mode", "uid", "gid", "kind",
            "metadata_before", "metadata_after"} | ({"size", "sha256"} if file else set()))
        require(row["name"] in expected and row["uid"] == config["principal_uid"]
                and row["gid"] == config["consumer_gid"]
                and row["mode"] == (0o440 if file else 0o750)
                and row["kind"] == ("file" if row["name"] in snapshots else "directory")
                and all(type(row[key]) is int for key in ("device", "inode", "mode", "uid", "gid"))
                and type(row["metadata_before"]) is list and len(row["metadata_before"]) == 10
                and all(type(value) is int for value in row["metadata_before"])
                and same(row["metadata_before"], row["metadata_after"]))
        metadata = row["metadata_before"]
        require(metadata[:6] == [row["device"], row["inode"], stat.S_IFREG if file else stat.S_IFDIR,
                row["uid"], row["gid"], row["mode"]]
                and metadata[6] >= 1 and metadata[7] >= 0 and metadata[8] >= 0 and metadata[9] >= 0)
        if file:
            require(metadata[6] == 1 and metadata[7] == row["size"])
            raw = snapshots[row["name"]]
            require(type(row["size"]) is int and row["size"] == len(raw) and row["sha256"] == c.digest(raw))
    require(len(names) == len(set(names)) and set(names) == expected)

def _record_refs_values(files, body, attempt, config):
    expected = {"state": "satisfied", "reason_id": "shadow.sandbox-satisfied",
        "launch_request_ref": ref(files["sandbox-request.json"]),
        "expectation_ref": ref(files["sandbox-expectation.json"]), "receipt_ref": ref(files["sandbox-receipt.json"]),
        "check_ref": ref(files["sandbox-check.json"]), "origin": {"state": "authenticated",
            "store_id": config["store_id"], "method": "controlled-storage.v1",
            "observation_sha256": c.digest(files["origin-observation.json"])},
        "payload_ref": {"content_id": "file-digest-result", "media_type": "application/json",
            "sha256": c.digest(files["file-digest-result.json"])}}
    require(same(body["sandbox"], expected))
    content = {"incident_ref": ("shadow-incident-record", "application/vnd.ystack.shadow-incident-record+json", "incident.json"),
        "qualified_identity_ref": ("shadow-qualified-identity", "application/vnd.ystack.qualified-identity+json", "qualified-identity.json"),
        "trace_ledger_ref": ("shadow-trace-ledger", "application/vnd.ystack.telemetry-trace-ledger+json", "trace-ledger.json")}
    for key, (identity, media, name) in content.items():
        require(same(body[key], {"content_id": identity, "media_type": media, "sha256": c.digest(files[name])}))
    environment = body["environment"]
    require(same(environment["claim_ref"], {"content_id": "shadow-environment-claim",
        "media_type": "application/vnd.ystack.control-execution-environment-claim+json", "sha256": c.digest(files["claim.json"])}))
    require(same(environment["registry_ref"], {"content_id": "shadow-environment-registry",
        "media_type": "application/vnd.ystack.shadow-environment-registry+json", "sha256": c.digest(files["registry.json"])}))

def _launch_expectation_values(files, config, registry, record_body, prep, instruction, control_values):
    launch, expectation = parse(files["sandbox-request.json"]), parse(files["sandbox-expectation.json"])
    launch_body = launch["body"]
    subject = {"environment_id": config["environment_id"],
        "environment_entry_sha256": c.digest(c.canonical(registry)), "target_repository_id": record_body["target_repository_id"],
        "source": prep["source"], "candidate": {"preparation_record_sha256": c.digest(files["preparation-record.json"]),
            "manifest_sha256": c.digest(files["preparation-manifest.json"]), "commit_id": prep["candidate"]["commit_id"],
            "tree_id": prep["candidate"]["tree_id"]}, "incident_sha256": c.digest(files["incident.json"])}
    require(set(launch) == {"schema_version", "kind", "id", "body"}
            and type(launch["schema_version"]) is int and launch["schema_version"] == 1
            and launch["kind"] == "sandbox_launch_request" and c._id(launch["id"])
            and set(launch_body) == {"attempt", "control", "instruction_sha256", "nonce", "store_id", "subject"}
            and c._sha(launch_body["nonce"]))
    require(same(launch_body["subject"], subject)
            and same(launch_body["control"], control_values)
            and launch_body["instruction_sha256"] == c.digest(instruction)
            and launch_body["store_id"] == config["store_id"]
            and same(launch_body["attempt"], {"attempt_id": launch["id"], "attempt_number": 1})
            and same(expectation, {"schema_version": 1, "kind": "sandbox_receipt_expectation", "id": launch["id"],
                "body": {"attempt": launch_body["attempt"] | {"launch_request_sha256": c.digest(files["sandbox-request.json"])},
                    "control": launch_body["control"], "store_id": config["store_id"], "subject": subject}}))
    return launch


def _bundle_facts_values(files, checked, fresh_origin, body):
    return {"bundle_ref": ref(files["bundle.json"]), "receipt_ref": ref(files["sandbox-receipt.json"]),
        "check_ref": ref(checked), "fresh_origin_ref": ref(fresh_origin),
        "archived_origin_ref": ref(files["origin-observation.json"]),
        "registry_ref": ref(files["registry.json"]), "accepted_set_ref": ref(files["accepted-identities.json"]),
        "materialization_ref": {"sha256": c.digest(files["materialization-response.json"])},
        **({"scope_policy_ref": body["scope_policy_ref"]} if body["record_form"] == "withheld-write-policy.v1" else {})}


def _coverage_identity_values(scope_id, workflow_id, task_class, qualified_fields, profile_fields,
        environment, registry_entry, policy_set_ref, sandbox_policy_sha, scope_policy_sha, coverage_base):
    return {"scope_id": scope_id, "workflow_id": workflow_id, "task_class": task_class,
        **qualified_fields, "resolved_profile": profile_fields, "environment_id": environment,
        "registry_entry": registry_entry, "control_policy_set_ref": policy_set_ref,
        "sandbox_policy_sha256": sandbox_policy_sha, "scope_policy_sha256": scope_policy_sha,
        "coverage_base": coverage_base, "coverage_rule_version": "scope-coverage.v1"}


def _coverage_git_values(base, current, base_tree, current_tree, config_sha):
    return {"base": base, "current": current, "base_tree": base_tree,
        "current_tree": current_tree, "config_sha256": config_sha}


def _coverage_request_body_values(attempt, nonce, repository_id, coverage_base, evaluated_revision,
        documents, qualifying_refs, current_refs, resolved_profile_ref, stage_request_ref,
        stage_result_ref, materialization_refs, publisher_refs, post_check_refs, receipt_refs,
        git_observation_sha, package_ref, accepted_ref):
    return {"attempt_id": attempt, "nonce": nonce, "repository_id": repository_id,
        "coverage_base": coverage_base, "evaluated_revision": evaluated_revision,
        "coverage_rule_version": "scope-coverage.v1", "documents": documents,
        "qualifying_shadow_record_refs": qualifying_refs, "current_shadow_record_refs": current_refs,
        "resolved_profile_ref": resolved_profile_ref, "stage_request_ref": stage_request_ref,
        "stage_result_ref": stage_result_ref, "materialization_refs": materialization_refs,
        "publisher_request_refs": publisher_refs, "post_check_refs": post_check_refs,
        "qualifying_receipt_refs": receipt_refs, "git_observation_sha256": git_observation_sha,
        "source_package_ref": package_ref, "source_accepted_set_ref": accepted_ref}


def _coverage_expectation_fields_values(body):
    return {key: body[key] for key in ("attempt_id", "nonce", "coverage_base", "evaluated_revision",
        "stage_request_ref", "resolved_profile_ref", "stage_result_ref", "source_package_ref", "source_accepted_set_ref")}


def _coverage_head_values(head):
    require(head.startswith(b"ref: refs/heads/") and head.endswith(b"\n"))
    return head[len(b"ref: refs/heads/"):-1].decode("utf-8")


def _coverage_packed_ref_values(packed, commit_id, branch_name):
    matches = [line for line in packed.splitlines() if not line.startswith((b"#", b"^"))
        and line.endswith(b" refs/heads/" + branch_name.encode())]
    require(matches == [(commit_id + " refs/heads/" + branch_name).encode()])
    return matches


def _coverage_interval_rows_values(observation, commits, revision, base):
    require(observation["first_parent_commits"] == [dict(row, index=index) for index, row in enumerate(commits)])
    require(observation["repository"]["repository_id"] == revision["repository_id"]
        and observation["branch_snapshots"]["current"]["commit_id"] == revision["commit_id"]
        and observation["branch_snapshots"]["baseline"]["commit_id"] == base["commit_id"])


def _coverage_changes_values(previous, facts):
    changed = sorted(path for path in set(previous) | set(facts)
        if previous.get(path) != facts.get(path) and
        (previous.get(path, (None, None))[1] == "blob" or facts.get(path, (None, None))[1] == "blob"))
    require(not any(path == ".ystack" or path.startswith(".ystack/") or path == ".github/workflows"
        or path.startswith(".github/workflows/") for path in changed))
    evidence = [path for path in changed if path == "ystack-evidence" or path.startswith("ystack-evidence/")]
    if evidence:
        require(changed == evidence and all(path not in previous and facts.get(path, ())[:2] == ("100644", "blob") for path in evidence))
    return changed, evidence


def _coverage_pull_values(pulls, commit_id):
    candidates = [pull for pull in pulls if pull["merge_commit_id"] == commit_id]
    require(len(candidates) == 1)
    return candidates[0]


def _coverage_pull_scope_matches_values(pull, scope_id, evidence):
    return pull["scope_id"] == scope_id and pull["changed_paths"] == evidence and pull["merged"] is True


def _coverage_publisher_prefix_matches_values(publisher, p, pull, revision):
    return (c.digest(c.canonical(publisher)) == pull["publisher_request_sha256"]
        and p["branch"] == pull["source_branch"] and p["target_repository_id"] == revision["repository_id"]
        and p["base_revision"]["commit_id"] == pull["base_commit_id"])


def _coverage_write_paths_values(body):
    return [item["path"] for item in body["write"]["write_set"]]


def _coverage_head_changes_values(base_facts, head_facts, evidence, facts):
    changes = sorted(path for path in set(base_facts) | set(head_facts)
        if base_facts.get(path) != head_facts.get(path) and
        (base_facts.get(path, (None, None))[1] == "blob" or head_facts.get(path, (None, None))[1] == "blob"))
    require(changes == evidence and all(path not in base_facts and head_facts[path] == facts[path] for path in evidence))
    return changes


def _coverage_blob_values(facts, item, raw):
    require(facts[item["path"]] == (item["mode"], "blob", item["git_blob_oid"])
        and c.digest(raw) == item["sha256"] and item["add_only"] is True)


def _coverage_interval_result_values(used, pulls, rows):
    require(used == {pull["node_id"] for pull in pulls})
    return {"sha256": c.digest(c.canonical(rows)), "commit_count": len(rows)}

def _preparation_document_values(files, receipt, response):
    prep = parse(files["preparation-record.json"])
    keys = {"schema_version", "kind", "status", "authority", "qualification", "input_sha256",
        "response_sha256", "stage_result_sha256", "receipt_sha256", "request_ref", "resolved_profile_ref",
        "attempt", "source", "candidate", "manifest_sha256", "storage_observation_sha256", "producer", "ownership"}
    candidate = receipt["candidate"]
    expected = {"schema_version": 1, "kind": "candidate_content_preparation", "status": "completed",
        "authority": "none", "qualification": "unavailable",
        "input_sha256": c.digest(files["materialization-input.json"]),
        "response_sha256": c.digest(files["materialization-response.json"]),
        "stage_result_sha256": c.digest(c.canonical(response["stage_result"])),
        "receipt_sha256": c.digest(response["payloads"][0]["data"].encode()),
        "request_ref": receipt["request_ref"], "resolved_profile_ref": receipt["resolved_profile_ref"],
        "attempt": receipt["attempt"], "source": receipt["source"],
        "candidate": {key: candidate[key] for key in ("hash_algorithm", "commit_id", "tree_id", "parent_commit_id")},
        "manifest_sha256": c.digest(files["preparation-manifest.json"]),
        "ownership": {"state": "local-preparation-complete", "immutable": False,
            "authenticated_receipt": False, "supervisor_handoff": "required"}}
    expected["candidate"]["outcome"] = response["stage_result"]["body"]["outcome"]["value"]
    require(set(prep) == keys and all(same(prep[key], value) for key, value in expected.items())
            and c._sha(prep["storage_observation_sha256"]))
    producer = prep["producer"]
    require(type(producer) is dict and set(producer) == {"component_id", "source_sha256", "python", "git",
        "jq", "protocol_sha256", "core", "unicode_version"}
        and producer["component_id"] == "candidate-content-preparation.v1")
    return prep, producer


def _preparation_binary_prefix_matches_values(identity):
    return type(identity) is dict and set(identity) == {"executable_sha256", "version"}


def _preparation_binary_suffix_matches_values(identity):
    return (type(identity["version"]) is str and 1 <= len(identity["version"]) <= 128
        and all(0x20 <= ord(char) <= 0x7e for char in identity["version"]))


def _preparation_core_values(core, generation_id, expected_files):
    require(type(core) is dict and set(core) == {"generation_id", "files"}
        and core["generation_id"] == generation_id and same(core["files"], expected_files))
    return core


def _candidate_header_values(source, body, revision, source_tree, candidate):
    require(same(source, {"repository_id": body["target_repository_id"], "hash_algorithm": revision["hash_algorithm"],
        "commit_id": revision["commit_id"], "tree_id": source_tree}))
    require(candidate["hash_algorithm"] == revision["hash_algorithm"] and candidate["repository_kind"] == "bare"
        and candidate["parent_commit_id"] == revision["commit_id"])


def _candidate_manifest_header_values(manifest):
    entries = manifest["entries"]
    require(type(entries) is list and len(entries) <= 10000)
    require(set(manifest) == {"schema_version", "kind", "hash_algorithm", "entries",
        "file_count", "directory_count", "total_file_bytes"}
        and type(manifest["schema_version"]) is int and manifest["schema_version"] == 1
        and manifest["kind"] == "candidate_content_manifest" and manifest["hash_algorithm"] == "sha256"
        and all(type(manifest[key]) is int and manifest[key] >= 0
                for key in ("file_count", "directory_count", "total_file_bytes")))
    return entries


def _candidate_manifest_row_values(row, manifest_facts, facts):
    require(type(row) is dict and row["path"] not in manifest_facts)
    value = facts.get(row["path"])
    require(value is not None and row["kind"] == ("directory" if value[1] == "tree" else "file"))
    manifest_facts[row["path"]] = value
    if value[1] == "tree":
        require(set(row) == {"path", "kind", "git_mode", "mode"}
            and row["git_mode"] == "040000" and row["mode"] == "0500")
    return value


def _candidate_manifest_file_matches_values(row, value):
    return (value[0] in {"100644", "100755"} and type(row["size_bytes"]) is int and row["size_bytes"] >= 0
        and row["git_mode"] == value[0] and row["blob_oid"] == value[2]
        and row["mode"] == ("0400" if value[0] == "100644" else "0500"))


def _candidate_manifest_blob_values(raw, row):
    require(len(raw) == row["size_bytes"] and c.digest(raw) == row["sha256"])


def _candidate_manifest_totals_values(manifest_facts, facts, manifest, entries, file_count, total_bytes):
    require(manifest_facts == facts and manifest["file_count"] == file_count
        and manifest["directory_count"] == len(entries) - file_count and manifest["total_file_bytes"] == total_bytes)


def _generator_runtime_values(gate_id, executables, files):
    return c.canonical({"schema_version": 1, "kind": "gate_runtime_package", "id": gate_id,
        "body": {"executables": executables, "files": files}})

def _scope_write_header_values(files, incident, body, scope):
    write = body["write"]
    require(set(write) == {"bundle_ref", "scope_id", "workflow_id", "task_class", "write_set",
        "publisher_request", "admission", "publication", "post_write_verification"})
    require(write["scope_id"] == scope["id"]
            and write["workflow_id"] == scope["body"]["workflow_id"] == "workflow.shadow-evidence-commit"
            and write["task_class"] == scope["body"]["task_class"] == "task.commit-shadow-evidence")
    prefix = "ystack-evidence/" + incident["id"] + "/"
    names = set(c.SHADOW_EVIDENCE_NAMES) | {"bundle.json", "eval-seed.json", "README.md"}
    policy_form = body["record_form"] == "withheld-write-policy.v1"
    if policy_form:
        names.add("scope-policy.json")
        c.check_scope_policy_ref(body["scope_policy_ref"], files["scope-policy.json"])
    paths = sorted(prefix + name for name in names)
    rows = write["write_set"]
    require(type(rows) is list and [row.get("path") for row in rows] == paths)
    return write, prefix, paths, rows, policy_form


def _scope_write_row_values(row, facts):
    require(set(row) == {"path", "mode", "sha256", "git_blob_oid", "add_only"}
            and row["mode"] == "100644" and row["add_only"] is True
            and c._sha(row["sha256"]) and c._writer_oid(row["git_blob_oid"])
            and facts.get(row["path"]) == ("100644", "blob", row["git_blob_oid"]))


def _scope_write_copied_values(frozen_files, incident, body, rows, paths, facts, source_facts):
    patch, expected_rows = c.evidence_patch(frozen_files, incident["body"]["git_revision_ref"]["hash_algorithm"], body["record_form"])
    require(same(rows, expected_rows))
    directories = {"/".join(path.split("/")[:index]) for path in paths for index in range(1, len(path.split("/")))}
    require(all(facts.get(path) == value or (path in directories and value[:2] == ("040000", "tree")
        and facts.get(path, ())[:2] == value[:2]) for path, value in source_facts.items()))
    require({path: value for path, value in facts.items() if path not in source_facts and value[1] != "tree"}
            == {row["path"]: ("100644", "blob", row["git_blob_oid"]) for row in rows})
    require({path for path, value in facts.items() if path not in source_facts and value[1] == "tree"}
            == directories - set(source_facts))
    return patch


def _scope_write_policy_values(policy_raw, policy_form, frozen_files, prefix):
    policy = parse(policy_raw)
    if policy_form:
        require(frozen_files[prefix + "scope-policy.json"] == policy_raw)
    return policy


def _scope_write_frozen_values(marker_raw, policy, scope_body, paths, frozen_files, prefix, incident, body, files):
    import fnmatch
    require(len(marker_raw) <= 8 * c.DOCUMENT_LIMIT)
    try:
        marker = json.loads(marker_raw.decode("utf-8"), object_pairs_hook=c._unique_object)
        require(type(marker) is dict)
        c.canonical(marker)
    except (UnicodeError, ValueError, TypeError, RecursionError):
        raise c.Refusal("E_RELATION") from None
    require(all(c.write_path_ok(path, policy, marker) and any(fnmatch.fnmatchcase(path, pattern) for pattern in scope_body["allowed_paths"]) for path in paths))
    frozen = {name: frozen_files[prefix + name] for name in c.SHADOW_EVIDENCE_NAMES + ("bundle.json",)}
    require(frozen["incident.json"] == files["incident.json"] and frozen_files[prefix + "README.md"]
            == b"Shadow evidence. Publication is withheld.\n")
    marker_doc = parse(frozen["bundle.json"])
    require(same(marker_doc, {"schema_version": 1, "kind": "shadow_consumer_bundle",
        "id": "bundle." + c.digest(frozen["incident.json"])[:32], "body": {
            "activation_state": "inactive", "record_form": "enforced-reproduction.v1",
            "incident_sha256": c.digest(frozen["incident.json"]), "target_revision": incident["body"]["git_revision_ref"],
            "files": [{"name": name, "size_bytes": len(frozen[name]), "sha256": c.digest(frozen[name])}
                      for name in sorted(c.SHADOW_EVIDENCE_NAMES)]}}))
    return frozen


def _scope_write_publication_values(write, files, publisher, publisher_body, incident, tree, rows):
    require(same(write["publisher_request"], publisher) and files["publisher-body.txt"] == publisher_body
            and same(write["publication"], {"state": "withheld", "reason_id": "shadow.write-not-published"})
            and same(write["admission"], {"state": "checked", "effect": "none",
                "request_sha256": c.digest(c.canonical(publisher)), "write_set_sha256": c.digest(c.canonical(rows))})
            and same(write["post_write_verification"], {"target_revision": incident["body"]["git_revision_ref"],
                "candidate_tree_id": tree, "write_set": rows}))
    return publisher


def _scope_write_frozen_tail_matches_values(frozen_files, frozen):
    return (sum(map(len, frozen_files.values())) <= 48 * c.DOCUMENT_LIMIT
        and parse(frozen["shadow-record.json"])["body"]["record_form"] == "enforced-reproduction.v1")

def _scope_command_recipe_values(role, executable_sha256, component_sha256, operation, arguments):
    require(type(role) is str and role and c._sha(executable_sha256) and c._sha(component_sha256)
        and type(operation) is str and operation and type(arguments) is list and len(arguments) <= 256)
    for position, argument in enumerate(arguments):
        require(type(argument) is dict and argument.get("position") == position
            and type(argument["position"]) is int and type(argument.get("role")) is str and argument["role"]
            and argument.get("type") in {"fixed", "historical-path", "content"}
            and set(argument) == ({"position", "type", "role", "value"} if argument["type"] == "fixed"
                else {"position", "type", "role"}))
        if argument["type"] == "fixed":require(type(argument["value"]) is str and "\0" not in argument["value"])
    return {"role": role, "executable_sha256": executable_sha256, "component_sha256": component_sha256,
        "operation": operation, "arguments": arguments}


def _reader_base_package_names_values():
    return ("shadow/v1/write-shadow.py", "shadow/v1/enforced-reproduction.py",
                             "scope/v1/scope-policy.json", "config/construction-mode.json",
                             "core/v2/generation-registry.json")


def _reader_fixed_package_names_values():
    return ("scripts/core-contract.sh", "shadow/v1/write-materialization-input.jq",
                "shadow/v1/qualified-identity.jq", "shadow/v1/validate-incident.sh", "shadow/v1/incident-record.jq",
                "adapters/local-git-materializer/v1/protocol.jq", "enforcement/v1/check-sandbox-receipt.sh",
                "enforcement/v1/sandbox-receipt.jq", "control/v1/evaluate-bound-sandbox.sh",
                "control/v1/sandbox-bound.jq", "control/v1/validate.sh", "control/v1/policy-set.jq",
                "telemetry/v1/validate-trace-ledger.sh", "telemetry/v1/trace-ledger.jq",
                "maintenance/v1/incident-to-eval.sh", "maintenance/v1/incident-to-eval.jq",
                "maintenance/v1/bands.jq", "evals/v1/eval-catalog.json", "evals/v1/seed-set.json")


def _scope_store_ancestor_values(rows, store_root):
    require(type(rows) is list and type(store_root) is str and os.path.isabs(store_root), "E_STORE")
    names = []
    path = "/"
    for part in Path(store_root).parts[:-1]:
        if part != "/":path = os.path.join(path, part)
        names.append(os.fsencode(path).hex())
    require(len(rows) == len(names), "E_STORE")
    identities = []
    sentinel = {"state": "not-observed-by-ancestor-rule"}
    for row, name in zip(rows, names):
        require(type(row) is dict and set(row) == {"role", "name", "before", "after", "named_after",
            "access_acl", "default_acl", "directory_names", "read_error"}
            and row["role"] == "store" and row["name"] == name and row["read_error"] is None
            and row["directory_names"] is None, "E_STORE")
        identity = c._identity_values(row["before"])
        require(identity == c._identity_values(row["after"]) == c._identity_values(row["named_after"])
            and stat.S_ISDIR(row["before"]["mode"]), "E_STORE")
        if type(row["access_acl"]) is dict or type(row["default_acl"]) is dict:
            require(row["access_acl"] == row["default_acl"] == sentinel, "E_STORE")
        identities.append(list(identity))
    return identities


def _scope_storage_chains_values(ancestors, rows, store_root, capture=False):
    require(type(rows) is list and rows and type(ancestors) is list and type(capture) is bool, "E_STORE")
    offset, first, known = 0, None, {}
    for row in rows:
        name = os.fsdecode(bytes.fromhex(row["name"]))
        if capture:
            require(name.startswith(".capture-") and all(part not in {"", ".", ".."} for part in name.split("/")), "E_STORE")
            path = os.path.join(store_root, name)
        elif name == ".":path = store_root
        else:
            attempt = os.fsdecode(bytes.fromhex(rows[1]["name"]))
            require(c._id(attempt), "E_STORE")
            path = os.path.join(store_root, name if name == attempt else attempt + "/" + name)
        count = len(Path(path).parts) - 1
        chain = ancestors[offset:offset + count]
        identities = _scope_store_ancestor_values(chain, path)
        if first is None:first = identities
        for component in chain:
            absolute = os.fsdecode(bytes.fromhex(component["name"]))
            identity = c._identity_values(component["before"])
            require(absolute not in known or known[absolute] == identity, "E_STORE")
            known[absolute] = identity
        identity = c._identity_values(row["before"])
        require(path not in known or known[path] == identity, "E_STORE")
        known[path] = identity
        offset += count
    require(offset == len(ancestors), "E_STORE")
    return first


def _scope_source_command_fields_values(request_raw, python_sha):
    return {"request_sha256": c.digest(request_raw), "python_sha256": python_sha}


def _scope_evaluation_policy_guard_values(driver_raw):
    prefix = b'"$jq_bin" -e \'\n'
    suffix = b'\n\' "$scratch/policy.json" >/dev/null 2>&1 || emit_error E_RELATION'
    begin = driver_raw.index(prefix) + len(prefix)
    end = driver_raw.index(suffix, begin)
    value = driver_raw[begin:end].decode("utf-8")
    require('scope_qualification_policy' in value)
    return value


def _scope_evaluation_output_guard_values(driver_raw):
    prefix = b'--arg scope_sha "$scope_sha" \'\n'
    suffix = b'\n\' "$scratch/evaluation.json" >/dev/null 2>&1 || emit_error E_RUNTIME'
    begin = driver_raw.index(prefix) + len(prefix)
    end = driver_raw.index(suffix, begin)
    value = driver_raw[begin:end].decode("utf-8")
    require('scope_qualification_evaluation' in value)
    return value


class _Owned(list):
    def __init__(self, reader):
        super().__init__()
        self.reader = reader

    def append(self, item):
        if isinstance(item, c._HeldStoreRead) and self.reader.store_session is not None:
            try:
                self.reader.store_session.acquire(item)
            except BaseException:
                item.close()
                raise
        super().append(item)
        if isinstance(item, c._HeldCoverageRead):
            self.reader.retain_source_capture(item)

    def remove(self, item):
        if isinstance(item, c._HeldStoreRead) and self.reader.store_session is not None:
            self.reader.store_session.release(item)
        super().remove(item)


class _GateReaderSession:
    is_inner = True

    def __init__(self):
        import socket
        require(stat.S_ISSOCK(os.fstat(6).st_mode), "E_RUNTIME")
        self.wire = c._GateWire(socket.socket(fileno=os.dup(6)), DEADLINE)
        phase, body = self.wire.receive()
        require(phase == "INIT" and set(body) == {"deadline", "gate_call_ref", "initial_origin_refs", "kill_request"}, "E_RUNTIME")
        require(type(body["deadline"]) in {int, float} and c._clock_value('scope/v1/read-shadow-evidence.py:74:0',time.monotonic(),'monotonic') < body["deadline"] <= DEADLINE, "E_RUNTIME")
        self.deadline = body["deadline"]
        self.wire.deadline = self.deadline - 10
        self.gate_call_ref, self.initial_origin_refs = body["gate_call_ref"], body["initial_origin_refs"]
        self.kill_request_raw = c.canonical(body["kill_request"])
        require(ref(self.kill_request_raw) == self.gate_call_ref, "E_RELATION")
        self.bindings = {}
        self.acquisitions, self.serial = {}, 0
        self.wire.send("INIT_ACK", {})

    def acquire(self, item):
        self.serial += 1
        identity = "inner." + str(self.serial)
        binding = c._gate_store_binding(item)
        self.wire.exchange("ACQUIRE", {"acquisition": identity, "binding": binding})
        self.acquisitions[id(item)] = identity
        self.bindings[identity] = binding

    def release(self, item):
        identity = self.acquisitions.pop(id(item))
        self.wire.exchange("RELEASE", {"acquisition": identity})
        del self.bindings[identity]

    def coverage_origins(self):
        rows = {c.canonical(binding["origin_ref"]): binding["origin_ref"] for binding in self.bindings.values()}
        require(all(c.canonical(row) in rows for row in self.initial_origin_refs), "E_STALE")
        return sorted(rows.values(), key=c.canonical)

    def request(self, request_raw, expectation):
        self.wire.exchange("C_REQUEST", {"request": parse(request_raw), "expectation": expectation,
            "acquisitions": sorted(self.acquisitions.values())})

    def released(self):
        require(not self.acquisitions, "E_RUNTIME")
        self.wire.exchange("C_RELEASED", {})

    def source_done(self):
        self.wire.exchange("C_DONE", {"acquisitions": sorted(self.acquisitions.values())})

    def final(self):
        self.wire.exchange("FINAL_OWNER", {"acquisitions": sorted(self.acquisitions.values())})

    def close(self):
        require(not self.acquisitions, "E_RUNTIME")
        self.wire.exchange("CLOSED", {})
        self.wire.sock.close()


class _Reader:
    @property
    def replay_output_unusable(self):
        try:return self.replay_output_state[0]
        except AttributeError:return True

    def __init__(self, scope_path, set_path, bundle_root, git_root, output, *, store_session=None, deadline=None, document_paths=None):
        self.document_paths = document_paths or {}
        self.store_session = store_session
        self.owned = _Owned(self)
        self.inputs, self.commands, self.gate_commands = [], [], []
        self.commands_open = True
        self.output = output
        self.scratch = output.parent.parent
        self.deadline = min(DEADLINE, deadline) if deadline is not None else DEADLINE
        self.anchor = None
        self.capture_completion_owner = None
        self.source_capture_ordinal = 0
        self.source_capture_work = []
        self.source_copies = []
        self.modules = None
        self.coverage_configuration = None
        self.authentication_revision = None
        self._runtime_ordinals = {site: 0 for site in _SCOPE_RUNTIME_SITES}
        try:
            require(PACKAGE.resolve() == PACKAGE and sys.version_info >= (3, 11), "E_RUNTIME")
            for path in (scope_path, set_path, bundle_root, git_root, output.parent):
                require(path.is_absolute() and path.resolve() == path, "E_RELATION")
            for left, right in ((bundle_root, git_root), (bundle_root, self.scratch),
                                (git_root, self.scratch), (PACKAGE, self.scratch)):
                require(left != right and left not in right.parents and right not in left.parents)
            self.captures = self.scratch / "reader-captures"
            require(self.captures.is_dir() and self.captures.resolve() == self.captures
                    and stat.S_IMODE(self.captures.stat().st_mode) == 0o700
                    and self.captures.stat().st_uid == os.getuid(), "E_RUNTIME")
            self.runtime = self.scratch / "reader-runtime"
            require(self.runtime.is_dir() and self.runtime.resolve() == self.runtime
                    and stat.S_IMODE(self.runtime.stat().st_mode) == 0o700
                    and self.runtime.stat().st_uid == os.getuid(), "E_RUNTIME")
            self.private_slot = 0
            if store_session is not None:
                for index in range(4096):
                    (self.captures / f"gate-{index:04d}").mkdir(mode=0o700)
                    (self.runtime / f"gate-{index:04d}").mkdir(mode=0o700)
            self.no_hooks = self.runtime / "no-hooks"
            require(self.no_hooks.is_dir() and self.no_hooks.resolve() == self.no_hooks
                    and stat.S_IMODE(self.no_hooks.stat().st_mode) == 0o700
                    and self.no_hooks.stat().st_uid == os.getuid(), "E_RUNTIME")
            self.python = self.hold(Path(sys.executable), c.EXECUTABLE_LIMIT)
            self.consumer = self.hold(SOURCE, c.EXECUTABLE_LIMIT)
            self.self_source = self.hold(Path(__file__).absolute(), c.EXECUTABLE_LIMIT)
            self.package_sources = {}
            for relative in _reader_base_package_names_values():
                if relative != "config/construction-mode.json" or os.path.lexists(PACKAGE / relative):
                    self.package_sources[relative] = self.hold(PACKAGE / relative, c.EXECUTABLE_LIMIT)
            self.scope_raw = self.hold(scope_path, c.DOCUMENT_LIMIT).raw
            self.set_raw = self.hold(set_path, c.DOCUMENT_LIMIT).raw
            self.scope, self.shadow_set = parse(self.scope_raw), parse(self.set_raw)
            self.scope_body = self.scope["body"]
            self.bundle_root = self.directory(bundle_root)
            self.git_root = git_root
            self.darwin = c._DarwinChildOwner(self.python, self.consumer, self.deadline, self)
            self.writer = self.load_writer()
            self.enforced = self.writer.e
            self.capture_completion_owner = self.enforced._load_capture_completion_owner()
            self.modules = self.enforced.core_modules(self.package_sources["core/v2/generation-registry.json"].raw)
            for source in sorted(self.modules.glob("*.jq")):
                self.package_sources[str(source.relative_to(PACKAGE))] = self.hold(source, c.EXECUTABLE_LIMIT)
            for source in (self.modules.parent / "core-ingress.sh", self.modules.parent / "contracts.jq"):
                self.package_sources[str(source.relative_to(PACKAGE))] = self.hold(source, c.EXECUTABLE_LIMIT)
            for relative in _reader_fixed_package_names_values():
                self.package_sources[relative] = self.hold(PACKAGE / relative, c.EXECUTABLE_LIMIT)
            self.jq = self.hold(Path(os.environ["YSTACK_SCOPE_JQ"]), c.EXECUTABLE_LIMIT)
            require(self.jq.sha256 == c.JQ_SHA256[sys.platform], "E_RUNTIME")
            self.bash = self.hold(Path("/bin/bash").resolve(), c.EXECUTABLE_LIMIT, hardlinks=True)
            self.git_binary = self.hold(Path("/usr/bin/git"), c.EXECUTABLE_LIMIT, hardlinks=True)
            self.git = c._ReadOnlyGit(str(git_root), self)
            self.owned.append(self.git)
            self.git.shape(self.scope_body["qualified_identity"]["target_revision"]["hash_algorithm"])
            self.recheck()
            self._initialize_replay_outputs()
        except BaseException:
            self.close()
            raise

    def hold(self, path, limit, hardlinks=False):
        item = c._hold_bytes(str(path), limit, hardlinks=hardlinks)
        self.owned.append(item)
        try:
            outputs = getattr(self, "replay_outputs", None)
            if outputs is not None:outputs["holds"].append((self, item))
        except BaseException as error:self._replay_output_failure(error, "reader-held-output")
        return item

    def directory(self, path):
        item = c._open_held(str(path), True, lambda _fd, _state, _ancestor: True, "E_RELATION")
        self.owned.append(item)
        return item

    def load_writer(self):
        spec = importlib.util.spec_from_file_location("scope_shadow_writer", PACKAGE / "shadow/v1/write-shadow.py")
        require(spec is not None and spec.loader is not None, "E_RUNTIME")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        require(Path(module.__file__).absolute() == PACKAGE / "shadow/v1/write-shadow.py")
        for loaded, expected in ((module.e, "shadow/v1/enforced-reproduction.py"),
                                 (module.c, "shadow/v1/_consumer.py")):
            require(Path(loaded.__file__).absolute() == PACKAGE / expected)
        self.recheck()
        return module

    def capture(self, name, raw):
        require("/" not in name and name not in {"", ".", ".."})
        if self.store_session is not None:
            require(len(self.inputs) < 4096, "E_LIMIT")
            path = self.captures / f"gate-{len(self.inputs):04d}" / name
        else:
            path = self.captures / name
        if self.store_session is not None:
            written = write_exclusive(path, raw, resolver=self.darwin)
        else:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
            try:
                sent = 0
                while sent < len(raw):
                    count = os.write(fd, raw[sent:])
                    require(count > 0, "E_RUNTIME")
                    sent += count
            finally:
                os.fsync(fd)
                os.close(fd)
        if self.store_session is not None:
            held = self.hold(path, max(c.DOCUMENT_LIMIT, len(raw)))
            require(held.raw == raw and c._identity(held.held.before) == written, "E_STALE")
        self.inputs.append((path, raw))
        return path

    def fresh_runtime_directory(self, name):
        if self.store_session is None:
            path = self.runtime / name
            path.mkdir(mode=0o700)
            return path
        require(self.private_slot < 4096, "E_LIMIT")
        path = self.runtime / f"gate-{self.private_slot:04d}"
        self.private_slot += 1
        require(not list(path.iterdir()), "E_STALE")
        return path

    def record_command(self, role, argv, executable, component):
        require(self.commands_open, "E_RUNTIME")
        require(len(self.commands) < 4096, "E_LIMIT")
        if self.store_session is not None:
            self.gate_commands.append({"role": role, "argv": argv, "executable_sha256": executable, "component_sha256": component})
        self.commands.append({"role": role, "argv_sha256": c.digest(c.canonical(argv)),
                              "executable_sha256": executable, "component_sha256": component})

    def terminal(self, observation):
        require(self.commands_open, "E_RUNTIME")
        self.commands_open = False
        self.seal_source_captures()
        raw = c.canonical({"schema_version": 1, "kind": "scope_shadow_evidence_terminal",
            "id": self.scope["id"], "body": {
                "observation_sha256": c.digest(observation), "commands": self.commands}})
        require(0 < len(raw) <= c.DOCUMENT_LIMIT, "E_LIMIT")
        write_exclusive(self.output.parent / "terminal.json", raw, resolver=self.darwin)
        return raw

    def execute_git(self, argv, limit):
        self.recheck()
        self.record_command("scope-git-inspection", argv, self.git_binary.sha256,
                            self.consumer.sha256)
        result = self.darwin._foreground(argv, b"", limit, 65536,
            min(30, self.deadline - c._clock_value('scope/v1/read-shadow-evidence.py:287:0',time.monotonic(),'monotonic')), self.environment())
        self.recheck()
        return result

    def environment(self):
        return {"PATH": str(self.jq.held.path.rsplit("/", 1)[0]) + ":/usr/bin:/bin",
            "LC_ALL": "C", "LANG": "C", "HOME": str(self.runtime), "TMPDIR": str(self.runtime),
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_NO_REPLACE_OBJECTS": "1", "GIT_NO_LAZY_FETCH": "1", "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0", "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath",
            "GIT_CONFIG_VALUE_0": str(self.no_hooks),
            **({"YSTACK_GATE_DEADLINE": str(self.deadline)} if self.store_session is not None else {})}

    def component(self, relative, arguments, raw=b"", limit=c.DOCUMENT_LIMIT):
        source = self.package_sources[relative]
        argv = ["/bin/bash", "-p", str(PACKAGE / relative), *map(str, arguments)]
        self.recheck()
        self.record_command("scope-fixed-check", argv, self.bash.sha256, source.sha256)
        result = self.darwin._foreground(argv, raw, limit, 65536,
            min(120, self.deadline - c._clock_value('scope/v1/read-shadow-evidence.py:306:0',time.monotonic(),'monotonic')), self.environment())
        self.recheck()
        return result

    def jq_check(self, relative, arguments, raw=b"", limit=c.DOCUMENT_LIMIT):
        source = self.package_sources[relative]
        argv = [self.jq.held.path, "-L", str(self.modules), *map(str, arguments), "-f", str(PACKAGE / relative)]
        self.recheck()
        self.record_command("scope-fixed-json-check", argv, self.jq.sha256, source.sha256)
        result = self.darwin._foreground(argv, raw, limit, 65536,
            min(30, self.deadline - c._clock_value('scope/v1/read-shadow-evidence.py:316:0',time.monotonic(),'monotonic')), self.environment())
        self.recheck()
        return result

    def recheck(self):
        for item in self.owned:
            item.recheck("E_STALE")
        for path, raw in self.inputs:
            require(path.read_bytes() == raw, "E_STALE")
        if self.anchor is not None:
            self.anchor.recheck("E_STALE")

    def anchor_for(self):
        if self.anchor is None:
            self.anchor = c.load_anchor(self.darwin if sys.platform == "darwin" else None,
                                       self.darwin if sys.platform == "darwin" else None)
            self.owned.append(self.anchor)
            try:
                self.anchor.private_observations["entropy"] = {}
                self.anchor.private_observations["commands"] = {"runtime_values": []}
                self.anchor.scope_runtime_owner = self
                require(self.capture_completion_owner is not None, "E_STORE")
                self.capture_completion_owner.authenticate(self.anchor)
                self.anchor.capture_completion_owner = self.capture_completion_owner
            except Exception as error:
                self.anchor.private_observations["unusable"] = True
                self.anchor.private_observations["completion_owner_failure"] = {
                    "category": type(error).__name__, "errno": getattr(error, "errno", None)}
                if getattr(error, "_scope_signal_cancel", False):
                    raise
        return self.anchor

    def _runtime_equal(self, site, expected, value):
        result = None
        anchor = self.anchor_for()
        try:
            ordinal = self._runtime_ordinals[site]
            self._runtime_ordinals[site] = ordinal + 1
            row = {"site": site, "ordinal": ordinal, "value": value}
            result = _scope_runtime_equal_values(expected, row, site, ordinal)
            rows = anchor.private_observations["commands"]["runtime_values"]
            require(len(rows) < 4096, "E_LIMIT")
            rows.append(row)
            for field in ("files", "read_bytes", "write_bytes", "physical_bytes", "export_read_bytes",
                          "export_write_bytes", "export_physical_bytes", "export_files"):
                anchor.recording_work.setdefault(field, 0)
            anchor.recording_work.setdefault("calls", {})
            c._capture_observe(anchor.recording_work, "M", "scope-runtime-value", row)
        except Exception as error:
            anchor.private_observations["unusable"] = True
            anchor.recording_work["scope_runtime_incomplete"] = True
            cancellation = error if getattr(error, "_scope_signal_cancel", False) else None
            try:c._capture_observation_error(anchor.recording_work, "M", "scope-runtime-value", error)
            except Exception as observed:
                anchor.recording_work["scope_runtime_incomplete"] = True
                if cancellation is None and getattr(observed, "_scope_signal_cancel", False):cancellation = observed
            if cancellation is not None:raise cancellation
            if result is None:result = expected == value
        return result

    def _recheck_source_copies(self, parent):
        for copied in self.source_copies:
            if copied.recorder_parent_path == parent.path:
                copied.recheck()
                require(not copied.closed and not copied.leaf.get("metadata_failure")
                        and not c._capture_work_incomplete(copied.leaf), "E_STORE")

    def _own_source_copy(self, copied, parent, preserve_cancellation=False):
        require(isinstance(copied, c._HeldCaptureCopy) and not copied.closed, "E_STORE")
        try:
            require(not any(item is copied for item in self.source_copies), "E_STORE")
            self.source_copies.append(copied)
            for item in self.source_copies:
                if item.recorder_parent_path == parent.path:
                    item.refresh_recorder_parent(parent)
        except BaseException as primary:
            if self.source_copies and self.source_copies[-1] is copied:
                self.source_copies.pop()
            try:copied.close()
            except BaseException as closing:
                if preserve_cancellation or isinstance(copied, c._HeldSourceConfigurationCopy):
                    primary_marked = isinstance(primary, KeyboardInterrupt) or getattr(primary, "_scope_signal_cancel", False)
                    closing_marked = isinstance(closing, KeyboardInterrupt) or getattr(closing, "_scope_signal_cancel", False)
                    cancellation = primary if primary_marked else closing if closing_marked else None
                    try:copied._failed(primary, "scope-source-configuration-registration", primary)
                    except BaseException as observed:
                        if cancellation is None and (isinstance(observed, KeyboardInterrupt) or getattr(observed, "_scope_signal_cancel", False)):cancellation = observed
                    try:copied._failed(closing, "scope-source-configuration-registration-close", primary)
                    except BaseException as observed:
                        if cancellation is None and (isinstance(observed, KeyboardInterrupt) or getattr(observed, "_scope_signal_cancel", False)):cancellation = observed
                    try:copied._transfer()
                    except BaseException as observed:
                        if cancellation is None and (isinstance(observed, KeyboardInterrupt) or getattr(observed, "_scope_signal_cancel", False)):cancellation = observed
                    if cancellation is not None and cancellation is not primary:raise cancellation
                elif getattr(closing, "_scope_signal_cancel", False) and not getattr(primary, "_scope_signal_cancel", False):
                    raise
            raise

    def _close_source_copies(self, primary=None, preserve_cancellation=False):
        copies, self.source_copies = self.source_copies, []
        primary = sys.exc_info()[1] if primary is None else primary
        cancellation = None
        configuration_cancellation = False
        if preserve_cancellation:
            first = primary if isinstance(primary, KeyboardInterrupt) or getattr(primary, "_scope_signal_cancel", False) else None
            for copied in reversed(copies):
                try:copied.recheck()
                except BaseException as error:
                    if first is None and (isinstance(error, KeyboardInterrupt) or getattr(error, "_scope_signal_cancel", False)):first = error
                    try:copied._failed(error, "scope-P-final-recheck", primary)
                    except BaseException as observed:
                        if first is None and (isinstance(observed, KeyboardInterrupt) or getattr(observed, "_scope_signal_cancel", False)):first = observed
                try:copied.close()
                except BaseException as error:
                    if first is None and (isinstance(error, KeyboardInterrupt) or getattr(error, "_scope_signal_cancel", False)):first = error
                    try:copied._failed(error, "scope-P-final-close", primary)
                    except BaseException as observed:
                        if first is None and (isinstance(observed, KeyboardInterrupt) or getattr(observed, "_scope_signal_cancel", False)):first = observed
            if first is not None and first is not primary:raise first
            return
        for copied in reversed(copies):
            try:
                try:copied.recheck()
                finally:copied.close()
            except BaseException as error:
                if preserve_cancellation or isinstance(copied, c._HeldSourceConfigurationCopy):
                    if cancellation is None and (isinstance(error, KeyboardInterrupt) or getattr(error, "_scope_signal_cancel", False)):
                        cancellation, configuration_cancellation = error, True
                elif not isinstance(error, Exception):raise
                try:copied._failed(error, "scope-P-final-close", primary)
                except BaseException as observed:
                    if not preserve_cancellation and not isinstance(copied, c._HeldSourceConfigurationCopy) and not isinstance(observed, Exception):raise
                    if cancellation is None and (getattr(observed, "_scope_signal_cancel", False)
                            or (preserve_cancellation or isinstance(copied, c._HeldSourceConfigurationCopy)) and isinstance(observed, KeyboardInterrupt)):
                        cancellation = observed
                        configuration_cancellation = preserve_cancellation or isinstance(copied, c._HeldSourceConfigurationCopy)
                if getattr(error, "_scope_signal_cancel", False) and cancellation is None:
                    cancellation = error
        if cancellation is not None and not getattr(primary, "_scope_signal_cancel", False) and not (
                configuration_cancellation and isinstance(primary, KeyboardInterrupt)):
            raise cancellation

    def retain_source_runtime(self, request_raw, sudo=None, preserve_cancellation=False):
        anchor, parent, cancellation = self.anchor_for(), None, None
        work, case_work, retention_failed = {}, None, False
        def failed(site, error):
            nonlocal cancellation, retention_failed
            retention_failed = True
            if preserve_cancellation:
                if cancellation is None and (isinstance(error, KeyboardInterrupt) or getattr(error, "_scope_signal_cancel", False)):cancellation = error
                try:
                    anchor.private_observations["unusable"] = True
                    c._capture_observation_error(work, "M", site, error)
                except BaseException as observed:
                    if cancellation is None and (isinstance(observed, KeyboardInterrupt) or getattr(observed, "_scope_signal_cancel", False)):cancellation = observed
                    try:work["accounting_incomplete"] = True
                    except BaseException as reporting:
                        if cancellation is None and (isinstance(reporting, KeyboardInterrupt) or getattr(reporting, "_scope_signal_cancel", False)):cancellation = reporting
                return
            anchor.private_observations["unusable"] = True
            if getattr(error, "_scope_signal_cancel", False) and cancellation is None:
                cancellation = error
            try:
                c._capture_observation_error(work, "M", site, error)
            except Exception as observed:
                work["accounting_incomplete"] = True
                if getattr(observed, "_scope_signal_cancel", False) and cancellation is None:
                    cancellation = observed
        try:
            c._capture_work_values(work, "scope-runtime-parent")
            anchor.recording_work.setdefault("scope_runtime_parent_work", []).append(work)
            parent = c._open_held(str(self.captures), True,
                c._store_rule(os.geteuid(), os.getegid(), 0o700, True, self.darwin), "E_STORE",
                recording_work=work, accounting_kind="M")
            key = str(parent.before.st_dev) + ":" + str(parent.before.st_ino)
            case_work = c._capture_work_values(anchor.recording_work, key)
            c._capture_transfer_work(work, anchor.recording_work, case_work)
            inputs = (("sudo", sudo),) if sudo is not None else (
                ("python", self.python), ("jq", self.jq),
                ("bash", self.bash), ("git", self.git_binary))
            for role, item in inputs:
                require(isinstance(item, c._HeldBytes), "E_STORE")
                self._recheck_source_copies(parent)
                copied = anchor.retain_runtime_acquisition(parent, role, item.held, item.raw, request_raw)
                self._own_source_copy(copied, parent, preserve_cancellation)
        except BaseException as error:
            if not preserve_cancellation and not isinstance(error, Exception):raise
            failed("scope-runtime-retain", error)
        finally:
            if parent is not None:
                try:
                    parent.close()
                except BaseException as error:
                    if not preserve_cancellation and not isinstance(error, Exception):raise
                    failed("scope-runtime-parent-close", error)
        try:
            if case_work is not None:
                c._capture_transfer_work(work, anchor.recording_work, case_work)
            else:
                work["transfer_incomplete"] = True
                anchor.recording_work["accounting_incomplete"] = True
            if c._capture_work_incomplete(work) or c._capture_work_incomplete(anchor.recording_work):
                anchor.private_observations["unusable"] = True
            c._capture_accounting_receipt(anchor)
        except BaseException as error:
            if not preserve_cancellation and not isinstance(error, Exception):raise
            failed("scope-runtime-tail-receipt", error)
        if retention_failed:
            try:self._close_source_copies(cancellation, preserve_cancellation)
            except BaseException as error:
                if not preserve_cancellation and not isinstance(error, Exception):raise
                if (getattr(error, "_scope_signal_cancel", False) or preserve_cancellation and isinstance(error, KeyboardInterrupt)) and cancellation is None:
                    cancellation = error
        if cancellation is not None:
            raise cancellation

    def retain_anchor_inputs(self, values):
        parent, copied, first = None, None, None
        try:
            require(self.commands_open and self.anchor is not None and self.store_session is not None
                and self.anchor.scope_runtime_owner is self, "E_STORE")
            for item in self.source_copies:
                if getattr(item, "anchor_input_reader", None) is self:
                    require(not item.closed and set(item.anchor_input_members) == set(values), "E_STORE")
                    for key, (raw, original) in values.items():
                        old = item.anchor_input_members[key]
                        require(old["raw"] == raw and old["original"] is original and original.components, "E_STORE")
                    item.recheck()
                    return item
            work = self.replay_output_work
            parent = c._open_held(str(self.captures / "gate-4095"), True,
                c._store_rule(os.geteuid(), os.getegid(), 0o700, True, self.darwin), "E_STORE",
                recording_work=work, accounting_kind="M")
            self._recheck_source_copies(parent)
            copied = self.anchor.retain_scope_anchor_inputs(parent, self, values)
            self._own_source_copy(copied, parent, preserve_cancellation=True)
        except BaseException as error:
            first = error
        finally:
            if parent is not None:
                try:parent.close()
                except BaseException as closing:
                    if first is None or not (isinstance(first, KeyboardInterrupt) or getattr(first, "_scope_signal_cancel", False)) and (
                            isinstance(closing, KeyboardInterrupt) or getattr(closing, "_scope_signal_cancel", False)):first = closing
                    try:c._capture_observation_error(self.replay_output_work, "M", "scope-anchor-parent-close", closing)
                    except BaseException as observed:
                        if first is None or not (isinstance(first, KeyboardInterrupt) or getattr(first, "_scope_signal_cancel", False)) and (
                                isinstance(observed, KeyboardInterrupt) or getattr(observed, "_scope_signal_cancel", False)):first = observed
        if first is not None:
            try:self._close_source_copies(first, preserve_cancellation=True)
            except BaseException as closing:
                if not (isinstance(first, KeyboardInterrupt) or getattr(first, "_scope_signal_cancel", False)) and (
                        isinstance(closing, KeyboardInterrupt) or getattr(closing, "_scope_signal_cancel", False)):first = closing
            self._replay_output_failure(first, "reader-anchor-copy")
            return None
        return copied

    def _retain_source_configuration(self, source, parent, ordinal):
        try:
            require(source.anchor is self.anchor and source.anchor.scope_runtime_owner is self
                    and any(item is source for item in self.owned)
                    and any(item is source.configuration for item in self.owned), "E_STORE")
            copied = source.anchor.retain_source_configuration(parent, source, ordinal)
            self._own_source_copy(copied, parent)
            return None
        except BaseException as error:
            cancellation = error if isinstance(error, KeyboardInterrupt) or getattr(error, "_scope_signal_cancel", False) else None
            try:
                source.anchor.private_observations["unusable"] = True
                c._capture_observation_error(source.anchor.recording_work, "M", "scope-source-configuration", error)
            except BaseException as observed:
                if cancellation is None and (isinstance(observed, KeyboardInterrupt) or getattr(observed, "_scope_signal_cancel", False)):
                    cancellation = observed
            try:self._close_source_copies(cancellation)
            except BaseException as closing:
                if cancellation is None and (isinstance(closing, KeyboardInterrupt) or getattr(closing, "_scope_signal_cancel", False)):
                    cancellation = closing
            return cancellation

    def retain_source_capture(self, source):
        parent = None
        cancellation = None
        configuration_cancel = None
        retention_failed = False
        try:
            require(len(self.source_capture_work) < 4096, "E_LIMIT")
            if hasattr(source, "capture_work"):
                self.source_capture_work.append(source.capture_work)
            require(hasattr(source, "capture") and self.source_capture_ordinal < 4096, "E_STORE")
            ordinal = self.source_capture_ordinal
            self.source_capture_ordinal += 1
            destination = self.captures
            if self.store_session is not None:
                slot = 4095 - ordinal
                require(slot >= len(self.inputs), "E_LIMIT")
                destination = self.captures / ("gate-%04d" % slot)
            parent = c._open_held(str(destination), True,
                c._store_rule(os.geteuid(), os.getegid(), 0o700, True, self.darwin), "E_STORE")
            self._recheck_source_copies(parent)
            copied = source.copy_source_capture(parent, ordinal, source.anchor.recording_work)
            self._own_source_copy(copied, parent)
            copied.scope_source = source
            copied.scope_source_ordinal = ordinal
            configuration_cancel = self._retain_source_configuration(source, parent, ordinal)
            cancellation = configuration_cancel
        except Exception as error:
            retention_failed = True
            source.anchor.private_observations["unusable"] = True
            source.anchor.private_observations["source_copy_failure"] = {
                "category": type(error).__name__,
                "errno": getattr(error, "os_errno", getattr(error, "errno", None))}
            if getattr(error, "_scope_signal_cancel", False):
                cancellation = error
        finally:
            if parent is not None:
                if configuration_cancel is not None:
                    try:parent.close()
                    except BaseException as error:
                        try:c._capture_observation_error(source.anchor.recording_work, "M", "scope-source-configuration-parent-close", error)
                        except BaseException:pass
                        try:configuration_cancel.__cause__ = error
                        except BaseException:pass
                else:
                    try:
                        parent.close()
                    except OSError as error:
                        retention_failed = True
                        source.anchor.private_observations["unusable"] = True
                        source.anchor.private_observations["source_copy_close_errno"] = error.errno
                        if getattr(error, "_scope_signal_cancel", False) and cancellation is None:
                            cancellation = error
        if retention_failed:
            try:self._close_source_copies(cancellation)
            except Exception as error:
                if getattr(error, "_scope_signal_cancel", False) and cancellation is None:
                    cancellation = error
        if cancellation is not None:
            raise cancellation

    def seal_source_captures(self):
        parent = None
        cancellation = None
        try:
            require(self.anchor is not None, "E_STORE")
            parent = c._open_held(str(self.captures), True,
                c._store_rule(os.geteuid(), os.getegid(), 0o700, True, self.darwin), "E_STORE")
            self._close_source_copies()
            self.enforced._seal_capture_recording(self.anchor, parent)
        except Exception as error:
            if self.anchor is not None:
                self.anchor.private_observations["unusable"] = True
                self.anchor.private_observations["source_seal_failure"] = {
                    "category": type(error).__name__, "errno": getattr(error, "errno", None)}
            if getattr(error, "_scope_signal_cancel", False):
                cancellation = error
        finally:
            if parent is not None:
                try:
                    key = str(parent.before.st_dev) + ":" + str(parent.before.st_ino)
                    case_work = c._capture_work_values(self.anchor.recording_work, key)
                    for work in self.source_capture_work:
                        c._capture_transfer_work(work, self.anchor.recording_work, case_work)
                except Exception as error:
                    self.anchor.private_observations["unusable"] = True
                    self.anchor.private_observations["source_tail_accounting_failure"] = {
                        "category": type(error).__name__, "errno": getattr(error, "errno", None)}
                    if getattr(error, "_scope_signal_cancel", False) and cancellation is None:
                        cancellation = error
                try:
                    parent.close()
                except OSError as error:
                    self.anchor.private_observations["unusable"] = True
                    self.anchor.private_observations["source_seal_close_errno"] = error.errno
                    if getattr(error, "_scope_signal_cancel", False) and cancellation is None:
                        cancellation = error
            if self.anchor is not None:
                if c._capture_work_incomplete(self.anchor.recording_work):
                    self.anchor.private_observations["unusable"] = True
                self.anchor.private_observations["recording_sealed"] = (
                    self.anchor.private_observations.get("recording_sealed", False)
                    and not self.anchor.private_observations.get("unusable", False)
                    and self.anchor.private_observations.get("accounting", {}).get("complete") is True)
        if cancellation is not None:
            raise cancellation

    def release_stores(self):
        self._close_source_copies()
        self.recheck()
        stores = [item for item in self.owned if isinstance(item, c._HeldStoreRead)]
        for item in stores:
            item.recheck()
        for item in stores:
            item.close()
            self.owned.remove(item)

    def close(self):
        first = None
        try:self._close_source_copies()
        except BaseException as error:first = error
        try:owned = list(self.owned)
        except BaseException:
            if getattr(first, "_scope_signal_cancel", False):raise first
            raise
        for item in reversed(owned):
            try:
                item.close()
                self.owned.remove(item)
            except BaseException as exc:
                if first is None:
                    first = exc
        if self.capture_completion_owner is not None:
            self.enforced._close_capture_completion_owner(self.capture_completion_owner)
        if first is not None:
            raise first

    def _replay_output_failure(self, error, site):
        first = error if isinstance(error, (KeyboardInterrupt, SystemExit)) or getattr(error, "_scope_signal_cancel", False) else None
        try:
            self.replay_output_state[0] = True
            if getattr(self, "anchor", None) is not None:self.anchor.private_observations["unusable"] = True
            self.replay_output_errors.append({"site": site, "error": error,
                "category": type(error).__name__, "errno": getattr(error, "errno", None)})
        except BaseException as reporting:
            if first is None and (isinstance(reporting, (KeyboardInterrupt, SystemExit)) or getattr(reporting, "_scope_signal_cancel", False)):first = reporting
        if first is not None:raise first

    def _initialize_replay_outputs(self):
        try:
            self.replay_output_state = [True]
            self.replay_output_errors = []
            self.replay_outputs = {"bundles": [], "git": [], "stores": [], "anchor": [], "holds": []}
            self.replay_output_work = {}
            c._capture_work_values(self.replay_output_work, "scope-replay-outputs")
            self.replay_output_work["accounting_incomplete"] = True
            self.replay_output_state[0] = False
        except Exception as error:
            self._replay_output_failure(error, "reader-output-initialize")

    def _retain_replay_output(self, group, key, value):
        try:
            require(group in {"bundles", "git", "stores", "anchor"} and type(key) is bytes)
            self.replay_outputs[group].append((key, value))
            if self.anchor is not None:
                self.anchor.recording_work["replay_output_work"] = self.replay_output_work
            c._capture_observe(self.replay_output_work, "M", "scope-replay-output", {
                "group": group, "ordinal": len(self.replay_outputs[group]) - 1,
                "record_bytes": len(key)})
        except BaseException as error:
            self._replay_output_failure(error, "reader-output-" + group)

    def fixed_bundle(self, held):
        facts = self._authenticate(held.files)
        held.recheck()
        return facts

    def _authenticate(self, files):
        anchor = self.anchor_for()
        fixed = _authentication_installed_names_values()
        require(all(files[name] == anchor.installed[role][0] for name, role in fixed.items()))
        incident, body, revision = _authentication_documents_values(files)
        require(same(revision, self.authentication_revision or self.scope_body["qualified_identity"]["target_revision"])
                and body["target_repository_id"] == self.scope_body["target_repository_id"])
        selected = _authentication_environment_values(anchor.registry[1], body)
        accepted = _authentication_environment_values(anchor.accepted[1], body)
        require(len(selected) == len(accepted) == 1)
        registry = selected[0]
        require(_authentication_registry_matches_values(registry, body)
                and registry["source_root_commit"] == (self.scope_body["coverage"]["coverage_base"]["commit_id"]
                    if "coverage" in self.scope_body else revision["commit_id"]))
        receipt = _authentication_receipt_values(files, accepted)
        observation = c.verifier_observation(anchor, body["environment"]["environment_id"], body["target_repository_id"])
        observer_path = self.capture("verifier-" + str(len(self.inputs)) + ".json", observation)
        provenance = parse(files["consumer-provenance.json"])
        require(same(provenance["body"]["observation"], parse(observation))
                and provenance["body"]["observation_sha256"] == c.digest(observation))
        retained = {name: self.capture(str(len(self.inputs)) + "-" + name, raw)
                    for name, raw in files.items()}
        evaluation = self.component("control/v1/evaluate-bound-sandbox.sh",
            ["evaluate", retained["duty-evaluation.json"], retained["claim.json"], observer_path])
        require(evaluation == files["sandbox-evaluation.json"] and parse(evaluation)["body"]["verdict"] == "satisfied")
        self.component("shadow/v1/validate-incident.sh", ["validate", retained["incident.json"]])
        material_input = parse(files["materialization-input.json"])
        identity = parse(files["qualified-identity.json"])
        instruction = self.enforced.make_instruction(incident)
        if body["record_form"] == "enforced-reproduction.v1":
            self.enforced.validate_input_relations(material_input, incident, parse(files["claim.json"]), identity, instruction)
        else:
            require(same(identity["body"]["stage_request_ref"], self.enforced.pair_ref(material_input["stage_request"]))
                    and same(identity["body"]["resolved_profile_ref"], self.enforced.pair_ref(material_input["resolved_profile"]))
                    and identity["body"]["verification_instructions_ref"]["sha256"] == c.digest(instruction))
        valid = self.jq_check("shadow/v1/qualified-identity.jq", ["-r", "--arg", "repository_id",
            body["target_repository_id"], "--arg", "hash_algorithm", revision["hash_algorithm"],
            "--arg", "commit_id", revision["commit_id"]], files["qualified-identity.json"])
        require(valid == b"")
        self.jq_check("adapters/local-git-materializer/v1/protocol.jq",
            ["-e", "--arg", "command", "validate-input"], files["materialization-input.json"])
        response = parse(files["materialization-response.json"])
        response_check = self.enforced.response_check(material_input, files["materialization-response.json"])
        self.jq_check("adapters/local-git-materializer/v1/protocol.jq",
            ["-e", "--arg", "command", "validate-response"], response_check)
        prep, manifest = parse(files["preparation-record.json"]), parse(files["preparation-manifest.json"])
        launch = _launch_expectation_values(files, anchor.config, registry, body, prep,
            instruction, self.enforced.control(anchor, evaluation))
        store = c._HeldStoreRead(anchor, launch["id"])
        self.owned.append(store)
        mapping = _authentication_store_names_values()
        require(set(store.snapshots) - {"capture.json", "sandbox-export.bin"} == set(mapping)
                and all(store.snapshots[key] == files[name] for key, name in mapping.items()))
        self.origin(parse(files["origin-observation.json"]), store.snapshots, launch["id"], anchor)
        self.origin(parse(store.observation), store.snapshots, launch["id"], anchor)
        checked = self.component("enforcement/v1/check-sandbox-receipt.sh", ["check-bound",
            retained["sandbox-receipt.json"], retained["sandbox-expectation.json"], retained["sandbox-evaluation.json"], observer_path])
        require(checked == files["sandbox-check.json"] and parse(checked)["body"]["check_verdict"] == "valid"
                and parse(checked)["body"]["enforcement_verdict"] == "satisfied")
        result_raw, result = self.enforced.payload_result(store.snapshots, parse(files["evidence-manifest.json"]),
            instruction, manifest, receipt)
        require(result_raw == files["file-digest-result.json"])
        write = body.get("write")
        self.writer._record_relations(files, incident, result, store.observation, anchor, write)
        self.record_refs(files, body, launch["id"], anchor)
        trace_receipt = self.component("telemetry/v1/validate-trace-ledger.sh",
            ["validate", incident["id"], launch["id"], retained["trace-ledger.json"]])
        require(trace_receipt == files["trace-receipt.json"])
        self.provenance(files, instruction, observation, launch["id"], write is not None)
        self.git_relations(files, material_input, incident, body)
        store.recheck()
        anchor.recheck("E_STALE")
        facts = _bundle_facts_values(files, checked, store.observation, body)
        try:self._retain_replay_output("stores", files["shadow-record.json"], (store, files, retained, store.storage_rows))
        except BaseException as error:self._replay_output_failure(error, "reader-store-retention")
        return facts

    def origin(self, document, snapshots, attempt_id, anchor):
        return _origin_projection_values(document, snapshots, attempt_id, anchor.config)

    def record_refs(self, files, body, attempt, anchor):
        return _record_refs_values(files, body, attempt, anchor.config)

    def provenance(self, files, instruction, observation, attempt, write):
        keys, body = _provenance_document_values(files, attempt)
        source = "shadow/v1/write-shadow.py" if write else "shadow/v1/enforced-reproduction.py"
        require(_provenance_content_matches_values(body, instruction, observation)
                and body["consumer_source_sha256"] == self.package_sources[source].sha256
                and body["python_sha256"] == self.python.sha256 and body["jq_sha256"] == self.jq.sha256
                and body["helper_source_sha256"] == c.HELPER_SOURCE_SHA256
                and all(c._sha(body[key]) for key in keys if key.endswith("sha256")))
        native = body["native_release"]
        require(_provenance_native_shape_matches_values(native)
                and self._runtime_equal("scope.soabi", native["python_abi"], sysconfig.get_config_var("SOABI"))
                and _provenance_native_identity_matches_values(native, body)
                and native["python_locator_sha256"] == c.digest(sys.executable.encode()))
        for key, relative in (("source_sha256", "shadow/v1/_cancel_release.c"),
                              ("build_script_sha256", "shadow/v1/build-cancel-release.sh")):
            held = self.hold(PACKAGE / relative, c.EXECUTABLE_LIMIT)
            require(native[key] == held.sha256)
        roles = _provenance_roles_values()
        fixed = {"helper-version": (body["helper_executable_sha256"], body["helper_source_sha256"]),
            "jq-version": (self.jq.sha256, self.jq.sha256),
            "darwin-acl-uuid-resolution": (self.python.sha256, self.consumer.sha256),
            "darwin-group-membership": (self.python.sha256, self.consumer.sha256)}
        supervisor = next(item for item in self.anchor.held if item.path == c.ANCHOR + "/host-supervisor.py")
        sudo = self.enforced.fixed_sudo()
        self.owned.append(sudo)
        sudo_sha = sudo.sha256
        supervisor_raw = supervisor.read(c.EXECUTABLE_LIMIT, "E_STALE")
        fixed["sandbox-launch-boundary"] = (sudo_sha, c.digest(supervisor_raw))
        for role, relative in roles.items():
            component = self.hold(PACKAGE / relative, c.EXECUTABLE_LIMIT)
            executable = (self.git_binary.sha256 if role == "write-git-inspection" else
                self.python.sha256 if role.startswith("candidate-") else
                self.jq.sha256 if role in {"write-materialization-input", "materializer-input-validation",
                    "materializer-response-validation", "qualified-identity-validation"} else self.bash.sha256)
            fixed[role] = (executable, component.sha256)
        _provenance_commands_values(body, fixed)
        try:
            verifier_raw, verifier = self.anchor.scope_verifier_input
            require(type(verifier_raw) is bytes and any(item is verifier for item in self.anchor.held)
                and verifier.path == self.anchor.config["identity_paths"]["verifier"] and verifier.components, "E_STORE")
            values = {"host": (self.anchor.config_raw, next(item for item in self.anchor.held
                if item.path == c.ANCHOR + "/host-config.json")), "verifier": (verifier_raw, verifier),
                "supervisor": (supervisor_raw, supervisor)}
            for role, (raw, _sha) in self.anchor.installed.items():
                values["installed-" + role] = (raw, next(item for item in self.anchor.held
                    if item.path == self.anchor.config["installed_files"][role]))
            self._retain_replay_output("anchor", self.anchor.config_raw, values)
        except BaseException as error:self._replay_output_failure(error, "reader-anchor-inputs")

    def commit(self, oid):
        raw = self.git.read(["cat-file", "commit", oid], c.DOCUMENT_LIMIT)
        headers = raw.split(b"\n\n", 1)[0].splitlines()
        trees = [row[5:].decode("ascii") for row in headers if row.startswith(b"tree ")]
        parents = [row[7:].decode("ascii") for row in headers if row.startswith(b"parent ")]
        require(len(trees) == 1 and c._writer_oid(trees[0]) and all(c._writer_oid(parent) for parent in parents))
        return trees[0], parents

    def git_relations(self, files, material_input, incident, body):
        revision = incident["body"]["git_revision_ref"]
        source_facts = self.git.inventory(revision)
        source_tree, _parents = self.commit(revision["commit_id"])
        response = parse(files["materialization-response.json"])
        receipt = parse(response["payloads"][0]["data"].encode())
        candidate, source = receipt["candidate"], receipt["source"]
        _candidate_header_values(source, body, revision, source_tree, candidate)
        candidate_tree, parents = self.commit(candidate["commit_id"])
        require(candidate_tree == candidate["tree_id"])
        facts = self.git.inventory(dict(revision, commit_id=candidate["commit_id"]))
        manifest = parse(files["preparation-manifest.json"])
        entries = _candidate_manifest_header_values(manifest)
        manifest_facts = {}
        file_count = total_bytes = 0
        for row in entries:
            value = _candidate_manifest_row_values(row, manifest_facts, facts)
            if value[1] == "blob":
                require(set(row) == {"path", "kind", "git_mode", "mode", "blob_oid", "size_bytes", "sha256"})
                file_count += 1
                require(type(row["size_bytes"]) is int and row["size_bytes"] >= 0)
                total_bytes += row["size_bytes"]
                require(_candidate_manifest_file_matches_values(row, value))
                raw = self.git.read(["cat-file", "blob", value[2]], min(16 * c.DOCUMENT_LIMIT, row["size_bytes"] + 1))
                _candidate_manifest_blob_values(raw, row)
        _candidate_manifest_totals_values(manifest_facts, facts, manifest, entries, file_count, total_bytes)
        self.preparation(files, receipt, response)
        if body["record_form"] == "enforced-reproduction.v1":
            self.enforced.require_no_change(files["materialization-response.json"], incident)
            require(facts == source_facts and candidate["commit_id"] == revision["commit_id"])
            return
        require(parents == [revision["commit_id"]])
        self.write_relations(files, material_input, incident, body, facts, source_facts, candidate_tree)

    def preparation(self, files, receipt, response):
        prep, producer = _preparation_document_values(files, receipt, response)
        for key, binary in (("python", self.python), ("git", self.git_binary), ("jq", self.jq)):
            identity = producer[key]
            require(_preparation_binary_prefix_matches_values(identity)
                and identity["executable_sha256"] == binary.sha256 and _preparation_binary_suffix_matches_values(identity))
        source = self.hold(PACKAGE / "preparation/v1/prepare-candidate.py", c.EXECUTABLE_LIMIT)
        require(producer["source_sha256"] == source.sha256
                and producer["protocol_sha256"] == self.package_sources["adapters/local-git-materializer/v1/protocol.jq"].sha256
                and producer["jq"]["version"] == "jq-1.6"
                and self._runtime_equal("scope.python-version", producer["python"]["version"], sys.version.splitlines()[0])
                and producer["git"]["version"].startswith("git version ")
                and self._runtime_equal("scope.unicode-version", producer["unicode_version"], unicodedata.unidata_version))
        core = producer["core"]
        base = {"adapters/local-git-materializer/v1/protocol.jq", "scripts/core-contract.sh", "core/v2/generation-registry.json"}
        generation = str(self.modules.parent.relative_to(PACKAGE))
        base.update(generation + "/" + suffix for suffix in ("core-ingress.sh", "contracts.jq",
            "modules/schema.jq", "modules/profile_graph.jq", "modules/stage_request.jq", "modules/result_facts.jq", "modules/result_truth.jq"))
        expected_files = [{"path": relative, "sha256": self.package_sources[relative].sha256}
                          for relative in sorted(base)]
        require(type(core) is dict and set(core) == {"generation_id", "files"}
                and core["generation_id"] == self.modules.parent.name and same(core["files"], expected_files))

    def write_relations(self, files, material_input, incident, body, facts, source_facts, tree):
        write, prefix, paths, rows, policy_form = _scope_write_header_values(files, incident, body, self.scope)
        frozen_files = {}
        for row in rows:
            _scope_write_row_values(row, facts)
            limit = 8 * c.DOCUMENT_LIMIT if row["path"].endswith("materialization-input.json") else 2 * c.DOCUMENT_LIMIT
            raw = self.git.read(["cat-file", "blob", row["git_blob_oid"]], limit + 1)
            require(len(raw) <= limit and c.digest(raw) == row["sha256"])
            frozen_files[row["path"]] = raw
        patch = _scope_write_copied_values(frozen_files, incident, body, rows, paths, facts, source_facts)
        policy_raw = files["scope-policy.json"] if policy_form else self.package_sources["scope/v1/scope-policy.json"].raw
        policy = _scope_write_policy_values(policy_raw, policy_form, frozen_files, prefix)
        marker_raw = self.package_sources["config/construction-mode.json"].raw
        frozen = _scope_write_frozen_values(marker_raw, policy, self.scope_body, paths, frozen_files, prefix, incident, body, files)
        require(same(write["bundle_ref"], self.writer._bundle_ref(frozen["bundle.json"]))
                and _scope_write_frozen_tail_matches_values(frozen_files, frozen))
        self._authenticate(frozen)
        seed_dir = self.fresh_runtime_directory("seed-" + str(len(self.inputs)))
        seed_incident = self.capture("seed-incident-" + str(len(self.inputs)) + ".json", frozen["incident.json"])
        seed_record = self.capture("seed-record-" + str(len(self.inputs)) + ".json", frozen["shadow-record.json"])
        seed = self.component("maintenance/v1/incident-to-eval.sh", ["convert", seed_incident, seed_record, seed_dir])
        require(seed == frozen_files[prefix + "eval-seed.json"])
        require(self.rebuild_input(frozen, paths, patch, files["claim.json"], parse(files["sandbox-request.json"])["id"], body["record_form"])
                == files["materialization-input.json"])
        publisher, publisher_body = self.writer._publisher(incident, tree)
        _scope_write_publication_values(write, files, publisher, publisher_body, incident, tree, rows)
        try:self._retain_replay_output("git", files["shadow-record.json"], (frozen_files, rows, self.git, files))
        except BaseException as error:self._replay_output_failure(error, "reader-git-retention")

    def allowed(self, path):
        import fnmatch
        return any(fnmatch.fnmatchcase(path, pattern) for pattern in self.scope_body["allowed_paths"])

    def rebuild_input(self, frozen, paths, patch, claim, attempt, record_form="withheld-write.v1"):
        contract = c.write_contract(paths, record_form)
        contract_path = self.capture("contract-" + str(len(self.inputs)) + ".json", contract)
        patch_path = self.capture("patch-" + str(len(self.inputs)) + ".txt", patch)
        metadata = {key: c.digest(raw) for key, raw in c.WRITE_TEXTS.items()}
        metadata.update({"contract": c.digest(contract), "patch": c.digest(patch), "allowed_paths": paths,
            "attempt_id": attempt, "suffix": c.digest(attempt.encode())[:32], "environment_id": parse(claim)["id"],
            "claim_sha256": c.digest(claim), "record_form": record_form,
            "incident_id": parse(frozen["incident.json"])["id"]})
        first_metadata = self.capture("metadata-" + str(len(self.inputs)) + ".json", c.canonical(metadata))
        args = ["-S", "-c", "--arg", "phase", "stage-request", "--rawfile", "contract", contract_path,
                "--rawfile", "patch", patch_path, "--slurpfile", "metadata", first_metadata]
        first_raw = self.jq_check("shadow/v1/write-materialization-input.jq", args,
                                 frozen["materialization-input.json"], limit=8 * c.DOCUMENT_LIMIT)
        first = parse(first_raw)
        require(c.canonical(first["original"]) == frozen["materialization-input.json"])
        metadata["stage_request_sha256"] = c.digest(c.canonical(first["stage_request"]))
        final_metadata = self.capture("metadata-" + str(len(self.inputs)) + ".json", c.canonical(metadata))
        args = ["-S", "-c", "--arg", "phase", "final-input", "--rawfile", "contract", contract_path,
                "--rawfile", "patch", patch_path, "--slurpfile", "metadata", final_metadata]
        return self.jq_check("shadow/v1/write-materialization-input.jq", args, first_raw, limit=8 * c.DOCUMENT_LIMIT)

    def record_source_command(self, argv, request_raw, sudo_sha, python_sha, supervisor_sha):
        role = "kill-register-source-boundary" if argv[-1] == "kill-register-read" else "coverage-source-boundary"
        self.record_command(role, argv, sudo_sha, supervisor_sha)
        self.commands[-1].update(_scope_source_command_fields_values(request_raw, python_sha))
        if self.store_session is not None:
            self.gate_commands[-1].update(_scope_source_command_fields_values(request_raw, python_sha))

    def coverage_identity(self, files):
        record = parse(files["shadow-record.json"])["body"]
        q = record["qualified_identity"]
        profile = parse(files["materialization-input.json"])["resolved_profile"]["content"]["body"]
        environment = record["environment"]["environment_id"]
        registry = [row for row in self.anchor.registry[1] if row["environment_id"] == environment]
        require(len(registry) == 1)
        return _coverage_identity_values(self.scope["id"], self.scope_body["workflow_id"], self.scope_body["task_class"],
            {key: q[key] for key in ("model_request", "adapter_config_refs", "prompt_refs", "skill_refs", "verification_instructions_ref")},
            {key: profile[key] for key in ("profile_ref", "profile_source", "selection_ref", "bindings")},
            environment, registry[0], ref(files["policy-set.json"]), c.digest(files["policy.json"]),
            c.digest(files["scope-policy.json"]), self.scope_body["coverage"]["coverage_base"])

    def coverage_interval(self, observation, retained_files):
        n = self.coverage_configuration.normalizer
        base = self.scope_body["coverage"]["coverage_base"]
        revision = self.scope_body["qualified_identity"]["target_revision"]
        head = self.hold(self.git_root / "HEAD", c.DOCUMENT_LIMIT).raw
        branch_name = _coverage_head_values(head)
        require(branch_name == observation["default_branch"]["name"])
        named_ref = self.git_root / "refs/heads" / branch_name
        if os.path.lexists(named_ref):
            require(self.hold(named_ref, c.DOCUMENT_LIMIT).raw == (revision["commit_id"] + "\n").encode())
        else:
            packed = self.hold(self.git_root / "packed-refs", c.DOCUMENT_LIMIT).raw
            _coverage_packed_ref_values(packed, revision["commit_id"], branch_name)
        rows = observation["first_parent_commits"]
        commits = []
        oid = revision["commit_id"]
        while True:
            require(len(commits) < 4096 and oid not in {row["commit_id"] for row in commits})
            tree, parents = self.commit(oid)
            commits.append({"commit_id": oid, "tree_id": tree,
                            "parent_commit_id": None if oid == base["commit_id"] else (parents[0] if parents else None)})
            if oid == base["commit_id"]:
                break
            require(parents)
            oid = parents[0]
        commits.reverse()
        _coverage_interval_rows_values(observation, commits, revision, base)
        pulls = observation["publisher_pull_requests"]
        used = set()
        previous = self.git.inventory(base)
        for row in commits[1:]:
            facts = self.git.inventory(dict(revision, commit_id=row["commit_id"]))
            changed, evidence = _coverage_changes_values(previous, facts)
            if evidence:
                require(changed == evidence and all(path not in previous and facts.get(path, ())[:2] == ("100644", "blob") for path in evidence))
                pull = _coverage_pull_values(pulls, row["commit_id"])
                require(pull["publisher_identity_ref"] == self.coverage_configuration.config["publisher_identity_ref"]
                        and _coverage_pull_scope_matches_values(pull, self.scope["id"], evidence))
                matching = []
                for files in retained_files:
                    body = parse(files["shadow-record.json"])["body"]
                    publisher = body["write"]["publisher_request"]
                    p = publisher["body"]
                    if (_coverage_publisher_prefix_matches_values(publisher, p, pull, revision)
                            and p["candidate_tree_id"] == self.commit(pull["head_commit_id"])[0]
                            and _coverage_write_paths_values(body) == evidence):
                        matching.append(files)
                require(len(matching) == 1)
                head_tree, head_parents = self.commit(pull["head_commit_id"])
                require(head_parents == [pull["base_commit_id"]])
                head_facts = self.git.inventory(dict(revision, commit_id=pull["head_commit_id"]))
                base_facts = self.git.inventory(dict(revision, commit_id=pull["base_commit_id"]))
                _coverage_head_changes_values(base_facts, head_facts, evidence, facts)
                for item in parse(matching[0]["shadow-record.json"])["body"]["write"]["write_set"]:
                    raw = self.git.read(["cat-file", "blob", facts[item["path"]][2]], 8 * c.DOCUMENT_LIMIT)
                    _coverage_blob_values(facts, item, raw)
                used.add(pull["node_id"])
            previous = facts
        return _coverage_interval_result_values(used, pulls, rows)

    def authenticate_gate_kill(self):
        if self.store_session is not None and self.store_session.is_inner:
            configuration = getattr(self, "kill_configuration", None)
            if configuration is None:
                configuration = c.load_coverage_configuration(self.anchor_for(), "kill-register-read")
                require(configuration is not None, "E_CONFIG")
                self.kill_configuration = configuration
                self.owned.append(configuration)
            source = c._HeldCoverageRead(self.anchor_for(), configuration, self.store_session.kill_request_raw)
            self.owned.append(source)
            try:self._retain_gate_kill_runtime(source, configuration)
            except BaseException as error:self._replay_output_failure(error, "scope-kill-runtime-retention")

    def _retain_gate_kill_runtime(self, source, configuration):
        anchor = self.anchor_for()
        raw = self.store_session.kill_request_raw
        request = parse(raw)
        require(self.commands_open and type(source) is c._HeldCoverageRead
            and source.anchor is anchor and source.configuration is configuration
            and any(item is source for item in self.owned)
            and any(item is configuration for item in self.owned)
            and source.capture.request_raw == raw
            and request["kind"] == "kill_register_source_request"
            and request["id"] == source.attempt_id, "E_STORE")
        binding = c.digest(raw)
        slots = {"python", "jq", "bash", "git"}
        def retained():
            rows = [row for row in anchor.private_observations.get("local_runtime", [])
                if row["request_sha256"] == binding and row["attempt_id"] == request["id"]
                and row["slot"] in slots]
            require(len(rows) == 4 and {row["slot"] for row in rows} == slots
                and all(row["index"] == 0 and row["errno"] is None for row in rows), "E_STORE")
            for row in rows:
                copies = [copy for copy in self.source_copies if not copy.closed
                    and row["file"] in copy.runtime_sha256 and row["file"] in copy.members]
                require(len(copies) == 1 and copies[0].runtime_sha256[row["file"]] == row["sha256"], "E_STORE")
            return rows
        existing = [row for row in anchor.private_observations.get("local_runtime", [])
            if row["request_sha256"] == binding and row["attempt_id"] == request["id"] and row["slot"] in slots]
        if existing:
            retained()
            return
        for item in (self.python, self.jq, self.bash, self.git_binary):
            require(type(item) is c._HeldBytes and item.raw is not None and item.held.components, "E_STORE")
        self.retain_source_runtime(raw, preserve_cancellation=True)
        retained()

    def source_coverage(self, qualifying, current, row_groups):
        context, result = self._source_coverage_request_phase(qualifying, current, row_groups)
        if context is None:
            return result
        return self._source_coverage_release_phase(context)

    def _source_coverage_request_phase(self, qualifying, current, row_groups):
        missing = {"state": "stale"}
        required = self.scope_body["required_shadow_environments"]
        if not (set(qualifying) == set(current) == set(required)
                and all(row["authentication"]["state"] == "authenticated" for rows in row_groups for row in rows if row["claimed"])):
            return None, missing
        anchor = self.anchor_for()
        configuration = c.load_coverage_configuration(anchor)
        if configuration is None:
            require(self.store_session is None, "E_RELATION")
            return None, missing
        self.coverage_configuration = configuration
        self.owned.append(configuration)
        n = configuration.normalizer
        for environment in required:
            qualifying_body = parse(qualifying[environment]["shadow-record.json"])["body"]
            current_body = parse(current[environment]["shadow-record.json"])["body"]
            require(qualifying_body["record_form"] == current_body["record_form"] == "withheld-write-policy.v1")
            c.check_scope_policy_ref(qualifying_body["scope_policy_ref"], qualifying[environment]["scope-policy.json"])
            c.check_scope_policy_ref(current_body["scope_policy_ref"], current[environment]["scope-policy.json"])
            require(qualifying[environment]["scope-policy.json"] == current[environment]["scope-policy.json"]
                    == self.package_sources["scope/v1/scope-policy.json"].raw)
            require(same(self.coverage_identity(qualifying[environment]), self.coverage_identity(current[environment])))
        documents = {}
        for name in n.DOCUMENT_NAMES:
            documents[name] = ref(self.hold(self.document_paths.get(name, self.scratch / (name + ".json")), c.DOCUMENT_LIMIT).raw)
        risk, duty = (parse(self.hold(self.document_paths.get(name, self.scratch / (name + ".json")), c.DOCUMENT_LIMIT).raw) for name in ("risk", "duty"))
        identity = self.scope_body["qualified_identity"]
        require(same(risk["body"]["stage"]["request_ref"], identity["stage_request_ref"])
                and same(duty["body"]["stage"]["request_ref"], identity["stage_request_ref"])
                and same(risk["body"]["stage"]["resolved_profile_ref"], identity["resolved_profile_ref"])
                and same(duty["body"]["stage"]["resolved_profile_ref"], identity["resolved_profile_ref"])
                and same(risk["body"]["stage"]["result_ref"], duty["body"]["stage"]["result_ref"]))
        require(all(same(ref(c.canonical(parse(files["materialization-response.json"])["stage_result"])),
                         duty["body"]["stage"]["result_ref"]) for files in current.values()))
        nonce = getattr(self, "_coverage_nonce", None)
        if not nonce:
            entropy = os.urandom(32)
            anchor.retain_entropy("coverage", entropy)
            nonce = entropy.hex()
        attempt = "coverage." + nonce
        def hashes(name):
            return [{"environment_id": environment, "sha256": c.digest(c.canonical(parse(files["shadow-record.json"])["body"]["write"][name]))}
                    for environment, files in sorted(current.items())]
        git_observation = _coverage_git_values(self.scope_body["coverage"]["coverage_base"], identity["target_revision"],
            self.commit(self.scope_body["coverage"]["coverage_base"]["commit_id"])[0],
            self.commit(identity["target_revision"]["commit_id"])[0], c.digest(self.git.config))
        body = _coverage_request_body_values(attempt, nonce, self.scope_body["target_repository_id"],
            self.scope_body["coverage"]["coverage_base"], identity["target_revision"], documents,
            sorted(self.scope_body["coverage"]["qualifying_shadow_record_refs"], key=c.canonical),
            sorted(self.scope_body["shadow_evidence_refs"], key=c.canonical),
            identity["resolved_profile_ref"], identity["stage_request_ref"], duty["body"]["stage"]["result_ref"],
            [{"environment_id": environment, "sha256": c.digest(files["materialization-response.json"])}
                for environment, files in sorted(current.items())],
            hashes("publisher_request"), hashes("post_write_verification"),
            sorted([ref(files["sandbox-receipt.json"]) for files in qualifying.values()], key=c.canonical),
            c.digest(c.canonical(git_observation)), n.doc_ref(configuration.package_raw), n.doc_ref(configuration.accepted_raw))
        if self.store_session is not None:
            body.update(initial_origin_refs=self.store_session.coverage_origins(), gate_call_ref=self.store_session.gate_call_ref)
        request_raw = c.canonical({"schema_version": 1, "kind": "coverage_source_request", "id": attempt, "body": body})
        n.request(request_raw)
        self.retain_source_runtime(request_raw)
        if getattr(self, "_coverage_prepare_only", False):
            return None, request_raw
        expectation = _coverage_expectation_fields_values(body)
        if self.store_session is not None:
            expectation.update(initial_origin_refs=body["initial_origin_refs"], gate_call_ref=body["gate_call_ref"])
        expectation.update(request_sha256=c.digest(request_raw), scope_ref=documents["scope"])
        workspace = self.fresh_runtime_directory(attempt)
        parent = os.open(self.runtime, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
        prepared = (("request.json", request_raw), ("expectation.json", c.canonical({"schema_version": 1,
                          "kind": "coverage_source_expectation", "id": attempt, "body": expectation})))
        for name, raw in prepared:
            write_exclusive(workspace / name, raw, mode=0o600, resolver=self.darwin)
        for name, _raw in prepared:
            self.hold(workspace / name, c.DOCUMENT_LIMIT)
        self.directory(workspace)
        self.recheck()
        if self.store_session is not None and self.store_session.is_inner:
            self.store_session.request(request_raw, expectation)
        return (self, qualifying, current, row_groups, anchor, configuration, n, identity, body, request_raw), None

    def _source_coverage_release_phase(self, context):
        require(type(context) is tuple and len(context) == 10 and context[0] is self, "E_RELATION")
        (_reader, qualifying, current, row_groups, anchor, configuration, n, identity, body, request_raw) = context
        self.release_stores()
        if self.store_session is not None and self.store_session.is_inner:
            self.store_session.released()
        self.darwin.coverage_source(request_raw)
        source = c._HeldCoverageRead(anchor, configuration, request_raw)
        self.owned.append(source)
        for files_by_environment, rows in zip((qualifying, current), row_groups):
            self.authentication_revision = (self.scope_body["coverage"]["coverage_base"] if files_by_environment is qualifying else identity["target_revision"])
            for environment, files in files_by_environment.items():
                facts = self._authenticate(files)
                row = next(row for row in rows if row["environment_id"] == environment)
                require(all(same(value, row["facts"][key]) for key, value in facts.items() if key != "fresh_origin_ref"))
                row["facts"] = facts
        observed = parse(source.snapshots["payload/observation.json"])
        receipt = parse(source.snapshots["receipt.json"])
        interval = self.coverage_interval(observed, list(qualifying.values()) + list(current.values()))
        require(all(n.age_ok(parse(files["sandbox-receipt.json"])["body"]["timing"]["terminated_at"], receipt["body"]["completed_at"])
                    for files in qualifying.values()))
        require(n.utc(observed["branch_snapshots"]["current"]["observed_at"]) <= n.utc(receipt["body"]["completed_at"]))
        self.recheck()
        if self.store_session is not None and self.store_session.is_inner:
            self.authenticate_gate_kill()
            self.store_session.source_done()
        return {"state": "authenticated", "request_ref": ref(request_raw), "receipt_ref": ref(source.snapshots["receipt.json"]),
            "origin_ref": ref(source.observation), "observation_sha256": c.digest(source.snapshots["payload/observation.json"]),
            "interval": interval, "coverage_base": body["coverage_base"], "evaluated_revision": body["evaluated_revision"],
            "current_binding_sha256": c.digest(c.canonical(body)), "qualifying_rows": row_groups[0]}


    def authenticate_bundles(self, current_only=False):
        document = self.shadow_set
        require(set(document) == {"schema_version", "kind", "id", "body"}
                and type(document["schema_version"]) is int and document["schema_version"] == 1
                and document["kind"] == "shadow_evidence_set" and c._id(document["id"])
                and type(document["body"]) is dict and set(document["body"]) == {"records"})
        records = document["body"]["records"]
        require(type(records) is list and 1 <= len(records) <= 16)
        references = self.scope_body["shadow_evidence_refs"]
        identity = self.scope_body["qualified_identity"]
        workflow = self.scope_body["workflow_id"] == "workflow.shadow-evidence-commit"
        task = self.scope_body["task_class"] == "task.commit-shadow-evidence"
        require(workflow == task)
        base_keys = {"activation_state", "authority", "check", "deploy_authority", "effects", "environment",
            "evaluation_mode", "git_revision_ref", "incident_ref", "materialization", "observed_at", "outcome",
            "qualification", "qualified_identity", "qualified_identity_ref", "reason_id", "shadow",
            "target_repository_id", "trace_ledger_ref"}
        rows, qualifying_rows = [], []
        digests, allowed_directories = set(), set()
        named = set(os.listdir(self.bundle_root.fd))
        coverage = self.scope_body.get("coverage")
        require(bool(coverage) == workflow)
        groups = [("current", references, identity["target_revision"], rows)]
        if coverage is not None:
            groups.insert(0, ("qualifying", coverage["qualifying_shadow_record_refs"], coverage["coverage_base"], qualifying_rows))
        role_files = {"qualifying": {}, "current": {}}
        for record in records:
            raw = c.canonical(record)
            digest = c.digest(raw)
            require(digest not in digests)
            digests.add(digest)
            require(type(record) is dict and set(record) == {"schema_version", "kind", "id", "body"}
                    and type(record["schema_version"]) is int and record["schema_version"] == 1
                    and record["kind"] == "shadow_reproduction_record" and c._id(record["id"])
                    and type(record["body"]) is dict)
            body = record["body"]
            form = body.get("record_form", "legacy")
            require(form in {"legacy", "enforced-reproduction.v1", "withheld-write.v1", "withheld-write-policy.v1"})
            additions = set() if form == "legacy" else {"record_form", "sandbox", "producer_invocations", "consumer_provenance_ref"}
            if form in {"withheld-write.v1", "withheld-write-policy.v1"}:
                additions.add("write")
            if form == "withheld-write-policy.v1":
                additions.add("scope_policy_ref")
            require(set(body) == base_keys | additions)
            for role, refs, revision, output_rows in groups:
                claimed = any(reference["id"] == record["id"] and reference["sha256"] == digest for reference in refs)
                same_identity = (same(body["qualified_identity"], identity) if role == "current" else
                    all(same(body["qualified_identity"][key], identity[key]) for key in
                        ("model_request", "adapter_config_refs", "prompt_refs", "skill_refs", "verification_instructions_ref")))
                match = body["target_repository_id"] == self.scope_body["target_repository_id"] and same(body["git_revision_ref"], revision) and same_identity
                eligible = claimed and match and form != "legacy"
                environment = body["environment"]["environment_id"]
                row = {"record_ref": ref(raw), "record_form": form, "claimed": claimed,
                    "eligible": eligible, "environment_id": environment,
                    "authentication": {"state": "missing"}, "facts": {}}
                if form == "legacy":
                    require(digest not in named)
                elif claimed:
                    allowed_directories.add(digest)
                if eligible and (not current_only or role == "current"):
                    require(environment not in role_files[role])
                    require(environment in self.scope_body["required_shadow_environments"])
                    require(form not in {"withheld-write.v1", "withheld-write-policy.v1"} or workflow)
                    if digest in named:
                        held = c._HeldBundle(self.bundle_root, digest, form)
                        self.owned.append(held)
                        require(held.files["shadow-record.json"] == raw)
                        require(body["materialization"]["value"]["outcome"] == ("no-change" if form == "enforced-reproduction.v1" else "changed"))
                        role_files[role][environment] = held.files
                        if os.path.lexists(c.ANCHOR):
                            self.authentication_revision = revision
                            row["facts"] = self.fixed_bundle(held)
                            row["authentication"] = {"state": "authenticated"}
                            try:self._retain_replay_output("bundles", raw, (held, role, environment))
                            except BaseException as error:self._replay_output_failure(error, "reader-bundle-retention")
                output_rows.append(row)
        require(named <= allowed_directories)
        for _role, refs, _revision, output_rows in groups:
            for reference in refs:
                require(sum(reference["id"] == row["record_ref"]["id"]
                            and reference["sha256"] == row["record_ref"]["sha256"] for row in output_rows) == 1)
        self.recheck()
        return rows, qualifying_rows, role_files

    def evaluate(self):
        context = self._evaluate_authentication_phase()
        _reader, rows, qualifying_rows, role_files, workflow, identity = context
        coverage_result = None
        if workflow:
            try:
                coverage_result = self.source_coverage(role_files["qualifying"], role_files["current"], [qualifying_rows, rows])
            except BaseException as error:
                if self.store_session is not None:
                    raise
                if getattr(error, "code", "") in {"E_STALE", "E_RUNTIME", "E_LIMIT", "E_DEPENDENCY"}:
                    raise
                if isinstance(error, (KeyboardInterrupt, SystemExit, InterruptedError)):
                    raise
                coverage_result = {"state": "stale"}
        return self._evaluate_observation_phase(context, coverage_result)

    def _evaluate_authentication_phase(self):
        rows, qualifying_rows, role_files = self.authenticate_bundles()
        workflow = self.scope_body["workflow_id"] == "workflow.shadow-evidence-commit"
        identity = self.scope_body["qualified_identity"]
        self.authenticate_gate_kill()
        return (self, rows, qualifying_rows, role_files, workflow, identity)

    def _evaluate_observation_phase(self, context, coverage_result):
        require(type(context) is tuple and len(context) == 6 and context[0] is self, "E_RELATION")
        (_reader, rows, qualifying_rows, role_files, workflow, identity) = context
        self.recheck()
        return _scope_reader_observation_values(self.scope["id"], ref(self.scope_raw), ref(self.set_raw),
            sorted(rows, key=lambda row: row["record_ref"]["sha256"]),
            {"repository_kind": "bare", "hash_algorithm": identity["target_revision"]["hash_algorithm"],
                "config_sha256": c.digest(self.git.config)}, self.commands, workflow, coverage_result)



class _ControlFIFO:
    def __init__(self, scratch):
        self.parent = c._open_held(str(scratch), True,
            lambda _fd, state, ancestor: ancestor or (state.st_uid == os.getuid()
                and stat.S_IMODE(state.st_mode) == 0o700), "E_RUNTIME")
        self.fd = None
        self.ready_fd = None
        try:
            self.fd = os.open("reader-control", os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW,
                              dir_fd=self.parent.fd)
            original = os.fstat(0)
            current = os.fstat(self.fd)
            require(self.identity(original) == self.identity(current), "E_STALE")
            self.before = self.identity(current)
            self.ready_fd = os.open("reader-ready", os.O_WRONLY | os.O_NONBLOCK | os.O_NOFOLLOW,
                                    dir_fd=self.parent.fd)
            self.ready_before = self.identity(os.fstat(self.ready_fd))
            require(self.identity(os.fstat(1)) == self.ready_before, "E_STALE")
            os.dup2(self.ready_fd, 1, inheritable=True)
            os.dup2(self.fd, 0, inheritable=True)
            os.set_blocking(0, True)
            self.recheck()
        except BaseException:
            self.close()
            raise

    @staticmethod
    def identity(state):
        require(stat.S_ISFIFO(state.st_mode) and state.st_uid == os.getuid()
                and state.st_gid == os.getgid() and stat.S_IMODE(state.st_mode) == 0o600
                and state.st_nlink == 1, "E_RUNTIME")
        return (state.st_dev, state.st_ino, stat.S_IFMT(state.st_mode),
                state.st_uid, state.st_gid, stat.S_IMODE(state.st_mode), state.st_nlink)

    def recheck(self):
        self.parent.recheck("E_STALE")
        require(self.identity(os.fstat(0)) == self.before
                and self.identity(os.fstat(self.fd)) == self.before
                and self.identity(os.stat("reader-control", dir_fd=self.parent.fd, follow_symlinks=False))
                == self.before, "E_STALE")
        require(self.identity(os.fstat(1)) == self.ready_before
                and self.identity(os.fstat(self.ready_fd)) == self.ready_before
                and self.identity(os.stat("reader-ready", dir_fd=self.parent.fd, follow_symlinks=False))
                == self.ready_before, "E_STALE")

    def close(self):
        fd, self.fd = self.fd, None
        ready_fd, self.ready_fd = self.ready_fd, None
        try:
            if ready_fd is not None:
                os.close(ready_fd)
            if fd is not None:
                os.close(fd)
        finally:
            self.parent.close()


def write_exclusive(path, raw, mode=0o400, resolver=None):
    parent = c._open_held(str(path.parent), True,
        lambda _fd, state, ancestor: ancestor or state.st_uid == os.getuid(), "E_RUNTIME")
    fd = None
    try:
        parent.recheck("E_STALE")
        before = set(os.listdir(parent.fd))
        require(path.name not in before, "E_STALE")
        fd = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     mode, dir_fd=parent.fd)
        sent = 0
        while sent < len(raw):
            count = os.write(fd, raw[sent:])
            require(count > 0, "E_RUNTIME")
            sent += count
        os.fsync(fd)
        state = os.fstat(fd)
        require(stat.S_ISREG(state.st_mode) and state.st_uid == os.getuid() and state.st_nlink == 1
                and stat.S_IMODE(state.st_mode) == mode, "E_RUNTIME")
        if sys.platform != "darwin" or resolver is not None:
            access, default = c._acl_state(fd, resolver)
            require((access == [] if sys.platform == "darwin" else access is None and default is None), "E_RUNTIME")
        written = c._identity(state)
        require(c._identity(os.stat(path.name, dir_fd=parent.fd, follow_symlinks=False)) == written, "E_STALE")
        require(set(os.listdir(parent.fd)) == before | {path.name}, "E_STALE")
        require(c._identity(os.fstat(parent.fd))[:6] == c._identity(parent.before)[:6], "E_STALE")
        require(c._identity(os.lstat(path.parent))[:6] == c._identity(parent.before)[:6], "E_STALE")
        for index, component in enumerate(parent.components[:-1]):
            require(c._identity(c._metadata(component.fd)) == c._identity(component.before), "E_STALE")
            if component.name is not None:
                require(c._identity(c._named_metadata(component.name, parent.components[index - 1].fd))
                        == c._identity(component.before), "E_STALE")
        os.fsync(parent.fd)
        return written
    finally:
        if fd is not None:
            os.close(fd)
        parent.close()


def main(arguments):
    require(len(arguments) == 6 and arguments[0] == "read", "E_USAGE")
    paths = list(map(Path, arguments[1:]))
    def cancel(_number, _frame):
        error = InterruptedError("scope reader cancelled")
        error._scope_signal_cancel = True
        raise error
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGALRM):
        signal.signal(number, cancel)
    control = _ControlFIFO(paths[-1].parent.parent)
    reader = None
    gate_session = None
    try:
        try:
            private = stat.S_ISSOCK(os.fstat(6).st_mode)
        except OSError:
            private = False
        if private:
            gate_session = _GateReaderSession()
        reader = _Reader(*paths, store_session=gate_session, deadline=gate_session.deadline if gate_session else None)
        raw = reader.evaluate()
        require(len(raw) <= c.DOCUMENT_LIMIT, "E_LIMIT")
        reader.recheck()
        write_exclusive(reader.output, raw, resolver=reader.darwin)
        reader.inputs.append((reader.output, raw))
        reader.recheck()
        if gate_session is not None:
            gate_session.final()
        require(os.write(1, b"READY\n") == 6, "E_RUNTIME")
        message = sys.stdin.buffer.read(8)
        require(message == b"SEAL\n", "E_RUNTIME")
        control.recheck()
        reader.recheck()
        terminal = reader.terminal(raw)
        frame = ("COMMIT " + str(len(terminal)) + " " + c.digest(terminal) + "\n").encode("ascii")
        require(len(frame) <= 96 and os.write(1, frame) == len(frame), "E_RUNTIME")
    finally:
        try:
            if reader is not None:
                reader.close()
            if gate_session is not None:
                gate_session.close()
        finally:
            control.close()


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except BaseException as error:
        code = getattr(error, "code", "E_RELATION" if isinstance(error,
            (KeyError, TypeError, ValueError, UnicodeError)) else "E_RUNTIME")
        if code not in {"E_USAGE", "E_LIMIT", "E_PARSE", "E_CANONICAL", "E_RELATION", "E_STALE", "E_RUNTIME"}:
            code = "E_RELATION" if code.startswith(("E_INSTALL", "E_STORE", "E_CONFIG", "E_ACL", "E_SHAPE")) else "E_RUNTIME"
        print(code, file=sys.stderr)
        raise SystemExit(1)
