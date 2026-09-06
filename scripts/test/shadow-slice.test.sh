#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
validator="$root/shadow/v1/validate-incident.sh"
reproducer="$root/shadow/v1/reproduce.sh"
registry="$root/shadow/v1/shadow-environments.json"
core="$root/scripts/core-contract.sh"
trace_validator="$root/telemetry/v1/validate-trace-ledger.sh"
sandbox_policy="$root/control/v1/sandbox-policy.json"
sandbox_decision="$root/control/v1/sandbox-decision.json"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-shadow-slice-test.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() { /bin/chmod -R u+w "$tmp" 2>/dev/null || :; /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_asset=jq-linux64
    jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) fail "unsupported host $platform" ;;
esac
# This suite bootstraps the shared jq 1.6 cache itself so it never depends on an
# earlier suite having filled it.
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
bin="$tmp/bin"
/bin/mkdir -m 700 "$bin"
/bin/cp "$jq_cache" "$bin/jq"
/bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"
[ "$("$jq_bin" --version)" = jq-1.6 ] || fail 'jq identity'
/usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 \
  "$root/adapters/local-git-materializer/v1/object-closure.c" -o "$bin/object-closure"
/bin/chmod 0555 "$bin/object-closure"
closure_helper="$bin/object-closure"
export PATH="$bin:/usr/bin:/bin"

"$jq_bin" -S -c -n \
  --arg reproduce "$(sha_file "$root/shadow/v1/reproduce.sh")" \
  --arg validate "$(sha_file "$root/shadow/v1/validate-incident.sh")" \
  --arg program "$(sha_file "$root/shadow/v1/incident-record.jq")" \
  --arg registry "$(sha_file "$registry")" '{
    "reproduce.sh":$reproduce,"validate-incident.sh":$validate,
    "incident-record.jq":$program,"shadow-environments.json":$registry}' \
  > "$tmp/component-digests.json"

git_clean() {
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects "$@"
}

/bin/mkdir -m 700 "$tmp/home" "$tmp/source.git"
git_clean init -q --bare --object-format=sha1 "$tmp/source.git"
failing_blob=$(/usr/bin/printf 'alpha\nbeta\n' |
  git_clean --git-dir="$tmp/source.git" hash-object -w --stdin)
failing_tree=$(/usr/bin/printf '100644 blob %s\tsource.txt\n' "$failing_blob" |
  git_clean --git-dir="$tmp/source.git" mktree)
failing_commit=$(/usr/bin/printf '%s\n' 'incident revision' |
  git_clean --git-dir="$tmp/source.git" commit-tree "$failing_tree")
passing_blob=$(/usr/bin/printf 'alpha\nbeta\ngamma\n' |
  git_clean --git-dir="$tmp/source.git" hash-object -w --stdin)
passing_tree=$(/usr/bin/printf '100644 blob %s\tsource.txt\n' "$passing_blob" |
  git_clean --git-dir="$tmp/source.git" mktree)
passing_commit=$(/usr/bin/printf '%s\n' 'fixed revision' |
  git_clean --git-dir="$tmp/source.git" commit-tree "$passing_tree" -p "$failing_commit")
git_clean --git-dir="$tmp/source.git" update-ref refs/heads/main "$passing_commit"
expected_digest=$(/usr/bin/printf 'alpha\nbeta\ngamma\n' | /usr/bin/shasum -a 256 |
  /usr/bin/awk '{print $1}')
source_fingerprint=$(/usr/bin/find "$tmp/source.git" -type f -print0 | LC_ALL=C sort -z |
  /usr/bin/xargs -0 /usr/bin/shasum -a 256 | /usr/bin/shasum -a 256 |
  /usr/bin/awk '{print $1}')

empty_digest=$(/usr/bin/printf '' | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
read_only_input() {
  local out_root=$1 commit=$2 tree=$3 staged request_sha
  bash "$root/scripts/test/local-git-materializer-fixtures.sh" build "$out_root" \
    "$jq_bin" sha1 "$commit" "$tree"
  staged="$out_root/staged.json"
  "$jq_bin" -S -c --arg empty "$empty_digest" '
    .payloads |= map(if .input_id == "input.producer-patch" then .data = "" else . end) |
    .trust_context.verified_payloads |= map(
      if .input_id == "input.producer-patch"
      then .content.data = "" | .sha256 = $empty else . end) |
    .stage_request.content.body.inputs |= map(
      if .input_id == "input.producer-patch"
      then .value.value.value.sha256 = $empty else . end)
  ' "$out_root/input.json" > "$staged"
  "$jq_bin" -S -c '.stage_request.content' "$staged" > "$out_root/request.json"
  "$jq_bin" -S -c '.resolved_profile.content' "$staged" > "$out_root/resolved.json"
  request_sha=$(sha_file "$out_root/request.json")
  "$jq_bin" -S -c --arg sha "$request_sha" '.stage_request.sha256 = $sha' "$staged" \
    > "$out_root/read-only-input.json"
}
read_only_input "$tmp/fixture-failing" "$failing_commit" "$failing_tree"
read_only_input "$tmp/fixture-passing" "$passing_commit" "$passing_tree"

policy_set="$tmp/policy-set.json"
"$jq_bin" -S -c -n --arg sandbox_policy "$(sha_file "$sandbox_policy")" \
  --arg sandbox_decision "$(sha_file "$sandbox_decision")" '
  def ref($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
  def section($id;$policy;$decision):
    {section_id:$id,
     policy_ref:ref("control-policy." + $id;
       "application/vnd.ystack.control-policy+json";$policy),
     decision_ref:ref("control-decision." + $id;
       "application/vnd.ystack.control-decision+json";$decision)};
  {schema_version:1,kind:"control_policy_set",id:"control-policy-set.shadow-fixture",
   body:{activation_state:"inactive",
     core_contract:{generation_id:("g-" + ("7" * 64)),
       package_ref:ref("core-contract-package.v2";
         "application/vnd.ystack.core-contract+json";("9" * 64)),
       semantic_identity:"core.contracts.v2"},
     fail_mode:"closed",policy_version:"v1",
     sections:[section("credential-policy";("1" * 64);("a" * 64)),
       section("duty-separation";("2" * 64);("b" * 64)),
       section("evidence-integrity";("3" * 64);("c" * 64)),
       section("kill-switch";("4" * 64);("d" * 64)),
       section("risk-gates";("5" * 64);("e" * 64)),
       section("sandbox";$sandbox_policy;$sandbox_decision)]}}
' > "$policy_set"
policy_set_sha=$(sha_file "$policy_set")

duty="$tmp/duty.json"
"$jq_bin" -S -c -n --arg set_sha "$policy_set_sha" --slurpfile set "$policy_set" '
  def content($id;$sha):
    {content_id:$id,media_type:"application/vnd.ystack.control-decision+json",sha256:$sha};
  def document($kind;$id;$sha): {schema_version:2,kind:$kind,id:$id,sha256:$sha};
  {schema_version:1,kind:"duty_separation_evaluation",id:"result.shadow-fixture",
   body:{activation_state:"inactive",core_contract:$set[0].body.core_contract,
     decision_ref:content("control-decision.duty-separation";("b" * 64)),
     evaluation_mode:"observation-only",
     policy_ref:(content("control-policy.duty-separation";("2" * 64)) |
       .media_type = "application/vnd.ystack.control-policy+json"),
     policy_set:{id:"control-policy-set.shadow-fixture",sha256:$set_sha},
     reason_ids:["duty.satisfied"],reference_semantics:"identity-only",
     stage:{request_ref:document("stage_request";"request.shadow-fixture";("3" * 64)),
       resolved_profile_ref:document("resolved_profile";"profile.shadow-fixture";("4" * 64)),
       result_ref:document("stage_result";"result.shadow-fixture";("5" * 64))},
     verdict:"satisfied"}}
' > "$duty"

claim="$tmp/claim.json"
"$jq_bin" -S -c -n --arg set_sha "$policy_set_sha" --arg duty_sha "$(sha_file "$duty")" \
  --slurpfile policy "$sandbox_policy" '
  def document($version;$kind;$id;$sha):
    {schema_version:$version,kind:$kind,id:$id,sha256:$sha};
  {schema_version:1,kind:"execution_environment_claim",id:"env.local-macos-fixture",
   body:{declaration_status:"complete",
     duty_evaluation_ref:document(1;"duty_separation_evaluation";
       "result.shadow-fixture";$duty_sha),
     effects:{external_writes:false,target_writes:false},
     environment:$policy[0].body.environment,
     execution_identity:{adapter_instance_id:"instance.verifier",
       execution_boundary_id:"boundary.verifier",principal_id:"principal.verifier",
       role:"verifier"},
     filesystem:$policy[0].body.filesystem,isolation:$policy[0].body.isolation,
     limits:$policy[0].body.limits,network:$policy[0].body.network,
     policy_set_ref:document(1;"control_policy_set";
       "control-policy-set.shadow-fixture";$set_sha),
     resources:$policy[0].body.resources,
     sensitive_material:$policy[0].body.sensitive_material,
     stage_result_ref:document(2;"stage_result";"result.shadow-fixture";("5" * 64)),
     tools:$policy[0].body.tools}}
' > "$claim"

incident() {
  local target=$1 id=$2 commit=$3
  "$jq_bin" -S -c -n --arg id "$id" --arg commit "$commit" \
    --arg expected "$expected_digest" '
    {schema_version:1,kind:"shadow_incident_record",id:$id,
     body:{deploy_authority:"none",target_repository_id:"fixture.target",
       git_revision_ref:{repository_id:"fixture.target",hash_algorithm:"sha1",
         commit_id:$commit},
       failing_check:{kind:"file-digest",path:"source.txt",expected_sha256:$expected},
       observed_symptom:"source.txt no longer matches the recorded digest",
       reporter_actor_ref:"actor.fixture-reporter",
       observed_at:"2026-08-30T00:00:04Z"}}
  ' > "$target"
}
failing_incident="$tmp/incident-failing.json"
passing_incident="$tmp/incident-passing.json"
incident "$failing_incident" incident.fixture-failing "$failing_commit"
incident "$passing_incident" incident.fixture-passing "$passing_commit"

"$validator" validate "$failing_incident" > "$tmp/incident-receipt.json"
"$jq_bin" -e '
  .schema_version == 1 and .kind == "shadow_incident_validation" and
  .id == "incident.fixture-failing" and .body.authority_effect == "none" and
  .body.deploy_authority == "none" and .body.forge_effect == "none" and
  .body.activation_state == "inactive" and
  .body.summary.failing_check.kind == "file-digest"
' "$tmp/incident-receipt.json" >/dev/null || fail incident-receipt
[ "$("$jq_bin" -r '.body.incident_ref.sha256' "$tmp/incident-receipt.json")" = \
  "$(sha_file "$failing_incident")" ] || fail incident-receipt-digest
/usr/bin/cmp -s "$tmp/incident-receipt.json" \
  <("$jq_bin" -S -c . "$tmp/incident-receipt.json") || fail incident-receipt-canonical
"$validator" validate "$failing_incident" > "$tmp/incident-receipt-2.json"
/usr/bin/cmp -s "$tmp/incident-receipt.json" "$tmp/incident-receipt-2.json" ||
  fail incident-receipt-repeat
pass 'the incident validator returns one canonical no-authority receipt'

mutate() {
  local source=$1 name=$2 filter=$3
  local target="$tmp/$name.json"
  "$jq_bin" -S -c "$filter" "$source" > "$target"
  /usr/bin/printf '%s\n' "$target"
}
expect_incident_error() {
  local name=$1 expected=$2 input=$3 status=0
  "$validator" validate "$input" > "$tmp/$name.out" 2> "$tmp/$name.err" || status=$?
  if [ "$status" -eq 0 ] || [ -s "$tmp/$name.out" ] ||
     [ "$(/bin/cat "$tmp/$name.err")" != "$expected" ]; then
    fail "$name"
  fi
  pass "$name"
}
expect_incident_error incident-deploy-authority E_SHAPE \
  "$(mutate "$failing_incident" incident-deploy-authority \
    '.body.deploy_authority = "operator"')"
expect_incident_error incident-impossible-date E_SHAPE \
  "$(mutate "$failing_incident" incident-impossible-date \
    '.body.observed_at = "2026-02-30T00:00:00Z"')"
expect_incident_error incident-short-commit E_SHAPE \
  "$(mutate "$failing_incident" incident-short-commit \
    '.body.git_revision_ref.commit_id = "abc"')"
expect_incident_error incident-repository-drift E_SHAPE \
  "$(mutate "$failing_incident" incident-repository-drift \
    '.body.git_revision_ref.repository_id = "fixture.other"')"
expect_incident_error incident-escaping-path E_SHAPE \
  "$(mutate "$failing_incident" incident-escaping-path \
    '.body.failing_check.path = "../secrets.txt"')"
"$jq_bin" -c '{kind,schema_version,id,body}' "$failing_incident" > "$tmp/unsorted.json"
expect_incident_error incident-unsorted E_CANONICAL "$tmp/unsorted.json"
/bin/cat "$failing_incident" "$failing_incident" > "$tmp/two-roots.json"
expect_incident_error incident-two-roots E_PARSE "$tmp/two-roots.json"
/usr/bin/printf '\357\273\277' > "$tmp/byte-order-mark.json"
/bin/cat "$failing_incident" >> "$tmp/byte-order-mark.json"
expect_incident_error incident-byte-order-mark E_PARSE "$tmp/byte-order-mark.json"
/bin/ln -s "$failing_incident" "$tmp/incident-symlink.json"
expect_incident_error incident-symlink E_RUNTIME "$tmp/incident-symlink.json"
"$jq_bin" -S -c -n --slurpfile record "$failing_incident" \
  '$record[0] | .body.padding = ("y" * 300000)' > "$tmp/oversized.json"
expect_incident_error incident-oversized E_LIMIT "$tmp/oversized.json"
status=0
"$validator" validate > "$tmp/usage.out" 2> "$tmp/usage.err" || status=$?
[ "$status" -ne 0 ] && [ "$(/bin/cat "$tmp/usage.err")" = E_USAGE ] || fail incident-usage
pass 'the incident validator fails closed on every malformed record'

/usr/bin/cmp -s "$registry" <("$jq_bin" -S -c . "$registry") || fail registry-canonical
"$jq_bin" -e '
  .schema_version == 1 and .kind == "shadow_environment_registry" and
  .body.activation_state == "inactive" and
  (.body.environments | map(.environment_id)) == ["env.local-macos-fixture"] and
  (.body.environments[0].evidence_scope) == "fixtures-only" and
  (.body.environments[0].proof_state) == "unproven"
' "$registry" >/dev/null || fail registry-contents
pass 'the environment registry lists exactly the one proven-nowhere fixture environment'

run_case() {
  local name=$1 incident_input=$2 materialization=$3
  local claim_input=${4:-$claim} source=${5:-$tmp/source.git}
  local case_root="$tmp/case-$name" status=0
  /bin/mkdir -m 700 "$case_root" "$case_root/candidate" "$case_root/scratch" \
    "$case_root/state"
  "$reproducer" reproduce "$incident_input" "$claim_input" "$policy_set" "$duty" \
    "$materialization" "$source" "$case_root/candidate" "$case_root/scratch" \
    "$case_root/state" "$closure_helper" "$jq_bin" \
    > "$case_root/out.json" 2> "$case_root/err" || status=$?
  RUN_STATUS=$status
  RUN_ROOT=$case_root
}
expect_outcome() {
  local name=$1 outcome=$2 reason=$3
  shift 3
  run_case "$name" "$@"
  if [ "$RUN_STATUS" -ne 0 ] || [ -s "$RUN_ROOT/err" ]; then fail "$name"; fi
  "$jq_bin" -e --arg outcome "$outcome" --arg reason "$reason" '
    .schema_version == 1 and .kind == "shadow_reproduction_record" and
    .body.outcome == $outcome and .body.reason_id == $reason and
    .body.shadow == true and .body.authority == "none" and
    .body.deploy_authority == "none" and .body.activation_state == "inactive" and
    .body.qualification == {state:"unavailable",reason_id:"shadow.unqualified"}
  ' "$RUN_ROOT/out.json" >/dev/null || fail "$name outcome"
  /usr/bin/cmp -s "$RUN_ROOT/out.json" "$RUN_ROOT/state/shadow-record.json" ||
    fail "$name record"
  /usr/bin/cmp -s "$RUN_ROOT/out.json" <("$jq_bin" -S -c . "$RUN_ROOT/out.json") ||
    fail "$name canonical"
  "$trace_validator" validate \
    "$("$jq_bin" -r '.id' "$RUN_ROOT/out.json")" attempt.shadow-reproduce \
    "$RUN_ROOT/state/trace-ledger.json" > "$RUN_ROOT/trace-receipt.json" ||
    fail "$name trace"
  /usr/bin/cmp -s "$RUN_ROOT/trace-receipt.json" "$RUN_ROOT/state/trace-receipt.json" ||
    fail "$name trace receipt"
  [ "$("$jq_bin" -r '.body.trace_ledger_ref.sha256' "$RUN_ROOT/out.json")" = \
    "$(sha_file "$RUN_ROOT/state/trace-ledger.json")" ] || fail "$name ledger digest"
  pass "$name"
}
expect_reproduce_error() {
  local name=$1 expected=$2
  shift 2
  run_case "$name" "$@"
  if [ "$RUN_STATUS" -eq 0 ] || [ -s "$RUN_ROOT/out.json" ] ||
     [ "$(/bin/cat "$RUN_ROOT/err")" != "$expected" ]; then
    fail "$name"
  fi
  pass "$name"
}

expect_outcome reproduced reproduced check.failed-at-revision "$failing_incident" \
  "$tmp/fixture-failing/read-only-input.json"
reproduced_root=$RUN_ROOT
"$jq_bin" -e --arg commit "$failing_commit" '
  .body.materialization.state == "present" and
  .body.materialization.value.outcome == "no-change" and
  .body.materialization.value.candidate.commit_id == $commit and
  .body.check.execution.value.matches_expected == false and
  .body.environment.evaluation.value.verdict == "satisfied"
' "$reproduced_root/out.json" >/dev/null || fail reproduced-detail
pass 'the failing revision reproduces the incident with a read-only materialization'

expect_outcome no-change no-change check.passed-at-revision "$passing_incident" \
  "$tmp/fixture-passing/read-only-input.json"
"$jq_bin" -e '.body.check.execution.value.matches_expected == true' \
  "$RUN_ROOT/out.json" >/dev/null || fail no-change-detail
pass 'the fixed revision reports no-change instead of a reproduction'

expect_outcome reproduced-repeat reproduced check.failed-at-revision \
  "$failing_incident" "$tmp/fixture-failing/read-only-input.json"
/usr/bin/cmp -s "$reproduced_root/out.json" "$RUN_ROOT/out.json" || fail repeat-record
/usr/bin/cmp -s "$reproduced_root/state/trace-ledger.json" \
  "$RUN_ROOT/state/trace-ledger.json" || fail repeat-ledger
pass 'a repeat run is byte-identical in both the record and the trace ledger'

materialized_result="$reproduced_root/state/materialization-result.json"
"$core" validate-stage-run "$tmp/fixture-failing/request.json" \
  "$tmp/fixture-failing/resolved.json" "$materialized_result" ||
  fail materialization-result-contract
"$jq_bin" -e --arg sha "$(sha_file "$materialized_result")" \
  --slurpfile result "$materialized_result" '
  .body.materialization.value.stage_result_ref ==
    {schema_version:2,kind:"stage_result",id:$result[0].id,sha256:$sha}
' "$reproduced_root/out.json" >/dev/null || fail stage-result-ref
pass 'the record binds the materializer core v2 stage result by exact identity'

"$jq_bin" -e '.body.environment.evaluation.value.verdict == "satisfied"' \
  "$reproduced_root/out.json" >/dev/null || fail environment-detail
expect_outcome unlisted-environment inconclusive environment.unlisted \
  "$failing_incident" "$tmp/fixture-failing/read-only-input.json" \
  "$(mutate "$claim" claim-unlisted '.id = "env.unlisted-runner"')"
"$jq_bin" -e '
  .body.environment.evaluation == {state:"absent",reason_id:"environment.unlisted"} and
  .body.materialization.state == "absent" and .body.check.execution.state == "absent"
' "$RUN_ROOT/out.json" >/dev/null || fail unlisted-detail
pass 'an environment outside the registry never runs and stays inconclusive'

expect_outcome unsatisfied-environment inconclusive environment.not-satisfied \
  "$failing_incident" "$tmp/fixture-failing/read-only-input.json" \
  "$(mutate "$claim" claim-incomplete '.body.declaration_status = "incomplete"')"
"$jq_bin" -e '
  .body.environment.evaluation.value.verdict == "inconclusive" and
  (.body.environment.evaluation.value.reason_ids | index("declaration.incomplete")) != null
' "$RUN_ROOT/out.json" >/dev/null || fail unsatisfied-detail
pass 'a listed environment whose sandbox claim is not satisfied stays inconclusive'

expect_outcome refused-environment inconclusive environment.evaluation-refused \
  "$failing_incident" "$tmp/fixture-failing/read-only-input.json" \
  "$(mutate "$claim" claim-malformed '.body.tools[0].network = "unknown"')"
"$jq_bin" -e '
  .body.environment.evaluation ==
    {state:"absent",reason_id:"environment.evaluation-refused"}
' "$RUN_ROOT/out.json" >/dev/null || fail refused-detail
pass 'a claim the real sandbox evaluator refuses is inconclusive, never satisfied'

expect_outcome forged-policy-binding inconclusive environment.not-satisfied \
  "$failing_incident" "$tmp/fixture-failing/read-only-input.json" \
  "$(mutate "$claim" claim-forged '.body.policy_set_ref.sha256 = ("0" * 64)')"
"$jq_bin" -e '.body.environment.evaluation.value.verdict == "violated"' \
  "$RUN_ROOT/out.json" >/dev/null || fail forged-detail
pass 'a claim that does not bind its own policy set is violated, so nothing runs'

expect_outcome named-check inconclusive check.not-runnable \
  "$(mutate "$failing_incident" incident-named-check \
    '.body.failing_check = {kind:"named-check",check_id:"check.unit-tests"}')" \
  "$tmp/fixture-failing/read-only-input.json"
pass 'a named deterministic check has no runner here and is inconclusive'

/bin/mkdir -m 700 "$tmp/gone.git"
git_clean init -q --bare --object-format=sha1 "$tmp/gone.git"
expect_outcome missing-revision inconclusive materialization.refused \
  "$failing_incident" "$tmp/fixture-failing/read-only-input.json" "$claim" "$tmp/gone.git"
pass 'a source repository without the incident revision cannot materialize'

expect_outcome missing-path inconclusive check.unreadable \
  "$(mutate "$failing_incident" incident-missing-path \
    '.body.failing_check.path = "not-present.txt"')" \
  "$tmp/fixture-failing/read-only-input.json"
pass 'a check path absent at the revision is inconclusive, never a reproduction'

expect_reproduce_error moved-revision E_STALE "$passing_incident" \
  "$tmp/fixture-failing/read-only-input.json"
expect_reproduce_error writable-input E_READ_ONLY "$failing_incident" \
  "$tmp/fixture-failing/input.json"
expect_reproduce_error writable-input-unlisted-environment E_READ_ONLY "$failing_incident" \
  "$tmp/fixture-failing/input.json" \
  "$(mutate "$claim" claim-unlisted-writable '.id = "env.unlisted-runner"')"
expect_reproduce_error network-input E_READ_ONLY "$failing_incident" \
  "$(mutate "$tmp/fixture-failing/read-only-input.json" input-network \
    '.stage_request.content.body.operation.arguments.network_mode = "allow"')"
expect_reproduce_error symlinked-incident E_RUNTIME "$tmp/incident-symlink.json" \
  "$tmp/fixture-failing/read-only-input.json"
expect_reproduce_error two-root-incident E_PARSE "$tmp/two-roots.json" \
  "$tmp/fixture-failing/read-only-input.json"
expect_reproduce_error oversized-incident E_LIMIT "$tmp/oversized.json" \
  "$tmp/fixture-failing/read-only-input.json"
expect_reproduce_error unsorted-incident E_CANONICAL "$tmp/unsorted.json" \
  "$tmp/fixture-failing/read-only-input.json"
expect_reproduce_error malformed-incident E_SHAPE \
  "$tmp/incident-deploy-authority.json" "$tmp/fixture-failing/read-only-input.json"

status=0
"$reproducer" reproduce "$failing_incident" > "$tmp/reproduce-usage.out" \
  2> "$tmp/reproduce-usage.err" || status=$?
[ "$status" -ne 0 ] &&
  [ "$(/bin/cat "$tmp/reproduce-usage.err")" = E_USAGE ] || fail reproduce-usage
/bin/mkdir -m 700 "$tmp/relative-check"
status=0
(cd "$tmp" && "$reproducer" reproduce incident-failing.json "$claim" "$policy_set" \
  "$duty" "$tmp/fixture-failing/read-only-input.json" "$tmp/source.git" \
  "$tmp/relative-check" "$tmp/relative-check" "$tmp/relative-check" \
  "$closure_helper" "$jq_bin") > /dev/null 2> "$tmp/relative.err" || status=$?
[ "$status" -ne 0 ] && [ "$(/bin/cat "$tmp/relative.err")" = E_USAGE ] || fail relative-path
pass 'the driver refuses a bad invocation and any relative path'

/bin/mkdir -m 700 "$tmp/dirty" "$tmp/dirty/candidate" "$tmp/dirty/scratch" \
  "$tmp/dirty/state"
: > "$tmp/dirty/state/leftover"
status=0
"$reproducer" reproduce "$failing_incident" "$claim" "$policy_set" "$duty" \
  "$tmp/fixture-failing/read-only-input.json" "$tmp/source.git" \
  "$tmp/dirty/candidate" "$tmp/dirty/scratch" "$tmp/dirty/state" \
  "$closure_helper" "$jq_bin" > /dev/null 2> "$tmp/dirty.err" || status=$?
[ "$status" -ne 0 ] && [ "$(/bin/cat "$tmp/dirty.err")" = E_WORKSPACE ] || fail dirty-state
/bin/mkdir -m 700 "$tmp/nested" "$tmp/nested/candidate" "$tmp/nested/scratch"
/bin/mkdir -m 700 "$tmp/nested/scratch/state"
status=0
"$reproducer" reproduce "$failing_incident" "$claim" "$policy_set" "$duty" \
  "$tmp/fixture-failing/read-only-input.json" "$tmp/source.git" \
  "$tmp/nested/candidate" "$tmp/nested/scratch" "$tmp/nested/scratch/state" \
  "$closure_helper" "$jq_bin" > /dev/null 2> "$tmp/nested.err" || status=$?
[ "$status" -ne 0 ] && [ "$(/bin/cat "$tmp/nested.err")" = E_WORKSPACE ] || fail nested-state
pass 'the driver refuses a used or overlapping caller directory'

[ "$source_fingerprint" = "$(/usr/bin/find "$tmp/source.git" -type f -print0 |
  LC_ALL=C sort -z | /usr/bin/xargs -0 /usr/bin/shasum -a 256 |
  /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')" ] || fail source-mutated
for component in reproduce.sh validate-incident.sh incident-record.jq \
  shadow-environments.json; do
  [ "$(sha_file "$root/shadow/v1/$component")" = \
    "$("$jq_bin" -r --arg name "$component" '.[$name]' "$tmp/component-digests.json")" ] ||
    fail component-mutated
done
pass 'the source repository and the component files are never written'

if /usr/bin/grep -Eq '(^|[^[:alnum:]_.-])(gh|glab|curl|wget|ssh|codex|claude)([^[:alnum:]_.-]|$)' \
     "$reproducer" ||
   /usr/bin/grep -Eq 'git +(push|commit|apply|update-ref|fetch|clone|init|config)' \
     "$reproducer" ||
   /usr/bin/grep -Eq 'pull_request|api\.github|https?://' "$reproducer"; then
  fail forge-or-network-command
fi
/usr/bin/grep -Fq 'cat-file' "$reproducer" || fail unexpected-git-use
pass 'the driver reads Git objects only and calls no forge, network, or model tool'

/usr/bin/printf 'shadow slice: %s focused checks passed\n' "$passes"
