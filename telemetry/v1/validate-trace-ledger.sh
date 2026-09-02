#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION)
      /usr/bin/printf '%s\n' "$1" >&2 ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

[ "$#" -eq 2 ] && [ "$1" = validate ] || emit_error E_USAGE
input=$2
self=${BASH_SOURCE[0]}
case "$self" in /*) ;; *) self="$(pwd -P)/$self" ;; esac
[ -f "$self" ] && [ ! -L "$self" ] || emit_error E_RUNTIME
self_dir=$(CDPATH='' cd -P -- "${self%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
self="$self_dir/${self##*/}"
[ "$self" = "$self_dir/validate-trace-ledger.sh" ] || emit_error E_RUNTIME
program="$self_dir/trace-ledger.jq"
[ -f "$program" ] && [ ! -L "$program" ] || emit_error E_RUNTIME
[ -f "$input" ] && [ ! -L "$input" ] || emit_error E_RUNTIME

jq_bin=$(command -v jq 2>/dev/null) || emit_error E_RUNTIME
case "$jq_bin" in /*) ;; *) emit_error E_RUNTIME ;; esac
[ -f "$jq_bin" ] && [ -x "$jq_bin" ] && [ ! -L "$jq_bin" ] &&
  [ "$($jq_bin --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME

scratch=$(/usr/bin/mktemp -d /tmp/ystack-trace-ledger.XXXXXX 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM

raw="$scratch/ledger.json"
program_copy="$scratch/program.jq"
/bin/dd if="$input" of="$raw" bs=1048577 count=1 2>/dev/null || emit_error E_RUNTIME
/bin/dd if="$program" of="$program_copy" bs=1048577 count=1 2>/dev/null ||
  emit_error E_RUNTIME
input_sha=$(sha_file "$raw") || emit_error E_RUNTIME
program_sha=$(sha_file "$program_copy") || emit_error E_RUNTIME
[ -f "$input" ] && [ ! -L "$input" ] && [ "$(sha_file "$input")" = "$input_sha" ] &&
  [ -f "$program" ] && [ ! -L "$program" ] &&
  [ "$(sha_file "$program")" = "$program_sha" ] || emit_error E_RUNTIME

raw_size=$(/usr/bin/wc -c < "$raw" | /usr/bin/tr -d ' ') || emit_error E_RUNTIME
[ "$raw_size" -le 1048576 ] || emit_error E_LIMIT
bom=$(/usr/bin/od -An -tx1 -N3 "$raw" 2>/dev/null | /usr/bin/tr -d ' \n') ||
  emit_error E_RUNTIME
[ "$bom" != efbbbf ] || emit_error E_PARSE
"$jq_bin" . "$raw" >/dev/null 2>&1 || emit_error E_PARSE
[ "$("$jq_bin" -s 'length' "$raw" 2>/dev/null)" -eq 1 ] || emit_error E_PARSE
canonical="$scratch/canonical.json"
"$jq_bin" -S -c . "$raw" > "$canonical" 2>/dev/null || emit_error E_PARSE
/usr/bin/cmp -s "$raw" "$canonical" || emit_error E_CANONICAL

"$jq_bin" -e '
  def within($depth):
    if $depth > 16 then false
    elif type == "array" then length <= 256 and all(.[];within($depth + 1))
    elif type == "object" then length <= 64 and
      all(keys_unsorted[];utf8bytelength <= 1024) and all(.[];within($depth + 1))
    elif type == "string" then utf8bytelength <= 1024
    elif type == "number" then . == floor and . >= 0 and . <= 2147483647 and
      tostring != "-0"
    else true end;
  within(0)
' "$raw" >/dev/null 2>&1 || emit_error E_LIMIT

shape=$("$jq_bin" -L "$scratch" -r --arg operation shape --arg ledger_sha "$input_sha" \
  --argjson event_digests '[]' -f "$program_copy" "$raw" 2>/dev/null) ||
  emit_error E_RUNTIME
[ -z "$shape" ] || { [ "$shape" = E_SHAPE ] && emit_error E_SHAPE; emit_error E_RUNTIME; }

event_count=$("$jq_bin" -r '.body.events | length' "$raw") || emit_error E_RUNTIME
: > "$scratch/digests.txt"
i=0
while [ "$i" -lt "$event_count" ]; do
  "$jq_bin" -S -c ".body.events[$i] | del(.record_digest)" "$raw" \
    > "$scratch/event.json" 2>/dev/null || emit_error E_RUNTIME
  sha_file "$scratch/event.json" >> "$scratch/digests.txt" || emit_error E_RUNTIME
  i=$((i + 1))
done
"$jq_bin" -R -s -c 'split("\n")[:-1]' "$scratch/digests.txt" \
  > "$scratch/digests.json" 2>/dev/null || emit_error E_RUNTIME

result=$("$jq_bin" -L "$scratch" -S -c -r --arg operation validate \
  --arg ledger_sha "$input_sha" --argjson event_digests "$(/bin/cat "$scratch/digests.json")" \
  -f "$program_copy" "$raw" 2>/dev/null) || emit_error E_RUNTIME
case "$result" in E_SHAPE|E_RELATION) emit_error "$result" ;; E_*) emit_error E_RUNTIME ;; esac
[ -f "$input" ] && [ ! -L "$input" ] && [ "$(sha_file "$input")" = "$input_sha" ] &&
  [ -f "$program" ] && [ ! -L "$program" ] &&
  [ "$(sha_file "$program")" = "$program_sha" ] || emit_error E_RUNTIME
/usr/bin/printf '%s\n' "$result"
