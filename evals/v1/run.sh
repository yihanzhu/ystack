#!/bin/bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

emit_error() {
  local token=${1:-E_RUNTIME}
  case "$token" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|E_STALE) ;;
    *) token=E_RUNTIME ;;
  esac
  /usr/bin/printf '%s\n' "$token" >&2
  exit 1
}

sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
sha_line() {
  builtin printf '%s\n' "$1" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}
snapshot_file() {
  /usr/bin/perl -MFcntl=:DEFAULT,:mode -e '
    my ($source,$target,$limit,$mode)=@ARGV;
    sysopen(my $in,$source,O_RDONLY|O_NOFOLLOW) or exit 40;
    my @stat=stat($in); @stat && S_ISREG($stat[2]) or exit 40;
    $stat[7] <= $limit or exit 42;
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

[ "$#" -eq 2 ] && [ "$1" = evaluate ] || emit_error E_USAGE
input=$2
self=${BASH_SOURCE[0]}
case "$self" in /*) ;; *) self="$(pwd -P)/$self" ;; esac
[ -f "$self" ] && [ ! -L "$self" ] || emit_error E_RUNTIME
source_dir=$(CDPATH='' cd -P -- "${self%/*}" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
self="$source_dir/${self##*/}"
[ "$self" = "$source_dir/run.sh" ] || emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$source_dir/../.." 2>/dev/null && pwd -P) || emit_error E_RUNTIME
[ "$source_dir" = "$repo/evals/v1" ] || emit_error E_RUNTIME

program_sha=d164a102919f42ef002e93c8b515b58028604819e6c09b87c6e4afadb0bbcce4
schema_sha=8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade
registry_sha=3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94
platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) jq_asset=jq-osx-amd64; jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_asset=jq-linux64; jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) emit_error E_RUNTIME ;;
esac
jq_source=''
for candidate in "${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset" /usr/bin/jq; do
  if [ -f "$candidate" ] && [ ! -L "$candidate" ] &&
     [ "$(sha_file "$candidate")" = "$jq_sha" ]; then jq_source=$candidate; break; fi
done
[ -n "$jq_source" ] || emit_error E_RUNTIME

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-eval-run.XXXXXX") || emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM
snapshot_file "$input" "$scratch/input.json" 4194304 0400 || {
  status=$?; [ "$status" -eq 42 ] && emit_error E_LIMIT; emit_error E_RUNTIME;
}
snapshot_file "$source_dir/framework.jq" "$scratch/framework.jq" 1048576 0400 || emit_error E_RUNTIME
snapshot_file "$repo/core/v2/generation-registry.json" "$scratch/registry.json" 1048576 0400 ||
  emit_error E_RUNTIME
snapshot_file "$jq_source" "$scratch/jq" 33554432 0500 || emit_error E_RUNTIME
[ "$(sha_file "$scratch/framework.jq")" = "$program_sha" ] || emit_error E_STALE
[ "$(sha_file "$scratch/registry.json")" = "$registry_sha" ] || emit_error E_STALE
[ "$(sha_file "$scratch/jq")" = "$jq_sha" ] || emit_error E_RUNTIME
generation=$("$scratch/jq" -er '
  if type=="array" and length>=1 and
     all(.[]; .semantic_identity=="core.contracts.v2" and
       (.generation_id | type=="string" and test("\\Ag-[0-9a-f]{64}\\z")))
  then .[-1].generation_id else error("E_STALE") end
' "$scratch/registry.json" 2>/dev/null) || emit_error E_STALE
schema="$repo/core/v2/generations/$generation/modules/schema.jq"
snapshot_file "$schema" "$scratch/schema.jq" 1048576 0400 || emit_error E_STALE
[ "$(sha_file "$scratch/schema.jq")" = "$schema_sha" ] || emit_error E_STALE

if ! "$scratch/jq" -S -c . "$scratch/input.json" > "$scratch/canonical.json" 2>/dev/null; then
  emit_error E_PARSE
fi
# jq reads JSON streams, so canonical bytes alone would admit a file holding
# several bundles. The input must be exactly one JSON text.
"$scratch/jq" -e -n --slurpfile roots "$scratch/input.json" '($roots | length) == 1' \
  >/dev/null 2>&1 || emit_error E_PARSE
/usr/bin/cmp -s "$scratch/input.json" "$scratch/canonical.json" || emit_error E_CANONICAL
bundle_sha=$(sha_file "$scratch/input.json") || emit_error E_RUNTIME
if ! "$scratch/jq" -e '
  . as $bundle |
  type=="object" and (.body|type=="object") and
  (.body.suite|type=="object") and
  all(["cases","trials","grades"][]; . as $key | ($bundle.body[$key]|type)=="array") and
  (.body.cases|length)<=32 and (.body.trials|length)<=128 and (.body.grades|length)<=256
' "$scratch/input.json" >/dev/null 2>&1; then emit_error E_SHAPE; fi

: > "$scratch/measured.tsv"
for section in suite cases trials grades; do
  if [ "$section" = suite ]; then count=1; else
    count=$("$scratch/jq" -r --arg section "$section" '.body[$section]|length' "$scratch/input.json") ||
      emit_error E_SHAPE
  fi
  index=0
  while [ "$index" -lt "$count" ]; do
    value=$("$scratch/jq" -S -c --arg section "$section" --argjson index "$index" '
      if $section=="suite" then .body.suite.value else .body[$section][$index].value end
    ' "$scratch/input.json") || emit_error E_SHAPE
    /usr/bin/printf '%s\t%s\t%s\n' "$section" "$index" "$(sha_line "$value")" >> "$scratch/measured.tsv"
    index=$((index + 1))
  done
done
"$scratch/jq" -R -s -c '
  split("\n") | map(select(length>0) | split("\t") |
    {section:.[0],index:(.[1]|tonumber),sha256:.[2]})
' "$scratch/measured.tsv" > "$scratch/measured.json" || emit_error E_RUNTIME

status=0
/usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
  "$scratch/jq" -S -c -L "$scratch" --arg program_sha256 "$program_sha" \
  --arg bundle_sha256 "$bundle_sha" --slurpfile measured_docs "$scratch/measured.json" \
  -f "$scratch/framework.jq" "$scratch/input.json" > "$scratch/output.json" \
  2> "$scratch/error" || status=$?
if [ "$status" -ne 0 ]; then
  [ ! -s "$scratch/output.json" ] || emit_error E_RUNTIME
  for token in E_SHAPE E_STALE E_RELATION; do
    /usr/bin/grep -Fq "$token" "$scratch/error" && emit_error "$token"
  done
  emit_error E_RUNTIME
fi
[ ! -s "$scratch/error" ] || emit_error E_RUNTIME
status=0
snapshot_file "$scratch/output.json" "$scratch/bounded-output.json" 1048576 0400 || status=$?
[ "$status" -eq 0 ] || { [ "$status" -eq 42 ] && emit_error E_LIMIT; emit_error E_RUNTIME; }
"$scratch/jq" -S -c . "$scratch/bounded-output.json" > "$scratch/canonical-output.json" 2>/dev/null ||
  emit_error E_RUNTIME
/usr/bin/cmp -s "$scratch/bounded-output.json" "$scratch/canonical-output.json" || emit_error E_RUNTIME
[ "$(sha_file "$scratch/input.json")" = "$bundle_sha" ] || emit_error E_RUNTIME
[ "$(sha_file "$scratch/framework.jq")" = "$program_sha" ] || emit_error E_RUNTIME
[ "$(sha_file "$scratch/schema.jq")" = "$schema_sha" ] || emit_error E_RUNTIME
[ "$(sha_file "$scratch/registry.json")" = "$registry_sha" ] || emit_error E_RUNTIME
[ "$(sha_file "$scratch/jq")" = "$jq_sha" ] || emit_error E_RUNTIME
/bin/cat "$scratch/bounded-output.json" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
