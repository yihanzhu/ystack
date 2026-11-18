#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
CDPATH=''

test_dir=$(cd "$(dirname "$0")" && pwd -P)
hook="$test_dir/../../.claude/hooks/no-merge-guard.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config"
mkdir -p "$HOME/.config/ystack" "$XDG_CONFIG_HOME/ystack"
publisher="$XDG_CONFIG_HOME/ystack/merge-publisher"
cd "$tmp"

session_id=manager-123
repo=org-name/ystack.repo_test
sha=0123456789abcdef0123456789abcdef01234567
cmd="gh pr merge 12 --repo $repo --squash --match-head-commit $sha"
publisher_line="$session_id $repo"
merge_message='Blocked by ystack guard: agents never merge PRs. The operator merges at the gate.'
publisher_message="Blocked by ystack guard: the merge publisher file is the operator's to write."
passed=0
failed=0

hook_input() {
  local agent_fields=${3:-'{}'}
  jq -cn --arg cmd "$1" --arg session "${2-$session_id}" --argjson fields "$agent_fields" \
    '{tool_input: {command: $cmd}, session_id: $session} + $fields'
}

assert_hook() {
  local label=$1 expected_status=$2 input=$3 expected_stderr=${4-}
  local status=0 stderr
  printf '%s' "$input" | "$hook" >/dev/null 2>"$tmp/stderr" || status=$?
  stderr=$(cat "$tmp/stderr")
  if [[ $status == "$expected_status" && $stderr == "$expected_stderr" ]]; then
    passed=$((passed + 1))
    printf 'PASS %s\n' "$label"
  else
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected exit %s and stderr [%s]\n  got exit %s and stderr [%s]\n' \
      "$label" "$expected_status" "$expected_stderr" "$status" "$stderr"
  fi
}

block_merge() {
  local label=$1
  shift
  assert_hook "$label" 2 "$(hook_input "$@")" "$merge_message"
}

printf '%s' "$publisher_line" > "$publisher"
assert_hook 'exact pinned merge' 0 "$(hook_input "$cmd")"
printf '%s\n' "$publisher_line" > "$publisher"
assert_hook 'publisher line with one trailing newline' 0 "$(hook_input "$cmd")"
assert_hook 'null agent fields' 0 "$(hook_input "$cmd" "$session_id" '{"agent_id":null,"agent_type":null}')"
assert_hook 'empty agent fields' 0 "$(hook_input "$cmd" "$session_id" '{"agent_id":"","agent_type":""}')"

block_merge 'agent ID present' "$cmd" "$session_id" '{"agent_id":"subagent-1"}'
block_merge 'agent type present' "$cmd" "$session_id" '{"agent_type":"reviewer"}'
block_merge 'non-string agent field' "$cmd" "$session_id" '{"agent_id":false}'
block_merge 'numeric agent type' "$cmd" "$session_id" '{"agent_type":0}'
block_merge 'camelCase agent ID present' "$cmd" "$session_id" '{"agentId":"subagent-1"}'
block_merge 'camelCase agent type present' "$cmd" "$session_id" '{"agentType":"reviewer"}'
block_merge 'empty session ID' "$cmd" ''
block_merge 'invalid session ID' "$cmd" 'manager_123'
block_merge 'session ID with trailing newline' "$cmd" "$session_id"$'\n'

mv "$publisher" "$tmp/publisher-target"
block_merge 'missing publisher file' "$cmd"
ln -s "$tmp/publisher-target" "$publisher"
block_merge 'publisher file is a symlink' "$cmd"
rm "$publisher"
mkdir "$publisher"
block_merge 'publisher path is a directory' "$cmd"
rmdir "$publisher"
printf 'other-session %s\n' "$repo" > "$publisher"
block_merge 'publisher names another session' "$cmd"
printf '%s other/repo\n' "$session_id" > "$publisher"
block_merge 'publisher names another repository' "$cmd"
printf '%s\nextra\n' "$publisher_line" > "$publisher"
block_merge 'publisher file has an extra line' "$cmd"
printf '%s\n\n' "$publisher_line" > "$publisher"
block_merge 'publisher file has an extra blank line' "$cmd"
printf '%s\0' "$publisher_line" > "$publisher"
block_merge 'publisher file has a NUL byte' "$cmd"
printf '%s\n' "$publisher_line" > "$publisher"

block_merge 'semicolon and another command' "$cmd; echo x"
block_merge 'and operator and another command' "$cmd && true"
block_merge 'embedded newline' "$cmd"$'\necho x'
block_merge 'trailing newline' "$cmd"$'\n'
assert_hook 'NUL at the end of the JSON command' 2 "$(hook_input "$cmd" |
  jq -c '.tool_input.command += "\u0000"')" "$merge_message"
input=$(hook_input "$cmd")
assert_hook 'two JSON documents on stdin' 2 "$input"$'\n'"$input" "$merge_message"
block_merge 'leading space' " $cmd"
block_merge 'admin flag' "$cmd --admin"
block_merge 'auto flag' "$cmd --auto"
block_merge 'merge flag' "${cmd/--squash/--merge}"
block_merge 'rebase flag' "${cmd/--squash/--rebase}"
block_merge 'flags in another order' "gh pr merge 12 --squash --repo $repo --match-head-commit $sha"
block_merge 'no repo flag' "gh pr merge 12 --squash --match-head-commit $sha"
block_merge '39-character SHA' "${cmd%?}"
block_merge 'uppercase SHA' "${cmd/abcdef/ABCDEF}"
block_merge 'PR number zero' "${cmd/merge 12/merge 0}"
block_merge 'PR number with a leading zero' "${cmd/merge 12/merge 01}"

assert_hook 'merge through the API' 2 "$(hook_input 'gh api --method PUT repos/o/r/pulls/1/merge')" \
  'Blocked by ystack guard: agents never merge PRs via the API. A human merges at the gate.'
assert_hook 'merge helper' 2 "$(hook_input 'scripts/merge-pr.sh 1')" \
  "Blocked by ystack guard: merge-pr.sh is the operator's own tool. Apply merge-ready and hand the PR over."
assert_hook 'direct push to main' 2 "$(hook_input 'git push origin main')" \
  'Blocked by ystack guard: no direct pushes to main. Push a branch and open a PR.'
assert_hook 'push rule takes precedence over merge rule' 2 "$(hook_input "$cmd; git push origin main")" \
  'Blocked by ystack guard: no direct pushes to main. Push a branch and open a PR.'
assert_hook 'cat names the full publisher path' 2 "$(hook_input "cat '$publisher'")" "$publisher_message"
assert_hook 'printf redirects to the bare publisher name' 2 \
  "$(hook_input 'printf "%s\n" "manager-123 o/r" > merge-publisher')" "$publisher_message"
assert_hook 'ordinary command' 0 "$(hook_input 'git status')"
assert_hook 'empty input' 0 ''

XDG_CONFIG_HOME=config
block_merge 'relative XDG config with no file in the default directory' "$cmd"
mv "$publisher" "$HOME/.config/ystack/merge-publisher"
XDG_CONFIG_HOME=''
assert_hook 'publisher file in the default config directory' 0 "$(hook_input "$cmd")"
XDG_CONFIG_HOME=config
assert_hook 'relative XDG config is ignored in favor of the default directory' 0 "$(hook_input "$cmd")"
unset XDG_CONFIG_HOME
HOME=home
block_merge 'relative HOME with XDG config unset' "$cmd"

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[[ $failed == 0 ]]
