#!/bin/bash
set -euo pipefail
export LC_ALL=C
umask 077
root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-shadow-write.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() { /bin/chmod -R u+w -- "$tmp" 2>/dev/null || true; /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT
if [ -x /opt/homebrew/bin/python3.14 ]; then
  python_bin=/opt/homebrew/bin/python3.14
else
  python_bin=$(command -v python3.14 2>/dev/null || command -v python3)
fi
python_bin=$("$python_bin" -I -S -B -c 'import os,sys; print(os.path.realpath(sys.executable))')
cat > "$tmp/writer-tests.py" <<'PY'
def run_writer_tests():
    import copy, signal
    from contextlib import contextmanager
    global scenario_work, scenario_output, scenario_mode, scenario_request
    module_names = ("shadow_writer_test_subject", "ystack_shadow_enforced", "ystack_shadow_consumer")
    module_state = {name: sys.modules.get(name) for name in module_names}
    spec = importlib.util.spec_from_file_location("shadow_writer_test_subject", package / "shadow/v1/write-shadow.py")
    w = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = w
    spec.loader.exec_module(w)
    w.e, w.c = e, c
    w.require, w.canonical, w.sha, w.parse = e.require, e.canonical, e.sha, e.parse
    original_work, original_output = scenario_work, scenario_output
    original_mode, original_request = scenario_mode, scenario_request
    fixture = work / "writer-fixtures"
    fixture.mkdir(mode=0o700)
    counter = 0
    def case(name, mutate=None, frozen_change=None):
        nonlocal counter
        counter += 1
        directory = fixture / (str(counter) + "-" + name)
        directory.mkdir(mode=0o700)
        request_doc = copy.deepcopy(request)
        request_doc["kind"] = "shadow_write_request"
        request_doc["id"] = request_doc["body"]["attempt_id"] = "attempt.write." + str(counter)
        request_doc["body"]["scope_id"] = "scope.fixture-write"
        request_doc["body"]["allowed_paths"] = sorted(
            "ystack-evidence/" + json.loads((output / "incident.json").read_bytes())["id"] + "/" + name
            for name in [*e.EVIDENCE_NAMES, "bundle.json", "README.md", "eval-seed.json"])
        if mutate:
            mutate(request_doc)
        frozen = output
        if frozen_change:
            frozen = directory / "frozen"
            shutil.copytree(output, frozen)
            frozen_change(frozen)
        request_path = directory / "request.json"
        write(request_path, canonical(request_doc), 0o400)
        work_path, output_path = directory / "work", directory / "output"
        work_path.mkdir(mode=0o700)
        output_path.mkdir(mode=0o700)
        return request_path, frozen, work_path, output_path
    def reset():
        native.state = native.module.prepare_state()
        names = ("block_entry", "arm_consumer", "checkpoint", "hold_completion", "block_final",
            "rollback_marker", "commit_completion", "abort_release", "outcome", "prepare_child", "spawn_child",
            "child_fds", "close_child_stdin", "close_child_stdout", "close_child_stderr",
            "observe_child_exit", "reap_child", "term_child_group", "kill_child_group",
            "check_child_group", "child_status")
        native.methods = tuple(getattr(native.state, name) for name in names)
        for name, method in zip(names, native.methods):
            setattr(native, name, method)
        return dataclasses.replace(admission, native=native, module_origins=e._runtime_module_origins())
    class PartialPreparationComplete(Exception):
        pass
    @contextmanager
    def partial_owner():
        sentinel = PartialPreparationComplete()
        try:
            with e.CancellationSignals(reset()):
                yield
                raise sentinel
        except PartialPreparationComplete as exc:
            if exc is not sentinel:
                raise
            ok(native.outcome() == "native-release.failure", "fixture partial boundary uses real abort-release; no L")
    def invoke(paths, refusal=False):
        global scenario_work, scenario_output, scenario_mode, scenario_request
        scenario_work, scenario_output = paths[2], paths[3]
        scenario_mode, scenario_request = "success", paths[0]
        try:
            with partial_owner():
                result = w.prepare(*paths, parent)
        except (e.Refusal, c.Refusal) as exc:
            if not refusal:
                raise
            ok(not (paths[3] / "bundle.json").exists(), "writer refusal leaves no completion: " + str(exc))
            return None
        if refusal:
            raise AssertionError("writer negative unexpectedly accepted")
        ok(not (paths[3] / "bundle.json").exists(), "slice4 never completes outer write bundle")
        return result
    stable_directory = e.stable_directory
    for fail_at, close_error in ((2, False), (3, False), (3, True), (0, False)):
        acquired, attempted = [], []
        first_error, cleanup_error = e.Refusal("E_WORKSPACE"), OSError("fixture close failure")
        class DirectoryOwner:
            def __init__(self, item):
                self.item, self.closes = item, 0
            def __getattr__(self, name):
                return getattr(self.item, name)
            def close(self):
                self.closes += 1
                self.item.close()
                if close_error:
                    raise cleanup_error
        def acquire(path):
            attempted.append(path)
            if len(attempted) == fail_at:
                raise first_error
            owner = DirectoryOwner(stable_directory(path))
            acquired.append(owner)
            return owner
        e.stable_directory = acquire
        owner_paths = case("directory-owner")
        try:
            with partial_owner():
                try:
                    owner = w._Workspace(*owner_paths, parent)
                except e.Refusal as exc:
                    ok(fail_at and exc is first_error, "directory acquisition preserves first refusal")
                    if close_error:
                        ok(exc.__cause__ is cleanup_error, "directory cleanup error remains chained")
                else:
                    ok(not fail_at, "normal directory acquisition succeeds")
                    owner.close()
                    owner.close()
            ok(len(acquired) == (fail_at - 1 if fail_at else 3)
               and all(item.closes == 1 for item in acquired), "every acquired directory closes once; none unacquired")
        finally:
            e.stable_directory = stable_directory
    def digest_directory(directory):
        return {str(path.relative_to(directory)): sha(path.read_bytes())
                for path in directory.rglob("*") if path.is_file()}
    source_before = digest_directory(base / "source.git")
    frozen_before = digest_directory(output)
    original_attempt = store / json.loads((output / "sandbox-request.json").read_bytes())["id"]
    store_before = digest_directory(original_attempt)
    paths = case("positive")
    result = invoke(paths)
    generated = json.loads(result.input_raw)
    first = json.loads((paths[2] / "builder/first.json").read_bytes())
    original = json.loads((output / "materialization-input.json").read_bytes())
    expected_paths = sorted(result.files)
    ok(len(result.files) == 32 and [row["path"] for row in result.write_set] == expected_paths,
       "actual materializer produces all 32 sorted additions")
    ok(all(row["mode"] == "100644" and row["add_only"] for row in result.write_set), "actual additions are all 100644")
    ok(all(result.files[row["path"]] == (output / row["path"].rsplit("/", 1)[1]).read_bytes()
           for row in result.write_set if row["path"].rsplit("/", 1)[1] in w.NAMES), "frozen 30 files copied byte-identically")
    readme = next(raw for name, raw in result.files.items() if name.endswith("/README.md"))
    seed = next(raw for name, raw in result.files.items() if name.endswith("/eval-seed.json"))
    ok(readme == b"Shadow evidence. Publication is withheld.\n", "exact README bytes")
    ok(seed == (paths[2] / "seed/eval-seed-case-stale-moved-artifacts.json").read_bytes(), "real converter sole output is renamed without byte changes")
    seed_doc = json.loads(seed)
    ok(seed_doc["body"]["provenance"]["shadow_record_ref"]["sha256"] == sha((output / "shadow-record.json").read_bytes()), "seed binds frozen original shadow record")
    ok(generated["stage_request"]["sha256"] == sha(canonical(first["stage_request"])), "actual stage request bytes hashed between phases")
    ok(generated["stage_request"]["content"]["body"]["workflow_id"] == "workflow.shadow-evidence-commit"
       and generated["stage_request"]["content"]["body"]["task_class_id"] == "task.commit-shadow-evidence", "exact writer workflow/task")
    ok(all(generated[key] == original[key] for key in ("profile", "resolved_profile", "manifests")), "complete profile graph remains unchanged")
    request_body = generated["stage_request"]["content"]["body"]
    for key in ("requested_by", "source", "base", "target_repository_id", "target_revision", "selection_ref", "repository_context_ref", "resolved_profile_ref"):
        ok(request_body[key] == original["stage_request"]["content"]["body"][key], "original request field retained: " + key)
    payloads = {row["input_id"]: row for row in generated["payloads"]}
    verified = {row["input_id"]: row for row in generated["trust_context"]["verified_payloads"]}
    ok(set(payloads) == set(verified) == {"input.materialize", "input.producer-patch"}, "exact two payload/verified identities")
    for key, row in payloads.items():
        ok(verified[key]["content"] == {"media_type": row["media_type"], "data": row["data"]}
           and verified[key]["sha256"] == sha(row["data"].encode()), "payload raw bytes bind verified digest: " + key)
    contract = json.loads(payloads["input.materialize"]["data"])
    ok(contract["allowed_modes"] == ["100644", "100755"] and contract["allowed_paths"] == expected_paths, "protocol modes retained; exact paths constrained")
    metadata = json.loads((paths[2] / "builder/metadata-final.json").read_bytes())
    for key, raw in c.WRITE_TEXTS.items():
        ok(metadata[key] == sha(raw) and (paths[2] / "builder" / (key + ".txt")).read_bytes() == raw,
           "actual LF text bytes hash: " + key)
    for key, digest_key in (("finish_condition", "finish"), ("verification_instruction", "verify")):
        ref = request_body[key]["ref"]
        ok(ref["decision_record_ref"]["sha256"] == ref["subject_ref"]["value"]["value"]["sha256"]
           == ref["scope_sha256"] == metadata[digest_key], "decision/subject/scope text digest agrees: " + key)
    contract_ref = request_body["operation"]["arguments"]["materialization_contract"]["ref"]
    ok(contract_ref["subject_ref"]["value"]["value"]["sha256"] == sha(payloads["input.materialize"]["data"].encode())
       and contract_ref["decision_record_ref"]["sha256"] == contract_ref["scope_sha256"] == metadata["output_contract"],
       "contract raw JSON hash stays distinct from output-contract text hash")
    suffix = sha(json.loads(paths[0].read_bytes())["id"].encode())[:32]
    ok(generated["stage_request"]["content"]["id"] == "request.shadow-write." + suffix
       and generated["attempt"]["result_id"] == "result.shadow-write." + suffix, "write identities derive from actual attempt UTF8")
    ok({generated["attempt"][key] for key in ("started_at", "finished_at", "recorded_at")} == {request_body["requested_at"]}, "all attempt timestamps retain original requested_at")
    identity = json.loads(result.qualified_identity_raw)
    ok(identity["body"]["stage_request_ref"]["sha256"] == generated["stage_request"]["sha256"]
       and identity["body"]["stage_request_ref"] != json.loads((output / "qualified-identity.json").read_bytes())["body"]["stage_request_ref"], "new qualified identity does not reuse stale request ref")
    verifier_result = json.loads(result.verification_files["file-digest-result.json"])
    ok(verifier_result["body"]["outcome"] == "match", "actual fixed verifier checks unchanged incident in written candidate")
    ok(json.loads(result.verification_files["sandbox-request.json"])["body"]["subject"]["candidate"]["tree_id"] == result.candidate_tree_id, "write receipt subject names actual new candidate tree")
    ok(digest_directory(base / "source.git") == source_before and digest_directory(output) == frozen_before
       and digest_directory(original_attempt) == store_before, "source/frozen original/store snapshots unchanged")
    roles = [row["role"] for row in json.loads((paths[2] / "builder/first.json").read_bytes()).get("commands", [])]
    ok(not roles, "candidate excludes outer command provenance")
    unreviewed = types.ModuleType("writer_unreviewed_origin")
    unreviewed.__spec__ = types.SimpleNamespace(origin=str(paths[2] / "builder/metadata-first.json"))
    sys.modules[unreviewed.__name__] = unreviewed
    try:
        try:
            e._runtime_module_origins()
        except e.Refusal:
            ok(True, "additional unreviewed module origin refuses; no directory wildcard")
        else:
            raise AssertionError("unreviewed origin accepted")
    finally:
        del sys.modules[unreviewed.__name__]
    original_origin = w.__spec__.origin
    w.__spec__.origin = str(paths[2] / "missing-writer.py")
    try:
        try:
            e._runtime_module_origins()
        except (e.Refusal, OSError):
            ok(True, "missing writer module origin refuses")
        else:
            raise AssertionError("missing origin accepted")
    finally:
        w.__spec__.origin = original_origin
    writer_hold = e.stable_file(package / "shadow/v1/write-shadow.py")
    writer_path = package / "shadow/v1/write-shadow.py"
    writer_original, writer_mode = writer_path.read_bytes(), writer_path.stat().st_mode & 0o777
    try:
        writer_path.chmod(0o600)
        writer_path.write_bytes(writer_original + b"\n")
        try:
            writer_hold.recheck()
        except (e.Refusal, c.Refusal):
            ok(True, "captured reviewed writer source drift refuses")
        else:
            raise AssertionError("changed writer source accepted")
    finally:
        writer_path.write_bytes(writer_original)
        writer_path.chmod(writer_mode)
        writer_hold.close()
    # Every refusal keeps the real converter/materializer/preparation/checker path.
    invoke(case("wrong-attempt", lambda doc: doc["body"].update(attempt_id="different")), True)
    invoke(case("original-attempt", lambda doc: (doc.update(id=request["id"]), doc["body"].update(attempt_id=request["id"]))), True)
    invoke(case("unsorted-paths", lambda doc: doc["body"]["allowed_paths"].reverse()), True)
    invoke(case("missing-path", lambda doc: doc["body"]["allowed_paths"].pop()), True)
    invoke(case("extra-path", lambda doc: doc["body"]["allowed_paths"].append("ystack-evidence/extra")), True)
    invoke(case("legacy-bundle", frozen_change=lambda d: ((d / "bundle.json").chmod(0o600), (d / "bundle.json").write_bytes(canonical(dict(json.loads((d / "bundle.json").read_bytes()), kind="legacy"))))), True)
    invoke(case("missing-evidence", frozen_change=lambda d: (d / "trace-receipt.json").unlink()), True)
    invoke(case("extra-evidence", frozen_change=lambda d: (d / "extra").write_bytes(b"")), True)
    invoke(case("symlink-evidence", frozen_change=lambda d: ((d / "policy.json").unlink(), (d / "policy.json").symlink_to(output / "policy.json"))), True)
    def change_frozen(d, name, mutate):
        path = d / name
        value = json.loads(path.read_bytes())
        mutate(value)
        path.chmod(0o600)
        path.write_bytes(canonical(value))
        marker = json.loads((d / "bundle.json").read_bytes())
        for row in marker["body"]["files"]:
            if row["name"] == name:
                row.update(size_bytes=len(path.read_bytes()), sha256=sha(path.read_bytes()))
        (d / "bundle.json").chmod(0o600)
        (d / "bundle.json").write_bytes(canonical(marker))
    def rehash_provenance(directory, mutate):
        change_frozen(directory, "consumer-provenance.json", mutate)
        raw = (directory / "consumer-provenance.json").read_bytes()
        change_frozen(directory, "shadow-record.json",
            lambda doc: doc["body"].update(consumer_provenance_ref=e.document_ref(raw)))
    provenance_doc = json.loads((output / "consumer-provenance.json").read_bytes())
    mutations = [("missing-" + key, lambda doc, key=key: doc["body"].pop(key))
                 for key in provenance_doc["body"]]
    mutations += [("kind", lambda doc: doc.update(kind="wrong")),
        ("id", lambda doc: doc.update(id="attempt.other")),
        ("schema-type", lambda doc: doc.update(schema_version=True)),
        ("body-type", lambda doc: doc.update(body=[])),
        ("extra-envelope", lambda doc: doc.update(extra=True)),
        ("extra-body", lambda doc: doc["body"].update(extra=True)),
        ("digest-type", lambda doc: doc["body"].update(helper_executable_sha256=1)),
        ("changed-source", lambda doc: doc["body"].update(consumer_source_sha256="0" * 64)),
        ("commands-type", lambda doc: doc["body"].update(commands={})),
        ("commands-empty", lambda doc: doc["body"].update(commands=[])),
        ("command-missing", lambda doc: doc["body"]["commands"][0].pop("argv_sha256")),
        ("command-extra", lambda doc: doc["body"]["commands"][0].update(extra=True)),
        ("command-role", lambda doc: doc["body"]["commands"][0].update(role="write-git-inspection")),
        ("command-digest", lambda doc: doc["body"]["commands"][0].update(argv_sha256="invalid")),
        ("command-executable", lambda doc: doc["body"]["commands"][0].update(executable_sha256="0" * 64)),
        ("command-component", lambda doc: doc["body"]["commands"][0].update(component_sha256="0" * 64))]
    bounded = e.run_bounded
    for name, mutate in mutations:
        called = []
        def observed(role, *args, **kwargs):
            called.append(role)
            return bounded(role, *args, **kwargs)
        e.run_bounded = observed
        try:
            invoke(case("provenance-" + name, frozen_change=lambda d: rehash_provenance(d, mutate)), True)
            ok(not any(role.startswith("write-") or role == "materialization" for role in called),
               "rehash cannot pass malformed provenance before conversion/materialization: " + name)
        finally:
            e.run_bounded = bounded
    invoke(case("rehashed-native-context", frozen_change=lambda d: change_frozen(d, "consumer-provenance.json", lambda doc: doc["body"]["native_release"].update(binary_sha256="0" * 64))), True)
    invoke(case("rehashed-evaluation", frozen_change=lambda d: change_frozen(d, "sandbox-evaluation.json", lambda doc: doc["body"].update(verdict="refused"))), True)
    invoke(case("rehashed-receipt", frozen_change=lambda d: change_frozen(d, "sandbox-receipt.json", lambda doc: doc["body"]["lifecycle"].update(runtime="failed"))), True)
    invoke(case("rehashed-accepted-set", frozen_change=lambda d: change_frozen(d, "accepted-identities.json", lambda doc: doc["body"].update(environments=[]))), True)
    receipt_path = original_attempt / "receipt.json"
    receipt_original = receipt_path.read_bytes()
    receipt_path.chmod(0o640)
    receipt_path.write_bytes(receipt_original + b"\n")
    receipt_path.chmod(0o440)
    invoke(case("changed-origin-store"), True)
    receipt_path.chmod(0o640)
    receipt_path.write_bytes(receipt_original)
    receipt_path.chmod(0o440)
    policy = json.loads((package / "scope/v1/scope-policy.json").read_bytes())
    mode = json.loads((package / "config/construction-mode.json").read_bytes())
    for path in ("../escape", "ystack-evidence/./alias", "ystack-evidence/../alias", "ystack-evidence/AUTH/x", ".ystack/x", "config/x", "AGENTS.md", "ystack-evidence/x. /x", "ystack-evidence/x\\y/x", "ystack-evidence/.git/x"):
        ok(not c.write_path_ok(path, policy, mode), "protected or unsafe path refuses: " + path)
    blobs = {"ystack-evidence/incident.fixture/" + str(i) + ".txt": b"\n" for i in range(32)}
    blobs["ystack-evidence/incident.fixture/0.txt"] = b"no final LF"
    patch, facts = c.evidence_patch(blobs, "sha1")
    ok(b"\\ No newline at end of file\n" in patch and patch.count(b"new file mode 100644") == 32, "add-only text patch includes no-final-LF marker")
    ok(all(row["git_blob_oid"] == hashlib.sha1(("blob " + str(len(blobs[row["path"]])) + "\0").encode() + blobs[row["path"]]).hexdigest() for row in facts), "raw Git SHA1 blob hashes")
    _, facts256 = c.evidence_patch(blobs, "sha256")
    ok(all(len(row["git_blob_oid"]) == 64 for row in facts256), "source SHA256 object algorithm supported")
    for raw in (b"binary\0", b"invalid\xff", b"\x01", b"x" * 1048576):
        changed = dict(blobs)
        changed[next(iter(changed))] = raw
        try:
            c.evidence_patch(changed, "sha1")
        except c.Refusal:
            ok(True, "binary/invalidUTF8/oversize patch refuses without truncation")
        else:
            raise AssertionError("unsafe patch accepted")
    def root_refusal(source_facts):
        fake = types.SimpleNamespace(request_doc=json.loads(paths[0].read_bytes()),
            components={package / "scope/v1/scope-policy.json": types.SimpleNamespace(raw=canonical(policy)),
                        package / "config/construction-mode.json": types.SimpleNamespace(raw=canonical(mode))})
        try:
            w._write_files(fake, {}, json.loads((output / "incident.json").read_bytes()), source_facts)
        except e.Refusal:
            ok(True, "existing root or ancestor alias refuses before converter")
        else:
            raise AssertionError("existing root accepted")
    root_name = "ystack-evidence/" + json.loads((output / "incident.json").read_bytes())["id"]
    for source_facts in ({root_name: ("040000", "tree", "0" * 40)},
                         {root_name + "/old": ("100644", "blob", "0" * 40)},
                         {root_name.upper(): ("120000", "blob", "0" * 40)},
                         {"ystack-evidence": ("120000", "blob", "0" * 40)},
                         {"YSTACK-EVIDENCE": ("040000", "tree", "0" * 40)}):
        root_refusal(source_facts)
    fact_paths = case("candidate-fact-boundaries")
    with partial_owner():
        ws = w._Workspace(fact_paths[0], fact_paths[1], fact_paths[2], fact_paths[3], parent)
        try:
            shutil.copytree(result.candidate_repository, ws.work / "candidate/repository.git")
            incident_doc = json.loads((output / "incident.json").read_bytes())
            source_facts = w._git_inventory(ws, base / "source.git", incident_doc["body"]["git_revision_ref"])
            actual = w._candidate_facts(ws, result.response_raw, incident_doc, source_facts, result.files, result.write_set)
            ok(actual["commit_id"] == result.candidate_commit_id, "actual parent/tree/blob positive before fact mutations")
            facts = w._git_inventory(ws, ws.work / "candidate/repository.git",
                dict(incident_doc["body"]["git_revision_ref"], commit_id=result.candidate_commit_id))
            sibling = "ystack-evidence/incident.previous/old.txt"
            ok(sibling in source_facts and facts[sibling] == source_facts[sibling]
               and facts["ystack-evidence"][2] != source_facts["ystack-evidence"][2]
               and facts["unrelated"] == source_facts["unrelated"], "actual sibling survives changed ancestor; unrelated tree unchanged")
            repository = ws.work / "candidate/repository.git"
            git_env = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C",
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_NO_REPLACE_OBJECTS": "1", "GIT_TERMINAL_PROMPT": "0",
                "GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
            def object_write(args, raw):
                return subprocess.check_output(["/usr/bin/git", "--no-replace-objects",
                    "--git-dir=" + str(repository), *args], input=raw, env=git_env).decode().strip()
            changed_blob = object_write(["hash-object", "-w", "--stdin"], b"changed old content\n")
            def changed_tree(entries, directory=""):
                children = {path[len(directory):].split("/")[0] for path in entries if path.startswith(directory)}
                rows = []
                for name in sorted(children):
                    path = directory + name
                    mode, kind, oid = entries[path]
                    if kind == "tree":
                        oid = changed_tree(entries, path + "/")
                    rows.append(f"{mode} {kind} {oid}\t{name}\n")
                return object_write(["mktree"], "".join(rows).encode())
            for name, mutate in (("old-blob", lambda f: f.update({sibling: ("100644", "blob", changed_blob)})),
                ("old-mode", lambda f: f.update({sibling: ("100755", "blob", f[sibling][2])})),
                ("old-type", lambda f: f.update({sibling: ("120000", "blob", f[sibling][2])})),
                ("old-removal", lambda f: f.pop(sibling)),
                ("extra-leaf", lambda f: f.update({"extra.txt": ("100644", "blob", changed_blob)})),
                ("unrelated-tree", lambda f: f.update({"unrelated/old.txt": ("100644", "blob", changed_blob)}))):
                changed = dict(facts)
                mutate(changed)
                tree = changed_tree(changed)
                commit = object_write(["commit-tree", tree, "-p", incident_doc["body"]["git_revision_ref"]["commit_id"]], b"fixture mutation\n")
                response_doc = json.loads(result.response_raw)
                receipt_doc = json.loads(response_doc["payloads"][0]["data"])
                receipt_doc["candidate"].update(commit_id=commit, tree_id=tree)
                receipt_raw = canonical(receipt_doc)
                response_doc["payloads"][0].update(data=receipt_raw.decode(), sha256=sha(receipt_raw))
                try:
                    w._candidate_facts(ws, canonical(response_doc), incident_doc, source_facts, result.files, result.write_set)
                except e.Refusal:
                    ok(True, "actual Git candidate rejects " + name)
                else:
                    raise AssertionError("changed old candidate accepted: " + name)
            for key, value in (("mode", "100755"), ("git_blob_oid", "0" * 40), ("path", root_name + "/unlisted")):
                changed = copy.deepcopy(result.write_set)
                changed[0][key] = value
                try:
                    w._candidate_facts(ws, result.response_raw, incident_doc, source_facts, result.files, changed)
                except e.Refusal:
                    ok(True, "independent actual candidate facts reject altered " + key)
                else:
                    raise AssertionError("changed candidate fact accepted")
            for key in ("parent_commit_id", "tree_id"):
                response_doc = json.loads(result.response_raw)
                receipt_doc = json.loads(response_doc["payloads"][0]["data"])
                receipt_doc["candidate"][key] = "0" * 40
                receipt_raw = canonical(receipt_doc)
                response_doc["payloads"][0].update(data=receipt_raw.decode(), sha256=sha(receipt_raw))
                try:
                    w._candidate_facts(ws, canonical(response_doc), incident_doc, source_facts, result.files, result.write_set)
                except e.Refusal:
                    ok(True, "rehashed response cannot falsify actual " + key)
                else:
                    raise AssertionError("false candidate parent/tree accepted")
        finally:
            ws.close()
    real_env = e.clean_env(base / "bin/jq", fixture)
    roles = ("write-seed-conversion", "write-materialization-input", "write-git-inspection")
    def fixed_command(role, name):
        directory = fixture / (role + "-" + name)
        directory.mkdir(mode=0o700)
        if role == "write-seed-conversion":
            incident_path = output / "incident.json" if name != "nonzero" else directory / "missing.json"
            return ["/bin/bash", "-p", str(package / "maintenance/v1/incident-to-eval.sh"), "convert",
                    str(incident_path), str(output / "shadow-record.json"), str(directory)]
        if role == "write-materialization-input":
            input_path = output / "materialization-input.json"
            if name == "nonzero":
                input_path = directory / "invalid.json"
                write(input_path, b"{invalid JSON\n", 0o400)
            return [str(base / "bin/jq"), "-L", str(package / "core/v2/generations" / generation / "modules"),
                    "-S", "-c", "--arg", "phase", "stage-request", "--rawfile", "contract",
                    str(paths[2] / "builder/contract.json"), "--rawfile", "patch", str(paths[2] / "builder/producer.patch"),
                    "--slurpfile", "metadata", str(paths[2] / "builder/metadata-first.json"), "-f",
                    str(package / "shadow/v1/write-materialization-input.jq"), str(input_path)]
        inspection = ["cat-file", "commit", "0" * 40] if name == "nonzero" else ["rev-parse", "--is-bare-repository"]
        return ["/usr/bin/git", "--no-replace-objects", "--git-dir=" + str(base / "source.git"), *inspection]
    commands = [(role, fixed_command(role, "positive")) for role in roles]
    argv = commands[-1][1]
    with partial_owner():
        for role, args in commands:
            bad = list(args)
            bad[-1] = "--unexpected"
            try:
                e._native_child_spec(role, bad, real_env)
            except (e.Refusal, c.Refusal):
                ok(native.child_status()[0] == 0, "wrong fixed argv refuses before native spawn")
            else:
                raise AssertionError("wrong argv accepted")
        tuple_args = e._native_child_spec("write-git-inspection", argv, real_env)
        for value in (19,):
            try:
                native.prepare_child((value, *tuple_args[1:]))
            except (ValueError, RuntimeError):
                ok(native.child_status()[0] == 0, "unknown role19 refuses before spawn")
            else:
                raise AssertionError("unknown role accepted")
        bad_env = tuple_args[:3] + (tuple(sorted((*tuple_args[3], b"EXTRA=1"))),)
        try:
            native.prepare_child(bad_env)
        except ValueError:
            ok(native.child_status()[0] == 0, "extra writer env refuses before spawn")
        else:
            raise AssertionError("extra environment accepted")
    for role, args in commands:
        with partial_owner():
            actual_output = e.run_bounded(role, args, env=real_env, output_limit=8 * e.OUTPUT_LIMIT)
            ok(bool(actual_output), "actual fixed " + role + " positive produces output")
            if role == "write-git-inspection":
                ok(actual_output == b"true\n", "actual role18 fixed Git reads bare fact")
            status = native.child_status()
            ok(status[17] == status[18] == status[19] == status[24] == 1 and status[23] == 0,
               role + " has unique reap/group absence/complete pipe responsibility")
        for name, limit, timeout in (("nonzero", 8 * e.OUTPUT_LIMIT, 120),
                                     ("oversize", 1, 120), ("timeout", 8 * e.OUTPUT_LIMIT, 0.000001)):
            args = fixed_command(role, name)
            child = subprocess.run([str(physical_python), "-I", "-S", "-B", str(native_negative_runner),
                *map(str, (base, package, physical_python, native_binary, native_record, dependency_record,
                           parent_helper, collector)), role, name, json.dumps(args), json.dumps(real_env),
                str(limit), str(timeout)], env={key: os.environ[key] for key in startup_environment_keys},
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
            (fixture / (role + "-" + name + ".stdout")).write_bytes(child.stdout)
            (fixture / (role + "-" + name + ".stderr")).write_bytes(child.stderr)
            if child.returncode != 0:
                print(child.stdout.decode(), end="")
                print(child.stderr.decode(), end="", file=sys.stderr)
                raise AssertionError(role + " " + name + " isolated control failed")
            report = json.loads(child.stdout)
            ok(report["outcome"] == "native-release.failure" and report["no_completion"],
               role + " " + name + " isolated raw failure retained; no L")
            print("native writer negative", json.dumps(report, sort_keys=True))
        old_term = signal.signal(signal.SIGTERM, signal.SIG_IGN)
        try:
            with partial_owner():
                signal.raise_signal(signal.SIGTERM)
                try:
                    e.run_bounded(role, fixed_command(role, "cancel"), env=real_env)
                except e.Cancelled:
                    ok(native.child_status()[0] == 0 and not (paths[3] / "bundle.json").exists(),
                       "fixture SIG_IGN; real watched TERM prevents next " + role + " child and completion")
                else:
                    raise AssertionError(role + " pending cancellation accepted")
        finally:
            signal.signal(signal.SIGTERM, old_term)
    ok(json.loads((root / "enforcement/v1/accepted-identities.json").read_bytes())["body"]["environments"] == [], "shipped accepted set stays empty")
    ok(w.main(["write-shadow.py", "prepare", "request", "bundle", "work", "output"]) == 1, "interim public prepare refuses without marker")
    scenario_work, scenario_output = original_work, original_output
    scenario_mode, scenario_request = original_mode, original_request
    for name, previous in module_state.items():
        if previous is None:
            sys.modules.pop(name, None)
        else:
            sys.modules[name] = previous
    print("shadow-write: actual materializer/converter/preparation/verifier/checker with simulated store/launch; no qualification")
run_writer_tests()
PY
"$python_bin" -I -S -B - "$root" "$tmp" <<'PY'
import pathlib,sys
root,tmp=map(pathlib.Path,sys.argv[1:])
source=(root/"scripts/test/shadow-enforced.test.sh").read_text()
anchor='mismatch_case=work/"case-mismatch";mismatch_case.mkdir(mode=0o700)'
if source.count(anchor)!=1:raise SystemExit("existing fixture boundary changed")
source=source.replace('root=$(CDPATH=\'\' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)', 'root='+repr(str(root)),1)
source=source.replace('for component_dir in adapters core preparation control enforcement shadow telemetry scripts; do',
 'for component_dir in adapters core preparation control enforcement shadow telemetry scripts maintenance evals scope config; do',1)
old=' for index,row in enumerate(manifest["entries"]):\n  raw=values[f"candidate/{index:05d}".encode()]'
if source.count(old)!=1:raise SystemExit("existing launch fixture boundary changed")
source=source.replace(old,' for directory in (row for row in manifest["entries"] if row["kind"]=="directory"):\n  (verifier_root/"candidate"/directory["path"]).mkdir(parents=True,exist_ok=True)\n for index,row in enumerate(row for row in manifest["entries"] if row["kind"]=="file"):\n  raw=values[f"candidate/{index:05d}".encode()]',1)
tree_line='real_tree=$(/usr/bin/printf \'100644 blob %s\\tsource.txt\\n\' "$real_blob" | git_fixture --git-dir="$real/source.git" mktree)'
if source.count(tree_line)!=1:raise SystemExit("existing actual source tree boundary changed")
sibling_tree='real_old_tree=$(/usr/bin/printf \'100644 blob %s\\told.txt\\n\' "$real_blob" | git_fixture --git-dir="$real/source.git" mktree)'
evidence_tree='real_evidence_tree=$(/usr/bin/printf \'040000 tree %s\\tincident.previous\\n\' "$real_old_tree" | git_fixture --git-dir="$real/source.git" mktree)'
source=source.replace(tree_line,sibling_tree+"\n"+evidence_tree+"\n"+tree_line.replace('source.txt\\n', 'source.txt\\n040000 tree %s\\tunrelated\\n040000 tree %s\\tystack-evidence\\n').replace('"$real_blob" |','"$real_blob" "$real_old_tree" "$real_evidence_tree" |'),1)
point='e.c.load_anchor=lambda _resolver=None,_group_reader=None: Anchor()'
if source.count(point)!=1:raise SystemExit("existing input diagnostic boundary changed")
diag="""
original_input_recheck=e.InputSnapshot.recheck
def diagnose_input_recheck(self):
 try:original_input_recheck(self)
 except BaseException:
  print("failed held input",self.held.path,file=sys.stderr)
  for index,component in enumerate(self.held.components):
   current=e.c._metadata(component.fd)
   named=current if component.name is None else e.c._named_metadata(component.name,self.held.components[index-1].fd)
   if e.c._identity(current)!=e.c._identity(component.before) or e.c._identity(named)!=e.c._identity(component.before):
    print("identity difference",index,component.name,e.c._identity(component.before),e.c._identity(current),e.c._identity(named),file=sys.stderr)
  raise
e.InputSnapshot.recheck=diagnose_input_recheck
"""
source=source.replace(point,point+"\n"+diag,1)
start=source.index('base, package, physical_python, native_binary, native_record, dependency_record, parent_helper, collector = map(pathlib.Path,sys.argv[1:])')
start=source.rfind('import os\nstartup_environment_keys=',0,start)
end=source.index('with e.CancellationSignals(admission):bundle=e.reproduce',start)
prelude=source[start:end]
prelude=prelude.replace('map(pathlib.Path,sys.argv[1:])','map(pathlib.Path,sys.argv[1:9])')
prelude=prelude.replace('path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(raw);path.chmod(mode)',
 'path.parent.mkdir(parents=True,exist_ok=True)\n if path.exists() and path.read_bytes()==raw:return\n if path.exists():path.chmod(0o600)\n path.write_bytes(raw);path.chmod(mode)')
import re
prelude=re.sub(r'\.mkdir\(([^\n)]*)\)',lambda m:m.group(0) if 'exist_ok' in m.group(1) else '.mkdir('+m.group(1)+',exist_ok=True)',prelude)
negative="""
role,name=sys.argv[9:11]
argv,environment=json.loads(sys.argv[11]),json.loads(sys.argv[12])
limit,timeout=int(sys.argv[13]),float(sys.argv[14])
class NegativeComplete(Exception):pass
sentinel=NegativeComplete()
refused=False
try:
 with e.CancellationSignals(admission):
  try:e.run_bounded(role,argv,env=environment,output_limit=limit,timeout=timeout)
  except e.Refusal as exc:
   assert str(exc) in {"E_RUNTIME","E_LIMIT"},str(exc)
   refused=True
   refusal_code=str(exc)
   status=native.child_status()
   assert len(status)==49
   if name=="nonzero":
    assert status[11]==1 and status[9]==getattr(os,"CLD_EXITED",1) and status[10]!=0
   if name=="oversize":assert str(exc)=="E_LIMIT"
   if status[0]==4:
    assert status[17]==status[18]==status[19]==status[24]==1 and status[23]==0
    classification="successful bounded cleanup"
   elif status[0]==3:
    assert status[24]==0 and (status[23]!=0 or not status[11])
    classification="retained native failure or outstanding duty; process exit is not State teardown"
   else:
    assert name=="timeout" and status[0] in {0,2} and status[23]==0
    classification="refused before owned child"
  assert refused,"negative command accepted"
  raise sentinel
except NegativeComplete as exc:
 assert exc is sentinel
assert native.outcome()=="native-release.failure"
assert native.child_status()==status
print(json.dumps({"role":role,"case":name,"status":status,"classification":classification,"refusal":refusal_code,
 "outcome":native.outcome(),"no_completion":True},sort_keys=True))
"""
runner=tmp/"writer-native-negative.py"
runner.write_text(prelude+negative)
body="root = pathlib.Path("+repr(str(root))+")\n"+(tmp/"writer-tests.py").read_text()
body="native_negative_runner = pathlib.Path("+repr(str(tmp/"writer-native-negative.py"))+")\n"+body
source=source.replace(anchor,"exec(compile("+repr(body)+", 'shadow-write-fixture-controls', 'exec'))\n"+anchor,1)
(tmp/"enforced-with-writer.sh").write_text(source)
PY
/bin/bash "$tmp/enforced-with-writer.sh"
