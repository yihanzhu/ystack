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

[ "$#" -eq 7 ] && [ "$1" = plan ] || emit_error E_USAGE
shift
source_path=${BASH_SOURCE[0]}
case "$source_path" in /*) ;; *) source_path="$(pwd -P)/$source_path" ;; esac
source_dir=$(CDPATH='' cd -P -- "${source_path%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
source_path="$source_dir/${source_path##*/}"
[ "$source_path" = "$source_dir/plan-review-fix.sh" ] || emit_error E_RUNTIME
policy="$source_dir/review-fix-policy.json"
program="$source_dir/review-fix-planner.jq"

physical_regular() {
  local candidate=$1 parent physical
  case "$candidate" in /*) ;; *) return 1 ;; esac
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  parent=${candidate%/*}
  [ -n "$parent" ] || parent=/
  physical=$(CDPATH='' cd -P -- "$parent" 2>/dev/null && pwd -P) || return 1
  [ "$candidate" = "$physical/${candidate##*/}" ]
}

for required in "$source_path" "$policy" "$program" "$@"; do
  physical_regular "$required" || emit_error E_RUNTIME
done
live_jq=$(command -v jq 2>/dev/null) || emit_error E_RUNTIME
case "$live_jq" in /*) ;; *) emit_error E_RUNTIME ;; esac
physical_regular "$live_jq" && [ -x "$live_jq" ] || emit_error E_RUNTIME
platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) emit_error E_RUNTIME ;;
esac
sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
[ "$(sha256_path "$live_jq")" = "$jq_sha" ] || emit_error E_RUNTIME

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-review-fix.XXXXXX" 2>/dev/null) ||
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
/bin/mkdir -m 0700 "$scratch/bin" || emit_error E_RUNTIME
jq_bin="$scratch/bin/jq"
/bin/dd if="$live_jq" of="$jq_bin" bs=16777217 count=1 2>/dev/null ||
  emit_error E_RUNTIME
/bin/chmod 0500 "$jq_bin" || emit_error E_RUNTIME
physical_regular "$jq_bin" && [ -x "$jq_bin" ] &&
  [ "$(sha256_path "$jq_bin")" = "$jq_sha" ] &&
  [ "$("$jq_bin" --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME

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
    depth<=32 and members<=16384 and strings_ok
  ' "$raw" >/dev/null 2>&1 || emit_error E_LIMIT
}
unchanged() { physical_regular "$1" && /usr/bin/cmp -s "$1" "$2"; }

snapshot_fixed "$source_path" "$scratch/driver.sh"
snapshot_fixed "$policy" "$scratch/policy.json"
snapshot_fixed "$program" "$scratch/program.jq"
names=(observation context credential reconciliation risk ledger)
inputs=("$@")
index=0
while [ "$index" -lt 6 ]; do
  snapshot_fixed "${inputs[$index]}" "$scratch/${names[$index]}.json"
  index=$((index + 1))
done
for document in policy "${names[@]}"; do
  canonical_json "$scratch/$document.json" "$scratch/$document.canonical"
done

policy_sha=$(sha256_path "$scratch/policy.json") || emit_error E_RUNTIME
observation_sha=$(sha256_path "$scratch/observation.json") || emit_error E_RUNTIME
context_sha=$(sha256_path "$scratch/context.json") || emit_error E_RUNTIME
credential_sha=$(sha256_path "$scratch/credential.json") || emit_error E_RUNTIME
reconciliation_sha=$(sha256_path "$scratch/reconciliation.json") ||
  emit_error E_RUNTIME
risk_sha=$(sha256_path "$scratch/risk.json") || emit_error E_RUNTIME
ledger_sha=$(sha256_path "$scratch/ledger.json") || emit_error E_RUNTIME

"$jq_bin" -n -S -c -f "$scratch/program.jq" \
  --slurpfile policy "$scratch/policy.json" \
  --slurpfile observation "$scratch/observation.json" \
  --slurpfile context "$scratch/context.json" \
  --slurpfile credential "$scratch/credential.json" \
  --slurpfile reconciliation "$scratch/reconciliation.json" \
  --slurpfile risk "$scratch/risk.json" \
  --slurpfile ledger "$scratch/ledger.json" \
  --arg policy_sha "$policy_sha" --arg observation_sha "$observation_sha" \
  --arg context_sha "$context_sha" --arg credential_sha "$credential_sha" \
  --arg reconciliation_sha "$reconciliation_sha" --arg risk_sha "$risk_sha" \
  --arg ledger_sha "$ledger_sha" \
  >"$scratch/plan.json" 2>/dev/null || emit_error E_RELATION
output_size=$(/usr/bin/wc -c <"$scratch/plan.json" | /usr/bin/tr -d ' ') ||
  emit_error E_RUNTIME
[ "$output_size" -le 1048576 ] || emit_error E_LIMIT
"$jq_bin" -S -c . "$scratch/plan.json" >"$scratch/plan.canonical" 2>/dev/null ||
  emit_error E_RUNTIME
/usr/bin/cmp -s "$scratch/plan.json" "$scratch/plan.canonical" ||
  emit_error E_RUNTIME
"$jq_bin" -e '
  (keys|sort)==["body","id","kind","schema_version"] and
  .schema_version==1 and .kind=="review_fix_plan" and
  .body.activation_state=="inactive" and .body.authority=="none" and
  .body.mode=="planning-only" and .body.effects==[] and
  .body.qualification.state=="unavailable" and
  ((.body.decision.outcome=="refusal" and
    (.body.decision|keys|sort)==["detail_ids","outcome","reason_id"] and
    (.body.decision.reason_id|
     IN("approval-present","attempt-limit","boundaries-unproven",
        "degraded-review","kill-switch","no-actionable-findings",
        "review-stale")) and
    (.body.decision.detail_ids|type=="array" and length>=1)) or
   (.body.decision.outcome=="fix-request" and
    (.body.decision|keys|sort)==["fix_request","outcome"] and
    .body.decision.fix_request.push_allowed==false and
    .body.decision.fix_request.authority=="none" and
    (.body.decision.fix_request.allowed_paths|length)>=1 and
    (.body.decision.fix_request.findings|length)>=1)) and
  ((.body|has("grant_ref") or has("activation"))|not)
' "$scratch/plan.json" >/dev/null 2>&1 || emit_error E_RUNTIME

if ! unchanged "$source_path" "$scratch/driver.sh" ||
   ! unchanged "$policy" "$scratch/policy.json" ||
   ! unchanged "$program" "$scratch/program.jq"; then
  emit_error E_RELATION
fi
index=0
while [ "$index" -lt 6 ]; do
  unchanged "${inputs[$index]}" "$scratch/${names[$index]}.json" ||
    emit_error E_RELATION
  index=$((index + 1))
done
physical_regular "$jq_bin" && [ -x "$jq_bin" ] &&
  [ "$(sha256_path "$jq_bin")" = "$jq_sha" ] || emit_error E_RELATION
/bin/cat "$scratch/plan.json" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
