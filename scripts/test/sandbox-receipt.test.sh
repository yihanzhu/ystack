#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
program="$root/enforcement/v1/sandbox-receipt.jq"
policy="$root/control/v1/sandbox-policy.json"
decision="$root/control/v1/sandbox-decision.json"
policy_set="$root/control/v1/control-policy-set.json"
registry="$root/shadow/v1/shadow-environments.json"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-sandbox-receipt-test.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() { /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
syn() { /usr/bin/printf '%s' "$1" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'; }

# Bootstraps the shared jq 1.6 cache itself, as
# scripts/test/shadow-slice.test.sh:24-51 does.
platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_asset=jq-linux64
    jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) fail "unsupported host $platform" ;;
esac
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

# Real fixed-file digests and evaluator refs, read (never copied) per
# scripts/test/portable-core-schema.test.sh:899-955.
policy_sha=$(sha256_path "$policy")
decision_sha=$(sha256_path "$decision")
policy_set_sha=$(sha256_path "$policy_set")
evaluator_driver_sha=$("$jq_bin" -r '.body.evaluator.driver_ref.sha256' "$decision")
evaluator_program_sha=$("$jq_bin" -r '.body.evaluator.program_ref.sha256' "$decision")
decision_id=$("$jq_bin" -r '.id' "$decision")
policy_id=$("$jq_bin" -r '.id' "$policy")
policy_set_id=$("$jq_bin" -r '.id' "$policy_set")
env_id=env.local-macos-fixture
entry_file="$tmp/registry-entry.json"
"$jq_bin" -S -c --arg env "$env_id" \
  '.body.environments[] | select(.environment_id==$env)' "$registry" >"$entry_file"
entry_sha=$(sha256_path "$entry_file")
target_repo=$("$jq_bin" -r --arg env "$env_id" \
  '.body.environments[] | select(.environment_id==$env).target_repository_id' "$registry")

# entry_digests: one {environment_id,sha256} per registry entry, in registry
# order, recomputed on every run (the caller hashes; jq 1.6 has no hash
# builtin).
build_entry_digests() {
  local out=$1 count idx entry_tmp sha envid
  count=$("$jq_bin" -r '.body.environments | length' "$registry")
  : >"$tmp/entry-digests.jsonl"
  idx=0
  while [ "$idx" -lt "$count" ]; do
    entry_tmp="$tmp/entry-digest-$idx.json"
    "$jq_bin" -S -c --argjson i "$idx" '.body.environments[$i]' "$registry" >"$entry_tmp"
    sha=$(sha256_path "$entry_tmp")
    envid=$("$jq_bin" -r --argjson i "$idx" '.body.environments[$i].environment_id' "$registry")
    "$jq_bin" -nc --arg e "$envid" --arg s "$sha" '{environment_id:$e,sha256:$s}' \
      >>"$tmp/entry-digests.jsonl"
    idx=$((idx + 1))
  done
  "$jq_bin" -sc '.' "$tmp/entry-digests.jsonl" >"$out"
}

# Synthetic (non-placeholder) fixture content, and the R3.4/R3.5 fragments
# shared byte-for-byte between the receipt and the expectation (R4.2).
store_id=store.fixture
attempt_id=attempt.fixture-0001
scratch_bound=1048576
attempt_json=$("$jq_bin" -nc --arg id "$attempt_id" --arg sha "$(syn launch-request.fixture)" \
  '{attempt_id:$id,attempt_number:1,launch_request_sha256:$sha}')
control_json_of() { # $1=evaluation_sha
  "$jq_bin" -nc --arg p "$policy_sha" --arg d "$decision_sha" --arg s "$policy_set_sha" \
    --arg ed "$evaluator_driver_sha" --arg ep "$evaluator_program_sha" --arg ev "$1" \
    '{policy_sha256:$p,decision_sha256:$d,policy_set_sha256:$s,evaluator_driver_sha256:$ed,
      evaluator_program_sha256:$ep,sandbox_evaluation_sha256:$ev}'
}
subject_json=$("$jq_bin" -nc --arg env "$env_id" --arg entry "$entry_sha" --arg repo "$target_repo" \
  --arg inc "$(syn incident.fixture)" --arg sc "$(syn source-commit.fixture)" \
  --arg st "$(syn source-tree.fixture)" --arg cc "$(syn candidate-commit.fixture)" \
  --arg ct "$(syn candidate-tree.fixture)" --arg prep "$(syn prep-record.fixture)" \
  --arg man "$(syn manifest.fixture)" \
  '{environment_id:$env,environment_entry_sha256:$entry,target_repository_id:$repo,
    incident_sha256:$inc,
    source:{repository_id:"repo.fixture-source",hash_algorithm:"sha256",commit_id:$sc,
      tree_id:$st},
    candidate:{preparation_record_sha256:$prep,manifest_sha256:$man,commit_id:$cc,
      tree_id:$ct}}')
identities_json=$("$jq_bin" -nc \
  --arg a "$(syn identity.guest_init)" --arg b "$(syn identity.guest_kernel)" \
  --arg c "$(syn identity.guest_kernel_config)" --arg d "$(syn identity.guest_supervisor)" \
  --arg e "$(syn identity.host_runtime)" --arg f "$(syn identity.host_supervisor)" \
  --arg g "$(syn identity.image)" --arg h "$(syn identity.toolchain)" \
  --arg i "$(syn identity.verification_instructions)" --arg j "$(syn identity.verifier)" \
  '{guest_init:$a,guest_kernel:$b,guest_kernel_config:$c,guest_supervisor:$d,host_runtime:$e,
    host_supervisor:$f,image:$g,toolchain:$h,verification_instructions:$i,verifier:$j}')

# The evaluation input (a real `sandbox_policy_evaluation`, bound to the real
# fixed-file digests): PR 1 never mutates it.
evaluation="$tmp/evaluation.json"
"$jq_bin" -nSc \
  --arg claim "$(syn claim.fixture)" --arg duty "$(syn duty.fixture)" \
  --arg did "$decision_id" --arg dsha "$decision_sha" --arg pid "$policy_id" \
  --arg psha "$policy_sha" --arg sid "$policy_set_id" --arg ssha "$policy_set_sha" '
def content($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
def docref($v;$kind;$id;$sha): {schema_version:$v,kind:$kind,id:$id,sha256:$sha};
{schema_version:1,kind:"sandbox_policy_evaluation",id:"sandbox-claim.fixture",
 body:{activation_state:"inactive",authority_effect:"none",
   claim_ref:docref(1;"execution_environment_claim";"sandbox-claim.fixture";$claim),
   decision_ref:content($did;"application/vnd.ystack.control-decision+json";$dsha),
   duty_evaluation_ref:docref(1;"duty_separation_evaluation";"result.fixture";$duty),
   enforcement_proof:"declaration-only",evaluation_mode:"observation-only",
   policy_ref:content($pid;"application/vnd.ystack.control-policy+json";$psha),
   policy_set:{id:$sid,sha256:$ssha},qualification_effect:"none",
   reason_ids:["sandbox.declaration-satisfied"],verdict:"satisfied"}}
' >"$evaluation"
evaluation_sha=$(sha256_path "$evaluation")
control_json=$(control_json_of "$evaluation_sha")

# The test-only accepted identity set (R5.2 shape): every fixture identity and
# mechanism, for one environment entry. Never written to the shipped set.
accepted="$tmp/accepted-identities.json"
"$jq_bin" -nSc --arg env "$env_id" --argjson bound "$scratch_bound" \
  --argjson ids "$identities_json" '
{schema_version:1,kind:"sandbox_accepted_identity_set",id:"sandbox.accepted-identities.v1",
 body:{activation_state:"inactive",set_version:"v1",
   environments:[{environment_id:$env,scratch_bytes:$bound,
     identities:($ids|with_entries(.value=[.value])),
     mechanisms:{cpu_time_ms:["mechanism.cpu-time"],wall_time_ms:["mechanism.wall-time"],
       memory_bytes:["mechanism.memory"],output_bytes:["mechanism.output"],
       process_count:["mechanism.process-count"],scratch_bytes:["mechanism.scratch"]}}]}}
' >"$accepted"
accepted_set_sha=$(sha256_path "$accepted")

# build_receipt/build_expectation: the full R3/R4 shape, parametrized only by
# the fields each test case varies. Every other field is the real, correctly
# bound fixture value above, so every control is valid from the start.
build_receipt() {
  local out=$1 cpu_observed=$2 teardown_state=$3 tree_terminated=$4 storage_destroyed=$5 \
    admission=$6 runtime=$7 exit_state=$8 exit_code_json=$9
  shift 9
  local outcome_verdict=$1 outcome_reason_ids_json=$2
  "$jq_bin" -nSc \
    --arg store_id "$store_id" --argjson attempt "$attempt_json" --argjson control "$control_json" \
    --argjson subject "$subject_json" --argjson ids "$identities_json" \
    --arg accepted_set_sha "$accepted_set_sha" --arg stdout "$(syn stdout.fixture)" \
    --arg stderr "$(syn stderr.fixture)" --arg evidence "$(syn evidence.fixture)" \
    --argjson bound "$scratch_bound" --argjson cpu "$cpu_observed" \
    --arg teardown_state "$teardown_state" --argjson terminated "$tree_terminated" \
    --argjson destroyed "$storage_destroyed" --arg admission "$admission" --arg runtime "$runtime" \
    --arg exit_state "$exit_state" --argjson exit_code "$exit_code_json" \
    --arg outcome_verdict "$outcome_verdict" --argjson outcome_reasons "$outcome_reason_ids_json" '
def row($b;$o;$r;$m;$obs):
  {bound:$b,observed:$o,resolution:$r,observation:"complete",enforcement:"hard",
   reached:($o>=$b),mechanism_id:$m,observer:$obs};
{schema_version:1,kind:"sandbox_enforcement_receipt",id:"receipt.fixture-0001",
 body:{contract_version:"v1",
   origin:{producer_role:"host-supervisor",store_id:$store_id,
     accepted_set_sha256:$accepted_set_sha},
   attempt:$attempt,control:$control,subject:$subject,
   identities:($ids|with_entries(.value={state:"observed",sha256:.value})),
   limits:{cpu_time_ms:row(30000;$cpu;1;"mechanism.cpu-time";"guest-supervisor"),
     wall_time_ms:row(60000;2000;1;"mechanism.wall-time";"host-supervisor"),
     memory_bytes:row(536870912;1048576;4096;"mechanism.memory";"guest-supervisor"),
     output_bytes:row(10485760;1024;1;"mechanism.output";"guest-supervisor"),
     process_count:row(32;3;1;"mechanism.process-count";"guest-supervisor"),
     scratch_bytes:row($bound;4096;4096;"mechanism.scratch";"guest-supervisor")},
   teardown:{state:$teardown_state,tree_terminated:$terminated,storage_destroyed:$destroyed},
   lifecycle:{admission:$admission,runtime:$runtime,control_deadline:"met"},
   payload:{stdout_sha256:$stdout,stderr_sha256:$stderr,evidence_manifest_sha256:$evidence,
     exit_state:$exit_state,exit_code:$exit_code},
   timing:{admitted_at:"2026-09-28T00:00:00Z",terminated_at:"2026-09-28T00:01:00Z"},
   outcome:{verdict:$outcome_verdict,reason_ids:$outcome_reasons}}}
' >"$out"
}

build_expectation() {
  "$jq_bin" -nSc --arg store_id "$store_id" --argjson attempt "$attempt_json" \
    --argjson control "$control_json" --argjson subject "$subject_json" '
{schema_version:1,kind:"sandbox_receipt_expectation",id:"expectation.fixture-0001",
 body:{store_id:$store_id,attempt:$attempt,control:$control,subject:$subject}}
' >"$1"
}

expectation="$tmp/expectation.json"
build_expectation "$expectation"
receipt_satisfied="$tmp/receipt-satisfied.json"
build_receipt "$receipt_satisfied" 1000 confirmed true true admitted completed exited 0 \
  satisfied '["enforcement.satisfied"]'
receipt_violated="$tmp/receipt-violated.json"
build_receipt "$receipt_violated" 30000 confirmed true true admitted completed exited 0 \
  violated '["limit.cpu-time-reached"]'
receipt_failed="$tmp/receipt-failed.json"
build_receipt "$receipt_failed" 1000 unconfirmed false false admitted completed exited 0 \
  failed '["failure.teardown"]'

mutate() {
  local source=$1 name=$2 filter=$3
  local target="$tmp/$name.json"
  "$jq_bin" -Sc "$filter" "$source" >"$target"
  printf '%s\n' "$target"
}

# Re-hashes the evaluation and rewrites `sandbox_evaluation_sha256` in the
# receipt and the expectation, so a mutation to the evaluation itself still
# binds on real digests (PR 2/3 cases reuse this).
recompute() {
  local evaluation_in=$1 receipt_in=$2 expectation_in=$3 name=$4 sha
  sha=$(sha256_path "$evaluation_in")
  "$jq_bin" -Sc --arg sha "$sha" '.body.control.sandbox_evaluation_sha256=$sha' \
    "$receipt_in" >"$tmp/$name-receipt.json"
  "$jq_bin" -Sc --arg sha "$sha" '.body.control.sandbox_evaluation_sha256=$sha' \
    "$expectation_in" >"$tmp/$name-expectation.json"
  printf '%s\n%s\n' "$tmp/$name-receipt.json" "$tmp/$name-expectation.json"
}

# The general form, letting a caller substitute any of the five fixed files
# (the malformed-fixed-file cases need this; every other case uses the real
# ones via the `run_program` wrapper below).
run_program_full() {
  local receipt=$1 expectation_in=$2 evaluation_in=$3 policy_in=$4 decision_in=$5 \
    policy_set_in=$6 registry_in=$7 accepted_in=$8 out=$9
  local entry_digests_file="$tmp/entry-digests-run.json"
  build_entry_digests "$entry_digests_file"
  "$jq_bin" -nSc -f "$program" \
    --slurpfile receipt "$receipt" --slurpfile expectation "$expectation_in" \
    --slurpfile evaluation "$evaluation_in" --slurpfile policy "$policy_in" \
    --slurpfile decision "$decision_in" --slurpfile policy_set "$policy_set_in" \
    --slurpfile registry "$registry_in" --slurpfile accepted "$accepted_in" \
    --slurpfile entry_digests "$entry_digests_file" \
    --arg receipt_sha "$(sha256_path "$receipt")" \
    --arg expectation_sha "$(sha256_path "$expectation_in")" \
    --arg evaluation_sha "$(sha256_path "$evaluation_in")" \
    --arg policy_sha "$(sha256_path "$policy_in")" \
    --arg decision_sha "$(sha256_path "$decision_in")" \
    --arg policy_set_sha "$(sha256_path "$policy_set_in")" \
    --arg accepted_set_sha "$(sha256_path "$accepted_in")" >"$out"
}

run_program() {
  local receipt=$1 expectation_in=$2 evaluation_in=$3 accepted_in=$4 out=$5
  run_program_full "$receipt" "$expectation_in" "$evaluation_in" "$policy" "$decision" \
    "$policy_set" "$registry" "$accepted_in" "$out"
}

# Runs the program and compares the output body exactly, plus the envelope.
run_case() {
  local name=$1 receipt=$2 expectation_in=$3 evaluation_in=$4 accepted_in=$5 cv=$6 ev=$7 \
    reasons=$8
  local out="$tmp/$name.out" expected rsha
  rsha=$(sha256_path "$receipt")
  run_program "$receipt" "$expectation_in" "$evaluation_in" "$accepted_in" "$out"
  expected=$("$jq_bin" -nSc \
    --arg cv "$cv" --arg ev "$ev" --argjson reasons "$reasons" --arg rsha "$rsha" \
    --arg esha "$(sha256_path "$expectation_in")" --arg vsha "$(sha256_path "$evaluation_in")" \
    --arg asha "$(sha256_path "$accepted_in")" \
    '{activation_state:"inactive",authority_effect:"none",qualification_effect:"none",
      origin_check:"not-performed",check_verdict:$cv,enforcement_verdict:$ev,
      reason_ids:$reasons,receipt_sha256:$rsha,expectation_sha256:$esha,
      evaluation_sha256:$vsha,accepted_set_sha256:$asha}')
  "$jq_bin" -e --arg rsha "$rsha" --argjson expected "$expected" '
    .schema_version==1 and .kind=="sandbox_receipt_check" and
    .id==("receipt-check."+$rsha) and .body==$expected
  ' "$out" >/dev/null || fail "$name"
  pass "$name"
}

# Three positive controls.
run_case satisfied-control "$receipt_satisfied" "$expectation" "$evaluation" "$accepted" \
  valid satisfied '["receipt.valid"]'
run_case violated-control "$receipt_violated" "$expectation" "$evaluation" "$accepted" \
  valid violated '["receipt.valid"]'
run_case failed-control "$receipt_failed" "$expectation" "$evaluation" "$accepted" \
  valid failed '["receipt.valid"]'

# receipt.declaration-only alone: the evaluation passed as the receipt.
run_case declaration-only "$evaluation" "$expectation" "$evaluation" "$accepted" \
  refused none '["receipt.declaration-only"]'

# receipt.kind-unsupported alone: another kind; schema_version 2;
# contract_version "v2".
for c in 'kind|.kind="sandbox_enforcement_receipt_v2"' 'schema|.schema_version=2' \
  'contract|.body.contract_version="v2"'; do
  name="kind-unsupported-${c%%|*}"
  run_case "$name" "$(mutate "$receipt_satisfied" "$name" "${c#*|}")" \
    "$expectation" "$evaluation" "$accepted" refused none '["receipt.kind-unsupported"]'
done

# receipt.malformed alone: a missing receipt body key; a broken expectation;
# and each R3.7/R3.8 consistency rule broken alone.
run_case malformed-missing-key \
  "$(mutate "$receipt_satisfied" malformed-missing-key 'del(.body.timing)')" \
  "$expectation" "$evaluation" "$accepted" refused none '["receipt.malformed"]'
run_case malformed-expectation "$receipt_satisfied" \
  "$(mutate "$expectation" malformed-expectation 'del(.body.store_id)')" "$evaluation" \
  "$accepted" refused none '["receipt.malformed"]'
for c in 'observed-null|.body.limits.cpu_time_ms.observed=null' \
  'observed-reached-false|.body.limits.cpu_time_ms.observed=30000|.body.limits.cpu_time_ms.reached=false' \
  'not-started-admitted|.body.payload.exit_state="not-started"|.body.payload.exit_code=null' \
  'refused-not-not-started|.body.lifecycle.admission="refused"' \
  'confirmed-storage-not-destroyed|.body.teardown.storage_destroyed=false'; do
  name="malformed-${c%%|*}"
  run_case "$name" "$(mutate "$receipt_satisfied" "$name" "${c#*|}")" \
    "$expectation" "$evaluation" "$accepted" refused none '["receipt.malformed"]'
done

# receipt.placeholder-identity alone: an all-ones identity slot, and an
# all-zeros payload.stdout_sha256.
for c in 'identity-slot|.body.identities.host_runtime.sha256=("1"*64)' \
  'payload-zero|.body.payload.stdout_sha256=("0"*64)'; do
  name="placeholder-${c%%|*}"
  run_case "$name" "$(mutate "$receipt_satisfied" "$name" "${c#*|}")" \
    "$expectation" "$evaluation" "$accepted" refused none '["receipt.placeholder-identity"]'
done

# Each R8 failure.* rule, set alone on the satisfied control, with a
# correctly derived outcome: `valid`, `failed` and that reason.
for c in 'launch-refused|.body.lifecycle.admission="refused"|.body.payload.exit_state="not-started"|.body.payload.exit_code=null' \
  'runtime|.body.lifecycle.runtime="error"' \
  'supervisor-timeout|.body.lifecycle.control_deadline="exceeded"' \
  'teardown|.body.teardown.state="unconfirmed"|.body.teardown.storage_destroyed=false' \
  'observation-unavailable|.body.identities.toolchain={state:"unobserved",reason_id:"identity.not-captured"}' \
  'enforcement-unavailable|.body.limits.scratch_bytes.enforcement="none"'; do
  reason="failure.${c%%|*}"
  name="failure-${c%%|*}"
  filter="${c#*|}|.body.outcome={verdict:\"failed\",reason_ids:[\"$reason\"]}"
  run_case "$name" "$(mutate "$receipt_satisfied" "$name" "$filter")" "$expectation" \
    "$evaluation" "$accepted" valid failed '["receipt.valid"]'
done

# receipt.outcome-inconsistent alone: the recorded outcome disagrees with the
# fields that would actually derive it.
run_case outcome-inconsistent \
  "$(mutate "$receipt_satisfied" outcome-inconsistent \
     '.body.outcome={verdict:"failed",reason_ids:["failure.runtime"]}')" \
  "$expectation" "$evaluation" "$accepted" refused none '["receipt.outcome-inconsistent"]'

# PR 2: each of the nine remaining R7.4 reasons alone, mutating a positive
# control (limit-mismatch is shown twice, by observer and by bound).
run_case origin-mismatch \
  "$(mutate "$receipt_satisfied" origin-mismatch '.body.origin.store_id="store.other"')" \
  "$expectation" "$evaluation" "$accepted" refused none '["receipt.origin-mismatch"]'
run_case replayed-attempt-number \
  "$(mutate "$receipt_satisfied" replayed-attempt-number '.body.attempt.attempt_number=2')" \
  "$expectation" "$evaluation" "$accepted" refused none '["receipt.replayed"]'
run_case subject-mismatch \
  "$(mutate "$receipt_satisfied" subject-mismatch \
     ".body.subject.incident_sha256=\"$(syn incident.other)\"")" \
  "$expectation" "$evaluation" "$accepted" refused none '["receipt.subject-mismatch"]'
control_mismatch_receipt=$(mutate "$receipt_satisfied" control-mismatch-r \
  ".body.control.evaluator_driver_sha256=\"$(syn evaluator-driver.other)\"")
control_mismatch_expectation=$(mutate "$expectation" control-mismatch-e \
  ".body.control.evaluator_driver_sha256=\"$(syn evaluator-driver.other)\"")
run_case control-mismatch "$control_mismatch_receipt" "$control_mismatch_expectation" \
  "$evaluation" "$accepted" refused none '["receipt.control-mismatch"]'
eval_violated=$(mutate "$evaluation" eval-violated '.body.verdict="violated"')
recomputed=$(recompute "$eval_violated" "$receipt_satisfied" "$expectation" eval-violated-ok)
recomputed_receipt=${recomputed%%$'\n'*}
recomputed_expectation=${recomputed#*$'\n'}
run_case evaluation-not-satisfied "$recomputed_receipt" "$recomputed_expectation" "$eval_violated" \
  "$accepted" refused none '["receipt.evaluation-not-satisfied"]'
env_mismatch_receipt=$(mutate "$receipt_satisfied" env-mismatch-r \
  '.body.subject.target_repository_id="repo.other"')
env_mismatch_expectation=$(mutate "$expectation" env-mismatch-e \
  '.body.subject.target_repository_id="repo.other"')
run_case environment-unlisted "$env_mismatch_receipt" "$env_mismatch_expectation" "$evaluation" \
  "$accepted" refused none '["receipt.environment-unlisted"]'
run_case stale \
  "$(mutate "$receipt_satisfied" stale \
     ".body.origin.accepted_set_sha256=\"$(syn accepted-set.other)\"")" \
  "$expectation" "$evaluation" "$accepted" refused none '["receipt.stale"]'
run_case identity-unaccepted \
  "$(mutate "$receipt_satisfied" identity-unaccepted \
     ".body.identities.toolchain.sha256=\"$(syn identity.toolchain-other)\"")" \
  "$expectation" "$evaluation" "$accepted" refused none '["receipt.identity-unaccepted"]'
run_case limit-mismatch-observer \
  "$(mutate "$receipt_satisfied" limit-mismatch-observer \
     '.body.limits.wall_time_ms.observer="guest-supervisor"')" \
  "$expectation" "$evaluation" "$accepted" refused none '["receipt.limit-mismatch"]'
run_case limit-mismatch-bound \
  "$(mutate "$receipt_satisfied" limit-mismatch-bound '.body.limits.memory_bytes.bound=999999999')" \
  "$expectation" "$evaluation" "$accepted" refused none '["receipt.limit-mismatch"]'

# The companion case: the evaluation verdict changed without `recompute` gives
# exactly receipt.control-mismatch and receipt.evaluation-not-satisfied.
run_case control-and-evaluation-mismatch "$receipt_satisfied" "$expectation" "$eval_violated" \
  "$accepted" refused none '["receipt.control-mismatch","receipt.evaluation-not-satisfied"]'

# Replay: the satisfied control against a second expectation differing only
# in the nonce-bearing launch_request_sha256, then only in attempt_id.
run_case replayed-launch-request \
  "$receipt_satisfied" \
  "$(mutate "$expectation" replayed-launch-request \
     ".body.attempt.launch_request_sha256=\"$(syn launch-request.other)\"")" \
  "$evaluation" "$accepted" refused none '["receipt.replayed"]'
run_case replayed-attempt-id \
  "$receipt_satisfied" \
  "$(mutate "$expectation" replayed-attempt-id '.body.attempt.attempt_id="attempt.other"')" \
  "$evaluation" "$accepted" refused none '["receipt.replayed"]'

# Integrity: a byte-identical copy of the satisfied control gives the same
# check, and the output still says origin_check: "not-performed".
receipt_copy="$tmp/receipt-satisfied-copy.json"
cp "$receipt_satisfied" "$receipt_copy"
run_case satisfied-copy "$receipt_copy" "$expectation" "$evaluation" "$accepted" \
  valid satisfied '["receipt.valid"]'

# The row matrix: for each R6 row, `partial`/`unavailable` give `failed` with
# failure.observation-unavailable; `none`/`unknown` give `failed` with
# failure.enforcement-unavailable; `reached` gives `violated` with that row's
# limit.* reason. None of these is ever `satisfied`.
row_limit_reason() {
  case "$1" in
    cpu_time_ms) printf 'limit.cpu-time-reached' ;;
    wall_time_ms) printf 'limit.wall-time-reached' ;;
    memory_bytes) printf 'limit.memory-reached' ;;
    output_bytes) printf 'limit.output-reached' ;;
    process_count) printf 'limit.process-count-reached' ;;
    scratch_bytes) printf 'limit.scratch-reached' ;;
  esac
}
for rb in "cpu_time_ms:30000" "wall_time_ms:60000" "memory_bytes:536870912" \
  "output_bytes:10485760" "process_count:32" "scratch_bytes:$scratch_bound"; do
  row=${rb%%:*}
  bound=${rb#*:}
  reason=$(row_limit_reason "$row")
  # Each filter is resolved to a plain variable first: nesting an escaped
  # `\"..\"` object literal directly inside a "$(...)" that is itself inside
  # a double-quoted argument gets its backslashes stripped by the outer
  # quotes before the inner command is parsed, corrupting the JSON. A prior
  # plain assignment avoids that extra quoting layer.
  partial_filter=".body.limits.$row.observation=\"partial\"|.body.outcome={verdict:\"failed\",reason_ids:[\"failure.observation-unavailable\"]}"
  run_case "row-$row-partial" "$(mutate "$receipt_satisfied" "row-$row-partial" "$partial_filter")" \
    "$expectation" "$evaluation" "$accepted" valid failed '["receipt.valid"]'
  unavailable_filter=".body.limits.$row.observation=\"unavailable\"|.body.limits.$row.observed=null|.body.outcome={verdict:\"failed\",reason_ids:[\"failure.observation-unavailable\"]}"
  run_case "row-$row-unavailable" \
    "$(mutate "$receipt_satisfied" "row-$row-unavailable" "$unavailable_filter")" \
    "$expectation" "$evaluation" "$accepted" valid failed '["receipt.valid"]'
  none_filter=".body.limits.$row.enforcement=\"none\"|.body.outcome={verdict:\"failed\",reason_ids:[\"failure.enforcement-unavailable\"]}"
  run_case "row-$row-enforcement-none" \
    "$(mutate "$receipt_satisfied" "row-$row-enforcement-none" "$none_filter")" \
    "$expectation" "$evaluation" "$accepted" valid failed '["receipt.valid"]'
  unknown_filter=".body.limits.$row.enforcement=\"unknown\"|.body.outcome={verdict:\"failed\",reason_ids:[\"failure.enforcement-unavailable\"]}"
  run_case "row-$row-enforcement-unknown" \
    "$(mutate "$receipt_satisfied" "row-$row-enforcement-unknown" "$unknown_filter")" \
    "$expectation" "$evaluation" "$accepted" valid failed '["receipt.valid"]'
  reached_filter=".body.limits.$row.observed=$bound|.body.limits.$row.reached=true|.body.outcome={verdict:\"violated\",reason_ids:[\"$reason\"]}"
  run_case "row-$row-reached" "$(mutate "$receipt_satisfied" "row-$row-reached" "$reached_filter")" \
    "$expectation" "$evaluation" "$accepted" valid violated '["receipt.valid"]'
done

# Malformed-fixed-file regression: a fixed document whose own body is `null`,
# the wrong type, or missing a required key is a jq `error` (mapped to
# E_RELATION by PR 3's driver), never an ordinary refusal. One case per fixed
# file per variant, with the other four fixed files left real and good.
expect_fixed_file_error() {
  local name=$1 policy_in=$2 decision_in=$3 policy_set_in=$4 registry_in=$5 accepted_in=$6
  local out="$tmp/$name.out" status=0
  run_program_full "$receipt_satisfied" "$expectation" "$evaluation" "$policy_in" \
    "$decision_in" "$policy_set_in" "$registry_in" "$accepted_in" "$out" \
    2>"$tmp/$name.err" || status=$?
  [ "$status" -ne 0 ] && [ ! -s "$out" ] && [ -s "$tmp/$name.err" ] || fail "$name"
  pass "$name"
}
bad_policy_null=$(mutate "$policy" bad-policy-null '.body=null')
bad_policy_wrong_type=$(mutate "$policy" bad-policy-wrong-type '.body="not-an-object"')
bad_policy_missing_key=$(mutate "$policy" bad-policy-missing-key 'del(.body.tools)')
bad_decision_null=$(mutate "$decision" bad-decision-null '.body=null')
bad_decision_wrong_type=$(mutate "$decision" bad-decision-wrong-type '.body=[]')
bad_decision_missing_key=$(mutate "$decision" bad-decision-missing-key 'del(.body.fail_mode)')
bad_policy_set_null=$(mutate "$policy_set" bad-policy-set-null '.body=null')
bad_policy_set_wrong_type=$(mutate "$policy_set" bad-policy-set-wrong-type '.body=1')
bad_policy_set_missing_key=$(mutate "$policy_set" bad-policy-set-missing-key 'del(.body.fail_mode)')
bad_registry_null=$(mutate "$registry" bad-registry-null '.body=null')
bad_registry_wrong_type=$(mutate "$registry" bad-registry-wrong-type '.body="x"')
bad_registry_missing_key=$(mutate "$registry" bad-registry-missing-key 'del(.body.registry_version)')
bad_accepted_null=$(mutate "$accepted" bad-accepted-null '.body=null')
bad_accepted_wrong_type=$(mutate "$accepted" bad-accepted-wrong-type '.body=[]')
bad_accepted_missing_key=$(mutate "$accepted" bad-accepted-missing-key 'del(.body.set_version)')

expect_fixed_file_error policy-body-null \
  "$bad_policy_null" "$decision" "$policy_set" "$registry" "$accepted"
expect_fixed_file_error policy-body-wrong-type \
  "$bad_policy_wrong_type" "$decision" "$policy_set" "$registry" "$accepted"
expect_fixed_file_error policy-body-missing-key \
  "$bad_policy_missing_key" "$decision" "$policy_set" "$registry" "$accepted"
expect_fixed_file_error decision-body-null \
  "$policy" "$bad_decision_null" "$policy_set" "$registry" "$accepted"
expect_fixed_file_error decision-body-wrong-type \
  "$policy" "$bad_decision_wrong_type" "$policy_set" "$registry" "$accepted"
expect_fixed_file_error decision-body-missing-key \
  "$policy" "$bad_decision_missing_key" "$policy_set" "$registry" "$accepted"
expect_fixed_file_error policy-set-body-null \
  "$policy" "$decision" "$bad_policy_set_null" "$registry" "$accepted"
expect_fixed_file_error policy-set-body-wrong-type \
  "$policy" "$decision" "$bad_policy_set_wrong_type" "$registry" "$accepted"
expect_fixed_file_error policy-set-body-missing-key \
  "$policy" "$decision" "$bad_policy_set_missing_key" "$registry" "$accepted"
expect_fixed_file_error registry-body-null \
  "$policy" "$decision" "$policy_set" "$bad_registry_null" "$accepted"
expect_fixed_file_error registry-body-wrong-type \
  "$policy" "$decision" "$policy_set" "$bad_registry_wrong_type" "$accepted"
expect_fixed_file_error registry-body-missing-key \
  "$policy" "$decision" "$policy_set" "$bad_registry_missing_key" "$accepted"
expect_fixed_file_error accepted-body-null \
  "$policy" "$decision" "$policy_set" "$registry" "$bad_accepted_null"
expect_fixed_file_error accepted-body-wrong-type \
  "$policy" "$decision" "$policy_set" "$registry" "$bad_accepted_wrong_type"
expect_fixed_file_error accepted-body-missing-key \
  "$policy" "$decision" "$policy_set" "$registry" "$bad_accepted_missing_key"

# One wrong-type field and one nested shape break per fixed file, at that
# file's index in `args` (policy/decision/policy_set/registry/accepted).
mutate_case() {
  local idx=$1 name=$2 filter=$3
  local args=("$policy" "$decision" "$policy_set" "$registry" "$accepted")
  args[idx]=$(mutate "${args[idx]}" "$name" "$filter")
  expect_fixed_file_error "$name" "${args[@]}"
}
mutate_case 0 policy-tools-wrong-type '.body.tools="not-an-array"'
mutate_case 0 policy-tools-nested-shape '.body.tools=[{}]'
mutate_case 1 decision-policy-ref-wrong-type '.body.policy_ref=1'
mutate_case 1 decision-policy-ref-nested-shape '.body.policy_ref.sha256="not-a-sha"'
mutate_case 2 policy-set-sections-wrong-type '.body.sections="x"'
mutate_case 2 policy-set-sections-nested-shape '.body.sections[0].policy_ref.sha256=1'
mutate_case 3 registry-environments-wrong-type '.body.environments="x"'
mutate_case 3 registry-environments-nested-shape '.body.environments[0].target_repository_id=1'
mutate_case 4 accepted-environments-wrong-type '.body.environments="x"'
mutate_case 4 accepted-environments-nested-shape '.body.environments[0].scratch_bytes="x"'
mutate_case 3 registry-id-wrong-type '.id=1'

# Generic: every top-level body key of every fixed file, set to null alone,
# one real committed key set per document (this also exercises the network
# and semantics fields named above).
doc_paths=("$policy" "$decision" "$policy_set" "$registry" "$accepted")
for idx in 0 1 2 3 4; do
  for key in $("$jq_bin" -r '.body|keys[]' "${doc_paths[$idx]}"); do
    mutate_case "$idx" "doc$idx-body-$key-null" ".body.$key=null"
  done
done

# Cross-document: the decision must reference the supplied policy bytes, and
# the policy set's own "sandbox" section must reference the supplied policy
# and decision bytes too.
mutate_case 1 decision-unrelated-policy '.body.policy_ref.sha256=("f"*64)'
mutate_case 2 policy-set-missing-sandbox-section 'del(.body.sections[-1])'
mutate_case 2 policy-set-sandbox-section-mismatch '.body.sections[-1].policy_ref.sha256=("f"*64)'
mutate_case 1 decision-policy-ref-wrong-content-id '.body.policy_ref.content_id="other"'
mutate_case 1 decision-policy-ref-wrong-media-type '.body.policy_ref.media_type="text/plain"'

# The schema combinator's array-element and exact-key-set coverage: a
# wrong-typed argv element, a wrong-typed resource_ids element, and an
# unexpected extra key, all inside one policy tool entry.
mutate_case 0 policy-tool-argv-null-element '.body.tools[0].argv=[null]'
mutate_case 0 policy-tool-resource-id-wrong-type '.body.tools[0].resource_ids=[42]'
mutate_case 0 policy-tool-extra-key '.body.tools[0].extra="x"'

# Generic: every scalar leaf path of every fixed file, set to null alone
# (paths enumerated from the real file at test time, not hardcoded).
for idx in 0 1 2 3 4; do
  while IFS= read -r leaf_path; do
    leaf_name="doc$idx-leaf-$(printf '%s' "$leaf_path" | shasum -a256 | cut -c1-10)"
    mutate_case "$idx" "$leaf_name" "setpath($leaf_path;null)"
  done < <("$jq_bin" -c 'paths(scalars)' "${doc_paths[$idx]}")
done

# Same-type invalid literals/enums/sets, not just wrong container types.
mutate_case 0 policy-fail-mode-invalid '.body.fail_mode="not-a-valid-mode"'
mutate_case 2 policy-set-sections-missing-id 'del(.body.sections[0])'
mutate_case 2 policy-set-sections-duplicate-id '.body.sections[0].section_id=.body.sections[1].section_id'
mutate_case 2 policy-set-package-ref-media-type-invalid '.body.core_contract.package_ref.media_type="text/plain"'
mutate_case 0 policy-resource-access-invalid '.body.resources[0].access="read-execute"'

# Defense by identity: a copy still schema-valid (id_ok tolerates a changed
# `.id`) is caught by the pin alone, on each of the three pinned files.
mutate_case 0 policy-tampered-pinned-copy '.id="control-policy.sandbox-tampered"'
mutate_case 1 decision-tampered-pinned-copy '.id="control-decision.sandbox-tampered"'
mutate_case 2 policy-set-tampered-pinned-copy '.id="control-policy-set.v1-tampered"'

# The remaining constraints this round adds: an invalid enum, a non-posint,
# a generation-id pattern break, a non-hex40 commit, and an out-of-enum
# proof_state.
mutate_case 1 decision-fail-mode-invalid '.body.fail_mode="open"'
mutate_case 1 decision-output-schema-version-invalid '.body.semantics.output_schema_version=-1.5'
mutate_case 2 policy-set-generation-id-invalid '.body.core_contract.generation_id="not-a-valid-id"'
mutate_case 3 registry-source-root-commit-invalid '.body.environments[0].source_root_commit="short"'
mutate_case 3 registry-proof-state-invalid '.body.environments[0].proof_state="proven"'

# Repeat runs give byte-identical output.
run_program "$receipt_satisfied" "$expectation" "$evaluation" "$accepted" "$tmp/rep1.out"
run_program "$receipt_satisfied" "$expectation" "$evaluation" "$accepted" "$tmp/rep2.out"
/usr/bin/cmp -s "$tmp/rep1.out" "$tmp/rep2.out" || fail 'determinism'
pass 'two runs give byte-identical output'

/usr/bin/printf 'sandbox receipt: %s focused checks passed\n' "$passes"
