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
read_message='Blocked by ystack guard: the hook could not read its input.'
command_check='tool_input.command does not equal the checked command'
agent_check='agent_id or agentId is set'
session_check='session_id is missing or not letters, digits and hyphens'
publisher_path_check='publisher file is missing, a symlink or not a regular file'
publisher_contents_check='publisher file does not name this session and repository'
passed=0
failed=0

hook_input() {
  local agent_fields=${3:-'{}'}
  jq -cn --arg cmd "$1" --arg session "${2-$session_id}" --argjson fields "$agent_fields" \
    '{tool_input: {command: $cmd}, session_id: $session} + $fields'
}

assert_hook() {
  assert_hook_stdin "$1" "$2" "${4-}" < <(printf '%s' "$3")
}

assert_hook_stdin() {
  local label=$1 expected_status=$2 expected_stderr=$3
  local status=0
  "$hook" >/dev/null 2>"$tmp/stderr" || status=$?
  if [[ $status == "$expected_status" ]] && cmp -s "$tmp/stderr" <(
    if [[ -n $expected_stderr ]]; then
      printf '%s\n' "$expected_stderr"
    fi
  ); then
    passed=$((passed + 1))
    printf 'PASS %s\n' "$label"
  else
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected exit %s and stderr [%s]\n  got exit %s and stderr [%s]\n' \
      "$label" "$expected_status" "$expected_stderr" "$status" "$(cat "$tmp/stderr")"
  fi
}

block_merge() {
  local label=$1
  shift
  assert_hook "$label" 2 "$(hook_input "$@")" "$merge_message"
}

pinned_message() {
  printf '%s\nPinned merge check failed: %s.' "$merge_message" "$1"
}

block_pinned_merge() {
  local label=$1 check=$2
  shift 2
  assert_hook "$label" 2 "$(hook_input "$@")" "$(pinned_message "$check")"
}

printf '%s' "$publisher_line" > "$publisher"
assert_hook 'exact pinned merge' 0 "$(hook_input "$cmd")"
printf '%s\n' "$publisher_line" > "$publisher"
assert_hook 'publisher line with one trailing newline' 0 "$(hook_input "$cmd")"
assert_hook 'null agent fields' 0 "$(hook_input "$cmd" "$session_id" '{"agent_id":null,"agentId":null}')"
assert_hook 'empty agent fields' 0 "$(hook_input "$cmd" "$session_id" '{"agent_id":"","agentId":""}')"

assert_hook 'agent type present' 0 "$(hook_input "$cmd" "$session_id" '{"agent_type":"reviewer"}')"
assert_hook 'numeric agent type' 0 "$(hook_input "$cmd" "$session_id" '{"agent_type":0}')"
assert_hook 'empty agent type' 0 "$(hook_input "$cmd" "$session_id" '{"agent_type":""}')"
assert_hook 'camelCase agent type present' 0 "$(hook_input "$cmd" "$session_id" '{"agentType":"reviewer"}')"
assert_hook 'numeric camelCase agent type' 0 "$(hook_input "$cmd" "$session_id" '{"agentType":0}')"
assert_hook 'empty camelCase agent type' 0 "$(hook_input "$cmd" "$session_id" '{"agentType":""}')"
block_pinned_merge 'agent ID present' "$agent_check" "$cmd" "$session_id" '{"agent_id":"subagent-1"}'
block_pinned_merge 'agent ID and type present' "$agent_check" "$cmd" "$session_id" \
  '{"agent_id":"subagent-1","agent_type":"reviewer"}'
block_pinned_merge 'boolean agent ID' "$agent_check" "$cmd" "$session_id" '{"agent_id":false}'
block_pinned_merge 'numeric agent ID' "$agent_check" "$cmd" "$session_id" '{"agent_id":0}'
block_pinned_merge 'object agent ID' "$agent_check" "$cmd" "$session_id" '{"agent_id":{}}'
block_pinned_merge 'camelCase agent ID present' "$agent_check" "$cmd" "$session_id" '{"agentId":"subagent-1"}'
block_pinned_merge 'camelCase agent ID and type present' "$agent_check" "$cmd" "$session_id" \
  '{"agentId":"subagent-1","agentType":"reviewer"}'
block_pinned_merge 'boolean camelCase agent ID' "$agent_check" "$cmd" "$session_id" '{"agentId":false}'
block_pinned_merge 'numeric camelCase agent ID' "$agent_check" "$cmd" "$session_id" '{"agentId":0}'
block_pinned_merge 'object camelCase agent ID' "$agent_check" "$cmd" "$session_id" '{"agentId":{}}'
block_pinned_merge 'empty session ID' "$session_check" "$cmd" ''
block_pinned_merge 'invalid session ID' "$session_check" "$cmd" 'manager_123'
block_pinned_merge 'session ID with trailing newline' "$session_check" "$cmd" "$session_id"$'\n'

mv "$publisher" "$tmp/publisher-target"
block_pinned_merge 'missing publisher file' "$publisher_path_check" "$cmd"
ln -s "$tmp/publisher-target" "$publisher"
block_pinned_merge 'publisher file is a symlink' "$publisher_path_check" "$cmd"
rm "$publisher"
mkdir "$publisher"
block_pinned_merge 'publisher path is a directory' "$publisher_path_check" "$cmd"
rmdir "$publisher"
printf 'other-session %s\n' "$repo" > "$publisher"
block_pinned_merge 'publisher names another session' "$publisher_contents_check" "$cmd"
printf '%s other/repo\n' "$session_id" > "$publisher"
block_pinned_merge 'publisher names another repository' "$publisher_contents_check" "$cmd"
printf '%s\nextra\n' "$publisher_line" > "$publisher"
block_pinned_merge 'publisher file has an extra line' "$publisher_contents_check" "$cmd"
printf '%s\n\n' "$publisher_line" > "$publisher"
block_pinned_merge 'publisher file has an extra blank line' "$publisher_contents_check" "$cmd"
printf '%s\0' "$publisher_line" > "$publisher"
block_pinned_merge 'publisher file has a NUL byte' "$publisher_contents_check" "$cmd"
printf '%s\n' "$publisher_line" > "$publisher"

block_merge 'semicolon and another command' "$cmd; echo x"
block_merge 'and operator and another command' "$cmd && true"
block_merge 'embedded newline' "$cmd"$'\necho x'
block_pinned_merge 'trailing newline' "$command_check" "$cmd"$'\n'
assert_hook 'NUL at the end of the JSON command' 2 "$(hook_input "$cmd" |
  jq -c '.tool_input.command += "\u0000"')" "$(pinned_message "$command_check")"
input=$(hook_input "$cmd")
assert_hook 'two JSON documents on stdin' 2 '{}'$'\n'"$input" \
  "$(pinned_message 'hook input is not exactly one JSON document')"
assert_hook 'two command documents on stdin' 2 "$input"$'\n'"$input" "$merge_message"
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
assert_hook 'printf redirects to the mixed-case publisher name' 2 \
  "$(hook_input "printf '%s\n' '$publisher_line' > '$HOME/.config/ystack/Merge-Publisher'")" "$publisher_message"
assert_hook 'ordinary command' 0 "$(hook_input 'git status')"
assert_hook 'empty input' 0 ''
assert_hook 'unfinished JSON input' 2 '{' "$read_message"
assert_hook 'non-JSON input' 2 'not json' "$read_message"
assert_hook 'JSON string input' 2 '"x"' "$read_message"
assert_hook 'JSON array input' 2 '[]' "$read_message"
assert_hook 'malformed input after a valid JSON document' 2 "$input"$'\n''{' "$read_message"
assert_hook_stdin 'raw NUL between ordinary and pinned command documents' 2 "$read_message" \
  < <(printf '%s\0%s' "$(hook_input 'git status')" "$input")
assert_hook_stdin 'raw NUL after pinned command document' 2 "$read_message" \
  < <(printf '%s\0' "$input")

available_locales=$(locale -a 2>/dev/null || true)
utf8_locale=$(awk 'tolower($0) ~ /utf-?8$/ { print; exit }' <<< "$available_locales")
if [[ -n $utf8_locale ]]; then
  LC_ALL="$utf8_locale" assert_hook 'exact pinned merge stays allowed in a UTF-8 locale' 0 "$input"
  invalid_byte_input=$(printf '{"tool_input":{"command":"echo \377; %s"},"session_id":"%s"}' "$cmd" "$session_id")
  LC_ALL="$utf8_locale" assert_hook 'merge with an invalid input byte stays blocked in a UTF-8 locale' 2 \
    "$invalid_byte_input" "$merge_message"
else
  printf 'PASS skipped UTF-8 locale cases (locale -a found no UTF-8 locale)\n'
fi

legacy_locale=$(awk 'tolower($0) ~ /\.(big5|gb18030|gbk)$/ { print; exit }' <<< "$available_locales")
if [[ -n $legacy_locale ]]; then
  LC_ALL="$legacy_locale" assert_hook "merge after a UTF-8 euro sign in $legacy_locale" 2 \
    "$(hook_input 'echo €;gh pr merge 1 --admin')" "$merge_message"
else
  printf 'PASS skipped legacy multibyte locale case (locale -a found no supported legacy locale)\n'
fi

XDG_CONFIG_HOME=config
block_pinned_merge 'relative XDG config with no file in the default directory' "$publisher_path_check" "$cmd"
mv "$publisher" "$HOME/.config/ystack/merge-publisher"
XDG_CONFIG_HOME=''
assert_hook 'publisher file in the default config directory' 0 "$(hook_input "$cmd")"
XDG_CONFIG_HOME="$tmp/empty-config"
mkdir "$XDG_CONFIG_HOME"
block_pinned_merge 'absolute XDG config without a publisher file does not fall back to HOME' \
  "$publisher_path_check" "$cmd"
XDG_CONFIG_HOME=config
assert_hook 'relative XDG config is ignored in favor of the default directory' 0 "$(hook_input "$cmd")"
unset XDG_CONFIG_HOME
HOME=home
block_pinned_merge 'relative HOME with XDG config unset' 'no absolute config directory' "$cmd"

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[[ $failed == 0 ]]
