#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

case "${1:-}:${3:-}" in
  run:/*/operations/[0-2]/I/driver-input/seed.json|dashboard:/*/operations/[0-2]/I/driver-input)
    exec /usr/bin/python3 -I -S -B -c 'GENERATION = '"'"'g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43'"'"'
PROGRAM_SHA = '"'"'efe2004d9d44c9fd3d9e6bf3e73edd9570d785af6c85f1e550fe0d7ff9fed413'"'"'
CATALOG_SHA = '"'"'0239138447a8f9fd420cb3c5da31660d8f75c85099d80d89a040dce2878a4cac'"'"'
TOOL_SHA = '"'"'b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9'"'"'
SCANNER_SHA = '"'"'556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5'"'"'
PLANNER_SHA = '"'"'03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4'"'"'
SANDBOX_SHA = '"'"'8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb'"'"'
RISK_SHA = '"'"'0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8'"'"'
DUTY_SHA = '"'"'146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa'"'"'
NORMALIZER_SHAS = '"'"'{"codex-cli-producer":"dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25","codex-native-reviewer":"7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603","github-actions-ci":"690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7","github-forge":"b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be","gitlab-forge":"ff2ec298eef102f94f28995f5306adeba8e078d19e4c22860c3b167cd9b7c37a"}'"'"'
FIXED_PINS = [('"'"'program.jq'"'"', '"'"'efe2004d9d44c9fd3d9e6bf3e73edd9570d785af6c85f1e550fe0d7ff9fed413'"'"'),
 ('"'"'catalog.json'"'"', '"'"'0239138447a8f9fd420cb3c5da31660d8f75c85099d80d89a040dce2878a4cac'"'"'),
 ('"'"'core/v2/generation-registry.json'"'"', '"'"'3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94'"'"'),
 ('"'"'core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/contracts.jq'"'"',
  '"'"'65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a'"'"'),
 ('"'"'core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/core-ingress.sh'"'"',
  '"'"'dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8'"'"'),
 ('"'"'core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/profile_graph.jq'"'"',
  '"'"'c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207'"'"'),
 ('"'"'core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_facts.jq'"'"',
  '"'"'8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281'"'"'),
 ('"'"'core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_truth.jq'"'"',
  '"'"'ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46'"'"'),
 ('"'"'core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/schema.jq'"'"',
  '"'"'8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade'"'"'),
 ('"'"'core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/stage_request.jq'"'"',
  '"'"'6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e'"'"'),
 ('"'"'scripts/core-contract.sh'"'"', '"'"'b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9'"'"'),
 ('"'"'orchestrator/v1/scan-state.sh'"'"', '"'"'556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5'"'"'),
 ('"'"'orchestrator/v1/reconciliation-plan.jq'"'"',
  '"'"'03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4'"'"'),
 ('"'"'control/v1/evaluate-sandbox.sh'"'"', '"'"'8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb'"'"'),
 ('"'"'control/v1/evaluate-risk-gates.sh'"'"', '"'"'0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8'"'"'),
 ('"'"'control/v1/risk-gates-policy.json'"'"', '"'"'3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e'"'"'),
 ('"'"'control/v1/risk-gates-decision.json'"'"', '"'"'8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5'"'"'),
 ('"'"'control/v1/risk-gates.jq'"'"', '"'"'d00fccd8e31b770c6df01fba17e3cc315d58edfbbf0a8055d66d537dc6ad21ff'"'"'),
 ('"'"'control/v1/duty-separation-policy.json'"'"',
  '"'"'b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9'"'"'),
 ('"'"'control/v1/duty-separation-decision.json'"'"',
  '"'"'4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99'"'"'),
 ('"'"'control/v1/duty-separation.jq'"'"', '"'"'b4e480748dd4fb7dec769b25f0f7649b0e5dc31f9de438bba690e9eab6ac236c'"'"'),
 ('"'"'control/v1/evaluate-duty.sh'"'"', '"'"'146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa'"'"'),
 ('"'"'adapters/codex-cli-producer/v1/normalize.jq'"'"',
  '"'"'dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25'"'"'),
 ('"'"'adapters/gitlab-forge/v1/normalize.jq'"'"',
  '"'"'ff2ec298eef102f94f28995f5306adeba8e078d19e4c22860c3b167cd9b7c37a'"'"'),
 ('"'"'adapters/codex-native-reviewer/v1/normalize.jq'"'"',
  '"'"'7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603'"'"'),
 ('"'"'adapters/github-actions-ci/v1/normalize.jq'"'"',
  '"'"'690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7'"'"'),
 ('"'"'adapters/github-forge/v1/normalize.jq'"'"',
  '"'"'b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be'"'"'),
 ('"'"'control/v1/policy-set.jq'"'"', '"'"'2be97550574ee4522fc0bd14780c92dee3c1b455f2c04b7763b0e437665a8d58'"'"'),
 ('"'"'control/v1/sandbox-decision.json'"'"', '"'"'c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd'"'"'),
 ('"'"'control/v1/sandbox-policy.json'"'"', '"'"'4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e'"'"'),
 ('"'"'control/v1/sandbox.jq'"'"', '"'"'83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3'"'"'),
 ('"'"'control/v1/validate.sh'"'"', '"'"'cf173ad0eaa08244bf636e3937845e894b21f14291fc5e66753e8673bdd2bd2a'"'"'),
 ('"'"'orchestrator/v1/state-scanner-driver.sh'"'"',
  '"'"'5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b'"'"'),
 ('"'"'orchestrator/v1/state-scanner-launcher.sh'"'"',
  '"'"'9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb'"'"'),
 ('"'"'orchestrator/v1/state-scanner.jq'"'"', '"'"'722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae'"'"'),
 ('"'"'evals/v1/framework.jq'"'"', '"'"'d164a102919f42ef002e93c8b515b58028604819e6c09b87c6e4afadb0bbcce4'"'"'),
 ('"'"'evals/v1/run.sh'"'"', '"'"'51770c5597d55bf05020502796810637bfbe697038a541ea6124530c0fffe55c'"'"')]
RECORD_GENERATION_QUERY = ('"'"'\n'"'"'
 '"'"'    if type == "array" and length >= 1 and all(.[];\n'"'"'
 '"'"'      .semantic_identity == "core.contracts.v2" and\n'"'"'
 '"'"'      (.generation_id | type == "string" and test("\\\\Ag-[0-9a-f]{64}\\\\z")))\n'"'"'
 '"'"'    then .[-1].generation_id else error("E_STALE") end\n'"'"'
 '"'"'  '"'"')
REPLAY_SHA_QUERY = ('"'"'\n'"'"'
 '"'"'    [.body.shadow_closure[] | select(.path == "evals/v1/replay-malicious.py")] as $rows |\n'"'"'
 '"'"'    if ($rows | length) == 1 and\n'"'"'
 '"'"'       ($rows[0].sha256 | type == "string" and test("\\\\A[0-9a-f]{64}\\\\z"))\n'"'"'
 '"'"'    then $rows[0].sha256 else error("E_RUNTIME") end\n'"'"'
 '"'"'  '"'"')
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import sys

class DriverError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code

def require(condition, code="E_RUNTIME"):
    if not condition:raise DriverError(code)

def cancelled(error):
    return isinstance(error, KeyboardInterrupt) or getattr(error, "_D_source_cancel", False) or getattr(error, "_scope_signal_cancel", False)

def first(primary, later):
    return later if primary is None or cancelled(later) and not cancelled(primary) else primary

def bootstrap_read(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    chunks, failure = [], None
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and 0 <= before.st_size <= limit)
        size = 0
        while size < before.st_size:
            chunk = os.read(fd, min(65536, before.st_size - size))
            require(chunk)
            bootstrap.append(("read", len(chunk)))
            chunks.append(chunk);size += len(chunk)
        require(os.fstat(fd) == before and os.stat(path, follow_symlinks=False) == before)
        raw = b"".join(chunks)
        bootstrap.append(("copy", len(raw)))
    except BaseException as error:
        failure = error
    finally:
        try:os.close(fd);bootstrap.append(("close", str(path)))
        except BaseException as error:failure = first(failure, error)
    if failure is not None:raise failure
    return raw

bootstrap = []
owner = None
try:
    require(len(sys.argv) == 8, "E_USAGE")
    mode, runtime_text, input_text, evaluator_text, evaluator_sha, seed_sha, observed_at = sys.argv[1:]
    require(mode in {"run", "dashboard"} and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", observed_at), "E_USAGE")
    runtime, input_path, evaluator = Path(runtime_text), Path(input_text), Path(evaluator_text)
    require(runtime.is_absolute() and str(runtime.resolve()) == runtime_text
        and not runtime.is_symlink() and runtime.is_dir()
        and Path(sys.argv[0]).absolute() == runtime / "driver.sh"
        and evaluator == runtime / "evaluator.json")
    suffix = "/driver-input/seed.json" if mode == "run" else "/driver-input"
    require(input_text.endswith(suffix))
    iroot = Path(input_text[:-len(suffix)])
    require(iroot.is_absolute() and iroot.name == "I" and iroot.parent.name in {"0", "1", "2"}
        and iroot.parent.parent.name == "operations" and str(iroot.resolve()) == str(iroot))
    replay_root = iroot / "driver-input/replay-work"
    require(replay_root.is_dir() and not replay_root.is_symlink())
    for name in os.listdir("/dev/fd"):
        if name.isdecimal() and int(name) > 2:
            fd = int(name)
            try:os.close(fd);bootstrap.append(("entry-close", fd, 0, None))
            except OSError as error:
                bootstrap.append(("entry-close", fd, None, error.errno))
                if error.errno != errno.EBADF:raise
    evaluator_raw = bootstrap_read(evaluator, 1048576)
    measured = hashlib.sha256(evaluator_raw).hexdigest();bootstrap.append(("hash", len(evaluator_raw)))
    require(measured == evaluator_sha, "E_STALE")
    evaluator_doc = json.loads(evaluator_raw)
    source_rows = evaluator_doc["body"]["shadow_closure"]
    consumer_rows = [row for row in source_rows if row["path"] == "shadow/v1/_consumer.py"]
    require(len(consumer_rows) == 1, "E_STALE")
    consumer_path = runtime / "shadow/v1/_consumer.py"
    consumer_raw = bootstrap_read(consumer_path, 1048576)
    measured = hashlib.sha256(consumer_raw).hexdigest();bootstrap.append(("hash", len(consumer_raw)))
    require(measured == consumer_rows[0]["sha256"], "E_STALE")
    spec = importlib.util.spec_from_file_location("ystack_shadow_consumer", consumer_path)
    require(spec is not None and spec.loader is not None)
    c = importlib.util.module_from_spec(spec);sys.modules[spec.name] = c;exec(compile(consumer_raw, str(consumer_path), "exec"), c.__dict__)
    require(c._source_root() == str(runtime))

    class Driver:
        def __init__(self):
            self.common = c._c3_fresh_work(0)
            self.scopes = {"common": self.common}
            self.scope = "common"
            self.budget = None
            self.holds, self.fds, self.children, self.entities = [], set(), [], []
            self.written, self.directories, self.sealed_inputs = {}, {}, {}
            self.errors, self.unknown = [], []
            self.common["_c3_scopes"] = self.scopes
            self.common["input_kind"] = "M"
            self.resolver = c._DarwinUUIDResolver() if sys.platform == "darwin" else None
            self.sequence, self.used, self.active_children = [], set(), []
            for event in bootstrap:
                if event[0] == "read":self.read_charge(event[1])
                elif event[0] == "copy":self.processing("C", event[1])
                elif event[0] == "hash":self.processing("H", event[1])
                elif event[0] == "close":
                    self.common["close_calls"] += 1
                    c._capture_observe(self.common, "M", "C3-driver.bootstrap-close", {"path": event[1], "return": 0, "errno": None})
                else:
                    self.common["close_calls"] += 1
                    c._capture_observe(self.common, "M", "C3-driver.entry-close",
                        {"fd": event[1], "return": event[2], "errno": event[3]})
            self.common["C3_bootstrap_import_incomplete"] = True
        @property
        def work(self):return self.scopes[self.scope]
        def room(self, increments):
            if self.budget is None:
                c._capture_copy_room(self.work, 0, False, case=True)
                return
            delta = c._c3_fresh_work(0)
            for path, amount in increments:
                target = delta
                for key in path[:-1]:target = target[key]
                target[path[-1]] += amount
            c._c3_grant_room(self.budget, 0, self.scope, "body", c._c3_work_values(self.work), c._c3_work_values(delta))
        def processing(self, kind, amount):
            self.work["seed_processing"][kind] += amount
        def read_charge(self, amount):
            self.work["read_bytes"] += amount
            c._capture_account(self.work, "M", "read_bytes", amount)
            self.processing("R", amount)
        def own_fd(self, fd):
            try:self.fds.add(fd)
            except BaseException as error:
                self.fds.discard(fd)
                try:
                    later = c._close_capture_copy(fd, self.work, self.work, "C3-driver.fd-adopt", None)
                    if later is not None:error = first(error, later)
                except BaseException as later:error = first(error, later)
                raise error
            return fd
        def own_pipe(self, pair):
            try:
                for fd in pair:
                    self.fds.add(fd)
                return pair
            except BaseException as error:
                for fd in pair:
                    self.fds.discard(fd)
                    try:
                        later = c._close_capture_copy(fd, self.work, self.work, "C3-driver.pipe-adopt", None)
                        if later is not None:error = first(error, later)
                    except BaseException as later:error = first(error, later)
                raise error
        def close(self, fd, site):
            self.fds.discard(fd)
            failure = c._close_capture_copy(fd, self.work, self.work, site, None)
            if failure is not None:raise failure
        def adopt(self, held):
            try:self.holds.append((held, self.scope))
            except BaseException as error:
                if not any(item is held for item, _scope in self.holds):
                    try:held.close()
                    except BaseException as later:error = first(error, later)
                raise error
            return held
        def held(self, path, directory=False, mode=0o400):
            held = c._open_held(str(path), directory,
                c._store_rule(os.geteuid(), os.getegid(), mode, directory, self.resolver),
                "E_STORE", recording_work=self.work, accounting_kind="M")
            return self.adopt(held)
        def read(self, path, limit=1048576, mode=0o400):
            held = self.held(path, mode=mode)
            failure, raw = None, None
            try:
                self.entity(path, held.before)
                self.room([(("read_bytes",), held.before.st_size), (("accounting", "M", "read_bytes"), held.before.st_size),
                    (("seed_processing", "R"), held.before.st_size)])
                raw = held.read(limit, "E_STORE", self.work)
                self.processing("R", len(raw))
                held.recheck("E_STORE", self.work, "M")
                if path != replay_root and replay_root not in path.parents:
                    state = c._stat_values(held.before)
                    if path in self.sealed_inputs:
                        old, identity = self.sealed_inputs[path]
                        code = "E_STALE" if runtime in path.parents else "E_RELATION"
                        require(identity == state, code);self.equal(old, raw, code)
                    else:self.sealed_inputs[path] = (raw, state)
            except BaseException as error:failure = error
            finally:
                try:self.release(held)
                except BaseException as error:failure = first(failure, error)
            if failure is not None:raise failure
            return raw
        def sha(self, raw):
            self.room([(("seed_processing", "H"), len(raw))])
            value = c.digest(raw);self.processing("H", len(raw));return value
        def equal(self, left, right, code):
            self.room([(("seed_processing", "E"), len(left) + len(right))])
            self.processing("E", len(left) + len(right));require(left == right, code)
        def encode(self, value):
            return c._c3_encode_values(value, self.work)
        def parse(self, raw):return c._c3_json_values(raw, self.work)
        def seed_document(self, raw):
            self.room([(("read_bytes",), len(raw)), (("accounting", "M", "read_bytes"), len(raw)),
                (("seed_processing", "R"), len(raw))])
            self.work["C3_seed_parse_incomplete"] = True
            self.read_charge(len(raw))
            value = c._json(raw, c.DOCUMENT_LIMIT, "E_PARSE")
            del self.work["C3_seed_parse_incomplete"]
            return value
        def entity(self, path, state):
            for root_name, root_path in (("privatework", replay_root), ("I", iroot), ("runtime", runtime)):
                if path == root_path or root_path in path.parents:break
            else:raise DriverError("E_RUNTIME")
            for _scope, existing_path, existing in self.entities:
                if existing_path == path:
                    require(existing["initial_identity"]["dev"] == state.st_dev
                        and existing["initial_identity"]["ino"] == state.st_ino, "E_RELATION")
                    return existing
            row = {"root": root_name, "member": os.fsencode("" if path == root_path else str(path.relative_to(root_path))).hex(),
                "creation_ordinal": len(self.entities), "kind": "M",
                "initial_identity": c._stat_values(state), "last_identity": c._stat_values(state),
                "size_bytes": state.st_size, "state": "present"}
            self.entities.append((self.scope, path, row));return row
        def observed_identity(self, path, state):
            for _scope, existing, row in self.entities:
                if existing == path:
                    row["last_identity"] = c._stat_values(state);row["size_bytes"] = state.st_size
        def parent(self, path):
            require(path in self.directories)
            held = self.directories[path]
            held.recheck("E_STORE", self.work, "M")
            return held
        def refresh(self, parent, before, names, added):
            require(set(parent.listdir()) == names | {added})
            c._refresh_recording_directory(parent, before, self.work)
            self.observed_identity(Path(parent.path), parent.before)
            index = len(parent.components) - 1
            for held, _scope in self.holds:
                if held is parent or len(held.components) <= index:continue
                if os.path.commonpath((held.path, parent.path)) == parent.path:
                    component = held.components[index]
                    require(c._identity(component.before) == c._identity(before))
                    component.before = parent.before
        def create_parent(self, parent_path, name, directory):
            parent = self.parent(parent_path)
            names = set(parent.listdir());require(name not in names and len(names) < 256, "E_LIMIT")
            self.room([(("files",), 1), (("accounting", "M", "files"), 1)])
            before = parent.before
            if directory:
                os.mkdir(name, 0o700, dir_fd=parent.fd);fd = None
            else:
                fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent.fd)
                self.own_fd(fd)
            self.work["files"] += 1;c._capture_account(self.work, "M", "files", 1)
            self.refresh(parent, before, names, name)
            os.fsync(parent.fd)
            return parent_path / name, fd
        def mkdir(self, parent, name):
            path, _fd = self.create_parent(parent, name, True)
            held = self.held(path, True, 0o700);require(not held.listdir())
            self.directories[path] = held;self.entity(path, held.before)
            return path
        def write(self, path, raw):
            require(type(raw) is bytes and len(raw) <= 1048576, "E_LIMIT")
            path, fd = self.create_parent(path.parent, path.name, False)
            row = self.entity(path, os.fstat(fd))
            failure = None
            try:
                offset = 0
                while offset < len(raw):
                    amount = min(65536, len(raw) - offset)
                    self.room([(("write_bytes",), amount), (("physical_bytes",), amount), (("read_bytes",), amount),
                        (("accounting", "M", "read_bytes"), amount),
                        (("accounting", "M", "write_bytes"), amount), (("accounting", "M", "physical_bytes"), amount),
                        (("seed_processing", "W"), amount), (("seed_processing", "C"), amount)])
                    c._capture_copy_room(self.work, amount, False, case=True)
                    count = os.write(fd, memoryview(raw)[offset:offset + amount])
                    if count > 0:
                        self.work["write_bytes"] += count;self.work["physical_bytes"] += count;self.work["read_bytes"] += count
                        self.processing("W", count);self.processing("C", count)
                        c._capture_account(self.work, "M", "write_bytes", count)
                        c._capture_account(self.work, "M", "physical_bytes", count)
                        c._capture_account(self.work, "M", "read_bytes", count)
                    require(count > 0);offset += count
                os.fsync(fd)
                state = os.fstat(fd);self.observed_identity(path, state)
                row["last_identity"] = c._stat_values(state);row["size_bytes"] = offset
            except BaseException as error:failure = error
            finally:
                try:self.close(fd, "C3-driver.value-write")
                except BaseException as error:failure = first(failure, error)
            if failure is not None:row["state"] = "unknown";raise failure
            actual = self.read(path, mode=0o600)
            require(len(actual) == len(raw))
            require(self.sha(actual) == self.sha(raw))
            self.equal(actual, raw, "E_RELATION")
            self.written[path] = (self.scope, raw, row["last_identity"])
            return path
        def run(self, argv, env=None):
            null = self.own_fd(os.open("/dev/null", os.O_RDONLY))
            out_read, out_write = self.own_pipe(os.pipe())
            err_read, err_write = self.own_pipe(os.pipe())
            actions = [(os.POSIX_SPAWN_DUP2, null, 0), (os.POSIX_SPAWN_DUP2, out_write, 1), (os.POSIX_SPAWN_DUP2, err_write, 2)]
            unused = set(self.fds)
            unused.update(component.fd for held, _scope in self.holds for component in held.components)
            unused.update((9, 10))
            actual_open = set()
            for fd in unused:
                try:os.fstat(fd);actual_open.add(fd)
                except OSError as error:
                    if error.errno != errno.EBADF:raise
            actions.extend((os.POSIX_SPAWN_CLOSE, fd) for fd in sorted(actual_open | {9, 10}) if fd > 2)
            pid = None;failure = None;stdout = bytearray();stderr = bytearray();status = None
            selector = selectors.SelectSelector()
            try:
                pid = os.posix_spawn(argv[0], argv, env if env is not None else {"LC_ALL": "C", "PATH": "/usr/bin:/bin", "TMPDIR": os.environ["TMPDIR"]}, file_actions=actions)
                self.active_children.append(pid)
                self.work.setdefault("C3_spawns", []).append({"pid": pid, "argv": argv, "actions": actions})
                c._capture_observe(self.work, "M", "C3-driver.spawn", {"pid": pid, "argv": argv, "actions": actions})
                for fd, site in ((null, "C3-driver.child-stdin"), (out_write, "C3-driver.child-stdout-write"), (err_write, "C3-driver.child-stderr-write")):
                    self.close(fd, site)
                selector.register(out_read, selectors.EVENT_READ, stdout)
                selector.register(err_read, selectors.EVENT_READ, stderr)
                while selector.get_map():
                    for key, _events in selector.select():
                        self.room([(("read_bytes",), 65536), (("accounting", "M", "read_bytes"), 65536), (("seed_processing", "R"), 65536)])
                        raw = os.read(key.fd, 65536)
                        self.read_charge(len(raw))
                        if not raw:
                            selector.unregister(key.fd);self.close(key.fd, "C3-driver.child-read")
                        else:
                            require(len(key.data) + len(raw) <= 1048576, "E_LIMIT")
                            key.data.extend(raw);self.processing("C", len(raw))
                waited, status = os.waitpid(pid, 0);require(waited == pid)
                self.work.setdefault("C3_waits", []).append({"pid": pid, "status": status})
                c._capture_observe(self.work, "M", "C3-driver.wait", {"pid": pid, "status": status})
                self.active_children.remove(pid);pid = None
                out, err = bytes(stdout), bytes(stderr)
                self.processing("C", len(out) + len(err))
                return waited, status, out, err
            except BaseException as error:failure = error
            finally:
                try:selector.close()
                except BaseException as error:failure = first(failure, error)
                for fd, site in ((null, "C3-driver.child-stdin-final"), (out_read, "C3-driver.child-out-final"),
                    (out_write, "C3-driver.child-out-write-final"), (err_read, "C3-driver.child-err-final"), (err_write, "C3-driver.child-err-write-final")):
                    if fd in self.fds:
                        try:self.close(fd, site)
                        except BaseException as error:failure = first(failure, error)
                if pid is not None:
                    try:os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:pass
                    except BaseException as error:failure = first(failure, error)
                    try:
                        waited, status = os.waitpid(pid, 0)
                        self.work.setdefault("C3_waits", []).append({"pid": waited, "status": status})
                        c._capture_observe(self.work, "M", "C3-driver.wait", {"pid": waited, "status": status})
                        self.active_children.remove(pid)
                    except BaseException as error:failure = first(failure, error)
                if failure is not None:
                    self.work["C3_partial_stdout"] = bytes(stdout);self.work["C3_partial_stderr"] = bytes(stderr)
                    self.processing("C", len(stdout) + len(stderr))
            raise failure
        def jq(self, arguments, code="E_RUNTIME"):
            _pid, status, out, err = self.run([str(runtime / "bin/jq"), *arguments])
            require(os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0, code)
            return out
        def check(self, operation, observation, candidate, token):
            raw = self.program(operation, observation, candidate, token)
            require(raw == b"true\n", token)
        def single(self, path):
            self.jq(["-e", "-n", "--slurpfile", "roots", str(path), "($roots | length) == 1"], "E_PARSE")
        def verify(self, digest, path, mode=0o400):
            try:require(self.sha(self.read(path, mode=mode)) == digest, "E_STALE")
            except BaseException as error:
                if cancelled(error) or getattr(error, "code", None) == "E_LIMIT":raise
                raise DriverError("E_STALE") from error
        def verify_runtime(self):
            for relative, expected in FIXED_PINS:self.verify(expected, runtime / relative)
            record_generation = self.jq(["-er", RECORD_GENERATION_QUERY, str(runtime / "core/v2/generation-registry.json")], "E_STALE").decode().rstrip("\n")
            path = "core/v2/generations/" + record_generation + "/modules/schema.jq"
            self.jq(["-e", "--arg", "path", path, "[.body.core_closure[] | select(.path == $path)] == [{path:$path,sha256:\"8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade\"}]", str(evaluator)], "E_STALE")
            self.verify("8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade", runtime / path)
            self.verify(self.evaluator_sha, evaluator)
            self.verify(self.seed_sha, self.input_document)
        def verify_review_files(self):
            raw = self.read(runtime / "review-files.tsv")
            for row in raw.decode().splitlines():
                digest, path = row.split("\t", 1)
                try:self.verify(digest, runtime / path)
                except BaseException as error:
                    if cancelled(error):raise
                    raise DriverError("E_RELATION") from error
        def program(self, operation, observation, candidate, code="E_RUNTIME"):
            args = ["-S", "-c", "-n", "-L", str(runtime / "core/v2/generations" / GENERATION / "modules"),
                "--arg", "evals_operation", operation]
            values = [("program_sha256", PROGRAM_SHA), ("driver_sha256", self.driver_sha), ("catalog_sha256", CATALOG_SHA),
                ("evaluator_sha256", self.evaluator_sha), ("seed_set_sha256", self.seed_sha), ("tool_sha256", TOOL_SHA),
                ("scanner_sha256", SCANNER_SHA), ("planner_sha256", PLANNER_SHA), ("sandbox_sha256", SANDBOX_SHA)]
            for name, value in values:args.extend(("--arg", name, value))
            args.extend(("--argjson", "normalizer_shas", NORMALIZER_SHAS))
            for name, value in (("risk_gates_sha256", RISK_SHA), ("duty_sha256", DUTY_SHA), ("observed_at", self.observed_at)):
                args.extend(("--arg", name, value))
            for name, path in (("catalog_docs", runtime / "catalog.json"), ("seed_set_docs", self.seed_docs),
                ("observation_docs", observation), ("evaluator_docs", evaluator), ("candidate_docs", candidate), ("result_docs", self.result_docs)):
                args.extend(("--slurpfile", name, str(path)))
            args.extend(("--argjson", "result_shas", self.result_shas, "-f", str(runtime / "program.jq")))
            return self.jq(args, code)
        def original_inputs(self):
            self.evaluator_sha, self.seed_sha, self.observed_at = evaluator_sha, seed_sha, observed_at
            self.input_document = input_path if mode == "run" else input_path / "manifest.json"
            self.driver_sha = self.sha(self.read(runtime / "driver.sh"))
            self.verify(consumer_rows[0]["sha256"], consumer_path)
            self.verify_runtime()
            jq_hold = self.held(runtime / "bin/jq", mode=0o500)
            require(os.access(runtime / "bin/jq", os.X_OK))
            self.release(jq_hold)
            require(self.jq(["--version"]) == b"jq-1.6\n")
            root = self.held(replay_root, True, 0o700);require(not root.listdir())
            self.directories[replay_root] = root
            self.work_identity = c._stat_values(root.before)
            self.entity(replay_root, root.before)
        def bindings(self):
            window_raw = self.read(iroot / "driver-input/window.json")
            self.window_sha = self.sha(window_raw)
            launcher_raw = self.read(runtime / "launcher.sh")
            table = c._c3_source_closure_values(launcher_raw)
            closure_sha = self.sha(table)
            for row in table.decode().splitlines():
                relative, expected, length, source_mode = row.split()
                require(length.isdecimal() and source_mode in {"100644", "100755"}, "E_STALE")
                self.verify(expected, runtime / relative)
            seeds, results, case_rows = [], [], []
            pairs = [(None, input_path, None)] if mode == "run" else [(index, input_path / ("seed-%d.json" % index), input_path / ("result-%d.json" % index)) for index in range(2)]
            for pair, seed, result in pairs:
                seed_raw = self.read(seed);seeds.append(self.sha(seed_raw));document = self.seed_document(seed_raw)
                if result is not None:results.append(self.sha(self.read(result)))
                for case in document["body"]["cases"]:
                    case_id = case["case_id"];require(case_id in c._C3_CASES)
                    slot = c._C3_CASES.index(case_id)
                    require(slot not in self.used);self.used.add(slot)
                    manifest_raw = self.encode(case["manifest"]["content"])
                    core_raw = self.encode(case["manifest"]["content"]["inventory_core"])
                    manifest_sha = self.sha(manifest_raw)
                    require(manifest_sha == case["manifest"]["sha256"], "E_RELATION")
                    case_rows.append({"slot": slot, "case_id": case_id, "manifest_size": len(manifest_raw),
                        "manifest_sha256": manifest_sha, "core_sha256": self.sha(core_raw)})
                    self.sequence.append({"slot": slot, "case_id": case_id, "pair": pair})
                    leaf = c._c3_fresh_work(0);leaf["input_kind"] = "M";self.scopes[case_id] = leaf
            bindings = {"seed_sha256s": seeds, "result_sha256s": results, "evaluator_sha256": self.sha(self.read(evaluator)),
                "source_closure_sha256": closure_sha, "cases": case_rows, "work_identity": self.work_identity}
            budget_raw = self.read(iroot / "driver-input/replay-budget.json")
            budget_sha = self.sha(budget_raw)
            self.budget = c._c3_budget_values(budget_raw, 0, int(iroot.parent.name), mode, self.window_sha, bindings, self.common)
            require(self.budget["sequence"] == self.sequence, "E_RELATION")
            self.common["_c3_budget_sha"] = budget_sha;self.common["_c3_input_bindings"] = bindings
            for scope, work in self.scopes.items():
                c._c3_grant_room(self.budget, 0, scope, "bootstrap", c._c3_work_values(work), c._c3_work_values(c._c3_fresh_work(0)))
            for scope, work in self.scopes.items():work["_c3_grant_binding"] = (self.budget, 0, scope, "body")
            self.used.clear()
        def append(self, path, raw):
            _owner_scope, old, identity = self.written[path]
            fd = self.own_fd(os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW))
            row = self.entity(path, os.fstat(fd));require(c._stat_values(os.fstat(fd)) == identity)
            failure = None
            try:
                offset = 0
                while offset < len(raw):
                    size = min(65536, len(raw) - offset)
                    self.room([(("write_bytes",), size), (("physical_bytes",), size), (("read_bytes",), size),
                        (("accounting", "M", "read_bytes"), size),
                        (("accounting", "M", "write_bytes"), size), (("accounting", "M", "physical_bytes"), size),
                        (("seed_processing", "W"), size), (("seed_processing", "C"), size)])
                    c._capture_copy_room(self.work, size, False, case=True)
                    count = os.write(fd, memoryview(raw)[offset:offset + size])
                    if count > 0:
                        self.work["write_bytes"] += count;self.work["physical_bytes"] += count;self.work["read_bytes"] += count
                        c._capture_account(self.work, "M", "write_bytes", count)
                        c._capture_account(self.work, "M", "physical_bytes", count)
                        c._capture_account(self.work, "M", "read_bytes", count)
                        self.processing("W", count);self.processing("C", count)
                    require(count > 0);offset += count
                os.fsync(fd);state = os.fstat(fd);self.observed_identity(path, state)
                row["last_identity"] = c._stat_values(state);row["size_bytes"] = len(old) + offset
            except BaseException as error:failure = error
            finally:
                try:self.close(fd, "C3-driver.value-append")
                except BaseException as error:failure = first(failure, error)
            if failure is not None:row["state"] = "unknown";raise failure
            actual = self.read(path, mode=0o600)
            joined = old + raw;self.processing("C", len(joined))
            require(self.sha(actual) == self.sha(joined));self.equal(actual, joined, "E_RELATION")
            self.written[path] = (self.scope, joined, row["last_identity"])
        def produce_result(self, seed_path, work_path):
            self.input_document, self.seed_docs = seed_path, seed_path
            self.check("validate-seed-set", work_path / "empty-observations.json", work_path / "empty-candidate.json", "E_SHAPE")
            seed_source = self.jq(["-r", ".body.seed_source // empty", str(seed_path)]).decode().rstrip("\n")
            require(seed_source == "shadow.malicious-instructions.v1")
            count = self.jq(["-r", ".body.cases | length", str(seed_path)]).decode().rstrip("\n")
            require(re.fullmatch(r"[1-9][0-9]?", count) and int(count) <= 64, "E_SHAPE")
            observations = self.write(work_path / "observations.json", b"[")
            replay = runtime / "evals/v1/replay-malicious.py"
            replay_sha = self.jq(["-er", REPLAY_SHA_QUERY, str(evaluator)]).decode().rstrip("\n")
            self.verify(replay_sha, replay)
            for index in range(int(count)):
                case_id = self.jq(["-r", ".body.cases[%d].case_id" % index, str(seed_path)]).decode().rstrip("\n")
                require(case_id in c._C3_CASES)
                slot = c._C3_CASES.index(case_id);require(slot not in self.used)
                wanted = self.sequence[len(self.children)]
                require(wanted["slot"] == slot and wanted["case_id"] == case_id)
                self.scope = case_id
                case_doc = replay_root / ("malicious-case-%d.json" % slot)
                case_raw = self.jq(["-S", "-c", ".body.cases[%d]" % index, str(seed_path)])
                self.write(case_doc, case_raw)
                case_work = self.mkdir(replay_root, "malicious-work-%d" % slot)
                out_path = self.write(replay_root / ("malicious-%d.out" % slot), b"")
                err_path = self.write(replay_root / ("malicious-%d.err" % slot), b"")
                canonical_path = self.write(replay_root / ("malicious-%d.canonical" % slot), b"")
                case = self.parse(case_raw)
                manifest_raw = self.encode(case["manifest"]["content"])
                core_raw = self.encode(case["manifest"]["content"]["inventory_core"])
                child_bindings = {"slot": slot, "case_id": case_id, "case_document_sha256": self.sha(case_raw),
                    "manifest_sha256": self.sha(manifest_raw), "core_sha256": self.sha(core_raw), "window_sha256": self.window_sha}
                require(not self.directories[case_work].listdir())
                self.release(self.directories.pop(case_work))
                self.scope = "common"
                try:
                    pid, status, wire, error = self.run(["/usr/bin/python3", "-I", "-S", "-B", str(replay), str(runtime),
                        str(iroot), str(case_doc), str(case_work)], {"LC_ALL": "C", "PATH": "/usr/bin:/bin", "TMPDIR": str(case_work)})
                except BaseException as failure:
                    self.scope = case_id
                    for target, key in ((out_path, "C3_partial_stdout"), (err_path, "C3_partial_stderr")):
                        if key in self.common:
                            try:self.append(target, self.common[key])
                            except BaseException as later:failure = first(failure, later)
                    raise failure
                self.scope = case_id
                self.append(out_path, wire);self.append(err_path, error)
                self.scope = "common"
                data, end, done, settlement = c._c3_receive_values(wire, error, status, pid, os.getpid(),
                    self.budget, slot + 1, child_bindings, self.common)
                received = self.common["C3_received"][-1]
                end_raw = received["end_raw"]
                self.room([(("seed_processing", "C"), 2 * (len(end_raw) + len(done)))])
                self.processing("C", 2 * (len(end_raw) + len(done)))
                self.children.append({"actor": slot + 1, "pid": pid, "wait_status": status,
                    "end_hex": end_raw.hex(), "done_hex": done.hex()})
                self.used.add(slot)
                self.common.setdefault("C3_child_settlements", []).append(settlement)
                self.scope = case_id
                self.verify(replay_sha, replay)
                self.append(canonical_path, data)
                self.single(canonical_path)
                final_case = self.held(case_work, True, 0o700)
                initial_rows = [row for _scope, path, row in self.entities if path == case_work]
                require(len(initial_rows) == 1)
                initial_identity, current_identity = initial_rows[0]["initial_identity"], c._stat_values(final_case.before)
                require(all(initial_identity[key] == current_identity[key] for key in ("dev", "ino", "mode", "uid", "gid")), "E_RELATION")
                self.observed_identity(case_work, final_case.before);self.release(final_case)
                canonical = self.jq(["-S", "-c", ".", str(canonical_path)])
                self.equal(data, canonical, "E_RUNTIME")
                self.jq(["-e", "--arg", "case_id", case_id, ".case_id == $case_id", str(canonical_path)])
                self.scope = "common"
                if index:self.append(observations, b",")
                self.append(observations, data.rstrip(b"\n"))
            self.scope = "common";self.append(observations, b"]\n")
            result = self.write(work_path / "run-result.json", self.program("build-run-result", observations, work_path / "empty-candidate.json"))
            self.check("validate-run-result", observations, result, "E_RUNTIME")
            return result
        def empties(self, work_path):
            self.write(work_path / "empty-observations.json", b"[]\n")
            self.write(work_path / "empty-candidate.json", b"{}\n")
        def business(self):
            self.scope = "common"
            self.seed_docs = self.input_document;self.result_docs = self.input_document;self.result_shas = "[]"
            self.empties(replay_root)
            self.single(self.input_document)
            self.seed_docs = replay_root / "empty-observations.json";self.result_docs = self.seed_docs
            self.check("validate-catalog", replay_root / "empty-observations.json", replay_root / "empty-candidate.json", "E_STALE")
            if mode == "run":
                result = self.produce_result(input_path, replay_root)
                self.verify_runtime();self.verify_review_files()
                return self.read(result, mode=0o600)
            manifest_path = input_path / "manifest.json"
            self.single(manifest_path)
            pair_count = self.jq(["-r", "if type == \"array\" then length else empty end", str(manifest_path)]).decode().rstrip("\n")
            require(re.fullmatch(r"([1-9]|1[0-6])", pair_count), "E_SHAPE")
            require(int(pair_count) == 2, "E_SHAPE")
            seeds_path = self.write(replay_root / "seeds.jsonl", b"")
            results_path = self.write(replay_root / "results.jsonl", b"")
            for pair in range(int(pair_count)):
                seed_path, result_path = input_path / ("seed-%d.json" % pair), input_path / ("result-%d.json" % pair)
                seed_raw, result_raw = self.read(seed_path), self.read(result_path)
                wanted_seed = self.jq(["-r", ".[%d].seed_sha256" % pair, str(manifest_path)]).decode().rstrip("\n")
                wanted_result = self.jq(["-r", ".[%d].result_sha256" % pair, str(manifest_path)]).decode().rstrip("\n")
                require(self.sha(seed_raw) == wanted_seed and self.sha(result_raw) == wanted_result, "E_RELATION")
                self.single(seed_path);self.single(result_path)
                canonical = self.jq(["-S", "-c", ".", str(result_path)], "E_CANONICAL")
                self.write(replay_root / ("pair-%d-canonical.json" % pair), canonical)
                self.equal(result_raw, canonical, "E_CANONICAL")
                pair_time = self.jq(["-r", ".body.observed_at", str(result_path)]).decode().rstrip("\n")
                require(re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", pair_time), "E_SHAPE")
                work_path = self.mkdir(replay_root, "pair-%d" % pair);self.empties(work_path)
                self.seed_sha, self.observed_at = self.sha(seed_raw), pair_time
                result = self.produce_result(seed_path, work_path)
                self.equal(self.read(result, mode=0o600), result_raw, "E_RELATION")
                self.input_document = manifest_path;self.seed_sha, self.observed_at = seed_sha, observed_at
                self.append(seeds_path, self.jq(["-S", "-c", ".", str(seed_path)]))
                self.append(results_path, self.jq(["-S", "-c", ".", str(result_path)]))
            self.seed_docs, self.result_docs = seeds_path, results_path
            self.result_shas = self.jq(["-c", "map(.result_sha256)", str(manifest_path)]).decode().rstrip("\n")
            self.jq(["-e", "-n", "--argjson", "shas", self.result_shas, "$shas | length == (unique | length)"])
            distinct = self.jq(["-s", "[.[].body.cases[] | [.family_id,.case_id]] | length == (unique | length)", str(results_path)])
            require(distinct == b"true\n", "E_SHAPE")
            dashboard = self.write(replay_root / "dashboard.json", self.program("build-dashboard", replay_root / "empty-observations.json", replay_root / "empty-candidate.json"))
            self.check("validate-dashboard", replay_root / "empty-observations.json", dashboard, "E_RUNTIME")
            self.verify_runtime();self.verify_review_files()
            return self.read(dashboard, mode=0o600)
        def release(self, held):
            matches = [index for index, (item, _scope) in enumerate(self.holds) if item is held]
            require(len(matches) == 1)
            _item, scope = self.holds.pop(matches[0]);previous = self.scope;self.scope = scope
            try:
                require(held.recording_work is self.work)
                held.close()
            finally:self.scope = previous
        def final_files(self):
            self.scope = "common"
            self.verify_runtime();self.verify_review_files()
            for path, (scope, raw, identity) in self.written.items():
                self.scope = scope
                actual = self.read(path, mode=0o600)
                require(c._stat_values(os.stat(path, follow_symlinks=False)) == identity, "E_RELATION")
                require(self.sha(actual) == self.sha(raw), "E_RELATION");self.equal(actual, raw, "E_RELATION")
            for path, (raw, identity) in list(self.sealed_inputs.items()):
                self.scope = "common"
                actual = self.read(path)
                require(c._stat_values(os.stat(path, follow_symlinks=False)) == identity, "E_STALE" if runtime in path.parents else "E_RELATION")
                require(self.sha(actual) == self.sha(raw), "E_RELATION");self.equal(actual, raw, "E_RELATION")
            for held, scope in self.holds:
                self.scope = scope;held.recheck("E_STORE", self.work, "M")
            self.scope = "common"
        def finish(self, data):
            require(len(self.children) == len(self.sequence) and self.used == {row["slot"] for row in self.sequence})
            self.final_files()
            while self.holds:self.release(self.holds[-1][0])
            for fd in sorted(self.fds):self.close(fd, "C3-driver.final-unused")
            self.close(0, "C3-driver.stdin")
            self.common["_c3_open_regular"] = [held.path for held, _scope in self.holds] + list(self.fds)
            self.common["_c3_owned_children"] = self.active_children
            require(not self.common["_c3_open_regular"] and not self.active_children)
            own = {}
            for scope, work in self.scopes.items():
                receipts = {name: {"state": "not-applicable"} for name in ("raw", "export", "source", "preparation", "Q")}
                if work.get("C3_spawns"):
                    receipts["Q"] = {"state": "unknown"}
                unknown = list(self.unknown) if scope == "common" else []
                unknown.extend(key for key, value in work.items() if key.endswith("incomplete") and value)
                own[scope] = c._c3_ledger_values(work, receipts,
                    [row for owner_scope, _path, row in self.entities if owner_scope == scope],
                    [row for row in self.errors if row["owner"] == work["accounting_owner"]], unknown)
            end = {"version": 1, "window_sha256": self.window_sha, "ordinal": self.budget["ordinal"], "actor": 0,
                "budget_sha256": self.common["_c3_budget_sha"], "leaf_pid": os.getpid(), "leaf_ppid": os.getppid(),
                "input_bindings": self.common["_c3_input_bindings"], "data": {"size_bytes": len(data), "sha256": self.sha(data)},
                "own": own, "children": self.children, "outcome": "completed"}
            c._c3_emit(data, end, self.common, self.budget, 0)
        def error_row(self, error, site):
            self.errors.append({"owner": "C3-driver", "site": site, "ordinal": len(self.errors),
                "category": type(error).__name__, "errno": getattr(error, "errno", None), "cancelled": bool(cancelled(error))})
        def failed(self, primary):
            failure = primary
            try:self.error_row(primary, "C3-driver.body")
            except BaseException as later:failure = first(failure, later)
            while self.holds:
                try:self.release(self.holds[-1][0])
                except BaseException as error:
                    try:self.error_row(error, "C3-driver.failed-held-close")
                    except BaseException as later:error = first(error, later)
                    failure = first(failure, error)
            for fd in sorted(self.fds):
                try:self.close(fd, "C3-driver.failed-unused")
                except BaseException as error:
                    try:self.error_row(error, "C3-driver.failed-fd-close")
                    except BaseException as later:error = first(error, later)
                    failure = first(failure, error)
            return failure
    owner = Driver()
    def interrupt(number, _frame):
        error = InterruptedError("driver cancelled")
        error._D_source_cancel = True
        error._scope_signal_cancel = True
        raise error
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):signal.signal(number, interrupt)
    owner.original_inputs();owner.bindings();owner.finish(owner.business())
except BaseException as error:
    if owner is not None:error = owner.failed(error)
    code = getattr(error, "code", "E_RUNTIME")
    if code not in {"E_USAGE", "E_RUNTIME", "E_LIMIT", "E_PARSE", "E_CANONICAL", "E_SHAPE", "E_RELATION", "E_STALE"}:code = "E_RUNTIME"
    try:os.write(2, (code + "\n").encode("ascii"))
    finally:os._exit(1)
' "$0" "$@"
    ;;
esac

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|E_STALE)
      /usr/bin/printf '%s\n' "$1" >&2
      ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

sha256_path() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

verify_hash() {
  [ -f "$2" ] && [ ! -L "$2" ] &&
    [ "$(sha256_path "$2")" = "$1" ]
}

[ "$#" -eq 7 ] || emit_error E_USAGE
mode=$1
case "$mode" in run|dashboard) ;; *) emit_error E_USAGE ;; esac
runtime=$2
input=$3
evaluator=$4
evaluator_sha256=$5
seed_set_sha256=$6
observed_at=$7
[[ "$observed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
  emit_error E_USAGE

self=${BASH_SOURCE[0]}
case "$self" in /*) ;; *) emit_error E_RUNTIME ;; esac
self_dir=$(CDPATH='' cd -P -- "${self%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
self="$self_dir/${self##*/}"
[ "$self" = "$runtime/driver.sh" ] && [ "$self_dir" = "$runtime" ] ||
  emit_error E_RUNTIME
[ -d "$runtime" ] && [ ! -L "$runtime" ] || emit_error E_RUNTIME
runtime_parent=${runtime%/*}
malicious_input_root=''
case "$mode:$input" in
  run:"$runtime_parent"/input.json) input_document=$input ;;
  dashboard:"$runtime_parent"/inputs)
    [ -d "$input" ] && [ ! -L "$input" ] || emit_error E_RUNTIME
    input_document="$input/manifest.json"
    ;;
  run:/*/operations/[0-2]/I/driver-input/seed.json)
    malicious_input_root=${input%/driver-input/seed.json}
    input_document=$input
    ;;
  dashboard:/*/operations/[0-2]/I/driver-input)
    malicious_input_root=${input%/driver-input}
    input_document="$input/manifest.json"
    ;;
  *) emit_error E_RUNTIME ;;
esac
if [ -n "$malicious_input_root" ]; then
  [ -d "$malicious_input_root" ] && [ ! -L "$malicious_input_root" ] &&
    [ -d "$malicious_input_root/driver-input" ] && [ ! -L "$malicious_input_root/driver-input" ] &&
    [ "$(CDPATH='' cd -P -- "$malicious_input_root/driver-input" 2>/dev/null && pwd -P)" = "$malicious_input_root/driver-input" ] ||
    emit_error E_RUNTIME
fi
readonly malicious_input_root
case "$evaluator" in "$runtime"/evaluator.json) ;; *) emit_error E_RUNTIME ;; esac

generation=g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43
modules="$runtime/core/v2/generations/$generation/modules"
program="$runtime/program.jq"
catalog="$runtime/catalog.json"
core_front_door="$runtime/scripts/core-contract.sh"
scanner="$runtime/orchestrator/v1/scan-state.sh"
scanner_sha256=556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5
planner="$runtime/orchestrator/v1/reconciliation-plan.jq"
planner_sha256=03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4
sandbox_evaluator="$runtime/control/v1/evaluate-sandbox.sh"
sandbox_sha256=8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb
risk_gates_evaluator="$runtime/control/v1/evaluate-risk-gates.sh"
risk_gates_sha256=0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8
duty_evaluator="$runtime/control/v1/evaluate-duty.sh"
duty_sha256=146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa
normalizer_shas='{"codex-cli-producer":"dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25","codex-native-reviewer":"7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603","github-actions-ci":"690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7","github-forge":"b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be","gitlab-forge":"ff2ec298eef102f94f28995f5306adeba8e078d19e4c22860c3b167cd9b7c37a"}'
jq_bin="$runtime/bin/jq"
work="$runtime_parent/work"
program_sha256=efe2004d9d44c9fd3d9e6bf3e73edd9570d785af6c85f1e550fe0d7ff9fed413
review_approval_sha256=none
driver_sha256=$(sha256_path "$self") || emit_error E_RUNTIME

verify_review_files() {
  local digest path
  [ -f "$runtime/review-files.tsv" ] && [ ! -L "$runtime/review-files.tsv" ] || return 1
  while IFS=$'\t' read -r digest path; do
    verify_hash "$digest" "$runtime/$path" || return 1
  done < "$runtime/review-files.tsv"
}
verify_review_approval() {
  if [ "$review_approval_sha256" != none ]; then
    verify_hash "$review_approval_sha256" "$runtime/evals/v1/seeds/reviewer-severity/approval.json" || return 1
  fi
}
verify_record_runtime() {
  local record_generation schema_path
  verify_hash d164a102919f42ef002e93c8b515b58028604819e6c09b87c6e4afadb0bbcce4 \
    "$runtime/evals/v1/framework.jq" &&
  verify_hash 51770c5597d55bf05020502796810637bfbe697038a541ea6124530c0fffe55c \
    "$runtime/evals/v1/run.sh" || return 1
  record_generation=$("$jq_bin" -er '
    if type == "array" and length >= 1 and all(.[];
      .semantic_identity == "core.contracts.v2" and
      (.generation_id | type == "string" and test("\\Ag-[0-9a-f]{64}\\z")))
    then .[-1].generation_id else error("E_STALE") end
  ' "$runtime/core/v2/generation-registry.json" 2>/dev/null) || return 1
  schema_path="core/v2/generations/$record_generation/modules/schema.jq"
  "$jq_bin" -e --arg path "$schema_path" '
    [.body.core_closure[] | select(.path == $path)] ==
      [{path:$path,sha256:"8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade"}]
  ' "$evaluator" >/dev/null 2>&1 || return 1
  verify_hash 8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade \
    "$runtime/$schema_path"
}
review_check() {
  local operation=$1 candidate=$2 token=$3 checked
  checked=$(run_program "$operation" "$work/empty-observations.json" "$candidate" 2>/dev/null) ||
    emit_error E_RUNTIME
  [ "$checked" = true ] || emit_error "$token"
}
replay_review_cases() {
  local approval="$runtime/evals/v1/seeds/reviewer-severity/approval.json"
  local bundle="$work/review-bundle.json" labels="$work/review-labels.json"
  local report="$work/review-report.json" error="$work/review-record.err"
  local section expected actual platform jq_asset record_tmp record_status token canonical
  [ "$review_approval_sha256" != none ] || emit_error E_STALE
  verify_hash "$review_approval_sha256" "$approval" || emit_error E_STALE
  single_root "$approval" || emit_error E_PARSE
  "$jq_bin" -S -c . "$approval" >"$work/review-approval.canonical" 2>/dev/null || emit_error E_PARSE
  /usr/bin/cmp -s "$approval" "$work/review-approval.canonical" || emit_error E_CANONICAL
  review_check validate-review-approval "$approval" E_SHAPE
  for section in bundle labels; do
    "$jq_bin" -S -c --arg section "$section" '.body.shared[$section].content' "$input" \
      >"$work/review-$section.json" || emit_error E_RUNTIME
    expected=$("$jq_bin" -r --arg section "$section" '.body.shared[$section].sha256' "$input") ||
      emit_error E_RUNTIME
    actual=$(sha256_path "$work/review-$section.json") || emit_error E_RUNTIME
    [ "$actual" = "$expected" ] || emit_error E_RELATION
  done
  [ -f "$labels" ] || emit_error E_RUNTIME
  review_check validate-review-anchor "$approval" E_RELATION
  platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m) || emit_error E_RUNTIME
  case "$platform" in
    Linux:x86_64) jq_asset=jq-linux64 ;;
    Darwin:x86_64|Darwin:arm64) jq_asset=jq-osx-amd64 ;;
    *) emit_error E_RUNTIME ;;
  esac
  record_tmp="$work/record-tmp"
  /bin/mkdir -m 0700 "$record_tmp" "$record_tmp/ystack-portable-core-jq16" || emit_error E_RUNTIME
  /bin/cp "$jq_bin" "$record_tmp/ystack-portable-core-jq16/$jq_asset" || emit_error E_RUNTIME
  /bin/chmod 0500 "$record_tmp/ystack-portable-core-jq16/$jq_asset" || emit_error E_RUNTIME
  record_status=0
  /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin TMPDIR="$record_tmp" \
    /bin/bash "$runtime/evals/v1/run.sh" evaluate "$bundle" \
    </dev/null >"$report" 2>"$error" || record_status=$?
  if [ "$record_status" -ne 0 ]; then
    [ ! -s "$report" ] || emit_error E_RUNTIME
    token=$(/bin/cat "$error") || emit_error E_RUNTIME
    case "$token" in
      E_SHAPE|E_STALE|E_RELATION|E_PARSE|E_CANONICAL|E_LIMIT|E_RUNTIME) emit_error "$token" ;;
      *) emit_error E_RUNTIME ;;
    esac
  fi
  [ ! -s "$error" ] || emit_error E_RUNTIME
  single_root "$report" || emit_error E_RUNTIME
  canonical="$work/review-report.canonical"
  "$jq_bin" -S -c . "$report" >"$canonical" 2>/dev/null || emit_error E_RUNTIME
  /usr/bin/cmp -s "$report" "$canonical" || emit_error E_RUNTIME
  "$jq_bin" -e '.body.cases | length == 1 and .[0].value.body.execution_kind == "model"' \
    "$bundle" >/dev/null 2>&1 || emit_error E_RELATION
  review_check validate-review-report "$report" E_RUNTIME
  review_check validate-review-relations "$approval" E_RELATION
  verify_review_approval || emit_error E_STALE
  verify_review_files || emit_error E_RELATION
  i=0
  while [ "$i" -lt "$case_count" ]; do
    case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input") || emit_error E_RUNTIME
    observation=$("$jq_bin" -S -c --arg id "$case_id" '
      [.body.cases[0].trials[] | select(.attempt_id == $id)] as $trials |
      if ($trials | length) == 1 then
        {case_id:$id,disposition:"human-graded",error_token:{state:"absent"},status:$trials[0].status}
      else error("E_RUNTIME") end
    ' "$report") || emit_error E_RUNTIME
    record_observation "$observation"
    i=$((i + 1))
  done
}

verify_runtime() {
  verify_hash "$program_sha256" "$program" &&
  verify_hash 0239138447a8f9fd420cb3c5da31660d8f75c85099d80d89a040dce2878a4cac "$catalog" &&
  verify_hash 3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94 \
    "$runtime/core/v2/generation-registry.json" &&
  verify_hash 65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a \
    "$runtime/core/v2/generations/$generation/contracts.jq" &&
  verify_hash dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8 \
    "$runtime/core/v2/generations/$generation/core-ingress.sh" &&
  verify_hash c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207 \
    "$modules/profile_graph.jq" &&
  verify_hash 8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281 \
    "$modules/result_facts.jq" &&
  verify_hash ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46 \
    "$modules/result_truth.jq" &&
  verify_hash 8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade \
    "$modules/schema.jq" &&
  verify_hash 6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e \
    "$modules/stage_request.jq" &&
  verify_hash b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 \
    "$core_front_door" &&
  verify_hash "$scanner_sha256" "$scanner" &&
  verify_hash "$planner_sha256" "$planner" &&
  verify_hash "$sandbox_sha256" "$sandbox_evaluator" &&
  verify_hash "$risk_gates_sha256" "$risk_gates_evaluator" &&
  verify_hash 3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e \
    "$runtime/control/v1/risk-gates-policy.json" &&
  verify_hash 8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5 \
    "$runtime/control/v1/risk-gates-decision.json" &&
  verify_hash d00fccd8e31b770c6df01fba17e3cc315d58edfbbf0a8055d66d537dc6ad21ff \
    "$runtime/control/v1/risk-gates.jq" &&
  verify_hash b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9 \
    "$runtime/control/v1/duty-separation-policy.json" &&
  verify_hash 4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99 \
    "$runtime/control/v1/duty-separation-decision.json" &&
  verify_hash b4e480748dd4fb7dec769b25f0f7649b0e5dc31f9de438bba690e9eab6ac236c \
    "$runtime/control/v1/duty-separation.jq" &&
  verify_hash "$duty_sha256" "$duty_evaluator" &&
  verify_hash dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25 \
    "$runtime/adapters/codex-cli-producer/v1/normalize.jq" &&
  verify_hash ff2ec298eef102f94f28995f5306adeba8e078d19e4c22860c3b167cd9b7c37a \
    "$runtime/adapters/gitlab-forge/v1/normalize.jq" &&
  verify_hash 7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603 \
    "$runtime/adapters/codex-native-reviewer/v1/normalize.jq" &&
  verify_hash 690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7 \
    "$runtime/adapters/github-actions-ci/v1/normalize.jq" &&
  verify_hash b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be \
    "$runtime/adapters/github-forge/v1/normalize.jq" &&
  verify_hash 2be97550574ee4522fc0bd14780c92dee3c1b455f2c04b7763b0e437665a8d58 \
    "$runtime/control/v1/policy-set.jq" &&
  verify_hash c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd \
    "$runtime/control/v1/sandbox-decision.json" &&
  verify_hash 4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e \
    "$runtime/control/v1/sandbox-policy.json" &&
  verify_hash 83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3 \
    "$runtime/control/v1/sandbox.jq" &&
  verify_hash cf173ad0eaa08244bf636e3937845e894b21f14291fc5e66753e8673bdd2bd2a \
    "$runtime/control/v1/validate.sh" &&
  verify_hash 5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b \
    "$runtime/orchestrator/v1/state-scanner-driver.sh" &&
  verify_hash 9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb \
    "$runtime/orchestrator/v1/state-scanner-launcher.sh" &&
  verify_hash 722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae \
    "$runtime/orchestrator/v1/state-scanner.jq" &&
  verify_record_runtime &&
  verify_review_approval &&
  verify_hash "$evaluator_sha256" "$evaluator" &&
  verify_hash "$program_seed_sha" "$input_document"
}
# The program sees exactly the documents named here. A dashboard run swaps the
# seed set, evaluator, and result documents per pair; every other run uses the
# driver's own.
program_evaluator=$evaluator
program_evaluator_sha=$evaluator_sha256
program_seed_sha=$seed_set_sha256
program_observed_at=$observed_at
seed_docs_file=$input_document
result_docs_file=$input_document
result_shas_json='[]'
verify_runtime || emit_error E_STALE
[ -x "$jq_bin" ] && [ ! -L "$jq_bin" ] &&
  [ "$("$jq_bin" --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME
[ -d "$work" ] && [ ! -L "$work" ] || emit_error E_RUNTIME

run_program() {
  "$jq_bin" -S -c -n -L "$modules" \
    --arg evals_operation "$1" \
    --arg program_sha256 "$program_sha256" --arg driver_sha256 "$driver_sha256" \
    --arg catalog_sha256 0239138447a8f9fd420cb3c5da31660d8f75c85099d80d89a040dce2878a4cac \
    --arg evaluator_sha256 "$program_evaluator_sha" \
    --arg seed_set_sha256 "$program_seed_sha" \
    --arg tool_sha256 b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 \
    --arg scanner_sha256 "$scanner_sha256" --arg planner_sha256 "$planner_sha256" \
    --arg sandbox_sha256 "$sandbox_sha256" --argjson normalizer_shas "$normalizer_shas" \
    --arg risk_gates_sha256 "$risk_gates_sha256" --arg duty_sha256 "$duty_sha256" \
    --arg observed_at "$program_observed_at" \
    --slurpfile catalog_docs "$catalog" \
    --slurpfile seed_set_docs "$seed_docs_file" \
    --slurpfile observation_docs "$2" \
    --slurpfile evaluator_docs "$program_evaluator" \
    --slurpfile candidate_docs "$3" \
    --slurpfile result_docs "$result_docs_file" --argjson result_shas "$result_shas_json" \
    -f "$program"
}
single_root() {
  "$jq_bin" -e -n --slurpfile roots "$1" '($roots | length) == 1' >/dev/null 2>&1
}

# A dashboard aggregates one to sixteen (seed set, run result) pairs staged by the
# launcher. Each result must validate against its own seed set and this exact
# program before it counts; the dashboard itself is then built and re-validated.
run_dashboard() {
  local manifest="$input/manifest.json" pair_count j pair_seed_doc pair_result_doc dashboard
  local work_root=$work dashboard_input=$input pair_observed_at
  single_root "$manifest" || emit_error E_PARSE
  pair_count=$("$jq_bin" -r 'if type == "array" then length else empty end' "$manifest") ||
    emit_error E_RUNTIME
  [[ "$pair_count" =~ ^([1-9]|1[0-6])$ ]] || emit_error E_SHAPE
  : > "$work/seeds.jsonl" || emit_error E_RUNTIME
  : > "$work/results.jsonl" || emit_error E_RUNTIME
  j=0
  while [ "$j" -lt "$pair_count" ]; do
    pair_seed_doc="$input/seed-$j.json"
    pair_result_doc="$input/result-$j.json"
    [ -f "$pair_seed_doc" ] && [ ! -L "$pair_seed_doc" ] && [ -f "$pair_result_doc" ] &&
      [ ! -L "$pair_result_doc" ] || emit_error E_RUNTIME
    [ "$(sha256_path "$pair_seed_doc")" = "$("$jq_bin" -r ".[$j].seed_sha256" "$manifest")" ] &&
      [ "$(sha256_path "$pair_result_doc")" = "$("$jq_bin" -r ".[$j].result_sha256" "$manifest")" ] ||
      emit_error E_RELATION
    single_root "$pair_seed_doc" || emit_error E_PARSE
    single_root "$pair_result_doc" || emit_error E_PARSE
    # Byte comparison: command substitution would hide trailing whitespace.
    "$jq_bin" -S -c . "$pair_result_doc" > "$work/pair-$j-canonical.json" 2>/dev/null ||
      emit_error E_CANONICAL
    /usr/bin/cmp -s "$pair_result_doc" "$work/pair-$j-canonical.json" || emit_error E_CANONICAL
    # The seed set is replayed here, in this runtime, at the result's own
    # recorded time. Only a result the replay reproduces byte for byte counts;
    # nothing embedded in the supplied result is trusted.
    pair_observed_at=$("$jq_bin" -r '.body.observed_at' "$pair_result_doc") || emit_error E_RUNTIME
    [[ "$pair_observed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
      emit_error E_SHAPE
    work="$work_root/pair-$j"
    /bin/mkdir -m 0700 "$work" || emit_error E_RUNTIME
    /usr/bin/printf '[]\n' > "$work/empty-observations.json" || emit_error E_RUNTIME
    /usr/bin/printf '{}\n' > "$work/empty-candidate.json" || emit_error E_RUNTIME
    input=$pair_seed_doc
    input_document=$pair_seed_doc
    program_seed_sha=$(sha256_path "$pair_seed_doc") || emit_error E_RUNTIME
    program_observed_at=$pair_observed_at
    produce_result
    /usr/bin/cmp -s "$work/run-result.json" "$pair_result_doc" || emit_error E_RELATION
    work=$work_root
    input=$dashboard_input
    input_document="$dashboard_input/manifest.json"
    program_seed_sha=$seed_set_sha256
    program_observed_at=$observed_at
    # Re-emitted one document per line so adjacent files never run together.
    "$jq_bin" -S -c . "$pair_seed_doc" >> "$work/seeds.jsonl" || emit_error E_RUNTIME
    "$jq_bin" -S -c . "$pair_result_doc" >> "$work/results.jsonl" || emit_error E_RUNTIME
    j=$((j + 1))
  done
  seed_docs_file="$work/seeds.jsonl"
  result_docs_file="$work/results.jsonl"
  result_shas_json=$("$jq_bin" -c 'map(.result_sha256)' "$manifest") || emit_error E_RUNTIME
  "$jq_bin" -e -n --argjson shas "$result_shas_json" \
    '$shas | length == (unique | length)' >/dev/null 2>&1 || emit_error E_RUNTIME
  local distinct_cases
  distinct_cases=$("$jq_bin" -s '[.[].body.cases[] | [.family_id,.case_id]] |
    length == (unique | length)' "$result_docs_file") || emit_error E_RUNTIME
  [ "$distinct_cases" = true ] || emit_error E_SHAPE
  dashboard="$work/dashboard.json"
  run_program build-dashboard "$work/empty-observations.json" "$work/empty-candidate.json" \
    > "$dashboard" 2>/dev/null || emit_error E_RUNTIME
  [ "$(run_program validate-dashboard "$work/empty-observations.json" "$dashboard" 2>/dev/null)" = true ] ||
    emit_error E_RUNTIME
  verify_runtime || emit_error E_STALE
  verify_review_files || emit_error E_RELATION
  /bin/cat "$dashboard" || emit_error E_RUNTIME
  exit 0
}

/usr/bin/printf '[]\n' > "$work/empty-observations.json" || emit_error E_RUNTIME
/usr/bin/printf '{}\n' > "$work/empty-candidate.json" || emit_error E_RUNTIME
# Caller input must be one parseable JSON root before any contract runs, so a
# broken file reads as a parse error and nothing else.
single_root "$input_document" || emit_error E_PARSE
seed_docs_file="$work/empty-observations.json"
result_docs_file="$work/empty-observations.json"
[ "$(run_program validate-catalog "$work/empty-observations.json" \
      "$work/empty-candidate.json" 2>/dev/null)" = true ] || emit_error E_STALE
record_observation() {
  if [ "$i" -gt 0 ]; then /usr/bin/printf ',' >> "$observations" || emit_error E_RUNTIME; fi
  /usr/bin/printf '%s' "$1" >> "$observations" || emit_error E_RUNTIME
}

# Orchestrator snapshots replay through the real state scanner. The scanner
# finds its jq under TMPDIR and its core under its own repo root, so both are
# staged inside the private runtime; nothing outside it is read.
replay_scanner_cases() {
  local platform jq_asset scanner_tmp snapshot_doc repository_id commit_id
  local scan_out scan_err scan_status classification token observation
  platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m) || emit_error E_RUNTIME
  case "$platform" in
    Linux:x86_64) jq_asset=jq-linux64 ;;
    Darwin:x86_64|Darwin:arm64) jq_asset=jq-osx-amd64 ;;
    *) emit_error E_RUNTIME ;;
  esac
  scanner_tmp="$work/scanner-tmp"
  /bin/mkdir -m 0700 "$scanner_tmp" "$scanner_tmp/ystack-portable-core-jq16" ||
    emit_error E_RUNTIME
  /bin/cp "$jq_bin" "$scanner_tmp/ystack-portable-core-jq16/$jq_asset" || emit_error E_RUNTIME
  /bin/chmod 0500 "$scanner_tmp/ystack-portable-core-jq16/$jq_asset" || emit_error E_RUNTIME
  i=0
  while [ "$i" -lt "$case_count" ]; do
    case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input") || emit_error E_RUNTIME
    snapshot_doc="$work/snapshot-$i.json"
    "$jq_bin" -S -c ".body.cases[$i].snapshot.content" "$input" > "$snapshot_doc" ||
      emit_error E_RUNTIME
    [ "$(sha256_path "$snapshot_doc")" = \
      "$("$jq_bin" -r ".body.cases[$i].snapshot.sha256" "$input")" ] || emit_error E_RELATION
    repository_id=$("$jq_bin" -r ".body.cases[$i].expected_revision.repository_id" "$input") ||
      emit_error E_RUNTIME
    commit_id=$("$jq_bin" -r ".body.cases[$i].expected_revision.commit_id" "$input") ||
      emit_error E_RUNTIME
    scan_out="$work/scan-$i.out"
    scan_err="$work/scan-$i.err"
    /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin TMPDIR="$scanner_tmp" \
      /bin/bash "$scanner" scan "$repository_id" "$commit_id" "$snapshot_doc" \
      </dev/null >"$scan_out" 2>"$scan_err"
    scan_status=$?
    if [ "$scan_status" -eq 0 ]; then
      [ ! -s "$scan_err" ] || emit_error E_RUNTIME
      classification=$("$jq_bin" -S -c '
        if (.body.classifications | length) == 1 then
          .body.classifications[0] |
          {action:.recovery.action,class:.class,reason_id:.recovery.reason_id}
        else empty end' "$scan_out") || emit_error E_RUNTIME
      [ -n "$classification" ] || emit_error E_RELATION
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" \
        --argjson classification "$classification" \
        '{case_id:$case_id,disposition:"observed",
          classification:{state:"present",value:$classification},
          error_token:{state:"absent"}}') || emit_error E_RUNTIME
    else
      [ ! -s "$scan_out" ] || emit_error E_RUNTIME
      token=$(/bin/cat "$scan_err" 2>/dev/null) || emit_error E_RUNTIME
      case "$token" in
        E_CANONICAL|E_LIMIT|E_PARSE|E_RELATION|E_RUNTIME|E_SHAPE|E_STALE|E_USAGE) ;;
        *) emit_error E_RUNTIME ;;
      esac
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --arg token "$token" \
        '{case_id:$case_id,disposition:"rejected",classification:{state:"absent"},
          error_token:{state:"present",value:$token}}') || emit_error E_RUNTIME
    fi
    record_observation "$observation"
    i=$((i + 1))
  done
}

# Decision claims replay through the real risk-gates evaluator, which regenerates
# the duty-separation evaluation and validates the core tuple from a mirror it
# builds out of this runtime. Verdict and reason set are recorded; a refusal by
# its one token.
replay_risk_gates_cases() {
  local risk_tmp doc member eval_out eval_err eval_status evaluation observation token
  local -a docs
  risk_tmp="$work/risk-gates-tmp"
  /bin/mkdir -m 0700 "$risk_tmp" || emit_error E_RUNTIME
  i=0
  while [ "$i" -lt "$case_count" ]; do
    case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input") || emit_error E_RUNTIME
    docs=()
    for member in policy_set request resolved_profile result duty claim; do
      doc="$work/risk-$member-$i.json"
      "$jq_bin" -S -c ".body.cases[$i].inputs.$member.content" "$input" > "$doc" ||
        emit_error E_RUNTIME
      [ "$(sha256_path "$doc")" = \
        "$("$jq_bin" -r ".body.cases[$i].inputs.$member.sha256" "$input")" ] ||
        emit_error E_RELATION
      docs+=("$doc")
    done
    eval_out="$work/risk-$i.out"
    eval_err="$work/risk-$i.err"
    /usr/bin/env -i LC_ALL=C PATH="$runtime/bin:/usr/bin:/bin" TMPDIR="$risk_tmp" \
      /bin/bash "$risk_gates_evaluator" evaluate "${docs[@]}" \
      </dev/null >"$eval_out" 2>"$eval_err"
    eval_status=$?
    if [ "$eval_status" -eq 0 ]; then
      [ ! -s "$eval_err" ] || emit_error E_RUNTIME
      evaluation=$("$jq_bin" -S -c '{reason_ids:.body.reason_ids,verdict:.body.verdict}' \
        "$eval_out") || emit_error E_RUNTIME
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" \
        --argjson evaluation "$evaluation" \
        '{case_id:$case_id,disposition:"evaluated",
          evaluation:{state:"present",value:$evaluation},
          error_token:{state:"absent"}}') || emit_error E_RUNTIME
    else
      [ ! -s "$eval_out" ] || emit_error E_RUNTIME
      token=$(/bin/cat "$eval_err" 2>/dev/null) || emit_error E_RUNTIME
      case "$token" in
        E_DUTY|E_LIMIT|E_RELATION|E_RUNTIME|E_USAGE) ;;
        *) emit_error E_RUNTIME ;;
      esac
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --arg token "$token" \
        '{case_id:$case_id,disposition:"rejected",evaluation:{state:"absent"},
          error_token:{state:"present",value:$token}}') || emit_error E_RUNTIME
    fi
    record_observation "$observation"
    i=$((i + 1))
  done
}

# Four-document tuples replay through the real duty-separation evaluator, which
# validates the policy set with its own validator pair and the core tuple against
# a mirror it builds out of this runtime. Verdict and reason set are recorded; a
# refusal by its one token.
replay_duty_cases() {
  local duty_tmp doc member eval_out eval_err eval_status evaluation observation token
  local -a docs
  duty_tmp="$work/duty-tmp"
  /bin/mkdir -m 0700 "$duty_tmp" || emit_error E_RUNTIME
  i=0
  while [ "$i" -lt "$case_count" ]; do
    case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input") || emit_error E_RUNTIME
    docs=()
    for member in policy_set request resolved_profile result; do
      doc="$work/duty-$member-$i.json"
      "$jq_bin" -S -c ".body.cases[$i].inputs.$member.content" "$input" > "$doc" ||
        emit_error E_RUNTIME
      [ "$(sha256_path "$doc")" = \
        "$("$jq_bin" -r ".body.cases[$i].inputs.$member.sha256" "$input")" ] ||
        emit_error E_RELATION
      docs+=("$doc")
    done
    eval_out="$work/duty-$i.out"
    eval_err="$work/duty-$i.err"
    /usr/bin/env -i LC_ALL=C PATH="$runtime/bin:/usr/bin:/bin" TMPDIR="$duty_tmp" \
      /bin/bash "$duty_evaluator" evaluate "${docs[@]}" \
      </dev/null >"$eval_out" 2>"$eval_err"
    eval_status=$?
    if [ "$eval_status" -eq 0 ]; then
      [ ! -s "$eval_err" ] || emit_error E_RUNTIME
      evaluation=$("$jq_bin" -S -c '{reason_ids:.body.reason_ids,verdict:.body.verdict}' \
        "$eval_out") || emit_error E_RUNTIME
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" \
        --argjson evaluation "$evaluation" \
        '{case_id:$case_id,disposition:"evaluated",
          evaluation:{state:"present",value:$evaluation},
          error_token:{state:"absent"}}') || emit_error E_RUNTIME
    else
      [ ! -s "$eval_out" ] || emit_error E_RUNTIME
      token=$(/bin/cat "$eval_err" 2>/dev/null) || emit_error E_RUNTIME
      case "$token" in
        E_CORE|E_LIMIT|E_POLICY_SET|E_RELATION|E_RUNTIME|E_USAGE) ;;
        *) emit_error E_RUNTIME ;;
      esac
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --arg token "$token" \
        '{case_id:$case_id,disposition:"rejected",evaluation:{state:"absent"},
          error_token:{state:"present",value:$token}}') || emit_error E_RUNTIME
    fi
    record_observation "$observation"
    i=$((i + 1))
  done
}

# Provider snapshots replay through the one default normalizer the case names,
# pure jq with no modules. The generic state, reason, and stale bindings are
# recorded; a refusal is recorded by the normalizer's own error id.
replay_normalizer_cases() {
  local normalizer input_doc norm_out norm_err norm_status normalization token observation
  i=0
  while [ "$i" -lt "$case_count" ]; do
    case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input") || emit_error E_RUNTIME
    normalizer=$("$jq_bin" -r ".body.cases[$i].normalizer" "$input") || emit_error E_RUNTIME
    case "$normalizer" in
      codex-cli-producer|codex-native-reviewer|github-actions-ci|github-forge|gitlab-forge) ;;
      *) emit_error E_SHAPE ;;
    esac
    input_doc="$work/normalizer-input-$i.json"
    "$jq_bin" -S -c ".body.cases[$i].input.content" "$input" > "$input_doc" ||
      emit_error E_RUNTIME
    [ "$(sha256_path "$input_doc")" = \
      "$("$jq_bin" -r ".body.cases[$i].input.sha256" "$input")" ] || emit_error E_RELATION
    norm_out="$work/normalizer-$i.out"
    norm_err="$work/normalizer-$i.err"
    "$jq_bin" -L "$modules" -S -c -f "$runtime/adapters/$normalizer/v1/normalize.jq" "$input_doc" \
      </dev/null >"$norm_out" 2>"$norm_err"
    norm_status=$?
    if [ "$norm_status" -eq 0 ]; then
      [ ! -s "$norm_err" ] || emit_error E_RUNTIME
      # A producer normalizer has no bindings to go stale; its set is empty.
      normalization=$("$jq_bin" -S -c '{reason_id,stale_bindings:(.stale_bindings // []),state}' \
        "$norm_out") || emit_error E_RUNTIME
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" \
        --argjson normalization "$normalization" \
        '{case_id:$case_id,disposition:"normalized",
          normalization:{state:"present",value:$normalization},
          error_token:{state:"absent"}}') || emit_error E_RUNTIME
    else
      [ ! -s "$norm_out" ] || emit_error E_RUNTIME
      token=$(/bin/cat "$norm_err" 2>/dev/null) || emit_error E_RUNTIME
      token=${token##*: }
      case "$token" in
        codex-reviewer.invalid-envelope|codex-reviewer.invalid-snapshot) ;;
        codex-reviewer.invalid-trust-context|github-actions-ci.invalid-envelope) ;;
        github-actions-ci.invalid-snapshot|github-actions-ci.invalid-trust-context) ;;
        github-actions-ci.provider-contradiction|github-forge.invalid-envelope) ;;
        github-forge.invalid-snapshot|github-forge.invalid-trust-context) ;;
        gitlab-forge.invalid-envelope|gitlab-forge.invalid-snapshot) ;;
        gitlab-forge.invalid-trust-context|E_SHAPE|E_STALE|E_TRUST) ;;
        *) emit_error E_RUNTIME ;;
      esac
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --arg token "$token" \
        '{case_id:$case_id,disposition:"rejected",normalization:{state:"absent"},
          error_token:{state:"present",value:$token}}') || emit_error E_RUNTIME
    fi
    record_observation "$observation"
    i=$((i + 1))
  done
}

# Boundary claims replay through the real sandbox-policy evaluator, which finds
# its jq on PATH and its policy beside itself; both come from the private runtime.
replay_sandbox_cases() {
  local sandbox_tmp set_doc duty_doc claim_doc eval_out eval_err eval_status
  local evaluation observation token
  sandbox_tmp="$work/sandbox-tmp"
  /bin/mkdir -m 0700 "$sandbox_tmp" || emit_error E_RUNTIME
  i=0
  while [ "$i" -lt "$case_count" ]; do
    case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input") || emit_error E_RUNTIME
    set_doc="$work/policy-set-$i.json"
    duty_doc="$work/duty-$i.json"
    claim_doc="$work/claim-$i.json"
    for member in policy_set duty claim; do
      case "$member" in
        policy_set) target=$set_doc ;;
        duty) target=$duty_doc ;;
        claim) target=$claim_doc ;;
      esac
      "$jq_bin" -S -c ".body.cases[$i].inputs.$member.content" "$input" > "$target" ||
        emit_error E_RUNTIME
      [ "$(sha256_path "$target")" = \
        "$("$jq_bin" -r ".body.cases[$i].inputs.$member.sha256" "$input")" ] ||
        emit_error E_RELATION
    done
    eval_out="$work/sandbox-$i.out"
    eval_err="$work/sandbox-$i.err"
    /usr/bin/env -i LC_ALL=C PATH="$runtime/bin:/usr/bin:/bin" TMPDIR="$sandbox_tmp" \
      /bin/bash "$sandbox_evaluator" evaluate "$set_doc" "$duty_doc" "$claim_doc" \
      </dev/null >"$eval_out" 2>"$eval_err"
    eval_status=$?
    if [ "$eval_status" -eq 0 ]; then
      [ ! -s "$eval_err" ] || emit_error E_RUNTIME
      evaluation=$("$jq_bin" -S -c '{reason_ids:.body.reason_ids,verdict:.body.verdict}' \
        "$eval_out") || emit_error E_RUNTIME
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" \
        --argjson evaluation "$evaluation" \
        '{case_id:$case_id,disposition:"evaluated",
          evaluation:{state:"present",value:$evaluation},
          error_token:{state:"absent"}}') || emit_error E_RUNTIME
    else
      [ ! -s "$eval_out" ] || emit_error E_RUNTIME
      token=$(/bin/cat "$eval_err" 2>/dev/null) || emit_error E_RUNTIME
      case "$token" in
        E_CANONICAL|E_LIMIT|E_PARSE|E_POLICY_SET|E_RELATION|E_RUNTIME|E_USAGE) ;;
        *) emit_error E_RUNTIME ;;
      esac
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --arg token "$token" \
        '{case_id:$case_id,disposition:"rejected",evaluation:{state:"absent"},
          error_token:{state:"present",value:$token}}') || emit_error E_RUNTIME
    fi
    record_observation "$observation"
    i=$((i + 1))
  done
}

# Planner bundles replay through the real reconciliation planner, pure jq over
# the private modules. Exactly which stage, request, operation, and attempt it
# would deliver, defer, or suppress, and which stages it hands to an operator,
# is recorded; a refusal is recorded by its one token.
replay_planner_cases() {
  local input_doc plan_out plan_err plan_status summary observation
  i=0
  while [ "$i" -lt "$case_count" ]; do
    case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input") || emit_error E_RUNTIME
    input_doc="$work/plan-input-$i.json"
    "$jq_bin" -S -c ".body.cases[$i].input.content" "$input" > "$input_doc" ||
      emit_error E_RUNTIME
    [ "$(sha256_path "$input_doc")" = \
      "$("$jq_bin" -r ".body.cases[$i].input.sha256" "$input")" ] || emit_error E_RELATION
    plan_out="$work/plan-$i.out"
    plan_err="$work/plan-$i.err"
    "$jq_bin" -L "$modules" -S -c -f "$planner" "$input_doc" \
      </dev/null >"$plan_out" 2>"$plan_err"
    plan_status=$?
    if [ "$plan_status" -eq 0 ]; then
      [ ! -s "$plan_err" ] || emit_error E_RUNTIME
      summary=$("$jq_bin" -S -c '
        def item: .delivery_key |
          {attempt_number,operation,request_sha256,stage_key};
        {deliveries:[.body.deliveries[] | item + {delivery_mode}],
         deferred:[.body.deferred[] | item + {reason_id}],
         suppressed:[.body.suppressed[] | item + {reason_id}],
         operator_messages:[.body.operator_messages[] |
           {action:.recovery.action,class,stage_key}]}' "$plan_out") || emit_error E_RUNTIME
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --argjson plan "$summary" \
        '{case_id:$case_id,disposition:"planned",plan:{state:"present",value:$plan},
          error_token:{state:"absent"}}') || emit_error E_RUNTIME
    else
      [ ! -s "$plan_out" ] || emit_error E_RUNTIME
      case "$(/bin/cat "$plan_err" 2>/dev/null)" in
        *E_RECONCILIATION_INPUT*) ;;
        *) emit_error E_RUNTIME ;;
      esac
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" \
        '{case_id:$case_id,disposition:"rejected",plan:{state:"absent"},
          error_token:{state:"present",value:"E_RECONCILIATION_INPUT"}}') || emit_error E_RUNTIME
    fi
    record_observation "$observation"
    i=$((i + 1))
  done
}

# Canonical documents for one case, each checked against its recorded digest
# before the core sees it. The core is the only judge; the driver only records.
replay_stage_run_cases() {
resolved_doc="$work/resolved.json"
"$jq_bin" -S -c '.body.shared.resolved_profile.content' "$input" > "$resolved_doc" ||
  emit_error E_RUNTIME
[ "$(sha256_path "$resolved_doc")" = \
  "$("$jq_bin" -r '.body.shared.resolved_profile.sha256' "$input")" ] ||
  emit_error E_RELATION
i=0
while [ "$i" -lt "$case_count" ]; do
  case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input") || emit_error E_RUNTIME
  role=$("$jq_bin" -r ".body.cases[$i].request_role" "$input") || emit_error E_RUNTIME
  case "$role" in producer|reviewer|verifier) ;; *) emit_error E_SHAPE ;; esac
  request_doc="$work/request-$i.json"
  result_doc="$work/result-$i.json"
  "$jq_bin" -S -c --arg role "$role" '.body.shared.requests[$role].content' \
    "$input" > "$request_doc" || emit_error E_RUNTIME
  [ "$(sha256_path "$request_doc")" = \
    "$("$jq_bin" -r --arg role "$role" '.body.shared.requests[$role].sha256' "$input")" ] ||
    emit_error E_RELATION
  "$jq_bin" -S -c ".body.cases[$i].result.content" "$input" > "$result_doc" ||
    emit_error E_RUNTIME
  [ "$(sha256_path "$result_doc")" = \
    "$("$jq_bin" -r ".body.cases[$i].result.sha256" "$input")" ] || emit_error E_RELATION
  status_value=$("$jq_bin" -r '.body.status // empty' "$result_doc") || emit_error E_RUNTIME

  core_err="$work/core-$i.err"
  core_out="$work/core-$i.out"
  /usr/bin/env -i LC_ALL=C PATH="$runtime/bin:/usr/bin:/bin" TMPDIR="$work" \
    /bin/bash "$core_front_door" validate-stage-run \
    "$request_doc" "$resolved_doc" "$result_doc" </dev/null 3>&- >"$core_out" 2>"$core_err"
  core_status=$?
  [ ! -s "$core_out" ] || emit_error E_RUNTIME
  if [ "$core_status" -eq 0 ]; then
    [ ! -s "$core_err" ] || emit_error E_RUNTIME
    case "$status_value" in
      blocked|cancelled|completed|failed|skipped|stale) ;;
      *) emit_error E_RELATION ;;
    esac
    observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --arg status "$status_value" \
      '{case_id:$case_id,disposition:"accepted",status:{state:"present",value:$status},
        error_token:{state:"absent"}}') || emit_error E_RUNTIME
  else
    token=$(/bin/cat "$core_err" 2>/dev/null) || emit_error E_RUNTIME
    case "$token" in
      E_CANONICAL|E_LIMIT|E_PARSE|E_REF|E_RELATION|E_RUNTIME|E_SHAPE|E_USAGE) ;;
      *) emit_error E_RUNTIME ;;
    esac
    observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --arg token "$token" \
      '{case_id:$case_id,disposition:"rejected",status:{state:"absent"},
        error_token:{state:"present",value:$token}}') || emit_error E_RUNTIME
  fi
  record_observation "$observation"
  i=$((i + 1))
done
}

replay_malicious_cases() {
  local replay="$runtime/evals/v1/replay-malicious.py" replay_sha
  local case_doc case_work replay_out replay_err replay_canonical replay_status observation
  [ -n "$malicious_input_root" ] &&
    [ "$seed_source" = shadow.malicious-instructions.v1 ] || emit_error E_RUNTIME
  replay_sha=$("$jq_bin" -er '
    [.body.shadow_closure[] | select(.path == "evals/v1/replay-malicious.py")] as $rows |
    if ($rows | length) == 1 and
       ($rows[0].sha256 | type == "string" and test("\\A[0-9a-f]{64}\\z"))
    then $rows[0].sha256 else error("E_RUNTIME") end
  ' "$program_evaluator" 2>/dev/null) || emit_error E_RUNTIME
  verify_hash "$replay_sha" "$replay" || emit_error E_STALE
  i=0
  while [ "$i" -lt "$case_count" ]; do
    case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input" 2>/dev/null) || emit_error E_RUNTIME
    case "$case_id" in
      malicious.checked-file-bytes|malicious.commit-message) ;;
      malicious.incident-symptom-text|malicious.unread-forge-text) ;;
      *) emit_error E_RUNTIME ;;
    esac
    case_doc="$work/malicious-case-$i.json"
    case_work="$work/malicious-work-$i"
    replay_out="$work/malicious-$i.out"
    replay_err="$work/malicious-$i.err"
    replay_canonical="$work/malicious-$i.canonical"
    (
      set -o noclobber
      "$jq_bin" -S -c ".body.cases[$i]" "$input" >"$case_doc"
    ) 2>/dev/null || emit_error E_RUNTIME
    /bin/mkdir -m 0700 "$case_work" 2>/dev/null || emit_error E_RUNTIME
    (
      set -o noclobber
      : >"$replay_out" && : >"$replay_err" && : >"$replay_canonical"
    ) 2>/dev/null || emit_error E_RUNTIME
    replay_status=0
    /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin TMPDIR="$case_work" \
      /usr/bin/python3 -I -S -B "$replay" "$runtime" "$malicious_input_root" \
      "$case_doc" "$case_work" \
      </dev/null 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- 10>&- \
      >"$replay_out" 2>"$replay_err" || replay_status=$?
    [ "$replay_status" -eq 0 ] && [ ! -s "$replay_err" ] || emit_error E_RUNTIME
    verify_hash "$replay_sha" "$replay" || emit_error E_STALE
    single_root "$replay_out" || emit_error E_RUNTIME
    "$jq_bin" -S -c . "$replay_out" >"$replay_canonical" 2>/dev/null || emit_error E_RUNTIME
    /usr/bin/cmp -s "$replay_out" "$replay_canonical" || emit_error E_RUNTIME
    "$jq_bin" -e --arg case_id "$case_id" '.case_id == $case_id' "$replay_out" \
      >/dev/null 2>&1 || emit_error E_RUNTIME
    observation=$(/bin/cat "$replay_out" 2>/dev/null) || emit_error E_RUNTIME
    record_observation "$observation"
    i=$((i + 1))
  done
}

# One run over the seed set named by $input, into $work/run-result.json. Run mode
# calls it once; dashboard mode calls it once per supplied pair to reproduce
# the supplied result.
produce_result() {
  seed_docs_file=$input
  [ "$(run_program validate-seed-set "$work/empty-observations.json" \
        "$work/empty-candidate.json" 2>/dev/null)" = true ] || emit_error E_SHAPE

  seed_source=$("$jq_bin" -r '.body.seed_source // empty' "$input") || emit_error E_RUNTIME
  if [ -n "$malicious_input_root" ]; then
    [ "$seed_source" = shadow.malicious-instructions.v1 ] || emit_error E_RUNTIME
  elif [ "$seed_source" = shadow.malicious-instructions.v1 ]; then
    emit_error E_RUNTIME
  fi
  case "$seed_source" in
    adapters.provider-normalizers.v1|control.duty-separation.v1) ;;
    control.risk-gates.v1|control.sandbox-policy.v1) ;;
    core.stage-run.v2|reviews.independent-verdicts.v1) ;;
    shadow.malicious-instructions.v1) ;;
    orchestrator.reconciliation-plan.v1|orchestrator.state-scanner.v1) ;;
    *) emit_error E_SHAPE ;;
  esac
  case_count=$("$jq_bin" -r '.body.cases | length' "$input") || emit_error E_RUNTIME
  [[ "$case_count" =~ ^[1-9][0-9]?$ ]] && [ "$case_count" -le 64 ] || emit_error E_SHAPE
  observations="$work/observations.json"
  /usr/bin/printf '[' > "$observations" || emit_error E_RUNTIME

  case "$seed_source" in
    shadow.malicious-instructions.v1) replay_malicious_cases ;;
    reviews.independent-verdicts.v1) replay_review_cases ;;
    core.stage-run.v2) replay_stage_run_cases ;;
    orchestrator.state-scanner.v1) replay_scanner_cases ;;
    control.sandbox-policy.v1) replay_sandbox_cases ;;
    control.risk-gates.v1) replay_risk_gates_cases ;;
    control.duty-separation.v1) replay_duty_cases ;;
    adapters.provider-normalizers.v1) replay_normalizer_cases ;;
    *) replay_planner_cases ;;
  esac
  /usr/bin/printf ']\n' >> "$observations" || emit_error E_RUNTIME

  result="$work/run-result.json"
  run_program build-run-result "$observations" "$work/empty-candidate.json" \
    > "$result" 2>/dev/null || emit_error E_RUNTIME
  [ "$(run_program validate-run-result "$observations" "$result" 2>/dev/null)" = true ] ||
    emit_error E_RUNTIME
}

if [ "$mode" = run ]; then
  produce_result
  verify_runtime || emit_error E_STALE
  verify_review_files || emit_error E_RELATION
  /bin/cat "$work/run-result.json" || emit_error E_RUNTIME
else
  run_dashboard
fi
