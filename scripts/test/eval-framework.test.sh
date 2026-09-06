#!/bin/bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
runner="$root/evals/v1/run.sh"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-eval-framework-test.XXXXXX")
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
jq_bin="$jq_cache_dir/$jq_asset"
if [ ! -f "$jq_bin" ] || [ "$(sha_file "$jq_bin")" != "$jq_sha" ]; then
  download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$download"
  [ "$(sha_file "$download")" = "$jq_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_bin"
fi
[ "$($jq_bin --version)" = jq-1.6 ] || fail 'jq identity'

ref() {
  "$jq_bin" -S -c -n --arg id "$1" --arg media "$2" --arg sha "$3" \
    '{content_id:$id,media_type:$media,sha256:$sha}'
}
wrap() {
  local source=$1 target=$2 id digest
  id=$("$jq_bin" -r .id "$source")
  digest=$(sha_file "$source")
  "$jq_bin" -S -c -n --arg id "$id" --arg sha "$digest" --slurpfile value "$source" '
    {ref:{content_id:$id,media_type:"application/vnd.ystack.eval-record+json",sha256:$sha},
     value:$value[0]}
  ' > "$target"
}
grader() {
  "$jq_bin" -S -c -n --arg id "$1" --arg kind "$2" --arg digit "$3" '
    def ref($id;$sha):
      {content_id:$id,media_type:"application/vnd.ystack.eval-grader+json",sha256:$sha};
    {grader_id:$id,grader_kind:$kind,
     implementation_ref:ref(($id+".implementation");($digit*64)),
     instructions_ref:ref(($id+".instructions");($digit*64))}
  '
}
rehash() {
  local source=$1 section=$2 index=$3 target=$4 value digest
  value=$("$jq_bin" -S -c --arg section "$section" --argjson index "$index" '
    if $section=="suite" then .body.suite.value else .body[$section][$index].value end
  ' "$source")
  digest=$(builtin printf '%s\n' "$value" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
  "$jq_bin" -S -c --arg section "$section" --argjson index "$index" --arg sha "$digest" '
    if $section=="suite" then .body.suite.ref.sha256=$sha
    else .body[$section][$index].ref.sha256=$sha end
  ' "$source" > "$target"
}
expect_error() {
  local name=$1 token=$2 input=$3 status=0
  "$runner" evaluate "$input" > "$tmp/$name.out" 2> "$tmp/$name.err" || status=$?
  [ "$status" -ne 0 ] && [ ! -s "$tmp/$name.out" ] &&
    [ "$(/bin/cat "$tmp/$name.err")" = "$token" ] || fail "$name"
  pass "$name"
}

framework_sha=$(sha_file "$root/evals/v1/framework.jq")
framework_ref=$(ref eval-framework.v1 application/vnd.ystack.eval-framework+jq "$framework_sha")
scope_ref=$(ref eval-scope.definition application/vnd.ystack.eval-scope+json "$(printf 'a%.0s' {1..64})")
"$jq_bin" -S -c -n --argjson framework "$framework_ref" --argjson definition "$scope_ref" '
  {schema_version:1,kind:"eval_suite",id:"suite.default-adapters",body:{
    suite_version:"v1",framework_ref:$framework,
    scope:{scope_id:"scope.default-adapters",scope_version:"v1",
      definition_ref:$definition,scope_sha256:$definition.sha256},
    case_ids:["case.deterministic","case.model"]}}
' > "$tmp/suite.value"
wrap "$tmp/suite.value" "$tmp/suite.wrap"
suite_ref=$("$jq_bin" -c .ref "$tmp/suite.wrap")

grader_det=$(grader grader.det deterministic b)
grader_human=$(grader grader.human human c)
grader_model=$(grader grader.model model d)
input_det=$(ref input.det application/json "$(printf '1%.0s' {1..64})")
expected_det=$(ref expected.det application/json "$(printf '2%.0s' {1..64})")
input_model=$(ref input.model application/json "$(printf '3%.0s' {1..64})")
expected_model=$(ref expected.model application/json "$(printf '4%.0s' {1..64})")
"$jq_bin" -S -c -n --argjson suite "$suite_ref" --argjson input "$input_det" \
  --argjson expected "$expected_det" --argjson det "$grader_det" --argjson human "$grader_human" '
  {schema_version:1,kind:"eval_case",id:"case.deterministic",body:{case_version:"v1",
   suite_ref:$suite,execution_kind:"deterministic",input_ref:$input,expected_ref:$expected,
   trial_count:1,trial_ids:["trial.det.1"],attempt_ids:["attempt.trial.det.1"],
   graders:[$det,$human]}}
' > "$tmp/case.det.value"
"$jq_bin" -S -c -n --argjson suite "$suite_ref" --argjson input "$input_model" \
  --argjson expected "$expected_model" --argjson det "$grader_det" --argjson human "$grader_human" \
  --argjson model "$grader_model" '
  {schema_version:1,kind:"eval_case",id:"case.model",body:{case_version:"v1",
   suite_ref:$suite,execution_kind:"model",input_ref:$input,expected_ref:$expected,
   trial_count:2,trial_ids:["trial.model.1","trial.model.2"],
   attempt_ids:["attempt.trial.model.1","attempt.trial.model.2"],graders:[$det,$human,$model]}}
' > "$tmp/case.model.value"
wrap "$tmp/case.det.value" "$tmp/case.det.wrap"
wrap "$tmp/case.model.value" "$tmp/case.model.wrap"
"$jq_bin" -S -c -s . "$tmp/case.det.wrap" "$tmp/case.model.wrap" > "$tmp/cases.json"
case_det_ref=$("$jq_bin" -c .ref "$tmp/case.det.wrap")
case_model_ref=$("$jq_bin" -c .ref "$tmp/case.model.wrap")

make_trial() {
  local id=$1 case_ref=$2 index=$3 digit=$4 output
  output=$(ref "$id.output" application/json "$(printf "$digit%.0s" {1..64})")
  "$jq_bin" -S -c -n --arg id "$id" --argjson case_ref "$case_ref" --argjson index "$index" \
    --argjson output "$output" '{schema_version:1,kind:"eval_trial",id:$id,body:{
      trial_version:"v1",case_ref:$case_ref,trial_index:$index,attempt_id:("attempt."+$id),
      started_at:"2026-09-01T00:00:00Z",finished_at:"2026-09-01T00:00:10Z",status:"completed",
      output_ref:{state:"present",value:$output},reason:{state:"absent"}}}'
}
make_trial trial.det.1 "$case_det_ref" 1 5 > "$tmp/trial.det.value"
make_trial trial.model.1 "$case_model_ref" 1 6 > "$tmp/trial.model1.value"
make_trial trial.model.2 "$case_model_ref" 2 7 > "$tmp/trial.model2.value"
for name in det model1 model2; do wrap "$tmp/trial.$name.value" "$tmp/trial.$name.wrap"; done
"$jq_bin" -S -c -s . "$tmp/trial.det.wrap" "$tmp/trial.model1.wrap" "$tmp/trial.model2.wrap" > "$tmp/trials.json"

make_grade() {
  local id=$1 trial=$2 grader_json=$3 status=$4 digit=$5
  local grader_id grader_kind grader_ref evidence evidence_state reason
  grader_id=$("$jq_bin" -r .grader_id <<< "$grader_json")
  grader_kind=$("$jq_bin" -r .grader_kind <<< "$grader_json")
  grader_ref=$("$jq_bin" -c .implementation_ref <<< "$grader_json")
  evidence=$(ref "$id.evidence" application/json "$(printf "$digit%.0s" {1..64})")
  if [ "$status" = inconclusive ]; then
    evidence_state='{"state":"absent"}'; reason='{"state":"present","value":"grader.no-consensus"}'
  else
    evidence_state=$("$jq_bin" -c -n --argjson value "$evidence" '{state:"present",value:$value}')
    reason='{"state":"absent"}'
  fi
  "$jq_bin" -S -c -n --arg id "$id" --argjson trial "$trial" --arg grader_id "$grader_id" \
    --arg grader_kind "$grader_kind" --argjson grader_ref "$grader_ref" --arg status "$status" \
    --argjson evidence "$evidence_state" --argjson reason "$reason" '
    {schema_version:1,kind:"eval_grade",id:$id,body:{grade_version:"v1",trial_ref:$trial,
     grader_id:$grader_id,grader_kind:$grader_kind,grader_ref:$grader_ref,
     graded_at:"2026-09-01T00:00:20Z",status:$status,
     evidence_ref:$evidence,reason:$reason}}'
}
trial_det_ref=$("$jq_bin" -c .ref "$tmp/trial.det.wrap")
trial_model1_ref=$("$jq_bin" -c .ref "$tmp/trial.model1.wrap")
trial_model2_ref=$("$jq_bin" -c .ref "$tmp/trial.model2.wrap")
grade_specs=(
  'det.det' 'det.human' 'model1.det' 'model1.human' 'model1.model'
  'model2.det' 'model2.human' 'model2.model'
)
for spec in "${grade_specs[@]}"; do
  trial_name=${spec%%.*}; grader_name=${spec##*.}; status=passed; digit=8
  [ "$spec" = model2.human ] && status=inconclusive
  case "$trial_name" in det) trial_ref=$trial_det_ref ;; model1) trial_ref=$trial_model1_ref ;; model2) trial_ref=$trial_model2_ref ;; esac
  case "$grader_name" in det) grader_json=$grader_det ;; human) grader_json=$grader_human ;; model) grader_json=$grader_model ;; esac
  make_grade "grade.$spec" "$trial_ref" "$grader_json" "$status" "$digit" > "$tmp/grade.$spec.value"
  wrap "$tmp/grade.$spec.value" "$tmp/grade.$spec.wrap"
done
"$jq_bin" -S -c -s . "$tmp"/grade.*.wrap | "$jq_bin" -S -c 'sort_by([.value.body.trial_ref.content_id,.value.body.grader_id])' > "$tmp/grades.json"
"$jq_bin" -S -c -n --slurpfile suite "$tmp/suite.wrap" --slurpfile cases "$tmp/cases.json" \
  --slurpfile trials "$tmp/trials.json" --slurpfile grades "$tmp/grades.json" '
  {schema_version:1,kind:"eval_bundle",id:"run.default-adapters",
   body:{suite:$suite[0],cases:$cases[0],trials:$trials[0],grades:$grades[0]}}
' > "$tmp/bundle.json"

"$runner" evaluate "$tmp/bundle.json" > "$tmp/report.json"
"$jq_bin" -e '
  .kind=="eval_report" and .body.mode=="evaluation-only" and
  .body.status=="inconclusive" and
  [.body.cases[].status]==["passed","inconclusive"] and
  [.body.cases[1].trials[].trial_index]==[1,2]
' "$tmp/report.json" >/dev/null || fail 'valid multi-trial report'
pass valid-multi-trial-report
"$runner" evaluate "$tmp/bundle.json" > "$tmp/repeat.json"
/usr/bin/cmp -s "$tmp/report.json" "$tmp/repeat.json" || fail 'deterministic report'
# Invoked by a relative path, the runner still binds itself to its own directory.
( cd "$root" && ./evals/v1/run.sh evaluate "$tmp/bundle.json" ) > "$tmp/relative.json" ||
  fail 'relative-path invocation'
/usr/bin/cmp -s "$tmp/report.json" "$tmp/relative.json" || fail 'relative-path report differs'
pass relative-path-invocation
# Trial ids are bound by position, so ids whose lexical order differs from
# their trial order are still one valid case shape; a repeated id is not.
generation=$(/usr/bin/sed -n "s/^PORTABLE_CORE_GENERATION='\\(g-[0-9a-f]\\{64\\}\\)'$/\\1/p" \
  "$root/scripts/core-contract.sh")
modules="$root/core/v2/generations/$generation/modules"
[ -d "$modules" ] || fail 'selected generation modules'
/usr/bin/awk 'NR > 48 && /^def / { exit } { print }' "$root/evals/v1/framework.jq" \
  > "$tmp/framework-shapes.jq"
"$jq_bin" -L "$tmp" -L "$modules" -e --slurpfile c "$tmp/case.model.value" -n '
  import "framework-shapes" as shapes;
  ($c[0] | .body.trial_ids = ["trial.model.9","trial.model.10"] |
   .body.attempt_ids = ["attempt.trial.model.9","attempt.trial.model.10"] | shapes::case_ok) and
  ($c[0] | .body.trial_ids = ["trial.model.1","trial.model.1"] | shapes::case_ok | not) and
  ($c[0] | .body.attempt_ids = ["attempt.trial.model.1","attempt.trial.model.1"] | shapes::case_ok | not)
' >/dev/null || fail 'trial ids are not bound by position'
pass trial-ids-bound-by-position
[ "$(/usr/bin/wc -c < "$tmp/report.json" | /usr/bin/tr -d ' ')" -le 1048576 ] ||
  fail 'bounded report'
pass deterministic-report

"$jq_bin" -S -c '.body.cases[0].value.body.expected_ref.sha256=("f"*64)' \
  "$tmp/bundle.json" > "$tmp/tamper.json"
expect_error tampered-record E_STALE "$tmp/tamper.json"
"$jq_bin" -S -c '.body.cases[0].value.body.suite_ref.sha256=("e"*64)' \
  "$tmp/bundle.json" > "$tmp/stale-unhashed.json"
rehash "$tmp/stale-unhashed.json" cases 0 "$tmp/stale.json"
expect_error stale-record-link E_RELATION "$tmp/stale.json"
"$jq_bin" -S -c '.body.trials[0].value.body.started_at="2026-09-01T00:00:11Z"' \
  "$tmp/bundle.json" > "$tmp/trial-time-unhashed.json"
rehash "$tmp/trial-time-unhashed.json" trials 0 "$tmp/trial-time.json"
expect_error inverted-trial-time E_SHAPE "$tmp/trial-time.json"
"$jq_bin" -S -c '.body.grades[0].value.body.graded_at="2026-09-01T00:00:09Z"' \
  "$tmp/bundle.json" > "$tmp/grade-time-unhashed.json"
rehash "$tmp/grade-time-unhashed.json" grades 0 "$tmp/grade-time.json"
expect_error early-grade-time E_RELATION "$tmp/grade-time.json"
"$jq_bin" -S -c '.body.trials[1].value.body.attempt_id=.body.trials[0].value.body.attempt_id' \
  "$tmp/bundle.json" > "$tmp/attempt-unhashed.json"
rehash "$tmp/attempt-unhashed.json" trials 1 "$tmp/attempt.json"
expect_error duplicate-attempt E_RELATION "$tmp/attempt.json"
"$jq_bin" -S -c '.body.cases|=reverse' "$tmp/bundle.json" > "$tmp/order.json"
expect_error record-order E_RELATION "$tmp/order.json"
"$jq_bin" -S -c '.body.trials += [.body.trials[0]]' "$tmp/bundle.json" > "$tmp/duplicate.json"
expect_error duplicate-trial E_RELATION "$tmp/duplicate.json"
"$jq_bin" -S -c '.body.grades |= map(select(.value.id!="grade.model2.model"))' \
  "$tmp/bundle.json" > "$tmp/missing-grade.json"
expect_error missing-grade E_RELATION "$tmp/missing-grade.json"
"$jq_bin" -S -c '.body.suite.value.body.extra_command="printf unsafe"' \
  "$tmp/bundle.json" > "$tmp/command.json"
expect_error arbitrary-command-field E_SHAPE "$tmp/command.json"
"$jq_bin" -S -c '.body.cases[0].value.body.graders[0].implementation_ref.content_id=("x"*129)' \
  "$tmp/bundle.json" > "$tmp/grader-metadata.json"
expect_error bounded-grader-metadata E_SHAPE "$tmp/grader-metadata.json"

"$jq_bin" -S -c '
  .body.trials[2].value.body.status="unavailable" |
  .body.trials[2].value.body.output_ref={state:"absent"} |
  .body.trials[2].value.body.reason={state:"present",value:"trial.output-unavailable"}
' "$tmp/bundle.json" > "$tmp/hidden-trial-unhashed.json"
rehash "$tmp/hidden-trial-unhashed.json" trials 2 "$tmp/hidden-trial.json"
hidden_trial_ref=$("$jq_bin" -c '.body.trials[2].ref' "$tmp/hidden-trial.json")
"$jq_bin" -S -c --argjson trial "$hidden_trial_ref" '
  .body.grades |= map(if .value.body.trial_ref.content_id=="trial.model.2" then
    .value.body.trial_ref=$trial |
    if .value.id=="grade.model2.model" then .value.body.status="failed"
    else .value.body.status="unavailable" | .value.body.evidence_ref={state:"absent"} |
      .value.body.reason={state:"present",value:"grader.unavailable"} end
    else . end)
' "$tmp/hidden-trial.json" > "$tmp/hidden-grades-0.json"
hidden_current="$tmp/hidden-grades-0.json"
hidden_count=0
for hidden_id in grade.model2.det grade.model2.human grade.model2.model; do
  hidden_index=$("$jq_bin" -r --arg id "$hidden_id" '.body.grades|map(.value.id)|index($id)' "$hidden_current")
  hidden_next="$tmp/hidden-grades-$((hidden_count + 1)).json"
  rehash "$hidden_current" grades "$hidden_index" "$hidden_next"
  hidden_current=$hidden_next
  hidden_count=$((hidden_count + 1))
done
expect_error unavailable-trial-hides-failure E_RELATION "$hidden_current"

"$jq_bin" -S -c '
  .body.grades |= map(if .value.id=="grade.model2.model" then
    .value.body.status="failed" else . end)
' "$tmp/bundle.json" > "$tmp/failed-unhashed.json"
failed_index=$("$jq_bin" -r '.body.grades|map(.value.id)|index("grade.model2.model")' "$tmp/failed-unhashed.json")
rehash "$tmp/failed-unhashed.json" grades "$failed_index" "$tmp/failed.json"
"$runner" evaluate "$tmp/failed.json" > "$tmp/failed-report.json"
[ "$("$jq_bin" -r .body.status "$tmp/failed-report.json")" = failed ] || fail 'failed grade precedence'
pass failed-grade-precedence

"$jq_bin" -S -c '
  .body.grades |= map(if .value.id=="grade.model2.human" then
    .value.body.status="unavailable" | .value.body.evidence_ref={state:"absent"} |
    .value.body.reason={state:"present",value:"grader.unavailable"}
    else . end)
' "$tmp/bundle.json" > "$tmp/unavailable-unhashed.json"
grade_index=$("$jq_bin" -r '.body.grades|map(.value.id)|index("grade.model2.human")' "$tmp/unavailable-unhashed.json")
rehash "$tmp/unavailable-unhashed.json" grades "$grade_index" "$tmp/unavailable.json"
"$runner" evaluate "$tmp/unavailable.json" > "$tmp/unavailable-report.json"
[ "$("$jq_bin" -r .body.status "$tmp/unavailable-report.json")" = unavailable ] || fail 'unavailable result'
pass explicit-unavailable

"$jq_bin" . "$tmp/bundle.json" > "$tmp/noncanonical.json"
expect_error canonical-bytes E_CANONICAL "$tmp/noncanonical.json"
/bin/cat "$tmp/bundle.json" "$tmp/bundle.json" > "$tmp/two-bundles.json"
expect_error multi-root-stream E_PARSE "$tmp/two-bundles.json"
"$jq_bin" -e '
  ([..|objects|keys[]|select(.=="authority" or .=="permissions" or .=="credential" or
    .=="network" or .=="command" or .=="activation" or .=="qualification")] | length)==0
' "$tmp/report.json" >/dev/null || fail 'inactive data-only output'
pass inactive-data-only-output

/usr/bin/printf 'PASS: %s eval-record evaluator checks\n' "$passes"
