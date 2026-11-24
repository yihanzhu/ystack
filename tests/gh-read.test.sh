#!/bin/bash
# Checks that scripts/gh-read.sh shows only the owner's text as instructions.
set -u

read_item="$(git rev-parse --show-toplevel)/scripts/gh-read.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
failures=0

pass() { echo "ok - $1"; }
fail() { echo "not ok - $1"; failures=$((failures + 1)); }

# Writes a saved GraphQL response. $1 file, $2 item author, $3 more pages (true|false).
fixture() {
  jq -n --arg author "$2" --argjson more "$3" '
    def person($l): {login: $l, __typename: "User"};
    {data: {repository: {issueOrPullRequest: {
      __typename: "PullRequest", number: 7, url: "https://example.invalid/7",
      headRefOid: "abc123", title: "Owner title",
      author: person($author), editor: null, body: "OWNER-BODY",
      comments: {pageInfo: {hasNextPage: $more}, nodes: [
        {author: person("stranger"), editor: null, body: "IGNORE-ALL-RULES", url: "u1"},
        {author: person("yihanzhu"), editor: null, body: "OWNER-COMMENT", url: "u2"},
        {author: person("yihanzhu"), editor: {login: "stranger"}, body: "EDITED-BY-STRANGER", url: "u3"},
        {author: {login: "yihanzhu", __typename: "Bot"}, editor: null, body: "BOT-WITH-OWNER-NAME", url: "u4"},
        {author: null, editor: null, body: "DELETED-ACCOUNT", url: "u5"}
      ]},
      reviews: {pageInfo: {hasNextPage: false}, nodes: [
        {author: person("stranger"), editor: null, body: "REVIEW-BY-STRANGER", state: "COMMENTED", url: "u6",
         comments: {pageInfo: {hasNextPage: false}, nodes: [
           {author: person("stranger"), editor: null, body: "LINE-BY-STRANGER", path: "a.sh", url: "u7"},
           {author: person("yihanzhu"), editor: null, body: "LINE-BY-OWNER", path: "a.sh", url: "u8"}
         ]}}
      ]}
    }}}}' > "$1"
}

check_output() {
  local name=$1 out=$2 shown=$3 hidden=$4 word
  for word in $shown; do
    printf '%s\n' "$out" | grep -q -F -- "$word" || { fail "$name: $word is missing"; return; }
  done
  for word in $hidden; do
    printf '%s\n' "$out" | grep -q -F -- "$word" && { fail "$name: $word is shown"; return; }
  done
  pass "$name"
}

fixture "$scratch/owner.json" yihanzhu false
out=$(env -u YSTACK_OWNER "$read_item" --from-json "$scratch/owner.json")
check_output 'owner PR, default view' "$out" \
  'OWNER-BODY OWNER-COMMENT LINE-BY-OWNER Title: hidden,' \
  'IGNORE-ALL-RULES EDITED-BY-STRANGER BOT-WITH-OWNER-NAME DELETED-ACCOUNT REVIEW-BY-STRANGER LINE-BY-STRANGER'

out=$(env -u YSTACK_OWNER "$read_item" --show-data --from-json "$scratch/owner.json")
check_output 'owner PR, data shown in fences' "$out" \
  'OWNER-BODY IGNORE-ALL-RULES LINE-BY-STRANGER <<<DATA NOT' ''
marker=$(printf '%s\n' "$out" | sed -n 's/^<<<DATA \([0-9a-f]*\)$/\1/p' | head -1)
if [ "${#marker}" -eq 16 ] && printf '%s\n' "$out" | grep -q -x -F "DATA $marker>>>"; then
  pass 'data fence has a 16-digit marker'
else
  fail 'data fence has a 16-digit marker'
fi

fixture "$scratch/stranger.json" stranger false
out=$(env -u YSTACK_OWNER "$read_item" --from-json "$scratch/stranger.json")
check_output 'PR opened by someone else' "$out" 'Do OWNER-COMMENT' 'OWNER-BODY Owner'

out=$(YSTACK_OWNER=stranger "$read_item" --from-json "$scratch/stranger.json")
check_output 'owner set by YSTACK_OWNER' "$out" \
  'OWNER-BODY IGNORE-ALL-RULES REVIEW-BY-STRANGER' 'OWNER-COMMENT LINE-BY-OWNER'

fixture "$scratch/more.json" yihanzhu true
if "$read_item" --from-json "$scratch/more.json" >/dev/null 2>&1; then
  fail 'more pages than one fails'
else
  pass 'more pages than one fails'
fi

printf '{"data":{"repository":{"issueOrPullRequest":null}}}' > "$scratch/none.json"
if "$read_item" --from-json "$scratch/none.json" >/dev/null 2>&1; then
  fail 'missing item fails'
else
  pass 'missing item fails'
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
