#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

if [ "${YSTACK_SCOPE_TEST_BOUNDED:-0}" != 1 ]; then
  YSTACK_SCOPE_TEST_BOUNDED=1 exec /usr/bin/perl -e 'alarm 300; exec @ARGV' "$0"
fi

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
validator="$root/scope/v1/validate-scope.sh"
evaluator="$root/scope/v1/evaluate-scope.sh"
policy="$root/scope/v1/scope-policy.json"
record_program="$root/scope/v1/workflow-scope.jq"
gate_program="$root/scope/v1/scope-gates.jq"
repo_marker="$root/config/construction-mode.json"

fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-scope-test.XXXXXX")
cleanup() { /bin/rm -rf -- "$tmp" >/dev/null 2>&1 || :; }
trap cleanup EXIT

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*)
    jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    ;;
  Linux:x86_64)
    jq_asset=jq-linux64
    jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44
    ;;
  *) fail "unsupported host $platform" ;;
esac
# This suite bootstraps the pinned jq 1.6 cache itself so it never depends on an
# earlier suite having filled it.
jq_cache_dir="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$jq_cache_dir"
jq_cache="$jq_cache_dir/$jq_asset"
if [ ! -f "$jq_cache" ] || [ -L "$jq_cache" ] ||
   [ "$(sha256_path "$jq_cache")" != "$jq_sha" ]; then
  download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$download"
  [ "$(sha256_path "$download")" = "$jq_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_cache"
fi
bin="$tmp/bin"
/bin/mkdir -m 700 "$bin"
/bin/cp "$jq_cache" "$bin/jq"
/bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"
[ "$("$jq_bin" --version)" = jq-1.6 ] || fail 'jq identity'

run_validator() { PATH="$bin:/usr/bin:/bin" "$validator" validate "$1"; }
run_evaluator() { PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate "$@"; }
expect_validator_error() {
  local label=$1 expected=$2 input=$3 status=0 out
  out=$(run_validator "$input" 2>&1 >/dev/null) || status=$?
  [ "$status" -ne 0 ] || fail "$label accepted"
  [ "$out" = "$expected" ] || fail "$label expected $expected got $out"
}
evaluation_reasons() {
  local out
  out=$(run_evaluator "$@") || fail 'evaluator refused a well-formed call'
  /usr/bin/printf '%s' "$out" | "$jq_bin" -c '.body.reason_ids'
}
expect_reasons() {
  local label=$1 expected=$2
  shift 2
  local actual
  actual=$(evaluation_reasons "$@")
  [ "$actual" = "$expected" ] || fail "$label expected $expected got $actual"
}
expect_evaluator_error() {
  local label=$1 expected=$2 status=0 out
  shift 2
  out=$(run_evaluator "$@" 2>&1 >/dev/null) || status=$?
  [ "$status" -ne 0 ] || fail "$label accepted"
  [ "$out" = "$expected" ] || fail "$label expected $expected got $out"
}

for shipped in "$policy" "$record_program" "$gate_program" "$validator" "$evaluator"; do
  [ -f "$shipped" ] && [ ! -L "$shipped" ] || fail "missing $shipped"
done
[ -x "$validator" ] && [ -x "$evaluator" ] || fail 'drivers must be executable'
"$jq_bin" -S -c . "$policy" >"$tmp/policy-canonical.json"
/usr/bin/cmp -s "$policy" "$tmp/policy-canonical.json" || fail 'policy is not canonical'
generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" "$root/scripts/core-contract.sh")
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || fail 'selected generation shape'
for source_path in scope/v1/scope-policy.json scope/v1/workflow-scope.jq \
  scope/v1/scope-gates.jq scope/v1/validate-scope.sh scope/v1/evaluate-scope.sh \
  scripts/test/scope-qualification.test.sh; do
  ! /usr/bin/grep -Fq "$generation" "$root/$source_path" ||
    fail "raw generation id in $source_path"
done
"$jq_bin" -e '
  .kind == "scope_qualification_policy" and .body.activation_state == "inactive" and
  .body.authority == "none" and .body.fail_mode == "closed" and
  .body.proposable_risk_tiers == ["routine"]
' "$policy" >/dev/null || fail 'policy contract'
pass 'the shipped gate policy is canonical, inactive, and routine-only'

scope_record() {
  "$jq_bin" -S -c -n '
    {schema_version:1,kind:"workflow_scope",id:"scope.docs-typo-fix.v1",
     body:{activation_state:"inactive",authority:"none",enabled:false,
       push_allowed:false,scope_version:"v1",
       target_repository_id:"repo.fixture-target",
       workflow_id:"workflow.docs-typo-fix",task_class:"task.docs-typo-fix",
       risk_tier:"routine",allowed_paths:["docs/guides/setup.md","docs/notes-?.md"],
       required_proof_kinds:["deterministic","independent-review"],
       required_eval_families:["protected-path-credential-network-publisher-boundaries",
         "stale-moved-artifacts"],
       required_shadow_environments:["env.ci-linux-fixture","env.local-macos-fixture"],
       max_attempts:2}}'
}
scope_record >"$tmp/scope.json"

"$jq_bin" -S -c -n '
  def record($id;$environment;$outcome;$repository):
    {schema_version:1,kind:"shadow_reproduction_record",id:$id,
     body:{activation_state:"inactive",authority:"none",deploy_authority:"none",
       effects:["caller-disposable-candidate-repository"],
       evaluation_mode:"observation-only",shadow:true,
       qualification:{state:"unavailable",reason_id:"shadow.unqualified"},
       outcome:$outcome,reason_id:"check.passed-at-revision",
       observed_at:"2026-09-05T00:00:00Z",target_repository_id:$repository,
       environment:{environment_id:$environment}}};
  {schema_version:1,kind:"shadow_evidence_set",
   id:"scope.evidence.docs-typo-fix.v1",
   body:{records:[
     record("shadow.docs-typo-fix.local";"env.local-macos-fixture";"reproduced";
       "repo.fixture-target"),
     record("shadow.docs-typo-fix.ci";"env.ci-linux-fixture";"no-change";
       "repo.fixture-target")]}}' >"$tmp/shadow-set.json"

"$jq_bin" -S -c -n '
  def family($id;$status;$total;$failed;$inconclusive):
    {family_id:$id,seed_status:$status,seed_sources:[],
     grader_kinds:["deterministic"],trial_policy:{kind:"single"},runs:1,
     cases:{total:$total,passed:($total - $failed - $inconclusive),
       failed:$failed,inconclusive:$inconclusive}};
  {schema_version:1,kind:"eval_dashboard",id:"evals.dashboard.v1",
   body:{activation_state:"inactive",authority_effect:"none",
     mode:"deterministic-offline",
     families:[
       family("actor-rerun-identity";"seeded";4;0;0),
       family("adapter-contract-compliance";"seeded";4;0;0),
       family("approval-invalidation-no-push-after-approval";"seeded";4;0;0),
       family("empty-fake-timed-out-degraded-reviews";"seeded";4;0;0),
       family("malicious-instructions";"declared";0;0;0),
       family("protected-path-credential-network-publisher-boundaries";"seeded";6;0;0),
       family("repeated-cancelled-missed-events";"seeded";5;0;0),
       family("reviewer-severity-false-positive-negative";"declared";0;0;0),
       family("stale-moved-artifacts";"seeded";7;0;0)]}}' >"$tmp/dashboard.json"

"$jq_bin" -S -c -n '
  {schema_version:1,kind:"risk_gate_evaluation",id:"stage.docs-typo-fix.result",
   body:{activation_state:"inactive",authority_effect:"none",
     classification:{declared_tier:"routine",minimum_tier:"routine"},
     evaluation_mode:"observation-only",reference_semantics:"identity-only",
     verdict:"inconclusive",
     reason_ids:["decision.provenance-unqualified"]}}' >"$tmp/risk.json"
"$jq_bin" -S -c -n '
  {schema_version:1,kind:"kill_switch_evaluation",
   id:"kill-attempt.docs-typo-fix",
   body:{activation_state:"inactive",authority_effect:"none",
     evaluation_mode:"observation-only",reference_semantics:"identity-only",
     verdict:"satisfied",reason_ids:["kill.cleared-current"]}}' >"$tmp/kill.json"
"$jq_bin" -S -c -n '
  {schema_version:1,kind:"duty_separation_evaluation",
   id:"stage.docs-typo-fix.result",
   body:{activation_state:"inactive",evaluation_mode:"observation-only",
     reference_semantics:"identity-only",verdict:"satisfied",
     reason_ids:["duty.satisfied"]}}' >"$tmp/duty.json"
/bin/cp "$repo_marker" "$tmp/marker.json"

good=("$tmp/scope.json" "$tmp/shadow-set.json" "$tmp/dashboard.json" "$tmp/risk.json"
  "$tmp/kill.json" "$tmp/duty.json" "$tmp/marker.json")

run_validator "$tmp/scope.json" || fail 'the routine fixture scope was refused'
pass 'the record validator accepts a well-formed routine workflow scope'

mutate_scope() { "$jq_bin" -S -c "$1" "$tmp/scope.json" >"$2"; }
mutate_scope '.body.enabled = true' "$tmp/bad-enabled.json"
mutate_scope '.body.push_allowed = true' "$tmp/bad-push.json"
mutate_scope '.body.workflow_id = "wf.docs"' "$tmp/bad-workflow.json"
mutate_scope '.body.task_class = "docs"' "$tmp/bad-task.json"
mutate_scope '.body.scope_version = "v2"' "$tmp/bad-version.json"
mutate_scope '.body.activation_state = "active"' "$tmp/bad-active.json"
mutate_scope '.body.max_attempts = 0' "$tmp/bad-attempts.json"
mutate_scope '.body.risk_tier = "elevated"' "$tmp/bad-tier.json"
mutate_scope '.body.allowed_paths = ["/etc/passwd"]' "$tmp/bad-absolute.json"
mutate_scope '.body.allowed_paths = ["../outside.md"]' "$tmp/bad-traversal.json"
mutate_scope '.body.allowed_paths = ["docs/**/x.md"]' "$tmp/bad-doublestar.json"
mutate_scope '.body.allowed_paths = ["*/x.md"]' "$tmp/bad-firstwild.json"
mutate_scope '.body.allowed_paths = [".git/config"]' "$tmp/bad-git.json"
mutate_scope '.body.allowed_paths = ["docs\\x.md"]' "$tmp/bad-backslash.json"
mutate_scope '.body.allowed_paths = ["docs/a.md","docs/a.md"]' "$tmp/bad-duplicate.json"
mutate_scope '.body.required_eval_families = ["not-a-family"]' "$tmp/bad-family.json"
mutate_scope '.body.required_proof_kinds = ["vibes"]' "$tmp/bad-proof.json"
mutate_scope '.body.extra = true' "$tmp/bad-extra.json"
mutate_scope 'del(.body.max_attempts)' "$tmp/bad-missing.json"
mutate_scope '.kind = "other_record"' "$tmp/bad-kind.json"
for case_name in bad-attempts bad-tier bad-absolute bad-traversal bad-doublestar \
  bad-firstwild bad-git bad-backslash bad-duplicate bad-family bad-proof bad-extra \
  bad-missing bad-kind; do
  expect_validator_error "$case_name" E_SHAPE "$tmp/$case_name.json"
done
for case_name in bad-enabled bad-push bad-workflow bad-task bad-version bad-active; do
  expect_validator_error "$case_name" E_RELATION "$tmp/$case_name.json"
done
pass 'the record validator refuses every malformed or authority-claiming scope'

"$jq_bin" -S . "$tmp/scope.json" >"$tmp/pretty.json"
expect_validator_error non-canonical E_CANONICAL "$tmp/pretty.json"
{ /bin/cat "$tmp/scope.json"; /bin/cat "$tmp/scope.json"; } >"$tmp/multi-root.json"
expect_validator_error multi-root E_PARSE "$tmp/multi-root.json"
/usr/bin/printf '\357\273\277' >"$tmp/bom.json"
/bin/cat "$tmp/scope.json" >>"$tmp/bom.json"
expect_validator_error bom E_PARSE "$tmp/bom.json"
{
  /usr/bin/printf '{"body":{"note":"'
  /usr/bin/head -c 1100000 /dev/zero | /usr/bin/tr '\0' 'a'
  /usr/bin/printf '"},"id":"scope.big.v1","kind":"workflow_scope","schema_version":1}\n'
} >"$tmp/oversized.json"
expect_validator_error oversized E_LIMIT "$tmp/oversized.json"
/bin/ln -s "$tmp/scope.json" "$tmp/symlink.json"
expect_validator_error symlink E_RUNTIME "$tmp/symlink.json"
expect_validator_error absent E_RUNTIME "$tmp/does-not-exist.json"
pass 'the record validator fails closed on bad, oversized, multi-root, and symlink input'

run_evaluator "${good[@]}" >"$tmp/evaluation.json"
run_evaluator "${good[@]}" >"$tmp/evaluation-repeat.json"
/usr/bin/cmp -s "$tmp/evaluation.json" "$tmp/evaluation-repeat.json" ||
  fail 'the evaluation is not byte-identical on repeat'

policy_sha=$(sha256_path "$policy")
scope_sha=$(sha256_path "$tmp/scope.json")
shadow_set_sha=$(sha256_path "$tmp/shadow-set.json")
dashboard_sha=$(sha256_path "$tmp/dashboard.json")
risk_sha=$(sha256_path "$tmp/risk.json")
kill_sha=$(sha256_path "$tmp/kill.json")
duty_sha=$(sha256_path "$tmp/duty.json")
marker_sha=$(sha256_path "$tmp/marker.json")
record_sha() {
  "$jq_bin" -S -c --argjson i "$1" '.body.records[$i]' "$tmp/shadow-set.json" \
    >"$tmp/record.json"
  sha256_path "$tmp/record.json"
}
record_0_sha=$(record_sha 0)
record_1_sha=$(record_sha 1)

"$jq_bin" -S -c -n \
  --arg policy_sha "$policy_sha" --arg scope_sha "$scope_sha" \
  --arg shadow_set_sha "$shadow_set_sha" --arg dashboard_sha "$dashboard_sha" \
  --arg risk_sha "$risk_sha" --arg kill_sha "$kill_sha" --arg duty_sha "$duty_sha" \
  --arg marker_sha "$marker_sha" --arg record_0_sha "$record_0_sha" \
  --arg record_1_sha "$record_1_sha" '
  def policy_ref: {content_id:"scope-qualification-policy",
    media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha};
  def mode_ref: {content_id:"operating-mode-marker",media_type:"application/json",
    sha256:$marker_sha};
  def scope_ref: {schema_version:1,kind:"workflow_scope",
    id:"scope.docs-typo-fix.v1",sha256:$scope_sha};
  def shadow_record($id;$environment;$outcome;$sha):
    {schema_version:1,kind:"shadow_reproduction_record",id:$id,sha256:$sha,
     environment_id:$environment,outcome:$outcome,
     target_repository_id:"repo.fixture-target"};
  def evidence: {
    duty_evaluation_ref:{schema_version:1,kind:"duty_separation_evaluation",
      id:"stage.docs-typo-fix.result",sha256:$duty_sha},
    eval_dashboard_ref:{schema_version:1,kind:"eval_dashboard",
      id:"evals.dashboard.v1",sha256:$dashboard_sha},
    kill_switch_evaluation_ref:{schema_version:1,kind:"kill_switch_evaluation",
      id:"kill-attempt.docs-typo-fix",sha256:$kill_sha},
    mode_marker_ref:mode_ref,
    policy_ref:policy_ref,
    risk_evaluation_ref:{schema_version:1,kind:"risk_gate_evaluation",
      id:"stage.docs-typo-fix.result",sha256:$risk_sha},
    shadow_records:([
      shadow_record("shadow.docs-typo-fix.local";"env.local-macos-fixture";
        "reproduced";$record_0_sha),
      shadow_record("shadow.docs-typo-fix.ci";"env.ci-linux-fixture";
        "no-change";$record_1_sha)] | sort_by(.sha256)),
    shadow_set_ref:{schema_version:1,kind:"shadow_evidence_set",
      id:"scope.evidence.docs-typo-fix.v1",sha256:$shadow_set_sha}};
  {schema_version:1,kind:"scope_qualification_evaluation",
   id:"scope.docs-typo-fix.v1",
   body:{activation_state:"inactive",authority:"none",authority_effect:"none",
     enabled:false,evaluation_mode:"observation-only",
     reference_semantics:"identity-only",
     qualification:{state:"unavailable",
       reason_id:"scope.enablement-requires-operator-pr"},
     operating_mode:{state:"construction",repository_marker:"matched",
       marker_ref:mode_ref},
     outcome:"proposable",reason_ids:["scope.proposable"],
     scope_ref:scope_ref,evidence:evidence,
     proposal:{state:"present",document:{
       schema_version:1,kind:"scope_enablement_proposal",
       id:"proposal.scope.docs-typo-fix.v1",
       body:{activation_state:"inactive",authority:"none",enabled:false,
         push_allowed:false,
         qualification:{state:"unavailable",
           reason_id:"scope.enablement-requires-operator-pr"},
         enablement:{state:"blocked",reason_id:"scope.mode-construction"},
         operator_action:"Enabling this scope is an independent operator-merged pull request after the operating-mode transition. This document only records what that pull request would add; it turns nothing on and grants no authority.",
         operating_mode:"construction",
         qualification_scope_ref:{purpose:"qualification",
           decision_record_ref:policy_ref,
           subject_ref:{type:"artifact",value:{type:"content",
             value:{content_id:"workflow-scope-record",
               media_type:"application/vnd.ystack.workflow-scope+json",
               sha256:$scope_sha}}},
           scope_sha256:$scope_sha},
         scope_document_ref:scope_ref,
         target_repository_id:"repo.fixture-target",
         workflow_id:"workflow.docs-typo-fix",task_class:"task.docs-typo-fix",
         risk_tier:"routine",
         allowed_paths:["docs/guides/setup.md","docs/notes-?.md"],
         required_proof_kinds:["deterministic","independent-review"],
         required_eval_families:[
           "protected-path-credential-network-publisher-boundaries",
           "stale-moved-artifacts"],
         max_attempts:2,
         environments:["env.ci-linux-fixture","env.local-macos-fixture"],
         evidence:evidence}}}}}' >"$tmp/expected.json"
/usr/bin/cmp -s "$tmp/evaluation.json" "$tmp/expected.json" ||
  fail 'the proposable evaluation does not match the expected document byte for byte'
pass 'a routine scope with complete evidence is proposable, byte for byte and on repeat'

"$jq_bin" -e '
  .body.enabled == false and .body.proposal.document.body.enabled == false and
  .body.proposal.document.body.push_allowed == false and
  .body.operating_mode.state == "construction" and
  .body.proposal.document.body.enablement ==
    {state:"blocked",reason_id:"scope.mode-construction"} and
  ([.. | strings] | any(. == "enabled" or . == "qualified" or . == "active") | not) and
  ((.body | has("grant_ref") or has("activation")) | not)
' "$tmp/evaluation.json" >/dev/null || fail 'the proposal claims authority'
pass 'the proposal is inert: nothing is enabled and enablement stays blocked'

mutate_scope '.body.risk_tier = "high"' "$tmp/tier-high.json"
mutate_scope '.body.risk_tier = "bootstrap"' "$tmp/tier-bootstrap.json"
expect_reasons tier-high '["scope.tier-not-routine"]' "$tmp/tier-high.json" \
  "${good[@]:1}"
expect_reasons tier-bootstrap '["scope.tier-not-routine"]' "$tmp/tier-bootstrap.json" \
  "${good[@]:1}"
"$jq_bin" -S -c '.body.classification.minimum_tier = "high"' "$tmp/risk.json" \
  >"$tmp/risk-high.json"
"$jq_bin" -S -c '.body.verdict = "violated"' "$tmp/risk.json" >"$tmp/risk-violated.json"
expect_reasons risk-tier-high '["scope.tier-not-routine"]' "${good[@]:0:3}" \
  "$tmp/risk-high.json" "${good[@]:4}"
expect_reasons risk-violated '["scope.tier-not-routine"]' "${good[@]:0:3}" \
  "$tmp/risk-violated.json" "${good[@]:4}"
pass 'only a routine tier the risk gate also classifies routine may be proposed'

for glob in '.github/workflows/ci.yml' 'config/models.conf' 'AGENTS.md' \
  'control/v1/validate.sh' 'src/migrations/001.sql' 'app/auth/login.ts' \
  'docs/*/page.md' 'secrets/token.txt'; do
  "$jq_bin" -S -c --arg glob "$glob" '.body.allowed_paths = [$glob]' \
    "$tmp/scope.json" >"$tmp/protected.json"
  expect_reasons "protected $glob" '["scope.protected-path"]' "$tmp/protected.json" \
    "${good[@]:1}"
done
pass 'a scope whose allowed paths touch a protected path is never proposable'

mutate_scope '.body.required_shadow_environments =
  ["env.ci-linux-fixture","env.local-macos-fixture","env.staging-fixture"]' \
  "$tmp/env-missing.json"
expect_reasons shadow-missing '["scope.shadow-evidence-missing"]' \
  "$tmp/env-missing.json" "${good[@]:1}"
"$jq_bin" -S -c '.body.records[0].body.outcome = "inconclusive"' "$tmp/shadow-set.json" \
  >"$tmp/shadow-inconclusive.json"
expect_reasons shadow-inconclusive \
  '["scope.shadow-evidence-missing","scope.shadow-inconclusive"]' "${good[@]:0:1}" \
  "$tmp/shadow-inconclusive.json" "${good[@]:2}"
"$jq_bin" -S -c '.body.records[0].body.target_repository_id = "repo.other"' \
  "$tmp/shadow-set.json" >"$tmp/shadow-other-repo.json"
expect_reasons shadow-other-repository '["scope.shadow-evidence-missing"]' \
  "${good[@]:0:1}" "$tmp/shadow-other-repo.json" "${good[@]:2}"
"$jq_bin" -S -c '.body.records[1] = .body.records[0]' "$tmp/shadow-set.json" \
  >"$tmp/shadow-replayed.json"
expect_reasons shadow-replayed \
  '["scope.malformed","scope.shadow-evidence-missing","scope.shadow-inconclusive"]' \
  "${good[@]:0:1}" "$tmp/shadow-replayed.json" "${good[@]:2}"
pass 'shadow evidence must cover every environment, be conclusive, and be distinct'

mutate_scope '.body.required_eval_families = ["malicious-instructions"]' \
  "$tmp/eval-declared.json"
expect_reasons eval-unseeded '["scope.eval-family-unseeded"]' \
  "$tmp/eval-declared.json" "${good[@]:1}"
"$jq_bin" -S -c '.body.families = (.body.families | map(
   if .family_id == "stale-moved-artifacts" then .cases.failed = 1 else . end))' \
  "$tmp/dashboard.json" >"$tmp/dashboard-failing.json"
expect_reasons eval-failing '["scope.eval-failing"]' "${good[@]:0:2}" \
  "$tmp/dashboard-failing.json" "${good[@]:3}"
"$jq_bin" -S -c '.body.families = (.body.families | map(
   if .family_id == "stale-moved-artifacts" then .cases.inconclusive = 1 else . end))' \
  "$tmp/dashboard.json" >"$tmp/dashboard-inconclusive.json"
expect_reasons eval-inconclusive '["scope.eval-failing"]' "${good[@]:0:2}" \
  "$tmp/dashboard-inconclusive.json" "${good[@]:3}"
"$jq_bin" -S -c '.body.families = (.body.families | map(
   if .family_id == "stale-moved-artifacts" then .cases.total = 0 else . end))' \
  "$tmp/dashboard.json" >"$tmp/dashboard-empty.json"
expect_reasons eval-no-cases '["scope.eval-failing"]' "${good[@]:0:2}" \
  "$tmp/dashboard-empty.json" "${good[@]:3}"
# A dashboard that lists a required family twice, failing once and passing once,
# must not let the later entry win: duplicate family ids are malformed.
"$jq_bin" -S -c '(.body.families | map(select(.family_id == "stale-moved-artifacts"))[0]) as $pass |
  .body.families |= (map(if .family_id == "stale-moved-artifacts" then .cases.failed = 1 else . end) |
    (map(.family_id != "stale-moved-artifacts") | index(true)) as $slot | .[$slot] = $pass)' \
  "$tmp/dashboard.json" >"$tmp/dashboard-duplicate.json"
"$jq_bin" -e '[.body.families[] | select(.family_id == "stale-moved-artifacts")] | length == 2' \
  "$tmp/dashboard-duplicate.json" >/dev/null || fail 'duplicate-family fixture must repeat the family'
"$jq_bin" -e '.body.families | length == 9' "$tmp/dashboard-duplicate.json" >/dev/null ||
  fail 'duplicate-family fixture must keep nine entries'
expect_reasons eval-duplicate-family '["scope.eval-failing","scope.eval-family-unseeded","scope.malformed"]' \
  "${good[@]:0:2}" "$tmp/dashboard-duplicate.json" "${good[@]:3}"
pass 'every required eval family must be seeded and free of failing or inconclusive grades'

"$jq_bin" -S -c '.body.verdict = "violated"' "$tmp/kill.json" >"$tmp/kill-violated.json"
"$jq_bin" -S -c '.body.verdict = "inconclusive"' "$tmp/kill.json" \
  >"$tmp/kill-inconclusive.json"
expect_reasons kill-violated '["scope.kill-switch"]' "${good[@]:0:4}" \
  "$tmp/kill-violated.json" "${good[@]:5}"
expect_reasons kill-inconclusive '["scope.kill-switch"]' "${good[@]:0:4}" \
  "$tmp/kill-inconclusive.json" "${good[@]:5}"
"$jq_bin" -S -c '.body.verdict = "violated"' "$tmp/duty.json" >"$tmp/duty-violated.json"
"$jq_bin" -S -c '.body.verdict = "inconclusive"' "$tmp/duty.json" \
  >"$tmp/duty-inconclusive.json"
expect_reasons duty-violated '["scope.duty-violation"]' "${good[@]:0:5}" \
  "$tmp/duty-violated.json" "${good[@]:6}"
expect_reasons duty-inconclusive '["scope.duty-violation"]' "${good[@]:0:5}" \
  "$tmp/duty-inconclusive.json" "${good[@]:6}"
pass 'a live kill switch or an unsatisfied duty separation blocks the proposal'

"$jq_bin" -S '.status = "operating"' "$tmp/marker.json" >"$tmp/marker-stale.json"
expect_reasons mode-stale-marker '["scope.mode-construction"]' "${good[@]:0:6}" \
  "$tmp/marker-stale.json"
"$jq_bin" -S -c '{status:"active"}' "$tmp/marker.json" >"$tmp/marker-shape.json"
expect_reasons mode-marker-shape '["scope.mode-construction"]' "${good[@]:0:6}" \
  "$tmp/marker-shape.json"
pass 'a marker that disagrees with the committed one leaves the mode unknown'

for malformed_case in 'del(.body.records[0].body.shadow)' \
  '.body.records[0].body.authority = "publisher"' \
  '.body.records[0].body.activation_state = "active"' \
  '.body.records[0].kind = "other_record"' \
  '.body.records = []'; do
  "$jq_bin" -S -c "$malformed_case" "$tmp/shadow-set.json" >"$tmp/shadow-malformed.json"
  expect_reasons "malformed shadow $malformed_case" \
    '["scope.malformed","scope.shadow-evidence-missing","scope.shadow-inconclusive"]' \
    "${good[@]:0:1}" "$tmp/shadow-malformed.json" "${good[@]:2}"
done
"$jq_bin" -S -c '.body.families = (.body.families[0:8])' "$tmp/dashboard.json" \
  >"$tmp/dashboard-malformed.json"
expect_reasons malformed-dashboard \
  '["scope.eval-failing","scope.eval-family-unseeded","scope.malformed"]' \
  "${good[@]:0:2}" "$tmp/dashboard-malformed.json" "${good[@]:3}"
"$jq_bin" -S -c '.kind = "other_evaluation"' "$tmp/kill.json" >"$tmp/kill-malformed.json"
expect_reasons malformed-kill '["scope.kill-switch","scope.malformed"]' \
  "${good[@]:0:4}" "$tmp/kill-malformed.json" "${good[@]:5}"
pass 'evidence that parses but does not hold its shape is refused as malformed'

expect_evaluator_error evaluator-non-canonical E_CANONICAL "$tmp/pretty.json" \
  "${good[@]:1}"
expect_evaluator_error evaluator-multi-root E_PARSE "$tmp/multi-root.json" \
  "${good[@]:1}"
expect_evaluator_error evaluator-oversized E_LIMIT "${good[@]:0:1}" \
  "$tmp/oversized.json" "${good[@]:2}"
expect_evaluator_error evaluator-symlink E_RUNTIME "$tmp/symlink.json" "${good[@]:1}"
expect_evaluator_error evaluator-absent E_RUNTIME "$tmp/does-not-exist.json" \
  "${good[@]:1}"
expect_evaluator_error evaluator-scope-shape E_SHAPE "$tmp/bad-kind.json" "${good[@]:1}"
expect_evaluator_error evaluator-scope-relation E_RELATION "$tmp/bad-enabled.json" \
  "${good[@]:1}"
expect_evaluator_error evaluator-arity E_USAGE "${good[@]:0:6}"
/usr/bin/printf '[1,2]\n' >"$tmp/array-root.json"
expect_evaluator_error evaluator-array-root E_PARSE "$tmp/array-root.json" "${good[@]:1}"
pass 'the evaluator fails closed on bad, oversized, multi-root, symlink, and short calls'

# A scope record that moved is a different record: the evaluation binds the exact
# bytes it read, so no earlier proposal can be replayed against new content.
"$jq_bin" -S -c '.body.max_attempts = 3' "$tmp/scope.json" >"$tmp/scope-moved.json"
run_evaluator "$tmp/scope-moved.json" "${good[@]:1}" >"$tmp/evaluation-moved.json"
moved_sha=$("$jq_bin" -r '.body.scope_ref.sha256' "$tmp/evaluation-moved.json")
[ "$moved_sha" != "$scope_sha" ] || fail 'a moved scope kept the old digest'
/usr/bin/cmp -s "$tmp/evaluation.json" "$tmp/evaluation-moved.json" &&
  fail 'a moved scope produced the same evaluation'
pass 'the evaluation is bound to the exact bytes of every input it read'

# The same component in a tree with no committed mode marker: the supplied marker
# is then all there is, and the evaluator still never enables anything.
fake_repo="$tmp/portable/scope/v1"
/bin/mkdir -p "$fake_repo"
for shipped in scope-policy.json workflow-scope.jq scope-gates.jq validate-scope.sh \
  evaluate-scope.sh; do
  /bin/cp "$root/scope/v1/$shipped" "$fake_repo/$shipped"
done
/bin/chmod 0500 "$fake_repo/validate-scope.sh" "$fake_repo/evaluate-scope.sh"
"$jq_bin" -S -c -n '{schema_version:1,status:"retired"}' >"$tmp/marker-operating.json"
PATH="$bin:/usr/bin:/bin" "$fake_repo/evaluate-scope.sh" evaluate "${good[@]:0:6}" \
  "$tmp/marker-operating.json" >"$tmp/evaluation-portable.json"
"$jq_bin" -e '
  .body.outcome == "proposable" and .body.enabled == false and
  .body.operating_mode == {state:"operating",repository_marker:"absent",
    marker_ref:.body.evidence.mode_marker_ref} and
  .body.proposal.document.body.enabled == false and
  .body.proposal.document.body.enablement ==
    {state:"blocked",reason_id:"scope.enablement-requires-operator-pr"}
' "$tmp/evaluation-portable.json" >/dev/null ||
  fail 'the portable copy enabled something or misread the mode'
pass 'with no committed mode marker the outcome is still only a blocked proposal'
# In that same portable tree an unknown status is not operating: only "active"
# and "retired" mean anything, and a typo fails closed.
"$jq_bin" -S -c -n '{schema_version:1,status:"activ"}' >"$tmp/marker-typo.json"
PATH="$bin:/usr/bin:/bin" "$fake_repo/evaluate-scope.sh" evaluate "${good[@]:0:6}" \
  "$tmp/marker-typo.json" >"$tmp/evaluation-typo.json"
"$jq_bin" -e '.body.outcome == "not-proposable" and
  .body.reason_ids == ["scope.mode-construction"] and .body.enabled == false' \
  "$tmp/evaluation-typo.json" >/dev/null || fail 'an unknown mode status was not refused'
pass 'an unknown operating-mode status fails closed even without a committed marker'

/usr/bin/printf 'scope qualification: %s focused checks passed\n' "$passes"
