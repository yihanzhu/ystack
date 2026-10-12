#!/usr/bin/env python3
"""Private deterministic materialization; completed write admission is withheld."""
from __future__ import annotations

import dataclasses
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
e = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = e
_spec.loader.exec_module(e)
c = e.c
require, canonical, sha, parse = e.require, e.canonical, e.sha, e.parse
NAMES = (*e.EVIDENCE_NAMES, "bundle.json")
REQUEST_KEYS = e.REQUEST_BODY_KEYS | {"scope_id", "allowed_paths"}
CONFIG_KEYS = {"core.repositoryformatversion", "core.filemode", "core.bare",
               "core.logallrefupdates", "core.ignorecase", "core.precomposeunicode", "extensions.objectformat"}


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


class _Workspace:
    def __init__(self, request: Path, bundle: Path, work: Path, output: Path, parent: dict):
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
            self.output_hold = e.stable_directory(output)
            self.bundle_hold = e.stable_directory(bundle)
            self.owned.extend([self.work_hold, self.output_hold, self.bundle_hold])
            self.bundle = bundle
            for name in ("dependencies", "captured", "runtime", "frozen", "seed", "builder",
                         "candidate", "materializer", "preparation-parent", "preparation-scratch",
                         "inspection-scratch", "checks", "observation", "launch", "receipt"):
                (work / name).mkdir(mode=0o700)
            for name in ("helper", "jq"):
                (work / "dependencies" / name).mkdir(mode=0o700)
            self.python = self.hold(Path(sys.executable), c.EXECUTABLE_LIMIT)
            self.consumer = self.hold(SOURCE / "shadow/v1/_consumer.py", c.EXECUTABLE_LIMIT)
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

    def recheck(self):
        for path, raw in self.inputs:
            require(e.read_regular(path, max(1, len(raw))) == raw, "E_RELATION")
        for item in self.owned:
            if hasattr(item, "recheck"):
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

    def git_read(self, repository, args, limit):
        return self.execute("write-git-inspection", ["/usr/bin/git", "--no-replace-objects",
            "--git-dir=" + str(repository), *args], SOURCE / "shadow/v1/write-shadow.py", output_limit=limit)

    def close(self):
        e.close_all(reversed(self.owned))
        self.owned = []


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
    provenance = parse(files["consumer-provenance.json"])
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


def _record_relations(files, incident, result, fresh_origin, anchor):
    record = parse(files["shadow-record.json"])
    body = record["body"]
    outcome = "no-change" if result["outcome"] == "match" else "reproduced"
    require(record["schema_version"] == 1 and record["kind"] == "shadow_reproduction_record"
            and record["id"] == incident["id"] and body["record_form"] == "enforced-reproduction.v1"
            and body["activation_state"] == "inactive" and body["authority"] == "none"
            and body["deploy_authority"] == "none" and body["shadow"] is True
            and body["qualification"] == {"state": "unavailable", "reason_id": "shadow.unqualified"}
            and body["outcome"] == outcome and body["producer_invocations"] == 0
            and body["git_revision_ref"] == incident["body"]["git_revision_ref"]
            and body["target_repository_id"] == incident["body"]["target_repository_id"]
            and body["check"]["failing_check"] == incident["body"]["failing_check"]
            and body["qualified_identity"] == parse(files["qualified-identity.json"])["body"], "E_RELATION")
    require(set(body) == {"record_form", "activation_state", "authority", "deploy_authority",
        "effects", "evaluation_mode", "shadow", "qualification", "outcome", "reason_id", "observed_at",
        "target_repository_id", "git_revision_ref", "qualified_identity", "qualified_identity_ref",
        "incident_ref", "environment", "materialization", "check", "sandbox", "producer_invocations",
        "consumer_provenance_ref", "trace_ledger_ref"}, "E_RELATION")
    require(body["effects"] == ["caller-disposable-candidate-repository"]
            and body["evaluation_mode"] == "observation-only"
            and body["reason_id"] == ("check.passed-at-revision" if outcome == "no-change" else "check.failed-at-revision")
            and body["observed_at"] == incident["body"]["observed_at"], "E_RELATION")
    response = parse(files["materialization-response.json"])
    receipt = parse(response["payloads"][0]["data"].encode())
    stage = response["stage_result"]
    require(body["materialization"] == {"state": "present", "value": {
        "adapter_id": "adapter.local-git-materializer.v1", "outcome": "no-change",
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
    config = ws.hold(repository / "config", e.OUTPUT_LIMIT).raw
    config_path = ws.capture("config-" + str(len(ws.inputs)) + ".txt", config)
    keys = ws.git_read(repository, ["config", "--file", str(config_path), "--name-only", "--list", "--no-includes"], e.OUTPUT_LIMIT)
    require(set(keys.decode().splitlines()) <= CONFIG_KEYS, "E_RELATION")
    require(ws.git_read(repository, ["rev-parse", "--is-bare-repository"], 16) == b"true\n"
            and ws.git_read(repository, ["rev-parse", "--show-object-format"], 16) == (revision["hash_algorithm"] + "\n").encode(), "E_RELATION")
    forbidden = ["commondir", "shallow", "info/grafts", "objects/info/alternates", "refs/replace"]
    require(not any(os.path.lexists(repository / name) for name in forbidden), "E_RELATION")
    require(not any((repository / "worktrees").glob("*"))
            and not any((repository / "objects/pack").glob("*.promisor")), "E_RELATION")
    raw = ws.git_read(repository, ["ls-tree", "-r", "-t", "-z", "--full-tree", revision["commit_id"]], 16 * e.OUTPUT_LIMIT)
    require(not raw or raw.endswith(b"\0"), "E_RELATION")
    facts = {}
    for line in raw.split(b"\0")[:-1]:
        head, name = line.split(b"\t", 1)
        mode, kind, oid = head.decode("ascii").split(" ")
        path = name.decode("utf-8")
        require(path not in facts and c._writer_oid(oid) and len(oid) == (40 if revision["hash_algorithm"] == "sha1" else 64), "E_RELATION")
        facts[path] = (mode, kind, oid)
    return facts


def _write_files(ws, frozen, incident, source_facts):
    incident_id = incident["id"]
    require(isinstance(incident_id, str) and all(char in "abcdefghijklmnopqrstuvwxyz0123456789._-" for char in incident_id), "E_RELATION")
    root = "ystack-evidence/" + incident_id
    policy = parse(ws.components[SOURCE / "scope/v1/scope-policy.json"].raw)
    mode = json.loads(ws.components[SOURCE / "config/construction-mode.json"].raw)
    paths = sorted(root + "/" + name for name in [*NAMES, "eval-seed.json", "README.md"])
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
    patch, facts = c.evidence_patch(files, incident["body"]["git_revision_ref"]["hash_algorithm"])
    return files, paths, patch, facts


def _build_input(ws, original_raw, paths, patch, claim_raw):
    builder = SOURCE / "shadow/v1/write-materialization-input.jq"
    contract = c.write_contract(paths)
    contract_path = ws.capture("contract.json", contract, "builder")
    patch_path = ws.capture("producer.patch", patch, "builder")
    metadata = {key: sha(value) for key, value in c.WRITE_TEXTS.items()}
    for key, raw in c.WRITE_TEXTS.items():
        ws.capture(key + ".txt", raw, "builder")
    metadata.update({"contract": sha(contract), "patch": sha(patch), "allowed_paths": paths,
        "attempt_id": ws.request_doc["id"], "suffix": sha(ws.request_doc["id"].encode())[:32],
        "environment_id": parse(claim_raw)["id"], "claim_sha256": sha(claim_raw)})
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
    receipt = parse(parse(response_raw)["payloads"][0]["data"].encode())
    revision = incident["body"]["git_revision_ref"]
    require(expected == c.evidence_patch(files, revision["hash_algorithm"])[1], "E_RELATION")
    candidate = receipt["candidate"]
    require(candidate["parent_commit_id"] == revision["commit_id"] and receipt["changed_paths"]["count"] == 32, "E_RELATION")
    repository = ws.work / "candidate/repository.git"
    candidate_revision = dict(revision, commit_id=candidate["commit_id"])
    facts = _git_inventory(ws, repository, candidate_revision)
    commit = ws.git_read(repository, ["cat-file", "commit", candidate["commit_id"]], e.OUTPUT_LIMIT)
    headers = commit.split(b"\n\n", 1)[0].splitlines()
    require([line[7:].decode() for line in headers if line.startswith(b"parent ")] == [revision["commit_id"]]
            and [line[5:].decode() for line in headers if line.startswith(b"tree ")] == [candidate["tree_id"]], "E_RELATION")
    require(all(facts.get(path) == value for path, value in source_facts.items()), "E_RELATION")
    additions = {path: value for path, value in facts.items() if path not in source_facts and value[1] != "tree"}
    require(additions == {row["path"]: ("100644", "blob", row["git_blob_oid"]) for row in expected}, "E_RELATION")
    expected_directories = {"/".join(path.split("/")[:index]) for path in files for index in range(1, len(path.split("/")))}
    require({path for path in facts if path not in source_facts and facts[path][1] == "tree"} == expected_directories - set(source_facts), "E_RELATION")
    for row in expected:
        raw = ws.git_read(repository, ["cat-file", "blob", row["git_blob_oid"]], len(files[row["path"]]) + 1)
        require(raw == files[row["path"]] and sha(raw) == row["sha256"], "E_RELATION")
    return candidate


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
        require(e._launch(ws.anchor, frame, ws.deadline) == 0, "E_RUNTIME")
        sudo.recheck()
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


def prepare(request_path: Path, bundle: Path, work: Path, output: Path, parent: dict):
    ws = _Workspace(request_path, bundle, work, output, parent)
    try:
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
            candidate["commit_id"], candidate["tree_id"], verification_files)
    finally:
        ws.close()


def main(argv):
    if len(argv) != 6 or argv[1] != "prepare":
        print("E_USAGE", file=sys.stderr)
        return 1
    print("E_RUNTIME", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
