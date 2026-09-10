#!/bin/bash -p
# Copied verbatim from adapters/local-git-materializer/v1/materialize.sh at
# a637451d4b3fbef6b516a9c08f68c0dde46a7059 (origin/main) — keep in sync. Bash
# resolves a shell function before consulting PATH, so a caller who cannot
# touch PATH could still make a bare command below run its own code; the
# scrub and the re-exec close that door the way the materializer's own entry
# does.
# copy-begin materialize.sh:4-13
clean_path=/usr/bin:/bin
while IFS= builtin read -r inherited_function; do
  builtin unset -f "$inherited_function" 2>/dev/null || :
done < <(builtin compgen -A function)
while IFS= builtin read -r exported_name; do
  case "$exported_name" in PATH) ;; *) builtin unset "$exported_name" 2>/dev/null || : ;; esac
done < <(builtin compgen -e)
PATH=$clean_path
LC_ALL=C
export PATH LC_ALL
# copy-end materialize.sh:4-13

set -euo pipefail

emit_error() {
  printf '%s\n' "${1:-E_RUNTIME}" >&2
  exit 1
}

umask 077

# Same producer, same commit, with requirement 17's four deviations: the
# marker word and verb, the argument count, the script-path normalization,
# and the marker branch's alias reset.
# copy-begin materialize.sh:22-29
[ "$#" -eq 10 ] || emit_error E_USAGE
script_path=${BASH_SOURCE[0]}
case "$script_path" in /*) ;; *) script_path="$(pwd -P)/$script_path" ;; esac
[ -f "$script_path" ] && [ ! -L "$script_path" ] || emit_error E_RUNTIME
if [ "$1" = assemble ]; then
  exec /usr/bin/env -i PATH="${PATH:-/usr/bin:/bin}" LC_ALL=C \
    /bin/bash "$script_path" __assemble_clean "$2" "$3" "$4" "$5" "$6" "$7" "$8" \
    "$9" "${10}"
fi
[ "$1" = __assemble_clean ] || emit_error E_USAGE
builtin unalias -a
builtin shopt -u expand_aliases
# copy-end materialize.sh:22-29

# Requirement 1's nine positional arguments, the verb already consumed above.
repository_id=$2
source_git_dir=$3
source_commit=$4
requested_at=$5
profile_dir=$6
resolved_profile_file=$7
jq_bin=$8
output_dir=$9
claim_file=${10}

sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

# Same producer, same commit: the one helper both this check and step (6)'s
# output-directory check call, the way empty_private_dir calls it at :97-98.
# copy-begin materialize.sh:76-81
physical_dir() {
  local path=$1 actual
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  actual=$(CDPATH='' cd -P -- "$path" && pwd -P) || return 1
  [ "$actual" = "$path" ]
}
# copy-end materialize.sh:76-81

directory_mode() {
  /usr/bin/stat -c '%a' "$1" 2>/dev/null || /usr/bin/stat -f '%Lp' "$1" 2>/dev/null
}
empty_private_dir() {
  physical_dir "$1" &&
    [ "$(directory_mode "$1")" = 700 ] &&
    [ -z "$(/usr/bin/find "$1" -mindepth 1 -print -quit 2>/dev/null)" ]
}
overlaps() {
  if [ "$1" = / ] || [ "$2" = / ]; then return 0; fi
  case "$1/" in "$2/"*) return 0 ;; esac
  case "$2/" in "$1/"*) return 0 ;; esac
  return 1
}

# 2.2 — argument and workspace checks in the order requirement 12 needs: an
# E_USAGE condition has to be decided before anything that can only fail
# E_WORKSPACE or E_RUNTIME. (1) arity/verb decided above.

# (2) every path argument absolute; existence/symlink-ness defers to (7),
# except the source directory (2.4) and the output directory (6) below.
for path_argument in "$source_git_dir" "$profile_dir" "$resolved_profile_file" \
  "$jq_bin" "$output_dir" "$claim_file"; do
  case "$path_argument" in /*) ;; *) emit_error E_USAGE ;; esac
done

# (3) the repository id.
[[ "$repository_id" =~ ^[a-z0-9][a-z0-9._:-]{0,127}$ ]] || emit_error E_USAGE

# (4) the commit id: lowercase hex of 40 or 64 characters. Width against the
# algorithm the repository actually reports is requirement 15's copy, below.
if [[ "$source_commit" =~ ^[0-9a-f]{40}$ ]]; then
  source_algorithm=sha1
elif [[ "$source_commit" =~ ^[0-9a-f]{64}$ ]]; then
  source_algorithm=sha256
else
  emit_error E_USAGE
fi

# (5) the timestamp's shape only; requirement 10's time_ok decides whether a
# well-shaped timestamp is a real instant.
[[ "$requested_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
  emit_error E_USAGE

# (6) the output directory: existing, empty, physical, 0700, disjoint from
# the source repository and the profile directory.
empty_private_dir "$output_dir" || emit_error E_WORKSPACE
overlaps "$output_dir" "$source_git_dir" && emit_error E_WORKSPACE
overlaps "$output_dir" "$profile_dir" && emit_error E_WORKSPACE
:

# (7) only now the pinned-jq checks, plus existence/non-symlink checks of
# every other supplied file and the component's own required files. Nothing
# above this line hashes or executes $jq_bin.
case "$(/usr/bin/uname -s):$(/usr/bin/uname -m)" in
  Darwin:*) jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) emit_error E_RUNTIME ;;
esac
[ -f "$jq_bin" ] && [ ! -L "$jq_bin" ] || emit_error E_RUNTIME
[ "$(sha256_path "$jq_bin")" = "$jq_sha" ] || emit_error E_RUNTIME
[ "$("$jq_bin" --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME

manifest_names="claude-code-producer codex-native-reviewer deterministic-verifier dormant-publisher github-actions-ci local-git-materializer"
for required in "$resolved_profile_file" "$claim_file" \
  "$profile_dir/profile.json" "$profile_dir/producer-config.json"; do
  [ -f "$required" ] && [ ! -L "$required" ] || emit_error E_RUNTIME
done
for manifest_name in $manifest_names; do
  required="$profile_dir/manifests/$manifest_name.json"
  [ -f "$required" ] && [ ! -L "$required" ] || emit_error E_RUNTIME
done

script_dir=$(CDPATH='' cd -P -- "${script_path%/*}" && pwd -P) || emit_error E_RUNTIME
repo_root=$(CDPATH='' cd -P -- "$script_dir/../.." && pwd -P) || emit_error E_RUNTIME
program="$script_dir/materialization-input.jq"
protocol="$repo_root/adapters/local-git-materializer/v1/protocol.jq"
core="$repo_root/scripts/core-contract.sh"
registry="$repo_root/core/v2/generation-registry.json"
for required in "$program" "$protocol" "$core" "$registry"; do
  [ -f "$required" ] && [ ! -L "$required" ] || emit_error E_RUNTIME
done

generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\\(g-[0-9a-f]\\{64\\}\\)'\$/\\1/p" "$core") ||
  emit_error E_RUNTIME
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || emit_error E_RUNTIME
"$jq_bin" -e --arg generation "$generation" '
  [.[] | select(.generation_id == $generation and
    .semantic_identity == "core.contracts.v2")] | length == 1
' "$registry" >/dev/null || emit_error E_RUNTIME
modules="$repo_root/core/v2/generations/$generation/modules"
[ -d "$modules" ] && [ ! -L "$modules" ] || emit_error E_RUNTIME

# Requirement 10: time_ok on the timestamp, before any input file is opened.
# Exit status and stdout are captured separately so "ran and said false"
# (E_USAGE) is never confused with "could not run at all" (E_RUNTIME).
time_status=0
time_answer=$(printf '%s' "$requested_at" |
  "$jq_bin" -L "$modules" -R 'import "schema" as schema; schema::time_ok' \
  2>/dev/null) || time_status=$?
[ "$time_status" -eq 0 ] || emit_error E_RUNTIME
case "$time_answer" in
  true) ;;
  false) emit_error E_USAGE ;;
  *) emit_error E_RUNTIME ;;
esac

# 2.3 — the eight profile documents are pinned by digest (requirement 3), so
# their bound is checked first and canonical form follows from a pin match;
# the resolved profile and the claim are not pinned, so they get the full
# BOM/parse/one-value/canonical treatment reproduce.sh's canonical_json gives.
size_ok() {
  local bytes
  bytes=$(/usr/bin/wc -c < "$1" | /usr/bin/tr -d ' ') || emit_error E_RUNTIME
  case "$bytes" in ''|*[!0-9]*) emit_error E_RUNTIME ;; esac
  [ "$bytes" -le "$2" ] || emit_error E_LIMIT
}
canonical_json() {
  local raw=$1 bom
  bom=$(/usr/bin/od -An -tx1 -N3 "$raw" 2>/dev/null | /usr/bin/tr -d ' \n') ||
    emit_error E_RUNTIME
  [ "$bom" != efbbbf ] || emit_error E_PARSE
  "$jq_bin" . "$raw" >/dev/null 2>&1 || emit_error E_PARSE
  [ "$("$jq_bin" -s 'length' "$raw" 2>/dev/null)" -eq 1 ] || emit_error E_PARSE
  "$jq_bin" -S -c . "$raw" > "$raw.canonical-check" 2>/dev/null || emit_error E_PARSE
  if /usr/bin/cmp -s "$raw" "$raw.canonical-check"; then
    /bin/rm -f -- "$raw.canonical-check"
  else
    /bin/rm -f -- "$raw.canonical-check"
    emit_error E_CANONICAL
  fi
}

manifest_count=$(/usr/bin/find "$profile_dir/manifests" -mindepth 1 -maxdepth 1 \
  -type f 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ') || emit_error E_RUNTIME
[ "$manifest_count" -eq 6 ] || emit_error E_PROFILE

size_ok "$profile_dir/profile.json" 1048576
size_ok "$profile_dir/producer-config.json" 1048576
for manifest_name in $manifest_names; do
  size_ok "$profile_dir/manifests/$manifest_name.json" 1048576
done
size_ok "$resolved_profile_file" 8388608
size_ok "$claim_file" 1048576
canonical_json "$resolved_profile_file"
canonical_json "$claim_file"

profile_sha256=$(sha256_path "$profile_dir/profile.json")
producer_config_sha256=$(sha256_path "$profile_dir/producer-config.json")
manifest_sha256=$("$jq_bin" -c -n \
  --arg ci "$(sha256_path "$profile_dir/manifests/github-actions-ci.json")" \
  --arg forge "$(sha256_path "$profile_dir/manifests/local-git-materializer.json")" \
  --arg producer "$(sha256_path "$profile_dir/manifests/claude-code-producer.json")" \
  --arg publisher "$(sha256_path "$profile_dir/manifests/dormant-publisher.json")" \
  --arg reviewer "$(sha256_path "$profile_dir/manifests/codex-native-reviewer.json")" \
  --arg verifier "$(sha256_path "$profile_dir/manifests/deterministic-verifier.json")" \
  '{ci:$ci,forge:$forge,producer:$producer,publisher:$publisher,reviewer:$reviewer,
    verifier:$verifier}')
resolved_profile_sha256=$(sha256_path "$resolved_profile_file")
claim_sha256=$(sha256_path "$claim_file")

# 2.4 — run_root's path is computed, the trap installed, and only then the
# directory created (requirement 18): a signal between mkdir and trap would
# otherwise leave a directory nothing is watching.
run_root="$output_dir/.ystack-assemble-run"
committed=no
committed_destinations=""
record_destination() {
  committed_destinations="${committed_destinations}${1}
"
}
cleanup_trap() {
  if [ "$committed" != yes ] && [ -n "$committed_destinations" ]; then
    printf '%s' "$committed_destinations" | while IFS= read -r destination; do
      [ -z "$destination" ] || [ ! -e "$destination" ] || /bin/rm -f -- "$destination"
    done
  fi
  [ -n "${run_root:-}" ] && [ -d "$run_root" ] && /bin/rm -rf -- "$run_root"
  return 0
}
on_signal() {
  trap - EXIT INT TERM HUP
  cleanup_trap
  kill -s "$1" "$$"
}
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP
trap cleanup_trap EXIT
/bin/mkdir -m 0700 "$run_root" || emit_error E_RUNTIME

git_env=(/usr/bin/env -i HOME="$run_root" TMPDIR="$run_root" PATH=/usr/bin:/bin LC_ALL=C
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1
  GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath
  GIT_CONFIG_VALUE_0="$run_root/no-hooks")

# The source directory's own physical check, which the copy below does not
# carry (materialize.sh:118 is outside the three spans starting at 271).
physical_dir "$source_git_dir" || emit_error E_TARGET

# 2.5 — the verbatim copy of every repository-level source-purity predicate
# the materializer applies (requirement 15). emit_error is shadowed to a
# bare non-zero exit inside the subshell, so the predicates keep their exact
# text while a failure comes back as a status this script can name.
source_pure() (
  emit_error() { exit 1; }
# copy-begin materialize.sh:271-332
git_dir() {
  local directory=$1
  shift
  "${git_env[@]}" /usr/bin/git --no-replace-objects --git-dir="$directory" "$@"
}

source_inventory="$run_root/source-filesystem"
source_inventory_byte_limit=8388608
source_inventory_entry_limit=65536
source_inventory_ceiling=$((source_inventory_byte_limit + 1))
if ! /usr/bin/find "$source_git_dir" -mindepth 1 -print0 |
  /usr/bin/head -c "$source_inventory_ceiling" > "$source_inventory"; then
  emit_error E_SOURCE_LIMIT
fi
source_inventory_bytes=$(/usr/bin/wc -c < "$source_inventory" | /usr/bin/tr -d ' ') ||
  emit_error E_SOURCE_LIMIT
[ "$source_inventory_bytes" -le "$source_inventory_byte_limit" ] ||
  emit_error E_SOURCE_LIMIT
source_inventory_entries=0
while IFS= builtin read -r -d '' source_entry; do
  source_inventory_entries=$((source_inventory_entries + 1))
  [ "$source_inventory_entries" -le "$source_inventory_entry_limit" ] ||
    emit_error E_SOURCE_LIMIT
  case "$source_entry" in "$source_git_dir"/*) ;; *) emit_error E_SOURCE_GIT ;; esac
  if [ -L "$source_entry" ] || { [ ! -f "$source_entry" ] && [ ! -d "$source_entry" ]; }; then
    emit_error E_SOURCE_GIT
  fi
done < "$source_inventory"
/bin/rm -f -- "$source_inventory"

source_config_input="$source_git_dir/config"
[ -f "$source_config_input" ] && [ ! -L "$source_config_input" ] ||
  emit_error E_SOURCE_CONFIG
source_config_snapshot="$run_root/source-config.snapshot"
source_config_ceiling=1048577
if ! /usr/bin/head -c "$source_config_ceiling" "$source_config_input" \
  > "$source_config_snapshot"; then
  emit_error E_SOURCE_CONFIG
fi
source_config_bytes=$(/usr/bin/wc -c < "$source_config_snapshot" | /usr/bin/tr -d ' ') ||
  emit_error E_SOURCE_CONFIG
[ "$source_config_bytes" -le 1048576 ] || emit_error E_SOURCE_CONFIG
source_config="$run_root/source-config"
"${git_env[@]}" /usr/bin/git config --file "$source_config_snapshot" \
  --name-only --list --no-includes > "$source_config" 2>/dev/null ||
  emit_error E_SOURCE_CONFIG
while IFS= read -r config_key; do
  case "$config_key" in
    core.repositoryformatversion|core.filemode|core.bare|core.logallrefupdates|core.ignorecase|core.precomposeunicode|extensions.objectformat) ;;
    '') ;;
    *) emit_error E_SOURCE_CONFIG ;;
  esac
done < "$source_config"
[ "$(git_dir "$source_git_dir" rev-parse --is-bare-repository 2>/dev/null)" = true ] ||
  emit_error E_SOURCE_WORKTREE
[ ! -e "$source_git_dir/commondir" ] && [ ! -e "$source_git_dir/shallow" ] &&
  [ -z "$(find "$source_git_dir/worktrees" -mindepth 1 -print -quit 2>/dev/null)" ] &&
  [ ! -e "$source_git_dir/info/grafts" ] &&
  [ ! -e "$source_git_dir/objects/info/alternates" ] &&
  [ ! -d "$source_git_dir/refs/replace" ] &&
  [ -z "$(find "$source_git_dir/objects/pack" -type f -name '*.promisor' -print -quit 2>/dev/null)" ] ||
  emit_error E_SOURCE_GIT
# copy-end materialize.sh:271-332
# copy-begin materialize.sh:333-347
packed_refs="$source_git_dir/packed-refs"
if [ -e "$packed_refs" ]; then
  [ -f "$packed_refs" ] && [ ! -L "$packed_refs" ] || emit_error E_SOURCE_GIT
  packed_refs_snapshot="$run_root/packed-refs"
  if ! /usr/bin/head -c 1048577 "$packed_refs" > "$packed_refs_snapshot"; then
    emit_error E_SOURCE_LIMIT
  fi
  packed_refs_bytes=$(/usr/bin/wc -c < "$packed_refs_snapshot" | /usr/bin/tr -d ' ') ||
    emit_error E_SOURCE_LIMIT
  [ "$packed_refs_bytes" -le 1048576 ] || emit_error E_SOURCE_LIMIT
  if /usr/bin/grep -aEq '^[0-9A-Fa-f]{40} refs/replace/|^[0-9A-Fa-f]{64} refs/replace/' \
      "$packed_refs_snapshot"; then
    emit_error E_SOURCE_GIT
  fi
fi
# copy-end materialize.sh:333-347
# copy-begin materialize.sh:348-360
if find "$source_git_dir/hooks" -type f ! -name '*.sample' -print -quit 2>/dev/null |
   /usr/bin/grep -q .; then
  emit_error E_SOURCE_HOOK
fi
actual_algorithm=$(git_dir "$source_git_dir" rev-parse --show-object-format 2>/dev/null) ||
  emit_error E_SOURCE_GIT
[ "$actual_algorithm" = "$source_algorithm" ] || emit_error E_SOURCE_IDENTITY
source_commit_type=$(git_dir "$source_git_dir" cat-file -t "$source_commit" 2>/dev/null) ||
  emit_error E_SOURCE_IDENTITY
source_commit_size=$(git_dir "$source_git_dir" cat-file -s "$source_commit" 2>/dev/null) ||
  emit_error E_SOURCE_IDENTITY
[ "$source_commit_type" = commit ] && [ "$source_commit_size" -le 1048576 ] ||
  emit_error E_SOURCE_LIMIT
# copy-end materialize.sh:348-360
  exit 0
)
source_pure || emit_error E_TARGET

# 2.6 — only after source_pure returns clean: the algorithm and the root
# tree id, read in the parent shell (source_pure is a subshell; no value
# escapes it). Nothing here re-reads the commit's tree content — the
# materializer's own check, by the boundary requirement 15 states.
hash_algorithm=$("${git_env[@]}" /usr/bin/git --no-replace-objects \
  --git-dir="$source_git_dir" rev-parse --show-object-format 2>/dev/null) ||
  emit_error E_RUNTIME
tree_id=$("${git_env[@]}" /usr/bin/git --no-replace-objects --git-dir="$source_git_dir" \
  rev-parse "$source_commit^{tree}" 2>/dev/null) || emit_error E_RUNTIME

# shadow/v1/materialization-input.jq: first the stage request, whose bytes
# must be finished before they can be digested, then the finished input
# built around that digest. The two calls share every argument but the
# phase and the stage-request digest.
common_args=(-n -L "$modules"
  --arg repository_id "$repository_id" --arg hash_algorithm "$hash_algorithm"
  --arg commit_id "$source_commit" --arg tree_id "$tree_id"
  --arg requested_at "$requested_at" --arg profile_sha256 "$profile_sha256"
  --arg producer_config_sha256 "$producer_config_sha256"
  --argjson manifest_sha256 "$manifest_sha256"
  --arg resolved_profile_sha256 "$resolved_profile_sha256"
  --arg claim_sha256 "$claim_sha256"
  --slurpfile profile "$profile_dir/profile.json"
  --slurpfile resolved_profile "$resolved_profile_file"
  --slurpfile claim "$claim_file"
  --slurpfile manifest_ci "$profile_dir/manifests/github-actions-ci.json"
  --slurpfile manifest_forge "$profile_dir/manifests/local-git-materializer.json"
  --slurpfile manifest_producer "$profile_dir/manifests/claude-code-producer.json"
  --slurpfile manifest_publisher "$profile_dir/manifests/dormant-publisher.json"
  --slurpfile manifest_reviewer "$profile_dir/manifests/codex-native-reviewer.json"
  --slurpfile manifest_verifier "$profile_dir/manifests/deterministic-verifier.json")

request_out="$run_root/request-out.json"
"$jq_bin" "${common_args[@]}" --arg phase request --arg stage_request_sha256 '' \
  --slurpfile stage_request "$profile_dir/profile.json" -f "$program" \
  > "$request_out" || emit_error E_RUNTIME
request_ok=$("$jq_bin" -r '.ok' "$request_out") || emit_error E_RUNTIME
[ "$request_ok" = true ] || emit_error "$("$jq_bin" -r '.error' "$request_out")"
stage_request_raw="$run_root/stage-request.json"
"$jq_bin" -S -c '.value' "$request_out" > "$stage_request_raw" || emit_error E_RUNTIME
stage_request_sha256=$(sha256_path "$stage_request_raw")

input_out="$run_root/input-out.json"
"$jq_bin" "${common_args[@]}" --arg phase input \
  --arg stage_request_sha256 "$stage_request_sha256" \
  --slurpfile stage_request "$stage_request_raw" -f "$program" \
  > "$input_out" || emit_error E_RUNTIME

# 2.7 — size check, then stage, then commit (requirement 18). The finished
# input is measured before anything is staged. The five smaller outputs
# stage first, each `> name.tmp && mv name.tmp name`; input.json is kept out
# of that loop because it alone needs the size check and moves out last.
finished_input="$run_root/input.json"
"$jq_bin" -S -c '.value.input' "$input_out" > "$finished_input" || emit_error E_RUNTIME
size_ok "$finished_input" 8388608

stage_dir="$run_root/stage"
/bin/mkdir -m 0700 "$stage_dir" || emit_error E_RUNTIME
/bin/mv "$finished_input" "$stage_dir/input.json"
staged_filters=(value.pair_refs.stage_request_ref value.pair_refs.resolved_profile_ref
  value.decision_texts.finish value.decision_texts.verify
  value.decision_texts.output_contract value.decision_texts.policy)
staged_forms=(json json raw raw raw raw)
staged_names=(stage-request-ref.json resolved-profile-ref.json finish-condition.txt
  verification-instructions.txt output-contract-decision.txt policy-decision.txt)
staged_index=0
while [ "$staged_index" -lt 6 ]; do
  name=${staged_names[$staged_index]}
  if [ "${staged_forms[$staged_index]}" = raw ]; then
    "$jq_bin" -r ".${staged_filters[$staged_index]}" "$input_out" > "$stage_dir/$name.tmp"
  else
    "$jq_bin" -S -c ".${staged_filters[$staged_index]}" "$input_out" > "$stage_dir/$name.tmp"
  fi
  /bin/mv "$stage_dir/$name.tmp" "$stage_dir/$name"
  staged_index=$((staged_index + 1))
done

"$jq_bin" -L "$modules" -e --arg command validate-input -f "$protocol" \
  "$stage_dir/input.json" >/dev/null 2>&1 || emit_error E_RELATION

# Commit: each destination is appended to the trap's list on the line above
# its own mv, input.json last.
for name in stage-request-ref.json resolved-profile-ref.json \
  finish-condition.txt verification-instructions.txt \
  output-contract-decision.txt policy-decision.txt; do
  record_destination "$output_dir/$name"
  /bin/mv "$stage_dir/$name" "$output_dir/$name"
done
record_destination "$output_dir/input.json"
/bin/mv "$stage_dir/input.json" "$output_dir/input.json"
committed=yes
committed_destinations=""

exit 0
