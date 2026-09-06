#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P) || exit 1
framework="$root/evals/v1/run-evals.sh"
launcher="$root/evals/v1/evals-launcher.sh"
catalog="$root/evals/v1/eval-catalog.json"
seed_set="$root/evals/v1/seed-set-duty.json"
evaluator="$root/control/v1/evaluate-duty.sh"
manifest="$root/ci/required-files.txt"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-evals-duty-test.XXXXXX") || exit 1
download=''
cleanup() {
  if [ -n "$download" ] && [ -f "$download" ]; then /bin/rm -f -- "$download"; fi
  /bin/rm -rf -- "$tmp"
}
trap cleanup EXIT
fail() { /usr/bin/printf 'not ok - %s\n' "$1" >&2; exit 1; }
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
if [ ! -f "$jq_cache" ] || [ "$(sha_file "$jq_cache")" != "$jq_sha" ]; then
  download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$download" ||
    fail 'jq download'
  [ "$(sha_file "$download")" = "$jq_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_cache"
  download=''
fi
/bin/mkdir -m 700 "$tmp/bin"
/bin/cp "$jq_cache" "$tmp/bin/jq"
/bin/chmod 0555 "$tmp/bin/jq"
jq_bin="$tmp/bin/jq"
[ "$("$jq_bin" --version)" = jq-1.6 ] || fail 'jq identity'

# --- shipped seed set: canonical, listed, and the family names its source -------
[ -f "$seed_set" ] && [ ! -L "$seed_set" ] || fail 'duty seed set missing'
"$jq_bin" -S -c . "$seed_set" > "$tmp/canonical.json" || fail 'seed set parse'
/usr/bin/cmp -s "$seed_set" "$tmp/canonical.json" || fail 'seed set not canonical'
for path in evals/v1/seed-set-duty.json scripts/test/evals-duty.test.sh; do
  /usr/bin/grep -qxF "$path" "$manifest" || fail "manifest missing $path"
done
"$jq_bin" -e '
  .body.seed_source == "control.duty-separation.v1" and .body.shared == {} and
  (.body.cases | length) == 10 and
  all(.body.cases[]; .family_id == "actor-rerun-identity" and
      (.inputs | keys) == ["policy_set","request","resolved_profile","result"])
' "$seed_set" > /dev/null || fail 'seed set header'
"$jq_bin" -e '
  .body.families[] | select(.family_id == "actor-rerun-identity") |
  .seed_status == "seeded" and .seed_sources == ["control.duty-separation.v1"]
' "$catalog" > /dev/null || fail 'catalog does not name the duty-separation source'
pass 'duty seed set is canonical, listed, and its catalog family names the duty-separation source'

for member in evaluate-duty.sh duty-separation-policy.json duty-separation-decision.json \
  duty-separation.jq validate.sh policy-set.jq; do
  /usr/bin/grep -qF "'$member $(sha_file "$root/control/v1/$member")'" "$launcher" ||
    fail "launcher does not pin control/v1/$member"
done
pass 'launcher pins the shipped duty-separation evaluator closure by digest'

# --- one deterministic pass through the real evaluator ---------------------------
observed_at=2026-09-05T00:00:00Z
run_framework() {
  local out=$1 err=$2 seed=$3
  "$framework" run "$seed" "$observed_at" >"$out" 2>"$err"
}
first="$tmp/first.json"
run_framework "$first" "$tmp/first.err" "$seed_set" || fail "framework run failed: $(<"$tmp/first.err")"
[ ! -s "$tmp/first.err" ] || fail 'framework wrote to stderr on success'
"$jq_bin" -e --arg seed_sha "$(sha_file "$seed_set")" --arg evaluator_sha "$(sha_file "$evaluator")" '
  .kind == "eval_run_result" and .id == "evals.run.evals.seed.control-duty.v1" and
  .body.seed_source == "control.duty-separation.v1" and
  .body.seed_set_ref.sha256 == $seed_sha and
  .body.summary == {total:10,passed:10,failed:0,inconclusive:0} and
  all(.body.cases[]; .verdict == "passed" and .grader_kind == "deterministic" and
      .subject_ref.kind == "stage_result" and .subject_ref.schema_version == 2) and
  all(.body.trace[]; .grader_kind == "deterministic" and
      .tool_ref == {content_id:"control-evaluator-driver.duty-separation.v1",
                    media_type:"text/x-shellscript",sha256:$evaluator_sha} and
      .adapter == {state:"absent"} and .latency == {state:"absent"} and .cost == {state:"absent"}) and
  (.body.evaluator.content.body.control_closure | length) == 14
' "$first" > /dev/null || fail 'run result shape or verdicts'
pass 'all ten identity cases pass through the real duty-separation evaluator'

"$jq_bin" -e '
  def evaluated($id): .body.cases[] | select(.case_id == $id) | .observation.value.evaluation.value;
  def refused($id): .body.cases[] | select(.case_id == $id) | .observation.value.error_token.value;
  evaluated("identity.satisfied-baseline") ==
    {verdict:"satisfied",reason_ids:["duty.satisfied"]} and
  evaluated("identity.skipped-stage-satisfied") ==
    {verdict:"satisfied",reason_ids:["duty.satisfied"]} and
  evaluated("identity.requester-role-denied-violated") ==
    {verdict:"violated",reason_ids:["requester.role-denied"]} and
  evaluated("identity.unclassified-capability-inconclusive") ==
    {verdict:"inconclusive",reason_ids:["actual.capability-unclassified"]} and
  evaluated("identity.actual-execution-kind-mismatch-violated") ==
    {verdict:"violated",
     reason_ids:["actual.execution-kind-mismatch","actual.permissions-mismatch"]} and
  evaluated("identity.reporter-role-mismatch-violated") ==
    {verdict:"violated",reason_ids:["reporter.role-mismatch"]} and
  evaluated("identity.actual-capability-mismatch-violated") ==
    {verdict:"violated",reason_ids:["actual.capability-mismatch"]} and
  refused("identity.policy-identity-rejected") == "E_RELATION" and
  refused("identity.producer-ceiling-rejected") == "E_CORE" and
  refused("identity.protected-collision-rejected") == "E_CORE"
' "$first" > /dev/null || fail 'identity verdicts or reasons misrecorded'
pass 'a denied requester role, a wrong execution kind, a mismatched reporter or capability is violated; an unclassified capability is only inconclusive'

second="$tmp/second.json"
run_framework "$second" "$tmp/second.err" "$seed_set" || fail 'second run failed'
/usr/bin/cmp -s "$first" "$second" || fail 'repeat run differs'
[ "$("$jq_bin" -S -c . "$first")" = "$(<"$first")" ] || fail 'output not canonical'
pass 'repeat run is byte-identical and canonical'

"$jq_bin" -e '
  ([.. | objects | keys[] | select(. == "authority" or . == "permissions" or
    . == "capabilities" or . == "credential" or . == "network" or . == "execute" or
    . == "schedule" or . == "merge" or . == "publish")] | length) == 0
' "$first" > /dev/null || fail 'authority or effect field present'
pass 'inactive data-only boundary holds for duty-separation replays'

# --- grading is honest --------------------------------------------------------------
wrong="$tmp/wrong.json"
"$jq_bin" -S -c '
  .body.cases |= map(if .case_id == "identity.unclassified-capability-inconclusive"
    then .expectation.verdict = "violated" | .expectation.reason_ids = ["requester.role-denied"]
    else . end)
' "$seed_set" > "$wrong"
run_framework "$tmp/wrong.out" "$tmp/wrong.err" "$wrong" || fail 'wrong-expectation run errored'
"$jq_bin" -e '
  .body.summary == {total:10,passed:9,failed:1,inconclusive:0} and
  (.body.cases[] | select(.case_id == "identity.unclassified-capability-inconclusive") |
    .verdict == "failed" and .reason_id == "evals.verdict-mismatch")
' "$tmp/wrong.out" > /dev/null || fail 'an unclassified capability expected as violated was not failed'
partial="$tmp/partial.json"
"$jq_bin" -S -c '
  .body.cases |= map(if .case_id == "identity.actual-execution-kind-mismatch-violated"
    then .expectation.reason_ids = ["actual.execution-kind-mismatch"] else . end)
' "$seed_set" > "$partial"
run_framework "$tmp/partial.out" "$tmp/partial.err" "$partial" || fail 'partial-reason run errored'
"$jq_bin" -e '
  .body.cases[] | select(.case_id == "identity.actual-execution-kind-mismatch-violated") |
  .verdict == "failed" and .reason_id == "evals.verdict-mismatch"
' "$tmp/partial.out" > /dev/null || fail 'an incomplete reason set was accepted'
pass 'a wrong verdict or an incomplete reason set is graded failed, never silently passed'

# --- fail closed on bad, moved, or misfiled input ----------------------------------
expect_error() {
  local name=$1 expected=$2 seed=$3 out err status
  out="$tmp/$name.out"; err="$tmp/$name.err"
  "$framework" run "$seed" "$observed_at" >"$out" 2>"$err"
  status=$?
  [ "$status" -ne 0 ] && [ ! -s "$out" ] && [ "$(<"$err")" = "$expected" ] ||
    fail "$name expected $expected, got status $status [$(<"$err")]"
}
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "identity.satisfied-baseline"
  then .inputs.result.sha256 = ("f" * 64) else . end)' "$seed_set" > "$tmp/moved.json"
expect_error moved-result-digest E_RELATION "$tmp/moved.json"
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "identity.satisfied-baseline"
  then .family_id = "protected-path-credential-network-publisher-boundaries" else . end)' \
  "$seed_set" > "$tmp/misfiled.json"
expect_error family-without-duty-source E_SHAPE "$tmp/misfiled.json"
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "identity.producer-ceiling-rejected"
  then .expectation.error_token = "E_DUTY" else . end)' "$seed_set" > "$tmp/badtoken.json"
expect_error token-from-another-evaluator E_SHAPE "$tmp/badtoken.json"
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "identity.satisfied-baseline"
  then .inputs.request.content.kind = "stage_result" else . end)' "$seed_set" > "$tmp/badkind.json"
expect_error wrong-input-kind E_SHAPE "$tmp/badkind.json"
pass 'moved, misfiled, and mis-shaped duty seed sets fail closed with one token'

# --- the launcher refuses an edited evaluator ---------------------------------------
copy="$tmp/copy"
/bin/mkdir -p "$copy/evals/v1" "$copy/core/v2" "$copy/scripts"
/bin/cp -R "$root/core/v2/." "$copy/core/v2/"
/bin/cp "$root/scripts/core-contract.sh" "$copy/scripts/core-contract.sh"
# Every component the launcher stages is present, so the edit below is the
# only stale thing in this fixture.
for component in orchestrator/v1 control/v1 adapters; do
  /bin/mkdir -p "$copy/$component" && /bin/cp -R "$root/$component/." "$copy/$component/"
done
for f in run-evals.sh evals-launcher.sh evals-driver.sh evals.jq eval-catalog.json; do
  /bin/cp "$root/evals/v1/$f" "$copy/evals/v1/$f"
done
/usr/bin/printf '\n# tampered\n' >> "$copy/control/v1/duty-separation.jq"
if "$copy/evals/v1/run-evals.sh" run "$seed_set" "$observed_at" >"$tmp/stale.out" 2>"$tmp/stale.err"; then
  fail 'edited evaluator was accepted'
fi
[ ! -s "$tmp/stale.out" ] && [ "$(<"$tmp/stale.err")" = E_STALE ] ||
  fail "edited evaluator was not refused: [$(<"$tmp/stale.err")]"
pass 'an edited duty-separation evaluator is refused as stale before anything runs'

/usr/bin/printf '1..%s\n' "$passes"
