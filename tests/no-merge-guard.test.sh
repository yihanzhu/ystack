#!/bin/bash
# Checks that the merge-guard hook blocks agent merges and pushes to main.
set -u

hook="$(git rev-parse --show-toplevel)/.claude/hooks/no-merge-guard.sh"
failures=0

expect() {
  local name=$1 want=$2 input=$3 got
  printf '%s' "$input" | "$hook" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    echo "ok - $name"
  else
    echo "not ok - $name: exit $got, want $want"
    failures=$((failures + 1))
  fi
}

command_input() {
  jq -cn --arg command "$1" '{tool_input: {command: $command}}'
}

expect 'plain command' 0 "$(command_input 'git status')"
expect 'push a branch' 0 "$(command_input 'git push -u origin repurpose/park')"
expect 'read a PR' 0 "$(command_input 'gh pr view 840 --json state')"
expect 'no command field' 0 '{"tool_input":{}}'

expect 'push to main' 2 "$(command_input 'git push origin main')"
expect 'push HEAD to main' 2 "$(command_input 'git push origin HEAD:main')"
expect 'force push to main ref' 2 "$(command_input 'git push origin +abc123:refs/heads/main')"
expect 'gh pr merge' 2 "$(command_input 'gh pr merge 840 --squash')"
expect 'gh pr merge after another command' 2 "$(command_input 'true && gh pr merge 840 --auto')"
expect 'REST merge' 2 "$(command_input 'gh api -X PUT repos/o/r/pulls/840/merge')"
expect 'GraphQL merge' 2 "$(command_input 'gh api graphql -f query="mutation { mergePullRequest(input: {}) { clientMutationId } }"')"
expect 'GraphQL auto-merge' 2 "$(command_input 'gh api graphql -f query="mutation { enablePullRequestAutoMerge(input: {}) { clientMutationId } }"')"
expect 'input that is not JSON' 2 'not json'

# Command substitution drops NUL bytes, so this case pipes the input directly.
printf '{"tool_input":{"command":"x"}}\0' | "$hook" >/dev/null 2>&1
if [ $? -eq 2 ]; then
  echo "ok - input with a NUL byte"
else
  echo "not ok - input with a NUL byte"
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
