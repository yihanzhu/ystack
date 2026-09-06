#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE)
      /usr/bin/printf '%s\n' "$1" >&2
      ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

physical_regular() {
  local candidate=$1 parent physical
  case "$candidate" in /*) ;; *) return 1 ;; esac
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  parent=${candidate%/*}
  [ -n "$parent" ] || parent=/
  physical=$(CDPATH='' cd -P -- "$parent" 2>/dev/null && pwd -P) || return 1
  [ "$candidate" = "$physical/${candidate##*/}" ]
}

[ "$#" -eq 2 ] && [ "$1" = validate ] || emit_error E_USAGE
record=$2
case "$record" in /*) ;; *) emit_error E_USAGE ;; esac

self=${BASH_SOURCE[0]}
case "$self" in /*) ;; *) self="$(pwd -P)/$self" ;; esac
[ -f "$self" ] && [ ! -L "$self" ] || emit_error E_RUNTIME
self_dir=$(CDPATH='' cd -P -- "${self%/*}" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
self="$self_dir/${self##*/}"
[ "$self" = "$self_dir/validate-incident.sh" ] || emit_error E_RUNTIME
program="$self_dir/incident-record.jq"
for required in "$self" "$program" "$record"; do
  physical_regular "$required" || emit_error E_RUNTIME
done

live_jq=$(command -v jq 2>/dev/null) || emit_error E_RUNTIME
physical_regular "$live_jq" && [ -x "$live_jq" ] || emit_error E_RUNTIME
case "$(/usr/bin/uname -s):$(/usr/bin/uname -m)" in
  Darwin:*) jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) emit_error E_RUNTIME ;;
esac
[ "$(sha256_path "$live_jq")" = "$jq_sha" ] || emit_error E_RUNTIME

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-shadow-incident.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
/bin/chmod 0700 "$scratch" || emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM

snapshot_bounded() {
  local source=$1 target=$2 limit=$3 size
  /bin/dd if="$source" of="$target" bs=$((limit + 1)) count=1 2>/dev/null ||
    emit_error E_RUNTIME
  size=$(/usr/bin/wc -c <"$target" | /usr/bin/tr -d ' ') || emit_error E_RUNTIME
  [ "$size" -le "$limit" ] || emit_error E_LIMIT
}

jq_bin="$scratch/jq"
snapshot_bounded "$live_jq" "$jq_bin" 16777216
/bin/chmod 0500 "$jq_bin" || emit_error E_RUNTIME
[ "$(sha256_path "$jq_bin")" = "$jq_sha" ] &&
  [ "$("$jq_bin" --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME

snapshot_bounded "$record" "$scratch/record.json" 262144
snapshot_bounded "$program" "$scratch/program.jq" 262144
record_sha=$(sha256_path "$scratch/record.json") || emit_error E_RUNTIME
program_sha=$(sha256_path "$scratch/program.jq") || emit_error E_RUNTIME

bom=$(/usr/bin/od -An -tx1 -N3 "$scratch/record.json" 2>/dev/null |
  /usr/bin/tr -d ' \n') || emit_error E_RUNTIME
[ "$bom" != efbbbf ] || emit_error E_PARSE
"$jq_bin" . "$scratch/record.json" >/dev/null 2>&1 || emit_error E_PARSE
[ "$("$jq_bin" -s 'length' "$scratch/record.json" 2>/dev/null)" -eq 1 ] ||
  emit_error E_PARSE
"$jq_bin" -S -c . "$scratch/record.json" >"$scratch/canonical.json" 2>/dev/null ||
  emit_error E_PARSE
/usr/bin/cmp -s "$scratch/record.json" "$scratch/canonical.json" ||
  emit_error E_CANONICAL
"$jq_bin" -e '
  def within($depth):
    if $depth > 16 then false
    elif type == "array" then length <= 256 and all(.[];within($depth + 1))
    elif type == "object" then length <= 64 and
      all(keys_unsorted[];utf8bytelength <= 1024) and all(.[];within($depth + 1))
    elif type == "string" then utf8bytelength <= 4096
    else true end;
  within(0)
' "$scratch/record.json" >/dev/null 2>&1 || emit_error E_LIMIT

shape=$("$jq_bin" -r --arg operation shape --arg record_sha "$record_sha" \
  -f "$scratch/program.jq" "$scratch/record.json" 2>/dev/null) || emit_error E_RUNTIME
[ -z "$shape" ] || { [ "$shape" = E_SHAPE ] && emit_error E_SHAPE; emit_error E_RUNTIME; }
"$jq_bin" -S -c --arg operation receipt --arg record_sha "$record_sha" \
  -f "$scratch/program.jq" "$scratch/record.json" >"$scratch/receipt.json" 2>/dev/null ||
  emit_error E_RUNTIME
"$jq_bin" -e 'type == "object" and .kind == "shadow_incident_validation"' \
  "$scratch/receipt.json" >/dev/null 2>&1 || emit_error E_RUNTIME

physical_regular "$record" && [ "$(sha256_path "$record")" = "$record_sha" ] &&
  physical_regular "$program" && [ "$(sha256_path "$program")" = "$program_sha" ] &&
  [ "$(sha256_path "$jq_bin")" = "$jq_sha" ] || emit_error E_RUNTIME
/bin/cat "$scratch/receipt.json" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
