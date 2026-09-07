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

[ "$#" -eq 3 ] && [ "$1" = validate ] || emit_error E_USAGE
kind=$2
input=$3
case "$kind" in
  deploy_authorization|deploy_environment_tiers|deploy_request|kill_switch_evaluation|\
  release_record|risk_gate_evaluation|rollback_rehearsal_record|rollback_request|\
  status_request) ;;
  *) emit_error E_USAGE ;;
esac
source_path=${BASH_SOURCE[0]}
case "$source_path" in /*) ;; *) source_path="$(pwd -P)/$source_path" ;; esac
[ -f "$source_path" ] && [ ! -L "$source_path" ] || emit_error E_RUNTIME
source_dir=$(CDPATH='' cd -P -- "${source_path%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
source_path="$source_dir/${source_path##*/}"
[ "$source_path" = "$source_dir/validate-deploy-document.sh" ] || emit_error E_RUNTIME
contracts="$source_dir/deploy_contracts.jq"
for required in "$contracts" "$input"; do
  [ -f "$required" ] && [ ! -L "$required" ] || emit_error E_RUNTIME
done
jq_bin=$(command -v jq 2>/dev/null) || emit_error E_RUNTIME
case "$jq_bin" in /*) ;; *) emit_error E_RUNTIME ;; esac
[ -f "$jq_bin" ] && [ -x "$jq_bin" ] && [ ! -L "$jq_bin" ] &&
  [ "$($jq_bin --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-deploy-document.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM

raw="$scratch/raw.json"
/bin/dd if="$input" of="$raw" bs=1048577 count=1 2>/dev/null || emit_error E_RUNTIME
raw_size=$(/usr/bin/wc -c <"$raw" | /usr/bin/tr -d ' ') || emit_error E_RUNTIME
[ "$raw_size" -le 1048576 ] || emit_error E_LIMIT
bom=$(/usr/bin/od -An -tx1 -N3 "$raw" 2>/dev/null | /usr/bin/tr -d ' \n') ||
  emit_error E_RUNTIME
[ "$bom" != efbbbf ] || emit_error E_PARSE
"$jq_bin" . "$raw" >/dev/null 2>&1 || emit_error E_PARSE
root_count=$("$jq_bin" -s 'length' "$raw" 2>/dev/null) || emit_error E_PARSE
[ "$root_count" -eq 1 ] || emit_error E_PARSE
canonical="$scratch/canonical.json"
"$jq_bin" -S -c . "$raw" >"$canonical" 2>/dev/null || emit_error E_PARSE
/usr/bin/cmp -s "$raw" "$canonical" || emit_error E_CANONICAL

"$jq_bin" -e '
  def depth:
    if type == "array" then
      if length == 0 then 1 else 1 + ([.[] | depth] | max) end
    elif type == "object" then
      if length == 0 then 1 else 1 + ([.[] | depth] | max) end
    else 1 end;
  def members:
    if type == "array" then length + ([.[] | members] | add // 0)
    elif type == "object" then (keys_unsorted | length) + ([.[] | members] | add // 0)
    else 0 end;
  def strings_ok:
    if type == "array" then all(.[];strings_ok)
    elif type == "object" then
      all(keys_unsorted[];utf8bytelength <= 8192) and all(.[];strings_ok)
    elif type == "string" then utf8bytelength <= 8192
    else true end;
  (depth <= 32) and (members <= 1024) and strings_ok
' "$raw" >/dev/null 2>&1 || emit_error E_LIMIT

"$jq_bin" -L "$source_dir" -e --arg kind "$kind" \
  'include "deploy_contracts"; document_ok($kind)' "$raw" >/dev/null 2>&1 ||
  emit_error E_SHAPE
/usr/bin/cmp -s "$input" "$raw" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
