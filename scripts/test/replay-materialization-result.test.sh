#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
replay="$root/delivery/v1/replay.py"
fixture_builder="$root/scripts/test/local-git-materializer-fixtures.sh"
test_tmp_base=${TMPDIR:-/tmp}
tmp=$(/usr/bin/mktemp -d "${test_tmp_base%/}/ystack-replay-result.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
suite_complete=0
managed_retention=0
cleanup() {
  if [ "$suite_complete" -eq 1 ] && [ "$managed_retention" -eq 0 ]; then
    /bin/rm -rf -- "$tmp"
  else
    printf 'receiver supervision evidence retained: %s\n' "$tmp" >&2
  fi
}
trap cleanup EXIT

sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
lock_identity() {
  python3 - "$1" <<'PYLOCK'
import os
import stat
import sys

metadata = os.lstat(sys.argv[1])
if not stat.S_ISREG(metadata.st_mode):
    raise SystemExit("lock identity requires a regular file")
print(f"{metadata.st_dev}:{metadata.st_ino}")
PYLOCK
}
passed=0
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Linux:x86_64) jq_asset=jq-linux64; jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  Darwin:x86_64|Darwin:arm64) jq_asset=jq-osx-amd64; jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  *) fail "unsupported host $platform" ;;
esac
jq_source="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset"
[ -f "$jq_source" ] && [ ! -L "$jq_source" ] && [ "$(sha_file "$jq_source")" = "$jq_sha" ] ||
  fail 'pinned jq 1.6 is required'
bin="$tmp/bin"
/bin/mkdir -m 700 "$bin"
/bin/cp "$jq_source" "$bin/jq"
/bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"
export PATH="$bin:/usr/bin:/bin"

runtime="$tmp/runtime"
/bin/mkdir -m 700 "$runtime"
/usr/bin/cc -std=c11 -O2 -Wall -Wextra -Werror "$root/adapters/local-git-materializer/v1/object-closure.c" \
  -o "$runtime/object-closure"

git_clean() {
  env -i PATH=/usr/bin:/bin LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git -c core.hooksPath=/dev/null "$@"
}

make_source() {
  local destination=$1 tree base commit
  git_clean init --bare "$destination" >/dev/null
  base=$(printf 'alpha\nbeta\n' | git_clean --git-dir="$destination" hash-object -w --stdin)
  GIT_INDEX_FILE="$tmp/source-index" git_clean --git-dir="$destination" update-index \
    --add --cacheinfo 100644,"$base",source.txt
  tree=$(GIT_INDEX_FILE="$tmp/source-index" git_clean --git-dir="$destination" write-tree)
  commit=$(printf 'source\n' | git_clean --git-dir="$destination" commit-tree "$tree")
  git_clean --git-dir="$destination" update-ref refs/heads/main "$commit"
  printf '%s %s\n' "$commit" "$tree"
}

read -r source_commit source_tree < <(make_source "$tmp/source.git")
"$fixture_builder" build "$tmp/fixture" "$jq_bin" sha1 "$source_commit" "$source_tree"
input="$tmp/fixture/input.json"
expected=$(printf 'alpha\nbeta\ngamma\n' | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
key="$tmp/delivery-key.json"
"$jq_bin" -S -c '{stage_key:(.stage_request.content.body |
  {initiative_id,workflow_id,stage_id,task_class_id}),
  request_sha256:.stage_request.sha256,operation:"dispatch-stage",
  attempt_number:.attempt.attempt_number}' "$input" > "$key"

make_roots() {
  local prefix=$1
  /bin/mkdir -m 700 "$tmp/$prefix-state" "$tmp/$prefix-candidate" "$tmp/$prefix-scratch"
}

set_replay_args() {
  local prefix=$1
  replay_arguments=(--input "$input" --delivery-key "$key" \
    --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
    --candidate-root "$tmp/$prefix-candidate" --scratch-root "$tmp/$prefix-scratch" \
    --state-dir "$tmp/$prefix-state" --closure-helper "$runtime/object-closure" \
    --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected")
}

identity_control="$tmp/lock-identity-control"
printf 'original\n' > "$identity_control"
printf 'replacement\n' > "$tmp/lock-identity-replacement"
control_before=$(lock_identity "$identity_control")
[ "$(lock_identity "$identity_control")" = "$control_before" ] || fail lock-identity-unchanged
/bin/mv "$identity_control" "$tmp/lock-identity-retained"
/bin/mv "$tmp/lock-identity-replacement" "$identity_control"
[ "$(lock_identity "$identity_control")" != "$control_before" ] || fail lock-identity-replacement
for nonregular in "$tmp/lock-identity-missing" "$tmp"; do
  if lock_identity "$nonregular" > "$tmp/lock-identity-invalid.out" 2> "$tmp/lock-identity-invalid.err"; then
    fail lock-identity-invalid-accepted
  fi
  [ ! -s "$tmp/lock-identity-invalid.out" ] || fail lock-identity-invalid-output
done

make_roots stored
set_replay_args stored
stored_args=("${replay_arguments[@]}")
python3 "$replay" "${stored_args[@]}" > "$tmp/stored-delivery.out"
"$jq_bin" -e '.state.schema_version==2 and .state.phase=="review-wait" and
  .state.receiver_result.status=="stored"' "$tmp/stored-delivery.out" >/dev/null || fail stored-delivery
"$jq_bin" -e '.schema_version==2 and .receiver_result.status=="stored" and
  .receiver_result.response_utf8[-1:]=="\n"' "$tmp/stored-state/run.json" >/dev/null || fail stored-journal
pass 'keyed delivery publishes actual response bytes in journal version 2'

journal_before=$(sha_file "$tmp/stored-state/run.json")
lock_identity_before=$(lock_identity "$tmp/stored-state/replay.lock")
python3 "$replay" "${stored_args[@]}" --read-materialization-result > "$tmp/stored-read.out"
"$jq_bin" -e '.kind=="delivery_replay_materialization_result" and .status=="stored" and
  .stage_result.content.kind=="stage_result" and
  .receipt.content_id=="candidate.materialization.receipt" and
  .response_utf8[-1:]=="\n"' "$tmp/stored-read.out" >/dev/null || fail stored-read
[ "$(sha_file "$tmp/stored-state/run.json")" = "$journal_before" ] || fail stored-read-mutated
lock_identity_after=$(lock_identity "$tmp/stored-state/replay.lock")
[ "$lock_identity_after" = "$lock_identity_before" ] ||
  fail "stored-lock-replaced: before=$lock_identity_before after=$lock_identity_after"
pass 'fresh read returns scanner-ready actual result without changing state or lock'

snapshot="$tmp/scanner-snapshot.json"
"$jq_bin" -S -c -n --slurpfile input "$input" --slurpfile retrieved "$tmp/stored-read.out" \
  --arg source_commit "$source_commit" '{
    schema_version:1,kind:"orchestrator_state_snapshot",id:"snapshot.materialization-result",
    body:{
      core_contract:{
        generation_id_sha256:"84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
        package_ref:{content_id:"core-contract-package.v2",
          media_type:"application/vnd.ystack.core-contract+json",
          sha256:"eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"},
        semantic_identity:"core.contracts.v2"},
      items:[{attempt:{state:"absent"},latest_result:{state:"present",value:$retrieved[0].stage_result},
        request:$input[0].stage_request,resolved_profile:$input[0].resolved_profile,retry_limit:2}],
      observed_at:"2026-08-30T00:10:00Z",
      snapshot_contract:{completeness:"complete",declared_item_count:1,maximum_item_count:64,
        schema_identity:"orchestrator.state-snapshot.v1"},
      source_revision:{repository_id:"fixture.target",hash_algorithm:"sha1",commit_id:$source_commit}}
  }' > "$snapshot"
"$root/orchestrator/v1/scan-state.sh" scan fixture.target "$source_commit" "$snapshot" \
  > "$tmp/scanner.out"
"$jq_bin" -e '.body.classifications == [(.body.classifications[0])] and
  .body.classifications[0].class=="terminal" and
  .body.classifications[0].recovery.reason_id=="scanner.stage-completed"' \
  "$tmp/scanner.out" >/dev/null || fail scanner-result
pass 'real retrieved result passes the scanner as terminal'

python3 "$replay" "${stored_args[@]}" > "$tmp/stored-redelivery.out"
[ "$(sha_file "$tmp/stored-state/run.json")" = "$journal_before" ] || fail redelivery-mutated
pass 'same key and frozen input reuse stored result without materialization'

empty_input="$tmp/empty-input.json"
empty_intermediate="$tmp/empty-intermediate.json"
empty_request="$tmp/empty-request.json"
empty_sha=$(printf '' | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
"$jq_bin" -S -c --arg sha "$empty_sha" '
  (.stage_request.content.body.inputs[] |
    select(.input_id=="input.producer-patch") | .value.value.value.sha256)=$sha |
  (.payloads[] | select(.input_id=="input.producer-patch") | .data)="" |
  (.trust_context.verified_payloads[] |
    select(.input_id=="input.producer-patch") | .content.data)="" |
  (.trust_context.verified_payloads[] |
    select(.input_id=="input.producer-patch") | .sha256)=$sha' \
  "$input" > "$empty_intermediate"
"$jq_bin" -S -c '.stage_request.content' "$empty_intermediate" > "$empty_request"
"$jq_bin" -S -c --arg sha "$(sha_file "$empty_request")" \
  '.stage_request.sha256=$sha' "$empty_intermediate" > "$empty_input"
original_input=$input
original_key=$key
original_expected=$expected
input=$empty_input
key="$tmp/empty-key.json"
expected=$(printf 'alpha\nbeta\n' | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
"$jq_bin" -S -c '{stage_key:(.stage_request.content.body |
  {initiative_id,workflow_id,stage_id,task_class_id}),
  request_sha256:.stage_request.sha256,operation:"dispatch-stage",
  attempt_number:.attempt.attempt_number}' "$input" > "$key"
make_roots no-change
set_replay_args no-change
python3 "$replay" "${replay_arguments[@]}" > "$tmp/no-change-delivery.out"
python3 "$replay" "${replay_arguments[@]}" --read-materialization-result > "$tmp/no-change-read.out"
"$jq_bin" -e '.stage_result.content.body.outcome.value=="no-change" and
  .stage_result.content.body.outputs==[] and .receipt.data[-1:]=="\n"' \
  "$tmp/no-change-read.out" >/dev/null || fail no-change-result
no_change_snapshot="$tmp/no-change-snapshot.json"
"$jq_bin" -S -c -n --slurpfile input "$input" --slurpfile retrieved "$tmp/no-change-read.out" \
  --arg source_commit "$source_commit" '{
    schema_version:1,kind:"orchestrator_state_snapshot",id:"snapshot.no-change-result",
    body:{core_contract:{
      generation_id_sha256:"84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
      package_ref:{content_id:"core-contract-package.v2",
        media_type:"application/vnd.ystack.core-contract+json",
        sha256:"eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"},
      semantic_identity:"core.contracts.v2"},items:[{
        attempt:{state:"absent"},latest_result:{state:"present",value:$retrieved[0].stage_result},
        request:$input[0].stage_request,resolved_profile:$input[0].resolved_profile,retry_limit:2}],
      observed_at:"2026-08-30T00:10:00Z",
      snapshot_contract:{completeness:"complete",declared_item_count:1,maximum_item_count:64,
        schema_identity:"orchestrator.state-snapshot.v1"},
      source_revision:{repository_id:"fixture.target",hash_algorithm:"sha1",commit_id:$source_commit}}}
  ' > "$no_change_snapshot"
"$root/orchestrator/v1/scan-state.sh" scan fixture.target "$source_commit" "$no_change_snapshot" \
  > "$tmp/no-change-scanner.out"
"$jq_bin" -e '.body.classifications[0].class=="terminal" and
  .body.classifications[0].recovery.reason_id=="scanner.stage-completed"' \
  "$tmp/no-change-scanner.out" >/dev/null || fail no-change-scanner
pass 'actual no-change response is retained and passes the scanner as terminal'
no_change_expected=$expected
input=$original_input
key=$original_key
expected=$original_expected

wrong_key="$tmp/wrong-key.json"
"$jq_bin" -S -c '.stage_key.stage_id="stage.wrong"' "$key" > "$wrong_key"
set +e
python3 "$replay" "${stored_args[@]}" --delivery-key "$wrong_key" \
  --read-materialization-result > "$tmp/wrong.out" 2> "$tmp/wrong.err"
status=$?
set -e
[ "$status" -eq 2 ] && [ "$(sha_file "$tmp/stored-state/run.json")" = "$journal_before" ] ||
  fail wrong-key
pass 'conflicting key is rejected without changing stored evidence'

set +e
python3 "$replay" "${stored_args[@]}" --read-materialization-result \
  --review-observation "$key" > "$tmp/observation.out" 2> "$tmp/observation.err"
status=$?
set -e
if [ "$status" -ne 1 ] ||
   ! grep -Fq 'does not accept workflow observations' "$tmp/observation.err"; then
  fail read-observation
fi
pass 'read mode rejects workflow observations'

make_roots legacy
set_replay_args legacy
legacy_args=("${replay_arguments[@]}")
legacy_without_key=()
skip=0
for value in "${legacy_args[@]}"; do
  if [ "$skip" -eq 1 ]; then skip=0; continue; fi
  if [ "$value" = --delivery-key ]; then skip=1; continue; fi
  legacy_without_key+=("$value")
done
python3 "$replay" "${legacy_without_key[@]}" > "$tmp/legacy.out"
set +e
python3 "$replay" "${legacy_without_key[@]}" --read-materialization-result > "$tmp/legacy-read.out"
status=$?
set -e
if [ "$status" -ne 3 ] || ! "$jq_bin" -e '.status=="unavailable" and
   .reason_id=="replay.legacy-result-unavailable" and (has("stage_result")|not)' \
   "$tmp/legacy-read.out" >/dev/null; then
  fail legacy-read
fi
pass 'version 1 remains unavailable as original result evidence'

loaded_wrapper="$tmp/loaded-driver-wrapper.py"
cat > "$loaded_wrapper" <<'PY'
import importlib.util
import hashlib
import json
import pathlib
import os
import sys
import time

path, mode, control, *arguments = sys.argv[1:]
if mode in ("pause", "lifecycle"):
    point, ready, release, *arguments = arguments
elif mode == "supervised-pause":
    point, token, admission_fd, phase_fd, *arguments = arguments
    admission_fd, phase_fd = int(admission_fd), int(phase_fd)
    admitted = os.read(admission_fd, 2)
    os.close(admission_fd)
    if admitted != b"1":
        raise SystemExit("invalid supervisor admission")
    os.set_inheritable(phase_fd, False)
    def shared_monotonic():
        return time.clock_gettime(time.CLOCK_MONOTONIC)
    phase_sequence = 0
    def supervised_phase(name, **facts):
        global phase_sequence
        phase_sequence += 1
        value = json.dumps({"token": token, "case": point, "sequence": phase_sequence,
                            "phase": name, **facts}, sort_keys=True).encode() + b"\n"
        if len(value) > 4096 or os.write(phase_fd, value) != len(value):
            raise SystemExit("supervisor phase write failed")
    supervised_phase("entry")
elif mode == "read-audit":
    audit_target, audit_limit, *arguments = arguments
elif mode == "source-root":
    source_root, *arguments = arguments
spec = importlib.util.spec_from_file_location("replay", path)
module = importlib.util.module_from_spec(spec)
module._REPLAY_DRIVER_BYTES = pathlib.Path(path).read_bytes()
if mode == "driver-drift":
    module._REPLAY_DRIVER_BYTES += b"\n"
    pathlib.Path(control).write_text(hashlib.sha256(module._REPLAY_DRIVER_BYTES).hexdigest() + "\n")
exec(compile(module._REPLAY_DRIVER_BYTES, path, "exec"), module.__dict__)
if mode == "supervised-pause":
    original_capture = module.capture_materializer
    def supervised_capture(*values):
        supervised_phase("materializer-entry")
        response = original_capture(*values)
        pathlib.Path(control + ".response").write_bytes(response)
        supervised_phase("materializer-return")
        return response
    module.capture_materializer = supervised_capture
    original_journal = module.write_journal
    def supervised_publication(target, state):
        stored = state.get("receiver_result", {}).get("status") == "stored"
        verifying = state.get("phase") == "verifying"
        if stored and verifying:
            prepublication_started = time.monotonic()
            supervised_phase("pre-publication", clock="CLOCK_MONOTONIC",
                             shared_monotonic=shared_monotonic())
            while time.monotonic() - prepublication_started < 12:
                time.sleep(0.02)
            prepublication_finished = time.monotonic()
        if point == "before" and stored and verifying:
            supervised_phase("ready", clock="CLOCK_MONOTONIC",
                             shared_monotonic=shared_monotonic(),
                             hold_seconds=prepublication_finished - prepublication_started,
                             publication_state="pending")
            ready_deadline = time.monotonic() + 20
            while time.monotonic() < ready_deadline:
                time.sleep(0.02)
            raise AssertionError("supervised before hold expired")
        original_journal(target, state)
        if point == "after" and stored and verifying:
            supervised_phase("ready", clock="CLOCK_MONOTONIC",
                             shared_monotonic=shared_monotonic(),
                             hold_seconds=prepublication_finished - prepublication_started,
                             publication_state="completed")
            ready_deadline = time.monotonic() + 20
            while time.monotonic() < ready_deadline:
                time.sleep(0.02)
            raise AssertionError("supervised after hold expired")
    module.write_journal = supervised_publication
elif mode in ("count", "count-gate"):
    if mode == "count-gate":
        original_lock = module.fcntl.flock
        def lock_wait(descriptor, operation):
            pathlib.Path(control + ".started." + str(os.getpid())).write_text("lock-wait\n")
            return original_lock(descriptor, operation)
        module.fcntl.flock = lock_wait
    original = module.capture_materializer
    def counted(*values):
        if mode == "count-gate":
            pathlib.Path(control + ".ready").write_text("ready\n")
            deadline = time.monotonic() + 20
            while not pathlib.Path(control + ".release").exists():
                if time.monotonic() >= deadline:
                    raise AssertionError("count gate watchdog")
                time.sleep(0.02)
        with pathlib.Path(control).open("a") as handle:
            handle.write("invoked\n")
        captured = original(*values)
        pathlib.Path(control + ".response").write_bytes(captured)
        return captured
    module.capture_materializer = counted
elif mode == "lifecycle":
    import stat
    original_capture = module.capture_materializer
    def gate():
        pathlib.Path(ready).write_text("ready\n")
        deadline = time.monotonic() + 20
        while not pathlib.Path(release).exists():
            if time.monotonic() >= deadline:
                raise AssertionError("lifecycle gate watchdog")
            time.sleep(0.02)
    def captured(*values):
        if point == "pre-effect":
            gate()
        with pathlib.Path(control).open("a") as handle:
            handle.write("invoked\n")
        if point == "output-overflow":
            original_process = module._capture_fixed_process
            arguments_value, execution, input_path = values
            expected = module.materializer_command(arguments_value, execution, input_path,
                pathlib.Path(arguments_value.candidate_root).resolve(), pathlib.Path(arguments_value.scratch_root).resolve())
            def overflow(command, environment, limit):
                if command != expected:
                    return original_process(command, environment, limit)
                assert environment == {"PATH": "/usr/bin:/bin", "LC_ALL": "C"} and limit == 1024 * 1024
                actual = original_process(command, environment, limit)
                assert actual.returncode == 0 and actual.stdout and len(actual.stdout) <= limit
                pathlib.Path(control + ".response").write_bytes(actual.stdout)
                pathlib.Path(control + ".capture").write_text(json.dumps({"command": command,
                    "environment": environment, "limit": limit, "actual_exit": actual.returncode,
                    "actual_stdout_bytes": len(actual.stdout), "injected_stdout_bytes": limit + 1}) + "\n")
                gate()
                return module.subprocess.CompletedProcess(command, actual.returncode, b'x' * (limit + 1), actual.stderr)
            module._capture_fixed_process = overflow
            try:
                return original_capture(*values)
            finally:
                module._capture_fixed_process = original_process
        response = original_capture(*values)
        pathlib.Path(control + ".response").write_bytes(response)
        if point == "output-malformed":
            gate()
            return b"{"
        return response
    module.capture_materializer = captured
    if point == "reply":
        original_result = module.result
        def reply(state):
            assert state.get("receiver_result", {}).get("status") == "stored"
            gate()
            return original_result(state)
        module.result = reply
    original_journal = module.write_journal
    def publication(target, state):
        stored = state.get("receiver_result", {}).get("status") == "stored"
        if not stored or state.get("phase") != "verifying":
            return original_journal(target, state)
        assert target.name == "run.json" and pathlib.Path(control + ".response").exists()
        if point == "before" or point.startswith("fault-"):
            gate()
        if not point.startswith("fault-"):
            original_journal(target, state)
            if point == "after":
                gate()
            return
        fault = point[6:]
        fdopen, fsync, replace = module.os.fdopen, module.os.fsync, module.os.replace
        observed = []
        def fail(operation):
            observed.append(operation)
            pathlib.Path(control + ".fault").write_text(operation + "\n")
            raise OSError("injected stored publication " + operation)
        class Handle:
            def __init__(self, wrapped):
                self.wrapped = wrapped
            def __enter__(self):
                self.wrapped.__enter__()
                return self
            def __exit__(self, *values):
                return self.wrapped.__exit__(*values)
            def write(self, data):
                if fault == "write":
                    fail("write")
                return self.wrapped.write(data)
            def flush(self):
                if fault == "flush":
                    fail("flush")
                return self.wrapped.flush()
            def fileno(self):
                return self.wrapped.fileno()
        def opened(descriptor, *values, **keywords):
            return Handle(fdopen(descriptor, *values, **keywords))
        def synced(descriptor):
            directory = stat.S_ISDIR(module.os.fstat(descriptor).st_mode)
            if fault == ("directory-fsync" if directory else "file-fsync"):
                fail(fault)
            return fsync(descriptor)
        def replaced(source, destination):
            assert pathlib.Path(destination) == target
            if fault == "rename":
                fail("rename")
            return replace(source, destination)
        module.os.fdopen, module.os.fsync, module.os.replace = opened, synced, replaced
        try:
            return original_journal(target, state)
        finally:
            module.os.fdopen, module.os.fsync, module.os.replace = fdopen, fsync, replace
            assert observed == [fault], (fault, observed)
    module.write_journal = publication
elif mode == "pause":
    original = module.write_journal
    def paused(target, state):
        stored = state.get("receiver_result", {}).get("status") == "stored"
        if point == "before" and stored:
            pathlib.Path(ready).write_text("ready\n")
            while not pathlib.Path(release).exists():
                time.sleep(0.02)
        original(target, state)
        if point == "after" and stored and state.get("phase") == "verifying":
            pathlib.Path(ready).write_text("ready\n")
            while not pathlib.Path(release).exists():
                time.sleep(0.02)
    module.write_journal = paused
elif mode in ("git-observe", "git-overflow", "git-nonzero"):
    candidate = pathlib.Path(arguments[arguments.index("--candidate-root") + 1]).resolve()
    state = pathlib.Path(arguments[arguments.index("--state-dir") + 1])
    journal = json.loads((state / "run.json").read_bytes())
    expected_command = ["/usr/bin/git", f"--git-dir={candidate / 'repository.git'}",
                        "diff-tree", "--no-commit-id", "--name-only", "-r",
                        journal["identity"]["source_commit_id"],
                        journal["materialization"]["candidate_commit_id"]]
    original = module._capture_fixed_process
    def checked_capture(command, environment, limit):
        if command != expected_command or environment != module.GIT_ENVIRONMENT or limit != 2 * 1024 * 1024:
            raise AssertionError(("unexpected fixed Git invocation", command, environment, limit))
        pathlib.Path(control).write_text(json.dumps(command) + "\n")
        if mode == "git-overflow":
            command = [sys.executable, "-c", "import sys; sys.stdout.buffer.write(b'x' * (2*1024*1024+1))"]
        elif mode == "git-nonzero":
            command = [sys.executable, "-c", "raise SystemExit(7)"]
        return original(command, environment, limit)
    module._capture_fixed_process = checked_capture
elif mode == "read-audit":
    original = module.read_bytes
    def audited_read(target, limit):
        if pathlib.Path(target) != pathlib.Path(audit_target):
            return original(target, limit)
        assert limit == int(audit_limit)
        observed = {"path": str(target), "limit": limit,
                    "file_bytes": pathlib.Path(target).stat().st_size}
        try:
            result = original(target, limit)
        except module.ReplayError as error:
            observed["refusal"] = str(error)
            raise
        else:
            observed["returned_bytes"] = len(result)
            return result
        finally:
            pathlib.Path(control).write_text(json.dumps(observed) + "\n")
    module.read_bytes = audited_read
elif mode == "source-root":
    module.__file__ = str(pathlib.Path(source_root) / "delivery/v1/replay.py")
elif mode == "driver-drift":
    pass
else:
    raise AssertionError(("unknown wrapper mode", mode))
if mode in ("count", "count-gate", "lifecycle", "supervised-pause"):
    original_reconcile = module.reconcile_materialization
    def counted_reconciliation(*values):
        with pathlib.Path(control).open("a") as handle:
            handle.write("reconciled\n")
        return original_reconcile(*values)
    module.reconcile_materialization = counted_reconciliation
sys.argv = [path] + arguments
raise SystemExit(module.main())
PY
make_roots concurrent
set_replay_args concurrent
concurrent_args=("${replay_arguments[@]}")
python3 "$loaded_wrapper" "$replay" count "$tmp/invocations" "${concurrent_args[@]}" \
  > "$tmp/concurrent-1.out" &
first=$!
python3 "$loaded_wrapper" "$replay" count "$tmp/invocations" "${concurrent_args[@]}" \
  > "$tmp/concurrent-2.out" &
second=$!
wait "$first"
wait "$second"
[ "$(wc -l < "$tmp/invocations" | tr -d ' ')" -eq 1 ] || fail concurrent-invocations
"$jq_bin" -e '.state.receiver_result.status=="stored"' "$tmp/concurrent-1.out" >/dev/null ||
  fail concurrent-first
"$jq_bin" -e '.state.receiver_result.status=="stored"' "$tmp/concurrent-2.out" >/dev/null ||
  fail concurrent-second
pass 'concurrent matching deliveries serialize to one real materializer invocation'

strict_state="$tmp/strict-state"
strict_candidate="$tmp/strict-candidate"
strict_scratch="$tmp/strict-scratch"
for key_case in duplicate trailing bom ordinal boolean fraction; do
  /bin/rm -rf -- "$strict_state" "$strict_candidate" "$strict_scratch"
  /bin/mkdir -m 700 "$strict_state" "$strict_candidate" "$strict_scratch"
  candidate_key="$tmp/key-$key_case.json"
  case "$key_case" in
    duplicate) /usr/bin/sed 's/"operation":"dispatch-stage"/"operation":"dispatch-stage","operation":"dispatch-stage"/' "$key" > "$candidate_key" ;;
    trailing) { /bin/cat "$key"; printf '{}\n'; } > "$candidate_key" ;;
    bom) { printf '\357\273\277'; /bin/cat "$key"; } > "$candidate_key" ;;
    ordinal) "$jq_bin" -S -c '.delivery_ordinal=2' "$key" > "$candidate_key" ;;
    boolean) "$jq_bin" -S -c '.attempt_number=true' "$key" > "$candidate_key" ;;
    fraction) "$jq_bin" -S -c '.attempt_number=1.5' "$key" > "$candidate_key" ;;
  esac
  set +e
  python3 "$replay" --input "$input" --delivery-key "$candidate_key" \
    --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
    --candidate-root "$strict_candidate" --scratch-root "$strict_scratch" \
    --state-dir "$strict_state" --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" \
    --verify-path source.txt --expected-sha256 "$expected" > "$tmp/key-$key_case.out" 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] && [ ! -e "$strict_state/run.json" ] || fail "strict-key-$key_case"
done
pass 'strict key parsing rejects duplicate, trailing, BOM, extra, boolean, and fractional data'

receiver_generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\([^']*\)'$/\1/p" "$root/scripts/core-contract.sh")
[ -n "$receiver_generation" ] || fail receiver-generation-missing
receiver_route=(
  delivery/v1/replay.py
  adapters/local-git-materializer/v1/materialize.sh
  adapters/local-git-materializer/v1/protocol.jq
  adapters/local-git-materializer/v1/object-closure.c
  scripts/core-contract.sh
  core/v2/generation-registry.json
  "core/v2/generations/$receiver_generation/core-ingress.sh"
  "core/v2/generations/$receiver_generation/contracts.jq"
  "core/v2/generations/$receiver_generation/modules/schema.jq"
  "core/v2/generations/$receiver_generation/modules/profile_graph.jq"
  "core/v2/generations/$receiver_generation/modules/stage_request.jq"
  "core/v2/generations/$receiver_generation/modules/result_facts.jq"
  "core/v2/generations/$receiver_generation/modules/result_truth.jq"
)
receiver_route_manifest="$tmp/receiver-route.tsv"
python3 - "$root" "$tmp/stored-state/execution" "$runtime/object-closure" "$jq_bin" \
  "$receiver_generation" "$receiver_route_manifest" "${receiver_route[@]}" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

root, execution, closure, jq, generation, manifest, *relative_paths = sys.argv[1:]
root, execution = Path(root), Path(execution)
registry = json.loads((root / "core/v2/generation-registry.json").read_bytes())
assert [item["generation_id"] for item in registry].count(generation) == 1
forbidden = re.compile(
    rb"\b(?:setsid|setpgid|start_new_session|disown|daemon)\b|"
    rb"(?:^|[;\n])[ \t]*set[ \t]+(?:-m|-o[ \t]+monitor)\b", re.MULTILINE)
lines = []
for relative in relative_paths:
    source = root / relative
    data = source.read_bytes()
    assert forbidden.search(data) is None, relative
    mode = stat.S_IMODE(source.stat().st_mode)
    lines.append(("source", relative, hashlib.sha256(data).hexdigest(), f"{mode:o}"))
    if relative not in ("delivery/v1/replay.py",
                         "adapters/local-git-materializer/v1/object-closure.c"):
        snapshot = execution / relative
        assert snapshot.read_bytes() == data, relative
assert (execution / ".dependencies/object-closure").read_bytes() == Path(closure).read_bytes()
assert (execution / ".dependencies/jq").read_bytes() == Path(jq).read_bytes()
for label, path in (("object-closure", closure), ("jq-1.6", jq)):
    value = Path(path)
    assert value.is_file() and os.access(value, os.X_OK)
    lines.append(("executable", label, hashlib.sha256(value.read_bytes()).hexdigest(),
                  f"{stat.S_IMODE(value.stat().st_mode):o}"))
Path(manifest).write_text("".join("\t".join(row) + "\n" for row in lines))
PY
receiver_tool_manifest="$tmp/receiver-tools.tsv"
python_executable=$(command -v python3)
bash_executable=$(command -v bash)
git_executable=$(command -v git)
{
  printf 'python\t%s\t%s\t' "$python_executable" "$(sha_file "$python_executable")"
  "$python_executable" --version 2>&1
  printf 'bash\t%s\t%s\t' "$bash_executable" "$(sha_file "$bash_executable")"
  "$bash_executable" --version | /usr/bin/sed -n '1p'
  printf 'git\t%s\t%s\t' "$git_executable" "$(sha_file "$git_executable")"
  "$git_executable" --version
  printf 'jq\t%s\t%s\t' "$jq_bin" "$(sha_file "$jq_bin")"
  "$jq_bin" --version
} > "$receiver_tool_manifest"
pass 'receiver containment route fixes source and executable identities without an escape primitive'


receiver_supervisor="$tmp/receiver-supervisor.py"
cat > "$receiver_supervisor" <<'PY'
import errno
import base64
import fcntl
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time

case, token, start_path, cancel_path, completion_path, stdout_path, stderr_path, wrapper, replay, point, control, *arguments = sys.argv[1:]
diagnostic_path = str(completion_path) + ".diagnostic-fifo"
diagnostic_reader_ready = Path(str(completion_path) + ".diagnostic-reader-ready")
def shared_monotonic():
    return time.clock_gettime(time.CLOCK_MONOTONIC)


started = shared_monotonic()
inherited_sigchld_ignored = signal.getsignal(signal.SIGCHLD) == signal.SIG_IGN
inherited_blocked = []
if hasattr(signal, "pthread_sigmask"):
    inherited_blocked = sorted(number.value for number in
        signal.pthread_sigmask(signal.SIG_BLOCK, set()) if number in (signal.SIGINT, signal.SIGTERM))
admission_deadline = started + 5
setup_deadline = started + 60
cleanup_deadline = None
diagnostic_deadline = None
pending_signal = []
primary = None
cleanup_errors = []
diagnostic_errors = []
diagnostic_emitted = False
diagnostic_flags_restored = False
diagnostic_sink_connected = False
diagnostic_blocked_writes = 0
diagnostic_prefill_bytes = 0
possible_admission = False
signal_attempt = None
signal_attempts = 0
authority = False
pid_authority = False
owned_pid = owned_pgid = owned_sid = None
raw_status = decoded_status = None
rescue_status = None
reaped = group_absent = False
capture_complete = False
phase_records = []
wire_sequence = 0
phase_buffer = bytearray()
control_bytes = 0
max_control_record = 0
stream_data = {"stdout": bytearray(), "stderr": bytearray()}
stream_bytes = {"stdout": 0, "stderr": 0}
stream_eof = {"stdout": False, "stderr": False}
ready_at = None
ready_elapsed = None
prepublication_at = None
prepublication_elapsed = None
process = None
channel_selector = selectors.DefaultSelector()
wait_eintr_injected = False
read_failure_injected = False
drain_pending_observations = 0


def first_failure(message):
    global primary
    if primary is None:
        primary = message


def deferred_signal(number, frame):
    if not pending_signal:
        pending_signal.append(number)


def bounded_write(path, data, limit):
    if len(data) > limit:
        raise ValueError("diagnostic exceeds limit")
    temporary = Path(str(path) + ".next")
    temporary.write_bytes(data)
    os.replace(temporary, path)


def emit_diagnostic(path, data):
    global diagnostic_emitted, diagnostic_flags_restored
    global diagnostic_sink_connected, diagnostic_blocked_writes, diagnostic_prefill_bytes
    descriptor = None
    prior_flags = None
    try:
        if case == "diagnostic-broken-sink":
            broken_read, descriptor = os.pipe()
            os.close(broken_read)
        else:
            while not diagnostic_reader_ready.exists() and shared_monotonic() < diagnostic_deadline:
                time.sleep(0.01)
            if not diagnostic_reader_ready.exists():
                raise TimeoutError("diagnostic reader connection deadline expired")
            descriptor = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
            diagnostic_sink_connected = True
        prior_flags = fcntl.fcntl(descriptor, fcntl.F_GETFL)
        fcntl.fcntl(descriptor, fcntl.F_SETFL, prior_flags | os.O_NONBLOCK)
        if point == "cancel-diagnostic-publication":
            boundary("diagnostic-publication")
        if case == "diagnostic-blocked-sink":
            while shared_monotonic() < diagnostic_deadline:
                try:
                    diagnostic_prefill_bytes += os.write(descriptor, b"x" * 4096)
                except BlockingIOError:
                    diagnostic_blocked_writes += 1
                    break
            if diagnostic_blocked_writes == 0:
                raise TimeoutError("diagnostic sink did not reach blocked state")
        offset = 0
        while offset < len(data):
            consume_cancellation("diagnostic-publication")
            if shared_monotonic() >= diagnostic_deadline:
                raise TimeoutError("diagnostic write deadline expired")
            try:
                written = os.write(descriptor, data[offset:offset + 4096])
            except BlockingIOError:
                diagnostic_blocked_writes += 1
                time.sleep(0.01)
                continue
            if written <= 0:
                raise OSError("diagnostic write made no progress")
            offset += written
        consume_cancellation("diagnostic-publication")
        diagnostic_emitted = True
    finally:
        if descriptor is not None and prior_flags is not None:
            if case == "diagnostic-restore-failure":
                closed_descriptor = descriptor
                os.close(descriptor)
                descriptor = None
                fcntl.fcntl(closed_descriptor, fcntl.F_SETFL, prior_flags)
            else:
                fcntl.fcntl(descriptor, fcntl.F_SETFL, prior_flags)
                diagnostic_flags_restored = True
        if descriptor is not None:
            os.close(descriptor)


def control_record(path, kind):
    try:
        value = json.loads(Path(path).read_bytes())
    except (OSError, ValueError):
        return None
    expected = {"case": case, "kind": kind, "token": token}
    return value if value == expected else None


def observed_signal():
    if pending_signal:
        return pending_signal[0]
    if hasattr(signal, "sigpending"):
        pending = signal.sigpending()
        for number in (signal.SIGINT, signal.SIGTERM):
            if number in pending:
                return number
    return None


def cancellation_seen():
    return bool(observed_signal() or control_record(cancel_path, "cancel"))


def consume_cancellation(where):
    if cancellation_seen():
        first_failure("cancelled at " + where)
        return True
    return False


def boundary(name):
    bounded_write(str(completion_path) + ".state",
                  json.dumps({"boundary": name, "token": token}, sort_keys=True).encode() + b"\n",
                  4096)
    if point != "cancel-" + name:
        return
    deadline = shared_monotonic() + 5
    while not cancellation_seen() and shared_monotonic() < deadline:
        time.sleep(0.01)
    if cancellation_seen():
        first_failure("cancelled at " + name)
    else:
        first_failure("cancellation control deadline expired at " + name)


def read_channels(selector, timeout):
    global control_bytes, max_control_record, wire_sequence, read_failure_injected
    global drain_pending_observations
    global prepublication_at, prepublication_elapsed, ready_at, ready_elapsed
    for key, _ in selector.select(max(0, timeout)):
        name = key.data
        try:
            if case == "capture-drain-expiry" and name == "stdout" and cleanup_deadline is not None:
                drain_pending_observations += 1
                time.sleep(min(0.01, max(0, timeout)))
                continue
            if case == "capture-read-failure" and name == "stdout" and not read_failure_injected:
                read_failure_injected = True
                raise OSError(errno.EIO, "injected stream read error")
            chunk = os.read(key.fd, 4096)
        except BlockingIOError:
            continue
        except OSError as error:
            first_failure(name + " read failed: " + str(error))
            selector.unregister(key.fd)
            continue
        if not chunk:
            selector.unregister(key.fd)
            if name in stream_eof:
                stream_eof[name] = True
            elif phase_buffer:
                first_failure("truncated phase record")
            continue
        if name == "phase":
            control_bytes += len(chunk)
            if control_bytes > 64 * 1024:
                first_failure("control data exceeds limit")
                selector.unregister(key.fd)
                continue
            phase_buffer.extend(chunk)
            if len(phase_buffer) > 4096 and b"\n" not in phase_buffer:
                first_failure("control record exceeds limit")
                selector.unregister(key.fd)
                continue
            while b"\n" in phase_buffer:
                raw, _, remainder = phase_buffer.partition(b"\n")
                phase_buffer[:] = remainder
                max_control_record = max(max_control_record, len(raw) + 1)
                if len(raw) + 1 > 4096:
                    first_failure("control record exceeds limit")
                    continue
                try:
                    record = json.loads(raw)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    first_failure("malformed phase record")
                    continue
                wire_sequence += 1
                if (record.get("case") != point or record.get("sequence") != wire_sequence
                        or record.get("token") != token):
                    first_failure("wrong control identity or sequence")
                    continue
                if record.get("kind") == "padding":
                    continue
                expected = len(phase_records) + 1
                allowed = ["entry", "materializer-entry", "materializer-return",
                           "pre-publication", "ready"]
                if expected > len(allowed) or record["phase"] != allowed[expected - 1]:
                    first_failure("out-of-order phase record")
                    continue
                phase_records.append(record)
                if record["phase"] == "pre-publication":
                    if (record.get("clock") != "CLOCK_MONOTONIC"
                            or type(record.get("shared_monotonic")) not in (int, float)):
                        first_failure("invalid pre-publication timing")
                    else:
                        prepublication_at = record["shared_monotonic"]
                        prepublication_elapsed = prepublication_at - started
                elif record["phase"] == "ready":
                    if (record.get("clock") != "CLOCK_MONOTONIC"
                            or type(record.get("shared_monotonic")) not in (int, float)
                            or type(record.get("hold_seconds")) not in (int, float)):
                        first_failure("invalid ready timing")
                    else:
                        ready_at = record["shared_monotonic"]
                        ready_elapsed = ready_at - started
        else:
            stream_bytes[name] += len(chunk)
            remaining = 64 * 1024 - len(stream_data[name])
            stream_data[name].extend(chunk[:max(0, remaining)])
            if stream_bytes[name] > 64 * 1024:
                first_failure(name + " capture exceeds limit")


def exact_reap():
    global raw_status, decoded_status, reaped, wait_eintr_injected
    while shared_monotonic() < cleanup_deadline:
        try:
            if case == "wait-eintr" and not wait_eintr_injected:
                wait_eintr_injected = True
                raise InterruptedError()
            if case == "wait-echild":
                raise ChildProcessError("injected ECHILD at exact wait boundary")
            if case == "wait-exhausted":
                waited, status = 0, 0
            else:
                waited, status = os.waitpid(owned_pid, os.WNOHANG)
        except InterruptedError:
            continue
        except ChildProcessError as error:
            cleanup_errors.append("missing child status: " + str(error))
            return
        except OSError as error:
            cleanup_errors.append("wait failed: " + str(error))
            return
        if waited == 0:
            read_channels(channel_selector, min(0.02, cleanup_deadline - shared_monotonic()))
            continue
        if waited != owned_pid or not (os.WIFEXITED(status) or os.WIFSIGNALED(status)):
            cleanup_errors.append("unexpected wait status")
            return
        raw_status = status
        decoded_status = os.waitstatus_to_exitcode(status)
        process.returncode = decoded_status
        reaped = True
        return
    cleanup_errors.append("child reap deadline expired")


def finish_capture():
    global capture_complete
    while shared_monotonic() < cleanup_deadline and channel_selector.get_map():
        read_channels(channel_selector, min(0.02, cleanup_deadline - shared_monotonic()))
    capture_complete = stream_eof["stdout"] and stream_eof["stderr"]
    if not capture_complete:
        cleanup_errors.append("stream capture incomplete")


def confirm_group_absence(inject_faults):
    global group_absent
    while shared_monotonic() < cleanup_deadline:
        try:
            if inject_faults and case == "probe-alive":
                probe_result = None
            elif inject_faults and case == "probe-eperm":
                raise PermissionError(errno.EPERM, "injected group probe EPERM")
            elif inject_faults and case == "probe-other":
                raise OSError(errno.EIO, "injected group probe error")
            else:
                probe_result = os.killpg(owned_pgid, 0)
            if inject_faults and case == "probe-alive" and probe_result is None:
                cleanup_errors.append("group remains observable")
                break
        except ProcessLookupError as error:
            if error.errno == errno.ESRCH:
                group_absent = True
                break
            cleanup_errors.append("unexpected absence probe: " + str(error))
            break
        except PermissionError as error:
            cleanup_errors.append("group absence probe denied: " + str(error))
            break
        except OSError as error:
            cleanup_errors.append("group absence probe failed: " + str(error))
            break
        time.sleep(0.02)
    if not group_absent:
        cleanup_errors.append("group absence unconfirmed")


for watched in (signal.SIGINT, signal.SIGTERM):
    signal.signal(watched, deferred_signal)
signal.signal(signal.SIGCHLD, signal.SIG_DFL)
if hasattr(signal, "pthread_sigmask"):
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGINT, signal.SIGTERM})

admission_read = admission_write = phase_read = phase_write = None


class NoLaunch(Exception):
    pass


try:
    boundary("launch-handoff")
    while primary is None:
        if pending_signal or control_record(cancel_path, "cancel"):
            first_failure("cancelled before launch")
            break
        if Path(cancel_path).exists() and not control_record(cancel_path, "cancel"):
            first_failure("invalid cancel record")
            break
        if control_record(start_path, "start"):
            break
        if Path(start_path).exists():
            first_failure("invalid start record")
            break
        if shared_monotonic() >= admission_deadline:
            first_failure("admission deadline expired")
            break
        time.sleep(0.01)
    if primary is not None:
        raise NoLaunch()
    if case == "exception-before-admission":
        raise RuntimeError("injected exception before child launch")
    admission_read, admission_write = os.pipe()
    phase_read, phase_write = os.pipe()
    for descriptor in (admission_read, admission_write, phase_read, phase_write):
        os.set_inheritable(descriptor, False)
    child_arguments = [sys.executable, wrapper, replay, "supervised-pause", control,
                       point, token, str(admission_read), str(phase_write), *arguments]
    process = subprocess.Popen(child_arguments, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        pass_fds=(admission_read, phase_write), close_fds=True)
    owned_pid = process.pid
    pid_authority = True
    os.close(admission_read)
    os.close(phase_write)
    owned_pgid = os.getpgid(owned_pid)
    owned_sid = os.getsid(owned_pid)
    if case == "identity-missing":
        first_failure("direct child identity missing")
    elif case == "identity-wrong":
        first_failure("direct child identity mismatch")
    elif case == "identity-own-group":
        first_failure("refused coordinator process group")
    elif owned_pid <= 0 or owned_pgid != owned_pid or owned_sid != owned_pid:
        first_failure("direct child identity mismatch")
    elif owned_pgid == os.getpgrp():
        first_failure("refused coordinator process group")
    else:
        authority = True
    for descriptor in (phase_read, process.stdout.fileno(), process.stderr.fileno()):
        os.set_blocking(descriptor, False)
    channel_selector.register(phase_read, selectors.EVENT_READ, "phase")
    channel_selector.register(process.stdout.fileno(), selectors.EVENT_READ, "stdout")
    channel_selector.register(process.stderr.fileno(), selectors.EVENT_READ, "stderr")
    if case == "exception-while-owned":
        raise RuntimeError("injected exception while direct child is gated")
    if case == "admission-write-failure":
        acknowledgement = Path(control + ".admission-closed")
        acknowledgement_deadline = shared_monotonic() + 2
        while not acknowledgement.exists() and shared_monotonic() < acknowledgement_deadline:
            time.sleep(0.01)
        if not acknowledgement.exists():
            first_failure("admission close acknowledgement missing")
    if primary is None:
        previous_mask = None
        try:
            if hasattr(signal, "pthread_sigmask"):
                previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
            os_pending = signal.sigpending() if hasattr(signal, "sigpending") else set()
            if (pending_signal or control_record(cancel_path, "cancel")
                    or signal.SIGINT in os_pending or signal.SIGTERM in os_pending):
                first_failure("cancelled at admission")
            else:
                possible_admission = True
                os.set_blocking(admission_write, False)
                if os.write(admission_write, b"1") != 1:
                    first_failure("short admission write")
        except OSError as error:
            first_failure("admission write failed: " + str(error))
        finally:
            if previous_mask is not None:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    os.close(admission_write)
    admission_write = None
    boundary("setup")
    while primary is None and ready_at is None:
        if consume_cancellation("setup"):
            break
        if shared_monotonic() >= setup_deadline:
            first_failure("setup deadline expired")
            break
        read_channels(channel_selector, min(0.05, setup_deadline - shared_monotonic()))
    if ready_at is not None:
        hold_deadline = ready_at + 20
        boundary("ready-hold")
        consume_cancellation("ready-hold")
        if shared_monotonic() >= hold_deadline:
            first_failure("ready hold deadline expired")
        if point == "natural":
            natural_deadline = shared_monotonic() + 2
            while (any(key.data == "phase" for key in channel_selector.get_map().values())
                   and shared_monotonic() < natural_deadline):
                read_channels(channel_selector, min(0.02, natural_deadline - shared_monotonic()))
    cleanup_deadline = shared_monotonic() + 10
    boundary("cleanup-before-signal")
    consume_cancellation("cleanup-before-signal")
    if case == "capture-forced-close":
        stdout_descriptor = process.stdout.fileno()
        channel_selector.unregister(stdout_descriptor)
        process.stdout.close()
    try:
        if possible_admission and authority:
            signal_attempt = "SIGKILL"
            signal_attempts += 1
            if case == "signal-error":
                raise OSError(errno.EIO, "injected group signal error")
            os.killpg(owned_pgid, signal.SIGKILL)
        elif pid_authority:
            signal_attempt = "PID-SIGKILL"
            signal_attempts += 1
            os.kill(owned_pid, signal.SIGKILL)
        else:
            cleanup_errors.append("no verified signal authority")
    except OSError as error:
        cleanup_errors.append("signal failed: " + str(error))
    finally:
        authority = False
        pid_authority = False
    boundary("retirement-wait")
    consume_cancellation("retirement-wait")
    if case == "exception-after-retirement":
        raise RuntimeError("injected exception after signal retirement")
    exact_reap()
    if case in ("wait-exhausted", "wait-echild") and not reaped:
        rescue_deadline = shared_monotonic() + 2
        while shared_monotonic() < rescue_deadline:
            try:
                rescue_pid, rescue_raw = os.waitpid(owned_pid, os.WNOHANG)
            except ChildProcessError:
                break
            if rescue_pid == owned_pid:
                rescue_status = os.waitstatus_to_exitcode(rescue_raw)
                process.returncode = rescue_status
                break
            time.sleep(0.01)
        if rescue_status is None:
            cleanup_errors.append("independent rescue failed")
    if case == "capture-drain-expiry":
        confirm_group_absence(True)
        finish_capture()
    else:
        finish_capture()
        confirm_group_absence(True)
except NoLaunch:
    capture_complete = True
    group_absent = True
except BaseException as error:
    first_failure(type(error).__name__ + ": " + str(error))
    if process is not None and owned_pid is not None and not reaped:
        if cleanup_deadline is None:
            cleanup_deadline = shared_monotonic() + 10
        try:
            if authority and possible_admission:
                signal_attempt = "SIGKILL"
                signal_attempts += 1
                os.killpg(owned_pgid, signal.SIGKILL)
            elif pid_authority:
                signal_attempt = "PID-SIGKILL"
                signal_attempts += 1
                os.kill(owned_pid, signal.SIGKILL)
        except OSError as cleanup_error:
            cleanup_errors.append("exception cleanup signal failed: " + str(cleanup_error))
        finally:
            authority = False
            pid_authority = False
        exact_reap()
        finish_capture()
        confirm_group_absence(False)
    elif process is None:
        capture_complete = True
        group_absent = True
finally:
    for descriptor_name in ("admission_read", "admission_write", "phase_read", "phase_write"):
        descriptor = globals().get(descriptor_name)
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass

expected_status = 37 if point == "natural" else -signal.SIGKILL
if cleanup_errors:
    first_failure("cleanup failed")
if ready_at is None:
    first_failure("publication readiness not observed")
if point in ("before", "after") and (prepublication_at is None or ready_at - prepublication_at < 12):
    first_failure("pre-publication hold was shorter than 12 seconds")
if decoded_status != expected_status:
    first_failure("authentic child status is unexpected")
if point == "natural":
    if (set(bytes(stream_data["stdout"]).splitlines()) != {b"tail-out", b"nested-out"}
            or set(bytes(stream_data["stderr"]).splitlines()) != {b"tail-err", b"nested-err"}):
        first_failure("natural-exit tails were not captured")
    if case != "control-natural":
        first_failure("outward stdout was not empty")
elif stream_bytes["stdout"] != 0:
    first_failure("outward stdout was not empty")
if not reaped or not group_absent or not capture_complete:
    first_failure("cleanup evidence incomplete")
if hasattr(signal, "pthread_sigmask"):
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
diagnostic_deadline = shared_monotonic() + 5
boundary("diagnostic-handoff")
consume_cancellation("diagnostic-handoff")


def evidence_record(outcome_sealed):
    return {"case": case, "token": token, "elapsed": shared_monotonic() - started,
        "deadlines": {"admission": admission_deadline, "setup": setup_deadline,
                      "cleanup": cleanup_deadline, "diagnostic": diagnostic_deadline},
        "prepublication_elapsed": prepublication_elapsed, "ready_elapsed": ready_elapsed,
        "owned_pid": owned_pid, "owned_pgid": owned_pgid, "owned_sid": owned_sid,
        "possible_admission": possible_admission, "signal_attempt": signal_attempt,
        "signal_attempts": signal_attempts, "raw_status": raw_status,
        "rescue_status": rescue_status, "decoded_status": decoded_status,
        "reaped": reaped, "group_absent": group_absent,
        "capture_complete": capture_complete, "stream_bytes": stream_bytes,
        "stream_eof": stream_eof,
        "stream_excerpt_base64": {
            name: base64.b64encode(bytes(stream_data[name][:4096])).decode()
            for name in ("stdout", "stderr")},
        "phase_records": phase_records, "primary_failure": primary,
        "control_bytes": control_bytes, "max_control_record": max_control_record,
        "pending_signal": observed_signal(),
        "outcome_sealed": outcome_sealed,
        "wait_eintr_retried": wait_eintr_injected,
        "drain_pending_observations": drain_pending_observations,
        "inherited_sigchld_ignored": inherited_sigchld_ignored,
        "inherited_blocked": inherited_blocked,
        "cleanup_errors": cleanup_errors, "diagnostic_errors": diagnostic_errors,
        "diagnostic_emitted": diagnostic_emitted,
        "diagnostic_sink_connected": diagnostic_sink_connected,
        "diagnostic_blocked_writes": diagnostic_blocked_writes,
        "diagnostic_prefill_bytes": diagnostic_prefill_bytes,
        "diagnostic_flags_restored": diagnostic_flags_restored}


try:
    if case == "capture-write-failure":
        raise OSError(errno.EIO, "injected capture publication error")
    bounded_write(stdout_path, bytes(stream_data["stdout"]), 64 * 1024)
    consume_cancellation("capture-publication")
    bounded_write(stderr_path, bytes(stream_data["stderr"]), 64 * 1024)
    consume_cancellation("capture-publication")
    diagnostic_bytes = json.dumps(evidence_record(False), sort_keys=True).encode() + b"\n"
    if len(diagnostic_bytes) > 16 * 1024:
        raise ValueError("diagnostic record exceeds limit")
    emit_diagnostic(diagnostic_path, diagnostic_bytes)
except BaseException as error:
    diagnostic_errors.append(type(error).__name__ + ": " + str(error))
    first_failure("diagnostic publication failed")
consume_cancellation("completion-publication")
record = evidence_record(True)
encoded_record = json.dumps(record, sort_keys=True).encode() + b"\n"
try:
    if case == "completion-write-failure":
        Path(str(completion_path) + ".next").mkdir()
    if case == "completion-rename-failure":
        Path(completion_path).mkdir()
    bounded_write(completion_path, encoded_record, 16 * 1024)
    prior_primary = primary
    consume_cancellation("completion-publication")
    if primary != prior_primary:
        record = evidence_record(True)
        encoded_record = json.dumps(record, sort_keys=True).encode() + b"\n"
        bounded_write(completion_path, encoded_record, 16 * 1024)
except BaseException as error:
    diagnostic_errors.append("completion publication failed: " + type(error).__name__ + ": " + str(error))
    raise SystemExit(1)
raise SystemExit(0 if primary is None and not cleanup_errors and not diagnostic_errors else 1)
PY

receiver_inherit_launcher="$tmp/receiver-inherit-launcher.py"
cat > "$receiver_inherit_launcher" <<'PY'
import os
import signal
import sys

mode, *command = sys.argv[1:]
if mode == "sigchld":
    signal.signal(signal.SIGCHLD, signal.SIG_IGN)
elif mode == "blocked":
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
elif mode == "shell":
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
else:
    raise SystemExit("unknown inherited-state mode")
os.execvp(command[0], command)
PY

receiver_diagnostic_reader="$tmp/receiver-diagnostic-reader.py"
cat > "$receiver_diagnostic_reader" <<'PY'
import os
from pathlib import Path
import sys
import time

fifo, output, stop, mode, ready = sys.argv[1:]
descriptor = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
Path(ready).write_text("connected\n")
data = bytearray()
if mode == "blocked":
    while not Path(stop).exists():
        time.sleep(0.01)
    os.close(descriptor)
    Path(output).write_bytes(data)
    raise SystemExit(0)
while True:
    try:
        chunk = os.read(descriptor, 4096)
    except BlockingIOError:
        chunk = None
    if chunk:
        data.extend(chunk)
    elif chunk == b"" and data:
        break
    elif Path(stop).exists():
        break
    else:
        time.sleep(0.01)
os.close(descriptor)
Path(output).write_bytes(data)
PY

receiver_shell_runner="$tmp/receiver-shell-runner.sh"
cat > "$receiver_shell_runner" <<'SH'
#!/bin/bash
set -euo pipefail
supervisor=$1 case_name=$2 token=$3 start=$4 cancel=$5 completion=$6
stdout_path=$7 stderr_path=$8 wrapper=$9
shift 9
replay=$1 point=$2 control=$3 shell_state=$4 shell_result=$5 shell_pause=$6
shift 6
job= diagnostic_reader= pending= cancel_failed=0 wait_complete=0 coordinator_status=125 active=0
diagnostic_reader_status=0

write_control() {
  local path=$1 kind=$2
  printf '{"case":"%s","kind":"%s","token":"%s"}\n' \
    "$case_name" "$kind" "$token" > "$path.next" && /bin/mv "$path.next" "$path"
}
write_shell_state() {
  printf '{"boundary":"%s","case":"%s","coordinator_pid":%s,"token":"%s"}\n' \
    "$1" "$case_name" "${job:-0}" "$token" > "$shell_state.next"
  /bin/mv "$shell_state.next" "$shell_state"
}
request_cancel() {
  if [ -z "$pending" ]; then
    pending=$1
    if ! write_control "$cancel" cancel; then cancel_failed=1; fi
  fi
}
wait_for_job() {
  while [ "$wait_complete" -eq 0 ]; do
    if wait "$job"; then coordinator_status=0; else coordinator_status=$?; fi
    if [ -n "$pending" ] && { [ "$coordinator_status" -eq 130 ] || [ "$coordinator_status" -eq 143 ]; }; then
      continue
    fi
    wait_complete=1
  done
}
finish_diagnostic_reader() {
  [ -n "$diagnostic_reader" ] || return 0
  : > "${completion}.diagnostic-stop"
  if wait "$diagnostic_reader"; then diagnostic_reader_status=0; else diagnostic_reader_status=$?; fi
  diagnostic_reader=
}
write_shell_result() {
  printf '{"cancel_failed":%s,"case":"%s","coordinator_status":%s,"diagnostic_reader_status":%s,"pending":"%s","token":"%s","wait_complete":%s}\n' \
    "$cancel_failed" "$case_name" "$coordinator_status" "$diagnostic_reader_status" \
    "$pending" "$token" "$wait_complete" \
    > "$shell_result.next"
  /bin/mv "$shell_result.next" "$shell_result"
}
on_exit() {
  local outcome=$?
  trap - EXIT ERR INT TERM
  if [ "$active" -eq 1 ]; then
    request_cancel shell-exit
    wait_for_job
    active=0
  fi
  finish_diagnostic_reader
  write_shell_result || true
  exit "$outcome"
}
trap on_exit EXIT
trap 'request_cancel INT' INT
trap 'request_cancel TERM' TERM
trap 'request_cancel shell-error' ERR

diagnostic_fifo="${completion}.diagnostic-fifo"
/usr/bin/mkfifo "$diagnostic_fifo"
if [ "$point" != diagnostic-broken-sink ]; then
  diagnostic_reader_mode=normal
  [ "$point" != diagnostic-blocked-sink ] || diagnostic_reader_mode=blocked
  python3 "${supervisor%/*}/receiver-diagnostic-reader.py" "$diagnostic_fifo" \
    "${completion}.diagnostic" "${completion}.diagnostic-stop" "$diagnostic_reader_mode" \
    "${completion}.diagnostic-reader-ready" &
  diagnostic_reader=$!
fi
coordinator=(python3 "$supervisor" "$case_name" "$token" "$start" "$cancel" "$completion"
  "$stdout_path" "$stderr_path" "$wrapper" "$replay" "$point" "$control" "$@")
if [ "$case_name" = inherited-sigchld ]; then
  coordinator=(python3 "${supervisor%/*}/receiver-inherit-launcher.py" sigchld "${coordinator[@]}")
elif [ "$case_name" = inherited-blocked ]; then
  coordinator=(python3 "${supervisor%/*}/receiver-inherit-launcher.py" blocked "${coordinator[@]}")
fi
"${coordinator[@]}" &
job=$!
active=1
write_shell_state launch-handoff
if [ "$shell_pause" = launch-handoff ]; then
  while [ -z "$pending" ]; do sleep 0.01; done
fi
if [ -n "$pending" ]; then
  request_cancel "$pending"
elif [ "$shell_pause" = invalid-start ]; then
  printf '{}\n' > "$start"
elif [ "$shell_pause" = invalid-cancel ]; then
  printf '{}\n' > "$cancel"
else
  write_control "$start" start
fi
if [ "$shell_pause" = shell-error ]; then false; fi
wait_for_job
active=0
finish_diagnostic_reader
write_shell_state completion-handoff
if [ "$shell_pause" = completion-handoff ]; then
  pause_deadline=$((SECONDS + 5))
  while [ -z "$pending" ] && [ "$SECONDS" -lt "$pause_deadline" ]; do sleep 0.01; done
fi
trap - EXIT ERR INT TERM
write_shell_result
[ "$cancel_failed" -eq 0 ] || exit 126
[ -z "$pending" ] || exit 1
exit "$coordinator_status"
SH
/bin/chmod 700 "$receiver_shell_runner"

run_managed_receiver() {
  local case_name=$1 token=$2 start=$3 cancel=$4 completion=$5
  local stdout_path=$6 stderr_path=$7 point=$8 control=$9
  shift 9
  local status shell_state shell_result
  shell_state="${completion}.shell-state"
  shell_result="${completion}.shell-result"
  if /bin/bash "$receiver_shell_runner" "$receiver_supervisor" "$case_name" "$token" \
    "$start" "$cancel" "$completion" "$stdout_path" "$stderr_path" \
    "${receiver_wrapper:-$loaded_wrapper}" "${receiver_replay:-$replay}" "$point" "$control" \
    "$shell_state" "$shell_result" none "$@"; then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 127 ] || return 127
  [ -f "$completion" ] || return 125
  python3 - "$completion" "$shell_result" "$token" "$case_name" <<'PY'
import json
import sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
shell = json.load(open(sys.argv[2], encoding="utf-8"))
assert record["token"] == sys.argv[3] and record["case"] == sys.argv[4]
assert shell["token"] == sys.argv[3] and shell["case"] == sys.argv[4]
assert shell["wait_complete"] == 1 and shell["cancel_failed"] == 0
PY
  return "$status"
}

receiver_control_inventory="$tmp/receiver-control-inventory.tsv"
: > "$receiver_control_inventory"
for point in before after; do
  make_roots "crash-$point"
  set_replay_args "crash-$point"
  crash_args=("${replay_arguments[@]}")
  invocation="$tmp/supervised-$point"
  /bin/mkdir -m 700 "$invocation"
  token=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
  start="$invocation/start-$token"
  cancel="$invocation/cancel-$token"
  completion="$invocation/completion-$token.json"
  if run_managed_receiver "$point" "$token" "$start" "$cancel" "$completion" \
    "$tmp/$point.out" "$tmp/$point.err" "$point" "$tmp/$point-oracle" "${crash_args[@]}"; then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 0 ] || fail "$point-supervisor-status"
  [ -f "$completion" ] || fail "$point-completion-missing"
  python3 - "$completion" "$token" "$point" <<'PY'
import json
import sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["token"] == sys.argv[2] and record["case"] == sys.argv[3]
assert 0 <= record["prepublication_elapsed"] <= record["ready_elapsed"] <= 60
assert record["decoded_status"] == -9
assert record["reaped"] and record["group_absent"] and record["capture_complete"]
assert record["stream_bytes"] == {"stderr": 0, "stdout": 0}
assert record["signal_attempt"] == "SIGKILL" and not record["cleanup_errors"]
assert record["ready_elapsed"] - record["prepublication_elapsed"] >= 12
assert record["phase_records"][-1]["hold_seconds"] >= 12
assert record["phase_records"][-1]["publication_state"] == (
    "pending" if sys.argv[3] == "before" else "completed")
assert [item["phase"] for item in record["phase_records"]] == [
    "entry", "materializer-entry", "materializer-return", "pre-publication", "ready"]
PY
  [ ! -s "$tmp/$point.out" ] || fail "$point-outward-output"
  if [ "$point" = before ]; then
    candidate_before=$(git_clean --git-dir="$tmp/crash-before-candidate/repository.git" rev-parse refs/heads/candidate)
    set +e
    python3 "$replay" "${crash_args[@]}" --read-materialization-result > "$tmp/before-read.out"
    status=$?
    set -e
    if [ "$status" -ne 3 ] ||
       ! "$jq_bin" -e '.reason_id=="replay.materialization-result-missing"' \
         "$tmp/before-read.out" >/dev/null; then
      fail before-missing
    fi
    [ "$(git_clean --git-dir="$tmp/crash-before-candidate/repository.git" rev-parse refs/heads/candidate)" = "$candidate_before" ] ||
      fail before-candidate-mutated
  else
    python3 "$replay" "${crash_args[@]}" --read-materialization-result > "$tmp/after-read.out"
    "$jq_bin" -e '.status=="stored" and .stage_result.content.kind=="stage_result"' \
      "$tmp/after-read.out" >/dev/null || fail after-stored
  fi
  printf 'real-%s\t%s\tPASS\n' "$point" "$point" >> "$receiver_control_inventory"
done
pass 'both synchronized process-crash windows preserve their distinct evidence state'

receiver_control_wrapper="$tmp/receiver-control-wrapper.py"
cat > "$receiver_control_wrapper" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import time

unused, mode, control, point, token, admission_fd, phase_fd, *arguments = sys.argv[1:]
assert mode == "supervised-pause"
admission_fd, phase_fd = int(admission_fd), int(phase_fd)
if point == "admission-write-failure":
    os.close(admission_fd)
    Path(control + ".admission-closed").write_text("closed\n")
    time.sleep(30)
    raise SystemExit(1)
admitted = os.read(admission_fd, 2)
os.close(admission_fd)
if admitted != b"1":
    raise SystemExit("invalid control admission")
os.set_inheritable(phase_fd, False)
Path(control + ".product").write_text("admitted\n")
wire_sequence = 0


def send_record(value, target_size=None):
    global wire_sequence
    wire_sequence += 1
    value.setdefault("token", token)
    value.setdefault("case", point)
    value.setdefault("sequence", wire_sequence)
    if target_size is not None:
        value["padding"] = ""
        base = json.dumps(value, sort_keys=True, separators=(",", ":")).encode() + b"\n"
        value["padding"] = "x" * (target_size - len(base))
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode() + b"\n"
    if target_size is not None:
        assert len(encoded) == target_size, (len(encoded), target_size)
    os.write(phase_fd, encoded)


def phase(unused_sequence, name, **changes):
    target_size = changes.pop("target_size", None)
    value = {"phase": name}
    if name in ("pre-publication", "ready"):
        value["clock"] = "CLOCK_MONOTONIC"
        value["shared_monotonic"] = time.clock_gettime(time.CLOCK_MONOTONIC)
    if name == "ready":
        value["hold_seconds"] = 0.0
    value.update(changes)
    send_record(value, target_size)


if point == "malformed":
    os.write(phase_fd, b"{bad\n")
elif point == "wrong-case":
    phase(1, "entry", case="other")
elif point == "duplicate":
    phase(1, "entry")
    phase(1, "entry")
elif point == "out-of-order":
    phase(1, "entry")
    phase(2, "materializer-return")
elif point == "record-overflow":
    send_record({"kind": "padding"}, 4097)
elif point == "record-exact":
    send_record({"kind": "padding"}, 4096)
    for sequence, name in enumerate(("entry", "materializer-entry", "materializer-return",
                                     "pre-publication", "ready"), 1):
        phase(sequence, name)
elif point == "control-overflow":
    for size in ([4096] * 16 + [128]):
        send_record({"kind": "padding"}, size)
elif point == "control-exact":
    for size in ([4096] * 15 + [2816]):
        send_record({"kind": "padding"}, size)
    for sequence, name in enumerate(("entry", "materializer-entry", "materializer-return",
                                     "pre-publication", "ready"), 1):
        phase(sequence, name, target_size=256)
elif point == "stream-overflow":
    for sequence, name in enumerate(("entry", "materializer-entry", "materializer-return"), 1):
        phase(sequence, name)
    sys.stdout.buffer.write(b"x" * (64 * 1024 + 1))
    sys.stdout.buffer.flush()
    phase(4, "pre-publication")
    phase(5, "ready")
elif point in ("stdout-exact", "stderr-exact"):
    for sequence, name in enumerate(("entry", "materializer-entry", "materializer-return"), 1):
        phase(sequence, name)
    stream = sys.stdout.buffer if point == "stdout-exact" else sys.stderr.buffer
    stream.write(b"x" * (64 * 1024))
    stream.flush()
    phase(4, "pre-publication")
    phase(5, "ready")
elif point == "stderr-overflow":
    for sequence, name in enumerate(("entry", "materializer-entry", "materializer-return"), 1):
        phase(sequence, name)
    sys.stderr.buffer.write(b"x" * (64 * 1024 + 1))
    sys.stderr.buffer.flush()
    phase(4, "pre-publication")
    phase(5, "ready")
elif point == "watchdog":
    phase(1, "entry")
    descendant = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(70)"],
                                  stdin=subprocess.DEVNULL, close_fds=True)
    Path(control + ".descendant").write_text(json.dumps({
        "pid": descendant.pid, "ppid": os.getpid(), "pgid": os.getpgid(descendant.pid),
        "sid": os.getsid(descendant.pid)}) + "\n")
    time.sleep(70)
elif point == "natural":
    for sequence, name in enumerate(("entry", "materializer-entry", "materializer-return",
                                     "pre-publication", "ready"), 1):
        phase(sequence, name)
    nested_ready = control + ".nested-ready"
    descendant = subprocess.Popen([sys.executable, "-c",
        "import pathlib,sys,time; sys.stdout.write('nested-out\\n'); "
        "sys.stderr.write('nested-err\\n'); sys.stdout.flush(); sys.stderr.flush(); "
        "pathlib.Path(sys.argv[1]).write_text('ready\\n'); time.sleep(30)", nested_ready],
        stdin=subprocess.DEVNULL, close_fds=True)
    Path(control + ".descendant").write_text(json.dumps({
        "pid": descendant.pid, "ppid": os.getpid(), "pgid": os.getpgid(descendant.pid),
        "sid": os.getsid(descendant.pid)}) + "\n")
    nested_deadline = time.monotonic() + 2
    while not Path(nested_ready).exists() and time.monotonic() < nested_deadline:
        time.sleep(0.01)
    if not Path(nested_ready).exists():
        raise RuntimeError("nested writer did not acknowledge output")
    sys.stdout.write("tail-out\n")
    sys.stderr.write("tail-err\n")
    sys.stdout.flush()
    sys.stderr.flush()
    os.close(phase_fd)
    os._exit(37)
elif point == "signal-error":
    for sequence, name in enumerate(("entry", "materializer-entry", "materializer-return",
                                     "pre-publication", "ready"), 1):
        phase(sequence, name)
    descendant = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(1)"],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, close_fds=True)
    Path(control + ".descendant").write_text(str(descendant.pid) + "\n")
    time.sleep(0.5)
    raise SystemExit(42)
elif point in ("cancel-ready-hold", "cancel-cleanup-before-signal",
               "cancel-retirement-wait", "cancel-diagnostic-handoff",
               "cancel-diagnostic-publication", "wait-eintr",
               "wait-exhausted", "wait-echild", "probe-alive",
               "probe-eperm", "probe-other", "capture-forced-close",
               "capture-drain-expiry", "capture-write-failure", "diagnostic-blocked-sink",
               "diagnostic-broken-sink", "diagnostic-restore-failure",
               "completion-write-failure", "completion-rename-failure",
               "inherited-sigchld", "inherited-blocked", "wait-completion-race",
               "exception-after-retirement"):
    for sequence, name in enumerate(("entry", "materializer-entry", "materializer-return",
                                     "pre-publication", "ready"), 1):
        phase(sequence, name)
elif point == "capture-read-failure":
    sys.stdout.write("read-fault\n")
    sys.stdout.flush()
    phase(1, "entry")
else:
    phase(1, "entry")
time.sleep(30)
PY

run_receiver_control() {
  local name=$1 point=$2 expected=$3
  local invocation="$tmp/control-$name" token start cancel completion status
  /bin/mkdir -m 700 "$invocation"
  token=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
  start="$invocation/start-$token"
  cancel="$invocation/cancel-$token"
  completion="$invocation/completion-$token.json"
  receiver_wrapper=$receiver_control_wrapper
  receiver_replay=unused
  if run_managed_receiver "$name" "$token" "$start" "$cancel" "$completion" \
    "$invocation/stdout" "$invocation/stderr" "$point" "$invocation/control"; then
    status=0
  else
    status=$?
  fi
  unset receiver_wrapper receiver_replay
  [ "$status" -eq "$expected" ] || fail "receiver-control-$name-status-$status"
  if ! python3 - "$completion" <<'PY'
import json
import sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
unresolved = (record["cleanup_errors"] or record["diagnostic_errors"]
              or not record["capture_complete"] or not record["group_absent"])
raise SystemExit(1 if unresolved else 0)
PY
  then
    managed_retention=1
    : > "$invocation/retained"
  fi
  printf '%s\t%s\tPASS\n' "$name" "$point" >> "$receiver_control_inventory"
}

run_receiver_control control-natural natural 0
python3 - "$tmp/control-control-natural/completion-"*'.json' \
  "$tmp/control-control-natural/control.descendant" <<'PY'
import json
import os
import sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
identity = json.load(open(sys.argv[2], encoding="utf-8"))
assert record["decoded_status"] == 37 and record["group_absent"]
assert identity["ppid"] == record["owned_pid"]
assert identity["pgid"] == record["owned_pgid"] == identity["sid"]
try:
    os.kill(identity["pid"], 0)
except ProcessLookupError:
    pass
else:
    raise AssertionError("natural-exit descendant survived")
PY
run_receiver_control natural-zero-oracle natural 1
python3 - "$tmp/control-natural-zero-oracle/completion-"*'.json' <<'PY'
import json
import sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["primary_failure"] == "outward stdout was not empty"
assert record["decoded_status"] == 37 and record["capture_complete"]
PY
for control_case in malformed wrong-case duplicate out-of-order record-overflow control-overflow \
  stream-overflow stderr-overflow admission-write-failure identity-missing identity-wrong \
  identity-own-group signal-error wait-exhausted wait-echild probe-alive probe-eperm probe-other \
  stdout-exact capture-read-failure capture-forced-close capture-drain-expiry \
  capture-write-failure \
  diagnostic-blocked-sink diagnostic-broken-sink diagnostic-restore-failure; do
  run_receiver_control "$control_case" "$control_case" 1
done
for control_case in record-exact control-exact stderr-exact inherited-sigchld; do
  run_receiver_control "$control_case" "$control_case" 0
done
run_receiver_control wait-eintr wait-eintr 0
python3 - "$tmp/control-wait-eintr/completion-"*'.json' <<'PY'
import json
import sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["wait_eintr_retried"] and record["decoded_status"] == -9
assert record["signal_attempts"] == 1 and not record["cleanup_errors"]
PY
python3 - \
  "$tmp/control-signal-error/completion-"*'.json' \
  "$tmp/control-wait-exhausted/completion-"*'.json' \
  "$tmp/control-wait-echild/completion-"*'.json' <<'PY'
import json
import sys
signal_error, exhausted, missing = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert signal_error["signal_attempts"] == 1 and signal_error["decoded_status"] == 42
assert signal_error["cleanup_errors"] == ["signal failed: [Errno 5] injected group signal error"]
assert exhausted["decoded_status"] is None and exhausted["rescue_status"] == -9
assert exhausted["reaped"] is False and "child reap deadline expired" in exhausted["cleanup_errors"]
assert missing["decoded_status"] is None and missing["rescue_status"] == -9
assert missing["reaped"] is False and missing["cleanup_errors"] == [
    "missing child status: injected ECHILD at exact wait boundary"]
PY
python3 - \
  "$tmp/control-diagnostic-blocked-sink/completion-"*'.json' \
  "$tmp/control-diagnostic-broken-sink/completion-"*'.json' \
  "$tmp/control-diagnostic-restore-failure/completion-"*'.json' <<'PY'
import json
import sys
blocked, broken, restoration = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert blocked["primary_failure"] == "diagnostic publication failed"
assert blocked["diagnostic_errors"] == ["TimeoutError: diagnostic write deadline expired"]
assert blocked["diagnostic_sink_connected"] and blocked["diagnostic_prefill_bytes"] > 0
assert blocked["diagnostic_blocked_writes"] > 1
assert blocked["elapsed"] >= 5 and blocked["diagnostic_flags_restored"]
assert broken["primary_failure"] == "diagnostic publication failed"
assert broken["diagnostic_errors"][0].startswith("BrokenPipeError: [Errno 32]")
assert restoration["primary_failure"] == "diagnostic publication failed"
assert restoration["diagnostic_errors"][0].startswith("OSError: [Errno 9]")
assert not restoration["diagnostic_flags_restored"]
PY
python3 - "$tmp/control-inherited-sigchld/completion-"*'.json' <<'PY'
import json
import sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["inherited_sigchld_ignored"] and record["decoded_status"] == -9
PY
python3 - \
  "$tmp/control-record-exact/completion-"*'.json' \
  "$tmp/control-control-exact/completion-"*'.json' \
  "$tmp/control-stdout-exact/completion-"*'.json' \
  "$tmp/control-stderr-exact/completion-"*'.json' <<'PY'
import json
import sys
record_exact, control_exact, stdout_exact, stderr_exact = [
    json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert record_exact["max_control_record"] == 4096 and not record_exact["cleanup_errors"]
assert control_exact["control_bytes"] == 64 * 1024 and not control_exact["cleanup_errors"]
assert stdout_exact["stream_bytes"] == {"stdout": 64 * 1024, "stderr": 0}
assert stdout_exact["primary_failure"] == "outward stdout was not empty"
assert stderr_exact["stream_bytes"] == {"stdout": 0, "stderr": 64 * 1024}
assert stderr_exact["primary_failure"] is None
PY
python3 - "$tmp" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
def load(name):
    return json.loads(next((root / ("control-" + name)).glob("completion-*.json")).read_text())

expected_primary = {
    "malformed": "malformed phase record",
    "wrong-case": "wrong control identity or sequence",
    "duplicate": "out-of-order phase record",
    "out-of-order": "out-of-order phase record",
    "record-overflow": "control record exceeds limit",
    "control-overflow": "control data exceeds limit",
    "stream-overflow": "stdout capture exceeds limit",
    "stderr-overflow": "stderr capture exceeds limit",
}
for name, expected in expected_primary.items():
    record = load(name)
    assert record["primary_failure"] == expected, (name, record["primary_failure"])
    assert record["signal_attempts"] == 1 and record["reaped"] and record["group_absent"]

signal_error = load("signal-error")
assert signal_error["cleanup_errors"] == ["signal failed: [Errno 5] injected group signal error"]
assert signal_error["signal_attempts"] == 1 and signal_error["decoded_status"] == 42
probe_fragments = {
    "probe-alive": "group remains observable",
    "probe-eperm": "group absence probe denied: [Errno 1] injected group probe EPERM",
    "probe-other": "group absence probe failed: [Errno 5] injected group probe error",
}
for name, fragment in probe_fragments.items():
    record = load(name)
    assert fragment in record["cleanup_errors"] and "group absence unconfirmed" in record["cleanup_errors"]
    assert record["signal_attempts"] == 1 and record["reaped"] and not record["group_absent"]

read_failure = load("capture-read-failure")
assert read_failure["primary_failure"].startswith("stdout read failed: [Errno 5]")
assert not read_failure["capture_complete"] and read_failure["stream_eof"]["stderr"]
forced = load("capture-forced-close")
assert forced["primary_failure"] == "cleanup failed" and not forced["capture_complete"]
assert "stream capture incomplete" in forced["cleanup_errors"]
drain = load("capture-drain-expiry")
assert drain["primary_failure"] == "cleanup failed" and not drain["capture_complete"]
assert drain["stream_eof"]["stdout"] is False and drain["group_absent"]
assert drain["drain_pending_observations"] > 0
assert drain["elapsed"] >= drain["deadlines"]["cleanup"] - drain["deadlines"]["admission"] + 5
assert drain["cleanup_errors"] == ["stream capture incomplete"]
write_failure = load("capture-write-failure")
assert write_failure["primary_failure"] == "diagnostic publication failed"
assert write_failure["diagnostic_errors"] == [
    "OSError: [Errno 5] injected capture publication error"]
admission = load("admission-write-failure")
assert admission["primary_failure"].startswith("admission write failed: [Errno 32]")
assert admission["possible_admission"] and admission["signal_attempt"] == "SIGKILL"
assert admission["signal_attempts"] == 1 and admission["decoded_status"] == -9
assert admission["reaped"] and admission["group_absent"] and admission["capture_complete"]
PY
for identity_case in identity-missing identity-wrong identity-own-group; do
  [ ! -e "$tmp/control-$identity_case/control.product" ] || fail "$identity_case-product-executed"
  python3 - "$tmp/control-$identity_case/completion-"*'.json' <<'PY'
import json
import sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["signal_attempt"] == "PID-SIGKILL" and record["signal_attempts"] == 1
assert not record["possible_admission"] and record["decoded_status"] == -9
PY
done
pass 'receiver supervision rejects malformed, misidentified, reordered, oversized, and overflowing evidence'

wait_receiver_boundary() {
  local state_path=$1 wanted=$2 owner=$3 count=0
  while :; do
    if [ -f "$state_path" ] && python3 - "$state_path" "$wanted" <<'PY'
import json
import sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(1)
raise SystemExit(0 if value.get("boundary") == sys.argv[2] else 1)
PY
    then
      return
    fi
    kill -0 "$owner" 2>/dev/null || fail "receiver-boundary-$wanted-owner-exited"
    count=$((count + 1))
    [ "$count" -lt 500 ] || fail "receiver-boundary-$wanted-timeout"
    sleep 0.01
  done
}

exercise_receiver_cancellation() {
  local target=$1 received=$2 boundary_name=$3
  local name="cancel-$target-$received-$boundary_name"
  local invocation="$tmp/$name" token start cancel completion shell_state shell_result
  local shell_owner coordinator_owner result_code point shell_pause
  /bin/mkdir -m 700 "$invocation"
  token=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
  start="$invocation/start-$token"
  cancel="$invocation/cancel-$token"
  completion="$invocation/completion-$token.json"
  shell_state="$invocation/shell-state.json"
  shell_result="$invocation/shell-result.json"
  point="cancel-$boundary_name"
  shell_pause=none
  if [ "$target" = bash ] && [ "$boundary_name" = launch-handoff ]; then
    shell_pause=launch-handoff
  fi
  python3 "$receiver_inherit_launcher" shell /bin/bash "$receiver_shell_runner" \
    "$receiver_supervisor" "$name" "$token" \
    "$start" "$cancel" "$completion" "$invocation/stdout" "$invocation/stderr" \
    "$receiver_control_wrapper" unused "$point" "$invocation/control" \
    "$shell_state" "$shell_result" "$shell_pause" &
  shell_owner=$!
  if [ "$target" = bash ] && [ "$boundary_name" = launch-handoff ]; then
    wait_receiver_boundary "$shell_state" launch-handoff "$shell_owner"
  else
    wait_receiver_boundary "$completion.state" "$boundary_name" "$shell_owner"
  fi
  if [ "$target" = coordinator ]; then
    coordinator_owner=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["coordinator_pid"])' "$shell_state")
    kill -"$received" "$coordinator_owner"
    kill -"$received" "$coordinator_owner" 2>/dev/null || true
  else
    kill -"$received" "$shell_owner"
    kill -"$received" "$shell_owner" 2>/dev/null || true
  fi
  if wait "$shell_owner"; then result_code=0; else result_code=$?; fi
  [ "$result_code" -eq 1 ] || fail "$name-status-$result_code"
  python3 - "$completion" "$shell_result" "$token" "$name" "$boundary_name" "$target" <<'PY'
import json
import sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
shell = json.load(open(sys.argv[2], encoding="utf-8"))
assert record["token"] == sys.argv[3] and record["case"] == sys.argv[4]
assert record["primary_failure"] == "cancelled at " + sys.argv[5]
assert shell["wait_complete"] == 1 and shell["cancel_failed"] == 0
if sys.argv[6] == "bash": assert shell["pending"] == sys.argv[5] or shell["pending"] in ("INT", "TERM")
if record["owned_pid"] is None:
    assert record["signal_attempts"] == 0 and not record["possible_admission"]
else:
    assert record["signal_attempt"] in ("SIGKILL", "PID-SIGKILL") and record["signal_attempts"] == 1
    assert record["reaped"] and record["group_absent"] and record["capture_complete"]
    assert not record["cleanup_errors"]
PY
  if [ "$boundary_name" = launch-handoff ]; then
    [ ! -e "$invocation/control.product" ] || fail "$name-product-executed"
  elif [ "$boundary_name" != setup ]; then
    [ -f "$invocation/control.product" ] || fail "$name-product-not-admitted"
  fi
  printf '%s\t%s\tPASS\n' "$name" "$point" >> "$receiver_control_inventory"
}

for received in INT TERM; do
  for target in bash coordinator; do
    for boundary_name in launch-handoff setup ready-hold cleanup-before-signal retirement-wait diagnostic-handoff; do
      exercise_receiver_cancellation "$target" "$received" "$boundary_name"
    done
  done
done
exercise_receiver_cancellation coordinator TERM diagnostic-publication
python3 - \
  "$tmp/cancel-coordinator-TERM-diagnostic-publication/completion-"*'.json' \
  "$tmp/cancel-coordinator-TERM-diagnostic-publication/completion-"*'.json.diagnostic' <<'PY'
import json
import sys
completion, diagnostic = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert completion["primary_failure"] == "cancelled at diagnostic-publication"
assert completion["outcome_sealed"] and completion["pending_signal"] == 15
assert diagnostic["outcome_sealed"] is False and diagnostic["primary_failure"] is None
PY

run_shell_control() {
  local name=$1 point=$2 shell_pause=$3
  local invocation="$tmp/$name" token start cancel completion shell_state shell_result owner result_code
  /bin/mkdir -m 700 "$invocation"
  token=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
  start="$invocation/start-$token"; cancel="$invocation/cancel-$token"
  completion="$invocation/completion-$token.json"
  shell_state="$invocation/shell-state.json"; shell_result="$invocation/shell-result.json"
  python3 "$receiver_inherit_launcher" shell /bin/bash "$receiver_shell_runner" \
    "$receiver_supervisor" "$name" "$token" \
    "$start" "$cancel" "$completion" "$invocation/stdout" "$invocation/stderr" \
    "$receiver_control_wrapper" unused "$point" "$invocation/control" \
    "$shell_state" "$shell_result" "$shell_pause" &
  owner=$!
  receiver_shell_owner=$owner receiver_shell_state=$shell_state receiver_shell_result=$shell_result
  receiver_shell_completion=$completion receiver_shell_cancel=$cancel
}

for invalid_control in start cancel; do
  run_shell_control "invalid-$invalid_control-record" "invalid-$invalid_control-record" \
    "invalid-$invalid_control"
  if wait "$receiver_shell_owner"; then status=0; else status=$?; fi
  [ "$status" -eq 1 ] || fail "invalid-$invalid_control-record-status"
  python3 - "$receiver_shell_completion" "$invalid_control" <<'PY'
import json
import sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["primary_failure"] == "invalid " + sys.argv[2] + " record"
assert record["owned_pid"] is None and record["signal_attempts"] == 0
assert record["group_absent"] and record["capture_complete"]
PY
  [ ! -e "$tmp/invalid-$invalid_control-record/control.product" ] ||
    fail "invalid-$invalid_control-record-product-executed"
  printf 'invalid-%s-record\tprelaunch\tPASS\n' "$invalid_control" >> "$receiver_control_inventory"
done

run_shell_control inherited-blocked cancel-setup none
wait_receiver_boundary "$receiver_shell_completion.state" setup "$receiver_shell_owner"
inherited_owner=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["coordinator_pid"])' "$receiver_shell_state")
kill -INT "$inherited_owner"; kill -TERM "$inherited_owner" 2>/dev/null || true
if wait "$receiver_shell_owner"; then status=0; else status=$?; fi
[ "$status" -eq 1 ] || fail inherited-blocked-status
python3 - "$receiver_shell_completion" <<'PY'
import json
import signal
import sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["inherited_blocked"] == sorted([signal.SIGINT, signal.SIGTERM])
assert record["primary_failure"] == "cancelled at setup" and record["signal_attempts"] == 1
PY
printf 'inherited-blocked\tsetup\tPASS\n' >> "$receiver_control_inventory"

run_shell_control wait-completion-race wait-completion-race completion-handoff
wait_receiver_boundary "$receiver_shell_state" completion-handoff "$receiver_shell_owner"
kill -TERM "$receiver_shell_owner"
if wait "$receiver_shell_owner"; then status=0; else status=$?; fi
[ "$status" -eq 1 ] || fail wait-completion-race-status
python3 - "$receiver_shell_completion" "$receiver_shell_result" <<'PY'
import json
import sys
record, shell = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert record["primary_failure"] is None and record["signal_attempts"] == 1
assert shell["pending"] == "TERM" and shell["wait_complete"] == 1
PY
printf 'wait-completion-race\tcompletion-handoff\tPASS\n' >> "$receiver_control_inventory"

run_shell_control shell-error cancel-setup shell-error
if wait "$receiver_shell_owner"; then status=0; else status=$?; fi
[ "$status" -ne 0 ] || fail shell-error-status
python3 - "$receiver_shell_completion" "$receiver_shell_result" <<'PY'
import json
import sys
record, shell = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert shell["pending"] == "shell-error" and shell["wait_complete"] == 1
assert record["primary_failure"].startswith("cancelled")
PY
printf 'shell-error\texit-wait\tPASS\n' >> "$receiver_control_inventory"

run_shell_control cancel-write-failure cancel-setup none
wait_receiver_boundary "$receiver_shell_completion.state" setup "$receiver_shell_owner"
/bin/mkdir "${receiver_shell_cancel}.next"
kill -INT "$receiver_shell_owner"
if wait "$receiver_shell_owner"; then status=0; else status=$?; fi
[ "$status" -eq 126 ] || fail cancel-write-failure-status
python3 - "$receiver_shell_completion" "$receiver_shell_result" <<'PY'
import json
import sys
record, shell = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert shell["cancel_failed"] == 1 and shell["wait_complete"] == 1
assert shell["pending"] == "INT"
assert record["primary_failure"] == "cancellation control deadline expired at setup"
assert record["elapsed"] >= 5 and not record["cleanup_errors"]
assert record["signal_attempts"] == 1 and record["reaped"] and record["group_absent"]
PY
managed_retention=1
: > "$tmp/cancel-write-failure/retained"
printf 'cancel-write-failure\tsetup\tPASS\n' >> "$receiver_control_inventory"

for exception_case in exception-before-admission exception-while-owned exception-after-retirement; do
  run_receiver_control "$exception_case" "$exception_case" 1
done
python3 - \
  "$tmp/control-exception-before-admission/completion-"*'.json' \
  "$tmp/control-exception-while-owned/completion-"*'.json' \
  "$tmp/control-exception-after-retirement/completion-"*'.json' <<'PY'
import json
import sys
before, owned, retired = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert before["primary_failure"] == "RuntimeError: injected exception before child launch"
assert before["owned_pid"] is None and before["signal_attempts"] == 0
assert before["capture_complete"] and before["group_absent"]
assert owned["primary_failure"] == "RuntimeError: injected exception while direct child is gated"
assert owned["signal_attempt"] == "PID-SIGKILL" and owned["signal_attempts"] == 1
assert owned["decoded_status"] == -9 and owned["reaped"] and owned["group_absent"]
assert owned["capture_complete"] and not owned["possible_admission"]
assert retired["primary_failure"] == "RuntimeError: injected exception after signal retirement"
assert retired["signal_attempt"] == "SIGKILL" and retired["signal_attempts"] == 1
assert retired["decoded_status"] == -9 and retired["reaped"] and retired["group_absent"]
assert retired["capture_complete"]
PY
for publication_case in completion-write-failure completion-rename-failure; do
  run_shell_control "$publication_case" "$publication_case" none
  if wait "$receiver_shell_owner"; then status=0; else status=$?; fi
  [ "$status" -eq 1 ] || fail "$publication_case-status"
  python3 - "$receiver_shell_completion.diagnostic" "$publication_case" <<'PY'
import json
import sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["case"] == sys.argv[2] and record["diagnostic_errors"] == []
assert record["signal_attempts"] == 1 and record["capture_complete"]
PY
  managed_retention=1
  : > "$tmp/$publication_case/retained"
  printf '%s\tcompletion-publication\tPASS\n' "$publication_case" >> "$receiver_control_inventory"
done
pass 'receiver supervision records all INT/TERM Bash/coordinator cancellation boundaries'

run_receiver_control watchdog watchdog 1
python3 - "$tmp/control-watchdog/completion-"*'.json' \
  "$tmp/control-watchdog/control.descendant" <<'PY'
import json
import os
import sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
descendant = json.load(open(sys.argv[2], encoding="utf-8"))
assert record["primary_failure"] == "setup deadline expired"
assert record["elapsed"] >= 60 and record["signal_attempts"] == 1
assert record["reaped"] and record["group_absent"] and record["capture_complete"]
assert descendant["ppid"] == record["owned_pid"]
assert descendant["pgid"] == record["owned_pgid"] == descendant["sid"]
try: os.kill(descendant["pid"], 0)
except ProcessLookupError: pass
else: raise AssertionError("watchdog descendant survived")
PY
python3 - "$receiver_control_inventory" <<'PY'
import sys

rows = [line.rstrip("\n").split("\t") for line in open(sys.argv[1], encoding="utf-8")]
generic = """malformed wrong-case duplicate out-of-order record-overflow control-overflow
stream-overflow stderr-overflow admission-write-failure identity-missing identity-wrong
identity-own-group signal-error wait-exhausted wait-echild probe-alive probe-eperm probe-other
stdout-exact capture-read-failure capture-forced-close capture-drain-expiry capture-write-failure
diagnostic-blocked-sink diagnostic-broken-sink diagnostic-restore-failure""".split()
expected = ["real-before", "real-after", "control-natural", "natural-zero-oracle"]
expected += generic + ["record-exact", "control-exact", "stderr-exact", "inherited-sigchld",
                       "wait-eintr"]
for received in ("INT", "TERM"):
    for target in ("bash", "coordinator"):
        for boundary in ("launch-handoff", "setup", "ready-hold", "cleanup-before-signal",
                         "retirement-wait", "diagnostic-handoff"):
            expected.append(f"cancel-{target}-{received}-{boundary}")
expected.append("cancel-coordinator-TERM-diagnostic-publication")
expected += ["invalid-start-record", "invalid-cancel-record", "inherited-blocked",
             "wait-completion-race", "shell-error", "cancel-write-failure",
             "exception-before-admission", "exception-while-owned", "exception-after-retirement",
             "completion-write-failure", "completion-rename-failure", "watchdog"]
assert [row[0] for row in rows] == expected
assert all(len(row) == 3 and row[1] and row[2] == "PASS" for row in rows)
assert len(expected) == len(set(expected))
PY

receiver_evidence="$tmp/receiver-evidence.jsonl"
python3 - "$tmp" "$receiver_control_inventory" "$receiver_route_manifest" \
  "$receiver_tool_manifest" "$receiver_evidence" \
  source "$root/scripts/test/replay-materialization-result.test.sh" \
  loaded-wrapper "$loaded_wrapper" receiver-supervisor "$receiver_supervisor" \
  inherit-launcher "$receiver_inherit_launcher" diagnostic-reader "$receiver_diagnostic_reader" \
  shell-runner "$receiver_shell_runner" control-wrapper "$receiver_control_wrapper" \
  replay "$replay" <<'PY'
import glob
import hashlib
import json
from pathlib import Path
import sys

tmp, inventory_path, route_path, tools_path, output_path, *helper_arguments = sys.argv[1:]
tmp = Path(tmp)
intentional_missing = {"completion-write-failure", "completion-rename-failure"}
limits = {"completion": 32768, "diagnostic": 32768, "shell-result": 4096}


def read_bounded(path, limit):
    path = Path(path)
    data = path.read_bytes()
    assert len(data) <= limit, (str(path), len(data), limit)
    return data


def digest(data):
    return hashlib.sha256(data).hexdigest()


evidence = []


def emit(kind, name, **facts):
    evidence.append({"kind": kind, "name": name, **facts})


inventory_data = read_bounded(inventory_path, 32768)
inventory_rows = [line.split("\t") for line in inventory_data.decode().splitlines()]
assert len(inventory_rows) == 72
for ordinal, row in enumerate(inventory_rows, 1):
    assert len(row) == 3 and row[2] == "PASS"
    emit("receiver-inventory", row[0], ordinal=ordinal, phase=row[1], result=row[2])
emit("proof-hash", "receiver-inventory", bytes=len(inventory_data), sha256=digest(inventory_data))

for kind, path, fields, limit in (
        ("route-manifest", route_path, ("type", "path", "sha256", "mode"), 65536),
        ("tool-manifest", tools_path, ("tool", "path", "sha256", "version"), 32768)):
    data = read_bounded(path, limit)
    rows = [line.split("\t", len(fields) - 1) for line in data.decode().splitlines()]
    assert rows and all(len(row) == len(fields) for row in rows)
    for ordinal, row in enumerate(rows, 1):
        emit(kind, row[1] if kind == "route-manifest" else row[0], ordinal=ordinal,
             record=dict(zip(fields, row)))
    emit("proof-hash", kind, bytes=len(data), sha256=digest(data))

assert len(helper_arguments) % 2 == 0
for index in range(0, len(helper_arguments), 2):
    name, path = helper_arguments[index:index + 2]
    data = Path(path).read_bytes()
    emit("source-hash", name, bytes=len(data), sha256=digest(data))

for inventory_name, unused_phase, unused_result in inventory_rows:
    record_case = inventory_name.removeprefix("real-") if inventory_name.startswith("real-") else inventory_name
    if inventory_name.startswith("real-"):
        invocation = tmp / ("supervised-" + record_case)
    else:
        choices = [tmp / ("control-" + inventory_name), tmp / inventory_name]
        existing = [path for path in choices if path.is_dir()]
        assert len(existing) == 1, (inventory_name, [str(path) for path in existing])
        invocation = existing[0]

    completion_paths = [Path(path) for path in glob.glob(str(invocation / "completion-*.json"))]
    completions = [path for path in completion_paths if path.is_file()]
    assert len(completions) == (0 if inventory_name in intentional_missing else 1), inventory_name
    if completions:
        assert completion_paths == completions
        completion_data = read_bounded(completions[0], limits["completion"])
        completion = json.loads(completion_data)
        assert completion["case"] == record_case
        emit("completion", inventory_name, state="present", bytes=len(completion_data),
             sha256=digest(completion_data), record=completion)
    else:
        assert len(completion_paths) <= 1
        emit("completion", inventory_name, state="intentionally-missing",
             reason="injected " + inventory_name,
             path_state="directory" if completion_paths else "absent")

    shell_candidates = list(invocation.glob("completion-*.json.shell-result"))
    shell_candidates += list(invocation.glob("shell-result.json"))
    assert len(shell_candidates) == 1, (inventory_name, [str(path) for path in shell_candidates])
    shell_data = read_bounded(shell_candidates[0], limits["shell-result"])
    shell_record = json.loads(shell_data)
    assert shell_record["case"] == record_case
    emit("shell-result", inventory_name, bytes=len(shell_data), sha256=digest(shell_data),
         record=shell_record)

    diagnostic_candidates = list(invocation.glob("completion-*.json.diagnostic"))
    assert len(diagnostic_candidates) <= 1, inventory_name
    if diagnostic_candidates:
        diagnostic_data = read_bounded(diagnostic_candidates[0], limits["diagnostic"])
        if diagnostic_data:
            diagnostic_record = json.loads(diagnostic_data)
            assert diagnostic_record["case"] == record_case
            emit("diagnostic", inventory_name, state="present", bytes=len(diagnostic_data),
                 sha256=digest(diagnostic_data), record=diagnostic_record)
        else:
            emit("diagnostic", inventory_name, state="empty", bytes=0,
                 sha256=digest(diagnostic_data))
    else:
        emit("diagnostic", inventory_name, state="absent")

    for stream in ("stdout", "stderr"):
        capture_path = invocation / stream
        if inventory_name.startswith("real-"):
            capture_path = tmp / (record_case + (".out" if stream == "stdout" else ".err"))
        if capture_path.exists():
            capture_data = capture_path.read_bytes()
            emit("capture", inventory_name, stream=stream, state="present", bytes=len(capture_data),
                 sha256=digest(capture_data))
        else:
            emit("capture", inventory_name, stream=stream, state="absent")
    emit("retention", inventory_name, retained=(invocation / "retained").exists())

encoded = b"".join((json.dumps(item, sort_keys=True, separators=(",", ":")) + "\n").encode()
                   for item in evidence)
assert len(encoded) <= 2 * 1024 * 1024
Path(output_path).write_bytes(encoded)
PY
/bin/cat "$receiver_evidence"
printf '{"bytes":%s,"kind":"proof-hash","name":"receiver-evidence","sha256":"%s"}\n' \
  "$(wc -c < "$receiver_evidence" | tr -d ' ')" "$(sha_file "$receiver_evidence")"
pass 'receiver supervision enforces the real 60-second setup watchdog'

checkpoint_helper="$tmp/checkpoint1-cases.py"
cat > "$checkpoint_helper" <<'PY'
import copy
import ast
import errno
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import time
from types import SimpleNamespace

(driver, input_path, key_path, source_git, base_state, base_candidate, base_scratch,
 closure_helper, jq_bin, expected_sha, case_root, inventory_path, no_change_input,
 no_change_key, no_change_state, no_change_candidate, no_change_scratch,
 no_change_expected_sha, loaded_wrapper) = sys.argv[1:]
driver = Path(driver)
input_path = Path(input_path)
key_path = Path(key_path)
source_git = Path(source_git)
base_state = Path(base_state)
base_candidate = Path(base_candidate)
base_scratch = Path(base_scratch)
no_change_input = Path(no_change_input)
no_change_key = Path(no_change_key)
no_change_state = Path(no_change_state)
no_change_candidate = Path(no_change_candidate)
no_change_scratch = Path(no_change_scratch)
case_root = Path(case_root)
inventory_path = Path(inventory_path)
case_root.mkdir(mode=0o700)
base_key = json.loads(key_path.read_bytes())
base_state_value = json.loads((base_state / "run.json").read_bytes())


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode() + b"\n"


def sha(value):
    return hashlib.sha256(value).hexdigest()


def set_path(value, path, replacement):
    target = value
    for name in path[:-1]:
        target = target[name]
    target[path[-1]] = replacement


def delete_path(value, path):
    target = value
    for name in path[:-1]:
        target = target[name]
    del target[path[-1]]


def mutate(path, replacement=None, delete=False):
    def apply(value):
        if delete:
            delete_path(value, path)
        else:
            set_path(value, path, copy.deepcopy(replacement))
    return apply


def value_at(value, path):
    for name in path:
        value = value[name]
    return value


def asserted_sets(*changes):
    def apply(value):
        for path, replacement in changes:
            if value_at(value, path) == replacement:
                raise AssertionError(("mutation already present", path, replacement))
            set_path(value, path, copy.deepcopy(replacement))
            if value_at(value, path) != replacement:
                raise AssertionError(("mutation not applied", path, replacement))
    return apply


def inventory(root):
    entries = []

    def visit(path, relative):
        metadata = os.lstat(path)
        item = {"path": relative, "mode": stat.S_IMODE(metadata.st_mode)}
        if stat.S_ISLNK(metadata.st_mode):
            item.update({"type": "symlink", "target": os.readlink(path)})
        elif stat.S_ISDIR(metadata.st_mode):
            item["type"] = "directory"
            for child in sorted(os.scandir(path), key=lambda entry: entry.name):
                visit(Path(child.path), f"{relative}/{child.name}" if relative else child.name)
        elif stat.S_ISREG(metadata.st_mode):
            data = Path(path).read_bytes()
            item.update({"type": "file", "bytes": len(data), "sha256": sha(data)})
            if Path(path).name == "replay.lock":
                item["inode"] = metadata.st_ino
        else:
            item["type"] = "other"
        entries.append(item)

    if not os.path.lexists(root):
        return [{"path": "", "type": "missing"}]
    visit(root, "")
    return sorted(entries, key=lambda item: item["path"])


def evidence_snapshot(state, candidate, scratch, supplied_input, supplied_key):
    return {
        "state": inventory(state),
        "candidate": inventory(candidate),
        "scratch": inventory(scratch),
        "supplied_input": inventory(supplied_input),
        "supplied_key": inventory(supplied_key),
    }


def case_directories(name, pending=False):
    root = case_root / name
    state = root / "state"
    candidate = root / "candidate"
    scratch = root / "scratch"
    supplied_input = root / "materialization-input.json"
    supplied_key = root / "delivery-key.json"
    shutil.copytree(base_state, state, symlinks=True)
    if pending:
        candidate.mkdir(mode=0o700)
        scratch.mkdir(mode=0o700)
    else:
        shutil.copytree(base_candidate, candidate, symlinks=True)
        shutil.copytree(base_scratch, scratch, symlinks=True)
    supplied_input.write_bytes(input_path.read_bytes())
    supplied_key.write_bytes(key_path.read_bytes())
    return root, state, candidate, scratch, supplied_input, supplied_key


def command(state, candidate, scratch, supplied_input, supplied_key):
    return [
        sys.executable, str(driver), "--input", str(supplied_input),
        "--delivery-key", str(supplied_key),
        "--source-repository-id", "fixture.target", "--source-git-dir", str(source_git),
        "--candidate-root", str(candidate), "--scratch-root", str(scratch),
        "--state-dir", str(state), "--closure-helper", closure_helper, "--jq-bin", jq_bin,
        "--verify-path", "source.txt", "--expected-sha256", expected_sha,
        "--read-materialization-result",
    ]


def record(group, name, outcome):
    line = f"{group}\t{name}\t{outcome}\n"
    with inventory_path.open("a", encoding="utf-8") as handle:
        handle.write(line)
    print(f"checkpoint1 {group} {name}: {outcome}")


def assert_read_envelope(value, response=None, key=None, run_key=None, unavailable=None):
    expected = {"schema_version": 1, "kind": "delivery_replay_materialization_result",
                "authority": "none", "qualification": "unavailable", "offline_simulation": True}
    if unavailable is not None:
        expected.update(status="unavailable", reason_id=unavailable)
    else:
        original = json.loads(response)
        extracted = subprocess.run([jq_bin, '-S', '-c', '.stage_result'], input=response,
                                   stdout=subprocess.PIPE, check=True).stdout
        expected.update(status="stored", delivery_key=key, run_key=run_key,
                        response_utf8=response.decode(),
                        stage_result={"content": original['stage_result'], "sha256": sha(extracted)},
                        receipt=original['payloads'][0])
    assert type(value.get('schema_version')) is int
    assert type(value.get('offline_simulation')) is bool
    assert value == expected and value.keys() == expected.keys(), (value, expected)


def invoke_case(group, name, expected_status, state_value=None, state_bytes=None,
                key_bytes=None, input_bytes=None, pending=False, output_kind=None, diagnostic=None):
    _, state, candidate, scratch, supplied_input, supplied_key = case_directories(
        name, pending=pending
    )
    if state_value is not None:
        (state / "run.json").write_bytes(encoded(state_value))
    if state_bytes is not None:
        (state / "run.json").write_bytes(state_bytes)
    if key_bytes is not None:
        supplied_key.write_bytes(key_bytes)
    if input_bytes is not None:
        supplied_input.write_bytes(input_bytes)
    before = evidence_snapshot(state, candidate, scratch, supplied_input, supplied_key)
    completed = subprocess.run(command(state, candidate, scratch, supplied_input, supplied_key),
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    after = evidence_snapshot(state, candidate, scratch, supplied_input, supplied_key)
    if completed.returncode != expected_status:
        raise AssertionError((group, name, "status", completed.returncode,
                              completed.stdout, completed.stderr))
    if b"Traceback" in completed.stderr:
        raise AssertionError((group, name, "traceback", completed.stderr))
    if diagnostic is not None:
        assert diagnostic in completed.stderr, (group, name, completed.stderr)
    if before != after:
        raise AssertionError((group, name, "evidence changed"))
    if output_kind is None:
        if b"delivery_replay_materialization_result" in completed.stdout:
            raise AssertionError((group, name, "scanner-ready output on refusal"))
    else:
        output = json.loads(completed.stdout)
        if expected_status == 3:
            assert_read_envelope(output, unavailable="replay.materialization-result-missing")
        if output.get("kind") != output_kind:
            raise AssertionError((group, name, "wrong output", output))
    record(group, name, "PASS")


def key_variant(name, operation, expected_status):
    value = copy.deepcopy(base_key)
    operation(value)
    return name, value, expected_status


key_cases = []
for field in ("initiative_id", "workflow_id", "stage_id", "task_class_id"):
    key_cases.extend([
        key_variant(f"missing-stage-{field}", mutate(["stage_key", field], delete=True), 1),
        key_variant(f"typed-stage-{field}", mutate(["stage_key", field], 7), 1),
        key_variant(f"conflicting-stage-{field}", mutate(["stage_key", field], f"other.{field}"), 2),
    ])
for field in ("stage_key", "request_sha256", "operation", "attempt_number"):
    key_cases.append(key_variant(f"missing-top-{field}", mutate([field], delete=True), 1))
key_cases.extend([
    key_variant("extra-delivery-ordinal", mutate(["delivery_ordinal"], 2), 1),
    key_variant("extra-stage-field", mutate(["stage_key", "extra"], "value"), 1),
    key_variant("null-stage-key", mutate(["stage_key"], None), 1),
    key_variant("list-stage-key", mutate(["stage_key"], []), 1),
    key_variant("empty-stage-key", mutate(["stage_key"], {}), 1),
    key_variant("null-stage-value", mutate(["stage_key", "stage_id"], None), 1),
    key_variant("list-stage-value", mutate(["stage_key", "stage_id"], []), 1),
    key_variant("object-stage-value", mutate(["stage_key", "stage_id"], {}), 1),
    key_variant("null-request", mutate(["request_sha256"], None), 1),
    key_variant("list-request", mutate(["request_sha256"], []), 1),
    key_variant("object-request", mutate(["request_sha256"], {}), 1),
    key_variant("boolean-request", mutate(["request_sha256"], True), 1),
    key_variant("malformed-request", mutate(["request_sha256"], "bad"), 1),
    key_variant("conflicting-request", mutate(["request_sha256"], "0" * 64), 2),
    key_variant("null-operation", mutate(["operation"], None), 1),
    key_variant("list-operation", mutate(["operation"], []), 1),
    key_variant("object-operation", mutate(["operation"], {}), 1),
    key_variant("unsupported-operation", mutate(["operation"], "dispatch-other"), 1),
    key_variant("null-attempt", mutate(["attempt_number"], None), 1),
    key_variant("list-attempt", mutate(["attempt_number"], []), 1),
    key_variant("object-attempt", mutate(["attempt_number"], {}), 1),
    key_variant("boolean-attempt", mutate(["attempt_number"], True), 1),
    key_variant("fractional-attempt", mutate(["attempt_number"], 1.5), 1),
    key_variant("unsupported-attempt", mutate(["attempt_number"], 2), 1),
])

for name, value, expected_status in key_cases:
    invoke_case("P03-supplied-key", f"supplied-{name}", expected_status,
                key_bytes=encoded(value))
    saved = copy.deepcopy(base_state_value)
    saved["identity"]["delivery_key"] = value
    invoke_case("P03-saved-key", f"saved-{name}", expected_status, state_value=saved)

base_input_value = json.loads(input_path.read_bytes())
for name, replacement, expected_status in (
    ("boolean-input-attempt", True, 1),
    ("fractional-input-attempt", 1.5, 1),
    ("unsupported-input-attempt", 2, 2),
):
    value = copy.deepcopy(base_input_value)
    value["attempt"]["attempt_number"] = replacement
    invoke_case("P03-input-attempt", name, expected_status, input_bytes=encoded(value))

raw_key_cases = {
    "duplicate-member": encoded(base_key).replace(b'"operation":"dispatch-stage"',
        b'"operation":"dispatch-stage","operation":"dispatch-stage"', 1),
    "trailing-document": encoded(base_key) + b"{}\n",
    "bom": b"\xef\xbb\xbf" + encoded(base_key),
    "invalid-utf8": encoded(base_key)[:-1] + b"\xff\n",
    "lone-surrogate": encoded(base_key).replace(b'"operation":"dispatch-stage"',
        b'"operation":"\\ud800"', 1),
    "truncated": encoded(base_key)[:-2],
    "nan": encoded(base_key).replace(b'"attempt_number":1', b'"attempt_number":NaN'),
    "infinity": encoded(base_key).replace(b'"attempt_number":1', b'"attempt_number":Infinity'),
    "negative-infinity": encoded(base_key).replace(b'"attempt_number":1', b'"attempt_number":-Infinity'),
    "positive-overflow": encoded(base_key).replace(b'"attempt_number":1', b'"attempt_number":1e999'),
    "negative-overflow": encoded(base_key).replace(b'"attempt_number":1', b'"attempt_number":-1e999'),
}
for name, value in raw_key_cases.items():
    invoke_case("P05-key-parser", f"key-{name}", 1, key_bytes=value)


def state_variant(name, operation, pending=False):
    value = pending_state() if pending else copy.deepcopy(base_state_value)
    operation(value)
    return name, value, pending


def pending_state():
    value = copy.deepcopy(base_state_value)
    value["phase"] = "materializing"
    value["receiver_result"] = {"schema_version": 1, "status": "pending"}
    for field in ("materialization", "verification", "review", "publisher",
                  "recoverable", "reason", "recovery"):
        value.pop(field, None)
    value["identity"].pop("candidate_commit_id", None)
    value["identity"].pop("candidate_tree_id", None)
    return value


state_cases = [
    state_variant("unsupported-version", mutate(["schema_version"], 3)),
    state_variant("unsupported-receiver-version", mutate(["receiver_result", "schema_version"], 2)),
    state_variant("unknown-receiver-status", mutate(["receiver_result", "status"], "unknown")),
    state_variant("unsupported-source-algorithm", mutate(["identity", "source_hash_algorithm"], "md5")),
    state_variant("unknown-phase", mutate(["phase"], "unknown")),
    state_variant("boolean-version-true", mutate(["schema_version"], True)),
    state_variant("boolean-version-false", mutate(["schema_version"], False)),
    state_variant("fraction-version", mutate(["schema_version"], 1.0)),
    state_variant("list-phase", mutate(["phase"], [])),
    state_variant("object-phase", mutate(["phase"], {})),
    state_variant("null-phase", mutate(["phase"], None)),
    state_variant("numeric-phase", mutate(["phase"], 1)),
    state_variant("list-source-algorithm", mutate(["identity", "source_hash_algorithm"], [])),
    state_variant("object-source-algorithm", mutate(["identity", "source_hash_algorithm"], {})),
    state_variant("null-source-algorithm", mutate(["identity", "source_hash_algorithm"], None)),
    state_variant("boolean-receiver-version", mutate(["receiver_result", "schema_version"], True)),
    state_variant("fraction-receiver-version", mutate(["receiver_result", "schema_version"], 1.0)),
    state_variant("list-receiver-status", mutate(["receiver_result", "status"], [])),
    state_variant("object-receiver-status", mutate(["receiver_result", "status"], {})),
    state_variant("null-receiver-status", mutate(["receiver_result", "status"], None)),
    state_variant("numeric-receiver-status", mutate(["receiver_result", "status"], 1)),
    state_variant("list-response", mutate(["receiver_result", "response_utf8"], [])),
    state_variant("boolean-response-digest", mutate(["receiver_result", "response_sha256"], True)),
    state_variant("list-verifier", mutate(["identity", "verifier"], [])),
    state_variant("extra-verifier-field", mutate(["identity", "verifier", "extra"], "value")),
    state_variant("boolean-verifier-digest", mutate(["identity", "verifier", "expected_sha256"], True)),
    state_variant("list-materialization", mutate(["materialization"], [])),
    state_variant("extra-materialization-field", mutate(["materialization", "extra"], "value")),
    state_variant("missing-materialization-field", mutate(["materialization", "receipt_sha256"], delete=True)),
    state_variant("typed-materialization-oid", mutate(["materialization", "candidate_commit_id"], [])),
    state_variant("typed-materialization-digest", mutate(["materialization", "response_sha256"], True)),
    state_variant("list-verification", mutate(["verification"], [])),
    state_variant("null-verification-review-wait", mutate(["verification"], None)),
    state_variant("extra-verification-field", mutate(["verification", "extra"], "value")),
    state_variant("missing-verification-field", mutate(["verification", "sha256"], delete=True)),
    state_variant("typed-verification-digest", mutate(["verification", "sha256"], True)),
    state_variant("unknown-state-field", mutate(["unknown"], "value")),
    state_variant("unknown-identity-field", mutate(["identity", "unknown"], "value")),
    state_variant("missing-stored-materialization", mutate(["materialization"], delete=True)),
    state_variant("missing-stored-candidate", mutate(["identity", "candidate_commit_id"], delete=True)),
]
for field in ("recoverable", "reason", "recovery"):
    for label, replacement in (("null", None), ("number", 1), ("list", []), ("object", {})):
        state_cases.append(state_variant(f"{field}-{label}", mutate([field], replacement)))
state_cases.append(state_variant("recoverable-zero", mutate(["recoverable"], 0)))
state_cases.extend([
    state_variant("review-list", mutate(["review"], [])),
    state_variant("review-null-review-wait", mutate(["review"], None)),
    state_variant("review-extra", mutate(["review"], {"actor_id": "test.reviewer", "verdict": "clean", "sha256": "0" * 64, "extra": 1})),
    state_variant("review-actor-type", mutate(["review"], {"actor_id": 1, "verdict": "clean", "sha256": "0" * 64})),
    state_variant("publisher-list", mutate(["publisher"], [])),
    state_variant("publisher-null-review-wait", mutate(["publisher"], None)),
    state_variant("publisher-extra", mutate(["publisher"], {"actor_id": "test.publisher", "disposition": "offline-simulated", "sha256": "0" * 64, "extra": 1})),
    state_variant("publisher-actor-type", mutate(["publisher"], {"actor_id": 1, "disposition": "offline-simulated", "sha256": "0" * 64})),
    state_variant("pending-wrong-phase", mutate(["phase"], "verifying"), pending=True),
    state_variant("pending-extra-receiver-field", mutate(["receiver_result", "extra"], 1), pending=True),
    state_variant("pending-boolean-receiver-version", mutate(["receiver_result", "schema_version"], True), pending=True),
    state_variant("pending-list-status", mutate(["receiver_result", "status"], []), pending=True),
    state_variant("pending-with-materialization", mutate(["materialization"], copy.deepcopy(base_state_value["materialization"])), pending=True),
    state_variant("pending-with-candidate-id", mutate(["identity", "candidate_commit_id"], base_state_value["identity"]["candidate_commit_id"]), pending=True),
])
verifying_null = copy.deepcopy(base_state_value)
verifying_null["phase"] = "verifying"
verifying_null["verification"] = None
state_cases.append(("verification-null-verifying", verifying_null, False))
failed_null = copy.deepcopy(base_state_value)
failed_null.update({"phase": "failed", "recoverable": False,
                    "reason": "fixed verifier failed", "verification": None})
state_cases.append(("verification-null-failed", failed_null, False))
for field in ("review", "publisher"):
    failed_optional_null = copy.deepcopy(base_state_value)
    failed_optional_null.update({"phase": "failed", "recoverable": False,
                                 "reason": "fixed verifier failed", field: None})
    state_cases.append((f"{field}-null-failed", failed_optional_null, False))
verifying_materialization_null = copy.deepcopy(base_state_value)
verifying_materialization_null["phase"] = "verifying"
verifying_materialization_null.pop("verification", None)
verifying_materialization_null["materialization"] = None
state_cases.append(("materialization-null-verifying", verifying_materialization_null, False))
for name, value, pending in state_cases:
    invoke_case("P04-typed-journal", f"state-{name}", 1, state_value=value, pending=pending)

failed = copy.deepcopy(base_state_value)
failed.update({"phase": "failed", "recoverable": False, "reason": "fixed verifier failed"})
invoke_case("P04-valid-failed", "stored-failed-remains-readable", 0, state_value=failed,
            output_kind="delivery_replay_materialization_result")
failed_recoverable = copy.deepcopy(failed)
failed_recoverable["recoverable"] = True
invoke_case("P04-valid-failed", "stored-recoverable-true-remains-readable", 0,
            state_value=failed_recoverable,
            output_kind="delivery_replay_materialization_result")

review_wait_omission = copy.deepcopy(base_state_value)
review_wait_omission.pop("review", None)
review_wait_omission.pop("publisher", None)
invoke_case("P04-valid-omission", "review-wait-omits-review-and-publisher", 0,
            state_value=review_wait_omission,
            output_kind="delivery_replay_materialization_result")
verifying_omission = copy.deepcopy(base_state_value)
verifying_omission["phase"] = "verifying"
for field in ("verification", "review", "publisher"):
    verifying_omission.pop(field, None)
invoke_case("P04-valid-omission", "verifying-omits-later-records", 0,
            state_value=verifying_omission,
            output_kind="delivery_replay_materialization_result")
failed_omission = copy.deepcopy(base_state_value)
failed_omission.update({"phase": "failed", "recoverable": False,
                        "reason": "fixed verifier failed"})
for field in ("verification", "review", "publisher"):
    failed_omission.pop(field, None)
invoke_case("P04-valid-omission", "failed-stored-omits-optional-records", 0,
            state_value=failed_omission,
            output_kind="delivery_replay_materialization_result")

pending = pending_state()
invoke_case("P04-valid-pending", "pending-remains-unavailable", 3, state_value=pending,
            pending=True, output_kind="delivery_replay_materialization_result")

def raw_journal_cases(value):
    base_raw = encoded(value)
    return {
    "duplicate-member": base_raw.replace(b'"schema_version":2',
        b'"schema_version":2,"schema_version":2', 1),
    "trailing-document": base_raw + b"{}\n",
    "bom": b"\xef\xbb\xbf" + base_raw,
    "invalid-utf8": base_raw[:-1] + b"\xff\n",
    "lone-surrogate": base_raw[:-2] + b',"reason":"\\ud800"}\n',
    "truncated": base_raw[:-2],
    "nan": base_raw[:-2] + b',"recoverable":NaN}\n',
    "infinity": base_raw[:-2] + b',"recoverable":Infinity}\n',
    "negative-infinity": base_raw[:-2] + b',"recoverable":-Infinity}\n',
    "positive-overflow": base_raw[:-2] + b',"recoverable":1e999}\n',
    "negative-overflow": base_raw[:-2] + b',"recoverable":-1e999}\n',
}
for baseline, value, is_pending in (("journal", base_state_value, False),
                                     ("pending-journal", pending_state(), True)):
    for name, raw in raw_journal_cases(value).items():
        invoke_case("P05-journal-parser", f"{baseline}-{name}", 1, state_bytes=raw,
                    pending=is_pending, diagnostic=b"duplicate JSON members" if name == "duplicate-member" else None)


def response_state(response_text, receipt_text=None):
    value = copy.deepcopy(base_state_value)
    response_bytes = response_text.encode("utf-8")
    value["receiver_result"]["response_utf8"] = response_text
    value["receiver_result"]["response_sha256"] = sha(response_bytes)
    value["materialization"]["response_sha256"] = sha(response_bytes)
    if receipt_text is not None:
        receipt_digest = sha(receipt_text.encode("utf-8"))
        value["receiver_result"]["receipt_sha256"] = receipt_digest
        value["materialization"]["receipt_sha256"] = receipt_digest
    return value


invoke_case("P05-response-parser", "response-truncated", 1,
            state_value=response_state("{"))
invoke_case("P05-response-parser", "response-positive-overflow", 1,
            state_value=response_state('{"unused":1e999}'))
for name, receipt_text in (("receipt-positive-overflow", "1e999"),
                           ("receipt-lone-surrogate", '"\\ud800"')):
    response = json.loads(base_state_value["receiver_result"]["response_utf8"])
    response["payloads"][0]["data"] = receipt_text
    response["payloads"][0]["sha256"] = sha(receipt_text.encode("utf-8"))
    response_text = encoded(response).decode("utf-8")
    invoke_case("P05-receipt-parser", name, 1,
                state_value=response_state(response_text, receipt_text))

scope = {"_REPLAY_DRIVER_BYTES": driver.read_bytes(), "__name__": "checkpoint1_driver",
         "__file__": str(driver)}
exec(compile(scope["_REPLAY_DRIVER_BYTES"], str(driver), "exec"), scope)
parse_json = scope["parse_json"]


def nested(levels):
    value = 0
    for _ in range(levels):
        value = [value]
    return encoded(value)


parse_json(nested(31))
record("P05-parser-boundary", "depth-32-accepted", "PASS")
try:
    parse_json(nested(32))
except scope["ReplayError"]:
    record("P05-parser-boundary", "depth-33-rejected", "PASS")
else:
    raise AssertionError("depth 33 accepted")
if parse_json(b"1e308\n") != 1e308:
    raise AssertionError("finite exponent changed")
record("P05-parser-boundary", "finite-exponent-accepted", "PASS")
for name, raw in (("positive-overflow", b"1e999\n"), ("negative-overflow", b"-1e999\n"),
                  ("lone-surrogate", b'"\\ud800"\n')):
    try:
        parse_json(raw)
    except scope["ReplayError"]:
        record("P05-parser-boundary", name, "PASS")
    else:
        raise AssertionError((name, "accepted"))


base_response_text = base_state_value["receiver_result"]["response_utf8"]
base_response = json.loads(base_response_text)
if encoded(base_response).decode() != base_response_text:
    raise AssertionError("actual materializer response is not canonical")


def rehashed_response_state(operation, baseline_state=base_state_value,
                            baseline_response=base_response):
    response = copy.deepcopy(baseline_response)
    operation(response)
    if response.get("payloads") and isinstance(response["payloads"][0], dict) and \
       isinstance(response["payloads"][0].get("data"), str):
        receipt_text = response["payloads"][0]["data"]
    else:
        receipt_text = baseline_response["payloads"][0]["data"]
    receipt_digest = sha(receipt_text.encode())
    stage_digest = sha(encoded(response["stage_result"]))
    response_text = encoded(response).decode()
    response_digest = sha(response_text.encode())
    state = copy.deepcopy(baseline_state)
    state["receiver_result"].update({
        "response_utf8": response_text,
        "response_sha256": response_digest,
        "stage_result_sha256": stage_digest,
        "receipt_sha256": receipt_digest,
    })
    state["materialization"]["response_sha256"] = response_digest
    state["materialization"]["receipt_sha256"] = receipt_digest
    return state


response_duplicate = base_response_text.replace('"schema_version":1',
    '"schema_version":1,"schema_version":1', 1)
assert response_duplicate != base_response_text and json.loads(response_duplicate) == base_response
response_duplicate_state = rehashed_response_state(lambda _: None)
response_duplicate_state['receiver_result']['response_utf8'] = response_duplicate
for record_value in (response_duplicate_state['receiver_result'], response_duplicate_state['materialization']):
    record_value['response_sha256'] = sha(response_duplicate.encode())
invoke_case('P05-response-parser', 'response-same-value-duplicate', 1,
            state_value=response_duplicate_state, diagnostic=b'duplicate JSON members')
receipt_original = base_response['payloads'][0]['data']
receipt_duplicate = receipt_original.replace('"schema_version":1',
    '"schema_version":1,"schema_version":1', 1)
assert receipt_duplicate != receipt_original and json.loads(receipt_duplicate) == json.loads(receipt_original)
receipt_digest = sha(receipt_duplicate.encode())
def duplicate_receipt(response):
    response['payloads'][0].update(data=receipt_duplicate, sha256=receipt_digest)
    body = response['stage_result']['body']
    for item in body['outputs']:
        item['ref']['sha256'] = receipt_digest
    for item in body['evidence']:
        item['proof_ref']['sha256'] = receipt_digest
    body['execution']['metadata']['tools']['source_ref']['sha256'] = receipt_digest
invoke_case('P05-receipt-parser', 'receipt-same-value-duplicate', 1,
            state_value=rehashed_response_state(duplicate_receipt), diagnostic=b'duplicate JSON members')
for name, fields in [('response', [('receiver_result', 'response_sha256'), ('materialization', 'response_sha256')]),
                     ('receipt', [('receiver_result', 'receipt_sha256'), ('materialization', 'receipt_sha256')]),
                     ('stage', [('receiver_result', 'stage_result_sha256')])]:
    value = copy.deepcopy(base_state_value)
    for record_name, field in fields:
        value[record_name][field] = '0' * 64
    assert value['receiver_result']['response_utf8'] == base_response_text
    invoke_case('P08-raw-stored-digest', 'isolated-' + name + '-digest', 1, state_value=value,
                diagnostic=b'response digest changed' if name == 'response' else b'result does not match the journal')


def rehashed_receipt_state(operation, baseline_state=base_state_value,
                           baseline_response=base_response):
    response = copy.deepcopy(baseline_response)
    receipt = json.loads(response["payloads"][0]["data"])
    operation(receipt)
    receipt_text = encoded(receipt).decode()
    receipt_digest = sha(receipt_text.encode())
    response["payloads"][0].update({"data": receipt_text, "sha256": receipt_digest})
    body = response["stage_result"]["body"]
    for ref in (body["outputs"][0]["ref"], body["evidence"][0]["proof_ref"],
                body["execution"]["metadata"]["tools"]["source_ref"]):
        ref["sha256"] = receipt_digest
    return rehashed_response_state(
        lambda value: value.update(response), baseline_state, baseline_response
    )


fixed_response_cases = [
    ("response-schema-version", mutate(["schema_version"], 2)),
    ("response-kind", mutate(["kind"], "other_response")),
    ("response-authority", mutate(["authority"], "write")),
    ("response-qualification-state", mutate(["qualification", "state"], "available")),
    ("response-qualification-reason", mutate(["qualification", "reason_id"], "adapter.other")),
    ("response-effects-empty", mutate(["effects"], [])),
    ("response-effects-extra", mutate(["effects"], ["caller-disposable-candidate-repository", "extra-effect"])),
    ("response-payload-missing", mutate(["payloads"], [])),
    ("response-payload-content-id", mutate(["payloads", 0, "content_id"], "other.receipt")),
    ("response-payload-media-type", mutate(["payloads", 0, "media_type"], "application/octet-stream")),
    ("response-payload-digest", mutate(["payloads", 0, "sha256"], "0" * 64)),
    ("response-extra", mutate(["extra"], True)),
    ("response-missing-authority", mutate(["authority"], delete=True)),
    ("output-receipt-digest", mutate(["stage_result", "body", "outputs", 0, "ref", "sha256"], "0" * 64)),
    ("output-receipt-content-id", mutate(["stage_result", "body", "outputs", 0, "ref", "content_id"], "other.receipt")),
    ("output-receipt-media-type", mutate(["stage_result", "body", "outputs", 0, "ref", "media_type"], "application/octet-stream")),
    ("output-id", mutate(["stage_result", "body", "outputs", 0, "output_id"], "candidate.other")),
    ("evidence-receipt-digest", mutate(["stage_result", "body", "evidence", 0, "proof_ref", "sha256"], "0" * 64)),
    ("evidence-receipt-content-id", mutate(["stage_result", "body", "evidence", 0, "proof_ref", "content_id"], "other.receipt")),
    ("evidence-receipt-media-type", mutate(["stage_result", "body", "evidence", 0, "proof_ref", "media_type"], "application/octet-stream")),
    ("evidence-id", mutate(["stage_result", "body", "evidence", 0, "evidence_id"], "evidence.other")),
    ("evidence-kind", mutate(["stage_result", "body", "evidence", 0, "kind"], "observed")),
    ("evidence-verdict", mutate(["stage_result", "body", "evidence", 0, "verdict"], "failed")),
    ("tools-receipt-digest", mutate(["stage_result", "body", "execution", "metadata", "tools", "source_ref", "sha256"], "0" * 64)),
    ("tools-receipt-content-id", mutate(["stage_result", "body", "execution", "metadata", "tools", "source_ref", "content_id"], "other.receipt")),
    ("tools-receipt-media-type", mutate(["stage_result", "body", "execution", "metadata", "tools", "source_ref", "media_type"], "application/octet-stream")),
    ("tools-computed", mutate(["stage_result", "body", "execution", "metadata", "tools", "state"], "computed")),
    ("tools-value", mutate(["stage_result", "body", "execution", "metadata", "tools", "value"], ["unexpected"])),
    ("metadata-kind", mutate(["stage_result", "body", "execution", "metadata", "kind"], "interactive")),
    ("performer", mutate(["stage_result", "body", "execution", "performer", "principal_id"], "principal.other")),
    ("reported-by", mutate(["stage_result", "body", "reported_by", "principal_id"], "principal.other")),
    ("actual-binding", mutate(["stage_result", "body", "execution", "actual_binding", "binding_id"], "binding.other")),
    ("environment", mutate(["stage_result", "body", "execution", "environment", "environment_id"], "environment.other")),
    ("capability", mutate(["stage_result", "body", "execution", "used_capability", "id"], "core.forge.other.v1")),
    ("request-ref", mutate(["stage_result", "body", "request_ref", "sha256"], "0" * 64)),
    ("result-request-ref-schema-version", asserted_sets(
        (("stage_result", "body", "request_ref", "schema_version"), 1))),
    ("result-request-ref-kind", asserted_sets(
        (("stage_result", "body", "request_ref", "kind"), "profile"))),
    ("result-request-ref-id", asserted_sets(
        (("stage_result", "body", "request_ref", "id"), "request.other"))),
    ("resolved-profile-ref", mutate(["stage_result", "body", "resolved_profile_ref", "sha256"], "0" * 64)),
    ("result-resolved-profile-ref-schema-version", asserted_sets(
        (("stage_result", "body", "resolved_profile_ref", "schema_version"), 1))),
    ("result-resolved-profile-ref-kind", asserted_sets(
        (("stage_result", "body", "resolved_profile_ref", "kind"), "profile"))),
    ("result-resolved-profile-ref-id", asserted_sets(
        (("stage_result", "body", "resolved_profile_ref", "id"), "resolved.other"))),
    ("attempt-id", mutate(["stage_result", "body", "attempt_id"], "attempt.other")),
    ("attempt-number", mutate(["stage_result", "body", "attempt_number"], 2)),
    ("result-version", mutate(["stage_result", "schema_version"], 1)),
    ("result-kind", mutate(["stage_result", "kind"], "other_result")),
    ("result-id", mutate(["stage_result", "id"], "result.other")),
    ("status", mutate(["stage_result", "body", "status"], "failed")),
    ("outcome-family", mutate(["stage_result", "body", "outcome", "family"], "other")),
    ("diagnostics", mutate(["stage_result", "body", "diagnostics"], [{}])),
    ("started-at", mutate(["stage_result", "body", "started_at"], "2026-08-30T00:00:00Z")),
    ("finished-at", mutate(["stage_result", "body", "finished_at"], "2026-08-30T00:00:03Z")),
    ("recorded-at", mutate(["stage_result", "body", "recorded_at"], "2026-08-30T00:00:04Z")),
    ("result-extra", mutate(["stage_result", "extra"], True)),
    ("body-extra", mutate(["stage_result", "body", "extra"], True)),
    ("metadata-extra", mutate(["stage_result", "body", "execution", "metadata", "extra"], True)),
    ("execution-extra", mutate(["stage_result", "body", "execution", "extra"], True)),
    ("body-missing-reported-by", mutate(["stage_result", "body", "reported_by"], delete=True)),
    ("execution-missing-metadata", mutate(["stage_result", "body", "execution", "metadata"], delete=True)),
    ("metadata-missing-tools", mutate(["stage_result", "body", "execution", "metadata", "tools"], delete=True)),
    ("output-missing-ref", mutate(["stage_result", "body", "outputs", 0, "ref"], delete=True)),
    ("evidence-missing-proof-ref", mutate(["stage_result", "body", "evidence", 0, "proof_ref"], delete=True)),
]
for fact in ("provider", "model", "snapshot", "effort", "prompt", "skills"):
    fixed_response_cases.append((
        f"metadata-{fact}",
        mutate(["stage_result", "body", "execution", "metadata", fact], {"state": "unavailable"}),
    ))


def append_duplicate(path):
    def apply(value):
        target = value
        for name in path:
            target = target[name]
        target.append(copy.deepcopy(target[0]))
    return apply


fixed_response_cases.extend([
    ("response-payload-extra", append_duplicate(["payloads"])),
    ("output-cardinality", append_duplicate(["stage_result", "body", "outputs"])),
    ("evidence-cardinality", append_duplicate(["stage_result", "body", "evidence"])),
])
for name, operation in fixed_response_cases:
    invoke_case("P08-persisted-fixed-response", name, 1,
                state_value=rehashed_response_state(operation))

for name, operation in (
    ("changed-outcome-no-change", asserted_sets(
        (("stage_result", "body", "outcome", "value"), "no-change"),
        (("stage_result", "body", "outputs"), []))),
    ("changed-outcome-unsupported", asserted_sets(
        (("stage_result", "body", "outcome", "value"), "unsupported"),
        (("stage_result", "body", "outputs"), []))),
    ("changed-missing-candidate-output", asserted_sets(
        (("stage_result", "body", "outputs"), []))),
):
    invoke_case("P08-persisted-outcome", name, 1,
                state_value=rehashed_response_state(operation))

for name, operation in (
    ("receipt-version", mutate(["schema_version"], 2)),
    ("receipt-kind", mutate(["kind"], "other_receipt")),
    ("receipt-adapter-id", mutate(["adapter", "id"], "adapter.other")),
    ("receipt-adapter-version", mutate(["adapter", "version"], "v2")),
    ("receipt-adapter-status", mutate(["adapter", "status"], "active")),
    ("receipt-attempt-id", mutate(["attempt", "attempt_id"], "attempt.other")),
    ("receipt-attempt-number", mutate(["attempt", "attempt_number"], 2)),
    ("receipt-request-ref", mutate(["request_ref", "sha256"], "0" * 64)),
    ("receipt-request-ref-schema-version", asserted_sets(
        (("request_ref", "schema_version"), 1))),
    ("receipt-request-ref-kind", asserted_sets(
        (("request_ref", "kind"), "profile"))),
    ("receipt-request-ref-id", asserted_sets(
        (("request_ref", "id"), "request.other"))),
    ("receipt-resolved-profile-ref", mutate(["resolved_profile_ref", "sha256"], "0" * 64)),
    ("receipt-resolved-profile-ref-schema-version", asserted_sets(
        (("resolved_profile_ref", "schema_version"), 1))),
    ("receipt-resolved-profile-ref-kind", asserted_sets(
        (("resolved_profile_ref", "kind"), "profile"))),
    ("receipt-resolved-profile-ref-id", asserted_sets(
        (("resolved_profile_ref", "id"), "resolved.other"))),
    ("receipt-manifest-ref", mutate(["manifest_ref", "sha256"], "0" * 64)),
    ("receipt-manifest-ref-schema-version", asserted_sets(
        (("manifest_ref", "schema_version"), 1))),
    ("receipt-manifest-ref-kind", asserted_sets(
        (("manifest_ref", "kind"), "profile"))),
    ("receipt-manifest-ref-id", asserted_sets(
        (("manifest_ref", "id"), "adapter.other"))),
    ("receipt-materialization-contract-ref", mutate(["materialization_contract_ref", "sha256"], "0" * 64)),
    ("receipt-materialization-contract-ref-content-id", asserted_sets(
        (("materialization_contract_ref", "content_id"), "contract.other"))),
    ("receipt-materialization-contract-ref-media-type", asserted_sets(
        (("materialization_contract_ref", "media_type"), "application/octet-stream"))),
    ("receipt-patch-ref", mutate(["patch_ref", "sha256"], "0" * 64)),
    ("receipt-patch-ref-content-id", asserted_sets(
        (("patch_ref", "content_id"), "patch.other"))),
    ("receipt-patch-ref-media-type", asserted_sets(
        (("patch_ref", "media_type"), "application/octet-stream"))),
    ("receipt-source-repository", mutate(["source", "repository_id"], "fixture.other")),
    ("receipt-source-algorithm", mutate(["source", "hash_algorithm"], "sha256")),
    ("receipt-source-commit", mutate(["source", "commit_id"], "9" * 40)),
    ("receipt-source-tree", mutate(["source", "tree_id"], "0" * 40)),
    ("receipt-candidate-kind", mutate(["candidate", "repository_kind"], "worktree")),
    ("receipt-candidate-algorithm", mutate(["candidate", "hash_algorithm"], "sha256")),
    ("receipt-candidate-commit", mutate(["candidate", "commit_id"], "8" * 40)),
    ("receipt-candidate-tree", mutate(["candidate", "tree_id"], "7" * 40)),
    ("receipt-candidate-parent", mutate(["candidate", "parent_commit_id"], "6" * 40)),
    ("receipt-changed-paths-count", mutate(["changed_paths", "count"], 2)),
    ("receipt-changed-paths-digest", mutate(["changed_paths", "sha256"], "0" * 64)),
    ("receipt-extra", mutate(["extra"], True)),
    ("receipt-missing-patch-ref", mutate(["patch_ref"], delete=True)),
):
    invoke_case("P08-persisted-receipt", name, 1,
                state_value=rehashed_receipt_state(operation))

invoke_case("P08-real-positive", "changed-stored-reopen", 0,
            output_kind="delivery_replay_materialization_result")

no_change_state_value = json.loads((no_change_state / "run.json").read_bytes())
no_change_response_text = no_change_state_value["receiver_result"]["response_utf8"]
no_change_response_value = json.loads(no_change_response_text)
if encoded(no_change_response_value).decode() != no_change_response_text:
    raise AssertionError("actual no-change materializer response is not canonical")


def invoke_no_change_case(name, operation):
    root = case_root / f"no-change-{name}"
    state = root / "state"
    candidate = root / "candidate"
    scratch = root / "scratch"
    supplied_input = root / "materialization-input.json"
    supplied_key = root / "delivery-key.json"
    shutil.copytree(no_change_state, state, symlinks=True)
    shutil.copytree(no_change_candidate, candidate, symlinks=True)
    shutil.copytree(no_change_scratch, scratch, symlinks=True)
    supplied_input.parent.mkdir(mode=0o700, exist_ok=True)
    supplied_input.write_bytes(no_change_input.read_bytes())
    supplied_key.write_bytes(no_change_key.read_bytes())
    mutated = rehashed_response_state(
        operation, no_change_state_value, no_change_response_value
    )
    (state / "run.json").write_bytes(encoded(mutated))
    before = evidence_snapshot(state, candidate, scratch, supplied_input, supplied_key)
    completed = subprocess.run([
        sys.executable, str(driver), "--input", str(supplied_input),
        "--delivery-key", str(supplied_key),
        "--source-repository-id", "fixture.target", "--source-git-dir", str(source_git),
        "--candidate-root", str(candidate), "--scratch-root", str(scratch),
        "--state-dir", str(state), "--closure-helper", closure_helper,
        "--jq-bin", jq_bin, "--verify-path", "source.txt",
        "--expected-sha256", no_change_expected_sha, "--read-materialization-result",
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    after = evidence_snapshot(state, candidate, scratch, supplied_input, supplied_key)
    if completed.returncode != 1 or b"Traceback" in completed.stderr or before != after:
        raise AssertionError((name, completed.returncode, completed.stderr, before == after))
    if b"delivery_replay_materialization_result" in completed.stdout:
        raise AssertionError((name, "scanner-ready output on refusal"))
    record("P08-persisted-outcome", name, "PASS")


no_change_output = [{
    "output_id": "candidate.repository",
    "ref": copy.deepcopy(
        no_change_response_value["stage_result"]["body"]["evidence"][0]["proof_ref"]
    ),
}]
invoke_no_change_case("no-change-outcome-changed", asserted_sets(
    (("stage_result", "body", "outcome", "value"), "changed"),
    (("stage_result", "body", "outputs"), no_change_output),
))
invoke_no_change_case("no-change-outcome-unsupported", asserted_sets(
    (("stage_result", "body", "outcome", "value"), "unsupported"),
))
invoke_no_change_case("no-change-unexpected-candidate-output", asserted_sets(
    (("stage_result", "body", "outputs"), no_change_output),
))


def invoke_existing_positive(name, supplied_input, supplied_key, state, candidate,
                             scratch, expected_digest):
    before = evidence_snapshot(state, candidate, scratch, supplied_input, supplied_key)
    completed = subprocess.run([
        sys.executable, str(driver), "--input", str(supplied_input),
        "--delivery-key", str(supplied_key),
        "--source-repository-id", "fixture.target", "--source-git-dir", str(source_git),
        "--candidate-root", str(candidate), "--scratch-root", str(scratch),
        "--state-dir", str(state), "--closure-helper", closure_helper,
        "--jq-bin", jq_bin, "--verify-path", "source.txt",
        "--expected-sha256", expected_digest, "--read-materialization-result",
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    after = evidence_snapshot(state, candidate, scratch, supplied_input, supplied_key)
    if completed.returncode != 0 or b"Traceback" in completed.stderr or before != after:
        raise AssertionError((name, completed.returncode, completed.stderr, before == after))
    output = json.loads(completed.stdout)
    if output.get("kind") != "delivery_replay_materialization_result" or \
       output.get("stage_result", {}).get("content", {}).get("body", {}).get(
           "outcome", {}).get("value") != "no-change":
        raise AssertionError((name, "wrong output", output))
    record("P08-real-positive", name, "PASS")


invoke_existing_positive(
    "no-change-stored-reopen", no_change_input, no_change_key, no_change_state,
    no_change_candidate, no_change_scratch, no_change_expected_sha
)

stream_program = """
import os, sys
out, err, style, status = sys.argv[1:]
out, err, status = int(out), int(err), int(status)
def write(fd, count, byte):
    while count:
        data = byte * min(count, 16384)
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        count -= len(data)
if style == 'before':
    write(2, err, b'e'); write(1, out, b'o')
elif style == 'interleaved':
    while out or err:
        n, m = min(out, 16384), min(err, 16384)
        write(1, n, b'o'); write(2, m, b'e')
        out -= n; err -= m
elif style == 'early-eof':
    os.close(1); write(2, err, b'e')
else:
    write(1, out, b'o'); write(2, err, b'e')
raise SystemExit(status)
"""

assert (scope['MAX_RESPONSE_BYTES'], scope['MAX_GIT_PATH_BYTES'],
        scope['MAX_STDERR_BYTES']) == (1024*1024, 2*1024*1024, 64*1024)
capture = scope['_capture_fixed_process']


def finite_capture(name, out, err=0, limit=1024*1024, style='plain', status=0,
                   fault=None, report=True):
    children, buffers, owned_descriptors = [], [], []
    original_popen, original_read = subprocess.Popen, os.read

    class ObservedBuffer(bytearray):
        def __init__(self):
            super().__init__()
            self.maximum = 0
            buffers.append(self)

        def extend(self, value):
            super().extend(value)
            self.maximum = max(self.maximum, len(self))

    def tracked_popen(*args, **kwargs):
        child = original_popen(*args, **kwargs)
        children.append(child)
        owned_descriptors.extend((child.stdout.fileno(), child.stderr.fileno()))
        return child

    def checked_read(descriptor, size):
        if descriptor in owned_descriptors:
            assert size <= 65536
            if fault == 'read':
                raise OSError(errno.EIO, 'owned test read failure')
            if fault == 'interrupt':
                raise KeyboardInterrupt('owned test interruption')
        return original_read(descriptor, size)

    def deadline(*_):
        raise AssertionError((name, 'stream deadline'))
    previous_alarm = signal.signal(signal.SIGALRM, deadline)
    signal.alarm(10)
    subprocess.Popen, os.read = tracked_popen, checked_read
    scope['bytearray'] = ObservedBuffer
    completed = None
    try:
        try:
            completed = capture([sys.executable, '-c', stream_program, str(out),
                                 str(err), style, str(status)],
                                {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}, limit)
        except (OSError, KeyboardInterrupt) as error:
            if (fault == 'read' and not isinstance(error, OSError)) or (
                    fault == 'interrupt' and not isinstance(error, KeyboardInterrupt)) or not fault:
                raise
        else:
            assert not fault, (name, 'injected failure was ignored')
            assert completed.returncode == status
            assert completed.stdout == b'o' * min(out, limit + 1)
            assert completed.stderr == b'e' * min(err, 64*1024)
    finally:
        subprocess.Popen, os.read = original_popen, original_read
        scope.pop('bytearray')
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous_alarm)
        assert len(children) == 1
        child = children[0]
        assert child.returncode is not None and child.poll() is not None
        assert child.stdout.closed and child.stderr.closed
        for descriptor in owned_descriptors:
            try:
                os.fstat(descriptor)
            except OSError as error:
                assert error.errno == errno.EBADF
            else:
                raise AssertionError((name, 'pipe descriptor remains open'))
        try:
            os.waitpid(child.pid, os.WNOHANG)
        except ChildProcessError:
            pass
        else:
            raise AssertionError((name, 'child was not reaped'))
        assert len(buffers) == 2
        assert buffers[0].maximum <= limit + 1
        assert buffers[1].maximum <= 64*1024
    if report:
        record('P12-bounded-process', name, 'PASS')
    return completed


for name, out, err, limit, style, status, fault in (
    ('response-stdout-limit', 1024*1024, 0, 1024*1024, 'plain', 0, None),
    ('response-stdout-limit-plus-one', 1024*1024+1, 0, 1024*1024, 'plain', 0, None),
    ('git-path-stdout-limit', 2*1024*1024, 0, 2*1024*1024, 'plain', 0, None),
    ('git-path-stdout-limit-plus-one', 2*1024*1024+1, 0, 2*1024*1024, 'plain', 0, None),
    ('stderr-limit', 3, 64*1024, 1024*1024, 'plain', 0, None),
    ('stderr-limit-plus-one', 3, 64*1024+1, 1024*1024, 'plain', 0, None),
    ('long-stderr-before-stdout', 17, 4*64*1024, 1024*1024, 'before', 0, None),
    ('interleaved-pipe-pressure', 2*1024*1024+65536, 4*64*1024, 2*1024*1024, 'interleaved', 0, None),
    ('nonzero-exit-bounded-diagnostic', 11, 64*1024+1, 1024*1024, 'plain', 7, None),
    ('early-stdout-eof', 0, 64*1024+1, 1024*1024, 'early-eof', 0, None),
    ('injected-read-failure', 2*1024*1024, 0, 1024*1024, 'plain', 0, 'read'),
    ('injected-interruption', 2*1024*1024, 0, 1024*1024, 'plain', 0, 'interrupt'),
):
    finite_capture(name, out, err, limit, style, status, fault)

caller_arguments = SimpleNamespace(source_repository_id='fixture.target',
    source_git_dir=str(source_git), candidate_root=str(base_candidate),
    scratch_root=str(base_scratch))
execution = base_state / 'execution'
expected_materializer_command = [
    str(execution / 'adapters/local-git-materializer/v1/materialize.sh'),
    'materialize', str(input_path), 'fixture.target', str(source_git.resolve()),
    str(base_candidate.resolve()), str(base_scratch.resolve()),
    str(execution / '.dependencies/object-closure'), str(execution / '.dependencies/jq'),
]
for name, out, err, status in (
    ('materializer-caller-limit', 1024*1024, 0, 0),
    ('materializer-caller-overflow', 1024*1024+1, 0, 0),
    ('materializer-caller-stderr-discard', 17, 64*1024+1, 0),
    ('materializer-caller-nonzero', 0, 64*1024+1, 7),
):
    def checked_materializer(command_value, environment, limit):
        assert command_value == expected_materializer_command
        assert environment == {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}
        assert limit == 1024*1024
        return finite_capture(name, out, err, limit, status=status, report=False)
    scope['_capture_fixed_process'] = checked_materializer
    try:
        try:
            stdout = scope['capture_materializer'](caller_arguments, execution, input_path)
        except scope['ReplayError'] as error:
            assert out > 1024*1024 or status != 0
            if status:
                assert str(error) == 'materialization did not complete: ' + 'e' * (64*1024)
            else:
                assert str(error) == 'materializer response exceeds its size limit'
        else:
            assert out <= 1024*1024 and status == 0
            assert stdout == b'o' * out
    finally:
        scope['_capture_fixed_process'] = capture
    record('P06-stream-caller', name, 'PASS')

for name, mode, expected_status in (
    ('real-fixed-git-caller-reopen', 'git-observe', 0),
    ('keyed-fixed-git-overflow-preservation', 'git-overflow', 1),
    ('keyed-fixed-git-nonzero-preservation', 'git-nonzero', 1),
):
    root, state, candidate, scratch, supplied_input, supplied_key = case_directories(name)
    checked_command = root / 'checked-command.json'
    before = evidence_snapshot(state, candidate, scratch, supplied_input, supplied_key)
    invocation = command(state, candidate, scratch, supplied_input, supplied_key)
    completed = subprocess.run([sys.executable, loaded_wrapper, str(driver), mode,
                                str(checked_command), *invocation[2:]],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               stdin=subprocess.DEVNULL, timeout=20, check=False)
    assert completed.returncode == expected_status, (name, completed.stderr)
    assert b'Traceback' not in completed.stderr
    assert before == evidence_snapshot(state, candidate, scratch, supplied_input, supplied_key)
    assert json.loads(checked_command.read_bytes())[2:] == [
        'diff-tree', '--no-commit-id', '--name-only', '-r',
        base_state_value['identity']['source_commit_id'],
        base_state_value['materialization']['candidate_commit_id']]
    if expected_status:
        assert b'candidate changed-path evidence is unavailable' in completed.stderr
        assert completed.stdout == b''
    else:
        assert json.loads(completed.stdout)['response_utf8'] == base_state_value['receiver_result']['response_utf8']
    record('P12-fixed-git-caller', name, 'PASS')

capture_node = next(node for node in ast.parse(driver.read_bytes()).body
                    if isinstance(node, ast.FunctionDef) and node.name == '_capture_fixed_process')
assert not any(isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
               and node.func.attr in ('run', 'communicate') for node in ast.walk(capture_node))
record('P12-bounded-process', 'fixed-capture-has-no-unbounded-fallback', 'PASS')


def replace_cli(arguments, option, value):
    arguments[arguments.index(option) + 1] = str(value)


def append_owned(path):
    metadata = path.stat()
    path.chmod(0o600)
    path.write_bytes(path.read_bytes() + b'\n')
    path.chmod(stat.S_IMODE(metadata.st_mode))


def invoke_identity_case(group, name, expected_status, state_value=None,
                         input_bytes=None, key_bytes=None, frozen_bytes=None, journal_bytes=None,
                         execution_file=None, source_file=None, native_source=None,
                         driver_drift=False, options=(), audit=None):
    root, state, candidate, scratch, supplied_input, supplied_key = case_directories(name)
    if state_value is not None:
        (state / 'run.json').write_bytes(encoded(state_value))
    for path, data in ((supplied_input, input_bytes), (supplied_key, key_bytes),
                       (state / 'materialization-input.json', frozen_bytes),
                       (state / 'run.json', journal_bytes)):
        if data is not None:
            path.write_bytes(data)
    if execution_file:
        append_owned(state / 'execution' / execution_file)
    invocation = command(state, candidate, scratch, supplied_input, supplied_key)
    extra_roots = []
    wrapper_mode, wrapper_values = None, []
    control = root / 'outside-evidence-audit.json'
    if source_file:
        source_copy = root / 'source-copy'
        for relative in list(base_state_value['identity']['materializer_package']['files']) + ['delivery/v1/replay.py']:
            target = source_copy / relative
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            shutil.copy2(driver.parents[2] / relative, target)
        append_owned(source_copy / source_file)
        extra_roots.append(source_copy)
        wrapper_mode, wrapper_values = 'source-root', [str(source_copy)]
    if native_source:
        original = Path(jq_bin if native_source == 'jq' else closure_helper)
        target = root / ('actual-source-' + native_source)
        shutil.copy2(original, target)
        append_owned(target)
        extra_roots.append(target)
        replace_cli(invocation, '--jq-bin' if native_source == 'jq' else '--closure-helper', target)
    if driver_drift:
        wrapper_mode = 'driver-drift'
    for option, replacement in options:
        replace_cli(invocation, option, replacement)
    if audit:
        target_name, limit, count = audit
        target = {'supplied-input': supplied_input, 'frozen-input': state / 'materialization-input.json',
                  'key': supplied_key, 'v2-journal': state / 'run.json'}[target_name]
        wrapper_mode, wrapper_values = 'read-audit', [str(target), str(limit)]
    before = evidence_snapshot(state, candidate, scratch, supplied_input, supplied_key)
    before['actual_source_tools'] = [inventory(path) for path in extra_roots]
    if wrapper_mode:
        invocation = [sys.executable, loaded_wrapper, str(driver), wrapper_mode,
                      str(control), *wrapper_values, *invocation[2:]]
    completed = subprocess.run(invocation, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=20, check=False)
    after = evidence_snapshot(state, candidate, scratch, supplied_input, supplied_key)
    after['actual_source_tools'] = [inventory(path) for path in extra_roots]
    assert completed.returncode == expected_status, (group, name, completed.stderr, completed.stdout)
    assert b'Traceback' not in completed.stderr and before == after, (group, name, 'preservation')
    if expected_status:
        assert b'delivery_replay_materialization_result' not in completed.stdout
    else:
        assert json.loads(completed.stdout)['response_utf8'] == base_response_text
    if audit:
        observed = json.loads(control.read_bytes())
        assert observed['limit'] == limit and observed['file_bytes'] == count
        if count <= limit:
            assert observed['returned_bytes'] == count and 'refusal' not in observed
        else:
            assert observed['refusal'] == 'input exceeds its size limit'
            assert 'returned_bytes' not in observed
    if driver_drift:
        assert control.read_text().strip() == sha(driver.read_bytes() + b'\n')
        assert control.read_text().strip() != sha(driver.read_bytes())
    record(group, name, 'PASS')


def padded_json(value, count):
    raw = encoded(value)
    assert len(raw) <= count
    return raw + b' ' * (count - len(raw))


limits = {'supplied-input': 8*1024*1024, 'frozen-input': 8*1024*1024,
          'key': 4096, 'v2-journal-read': 8*1024*1024,
          'v1-journal-read': 65536, 'v2-journal-write': 8*1024*1024,
          'v1-journal-write': 65536, 'review-observation': 65536,
          'publisher-observation': 65536}
assert (scope['MAX_INPUT_BYTES'], scope['MAX_DELIVERY_KEY_BYTES'],
        scope['MAX_JOURNAL_V2_BYTES'], scope['MAX_OBSERVATION_BYTES'],
        scope['MAX_STAGE_RESULT_BYTES'], scope['MAX_RECEIPT_BYTES']) == (
            8*1024*1024, 4096, 8*1024*1024, 65536, 256*1024, 65536)
for boundary, limit in limits.items():
    for suffix, count in (('limit', limit), ('limit-plus-one', limit+1)):
        name = boundary + '-' + suffix
        boundary_root = case_root / name
        boundary_root.mkdir(mode=0o700)
        path = boundary_root / 'boundary.json'
        if 'journal-write' in boundary:
            version = 2 if boundary.startswith('v2') else 1
            value = {'schema_version': version, 'padding': ''}
            value['padding'] = 'x' * (count - len(encoded(value)))
            assert len(encoded(value)) == count
            path.write_bytes(b'prior journal\n')
        else:
            value = {'schema_version': 2 if boundary.startswith('v2') else 1}
            path.write_bytes(padded_json(value, count))
        before = inventory(boundary_root)
        try:
            if 'journal-write' in boundary:
                scope['write_journal'](path, value)
            elif 'journal-read' in boundary:
                assert scope['read_journal'](path) == value
            elif 'observation' in boundary:
                kind = 'delivery_replay_' + ('publisher' if boundary.startswith('publisher') else 'review') + '_observation'
                field = 'disposition' if boundary.startswith('publisher') else 'verdict'
                scope['observation'](path, kind,
                                     base_state_value['identity'],
                                     base_state_value['materialization']['candidate_commit_id'], field)
            else:
                assert scope['read_bytes'](path, limit) == path.read_bytes()
        except scope['ReplayError'] as error:
            if count <= limit:
                assert 'observation' in boundary and str(error) == 'offline observation is malformed'
            else:
                assert 'size limit' in str(error)
            assert before == inventory(boundary_root)
        else:
            assert count <= limit
            if 'journal-write' in boundary:
                assert path.read_bytes() == encoded(value)
            else:
                assert before == inventory(boundary_root)
        record('P06-nonstream', name, 'PASS')

for boundary, limit in (('supplied-input', 8*1024*1024), ('frozen-input', 8*1024*1024),
                         ('key', 4096), ('v2-journal', 8*1024*1024)):
    for suffix, count in (('limit', limit), ('limit-plus-one', limit+1)):
        values = {'audit': (boundary, limit, count)}
        status = 0 if count == limit and boundary in ('key', 'v2-journal') else 1
        if boundary == 'supplied-input': values['input_bytes'] = padded_json(base_input_value, count)
        elif boundary == 'frozen-input': values['frozen_bytes'] = padded_json(base_input_value, count)
        elif boundary == 'key': values['key_bytes'] = padded_json(base_key, count)
        else: values['journal_bytes'] = padded_json(base_state_value, count)
        invoke_identity_case('P06-file-caller', boundary+'-'+suffix, status, **values)

for boundary, limit in (('response-validation', 1024*1024), ('stage-extraction', 256*1024),
                         ('receipt-validation', 65536)):
    for suffix, count in (('limit', limit), ('limit-plus-one', limit+1)):
        response = copy.deepcopy(base_response)
        if boundary == 'stage-extraction':
            stage = {'padding': ''}
            stage['padding'] = 'x' * (count - len(encoded(stage)))
            response['stage_result'] = stage
            assert len(scope['jq_canonical_document'](execution, stage)) == count
        elif boundary == 'receipt-validation':
            response['payloads'][0]['data'] = padded_json({}, count).decode()
        else:
            response = {}
        raw = padded_json(response, count) if boundary == 'response-validation' else encoded(response)
        before = evidence_snapshot(base_state, base_candidate, base_scratch, input_path, key_path)
        try:
            scope['validate_materializer_response'](caller_arguments, execution, input_path,
                                                    base_state_value['identity'], raw)
        except scope['ReplayError'] as error:
            if count > limit:
                expected = {'response-validation': 'materializer response',
                            'stage-extraction': 'materializer stage result',
                            'receipt-validation': 'materializer receipt'}[boundary]
                assert str(error) == expected + ' exceeds its size limit'
            else:
                assert 'size limit' not in str(error)
        else:
            raise AssertionError((boundary, 'invalid large semantic shape accepted'))
        assert before == evidence_snapshot(base_state, base_candidate, base_scratch, input_path, key_path)
        record('P06-nonstream', boundary+'-'+suffix, 'PASS')


def refresh_run(state):
    saved = state['identity']
    saved['run_key'] = sha(encoded({key: value for key, value in saved.items()
        if key not in ('run_key', 'candidate_commit_id', 'candidate_tree_id')})[:-1])


def refresh_saved(state):
    saved = state['identity']
    package = saved['materializer_package']
    package['sha256'] = sha(encoded({'generation_id': package['generation_id'],
                                     'files': package['files']})[:-1])
    saved['materializer_sha256'] = package['files'][scope['PACKAGE_FILES'][0]]
    state['verification'] = {'id': saved['verifier']['id'], 'path': saved['verifier']['path'],
                             'sha256': saved['verifier']['expected_sha256']}
    refresh_run(state)


def saved_case(group, name, path, replacement, status):
    value = copy.deepcopy(base_state_value)
    asserted_sets((['identity', *path], replacement))(value)
    if path == ['materializer_sha256']:
        value['identity']['materializer_package']['files'][scope['PACKAGE_FILES'][0]] = replacement
    refresh_saved(value)
    if path == ['run_key']:
        value['identity']['run_key'] = replacement
    assert value_at(value, ['identity', *path]) == replacement
    invoke_identity_case(group, name, status, state_value=value)

for field in ('input_sha256', 'request_sha256', 'run_key', 'driver_sha256', 'materializer_sha256',
              'closure_helper_sha256', 'jq_sha256', 'source_repository_id', 'source_commit_id',
              'source_tree_id', 'source_hash_algorithm'):
    original = base_state_value['identity'][field]
    changed = {'source_repository_id': 'fixture.changed', 'source_hash_algorithm': 'sha256'}.get(field,
        ('0' if original[0] != '0' else '1') * len(original))
    for suffix, replacement, status in (('malformed', None, 1), ('changed', changed, 2)):
        saved_case('P07-saved-identity', field+'-'+suffix, [field], replacement, status)
for field, changed in (('id', 'delivery.other-verifier.v1'), ('path', 'other.txt'), ('expected_sha256', '0'*64)):
    for suffix, replacement, status in (('malformed', None, 1), ('changed', changed, 2)):
        saved_case('P07-saved-verifier', field+'-'+suffix, ['verifier',field], replacement, status)
package_paths = list(base_state_value['identity']['materializer_package']['files'])
for relative in package_paths:
    for suffix, replacement, status in (('malformed', None, 1), ('changed', '0'*64, 2)):
        saved_case('P07-saved-package-file', relative+'-'+suffix,
                   ['materializer_package','files',relative], replacement, status)
    invoke_identity_case('P07-actual-tool', 'current-source-'+relative, 2, source_file=relative)
    invoke_identity_case('P07-actual-tool', 'frozen-execution-'+relative, 2, execution_file=relative)
for name in ('generation-malformed','generation-changed','file-set-missing','file-set-extra','aggregate-corrupt'):
    value = copy.deepcopy(base_state_value)
    package = value['identity']['materializer_package']
    if name.startswith('generation'):
        generation = 'g-'+'0'*64 if name.endswith('changed') else 'bad'
        old_generation = package['generation_id']
        package['generation_id'] = generation
        package['files'] = {key.replace(old_generation,generation): digest for key,digest in package['files'].items()}
    elif name == 'file-set-missing': package['files'].pop(package_paths[-1])
    elif name == 'file-set-extra': package['files']['unaccepted-file'] = '0'*64
    refresh_saved(value)
    if name == 'aggregate-corrupt':
        package['sha256'] = '0'*64
        refresh_run(value)
    invoke_identity_case('P07-saved-package', name, 2 if name=='generation-changed' else 1, state_value=value)
for tool in ('jq','object-closure'):
    invoke_identity_case('P07-actual-tool', 'current-source-'+tool, 2, native_source=tool)
    invoke_identity_case('P07-actual-tool', 'frozen-execution-'+tool, 2, execution_file='.dependencies/'+tool)
invoke_identity_case('P07-actual-tool', 'loaded-driver-byte-drift', 2, driver_drift=True)
for option, malformed, changed in (('source-repository-id','bad value','fixture.changed'),
                                   ('verify-path','../bad','other.txt'), ('expected-sha256','bad','0'*64)):
    for suffix, replacement, status in (('malformed',malformed,1), ('changed',changed,2)):
        invoke_identity_case('P07-argument', option+'-'+suffix, status, options=[('--'+option,replacement)])


def replace_value(value, old, new):
    if value == old: return copy.deepcopy(new)
    if isinstance(value, dict):
        return {key: replace_value(item,old,new) for key,item in value.items()}
    if isinstance(value, list): return [replace_value(item,old,new) for item in value]
    return value


def refresh_input(value):
    paths = [['manifests',index] for index in range(len(value['manifests']))] + [
        ['profile'],['resolved_profile'],['stage_request']]
    for path in paths:
        pair = value_at(value,path)
        old = pair['sha256']
        raw = scope['jq_canonical_document'](execution,pair['content'])
        assert raw == encoded(pair['content'])
        value = replace_value(value,old,sha(raw))
    return value

def replace_package_binding(value, manifest_id, package):
    if isinstance(value, dict):
        if value.get('manifest_ref',{}).get('id') == manifest_id and 'package_ref' in value:
            value['package_ref'] = copy.deepcopy(package)
        if value.get('binding',{}).get('manifest_ref',{}).get('id') == manifest_id:
            value['package_source']['source'] = copy.deepcopy(package)
        for item in value.values(): replace_package_binding(item,manifest_id,package)
    elif isinstance(value, list):
        for item in value: replace_package_binding(item,manifest_id,package)

input_variants = []
for category, path in [('profile',['profile']),('resolved-profile',['resolved_profile']),('stage-request',['stage_request'])]:
    value = copy.deepcopy(base_input_value)
    old_id = value_at(value,path)['content']['id']
    input_variants.append((category,replace_value(value,old_id,old_id+'.changed')))
for index,pair in enumerate(base_input_value['manifests']):
    value = copy.deepcopy(base_input_value)
    old = value['manifests'][index]['content']['body']['package_ref']
    new = copy.deepcopy(old); new['object_id'] = '0'*len(old['object_id'])
    value['manifests'][index]['content']['body']['package_ref'] = new
    replace_package_binding(value,pair['content']['id'],new)
    input_variants.append(('manifest-'+pair['content']['id'],value))
for index,payload in enumerate(base_input_value['payloads']):
    value = copy.deepcopy(base_input_value)
    old_data = payload['data']
    if payload['input_id']=='input.materialize':
        contract = json.loads(old_data); contract['max_patch_bytes'] -= 1
        new_data = encoded(contract).decode()
    else: new_data = old_data.replace('+gamma','+delta')
    assert old_data != new_data
    value = replace_value(value,old_data,new_data)
    value = replace_value(value,sha(old_data.encode()),sha(new_data.encode()))
    input_variants.append(('payload-'+payload['input_id'],value))
for field,replacement in [('attempt_id','attempt.changed'),('result_id','result.changed'),
                          ('started_at','2026-08-30T00:00:00Z'),('finished_at','2026-08-30T00:00:03Z'),
                          ('recorded_at','2026-08-30T00:00:04Z')]:
    value = copy.deepcopy(base_input_value)
    asserted_sets((['attempt',field],replacement))(value)
    input_variants.append(('attempt-id' if field=='attempt_id' else 'attempt-'+field.replace('_','-'),value))
for name,value in input_variants:
    invoke_identity_case('P07-frozen-input', name+'-raw-drift', 1, frozen_bytes=encoded(value))
    value = refresh_input(value)
    supplied = copy.deepcopy(base_key); supplied['request_sha256'] = value['stage_request']['sha256']
    assert encoded(value) != encoded(base_input_value)
    invoke_identity_case('P07-supplied-input', name+'-valid-drift', 2,
                         input_bytes=encoded(value), key_bytes=encoded(supplied))


def checked_process(invocation, status=0):
    result = subprocess.run(invocation, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=20, check=False)
    if status is not None:
        assert result.returncode == status and b'Traceback' not in result.stderr, (
            invocation, result.returncode, result.stdout, result.stderr)
    return result


def without_key(invocation):
    values = invocation.copy()
    offset = values.index('--delivery-key')
    del values[offset:offset+2]
    return values


def retained_operation(name, invocation, roots, status=0, response=None, unavailable=None, extra_roots=()):
    prior_journal = json.loads((roots[0] / 'run.json').read_bytes()) if response is not None else None
    expected_key = json.loads(roots[4].read_bytes()) if response is not None else None
    if response is not None:
        assert prior_journal['identity']['delivery_key'] == expected_key
    before = evidence_snapshot(*roots)
    before["extra_roots"] = [inventory(path) for path in extra_roots]
    result = checked_process(invocation, None)
    after = evidence_snapshot(*roots)
    after["extra_roots"] = [inventory(path) for path in extra_roots]
    print('cp4b-preservation ' + json.dumps({'name': name, 'before': before, 'after': after, 'actual_exit': result.returncode},
                                         sort_keys=True, separators=(',', ':')))
    assert result.returncode == status and b'Traceback' not in result.stderr, (
        name, result.returncode, result.stdout, result.stderr)
    assert before == after, (name, 'complete evidence changed')
    if response is not None:
        value = json.loads(result.stdout)
        retained = value['response_utf8'] if '--read-materialization-result' in invocation else (
            value['state']['receiver_result']['response_utf8'])
        assert retained.encode() == response, (name, 'original response bytes')
        if '--read-materialization-result' in invocation:
            assert_read_envelope(value, response, expected_key, prior_journal['identity']['run_key'])
    elif unavailable:
        value = json.loads(result.stdout)
        assert_read_envelope(value, unavailable=unavailable)
    else:
        assert b'delivery_replay_materialization_result' not in result.stdout
    return result


def original_oracle(name, response):
    print('cp4b-original ' + json.dumps({
        'name': name, 'response_utf8': response.decode(),
        'receipt': json.loads(response)['payloads'][0]}, sort_keys=True))


def fixed_git(repository, *arguments, data=None, raw=False):
    invocation = ['/usr/bin/git', '-c', 'core.hooksPath=/dev/null',
                  f'--git-dir={repository}', *arguments]
    fixture_environment = dict(scope['GIT_ENVIRONMENT'], GIT_AUTHOR_NAME='fixture',
        GIT_AUTHOR_EMAIL='fixture@example.invalid', GIT_COMMITTER_NAME='fixture',
        GIT_COMMITTER_EMAIL='fixture@example.invalid', GIT_AUTHOR_DATE='2000-01-01T00:00:00Z',
        GIT_COMMITTER_DATE='2000-01-01T00:00:00Z')
    result = subprocess.run(invocation, input=data, env=fixture_environment,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    assert result.returncode == 0, (invocation, result.stderr)
    return result.stdout if raw else result.stdout.strip().decode()


for algorithm in ('sha1', 'sha256'):
    for ancestry in ('root', 'ancestor'):
        for outcome in ('changed', 'no-change'):
            name = f'{algorithm}-{ancestry}-{outcome}'
            root = case_root / ('real-' + name)
            root.mkdir(mode=0o700)
            repository = root / 'source.git'
            checked_process(['/usr/bin/git', 'init', '--bare', '--object-format='+algorithm,
                             str(repository)])
            blob = fixed_git(repository, 'hash-object', '-w', '--stdin', data=b'alpha\nbeta\n')
            tree = fixed_git(repository, 'mktree', data=f'100644 blob {blob}\tsource.txt\n'.encode())
            parent = fixed_git(repository, 'commit-tree', tree, data=b'root\n')
            commit = parent if ancestry == 'root' else fixed_git(
                repository, 'commit-tree', tree, '-p', parent, data=b'ancestor source\n')
            fixed_git(repository, 'update-ref', 'refs/heads/main', commit)
            assert fixed_git(repository,'rev-parse','--show-object-format') == algorithm
            assert fixed_git(repository,'rev-parse',commit+'^{tree}') == tree
            assert fixed_git(repository,'rev-list','--parents','-n','1',commit) == (
                commit if ancestry=='root' else commit+' '+parent)
            fixture = root / 'fixture'
            checked_process([str(driver.parents[2] / 'scripts/test/local-git-materializer-fixtures.sh'),
                             'build', str(fixture), jq_bin, algorithm, commit, tree])
            supplied_input, supplied_key = root / 'input.json', root / 'key.json'
            value = json.loads((fixture / 'input.json').read_bytes())
            if outcome == 'no-change':
                patch = next(item['data'] for item in value['payloads']
                             if item['input_id'] == 'input.producer-patch')
                value = replace_value(value, patch, '')
                value = replace_value(value, sha(patch.encode()), sha(b''))
                value = refresh_input(value)
            supplied_input.write_bytes(encoded(value))
            supplied = copy.deepcopy(base_key)
            supplied['request_sha256'] = value['stage_request']['sha256']
            supplied_key.write_bytes(encoded(supplied))
            state, candidate, scratch = [root / item for item in ('state', 'candidate', 'scratch')]
            for path in (state, candidate, scratch): path.mkdir(mode=0o700)
            invocation = command(state, candidate, scratch, supplied_input, supplied_key)
            invocation.remove('--read-materialization-result')
            replace_cli(invocation, '--source-git-dir', repository)
            wanted_blob = b'alpha\nbeta\ngamma\n' if outcome == 'changed' else b'alpha\nbeta\n'
            replace_cli(invocation, '--expected-sha256', sha(wanted_blob))
            control = root / 'outside-evidence-invocations'
            counted = [sys.executable, loaded_wrapper, str(driver), 'count', str(control),
                       *invocation[2:]]
            checked_process(counted)
            original = Path(str(control)+'.response').read_bytes()
            response = json.loads(original)
            receipt_payload = response['payloads'][0]
            receipt = json.loads(receipt_payload['data'])
            assert original.endswith(b'\n') and receipt_payload['data'].endswith('\n')
            assert receipt_payload['sha256'] == sha(receipt_payload['data'].encode())
            assert receipt['source'] == {'repository_id':'fixture.target', 'hash_algorithm':algorithm,
                                         'commit_id':commit, 'tree_id':tree}
            assert fixed_git(candidate/'repository.git','rev-parse','--show-object-format') == algorithm
            actual_commit = fixed_git(candidate / 'repository.git', 'rev-parse', 'refs/heads/candidate')
            actual_tree = fixed_git(candidate / 'repository.git', 'rev-parse', actual_commit+'^{tree}')
            assert receipt['candidate'] == {'repository_kind':'bare', 'hash_algorithm':algorithm,
                'commit_id':actual_commit, 'tree_id':actual_tree, 'parent_commit_id':commit}
            assert fixed_git(candidate / 'repository.git', 'show', actual_tree+':source.txt', raw=True) == wanted_blob
            if outcome == 'changed':
                assert actual_commit != commit and actual_tree != tree
                assert fixed_git(candidate / 'repository.git', 'rev-parse', actual_commit+'^') == commit
            else:
                assert actual_commit == commit and actual_tree == tree
            assert receipt['changed_paths'] == {'count':int(outcome=='changed'),
                'sha256':sha(encoded(['source.txt'] if outcome=='changed' else []))}
            assert response['stage_result']['body']['outcome']['value'] == outcome
            roots = (state, candidate, scratch, supplied_input, supplied_key)
            read = counted + ['--read-materialization-result']
            first_read = retained_operation(name+'-read', read, roots, response=original)
            retrieved = json.loads(first_read.stdout)
            stage_bytes = (
                subprocess.run([jq_bin,'-S','-c','.stage_result'], input=original,
                               stdout=subprocess.PIPE, check=True).stdout)
            assert retrieved['stage_result'] == {'content':response['stage_result'],'sha256':sha(stage_bytes)}
            assert retrieved['receipt'] == receipt_payload
            original_oracle(name, original)
            record('P01-real-variants', name, 'PASS')
            repeated = retained_operation(name+'-repeat-read', read, roots, response=original)
            assert repeated.stdout == first_read.stdout
            retained_operation(name+'-redelivery', counted, roots, response=original)
            assert control.read_bytes() == b'invoked\n'
            assert Path(str(control)+'.response').read_bytes() == original
            record('P02-retention', name+'-read-repeat-redelivery-one-invocation', 'PASS')

name = 'synchronized-concurrent-original-retention'
root = case_root / name
root.mkdir(mode=0o700)
state,candidate,scratch = [root/item for item in ('state','candidate','scratch')]
for path in (state,candidate,scratch): path.mkdir(mode=0o700)
roots = (state,candidate,scratch,input_path,key_path)
invocation = command(*roots)
invocation.remove('--read-materialization-result')
control = root/'outside-evidence-invocations'
counted = [sys.executable,loaded_wrapper,str(driver),'count-gate',str(control),*invocation[2:]]
children = []
try:
    children.append(subprocess.Popen(counted,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE))
    deadline = time.monotonic()+20
    while not Path(str(control)+'.ready').exists():
        assert children[0].poll() is None and time.monotonic()<deadline
        time.sleep(0.02)
    children.append(subprocess.Popen(counted,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE))
    while len(list(root.glob('outside-evidence-invocations.started.*'))) != 2:
        assert children[1].poll() is None and time.monotonic()<deadline
        time.sleep(0.02)
    Path(str(control)+'.release').write_text('release\n')
    outputs = [child.communicate(timeout=20) for child in children]
    assert all(child.returncode==0 for child in children), outputs
finally:
    for child in children:
        if child.poll() is None: child.kill()
        child.wait()
        child.stdout.close()
        child.stderr.close()
original = Path(str(control)+'.response').read_bytes()
original_oracle(name, original)
assert control.read_bytes() == b'invoked\n'
assert all(json.loads(out)['state']['receiver_result']['response_utf8'].encode()==original for out,err in outputs)
retained_operation(name+'-read',counted+['--read-materialization-result'],roots,response=original)
retained_operation(name+'-redelivery',counted,roots,response=original)
assert control.read_bytes() == b'invoked\n'
record('P02-concurrent',name,'PASS')

name = 'actual-fixed-verifier-failure'
root = case_root / name
root.mkdir(mode=0o700)
state, candidate, scratch = [root / item for item in ('state','candidate','scratch')]
for path in (state,candidate,scratch): path.mkdir(mode=0o700)
invocation = command(state,candidate,scratch,input_path,key_path)
invocation.remove('--read-materialization-result')
replace_cli(invocation,'--expected-sha256','0'*64)
control = root / 'outside-evidence-invocations'
counted = [sys.executable,loaded_wrapper,str(driver),'count',str(control),*invocation[2:]]
failed = checked_process(counted,1)
assert json.loads(failed.stdout)['state']['reason'] == 'fixed verifier digest mismatch'
assert json.loads((state/'run.json').read_bytes())['phase'] == 'failed'
original = Path(str(control)+'.response').read_bytes()
original_oracle(name, original)
roots = (state,candidate,scratch,input_path,key_path)
first = retained_operation(name+'-read',counted+['--read-materialization-result'],roots,response=original)
second = retained_operation(name+'-repeat-read',counted+['--read-materialization-result'],roots,response=original)
assert first.stdout == second.stdout and control.read_bytes() == b'invoked\n'
record('P02-verifier-failure',name+'-read-original-without-verifying','PASS')

name = 'actual-v1-unavailable-preserved'
_,state,candidate,scratch,supplied_input,supplied_key = case_directories(name)
shutil.rmtree(state)
shutil.copytree(case_root.parent/'legacy-state',state,symlinks=True)
roots = (state,candidate,scratch,supplied_input,supplied_key)
retained_operation(name,without_key(command(*roots)),roots,3,
                   unavailable='replay.legacy-result-unavailable')
assert json.loads((state/'run.json').read_bytes())['schema_version'] == 1
record('P13-format',name,'PASS')

for phase in ('pending', 'stored'):
    for mode in ('read', 'delivery'):
        name = f'v2-{phase}-no-key-{mode}'
        _, state, candidate, scratch, supplied_input, supplied_key = case_directories(name)
        if phase == 'pending':
            value = pending_state()
            (state / 'run.json').write_bytes(encoded(value))
        invocation = without_key(command(state,candidate,scratch,supplied_input,supplied_key))
        if mode == 'delivery': invocation.remove('--read-materialization-result')
        retained_operation(name, invocation, (state,candidate,scratch,supplied_input,supplied_key), 2)
        record('P13-format', name, 'PASS')

for mode in ('read', 'delivery'):
    name = 'v1-retrofit-key-'+mode
    _, state,candidate,scratch,supplied_input,supplied_key = case_directories(name)
    shutil.rmtree(state)
    shutil.copytree(case_root.parent/'legacy-state',state,symlinks=True)
    invocation = command(state,candidate,scratch,supplied_input,supplied_key)
    if mode == 'delivery': invocation.remove('--read-materialization-result')
    retained_operation(name, invocation, (state,candidate,scratch,supplied_input,supplied_key), 2)
    assert json.loads((state/'run.json').read_bytes())['schema_version'] == 1
    record('P13-format', name, 'PASS')

for target_name in ('state','journal','lock','bundle','frozen-input','key','input'):
    kinds = ('missing','symlink','directory','fifo') if target_name not in ('state','bundle') else ('missing',)
    for kind in kinds:
        name = target_name+'-'+kind+'-read'
        _, state,candidate,scratch,supplied_input,supplied_key = case_directories(name)
        target = {'state':state,'journal':state/'run.json','lock':state/'replay.lock','bundle':state/'execution',
                  'frozen-input':state/'materialization-input.json','key':supplied_key,
                  'input':supplied_input}[target_name]
        original_target_bytes = target.read_bytes() if target.is_file() else b''
        if target.is_dir(): shutil.rmtree(target)
        else: target.unlink()
        extra_roots = []
        if kind == 'symlink':
            referent = target.parent / ('outside-'+target.name)
            referent.write_bytes(original_target_bytes)
            target.symlink_to(referent)
            extra_roots.append(referent)
        elif kind == 'directory': target.mkdir(mode=0o700)
        elif kind == 'fifo': os.mkfifo(target, mode=0o600)
        roots = (state,candidate,scratch,supplied_input,supplied_key)
        retained_operation(name, command(*roots), roots, 1, extra_roots=extra_roots)
        record('P13-filesystem', name, 'PASS')

for option in ('--review-observation','--publisher-observation'):
    name = option[2:]+'-refused-read'
    _, state,candidate,scratch,supplied_input,supplied_key = case_directories(name)
    roots = (state,candidate,scratch,supplied_input,supplied_key)
    retained_operation(name, command(*roots)+[option,str(supplied_key)], roots, 1)
    record('P13-observation', name, 'PASS')

for name, operation in (
    ('wrong-result-request-ref', mutate(['body','request_ref','id'],'request.other')),
    ('wrong-result-profile-ref', mutate(['body','resolved_profile_ref','id'],'profile.other')),
    ('wrong-result-digest', None),
    ('rehashed-attempt-mismatch', mutate(['body','attempt_number'],3)),
):
    snapshot = json.loads((case_root.parent / 'scanner-snapshot.json').read_bytes())
    pair = snapshot['body']['items'][0]['latest_result']['value']
    if operation:
        operation(pair['content'])
        pair['sha256'] = sha(subprocess.run([jq_bin,'-S','-c','.'],input=encoded(pair['content']),
                                           stdout=subprocess.PIPE,check=True).stdout)
    else: pair['sha256'] = '0'*64
    path = case_root / ('scanner-'+name+'.json')
    path.write_bytes(encoded(snapshot))
    before = inventory(path)
    result = checked_process([str(driver.parents[2]/'orchestrator/v1/scan-state.sh'),
                              'scan','fixture.target',base_state_value['identity']['source_commit_id'],
                              str(path)],1)
    assert before == inventory(path) and b'scanner.stage-completed' not in result.stdout
    record('P14-real-scanner', name, 'PASS')

import atexit
owned_lifecycle_processes = []

def cleanup_lifecycle_processes():
    for process in owned_lifecycle_processes:
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=10)
        if process.stdout is not None:
            process.stdout.close()
        process.stderr.close()

atexit.register(cleanup_lifecycle_processes)


def lifecycle_case(name, point):
    root, *roots = case_directories('cp4c-' + name, pending=True)
    (roots[0] / 'run.json').write_bytes(encoded(pending_state()))
    if point == 'pre-effect':
        (roots[0] / 'run.json').unlink()
        (roots[0] / 'materialization-input.json').unlink()
    read = command(*roots)
    delivery = read[:-1]
    control, ready, release = [root / item for item in ('oracle', 'ready', 'release')]
    invocation = [sys.executable, loaded_wrapper, str(driver), 'lifecycle', str(control),
                  point, str(ready), str(release), *delivery[2:]]
    process = subprocess.Popen(invocation, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    owned_lifecycle_processes.append(process)
    try:
        deadline = time.monotonic() + 20
        while not ready.exists():
            if process.poll() is not None:
                stdout, stderr = process.communicate()
                raise AssertionError((name, 'gate not reached', process.returncode, stdout, stderr))
            if time.monotonic() >= deadline:
                raise AssertionError((name, 'ready watchdog'))
            time.sleep(0.02)
        assert process.poll() is None
        initial_calls = control.read_bytes() if control.exists() else None
        assert initial_calls == (None if point == 'pre-effect' else b'invoked\n')
        os.set_blocking(process.stdout.fileno(), False)
        try:
            outward = os.read(process.stdout.fileno(), 1)
        except BlockingIOError:
            outward = b''
        assert outward == b'', (name, 'outward success before release')
        os.set_blocking(process.stdout.fileno(), True)
        before = evidence_snapshot(*roots)
        oracle = Path(str(control) + '.response')
        response = oracle.read_bytes() if oracle.exists() else None
        if point != 'pre-effect':
            assert response and json.loads(response)['stage_result']
            original_oracle('cp4c-' + name, response)
        print('cp4c-pause ' + json.dumps({'name': name, 'point': point, 'snapshot': before,
                                        'outward_stdout_bytes': 0,
                                        'initial_calls_utf8': initial_calls.decode() if initial_calls else None}, sort_keys=True))
        return root, roots, read, delivery, control, release, process, before, response
    except BaseException:
        process.kill() if process.poll() is None else None
        process.communicate(timeout=10)
        process.stdout.close(); process.stderr.close()
        owned_lifecycle_processes.remove(process)
        raise


def finish_owned(process, name, status=None, kill=False):
    try:
        if kill:
            process.kill()
        stdout, stderr = process.communicate(timeout=20)
        print('cp4c-process ' + json.dumps({'name': name, 'pid': process.pid,
            'actual_exit': process.returncode, 'stdout_utf8': (stdout or b'').decode(),
            'stderr_utf8': stderr.decode(), 'reaped': process.poll() is not None}, sort_keys=True))
        if status is not None:
            assert process.returncode == status, (name, process.returncode, stdout, stderr)
        if kill:
            assert stdout == b''
        return stdout or b'', stderr
    finally:
        if process.poll() is None:
            process.kill(); process.wait(timeout=10)
        if process.stdout is not None:
            process.stdout.close()
        process.stderr.close()
        owned_lifecycle_processes.remove(process)


def recovery_command(invocation, control):
    if invocation[1] == loaded_wrapper:
        assert invocation[3:5] == ['count', str(control)]
        return invocation
    assert invocation[1] == str(driver)
    return [sys.executable, loaded_wrapper, str(driver), 'count', str(control), *invocation[2:]]


def counter_bytes(control):
    return control.read_bytes() if control.exists() else None


def unchanged_counter(name, control, before):
    after = counter_bytes(control)
    print('cp4c-counter ' + json.dumps({'name': name, 'before_utf8': before.decode() if before else None,
                                       'after_utf8': after.decode() if after else None}, sort_keys=True))
    assert before in (None, b'invoked\n') and after == before, (name, 'capture/reconciliation on recovery')


def recovery_operation(name, invocation, roots, control, *values, **keywords):
    before = counter_bytes(control)
    result = retained_operation(name, recovery_command(invocation, control), roots, *values, **keywords)
    unchanged_counter(name, control, before)
    return result


def recovery_process(name, invocation, control, status):
    before = counter_bytes(control)
    result = checked_process(recovery_command(invocation, control), status)
    unchanged_counter(name, control, before)
    return result


for evidence in ('retained-candidate', 'empty-pre-effect'):
    name = 'dangling-journal-' + evidence
    root, state, candidate, scratch, supplied_input, supplied_key = case_directories(
        name, pending=evidence == 'empty-pre-effect')
    roots = (state, candidate, scratch, supplied_input, supplied_key)
    assert (state / 'execution').is_dir() and (state / 'replay.lock').is_file()
    assert bool(list(candidate.iterdir())) == (evidence == 'retained-candidate')
    assert not list(scratch.iterdir())
    journal = state / 'run.json'
    journal.unlink()
    referent = root / 'missing-journal-referent.json'
    link_text = '../missing-journal-referent.json'
    journal.symlink_to(link_text)
    assert os.path.lexists(journal) and not journal.exists() and not os.path.lexists(referent)
    control = root / 'outside-evidence-invocations'
    read = command(*roots)
    delivery = read.copy()
    delivery.remove('--read-materialization-result')
    for index in range(2):
        for operation, invocation in [('read', read), ('delivery', delivery)]:
            case = name + '-' + operation + '-' + str(index)
            result = recovery_operation(case, invocation, roots, control, 1, extra_roots=[referent])
            assert result.stdout == b'' and b'input is not readable' in result.stderr, (
                case, result.returncode, result.stdout, result.stderr)
            assert journal.is_symlink() and os.readlink(journal) == link_text
            assert not os.path.lexists(referent) and not control.exists()
            assert not Path(str(control) + '.response').exists()
            record('P13-dangling-journal', case, 'PASS')


def repeated_stored(name, read, delivery, roots, response, control):
    previous = None
    for index in range(2):
        result = recovery_operation(name + '-read-' + str(index), read, roots, control, response=response)
        assert previous is None or result.stdout == previous
        previous = result.stdout
        record('P10/P11-stored-reopen', name + '-read-' + str(index), 'PASS')
    before = evidence_snapshot(*roots)
    journal = roots[0] / 'run.json'
    prior_bytes = journal.read_bytes()
    prior_journal = json.loads(prior_bytes)
    expected_journal = copy.deepcopy(prior_journal)
    if prior_journal['phase'] == 'verifying':
        verifier = prior_journal['identity']['verifier']
        expected_journal['phase'] = 'review-wait'
        expected_journal['verification'] = {'id': verifier['id'], 'path': verifier['path'],
                                             'sha256': verifier['expected_sha256']}
        expected_bytes = encoded(expected_journal)
    else:
        assert prior_journal['phase'] == 'review-wait'
        expected_bytes = prior_bytes
    expected_snapshot = copy.deepcopy(before)
    journal_entries = [item for item in expected_snapshot['state'] if item['path'] == 'run.json']
    assert len(journal_entries) == 1
    assert journal_entries[0]['type'] == 'file' and journal_entries[0]['mode'] == 0o600
    journal_entries[0].update(bytes=len(expected_bytes), sha256=sha(expected_bytes))
    first_delivery = recovery_process(name + '-resume', delivery, control, 0)
    returned_journal = json.loads(first_delivery.stdout)['state']
    assert encoded(returned_journal) == encoded(expected_journal)
    assert returned_journal['receiver_result']['response_utf8'].encode() == response
    after = evidence_snapshot(*roots)
    after_bytes = journal.read_bytes()
    print('cp4c-resume ' + json.dumps({'name': name, 'before': before, 'after': after,
        'prior_journal_utf8': prior_bytes.decode(), 'expected_journal_utf8': expected_bytes.decode(),
        'after_journal_utf8': after_bytes.decode()}, sort_keys=True))
    assert after_bytes == expected_bytes and json.loads(after_bytes) == expected_journal
    assert after == expected_snapshot, (name, 'journal or other evidence changed beyond exact workflow delta')
    record('P10/P11-stored-redelivery', name + '-resume-original-response', 'PASS')
    for index in range(2):
        recovery_operation(name + '-delivery-' + str(index), delivery, roots, control, response=response)
        record('P10/P11-stored-redelivery', name + '-delivery-' + str(index), 'PASS')


values = lifecycle_case('empty-pending-restart', 'pre-effect')
root, roots, read, delivery, control, release, process, before, response = values
assert response is None and not control.exists()
assert json.loads((roots[0] / 'run.json').read_bytes()) == pending_state()
assert not list(roots[1].iterdir())
assert not list(roots[2].iterdir())
finish_owned(process, 'empty-pending-pre-effect-crash', -signal.SIGKILL, kill=True)
assert before == evidence_snapshot(*roots) and not control.exists()
recovery_operation('empty-pending-after-pre-effect-crash', read, roots, control,
                   3, unavailable='replay.materialization-result-missing')
record('P09-empty-restart', 'actual-pre-effect-crash-pending-preserved', 'PASS')
counted = [sys.executable, loaded_wrapper, str(driver), 'count', str(control), *delivery[2:]]
result = checked_process(counted, 0)
stdout, stderr = result.stdout, result.stderr
response = Path(str(control) + '.response').read_bytes()
original_oracle('cp4c-empty-pending-restart', response)
assert json.loads(stdout)['state']['receiver_result']['response_utf8'].encode() == response
assert control.read_text() == 'invoked\n'
record('P09-empty-restart', 'same-pending-first-effect', 'PASS')
counted = [sys.executable, loaded_wrapper, str(driver), 'count', str(control), *delivery[2:]]
for index in range(2):
    recovery_operation('empty-pending-repeat-' + str(index), counted, roots, control, response=response)
    assert control.read_text() == 'invoked\n'
    record('P09-empty-restart', 'materialized-once-' + str(index), 'PASS')
repeated_stored('empty-pending-restart', read, delivery, roots, response, control)

for variant in ('partial-candidate', 'partial-scratch', 'linked-candidate', 'complete-candidate'):
    root, *roots = case_directories('cp4c-' + variant, pending=variant != 'complete-candidate')
    (roots[0] / 'run.json').write_bytes(encoded(pending_state()))
    if variant == 'partial-candidate':
        (roots[1] / 'partial').write_bytes(b'partial candidate\x00')
    elif variant == 'partial-scratch':
        (roots[2] / 'partial').write_bytes(b'partial scratch\x00')
    elif variant == 'linked-candidate':
        (roots[1] / 'link').symlink_to(roots[4])
    read = command(*roots); delivery = read[:-1]
    control = root / 'count'
    counted = [sys.executable, loaded_wrapper, str(driver), 'count', str(control), *delivery[2:]]
    for index in range(2):
        for operation, invocation in [('read', read), ('delivery', counted)]:
            recovery_operation(variant + '-' + operation + '-' + str(index), invocation, roots, control,
                               3, unavailable='replay.materialization-result-missing')
            assert not control.exists()
            record('P09-partial-effect', variant + '-' + operation + '-' + str(index), 'PASS')

root, *roots = case_directories('cp4c-damaged-stored')
value = copy.deepcopy(base_state_value)
value['receiver_result']['response_sha256'] = '0' * 64
(roots[0] / 'run.json').write_bytes(encoded(value))
read = command(*roots); control = root / 'count'
counted = [sys.executable, loaded_wrapper, str(driver), 'count', str(control), *read[2:-1]]
for index in range(2):
    for operation, invocation in [('read', read), ('delivery', counted)]:
        recovery_operation('damaged-stored-' + operation + '-' + str(index), invocation, roots, control, 1)
        assert not control.exists()
        record('P09-damaged-stored', operation + '-' + str(index), 'PASS')

root, *roots = case_directories('cp4c-fresh-populated-candidate')
(roots[0] / 'run.json').unlink()
(roots[0] / 'materialization-input.json').unlink()
read = command(*roots); delivery = read[:-1]
candidate_before, scratch_before = inventory(roots[1]), inventory(roots[2])
control = root / 'count'
result = checked_process(recovery_command(delivery, control), 1)
assert counter_bytes(control) == b'invoked\n'
assert inventory(roots[1]) == candidate_before and inventory(roots[2]) == scratch_before
assert json.loads((roots[0] / 'run.json').read_bytes())['receiver_result']['status'] == 'pending'
assert b'delivery_replay_materialization_result' not in result.stdout
record('P09-fresh-candidate', 'cannot-adopt-populated-root', 'PASS')
for index in range(2):
    recovery_operation('fresh-populated-read-' + str(index), read, roots, control,
                       3, unavailable='replay.materialization-result-missing')
    recovery_operation('fresh-populated-delivery-' + str(index), delivery, roots, control,
                       3, unavailable='replay.materialization-result-missing')
    record('P09-fresh-candidate', 'preserved-reopen-' + str(index), 'PASS')

for point in ('before', 'after'):
    name = 'sigkill-' + point
    root, roots, read, delivery, control, release, process, before, response = lifecycle_case(name, point)
    finish_owned(process, name, -signal.SIGKILL, kill=True)
    assert before == evidence_snapshot(*roots)
    record('P10-SIGKILL', point + '-exact-pause-preservation', 'PASS')
    if point == 'after':
        repeated_stored(name, read, delivery, roots, response, control)
    else:
        for index in range(2):
            for operation, invocation in [('read', read), ('delivery', delivery)]:
                recovery_operation(name + '-' + operation + '-' + str(index), invocation, roots, control,
                                   3, unavailable='replay.materialization-result-missing')
                record('P10-missing-reopen', operation + '-' + str(index), 'PASS')
    assert control.read_text() == 'invoked\n'

for fault in ('write', 'flush', 'file-fsync', 'rename', 'directory-fsync'):
    name = 'publication-' + fault
    root, roots, read, delivery, control, release, process, before, response = lifecycle_case(name, 'fault-' + fault)
    assert json.loads((roots[0] / 'run.json').read_bytes())['receiver_result']['status'] == 'pending'
    release.write_text('release\n')
    stdout, stderr = finish_owned(process, name, 1)
    assert not stdout and b'injected stored publication' in stderr and b'Traceback' not in stderr
    assert Path(str(control) + '.fault').read_text() == fault + '\n'
    after = evidence_snapshot(*roots)
    print('cp4c-publication ' + json.dumps({'name': name, 'before': before, 'after': after,
                                         'renamed': fault == 'directory-fsync'}, sort_keys=True))
    if fault == 'directory-fsync':
        prior, present = copy.deepcopy(before), copy.deepcopy(after)
        for snapshot in (prior, present):
            snapshot['state'] = [item for item in snapshot['state'] if item['path'] != 'run.json']
        assert prior == present, (name, 'evidence outside replaced journal changed')
        repeated_stored(name, read, delivery, roots, response, control)
    else:
        assert before == after, (name, 'prior usable pending evidence changed')
        for index in range(2):
            for operation, invocation in [('read', read), ('delivery', delivery)]:
                recovery_operation(name + '-' + operation + '-' + str(index), invocation, roots, control,
                                   3, unavailable='replay.materialization-result-missing')
                record('P11-pre-rename', fault + '-' + operation + '-' + str(index), 'PASS')
    assert control.read_text() == 'invoked\n'
    record('P11-atomic-publication', fault + '-no-outward-success', 'PASS')

name = 'broken-reply'
root, roots, read, delivery, control, release, process, before, response = lifecycle_case(name, 'reply')
process.stdout.close(); process.stdout = None
release.write_text('release\n')
stdout, stderr = finish_owned(process, name)
assert process.returncode != 0 and not stdout
assert before == evidence_snapshot(*roots)
record('P11-outward-pipe', 'failed-reply-retains-publication', 'PASS')
repeated_stored(name, read, delivery, roots, response, control)

for received in (signal.SIGINT, signal.SIGTERM):
    name = 'keyed-' + signal.Signals(received).name
    root, roots, read, delivery, control, release, process, before, response = lifecycle_case(name, 'before')
    process.send_signal(received)
    release.write_text('release\n')
    stdout, stderr = finish_owned(process, name, 75)
    assert b'Traceback' not in stderr
    assert json.loads(stdout)['state']['receiver_result']['response_utf8'].encode() == response
    assert control.read_text() == 'invoked\n'
    record('P11-keyed-interruption', signal.Signals(received).name + '-exit75', 'PASS')
    repeated_stored(name, read, delivery, roots, response, control)

for fault, diagnostic in [('malformed', b'input is not JSON'),
                          ('overflow', b'materializer response exceeds its size limit')]:
    name = 'capture-' + fault
    root, roots, read, delivery, control, release, process, before, response = lifecycle_case(name, 'output-' + fault)
    prior = (roots[0] / 'run.json').read_bytes()
    assert json.loads(prior) == pending_state() and inventory(roots[1])
    actual = json.loads(response)
    receipt = json.loads(actual['payloads'][0]['data'])
    candidate = roots[1] / 'repository.git'
    commit = fixed_git(candidate, 'rev-parse', 'refs/heads/candidate')
    assert receipt['candidate']['commit_id'] == commit
    assert receipt['candidate']['tree_id'] == fixed_git(candidate, 'rev-parse', commit + '^{tree}')
    if fault == 'overflow':
        capture = json.loads(Path(str(control) + '.capture').read_bytes())
        assert capture['actual_exit'] == 0 and capture['injected_stdout_bytes'] == 1024 * 1024 + 1
        print('cp4d-capture ' + json.dumps(capture, sort_keys=True))
    release.write_text('release\n')
    stdout, stderr = finish_owned(process, name, 1)
    assert not stdout and diagnostic in stderr and b'Traceback' not in stderr
    assert before == evidence_snapshot(*roots) and (roots[0] / 'run.json').read_bytes() == prior
    assert not {'recoverable', 'reason', 'recovery'} & json.loads(prior).keys()
    record('P06-keyed-after-effect', name + '-ordinary-error-preserves-pending', 'PASS')
    for index in range(2):
        for operation, invocation in [('read', read), ('delivery', delivery)]:
            recovery_operation(name + '-' + operation + '-' + str(index), invocation, roots, control,
                               3, unavailable='replay.materialization-result-missing')
            record('P06-keyed-after-effect', name + '-' + operation + '-' + str(index), 'PASS')
    assert control.read_bytes() == b'invoked\n'


PY

checkpoint_inventory="$tmp/checkpoint1-case-inventory.tsv"
: > "$checkpoint_inventory"
python3 "$checkpoint_helper" "$replay" "$input" "$key" "$tmp/source.git" \
  "$tmp/stored-state" "$tmp/stored-candidate" "$tmp/stored-scratch" \
  "$runtime/object-closure" "$jq_bin" "$expected" "$tmp/checkpoint1-cases" \
  "$checkpoint_inventory" "$empty_input" "$tmp/empty-key.json" \
  "$tmp/no-change-state" "$tmp/no-change-candidate" "$tmp/no-change-scratch" \
  "$no_change_expected" "$loaded_wrapper"
checkpoint_case_count=$(wc -l < "$checkpoint_inventory" | tr -d ' ')
[ "$checkpoint_case_count" -ge 100 ] || fail checkpoint1-case-count
original_evidence="$tmp/original-case-evidence.jsonl"
python3 - "$checkpoint_inventory" "$original_evidence" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

source, target = map(Path, sys.argv[1:])
data = source.read_bytes()
rows = [line.split("\t") for line in data.decode().splitlines()]
assert len(rows) == 654 and all(len(row) == 3 and row[2] == "PASS" for row in rows)
records = [{"group": row[0], "kind": "original-case-inventory", "name": row[1],
            "ordinal": ordinal, "result": row[2]}
           for ordinal, row in enumerate(rows, 1)]
records.append({"bytes": len(data), "kind": "proof-hash", "name": "original-case-inventory",
                "sha256": hashlib.sha256(data).hexdigest()})
encoded = b"".join((json.dumps(item, sort_keys=True, separators=(",", ":")) + "\n").encode()
                   for item in records)
assert len(encoded) <= 512 * 1024
target.write_bytes(encoded)
PY
/bin/cat "$original_evidence"
printf '{"bytes":%s,"kind":"proof-hash","name":"original-case-evidence","sha256":"%s"}\n' \
  "$(wc -c < "$original_evidence" | tr -d ' ')" "$(sha_file "$original_evidence")"
pass "P03/P04/P05 typed key, journal, parser, and preservation matrix ($checkpoint_case_count cases)"

bad_stored_response="$tmp/bad-stored-response.json"
"$jq_bin" -S -c '.receiver_result.response_utf8 | fromjson |
  .stage_result.body.attempt_number=2' "$tmp/stored-state/run.json" > "$bad_stored_response"
bad_stored_stage="$tmp/bad-stored-stage.json"
"$jq_bin" -S -c '.stage_result' "$bad_stored_response" > "$bad_stored_stage"
"$jq_bin" -S -c --rawfile response "$bad_stored_response" \
  --arg response_sha "$(sha_file "$bad_stored_response")" \
  --arg stage_sha "$(sha_file "$bad_stored_stage")" '
  .receiver_result.response_utf8=$response |
  .receiver_result.response_sha256=$response_sha |
  .receiver_result.stage_result_sha256=$stage_sha' \
  "$tmp/stored-state/run.json" > "$tmp/stored-state/run.next"
/bin/mv "$tmp/stored-state/run.next" "$tmp/stored-state/run.json"
corrupt_before=$(sha_file "$tmp/stored-state/run.json")
set +e
python3 "$replay" "${stored_args[@]}" --read-materialization-result \
  > "$tmp/corrupt-read.out" 2> "$tmp/corrupt-read.err"
status=$?
set -e
[ "$status" -eq 1 ] && [ ! -s "$tmp/corrupt-read.out" ] &&
  [ "$(sha_file "$tmp/stored-state/run.json")" = "$corrupt_before" ] || fail corrupt-stored
pass 'rehashed corrupt result relations fail without changing retained bytes'

suite_complete=1
printf 'replay materialization result: %s focused checks passed\n' "$passed"
