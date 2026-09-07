#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_RELATION|E_TIERS)
      /usr/bin/printf '%s\n' "$1" >&2
      ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

[ "$#" -eq 7 ] && [ "$1" = evaluate ] || emit_error E_USAGE
shift
source_path=${BASH_SOURCE[0]}
case "$source_path" in /*) ;; *) source_path="$(pwd -P)/$source_path" ;; esac
[ -f "$source_path" ] && [ ! -L "$source_path" ] || emit_error E_RUNTIME
source_dir=$(CDPATH='' cd -P -- "${source_path%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
source_path="$source_dir/${source_path##*/}"
[ "$source_path" = "$source_dir/evaluate-deploy.sh" ] || emit_error E_RUNTIME
tiers="$source_dir/environment-tiers.json"
decision="$source_dir/deploy-decision.json"
program="$source_dir/deploy-gates.jq"
contracts="$source_dir/deploy_contracts.jq"
validator="$source_dir/validate-deploy-document.sh"

physical_regular() {
  local candidate=$1 parent physical
  case "$candidate" in /*) ;; *) return 1 ;; esac
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  parent=${candidate%/*}
  [ -n "$parent" ] || parent=/
  physical=$(CDPATH='' cd -P -- "$parent" 2>/dev/null && pwd -P) || return 1
  [ "$candidate" = "$physical/${candidate##*/}" ]
}

for required in "$source_path" "$tiers" "$decision" "$program" "$contracts" \
  "$validator" "$@"; do
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
sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
[ "$(sha256_path "$live_jq")" = "$jq_sha" ] || emit_error E_RUNTIME

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-deploy-gates.XXXXXX" 2>/dev/null) ||
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
/bin/mkdir -m 0700 "$scratch/bin" "$scratch/lib" || emit_error E_RUNTIME
/bin/dd if="$live_jq" of="$scratch/bin/jq" bs=16777217 count=1 2>/dev/null ||
  emit_error E_RUNTIME
/bin/chmod 0500 "$scratch/bin/jq" || emit_error E_RUNTIME
jq_bin="$scratch/bin/jq"
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
      if type == "array" then if length == 0 then 1 else 1 + ([.[] | depth] | max) end
      elif type == "object" then if length == 0 then 1 else 1 + ([.[] | depth] | max) end
      else 1 end;
    def members:
      if type == "array" then length + ([.[] | members] | add // 0)
      elif type == "object" then (keys_unsorted | length) + ([.[] | members] | add // 0)
      else 0 end;
    def strings_ok:
      if type == "array" then all(.[];strings_ok)
      elif type == "object" then
        all(keys_unsorted[];utf8bytelength <= 8192) and all(.[];strings_ok)
      elif type == "string" then utf8bytelength <= 8192 else true end;
    depth <= 32 and members <= 4096 and strings_ok
  ' "$raw" >/dev/null 2>&1 || emit_error E_LIMIT
}
unchanged() { physical_regular "$1" && /usr/bin/cmp -s "$1" "$2"; }

/bin/mkdir -p "$scratch/validator/deploy/v1" || emit_error E_RUNTIME
mirror_validator="$scratch/validator/deploy/v1/validate-deploy-document.sh"
mirror_contracts="$scratch/validator/deploy/v1/deploy_contracts.jq"
snapshot_fixed "$source_path" "$scratch/driver.sh"
snapshot_fixed "$validator" "$mirror_validator"
/bin/chmod 0500 "$mirror_validator" || emit_error E_RUNTIME
snapshot_fixed "$tiers" "$scratch/tiers.json"
snapshot_fixed "$decision" "$scratch/decision.json"
snapshot_fixed "$program" "$scratch/lib/deploy-gates.jq"
snapshot_fixed "$contracts" "$scratch/lib/deploy_contracts.jq"
/bin/cp "$scratch/lib/deploy_contracts.jq" "$mirror_contracts" || emit_error E_RUNTIME
names=(request release authorization rehearsal risk kill)
inputs=("$@")
index=0
while [ "$index" -lt 6 ]; do
  snapshot_fixed "${inputs[$index]}" "$scratch/${names[$index]}.json"
  index=$((index + 1))
done
for document in tiers decision request release authorization rehearsal risk kill; do
  canonical_json "$scratch/$document.json" "$scratch/$document.canonical"
done

tiers_sha=$(sha256_path "$scratch/tiers.json") || emit_error E_RUNTIME
decision_sha=$(sha256_path "$scratch/decision.json") || emit_error E_RUNTIME
program_sha=$(sha256_path "$scratch/lib/deploy-gates.jq") || emit_error E_RUNTIME
contracts_sha=$(sha256_path "$scratch/lib/deploy_contracts.jq") || emit_error E_RUNTIME
driver_sha=$(sha256_path "$scratch/driver.sh") || emit_error E_RUNTIME
validator_sha=$(sha256_path "$mirror_validator") || emit_error E_RUNTIME
request_sha=$(sha256_path "$scratch/request.json") || emit_error E_RUNTIME
release_sha=$(sha256_path "$scratch/release.json") || emit_error E_RUNTIME
authorization_sha=$(sha256_path "$scratch/authorization.json") || emit_error E_RUNTIME
rehearsal_sha=$(sha256_path "$scratch/rehearsal.json") || emit_error E_RUNTIME
risk_sha=$(sha256_path "$scratch/risk.json") || emit_error E_RUNTIME
kill_sha=$(sha256_path "$scratch/kill.json") || emit_error E_RUNTIME

"$jq_bin" -e --arg driver_sha "$driver_sha" --arg program_sha "$program_sha" \
  --arg contracts_sha "$contracts_sha" --arg validator_sha "$validator_sha" '
  def ref($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
  .body.evaluator == {
    contracts_ref:ref("deploy-contract-module.v1";"text/x-jq";$contracts_sha),
    driver_ref:ref("deploy-evaluator-driver.deploy-gates.v1";"text/x-shellscript";
      $driver_sha),
    program_ref:ref("deploy-evaluator-program.deploy-gates.v1";"text/x-jq";$program_sha),
    validator_ref:ref("deploy-document-validator-driver.v1";"text/x-shellscript";
      $validator_sha)}
' "$scratch/decision.json" >/dev/null 2>&1 || emit_error E_RELATION

jq_dir=${jq_bin%/*}
validator_status=0
/usr/bin/env -i LC_ALL=C PATH="$jq_dir:/usr/bin:/bin" TMPDIR="$scratch" \
  /bin/bash "$mirror_validator" validate deploy_environment_tiers \
  "$scratch/tiers.json" >"$scratch/validator.out" 2>"$scratch/validator.err" ||
  validator_status=$?
[ "$validator_status" -eq 0 ] && [ ! -s "$scratch/validator.out" ] &&
  [ ! -s "$scratch/validator.err" ] || emit_error E_TIERS

"$jq_bin" -n -S -c -L "$scratch/lib" -f "$scratch/lib/deploy-gates.jq" \
  --slurpfile tiers "$scratch/tiers.json" \
  --slurpfile decision "$scratch/decision.json" \
  --slurpfile request "$scratch/request.json" \
  --slurpfile release "$scratch/release.json" \
  --slurpfile authorization "$scratch/authorization.json" \
  --slurpfile rehearsal "$scratch/rehearsal.json" \
  --slurpfile risk "$scratch/risk.json" \
  --slurpfile kill "$scratch/kill.json" \
  --arg tiers_sha "$tiers_sha" --arg decision_sha "$decision_sha" \
  --arg request_sha "$request_sha" --arg release_sha "$release_sha" \
  --arg authorization_sha "$authorization_sha" --arg rehearsal_sha "$rehearsal_sha" \
  --arg risk_sha "$risk_sha" --arg kill_sha "$kill_sha" \
  >"$scratch/evaluation.json" 2>/dev/null || emit_error E_RELATION
output_size=$(/usr/bin/wc -c <"$scratch/evaluation.json" | /usr/bin/tr -d ' ') ||
  emit_error E_RUNTIME
[ "$output_size" -le 1048576 ] || emit_error E_LIMIT

"$jq_bin" -e --arg tiers_sha "$tiers_sha" --arg request_sha "$request_sha" '
  (keys | sort) == ["body","id","kind","schema_version"] and
  .schema_version == 1 and .kind == "deploy_gate_evaluation" and
  (.body |
    (keys | sort) == ["activation_state","authority","authorization_ref","decision",
      "decision_ref","evaluation_mode","kill_switch_evaluation_ref","qualification",
      "reason_ids","reference_semantics","rehearsal_ref","release_ref","request_ref",
      "requested_capability","risk_evaluation_ref","tier","tiers_ref"] and
    .activation_state == "inactive" and .authority == "none" and
    .evaluation_mode == "observation-only" and
    .reference_semantics == "identity-only" and
    .qualification == {reason:"no-deployment-adapter-exists",state:"unavailable"} and
    (.decision == "admissible" or .decision == "refused") and
    .request_ref.sha256 == $request_sha and .tiers_ref.sha256 == $tiers_sha and
    (.reason_ids | type == "array" and length >= 1 and . == (sort | unique)) and
    ((.decision == "admissible") == (.reason_ids == ["deploy.admissible"])) and
    (.reason_ids | all(.[]; startswith("deploy.")))) and
  ((.body | has("grant") or has("qualification_ref") or has("activation")) | not)
' "$scratch/evaluation.json" >/dev/null 2>&1 || emit_error E_RUNTIME

if ! unchanged "$source_path" "$scratch/driver.sh" ||
   ! unchanged "$validator" "$mirror_validator" ||
   ! unchanged "$tiers" "$scratch/tiers.json" ||
   ! unchanged "$decision" "$scratch/decision.json" ||
   ! unchanged "$program" "$scratch/lib/deploy-gates.jq" ||
   ! unchanged "$contracts" "$scratch/lib/deploy_contracts.jq"; then
  emit_error E_RELATION
fi
physical_regular "$jq_bin" && [ -x "$jq_bin" ] &&
  [ "$(sha256_path "$jq_bin")" = "$jq_sha" ] &&
  [ "$($jq_bin --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RELATION
index=0
while [ "$index" -lt 6 ]; do
  unchanged "${inputs[$index]}" "$scratch/${names[$index]}.json" ||
    emit_error E_RELATION
  index=$((index + 1))
done
/bin/cat "$scratch/evaluation.json" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
