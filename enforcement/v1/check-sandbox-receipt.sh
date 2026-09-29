#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_RELATION)
      /usr/bin/printf '%s\n' "$1" >&2
      ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

[ "$#" -eq 4 ] && [ "$1" = check ] || emit_error E_USAGE
shift
source_path=${BASH_SOURCE[0]}
case "$source_path" in /*) ;; *) source_path="$(pwd -P)/$source_path" ;; esac
[ -f "$source_path" ] && [ ! -L "$source_path" ] || emit_error E_RUNTIME
source_dir=$(CDPATH='' cd -P -- "${source_path%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
source_path="$source_dir/${source_path##*/}"
[ "$source_path" = "$source_dir/check-sandbox-receipt.sh" ] || emit_error E_RUNTIME
root_dir=$(CDPATH='' cd -P -- "$source_dir/../.." 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
program="$source_dir/sandbox-receipt.jq"
policy="$root_dir/control/v1/sandbox-policy.json"
decision="$root_dir/control/v1/sandbox-decision.json"
policy_set="$root_dir/control/v1/control-policy-set.json"
registry="$root_dir/shadow/v1/shadow-environments.json"
accepted="$root_dir/enforcement/v1/accepted-identities.json"

physical_regular() {
  local candidate=$1 parent physical
  case "$candidate" in /*) ;; *) return 1 ;; esac
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  parent=${candidate%/*}
  [ -n "$parent" ] || parent=/
  physical=$(CDPATH='' cd -P -- "$parent" 2>/dev/null && pwd -P) || return 1
  [ "$candidate" = "$physical/${candidate##*/}" ]
}

for required in "$source_path" "$program" "$policy" "$decision" "$policy_set" \
  "$registry" "$accepted" "$@"; do
  physical_regular "$required" || emit_error E_RUNTIME
done
jq_bin=$(command -v jq 2>/dev/null) || emit_error E_RUNTIME
case "$jq_bin" in /*) ;; *) emit_error E_RUNTIME ;; esac
physical_regular "$jq_bin" && [ -x "$jq_bin" ] || emit_error E_RUNTIME
live_jq=$jq_bin
platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) emit_error E_RUNTIME ;;
esac
[ "$(/usr/bin/shasum -a 256 "$live_jq" | /usr/bin/awk '{print $1}')" = "$jq_sha" ] ||
  emit_error E_RUNTIME

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-sandbox-receipt.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
/bin/chmod 0700 "$scratch" || emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM

snapshot_fixed() {
  local source=$1 target=$2 size
  /bin/dd if="$source" of="$target" bs=1048577 count=1 2>/dev/null ||
    emit_error E_RUNTIME
  size=$(/usr/bin/wc -c <"$target" | /usr/bin/tr -d ' ') || emit_error E_RUNTIME
  [ "$size" -le 1048576 ] || emit_error E_LIMIT
}
snapshot_executable() {
  local source=$1 target=$2 size
  /bin/dd if="$source" of="$target" bs=16777217 count=1 2>/dev/null ||
    emit_error E_RUNTIME
  size=$(/usr/bin/wc -c <"$target" | /usr/bin/tr -d ' ') || emit_error E_RUNTIME
  [ "$size" -le 16777216 ] || emit_error E_LIMIT
  /bin/chmod 0500 "$target" || emit_error E_RUNTIME
}
sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
/bin/mkdir -m 0700 "$scratch/bin" || emit_error E_RUNTIME
jq_bin="$scratch/bin/jq"
snapshot_executable "$live_jq" "$jq_bin"
physical_regular "$jq_bin" && [ -x "$jq_bin" ] &&
  [ "$(sha256_path "$jq_bin")" = "$jq_sha" ] &&
  [ "$($jq_bin --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME

canonical_json() {
  local raw=$1 canonical=$2 bom roots
  bom=$(/usr/bin/od -An -tx1 -N3 "$raw" 2>/dev/null | /usr/bin/tr -d ' \n') ||
    emit_error E_RUNTIME
  [ "$bom" != efbbbf ] || emit_error E_PARSE
  "$jq_bin" . "$raw" >/dev/null 2>&1 || emit_error E_PARSE
  roots=$("$jq_bin" -s 'length' "$raw" 2>/dev/null) || emit_error E_PARSE
  [ "$roots" -eq 1 ] || emit_error E_PARSE
  "$jq_bin" -S -c . "$raw" >"$canonical" 2>/dev/null || emit_error E_PARSE
  /usr/bin/cmp -s "$raw" "$canonical" || emit_error E_CANONICAL
  "$jq_bin" -e '
    def depth:
      if type=="array" then if length==0 then 1 else 1+([.[]|depth]|max) end
      elif type=="object" then if length==0 then 1 else 1+([.[]|depth]|max) end
      else 1 end;
    def members:
      if type=="array" then length+([.[]|members]|add//0)
      elif type=="object" then (keys_unsorted|length)+([.[]|members]|add//0)
      else 0 end;
    def strings_ok:
      if type=="array" then all(.[];strings_ok)
      elif type=="object" then
        all(keys_unsorted[];utf8bytelength<=8192) and all(.[];strings_ok)
      elif type=="string" then utf8bytelength<=8192 else true end;
    depth<=32 and members<=4096 and strings_ok
  ' "$raw" >/dev/null 2>&1 || emit_error E_LIMIT
}
unchanged() { physical_regular "$1" && /usr/bin/cmp -s "$1" "$2"; }

snapshot_fixed "$source_path" "$scratch/driver.sh"
snapshot_fixed "$program" "$scratch/program.jq"
snapshot_fixed "$policy" "$scratch/policy.json"
snapshot_fixed "$decision" "$scratch/decision.json"
snapshot_fixed "$policy_set" "$scratch/policy-set.json"
snapshot_fixed "$registry" "$scratch/registry.json"
snapshot_fixed "$accepted" "$scratch/accepted.json"

names=(receipt expectation evaluation)
inputs=("$@")
index=0
while [ "$index" -lt 3 ]; do
  snapshot_fixed "${inputs[$index]}" "$scratch/${names[$index]}.json"
  index=$((index + 1))
done
for static_name in policy decision policy-set registry accepted receipt expectation evaluation; do
  canonical_json "$scratch/$static_name.json" "$scratch/$static_name.canonical"
done

policy_sha=$(sha256_path "$scratch/policy.json") || emit_error E_RUNTIME
decision_sha=$(sha256_path "$scratch/decision.json") || emit_error E_RUNTIME
policy_set_sha=$(sha256_path "$scratch/policy-set.json") || emit_error E_RUNTIME
accepted_sha=$(sha256_path "$scratch/accepted.json") || emit_error E_RUNTIME
receipt_sha=$(sha256_path "$scratch/receipt.json") || emit_error E_RUNTIME
expectation_sha=$(sha256_path "$scratch/expectation.json") || emit_error E_RUNTIME
evaluation_sha=$(sha256_path "$scratch/evaluation.json") || emit_error E_RUNTIME

entry_count=$("$jq_bin" -r '.body.environments | length' "$scratch/registry.json" \
  2>/dev/null) || emit_error E_RELATION
: >"$scratch/entry-digests.jsonl"
index=0
while [ "$index" -lt "$entry_count" ]; do
  "$jq_bin" -S -c --argjson i "$index" '.body.environments[$i]' "$scratch/registry.json" \
    >"$scratch/entry-$index.json" 2>/dev/null || emit_error E_RELATION
  entry_sha=$(sha256_path "$scratch/entry-$index.json") || emit_error E_RUNTIME
  entry_env=$("$jq_bin" -r --argjson i "$index" '.body.environments[$i].environment_id' \
    "$scratch/registry.json" 2>/dev/null) || emit_error E_RELATION
  "$jq_bin" -n -c --arg e "$entry_env" --arg s "$entry_sha" \
    '{environment_id:$e,sha256:$s}' >>"$scratch/entry-digests.jsonl" 2>/dev/null ||
    emit_error E_RUNTIME
  index=$((index + 1))
done
"$jq_bin" -s -c '.' "$scratch/entry-digests.jsonl" >"$scratch/entry-digests.json" 2>/dev/null ||
  emit_error E_RUNTIME

"$jq_bin" -n -S -c -f "$scratch/program.jq" \
  --slurpfile receipt "$scratch/receipt.json" --slurpfile expectation "$scratch/expectation.json" \
  --slurpfile evaluation "$scratch/evaluation.json" --slurpfile policy "$scratch/policy.json" \
  --slurpfile decision "$scratch/decision.json" --slurpfile policy_set "$scratch/policy-set.json" \
  --slurpfile registry "$scratch/registry.json" --slurpfile accepted "$scratch/accepted.json" \
  --slurpfile entry_digests "$scratch/entry-digests.json" \
  --arg receipt_sha "$receipt_sha" --arg expectation_sha "$expectation_sha" \
  --arg evaluation_sha "$evaluation_sha" --arg policy_sha "$policy_sha" \
  --arg decision_sha "$decision_sha" --arg policy_set_sha "$policy_set_sha" \
  --arg accepted_set_sha "$accepted_sha" \
  >"$scratch/output.json" 2>/dev/null || emit_error E_RELATION
output_size=$(/usr/bin/wc -c <"$scratch/output.json" | /usr/bin/tr -d ' ') ||
  emit_error E_RUNTIME
[ "$output_size" -le 1048576 ] || emit_error E_LIMIT

if ! unchanged "$source_path" "$scratch/driver.sh" ||
   ! unchanged "$program" "$scratch/program.jq" ||
   ! unchanged "$policy" "$scratch/policy.json" ||
   ! unchanged "$decision" "$scratch/decision.json" ||
   ! unchanged "$policy_set" "$scratch/policy-set.json" ||
   ! unchanged "$registry" "$scratch/registry.json" ||
   ! unchanged "$accepted" "$scratch/accepted.json"; then
  emit_error E_RELATION
fi
physical_regular "$jq_bin" && [ -x "$jq_bin" ] &&
  [ "$(sha256_path "$jq_bin")" = "$jq_sha" ] &&
  [ "$($jq_bin --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RELATION
index=0
while [ "$index" -lt 3 ]; do
  unchanged "${inputs[$index]}" "$scratch/${names[$index]}.json" || emit_error E_RELATION
  index=$((index + 1))
done
/bin/cat "$scratch/output.json" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
