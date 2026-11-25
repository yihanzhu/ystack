#!/bin/bash
# PreToolUse guard for Bash. Agents never merge a PR and never push to main.
# Exit 2 blocks the command. The owner merges every PR.

export LC_ALL=C

block() {
  echo "Blocked by ystack guard: $1" >&2
  exit 2
}

# read returns 0 only if the input holds a NUL byte, which valid JSON never does.
if IFS= read -r -d '' input || ! cmd=$(
  set -o pipefail
  printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\000'
); then
  block "the hook could not read its input."
fi
[ -n "$cmd" ] || block "the hook got no command."

if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push[^|;&]*[[:space:]:+](refs/heads/)?main([[:space:]]|$)'; then
  block "no direct pushes to main. Push a branch and open a PR."
fi
# Lines are joined, so a backslash line break between `gh pr` and `merge` counts.
if printf '%s' "$cmd" | tr '\n' ' ' |
  grep -Eq 'gh[[:space:]]+pr([[:space:]]+[^|;&[:space:]]+)*[[:space:]]+merge([[:space:]]|$)'; then
  block "agents never merge PRs. The owner merges every PR."
fi
if printf '%s' "$cmd" | grep -Eq 'pulls/[^/[:space:]]+/merge|mergePullRequest|enablePullRequestAutoMerge'; then
  block "agents never merge PRs through the API. The owner merges every PR."
fi
if printf '%s' "$cmd" | grep -Eq 'rulesets|branches/[^/[:space:]]+/protection'; then
  if printf '%s' "$cmd" | grep -Eiq "(-X|--method|--request)[[:space:]=]*[\"']?(PUT|PATCH|POST|DELETE)"; then
    block "agents never change rulesets or branch protection."
  fi
  # gh api sends a POST when it has fields or an input file and no method.
  if printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+api' &&
    printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])(-[fF]|--field|--raw-field|--input)'; then
    block "agents never change rulesets or branch protection."
  fi
fi
exit 0
