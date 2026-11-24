#!/bin/bash
# Installs the kit for Claude Code and Codex on this machine. Safe to run again.
#
#   kit/install.sh          install or refresh
#   kit/install.sh --check  exit 0 if the installed copy is current, 1 if not; change nothing
#
# It changes only:
#  - the block between its markers in ~/.claude/CLAUDE.md (imports of kit/rules),
#  - the block between its markers in ~/.codex/AGENTS.md (kit/rules inlined,
#    because Codex has no imports),
#  - links in ~/.claude/skills and ~/.agents/skills that point into kit/skills,
#  - the parked yshifu command in ~/.claude/commands.
# All other text and files stay as they are. It writes nothing into this repo.

set -euo pipefail

kit=$(cd "$(dirname "$0")" && pwd)
begin_mark='<!-- ystack kit: begin'
end_mark='<!-- ystack kit: end -->'
check=false
stale=0

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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

claude_block() {
  local rules
  rules=$(shown "$kit/rules")
  echo "$begin_mark (kit/install.sh writes this block; change the kit, not this) -->"
  echo "@$rules/working-preferences.md"
  echo "@$rules/claude.md"
  echo "$end_mark"
}

codex_block() {
  echo "$begin_mark (kit/install.sh writes this block; change the kit, not this) -->"
  cat "$kit/rules/working-preferences.md"
  echo
  cat "$kit/rules/codex.md"
  echo "$end_mark"
}

# Puts the block in $2 between the markers of file $1, or appends it.
put_block() {
  local file=$1 block=$2 begins ends first_begin first_end
  begins=$(grep -c "^$begin_mark" "$file" 2> /dev/null || true)
  ends=$(grep -c "^$end_mark" "$file" 2> /dev/null || true)
  if [ ! -e "$file" ]; then
    cp "$block" "$work/next"
  elif [ "${begins:-0}" = 0 ] && [ "${ends:-0}" = 0 ]; then
    {
      cat "$file"
      [ ! -s "$file" ] || [ -z "$(tail -c 1 "$file")" ] || echo
      [ ! -s "$file" ] || echo
      cat "$block"
    } > "$work/next"
  elif [ "$begins" = 1 ] && [ "$ends" = 1 ]; then
    first_begin=$(grep -n "^$begin_mark" "$file" | cut -d: -f1)
    first_end=$(grep -n "^$end_mark" "$file" | cut -d: -f1)
    [ "$first_begin" -lt "$first_end" ] || fail "$(shown "$file") has its kit markers out of order. Fix it by hand."
    awk -v block="$block" -v b="$begin_mark" -v e="$end_mark" '
      index($0, b) == 1 { while ((getline line < block) > 0) print line; skip = 1; next }
      index($0, e) == 1 { skip = 0; next }
      !skip { print }' "$file" > "$work/next"
  else
    fail "$(shown "$file") has broken kit markers. Fix it by hand."
  fi
  if cmp -s "$work/next" "$file"; then
    return
  fi
  if $check; then
    echo "stale: $(shown "$file")"
    stale=1
    return
  fi
  mkdir -p "$(dirname "$file")"
  # Writing through the file keeps a symlink and the file mode.
  cat "$work/next" > "$file"
  echo "updated: $(shown "$file")"
}

link_skills() {
  local dest link target skill name
  for dest in "$HOME/.claude/skills" "$HOME/.agents/skills"; do
    if [ -d "$dest" ]; then
      for link in "$dest"/*; do
        [ -L "$link" ] || continue
        target=$(readlink "$link")
        case $target in
          "$kit/skills/"*) ;;
          *) continue ;;
        esac
        [ ! -e "$link" ] || continue
        if $check; then
          echo "stale: $(shown "$link")"
          stale=1
        else
          rm -- "$link"
          echo "removed: $(shown "$link")"
        fi
      done
    fi
    for skill in "$kit"/skills/*/; do
      [ -f "$skill/SKILL.md" ] || continue
      name=$(basename "$skill")
      link=$dest/$name
      if [ -L "$link" ] && [ "$(readlink "$link")" = "$kit/skills/$name" ]; then
        continue
      fi
      [ ! -e "$link" ] && [ ! -L "$link" ] ||
        fail "$(shown "$link") exists and is not this kit's link. Remove it by hand."
      if $check; then
        echo "missing: $(shown "$link")"
        stale=1
      else
        mkdir -p "$dest"
        ln -s "$kit/skills/$name" "$link"
        echo "linked: $(shown "$link")"
      fi
    done
  done
}

remove_parked_command() {
  local file
  for file in "$HOME/.claude/commands/yshifu.md" "$HOME/.claude/commands/yshifu.md.bak"; do
    if [ ! -f "$file" ] || ! grep -q 'Summon yshifu' "$file"; then
      continue
    fi
    if $check; then
      echo "parked: $(shown "$file")"
      stale=1
    else
      rm -- "$file"
      echo "removed the parked yshifu command: $(shown "$file")"
    fi
  done
}

# A linked worktree is temporary; the agents must load the kit from the main checkout.
if git_dir=$(git -C "$kit" rev-parse --absolute-git-dir 2> /dev/null); then
  common_dir=$(cd "$kit" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
  [ "$(cd "$git_dir" && pwd -P)" = "$common_dir" ] ||
    fail "run this from the main checkout, not from a linked worktree."
fi

for f in working-preferences.md claude.md codex.md; do
  [ -s "$kit/rules/$f" ] || fail "kit/rules/$f is missing."
done
claude_block > "$work/claude-block"
codex_block > "$work/codex-block"
put_block "$HOME/.claude/CLAUDE.md" "$work/claude-block"
put_block "$HOME/.codex/AGENTS.md" "$work/codex-block"
link_skills
remove_parked_command

if $check; then
  [ "$stale" = 0 ] || exit 1
  echo "kit/install.sh: the installed kit is current."
fi
