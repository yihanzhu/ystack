#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P) || exit 1
framework="$root/evals/v1/run-evals.sh"
launcher="$root/evals/v1/evals-launcher.sh"
catalog="$root/evals/v1/eval-catalog.json"
seed_set="$root/evals/v1/seed-set-approvals.json"
evaluator="$root/control/v1/evaluate-risk-gates.sh"
manifest="$root/ci/required-files.txt"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-evals-approvals-test.XXXXXX") || exit 1
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
[ -f "$seed_set" ] && [ ! -L "$seed_set" ] || fail 'approvals seed set missing'
"$jq_bin" -S -c . "$seed_set" > "$tmp/canonical.json" || fail 'seed set parse'
/usr/bin/cmp -s "$seed_set" "$tmp/canonical.json" || fail 'seed set not canonical'
for path in evals/v1/seed-set-approvals.json scripts/test/evals-approvals.test.sh; do
  /usr/bin/grep -qxF "$path" "$manifest" || fail "manifest missing $path"
done
"$jq_bin" -e '
  .body.seed_source == "control.risk-gates.v1" and .body.shared == {} and
  (.body.cases | length) == 16 and
  all(.body.cases[]; .family_id == "approval-invalidation-no-push-after-approval" and
      (.inputs | keys) == ["claim","duty","policy_set","request","resolved_profile","result"])
' "$seed_set" > /dev/null || fail 'seed set header'
"$jq_bin" -e '
  .body.families[] |
  select(.family_id == "approval-invalidation-no-push-after-approval") |
  .seed_status == "seeded" and .seed_sources == ["control.risk-gates.v1"]
' "$catalog" > /dev/null || fail 'catalog does not name the risk-gates source'
pass 'approvals seed set is canonical, listed, and its catalog family names the risk-gates source'

for member in evaluate-risk-gates.sh risk-gates-policy.json risk-gates-decision.json risk-gates.jq \
  duty-separation-policy.json duty-separation-decision.json duty-separation.jq evaluate-duty.sh; do
  /usr/bin/grep -qF "'$member $(sha_file "$root/control/v1/$member")'" "$launcher" ||
    fail "launcher does not pin control/v1/$member"
done
pass 'launcher pins the shipped risk-gates and duty-separation evaluator closure by digest'

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
  .kind == "eval_run_result" and .id == "evals.run.evals.seed.control-approvals.v1" and
  .body.seed_source == "control.risk-gates.v1" and
  .body.seed_set_ref.sha256 == $seed_sha and
  .body.summary == {total:16,passed:16,failed:0,inconclusive:0} and
  all(.body.cases[]; .verdict == "passed" and .grader_kind == "deterministic" and
      .subject_ref.kind == "risk_gate_decision_claim") and
  all(.body.trace[]; .grader_kind == "deterministic" and
      .tool_ref == {content_id:"control-evaluator-driver.risk-gates.v1",
                    media_type:"text/x-shellscript",sha256:$evaluator_sha} and
      .adapter == {state:"absent"} and .latency == {state:"absent"} and .cost == {state:"absent"}) and
  (.body.evaluator.content.body.control_closure | length) == 14
' "$first" > /dev/null || fail 'run result shape or verdicts'
pass 'all sixteen approval cases pass through the real risk-gates evaluator'

"$jq_bin" -e '
  def evaluated($id): .body.cases[] | select(.case_id == $id) | .observation.value.evaluation.value;
  def refused($id): .body.cases[] | select(.case_id == $id) | .observation.value.error_token.value;
  evaluated("approval.request-moved-after-decision-violated") ==
    {verdict:"violated",reason_ids:["decision.stale","decision.unbound"]} and
  evaluated("approval.decision-after-request-violated") ==
    {verdict:"violated",reason_ids:["decision.after-request"]} and
  evaluated("approval.missing-decision-violated").reason_ids == ["decision.missing"] and
  evaluated("approval.rejected-decision-violated").reason_ids == ["decision.rejected"] and
  evaluated("approval.tier-downgrade-violated").reason_ids == ["risk.tier-downgrade"] and
  evaluated("approval.reviewer-cannot-approve-high-violated").reason_ids ==
    ["decision.actor-unbound","decision.role-denied"] and
  evaluated("approval.ambiguous-claims-violated").reason_ids == ["decision.ambiguous"] and
  evaluated("approval.duty-violation-violated").reason_ids == ["duty.violated"] and
  evaluated("approval.routine-independent-check-unqualified") ==
    {verdict:"inconclusive",reason_ids:["decision.provenance-unqualified"]} and
  evaluated("approval.high-operator-approval-unqualified").verdict == "inconclusive" and
  refused("approval.forged-duty-rejected") == "E_DUTY"
' "$first" > /dev/null || fail 'approval verdicts or reasons misrecorded'
pass 'a moved request, a late, missing, rejected, downgraded, misrolled, or ambiguous decision is violated; an honest accept is only inconclusive'

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
pass 'inactive data-only boundary holds for risk-gates replays'

# --- grading is honest --------------------------------------------------------------
wrong="$tmp/wrong.json"
"$jq_bin" -S -c '
  .body.cases |= map(if .case_id == "approval.routine-independent-check-unqualified"
    then .expectation.verdict = "violated" | .expectation.reason_ids = ["decision.missing"]
    else . end)
' "$seed_set" > "$wrong"
run_framework "$tmp/wrong.out" "$tmp/wrong.err" "$wrong" || fail 'wrong-expectation run errored'
"$jq_bin" -e '
  .body.summary == {total:16,passed:15,failed:1,inconclusive:0} and
  (.body.cases[] | select(.case_id == "approval.routine-independent-check-unqualified") |
    .verdict == "failed" and .reason_id == "evals.verdict-mismatch")
' "$tmp/wrong.out" > /dev/null || fail 'an unqualified accept expected as violated was not failed'
partial="$tmp/partial.json"
"$jq_bin" -S -c '
  .body.cases |= map(if .case_id == "approval.request-moved-after-decision-violated"
    then .expectation.reason_ids = ["decision.stale"] else . end)
' "$seed_set" > "$partial"
run_framework "$tmp/partial.out" "$tmp/partial.err" "$partial" || fail 'partial-reason run errored'
"$jq_bin" -e '
  .body.cases[] | select(.case_id == "approval.request-moved-after-decision-violated") |
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
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "approval.missing-decision-violated"
  then .inputs.claim.sha256 = ("f" * 64) else . end)' "$seed_set" > "$tmp/moved.json"
expect_error moved-claim-digest E_RELATION "$tmp/moved.json"
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "approval.missing-decision-violated"
  then .family_id = "protected-path-credential-network-publisher-boundaries" else . end)' \
  "$seed_set" > "$tmp/misfiled.json"
expect_error family-without-risk-gates-source E_SHAPE "$tmp/misfiled.json"
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "approval.forged-duty-rejected"
  then .expectation.error_token = "E_POLICY_SET" else . end)' "$seed_set" > "$tmp/badtoken.json"
expect_error token-from-another-evaluator E_SHAPE "$tmp/badtoken.json"
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "approval.missing-decision-violated"
  then .inputs.request.content.kind = "stage_result" else . end)' "$seed_set" > "$tmp/badkind.json"
expect_error wrong-input-kind E_SHAPE "$tmp/badkind.json"
# The risk-gates evaluator has no satisfied verdict, so a seed claiming one is refused.
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "approval.routine-independent-check-unqualified"
  then .expectation.verdict = "satisfied" else . end)' "$seed_set" > "$tmp/satisfied.json"
expect_error satisfied-verdict-claimed E_SHAPE "$tmp/satisfied.json"
pass 'moved, misfiled, and mis-shaped approval seed sets fail closed with one token'

# --- the launcher refuses an edited evaluator ---------------------------------------
copy="$tmp/copy"
/bin/mkdir -p "$copy/evals/v1" "$copy/core/v2" "$copy/scripts" "$copy/orchestrator/v1" \
  "$copy/control/v1"
/bin/cp -R "$root/core/v2/." "$copy/core/v2/"
/bin/cp "$root/scripts/core-contract.sh" "$copy/scripts/core-contract.sh"
for f in run-evals.sh evals-launcher.sh evals-driver.sh evals.jq eval-catalog.json; do
  /bin/cp "$root/evals/v1/$f" "$copy/evals/v1/$f"
done
for f in scan-state.sh state-scanner-launcher.sh state-scanner-driver.sh state-scanner.jq \
  reconciliation-plan.jq; do
  /bin/cp "$root/orchestrator/v1/$f" "$copy/orchestrator/v1/$f"
done
for f in evaluate-sandbox.sh policy-set.jq sandbox-decision.json sandbox-policy.json \
  sandbox.jq validate.sh evaluate-risk-gates.sh risk-gates-policy.json risk-gates-decision.json \
  risk-gates.jq duty-separation-policy.json duty-separation-decision.json duty-separation.jq \
  evaluate-duty.sh; do
  /bin/cp "$root/control/v1/$f" "$copy/control/v1/$f"
done
for name in codex-native-reviewer github-actions-ci github-forge; do
  /bin/mkdir -p "$copy/adapters/$name/v1"
  /bin/cp "$root/adapters/$name/v1/normalize.jq" "$copy/adapters/$name/v1/normalize.jq"
done
/usr/bin/printf '\n# tampered\n' >> "$copy/control/v1/risk-gates.jq"
if "$copy/evals/v1/run-evals.sh" run "$seed_set" "$observed_at" >"$tmp/stale.out" 2>"$tmp/stale.err"; then
  fail 'edited evaluator was accepted'
fi
[ ! -s "$tmp/stale.out" ] && [ "$(<"$tmp/stale.err")" = E_STALE ] ||
  fail "edited evaluator was not refused: [$(<"$tmp/stale.err")]"
pass 'an edited risk-gates evaluator is refused as stale before anything runs'

/usr/bin/printf '1..%s\n' "$passes"
