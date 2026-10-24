"""Private offline admission for held shadow evidence. No publication authority."""
from __future__ import annotations
import dataclasses
import json
from pathlib import Path
import sys

_SOURCE = Path(__file__).absolute().parents[2]
_consumer = sys.modules.get("ystack_shadow_consumer")
if (_consumer is None or Path(_consumer.__file__).absolute() != _SOURCE / "shadow/v1/_consumer.py"
        or Path(_consumer.__file__).resolve(strict=True) != Path(_consumer.__file__).absolute()):
    raise RuntimeError("E_RUNTIME")
c = _consumer
_LIMIT = 1_048_576
_NAMES = (
    "accepted-identities.json", "claim.json", "consumer-provenance.json", "decision.json",
    "duty-evaluation.json", "evaluator-driver.txt", "evaluator-program.txt",
    "evidence-manifest.json", "file-digest-result.json", "incident.json",
    "materialization-input.json", "materialization-response.json", "origin-observation.json",
    "payload-stderr.txt", "payload-stdout.txt", "policy-set.json", "policy.json",
    "preparation-manifest.json", "preparation-record.json", "qualified-identity.json",
    "registry.json", "sandbox-check.json", "sandbox-evaluation.json",
    "sandbox-expectation.json", "sandbox-receipt.json", "sandbox-request.json",
    "shadow-record.json", "trace-ledger.json", "trace-receipt.json",
)


def _require(value, code="E_RELATION"):
    c._require(value, code)


def _parse(raw, limit=_LIMIT):
    _require(type(raw) is bytes, "E_SHAPE")
    return c._json(raw, limit, "E_SHAPE")


@dataclasses.dataclass(frozen=True)
class _AdmissionInputs:
    incident_raw: bytes
    generated_response_raw: bytes
    write_raw: bytes
    generated_input_raw: bytes
    frozen_files: tuple[tuple[str, bytes], ...]
    candidate_files: tuple[tuple[str, bytes], ...]
    outer_files: tuple[tuple[str, bytes], ...]
    seed_raw: bytes
    record_form: str
    scope_id: str
    allowed_paths: tuple[str, ...]
    policy_raw: bytes
    mode_raw: bytes
    source_inventory: tuple[tuple[str, tuple[str, str, str]], ...]
    source_git: c._ReadOnlyGit
    candidate_git: c._ReadOnlyGit


@dataclasses.dataclass(frozen=True)
class _AdmissionResult:
    base_revision_raw: bytes
    candidate_commit_id: str
    candidate_tree_id: str
    publisher_request_raw: bytes
    title_raw: bytes
    body_raw: bytes
    write_set_raw: bytes
    admission_raw: bytes
    post_write_plan_raw: bytes


def bundle_ref(raw):
    _require(type(raw) is bytes and len(raw) <= _LIMIT, "E_LIMIT")
    return {"content_id": "shadow-consumer-bundle",
        "media_type": "application/vnd.ystack.shadow-consumer-bundle+json", "sha256": c.digest(raw)}


def publisher(incident, tree):
    identity = incident["id"]
    _require(c._id(identity) and all(char in "abcdefghijklmnopqrstuvwxyz0123456789._-" for char in identity)
             and ".." not in identity and not identity.endswith((".", ".lock")))
    body = ("Shadow evidence for " + identity + ". Publication is withheld.\n").encode()
    request = {"schema_version": 1, "kind": "shadow_publisher_request", "id": identity,
        "body": {"target_repository_id": incident["body"]["target_repository_id"],
            "branch": "ystack/evidence/" + identity,
            "base_revision": incident["body"]["git_revision_ref"], "candidate_tree_id": tree,
            "title": "Shadow evidence: " + identity, "body_sha256": c.digest(body)}}
    return request, body


def _files(rows):
    _require(type(rows) is tuple and all(type(row) is tuple and len(row) == 2 for row in rows), "E_SHAPE")
    _require(all(type(name) is str and type(raw) is bytes for name, raw in rows), "E_SHAPE")
    _require(tuple(sorted(rows)) == rows and len({name for name, _raw in rows}) == len(rows))
    _require(sum(len(raw) for _name, raw in rows) <= 48 * _LIMIT, "E_LIMIT")
    for name, raw in rows:
        leaf = name.rsplit("/", 1)[-1]
        limit = 8 * _LIMIT if leaf == "materialization-input.json" else 2 * _LIMIT if leaf == "preparation-manifest.json" else _LIMIT
        _require(len(raw) <= limit, "E_LIMIT")
    return dict(rows)


def _owner(owner):
    _require(type(owner) is c._ReadOnlyGit and owner.held and len(owner.held) == 4)
    repository = Path(owner.repository)
    _require(repository.is_absolute() and repository.resolve(strict=True) == repository)
    _require(owner.held[0].path == str(repository))
    owner.recheck()


def candidate_facts(source_git, candidate_git, response_raw, incident, source_facts, files, expected, record_form):
    _owner(source_git)
    _owner(candidate_git)
    _require(source_git is not candidate_git and source_git.repository != candidate_git.repository)
    revision = incident["body"]["git_revision_ref"]
    _require(revision["repository_id"] == incident["body"]["target_repository_id"])
    _require(source_git.inventory(revision) == source_facts)
    receipt = _parse(_parse(response_raw)["payloads"][0]["data"].encode())
    candidate = receipt["candidate"]
    algorithm = revision["hash_algorithm"]
    _require(expected == c.evidence_patch(files, algorithm, record_form)[1])
    _require(candidate["parent_commit_id"] == revision["commit_id"]
             and candidate["commit_id"] != revision["commit_id"]
             and receipt["changed_paths"]["count"] == len(files))
    candidate_revision = dict(revision, commit_id=candidate["commit_id"])
    facts = candidate_git.inventory(candidate_revision)
    commit = candidate_git.read(["cat-file", "commit", candidate["commit_id"]], _LIMIT)
    headers = commit.split(b"\n\n", 1)[0].splitlines()
    _require([line[7:].decode() for line in headers if line.startswith(b"parent ")] == [revision["commit_id"]]
             and [line[5:].decode() for line in headers if line.startswith(b"tree ")] == [candidate["tree_id"]])
    directories = {"/".join(path.split("/")[:index]) for path in files for index in range(1, len(path.split("/")))}
    _require(all(facts.get(path) == value or (path in directories
        and value[:2] == ("040000", "tree") and facts.get(path, ())[:2] == value[:2])
        for path, value in source_facts.items()))
    additions = {path: value for path, value in facts.items() if path not in source_facts and value[1] != "tree"}
    _require(additions == {row["path"]: ("100644", "blob", row["git_blob_oid"]) for row in expected})
    _require({path for path in facts if path not in source_facts and facts[path][1] == "tree"} == directories - set(source_facts))
    for row in expected:
        raw = candidate_git.read(["cat-file", "blob", row["git_blob_oid"]], len(files[row["path"]]) + 1)
        _require(raw == files[row["path"]] and c.digest(raw) == row["sha256"])
    source_git.recheck()
    candidate_git.recheck()
    return candidate


def admit_write(inputs):
    _require(type(inputs) is _AdmissionInputs, "E_SHAPE")
    _require(sys.modules.get("ystack_shadow_consumer") is c, "E_RUNTIME")
    _require(inputs.record_form in {"withheld-write.v1", "withheld-write-policy.v1"})
    incident = _parse(inputs.incident_raw)
    write = _parse(inputs.write_raw)
    generated = _parse(inputs.generated_input_raw, 8 * _LIMIT)
    _parse(inputs.generated_response_raw)
    _parse(inputs.seed_raw)
    policy = _parse(inputs.policy_raw)
    _require(type(inputs.mode_raw) is bytes and len(inputs.mode_raw) <= _LIMIT, "E_LIMIT")
    mode = json.loads(inputs.mode_raw, object_pairs_hook=c._unique_object)
    frozen = _files(inputs.frozen_files)
    files = _files(inputs.candidate_files)
    outer = _files(inputs.outer_files)
    policy_form = inputs.record_form == "withheld-write-policy.v1"
    _require(set(frozen) == set(_NAMES) | {"bundle.json"})
    _require(frozen["incident.json"] == inputs.incident_raw)
    prefix = "ystack-evidence/" + incident["id"] + "/"
    names = set(_NAMES) | {"bundle.json", "eval-seed.json", "README.md"}
    if policy_form:
        names.add("scope-policy.json")
    _require(set(files) == {prefix + name for name in names})
    _require(set(outer) == set(_NAMES) | {"publisher-body.txt"} | ({"scope-policy.json"} if policy_form else set()))
    _require(all(files[prefix + name] == raw for name, raw in frozen.items()))
    _require(files[prefix + "eval-seed.json"] == inputs.seed_raw
             and files[prefix + "README.md"] == b"Shadow evidence. Publication is withheld.\n")
    marker = _parse(frozen["bundle.json"])
    marker_rows = [{"name": name, "size_bytes": len(raw), "sha256": c.digest(raw)}
                   for name, raw in sorted(frozen.items()) if name != "bundle.json"]
    _require(marker["body"]["files"] == marker_rows)
    if policy_form:
        _require(files[prefix + "scope-policy.json"] == outer["scope-policy.json"] == inputs.policy_raw)
        reference = _parse(outer["shadow-record.json"])["body"].get("scope_policy_ref")
        c.check_scope_policy_ref(reference, inputs.policy_raw)
    _require(type(inputs.allowed_paths) is tuple and len(inputs.allowed_paths) <= 33
             and all(type(path) is str and len(path.encode()) <= 4096 for path in inputs.allowed_paths), "E_LIMIT")
    _require(tuple(sorted(files)) == inputs.allowed_paths
             and all(c.write_path_ok(path, policy, mode) for path in inputs.allowed_paths))
    _require(c._id(inputs.scope_id))
    _require(type(inputs.source_inventory) is tuple
             and all(type(row) is tuple and len(row) == 2 and type(row[0]) is str
                     and type(row[1]) is tuple and len(row[1]) == 3 for row in inputs.source_inventory), "E_SHAPE")
    source = dict(inputs.source_inventory)
    _require(tuple(sorted(source.items())) == inputs.source_inventory)
    root = prefix[:-1]
    _require(not any(path.lower() == root.lower() or path.lower().startswith(root.lower() + "/") for path in source))
    _require(all(path.lower() != "ystack-evidence" or
        (path == "ystack-evidence" and source[path][:2] == ("040000", "tree")) for path in source))
    revision = incident["body"]["git_revision_ref"]
    patch, rows = c.evidence_patch(files, revision["hash_algorithm"], inputs.record_form)
    _require(len(patch) <= _LIMIT, "E_LIMIT")
    candidate = candidate_facts(inputs.source_git, inputs.candidate_git, inputs.generated_response_raw,
        incident, source, files, rows, inputs.record_form)
    request, body = publisher(incident, candidate["tree_id"])
    request_raw, rows_raw = c.canonical(request), c.canonical(rows)
    admission = {"state": "checked", "effect": "none", "request_sha256": c.digest(request_raw),
                 "write_set_sha256": c.digest(rows_raw)}
    post = {"target_revision": revision, "candidate_tree_id": candidate["tree_id"], "write_set": rows}
    stage = generated["stage_request"]["content"]["body"]
    expected = {"bundle_ref": bundle_ref(frozen["bundle.json"]), "scope_id": inputs.scope_id,
        "workflow_id": "workflow.shadow-evidence-commit", "task_class": "task.commit-shadow-evidence",
        "write_set": rows, "publisher_request": request, "admission": admission,
        "publication": {"state": "withheld", "reason_id": "shadow.write-not-published"},
        "post_write_verification": post}
    _require(stage["workflow_id"] == expected["workflow_id"] and stage["task_class_id"] == expected["task_class"])
    _require(c.canonical(write) == c.canonical(expected) and outer["publisher-body.txt"] == body)
    inputs.source_git.recheck()
    inputs.candidate_git.recheck()
    return _AdmissionResult(c.canonical(revision), candidate["commit_id"], candidate["tree_id"],
        request_raw, request["body"]["title"].encode(), body, rows_raw,
        c.canonical(admission), c.canonical(post))
