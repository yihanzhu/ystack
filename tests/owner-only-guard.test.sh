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

# Checks that the block message names $3.
expect_message() {
  local name=$1 input=$2 want=$3 got
  got=$(printf '%s' "$input" | "$hook" 2>&1 >/dev/null)
  case $got in
    *"$want"*) echo "ok - $name" ;;
    *) echo "not ok - $name: message lacks '$want'"; failures=$((failures + 1)) ;;
  esac
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
status_query='gh api graphql -f query="{ repository(owner: \"o\", name: \"r\") { pullRequest(number: 1) { reviewDecision reviewRequests(first: 5) { totalCount } reviewThreads(first: 50) { nodes { isResolved } } comments { totalCount } } } }"'
expect 'GraphQL review status and comment count' 0 "$(bash_call "$status_query")"
expect 'API PR list with a quoted & and a safe filter' 0 "$(bash_call "gh api 'repos/o/r/pulls?state=open&per_page=100' --jq '.[].number'")"
expect 'API PR list as TSV of safe fields' 0 "$(bash_call "gh api repos/o/r/pulls --jq '.[] | [.number, .user.login] | @tsv'")"
expect 'API PR list mapped to numbers' 0 "$(bash_call "gh api repos/o/r/pulls --jq 'map(.number)'")"
expect 'API open PR numbers through select' 0 "$(bash_call "gh api repos/o/r/pulls --jq '.[] | select(.draft == false) | .number'")"
expect 'API PR numbers sorted, then printed' 0 "$(bash_call "gh api repos/o/r/pulls --jq 'sort_by(.number) | .[].number'")"
expect 'API read of a repository named issues by address' 0 "$(fetch_call 'https://api.github.com/repos/acme/issues')"
expect 'API PR with grouped -iq and a safe field' 0 "$(bash_call "gh api repos/o/r/pulls/1 -iq '.head.sha'")"
# shellcheck disable=SC2016 # These agent commands hold literal $(...) and $VAR.
{
  expect 'safe read in a quoted substitution' 0 "$(bash_call 'sha="$(gh api repos/o/r/pulls/856 --jq .head.sha)"')"
  expect 'safe read in a substitution with a quoted filter' 0 "$(bash_call "sha=\$(gh api repos/o/r/pulls/856 --jq '.head.sha')")"
  expect 'safe read in echo' 0 "$(bash_call 'echo "$(gh api repos/o/r/pulls/856 --jq .head.sha)"')"
  expect 'safe read in test' 0 "$(bash_call 'test "$(gh api repos/o/r/pulls/856 --jq .state)" = closed')"
  expect 'PR files by a variable number, filtered' 0 "$(bash_call "gh api repos/o/r/pulls/\$n/files --jq '.[].filename'")"
  expect 'PR by a variable number, safe filter' 0 "$(bash_call 'gh api repos/o/r/pulls/$n --jq .state')"
  expect 'PR list of a variable repository, filtered' 0 "$(bash_call "gh api \"repos/\$REPO/pulls\" --jq '.[].number'")"
  expect 'PRs of a commit, filtered' 0 "$(bash_call "gh api repos/o/r/commits/abc/pulls --jq '.[].number'")"
}
expect 'API issue search numbers' 0 "$(bash_call "gh api 'search/issues?q=repo:o/r' --jq '.items[].number'")"
expect 'curl of check runs' 0 "$(bash_call 'curl -s https://api.github.com/repos/o/r/commits/abc/check-runs')"
expect 'repository page' 0 "$(fetch_call 'https://github.com/o/r')"
expect 'file page' 0 "$(fetch_call 'https://github.com/o/r/blob/main/README.md')"

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
comments_query='gh api graphql -f query="{ repository(owner: \"o\", name: \"r\") { issue(number: 1) { comments(first: 5) { nodes { bodyText } } } } }"'
expect 'GraphQL comment bodies' 2 "$(bash_call "$comments_query")"
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
expect 'API PR bodies through a quoted pipe' 2 "$(bash_call "gh api repos/o/r/pulls --jq '.[] | .body'")"
expect 'API issue objects with bodies' 2 "$(bash_call "gh api repos/o/r/issues --jq '.[] | {number, body}'")"
expect 'API issue search titles' 2 "$(bash_call "gh api 'search/issues?q=repo:o/r' --jq '.items[] | .title'")"
expect 'API issue with the identity filter' 2 "$(bash_call 'gh api repos/o/r/issues/12 --jq .')"
expect 'API PR list with .[]' 2 "$(bash_call "gh api repos/o/r/pulls --jq '.[]'")"
expect 'API issue search with .items' 2 "$(bash_call "gh api 'search/issues?q=repo:o/r' --jq .items")"
expect 'API PR with del' 2 "$(bash_call "gh api repos/o/r/pulls/1 -q 'del(.head)'")"
# shellcheck disable=SC2016 # These agent commands hold literal $(...), backquotes and $VAR.
{
  expect 'body read in a quoted substitution' 2 "$(bash_call 'x="$(gh api repos/o/r/pulls/856 --jq .body)"')"
  expect 'issue read in backquotes' 2 "$(bash_call 'x=`gh api repos/o/r/issues/1`')"
  expect 'PR by a variable number' 2 "$(bash_call 'gh api repos/o/r/pulls/$n')"
  expect 'issue by a braced variable number' 2 "$(bash_call 'gh api repos/o/r/issues/${n}')"
  expect 'issue body by a quoted variable number' 2 "$(bash_call 'gh api "repos/o/r/issues/$n" --jq .body')"
  expect 'PR bodies in a loop' 2 "$(bash_call 'for n in 850 851; do gh api repos/o/r/pulls/$n --jq .body; done')"
  expect 'PR by a substituted number' 2 "$(bash_call 'gh api repos/o/r/pulls/$(gh pr view --json number -q .number)')"
  expect 'issue list of a variable repository' 2 "$(bash_call 'gh api "repos/$REPO/issues"')"
  expect 'PR list of the workflow repository' 2 "$(bash_call 'gh api repos/$GITHUB_REPOSITORY/pulls')"
  expect 'PRs of a commit' 2 "$(bash_call 'gh api repos/o/r/commits/abc/pulls')"
  expect 'PRs of a commit by curl' 2 "$(bash_call 'curl -s https://api.github.com/repos/o/r/commits/abc/pulls')"
}
expect 'PRs of a commit by address' 2 "$(fetch_call 'https://api.github.com/repos/o/r/commits/abc/pulls')"
expect 'API PRs through sort_by' 2 "$(bash_call "gh api repos/o/r/pulls --jq 'sort_by(.number)'")"
expect 'API PRs through group_by' 2 "$(bash_call "gh api repos/o/r/pulls --jq 'group_by(.state)'")"
expect 'API PR with a safe filter, then an attached body filter' 2 "$(bash_call 'gh api repos/o/r/pulls/1 -q .number -q.body')"
expect 'API PR with --jq only inside another argument' 2 "$(bash_call "gh api repos/o/r/pulls/1 -H 'X-A: --jq .number'")"
title_event_query='gh api graphql -f query="{ repository(owner: \"o\", name: \"r\") { issue(number: 1) { timelineItems(first: 5) { nodes { ... on RenamedTitleEvent { previousTitle currentTitle } } } } } }"'
expect 'GraphQL renamed titles' 2 "$(bash_call "$title_event_query")"
expect 'API open PRs through select' 2 "$(bash_call "gh api repos/o/r/pulls --jq '.[] | select(.draft == false)'")"
expect 'API PR titles in a string' 2 "$(bash_call "gh api repos/o/r/pulls --jq '.[] | \"\\(.number) \\(.title)\"'")"
expect 'API PR with a template' 2 "$(bash_call "gh api repos/o/r/pulls/1 --jq .number -t '{{.body}}'")"
expect 'GraphQL body on the next line' 2 "$(bash_call $'gh api graphql -f query=\'\n{ repository(owner:"o",name:"r") { pullRequest(number:1) { body } } }\'')"
# shellcheck disable=SC2016 # The agent's command holds a literal $q.
expect 'GraphQL body in a variable' 2 "$(bash_call $'q=\'{ repository(owner:"o",name:"r") { pullRequest(number:1) { body } } }\'\ngh api graphql -f query="$q"')"
expect 'curl of an issue' 2 "$(bash_call 'curl -s https://api.github.com/repos/o/r/issues/12')"
expect 'curl of issue comments' 2 "$(bash_call 'curl -s https://api.github.com/repos/o/r/issues/12/comments')"
expect 'curl of a PR list' 2 "$(bash_call 'curl -s https://api.github.com/repos/o/r/pulls')"
expect 'wget of an issue search' 2 "$(bash_call "wget -qO- 'https://api.github.com/search/issues?q=repo:o/r'")"
expect 'curl of GraphQL' 2 "$(bash_call 'curl -s -X POST https://api.github.com/graphql -d @q.json')"
expect 'API issue address' 2 "$(fetch_call 'https://api.github.com/repos/o/r/issues/12')"
expect 'API review address' 2 "$(fetch_call 'https://api.github.com/repos/o/r/pulls/1/reviews')"
expect 'issue list page' 2 "$(fetch_call 'https://github.com/o/r/issues')"
expect 'PR list page' 2 "$(fetch_call 'https://github.com/o/r/pulls')"
expect 'discussions page' 2 "$(fetch_call 'https://github.com/o/r/discussions')"
expect 'discussion page' 2 "$(fetch_call 'https://github.com/o/r/discussions/5')"
expect_message 'unsafe filter names the safe fields' "$(bash_call 'gh api repos/o/r/issues/12 --jq .')" 'may name only these fields'

# The hook needs jq. With no jq on PATH, it blocks and says so.
no_jq=$(mktemp -d) || exit 1
trap 'rm -rf "$no_jq"' EXIT
input=$(bash_call 'git status')
message=$(printf '%s' "$input" | PATH=$no_jq "$hook" 2>&1 >/dev/null)
status=$?
case $status:$message in
  2:*jq*) echo "ok - jq missing from PATH" ;;
  *) echo "not ok - jq missing from PATH: exit $status"; failures=$((failures + 1)) ;;
esac

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
