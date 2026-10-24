#!/usr/bin/env python3
"""Private deterministic evidence writer; publication remains withheld."""
from __future__ import annotations

import dataclasses
import gc
import importlib.util
import json
import os
import sys
import time
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("ystack_shadow_enforced", SOURCE / "shadow/v1/enforced-reproduction.py")
if _spec is None or _spec.loader is None:
    raise SystemExit("E_RUNTIME")
e = sys.modules.get(_spec.name)
if e is None:
    e = importlib.util.module_from_spec(_spec)
    sys.modules[_spec.name] = e
    _spec.loader.exec_module(e)
else:
    if Path(e.__file__).absolute() != SOURCE / "shadow/v1/enforced-reproduction.py":
        raise SystemExit("E_RUNTIME")
    if sys.modules.get("ystack_shadow_consumer") is not e.c:
        raise SystemExit("E_RUNTIME")
c = e.c
require, canonical, sha, parse = e.require, e.canonical, e.sha, e.parse

_ADMISSION_SHA256 = "aadac15726dbfe64b7a171ba74e319cf2df3b6d0fcd71bc810698f13030cf294"
_ADMISSION_PATH = SOURCE / "publisher/v1/_admission.py"
require(_ADMISSION_PATH.resolve(strict=True) == _ADMISSION_PATH, "E_RUNTIME")
_ADMISSION_SOURCE = e.stable_file(_ADMISSION_PATH)
require(_ADMISSION_SOURCE.sha256 == _ADMISSION_SHA256, "E_RUNTIME")
_admission_spec = importlib.util.spec_from_file_location("ystack_publisher_admission", _ADMISSION_PATH)
require(_admission_spec is not None and _admission_spec.loader is not None, "E_RUNTIME")
a = importlib.util.module_from_spec(_admission_spec)
sys.modules[_admission_spec.name] = a
exec(compile(_ADMISSION_SOURCE.raw, str(_ADMISSION_PATH), "exec"), a.__dict__)
require(a.c is c, "E_RUNTIME")
_ADMISSION_SOURCE.recheck("E_RUNTIME")
NAMES = (*e.EVIDENCE_NAMES, "bundle.json")
REQUEST_KEYS = e.REQUEST_BODY_KEYS | {"scope_id", "allowed_paths"}



@dataclasses.dataclass(frozen=True)
class MaterializedWrite:
    files: dict[str, bytes]
    input_raw: bytes
    response_raw: bytes
    qualified_identity_raw: bytes
    preparation_record_raw: bytes
    preparation_manifest_raw: bytes
    origin_raw: bytes
    evaluation_raw: bytes
    write_set: list[dict]
    candidate_repository: Path
    candidate_commit_id: str
    candidate_tree_id: str
    verification_files: dict[str, bytes]
    source_facts: dict[str, tuple]


class _Workspace:
    def __init__(self, request: Path, bundle: Path, work: Path, output: Path, parent: dict, record_form="withheld-write.v1"):
        require(record_form in {"withheld-write.v1", "withheld-write-policy.v1"}, "E_RELATION")
        self.record_form = record_form
        self.owned = []
        self.inputs = []
        self.components = {}
        self.commands = []
        self.deadline = time.monotonic() + e.OVERALL_SECONDS
        self.work, self.output, self.parent = work, output, parent
        try:
            self.request = self.hold(request, e.REQUEST_LIMIT)
            self.request_doc = parse(self.request.raw, e.REQUEST_LIMIT)
            doc = self.request_doc
            require(set(doc) == {"schema_version", "kind", "id", "body"}
                    and type(doc["schema_version"]) is int and doc["schema_version"] == 1
                    and doc["kind"] == "shadow_write_request" and c._id(doc["id"])
                    and isinstance(doc["body"], dict) and set(doc["body"]) == REQUEST_KEYS
                    and doc["body"]["attempt_id"] == doc["id"]
                    and type(doc["body"]["attempt_number"]) is int
                    and doc["body"]["attempt_number"] == 1 and c._id(doc["body"]["scope_id"]), "E_SHAPE")
            self.paths = {key: Path(doc["body"][key]) for key in e.REQUEST_BODY_KEYS -
                          {"attempt_id", "attempt_number"}}
            require(all(path.is_absolute() and path.resolve() == path for path in self.paths.values()), "E_SHAPE")
            e.private_empty(work)
            e.private_empty(output)
            e.disjoint([request, bundle, work, output, *self.paths.values()])
            self.work_hold = e.stable_directory(work)
            self.owned.append(self.work_hold)
            self.output_hold = e.stable_directory(output)
            self.owned.append(self.output_hold)
            self.bundle_hold = e.stable_directory(bundle)
            self.owned.append(self.bundle_hold)
            self.bundle = bundle
            for name in ("dependencies", "captured", "runtime", "frozen", "seed", "builder",
                         "candidate", "materializer", "preparation-parent", "preparation-scratch",
                         "inspection-scratch", "checks", "observation", "launch", "receipt"):
                (work / name).mkdir(mode=0o700)
            for name in ("helper", "jq"):
                (work / "dependencies" / name).mkdir(mode=0o700)
            self.python = self.hold(Path(sys.executable), c.EXECUTABLE_LIMIT)
            self.consumer = self.hold(SOURCE / "shadow/v1/_consumer.py", c.EXECUTABLE_LIMIT)
            self.admission_source = self.hold(_ADMISSION_PATH, c.EXECUTABLE_LIMIT)
            require(self.admission_source.raw == _ADMISSION_SOURCE.raw
                    and self.admission_source.sha256 == _ADMISSION_SHA256 and a.c is c, "E_RUNTIME")
            def command(role, argv, executable_sha256, component_sha256):
                self.commands.append({"role": role, "argv_sha256": sha(canonical(argv)),
                    "executable_sha256": executable_sha256, "component_sha256": component_sha256})
            self.resolver = (e._DarwinUUIDResolver(self.python, self.consumer, self.deadline, command)
                             if sys.platform == "darwin" else None)
            group = e._DarwinGroupReader(self.resolver) if self.resolver is not None else None
            self.anchor = c.load_anchor(self.resolver, group)
            self.owned.append(self.anchor)
            exclusions = [SOURCE, request, bundle, Path(c.ANCHOR).parent, *self.paths.values(),
                Path(self.anchor.config["store_root"]), Path(self.anchor.config["work_root"])]
            exclusions += [Path(value) for value in self.anchor.config["installed_files"].values()]
            exclusions += [Path(value) for key, value in self.anchor.config["identity_paths"].items()
                           if key != "dyld_cache_files"]
            exclusions += list(map(Path, self.anchor.config["identity_paths"]["dyld_cache_files"]))
            e.outside([work, output], exclusions)
            require(str(self.paths["closure_helper"]) == parent["helper_path"], "E_RELATION")
            self.helper = c.snapshot_dependency(str(self.paths["closure_helper"]),
                parent["helper_executable_sha256"], parent["helper_executable_size"],
                str(work / "dependencies/helper/object-closure"), "object-closure")
            self.owned.append(self.helper)
            self.jq = c.snapshot_jq(str(self.paths["jq"]), str(work / "dependencies/jq/jq"))
            self.owned.append(self.jq)
            self.bash = e.fixed_bash()
            self.owned.append(self.bash)
            self.sudo = e.fixed_sudo()
            self.owned.append(self.sudo)
            self.git = self.hold(Path("/usr/bin/git").resolve(), c.EXECUTABLE_LIMIT, True)
            self.git_named = e.stable_file(Path("/usr/bin/git"), allow_hardlinks=True)
            self.owned.append(self.git_named)
            self.env = e.clean_env(Path(self.jq.snapshot.path), work / "runtime")
            registry = self.hold(SOURCE / "core/v2/generation-registry.json", e.OUTPUT_LIMIT)
            self.modules = e.core_modules(registry.raw)
            relative = ["shadow/v1/write-shadow.py", "shadow/v1/enforced-reproduction.py",
                "shadow/v1/write-materialization-input.jq", "shadow/v1/qualified-identity.jq",
                "shadow/v1/validate-incident.sh", "shadow/v1/incident-record.jq",
                "maintenance/v1/incident-to-eval.sh", "maintenance/v1/incident-to-eval.jq",
                "maintenance/v1/bands.jq", "evals/v1/eval-catalog.json", "evals/v1/seed-set.json",
                "scope/v1/scope-policy.json", "config/construction-mode.json",
                "adapters/local-git-materializer/v1/materialize.sh",
                "adapters/local-git-materializer/v1/protocol.jq",
                "adapters/local-git-materializer/v1/object-closure.c", "scripts/core-contract.sh",
                "preparation/v1/prepare-candidate.py", "control/v1/evaluate-bound-sandbox.sh",
                "control/v1/sandbox-bound.jq", "control/v1/sandbox-bound-policy.json",
                "control/v1/sandbox-bound-decision.json", "control/v1/control-policy-set-sandbox-bound.json",
                "control/v1/validate.sh", "control/v1/policy-set.jq",
                "enforcement/v1/check-sandbox-receipt.sh", "enforcement/v1/sandbox-receipt.jq",
                "telemetry/v1/validate-trace-ledger.sh", "telemetry/v1/trace-ledger.jq"]
            paths = [SOURCE / path for path in relative] + list(self.modules.glob("*.jq"))
            paths += [self.modules.parent / "core-ingress.sh", self.modules.parent / "contracts.jq"]
            self.components = {path: self.hold(path, 8 * e.OUTPUT_LIMIT) for path in paths}
            if self.record_form == "withheld-write-policy.v1":
                c.scope_policy_ref(self.components[SOURCE / "scope/v1/scope-policy.json"].raw)
            require(self.components[SOURCE / c.HELPER_SOURCE].sha256 == parent["helper_source_sha256"], "E_RELATION")
            c.verify_helper_source()
            self.helper.recheck()
            require(e.run_bounded("helper-version", [self.helper.snapshot.path, "version"],
                env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
                deadline=self.deadline) == b"ystack-object-closure-v1\n", "E_RELATION")
            self.helper.recheck()
            for role in ("incident", "claim", "duty_evaluation", "materialization_input", "qualified_identity"):
                path = self.paths[role]
                limit = 8 * e.OUTPUT_LIMIT if role == "materialization_input" else e.OUTPUT_LIMIT
                raw = self.hold(path, limit).raw
                self.capture(role + ".json", raw)
            self.recheck()
        except BaseException:
            self.close()
            raise

    def hold(self, path, limit, hardlinks=False):
        item = e.stable_file(path, limit, allow_hardlinks=hardlinks)
        self.owned.append(item)
        return item

    def capture(self, name, raw, directory="captured"):
        path = self.work / directory / name
        e.write_exclusive(path, raw)
        self.inputs.append((path, raw))
        return path

    def recheck(self, sealed=False):
        _ADMISSION_SOURCE.recheck("E_RUNTIME")
        require(sys.modules.get("ystack_publisher_admission") is a
                and sys.modules.get("ystack_shadow_consumer") is c and a.c is c, "E_RUNTIME")
        for path, raw in self.inputs:
            require(e.read_regular(path, max(1, len(raw))) == raw, "E_RELATION")
        for item in self.owned:
            if sealed and item is self.anchor:
                item.seal_recheck()
            elif hasattr(item, "recheck"):
                item.recheck()
        native = e.CancellationSignals.active.native if e.CancellationSignals.active else None
        require(isinstance(native, e._NativeRelease), "E_RUNTIME")
        native.recheck()

    def execute(self, role, argv, component, **options):
        self.recheck()
        if argv[0] == "/bin/bash":
            executable_sha = self.bash.physical.sha256
        elif argv[0] == self.jq.snapshot.path:
            executable_sha = self.jq.sha256
        elif argv[0] == "/usr/bin/git":
            executable_sha = self.git.sha256
        elif argv[0] == sys.executable:
            executable_sha = self.python.sha256
        else:
            raise e.Refusal("E_RELATION")
        self.commands.append({"role": role, "argv_sha256": sha(canonical(argv)),
            "executable_sha256": executable_sha,
            "component_sha256": self.components[component].sha256})
        result = e.run_bounded(role, argv, env=self.env, deadline=self.deadline, **options)
        self.recheck()
        return result

    def component(self, role, relative, args, **options):
        path = SOURCE / relative
        return self.execute(role, ["/bin/bash", "-p", str(path), *args], path, **options)

    def protocol(self, operation, path):
        source = SOURCE / "adapters/local-git-materializer/v1/protocol.jq"
        raw = self.execute("materializer-" + ("input" if operation == "validate-input" else "response")
            + "-validation", [self.jq.snapshot.path, "-L", str(self.modules), "-e", "--arg",
            "command", operation, "-f", str(source), str(path)], source)
        require(raw.strip() == b"true", "E_RELATION")

    def execute_git(self, argv, limit):
        return self.execute("write-git-inspection", argv, SOURCE / "shadow/v1/write-shadow.py",
                            output_limit=limit)

    def git_owner(self, repository):
        if not hasattr(self, "git_owners"):
            self.git_owners = {}
        key = str(repository)
        if key not in self.git_owners:
            owner = c._ReadOnlyGit(key, self)
            self.owned.append(owner)
            self.git_owners[key] = owner
        return self.git_owners[key]

    def git_read(self, repository, args, limit):
        try:
            return self.git_owner(repository).read(args, limit)
        except c.Refusal as exc:
            raise e.Refusal(exc.code) from exc

    def close(self):
        owned = self.owned
        self.owned = []
        e.close_all(reversed(owned))


def _inventory(ws):
    require(set(os.listdir(ws.bundle_hold.held.fd)) == set(NAMES), "E_RELATION")
    files = {}
    for name in NAMES:
        limit = 8 * e.OUTPUT_LIMIT if name == "materialization-input.json" else (
            2 * e.OUTPUT_LIMIT if name == "preparation-manifest.json" else e.OUTPUT_LIMIT)
        files[name] = ws.hold(ws.bundle / name, limit).raw
        ws.capture(name, files[name], "frozen")
    bundle = parse(files["bundle.json"])
    incident = parse(files["incident.json"])
    require(bundle == {"schema_version": 1, "kind": "shadow_consumer_bundle",
        "id": "bundle." + sha(files["incident.json"])[:32], "body": {
            "activation_state": "inactive", "record_form": "enforced-reproduction.v1",
            "incident_sha256": sha(files["incident.json"]),
            "target_revision": incident["body"]["git_revision_ref"],
            "files": [{"name": name, "size_bytes": len(files[name]), "sha256": sha(files[name])}
                      for name in sorted(e.EVIDENCE_NAMES)]}}, "E_RELATION")
    for name in e.EVIDENCE_NAMES:
        if name.endswith(".json"):
            parse(files[name], 8 * e.OUTPUT_LIMIT)
    installed = {"accepted-identities.json": "accepted_set", "registry.json": "registry",
        "evaluator-driver.txt": "evaluator_driver", "evaluator-program.txt": "evaluator_program",
        "policy.json": "control_policy", "decision.json": "control_decision", "policy-set.json": "control_policy_set"}
    require(all(files[name] == ws.anchor.installed[role][0] for name, role in installed.items()), "E_RELATION")
    for role, name in (("incident", "incident.json"), ("materialization_input", "materialization-input.json"),
                       ("qualified_identity", "qualified-identity.json")):
        require((ws.work / "captured" / (role + ".json")).read_bytes() == files[name], "E_RELATION")
    provenance = _provenance(ws, files)
    native = e.CancellationSignals.active.native
    require(provenance["body"]["native_release"] == native.provenance(ws.parent)
            and provenance["body"]["instruction_utf8"].encode() == e.make_instruction(incident)
            and provenance["body"]["instruction_sha256"] == sha(e.make_instruction(incident)), "E_RELATION")
    ws.component("incident-validation", "shadow/v1/validate-incident.sh", ["validate", str(ws.work / "frozen/incident.json")])
    ws.protocol("validate-input", ws.work / "frozen/materialization-input.json")
    input_doc = parse(files["materialization-input.json"], 8 * e.OUTPUT_LIMIT)
    identity = parse(files["qualified-identity.json"])
    claim = parse(files["claim.json"])
    e.validate_input_relations(input_doc, incident, claim, identity, e.make_instruction(incident))
    _identity_check(ws, files["qualified-identity.json"], incident)
    receipt = e.require_no_change(files["materialization-response.json"], incident)
    response_check = ws.capture("frozen-response-check.json", e.response_check(input_doc, files["materialization-response.json"]))
    ws.protocol("validate-response", response_check)
    return files, incident, receipt


def _provenance(ws, files):
    doc = parse(files["consumer-provenance.json"])
    digests = {"helper_source_sha256": ws.parent["helper_source_sha256"],
        "helper_build_record_sha256": ws.parent["helper_build_record_sha256"],
        "helper_executable_sha256": ws.parent["helper_executable_sha256"],
        "consumer_source_sha256": ws.components[SOURCE / "shadow/v1/enforced-reproduction.py"].sha256,
        "python_sha256": ws.python.sha256, "jq_sha256": ws.jq.sha256}
    keys = {"activation_state", "authority", "instruction_utf8", "instruction_sha256",
            "observation", "observation_sha256", "native_release", "commands", *digests}
    require(set(doc) == {"schema_version", "kind", "id", "body"}
            and type(doc["schema_version"]) is int and doc["schema_version"] == 1
            and doc["kind"] == "shadow_consumer_provenance"
            and doc["id"] == parse(files["sandbox-request.json"])["id"]
            and c._id(doc["id"]) and type(doc["body"]) is dict
            and set(doc["body"]) == keys, "E_RELATION")
    body = doc["body"]
    require(body["activation_state"] == "inactive" and body["authority"] == "none"
            and type(body["instruction_utf8"]) is str
            and type(body["observation"]) is dict and type(body["native_release"]) is dict
            and all(c._sha(body[key]) and body[key] == value for key, value in digests.items())
            and c._sha(body["instruction_sha256"]) and c._sha(body["observation_sha256"])
            and body["observation_sha256"] == sha(canonical(body["observation"])), "E_RELATION")
    commands = body["commands"]
    supervisor = next(item for item in ws.anchor.held if item.path == str(Path(c.ANCHOR) / "host-supervisor.py"))
    fixed = {"helper-version": (ws.helper.sha256, digests["helper_source_sha256"]),
        "jq-version": (ws.jq.sha256, ws.jq.sha256),
        "sandbox-launch-boundary": (ws.sudo.sha256, sha(supervisor.read(c.EXECUTABLE_LIMIT, "E_RELATION"))),
        "darwin-acl-uuid-resolution": (ws.python.sha256, ws.consumer.sha256),
        "darwin-group-membership": (ws.python.sha256, ws.consumer.sha256)}
    for executable, sources in ((ws.bash.physical.sha256, {
        "incident-validation": "shadow/v1/validate-incident.sh",
        "materialization": "adapters/local-git-materializer/v1/materialize.sh",
        "sandbox-bound-evaluation": "control/v1/evaluate-bound-sandbox.sh",
        "sandbox-receipt-check": "enforcement/v1/check-sandbox-receipt.sh",
        "trace-validation": "telemetry/v1/validate-trace-ledger.sh"}), (ws.jq.sha256, {
        "materializer-input-validation": "adapters/local-git-materializer/v1/protocol.jq",
        "materializer-response-validation": "adapters/local-git-materializer/v1/protocol.jq",
        "qualified-identity-validation": "shadow/v1/qualified-identity.jq"}), (ws.python.sha256, {
        "candidate-preparation": "preparation/v1/prepare-candidate.py",
        "candidate-inspection": "preparation/v1/prepare-candidate.py"})):
        fixed.update({role: (executable, ws.components[SOURCE / path].sha256) for role, path in sources.items()})
    require(type(commands) is list and commands and all(type(row) is dict
        and set(row) == {"role", "argv_sha256", "executable_sha256", "component_sha256"}
        and type(row["role"]) is str and row["role"] in fixed
        and all(c._sha(row[key]) for key in ("argv_sha256", "executable_sha256", "component_sha256"))
        and (row["executable_sha256"], row["component_sha256"]) == fixed[row["role"]]
        for row in commands), "E_RELATION")
    return doc


def _identity_check(ws, raw, incident):
    source = SOURCE / "shadow/v1/qualified-identity.jq"
    revision = incident["body"]["git_revision_ref"]
    result = ws.execute("qualified-identity-validation", [ws.jq.snapshot.path, "-L", str(ws.modules),
        "-r", "--arg", "repository_id", incident["body"]["target_repository_id"], "--arg",
        "hash_algorithm", revision["hash_algorithm"], "--arg", "commit_id", revision["commit_id"],
        "-f", str(source)], source, stdin=raw)
    require(result == b"", "E_RELATION")


def _authenticated_frozen(ws, files, incident):
    launch = parse(files["sandbox-request.json"])
    expectation = parse(files["sandbox-expectation.json"])
    require(ws.request_doc["id"] != launch["id"], "E_RELATION")
    observation_raw = c.verifier_observation(ws.anchor, parse(files["claim.json"])["id"], incident["body"]["target_repository_id"])
    provenance = parse(files["consumer-provenance.json"])
    require(provenance["body"]["observation"] == parse(observation_raw)
            and provenance["body"]["observation_sha256"] == sha(observation_raw), "E_RELATION")
    observation_path = ws.capture("frozen-observation.json", observation_raw, "observation")
    evaluation = ws.component("sandbox-bound-evaluation", "control/v1/evaluate-bound-sandbox.sh",
        ["evaluate", str(ws.work / "frozen/duty-evaluation.json"), str(ws.work / "frozen/claim.json"), str(observation_path)])
    require(evaluation == files["sandbox-evaluation.json"] and parse(evaluation)["body"]["verdict"] == "satisfied", "E_RELATION")
    prep_raw, manifest_raw = files["preparation-record.json"], files["preparation-manifest.json"]
    prep, manifest = parse(prep_raw), parse(manifest_raw, 2 * e.OUTPUT_LIMIT)
    reconstructed = dict(launch["body"])
    selected = [row for row in ws.anchor.registry[1] if row["environment_id"] == ws.anchor.config["environment_id"]]
    require(len(selected) == 1, "E_RELATION")
    subject = {"environment_id": ws.anchor.config["environment_id"],
        "environment_entry_sha256": sha(canonical(selected[0])), "target_repository_id": incident["body"]["target_repository_id"],
        "source": prep["source"], "candidate": {"preparation_record_sha256": sha(prep_raw),
            "manifest_sha256": sha(manifest_raw), "commit_id": prep["candidate"]["commit_id"],
            "tree_id": prep["candidate"]["tree_id"]}, "incident_sha256": sha(files["incident.json"])}
    require(reconstructed["subject"] == subject and reconstructed["control"] == e.control(ws.anchor, evaluation)
            and reconstructed["instruction_sha256"] == sha(e.make_instruction(incident))
            and reconstructed["store_id"] == ws.anchor.config["store_id"]
            and reconstructed["attempt"] == {"attempt_id": launch["id"], "attempt_number": 1}
            and expectation == {"schema_version": 1, "kind": "sandbox_receipt_expectation", "id": launch["id"],
                "body": {"attempt": reconstructed["attempt"] | {"launch_request_sha256": sha(files["sandbox-request.json"])},
                    "control": reconstructed["control"], "store_id": reconstructed["store_id"], "subject": subject}}, "E_RELATION")
    snapshots, fresh_origin = c.read_store_attempt(ws.anchor, launch["id"])
    mapping = {"receipt.json": "sandbox-receipt.json", "payload/stdout": "payload-stdout.txt",
        "payload/stderr": "payload-stderr.txt", "payload/evidence-manifest.json": "evidence-manifest.json",
        "payload/evidence/0000": "file-digest-result.json"}
    require(set(snapshots) == set(mapping) and all(snapshots[key] == files[name] for key, name in mapping.items()), "E_RELATION")
    check = ws.component("sandbox-receipt-check", "enforcement/v1/check-sandbox-receipt.sh",
        ["check-bound", str(ws.work / "frozen/sandbox-receipt.json"), str(ws.work / "frozen/sandbox-expectation.json"),
         str(ws.work / "frozen/sandbox-evaluation.json"), str(observation_path)])
    checked = parse(check)
    require(check == files["sandbox-check.json"] and checked["body"]["check_verdict"] == "valid"
            and checked["body"]["enforcement_verdict"] == "satisfied", "E_RELATION")
    result_raw, result = e.payload_result(snapshots, parse(files["evidence-manifest.json"]),
        e.make_instruction(incident), manifest, parse(files["sandbox-receipt.json"]))
    _record_relations(files, incident, result, fresh_origin, ws.anchor)
    trace_receipt = ws.component("trace-validation", "telemetry/v1/validate-trace-ledger.sh",
        ["validate", incident["id"], launch["id"], str(ws.work / "frozen/trace-ledger.json")])
    require(trace_receipt == files["trace-receipt.json"] and result_raw == files["file-digest-result.json"], "E_RELATION")
    return fresh_origin


def _record_relations(files, incident, result, fresh_origin, anchor, write=None):
    record = parse(files["shadow-record.json"])
    require(set(record) == {"schema_version", "kind", "id", "body"}
        and type(record["schema_version"]) is int and record["schema_version"] == 1
        and type(record["body"]) is dict, "E_RELATION")
    body = record["body"]
    form = body.get("record_form")
    require(form in ({"withheld-write.v1", "withheld-write-policy.v1"} if write is not None else {"enforced-reproduction.v1"}), "E_RELATION")
    require(set(body) == {"record_form", "activation_state", "authority", "deploy_authority",
        "effects", "evaluation_mode", "shadow", "qualification", "outcome", "reason_id", "observed_at",
        "target_repository_id", "git_revision_ref", "qualified_identity", "qualified_identity_ref",
        "incident_ref", "environment", "materialization", "check", "sandbox", "producer_invocations",
        "consumer_provenance_ref", "trace_ledger_ref"} | ({"write"} if write is not None else set()) | ({"scope_policy_ref"} if form == "withheld-write-policy.v1" else set()), "E_RELATION")
    if form == "withheld-write-policy.v1":
        c.check_scope_policy_ref(body["scope_policy_ref"], files["scope-policy.json"])
    else:
        require("scope-policy.json" not in files, "E_RELATION")
    if write is not None:
        require(canonical(body["write"]) == canonical(write), "E_RELATION")
    outcome = "no-change" if result["outcome"] == "match" else "reproduced"
    require(record["schema_version"] == 1 and record["kind"] == "shadow_reproduction_record"
            and record["id"] == incident["id"] and body["record_form"] == form
            and body["activation_state"] == "inactive" and body["authority"] == "none"
            and body["deploy_authority"] == "none" and body["shadow"] is True
            and body["qualification"] == {"state": "unavailable", "reason_id": "shadow.unqualified"}
            and body["outcome"] == outcome and type(body["producer_invocations"]) is int
            and body["producer_invocations"] == 0
            and body["git_revision_ref"] == incident["body"]["git_revision_ref"]
            and body["target_repository_id"] == incident["body"]["target_repository_id"]
            and body["check"]["failing_check"] == incident["body"]["failing_check"]
            and body["qualified_identity"] == parse(files["qualified-identity.json"])["body"], "E_RELATION")
    require(body["effects"] == ["caller-disposable-candidate-repository"]
            and body["evaluation_mode"] == "observation-only"
            and body["reason_id"] == ("check.passed-at-revision" if outcome == "no-change" else "check.failed-at-revision")
            and body["observed_at"] == incident["body"]["observed_at"], "E_RELATION")
    response = parse(files["materialization-response.json"])
    receipt = parse(response["payloads"][0]["data"].encode())
    stage = response["stage_result"]
    require(body["materialization"] == {"state": "present", "value": {
        "adapter_id": "adapter.local-git-materializer.v1", "outcome": ("changed" if write is not None else "no-change"),
        "source": receipt["source"], "candidate": receipt["candidate"],
        "stage_result_ref": {"schema_version": 2, "kind": "stage_result", "id": stage["id"],
                             "sha256": sha(canonical(stage))}}}, "E_RELATION")
    prep = parse(files["preparation-record.json"])
    require(prep["source"] == receipt["source"]
            and all(prep["candidate"][key] == receipt["candidate"][key] for key in ("commit_id", "tree_id")), "E_RELATION")
    require(body["check"]["execution"] == {"state": "present", "value": {
        "tool_id": "tool.verifier", "observed_sha256": result["observed"]["sha256"],
        "matches_expected": result["outcome"] == "match"}}, "E_RELATION")
    evaluation = parse(files["sandbox-evaluation.json"])
    claim = parse(files["claim.json"])
    duty_ref = e.document_ref(files["duty-evaluation.json"])
    require(canonical(evaluation["body"]["claim_ref"]) == canonical(e.document_ref(files["claim.json"]))
            and canonical(evaluation["body"]["duty_evaluation_ref"]) == canonical(duty_ref)
            and canonical(claim["body"]["duty_evaluation_ref"]) == canonical(duty_ref), "E_RELATION")
    if write is not None:
        generated = parse(files["materialization-input.json"], 8 * e.OUTPUT_LIMIT)
        require(generated["stage_request"]["content"]["body"]["environment_ref"] == {
            "environment_id": claim["id"], "fingerprint_sha256": sha(files["claim.json"])}, "E_RELATION")
    require(body["environment"]["environment_id"] == parse(files["claim.json"])["id"]
            and body["environment"]["evaluation"] == {"state": "present", "value": {
                "verdict": evaluation["body"]["verdict"], "reason_ids": evaluation["body"]["reason_ids"],
                "evaluation_ref": {"content_id": "shadow-sandbox-evaluation",
                    "media_type": "application/vnd.ystack.control-evaluation+json",
                    "sha256": sha(files["sandbox-evaluation.json"])}}}, "E_RELATION")
    require(files["trace-ledger.json"] == e.trace_ledger(incident, parse(files["sandbox-request.json"])["id"],
        parse(files["claim.json"])["id"], outcome, "tool.verifier", files["sandbox-evaluation.json"], files["sandbox-check.json"]), "E_RELATION")
    origin = parse(files["origin-observation.json"])
    require(origin["kind"] == "shadow_origin_observation" and origin["body"]["result"] == "authenticated"
            and origin["body"]["store_id"] == anchor.config["store_id"]
            and origin["id"] == origin["body"]["attempt_id"] == parse(files["sandbox-request.json"])["id"], "E_RELATION")
    for key, name in (("consumer_provenance_ref", "consumer-provenance.json"),):
        require(body[key] == e.document_ref(files[name]), "E_RELATION")
    content_refs = {"incident_ref": "incident.json", "qualified_identity_ref": "qualified-identity.json", "trace_ledger_ref": "trace-ledger.json"}
    require(all(body[key]["sha256"] == sha(files[name]) for key, name in content_refs.items()), "E_RELATION")
    sandbox = body["sandbox"]
    require(sandbox["state"] == "satisfied" and sandbox["reason_id"] == "shadow.sandbox-satisfied"
            and sandbox["origin"] == {"state": "authenticated", "store_id": anchor.config["store_id"],
                "method": "controlled-storage.v1", "observation_sha256": sha(files["origin-observation.json"])}
            and parse(fresh_origin)["body"]["attempt_id"] == parse(files["sandbox-request.json"])["id"], "E_RELATION")
    for key, name in (("launch_request_ref", "sandbox-request.json"), ("expectation_ref", "sandbox-expectation.json"),
                      ("receipt_ref", "sandbox-receipt.json"), ("check_ref", "sandbox-check.json")):
        require(sandbox[key] == e.document_ref(files[name]), "E_RELATION")
    require(sandbox["payload_ref"]["sha256"] == sha(files["file-digest-result.json"])
            and body["environment"]["claim_ref"]["sha256"] == sha(files["claim.json"])
            and body["environment"]["registry_ref"]["sha256"] == sha(files["registry.json"])
            and body["environment"]["evaluation"]["value"]["evaluation_ref"]["sha256"] == sha(files["sandbox-evaluation.json"]), "E_RELATION")


def _git_inventory(ws, repository, revision):
    try:
        return ws.git_owner(repository).inventory(revision)
    except c.Refusal as exc:
        raise e.Refusal(exc.code) from exc


def _write_files(ws, frozen, incident, source_facts):
    incident_id = incident["id"]
    require(isinstance(incident_id, str) and all(char in "abcdefghijklmnopqrstuvwxyz0123456789._-" for char in incident_id), "E_RELATION")
    root = "ystack-evidence/" + incident_id
    policy = parse(ws.components[SOURCE / "scope/v1/scope-policy.json"].raw)
    mode = json.loads(ws.components[SOURCE / "config/construction-mode.json"].raw)
    names = [*NAMES, "eval-seed.json", "README.md"]
    if ws.record_form == "withheld-write-policy.v1":
        c.scope_policy_ref(ws.components[SOURCE / "scope/v1/scope-policy.json"].raw)
        names.append("scope-policy.json")
    paths = sorted(root + "/" + name for name in names)
    require(ws.request_doc["body"]["allowed_paths"] == paths
            and all(c.write_path_ok(path, policy, mode) for path in paths), "E_RELATION")
    require(not any(path.lower() == root.lower() or path.lower().startswith(root.lower() + "/")
                    for path in source_facts), "E_RELATION")
    require(all(path.lower() != "ystack-evidence" or
                (path == "ystack-evidence" and source_facts[path][:2] == ("040000", "tree"))
                for path in source_facts), "E_RELATION")
    seed_raw = ws.component("write-seed-conversion", "maintenance/v1/incident-to-eval.sh",
        ["convert", str(ws.work / "frozen/incident.json"), str(ws.work / "frozen/shadow-record.json"), str(ws.work / "seed")])
    require(set(os.listdir(ws.work / "seed")) == {"eval-seed-case-stale-moved-artifacts.json"}, "E_RELATION")
    require(ws.hold(ws.work / "seed/eval-seed-case-stale-moved-artifacts.json", e.OUTPUT_LIMIT).raw == seed_raw, "E_RELATION")
    parse(seed_raw)
    files = {root + "/" + name: raw for name, raw in frozen.items()}
    files[root + "/eval-seed.json"] = seed_raw
    files[root + "/README.md"] = b"Shadow evidence. Publication is withheld.\n"
    if ws.record_form == "withheld-write-policy.v1":
        files[root + "/scope-policy.json"] = ws.components[SOURCE / "scope/v1/scope-policy.json"].raw
    patch, facts = c.evidence_patch(files, incident["body"]["git_revision_ref"]["hash_algorithm"], ws.record_form)
    return files, paths, patch, facts


def _build_input(ws, original_raw, paths, patch, claim_raw):
    builder = SOURCE / "shadow/v1/write-materialization-input.jq"
    contract = c.write_contract(paths, ws.record_form)
    contract_path = ws.capture("contract.json", contract, "builder")
    patch_path = ws.capture("producer.patch", patch, "builder")
    metadata = {key: sha(value) for key, value in c.WRITE_TEXTS.items()}
    for key, raw in c.WRITE_TEXTS.items():
        ws.capture(key + ".txt", raw, "builder")
    metadata.update({"contract": sha(contract), "patch": sha(patch), "allowed_paths": paths,
        "attempt_id": ws.request_doc["id"], "suffix": sha(ws.request_doc["id"].encode())[:32],
        "environment_id": parse(claim_raw)["id"], "claim_sha256": sha(claim_raw),
        "record_form": ws.record_form, "incident_id": parse((ws.work / "frozen/incident.json").read_bytes())["id"]})
    def phase(name, input_path, metadata_path):
        return ws.execute("write-materialization-input", [ws.jq.snapshot.path, "-L", str(ws.modules),
            "-S", "-c", "--arg", "phase", name, "--rawfile", "contract", str(contract_path),
            "--rawfile", "patch", str(patch_path), "--slurpfile", "metadata", str(metadata_path),
            "-f", str(builder), str(input_path)], builder, output_limit=8 * e.OUTPUT_LIMIT)
    metadata_path = ws.capture("metadata-first.json", canonical(metadata), "builder")
    first_raw = phase("stage-request", ws.work / "frozen/materialization-input.json", metadata_path)
    first = parse(first_raw, 8 * e.OUTPUT_LIMIT)
    require(canonical(first["original"]) == original_raw, "E_RELATION")
    first_path = ws.capture("first.json", first_raw, "builder")
    stage_raw = canonical(first["stage_request"])
    ws.capture("stage-request.json", stage_raw, "builder")
    metadata["stage_request_sha256"] = sha(stage_raw)
    second_metadata = ws.capture("metadata-final.json", canonical(metadata), "builder")
    result_raw = phase("final-input", first_path, second_metadata)
    result = parse(result_raw, 8 * e.OUTPUT_LIMIT)
    require(result["stage_request"] == {"content": first["stage_request"], "sha256": sha(stage_raw)}, "E_RELATION")
    for key in ("profile", "resolved_profile", "manifests"):
        require(result[key] == parse(original_raw, 8 * e.OUTPUT_LIMIT)[key], "E_RELATION")
    result_path = ws.capture("write-input.json", result_raw, "builder")
    ws.protocol("validate-input", result_path)
    return result_raw, result_path


def _candidate_facts(ws, response_raw, incident, source_facts, files, expected):
    try:
        return a.candidate_facts(ws.git_owner(ws.paths["source_git_dir"]),
            ws.git_owner(ws.work / "candidate/repository.git"), response_raw, incident,
            source_facts, files, expected, ws.record_form)
    except c.Refusal as exc:
        raise e.Refusal(exc.code) from exc


def _verify_write(ws, incident, input_raw, record_raw, manifest_raw, evaluation_raw, observation_raw):
    instruction = e.make_instruction(incident)
    manifest = parse(manifest_raw, 2 * e.OUTPUT_LIMIT)
    launch_raw, expectation_raw = e.make_launch(ws.anchor, ws.request_doc,
        (ws.work / "frozen/incident.json").read_bytes(), evaluation_raw, observation_raw,
        record_raw, manifest_raw, instruction)
    launch_path = ws.work / "launch/sandbox-request.json"
    expectation_path = ws.work / "launch/sandbox-expectation.json"
    e.write_exclusive(launch_path, launch_raw, sync=True)
    e.write_exclusive(expectation_path, expectation_raw, sync=True)
    directory = os.open(launch_path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    def records():
        yield from ((b"request.json", launch_raw), (b"evaluation.json", evaluation_raw),
            (b"incident.json", (ws.work / "frozen/incident.json").read_bytes()),
            (b"record.json", record_raw), (b"manifest.json", manifest_raw), (b"instruction", instruction))
        for index, row in enumerate(row for row in manifest["entries"] if row["kind"] == "file"):
            require(type(row["size_bytes"]) is int and row["size_bytes"] >= 0, "E_RELATION")
            raw = e.read_regular(ws.work / "preparation-parent/preparation/candidate" / row["path"], row["size_bytes"])
            require(len(raw) == row["size_bytes"] and sha(raw) == row["sha256"], "E_RELATION")
            yield f"candidate/{index:05d}".encode(), raw
    frame = e.frame_write(records())
    sudo = e.fixed_sudo()
    try:
        ws.recheck()
        sudo.recheck()
        supervisor = next(item for item in ws.anchor.held
            if item.path == str(Path(c.ANCHOR) / "host-supervisor.py"))
        supervisor.recheck("E_RELATION")
        argv = ["/usr/bin/sudo", "-n", "-u", f"#{ws.anchor.config['principal_uid']}", "--",
            sys.executable, str(Path(c.ANCHOR) / "host-supervisor.py"), "launch"]
        ws.commands.append({"role": "sandbox-launch-boundary", "argv_sha256": sha(canonical(argv)),
            "executable_sha256": sudo.sha256,
            "component_sha256": sha(supervisor.read(c.EXECUTABLE_LIMIT, "E_RELATION"))})
        require(e._launch(ws.anchor, frame, ws.deadline) == 0, "E_RUNTIME")
        sudo.recheck()
        supervisor.recheck("E_RELATION")
    finally:
        sudo.close()
    snapshots, origin_raw = c.read_store_attempt(ws.anchor, ws.request_doc["id"])
    receipt_path = ws.capture("write-receipt.json", snapshots["receipt.json"], "receipt")
    evaluation_path = ws.capture("write-evaluation.json", evaluation_raw, "checks")
    observation_path = ws.capture("write-verifier-observation.json", observation_raw, "checks")
    checker_raw = ws.component("sandbox-receipt-check", "enforcement/v1/check-sandbox-receipt.sh",
        ["check-bound", str(receipt_path), str(expectation_path), str(evaluation_path), str(observation_path)])
    check = parse(checker_raw)
    require(check["body"]["check_verdict"] == "valid" and check["body"]["enforcement_verdict"] == "satisfied", "E_RELATION")
    result_raw, _result = e.payload_result(snapshots, parse(snapshots["payload/evidence-manifest.json"]),
        instruction, manifest, parse(snapshots["receipt.json"]))
    files = {"sandbox-request.json": launch_raw, "sandbox-expectation.json": expectation_raw,
        "sandbox-receipt.json": snapshots["receipt.json"], "sandbox-check.json": checker_raw,
        "origin-observation.json": origin_raw, "payload-stdout.txt": snapshots["payload/stdout"],
        "payload-stderr.txt": snapshots["payload/stderr"],
        "evidence-manifest.json": snapshots["payload/evidence-manifest.json"],
        "file-digest-result.json": result_raw}
    for name, raw in files.items():
        ws.capture(name, raw, "checks")
    return files


def _materialize(ws):
    work, output = ws.work, ws.output
    frozen, incident, _receipt = _inventory(ws)
    origin_raw = _authenticated_frozen(ws, frozen, incident)
    revision = incident["body"]["git_revision_ref"]
    source_facts = _git_inventory(ws, ws.paths["source_git_dir"], revision)
    files, paths, patch, write_set = _write_files(ws, frozen, incident, source_facts)
    claim_raw = (work / "captured/claim.json").read_bytes()
    claim = parse(claim_raw)
    require(claim["id"] == parse(frozen["claim.json"])["id"]
            and claim["body"]["policy_set_ref"] == parse(frozen["claim.json"])["body"]["policy_set_ref"], "E_RELATION")
    observation_raw = c.verifier_observation(ws.anchor, claim["id"], incident["body"]["target_repository_id"])
    observation_path = ws.capture("write-observation.json", observation_raw, "observation")
    evaluation_raw = ws.component("sandbox-bound-evaluation", "control/v1/evaluate-bound-sandbox.sh",
        ["evaluate", str(work / "captured/duty_evaluation.json"), str(work / "captured/claim.json"), str(observation_path)])
    require(parse(evaluation_raw)["body"]["verdict"] == "satisfied", "E_RELATION")
    input_raw, input_path = _build_input(ws, frozen["materialization-input.json"], paths, patch, claim_raw)
    response_raw = ws.component("materialization", "adapters/local-git-materializer/v1/materialize.sh",
        ["materialize", str(input_path), incident["body"]["target_repository_id"], str(ws.paths["source_git_dir"]),
         str(work / "candidate"), str(work / "materializer"), ws.helper.snapshot.path, ws.jq.snapshot.path])
    response_path = ws.capture("response.json", response_raw)
    response_check = ws.capture("response-check.json", e.response_check(parse(input_raw, 8 * e.OUTPUT_LIMIT), response_raw))
    ws.protocol("validate-response", response_check)
    candidate = _candidate_facts(ws, response_raw, incident, source_facts, files, write_set)
    prep = work / "preparation-parent/preparation"
    preparation = SOURCE / "preparation/v1/prepare-candidate.py"
    common = ["--input", str(input_path), "--input-sha256", sha(input_raw), "--response", str(response_path),
        "--response-sha256", sha(response_raw), "--candidate-repository", str(work / "candidate/repository.git"),
        "--output", str(prep), "--jq", ws.jq.snapshot.path]
    for operation, scratch in (("prepare", "preparation-scratch"), ("inspect", "inspection-scratch")):
        ws.execute("candidate-" + ("preparation" if operation == "prepare" else "inspection"),
            [sys.executable, "-I", "-S", "-B", str(preparation), operation, *common,
             "--scratch", str(work / scratch)], preparation, timeout=300)
    prep_raw = ws.hold(prep / "record.json", 64 * 1024).raw
    manifest_raw = ws.hold(prep / "manifest.json", 2 * e.OUTPUT_LIMIT).raw
    instruction = e.make_instruction(incident)
    identity = parse(frozen["qualified-identity.json"])
    identity["id"] = "identity.shadow-write." + sha(ws.request_doc["id"].encode())[:32]
    identity["body"]["stage_request_ref"] = e.pair_ref(parse(input_raw, 8 * e.OUTPUT_LIMIT)["stage_request"])
    identity["body"]["verification_instructions_ref"]["sha256"] = sha(instruction)
    identity_raw = canonical(identity)
    _identity_check(ws, identity_raw, incident)
    ws.capture("write-qualified-identity.json", identity_raw)
    ws.capture("write-evaluation.json", evaluation_raw)
    ws.capture("write-origin-observation.json", origin_raw)
    verification_files = _verify_write(ws, incident, input_raw, prep_raw, manifest_raw,
        evaluation_raw, observation_raw)
    ws.recheck()
    require(_git_inventory(ws, ws.paths["source_git_dir"], revision) == source_facts, "E_RELATION")
    require(set(os.listdir(ws.bundle_hold.held.fd)) == set(NAMES), "E_RELATION")
    require(not (output / "bundle.json").exists(), "E_RELATION")
    return MaterializedWrite(files, input_raw, response_raw, identity_raw, prep_raw, manifest_raw,
        origin_raw, evaluation_raw, write_set, work / "candidate/repository.git",
        candidate["commit_id"], candidate["tree_id"], verification_files, source_facts)


def prepare(request_path: Path, bundle: Path, work: Path, output: Path, parent: dict):
    ws = _Workspace(request_path, bundle, work, output, parent)
    try:
        return _materialize(ws)
    finally:
        ws.close()


def _bundle_ref(raw):
    return a.bundle_ref(raw)


def _publisher(incident, tree):
    return a.publisher(incident, tree)


def _write_provenance(ws, incident):
    native = e.CancellationSignals.active.native
    instruction = e.make_instruction(incident)
    observation = (ws.work / "observation/write-observation.json").read_bytes()
    return canonical({"schema_version": 1, "kind": "shadow_consumer_provenance", "id": ws.request_doc["id"],
        "body": {"activation_state": "inactive", "authority": "none", "instruction_utf8": instruction.decode(),
            "instruction_sha256": sha(instruction), "observation": parse(observation), "observation_sha256": sha(observation),
            "helper_source_sha256": ws.parent["helper_source_sha256"], "helper_build_record_sha256": ws.parent["helper_build_record_sha256"],
            "helper_executable_sha256": ws.parent["helper_executable_sha256"],
            "consumer_source_sha256": ws.components[SOURCE / "shadow/v1/write-shadow.py"].sha256,
            "python_sha256": ws.python.sha256, "jq_sha256": ws.jq.sha256,
            "native_release": native.provenance(ws.parent), "commands": ws.commands}})


def _admit(ws, materialized, frozen, files, write):
    incident = parse(frozen["incident.json"])
    revision = incident["body"]["git_revision_ref"]
    draft = dict(files)
    draft["shadow-record.json"] = _outer_record(ws, materialized, frozen, files, write,
        files["consumer-provenance.json"], files["trace-ledger.json"], ws.record_form)
    inputs = a._AdmissionInputs(
        frozen["incident.json"], materialized.response_raw, canonical(write), materialized.input_raw,
        tuple(sorted(frozen.items())), tuple(sorted(materialized.files.items())), tuple(sorted(draft.items())),
        ws.hold(ws.work / "seed/eval-seed-case-stale-moved-artifacts.json", e.OUTPUT_LIMIT).raw,
        ws.record_form, ws.request_doc["body"]["scope_id"], tuple(ws.request_doc["body"]["allowed_paths"]),
        ws.components[SOURCE / "scope/v1/scope-policy.json"].raw,
        ws.components[SOURCE / "config/construction-mode.json"].raw,
        tuple(sorted(materialized.source_facts.items())), ws.git_owner(ws.paths["source_git_dir"]),
        ws.git_owner(materialized.candidate_repository))
    try:
        admitted = a.admit_write(inputs)
    except c.Refusal as exc:
        raise e.Refusal(exc.code) from exc
    require(admitted.candidate_commit_id == materialized.candidate_commit_id
            and admitted.candidate_tree_id == materialized.candidate_tree_id, "E_RELATION")
    write_set = materialized.write_set
    expected = parse(admitted.admission_raw)
    prefix = "ystack-evidence/" + incident["id"] + "/"
    require(all(materialized.files[prefix + name] == raw for name, raw in frozen.items()), "E_RELATION")
    require(set(files) == set(e.EVIDENCE_NAMES) | {"publisher-body.txt"}
            | ({"scope-policy.json"} if ws.record_form == "withheld-write-policy.v1" else set()), "E_RELATION")
    if ws.record_form == "withheld-write-policy.v1":
        raw = ws.components[SOURCE / "scope/v1/scope-policy.json"].raw
        require(files["scope-policy.json"] == materialized.files[prefix + "scope-policy.json"] == raw, "E_RELATION")
        c.scope_policy_ref(raw)
    retained = {"claim.json": (ws.work / "captured/claim.json").read_bytes(),
        "duty-evaluation.json": (ws.work / "captured/duty_evaluation.json").read_bytes(),
        "materialization-input.json": materialized.input_raw,
        "materialization-response.json": materialized.response_raw,
        "preparation-record.json": materialized.preparation_record_raw,
        "preparation-manifest.json": materialized.preparation_manifest_raw,
        "qualified-identity.json": materialized.qualified_identity_raw,
        "sandbox-evaluation.json": materialized.evaluation_raw, **materialized.verification_files}
    require(all(files[name] == raw for name, raw in retained.items()), "E_RELATION")
    require(_git_inventory(ws, ws.paths["source_git_dir"], revision) == materialized.source_facts, "E_RELATION")
    candidate = _candidate_facts(ws, materialized.response_raw, incident, materialized.source_facts,
        materialized.files, write_set)
    require(candidate["commit_id"] == materialized.candidate_commit_id
        and candidate["tree_id"] == materialized.candidate_tree_id, "E_RELATION")
    ws.recheck()
    provenance = _write_provenance(ws, incident)
    files["consumer-provenance.json"] = provenance
    files["shadow-record.json"] = _outer_record(ws, materialized, frozen, files, write,
        provenance, files["trace-ledger.json"], ws.record_form)
    final_body = parse(files["shadow-record.json"])["body"]
    draft_body = parse(draft["shadow-record.json"])["body"]
    require(final_body["write"] == draft_body["write"]
            and final_body.get("scope_policy_ref") == draft_body.get("scope_policy_ref")
            and files.get("scope-policy.json") == draft.get("scope-policy.json")
            and canonical(final_body["write"]["publisher_request"]) == admitted.publisher_request_raw
            and files["publisher-body.txt"] == admitted.body_raw
            and canonical(final_body["write"]["write_set"]) == admitted.write_set_raw
            and canonical(final_body["write"]["admission"]) == admitted.admission_raw
            and canonical(final_body["write"]["post_write_verification"]) == admitted.post_write_plan_raw,
            "E_RELATION")
    result = parse(files["file-digest-result.json"])["body"]
    _record_relations(files, incident, result, files["origin-observation.json"], ws.anchor, write)
    ws.recheck(sealed=True)
    return expected


def _outer_record(ws, materialized, frozen, files, write, provenance, trace, record_form="withheld-write.v1"):
    incident = parse(frozen["incident.json"])
    body = parse(frozen["shadow-record.json"])["body"]
    response = parse(materialized.response_raw)
    receipt = parse(response["payloads"][0]["data"].encode())
    stage = response["stage_result"]
    evaluation = parse(materialized.evaluation_raw)
    result = parse(files["file-digest-result.json"])["body"]
    outcome = "no-change" if result["outcome"] == "match" else "reproduced"
    require(record_form in {"withheld-write.v1", "withheld-write-policy.v1"}, "E_RELATION")
    body.update(record_form=record_form, qualified_identity=parse(materialized.qualified_identity_raw)["body"],
        qualified_identity_ref={"content_id": "shadow-qualified-identity",
            "media_type": "application/vnd.ystack.qualified-identity+json", "sha256": sha(materialized.qualified_identity_raw)},
        outcome=outcome, reason_id="check.passed-at-revision" if outcome == "no-change" else "check.failed-at-revision",
        materialization={"state": "present", "value": {"adapter_id": "adapter.local-git-materializer.v1",
            "outcome": stage["body"]["outcome"]["value"], "source": receipt["source"], "candidate": receipt["candidate"],
            "stage_result_ref": {"schema_version": 2, "kind": "stage_result", "id": stage["id"],
                "sha256": sha(canonical(stage))}}},
        check={"failing_check": incident["body"]["failing_check"], "execution": {"state": "present", "value": {
            "tool_id": "tool.verifier", "observed_sha256": result["observed"]["sha256"], "matches_expected": result["outcome"] == "match"}}},
        consumer_provenance_ref=e.document_ref(provenance),
        trace_ledger_ref={"content_id": "shadow-trace-ledger", "media_type": "application/vnd.ystack.telemetry-trace-ledger+json",
            "sha256": sha(trace)}, write=write)
    if record_form == "withheld-write-policy.v1":
        body["scope_policy_ref"] = c.scope_policy_ref(files["scope-policy.json"])
    body["environment"]["claim_ref"]["sha256"] = sha(files["claim.json"])
    body["environment"]["evaluation"] = {"state": "present", "value": {
        "verdict": evaluation["body"]["verdict"], "reason_ids": evaluation["body"]["reason_ids"],
        "evaluation_ref": {"content_id": "shadow-sandbox-evaluation",
            "media_type": "application/vnd.ystack.control-evaluation+json", "sha256": sha(materialized.evaluation_raw)}}}
    body["sandbox"] = {"state": "satisfied", "reason_id": "shadow.sandbox-satisfied",
        "launch_request_ref": e.document_ref(files["sandbox-request.json"]),
        "expectation_ref": e.document_ref(files["sandbox-expectation.json"]),
        "receipt_ref": e.document_ref(files["sandbox-receipt.json"]), "check_ref": e.document_ref(files["sandbox-check.json"]),
        "origin": {"state": "authenticated", "store_id": ws.anchor.config["store_id"],
            "method": "controlled-storage.v1", "observation_sha256": sha(files["origin-observation.json"])},
        "payload_ref": {"content_id": "file-digest-result", "media_type": "application/json",
            "sha256": sha(files["file-digest-result.json"])}}
    return canonical({"schema_version": 1, "kind": "shadow_reproduction_record", "id": incident["id"], "body": body})


def write(request_path: Path, bundle: Path, work: Path, output: Path, parent: dict, record_form="withheld-write.v1"):
    ws = _Workspace(request_path, bundle, work, output, parent, record_form)
    try:
        materialized = _materialize(ws)
        frozen = {name: (work / "frozen" / name).read_bytes() for name in NAMES}
        incident = parse(frozen["incident.json"])
        publisher, publisher_body = _publisher(incident, materialized.candidate_tree_id)
        stage = parse(materialized.input_raw, 8 * e.OUTPUT_LIMIT)["stage_request"]["content"]["body"]
        write_section = {"bundle_ref": _bundle_ref(frozen["bundle.json"]),
            "scope_id": ws.request_doc["body"]["scope_id"], "workflow_id": stage["workflow_id"],
            "task_class": stage["task_class_id"], "write_set": materialized.write_set, "publisher_request": publisher,
            "admission": {"state": "checked", "effect": "none", "request_sha256": sha(canonical(publisher)),
                "write_set_sha256": sha(canonical(materialized.write_set))},
            "publication": {"state": "withheld", "reason_id": "shadow.write-not-published"},
            "post_write_verification": {"target_revision": incident["body"]["git_revision_ref"],
                "candidate_tree_id": materialized.candidate_tree_id, "write_set": materialized.write_set}}
        files = {name: frozen[name] for name in e.EVIDENCE_NAMES}
        files.update({"claim.json": (work / "captured/claim.json").read_bytes(),
            "duty-evaluation.json": (work / "captured/duty_evaluation.json").read_bytes(),
            "materialization-input.json": materialized.input_raw,
            "materialization-response.json": materialized.response_raw,
            "preparation-record.json": materialized.preparation_record_raw,
            "preparation-manifest.json": materialized.preparation_manifest_raw,
            "qualified-identity.json": materialized.qualified_identity_raw,
            "sandbox-evaluation.json": materialized.evaluation_raw,
            "publisher-body.txt": publisher_body, **materialized.verification_files})
        if ws.record_form == "withheld-write-policy.v1":
            files["scope-policy.json"] = ws.components[SOURCE / "scope/v1/scope-policy.json"].raw
        result = parse(files["file-digest-result.json"])["body"]
        outcome = "no-change" if result["outcome"] == "match" else "reproduced"
        trace = e.trace_ledger(incident, ws.request_doc["id"], parse(files["claim.json"])["id"],
            outcome, "tool.verifier", materialized.evaluation_raw, files["sandbox-check.json"])
        trace_path = ws.capture("write-trace-ledger.json", trace)
        trace_receipt = ws.component("trace-validation", "telemetry/v1/validate-trace-ledger.sh",
            ["validate", incident["id"], ws.request_doc["id"], str(trace_path)])
        files.update({"trace-ledger.json": trace, "trace-receipt.json": trace_receipt})
        _admit(ws, materialized, frozen, files, write_section)
        ws.anchor.seal_recheck()
        ws.recheck(sealed=True)
        rows = [{"name": name, "size_bytes": len(raw), "sha256": sha(raw)} for name, raw in sorted(files.items())]
        marker = canonical({"schema_version": 1, "kind": "shadow_consumer_bundle", "id": "bundle." + sha(files["incident.json"])[:32],
            "body": {"activation_state": "inactive", "record_form": ws.record_form,
                "incident_sha256": sha(files["incident.json"]), "target_revision": incident["body"]["git_revision_ref"], "files": rows}})
        directory = ws.output_hold.held.fd
        for name, raw in sorted(files.items()):
            e.CancellationSignals.checkpoint()
            ws.output_hold.recheck("E_RELATION")
            e.write_exclusive_at(directory, name, raw, sync=True)
        ws.output_hold.recheck("E_RELATION")
        require(set(os.listdir(directory)) == set(files), "E_RELATION")
        os.fsync(directory)
        ws.recheck(sealed=True)
        require(e.CancellationSignals.retain_completion(directory) is True, "E_RUNTIME")
        e.CancellationSignals.prepare_completion(marker)
        return marker
    finally:
        ws.close()


def _startup():
    require(__name__ == "__main__" and sys.flags.isolated == 1 and sys.flags.no_site == 1
            and sys.flags.dont_write_bytecode == 1, "E_RUNTIME")
    require(not any(key.startswith(("LD_", "DYLD_")) for key in os.environ), "E_RUNTIME")
    executable = Path(sys.executable)
    require(executable.is_absolute() and executable.resolve(strict=True) == executable, "E_RUNTIME")
    e._runtime_callbacks_clear()
    gc.disable()
    held = e.stable_file(executable)
    try:
        digest = held.sha256
        held.recheck("E_RUNTIME")
    finally:
        held.close()
    return e._StartupAdmission(e._STARTUP_KEY, str(executable), digest, sys.version,
        tuple(sys.version_info[:2]), e._runtime_module_origins(), e._NativeThreadCensus())


def main(argv, admission=None):
    native = owner = None
    try:
        require(isinstance(admission, e._StartupAdmission) and admission.key is e._STARTUP_KEY, "E_RUNTIME")
        require(len(argv) == 6 and argv[1] in {"prepare", "prepare-policy"}, "E_USAGE")
        context = c.capture_parent_context()
        native = e._NativeRelease(context, admission)
        admission = dataclasses.replace(admission, native=native, module_origins=e._runtime_module_origins())
        owner = e.CancellationSignals(admission)
        with owner:
            try:
                write(*map(Path, argv[2:]), context,
                    "withheld-write-policy.v1" if argv[1] == "prepare-policy" else "withheld-write.v1")
            except BaseException as exc:
                closing, native = native, None
                try:
                    closing.close()
                except BaseException as close_exc:
                    raise exc from close_exc
                raise
            closing, native = native, None
            closing.close()
        return 0
    except BaseException as exc:
        if owner is not None and owner.caller_exception is exc:
            raise
        if isinstance(exc, (e.Cancelled, e.Refusal, c.Refusal, KeyError, TypeError, ValueError, OSError, json.JSONDecodeError)):
            code = exc.code if isinstance(exc, (e.Refusal, c.Refusal)) else "E_RUNTIME"
            print(code if code in {"E_USAGE", "E_RUNTIME", "E_LIMIT", "E_SHAPE", "E_CANONICAL", "E_RELATION",
                "E_WORKSPACE", "E_PARENT_CONTEXT"} else "E_RUNTIME", file=sys.stderr)
            return 1
        raise
    finally:
        if native is not None:
            native.close()


if __name__ == "__main__":
    try:
        admission = _startup()
    except Exception:
        print("E_RUNTIME", file=sys.stderr)
        raise SystemExit(1) from None
    raise SystemExit(main(sys.argv, admission))
