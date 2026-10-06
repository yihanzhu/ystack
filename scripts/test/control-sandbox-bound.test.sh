#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-sandbox-bound-test.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() { /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
syn() { /usr/bin/printf '%s' "$1" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'; }

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) jq_asset=jq-osx-amd64; jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_asset=jq-linux64; jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) fail "unsupported host $platform" ;;
esac
jq_cache="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset"
[ -f "$jq_cache" ] && [ "$(sha256_path "$jq_cache")" = "$jq_sha" ] || fail 'jq cache'
bin="$tmp/bin"
/bin/mkdir -m 700 "$bin"
/bin/cp "$jq_cache" "$bin/jq"
/bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"

fixture="$tmp/package"
/bin/mkdir -p "$fixture/control/v1" "$fixture/enforcement/v1" "$fixture/shadow/v1"
for name in evaluate-bound-sandbox.sh sandbox-bound.jq sandbox-bound-policy.json \
  sandbox-bound-decision.json control-policy-set-sandbox-bound.json validate.sh policy-set.jq; do
  /bin/cp "$root/control/v1/$name" "$fixture/control/v1/$name"
done
/bin/chmod 0755 "$fixture/control/v1/evaluate-bound-sandbox.sh" "$fixture/control/v1/validate.sh"
/bin/cp "$root/shadow/v1/shadow-environments.json" "$fixture/shadow/v1/shadow-environments.json"
evaluator="$fixture/control/v1/evaluate-bound-sandbox.sh"
policy="$fixture/control/v1/sandbox-bound-policy.json"
set="$fixture/control/v1/control-policy-set-sandbox-bound.json"
env_id=env.local-macos-fixture
verifier_sha=$(syn verifier.fixture)

accepted="$fixture/enforcement/v1/accepted-identities.json"
"$jq_bin" -nSc --arg env "$env_id" --arg d "$verifier_sha" '
  def ids: {guest_init:[$d],guest_kernel:[$d],guest_kernel_config:[$d],guest_supervisor:[$d],
    host_runtime:[$d],host_supervisor:[$d],image:[$d],toolchain:[$d],
    verification_instructions:[$d],verifier:[$d]};
  def mechanisms: {cpu_time_ms:["mechanism.cpu"],memory_bytes:["mechanism.memory"],
    output_bytes:["mechanism.output"],process_count:["mechanism.process"],
    scratch_bytes:["mechanism.scratch"],wall_time_ms:["mechanism.wall"]};
  {schema_version:1,kind:"sandbox_accepted_identity_set",id:"sandbox.accepted-identities.v1",
   body:{activation_state:"inactive",environments:[{environment_id:$env,identities:ids,
     mechanisms:mechanisms,scratch_bytes:1048576}],set_version:"v1"}}
' >"$accepted"
/bin/cp "$accepted" "$tmp/accepted-original.json"
set_sha=$(sha256_path "$set")
accepted_sha=$(sha256_path "$accepted")
registry="$fixture/shadow/v1/shadow-environments.json"
entry="$tmp/entry.json"
"$jq_bin" -Sc --arg env "$env_id" '.body.environments[]|select(.environment_id==$env)' \
  "$registry" >"$entry"
entry_sha=$(sha256_path "$entry")
target=$("$jq_bin" -r '.target_repository_id' "$entry")

duty="$tmp/duty.json"
"$jq_bin" -nSc --arg set_sha "$set_sha" --slurpfile set "$set" '
  def doc($v;$kind;$id;$sha): {schema_version:$v,kind:$kind,id:$id,sha256:$sha};
  ($set[0].body.sections[]|select(.section_id=="duty-separation")) as $section |
  {schema_version:1,kind:"duty_separation_evaluation",id:"result.bound",
   body:{activation_state:"inactive",core_contract:$set[0].body.core_contract,
     decision_ref:$section.decision_ref,evaluation_mode:"observation-only",
     policy_ref:$section.policy_ref,policy_set:{id:$set[0].id,sha256:$set_sha},
     reason_ids:["duty.satisfied"],reference_semantics:"identity-only",
     stage:{request_ref:doc(2;"stage_request";"request.bound";("2"*64)),
       resolved_profile_ref:doc(2;"resolved_profile";"profile.bound";("3"*64)),
       result_ref:doc(2;"stage_result";"result.bound";("4"*64))},verdict:"satisfied"}}
' >"$duty"

build_claim() {
  local duty_in=$1 digest=$2 out=$3 duty_sha
  duty_sha=$(sha256_path "$duty_in")
  "$jq_bin" -nSc --arg env "$env_id" --arg d "$digest" --arg duty_sha "$duty_sha" \
    --arg set_sha "$set_sha" --slurpfile p "$policy" '
    def doc($v;$kind;$id;$sha): {schema_version:$v,kind:$kind,id:$id,sha256:$sha};
    {schema_version:1,kind:"execution_environment_claim",id:$env,
     body:{declaration_status:"complete",
       duty_evaluation_ref:doc(1;"duty_separation_evaluation";"result.bound";$duty_sha),
       effects:{external_writes:false,target_writes:false},environment:$p[0].body.environment,
       execution_identity:{adapter_instance_id:"instance.verifier",
         execution_boundary_id:"boundary.verifier",principal_id:"principal.verifier",role:"verifier"},
       filesystem:$p[0].body.filesystem,isolation:$p[0].body.isolation,limits:$p[0].body.limits,
       network:$p[0].body.network,policy_set_ref:doc(1;"control_policy_set";
         "control-policy-set.sandbox-bound.v1";$set_sha),resources:$p[0].body.resources,
       sensitive_material:$p[0].body.sensitive_material,
       stage_result_ref:doc(2;"stage_result";"result.bound";("4"*64)),
       tools:[($p[0].body.tools[0]|del(.identity_binding)+{sha256:$d})]}}
  ' >"$out"
}
claim="$tmp/claim.json"
build_claim "$duty" "$verifier_sha" "$claim"
build_observation() {
  local digest=$1 accepted_digest=$2 target_id=$3 out=$4
  "$jq_bin" -nSc --arg env "$env_id" --arg entry "$entry_sha" --arg target "$target_id" \
    --arg accepted "$accepted_digest" --arg d "$digest" '
    {schema_version:1,kind:"sandbox_verifier_observation",id:"sandbox.observation.verifier",
     body:{environment_id:$env,environment_entry_sha256:$entry,target_repository_id:$target,
       accepted_set_sha256:$accepted,verifier_sha256:$d}}
  ' >"$out"
}
observation="$tmp/observation.json"
build_observation "$verifier_sha" "$accepted_sha" "$target" "$observation"

run_eval() {
  local active=$1 duty_in=$2 claim_in=$3 observation_in=$4 name=$5 status=0
  RUN_OUT="$tmp/$name.out"; RUN_ERR="$tmp/$name.err"
  PATH="$bin:/usr/bin:/bin" /usr/bin/perl -e 'alarm shift; exec @ARGV' 10 \
    "$active" evaluate "$duty_in" "$claim_in" "$observation_in" \
    >"$RUN_OUT" 2>"$RUN_ERR" || status=$?
  RUN_STATUS=$status
}
expect_verdict() {
  local name=$1 expected=$2 duty_in=$3 claim_in=$4 observation_in=$5
  run_eval "$evaluator" "$duty_in" "$claim_in" "$observation_in" "$name"
  if [ "$RUN_STATUS" -ne 0 ] || [ -s "$RUN_ERR" ] ||
     ! "$jq_bin" -e --arg v "$expected" '.body.verdict==$v and
       .body.authority_effect=="none" and .body.qualification_effect=="none"' \
       "$RUN_OUT" >/dev/null; then
    /bin/cat "$RUN_ERR" >&2
    fail "$name"
  fi
  pass "$name"
}
mutate() {
  local source=$1 name=$2 filter=$3 target_path
  target_path="$tmp/$name.json"
  "$jq_bin" -Sc "$filter" "$source" >"$target_path"
  /usr/bin/printf '%s\n' "$target_path"
}

expect_verdict same-set-satisfied satisfied "$duty" "$claim" "$observation"
"$jq_bin" -e --arg d "$verifier_sha" --arg o "$(sha256_path "$observation")" '
  .body.reason_ids==["sandbox.verifier-binding-satisfied"] and
  .body.verifier_binding.verifier_sha256==$d and .body.verifier_binding.observation_sha256==$o
' "$RUN_OUT" >/dev/null || fail 'complete verifier binding output'
pass 'complete verifier binding output'

for item in \
  'role|.body.execution_identity.role="producer"' \
  'argv|.body.tools[0].argv += ["extra"]' \
  'root|.body.filesystem.write_roots[0].path="/sandbox/other"' \
  'limit|.body.limits.wall_time_ms=60001' \
  'incomplete|.body.declaration_status="incomplete"'; do
  name=${item%%|*}
  expect_verdict "$name-refused" inconclusive "$duty" \
    "$(mutate "$claim" "$name-claim" "${item#*|}")" "$observation"
done

wrong_target=$(mutate "$observation" wrong-target '.body.target_repository_id="fixture.other"')
expect_verdict wrong-target-refused inconclusive "$duty" "$claim" "$wrong_target"
unlisted=$(syn verifier.unlisted)
unlisted_claim="$tmp/unlisted-claim.json"; build_claim "$duty" "$unlisted" "$unlisted_claim"
unlisted_observation="$tmp/unlisted-observation.json"
build_observation "$unlisted" "$accepted_sha" "$target" "$unlisted_observation"
expect_verdict unlisted-refused inconclusive "$duty" "$unlisted_claim" "$unlisted_observation"
for digest in "$(/usr/bin/printf '0%.0s' {1..64})" "$(/usr/bin/printf '1%.0s' {1..64})"; do
  name=${digest:0:1}
  placeholder_claim="$tmp/$name-claim.json"; build_claim "$duty" "$digest" "$placeholder_claim"
  placeholder_observation="$tmp/$name-observation.json"
  build_observation "$digest" "$accepted_sha" "$target" "$placeholder_observation"
  expect_verdict "placeholder-$name-refused" inconclusive "$duty" "$placeholder_claim" \
    "$placeholder_observation"
done

other=$(syn verifier.other)
accepted_two="$tmp/accepted-two.json"
"$jq_bin" -Sc --arg other "$other" '.body.environments[0].identities.verifier += [$other] |
  .body.environments[0].identities.verifier |= sort' "$accepted" >"$accepted_two"
/bin/cp "$accepted_two" "$accepted"
accepted_two_sha=$(sha256_path "$accepted")
unequal_observation="$tmp/unequal-observation.json"
build_observation "$other" "$accepted_two_sha" "$target" "$unequal_observation"
expect_verdict two-accepted-unequal-refused inconclusive "$duty" "$claim" "$unequal_observation"
/bin/cp "$tmp/accepted-original.json" "$accepted"

false_duty=$(mutate "$duty" false-duty \
  '.body.verdict="violated"|.body.reason_ids=["duty.same-principal"]')
false_claim="$tmp/false-claim.json"; build_claim "$false_duty" "$verifier_sha" "$false_claim"
expect_verdict false-duty-refused inconclusive "$false_duty" "$false_claim" "$observation"

legacy_duty=$(mutate "$duty" legacy-duty '.body.policy_set.id="control-policy-set.v1"')
legacy_claim="$tmp/legacy-claim.json"; build_claim "$legacy_duty" "$verifier_sha" "$legacy_claim"
run_eval "$evaluator" "$legacy_duty" "$legacy_claim" "$observation" legacy-duty
[ "$RUN_STATUS" -ne 0 ] && [ ! -s "$RUN_OUT" ] &&
  [ "$(/bin/cat "$RUN_ERR")" = E_RELATION ] || fail 'legacy duty refused'
pass 'legacy duty refused'

shipped_observation="$tmp/shipped-observation.json"
shipped_sha=$(sha256_path "$root/enforcement/v1/accepted-identities.json")
build_observation "$verifier_sha" "$shipped_sha" "$target" "$shipped_observation"
run_eval "$root/control/v1/evaluate-bound-sandbox.sh" "$duty" "$claim" \
  "$shipped_observation" shipped-empty
[ "$RUN_STATUS" -eq 0 ] && [ ! -s "$RUN_ERR" ] &&
  "$jq_bin" -e '.body.verdict=="inconclusive" and
    .body.reason_ids==["sandbox.verifier-binding-refused"]' "$RUN_OUT" >/dev/null ||
  fail 'shipped empty set refusal'
pass 'shipped empty set refusal'

stale="$tmp/stale"
/bin/cp -R "$fixture" "$stale"
/usr/bin/printf '\n' >>"$stale/control/v1/sandbox-bound.jq"
run_eval "$stale/control/v1/evaluate-bound-sandbox.sh" "$duty" "$claim" "$observation" stale-program
[ "$RUN_STATUS" -ne 0 ] && [ ! -s "$RUN_OUT" ] &&
  [ "$(/bin/cat "$RUN_ERR")" = E_RELATION ] || fail 'fixed source drift'
pass 'fixed source drift'

for path in control/v1/sandbox-bound-policy.json control/v1/sandbox-bound-decision.json \
  control/v1/control-policy-set-sandbox-bound.json control/v1/evaluate-bound-sandbox.sh \
  control/v1/sandbox-bound.jq scripts/test/control-sandbox-bound.test.sh; do
  [ -e "$root/$path" ] || fail "owned path $path"
done
pass 'owned bound-control paths are complete'
/usr/bin/printf 'control sandbox bound: %s focused checks passed\n' "$passes"
