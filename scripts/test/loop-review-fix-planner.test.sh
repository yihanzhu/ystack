#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
planner="$root/loop/v1/plan-review-fix.sh"
policy="$root/loop/v1/review-fix-policy.json"
reviewer="$root/adapters/codex-native-reviewer/v1/normalize.jq"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-review-fix-test.XXXXXX")
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
if [ ! -f "$jq_cache" ] || [ -L "$jq_cache" ] ||
   [ "$(sha_file "$jq_cache")" != "$jq_sha" ]; then
  download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$download"
  [ "$(sha_file "$download")" = "$jq_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_cache"
fi
[ "$(sha_file "$jq_cache")" = "$jq_sha" ] || fail 'jq digest'
bin="$tmp/bin"
/bin/mkdir -m 700 "$bin"
/bin/cp "$jq_cache" "$bin/jq"
/bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"
[ "$("$jq_bin" --version)" = jq-1.6 ] || fail 'jq identity'

fixtures="$tmp/fixtures"
/bin/mkdir -m 700 "$fixtures"
review_input="$fixtures/review-input.json"
"$jq_bin" -S -c -n '
  def sha($character): $character * 64;
  def rev($character):
    {repository_id:"repo.example",hash_algorithm:"sha1",
     commit_id:($character * 40)};
  def inline($id;$path;$severity;$line):
    {finding_id:$id,path:$path,line:$line,side:"RIGHT",
     commit_id:rev("a").commit_id,body:("finding " + $id),
     provider_severity:$severity,provider_metadata:{}};
  def hidden: {state:"unavailable",reason_id:"codex.hidden"};
  {trust_context:{expected_repository_id:"11",expected_change_request_id:"22",
     expected_review_id:"33",expected_head:rev("a"),expected_base:rev("b"),
     expected_github_app_id:"44",observation_time:"2026-09-01T00:05:00Z",
     instruction_ref:{content_id:"codex-instruction",media_type:"text/plain",
       sha256:sha("1")},
     review_policy_ref:{content_id:"codex-review-policy",
       media_type:"application/json",sha256:sha("2")},
     execution_boundary_id:"boundary.reviewer",invocation_kind:"native-review"},
   snapshot:{repository_id:"11",change_request_id:"22",review_id:"33",
     head:rev("a"),base:rev("b"),github_app_id:"44",
     observed_at:"2026-09-01T00:05:00Z",status:"COMPLETED",complete:true,
     started_at:"2026-09-01T00:00:00Z",updated_at:"2026-09-01T00:04:00Z",
     terminal_at:"2026-09-01T00:03:00Z",dismissed_at:null,
     reported_top_level_count:1,reported_inline_count:3,
     top_level_findings:[{finding_id:"T1",body:"summary",
       provider_severity:"P2",provider_metadata:{}}],
     inline_findings:([inline("F1";"loop/v1/plan-review-fix.sh";"P1";12),
       inline("F2";"loop/v1/review-fix-planner.jq";"nit";40),
       inline("F3";"loop/v1/plan-review-fix.sh";"Important";80)] |
       sort_by([.path,.line,.side,.finding_id])),
     hidden_execution:{model:hidden,effort:hidden,tools:hidden,cost:hidden},
     provider_metadata:{}}}
' >"$review_input"
normalize() {
  local source=$1 target=$2
  "$jq_bin" -S -c -f "$reviewer" "$source" >"$target"
}
mutate() {
  local source=$1 name=$2 filter=$3
  local target="$fixtures/$name.json"
  "$jq_bin" -S -c "$filter" "$source" >"$target"
  /usr/bin/printf '%s\n' "$target"
}
observation="$fixtures/observation.json"
normalize "$review_input" "$observation"
"$jq_bin" -e '.state=="findings" and .stale_bindings==[]' "$observation" \
  >/dev/null || fail 'reviewer fixture'

credential="$fixtures/credential.json"
"$jq_bin" -S -c -n '
  def sha($character): $character * 64;
  def dref($version;$kind;$id;$character):
    {schema_version:$version,kind:$kind,id:$id,sha256:sha($character)};
  def cref($id;$media;$character):
    {content_id:$id,media_type:$media,sha256:sha($character)};
  def core:
    {semantic_identity:"core.contracts.v2",generation_id_sha256:sha("2"),
     package_ref:cref("core-contract-package.v2";
       "application/vnd.ystack.core-contract+json";"3")};
  def stage:
    {request_ref:dref(2;"stage_request";"request.review-fix";"8"),
     resolved_profile_ref:dref(2;"resolved_profile";"profile.review-fix";"9"),
     result_ref:dref(2;"stage_result";"result.review-fix";"a")};
  {schema_version:1,kind:"credential_policy_evaluation",id:"result.review-fix",
   body:{activation_state:"inactive",authority_effect:"none",
     claim_ref:dref(1;"credential_boundary_claim";"claim.review-fix";"1"),
     core_contract:core,
     decision_ref:cref("control-decision.credential-policy";
       "application/vnd.ystack.control-decision+json";"4"),
     duty_evaluation_ref:
       dref(1;"duty_separation_evaluation";"result.review-fix";"5"),
     evaluation_mode:"observation-only",
     policy_ref:cref("control-policy.credential-policy";
       "application/vnd.ystack.control-policy+json";"6"),
     policy_set:{id:"control-policy-set.review-fix",sha256:sha("7")},
     qualification_effect:"none",reason_ids:["credential.boundary-proven"],
     reference_semantics:"identity-only",stage:stage,verdict:"satisfied"}}
' >"$credential"
risk="$fixtures/risk.json"
"$jq_bin" -S -c -n '
  def sha($character): $character * 64;
  def dref($version;$kind;$id;$character):
    {schema_version:$version,kind:$kind,id:$id,sha256:sha($character)};
  def cref($id;$media;$character):
    {content_id:$id,media_type:$media,sha256:sha($character)};
  {schema_version:1,kind:"risk_gate_evaluation",id:"result.review-fix",
   body:{activation_state:"inactive",authority_effect:"none",
     classification:{declared_tier:"routine",minimum_tier:"routine"},
     core_contract:{semantic_identity:"core.contracts.v2",
       generation_id_sha256:sha("2"),
       package_ref:cref("core-contract-package.v2";
         "application/vnd.ystack.core-contract+json";"3")},
     decision_claim_ref:cref("risk-claim.review-fix";
       "application/vnd.ystack.risk-gate-decision-claim+json";"b"),
     decision_ref:cref("control-decision.risk-gates";
       "application/vnd.ystack.control-decision+json";"c"),
     duty_evaluation_ref:
       dref(1;"duty_separation_evaluation";"result.review-fix";"5"),
     evaluation_mode:"observation-only",
     policy_ref:cref("control-policy.risk-gates";
       "application/vnd.ystack.control-policy+json";"d"),
     policy_set:{id:"control-policy-set.review-fix",sha256:sha("7")},
     reason_ids:["risk-gates.satisfied"],reference_semantics:"identity-only",
     stage:{request_ref:dref(2;"stage_request";"request.review-fix";"8"),
       resolved_profile_ref:dref(2;"resolved_profile";"profile.review-fix";"9"),
       result_ref:dref(2;"stage_result";"result.review-fix";"a")},
     verdict:"satisfied"}}
' >"$risk"
reconciliation="$fixtures/reconciliation.json"
"$jq_bin" -S -c -n '
  def sha($character): $character * 64;
  {schema_version:1,kind:"orchestrator_reconciliation_plan",
   id:"observation.review-fix",
   body:{activation_state:"inactive",authority_effect:"none",
     concurrency:{active_pending:0,available_slots:2,max_in_flight:2},
     deferred:[],deliveries:[],
     delivery_ledger_ref:{schema_identity:"orchestrator.delivery-ledger.v1",
       kind:"orchestrator_delivery_ledger",id:"ledger.delivery",
       sha256:sha("e")},
     mode:"planning-only",
     observation_ref:{schema_identity:"orchestrator.state-observation.v1",
       kind:"orchestrator_state_observation",id:"observation.review-fix",
       sha256:sha("f")},
     operator_messages:[],suppressed:[]}}
' >"$reconciliation"
ledger="$fixtures/ledger.json"
"$jq_bin" -S -c -n '
  {schema_version:1,kind:"review_fix_attempt_ledger",id:"ledger.review-fix",
   body:{activation_state:"inactive",
     change_ref:{change_request_id:"22",repository_id:"11"},entries:[],
     ledger_contract:{declared_entry_count:0,maximum_entry_count:64,
       schema_identity:"loop.review-fix-attempt-ledger.v1"},
     recorded_at:"2026-09-01T00:06:00Z"}}
' >"$ledger"

bind_context() {
  local name=$1 credential_input=$2 reconciliation_input=$3 risk_input=$4
  local ledger_input=$5 filter=${6:-.} target="$fixtures/$name.json"
  "$jq_bin" -S -c -n \
    --arg credential "$(sha_file "$credential_input")" \
    --arg reconciliation "$(sha_file "$reconciliation_input")" \
    --arg risk "$(sha_file "$risk_input")" \
    --arg ledger "$(sha_file "$ledger_input")" "
    def rev(\$character):
      {repository_id:\"repo.example\",hash_algorithm:\"sha1\",
       commit_id:(\$character * 40)};
    {schema_version:1,kind:\"review_fix_change_context\",id:\"change.review-fix\",
     body:{activation_state:\"inactive\",approvals:[],base:rev(\"b\"),
       boundary_refs:{
         attempt_ledger_ref:{schema_version:1,
           kind:\"review_fix_attempt_ledger\",id:\"ledger.review-fix\",
           sha256:\$ledger},
         credential_evaluation_ref:{schema_version:1,
           kind:\"credential_policy_evaluation\",id:\"result.review-fix\",
           sha256:\$credential},
         reconciliation_plan_ref:{schema_version:1,
           kind:\"orchestrator_reconciliation_plan\",
           id:\"observation.review-fix\",sha256:\$reconciliation},
         risk_gate_evaluation_ref:{schema_version:1,
           kind:\"risk_gate_evaluation\",id:\"result.review-fix\",
           sha256:\$risk}},
       change_ref:{change_request_id:\"22\",repository_id:\"11\"},head:rev(\"a\"),
       kill_switch:{reason_id:\"kill.cleared-current\",state:\"cleared\"},
       observed_at:\"2026-09-01T00:07:00Z\"}} | $filter
  " >"$target"
  /usr/bin/printf '%s\n' "$target"
}
context=$(bind_context context "$credential" "$reconciliation" "$risk" "$ledger")

run_planner() {
  local name=$1 observation_input=$2 context_input=$3 credential_input=$4
  local reconciliation_input=$5 risk_input=$6 ledger_input=$7 status=0
  RUN_OUT="$tmp/$name.out"
  RUN_ERR="$tmp/$name.err"
  PATH="$bin:/usr/bin:/bin" /usr/bin/perl -e 'alarm shift; exec @ARGV' 60 \
    "$planner" plan "$observation_input" "$context_input" "$credential_input" \
    "$reconciliation_input" "$risk_input" "$ledger_input" \
    >"$RUN_OUT" 2>"$RUN_ERR" || status=$?
  RUN_STATUS=$status
}
expect_plan() {
  local name=$1 observation_input=$2 context_input=$3 credential_input=$4
  local reconciliation_input=$5 risk_input=$6 ledger_input=$7
  run_planner "$name" "$observation_input" "$context_input" \
    "$credential_input" "$reconciliation_input" "$risk_input" "$ledger_input"
  [ "$RUN_STATUS" -eq 0 ] && [ ! -s "$RUN_ERR" ] || fail "$name status"
  /usr/bin/cmp -s "$RUN_OUT" <("$jq_bin" -S -c . "$RUN_OUT") ||
    fail "$name canonical"
}
expect_refusal() {
  local name=$1 reason=$2 detail=$3 context_input=$4 observation_input=${5:-$observation}
  local credential_input=${6:-$credential} reconciliation_input=${7:-$reconciliation}
  local risk_input=${8:-$risk} ledger_input=${9:-$ledger}
  expect_plan "$name" "$observation_input" "$context_input" \
    "$credential_input" "$reconciliation_input" "$risk_input" "$ledger_input"
  "$jq_bin" -e --arg reason "$reason" --arg detail "$detail" '
    .body.decision.outcome=="refusal" and
    (.body.decision|keys|sort)==["detail_ids","outcome","reason_id"] and
    .body.decision.reason_id==$reason and
    (.body.decision.detail_ids|index($detail))!=null and
    (.body.decision.detail_ids|.==(sort|unique)) and
    (.body|has("fix_request")|not)
  ' "$RUN_OUT" >/dev/null || fail "$name refusal"
  pass "$name"
}
expect_error() {
  local name=$1 expected=$2
  shift 2
  local status=0
  RUN_OUT="$tmp/$name.out"
  RUN_ERR="$tmp/$name.err"
  PATH="$bin:/usr/bin:/bin" /usr/bin/perl -e 'alarm shift; exec @ARGV' 60 \
    "$@" >"$RUN_OUT" 2>"$RUN_ERR" || status=$?
  if [ "$status" -eq 0 ] || [ -s "$RUN_OUT" ] ||
     [ "$(/bin/cat "$RUN_ERR")" != "$expected" ] ||
     /usr/bin/grep -Fq "$tmp" "$RUN_ERR"; then
    fail "$name"
  fi
  pass "$name"
}
expect_plan happy "$observation" "$context" "$credential" "$reconciliation" \
  "$risk" "$ledger"
happy="$tmp/happy.out"
expected="$tmp/expected.json"
"$jq_bin" -S -c -n \
  --arg policy_sha "$(sha_file "$policy")" \
  --arg observation_sha "$(sha_file "$observation")" \
  --arg context_sha "$(sha_file "$context")" \
  --arg credential_sha "$(sha_file "$credential")" \
  --arg reconciliation_sha "$(sha_file "$reconciliation")" \
  --arg risk_sha "$(sha_file "$risk")" \
  --arg ledger_sha "$(sha_file "$ledger")" '
  def rev($character):
    {repository_id:"repo.example",hash_algorithm:"sha1",
     commit_id:($character * 40)};
  {schema_version:1,kind:"review_fix_plan",id:"change.review-fix",
   body:{activation_state:"inactive",
     attempt:{limit:2,next_number:1,recorded_count:0},authority:"none",
     change_ref:{change_request_id:"22",repository_id:"11"},
     decision:{outcome:"fix-request",
       fix_request:{allowed_paths:["loop/v1/plan-review-fix.sh"],
         artifact_kind:"git-patch",attempt:{limit:2,number:1},authority:"none",
         base:rev("b"),capability_id:"core.harness.produce.v1",
         findings:[{finding_id:"F1",path:"loop/v1/plan-review-fix.sh",
             provider_severity:"P1"},
           {finding_id:"F3",path:"loop/v1/plan-review-fix.sh",
             provider_severity:"Important"}],
         head:rev("a"),
         permissions:["core.perm.evidence.write.v1","core.perm.model.invoke.v1",
           "core.perm.scratch.write.v1","core.perm.target.read.v1"],
         push_allowed:false,push_allowed_reason_id:"loop.inactive-planner",
         request_kind:"stage_request",
         review_ref:{change_request_id:"22",repository_id:"11",review_id:"33"},
         role:"producer",target_repository_id:"repo.example"}},
     effects:[],
     inputs:{
       attempt_ledger_ref:{schema_version:1,kind:"review_fix_attempt_ledger",
         id:"ledger.review-fix",sha256:$ledger_sha},
       change_context_ref:{schema_version:1,kind:"review_fix_change_context",
         id:"change.review-fix",sha256:$context_sha},
       credential_evaluation_ref:{schema_version:1,
         kind:"credential_policy_evaluation",id:"result.review-fix",
         sha256:$credential_sha},
       observation_ref:{content_id:"loop-review-observation",
         media_type:"application/json",sha256:$observation_sha},
       policy_ref:{content_id:"loop-policy.review-fix",
         media_type:"application/vnd.ystack.loop-policy+json",
         sha256:$policy_sha},
       reconciliation_plan_ref:{schema_version:1,
         kind:"orchestrator_reconciliation_plan",id:"observation.review-fix",
         sha256:$reconciliation_sha},
       risk_gate_evaluation_ref:{schema_version:1,kind:"risk_gate_evaluation",
         id:"result.review-fix",sha256:$risk_sha}},
     mode:"planning-only",observed_at:"2026-09-01T00:07:00Z",
     qualification:{reason_id:"loop.unqualified",state:"unavailable"}}}
' >"$expected"
/usr/bin/cmp -s "$happy" "$expected" || fail 'happy path bytes'
pass 'one bounded fix request is produced byte for byte'

expect_plan repeat "$observation" "$context" "$credential" "$reconciliation" \
  "$risk" "$ledger"
/usr/bin/cmp -s "$tmp/repeat.out" "$expected" || fail 'repeat bytes'
pass 'a repeated run returns identical bytes'

"$jq_bin" -e '
  .body.authority=="none" and .body.effects==[] and
  .body.mode=="planning-only" and .body.activation_state=="inactive" and
  .body.qualification=={reason_id:"loop.unqualified",state:"unavailable"} and
  .body.decision.fix_request.authority=="none" and
  .body.decision.fix_request.push_allowed==false and
  ((.body|has("grant_ref") or has("activation") or has("qualification_ref"))|not)
' "$happy" >/dev/null || fail 'inactive output'
pass 'the plan grants, qualifies, and activates nothing'

"$jq_bin" -e '
  .body.decision.fix_request as $request |
  ($request.findings|map(.finding_id))==["F1","F3"] and
  $request.allowed_paths==["loop/v1/plan-review-fix.sh"] and
  ($request.allowed_paths|
    all(.[]; . as $path | $request.findings|map(.path)|index($path)!=null)) and
  $request.head.commit_id==("a"*40) and $request.base.commit_id==("b"*40)
' "$happy" >/dev/null || fail 'bounded request'
pass 'the request lists only actionable findings and their own files'

kill_context=$(mutate "$context" kill-context \
  '.body.kill_switch={reason_id:"kill.global-stop",state:"engaged"}')
expect_refusal kill-switch kill-switch kill.global-stop "$kill_context"

credential_unproven=$(mutate "$credential" credential-unproven \
  '.body.verdict="inconclusive"|.body.reason_ids=["claim.provenance-unqualified"]')
credential_unproven_context=$(bind_context credential-unproven-context \
  "$credential_unproven" "$reconciliation" "$risk" "$ledger")
expect_refusal credential-not-satisfied boundaries-unproven \
  boundary.credential-not-satisfied "$credential_unproven_context" \
  "$observation" "$credential_unproven"
expect_refusal credential-identity boundaries-unproven \
  boundary.credential-identity-mismatch "$context" "$observation" \
  "$credential_unproven"

reconciliation_open=$(mutate "$reconciliation" reconciliation-open \
  '.body.operator_messages=[{class:"blocked",stage_key:{}}]')
reconciliation_open_context=$(bind_context reconciliation-open-context \
  "$credential" "$reconciliation_open" "$risk" "$ledger")
expect_refusal reconciliation-open boundaries-unproven \
  boundary.reconciliation-unreconciled "$reconciliation_open_context" \
  "$observation" "$credential" "$reconciliation_open"
expect_refusal reconciliation-identity boundaries-unproven \
  boundary.reconciliation-identity-mismatch "$context" "$observation" \
  "$credential" "$reconciliation_open"
reconciliation_pending=$(mutate "$reconciliation" reconciliation-pending \
  '.body.deliveries=[{delivery_key:"delivery.one",delivery_mode:"dispatch",operation:"deliver",provenance:{},recovery:{},stage_key:{}}]')
reconciliation_pending_context=$(bind_context reconciliation-pending-context \
  "$credential" "$reconciliation_pending" "$risk" "$ledger")
expect_refusal reconciliation-pending-deliveries boundaries-unproven \
  boundary.reconciliation-unreconciled "$reconciliation_pending_context" \
  "$observation" "$credential" "$reconciliation_pending"
reconciliation_inflight=$(mutate "$reconciliation" reconciliation-inflight \
  '.body.concurrency.active_pending=1|.body.concurrency.available_slots=1')
reconciliation_inflight_context=$(bind_context reconciliation-inflight-context \
  "$credential" "$reconciliation_inflight" "$risk" "$ledger")
expect_refusal reconciliation-inflight boundaries-unproven \
  boundary.reconciliation-unreconciled "$reconciliation_inflight_context" \
  "$observation" "$credential" "$reconciliation_inflight"

risk_unproven=$(mutate "$risk" risk-unproven \
  '.body.verdict="violated"|.body.reason_ids=["push.after-approval"]')
risk_unproven_context=$(bind_context risk-unproven-context "$credential" \
  "$reconciliation" "$risk_unproven" "$ledger")
expect_refusal risk-not-satisfied boundaries-unproven \
  boundary.risk-not-satisfied "$risk_unproven_context" "$observation" \
  "$credential" "$reconciliation" "$risk_unproven"
expect_refusal risk-identity boundaries-unproven \
  boundary.risk-identity-mismatch "$context" "$observation" "$credential" \
  "$reconciliation" "$risk_unproven"

ledger_other=$(mutate "$ledger" ledger-other \
  '.body.change_ref.change_request_id="99"')
ledger_other_context=$(bind_context ledger-other-context "$credential" \
  "$reconciliation" "$risk" "$ledger_other")
expect_refusal ledger-change boundaries-unproven \
  boundary.attempt-ledger-change-mismatch "$ledger_other_context" \
  "$observation" "$credential" "$reconciliation" "$risk" "$ledger_other"
expect_refusal ledger-identity boundaries-unproven \
  boundary.attempt-ledger-identity-mismatch "$context" "$observation" \
  "$credential" "$reconciliation" "$risk" "$ledger_other"
ledger_late=$(mutate "$ledger" ledger-late \
  '.body.recorded_at="2026-09-01T00:08:00Z"')
ledger_late_context=$(bind_context ledger-late-context "$credential" \
  "$reconciliation" "$risk" "$ledger_late")
expect_refusal ledger-late boundaries-unproven \
  boundary.attempt-ledger-not-yet-observed "$ledger_late_context" \
  "$observation" "$credential" "$reconciliation" "$risk" "$ledger_late"

moved_head=$(bind_context moved-head-context "$credential" "$reconciliation" \
  "$risk" "$ledger" '.body.head.commit_id=("c"*40)')
expect_refusal moved-head review-stale review.head-mismatch "$moved_head"
moved_base=$(bind_context moved-base-context "$credential" "$reconciliation" \
  "$risk" "$ledger" '.body.base.commit_id=("d"*40)')
expect_refusal moved-base review-stale review.base-mismatch "$moved_base"
stale_review="$fixtures/observation-stale.json"
normalize "$(mutate "$review_input" review-stale-input \
  '.trust_context.expected_review_id="77"')" "$stale_review"
expect_refusal stale-bindings review-stale review.bindings-stale "$context" \
  "$stale_review"
cleared_review_binding=$(mutate "$stale_review" observation-cleared-review '
  .stale_bindings=[]|.state="findings"|.reason_id="codex.review-findings"')
expect_refusal cleared-review-binding review-stale review.bindings-stale \
  "$context" "$cleared_review_binding"
app_review="$fixtures/observation-app.json"
normalize "$(mutate "$review_input" review-app-input \
  '.trust_context.expected_github_app_id="55"')" "$app_review"
cleared_app_binding=$(mutate "$app_review" observation-cleared-app '
  .stale_bindings=[]|.state="findings"|.reason_id="codex.review-findings"')
expect_refusal cleared-app-binding review-stale review.bindings-stale \
  "$context" "$cleared_app_binding"
forged_bindings=$(mutate "$observation" observation-forged-bindings \
  '.stale_bindings=["head"]')
expect_refusal forged-bindings review-stale review.bindings-unverified \
  "$context" "$forged_bindings"

dismissed_review="$fixtures/observation-dismissed.json"
normalize "$(mutate "$review_input" review-dismissed-input \
  '.snapshot.status="DISMISSED"|.snapshot.dismissed_at="2026-09-01T00:04:00Z"')" \
  "$dismissed_review"
expect_refusal dismissed degraded-review review.dismissed "$context" \
  "$dismissed_review"
timeout_review="$fixtures/observation-timeout.json"
normalize "$(mutate "$review_input" review-timeout-input \
  '.snapshot.status="TIMED_OUT"')" "$timeout_review"
expect_refusal timed-out degraded-review review.timeout "$context" \
  "$timeout_review"
partial_review="$fixtures/observation-partial.json"
normalize "$(mutate "$review_input" review-partial-input \
  '.snapshot.complete=false|.snapshot.reported_inline_count=9')" \
  "$partial_review"
expect_refusal incomplete degraded-review review.incomplete "$context" \
  "$partial_review"
# A snapshot marked incomplete while the observation still claims a settled
# state is not a degraded review but a forged one: the state disagrees with
# the normalizer's own derivation, so the document is refused as malformed.
expect_error forged-incomplete-state E_RELATION "$planner" plan \
  "$(mutate "$observation" observation-forged-incomplete \
    '.observation.complete=false')" \
  "$context" "$credential" "$reconciliation" "$risk" "$ledger"

approved=$(bind_context approved-context "$credential" "$reconciliation" \
  "$risk" "$ledger" \
  '.body.approvals=[{approval_id:"approval.one",commit_id:("a"*40),recorded_at:"2026-09-01T00:06:30Z"}]')
expect_refusal approval-on-head approval-present approval.recorded-on-head \
  "$approved"
superseded=$(bind_context superseded-context "$credential" "$reconciliation" \
  "$risk" "$ledger" \
  '.body.approvals=[{approval_id:"approval.one",commit_id:("b"*40),recorded_at:"2026-09-01T00:06:30Z"}]')
expect_plan superseded-approval "$observation" "$superseded" "$credential" \
  "$reconciliation" "$risk" "$ledger"
"$jq_bin" -e '
  .body.decision.outcome=="fix-request" and
  .body.decision.fix_request.push_allowed==false and
  .body.decision.fix_request.push_allowed_reason_id=="loop.no-push-after-approval"
' "$tmp/superseded-approval.out" >/dev/null || fail 'no-push-after-approval'
pass 'an approval anywhere on the change forbids a push'

full_ledger=$(mutate "$ledger" ledger-full '
  .body.entries=[{attempt_id:"attempt.one",attempt_number:1,
      head_commit_id:("a"*40),outcome:"failed",
      recorded_at:"2026-09-01T00:05:30Z"},
    {attempt_id:"attempt.two",attempt_number:2,head_commit_id:("a"*40),
      outcome:"failed",recorded_at:"2026-09-01T00:05:40Z"}] |
  .body.ledger_contract.declared_entry_count=2')
full_ledger_context=$(bind_context ledger-full-context "$credential" \
  "$reconciliation" "$risk" "$full_ledger")
expect_refusal attempt-limit attempt-limit attempt.limit-reached \
  "$full_ledger_context" "$observation" "$credential" "$reconciliation" \
  "$risk" "$full_ledger"

clean_review="$fixtures/observation-clean.json"
normalize "$(mutate "$review_input" review-clean-input '
  .snapshot.reported_top_level_count=0|.snapshot.reported_inline_count=0|
  .snapshot.top_level_findings=[]|.snapshot.inline_findings=[]')" \
  "$clean_review"
expect_refusal clean-review no-actionable-findings findings.review-clean \
  "$context" "$clean_review"
nit_review="$fixtures/observation-nits.json"
normalize "$(mutate "$review_input" review-nits-input '
  .snapshot.inline_findings=[.snapshot.inline_findings[]|
    select(.provider_severity=="nit")]|
  .snapshot.reported_inline_count=1|.snapshot.top_level_findings=[]|
  .snapshot.reported_top_level_count=0')" "$nit_review"
expect_refusal nits-only no-actionable-findings findings.none-actionable \
  "$context" "$nit_review"

expect_error wrong-verb E_USAGE "$planner" evaluate "$observation" "$context" \
  "$credential" "$reconciliation" "$risk" "$ledger"
expect_error wrong-arity E_USAGE "$planner" plan "$observation" "$context"
expect_error missing-input E_RUNTIME "$planner" plan "$observation" "$context" \
  "$credential" "$reconciliation" "$risk" "$tmp/absent.json"
expect_error directory-input E_RUNTIME "$planner" plan "$observation" \
  "$context" "$credential" "$reconciliation" "$risk" "$fixtures"
/bin/ln -s "$ledger" "$tmp/ledger-link.json"
expect_error symlink-input E_RUNTIME "$planner" plan "$observation" "$context" \
  "$credential" "$reconciliation" "$risk" "$tmp/ledger-link.json"
relative_status=0
relative_out="$tmp/relative.out"
relative_err="$tmp/relative.err"
(cd "$fixtures" && PATH="$bin:/usr/bin:/bin" \
  /usr/bin/perl -e 'alarm shift; exec @ARGV' 60 "$planner" plan \
  "$observation" "$context" "$credential" "$reconciliation" "$risk" \
  ledger.json >"$relative_out" 2>"$relative_err") || relative_status=$?
if [ "$relative_status" -eq 0 ] || [ -s "$relative_out" ] ||
   [ "$(/bin/cat "$relative_err")" != E_RUNTIME ]; then
  fail 'relative input path'
fi
pass 'a relative input path is refused'

/usr/bin/printf '%s' '{"kind":' >"$tmp/malformed.json"
expect_error malformed-input E_PARSE "$planner" plan "$observation" "$context" \
  "$credential" "$reconciliation" "$risk" "$tmp/malformed.json"
/bin/cat "$ledger" "$ledger" >"$tmp/multi-root.json"
expect_error multi-root-input E_PARSE "$planner" plan "$observation" \
  "$context" "$credential" "$reconciliation" "$risk" "$tmp/multi-root.json"
"$jq_bin" -S . "$ledger" >"$tmp/pretty.json"
expect_error non-canonical-input E_CANONICAL "$planner" plan "$observation" \
  "$context" "$credential" "$reconciliation" "$risk" "$tmp/pretty.json"
"$jq_bin" -S -c -n '{schema_version:1,padding:("z"*1400000)}' \
  >"$tmp/oversize.json"
expect_error oversize-input E_LIMIT "$planner" plan "$observation" "$context" \
  "$credential" "$reconciliation" "$risk" "$tmp/oversize.json"
"$jq_bin" -S -c -n 'reduce range(0;33) as $index (0;{value:.})' \
  >"$tmp/deep.json"
expect_error deep-input E_LIMIT "$planner" plan "$observation" "$context" \
  "$credential" "$reconciliation" "$risk" "$tmp/deep.json"

expect_error context-unknown-field E_RELATION "$planner" plan "$observation" \
  "$(mutate "$context" context-unknown '.body.untrusted="value"')" \
  "$credential" "$reconciliation" "$risk" "$ledger"
expect_error context-head-equals-base E_RELATION "$planner" plan \
  "$observation" \
  "$(mutate "$context" context-degenerate '.body.base.commit_id=("a"*40)')" \
  "$credential" "$reconciliation" "$risk" "$ledger"
expect_error credential-unknown-field E_RELATION "$planner" plan \
  "$observation" "$context" \
  "$(mutate "$credential" credential-unknown '.body.untrusted="value"')" \
  "$reconciliation" "$risk" "$ledger"
expect_error observation-forged-adapter E_RELATION "$planner" plan \
  "$(mutate "$observation" observation-forged '.adapter.status="active"')" \
  "$context" "$credential" "$reconciliation" "$risk" "$ledger"
expect_error observation-granted-authority E_RELATION "$planner" plan \
  "$(mutate "$observation" observation-authority '.authority="full"')" \
  "$context" "$credential" "$reconciliation" "$risk" "$ledger"
expect_error observation-inline-count-over E_RELATION "$planner" plan \
  "$(mutate "$observation" observation-inline-over \
    '.observation.reported_inline_count=9')" \
  "$context" "$credential" "$reconciliation" "$risk" "$ledger"
expect_error observation-inline-count-under E_RELATION "$planner" plan \
  "$(mutate "$observation" observation-inline-under \
    '.observation.reported_inline_count=1')" \
  "$context" "$credential" "$reconciliation" "$risk" "$ledger"
expect_error observation-top-level-count-mismatch E_RELATION "$planner" plan \
  "$(mutate "$observation" observation-top-level-miscount \
    '.observation.reported_top_level_count=5')" \
  "$context" "$credential" "$reconciliation" "$risk" "$ledger"
expect_error ledger-count-mismatch E_RELATION "$planner" plan "$observation" \
  "$context" "$credential" "$reconciliation" "$risk" \
  "$(mutate "$ledger" ledger-miscounted \
    '.body.ledger_contract.declared_entry_count=3')"
expect_error reconciliation-active E_RELATION "$planner" plan "$observation" \
  "$context" "$credential" \
  "$(mutate "$reconciliation" reconciliation-active '.body.mode="dispatching"')" \
  "$risk" "$ledger"
expect_error completed-with-dismissed-at E_RELATION "$planner" plan \
  "$(mutate "$observation" completed-dismissed \
    '.observation.dismissed_at="2026-09-01T00:04:00Z"')" \
  "$context" "$credential" "$reconciliation" "$risk" "$ledger"
expect_error completed-without-terminal-at E_RELATION "$planner" plan \
  "$(mutate "$observation" completed-no-terminal \
    '.observation.terminal_at=null')" \
  "$context" "$credential" "$reconciliation" "$risk" "$ledger"
expect_error forged-clean-state-over-dismissed E_RELATION "$planner" plan \
  "$(mutate "$observation" forged-clean \
    '.observation.status="DISMISSED"|.observation.dismissed_at="2026-09-01T00:04:00Z"')" \
  "$context" "$credential" "$reconciliation" "$risk" "$ledger"

race_root="$tmp/race"
/bin/mkdir -p "$race_root/loop/v1"
/bin/cp "$planner" "$policy" "$race_root/loop/v1/"
/bin/chmod 0755 "$race_root/loop/v1/plan-review-fix.sh"
/usr/bin/printf '%s\n' \
  'def spin: reduce range(0;20000000) as $index (0; . + 1);' \
  'spin as $ignored |' \
  '{schema_version:1,kind:"review_fix_plan",id:"change.review-fix",' \
  ' body:{activation_state:"inactive",authority:"none",' \
  '   decision:{detail_ids:["kill.stub"],outcome:"refusal",' \
  '     reason_id:"kill-switch"},effects:[],mode:"planning-only",' \
  '   qualification:{reason_id:"loop.unqualified",state:"unavailable"}}}' \
  >"$race_root/loop/v1/review-fix-planner.jq"
race_ledger="$tmp/race-ledger.json"
/bin/cp "$ledger" "$race_ledger"
race_tmp="$tmp/race-scratch"
/bin/mkdir -m 700 "$race_tmp"
race_out="$tmp/race.out"
race_err="$tmp/race.err"
TMPDIR="$race_tmp" PATH="$bin:/usr/bin:/bin" \
  /usr/bin/perl -e 'alarm shift; exec @ARGV' 60 \
  "$race_root/loop/v1/plan-review-fix.sh" plan "$observation" "$context" \
  "$credential" "$reconciliation" "$risk" "$race_ledger" \
  >"$race_out" 2>"$race_err" &
race_pid=$!
attempt=0
while [ -z "$(/usr/bin/find "$race_tmp" -name ledger.json -print 2>/dev/null)" ] &&
      kill -0 "$race_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
  attempt=$((attempt + 1))
  /bin/sleep 0.01
done
"$jq_bin" -S -c '.body.recorded_at="2026-09-01T00:05:59Z"' "$ledger" \
  >"$tmp/race-moved.json"
/bin/mv "$tmp/race-moved.json" "$race_ledger"
race_status=0
wait "$race_pid" || race_status=$?
if [ "$race_status" -eq 0 ] || [ -s "$race_out" ] ||
   [ "$(/bin/cat "$race_err")" != E_RELATION ]; then
  fail 'moved input postflight'
fi
pass 'an input changed after the snapshot is refused'

for owned in loop/v1/plan-review-fix.sh loop/v1/review-fix-planner.jq \
  loop/v1/review-fix-policy.json scripts/test/loop-review-fix-planner.test.sh; do
  [ -f "$root/$owned" ] && [ ! -L "$root/$owned" ] || fail "owned path $owned"
done
pass 'owned product and test paths are complete'
/usr/bin/printf 'loop review-fix planner: %s focused checks passed\n' "$passes"
