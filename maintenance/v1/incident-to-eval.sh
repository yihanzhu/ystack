#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|E_FAMILY|E_WORKSPACE)
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
  # jq reads JSON streams: each input must be exactly one JSON text.
  "$jq_bin" -e -n --slurpfile roots "$raw" '($roots | length) == 1' >/dev/null 2>&1 ||
    emit_error E_PARSE
  "$jq_bin" -S -c . "$raw" > "$raw.canonical" 2>/dev/null || emit_error E_PARSE
  /usr/bin/cmp -s "$raw" "$raw.canonical" || emit_error E_CANONICAL
}

[ "$#" -eq 4 ] && [ "$1" = convert ] || emit_error E_USAGE
incident=$2
shadow=$3
output_dir=$4
for supplied in "$incident" "$shadow" "$output_dir"; do
  case "$supplied" in /*) ;; *) emit_error E_USAGE ;; esac
done

self=${BASH_SOURCE[0]}
case "$self" in /*) ;; *) self="$(pwd -P)/$self" ;; esac
[ -f "$self" ] && [ ! -L "$self" ] || emit_error E_RUNTIME
self_dir=$(CDPATH='' cd -P -- "${self%/*}" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
[ "$self" = "$self_dir/incident-to-eval.sh" ] || emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$self_dir/../.." 2>/dev/null && pwd -P) || emit_error E_RUNTIME
[ "$self_dir" = "$repo/maintenance/v1" ] || emit_error E_RUNTIME
catalog="$repo/evals/v1/eval-catalog.json"
seed_set="$repo/evals/v1/seed-set.json"
for component in "$self_dir/incident-to-eval.jq" "$self_dir/bands.jq" "$catalog" \
  "$seed_set"; do
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

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-maintenance-eval.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM
/bin/mkdir -m 0700 "$scratch/bin" "$scratch/lib" || emit_error E_RUNTIME

jq_bin="$scratch/bin/jq"
snapshot_bounded "$jq_source" "$jq_bin" 16777216 0500
[ "$(sha_file "$jq_bin")" = "$jq_sha" ] &&
  [ "$("$jq_bin" --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME

snapshot_bounded "$self_dir/bands.jq" "$scratch/lib/bands.jq" 262144 0400
snapshot_bounded "$self_dir/incident-to-eval.jq" "$scratch/lib/incident-to-eval.jq" \
  262144 0400
snapshot_bounded "$incident" "$scratch/incident.json" 262144 0400
snapshot_bounded "$shadow" "$scratch/shadow.json" 1048576 0400
snapshot_bounded "$catalog" "$scratch/catalog.json" 262144 0400
snapshot_bounded "$seed_set" "$scratch/seed-set.json" 4194304 0400
for named in incident shadow catalog seed-set; do
  canonical_json "$scratch/$named.json"
done
incident_sha=$(sha_file "$scratch/incident.json") || emit_error E_RUNTIME
shadow_sha=$(sha_file "$scratch/shadow.json") || emit_error E_RUNTIME
catalog_sha=$(sha_file "$scratch/catalog.json") || emit_error E_RUNTIME
seed_set_sha=$(sha_file "$scratch/seed-set.json") || emit_error E_RUNTIME

"$jq_bin" -S -c -n --arg incident_sha "$incident_sha" --arg shadow_sha "$shadow_sha" \
  --arg catalog_sha "$catalog_sha" --arg seed_set_sha "$seed_set_sha" \
  --slurpfile incident "$scratch/incident.json" \
  --slurpfile shadow "$scratch/shadow.json" \
  --slurpfile catalog "$scratch/catalog.json" \
  --slurpfile seed_set "$scratch/seed-set.json" '
  {incident:$incident[0],shadow:$shadow[0],catalog:$catalog[0],
   seed_set:$seed_set[0],
   digests:{incident:$incident_sha,shadow:$shadow_sha,catalog:$catalog_sha,
     seed_set:$seed_set_sha}}' > "$scratch/input.json" 2>/dev/null ||
  emit_error E_RUNTIME

shape=$(/usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin "$jq_bin" -L "$scratch/lib" -r \
  --arg operation shape -f "$scratch/lib/incident-to-eval.jq" "$scratch/input.json" \
  2>/dev/null) || emit_error E_RUNTIME
case "$shape" in
  '') ;;
  E_SHAPE|E_RELATION|E_FAMILY) emit_error "$shape" ;;
  *) emit_error E_RUNTIME ;;
esac

skeleton="$scratch/skeleton.json"
/usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin "$jq_bin" -L "$scratch/lib" -S -c \
  --arg operation convert -f "$scratch/lib/incident-to-eval.jq" "$scratch/input.json" \
  > "$skeleton" 2>/dev/null || emit_error E_RUNTIME
family=$("$jq_bin" -r '
  if type == "object" and .kind == "maintenance_eval_seed_skeleton" and
     (.body.family_id | type == "string" and test("\\A[a-z][a-z0-9-]{0,63}\\z"))
  then .body.family_id else "" end' "$skeleton" 2>/dev/null) || emit_error E_RUNTIME
[ -n "$family" ] || emit_error E_RUNTIME

[ -z "$(/usr/bin/find "$output_dir" -mindepth 1 -print -quit 2>/dev/null)" ] ||
  emit_error E_WORKSPACE
/bin/cp "$skeleton" "$output_dir/eval-seed-case-$family.json" || emit_error E_RUNTIME
/bin/chmod 0400 "$output_dir/eval-seed-case-$family.json" || emit_error E_RUNTIME

[ "$(sha_file "$scratch/incident.json")" = "$incident_sha" ] &&
  [ "$(sha_file "$scratch/shadow.json")" = "$shadow_sha" ] &&
  [ "$(sha_file "$scratch/catalog.json")" = "$catalog_sha" ] &&
  [ "$(sha_file "$scratch/seed-set.json")" = "$seed_set_sha" ] &&
  [ "$(sha_file "$jq_bin")" = "$jq_sha" ] || emit_error E_RUNTIME
/bin/cat "$skeleton" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
