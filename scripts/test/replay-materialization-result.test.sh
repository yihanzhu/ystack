#!/usr/bin/env bash
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
[ "$status" -eq 1 ] && grep -Fq 'does not accept workflow observations' "$tmp/observation.err" ||
  fail read-observation
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
[ "$status" -eq 3 ] && "$jq_bin" -e '.status=="unavailable" and
  .reason_id=="replay.legacy-result-unavailable" and (has("stage_result")|not)' \
  "$tmp/legacy-read.out" >/dev/null || fail legacy-read
pass 'version 1 remains unavailable as original result evidence'

counter_wrapper="$tmp/counter-wrapper.py"
cat > "$counter_wrapper" <<'PY'
import importlib.util
import pathlib
import sys

path, counter, *arguments = sys.argv[1:]
spec = importlib.util.spec_from_file_location("replay", path)
module = importlib.util.module_from_spec(spec)
module._REPLAY_DRIVER_BYTES = pathlib.Path(path).read_bytes()
exec(compile(module._REPLAY_DRIVER_BYTES, path, "exec"), module.__dict__)
original = module.capture_materializer
def counted(*values):
    with pathlib.Path(counter).open("a") as handle:
        handle.write("invoked\n")
    return original(*values)
module.capture_materializer = counted
sys.argv = [path] + arguments
raise SystemExit(module.main())
PY
make_roots concurrent
set_replay_args concurrent
concurrent_args=("${replay_arguments[@]}")
python3 "$counter_wrapper" "$replay" "$tmp/invocations" "${concurrent_args[@]}" \
  > "$tmp/concurrent-1.out" &
first=$!
python3 "$counter_wrapper" "$replay" "$tmp/invocations" "${concurrent_args[@]}" \
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

wrapper="$tmp/crash-wrapper.py"
cat > "$wrapper" <<'PY'
import importlib.util
import os
import pathlib
import sys
import time

path, point, ready, release, *arguments = sys.argv[1:]
spec = importlib.util.spec_from_file_location("replay", path)
module = importlib.util.module_from_spec(spec)
module._REPLAY_DRIVER_BYTES = pathlib.Path(path).read_bytes()
exec(compile(module._REPLAY_DRIVER_BYTES, path, "exec"), module.__dict__)
original = module.write_journal

def paused(target, state):
    if point == "before" and state.get("receiver_result", {}).get("status") == "stored":
        pathlib.Path(ready).write_text("ready\n")
        while not pathlib.Path(release).exists():
            time.sleep(0.02)
    original(target, state)
    if point == "after" and state.get("receiver_result", {}).get("status") == "stored" and state.get("phase") == "verifying":
        pathlib.Path(ready).write_text("ready\n")
        while not pathlib.Path(release).exists():
            time.sleep(0.02)

module.write_journal = paused
sys.argv = [path] + arguments
raise SystemExit(module.main())
PY

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
  python3 "$wrapper" "$replay" "$point" "$ready" "$release" "${crash_args[@]}" \
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
    [ "$status" -eq 3 ] && "$jq_bin" -e '.reason_id=="replay.materialization-result-missing"' \
      "$tmp/before-read.out" >/dev/null || fail before-missing
    [ "$(git_clean --git-dir="$tmp/crash-before-candidate/repository.git" rev-parse refs/heads/candidate)" = "$candidate_before" ] ||
      fail before-candidate-mutated
  else
    python3 "$replay" "${crash_args[@]}" --read-materialization-result > "$tmp/after-read.out"
    "$jq_bin" -e '.status=="stored" and .stage_result.content.kind=="stage_result"' \
      "$tmp/after-read.out" >/dev/null || fail after-stored
  fi
done
pass 'both synchronized process-crash windows preserve their distinct evidence state'

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
