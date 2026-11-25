#!/bin/bash
# Runs every check in this repo. It runs them all, then exits 1 if any failed.
#
#   scripts/check.sh              all checks
#   scripts/check.sh --skip-tree  all but the tree scan, for the CI checks job
#
# CI's guard job scans the tree with the base commit's scanner and the term
# secret, so the checks job skips that scan and never sees the term list.
set -uo pipefail

# CI installs this version too; ci.yml holds its digest. Change both together.
shellcheck_version=0.11.0

skip_tree=false
case ${1:-} in
  '') ;;
  --skip-tree) skip_tree=true ;;
  *) echo "usage: scripts/check.sh [--skip-tree]" >&2; exit 2 ;;
esac

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 2
cd "$root" || exit 2

failed=()

echo "== shellcheck"
got=$(shellcheck --version 2> /dev/null | awk '/^version:/ { print $2 }')
if [ "$got" != "$shellcheck_version" ]; then
  echo "shellcheck ${got:-is missing}; this repo pins $shellcheck_version."
  failed+=("shellcheck version")
elif ! git ls-files -z -- '*.sh' .githooks | xargs -0 -r shellcheck -x -S style; then
  failed+=(shellcheck)
fi

# The public-repo test needs the pinned gitleaks.
echo "== gitleaks"
if ! scripts/get-gitleaks.sh; then
  failed+=(gitleaks)
fi

for test in tests/*.test.sh; do
  echo "== $test"
  bash "$test" < /dev/null || failed+=("$test")
done

if ! $skip_tree; then
  echo "== check-public tree"
  scripts/check-public.sh tree || failed+=("check-public tree")
fi

echo
if [ "${#failed[@]}" -gt 0 ]; then
  printf 'failed: %s\n' "${failed[@]}"
  exit 1
fi
echo "check.sh: all checks passed."
