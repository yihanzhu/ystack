#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|E_STALE)
      /usr/bin/printf '%s\n' "$1" >&2
      ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

sha256_path() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

verify_hash() {
  [ -f "$2" ] && [ ! -L "$2" ] &&
    [ "$(sha256_path "$2")" = "$1" ]
}

[ "$#" -eq 7 ] || emit_error E_USAGE
mode=$1
case "$mode" in run|dashboard) ;; *) emit_error E_USAGE ;; esac
runtime=$2
input=$3
evaluator=$4
evaluator_sha256=$5
seed_set_sha256=$6
observed_at=$7
[[ "$observed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
  emit_error E_USAGE

self=${BASH_SOURCE[0]}
case "$self" in /*) ;; *) emit_error E_RUNTIME ;; esac
self_dir=$(CDPATH='' cd -P -- "${self%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
self="$self_dir/${self##*/}"
[ "$self" = "$runtime/driver.sh" ] && [ "$self_dir" = "$runtime" ] ||
  emit_error E_RUNTIME
[ -d "$runtime" ] && [ ! -L "$runtime" ] || emit_error E_RUNTIME
runtime_parent=${runtime%/*}
case "$mode:$input" in
  run:"$runtime_parent"/input.json) input_document=$input ;;
  dashboard:"$runtime_parent"/inputs)
    [ -d "$input" ] && [ ! -L "$input" ] || emit_error E_RUNTIME
    input_document="$input/manifest.json"
    ;;
  *) emit_error E_RUNTIME ;;
esac
case "$evaluator" in "$runtime"/evaluator.json) ;; *) emit_error E_RUNTIME ;; esac

generation=g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43
modules="$runtime/core/v2/generations/$generation/modules"
program="$runtime/program.jq"
catalog="$runtime/catalog.json"
core_front_door="$runtime/scripts/core-contract.sh"
scanner="$runtime/orchestrator/v1/scan-state.sh"
scanner_sha256=556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5
planner="$runtime/orchestrator/v1/reconciliation-plan.jq"
planner_sha256=03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4
sandbox_evaluator="$runtime/control/v1/evaluate-sandbox.sh"
sandbox_sha256=8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb
risk_gates_evaluator="$runtime/control/v1/evaluate-risk-gates.sh"
risk_gates_sha256=0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8
normalizer_shas='{"codex-cli-producer":"dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25","codex-native-reviewer":"7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603","github-actions-ci":"690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7","github-forge":"b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be","gitlab-forge":"b8461e4341f0426b6f66664b859af38748deedcc199b772e487fb3aa3ee3c713"}'
jq_bin="$runtime/bin/jq"
work="$runtime_parent/work"
program_sha256=c92eae2b20cff74e27af12bf38c8b0f5199eb7fa62bd02c41f205f0e04cda504
driver_sha256=$(sha256_path "$self") || emit_error E_RUNTIME

verify_runtime() {
  verify_hash "$program_sha256" "$program" &&
  verify_hash ddd8937325342d202ec57c3060be71881e603c00f423e5a3587339c57aa22b65 "$catalog" &&
  verify_hash 3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94 \
    "$runtime/core/v2/generation-registry.json" &&
  verify_hash 65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a \
    "$runtime/core/v2/generations/$generation/contracts.jq" &&
  verify_hash dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8 \
    "$runtime/core/v2/generations/$generation/core-ingress.sh" &&
  verify_hash c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207 \
    "$modules/profile_graph.jq" &&
  verify_hash 8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281 \
    "$modules/result_facts.jq" &&
  verify_hash ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46 \
    "$modules/result_truth.jq" &&
  verify_hash 8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade \
    "$modules/schema.jq" &&
  verify_hash 6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e \
    "$modules/stage_request.jq" &&
  verify_hash b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 \
    "$core_front_door" &&
  verify_hash "$scanner_sha256" "$scanner" &&
  verify_hash "$planner_sha256" "$planner" &&
  verify_hash "$sandbox_sha256" "$sandbox_evaluator" &&
  verify_hash "$risk_gates_sha256" "$risk_gates_evaluator" &&
  verify_hash 3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e \
    "$runtime/control/v1/risk-gates-policy.json" &&
  verify_hash 8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5 \
    "$runtime/control/v1/risk-gates-decision.json" &&
  verify_hash d00fccd8e31b770c6df01fba17e3cc315d58edfbbf0a8055d66d537dc6ad21ff \
    "$runtime/control/v1/risk-gates.jq" &&
  verify_hash b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9 \
    "$runtime/control/v1/duty-separation-policy.json" &&
  verify_hash 4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99 \
    "$runtime/control/v1/duty-separation-decision.json" &&
  verify_hash b4e480748dd4fb7dec769b25f0f7649b0e5dc31f9de438bba690e9eab6ac236c \
    "$runtime/control/v1/duty-separation.jq" &&
  verify_hash 146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa \
    "$runtime/control/v1/evaluate-duty.sh" &&
  verify_hash dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25 \
    "$runtime/adapters/codex-cli-producer/v1/normalize.jq" &&
  verify_hash b8461e4341f0426b6f66664b859af38748deedcc199b772e487fb3aa3ee3c713 \
    "$runtime/adapters/gitlab-forge/v1/normalize.jq" &&
  verify_hash 7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603 \
    "$runtime/adapters/codex-native-reviewer/v1/normalize.jq" &&
  verify_hash 690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7 \
    "$runtime/adapters/github-actions-ci/v1/normalize.jq" &&
  verify_hash b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be \
    "$runtime/adapters/github-forge/v1/normalize.jq" &&
  verify_hash 2be97550574ee4522fc0bd14780c92dee3c1b455f2c04b7763b0e437665a8d58 \
    "$runtime/control/v1/policy-set.jq" &&
  verify_hash c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd \
    "$runtime/control/v1/sandbox-decision.json" &&
  verify_hash 4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e \
    "$runtime/control/v1/sandbox-policy.json" &&
  verify_hash 83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3 \
    "$runtime/control/v1/sandbox.jq" &&
  verify_hash cf173ad0eaa08244bf636e3937845e894b21f14291fc5e66753e8673bdd2bd2a \
    "$runtime/control/v1/validate.sh" &&
  verify_hash 5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b \
    "$runtime/orchestrator/v1/state-scanner-driver.sh" &&
  verify_hash 9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb \
    "$runtime/orchestrator/v1/state-scanner-launcher.sh" &&
  verify_hash 722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae \
    "$runtime/orchestrator/v1/state-scanner.jq" &&
  verify_hash "$evaluator_sha256" "$evaluator" &&
  verify_hash "$program_seed_sha" "$input_document"
}
# The program sees exactly the documents named here. A dashboard run swaps the
# seed set, evaluator, and result documents per pair; every other run uses the
# driver's own.
program_evaluator=$evaluator
program_evaluator_sha=$evaluator_sha256
program_seed_sha=$seed_set_sha256
program_observed_at=$observed_at
seed_docs_file=$input_document
result_docs_file=$input_document
result_shas_json='[]'
verify_runtime || emit_error E_STALE
[ -x "$jq_bin" ] && [ ! -L "$jq_bin" ] &&
  [ "$("$jq_bin" --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME
[ -d "$work" ] && [ ! -L "$work" ] || emit_error E_RUNTIME

run_program() {
  "$jq_bin" -S -c -n -L "$modules" \
    --arg evals_operation "$1" \
    --arg program_sha256 "$program_sha256" --arg driver_sha256 "$driver_sha256" \
    --arg catalog_sha256 ddd8937325342d202ec57c3060be71881e603c00f423e5a3587339c57aa22b65 \
    --arg evaluator_sha256 "$program_evaluator_sha" \
    --arg seed_set_sha256 "$program_seed_sha" \
    --arg tool_sha256 b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 \
    --arg scanner_sha256 "$scanner_sha256" --arg planner_sha256 "$planner_sha256" \
    --arg sandbox_sha256 "$sandbox_sha256" --argjson normalizer_shas "$normalizer_shas" \
    --arg risk_gates_sha256 "$risk_gates_sha256" \
    --arg observed_at "$program_observed_at" \
    --slurpfile catalog_docs "$catalog" \
    --slurpfile seed_set_docs "$seed_docs_file" \
    --slurpfile observation_docs "$2" \
    --slurpfile evaluator_docs "$program_evaluator" \
    --slurpfile candidate_docs "$3" \
    --slurpfile result_docs "$result_docs_file" --argjson result_shas "$result_shas_json" \
    -f "$program"
}
single_root() {
  "$jq_bin" -e -n --slurpfile roots "$1" '($roots | length) == 1' >/dev/null 2>&1
}

# A dashboard aggregates one to sixteen (seed set, run result) pairs staged by the
# launcher. Each result must validate against its own seed set and this exact
# program before it counts; the dashboard itself is then built and re-validated.
run_dashboard() {
  local manifest="$input/manifest.json" pair_count j pair_seed_doc pair_result_doc dashboard
  local work_root=$work dashboard_input=$input pair_observed_at
  single_root "$manifest" || emit_error E_PARSE
  pair_count=$("$jq_bin" -r 'if type == "array" then length else empty end' "$manifest") ||
    emit_error E_RUNTIME
  [[ "$pair_count" =~ ^([1-9]|1[0-6])$ ]] || emit_error E_SHAPE
  : > "$work/seeds.jsonl" || emit_error E_RUNTIME
  : > "$work/results.jsonl" || emit_error E_RUNTIME
  j=0
  while [ "$j" -lt "$pair_count" ]; do
    pair_seed_doc="$input/seed-$j.json"
    pair_result_doc="$input/result-$j.json"
    [ -f "$pair_seed_doc" ] && [ ! -L "$pair_seed_doc" ] && [ -f "$pair_result_doc" ] &&
      [ ! -L "$pair_result_doc" ] || emit_error E_RUNTIME
    [ "$(sha256_path "$pair_seed_doc")" = "$("$jq_bin" -r ".[$j].seed_sha256" "$manifest")" ] &&
      [ "$(sha256_path "$pair_result_doc")" = "$("$jq_bin" -r ".[$j].result_sha256" "$manifest")" ] ||
      emit_error E_RELATION
    single_root "$pair_seed_doc" || emit_error E_PARSE
    single_root "$pair_result_doc" || emit_error E_PARSE
    # Byte comparison: command substitution would hide trailing whitespace.
    "$jq_bin" -S -c . "$pair_result_doc" > "$work/pair-$j-canonical.json" 2>/dev/null ||
      emit_error E_CANONICAL
    /usr/bin/cmp -s "$pair_result_doc" "$work/pair-$j-canonical.json" || emit_error E_CANONICAL
    # The seed set is replayed here, in this runtime, at the result's own
    # recorded time. Only a result the replay reproduces byte for byte counts;
    # nothing embedded in the supplied result is trusted.
    pair_observed_at=$("$jq_bin" -r '.body.observed_at' "$pair_result_doc") || emit_error E_RUNTIME
    [[ "$pair_observed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
      emit_error E_SHAPE
    work="$work_root/pair-$j"
    /bin/mkdir -m 0700 "$work" || emit_error E_RUNTIME
    /usr/bin/printf '[]\n' > "$work/empty-observations.json" || emit_error E_RUNTIME
    /usr/bin/printf '{}\n' > "$work/empty-candidate.json" || emit_error E_RUNTIME
    input=$pair_seed_doc
    input_document=$pair_seed_doc
    program_seed_sha=$(sha256_path "$pair_seed_doc") || emit_error E_RUNTIME
    program_observed_at=$pair_observed_at
    produce_result
    /usr/bin/cmp -s "$work/run-result.json" "$pair_result_doc" || emit_error E_RELATION
    work=$work_root
    input=$dashboard_input
    input_document="$dashboard_input/manifest.json"
    program_seed_sha=$seed_set_sha256
    program_observed_at=$observed_at
    # Re-emitted one document per line so adjacent files never run together.
    "$jq_bin" -S -c . "$pair_seed_doc" >> "$work/seeds.jsonl" || emit_error E_RUNTIME
    "$jq_bin" -S -c . "$pair_result_doc" >> "$work/results.jsonl" || emit_error E_RUNTIME
    j=$((j + 1))
  done
  seed_docs_file="$work/seeds.jsonl"
  result_docs_file="$work/results.jsonl"
  result_shas_json=$("$jq_bin" -c 'map(.result_sha256)' "$manifest") || emit_error E_RUNTIME
  dashboard="$work/dashboard.json"
  run_program build-dashboard "$work/empty-observations.json" "$work/empty-candidate.json" \
    > "$dashboard" 2>/dev/null || emit_error E_RUNTIME
  [ "$(run_program validate-dashboard "$work/empty-observations.json" "$dashboard" 2>/dev/null)" = true ] ||
    emit_error E_RUNTIME
  verify_runtime || emit_error E_STALE
  /bin/cat "$dashboard" || emit_error E_RUNTIME
  exit 0
}

/usr/bin/printf '[]\n' > "$work/empty-observations.json" || emit_error E_RUNTIME
/usr/bin/printf '{}\n' > "$work/empty-candidate.json" || emit_error E_RUNTIME
# Caller input must be one parseable JSON root before any contract runs, so a
# broken file reads as a parse error and nothing else.
single_root "$input_document" || emit_error E_PARSE
seed_docs_file="$work/empty-observations.json"
result_docs_file="$work/empty-observations.json"
[ "$(run_program validate-catalog "$work/empty-observations.json" \
      "$work/empty-candidate.json" 2>/dev/null)" = true ] || emit_error E_STALE
record_observation() {
  if [ "$i" -gt 0 ]; then /usr/bin/printf ',' >> "$observations" || emit_error E_RUNTIME; fi
  /usr/bin/printf '%s' "$1" >> "$observations" || emit_error E_RUNTIME
}

# Orchestrator snapshots replay through the real state scanner. The scanner
# finds its jq under TMPDIR and its core under its own repo root, so both are
# staged inside the private runtime; nothing outside it is read.
replay_scanner_cases() {
  local platform jq_asset scanner_tmp snapshot_doc repository_id commit_id
  local scan_out scan_err scan_status classification token observation
  platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m) || emit_error E_RUNTIME
  case "$platform" in
    Linux:x86_64) jq_asset=jq-linux64 ;;
    Darwin:x86_64|Darwin:arm64) jq_asset=jq-osx-amd64 ;;
    *) emit_error E_RUNTIME ;;
  esac
  scanner_tmp="$work/scanner-tmp"
  /bin/mkdir -m 0700 "$scanner_tmp" "$scanner_tmp/ystack-portable-core-jq16" ||
    emit_error E_RUNTIME
  /bin/cp "$jq_bin" "$scanner_tmp/ystack-portable-core-jq16/$jq_asset" || emit_error E_RUNTIME
  /bin/chmod 0500 "$scanner_tmp/ystack-portable-core-jq16/$jq_asset" || emit_error E_RUNTIME
  i=0
  while [ "$i" -lt "$case_count" ]; do
    case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input") || emit_error E_RUNTIME
    snapshot_doc="$work/snapshot-$i.json"
    "$jq_bin" -S -c ".body.cases[$i].snapshot.content" "$input" > "$snapshot_doc" ||
      emit_error E_RUNTIME
    [ "$(sha256_path "$snapshot_doc")" = \
      "$("$jq_bin" -r ".body.cases[$i].snapshot.sha256" "$input")" ] || emit_error E_RELATION
    repository_id=$("$jq_bin" -r ".body.cases[$i].expected_revision.repository_id" "$input") ||
      emit_error E_RUNTIME
    commit_id=$("$jq_bin" -r ".body.cases[$i].expected_revision.commit_id" "$input") ||
      emit_error E_RUNTIME
    scan_out="$work/scan-$i.out"
    scan_err="$work/scan-$i.err"
    /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin TMPDIR="$scanner_tmp" \
      /bin/bash "$scanner" scan "$repository_id" "$commit_id" "$snapshot_doc" \
      </dev/null >"$scan_out" 2>"$scan_err"
    scan_status=$?
    if [ "$scan_status" -eq 0 ]; then
      [ ! -s "$scan_err" ] || emit_error E_RUNTIME
      classification=$("$jq_bin" -S -c '
        if (.body.classifications | length) == 1 then
          .body.classifications[0] |
          {action:.recovery.action,class:.class,reason_id:.recovery.reason_id}
        else empty end' "$scan_out") || emit_error E_RUNTIME
      [ -n "$classification" ] || emit_error E_RELATION
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" \
        --argjson classification "$classification" \
        '{case_id:$case_id,disposition:"observed",
          classification:{state:"present",value:$classification},
          error_token:{state:"absent"}}') || emit_error E_RUNTIME
    else
      [ ! -s "$scan_out" ] || emit_error E_RUNTIME
      token=$(/bin/cat "$scan_err" 2>/dev/null) || emit_error E_RUNTIME
      case "$token" in
        E_CANONICAL|E_LIMIT|E_PARSE|E_RELATION|E_RUNTIME|E_SHAPE|E_STALE|E_USAGE) ;;
        *) emit_error E_RUNTIME ;;
      esac
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --arg token "$token" \
        '{case_id:$case_id,disposition:"rejected",classification:{state:"absent"},
          error_token:{state:"present",value:$token}}') || emit_error E_RUNTIME
    fi
    record_observation "$observation"
    i=$((i + 1))
  done
}

# Decision claims replay through the real risk-gates evaluator, which regenerates
# the duty-separation evaluation and validates the core tuple from a mirror it
# builds out of this runtime. Verdict and reason set are recorded; a refusal by
# its one token.
replay_risk_gates_cases() {
  local risk_tmp doc member eval_out eval_err eval_status evaluation observation token
  local -a docs
  risk_tmp="$work/risk-gates-tmp"
  /bin/mkdir -m 0700 "$risk_tmp" || emit_error E_RUNTIME
  i=0
  while [ "$i" -lt "$case_count" ]; do
    case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input") || emit_error E_RUNTIME
    docs=()
    for member in policy_set request resolved_profile result duty claim; do
      doc="$work/risk-$member-$i.json"
      "$jq_bin" -S -c ".body.cases[$i].inputs.$member.content" "$input" > "$doc" ||
        emit_error E_RUNTIME
      [ "$(sha256_path "$doc")" = \
        "$("$jq_bin" -r ".body.cases[$i].inputs.$member.sha256" "$input")" ] ||
        emit_error E_RELATION
      docs+=("$doc")
    done
    eval_out="$work/risk-$i.out"
    eval_err="$work/risk-$i.err"
    /usr/bin/env -i LC_ALL=C PATH="$runtime/bin:/usr/bin:/bin" TMPDIR="$risk_tmp" \
      /bin/bash "$risk_gates_evaluator" evaluate "${docs[@]}" \
      </dev/null >"$eval_out" 2>"$eval_err"
    eval_status=$?
    if [ "$eval_status" -eq 0 ]; then
      [ ! -s "$eval_err" ] || emit_error E_RUNTIME
      evaluation=$("$jq_bin" -S -c '{reason_ids:.body.reason_ids,verdict:.body.verdict}' \
        "$eval_out") || emit_error E_RUNTIME
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" \
        --argjson evaluation "$evaluation" \
        '{case_id:$case_id,disposition:"evaluated",
          evaluation:{state:"present",value:$evaluation},
          error_token:{state:"absent"}}') || emit_error E_RUNTIME
    else
      [ ! -s "$eval_out" ] || emit_error E_RUNTIME
      token=$(/bin/cat "$eval_err" 2>/dev/null) || emit_error E_RUNTIME
      case "$token" in
        E_DUTY|E_LIMIT|E_RELATION|E_RUNTIME|E_USAGE) ;;
        *) emit_error E_RUNTIME ;;
      esac
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --arg token "$token" \
        '{case_id:$case_id,disposition:"rejected",evaluation:{state:"absent"},
          error_token:{state:"present",value:$token}}') || emit_error E_RUNTIME
    fi
    record_observation "$observation"
    i=$((i + 1))
  done
}

# Provider snapshots replay through the one default normalizer the case names,
# pure jq with no modules. The generic state, reason, and stale bindings are
# recorded; a refusal is recorded by the normalizer's own error id.
replay_normalizer_cases() {
  local normalizer input_doc norm_out norm_err norm_status normalization token observation
  i=0
  while [ "$i" -lt "$case_count" ]; do
    case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input") || emit_error E_RUNTIME
    normalizer=$("$jq_bin" -r ".body.cases[$i].normalizer" "$input") || emit_error E_RUNTIME
    case "$normalizer" in
      codex-cli-producer|codex-native-reviewer|github-actions-ci|github-forge|gitlab-forge) ;;
      *) emit_error E_SHAPE ;;
    esac
    input_doc="$work/normalizer-input-$i.json"
    "$jq_bin" -S -c ".body.cases[$i].input.content" "$input" > "$input_doc" ||
      emit_error E_RUNTIME
    [ "$(sha256_path "$input_doc")" = \
      "$("$jq_bin" -r ".body.cases[$i].input.sha256" "$input")" ] || emit_error E_RELATION
    norm_out="$work/normalizer-$i.out"
    norm_err="$work/normalizer-$i.err"
    "$jq_bin" -L "$modules" -S -c -f "$runtime/adapters/$normalizer/v1/normalize.jq" "$input_doc" \
      </dev/null >"$norm_out" 2>"$norm_err"
    norm_status=$?
    if [ "$norm_status" -eq 0 ]; then
      [ ! -s "$norm_err" ] || emit_error E_RUNTIME
      # A producer normalizer has no bindings to go stale; its set is empty.
      normalization=$("$jq_bin" -S -c '{reason_id,stale_bindings:(.stale_bindings // []),state}' \
        "$norm_out") || emit_error E_RUNTIME
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" \
        --argjson normalization "$normalization" \
        '{case_id:$case_id,disposition:"normalized",
          normalization:{state:"present",value:$normalization},
          error_token:{state:"absent"}}') || emit_error E_RUNTIME
    else
      [ ! -s "$norm_out" ] || emit_error E_RUNTIME
      token=$(/bin/cat "$norm_err" 2>/dev/null) || emit_error E_RUNTIME
      token=${token##*: }
      case "$token" in
        codex-reviewer.invalid-envelope|codex-reviewer.invalid-snapshot) ;;
        codex-reviewer.invalid-trust-context|github-actions-ci.invalid-envelope) ;;
        github-actions-ci.invalid-snapshot|github-actions-ci.invalid-trust-context) ;;
        github-actions-ci.provider-contradiction|github-forge.invalid-envelope) ;;
        github-forge.invalid-snapshot|github-forge.invalid-trust-context) ;;
        gitlab-forge.invalid-envelope|gitlab-forge.invalid-snapshot) ;;
        gitlab-forge.invalid-trust-context|E_SHAPE|E_STALE|E_TRUST) ;;
        *) emit_error E_RUNTIME ;;
      esac
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --arg token "$token" \
        '{case_id:$case_id,disposition:"rejected",normalization:{state:"absent"},
          error_token:{state:"present",value:$token}}') || emit_error E_RUNTIME
    fi
    record_observation "$observation"
    i=$((i + 1))
  done
}

# Boundary claims replay through the real sandbox-policy evaluator, which finds
# its jq on PATH and its policy beside itself; both come from the private runtime.
replay_sandbox_cases() {
  local sandbox_tmp set_doc duty_doc claim_doc eval_out eval_err eval_status
  local evaluation observation token
  sandbox_tmp="$work/sandbox-tmp"
  /bin/mkdir -m 0700 "$sandbox_tmp" || emit_error E_RUNTIME
  i=0
  while [ "$i" -lt "$case_count" ]; do
    case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input") || emit_error E_RUNTIME
    set_doc="$work/policy-set-$i.json"
    duty_doc="$work/duty-$i.json"
    claim_doc="$work/claim-$i.json"
    for member in policy_set duty claim; do
      case "$member" in
        policy_set) target=$set_doc ;;
        duty) target=$duty_doc ;;
        claim) target=$claim_doc ;;
      esac
      "$jq_bin" -S -c ".body.cases[$i].inputs.$member.content" "$input" > "$target" ||
        emit_error E_RUNTIME
      [ "$(sha256_path "$target")" = \
        "$("$jq_bin" -r ".body.cases[$i].inputs.$member.sha256" "$input")" ] ||
        emit_error E_RELATION
    done
    eval_out="$work/sandbox-$i.out"
    eval_err="$work/sandbox-$i.err"
    /usr/bin/env -i LC_ALL=C PATH="$runtime/bin:/usr/bin:/bin" TMPDIR="$sandbox_tmp" \
      /bin/bash "$sandbox_evaluator" evaluate "$set_doc" "$duty_doc" "$claim_doc" \
      </dev/null >"$eval_out" 2>"$eval_err"
    eval_status=$?
    if [ "$eval_status" -eq 0 ]; then
      [ ! -s "$eval_err" ] || emit_error E_RUNTIME
      evaluation=$("$jq_bin" -S -c '{reason_ids:.body.reason_ids,verdict:.body.verdict}' \
        "$eval_out") || emit_error E_RUNTIME
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" \
        --argjson evaluation "$evaluation" \
        '{case_id:$case_id,disposition:"evaluated",
          evaluation:{state:"present",value:$evaluation},
          error_token:{state:"absent"}}') || emit_error E_RUNTIME
    else
      [ ! -s "$eval_out" ] || emit_error E_RUNTIME
      token=$(/bin/cat "$eval_err" 2>/dev/null) || emit_error E_RUNTIME
      case "$token" in
        E_CANONICAL|E_LIMIT|E_PARSE|E_POLICY_SET|E_RELATION|E_RUNTIME|E_USAGE) ;;
        *) emit_error E_RUNTIME ;;
      esac
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --arg token "$token" \
        '{case_id:$case_id,disposition:"rejected",evaluation:{state:"absent"},
          error_token:{state:"present",value:$token}}') || emit_error E_RUNTIME
    fi
    record_observation "$observation"
    i=$((i + 1))
  done
}

# Planner bundles replay through the real reconciliation planner, pure jq over
# the private modules. Exactly which stage, request, operation, and attempt it
# would deliver, defer, or suppress, and which stages it hands to an operator,
# is recorded; a refusal is recorded by its one token.
replay_planner_cases() {
  local input_doc plan_out plan_err plan_status summary observation
  i=0
  while [ "$i" -lt "$case_count" ]; do
    case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input") || emit_error E_RUNTIME
    input_doc="$work/plan-input-$i.json"
    "$jq_bin" -S -c ".body.cases[$i].input.content" "$input" > "$input_doc" ||
      emit_error E_RUNTIME
    [ "$(sha256_path "$input_doc")" = \
      "$("$jq_bin" -r ".body.cases[$i].input.sha256" "$input")" ] || emit_error E_RELATION
    plan_out="$work/plan-$i.out"
    plan_err="$work/plan-$i.err"
    "$jq_bin" -L "$modules" -S -c -f "$planner" "$input_doc" \
      </dev/null >"$plan_out" 2>"$plan_err"
    plan_status=$?
    if [ "$plan_status" -eq 0 ]; then
      [ ! -s "$plan_err" ] || emit_error E_RUNTIME
      summary=$("$jq_bin" -S -c '
        def item: .delivery_key |
          {attempt_number,operation,request_sha256,stage_key};
        {deliveries:[.body.deliveries[] | item + {delivery_mode}],
         deferred:[.body.deferred[] | item + {reason_id}],
         suppressed:[.body.suppressed[] | item + {reason_id}],
         operator_messages:[.body.operator_messages[] |
           {action:.recovery.action,class,stage_key}]}' "$plan_out") || emit_error E_RUNTIME
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --argjson plan "$summary" \
        '{case_id:$case_id,disposition:"planned",plan:{state:"present",value:$plan},
          error_token:{state:"absent"}}') || emit_error E_RUNTIME
    else
      [ ! -s "$plan_out" ] || emit_error E_RUNTIME
      case "$(/bin/cat "$plan_err" 2>/dev/null)" in
        *E_RECONCILIATION_INPUT*) ;;
        *) emit_error E_RUNTIME ;;
      esac
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" \
        '{case_id:$case_id,disposition:"rejected",plan:{state:"absent"},
          error_token:{state:"present",value:"E_RECONCILIATION_INPUT"}}') || emit_error E_RUNTIME
    fi
    record_observation "$observation"
    i=$((i + 1))
  done
}

# Canonical documents for one case, each checked against its recorded digest
# before the core sees it. The core is the only judge; the driver only records.
replay_stage_run_cases() {
resolved_doc="$work/resolved.json"
"$jq_bin" -S -c '.body.shared.resolved_profile.content' "$input" > "$resolved_doc" ||
  emit_error E_RUNTIME
[ "$(sha256_path "$resolved_doc")" = \
  "$("$jq_bin" -r '.body.shared.resolved_profile.sha256' "$input")" ] ||
  emit_error E_RELATION
i=0
while [ "$i" -lt "$case_count" ]; do
  case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input") || emit_error E_RUNTIME
  role=$("$jq_bin" -r ".body.cases[$i].request_role" "$input") || emit_error E_RUNTIME
  case "$role" in producer|reviewer|verifier) ;; *) emit_error E_SHAPE ;; esac
  request_doc="$work/request-$i.json"
  result_doc="$work/result-$i.json"
  "$jq_bin" -S -c --arg role "$role" '.body.shared.requests[$role].content' \
    "$input" > "$request_doc" || emit_error E_RUNTIME
  [ "$(sha256_path "$request_doc")" = \
    "$("$jq_bin" -r --arg role "$role" '.body.shared.requests[$role].sha256' "$input")" ] ||
    emit_error E_RELATION
  "$jq_bin" -S -c ".body.cases[$i].result.content" "$input" > "$result_doc" ||
    emit_error E_RUNTIME
  [ "$(sha256_path "$result_doc")" = \
    "$("$jq_bin" -r ".body.cases[$i].result.sha256" "$input")" ] || emit_error E_RELATION
  status_value=$("$jq_bin" -r '.body.status // empty' "$result_doc") || emit_error E_RUNTIME

  core_err="$work/core-$i.err"
  core_out="$work/core-$i.out"
  /usr/bin/env -i LC_ALL=C PATH="$runtime/bin:/usr/bin:/bin" TMPDIR="$work" \
    /bin/bash "$core_front_door" validate-stage-run \
    "$request_doc" "$resolved_doc" "$result_doc" </dev/null 3>&- >"$core_out" 2>"$core_err"
  core_status=$?
  [ ! -s "$core_out" ] || emit_error E_RUNTIME
  if [ "$core_status" -eq 0 ]; then
    [ ! -s "$core_err" ] || emit_error E_RUNTIME
    case "$status_value" in
      blocked|cancelled|completed|failed|skipped|stale) ;;
      *) emit_error E_RELATION ;;
    esac
    observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --arg status "$status_value" \
      '{case_id:$case_id,disposition:"accepted",status:{state:"present",value:$status},
        error_token:{state:"absent"}}') || emit_error E_RUNTIME
  else
    token=$(/bin/cat "$core_err" 2>/dev/null) || emit_error E_RUNTIME
    case "$token" in
      E_CANONICAL|E_LIMIT|E_PARSE|E_REF|E_RELATION|E_RUNTIME|E_SHAPE|E_USAGE) ;;
      *) emit_error E_RUNTIME ;;
    esac
    observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --arg token "$token" \
      '{case_id:$case_id,disposition:"rejected",status:{state:"absent"},
        error_token:{state:"present",value:$token}}') || emit_error E_RUNTIME
  fi
  record_observation "$observation"
  i=$((i + 1))
done
}

# One run over the seed set named by $input, into $work/run-result.json. Run mode
# calls it once; dashboard mode calls it once per supplied pair to reproduce
# the supplied result.
produce_result() {
  seed_docs_file=$input
  [ "$(run_program validate-seed-set "$work/empty-observations.json" \
        "$work/empty-candidate.json" 2>/dev/null)" = true ] || emit_error E_SHAPE

  seed_source=$("$jq_bin" -r '.body.seed_source // empty' "$input") || emit_error E_RUNTIME
  case "$seed_source" in
    adapters.provider-normalizers.v1|control.risk-gates.v1|control.sandbox-policy.v1) ;;
    core.stage-run.v2) ;;
    orchestrator.reconciliation-plan.v1|orchestrator.state-scanner.v1) ;;
    *) emit_error E_SHAPE ;;
  esac
  case_count=$("$jq_bin" -r '.body.cases | length' "$input") || emit_error E_RUNTIME
  [[ "$case_count" =~ ^[1-9][0-9]?$ ]] && [ "$case_count" -le 64 ] || emit_error E_SHAPE
  observations="$work/observations.json"
  /usr/bin/printf '[' > "$observations" || emit_error E_RUNTIME

  case "$seed_source" in
    core.stage-run.v2) replay_stage_run_cases ;;
    orchestrator.state-scanner.v1) replay_scanner_cases ;;
    control.sandbox-policy.v1) replay_sandbox_cases ;;
    control.risk-gates.v1) replay_risk_gates_cases ;;
    adapters.provider-normalizers.v1) replay_normalizer_cases ;;
    *) replay_planner_cases ;;
  esac
  /usr/bin/printf ']\n' >> "$observations" || emit_error E_RUNTIME

  result="$work/run-result.json"
  run_program build-run-result "$observations" "$work/empty-candidate.json" \
    > "$result" 2>/dev/null || emit_error E_RUNTIME
  [ "$(run_program validate-run-result "$observations" "$result" 2>/dev/null)" = true ] ||
    emit_error E_RUNTIME
}

if [ "$mode" = run ]; then
  produce_result
  verify_runtime || emit_error E_STALE
  /bin/cat "$work/run-result.json" || emit_error E_RUNTIME
else
  run_dashboard
fi
