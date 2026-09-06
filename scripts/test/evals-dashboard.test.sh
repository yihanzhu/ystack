#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P) || exit 1
framework="$root/evals/v1/run-evals.sh"
catalog="$root/evals/v1/eval-catalog.json"
manifest="$root/ci/required-files.txt"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-evals-dashboard-test.XXXXXX") || exit 1
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

/usr/bin/grep -qxF scripts/test/evals-dashboard.test.sh "$manifest" || fail 'manifest missing test'
observed_at=2026-09-05T00:00:00Z

# --- one run per shipped seed set, then one dashboard over all of them -----------
seeds=(seed-set seed-set-events seed-set-plans seed-set-boundaries seed-set-adapters
  seed-set-approvals seed-set-duty)
pairs=()
for name in "${seeds[@]}"; do
  "$framework" run "$root/evals/v1/$name.json" "$observed_at" \
    >"$tmp/$name.result.json" 2>"$tmp/$name.err" || fail "run failed for $name: $(<"$tmp/$name.err")"
  pairs+=("$root/evals/v1/$name.json" "$tmp/$name.result.json")
done
pass 'all seven shipped seed sets produce run results'

dashboard="$tmp/dashboard.json"
"$framework" dashboard "$observed_at" "${pairs[@]}" >"$dashboard" 2>"$tmp/dashboard.err" ||
  fail "dashboard failed: $(<"$tmp/dashboard.err")"
[ ! -s "$tmp/dashboard.err" ] || fail 'dashboard wrote to stderr on success'
"$jq_bin" -e --arg catalog_sha "$(sha_file "$catalog")" '
  .kind == "eval_dashboard" and .id == "evals.dashboard.v1" and
  .body.activation_state == "inactive" and .body.authority_effect == "none" and
  .body.mode == "deterministic-offline" and .body.catalog_ref.sha256 == $catalog_sha and
  (.body.inputs | length) == 7 and
  .body.coverage == {families_total:9,families_seeded:7,families_declared:2,
                     families_with_results:7,
                     sources_with_results:["adapters.provider-normalizers.v1",
                       "control.duty-separation.v1","control.risk-gates.v1",
                       "control.sandbox-policy.v1","core.stage-run.v2",
                       "orchestrator.reconciliation-plan.v1","orchestrator.state-scanner.v1"]} and
  .body.quality == {total:138,passed:138,failed:0,inconclusive:0} and
  (.body.families | length) == 9 and
  (.body.families[] | select(.family_id == "repeated-cancelled-missed-events") |
    .runs == 2 and .cases.total == 25 and .cases.passed == 25) and
  (.body.families[] | select(.family_id == "malicious-instructions") |
    .runs == 0 and .cases == {total:0,passed:0,failed:0,inconclusive:0}) and
  .body.recovery == {stranded_recovered:2,cancelled_stayed_terminal:2,
                     repeats_redelivered_once:3,repeats_suppressed_after_acknowledgement:1,
                     retry_limit_enforced:1,events_refused:6} and
  all(.body.telemetry[]; . == {state:"absent",reason_id:"evals.no-live-runs"}) and
  (.body.flow | length) == 15 and
  all(.body.flow[]; . == {state:"absent",reason_id:"evals.no-operating-history"})
' "$dashboard" > /dev/null || fail 'dashboard coverage, quality, recovery, or absent metrics'
pass 'dashboard counts coverage, quality, and recovery; live metrics stay absent with a reason'

"$jq_bin" -e '
  ([.. | objects | keys[] | select(. == "authority" or . == "permissions" or
    . == "capabilities" or . == "credential" or . == "network" or . == "execute" or
    . == "schedule" or . == "merge" or . == "publish")] | length) == 0
' "$dashboard" > /dev/null || fail 'authority or effect field present'
pass 'inactive data-only boundary holds for the dashboard'

second="$tmp/dashboard-2.json"
"$framework" dashboard "$observed_at" "${pairs[@]}" >"$second" 2>/dev/null || fail 'second dashboard failed'
/usr/bin/cmp -s "$dashboard" "$second" || fail 'repeat dashboard differs'
[ "$("$jq_bin" -S -c . "$dashboard")" = "$(<"$dashboard")" ] || fail 'dashboard not canonical'
pass 'repeat dashboard is byte-identical and canonical'

# A single pair is enough, and its numbers are that run's alone.
"$framework" dashboard "$observed_at" "$root/evals/v1/seed-set.json" "$tmp/seed-set.result.json" \
  >"$tmp/one.json" 2>/dev/null || fail 'single-pair dashboard failed'
"$jq_bin" -e '
  (.body.inputs | length) == 1 and .body.quality.total == 8 and
  .body.coverage.families_with_results == 2 and
  .body.coverage.sources_with_results == ["core.stage-run.v2"] and
  .body.recovery == {stranded_recovered:0,cancelled_stayed_terminal:0,
                     repeats_redelivered_once:0,repeats_suppressed_after_acknowledgement:0,
                     retry_limit_enforced:0,events_refused:0}
' "$tmp/one.json" > /dev/null || fail 'single-pair dashboard counts'
pass 'a dashboard over one result counts only that result'

# A result recorded at another time still counts, and a seed file without a
# trailing newline (paired with the result it actually produced) still reads as
# its own document beside the next one.
/usr/bin/printf '%s' "$(<"$root/evals/v1/seed-set.json")" > "$tmp/seed-no-newline.json"
"$framework" run "$tmp/seed-no-newline.json" 2026-08-30T00:00:00Z \
  >"$tmp/earlier.result.json" 2>/dev/null || fail 'earlier run failed'
"$framework" dashboard "$observed_at" "$tmp/seed-no-newline.json" "$tmp/earlier.result.json" \
  "$root/evals/v1/seed-set-events.json" "$tmp/seed-set-events.result.json" \
  >"$tmp/mixed.json" 2>"$tmp/mixed.err" || fail "mixed-time dashboard failed: $(<"$tmp/mixed.err")"
"$jq_bin" -e '
  .body.observed_at == "2026-09-05T00:00:00Z" and
  ([.body.inputs[].observed_at] | sort) == ["2026-08-30T00:00:00Z","2026-09-05T00:00:00Z"] and
  .body.quality.total == 20
' "$tmp/mixed.json" > /dev/null || fail 'mixed-time dashboard inputs'
pass 'results recorded at other times and seed files without a trailing newline are accepted'

# --- results are re-validated before they count ------------------------------------
expect_error() {
  local name=$1 expected=$2 out err status
  shift 2
  out="$tmp/$name.out"; err="$tmp/$name.err"
  "$framework" dashboard "$observed_at" "$@" >"$out" 2>"$err"
  status=$?
  [ "$status" -ne 0 ] && [ ! -s "$out" ] && [ "$(<"$err")" = "$expected" ] ||
    fail "$name expected $expected, got status $status [$(<"$err")]"
}
"$jq_bin" -S -c '.body.cases[0].verdict = "failed" | .body.cases[0].reason_id = "evals.status-mismatch" |
  .body.summary.passed -= 1 | .body.summary.failed += 1' "$tmp/seed-set.result.json" > "$tmp/flipped.json"
expect_error flipped-verdict E_RELATION "$root/evals/v1/seed-set.json" "$tmp/flipped.json"
"$jq_bin" -S -c '.body.evaluator.sha256 = ("e" * 64) |
  .body.trace |= map(.identity.evaluator_ref.sha256 = ("e" * 64))' "$tmp/seed-set.result.json" \
  > "$tmp/claimed-evaluator.json"
expect_error claimed-evaluator-digest E_RELATION "$root/evals/v1/seed-set.json" "$tmp/claimed-evaluator.json"
expect_error mismatched-pair E_RELATION "$root/evals/v1/seed-set-events.json" "$tmp/seed-set.result.json"
expect_error duplicate-result E_RUNTIME "$root/evals/v1/seed-set.json" "$tmp/seed-set.result.json" \
  "$root/evals/v1/seed-set.json" "$tmp/seed-set.result.json"
"$jq_bin" . "$tmp/seed-set.result.json" > "$tmp/pretty.json"
expect_error non-canonical-result E_CANONICAL "$root/evals/v1/seed-set.json" "$tmp/pretty.json"
/usr/bin/printf '%s  \n' "$(<"$tmp/seed-set.result.json")" > "$tmp/trailing-space.json"
expect_error trailing-whitespace-result E_CANONICAL "$root/evals/v1/seed-set.json" "$tmp/trailing-space.json"
/usr/bin/printf '%s' "$(<"$tmp/seed-set.result.json")" > "$tmp/no-newline.json"
expect_error missing-final-newline-result E_CANONICAL "$root/evals/v1/seed-set.json" "$tmp/no-newline.json"
/usr/bin/printf '{"kind":"eval_run_result"' > "$tmp/truncated.json"
expect_error truncated-result E_PARSE "$root/evals/v1/seed-set.json" "$tmp/truncated.json"
if "$framework" dashboard "$observed_at" "$root/evals/v1/seed-set.json" >"$tmp/odd.out" 2>"$tmp/odd.err"; then
  fail 'an unpaired seed set was accepted'
fi
[ "$(<"$tmp/odd.err")" = E_USAGE ] || fail 'unpaired arguments are a usage error'
pass 'a flipped verdict, a claimed evaluator digest, a mismatched pair, a duplicate, a non-canonical, whitespace-padded, or truncated result, and odd arguments fail closed'

/usr/bin/printf '1..%s\n' "$passes"
