#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
assembler="$root/shadow/v1/assemble-materialization-input.sh"
materializer="$root/adapters/local-git-materializer/v1/materialize.sh"
modules="$root/core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules"
protocol="$root/adapters/local-git-materializer/v1/protocol.jq"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-shadow-assembler-test.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() { /bin/chmod -R u+w "$tmp" 2>/dev/null || :; /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

# 0.1 — bootstrap the pinned jq 1.6 and the object-closure helper, the way
# scripts/test/shadow-slice.test.sh does (lines 1 and 3-56; line 2's
# file-level shellcheck directive is not copied — 2.9 says why).
case "$(/usr/bin/uname -s):$(/usr/bin/uname -m)" in
  Darwin:*) jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_asset=jq-linux64
    jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) fail "unsupported host" ;;
esac
jq_cache_dir="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$jq_cache_dir"
jq_cache="$jq_cache_dir/$jq_asset"
if [ ! -f "$jq_cache" ] || [ -L "$jq_cache" ] || [ "$(sha_file "$jq_cache")" != "$jq_sha" ]; then
  download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$download"
  [ "$(sha_file "$download")" = "$jq_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"; /bin/mv "$download" "$jq_cache"
fi
bin="$tmp/bin"
/bin/mkdir -m 700 "$bin"
/bin/cp "$jq_cache" "$bin/jq"; /bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"
[ "$("$jq_bin" --version)" = jq-1.6 ] || fail 'jq identity'
/usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 \
  "$root/adapters/local-git-materializer/v1/object-closure.c" -o "$bin/object-closure"
/bin/chmod 0555 "$bin/object-closure"
closure_helper="$bin/object-closure"
export PATH="$bin:/usr/bin:/bin"

git_clean() {
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects "$@"
}

# 0.2 — the sha1 fixture repository, byte-identical to the one
# scripts/test/shadow-slice.test.sh:81-98 builds, so its root commit is the
# one shadow/v1/shadow-environments.json lists for `fixture.target`; and a
# second, sha256, source repository (requirement 13).
/bin/mkdir -m 700 "$tmp/home" "$tmp/source.git"
git_clean init -q --bare --object-format=sha1 "$tmp/source.git"
blob=$(printf 'alpha\nbeta\n' | git_clean --git-dir="$tmp/source.git" hash-object -w --stdin)
notes_tree=$(printf '100644 blob %s\tkeep.txt\n' "$blob" |
  git_clean --git-dir="$tmp/source.git" mktree)
tree=$(printf '100644 blob %s\tsource.txt\n040000 tree %s\tnotes\n' "$blob" "$notes_tree" |
  git_clean --git-dir="$tmp/source.git" mktree)
commit=$(printf '%s\n' 'incident revision' |
  git_clean --git-dir="$tmp/source.git" commit-tree "$tree")
git_clean --git-dir="$tmp/source.git" update-ref refs/heads/main "$commit"
/bin/mkdir -m 700 "$tmp/source256.git"
git_clean init -q --bare --object-format=sha256 "$tmp/source256.git"
blob256=$(printf 'alpha\nbeta\n' | git_clean --git-dir="$tmp/source256.git" hash-object -w --stdin)
tree256=$(printf '100644 blob %s\tsource.txt\n' "$blob256" |
  git_clean --git-dir="$tmp/source256.git" mktree)
commit256=$(printf '%s\n' source |
  git_clean --git-dir="$tmp/source256.git" commit-tree "$tree256")
git_clean --git-dir="$tmp/source256.git" update-ref refs/heads/main "$commit256"

# 0.3 — the profile directory, the shipped default byte for byte, and a
# resolved profile over it: real bindings, real manifest digests, and a
# present producer config_source pinned to the real producer-config.json
# digest (requirement 16) — where the fixture builder elsewhere in this
# repo writes "absent" for every binding.
profile_dir="$tmp/profile-dir"
/bin/mkdir -m 700 -p "$profile_dir/manifests"
/bin/cp "$root/profiles/default/v1/profile.json" "$profile_dir/profile.json"
/bin/cp "$root/profiles/default/v1/producer-config.json" "$profile_dir/producer-config.json"
/bin/cp "$root/profiles/default/v1/manifests/"*.json "$profile_dir/manifests/"
profile_sha256=$(sha_file "$profile_dir/profile.json")
producer_config_sha256=$(sha_file "$profile_dir/producer-config.json")
manifest_sha256=$("$jq_bin" -c -n \
  --arg ci "$(sha_file "$profile_dir/manifests/github-actions-ci.json")" \
  --arg forge "$(sha_file "$profile_dir/manifests/local-git-materializer.json")" \
  --arg producer "$(sha_file "$profile_dir/manifests/claude-code-producer.json")" \
  --arg publisher "$(sha_file "$profile_dir/manifests/dormant-publisher.json")" \
  --arg reviewer "$(sha_file "$profile_dir/manifests/codex-native-reviewer.json")" \
  --arg verifier "$(sha_file "$profile_dir/manifests/deterministic-verifier.json")" \
  '{ci:$ci,forge:$forge,producer:$producer,publisher:$publisher,reviewer:$reviewer,verifier:$verifier}')

resolved_program="$tmp/build-resolved.jq"
cat > "$resolved_program" <<'JQEOF'
def present($v): {state:"present",value:$v};
def absent: {state:"absent"};
def source_value($s;$f;$d): {source:$s,value_format:$f,value_sha256:$d};
def content($id;$m;$d): {content_id:$id,media_type:$m,sha256:$d};
def scope($p;$id;$d): {purpose:$p,decision_record_ref:content("decision-"+$id;"application/json";$d),
  subject_ref:{type:"artifact",value:{type:"content",value:content($id;"application/json";$d)}},
  scope_sha256:$d};
def blob($path;$c): {revision:{repository_id:"repo.ystack",hash_algorithm:"sha1",commit_id:($c*40)},
  location:{kind:"path",value:$path},object_type:"blob",object_id:($c*40),mode:"100644"};
def resolved_binding($binding;$manifests;$producer_config):
  $binding.role as $role |
  {binding:$binding,adapter_implementation:{id:$binding.manifest_ref.id,version:"v1"},
   manifest_source:source_value(blob("manifests/"+$role+".json";"a");"canonical-json";$manifests[$role]),
   package_source:source_value($binding.package_ref;"raw-bytes";("b"*64)),
   config_source:(if $binding|has("config_ref") then present(source_value($binding.config_ref;
     "raw-bytes";(if $role=="producer" then $producer_config else ("c"*64) end))) else absent end),
   prompt_source:(if $binding|has("prompt_ref") then
     present(source_value($binding.prompt_ref;"raw-bytes";("d"*64))) else absent end),
   skill_sources:($binding.skill_refs|map(source_value(.;"raw-bytes";("e"*64)))),
   tool_sources:($binding.requested_tools|map({tool_id:.tool_id,
     package_source:source_value(.package_ref;"raw-bytes";("f"*64)),
     config_source:(if .config_ref.state=="present" then
       present(source_value(.config_ref.value;"raw-bytes";("9"*64))) else absent end)}))};
{schema_version:2,kind:"resolved_profile",id:"resolved.default.v1",
 body:{profile_ref:{schema_version:2,kind:"profile",id:$profile[0].id,sha256:$profile_sha256},
   profile_source:source_value(blob("profiles/default/v1/profile.json";"0");"canonical-json";
     $profile_sha256),
   selection_ref:scope("selection";"selection.default";("1"*64)),
   repository_context_ref:scope("repository-context";"repository.default";("2"*64)),
   bindings:($profile[0].body.bindings|map(resolved_binding(.;$manifest_sha256;$producer_config_sha256)))}}
JQEOF
resolved_profile="$tmp/resolved-profile.json"
"$jq_bin" -S -c -n --slurpfile profile "$profile_dir/profile.json" \
  --arg profile_sha256 "$profile_sha256" --arg producer_config_sha256 "$producer_config_sha256" \
  --argjson manifest_sha256 "$manifest_sha256" -f "$resolved_program" > "$resolved_profile"
claim="$tmp/claim.json"
"$jq_bin" -S -c -n '{schema_version:1,kind:"execution_environment_claim",
  id:"env.local-macos-fixture",body:{declaration_status:"complete"}}' > "$claim"

assemble() {
  local out=$1 repo=$2 source=$3 commit_id=$4 time=$5 pdir=$6 resolved=$7 jq_arg=$8 claim_arg=$9
  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /bin/bash -p "$assembler" assemble \
    "$repo" "$source" "$commit_id" "$time" "$pdir" "$resolved" "$jq_arg" "$out" "$claim_arg"
}
expect_error() {
  local name=$1 expected=$2 status=0 err
  shift 2
  /bin/rm -rf "$tmp/out-$name"; /bin/mkdir -m 700 "$tmp/out-$name"
  err=$(assemble "$tmp/out-$name" "$@" 2>&1 >/dev/null) || status=$?
  [ "$status" -ne 0 ] && [ "$err" = "$expected" ] || fail "$name (status=$status err=$err)"
  [ -z "$(/usr/bin/find "$tmp/out-$name" -mindepth 1 -print -quit)" ] || fail "$name-leftover"
  pass "$name -> $expected"
}
good=(fixture.target "$tmp/source.git" "$commit" 2026-09-10T00:00:00Z "$profile_dir" \
  "$resolved_profile" "$jq_bin" "$claim")

# 0.4 — the positive assertions.
good_out="$tmp/out-good"
/bin/mkdir -m 700 "$good_out"
assemble "$good_out" "${good[@]}"
"$jq_bin" -L "$modules" -e --arg command validate-input -f "$protocol" \
  "$good_out/input.json" >/dev/null || fail validate-input
listing=$(/bin/ls -a "$good_out" | /usr/bin/grep -v '^\.\{1,2\}$' | LC_ALL=C sort | /usr/bin/xargs)
[ "$listing" = "finish-condition.txt input.json output-contract-decision.txt policy-decision.txt resolved-profile-ref.json stage-request-ref.json verification-instructions.txt" ] ||
  fail good-listing
pass 'the output validates and a good run leaves exactly the seven documents'

second_out="$tmp/out-second"
/bin/mkdir -m 700 "$second_out"
assemble "$second_out" "${good[@]}"
for f in input.json stage-request-ref.json resolved-profile-ref.json finish-condition.txt \
  verification-instructions.txt output-contract-decision.txt policy-decision.txt; do
  /usr/bin/cmp -s "$good_out/$f" "$second_out/$f" || fail "determinism-$f"
done
"$jq_bin" -S -c . "$good_out/input.json" | /usr/bin/cmp -s - "$good_out/input.json" || fail canonical
pass 'a repeat run is byte-identical and canonical'

"$jq_bin" -e '
  ([.payloads[]|select(.input_id=="input.producer-patch")|.data]==[""]) and
  ([.trust_context.verified_payloads[]|
    select(.input_id=="input.producer-patch")|.content.data]==[""]) and
  .stage_request.content.body.operation.arguments.network_mode=="deny"
' "$good_out/input.json" >/dev/null || fail read-only-shape
claim_sha=$(sha_file "$claim")
"$jq_bin" -e --arg id env.local-macos-fixture --arg sha "$claim_sha" '
  .stage_request.content.body.environment_ref=={environment_id:$id,fingerprint_sha256:$sha}
' "$good_out/input.json" >/dev/null || fail environment-ref
"$jq_bin" -e --slurpfile request "$good_out/stage-request-ref.json" \
  --slurpfile resolved "$good_out/resolved-profile-ref.json" '
  def pair_ref($p): {schema_version:$p.content.schema_version,kind:$p.content.kind,
    id:$p.content.id,sha256:$p.sha256};
  $request[0]==pair_ref(.stage_request) and $resolved[0]==pair_ref(.resolved_profile)
' "$good_out/input.json" >/dev/null || fail pair-refs
pass 'read-only shape, environment_ref, and both pair_refs match what the driver compares'

sha256_out="$tmp/out-sha256"
/bin/mkdir -m 700 "$sha256_out"
assemble "$sha256_out" fixture.target "$tmp/source256.git" "$commit256" 2026-09-10T00:00:00Z \
  "$profile_dir" "$resolved_profile" "$jq_bin" "$claim"
"$jq_bin" -e '.stage_request.content.body.target_revision.value.hash_algorithm=="sha256" and
  (.stage_request.content.body.target_revision.value.commit_id|length)==64' \
  "$sha256_out/input.json" >/dev/null || fail sha256-width
pass 'both hash algorithms are covered, widths following the repository'

# 0.5 — one case per refusal class named in requirement 12.
expect_error usage-impossible-date E_USAGE fixture.target "$tmp/source.git" "$commit" \
  2026-02-30T00:00:00Z "$profile_dir" "$resolved_profile" "$jq_bin" "$claim"
/bin/ln -s "$tmp/source.git" "$tmp/source-link.git"
expect_error target-symlinked-source E_TARGET fixture.target "$tmp/source-link.git" "$commit" \
  2026-09-10T00:00:00Z "$profile_dir" "$resolved_profile" "$jq_bin" "$claim"
nonempty_out="$tmp/out-workspace-nonempty-output"
/bin/rm -rf "$nonempty_out"; /bin/mkdir -m 700 "$nonempty_out"
: > "$nonempty_out/stray"
ws_status=0
ws_err=$(assemble "$nonempty_out" "${good[@]}" 2>&1 >/dev/null) || ws_status=$?
[ "$ws_status" -ne 0 ] && [ "$ws_err" = E_WORKSPACE ] ||
  fail "workspace-nonempty-output (status=$ws_status err=$ws_err)"
pass 'workspace-nonempty-output -> E_WORKSPACE'
jq_wrong_digest="$tmp/bin-jq-wrong"
/bin/cp "$jq_bin" "$jq_wrong_digest"
/bin/chmod 0755 "$jq_wrong_digest"; printf 'x' >> "$jq_wrong_digest"; /bin/chmod 0555 "$jq_wrong_digest"
expect_error runtime-wrong-jq-digest E_RUNTIME fixture.target "$tmp/source.git" "$commit" \
  2026-09-10T00:00:00Z "$profile_dir" "$resolved_profile" "$jq_wrong_digest" "$claim"
big_claim="$tmp/big-claim.json"
"$jq_bin" -S -c -n '{schema_version:1,kind:"execution_environment_claim",
  id:"env.local-macos-fixture",body:{padding:("y"*1100000)}}' > "$big_claim"
expect_error limit-oversized-claim E_LIMIT fixture.target "$tmp/source.git" "$commit" \
  2026-09-10T00:00:00Z "$profile_dir" "$resolved_profile" "$jq_bin" "$big_claim"
two_roots="$tmp/two-roots-claim.json"
cat "$claim" "$claim" > "$two_roots"
expect_error parse-two-values E_PARSE fixture.target "$tmp/source.git" "$commit" \
  2026-09-10T00:00:00Z "$profile_dir" "$resolved_profile" "$jq_bin" "$two_roots"
noncanon_claim="$tmp/noncanon-claim.json"
"$jq_bin" -c -n '{schema_version:1,body:{declaration_status:"complete"},
  id:"env.local-macos-fixture",kind:"execution_environment_claim"}' > "$noncanon_claim"
expect_error canonical-claim E_CANONICAL fixture.target "$tmp/source.git" "$commit" \
  2026-09-10T00:00:00Z "$profile_dir" "$resolved_profile" "$jq_bin" "$noncanon_claim"
badkind_claim="$tmp/badkind-claim.json"
"$jq_bin" -S -c -n '{schema_version:1,kind:"something_else",
  id:"env.local-macos-fixture",body:{}}' > "$badkind_claim"
expect_error shape-claim-kind E_SHAPE fixture.target "$tmp/source.git" "$commit" \
  2026-09-10T00:00:00Z "$profile_dir" "$resolved_profile" "$jq_bin" "$badkind_claim"
lookalike_dir="$tmp/lookalike-dir"
/bin/mkdir -m 700 -p "$lookalike_dir/manifests"
/bin/cp "$profile_dir/producer-config.json" "$lookalike_dir/"
/bin/cp "$profile_dir/manifests/"*.json "$lookalike_dir/manifests/"
"$jq_bin" -S -c '.body.profile_version="v2"' "$profile_dir/profile.json" > "$lookalike_dir/profile.json"
expect_error profile-lookalike-default E_PROFILE fixture.target "$tmp/source.git" "$commit" \
  2026-09-10T00:00:00Z "$lookalike_dir" "$resolved_profile" "$jq_bin" "$claim"
inconsistent_resolved="$tmp/inconsistent-resolved.json"
"$jq_bin" -S -c '(.body.bindings|map(select(.binding.role=="verifier"))[0].manifest_source.value_sha256)
  as $other | .body.bindings |= map(if .binding.role=="reviewer" then
    .manifest_source.value_sha256=$other else . end)' "$resolved_profile" > "$inconsistent_resolved"
expect_error relation-inconsistent-set E_RELATION fixture.target "$tmp/source.git" "$commit" \
  2026-09-10T00:00:00Z "$profile_dir" "$inconsistent_resolved" "$jq_bin" "$claim"
pass 'one case fires per refusal class in requirement 12'
# The second half of E_RELATION — a finished input that fails validate-input
# after passing every earlier check — has no case here: nothing that passes
# 2.2-2.6 can reach a failing self-check, and the only way to force one is a
# test-only hook the plan's Alternatives reject. It is covered by review
# instead, plus the good run above proving a real run's self-check exits 0.

# 0.6(a) — the pins are live.
for pin_file in profile.json producer-config.json manifests/claude-code-producer.json \
  manifests/codex-native-reviewer.json manifests/deterministic-verifier.json \
  manifests/dormant-publisher.json manifests/github-actions-ci.json \
  manifests/local-git-materializer.json; do
  digest=$(sha_file "$root/profiles/default/v1/$pin_file")
  /usr/bin/grep -q "$digest" "$root/shadow/v1/materialization-input.jq" ||
    fail "pin-not-live-$pin_file"
done
pass 'the eight profile pins are live against the working tree'

# 0.6(b) — the copied spans are copies, read against the working tree.
extract() {
  /usr/bin/awk -v m="$1" '$0=="# copy-begin materialize.sh:" m {f=1;next}
    $0=="# copy-end materialize.sh:" m {f=0} f' "$assembler"
}
check_span() {
  local span=$1 start=$2 end=$3 first=$4 matches
  extract "$span" > "$tmp/copy-$span"
  [ "$(/usr/bin/wc -l < "$tmp/copy-$span" | /usr/bin/tr -d ' ')" -eq $((end - start + 1)) ] ||
    fail "span-length-$span"
  matches=$(/usr/bin/grep -n -x -F "$first" "$materializer")
  [ "$(printf '%s\n' "$matches" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" -eq 1 ] &&
    [ "${matches%%:*}" -eq "$start" ] || fail "anchor-$span"
  /usr/bin/sed -n "${start},${end}p" "$materializer" | /usr/bin/cmp -s - "$tmp/copy-$span" ||
    fail "span-bytes-$span"
}
check_span 76-81 76 81 'physical_dir() {'
check_span 271-332 271 332 'git_dir() {'
check_span 333-347 333 347 'packed_refs="$source_git_dir/packed-refs"'
check_span 348-360 348 360 "if find \"\$source_git_dir/hooks\" -type f ! -name '*.sample' -print -quit 2>/dev/null |"
check_span 4-13 4 13 'clean_path=/usr/bin:/bin'
[ "$(/usr/bin/sed -n '1p' "$materializer")" = "$(/usr/bin/sed -n '1p' "$assembler")" ] || fail shebang
extract 22-29 > "$tmp/copy-entry"
/usr/bin/grep -q '\[ "\$#" -eq 10 \]' "$tmp/copy-entry" &&
  /usr/bin/grep -q 'assemble' "$tmp/copy-entry" &&
  /usr/bin/grep -q 'builtin unalias -a' "$tmp/copy-entry" || fail entry-deviations
pass 'the copied spans are byte-identical to materialize.sh in the working tree'

# 0.6(c) — the source orders requirement 18 fixes.
trap_line=$(/usr/bin/grep -n '^trap cleanup_trap EXIT$' "$assembler" | /usr/bin/cut -d: -f1)
mkdir_line=$(/usr/bin/grep -n 'mkdir -m 0700 "\$run_root"' "$assembler" | /usr/bin/cut -d: -f1)
[ "$trap_line" -lt "$mkdir_line" ] || fail order-trap-before-mkdir
validate_line=$(/usr/bin/grep -n 'validate-input' "$assembler" | /usr/bin/tail -1 | /usr/bin/cut -d: -f1)
append_line=$(/usr/bin/grep -n 'record_destination "\$output_dir/\$name"' "$assembler" |
  /usr/bin/cut -d: -f1)
[ "$validate_line" -lt "$append_line" ] || fail order-validate-before-commit
other_mv_line=$(/usr/bin/grep -n '/bin/mv "\$stage_dir/\$name" "\$output_dir/\$name"' "$assembler" |
  /usr/bin/cut -d: -f1)
[ "$append_line" -lt "$other_mv_line" ] || fail order-append-before-mv
input_append_line=$(/usr/bin/grep -n 'record_destination "\$output_dir/input.json"' "$assembler" |
  /usr/bin/cut -d: -f1)
input_mv_line=$(/usr/bin/grep -n '/bin/mv "\$stage_dir/input.json" "\$output_dir/input.json"' \
  "$assembler" | /usr/bin/cut -d: -f1)
[ "$other_mv_line" -lt "$input_append_line" ] && [ "$input_append_line" -lt "$input_mv_line" ] ||
  fail order-input-last
committed_line=$(/usr/bin/grep -n '^committed=yes$' "$assembler" | /usr/bin/cut -d: -f1)
[ "$committed_line" -gt "$input_mv_line" ] || fail order-committed-after-input-mv
pass 'the trap, staging, and commit orders hold in the source'

# 0.7 — the driver run.
sandbox_policy="$root/control/v1/sandbox-policy.json"
sandbox_decision="$root/control/v1/sandbox-decision.json"
policy_set="$tmp/policy-set.json"
"$jq_bin" -S -c -n --arg sp "$(sha_file "$sandbox_policy")" --arg sd "$(sha_file "$sandbox_decision")" '
  def ref($id;$m;$s): {content_id:$id,media_type:$m,sha256:$s};
  def section($id;$p;$d): {section_id:$id,
    policy_ref:ref("control-policy."+$id;"application/vnd.ystack.control-policy+json";$p),
    decision_ref:ref("control-decision."+$id;"application/vnd.ystack.control-decision+json";$d)};
  {schema_version:1,kind:"control_policy_set",id:"control-policy-set.shadow-fixture",
   body:{activation_state:"inactive",core_contract:{generation_id:("g-"+("7"*64)),
       package_ref:ref("core-contract-package.v2";"application/vnd.ystack.core-contract+json";("9"*64)),
       semantic_identity:"core.contracts.v2"},
     fail_mode:"closed",policy_version:"v1",
     sections:[section("credential-policy";("1"*64);("a"*64)),
       section("duty-separation";("2"*64);("b"*64)),section("evidence-integrity";("3"*64);("c"*64)),
       section("kill-switch";("4"*64);("d"*64)),section("risk-gates";("5"*64);("e"*64)),
       section("sandbox";$sp;$sd)]}}' > "$policy_set"
policy_set_sha=$(sha_file "$policy_set")
duty="$tmp/duty.json"
"$jq_bin" -S -c -n --arg set_sha "$policy_set_sha" --slurpfile set "$policy_set" '
  def content($id;$s): {content_id:$id,media_type:"application/vnd.ystack.control-decision+json",sha256:$s};
  def document($k;$id;$s): {schema_version:2,kind:$k,id:$id,sha256:$s};
  {schema_version:1,kind:"duty_separation_evaluation",id:"result.shadow-fixture",
   body:{activation_state:"inactive",core_contract:$set[0].body.core_contract,
     decision_ref:content("control-decision.duty-separation";("b"*64)),
     evaluation_mode:"observation-only",
     policy_ref:(content("control-policy.duty-separation";("2"*64))|
       .media_type="application/vnd.ystack.control-policy+json"),
     policy_set:{id:"control-policy-set.shadow-fixture",sha256:$set_sha},
     reason_ids:["duty.satisfied"],reference_semantics:"identity-only",
     stage:{request_ref:document("stage_request";"request.shadow-fixture";("3"*64)),
       resolved_profile_ref:document("resolved_profile";"profile.shadow-fixture";("4"*64)),
       result_ref:document("stage_result";"result.shadow-fixture";("5"*64))},
     verdict:"satisfied"}}' > "$duty"
driver_claim="$tmp/driver-claim.json"
"$jq_bin" -S -c -n --arg set_sha "$policy_set_sha" --arg duty_sha "$(sha_file "$duty")" \
  --slurpfile policy "$sandbox_policy" '
  def document($v;$k;$id;$s): {schema_version:$v,kind:$k,id:$id,sha256:$s};
  {schema_version:1,kind:"execution_environment_claim",id:"env.local-macos-fixture",
   body:{declaration_status:"complete",
     duty_evaluation_ref:document(1;"duty_separation_evaluation";"result.shadow-fixture";$duty_sha),
     effects:{external_writes:false,target_writes:false},environment:$policy[0].body.environment,
     execution_identity:{adapter_instance_id:"instance.verifier",
       execution_boundary_id:"boundary.verifier",principal_id:"principal.verifier",role:"verifier"},
     filesystem:$policy[0].body.filesystem,isolation:$policy[0].body.isolation,
     limits:$policy[0].body.limits,network:$policy[0].body.network,
     policy_set_ref:document(1;"control_policy_set";"control-policy-set.shadow-fixture";$set_sha),
     resources:$policy[0].body.resources,sensitive_material:$policy[0].body.sensitive_material,
     stage_result_ref:document(2;"stage_result";"result.shadow-fixture";("5"*64)),
     tools:$policy[0].body.tools}}' > "$driver_claim"
driver_out="$tmp/out-driver"
/bin/mkdir -m 700 "$driver_out"
assemble "$driver_out" fixture.target "$tmp/source.git" "$commit" 2026-09-10T00:00:00Z \
  "$profile_dir" "$resolved_profile" "$jq_bin" "$driver_claim"
expected_digest=$(printf 'alpha\nbeta\n' | sha_file /dev/stdin)
incident="$tmp/incident.json"
"$jq_bin" -S -c -n --arg commit "$commit" --arg expected "$expected_digest" '
  {schema_version:1,kind:"shadow_incident_record",id:"incident.assembler-test",
   body:{deploy_authority:"none",target_repository_id:"fixture.target",
     git_revision_ref:{repository_id:"fixture.target",hash_algorithm:"sha1",commit_id:$commit},
     failing_check:{kind:"file-digest",path:"source.txt",expected_sha256:$expected},
     observed_symptom:"source.txt no longer matches the recorded digest",
     reporter_actor_ref:"actor.fixture-reporter",observed_at:"2026-08-30T00:00:04Z"}}' > "$incident"
identity="$tmp/identity.json"
"$jq_bin" -S -c -n --arg blob "$blob" --arg commit "$commit" --slurpfile input "$driver_out/input.json" '
  def digest($c): ($c*64);
  def pair_ref($p): {schema_version:$p.content.schema_version,kind:$p.content.kind,
    id:$p.content.id,sha256:$p.sha256};
  {schema_version:1,kind:"qualified_identity",id:"identity.assembler-test",
   body:{adapter_config_refs:[{content_id:"producer-config",
       media_type:"application/vnd.ystack.adapter-config+json",sha256:digest("1")}],
     model_request:{effort_id:"high",model_id:"model.fixture",provider_id:"provider.fixture"},
     prompt_refs:[{location:{kind:"path",value:"routines/coder.md"},mode:"100644",object_id:$blob,
       object_type:"blob",revision:{commit_id:$commit,hash_algorithm:"sha1",
         repository_id:"fixture.harness"}}],
     resolved_profile_ref:pair_ref($input[0].resolved_profile),skill_refs:[],
     stage_request_ref:pair_ref($input[0].stage_request),
     target_revision:{commit_id:$commit,hash_algorithm:"sha1",repository_id:"fixture.target"},
     verification_instructions_ref:{content_id:"verification-instructions",
       media_type:"application/vnd.ystack.verification-instructions+json",sha256:digest("4")}}}' \
  > "$identity"
driver_case="$tmp/driver-case"
/bin/mkdir -m 700 "$driver_case" "$driver_case/candidate" "$driver_case/scratch" "$driver_case/state"
"$root/shadow/v1/reproduce.sh" reproduce "$incident" "$driver_claim" "$policy_set" "$duty" \
  "$driver_out/input.json" "$identity" "$tmp/source.git" "$driver_case/candidate" \
  "$driver_case/scratch" "$driver_case/state" "$closure_helper" "$jq_bin" \
  > "$driver_case/out.json" 2> "$driver_case/err"
[ -s "$driver_case/err" ] && fail "driver-run: $(cat "$driver_case/err")"
outcome=$("$jq_bin" -r '.body.outcome' "$driver_case/out.json")
[ "$outcome" != inconclusive ] || fail "driver-inconclusive: $(cat "$driver_case/err")"
pass "the driver accepts the assembled input and answers $outcome"

/usr/bin/printf 'shadow assembler: %s focused checks passed\n' "$passes"
