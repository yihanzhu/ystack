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
cleanup() { /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT

sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
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
    /usr/bin/git -c core.hooksPath=/dev/null "$@"
}

make_source() {
  local destination=$1 tree base commit
  git_clean init --bare "$destination" >/dev/null
  tree=$(printf 'alpha\nbeta\n' | git_clean --git-dir="$destination" hash-object -w --stdin |
    git_clean --git-dir="$destination" mktree 2>/dev/null) || true
  # mktree needs a named entry, so build the source tree through a temporary index.
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
lock_inode_before=$(/usr/bin/stat -f %i "$tmp/stored-state/replay.lock" 2>/dev/null ||
  /usr/bin/stat -c %i "$tmp/stored-state/replay.lock")
python3 "$replay" "${stored_args[@]}" --read-materialization-result > "$tmp/stored-read.out"
"$jq_bin" -e '.kind=="delivery_replay_materialization_result" and .status=="stored" and
  .stage_result.content.kind=="stage_result" and
  .receipt.content_id=="candidate.materialization.receipt" and
  .response_utf8[-1:]=="\n"' "$tmp/stored-read.out" >/dev/null || fail stored-read
[ "$(sha_file "$tmp/stored-state/run.json")" = "$journal_before" ] || fail stored-read-mutated
lock_inode_after=$(/usr/bin/stat -f %i "$tmp/stored-state/replay.lock" 2>/dev/null ||
  /usr/bin/stat -c %i "$tmp/stored-state/replay.lock")
[ "$lock_inode_after" = "$lock_inode_before" ] || fail stored-lock-replaced
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
import json
import pathlib
import sys
import time

path, mode, control, *arguments = sys.argv[1:]
if mode == "pause":
    point, ready, release, *arguments = arguments
spec = importlib.util.spec_from_file_location("replay", path)
module = importlib.util.module_from_spec(spec)
module._REPLAY_DRIVER_BYTES = pathlib.Path(path).read_bytes()
exec(compile(module._REPLAY_DRIVER_BYTES, path, "exec"), module.__dict__)
if mode == "count":
    original = module.capture_materializer
    def counted(*values):
        with pathlib.Path(control).open("a") as handle:
            handle.write("invoked\n")
        return original(*values)
    module.capture_materializer = counted
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
else:
    raise AssertionError(("unknown wrapper mode", mode))
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


wait_ready() {
  local process=$1 ready=$2 count=0
  while [ ! -f "$ready" ]; do
    kill -0 "$process" 2>/dev/null || fail crash-process-died-early
    count=$((count + 1))
    [ "$count" -lt 500 ] || fail crash-process-timeout
    sleep 0.02
  done
}

for point in before after; do
  make_roots "crash-$point"
  set_replay_args "crash-$point"
  crash_args=("${replay_arguments[@]}")
  ready="$tmp/$point.ready"
  release="$tmp/$point.release"
  python3 "$loaded_wrapper" "$replay" pause unused "$point" "$ready" "$release" "${crash_args[@]}" \
    > "$tmp/$point.out" 2> "$tmp/$point.err" &
  process=$!
  wait_ready "$process" "$ready"
  kill -KILL "$process"
  set +e
  wait "$process" 2>/dev/null
  set -e
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
done
pass 'both synchronized process-crash windows preserve their distinct evidence state'

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


def invoke_case(group, name, expected_status, state_value=None, state_bytes=None,
                key_bytes=None, input_bytes=None, pending=False, output_kind=None):
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
    if before != after:
        raise AssertionError((group, name, "evidence changed"))
    if output_kind is None:
        if b"delivery_replay_materialization_result" in completed.stdout:
            raise AssertionError((group, name, "scanner-ready output on refusal"))
    else:
        output = json.loads(completed.stdout)
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

base_raw = encoded(base_state_value)
raw_state_cases = {
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
for name, value in raw_state_cases.items():
    invoke_case("P05-journal-parser", f"journal-{name}", 1, state_bytes=value)


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

printf 'replay materialization result: %s focused checks passed\n' "$passed"
