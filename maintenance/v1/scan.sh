#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|E_WORKSPACE)
      /usr/bin/printf '%s\n' "$1" >&2 ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

snapshot_file() {
  /usr/bin/perl -MFcntl=:DEFAULT,:mode -e '
    my ($source,$target,$limit,$mode)=@ARGV;
    my @leaf=lstat($source); @leaf && S_ISREG($leaf[2]) or exit 40;
    sysopen(my $in,$source,O_RDONLY|O_NOFOLLOW) or exit 40;
    my @stat=stat($in); @stat && S_ISREG($stat[2]) or exit 40;
    sysopen(my $out,$target,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,oct($mode)) or exit 40;
    my $total=0;
    while (1) {
      my $read=sysread($in,my $buffer,65536); defined($read) or exit 40;
      last if $read==0; $total += $read; $total <= $limit or exit 42;
      my $offset=0;
      while ($offset < $read) {
        my $written=syswrite($out,$buffer,$read-$offset,$offset);
        defined($written) && $written>0 or exit 40; $offset += $written;
      }
    }
    close($in) or exit 40; close($out) or exit 40;
    chmod(oct($mode),$target)==1 or exit 40;
  ' "$1" "$2" "$3" "$4"
}

snapshot_bounded() {
  local status=0
  snapshot_file "$1" "$2" "$3" "$4" || status=$?
  [ "$status" -eq 0 ] && return 0
  [ "$status" -eq 42 ] && emit_error E_LIMIT
  emit_error E_RUNTIME
}

canonical_json() {
  local raw=$1 bom
  bom=$(/usr/bin/od -An -tx1 -N3 "$raw" 2>/dev/null | /usr/bin/tr -d ' \n') ||
    emit_error E_RUNTIME
  [ "$bom" != efbbbf ] || emit_error E_PARSE
  "$jq_bin" . "$raw" >/dev/null 2>&1 || emit_error E_PARSE
  # jq reads JSON streams, so canonical bytes alone would admit several documents
  # in one file. Each input must be exactly one JSON text.
  "$jq_bin" -e -n --slurpfile roots "$raw" '($roots | length) == 1' >/dev/null 2>&1 ||
    emit_error E_PARSE
  "$jq_bin" -S -c . "$raw" > "$raw.canonical" 2>/dev/null || emit_error E_PARSE
  /usr/bin/cmp -s "$raw" "$raw.canonical" || emit_error E_CANONICAL
}

[ "$#" -ge 5 ] && [ "$#" -le 37 ] && [ "$1" = scan ] || emit_error E_USAGE
shift
dashboard=$1
ledger=$2
kill_switch=$3
output_dir=$4
shift 4
for supplied in "$dashboard" "$ledger" "$kill_switch" "$output_dir" "$@"; do
  case "$supplied" in /*) ;; *) emit_error E_USAGE ;; esac
done

self=${BASH_SOURCE[0]}
case "$self" in /*) ;; *) self="$(pwd -P)/$self" ;; esac
[ -f "$self" ] && [ ! -L "$self" ] || emit_error E_RUNTIME
self_dir=$(CDPATH='' cd -P -- "${self%/*}" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
[ "$self" = "$self_dir/scan.sh" ] || emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$self_dir/../.." 2>/dev/null && pwd -P) || emit_error E_RUNTIME
[ "$self_dir" = "$repo/maintenance/v1" ] || emit_error E_RUNTIME
trace_validator="$repo/telemetry/v1/validate-trace-ledger.sh"
for component in "$self_dir/scan.jq" "$self_dir/bands.jq" \
  "$self_dir/control-bands.json" "$trace_validator"; do
  [ -f "$component" ] && [ ! -L "$component" ] || emit_error E_RUNTIME
done

[ -d "$output_dir" ] && [ ! -L "$output_dir" ] &&
  [ "$output_dir" = "$(CDPATH='' cd -P -- "$output_dir" 2>/dev/null && pwd -P)" ] ||
  emit_error E_WORKSPACE
[ -z "$(/usr/bin/find "$output_dir" -mindepth 1 -print -quit 2>/dev/null)" ] ||
  emit_error E_WORKSPACE

case "$(/usr/bin/uname -s):$(/usr/bin/uname -m)" in
  Darwin:*) jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) emit_error E_RUNTIME ;;
esac
jq_source=$(command -v jq 2>/dev/null) || emit_error E_RUNTIME
case "$jq_source" in /*) ;; *) emit_error E_RUNTIME ;; esac
[ -f "$jq_source" ] && [ ! -L "$jq_source" ] || emit_error E_RUNTIME

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-maintenance-scan.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM
/bin/mkdir -m 0700 "$scratch/bin" "$scratch/lib" "$scratch/out" || emit_error E_RUNTIME

jq_bin="$scratch/bin/jq"
snapshot_bounded "$jq_source" "$jq_bin" 16777216 0500
[ "$(sha_file "$jq_bin")" = "$jq_sha" ] &&
  [ "$("$jq_bin" --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME

snapshot_bounded "$self_dir/bands.jq" "$scratch/lib/bands.jq" 262144 0400
snapshot_bounded "$self_dir/scan.jq" "$scratch/lib/scan.jq" 262144 0400
snapshot_bounded "$self_dir/control-bands.json" "$scratch/bands.json" 262144 0400
snapshot_bounded "$dashboard" "$scratch/dashboard.json" 1048576 0400
snapshot_bounded "$ledger" "$scratch/ledger.json" 1048576 0400
snapshot_bounded "$kill_switch" "$scratch/kill-switch.json" 262144 0400
for named in bands dashboard ledger kill-switch; do
  canonical_json "$scratch/$named.json"
done
bands_sha=$(sha_file "$scratch/bands.json") || emit_error E_RUNTIME
dashboard_sha=$(sha_file "$scratch/dashboard.json") || emit_error E_RUNTIME
ledger_sha=$(sha_file "$scratch/ledger.json") || emit_error E_RUNTIME
kill_switch_sha=$(sha_file "$scratch/kill-switch.json") || emit_error E_RUNTIME

# The ledger must be a sealed one: the telemetry validator re-derives its digest
# chain before any band counts an event in it.
ledger_session=$("$jq_bin" -r '.body.session_id // ""' "$scratch/ledger.json") ||
  emit_error E_RUNTIME
ledger_attempt=$("$jq_bin" -r '.body.attempt_id // ""' "$scratch/ledger.json") ||
  emit_error E_RUNTIME
[ -n "$ledger_session" ] && [ -n "$ledger_attempt" ] || emit_error E_SHAPE
PATH="$scratch/bin:/usr/bin:/bin" "$trace_validator" validate "$ledger_session" \
  "$ledger_attempt" "$scratch/ledger.json" >/dev/null 2>&1 || emit_error E_RELATION

: > "$scratch/findings.txt"
: > "$scratch/rehearsals.txt"
extra=0
for supplied in "$@"; do
  extra=$((extra + 1))
  snapshot_bounded "$supplied" "$scratch/extra-$extra.json" 262144 0400
  canonical_json "$scratch/extra-$extra.json"
  kind=$("$jq_bin" -r 'if type == "object" and (.kind | type == "string")
    then .kind else "" end' "$scratch/extra-$extra.json") || emit_error E_RUNTIME
  case "$kind" in
    maintenance_scan_finding) list="$scratch/findings.txt" ;;
    rollback_rehearsal_record) list="$scratch/rehearsals.txt" ;;
    *) emit_error E_SHAPE ;;
  esac
  /usr/bin/printf '%s\t%s\n' "$scratch/extra-$extra.json" \
    "$(sha_file "$scratch/extra-$extra.json")" >> "$list" || emit_error E_RUNTIME
done

collect() {
  local listing=$1 out="$2" entry path digest
  : > "$out"
  while IFS=$'\t' read -r path digest; do
    [ -n "$path" ] || continue
    entry=$("$jq_bin" -S -c -n --arg sha "$digest" --slurpfile document "$path" \
      '{document:$document[0],sha256:$sha}' 2>/dev/null) || emit_error E_RUNTIME
    [ -n "$entry" ] || emit_error E_RUNTIME
    /usr/bin/printf '%s\n' "$entry" >> "$out" || emit_error E_RUNTIME
  done < "$listing"
}
collect "$scratch/findings.txt" "$scratch/findings.jsonl"
collect "$scratch/rehearsals.txt" "$scratch/rehearsals.jsonl"

"$jq_bin" -S -c -n --arg bands_sha "$bands_sha" --arg dashboard_sha "$dashboard_sha" \
  --arg ledger_sha "$ledger_sha" --arg kill_switch_sha "$kill_switch_sha" \
  --slurpfile bands "$scratch/bands.json" \
  --slurpfile dashboard "$scratch/dashboard.json" \
  --slurpfile ledger "$scratch/ledger.json" \
  --slurpfile kill_switch "$scratch/kill-switch.json" \
  --slurpfile findings "$scratch/findings.jsonl" \
  --slurpfile rehearsals "$scratch/rehearsals.jsonl" '
  {bands:{document:$bands[0],sha256:$bands_sha},
   dashboard:{document:$dashboard[0],sha256:$dashboard_sha},
   ledger:{document:$ledger[0],sha256:$ledger_sha},
   kill_switch:{document:$kill_switch[0],sha256:$kill_switch_sha},
   findings:$findings,rehearsals:$rehearsals}' > "$scratch/bundle.json" 2>/dev/null ||
  emit_error E_RUNTIME

shape=$(/usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin "$jq_bin" -L "$scratch/lib" -r \
  --arg operation shape -f "$scratch/lib/scan.jq" "$scratch/bundle.json" 2>/dev/null) ||
  emit_error E_RUNTIME
case "$shape" in
  '') ;;
  E_SHAPE|E_RELATION) emit_error "$shape" ;;
  *) emit_error E_RUNTIME ;;
esac

result="$scratch/result.json"
/usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin "$jq_bin" -L "$scratch/lib" -S -c \
  --arg operation scan -f "$scratch/lib/scan.jq" "$scratch/bundle.json" \
  > "$result" 2>/dev/null || emit_error E_RUNTIME
"$jq_bin" -e 'type == "object" and (.scan | type == "object") and
  (.intents | type == "array" and length <= 40)' "$result" >/dev/null 2>&1 ||
  emit_error E_RUNTIME

"$jq_bin" -S -c '.scan' "$result" > "$scratch/out/maintenance-scan.json" 2>/dev/null ||
  emit_error E_RUNTIME
intent_count=$("$jq_bin" -r '.intents | length' "$result") || emit_error E_RUNTIME
index=0
while [ "$index" -lt "$intent_count" ]; do
  name=$("$jq_bin" -r --argjson i "$index" '.intents[$i].file_name' "$result") ||
    emit_error E_RUNTIME
  case "$name" in
    intent-band-*.json|intent-finding-*.json) ;;
    *) emit_error E_RUNTIME ;;
  esac
  [ ! -e "$scratch/out/$name" ] || emit_error E_RELATION
  "$jq_bin" -S -c --argjson i "$index" '.intents[$i].document' "$result" \
    > "$scratch/out/$name" 2>/dev/null || emit_error E_RUNTIME
  index=$((index + 1))
done

[ -z "$(/usr/bin/find "$output_dir" -mindepth 1 -print -quit 2>/dev/null)" ] ||
  emit_error E_WORKSPACE
for written in "$scratch/out"/*.json; do
  /bin/cp "$written" "$output_dir/${written##*/}" || emit_error E_RUNTIME
  /bin/chmod 0400 "$output_dir/${written##*/}" || emit_error E_RUNTIME
done

[ "$(sha_file "$scratch/bands.json")" = "$bands_sha" ] &&
  [ "$(sha_file "$scratch/dashboard.json")" = "$dashboard_sha" ] &&
  [ "$(sha_file "$scratch/ledger.json")" = "$ledger_sha" ] &&
  [ "$(sha_file "$scratch/kill-switch.json")" = "$kill_switch_sha" ] &&
  [ "$(sha_file "$jq_bin")" = "$jq_sha" ] || emit_error E_RUNTIME
/bin/cat "$scratch/out/maintenance-scan.json" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
