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
expect 'read a PR with merge fields' 0 "$(command_input 'gh pr view 851 --json mergeable,mergeStateStatus')"
expect 'read rulesets' 0 "$(command_input 'gh api repos/o/r/rulesets')"
expect 'read a ruleset with GET' 0 "$(command_input 'gh api -X GET repos/o/r/rulesets/123')"
expect 'read branch protection' 0 "$(command_input 'gh api repos/o/r/branches/main/protection')"

expect 'push to main' 2 "$(command_input 'git push origin main')"
expect 'push HEAD to main' 2 "$(command_input 'git push origin HEAD:main')"
expect 'force push to main ref' 2 "$(command_input 'git push origin +abc123:refs/heads/main')"
expect 'gh pr merge' 2 "$(command_input 'gh pr merge 840 --squash')"
expect 'gh pr merge after another command' 2 "$(command_input 'true && gh pr merge 840 --auto')"
expect 'gh pr merge with a flag before merge' 2 "$(command_input 'gh pr -R yihanzhu/ystack merge 851')"
expect 'gh pr merge across a line break' 2 "$(command_input $'gh pr \\\n  merge 851')"
expect 'REST merge' 2 "$(command_input 'gh api -X PUT repos/o/r/pulls/840/merge')"
# shellcheck disable=SC2016 # The agent's command holds a literal $n.
expect 'REST merge with a variable PR number' 2 "$(command_input 'gh api -X PUT "repos/o/r/pulls/$n/merge"')"
expect 'ruleset PUT' 2 "$(command_input 'gh api -X PUT repos/o/r/rulesets/123 --input ruleset.json')"
expect 'ruleset POST by fields' 2 "$(command_input 'gh api repos/o/r/rulesets -f name=gate')"
expect 'branch protection DELETE' 2 "$(command_input 'gh api --method=DELETE repos/o/r/branches/main/protection')"
expect 'empty command' 2 "$(command_input '')"
expect 'no command field' 2 '{"tool_input":{}}'
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
