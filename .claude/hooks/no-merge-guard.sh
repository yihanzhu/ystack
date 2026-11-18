#!/bin/bash
# PreToolUse guard for Bash. Blocks direct pushes to main and agent merges.
# Exit 2 blocks the command.
# Allow one exact pinned merge form on the main thread only (no agent_id or agentId),
# with a matching operator-written publisher file. If any check fails, block.
# Issue #275 comment 6966108607.
# Issue #275 comment 6981243584.
# Defense in depth under ystack-main-gate and the only guard in clones without it.
# merge-pr.sh stays blocked because its old exemption became a bypass.

export LC_ALL=C

# Bash strings cannot hold a raw NUL, which is invalid in JSON.
if IFS= read -r -d '' input || ! cmd=$(
  set -o pipefail
  printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\000'
); then
  echo "Blocked by ystack guard: the hook could not read its input." >&2
  exit 2
fi
if [ -z "$cmd" ]; then
  exit 0
fi

# Any push whose refspec targets main (origin main, HEAD:main, +sha:refs/heads/main).
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push[^|;&]*[[:space:]:+](refs/heads/)?main([[:space:]]|$)'; then
  echo "Blocked by ystack guard: no direct pushes to main. Push a branch and open a PR." >&2
  exit 2
fi

if printf '%s' "$cmd" | grep -Fqi 'merge-publisher'; then
  echo "Blocked by ystack guard: the merge publisher file is the operator's to write." >&2
  exit 2
fi

allow_pinned_merge() (
  fail_pinned_merge() {
    printf 'Pinned merge check failed: %s.\n' "$1"
    exit 1
  }

  shopt -u nocasematch
  merge_pattern='^gh pr merge [1-9][0-9]* --repo ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+) --squash --match-head-commit [0-9a-f]{40}$'
  [[ $cmd =~ $merge_pattern ]] || exit 1
  repo=${BASH_REMATCH[1]}

  jq -es 'length == 1' <<< "$input" >/dev/null 2>&1 ||
    fail_pinned_merge 'hook input is not exactly one JSON document'
  # Command substitution can strip bytes. Check the original JSON string too.
  jq -e --arg command "$cmd" '.tool_input.command == $command' <<< "$input" >/dev/null 2>&1 ||
    fail_pinned_merge 'tool_input.command does not equal the checked command'
  jq -e '(.agent_id == null or .agent_id == "") and (.agentId == null or .agentId == "")' \
    <<< "$input" >/dev/null 2>&1 ||
    fail_pinned_merge 'agent_id or agentId is set'
  session_id=$(jq -er '.session_id | strings | select(test("\\A[A-Za-z0-9-]+\\z"))' \
    <<< "$input" 2>/dev/null) ||
    fail_pinned_merge 'session_id is missing or not letters, digits and hyphens'

  if [[ $XDG_CONFIG_HOME == /* ]]; then
    config_dir=$XDG_CONFIG_HOME
  elif [[ $HOME == /* ]]; then
    config_dir=$HOME/.config
  else
    fail_pinned_merge 'no absolute config directory'
  fi
  publisher=$config_dir/ystack/merge-publisher
  [[ -f $publisher && ! -L $publisher ]] ||
    fail_pinned_merge 'publisher file is missing, a symlink or not a regular file'
  printf '%s %s' "$session_id" "$repo" | cmp -s -- "$publisher" - ||
    printf '%s %s\n' "$session_id" "$repo" | cmp -s -- "$publisher" - ||
    fail_pinned_merge 'publisher file does not name this session and repository'
)
if pinned_failure=$(allow_pinned_merge); then
  exit 0
fi

if printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge'; then
  echo "Blocked by ystack guard: agents never merge PRs. The operator merges at the gate." >&2
  if [[ -n $pinned_failure ]]; then
    printf '%s\n' "$pinned_failure" >&2
  fi
  exit 2
fi
if printf '%s' "$cmd" | grep -Eq 'merge-pr\.sh'; then
  echo "Blocked by ystack guard: merge-pr.sh is the operator's own tool. Apply merge-ready and hand the PR over." >&2
  exit 2
fi
if printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+api[[:space:]][^|;&]*pulls/[0-9]+/merge'; then
  echo "Blocked by ystack guard: agents never merge PRs via the API. A human merges at the gate." >&2
  exit 2
fi

exit 0
