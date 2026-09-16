#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
protocol="$root/adapters/local-git-materializer/v1/protocol.jq"
fixture_builder="$root/scripts/test/local-git-materializer-fixtures.sh"
test_tmp_base=${TMPDIR:-/tmp}
tmp=$(/usr/bin/mktemp -d "${test_tmp_base%/}/ystack-materializer-protocol.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() { /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT

sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Linux:x86_64) jq_asset=jq-linux64; jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  Darwin:x86_64|Darwin:arm64) jq_asset=jq-osx-amd64; jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  *) printf 'FAIL: unsupported host %s\n' "$platform" >&2; exit 1 ;;
esac
jq_source="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset"
[ -f "$jq_source" ] && [ ! -L "$jq_source" ] && [ "$(sha_file "$jq_source")" = "$jq_sha" ] || {
  printf '%s\n' 'FAIL: pinned jq 1.6 is required' >&2
  exit 1
}
bin="$tmp/bin"
/bin/mkdir -m 700 "$bin"
if [ "$platform" = Darwin:arm64 ]; then
  printf '%s\n' '#!/bin/bash' "exec /usr/bin/arch -x86_64 '$jq_source' \"\$@\"" > "$bin/jq"
else
  /bin/cp "$jq_source" "$bin/jq"
fi
/bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"
export PATH="$bin:/usr/bin:/bin"
[ "$($jq_bin --version)" = jq-1.6 ] || exit 1
generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" \
  "$root/scripts/core-contract.sh")
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || exit 1
$jq_bin -e --arg generation "$generation" '
  [.[] | select(.generation_id == $generation and
    .semantic_identity == "core.contracts.v2")] | length == 1
' "$root/core/v2/generation-registry.json" >/dev/null || exit 1
modules="$root/core/v2/generations/$generation/modules"
core="$root/scripts/core-contract.sh"

passed=0
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

fixture="$tmp/fixture"
source_commit=$(printf '%040d' 0 | /usr/bin/tr 0 1)
source_tree=$(printf '%040d' 0 | /usr/bin/tr 0 2)
"$fixture_builder" build "$fixture" "$jq_bin" sha1 "$source_commit" "$source_tree"
input="$fixture/input.json"

manifest_args=(
  "$fixture/manifests/forge.json"
  "$fixture/manifests/producer.json"
  "$fixture/manifests/publisher.json"
  "$fixture/manifests/reviewer.json"
  "$fixture/manifests/verifier.json"
)
for document in "$fixture/profile.json" "$fixture/resolved-profile.json" \
  "$fixture/stage-request.json" "${manifest_args[@]}"; do
  "$core" validate-document "$document" || fail "core-document-${document##*/}"
done
"$core" validate-profile-set "$fixture/profile.json" "$fixture/resolved-profile.json" \
  "${manifest_args[@]}" || fail core-profile-set
"$jq_bin" -L "$modules" -e --arg command validate-input -f "$protocol" "$input" >/dev/null ||
  fail valid-input
pass 'exact core v2 graph, request, manifest, and payload envelope validate'

expect_invalid() {
  local name=$1 filter=$2
  local candidate="$tmp/$name.json"
  "$jq_bin" -S -c "$filter" "$input" > "$candidate"
  if "$jq_bin" -L "$modules" -e --arg command validate-input -f "$protocol" \
      "$candidate" >/dev/null 2> "$tmp/$name.err"; then
    fail "$name accepted"
  fi
  pass "$name"
}

expect_invalid_contract() {
  local name=$1 filter=$2
  expect_invalid "$name" "$filter |
    (.trust_context.verified_payloads[] |
      select(.input_id==\"input.materialize\") | .content.data) =
      (.payloads[] | select(.input_id==\"input.materialize\") | .data)"
}

expect_invalid extra-envelope-field '.unexpected=true'
expect_invalid missing-attempt 'del(.attempt)'
expect_invalid malformed-time '.attempt.finished_at="2026-02-30T00:00:02Z"'
expect_invalid duplicate-payload '.payloads[1]=.payloads[0]'
expect_invalid relabelled-payload '.payloads[1].input_id="input.other"'
expect_invalid payload-media-mismatch '.payloads[1].media_type="application/json"'
expect_invalid changed-after-verification \
  '(.payloads[] | select(.input_id=="input.producer-patch") | .data) += "tamper"'
expect_invalid missing-verified-payload 'del(.trust_context.verified_payloads[0])'
expect_invalid stale-resolved-ref \
  '.stage_request.content.body.resolved_profile_ref.sha256=("0"*64)'
expect_invalid duplicate-manifest '.manifests += [.manifests[0]]'
expect_invalid wrong-manifest-package \
  '(.resolved_profile.content.body.bindings[] | select(.binding.role=="forge") |
    .binding.package_ref.object_id)=("0"*40)'
expect_invalid wrong-role '.stage_request.content.body.operation.role="producer"'
expect_invalid wrong-capability \
  '.stage_request.content.body.operation.capability_id="core.harness.produce.v1"'
expect_invalid wrong-permissions \
  '.stage_request.content.body.operation.permissions-=["core.perm.candidate-repository.write.v2"]'
expect_invalid_contract malformed-contract-data \
  '(.payloads[] | select(.input_id=="input.materialize") | .data)="{"'
expect_invalid_contract traversal-contract-path \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .allowed_paths=["../escape"] | tojson)'
expect_invalid_contract git-contract-path \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .allowed_paths=[".Git/config"] | tojson)'
expect_invalid_contract contract-mode-expansion \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .allowed_modes += ["120000"] | tojson)'
expect_invalid_contract contract-zero-byte-limit \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .max_patch_bytes=0 | tojson)'
expect_invalid_contract contract-change-limit-over-paths \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .max_changed_paths=2 | tojson)'
expect_invalid_contract contract-allows-binary \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .allow_binary_patch=true | tojson)'
expect_invalid_contract contract-allows-symlink \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .allow_symlinks=true | tojson)'
expect_invalid_contract contract-allows-submodule \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .allow_submodules=true | tojson)'
expect_invalid_contract contract-worktree-output \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .candidate_repository_kind="worktree" | tojson)'
expect_invalid_contract contract-patch-byte-limit '
  (.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .max_patch_bytes=1 | tojson)'

receipt="$tmp/receipt.json"
candidate_commit=$(printf '%040d' 0 | /usr/bin/tr 0 3)
candidate_tree=$(printf '%040d' 0 | /usr/bin/tr 0 4)
changed_paths_sha=$(printf '%064d' 0 | /usr/bin/tr 0 5)
receipt_args=(
  --arg command receipt
  --arg source_repository_id fixture.target
  --arg source_hash_algorithm sha1
  --arg source_commit "$source_commit"
  --arg source_tree "$source_tree"
  --arg candidate_commit "$candidate_commit"
  --arg candidate_tree "$candidate_tree"
  --arg changed_path_count 1
  --arg changed_paths_sha256 "$changed_paths_sha"
)
projection_malformed="$tmp/projection-malformed.json"
"$jq_bin" -S -c '.unexpected=true' "$input" > "$projection_malformed"
for projection_command in contract patch receipt stage-result; do
  projection_args=(--arg command "$projection_command")
  case "$projection_command" in
    receipt) projection_args=("${receipt_args[@]}") ;;
    stage-result)
      projection_args=(--arg command stage-result --arg outcome changed
        --arg receipt_json '{}' --arg verified_receipt_json '{}')
      ;;
  esac
  if "$jq_bin" -L "$modules" "${projection_args[@]}" -f "$protocol" \
       "$projection_malformed" >"$tmp/$projection_command-malformed.out" 2>/dev/null; then
    fail "$projection_command projection accepted invalid envelope"
  fi
  pass "$projection_command validates the current envelope"
done
"$jq_bin" -S -c -L "$modules" "${receipt_args[@]}" -f "$protocol" "$input" > "$receipt"
"$jq_bin" -S -c -L "$modules" "${receipt_args[@]}" -f "$protocol" "$input" > "$tmp/receipt-repeat"
/usr/bin/cmp -s "$receipt" "$tmp/receipt-repeat" || fail receipt-repeat
if /usr/bin/grep -Fq "$tmp" "$receipt" ||
   "$jq_bin" -e '[..|objects|keys[]] | any(.=="authority" or .=="effects" or .=="qualification")' \
     "$receipt" >/dev/null; then
  fail receipt-effect-surface
fi
pass 'canonical receipt is path-free and carries no authority or effect'

expect_receipt_reject() {
  local name=$1 repository_id=$2 commit_id=$3 tree_id=$4 changed_count=$5
  if "$jq_bin" -L "$modules" --arg command receipt \
      --arg source_repository_id "$repository_id" --arg source_hash_algorithm sha1 \
      --arg source_commit "$commit_id" --arg source_tree "$tree_id" \
      --arg candidate_commit "$candidate_commit" --arg candidate_tree "$candidate_tree" \
      --arg changed_path_count "$changed_count" \
      --arg changed_paths_sha256 "$changed_paths_sha" \
      -f "$protocol" "$input" >/dev/null 2>&1; then
    fail "$name"
  fi
  pass "$name"
}
expect_receipt_reject source-repository-mismatch fixture.other \
  "$source_commit" "$source_tree" 1
expect_receipt_reject source-commit-mismatch fixture.target \
  "$(printf '%040d' 0 | /usr/bin/tr 0 6)" "$source_tree" 1
expect_receipt_reject source-tree-mismatch fixture.target \
  "$source_commit" "$(printf '%040d' 0 | /usr/bin/tr 0 7)" 1
expect_receipt_reject changed-path-limit fixture.target \
  "$source_commit" "$source_tree" 2

receipt_sha=$(sha_file "$receipt")
verified_receipt="$tmp/verified-receipt.json"
"$jq_bin" -S -c -n --slurpfile receipt "$receipt" --arg sha "$receipt_sha" \
  '{content:$receipt[0],sha256:$sha}' > "$verified_receipt"
stage_result_args=(
  --arg command stage-result
  --arg outcome changed
  --arg receipt_json "$(<"$receipt")"
  --arg verified_receipt_json "$(<"$verified_receipt")"
)
result="$tmp/result.json"
"$jq_bin" -S -c -L "$modules" "${stage_result_args[@]}" \
  -f "$protocol" "$input" > "$result"
"$core" validate-stage-run "$fixture/stage-request.json" "$fixture/resolved-profile.json" \
  "$result" || fail core-stage-result
"$jq_bin" -e '
  .body.status=="completed" and .body.outcome=={family:"change",value:"changed"} and
  .body.outputs[0].output_id=="candidate.repository" and
  .body.evidence==[{evidence_id:"evidence.local-git-materialization",kind:"deterministic",
    verdict:"passed",proof_ref:.body.outputs[0].ref}] and
  ([..|objects|keys[]] | index("effects")==null) and
  ([..|objects|keys[]] | index("qualification")==null)
' "$result" >/dev/null || fail result-surface
"$jq_bin" -S -c -L "$modules" "${stage_result_args[@]}" \
  -f "$protocol" "$input" > "$tmp/result-repeat"
/usr/bin/cmp -s "$result" "$tmp/result-repeat" || fail result-repeat
pass 'pure result projection passes the exact core v2 stage relation'

make_verified_receipt() {
  local source_file=$1 output_file=$2 digest
  digest=$(sha_file "$source_file")
  "$jq_bin" -S -c -n --slurpfile receipt "$source_file" --arg sha "$digest" \
    '{content:$receipt[0],sha256:$sha}' > "$output_file"
}
expect_stage_result_reject() {
  local name=$1 outcome=$2 raw_file=$3 pair_file=$4
  if "$jq_bin" -L "$modules" --arg command stage-result --arg outcome "$outcome" \
      --arg receipt_json "$(<"$raw_file")" \
      --arg verified_receipt_json "$(<"$pair_file")" \
      -f "$protocol" "$input" >/dev/null 2>&1; then
    fail "$name"
  fi
  pass "$name"
}

moved_receipt="$tmp/moved-receipt.json"
"$jq_bin" -S -c '.request_ref.sha256=("6"*64)' "$receipt" > "$moved_receipt"
expect_stage_result_reject receipt-changed-after-verification changed \
  "$moved_receipt" "$verified_receipt"

mismatched_request_pair="$tmp/mismatched-request-pair.json"
make_verified_receipt "$moved_receipt" "$mismatched_request_pair"
expect_stage_result_reject receipt-request-mismatch changed \
  "$moved_receipt" "$mismatched_request_pair"

nested_source_input="$tmp/nested-source-input.json"
"$jq_bin" -S -c '
  (.stage_request.content.body.inputs[] |
    select(.input_id=="input.source-tree") | .value.value.value.location) =
    {kind:"path",value:"nested"} |
  .stage_request.content.body.source.value.location={kind:"path",value:"nested"} |
  .stage_request.sha256=("9"*64)
' "$input" > "$nested_source_input"
nested_source_receipt="$tmp/nested-source-receipt.json"
"$jq_bin" -S -c '.request_ref.sha256=("9"*64)' \
  "$receipt" > "$nested_source_receipt"
nested_source_pair="$tmp/nested-source-pair.json"
make_verified_receipt "$nested_source_receipt" "$nested_source_pair"
if "$jq_bin" -L "$modules" --arg command stage-result --arg outcome changed \
    --arg receipt_json "$(<"$nested_source_receipt")" \
    --arg verified_receipt_json "$(<"$nested_source_pair")" \
    -f "$protocol" "$nested_source_input" >/dev/null 2>&1; then
  fail receipt-nested-source-tree
fi
pass 'receipt source must be the repository root tree'

mismatched_attempt="$tmp/mismatched-attempt-receipt.json"
"$jq_bin" -S -c '.attempt.attempt_number += 1' "$receipt" > "$mismatched_attempt"
mismatched_attempt_pair="$tmp/mismatched-attempt-pair.json"
make_verified_receipt "$mismatched_attempt" "$mismatched_attempt_pair"
expect_stage_result_reject receipt-attempt-mismatch changed \
  "$mismatched_attempt" "$mismatched_attempt_pair"

malformed_digest_pair="$tmp/malformed-receipt-digest-pair.json"
"$jq_bin" -S -c '.sha256="invalid"' "$verified_receipt" > "$malformed_digest_pair"
expect_stage_result_reject receipt-digest-shape changed \
  "$receipt" "$malformed_digest_pair"
expect_stage_result_reject receipt-outcome-mismatch no-change \
  "$receipt" "$verified_receipt"

unchanged_commit_receipt="$tmp/unchanged-commit-receipt.json"
"$jq_bin" -S -c '.candidate.commit_id=.source.commit_id' \
  "$receipt" > "$unchanged_commit_receipt"
unchanged_commit_pair="$tmp/unchanged-commit-pair.json"
make_verified_receipt "$unchanged_commit_receipt" "$unchanged_commit_pair"
expect_stage_result_reject changed-with-unchanged-commit changed \
  "$unchanged_commit_receipt" "$unchanged_commit_pair"

unchanged_tree_receipt="$tmp/unchanged-tree-receipt.json"
"$jq_bin" -S -c '.candidate.tree_id=.source.tree_id' \
  "$receipt" > "$unchanged_tree_receipt"
unchanged_tree_pair="$tmp/unchanged-tree-pair.json"
make_verified_receipt "$unchanged_tree_receipt" "$unchanged_tree_pair"
expect_stage_result_reject changed-with-unchanged-tree changed \
  "$unchanged_tree_receipt" "$unchanged_tree_pair"

no_change_receipt="$tmp/no-change-receipt.json"
"$jq_bin" -S -c -L "$modules" --arg command receipt \
  --arg source_repository_id fixture.target --arg source_hash_algorithm sha1 \
  --arg source_commit "$source_commit" --arg source_tree "$source_tree" \
  --arg candidate_commit "$source_commit" --arg candidate_tree "$source_tree" \
  --arg changed_path_count 0 --arg changed_paths_sha256 "$changed_paths_sha" \
  -f "$protocol" "$input" > "$no_change_receipt"
no_change_pair="$tmp/no-change-pair.json"
make_verified_receipt "$no_change_receipt" "$no_change_pair"
no_change_result="$tmp/no-change-result.json"
"$jq_bin" -S -c -L "$modules" --arg command stage-result --arg outcome no-change \
  --arg receipt_json "$(<"$no_change_receipt")" \
  --arg verified_receipt_json "$(<"$no_change_pair")" \
  -f "$protocol" "$input" > "$no_change_result"
"$core" validate-stage-run "$fixture/stage-request.json" "$fixture/resolved-profile.json" \
  "$no_change_result" || fail core-no-change-result
"$jq_bin" -e '.body.outcome.value=="no-change" and .body.outputs==[] and
  .body.evidence[0].proof_ref.sha256 == .body.execution.metadata.tools.source_ref.sha256' \
  "$no_change_result" >/dev/null || fail no-change-result-surface
pass 'verified no-change receipt binds the no-change result'

response="$tmp/response.json"
"$jq_bin" -S -c -n --slurpfile result "$result" --rawfile receipt "$receipt" \
  --arg receipt_sha "$(sha_file "$receipt")" '{
    schema_version:1,kind:"local_git_materialization_response",
    stage_result:$result[0],payloads:[{
      content_id:"candidate.materialization.receipt",media_type:"application/json",
      sha256:$receipt_sha,data:$receipt}],authority:"none",
    qualification:{state:"unavailable",reason_id:"adapter.unqualified"},
    effects:["caller-disposable-candidate-repository"]
  }' > "$response"
stage_result_sha=$(sha_file "$result")
response_bundle="$tmp/response-bundle.json"
"$jq_bin" -S -c -n --slurpfile input "$input" --slurpfile response "$response" \
  --slurpfile receipt "$verified_receipt" --rawfile receipt_utf8 "$receipt" \
  --arg stage_result_sha256 "$stage_result_sha" '{input:$input[0],response:$response[0],
    verified_receipt:$receipt[0],receipt_utf8:$receipt_utf8,
    stage_result_sha256:$stage_result_sha256}' > "$response_bundle"
"$jq_bin" -e -L "$modules" --arg command validate-response \
  -f "$protocol" "$response_bundle" >/dev/null ||
  fail validate-response
pass 'supplied response validates without generating replacement evidence'

"$jq_bin" -e --slurpfile input "$input" --arg receipt_sha "$receipt_sha" '
  .schema_version==1 and .kind=="local_git_materialization_response" and
  .authority=="none" and
  .qualification=={state:"unavailable",reason_id:"adapter.unqualified"} and
  .effects==["caller-disposable-candidate-repository"] and
  .payloads==[{content_id:"candidate.materialization.receipt",
    media_type:"application/json",sha256:$receipt_sha,data:.payloads[0].data}] and
  .stage_result.schema_version==2 and .stage_result.kind=="stage_result" and
  .stage_result.id==$input[0].attempt.result_id and
  .stage_result.body.request_ref=={
    schema_version:$input[0].stage_request.content.schema_version,
    kind:$input[0].stage_request.content.kind,id:$input[0].stage_request.content.id,
    sha256:$input[0].stage_request.sha256} and
  .stage_result.body.resolved_profile_ref=={
    schema_version:$input[0].resolved_profile.content.schema_version,
    kind:$input[0].resolved_profile.content.kind,id:$input[0].resolved_profile.content.id,
    sha256:$input[0].resolved_profile.sha256} and
  .stage_result.body.attempt_id==$input[0].attempt.attempt_id and
  .stage_result.body.attempt_number==$input[0].attempt.attempt_number and
  .stage_result.body.status=="completed" and
  .stage_result.body.outcome=={family:"change",value:"changed"} and
  .stage_result.body.outputs==[{output_id:"candidate.repository",ref:{
    content_id:"candidate.materialization.receipt",media_type:"application/json",
    sha256:$receipt_sha}}] and .stage_result.body.diagnostics==[] and
  .stage_result.body.evidence==[{evidence_id:"evidence.local-git-materialization",
    kind:"deterministic",verdict:"passed",proof_ref:{
      content_id:"candidate.materialization.receipt",media_type:"application/json",
      sha256:$receipt_sha}}] and
  .stage_result.body.execution.metadata=={
    kind:"deterministic",provider:{state:"not-applicable"},
    model:{state:"not-applicable"},snapshot:{state:"not-applicable"},
    effort:{state:"not-applicable"},prompt:{state:"not-applicable"},
    skills:{state:"not-applicable"},tools:{state:"recorded",value:[],source_ref:{
      content_id:"candidate.materialization.receipt",media_type:"application/json",
      sha256:$receipt_sha}}} and
  .stage_result.body.started_at==$input[0].attempt.started_at and
  .stage_result.body.finished_at==$input[0].attempt.finished_at and
  .stage_result.body.recorded_at==$input[0].attempt.recorded_at
' "$response" >/dev/null || fail independent-fixed-response-facts
pass 'independent assertions bind every fixed response receipt reference and metadata fact'

expect_fixed_response_reject() {
  local name=$1 filter=$2 core_valid=${3:-no}
  local mutated="$tmp/fixed-$name-response.json"
  local stage="$tmp/fixed-$name-stage.json"
  local bundle="$tmp/fixed-$name-bundle.json"
  local digest
  "$jq_bin" -S -c "$filter" "$response" > "$mutated"
  "$jq_bin" -S -c '.stage_result' "$mutated" > "$stage"
  digest=$(sha_file "$stage")
  if [ "$core_valid" = yes ]; then
    "$core" validate-stage-run "$fixture/stage-request.json" \
      "$fixture/resolved-profile.json" "$stage" || fail "$name not core-valid"
  fi
  "$jq_bin" -S -c --slurpfile response "$mutated" --arg sha "$digest" \
    '.response=$response[0] | .stage_result_sha256=$sha' \
    "$response_bundle" > "$bundle"
  if "$jq_bin" -e -L "$modules" --arg command validate-response \
      -f "$protocol" "$bundle" >/dev/null 2>&1; then
    fail "$name accepted"
  fi
  pass "P08 direct fixed response rejects $name"
}

expect_fixed_response_reject response-schema-version '.schema_version=2'
expect_fixed_response_reject response-kind '.kind="other_response"'
expect_fixed_response_reject response-authority '.authority="write"'
expect_fixed_response_reject response-qualification-state \
  '.qualification.state="available"'
expect_fixed_response_reject response-qualification-reason \
  '.qualification.reason_id="adapter.other"'
expect_fixed_response_reject response-effects-empty '.effects=[]'
expect_fixed_response_reject response-effects-extra '.effects += ["extra-effect"]'
expect_fixed_response_reject response-payload-missing '.payloads=[]'
expect_fixed_response_reject response-payload-extra '.payloads += [.payloads[0]]'
expect_fixed_response_reject response-payload-content-id \
  '.payloads[0].content_id="other.receipt"'
expect_fixed_response_reject response-payload-media-type \
  '.payloads[0].media_type="application/octet-stream"'
expect_fixed_response_reject response-payload-digest '.payloads[0].sha256=("0"*64)'
expect_fixed_response_reject response-payload-data '.payloads[0].data="{}\n"'
expect_fixed_response_reject response-extra '.extra=true'
expect_fixed_response_reject response-missing-authority 'del(.authority)'
expect_fixed_response_reject output-receipt-digest \
  '.stage_result.body.outputs[0].ref.sha256=("0"*64)' yes
expect_fixed_response_reject output-receipt-content-id \
  '.stage_result.body.outputs[0].ref.content_id="other.receipt"' yes
expect_fixed_response_reject output-receipt-media-type \
  '.stage_result.body.outputs[0].ref.media_type="application/octet-stream"'
expect_fixed_response_reject output-id \
  '.stage_result.body.outputs[0].output_id="candidate.other"'
expect_fixed_response_reject output-cardinality \
  '.stage_result.body.outputs += [.stage_result.body.outputs[0]]'
expect_fixed_response_reject evidence-receipt-digest \
  '.stage_result.body.evidence[0].proof_ref.sha256=("0"*64)' yes
expect_fixed_response_reject evidence-receipt-content-id \
  '.stage_result.body.evidence[0].proof_ref.content_id="other.receipt"' yes
expect_fixed_response_reject evidence-receipt-media-type \
  '.stage_result.body.evidence[0].proof_ref.media_type="application/octet-stream"' yes
expect_fixed_response_reject evidence-id \
  '.stage_result.body.evidence[0].evidence_id="evidence.other"' yes
expect_fixed_response_reject evidence-kind \
  '.stage_result.body.evidence[0].kind="observed"'
expect_fixed_response_reject evidence-verdict \
  '.stage_result.body.evidence[0].verdict="failed"'
expect_fixed_response_reject evidence-cardinality \
  '.stage_result.body.evidence += [.stage_result.body.evidence[0]]'
expect_fixed_response_reject tools-receipt-digest \
  '.stage_result.body.execution.metadata.tools.source_ref.sha256=("0"*64)' yes
expect_fixed_response_reject tools-receipt-content-id \
  '.stage_result.body.execution.metadata.tools.source_ref.content_id="other.receipt"' yes
expect_fixed_response_reject tools-receipt-media-type \
  '.stage_result.body.execution.metadata.tools.source_ref.media_type="application/octet-stream"' yes
expect_fixed_response_reject tools-computed \
  '.stage_result.body.execution.metadata.tools.state="computed"' yes
expect_fixed_response_reject tools-value \
  '.stage_result.body.execution.metadata.tools.value=["unexpected"]'
expect_fixed_response_reject metadata-kind \
  '.stage_result.body.execution.metadata.kind="interactive"'
for fact in provider model snapshot effort prompt skills; do
  expect_fixed_response_reject "metadata-$fact" \
    ".stage_result.body.execution.metadata.$fact={state:\"unavailable\"}"
done
expect_fixed_response_reject metadata-extra \
  '.stage_result.body.execution.metadata.extra=true'
expect_fixed_response_reject execution-extra \
  '.stage_result.body.execution.extra=true'
expect_fixed_response_reject performer \
  '.stage_result.body.execution.performer.principal_id="principal.other"'
expect_fixed_response_reject reported-by \
  '.stage_result.body.reported_by.principal_id="principal.other"'
expect_fixed_response_reject actual-binding \
  '.stage_result.body.execution.actual_binding.binding_id="binding.other"'
expect_fixed_response_reject environment \
  '.stage_result.body.execution.environment.environment_id="environment.other"'
expect_fixed_response_reject capability \
  '.stage_result.body.execution.used_capability.id="core.forge.other.v1"'
expect_fixed_response_reject request-ref \
  '.stage_result.body.request_ref.sha256=("0"*64)'
expect_fixed_response_reject resolved-profile-ref \
  '.stage_result.body.resolved_profile_ref.sha256=("0"*64)'
expect_fixed_response_reject attempt-id '.stage_result.body.attempt_id="attempt.other"'
expect_fixed_response_reject attempt-number '.stage_result.body.attempt_number=2'
expect_fixed_response_reject result-schema-version '.stage_result.schema_version=1'
expect_fixed_response_reject result-kind '.stage_result.kind="other_result"'
expect_fixed_response_reject result-id '.stage_result.id="result.other"'
expect_fixed_response_reject result-extra '.stage_result.extra=true'
expect_fixed_response_reject body-extra '.stage_result.body.extra=true'
expect_fixed_response_reject body-missing-reported-by \
  'del(.stage_result.body.reported_by)'
expect_fixed_response_reject execution-missing-metadata \
  'del(.stage_result.body.execution.metadata)'
expect_fixed_response_reject metadata-missing-tools \
  'del(.stage_result.body.execution.metadata.tools)'
expect_fixed_response_reject output-missing-ref \
  'del(.stage_result.body.outputs[0].ref)'
expect_fixed_response_reject evidence-missing-proof-ref \
  'del(.stage_result.body.evidence[0].proof_ref)'
expect_fixed_response_reject status '.stage_result.body.status="failed"'
expect_fixed_response_reject outcome-family '.stage_result.body.outcome.family="other"'
expect_fixed_response_reject diagnostics '.stage_result.body.diagnostics=[{}]'
expect_fixed_response_reject started-at \
  '.stage_result.body.started_at="2026-08-30T00:00:00Z"'
expect_fixed_response_reject finished-at \
  '.stage_result.body.finished_at="2026-08-30T00:00:03Z"'
expect_fixed_response_reject recorded-at \
  '.stage_result.body.recorded_at="2026-08-30T00:00:04Z"'

expect_rehashed_receipt_reject() {
  local name=$1 filter=$2
  local mutated_receipt="$tmp/receipt-fact-$name.json"
  local pair="$tmp/receipt-fact-$name-pair.json"
  local mutated="$tmp/receipt-fact-$name-response.json"
  local stage="$tmp/receipt-fact-$name-stage.json"
  local bundle="$tmp/receipt-fact-$name-bundle.json"
  local receipt_digest stage_digest
  "$jq_bin" -S -c "$filter" "$receipt" > "$mutated_receipt"
  receipt_digest=$(sha_file "$mutated_receipt")
  "$jq_bin" -S -c -n --slurpfile receipt "$mutated_receipt" \
    --arg sha "$receipt_digest" '{content:$receipt[0],sha256:$sha}' > "$pair"
  "$jq_bin" -S -c --rawfile receipt "$mutated_receipt" \
    --arg sha "$receipt_digest" '
      .payloads[0].data=$receipt | .payloads[0].sha256=$sha |
      .stage_result.body.outputs[0].ref.sha256=$sha |
      .stage_result.body.evidence[0].proof_ref.sha256=$sha |
      .stage_result.body.execution.metadata.tools.source_ref.sha256=$sha
    ' "$response" > "$mutated"
  "$jq_bin" -S -c '.stage_result' "$mutated" > "$stage"
  stage_digest=$(sha_file "$stage")
  "$jq_bin" -S -c --slurpfile response "$mutated" --slurpfile pair "$pair" \
    --rawfile receipt "$mutated_receipt" --arg stage_sha "$stage_digest" '
      .response=$response[0] | .verified_receipt=$pair[0] |
      .receipt_utf8=$receipt | .stage_result_sha256=$stage_sha
    ' "$response_bundle" > "$bundle"
  if "$jq_bin" -e -L "$modules" --arg command validate-response \
      -f "$protocol" "$bundle" >/dev/null 2>&1; then
    fail "$name accepted"
  fi
  pass "P08 direct fully rehashed receipt rejects $name"
}

expect_rehashed_receipt_reject request-ref '.request_ref.sha256=("0"*64)'
expect_rehashed_receipt_reject receipt-version '.schema_version=2'
expect_rehashed_receipt_reject receipt-kind '.kind="other_receipt"'
expect_rehashed_receipt_reject adapter-id '.adapter.id="adapter.other"'
expect_rehashed_receipt_reject adapter-version '.adapter.version="v2"'
expect_rehashed_receipt_reject adapter-status '.adapter.status="active"'
expect_rehashed_receipt_reject attempt-id '.attempt.attempt_id="attempt.other"'
expect_rehashed_receipt_reject attempt-number '.attempt.attempt_number=2'
expect_rehashed_receipt_reject resolved-profile-ref \
  '.resolved_profile_ref.sha256=("0"*64)'
expect_rehashed_receipt_reject manifest-ref '.manifest_ref.sha256=("0"*64)'
expect_rehashed_receipt_reject materialization-contract-ref \
  '.materialization_contract_ref.sha256=("0"*64)'
expect_rehashed_receipt_reject patch-ref '.patch_ref.sha256=("0"*64)'
expect_rehashed_receipt_reject source-repository '.source.repository_id="fixture.other"'
expect_rehashed_receipt_reject source-algorithm '.source.hash_algorithm="sha256"'
expect_rehashed_receipt_reject source-commit '.source.commit_id=("9"*40)'
expect_rehashed_receipt_reject source-tree '.source.tree_id=("0"*40)'
expect_rehashed_receipt_reject candidate-kind '.candidate.repository_kind="worktree"'
expect_rehashed_receipt_reject candidate-algorithm '.candidate.hash_algorithm="sha256"'
expect_rehashed_receipt_reject candidate-commit '.candidate.commit_id="invalid"'
expect_rehashed_receipt_reject candidate-tree '.candidate.tree_id="invalid"'
expect_rehashed_receipt_reject candidate-parent '.candidate.parent_commit_id=("6"*40)'
expect_rehashed_receipt_reject changed-paths-count '.changed_paths.count=2'
expect_rehashed_receipt_reject changed-paths-digest '.changed_paths.sha256="invalid"'
expect_rehashed_receipt_reject receipt-extra '.extra=true'
expect_rehashed_receipt_reject receipt-missing-patch-ref 'del(.patch_ref)'

no_change_response="$tmp/no-change-response.json"
no_change_stage_sha=$(sha_file "$no_change_result")
no_change_receipt_sha=$(sha_file "$no_change_receipt")
"$jq_bin" -S -c -n --slurpfile result "$no_change_result" \
  --rawfile receipt "$no_change_receipt" --arg receipt_sha "$no_change_receipt_sha" '{
    schema_version:1,kind:"local_git_materialization_response",stage_result:$result[0],
    payloads:[{content_id:"candidate.materialization.receipt",media_type:"application/json",
      sha256:$receipt_sha,data:$receipt}],authority:"none",
    qualification:{state:"unavailable",reason_id:"adapter.unqualified"},
    effects:["caller-disposable-candidate-repository"]
  }' > "$no_change_response"
no_change_bundle="$tmp/no-change-response-bundle.json"
"$jq_bin" -S -c -n --slurpfile input "$input" \
  --slurpfile response "$no_change_response" --slurpfile receipt "$no_change_pair" \
  --rawfile receipt_utf8 "$no_change_receipt" \
  --arg stage_result_sha256 "$no_change_stage_sha" '{input:$input[0],response:$response[0],
    verified_receipt:$receipt[0],receipt_utf8:$receipt_utf8,
    stage_result_sha256:$stage_result_sha256}' > "$no_change_bundle"
"$jq_bin" -e -L "$modules" --arg command validate-response \
  -f "$protocol" "$no_change_bundle" >/dev/null || fail validate-no-change-response
"$jq_bin" -e '.response.stage_result.body.outputs==[] and
  .response.stage_result.body.evidence[0].proof_ref ==
    .response.stage_result.body.execution.metadata.tools.source_ref and
  .response.stage_result.body.evidence[0].proof_ref.sha256 == .verified_receipt.sha256' \
  "$no_change_bundle" >/dev/null || fail independent-no-change-fixed-facts
pass 'supplied no-change response retains exact evidence and tools receipt links'

bad_response="$tmp/bad-response.json"
"$jq_bin" -S -c '.effects += ["extra-effect"]' "$response" > "$bad_response"
bad_response_bundle="$tmp/bad-response-bundle.json"
"$jq_bin" -S -c --slurpfile response "$bad_response" '.response=$response[0]' \
  "$response_bundle" > "$bad_response_bundle"
if "$jq_bin" -e -L "$modules" --arg command validate-response \
    -f "$protocol" "$bad_response_bundle" >/dev/null 2>&1; then
  fail validate-response-effect
fi
pass 'response validator rejects added effect claims'

bad_result_response="$tmp/bad-result-response.json"
"$jq_bin" -S -c '.stage_result.body.attempt_number += 1' "$response" > "$bad_result_response"
bad_result="$tmp/bad-result.json"
"$jq_bin" -S -c '.stage_result' "$bad_result_response" > "$bad_result"
bad_result_bundle="$tmp/bad-result-bundle.json"
"$jq_bin" -S -c --slurpfile response "$bad_result_response" \
  --arg sha "$(sha_file "$bad_result")" \
  '.response=$response[0] | .stage_result_sha256=$sha' \
  "$response_bundle" > "$bad_result_bundle"
if "$jq_bin" -e -L "$modules" --arg command validate-response \
    -f "$protocol" "$bad_result_bundle" >/dev/null 2>&1; then
  fail validate-response-attempt
fi
pass 'response validator rejects a rehashed result relation mismatch'

if "$jq_bin" -L "$modules" --arg command receipt --arg source_hash_algorithm sha1 \
    --arg source_commit INVALID --arg source_tree "$source_tree" \
    --arg candidate_commit "$source_commit" --arg candidate_tree "$source_tree" \
    --arg changed_path_count 1 --arg changed_paths_sha256 "$(printf '%064d' 0)" \
    --arg source_repository_id fixture.target -f "$protocol" "$input" \
    > "$tmp/bad-receipt.out" 2> "$tmp/bad-receipt.err"; then
  fail malformed-receipt-identity
fi
pass 'malformed receipt identity rejected'

if /usr/bin/grep -Eq 'curl|wget|gh |glab |github[.]com|gitlab[.]com|system[(]|@sh|getenv' \
    "$protocol" "$fixture_builder"; then
  fail execution-surface
fi
pass 'protocol and fixture builder have no product execution or network seam'

printf 'local Git materializer protocol: %s focused checks passed\n' "$passed"
