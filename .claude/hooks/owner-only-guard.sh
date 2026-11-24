#!/bin/bash
# PreToolUse guard for Bash and WebFetch. Agents read issue, PR, review and
# comment text only through scripts/gh-read.sh, which hides text that the owner
# did not write. Exit 2 blocks the call.

export LC_ALL=C

block() {
  echo "Blocked by ystack guard: $1 Use scripts/gh-read.sh NUMBER; it hides text from other accounts." >&2
  exit 2
}

if IFS= read -r -d '' input || ! fields=$(
  set -o pipefail
  printf '%s' "$input" | jq -r '[.tool_input.command // "", .tool_input.url // ""] | map(gsub("\u0000"; "")) | .[]' 2>/dev/null
); then
  echo "Blocked by ystack guard: the hook could not read its input." >&2
  exit 2
fi
cmd=${fields%$'\n'*}
url=${fields##*$'\n'}

if printf '%s' "$url" | grep -Eiq '^https?://(www\.)?github\.com/[^/]+/[^/]+/(issues|pull)/[0-9]+'; then
  block "this page holds issue or PR text from any account."
fi
[ -n "$cmd" ] || exit 0

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
    if printf '%s' "$part" | grep -Eq '(issues|pulls)/[0-9]+([^0-9/]|$)'; then
      if ! printf '%s' "$part" | grep -Eq -- '(--jq|-q)[[:space:]=]' ||
        printf '%s' "$part" | grep -Eq 'body|title'; then
        block "the issue or PR object holds its body; filter it with --jq."
      fi
    fi
    if printf '%s' "$part" | grep -Eq 'graphql' && printf '%s' "$part" | grep -Eq 'body'; then
      block "this query reads body text."
    fi
  fi
done < <(printf '%s\n' "$cmd" | tr ';|&' '\n')
exit 0
