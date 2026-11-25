#!/bin/bash
# PreToolUse guard for Bash, live in every Claude Code session opened in a
# ystack checkout. It blocks PR merges, pushes to main, and changes to rulesets,
# branch protection or the default branch. Exit 2 blocks the command. The
# session that wrote a PR never merges it; a reviewing session outside this repo
# merges approved PRs (AGENTS.md, "The owner's OK").
#
# It runs on every Bash call, so it uses bash tests and no subprocess after jq.

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

# Backslash line breaks are removed, as bash removes them.
joined=${cmd//$'\\\n'/}

guarded_words='push|[Mm]erge|graphql|rulesets|protection|default[-_]branch'
[[ $joined =~ $guarded_words ]] || exit 0

merge_msg="no PR merges from a ystack session. The session that wrote a PR never merges it; a reviewing session outside this repo merges approved PRs."
gate_msg="no changes to rulesets, branch protection or the default branch from a ystack session."

graphql_merge='mergePullRequest|enablePullRequestAutoMerge'
graphql_gate='(create|update|delete)(RepositoryRuleset|BranchProtectionRule)'
[[ $joined =~ $graphql_merge ]] && block "$merge_msg"
if [[ $joined == *graphql* ]] && [[ $joined =~ $graphql_gate ]]; then
  block "$gate_msg"
fi

# A flag with an optional value, as in `-R o/r`, `--repo=o/r` or `-C "a dir"`.
flags="([[:space:]]+-[^[:space:]]*([[:space:]]+(\"[^\"]*\"|'[^']*'|[^-[:space:]|;&\"'][^[:space:]|;&]*))?)*"
push_main="git${flags}[[:space:]]+push[^|;&]*[[:space:]:+\"'](refs/heads/)?main([^[:alnum:]_./:-]|\$)"
pr_merge="gh${flags}[[:space:]]+pr${flags}[[:space:]]+[\"']?merge([^[:alnum:]_-]|\$)"
repo_edit="gh${flags}[[:space:]]+repo${flags}[[:space:]]+edit([^[:alnum:]_-]|\$)"

# One command: quoted strings, escaped characters, and other characters up to
# |, ; or &.
part_re="^(\"([^\"\\\\]|\\\\.)*\"|'[^']*'|\\\\.|[^|;&\"'\\\\])*"
# The PR number may be a word, a variable or a command substitution.
rest_merge="pulls/([^/[:space:]]+|\\\$\\([^)]*\\)|\`[^\`]*\`)/merge([^[:alnum:]_-]|\$)"
gate_path="/rulesets([^[:alnum:]_-]|\$)|branches/[^/[:space:]]+/protection|default_branch"
# Grouped short flags count too, as in -iX or -if. The value ends at a space,
# a closing parenthesis, a backquote or a redirection.
method_re="(^|[[:space:]])(-[A-Za-z]*X|--method|--request)([[:space:]]+|=)?([^[:space:])\`<>]*)"
read_method="^[\"']?([Gg][Ee][Tt]|[Hh][Ee][Aa][Dd])[\"']?\$"
field_re="(^|[[:space:]])(-[A-Za-z]*[fF]|--field|--raw-field|--input)"
gh_api='gh[[:space:]]+api'

check_part() {
  local part=$1 rest has_method=false
  [[ $part == *pulls/*/merge* ]] && [[ $part =~ $rest_merge ]] && block "$merge_msg"
  if [[ $part == *--default-branch* ]] && [[ $part =~ $repo_edit ]]; then
    block "$gate_msg"
  fi
  [[ $part =~ $gate_path ]] || return 0
  # A method that is not literally GET or HEAD counts as a write, so "$M" does.
  rest=$part
  while [[ $rest =~ $method_re ]]; do
    has_method=true
    [[ ${BASH_REMATCH[4]} =~ $read_method ]] || block "$gate_msg"
    rest=${rest#*"${BASH_REMATCH[0]}"}
  done
  # gh api sends a POST when it has fields or an input file and no method.
  if ! $has_method && [[ $part =~ $gh_api ]] && [[ $part =~ $field_re ]]; then
    block "$gate_msg"
  fi
}

# Split into lines in memory: a here-string needs a temporary file in bash 3.2,
# and a failed one would skip the loop.
set -f
IFS=$'\n'
# shellcheck disable=SC2206 # Splitting on line breaks is the point; set -f stops globbing.
lines=($joined)
IFS=$' \t\n'
set +f
for line in ${lines[@]+"${lines[@]}"}; do
  [[ $line =~ $guarded_words ]] || continue
  if [[ $line == *push* ]] && [[ $line =~ $push_main ]]; then
    block "no direct pushes to main. Push a branch and open a PR."
  fi
  if [[ $line == *merge* ]] && [[ $line =~ $pr_merge ]]; then
    block "$merge_msg"
  fi
  # Redirections such as 2>&1 are not command breaks.
  rest=${line//&>/>}
  rest=${rest//>&/>}
  rest=${rest//<&/<}
  while [ -n "$rest" ]; do
    [[ $rest =~ $part_re ]]
    part=${BASH_REMATCH[0]}
    check_part "$part"
    # Drop the part and the character that ended it.
    rest=${rest:$((${#part} + 1))}
  done
done
exit 0
