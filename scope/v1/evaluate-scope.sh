#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|E_STALE)
      /usr/bin/printf '%s\n' "$1" >&2
      ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

[ "$#" -eq 10 ] && [ "$1" = evaluate ] || emit_error E_USAGE
shift
documents=("$1" "$2" "$3" "$4" "$5" "$6" "$7")
bundle_root=$8
source_git=$9
source_path=${BASH_SOURCE[0]}
case "$source_path" in /*) ;; *) source_path="$(pwd -P)/$source_path" ;; esac
source_dir=$(CDPATH='' cd -P -- "${source_path%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
source_path="$source_dir/${source_path##*/}"
[ "$source_path" = "$source_dir/evaluate-scope.sh" ] || emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$source_dir/../.." 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
[ "$source_dir" = "$repo/scope/v1" ] || emit_error E_RUNTIME
policy="$source_dir/scope-policy.json"
record_program="$source_dir/workflow-scope.jq"
program="$source_dir/scope-gates.jq"
mode_marker="$repo/config/construction-mode.json"
for required in "$source_path" "$policy" "$record_program" "$program"; do
  [ -f "$required" ] && [ ! -L "$required" ] || emit_error E_RUNTIME
done
for input in "${documents[@]}"; do
  [ -f "$input" ] && [ ! -L "$input" ] || emit_error E_RUNTIME
done
jq_bin=$(command -v jq 2>/dev/null) || emit_error E_RUNTIME
case "$jq_bin" in /*) ;; *) emit_error E_RUNTIME ;; esac
[ -f "$jq_bin" ] && [ -x "$jq_bin" ] && [ ! -L "$jq_bin" ] &&
  [ "$($jq_bin --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-scope-evaluate.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
/bin/mkdir -m 700 "$scratch/observation" || emit_error E_RUNTIME
reader_pid=''
control_open=false
control_verified=false
finish_reader() {
  if [ "$control_open" = true ]; then
    if [ "$control_verified" = true ]; then /usr/bin/printf 'CANCEL\n' >&7 || :; fi
    exec 7>&-
    control_open=false
  fi
  if [ -n "$reader_pid" ]; then
    wait "$reader_pid" 2>/dev/null || :
    reader_pid=''
  fi
}
cleanup() { finish_reader; exec 8<&-; /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; /usr/bin/printf '%s\n' E_RUNTIME >&2; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM

snapshot() {
  local source=$1 target=$2 size bom
  /bin/dd if="$source" of="$target" bs=1048577 count=1 2>/dev/null ||
    emit_error E_RUNTIME
  size=$(/usr/bin/wc -c <"$target" | /usr/bin/tr -d ' ') || emit_error E_RUNTIME
  [ "$size" -le 1048576 ] || emit_error E_LIMIT
  bom=$(/usr/bin/od -An -tx1 -N3 "$target" 2>/dev/null | /usr/bin/tr -d ' \n') ||
    emit_error E_RUNTIME
  [ "$bom" != efbbbf ] || emit_error E_PARSE
  "$jq_bin" -e 'type == "object"' "$target" >/dev/null 2>&1 || emit_error E_PARSE
  [ "$("$jq_bin" -s 'length' "$target" 2>/dev/null)" = 1 ] || emit_error E_PARSE
}
canonicalize() {
  "$jq_bin" -S -c . "$1" >"$2" 2>/dev/null || emit_error E_PARSE
}
require_canonical() {
  canonicalize "$1" "$1.canonical"
  /usr/bin/cmp -s "$1" "$1.canonical" || emit_error E_CANONICAL
}

names=(scope shadow-set dashboard risk kill duty marker)
index=0
for input in "${documents[@]}"; do
  snapshot "$input" "$scratch/${names[$index]}.json"
  index=$((index + 1))
done
for canonical in scope shadow-set dashboard risk kill duty marker; do
  require_canonical "$scratch/$canonical.json"
done
snapshot "$policy" "$scratch/policy.json"
require_canonical "$scratch/policy.json"

record_result=$("$jq_bin" -r -f "$record_program" "$scratch/scope.json" 2>/dev/null) ||
  emit_error E_RUNTIME
case "$record_result" in
  '') ;;
  E_SHAPE|E_RELATION) emit_error "$record_result" ;;
  *) emit_error E_RUNTIME ;;
esac

"$jq_bin" -e '
  (keys | sort) == ["body","id","kind","schema_version"] and
  .schema_version == 1 and .kind == "scope_qualification_policy" and
  .id == "scope-policy.qualification" and
  .body.activation_state == "inactive" and .body.authority == "none" and
  .body.fail_mode == "closed" and .body.policy_version == "v1" and
  .body.proposable_risk_tiers == ["routine"] and
  .body.required_eval_seed_status == "seeded" and
  .body.accepted_shadow_outcomes == ["no-change","reproduced"] and
  .body.refused_shadow_outcomes == ["inconclusive"] and
  .body.outcomes == ["not-proposable","proposable"] and
  (.body.protected_path_prefixes | length >= 1) and
  (.body.protected_root_files | length >= 1) and
  (.body.protected_path_segments | length >= 1)
' "$scratch/policy.json" >/dev/null 2>&1 || emit_error E_RELATION

# The operating-mode marker is read from the repository read-only and only ever
# compared. A supplied marker that disagrees with the committed one leaves the
# mode unknown, and the evaluator refuses rather than guessing. The supplied
# marker must already be canonical, so the committed one is put into canonical
# form in the scratch directory before the byte comparison: two markers are the
# same marker when their canonical bytes agree. The committed file is only read.
mode_repo_state=absent
committed_marker_sha=''
# A committed marker that exists as anything but a regular file (a symlink, a
# directory, a device) is not "absent": it is a tree this evaluator cannot read
# the mode from, and it refuses rather than letting a supplied marker decide.
if [ -e "$mode_marker" ] || [ -L "$mode_marker" ]; then
  [ -f "$mode_marker" ] && [ ! -L "$mode_marker" ] || emit_error E_RUNTIME
fi
if [ -f "$mode_marker" ] && [ ! -L "$mode_marker" ]; then
  snapshot "$mode_marker" "$scratch/repo-marker.json"
  committed_marker_sha=$(sha256_path "$scratch/repo-marker.json") ||
    emit_error E_RUNTIME
  canonicalize "$scratch/repo-marker.json" "$scratch/repo-marker-canonical.json"
  if /usr/bin/cmp -s "$scratch/marker.json" "$scratch/repo-marker-canonical.json"; then
    mode_repo_state=matched
  else
    mode_repo_state=differs
  fi
fi

record_count=$("$jq_bin" -r '
  if (.body | type) == "object" and (.body.records | type) == "array"
  then (.body.records | length) else 0 end
' "$scratch/shadow-set.json" 2>/dev/null) || emit_error E_RUNTIME
case "$record_count" in ''|*[!0-9]*) emit_error E_RUNTIME ;; esac
[ "$record_count" -le 16 ] || record_count=0
: >"$scratch/record-shas.txt"
record_index=0
while [ "$record_index" -lt "$record_count" ]; do
  "$jq_bin" -S -c --argjson i "$record_index" '.body.records[$i]' \
    "$scratch/shadow-set.json" >"$scratch/record.json" 2>/dev/null ||
    emit_error E_RUNTIME
  sha256_path "$scratch/record.json" >>"$scratch/record-shas.txt" ||
    emit_error E_RUNTIME
  record_index=$((record_index + 1))
done
record_shas=$("$jq_bin" -R -s -c 'split("\n") | map(select(length > 0))' \
  <"$scratch/record-shas.txt") || emit_error E_RUNTIME

reader="$source_dir/read-shadow-evidence.py"
[ -f "$reader" ] && [ ! -L "$reader" ] || emit_error E_RUNTIME
python_bin=$(command -v python3 2>/dev/null) || emit_error E_RUNTIME
python_bin=$("$python_bin" -I -S -B -c 'import os,sys;print(os.path.realpath(sys.executable))' 2>/dev/null) || emit_error E_RUNTIME
case "$python_bin" in /*) ;; *) emit_error E_RUNTIME ;; esac
reader_sha=$(sha256_path "$reader") || emit_error E_RUNTIME
consumer_sha=$(sha256_path "$repo/shadow/v1/_consumer.py") || emit_error E_RUNTIME
python_sha=$(sha256_path "$python_bin") || emit_error E_RUNTIME
jq_sha=$(sha256_path "$jq_bin") || emit_error E_RUNTIME
/usr/bin/mkfifo -m 600 "$scratch/reader-control" "$scratch/reader-ready" || emit_error E_RUNTIME
/bin/mkdir -m 700 "$scratch/reader-captures" "$scratch/reader-runtime" "$scratch/reader-runtime/no-hooks" || emit_error E_RUNTIME
exec 7<>"$scratch/reader-control"
exec 8<>"$scratch/reader-ready"
control_open=true
/usr/bin/perl -MFcntl=F_GETFL,F_SETFL,O_NONBLOCK -e '
  my $flags = fcntl(STDIN, F_GETFL, 0);
  defined($flags) && fcntl(STDIN, F_SETFL, $flags | O_NONBLOCK) or exit 1;
' <&7 || emit_error E_RUNTIME
for prepared in observation.json observation.json.canonical evaluation.json evaluation.json.canonical reader-stderr; do
  : >"$scratch/$prepared" || emit_error E_RUNTIME
done
/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C YSTACK_SCOPE_JQ="$jq_bin" \
  /usr/bin/perl -e 'alarm 300; exec @ARGV; die "exec failed: $!\n"' "$python_bin" -I -S -B "$reader" read \
  "$scratch/scope.json" "$scratch/shadow-set.json" "$bundle_root" "$source_git" \
  "$scratch/observation/result.json" <&7 >&8 2>"$scratch/reader-stderr" 7>&- 8>&- &
reader_pid=$!
exec 9<"$scratch/reader-ready"
exec 8<&9
exec 9<&-
ready=''
if ! IFS= read -r -t 300 -n 16 ready <&8; then
  finish_reader
  reader_error=$(/bin/cat "$scratch/reader-stderr") || emit_error E_RUNTIME
  emit_error "$reader_error"
fi
[ "$ready" = READY ] || emit_error E_RUNTIME
control_verified=true
snapshot "$scratch/observation/result.json" "$scratch/observation.json"
require_canonical "$scratch/observation.json"

policy_sha=$(sha256_path "$scratch/policy.json") || emit_error E_RUNTIME
scope_sha=$(sha256_path "$scratch/scope.json") || emit_error E_RUNTIME
shadow_set_sha=$(sha256_path "$scratch/shadow-set.json") || emit_error E_RUNTIME
dashboard_sha=$(sha256_path "$scratch/dashboard.json") || emit_error E_RUNTIME
risk_sha=$(sha256_path "$scratch/risk.json") || emit_error E_RUNTIME
kill_sha=$(sha256_path "$scratch/kill.json") || emit_error E_RUNTIME
duty_sha=$(sha256_path "$scratch/duty.json") || emit_error E_RUNTIME
marker_sha=$(sha256_path "$scratch/marker.json") || emit_error E_RUNTIME
program_sha=$(sha256_path "$program") || emit_error E_RUNTIME
record_program_sha=$(sha256_path "$record_program") || emit_error E_RUNTIME
driver_sha=$(sha256_path "$source_path") || emit_error E_RUNTIME

"$jq_bin" -S -c -n -f "$program" \
  --slurpfile policy "$scratch/policy.json" \
  --slurpfile scope "$scratch/scope.json" \
  --slurpfile shadow_set "$scratch/shadow-set.json" \
  --slurpfile dashboard "$scratch/dashboard.json" \
  --slurpfile risk "$scratch/risk.json" \
  --slurpfile kill "$scratch/kill.json" \
  --slurpfile duty "$scratch/duty.json" \
  --slurpfile marker "$scratch/marker.json" \
  --slurpfile measured "$scratch/observation.json" \
  --argjson record_shas "$record_shas" \
  --arg mode_repo_state "$mode_repo_state" \
  --arg policy_sha "$policy_sha" --arg scope_sha "$scope_sha" \
  --arg shadow_set_sha "$shadow_set_sha" --arg dashboard_sha "$dashboard_sha" \
  --arg risk_sha "$risk_sha" --arg kill_sha "$kill_sha" \
  --arg duty_sha "$duty_sha" --arg marker_sha "$marker_sha" \
  >"$scratch/evaluation.json" 2>/dev/null || emit_error E_RUNTIME

[ "$(sha256_path "$reader")" = "$reader_sha" ] &&
  [ "$(sha256_path "$repo/shadow/v1/_consumer.py")" = "$consumer_sha" ] &&
  [ "$(sha256_path "$python_bin")" = "$python_sha" ] &&
  [ "$(sha256_path "$jq_bin")" = "$jq_sha" ] &&
  /usr/bin/cmp -s "$scratch/observation.json" "$scratch/observation/result.json" &&
  [ "$(sha256_path "$policy")" = "$policy_sha" ] &&
  [ "$(sha256_path "$program")" = "$program_sha" ] &&
  [ "$(sha256_path "$record_program")" = "$record_program_sha" ] &&
  [ "$(sha256_path "$source_path")" = "$driver_sha" ] || emit_error E_RELATION
index=0
for input in "${documents[@]}"; do
  [ -f "$input" ] && [ ! -L "$input" ] || emit_error E_STALE
  /usr/bin/cmp -s "$input" "$scratch/${names[$index]}.json" || emit_error E_STALE
  index=$((index + 1))
done
# The committed marker is an input to the result too: the snapshot above decided
# both the operating mode and the `repository_marker` field, so marker bytes
# that changed during the run would leave the evaluation describing a marker the
# repository no longer holds. It is rechecked here like every other input, and a
# marker that appeared, vanished, or changed makes the run stale.
if [ -n "$committed_marker_sha" ]; then
  [ -f "$mode_marker" ] && [ ! -L "$mode_marker" ] &&
    [ "$(sha256_path "$mode_marker")" = "$committed_marker_sha" ] ||
    emit_error E_STALE
elif [ -e "$mode_marker" ] || [ -L "$mode_marker" ]; then
  # Anything that appeared at the marker path mid-run, regular or not, means
  # the repository's mode is no longer what this run read.
  emit_error E_STALE
fi
require_canonical "$scratch/evaluation.json"

"$jq_bin" -e --arg scope_id "$(
  "$jq_bin" -r '.id' "$scratch/scope.json")" --arg scope_sha "$scope_sha" '
  (keys | sort) == ["body","id","kind","schema_version"] and
  .schema_version == 1 and .kind == "scope_qualification_evaluation" and
  .id == $scope_id and
  (.body | keys | sort) == ["activation_state","authority","authority_effect",
    "enabled","evaluation_mode","evidence","operating_mode","outcome","proposal",
    "qualification","reason_ids","reference_semantics","scope_ref"] and
  .body.activation_state == "inactive" and .body.authority == "none" and
  .body.authority_effect == "none" and .body.enabled == false and
  .body.evaluation_mode == "observation-only" and
  .body.reference_semantics == "identity-only" and
  .body.qualification.state == "unavailable" and
  .body.scope_ref.sha256 == $scope_sha and
  (.body.outcome as $outcome |
   ["not-proposable","proposable"] | index($outcome) != null) and
  (.body.reason_ids |
   type == "array" and length >= 1 and all(.[]; type == "string") and
   . == (sort | unique)) and
  (if .body.outcome == "proposable"
   then .body.reason_ids == ["scope.proposable"] and
        .body.proposal.state == "present" and
        .body.proposal.document.kind == "scope_enablement_proposal" and
        .body.proposal.document.body.enabled == false and
        .body.proposal.document.body.push_allowed == false and
        .body.proposal.document.body.risk_tier == "routine" and
        .body.proposal.document.body.authority == "none" and
        .body.proposal.document.body.enablement.state == "blocked" and
        .body.proposal.document.body.qualification.state == "unavailable"
   else (.body.reason_ids | index("scope.proposable")) == null and
        .body.proposal == {state: "absent"} end) and
  ((.body | has("grant_ref") or has("activation") or has("qualification_ref")) | not)
' "$scratch/evaluation.json" >/dev/null 2>&1 || emit_error E_RUNTIME

/usr/bin/printf 'SEAL\n' >&7 || emit_error E_RUNTIME
exec 7>&-
control_open=false
reader_status=0
wait "$reader_pid" || reader_status=$?
reader_pid=''
[ "$(/usr/bin/wc -c <"$scratch/reader-stderr" | /usr/bin/tr -d ' ')" -le 65536 ] || emit_error E_LIMIT
if [ "$reader_status" -ne 0 ]; then
  reader_error=$(/bin/cat "$scratch/reader-stderr") || emit_error E_RUNTIME
  emit_error "$reader_error"
fi
[ ! -s "$scratch/reader-stderr" ] || emit_error E_RUNTIME
extra=''
if IFS= read -r -n 1 extra <&8 || [ -n "$extra" ]; then emit_error E_RUNTIME; fi
exec 8<&-

/bin/cat "$scratch/evaluation.json" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
