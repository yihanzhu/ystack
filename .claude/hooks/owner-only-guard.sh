#!/bin/bash
# PreToolUse guard for Bash and WebFetch. Agents read issue, PR, review and
# comment text only through scripts/gh-read.sh, which hides text that the owner
# did not write. Exit 2 blocks the call.

export LC_ALL=C

block() {
  echo "Blocked by ystack guard: $1 Use scripts/gh-read.sh NUMBER; it hides text from other accounts." >&2
  exit 2
}

fail() {
  echo "Blocked by ystack guard: $1" >&2
  exit 2
}

# One line each for the tool name and the URL, then the command, which may hold
# line breaks, then a last line "." so that no line break is lost.
if IFS= read -r -d '' input || ! fields=$(
  set -o pipefail
  printf '%s' "$input" | jq -r '
    (.tool_name // ""), (.tool_input.url // "" | gsub("\n"; " ")),
    (.tool_input.command // ""), "." | gsub("\u0000"; "")' 2>/dev/null
); then
  fail "the hook could not read its input."
fi
tool=${fields%%$'\n'*}
rest=${fields#*$'\n'}
url=${rest%%$'\n'*}
rest=${rest#*$'\n'}
cmd=${rest%$'\n.'}

case $tool in
  Bash) [ -n "$cmd" ] || fail "the hook got no command." ;;
  WebFetch) [ -n "$url" ] || fail "the hook got no URL." ;;
  *) [ -n "$cmd$url" ] || fail "the hook got no command and no URL." ;;
esac

if printf '%s' "$url" | grep -Eiq 'https?://(www\.)?github\.com/[^/]+/[^/]+/(issues|pull)/[0-9]+'; then
  block "this page holds issue or PR text from any account."
fi
# Backslash line breaks are removed, as bash removes them.
cmd=${cmd//$'\\\n'/}
# Every rule below needs `gh` and a space, so other commands pass at once.
[[ $cmd =~ gh[[:space:]] ]] || exit 0

# JSON fields of gh issue, gh pr and gh search that hold text from any account.
text_fields='(^|[^A-Za-z])(body|comments|reviews|latestReviews)([^A-Za-z]|$)'

while IFS= read -r part; do
  if printf '%s' "$part" | grep -Eq 'gh[[:space:]]+(issue|pr|search)[[:space:]]'; then
    if printf '%s' "$part" | grep -Eq -- '--comments'; then
      block "--comments prints comments from any account."
    fi
    if printf '%s' "$part" | grep -Eq -- '--json' && printf '%s' "$part" | grep -Eq "$text_fields"; then
      block "these JSON fields hold text from any account."
    fi
    if printf '%s' "$part" | grep -Eq 'gh[[:space:]]+(issue|pr)[[:space:]]+view' &&
      ! printf '%s' "$part" | grep -Eq -- '--json|(^|[[:space:]])(-w|--web)([[:space:]]|$)'; then
      block "plain 'gh issue view' and 'gh pr view' print the body."
    fi
  fi
  if printf '%s' "$part" | grep -Eq 'gh[[:space:]]+api'; then
    if printf '%s' "$part" | grep -Eq '/(comments|reviews|timeline|events)([^A-Za-z]|$)'; then
      block "this endpoint returns comments or reviews."
    fi
    # One issue or PR, a list of them (of a repository, an organization, the
    # user, or all), or an issue search. A repository named issues is not a list.
    if printf '%s' "$part" | grep -Eq "(issues|pulls)/[0-9]+([^0-9/]|\$)|(repos/[^/[:space:]]+/[^/[:space:]]+/|orgs/[^/[:space:]]+/|user/|[[:space:]\"']/?)(issues|pulls)([?[:space:]\"']|\$)|search/issues"; then
      if ! printf '%s' "$part" | grep -Eq -- '(--jq|-q)[[:space:]=]' ||
        printf '%s' "$part" | grep -Eq 'body|title'; then
        block "issue and PR objects hold their body and title; filter them with --jq."
      fi
    fi
    if printf '%s' "$part" | grep -Eq 'graphql' &&
      printf '%s' "$part" | grep -Eiq 'body|title|comment|review|timeline'; then
      block "this query reads text from any account."
    fi
  fi
done < <(printf '%s\n' "$cmd" | tr ';|&' '\n')
exit 0
