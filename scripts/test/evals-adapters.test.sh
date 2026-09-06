#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P) || exit 1
framework="$root/evals/v1/run-evals.sh"
launcher="$root/evals/v1/evals-launcher.sh"
catalog="$root/evals/v1/eval-catalog.json"
seed_set="$root/evals/v1/seed-set-adapters.json"
manifest="$root/ci/required-files.txt"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-evals-adapters-test.XXXXXX") || exit 1
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

normalizers=(codex-native-reviewer github-actions-ci github-forge)

# --- shipped seed set: canonical, listed, and the family names its source -------
[ -f "$seed_set" ] && [ ! -L "$seed_set" ] || fail 'adapters seed set missing'
"$jq_bin" -S -c . "$seed_set" > "$tmp/canonical.json" || fail 'seed set parse'
/usr/bin/cmp -s "$seed_set" "$tmp/canonical.json" || fail 'seed set not canonical'
for path in evals/v1/seed-set-adapters.json scripts/test/evals-adapters.test.sh; do
  /usr/bin/grep -qxF "$path" "$manifest" || fail "manifest missing $path"
done
"$jq_bin" -e '
  .body.seed_source == "adapters.provider-normalizers.v1" and .body.shared == {} and
  (.body.cases | length) == 37 and
  all(.body.cases[]; .family_id == "adapter-contract-compliance") and
  ([.body.cases[].normalizer] | unique) ==
    ["codex-native-reviewer","github-actions-ci","github-forge"]
' "$seed_set" > /dev/null || fail 'seed set header'
"$jq_bin" -e '
  .body.families[] | select(.family_id == "adapter-contract-compliance") |
  .seed_status == "seeded" and .seed_sources == ["adapters.provider-normalizers.v1"]
' "$catalog" > /dev/null || fail 'catalog does not name the normalizer source'
pass 'adapters seed set is canonical, listed, and its catalog family names the normalizer source'

for name in "${normalizers[@]}"; do
  /usr/bin/grep -qF "'$name $(sha_file "$root/adapters/$name/v1/normalize.jq")'" "$launcher" ||
    fail "launcher does not pin adapters/$name/v1/normalize.jq"
done
pass 'launcher pins the three shipped normalizers by digest'

# --- one deterministic pass through the real normalizers -------------------------
observed_at=2026-09-05T00:00:00Z
run_framework() {
  local out=$1 err=$2 seed=$3
  "$framework" run "$seed" "$observed_at" >"$out" 2>"$err"
}
first="$tmp/first.json"
run_framework "$first" "$tmp/first.err" "$seed_set" || fail "framework run failed: $(<"$tmp/first.err")"
[ ! -s "$tmp/first.err" ] || fail 'framework wrote to stderr on success'
"$jq_bin" -e --arg seed_sha "$(sha_file "$seed_set")" \
  --arg reviewer_sha "$(sha_file "$root/adapters/codex-native-reviewer/v1/normalize.jq")" \
  --arg ci_sha "$(sha_file "$root/adapters/github-actions-ci/v1/normalize.jq")" \
  --arg forge_sha "$(sha_file "$root/adapters/github-forge/v1/normalize.jq")" '
  def tool($name; $sha):
    {content_id:("adapter-normalizer." + $name + ".v1"),media_type:"text/x-jq",sha256:$sha};
  .kind == "eval_run_result" and .id == "evals.run.evals.seed.provider-normalizers.v1" and
  .body.seed_source == "adapters.provider-normalizers.v1" and
  .body.seed_set_ref.sha256 == $seed_sha and
  .body.summary == {total:37,passed:37,failed:0,inconclusive:0} and
  all(.body.cases[]; .verdict == "passed" and .grader_kind == "deterministic" and
      .subject_ref.content_id == "adapter-provider-snapshot.v1") and
  (.body.trace | map(.tool_ref) | unique) ==
    [tool("codex-native-reviewer";$reviewer_sha),tool("github-actions-ci";$ci_sha),
     tool("github-forge";$forge_sha)] and
  all(.body.trace[]; .grader_kind == "deterministic" and
      .adapter == {state:"absent"} and .latency == {state:"absent"} and .cost == {state:"absent"}) and
  (.body.evaluator.content.body.adapter_closure | length) == 3
' "$first" > /dev/null || fail 'run result shape or verdicts'
pass 'all thirty-seven normalizer cases pass, each traced to the one normalizer that ran'

"$jq_bin" -e '
  def normalized($id): .body.cases[] | select(.case_id == $id) | .observation.value.normalization.value;
  def refused($id): .body.cases[] | select(.case_id == $id) | .observation.value.error_token.value;
  normalized("adapter.forge.merged") ==
    {state:"merged",reason_id:"github.change-request-merged",stale_bindings:[]} and
  normalized("adapter.forge.stale-app-head-repository") ==
    {state:"stale",reason_id:"github.binding-stale",stale_bindings:["app","head","repository"]} and
  normalized("adapter.forge.provider-metadata-cannot-decide").state == "open-ready" and
  normalized("adapter.reviewer.dismissed").state == "dismissed" and
  normalized("adapter.reviewer.in-progress-inconclusive") ==
    {state:"inconclusive",reason_id:"codex.review-incomplete",stale_bindings:[]} and
  normalized("adapter.reviewer.stale-review").stale_bindings == ["review"] and
  normalized("adapter.ci.timed-out") == {state:"timed-out",reason_id:"ci.timed-out",stale_bindings:[]} and
  normalized("adapter.ci.provider-stale") == {state:"stale",reason_id:"ci.provider-stale",stale_bindings:[]} and
  normalized("adapter.ci.stale-run-attempt").stale_bindings == ["run-attempt"] and
  refused("adapter.forge.extra-envelope-field-rejected") == "github-forge.invalid-envelope" and
  refused("adapter.reviewer.exposed-model-rejected") == "codex-reviewer.invalid-snapshot" and
  refused("adapter.ci.malformed-content-ref-rejected") == "github-actions-ci.invalid-trust-context"
' "$first" > /dev/null || fail 'normalizer states, reasons, stale bindings, or refusals misrecorded'
pass 'forge, CI, and reviewer states, stale bindings, and refusals are recorded exactly'

second="$tmp/second.json"
run_framework "$second" "$tmp/second.err" "$seed_set" || fail 'second run failed'
/usr/bin/cmp -s "$first" "$second" || fail 'repeat run differs'
[ "$("$jq_bin" -S -c . "$first")" = "$(<"$first")" ] || fail 'output not canonical'
pass 'repeat run is byte-identical and canonical'

"$jq_bin" -e '
  ([.. | objects | keys[] | select(. == "authority" or . == "permissions" or
    . == "capabilities" or . == "credential" or . == "execute" or
    . == "schedule" or . == "merge" or . == "publish")] | length) == 0
' "$first" > /dev/null || fail 'authority or effect field present'
pass 'inactive data-only boundary holds for normalizer replays'

# --- grading is honest --------------------------------------------------------------
wrong="$tmp/wrong.json"
"$jq_bin" -S -c '
  .body.cases |= map(if .case_id == "adapter.forge.provider-metadata-cannot-decide"
    then .expectation.state = "merged" | .expectation.reason_id = "github.change-request-merged"
    else . end)
' "$seed_set" > "$wrong"
run_framework "$tmp/wrong.out" "$tmp/wrong.err" "$wrong" || fail 'wrong-expectation run errored'
"$jq_bin" -e '
  .body.summary == {total:37,passed:36,failed:1,inconclusive:0} and
  (.body.cases[] | select(.case_id == "adapter.forge.provider-metadata-cannot-decide") |
    .verdict == "failed" and .reason_id == "evals.normalization-mismatch")
' "$tmp/wrong.out" > /dev/null || fail 'provider text expected to decide a state was not failed'
partial="$tmp/partial.json"
"$jq_bin" -S -c '
  .body.cases |= map(if .case_id == "adapter.forge.stale-app-head-repository"
    then .expectation.stale_bindings = ["head"] else . end)
' "$seed_set" > "$partial"
run_framework "$tmp/partial.out" "$tmp/partial.err" "$partial" || fail 'partial-bindings run errored'
"$jq_bin" -e '
  .body.cases[] | select(.case_id == "adapter.forge.stale-app-head-repository") |
  .verdict == "failed" and .reason_id == "evals.normalization-mismatch"
' "$tmp/partial.out" > /dev/null || fail 'an incomplete stale-binding set was accepted'
pass 'a wrong state or an incomplete stale-binding set is graded failed, never silently passed'

# --- fail closed on bad, moved, or misfiled input ----------------------------------
expect_error() {
  local name=$1 expected=$2 seed=$3 out err status
  out="$tmp/$name.out"; err="$tmp/$name.err"
  "$framework" run "$seed" "$observed_at" >"$out" 2>"$err"
  status=$?
  [ "$status" -ne 0 ] && [ ! -s "$out" ] && [ "$(<"$err")" = "$expected" ] ||
    fail "$name expected $expected, got status $status [$(<"$err")]"
}
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "adapter.forge.open-ready"
  then .input.sha256 = ("f" * 64) else . end)' "$seed_set" > "$tmp/moved.json"
expect_error moved-input-digest E_RELATION "$tmp/moved.json"
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "adapter.forge.open-ready"
  then .normalizer = "claude-code-producer" else . end)' "$seed_set" > "$tmp/unknown.json"
expect_error unknown-normalizer E_SHAPE "$tmp/unknown.json"
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "adapter.forge.open-ready"
  then .family_id = "stale-moved-artifacts" else . end)' "$seed_set" > "$tmp/misfiled.json"
expect_error family-without-normalizer-source E_SHAPE "$tmp/misfiled.json"
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "adapter.forge.open-ready"
  then .expectation.state = "approved" else . end)' "$seed_set" > "$tmp/badstate.json"
expect_error unknown-state E_SHAPE "$tmp/badstate.json"
"$jq_bin" -S -c '.body.cases |= map(if .case_id == "adapter.forge.missing-state-rejected"
  then .expectation.error_token = "github-forge.something-else" else . end)' "$seed_set" \
  > "$tmp/badtoken.json"
expect_error unknown-error-id E_SHAPE "$tmp/badtoken.json"
pass 'moved, misfiled, and mis-shaped normalizer seed sets fail closed with one token'

# --- the launcher refuses an edited normalizer --------------------------------------
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
  sandbox.jq validate.sh; do
  /bin/cp "$root/control/v1/$f" "$copy/control/v1/$f"
done
for name in "${normalizers[@]}"; do
  /bin/mkdir -p "$copy/adapters/$name/v1"
  /bin/cp "$root/adapters/$name/v1/normalize.jq" "$copy/adapters/$name/v1/normalize.jq"
done
/usr/bin/printf '\n# tampered\n' >> "$copy/adapters/github-forge/v1/normalize.jq"
if "$copy/evals/v1/run-evals.sh" run "$seed_set" "$observed_at" >"$tmp/stale.out" 2>"$tmp/stale.err"; then
  fail 'edited normalizer was accepted'
fi
[ ! -s "$tmp/stale.out" ] && [ "$(<"$tmp/stale.err")" = E_STALE ] ||
  fail "edited normalizer was not refused: [$(<"$tmp/stale.err")]"
pass 'an edited normalizer is refused as stale before anything runs'

/usr/bin/printf '1..%s\n' "$passes"
