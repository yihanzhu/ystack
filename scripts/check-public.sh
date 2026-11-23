#!/bin/bash
# Blocks employer-confidential terms and secrets from entering this public repo.
#
#   check-public.sh staged            staged files and paths (pre-commit hook)
#   check-public.sh message FILE      a commit message or other text
#   check-public.sh tree              every tracked file and path
#   check-public.sh range BASE HEAD   each commit in BASE..HEAD
#   check-public.sh history           every commit on every ref; terms only
#
# Terms come from $YSTACK_BLOCKED_TERMS when it is set (CI), or else from
# $YSTACK_BLOCKED_TERMS_FILE (default ~/.config/ystack/blocked-terms.txt).
# One term per line, matched without case. A line that starts with # is skipped.
#
# The output never holds a term or a matching line, because CI logs are public.
# A finding names only a file and line numbers, a commit, or a path's position.
#
# Exit 0: clean. Exit 1: findings. Exit 2: the check could not run.

set -uo pipefail
export LC_ALL=C

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
terms=$work/terms
found=0

setup_error() {
  echo "check-public: $1" >&2
  exit 2
}

finding() {
  echo "check-public: $1" >&2
  found=1
}

has_term() {
  grep -q -i -F -f "$terms"
}

term_lines() {
  grep -I -i -n -F -f "$terms" -- "$1" | cut -d: -f1 | paste -sd, -
}

load_terms() {
  local raw file term n=0
  if [ -n "${YSTACK_BLOCKED_TERMS+set}" ]; then
    raw=$YSTACK_BLOCKED_TERMS
  else
    file=${YSTACK_BLOCKED_TERMS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/ystack/blocked-terms.txt}
    [ -f "$file" ] || setup_error "no term list at $file. See AGENTS.md."
    raw=$(cat -- "$file")
  fi
  printf '%s\n' "$raw" | tr -d '\r' |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
    grep -v -e '^$' -e '^#' > "$terms"
  [ -s "$terms" ] || setup_error "the term list is empty."
  while IFS= read -r term; do
    n=$((n + 1))
    [ "${#term}" -ge 3 ] || setup_error "term $n is shorter than 3 characters."
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
      printf '::add-mask::%s\n' "$term"
    fi
  done < "$terms"
}

# Reads NUL-separated paths. $1 is "staged" or "tree"; $2 names the path list.
scan_files() {
  local mode=$1 list=$2 path name src lines i=0
  while IFS= read -r -d '' path; do
    i=$((i + 1))
    name=$path
    if printf '%s\n' "$path" | has_term; then
      name="entry $i of '$list'"
      finding "a blocked term is in the path of $name"
    fi
    if [ "$mode" = staged ]; then
      git show ":$path" > "$work/blob" 2>/dev/null || continue
      src=$work/blob
    else
      [ -f "$path" ] && [ ! -L "$path" ] || continue
      src=$path
    fi
    lines=$(term_lines "$src")
    [ -z "$lines" ] || finding "a blocked term is in $name, line $lines"
  done
}

gitleaks_scan() {
  local bin rc
  bin=$("$here/get-gitleaks.sh" --no-fetch) || exit 2
  "$bin" "$@" --no-banner --redact --exit-code 3 \
    --report-format json --report-path "$work/leaks.json" > "$work/leaks.log" 2>&1
  rc=$?
  case $rc in
    0) ;;
    3)
      jq -r '.[] | "check-public: secret (\(.RuleID)) in \(.File):\(.StartLine)" +
        (if .Commit != "" then " of commit \(.Commit)" else "" end)' "$work/leaks.json" >&2
      found=1
      ;;
    *)
      cat "$work/leaks.log" >&2
      setup_error "gitleaks could not run (exit $rc)."
      ;;
  esac
}

check_staged() {
  scan_files staged 'git diff --cached --name-only' \
    < <(git diff --cached --name-only -z --diff-filter=ACMR)
  gitleaks_scan git --pre-commit --staged .
}

check_message() {
  local file=$1 lines
  lines=$(term_lines "$file")
  [ -z "$lines" ] || finding "a blocked term is in the message text, line $lines"
  gitleaks_scan stdin < "$file"
}

check_tree() {
  scan_files tree 'git ls-files' < <(git ls-files -z)
  gitleaks_scan dir .
}

check_range() {
  local base=$1 head=$2 sha
  for sha in $(git rev-list "$base..$head") ; do
    if git log -1 --format=%B "$sha" | has_term; then
      finding "a blocked term is in the message of commit $sha"
    fi
    if git show --format= --no-color --unified=0 "$sha" | grep '^+' | has_term; then
      finding "commit $sha adds a blocked term"
    fi
  done
  gitleaks_scan git --log-opts="$base..$head" .
}

check_history() {
  local pattern sha
  pattern=$(sed -e 's/[][\.^$*+?(){}|/]/\\&/g' "$terms" | paste -sd'|' -)
  while IFS= read -r sha; do
    finding "commit $sha adds or removes a blocked term"
  done < <(git log --all -i -G"$pattern" --format=%H)
  while IFS= read -r sha; do
    git log -1 --format=%B "$sha" | has_term &&
      finding "a blocked term is in the message of commit $sha"
  done < <(git rev-list --all)
}

mode=${1:-}
case $mode in
  staged | tree | history) [ $# -eq 1 ] || setup_error "usage: $mode takes no arguments." ;;
  message)
    [ $# -eq 2 ] || setup_error "usage: message FILE"
    [ -f "$2" ] || setup_error "no text file at $2."
    set -- "$1" "$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
    ;;
  range) [ $# -eq 3 ] || setup_error "usage: range BASE HEAD" ;;
  *) setup_error "usage: check-public.sh staged|message FILE|tree|range BASE HEAD|history" ;;
esac
cd "$(git rev-parse --show-toplevel)" 2>/dev/null || setup_error "not inside a Git work tree."
load_terms
case $mode in
  staged) check_staged ;;
  message) check_message "$2" ;;
  tree) check_tree ;;
  range) check_range "$2" "$3" ;;
  history) check_history ;;
esac
if [ "$found" -ne 0 ]; then
  echo "check-public: blocked. Remove each finding above." >&2
  exit 1
fi
echo "check-public: $mode clean."
