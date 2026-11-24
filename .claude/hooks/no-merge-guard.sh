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
[ -n "$cmd" ] || exit 0

if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push[^|;&]*[[:space:]:+](refs/heads/)?main([[:space:]]|$)'; then
  block "no direct pushes to main. Push a branch and open a PR."
fi
if printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge'; then
  block "agents never merge PRs. The owner merges every PR."
fi
if printf '%s' "$cmd" | grep -Eq 'pulls/[0-9]+/merge|mergePullRequest|enablePullRequestAutoMerge'; then
  block "agents never merge PRs through the API. The owner merges every PR."
fi
exit 0
