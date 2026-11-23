#!/bin/bash
# Blocks employer-confidential terms and secrets from entering this public repo.
#
#   check-public.sh staged            the whole index (pre-commit hook)
#   check-public.sh message FILE      a commit message or other text
#   check-public.sh tree              the tree of HEAD
#   check-public.sh range BASE HEAD   the tree of HEAD; for each commit in BASE..HEAD
#                                     its paths and message; every blob BASE cannot reach
#   check-public.sh history           every commit on every ref; terms only
#
# Terms come from $YSTACK_BLOCKED_TERMS when it is set (CI), or else from
# $YSTACK_BLOCKED_TERMS_FILE (default ~/.config/ystack/blocked-terms.txt).
# One term per line, matched without case. A line that starts with # is skipped.
#
# The check reads Git objects, never the work tree. It copies every blob, path
# and message it covers into a scratch directory, then runs the term match and
# gitleaks over those copies. Output never holds a term, a matching line or a
# secret, because CI logs are public: a finding names a path (or its position
# when the path itself is sensitive), line numbers, and a commit.
#
# Exit 0: clean. Exit 1: findings. Exit 2: the check could not run completely.

set -uo pipefail
export LC_ALL=C

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
terms=$work/terms
scan=$work/scan
mkdir -p "$scan/blobs" "$scan/paths" "$scan/msgs" "$work/no-ignore" || exit 2
: > "$work/where"
path_count=0
found=0

setup_error() {
  echo "check-public: $1" >&2
  exit 2
}

finding() {
  echo "check-public: $1" >&2
  found=1
}

# Succeeds if FILE holds a term. A grep error stops the check.
holds_term() {
  grep -q -a -i -F -f "$terms" -- "$1"
  case $? in
    0) return 0 ;;
    1) return 1 ;;
    *) setup_error "the term match failed." ;;
  esac
}

load_terms() {
  local raw file term n=0
  if [ -n "${YSTACK_BLOCKED_TERMS+set}" ]; then
    raw=$YSTACK_BLOCKED_TERMS
  else
    file=${YSTACK_BLOCKED_TERMS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/ystack/blocked-terms.txt}
    [ -f "$file" ] || setup_error "no term list at $file. See AGENTS.md."
    raw=$(cat -- "$file") || setup_error "cannot read the term list."
  fi
  printf '%s\n' "$raw" > "$work/raw" || setup_error "cannot write the scratch copy."
  tr -d '\r' < "$work/raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' > "$work/trimmed" ||
    setup_error "cannot read the term list."
  grep -v -e '^$' -e '^#' "$work/trimmed" > "$terms"
  [ $? -le 1 ] || setup_error "cannot read the term list."
  [ -s "$terms" ] || setup_error "the term list is empty."
  while IFS= read -r term; do
    n=$((n + 1))
    [ "${#term}" -ge 3 ] || setup_error "term $n is shorter than 3 characters."
  done < "$terms"
}

# Copies one path into the scan, checks it for terms, and prints how to name it.
add_path() {
  local path=$1 position=$2 shown=$1
  path_count=$((path_count + 1))
  printf '%s' "$path" > "$scan/paths/$path_count" || setup_error "cannot write the scratch copy."
  if holds_term "$scan/paths/$path_count"; then
    shown=$position
    finding "a blocked term is in the path of $shown"
  elif [[ $path == *[$'\n\t']* ]]; then
    shown=$position
  fi
  printf '%s\t%s\n' "paths/$path_count" "$shown" >> "$work/where"
  REPLY=$shown
}

# Copies one blob into the scan, once. $3 says where the blob was first seen.
add_blob() {
  local mode=$1 id=$2 shown=$3
  [[ $id =~ ^[0-9a-f]{40,64}$ ]] || setup_error "unexpected object id."
  if [ "$mode" = 160000 ]; then
    finding "$shown is a submodule; this repo allows none"
    return
  fi
  [ -e "$scan/blobs/$id" ] && return
  git cat-file blob "$id" > "$scan/blobs/$id" || setup_error "cannot read the blob of $shown."
  printf '%s\t%s\n' "blobs/$id" "$shown" >> "$work/where"
}

# Adds every entry of a NUL-separated listing in FILE.
# $2: index of the object id in the entry's fields; $3 names the listing.
add_listing() {
  local listing=$1 id_field=$2 label=$3 suffix=$4 entry meta path i=0
  local -a fields
  while IFS= read -r -d '' entry; do
    i=$((i + 1))
    meta=${entry%%$'\t'*}
    path=${entry#*$'\t'}
    read -r -a fields <<< "$meta"
    add_path "$path" "entry $i of '$label'"
    add_blob "${fields[0]}" "${fields[$id_field]}" "$REPLY$suffix"
  done < "$listing"
}

add_commit_tree() {
  local sha=$1
  git ls-tree -r -z --full-tree "$sha" > "$work/listing" || setup_error "cannot list commit $sha."
  add_listing "$work/listing" 2 "git ls-tree -r $sha" " (commit $sha)"
}

# Checks every path of a commit for terms and gitlinks, with one grep per commit.
check_commit_paths() {
  local sha=$1 lines
  git ls-tree -r -z --full-tree "$sha" > "$work/listing" || setup_error "cannot list commit $sha."
  tr '\0' '\n' < "$work/listing" | cut -f2- > "$work/names" || setup_error "cannot list commit $sha."
  grep -n -a -i -F -f "$terms" -- "$work/names" | cut -d: -f1 | paste -sd, - > "$work/name-hits"
  [ "${PIPESTATUS[0]}" -le 1 ] || setup_error "the term match failed."
  lines=$(cat "$work/name-hits")
  [ -z "$lines" ] || finding "a blocked term is in a path of commit $sha (lines $lines of 'git ls-tree -r $sha')"
  tr '\0' '\n' < "$work/listing" | cut -d' ' -f1 > "$work/modes" || setup_error "cannot list commit $sha."
  if grep -q -x 160000 "$work/modes"; then
    finding "commit $sha has a submodule; this repo allows none"
  fi
}

# Adds each blob that BASE cannot reach, under the first path Git reports for it.
add_new_blobs() {
  local base=$1 head=$2 line id path i=0
  git rev-list --objects "$head" --not "$base" > "$work/objects" || setup_error "cannot list new objects."
  cut -d' ' -f1 "$work/objects" |
    git cat-file --batch-check='%(objectname) %(objecttype)' > "$work/types" ||
    setup_error "cannot read object types."
  awk 'NR == FNR { if ($2 == "blob") blob[$1] = 1; next } ($1 in blob)' \
    "$work/types" "$work/objects" > "$work/new-blobs" || setup_error "cannot list new blobs."
  while IFS= read -r line; do
    i=$((i + 1))
    id=${line%% *}
    path=${line#* }
    add_path "$path" "new object $i of '$base..$head'"
    add_blob 100644 "$id" "$REPLY (new in this range)"
  done < "$work/new-blobs"
}

add_message() {
  local sha=$1
  git log -1 --format=%B "$sha" > "$scan/msgs/$sha" || setup_error "cannot read commit $sha."
  printf '%s\t%s\n' "msgs/$sha" "the message of commit $sha" >> "$work/where"
}

where() {
  local shown
  shown=$(awk -F '\t' -v key="$1" '$1 == key { print $2; exit }' "$work/where") ||
    setup_error "cannot map a finding."
  printf '%s' "${shown:-an unnamed input}"
}

match_terms() {
  local file lines
  (cd "$scan" && grep -r -a -i -n -F -f "$terms" -- blobs msgs) > "$work/hits"
  [ $? -le 1 ] || setup_error "the term match failed."
  awk -F: '{ lines[$1] = lines[$1] (lines[$1] == "" ? "" : ",") $2 }
    END { for (f in lines) print f "\t" lines[f] }' "$work/hits" > "$work/hit-lines" ||
    setup_error "cannot sort the term matches."
  while IFS=$'\t' read -r file lines; do
    finding "a blocked term is in $(where "$file"), line $lines"
  done < "$work/hit-lines"
}

match_secrets() {
  local bin rc
  bin=$("$here/get-gitleaks.sh" --no-fetch) || exit 2
  (cd "$scan" && env -u GITLEAKS_CONFIG -u GITLEAKS_CONFIG_TOML "$bin" dir . \
    --no-banner --redact --ignore-gitleaks-allow --gitleaks-ignore-path "$work/no-ignore" \
    --exit-code 3 --report-format json --report-path "$work/leaks.json") > /dev/null 2>&1
  rc=$?
  case $rc in
    0) return ;;
    3) ;;
    *) setup_error "gitleaks could not run (exit $rc)." ;;
  esac
  jq -r '.[] | [((.File | capture("(?<k>(blobs|paths|msgs)/[^/]+)$") | .k) // "?"), (.StartLine | tostring),
    (.RuleID | if test("^[A-Za-z0-9_-]+$") then . else "unknown" end)] | @tsv' \
    "$work/leaks.json" > "$work/leak-lines" || setup_error "cannot read the gitleaks report."
  while IFS=$'\t' read -r file line rule; do
    [[ $line =~ ^[0-9]+$ ]] || line='?'
    finding "a secret ($rule) is in $(where "$file"), line $line"
  done < "$work/leak-lines"
}

check_history() {
  local pattern sha
  sed -e 's/[][\.^$*+?(){}|/]/\\&/g' "$terms" | paste -sd'|' - > "$work/pattern" ||
    setup_error "cannot build the history pattern."
  pattern=$(cat "$work/pattern")
  git log --all -i -G"$pattern" --format=%H > "$work/commits" || setup_error "git log failed."
  while IFS= read -r sha; do
    finding "commit $sha adds or removes a blocked term"
  done < "$work/commits"
  git rev-list --all > "$work/commits" || setup_error "git rev-list failed."
  while IFS= read -r sha; do
    git log -1 --format=%B "$sha" > "$work/message" || setup_error "cannot read commit $sha."
    holds_term "$work/message" && finding "a blocked term is in the message of commit $sha"
  done < "$work/commits"
}

mode=${1:-}
case $mode in
  staged | tree | history) [ $# -eq 1 ] || setup_error "usage: $mode takes no arguments." ;;
  message)
    [ $# -eq 2 ] || setup_error "usage: message FILE"
    cp -- "$2" "$work/message" 2>/dev/null || setup_error "cannot read $2."
    ;;
  range) [ $# -eq 3 ] || setup_error "usage: range BASE HEAD" ;;
  *) setup_error "usage: check-public.sh staged|message FILE|tree|range BASE HEAD|history" ;;
esac
cd "$(git rev-parse --show-toplevel)" 2>/dev/null || setup_error "not inside a Git work tree."
load_terms

case $mode in
  staged)
    git ls-files -s -z > "$work/listing" || setup_error "cannot list the index."
    add_listing "$work/listing" 1 "git ls-files -s" ""
    ;;
  message)
    cp "$work/message" "$scan/msgs/text" || setup_error "cannot write the scratch copy."
    printf '%s\t%s\n' "msgs/text" "the message text" >> "$work/where"
    ;;
  tree)
    add_commit_tree HEAD
    ;;
  range)
    git rev-list "$2..$3" > "$work/commits" || setup_error "cannot list $2..$3."
    while IFS= read -r sha; do
      check_commit_paths "$sha"
      add_message "$sha"
    done < "$work/commits"
    add_commit_tree "$3"
    add_new_blobs "$2" "$3"
    ;;
  history)
    check_history
    ;;
esac

if [ "$mode" != history ]; then
  match_terms
  match_secrets
fi
if [ "$found" -ne 0 ]; then
  echo "check-public: blocked. Remove each finding above." >&2
  exit 1
fi
echo "check-public: $mode clean."
