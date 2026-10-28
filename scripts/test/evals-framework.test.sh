#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P) || exit 1
framework="$root/evals/v1/run-evals.sh"
launcher="$root/evals/v1/evals-launcher.sh"
driver="$root/evals/v1/evals-driver.sh"
program="$root/evals/v1/evals.jq"
catalog="$root/evals/v1/eval-catalog.json"
seed_set="$root/evals/v1/seed-set.json"
manifest="$root/ci/required-files.txt"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-evals-test.XXXXXX") || exit 1
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

# --- shipped files: present, regular, canonical, mode -----------------------
for shipped in "$framework" "$launcher" "$driver" "$program" "$catalog" "$seed_set"; do
  [ -f "$shipped" ] && [ ! -L "$shipped" ] || fail "missing shipped file $shipped"
done
for json in "$catalog" "$seed_set"; do
  "$jq_bin" -S -c . "$json" > "$tmp/canonical.json" || fail 'shipped json parse'
  /usr/bin/cmp -s "$json" "$tmp/canonical.json" || fail "shipped json not canonical: $json"
done
pass 'shipped documents are canonical single-root json'

for path in evals/v1/run-evals.sh evals/v1/evals-launcher.sh evals/v1/evals-driver.sh \
  evals/v1/evals.jq evals/v1/eval-catalog.json evals/v1/seed-set.json \
  scripts/test/evals-framework.test.sh; do
  /usr/bin/grep -qxF "$path" "$manifest" || fail "manifest missing $path"
done
pass 'restore manifest lists every framework path'

program_sha=$(sha_file "$program")
catalog_sha=$(sha_file "$catalog")
driver_sha=$(sha_file "$driver")
/usr/bin/grep -qF "program_sha=$program_sha" "$launcher" || fail 'launcher pins program digest'
/usr/bin/grep -qF "catalog_sha=$catalog_sha" "$launcher" || fail 'launcher pins catalog digest'
/usr/bin/grep -qF "driver_sha=$driver_sha" "$launcher" || fail 'launcher pins driver digest'
/usr/bin/grep -qF "program_sha256=$program_sha" "$driver" || fail 'driver pins program digest'
/usr/bin/grep -qF "verify_hash $catalog_sha" "$driver" || fail 'driver pins catalog digest'
pass 'launcher and driver pin the exact shipped program, catalog, and driver'

# --- catalog contract --------------------------------------------------------
"$jq_bin" -e '
  .kind == "eval_catalog" and .body.activation_state == "inactive" and
  .body.fail_mode == "closed" and (.body.families | length) == 9 and
  ([.body.families[] | select(.seed_status == "seeded")] | length) == 7 and
  ([.body.families[] | select(.seed_status == "declared")] | length) == 2 and
  all(.body.families[]; .seed_status == "seeded" and (.seed_sources | length) >= 1 or
      .seed_status == "declared" and .seed_sources == []) and
  all(.body.families[] | select((.grader_kinds | index("deterministic")) == null);
      .trial_policy.kind == "multi")
' "$catalog" > /dev/null || fail 'catalog shape'
pass 'catalog names all nine roadmap families, seven seeded, stochastic ones multi-trial'

# --- the run on the committed seed set ---------------------------------------
observed_at=2026-09-05T00:00:00Z
run_framework() {
  local out=$1 err=$2 seed=$3
  "$framework" run "$seed" "$observed_at" >"$out" 2>"$err"
}
first="$tmp/first.json"
run_framework "$first" "$tmp/first.err" "$seed_set" || fail "framework run failed: $(<"$tmp/first.err")"
[ ! -s "$tmp/first.err" ] || fail 'framework wrote to stderr on success'
"$jq_bin" -e --arg seed_sha "$(sha_file "$seed_set")" --arg catalog_sha "$catalog_sha" '
  .schema_version == 1 and .kind == "eval_run_result" and
  .body.activation_state == "inactive" and .body.authority_effect == "none" and
  .body.mode == "deterministic-offline" and
  .body.catalog_ref.sha256 == $catalog_sha and .body.seed_set_ref.sha256 == $seed_sha and
  .body.summary == {total:8,passed:8,failed:0,inconclusive:0} and
  (.body.cases | length) == 8 and all(.body.cases[]; .verdict == "passed") and
  (.body.trace | length) == 8 and
  all(.body.trace[]; .adapter == {state:"absent"} and .gate == {state:"absent"} and
      .latency == {state:"absent"} and .cost == {state:"absent"}) and
  (.body.evaluator.content.body.core_closure | length) == 9 and
  ([.body.cases[] | select(.expectation.disposition == "rejected")] | length) == 4 and
  ([.body.cases[] | select(.expectation.disposition == "accepted")] | length) == 4
' "$first" > /dev/null || fail 'run result shape or verdicts'
pass 'all eight seed cases pass through the real core with the expected disposition'

"$jq_bin" -e '
  ([.body.cases[] | select(.family_id == "stale-moved-artifacts")] | length) == 4 and
  ([.body.cases[] | select(.family_id == "empty-fake-timed-out-degraded-reviews")] | length) == 4 and
  (.body.cases[] | select(.case_id == "stale.moved-request-ref-rejected") |
    .observation.value.error_token.value == "E_REF") and
  (.body.cases[] | select(.case_id == "review.fake-inconclusive-pass-rejected") |
    .observation.value.error_token.value == "E_RELATION") and
  (.body.cases[] | select(.case_id == "review.missing-independent-review-rejected") |
    .observation.value.error_token.value == "E_RELATION")
' "$first" > /dev/null || fail 'family coverage or rejection tokens'
pass 'moved artifacts reject with E_REF; fake and degraded reviews reject with E_RELATION'

second="$tmp/second.json"
run_framework "$second" "$tmp/second.err" "$seed_set" || fail 'second run failed'
/usr/bin/cmp -s "$first" "$second" || fail 'repeat run differs'
[ "$("$jq_bin" -S -c . "$first")" = "$(<"$first")" ] || fail 'output not canonical'
pass 'repeat run is byte-identical and canonical'

"$jq_bin" -e '
  ([.. | objects | keys[] | select(. == "authority" or . == "permissions" or
    . == "capabilities" or . == "credential" or . == "network" or . == "execute" or
    . == "schedule" or . == "merge" or . == "publish")] | length) == 0
' "$first" > /dev/null || fail 'authority or effect field present'
pass 'inactive data-only boundary: no authority, permission, or effect fields'

# --- grading is honest: a wrong expectation fails, an undecidable family stays inconclusive
wrong="$tmp/wrong-expectation.json"
"$jq_bin" -S -c '
  .body.cases |= map(if .case_id == "stale.status-accepted"
    then .expectation.status = "completed" else . end)
' "$seed_set" > "$wrong"
run_framework "$tmp/wrong.json" "$tmp/wrong.err" "$wrong" || fail 'wrong-expectation run errored'
"$jq_bin" -e '
  .body.summary == {total:8,passed:7,failed:1,inconclusive:0} and
  (.body.cases[] | select(.case_id == "stale.status-accepted") |
    .verdict == "failed" and .reason_id == "evals.status-mismatch")
' "$tmp/wrong.json" > /dev/null || fail 'wrong expectation was not failed'
pass 'a wrong expectation is graded failed, never silently passed'

generation=$(/usr/bin/grep -oE '^generation=g-[0-9a-f]{64}$' "$launcher" | /usr/bin/cut -d= -f2)
[ -n "$generation" ] || fail 'launcher names one core generation'
modules="$root/core/v2/generations/$generation/modules"
[ -d "$modules" ] || fail "core generation modules missing: $generation"

stochastic="$tmp/stochastic.json"
"$jq_bin" -S -c '
  .body.cases |= map(if .case_id == "stale.completed-baseline"
    then .family_id = "reviewer-severity-false-positive-negative" else . end)
' "$seed_set" > "$stochastic"
# The shipped catalog does not seed that family from core stage runs, so the
# launcher refuses the misfiled set before anything runs.
if "$framework" run "$stochastic" "$observed_at" >"$tmp/misfiled.out" 2>"$tmp/misfiled.err"; then
  fail 'seed set filed under an unseeded family was accepted'
fi
[ ! -s "$tmp/misfiled.out" ] && [ "$(<"$tmp/misfiled.err")" = E_SHAPE ] ||
  fail "misfiled seed set was not refused: [$(<"$tmp/misfiled.err")]"
# With a catalog that does draw that model-only family from stage runs, the
# program grades the case inconclusive: no deterministic grader, nothing guessed.
model_only_catalog="$tmp/model-only-catalog.json"
"$jq_bin" -S -c '
  .body.families |= map(if .family_id == "reviewer-severity-false-positive-negative"
    then .seed_status = "seeded" | .seed_sources = ["core.stage-run.v2"] else . end)
' "$catalog" > "$model_only_catalog"
model_only_catalog_sha=$(sha_file "$model_only_catalog")
"$jq_bin" -S -c --arg sha "$model_only_catalog_sha" \
  '.body.evaluator.content | .body.catalog_ref.sha256 = $sha' "$first" > "$tmp/stochastic-evaluator.json"
"$jq_bin" -S -c '[.body.cases[].observation.value]' "$first" > "$tmp/stochastic-observations.json"
"$jq_bin" -S -c -n -L "$modules" \
  --arg evals_operation build-run-result \
  --arg program_sha256 "$program_sha" --arg driver_sha256 "$driver_sha" \
  --arg catalog_sha256 "$model_only_catalog_sha" \
  --arg evaluator_sha256 "$(sha_file "$tmp/stochastic-evaluator.json")" \
  --arg seed_set_sha256 "$(sha_file "$stochastic")" \
  --arg tool_sha256 b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 \
  --arg scanner_sha256 "$(sha_file "$root/orchestrator/v1/scan-state.sh")" \
  --arg planner_sha256 "$(sha_file "$root/orchestrator/v1/reconciliation-plan.jq")" \
  --arg sandbox_sha256 "$(sha_file "$root/control/v1/evaluate-sandbox.sh")" \
  --argjson normalizer_shas "$("$jq_bin" -n --arg r "$(sha_file "$root/adapters/codex-native-reviewer/v1/normalize.jq")" --arg c "$(sha_file "$root/adapters/github-actions-ci/v1/normalize.jq")" --arg f "$(sha_file "$root/adapters/github-forge/v1/normalize.jq")" --arg g "$(sha_file "$root/adapters/gitlab-forge/v1/normalize.jq")" --arg p "$(sha_file "$root/adapters/codex-cli-producer/v1/normalize.jq")" '{"codex-cli-producer":$p,"codex-native-reviewer":$r,"github-actions-ci":$c,"github-forge":$f,"gitlab-forge":$g}')" \
  --arg risk_gates_sha256 "$(sha_file "$root/control/v1/evaluate-risk-gates.sh")" \
  --arg duty_sha256 "$(sha_file "$root/control/v1/evaluate-duty.sh")" \
  --slurpfile result_docs "$tmp/stochastic-observations.json" --argjson result_shas '[]' \
  --arg observed_at "$observed_at" \
  --slurpfile catalog_docs "$model_only_catalog" --slurpfile seed_set_docs "$stochastic" \
  --slurpfile observation_docs "$tmp/stochastic-observations.json" \
  --slurpfile evaluator_docs "$tmp/stochastic-evaluator.json" \
  --slurpfile candidate_docs "$tmp/stochastic-observations.json" \
  -f "$program" > "$tmp/stochastic.out" 2>"$tmp/stochastic.err" ||
  fail "stochastic build errored: $(<"$tmp/stochastic.err")"
"$jq_bin" -e '
  .body.summary == {total:8,passed:7,failed:0,inconclusive:1} and
  (.body.cases[] | select(.case_id == "stale.completed-baseline") |
    .verdict == "inconclusive" and .grader_kind == "none" and
    .reason_id == "evals.no-deterministic-grader") and
  (.body.trace[] | select(.case_id == "stale.completed-baseline") | .grader_kind == "none") and
  ([.body.trace[] | select(.grader_kind == "deterministic")] | length) == 7
' "$tmp/stochastic.out" > /dev/null || fail 'model-only family was decided deterministically'
pass 'a misfiled family is refused; a seeded model-only family stays inconclusive in case and trace'

# A run result built from a partial observation set marks the unobserved case
# inconclusive in the program; the dashboard, which replays every case, refuses it.
"$jq_bin" -S -c '.body.evaluator.content' "$first" > "$tmp/partial-evaluator.json"
"$jq_bin" -S -c '[.body.cases[1:][].observation.value]' "$first" > "$tmp/partial-observations.json"
"$jq_bin" -S -c -n -L "$modules" \
  --arg evals_operation build-run-result \
  --arg program_sha256 "$program_sha" --arg driver_sha256 "$driver_sha" \
  --arg catalog_sha256 "$catalog_sha" \
  --arg evaluator_sha256 "$(sha_file "$tmp/partial-evaluator.json")" \
  --arg seed_set_sha256 "$(sha_file "$seed_set")" \
  --arg tool_sha256 b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 \
  --arg scanner_sha256 "$(sha_file "$root/orchestrator/v1/scan-state.sh")" \
  --arg planner_sha256 "$(sha_file "$root/orchestrator/v1/reconciliation-plan.jq")" \
  --arg sandbox_sha256 "$(sha_file "$root/control/v1/evaluate-sandbox.sh")" \
  --argjson normalizer_shas "$("$jq_bin" -n --arg r "$(sha_file "$root/adapters/codex-native-reviewer/v1/normalize.jq")" --arg c "$(sha_file "$root/adapters/github-actions-ci/v1/normalize.jq")" --arg f "$(sha_file "$root/adapters/github-forge/v1/normalize.jq")" --arg g "$(sha_file "$root/adapters/gitlab-forge/v1/normalize.jq")" --arg p "$(sha_file "$root/adapters/codex-cli-producer/v1/normalize.jq")" '{"codex-cli-producer":$p,"codex-native-reviewer":$r,"github-actions-ci":$c,"github-forge":$f,"gitlab-forge":$g}')" \
  --arg risk_gates_sha256 "$(sha_file "$root/control/v1/evaluate-risk-gates.sh")" \
  --arg duty_sha256 "$(sha_file "$root/control/v1/evaluate-duty.sh")" \
  --slurpfile result_docs "$tmp/partial-observations.json" --argjson result_shas '[]' \
  --arg observed_at "$observed_at" \
  --slurpfile catalog_docs "$catalog" --slurpfile seed_set_docs "$seed_set" \
  --slurpfile observation_docs "$tmp/partial-observations.json" \
  --slurpfile evaluator_docs "$tmp/partial-evaluator.json" \
  --slurpfile candidate_docs "$tmp/partial-observations.json" \
  -f "$program" > "$tmp/partial.out" 2>"$tmp/partial.err" ||
  fail "partial build errored: $(<"$tmp/partial.err")"
"$jq_bin" -e '.body.summary == {total:8,passed:7,failed:0,inconclusive:1} and
  (.body.cases[0].observation == {state:"absent"})' "$tmp/partial.out" > /dev/null ||
  fail 'partial observation set did not yield one inconclusive case'
# The dashboard replays the seed set and observes every case, so a result with
# an unobserved case cannot be reproduced and does not count.
if "$framework" dashboard "$observed_at" "$seed_set" "$tmp/partial.out" > "$tmp/partial-dashboard.json" \
  2>"$tmp/partial-dashboard.err"; then
  fail 'dashboard counted a result its replay cannot reproduce'
fi
[ "$(<"$tmp/partial-dashboard.err")" = E_RELATION ] || fail 'partial result was not refused as E_RELATION'
pass 'a partially observed result is inconclusive in the program and refused by the dashboard replay'

# --- fail closed on bad or moved input ----------------------------------------
expect_error() {
  local name=$1 expected=$2 seed=$3 out err status
  out="$tmp/$name.out"; err="$tmp/$name.err"
  "$framework" run "$seed" "$observed_at" >"$out" 2>"$err"
  status=$?
  [ "$status" -ne 0 ] && [ ! -s "$out" ] && [ "$(<"$err")" = "$expected" ] ||
    fail "$name expected $expected, got status $status [$(<"$err")]"
}
/usr/bin/printf '{"kind":"eval_seed_set"' > "$tmp/truncated.json"
expect_error truncated-input E_PARSE "$tmp/truncated.json"
"$jq_bin" -S -c '.body.cases[0].result.sha256 = ("f" * 64)' "$seed_set" > "$tmp/moved.json"
expect_error moved-result-digest E_RELATION "$tmp/moved.json"
"$jq_bin" -S -c '.body.cases[0].request_role = "operator"' "$seed_set" > "$tmp/badrole.json"
expect_error unknown-request-role E_SHAPE "$tmp/badrole.json"
"$jq_bin" -S -c 'del(.body.cases[0].expectation)' "$seed_set" > "$tmp/noexp.json"
expect_error missing-expectation E_SHAPE "$tmp/noexp.json"
pass 'malformed, moved, and mis-shaped seed sets fail closed with one token'

# A seed id must leave room for the "evals.run." prefix inside the id limit,
# otherwise the run result would be built and then refused as mis-shaped.
long_id=$(/usr/bin/printf 'seed.%0117d' 0)
"$jq_bin" -S -c --arg id "$long_id" '.id = $id' "$seed_set" > "$tmp/longid.json"
[ "${#long_id}" -eq 122 ] || fail 'long id fixture'
expect_error long-seed-id E_SHAPE "$tmp/longid.json"
fit_id=$(/usr/bin/printf 'seed.%0113d' 0)
"$jq_bin" -S -c --arg id "$fit_id" '.id = $id' "$seed_set" > "$tmp/fitid.json"
run_framework "$tmp/fitid.out" "$tmp/fitid.err" "$tmp/fitid.json" || fail 'longest fitting seed id errored'
[ "$("$jq_bin" -r .id "$tmp/fitid.out")" = "evals.run.$fit_id" ] || fail 'run id prefix'
pass 'a seed id too long to prefix is refused before any case runs'

# validate-run-result binds every ref to the exact catalog, evaluator, and seed
# set it was handed, not merely to well-formed digests.
"$jq_bin" -S -c '.body.evaluator.content' "$first" > "$tmp/evaluator.json"
"$jq_bin" -S -c '[.body.cases[].observation.value]' "$first" > "$tmp/observations.json"
validate_result() {
  "$jq_bin" -S -c -n -L "$modules" \
    --arg evals_operation validate-run-result \
    --arg program_sha256 "$program_sha" --arg driver_sha256 "$driver_sha" \
    --arg catalog_sha256 "$catalog_sha" \
    --arg evaluator_sha256 "$("$jq_bin" -r .body.evaluator.sha256 "$1")" \
    --arg seed_set_sha256 "$(sha_file "$seed_set")" \
    --arg tool_sha256 b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 \
    --arg scanner_sha256 "$(sha_file "$root/orchestrator/v1/scan-state.sh")" \
    --arg planner_sha256 "$(sha_file "$root/orchestrator/v1/reconciliation-plan.jq")" \
    --arg sandbox_sha256 "$(sha_file "$root/control/v1/evaluate-sandbox.sh")" \
    --argjson normalizer_shas "$("$jq_bin" -n --arg r "$(sha_file "$root/adapters/codex-native-reviewer/v1/normalize.jq")" --arg c "$(sha_file "$root/adapters/github-actions-ci/v1/normalize.jq")" --arg f "$(sha_file "$root/adapters/github-forge/v1/normalize.jq")" --arg g "$(sha_file "$root/adapters/gitlab-forge/v1/normalize.jq")" --arg p "$(sha_file "$root/adapters/codex-cli-producer/v1/normalize.jq")" '{"codex-cli-producer":$p,"codex-native-reviewer":$r,"github-actions-ci":$c,"github-forge":$f,"gitlab-forge":$g}')" \
    --arg risk_gates_sha256 "$(sha_file "$root/control/v1/evaluate-risk-gates.sh")" \
    --arg duty_sha256 "$(sha_file "$root/control/v1/evaluate-duty.sh")" \
    --slurpfile result_docs "$tmp/observations.json" --argjson result_shas '[]' \
    --arg observed_at "$observed_at" \
    --slurpfile catalog_docs "$catalog" --slurpfile seed_set_docs "$seed_set" \
    --slurpfile observation_docs "$tmp/observations.json" \
    --slurpfile evaluator_docs "$tmp/evaluator.json" \
    --slurpfile candidate_docs "$1" -f "$program" 2>/dev/null
}
[ "$(validate_result "$first")" = true ] || fail 'shipped run result does not validate'
for mutation in '.body.catalog_ref.sha256 = ("a" * 64)' \
  '.body.seed_set_ref.sha256 = ("a" * 64)' \
  '.body.evaluator.sha256 = ("a" * 64)' \
  '.body.seed_set_ref.id = "other.seed" | .id = "evals.run.other.seed"' \
  '.body.cases[0].verdict = "failed" | .body.cases[0].reason_id = "evals.status-mismatch" |
   .body.summary.passed -= 1 | .body.summary.failed += 1' \
  '.body.trace |= (.[0:1] + .[2:] + .[1:2])' \
  '.body.cases[0].observation.value.status.value = "skipped"'; do
  "$jq_bin" -S -c "$mutation" "$first" > "$tmp/rebound.json"
  [ "$(validate_result "$tmp/rebound.json")" = false ] ||
    fail "run result with moved ref or altered derivation accepted: $mutation"
done
# An archived result may not claim a program, driver, or catalog that never ran,
# even when the embedded evaluator's own digest is recomputed to match.
for closure_filter in 'del(.body.evaluator.content.body.record_closure)' \
  '.body.evaluator.content.body.record_closure += [.body.evaluator.content.body.record_closure[0]]' \
  '.body.evaluator.content.body.record_closure[0].sha256=("e"*64)' \
  '.body.evaluator.content.body.record_closure[0].extra=true'; do
  "$jq_bin" -S -c "$closure_filter" "$first" >"$tmp/review-bad-closure.json"
  "$jq_bin" -S -c '.body.evaluator.content' "$tmp/review-bad-closure.json" >"$tmp/evaluator.json"
  closure_sha=$(sha_file "$tmp/evaluator.json")
  "$jq_bin" -S -c --arg sha "$closure_sha" '.body.evaluator.sha256=$sha' \
    "$tmp/review-bad-closure.json" >"$tmp/review-rebound-closure.json"
  [ "$(validate_result "$tmp/review-rebound-closure.json")" = false ] || fail 'record closure contract'
done
"$jq_bin" -S -c '.body.evaluator.content' "$first" >"$tmp/evaluator.json"
pass 'the exact record closure remains required after rebinding its evaluator digest'
for ref in program_ref driver_ref catalog_ref; do
  "$jq_bin" -S -c --arg ref "$ref" '.body.evaluator.content.body[$ref].sha256 = ("b" * 64)' \
    "$first" > "$tmp/rebound.json"
  evaluator_sha=$("$jq_bin" -S -c '.body.evaluator.content' "$tmp/rebound.json" |
    /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
  "$jq_bin" -S -c --arg sha "$evaluator_sha" '.body.evaluator.sha256 = $sha' \
    "$tmp/rebound.json" > "$tmp/rebound-evaluator.json"
  "$jq_bin" -S -c '.body.evaluator.content' "$tmp/rebound-evaluator.json" > "$tmp/evaluator.json"
  [ "$(validate_result "$tmp/rebound-evaluator.json")" = false ] ||
    fail "evaluator claiming an unshipped $ref was accepted"
done
"$jq_bin" -S -c '.body.evaluator.content' "$first" > "$tmp/evaluator.json"
"$jq_bin" -S -c '.body.evaluator.sha256 = ("c" * 64)' "$first" > "$tmp/rebound.json"
[ "$(validate_result "$tmp/rebound.json")" = false ] ||
  fail 'run result with a moved evaluator digest accepted'
pass 'a run result must be exactly what the program derives from its bound inputs'

if "$framework" run "$seed_set" "not-a-time" >"$tmp/badtime.out" 2>"$tmp/badtime.err"; then
  fail 'observed_at is not validated'
fi
[ "$(<"$tmp/badtime.err")" = E_USAGE ] || fail 'observed_at is not validated'
pass 'observed_at must be an exact UTC timestamp'

# --- the launcher refuses a stale (edited) program -----------------------------
copy="$tmp/copy"
/bin/mkdir -p "$copy/evals/v1" "$copy/core/v2" "$copy/scripts"
/bin/cp -R "$root/core/v2/." "$copy/core/v2/"
/bin/cp "$root/scripts/core-contract.sh" "$copy/scripts/core-contract.sh"
# Every component the launcher stages must be present, so the only stale thing
# in this fixture is the edit below.
for component in orchestrator/v1 control/v1 adapters; do
  if [ -d "$root/$component" ]; then
    /bin/mkdir -p "$copy/$component" && /bin/cp -R "$root/$component/." "$copy/$component/"
  fi
done
for f in run-evals.sh evals-launcher.sh evals-driver.sh evals.jq eval-catalog.json seed-set.json framework.jq run.sh; do
  /bin/cp "$root/evals/v1/$f" "$copy/evals/v1/$f"
done
/usr/bin/printf '\n# tampered\n' >> "$copy/evals/v1/evals.jq"
if "$copy/evals/v1/run-evals.sh" run "$seed_set" "$observed_at" >"$tmp/stale.out" 2>"$tmp/stale.err"; then
  fail 'edited program was accepted'
fi
[ ! -s "$tmp/stale.out" ] && [ "$(<"$tmp/stale.err")" = E_STALE ] ||
  fail "edited program was not refused: [$(<"$tmp/stale.err")]"
pass 'an edited program is refused as stale before anything runs'

[ "$(sha_file "$root/core/v2/generation-registry.json")" = \
  3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94 ] || fail 'record registry pin'
record_generation=$("$jq_bin" -er '
  if type == "array" and length >= 1 and all(.[]; .semantic_identity == "core.contracts.v2" and
    (.generation_id | type == "string" and test("\\Ag-[0-9a-f]{64}\\z")))
  then .[-1].generation_id else error("E_STALE") end
' "$root/core/v2/generation-registry.json") || fail 'record registry grammar'
record_schema="core/v2/generations/$record_generation/modules/schema.jq"
"$jq_bin" -e --arg path "$record_schema" '
  [.body.evaluator.content.body.core_closure[] | select(.path == $path)] ==
  [{path:$path,sha256:"8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade"}] and
  .body.evaluator.content.body.record_closure ==
  [{path:$path,sha256:"8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade"},
   {path:"evals/v1/framework.jq",sha256:"d164a102919f42ef002e93c8b515b58028604819e6c09b87c6e4afadb0bbcce4"},
   {path:"evals/v1/run.sh",sha256:"51770c5597d55bf05020502796810637bfbe697038a541ea6124530c0fffe55c"}]
' "$first" >/dev/null || fail 'record closure follows registry and core schema'
[ "$(sha_file "$root/$record_schema")" = \
  8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade ] || fail 'record schema bytes'
review_wrap() {
  local digest
  digest=$(sha_file "$1") || fail 'review wrapper digest'
  "$jq_bin" -S -c -n --arg sha "$digest" --slurpfile value "$1" '
    {ref:{content_id:$value[0].id,media_type:"application/vnd.ystack.eval-record+json",sha256:$sha},
     value:$value[0]}' >"$2" || fail 'review wrapper'
}
review_rehash() {
  local source=$1 target=$2 section index count digest
  /bin/cp "$source" "$tmp/review-rehash.json" || fail 'review rehash copy'
  for section in suite cases trials grades; do
    if [ "$section" = suite ]; then count=1
    else count=$("$jq_bin" -r --arg s "$section" '.body[$s]|length' "$tmp/review-rehash.json"); fi
    index=0
    while [ "$index" -lt "$count" ]; do
      "$jq_bin" -S -c --arg s "$section" --argjson i "$index" '
        if $s == "suite" then .body.suite.value else .body[$s][$i].value end
      ' "$tmp/review-rehash.json" >"$tmp/review-value.json" || fail 'review rehash value'
      digest=$(sha_file "$tmp/review-value.json") || fail 'review rehash digest'
      "$jq_bin" -S -c --arg s "$section" --argjson i "$index" --arg sha "$digest" '
        if $s == "suite" then .body.suite.ref.sha256 = $sha
        else .body[$s][$i].ref.sha256 = $sha end
      ' "$tmp/review-rehash.json" >"$tmp/review-next.json" || fail 'review rehash wrapper'
      if [ "$section" = suite ]; then
        "$jq_bin" -S -c '.body.suite.ref as $r | .body.cases |= map(.value.body.suite_ref = $r)' \
          "$tmp/review-next.json" >"$tmp/review-rehash.json" || fail 'review suite refs'
      elif [ "$section" = cases ]; then
        "$jq_bin" -S -c --argjson i "$index" '.body.cases[$i].ref as $r |
          .body.trials |= map(.value.body.case_ref = $r)' "$tmp/review-next.json" \
          >"$tmp/review-rehash.json" || fail 'review case refs'
      elif [ "$section" = trials ]; then
        "$jq_bin" -S -c --argjson i "$index" '.body.trials[$i].ref as $r |
          .body.grades |= map(if .value.body.trial_ref.content_id == $r.content_id
            then .value.body.trial_ref = $r else . end)' "$tmp/review-next.json" \
          >"$tmp/review-rehash.json" || fail 'review trial refs'
      else /bin/mv "$tmp/review-next.json" "$tmp/review-rehash.json" || fail 'review grade refs'; fi
      index=$((index + 1))
    done
  done
  /bin/cp "$tmp/review-rehash.json" "$target" || fail 'review rehash result'
}
review_seed_from() {
  local repo=$1 bundle=$2 labels=$3 target=$4
  "$jq_bin" -S -c -n --slurpfile bundle "$bundle" --slurpfile labels "$labels" \
    --arg bundle_sha "$(sha_file "$bundle")" --arg labels_sha "$(sha_file "$labels")" \
    --slurpfile catalog "$catalog" '
    {schema_version:1,kind:"eval_seed_set",id:"evals.seed.reviews.fixture",
     body:{core_contract:$catalog[0].body.core_contract,seed_source:"reviews.independent-verdicts.v1",
       shared:{bundle:{content:$bundle[0],sha256:$bundle_sha},labels:{content:$labels[0],sha256:$labels_sha},
         files:[$labels[0].body.trials[] | {path:("evals/v1/seeds/reviewer-severity/verdicts/" + .comment_id + ".md"),
           sha256:.verdict_sha256}]},
       cases:[$labels[0].body.trials[] | {case_id:("review." + .comment_id),
         family_id:"reviewer-severity-false-positive-negative",
         expectation:{disposition:"human-graded",status:"passed"},
         verdict:{comment_id:.comment_id,path:("evals/v1/seeds/reviewer-severity/verdicts/" + .comment_id + ".md"),
           sha256:.verdict_sha256}}]}}' >"$target" || fail "review seed $repo"
}
review_substitute() {
  local source=$1 target=$2 before=$3 after=$4 count=$5
  "$jq_bin" -R -s -j --arg before "$before" --arg after "$after" --argjson count "$count" '
    if (split($before) | length) == ($count + 1) then split($before) | join($after)
    else error("unexpected substitution count") end
  ' "$source" >"$target.next" || fail 'private fixture substitution count'
  /bin/mv "$target.next" "$target" || fail 'private fixture substitution'
}
review_fixture() {
  local name=$1 n=$2 failed=$3 repo="$tmp/review-$1" dir i id status
  /bin/mkdir -p "$repo/evals/v1/seeds/reviewer-severity/verdicts" "$repo/core/v2" "$repo/scripts" || fail 'review fixture dirs'
  /bin/cp -R "$root/evals/v1/." "$repo/evals/v1/" || fail 'review entry copy'
  /bin/cp -R "$root/core/v2/." "$repo/core/v2/" || fail 'review core copy'
  /bin/cp "$root/scripts/core-contract.sh" "$repo/scripts/core-contract.sh" || fail 'review front door copy'
  for dir in orchestrator control adapters; do /bin/cp -R "$root/$dir" "$repo/$dir" || fail 'review closure copy'; done
  dir="$repo/evals/v1/seeds/reviewer-severity"
  : >"$repo/labels.jsonl"
  i=1
  while [ "$i" -le "$n" ]; do
    id=$((1000 + i)); status=passed
    if [ "$i" -eq "$failed" ]; then status=failed; fi
    /usr/bin/printf 'Fixture verdict %s\n' "$id" >"$dir/verdicts/$id.md"
    "$jq_bin" -S -c -n --arg id "$id" --arg status "$status" --arg sha "$(sha_file "$dir/verdicts/$id.md")" '
      {comment_id:$id,verdict_sha256:$sha,
       findings:[{index:1,tag:"P0",label:"important"},{index:2,tag:"P1",label:"nit"},
         {index:3,tag:"P2",label:"not-a-defect"},{index:4,tag:"P3",label:"nit"}],
       missed_important:(if $status == "failed" then
         [{summary:"Fixture missed finding",evidence_link:"https://example.invalid/fixture"}] else [] end),
       grade_status:$status}
    ' >>"$repo/labels.jsonl" || fail 'fixture label'
    i=$((i + 1))
  done
  "$jq_bin" -S -c -s '{schema_version:1,kind:"eval_labels",id:"evals.reviewer-severity.labels.v1",body:{trials:.}}' \
    "$repo/labels.jsonl" >"$repo/labels.json" || fail 'fixture labels'
  "$jq_bin" -S -c -n --arg sha "$(sha_file "$repo/labels.json")" --slurpfile labels "$repo/labels.json" '
    {schema_version:1,kind:"eval_label_approval",id:"evals.reviewer-severity.approval.v1",body:{
      family_id:"reviewer-severity-false-positive-negative",labels_sha256:$sha,
      selected_comment_ids:[$labels[0].body.trials[].comment_id],decision_request_id:"FIXTURE-ONLY",
      request_comment_id:"9001",approval_comment_id:"9002",approval_comment_url:"https://example.invalid/fixture",
      approver:"yihanzhu",approved_at:"2026-09-05T00:00:00Z"}}
  ' >"$dir/approval.json" || fail 'fixture approval'
  "$jq_bin" -S -c -n --arg framework "$(sha_file "$root/evals/v1/framework.jq")" '
    def ref($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
    {schema_version:1,kind:"eval_suite",id:"suite.review-fixture",body:{suite_version:"v1",
      framework_ref:ref("eval-framework.v1";"application/vnd.ystack.eval-framework+jq";$framework),
      scope:{scope_id:"scope.fixture",scope_version:"v1",scope_sha256:("a"*64),
        definition_ref:ref("fixture-scope";"application/json";("a"*64))},case_ids:["case.reviews"]}}
  ' >"$repo/suite.value" || fail 'fixture suite'
  review_wrap "$repo/suite.value" "$repo/suite.wrap"
  "$jq_bin" -S -c -n --argjson n "$n" --arg labels_sha "$(sha_file "$repo/labels.json")" \
    --slurpfile suite "$repo/suite.wrap" '
    {schema_version:1,kind:"eval_case",id:"case.reviews",body:{case_version:"v1",
     suite_ref:$suite[0].ref,execution_kind:"model",
     input_ref:{content_id:"fixture-input",media_type:"text/markdown",sha256:("b"*64)},
     expected_ref:{content_id:"evals.reviewer-severity.labels.v1",media_type:"application/vnd.ystack.eval-labels+json",sha256:$labels_sha},
     trial_count:$n,trial_ids:[range(1;$n+1)|"trial." + ((1000+.)|tostring)],
     attempt_ids:[range(1;$n+1)|"review." + ((1000+.)|tostring)],
     graders:[{grader_id:"grader.operator",grader_kind:"human",
       implementation_ref:{content_id:"evals.reviewer-severity.rubric.v1",media_type:"text/markdown",sha256:("c"*64)},
       instructions_ref:{content_id:"evals.reviewer-severity.rubric.v1",media_type:"text/markdown",sha256:("c"*64)}}]}}
  ' >"$repo/case.value" || fail 'fixture case'
  review_wrap "$repo/case.value" "$repo/case.wrap"
  : >"$repo/trials.jsonl"; : >"$repo/grades.jsonl"
  i=1
  while [ "$i" -le "$n" ]; do
    id=$((1000 + i))
    "$jq_bin" -S -c -n --arg id "$id" --argjson index "$i" --slurpfile case "$repo/case.wrap" \
      --arg sha "$(sha_file "$dir/verdicts/$id.md")" '
      {schema_version:1,kind:"eval_trial",id:("trial."+$id),body:{trial_version:"v1",
        case_ref:$case[0].ref,trial_index:$index,attempt_id:("review."+$id),
        started_at:"2026-09-01T00:00:00Z",finished_at:"2026-09-01T00:00:10Z",status:"completed",
        output_ref:{state:"present",value:{content_id:"review-verdict.v1",media_type:"text/markdown",sha256:$sha}},
        reason:{state:"absent"}}}' >"$repo/trial.value" || fail 'fixture trial'
    review_wrap "$repo/trial.value" "$repo/trial.wrap"
    /bin/cat "$repo/trial.wrap" >>"$repo/trials.jsonl"
    "$jq_bin" -S -c -n --arg id "$id" --slurpfile trial "$repo/trial.wrap" \
      --slurpfile labels "$repo/labels.json" --slurpfile case "$repo/case.wrap" '
      {schema_version:1,kind:"eval_grade",id:("grade."+$id),body:{grade_version:"v1",trial_ref:$trial[0].ref,
        grader_id:"grader.operator",grader_kind:"human",grader_ref:$case[0].value.body.graders[0].implementation_ref,
        graded_at:"2026-09-05T00:00:00Z",status:([$labels[0].body.trials[]|select(.comment_id==$id)][0].grade_status),
        evidence_ref:{state:"present",value:$case[0].value.body.expected_ref},reason:{state:"absent"}}}
    ' >"$repo/grade.value" || fail 'fixture grade'
    review_wrap "$repo/grade.value" "$repo/grade.wrap"
    /bin/cat "$repo/grade.wrap" >>"$repo/grades.jsonl"
    i=$((i + 1))
  done
  "$jq_bin" -S -c -s . "$repo/trials.jsonl" >"$repo/trials.json"
  "$jq_bin" -S -c -s . "$repo/grades.jsonl" >"$repo/grades.json"
  "$jq_bin" -S -c -n --slurpfile suite "$repo/suite.wrap" --slurpfile case "$repo/case.wrap" \
    --slurpfile trials "$repo/trials.json" --slurpfile grades "$repo/grades.json" '
    {schema_version:1,kind:"eval_bundle",id:"bundle.review-fixture",
      body:{suite:$suite[0],cases:$case,trials:$trials[0],grades:$grades[0]}}
  ' >"$repo/bundle.json" || fail 'fixture bundle'
  review_seed_from "$repo" "$repo/bundle.json" "$repo/labels.json" "$repo/seed.json"
  "$jq_bin" -S -c '.body.families |= map(if .family_id == "reviewer-severity-false-positive-negative" then
    .seed_status="seeded" | .seed_sources=["reviews.independent-verdicts.v1"] else . end)' "$catalog" \
    >"$repo/evals/v1/eval-catalog.json" || fail 'private seeded catalog'
  if [ "$name" = wrong-selection ]; then
    "$jq_bin" -S -c '.body.selected_comment_ids[4]="1999"' "$dir/approval.json" >"$repo/approval.next"
    /bin/mv "$repo/approval.next" "$dir/approval.json"
  elif [ "$name" = approval-shape ]; then
    "$jq_bin" -S -c '.body.extra=true' "$dir/approval.json" >"$repo/approval.next"
    /bin/mv "$repo/approval.next" "$dir/approval.json"
  fi
  local catalog_sha approval_sha private_driver_sha
  catalog_sha=$(sha_file "$repo/evals/v1/eval-catalog.json"); approval_sha=$(sha_file "$dir/approval.json")
  review_substitute "$repo/evals/v1/evals-driver.sh" "$repo/evals/v1/evals-driver.sh" \
    0239138447a8f9fd420cb3c5da31660d8f75c85099d80d89a040dce2878a4cac "$catalog_sha" 4
  review_substitute "$repo/evals/v1/evals-launcher.sh" "$repo/evals/v1/evals-launcher.sh" \
    0239138447a8f9fd420cb3c5da31660d8f75c85099d80d89a040dce2878a4cac "$catalog_sha" 1
  if [ "$name" != none ]; then
    review_substitute "$repo/evals/v1/evals-driver.sh" "$repo/evals/v1/evals-driver.sh" \
      review_approval_sha256=none "review_approval_sha256=$approval_sha" 1
    review_substitute "$repo/evals/v1/evals-launcher.sh" "$repo/evals/v1/evals-launcher.sh" \
      review_approval_sha=none "review_approval_sha=$approval_sha" 1
  fi
  private_driver_sha=$(sha_file "$repo/evals/v1/evals-driver.sh")
  review_substitute "$repo/evals/v1/evals-launcher.sh" "$repo/evals/v1/evals-launcher.sh" \
    "driver_sha=$driver_sha" "driver_sha=$private_driver_sha" 1
  for section in evals-driver.sh evals-launcher.sh; do
    /usr/bin/diff -u "$root/evals/v1/$section" "$repo/evals/v1/$section" >"$repo/$section.diff"
    status=$?; [ "$status" -eq 1 ] || fail 'private fixture must have exact literal diff'
    /bin/cat "$repo/$section.diff"
  done
  /usr/bin/grep -qxF "program_sha256=$program_sha" "$repo/evals/v1/evals-driver.sh" || fail 'fixture program pin'
  /usr/bin/grep -qxF "driver_sha=$private_driver_sha" "$repo/evals/v1/evals-launcher.sh" || fail 'fixture driver pin'
}
review_expect_error() {
  local name=$1 token=$2 repo=$3 seed=$4 status=0
  "$repo/evals/v1/run-evals.sh" run "$seed" "$observed_at" \
    >"$tmp/review-$name.out" 2>"$tmp/review-$name.err" || status=$?
  [ "$status" -ne 0 ] && [ ! -s "$tmp/review-$name.out" ] &&
    [ "$(<"$tmp/review-$name.err")" = "$token" ] ||
    fail "review $name: status$status [$(<"$tmp/review-$name.err")] expected $token"
  pass "review fixture $name refuses $token without output"
}
review_fixture five 5 0
review_fixture six 6 0
review_fixture four 4 0
review_fixture failed 5 1
review_fixture none 5 0
review_fixture wrong-selection 5 0
review_fixture approval-shape 5 0
review_expect_error shipped-declared E_SHAPE "$root" "$tmp/review-five/seed.json"
for record_variant in pretty multiple-roots; do
  if [ "$record_variant" = pretty ]; then
    "$jq_bin" . "$tmp/review-five/bundle.json" >"$tmp/review-record-invalid.json"; token=E_CANONICAL
  else
    /bin/cat "$tmp/review-five/bundle.json" "$tmp/review-five/bundle.json" >"$tmp/review-record-invalid.json"; token=E_PARSE
  fi
  status=0
  "$tmp/review-five/evals/v1/run.sh" evaluate "$tmp/review-record-invalid.json" \
    >"$tmp/review-record-$record_variant.out" 2>"$tmp/review-record-$record_variant.err" || status=$?
  [ "$status" -ne 0 ] && [ ! -s "$tmp/review-record-$record_variant.out" ] &&
    [ "$(<"$tmp/review-record-$record_variant.err")" = "$token" ] || fail "actual record $record_variant"
  pass "actual record evaluator refuses $record_variant with $token"
done
review_expect_error no-fixed-approval E_STALE "$tmp/review-none" "$tmp/review-none/seed.json"
review_expect_error below-minimum E_RELATION "$tmp/review-four" "$tmp/review-four/seed.json"
for review_name in five six failed; do
  review_repo="$tmp/review-$review_name"
  "$review_repo/evals/v1/run.sh" evaluate "$review_repo/bundle.json" >"$review_repo/record-report.json" || fail 'actual record evaluate'
  "$review_repo/evals/v1/run-evals.sh" run "$review_repo/seed.json" "$observed_at" \
    >"$review_repo/result.json" 2>"$review_repo/result.err" || fail "review $review_name run"
  [ ! -s "$review_repo/result.err" ] || fail 'review positive stderr'
  "$jq_bin" -e --slurpfile report "$review_repo/record-report.json" \
    --arg run_sha "$(sha_file "$root/evals/v1/run.sh")" \
    --slurpfile seed "$review_repo/seed.json" '
    .body as $body |
    all($body.cases[]; . as $case |
      .grader_kind == "human" and .verdict ==
        ([$report[0].body.cases[0].trials[]|select(.attempt_id == $case.case_id)][0].status) and
      .subject_ref.sha256 == ([$seed[0].body.cases[]|select(.case_id == $case.case_id)][0].verdict.sha256)) and
    all($body.trace[]; .grader_kind == "human" and
      .tool_ref == {content_id:"eval-record-evaluator.v1",media_type:"text/x-shellscript",sha256:$run_sha})
  ' "$review_repo/result.json" >/dev/null || fail 'actual record statuses and refs'
  pass "review $review_name relays actual record statuses and pinned refs"
done
"$jq_bin" -e '.body.summary == {total:5,passed:4,failed:1,inconclusive:0} and
  (.body.cases[]|select(.case_id == "review.1001")|.reason_id == "evals.human-grade-failed")' \
  "$tmp/review-failed/result.json" >/dev/null || fail 'approved failed status must remain failed'
"$tmp/review-five/evals/v1/run-evals.sh" run "$tmp/review-five/seed.json" "$observed_at" \
  >"$tmp/review-five/repeat.json" || fail 'review repeat'
/usr/bin/cmp -s "$tmp/review-five/result.json" "$tmp/review-five/repeat.json" || fail 'review repeat bytes'

for mutation in status-down status-up evidence output rubric expected graded-at trial-index case-ref extra-wrapper; do
  review_repo="$tmp/review-five"
  if [ "$mutation" = status-up ]; then review_repo="$tmp/review-failed"; fi
  case "$mutation" in
    status-down) filter='.body.grades[0].value.body.status="failed"'; token=E_RELATION ;;
    status-up) filter='.body.grades[0].value.body.status="passed"'; token=E_RELATION ;;
    evidence) filter='.body.grades[0].value.body.evidence_ref.value.sha256=("e"*64)'; token=E_RELATION ;;
    output) filter='.body.trials[0].value.body.output_ref.value.sha256=("e"*64)'; token=E_RELATION ;;
    rubric) filter='.body.cases[0].value.body.graders[0].instructions_ref.sha256=("e"*64)'; token=E_RELATION ;;
    expected) filter='.body.cases[0].value.body.expected_ref.sha256=("e"*64)'; token=E_RELATION ;;
    graded-at) filter='.body.grades[0].value.body.graded_at="2026-09-04T00:00:00Z"'; token=E_RELATION ;;
    trial-index) filter='.body.trials[0].value.body.trial_index=2'; token=E_RELATION ;;
    case-ref) filter='.body.suite.value.body.case_ids=["case.other"]'; token=E_RELATION ;;
    extra-wrapper) filter='.body.grades[0].extra=true'; token=E_SHAPE ;;
  esac
  "$jq_bin" -S -c "$filter" "$review_repo/bundle.json" >"$tmp/review-mutated.json" || fail 'bundle mutation'
  review_rehash "$tmp/review-mutated.json" "$tmp/review-mutated.bundle.json"
  review_seed_from "$review_repo" "$tmp/review-mutated.bundle.json" "$review_repo/labels.json" "$tmp/review-mutated.seed.json"
  review_expect_error "$mutation" "$token" "$review_repo" "$tmp/review-mutated.seed.json"
done
"$jq_bin" -S -c 'del(.body.grades[0].ref)' "$tmp/review-five/bundle.json" >"$tmp/review-wrapper-missing.bundle.json"
review_seed_from "$tmp/review-five" "$tmp/review-wrapper-missing.bundle.json" "$tmp/review-five/labels.json" "$tmp/review-wrapper-missing.seed.json"
review_expect_error missing-wrapper-ref E_SHAPE "$tmp/review-five" "$tmp/review-wrapper-missing.seed.json"
for mutation in duplicate-attempt extra-grade missing-grade swapped-comments; do
  case "$mutation" in
    duplicate-attempt) filter='.body.trials[1].value.body.attempt_id="review.1001"' ;;
    extra-grade) filter='.body.grades += [.body.grades[0]]' ;;
    missing-grade) filter='.body.grades |= .[1:]' ;;
    swapped-comments) filter='.body.trials[0].value.body.attempt_id="review.1002" |
      .body.trials[1].value.body.attempt_id="review.1001" |
      .body.cases[0].value.body.attempt_ids[0]="review.1002" |
      .body.cases[0].value.body.attempt_ids[1]="review.1001"' ;;
  esac
  "$jq_bin" -S -c "$filter" "$tmp/review-five/bundle.json" >"$tmp/review-mutated.json" || fail 'identity mutation'
  review_rehash "$tmp/review-mutated.json" "$tmp/review-mutated.bundle.json"
  review_seed_from "$tmp/review-five" "$tmp/review-mutated.bundle.json" "$tmp/review-five/labels.json" "$tmp/review-mutated.seed.json"
  review_expect_error "$mutation" E_RELATION "$tmp/review-five" "$tmp/review-mutated.seed.json"
done
/bin/cp "$tmp/review-five/evals/v1/seeds/reviewer-severity/verdicts/1001.md" \
  "$tmp/review-five/evals/v1/seeds/reviewer-severity/verdicts/1999.md"
for mutation in duplicate-label missing-label extra-label verdict-label-digest; do
  case "$mutation" in
    duplicate-label) filter='.body.trials += [.body.trials[0]]'; token=E_SHAPE ;;
    missing-label) filter='.body.trials |= .[1:]'; token=E_RELATION ;;
    extra-label) filter='.body.trials += [(.body.trials[0] | .comment_id="1999")]'; token=E_RELATION ;;
    verdict-label-digest) filter='.body.trials[0].verdict_sha256=("e"*64)'; token=E_RELATION ;;
  esac
  "$jq_bin" -S -c "$filter" "$tmp/review-five/labels.json" >"$tmp/review-mutated.labels.json" || fail 'label mutation'
  review_seed_from "$tmp/review-five" "$tmp/review-five/bundle.json" "$tmp/review-mutated.labels.json" "$tmp/review-mutated.seed.json"
  review_expect_error "$mutation" "$token" "$tmp/review-five" "$tmp/review-mutated.seed.json"
done
label_case=0
for label_filter in '.body.trials[0].comment_id="01001"' \
  '.body.trials[0].extra=true' '.body.trials[0].grade_status="inconclusive"' \
  '.body.trials[0].findings[0].index=0' '.body.trials[0].findings[0].tag="P4"' \
  '.body.trials[0].findings[0].label="unknown"' \
  '.body.trials[0].findings += [.body.trials[0].findings[0]]' \
  '.body.trials[0].missed_important=[{summary:"two\nlines",evidence_link:"fixture"}]'; do
  "$jq_bin" -S -c "$label_filter" "$tmp/review-five/labels.json" >"$tmp/review-mutated.labels.json"
  review_seed_from "$tmp/review-five" "$tmp/review-five/bundle.json" "$tmp/review-mutated.labels.json" "$tmp/review-mutated.seed.json"
  label_case=$((label_case + 1))
  review_expect_error "label-shape-$label_case" E_SHAPE "$tmp/review-five" "$tmp/review-mutated.seed.json"
done
for mutation in duplicate-seed missing-seed extra-seed caller-approval traversal; do
  token=E_RELATION
  case "$mutation" in
    duplicate-seed) filter='.body.cases += [.body.cases[0]]'; token=E_SHAPE ;;
    missing-seed) filter='.body.cases |= .[1:]' ;;
    extra-seed) filter='.body.cases += [(.body.cases[0] | .case_id="review.1999" |
      .verdict.comment_id="1999" | .verdict.path="evals/v1/seeds/reviewer-severity/verdicts/1999.md")]' ;;
    caller-approval) filter='.body.shared.approval={state:"present"}'; token=E_SHAPE ;;
    traversal) filter='.body.shared.files[0].path="evals/v1/seeds/reviewer-severity/verdicts/../1001.md"'; token=E_SHAPE ;;
  esac
  "$jq_bin" -S -c "$filter" "$tmp/review-five/seed.json" >"$tmp/review-mutated.seed.json" || fail 'seed mutation'
  review_expect_error "$mutation" "$token" "$tmp/review-five" "$tmp/review-mutated.seed.json"
done
review_repo="$tmp/review-five"
for file in evals/v1/run.sh evals/v1/framework.jq "$record_schema"; do
  /bin/cp "$review_repo/$file" "$tmp/review-saved-file" || fail 'closure backup'
  /usr/bin/printf '\n' >>"$review_repo/$file"
  review_expect_error "closure-${file##*/}" E_STALE "$review_repo" "$review_repo/seed.json"
  /bin/cp "$tmp/review-saved-file" "$review_repo/$file" || fail 'closure restore'
done
verdict_file="$review_repo/evals/v1/seeds/reviewer-severity/verdicts/1001.md"
/bin/cp "$verdict_file" "$tmp/review-saved-verdict"
/bin/rm "$verdict_file"
review_expect_error missing-verdict E_RELATION "$review_repo" "$review_repo/seed.json"
/bin/ln -s "$tmp/review-saved-verdict" "$verdict_file"
review_expect_error symlink-verdict E_RELATION "$review_repo" "$review_repo/seed.json"
/bin/rm "$verdict_file"
/bin/cp "$tmp/review-saved-verdict" "$verdict_file"
/usr/bin/printf 'tampered\n' >>"$verdict_file"
review_expect_error verdict-bytes E_RELATION "$review_repo" "$review_repo/seed.json"
/bin/cp "$tmp/review-saved-verdict" "$verdict_file"
/bin/mv "$review_repo/evals/v1/seeds/reviewer-severity/verdicts" "$review_repo/held-verdicts"
/bin/ln -s "$review_repo/held-verdicts" "$review_repo/evals/v1/seeds/reviewer-severity/verdicts"
review_expect_error parent-symlink E_RELATION "$review_repo" "$review_repo/seed.json"
/bin/rm "$review_repo/evals/v1/seeds/reviewer-severity/verdicts"
/bin/mv "$review_repo/held-verdicts" "$review_repo/evals/v1/seeds/reviewer-severity/verdicts"
"$jq_bin" -S -c '.body.shared.files += [(.body.shared.files[0] | .sha256=("e"*64))]' \
  "$review_repo/seed.json" >"$tmp/review-conflicting-files.json"
review_expect_error conflicting-shared-digest E_RELATION "$review_repo" "$tmp/review-conflicting-files.json"
approval_file="$review_repo/evals/v1/seeds/reviewer-severity/approval.json"
/bin/cp "$approval_file" "$tmp/review-saved-approval"
/usr/bin/printf '\n' >>"$approval_file"
review_expect_error changed-fixed-approval E_STALE "$review_repo" "$review_repo/seed.json"
/bin/cp "$tmp/review-saved-approval" "$approval_file"
"$review_repo/evals/v1/run-evals.sh" run "$review_repo/evals/v1/seed-set.json" "$observed_at" \
  >"$review_repo/core-result.json" || fail 'private real core run'
"$review_repo/evals/v1/run-evals.sh" dashboard "$observed_at" \
  "$review_repo/seed.json" "$review_repo/result.json" \
  "$review_repo/evals/v1/seed-set.json" "$review_repo/core-result.json" \
  >"$review_repo/dashboard.json" || fail 'review and core dashboard'
"$jq_bin" -e '.body.quality.total == 13 and .body.quality.passed == 13 and
  (.body.inputs|length)==2' "$review_repo/dashboard.json" >/dev/null || fail 'review/core dashboard counts'
"$review_repo/evals/v1/run-evals.sh" run "$review_repo/seed.json" 2026-09-04T00:00:00Z \
  >"$review_repo/earlier.json" || fail 'review earlier run'
for variant in identical distinct forged; do
  case "$variant" in
    identical) second="$review_repo/result.json"; token=E_RUNTIME ;;
    distinct) second="$review_repo/earlier.json"; token=E_SHAPE ;;
    forged)
      "$jq_bin" -S -c '.body.cases[0].verdict="failed" | .body.summary.passed-=1 | .body.summary.failed+=1' \
        "$review_repo/earlier.json" >"$review_repo/forged.json"
      second="$review_repo/forged.json"; token=E_RELATION ;;
  esac
  status=0
  "$review_repo/evals/v1/run-evals.sh" dashboard "$observed_at" \
    "$review_repo/seed.json" "$review_repo/result.json" "$review_repo/seed.json" "$second" \
    >"$tmp/review-dashboard-$variant.out" 2>"$tmp/review-dashboard-$variant.err" || status=$?
  [ "$status" -ne 0 ] && [ ! -s "$tmp/review-dashboard-$variant.out" ] &&
    [ "$(<"$tmp/review-dashboard-$variant.err")" = "$token" ] || fail "review dashboard $variant"
  pass "review dashboard $variant preserves $token"
done
/bin/cp "$tmp/review-six/evals/v1/seeds/reviewer-severity/verdicts/1006.md" \
  "$tmp/review-five/evals/v1/seeds/reviewer-severity/verdicts/1006.md"
review_expect_error coordinated-caller-rewrite E_RELATION "$tmp/review-five" "$tmp/review-six/seed.json"
review_expect_error wrong-selected-set E_RELATION "$tmp/review-wrong-selection" "$tmp/review-wrong-selection/seed.json"
review_expect_error approval-shape E_SHAPE "$tmp/review-approval-shape" "$tmp/review-approval-shape/seed.json"
review_direct() {
  local operation=$1 observation=$2 candidate=$3
  "$jq_bin" -S -c -n -L "$modules" \
    --arg evals_operation "$operation" --arg program_sha256 "$program_sha" \
    --arg driver_sha256 "$(sha_file "$tmp/review-five/evals/v1/evals-driver.sh")" \
    --arg catalog_sha256 "$(sha_file "$tmp/review-five/evals/v1/eval-catalog.json")" \
    --arg evaluator_sha256 "$(sha_file "$tmp/review-evaluator.json")" \
    --arg seed_set_sha256 "$(sha_file "$tmp/review-five/seed.json")" \
    --arg tool_sha256 "$(sha_file "$root/scripts/core-contract.sh")" \
    --arg scanner_sha256 "$(sha_file "$root/orchestrator/v1/scan-state.sh")" \
    --arg planner_sha256 "$(sha_file "$root/orchestrator/v1/reconciliation-plan.jq")" \
    --arg sandbox_sha256 "$(sha_file "$root/control/v1/evaluate-sandbox.sh")" \
    --arg risk_gates_sha256 "$(sha_file "$root/control/v1/evaluate-risk-gates.sh")" \
    --arg duty_sha256 "$(sha_file "$root/control/v1/evaluate-duty.sh")" \
    --argjson normalizer_shas '{}' --arg observed_at "$observed_at" \
    --slurpfile catalog_docs "$tmp/review-five/evals/v1/eval-catalog.json" \
    --slurpfile seed_set_docs "$tmp/review-five/seed.json" --slurpfile observation_docs "$observation" \
    --slurpfile evaluator_docs "$tmp/review-evaluator.json" --slurpfile candidate_docs "$candidate" \
    --slurpfile result_docs "$first" --argjson result_shas '[]' -f "$program"
}
"$jq_bin" -S -c '.body.evaluator.content' "$tmp/review-five/result.json" >"$tmp/review-evaluator.json"
"$jq_bin" -S -c '[.body.cases[].observation.value]' "$tmp/review-five/result.json" >"$tmp/review-observations.json"
for variant in missing inconclusive; do
  if [ "$variant" = missing ]; then filter='.[1:]'; reason=evals.observation-missing
  else filter='.[0].status="inconclusive"'; reason=evals.human-grade-inconclusive; fi
  "$jq_bin" -S -c "$filter" "$tmp/review-observations.json" >"$tmp/review-direct-observations.json"
  review_direct build-run-result "$tmp/review-direct-observations.json" "$first" \
    >"$tmp/review-direct-result.json" || fail 'direct review grade'
  "$jq_bin" -e --arg reason "$reason" '.body.cases[0].verdict == "inconclusive" and
    .body.cases[0].reason_id == $reason and .body.cases[0].grader_kind == "human"' \
    "$tmp/review-direct-result.json" >/dev/null || fail 'defensive review inconclusive'
  [ "$(review_direct validate-run-result "$tmp/review-direct-observations.json" "$tmp/review-direct-result.json")" = true ] ||
    fail 'defensive review validation'
done
for field in cases trace; do
  "$jq_bin" -S -c --arg field "$field" '.body[$field][0].grader_kind="deterministic"' \
    "$tmp/review-five/result.json" >"$tmp/review-bad-human.json"
  [ "$(review_direct validate-run-result "$tmp/review-observations.json" "$tmp/review-bad-human.json")" = false ] ||
    fail "review requires human $field"
done
"$jq_bin" -S -c '.body.cases[0].grader_kind="human"' "$first" >"$tmp/review-human-core.json"
[ "$(validate_result "$tmp/review-human-core.json")" = false ] || fail 'human forbidden on core source'
pass 'review direct build/validate preserves defensive inconclusive and source-specific human grading'

/usr/bin/printf '1..%s\n' "$passes"
