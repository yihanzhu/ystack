#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
fixtures="$root/scripts/test"
generation=g-98b9b6769e213878a0cf52dad0565ae3e1e71f0834c06a082cf80fe80591adee
relative="core/v3/generations/$generation"
package="$root/$relative"
rules="$fixtures/portable-core-v3-publisher-rules.tsv"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ystack-core-v3-publisher.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
trap 'rm -rf -- "$tmp"' EXIT
sha_file() { shasum -a 256 "$1" | awk '{print $1}'; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
case "$(uname -s):$(uname -m)" in
  Darwin:*) asset=jq-osx-amd64; digest=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) asset=jq-linux64; digest=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) fail 'unsupported pinned runtime platform' ;;
esac
jq_bin="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$asset"
[ -f "$jq_bin" ] && [ ! -L "$jq_bin" ] && [ "$(sha_file "$jq_bin")" = "$digest" ] || fail 'pinned jq cache unavailable; functional NOT RUN'
jq_cmd=("$jq_bin")
[ "$(uname -s):$(uname -m)" != Darwin:arm64 ] || jq_cmd=(/usr/bin/arch -x86_64 "$jq_bin")
[ "$("${jq_cmd[@]}" --version)" = jq-1.6 ] || fail 'jq version'
mkdir "$tmp/bin"
ln -s "$jq_bin" "$tmp/bin/jq"
export PATH="$tmp/bin:/usr/bin:/bin"
fixture() { "${jq_cmd[@]}" -L "$fixtures" -S -c -n "$@"; }
mutate() { "${jq_cmd[@]}" -L "$fixtures" -S -c "$@"; }
run_package() (
  local selected=$1 mode=$2 input
  shift 2
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$selected/core-ingress.sh" 2>/dev/null || { printf 'E_RUNTIME\n' >&2; exit 1; }
  trap 'portable_core_ingress_close >/dev/null 2>&1 || :' EXIT
  portable_core_ingress_open || exit 1
  portable_core_ingress_begin "$mode" || exit 1
  for input in "$@"; do portable_core_ingress_snapshot "$input" || exit 1; done
  portable_core_ingress_finish_driver || exit 1
  portable_core_ingress_validate || exit 1
  portable_core_ingress_close || exit 1
  trap - EXIT
)
assert_route() {
  local expected=$1 selected=$2 mode=$3 status=0
  shift 3
  run_package "$selected" "$mode" "$@" >"$tmp/out" 2>"$tmp/err" || status=$?
  [ ! -s "$tmp/out" ] || fail "$case_id/$route unexpected stdout"
  if [ "$expected" = OK ]; then
    [ "$status" -eq 0 ] && [ ! -s "$tmp/err" ] || { cat "$tmp/err" >&2; fail "$case_id/$route expected OK"; }
  else
    [ "$status" -ne 0 ] && [ "$(cat "$tmp/err")" = "$expected" ] || {
      cat "$tmp/err" >&2; fail "$case_id/$route expected $expected (status $status)";
    }
  fi
}
roles=(forge producer publisher reviewer verifier)
manifest_files=()
for role in "${roles[@]}"; do
  fixture --arg role "$role" 'import "portable-core-v3-publisher-fixtures" as f; f::manifest($role)' >"$tmp/manifest-$role.json"
  manifest_files+=("$tmp/manifest-$role.json")
done
shas=$(fixture --arg forge "$(sha_file "$tmp/manifest-forge.json")" \
  --arg producer "$(sha_file "$tmp/manifest-producer.json")" \
  --arg publisher "$(sha_file "$tmp/manifest-publisher.json")" \
  --arg reviewer "$(sha_file "$tmp/manifest-reviewer.json")" \
  --arg verifier "$(sha_file "$tmp/manifest-verifier.json")" \
  '{forge:$forge,producer:$producer,publisher:$publisher,reviewer:$reviewer,verifier:$verifier}')
fixture --argjson shas "$shas" 'import "portable-core-v3-publisher-fixtures" as f; f::profile($shas)' >"$tmp/profile.json"
fixture --slurpfile profile "$tmp/profile.json" --arg sha "$(sha_file "$tmp/profile.json")" --argjson shas "$shas" \
  'import "portable-core-v3-publisher-fixtures" as f; f::resolved($profile[0];$sha;$shas)' >"$tmp/resolved.json"
for role in "${roles[@]}"; do
  fixture --arg role "$role" --arg sha "$(sha_file "$tmp/resolved.json")" \
    'import "portable-core-v3-publisher-fixtures" as f; f::operation_request($role;$sha)' >"$tmp/request-$role.json"
  fixture --slurpfile request "$tmp/request-$role.json" --arg request_sha "$(sha_file "$tmp/request-$role.json")" \
    --slurpfile resolved "$tmp/resolved.json" --arg resolved_sha "$(sha_file "$tmp/resolved.json")" \
    'import "portable-core-v3-publisher-fixtures" as f; f::result($request[0];$request_sha;$resolved[0];$resolved_sha)' >"$tmp/result-$role.json"
done
mkdir "$tmp/case"
reset_case() {
  cp "$tmp/profile.json" "$tmp/case/profile.json"
  cp "$tmp/resolved.json" "$tmp/case/resolved.json"
  cp "$tmp/request-publisher.json" "$tmp/case/request.json"
  cp "$tmp/result-publisher.json" "$tmp/case/result.json"
  for role in "${roles[@]}"; do cp "$tmp/manifest-$role.json" "$tmp/case/manifest-$role.json"; done
}
change_file() {
  local file=$1 filter=$2
  shift 2
  mutate "$@" "$filter" "$tmp/case/$file.json" >"$tmp/changed.json"
  mv "$tmp/changed.json" "$tmp/case/$file.json"
}
refresh_refs() {
  change_file resolved '.body.profile_ref.sha256=$sha | .body.profile_source.value_sha256=$sha' \
    --arg sha "$(sha_file "$tmp/case/profile.json")"
  change_file request '.body.resolved_profile_ref.sha256=$sha' --arg sha "$(sha_file "$tmp/case/resolved.json")"
  change_file result '.body.resolved_profile_ref.sha256=$sha | .body.request_ref.sha256=$request_sha' \
    --arg sha "$(sha_file "$tmp/case/resolved.json")" --arg request_sha "$(sha_file "$tmp/case/request.json")"
}
select_route() {
  case "$route" in
    D|D-profile|D-resolved) mode=document; inputs=("$tmp/case/$target.json") ;;
    P) mode=profile-set; inputs=("$tmp/case/profile.json" "$tmp/case/resolved.json");
      for role in "${roles[@]}"; do inputs+=("$tmp/case/manifest-$role.json"); done ;;
    T) mode=stage-run; inputs=("$tmp/case/request.json" "$tmp/case/resolved.json" "$tmp/case/result.json") ;;
    *) fail "unknown concrete route $route" ;;
  esac
}
make_case() {
  target=request
  case "$case_id" in
    ok-kind-*) target=${case_id#ok-kind-}; [ "$target" != manifest ] || target=manifest-publisher ;;
    ok-operation-*)
      role=${case_id#ok-operation-}
      cp "$tmp/request-$role.json" "$tmp/case/request.json"
      cp "$tmp/result-$role.json" "$tmp/case/result.json" ;;
    major-*)
      case "$route" in P) target=profile ;; T) target=request ;; *) target=request ;; esac
      if [ "$case_id" = major-mixed-ref ]; then
        if [ "$target" = profile ]; then change_file "$target" '.body.bindings[0].manifest_ref.schema_version=2'
        else change_file "$target" '.body.resolved_profile_ref.schema_version=2'; fi
      else change_file "$target" '.schema_version=$version' --argjson version "${case_id#major-}"; fi ;;
    dormant-offer) target=manifest-publisher; change_file "$target" '.body.offered_roles=["identity"] | .body.offered_capabilities=[] | .body.offered_permissions=[]' ;;
    profile-*|resolved-*|separation-*|projection-*|registry-model-publisher)
      case "$case_id:$route" in
        projection-*|*:D-resolved|*:T) target=resolved ;;
        *) target=profile ;;
      esac
      change_file "$target" 'import "portable-core-v3-publisher-fixtures" as f; f::profile_mutation($id)' --arg id "$case_id" ;;
    union-*|effect-*|no-execution-dispatch|result-*|publication-missing|cross-*|status-*|failed-*|cancelled-*|fact-gap-*|identity-mismatch-*|nonpassing-changed|post-mismatch-completed|ref-*|time-before-request)
      target=result
      change_file result 'import "portable-core-v3-publisher-fixtures" as f; f::result_mutation($id;$resolved[0])' \
        --arg id "$case_id" --slurpfile resolved "$tmp/case/resolved.json" ;;
    publication-other-capability)
      cp "$tmp/request-producer.json" "$tmp/case/request.json"
      cp "$tmp/result-producer.json" "$tmp/case/result.json"
      change_file result '.body.publication=$publication' --argjson publication "$(mutate '.body.publication' "$tmp/result-publisher.json")" ;;
    *) change_file request 'import "portable-core-v3-publisher-fixtures" as f; f::request_mutation($id)' --arg id "$case_id" ;;
  esac
  # Each mutated request/profile has new raw bytes. Ref-mismatch cases mutate after rebinding.
  case "$case_id" in
    ref-*)
      cp "$tmp/result-publisher.json" "$tmp/case/result.json"
      refresh_refs
      change_file result 'import "portable-core-v3-publisher-fixtures" as f; f::result_mutation($id;$resolved[0])' \
        --arg id "$case_id" --slurpfile resolved "$tmp/case/resolved.json" ;;
    *) refresh_refs ;;
  esac
  select_route
}
copy_package() {
  local destination=$1
  mkdir -p "$destination/core/v3/generations"
  cp -R "$package" "$destination/core/v3/generations/$generation"
}
force_cell() {
  local force=${case_id#force-} force_owner fault_file caller_file target_id marker wrapper caller bypass replacement kind owner_module
  target=${force#*-}
  case "$force" in
    truth-self-*) target=${force#truth-self-}; force_owner=truth-self ;;
    truth-cross-*) target=${force#truth-cross-}; force_owner=truth-cross ;;
    *) force_owner=${force%%-*} ;;
  esac
  [ "$target" != manifest ] || target=manifest-publisher
  target_id=$(mutate -r '.id' "$tmp/case/$target.json")
  select_route
  assert_route OK "$package" "$mode" "${inputs[@]}"
  copy_package "$tmp/forced"
  case "$force_owner" in
    schema)
      kind=$(mutate -r '.kind' "$tmp/case/$target.json")
      case "$kind" in adapter_manifest|profile|resolved_profile) owner_module=profile_graph ;; stage_request) owner_module=stage_request ;; *) owner_module=result_truth ;; esac
      fault_file=modules/schema.jq
      caller_file="modules/$owner_module.jq"
      replace_owned "$tmp/forced/$relative/$fault_file" 'def envelope_ok($kind):' 'def envelope_ok($kind;$document_id):' ''
      replace_owned "$tmp/forced/$relative/$fault_file" 'def document_envelope_ok:' $'def envelope_ok($kind): envelope_ok($kind;"");\n\ndef document_envelope_ok:' ''
      caller="schema::envelope_ok(\"$kind\")"
      replacement="(.id as \$document_id | schema::envelope_ok(\"$kind\";\$document_id))"
      replace_owned "$tmp/forced/$relative/$caller_file" "$caller" "$replacement" ''
      caller=$replacement
      marker='def envelope_ok($kind;$document_id):'
      wrapper="def envelope_ok(\$kind;\$document_id): if \$document_id == \"$target_id\" then false else forced_original(\$kind;\$document_id) end;"
      bypass="(if .id == \"$target_id\" then true else $caller end)" ;;
    profile)
      fault_file=modules/profile_graph.jq
      marker='def protected_role_separation_ok($bindings):'
      wrapper='def protected_role_separation_ok($bindings): forced_original($bindings);'
      caller_file="$fault_file"
      if [ "$target" = profile ]; then kind=profile_relations_ok; else kind=resolved_profile_relations_ok; fi
      # Carry document identity at this owner-call boundary before projecting binding arrays.
      mutate_owner_identity "$tmp/forced/$relative/$caller_file" "$kind" "$target_id"
      caller='protected_role_separation_ok($bindings)'
      wrapper="$wrapper\ndef forced_target(\$bindings;\$document_id): if \$document_id == \"$target_id\" then false else protected_role_separation_ok(\$bindings) end;"
      replace_owned "$tmp/forced/$relative/$caller_file" "$caller" 'forced_target($bindings;$forced_document_id)' "$kind"
      caller='forced_target($bindings;$forced_document_id)'
      bypass="(if \$forced_document_id == \"$target_id\" then true else $caller end)" ;;
    request)
      prepare_request_identity
      fault_file=modules/stage_request.jq; marker='def publisher_request_relation_ok($body;$document_id):'
      wrapper="def publisher_request_relation_ok(\$body;\$document_id): if \$document_id == \"$target_id\" then false else forced_original(\$body;\$document_id) end;"
      caller_file="$fault_file"; caller='and publisher_request_relation_ok($body;$document_id);'
      bypass="and (if \$document_id == \"$target_id\" then true else publisher_request_relation_ok(\$body;\$document_id) end);" ;;
    facts)
      prepare_fact_identity
      fault_file=modules/result_facts.jq; marker='def execution_metadata_shape_ok($document_id):'
      wrapper="def execution_metadata_shape_ok(\$document_id): if \$document_id == \"$target_id\" then false else forced_original(\$document_id) end;"
      caller_file="$fault_file"; caller='(.metadata | execution_metadata_shape_ok($document_id))'
      bypass="(if \$document_id == \"$target_id\" then true else $caller end)" ;;
    truth-self)
      fault_file=modules/result_truth.jq; marker='def publication_self_relations_ok:'
      wrapper="def publication_self_relations_ok: if .request_ref.id == \"request.publisher\" then false else forced_original end;"
      caller_file="$fault_file"; caller='  publication_self_relations_ok;'
      bypass='  (if .request_ref.id == "request.publisher" then true else publication_self_relations_ok end);' ;;
    truth-cross)
      fault_file=modules/result_truth.jq; marker='def publisher_result_relation_ok($request; $resolved; $result):'
      wrapper='def publisher_result_relation_ok($request; $resolved; $result): if $result.request_ref.id == "request.publisher" then false else forced_original($request;$resolved;$result) end;'
      caller_file="$fault_file"
      caller=$'publisher_result_relation_ok(\n    $request_pair.content.body;$resolved_pair.content.body;$result)'
      bypass="(if \$result.request_ref.id == \"request.publisher\" then true else $caller end)" ;;
    *) fail "unknown force $force_owner" ;;
  esac
  cp "$tmp/forced/$relative/$fault_file" "$tmp/force-source"
  "${jq_cmd[@]}" -Rsr --arg marker "$marker" --arg wrapper "$wrapper" '
    index($marker) as $start | if $start == null then error("missing forced predicate") else
    .[0:$start] as $prefix | .[$start:] as $rest |
    ($rest | index("\n\ndef ")) as $end |
    if $end == null then error("missing predicate end") else
      ($rest[0:$end] | sub("def [a-z_]+";"def forced_original")) as $original |
      $prefix+$original+"\n\n"+($wrapper | gsub("\\\\n";"\n"))+$rest[$end:]
    end end
  ' "$tmp/force-source" >"$tmp/forced/$relative/$fault_file"
  assert_route "$expected" "$tmp/forced/$relative" "$mode" "${inputs[@]}"
  replace_owned "$tmp/forced/$relative/$caller_file" "$caller" "$bypass" ''
  # The failing predicate remains injected. Only this target call is bypassed.
  grep -Fq 'then false else' "$tmp/forced/$relative/$fault_file" || fail 'injection disappeared from negative control'
  assert_route OK "$tmp/forced/$relative" "$mode" "${inputs[@]}"
  printf 'forced %s/%s target=%s baseline=OK rejection=%s omission-control=OK\n' "$case_id" "$route" "$target_id" "$expected"
  rm -rf "$tmp/forced"
}
replace_owned() {
  local file=$1 needle=$2 replacement=$3 phase=$4
  cp "$file" "$tmp/replace-source"
  "${jq_cmd[@]}" -Rsr --arg needle "$needle" --arg replacement "$replacement" --arg phase "$phase" '
    if $phase == "" then
      split($needle) | if length < 2 then error("missing target call") else join($replacement) end
    else
      index("def "+$phase+":") as $start |
      .[0:$start] as $prefix | .[$start:] as $rest |
      ($rest | index("\n\ndef ")) as $end |
      $prefix+($rest[0:$end] | split($needle) | if length != 2 then error("target call count") else join($replacement) end)+$rest[$end:]
    end
  ' "$tmp/replace-source" >"$file"
}
mutate_owner_identity() {
  local file=$1 phase=$2
  replace_owned "$file" "def $phase:" "def $phase: .id as \$forced_document_id |" ''
}
prepare_request_identity() {
  local file="$tmp/forced/$relative/modules/stage_request.jq"
  replace_owned "$file" 'def publisher_request_relation_ok($body):' 'def publisher_request_relation_ok($body;$document_id):' ''
  replace_owned "$file" 'def stage_request_self_relations_ok:' 'def stage_request_self_relations_ok($document_id):' ''
  replace_owned "$file" 'and publisher_request_relation_ok($body);' 'and publisher_request_relation_ok($body;$document_id);' ''
  replace_owned "$file" 'def stage_request_self_ok:' $'def stage_request_self_relations_ok: stage_request_self_relations_ok("");\n\ndef stage_request_self_ok:' ''
  replace_owned "$file" '(.body | stage_request_self_relations_ok);' '(.id as $document_id | .body | stage_request_self_relations_ok($document_id));' ''
}
prepare_fact_identity() {
  local facts_file="$tmp/forced/$relative/modules/result_facts.jq"
  local truth_file="$tmp/forced/$relative/modules/result_truth.jq"
  replace_owned "$facts_file" 'def execution_metadata_shape_ok:' 'def execution_metadata_shape_ok($document_id):' ''
  replace_owned "$facts_file" 'def execution_shape_ok:' $'def execution_metadata_shape_ok: execution_metadata_shape_ok("");\n\ndef execution_shape_ok($document_id):' ''
  replace_owned "$facts_file" '(.metadata | execution_metadata_shape_ok)' '(.metadata | execution_metadata_shape_ok($document_id))' ''
  replace_owned "$facts_file" 'def stage_result_facts_shape_ok:' $'def execution_shape_ok: execution_shape_ok("");\n\ndef stage_result_facts_shape_ok($document_id):' ''
  replace_owned "$facts_file" '(.execution | execution_shape_ok)' '(.execution | execution_shape_ok($document_id))' ''
  replace_owned "$facts_file" 'def fact_matches($fact; $expected):' $'def stage_result_facts_shape_ok: stage_result_facts_shape_ok("");\n\ndef fact_matches($fact; $expected):' ''
  replace_owned "$truth_file" 'def stage_result_body_shape_ok:' 'def stage_result_body_shape_ok($document_id):' ''
  replace_owned "$truth_file" 'result_facts::stage_result_facts_shape_ok;' 'result_facts::stage_result_facts_shape_ok($document_id);' ''
  replace_owned "$truth_file" 'def status_presence_ok:' $'def stage_result_body_shape_ok: stage_result_body_shape_ok("");\n\ndef status_presence_ok:' ''
  replace_owned "$truth_file" '(.body | stage_result_body_shape_ok);' '(.id as $document_id | .body | stage_result_body_shape_ok($document_id));' ''
}
loader_cell() {
  local mutation=${case_id##*-} member=${case_id#load-} location ancestor
  member=${member%-"$mutation"}
  copy_package "$tmp/load"
  case "$member" in
    contracts) location="$relative/contracts.jq" ;;
    ingress) location="$relative/core-ingress.sh" ;;
    schema|profile_graph|stage_request|result_facts|result_truth) location="$relative/modules/$member.jq" ;;
    repo) location=. ;;
    core) location=core ;;
    major) location=core/v3 ;;
    generations) location=core/v3/generations ;;
    generation) location="$relative" ;;
    modules) location="$relative/modules" ;;
    *) fail "unknown loader member $member" ;;
  esac
  # Rename owned copies only. The saved ingress remains addressable for all ancestor faults.
  ancestor="$tmp/load/$location"
  if [ "$location" = . ]; then
    mv "$tmp/load" "$tmp/load-saved"
    case "$mutation" in
      missing) : ;;
      nonregular) printf x >"$tmp/load" ;;
      symlink) ln -s "$tmp/load-saved" "$tmp/load" ;;
    esac
  else
    mv "$ancestor" "$tmp/held"
    case "$mutation" in
      missing) : ;;
      nonregular) if [ -d "$tmp/held" ]; then printf x >"$ancestor"; else mkdir "$ancestor"; fi ;;
      symlink) ln -s "$tmp/held" "$ancestor" ;;
    esac
  fi
  assert_route E_RUNTIME "$tmp/load/$relative" "$mode" "${inputs[@]}"
  rm -rf "$tmp/load" "$tmp/load-saved" "$tmp/held"
}
static_case() {
  local file old_generation restored mode_line manifest_path
  case "$case_id" in
    old-exports-exact)
      git -C "$root" ls-tree -r HEAD -- core/v1/generations core/v2/generations >"$tmp/new-exports"
      [ "$(wc -l < "$tmp/new-exports" | tr -d ' ')" = 28 ] || fail 'old export count'
      [ "$(sha_file "$tmp/new-exports")" = 37e913e16928aa68aafb5cd2e4a0548f82e0d36338378ea4ace1e12ac80f3899 ] || fail 'old export modes and bytes'
      [ "$(git -C "$root" hash-object scripts/core-contract.sh)" = 18748127ead49a22717723e9860210940010d84e ] || fail 'public wrapper changed' ;;
    registry-exact)
      "${jq_cmd[@]}" -S -c . "$root/core/v3/generation-registry.json" >"$tmp/registry.canonical"
      cmp -s "$root/core/v3/generation-registry.json" "$tmp/registry.canonical" || fail 'canonical registry'
      "${jq_cmd[@]}" -e --arg generation "$generation" '
        . == [{generation_id:$generation,parent_spec_blob:"e55e2aaeb179d7e06f229805744b2be49cbfa1bf",
          parent_plan_merge_commit:"c6c3f74181ea86f85be87ecf4431e67a5f272d82"}]
      ' "$root/core/v3/generation-registry.json" >/dev/null || fail 'exact registry'
      [ "$(git -C "$root" hash-object work/fixed-evidence-publication/plan.md)" = d8aa60b213cf7fce29c386b0eac49401c36643ff ] || fail 'accepted plan blob' ;;
    restore-exact)
      restored="$tmp/restored"
      mkdir "$restored"
      while IFS= read -r manifest_path; do
        case "$manifest_path" in ''|'#'*) continue ;; esac
        [ -f "$root/$manifest_path" ] && [ ! -L "$root/$manifest_path" ] || fail "manifest file $manifest_path"
        mkdir -p "$restored/$(dirname -- "$manifest_path")"
        cp "$root/$manifest_path" "$restored/$manifest_path"
        mode_line=$(git -C "$root" ls-files -s -- "$manifest_path")
        case "$mode_line" in
          100755*) chmod 0755 "$restored/$manifest_path" ;;
          100644*) chmod 0644 "$restored/$manifest_path" ;;
          *) fail "untracked or unsupported manifest mode $manifest_path" ;;
        esac
        cmp -s "$root/$manifest_path" "$restored/$manifest_path" || fail "restored bytes $manifest_path"
      done <"$root/ci/required-files.txt"
      for file in contracts.jq core-ingress.sh modules/schema.jq modules/profile_graph.jq modules/stage_request.jq modules/result_facts.jq modules/result_truth.jq; do
        [ -f "$restored/$relative/$file" ] && [ ! -x "$restored/$relative/$file" ] || fail "restored private member $file"
      done
      [ -f "$restored/core/v3/generation-registry.json" ] || fail 'restored registry'
      for route in D P T; do target=request; select_route; assert_route OK "$restored/$relative" "$mode" "${inputs[@]}"; done
      cmp -s "$root/scripts/core-contract.sh" "$restored/scripts/core-contract.sh" || fail 'restored wrapper'
      old_generation=$("${jq_cmd[@]}" -r '.[-1].generation_id' "$restored/core/v2/generation-registry.json")
      grep -Fq "PORTABLE_CORE_GENERATION='$old_generation'" "$restored/scripts/core-contract.sh" || fail 'restored public selection'
      rm -rf "$restored" ;;
    *) fail "unknown static case $case_id" ;;
  esac
}
guard_case() {
  local source="$tmp/guard-source" name directive
  (
    export schema_v3_generation=$generation
    export schema_root=$root
    export schema_v2_corrective_generation
    schema_v2_corrective_generation=$("${jq_cmd[@]}" -r '.[-1].generation_id' "$root/core/v2/generation-registry.json")
    sed -n '/^v3_generation_path_ok() {/,/^}/p' "$fixtures/portable-core-schema.test.sh" >"$tmp/guard-functions.sh"
    sed -n '/^v3_activation_path_ok() {/,/^}/p' "$fixtures/portable-core-schema.test.sh" >>"$tmp/guard-functions.sh"
    sed -n '/^schema_activation_state_ok() {/,/^}/p' "$fixtures/portable-core-schema.test.sh" >>"$tmp/guard-functions.sh"
    # shellcheck source=/dev/null
    source "$tmp/guard-functions.sh"
    case "$case_id" in
      guard-wrapper-switch)
        "${jq_cmd[@]}" -Rsr --arg generation "$generation" '
          gsub("PORTABLE_CORE_GENERATION='"'"'g-[0-9a-f]{64}'"'"'";
            "PORTABLE_CORE_GENERATION='"'"'"+$generation+"'"'"'")
        ' "$root/scripts/core-contract.sh" >"$tmp/wrapper-switched"
        chmod 0755 "$tmp/wrapper-switched"
        if schema_activation_state_ok "$package/contracts.jq" "$tmp/wrapper-switched"; then fail 'shared guard accepted v3 wrapper'; fi ;;
      guard-extra-module|guard-foreign-generation)
        name="$relative/modules/unknown.jq"
        [ "$case_id" != guard-foreign-generation ] || name="core/v3/generations/g-$(printf '0%.0s' {1..64})/modules/schema.jq"
        if v3_generation_path_ok "$name"; then fail 'shared guard accepted outside package'; fi ;;
      guard-public-caller|guard-work-loader)
        name=scripts/core-v3-loader.sh
        [ "$case_id" != guard-work-loader ] || name=work/other/loader.jq
        if v3_activation_path_ok "$name"; then fail 'shared guard accepted outside loader'; fi ;;
      *) fail "unknown guard case $case_id" ;;
    esac
  )
  for directive in 'include "schema";' 'import "../schema" as s;' 'import "schema" as s {search:"."};' 'import "schema" as $data;'; do
    printf '%s\n' "$directive" >"$source"
    if "${jq_cmd[@]}" -Rse '
      test("\\Aimport \"(schema|profile_graph|stage_request|result_facts|result_truth)\" as [a-z_]+;\\n\\z")
    ' "$source" >/dev/null; then fail 'import grammar accepted foreign directive'; fi
  done
}
[ "$(head -n 1 "$rules")" = $'rule_id\towner\tcase_id\tmode\texpected' ] || fail 'rules header'
[ "$(tail -n +2 "$rules" | wc -l | tr -d ' ')" = 606 ] || fail 'finite rule count'
[ "$(tail -n +2 "$rules" | cut -f3,4 | sort -u | wc -l | tr -d ' ')" = 606 ] || fail 'duplicate case/route'
: >"$tmp/executed"
while IFS=$'\t' read -r group owner case_id route expected; do
  [ "$group" != rule_id ] || continue
  reset_case
  case "$case_id" in
    force-*) force_cell ;;
    load-*) target=request; select_route; loader_cell ;;
    guard-*) guard_case ;;
    restore-exact|old-exports-exact|registry-exact) static_case ;;
    ambient-*)
      target=request; select_route
      mkdir -p "$tmp/poison/.jq"
      printf 'error("ambient poison");\n' >"$tmp/poison/schema.jq"
      cp "$tmp/poison/schema.jq" "$tmp/poison/.jq/schema.jq"
      (cd "$tmp/poison"; HOME="$tmp/poison" JQ_LIBRARY_PATH="$tmp/poison" \
        assert_route OK "$package" "$mode" "${inputs[@]}") ;;
    *) make_case; assert_route "$expected" "$package" "$mode" "${inputs[@]}" ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\n' "$group" "$owner" "$case_id" "$route" "$expected" >>"$tmp/executed"
  printf 'ok %s/%s expected=%s\n' "$case_id" "$route" "$expected"
done <"$rules"
tail -n +2 "$rules" >"$tmp/expected"
cmp -s "$tmp/expected" "$tmp/executed" || fail 'missing/unexpected execution row'
awk -F '\t' '{expected[$1]++; passed[$1]++} END {
  for (g in expected) printf "%s total=%d expected=%d passed=%d\n",g,expected[g],expected[g],passed[g]
}' "$tmp/executed" | sort
printf 'finite cases: 606/606\n'
inherited_graph() {
  local variant=$1 mutation=$2 original_producer variant_sha variant_shas
  original_producer="$tmp/manifest-producer.json"
  mutate "$mutation" "$original_producer" >"$tmp/inherited-manifest.json"
  variant_sha=$(sha_file "$tmp/inherited-manifest.json")
  variant_shas=$(fixture --argjson shas "$shas" --arg sha "$variant_sha" '$shas | .producer=$sha')
  fixture --argjson shas "$variant_shas" 'import "portable-core-v3-publisher-fixtures" as f; f::profile($shas)' >"$tmp/inherited-profile.json"
  fixture --slurpfile profile "$tmp/inherited-profile.json" --arg sha "$(sha_file "$tmp/inherited-profile.json")" --argjson shas "$variant_shas" \
    'import "portable-core-v3-publisher-fixtures" as f; f::resolved($profile[0];$sha;$shas)' >"$tmp/inherited-resolved.json"
  fixture --slurpfile profile "$tmp/inherited-profile.json" --arg profile_sha "$(sha_file "$tmp/inherited-profile.json")" \
    --slurpfile resolved "$tmp/inherited-resolved.json" --arg resolved_sha "$(sha_file "$tmp/inherited-resolved.json")" \
    --slurpfile producer "$tmp/inherited-manifest.json" --arg producer_sha "$variant_sha" \
    --slurpfile publisher "$tmp/manifest-publisher.json" --slurpfile reviewer "$tmp/manifest-reviewer.json" \
    --slurpfile verifier "$tmp/manifest-verifier.json" --slurpfile forge "$tmp/manifest-forge.json" --argjson shas "$shas" '
    {profile:{content:$profile[0],sha256:$profile_sha},resolved:{content:$resolved[0],sha256:$resolved_sha},
     manifests:[{content:$producer[0],sha256:$producer_sha},{content:$publisher[0],sha256:$shas.publisher},
      {content:$reviewer[0],sha256:$shas.reviewer},{content:$verifier[0],sha256:$shas.verifier},
      {content:$forge[0],sha256:$shas.forge}]}
  ' >"$tmp/graph-$variant.json"
}
run_inherited() {
  local row suite inherited_id role expression expected graph actual index mapped count=0
  fixture 'import "portable-core-v3-publisher-fixtures" as f; f::inherited_cases' >"$tmp/inherited-cases.json"
  [ "$(mutate 'length' "$tmp/inherited-cases.json")" = 626 ] || fail 'inherited case inventory'
  inherited_graph profile_graph '.'
  inherited_graph profile_role_offer_graph '.body.offered_roles=["reviewer"]'
  inherited_graph profile_capability_offer_graph '.body.offered_capabilities=[]'
  inherited_graph profile_execution_offer_graph '.body.offered_execution_kinds=["deterministic"]'
  inherited_graph profile_permission_offer_graph '.body.offered_permissions=[]'
  inherited_graph profile_tool_version_graph '.body.offered_tools[0].tool_version="v2"'
  inherited_graph profile_tool_package_graph '.body.offered_tools[0].package_ref.object_id=("0"*40)'
  inherited_graph profile_tool_config_presence_graph '.body.offered_tools[0].config_ref={state:"absent"}'
  inherited_graph profile_tool_config_object_graph '.body.offered_tools[0].config_ref.value.object_id=("0"*40)'
  inherited_graph profile_package_graph '.body.package_ref.object_id=("0"*40)'
  inherited_graph profile_config_contract_graph 'del(.body.config_contract_ref)'
  inherited_graph profile_superset_offer_graph '.body.offered_roles=["producer","reviewer"] |
    .body.offered_execution_kinds=["deterministic","model"] |
    .body.offered_capabilities=["core.harness.produce.v1","core.review.change.v1","core.verify.run.v1"] |
    .body.offered_permissions=["core.perm.candidate.execute.v1","core.perm.evidence.write.v1","core.perm.model.invoke.v1","core.perm.scratch.write.v1","core.perm.target.read.v1"] |
    .body.offered_tools += [(.body.offered_tools[0] | .tool_id="tool.zextra")]'
  mutate '. as $graph | .manifests += [range(1;4) as $n | $graph.manifests[0] | .content.id=("manifest.extra"+($n|tostring))]' \
    "$tmp/graph-profile_graph.json" >"$tmp/graph-profile_extra_graph.json"
  fixture --arg sha "$(sha_file "$tmp/resolved.json")" \
    'import "portable-core-stage-request-fixtures" as f; import "portable-core-v3-publisher-fixtures" as v; f::bootstrap_request_doc($sha) | v::v3' >"$tmp/request-bootstrap.json"
  mutate 'walk(if type=="object" and has("schema_version") then .schema_version=3 else . end) |
    .policy_expectation.capability_ids=["core.publisher.publish-evidence.v3","core.forge.materialize-candidate.v2","core.harness.produce.v1","core.review.change.v1","core.verify.run.v1"] |
    .policy_expectation.permission_ids=["core.perm.evidence-publication.create.v3","core.perm.candidate.execute.v1","core.perm.candidate-repository.write.v2","core.perm.evidence.write.v1","core.perm.model.invoke.v1","core.perm.scratch.write.v1","core.perm.target.read.v1"]' \
    "$fixtures/portable-core-schema-fixtures.json" >"$tmp/schema-fixture.json"
  : >"$tmp/inherited-executed"
  for index in $(seq 0 625); do
    row=$(mutate -c --argjson index "$index" '.[$index]' "$tmp/inherited-cases.json")
    suite=$(printf '%s\n' "$row" | "${jq_cmd[@]}" -r .suite)
    inherited_id=$(printf '%s\n' "$row" | "${jq_cmd[@]}" -r .case_id)
    role=$(printf '%s\n' "$row" | "${jq_cmd[@]}" -r .role)
    expression=$(printf '%s\n' "$row" | "${jq_cmd[@]}" -r .expression)
    expected=$(printf '%s\n' "$row" | "${jq_cmd[@]}" -r .expected)
    graph=$(printf '%s\n' "$row" | "${jq_cmd[@]}" -r .graph)
    mapped=$(printf '%s\n' "$row" | "${jq_cmd[@]}" -r '.mapped // empty')
    [ -n "$graph" ] || graph='$profile_graph'
    graph=${graph#\$}
    [ "$role" != bootstrap ] || cp "$tmp/result-producer.json" "$tmp/result-bootstrap.json"
    if ! actual=$("${jq_cmd[@]}" -r -n -L "$package/modules" -L "$fixtures" \
      --slurpfile graph "$tmp/graph-$graph.json" --slurpfile fixture "$tmp/schema-fixture.json" \
      --slurpfile request "$tmp/request-$role.json" --slurpfile resolved "$tmp/resolved.json" \
      --slurpfile result "$tmp/result-$role.json" \
      --arg request_sha "$(sha_file "$tmp/request-$role.json")" --arg resolved_sha "$(sha_file "$tmp/resolved.json")" '
      import "schema" as schema; import "profile_graph" as profile_graph;
      import "stage_request" as stage_request; import "result_facts" as result_facts;
      import "result_truth" as result_truth; import "portable-core-v3-publisher-fixtures" as fixture;
      $graph[0] as $g | $fixture[0] as $f | $request[0] as $request_doc |
      $resolved[0] as $resolved_doc | $result[0] as $result_doc |
      {content:$request_doc,sha256:$request_sha} as $request_pair |
      {content:$resolved_doc,sha256:$resolved_sha} as $resolved_pair | ('"$expression"')'); then
      fail "inherited $suite/$inherited_id jq error"
    fi
    [ "$actual" = "$expected" ] || fail "inherited $suite/$inherited_id expected=$expected actual=$actual"
    printf '%s\t%s\t%s\n' "$suite" "$inherited_id" "$mapped" >>"$tmp/inherited-executed"
    count=$((count + 1))
  done
  [ "$count" = 626 ] || fail 'partial inherited direct proof'
  printf 'inherited direct rules: %s/626\n' "$count"
}
run_inherited
prove_raw_pipeline() {
  local raw_case raw_expected target_file raw_input
  while IFS=$'\t' read -r raw_case raw_expected; do
    for route in D P T; do
      reset_case
      target=request
      [ "$route" != P ] || target=profile
      select_route
      target_file="$tmp/case/$target.json"
      raw_input="$tmp/raw-input"
      case "$raw_case" in
        empty) : >"$raw_input" ;;
        multi-root) printf '{}\n{}\n' >"$raw_input" ;;
        invalid-utf8) printf '\377\n' >"$raw_input" ;;
        bom) printf '\357\273\277{}\n' >"$raw_input" ;;
        duplicate-key) printf '{"a":1,"a":1}\n' >"$raw_input" ;;
        whitespace) printf ' {"a":1}\n' >"$raw_input" ;;
        escape) printf '{"a":"\\u0061"}\n' >"$raw_input" ;;
        missing-lf) printf '{}' >"$raw_input" ;;
        extra-lf) printf '{}\n\n' >"$raw_input" ;;
        unsorted) printf '{"z":1,"a":1}\n' >"$raw_input" ;;
        raw-limit) "${jq_cmd[@]}" -nr '"a"*1048577' >"$raw_input" ;;
        depth-limit) "${jq_cmd[@]}" -S -c -n 'reduce range(0;34) as $i (0; [.])' >"$raw_input" ;;
      esac
      cp "$raw_input" "$target_file"
      case_id="inherited-raw-$raw_case"
      assert_route "$raw_expected" "$package" "$mode" "${inputs[@]}"
      printf 'inherited raw pipeline %s/%s expected=%s\n' "$raw_case" "$route" "$raw_expected"
    done
  done <<'RAW'
empty	E_PARSE
multi-root	E_PARSE
invalid-utf8	E_PARSE
bom	E_CANONICAL
duplicate-key	E_CANONICAL
whitespace	E_CANONICAL
escape	E_CANONICAL
missing-lf	E_CANONICAL
extra-lf	E_CANONICAL
unsorted	E_CANONICAL
raw-limit	E_LIMIT
depth-limit	E_LIMIT
RAW
  printf 'inherited raw route cells: 36/36\n'
}
prove_raw_pipeline
ledger_static_accounting() {
  local ledger expected_blob actual_blob review=0 legacy=0 rcount lcount
  while IFS=$'\t' read -r ledger expected_blob; do
    actual_blob=$(git -C "$root" hash-object "scripts/test/$ledger")
    [ "$actual_blob" = "$expected_blob" ] || fail "frozen ledger $ledger"
    rcount=$(awk -F '\t' '$1=="review" {n++} END {print n+0}' "$fixtures/$ledger")
    lcount=$(awk -F '\t' '$1=="legacy" {n++} END {print n+0}' "$fixtures/$ledger")
    review=$((review + rcount)); legacy=$((legacy + lcount))
  done <<'LEDGERS'
portable-core-schema-ledger.tsv	3335f290b33d56c37d4386fc36051335d042ddc9
portable-core-ingress-ledger.tsv	64457f9e492acdfc150e0f56189e3b8a2ad6bfe0
portable-core-profile-graph-ledger.tsv	85c65af48ee14193ee12a3e4c0cf9c25dd3c4621
portable-core-stage-request-ledger.tsv	2ac759aac55110651c899a93b28e9a14df227ef8
portable-core-result-facts-ledger.tsv	702dd86f2b311015e5605ba76bbab358c5f5b5f8
portable-core-result-truth-ledger.tsv	0b2867c4064dc1eae22de985b3ca3b241ee40b6e
portable-core-assembly-ledger.tsv	4403ea649ea17fce35e3ff8a8e39276d9d7f518f
LEDGERS
  [ "$review" = 34 ] && [ "$legacy" = 279 ] || fail 'closed old ledger aggregate'
  printf 'frozen review ledger rows: %s/34 (static identity; execution is in unchanged suites)\n' "$review"
  printf 'frozen legacy ledger rows: %s/279 (static identity; execution is in unchanged suites)\n' "$legacy"
}
ledger_static_accounting
