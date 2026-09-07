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
  out=$(run_evaluator "$@" 2>&1) ||
    fail "evaluator refused a well-formed call ($1): $(/usr/bin/printf '%s' "$out" | /usr/bin/tail -c 300)"
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

# The identities qualification is attached to. The scope records them, the shadow
# records say which revision they ran against, and the evaluator binds the two.
fixture_revision='{"commit_id":"1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d","hash_algorithm":"sha1","repository_id":"repo.fixture-target"}'
other_revision='{"commit_id":"90abcdef1234567890abcdef1234567890abcdef","hash_algorithm":"sha1","repository_id":"repo.fixture-target"}'
qualified_identity='{
  "adapter_config_refs":[
    {"content_id":"producer-config",
     "media_type":"application/vnd.ystack.adapter-config+json",
     "sha256":"dbb66b0ed70b09061474eb8a8245e7df9c26e3fb8eca1d1b5b5223c74d3699b4"}],
  "model_request":{"effort_id":"high","model_id":"claude.sonnet",
    "provider_id":"anthropic"},
  "prompt_refs":[
    {"location":{"kind":"path","value":"routines/coder.md"},"mode":"100644",
     "object_id":"b307b85339fbfc060aec59c625918a3f20707438",
     "object_type":"blob",
     "revision":{"commit_id":"a637451d4b3fbef6b516a9c08f68c0dde46a7059",
       "hash_algorithm":"sha1","repository_id":"repo.ystack"}}],
  "resolved_profile_ref":{"id":"resolved.docs-typo-fix.v1","kind":"resolved_profile",
    "schema_version":2,
    "sha256":"3bae8e45eea85ad41068735782b4750deb920654c34712b85159195ceec8b688"},
  "skill_refs":[],
  "stage_request_ref":{"id":"stage.docs-typo-fix.request","kind":"stage_request",
    "schema_version":2,
    "sha256":"0cefa6d87f7869958b5ba9f0555a6327e8f49f3047b5bde500c7796024256592"},
  "target_revision":{"commit_id":"1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d",
    "hash_algorithm":"sha1","repository_id":"repo.fixture-target"},
  "verification_instructions_ref":{"content_id":"verification-instructions",
    "media_type":"application/vnd.ystack.verification-instructions+json",
    "sha256":"eebf0a48514a92396eb06ceee8fabc218f6b8c979e01ad5850bdedb42f494488"}}'

# The shadow record fixtures are whole records in the shape
# shadow/v1/reproduce.sh emits, not only the fields this evaluator reads: the
# qualification gate now checks that slice's complete emitted shape, so a stub
# carrying the envelope, the markers, and an accepted outcome is refused as
# malformed. Every block is here field for field - the incident, environment
# claim, registry, and trace ledger references, the sandbox evaluation section,
# the read-only materialization with the materializer receipt's source and
# candidate, and the executed file-digest check - and the reason id, outcome,
# and section states are the combination the slice actually produces for that
# run.
expected_check_sha=8f434346648f6b96df89dda901c5176b10a6d83961dd3c2e6c66a9f0f95d4c9b
observed_check_sha=60303ae22b998861bce3b28f33eec1be758a213c86c93c076dbe9f558c11c752
"$jq_bin" -S -c -n --argjson revision "$fixture_revision" \
  --arg expected "$expected_check_sha" --arg observed "$observed_check_sha" '
  def digest($character): ($character * 64);
  def record($id;$environment;$outcome;$repository):
    ($revision | .repository_id = $repository) as $rev |
    (if $outcome == "reproduced" then "check.failed-at-revision"
     else "check.passed-at-revision" end) as $reason |
    {schema_version:1,kind:"shadow_reproduction_record",id:$id,
     body:{activation_state:"inactive",authority:"none",deploy_authority:"none",
       effects:["caller-disposable-candidate-repository"],
       evaluation_mode:"observation-only",shadow:true,
       qualification:{state:"unavailable",reason_id:"shadow.unqualified"},
       outcome:$outcome,reason_id:$reason,
       observed_at:"2026-09-05T00:00:00Z",target_repository_id:$repository,
       git_revision_ref:$rev,
       incident_ref:{content_id:"shadow-incident-record",
         media_type:"application/vnd.ystack.shadow-incident-record+json",
         sha256:digest("a")},
       environment:{environment_id:$environment,
         claim_ref:{content_id:"shadow-environment-claim",
           media_type:"application/vnd.ystack.control-execution-environment-claim+json",
           sha256:digest("b")},
         registry_ref:{content_id:"shadow-environment-registry",
           media_type:"application/vnd.ystack.shadow-environment-registry+json",
           sha256:digest("c")},
         evaluation:{state:"present",
           value:{verdict:"satisfied",
             reason_ids:["sandbox.declaration-satisfied"],
             evaluation_ref:{content_id:"shadow-sandbox-evaluation",
               media_type:"application/vnd.ystack.control-evaluation+json",
               sha256:digest("d")}}}},
       materialization:{state:"present",
         value:{adapter_id:"adapter.local-git-materializer.v1",
           outcome:"no-change",
           source:{repository_id:$repository,
             hash_algorithm:$rev.hash_algorithm,commit_id:$rev.commit_id,
             tree_id:"4b825dc642cb6eb9a060e54bf8d69288fbee4904"},
           candidate:{repository_kind:"bare",
             hash_algorithm:$rev.hash_algorithm,commit_id:$rev.commit_id,
             tree_id:"4b825dc642cb6eb9a060e54bf8d69288fbee4904",
             parent_commit_id:$rev.commit_id},
           stage_result_ref:{schema_version:2,kind:"stage_result",
             id:("stage.docs-typo-fix.result." + $environment),
             sha256:digest("e")}}},
       check:{failing_check:{kind:"file-digest",path:"docs/components.md",
           expected_sha256:$expected},
         execution:{state:"present",
           value:{tool_id:"tool.git-blob-digest",
             observed_sha256:(if $outcome == "no-change" then $expected
                              else $observed end),
             matches_expected:($outcome == "no-change")}}},
       trace_ledger_ref:{content_id:"shadow-trace-ledger",
         media_type:"application/vnd.ystack.telemetry-trace-ledger+json",
         sha256:digest("f")}}};
  {schema_version:1,kind:"shadow_evidence_set",
   id:"scope.evidence.docs-typo-fix.v1",
   body:{records:[
     record("shadow.docs-typo-fix.local";"env.local-macos-fixture";"reproduced";
       "repo.fixture-target"),
     record("shadow.docs-typo-fix.ci";"env.ci-linux-fixture";"no-change";
       "repo.fixture-target")]}}' >"$tmp/shadow-set.json"

# The dashboard fixture is a whole eval dashboard in the shape
# evals/v1/evals.jq emits, not only the parts this evaluator reads: the
# qualification gate now checks the framework's complete emitted shape, so a
# fixture carrying just the families would be refused as malformed. Every block
# is here field for field — the portable core contract the framework pins, the
# catalog and evaluator references, the run inputs, coverage, quality, recovery,
# and the absent telemetry and flow metrics.
"$jq_bin" -S -c -n '
  def family($id;$status;$total;$failed;$inconclusive):
    {family_id:$id,seed_status:$status,seed_sources:[],
     grader_kinds:["deterministic"],trial_policy:{kind:"single"},runs:1,
     cases:{total:$total,passed:($total - $failed - $inconclusive),
       failed:$failed,inconclusive:$inconclusive}};
  def absent($reason): {state:"absent",reason_id:$reason};
  def closure($path;$sha): [{path:$path,sha256:$sha}];
  {schema_version:1,kind:"eval_dashboard",id:"evals.dashboard.v1",
   body:{activation_state:"inactive",authority_effect:"none",
     mode:"deterministic-offline",
     core_contract:{
       generation_id_sha256:
         "84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
       package_ref:{content_id:"core-contract-package.v2",
         media_type:"application/vnd.ystack.core-contract+json",
         sha256:"eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"},
       semantic_identity:"core.contracts.v2"},
     catalog_ref:{schema_version:1,kind:"eval_catalog",id:"evals.catalog.v1",
       sha256:"1111111111111111111111111111111111111111111111111111111111111111"},
     evaluator:{
       sha256:"2222222222222222222222222222222222222222222222222222222222222222",
       content:{schema_version:1,kind:"eval_framework_evaluator",
         id:"evals.framework.v1",
         body:{
           core_contract:{
             generation_id_sha256:
               "84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
             package_ref:{content_id:"core-contract-package.v2",
               media_type:"application/vnd.ystack.core-contract+json",
               sha256:"eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"},
             semantic_identity:"core.contracts.v2"},
           core_closure:closure("core/v2/generation-registry.json";
             "3333333333333333333333333333333333333333333333333333333333333333"),
           orchestrator_closure:closure("orchestrator/v1/scan-state.sh";
             "4444444444444444444444444444444444444444444444444444444444444444"),
           control_closure:closure("control/v1/kill-switch.jq";
             "5555555555555555555555555555555555555555555555555555555555555555"),
           adapter_closure:closure("adapters/codex-native-reviewer/v1/normalize.jq";
             "6666666666666666666666666666666666666666666666666666666666666666"),
           bootstrap_ref:{content_id:"evals-framework-bootstrap.v1",
             media_type:"text/x-shellscript",
             sha256:"7777777777777777777777777777777777777777777777777777777777777777"},
           launcher_ref:{content_id:"evals-framework-launcher.v1",
             media_type:"text/x-shellscript",
             sha256:"8888888888888888888888888888888888888888888888888888888888888888"},
           driver_ref:{content_id:"evals-framework-driver.v1",
             media_type:"text/x-shellscript",
             sha256:"9999999999999999999999999999999999999999999999999999999999999999"},
           program_ref:{content_id:"evals-framework-program.v1",
             media_type:"text/x-jq",
             sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
           catalog_ref:{content_id:"evals-catalog.v1",
             media_type:"application/vnd.ystack.eval-catalog+json",
             sha256:"1111111111111111111111111111111111111111111111111111111111111111"},
           runtime:{host_os:"linux",host_architecture:"x86_64",
             jq_architecture:"x86_64",execution_mode:"native",
             jq_ref:{content_id:"jq-runtime.v1",
               media_type:"application/x-executable",
               sha256:"af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44"},
             shell_ref:{content_id:"bash-runtime",
               media_type:"application/x-executable",
               sha256:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}}}},
     observed_at:"2026-09-05T00:00:00Z",
     inputs:[{run_id:"evals.run.fixture",seed_source:"core.stage-run.v2",
       result_sha256:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
       observed_at:"2026-09-05T00:00:00Z",
       seed_set_ref:{schema_version:1,kind:"eval_seed_set",id:"evals.seed-set.fixture",
         sha256:"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},
       summary:{total:34,passed:34,failed:0,inconclusive:0}}],
     coverage:{families_total:9,families_seeded:7,families_declared:2,
       families_with_results:7,
       sources_with_results:["core.stage-run.v2"]},
     quality:{total:34,passed:34,failed:0,inconclusive:0},
     recovery:{stranded_recovered:0,cancelled_stayed_terminal:0,
       repeats_redelivered_once:0,repeats_suppressed_after_acknowledgement:0,
       retry_limit_enforced:0,events_refused:0},
     telemetry:{cost:absent("evals.no-live-runs"),
       latency:absent("evals.no-live-runs"),tokens:absent("evals.no-live-runs")},
     flow:([
       "accepted-plan-to-merge-time","dora-instability","dora-throughput",
       "escaped-defects","escaped-vulnerabilities","first-pass-success",
       "human-gate-wait","intent-to-spec-time","queue-wait","review-latency",
       "review-precision","review-recall-samples","review-stale-rate",
       "rework-cycles","target-outcome"] |
       map({key:.,value:absent("evals.no-operating-history")}) | from_entries),
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

# The three gate evaluations are complete documents in the shape their own
# evaluators emit — control/v1/risk-gates.jq, control/v1/kill-switch.jq, and
# control/v1/duty-separation.jq — field for field and ref for ref, because the
# gate program accepts nothing less than an evaluator's whole output. They carry
# the policy set they ran under, the portable core contract, the control
# decision and policy they read, the stage they are about, and the duty
# evaluation the risk and kill-switch evaluators each bind. The duty document is
# written first so the other two can name it.
policy_set='{"id":"control.policy-set.v1","sha256":"42d342f42022ce1fb8c5c8e06c15dd3fd1ef604c215d1ce1ad6f7cc90ba8b747"}'
stage_block='{
  "request_ref":{"id":"stage.docs-typo-fix.request","kind":"stage_request",
    "schema_version":2,
    "sha256":"0cefa6d87f7869958b5ba9f0555a6327e8f49f3047b5bde500c7796024256592"},
  "resolved_profile_ref":{"id":"resolved.docs-typo-fix.v1","kind":"resolved_profile",
    "schema_version":2,
    "sha256":"3bae8e45eea85ad41068735782b4750deb920654c34712b85159195ceec8b688"},
  "result_ref":{"id":"stage.docs-typo-fix.result","kind":"stage_result",
    "schema_version":2,
    "sha256":"0fd5b4136f4b21757eeb1bcbd780cb5baac605663df3a9be4dd7b34c786a045d"}}'
# A fixture generation id, not the shipped one: the guard above forbids the real
# generation id in this file, and the gate program checks the shape only.
core_contract='{
  "generation_id":"g-0bef6d994accaf957358a8f9c833c0ce64bb71fe2bc934b9569277bbe19b8d29",
  "package_ref":{"content_id":"core-contract-package.v2",
    "media_type":"application/vnd.ystack.core-contract+json",
    "sha256":"84d29c91b3018a321dad4c036bc9140cec6ad1c2371e12b8b6a4ac1155e054cb"},
  "semantic_identity":"core.contracts.v2"}'
control_policy_ref='{"content_id":"control.policy.v1",
  "media_type":"application/vnd.ystack.control-policy+json",
  "sha256":"5cc06d264d934d9b143493f47ece687c295c283e8468438d355e3a8c449c95c5"}'
control_decision_ref='{"content_id":"control.decision.docs-typo-fix",
  "media_type":"application/vnd.ystack.control-decision+json",
  "sha256":"47fd3c45b720f57074bf6c666716278c728ccda210df8f95a431dbde0b0b43d0"}'
duty_decision_ref='{"content_id":"control.decision.duty-separation",
  "media_type":"application/vnd.ystack.control-decision+json",
  "sha256":"b4ff4ce76d4dfd90e7a6bace6bae19f95a76d8680ac3778a779d7c883ffc8548"}'
decision_claim_ref='{"content_id":"risk.decision-claim.docs-typo-fix",
  "media_type":"application/vnd.ystack.risk-gate-decision-claim+json",
  "sha256":"ff7a0762578d99a4ebe04b14be2298d9934edebd12e5dc2dcde41ce4633275c6"}'
kill_state_ref='{"schema_version":1,"kind":"kill_switch_state",
  "id":"kill.state.v1",
  "sha256":"e0a9c5c06f7afc6c7804e8033378ac583dba7a5a5adf5e035bb94092ccbe4a32"}'

"$jq_bin" -S -c -n --argjson policy_set "$policy_set" --argjson stage "$stage_block" \
  --argjson core_contract "$core_contract" \
  --argjson policy_ref "$control_policy_ref" \
  --argjson decision_ref "$duty_decision_ref" '
  {schema_version:1,kind:"duty_separation_evaluation",
   id:"stage.docs-typo-fix.result",
   body:{activation_state:"inactive",core_contract:$core_contract,
     decision_ref:$decision_ref,evaluation_mode:"observation-only",
     policy_ref:$policy_ref,policy_set:$policy_set,stage:$stage,
     reference_semantics:"identity-only",verdict:"satisfied",
     reason_ids:["duty.satisfied"]}}' >"$tmp/duty.json"
duty_sha=$(sha256_path "$tmp/duty.json")
"$jq_bin" -S -c -n --argjson policy_set "$policy_set" --argjson stage "$stage_block" \
  --argjson core_contract "$core_contract" \
  --argjson policy_ref "$control_policy_ref" \
  --argjson decision_ref "$control_decision_ref" \
  --argjson claim_ref "$decision_claim_ref" \
  --arg duty_sha "$duty_sha" '
  {schema_version:1,kind:"risk_gate_evaluation",id:"stage.docs-typo-fix.result",
   body:{activation_state:"inactive",authority_effect:"none",
     classification:{declared_tier:"routine",minimum_tier:"routine"},
     core_contract:$core_contract,decision_claim_ref:$claim_ref,
     decision_ref:$decision_ref,
     duty_evaluation_ref:{content_id:"stage.docs-typo-fix.result",
       media_type:"application/vnd.ystack.duty-separation-evaluation+json",
       sha256:$duty_sha},
     policy_ref:$policy_ref,policy_set:$policy_set,stage:$stage,
     evaluation_mode:"observation-only",reference_semantics:"identity-only",
     verdict:"inconclusive",
     reason_ids:["decision.provenance-unqualified"]}}' >"$tmp/risk.json"
"$jq_bin" -S -c -n --argjson policy_set "$policy_set" --arg duty_sha "$duty_sha" \
  --argjson policy_ref "$control_policy_ref" \
  --argjson decision_ref "$control_decision_ref" \
  --argjson duty_decision_ref "$duty_decision_ref" \
  --argjson state_ref "$kill_state_ref" '
  {schema_version:1,kind:"kill_switch_evaluation",
   id:"kill-attempt.docs-typo-fix",
   body:{activation_state:"inactive",authority_effect:"none",
     decision_ref:$decision_ref,duty_decision_ref:$duty_decision_ref,
     duty_evaluation_ref:{schema_version:1,kind:"duty_separation_evaluation",
       id:"stage.docs-typo-fix.result",sha256:$duty_sha},
     policy_ref:$policy_ref,policy_set:$policy_set,state_ref:$state_ref,
     attempt_ref:{schema_version:1,kind:"kill_switch_attempt",
       id:"kill-attempt.docs-typo-fix",
       sha256:"5f4cf0c000008d393df5f101db749ae7c6a29e967ea15ceb059fe2f84a6a99b9"},
     evaluation_mode:"observation-only",reference_semantics:"identity-only",
     verdict:"satisfied",reason_ids:["kill.cleared-current"]}}' >"$tmp/kill.json"

# A scope claims its evidence by digest, so every evidence document is built
# first and the scope record is written to name exactly the shadow records and
# the three gate evaluations it may count.
set_record_sha() {
  "$jq_bin" -S -c --argjson i "$2" '.body.records[$i]' "$1" >"$tmp/record-digest.json"
  sha256_path "$tmp/record-digest.json"
}
evidence_refs() {
  local set_path=$1 count index refs=()
  count=$("$jq_bin" -r '.body.records | length' "$set_path")
  index=0
  while [ "$index" -lt "$count" ]; do
    refs+=("$("$jq_bin" -S -c -n --arg sha "$(set_record_sha "$set_path" "$index")" \
      --arg id "$("$jq_bin" -r --argjson i "$index" '.body.records[$i].id' "$set_path")" \
      '{schema_version:1,kind:"shadow_reproduction_record",id:$id,sha256:$sha}')")
    index=$((index + 1))
  done
  /usr/bin/printf '%s\n' "${refs[@]}" |
    "$jq_bin" -S -c -s 'sort | unique'
}
# One document ref naming the evaluation in $1 by its own kind, id, and digest.
gate_ref() {
  "$jq_bin" -S -c -n --arg sha "$(sha256_path "$1")" \
    --arg id "$("$jq_bin" -r '.id' "$1")" --arg kind "$("$jq_bin" -r '.kind' "$1")" \
    '{schema_version:1,kind:$kind,id:$id,sha256:$sha}'
}
# $1 = risk, $2 = kill-switch, $3 = duty evaluation the scope claims.
gate_refs() {
  "$jq_bin" -S -c -n --argjson risk "$(gate_ref "$1")" \
    --argjson kill "$(gate_ref "$2")" --argjson duty "$(gate_ref "$3")" \
    '{risk_gate_evaluation_ref:$risk,kill_switch_evaluation_ref:$kill,
      duty_separation_evaluation_ref:$duty}'
}
# $1 = shadow evidence set, $2 = risk, $3 = kill, $4 = duty, $5 = output path.
scope_record() {
  "$jq_bin" -S -c -n --argjson refs "$(evidence_refs "$1")" \
    --argjson gate_refs "$(gate_refs "$2" "$3" "$4")" \
    --argjson identity "$qualified_identity" '
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
       shadow_evidence_refs:$refs,
       qualified_identity:$identity,
       gate_evidence_refs:$gate_refs,
       max_attempts:2}}' >"$5"
}
# $1 = risk, $2 = kill, $3 = duty, $4 = output: the standard scope re-pointed at
# one mutated gate evaluation, so a case can isolate a verdict from a rebinding.
scope_for_gates() {
  scope_record "$tmp/shadow-set.json" "$1" "$2" "$3" "$4"
}
# $1 = mutated shadow evidence set, $2 = output: the standard scope re-pointed at
# that set, so a case can isolate the shadow problem from an unmet claim.
scope_for_shadow() {
  scope_record "$1" "$tmp/risk.json" "$tmp/kill.json" "$tmp/duty.json" "$2"
}
scope_record "$tmp/shadow-set.json" "$tmp/risk.json" "$tmp/kill.json" \
  "$tmp/duty.json" "$tmp/scope.json"
# Every input the evaluator reads must be canonical, the mode marker included,
# so the committed marker is put into canonical form before it is supplied.
"$jq_bin" -S -c . "$repo_marker" >"$tmp/marker.json"

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
mutate_scope 'del(.body.shadow_evidence_refs)' "$tmp/bad-no-refs.json"
mutate_scope '.body.shadow_evidence_refs = []' "$tmp/bad-empty-refs.json"
mutate_scope '.body.shadow_evidence_refs =
  [{schema_version:1,kind:"shadow_reproduction_record",id:"shadow.x"}]' \
  "$tmp/bad-ref-shape.json"
mutate_scope '.body.shadow_evidence_refs[0].sha256 = "not-a-digest"' \
  "$tmp/bad-ref-digest.json"
mutate_scope '.body.shadow_evidence_refs[0].kind = "other_record"' \
  "$tmp/bad-ref-kind.json"
mutate_scope '.body.shadow_evidence_refs =
  [.body.shadow_evidence_refs[0], .body.shadow_evidence_refs[0]]' \
  "$tmp/bad-ref-duplicate.json"
mutate_scope 'del(.body.qualified_identity)' "$tmp/bad-no-identity.json"
mutate_scope 'del(.body.qualified_identity.stage_request_ref)' "$tmp/bad-no-stage-request.json"
mutate_scope '.id = ("scope." + ("x" * 114))' "$tmp/bad-long-id.json"
mutate_scope 'del(.body.qualified_identity.model_request)' "$tmp/bad-no-model.json"
mutate_scope '.body.qualified_identity.model_request.effort_id = 3' \
  "$tmp/bad-model-shape.json"
mutate_scope '.body.qualified_identity.prompt_refs = []' "$tmp/bad-no-prompt.json"
mutate_scope '.body.qualified_identity.prompt_refs[0].object_id = "not-an-object"' \
  "$tmp/bad-prompt-object.json"
mutate_scope '.body.qualified_identity.adapter_config_refs[0].media_type = "json"' \
  "$tmp/bad-config-media.json"
mutate_scope 'del(.body.qualified_identity.verification_instructions_ref)' \
  "$tmp/bad-no-verification.json"
mutate_scope '.body.qualified_identity.resolved_profile_ref.schema_version = 1' \
  "$tmp/bad-profile-version.json"
mutate_scope '.body.qualified_identity.target_revision.repository_id = "repo.other"' \
  "$tmp/bad-revision-repository.json"
mutate_scope '.body.qualified_identity.target_revision.commit_id = "abc"' \
  "$tmp/bad-revision-commit.json"
mutate_scope 'del(.body.gate_evidence_refs)' "$tmp/bad-no-gate-refs.json"
mutate_scope 'del(.body.gate_evidence_refs.kill_switch_evaluation_ref)' \
  "$tmp/bad-gate-ref-missing.json"
mutate_scope '.body.gate_evidence_refs.risk_gate_evaluation_ref.kind =
  "duty_separation_evaluation"' "$tmp/bad-gate-ref-kind.json"
mutate_scope '.body.gate_evidence_refs.duty_separation_evaluation_ref.sha256 =
  "not-a-digest"' "$tmp/bad-gate-ref-digest.json"
for case_name in bad-attempts bad-tier bad-absolute bad-traversal bad-doublestar \
  bad-firstwild bad-git bad-backslash bad-duplicate bad-family bad-proof bad-extra \
  bad-missing bad-kind bad-no-refs bad-empty-refs bad-ref-shape bad-ref-digest \
  bad-ref-kind bad-ref-duplicate bad-no-identity bad-no-stage-request bad-long-id bad-no-model bad-model-shape \
  bad-no-prompt bad-prompt-object bad-config-media bad-no-verification \
  bad-profile-version bad-revision-repository bad-revision-commit \
  bad-no-gate-refs bad-gate-ref-missing bad-gate-ref-kind bad-gate-ref-digest; do
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
record_0_sha=$(set_record_sha "$tmp/shadow-set.json" 0)
record_1_sha=$(set_record_sha "$tmp/shadow-set.json" 1)

"$jq_bin" -S -c -n \
  --arg policy_sha "$policy_sha" --arg scope_sha "$scope_sha" \
  --arg shadow_set_sha "$shadow_set_sha" --arg dashboard_sha "$dashboard_sha" \
  --arg risk_sha "$risk_sha" --arg kill_sha "$kill_sha" --arg duty_sha "$duty_sha" \
  --arg marker_sha "$marker_sha" --arg record_0_sha "$record_0_sha" \
  --arg record_1_sha "$record_1_sha" \
  --argjson identity "$qualified_identity" \
  --argjson gate_refs "$(gate_refs "$tmp/risk.json" "$tmp/kill.json" "$tmp/duty.json")" '
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
      id:"scope.evidence.docs-typo-fix.v1",sha256:$shadow_set_sha},
    unclaimed_shadow_records:[]};
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
         qualified_identity:$identity,
         gate_evidence_refs:$gate_refs,
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
# A gate evaluation whose bytes changed is a different document, so each of
# these cases gets a scope that claims the mutated one: the refusal under test is
# the verdict, not an unbound claim.
"$jq_bin" -S -c '.body.classification.minimum_tier = "high"' "$tmp/risk.json" \
  >"$tmp/risk-high.json"
scope_for_gates "$tmp/risk-high.json" "$tmp/kill.json" "$tmp/duty.json" \
  "$tmp/scope-risk-high.json"
"$jq_bin" -S -c '.body.verdict = "violated" |
  .body.reason_ids = ["decision.actor-unbound"]' "$tmp/risk.json" \
  >"$tmp/risk-violated.json"
scope_for_gates "$tmp/risk-violated.json" "$tmp/kill.json" "$tmp/duty.json" \
  "$tmp/scope-risk-violated.json"
expect_reasons risk-tier-high '["scope.tier-not-routine"]' \
  "$tmp/scope-risk-high.json" "${good[@]:1:2}" "$tmp/risk-high.json" "${good[@]:4}"
expect_reasons risk-violated '["scope.tier-not-routine"]' \
  "$tmp/scope-risk-violated.json" "${good[@]:1:2}" "$tmp/risk-violated.json" \
  "${good[@]:4}"
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
# A leaf wildcard is judged by what it could expand to: src/* and src/auth* can
# reach a protected segment (a bare * is already refused by the record validator,
# which forbids a wildcard in the first segment), while src/*.ts cannot name any
# protected segment and stays allowed.
for glob in 'src/*' 'src/auth*' 'lib/secret?'; do
  "$jq_bin" -S -c --arg glob "$glob" '.body.allowed_paths = [$glob]' \
    "$tmp/scope.json" >"$tmp/protected-leaf.json"
  expect_reasons "protected leaf $glob" '["scope.protected-path"]' "$tmp/protected-leaf.json" \
    "${good[@]:1}"
done
"$jq_bin" -S -c '.body.allowed_paths = ["src/*.ts"]' "$tmp/scope.json" >"$tmp/leaf-allowed.json"
expect_reasons 'leaf wildcard that reaches no protected name' '["scope.proposable"]' \
  "$tmp/leaf-allowed.json" "${good[@]:1}"
pass 'a leaf wildcard is refused when it could expand to a protected name'

# A checkout may be case-insensitive, so a glob that differs from a protected name
# only by case reaches the same file and is refused for the same reason.
for glob in 'agents.md' 'AGENTS.MD' 'src/Auth/login.ts' '.GitHub/workflows/x.yml' \
  'Config/models.conf' 'app/SECRETS/token.txt'; do
  "$jq_bin" -S -c --arg glob "$glob" '.body.allowed_paths = [$glob]' \
    "$tmp/scope.json" >"$tmp/protected-case.json"
  run_validator "$tmp/protected-case.json" || fail "case glob $glob was refused"
  expect_reasons "protected case $glob" '["scope.protected-path"]' \
    "$tmp/protected-case.json" "${good[@]:1}"
done
pass 'protected paths are matched case-insensitively in every segment'

mutate_scope '.body.required_shadow_environments =
  ["env.ci-linux-fixture","env.local-macos-fixture","env.staging-fixture"]' \
  "$tmp/env-missing.json"
expect_reasons shadow-missing '["scope.shadow-evidence-missing"]' \
  "$tmp/env-missing.json" "${good[@]:1}"
# A record whose bytes changed is a different record, so these two fixtures get a
# scope that claims the mutated set: the refusal under test is the outcome or the
# repository, not an unmet claim.
# The inconclusive record is a whole record too: the slice reaches that outcome
# with the environment reason beside it and the materialization and check
# sections it never ran left absent.
"$jq_bin" -S -c '.body.records[0].body |=
  (.outcome = "inconclusive" | .reason_id = "environment.not-satisfied" |
   .environment.evaluation.value.verdict = "inconclusive" |
   .environment.evaluation.value.reason_ids = ["declaration.incomplete"] |
   .materialization = {state:"absent",reason_id:"materialization.not-attempted"} |
   .check.execution = {state:"absent",reason_id:"check.not-attempted"})' \
  "$tmp/shadow-set.json" >"$tmp/shadow-inconclusive.json"
scope_for_shadow "$tmp/shadow-inconclusive.json" "$tmp/scope-inconclusive.json"
expect_reasons shadow-inconclusive \
  '["scope.shadow-evidence-missing","scope.shadow-inconclusive"]' \
  "$tmp/scope-inconclusive.json" "$tmp/shadow-inconclusive.json" "${good[@]:2}"
"$jq_bin" -S -c '.body.records[0].body |= (.target_repository_id = "repo.other" |
  .git_revision_ref.repository_id = "repo.other" |
  .materialization.value.source.repository_id = "repo.other")' \
  "$tmp/shadow-set.json" >"$tmp/shadow-other-repo.json"
scope_for_shadow "$tmp/shadow-other-repo.json" "$tmp/scope-other-repo.json"
expect_reasons shadow-other-repository '["scope.shadow-evidence-missing"]' \
  "$tmp/scope-other-repo.json" "$tmp/shadow-other-repo.json" "${good[@]:2}"
"$jq_bin" -S -c '.body.records[1] = .body.records[0]' "$tmp/shadow-set.json" \
  >"$tmp/shadow-replayed.json"
expect_reasons shadow-replayed \
  '["scope.malformed","scope.shadow-evidence-missing","scope.shadow-inconclusive"]' \
  "${good[@]:0:1}" "$tmp/shadow-replayed.json" "${good[@]:2}"
# An outcome outside the shadow slice's vocabulary is not a record this
# evaluator understands, even when it is claimed: the set is malformed.
"$jq_bin" -S -c '.body.records[0].body.outcome = "failed"' "$tmp/shadow-set.json" \
  >"$tmp/shadow-unknown-outcome.json"
scope_for_shadow "$tmp/shadow-unknown-outcome.json" "$tmp/scope-unknown-outcome.json"
expect_reasons shadow-unknown-outcome \
  '["scope.malformed","scope.shadow-evidence-missing","scope.shadow-inconclusive"]' \
  "$tmp/scope-unknown-outcome.json" "$tmp/shadow-unknown-outcome.json" "${good[@]:2}"
pass 'shadow evidence must cover every environment, be conclusive, use a known outcome, and be distinct'

# A hand-written record carrying only the fields the gate reads - the envelope,
# the inactive/none markers, an accepted outcome, the repository, the revision,
# and an environment id - is not a shadow output. It is refused as malformed, so
# a stub can never back a scope.
"$jq_bin" -S -c --argjson revision "$fixture_revision" '
  .body.records[0] =
    {schema_version:1,kind:"shadow_reproduction_record",
     id:"shadow.docs-typo-fix.local",
     body:{activation_state:"inactive",authority:"none",deploy_authority:"none",
       shadow:true,
       qualification:{state:"unavailable",reason_id:"shadow.unqualified"},
       outcome:"reproduced",target_repository_id:"repo.fixture-target",
       git_revision_ref:$revision,
       environment:{environment_id:"env.local-macos-fixture"}}}' \
  "$tmp/shadow-set.json" >"$tmp/shadow-stub.json"
scope_for_shadow "$tmp/shadow-stub.json" "$tmp/scope-stub.json"
expect_reasons shadow-stub-record \
  '["scope.malformed","scope.shadow-evidence-missing","scope.shadow-inconclusive"]' \
  "$tmp/scope-stub.json" "$tmp/shadow-stub.json" "${good[@]:2}"
pass 'a stub carrying only the fields the gate reads is not a shadow record'

# The scope counts only the records it claims by digest. A record it never named
# is ignored even when it would have covered a required environment, and it is
# reported so the operator sees what was left out.
"$jq_bin" -S -c '.body.shadow_evidence_refs =
  [.body.shadow_evidence_refs[] | select(.id == "shadow.docs-typo-fix.ci")]' \
  "$tmp/scope.json" >"$tmp/scope-unclaimed.json"
run_validator "$tmp/scope-unclaimed.json" || fail 'a one-ref scope was refused'
expect_reasons shadow-unclaimed '["scope.shadow-evidence-missing"]' \
  "$tmp/scope-unclaimed.json" "${good[@]:1}"
run_evaluator "$tmp/scope-unclaimed.json" "${good[@]:1}" >"$tmp/evaluation-unclaimed.json"
"$jq_bin" -e --arg sha "$record_0_sha" '
  .body.evidence.unclaimed_shadow_records == [$sha] and
  .body.proposal == {state:"absent"}' "$tmp/evaluation-unclaimed.json" >/dev/null ||
  fail 'the ignored record was not reported by digest'
# A claim the supplied evidence never answers is missing evidence, not a pass.
"$jq_bin" -S -c '.body.shadow_evidence_refs = ((.body.shadow_evidence_refs +
  [{schema_version:1,kind:"shadow_reproduction_record",
    id:"shadow.docs-typo-fix.absent",
    sha256:"0000000000000000000000000000000000000000000000000000000000000000"}]) |
  sort | unique)' "$tmp/scope.json" >"$tmp/scope-dangling-ref.json"
run_validator "$tmp/scope-dangling-ref.json" || fail 'a three-ref scope was refused'
expect_reasons shadow-dangling-ref '["scope.shadow-evidence-missing"]' \
  "$tmp/scope-dangling-ref.json" "${good[@]:1}"
pass 'only the shadow records a scope claims by digest count as its evidence'

mutate_scope '.body.required_eval_families = ["malicious-instructions"]' \
  "$tmp/eval-declared.json"
expect_reasons eval-unseeded '["scope.eval-family-unseeded"]' \
  "$tmp/eval-declared.json" "${good[@]:1}"
"$jq_bin" -S -c '.body.families = (.body.families | map(
   if .family_id == "stale-moved-artifacts" then .cases.failed = 1 | .cases.passed -= 1 else . end))' \
  "$tmp/dashboard.json" >"$tmp/dashboard-failing.json"
expect_reasons eval-failing '["scope.eval-failing"]' "${good[@]:0:2}" \
  "$tmp/dashboard-failing.json" "${good[@]:3}"
"$jq_bin" -S -c '.body.families = (.body.families | map(
   if .family_id == "stale-moved-artifacts" then .cases.inconclusive = 1 | .cases.passed -= 1 else . end))' \
  "$tmp/dashboard.json" >"$tmp/dashboard-inconclusive.json"
expect_reasons eval-inconclusive '["scope.eval-failing"]' "${good[@]:0:2}" \
  "$tmp/dashboard-inconclusive.json" "${good[@]:3}"
"$jq_bin" -S -c '.body.families = (.body.families | map(
   if .family_id == "stale-moved-artifacts" then .cases = {total:0,passed:0,failed:0,inconclusive:0} else . end))' \
  "$tmp/dashboard.json" >"$tmp/dashboard-empty.json"
expect_reasons eval-no-cases '["scope.eval-failing"]' "${good[@]:0:2}" \
  "$tmp/dashboard-empty.json" "${good[@]:3}"
"$jq_bin" -S -c '.body.families = (.body.families | map(
   if .family_id == "stale-moved-artifacts" then .cases = {total:1,passed:0,failed:0,inconclusive:0} else . end))' \
  "$tmp/dashboard.json" >"$tmp/dashboard-unpassed.json"
expect_reasons eval-no-passing-case '["scope.eval-failing","scope.eval-family-unseeded","scope.malformed"]' "${good[@]:0:2}" \
  "$tmp/dashboard-unpassed.json" "${good[@]:3}"
# A dashboard that lists a required family twice, failing once and passing once,
# must not let the later entry win: duplicate family ids are malformed.
"$jq_bin" -S -c '(.body.families | map(select(.family_id == "stale-moved-artifacts"))[0]) as $pass |
  .body.families |= (map(if .family_id == "stale-moved-artifacts" then .cases.failed = 1 | .cases.passed -= 1 else . end) |
    (map(.family_id != "stale-moved-artifacts") | index(true)) as $slot | .[$slot] = $pass)' \
  "$tmp/dashboard.json" >"$tmp/dashboard-duplicate.json"
"$jq_bin" -e '[.body.families[] | select(.family_id == "stale-moved-artifacts")] | length == 2' \
  "$tmp/dashboard-duplicate.json" >/dev/null || fail 'duplicate-family fixture must repeat the family'
"$jq_bin" -e '.body.families | length == 9' "$tmp/dashboard-duplicate.json" >/dev/null ||
  fail 'duplicate-family fixture must keep nine entries'
"$jq_bin" -S -c '.body.families |= map(if .family_id == "stale-moved-artifacts"
  then .cases.skipped = 0 else . end)' "$tmp/dashboard.json" >"$tmp/dashboard-extra-counter.json"
expect_reasons eval-extra-counter '["scope.eval-failing","scope.eval-family-unseeded","scope.malformed"]' \
  "${good[@]:0:2}" "$tmp/dashboard-extra-counter.json" "${good[@]:3}"
expect_reasons eval-duplicate-family '["scope.eval-failing","scope.eval-family-unseeded","scope.malformed"]' \
  "${good[@]:0:2}" "$tmp/dashboard-duplicate.json" "${good[@]:3}"
pass 'every required eval family must be seeded and free of failing or inconclusive grades'

# Each verdict carries the reasons its own evaluator emits with it: a
# kill-switch or duty evaluation that keeps a cleared or satisfied reason beside
# another verdict is not a document either evaluator produces.
for verdict in violated inconclusive; do
  case "$verdict" in
    violated)
      kill_reason=kill.state-invalid
      duty_reason=actual.capability-mismatch
      # The reasons the other two evaluators emit beside this duty verdict:
      # control/v1/risk-gates.jq puts duty.violated among its violations, which
      # makes its own verdict violated, and control/v1/kill-switch.jq puts
      # kill.duty-violated among its violations, which makes its verdict
      # violated too.
      risk_verdict=violated
      risk_reasons='["duty.violated"]'
      kill_duty_verdict=violated
      kill_duty_reasons='["kill.duty-violated"]'
      # A violated duty therefore never stands alone: the risk gate reporting a
      # violation is not routine, and the kill switch is not clear.
      duty_expected='["scope.duty-violation","scope.kill-switch","scope.tier-not-routine"]'
      ;;
    *)
      # kill.duty-inconclusive belongs to an inconclusive duty verdict, so a
      # kill-switch case beside the satisfied duty fixture uses one of that
      # evaluator's duty-independent unknowns instead.
      kill_reason=kill.scope-missing.repository
      duty_reason=actual.capability-unclassified
      risk_verdict=inconclusive
      risk_reasons='["decision.provenance-unqualified","duty.inconclusive"]'
      kill_duty_verdict=inconclusive
      kill_duty_reasons='["kill.duty-inconclusive"]'
      duty_expected='["scope.duty-violation","scope.kill-switch"]'
      ;;
  esac
  "$jq_bin" -S -c --arg verdict "$verdict" --arg reason "$kill_reason" \
    '.body.verdict = $verdict | .body.reason_ids = [$reason]' \
    "$tmp/kill.json" >"$tmp/kill-$verdict.json"
  scope_for_gates "$tmp/risk.json" "$tmp/kill-$verdict.json" "$tmp/duty.json" \
    "$tmp/scope-kill-$verdict.json"
  expect_reasons "kill-$verdict" '["scope.kill-switch"]' \
    "$tmp/scope-kill-$verdict.json" "${good[@]:1:3}" "$tmp/kill-$verdict.json" \
    "${good[@]:5}"
  "$jq_bin" -S -c --arg verdict "$verdict" --arg reason "$duty_reason" \
    '.body.verdict = $verdict | .body.reason_ids = [$reason]' \
    "$tmp/duty.json" >"$tmp/duty-$verdict.json"
  # The risk and kill evaluations are recomputed over the mutated duty bytes, so
  # they name its digest, and they carry the duty reasons their own evaluators
  # emit for that verdict, so the three still agree with each other.
  duty_verdict_sha=$(sha256_path "$tmp/duty-$verdict.json")
  "$jq_bin" -S -c --arg sha "$duty_verdict_sha" --arg verdict "$risk_verdict" \
    --argjson reasons "$risk_reasons" \
    '.body.duty_evaluation_ref.sha256 = $sha | .body.verdict = $verdict |
     .body.reason_ids = $reasons' \
    "$tmp/risk.json" >"$tmp/risk-duty-$verdict.json"
  "$jq_bin" -S -c --arg sha "$duty_verdict_sha" --arg verdict "$kill_duty_verdict" \
    --argjson reasons "$kill_duty_reasons" \
    '.body.duty_evaluation_ref.sha256 = $sha | .body.verdict = $verdict |
     .body.reason_ids = $reasons' \
    "$tmp/kill.json" >"$tmp/kill-duty-$verdict.json"
  scope_for_gates "$tmp/risk-duty-$verdict.json" "$tmp/kill-duty-$verdict.json" \
    "$tmp/duty-$verdict.json" "$tmp/scope-duty-$verdict.json"
  expect_reasons "duty-$verdict" "$duty_expected" \
    "$tmp/scope-duty-$verdict.json" "${good[@]:1:2}" "$tmp/risk-duty-$verdict.json" \
    "$tmp/kill-duty-$verdict.json" "$tmp/duty-$verdict.json" "${good[@]:6}"
done
pass 'a live kill switch or an unsatisfied duty separation blocks the proposal'
# A kill-switch evaluation that names this duty evaluation by id but over other
# bytes (a different digest) is not evidence about the same attempt.
"$jq_bin" -S -c '.body.duty_evaluation_ref.sha256 = ("d" * 64)' "$tmp/kill.json" >"$tmp/kill-other-duty-bytes.json"
scope_for_gates "$tmp/risk.json" "$tmp/kill-other-duty-bytes.json" "$tmp/duty.json" \
  "$tmp/scope-kill-other-duty-bytes.json"
expect_reasons kill-other-duty-bytes '["scope.malformed"]' \
  "$tmp/scope-kill-other-duty-bytes.json" "${good[@]:1:3}" "$tmp/kill-other-duty-bytes.json" \
  "${good[@]:5}"
pass 'gate evaluations must name the duty evaluation by digest, not only by id'
# Gate outputs about another stage request never qualify this scope, even when
# they are valid and use the same resolved profile.
other_request='{"id":"stage.other-work.request","kind":"stage_request","schema_version":2,"sha256":"'"$(printf 'e%.0s' {1..64})"'"}'
"$jq_bin" -S -c --argjson req "$other_request" '.body.stage.request_ref = $req' "$tmp/risk.json" >"$tmp/risk-other-stage.json"
"$jq_bin" -S -c --argjson req "$other_request" '.body.stage.request_ref = $req' "$tmp/duty.json" >"$tmp/duty-other-stage.json"
other_duty_sha=$(sha256_path "$tmp/duty-other-stage.json")
"$jq_bin" -S -c --arg sha "$other_duty_sha" '.body.duty_evaluation_ref.sha256 = $sha' "$tmp/risk-other-stage.json" >"$tmp/risk-other-stage2.json"
"$jq_bin" -S -c --arg sha "$other_duty_sha" '.body.duty_evaluation_ref.sha256 = $sha' "$tmp/kill.json" >"$tmp/kill-other-stage.json"
scope_for_gates "$tmp/risk-other-stage2.json" "$tmp/kill-other-stage.json" "$tmp/duty-other-stage.json" \
  "$tmp/scope-other-stage.json"
expect_reasons gates-other-stage-request '["scope.malformed"]' \
  "$tmp/scope-other-stage.json" "${good[@]:1:2}" "$tmp/risk-other-stage2.json" \
  "$tmp/kill-other-stage.json" "$tmp/duty-other-stage.json" "${good[@]:6}"
pass 'gate evidence must be about the scope'"'"'s own stage request'

# A shadow record that claims any deploy authority is not an observation-only
# shadow record, whatever else it says.
"$jq_bin" -S -c '.body.records[0].body.deploy_authority = "grant"' "$tmp/shadow-set.json" \
  >"$tmp/shadow-deploy-authority.json"
scope_record "$tmp/shadow-deploy-authority.json" "$tmp/risk.json" "$tmp/kill.json" "$tmp/duty.json" \
  "$tmp/scope-deploy-authority.json"
expect_reasons shadow-deploy-authority \
  '["scope.malformed","scope.shadow-evidence-missing","scope.shadow-inconclusive"]' \
  "$tmp/scope-deploy-authority.json" "$tmp/shadow-deploy-authority.json" "${good[@]:2}"
pass 'a shadow record claiming deploy authority is refused as malformed'

# A gate evaluation the scope did not name is not the one it was qualified
# against, even when its verdict is fine: the digest the driver measured has to
# equal the digest the scope claimed.
"$jq_bin" -S -c '.body.reason_ids =
  ["decision.provenance-unqualified","duty.inconclusive"]' "$tmp/risk.json" \
  >"$tmp/risk-restated.json"
expect_reasons risk-digest-mismatch '["scope.malformed"]' "${good[@]:0:3}" \
  "$tmp/risk-restated.json" "${good[@]:4}"
"$jq_bin" -S -c '.body.state_ref.sha256 =
  "1ad2df26c1b0c9d5e3b3f0e0a3b6cf3f70b6e0e8e6b74ff96f5d0e1c6a0a3e12"' \
  "$tmp/kill.json" >"$tmp/kill-restated.json"
expect_reasons kill-digest-mismatch '["scope.malformed"]' "${good[@]:0:4}" \
  "$tmp/kill-restated.json" "${good[@]:5}"
# The three must belong together: one policy set, one stage, one duty
# evaluation. Each of these is a satisfied verdict produced for something else.
"$jq_bin" -S -c '.body.policy_set.id = "control.policy-set.other"' "$tmp/kill.json" \
  >"$tmp/kill-other-policy-set.json"
scope_for_gates "$tmp/risk.json" "$tmp/kill-other-policy-set.json" "$tmp/duty.json" \
  "$tmp/scope-kill-other-policy-set.json"
expect_reasons kill-other-policy-set '["scope.malformed"]' \
  "$tmp/scope-kill-other-policy-set.json" "${good[@]:1:3}" \
  "$tmp/kill-other-policy-set.json" "${good[@]:5}"
"$jq_bin" -S -c '.body.stage.request_ref.id = "stage.other.request"' "$tmp/duty.json" \
  >"$tmp/duty-other-stage.json"
scope_for_gates "$tmp/risk.json" "$tmp/kill.json" "$tmp/duty-other-stage.json" \
  "$tmp/scope-duty-other-stage.json"
expect_reasons duty-other-stage '["scope.malformed"]' \
  "$tmp/scope-duty-other-stage.json" "${good[@]:1:4}" "$tmp/duty-other-stage.json" \
  "${good[@]:6}"
"$jq_bin" -S -c '.body.duty_evaluation_ref.id = "stage.other.result"' "$tmp/kill.json" \
  >"$tmp/kill-other-duty.json"
scope_for_gates "$tmp/risk.json" "$tmp/kill-other-duty.json" "$tmp/duty.json" \
  "$tmp/scope-kill-other-duty.json"
expect_reasons kill-other-duty '["scope.malformed"]' \
  "$tmp/scope-kill-other-duty.json" "${good[@]:1:3}" "$tmp/kill-other-duty.json" \
  "${good[@]:5}"
# The scope's own resolved profile is the one the risk and duty evaluations must
# be about; a scope that records a different profile was never qualified by them.
"$jq_bin" -S -c '.body.qualified_identity.resolved_profile_ref.id =
  "resolved.other.v1"' "$tmp/scope.json" >"$tmp/scope-other-profile.json"
run_validator "$tmp/scope-other-profile.json" ||
  fail 'a scope naming another resolved profile was refused as malformed'
expect_reasons scope-other-profile '["scope.malformed"]' \
  "$tmp/scope-other-profile.json" "${good[@]:1}"
pass 'gate evidence counts only when the scope named it and the three agree'

# Binding the three by digest is not enough: their contents have to agree about
# what the duty evaluation said, because the real evaluators put the duty verdict
# into their own reasons. A pair no run could have produced is malformed, and the
# verdict reasons that follow from each document stand beside it.
"$jq_bin" -S -c '.body.reason_ids = ["decision.actor-unbound"]' \
  "$tmp/risk-duty-violated.json" >"$tmp/risk-duty-dropped.json"
scope_for_gates "$tmp/risk-duty-dropped.json" "$tmp/kill-duty-violated.json" \
  "$tmp/duty-violated.json" "$tmp/scope-risk-duty-dropped.json"
expect_reasons risk-missing-duty-violated \
  '["scope.duty-violation","scope.kill-switch","scope.malformed","scope.tier-not-routine"]' \
  "$tmp/scope-risk-duty-dropped.json" "${good[@]:1:2}" "$tmp/risk-duty-dropped.json" \
  "$tmp/kill-duty-violated.json" "$tmp/duty-violated.json" "${good[@]:6}"
"$jq_bin" -S -c '.body.verdict = "violated" | .body.reason_ids = ["duty.violated"]' \
  "$tmp/risk.json" >"$tmp/risk-claims-duty-violated.json"
scope_for_gates "$tmp/risk-claims-duty-violated.json" "$tmp/kill.json" "$tmp/duty.json" \
  "$tmp/scope-risk-claims-duty-violated.json"
expect_reasons risk-claims-duty-violated '["scope.malformed","scope.tier-not-routine"]' \
  "$tmp/scope-risk-claims-duty-violated.json" "${good[@]:1:2}" \
  "$tmp/risk-claims-duty-violated.json" "${good[@]:4}"
# The same contradiction the other way round and without any verdict problem to
# hide behind: an unknown the risk gate only emits for an inconclusive duty,
# beside a duty evaluation that is satisfied.
scope_for_gates "$tmp/risk-restated.json" "$tmp/kill.json" "$tmp/duty.json" \
  "$tmp/scope-risk-claims-duty-inconclusive.json"
expect_reasons risk-claims-duty-inconclusive '["scope.malformed"]' \
  "$tmp/scope-risk-claims-duty-inconclusive.json" "${good[@]:1:2}" \
  "$tmp/risk-restated.json" "${good[@]:4}"
# kill.duty-unverifiable is what the kill-switch evaluator emits for a duty
# document it could not verify, which a claimed and fully checked duty evaluation
# is not.
"$jq_bin" -S -c '.body.verdict = "inconclusive" |
  .body.reason_ids = ["kill.duty-unverifiable"]' "$tmp/kill.json" \
  >"$tmp/kill-duty-unverifiable.json"
scope_for_gates "$tmp/risk.json" "$tmp/kill-duty-unverifiable.json" "$tmp/duty.json" \
  "$tmp/scope-kill-duty-unverifiable.json"
expect_reasons kill-duty-unverifiable '["scope.kill-switch","scope.malformed"]' \
  "$tmp/scope-kill-duty-unverifiable.json" "${good[@]:1:3}" \
  "$tmp/kill-duty-unverifiable.json" "${good[@]:5}"
pass 'the three gate evaluations must agree with each other about the duty verdict'

# A gate evaluation is accepted only in its own evaluator's complete output
# shape, so a document that carries the envelope, the markers, and a verdict but
# is missing an evaluator field, carries one too many, names a ref of the wrong
# kind, or states a verdict its reasons do not support, is malformed. Each case
# claims the mutated document, so the refusal is the shape and not an unbound
# claim, and the verdict reason for that gate stands beside scope.malformed
# because a document that is not a real evaluation proves no verdict either.
"$jq_bin" -S -c 'del(.body.state_ref)' "$tmp/kill.json" >"$tmp/kill-no-state.json"
scope_for_gates "$tmp/risk.json" "$tmp/kill-no-state.json" "$tmp/duty.json" \
  "$tmp/scope-kill-no-state.json"
expect_reasons kill-missing-state-ref '["scope.kill-switch","scope.malformed"]' \
  "$tmp/scope-kill-no-state.json" "${good[@]:1:3}" "$tmp/kill-no-state.json" \
  "${good[@]:5}"
"$jq_bin" -S -c '.body.extra_field = "unexpected"' "$tmp/risk.json" \
  >"$tmp/risk-extra-key.json"
scope_for_gates "$tmp/risk-extra-key.json" "$tmp/kill.json" "$tmp/duty.json" \
  "$tmp/scope-risk-extra-key.json"
expect_reasons risk-extra-body-key '["scope.malformed","scope.tier-not-routine"]' \
  "$tmp/scope-risk-extra-key.json" "${good[@]:1:2}" "$tmp/risk-extra-key.json" \
  "${good[@]:4}"
"$jq_bin" -S -c '.body.reason_ids =
  ["kill.cleared-current","kill.state-invalid"]' "$tmp/kill.json" \
  >"$tmp/kill-extra-reason.json"
scope_for_gates "$tmp/risk.json" "$tmp/kill-extra-reason.json" "$tmp/duty.json" \
  "$tmp/scope-kill-extra-reason.json"
expect_reasons kill-satisfied-extra-reason '["scope.kill-switch","scope.malformed"]' \
  "$tmp/scope-kill-extra-reason.json" "${good[@]:1:3}" \
  "$tmp/kill-extra-reason.json" "${good[@]:5}"
"$jq_bin" -S -c '.body.stage.result_ref.kind = "stage_request"' "$tmp/duty.json" \
  >"$tmp/duty-wrong-kind.json"
scope_for_gates "$tmp/risk.json" "$tmp/kill.json" "$tmp/duty-wrong-kind.json" \
  "$tmp/scope-duty-wrong-kind.json"
expect_reasons duty-wrong-kind-ref '["scope.duty-violation","scope.malformed"]' \
  "$tmp/scope-duty-wrong-kind.json" "${good[@]:1:4}" "$tmp/duty-wrong-kind.json" \
  "${good[@]:6}"
pass 'a gate evaluation missing, exceeding, or contradicting its evaluator output is malformed'

# Qualification is attached to one exact target version. Shadow evidence from a
# different revision is evidence about a different target, so it does not count.
"$jq_bin" -S -c --argjson revision "$other_revision" \
  '.body.qualified_identity.target_revision = $revision' "$tmp/scope.json" \
  >"$tmp/scope-other-revision.json"
run_validator "$tmp/scope-other-revision.json" ||
  fail 'a scope naming another target revision was refused as malformed'
expect_reasons scope-other-revision '["scope.shadow-evidence-missing"]' \
  "$tmp/scope-other-revision.json" "${good[@]:1}"
"$jq_bin" -S -c --argjson revision "$other_revision" \
  '.body.records[0].body |= (.git_revision_ref = $revision |
   .materialization.value.source.commit_id = $revision.commit_id |
   .materialization.value.candidate.commit_id = $revision.commit_id |
   .materialization.value.candidate.parent_commit_id = $revision.commit_id)' \
  "$tmp/shadow-set.json" >"$tmp/shadow-other-revision.json"
scope_for_shadow "$tmp/shadow-other-revision.json" "$tmp/scope-shadow-revision.json"
expect_reasons shadow-other-revision '["scope.shadow-evidence-missing"]' \
  "$tmp/scope-shadow-revision.json" "$tmp/shadow-other-revision.json" "${good[@]:2}"
pass 'shadow evidence counts only at the target revision the scope records'

"$jq_bin" -S -c '.status = "operating"' "$tmp/marker.json" >"$tmp/marker-stale.json"
expect_reasons mode-stale-marker '["scope.mode-construction"]' "${good[@]:0:6}" \
  "$tmp/marker-stale.json"
"$jq_bin" -S -c '{status:"active"}' "$tmp/marker.json" >"$tmp/marker-shape.json"
expect_reasons mode-marker-shape '["scope.mode-construction"]' "${good[@]:0:6}" \
  "$tmp/marker-shape.json"
pass 'a marker that disagrees with the committed one leaves the mode unknown'

# The mode marker is an input like any other: it is snapshotted, size-bounded,
# required to be exactly one JSON text, and required to be canonical, so a
# pretty-printed or two-root marker never reaches the gate program and never has
# its digest recorded.
"$jq_bin" -S '.status = "retired"' "$tmp/marker.json" >"$tmp/marker-pretty.json"
expect_evaluator_error marker-non-canonical E_CANONICAL "${good[@]:0:6}" \
  "$tmp/marker-pretty.json"
{ /bin/cat "$tmp/marker.json"; /bin/cat "$tmp/marker.json"; } \
  >"$tmp/marker-multi-root.json"
expect_evaluator_error marker-multi-root E_PARSE "${good[@]:0:6}" \
  "$tmp/marker-multi-root.json"
pass 'the mode marker is canonicalized and single-rooted like every other input'

# The last four cases are what the whole-shape check adds: a record missing one
# of the slice's blocks, a record carrying one key more than the slice emits, a
# reproduced outcome whose materialization never ran, and a qualification with a
# reason id the slice never writes are all records no shadow run produced.
for malformed_case in 'del(.body.records[0].body.shadow)' \
  '.body.records[0].body.materialization.value.outcome = "changed"' \
  '.body.records[0].body.authority = "publisher"' \
  '.body.records[0].body.activation_state = "active"' \
  '.body.records[0].kind = "other_record"' \
  '.body.records = []' \
  'del(.body.records[0].body.materialization)' \
  '.body.records[0].body.replayed_from = "shadow.other"' \
  '.body.records[0].body.materialization =
     {state:"absent",reason_id:"materialization.not-attempted"}' \
  '.body.records[0].body.qualification.reason_id = "shadow.qualified"'; do
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

# The dashboard is judged against the evals framework's whole emitted shape, so a
# document carrying only the blocks this evaluator reads is not a dashboard. One
# of the framework's real top-level blocks missing, or one key more than it
# emits, is malformed, and the eval reasons follow because a dashboard that is
# not a dashboard grades nothing.
for dashboard_case in 'del(.body.flow)' 'del(.body.telemetry)' \
  'del(.body.evaluator)' 'del(.body.catalog_ref)' 'del(.body.coverage)' \
  '.body.extra_block = {}' '.extra = true' \
  '.body.core_contract.semantic_identity = "core.contracts.v1"' \
  '.body.coverage.families_total = 8' \
  '.body.observed_at = "2026-02-30T00:00:00Z"' \
  '.body.evaluator.content.body.runtime.host_os = "plan9"' \
  '.body.catalog_ref.kind = "eval_seed_set"'; do
  "$jq_bin" -S -c "$dashboard_case" "$tmp/dashboard.json" \
    >"$tmp/dashboard-shape.json"
  expect_reasons "dashboard shape $dashboard_case" \
    '["scope.eval-failing","scope.eval-family-unseeded","scope.malformed"]' \
    "${good[@]:0:2}" "$tmp/dashboard-shape.json" "${good[@]:3}"
done
pass 'the dashboard is validated against the evals framework complete emitted shape'

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
# A committed marker present as a symlink is not absent: the portable tree must
# refuse rather than let the supplied marker decide the mode.
/bin/mkdir -p "$tmp/portable/config"
/bin/ln -s /dev/null "$tmp/portable/config/construction-mode.json"
symlink_status=0
PATH="$bin:/usr/bin:/bin" "$fake_repo/evaluate-scope.sh" evaluate "${good[@]:0:6}" \
  "$tmp/marker-operating.json" >"$tmp/evaluation-symlink-marker.json" 2>"$tmp/symlink-marker.err" ||
  symlink_status=$?
[ "$symlink_status" -ne 0 ] && [ ! -s "$tmp/evaluation-symlink-marker.json" ] &&
  [ "$(/bin/cat "$tmp/symlink-marker.err")" = E_RUNTIME ] || fail 'a symlinked committed marker was not refused'
/bin/rm -f "$tmp/portable/config/construction-mode.json"
pass 'a committed marker that is not a regular file fails closed'

# The committed marker decides both the mode and the `repository_marker` field,
# and it is read before the gate program runs, so it is rechecked afterwards
# like every other input. These two cases change it while the run is in flight:
# a shim on PATH rewrites (or creates) the committed marker when the evaluator
# invokes the gate program, which is after the snapshot and before the stale
# checks. Both must be refused rather than emitting a result about marker bytes
# the repository no longer holds.
race_marker_case() {
  local label=$1 committed=$2 shape=${3:-file} status=0 out
  local race_repo="$tmp/race-$label" race_bin="$tmp/race-bin-$label"
  /bin/mkdir -p "$race_repo/scope/v1" "$race_repo/config"
  /bin/mkdir -m 700 "$race_bin"
  for shipped in scope-policy.json workflow-scope.jq scope-gates.jq \
    validate-scope.sh evaluate-scope.sh; do
    /bin/cp "$root/scope/v1/$shipped" "$race_repo/scope/v1/$shipped"
  done
  /bin/chmod 0500 "$race_repo/scope/v1/evaluate-scope.sh"
  if [ -n "$committed" ]; then
    /bin/cp "$committed" "$race_repo/config/construction-mode.json"
  fi
  { /usr/bin/printf '#!/bin/bash\nfor argument in "$@"; do\n'
    /usr/bin/printf '  case "$argument" in\n'
    /usr/bin/printf '    */scope-gates.jq)\n'
    if [ "$shape" = symlink ]; then
      /usr/bin/printf '      /bin/ln -sf /dev/null %s ;;\n' "$race_repo/config/construction-mode.json"
    else
      /usr/bin/printf '      /bin/cat %s > %s ;;\n' \
        "$tmp/marker-operating.json" "$race_repo/config/construction-mode.json"
    fi
    /usr/bin/printf '  esac\ndone\nexec %s "$@"\n' "$jq_bin"
  } >"$race_bin/jq"
  /bin/chmod 0555 "$race_bin/jq"
  out=$(PATH="$race_bin:/usr/bin:/bin" "$race_repo/scope/v1/evaluate-scope.sh" \
    evaluate "${good[@]:0:6}" "$tmp/marker.json" 2>&1 >/dev/null) || status=$?
  [ "$status" -ne 0 ] || fail "$label accepted a marker that changed mid-run"
  [ "$out" = E_STALE ] || fail "$label expected E_STALE got $out"
}
race_marker_case rewritten "$tmp/marker.json"
race_marker_case appeared ''
race_marker_case appeared-symlink '' symlink
pass 'a committed mode marker that changes while the run is in flight is stale'

/usr/bin/printf 'scope qualification: %s focused checks passed\n' "$passes"
