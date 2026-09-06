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
policy="$root/scope/v1/scope-policy.json"
record_program="$root/scope/v1/workflow-scope.jq"

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
expect_validator_error() {
  local label=$1 expected=$2 input=$3 status=0 out
  out=$(run_validator "$input" 2>&1 >/dev/null) || status=$?
  [ "$status" -ne 0 ] || fail "$label accepted"
  [ "$out" = "$expected" ] || fail "$label expected $expected got $out"
}
for shipped in "$policy" "$record_program" "$validator"; do
  [ -f "$shipped" ] && [ ! -L "$shipped" ] || fail "missing $shipped"
done
[ -x "$validator" ] || fail 'the validator must be executable'
"$jq_bin" -S -c . "$policy" >"$tmp/policy-canonical.json"
/usr/bin/cmp -s "$policy" "$tmp/policy-canonical.json" || fail 'policy is not canonical'
generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" "$root/scripts/core-contract.sh")
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || fail 'selected generation shape'
for source_path in scope/v1/scope-policy.json scope/v1/workflow-scope.jq \
  scope/v1/validate-scope.sh scripts/test/scope-qualification.test.sh; do
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

/usr/bin/printf 'scope qualification: %s focused checks passed\n' "$passes"
