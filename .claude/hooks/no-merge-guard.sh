#!/bin/bash
# PreToolUse guard for Bash. It blocks pushes to main, PR merges, and changes to
# rulesets or branch protection. Exit 2 blocks the command. The session that
# wrote a PR never merges it; see "The owner's OK" in AGENTS.md.

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

# Backslash line breaks are removed, as bash removes them. grep reads line by
# line, so each line of `joined` is one command line.
joined=${cmd//$'\\\n'/}

# Flags with an optional value, as in `-R o/r`, `--repo=o/r` or `-C "a dir"`.
flags="([[:space:]]+-[^[:space:]]*([[:space:]]+(\"[^\"]*\"|'[^']*'|[^-[:space:]|;&\"'][^[:space:]|;&]*))?)*"
merge_msg="this session may not merge PRs. The session that wrote a PR never merges it."
gate_msg="this session may not change rulesets or branch protection."

if printf '%s' "$joined" |
  grep -Eq "git${flags}[[:space:]]+push[^|;&]*[[:space:]:+\"'](refs/heads/)?main([^[:alnum:]_./:-]|\$)"; then
  block "no direct pushes to main. Push a branch and open a PR."
fi
if printf '%s' "$joined" |
  grep -Eq "gh${flags}[[:space:]]+pr${flags}[[:space:]]+[\"']?merge([^[:alnum:]_-]|\$)"; then
  block "$merge_msg"
fi
if printf '%s' "$cmd" | grep -Eq 'pulls/[^/[:space:]]+/merge|mergePullRequest|enablePullRequestAutoMerge'; then
  block "$merge_msg"
fi
if printf '%s' "$cmd" | grep -q graphql &&
  printf '%s' "$cmd" | grep -Eq '(create|update|delete)(RepositoryRuleset|BranchProtectionRule)'; then
  block "$gate_msg"
fi

# REST writes to the gate, read one command at a time: the parts between |, ;, &
# and line breaks. Redirections such as 2>&1 are not command breaks. The flag is
# case-sensitive (`grep -x` is not `-X`); the method is not.
parts=${joined//&>/>}
parts=${parts//>&/>}
parts=${parts//<&/<}
method_flag='(^|[[:space:]])(-X|--method|--request)'
write_method="${method_flag}[[:space:]=]*[\"']?([Pp][Uu][Tt]|[Pp][Aa][Tt][Cc][Hh]|[Pp][Oo][Ss][Tt]|[Dd][Ee][Ll][Ee][Tt][Ee])"
while IFS= read -r part; do
  printf '%s' "$part" | grep -Eq '/rulesets([^[:alnum:]_-]|$)|branches/[^/[:space:]]+/protection' || continue
  if printf '%s' "$part" | grep -Eq "$write_method"; then
    block "$gate_msg"
  fi
  # gh api sends a POST when it has fields or an input file and no method.
  if ! printf '%s' "$part" | grep -Eq "$method_flag" &&
    printf '%s' "$part" | grep -Eq 'gh[[:space:]]+api' &&
    printf '%s' "$part" | grep -Eq '(^|[[:space:]])(-[fF]|--field|--raw-field|--input)'; then
    block "$gate_msg"
  fi
done < <(printf '%s\n' "$parts" | tr '|;&' '\n')
exit 0
