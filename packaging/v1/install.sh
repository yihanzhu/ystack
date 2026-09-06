#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|\
    E_PATH|E_PROFILE|E_TARGET|E_DIGEST|E_DENYLIST) /usr/bin/printf '%s\n' "$1" >&2 ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

physical_leaf() {
  local candidate=$1 parent name physical_parent
  case "$candidate" in /*) ;; *) candidate="$(pwd -P)/$candidate" ;; esac
  parent=${candidate%/*}
  name=${candidate##*/}
  [ -n "$name" ] || return 1
  physical_parent=$(CDPATH='' cd -P -- "$parent" 2>/dev/null && pwd -P) || return 1
  PHYSICAL_LEAF="$physical_parent/$name"
}

# Same closed shape list build-release.sh packages by; re-checked here so a
# hand-edited manifest cannot steer a write outside the product tree.
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

[ "$#" -eq 4 ] && [ "$1" = install ] || emit_error E_USAGE
manifest_input=$2
profile_id=$3
target_input=$4
[[ "$profile_id" =~ ^profile\.[a-z0-9][a-z0-9-]{0,30}\.v1$ ]] || emit_error E_USAGE

self=${BASH_SOURCE[0]}
case "$self" in /*) ;; *) self="$(pwd -P)/$self" ;; esac
self_dir=$(CDPATH='' cd -P -- "${self%/*}" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
self="$self_dir/${self##*/}"
[ "$self" = "$self_dir/install.sh" ] || emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$self_dir/../.." 2>/dev/null && pwd -P) || emit_error E_RUNTIME
[ "$self_dir" = "$repo/packaging/v1" ] || emit_error E_RUNTIME
program="$self_dir/packaging.jq"
# The release builder is the sibling this installer replays the manifest against.
builder="$self_dir/build-release.sh"
for required in "$self" "$program" "$builder"; do
  [ -f "$required" ] && [ ! -L "$required" ] || emit_error E_RUNTIME
done
[ -x "$builder" ] || emit_error E_RUNTIME

jq_bin=$(command -v jq 2>/dev/null) || emit_error E_RUNTIME
case "$jq_bin" in /*) ;; *) emit_error E_RUNTIME ;; esac
[ -f "$jq_bin" ] && [ -x "$jq_bin" ] && [ ! -L "$jq_bin" ] &&
  [ "$($jq_bin --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME

physical_leaf "$manifest_input" || emit_error E_RUNTIME
manifest_input=$PHYSICAL_LEAF
[ -f "$manifest_input" ] && [ ! -L "$manifest_input" ] || emit_error E_RUNTIME

# A target is refused unless it is an existing, empty, real directory outside this
# repo and outside the operator's home dotfiles. Installing never adopts an
# existing tree and never follows a symlink into one.
physical_leaf "$target_input" || emit_error E_TARGET
target=$PHYSICAL_LEAF
[ -d "$target" ] && [ ! -L "$target" ] || emit_error E_TARGET
[ "$(CDPATH='' cd -P -- "$target" 2>/dev/null && pwd -P)" = "$target" ] || emit_error E_TARGET
# Emptiness must be proven, not assumed: an unreadable directory makes ls fail
# with no output, which must not pass as empty.
[ -r "$target" ] || emit_error E_TARGET
target_listing=$(/bin/ls -A -- "$target" 2>/dev/null) || emit_error E_TARGET
[ -z "$target_listing" ] || emit_error E_TARGET
case "$target" in
  "$repo"|"$repo"/*) emit_error E_TARGET ;;
esac
case "$repo" in
  "$target"/*) emit_error E_TARGET ;;
esac
if [ -n "${HOME:-}" ]; then
  home_dir=$(CDPATH='' cd -P -- "$HOME" 2>/dev/null && pwd -P) || home_dir=''
  if [ -n "$home_dir" ]; then
    case "$target" in
      "$home_dir"|"$home_dir"/.*) emit_error E_TARGET ;;
    esac
  fi
fi

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-install.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM

raw="$scratch/manifest.json"
/bin/dd if="$manifest_input" of="$raw" bs=1048577 count=1 2>/dev/null || emit_error E_RUNTIME
[ "$(/usr/bin/wc -c <"$raw" | /usr/bin/tr -d ' ')" -le 1048576 ] || emit_error E_LIMIT
manifest_sha=$(sha_file "$raw")
[ "$(/usr/bin/od -An -tx1 -N3 "$raw" | /usr/bin/tr -d ' \n')" != efbbbf ] || emit_error E_PARSE
"$jq_bin" . "$raw" >/dev/null 2>&1 || emit_error E_PARSE
[ "$("$jq_bin" -s length "$raw" 2>/dev/null)" -eq 1 ] || emit_error E_PARSE
"$jq_bin" -S -c . "$raw" >"$scratch/canonical.json" 2>/dev/null || emit_error E_PARSE
/usr/bin/cmp -s "$raw" "$scratch/canonical.json" || emit_error E_CANONICAL

commit=$("$jq_bin" -r '.body.source.commit_id // ""' "$raw" 2>/dev/null)
generation=$("$jq_bin" -r '.body.core_contract.generation_id // ""' "$raw" 2>/dev/null)
release_id=$("$jq_bin" -r '.id // ""' "$raw" 2>/dev/null)
# The release id must be the SHA-256 of the canonical body, so the body is
# re-canonicalised here and hashed rather than read back out of the manifest.
"$jq_bin" -S -c '.body' "$raw" >"$scratch/body.json" 2>/dev/null || emit_error E_SHAPE
body_sha=$(sha_file "$scratch/body.json")
packaging_jq() {
  local operation=$1
  shift
  "$jq_bin" --arg operation "$operation" --arg commit "$commit" \
    --arg generation "$generation" --arg profile_id "$profile_id" \
    --arg release_id "$release_id" --arg body_sha "$body_sha" \
    --arg manifest_sha "$manifest_sha" --arg north_star_sha "${north_star_sha:-}" \
    --rawfile files "$scratch/installed.tsv" --rawfile profiles "$scratch/empty" \
    -f "$program" "$@"
}
: >"$scratch/installed.tsv"
: >"$scratch/empty"
shape=$(packaging_jq manifest-shape -r "$raw" 2>/dev/null) || emit_error E_RUNTIME
[ -z "$shape" ] || emit_error E_SHAPE

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
source_generation=$(repo_git cat-file blob "$commit:scripts/core-contract.sh" 2>/dev/null |
  /usr/bin/sed -n "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p")
[ "$source_generation" = "$generation" ] || emit_error E_RELATION

# The manifest is not merely checked, it is reproduced: the sibling builder rebuilds
# the release for the commit and profile ids the manifest itself names, and the
# supplied bytes must equal the rebuilt bytes. That one comparison settles the
# release id, every per-profile file list, every mode, object id, and digest, and
# the core generation at once, so a hand-edited manifest cannot install. The
# per-file checks below stay as defence in depth.
manifest_profiles=()
while IFS= read -r listed; do
  [[ "$listed" =~ ^profile\.[a-z0-9][a-z0-9-]{0,30}\.v1$ ]] || emit_error E_SHAPE
  manifest_profiles+=("$listed")
done < <("$jq_bin" -r '.body.profiles[].profile_id' "$raw" 2>/dev/null)
[ "${#manifest_profiles[@]}" -ge 1 ] && [ "${#manifest_profiles[@]}" -le 4 ] ||
  emit_error E_SHAPE
"$builder" build-release "$commit" "${manifest_profiles[@]}" >"$scratch/rebuilt.json" \
  2>/dev/null || emit_error E_DIGEST
/usr/bin/cmp -s "$raw" "$scratch/rebuilt.json" || emit_error E_DIGEST

packaging_jq profile-files -r "$raw" >"$scratch/wanted.tsv" 2>/dev/null ||
  emit_error E_PROFILE
[ -s "$scratch/wanted.tsv" ] || emit_error E_PROFILE

# Nothing is written into the target until every packaged blob has matched the
# manifest's Git object id and SHA-256 and passed the personal-data denylist.
denied_content='(/Users/|ghp_[A-Za-z0-9]{10}|github_pat_[A-Za-z0-9_]{10}|xox[abpr]-[A-Za-z0-9]{8}|sk-ant-|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]+PRIVATE KEY|ystack-shipped-default)'
staged="$scratch/stage"
/bin/mkdir -p "$staged" || emit_error E_RUNTIME
while IFS=$'\t' read -r path mode object_id sha256; do
  packaged_path_ok "$path" || emit_error E_PATH
  case "$mode" in 100644|100755) ;; *) emit_error E_SHAPE ;; esac
  [ "$(repo_git rev-parse --verify --quiet "$commit:$path" 2>/dev/null)" = "$object_id" ] ||
    emit_error E_DIGEST
  # The mode is part of the packaged identity: a manifest may not turn a data
  # file into an executable while keeping the same blob.
  [ "$(repo_git ls-tree "$commit" -- "$path" 2>/dev/null | /usr/bin/cut -d' ' -f1)" = "$mode" ] ||
    emit_error E_DIGEST
  size=$(repo_git cat-file -s "$object_id" 2>/dev/null) || emit_error E_DIGEST
  [[ "$size" =~ ^[0-9]{1,7}$ ]] && [ "$size" -le 1048576 ] || emit_error E_LIMIT
  /bin/mkdir -p "$staged/${path%/*}" || emit_error E_RUNTIME
  repo_git cat-file blob "$object_id" >"$staged/$path" 2>/dev/null || emit_error E_DIGEST
  [ "$(sha_file "$staged/$path")" = "$sha256" ] || emit_error E_DIGEST
  ! /usr/bin/grep -aqE "$denied_content" "$staged/$path" || emit_error E_DENYLIST
  case "$mode" in
    100755) /bin/chmod 0500 "$staged/$path" || emit_error E_RUNTIME ;;
    *) /bin/chmod 0400 "$staged/$path" || emit_error E_RUNTIME ;;
  esac
  /usr/bin/printf '%s\t%s\t%s\n' "$path" "$mode" "$sha256" >>"$scratch/installed.tsv" ||
    emit_error E_RUNTIME
done <"$scratch/wanted.tsv"

/bin/cat >"$staged/north-star.md" <<'PLACEHOLDER'
# North star

This file belongs to this target. The ystack installer wrote a placeholder and
nothing else: no goal, no approval record, and no marker carried over from the
control plane. Nothing here authorizes proactive work.

Replace the entry below with your own goal and commit it. Until you do, and until
you approve it yourself, this target has no north star for any tool to debate a
proposal against.

## Current north star

### Placeholder - replace with your own goal - status: **unset**

Describe the single outcome this project is steering toward right now. A good north
star is concrete enough that a reviewer can judge whether a proposal serves it.

- **Why it's the north star:**
- **Done-signal:**

## North-star log

- **Placeholder** - *unset; write your own north star here and commit it.*
PLACEHOLDER
/bin/chmod 0600 "$staged/north-star.md" || emit_error E_RUNTIME
north_star_sha=$(sha_file "$staged/north-star.md")
packaging_jq install-record -S -c -n >"$scratch/record-body.json" 2>/dev/null ||
  emit_error E_RELATION
record_id="install.$(sha_file "$scratch/record-body.json")"
"$jq_bin" -S -c -n --arg id "$record_id" --slurpfile body "$scratch/record-body.json" \
  '{body: $body[0], id: $id, kind: "install_record", schema_version: 1}' \
  >"$staged/install-record.json" 2>/dev/null || emit_error E_RUNTIME
"$jq_bin" -S -c . "$staged/install-record.json" >"$scratch/record.canonical" 2>/dev/null ||
  emit_error E_RUNTIME
/usr/bin/cmp -s "$staged/install-record.json" "$scratch/record.canonical" ||
  emit_error E_RUNTIME
/bin/chmod 0400 "$staged/install-record.json" || emit_error E_RUNTIME
[ "$(sha_file "$manifest_input")" = "$manifest_sha" ] || emit_error E_RELATION

root="$target/.ystack"
/bin/mkdir -m 0700 "$root" || emit_error E_TARGET
while IFS= read -r staged_path; do
  relative=${staged_path#"$staged"/}
  case "$relative" in */*) /bin/mkdir -p "$root/${relative%/*}" || emit_error E_RUNTIME ;; esac
  /bin/cp -p "$staged_path" "$root/$relative" || emit_error E_RUNTIME
done < <(/usr/bin/find "$staged" -type f | /usr/bin/sort)
/usr/bin/printf '%s\n' "$record_id"
trap - EXIT HUP INT TERM
cleanup
