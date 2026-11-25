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
expect 'push a feature branch with -C' 0 "$(command_input 'git -C ../ystack push origin feature')"
expect 'push a feature branch, then check out main' 0 "$(command_input 'git push origin feature && git checkout main')"
expect 'read a PR with -R before pr' 0 "$(command_input 'gh -R o/r pr view 1')"
expect 'ruleset read with &>' 0 "$(command_input 'gh api repos/o/r/rulesets &>/dev/null')"
expect 'ruleset read piped to grep -F' 0 "$(command_input 'gh api repos/o/r/rulesets | grep -F enforcement')"
expect 'ruleset read piped to sort -f' 0 "$(command_input 'gh api repos/o/r/rulesets | sort -f')"
expect 'ruleset read with HEAD' 0 "$(command_input 'gh api --method=head repos/o/r/rulesets')"
expect 'read the default branch' 0 "$(command_input 'gh api repos/o/r --jq .default_branch')"
# shellcheck disable=SC2016 # The agent's command holds a literal $(...).
expect 'ruleset read with GET inside $(...)' 0 "$(command_input 'count=$(gh api repos/o/r/rulesets -X GET)')"
expect 'read PR files into a file named merge' 0 "$(command_input 'gh api repos/o/r/pulls/42/files > /tmp/merge-files.json')"

expect 'push to main' 2 "$(command_input 'git push origin main')"
expect 'push HEAD to main' 2 "$(command_input 'git push origin HEAD:main')"
expect 'force push to main ref' 2 "$(command_input 'git push origin +abc123:refs/heads/main')"
expect 'push to main with -C' 2 "$(command_input 'git -C ../ystack push origin main')"
expect 'push to main with a quoted -C path' 2 "$(command_input 'git -C "release checkout" push origin main')"
expect 'push to main with -c' 2 "$(command_input 'git -c k=v push origin main')"
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
expect 'gh pr merge with --repo o/r before pr' 2 "$(command_input 'gh --repo o/r pr merge 1')"
expect 'REST merge' 2 "$(command_input 'gh api -X PUT repos/o/r/pulls/840/merge')"
# shellcheck disable=SC2016 # The agent's command holds a literal $n.
expect 'REST merge with a variable PR number' 2 "$(command_input 'gh api -X PUT "repos/o/r/pulls/$n/merge"')"
# shellcheck disable=SC2016 # The agent's command holds a literal $(...).
expect 'REST merge with a substituted PR number' 2 "$(command_input 'gh api -X PUT "repos/o/r/pulls/$(gh pr view --json number -q .number)/merge"')"
expect 'ruleset DELETE with a quoted pipe' 2 "$(command_input "gh api repos/o/r/rulesets/1 --jq '.a|.b' -X DELETE")"
expect 'ruleset PUT with a quoted &' 2 "$(command_input "gh api 'repos/o/r/rulesets/1?a=1&b=2' -X PUT")"
expect 'ruleset POST with a quoted & and fields' 2 "$(command_input "gh api 'repos/o/r/rulesets?a=1&b=2' -f name=gate")"
expect 'ruleset write with an escaped quote before a quoted pipe' 2 "$(command_input 'gh api repos/o/r/rulesets/1 -H "X-Note: a\"|b" -X OPTIONS')"
expect 'ruleset DELETE with an escaped pipe' 2 "$(command_input 'gh api repos/o/r/rulesets/1 --jq .a\|.b -X DELETE')"
expect 'ruleset DELETE with a quoted semicolon' 2 "$(command_input "gh api repos/o/r/rulesets/1 -H 'X-A: a;b' -X DELETE")"
# shellcheck disable=SC2016 # The agent's command holds a literal $M.
expect 'ruleset write with a variable method' 2 "$(command_input 'gh api -X "$M" repos/o/r/rulesets/1 -f enforcement=disabled')"
# shellcheck disable=SC2016 # The agent's command holds a literal $(...).
expect 'ruleset write with a substituted method' 2 "$(command_input 'gh api --method "$(echo DELETE)" repos/o/r/rulesets/1')"
expect 'ruleset DELETE with grouped -iX' 2 "$(command_input 'gh api -iX DELETE repos/o/r/rulesets/1')"
expect 'ruleset PUT with grouped -iXPUT' 2 "$(command_input 'gh api -iXPUT repos/o/r/rulesets/1')"
expect 'ruleset POST with grouped -if' 2 "$(command_input 'gh api repos/o/r/rulesets -if name=gate')"
expect 'ruleset PUT by curl --request' 2 "$(command_input 'curl --request PUT https://api.github.com/repos/o/r/rulesets/1')"
expect 'ruleset POST by --field' 2 "$(command_input 'gh api repos/o/r/rulesets --field name=gate')"
expect 'ruleset POST by --raw-field' 2 "$(command_input 'gh api repos/o/r/rulesets --raw-field name=gate')"
expect 'ruleset POST by -F' 2 "$(command_input 'gh api repos/o/r/rulesets -F name=gate')"
expect 'branch protection POST by fields' 2 "$(command_input 'gh api repos/o/r/branches/main/protection -f enforce_admins=false')"
expect 'branch protection POST by an input file' 2 "$(command_input 'gh api repos/o/r/branches/main/protection --input p.json')"
expect 'ruleset DELETE after &>' 2 "$(command_input 'gh api repos/o/r/rulesets/1 &>/dev/null -X DELETE')"
expect 'ruleset PUT after <&' 2 "$(command_input 'gh api repos/o/r/rulesets/1 0<&3 -X PUT')"
expect 'default branch by gh repo edit' 2 "$(command_input 'gh repo edit --default-branch dev')"
expect 'default branch by gh repo edit -R' 2 "$(command_input 'gh repo edit -R o/r --default-branch dev')"
expect 'default branch by REST PATCH' 2 "$(command_input 'gh api -X PATCH repos/o/r -f default_branch=dev')"
expect 'ruleset PUT' 2 "$(command_input 'gh api -X PUT repos/o/r/rulesets/123')"
expect 'ruleset POST by fields' 2 "$(command_input 'gh api repos/o/r/rulesets -f name=gate')"
expect 'ruleset POST with 2>&1 before the input' 2 "$(command_input 'gh api repos/o/r/rulesets/1 2>&1 --input r.json')"
expect 'ruleset PUT with 2>&1 before the method' 2 "$(command_input 'gh api repos/o/r/rulesets/1 2>&1 -X PUT')"
expect 'ruleset POST by an input file' 2 "$(command_input 'gh api repos/o/r/rulesets/1 --input ruleset.json')"
expect 'ruleset PUT in lower case' 2 "$(command_input 'gh api -X put repos/o/r/rulesets/1')"
expect 'ruleset POST after a GET read' 2 "$(command_input 'gh api -X GET repos/o/r/rulesets && gh api repos/o/r/rulesets/1 -f enforcement=disabled')"
expect 'GraphQL ruleset delete' 2 "$(command_input 'gh api graphql -f query=mutation{deleteRepositoryRuleset(input:{repositoryRulesetId:RRS_1}){clientMutationId}}')"
expect 'GraphQL branch protection update' 2 "$(command_input 'gh api graphql -f query=mutation{updateBranchProtectionRule(input:{branchProtectionRuleId:BPR_1}){clientMutationId}}')"
expect 'GraphQL ruleset create' 2 "$(command_input 'gh api graphql -f query=mutation{createRepositoryRuleset(input:{}){clientMutationId}}')"
expect 'GraphQL branch protection create' 2 "$(command_input 'gh api graphql -f query=mutation{createBranchProtectionRule(input:{}){clientMutationId}}')"
expect 'ruleset write across a line break' 2 "$(command_input $'gh api --method \\\n  PATCH repos/o/r/rulesets/1')"
expect 'branch protection DELETE' 2 "$(command_input 'gh api --method=DELETE repos/o/r/branches/main/protection')"
expect 'empty command' 2 "$(command_input '')"
expect 'no command field' 2 '{"tool_input":{}}'
expect 'GraphQL merge' 2 "$(command_input 'gh api graphql -f query="mutation { mergePullRequest(input: {}) { clientMutationId } }"')"
expect 'GraphQL auto-merge' 2 "$(command_input 'gh api graphql -f query="mutation { enablePullRequestAutoMerge(input: {}) { clientMutationId } }"')"
expect 'input that is not JSON' 2 'not json'
expect 'truncated JSON' 2 '{"tool_input":{"command":"git st'

# A here-string needs a temporary file in bash 3.2. If that file cannot be
# made, the loop it feeds is skipped and the hook lets the command through.
if grep -q '<<<' "$hook"; then
  echo "not ok - the hook uses no here-string"
  failures=$((failures + 1))
else
  echo "ok - the hook uses no here-string"
fi

# The hook needs jq. With no jq on PATH, it blocks.
no_jq=$(mktemp -d) || exit 1
trap 'rm -rf "$no_jq"' EXIT
ln -s "$(command -v tr)" "$no_jq/tr"
input=$(command_input 'git status')
printf '%s' "$input" | PATH=$no_jq "$hook" >/dev/null 2>&1
if [ $? -eq 2 ]; then
  echo "ok - jq missing from PATH"
else
  echo "not ok - jq missing from PATH"
  failures=$((failures + 1))
fi

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
