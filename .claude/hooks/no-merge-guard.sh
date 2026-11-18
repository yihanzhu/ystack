#!/bin/bash
# Allow one exact pinned merge form on the main thread only, with a matching
# operator-written publisher file. If any check fails, the merge stays blocked.
# Issue #275 comment 6966108607.

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
if [ -z "$cmd" ]; then
  exit 0
fi

# Any push whose refspec targets main (origin main, HEAD:main, +sha:refs/heads/main).
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push[^|;&]*[[:space:]:+](refs/heads/)?main([[:space:]]|$)'; then
  echo "Blocked by ystack guard: no direct pushes to main. Push a branch and open a PR." >&2
  exit 2
fi

allow_pinned_merge() (
  export LC_ALL=C
  shopt -u nocasematch
  merge_pattern='^gh pr merge [1-9][0-9]* --repo ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+) --squash --match-head-commit [0-9a-f]{40}$'
  [[ $cmd =~ $merge_pattern ]] || exit 1
  repo=${BASH_REMATCH[1]}

  # Command substitution can strip bytes. Check the original JSON string too.
  session_id=$(jq -ers --arg command "$cmd" '
    select(length == 1) | .[0]
    | select(.tool_input.command == $command
        and (.agent_id == null or .agent_id == "")
        and (.agent_type == null or .agent_type == ""))
    | .session_id | strings | select(test("\\A[A-Za-z0-9-]+\\z"))
  ' <<< "$input") || exit 1

  publisher=${XDG_CONFIG_HOME:-$HOME/.config}/ystack/merge-publisher
  [[ -f $publisher && ! -L $publisher ]] || exit 1
  printf '%s %s' "$session_id" "$repo" | cmp -s -- "$publisher" - ||
    printf '%s %s\n' "$session_id" "$repo" | cmp -s -- "$publisher" -
)
if allow_pinned_merge; then
  exit 0
fi

if printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge'; then
  echo "Blocked by ystack guard: agents never merge PRs. The operator merges at the gate." >&2
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
