#!/bin/bash
# Blocks employer-confidential terms and secrets from entering this public repo.
#
#   check-public.sh staged            the whole index (pre-commit hook)
#   check-public.sh message FILE      a commit message or other text
#   check-public.sh tree              the tree of HEAD
#   check-public.sh range BASE HEAD   the tree of HEAD; for each commit in BASE..HEAD
#                                     every path, each file it adds or changes against
#                                     any parent, its message and its author and committer
#   check-public.sh history           every commit on every ref; terms only
#
# Terms come from $YSTACK_BLOCKED_TERMS when it is set (CI), or else from
# $YSTACK_BLOCKED_TERMS_FILE (default ~/.config/ystack/blocked-terms.txt).
# One term per line, matched without case. A line that starts with # is skipped.
#
# The check reads Git objects, never the work tree. It copies each file it covers
# to files/N/PATH in a scratch directory, keeping the path so that gitleaks rules
# for named files still apply, and copies paths and messages as text. Then it runs
# the term match and gitleaks over the copies. Output never holds a term, a
# matching line, a secret or a path, because CI logs are public. A finding names
# an entry number in a Git listing, line numbers, and a commit.
#
# Exit 0: clean. Exit 1: findings. Exit 2: the check could not run completely.

set -uo pipefail
export LC_ALL=C

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
terms=$work/terms
scan=$work/scan
mkdir -p "$scan/files" "$scan/paths" "$scan/msgs" "$work/no-ignore" || exit 2
: > "$work/where" || exit 2
: > "$work/seen" || exit 2
entries=0
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
    [ -f "$file" ] || setup_error "no term list. See AGENTS.md."
    raw=$(cat -- "$file") || setup_error "cannot read the term list."
  fi
  printf '%s\n' "$raw" > "$work/raw" || setup_error "cannot write a scratch file."
  tr -d '\r' < "$work/raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' > "$work/trimmed" ||
    setup_error "cannot read the term list."
  grep -v -e '^$' -e '^#' "$work/trimmed" > "$terms"
  [ $? -le 1 ] || setup_error "cannot read the term list."
  [ -s "$terms" ] || setup_error "the term list is empty."
  exec 3< "$terms" || setup_error "cannot read a scratch file."
  while IFS= read -r -u 3 term; do
    n=$((n + 1))
    [ "${#term}" -ge 3 ] || setup_error "term $n is shorter than 3 characters."
  done
  exec 3<&-
}

# Adds one file of a Git listing to the scan. $1 mode, $2 object id, $3 path,
# $4 how to name the entry in public output.
add_entry() {
  local mode=$1 id=$2 path=$3 label=$4 dir key
  [[ $id =~ ^[0-9a-f]{40,64}$ ]] || setup_error "unexpected object id."
  if [ "$mode" = 160000 ]; then
    finding "$label is a submodule; this repo allows none"
    return
  fi
  # The path goes into the key as hex, so a newline in a path cannot split it.
  key=$(printf '%s' "$path" | od -An -v -tx1 | tr -d ' \n') || setup_error "cannot copy the path of $label."
  key="$id $key"
  grep -q -x -F -- "$key" "$work/seen" && return
  printf '%s\n' "$key" >> "$work/seen" || setup_error "cannot write a scratch file."
  entries=$((entries + 1))
  # Error messages from these writes could name the path, so they are dropped.
  { printf '%s' "$path" > "$scan/paths/$entries"; } 2> /dev/null ||
    setup_error "cannot copy the path of $label."
  printf '%s\t%s\n' "paths/$entries" "the path of $label" >> "$work/where"
  if holds_term "$scan/paths/$entries"; then
    finding "a blocked term is in the path of $label"
  fi
  dir=$scan/files/$entries
  { mkdir -p "$(dirname "$dir/$path")" && git cat-file blob "$id" > "$dir/$path"; } 2> /dev/null ||
    setup_error "cannot copy the blob of $label."
  printf '%s\t%s\n' "files/$entries" "$label" >> "$work/where"
}

# Adds every entry of a NUL-separated listing in FILE.
# $2: index of the object id among the entry's fields; $3 names the listing.
add_listing() {
  local listing=$1 id_field=$2 label=$3 entry meta path i=0
  local -a fields
  exec 4< "$listing" || setup_error "cannot read a scratch file."
  while IFS= read -r -d '' -u 4 entry; do
    i=$((i + 1))
    meta=${entry%%$'\t'*}
    path=${entry#*$'\t'}
    read -r -a fields <<< "$meta"
    add_entry "${fields[0]}" "${fields[$id_field]}" "$path" "entry $i of '$label'"
  done
  exec 4<&-
}

add_commit_tree() {
  local sha=$1
  git ls-tree -r -z --full-tree "$sha" > "$work/listing" || setup_error "cannot list commit $sha."
  add_listing "$work/listing" 2 "git ls-tree -r $sha"
}

# Checks every path of a commit for terms and submodules, with one grep per commit.
check_commit_paths() {
  local sha=$1 lines
  git ls-tree -r -z --full-tree "$sha" > "$work/listing" || setup_error "cannot list commit $sha."
  tr '\0' '\n' < "$work/listing" | cut -f2- > "$work/names" || setup_error "cannot list commit $sha."
  grep -n -a -i -F -f "$terms" -- "$work/names" > "$work/name-hits"
  case $? in
    0) found=1 ;;
    1) ;;
    *) setup_error "the term match failed." ;;
  esac
  lines=$(cut -d: -f1 "$work/name-hits" | paste -sd, -) || setup_error "cannot sort the term matches."
  [ -z "$lines" ] || finding "a blocked term is in a path of commit $sha (lines $lines of 'git ls-tree -r $sha')"
  tr '\0' '\n' < "$work/listing" | cut -d' ' -f1 > "$work/modes" || setup_error "cannot list commit $sha."
  if grep -q -x 160000 "$work/modes"; then
    finding "commit $sha has a submodule; this repo allows none"
  fi
}

# Adds each file that a commit adds or changes against any of its parents, so
# renames, merge results and short-lived files are covered.
add_commit_changes() {
  local sha=$1 meta path i=0
  local -a fields
  git diff-tree -r -z -m --root --no-commit-id --no-renames --diff-filter=AMT "$sha" \
    > "$work/changes" || setup_error "cannot diff commit $sha."
  exec 5< "$work/changes" || setup_error "cannot read a scratch file."
  while IFS= read -r -d '' -u 5 meta && IFS= read -r -d '' -u 5 path; do
    i=$((i + 1))
    read -r -a fields <<< "${meta#:}"
    add_entry "${fields[1]}" "${fields[3]}" "$path" "change $i of 'git diff-tree -r -m --root $sha'"
  done
  exec 5<&-
}

add_message() {
  local sha=$1
  git log -1 --format='%an <%ae>%n%cn <%ce>%n%n%B' "$sha" > "$scan/msgs/$sha" ||
    setup_error "cannot read commit $sha."
  printf '%s\t%s\n' "msgs/$sha" "the author, committer or message of commit $sha" >> "$work/where"
}

# Names a scanned file in public output. $1 is files/N, paths/N or msgs/NAME.
where() {
  local shown
  shown=$(awk -F '\t' -v key="$1" '$1 == key { print $2; exit }' "$work/where") ||
    setup_error "cannot map a finding."
  printf '%s' "${shown:-an unnamed input}"
}

# Names a scanned file by its first two path parts: files/N or msgs/NAME.
scan_key() {
  local rest=${1#*/}
  printf '%s/%s' "${1%%/*}" "${rest%%/*}"
}

match_terms() {
  local file lines
  (cd "$scan" && grep -r -l --null -a -i -F -f "$terms" -- files msgs) > "$work/hit-files" 2> /dev/null
  case $? in
    0) found=1 ;;
    1) ;;
    *) setup_error "the term match failed." ;;
  esac
  exec 6< "$work/hit-files" || setup_error "cannot read a scratch file."
  while IFS= read -r -d '' -u 6 file; do
    lines=$( (cd "$scan" && grep -n -a -i -F -f "$terms" -- "$file") 2> /dev/null |
      cut -d: -f1 | paste -sd, -)
    finding "a blocked term is in $(where "$(scan_key "$file")"), line ${lines:-?}"
  done
  exec 6<&-
}

match_secrets() {
  local bin rc rows key line rule
  bin=$("$here/get-gitleaks.sh" --no-fetch) || exit 2
  (cd "$scan" && env -u GITLEAKS_CONFIG -u GITLEAKS_CONFIG_TOML "$bin" dir . \
    --no-banner --redact --ignore-gitleaks-allow --gitleaks-ignore-path "$work/no-ignore" \
    --exit-code 3 --report-format json --report-path "$work/leaks.json") > /dev/null 2>&1
  rc=$?
  case $rc in
    0) return ;;
    3) found=1 ;;
    *) setup_error "gitleaks could not run (exit $rc)." ;;
  esac
  jq -r '.[] | [
      ((.File | capture("^(\\./)?(?<k>(files|paths)/[0-9]+|msgs/[0-9a-z]+)(/|$)") | .k) // "?"),
      (.StartLine | tostring),
      (.RuleID | if test("^[A-Za-z0-9_-]+$") then . else "unknown" end)
    ] | @tsv' "$work/leaks.json" > "$work/leak-lines" ||
    setup_error "gitleaks found a secret, but its report is unreadable."
  rows=$(wc -l < "$work/leak-lines") || setup_error "cannot read a scratch file."
  [ "$rows" -gt 0 ] || setup_error "gitleaks found a secret, but its report is empty."
  exec 6< "$work/leak-lines" || setup_error "cannot read a scratch file."
  while IFS=$'\t' read -r -u 6 key line rule; do
    [[ $line =~ ^[0-9]+$ ]] || line='?'
    finding "a secret ($rule) is in $(where "$key"), line $line"
  done
  exec 6<&-
}

check_history() {
  local pattern sha
  sed -e 's/[][\.^$*+?(){}|/]/\\&/g' "$terms" | paste -sd'|' - > "$work/pattern" ||
    setup_error "cannot build the history pattern."
  pattern=$(cat "$work/pattern") || setup_error "cannot read a scratch file."
  git log --all -i -G"$pattern" --format=%H > "$work/commits" || setup_error "git log failed."
  exec 7< "$work/commits" || setup_error "cannot read a scratch file."
  while IFS= read -r -u 7 sha; do
    finding "commit $sha adds or removes a blocked term"
  done
  exec 7<&-
  git rev-list --all > "$work/commits" || setup_error "git rev-list failed."
  exec 7< "$work/commits" || setup_error "cannot read a scratch file."
  while IFS= read -r -u 7 sha; do
    git log -1 --format='%an <%ae>%n%cn <%ce>%n%n%B' "$sha" > "$work/message" ||
      setup_error "cannot read commit $sha."
    holds_term "$work/message" &&
      finding "a blocked term is in the author, committer or message of commit $sha"
  done
  exec 7<&-
}

mode=${1:-}
case $mode in
  staged | tree | history) [ $# -eq 1 ] || setup_error "usage: $mode takes no arguments." ;;
  message)
    [ $# -eq 2 ] || setup_error "usage: message FILE"
    cp -- "$2" "$work/message" 2>/dev/null || setup_error "cannot read the message file."
    ;;
  range) [ $# -eq 3 ] || setup_error "usage: range BASE HEAD" ;;
  *) setup_error "usage: check-public.sh staged|message FILE|tree|range BASE HEAD|history" ;;
esac
cd "$(git rev-parse --show-toplevel)" 2>/dev/null || setup_error "not inside a Git work tree."
load_terms

case $mode in
  staged)
    git ls-files -s -z > "$work/listing" || setup_error "cannot list the index."
    add_listing "$work/listing" 1 "git ls-files -s"
    { git var GIT_AUTHOR_IDENT && git var GIT_COMMITTER_IDENT; } > "$scan/msgs/identity" 2> /dev/null ||
      setup_error "cannot read the Git identity."
    printf '%s\t%s\n' "msgs/identity" "the author or committer of the next commit" >> "$work/where"
    ;;
  message)
    cp "$work/message" "$scan/msgs/text" || setup_error "cannot write a scratch file."
    printf '%s\t%s\n' "msgs/text" "the message text" >> "$work/where"
    ;;
  tree)
    add_commit_tree HEAD
    ;;
  range)
    add_commit_tree "$3"
    git rev-list "$2..$3" > "$work/commits" || setup_error "cannot list $2..$3."
    exec 8< "$work/commits" || setup_error "cannot read a scratch file."
    while IFS= read -r -u 8 sha; do
      check_commit_paths "$sha"
      add_commit_changes "$sha"
      add_message "$sha"
    done
    exec 8<&-
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
