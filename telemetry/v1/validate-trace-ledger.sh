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

physical_leaf() {
  local candidate=$1 parent name physical_parent
  case "$candidate" in /*) ;; *) candidate="$(pwd -P)/$candidate" ;; esac
  parent=${candidate%/*}
  name=${candidate##*/}
  [ -n "$name" ] || return 1
  physical_parent=$(CDPATH='' cd -P -- "$parent" 2>/dev/null && pwd -P) || return 1
  PHYSICAL_LEAF="$physical_parent/$name"
}

snapshot_regular() {
  local source=$1 target=$2 limit=$3 mode=$4 snapshot_status=0
  SNAPSHOT_DIGEST=$(/usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/perl -MFcntl=:DEFAULT,:mode -MDigest::SHA -MCwd=abs_path -e '
      use strict; use warnings;
      my ($source,$target,$limit,$mode)=@ARGV;
      my ($parent,$name)=$source =~ m{\A(.+)/([^/]+)\z};
      exit 2 unless defined($parent) && defined($name) &&
        defined(abs_path($parent)) && abs_path($parent) eq $parent;
      my @parent=lstat($parent); my @leaf=lstat($source);
      exit 2 unless @parent && @leaf && S_ISDIR($parent[2]) && S_ISREG($leaf[2]);
      chdir($parent) or exit 2;
      sysopen(my $in,$name,O_RDONLY|O_NOFOLLOW) or exit 2;
      binmode($in); my @opened=stat($in); my @cwd=stat(".");
      exit 2 unless @opened && @cwd && S_ISREG($opened[2]) &&
        $leaf[0]==$opened[0] && $leaf[1]==$opened[1] &&
        $leaf[7]==$opened[7] && $leaf[9]==$opened[9] && $leaf[10]==$opened[10] &&
        $parent[0]==$cwd[0] && $parent[1]==$cwd[1];
      sysopen(my $out,$target,O_WRONLY|O_CREAT|O_EXCL,oct($mode)) or exit 2;
      binmode($out); my $sha=Digest::SHA->new(256); my $total=0;
      while (1) {
        my $read=sysread($in,my $buffer,65536);
        exit 2 unless defined($read); last if $read==0;
        $total += $read; exit 3 if $total > $limit;
        print {$out} $buffer or exit 2; $sha->add($buffer);
      }
      close($out) or exit 2;
      my @after=stat($in); my @path_after=lstat($name); my @parent_after=stat(".");
      exit 2 unless @after && @path_after && @parent_after && S_ISREG($path_after[2]) &&
        $opened[0]==$after[0] && $opened[1]==$after[1] &&
        $opened[7]==$after[7] && $opened[9]==$after[9] && $opened[10]==$after[10] &&
        $after[0]==$path_after[0] && $after[1]==$path_after[1] &&
        $after[7]==$path_after[7] && $after[9]==$path_after[9] &&
        $after[10]==$path_after[10] && $cwd[0]==$parent_after[0] &&
        $cwd[1]==$parent_after[1];
      print $sha->hexdigest,"\n";
    ' "$source" "$target" "$limit" "$mode" 2>/dev/null) || snapshot_status=$?
  case "$snapshot_status" in
    0) [ "$SNAPSHOT_DIGEST" ] || emit_error E_RUNTIME ;;
    3) emit_error E_LIMIT ;;
    *) emit_error E_RUNTIME ;;
  esac
}

expected_jq_digest() {
  case "$(/usr/bin/uname -s):$(/usr/bin/uname -m)" in
    Darwin:*) /usr/bin/printf '%s\n' 5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
    Linux:x86_64) /usr/bin/printf '%s\n' af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
    *) return 1 ;;
  esac
}

[ "$#" -eq 4 ] && [ "$1" = validate ] || emit_error E_USAGE
expected_session=$2
expected_attempt=$3
input=$4
[[ "$expected_session" =~ ^[a-z0-9][a-z0-9._:-]{0,127}$ ]] || emit_error E_USAGE
[[ "$expected_attempt" =~ ^[a-z0-9][a-z0-9._:-]{0,127}$ ]] || emit_error E_USAGE
self=${BASH_SOURCE[0]}
case "$self" in /*) ;; *) self="$(pwd -P)/$self" ;; esac
[ -f "$self" ] && [ ! -L "$self" ] || emit_error E_RUNTIME
self_dir=$(CDPATH='' cd -P -- "${self%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
self="$self_dir/${self##*/}"
[ "$self" = "$self_dir/validate-trace-ledger.sh" ] || emit_error E_RUNTIME
program="$self_dir/trace-ledger.jq"
physical_leaf "$input" || emit_error E_RUNTIME
input=$PHYSICAL_LEAF

jq_source=$(command -v jq 2>/dev/null) || emit_error E_RUNTIME
physical_leaf "$jq_source" || emit_error E_RUNTIME
jq_source=$PHYSICAL_LEAF
jq_sha=$(expected_jq_digest) || emit_error E_RUNTIME

scratch=$(/usr/bin/mktemp -d /tmp/ystack-trace-ledger.XXXXXX 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM

jq_bin="$scratch/jq"
snapshot_regular "$jq_source" "$jq_bin" 8388608 0500
[ "$SNAPSHOT_DIGEST" = "$jq_sha" ] &&
  [ "$($jq_bin --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME

raw="$scratch/ledger.json"
program_copy="$scratch/program.jq"
snapshot_regular "$input" "$raw" 1048576 0400
input_sha=$SNAPSHOT_DIGEST
snapshot_regular "$program" "$program_copy" 1048576 0400
program_sha=$SNAPSHOT_DIGEST

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
  --arg expected_session "$expected_session" --arg expected_attempt "$expected_attempt" \
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
  --arg ledger_sha "$input_sha" --arg expected_session "$expected_session" \
  --arg expected_attempt "$expected_attempt" \
  --argjson event_digests "$(/bin/cat "$scratch/digests.json")" \
  -f "$program_copy" "$raw" 2>/dev/null) || emit_error E_RUNTIME
case "$result" in E_SHAPE|E_RELATION) emit_error "$result" ;; E_*) emit_error E_RUNTIME ;; esac
snapshot_regular "$input" "$scratch/input-post.json" 1048576 0400
[ "$SNAPSHOT_DIGEST" = "$input_sha" ] || emit_error E_RUNTIME
snapshot_regular "$program" "$scratch/program-post.jq" 1048576 0400
[ "$SNAPSHOT_DIGEST" = "$program_sha" ] || emit_error E_RUNTIME
snapshot_regular "$jq_source" "$scratch/jq-post" 8388608 0400
[ "$SNAPSHOT_DIGEST" = "$jq_sha" ] || emit_error E_RUNTIME
[ -f "$raw" ] && [ ! -L "$raw" ] && [ "$(sha_file "$raw")" = "$input_sha" ] &&
  [ -f "$program_copy" ] && [ ! -L "$program_copy" ] &&
  [ "$(sha_file "$program_copy")" = "$program_sha" ] &&
  [ -f "$jq_bin" ] && [ -x "$jq_bin" ] && [ ! -L "$jq_bin" ] &&
  [ "$(sha_file "$jq_bin")" = "$jq_sha" ] || emit_error E_RUNTIME
/usr/bin/printf '%s\n' "$result"
