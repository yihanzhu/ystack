#!/bin/bash
# Checks scripts/check-public.sh against a scratch repository with fake terms.
# Needs the pinned gitleaks: run scripts/get-gitleaks.sh first.
set -u
export LC_ALL=C

check="$(git rev-parse --show-toplevel)/scripts/check-public.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
failures=0

fake_terms=$'# fake terms for this test\nZebraquill\nmoonfjord'
printf '%s\n' zebraquill moonfjord > "$scratch/terms-to-hide"
fake_token="ghp_$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 36)"
printf '%s\n' "$fake_token" >> "$scratch/terms-to-hide"

# Runs check-public.sh in the scratch repo. $1 name, $2 wanted exit, $3 text the
# output must hold ("" for none), then the check's arguments.
expect() {
  local name=$1 want=$2 needle=$3 out got
  shift 3
  out=$(cd "$scratch/repo" && env -u GITHUB_ACTIONS "$check" "$@" 2>&1)
  got=$?
  if [ "$got" -ne "$want" ]; then
    echo "not ok - $name: exit $got, want $want"
    printf '%s\n' "$out" | sed 's/^/#   /' | grep -v -i -F -f "$scratch/terms-to-hide"
    failures=$((failures + 1))
  elif printf '%s\n' "$out" | grep -q -i -F -f "$scratch/terms-to-hide"; then
    echo "not ok - $name: the output shows a term or the token"
    failures=$((failures + 1))
  elif [ -n "$needle" ] && ! printf '%s\n' "$out" | grep -q -F -- "$needle"; then
    echo "not ok - $name: the output lacks '$needle'"
    failures=$((failures + 1))
  else
    echo "ok - $name"
  fi
}

commit_all() {
  git -C "$scratch/repo" add -A
  git -C "$scratch/repo" -c core.hooksPath=/dev/null commit -q -m "$1"
}

git init -q "$scratch/repo"
git -C "$scratch/repo" config user.name test
git -C "$scratch/repo" config user.email test@example.invalid
printf 'plain text\n' > "$scratch/repo/readme.txt"
commit_all 'first commit'
base=$(git -C "$scratch/repo" rev-parse HEAD)

export YSTACK_BLOCKED_TERMS_FILE="$scratch/no-such-file"
unset YSTACK_BLOCKED_TERMS
expect 'missing term list' 2 'no term list' tree
YSTACK_BLOCKED_TERMS='' expect 'empty term list' 2 'is empty' tree
YSTACK_BLOCKED_TERMS=$'ab\nmoonfjord' expect 'too-short term' 2 'term 1 is shorter' tree
printf '%s\n' "$fake_terms" > "$scratch/terms.txt"
YSTACK_BLOCKED_TERMS_FILE="$scratch/terms.txt" expect 'term list from a file' 0 'tree clean' tree

export YSTACK_BLOCKED_TERMS="$fake_terms"
expect 'clean tree' 0 'tree clean' tree
expect 'clean range' 0 'range clean' range "$base" HEAD

printf 'one\nNotes about ZEBRAQUILL here\n' > "$scratch/repo/notes.txt"
commit_all 'add notes'
expect 'term in a file, other case' 1 'notes.txt, line 2' tree
expect 'term added in a commit' 1 'adds a blocked term' range "$base" HEAD
git -C "$scratch/repo" rm -q notes.txt
commit_all 'remove notes'
expect 'term removed again: tree' 0 'tree clean' tree
expect 'term in history' 1 'adds or removes a blocked term' history

mkdir -p "$scratch/repo/moonfjord-docs"
printf 'clean\n' > "$scratch/repo/moonfjord-docs/a.txt"
git -C "$scratch/repo" add -A
expect 'term in a staged path' 1 "entry 1 of 'git diff --cached --name-only'" staged
commit_all 'add docs'
expect 'term in a tracked path' 1 "of 'git ls-files'" tree
git -C "$scratch/repo" rm -q -r moonfjord-docs
commit_all 'remove docs'

printf 'clean\n' > "$scratch/repo/b.txt"
git -C "$scratch/repo" add b.txt
commit_all 'mention moonfjord in a message'
expect 'term in a commit message' 1 'in the message of commit' range "$base" HEAD

printf 'Subject\n\nBody with zebraquill\n' > "$scratch/message.txt"
expect 'term in message text' 1 'message text, line 3' message "$scratch/message.txt"
printf 'Subject\n\nA clean body\n' > "$scratch/message.txt"
expect 'clean message text' 0 'message clean' message "$scratch/message.txt"

printf 'token = "%s"\n' "$fake_token" > "$scratch/repo/config.txt"
git -C "$scratch/repo" add config.txt
expect 'secret in a staged file' 1 'secret (github-pat)' staged
commit_all 'add config'
expect 'secret in the tree' 1 'config.txt:1' tree
printf 'Subject\n\ntoken %s\n' "$fake_token" > "$scratch/message.txt"
expect 'secret in message text' 1 'secret (github-pat)' message "$scratch/message.txt"

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
