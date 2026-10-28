#!/usr/bin/env python3
"""Generate inactive gate observations from one authenticated materialization."""
from __future__ import annotations
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import stat
import sys
import time

_entry_clock = time.monotonic()
ENTRY_DEADLINE = _entry_clock + 300
PACKAGE = Path(__file__).absolute().parents[2]
_spec = importlib.util.spec_from_file_location("gate_evidence_reader", PACKAGE / "scope/v1/read-shadow-evidence.py")
if _spec is None or _spec.loader is None:
    raise SystemExit("E_RUNTIME")
r = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = r
_spec.loader.exec_module(r)
c = r.c
c._clock_value('scope/v1/generate-gate-evidence.py:15:0', _entry_clock, 'monotonic')
require, parse, ref = r.require, r.parse, r.ref


def envelope(kind, identity, body):
    return {"schema_version": 1, "kind": kind, "id": identity, "body": body}


def generation_request(raw):
    value = parse(raw, c.DOCUMENT_LIMIT)
    require(set(value) == {"schema_version", "kind", "id", "body"}
            and type(value["schema_version"]) is int and value["schema_version"] == 1
            and value["kind"] == "scope_gate_generation_request" and c._id(value["id"])
            and type(value["body"]) is dict and set(value["body"]) == {"scope_basis", "risk_claim"})
    pending = [(value, 0)]
    while pending:
        item, depth = pending.pop()
        require(depth <= 64, "E_LIMIT")
        if isinstance(item, dict):
            pending.extend((child, depth + 1) for child in item.values())
        elif isinstance(item, list):
            pending.extend((child, depth + 1) for child in item)
    basis, claim = value["body"]["scope_basis"], value["body"]["risk_claim"]
    require(type(basis) is dict and type(basis.get("body")) is dict
            and "gate_evidence_refs" not in basis["body"] and type(claim) is dict)
    require(len(c.canonical(basis)) <= c.DOCUMENT_LIMIT and len(c.canonical(claim)) <= c.DOCUMENT_LIMIT, "E_LIMIT")
    return value


def project_register(register_raw, basis, stage_request, result, duty_raw, active):
    n = _normalizer()
    register = n.kill_register(register_raw)
    require(active is True, "E_RUNTIME")
    body = register["body"]
    request_body = stage_request["body"]
    scope = {"repository_id": request_body["target_repository_id"], "workflow_id": request_body["workflow_id"],
             "stage_id": request_body["stage_id"], "attempt_id": result["id"]}
    require(scope["repository_id"] == basis["body"]["target_repository_id"]
            and all(c._id(value) for value in scope.values()))
    entries = []
    for kind in ("global", "repository", "workflow"):
        identity = "*" if kind == "global" else scope[kind + "_id"]
        selected = [row for row in body["entries"] if row["scope_kind"] == kind and row["scope_id"] == identity]
        require(len(selected) == 1)
        entries.append(selected[0])
    entries.extend({"scope_kind": kind, "scope_id": scope[kind + "_id"], "state": "cleared"} for kind in ("stage", "attempt"))
    identity = "state." + c.digest(register_raw + c.canonical(scope))[:48]
    state_raw = c.canonical(envelope("kill_switch_state", identity, {"activation_state": "inactive", "attempt_id": result["id"],
        "authority_epoch": body["authority_epoch"], "revision": body["revision"], "entries": entries, "register_ref": ref(register_raw)}))
    attempt_raw = c.canonical(envelope("kill_switch_attempt", result["id"], {"activation_state": "inactive",
        "authority_epoch": body["authority_epoch"], "duty_evaluation_ref": ref(duty_raw), "scope": scope,
        "expected_state": {"id": identity, "revision": body["revision"], "sha256": c.digest(state_raw)}}))
    return state_raw, attempt_raw


def _normalizer():
    spec = importlib.util.spec_from_file_location("gate_register_normalizer", PACKAGE / "sandbox/v1/coverage-source.py")
    require(spec is not None and spec.loader is not None, "E_RUNTIME")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _kill_request_body_values(basis, config, call_id, nonce, role_files, initial_origin_refs,
        git_config_raw, package_raw, accepted_raw):
    body = {"operation": "kill-register-read.v1", "version": 1, "call_id": call_id, "nonce": nonce,
        "target_repository_id": basis["body"]["target_repository_id"],
        **{key: config[key] for key in ("control_repository", "default_branch", "bootstrap")},
        "bundle_refs": sorted({c.canonical(ref(files["bundle.json"])): ref(files["bundle.json"])
            for files in role_files["current"].values()}.values(), key=c.canonical),
        "initial_origin_refs": initial_origin_refs,
        "git_observation_sha256": c.digest(c.canonical({"revision": basis["body"]["qualified_identity"]["target_revision"],
            "config_sha256": c.digest(git_config_raw)})),
        "source_package_ref": ref(package_raw), "source_accepted_set_ref": ref(accepted_raw)}
    return body


def _scope_values(basis, duty, risk, kill):
    scope = json.loads(c.canonical(basis))
    scope["body"]["gate_evidence_refs"] = {"duty_separation_evaluation_ref": ref(duty),
        "risk_gate_evaluation_ref": ref(risk), "kill_switch_evaluation_ref": ref(kill)}
    require(c.canonical({**scope, "body": {key: value for key, value in scope["body"].items() if key != "gate_evidence_refs"}})
            == c.canonical(basis))
    return c.canonical(scope)


def _origins_values(observations):
    rows = {}
    for observation, snapshots in observations:
        rows[c.digest(observation)] = {"observation": parse(observation),
            "receipt_sha256": c.digest(snapshots["receipt.json"]),
            "payload": [{"name": name, "size_bytes": len(raw), "sha256": c.digest(raw)}
                for name, raw in sorted(snapshots.items()) if name not in {"receipt.json", "capture.json", "sandbox-export.bin"}]}
    return [rows[key] for key in sorted(rows)]


def _manifest_values(identity, rows, initial_origins, final_origins, kill_request_raw, coverage_request_raw, work=None):
    if work is not None:
        work["gate_manifest_parse_unknown"] = True
        work["gate_manifest_parse_attempt_bytes"] = len(kill_request_raw) + (len(coverage_request_raw) if coverage_request_raw is not None else 0)
    value = envelope("scope_gate_generation_manifest", identity,
        {"activation_state": "inactive", "authority": "none", "enabled": False, "files": rows,
         "initial_origin_refs": initial_origins, "final_origin_refs": final_origins,
         "source_initial_origin_refs": {"kill": parse(kill_request_raw)["body"]["initial_origin_refs"],
             "coverage": parse(coverage_request_raw)["body"]["initial_origin_refs"] if coverage_request_raw else []}})
    if work is None:
        manifest = c.canonical(value)
    else:
        parsed_bytes = len(kill_request_raw) + (len(coverage_request_raw) if coverage_request_raw is not None else 0)
        work["read_bytes"] += parsed_bytes
        work.setdefault("seed_processing", {})["R"] = work.get("seed_processing", {}).get("R", 0) + parsed_bytes
        c._capture_account(work, "M", "read_bytes", parsed_bytes)
        work["gate_manifest_parse_unknown"] = False
        work["gate_manifest_encode_unknown"] = True
        manifest = c._private_capture_observations(value, work, work)
        work["gate_manifest_encode_unknown"] = False
    require(len(manifest) <= c.DOCUMENT_LIMIT, "E_LIMIT")
    return manifest


def _completion_values(identity, manifest, work=None):
    renderer, constructor = c.canonical, envelope
    if work is not None:work["completion_hash_unknown"] = True
    value = constructor("scope_gate_generation_complete", identity,
        {"manifest_sha256": c.digest(manifest), "activation_state": "inactive", "authority": "none", "enabled": False})
    if work is None:return renderer(value)
    work.setdefault("seed_processing", {})["H"] = work.get("seed_processing", {}).get("H", 0) + len(manifest)
    work["completion_hash_unknown"] = False
    work["completion_encode_unknown"] = True
    before, failure, raw = work["read_bytes"], None, None
    try:raw = c._private_capture_observations(value, work, work)
    except BaseException as error:failure = error
    finally:
        processed = work["read_bytes"] - before
        try:
            work["seed_processing"]["C"] = work["seed_processing"].get("C", 0) + processed
            c._capture_account(work, "M", "read_bytes", processed)
        except BaseException as error:
            if failure is None:failure = error
            else:
                previous = failure
                first_cancel = getattr(failure, "_scope_signal_cancel", False) or isinstance(failure, KeyboardInterrupt)
                next_cancel = getattr(error, "_scope_signal_cancel", False) or isinstance(error, KeyboardInterrupt)
                if next_cancel and not first_cancel:failure = error
                try:c._capture_observation_error(work, "M", "completion-secondary", error)
                except BaseException as reporting:
                    first_cancel = getattr(failure, "_scope_signal_cancel", False) or isinstance(failure, KeyboardInterrupt)
                    next_cancel = getattr(reporting, "_scope_signal_cancel", False) or isinstance(reporting, KeyboardInterrupt)
                    if next_cancel and not first_cancel:failure = reporting
                if failure is not error:failure.__cause__ = error
                elif previous is not error:failure.__cause__ = previous
    if failure is not None:raise failure
    c._capture_account(work, "M", "logical_bytes", len(raw))
    c._capture_account(work, "M", "occurrences", 1)
    work["completion_encode_unknown"] = False
    return raw


def _stable_binding(binding):
    require(set(binding) == {"store_id", "attempt_id", "ancestors", "entries", "snapshots", "origin_ref"}, "E_RUNTIME")
    return {key: value for key, value in binding.items() if key != "origin_ref"}


class _GateStoreSession:
    """One private owner records every local and remote store acquisition."""
    is_inner = False

    def __init__(self, call_id, binding, deadline):
        self.call_id, self.binding, self.deadline = call_id, binding, deadline
        self.phase = "P0"
        self.local, self.remote, self.frozen = {}, {}, {}
        self.initial_origin_refs, self.final_origins = [], []
        self.kill_request_raw = self.coverage_request_raw = self.coverage_expectation_raw = None
        self.gate_call_ref = None
        self.reader = self.kill_configuration = self.kill_source = self.generator = None
        self.coverage_configuration = self.coverage_source = None
        self.role_files = None
        self.wire = self.child_socket = None
        self.closed = self.initialized = self.owner_confirmed = False
        self.remote_serial = 0

    def _p_handoff_side(self, phase, value):
        handoff = getattr(self, "p_handoff", None)
        if handoff is None:
            return
        try:
            if phase == "INIT":
                self.wire.recording_work = handoff.work
                value["p_handoff"] = {"version": 1}
            elif phase in {"C_REQUEST", "FINAL_OWNER"}:
                handoff.stage(value, phase)
            elif phase in {"C_RELEASED", "CLOSED"}:
                handoff.settle(value, phase)
            else:
                require(phase == "COMPLETE", "E_RUNTIME")
                handoff.complete()
        except BaseException as error:
            first = error
            try:
                handoff.fail(error, phase)
            except BaseException as later:
                first = c._c3_first(first, later)
                try:
                    errors = getattr(self, "p_handoff_errors", None)
                    if errors is None:
                        errors = []
                        self.p_handoff_errors = errors
                    errors.append((phase, error, later))
                except BaseException as reported:
                    first = c._c3_first(first, reported)
                    try:self.p_handoff_error_unknown = (getattr(self, "p_handoff_error_unknown", None), error, later, reported)
                    except BaseException as last:first = c._c3_first(first, last)
                try:handoff.unusable = True
                except BaseException as reported:
                    first = c._c3_first(first, reported)
                    try:self.p_handoff_error_unknown = (getattr(self, "p_handoff_error_unknown", None), error, later, reported)
                    except BaseException as last:first = c._c3_first(first, last)
            if isinstance(first, KeyboardInterrupt) or getattr(first, "_scope_signal_cancel", False):
                raise first

    def remember(self, binding):
        key = (binding["store_id"], binding["attempt_id"])
        stable = _stable_binding(binding)
        if key in self.frozen:
            require(r.same(stable, self.frozen[key]), "E_STALE")
        else:
            require(len(self.frozen) < 128, "E_LIMIT")
            self.frozen[key] = stable
        return key

    def acquire(self, item):
        require(self.phase in {"P0", "K_DONE", "C_REQUEST", "C_DONE", "FINAL_OWNER"}, "E_RUNTIME")
        binding = c._gate_store_binding(item)
        key = self.remember(binding)
        require(id(item) not in self.local, "E_RUNTIME")
        self.local[id(item)] = (item, key, binding)

    def release(self, item):
        require(id(item) in self.local, "E_RUNTIME")
        del self.local[id(item)]

    def origins(self):
        result = {}
        for _item, key, binding in self.local.values():
            require(key not in result or result[key] == binding["origin_ref"], "E_STALE")
            result[key] = binding["origin_ref"]
        return sorted(result.values(), key=c.canonical)

    def coverage_origins(self):
        return self.origins()

    def release_local(self):
        self._release_local_close_phase()
        self._release_local_check_phase()

    def _release_local_close_phase(self):
        self.reader.release_stores()

    def _release_local_check_phase(self):
        require(not self.local, "E_RUNTIME")

    def authenticate_core(self, current_only=False):
        rows, qualifying_rows, files = self.reader.authenticate_bundles(current_only)
        required = set(self.reader.scope_body["required_shadow_environments"])
        require(set(files["current"]) == required and all(row["authentication"]["state"] == "authenticated"
            for row in rows if row["claimed"]), "E_RELATION")
        if not current_only and "coverage" in self.reader.scope_body:
            require(set(files["qualifying"]) == required and all(row["authentication"]["state"] == "authenticated"
                for row in qualifying_rows if row["claimed"]), "E_RELATION")
        self.role_files = files
        return rows, qualifying_rows, files

    def bind_kill(self):
        source = c._HeldCoverageRead(self.reader.anchor_for(), self.kill_configuration, self.kill_request_raw)
        self.reader.owned.append(source)
        self.kill_source = source
        return source

    def start_scope(self):
        require(self.phase == "K_DONE" and self.local and not self.remote, "E_RUNTIME")
        parent, self.child_socket = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        self.wire = c._GateWire(parent, self.deadline - 10, self.call_id, os.urandom(32).hex(), self.binding)
        body = {"deadline": self.deadline, "gate_call_ref": self.gate_call_ref,
            "initial_origin_refs": self.origins(), "kill_request": parse(self.kill_request_raw)}
        self._p_handoff_side("INIT", body)
        self.wire.send("INIT", body)

    def pump(self):
        phase, body = self.wire.receive()
        side = None
        if getattr(self, "p_handoff", None) is not None and phase in {"C_REQUEST", "C_RELEASED", "FINAL_OWNER", "CLOSED"}:
            side = body.pop("p_handoff", None)
        if phase == "INIT_ACK":
            require(self.phase == "K_DONE" and body == {} and not self.initialized, "E_RUNTIME")
            self.initialized = True
            return
        require(self.initialized, "E_RUNTIME")
        if phase == "ACQUIRE":
            require(set(body) == {"acquisition", "binding"} and self.phase in {"K_DONE", "C_DONE", "FINAL_OWNER"}, "E_RUNTIME")
            identity = body["acquisition"]
            require(identity == "inner." + str(self.remote_serial + 1) and self.remote_serial < 4096
                    and not self.owner_confirmed, "E_RUNTIME")
            self.remote_serial += 1
            self.remember(body["binding"])
            self.remote[identity] = body["binding"]
        elif phase == "RELEASE":
            require(set(body) == {"acquisition"} and body["acquisition"] in self.remote
                    and (self.phase == "C_REQUEST" or (self.phase == "FINAL_OWNER" and self.owner_confirmed)), "E_RUNTIME")
            del self.remote[body["acquisition"]]
        elif phase == "C_REQUEST":
            require(self.phase == "K_DONE" and set(body) == {"request", "expectation", "acquisitions"}
                    and body["acquisitions"] == sorted(self.remote), "E_RUNTIME")
            self.phase = "C_REQUEST"
            rows, qualifying_rows, files = self.authenticate_core()
            incoming = c.canonical(body["request"])
            nonce = parse(incoming)["body"]["nonce"]
            self.reader._coverage_nonce = nonce
            self.reader._coverage_prepare_only = True
            try:
                expected = self.reader.source_coverage(files["qualifying"], files["current"], [qualifying_rows, rows])
            finally:
                self.reader._coverage_prepare_only = False
                self.reader._coverage_nonce = None
            require(type(expected) is bytes and incoming == expected, "E_RELATION")
            self.coverage_request_raw = incoming
            wanted = {key: parse(incoming)["body"][key] for key in ("attempt_id", "nonce", "coverage_base", "evaluated_revision",
                "stage_request_ref", "resolved_profile_ref", "stage_result_ref", "source_package_ref", "source_accepted_set_ref",
                "initial_origin_refs", "gate_call_ref")}
            wanted.update(request_sha256=c.digest(incoming), scope_ref=parse(incoming)["body"]["documents"]["scope"])
            require(r.same(body["expectation"], wanted), "E_RELATION")
            self.coverage_expectation_raw = c.canonical(envelope("coverage_source_expectation", parse(incoming)["id"], wanted))
            self.generator.put("coverage-request", incoming)
            self.generator.put("coverage-expectation", self.coverage_expectation_raw)
            self.coverage_configuration = self.reader.coverage_configuration
            self.reader.recheck()
            self._p_handoff_side(phase, side)
            self.release_local()
        elif phase == "C_RELEASED":
            require(self.phase == "C_REQUEST" and body == {} and not self.local and not self.remote, "E_RUNTIME")
            self.phase = "C_DONE"
            self._p_handoff_side(phase, side)
        elif phase == "C_DONE":
            require(self.phase == "C_DONE" and set(body) == {"acquisitions"}
                    and body["acquisitions"] == sorted(self.remote) and self.remote, "E_RUNTIME")
            self.authenticate_core()
            self.bind_kill()
            source = c._HeldCoverageRead(self.reader.anchor_for(), self.coverage_configuration, self.coverage_request_raw)
            self.reader.owned.append(source)
            self.coverage_source = source
            require(set(key for _item, key, _binding in self.local.values()) == set(self.frozen), "E_RELATION")
            self.reader.recheck()
            self.phase = "FINAL_OWNER"
        elif phase == "FINAL_OWNER":
            require(not self.owner_confirmed, "E_RUNTIME")
            require(set(body) == {"acquisitions"} and body["acquisitions"] == sorted(self.remote), "E_RUNTIME")
            if "coverage" in self.reader.scope_body:
                require(self.phase == "FINAL_OWNER" and self.coverage_source is not None, "E_RUNTIME")
            else:
                require(self.phase == "K_DONE" and self.coverage_request_raw is None, "E_RUNTIME")
                self.phase = "FINAL_OWNER"
            require(self.local and self.remote and {tuple((binding["store_id"], binding["attempt_id"])) for binding in self.remote.values()}
                    == {key for _item, key, _binding in self.local.values()}, "E_RUNTIME")
            self.reader.recheck()
            self.final_origins = self.origins()
            self.owner_confirmed = True
            self._p_handoff_side(phase, side)
        elif phase == "CLOSED":
            require(self.phase == "FINAL_OWNER" and self.owner_confirmed and not self.remote and body == {}, "E_RUNTIME")
            self.reader.recheck()
            self.closed = True
            self._p_handoff_side(phase, side)
        else:
            require(False, "E_RUNTIME")
        self.wire.send(phase + "_ACK", {})

    def complete(self):
        require(self.closed and self.phase == "FINAL_OWNER" and not self.remote and self.local, "E_RUNTIME")
        self.reader.recheck()
        require(self.final_origins == self.origins(), "E_STALE")
        self._p_handoff_side("COMPLETE", None)
        self.phase = "COMPLETE"

    def close(self):
        for sock in (self.child_socket, self.wire.sock if self.wire is not None else None):
            if sock is not None:
                sock.close()


class _Generator:
    capture_output_unusable = True

    def __init__(self, arguments):
        require(len(arguments) == 8 and arguments[0] == "generate", "E_USAGE")
        self.deadline = ENTRY_DEADLINE
        self.held, self.outputs = [], {}
        self._init_output_capture()
        self.reader = self.session = None
        self.active = True
        self.created = False
        self.paths = [Path(value) for value in arguments[1:]]
        for path in self.paths:
            require(path.is_absolute() and path.resolve() == path, "E_RELATION")
        request, shadow, dashboard, marker, bundle, git, self.output = self.paths
        jq = shutil.which("jq")
        require(jq is not None and os.path.realpath(jq) == jq, "E_DEPENDENCY")
        os.environ.clear()
        os.environ.update(PATH="/usr/bin:/bin", LC_ALL="C", LANG="C", YSTACK_SCOPE_JQ=jq)
        for left_index, left in enumerate(self.paths + [PACKAGE]):
            for right in (self.paths + [PACKAGE])[left_index + 1:]:
                require(left != right and left not in right.parents and right not in left.parents)
        require(not os.path.lexists(self.output), "E_RELATION")
        parent = c._open_held(str(self.output.parent), True,
            lambda _fd, state, ancestor: ancestor or state.st_uid == os.getuid(), "E_RELATION")
        self.held.append(parent)
        os.mkdir(self.output, 0o700)
        self.created = True
        os.fsync(parent.fd)
        # The parent's child inventory changed before it becomes a frozen input.
        self.held.remove(parent); parent.close()
        self.private = self.output / "private"
        for name in ("private", "objects", "completion", "manifests"):
            (self.output / name).mkdir(mode=0o700)
        names = ("request", "basis", "claim", "shadow-set", "dashboard", "marker", "stage-request", "resolved-profile", "stage-result",
            "policy-set", "state", "attempt", "duty", "risk", "kill", "scope", "scope-evaluation", "kill-request", "kill-expectation",
            "runtime", "initial-origins", "final-origins", "commands", "kill-evidence", "coverage-evidence",
            "register", "coverage-request", "coverage-expectation", "kill-configuration")
        for name in names:
            (self.output / "objects" / name).mkdir(mode=0o700)
        for name in ("kill-evidence", "coverage-evidence"):
            for index in range(132):
                (self.output / "objects" / name / f"raw-{index:04d}").mkdir(mode=0o700)
        for name in ("reader-captures", "reader-runtime", "observation"):
            (self.private / name).mkdir(mode=0o700)
        (self.private / "reader-runtime/no-hooks").mkdir(mode=0o700)
        for name, path in (("request", request), ("shadow-set", shadow), ("dashboard", dashboard), ("marker", marker)):
            raw = self.hold(path).raw
            parse(raw, c.DOCUMENT_LIMIT)
            self.put(name, raw)
        self.request = generation_request(self.outputs["request"].read_bytes())
        self.basis, self.claim = (self.request["body"][name] for name in ("scope_basis", "risk_claim"))
        self.put("basis", c.canonical(self.basis))
        self.put("claim", c.canonical(self.claim))
        self.session = _GateStoreSession(self.request["id"], c.digest(c.canonical(self.request)), self.deadline)
        self.reader = r._Reader(self.outputs["basis"], self.outputs["shadow-set"], bundle, git,
            self.private / "observation/result.json", store_session=self.session, deadline=self.deadline,
            document_paths={name: self.path(name) for name in ("scope", "shadow-set", "dashboard", "risk", "kill", "duty", "marker")})
        self.session.reader = self.reader
        self.session.generator = self
        for relative in ("scope/v1/workflow-scope.jq", "scope/v1/generate-gate-evidence.py", "scope/v1/evaluate-scope.sh",
            "scope/v1/scope-gates.jq", "sandbox/v1/coverage-source.py", "sandbox/v1/host-supervisor.py"):
            self.package(relative)
        for folder in ("control/v1", "scope/v1"):
            for path in sorted((PACKAGE / folder).iterdir()):
                if path.is_file() and path.suffix in {".sh", ".jq", ".json", ".py"}:
                    self.package(str(path.relative_to(PACKAGE)))
        self.hold(self.output)
        self.check()
        require(self.reader.jq_check("scope/v1/workflow-scope.jq", ["-r", "--arg", "gate_basis", "basis"], c.canonical(self.basis)) == b"", "E_SHAPE")

    def path(self, name):
        return self.output / "objects" / name / "value.json"

    def hold(self, path):
        if path.is_dir():
            held = c._open_held(str(path), True, lambda _fd, _state, _ancestor: True, "E_RELATION")
        else:
            held = c._hold_bytes(str(path), c.DOCUMENT_LIMIT)
        self.held.append(held)
        return held

    def package(self, relative):
        if relative not in self.reader.package_sources:
            self.reader.package_sources[relative] = self.reader.hold(PACKAGE / relative, c.EXECUTABLE_LIMIT)

    def put(self, name, raw):
        require(name not in self.outputs and type(raw) is bytes and len(raw) <= c.DOCUMENT_LIMIT, "E_LIMIT")
        path = self.path(name)
        written = r.write_exclusive(path, raw, resolver=self.reader.darwin if self.reader is not None else None)
        self.outputs[name] = path
        self.hold_written(path, raw, written)
        return path

    def hold_written(self, path, raw, written):
        held = self.hold(path)
        require(held.raw == raw and c._identity(held.held.before) == written, "E_STALE")
        self._record_output_hold(path, held)
        return held

    def _init_output_capture(self):
        try:
            self.output_holds = self.capture_output_work = None
            self.capture_output_error = self.capture_output_cancel = None
            self.capture_output_error_category = self.capture_output_error_errno = None
            self.capture_output_errors = None
            self.capture_output_owned = self.capture_output_pending = None
            self.output_holds = dict()
            self.capture_output_errors = list()
            self.capture_output_work = dict(cost_unknown=True, accounting_incomplete=True)
            c._capture_work_values(self.capture_output_work, "gate-output")
            self.capture_output_unusable = False
        except BaseException as error:
            cancellation = self._output_capture_failed("initialize", error)
            if cancellation is not None:
                raise cancellation

    def _output_capture_failed(self, site, error):
        cancellation = getattr(self, "capture_output_cancel", None)
        if cancellation is None and (getattr(error, "_scope_signal_cancel", False) or isinstance(error, KeyboardInterrupt)):
            cancellation = error
        marking_error = restoring_error = None
        try:
            # Direct deletion avoids materializing the instance dictionary.
            object.__delattr__(self, "capture_output_unusable")
        except AttributeError:
            pass
        except BaseException as marking:
            marking_error = marking
            if cancellation is None and (getattr(marking, "_scope_signal_cancel", False) or isinstance(marking, KeyboardInterrupt)):
                cancellation = marking
            try:
                object.__setattr__(self, "capture_output_unusable", True)
            except BaseException as restoring:
                restoring_error = restoring
                if cancellation is None and (getattr(restoring, "_scope_signal_cancel", False) or isinstance(restoring, KeyboardInterrupt)):
                    cancellation = restoring
        try:
            self.capture_output_errors.append({"site": site, "error": error,
                "category": type(error).__name__, "errno": getattr(error, "errno", None)})
            for failure in (marking_error, restoring_error):
                if failure is not None:
                    self.capture_output_errors.append({"site": "failure-marker", "error": failure,
                        "category": type(failure).__name__, "errno": getattr(failure, "errno", None)})
        except BaseException as secondary:
            if cancellation is None and (getattr(secondary, "_scope_signal_cancel", False) or isinstance(secondary, KeyboardInterrupt)):
                cancellation = secondary
            try:
                self.capture_output_reporting_error = secondary
            except BaseException as reporting:
                if cancellation is None and (getattr(reporting, "_scope_signal_cancel", False) or isinstance(reporting, KeyboardInterrupt)):
                    cancellation = reporting
        try:
            if getattr(self, "capture_output_error", None) is None:
                self.capture_output_error = error
                self.capture_output_error_category = type(error).__name__
                self.capture_output_error_errno = getattr(error, "errno", None)
            if cancellation is not None:
                self.capture_output_cancel = cancellation
        except BaseException as secondary:
            if cancellation is None and (getattr(secondary, "_scope_signal_cancel", False) or isinstance(secondary, KeyboardInterrupt)):
                cancellation = secondary
            try:
                self.capture_output_reporting_error = secondary
            except BaseException as reporting:
                if cancellation is None and (getattr(reporting, "_scope_signal_cancel", False) or isinstance(reporting, KeyboardInterrupt)):
                    cancellation = reporting
        anchor = getattr(getattr(self, "reader", None), "anchor", None)
        if anchor is not None:
            try:
                anchor.private_observations["unusable"] = True
            except BaseException as secondary:
                if cancellation is None and (getattr(secondary, "_scope_signal_cancel", False) or isinstance(secondary, KeyboardInterrupt)):
                    cancellation = secondary
                try:
                    self.capture_output_reporting_error = secondary
                except BaseException as reporting:
                    if cancellation is None and (getattr(reporting, "_scope_signal_cancel", False) or isinstance(reporting, KeyboardInterrupt)):
                        cancellation = reporting
        return cancellation

    def _link_output_capture_work(self):
        anchor = getattr(getattr(self, "reader", None), "anchor", None)
        if anchor is not None and getattr(self, "capture_output_work", None) is not None:
            leaves = anchor.recording_work.setdefault("gate_output_work", [])
            if not any(leaf is self.capture_output_work for leaf in leaves):
                leaves.append(self.capture_output_work)
            anchor.recording_work["accounting_incomplete"] = True

    def _record_output_hold(self, path, held):
        cancellation = getattr(self, "capture_output_cancel", None)
        if not self.capture_output_unusable:
            try:
                self._link_output_capture_work()
                self.output_holds[path.relative_to(self.output).as_posix()] = held
            except BaseException as error:
                observed = self._output_capture_failed("register", error)
                cancellation = cancellation if cancellation is not None else observed
        if cancellation is not None:
            raise cancellation
        return not self.capture_output_unusable



    def _capture_completion(self, path, raw, written):
        cancellation = getattr(self, "capture_output_cancel", None)
        pending = None
        if not self.capture_output_unusable:
            try:
                self._link_output_capture_work()
                pending = c._open_held(str(path), False,
                    lambda _fd, _state, _ancestor: True, "E_RELATION",
                    recording_work=self.capture_output_work, accounting_kind="M")
                self.capture_output_pending = pending
                held = c._HeldBytes(pending, pending.read(c.DOCUMENT_LIMIT, "E_RELATION", self.capture_output_work))
                require(held.raw == raw and c._identity(pending.before) == written, "E_STALE")
                if self._record_output_hold(path, held):
                    self.capture_output_owned = held
                    self.capture_output_pending = None
                    pending = None
            except BaseException as error:
                observed = self._output_capture_failed("complete", error)
                cancellation = cancellation if cancellation is not None else observed
        if pending is not None:
            observed = self._close_output_path(pending, "pending-close")
            cancellation = cancellation if cancellation is not None else observed
            try:
                self.capture_output_pending = None
            except BaseException as error:
                observed = self._output_capture_failed("pending-release", error)
                cancellation = cancellation if cancellation is not None else observed
        if cancellation is not None:
            raise cancellation

    def _close_output_path(self, held, site):
        # Pop-before-close preserves single ownership when cancellation interrupts cleanup.
        cancellation = getattr(self, "capture_output_cancel", None)
        while held.components:
            component = held.components.pop()
            try:
                os.close(component.fd)
            except BaseException as error:
                observed = self._output_capture_failed(site, error)
                cancellation = cancellation if cancellation is not None else observed
            finally:
                try:
                    self.capture_output_work["held_close_calls"] = self.capture_output_work.get("held_close_calls", 0) + 1
                except BaseException as error:
                    observed = self._output_capture_failed("close-ledger", error)
                    cancellation = cancellation if cancellation is not None else observed
        return cancellation

    def _close_output_capture(self):
        cancellation = getattr(self, "capture_output_cancel", None)
        owned = getattr(self, "capture_output_owned", None)
        pending = getattr(self, "capture_output_pending", None)
        try:
            self.capture_output_owned = self.capture_output_pending = None
        except BaseException as error:
            observed = self._output_capture_failed("owner-release", error)
            cancellation = cancellation if cancellation is not None else observed
        if owned is not None and owned.held.components:
            try:
                require(owned.held.read(len(owned.raw), "E_STALE", self.capture_output_work) == owned.raw, "E_STALE")
            except BaseException as error:
                observed = self._output_capture_failed("complete-recheck", error)
                cancellation = cancellation if cancellation is not None else observed
            observed = self._close_output_path(owned.held, "complete-close")
            cancellation = cancellation if cancellation is not None else observed
        if pending is not None and (owned is None or pending is not owned.held):
            observed = self._close_output_path(pending, "pending-close")
            cancellation = cancellation if cancellation is not None else observed
        try:
            self._link_output_capture_work()
        except BaseException as error:
            observed = self._output_capture_failed("ledger", error)
            cancellation = cancellation if cancellation is not None else observed
        return cancellation

    def check(self):
        require(self.active and c._clock_value('scope/v1/generate-gate-evidence.py:359:0',time.monotonic(),'monotonic') < self.deadline, "E_RUNTIME")
        for held in self.held:
            held.recheck("E_STALE")
            path = Path(held.held.path if isinstance(held, c._HeldBytes) else held.path)
            if self.reader is not None and (path == self.output or self.output in path.parents):
                fd = held.held.fd if isinstance(held, c._HeldBytes) else held.fd
                access, default = c._acl_state(fd, self.reader.darwin)
                require((access == [] if sys.platform == "darwin" else access is None and default is None), "E_STALE")
        if getattr(self, "reader", None) is not None:
            self.reader.recheck()

    def driver(self, relative, names):
        self.check()
        raw = self.reader.component(relative, ["evaluate", *[self.outputs[name] for name in names]])
        parse(raw, c.DOCUMENT_LIMIT)
        self.check()
        return raw

    def inputs(self):
        _rows, _qualifying, files = self.session.authenticate_core(current_only=True)
        tuples = []
        for current in files["current"].values():
            material = parse(current["materialization-input.json"])
            atomic = []
            for name in ("stage_request", "resolved_profile"):
                pair = material[name]
                reference = self.reader.enforced.pair_ref(pair)
                raw = c.canonical(pair["content"])
                require(reference == ref(raw))
                atomic.append(raw)
            atomic.extend((c.canonical(parse(current["materialization-response.json"])["stage_result"]), current["policy-set.json"]))
            tuples.append(atomic)
        require(tuples and all(row == tuples[0] for row in tuples), "E_RELATION")
        for name, raw in zip(("stage-request", "resolved-profile", "stage-result", "policy-set"), tuples[0]):
            self.put(name, raw)
            self.reader.hold(self.outputs[name], c.DOCUMENT_LIMIT)
        require(ref(tuples[0][0]) == self.basis["body"]["qualified_identity"]["stage_request_ref"]
                and ref(tuples[0][1]) == self.basis["body"]["qualified_identity"]["resolved_profile_ref"])

    def observations(self):
        return _origins_values([(item.observation, item.snapshots)
            for item, _key, _binding in self.session.local.values()])

    def kill_source(self):
        context = self._kill_source_request_phase()
        context[1].release_local()
        return self._kill_source_result_phase(context)

    def _kill_source_request_phase(self):
        reader, session = self.reader, self.session
        configuration = c.load_coverage_configuration(reader.anchor_for(), "kill-register-read")
        require(configuration is not None, "E_CONFIG")
        reader.owned.append(configuration)
        reader.kill_configuration = session.kill_configuration = configuration
        session.initial_origin_refs = session.origins()
        self.put("initial-origins", c.canonical(envelope("gate_initial_origins", self.request["id"], {"origins": session.initial_origin_refs, "observations": self.observations()})))
        runtime = c.canonical(envelope("gate_runtime_package", self.request["id"], {"executables": [
            {"path": held.held.path, "size_bytes": len(held.raw), "sha256": held.sha256}
            for held in (reader.python, reader.bash, reader.git_binary, reader.jq)], "files": [
            {"path": name, "sha256": held.sha256} for name, held in sorted(reader.package_sources.items())]}))
        self.put("runtime", runtime)
        entropy = os.urandom(32)
        reader.anchor.retain_entropy("kill", entropy)
        nonce = entropy.hex()
        call_id = "kill-register." + nonce
        config = configuration.config
        require(config["control_repository"]["repository_id"] != self.basis["body"]["target_repository_id"])
        body = _kill_request_body_values(self.basis, config, call_id, nonce, session.role_files,
            session.initial_origin_refs, reader.git.config, configuration.package_raw, configuration.accepted_raw)
        mapping = {"basis_ref": "basis", "claim_ref": "claim", "stage_request_ref": "stage-request", "resolved_profile_ref": "resolved-profile",
            "stage_result_ref": "stage-result", "policy_set_ref": "policy-set", "shadow_set_ref": "shadow-set", "dashboard_ref": "dashboard",
            "marker_ref": "marker", "runtime_ref": "runtime"}
        body.update({key: ref(self.outputs[name].read_bytes()) for key, name in mapping.items()})
        raw = c.canonical(envelope("kill_register_source_request", call_id, body))
        configuration.normalizer.request(raw)
        session.call_id = call_id
        session.kill_request_raw, session.gate_call_ref = raw, ref(raw)
        self.put("kill-configuration", c.canonical(envelope("gate_source_configuration", call_id,
            {"config": parse(configuration.config_raw), "package": parse(configuration.package_raw), "accepted": parse(configuration.accepted_raw)})))
        self.put("kill-request", raw)
        self.put("kill-expectation", c.canonical(envelope("kill_register_source_expectation", call_id,
            body | {"request_sha256": c.digest(raw)})))
        for name in ("kill-request", "kill-expectation", "runtime", "initial-origins"):
            reader.hold(self.outputs[name], c.DOCUMENT_LIMIT)
        self.check()
        session.phase = "K_REQUEST"
        return reader, session, config, raw

    def _kill_source_result_phase(self, context):
        reader, session, config, raw = context
        require(not session.local and not session.remote, "E_RUNTIME")
        reader.darwin.kill_register_source(raw)
        session.phase = "K_DONE"
        session.authenticate_core(current_only=True)
        source = session.bind_kill()
        observed = parse(source.snapshots["payload/observation.json"])
        require(observed["bootstrap"] == config["bootstrap"] and observed["repository"] == config["control_repository"]
                and observed["default_branch"] == config["default_branch"])
        register_raw = c.canonical(observed["register"])
        require(c.digest(register_raw) == observed["register_sha256"])
        return register_raw

    def run(self):
        manifest_owner = self._run_values()
        self._run_complete(manifest_owner)

    def _run_values(self):
        self.inputs()
        return self._run_after_inputs()

    def _run_after_inputs(self):
        register_raw = self.kill_source()
        return self._run_after_kill(register_raw)

    def _run_after_kill(self, register_raw):
        self.put("register", register_raw)
        duty = self.driver("control/v1/evaluate-duty.sh", ["policy-set", "stage-request", "resolved-profile", "stage-result"])
        self.put("duty", duty)
        stage_refs = {key: ref(self.outputs[name].read_bytes()) for key, name in
            (("request_ref", "stage-request"), ("resolved_profile_ref", "resolved-profile"), ("result_ref", "stage-result"))}
        policy_set = parse(self.outputs["policy-set"].read_bytes())
        policy_ref = {"id": policy_set["id"], "sha256": c.digest(self.outputs["policy-set"].read_bytes())}
        require(parse(duty)["body"]["stage"] == stage_refs and parse(duty)["body"]["policy_set"] == policy_ref)
        risk = self.driver("control/v1/evaluate-risk-gates.sh", ["policy-set", "stage-request", "resolved-profile", "stage-result", "duty", "claim"])
        self.put("risk", risk)
        require(parse(risk)["body"]["verdict"] in {"inconclusive", "violated"}
                and parse(risk)["body"]["stage"] == stage_refs and parse(risk)["body"]["policy_set"] == policy_ref
                and parse(risk)["body"]["duty_evaluation_ref"] == ref(duty))
        state, attempt = project_register(register_raw, self.basis, parse(self.outputs["stage-request"].read_bytes()),
            parse(self.outputs["stage-result"].read_bytes()), duty, self.active)
        self.put("state", state); self.put("attempt", attempt)
        kill = self.driver("control/v1/evaluate-kill-switch.sh", ["policy-set", "state", "attempt", "duty"])
        self.put("kill", kill)
        killed = parse(kill)["body"]
        require(killed["state_ref"] == ref(state) and killed["attempt_ref"] == ref(attempt)
                and killed["duty_evaluation_ref"] == ref(duty))
        self.put("scope", _scope_values(self.basis, duty, risk, kill))
        for name in ("duty", "risk", "state", "attempt", "kill", "scope"):
            self.reader.hold(self.outputs[name], c.DOCUMENT_LIMIT)
        self.session.start_scope()
        names = ("scope", "shadow-set", "dashboard", "risk", "kill", "duty", "marker")
        result = self.reader.darwin.gate_scope([*[str(self.outputs[name]) for name in names], str(self.paths[4]), str(self.paths[5])], self.session)
        evaluation = parse(result)
        require(evaluation["kind"] == "scope_qualification_evaluation" and evaluation["body"]["scope_ref"] == ref(self.outputs["scope"].read_bytes())
                and evaluation["body"]["authority"] == "none" and evaluation["body"]["enabled"] is False)
        self.put("scope-evaluation", result)
        self.put("final-origins", c.canonical(envelope("gate_final_origins", self.request["id"], {"origins": self.session.final_origins, "observations": self.observations()})))
        self.put("commands", c.canonical(envelope("gate_driver_commands", self.request["id"], {"commands": self.reader.commands, "argv": self.reader.gate_commands})))
        for name, source in (("kill-evidence", self.session.kill_source), ("coverage-evidence", self.session.coverage_source)):
            if source is not None:
                source_files = sorted((filename, raw) for filename, raw in source.snapshots.items()
                                      if filename != "capture.json")
                rows = [{"name": filename, "output": str((self.output / "objects" / name / f"raw-{index:04d}/value.raw").relative_to(self.output)),
                         "size_bytes": len(raw), "sha256": c.digest(raw)}
                        for index, (filename, raw) in enumerate(source_files)]
                self.put(name, c.canonical(envelope("gate_source_evidence", self.request["id"],
                    {"origin_ref": ref(source.observation), "files": rows})))
                for row, (_filename, raw) in zip(rows, source_files):
                    path = self.output / row["output"]
                    written = r.write_exclusive(path, raw, resolver=self.reader.darwin)
                    self.hold_written(path, raw, written)
        self.check()
        rows = []
        for path in sorted(self.output.rglob("*")):
            require(not path.is_symlink(), "E_STALE")
            if path.is_file():
                raw = path.read_bytes()
                rows.append({"name": str(path.relative_to(self.output)), "size_bytes": len(raw), "sha256": c.digest(raw)})
        manifest = _manifest_values(self.request["id"], rows, self.session.initial_origin_refs,
            self.session.final_origins, self.session.kill_request_raw, self.session.coverage_request_raw)
        written = r.write_exclusive(self.output / "manifests/manifest.json", manifest, resolver=self.reader.darwin)
        manifest_owner = self.hold_written(self.output / "manifests/manifest.json", manifest, written)
        self.check()
        self.sync_directories()
        self.check()
        return manifest_owner

    def _run_complete(self, manifest_owner):
        require(type(manifest_owner) is c._HeldBytes and any(item is manifest_owner for item in self.held)
            and manifest_owner.held.path == str(self.output / "manifests/manifest.json")
            and self.session.phase == "FINAL_OWNER", "E_RUNTIME")
        manifest = manifest_owner.raw
        self.session.complete()
        self.reader.seal_source_captures()
        completion = _completion_values(self.request["id"], manifest)
        written = r.write_exclusive(self.output / "completion/COMPLETE.json", completion, resolver=self.reader.darwin)
        self._capture_completion(self.output / "completion/COMPLETE.json", completion, written)

    def sync_directories(self):
        # Child directory links must be durable before COMPLETE can name the package.
        for folder, directories, _files in os.walk(self.output, topdown=False, followlinks=False):
            require(c._clock_value('scope/v1/generate-gate-evidence.py:539:0',time.monotonic(),'monotonic') <= self.deadline, "E_RUNTIME")
            path = Path(folder)
            require(not path.is_symlink() and all(not (path / name).is_symlink() for name in directories), "E_STALE")
            fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                before = c._identity(os.fstat(fd))
                require(before == c._identity(os.lstat(path)), "E_STALE")
                os.fsync(fd)
                require(before == c._identity(os.fstat(fd)) == c._identity(os.lstat(path)), "E_STALE")
            finally:
                os.close(fd)

    def close(self):
        primary = sys.exc_info()[1]
        prior_cancel = getattr(self, "capture_output_cancel", None)
        try:
            self.active = False
            failure = None
            if getattr(self, "reader", None) is not None:
                try:
                    self.reader.close()
                except BaseException as exc:
                    failure = exc
            if getattr(self, "session", None) is not None:
                self.session.close()
            for held in reversed(getattr(self, "held", [])):
                try:
                    held.close()
                except BaseException as exc:
                    failure = failure or exc
            self.held = []
            if failure is not None:
                raise failure
        finally:
            native = sys.exc_info()[1]
            for error in (primary, prior_cancel, native):
                if error is not None and (getattr(error, "_scope_signal_cancel", False) or isinstance(error, KeyboardInterrupt)):
                    try:
                        self.capture_output_cancel = error
                    except BaseException as reporting:
                        self._output_capture_failed("cancel-report", reporting)
                    break
            cancellation = self._close_output_capture()
            for error in (primary, prior_cancel, native, cancellation):
                if error is not None and (getattr(error, "_scope_signal_cancel", False) or isinstance(error, KeyboardInterrupt)):
                    raise error


def main(arguments):
    require(sys.flags.isolated and sys.flags.no_site and sys.flags.dont_write_bytecode, "E_RUNTIME")
    os.umask(0o077)
    # Only the consumer's own children can inherit a private lifecycle channel.
    for fd_name in os.listdir("/dev/fd"):
        if fd_name.isdigit() and int(fd_name) > 2:
            try:
                os.close(int(fd_name))
            except OSError:
                pass
    generator = None
    def cancel(_number, _frame):
        if generator is not None:
            generator.active = False
        error = InterruptedError("gate generation cancelled")
        error._scope_signal_cancel = True
        raise error
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, cancel)
    try:
        generator = _Generator.__new__(_Generator)
        generator.__init__(arguments)
        generator.run()
        generator.close()
        require(c._clock_value('scope/v1/generate-gate-evidence.py:593:0',time.monotonic(),'monotonic') <= generator.deadline, "E_RUNTIME")
    except BaseException:
        if generator is not None:
            try:
                generator.close()
            finally:
                output = getattr(generator, "output", None)
                if output is not None and getattr(generator, "created", False):
                    marker = output / "completion/COMPLETE.json"
                    if marker.is_file() and not marker.is_symlink():
                        marker.unlink()
                        fd = os.open(marker.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                        try:
                            os.fsync(fd)
                        finally:
                            os.close(fd)
        raise


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except BaseException as error:
        print(getattr(error, "code", "E_RUNTIME"), file=sys.stderr)
        raise SystemExit(1)
