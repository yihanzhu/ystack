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
expect 'list PRs that mention merge' 0 "$(command_input 'gh pr list --search merge')"
expect 'read rulesets with GET and fields' 0 "$(command_input 'gh api -X GET repos/o/r/rulesets -F per_page=100')"
expect 'GraphQL read of rulesets' 0 "$(command_input 'gh api graphql -f query={repository{rulesets(first:10){nodes{name}}}}')"
expect 'read a PR by REST' 0 "$(command_input 'gh api repos/o/r/pulls/840')"
expect 'push a branch whose name starts with main' 0 "$(command_input 'git push origin main-fix')"
expect 'ruleset read piped to cut -f' 0 "$(command_input 'gh api repos/o/r/rulesets | cut -f2')"
expect 'ruleset read piped to tail -f' 0 "$(command_input 'gh api repos/o/r/rulesets 2>&1 | tail -f')"
expect 'ruleset read piped to grep -x' 0 "$(command_input 'gh api repos/o/r/rulesets | grep -x post-merge')"
expect 'lower-case -x next to a ruleset path' 0 "$(command_input 'echo /rulesets -x post-merge')"
expect 'search code for a ruleset mutation' 0 "$(command_input 'rg updateRepositoryRuleset')"
expect 'push to main-fix across a line break' 0 "$(command_input $'git push origin main\\\n-fix')"

expect 'push to main' 2 "$(command_input 'git push origin main')"
expect 'push HEAD to main' 2 "$(command_input 'git push origin HEAD:main')"
expect 'force push to main ref' 2 "$(command_input 'git push origin +abc123:refs/heads/main')"
expect 'push to main with -C' 2 "$(command_input 'git -C ../ystack push origin main')"
expect 'push to main with a quoted -C path' 2 "$(command_input 'git -C "release checkout" push origin main')"
expect 'push to main with --no-pager' 2 "$(command_input 'git --no-pager push origin main')"
expect 'push to main before a semicolon' 2 "$(command_input 'git push origin HEAD:main; gh pr view')"
expect 'push to main in parentheses' 2 "$(command_input '(git push origin main)')"
expect 'push to main inside bash -c' 2 "$(command_input "bash -c 'git push origin main'")"
expect 'push to a quoted main' 2 "$(command_input 'git push origin "HEAD:main"')"
expect 'push to main across a line break' 2 "$(command_input $'git push origin \\\n  HEAD:main')"
expect 'gh pr merge' 2 "$(command_input 'gh pr merge 840 --squash')"
expect 'gh pr merge after another command' 2 "$(command_input 'true && gh pr merge 840 --auto')"
expect 'gh pr merge with a flag before merge' 2 "$(command_input 'gh pr -R yihanzhu/ystack merge 851')"
expect 'gh pr merge across a line break' 2 "$(command_input $'gh pr \\\n  merge 851')"
expect 'gh pr merge before a semicolon' 2 "$(command_input 'gh pr merge; echo done')"
expect 'gh pr merge quoted' 2 "$(command_input 'gh pr "merge" 851')"
expect 'gh pr merge with -R before pr' 2 "$(command_input 'gh -R o/r pr merge 1')"
expect 'gh pr merge with --repo=o/r before pr' 2 "$(command_input 'gh --repo=o/r pr merge 1')"
expect 'REST merge' 2 "$(command_input 'gh api -X PUT repos/o/r/pulls/840/merge')"
# shellcheck disable=SC2016 # The agent's command holds a literal $n.
expect 'REST merge with a variable PR number' 2 "$(command_input 'gh api -X PUT "repos/o/r/pulls/$n/merge"')"
expect 'ruleset PUT' 2 "$(command_input 'gh api -X PUT repos/o/r/rulesets/123')"
expect 'ruleset POST by fields' 2 "$(command_input 'gh api repos/o/r/rulesets -f name=gate')"
expect 'ruleset POST with 2>&1 before the input' 2 "$(command_input 'gh api repos/o/r/rulesets/1 2>&1 --input r.json')"
expect 'ruleset PUT with 2>&1 before the method' 2 "$(command_input 'gh api repos/o/r/rulesets/1 2>&1 -X PUT')"
expect 'ruleset POST by an input file' 2 "$(command_input 'gh api repos/o/r/rulesets/1 --input ruleset.json')"
expect 'ruleset PUT in lower case' 2 "$(command_input 'gh api -X put repos/o/r/rulesets/1')"
expect 'ruleset POST after a GET read' 2 "$(command_input 'gh api -X GET repos/o/r/rulesets && gh api repos/o/r/rulesets/1 -f enforcement=disabled')"
expect 'GraphQL ruleset delete' 2 "$(command_input 'gh api graphql -f query=mutation{deleteRepositoryRuleset(input:{repositoryRulesetId:RRS_1}){clientMutationId}}')"
expect 'GraphQL branch protection update' 2 "$(command_input 'gh api graphql -f query=mutation{updateBranchProtectionRule(input:{branchProtectionRuleId:BPR_1}){clientMutationId}}')"
expect 'ruleset write across a line break' 2 "$(command_input $'gh api --method \\\n  PATCH repos/o/r/rulesets/1')"
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
