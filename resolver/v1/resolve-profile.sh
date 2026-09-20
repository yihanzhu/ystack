#!/bin/bash -p
# shellcheck disable=SC2016
#
# Public entry for resolver-trusted-parent (work/resolver-trusted-parent, R1).
# Public arguments: <jq> <output> <request> <map>. Compiles the pinned parent
# (resolver/v1/trusted-launch.c) and helper (resolver/v1/nofollow-snapshot.c)
# from their committed sources into a fresh private run directory under
# <output>/.run, launches the parent as a child (never exec'd -- the entry has
# to outlive it to remove the run directory) and waits for it, forwarding at
# most the first caller signal it receives and passing the child's stdout and
# stderr through unchanged.
#
# First statement: refuse a non-privileged arrival (R1).
case $- in
  *p*) ;;
  *) exit 78 ;;
esac

umask 077

# Fork-free headroom ladder (R1): the /dev/fd/* close loop below is a shell
# glob, not a fork, so this only ever has to clear room for the caller's own
# already-open descriptors.
# `ulimit -S -n hard` first, unredirected (a failed raise here still means
# refusing): bash 5.2 keeps an undo list even for `exec` redirections, so the
# `exec >&2` right after also needs a spare fd, EMFILE-denied once the ladder
# lowered the soft limit -- raising back to hard frees room for it and the
# printf. bash 3.2 (Darwin) still prints regardless; bash 5.2 (Linux)
# otherwise prints its own "redirection error" instead of E_RUNTIME (CI case 75).
ulimit -S -n 1024 2>/dev/null || ulimit -S -n 256 2>/dev/null || ulimit -S -n 64 2>/dev/null || {
  ulimit -S -n hard
  exec >&2
  builtin printf '%s\n' E_RUNTIME
  exit 1
}

# Close every inherited descriptor above 2, /dev/fd/* enumerated with
# nullglob off -- an unmatched literal glob is itself a refusal (R1). No
# descriptor is skipped for being bash's own script fd; bash relocates it.
for fd_entry in /dev/fd/*; do
  fd_name=${fd_entry##*/}
  case "$fd_name" in
    ''|*[!0-9]*)
      if [ "$fd_entry" = '/dev/fd/*' ]; then
        # Same ulimit-then-exec reasoning as the ladder above: opendir("/dev/fd")
        # itself hit EMFILE, so `exec >&2`'s undo-list fd (bash 5.2) is starved too.
        ulimit -S -n hard
        exec >&2
        builtin printf '%s\n' E_RUNTIME
        exit 1
      fi
      continue
      ;;
  esac
  case "$fd_name" in
    0|1|2) continue ;;
  esac
  eval "exec ${fd_name}>&-" 2>/dev/null || :
done

# Capture an absolute self path with shell builtins only, before the scrub
# below can take PWD away, and keep it unexported across that scrub.
case ${BASH_SOURCE[0]} in
  /*) script_path=${BASH_SOURCE[0]} ;;
  *) script_path=$PWD/${BASH_SOURCE[0]} ;;
esac
builtin export -n script_path

# copy-begin adapters/local-git-materializer/v1/materialize.sh:4-13 at a637451d4b3fbef6b516a9c08f68c0dde46a7059
clean_path=/usr/bin:/bin
while IFS= builtin read -r inherited_function; do
  builtin unset -f "$inherited_function" 2>/dev/null || :
done < <(builtin compgen -A function)
# BASH_XTRACEFD (r10 P1): Bash >=4.1 closes the fd assigned away from,
# and closes the new one on unset -- save/restore a standard caller fd
# around the park (a non-standard value, e.g. 5, may lose that fd here;
# harmless, every fd above 2 is closed already).
if [ -n "${BASH_XTRACEFD+x}" ]; then
  saved=$BASH_XTRACEFD
  case $saved in
    0) exec 8<&0 ;; 1|2) exec 8>&"$saved" ;; *) saved='' ;;
  esac
  exec 9>&2; BASH_XTRACEFD=9
  case $saved in
    0) exec 0<&8 8<&- ;; 1) exec 1>&8 8>&- ;; 2) exec 2>&8 8>&- ;;
  esac
  unset BASH_XTRACEFD
fi
while IFS= builtin read -r exported_name; do
  case "$exported_name" in PATH) ;; *) builtin unset "$exported_name" 2>/dev/null || : ;; esac
done < <(builtin compgen -e)
PATH=$clean_path
LC_ALL=C
export PATH LC_ALL
# copy-end adapters/local-git-materializer/v1/materialize.sh:4-13

# copy-begin adapters/local-git-materializer/v1/materialize.sh:22-29 at a637451d4b3fbef6b516a9c08f68c0dde46a7059
# (adapted: four public arguments rather than eight, the
# __resolve_profile_clean marker in place of "materialize", -p kept on the
# re-exec, script_path made absolute above rather than refused when relative,
# and every refusal line here via builtin printf rather than /usr/bin/printf)
if [ "$#" -eq 4 ]; then
  exec /usr/bin/env -i PATH="${PATH:-/usr/bin:/bin}" LC_ALL=C \
    /bin/bash -p "$script_path" __resolve_profile_clean "$1" "$2" "$3" "$4"
fi
[ "$#" -eq 5 ] && [ "$1" = __resolve_profile_clean ] || {
  builtin printf '%s\n' E_USAGE >&2
  exit 64
}
# copy-end adapters/local-git-materializer/v1/materialize.sh:22-29

# Marker arrival: defence in depth beside the scrub above, against an aliased
# or hijacked builtin surviving into this second process.
builtin unalias -a
builtin shopt -u expand_aliases

shift

# The entry runs under set -uo pipefail; -e is deliberately not set, so a
# refused or signalled external command's non-zero status reaches the next
# statement instead of killing the shell outright (R1).
set -uo pipefail

refuse() {
  builtin printf '%s\n' "$1" >&2
  exit 1
}

checkpoint() {
  [ -z "$entry_signal" ] || exit
}

# The six names every trap and checkpoint reads, declared empty before any
# trap is armed and before the first external command, so set -u never turns
# a signal-free run's first checkpoint into a fatal unbound read (R1).
# wait_interrupted is deliberately not among them: the traps only write it,
# and its one read is always preceded by the loop's own clear, same iteration.
entry_signal='' run_created='' entry_status='' parent_pid='' last_forwarded='' trap_busy=''

jq_arg=$1
output=$2
request=$3
map=$4

# Repository root from this entry's own location, the way the runtime
# resolves its own (resolver/v1/profile-resolve-runtime.sh:4-16) -- builtins
# only, no external command.
entry_dir=${script_path%/*}
entry_repo=${entry_dir%/resolver/v1}
if [ "$entry_repo" = "$entry_dir" ] ||
   [ ! -f "$entry_repo/scripts/lib/profile-resolution.sh" ] ||
   [ -L "$entry_repo/scripts/lib/profile-resolution.sh" ]; then
  refuse 'E_RUNTIME binding'
fi
runtime_path="$entry_dir/profile-resolve-runtime.sh"

# Platform: two uname reads, each in the three-step run, checkpoint, refuse
# shape, never a substitution inside the case word itself (R1) -- a signal
# landing on a foreground uname must not be mistaken for an unsupported
# platform.
os=$(/usr/bin/uname -s); status=$?
checkpoint
[ "$status" -eq 0 ] || refuse E_RUNTIME
machine=$(/usr/bin/uname -m); status=$?
checkpoint
[ "$status" -eq 0 ] || refuse E_RUNTIME

core_generation=g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43
core_schema_major=2

case "$os:$machine" in
  Linux:x86_64)
    path_max=4096
    name_max=255
    jq_sha256=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44
    sha1_args=(/usr/bin/sha1sum)
    sha256_args=(/usr/bin/sha256sum)
    compiler=/usr/bin/cc
    compiler_extra=''
    stat_size_fmt=(-c '%s')
    stat_owner_mode=(-c '%u %a')
    ;;
  Darwin:x86_64|Darwin:arm64)
    path_max=1024
    name_max=255
    jq_sha256=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    sha1_args=(/usr/bin/shasum -a 1)
    sha256_args=(/usr/bin/shasum -a 256)
    compiler=/Library/Developer/CommandLineTools/usr/bin/clang
    compiler_extra='-isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk'
    stat_size_fmt=(-f '%z')
    stat_owner_mode=(-f '%u %Lp')
    ;;
  *) refuse E_RUNTIME ;;
esac

# Validate the output root before anything is written into it (R1): absolute,
# short enough to leave room for .run/tmp/ plus a NAME_MAX name, a real
# directory with no symlink component, owned by this uid, mode exactly 0700,
# and empty.
case "$output" in
  /*) ;;
  *) refuse E_RUNTIME ;;
esac
# R-colon: a ':' anywhere in the output path (and so, since jq is bound at
# "$output/.run/jq", in the parent's tool_path too) would let the parent's
# literal PATH="<tool_path>:/usr/bin:/bin" splice split into two PATH
# entries, exposing an earlier attacker-controlled component to its
# `command -v jq`/`command -v awk` lookups. This entry always launches the
# parent with a fixed clean PATH (clean_env below), so it is not itself
# exploitable, but the check is refused here too, by string content alone,
# so a caller cannot even construct such an output/run pair for the parent.
case "$output" in
  *:*) refuse E_RUNTIME ;;
esac
# Reserve the literal "/.run/tmp/" (10 bytes) plus a full NAME_MAX filename --
# the compiler chooses its own intermediate names, so no single name is
# enough (R1) -- rather than the fixed, too-small margin an earlier round
# used. This is deliberately stricter than the parent's own copied guard
# (`strlen(sandbox) > PATH_MAX - 16`), which only reserves room for
# "<output>/child.stdout".
run_tmp_reserve=$((10 + name_max))
[ "${#output}" -le $((path_max - run_tmp_reserve)) ] || refuse E_RUNTIME
[ -d "$output" ] && [ ! -L "$output" ] || refuse E_RUNTIME
output_physical=$(CDPATH='' builtin cd -P -- "$output" && builtin pwd -P); status=$?
checkpoint
[ "$status" -eq 0 ] || refuse E_RUNTIME
[ "$output" = "$output_physical" ] || refuse E_RUNTIME
output_owner_mode=$(/usr/bin/stat "${stat_owner_mode[@]}" "$output"); status=$?
checkpoint
[ "$status" -eq 0 ] || refuse E_RUNTIME
output_owner=${output_owner_mode%% *}
output_mode=${output_owner_mode#* }
[ "$output_owner" = "$EUID" ] || refuse E_RUNTIME
[ "$output_mode" = 700 ] || refuse E_RUNTIME
shopt -s dotglob nullglob
output_entries=("${output}/"*)
shopt -u dotglob nullglob
[ "${#output_entries[@]}" -eq 0 ] || refuse E_RUNTIME

run="$output/.run"

# Traps installed only now: after the seven names above and after run is
# assigned, so nothing a trap or a checkpoint reads is unset when armed (R1).
# Pre-parent arming uses the record-only form only: no parent exists yet for
# a forwarding body to target, so this is the two-statement literal, and
# nothing besides.
trap ': "${entry_signal:=TERM}"; wait_interrupted=1' TERM
trap ': "${entry_signal:=INT}"; wait_interrupted=1' INT
trap ': "${entry_signal:=HUP}"; wait_interrupted=1' HUP

# EXIT trap: capture status first, ignore INT, TERM and HUP second (trap is a
# builtin so this cannot lose the captured status), restore and remove an
# owned run directory, write the entry's own diagnostic last and only onto a
# regular stderr, then select the prescribed exit status.
# shellcheck disable=SC2154  # ecap is assigned by this same trap string when it fires
trap '
  ecap=$?
  trap "" INT TERM HUP
  if [ -n "$run_created" ]; then
    /bin/chmod 0700 "${run:?}" || :
    /bin/rm -rf -- "${run:?}" || :
  fi
  if [ -n "$entry_signal" ] && [ -f /dev/fd/2 ]; then
    if [ -n "$parent_pid" ]; then
      builtin printf "entry-signal: %s forwarded %s\n" "$entry_signal" "$parent_pid" >&2
    else
      builtin printf "entry-signal: %s no-parent\n" "$entry_signal" >&2
    fi
  fi
  if [ -n "$entry_status" ]; then
    exit "$entry_status"
  elif [ -n "$entry_signal" ]; then
    exit "$((128 + $(kill -l "$entry_signal")))"
  else
    exit "$ecap"
  fi
' EXIT

[ -e "$run" ] && refuse E_RUNTIME

# Plain mkdir, no -p and no -m: 0700 comes from the umask above. The guard is
# set on a clean success and also on a status above 128 with the directory
# present -- the caller's group signal killed mkdir after it had created the
# directory -- and left unset on any other non-zero status.
/bin/mkdir -- "$run"; status=$?
if [ "$status" -eq 0 ]; then
  run_created=1
elif [ "$status" -gt 128 ] && [ -e "$run" ]; then
  run_created=1
fi
checkpoint
[ -n "$run_created" ] || refuse E_RUNTIME

/bin/mkdir -- "$run/tmp"; status=$?
checkpoint
[ "$status" -eq 0 ] || refuse E_RUNTIME
/bin/mkdir -- "$run/home"; status=$?
checkpoint
[ "$status" -eq 0 ] || refuse E_RUNTIME

clean_env=(/usr/bin/env -i "PATH=/usr/bin:/bin" "LC_ALL=C" "TMPDIR=$run/tmp" "HOME=$run/home")

# The ten entry-pinned blob ids: this entry's own two C sources, plus the
# eight loaded files R5 lists (the runtime file this entry binds, the
# library it sources, the resolver jq program, and the five jq modules under
# the pinned generation). Each id is the file's git blob id computed without
# git -- SHA-1 over "blob <size>\0" then the bytes -- against the constant
# pinned at origin/main for the eight loaded files, and at this branch's own
# working tree for the two C sources (trusted-launch.c pins its own source).
trusted_launch_path="$entry_repo/resolver/v1/trusted-launch.c"
helper_path="$entry_repo/resolver/v1/nofollow-snapshot.c"
modules_dir="$entry_repo/core/v$core_schema_major/generations/$core_generation/modules"

pin_paths=(
  "$runtime_path"
  "$entry_repo/scripts/lib/profile-resolution.sh"
  "$entry_repo/resolver/v1/profile-resolution.jq"
  "$modules_dir/schema.jq"
  "$modules_dir/profile_graph.jq"
  "$modules_dir/stage_request.jq"
  "$modules_dir/result_facts.jq"
  "$modules_dir/result_truth.jq"
  "$helper_path"
  "$trusted_launch_path"
)
pin_hexes=(
  54e174128a9f2f1a13ea17794d54696698b72eec
  4cb098be3de6bc00406315a8944d54b17231e98c
  9004cb7bd38fc165d8b1414786a520af23cfb9b3
  e2bc03a2b6d1ed1119ffd794981b06c6f59f46f8
  e3633b25b890ce68024fba682f0f50606429f020
  aff5cf1b87efac8cb95918ec5dc240a055277f52
  cfc3ed3b1c3d714412a6dffc85accaabb98cf3df
  6af6f42d9afb073fbc892646fe9cd899f7057700
  cb99a95688f5b141e2a4db787bbc800780f5e59a
  f81a186cab0813bbef54150726e9ff1ca3d6270e
)

pin_index=0
while [ "$pin_index" -lt "${#pin_paths[@]}" ]; do
  pin_path=${pin_paths[$pin_index]}
  pin_name=${pin_path##*/}
  # Regular/non-symlink check via bash test builtins (no open()) before any
  # read: a FIFO in place of a pinned file would pass stat but block the
  # cat/hash below forever, and a symlink to /dev/zero hashes unbounded.
  [ -f "$pin_path" ] && [ ! -L "$pin_path" ] || refuse "E_RUNTIME pin $pin_name"
  pin_size=$("${clean_env[@]}" /usr/bin/stat "${stat_size_fmt[@]}" "$pin_path"); status=$?
  checkpoint
  [ "$status" -eq 0 ] || refuse "E_RUNTIME pin $pin_name"
  pin_digest_line=$(builtin printf 'blob %d\0' "$pin_size" | /bin/cat - "$pin_path" | "${clean_env[@]}" "${sha1_args[@]}"); status=$?
  checkpoint
  [ "$status" -eq 0 ] || refuse "E_RUNTIME pin $pin_name"
  pin_digest=${pin_digest_line%% *}
  [ "$pin_digest" = "${pin_hexes[$pin_index]}" ] || refuse "E_RUNTIME pin $pin_name"
  pin_index=$((pin_index + 1))
done

# <jq>, validated pre-hash/exec (spec.md:4650-4654) as absolute/regular/non-symlink/executable: SHA-256 for this platform, then the jq-1.6 identity probe, both under the same fixed env as the pin checks above.
case "$jq_arg" in /*) ;; *) builtin printf '%s\n' E_USAGE >&2; exit 64 ;; esac
[ -f "$jq_arg" ] && [ ! -L "$jq_arg" ] && [ -x "$jq_arg" ] || refuse 'E_RUNTIME binding'
jq_digest_line=$("${clean_env[@]}" "${sha256_args[@]}" < "$jq_arg"); status=$?
checkpoint
[ "$status" -eq 0 ] || refuse 'E_RUNTIME binding'
jq_digest=${jq_digest_line%% *}
[ "$jq_digest" = "$jq_sha256" ] || refuse 'E_RUNTIME binding'
jq_version=$("${clean_env[@]}" "$jq_arg" --version); status=$?
checkpoint
[ "$status" -eq 0 ] || refuse 'E_RUNTIME binding'
[ "$jq_version" = jq-1.6 ] || refuse 'E_RUNTIME binding'

[ -x "$compiler" ] || refuse 'E_RUNTIME binding'

# shellcheck disable=SC2086  # compiler_extra is an intentionally word-split flag string
"${clean_env[@]}" "$compiler" $compiler_extra -std=c11 -O2 -Wall -Wextra -Werror -pedantic -pipe \
  -o "$run/trusted-launch" "$trusted_launch_path"; status=$?
checkpoint
[ "$status" -eq 0 ] || refuse 'E_RUNTIME compile'
# shellcheck disable=SC2086
"${clean_env[@]}" "$compiler" $compiler_extra -std=c11 -O2 -Wall -Wextra -Werror -pedantic -pipe \
  -o "$run/nofollow-snapshot" "$helper_path"; status=$?
checkpoint
[ "$status" -eq 0 ] || refuse 'E_RUNTIME compile'

"${clean_env[@]}" /bin/cp -- "$jq_arg" "$run/jq"; status=$?
checkpoint
[ "$status" -eq 0 ] || refuse 'E_RUNTIME binding'

case "$os" in
  Linux)
    "${clean_env[@]}" /bin/cp -- /usr/bin/awk "$run/awk"; status=$?
    checkpoint
    [ "$status" -eq 0 ] || refuse 'E_RUNTIME binding'
    ;;
  Darwin)
    { builtin printf '%s\n' '#!/bin/bash' 'exec /usr/bin/awk "$@"'; } > "$run/awk"
    status=$?
    checkpoint
    [ "$status" -eq 0 ] || refuse 'E_RUNTIME binding'
    ;;
esac

# Tighten: the compiler scratch and HOME are gone before the mode pass, then
# every remaining file goes to 0500, then the run directory itself.
/bin/rm -rf -- "${run:?}/tmp" "${run:?}/home"; status=$?
checkpoint
[ "$status" -eq 0 ] || refuse 'E_RUNTIME binding'
for run_file in "${run}/"*; do
  [ -e "$run_file" ] || continue
  /bin/chmod 0500 "$run_file"; status=$?
  checkpoint
  [ "$status" -eq 0 ] || refuse 'E_RUNTIME binding'
done
/bin/chmod 0500 "$run"; status=$?
checkpoint
[ "$status" -eq 0 ] || refuse 'E_RUNTIME binding'

checkpoint

# Launch the parent as a child -- never exec'd, so this shell and its traps
# survive to remove the run directory -- under a fixed env of PATH and
# LC_ALL only, nothing named for the caller. Stdout and stderr are not
# touched, so the parent's own are the entry's own.
parent_env=(/usr/bin/env -i "PATH=/usr/bin:/bin" "LC_ALL=C")
"${parent_env[@]}" "$run/trusted-launch" resolve "$runtime_path" "$run/nofollow-snapshot" \
  "$run/jq" "$request" "$map" "$output" "$run" &
parent_pid=$!

# The forwarding form arms the instant a parent exists to target.
trap ': "${entry_signal:=TERM}"; wait_interrupted=1; if [ -z "$trap_busy" ]; then trap_busy=1; case " $(jobs -l) " in *" $parent_pid Running"*) [ -n "$last_forwarded" ] || { kill -"$entry_signal" "$parent_pid" 2>/dev/null || :; last_forwarded=$entry_signal; };; esac; trap_busy=''; fi' TERM
trap ': "${entry_signal:=INT}"; wait_interrupted=1; if [ -z "$trap_busy" ]; then trap_busy=1; case " $(jobs -l) " in *" $parent_pid Running"*) [ -n "$last_forwarded" ] || { kill -"$entry_signal" "$parent_pid" 2>/dev/null || :; last_forwarded=$entry_signal; };; esac; trap_busy=''; fi' INT
trap ': "${entry_signal:=HUP}"; wait_interrupted=1; if [ -z "$trap_busy" ]; then trap_busy=1; case " $(jobs -l) " in *" $parent_pid Running"*) [ -n "$last_forwarded" ] || { kill -"$entry_signal" "$parent_pid" 2>/dev/null || :; last_forwarded=$entry_signal; };; esac; trap_busy=''; fi' HUP

# The wait loop: step 2 is the record-only section (disarms forwarding for
# its own guarded check-send-record so the trap and the loop can never both
# send), then wait, then the clear-flag break, then the set-flag table read
# with its continue and second wait -- see plan.md for why each position.
while :; do
  wait_interrupted=''
  while [ -n "$entry_signal" ] && [ -z "$last_forwarded" ]; do
    trap ': "${entry_signal:=TERM}"; wait_interrupted=1' TERM
    trap ': "${entry_signal:=INT}"; wait_interrupted=1' INT
    trap ': "${entry_signal:=HUP}"; wait_interrupted=1' HUP
    if [ -n "$entry_signal" ] && [ -z "$last_forwarded" ]; then
      case " $(jobs -l) " in
        *" $parent_pid Running"*)
          kill -"$entry_signal" "$parent_pid" 2>/dev/null || :
          ;;
      esac
      last_forwarded=$entry_signal
    fi
    trap ': "${entry_signal:=TERM}"; wait_interrupted=1; if [ -z "$trap_busy" ]; then trap_busy=1; case " $(jobs -l) " in *" $parent_pid Running"*) [ -n "$last_forwarded" ] || { kill -"$entry_signal" "$parent_pid" 2>/dev/null || :; last_forwarded=$entry_signal; };; esac; trap_busy=''; fi' TERM
    trap ': "${entry_signal:=INT}"; wait_interrupted=1; if [ -z "$trap_busy" ]; then trap_busy=1; case " $(jobs -l) " in *" $parent_pid Running"*) [ -n "$last_forwarded" ] || { kill -"$entry_signal" "$parent_pid" 2>/dev/null || :; last_forwarded=$entry_signal; };; esac; trap_busy=''; fi' INT
    trap ': "${entry_signal:=HUP}"; wait_interrupted=1; if [ -z "$trap_busy" ]; then trap_busy=1; case " $(jobs -l) " in *" $parent_pid Running"*) [ -n "$last_forwarded" ] || { kill -"$entry_signal" "$parent_pid" 2>/dev/null || :; last_forwarded=$entry_signal; };; esac; trap_busy=''; fi' HUP
  done
  wait "$parent_pid"; status=$?
  if [ -z "$wait_interrupted" ]; then
    entry_status=$status
    break
  fi
  case " $(jobs -l) " in *" $parent_pid Running"*) continue ;; esac
  wait "$parent_pid"; second=$?
  [ "$second" -ne 127 ] || second=$status
  [ "$second" -ne 127 ] || second=$((128 + $(kill -l "$entry_signal")))
  entry_status=$second
  break
done
