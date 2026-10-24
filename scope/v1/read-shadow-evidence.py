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
DEADLINE = time.monotonic() + 300
_spec = importlib.util.spec_from_file_location("scope_shadow_consumer", SOURCE)
if _spec is None or _spec.loader is None or SOURCE.resolve() != SOURCE:
    raise SystemExit("E_RUNTIME")
c = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = c
_spec.loader.exec_module(c)


def require(value, code="E_RELATION"):
    c._require(value, code)


def parse(raw, limit=8 * c.DOCUMENT_LIMIT):
    return c._json(raw, limit, "E_RELATION")


def same(left, right):
    return c.canonical(left) == c.canonical(right)


def ref(raw):
    document = parse(raw)
    return {"schema_version": document["schema_version"], "kind": document["kind"],
            "id": document["id"], "sha256": c.digest(raw)}


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
        require(type(body["deadline"]) in {int, float} and time.monotonic() < body["deadline"] <= DEADLINE, "E_RUNTIME")
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
        self.modules = None
        self.coverage_configuration = None
        self.authentication_revision = None
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
            for relative in ("publisher/v1/_admission.py", "shadow/v1/write-shadow.py", "shadow/v1/enforced-reproduction.py",
                             "scope/v1/scope-policy.json", "config/construction-mode.json",
                             "core/v2/generation-registry.json"):
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
            self.modules = self.enforced.core_modules(self.package_sources["core/v2/generation-registry.json"].raw)
            for source in sorted(self.modules.glob("*.jq")):
                self.package_sources[str(source.relative_to(PACKAGE))] = self.hold(source, c.EXECUTABLE_LIMIT)
            for source in (self.modules.parent / "core-ingress.sh", self.modules.parent / "contracts.jq"):
                self.package_sources[str(source.relative_to(PACKAGE))] = self.hold(source, c.EXECUTABLE_LIMIT)
            for relative in ("scripts/core-contract.sh", "shadow/v1/write-materialization-input.jq",
                "shadow/v1/qualified-identity.jq", "shadow/v1/validate-incident.sh", "shadow/v1/incident-record.jq",
                "adapters/local-git-materializer/v1/protocol.jq", "enforcement/v1/check-sandbox-receipt.sh",
                "enforcement/v1/sandbox-receipt.jq", "control/v1/evaluate-bound-sandbox.sh",
                "control/v1/sandbox-bound.jq", "control/v1/validate.sh", "control/v1/policy-set.jq",
                "telemetry/v1/validate-trace-ledger.sh", "telemetry/v1/trace-ledger.jq",
                "maintenance/v1/incident-to-eval.sh", "maintenance/v1/incident-to-eval.jq",
                "maintenance/v1/bands.jq", "evals/v1/eval-catalog.json", "evals/v1/seed-set.json"):
                self.package_sources[relative] = self.hold(PACKAGE / relative, c.EXECUTABLE_LIMIT)
            self.jq = self.hold(Path(os.environ["YSTACK_SCOPE_JQ"]), c.EXECUTABLE_LIMIT)
            require(self.jq.sha256 == c.JQ_SHA256[sys.platform], "E_RUNTIME")
            self.bash = self.hold(Path("/bin/bash").resolve(), c.EXECUTABLE_LIMIT, hardlinks=True)
            self.git_binary = self.hold(Path("/usr/bin/git"), c.EXECUTABLE_LIMIT, hardlinks=True)
            self.git = c._ReadOnlyGit(str(git_root), self)
            self.owned.append(self.git)
            self.git.shape(self.scope_body["qualified_identity"]["target_revision"]["hash_algorithm"])
            self.recheck()
        except BaseException:
            self.close()
            raise

    def hold(self, path, limit, hardlinks=False):
        item = c._hold_bytes(str(path), limit, hardlinks=hardlinks)
        self.owned.append(item)
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
        helper = self.package_sources["publisher/v1/_admission.py"]
        require(module._ADMISSION_SHA256 == helper.sha256 and module._ADMISSION_SOURCE.raw == helper.raw
                and module.a.c is module.c and sys.modules.get("ystack_publisher_admission") is module.a
                and Path(module.a.__file__).absolute() == PACKAGE / "publisher/v1/_admission.py", "E_RUNTIME")
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
            min(30, self.deadline - time.monotonic()), self.environment())
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
            min(120, self.deadline - time.monotonic()), self.environment())
        self.recheck()
        return result

    def jq_check(self, relative, arguments, raw=b"", limit=c.DOCUMENT_LIMIT):
        source = self.package_sources[relative]
        argv = [self.jq.held.path, "-L", str(self.modules), *map(str, arguments), "-f", str(PACKAGE / relative)]
        self.recheck()
        self.record_command("scope-fixed-json-check", argv, self.jq.sha256, source.sha256)
        result = self.darwin._foreground(argv, raw, limit, 65536,
            min(30, self.deadline - time.monotonic()), self.environment())
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
        return self.anchor

    def release_stores(self):
        self.recheck()
        stores = [item for item in self.owned if isinstance(item, c._HeldStoreRead)]
        for item in stores:
            item.recheck()
        for item in stores:
            item.close()
            self.owned.remove(item)

    def close(self):
        owned = list(self.owned)
        first = None
        for item in reversed(owned):
            try:
                item.close()
                self.owned.remove(item)
            except BaseException as exc:
                if first is None:
                    first = exc
        if first is not None:
            raise first

    def fixed_bundle(self, held):
        facts = self._authenticate(held.files)
        held.recheck()
        return facts

    def _authenticate(self, files):
        anchor = self.anchor_for()
        fixed = {"accepted-identities.json": "accepted_set", "registry.json": "registry",
            "evaluator-driver.txt": "evaluator_driver", "evaluator-program.txt": "evaluator_program",
            "policy.json": "control_policy", "decision.json": "control_decision", "policy-set.json": "control_policy_set"}
        require(all(files[name] == anchor.installed[role][0] for name, role in fixed.items()))
        incident, record = parse(files["incident.json"]), parse(files["shadow-record.json"])
        body, revision = record["body"], incident["body"]["git_revision_ref"]
        require(same(revision, self.authentication_revision or self.scope_body["qualified_identity"]["target_revision"])
                and body["target_repository_id"] == self.scope_body["target_repository_id"])
        selected = [row for row in anchor.registry[1] if row["environment_id"] == body["environment"]["environment_id"]]
        accepted = [row for row in anchor.accepted[1] if row["environment_id"] == body["environment"]["environment_id"]]
        require(len(selected) == len(accepted) == 1)
        registry = selected[0]
        require(registry["proof_state"] == "native-qualified"
                and registry["target_repository_id"] == body["target_repository_id"]
                and registry["source_root_commit"] == (self.scope_body["coverage"]["coverage_base"]["commit_id"]
                    if "coverage" in self.scope_body else revision["commit_id"]))
        receipt = parse(files["sandbox-receipt.json"])
        for slot, value in receipt["body"]["identities"].items():
            require(set(value) == {"state", "sha256"} and value["state"] == "observed"
                    and value["sha256"] in accepted[0]["identities"][slot])
        require(set(receipt["body"]["identities"]) == c.IDENTITY_SLOTS)
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
        launch, expectation = parse(files["sandbox-request.json"]), parse(files["sandbox-expectation.json"])
        launch_body = launch["body"]
        subject = {"environment_id": anchor.config["environment_id"],
            "environment_entry_sha256": c.digest(c.canonical(registry)), "target_repository_id": body["target_repository_id"],
            "source": prep["source"], "candidate": {"preparation_record_sha256": c.digest(files["preparation-record.json"]),
                "manifest_sha256": c.digest(files["preparation-manifest.json"]), "commit_id": prep["candidate"]["commit_id"],
                "tree_id": prep["candidate"]["tree_id"]}, "incident_sha256": c.digest(files["incident.json"])}
        require(set(launch) == {"schema_version", "kind", "id", "body"}
                and type(launch["schema_version"]) is int and launch["schema_version"] == 1
                and launch["kind"] == "sandbox_launch_request" and c._id(launch["id"])
                and set(launch_body) == {"attempt", "control", "instruction_sha256", "nonce", "store_id", "subject"}
                and c._sha(launch_body["nonce"]))
        require(same(launch_body["subject"], subject)
                and same(launch_body["control"], self.enforced.control(anchor, evaluation))
                and launch_body["instruction_sha256"] == c.digest(instruction)
                and launch_body["store_id"] == anchor.config["store_id"]
                and same(launch_body["attempt"], {"attempt_id": launch["id"], "attempt_number": 1})
                and same(expectation, {"schema_version": 1, "kind": "sandbox_receipt_expectation", "id": launch["id"],
                    "body": {"attempt": launch_body["attempt"] | {"launch_request_sha256": c.digest(files["sandbox-request.json"])},
                        "control": launch_body["control"], "store_id": anchor.config["store_id"], "subject": subject}}))
        store = c._HeldStoreRead(anchor, launch["id"])
        self.owned.append(store)
        mapping = {"receipt.json": "sandbox-receipt.json", "payload/stdout": "payload-stdout.txt",
            "payload/stderr": "payload-stderr.txt", "payload/evidence-manifest.json": "evidence-manifest.json",
            "payload/evidence/0000": "file-digest-result.json"}
        require(set(store.snapshots) == set(mapping)
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
        return {"bundle_ref": ref(files["bundle.json"]), "receipt_ref": ref(files["sandbox-receipt.json"]),
            "check_ref": ref(checked), "fresh_origin_ref": ref(store.observation),
            "archived_origin_ref": ref(files["origin-observation.json"]),
            "registry_ref": ref(files["registry.json"]), "accepted_set_ref": ref(files["accepted-identities.json"]),
            "materialization_ref": {"sha256": c.digest(files["materialization-response.json"])},
            **({"scope_policy_ref": body["scope_policy_ref"]} if body["record_form"] == "withheld-write-policy.v1" else {})}

    def origin(self, document, snapshots, attempt_id, anchor):
        require(set(document) == {"schema_version", "kind", "id", "body"}
                and type(document["schema_version"]) is int and document["schema_version"] == 1
                and document["kind"] == "shadow_origin_observation" and document["id"] == attempt_id)
        body = document["body"]
        require(set(body) == {"store_id", "attempt_id", "entries", "result"}
                and body["store_id"] == anchor.config["store_id"] and body["attempt_id"] == attempt_id
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
            require(row["name"] in expected and row["uid"] == anchor.config["principal_uid"]
                    and row["gid"] == anchor.config["consumer_gid"]
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

    def record_refs(self, files, body, attempt, anchor):
        expected = {"state": "satisfied", "reason_id": "shadow.sandbox-satisfied",
            "launch_request_ref": ref(files["sandbox-request.json"]),
            "expectation_ref": ref(files["sandbox-expectation.json"]), "receipt_ref": ref(files["sandbox-receipt.json"]),
            "check_ref": ref(files["sandbox-check.json"]), "origin": {"state": "authenticated",
                "store_id": anchor.config["store_id"], "method": "controlled-storage.v1",
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

    def provenance(self, files, instruction, observation, attempt, write):
        document = parse(files["consumer-provenance.json"])
        keys = {"activation_state", "authority", "instruction_utf8", "instruction_sha256",
            "observation", "observation_sha256", "native_release", "commands", "helper_source_sha256",
            "helper_build_record_sha256", "helper_executable_sha256", "consumer_source_sha256", "python_sha256", "jq_sha256"}
        require(set(document) == {"schema_version", "kind", "id", "body"}
                and type(document["schema_version"]) is int and document["schema_version"] == 1
                and document["kind"] == "shadow_consumer_provenance" and document["id"] == attempt
                and type(document["body"]) is dict and set(document["body"]) == keys)
        body = document["body"]
        source = "shadow/v1/write-shadow.py" if write else "shadow/v1/enforced-reproduction.py"
        require(body["activation_state"] == "inactive" and body["authority"] == "none"
                and type(body["instruction_utf8"]) is str and body["instruction_utf8"].encode() == instruction
                and body["instruction_sha256"] == c.digest(instruction)
                and same(body["observation"], parse(observation)) and body["observation_sha256"] == c.digest(observation)
                and body["consumer_source_sha256"] == self.package_sources[source].sha256
                and body["python_sha256"] == self.python.sha256 and body["jq_sha256"] == self.jq.sha256
                and body["helper_source_sha256"] == c.HELPER_SOURCE_SHA256
                and all(c._sha(body[key]) for key in keys if key.endswith("sha256")))
        native = body["native_release"]
        hashes = {"source_sha256", "build_script_sha256", "build_record_sha256", "binary_locator_sha256",
                  "binary_sha256", "python_locator_sha256", "python_sha256", "dependency_record_sha256"}
        require(type(native) is dict and set(native) == hashes | {"context_version", "binary_size", "python_abi", "loader_mode"}
                and type(native["context_version"]) is int and native["context_version"] == 2
                and all(c._sha(native[key]) for key in hashes)
                and type(native["binary_size"]) is int and 0 < native["binary_size"] <= c.EXECUTABLE_LIMIT
                and native["loader_mode"] == "rtld-now-local.v1" and type(native["python_abi"]) is str
                and native["python_abi"] == sysconfig.get_config_var("SOABI")
                and 1 <= len(native["python_abi"]) <= 128
                and all(0x20 <= ord(char) <= 0x7e for char in native["python_abi"])
                and native["python_sha256"] == body["python_sha256"]
                and native["python_locator_sha256"] == c.digest(sys.executable.encode()))
        for key, relative in (("source_sha256", "shadow/v1/_cancel_release.c"),
                              ("build_script_sha256", "shadow/v1/build-cancel-release.sh")):
            held = self.hold(PACKAGE / relative, c.EXECUTABLE_LIMIT)
            require(native[key] == held.sha256)
        roles = {
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
        fixed = {"helper-version": (body["helper_executable_sha256"], body["helper_source_sha256"]),
            "jq-version": (self.jq.sha256, self.jq.sha256),
            "darwin-acl-uuid-resolution": (self.python.sha256, self.consumer.sha256),
            "darwin-group-membership": (self.python.sha256, self.consumer.sha256)}
        supervisor = next(item for item in self.anchor.held if item.path == c.ANCHOR + "/host-supervisor.py")
        sudo = self.enforced.fixed_sudo()
        self.owned.append(sudo)
        fixed["sandbox-launch-boundary"] = (sudo.sha256, c.digest(supervisor.read(c.EXECUTABLE_LIMIT, "E_STALE")))
        for role, relative in roles.items():
            component = self.hold(PACKAGE / relative, c.EXECUTABLE_LIMIT)
            executable = (self.git_binary.sha256 if role == "write-git-inspection" else
                self.python.sha256 if role.startswith("candidate-") else
                self.jq.sha256 if role in {"write-materialization-input", "materializer-input-validation",
                    "materializer-response-validation", "qualified-identity-validation"} else self.bash.sha256)
            fixed[role] = (executable, component.sha256)
        commands = body["commands"]
        require(type(commands) is list and 1 <= len(commands) <= 4096)
        for row in commands:
            require(type(row) is dict and set(row) == {"role", "argv_sha256", "executable_sha256", "component_sha256"}
                    and type(row["role"]) is str and row["role"] in fixed
                    and all(c._sha(row[key]) for key in ("argv_sha256", "executable_sha256", "component_sha256"))
                    and (row["executable_sha256"], row["component_sha256"]) == fixed[row["role"]])

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
        require(same(source, {"repository_id": body["target_repository_id"], "hash_algorithm": revision["hash_algorithm"],
            "commit_id": revision["commit_id"], "tree_id": source_tree}))
        require(candidate["hash_algorithm"] == revision["hash_algorithm"] and candidate["repository_kind"] == "bare"
                and candidate["parent_commit_id"] == revision["commit_id"])
        candidate_tree, parents = self.commit(candidate["commit_id"])
        require(candidate_tree == candidate["tree_id"])
        facts = self.git.inventory(dict(revision, commit_id=candidate["commit_id"]))
        manifest = parse(files["preparation-manifest.json"])
        entries = manifest["entries"]
        require(type(entries) is list and len(entries) <= 10000)
        require(set(manifest) == {"schema_version", "kind", "hash_algorithm", "entries",
            "file_count", "directory_count", "total_file_bytes"}
            and type(manifest["schema_version"]) is int and manifest["schema_version"] == 1
            and manifest["kind"] == "candidate_content_manifest" and manifest["hash_algorithm"] == "sha256"
            and all(type(manifest[key]) is int and manifest[key] >= 0
                    for key in ("file_count", "directory_count", "total_file_bytes")))
        manifest_facts = {}
        file_count = total_bytes = 0
        for row in entries:
            require(type(row) is dict and row["path"] not in manifest_facts)
            value = facts.get(row["path"])
            require(value is not None and row["kind"] == ("directory" if value[1] == "tree" else "file"))
            manifest_facts[row["path"]] = value
            if value[1] == "tree":
                require(set(row) == {"path", "kind", "git_mode", "mode"}
                        and row["git_mode"] == "040000" and row["mode"] == "0500")
            if value[1] == "blob":
                require(set(row) == {"path", "kind", "git_mode", "mode", "blob_oid", "size_bytes", "sha256"})
                file_count += 1
                require(type(row["size_bytes"]) is int and row["size_bytes"] >= 0)
                total_bytes += row["size_bytes"]
                require(value[0] in {"100644", "100755"} and type(row["size_bytes"]) is int and row["size_bytes"] >= 0
                        and row["git_mode"] == value[0] and row["blob_oid"] == value[2]
                        and row["mode"] == ("0400" if value[0] == "100644" else "0500"))
                raw = self.git.read(["cat-file", "blob", value[2]], min(16 * c.DOCUMENT_LIMIT, row["size_bytes"] + 1))
                require(len(raw) == row["size_bytes"] and c.digest(raw) == row["sha256"])
        require(manifest_facts == facts and manifest["file_count"] == file_count
                and manifest["directory_count"] == len(entries) - file_count
                and manifest["total_file_bytes"] == total_bytes)
        self.preparation(files, receipt, response)
        if body["record_form"] == "enforced-reproduction.v1":
            self.enforced.require_no_change(files["materialization-response.json"], incident)
            require(facts == source_facts and candidate["commit_id"] == revision["commit_id"])
            return
        require(parents == [revision["commit_id"]])
        self.write_relations(files, material_input, incident, body, facts, source_facts, candidate_tree)

    def preparation(self, files, receipt, response):
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
        for key, binary in (("python", self.python), ("git", self.git_binary), ("jq", self.jq)):
            identity = producer[key]
            require(type(identity) is dict and set(identity) == {"executable_sha256", "version"}
                and identity["executable_sha256"] == binary.sha256 and type(identity["version"]) is str
                and 1 <= len(identity["version"]) <= 128 and all(0x20 <= ord(char) <= 0x7e for char in identity["version"]))
        source = self.hold(PACKAGE / "preparation/v1/prepare-candidate.py", c.EXECUTABLE_LIMIT)
        require(producer["source_sha256"] == source.sha256
                and producer["protocol_sha256"] == self.package_sources["adapters/local-git-materializer/v1/protocol.jq"].sha256
                and producer["jq"]["version"] == "jq-1.6"
                and producer["python"]["version"] == sys.version.splitlines()[0]
                and producer["git"]["version"].startswith("git version ")
                and producer["unicode_version"] == unicodedata.unidata_version)
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
        write = body["write"]
        require(set(write) == {"bundle_ref", "scope_id", "workflow_id", "task_class", "write_set",
            "publisher_request", "admission", "publication", "post_write_verification"})
        require(write["scope_id"] == self.scope["id"]
                and write["workflow_id"] == self.scope_body["workflow_id"] == "workflow.shadow-evidence-commit"
                and write["task_class"] == self.scope_body["task_class"] == "task.commit-shadow-evidence")
        prefix = "ystack-evidence/" + incident["id"] + "/"
        names = set(c.SHADOW_EVIDENCE_NAMES) | {"bundle.json", "eval-seed.json", "README.md"}
        policy_form = body["record_form"] == "withheld-write-policy.v1"
        if policy_form:
            names.add("scope-policy.json")
            c.check_scope_policy_ref(body["scope_policy_ref"], files["scope-policy.json"])
        paths = sorted(prefix + name for name in names)
        rows = write["write_set"]
        require(type(rows) is list and [row.get("path") for row in rows] == paths)
        frozen_files = {}
        for row in rows:
            require(set(row) == {"path", "mode", "sha256", "git_blob_oid", "add_only"}
                    and row["mode"] == "100644" and row["add_only"] is True
                    and c._sha(row["sha256"]) and c._writer_oid(row["git_blob_oid"])
                    and facts.get(row["path"]) == ("100644", "blob", row["git_blob_oid"]))
            limit = 8 * c.DOCUMENT_LIMIT if row["path"].endswith("materialization-input.json") else 2 * c.DOCUMENT_LIMIT
            raw = self.git.read(["cat-file", "blob", row["git_blob_oid"]], limit + 1)
            require(len(raw) <= limit and c.digest(raw) == row["sha256"])
            frozen_files[row["path"]] = raw
        patch, expected_rows = c.evidence_patch(frozen_files, incident["body"]["git_revision_ref"]["hash_algorithm"], body["record_form"])
        require(same(rows, expected_rows))
        directories = {"/".join(path.split("/")[:index]) for path in paths for index in range(1, len(path.split("/")))}
        require(all(facts.get(path) == value or (path in directories and value[:2] == ("040000", "tree")
            and facts.get(path, ())[:2] == value[:2]) for path, value in source_facts.items()))
        require({path: value for path, value in facts.items() if path not in source_facts and value[1] != "tree"}
                == {row["path"]: ("100644", "blob", row["git_blob_oid"]) for row in rows})
        require({path for path, value in facts.items() if path not in source_facts and value[1] == "tree"}
                == directories - set(source_facts))
        policy_raw = files["scope-policy.json"] if policy_form else self.package_sources["scope/v1/scope-policy.json"].raw
        policy = parse(policy_raw)
        if policy_form:
            require(frozen_files[prefix + "scope-policy.json"] == policy_raw)
        marker_raw = self.package_sources["config/construction-mode.json"].raw
        require(len(marker_raw) <= 8 * c.DOCUMENT_LIMIT)
        try:
            marker = json.loads(marker_raw.decode("utf-8"), object_pairs_hook=c._unique_object)
            require(type(marker) is dict)
            c.canonical(marker)
        except (UnicodeError, ValueError, TypeError, RecursionError):
            raise c.Refusal("E_RELATION") from None
        require(all(c.write_path_ok(path, policy, marker) and self.allowed(path) for path in paths))
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
        require(same(write["bundle_ref"], self.writer._bundle_ref(frozen["bundle.json"]))
                and sum(map(len, frozen_files.values())) <= 48 * c.DOCUMENT_LIMIT
                and parse(frozen["shadow-record.json"])["body"]["record_form"] == "enforced-reproduction.v1")
        self._authenticate(frozen)
        seed_dir = self.fresh_runtime_directory("seed-" + str(len(self.inputs)))
        seed_incident = self.capture("seed-incident-" + str(len(self.inputs)) + ".json", frozen["incident.json"])
        seed_record = self.capture("seed-record-" + str(len(self.inputs)) + ".json", frozen["shadow-record.json"])
        seed = self.component("maintenance/v1/incident-to-eval.sh", ["convert", seed_incident, seed_record, seed_dir])
        require(seed == frozen_files[prefix + "eval-seed.json"])
        require(self.rebuild_input(frozen, paths, patch, files["claim.json"], parse(files["sandbox-request.json"])["id"], body["record_form"])
                == files["materialization-input.json"])
        publisher, publisher_body = self.writer._publisher(incident, tree)
        require(same(write["publisher_request"], publisher) and files["publisher-body.txt"] == publisher_body
                and same(write["publication"], {"state": "withheld", "reason_id": "shadow.write-not-published"})
                and same(write["admission"], {"state": "checked", "effect": "none",
                    "request_sha256": c.digest(c.canonical(publisher)), "write_set_sha256": c.digest(c.canonical(rows))})
                and same(write["post_write_verification"], {"target_revision": incident["body"]["git_revision_ref"],
                    "candidate_tree_id": tree, "write_set": rows}))

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
        self.commands[-1].update(request_sha256=c.digest(request_raw), python_sha256=python_sha)
        if self.store_session is not None:
            self.gate_commands[-1].update(request_sha256=c.digest(request_raw), python_sha256=python_sha)

    def coverage_identity(self, files):
        record = parse(files["shadow-record.json"])["body"]
        q = record["qualified_identity"]
        profile = parse(files["materialization-input.json"])["resolved_profile"]["content"]["body"]
        environment = record["environment"]["environment_id"]
        registry = [row for row in self.anchor.registry[1] if row["environment_id"] == environment]
        require(len(registry) == 1)
        return {"scope_id": self.scope["id"], "workflow_id": self.scope_body["workflow_id"],
            "task_class": self.scope_body["task_class"],
            **{key: q[key] for key in ("model_request", "adapter_config_refs", "prompt_refs", "skill_refs", "verification_instructions_ref")},
            "resolved_profile": {key: profile[key] for key in ("profile_ref", "profile_source", "selection_ref", "bindings")},
            "environment_id": environment, "registry_entry": registry[0],
            "control_policy_set_ref": ref(files["policy-set.json"]),
            "sandbox_policy_sha256": c.digest(files["policy.json"]),
            "scope_policy_sha256": c.digest(files["scope-policy.json"]),
            "coverage_base": self.scope_body["coverage"]["coverage_base"], "coverage_rule_version": "scope-coverage.v1"}

    def coverage_interval(self, observation, retained_files):
        n = self.coverage_configuration.normalizer
        base = self.scope_body["coverage"]["coverage_base"]
        revision = self.scope_body["qualified_identity"]["target_revision"]
        head = self.hold(self.git_root / "HEAD", c.DOCUMENT_LIMIT).raw
        require(head.startswith(b"ref: refs/heads/") and head.endswith(b"\n"))
        branch_name = head[len(b"ref: refs/heads/"):-1].decode("utf-8")
        require(branch_name == observation["default_branch"]["name"])
        named_ref = self.git_root / "refs/heads" / branch_name
        if os.path.lexists(named_ref):
            require(self.hold(named_ref, c.DOCUMENT_LIMIT).raw == (revision["commit_id"] + "\n").encode())
        else:
            packed = self.hold(self.git_root / "packed-refs", c.DOCUMENT_LIMIT).raw
            matches = [line for line in packed.splitlines() if not line.startswith((b"#", b"^"))
                       and line.endswith(b" refs/heads/" + branch_name.encode())]
            require(matches == [(revision["commit_id"] + " refs/heads/" + branch_name).encode()])
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
        require(rows == [dict(row, index=index) for index, row in enumerate(commits)])
        require(observation["repository"]["repository_id"] == revision["repository_id"]
                and observation["branch_snapshots"]["current"]["commit_id"] == revision["commit_id"]
                and observation["branch_snapshots"]["baseline"]["commit_id"] == base["commit_id"])
        pulls = observation["publisher_pull_requests"]
        used = set()
        previous = self.git.inventory(base)
        for row in commits[1:]:
            facts = self.git.inventory(dict(revision, commit_id=row["commit_id"]))
            changed = sorted(path for path in set(previous) | set(facts)
                if previous.get(path) != facts.get(path) and
                (previous.get(path, (None, None))[1] == "blob" or facts.get(path, (None, None))[1] == "blob"))
            require(not any(path == ".ystack" or path.startswith(".ystack/") or path == ".github/workflows"
                            or path.startswith(".github/workflows/") for path in changed))
            evidence = [path for path in changed if path == "ystack-evidence" or path.startswith("ystack-evidence/")]
            if evidence:
                require(changed == evidence and all(path not in previous and facts.get(path, ())[:2] == ("100644", "blob") for path in evidence))
                candidates = [pull for pull in pulls if pull["merge_commit_id"] == row["commit_id"]]
                require(len(candidates) == 1)
                pull = candidates[0]
                require(pull["publisher_identity_ref"] == self.coverage_configuration.config["publisher_identity_ref"]
                        and pull["scope_id"] == self.scope["id"] and pull["changed_paths"] == evidence
                        and pull["merged"] is True)
                matching = []
                for files in retained_files:
                    body = parse(files["shadow-record.json"])["body"]
                    publisher = body["write"]["publisher_request"]
                    p = publisher["body"]
                    if (c.digest(c.canonical(publisher)) == pull["publisher_request_sha256"]
                            and p["branch"] == pull["source_branch"] and p["target_repository_id"] == revision["repository_id"]
                            and p["base_revision"]["commit_id"] == pull["base_commit_id"]
                            and p["candidate_tree_id"] == self.commit(pull["head_commit_id"])[0]
                            and [item["path"] for item in body["write"]["write_set"]] == evidence):
                        matching.append(files)
                require(len(matching) == 1)
                head_tree, head_parents = self.commit(pull["head_commit_id"])
                require(head_parents == [pull["base_commit_id"]])
                head_facts = self.git.inventory(dict(revision, commit_id=pull["head_commit_id"]))
                base_facts = self.git.inventory(dict(revision, commit_id=pull["base_commit_id"]))
                head_changes = sorted(path for path in set(base_facts) | set(head_facts)
                    if base_facts.get(path) != head_facts.get(path) and
                    (base_facts.get(path, (None, None))[1] == "blob" or head_facts.get(path, (None, None))[1] == "blob"))
                require(head_changes == evidence and all(path not in base_facts and head_facts[path] == facts[path] for path in evidence))
                for item in parse(matching[0]["shadow-record.json"])["body"]["write"]["write_set"]:
                    raw = self.git.read(["cat-file", "blob", facts[item["path"]][2]], 8 * c.DOCUMENT_LIMIT)
                    require(facts[item["path"]] == (item["mode"], "blob", item["git_blob_oid"])
                            and c.digest(raw) == item["sha256"] and item["add_only"] is True)
                used.add(pull["node_id"])
            previous = facts
        require(used == {pull["node_id"] for pull in pulls})
        return {"sha256": c.digest(c.canonical(rows)), "commit_count": len(rows)}

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

    def source_coverage(self, qualifying, current, row_groups):
        missing = {"state": "stale"}
        required = self.scope_body["required_shadow_environments"]
        if not (set(qualifying) == set(current) == set(required)
                and all(row["authentication"]["state"] == "authenticated" for rows in row_groups for row in rows if row["claimed"])):
            return missing
        anchor = self.anchor_for()
        configuration = c.load_coverage_configuration(anchor)
        if configuration is None:
            require(self.store_session is None, "E_RELATION")
            return missing
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
        nonce = getattr(self, "_coverage_nonce", None) or os.urandom(32).hex()
        attempt = "coverage." + nonce
        def hashes(name):
            return [{"environment_id": environment, "sha256": c.digest(c.canonical(parse(files["shadow-record.json"])["body"]["write"][name]))}
                    for environment, files in sorted(current.items())]
        git_observation = {"base": self.scope_body["coverage"]["coverage_base"], "current": identity["target_revision"],
            "base_tree": self.commit(self.scope_body["coverage"]["coverage_base"]["commit_id"])[0],
            "current_tree": self.commit(identity["target_revision"]["commit_id"])[0], "config_sha256": c.digest(self.git.config)}
        body = {"attempt_id": attempt, "nonce": nonce, "repository_id": self.scope_body["target_repository_id"],
            "coverage_base": self.scope_body["coverage"]["coverage_base"], "evaluated_revision": identity["target_revision"],
            "coverage_rule_version": "scope-coverage.v1", "documents": documents,
            "qualifying_shadow_record_refs": sorted(self.scope_body["coverage"]["qualifying_shadow_record_refs"], key=c.canonical),
            "current_shadow_record_refs": sorted(self.scope_body["shadow_evidence_refs"], key=c.canonical),
            "resolved_profile_ref": identity["resolved_profile_ref"], "stage_request_ref": identity["stage_request_ref"],
            "stage_result_ref": duty["body"]["stage"]["result_ref"],
            "materialization_refs": [{"environment_id": environment, "sha256": c.digest(files["materialization-response.json"])}
                                      for environment, files in sorted(current.items())],
            "publisher_request_refs": hashes("publisher_request"), "post_check_refs": hashes("post_write_verification"),
            "qualifying_receipt_refs": sorted([ref(files["sandbox-receipt.json"]) for files in qualifying.values()], key=c.canonical),
            "git_observation_sha256": c.digest(c.canonical(git_observation)),
            "source_package_ref": n.doc_ref(configuration.package_raw), "source_accepted_set_ref": n.doc_ref(configuration.accepted_raw)}
        if self.store_session is not None:
            body.update(initial_origin_refs=self.store_session.coverage_origins(), gate_call_ref=self.store_session.gate_call_ref)
        request_raw = c.canonical({"schema_version": 1, "kind": "coverage_source_request", "id": attempt, "body": body})
        n.request(request_raw)
        if getattr(self, "_coverage_prepare_only", False):
            return request_raw
        expectation = {key: body[key] for key in ("attempt_id", "nonce", "coverage_base", "evaluated_revision",
            "stage_request_ref", "resolved_profile_ref", "stage_result_ref", "source_package_ref", "source_accepted_set_ref")}
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
                output_rows.append(row)
        require(named <= allowed_directories)
        for _role, refs, _revision, output_rows in groups:
            for reference in refs:
                require(sum(reference["id"] == row["record_ref"]["id"]
                            and reference["sha256"] == row["record_ref"]["sha256"] for row in output_rows) == 1)
        self.recheck()
        return rows, qualifying_rows, role_files

    def evaluate(self):
        rows, qualifying_rows, role_files = self.authenticate_bundles()
        workflow = self.scope_body["workflow_id"] == "workflow.shadow-evidence-commit"
        identity = self.scope_body["qualified_identity"]
        self.authenticate_gate_kill()
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
        self.recheck()
        result = {"schema_version": 1, "kind": "scope_shadow_evidence_observation", "id": self.scope["id"],
            "body": {"scope_ref": ref(self.scope_raw), "shadow_set_ref": ref(self.set_raw),
                "rows": sorted(rows, key=lambda row: row["record_ref"]["sha256"]),
                "git": {"repository_kind": "bare", "hash_algorithm": identity["target_revision"]["hash_algorithm"],
                    "config_sha256": c.digest(self.git.config)}, "commands": self.commands,
                **({"coverage": coverage_result} if workflow else {})}}
        return c.canonical(result)


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
        raise InterruptedError("scope reader cancelled")
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
