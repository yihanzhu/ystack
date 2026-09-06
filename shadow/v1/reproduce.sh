#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_STALE|E_RELATION| \
    E_READ_ONLY|E_WORKSPACE)
      /usr/bin/printf '%s\n' "$1" >&2
      ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

physical_regular() {
  local candidate=$1 parent physical
  case "$candidate" in /*) ;; *) return 1 ;; esac
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  parent=${candidate%/*}
  [ -n "$parent" ] || parent=/
  physical=$(CDPATH='' cd -P -- "$parent" 2>/dev/null && pwd -P) || return 1
  [ "$candidate" = "$physical/${candidate##*/}" ]
}

physical_dir() {
  local candidate=$1 physical
  case "$candidate" in /*) ;; *) return 1 ;; esac
  [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 1
  physical=$(CDPATH='' cd -P -- "$candidate" 2>/dev/null && pwd -P) || return 1
  [ "$candidate" = "$physical" ]
}

empty_private_dir() {
  physical_dir "$1" &&
    [ "$(/usr/bin/stat -f '%Lp' "$1" 2>/dev/null ||
        /usr/bin/stat -c '%a' "$1" 2>/dev/null)" = 700 ] &&
    [ -z "$(/usr/bin/find "$1" -mindepth 1 -print -quit 2>/dev/null)" ]
}

overlaps() {
  if [ "$1" = / ] || [ "$2" = / ]; then
    return 0
  fi
  case "$1/" in "$2/"*) return 0 ;; esac
  case "$2/" in "$1/"*) return 0 ;; esac
  return 1
}

check_disjoint() {
  overlaps "$1" "$2" && emit_error E_WORKSPACE
  return 0
}

[ "$#" -eq 12 ] && [ "$1" = reproduce ] || emit_error E_USAGE
shift
incident=$1
claim=$2
policy_set=$3
duty=$4
materialization_input=$5
source_git_dir=$6
candidate_root=$7
scratch_root=$8
state_dir=$9
closure_helper=${10}
caller_jq=${11}
for supplied in "$@"; do
  case "$supplied" in /*) ;; *) emit_error E_USAGE ;; esac
done
for regular in "$incident" "$claim" "$policy_set" "$duty" \
  "$materialization_input" "$closure_helper" "$caller_jq"; do
  physical_regular "$regular" || emit_error E_RUNTIME
done
[ -x "$closure_helper" ] && [ -x "$caller_jq" ] || emit_error E_RUNTIME
physical_dir "$source_git_dir" || emit_error E_WORKSPACE
for workspace in "$candidate_root" "$scratch_root" "$state_dir"; do
  empty_private_dir "$workspace" || emit_error E_WORKSPACE
done
check_disjoint "$source_git_dir" "$candidate_root"
check_disjoint "$source_git_dir" "$scratch_root"
check_disjoint "$source_git_dir" "$state_dir"
check_disjoint "$candidate_root" "$scratch_root"
check_disjoint "$candidate_root" "$state_dir"
check_disjoint "$scratch_root" "$state_dir"

self=${BASH_SOURCE[0]}
case "$self" in /*) ;; *) self="$(pwd -P)/$self" ;; esac
[ -f "$self" ] && [ ! -L "$self" ] || emit_error E_RUNTIME
self_dir=$(CDPATH='' cd -P -- "${self%/*}" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
self="$self_dir/${self##*/}"
[ "$self" = "$self_dir/reproduce.sh" ] || emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$self_dir/../.." 2>/dev/null && pwd -P) || emit_error E_RUNTIME
[ "$self_dir" = "$repo/shadow/v1" ] || emit_error E_RUNTIME
program="$self_dir/incident-record.jq"
registry="$self_dir/shadow-environments.json"
sandbox_evaluator="$repo/control/v1/evaluate-sandbox.sh"
trace_validator="$repo/telemetry/v1/validate-trace-ledger.sh"
materializer="$repo/adapters/local-git-materializer/v1/materialize.sh"
for component in "$self" "$program" "$registry" "$sandbox_evaluator" \
  "$trace_validator" "$materializer"; do
  physical_regular "$component" || emit_error E_RUNTIME
done

case "$(/usr/bin/uname -s):$(/usr/bin/uname -m)" in
  Darwin:*) jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) emit_error E_RUNTIME ;;
esac
[ "$(sha256_path "$caller_jq")" = "$jq_sha" ] || emit_error E_RUNTIME

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-shadow-reproduce.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
/bin/chmod 0700 "$scratch" || emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM
/bin/mkdir -m 0700 "$scratch/bin" || emit_error E_RUNTIME

snapshot_bounded() {
  local source=$1 target=$2 limit=$3 size
  /bin/dd if="$source" of="$target" bs=$((limit + 1)) count=1 2>/dev/null ||
    emit_error E_RUNTIME
  size=$(/usr/bin/wc -c <"$target" | /usr/bin/tr -d ' ') || emit_error E_RUNTIME
  [ "$size" -le "$limit" ] || emit_error E_LIMIT
}

jq_bin="$scratch/bin/jq"
snapshot_bounded "$caller_jq" "$jq_bin" 16777216
/bin/chmod 0500 "$jq_bin" || emit_error E_RUNTIME
[ "$(sha256_path "$jq_bin")" = "$jq_sha" ] &&
  [ "$("$jq_bin" --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME

canonical_json() {
  local raw=$1 bom
  bom=$(/usr/bin/od -An -tx1 -N3 "$raw" 2>/dev/null | /usr/bin/tr -d ' \n') ||
    emit_error E_RUNTIME
  [ "$bom" != efbbbf ] || emit_error E_PARSE
  "$jq_bin" . "$raw" >/dev/null 2>&1 || emit_error E_PARSE
  [ "$("$jq_bin" -s 'length' "$raw" 2>/dev/null)" -eq 1 ] || emit_error E_PARSE
  "$jq_bin" -S -c . "$raw" >"$raw.canonical" 2>/dev/null || emit_error E_PARSE
  /usr/bin/cmp -s "$raw" "$raw.canonical" || emit_error E_CANONICAL
}

snapshot_bounded "$incident" "$scratch/incident.json" 262144
snapshot_bounded "$claim" "$scratch/claim.json" 1048576
snapshot_bounded "$registry" "$scratch/registry.json" 262144
snapshot_bounded "$materialization_input" "$scratch/materialize-input.json" 8388608
snapshot_bounded "$policy_set" "$scratch/policy-set.json" 1048576
snapshot_bounded "$duty" "$scratch/duty.json" 1048576
snapshot_bounded "$program" "$scratch/incident-record.jq" 262144
for bounded in incident claim registry materialize-input; do
  canonical_json "$scratch/$bounded.json"
done
incident_sha=$(sha256_path "$scratch/incident.json") || emit_error E_RUNTIME
claim_sha=$(sha256_path "$scratch/claim.json") || emit_error E_RUNTIME
registry_sha=$(sha256_path "$scratch/registry.json") || emit_error E_RUNTIME
input_sha=$(sha256_path "$scratch/materialize-input.json") || emit_error E_RUNTIME
policy_sha=$(sha256_path "$scratch/policy-set.json") || emit_error E_RUNTIME
duty_sha=$(sha256_path "$scratch/duty.json") || emit_error E_RUNTIME
program_sha=$(sha256_path "$scratch/incident-record.jq") || emit_error E_RUNTIME

shape=$("$jq_bin" -r --arg operation shape --arg record_sha "$incident_sha" \
  -f "$scratch/incident-record.jq" "$scratch/incident.json" 2>/dev/null) ||
  emit_error E_RUNTIME
[ -z "$shape" ] || emit_error E_SHAPE
"$jq_bin" -e '
  .schema_version == 1 and .kind == "shadow_environment_registry" and
  .body.activation_state == "inactive" and
  (.body.environments | type == "array" and length >= 1 and length <= 64 and
   all(.[];.environment_id | type == "string" and
     test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z")))
' "$scratch/registry.json" >/dev/null 2>&1 || emit_error E_RELATION

incident_id=$("$jq_bin" -r '.id' "$scratch/incident.json") || emit_error E_RUNTIME
repository_id=$("$jq_bin" -r '.body.target_repository_id' "$scratch/incident.json") ||
  emit_error E_RUNTIME
hash_algorithm=$("$jq_bin" -r '.body.git_revision_ref.hash_algorithm' \
  "$scratch/incident.json") || emit_error E_RUNTIME
commit_id=$("$jq_bin" -r '.body.git_revision_ref.commit_id' "$scratch/incident.json") ||
  emit_error E_RUNTIME
observed_at=$("$jq_bin" -r '.body.observed_at' "$scratch/incident.json") ||
  emit_error E_RUNTIME
reporter=$("$jq_bin" -r '.body.reporter_actor_ref' "$scratch/incident.json") ||
  emit_error E_RUNTIME
check_kind=$("$jq_bin" -r '.body.failing_check.kind' "$scratch/incident.json") ||
  emit_error E_RUNTIME
check_path=$("$jq_bin" -r '.body.failing_check.path // ""' "$scratch/incident.json") ||
  emit_error E_RUNTIME
expected_sha=$("$jq_bin" -r '.body.failing_check.expected_sha256 // ""' \
  "$scratch/incident.json") || emit_error E_RUNTIME

environment_id=$("$jq_bin" -r '
  if type == "object" and (.id | type == "string") and
     (.id | test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z")) and
     .kind == "execution_environment_claim"
  then .id else "" end
' "$scratch/claim.json") || emit_error E_RUNTIME
[ -n "$environment_id" ] || emit_error E_SHAPE

# The read-only guards hold for every run, whatever the environment verdict:
# a materialization input that carries patch bytes or allows network is refused
# outright, never recorded as an inconclusive shadow.
"$jq_bin" -e --arg repository "$repository_id" --arg algorithm "$hash_algorithm" \
  --arg commit "$commit_id" '
  .stage_request.content.body as $body |
  $body.target_repository_id == $repository and
  $body.target_revision.value.repository_id == $repository and
  $body.target_revision.value.hash_algorithm == $algorithm and
  $body.target_revision.value.commit_id == $commit
' "$scratch/materialize-input.json" >/dev/null 2>&1 || emit_error E_STALE
"$jq_bin" -e '
  ([.payloads[] | select(.input_id == "input.producer-patch") | .data] == [""]) and
  ([.trust_context.verified_payloads[] |
    select(.input_id == "input.producer-patch") | .content.data] == [""]) and
  .stage_request.content.body.operation.arguments.network_mode == "deny"
' "$scratch/materialize-input.json" >/dev/null 2>&1 || emit_error E_READ_ONLY

outcome=inconclusive
reason=environment.unlisted
environment_result=result.environment-refused
evaluation_section='{"reason_id":"environment.unlisted","state":"absent"}'
materialization_section='{"reason_id":"materialization.not-attempted","state":"absent"}'
execution_section='{"reason_id":"check.not-attempted","state":"absent"}'
adapter_fact=none
tool_fact=none

if "$jq_bin" -e --arg id "$environment_id" \
   '[.body.environments[] | select(.environment_id == $id)] | length == 1' \
   "$scratch/registry.json" >/dev/null 2>&1; then
  evaluation_status=0
  PATH="$scratch/bin:/usr/bin:/bin" "$sandbox_evaluator" evaluate \
    "$scratch/policy-set.json" "$scratch/duty.json" "$scratch/claim.json" \
    >"$scratch/sandbox.json" 2>/dev/null ||
    evaluation_status=$?
  if [ "$evaluation_status" -ne 0 ]; then
    reason=environment.evaluation-refused
    evaluation_section='{"reason_id":"environment.evaluation-refused","state":"absent"}'
  else
    sandbox_sha=$(sha256_path "$scratch/sandbox.json") || emit_error E_RUNTIME
    evaluation_section=$("$jq_bin" -S -c --arg sha "$sandbox_sha" '{
      state:"present",
      value:{verdict:.body.verdict,reason_ids:.body.reason_ids,
        evaluation_ref:{content_id:"shadow-sandbox-evaluation",
          media_type:"application/vnd.ystack.control-evaluation+json",sha256:$sha}}}' \
      "$scratch/sandbox.json") || emit_error E_RUNTIME
    if "$jq_bin" -e '.body.verdict == "satisfied"' "$scratch/sandbox.json" \
       >/dev/null 2>&1; then
      reason=environment.satisfied
      environment_result=result.environment-satisfied
    else
      reason=environment.not-satisfied
    fi
  fi
fi

if [ "$reason" = environment.satisfied ] && [ "$check_kind" != file-digest ]; then
  reason=check.not-runnable
fi

if [ "$reason" = environment.satisfied ]; then
  materialize_status=0
  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /bin/bash "$materializer" materialize \
    "$scratch/materialize-input.json" "$repository_id" "$source_git_dir" \
    "$candidate_root" "$scratch_root" "$closure_helper" "$jq_bin" \
    >"$scratch/materialize.json" 2>/dev/null || materialize_status=$?
  if [ "$materialize_status" -ne 0 ]; then
    reason=materialization.refused
    materialization_section='{"reason_id":"materialization.refused","state":"absent"}'
  else
    "$jq_bin" -S -c '.stage_result' "$scratch/materialize.json" \
      >"$scratch/stage-result.json" 2>/dev/null || emit_error E_RUNTIME
    stage_result_sha=$(sha256_path "$scratch/stage-result.json") || emit_error E_RUNTIME
    "$jq_bin" -j '.payloads[0].data' "$scratch/materialize.json" \
      >"$scratch/receipt.json" 2>/dev/null || emit_error E_RUNTIME
    "$jq_bin" -e --arg algorithm "$hash_algorithm" --arg commit "$commit_id" \
      --arg repository "$repository_id" '
      .source == {repository_id:$repository,hash_algorithm:$algorithm,
        commit_id:$commit,tree_id:.candidate.tree_id} and
      .candidate.commit_id == $commit and .changed_paths.count == 0
    ' "$scratch/receipt.json" >/dev/null 2>&1 || emit_error E_RELATION
    materialization_section=$("$jq_bin" -S -c --arg sha "$stage_result_sha" \
      --slurpfile result "$scratch/stage-result.json" '{
      state:"present",
      value:{adapter_id:"adapter.local-git-materializer.v1",
        outcome:$result[0].body.outcome.value,
        source:.source,candidate:.candidate,
        stage_result_ref:{schema_version:2,kind:"stage_result",id:$result[0].id,
          sha256:$sha}}}' "$scratch/receipt.json") || emit_error E_RUNTIME
    adapter_fact=adapter.local-git-materializer.v1
    candidate_tree=$("$jq_bin" -r '.candidate.tree_id' "$scratch/receipt.json") ||
      emit_error E_RUNTIME
    reason=check.completed
  fi
fi

if [ "$reason" = check.completed ]; then
  repository="$candidate_root/repository.git"
  git_env=(/usr/bin/env -i HOME="$scratch" TMPDIR="$scratch" PATH=/usr/bin:/bin
    LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
    GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0
    GIT_OPTIONAL_LOCKS=0)
  # Only a blob can be digest-checked; a directory or other object at the
  # path is an unreadable check, not a failed run.
  object_type=$("${git_env[@]}" /usr/bin/git --no-replace-objects \
    --git-dir="$repository" cat-file -t "$candidate_tree:$check_path" 2>/dev/null) || :
  blob_size=''
  if [ "${object_type:-}" = blob ]; then
    blob_size=$("${git_env[@]}" /usr/bin/git --no-replace-objects \
      --git-dir="$repository" cat-file -s "$candidate_tree:$check_path" 2>/dev/null) || :
  fi
  case "${blob_size:-}" in
    ''|*[!0-9]*) blob_size='' ;;
    *) [ "${#blob_size}" -le 9 ] && [ "$blob_size" -le 1048576 ] || blob_size='' ;;
  esac
  if [ -z "$blob_size" ]; then
    reason=check.unreadable
    execution_section='{"reason_id":"check.unreadable","state":"absent"}'
  else
    "${git_env[@]}" /usr/bin/git --no-replace-objects --git-dir="$repository" \
      cat-file blob "$candidate_tree:$check_path" >"$scratch/blob" 2>/dev/null ||
      emit_error E_RUNTIME
    [ "$(/usr/bin/wc -c <"$scratch/blob" | /usr/bin/tr -d ' ')" = "$blob_size" ] ||
      emit_error E_RUNTIME
    observed_sha=$(sha256_path "$scratch/blob") || emit_error E_RUNTIME
    tool_fact=tool.git-blob-digest
    if [ "$observed_sha" = "$expected_sha" ]; then
      outcome=no-change
      reason=check.passed-at-revision
    else
      outcome=reproduced
      reason=check.failed-at-revision
    fi
    execution_section=$("$jq_bin" -S -c -n --arg observed "$observed_sha" \
      --arg expected "$expected_sha" --arg tool "$tool_fact" '{
      state:"present",
      value:{tool_id:$tool,observed_sha256:$observed,
        matches_expected:($observed == $expected)}}') || emit_error E_RUNTIME
  fi
fi

ledger_unsealed="$scratch/ledger-unsealed.json"
"$jq_bin" -S -c -n --arg session "$incident_id" --arg observed_at "$observed_at" \
  --arg incident_sha "$incident_sha" --arg claim_sha "$claim_sha" \
  --arg environment "$environment_id" --arg reporter "$reporter" \
  --arg environment_result "$environment_result" --arg outcome "$outcome" \
  --arg adapter "$adapter_fact" --arg tool "$tool_fact" '
  def incident_ref: {content_id:"shadow-incident-record",
    media_type:"application/vnd.ystack.shadow-incident-record+json",
    sha256:$incident_sha};
  def claim_ref: {content_id:"shadow-environment-claim",
    media_type:"application/vnd.ystack.control-execution-environment-claim+json",
    sha256:$claim_sha};
  def recorded($value;$ref): {state:"recorded",value:$value,source_ref:$ref};
  def unavailable($reason): {state:"unavailable",reason_id:$reason};
  def optional($value;$ref):
    if $value == "none" then {state:"not-applicable"} else recorded($value;$ref) end;
  def facts($stage;$gate;$result;$adapter_value;$tool_value): {
    adapter:optional($adapter_value;incident_ref),
    cost_microunits:unavailable("cost.not-measured"),
    execution_environment:recorded($environment;claim_ref),
    gate:optional($gate;claim_ref),
    identity:recorded($reporter;incident_ref),
    initiative:recorded($session;incident_ref),
    latency_ms:unavailable("latency.not-measured"),
    result:recorded($result;incident_ref),
    stage:recorded($stage;incident_ref),
    status:recorded("status.completed";incident_ref),
    task_class:recorded("task.shadow-incident-reproduction";incident_ref),
    tool:optional($tool_value;incident_ref),
    workflow:recorded("workflow.shadow-incident-reproduction";incident_ref)};
  def event($id;$sequence;$type;$facts): {
    schema_version:1,kind:"telemetry_trace_event",id:$id,session_id:$session,
    attempt_id:"attempt.shadow-reproduce",trace_id:"trace.shadow-reproduce",
    sequence:$sequence,prior_digest:null,occurred_at:$observed_at,event_type:$type,
    facts:$facts,record_digest:("0"*64)};
  {schema_version:1,kind:"telemetry_trace_ledger",id:"shadow-trace-ledger",
   body:{session_id:$session,attempt_id:"attempt.shadow-reproduce",
     trace_ids:["trace.shadow-reproduce"],
     events:[
       event("event.shadow-environment";0;"shadow.environment-evaluated";
         facts("stage.shadow-environment";"gate.sandbox-policy";$environment_result;
           "none";"none")),
       event("event.shadow-outcome";1;"shadow.outcome-recorded";
         facts("stage.shadow-reproduce";"none";("result." + $outcome);$adapter;$tool))],
     seal:{algorithm:"sha256",canonicalization:"jq-1.6-sort-compact-line",
       event_count:0,first_digest:("0"*64),final_digest:("0"*64)}}}
' >"$ledger_unsealed" || emit_error E_RUNTIME

sealing="$scratch/sealing.json"
/bin/cp "$ledger_unsealed" "$sealing" || emit_error E_RUNTIME
event_count=$("$jq_bin" -r '.body.events | length' "$sealing") || emit_error E_RUNTIME
prior=''
first=''
index=0
while [ "$index" -lt "$event_count" ]; do
  if [ "$index" -eq 0 ]; then
    "$jq_bin" -S -c --argjson i "$index" '.body.events[$i].prior_digest = null' \
      "$sealing" >"$sealing.next" || emit_error E_RUNTIME
  else
    "$jq_bin" -S -c --argjson i "$index" --arg prior "$prior" \
      '.body.events[$i].prior_digest = $prior' "$sealing" >"$sealing.next" ||
      emit_error E_RUNTIME
  fi
  /bin/mv "$sealing.next" "$sealing" || emit_error E_RUNTIME
  "$jq_bin" -S -c --argjson i "$index" '.body.events[$i] | del(.record_digest)' \
    "$sealing" >"$scratch/event.json" || emit_error E_RUNTIME
  digest=$(sha256_path "$scratch/event.json") || emit_error E_RUNTIME
  [ -n "$first" ] || first=$digest
  "$jq_bin" -S -c --argjson i "$index" --arg digest "$digest" \
    '.body.events[$i].record_digest = $digest' "$sealing" >"$sealing.next" ||
    emit_error E_RUNTIME
  /bin/mv "$sealing.next" "$sealing" || emit_error E_RUNTIME
  prior=$digest
  index=$((index + 1))
done
ledger="$scratch/trace-ledger.json"
"$jq_bin" -S -c --argjson count "$event_count" --arg first "$first" --arg final "$prior" \
  '.body.seal.event_count = $count | .body.seal.first_digest = $first |
   .body.seal.final_digest = $final' "$sealing" >"$ledger" || emit_error E_RUNTIME
PATH="$scratch/bin:/usr/bin:/bin" "$trace_validator" validate "$incident_id" \
  attempt.shadow-reproduce "$ledger" >"$scratch/trace-receipt.json" 2>/dev/null ||
  emit_error E_RELATION
ledger_sha=$(sha256_path "$ledger") || emit_error E_RUNTIME

record="$scratch/shadow-record.json"
"$jq_bin" -S -c -n --arg id "$incident_id" --arg outcome "$outcome" \
  --arg reason "$reason" --arg observed_at "$observed_at" \
  --arg incident_sha "$incident_sha" --arg claim_sha "$claim_sha" \
  --arg registry_sha "$registry_sha" --arg environment "$environment_id" \
  --arg ledger_sha "$ledger_sha" \
  --slurpfile incident "$scratch/incident.json" \
  --argjson evaluation "$evaluation_section" \
  --argjson materialization "$materialization_section" \
  --argjson execution "$execution_section" '
  {schema_version:1,kind:"shadow_reproduction_record",id:$id,
   body:{
     activation_state:"inactive",
     authority:"none",
     deploy_authority:"none",
     effects:["caller-disposable-candidate-repository"],
     evaluation_mode:"observation-only",
     shadow:true,
     qualification:{state:"unavailable",reason_id:"shadow.unqualified"},
     outcome:$outcome,
     reason_id:$reason,
     observed_at:$observed_at,
     target_repository_id:$incident[0].body.target_repository_id,
     git_revision_ref:$incident[0].body.git_revision_ref,
     incident_ref:{content_id:"shadow-incident-record",
       media_type:"application/vnd.ystack.shadow-incident-record+json",
       sha256:$incident_sha},
     environment:{environment_id:$environment,
       claim_ref:{content_id:"shadow-environment-claim",
         media_type:"application/vnd.ystack.control-execution-environment-claim+json",
         sha256:$claim_sha},
       registry_ref:{content_id:"shadow-environment-registry",
         media_type:"application/vnd.ystack.shadow-environment-registry+json",
         sha256:$registry_sha},
       evaluation:$evaluation},
     materialization:$materialization,
     check:{failing_check:$incident[0].body.failing_check,execution:$execution},
     trace_ledger_ref:{content_id:"shadow-trace-ledger",
       media_type:"application/vnd.ystack.telemetry-trace-ledger+json",
       sha256:$ledger_sha}}}
' >"$record" || emit_error E_RUNTIME
"$jq_bin" -e --arg outcome "$outcome" '
  .body.authority == "none" and .body.deploy_authority == "none" and
  .body.shadow == true and .body.activation_state == "inactive" and
  .body.qualification.state == "unavailable" and
  (["inconclusive","no-change","reproduced"] | index($outcome) != null)
' "$record" >/dev/null 2>&1 || emit_error E_RELATION

# Every caller-supplied input must still be the bytes this run snapshotted,
# or the record describes something other than what the caller now holds; the
# check runs before anything is published into the caller's state directory.
[ "$(sha256_path "$incident")" = "$incident_sha" ] &&
  [ "$(sha256_path "$claim")" = "$claim_sha" ] &&
  [ "$(sha256_path "$registry")" = "$registry_sha" ] &&
  [ "$(sha256_path "$materialization_input")" = "$input_sha" ] &&
  [ "$(sha256_path "$policy_set")" = "$policy_sha" ] &&
  [ "$(sha256_path "$duty")" = "$duty_sha" ] &&
  [ "$(sha256_path "$program")" = "$program_sha" ] &&
  [ "$(sha256_path "$jq_bin")" = "$jq_sha" ] || emit_error E_RELATION
/bin/cp "$record" "$state_dir/shadow-record.json" || emit_error E_RUNTIME
/bin/cp "$ledger" "$state_dir/trace-ledger.json" || emit_error E_RUNTIME
/bin/cp "$scratch/trace-receipt.json" "$state_dir/trace-receipt.json" ||
  emit_error E_RUNTIME
/bin/chmod 0400 "$state_dir/shadow-record.json" "$state_dir/trace-ledger.json" \
  "$state_dir/trace-receipt.json" || emit_error E_RUNTIME
if [ -f "$scratch/stage-result.json" ]; then
  /bin/cp "$scratch/stage-result.json" "$state_dir/materialization-result.json" ||
    emit_error E_RUNTIME
  /bin/chmod 0400 "$state_dir/materialization-result.json" || emit_error E_RUNTIME
fi
/bin/cat "$record" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
