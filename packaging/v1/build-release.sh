#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PATH|E_PROFILE|E_RELATION) /usr/bin/printf '%s\n' "$1" >&2 ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

# A packaged path is refused unless it is one of the four shipped product shapes.
# The denylist is the readable statement of the same rule: personal configuration,
# the operator's harness directory, the manager persona, and the prompts a target
# writes for itself are never packaged.
packaged_path_ok() {
  local candidate=$1
  case "$candidate" in
    config/*|.claude/*|manager/*|work/*|.github/*|website/*|templates/*|\
    routines/*|reviewer/*|proposals/*|docs/*|evals/*|control/*) return 1 ;;
  esac
  case "$candidate" in
    ''|/*|.*|*/|*//*|*/.*|*..*|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  [ "${#candidate}" -le 160 ] || return 1
  case "$candidate" in
    profiles/*/v1/*|adapters/*/v1/*|core/v2/generations/g-*/*|scripts/core-contract.sh) ;;
    *) return 1 ;;
  esac
}

[ "$#" -ge 3 ] && [ "$#" -le 6 ] && [ "$1" = build-release ] || emit_error E_USAGE
shift
commit=$1
shift
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || emit_error E_USAGE
for requested in "$@"; do
  [[ "$requested" =~ ^profile\.[a-z0-9][a-z0-9-]{0,30}\.v1$ ]] || emit_error E_USAGE
done

self=${BASH_SOURCE[0]}
case "$self" in /*) ;; *) self="$(pwd -P)/$self" ;; esac
self_dir=$(CDPATH='' cd -P -- "${self%/*}" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
self="$self_dir/${self##*/}"
[ "$self" = "$self_dir/build-release.sh" ] || emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$self_dir/../.." 2>/dev/null && pwd -P) || emit_error E_RUNTIME
[ "$self_dir" = "$repo/packaging/v1" ] || emit_error E_RUNTIME
program="$self_dir/packaging.jq"
for required in "$self" "$program"; do
  [ -f "$required" ] && [ ! -L "$required" ] || emit_error E_RUNTIME
done

jq_bin=$(command -v jq 2>/dev/null) || emit_error E_RUNTIME
case "$jq_bin" in /*) ;; *) emit_error E_RUNTIME ;; esac
[ -f "$jq_bin" ] && [ -x "$jq_bin" ] && [ ! -L "$jq_bin" ] &&
  [ "$($jq_bin --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME

# Reads must see the exact objects of the commit: no refs/replace substitution
# and no lazy fetch of promised objects from a partial clone.
repo_git() {
  GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 \
    GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 \
    /usr/bin/git --no-replace-objects -C "$repo" -c core.askPass= -c credential.helper= "$@"
}
[ "$(repo_git rev-parse --show-toplevel 2>/dev/null)" = "$repo" ] || emit_error E_RUNTIME
[ "$(repo_git rev-parse --verify --quiet "$commit^{commit}" 2>/dev/null)" = "$commit" ] ||
  emit_error E_RELATION

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-release.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM

blob_at() {
  local path=$1 size
  size=$(repo_git cat-file -s "$commit:$path" 2>/dev/null) || return 1
  [[ "$size" =~ ^[0-9]{1,7}$ ]] && [ "$size" -le 1048576 ] || return 1
  repo_git cat-file blob "$commit:$path" >"$scratch/blob" 2>/dev/null || return 1
  [ "$(/usr/bin/wc -c <"$scratch/blob" | /usr/bin/tr -d ' ')" -eq "$size" ] || return 1
}

# The core generation is read out of the packaged validator at the exact release
# commit, never hardcoded here, so a generation bump cannot silently drift.
blob_at scripts/core-contract.sh || emit_error E_RELATION
# Documents are validated with the contract validator AS COMMITTED at the release
# commit, never the checkout's working copy: the release must read one exact
# commit even when the checkout has local edits or is at another commit.
committed="$scratch/committed"
/bin/mkdir -m 0700 "$committed" || emit_error E_RUNTIME
repo_git archive --format=tar "$commit" scripts/core-contract.sh core/v2 2>/dev/null |
  /usr/bin/tar -x -C "$committed" 2>/dev/null || emit_error E_RELATION
[ -f "$committed/scripts/core-contract.sh" ] && [ ! -L "$committed/scripts/core-contract.sh" ] ||
  emit_error E_RELATION
/bin/chmod 0500 "$committed/scripts/core-contract.sh" || emit_error E_RUNTIME
committed_validator="$committed/scripts/core-contract.sh"
generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" "$scratch/blob")
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || emit_error E_RELATION

: >"$scratch/paths"
: >"$scratch/profiles.tsv"
: >"$scratch/files.tsv"
packaging_jq() {
  local operation=$1
  shift
  "$jq_bin" --arg operation "$operation" --arg commit "$commit" \
    --arg generation "$generation" --arg profile_id '' --arg release_id '' \
    --arg body_sha "${body_sha:-}" --arg manifest_sha '' --arg north_star_sha '' \
    --rawfile files "$scratch/files.tsv" --rawfile profiles "$scratch/profiles.tsv" \
    -f "$program" "$@"
}
record_path() {
  packaged_path_ok "$1" || emit_error E_PATH
  /usr/bin/printf '%s\n' "$1" >>"$scratch/paths" || emit_error E_RUNTIME
  /usr/bin/printf '%s\t%s\n' "$2" "$1" >>"$scratch/profiles.tsv" || emit_error E_RUNTIME
}
record_tree() {
  local profile_id=$1 path=$2 line entry seen=0
  while IFS= read -r line; do
    entry=${line#*$'\t'}
    [ "$entry" != "$line" ] || emit_error E_RELATION
    record_path "$entry" "$profile_id"
    seen=$((seen + 1))
  done < <(repo_git ls-tree -r -z --full-tree "$commit" -- "$path" | /usr/bin/tr '\0' '\n')
  [ "$seen" -ge 1 ] || emit_error E_RELATION
  RECORD_TREE_COUNT=$seen
}

for requested in "$@"; do
  name=${requested#profile.}
  name=${name%.v1}
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || emit_error E_USAGE
  base="profiles/$name/v1"
  blob_at "$base/profile.json" || emit_error E_PROFILE
  /bin/cp "$scratch/blob" "$scratch/profile.json" || emit_error E_RUNTIME
  "$jq_bin" -e --arg id "$requested" '.id == $id and (.body.bindings | length) == 6' \
    "$scratch/profile.json" >/dev/null 2>&1 || emit_error E_PROFILE
  # The profile must be a valid core document with six complete bindings before
  # anything is derived from it; a binding without a package ref would otherwise
  # simply emit no row and the release would ship without that adapter.
  "$jq_bin" -e '
    [.body.bindings[] | .role] == (["ci","forge","producer","publisher","reviewer","verifier"] | sort) or
    ([.body.bindings[] | .role] | sort) == ["ci","forge","producer","publisher","reviewer","verifier"]
  ' "$scratch/profile.json" >/dev/null 2>&1 || emit_error E_PROFILE
  "$jq_bin" -e '
    all(.body.bindings[];
      (.manifest_ref | type == "object" and (.id | type) == "string" and (.sha256 | type) == "string") and
      (.package_ref | type == "object" and (.object_type | type) == "string" and
        (.object_id | type) == "string" and (.mode | type) == "string" and
        (.location | type == "object" and (.kind | type) == "string")))
  ' "$scratch/profile.json" >/dev/null 2>&1 || emit_error E_PROFILE
  "$committed_validator" validate-document "$scratch/profile.json" >/dev/null 2>&1 ||
    emit_error E_PROFILE
  record_path "$base/profile.json" "$requested"
  config_path=$("$jq_bin" -r '
    [.body.bindings[] | select(has("config_ref")) | .config_ref.location.value] |
    if length == 1 then .[0] else "" end' "$scratch/profile.json" 2>/dev/null)
  [ "$config_path" = "$base/producer-config.json" ] || emit_error E_PROFILE
  record_path "$config_path" "$requested"
  record_tree "$requested" "$base/manifests"
  [ "$RECORD_TREE_COUNT" -eq 6 ] || emit_error E_PROFILE
  # Each manifest file at the commit must be the exact document the profile's
  # binding pins by id and digest; a manifest edited after the profile was
  # assembled is a stale profile, not something to package.
  : >"$scratch/manifests-found.tsv"
  while IFS= read -r line; do
    manifest_path=${line#*$'\t'}
    blob_at "$manifest_path" || emit_error E_LIMIT
    manifest_id=$("$jq_bin" -r 'if type == "object" and (.id | type) == "string" then .id else empty end' \
      "$scratch/blob" 2>/dev/null)
    [ -n "$manifest_id" ] || emit_error E_RELATION
    # Each manifest must be a valid core document, and the package it offers
    # must be the very object the profile's binding for that manifest packages;
    # a profile re-pinned to an edited manifest that points elsewhere is stale.
    /bin/cp "$scratch/blob" "$scratch/manifest.json" || emit_error E_RUNTIME
    "$committed_validator" validate-document "$scratch/manifest.json" >/dev/null 2>&1 ||
      emit_error E_PROFILE
    "$jq_bin" -e --arg id "$manifest_id" --slurpfile manifest "$scratch/manifest.json" '
      [.body.bindings[] | select(.manifest_ref.id == $id)] as $bound |
      ($bound | length) == 1 and $bound[0].package_ref == $manifest[0].body.package_ref
    ' "$scratch/profile.json" >/dev/null 2>&1 || emit_error E_RELATION
    /usr/bin/printf '%s\t%s\n' "$manifest_id" "$(sha_file "$scratch/blob")" \
      >>"$scratch/manifests-found.tsv"
  done < <(repo_git ls-tree -r -z --full-tree "$commit" -- "$base/manifests" | /usr/bin/tr '\0' '\n')
  "$jq_bin" -r '.body.bindings[] | .manifest_ref | [.id, .sha256] | @tsv' \
    "$scratch/profile.json" 2>/dev/null | /usr/bin/sort >"$scratch/manifests-pinned.tsv" ||
    emit_error E_RUNTIME
  /usr/bin/sort "$scratch/manifests-found.tsv" >"$scratch/manifests-found.sorted" || emit_error E_RUNTIME
  /usr/bin/cmp -s "$scratch/manifests-pinned.tsv" "$scratch/manifests-found.sorted" ||
    emit_error E_RELATION
  # Package the exact Git object the profile binds, not whatever sits at the
  # path in this commit: a drifted adapter, config, or prompt is a stale profile.
  # Every ref must still resolve to the object the profile pins (config and
  # prompt refs included); only package refs are packaged, the config is
  # recorded above and prompts are deliberately not shipped.
  while IFS=$'\t' read -r ref_role ref_loc ref_kind ref_path ref_oid ref_mode; do
    # Only a path location can be packaged; a root or unknown location is not
    # skipped, it makes the profile unpackageable.
    [ "$ref_loc" = path ] || emit_error E_RELATION
    if [ "$ref_role" = package_ref ]; then
      # A tree is judged by where its entries would land.
      case "$ref_kind" in
        blob) packaged_path_ok "$ref_path" || emit_error E_PATH ;;
        tree) packaged_path_ok "$ref_path/entry" || emit_error E_PATH ;;
      esac
    fi
    [ "$(repo_git rev-parse --verify --quiet "$commit:$ref_path" 2>/dev/null)" = "$ref_oid" ] ||
      emit_error E_RELATION
    if [ "$ref_kind" = blob ]; then
      [ "$(repo_git ls-tree --full-tree "$commit" -- "$ref_path" 2>/dev/null |
           /usr/bin/cut -d' ' -f1)" = "$ref_mode" ] || emit_error E_RELATION
    fi
    [ "$ref_role" = package_ref ] || continue
    case "$ref_kind" in
      blob) record_path "$ref_path" "$requested" ;;
      tree) record_tree "$requested" "$ref_path" ;;
      *) emit_error E_RELATION ;;
    esac
  done < <("$jq_bin" -r '.body.bindings[] |
    to_entries[] | select(.key == "package_ref" or .key == "config_ref" or .key == "prompt_ref") |
    [.key, (.value.location.kind // "missing"), .value.object_type,
     (.value.location.value // ""), .value.object_id, .value.mode] | @tsv' \
    "$scratch/profile.json" 2>/dev/null)
  # The core files a profile carries are named once, in packaging.jq, so the
  # installer's derived check reads the same list this loop packages.
  core_seen=0
  while IFS= read -r core_path; do
    record_path "$core_path" "$requested"
    core_seen=$((core_seen + 1))
  done < <(packaging_jq core-paths -r -n 2>/dev/null)
  [ "$core_seen" -eq 8 ] || emit_error E_RELATION
done

/usr/bin/sort -u "$scratch/paths" >"$scratch/paths.sorted" || emit_error E_RUNTIME
file_count=$(/usr/bin/wc -l <"$scratch/paths.sorted" | /usr/bin/tr -d ' ')
[ "$file_count" -ge 1 ] && [ "$file_count" -le 128 ] || emit_error E_LIMIT
: >"$scratch/files.tsv"
total_bytes=0
while IFS= read -r path; do
  packaged_path_ok "$path" || emit_error E_PATH
  record=$(repo_git ls-tree -z --full-tree "$commit" -- "$path" | /usr/bin/tr -d '\0')
  mode=${record%% *}
  rest=${record#* }
  kind=${rest%% *}
  oid=${rest#* }
  oid=${oid%%$'\t'*}
  [ "$kind" = blob ] || emit_error E_RELATION
  case "$mode" in 100644|100755) ;; *) emit_error E_RELATION ;; esac
  [[ "$oid" =~ ^[0-9a-f]{40}$ ]] || emit_error E_RELATION
  blob_at "$path" || emit_error E_LIMIT
  total_bytes=$((total_bytes + $(/usr/bin/wc -c <"$scratch/blob" | /usr/bin/tr -d ' ')))
  [ "$total_bytes" -le 8388608 ] || emit_error E_LIMIT
  /usr/bin/printf '%s\t%s\t%s\t%s\n' "$path" "$mode" "$oid" "$(sha_file "$scratch/blob")" \
    >>"$scratch/files.tsv" || emit_error E_RUNTIME
done <"$scratch/paths.sorted"

packaging_jq release -S -c -n >"$scratch/body.json" 2>/dev/null || emit_error E_RELATION
body_sha=$(sha_file "$scratch/body.json")
release_id="release.$body_sha"
"$jq_bin" -S -c -n --arg id "$release_id" --slurpfile body "$scratch/body.json" \
  '{body: $body[0], id: $id, kind: "release_manifest", schema_version: 1}' \
  >"$scratch/manifest.json" 2>/dev/null || emit_error E_RUNTIME
"$jq_bin" -S -c . "$scratch/manifest.json" >"$scratch/manifest.canonical" 2>/dev/null ||
  emit_error E_RUNTIME
/usr/bin/cmp -s "$scratch/manifest.json" "$scratch/manifest.canonical" || emit_error E_RUNTIME
shape=$(packaging_jq manifest-shape -r "$scratch/manifest.json" 2>/dev/null) ||
  emit_error E_RUNTIME
[ -z "$shape" ] || emit_error E_RELATION
/bin/cat "$scratch/manifest.json" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
