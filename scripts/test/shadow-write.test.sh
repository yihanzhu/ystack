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
    module_names = ("shadow_writer_test_subject", "ystack_shadow_enforced", "ystack_shadow_consumer", "ystack_publisher_admission")
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
    def case(name, mutate=None, frozen_change=None, policy_form=False):
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
        if policy_form:
            request_doc["body"]["allowed_paths"].append("ystack-evidence/" + json.loads((output / "incident.json").read_bytes())["id"] + "/scope-policy.json")
            request_doc["body"]["allowed_paths"].sort()
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
        fake = types.SimpleNamespace(record_form="withheld-write.v1", request_doc=json.loads(paths[0].read_bytes()),
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
    def complete(paths, refusal=False, mode="success", record_form="withheld-write.v1"):
        global scenario_work, scenario_output, scenario_mode, scenario_request
        scenario_work, scenario_output = paths[2], paths[3]
        scenario_mode, scenario_request = mode, paths[0]
        original_launch = e._launch
        def timed_fixture_launch(anchor, frame, deadline):
            code = original_launch(anchor, frame, deadline)
            attempt = json.loads(paths[0].read_bytes())["id"]
            receipt_path = store / attempt / "receipt.json"
            if receipt_path.exists():
                receipt = json.loads(receipt_path.read_bytes())
                minute = counter % 50
                receipt["body"]["timing"] = {"admitted_at": f"2026-08-30T00:{minute:02d}:05Z",
                    "terminated_at": f"2026-08-30T00:{minute:02d}:06Z"}
                receipt_path.chmod(0o600)
                receipt_path.write_bytes(canonical(receipt))
                receipt_path.chmod(0o440)
            return code
        e._launch = timed_fixture_launch
        try:
            with e.CancellationSignals(reset()):
                marker = w.write(*paths, parent, record_form)
                ok(not (paths[3] / "bundle.json").exists(), "writer marker stays absent before native L")
        except (e.Refusal, c.Refusal) as exc:
            if not refusal:
                raise
            ok(native.outcome() == "native-release.failure", "full writer refusal uses real native abort-release")
            ok(not (paths[3] / "bundle.json").exists(), "full writer refusal leaves no outer marker: " + str(exc))
            return None
        finally:
            e._launch = original_launch
        if refusal:
            raise AssertionError("complete writer negative unexpectedly accepted")
        ok(native.outcome() == "native-release.success", "complete writer uses actual native completion L")
        ok((paths[3] / "bundle.json").read_bytes() == marker, "actual native L installs exact writer marker")
        return {path.name: path.read_bytes() for path in paths[3].iterdir()}
    admit_function = w._admit
    inspection = []
    def inspected_admission(ws, materialized, frozen, retained, write_section):
        expected = copy.deepcopy(write_section)
        names = set(retained)
        marker = ws.output / "bundle.json"
        ok(not marker.exists() and not any(ws.output.iterdir()), "admission starts before any outer retained output")
        for field in sorted(expected):
            altered = copy.deepcopy(expected)
            altered.pop(field)
            try:
                admit_function(ws, materialized, frozen, dict(retained), altered)
            except e.Refusal as exc:
                ok(str(exc) == "E_RELATION" and not marker.exists(), "missing write field refuses before seal: " + field)
            else:
                raise AssertionError("missing write field accepted: " + field)
        mutations = [
            ("bundle-digest", lambda value: value["bundle_ref"].update(sha256="0" * 64)),
            ("bundle-extra-kind", lambda value: value["bundle_ref"].update(kind="shadow_reproduction_record")),
            ("scope", lambda value: value.update(scope_id="scope.other")),
            ("workflow", lambda value: value.update(workflow_id="workflow.other")),
            ("task", lambda value: value.update(task_class="task.other")),
            ("write-order", lambda value: value["write_set"].reverse()),
            ("write-path", lambda value: value["write_set"][0].update(path="ystack-evidence/elsewhere")),
            ("write-mode", lambda value: value["write_set"][0].update(mode="100755")),
            ("write-raw-digest", lambda value: value["write_set"][0].update(sha256="0" * 64)),
            ("write-git-oid", lambda value: value["write_set"][0].update(git_blob_oid="0" * 40)),
            ("write-add-only", lambda value: value["write_set"][0].update(add_only=False)),
            ("write-extra", lambda value: value["write_set"][0].update(extra="not-reviewed")),
            ("write-missing", lambda value: value["write_set"].pop()),
            ("publisher-kind", lambda value: value["publisher_request"].update(kind="publisher_command")),
            ("publisher-schema", lambda value: value["publisher_request"].update(schema_version=True)),
            ("publisher-id", lambda value: value["publisher_request"].update(id="incident.other")),
            ("publisher-extra", lambda value: value["publisher_request"]["body"].update(url="https://invalid.example")),
            ("publication-effect", lambda value: value.update(publication={"state": "published"})),
            ("publication-reason", lambda value: value["publication"].update(reason_id="publication.allowed")),
            ("publication-extra", lambda value: value["publication"].update(authority="publish")),
            ("post-target", lambda value: value["post_write_verification"]["target_revision"].update(commit_id="0" * 40)),
            ("post-tree", lambda value: value["post_write_verification"].update(candidate_tree_id="0" * 40)),
            ("post-set", lambda value: value["post_write_verification"]["write_set"].pop()),
            ("post-extra", lambda value: value["post_write_verification"].update(verified=True)),
        ]
        for value in (False, 0, 1):
            mutations.append(("typed-add-only-" + repr(value), lambda section, value=value:
                section["write_set"][0].update(add_only=value)))
        for value in (True, False, 0):
            mutations.append(("typed-publisher-schema-" + repr(value), lambda section, value=value:
                section["publisher_request"].update(schema_version=value)))
        for value in (True, False, 0, 1):
            mutations.extend((
                ("typed-admission-effect-" + repr(value), lambda section, value=value: section["admission"].update(effect=value)),
                ("typed-admission-state-" + repr(value), lambda section, value=value: section["admission"].update(state=value)),
                ("typed-publication-state-" + repr(value), lambda section, value=value: section["publication"].update(state=value)),
                ("typed-scope-" + repr(value), lambda section, value=value: section.update(scope_id=value)),
                ("bundle-extra-schema-" + repr(value), lambda section, value=value: section["bundle_ref"].update(schema_version=value))))
        for key in sorted(expected["admission"]):
            if key not in {"request_sha256", "write_set_sha256"}:
                mutations.append(("admission-missing-" + key, lambda section, key=key: section["admission"].pop(key)))
        mutations.extend((
            ("admission-extra", lambda section: section["admission"].update(transport="forbidden")),
            ("admission-effect", lambda section: section["admission"].update(effect="published")),
            ("admission-state", lambda section: section["admission"].update(state="authorized"))))
        for key in sorted(expected["publisher_request"]["body"]):
            mutations.append(("publisher-" + key, lambda value, key=key:
                value["publisher_request"]["body"].update({key: None})))
        for key in sorted(expected["write_set"][0]):
            mutations.append(("write-row-missing-" + key, lambda value, key=key: value["write_set"][0].pop(key)))
        for name, mutate in mutations:
            altered = copy.deepcopy(expected)
            mutate(altered)
            # Linked digests are recomputed; refusal must concern equality, not a stale hash.
            altered["admission"]["request_sha256"] = sha(canonical(altered["publisher_request"]))
            altered["admission"]["write_set_sha256"] = sha(canonical(altered["write_set"]))
            commands_before = copy.deepcopy(ws.commands)
            try:
                admit_function(ws, materialized, frozen, dict(retained), altered)
            except e.Refusal as exc:
                ok(str(exc) == "E_RELATION" and not marker.exists(), "linked write mutation refuses: " + name)
                ok(ws.commands == commands_before, "request mutation launches no later child: " + name)
            else:
                raise AssertionError("altered writer relation accepted: " + name)
        for key in ("request_sha256", "write_set_sha256"):
            for value in (None, "0" * 64, True, False, 0, 1):
                altered = copy.deepcopy(expected)
                altered["admission"][key] = value
                commands_before = copy.deepcopy(ws.commands)
                try:
                    admit_function(ws, materialized, frozen, dict(retained), altered)
                except e.Refusal as exc:
                    ok(str(exc) == "E_RELATION" and not marker.exists(), "admission hash mutation refuses: " + key + ":" + repr(value))
                    ok(ws.commands == commands_before, "admission hash refuses before later child")
                else:
                    raise AssertionError("invalid admission hash accepted")
        retained_mutations = [("body-byte", lambda value: value.update({"publisher-body.txt": value["publisher-body.txt"] + b"\n"})),
                            ("outer-missing", lambda value: value.pop("policy.json")),
                            ("outer-extra", lambda value: value.update(extra=b"")),
                            ("retained-response", lambda value: value.update({"materialization-response.json": b"{}\n"})),
                            ("retained-identity", lambda value: value.update({"qualified-identity.json": b"{}\n"})),
                            ("retained-preparation", lambda value: value.update({"preparation-manifest.json": b"{}\n"})),
                            ("retained-check", lambda value: value.update({"sandbox-check.json": b"{}\n"})),
                            ("retained-receipt", lambda value: value.update({"sandbox-receipt.json": b"{}\n"})),
                            ("retained-claim", lambda value: value.update({"claim.json": b"{}\n"})),
                            ("retained-duty", lambda value: value.update({"duty-evaluation.json": b"{}\n"}))]
        for filename in ("claim.json", "duty-evaluation.json"):
            if retained[filename] != frozen[filename]:
                retained_mutations.append(("stale-" + filename,
                    lambda value, filename=filename: value.update({filename: frozen[filename]})))
        for name, alter in retained_mutations:
            altered = dict(retained)
            alter(altered)
            commands_before = copy.deepcopy(ws.commands)
            try:
                admit_function(ws, materialized, frozen, altered, copy.deepcopy(expected))
            except e.Refusal as exc:
                ok(str(exc) == "E_RELATION" and not marker.exists(), "outer retained mismatch refuses: " + name)
                ok(ws.commands == commands_before, "retained mismatch launches no later child: " + name)
            else:
                raise AssertionError("altered retained evidence accepted: " + name)
        original_record_builder = w._outer_record
        def inspect_record(*args):
            raw = original_record_builder(*args)
            record = json.loads(raw)
            record_mutations = [("missing-" + key, lambda value, key=key: value["body"].pop(key))
                for key in ("record_form", "write", "materialization", "check", "qualified_identity_ref", "consumer_provenance_ref", "trace_ledger_ref")]
            record_mutations.extend((
                ("stale-outer-claim-ref", lambda item: item["body"]["environment"]["claim_ref"].update(sha256=sha(frozen["claim.json"]))),
                ("typed-record-schema", lambda item: item.update(schema_version=True)),
                ("typed-zero-producer", lambda item: item["body"].update(producer_invocations=False)),
                ("extra-envelope", lambda item: item.update(authority="publish"))))
            for value in (1, 0, False):
                record_mutations.append(("typed-retained-add-only-" + repr(value),
                    lambda item, value=value: item["body"]["write"]["write_set"][0].update(add_only=value)))
            commands_before = copy.deepcopy(ws.commands)
            for name, mutate in record_mutations:
                altered = copy.deepcopy(record)
                mutate(altered)
                if "write" in altered["body"]:
                    section = altered["body"]["write"]
                    section["admission"]["write_set_sha256"] = sha(canonical(section["write_set"]))
                proof_files = dict(retained, **{"shadow-record.json": canonical(altered)})
                try:
                    w._record_relations(proof_files, json.loads(frozen["incident.json"]),
                        json.loads(retained["file-digest-result.json"])["body"], retained["origin-observation.json"], ws.anchor, expected)
                except e.Refusal as exc:
                    ok(str(exc) == "E_RELATION" and not marker.exists(), "closed outer relation refuses with linked hashes: " + name)
                    ok(ws.commands == commands_before and not any(ws.output.iterdir()), "malformed outer record permits no child or output after exact admission boundary")
                else:
                    raise AssertionError("malformed retained outer record accepted: " + name)
            for field, filename in (("claim_ref", "claim.json"), ("duty_evaluation_ref", "duty-evaluation.json")):
                if retained[filename] == frozen[filename]:
                    continue
                proof_files = dict(retained, **{"shadow-record.json": raw})
                evaluation = json.loads(proof_files["sandbox-evaluation.json"])
                evaluation["body"][field] = e.document_ref(frozen[filename])
                proof_files["sandbox-evaluation.json"] = canonical(evaluation)
                altered = copy.deepcopy(record)
                altered["body"]["environment"]["evaluation"]["value"]["evaluation_ref"]["sha256"] = sha(proof_files["sandbox-evaluation.json"])
                proof_files["trace-ledger.json"] = e.trace_ledger(json.loads(frozen["incident.json"]),
                    json.loads(retained["sandbox-request.json"])["id"], json.loads(retained["claim.json"])["id"],
                    record["body"]["outcome"], "tool.verifier", proof_files["sandbox-evaluation.json"], retained["sandbox-check.json"])
                altered["body"]["trace_ledger_ref"]["sha256"] = sha(proof_files["trace-ledger.json"])
                proof_files["shadow-record.json"] = canonical(altered)
                try:
                    w._record_relations(proof_files, json.loads(frozen["incident.json"]),
                        json.loads(retained["file-digest-result.json"])["body"], retained["origin-observation.json"], ws.anchor, expected)
                except e.Refusal as exc:
                    ok(str(exc) == "E_RELATION" and ws.commands == commands_before and not marker.exists(), "stale evaluation ref refuses despite recomputed record/trace digests: " + field)
                else:
                    raise AssertionError("stale evaluation ref accepted: " + field)
            proof_files = dict(retained)
            generated = json.loads(proof_files["materialization-input.json"])
            generated["stage_request"]["content"]["body"]["environment_ref"]["fingerprint_sha256"] = sha(frozen["claim.json"])
            generated["stage_request"]["sha256"] = sha(canonical(generated["stage_request"]["content"]))
            identity = json.loads(proof_files["qualified-identity.json"])
            identity["body"]["stage_request_ref"] = e.pair_ref(generated["stage_request"])
            proof_files["materialization-input.json"], proof_files["qualified-identity.json"] = canonical(generated), canonical(identity)
            altered = copy.deepcopy(record)
            altered["body"]["qualified_identity"] = identity["body"]
            altered["body"]["qualified_identity_ref"]["sha256"] = sha(proof_files["qualified-identity.json"])
            proof_files["shadow-record.json"] = canonical(altered)
            try:
                w._record_relations(proof_files, json.loads(frozen["incident.json"]),
                    json.loads(retained["file-digest-result.json"])["body"], retained["origin-observation.json"], ws.anchor, expected)
            except e.Refusal as exc:
                ok(str(exc) == "E_RELATION" and ws.commands == commands_before and not marker.exists(), "stale input fingerprint refuses despite recomputed stage/identity/record refs")
            else:
                raise AssertionError("stale input fingerprint accepted")
            return raw
        w._outer_record = inspect_record
        try:
            answer = admit_function(ws, materialized, frozen, retained, write_section)
        finally:
            w._outer_record = original_record_builder
        inspection.append((materialized, copy.deepcopy(ws.commands), answer))
        return answer
    w._admit = inspected_admission
    def fresh_inputs(paths, fresh_duty=False):
        document = json.loads(paths[0].read_bytes())
        claim = json.loads(pathlib.Path(document["body"]["claim"]).read_bytes())
        duty = json.loads(pathlib.Path(document["body"]["duty_evaluation"]).read_bytes())
        claim["body"]["execution_identity"]["adapter_instance_id"] = "adapter.instance.write." + str(counter)
        duty_raw = canonical(duty)
        if fresh_duty:
            result = json.loads((base / "prior-result.json").read_bytes())
            result["body"]["recorded_at"] = "2026-08-30T00:00:09Z"
            result_path = paths[0].parent / "current-prior-result.json"
            write(result_path, canonical(result), 0o400)
            evaluated = subprocess.run(["/bin/bash", "-p", str(root / "control/v1/evaluate-duty.sh"), "evaluate",
                str(root / "control/v1/control-policy-set-sandbox-bound.json"), str(base / "prior-request.json"),
                str(base / "prior-profile.json"), str(result_path)], env={"PATH": str(base / "bin") + ":/usr/bin:/bin",
                "LC_ALL": "C", "TMPDIR": str(base.parent.parent)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
            ok(evaluated.returncode == 0, "real unchanged duty evaluator accepts synthetic later recorded_at: " + evaluated.stderr.decode())
            duty_raw = evaluated.stdout
            duty = json.loads(duty_raw)
            ok(duty["body"]["verdict"] == "satisfied" and duty_raw != output.joinpath("duty-evaluation.json").read_bytes(), "real evaluator produces distinct valid canonical current duty")
            claim["body"]["stage_result_ref"] = duty["body"]["stage"]["result_ref"]
        claim["body"]["duty_evaluation_ref"] = e.document_ref(duty_raw)
        for role, raw in (("claim", canonical(claim)), ("duty_evaluation", duty_raw)):
            path = paths[0].parent / (role + ".json")
            write(path, raw, 0o400)
            document["body"][role] = str(path)
        paths[0].chmod(0o600)
        write(paths[0], canonical(document), 0o400)
    first_complete_paths = case("complete-first")
    fresh_inputs(first_complete_paths)
    try:
        first_complete = complete(first_complete_paths)
        second_complete_paths = case("complete-second")
        fresh_inputs(second_complete_paths, fresh_duty=True)
        second_complete = complete(second_complete_paths)
    finally:
        w._admit = admit_function
    first_launch = json.loads(first_complete["sandbox-request.json"])
    second_launch = json.loads(second_complete["sandbox-request.json"])
    ok(first_launch["id"] != second_launch["id"] and first_launch["body"]["nonce"] != second_launch["body"]["nonce"],
       "two disposable complete attempts have distinct actual generated nonce and identity")
    ok(json.loads(first_complete["sandbox-receipt.json"])["body"]["timing"] !=
       json.loads(second_complete["sandbox-receipt.json"])["body"]["timing"],
       "two synthetic launch receipts explicitly vary timing; native proof does not grant VM qualification")
    first_record = json.loads(first_complete["shadow-record.json"])
    second_record = json.loads(second_complete["shadow-record.json"])
    first_write, second_write = first_record["body"]["write"], second_record["body"]["write"]
    incident = json.loads(output.joinpath("incident.json").read_bytes())
    expected_publisher_body = b"Shadow evidence for " + incident["id"].encode() + b". Publication is withheld.\n"
    expected_publisher = {"schema_version": 1, "kind": "shadow_publisher_request", "id": incident["id"],
        "body": {"target_repository_id": incident["body"]["target_repository_id"],
            "branch": "ystack/evidence/" + incident["id"], "base_revision": incident["body"]["git_revision_ref"],
            "candidate_tree_id": first_write["post_write_verification"]["candidate_tree_id"],
            "title": "Shadow evidence: " + incident["id"], "body_sha256": sha(expected_publisher_body)}}
    ok(first_complete["publisher-body.txt"] == second_complete["publisher-body.txt"] == expected_publisher_body,
       "publisher body is exact single-line UTF8 and one final LF")
    ok(first_write["publisher_request"] == second_write["publisher_request"] == expected_publisher,
       "neutral publisher request has exact six body keys and fixed bytes across fresh attempts")
    ok(canonical(first_write["write_set"]) == canonical(second_write["write_set"]), "two actual candidates have identical canonical verified write sets")
    ok(first_write["post_write_verification"] == second_write["post_write_verification"], "two actual candidate trees and post-write data agree")
    ok(sha(canonical(first_write["post_write_verification"])) == sha(canonical(second_write["post_write_verification"])), "post-write digests stable across two fresh attempts")
    ok(first_write == second_write, "complete offline write section is independent of attempt nonce and timings")
    ok(first_write["bundle_ref"] == {"content_id": "shadow-consumer-bundle",
        "media_type": "application/vnd.ystack.shadow-consumer-bundle+json",
        "sha256": sha(output.joinpath("bundle.json").read_bytes())}, "bundle ref binds exact frozen raw marker")
    for retained, paths in ((first_complete, first_complete_paths), (second_complete, second_complete_paths)):
        ok(set(retained) == set(e.EVIDENCE_NAMES) | {"publisher-body.txt", "bundle.json"}, "complete outer inventory contains exactly 30 evidence files plus marker")
        marker = json.loads(retained["bundle.json"])
        ok(marker["body"]["record_form"] == "withheld-write.v1" and marker["body"]["activation_state"] == "inactive", "outer marker discriminates inactive write form")
        ok(marker["body"]["files"] == [{"name": name, "sha256": sha(raw), "size_bytes": len(raw)}
            for name, raw in sorted(retained.items()) if name != "bundle.json"], "native marker inventories every actual retained byte")
        record = json.loads(retained["shadow-record.json"])
        ok(record["body"]["producer_invocations"] == 0 and record["body"]["authority"] == record["body"]["deploy_authority"] == "none", "complete writer grants no producer or publication authority")
        ok(record["body"]["outcome"] == "no-change" and record["body"]["materialization"]["value"]["outcome"] == "changed", "completed fixed check outcome remains separate from changed materialization")
        ok(record["body"]["qualified_identity"] == json.loads(retained["qualified-identity.json"])["body"], "outer identity uses actual new generated write stage request")
        write_section = record["body"]["write"]
        request_body = json.loads(retained["materialization-input.json"])["stage_request"]["content"]["body"]
        current_request = json.loads(paths[0].read_bytes())["body"]
        current_claim = pathlib.Path(current_request["claim"]).read_bytes()
        current_duty = pathlib.Path(current_request["duty_evaluation"]).read_bytes()
        ok(retained["claim.json"] == current_claim != output.joinpath("claim.json").read_bytes(), "outer retains actual fresh same-environment claim, not frozen claim")
        ok(retained["duty-evaluation.json"] == current_duty, "outer retains actual current validated duty bytes")
        evaluation = json.loads(retained["sandbox-evaluation.json"])["body"]
        ok(evaluation["claim_ref"] == e.document_ref(current_claim) and
           evaluation["duty_evaluation_ref"] == e.document_ref(current_duty), "actual bound evaluator refs bind current retained claim and duty")
        ok(json.loads(current_claim)["body"]["duty_evaluation_ref"] == e.document_ref(current_duty), "current claim binds actual current duty")
        ok(record["body"]["environment"]["claim_ref"]["sha256"] == sha(current_claim) and
           request_body["environment_ref"] == {"environment_id": json.loads(current_claim)["id"], "fingerprint_sha256": sha(current_claim)}, "outer claim ref and generated request fingerprint bind actual current claim")
        ok(write_section["workflow_id"] == request_body["workflow_id"] and write_section["task_class"] == request_body["task_class_id"], "write workflow/task equal actual generated request")
        ok(write_section["admission"] == {"state": "checked", "effect": "none",
            "request_sha256": sha(canonical(write_section["publisher_request"])), "write_set_sha256": sha(canonical(write_section["write_set"]))}, "offline admission hashes actual canonical request and write set")
        ok(write_section["publication"] == {"state": "withheld", "reason_id": "shadow.write-not-published"}, "publication is exactly withheld")
        ok(set(write_section["post_write_verification"]) == {"target_revision", "candidate_tree_id", "write_set"}, "post-write object describes checks without claiming verified publication")
        receipt = json.loads(retained["sandbox-receipt.json"])
        launch_doc = json.loads(retained["sandbox-request.json"])
        ok(launch_doc["id"] == json.loads(paths[0].read_bytes())["id"] != json.loads(output.joinpath("sandbox-request.json").read_bytes())["id"], "outer request is distinct fresh attempt")
        ok(receipt["body"]["attempt"]["attempt_id"] == launch_doc["id"], "outer authenticated receipt belongs to fresh write attempt")
        ok(record["body"]["sandbox"]["receipt_ref"] == e.document_ref(retained["sandbox-receipt.json"]), "record binds actual new receipt instead of frozen original")
        ok(record["body"]["sandbox"]["origin"]["observation_sha256"] == sha(retained["origin-observation.json"]), "outer origin ref binds fresh store observation")
        ok(record["body"]["consumer_provenance_ref"] == e.document_ref(retained["consumer-provenance.json"]), "record binds full writer provenance")
        provenance = json.loads(retained["consumer-provenance.json"])
        ok(provenance["id"] == launch_doc["id"] and provenance["body"]["consumer_source_sha256"] == sha((package / "shadow/v1/write-shadow.py").read_bytes()), "provenance binds current reviewed writer source")
        roles = [row["role"] for row in provenance["body"]["commands"]]
        ok(all(role in roles for role in ("write-seed-conversion", "write-materialization-input", "write-git-inspection", "candidate-preparation", "candidate-inspection", "sandbox-receipt-check", "trace-validation", "sandbox-launch-boundary")), "full actual fixed-command ledger reaches admission fact checks")
        launch_rows = [row for row in provenance["body"]["commands"] if row["role"] == "sandbox-launch-boundary"]
        expected_argv = ["/usr/bin/sudo", "-n", "-u", f"#{principal}", "--", sys.executable,
            str(anchor / "host-supervisor.py"), "launch"]
        ok(len(launch_rows) == 1 and launch_rows[0]["argv_sha256"] == sha(canonical(expected_argv))
           and launch_rows[0]["component_sha256"] == sha((anchor / "host-supervisor.py").read_bytes()),
           "one actual simulated launch boundary row binds original fixed argv and held supervisor source")
        ok(not any("publisher" in role or "producer" in role or "model" in role for role in roles), "no producer, model or publisher command occurs")
        trace = json.loads(retained["trace-ledger.json"])
        ok(trace["body"]["attempt_id"] == launch_doc["id"] and record["body"]["trace_ledger_ref"]["sha256"] == sha(retained["trace-ledger.json"]), "outer trace binds actual write attempt and completed fixed check")
        candidate = paths[2] / "preparation-parent/preparation/candidate"
        prefix = candidate / "ystack-evidence" / incident["id"]
        ok(not (prefix / "publisher-body.txt").exists(), "publisher body remains outside the 32-file candidate")
        for name in w.NAMES:
            ok((prefix / name).read_bytes() == output.joinpath(name).read_bytes(), "candidate keeps original frozen bytes: " + name)
        for name in ("sandbox-request.json", "sandbox-receipt.json", "shadow-record.json", "trace-ledger.json", "consumer-provenance.json"):
            ok((prefix / name).read_bytes() != retained[name], "new outer attempt evidence stays outside candidate: " + name)
    ok(inspection[0][1] == json.loads(first_complete["consumer-provenance.json"])["body"]["commands"], "no child command appears after frozen complete provenance")
    ok(first_complete["duty-evaluation.json"] == output.joinpath("duty-evaluation.json").read_bytes() != second_complete["duty-evaluation.json"], "both unchanged and fresh valid current duty complete without changing frozen candidate bytes")
    ok(digest_directory(base / "source.git") == source_before and digest_directory(output) == frozen_before
       and digest_directory(original_attempt) == store_before, "complete two-attempt flow preserves original source, bundle and controlled-store bytes")
    for mode in ("cpu-none", "unconfirmed", "missing", "partial"):
        invalid_receipt_paths = case("write-receipt-" + mode)
        complete(invalid_receipt_paths, True, mode)
        ok(not any(invalid_receipt_paths[3].iterdir()), "failed or unavailable write receipt leaves no outer retained output: " + mode)
        ok((invalid_receipt_paths[2] / "captured/response.json").exists()
           and (invalid_receipt_paths[2] / "preparation-parent/preparation/record.json").exists(),
           "receipt refusal follows actual completed materialization and preparation: " + mode)
        ok(not (invalid_receipt_paths[2] / "captured/write-trace-ledger.json").exists(),
           "invalid receipt never reaches outer trace validation or admission: " + mode)
        ok(native.outcome() == "native-release.failure", "failed verification cannot gain native completion: " + mode)
        if mode == "cpu-none":
            receipt = json.loads((store / json.loads(invalid_receipt_paths[0].read_bytes())["id"] / "receipt.json").read_bytes())
            ok(receipt["body"]["limits"]["cpu_time_ms"]["enforcement"] ==
               receipt["body"]["limits"]["wall_time_ms"]["enforcement"] == "none",
               "actual checker refuses explicit simulated NONE controls; production qualification stays blocked")
    original_outer = w._outer_record
    boundary = []
    def refuse_outer(ws, materialized, frozen, retained, section, provenance, trace):
        boundary.append("materialization-and-authenticated-verification-completed")
        altered = json.loads(original_outer(ws, materialized, frozen, retained, section, provenance, trace))
        altered["body"]["sandbox"]["receipt_ref"]["sha256"] = sha(frozen["sandbox-receipt.json"])
        return canonical(altered)
    w._outer_record = refuse_outer
    try:
        failed_paths = case("outer-original-receipt")
        complete(failed_paths, True)
        ok(boundary == ["materialization-and-authenticated-verification-completed"] and not any(failed_paths[3].iterdir()), "wrong outer receipt refuses at admission before retained output/seal")
    finally:
        w._outer_record = original_outer
    def no_marker(paths, label):
        ok(not (paths[3] / "bundle.json").exists(), label + " leaves no completed marker")
        ok(native.outcome() == "native-release.failure", label + " preserves actual native failure")
    write_at = e.write_exclusive_at
    for stop_name in ("accepted-identities.json", "publisher-body.txt", "trace-receipt.json"):
        retained_names = []
        stopped = case("seal-failure-" + stop_name)
        def fail_at_file(directory, name, raw, **options):
            retained_names.append(name)
            if name == stop_name:
                raise e.Refusal("E_RUNTIME")
            return write_at(directory, name, raw, **options)
        e.write_exclusive_at = fail_at_file
        try:
            complete(stopped, True)
            no_marker(stopped, "outer retained write failure")
            ok(retained_names[-1] == stop_name and retained_names.count(stop_name) == 1,
               "outer write stops once at exact first failed file")
            expected_names = sorted(set(e.EVIDENCE_NAMES) | {"publisher-body.txt"})
            ok(retained_names == expected_names[:expected_names.index(stop_name) + 1],
               "no later retained write happens after failed boundary")
            ok(set(path.name for path in stopped[3].iterdir()) == set(retained_names[:-1]),
               "only successfully retained prefix exists after write failure")
        finally:
            e.write_exclusive_at = write_at
    workspace_close = w._Workspace.close
    closed = []
    close_paths = case("ordinary-close-failure")
    first_close_error = e.Refusal("E_RUNTIME")
    def fail_after_close(ws):
        closed.append(ws)
        workspace_close(ws)
        raise first_close_error
    w._Workspace.close = fail_after_close
    try:
        complete(close_paths, True)
        no_marker(close_paths, "ordinary owner close failure")
        ok(len(closed) == 1 and closed[0].owned == [], "every ordinary owner closes before native completion and is not retried")
        ok(set(path.name for path in close_paths[3].iterdir()) == set(e.EVIDENCE_NAMES) | {"publisher-body.txt"},
           "close failure can retain evidence but never reports completion")
    finally:
        w._Workspace.close = workspace_close
    for phase in ("before-admission", "during-retention", "after-retention"):
        cancelled_paths = case("cancel-" + phase)
        calls = []
        prior_signal = signal.getsignal(signal.SIGTERM)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        def cancel_admission(*args):
            calls.append("verified-materialization")
            os.kill(os.getpid(), signal.SIGTERM)
            e.CancellationSignals.checkpoint()
            return admit_function(*args)
        def cancel_retention(directory, name, raw, **options):
            calls.append(name)
            result = write_at(directory, name, raw, **options)
            os.kill(os.getpid(), signal.SIGTERM)
            return result
        def cancel_after_close(ws):
            calls.append("ordinary-close")
            workspace_close(ws)
            os.kill(os.getpid(), signal.SIGTERM)
        if phase == "before-admission":
            w._admit = cancel_admission
        elif phase == "during-retention":
            e.write_exclusive_at = cancel_retention
        else:
            w._Workspace.close = cancel_after_close
        try:
            try:
                complete(cancelled_paths)
            except (e.Cancelled, e.Refusal) as exc:
                ok(isinstance(exc, e.Cancelled) or str(exc) == "E_RUNTIME", "watched signal is refusal under real native owner")
            else:
                raise AssertionError("cancelled complete writer accepted")
            no_marker(cancelled_paths, "writer cancellation at " + phase)
            if phase == "before-admission":
                ok(calls == ["verified-materialization"] and not any(cancelled_paths[3].iterdir()),
                   "pre-admission cancellation leaves no retained output or later operation")
            elif phase == "during-retention":
                ok(calls == ["accepted-identities.json"], "retention cancellation stops at next real checkpoint")
                ok(set(path.name for path in cancelled_paths[3].iterdir()) == {"accepted-identities.json"},
                   "retention cancellation leaves exact completed prefix")
            else:
                ok(calls == ["ordinary-close"], "post-retention cancellation does not repeat ordinary cleanup")
                ok(set(path.name for path in cancelled_paths[3].iterdir()) == set(e.EVIDENCE_NAMES) | {"publisher-body.txt"},
                   "post-retention cancellation preserves evidence and rolls back completion")
        finally:
            signal.signal(signal.SIGTERM, prior_signal)
            w._admit = admit_function
            e.write_exclusive_at = write_at
            w._Workspace.close = workspace_close
    public_paths = case("public-main")
    public_entry = subprocess.run([sys.executable, "-I", "-S", "-B", str(native_public_runner),
        *map(str, (base, package, physical_python, native_binary, native_record, dependency_record, parent_helper, collector)),
        *map(str, public_paths)], env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=600)
    print("fresh public writer", public_entry.stdout.decode())
    ok(public_entry.returncode == 0 and public_entry.stderr == b"",
       "public prepare uses fresh isolated P, real descriptor3 and actual first NativeRelease constructor: " + public_entry.stderr.decode())
    ok((public_paths[3] / "bundle.json").exists(), "fresh public actual native owner installs writer marker")
    public_record = json.loads((public_paths[3] / "shadow-record.json").read_bytes())
    ok(public_record["body"]["write"]["publication"] == {"state": "withheld", "reason_id": "shadow.write-not-published"},
       "public native completion keeps publication withheld")
    policy_outputs = []
    for index in range(2):
        policy_paths = case("public-policy-" + str(index), policy_form=True)
        fresh_inputs(policy_paths, fresh_duty=bool(index))
        process = subprocess.run([sys.executable, "-I", "-S", "-B", str(native_public_runner),
            *map(str, (base, package, physical_python, native_binary, native_record, dependency_record, parent_helper, collector)),
            *map(str, policy_paths), "prepare-policy"],
            env={"PATH":"/usr/bin:/bin", "LC_ALL":"C", "LANG":"C"},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=600)
        print("fresh public policy writer SIMULATED launch", process.stdout.decode())
        ok(process.returncode == 0 and process.stderr == b"",
           "prepare-policy actual public producer and native owner, SIMULATED launch: " + process.stderr.decode())
        retained = {path.name:path.read_bytes() for path in policy_paths[3].iterdir()}
        record = json.loads(retained["shadow-record.json"])
        marker = json.loads(retained["bundle.json"])
        policy_raw = (package/"scope/v1/scope-policy.json").read_bytes()
        expected_ref = c.scope_policy_ref(policy_raw)
        ok(set(retained) == set(e.EVIDENCE_NAMES) | {"publisher-body.txt", "scope-policy.json", "bundle.json"},
           "policy outer has exactly 32 files, without changing frozen reproduction inventory")
        ok(record["body"]["record_form"] == marker["body"]["record_form"] == "withheld-write-policy.v1" and
           record["body"]["scope_policy_ref"] == expected_ref and retained["scope-policy.json"] == policy_raw,
           "new form binds canonical held policy raw bytes with exact typed reference")
        ok(len(record["body"]["write"]) == 9 and len(record["body"]["write"]["write_set"]) == 33,
           "new form keeps nine write keys and only adds policy candidate file")
        prefix = "ystack-evidence/" + incident["id"] + "/"
        row = next(row for row in record["body"]["write"]["write_set"] if row["path"] == prefix+"scope-policy.json")
        ok(row["mode"] == "100644" and row["sha256"] == sha(policy_raw), "policy candidate is exact raw 100644 addition")
        candidate = policy_paths[2]/"candidate/repository.git"
        actual_policy = subprocess.run(["/usr/bin/git", "--no-replace-objects", "--git-dir="+str(candidate),
            "cat-file", "blob", row["git_blob_oid"]], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        ok(actual_policy.returncode == 0 and not actual_policy.stderr and actual_policy.stdout == policy_raw,
           "actual materialized candidate policy equals outer and held bytes")
        policy_outputs.append((retained, record, policy_paths))
    ok(policy_outputs[0][1]["body"]["write"] == policy_outputs[1][1]["body"]["write"],
       "two prepare-policy attempts keep complete candidate and write-section determinism")
    def check_policy_bundle(name,positive,label):
        bundle_parent=c._open_held(str(fixture),True,lambda _fd,_state,_ancestor:True,"E_RELATION")
        try:
            try:held=c._HeldBundle(bundle_parent,name,"withheld-write-policy.v1")
            except c.Refusal:ok(not positive,"actual producer bundle rejects "+label)
            else:
                try:held.recheck();ok(positive,"actual producer bundle accepts exact policy ref")
                finally:held.close()
        finally:bundle_parent.close()
    for output_index,(retained, record, paths) in enumerate(policy_outputs):
        actual_ref=record["body"]["scope_policy_ref"]
        c.check_scope_policy_ref(actual_ref,retained["scope-policy.json"])
        ref_cases=[("missing-"+key,{name:value for name,value in actual_ref.items() if name!=key}) for key in actual_ref]
        ref_cases += [("extra",dict(actual_ref,extra="x")),("name",dict(actual_ref,name="policy.json")),
            ("digest-upper",dict(actual_ref,sha256="A"*64)),("digest-short",dict(actual_ref,sha256="a"*63)),
            ("digest-mismatch",dict(actual_ref,sha256="0"*64)),("digest-null",dict(actual_ref,sha256=None)),
            ("digest-bool",dict(actual_ref,sha256=True)),("name-null",dict(actual_ref,name=None)),
            ("ref-array",[]),("ref-null",None),("ref-bool",False)]
        for value in (True,False,0,-1,1,1048576,1048577,1.0,"1",None):
            ref_cases.append(("size-"+repr(value),dict(actual_ref,size_bytes=value)))
        for label,value in [("exact",actual_ref),*ref_cases]:
            name="policy-ref-"+str(output_index)+"-"+label
            location=fixture/name;location.mkdir(mode=0o700)
            changed=dict(retained);document=copy.deepcopy(record)
            document["body"]["scope_policy_ref"]=value
            changed["shadow-record.json"]=canonical(document)
            marker=json.loads(changed["bundle.json"])
            marker["body"]["files"]=[{"name":key,"size_bytes":len(raw),"sha256":sha(raw)}
                for key,raw in sorted(changed.items()) if key!="bundle.json"]
            changed["bundle.json"]=canonical(marker)
            for key,raw in changed.items():write(location/key,raw,0o400)
            check_policy_bundle(name,label=="exact",label)
        for label in ("missing","extra","renamed","noncanonical","empty","overlimit"):
            name="policy-inventory-"+str(output_index)+"-"+label;location=fixture/name;location.mkdir(mode=0o700)
            changed=dict(retained)
            if label=="missing":changed.pop("scope-policy.json")
            elif label=="extra":changed["extra-policy.json"]=changed["scope-policy.json"]
            elif label=="renamed":changed["scope-policy-renamed.json"]=changed.pop("scope-policy.json")
            elif label=="noncanonical":changed["scope-policy.json"]+=b" "
            elif label=="empty":changed["scope-policy.json"]=b""
            else:changed["scope-policy.json"]=b" "*1048577
            marker=json.loads(changed["bundle.json"])
            marker["body"]["files"]=[{"name":key,"size_bytes":len(raw),"sha256":sha(raw)}
                for key,raw in sorted(changed.items()) if key!="bundle.json"]
            changed["bundle.json"]=canonical(marker)
            for key,raw in changed.items():write(location/key,raw,0o400)
            check_policy_bundle(name,False,label)
    maximum_policy=canonical({"padding":"x"*(1048576-len(canonical({"padding":""})))})
    ok(len(maximum_policy)==1048576 and c.scope_policy_ref(maximum_policy)["size_bytes"]==1048576,
       "canonical policy accepts exact one-MiB reference bound in full suite")
    for raw in (b"",b"{}",b"[]\n",b'{"x":1,"x":2}\n',b'{"x":NaN}\n',b"\xff",maximum_policy+b" "):
        try:c.scope_policy_ref(raw)
        except c.Refusal:ok(True,"canonical policy bytes/size reject in full suite")
        else:raise AssertionError("invalid policy raw accepted")
    for policy_form,request_policy in ((True,False),(False,True)):
        wrong_count=case("new32" if policy_form else "old33",policy_form=request_policy)
        fresh_inputs(wrong_count)
        complete(wrong_count,refusal=True,record_form="withheld-write-policy.v1" if policy_form else "withheld-write.v1")
        ok(not (wrong_count[3]/"bundle.json").exists(),"actual producer refuses new32/old33 without form inference")
    for retained,record,source_paths in (policy_outputs[0],(first_complete,first_record,first_complete_paths)):
        form=record["body"]["record_form"];policy_form=form=="withheld-write-policy.v1"
        fact_paths=case("policy-candidate-facts-"+form,policy_form=policy_form)
        with partial_owner():
            ws=w._Workspace(*fact_paths,parent,form)
            try:
                shutil.copytree(source_paths[2]/"candidate/repository.git",ws.work/"candidate/repository.git")
                repository=ws.work/"candidate/repository.git"
                incident_doc=json.loads(retained["incident.json"])
                revision=incident_doc["body"]["git_revision_ref"]
                response_doc=json.loads(retained["materialization-response.json"])
                receipt_doc=json.loads(response_doc["payloads"][0]["data"])
                facts=w._git_inventory(ws,repository,dict(revision,commit_id=receipt_doc["candidate"]["commit_id"]))
                source_facts=w._git_inventory(ws,base/"source.git",revision)
                rows=record["body"]["write"]["write_set"]
                expected_files={row["path"]:ws.git_read(repository,["cat-file","blob",row["git_blob_oid"]],1048577*8) for row in rows}
                w._candidate_facts(ws,canonical(response_doc),incident_doc,source_facts,expected_files,rows)
                ok(True,"actual "+form+" candidate positive before policy Git mutations")
                policy_path="ystack-evidence/"+incident_doc["id"]+"/scope-policy.json"
                new_blob=object_write(["hash-object","-w","--stdin"],canonical({"wrong":"policy blob"}))
                mutations=("missing","extra","renamed","wrong-mode","wrong-blob") if policy_form else ("old33",)
                for label in mutations:
                    altered=dict(facts)
                    if label=="missing":altered.pop(policy_path)
                    elif label=="extra":altered[policy_path+".extra"]=("100644","blob",new_blob)
                    elif label=="renamed":altered[policy_path+".renamed"]=altered.pop(policy_path)
                    elif label=="wrong-mode":altered[policy_path]=("100755","blob",altered[policy_path][2])
                    else:altered[policy_path]=("100644","blob",new_blob)
                    tree=changed_tree(altered)
                    commit=object_write(["commit-tree",tree,"-p",revision["commit_id"]],b"policy candidate negative\n")
                    changed_response=copy.deepcopy(response_doc);changed_receipt=json.loads(changed_response["payloads"][0]["data"])
                    changed_receipt["candidate"].update(commit_id=commit,tree_id=tree)
                    changed_receipt["changed_paths"]["count"]=len(rows)+(-1 if label=="missing" else 1 if label in {"extra","old33"} else 0)
                    receipt_raw=canonical(changed_receipt)
                    changed_response["payloads"][0].update(data=receipt_raw.decode(),sha256=sha(receipt_raw))
                    try:w._candidate_facts(ws,canonical(changed_response),incident_doc,source_facts,expected_files,rows)
                    except e.Refusal:ok(True,"actual policy Git candidate refuses "+form+"/"+label)
                    else:raise AssertionError("policy Git candidate accepted "+label)
            finally:ws.close()
    for phase in ("capture", "admit", "final-fsync"):
        damaged = case("policy-held-"+phase, policy_form=True)
        fresh_inputs(damaged)
        policy_path = package/"scope/v1/scope-policy.json"
        original_policy, original_mode = policy_path.read_bytes(), policy_path.stat().st_mode & 0o777
        original_files, original_admit, original_fsync = w._write_files, w._admit, w.os.fsync
        changed = False
        def mutate_policy():
            nonlocal changed
            if not changed:
                changed = True
                policy_path.chmod(0o600)
                policy_path.write_bytes(original_policy+b" ")
        def changed_files(*args):
            result = original_files(*args)
            if phase == "capture":mutate_policy()
            return result
        def changed_admit(*args):
            result = original_admit(*args)
            if phase == "admit":mutate_policy()
            return result
        def changed_fsync(fd):
            result = original_fsync(fd)
            if phase == "final-fsync" and set(path.name for path in damaged[3].iterdir()) == set(e.EVIDENCE_NAMES) | {"publisher-body.txt", "scope-policy.json"}:
                mutate_policy()
            return result
        w._write_files, w._admit, w.os.fsync = changed_files, changed_admit, changed_fsync
        try:
            complete(damaged, refusal=True, record_form="withheld-write-policy.v1")
            ok(changed and not (damaged[3]/"bundle.json").exists(), "held policy mutation refuses before native L at "+phase)
        finally:
            w._write_files, w._admit, w.os.fsync = original_files, original_admit, original_fsync
            policy_path.chmod(0o600);policy_path.write_bytes(original_policy);policy_path.chmod(original_mode)
    for operation in ("prepare", "prepare-policy", "reproduce", "publish"):
        untrusted = case("public-untrusted-" + operation)
        untrusted_argv = [sys.executable, "-I", "-S", "-B", str(package / "shadow/v1/write-shadow.py"), operation,
            *map(str, untrusted)]
        process = subprocess.run(untrusted_argv, env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        expected_code = b"E_PARENT_CONTEXT\n" if operation in {"prepare", "prepare-policy"} else b"E_USAGE\n"
        ok(process.returncode == 1 and process.stdout == b"" and process.stderr == expected_code,
           "actual isolated public entry refuses untrusted context or unavailable operation: " + operation)
        ok(not any(untrusted[2].iterdir()) and not any(untrusted[3].iterdir()),
           "actual untrusted public entry starts no workspace or outer write")
    cache = base.parent.parent / "ystack-portable-core-jq16" / ("jq-osx-amd64" if sys.platform == "darwin" else "jq-linux64")
    cache_digest = ("5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef" if sys.platform == "darwin"
        else "af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44")
    ok(cache.is_file() and not cache.is_symlink() and sha(cache.read_bytes()) == cache_digest,
       "scope paired control requires already verified jq1.6 cache; no download fallback")
    scope_source = (root / "scripts/test/scope-qualification.test.sh").read_text()
    scope_boundary = 'run_validator "$tmp/scope.json" || fail'
    ok(scope_source.count(scope_boundary) == 1, "existing scope fixture has one fixed evaluator boundary")
    scope_suffix = scope_source[scope_source.index(scope_boundary):]
    scope_prelude = scope_source[:scope_source.index(scope_boundary)]
    scope_root = 'root=$(CDPATH=\'\' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)'
    ok(scope_prelude.count(scope_root) == 1, "scope fixture keeps fixed physical repository root")
    scope_prelude = scope_prelude.replace(scope_root, "root=" + repr(str(root)), 1)
    scope_script = fixture / "scope-write-form.sh"
    supplied_record = fixture / "scope-write-record.json"
    write(supplied_record, first_complete["shadow-record.json"], 0o400)
    scope_tail = '''
run_evaluator "${good[@]}" > "$tmp/legacy-evaluation.json"
"$jq_bin" -e '(.body.reason_ids | index("scope.malformed")) == null' "$tmp/legacy-evaluation.json" >/dev/null || fail 'existing legacy positive malformed'
"$jq_bin" -S -c --slurpfile write_record "$1" '.body.records=[$write_record[0]]' "$tmp/shadow-set.json" > "$tmp/write-set.json"
scope_for_shadow "$tmp/write-set.json" "$tmp/write-scope.json"
run_evaluator "$tmp/write-scope.json" "$tmp/write-set.json" "$tmp/dashboard.json" "$tmp/risk.json" "$tmp/kill.json" "$tmp/duty.json" "$tmp/marker.json" > "$tmp/write-evaluation.json"
"$jq_bin" -e '.body.outcome=="not-proposable" and (.body.reason_ids | index("scope.sandbox-receipt-missing") != null) and .body.authority_effect=="none" and (.body.evidence.shadow_bundle_facts | all(.eligible==false and .authentication.state=="missing"))' "$tmp/write-evaluation.json" >/dev/null || fail 'unrelated write form supplied authentic evidence'
cat "$tmp/legacy-evaluation.json" "$tmp/write-evaluation.json"
'''
    write(scope_script, (scope_prelude + scope_tail + '\nexit "$?"\n' + scope_suffix).encode(), 0o500)
    scope_check = subprocess.run(["/bin/bash", str(scope_script), str(supplied_record)],
        env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "TMPDIR": str(base.parent.parent), "YSTACK_SCOPE_TEST_BOUNDED": "1"},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    ok(scope_check.returncode == 0, "actual scope evaluator keeps unrelated write and legacy records unqualified: " + scope_check.stderr.decode())
    print(scope_check.stdout.decode())
    ok(json.loads((root / "enforcement/v1/accepted-identities.json").read_bytes())["body"]["environments"] == [], "shipped accepted set stays empty")
    ok(w.main(["write-shadow.py", "prepare", "request", "bundle", "work", "output"]) == 1, "public prepare refuses without trusted startup admission")
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
public_prelude=prelude[:prelude.index('executable.close();native=e._NativeRelease')]+"executable.close()\n"
public_body="""
writer_spec=importlib.util.spec_from_file_location("shadow_writer_public_subject",package/"shadow/v1/write-shadow.py")
writer=importlib.util.module_from_spec(writer_spec);sys.modules[writer_spec.name]=writer
writer_spec.loader.exec_module(writer)
writer.e,writer.c=e,c
writer.require,writer.canonical,writer.sha,writer.parse=e.require,e.canonical,e.sha,e.parse
admission=dataclasses.replace(admission,module_origins=e._runtime_module_origins())
parent_inputs.recheck();parent_inputs.close()
paths=list(map(pathlib.Path,sys.argv[9:13]))
context_path=paths[0].parent/"descriptor3-parent-context.json"
write(context_path,canonical({"schema_version":2,"kind":"shadow_consumer_parent_context","id":"shadow.parent","body":parent}),0o400)
context_fd=os.open(context_path,os.O_RDONLY)
os.dup2(context_fd,3)
if context_fd!=3:os.close(context_fd)
scenario_work,scenario_output=paths[2:]
scenario_mode,scenario_request="success",paths[0]
assert e._NATIVE_ORIGIN is None and "_cancel_release" not in sys.modules
operation=sys.argv[13] if len(sys.argv)==14 else "prepare"
assert operation in {"prepare","prepare-policy"}
code=writer.main(["write-shadow.py",operation,*map(str,paths)],admission)
assert code==0,"fresh public main refusal"
assert (paths[3]/"bundle.json").exists()
record=json.loads((paths[3]/"shadow-record.json").read_bytes())
assert record["body"]["record_form"]==("withheld-write-policy.v1" if operation=="prepare-policy" else "withheld-write.v1")
print(json.dumps({"fresh_public_main":True,"descriptor3":"actual readonly regular schema2","native_first_load":str(e._NATIVE_ORIGIN),"record":record},sort_keys=True))
"""
(tmp/"writer-public-entry.py").write_text(public_prelude+public_body)
runner=tmp/"writer-native-negative.py"
runner.write_text(prelude+negative)
body="root = pathlib.Path("+repr(str(root))+")\n"+(tmp/"writer-tests.py").read_text()
body="native_public_runner = pathlib.Path("+repr(str(tmp/"writer-public-entry.py"))+")\n"+body
body="native_negative_runner = pathlib.Path("+repr(str(tmp/"writer-native-negative.py"))+")\n"+body
source=source.replace(anchor,"exec(compile("+repr(body)+", 'shadow-write-fixture-controls', 'exec'))\n"+anchor,1)
(tmp/"enforced-with-writer.sh").write_text(source)
PY
/bin/bash "$tmp/enforced-with-writer.sh"
