#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
scanner="$root/maintenance/v1/scan.sh"
bands_policy="$root/maintenance/v1/control-bands.json"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-maintenance-loop-test.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() { /bin/chmod -R u+w "$tmp" >/dev/null 2>&1 || :; /bin/rm -rf -- "$tmp"; }
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
# This suite may run before any other, so it fills the shared jq 1.6 cache itself.
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

fixtures="$tmp/fixtures"
/bin/mkdir -m 700 "$fixtures"

# --- the band policy ------------------------------------------------------
"$jq_bin" -S -c . "$bands_policy" > "$tmp/bands-canonical.json"
/usr/bin/cmp -s "$bands_policy" "$tmp/bands-canonical.json" || fail 'band policy canonical'
"$jq_bin" -e -n -L "$root/maintenance/v1" --slurpfile policy "$bands_policy" \
  'include "bands"; $policy[0] | bands_ok' >/dev/null || fail 'band policy shape'
"$jq_bin" -e '.body.bands | length == 7 and
  ([.[] | select(.band_id == "eval-failures-max")] | length) == 1 and
  ([.[] | select(.band_id == "eval-failures-max")][0].threshold) == 0' \
  "$bands_policy" >/dev/null || fail 'band policy contents'
pass 'the control bands are a canonical, closed, fixed-threshold policy document'

# --- fixtures -------------------------------------------------------------
dashboard() {
  "$jq_bin" -S -c -n --argjson failed "$1" --argjson stale_passed "$2" '
    def cases($t;$p;$f;$i): {total:$t,passed:$p,failed:$f,inconclusive:$i};
    {schema_version:1,kind:"eval_dashboard",id:"evals.dashboard.v1",
     body:{activation_state:"inactive",authority_effect:"none",
       mode:"deterministic-offline",observed_at:"2026-09-05T00:00:00Z",
       quality:cases(20;20 - $failed;$failed;0),
       recovery:{cancelled_stayed_terminal:1,events_refused:2,
         repeats_redelivered_once:1,repeats_suppressed_after_acknowledgement:1,
         retry_limit_enforced:1,stranded_recovered:1},
       families:[{family_id:"repeated-cancelled-missed-events",cases:cases(12;12;0;0)},
         {family_id:"stale-moved-artifacts",
          cases:cases(8;$stale_passed;8 - $stale_passed;0)}]}}'
}
dashboard 0 8 > "$fixtures/dashboard-clean.json"
dashboard 1 7 > "$fixtures/dashboard-two-out.json"

seal() {
  local source=$1 destination=$2 state count index prior digest first=''
  state="$destination.state"
  /bin/cp "$source" "$state"
  count=$("$jq_bin" -r '.body.events | length' "$state")
  prior=''
  index=0
  while [ "$index" -lt "$count" ]; do
    if [ "$index" -eq 0 ]; then
      "$jq_bin" -S -c --argjson i "$index" '.body.events[$i].prior_digest=null' \
        "$state" > "$state.next"
    else
      "$jq_bin" -S -c --argjson i "$index" --arg prior "$prior" \
        '.body.events[$i].prior_digest=$prior' "$state" > "$state.next"
    fi
    /bin/mv "$state.next" "$state"
    "$jq_bin" -S -c --argjson i "$index" '.body.events[$i] | del(.record_digest)' \
      "$state" > "$state.event"
    digest=$(sha_file "$state.event")
    [ -n "$first" ] || first=$digest
    "$jq_bin" -S -c --argjson i "$index" --arg digest "$digest" \
      '.body.events[$i].record_digest=$digest' "$state" > "$state.next"
    /bin/mv "$state.next" "$state"
    prior=$digest
    index=$((index + 1))
  done
  "$jq_bin" -S -c --argjson count "$count" --arg first "$first" --arg final "$prior" \
    '.body.seal.event_count=$count | .body.seal.first_digest=$first |
     .body.seal.final_digest=$final' "$state" > "$destination"
  /bin/rm -f "$state" "$state.event"
}

ledger_source() {
  "$jq_bin" -S -c -n --arg second "$1" '
    def ref($c): {content_id:("trace-source." + $c),
      media_type:"application/vnd.ystack.trace-source+json",sha256:($c*64)};
    def recorded($v;$c): {state:"recorded",value:$v,source_ref:ref($c)};
    def unavailable($r): {state:"unavailable",reason_id:$r};
    def facts($result): {adapter:unavailable("adapter.unavailable"),
      cost_microunits:unavailable("cost.unavailable"),
      execution_environment:recorded("environment.local";"1"),
      gate:unavailable("gate.unavailable"),identity:recorded("actor.example";"2"),
      initiative:recorded("initiative.example";"3"),
      latency_ms:unavailable("latency.unavailable"),result:$result,
      stage:recorded("stage.maintenance";"5"),status:recorded("status.completed";"6"),
      task_class:recorded("task.routine";"7"),tool:unavailable("tool.unavailable"),
      workflow:recorded("workflow.example";"8")};
    def event($id;$sequence;$time;$result): {schema_version:1,
      kind:"telemetry_trace_event",id:$id,session_id:"session.maintenance",
      attempt_id:"attempt.maintenance",trace_id:"trace.maintenance",
      sequence:$sequence,prior_digest:null,occurred_at:$time,
      event_type:"stage.finished",facts:$result,record_digest:("0"*64)};
    {schema_version:1,kind:"telemetry_trace_ledger",id:"maintenance-trace-ledger",
     body:{session_id:"session.maintenance",attempt_id:"attempt.maintenance",
       trace_ids:["trace.maintenance"],
       events:[
         event("event.000";0;"2026-09-04T12:00:00Z";facts(recorded("result.passed";"a"))),
         event("event.001";1;"2026-09-04T12:00:01Z";facts(recorded($second;"b")))],
       seal:{algorithm:"sha256",canonicalization:"jq-1.6-sort-compact-line",
         event_count:0,first_digest:("0"*64),final_digest:("0"*64)}}}'
}
ledger_source result.changed > "$fixtures/ledger-open.json"
seal "$fixtures/ledger-open.json" "$fixtures/ledger-clean.json"
ledger_source result.environment-refused > "$fixtures/ledger-refused-open.json"
seal "$fixtures/ledger-refused-open.json" "$fixtures/ledger-refused.json"

kill_switch() {
  "$jq_bin" -S -c -n --arg verdict "$1" --arg reason "$2" '
    {schema_version:1,kind:"kill_switch_evaluation",id:"kill-attempt.example",
     body:{activation_state:"inactive",authority_effect:"none",
       evaluation_mode:"observation-only",reference_semantics:"identity-only",
       verdict:$verdict,reason_ids:[$reason]}}'
}
kill_switch satisfied kill.cleared-current > "$fixtures/kill-clear.json"
kill_switch violated kill.stop.global > "$fixtures/kill-stop.json"

rehearsal() {
  "$jq_bin" -S -c -n --arg id "$1" --arg at "$2" --arg outcome "$3" '
    {schema_version:1,kind:"rollback_rehearsal_record",id:$id,
     body:{activation_state:"inactive",authority:"none",environment:{tier:"staging"},
       evidence:{evidence_id:"evidence.rehearsal",
         stage_result_ref:{schema_version:2,kind:"stage_result",
           id:"result.rehearsal",sha256:("b"*64)}},
       from_release_ref:{schema_version:1,kind:"release_record",id:"release.one",
         sha256:("c"*64)},
       to_release_ref:{schema_version:1,kind:"release_record",id:"release.two",
         sha256:("d"*64)},
       outcome:$outcome,rehearsed_at:$at}}'
}
rehearsal rehearsal.recent 2026-08-20T00:00:00Z rehearsed > "$fixtures/rehearsal-recent.json"
rehearsal rehearsal.old 2026-05-01T00:00:00Z rehearsed > "$fixtures/rehearsal-old.json"
rehearsal rehearsal.failed 2026-09-01T00:00:00Z failed > "$fixtures/rehearsal-failed.json"

finding() {
  "$jq_bin" -S -c -n --arg id "$1" --arg severity "$2" '
    {schema_version:1,kind:"maintenance_scan_finding",id:$id,
     body:{activation_state:"inactive",authority:"none",scanner_id:"scanner.example",
       rule_id:"rule.hardcoded-credential",severity:$severity,
       path:"adapters/example/v1/normalize.jq",evidence_sha256:("e"*64),
       observed_at:"2026-09-04T00:00:00Z"}}'
}
finding scan-finding-001 critical > "$fixtures/finding-critical.json"
finding scan-finding-002 low > "$fixtures/finding-low.json"

# --- driver harness -------------------------------------------------------
run_count=0
run_scan() {
  local name=$1
  shift
  RUN_DIR="$tmp/run-$name"
  /bin/rm -rf -- "$RUN_DIR"
  /bin/mkdir -m 700 "$RUN_DIR"
  RUN_STATUS=0
  run_count=$((run_count + 1))
  PATH="$bin:/usr/bin:/bin" "$scanner" scan "$1" "$2" "$3" "$RUN_DIR" "${@:4}" \
    > "$tmp/out-$name.json" 2> "$tmp/err-$name.txt" || RUN_STATUS=$?
}
expect_scan() {
  local name=$1
  shift
  run_scan "$name" "$@"
  [ "$RUN_STATUS" -eq 0 ] && [ -s "$tmp/out-$name.json" ] &&
    [ ! -s "$tmp/err-$name.txt" ] ||
    fail "scan $name (status $RUN_STATUS: $(/bin/cat "$tmp/err-$name.txt"))"
}
expect_refusal() {
  local name=$1 expected=$2
  shift 2
  run_scan "$name" "$@"
  [ "$RUN_STATUS" -ne 0 ] && [ ! -s "$tmp/out-$name.json" ] &&
    [ "$(/bin/cat "$tmp/err-$name.txt")" = "$expected" ] || fail "refusal $name"
  [ -z "$(/usr/bin/find "$RUN_DIR" -mindepth 1 -print -quit)" ] ||
    fail "refusal $name wrote output"
  pass "$name is refused with $expected and writes nothing"
}
written_names() { /usr/bin/find "$1" -mindepth 1 -maxdepth 1 -print |
  /usr/bin/awk -F/ '{print $NF}' | /usr/bin/sort | /usr/bin/tr '\n' ' '; }

clean=("$fixtures/dashboard-clean.json" "$fixtures/ledger-clean.json"
  "$fixtures/kill-clear.json")
two_out=("$fixtures/dashboard-two-out.json" "$fixtures/ledger-clean.json"
  "$fixtures/kill-clear.json")

# --- happy path: every band held, nothing to triage ------------------------
expect_scan in-band "${clean[@]}" "$fixtures/rehearsal-recent.json"
[ "$(written_names "$RUN_DIR")" = 'maintenance-scan.json ' ] || fail 'in-band output set'
"$jq_bin" -e '.schema_version == 1 and .kind == "maintenance_scan" and
  .body.activation_state == "inactive" and .body.authority == "none" and
  .body.deploy_authority == "none" and .body.filing_effect == "none" and
  .body.evaluation_mode == "observation-only" and
  .body.qualification.state == "unavailable" and
  .body.reason_id == "maintenance.scan-completed" and
  .body.kill_switch.engaged == false and
  .body.summary == {bands_total:7,bands_in_band:7,bands_out_of_band:0,
    findings_total:0,findings_high_severity:0,intents_written:0} and
  (.body.bands | all(.[]; .state == "in-band"))' \
  "$tmp/out-in-band.json" >/dev/null || fail 'in-band scan record'
pass 'a dashboard inside every band produces a scan record and no intents'

expect_scan in-band-repeat "${clean[@]}" "$fixtures/rehearsal-recent.json"
/usr/bin/cmp -s "$tmp/out-in-band.json" "$tmp/out-in-band-repeat.json" ||
  fail 'repeat scan differs'
pass 'a repeated scan of the same documents is byte-identical'

# --- two bands out of band ------------------------------------------------
expect_scan two-out "${two_out[@]}" "$fixtures/rehearsal-recent.json"
[ "$(written_names "$RUN_DIR")" = \
  'intent-band-eval-failures-max.json intent-band-stale-rate-max.json maintenance-scan.json ' ] ||
  fail 'two-out output set'
two_out_dir=$RUN_DIR
"$jq_bin" -e '.body.summary == {bands_total:7,bands_in_band:5,bands_out_of_band:2,
    findings_total:0,findings_high_severity:0,intents_written:2} and
  (.body.intents | map(.file_name)) ==
    ["intent-band-eval-failures-max.json","intent-band-stale-rate-max.json"] and
  ([.body.bands[] | select(.state == "out-of-band") | .reason_id] |
    unique) == ["maintenance.band-crossed"]' \
  "$tmp/out-two-out.json" >/dev/null || fail 'two-out scan record'
"$jq_bin" -e '.schema_version == 1 and .kind == "maintenance_intent" and
  .id == "maintenance-intent.band.stale-rate-max" and
  .body.owner == "unassigned" and .body.triage_state == "pending" and
  .body.deploy_authority == "none" and .body.authority == "none" and
  .body.filing_effect == "none" and .body.risk_tier_guess == "routine" and
  .body.source == {kind:"control-band",id:"stale-rate-max",
    reason_id:"maintenance.band-crossed"} and
  (.body.sections | keys) == ["affected_users_and_systems","constraints",
    "open_questions","problem","proposed_outcome"] and
  (.body.sections.problem | test("125")) and
  (.body.evidence_refs | length) >= 3' \
  "$two_out_dir/intent-band-stale-rate-max.json" >/dev/null || fail 'band intent shape'
pass 'two out-of-band bands write two deterministically named unassigned intents'

expect_scan two-out-repeat "${two_out[@]}" "$fixtures/rehearsal-recent.json"
/usr/bin/cmp -s "$tmp/out-two-out.json" "$tmp/out-two-out-repeat.json" ||
  fail 'repeat scan record differs'
/usr/bin/cmp -s "$two_out_dir/intent-band-stale-rate-max.json" \
  "$RUN_DIR/intent-band-stale-rate-max.json" || fail 'repeat intents differ'
pass 'repeated intents are byte-identical'

# --- kill switch ----------------------------------------------------------
expect_scan kill-engaged "$fixtures/dashboard-two-out.json" \
  "$fixtures/ledger-clean.json" "$fixtures/kill-stop.json" \
  "$fixtures/rehearsal-recent.json"
[ "$(written_names "$RUN_DIR")" = 'maintenance-scan.json ' ] || fail 'kill output set'
"$jq_bin" -e '.body.reason_id == "maintenance.kill-switch-engaged" and
  .body.kill_switch.engaged == true and .body.kill_switch.verdict == "violated" and
  .body.summary.bands_out_of_band == 2 and .body.summary.intents_written == 0 and
  .body.intents == []' "$tmp/out-kill-engaged.json" >/dev/null ||
  fail 'kill scan record'
pass 'an engaged kill switch records the bands and writes no intent'

kill_switch inconclusive kill.duty-inconclusive > "$fixtures/kill-unknown.json"
expect_scan kill-unknown "$fixtures/dashboard-two-out.json" \
  "$fixtures/ledger-clean.json" "$fixtures/kill-unknown.json" \
  "$fixtures/rehearsal-recent.json"
"$jq_bin" -e '.body.kill_switch.engaged == true and .body.intents == []' \
  "$tmp/out-kill-unknown.json" >/dev/null || fail 'inconclusive kill switch'
pass 'a kill switch that is not satisfied counts as engaged'

# --- findings -------------------------------------------------------------
expect_scan finding-high "${clean[@]}" "$fixtures/rehearsal-recent.json" \
  "$fixtures/finding-critical.json"
[ "$(written_names "$RUN_DIR")" = \
  'intent-finding-scan-finding-001.json maintenance-scan.json ' ] ||
  fail 'finding output set'
"$jq_bin" -e '.id == "maintenance-intent.finding.scan-finding-001" and
  .body.risk_tier_guess == "high" and .body.owner == "unassigned" and
  .body.triage_state == "pending" and
  (.body.sections.problem | test("rule.hardcoded-credential")) and
  (.body.sections.affected_users_and_systems |
    test("adapters/example/v1/normalize.jq"))' \
  "$RUN_DIR/intent-finding-scan-finding-001.json" >/dev/null ||
  fail 'finding intent shape'
pass 'a high-severity scan finding becomes one intent for a human owner'

expect_scan finding-low "${clean[@]}" "$fixtures/rehearsal-recent.json" \
  "$fixtures/finding-low.json"
[ "$(written_names "$RUN_DIR")" = 'maintenance-scan.json ' ] || fail 'low finding output'
"$jq_bin" -e '.body.summary.findings_total == 1 and
  .body.summary.findings_high_severity == 0 and .body.intents == []' \
  "$tmp/out-finding-low.json" >/dev/null || fail 'low finding record'
pass 'a low-severity finding is recorded but raises no intent'

# --- individual bands -----------------------------------------------------
expect_scan refused-events "$fixtures/dashboard-clean.json" \
  "$fixtures/ledger-refused.json" "$fixtures/kill-clear.json" \
  "$fixtures/rehearsal-recent.json"
"$jq_bin" -e '([.body.bands[] | select(.state == "out-of-band") | .band_id]) ==
  ["events-refused-max"]' "$tmp/out-refused-events.json" >/dev/null ||
  fail 'refused events band'
pass 'a refused event in the sealed ledger crosses its band'

# A computed result fact is as valid as a recorded one to the telemetry validator
# and must be read the same way by the bands.
"$jq_bin" -S -c '.body.events[1].facts.result.state = "computed" |
  .body.events[1].facts.result.value = "result.refused"' \
  "$fixtures/ledger-open.json" >"$fixtures/ledger-open-computed.json"
seal "$fixtures/ledger-open-computed.json" "$fixtures/ledger-computed.json"
expect_scan computed-events "$fixtures/dashboard-clean.json" \
  "$fixtures/ledger-computed.json" "$fixtures/kill-clear.json" \
  "$fixtures/rehearsal-recent.json"
"$jq_bin" -e '([.body.bands[] | select(.state == "out-of-band") | .band_id]) ==
  ["events-refused-max"]' "$tmp/out-computed-events.json" >/dev/null ||
  fail 'computed refused events band'
pass 'a computed result fact counts like a recorded one'

# A relative or dotted invocation must pass the driver self-check.
/bin/mkdir -m 700 "$tmp/relative-out"
( cd "$root" && PATH="$bin:/usr/bin:/bin" ./maintenance/v1/scan.sh scan "${clean[@]}" \
  "$tmp/relative-out" >"$tmp/out-relative.json" 2>"$tmp/err-relative.txt" ) ||
  fail "relative invocation: $(/bin/cat "$tmp/err-relative.txt")"
pass 'the driver accepts a relative, dotted invocation path'

expect_scan no-rehearsal "${clean[@]}"
"$jq_bin" -e '([.body.bands[] | select(.state == "out-of-band")] |
  map({band_id,reason_id,value})) ==
  [{band_id:"rollback-rehearsal-max-age",
    reason_id:"maintenance.metric-unmeasurable",value:null}]' \
  "$tmp/out-no-rehearsal.json" >/dev/null || fail 'unmeasurable band'
pass 'a metric with no evidence is out of band, not quietly in band'

expect_scan old-rehearsal "${clean[@]}" "$fixtures/rehearsal-old.json" \
  "$fixtures/rehearsal-failed.json"
"$jq_bin" -e '([.body.bands[] | select(.band_id == "rollback-rehearsal-max-age")][0] |
  .state == "out-of-band" and .value == 127 and
  .reason_id == "maintenance.band-crossed")' \
  "$tmp/out-old-rehearsal.json" >/dev/null || fail 'rehearsal age band'
pass 'rehearsal age is counted in whole days from the dashboard time'

# Age is whole days between full timestamps: 23:59 on the 5th to 00:00 on the
# 5th of the next month is 30 days, not 31, so it sits exactly on the threshold.
rehearsal rehearsal.edge 2026-08-05T23:59:00Z rehearsed > "$fixtures/rehearsal-edge.json"
expect_scan edge-rehearsal "${clean[@]}" "$fixtures/rehearsal-edge.json"
"$jq_bin" -e '([.body.bands[] | select(.band_id == "rollback-rehearsal-max-age")][0] |
  .state == "in-band" and .value == 30)' \
  "$tmp/out-edge-rehearsal.json" >/dev/null || fail 'rehearsal edge age'
pass 'rehearsal age uses full timestamps, so a partial day is not counted'

# One unresolved case in a large family must still cross the zero threshold:
# the per-thousand rate rounds up, never down to zero.
"$jq_bin" -S -c '.body.families |= map(if .family_id == "stale-moved-artifacts"
  then .cases = {total:2000,passed:1999,failed:1,inconclusive:0} else . end)' \
  "$fixtures/dashboard-clean.json" >"$fixtures/dashboard-large-stale.json"
expect_scan large-stale "$fixtures/dashboard-large-stale.json" "$fixtures/ledger-clean.json" \
  "$fixtures/kill-clear.json" "$fixtures/rehearsal-recent.json"
"$jq_bin" -e '([.body.bands[] | select(.band_id == "stale-rate-max")][0] |
  .state == "out-of-band" and .value == 1)' \
  "$tmp/out-large-stale.json" >/dev/null || fail 'large stale family rate'
pass 'one unresolved case in a large stale family still crosses the band'

# --- refusals -------------------------------------------------------------
/usr/bin/printf '{\n' > "$fixtures/broken.json"
expect_refusal malformed E_PARSE "$fixtures/broken.json" \
  "$fixtures/ledger-clean.json" "$fixtures/kill-clear.json"
/bin/cat "$fixtures/dashboard-clean.json" "$fixtures/dashboard-clean.json" \
  > "$fixtures/multi-root.json"
expect_refusal multi-root E_PARSE "$fixtures/multi-root.json" \
  "$fixtures/ledger-clean.json" "$fixtures/kill-clear.json"
/usr/bin/printf '\357\273\277' > "$fixtures/bom.json"
/bin/cat "$fixtures/dashboard-clean.json" >> "$fixtures/bom.json"
expect_refusal bom E_PARSE "$fixtures/bom.json" "$fixtures/ledger-clean.json" \
  "$fixtures/kill-clear.json"
"$jq_bin" . "$fixtures/dashboard-clean.json" > "$fixtures/noncanonical.json"
expect_refusal noncanonical E_CANONICAL "$fixtures/noncanonical.json" \
  "$fixtures/ledger-clean.json" "$fixtures/kill-clear.json"
/usr/bin/awk 'BEGIN { for (i = 0; i < 1048577; i++) printf "x" }' > "$fixtures/huge.json"
expect_refusal oversized E_LIMIT "$fixtures/huge.json" "$fixtures/ledger-clean.json" \
  "$fixtures/kill-clear.json"
/bin/ln -s "$fixtures/dashboard-clean.json" "$fixtures/dashboard-link.json"
expect_refusal symlink-input E_RUNTIME "$fixtures/dashboard-link.json" \
  "$fixtures/ledger-clean.json" "$fixtures/kill-clear.json"
/usr/bin/mkfifo "$fixtures/dashboard.fifo"
expect_refusal nonregular-input E_RUNTIME "$fixtures/dashboard.fifo" \
  "$fixtures/ledger-clean.json" "$fixtures/kill-clear.json"
"$jq_bin" -S -c 'del(.body.recovery.stranded_recovered)' \
  "$fixtures/dashboard-clean.json" > "$fixtures/dashboard-missing.json"
expect_refusal missing-recovery-count E_SHAPE "$fixtures/dashboard-missing.json" \
  "$fixtures/ledger-clean.json" "$fixtures/kill-clear.json"
expect_refusal unsealed-ledger E_RELATION "$fixtures/dashboard-clean.json" \
  "$fixtures/ledger-refused-open.json" "$fixtures/kill-clear.json"
"$jq_bin" -S -c '.body.events[1].facts.status.value = "status.failed"' \
  "$fixtures/ledger-clean.json" > "$fixtures/ledger-tampered.json"
expect_refusal tampered-ledger E_RELATION "$fixtures/dashboard-clean.json" \
  "$fixtures/ledger-tampered.json" "$fixtures/kill-clear.json"
expect_refusal unknown-extra-document E_SHAPE "${clean[@]}" \
  "$fixtures/dashboard-clean.json"
/bin/cp "$fixtures/finding-critical.json" "$fixtures/finding-duplicate.json"
expect_refusal duplicate-finding E_RELATION "${clean[@]}" \
  "$fixtures/finding-critical.json" "$fixtures/finding-duplicate.json"
"$jq_bin" -S -c '.body.severity = "urgent"' "$fixtures/finding-critical.json" \
  > "$fixtures/finding-bad-severity.json"
expect_refusal unknown-severity E_SHAPE "${clean[@]}" \
  "$fixtures/finding-bad-severity.json"
"$jq_bin" -S -c '.body.path = "/etc/passwd"' "$fixtures/finding-critical.json" \
  > "$fixtures/finding-absolute-path.json"
expect_refusal absolute-finding-path E_SHAPE "${clean[@]}" \
  "$fixtures/finding-absolute-path.json"

# --- output directory and command surface ---------------------------------
busy="$tmp/busy"
/bin/mkdir -m 700 "$busy"
: > "$busy/leftover.json"
status=0
PATH="$bin:/usr/bin:/bin" "$scanner" scan "${clean[@]}" "$busy" \
  > "$tmp/busy.out" 2> "$tmp/busy.err" || status=$?
[ "$status" -ne 0 ] && [ ! -s "$tmp/busy.out" ] &&
  [ "$(/bin/cat "$tmp/busy.err")" = E_WORKSPACE ] &&
  [ "$(written_names "$busy")" = 'leftover.json ' ] || fail 'non-empty output dir'
pass 'a non-empty output directory is refused and left untouched'

status=0
PATH="$bin:/usr/bin:/bin" "$scanner" scan "${clean[@]}" "$tmp/absent-dir" \
  > "$tmp/absent.out" 2> "$tmp/absent.err" || status=$?
[ "$status" -ne 0 ] && [ "$(/bin/cat "$tmp/absent.err")" = E_WORKSPACE ] ||
  fail 'missing output dir'
pass 'a missing output directory is refused'

for bad_usage in validate scan; do
  status=0
  /bin/rm -rf -- "$tmp/usage-out"
  /bin/mkdir -m 700 "$tmp/usage-out"
  if [ "$bad_usage" = validate ]; then
    PATH="$bin:/usr/bin:/bin" "$scanner" validate "${clean[@]}" "$tmp/usage-out" \
      > "$tmp/usage.out" 2> "$tmp/usage.err" || status=$?
  else
    PATH="$bin:/usr/bin:/bin" "$scanner" scan "${clean[@]}" \
      > "$tmp/usage.out" 2> "$tmp/usage.err" || status=$?
  fi
  [ "$status" -ne 0 ] && [ ! -s "$tmp/usage.out" ] &&
    [ "$(/bin/cat "$tmp/usage.err")" = E_USAGE ] || fail "usage $bad_usage"
done
status=0
(cd "$fixtures" && PATH="$bin:/usr/bin:/bin" "$scanner" scan dashboard-clean.json \
  "$fixtures/ledger-clean.json" "$fixtures/kill-clear.json" "$tmp/run-in-band" \
  > "$tmp/relative.out" 2> "$tmp/relative.err") || status=$?
[ "$status" -ne 0 ] && [ "$(/bin/cat "$tmp/relative.err")" = E_USAGE ] ||
  fail 'relative input path'
pass 'the command surface is closed and every input path must be absolute'

moved="$tmp/moved"
/bin/mkdir -m 700 "$moved"
/bin/cp "$scanner" "$moved/scan.sh"
/bin/chmod 0555 "$moved/scan.sh"
status=0
/bin/mkdir -m 700 "$tmp/moved-out"
PATH="$bin:/usr/bin:/bin" "$moved/scan.sh" scan "${clean[@]}" "$tmp/moved-out" \
  > "$tmp/moved.out" 2> "$tmp/moved.err" || status=$?
[ "$status" -ne 0 ] && [ ! -s "$tmp/moved.out" ] &&
  [ "$(/bin/cat "$tmp/moved.err")" = E_RUNTIME ] || fail 'moved driver'
pass 'a driver copied out of its component directory refuses to run'

fake_bin="$tmp/fake-bin"
/bin/mkdir -m 700 "$fake_bin"
/usr/bin/printf '#!/bin/sh\n/usr/bin/touch %s\n/usr/bin/printf "jq-1.6\\n"\n' \
  "$tmp/fake-jq-ran" > "$fake_bin/jq"
/bin/chmod 0500 "$fake_bin/jq"
status=0
/bin/mkdir -m 700 "$tmp/fake-out"
PATH="$fake_bin:/usr/bin:/bin" "$scanner" scan "${clean[@]}" "$tmp/fake-out" \
  > "$tmp/fake.out" 2> "$tmp/fake.err" || status=$?
[ "$status" -ne 0 ] && [ ! -s "$tmp/fake.out" ] &&
  [ "$(/bin/cat "$tmp/fake.err")" = E_RUNTIME ] && [ ! -e "$tmp/fake-jq-ran" ] ||
  fail 'unverified jq'
pass 'an unverified jq is rejected without being executed'


# --- shipped incidents become eval seed cases -----------------------------
converter="$root/maintenance/v1/incident-to-eval.sh"
seed_set_file="$root/evals/v1/seed-set.json"

incident() {
  "$jq_bin" -S -c -n --arg id "$1" --arg kind "$2" '
    {schema_version:1,kind:"shadow_incident_record",id:$id,
     body:{deploy_authority:"none",target_repository_id:"repo.example",
       git_revision_ref:{repository_id:"repo.example",hash_algorithm:"sha1",
         commit_id:("1"*40)},
       failing_check:(if $kind == "file-digest"
         then {kind:"file-digest",path:"docs/components.md",expected_sha256:("a"*64)}
         else {kind:"named-check",check_id:"check.example"} end),
       observed_symptom:"The pinned document no longer matches its recorded digest.",
       reporter_actor_ref:"actor.example",observed_at:"2026-09-03T00:00:00Z"}}'
}
shadow_record() {
  "$jq_bin" -S -c -n --arg id "$1" --arg outcome "$2" --arg incident_sha "$3" \
    --slurpfile incident "$4" '
    {schema_version:1,kind:"shadow_reproduction_record",id:$id,
     body:{activation_state:"inactive",authority:"none",deploy_authority:"none",
       effects:["caller-disposable-candidate-repository"],
       evaluation_mode:"observation-only",shadow:true,
       qualification:{state:"unavailable",reason_id:"shadow.unqualified"},
       outcome:$outcome,reason_id:"check.failed-at-revision",
       observed_at:"2026-09-03T01:00:00Z",
       target_repository_id:$incident[0].body.target_repository_id,
       git_revision_ref:$incident[0].body.git_revision_ref,
       incident_ref:{content_id:"shadow-incident-record",
         media_type:"application/vnd.ystack.shadow-incident-record+json",
         sha256:$incident_sha},
       check:{failing_check:$incident[0].body.failing_check,
         execution:{state:"present",value:{tool_id:"tool.git-blob-digest",
           observed_sha256:("b"*64),matches_expected:false}}}}}'
}

incident incident.digest-drift file-digest > "$fixtures/incident-digest.json"
incident incident.named-check named-check > "$fixtures/incident-named.json"
digest_sha=$(sha_file "$fixtures/incident-digest.json")
named_sha=$(sha_file "$fixtures/incident-named.json")
shadow_record incident.digest-drift reproduced "$digest_sha" \
  "$fixtures/incident-digest.json" > "$fixtures/shadow-reproduced.json"
shadow_record incident.digest-drift no-change "$digest_sha" \
  "$fixtures/incident-digest.json" > "$fixtures/shadow-no-change.json"
shadow_record incident.digest-drift inconclusive "$digest_sha" \
  "$fixtures/incident-digest.json" > "$fixtures/shadow-inconclusive.json"
shadow_record incident.named-check reproduced "$named_sha" \
  "$fixtures/incident-named.json" > "$fixtures/shadow-named.json"
shadow_record incident.digest-drift reproduced "$named_sha" \
  "$fixtures/incident-digest.json" > "$fixtures/shadow-wrong-digest.json"

run_convert() {
  local name=$1
  shift
  RUN_DIR="$tmp/convert-$name"
  /bin/rm -rf -- "$RUN_DIR"
  /bin/mkdir -m 700 "$RUN_DIR"
  RUN_STATUS=0
  PATH="$bin:/usr/bin:/bin" "$converter" convert "$1" "$2" "$RUN_DIR" \
    > "$tmp/convert-$name.json" 2> "$tmp/convert-$name.err" || RUN_STATUS=$?
}
expect_convert() {
  local name=$1
  shift
  run_convert "$name" "$@"
  [ "$RUN_STATUS" -eq 0 ] && [ -s "$tmp/convert-$name.json" ] &&
    [ ! -s "$tmp/convert-$name.err" ] ||
    fail "convert $name (status $RUN_STATUS: $(/bin/cat "$tmp/convert-$name.err"))"
}
expect_convert_refusal() {
  local name=$1 expected=$2
  shift 2
  run_convert "$name" "$@"
  [ "$RUN_STATUS" -ne 0 ] && [ ! -s "$tmp/convert-$name.json" ] &&
    [ "$(/bin/cat "$tmp/convert-$name.err")" = "$expected" ] ||
    fail "convert refusal $name"
  [ -z "$(/usr/bin/find "$RUN_DIR" -mindepth 1 -print -quit)" ] ||
    fail "convert refusal $name wrote output"
  pass "$name is refused with $expected and writes nothing"
}

expect_convert reproduced "$fixtures/incident-digest.json" \
  "$fixtures/shadow-reproduced.json"
[ "$(written_names "$RUN_DIR")" = 'eval-seed-case-stale-moved-artifacts.json ' ] ||
  fail 'skeleton output set'
skeleton="$RUN_DIR/eval-seed-case-stale-moved-artifacts.json"
"$jq_bin" -e --arg incident "$digest_sha" '
  .schema_version == 1 and .kind == "maintenance_eval_seed_skeleton" and
  .body.activation_state == "inactive" and .body.authority == "none" and
  .body.deploy_authority == "none" and .body.seed_set_effect == "none" and
  .body.family_id == "stale-moved-artifacts" and
  .body.seed_source == "core.stage-run.v2" and
  .body.case.expectation == {disposition:"accepted",status:"stale"} and
  .body.case.request_role == "producer" and
  .body.case.case_id == "incident.incident.digest-drift" and
  .body.case_shape.required_fields ==
    ["case_id","expectation","family_id","request_role","result"] and
  .body.case_shape.pending_fields == ["result"] and
  .body.provenance.incident_ref.sha256 == $incident and
  .body.provenance.shadow_outcome == "reproduced"' "$skeleton" >/dev/null ||
  fail 'skeleton shape'
# The expectation must be one the family's own seed set already uses.
"$jq_bin" -e --slurpfile skeleton "$skeleton" '
  [.body.cases[] | select(.family_id == "stale-moved-artifacts") | .expectation] |
  index($skeleton[0].body.case.expectation) != null' "$seed_set_file" >/dev/null ||
  fail 'expectation not drawn from the seed set'
pass 'a reproduced incident becomes a seed case skeleton in its family shape'

expect_convert reproduced-repeat "$fixtures/incident-digest.json" \
  "$fixtures/shadow-reproduced.json"
/usr/bin/cmp -s "$tmp/convert-reproduced.json" "$tmp/convert-reproduced-repeat.json" ||
  fail 'repeat conversion differs'
/usr/bin/cmp -s "$skeleton" "$RUN_DIR/eval-seed-case-stale-moved-artifacts.json" ||
  fail 'repeat skeleton differs'
pass 'a repeated conversion is byte-identical'

expect_convert no-change "$fixtures/incident-digest.json" \
  "$fixtures/shadow-no-change.json"
"$jq_bin" -e '.body.case.expectation == {disposition:"accepted",status:"completed"}' \
  "$tmp/convert-no-change.json" >/dev/null || fail 'no-change expectation'
pass 'a run that reproduced nothing becomes the passing baseline expectation'

expect_convert_refusal family-unmatched E_FAMILY "$fixtures/incident-named.json" \
  "$fixtures/shadow-named.json"
expect_convert_refusal inconclusive-outcome E_RELATION \
  "$fixtures/incident-digest.json" "$fixtures/shadow-inconclusive.json"
expect_convert_refusal unbound-shadow E_RELATION "$fixtures/incident-digest.json" \
  "$fixtures/shadow-wrong-digest.json"
expect_convert_refusal crossed-incident E_RELATION "$fixtures/incident-named.json" \
  "$fixtures/shadow-reproduced.json"
expect_convert_refusal convert-malformed E_PARSE "$fixtures/broken.json" \
  "$fixtures/shadow-reproduced.json"
/bin/cat "$fixtures/incident-digest.json" "$fixtures/incident-digest.json" \
  > "$fixtures/incident-multi.json"
expect_convert_refusal convert-multi-root E_PARSE "$fixtures/incident-multi.json" \
  "$fixtures/shadow-reproduced.json"
"$jq_bin" . "$fixtures/incident-digest.json" > "$fixtures/incident-noncanonical.json"
expect_convert_refusal convert-noncanonical E_CANONICAL \
  "$fixtures/incident-noncanonical.json" "$fixtures/shadow-reproduced.json"
expect_convert_refusal convert-oversized E_LIMIT "$fixtures/huge.json" \
  "$fixtures/shadow-reproduced.json"
/bin/ln -s "$fixtures/incident-digest.json" "$fixtures/incident-link.json"
expect_convert_refusal convert-symlink E_RUNTIME "$fixtures/incident-link.json" \
  "$fixtures/shadow-reproduced.json"
/usr/bin/mkfifo "$fixtures/incident.fifo"
expect_convert_refusal convert-nonregular E_RUNTIME "$fixtures/incident.fifo" \
  "$fixtures/shadow-reproduced.json"

status=0
PATH="$bin:/usr/bin:/bin" "$converter" convert "$fixtures/incident-digest.json" \
  "$fixtures/shadow-reproduced.json" "$busy" > "$tmp/convert-busy.out" \
  2> "$tmp/convert-busy.err" || status=$?
[ "$status" -ne 0 ] && [ "$(/bin/cat "$tmp/convert-busy.err")" = E_WORKSPACE ] &&
  [ "$(written_names "$busy")" = 'leftover.json ' ] || fail 'convert output dir'
pass 'the converter refuses a non-empty output directory and leaves no seed set touched'

/bin/cp "$converter" "$moved/incident-to-eval.sh"
/bin/chmod 0555 "$moved/incident-to-eval.sh"
status=0
/bin/rm -rf -- "$tmp/moved-convert"
/bin/mkdir -m 700 "$tmp/moved-convert"
PATH="$bin:/usr/bin:/bin" "$moved/incident-to-eval.sh" convert \
  "$fixtures/incident-digest.json" "$fixtures/shadow-reproduced.json" \
  "$tmp/moved-convert" > "$tmp/moved-convert.out" 2> "$tmp/moved-convert.err" ||
  status=$?
[ "$status" -ne 0 ] && [ "$(/bin/cat "$tmp/moved-convert.err")" = E_RUNTIME ] ||
  fail 'moved converter'
pass 'a converter copied out of its component directory refuses to run'

status=0
PATH="$bin:/usr/bin:/bin" "$converter" rewrite "$fixtures/incident-digest.json" \
  "$fixtures/shadow-reproduced.json" "$tmp/moved-convert" > "$tmp/convert-usage.out" \
  2> "$tmp/convert-usage.err" || status=$?
[ "$status" -ne 0 ] && [ "$(/bin/cat "$tmp/convert-usage.err")" = E_USAGE ] ||
  fail 'converter usage'
seed_set_before=$(sha_file "$seed_set_file")
[ "$seed_set_before" = "$(sha_file "$seed_set_file")" ] || fail 'seed set changed'
pass 'the converter surface is closed and no seed set is ever modified'

/usr/bin/printf 'PASS: %s maintenance loop checks\n' "$passes"
