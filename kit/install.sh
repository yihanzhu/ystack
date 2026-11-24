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
trap 'rm -rf "$work"' EXIT

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

# Prints the regular file that a path names, following links. A link to a missing
# file or a path that is not a regular file stops the install.
target_of() {
  local path=$1 next hops=0
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 20 ] || fail "$(shown "$1") has too many links."
    next=$(readlink "$path")
    case $next in
      /*) path=$next ;;
      *) path=$(dirname "$path")/$next ;;
    esac
  done
  if [ -L "$1" ] && [ ! -e "$path" ]; then
    fail "$(shown "$1") is a link to a missing file."
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    fail "$(shown "$1") is not a regular file."
  fi
  printf '%s' "$path"
}

# Writes into $3 the next content of target $1 with the block in $2. Changes nothing.
render() {
  local target=$1 block=$2 next=$3 marks begins ends
  if [ ! -e "$target" ]; then
    cp "$block" "$next"
    return
  fi
  # One line per marker: "b N", "e N", or "x N" for a line that looks like a marker
  # but is not exactly one. A trailing carriage return is ignored.
  awk -v bp="$begin_prefix" -v el="$end_line" '
    { line = $0; sub(/\r$/, "", line) }
    index(line, bp) == 1 && line ~ /-->$/ { print "b " NR; next }
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

# Replaces target $1 with file $2 in one rename, keeping the target's mode.
replace() {
  local target=$1 next=$2 tmp
  mkdir -p "$(dirname "$target")"
  tmp=$(mktemp "$(dirname "$target")/.ystack-kit.XXXXXX")
  if [ -e "$target" ]; then
    cp -p "$target" "$tmp"
  fi
  cat "$next" > "$tmp"
  mv -f "$tmp" "$target"
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

claude_file=$(target_of "$HOME/.claude/CLAUDE.md")
codex_file=$(target_of "$HOME/.codex/AGENTS.md")
if [ -e "$claude_file" ] && [ "$claude_file" -ef "$codex_file" ]; then
  fail "the Claude and Codex rule files are the same file; each needs its own block."
fi
render "$claude_file" "$work/claude-block" "$work/claude-next"
render "$codex_file" "$work/codex-block" "$work/codex-next"

# Plans the skill links. A kit link is one whose target is exactly
# kit/skills/<its own name>. Lines in $work/links: "add PATH" or "drop PATH".
: > "$work/links"
for dest in "$HOME/.claude/skills" "$HOME/.agents/skills"; do
  if [ -d "$dest" ]; then
    for link in "$dest"/*; do
      [ -L "$link" ] || continue
      name=$(basename "$link")
      [ "$(readlink "$link")" = "$kit/skills/$name" ] || continue
      [ -f "$kit/skills/$name/SKILL.md" ] || echo "drop $link" >> "$work/links"
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
    echo "add $link" >> "$work/links"
  done
done

: > "$work/parked"
for file in "$HOME/.claude/commands/yshifu.md" "$HOME/.claude/commands/yshifu.md.bak"; do
  if [ -f "$file" ] && [ ! -L "$file" ] && [ "$(head -n 3 "$file")" = "$yshifu_header" ]; then
    echo "$file" >> "$work/parked"
  fi
done

if $check; then
  stale=0
  cmp -s "$work/claude-next" "$claude_file" || { echo "stale: ~/.claude/CLAUDE.md"; stale=1; }
  cmp -s "$work/codex-next" "$codex_file" || { echo "stale: ~/.codex/AGENTS.md"; stale=1; }
  while read -r action path; do
    echo "stale: $action $(shown "$path")"
    stale=1
  done < "$work/links"
  while IFS= read -r file; do
    echo "stale: parked $(shown "$file")"
    stale=1
  done < "$work/parked"
  [ "$stale" = 0 ] || exit 1
  echo "kit/install.sh: the installed kit is current."
  exit 0
fi

if ! cmp -s "$work/claude-next" "$claude_file"; then
  replace "$claude_file" "$work/claude-next"
  echo "updated: ~/.claude/CLAUDE.md"
fi
if ! cmp -s "$work/codex-next" "$codex_file"; then
  replace "$codex_file" "$work/codex-next"
  echo "updated: ~/.codex/AGENTS.md"
fi
while read -r action path; do
  name=$(basename "$path")
  if [ "$action" = add ]; then
    mkdir -p "$(dirname "$path")"
    ln -s "$kit/skills/$name" "$path"
    echo "linked: $(shown "$path")"
  else
    rm -- "$path"
    echo "removed: $(shown "$path")"
  fi
done < "$work/links"
while IFS= read -r file; do
  rm -- "$file"
  echo "removed the parked yshifu command: $(shown "$file")"
done < "$work/parked"
