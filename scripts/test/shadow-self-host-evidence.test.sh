#!/usr/bin/env bash
# shellcheck disable=SC2016
# Requirements 15, 16 and 17 of work/shadow-self-host-run/spec.md, together in
# one file because all three read the same committed evidence bytes and none
# of them performs a real self-host reproduction, obtains credentials or
# invokes a model. Runs offline, in CI, on Linux.
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
evdir="$root/shadow/evidence/self-host-transition/v1"

fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-shadow-self-host-evidence.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() { /bin/chmod -R u+w "$tmp" 2>/dev/null || :; /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Provision the pinned jq 1.6 and the closure helper. This is ordinary CI
# suite provisioning of a pinned dependency, exactly as the other suites do it
# (scripts/test/shadow-slice.test.sh:24-51) - it is not inside requirement
# 10's run boundary, which belongs to the operator's evidence session, not to
# this offline check.
# ---------------------------------------------------------------------------
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
   [ "$(sha_file "$jq_cache")" != "$jq_sha" ]; then
  download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$download"
  [ "$(sha_file "$download")" = "$jq_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_cache"
fi
jqdir="$tmp/bin"
/bin/mkdir -m 700 "$jqdir"
/bin/cp "$jq_cache" "$jqdir/jq"
/bin/chmod 0555 "$jqdir/jq"
jq_bin="$jqdir/jq"
[ "$("$jq_bin" --version)" = jq-1.6 ] || fail 'jq identity'
/usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 \
  "$root/adapters/local-git-materializer/v1/object-closure.c" -o "$jqdir/object-closure"
/bin/chmod 0555 "$jqdir/object-closure"
run_path="$jqdir:/usr/bin:/bin"

# ---------------------------------------------------------------------------
# The complete expected evidence layout (work/shadow-self-host-run/plan.md,
# "Files that change" table): 15 shared files, 15 per case, 45 in all.
# ---------------------------------------------------------------------------
shared_files=(
  README.md verification-instructions.md checksums.json
  resolved-profile.json environment-claim.json control-policy-set.json
  requester.json core-package-closure.json duty-evaluation.json
  prerequisite/environment-declaration.json prerequisite/input.json
  prerequisite/stage-request.json prerequisite/resolved-profile-document.json
  prerequisite/stage-result.json prerequisite/materialization-receipt.json
)
per_case_files=(
  incident.json qualified-identity.json sandbox-evaluation.json
  materialization-receipt.json
  assembled/input.json assembled/stage-request-ref.json
  assembled/resolved-profile-ref.json assembled/finish-condition.txt
  assembled/verification-instructions.txt
  assembled/output-contract-decision.txt assembled/policy-decision.txt
  state/shadow-record.json state/trace-ledger.json state/trace-receipt.json
  state/materialization-result.json
)
all_relative_files=()
for f in "${shared_files[@]}"; do all_relative_files+=("$f"); done
for case_name in pre post; do
  for f in "${per_case_files[@]}"; do all_relative_files+=("$case_name/$f"); done
done
[ "${#all_relative_files[@]}" -eq 45 ] || fail 'evidence manifest must name 45 files'

# ---------------------------------------------------------------------------
# The precondition this whole suite depends on: the operator's evidence
# session has not run yet until every one of the 45 files above exists. That
# is expected on this branch before the operator hands the evidence back, and
# this check must fail loudly and explicitly about it rather than skip or
# silently pass, and rather than let a later check crash confusingly on an
# absent file.
# ---------------------------------------------------------------------------
missing=()
for relative in "${all_relative_files[@]}"; do
  [ -f "$evdir/$relative" ] || missing+=("$relative")
done
if [ "${#missing[@]}" -gt 0 ]; then
  /usr/bin/printf 'evidence not yet captured: %s\n' \
    "shadow/evidence/self-host-transition/v1/ is missing ${#missing[@]} of ${#all_relative_files[@]} required files" >&2
  for relative in "${missing[@]}"; do
    /usr/bin/printf 'evidence not yet captured: missing %s\n' \
      "shadow/evidence/self-host-transition/v1/$relative" >&2
  done
  /usr/bin/printf 'evidence not yet captured: this suite performs no self-host reproduction and cannot supply these bytes itself; see work/shadow-self-host-run/plan.md, "Operator steps".\n' >&2
  exit 1
fi

# ===========================================================================
# From here on, all 45 files are present. checks() runs requirement 15's
# thirteen checks over one evidence root (the real one, or a mutated copy of
# it for the negative cases in check 13) and returns non-zero on the first
# mismatch, naming it on stderr.
# ===========================================================================

canonical_ok() {
  local f=$1
  [ -s "$f" ] || return 1
  "$jq_bin" -e 'type != null' "$f" >/dev/null 2>&1 || return 1
  [ "$("$jq_bin" -s 'length' "$f" 2>/dev/null)" = 1 ] || return 1
  # Write the canonicalised copy under $tmp, never beside the file being
  # checked: this runs against the committed evidence tree itself first, and
  # a stray "$f.canon" left there would break the exact-inventory check
  # (check 1) on a second invocation and contaminate every negative-case copy
  # made from it.
  local canon rc
  canon=$(/usr/bin/mktemp "$tmp/canon.XXXXXX") || return 1
  "$jq_bin" -S -c . "$f" >"$canon" 2>/dev/null || { /bin/rm -f "$canon"; return 1; }
  /usr/bin/cmp -s "$f" "$canon"
  rc=$?
  /bin/rm -f "$canon"
  return $rc
}

# check_evidence: run requirement 15's thirteen checks (minus 13 itself,
# which drives this function from the outside) against evidence root $1.
# Prints the name of the first failed check on stderr and returns 1; returns
# 0 when every check passes. $2, if given, is a case-insensitive label used
# only in diagnostics.
check_evidence() {
  local dir=$1 label=${2:-evidence}
  local case_name step

  # --- check 1: checksums.json inventory is exact and every digest matches.
  step='checksums-inventory'
  [ -f "$dir/checksums.json" ] || { /usr/bin/printf '%s: %s\n' "$label" "$step: absent" >&2; return 1; }
  local found_files=() f rel
  while IFS= read -r f; do
    rel=${f#"$dir"/}
    [ "$rel" = checksums.json ] && continue
    found_files+=("$rel")
  done < <(/usr/bin/find "$dir" -type f | LC_ALL=C sort)
  local listed_count
  listed_count=$("$jq_bin" -e '.body.files | length' "$dir/checksums.json" 2>/dev/null) ||
    { /usr/bin/printf '%s: %s\n' "$label" "$step: malformed" >&2; return 1; }
  [ "$listed_count" -eq "${#found_files[@]}" ] ||
    { /usr/bin/printf '%s: %s (listed %s, found %s)\n' "$label" "$step" \
      "$listed_count" "${#found_files[@]}" >&2; return 1; }
  for rel in "${found_files[@]}"; do
    local listed_sha actual_sha
    listed_sha=$("$jq_bin" -e --arg p "$rel" \
      '[.body.files[] | select(.path == $p)] | if length == 1 then .[0].sha256 else empty end' \
      "$dir/checksums.json" 2>/dev/null) ||
      { /usr/bin/printf '%s: %s: %s not listed exactly once\n' "$label" "$step" "$rel" >&2; return 1; }
    listed_sha=${listed_sha//\"/}
    actual_sha=$(sha_file "$dir/$rel")
    [ "$listed_sha" = "$actual_sha" ] ||
      { /usr/bin/printf '%s: %s: %s digest mismatch\n' "$label" "$step" "$rel" >&2; return 1; }
  done

  # --- check 2: every .json is canonical jq -S -c, single text; the one
  # documented exception is core-package-closure.json, canonical with its
  # final newline removed.
  step='canonical-json'
  for rel in "${found_files[@]}"; do
    case "$rel" in
      *.json) ;;
      *) continue ;;
    esac
    if [ "$rel" = core-package-closure.json ]; then
      [ "$(/usr/bin/tail -c 1 "$dir/$rel" | /usr/bin/od -An -tx1 | /usr/bin/tr -d ' \n')" != 0a ] ||
        { /usr/bin/printf '%s: %s: %s must have no trailing newline\n' "$label" "$step" "$rel" >&2; return 1; }
      "$jq_bin" -S -c . "$dir/$rel" >"$tmp/closure.canon" 2>/dev/null ||
        { /usr/bin/printf '%s: %s: %s not parseable\n' "$label" "$step" "$rel" >&2; return 1; }
      /usr/bin/printf '%s' "$(cat "$tmp/closure.canon")" >"$tmp/closure.nonl"
      /usr/bin/cmp -s "$dir/$rel" "$tmp/closure.nonl" ||
        { /usr/bin/printf '%s: %s: %s not canonical (newline-stripped)\n' "$label" "$step" "$rel" >&2; return 1; }
      continue
    fi
    canonical_ok "$dir/$rel" ||
      { /usr/bin/printf '%s: %s: %s not canonical single-root JSON\n' "$label" "$step" "$rel" >&2; return 1; }
  done

  # --- check 3: each incident validates.
  step='incident-validates'
  for case_name in pre post; do
    PATH="$run_path" "$root/shadow/v1/validate-incident.sh" validate \
      "$dir/$case_name/incident.json" >/dev/null 2>"$tmp/$case_name.verr" ||
      { /usr/bin/printf '%s: %s: %s incident refused (%s)\n' "$label" "$step" "$case_name" \
        "$(cat "$tmp/$case_name.verr")" >&2; return 1; }
  done

  # --- check 4: qualified-identity binds the assembler's own emitted refs,
  # target_revision equals the case's own git_revision_ref, and each case's
  # verification_instructions_ref actually names the retained
  # verification-instructions.md bytes: the shape check in
  # shadow/v1/qualified-identity.jq only confirms this field is *a*
  # content_ref, never that it names the bundled file this offline proof
  # advertises as its minimal digest procedure. Both cases share the one
  # committed instructions file, so their refs must also agree with each
  # other, not merely each pass in isolation.
  #
  # The stage/profile ref comparison below used to stop at "the identity
  # names the same object as assembled/stage-request-ref.json and
  # assembled/resolved-profile-ref.json": three documents the assembler
  # itself emits together, so a mutation replacing the shared resolved
  # profile and refreshing all three consistently would sail through. Per
  # plan.md's own extraction recipe (`jq -S -c '.resolved_profile.content'
  # / '.stage_request.content'` on assembled/input.json, verified against
  # the assembler's stage-request-ref.json / resolved-profile-ref.json
  # sha256 fields), recompute both digests independently from the retained
  # bytes: resolved_profile_ref from the shared, retained resolved-profile.json
  # file (shadow/v1/materialization-input.jq: resolved_profile_sha256 is the
  # raw sha256 of that file, per assemble-materialization-input.sh:227), and
  # stage_request_ref from the canonicalized stage-request content embedded
  # in this case's own assembled/input.json (assemble-materialization-input.sh:
  # 404-411 canonicalizes the produced request with `jq -S -c` before hashing
  # it). Then require every one of the three documents (identity, assembled
  # ref file, and the input.json-embedded content) to agree with that
  # independently recomputed digest, not merely with each other.
  step='identity-binds-assembler-output'
  local vi_sha; vi_sha=$(sha_file "$dir/verification-instructions.md")
  local pre_vi_ref post_vi_ref
  local resolved_profile_sha; resolved_profile_sha=$(sha_file "$dir/resolved-profile.json")
  for case_name in pre post; do
    local identity="$dir/$case_name/qualified-identity.json"
    local req_ref="$dir/$case_name/assembled/stage-request-ref.json"
    local prof_ref="$dir/$case_name/assembled/resolved-profile-ref.json"
    local input="$dir/$case_name/assembled/input.json"
    local computed_req_sha computed_prof_sha
    computed_req_sha=$("$jq_bin" -S -c '.stage_request.content' "$input" 2>/dev/null |
      sha_file /dev/stdin) ||
      { /usr/bin/printf '%s: %s: %s stage_request content unreadable\n' "$label" "$step" "$case_name" >&2; return 1; }
    computed_prof_sha=$("$jq_bin" -S -c '.resolved_profile.content' "$input" 2>/dev/null |
      sha_file /dev/stdin) ||
      { /usr/bin/printf '%s: %s: %s resolved_profile content unreadable\n' "$label" "$step" "$case_name" >&2; return 1; }
    [ "$computed_prof_sha" = "$resolved_profile_sha" ] ||
      { /usr/bin/printf '%s: %s: %s resolved_profile embedded in input.json does not equal the retained resolved-profile.json bytes\n' "$label" "$step" "$case_name" >&2; return 1; }
    # input.json embeds each document alongside its own sha256 field
    # (shadow/v1/materialization-input.jq's input_document: stage_request and
    # resolved_profile are each {content, sha256}). The reference-file
    # comparisons above hash the embedded .content and compare it only to the
    # separate stage-request-ref.json/resolved-profile-ref.json files and to
    # the retained resolved-profile.json; neither the materializer nor any
    # other consumer validates the assembled input itself, so nothing before
    # this line has ever compared the embedded .sha256 fields against the
    # content they accompany. A digest field edited alone, with checksums.json
    # refreshed, would otherwise pass every check above.
    "$jq_bin" -e -n --slurpfile input "$input" \
      --arg req_sha "$computed_req_sha" --arg prof_sha "$computed_prof_sha" '
      $input[0].stage_request.sha256 == $req_sha and
      $input[0].resolved_profile.sha256 == $prof_sha
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s embedded stage_request.sha256/resolved_profile.sha256 in assembled/input.json does not match the content it accompanies\n' "$label" "$step" "$case_name" >&2; return 1; }
    "$jq_bin" -e -n --slurpfile identity "$identity" --slurpfile req "$req_ref" \
      --slurpfile prof "$prof_ref" \
      --arg req_sha "$computed_req_sha" --arg prof_sha "$computed_prof_sha" '
      $identity[0].body.stage_request_ref == $req[0] and
      $identity[0].body.resolved_profile_ref == $prof[0] and
      $req[0].sha256 == $req_sha and
      $prof[0].sha256 == $prof_sha
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s stage/profile ref mismatch or does not recompute from retained bytes\n' "$label" "$step" "$case_name" >&2; return 1; }
    "$jq_bin" -e -n --slurpfile identity "$identity" \
      --slurpfile incident "$dir/$case_name/incident.json" '
      $identity[0].body.target_revision == $incident[0].body.git_revision_ref
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s target_revision mismatch\n' "$label" "$step" "$case_name" >&2; return 1; }
    "$jq_bin" -e -n --slurpfile identity "$identity" --arg sha "$vi_sha" '
      $identity[0].body.verification_instructions_ref.sha256 == $sha
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s verification_instructions_ref does not name the retained verification-instructions.md bytes\n' "$label" "$step" "$case_name" >&2; return 1; }
    if [ "$case_name" = pre ]; then
      pre_vi_ref=$("$jq_bin" -c '.body.verification_instructions_ref' "$identity" 2>/dev/null)
    else
      post_vi_ref=$("$jq_bin" -c '.body.verification_instructions_ref' "$identity" 2>/dev/null)
    fi
  done

  # Review round 9's P2: prerequisite/input.json is never bound to the
  # retained prerequisite/stage-request.json and
  # prerequisite/resolved-profile-document.json bytes anywhere above -- the
  # duty evaluation's stage.request_ref/resolved_profile_ref (step
  # 'duty-evaluation' below) recompute against those two files directly, not
  # against prerequisite/input.json, and the fingerprint check further down
  # only reads prerequisite/environment-declaration.json. Bind
  # prerequisite/input.json to the same two retained files exactly as each
  # case's assembled/input.json is bound to its own retained bytes above:
  # recompute both embedded .content digests independently and compare them
  # (a) to the retained file bytes and (b) to the embedded .sha256 fields
  # that accompany them. Without this, prerequisite/input.json's embedded
  # request could disagree with the execution that actually produced the
  # duty evidence -- for example, a network_mode of "allow" -- while every
  # check in this suite still passed.
  step='prerequisite-input-binds-retained-bytes'
  local prereq_input="$dir/prerequisite/input.json"
  local prereq_req_sha prereq_prof_sha prereq_computed_req_sha prereq_computed_prof_sha
  prereq_req_sha=$(sha_file "$dir/prerequisite/stage-request.json")
  prereq_prof_sha=$(sha_file "$dir/prerequisite/resolved-profile-document.json")
  prereq_computed_req_sha=$("$jq_bin" -S -c '.stage_request.content' "$prereq_input" 2>/dev/null |
    sha_file /dev/stdin) ||
    { /usr/bin/printf '%s: %s: prerequisite stage_request content unreadable\n' "$label" "$step" >&2; return 1; }
  prereq_computed_prof_sha=$("$jq_bin" -S -c '.resolved_profile.content' "$prereq_input" 2>/dev/null |
    sha_file /dev/stdin) ||
    { /usr/bin/printf '%s: %s: prerequisite resolved_profile content unreadable\n' "$label" "$step" >&2; return 1; }
  [ "$prereq_computed_req_sha" = "$prereq_req_sha" ] &&
    [ "$prereq_computed_prof_sha" = "$prereq_prof_sha" ] ||
    { /usr/bin/printf '%s: %s: prerequisite/input.json embedded stage_request/resolved_profile content does not equal the retained prerequisite/stage-request.json or resolved-profile-document.json bytes\n' \
      "$label" "$step" >&2; return 1; }
  "$jq_bin" -e -n --slurpfile input "$prereq_input" \
    --arg req_sha "$prereq_computed_req_sha" --arg prof_sha "$prereq_computed_prof_sha" '
    $input[0].stage_request.sha256 == $req_sha and
    $input[0].resolved_profile.sha256 == $prof_sha
  ' >/dev/null 2>&1 ||
    { /usr/bin/printf '%s: %s: prerequisite/input.json embedded stage_request.sha256/resolved_profile.sha256 does not match the content it accompanies\n' \
      "$label" "$step" >&2; return 1; }

  # --- check 4b (requirement 16): each case's own shadow record must embed
  # the identity it actually ran under, byte for byte, and its
  # qualified_identity_ref must name the retained qualified-identity.json
  # bytes by digest. scope-gates.jq's shadow_record_ok only shape-checks a
  # record's embedded qualified_identity (comment at scope/v1/scope-gates.jq
  # ~618-622: "the field rules inside them are not repeated here"); full
  # field-level identity validation happens only for whichever single
  # identity is passed as the scope's own qualified_identity, and a record
  # that fails to match it is silently excluded from "mine" rather than
  # refused. So this offline check must independently bind each of the two
  # records to its own case's retained identity document — not rely on the
  # scope harness below, which only exercises one identity per invocation.
  step='record-binds-own-identity'
  for case_name in pre post; do
    local identity="$dir/$case_name/qualified-identity.json"
    local record="$dir/$case_name/state/shadow-record.json"
    local identity_sha; identity_sha=$(sha_file "$identity")
    "$jq_bin" -e -n --slurpfile identity "$identity" --slurpfile rec "$record" \
      --arg sha "$identity_sha" '
      $rec[0].body.qualified_identity == $identity[0].body and
      $rec[0].body.qualified_identity_ref == {content_id:"shadow-qualified-identity",
        media_type:"application/vnd.ystack.qualified-identity+json",sha256:$sha}
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s shadow record does not bind its own retained qualified-identity.json\n' "$label" "$step" "$case_name" >&2; return 1; }
  done
  [ -n "$pre_vi_ref" ] && [ "$pre_vi_ref" = "$post_vi_ref" ] ||
    { /usr/bin/printf '%s: %s: pre and post verification_instructions_ref (media type/content id/digest) do not agree on the one shared instructions file\n' "$label" "$step" >&2; return 1; }

  # --- check 4c (spec requirements 12-13): the identity's model_request,
  # adapter_config_refs, prompt_refs and skill_refs must actually come from
  # the selected profile, not merely be well-shaped and self-consistent with
  # the shadow record. qualified-identity.jq's qualified_identity_ok (copied
  # from scope/v1/workflow-scope.jq) only checks the shape of these fields,
  # and check 4b above only checks that a record embeds its own identity
  # byte for byte, so a fixture model/config/prompt/skill set consistently
  # carried by both documents would still pass. Derive the expected values
  # from the retained resolved-profile.json's producer binding (the only
  # binding with execution_kind "model") and the pinned producer config
  # (materialization-input.jq's producer_config_pin), per plan.md's
  # qualified-identity section: adapter_config_refs is the producer binding's
  # config ref (one entry, digest-bound to the pinned producer-config.json),
  # prompt_refs is the routines/coder.md prompt object the binding names,
  # skill_refs is the binding's own (empty) skill_refs, and model_request is
  # the model request the binding carries.
  step='identity-provenance'
  local producer_config_pin=ea076206d7f721aa4796c2a0830e95b3c7006703addc717240447c64ad589b61
  for case_name in pre post; do
    local identity="$dir/$case_name/qualified-identity.json"
    "$jq_bin" -e -n --slurpfile identity "$identity" --slurpfile profile "$dir/resolved-profile.json" \
      --arg pin "$producer_config_pin" '
      ([$profile[0].body.bindings[] | select(.binding.role == "producer")]) as $producers |
      ($producers | length) == 1 and
      $producers[0] as $producer |
      $producer.config_source.state == "present" and
      $producer.config_source.value.value_sha256 == $pin and
      $identity[0].body.model_request == $producer.binding.model_request and
      $identity[0].body.prompt_refs == [$producer.binding.prompt_ref] and
      $identity[0].body.skill_refs == $producer.binding.skill_refs and
      ($identity[0].body.adapter_config_refs | length) == 1 and
      $identity[0].body.adapter_config_refs[0].sha256 == $pin
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s model_request/adapter_config_refs/prompt_refs/skill_refs do not derive from the retained resolved-profile.json producer binding and the pinned producer config\n' "$label" "$step" "$case_name" >&2; return 1; }
  done

  # --- check 5: the two required outcomes, and the shared shadow-record
  # invariants. The failing check plan.md's "The two runs" (requirement 8)
  # names is the exact one this evidence must be proof of: file-digest at
  # config/construction-mode.json, expected b913cf62... (the pre-revision
  # blob at d3f6d52), observed b913cf62... on pre (matched) and 5b3e0baf...
  # on post (differed). check_block_ok in scope/v1/scope-gates.jq only
  # checks that the incident's own execution.value.matches_expected agrees
  # with its own failing_check.expected_sha256 — internal self-consistency —
  # never that either digest is the specific value the plan's outcome
  # section fixes, so evidence for an entirely different path or digest
  # would still pass every shape and consumer check. Assert the exact
  # object on both the retained incident and the shadow record it produced.
  step='outcomes'
  local expected_sha=b913cf629566dd532ca507a591cdec5cccb2611b12c63949daca6eb33cd15a93
  local post_observed_sha=5b3e0bafe63f84134e1b4aa2659e954bbbbd0bcc87d20716b03cd1b9d15a0fda
  local pre_observed_sha=$expected_sha
  for case_name in pre post; do
    "$jq_bin" -e -n --slurpfile i "$dir/$case_name/incident.json" --arg exp "$expected_sha" '
      $i[0].body.failing_check ==
        {kind:"file-digest",path:"config/construction-mode.json",expected_sha256:$exp}
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s incident.json does not name the exact failing check (config/construction-mode.json, expected b913cf62...)\n' "$label" "$step" "$case_name" >&2; return 1; }
  done
  "$jq_bin" -e -n --slurpfile r "$dir/post/state/shadow-record.json" \
    --arg exp "$expected_sha" --arg obs "$post_observed_sha" '
    $r[0].body.check.failing_check ==
      {kind:"file-digest",path:"config/construction-mode.json",expected_sha256:$exp} and
    $r[0].body.check.execution.value.observed_sha256 == $obs and
    $r[0].body.check.execution.value.matches_expected == false
  ' >/dev/null 2>&1 ||
    { /usr/bin/printf '%s: %s: post shadow record does not assert the exact failing-check object (config/construction-mode.json, expected b913cf62..., observed 5b3e0baf...)\n' "$label" "$step" >&2; return 1; }
  "$jq_bin" -e -n --slurpfile r "$dir/pre/state/shadow-record.json" \
    --arg exp "$expected_sha" --arg obs "$pre_observed_sha" '
    $r[0].body.check.failing_check ==
      {kind:"file-digest",path:"config/construction-mode.json",expected_sha256:$exp} and
    $r[0].body.check.execution.value.observed_sha256 == $obs and
    $r[0].body.check.execution.value.matches_expected == true
  ' >/dev/null 2>&1 ||
    { /usr/bin/printf '%s: %s: pre shadow record does not assert the exact failing-check object (config/construction-mode.json, expected and observed both b913cf62...)\n' "$label" "$step" >&2; return 1; }
  "$jq_bin" -e -n --slurpfile r "$dir/post/state/shadow-record.json" '
    $r[0].body.outcome == "reproduced" and
    $r[0].body.reason_id == "check.failed-at-revision" and
    $r[0].body.git_revision_ref.commit_id == "0427390224c25147650f1bd3b6e43ed6911b97a7"
  ' >/dev/null 2>&1 ||
    { /usr/bin/printf '%s: %s: post outcome wrong\n' "$label" "$step" >&2; return 1; }
  "$jq_bin" -e -n --slurpfile r "$dir/pre/state/shadow-record.json" '
    $r[0].body.outcome == "no-change" and
    $r[0].body.reason_id == "check.passed-at-revision" and
    $r[0].body.git_revision_ref.commit_id == "d3f6d525328838b9c2de819699e53d8909ab7a3f"
  ' >/dev/null 2>&1 ||
    { /usr/bin/printf '%s: %s: pre outcome wrong\n' "$label" "$step" >&2; return 1; }
  for case_name in pre post; do
    "$jq_bin" -e -n --slurpfile r "$dir/$case_name/state/shadow-record.json" '
      $r[0].body.authority == "none" and $r[0].body.deploy_authority == "none" and
      $r[0].body.shadow == true and $r[0].body.activation_state == "inactive" and
      $r[0].body.qualification == {state:"unavailable",reason_id:"shadow.unqualified"}
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s shared invariants wrong\n' "$label" "$step" "$case_name" >&2; return 1; }
  done

  # --- check 6: empty patch payload in both locations, network deny. The
  # cardinality check is copied verbatim from the driver's own guard
  # (shadow/v1/reproduce.sh:278-280: "== [\"\"]", not "all(. == \"\")"): the
  # driver's check requires the extracted array to have exactly one element,
  # the empty string, so a missing entry ([]) or a duplicate one (["", ""])
  # would satisfy "all(. == \"\")" while the real driver rejects both.
  step='no-patch-no-network'
  for case_name in pre post; do
    "$jq_bin" -e -n --slurpfile input "$dir/$case_name/assembled/input.json" '
      ([$input[0].payloads[] | select(.input_id == "input.producer-patch") | .data] == [""]) and
      ([$input[0].trust_context.verified_payloads[] |
        select(.input_id == "input.producer-patch") | .content.data] == [""]) and
      $input[0].stage_request.content.body.operation.arguments.network_mode == "deny"
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s patch/network invariant wrong\n' "$label" "$step" "$case_name" >&2; return 1; }
  done

  # --- check 7: materialization-result present, no-change, referenced
  # receipt resolves inside the bundle, and the three receipts (pre, post,
  # prerequisite) are pairwise distinct.
  step='materialization-result'
  local receipts=()
  for case_name in pre post; do
    local result="$dir/$case_name/state/materialization-result.json"
    local receipt="$dir/$case_name/materialization-receipt.json"
    local receipt_sha; receipt_sha=$(sha_file "$receipt")
    receipts+=("$receipt_sha")
    "$jq_bin" -e -n --slurpfile rec "$dir/$case_name/state/shadow-record.json" \
      --slurpfile result "$result" --arg sha "$(sha_file "$result")" '
      $rec[0].body.materialization.value.stage_result_ref.sha256 == $sha
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s record does not bind its own result\n' "$label" "$step" "$case_name" >&2; return 1; }
    "$jq_bin" -e -n --slurpfile result "$result" --arg sha "$receipt_sha" '
      $result[0].body.evidence[0].proof_ref.sha256 == $sha and
      $result[0].body.execution.metadata.tools.source_ref.sha256 == $sha and
      (($result[0].body.outputs // [])[0].ref.sha256 // $sha) == $sha
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s receipt does not resolve inside the bundle\n' "$label" "$step" "$case_name" >&2; return 1; }
    # The plan's offline check 7 requires a retained materialization to have
    # actually completed with no change, not merely to reference a result
    # document that resolves: a result reporting "changed", or one that never
    # completed, would still satisfy every check above by referencing itself
    # and its own receipt consistently. adapters/local-git-materializer/v1's
    # protocol (protocol.jq:388-390) emits body.status "completed" and
    # body.outcome {family:"change",value:...}; the self-host run's offline
    # check 7 names "no-change" as the value both retained cases must carry.
    "$jq_bin" -e -n --slurpfile result "$result" '
      $result[0].body.status == "completed" and
      $result[0].body.outcome == {family:"change",value:"no-change"}
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s materialization result is not a completed no-change materialization\n' "$label" "$step" "$case_name" >&2; return 1; }
    # Review round 8's P2: everything above resolves the result against its
    # own receipt and binds the shadow record to the result, but neither
    # consumer (scope-gates.jq, control/v1/sandbox.jq) ever checks that the
    # result's own body.request_ref/body.resolved_profile_ref actually name
    # this case's execution request and profile -- both consume the shadow
    # record, not the materialization result. Without this, a result naming
    # an unrelated stage request/profile would still pass every check above
    # by referencing itself and its own receipt consistently. Compare
    # against this case's own assembled reference files (already recomputed
    # from retained bytes and bound to qualified-identity.json in check 4:
    # "identity-binds-assembler-output"), all fields, not merely sha256.
    "$jq_bin" -e -n --slurpfile result "$result" \
      --slurpfile req "$dir/$case_name/assembled/stage-request-ref.json" \
      --slurpfile prof "$dir/$case_name/assembled/resolved-profile-ref.json" '
      $result[0].body.request_ref == $req[0] and
      $result[0].body.resolved_profile_ref == $prof[0]
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s materialization result request_ref/resolved_profile_ref does not equal the assembled references\n' "$label" "$step" "$case_name" >&2; return 1; }
  done
  local prereq_receipt_sha; prereq_receipt_sha=$(sha_file "$dir/prerequisite/materialization-receipt.json")
  # The prerequisite receipt must resolve against the prerequisite stage
  # result's own receipt-reference fields, exactly as check 7 requires of
  # each case's receipt above (plan.md ~750-755): otherwise a receipt
  # containing unrelated canonical JSON, with checksums.json refreshed to
  # match, would pass every check here by being merely present and distinct
  # from the two case receipts, leaving the duty evaluation's prerequisite
  # proof unrecoverable.
  "$jq_bin" -e -n --slurpfile result "$dir/prerequisite/stage-result.json" --arg sha "$prereq_receipt_sha" '
    $result[0].body.evidence[0].proof_ref.sha256 == $sha and
    $result[0].body.execution.metadata.tools.source_ref.sha256 == $sha and
    (($result[0].body.outputs // [])[0].ref.sha256 // $sha) == $sha
  ' >/dev/null 2>&1 ||
    { /usr/bin/printf '%s: %s: prerequisite receipt does not resolve against its stage result\n' "$label" "$step" >&2; return 1; }
  # Same binding as above for the prerequisite result, applying the round-5/6
  # derivation (plan.md ~1150-1158): the prerequisite has no separate
  # stage-request-ref.json/resolved-profile-ref.json pair, so its
  # request_ref/resolved_profile_ref are compared by digest against the
  # retained prerequisite/stage-request.json and
  # prerequisite/resolved-profile-document.json bytes -- the same two files
  # the duty-evaluation reference-mismatch check (step 'duty-evaluation')
  # already recomputes duty[0].body.stage.request_ref.sha256/
  # resolved_profile_ref.sha256 against.
  "$jq_bin" -e -n --slurpfile result "$dir/prerequisite/stage-result.json" \
    --arg req_sha "$(sha_file "$dir/prerequisite/stage-request.json")" \
    --arg prof_sha "$(sha_file "$dir/prerequisite/resolved-profile-document.json")" '
    $result[0].body.request_ref.sha256 == $req_sha and
    $result[0].body.resolved_profile_ref.sha256 == $prof_sha
  ' >/dev/null 2>&1 ||
    { /usr/bin/printf '%s: %s: prerequisite materialization result request_ref/resolved_profile_ref does not match its stage request/profile\n' "$label" "$step" >&2; return 1; }
  if [ "${receipts[0]}" = "${receipts[1]}" ] || \
     [ "${receipts[0]}" = "$prereq_receipt_sha" ] || \
     [ "${receipts[1]}" = "$prereq_receipt_sha" ]; then
    /usr/bin/printf '%s: %s: receipts are not pairwise distinct\n' "$label" "$step" >&2; return 1
  fi

  # --- check 8: the trace seal recomputes through the shipped validator, and
  # the receipt it returns is byte-identical to the committed one.
  step='trace-seal'
  for case_name in pre post; do
    local record_id
    record_id=$("$jq_bin" -r '.id' "$dir/$case_name/state/shadow-record.json")
    PATH="$run_path" "$root/telemetry/v1/validate-trace-ledger.sh" validate "$record_id" \
      attempt.shadow-reproduce "$dir/$case_name/state/trace-ledger.json" \
      >"$tmp/$case_name.trace-receipt.json" 2>"$tmp/$case_name.trace.err" ||
      { /usr/bin/printf '%s: %s: %s trace ledger does not reseal (%s)\n' "$label" "$step" \
        "$case_name" "$(cat "$tmp/$case_name.trace.err")" >&2; return 1; }
    /usr/bin/cmp -s "$tmp/$case_name.trace-receipt.json" \
      "$dir/$case_name/state/trace-receipt.json" ||
      { /usr/bin/printf '%s: %s: %s trace receipt mismatch\n' "$label" "$step" "$case_name" >&2; return 1; }
    "$jq_bin" -e -n --slurpfile rec "$dir/$case_name/state/shadow-record.json" \
      --arg sha "$(sha_file "$dir/$case_name/state/trace-ledger.json")" '
      $rec[0].body.trace_ledger_ref.sha256 == $sha
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s trace_ledger_ref mismatch\n' "$label" "$step" "$case_name" >&2; return 1; }
  done

  # --- check 9: each retained sandbox evaluation hashes to the record's own
  # reference to it.
  step='sandbox-evaluation-ref'
  for case_name in pre post; do
    "$jq_bin" -e -n --slurpfile rec "$dir/$case_name/state/shadow-record.json" \
      --arg sha "$(sha_file "$dir/$case_name/sandbox-evaluation.json")" '
      $rec[0].body.environment.evaluation.value.evaluation_ref.sha256 == $sha
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s\n' "$label" "$step" "$case_name" >&2; return 1; }
  done

  # --- check 9b: each case's sandbox evaluation claim_ref and shadow
  # record's environment.claim_ref are each bound to the retained
  # environment-claim.json bytes, not only to each other. Check 9 above and
  # requirement 2's reference recomputation (check 10 below) both leave a gap:
  # neither the sandbox evaluation's own claim_ref nor the shadow record's
  # environment.claim_ref is ever compared against the retained claim's
  # recomputed digest, so a case's evaluation and record could certify a claim
  # different from the one actually committed under this evidence tree. This
  # recomputes the claim's SHA-256 once and checks both consumer references
  # against it (all fields of each ref, not only sha256).
  step='claim-binding'
  local claim_sha; claim_sha=$(sha_file "$dir/environment-claim.json")
  for case_name in pre post; do
    "$jq_bin" -e -n --slurpfile claim "$dir/environment-claim.json" \
      --slurpfile ev "$dir/$case_name/sandbox-evaluation.json" --arg sha "$claim_sha" '
      $ev[0].body.claim_ref == {schema_version: $claim[0].schema_version,
        kind: $claim[0].kind, id: $claim[0].id, sha256: $sha}
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s sandbox evaluation claim_ref does not bind the retained environment-claim.json\n' \
        "$label" "$step" "$case_name" >&2; return 1; }
    "$jq_bin" -e -n --slurpfile rec "$dir/$case_name/state/shadow-record.json" --arg sha "$claim_sha" '
      $rec[0].body.environment.claim_ref == {content_id: "shadow-environment-claim",
        media_type: "application/vnd.ystack.control-execution-environment-claim+json",
        sha256: $sha}
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s shadow record environment.claim_ref does not bind the retained environment-claim.json\n' \
        "$label" "$step" "$case_name" >&2; return 1; }
  done

  # --- check 9c (review round 9's other P2): each retained
  # sandbox-evaluation.json's own policy_ref, decision_ref, policy_set and
  # duty_evaluation_ref are never resolved against the actual inputs
  # anywhere else in this suite -- check 9 only hashes the whole retained
  # file against the shadow record's evaluation_ref, check 9b only binds
  # claim_ref, and neither consumer (scope-gates.jq, control/v1/sandbox.jq)
  # reads the retained sandbox-evaluation.json at all (both consume the
  # shadow record's recorded copy). Replacing one of those four reference
  # digests and refreshing the shadow record's evaluation digest and
  # checksums.json downstream would satisfy every check above while naming
  # different or nonexistent policy/duty evidence.
  #
  # control/v1/sandbox.jq's own output (read above, "check 10" derivation)
  # embeds no timestamp or other run-varying field -- it is a pure function
  # of policy.json, decision.json, policy-set.json, duty.json and claim.json
  # -- so the strongest available check is to recompute it for real, through
  # the shipped, unmodified control/v1/evaluate-sandbox.sh, over the
  # retained control-policy-set.json/duty-evaluation.json/environment-claim.json
  # this evidence already commits to, and require the result to be
  # byte-identical to the retained sandbox-evaluation.json: identical bytes
  # can only occur when every one of those four reference fields (and the
  # verdict together with them) already names the real, retained inputs.
  step='sandbox-evaluation-inputs'
  for case_name in pre post; do
    PATH="$run_path" "$root/control/v1/evaluate-sandbox.sh" evaluate \
      "$dir/control-policy-set.json" "$dir/duty-evaluation.json" "$dir/environment-claim.json" \
      >"$tmp/$case_name.sandbox-eval-recomputed.json" 2>"$tmp/$case_name.sandbox-eval.err" ||
      { /usr/bin/printf '%s: %s: %s sandbox evaluation does not recompute over the retained control-policy-set.json/duty-evaluation.json/environment-claim.json (%s)\n' \
        "$label" "$step" "$case_name" "$(cat "$tmp/$case_name.sandbox-eval.err")" >&2; return 1; }
    /usr/bin/cmp -s "$tmp/$case_name.sandbox-eval-recomputed.json" \
      "$dir/$case_name/sandbox-evaluation.json" ||
      { /usr/bin/printf '%s: %s: %s retained sandbox-evaluation.json is not byte-identical to the shipped evaluate-sandbox.sh output over the retained control-policy-set.json/duty-evaluation.json/environment-claim.json (policy_ref/decision_ref/policy_set/duty_evaluation_ref do not all resolve)\n' \
        "$label" "$step" "$case_name" >&2; return 1; }
  done

  # --- check 10: the declaration-only marker, the all-ones demonstration
  # verifier digest kept and labelled (never absent), no overclaiming prose,
  # and requirement 2's full reference-field recomputation. The two runs the
  # plan describes both succeeded, so the retained sandbox-evaluation.json
  # for each case must itself be "satisfied" with the declaration-only
  # reason, and the shadow record's own recorded evaluation.value (verdict,
  # reason_ids — shadow/v1/reproduce.sh:430-434) must equal it field for
  # field: the record's consumers read that recorded copy, never the
  # retained sandbox-evaluation.json directly, so a mismatch there would let
  # the record claim a different result than the one actually evaluated.
  step='declaration-only-and-references'
  for case_name in pre post; do
    "$jq_bin" -e -n --slurpfile ev "$dir/$case_name/sandbox-evaluation.json" \
      --slurpfile rec "$dir/$case_name/state/shadow-record.json" '
      $ev[0].body.enforcement_proof == "declaration-only" and
      $ev[0].body.authority_effect == "none" and
      $ev[0].body.qualification_effect == "none" and
      $ev[0].body.verdict == "satisfied" and
      $ev[0].body.reason_ids == ["sandbox.declaration-satisfied"] and
      $rec[0].body.environment.evaluation.value.verdict == $ev[0].body.verdict and
      $rec[0].body.environment.evaluation.value.reason_ids == $ev[0].body.reason_ids
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s marker or recorded-evaluation mismatch\n' "$label" "$step" "$case_name" >&2; return 1; }
  done
  local all_ones; all_ones=$(printf '1%.0s' $(seq 1 64))
  "$jq_bin" -e -n --slurpfile claim "$dir/environment-claim.json" --arg ones "$all_ones" '
    ($claim[0].body.tools | length) > 0 and
    ($claim[0].body.tools | all(.sha256 == $ones))
  ' >/dev/null 2>&1 ||
    { /usr/bin/printf '%s: %s: claim must retain the shipped all-ones verifier digest\n' "$label" "$step" >&2; return 1; }
  /usr/bin/grep -Fq "$all_ones" "$root/shadow/evidence/self-host-transition/v1/README.md" 2>/dev/null ||
    /usr/bin/grep -Fq "$all_ones" "$dir/README.md" 2>/dev/null ||
    { /usr/bin/printf '%s: %s: README must label the shipped demonstration value\n' "$label" "$step" >&2; return 1; }
  # Ban affirmative overclaims ("this is sandbox-enforced / qualified /
  # proposable") without also banning a disclaimer that merely names and
  # negates the same phrase (the committed README's "It is **not**
  # sandbox-enforced", docs/components.md's "Nothing here is qualified").
  # Markdown emphasis characters are stripped first so "**not**" still reads
  # as the word "not" immediately before the phrase it negates.
  overclaim_found() {
    local f=$1
    [ -f "$f" ] || return 1
    /usr/bin/perl -0777 -ne '
      (my $t = $_) =~ tr/*`_//d;
      my @phrases = ("sandbox-enforced", "sandbox is enforced",
        "enforcement is proven", "proven enforcement", "is qualified",
        "is proposable");
      for my $p (@phrases) {
        while ($t =~ /\Q$p\E/gi) {
          my $s = $-[0];
          my $ctx = substr($t, $s > 60 ? $s - 60 : 0, $s > 60 ? 60 : $s);
          exit 0 unless $ctx =~ /\b(?:not|never|no|nothing)\b/i;
        }
      }
      while ($t =~ /workflow.{0,20}qualified/gis) {
        my $s = $-[0];
        my $ctx = substr($t, $s > 60 ? $s - 60 : 0, $s > 60 ? 60 : $s);
        exit 0 unless $ctx =~ /\b(?:not|never|no|nothing)\b/i;
      }
      exit 1
    ' "$f"
  }
  for f in "$root/shadow/evidence/self-host-transition/v1/README.md" \
    "$root/shadow/evidence/self-host-transition/v1/verification-instructions.md" \
    "$root/RESTORE.md" "$root/docs/components.md"; do
    if overclaim_found "$f"; then
      /usr/bin/printf '%s: %s: %s overclaims sandbox enforcement or qualification\n' \
        "$label" "$step" "$f" >&2
      return 1
    fi
  done
  # requirement 2's reference-field recomputation, over the real committed
  # bytes those fields name. Only the credential-policy section's shipped
  # policy filename omits the section's own "-policy" suffix a second time
  # (control/v1/credential-policy.json, not credential-policy-policy.json);
  # every other section follows the plain "$section-policy.json" pattern.
  policy_filename_for_section() {
    case "$1" in
      credential-policy) /usr/bin/printf '%s' 'credential-policy.json' ;;
      *) /usr/bin/printf '%s-policy.json' "$1" ;;
    esac
  }
  for section in credential-policy duty-separation evidence-integrity kill-switch \
    risk-gates sandbox; do
    local expect_policy expect_decision actual_policy actual_decision
    expect_policy=$(sha_file "$root/control/v1/$(policy_filename_for_section "$section")")
    expect_decision=$(sha_file "$root/control/v1/$section-decision.json")
    actual_policy=$("$jq_bin" -r --arg s "$section" \
      '.body.sections[] | select(.section_id == $s) | .policy_ref.sha256' "$dir/control-policy-set.json")
    actual_decision=$("$jq_bin" -r --arg s "$section" \
      '.body.sections[] | select(.section_id == $s) | .decision_ref.sha256' "$dir/control-policy-set.json")
    [ "$actual_policy" = "$expect_policy" ] && [ "$actual_decision" = "$expect_decision" ] ||
      { /usr/bin/printf '%s: %s: control-policy-set section %s reference mismatch\n' "$label" "$step" "$section" >&2; return 1; }
  done
  "$jq_bin" -e -n --slurpfile set "$dir/control-policy-set.json" \
    --arg closure_sha "$(sha_file "$dir/core-package-closure.json")" '
    $set[0].body.core_contract.package_ref.sha256 == $closure_sha
  ' >/dev/null 2>&1 ||
    { /usr/bin/printf '%s: %s: control-policy-set core package_ref mismatch\n' "$label" "$step" >&2; return 1; }
  "$jq_bin" -e -n --slurpfile duty "$dir/duty-evaluation.json" \
    --arg policy_sha "$(sha_file "$root/control/v1/duty-separation-policy.json")" \
    --arg decision_sha "$(sha_file "$root/control/v1/duty-separation-decision.json")" \
    --arg set_sha "$(sha_file "$dir/control-policy-set.json")" \
    --arg req_sha "$(sha_file "$dir/prerequisite/stage-request.json")" \
    --arg prof_sha "$(sha_file "$dir/prerequisite/resolved-profile-document.json")" \
    --arg result_sha "$(sha_file "$dir/prerequisite/stage-result.json")" '
    $duty[0].body.policy_ref.sha256 == $policy_sha and
    $duty[0].body.decision_ref.sha256 == $decision_sha and
    $duty[0].body.policy_set.sha256 == $set_sha and
    $duty[0].body.stage.request_ref.sha256 == $req_sha and
    $duty[0].body.stage.resolved_profile_ref.sha256 == $prof_sha and
    $duty[0].body.stage.result_ref.sha256 == $result_sha
  ' >/dev/null 2>&1 ||
    { /usr/bin/printf '%s: %s: duty-evaluation reference mismatch\n' "$label" "$step" >&2; return 1; }
  # The retained duty evaluation must actually be the satisfied verdict this
  # run needs, not merely reference-consistent (control/v1/duty-separation.jq:180,
  # the only satisfied form control/v1/sandbox.jq:135-137 accepts): a result
  # doctored to "violated" with its downstream hashes refreshed still passes
  # every reference check above.
  "$jq_bin" -e -n --slurpfile duty "$dir/duty-evaluation.json" '
    $duty[0].body.verdict == "satisfied" and
    $duty[0].body.reason_ids == ["duty.satisfied"]
  ' >/dev/null 2>&1 ||
    { /usr/bin/printf '%s: %s: duty-evaluation verdict is not satisfied\n' "$label" "$step" >&2; return 1; }
  # The claim's stage_result_ref is compared field for field against the duty
  # evaluation's own body.stage.result_ref (plan.md: "stage_result_ref copied
  # field for field from duty-evaluation.json's body.stage.result_ref") and
  # against the digest of the retained prerequisite/stage-result.json bytes it
  # names; checking only policy_set_ref and duty_evaluation_ref (as before)
  # left the claim free to point at any unrelated stage result, since neither
  # of those two fields names the stage result at all.
  "$jq_bin" -e -n --slurpfile claim "$dir/environment-claim.json" \
    --slurpfile duty "$dir/duty-evaluation.json" \
    --arg set_sha "$(sha_file "$dir/control-policy-set.json")" \
    --arg duty_sha "$(sha_file "$dir/duty-evaluation.json")" \
    --arg result_sha "$(sha_file "$dir/prerequisite/stage-result.json")" '
    $claim[0].body.policy_set_ref.sha256 == $set_sha and
    $claim[0].body.duty_evaluation_ref.sha256 == $duty_sha and
    $claim[0].body.stage_result_ref == $duty[0].body.stage.result_ref and
    $claim[0].body.stage_result_ref.sha256 == $result_sha
  ' >/dev/null 2>&1 ||
    { /usr/bin/printf '%s: %s: environment-claim reference mismatch\n' "$label" "$step" >&2; return 1; }
  # plan.md ~855-857: each assembled request's environment_ref.fingerprint_sha256
  # must equal the SHA-256 recomputed from the retained document it actually
  # names — the prerequisite request fingerprints
  # prerequisite/environment-declaration.json, and each case's request
  # fingerprints the retained environment-claim.json
  # (shadow/v1/materialization-input.jq:204: environment_ref is
  # {environment_id, fingerprint_sha256:$claim_sha256} for the case requests,
  # and the analogous prerequisite assembler fingerprints the declaration).
  # Nothing above this line ever compares the fingerprint field against the
  # document it claims to name, so a request could retain a fingerprint for a
  # different environment document than the one actually captured beside it.
  local decl_sha; decl_sha=$(sha_file "$dir/prerequisite/environment-declaration.json")
  "$jq_bin" -e -n --slurpfile input "$dir/prerequisite/input.json" --arg sha "$decl_sha" '
    $input[0].stage_request.content.body.environment_ref.fingerprint_sha256 == $sha
  ' >/dev/null 2>&1 ||
    { /usr/bin/printf '%s: %s: prerequisite assembled/input.json environment_ref.fingerprint_sha256 does not equal the retained environment-declaration.json digest\n' "$label" "$step" >&2; return 1; }
  for case_name in pre post; do
    "$jq_bin" -e -n --slurpfile input "$dir/$case_name/assembled/input.json" --arg sha "$claim_sha" '
      $input[0].stage_request.content.body.environment_ref.fingerprint_sha256 == $sha
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s assembled/input.json environment_ref.fingerprint_sha256 does not equal the retained environment-claim.json digest\n' "$label" "$step" "$case_name" >&2; return 1; }
  done
  # None of the reference fields requirement 2 names as identifying real
  # committed bytes may be a repeated-character placeholder of the kind
  # scripts/test/shadow-slice.test.sh builds its fixtures from
  # (work/shadow-self-host-run/spec.md requirement 2's precondition-gate
  # field list). This is scoped to exactly those fields, not every string in
  # the document: a whole-document scan would also reject the claim's
  # body.tools[].sha256, the shipped all-ones demonstration verifier digest
  # that requirement 2 requires this same claim to retain literally (checked
  # a few lines above).
  local placeholder_pat='\\A(.)\\1{63}\\z'
  if "$jq_bin" -e --arg pat "$placeholder_pat" '
      [.body.core_contract.package_ref.sha256,
       (.body.sections[].policy_ref.sha256), (.body.sections[].decision_ref.sha256)] |
      map(select(test($pat))) | length > 0
    ' "$dir/control-policy-set.json" >/dev/null 2>&1; then
    /usr/bin/printf '%s: %s: control-policy-set.json carries a placeholder reference digest\n' \
      "$label" "$step" >&2
    return 1
  fi
  if "$jq_bin" -e --arg pat "$placeholder_pat" '
      [.body.policy_ref.sha256, .body.decision_ref.sha256, .body.policy_set.sha256,
       .body.stage.request_ref.sha256, .body.stage.resolved_profile_ref.sha256,
       .body.stage.result_ref.sha256] |
      map(select(test($pat))) | length > 0
    ' "$dir/duty-evaluation.json" >/dev/null 2>&1; then
    /usr/bin/printf '%s: %s: duty-evaluation.json carries a placeholder reference digest\n' \
      "$label" "$step" >&2
    return 1
  fi
  if "$jq_bin" -e --arg pat "$placeholder_pat" '
      [.body.policy_set_ref.sha256, .body.duty_evaluation_ref.sha256,
       (.body.stage_result_ref.sha256 // empty)] |
      map(select(test($pat))) | length > 0
    ' "$dir/environment-claim.json" >/dev/null 2>&1; then
    /usr/bin/printf '%s: %s: environment-claim.json carries a placeholder reference digest\n' \
      "$label" "$step" >&2
    return 1
  fi

  # --- check 11: core-package-closure.json recovers the package reference
  # offline and its members recompute.
  step='core-package-closure'
  local closure_sha; closure_sha=$(sha_file "$dir/core-package-closure.json")
  [ "$closure_sha" = eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963 ] ||
    { /usr/bin/printf '%s: %s: digest mismatch\n' "$label" "$step" >&2; return 1; }
  local nl_sha
  nl_sha=$( { cat "$dir/core-package-closure.json"; printf '\n'; } | sha_file /dev/stdin)
  [ "$nl_sha" = 06dbd5ec60040dd0d913ca011fd296d7cce78d604bb887a3be0656698f535cf1 ] ||
    { /usr/bin/printf '%s: %s: newline-terminated digest does not match the known-different value\n' "$label" "$step" >&2; return 1; }
  local members_count
  members_count=$("$jq_bin" -e '.members | length' "$dir/core-package-closure.json" 2>/dev/null) &&
    [ "$members_count" -eq 9 ] ||
    { /usr/bin/printf '%s: %s: must name exactly nine members\n' "$label" "$step" >&2; return 1; }
  # Per the plan, this recovers the package reference from the live
  # committed working tree, not from a historical Git revision: a shallow CI
  # checkout (actions/checkout's default depth) does not carry the object for
  # d3f6d525328838b9c2de819699e53d8909ab7a3f, so `git show <rev>:<path>` would
  # fail every run once the earlier checks pass, regardless of the evidence.
  # The closure names a fixed, immutable generation (scripts/core-contract.sh
  # and core/v2/generations/<selected-generation>/**), so its nine members'
  # committed bytes at the current head equal their bytes at the pinned
  # revision; requirement 11 is "the nine members' digests equal the live
  # digests of those nine committed files at the pinned generation."
  local i mpath msha live_sha
  i=0
  while [ "$i" -lt 9 ]; do
    mpath=$("$jq_bin" -r --argjson i "$i" '.members[$i].path' "$dir/core-package-closure.json")
    msha=$("$jq_bin" -r --argjson i "$i" '.members[$i].sha256' "$dir/core-package-closure.json")
    [ -f "$root/$mpath" ] ||
      { /usr/bin/printf '%s: %s: member %s not resolvable in the committed tree\n' "$label" "$step" "$mpath" >&2; return 1; }
    live_sha=$(sha_file "$root/$mpath")
    [ "$msha" = "$live_sha" ] ||
      { /usr/bin/printf '%s: %s: member %s digest mismatch\n' "$label" "$step" "$mpath" >&2; return 1; }
    i=$((i + 1))
  done

  # --- check 12: requester.json digest, shape, role and identity
  # distinctness, and that every retained assembly used it verbatim.
  step='requester-identity'
  local requester_sha; requester_sha=$(sha_file "$dir/requester.json")
  [ "$requester_sha" = 7596d803e09956c24a627d29558b22a583369080ac653941816c0fbadb2d68cd ] ||
    { /usr/bin/printf '%s: %s: digest mismatch\n' "$label" "$step" >&2; return 1; }
  local sel_full sel_dir
  sel_full=$(/usr/bin/sed -n \
    "s/^PORTABLE_CORE_GENERATION='\\(g-[0-9a-f]\\{64\\}\\)'\$/\\1/p" \
    "$root/scripts/core-contract.sh")
  sel_dir="$root/core/v2/generations/$sel_full/modules"
  "$jq_bin" -L "$sel_dir" -e -n --slurpfile r "$dir/requester.json" \
    'import "schema" as schema; $r[0] | schema::actor_ref_ok' >/dev/null 2>&1 ||
    { /usr/bin/printf '%s: %s: requester fails schema::actor_ref_ok\n' "$label" "$step" >&2; return 1; }
  "$jq_bin" -e -n --slurpfile r "$dir/requester.json" '$r[0].role == "operator"' \
    >/dev/null 2>&1 ||
    { /usr/bin/printf '%s: %s: requester role must be operator\n' "$label" "$step" >&2; return 1; }
  "$jq_bin" -e -n --slurpfile r "$dir/requester.json" \
    --slurpfile profile "$root/profiles/default/v1/profile.json" '
    ($profile[0].body.bindings | map(.adapter_instance_id, .execution_boundary_id, .principal_id)) as $bound |
    ([$r[0].adapter_instance_id, $r[0].execution_boundary_id, $r[0].principal_id] |
     any(. as $v | $bound | index($v) != null)) | not
  ' >/dev/null 2>&1 ||
    { /usr/bin/printf '%s: %s: requester identity collides with a protected binding\n' "$label" "$step" >&2; return 1; }
  for input in "$dir/pre/assembled/input.json" "$dir/post/assembled/input.json" \
    "$dir/prerequisite/input.json"; do
    "$jq_bin" -e -n --slurpfile input "$input" --slurpfile r "$dir/requester.json" '
      $input[0].stage_request.content.body.requested_by == $r[0]
    ' >/dev/null 2>&1 ||
      { /usr/bin/printf '%s: %s: %s does not carry the approved requester\n' "$label" "$step" "$input" >&2; return 1; }
  done

  return 0
}

check_evidence "$evdir" 'evidence' || fail 'the committed evidence fails one or more offline checks'
pass 'the committed evidence passes checksums.json inventory, canonical JSON, incident validation, identity/reference equality (both assembler refs recomputed from retained bytes, including the embedded stage_request.sha256/resolved_profile.sha256 fields), the prerequisite input binding to its retained request/profile extracts, each record binding its own retained identity, identity provenance against the resolved profile producer binding and pinned producer config, both outcomes, empty-patch/network-deny, materialization, trace seal, sandbox evaluation matching the recorded, sandbox evaluation recomputing byte-identical through the shipped evaluator over the retained policy-set/duty/claim, satisfied verdict, claim binding, declaration-only marker with reference recomputation (including each assembled requests own environment_ref.fingerprint_sha256 against the retained declaration/claim it names), core package closure, and the approved requester'

# ---------------------------------------------------------------------------
# check 13: negative cases. A copy of the evidence tree, mutated one way at a
# time, must fail check_evidence. A test that passes on altered evidence
# proves nothing.
# ---------------------------------------------------------------------------
mutant_dir="$tmp/mutant"

# Give each negative case a fresh, unmutated copy of the evidence tree: a
# reused directory that already exists makes "cp -R $evdir $mutant_dir" nest
# a second "v1" directory inside it instead of restoring the original files,
# so every case after the first would fail from the leftover extra inventory
# and prior corruption rather than from its own mutation. Confirming the
# fresh copy passes first proves each case starts from a clean baseline.
fresh_mutant_copy() {
  /bin/rm -rf -- "$mutant_dir"
  /bin/cp -R "$evdir" "$mutant_dir"
  /bin/chmod -R u+w "$mutant_dir"
  check_evidence "$mutant_dir" 'mutant-baseline' >/dev/null 2>&1 ||
    fail 'a freshly copied, unmutated evidence tree must pass before it is mutated'
}

# refresh_checksums: recompute checksums.json's body.files inventory over the
# tree at $1, keeping every other field of the document as committed. Some
# negative cases below are about a check deeper than checksums-inventory
# (check 1); mutating a file without this would always be caught by check 1
# first, proving nothing about the check the case is actually targeting.
refresh_checksums() {
  local dir=$1 f rel
  local entries="$tmp/refresh-checksums-entries.json"
  /usr/bin/printf '[]' >"$entries"
  while IFS= read -r f; do
    rel=${f#"$dir"/}
    [ "$rel" = checksums.json ] && continue
    "$jq_bin" -c --arg p "$rel" --arg s "$(sha_file "$f")" \
      '. + [{path:$p,sha256:$s}]' "$entries" >"$entries.new"
    /bin/mv "$entries.new" "$entries"
  done < <(/usr/bin/find "$dir" -type f | LC_ALL=C sort)
  "$jq_bin" -S -c --slurpfile entries "$entries" \
    '.body.files = ($entries[0] | sort_by(.path))' \
    "$dir/checksums.json" >"$dir/checksums.json.new"
  /bin/mv "$dir/checksums.json.new" "$dir/checksums.json"
}

# refresh_claim_chain: after environment-claim.json's bytes change (so its own
# digest moves), rewrite every downstream reference that names that digest by
# value rather than deriving it: both cases' sandbox-evaluation.json
# claim_ref.sha256 (check 9b), and both shadow records' own
# environment.claim_ref.sha256 (check 9b) plus
# environment.evaluation.value.evaluation_ref.sha256 (check 9), which must
# also move because rewriting a sandbox evaluation's claim_ref changes that
# file's own digest in turn. Without this, a negative case that mutates
# environment-claim.json to reach some check deeper than 9b/9 (for example the
# duty-verdict or environment-claim reference-mismatch assertions in check 10)
# would instead be refused by check 9b or check 9 first, proving nothing about
# the check it actually targets.
refresh_claim_chain() {
  local dir=$1 case_name claim_sha eval_sha
  claim_sha=$(sha_file "$dir/environment-claim.json")
  for case_name in pre post; do
    "$jq_bin" -S -c --arg sha "$claim_sha" '.body.claim_ref.sha256 = $sha' \
      "$dir/$case_name/sandbox-evaluation.json" >"$dir/$case_name/sandbox-evaluation.json.new"
    /bin/mv "$dir/$case_name/sandbox-evaluation.json.new" "$dir/$case_name/sandbox-evaluation.json"
    eval_sha=$(sha_file "$dir/$case_name/sandbox-evaluation.json")
    "$jq_bin" -S -c --arg claim_sha "$claim_sha" --arg eval_sha "$eval_sha" '
      .body.environment.claim_ref.sha256 = $claim_sha |
      .body.environment.evaluation.value.evaluation_ref.sha256 = $eval_sha
    ' "$dir/$case_name/state/shadow-record.json" >"$dir/$case_name/state/shadow-record.json.new"
    /bin/mv "$dir/$case_name/state/shadow-record.json.new" "$dir/$case_name/state/shadow-record.json"
  done
}

# (a) a single evidence file's bytes change.
fresh_mutant_copy
"$jq_bin" -S -c '.body.reason_id = "check.failed-at-revision-mutated"' \
  "$mutant_dir/pre/state/shadow-record.json" >"$mutant_dir/pre/state/shadow-record.json.new"
/bin/mv "$mutant_dir/pre/state/shadow-record.json.new" "$mutant_dir/pre/state/shadow-record.json"
if check_evidence "$mutant_dir" 'mutant-file' 2>/dev/null; then
  fail 'a mutated evidence file must be refused'
fi
pass 'a mutated evidence file is refused'

# (b) a digest inside checksums.json is corrupted, restoring the file itself.
fresh_mutant_copy
"$jq_bin" -S -c '
  .body.files |= map(if .path == "README.md"
    then .sha256 = ("0" * 64) else . end)
' "$mutant_dir/checksums.json" >"$mutant_dir/checksums.json.new"
/bin/mv "$mutant_dir/checksums.json.new" "$mutant_dir/checksums.json"
if check_evidence "$mutant_dir" 'mutant-checksum' 2>/dev/null; then
  fail 'a corrupted checksums.json digest must be refused'
fi
pass 'a corrupted checksums.json digest is refused'

# (c) an outcome field is changed.
fresh_mutant_copy
"$jq_bin" -S -c '.body.outcome = "no-change" | .body.reason_id = "check.passed-at-revision"' \
  "$mutant_dir/post/state/shadow-record.json" >"$mutant_dir/post/state/shadow-record.json.new"
/bin/mv "$mutant_dir/post/state/shadow-record.json.new" "$mutant_dir/post/state/shadow-record.json"
if check_evidence "$mutant_dir" 'mutant-outcome' 2>/dev/null; then
  fail 'a mutated outcome field must be refused'
fi
pass 'a mutated outcome field is refused'

# (d) a retained materialization result reports a changed outcome instead of
# no-change, with the shadow record's own result reference AND checksums.json
# both refreshed, so only check 7's new completed/no-change assertion — not
# its earlier "record does not bind its own result" assertion, and not the
# checksums-inventory check — can catch it. Leaving the shadow record's
# stage_result_ref pointing at the original bytes would make this case fail
# on that earlier, unrelated assertion instead, proving nothing about the
# completed/no-change check this case exists to exercise.
fresh_mutant_copy
"$jq_bin" -S -c '.body.outcome.value = "changed"' \
  "$mutant_dir/post/state/materialization-result.json" \
  >"$mutant_dir/post/state/materialization-result.json.new"
/bin/mv "$mutant_dir/post/state/materialization-result.json.new" \
  "$mutant_dir/post/state/materialization-result.json"
mutated_result_sha=$(sha_file "$mutant_dir/post/state/materialization-result.json")
"$jq_bin" -S -c --arg sha "$mutated_result_sha" \
  '.body.materialization.value.stage_result_ref.sha256 = $sha' \
  "$mutant_dir/post/state/shadow-record.json" >"$mutant_dir/post/state/shadow-record.json.new"
/bin/mv "$mutant_dir/post/state/shadow-record.json.new" \
  "$mutant_dir/post/state/shadow-record.json"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-materialization-outcome' 2>"$tmp/mat-outcome.err"; then
  fail 'a retained materialization result reporting a changed outcome must be refused'
fi
/usr/bin/grep -q 'materialization result is not a completed no-change materialization' \
  "$tmp/mat-outcome.err" ||
  fail "a retained materialization result reporting a changed outcome must fail specifically on the completed/no-change assertion, not an earlier one ($(cat "$tmp/mat-outcome.err"))"
pass 'a retained materialization result reporting a changed outcome instead of no-change is refused specifically by the completed/no-change assertion'

# (e) the environment claim's stage_result_ref points at an unrelated result
# rather than the duty evaluation's own stage.result_ref and the retained
# prerequisite stage result, with the claim-reference chain and
# checksums.json refreshed so only the environment-claim reference-mismatch
# assertion in check 10 — not the earlier claim-binding check (9b), which
# would otherwise refuse first on the claim's own now-moved digest, and not
# the checksums-inventory check — can catch it.
fresh_mutant_copy
"$jq_bin" -S -c '.body.stage_result_ref.sha256 =
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
  "$mutant_dir/environment-claim.json" >"$mutant_dir/environment-claim.json.new"
/bin/mv "$mutant_dir/environment-claim.json.new" "$mutant_dir/environment-claim.json"
refresh_claim_chain "$mutant_dir"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-claim-stage-result' 2>"$tmp/claim-stage-result.err"; then
  fail 'an environment claim pointing at an unrelated stage result must be refused'
fi
/usr/bin/grep -q 'environment-claim reference mismatch' "$tmp/claim-stage-result.err" ||
  fail "an environment claim pointing at an unrelated stage result must fail specifically on the environment-claim reference-mismatch check ($(cat "$tmp/claim-stage-result.err"))"
pass 'an environment claim whose stage_result_ref does not match the duty evaluation and the retained prerequisite stage result (claim-reference chain and checksums refreshed) is refused specifically by the environment-claim reference-mismatch check'

# (f) the retained verification-instructions.md bytes are edited after the
# qualified-identity.json refs were computed, with checksums.json refreshed
# so only the new verification_instructions_ref digest check (check 4) —
# not the checksums-inventory check — can catch it.
fresh_mutant_copy
/usr/bin/printf '\n<!-- mutated -->\n' >>"$mutant_dir/verification-instructions.md"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-verification-instructions' 2>"$tmp/vi.err"; then
  fail 'edited verification-instructions.md bytes must be refused'
fi
/usr/bin/grep -q 'verification_instructions_ref does not name the retained verification-instructions.md bytes' \
  "$tmp/vi.err" ||
  fail "edited verification-instructions.md bytes must fail specifically on the verification_instructions_ref digest check ($(cat "$tmp/vi.err"))"
pass "edited verification-instructions.md bytes are refused because the identities' verification_instructions_ref no longer names them"

# (g) the producer-patch payload entry is removed entirely (an empty array),
# which the driver's exact cardinality check ([...] == [""]) refuses but the
# earlier, looser "all(. == \"\")" predicate would vacuously accept.
fresh_mutant_copy
"$jq_bin" -S -c '.payloads |= map(select(.input_id != "input.producer-patch"))' \
  "$mutant_dir/post/assembled/input.json" >"$mutant_dir/post/assembled/input.json.new"
/bin/mv "$mutant_dir/post/assembled/input.json.new" "$mutant_dir/post/assembled/input.json"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-patch-missing' 2>/dev/null; then
  fail 'a missing producer-patch payload entry must be refused'
fi
pass 'a missing producer-patch payload entry (an empty array where the driver requires exactly one empty string) is refused'

# (h) the producer-patch entry is duplicated in trust_context.verified_payloads
# (two elements, both the empty string), which the same exact cardinality
# check refuses but "all(. == \"\")" would again vacuously accept.
fresh_mutant_copy
"$jq_bin" -S -c \
  '.trust_context.verified_payloads +=
     ([.trust_context.verified_payloads[] | select(.input_id == "input.producer-patch")] | .[0:1])' \
  "$mutant_dir/post/assembled/input.json" >"$mutant_dir/post/assembled/input.json.new"
/bin/mv "$mutant_dir/post/assembled/input.json.new" "$mutant_dir/post/assembled/input.json"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-patch-duplicate' 2>/dev/null; then
  fail 'a duplicated producer-patch verified-payload entry must be refused'
fi
pass 'a duplicated producer-patch verified-payload entry (two empty strings where the driver requires exactly one) is refused'

# (i) the retained environment-claim.json is swapped for a claim that differs
# from the one the sandbox evaluations and shadow records were actually
# produced from (body.network.mode flipped to "allow"), with checksums.json
# refreshed so only the new claim-binding check (check 9b) — not the
# checksums-inventory check — can catch it. Every other retained document
# (sandbox-evaluation.json's claim_ref, the shadow records' environment.
# claim_ref, the duty evaluation, the policy set) still names the original
# claim bytes by digest, so this proves the binding check actually compares
# those references against the retained claim's own recomputed hash, not
# just against each other.
fresh_mutant_copy
"$jq_bin" -S -c '.body.network.mode = "allow"' \
  "$mutant_dir/environment-claim.json" >"$mutant_dir/environment-claim.json.new"
/bin/mv "$mutant_dir/environment-claim.json.new" "$mutant_dir/environment-claim.json"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-claim-network-mode' 2>"$tmp/claim-binding.err"; then
  fail 'a retained environment claim with its network.mode swapped to allow must be refused'
fi
/usr/bin/grep -q 'claim_ref does not bind the retained environment-claim.json' \
  "$tmp/claim-binding.err" ||
  fail "a retained environment claim with its network.mode swapped to allow must fail specifically on the claim-binding check ($(cat "$tmp/claim-binding.err"))"
pass 'a retained environment claim whose network.mode is swapped to allow (recomputed checksums, otherwise-unchanged consumer references) is refused specifically by the claim-binding check'

# (j) the shared resolved-profile.json is replaced by a different (but still
# canonical) resolved profile document, with checksums.json refreshed, so
# only the recomputation added to check 4 — comparing both assemblers'
# resolved_profile_ref against the retained resolved-profile.json's own
# recomputed SHA-256, and the content embedded in each case's
# assembled/input.json against those same retained bytes — can catch it.
# Before that recomputation, every reference agreed only with every other
# reference, so swapping the shared document out from under all of them
# while refreshing checksums.json left every check passing.
fresh_mutant_copy
"$jq_bin" -S -c '. + {"self-host-fix-373-mutant": true}' \
  "$mutant_dir/resolved-profile.json" >"$mutant_dir/resolved-profile.json.new"
/bin/mv "$mutant_dir/resolved-profile.json.new" "$mutant_dir/resolved-profile.json"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-resolved-profile-swap' 2>"$tmp/resolved-profile.err"; then
  fail 'a replaced shared resolved-profile.json must be refused'
fi
/usr/bin/grep -q 'resolved_profile embedded in input.json does not equal the retained resolved-profile.json bytes' \
  "$tmp/resolved-profile.err" ||
  fail "a replaced shared resolved-profile.json must fail specifically on the recomputed resolved_profile_ref check ($(cat "$tmp/resolved-profile.err"))"
pass 'a replaced shared resolved-profile.json (recomputed checksums, otherwise-unchanged consumer references) is refused specifically by the recomputed resolved_profile_ref check'

# (k) the pre case's qualified-identity.json has its model_request changed,
# with checksums.json refreshed, so only the new check 4b — binding each
# case's own shadow record to its own retained identity document, byte for
# byte — can catch it: every other check compares the identity only against
# the assembler's own emitted refs and the incident, none of which name the
# model_request field this mutation touches.
fresh_mutant_copy
"$jq_bin" -S -c \
  '.body.model_request.model_id = "claude-mutant-5"' \
  "$mutant_dir/pre/qualified-identity.json" >"$mutant_dir/pre/qualified-identity.json.new"
/bin/mv "$mutant_dir/pre/qualified-identity.json.new" "$mutant_dir/pre/qualified-identity.json"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-pre-identity-model' 2>"$tmp/pre-identity.err"; then
  fail "a mutated pre identity's model_request must be refused"
fi
/usr/bin/grep -q 'shadow record does not bind its own retained qualified-identity.json' \
  "$tmp/pre-identity.err" ||
  fail "a mutated pre identity's model_request must fail specifically on the record-binds-own-identity check ($(cat "$tmp/pre-identity.err"))"
pass "a mutated pre identity's model_request (recomputed checksums, otherwise-unchanged consumer references) is refused specifically by the record-binds-own-identity check"

# (l) the post case's retained sandbox-evaluation.json reports a violated
# verdict, with the shadow record's own evaluation_ref digest and
# checksums.json refreshed so only check 10's new requirement — that the
# retained verdict and reason_ids equal the record's own recorded
# evaluation.value and are themselves "satisfied" — can catch it. The
# record's own recorded verdict/reason_ids are left untouched at
# satisfied/["sandbox.declaration-satisfied"], so before this addition the
# scope consumer (which reads only the record's recorded copy) would accept
# contradictory evidence the driver could never actually produce.
fresh_mutant_copy
"$jq_bin" -S -c '.body.verdict = "violated" | .body.reason_ids = ["sandbox.violated"]' \
  "$mutant_dir/post/sandbox-evaluation.json" >"$mutant_dir/post/sandbox-evaluation.json.new"
/bin/mv "$mutant_dir/post/sandbox-evaluation.json.new" "$mutant_dir/post/sandbox-evaluation.json"
mutated_sandbox_sha=$(sha_file "$mutant_dir/post/sandbox-evaluation.json")
"$jq_bin" -S -c --arg sha "$mutated_sandbox_sha" \
  '.body.environment.evaluation.value.evaluation_ref.sha256 = $sha' \
  "$mutant_dir/post/state/shadow-record.json" >"$mutant_dir/post/state/shadow-record.json.new"
/bin/mv "$mutant_dir/post/state/shadow-record.json.new" "$mutant_dir/post/state/shadow-record.json"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-sandbox-verdict-violated' 2>"$tmp/sandbox-verdict.err"; then
  fail 'a retained sandbox evaluation reporting a violated verdict must be refused'
fi
/usr/bin/grep -q 'marker or recorded-evaluation mismatch' \
  "$tmp/sandbox-verdict.err" ||
  fail "a retained sandbox evaluation reporting a violated verdict must fail specifically on the declaration-only-and-references check ($(cat "$tmp/sandbox-verdict.err"))"
pass 'a retained sandbox evaluation reporting a violated verdict (record digest and checksums refreshed, recorded verdict left satisfied) is refused specifically by the declaration-only-and-references check'

# (m) the pre case's assembled/input.json has its embedded
# .stage_request.sha256 field corrupted while the .content it accompanies,
# every reference file and the retained resolved-profile.json are left
# untouched, so only the new embedded-digest comparison added to check 4 —
# not the existing reference-file comparisons, none of which read this
# field — can catch it.
fresh_mutant_copy
bad_sha=$(/usr/bin/printf 'f%.0s' $(seq 1 64))
"$jq_bin" -S -c --arg s "$bad_sha" '.stage_request.sha256 = $s' \
  "$mutant_dir/pre/assembled/input.json" >"$mutant_dir/pre/assembled/input.json.new"
/bin/mv "$mutant_dir/pre/assembled/input.json.new" "$mutant_dir/pre/assembled/input.json"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-embedded-stage-request-sha' 2>"$tmp/embed-req.err"; then
  fail 'a corrupted embedded stage_request.sha256 field in assembled/input.json must be refused'
fi
/usr/bin/grep -q 'embedded stage_request.sha256/resolved_profile.sha256 in assembled/input.json does not match the content it accompanies' \
  "$tmp/embed-req.err" ||
  fail "a corrupted embedded stage_request.sha256 field must fail specifically on the new embedded-digest check ($(cat "$tmp/embed-req.err"))"
pass 'a corrupted embedded stage_request.sha256 field in assembled/input.json (content, reference files and resolved-profile.json all left untouched) is refused specifically by the embedded-digest check'

# (n) the same, but for the embedded .resolved_profile.sha256 field, proving
# the new check covers both embedded digest fields independently.
fresh_mutant_copy
bad_sha=$(/usr/bin/printf 'e%.0s' $(seq 1 64))
"$jq_bin" -S -c --arg s "$bad_sha" '.resolved_profile.sha256 = $s' \
  "$mutant_dir/post/assembled/input.json" >"$mutant_dir/post/assembled/input.json.new"
/bin/mv "$mutant_dir/post/assembled/input.json.new" "$mutant_dir/post/assembled/input.json"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-embedded-resolved-profile-sha' 2>"$tmp/embed-prof.err"; then
  fail 'a corrupted embedded resolved_profile.sha256 field in assembled/input.json must be refused'
fi
/usr/bin/grep -q 'embedded stage_request.sha256/resolved_profile.sha256 in assembled/input.json does not match the content it accompanies' \
  "$tmp/embed-prof.err" ||
  fail "a corrupted embedded resolved_profile.sha256 field must fail specifically on the new embedded-digest check ($(cat "$tmp/embed-prof.err"))"
pass 'a corrupted embedded resolved_profile.sha256 field in assembled/input.json (content, reference files and resolved-profile.json all left untouched) is refused specifically by the embedded-digest check'

# (o) the pre case's qualified-identity.json has its model_request changed
# consistently with its own shadow record (both documents, both hashes
# refreshed together), so check 4b's byte-for-byte record/identity binding
# still passes and only the new identity-provenance check — comparing the
# identity's model_request against the retained resolved-profile.json's
# producer binding — can catch it.
fresh_mutant_copy
"$jq_bin" -S -c '.body.model_request.model_id = "claude-mutant-5"' \
  "$mutant_dir/pre/qualified-identity.json" >"$mutant_dir/pre/qualified-identity.json.new"
/bin/mv "$mutant_dir/pre/qualified-identity.json.new" "$mutant_dir/pre/qualified-identity.json"
mutated_identity_sha=$(sha_file "$mutant_dir/pre/qualified-identity.json")
"$jq_bin" -S -c --arg sha "$mutated_identity_sha" '
  .body.qualified_identity.model_request.model_id = "claude-mutant-5" |
  .body.qualified_identity_ref.sha256 = $sha
' "$mutant_dir/pre/state/shadow-record.json" >"$mutant_dir/pre/state/shadow-record.json.new"
/bin/mv "$mutant_dir/pre/state/shadow-record.json.new" "$mutant_dir/pre/state/shadow-record.json"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-pre-identity-model-consistent' 2>"$tmp/pre-identity-provenance.err"; then
  fail "a pre identity's model_request altered consistently in the identity and its own shadow record must be refused"
fi
/usr/bin/grep -q 'model_request/adapter_config_refs/prompt_refs/skill_refs do not derive from the retained resolved-profile.json producer binding and the pinned producer config' \
  "$tmp/pre-identity-provenance.err" ||
  fail "a pre identity's model_request altered consistently in the identity and its own shadow record must fail specifically on the identity-provenance check ($(cat "$tmp/pre-identity-provenance.err"))"
pass "a pre identity's model_request altered consistently in the identity and its own shadow record (recomputed hashes, record-binds-own-identity satisfied) is refused specifically by the identity-provenance check"

# (p) the retained duty evaluation's verdict is changed to "violated" with its
# downstream reference refreshed (environment-claim.json's duty_evaluation_ref
# points at the mutated bytes), which moves the claim's own digest, so the
# whole downstream claim-reference chain (both cases' sandbox-evaluation.json
# claim_ref, both shadow records' environment.claim_ref and evaluation_ref)
# and checksums.json are refreshed too, so only the new verdict assertion —
# not the claim-binding check (9b), which would otherwise refuse first on the
# claim's now-moved digest before check_evidence ever reaches the
# duty-verdict assertion — and not the checksums-inventory check, can catch
# it. A verdict a real evaluator would never emit for this policy set must
# still be refused even when every reference to it is internally consistent.
fresh_mutant_copy
"$jq_bin" -S -c '.body.verdict = "violated" | .body.reason_ids = ["reporter.role-mismatch"]' \
  "$mutant_dir/duty-evaluation.json" >"$mutant_dir/duty-evaluation.json.new"
/bin/mv "$mutant_dir/duty-evaluation.json.new" "$mutant_dir/duty-evaluation.json"
mutated_duty_sha=$(sha_file "$mutant_dir/duty-evaluation.json")
"$jq_bin" -S -c --arg sha "$mutated_duty_sha" '.body.duty_evaluation_ref.sha256 = $sha' \
  "$mutant_dir/environment-claim.json" >"$mutant_dir/environment-claim.json.new"
/bin/mv "$mutant_dir/environment-claim.json.new" "$mutant_dir/environment-claim.json"
refresh_claim_chain "$mutant_dir"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-duty-verdict' 2>"$tmp/duty-verdict.err"; then
  fail 'a retained duty evaluation reporting a violated verdict must be refused'
fi
/usr/bin/grep -q 'duty-evaluation verdict is not satisfied' "$tmp/duty-verdict.err" ||
  fail "a retained duty evaluation reporting a violated verdict must fail specifically on the new verdict assertion ($(cat "$tmp/duty-verdict.err"))"
pass 'a retained duty evaluation reporting a violated verdict with its downstream reference and the whole claim-reference chain refreshed is refused specifically by the verdict assertion'

# (q) the prerequisite materialization receipt is swapped for unrelated
# canonical JSON, with checksums.json refreshed so only the new
# prerequisite-receipt-binding assertion — not the checksums-inventory check
# — can catch it. Distinctness from the two case receipts alone is not
# enough: the swapped receipt is still distinct from both, but no longer
# resolves against the prerequisite stage result's own receipt-reference
# fields, so the duty evaluation's prerequisite proof would be unrecoverable.
fresh_mutant_copy
"$jq_bin" -S -c -n '{schema_version:1,kind:"unrelated_document",id:"mutant.unrelated",body:{note:"not a receipt"}}' \
  >"$mutant_dir/prerequisite/materialization-receipt.json"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-prereq-receipt' 2>"$tmp/prereq-receipt.err"; then
  fail 'a prerequisite receipt swapped for unrelated canonical JSON must be refused'
fi
/usr/bin/grep -q 'prerequisite receipt does not resolve against its stage result' "$tmp/prereq-receipt.err" ||
  fail "a prerequisite receipt swapped for unrelated canonical JSON must fail specifically on the prerequisite-receipt-binding assertion ($(cat "$tmp/prereq-receipt.err"))"
pass 'a prerequisite receipt swapped for unrelated canonical JSON is refused specifically by the prerequisite-receipt-binding assertion'

# (r) the retained prerequisite/environment-declaration.json is swapped for
# unrelated canonical JSON, with checksums.json refreshed so only the new
# prerequisite fingerprint check above — not the checksums-inventory check —
# can catch it. Nothing else in this suite reads
# prerequisite/environment-declaration.json, so before that check existed a
# retained request could fingerprint a wholly different environment
# declaration than the one actually committed beside it and still pass every
# check.
fresh_mutant_copy
"$jq_bin" -S -c -n \
  '{schema_version:1,kind:"unrelated_document",id:"mutant.unrelated-declaration",body:{note:"not a declaration"}}' \
  >"$mutant_dir/prerequisite/environment-declaration.json"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-prereq-declaration' 2>"$tmp/prereq-decl.err"; then
  fail 'a prerequisite environment declaration swapped for unrelated canonical JSON must be refused'
fi
/usr/bin/grep -q 'prerequisite assembled/input.json environment_ref.fingerprint_sha256 does not equal the retained environment-declaration.json digest' \
  "$tmp/prereq-decl.err" ||
  fail "a prerequisite environment declaration swapped for unrelated canonical JSON must fail specifically on the prerequisite fingerprint check ($(cat "$tmp/prereq-decl.err"))"
pass 'a prerequisite environment declaration swapped for unrelated canonical JSON (checksums refreshed) is refused specifically by the prerequisite fingerprint check'

# (s) a retained materialization result's body.request_ref.sha256 is changed
# to name an unrelated stage request, with the shadow record's own result
# reference and checksums.json both refreshed (the same refresh shape as
# case (d)), so only the new request_ref/resolved_profile_ref binding
# assertion added to check 7 -- not the earlier "record does not bind its
# own result" assertion, and not the checksums-inventory check -- can catch
# it. Review round 8's P2: before this check existed, a materialization
# result could name an unrelated execution request while still resolving
# against its own receipt and being bound to the shadow record, because
# neither consumer of the evidence (scope-gates.jq, control/v1/sandbox.jq)
# reads the result's request_ref/resolved_profile_ref at all -- both consume
# the shadow record instead.
fresh_mutant_copy
"$jq_bin" -S -c '.body.request_ref.sha256 =
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
  "$mutant_dir/post/state/materialization-result.json" \
  >"$mutant_dir/post/state/materialization-result.json.new"
/bin/mv "$mutant_dir/post/state/materialization-result.json.new" \
  "$mutant_dir/post/state/materialization-result.json"
mutated_result_sha=$(sha_file "$mutant_dir/post/state/materialization-result.json")
"$jq_bin" -S -c --arg sha "$mutated_result_sha" \
  '.body.materialization.value.stage_result_ref.sha256 = $sha' \
  "$mutant_dir/post/state/shadow-record.json" >"$mutant_dir/post/state/shadow-record.json.new"
/bin/mv "$mutant_dir/post/state/shadow-record.json.new" \
  "$mutant_dir/post/state/shadow-record.json"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-result-request-ref' 2>"$tmp/result-request-ref.err"; then
  fail 'a retained materialization result whose request_ref points at an unrelated stage request must be refused'
fi
/usr/bin/grep -q 'materialization result request_ref/resolved_profile_ref does not equal the assembled references' \
  "$tmp/result-request-ref.err" ||
  fail "a retained materialization result whose request_ref points at an unrelated stage request must fail specifically on the new request/profile binding assertion ($(cat "$tmp/result-request-ref.err"))"
pass 'a retained materialization result whose request_ref is changed, with its own digest refreshed downstream in the shadow record and checksums.json, is refused specifically by the request/profile binding assertion'

# (t) review round 9's P2: prerequisite/input.json's embedded stage request
# has its network_mode flipped to "allow", with only checksums.json
# refreshed -- the retained prerequisite/stage-request.json and
# prerequisite/resolved-profile-document.json extracts, and every other
# assertion in this suite (requester, environment fingerprint, duty
# evaluation's own recomputed stage.request_ref/resolved_profile_ref, which
# read the retained extract files directly, not the embedded input), are
# left untouched, so only the new prerequisite-input-binds-retained-bytes
# check can catch it.
fresh_mutant_copy
"$jq_bin" -S -c '.stage_request.content.body.operation.arguments.network_mode = "allow"' \
  "$mutant_dir/prerequisite/input.json" >"$mutant_dir/prerequisite/input.json.new"
/bin/mv "$mutant_dir/prerequisite/input.json.new" "$mutant_dir/prerequisite/input.json"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-prereq-input-network-mode' 2>"$tmp/prereq-input.err"; then
  fail 'a prerequisite/input.json embedded request with network_mode changed to allow must be refused'
fi
/usr/bin/grep -q 'prerequisite/input.json embedded stage_request/resolved_profile content does not equal the retained prerequisite/stage-request.json or resolved-profile-document.json bytes' \
  "$tmp/prereq-input.err" ||
  fail "a prerequisite/input.json embedded request with network_mode changed to allow must fail specifically on the new prerequisite-input-binds-retained-bytes check ($(cat "$tmp/prereq-input.err"))"
pass 'a prerequisite/input.json embedded request with network_mode changed to allow (retained extracts and checksums otherwise consistent) is refused specifically by the prerequisite-input-binds-retained-bytes check'

# (u) review round 9's other P2: one of a retained sandbox evaluation's own
# reference fields (duty_evaluation_ref.sha256) is replaced with an
# unrelated digest, with the shadow record's own evaluation_ref refreshed
# downstream to match the mutated file's new digest, and checksums.json
# refreshed too, so only the new sandbox-evaluation-inputs check -- which
# recomputes the evaluation for real through the shipped evaluator, not
# check 9 (which only hashes the whole retained file against the record) or
# check 10's field-level assertions (which never inspect duty_evaluation_ref)
# -- can catch it.
fresh_mutant_copy
bad_duty_ref_sha=$(/usr/bin/printf 'd%.0s' $(seq 1 64))
"$jq_bin" -S -c --arg s "$bad_duty_ref_sha" '.body.duty_evaluation_ref.sha256 = $s' \
  "$mutant_dir/post/sandbox-evaluation.json" >"$mutant_dir/post/sandbox-evaluation.json.new"
/bin/mv "$mutant_dir/post/sandbox-evaluation.json.new" "$mutant_dir/post/sandbox-evaluation.json"
mutated_eval_sha=$(sha_file "$mutant_dir/post/sandbox-evaluation.json")
"$jq_bin" -S -c --arg sha "$mutated_eval_sha" \
  '.body.environment.evaluation.value.evaluation_ref.sha256 = $sha' \
  "$mutant_dir/post/state/shadow-record.json" >"$mutant_dir/post/state/shadow-record.json.new"
/bin/mv "$mutant_dir/post/state/shadow-record.json.new" "$mutant_dir/post/state/shadow-record.json"
refresh_checksums "$mutant_dir"
if check_evidence "$mutant_dir" 'mutant-sandbox-eval-duty-ref' 2>"$tmp/sandbox-eval-ref.err"; then
  fail 'a retained sandbox evaluation with a corrupted duty_evaluation_ref must be refused'
fi
/usr/bin/grep -q 'retained sandbox-evaluation.json is not byte-identical to the shipped evaluate-sandbox.sh output' \
  "$tmp/sandbox-eval-ref.err" ||
  fail "a retained sandbox evaluation with a corrupted duty_evaluation_ref must fail specifically on the new sandbox-evaluation-inputs check ($(cat "$tmp/sandbox-eval-ref.err"))"
pass 'a retained sandbox evaluation with a corrupted duty_evaluation_ref (record digest and checksums refreshed downstream) is refused specifically by the sandbox-evaluation-inputs check'

/bin/rm -rf -- "$mutant_dir"

# ===========================================================================
# Requirement 16: the scope consumer, exercised as a clearly marked inactive
# compatibility harness. This asserts shape and reference compatibility only;
# it never claims a passing or proposable result, and it copies nothing from,
# and weakens nothing in, the shipped validator.
# ===========================================================================
# This is an INACTIVE COMPATIBILITY HARNESS: it exercises the real, unmodified
# scope/v1/evaluate-scope.sh with the two real unchanged shadow records above
# as the shadow set, and inert fixture documents in the other six input slots
# (dashboard, risk, kill, duty, marker are compatibility filler unrelated to
# this task's own claim; only the scope record and the shadow set describe
# this run). The assertion is narrow, per requirement 16: the evaluator's
# complete shape and reference checks accept the two real records, and the
# classification is read verbatim from the evaluator's own vocabulary.
# Compatibility is not qualification: nothing here creates live scope
# authority, and the result is never restated as passing or proposable.
scope_dir="$tmp/scope-harness"
/bin/mkdir -m 700 "$scope_dir"
evaluator="$root/scope/v1/evaluate-scope.sh"
repo_marker="$root/config/construction-mode.json"

pre_record="$evdir/pre/state/shadow-record.json"
post_record="$evdir/post/state/shadow-record.json"
"$jq_bin" -S -c -n --slurpfile pre "$pre_record" --slurpfile post "$post_record" \
  '{schema_version:1,kind:"shadow_evidence_set",
    id:"scope.evidence.self-host-transition.v1",
    body:{records:[$pre[0],$post[0]]}}' >"$scope_dir/shadow-set.json"
pre_record_sha=$("$jq_bin" -S -c '.body.records[0]' "$scope_dir/shadow-set.json" | sha_file /dev/stdin)
post_record_sha=$("$jq_bin" -S -c '.body.records[1]' "$scope_dir/shadow-set.json" | sha_file /dev/stdin)
pre_id=$("$jq_bin" -r '.id' "$pre_record")
post_id=$("$jq_bin" -r '.id' "$post_record")
post_identity=$("$jq_bin" -c '.body' "$evdir/post/qualified-identity.json")
pre_identity=$("$jq_bin" -c '.body' "$evdir/pre/qualified-identity.json")

# The dashboard fixture: a whole eval_dashboard in evals/v1/evals.jq's shape,
# complete and valid under scope-gates.jq's own dashboard_shape (nine gate
# families, 64-hex-character digests throughout), seeding the one family this
# scope declares and declaring the other eight, unrelated to this task's own
# evidence (evaluate-scope.sh judges the framework's complete emitted shape).
# A dashboard that fails this shape check is malformed, and a malformed input
# makes the evaluator refuse with "scope.malformed" regardless of the real
# gates below — which would prove nothing about scope compatibility. Every
# digest here is 64 hex characters, checked directly below.
"$jq_bin" -S -c -n '
  def absent($reason): {state:"absent",reason_id:$reason};
  def closure($path;$sha): [{path:$path,sha256:$sha}];
  def family($id;$status;$total;$failed;$inconclusive):
    {family_id:$id,seed_status:$status,
     seed_sources:(if $status == "seeded" then ["core.stage-run.v2"] else [] end),
     grader_kinds:["deterministic"],trial_policy:{kind:"single"},runs:1,
     cases:{total:$total,passed:($total - $failed - $inconclusive),
       failed:$failed,inconclusive:$inconclusive}};
  {schema_version:1,kind:"eval_dashboard",id:"evals.dashboard.v1",
   body:{activation_state:"inactive",authority_effect:"none",
     mode:"deterministic-offline",
     core_contract:{
       generation_id_sha256:"84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
       package_ref:{content_id:"core-contract-package.v2",
         media_type:"application/vnd.ystack.core-contract+json",
         sha256:"eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"},
       semantic_identity:"core.contracts.v2"},
     catalog_ref:{schema_version:1,kind:"eval_catalog",id:"evals.catalog.v1",
       sha256:("1" * 64)},
     evaluator:{sha256:("2" * 64),
       content:{schema_version:1,kind:"eval_framework_evaluator",
         id:"evals.framework.v1",
         body:{
           core_contract:{
             generation_id_sha256:"84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
             package_ref:{content_id:"core-contract-package.v2",
               media_type:"application/vnd.ystack.core-contract+json",
               sha256:"eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"},
             semantic_identity:"core.contracts.v2"},
           core_closure:closure("core/v2/generation-registry.json";("3" * 64)),
           orchestrator_closure:closure("orchestrator/v1/scan-state.sh";("4" * 64)),
           control_closure:closure("control/v1/kill-switch.jq";("5" * 64)),
           adapter_closure:closure("adapters/codex-native-reviewer/v1/normalize.jq";("6" * 64)),
           bootstrap_ref:{content_id:"evals-framework-bootstrap.v1",
             media_type:"text/x-shellscript",sha256:("7" * 64)},
           launcher_ref:{content_id:"evals-framework-launcher.v1",
             media_type:"text/x-shellscript",sha256:("8" * 64)},
           driver_ref:{content_id:"evals-framework-driver.v1",
             media_type:"text/x-shellscript",sha256:("9" * 64)},
           program_ref:{content_id:"evals-framework-program.v1",
             media_type:"text/x-jq",sha256:("a" * 64)},
           catalog_ref:{content_id:"evals-catalog.v1",
             media_type:"application/vnd.ystack.eval-catalog+json",sha256:("1" * 64)},
           runtime:{host_os:"linux",host_architecture:"x86_64",
             jq_architecture:"x86_64",execution_mode:"native",
             jq_ref:{content_id:"jq-runtime.v1",media_type:"application/x-executable",
               sha256:"af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44"},
             shell_ref:{content_id:"bash-runtime",media_type:"application/x-executable",
               sha256:("b" * 64)}}}}},
     observed_at:"2026-09-05T00:00:00Z",
     inputs:[{run_id:"evals.run.self-host-harness",seed_source:"core.stage-run.v2",
       result_sha256:("c" * 64),observed_at:"2026-09-05T00:00:00Z",
       seed_set_ref:{schema_version:1,kind:"eval_seed_set",id:"evals.seed-set.harness",
         sha256:("d" * 64)},
       summary:{total:7,passed:7,failed:0,inconclusive:0}}],
     coverage:{families_total:9,families_seeded:1,families_declared:8,
       families_with_results:1,sources_with_results:["core.stage-run.v2"]},
     quality:{total:7,passed:7,failed:0,inconclusive:0},
     recovery:{stranded_recovered:0,cancelled_stayed_terminal:0,
       repeats_redelivered_once:0,repeats_suppressed_after_acknowledgement:0,
       retry_limit_enforced:0,events_refused:0},
     telemetry:{cost:absent("evals.no-live-runs"),latency:absent("evals.no-live-runs"),
       tokens:absent("evals.no-live-runs")},
     flow:([
       "accepted-plan-to-merge-time","dora-instability","dora-throughput",
       "escaped-defects","escaped-vulnerabilities","first-pass-success",
       "human-gate-wait","intent-to-spec-time","queue-wait","review-latency",
       "review-precision","review-recall-samples","review-stale-rate",
       "rework-cycles","target-outcome"] |
       map({key:.,value:absent("evals.no-operating-history")}) | from_entries),
     families:[
       family("actor-rerun-identity";"declared";0;0;0),
       family("adapter-contract-compliance";"declared";0;0;0),
       family("approval-invalidation-no-push-after-approval";"declared";0;0;0),
       family("empty-fake-timed-out-degraded-reviews";"declared";0;0;0),
       family("malicious-instructions";"declared";0;0;0),
       family("protected-path-credential-network-publisher-boundaries";"declared";0;0;0),
       family("repeated-cancelled-missed-events";"declared";0;0;0),
       family("reviewer-severity-false-positive-negative";"declared";0;0;0),
       family("stale-moved-artifacts";"seeded";7;1;0)]}}' \
  >"$scope_dir/dashboard.json"
"$jq_bin" -e '
  [.body.core_contract.package_ref.sha256, .body.catalog_ref.sha256,
   .body.evaluator.sha256, .body.evaluator.content.body.core_contract.package_ref.sha256,
   (.body.evaluator.content.body.core_closure[].sha256),
   (.body.evaluator.content.body.orchestrator_closure[].sha256),
   (.body.evaluator.content.body.control_closure[].sha256),
   (.body.evaluator.content.body.adapter_closure[].sha256),
   .body.evaluator.content.body.bootstrap_ref.sha256,
   .body.evaluator.content.body.launcher_ref.sha256,
   .body.evaluator.content.body.driver_ref.sha256,
   .body.evaluator.content.body.program_ref.sha256,
   .body.evaluator.content.body.catalog_ref.sha256,
   .body.evaluator.content.body.runtime.jq_ref.sha256,
   .body.evaluator.content.body.runtime.shell_ref.sha256,
   (.body.inputs[].result_sha256), (.body.inputs[].seed_set_ref.sha256)] |
  all(test("\\A[0-9a-f]{64}\\z"))
' "$scope_dir/dashboard.json" >/dev/null 2>&1 ||
  fail 'scope harness: dashboard fixture digest is not exactly 64 hex characters'
"$jq_bin" -e '(.body.families | length) == 9' "$scope_dir/dashboard.json" >/dev/null 2>&1 ||
  fail 'scope harness: dashboard fixture must declare all nine gate families'

harness_policy_set='{"id":"control.policy-set.self-host-harness","sha256":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}'
harness_core_contract='{
  "generation_id":"g-0bef6d994accaf957358a8f9c833c0ce64bb71fe2bc934b9569277bbe19b8d29",
  "package_ref":{"content_id":"core-contract-package.v2",
    "media_type":"application/vnd.ystack.core-contract+json","sha256":"3333333333333333333333333333333333333333333333333333333333333333"},
  "semantic_identity":"core.contracts.v2"}'
harness_policy_ref='{"content_id":"control.policy.self-host-harness",
  "media_type":"application/vnd.ystack.control-policy+json","sha256":"4444444444444444444444444444444444444444444444444444444444444444"}'
harness_decision_ref='{"content_id":"control.decision.self-host-harness",
  "media_type":"application/vnd.ystack.control-decision+json","sha256":"5555555555555555555555555555555555555555555555555555555555555555"}'
harness_duty_decision_ref='{"content_id":"control.decision.duty-separation",
  "media_type":"application/vnd.ystack.control-decision+json","sha256":"6666666666666666666666666666666666666666666666666666666666666666"}'
harness_claim_ref='{"content_id":"risk.decision-claim.self-host-harness",
  "media_type":"application/vnd.ystack.risk-gate-decision-claim+json","sha256":"7777777777777777777777777777777777777777777777777777777777777777"}'
harness_kill_state_ref='{"schema_version":1,"kind":"kill_switch_state",
  "id":"kill.state.self-host-harness","sha256":"8888888888888888888888888888888888888888888888888888888888888888"}'

"$jq_bin" -S -c . "$repo_marker" >"$scope_dir/marker.json"

gate_ref() {
  "$jq_bin" -S -c -n --arg sha "$(sha_file "$1")" --arg id "$("$jq_bin" -r '.id' "$1")" \
    --arg kind "$("$jq_bin" -r '.kind' "$1")" '{schema_version:1,kind:$kind,id:$id,sha256:$sha}'
}

# Requirement 16 exercises BOTH cases, not just post: scope-gates.jq's
# shadow_record_ok only shape-checks a record's embedded qualified_identity
# and gives full field-level validation only to whichever single identity is
# passed as the scope's own qualified_identity (scope/v1/scope-gates.jq
# ~618-622). Running this harness once with post_identity alone would never
# exercise that full validation against the pre record's identity, so a
# harness that always used post_identity could not tell a byte-mutated pre
# identity from a genuine one. Loop over both cases, each time supplying
# THAT case's own retained qualified-identity.json as the scope identity
# under test, so each of the two identities gets the evaluator's complete
# field-level treatment in turn.
for scope_case in pre post; do
  if [ "$scope_case" = pre ]; then
    case_identity=$pre_identity
  else
    case_identity=$post_identity
  fi
  # The gate stage's request_ref and resolved_profile_ref are bound to the
  # identity under test: scope-gates.jq (gates_bound) requires the risk and
  # duty evaluations' stage references to equal the scope's qualified_identity
  # references exactly, so a harness stage naming placeholder documents
  # instead of the identity under test would make every gate binding refuse
  # as malformed regardless of the rest of this fixture. Only result_ref is
  # free to name an inert placeholder: nothing here compares it against the
  # identity.
  harness_stage=$("$jq_bin" -c -n --argjson identity "$case_identity" '{
    request_ref:$identity.stage_request_ref,
    resolved_profile_ref:$identity.resolved_profile_ref,
    result_ref:{id:"stage.self-host-harness.result",kind:"stage_result",
      schema_version:2,
      sha256:"2222222222222222222222222222222222222222222222222222222222222222"}}')

  "$jq_bin" -S -c -n --argjson policy_set "$harness_policy_set" --argjson stage "$harness_stage" \
    --argjson core_contract "$harness_core_contract" --argjson policy_ref "$harness_policy_ref" \
    --argjson decision_ref "$harness_duty_decision_ref" '
    {schema_version:1,kind:"duty_separation_evaluation",
     id:"stage.self-host-harness.result",
     body:{activation_state:"inactive",core_contract:$core_contract,
       decision_ref:$decision_ref,evaluation_mode:"observation-only",
       policy_ref:$policy_ref,policy_set:$policy_set,stage:$stage,
       reference_semantics:"identity-only",verdict:"satisfied",
       reason_ids:["duty.satisfied"]}}' >"$scope_dir/duty-$scope_case.json"
  harness_duty_sha=$(sha_file "$scope_dir/duty-$scope_case.json")

  "$jq_bin" -S -c -n --argjson policy_set "$harness_policy_set" --argjson stage "$harness_stage" \
    --argjson core_contract "$harness_core_contract" --argjson policy_ref "$harness_policy_ref" \
    --argjson decision_ref "$harness_decision_ref" --argjson claim_ref "$harness_claim_ref" \
    --arg duty_sha "$harness_duty_sha" '
    {schema_version:1,kind:"risk_gate_evaluation",id:"stage.self-host-harness.result",
     body:{activation_state:"inactive",authority_effect:"none",
       classification:{declared_tier:"routine",minimum_tier:"routine"},
       core_contract:$core_contract,decision_claim_ref:$claim_ref,decision_ref:$decision_ref,
       duty_evaluation_ref:{content_id:"stage.self-host-harness.result",
         media_type:"application/vnd.ystack.duty-separation-evaluation+json",sha256:$duty_sha},
       policy_ref:$policy_ref,policy_set:$policy_set,stage:$stage,
       evaluation_mode:"observation-only",reference_semantics:"identity-only",
       verdict:"inconclusive",reason_ids:["decision.provenance-unqualified"]}}' \
    >"$scope_dir/risk-$scope_case.json"

  "$jq_bin" -S -c -n --argjson policy_set "$harness_policy_set" --arg duty_sha "$harness_duty_sha" \
    --argjson policy_ref "$harness_policy_ref" --argjson decision_ref "$harness_decision_ref" \
    --argjson duty_decision_ref "$harness_duty_decision_ref" --argjson state_ref "$harness_kill_state_ref" '
    {schema_version:1,kind:"kill_switch_evaluation",id:"kill-attempt.self-host-harness",
     body:{activation_state:"inactive",authority_effect:"none",
       decision_ref:$decision_ref,duty_decision_ref:$duty_decision_ref,
       duty_evaluation_ref:{schema_version:1,kind:"duty_separation_evaluation",
         id:"stage.self-host-harness.result",sha256:$duty_sha},
       policy_ref:$policy_ref,policy_set:$policy_set,state_ref:$state_ref,
       attempt_ref:{schema_version:1,kind:"kill_switch_attempt",
         id:"kill-attempt.self-host-harness",sha256:"9999999999999999999999999999999999999999999999999999999999999999"},
       evaluation_mode:"observation-only",reference_semantics:"identity-only",
       verdict:"satisfied",reason_ids:["kill.cleared-current"]}}' >"$scope_dir/kill-$scope_case.json"

  risk_ref=$(gate_ref "$scope_dir/risk-$scope_case.json")
  kill_ref=$(gate_ref "$scope_dir/kill-$scope_case.json")
  duty_ref=$(gate_ref "$scope_dir/duty-$scope_case.json")

  "$jq_bin" -S -c -n --arg pre_id "$pre_id" --arg pre_sha "$pre_record_sha" \
    --arg post_id "$post_id" --arg post_sha "$post_record_sha" \
    --argjson identity "$case_identity" \
    --argjson risk_ref "$risk_ref" --argjson kill_ref "$kill_ref" --argjson duty_ref "$duty_ref" '
    {schema_version:1,kind:"workflow_scope",id:"scope.self-host-transition.v1",
     body:{activation_state:"inactive",authority:"none",enabled:false,
       push_allowed:false,scope_version:"v1",
       target_repository_id:"repo.ystack",
       workflow_id:"workflow.self-host-transition",
       task_class:"task.self-host-transition",
       risk_tier:"routine",
       allowed_paths:["docs/guides/setup.md","docs/notes-?.md"],
       required_proof_kinds:["deterministic","independent-review"],
       required_eval_families:["stale-moved-artifacts"],
       required_shadow_environments:["env.local-macos-ystack-self"],
       shadow_evidence_refs:([
         {schema_version:1,kind:"shadow_reproduction_record",id:$pre_id,sha256:$pre_sha},
         {schema_version:1,kind:"shadow_reproduction_record",id:$post_id,sha256:$post_sha}] |
         # workflow-scope.jq bounded_set requires the array to equal its own
         # plain sort, not a sort keyed on one field: with two refs sharing
         # every key name, the generic object sort compares "id" before
         # "sha256" ever enters it, so sorting by sha256 alone could disagree
         # with the shape check depending on which digest happened to be
         # smaller; sort here exactly as bounded_set does.
         sort),
       qualified_identity:$identity,
       gate_evidence_refs:{risk_gate_evaluation_ref:$risk_ref,
         kill_switch_evaluation_ref:$kill_ref,duty_separation_evaluation_ref:$duty_ref},
       max_attempts:2}}' >"$scope_dir/scope-$scope_case.json"

  if ! PATH="$run_path" "$evaluator" evaluate \
      "$scope_dir/scope-$scope_case.json" "$scope_dir/shadow-set.json" "$scope_dir/dashboard.json" \
      "$scope_dir/risk-$scope_case.json" "$scope_dir/kill-$scope_case.json" "$scope_dir/duty-$scope_case.json" \
      "$scope_dir/marker.json" >"$scope_dir/evaluation-$scope_case.json" 2>"$tmp/scope-$scope_case.err"; then
    fail "scope harness ($scope_case): evaluate-scope.sh refused the two real shadow records ($(cat "$tmp/scope-$scope_case.err"))"
  fi
  # The accepted spec (requirement 2) and the plan's consumer section
  # (work/shadow-self-host-run/plan.md, "The consumers") both require this
  # scope's classification to be the evaluator's real "not-proposable" answer,
  # not a manufactured "proposable" one: there is no real sandbox and this
  # fixture is declaration-only. The dashboard's one seeded family
  # ("stale-moved-artifacts") is deliberately given a failing case above
  # (family("stale-moved-artifacts";"seeded";7;1;0)) so the gate stage stays
  # well-formed under scope-gates.jq's own shape and reference checks (nine
  # real gate families, 64-hex digests, gates bound to the tested identity,
  # gates mutually consistent) and refuses for a real, specific,
  # non-malformed reason instead: "scope.eval-failing"
  # (scope/v1/scope-gates.jq:887-890), reported distinctly from
  # "scope.malformed" as the plan's consumer section requires. This is still
  # never live authority: qualification stays unavailable, enablement stays
  # blocked, and enabling this scope remains an independent operator-merged
  # pull request — the qualification field itself records that regardless of
  # outcome, checked below field for field.
  "$jq_bin" -e -n --slurpfile e "$scope_dir/evaluation-$scope_case.json" '
    $e[0].body.outcome == "not-proposable" and
    $e[0].body.reason_ids == ["scope.eval-failing"] and
    $e[0].body.qualification ==
      {state:"unavailable",reason_id:"scope.enablement-requires-operator-pr"} and
    $e[0].body.authority == "none" and $e[0].body.enabled == false and
    ($e[0].body.evidence.shadow_records | length) == 2 and
    $e[0].body.proposal.state == "absent"
  ' >/dev/null 2>&1 ||
    fail "scope harness ($scope_case): the evaluator did not report the exact not-proposable classification, with the specific scope.eval-failing refusal reason and no live authority"
  pass "scope harness ($scope_case case's own identity, inactive compatibility only): the shipped evaluate-scope.sh accepts the two real unchanged shadow records and the nine-family dashboard under its complete shape and reference checks, with this case's own identity fully field-validated, and reports the exact not-proposable classification in its own vocabulary — refused for the specific scope.eval-failing reason, distinct from scope.malformed — with qualification still unavailable and no live authority"
done

# Negative control: a dashboard missing eight of the nine required gate
# families is malformed under scope-gates.jq's own dashboard_shape, and must be
# refused with "scope.malformed" and outcome "not-proposable". Without this
# check, the positive assertion above could pass vacuously against a harness
# that always reported proposable regardless of what the dashboard said. Uses
# the post case's fixtures; either case's would do since this checks the
# dashboard, not the identity.
malformed_dashboard="$scope_dir/dashboard-malformed.json"
"$jq_bin" -S -c '.body.families |= .[0:1]' "$scope_dir/dashboard.json" >"$malformed_dashboard"
if ! PATH="$run_path" "$evaluator" evaluate \
    "$scope_dir/scope-post.json" "$scope_dir/shadow-set.json" "$malformed_dashboard" \
    "$scope_dir/risk-post.json" "$scope_dir/kill-post.json" "$scope_dir/duty-post.json" \
    "$scope_dir/marker.json" >"$scope_dir/evaluation-malformed.json" \
    2>"$tmp/scope-malformed.err"; then
  fail "scope harness: evaluate-scope.sh refused a well-formed call with a malformed dashboard ($(cat "$tmp/scope-malformed.err"))"
fi
"$jq_bin" -e -n --slurpfile e "$scope_dir/evaluation-malformed.json" '
  $e[0].body.outcome == "not-proposable" and
  ($e[0].body.reason_ids | index("scope.malformed")) != null
' >/dev/null 2>&1 ||
  fail 'scope harness negative control: a dashboard missing eight of the nine gate families must be refused as malformed'
pass 'scope harness negative control: a dashboard carrying only one of the nine required gate families is refused as malformed and not-proposable, proving the positive assertion above is not vacuous'

# ===========================================================================
# Requirement 17: feed each incident and its matching, unchanged shadow
# record to the real maintenance converter. Cross-pairing must fail.
# generated skeletons are test outputs in a temp directory; evals/v1/seed-set.json
# is never touched.
# ===========================================================================
converter="$root/maintenance/v1/incident-to-eval.sh"
convert_ok() {
  local incident=$1 shadow=$2 out=$3
  /bin/mkdir -m 700 "$out"
  PATH="$run_path" "$converter" convert "$incident" "$shadow" "$out"
}
post_out="$tmp/maint-post"
pre_out="$tmp/maint-pre"
convert_ok "$evdir/post/incident.json" "$post_record" "$post_out" \
  >"$post_out.skeleton.json" 2>"$post_out.err" ||
  fail "maintenance conversion of the post case refused: $(cat "$post_out.err")"
"$jq_bin" -e -n --slurpfile s "$post_out.skeleton.json" '
  $s[0].body.family_id == "stale-moved-artifacts" and
  $s[0].body.case.expectation == {disposition:"accepted",status:"stale"} and
  $s[0].body.qualification == {state:"unavailable",reason_id:"maintenance.no-adapter-exists"}
' >/dev/null 2>&1 || fail 'post maintenance skeleton has the wrong family/expectation/qualification'
"$jq_bin" -e -n --slurpfile s "$post_out.skeleton.json" --arg sha "$(sha_file "$evdir/post/incident.json")" \
  '$s[0].body.provenance.incident_ref.sha256 == $sha' >/dev/null 2>&1 ||
  fail 'post maintenance skeleton provenance.incident_ref mismatch'
"$jq_bin" -e -n --slurpfile s "$post_out.skeleton.json" --arg sha "$(sha_file "$post_record")" \
  '$s[0].body.provenance.shadow_record_ref.sha256 == $sha' >/dev/null 2>&1 ||
  fail 'post maintenance skeleton provenance.shadow_record_ref mismatch'
pass 'the post incident and its unchanged shadow record convert to the stale-moved-artifacts family with {accepted, stale}'

convert_ok "$evdir/pre/incident.json" "$pre_record" "$pre_out" \
  >"$pre_out.skeleton.json" 2>"$pre_out.err" ||
  fail "maintenance conversion of the pre case refused: $(cat "$pre_out.err")"
"$jq_bin" -e -n --slurpfile s "$pre_out.skeleton.json" '
  $s[0].body.family_id == "stale-moved-artifacts" and
  $s[0].body.case.expectation == {disposition:"accepted",status:"completed"} and
  $s[0].body.qualification == {state:"unavailable",reason_id:"maintenance.no-adapter-exists"}
' >/dev/null 2>&1 || fail 'pre maintenance skeleton has the wrong family/expectation/qualification'
pass 'the pre incident and its unchanged shadow record convert to the stale-moved-artifacts family with {accepted, completed}'

cross_1="$tmp/maint-cross-1"
if convert_ok "$evdir/post/incident.json" "$pre_record" "$cross_1" \
    >"$cross_1.out" 2>"$cross_1.err"; then
  fail 'cross-pairing the post incident with the pre shadow record must be refused'
fi
cross_2="$tmp/maint-cross-2"
if convert_ok "$evdir/pre/incident.json" "$post_record" "$cross_2" \
    >"$cross_2.out" 2>"$cross_2.err"; then
  fail 'cross-pairing the pre incident with the post shadow record must be refused'
fi
pass 'cross-pairing either incident with the other case shadow record is refused'
[ ! -f "$root/evals/v1/seed-set.json.new" ] || fail 'evals/v1/seed-set.json must never be touched'
pass 'no live eval seed set was modified'

/usr/bin/printf 'shadow self-host evidence: %s focused checks passed\n' "$passes"
