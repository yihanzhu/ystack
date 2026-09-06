#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
evaluator="$root/deploy/v1/evaluate-deploy.sh"
validator="$root/deploy/v1/validate-deploy-document.sh"
tiers="$root/deploy/v1/environment-tiers.json"
decision="$root/deploy/v1/deploy-decision.json"
dormant="$root/adapter-tests/v1/fakes/deploy-dormant.sh"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-deploy-gates-test.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() { /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) jq_asset=jq-osx-amd64; jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_asset=jq-linux64; jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) fail "unsupported host $platform" ;;
esac
jq_cache_dir="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$jq_cache_dir"
jq_cache="$jq_cache_dir/$jq_asset"
if [ ! -f "$jq_cache" ] || [ "$(sha256_path "$jq_cache")" != "$jq_sha" ]; then
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
[ "$($jq_bin --version)" = jq-1.6 ] || fail 'jq identity'
pass 'pinned jq 1.6 runtime'

mutate() {
  local source=$1 name=$2 filter=$3 target
  target="$tmp/$name.json"
  "$jq_bin" -S -c "$filter" "$source" >"$target"
  /usr/bin/printf '%s\n' "$target"
}

release="$tmp/release.json"
"$jq_bin" -S -c -n '
  def core_ref($id;$sha): {schema_version:2,kind:"stage_result",id:$id,sha256:$sha};
  {schema_version:1,kind:"release_record",id:"release.moon-garden.0001",
   body:{activation_state:"inactive",authority:"none",
     qualification:{reason:"no-deployment-adapter-exists",state:"unavailable"},
     release_id:"release.moon-garden.0001",
     source:{commit_id:("a"*40),hash_algorithm:"sha1",repository_id:"repository.target",
       tree_id:("b"*40)},
     verification:{status:"verified",verified_commit_id:("a"*40),verified_tree_id:("b"*40),
       verifier_result_ref:core_ref("result.verify.0001";("1"*64))},
     evidence:{
       ci:{evidence_id:"evidence.ci",stage_result_ref:core_ref("result.ci.0001";("2"*64))},
       independent_review:{evidence_id:"evidence.review",
         stage_result_ref:core_ref("result.review.0001";("3"*64))},
       verifier:{evidence_id:"evidence.deterministic",
         stage_result_ref:core_ref("result.verify.0001";("1"*64))},
       packaging_release_manifest:{content_id:"release-manifest.0001",
         media_type:"application/vnd.ystack.release-manifest+json",sha256:("4"*64)}}}}
' >"$release"
release_sha=$(sha256_path "$release")
previous=$(mutate "$release" previous-release '
  .id="release.moon-garden.0000"|.body.release_id="release.moon-garden.0000"|
  .body.source.commit_id=("c"*40)|.body.source.tree_id=("d"*40)|
  .body.verification.verified_commit_id=("c"*40)|
  .body.verification.verified_tree_id=("d"*40)')
previous_sha=$(sha256_path "$previous")

authorization="$tmp/authorization.json"
"$jq_bin" -S -c -n --arg release_sha "$release_sha" '
  {schema_version:1,kind:"deploy_authorization",id:"deploy-authorization.production.0001",
   body:{activation_state:"inactive",authority:"none",authorization_kind:"named-operator",
     decision:"authorized",environment:{tier:"production"},
     expires_at:"2026-09-06T00:00:00Z",issued_at:"2026-09-05T00:00:00Z",
     operator:{display_name:"Named release operator",principal_id:"principal.operator",
       role:"operator"},
     release_ref:{schema_version:1,kind:"release_record",id:"release.moon-garden.0001",
       sha256:$release_sha}}}
' >"$authorization"
authorization_sha=$(sha256_path "$authorization")

rehearsal="$tmp/rehearsal.json"
"$jq_bin" -S -c -n --arg release_sha "$release_sha" --arg previous_sha "$previous_sha" '
  {schema_version:1,kind:"rollback_rehearsal_record",id:"rollback-rehearsal.production.0001",
   body:{activation_state:"inactive",authority:"none",environment:{tier:"production"},
     evidence:{evidence_id:"evidence.rehearsal",
       stage_result_ref:{schema_version:2,kind:"stage_result",id:"result.rehearsal.0001",
         sha256:("5"*64)}},
     from_release_ref:{schema_version:1,kind:"release_record",id:"release.moon-garden.0001",
       sha256:$release_sha},
     to_release_ref:{schema_version:1,kind:"release_record",id:"release.moon-garden.0000",
       sha256:$previous_sha},
     outcome:"rehearsed",rehearsed_at:"2026-09-04T00:00:00Z"}}
' >"$rehearsal"
rehearsal_sha=$(sha256_path "$rehearsal")

policy_set_id=control-policy-set.deploy-test
request="$tmp/request-deploy.json"
"$jq_bin" -S -c -n --arg release_sha "$release_sha" \
  --arg authorization_sha "$authorization_sha" --arg policy_set_id "$policy_set_id" '
  {schema_version:1,kind:"deploy_request",id:"deploy-request.production.0001",
   body:{activation_state:"inactive",authority:"none",
     actor_ref:{adapter_instance_id:"instance.publisher",
       execution_boundary_id:"boundary.publisher",implementation_id:"impl.dormant-publisher",
       implementation_version:"v1",principal_id:"principal.publisher",role:"publisher"},
     authorization_ref:{schema_version:1,kind:"deploy_authorization",
       id:"deploy-authorization.production.0001",sha256:$authorization_sha},
     environment:{tier:"production"},
     policy_set:{id:$policy_set_id,sha256:("6"*64)},
     release_ref:{schema_version:1,kind:"release_record",id:"release.moon-garden.0001",
       sha256:$release_sha},
     requested_at:"2026-09-05T12:00:00Z",requested_capability:"deploy"}}
' >"$request"

risk="$tmp/risk.json"
"$jq_bin" -S -c -n --arg policy_set_id "$policy_set_id" '
  {schema_version:1,kind:"risk_gate_evaluation",id:"result.deploy-test",
   body:{activation_state:"inactive",evaluation_mode:"observation-only",
     reference_semantics:"identity-only",
     policy_set:{id:$policy_set_id,sha256:("6"*64)},verdict:"inconclusive",
     reason_ids:["risk-gates.minimum-tier-unknown"]}}
' >"$risk"
kill_switch="$tmp/kill.json"
"$jq_bin" -S -c -n --arg policy_set_id "$policy_set_id" '
  {schema_version:1,kind:"kill_switch_evaluation",id:"kill-attempt.deploy-test",
   body:{activation_state:"inactive",evaluation_mode:"observation-only",
     reference_semantics:"identity-only",
     policy_set:{id:$policy_set_id,sha256:("6"*64)},verdict:"satisfied",
     reason_ids:["kill.cleared-current"]}}
' >"$kill_switch"

RUN_STATUS=0
run_evaluator() {
  local active=$1 out=$2 err=$3 status=0
  shift 3
  PATH="$bin:/usr/bin:/bin" /usr/bin/perl -e 'alarm shift; exec @ARGV' 30 \
    "$active" evaluate "$@" >"$out" 2>"$err" || status=$?
  RUN_STATUS=$status
}
VERDICT_OUTPUT=''
expect_decision() {
  local name=$1 expected=$2 reason=$3
  shift 3
  local out="$tmp/$name.out" err="$tmp/$name.err"
  run_evaluator "$evaluator" "$out" "$err" "$@"
  if [ "$RUN_STATUS" -ne 0 ] || [ -s "$err" ] ||
     ! "$jq_bin" -e --arg decision "$expected" '.body.decision==$decision' "$out" \
       >/dev/null ||
     ! /usr/bin/cmp -s "$out" <("$jq_bin" -S -c . "$out"); then
    fail "$name"
  fi
  if [ -n "$reason" ]; then
    local expected_reasons=() expected_json
    read -r -a expected_reasons <<<"$reason"
    expected_json=$("$jq_bin" -c -n '$ARGS.positional|sort' --args "${expected_reasons[@]}")
    "$jq_bin" -e --argjson expected "$expected_json" '.body.reason_ids==$expected' "$out" \
      >/dev/null || fail "$name reason"
  fi
  VERDICT_OUTPUT=$out
  pass "$name"
}
expect_error() {
  local name=$1 expected=$2 active=$3
  shift 3
  local out="$tmp/$name.out" err="$tmp/$name.err"
  run_evaluator "$active" "$out" "$err" "$@"
  if [ "$RUN_STATUS" -eq 0 ] || [ -s "$out" ] ||
     [ "$(/bin/cat "$err")" != "$expected" ] || /usr/bin/grep -Fq "$tmp" "$err"; then
    fail "$name"
  fi
  pass "$name"
}
base_run() { /usr/bin/printf '%s\n' "$request" "$release" "$authorization" \
  "$rehearsal" "$risk" "$kill_switch"; }

expect_decision production-deploy-admissible admissible deploy.admissible \
  "$request" "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"
expected="$tmp/expected.json"
"$jq_bin" -S -c -n --arg tiers_sha "$(sha256_path "$tiers")" \
  --arg decision_sha "$(sha256_path "$decision")" \
  --arg request_sha "$(sha256_path "$request")" --arg release_sha "$release_sha" \
  --arg authorization_sha "$authorization_sha" --arg rehearsal_sha "$rehearsal_sha" \
  --arg risk_sha "$(sha256_path "$risk")" --arg kill_sha "$(sha256_path "$kill_switch")" '
  def ref($version;$kind;$id;$sha):
    {schema_version:$version,kind:$kind,id:$id,sha256:$sha};
  {schema_version:1,kind:"deploy_gate_evaluation",id:"deploy-request.production.0001",
   body:{activation_state:"inactive",authority:"none",
     authorization_ref:ref(1;"deploy_authorization";"deploy-authorization.production.0001";
       $authorization_sha),
     decision:"admissible",
     decision_ref:{content_id:"deploy-decision.deploy-gates",
       media_type:"application/vnd.ystack.control-decision+json",sha256:$decision_sha},
     evaluation_mode:"observation-only",
     kill_switch_evaluation_ref:ref(1;"kill_switch_evaluation";"kill-attempt.deploy-test";
       $kill_sha),
     qualification:{reason:"no-deployment-adapter-exists",state:"unavailable"},
     reason_ids:["deploy.admissible"],reference_semantics:"identity-only",
     rehearsal_ref:ref(1;"rollback_rehearsal_record";"rollback-rehearsal.production.0001";
       $rehearsal_sha),
     release_ref:ref(1;"release_record";"release.moon-garden.0001";$release_sha),
     request_ref:ref(1;"deploy_request";"deploy-request.production.0001";$request_sha),
     requested_capability:"deploy",
     risk_evaluation_ref:ref(1;"risk_gate_evaluation";"result.deploy-test";$risk_sha),
     tier:"production",
     tiers_ref:{content_id:"deploy-policy.environment-tiers",
       media_type:"application/vnd.ystack.deploy-policy+json",sha256:$tiers_sha}}}
' >"$expected"
/usr/bin/cmp -s "$VERDICT_OUTPUT" "$expected" || fail 'byte-identical admissible document'
pass 'admissible document matches the expected bytes'
first="$tmp/first-run.json"
/bin/cp "$VERDICT_OUTPUT" "$first"
expect_decision production-deploy-repeat admissible deploy.admissible \
  "$request" "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"
/usr/bin/cmp -s "$first" "$VERDICT_OUTPUT" || fail 'repeat run drifted'
pass 'repeat run is byte identical'
"$jq_bin" -e '
  .body.authority=="none" and .body.activation_state=="inactive" and
  .body.evaluation_mode=="observation-only" and
  .body.qualification=={reason:"no-deployment-adapter-exists",state:"unavailable"} and
  ((has("grant") or has("activation") or (.body|has("qualification_ref")))|not)
' "$VERDICT_OUTPUT" >/dev/null || fail 'admissible output claimed authority'
pass 'admissible grants no authority and activates nothing'

routine_authorization=$(mutate "$authorization" staging-authorization '
  .id="deploy-authorization.staging.0001"|.body.authorization_kind="routine-gate"|
  .body.environment.tier="staging"|.body.operator.role="publisher"|
  .body.operator.principal_id="principal.publisher"')
routine_authorization_sha=$(sha256_path "$routine_authorization")
staging_request="$tmp/staging-request.json"
"$jq_bin" -S -c --arg sha "$routine_authorization_sha" '
  .id="deploy-request.staging.0001"|.body.environment.tier="staging"|
  .body.authorization_ref.id="deploy-authorization.staging.0001"|
  .body.authorization_ref.sha256=$sha' "$request" >"$staging_request"
expect_decision staging-deploy-admissible admissible deploy.admissible \
  "$staging_request" "$release" "$routine_authorization" "$rehearsal" "$risk" "$kill_switch"

dev_authorization=$(mutate "$routine_authorization" dev-authorization '
  .id="deploy-authorization.dev.0001"|.body.environment.tier="dev"')
dev_authorization_sha=$(sha256_path "$dev_authorization")
dev_status="$tmp/dev-status-request.json"
"$jq_bin" -S -c --arg sha "$dev_authorization_sha" '
  .kind="status_request"|.id="status-request.dev.0001"|
  .body.requested_capability="status"|.body.environment.tier="dev"|
  .body.actor_ref.role="observer"|
  .body.authorization_ref.id="deploy-authorization.dev.0001"|
  .body.authorization_ref.sha256=$sha' "$request" >"$dev_status"
expect_decision dev-status-admissible admissible deploy.admissible \
  "$dev_status" "$release" "$dev_authorization" "$rehearsal" "$risk" "$kill_switch"

rollback="$tmp/rollback-request.json"
"$jq_bin" -S -c --arg rehearsal_sha "$rehearsal_sha" --arg previous_sha "$previous_sha" '
  .kind="rollback_request"|.id="rollback-request.production.0001"|
  .body.requested_capability="rollback"|
  .body.rehearsal_ref={schema_version:1,kind:"rollback_rehearsal_record",
    id:"rollback-rehearsal.production.0001",sha256:$rehearsal_sha}|
  .body.rollback_to_release_ref={schema_version:1,kind:"release_record",
    id:"release.moon-garden.0000",sha256:$previous_sha}' "$request" >"$rollback"
expect_decision rollback-rehearsed-admissible admissible deploy.admissible \
  "$rollback" "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"

failed_rehearsal=$(mutate "$rehearsal" failed-rehearsal '.body.outcome="failed"')
failed_rehearsal_sha=$(sha256_path "$failed_rehearsal")
rollback_failed=$(mutate "$rollback" rollback-failed-rehearsal \
  ".body.rehearsal_ref.sha256=\"$failed_rehearsal_sha\"")
expect_decision rollback-unrehearsed-outcome refused deploy.rollback-unrehearsed \
  "$rollback_failed" "$release" "$authorization" "$failed_rehearsal" "$risk" "$kill_switch"
operator_rollback=$(mutate "$rollback_failed" operator-rollback \
  '.body.actor_ref.role="operator"|.body.actor_ref.principal_id="principal.operator"')
expect_decision rollback-operator-exempt admissible deploy.admissible \
  "$operator_rollback" "$release" "$authorization" "$failed_rehearsal" "$risk" "$kill_switch"
staging_rehearsal=$(mutate "$rehearsal" staging-rehearsal '.body.environment.tier="staging"')
staging_rehearsal_sha=$(sha256_path "$staging_rehearsal")
rollback_wrong_environment=$(mutate "$rollback" rollback-wrong-environment \
  ".body.rehearsal_ref.sha256=\"$staging_rehearsal_sha\"")
expect_decision rollback-unrehearsed-environment refused deploy.rollback-unrehearsed \
  "$rollback_wrong_environment" "$release" "$authorization" "$staging_rehearsal" "$risk" \
  "$kill_switch"
rollback_wrong_pair=$(mutate "$rollback" rollback-wrong-pair \
  '.body.rollback_to_release_ref.sha256=("0"*64)')
expect_decision rollback-unrehearsed-pair refused deploy.rollback-unrehearsed \
  "$rollback_wrong_pair" "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"
rollback_unbound=$(mutate "$rollback" rollback-unbound-rehearsal \
  '.body.rehearsal_ref.sha256=("0"*64)')
expect_decision rollback-unrehearsed-reference refused deploy.rollback-unrehearsed \
  "$rollback_unbound" "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"

expect_decision tier-unknown refused deploy.tier-unknown \
  "$(mutate "$request" canary-request '.body.environment.tier="canary"')" \
  "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"
expect_decision authorization-missing-reference refused deploy.authorization-missing \
  "$(mutate "$request" unbound-authorization '.body.authorization_ref.sha256=("0"*64)')" \
  "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"
withheld=$(mutate "$authorization" withheld-authorization '.body.decision="withheld"')
withheld_sha=$(sha256_path "$withheld")
withheld_request=$(mutate "$request" withheld-request \
  ".body.authorization_ref.sha256=\"$withheld_sha\"")
expect_decision authorization-missing-withheld refused \
  "deploy.authorization-missing deploy.authorization-wrong-tier" \
  "$withheld_request" "$release" "$withheld" "$rehearsal" "$risk" "$kill_switch"
expect_decision authorization-stale-expired refused deploy.authorization-stale \
  "$(mutate "$request" late-request '.body.requested_at="2026-09-07T00:00:00Z"')" \
  "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"
other_release=$(mutate "$authorization" authorization-other-release \
  '.body.release_ref.sha256=("0"*64)')
other_release_sha=$(sha256_path "$other_release")
other_release_request=$(mutate "$request" other-release-request \
  ".body.authorization_ref.sha256=\"$other_release_sha\"")
expect_decision authorization-stale-release refused deploy.authorization-stale \
  "$other_release_request" "$release" "$other_release" "$rehearsal" "$risk" "$kill_switch"
production_routine=$(mutate "$authorization" production-routine-authorization \
  '.body.authorization_kind="routine-gate"|.body.operator.role="publisher"')
production_routine_sha=$(sha256_path "$production_routine")
production_routine_request=$(mutate "$request" production-routine-request \
  ".body.authorization_ref.sha256=\"$production_routine_sha\"")
expect_decision production-requires-named-operator refused deploy.authorization-wrong-tier \
  "$production_routine_request" "$release" "$production_routine" "$rehearsal" "$risk" \
  "$kill_switch"
unnamed_operator=$(mutate "$authorization" unnamed-operator-authorization \
  '.body.operator.role="publisher"')
unnamed_operator_sha=$(sha256_path "$unnamed_operator")
unnamed_operator_request=$(mutate "$request" unnamed-operator-request \
  ".body.authorization_ref.sha256=\"$unnamed_operator_sha\"")
expect_decision production-named-operator-role refused deploy.authorization-wrong-tier \
  "$unnamed_operator_request" "$release" "$unnamed_operator" "$rehearsal" "$risk" \
  "$kill_switch"
wrong_tier=$(mutate "$authorization" wrong-tier-authorization \
  '.body.environment.tier="staging"')
wrong_tier_sha=$(sha256_path "$wrong_tier")
wrong_tier_request=$(mutate "$request" wrong-tier-request \
  ".body.authorization_ref.sha256=\"$wrong_tier_sha\"")
expect_decision authorization-wrong-tier refused deploy.authorization-wrong-tier \
  "$wrong_tier_request" "$release" "$wrong_tier" "$rehearsal" "$risk" "$kill_switch"

rebind_release() {
  local name=$1 filter=$2 moved moved_sha moved_authorization moved_authorization_sha
  local moved_request
  moved=$(mutate "$release" "$name-release" "$filter")
  moved_sha=$(sha256_path "$moved")
  moved_authorization=$(mutate "$authorization" "$name-authorization" \
    ".body.release_ref.sha256=\"$moved_sha\"")
  moved_authorization_sha=$(sha256_path "$moved_authorization")
  moved_request=$(mutate "$request" "$name-request" \
    ".body.release_ref.sha256=\"$moved_sha\"|.body.authorization_ref.sha256=\"$moved_authorization_sha\"")
  expect_decision "$name" refused deploy.release-unverified \
    "$moved_request" "$moved" "$moved_authorization" "$rehearsal" "$risk" "$kill_switch"
}
rebind_release release-unverified-status '.body.verification.status="unverified"'
rebind_release release-unverified-tree '.body.verification.verified_tree_id=("e"*40)'
rebind_release release-unverified-commit '.body.verification.verified_commit_id=("e"*40)'
rebind_release release-unverified-evidence \
  '.body.evidence.verifier.stage_result_ref.sha256=("7"*64)'
expect_decision release-unverified-reference refused \
  "deploy.authorization-stale deploy.release-unverified" \
  "$(mutate "$request" unbound-release '.body.release_ref.sha256=("0"*64)')" \
  "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"

expect_decision kill-switch-violated refused deploy.kill-switch \
  "$request" "$release" "$authorization" "$rehearsal" "$risk" \
  "$(mutate "$kill_switch" kill-violated \
    '.body.verdict="violated"|.body.reason_ids=["kill.stop-active"]')"
expect_decision kill-switch-inconclusive refused deploy.kill-switch \
  "$request" "$release" "$authorization" "$rehearsal" "$risk" \
  "$(mutate "$kill_switch" kill-inconclusive \
    '.body.verdict="inconclusive"|.body.reason_ids=["kill.duty-inconclusive"]')"
expect_decision duty-violation-role refused deploy.duty-violation \
  "$(mutate "$request" producer-request '.body.actor_ref.role="producer"')" \
  "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"
expect_decision duty-violation-risk refused deploy.duty-violation \
  "$request" "$release" "$authorization" "$rehearsal" \
  "$(mutate "$risk" risk-duty \
    '.body.verdict="violated"|.body.reason_ids=["duty.publisher-model-access"]')" \
  "$kill_switch"
expect_decision malformed-request-field refused deploy.malformed \
  "$(mutate "$request" extra-field-request '.body.untrusted="value"')" \
  "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"
expect_decision malformed-policy-set refused deploy.malformed \
  "$request" "$release" "$authorization" "$rehearsal" \
  "$(mutate "$risk" risk-other-policy-set '.body.policy_set.sha256=("0"*64)')" \
  "$kill_switch"
malformed_id=$(mutate "$release" malformed-release-id '.body.release_id="release.other"')
malformed_id_sha=$(sha256_path "$malformed_id")
malformed_id_authorization=$(mutate "$authorization" malformed-id-authorization \
  ".body.release_ref.sha256=\"$malformed_id_sha\"")
malformed_id_request=$(mutate "$request" malformed-id-request \
  ".body.release_ref.sha256=\"$malformed_id_sha\"|.body.authorization_ref.sha256=\"$(sha256_path "$malformed_id_authorization")\"")
expect_decision malformed-release-identity refused deploy.malformed \
  "$malformed_id_request" "$malformed_id" "$malformed_id_authorization" "$rehearsal" \
  "$risk" "$kill_switch"
expect_decision malformed-rehearsal refused deploy.malformed \
  "$request" "$release" "$authorization" \
  "$(mutate "$rehearsal" rehearsal-extra-field '.body.untrusted="value"')" \
  "$risk" "$kill_switch"

expect_error usage-verb E_USAGE "$evaluator" "$request"
expect_error envelope-kind E_RELATION "$evaluator" \
  "$(mutate "$request" wrong-envelope '.kind="release_record"')" \
  "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"
expect_error envelope-schema E_RELATION "$evaluator" \
  "$(mutate "$request" wrong-schema '.schema_version=2')" \
  "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"
/bin/cat "$request" "$request" >"$tmp/multi-root.json"
expect_error multi-root E_PARSE "$evaluator" "$tmp/multi-root.json" \
  "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"
"$jq_bin" -c . "$request" | "$jq_bin" -c '{kind,id,schema_version,body}' \
  >"$tmp/uncanonical.json"
expect_error uncanonical E_CANONICAL "$evaluator" "$tmp/uncanonical.json" \
  "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"
"$jq_bin" -S -c -n 'reduce range(0;33) as $index (0;{value:.})' >"$tmp/deep.json"
expect_error depth-limit E_LIMIT "$evaluator" "$tmp/deep.json" \
  "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"
"$jq_bin" -S -c -n '{schema_version:1,kind:"deploy_request",id:"deploy-request.large",
  body:{padding:("x"*1100000)}}' >"$tmp/oversized.json"
expect_error oversize-limit E_LIMIT "$evaluator" "$tmp/oversized.json" \
  "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"
/bin/ln -s "$request" "$tmp/symlinked-request.json"
expect_error symlink-input E_RUNTIME "$evaluator" "$tmp/symlinked-request.json" \
  "$release" "$authorization" "$rehearsal" "$risk" "$kill_switch"

copy_root="$tmp/copied"
/bin/mkdir -p "$copy_root/deploy/v1"
for path in evaluate-deploy.sh validate-deploy-document.sh deploy-gates.jq \
  deploy_contracts.jq environment-tiers.json deploy-decision.json; do
  /bin/cp "$root/deploy/v1/$path" "$copy_root/deploy/v1/$path"
done
/bin/chmod 0755 "$copy_root/deploy/v1/evaluate-deploy.sh" \
  "$copy_root/deploy/v1/validate-deploy-document.sh"
stale_program="$tmp/stale-program"
/bin/cp -R "$copy_root" "$stale_program"
/usr/bin/printf '\n' >>"$stale_program/deploy/v1/deploy-gates.jq"
expect_error stale-evaluator-program E_RELATION \
  "$stale_program/deploy/v1/evaluate-deploy.sh" "$request" "$release" "$authorization" \
  "$rehearsal" "$risk" "$kill_switch"
stale_tiers="$tmp/stale-tiers"
/bin/cp -R "$copy_root" "$stale_tiers"
"$jq_bin" -S -c '.body.tiers[2].authorization_kind="routine-gate"|
  .body.tiers[2].operator_named=false' "$tiers" >"$stale_tiers/deploy/v1/environment-tiers.json"
expect_error stale-tiers-binding E_RELATION \
  "$stale_tiers/deploy/v1/evaluate-deploy.sh" "$request" "$release" "$authorization" \
  "$rehearsal" "$risk" "$kill_switch"
broken_tiers="$tmp/broken-tiers"
/bin/cp -R "$copy_root" "$broken_tiers"
"$jq_bin" -S -c '.body.policy_version="v2"' "$tiers" \
  >"$broken_tiers/deploy/v1/environment-tiers.json"
expect_error rejected-tiers-policy E_TIERS \
  "$broken_tiers/deploy/v1/evaluate-deploy.sh" "$request" "$release" "$authorization" \
  "$rehearsal" "$risk" "$kill_switch"

race_root="$tmp/race"
/bin/cp -R "$copy_root" "$race_root"
marker="$tmp/validator.marker"
release_gate="$tmp/validator.release"
/usr/bin/printf '%s\n' '#!/bin/bash' 'set -uo pipefail' \
  "/usr/bin/printf '%s\\n' ready >'$marker'" \
  "count=0; while [ ! -e '$release_gate' ] && [ \"\$count\" -lt 500 ]; do count=\$((count+1)); /bin/sleep 0.01; done" \
  "[ -e '$release_gate' ] || exit 1" 'exit 0' \
  >"$race_root/deploy/v1/validate-deploy-document.sh"
/bin/chmod 0755 "$race_root/deploy/v1/validate-deploy-document.sh"
"$jq_bin" -S -c --arg sha "$(sha256_path "$race_root/deploy/v1/validate-deploy-document.sh")" \
  '.body.evaluator.validator_ref.sha256=$sha' "$decision" >"$tmp/race-decision.json"
/bin/mv "$tmp/race-decision.json" "$race_root/deploy/v1/deploy-decision.json"
race_request="$tmp/race-request.json"
/bin/cp "$request" "$race_request"
race_out="$tmp/race.out"
race_err="$tmp/race.err"
PATH="$bin:/usr/bin:/bin" /usr/bin/perl -e 'alarm shift; exec @ARGV' 30 \
  "$race_root/deploy/v1/evaluate-deploy.sh" evaluate "$race_request" "$release" \
  "$authorization" "$rehearsal" "$risk" "$kill_switch" >"$race_out" 2>"$race_err" &
race_pid=$!
attempt=0
while [ ! -e "$marker" ] && kill -0 "$race_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
  attempt=$((attempt + 1))
  /bin/sleep 0.01
done
if [ ! -e "$marker" ]; then
  : >"$release_gate"
  kill "$race_pid" 2>/dev/null || :
  wait "$race_pid" 2>/dev/null || :
  fail 'moved-input marker timeout'
fi
"$jq_bin" -S -c '.body.requested_at="2026-09-05T13:00:00Z"' "$race_request" \
  >"$tmp/race-request-moved"
/bin/mv "$tmp/race-request-moved" "$race_request"
: >"$release_gate"
race_status=0
wait "$race_pid" || race_status=$?
[ "$race_status" -ne 0 ] && [ ! -s "$race_out" ] &&
  [ "$(/bin/cat "$race_err")" = E_RELATION ] || fail 'moved input accepted'
pass 'an input moved after the snapshot is refused'

validator_status=0
run_validator() {
  local kind=$1 document=$2 out=$3 err=$4 status=0
  PATH="$bin:/usr/bin:/bin" /usr/bin/perl -e 'alarm shift; exec @ARGV' 20 \
    "$validator" validate "$kind" "$document" >"$out" 2>"$err" || status=$?
  validator_status=$status
}
expect_valid() {
  local name=$1 kind=$2 document=$3
  run_validator "$kind" "$document" "$tmp/$name.out" "$tmp/$name.err"
  [ "$validator_status" -eq 0 ] && [ ! -s "$tmp/$name.out" ] &&
    [ ! -s "$tmp/$name.err" ] || fail "$name"
  pass "$name"
}
expect_invalid() {
  local name=$1 expected=$2 kind=$3 document=$4
  run_validator "$kind" "$document" "$tmp/$name.out" "$tmp/$name.err"
  [ "$validator_status" -ne 0 ] && [ ! -s "$tmp/$name.out" ] &&
    [ "$(/bin/cat "$tmp/$name.err")" = "$expected" ] || fail "$name"
  pass "$name"
}
expect_valid validate-tiers deploy_environment_tiers "$tiers"
expect_valid validate-release release_record "$release"
expect_valid validate-authorization deploy_authorization "$authorization"
expect_valid validate-rehearsal rollback_rehearsal_record "$rehearsal"
expect_valid validate-deploy-request deploy_request "$request"
expect_valid validate-rollback-request rollback_request "$rollback"
expect_valid validate-status-request status_request "$dev_status"
expect_valid validate-risk risk_gate_evaluation "$risk"
expect_valid validate-kill kill_switch_evaluation "$kill_switch"
expect_invalid validate-kind-mismatch E_SHAPE status_request "$request"
expect_invalid validate-unknown-kind E_USAGE deploy_receipt "$request"
expect_invalid validate-extra-field E_SHAPE deploy_request \
  "$(mutate "$request" validator-extra-field '.body.untrusted="value"')"
expect_invalid validate-bad-timestamp E_SHAPE deploy_request \
  "$(mutate "$request" validator-bad-timestamp '.body.requested_at="2026-09-05 12:00:00"')"
expect_invalid validate-expiry-order E_SHAPE deploy_authorization \
  "$(mutate "$authorization" validator-expiry-order \
    '.body.expires_at=.body.issued_at')"
expect_invalid validate-same-release-pair E_SHAPE rollback_rehearsal_record \
  "$(mutate "$rehearsal" validator-same-pair '.body.to_release_ref=.body.from_release_ref')"
expect_invalid validate-short-oid E_SHAPE release_record \
  "$(mutate "$release" validator-short-oid '.body.source.hash_algorithm="sha256"')"
expect_invalid validate-multi-root E_PARSE deploy_request "$tmp/multi-root.json"
expect_invalid validate-uncanonical E_CANONICAL deploy_request "$tmp/uncanonical.json"
expect_invalid validate-oversized E_LIMIT deploy_request "$tmp/oversized.json"
expect_invalid validate-symlink E_RUNTIME deploy_request "$tmp/symlinked-request.json"
"$jq_bin" -S -c 'del(.body.evidence.packaging_release_manifest.content_id)' "$release" \
  >"$tmp/release-no-manifest-id.json"
expect_invalid validate-broken-manifest-ref E_SHAPE release_record \
  "$tmp/release-no-manifest-id.json"
expect_valid validate-absent-manifest release_record \
  "$(mutate "$release" release-absent-manifest \
    '.body.evidence.packaging_release_manifest=null')"

receipt="$tmp/receipt.json"
dormant_status=0
/usr/bin/env -i LC_ALL=C PATH="$bin:/usr/bin:/bin" HOME="$tmp" \
  /usr/bin/perl -e 'alarm shift; exec @ARGV' 20 /bin/bash "$dormant" "$first" "$jq_bin" \
  >"$receipt" 2>"$tmp/receipt.err" || dormant_status=$?
[ "$dormant_status" -eq 0 ] && [ ! -s "$tmp/receipt.err" ] || fail 'dormant adapter run'
"$jq_bin" -e --arg sha "$(sha256_path "$first")" '
  .kind=="adapter_receipt" and .outcome=="refused" and .reason_id=="deploy.dormant" and
  .message=="dormant: deployment disabled in construction mode" and
  .adapter=={id:"fake.deploy-dormant.v1",status:"inactive",version:"v1"} and
  .authority=="none" and .qualification.state=="unavailable" and
  .capability=={reason_id:"deploy.dormant",state:"unavailable"} and
  .capabilities==[] and .permissions==[] and .tools==[] and .effects==[] and
  .evaluation_ref.sha256==$sha and .requested_capability=="deploy" and .tier=="production"
' "$receipt" >/dev/null || fail 'dormant adapter receipt'
/usr/bin/cmp -s "$receipt" <("$jq_bin" -S -c . "$receipt") || fail 'dormant receipt canonical'
pass 'the dormant deployment adapter refuses an admissible request'
refused_evaluation="$tmp/refused-evaluation.json"
/bin/cp "$tmp/kill-switch-violated.out" "$refused_evaluation"
dormant_status=0
/usr/bin/env -i LC_ALL=C PATH="$bin:/usr/bin:/bin" HOME="$tmp" \
  /usr/bin/perl -e 'alarm shift; exec @ARGV' 20 /bin/bash "$dormant" \
  "$refused_evaluation" "$jq_bin" >"$tmp/refused-receipt.json" \
  2>"$tmp/refused-receipt.err" || dormant_status=$?
[ "$dormant_status" -eq 65 ] && [ ! -s "$tmp/refused-receipt.json" ] ||
  fail 'dormant adapter accepted a refused evaluation'
pass 'the dormant deployment adapter refuses a non-admissible evaluation'

for path in deploy/v1/environment-tiers.json deploy/v1/deploy-decision.json \
  deploy/v1/deploy-gates.jq deploy/v1/deploy_contracts.jq \
  deploy/v1/evaluate-deploy.sh deploy/v1/validate-deploy-document.sh \
  adapter-tests/v1/fakes/deploy-dormant.sh \
  scripts/test/deploy-rollback-gates.test.sh; do
  [ -e "$root/$path" ] || fail "owned path $path"
done
pass 'owned product and test paths are complete'
/usr/bin/printf 'deploy and rollback gates: %s focused checks passed\n' "$passes"
