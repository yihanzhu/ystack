#!/bin/bash
# Installs the kit for Claude Code and Codex on this machine. Safe to run again.
#
#   kit/install.sh          install or refresh
#   kit/install.sh --check  exit 0 if the installed copy is current, 1 if not; change nothing
#
# It changes only:
#  - the block between its marker lines in ~/.claude/CLAUDE.md (imports of kit/rules),
#  - the block between its marker lines in ~/.codex/AGENTS.md (kit/rules written in,
#    because Codex has no imports),
#  - links named kit/skills/<name> in ~/.claude/skills and ~/.agents/skills,
#  - the parked yshifu command in ~/.claude/commands.
# All other text and files stay byte for byte. It checks everything before it writes
# anything, and it replaces each file in one rename. It writes nothing into this repo.

set -euo pipefail

begin_prefix='<!-- ystack kit: begin'
begin_line="$begin_prefix (kit/install.sh writes this block; change the kit, not this) -->"
end_line='<!-- ystack kit: end -->'
yshifu_header='---
description: Summon yshifu, the dev-team manager, for the current repo
---'
check=false

case ${1:-} in
  '') ;;
  --check) check=true ;;
  *) echo "usage: kit/install.sh [--check]" >&2; exit 2 ;;
esac

fail() {
  echo "kit/install.sh: $1" >&2
  exit 2
}

# Names a path as ~/... when it is under HOME.
shown() {
  # shellcheck disable=SC2088 # A literal ~ is the point: agents expand it.
  case $1 in
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

kit=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d) || exit 2
temps=()
cleanup() {
  local tmp
  rm -rf "$work"
  for tmp in ${temps[@]+"${temps[@]}"}; do
    rm -f -- "$tmp"
  done
}
trap cleanup EXIT

# The agents must load the kit from a lasting main checkout, not a linked worktree.
command -v git > /dev/null || fail "git is required."
git_dir=$(git -C "$kit" rev-parse --absolute-git-dir 2> /dev/null) ||
  fail "the kit must be inside a Git checkout."
common_dir=$(cd "$kit" && cd "$(git rev-parse --git-common-dir)" && pwd -P) ||
  fail "cannot find the checkout's Git directory."
[ "$(cd "$git_dir" && pwd -P)" = "$common_dir" ] ||
  fail "run this from the main checkout, not from a linked worktree."

rules=$(shown "$kit/rules")
case $rules in
  *[[:space:]]*) fail "the kit path holds white space, which an @ import cannot carry. Move the checkout." ;;
esac
for f in working-preferences.md claude.md codex.md; do
  [ -s "$kit/rules/$f" ] || fail "kit/rules/$f is missing."
done

# Sets resolved to the regular file that a path names, following links. A link to
# a missing file, a path that is not a regular file, or a link that cannot be
# followed exactly (a target name ending in a newline) stops the install.
target_of() {
  local path=$1 next hops=0
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 20 ] || fail "$(shown "$1") has too many links."
    next=$(readlink "$path") || fail "cannot read the link $(shown "$1")."
    case $next in
      /*) path=$next ;;
      *) path=$(dirname "$path")/$next ;;
    esac
  done
  if [ -L "$1" ] && [ ! -e "$path" ]; then
    fail "$(shown "$1") is a link to a missing file."
  fi
  if [ -L "$1" ] && [ ! "$path" -ef "$1" ]; then
    fail "cannot follow the link $(shown "$1") exactly."
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    fail "$(shown "$1") is not a regular file."
  fi
  resolved=$path
}

# Writes into $3 the next content of target $1 with the block in $2. Changes nothing.
render() {
  local target=$1 block=$2 next=$3 marks begins ends
  if [ ! -e "$target" ]; then
    cp "$block" "$next"
    return
  fi
  cp "$target" "$next.before" || fail "cannot read $(shown "$target")."
  # One line per marker: "b N", "e N", or "x N" for a line that looks like a marker
  # but is not exactly one. A trailing carriage return is ignored.
  awk -v bl="$begin_line" -v el="$end_line" '
    { line = $0; sub(/\r$/, "", line) }
    line == bl { print "b " NR; next }
    line == el { print "e " NR; next }
    index(line, "ystack kit:") { print "x " NR }' "$target" > "$work/marks" ||
    fail "cannot read $(shown "$target")."
  marks=$(cut -d' ' -f1 "$work/marks" | tr -d '\n')
  case $marks in
    '')
      {
        cat "$target"
        [ ! -s "$target" ] || [ -z "$(tail -c 1 "$target")" ] || echo
        [ ! -s "$target" ] || echo
        cat "$block"
      } > "$next"
      ;;
    be)
      begins=$(awk '$1 == "b" { print $2 }' "$work/marks")
      ends=$(awk '$1 == "e" { print $2 }' "$work/marks")
      {
        [ "$begins" -eq 1 ] || head -n "$((begins - 1))" "$target"
        cat "$block"
        tail -n "+$((ends + 1))" "$target"
      } > "$next"
      ;;
    *) fail "$(shown "$target") has broken, extra or out-of-order kit markers. Fix it by hand." ;;
  esac
}

# Copies the next content of target $1 (file $2) to a new file beside the target,
# keeping the target's mode, and sets staged to its path. Renames happen later.
stage() {
  local target=$1 next=$2 dir
  dir=$(dirname "$target")
  mkdir -p "$dir" 2> /dev/null || fail "cannot create $(shown "$dir")."
  staged=$(mktemp "$dir/.ystack-kit.XXXXXX" 2> /dev/null) || fail "cannot write in $(shown "$dir")."
  temps+=("$staged")
  if [ -e "$target" ]; then
    cp -p "$target" "$staged" || fail "cannot copy $(shown "$target")."
  fi
  cat "$next" > "$staged" || fail "cannot write in $(shown "$dir")."
}

# Stops if target $1 changed since it was read into $2.before.
unchanged_since_read() {
  local target=$1 next=$2
  if [ -e "$next.before" ]; then
    cmp -s "$next.before" "$target" || fail "$(shown "$target") changed while installing. Run again."
  else
    [ ! -e "$target" ] || fail "$(shown "$target") appeared while installing. Run again."
  fi
}

{
  echo "$begin_line"
  echo "@$rules/working-preferences.md"
  echo "@$rules/claude.md"
  echo "$end_line"
} > "$work/claude-block"
{
  echo "$begin_line"
  cat "$kit/rules/working-preferences.md"
  echo
  cat "$kit/rules/codex.md"
  echo "$end_line"
} > "$work/codex-block"

target_of "$HOME/.claude/CLAUDE.md"
claude_file=$resolved
target_of "$HOME/.codex/AGENTS.md"
codex_file=$resolved
if [ -e "$claude_file" ] && [ "$claude_file" -ef "$codex_file" ]; then
  fail "the Claude and Codex rule files are the same file; each needs its own block."
fi
render "$claude_file" "$work/claude-block" "$work/claude-next"
render "$codex_file" "$work/codex-block" "$work/codex-next"

# Plans the skill links. A kit link is one whose target is exactly
# kit/skills/<its own name>. Two destination names for one folder count once.
dests=("$HOME/.claude/skills")
if [ -d "$HOME/.claude/skills" ] && [ -d "$HOME/.agents/skills" ] &&
  [ "$HOME/.claude/skills" -ef "$HOME/.agents/skills" ]; then
  :
else
  dests+=("$HOME/.agents/skills")
fi
adds=()
drops=()
for dest in "${dests[@]}"; do
  if [ -d "$dest" ]; then
    for link in "$dest"/*; do
      [ -L "$link" ] || continue
      name=$(basename "$link")
      [ "$(readlink "$link")" = "$kit/skills/$name" ] || continue
      [ -f "$kit/skills/$name/SKILL.md" ] || drops+=("$link")
    done
  fi
  for skill in "$kit"/skills/*/; do
    name=$(basename "$skill")
    [ -f "$kit/skills/$name/SKILL.md" ] || continue
    link=$dest/$name
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$kit/skills/$name" ]; then
      continue
    fi
    if [ -e "$link" ] || [ -L "$link" ]; then
      fail "$(shown "$link") exists and is not this kit's link. Remove it by hand."
    fi
    adds+=("$link")
  done
done

is_parked_command() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(head -n 3 "$1")" = "$yshifu_header" ]
}
parked=()
for file in "$HOME/.claude/commands/yshifu.md" "$HOME/.claude/commands/yshifu.md.bak"; do
  if is_parked_command "$file"; then
    parked+=("$file")
  fi
done

if $check; then
  stale=0
  cmp -s "$work/claude-next" "$claude_file" || { echo "stale: ~/.claude/CLAUDE.md"; stale=1; }
  cmp -s "$work/codex-next" "$codex_file" || { echo "stale: ~/.codex/AGENTS.md"; stale=1; }
  for path in ${adds[@]+"${adds[@]}"}; do
    echo "stale: missing link $(shown "$path")"
    stale=1
  done
  for path in ${drops[@]+"${drops[@]}"}; do
    echo "stale: extra link $(shown "$path")"
    stale=1
  done
  for path in ${parked[@]+"${parked[@]}"}; do
    echo "stale: parked $(shown "$path")"
    stale=1
  done
  [ "$stale" = 0 ] || exit 1
  echo "kit/install.sh: the installed kit is current."
  exit 0
fi

# Stage every file change first, so a write failure stops before any rename.
claude_tmp=''
codex_tmp=''
if ! cmp -s "$work/claude-next" "$claude_file"; then
  stage "$claude_file" "$work/claude-next"
  claude_tmp=$staged
fi
if ! cmp -s "$work/codex-next" "$codex_file"; then
  stage "$codex_file" "$work/codex-next"
  codex_tmp=$staged
fi
[ -z "$claude_tmp" ] || unchanged_since_read "$claude_file" "$work/claude-next"
[ -z "$codex_tmp" ] || unchanged_since_read "$codex_file" "$work/codex-next"
if [ -n "$claude_tmp" ]; then
  mv -f "$claude_tmp" "$claude_file"
  echo "updated: ~/.claude/CLAUDE.md"
fi
if [ -n "$codex_tmp" ]; then
  mv -f "$codex_tmp" "$codex_file"
  echo "updated: ~/.codex/AGENTS.md"
fi

for path in ${adds[@]+"${adds[@]}"}; do
  name=$(basename "$path")
  [ ! -e "$path" ] && [ ! -L "$path" ] || fail "$(shown "$path") appeared while installing. Run again."
  mkdir -p "$(dirname "$path")"
  ln -s "$kit/skills/$name" "$path"
  echo "linked: $(shown "$path")"
done
for path in ${drops[@]+"${drops[@]}"}; do
  name=$(basename "$path")
  [ -L "$path" ] && [ "$(readlink "$path")" = "$kit/skills/$name" ] ||
    fail "$(shown "$path") changed while installing. Run again."
  rm -- "$path"
  echo "removed: $(shown "$path")"
done
for path in ${parked[@]+"${parked[@]}"}; do
  is_parked_command "$path" || fail "$(shown "$path") changed while installing. Run again."
  rm -- "$path"
  echo "removed the parked yshifu command: $(shown "$path")"
done
