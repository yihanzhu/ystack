#!/bin/bash
# Checks that the owner-only hook blocks direct reads of issue and PR text.
set -u

hook="$(git rev-parse --show-toplevel)/.claude/hooks/owner-only-guard.sh"
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

bash_call() {
  jq -cn --arg command "$1" '{tool_name: "Bash", tool_input: {command: $command}}'
}

fetch_call() {
  jq -cn --arg url "$1" '{tool_name: "WebFetch", tool_input: {url: $url, prompt: "summarize"}}'
}

expect 'plain command' 0 "$(bash_call 'git status')"
expect 'gh-read' 0 "$(bash_call 'scripts/gh-read.sh 841')"
expect 'PR state as JSON' 0 "$(bash_call 'gh pr view 841 --json state,headRefOid')"
expect 'PR in the browser' 0 "$(bash_call 'gh pr view 841 --web')"
expect 'list titles' 0 "$(bash_call 'gh pr list --state open --json number,title')"
expect 'create a PR with a body' 0 "$(bash_call 'gh pr create --title t --body-file b.md')"
expect 'comment on an issue' 0 "$(bash_call 'gh issue comment 5 --body done')"
expect 'API object filtered' 0 "$(bash_call 'gh api repos/o/r/pulls/841 --jq .head.sha')"
expect 'API checks' 0 "$(bash_call 'gh api repos/o/r/commits/abc/check-runs --jq .total_count')"
expect 'other web page' 0 "$(fetch_call 'https://docs.github.com/en/rest')"
expect 'multi-line command with a plain last line' 0 "$(bash_call $'gh pr view 841 --json state\ngit status')"
expect 'API PR list filtered' 0 "$(bash_call "gh api repos/o/r/pulls --jq '.[].number'")"
expect 'API issue search count' 0 "$(bash_call "gh api 'search/issues?q=repo:o/r' --jq .total_count")"
expect 'API read of a repository named issues' 0 "$(bash_call 'gh api repos/acme/issues')"
expect 'API PR files filtered' 0 "$(bash_call "gh api repos/o/r/pulls/841/files --jq '.[].filename'")"
state_query='gh api graphql -f query="{ repository(owner: \"o\", name: \"r\") { pullRequest(number: 1) { state } } }"'
expect 'GraphQL state only' 0 "$(bash_call "$state_query")"

expect 'plain issue view' 2 "$(bash_call 'gh issue view 12')"
expect 'plain PR view' 2 "$(bash_call 'gh pr view 841')"
expect 'PR view with comments' 2 "$(bash_call 'gh pr view 841 --comments')"
expect 'PR body as JSON' 2 "$(bash_call 'gh pr view 841 --json title,body')"
expect 'PR reviews as JSON' 2 "$(bash_call 'gh pr view 841 --json reviews')"
expect 'issue list with bodies' 2 "$(bash_call 'gh issue list --json number,body')"
expect 'search with bodies' 2 "$(bash_call 'gh search issues x --json body')"
expect 'view after another command' 2 "$(bash_call 'cd /tmp && gh issue view 12')"
expect 'API comments' 2 "$(bash_call 'gh api repos/o/r/issues/12/comments')"
expect 'API reviews' 2 "$(bash_call 'gh api repos/o/r/pulls/841/reviews --jq .[].state')"
expect 'API timeline' 2 "$(bash_call 'gh api repos/o/r/issues/12/timeline')"
expect 'API object unfiltered' 2 "$(bash_call 'gh api repos/o/r/issues/12')"
expect 'API object body filter' 2 "$(bash_call 'gh api repos/o/r/issues/12 --jq .body')"
# An assignment keeps the braces literal; bash 3.2 expands them inside "$(...)".
graphql_cmd='gh api graphql -f query="query { repository(owner: \"o\", name: \"r\") { issue(number: 1) { body } } }"'
expect 'GraphQL body' 2 "$(bash_call "$graphql_cmd")"
expect 'issue page' 2 "$(fetch_call 'https://github.com/o/r/issues/12')"
expect 'PR page' 2 "$(fetch_call 'https://github.com/o/r/pull/841#issuecomment-1')"
expect 'input that is not JSON' 2 'not json'
expect 'multi-line command with a PR view last' 2 "$(bash_call $'echo start\ngh pr view 841')"
expect 'API issue list' 2 "$(bash_call 'gh api repos/o/r/issues')"
expect 'API PR list with a query' 2 "$(bash_call "gh api 'repos/o/r/pulls?state=open'")"
expect 'API issue search' 2 "$(bash_call "gh api 'search/issues?q=repo:o/r'")"
expect 'API PR list filtered to bodies' 2 "$(bash_call "gh api repos/o/r/pulls --jq '.[].body'")"
comments_query='gh api graphql -f query="{ repository(owner: \"o\", name: \"r\") { issue(number: 1) { comments(first: 5) { nodes { author { login } } } } } }"'
expect 'GraphQL comments' 2 "$(bash_call "$comments_query")"
title_query='gh api graphql -f query="{ repository(owner: \"o\", name: \"r\") { pullRequests(first: 5) { nodes { title } } } }"'
expect 'GraphQL titles' 2 "$(bash_call "$title_query")"
expect 'GraphQL titles across a line break' 2 "$(bash_call "${title_query/ -f/ \\$'\n'  -f}")"
expect 'Bash call with no command but a URL' 2 '{"tool_name":"Bash","tool_input":{"command":"","url":"https://docs.github.com"}}'
expect 'WebFetch call with no URL but a command' 2 '{"tool_name":"WebFetch","tool_input":{"url":"","command":"pwd"}}'
expect 'issue page after a line break' 2 "$(fetch_call $'\nhttps://github.com/o/r/issues/12')"
expect 'API issue list of all repositories' 2 "$(bash_call 'gh api /issues')"
expect 'API issue list of an organization' 2 "$(bash_call 'gh api orgs/o/issues')"
expect 'no tool name and no fields' 2 '{"tool_input":{}}'
expect 'truncated JSON' 2 '{"tool_name":"Bash","tool_input":{"command":"git st'

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
