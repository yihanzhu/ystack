#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
validator="$root/shadow/v1/validate-incident.sh"
registry="$root/shadow/v1/shadow-environments.json"
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
export PATH="$bin:/usr/bin:/bin"

"$jq_bin" -S -c -n \
  --arg validate "$(sha_file "$validator")" \
  --arg program "$(sha_file "$root/shadow/v1/incident-record.jq")" \
  --arg registry "$(sha_file "$registry")" '{
    "validate-incident.sh":$validate,"incident-record.jq":$program,
    "shadow-environments.json":$registry}' > "$tmp/component-digests.json"

incident_commit=0123456789abcdef0123456789abcdef01234567
expected_digest=4fdbc441ea7b546100e086ac1e4fc5ae6749b7314311c99db05be450eca12996
failing_incident="$tmp/incident.json"
"$jq_bin" -S -c -n --arg commit "$incident_commit" --arg expected "$expected_digest" '
  {schema_version:1,kind:"shadow_incident_record",id:"incident.fixture-failing",
   body:{deploy_authority:"none",target_repository_id:"fixture.target",
     git_revision_ref:{repository_id:"fixture.target",hash_algorithm:"sha1",
       commit_id:$commit},
     failing_check:{kind:"file-digest",path:"source.txt",expected_sha256:$expected},
     observed_symptom:"source.txt no longer matches the recorded digest",
     reporter_actor_ref:"actor.fixture-reporter",
     observed_at:"2026-08-30T00:00:04Z"}}
' > "$failing_incident"

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

"$validator" validate "$(mutate "$failing_incident" incident-named-check \
  '.body.failing_check = {kind:"named-check",check_id:"check.unit-tests"}')" \
  > "$tmp/named-receipt.json"
"$jq_bin" -e '.body.summary.failing_check.check_id == "check.unit-tests"' \
  "$tmp/named-receipt.json" >/dev/null || fail incident-named-check
pass 'a named deterministic check id is an accepted failing-check form'
expect_error() {
  local name=$1 expected=$2 input=$3 status=0
  "$validator" validate "$input" > "$tmp/$name.out" 2> "$tmp/$name.err" || status=$?
  if [ "$status" -eq 0 ] || [ -s "$tmp/$name.out" ] ||
     [ "$(/bin/cat "$tmp/$name.err")" != "$expected" ]; then
    fail "$name"
  fi
  pass "$name"
}
expect_error incident-deploy-authority E_SHAPE \
  "$(mutate "$failing_incident" incident-deploy-authority \
    '.body.deploy_authority = "operator"')"
expect_error incident-impossible-date E_SHAPE \
  "$(mutate "$failing_incident" incident-impossible-date \
    '.body.observed_at = "2026-02-30T00:00:00Z"')"
expect_error incident-short-commit E_SHAPE \
  "$(mutate "$failing_incident" incident-short-commit \
    '.body.git_revision_ref.commit_id = "abc"')"
expect_error incident-repository-drift E_SHAPE \
  "$(mutate "$failing_incident" incident-repository-drift \
    '.body.git_revision_ref.repository_id = "fixture.other"')"
expect_error incident-escaping-path E_SHAPE \
  "$(mutate "$failing_incident" incident-escaping-path \
    '.body.failing_check.path = "../secrets.txt"')"
expect_error incident-extra-field E_SHAPE \
  "$(mutate "$failing_incident" incident-extra-field \
    '.body.deploy_target = "production"')"
"$jq_bin" -c '{kind,schema_version,id,body}' "$failing_incident" > "$tmp/unsorted.json"
expect_error incident-unsorted E_CANONICAL "$tmp/unsorted.json"
/bin/cat "$failing_incident" "$failing_incident" > "$tmp/two-roots.json"
expect_error incident-two-roots E_PARSE "$tmp/two-roots.json"
/usr/bin/printf '\357\273\277' > "$tmp/byte-order-mark.json"
/bin/cat "$failing_incident" >> "$tmp/byte-order-mark.json"
expect_error incident-byte-order-mark E_PARSE "$tmp/byte-order-mark.json"
/bin/ln -s "$failing_incident" "$tmp/incident-symlink.json"
expect_error incident-symlink E_RUNTIME "$tmp/incident-symlink.json"
expect_error incident-absent E_RUNTIME "$tmp/never-written.json"
"$jq_bin" -S -c -n --slurpfile record "$failing_incident" \
  '$record[0] | .body.padding = ("y" * 300000)' > "$tmp/oversized.json"
expect_error incident-oversized E_LIMIT "$tmp/oversized.json"
status=0
"$validator" validate > "$tmp/usage.out" 2> "$tmp/usage.err" || status=$?
[ "$status" -ne 0 ] && [ "$(/bin/cat "$tmp/usage.err")" = E_USAGE ] || fail incident-usage
status=0
(cd "$tmp" && "$validator" validate incident.json) > /dev/null 2> "$tmp/relative.err" ||
  status=$?
[ "$status" -ne 0 ] && [ "$(/bin/cat "$tmp/relative.err")" = E_USAGE ] || fail relative-path
pass 'the incident validator fails closed on every malformed or unusable record'

/usr/bin/cmp -s "$registry" <("$jq_bin" -S -c . "$registry") || fail registry-canonical
"$jq_bin" -e '
  .schema_version == 1 and .kind == "shadow_environment_registry" and
  .body.activation_state == "inactive" and
  (.body.environments | map(.environment_id)) == ["env.local-macos-fixture"] and
  (.body.environments[0].evidence_scope) == "fixtures-only" and
  (.body.environments[0].proof_state) == "unproven"
' "$registry" >/dev/null || fail registry-contents
pass 'the environment registry lists exactly the one proven-nowhere fixture environment'

for component in validate-incident.sh incident-record.jq shadow-environments.json; do
  [ "$(sha_file "$root/shadow/v1/$component")" = \
    "$("$jq_bin" -r --arg name "$component" '.[$name]' "$tmp/component-digests.json")" ] ||
    fail component-mutated
done
if /usr/bin/grep -Eq '(^|[^[:alnum:]_.-])(gh|glab|curl|wget|ssh|codex|claude)([^[:alnum:]_.-]|$)' \
     "$validator" ||
   /usr/bin/grep -Eq 'pull_request|api\.github|https?://' "$validator"; then
  fail forge-or-network-command
fi
pass 'the validator never writes its own files and calls no forge, network, or model tool'

/usr/bin/printf 'shadow slice: %s focused checks passed\n' "$passes"
