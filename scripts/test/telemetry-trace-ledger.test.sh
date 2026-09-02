#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
validator="$root/telemetry/v1/validate-trace-ledger.sh"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-trace-ledger-test.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() { /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) jq_asset=jq-osx-amd64; jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_asset=jq-linux64; jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) fail "unsupported host $platform" ;;
esac
jq_cache_dir="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$jq_cache_dir"
jq_cache="$jq_cache_dir/$jq_asset"
if [ ! -f "$jq_cache" ] || [ -L "$jq_cache" ] || [ "$(sha_file "$jq_cache")" != "$jq_sha" ]; then
  download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$download"
  [ "$(sha_file "$download")" = "$jq_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_cache"
fi
bin="$tmp/bin"
/bin/mkdir -m 700 "$bin"
/bin/cp "$jq_cache" "$bin/jq"
/bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"
[ "$("$jq_bin" --version)" = jq-1.6 ] || fail 'jq identity'

unsealed="$tmp/unsealed.json"
"$jq_bin" -S -c -n '
  def ref($id;$c): {content_id:$id,media_type:"application/vnd.ystack.trace-source+json",sha256:($c*64)};
  def recorded($value;$c): {state:"recorded",value:$value,source_ref:ref("trace-source."+$c;$c)};
  def unavailable($reason): {state:"unavailable",reason_id:$reason};
  def facts($stage;$tool;$status;$result;$latency): {
    adapter:unavailable("adapter.unavailable"),cost_microunits:unavailable("cost.unavailable"),
    execution_environment:recorded("environment.local";"1"),gate:unavailable("gate.unavailable"),
    identity:recorded("actor.example";"2"),initiative:recorded("initiative.example";"3"),
    latency_ms:(if $latency == null then unavailable("latency.unavailable") else recorded($latency;"4") end),
    result:$result,stage:recorded($stage;"5"),status:recorded($status;"6"),
    task_class:recorded("task.routine";"7"),tool:$tool,workflow:recorded("workflow.example";"8")};
  def event($id;$trace;$sequence;$time;$type;$facts): {
    schema_version:1,kind:"telemetry_trace_event",id:$id,session_id:"session.example",
    attempt_id:"attempt.example",trace_id:$trace,sequence:$sequence,prior_digest:null,
    occurred_at:$time,event_type:$type,facts:$facts,record_digest:("0"*64)};
  {schema_version:1,kind:"telemetry_trace_ledger",id:"trace-ledger.example",
   body:{session_id:"session.example",attempt_id:"attempt.example",
     trace_ids:["trace.one","trace.two"],events:[
     event("event.000";"trace.one";0;"2026-09-02T12:00:00Z";"session.started";
       facts("stage.session";unavailable("tool.unavailable");"status.running";unavailable("result.unavailable");null)),
     event("event.001";"trace.one";1;"2026-09-02T12:00:01Z";"tool.finished";
       facts("stage.build";recorded("tool.example";"9");"status.completed";recorded("result.changed";"a");25)),
     event("event.002";"trace.two";2;"2026-09-02T12:00:02Z";"gate.checked";
       facts("stage.verify";unavailable("tool.not-applicable");"status.completed";recorded("result.passed";"b");3))],
     seal:{algorithm:"sha256",canonicalization:"jq-1.6-sort-compact-line",event_count:0,
       first_digest:("0"*64),final_digest:("0"*64)}}}
' > "$unsealed"

reseal_count=0
reseal() {
  local source=$1 destination=$2 state count i prior digest first=''
  reseal_count=$((reseal_count + 1))
  state="$tmp/reseal-$reseal_count.json"
  /bin/cp "$source" "$state"
  count=$("$jq_bin" -r '.body.events | length' "$state")
  prior=''
  i=0
  while [ "$i" -lt "$count" ]; do
    if [ "$i" -eq 0 ]; then
      "$jq_bin" -S -c --argjson i "$i" '.body.events[$i].prior_digest=null' "$state" > "$state.next"
    else
      "$jq_bin" -S -c --argjson i "$i" --arg prior "$prior" '.body.events[$i].prior_digest=$prior' "$state" > "$state.next"
    fi
    /bin/mv "$state.next" "$state"
    "$jq_bin" -S -c --argjson i "$i" '.body.events[$i] | del(.record_digest)' "$state" > "$tmp/event.json"
    digest=$(sha_file "$tmp/event.json")
    [ -n "$first" ] || first=$digest
    "$jq_bin" -S -c --argjson i "$i" --arg digest "$digest" '.body.events[$i].record_digest=$digest' "$state" > "$state.next"
    /bin/mv "$state.next" "$state"
    prior=$digest
    i=$((i + 1))
  done
  "$jq_bin" -S -c --argjson count "$count" --arg first "$first" --arg final "$prior" \
    '.body.seal.event_count=$count | .body.seal.first_digest=$first | .body.seal.final_digest=$final' \
    "$state" > "$destination"
}

valid="$tmp/valid.json"
reseal "$unsealed" "$valid"

run_validator() {
  local input=$1 out=$2 err=$3 status=0
  PATH="$bin:/usr/bin:/bin" "$validator" validate session.example attempt.example \
    "$input" > "$out" 2> "$err" || status=$?
  RUN_STATUS=$status
}
expect_pass() {
  local name=$1 input=$2 out err
  out="$tmp/$name.out"
  err="$tmp/$name.err"
  run_validator "$input" "$out" "$err"
  [ "$RUN_STATUS" -eq 0 ] && [ -s "$out" ] && [ ! -s "$err" ] || fail "$name"
  pass "$name"
}
expect_error() {
  local name=$1 expected=$2 input=$3 out err
  out="$tmp/$name.out"
  err="$tmp/$name.err"
  run_validator "$input" "$out" "$err"
  [ "$RUN_STATUS" -ne 0 ] && [ ! -s "$out" ] && [ "$(/bin/cat "$err")" = "$expected" ] || fail "$name"
  pass "$name"
}
raw_mutation() {
  local name=$1 filter=$2
  "$jq_bin" -S -c "$filter" "$valid" > "$tmp/$name.json"
  /usr/bin/printf '%s\n' "$tmp/$name.json"
}
resealed_mutation() {
  local name=$1 filter=$2
  "$jq_bin" -S -c "$filter" "$valid" > "$tmp/$name.pre.json"
  reseal "$tmp/$name.pre.json" "$tmp/$name.json"
  /usr/bin/printf '%s\n' "$tmp/$name.json"
}

expect_pass canonical-valid "$valid"
expect_pass deterministic-repeat "$valid"
/usr/bin/cmp -s "$tmp/canonical-valid.out" "$tmp/deterministic-repeat.out" || fail 'deterministic output'
ledger_sha=$(sha_file "$valid")
"$jq_bin" -e --arg sha "$ledger_sha" '
  .kind == "telemetry_trace_ledger_validation" and .body.activation_state == "inactive" and
  .body.authority_effect == "none" and .body.storage_effect == "none" and
  .body.session_id == "session.example" and .body.attempt_id == "attempt.example" and
  .body.replay_key == {session_id:"session.example",attempt_id:"attempt.example",
    final_digest:.body.final_digest} and .body.event_count == 3 and
  (.body.trace_ids | length) == 2 and
  .body.ledger_ref.sha256 == $sha and .body.ledger_ref.media_type ==
    "application/vnd.ystack.telemetry-trace-ledger+json"
' "$tmp/canonical-valid.out" >/dev/null || fail 'receipt shape'
pass 'canonical deterministic validation receipt'
[ "$(/usr/bin/wc -c < "$tmp/canonical-valid.out" | /usr/bin/tr -d ' ')" -le 2048 ] ||
  fail 'receipt size bound'
pass 'validation receipt is bounded'

expect_error sequence E_RELATION "$(resealed_mutation sequence '.body.events[1].sequence=7')"
expect_error prior-digest E_RELATION "$(raw_mutation prior-digest '.body.events[1].prior_digest=("f"*64)')"
expect_error duplicate-id E_RELATION "$(resealed_mutation duplicate-id '.body.events[1].id=.body.events[0].id')"
expect_error reorder E_RELATION "$(raw_mutation reorder '.body.events[0:2] |= reverse')"
expect_error truncation E_RELATION "$(raw_mutation truncation '.body.events |= .[:-1]')"
expect_error tamper E_RELATION "$(raw_mutation tamper '.body.events[1].facts.status.value="status.failed"')"
expect_error time-order E_RELATION "$(resealed_mutation time-order '.body.events[2].occurred_at="2026-09-02T11:59:59Z"')"
expect_error trace-set E_RELATION "$(resealed_mutation trace-set '.body.events[2].trace_id="trace.three"')"
expect_error event-attempt E_RELATION "$(resealed_mutation event-attempt '.body.events[1].attempt_id="attempt.other"')"
expect_error missing-unavailable E_SHAPE "$(raw_mutation missing-unavailable 'del(.body.events[0].facts.adapter)')"
expect_error malformed-time E_SHAPE "$(raw_mutation malformed-time '.body.events[0].occurred_at="2026-02-30T00:00:00Z"')"
for field in authority command credential effect network provider; do
  expect_error "forbidden-$field" E_SHAPE "$(raw_mutation "forbidden-$field" ".body.events[0].facts.$field=\"forbidden\"")"
done
expect_error bounded-events E_LIMIT "$(raw_mutation bounded-events '.body.events=[range(0;257) as $i | .body.events[0]]')"

"$jq_bin" . "$valid" > "$tmp/noncanonical.json"
expect_error noncanonical E_CANONICAL "$tmp/noncanonical.json"
/usr/bin/printf '{\n' > "$tmp/parse.json"
expect_error parse E_PARSE "$tmp/parse.json"
/bin/cat "$valid" "$valid" > "$tmp/multi-root.json"
expect_error multi-root E_PARSE "$tmp/multi-root.json"
/usr/bin/printf '\357\273\277' > "$tmp/bom.json"
/bin/cat "$valid" >> "$tmp/bom.json"
expect_error bom E_PARSE "$tmp/bom.json"
/usr/bin/awk 'BEGIN { for (i=0;i<1048577;i++) printf "x" }' > "$tmp/large.json"
expect_error raw-limit E_LIMIT "$tmp/large.json"
/bin/ln -s "$valid" "$tmp/ledger-link.json"
expect_error symlink-input E_RUNTIME "$tmp/ledger-link.json"
/usr/bin/mkfifo "$tmp/ledger.fifo"
expect_error nonregular-input E_RUNTIME "$tmp/ledger.fifo"

usage_status=0
PATH="$bin:/usr/bin:/bin" "$validator" validate session.example attempt.example "$valid" extra \
  > "$tmp/usage.out" 2> "$tmp/usage.err" || usage_status=$?
[ "$usage_status" -ne 0 ] && [ ! -s "$tmp/usage.out" ] && [ "$(/bin/cat "$tmp/usage.err")" = E_USAGE ] || fail usage
pass 'closed command surface'

runtime="$tmp/runtime"
/bin/mkdir -m 700 "$runtime"
/bin/cp "$validator" "$runtime/validate-trace-ledger.sh"
/bin/chmod 0555 "$runtime/validate-trace-ledger.sh"
/bin/ln -s "$root/telemetry/v1/trace-ledger.jq" "$runtime/trace-ledger.jq"
runtime_status=0
PATH="$bin:/usr/bin:/bin" "$runtime/validate-trace-ledger.sh" validate \
  session.example attempt.example "$valid" > "$tmp/runtime.out" 2> "$tmp/runtime.err" || runtime_status=$?
[ "$runtime_status" -ne 0 ] && [ ! -s "$tmp/runtime.out" ] && [ "$(/bin/cat "$tmp/runtime.err")" = E_RUNTIME ] || fail 'symlinked program'
pass 'symlinked validator program rejected'

other_attempt_status=0
PATH="$bin:/usr/bin:/bin" "$validator" validate session.example attempt.other "$valid" \
  > "$tmp/other-attempt.out" 2> "$tmp/other-attempt.err" || other_attempt_status=$?
[ "$other_attempt_status" -ne 0 ] && [ ! -s "$tmp/other-attempt.out" ] &&
  [ "$(/bin/cat "$tmp/other-attempt.err")" = E_RELATION ] || fail 'cross-attempt replay'
pass 'caller attempt binding rejects replay'

other_session_status=0
PATH="$bin:/usr/bin:/bin" "$validator" validate session.other attempt.example "$valid" \
  > "$tmp/other-session.out" 2> "$tmp/other-session.err" || other_session_status=$?
[ "$other_session_status" -ne 0 ] && [ ! -s "$tmp/other-session.out" ] &&
  [ "$(/bin/cat "$tmp/other-session.err")" = E_RELATION ] || fail 'cross-session replay'
pass 'caller session binding rejects replay'

fake_bin="$tmp/fake-bin"
/bin/mkdir -m 700 "$fake_bin"
/usr/bin/printf '#!/bin/sh\n/usr/bin/touch %s\n/usr/bin/printf "jq-1.6\\n"\n' \
  "$tmp/fake-jq-ran" > "$fake_bin/jq"
/bin/chmod 0500 "$fake_bin/jq"
fake_status=0
PATH="$fake_bin:/usr/bin:/bin" "$validator" validate session.example attempt.example "$valid" \
  > "$tmp/fake.out" 2> "$tmp/fake.err" || fake_status=$?
[ "$fake_status" -ne 0 ] && [ ! -s "$tmp/fake.out" ] &&
  [ "$(/bin/cat "$tmp/fake.err")" = E_RUNTIME ] && [ ! -e "$tmp/fake-jq-ran" ] ||
  fail 'unverified jq execution'
pass 'unverified jq is rejected without execution'

/usr/bin/printf 'PASS: %s telemetry trace-ledger checks\n' "$passes"
