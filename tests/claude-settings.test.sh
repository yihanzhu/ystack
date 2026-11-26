#!/bin/bash
# Checks that .claude/settings.json runs each guard hook on the tools it guards.
set -u

root=$(git rev-parse --show-toplevel)
settings="$root/.claude/settings.json"
failures=0

pass() { echo "ok - $1"; }
fail() { echo "not ok - $1"; failures=$((failures + 1)); }

# Checks that a PreToolUse entry whose matcher covers tool $1 runs hook $2.
# Claude Code matches a matcher against the whole tool name; "*" and an empty
# or missing matcher match every tool.
expect_hook() {
  local tool=$1 name=$2 command
  command="\"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/$name"
  if jq -e --arg tool "$tool" --arg command "$command" '
    [.hooks.PreToolUse[]?
     | select((.matcher // "") as $m
         | $m == "" or $m == "*" or ($tool | test("^(" + $m + ")$")))
     | .hooks[]? | select(.type == "command" and .command == $command)]
    | length > 0' "$settings" > /dev/null 2>&1; then
    pass "$tool runs $name"
  else
    fail "$tool runs $name"
  fi
}

expect_hook Bash no-merge-guard.sh
expect_hook Bash owner-only-guard.sh
expect_hook WebFetch owner-only-guard.sh

for name in no-merge-guard.sh owner-only-guard.sh; do
  if [ -f "$root/.claude/hooks/$name" ] && [ -x "$root/.claude/hooks/$name" ]; then
    pass "$name is an executable file"
  else
    fail "$name is an executable file"
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
