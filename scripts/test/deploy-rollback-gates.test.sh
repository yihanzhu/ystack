#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
validator="$root/deploy/v1/validate-deploy-document.sh"
tiers="$root/deploy/v1/environment-tiers.json"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-deploy-contracts-test.XXXXXX")
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

rollback="$tmp/rollback-request.json"
"$jq_bin" -S -c --arg rehearsal_sha "$rehearsal_sha" --arg previous_sha "$previous_sha" '
  .kind="rollback_request"|.id="rollback-request.production.0001"|
  .body.requested_capability="rollback"|
  .body.rehearsal_ref={schema_version:1,kind:"rollback_rehearsal_record",
    id:"rollback-rehearsal.production.0001",sha256:$rehearsal_sha}|
  .body.rollback_to_release_ref={schema_version:1,kind:"release_record",
    id:"release.moon-garden.0000",sha256:$previous_sha}' "$request" >"$rollback"
routine_authorization=$(mutate "$authorization" staging-authorization '
  .id="deploy-authorization.staging.0001"|.body.authorization_kind="routine-gate"|
  .body.environment.tier="staging"|.body.operator.role="publisher"|
  .body.operator.principal_id="principal.publisher"')
dev_authorization=$(mutate "$routine_authorization" dev-authorization '
  .id="deploy-authorization.dev.0001"|.body.environment.tier="dev"')
dev_status="$tmp/dev-status-request.json"
"$jq_bin" -S -c --arg sha "$(sha256_path "$dev_authorization")" '
  .kind="status_request"|.id="status-request.dev.0001"|
  .body.requested_capability="status"|.body.environment.tier="dev"|
  .body.actor_ref.role="observer"|
  .body.authorization_ref.id="deploy-authorization.dev.0001"|
  .body.authorization_ref.sha256=$sha' "$request" >"$dev_status"

# Fixtures the evaluator half of this suite also uses; here they exercise the
# validator's fail-closed handling of malformed, multi-root, oversized, and
# symlinked input.
/bin/cat "$request" "$request" >"$tmp/multi-root.json"
"$jq_bin" -c . "$request" | "$jq_bin" -c '{kind,id,schema_version,body}' \
  >"$tmp/uncanonical.json"
"$jq_bin" -S -c -n '{schema_version:1,kind:"deploy_request",id:"deploy-request.large",
  body:{padding:("x"*1100000)}}' >"$tmp/oversized.json"
/bin/ln -s "$request" "$tmp/symlinked-request.json"

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


for path in deploy/v1/environment-tiers.json deploy/v1/deploy_contracts.jq \
  deploy/v1/validate-deploy-document.sh scripts/test/deploy-rollback-gates.test.sh; do
  [ -e "$root/$path" ] || fail "owned path $path"
done
pass 'owned product and test paths are complete'
/usr/bin/printf 'deploy and rollback contracts: %s focused checks passed\n' "$passes"
