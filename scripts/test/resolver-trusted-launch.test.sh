#!/usr/bin/env bash
# shellcheck disable=SC2016
#
# R10 focused test for resolver-trusted-launch (work/resolver-trusted-parent).
# Exercises the shipped entry (resolver/v1/resolve-profile.sh) and the shipped
# parent (resolver/v1/trusted-launch.c), which do not exist yet at plan step 1 —
# this run is expected to fail against absent behavior (plan.md:96-97).
#
# Case inventory (R10 groups, spec.md lines noted per group): Group 1 entry-owned
# refusals (7099-7170); Group 2 parent-owned refusals, direct invocation
# (7247-7420); Group 3 runtime refusal, labelled (7442-7447); R3 no-copy
# invariant (7449-7524); loader-variable case (7495-7524); entry mode / relative
# invocation (7566-7600); compiler-environment pollution (7608-7710); cleanup
# cases (7716-7764); two-umask case (7813-7845); descriptor cases (7846-7975);
# signal cases (7976-8385); pinned-blob / generation assertions (8388-8410);
# mechanism checks / proof-by-reading (8460-8995).
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
entry="$root/resolver/v1/resolve-profile.sh"
parent_source="$root/resolver/v1/trusted-launch.c"
helper_source="$root/resolver/v1/nofollow-snapshot.c"
runtime="$root/resolver/v1/profile-resolve-runtime.sh"
library="$root/scripts/lib/profile-resolution.sh"
jq_program="$root/resolver/v1/profile-resolution.jq"
launcher_source="$root/scripts/test/portable-profile-resolution-launcher.c"
fixture_builder="$root/scripts/test/portable-profile-resolution-fixtures.sh"

# Derived, not embedded (R10, spec.md ~8747-8748): derive the pinned generation
# id from the parent's own PARENT_CORE_GENERATION constant, the same fixed
# value the eight-pin assertions below are keyed off, rather than carry a
# hand-copied "g-..." literal.
core_generation_value=$(/usr/bin/grep -A1 'static const char \*const PARENT_CORE_GENERATION =' \
  "$parent_source" 2>/dev/null | /usr/bin/grep -oE 'g-[0-9a-f]{64}')
if [ -z "$core_generation_value" ]; then
  # fail_case is not defined yet here (bootstrap failure, not a test case).
  printf 'setup: could not derive the pinned core generation id from trusted-launch.c\n' >&2
  exit 1
fi
generation_dir="$root/core/v2/generations/$core_generation_value"
mod_schema="$generation_dir/modules/schema.jq"
mod_result_truth="$generation_dir/modules/result_truth.jq"
mod_stage_request="$generation_dir/modules/stage_request.jq"
mod_profile_graph="$generation_dir/modules/profile_graph.jq"
mod_result_facts="$generation_dir/modules/result_facts.jq"

# The eight loaded/pinned files R5 enumerates (entry pins these plus its own
# two C sources -- ten total). An array, not a scalar, so a checkout path
# containing a space cannot split one filename into two words at the
# unquoted expansions below (round-4 review).
loaded_files=("$runtime" "$library" "$jq_program" "$mod_schema" "$mod_result_truth" "$mod_stage_request" "$mod_profile_graph" "$mod_result_facts")

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  # Darwin's default TMPDIR sits inside what the write-attribution cases below observe; /private/tmp (never the /tmp symlink) sits outside it.
  Darwin:*) tmp=$(/usr/bin/mktemp -d "/private/tmp/ystack-resolver-trusted-launch-test.XXXXXX") ;;
  *) tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-resolver-trusted-launch-test.XXXXXX") ;;
esac
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
suite_complete=0
cleanup() {
  cleanup_status=$?
  if [ "$suite_complete" -eq 1 ]; then
    /bin/chmod -R u+w "$tmp" 2>/dev/null || :
    /bin/rm -rf -- "$tmp"
  else
    printf 'preserved failing fixture: %s\n' "$tmp" >&2
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

total=0
passed=0
pass_case() { total=$((total + 1)); passed=$((passed + 1)); printf 'ok %d - %s\n' "$total" "$1"; }
fail_case() { total=$((total + 1)); printf 'not ok %d - %s\n' "$total" "$1" >&2; exit 1; }
skip_case() { total=$((total + 1)); passed=$((passed + 1)); printf 'ok %d - %s # SKIP %s\n' "$total" "$1" "$2"; }

sha256_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

# --- 0. Pinned jq, provisioned the way shadow-slice.test.sh:24-51 does -----------------

case "$platform" in
  Darwin:*) jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_asset=jq-linux64
    jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) fail_case "unsupported host $platform" ;;
esac
jq_cache_dir="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$jq_cache_dir"
jq_cache="$jq_cache_dir/$jq_asset"
if [ ! -f "$jq_cache" ] || [ -L "$jq_cache" ] || [ "$(sha256_file "$jq_cache")" != "$jq_sha" ]; then
  jq_download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$jq_download"
  [ "$(sha256_file "$jq_download")" = "$jq_sha" ] || fail_case 'jq release digest'
  /bin/chmod 0555 "$jq_download"
  /bin/mv "$jq_download" "$jq_cache"
fi
bin="$tmp/bin"
/bin/mkdir -m 700 "$bin"
/bin/cp "$jq_cache" "$bin/jq"
/bin/chmod 0555 "$bin/jq"
bound_jq="$bin/jq"
[ "$("$bound_jq" --version)" = jq-1.6 ] || fail_case 'jq identity'

case "$platform" in
  Linux:x86_64) /bin/cp /usr/bin/awk "$bin/awk" ;;
  Darwin:*) /usr/bin/printf '%s\n' '#!/bin/bash' 'exec /usr/bin/awk "$@"' > "$bin/awk" ;;
esac
/bin/chmod 0555 "$bin/awk"

# --- Per-platform tool table (mirrors R1's compile line and R7's digest tools) ----------

case "$platform" in
  Linux:x86_64)
    compiler=/usr/bin/cc
    compiler_extra_flags=()
    ;;
  Darwin:*)
    compiler=/Library/Developer/CommandLineTools/usr/bin/clang
    compiler_extra_flags=(-isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)
    ;;
esac

compile_source() {
  # compile_source SOURCE OUTPUT [EXTRA_ENV...]
  cs_source=$1
  cs_output=$2
  shift 2
  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C "$@" \
    "$compiler" "${compiler_extra_flags[@]}" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -o "$cs_output" "$cs_source"
}

# wait_for_run OUT_DIR -- poll up to 5s for OUT_DIR/.run to appear.
wait_for_run() {
  wfr_deadline=$(( $(/bin/date +%s) + 5 ))
  while [ ! -e "$1/.run" ]; do
    [ "$(/bin/date +%s)" -lt "$wfr_deadline" ] || break
    /bin/sleep 0.01
  done
}

# poll_run_before_eof FLAG OUT_DIR SECS -- echoes 1 if OUT_DIR/.run preceded FLAG.
poll_run_before_eof() {
  prbe_deadline=$(( $(/bin/date +%s) + $3 )); prbe_saw=0
  while [ ! -e "$1" ]; do
    [ -e "$2/.run" ] && prbe_saw=1
    [ "$(/bin/date +%s)" -lt "$prbe_deadline" ] || break
    /bin/sleep 0.01
  done
  printf '%s\n' "$prbe_saw"
}

# --- 1. Real profile acquisition (plan.md:76-90; R10's positive-request requirement) ---
#
# Prefer already-present exact objects in a disposable repository built from this
# checkout's own objects. Fall back to an anonymous public-HTTPS fetch, with a clean
# environment and disposable HOME, only if the checkout lacks them. A failed
# acquisition fails the test outright -- it is never a skip.

real_repo="$tmp/real-repo.git"
real_head=$(/usr/bin/git -C "$root" rev-parse HEAD)

# Collect every commit_id embedded in the real committed profile/manifest objects, plus
# the head commit itself (which names profile.json and the manifest files directly).
profile_json="$root/profiles/default/v1/profile.json"
required_commits=$("$bound_jq" -r '
  [.. | objects | select(has("commit_id")) | .commit_id] | unique[]
' "$profile_json")
all_present=1
for c in $real_head $required_commits; do
  /usr/bin/git -C "$root" cat-file -e "$c^{commit}" 2>/dev/null || all_present=0
done

if [ "$all_present" -eq 1 ]; then
  /usr/bin/git clone --quiet --bare --no-hardlinks -- "$root" "$real_repo"
else
  disposable_home="$tmp/real-repo-home"
  /bin/mkdir -m 700 "$disposable_home"
  # Seed from this checkout's own objects first (real_head is always present
  # in $root); only genuinely missing objects fall back to a public fetch,
  # which cannot see an unpublished local commit.
  /usr/bin/git clone --quiet --bare --no-hardlinks -- "$root" "$real_repo"
  for c in $real_head $required_commits; do
    /usr/bin/git -C "$real_repo" cat-file -e "$c^{commit}" 2>/dev/null && continue
    env -i PATH=/usr/bin:/bin HOME="$disposable_home" \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
      GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false GIT_SSH_COMMAND=/bin/false \
      /usr/bin/git -C "$real_repo" -c protocol.version=2 -c credential.helper= \
        -c core.hooksPath=/dev/null fetch --no-tags --no-write-fetch-head \
        'https://github.com/yihanzhu/ystack.git' "$c" || {
          fail_case "real-object acquisition: cannot obtain commit $c"
        }
    /usr/bin/git -C "$real_repo" cat-file -e "$c^{commit}" 2>/dev/null ||
      fail_case "real-object acquisition: fetched but missing commit $c"
  done
fi
for c in $real_head $required_commits; do
  /usr/bin/git -C "$real_repo" cat-file -e "$c^{commit}" 2>/dev/null ||
    fail_case "real-object acquisition: closure incomplete for $c"
done
pass_case 'real profile/manifest object closure acquired into a disposable repository'

real_locator() {
  # real_locator PATH -> jq locator object {repository_id,hash_algorithm,commit_id,path,object_id}
  real_line=$(/usr/bin/git -C "$root" ls-tree "$real_head" -- "$1")
  real_meta=${real_line%%$'\t'*}
  IFS=' ' read -r _ _ real_oid <<< "$real_meta"
  "$bound_jq" -S -c -n --arg id repo.ystack --arg commit "$real_head" --arg path "$1" \
    --arg oid "$real_oid" \
    '{repository_id:$id,hash_algorithm:"sha1",commit_id:$commit,path:$path,object_id:$oid}'
}

real_profile_locator=$(real_locator profiles/default/v1/profile.json)
real_manifest_locators='[]'
for m in claude-code-producer codex-native-reviewer deterministic-verifier \
         dormant-publisher github-actions-ci local-git-materializer; do
  loc=$(real_locator "profiles/default/v1/manifests/$m.json")
  real_manifest_locators=$("$bound_jq" -S -c --argjson l "$loc" '. + [$l]' <<< "$real_manifest_locators")
done
real_scope() {
  real_hash=$(/usr/bin/printf '%064d' 0 | /usr/bin/tr 0 "$2")
  "$bound_jq" -S -c -n --arg purpose "$1" --arg hash "$real_hash" \
    '{purpose:$purpose,decision_record_ref:{content_id:("decision-"+$purpose),media_type:"application/json",sha256:$hash},
      subject_ref:{type:"artifact",value:{type:"content",value:{content_id:$purpose,media_type:"application/json",sha256:$hash}}},
      scope_sha256:$hash}'
}
real_selection=$(real_scope selection 8)
real_context=$(real_scope repository-context 9)
real_request="$tmp/real-request.json"
"$bound_jq" -S -c -n --argjson profile "$real_profile_locator" --argjson manifests "$real_manifest_locators" \
  --argjson selection "$real_selection" --argjson context "$real_context" \
  '{version:1,profile_source:$profile,manifest_sources:$manifests,
    selection_ref:$selection,repository_context_ref:$context}' > "$real_request"
real_map="$tmp/real-map.json"
"$bound_jq" -S -c -n --arg root "$real_repo" \
  '{version:1,repositories:[{repository_id:"repo.ystack",root:$root}]}' > "$real_map"
pass_case 'positive resolution request names the real committed profiles/default/v1 objects'

# --- 1b. Real-profile equivalence (round-8 finding 1; plan.md:447-448) -------------------
# Uninterrupted, to-completion run of the shipped entry AND a freshly compiled
# copy of the pre-existing test launcher on the same real default-profile
# inputs: both must exit 0 with byte-identical stdout.
if [ -x "$entry" ]; then
  eq_out="$tmp/equivalence.entry.out"; /bin/mkdir -m 700 "$eq_out"
  eq_entry_stdout="$tmp/equivalence.entry.stdout"; eq_entry_status=0
  "$entry" "$bound_jq" "$eq_out" "$real_request" "$real_map" \
    > "$eq_entry_stdout" 2> "$tmp/equivalence.entry.stderr" || eq_entry_status=$?

  eq_launcher_bin="$tmp/equivalence-launcher"; eq_launcher_helper="$tmp/equivalence-nofollow-snapshot"
  compile_source "$launcher_source" "$eq_launcher_bin"
  compile_source "$helper_source" "$eq_launcher_helper"
  eq_sandbox="$tmp/equivalence.launcher.sandbox"; /bin/mkdir -m 700 "$eq_sandbox"
  eq_launcher_stdout="$tmp/equivalence.launcher.stdout"; eq_launcher_status=0
  YSTACK_TEST_SANDBOX="$eq_sandbox" \
    "$eq_launcher_bin" resolve "$runtime" "$eq_launcher_helper" "$bound_jq" \
    "$real_request" "$real_map" \
    > "$eq_launcher_stdout" 2> "$tmp/equivalence.launcher.stderr" || eq_launcher_status=$?

  if [ "$eq_entry_status" -eq 0 ] && [ "$eq_launcher_status" -eq 0 ] &&
     /usr/bin/cmp -s "$eq_entry_stdout" "$eq_launcher_stdout"; then
    pass_case 'mechanism: shipped entry and the existing test launcher both resolve the real default profile to completion with byte-identical stdout'
  else
    fail_case "real-profile equivalence: entry_status=$eq_entry_status launcher_status=$eq_launcher_status $(/usr/bin/cmp "$eq_entry_stdout" "$eq_launcher_stdout" 2>&1 || :)"
  fi
else
  fail_case 'real-profile equivalence (entry absent)'
fi

# --- 1c. BASH_XTRACEFD pollution (round-9 finding 1): must not survive the scrub as a closed stdout/stderr.
if [ -x "$entry" ]; then
  for xfd in 1 2; do
    xtrace_out="$tmp/xtracefd$xfd.out"; /bin/mkdir -m 700 "$xtrace_out"; xtrace_stdout="$tmp/xtracefd$xfd.stdout"; xtrace_status=0
    BASH_XTRACEFD=$xfd "$entry" "$bound_jq" "$xtrace_out" "$real_request" "$real_map" \
      > "$xtrace_stdout" 2> "$tmp/xtracefd$xfd.stderr" || xtrace_status=$?
    if [ "$xtrace_status" -eq 0 ] && /usr/bin/cmp -s "$xtrace_stdout" "$eq_entry_stdout"; then
      pass_case "environment: inherited BASH_XTRACEFD=$xfd does not disturb resolution stdout"
    else
      fail_case "BASH_XTRACEFD=$xfd pollution: status=$xtrace_status $(/usr/bin/cmp "$xtrace_stdout" "$eq_entry_stdout" 2>&1 || :)"
    fi
  done
else
  fail_case 'environment: BASH_XTRACEFD pollution cases (entry absent)'
fi

# --- 2. Synthetic fixture, for auxiliary/hostile cases (plan.md: fixture helpers) -------

synthetic="$tmp/synthetic"
exec 3>&2
eval "$(PATH="$bin:/usr/bin:/bin" "$fixture_builder" "$synthetic" "$bound_jq")"
# The eval above sets: request= map= profile= manifests= assets=
# shellcheck disable=SC2154
synthetic_request="$request"
# shellcheck disable=SC2154
synthetic_map="$map"

# --- 3. Shared run-directory ("group 2") fixture builder --------------------------------
# The only legitimate direct trusted-launch caller: it proves the parent's own
# refusals. A passing group-2 case is not permission for anyone else to launch
# the parent this way.

group2_counter=0
build_run_directory() {
  # build_run_directory OUTPUT [--parent-source SRC] [--helper-source SRC]
  # [--jq PATH] [--skip-jq] [--skip-awk] [--skip-helper]
  g2_output=$1; shift
  g2_parent_src=$parent_source
  g2_helper_src=$helper_source
  g2_jq=$bound_jq
  g2_skip_jq=0 g2_skip_awk=0 g2_skip_helper=0
  while [ $# -gt 0 ]; do
    case $1 in
      --parent-source) g2_parent_src=$2; shift 2 ;;
      --helper-source) g2_helper_src=$2; shift 2 ;;
      --jq) g2_jq=$2; shift 2 ;;
      --skip-jq) g2_skip_jq=1; shift ;;
      --skip-awk) g2_skip_awk=1; shift ;;
      --skip-helper) g2_skip_helper=1; shift ;;
      *) shift ;;
    esac
  done
  /bin/mkdir -m 700 "$g2_output"
  g2_run="$g2_output/.run"
  /bin/mkdir -m 700 "$g2_run"
  /bin/mkdir -m 700 "$g2_run/tmp"
  /bin/mkdir -m 700 "$g2_run/home"
  compile_source "$g2_parent_src" "$g2_run/trusted-launch" \
    "TMPDIR=$g2_run/tmp" "HOME=$g2_run/home"
  if [ "$g2_skip_helper" -ne 1 ]; then
    compile_source "$g2_helper_src" "$g2_run/nofollow-snapshot" \
      "TMPDIR=$g2_run/tmp" "HOME=$g2_run/home"
  fi
  if [ "$g2_skip_jq" -ne 1 ]; then
    /bin/cp "$g2_jq" "$g2_run/jq"
  fi
  if [ "$g2_skip_awk" -ne 1 ]; then
    case "$platform" in
      Linux:x86_64) /bin/cp /usr/bin/awk "$g2_run/awk" ;;
      Darwin:*) /usr/bin/printf '%s\n' '#!/bin/bash' 'exec /usr/bin/awk "$@"' > "$g2_run/awk" ;;
    esac
  fi
  /bin/rm -rf -- "${g2_run:?}/tmp" "${g2_run:?}/home"
  for f in "$g2_run"/*; do [ -e "$f" ] && /bin/chmod 0500 "$f"; done
  /bin/chmod 0500 "$g2_run"
  /bin/chmod 0700 "$g2_output"
}

invoke_parent() {
  # invoke_parent RUN REQUEST MAP OUTPUT [RUN_OVERRIDE]
  ip_run=$1 ip_request=$2 ip_map=$3 ip_output=$4 ip_run_arg=${5:-$1}
  "$ip_run/trusted-launch" resolve "$runtime" "$ip_run/nofollow-snapshot" "$ip_run/jq" \
    "$ip_request" "$ip_map" "$ip_output" "$ip_run_arg"
}

invoke_parent_exec() {
  # invoke_parent_exec RUN REQUEST MAP OUTPUT [RUN_OVERRIDE] -- identical to
  # invoke_parent, but for callers that background it and then watch a caller-
  # owned descriptor's close-ordering (the p1/p2 descriptor cases below).
  # "invoke_parent ... &" leaves a wrapper bash process alive doing an implicit
  # wait() on trusted-launch's whole subtree, inheriting the caller's fifo write
  # end and never closing it -- measured delaying a fifo reader's EOF by double-
  # digit seconds versus a standalone repro with nothing watching that descriptor.
  # Every other invoke_parent caller (group 2 refusals, R3, etc.) runs foreground
  # in the suite's own process, where an unconditional "exec" would replace it --
  # so this exec-tail variant is only for backgrounded, ordering-sensitive callers.
  ipe_run=$1 ipe_request=$2 ipe_map=$3 ipe_output=$4 ipe_run_arg=${5:-$1}
  exec "$ipe_run/trusted-launch" resolve "$runtime" "$ipe_run/nofollow-snapshot" "$ipe_run/jq" \
    "$ipe_request" "$ipe_map" "$ipe_output" "$ipe_run_arg"
}

assert_refused_before_fork() {
  # assert_refused_before_fork NAME STATUS STDOUT STDERR
  # assert_refused_before_fork NAME STATUS STDOUT STDERR [EXPECTED_PREFIX]
  # EXPECTED_PREFIX defaults to E_RUNTIME. The two argv[5]/argv[6] leading-slash
  # cases (non-absolute request/map) are refused by the copied launcher's unchanged
  # E_USAGE shape check (portable-profile-resolution-launcher.c:636), not by
  # deviation 5's new E_RUNTIME regular/non-symlink refinement -- see
  # trusted-launch.c's comment above that branch -- so those two callers pass
  # E_USAGE explicitly rather than reusing this default.
  af_name=$1 af_status=$2 af_stdout=$3 af_stderr=$4 af_prefix=${5:-E_RUNTIME}
  [ "$af_status" -ne 0 ] || fail_case "$af_name: parent exited 0"
  [ ! -s "$af_stdout" ] || fail_case "$af_name: parent wrote stdout before fork"
  [ "$(/usr/bin/wc -l < "$af_stderr" | /usr/bin/awk '{print $1}')" -eq 1 ] ||
    fail_case "$af_name: parent stderr is not exactly one line"
  /usr/bin/grep -q "^$af_prefix" "$af_stderr" || fail_case "$af_name: missing $af_prefix line"
  /usr/bin/grep -q '^runtime-pgid:' "$af_stderr" && fail_case "$af_name: runtime-pgid present on a refusal"
  pass_case "$af_name"
}

# --- 4. Group 1 -- entry-owned refusals (spec.md:7099-7170) -----------------------------
# Driven through the shipped entry. Each pin-check case asserts the E_RUNTIME
# line and that the trap removed .run (folded into entry_pin_refusal below).

entry_pin_case_n=0
entry_pin_refusal() {
  # entry_pin_refusal NAME TAMPERED_TREE_DIR TAMPERED_ENTRY_OR_UNSET
  epr_name=$1 epr_tree=$2
  entry_pin_case_n=$((entry_pin_case_n + 1))
  epr_out="$tmp/group1.$entry_pin_case_n"
  epr_stdout="$epr_out.stdout" epr_stderr="$epr_out.stderr"
  /bin/mkdir -m 700 "$epr_out"
  epr_status=0
  "$epr_tree/resolver/v1/resolve-profile.sh" "$bound_jq" "$epr_out" \
    "$synthetic_request" "$synthetic_map" \
    > "$epr_stdout" 2> "$epr_stderr" || epr_status=$?
  [ "$epr_status" -ne 0 ] || fail_case "$epr_name: entry exited 0"
  /usr/bin/grep -q '^E_RUNTIME' "$epr_stderr" || fail_case "$epr_name: missing E_RUNTIME line"
  epr_listing=$(/usr/bin/find "$epr_out" -mindepth 1 -maxdepth 1)
  [ -z "$epr_listing" ] || fail_case "$epr_name: output directory not empty after cleanup ($epr_listing)"
  pass_case "$epr_name"
}

copy_repo_tree() {
  # copy_repo_tree DEST -- an editable copy of the whole checkout, never the working tree.
  #
  # "git archive | tar -xf" preserves git's recorded modes, but tar applies them
  # through this process's "umask 077" (top of file), so a nominally-644 file
  # lands at 600; the blanket "chmod -R u+w" below only restores owner-write,
  # not group/other bits. Every group-1 case reading this tree is a refusal
  # case tolerant of any reason, which is how this stayed silent -- but
  # resolver/v1/profile-resolve-runtime.sh's mode is a pinned deviation-1
  # check enforced at exactly 0644, so a genuine success run through a copied
  # tree (the "entry-script-as-descriptor" case below) refuses "E_RUNTIME
  # binding" on the wrong file entirely without this fix.
  /bin/mkdir -m 700 "$1"
  /usr/bin/git -C "$root" archive "$real_head" | (cd "$1" && /usr/bin/tar -xf -)
  /bin/chmod -R u+w "$1"
  /bin/chmod 0644 "$1/resolver/v1/profile-resolve-runtime.sh"
}

if [ ! -f "$entry" ]; then
  # The shipped entry does not exist yet: this IS the required initial failing run
  # against absent behavior (plan.md:96-97). Record it and stop attempting entry-driven
  # cases; group-2/mechanism cases below still execute and still fail for the same reason.
  printf 'not ok - shipped entry resolver/v1/resolve-profile.sh does not exist\n' >&2
fi

group1_tree="$tmp/group1-tree"
copy_repo_tree "$group1_tree"

# 1a. jq whose SHA-256 does not match the platform pin.
bad_jq="$tmp/bad-jq"; /usr/bin/printf '#!/bin/sh\nexit 0\n' > "$bad_jq"; /bin/chmod 0555 "$bad_jq"
g1_out="$tmp/g1.badjq"; /bin/mkdir -m 700 "$g1_out"
g1_status=0
"$entry" "$bad_jq" "$g1_out" "$synthetic_request" "$synthetic_map" \
  > "$g1_out.stdout" 2> "$g1_out.stderr" || g1_status=$?
if [ ! -x "$entry" ]; then fail_case 'group1: jq digest mismatch (entry absent)'; fi
if [ "$g1_status" -ne 0 ] && /usr/bin/grep -q '^E_RUNTIME' "$g1_out.stderr" &&
   [ -z "$(/usr/bin/find "$g1_out" -mindepth 1 -maxdepth 1)" ]; then
  pass_case 'group1: entry refuses a jq whose SHA-256 does not match the platform pin'
else
  fail_case 'group1: jq digest mismatch'
fi

# 1a2. <jq> validated pre-hash/exec (spec.md:4650-4654): relative/symlink/fifo/dev-zero refused, no hang; valid jq resolves.
jqv_dir="$tmp/g1-jqval"; /bin/mkdir -m 700 "$jqv_dir"; /bin/ln -s "$bound_jq" "$jqv_dir/symlink"; /usr/bin/mkfifo -m 600 "$jqv_dir/fifo"
jqv_names=(relative symlink fifo dev-zero valid)
jqv_args=("${bound_jq##*/}" "$jqv_dir/symlink" "$jqv_dir/fifo" /dev/zero "$bound_jq")
jqv_codes=(E_USAGE E_RUNTIME E_RUNTIME E_RUNTIME '')
for jqv_i in 0 1 2 3 4; do
  jqv_out="$tmp/g1.jqval.${jqv_names[$jqv_i]}"; /bin/mkdir -m 700 "$jqv_out"
  ( "$entry" "${jqv_args[$jqv_i]}" "$jqv_out" "$synthetic_request" "$synthetic_map" \
      > "$jqv_out.stdout" 2> "$jqv_out.stderr" ) & jqv_pid=$!
  jqv_deadline=$(( $(/bin/date +%s) + $([ "${jqv_names[$jqv_i]}" = valid ] && echo 30 || echo 5) ))
  while kill -0 "$jqv_pid" 2>/dev/null && [ "$(/bin/date +%s)" -lt "$jqv_deadline" ]; do /bin/sleep 0.02; done
  kill -0 "$jqv_pid" 2>/dev/null && { kill -9 "$jqv_pid" 2>/dev/null; fail_case "group1: jq validation (${jqv_names[$jqv_i]}) hung"; }
  jqv_status=0; wait "$jqv_pid" 2>/dev/null || jqv_status=$?
  [ "${jqv_names[$jqv_i]}" = valid ] && { [ "$jqv_status" -eq 0 ] || fail_case 'group1: valid jq rejected by argument validation'; continue; }
  { [ "$jqv_status" -ne 0 ] && /usr/bin/grep -q "^${jqv_codes[$jqv_i]}" "$jqv_out.stderr" &&
    [ -z "$(/usr/bin/find "$jqv_out" -mindepth 1 -maxdepth 1)" ]; } || fail_case "group1: jq validation (${jqv_names[$jqv_i]})"
done
pass_case 'group1: jq argument validated (absolute, regular, non-symlink, executable) before hashing or executing'

# 1b-1f: edited pinned source files, each in its own copy of the tree.
for target in resolver/v1/nofollow-snapshot.c resolver/v1/trusted-launch.c \
              scripts/lib/profile-resolution.sh resolver/v1/profile-resolution.jq \
              "core/v2/generations/$core_generation_value/modules/schema.jq"; do
  edited_tree="$tmp/group1-edit-$(printf '%s' "$target" | /usr/bin/tr '/' '_')"
  copy_repo_tree "$edited_tree"
  /usr/bin/printf '\n' >> "$edited_tree/$target"
  entry_pin_refusal "group1: edited $target is refused on its own pin" "$edited_tree"
done

# The trusted-launch.c case carries two extra assertions: no compiler ever ran, and the
# neighbouring nofollow-snapshot.c pin is untouched.
tl_tree="$tmp/group1-trusted-launch"
copy_repo_tree "$tl_tree"
/usr/bin/printf '\n' >> "$tl_tree/resolver/v1/trusted-launch.c"
tl_out="$tmp/g1.trusted-launch-source"; /bin/mkdir -m 700 "$tl_out"
tl_poll_saw_compile=0
if [ -x "$entry" ]; then
  (
    "$tl_tree/resolver/v1/resolve-profile.sh" "$bound_jq" "$tl_out" \
      "$synthetic_request" "$synthetic_map" > "$tl_out.stdout" 2> "$tl_out.stderr"
  ) &
  tl_pid=$!
  tl_deadline=$(( $(/bin/date +%s) + 30 ))
  while kill -0 "$tl_pid" 2>/dev/null; do
    if [ -e "$tl_out/.run/trusted-launch" ] || \
       /usr/bin/find "$tl_out/.run" -maxdepth 1 -name '*.o' 2>/dev/null | /usr/bin/grep -q .; then
      tl_poll_saw_compile=1
    fi
    [ "$(/bin/date +%s)" -lt "$tl_deadline" ] || break
    /bin/sleep 0.02
  done
  tl_status=0
  wait "$tl_pid" || tl_status=$?
  [ "$tl_status" -ne 0 ] || fail_case 'group1: edited trusted-launch.c source is refused (status)'
  /usr/bin/grep -qi 'trusted-launch' "$tl_out.stderr" || fail_case 'group1: refusal does not name the parent-source pin'
  [ "$tl_poll_saw_compile" -eq 0 ] || fail_case 'group1: compiler ran before the source pin was checked'
  [ -z "$(/usr/bin/find "$tl_out" -mindepth 1 -maxdepth 1)" ] || fail_case 'group1: output not empty after trusted-launch.c refusal'
  [ "$(/usr/bin/git -C "$root" hash-object "$tl_tree/resolver/v1/nofollow-snapshot.c")" = \
    "$(/usr/bin/git -C "$root" hash-object "$root/resolver/v1/nofollow-snapshot.c")" ] ||
    fail_case 'group1: neighbouring nofollow-snapshot.c pin was touched by the test'
  pass_case 'group1: edited trusted-launch.c source refused with no compile and full cleanup'
else
  fail_case 'group1: edited trusted-launch.c source (entry absent)'
fi

# 1g. output path too long for the entry's own length guard.
long_base="$tmp/g1-long"
/bin/mkdir -m 700 "$long_base"
long_ceiling=$( [ "${platform%%:*}" = Darwin ] && echo 1024 || echo 4096 )
long_dir="$long_base"
while [ "${#long_dir}" -lt $((long_ceiling - 16)) ]; do
  long_dir="$long_dir/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  /bin/mkdir -m 700 "$long_dir" 2>/dev/null || break
done
if [ -x "$entry" ] && [ "${#long_dir}" -ge $((long_ceiling - 16)) ]; then
  long_status=0
  "$entry" "$bound_jq" "$long_dir" "$synthetic_request" "$synthetic_map" \
    > "$tmp/g1.long.stdout" 2> "$tmp/g1.long.stderr" || long_status=$?
  if [ "$long_status" -ne 0 ] && /usr/bin/grep -q '^E_RUNTIME' "$tmp/g1.long.stderr"; then
    pass_case 'group1: entry refuses an overlong output path before creating anything'
  else
    fail_case 'group1: overlong output path'
  fi
else
  fail_case 'group1: overlong output path (entry absent or platform PATH_MAX unreachable)'
fi

# 1g2. output path length strictly between the parent's own shorter copied
# guard (PATH_MAX-16, room for "<output>/child.stdout") and the entry's
# stricter R1 bound (10 bytes for "/.run/tmp/" + a full 255-byte NAME_MAX
# name = 265 total). The parent's guard alone would accept this path, but
# the entry must still refuse it before writing a ".run" scratch directory.
entry_reserve=265
mid_base="$tmp/g1-mid"
/bin/mkdir -m 700 "$mid_base"
mid_dir="$mid_base"
mid_target=$((long_ceiling - 200))
while [ "${#mid_dir}" -lt "$mid_target" ]; do
  mid_dir="$mid_dir/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  /bin/mkdir -m 700 "$mid_dir" 2>/dev/null || break
done
if [ -x "$entry" ] &&
   [ "${#mid_dir}" -gt $((long_ceiling - entry_reserve)) ] &&
   [ "${#mid_dir}" -le $((long_ceiling - 16)) ]; then
  mid_status=0
  "$entry" "$bound_jq" "$mid_dir" "$synthetic_request" "$synthetic_map" \
    > "$tmp/g1.mid.stdout" 2> "$tmp/g1.mid.stderr" || mid_status=$?
  if [ "$mid_status" -ne 0 ] && /usr/bin/grep -q '^E_RUNTIME' "$tmp/g1.mid.stderr" &&
     [ ! -e "$mid_dir/.run" ] && [ -z "$(/usr/bin/find "$mid_dir" -mindepth 1 -maxdepth 1)" ]; then
    pass_case 'group1: entry refuses a path between the parent guard and its own bound, no scratch dir created'
  else
    fail_case 'group1: mid-length output path (accepted, or a scratch directory was created)'
  fi
else
  fail_case 'group1: mid-length output path (entry absent or interval unreachable on this filesystem)'
fi

# 1h-1l. Five output-root validate-first cases: each asserts the target was never
# written to (no .run, entry set unchanged) because the refusal precedes any write.
assert_output_untouched_refusal() {
  # assert_output_untouched_refusal NAME OUTPUT_DIR BEFORE_LISTING
  aou_name=$1 aou_dir=$2 aou_before=$3
  aou_status=0
  "$entry" "$bound_jq" "$aou_dir" "$synthetic_request" "$synthetic_map" \
    > "$tmp/aou.stdout" 2> "$tmp/aou.stderr" || aou_status=$?
  [ "$aou_status" -ne 0 ] || fail_case "$aou_name: exited 0"
  /usr/bin/grep -q '^E_RUNTIME' "$tmp/aou.stderr" || fail_case "$aou_name: missing E_RUNTIME"
  aou_after=$(/usr/bin/find "$aou_dir" -mindepth 1 -print 2>/dev/null | /usr/bin/sort)
  [ "$aou_after" = "$aou_before" ] || fail_case "$aou_name: target was written to"
  pass_case "$aou_name"
}

if [ -x "$entry" ]; then
  # symlink output
  real_out="$tmp/g1.symlink-target"; /bin/mkdir -m 700 "$real_out"
  sym_out="$tmp/g1.symlink"; /bin/ln -s "$real_out" "$sym_out"
  assert_output_untouched_refusal 'group1: output path is a symlink' "$sym_out" ''

  # group-writable 0750
  gw_out="$tmp/g1.groupwritable"; /bin/mkdir -m 750 "$gw_out"
  assert_output_untouched_refusal 'group1: output mode 0750 instead of 0700' "$gw_out" ''

  # holds an ordinary file
  file_out="$tmp/g1.hasfile"; /bin/mkdir -m 700 "$file_out"; : > "$file_out/stray"
  assert_output_untouched_refusal 'group1: output already holds an ordinary file' "$file_out" "$file_out/stray"

  # holds a .run entry
  run_out="$tmp/g1.hasrun"; /bin/mkdir -m 700 "$run_out"; /bin/mkdir -m 700 "$run_out/.run"
  assert_output_untouched_refusal 'group1: output already holds a .run entry' "$run_out" "$run_out/.run"

  # owned by another uid: skip under root with a printed reason, else point at a
  # root-owned system directory this test never writes to.
  if [ "$(id -u)" -eq 0 ]; then
    skip_case 'group1: output owned by another uid' 'suite is running as root'
  else
    other_status=0
    "$entry" "$bound_jq" /usr/bin "$synthetic_request" "$synthetic_map" \
      > "$tmp/g1.otheruid.stdout" 2> "$tmp/g1.otheruid.stderr" || other_status=$?
    if [ "$other_status" -ne 0 ] && /usr/bin/grep -q '^E_RUNTIME' "$tmp/g1.otheruid.stderr" &&
       [ ! -e /usr/bin/.run ]; then
      pass_case 'group1: output owned by another uid is refused before any write'
    else
      fail_case 'group1: other-uid output'
    fi
  fi
else
  fail_case 'group1: five output-root cases (entry absent)'
fi

# --- 5. Group 2 -- parent-owned refusals, direct invocation (spec.md:7247-7420) ---------

if [ -f "$parent_source" ] && [ -f "$helper_source" ]; then
  parent_available=1
else
  parent_available=0
  printf 'not ok - shipped parent resolver/v1/trusted-launch.c does not exist\n' >&2
fi

run_direct_refusal_case() {
  # run_direct_refusal_case NAME RUN REQUEST MAP OUTPUT [RUN_ARG] [EXPECTED_PREFIX]
  rdr_name=$1 rdr_run=$2 rdr_request=$3 rdr_map=$4 rdr_output=$5 rdr_arg=${6:-$2} rdr_prefix=${7:-E_RUNTIME}
  rdr_status=0
  invoke_parent "$rdr_run" "$rdr_request" "$rdr_map" "$rdr_output" "$rdr_arg" \
    > "$rdr_output.stdout" 2> "$rdr_output.stderr" || rdr_status=$?
  assert_refused_before_fork "$rdr_name" "$rdr_status" "$rdr_output.stdout" "$rdr_output.stderr" "$rdr_prefix"
}

if [ "$parent_available" -eq 1 ]; then
  group2_counter=$((group2_counter + 1))

  # Positive control for this entire group's output/run pairing: deviation 4
  # requires the OUTPUT argument to be the directory that directly contains
  # .run (exactly {".run"}, same object as the RUN argument) -- an unrelated
  # empty directory fails that check immediately with E_RUNTIME output before
  # any other R5 check runs, which would silently swallow every refusal case
  # below regardless of its own specific tamper. Prove the pairing itself
  # works first: an untampered build_run_directory, invoked with genuine
  # sources and OUTPUT set to its own container, must succeed end-to-end.
  g2_control_out="$tmp/g2.positive-control"; build_run_directory "$g2_control_out"
  g2_control_status=0
  invoke_parent "$g2_control_out/.run" "$synthetic_request" "$synthetic_map" "$g2_control_out" \
    > "$g2_control_out.stdout" 2> "$g2_control_out.stderr" || g2_control_status=$?
  if [ "$g2_control_status" -eq 0 ]; then
    pass_case 'group2: positive control -- untampered run/output pair succeeds'
  else
    fail_case "group2: positive control failed (status=$g2_control_status): $(cat "$g2_control_out.stderr" 2>/dev/null)"
  fi

  g2out="$tmp/g2.runtime-blob"
  build_run_directory "$g2out"
  /bin/chmod u+w "$g2out"
  runtime_copy="$tmp/g2.runtime-copy.sh"
  /bin/cp "$runtime" "$runtime_copy"; /usr/bin/printf '\n' >> "$runtime_copy"; /bin/chmod 0644 "$runtime_copy"
  g2status=0
  "$g2out/.run/trusted-launch" resolve "$runtime_copy" "$g2out/.run/nofollow-snapshot" \
    "$g2out/.run/jq" "$synthetic_request" "$synthetic_map" "$g2out" "$g2out/.run" \
    > "$g2out.stdout" 2> "$g2out.stderr" || g2status=$?
  assert_refused_before_fork 'group2: runtime file blob id mismatch' "$g2status" "$g2out.stdout" "$g2out.stderr" 'E_RUNTIME pin'

  # runtime file mode 0755 instead of 0644
  g2out2="$tmp/g2.runtime-mode"; build_run_directory "$g2out2"
  mode_runtime="$tmp/g2.runtime-mode.sh"; /bin/cp "$runtime" "$mode_runtime"; /bin/chmod 0755 "$mode_runtime"
  g2o2="$tmp/g2.runtime-mode.out"; /bin/mkdir -m 700 "$g2o2"
  g2s2=0
  "$g2out2/.run/trusted-launch" resolve "$mode_runtime" "$g2out2/.run/nofollow-snapshot" \
    "$g2out2/.run/jq" "$synthetic_request" "$synthetic_map" "$g2o2" "$g2out2/.run" \
    > "$g2o2.stdout" 2> "$g2o2.stderr" || g2s2=$?
  assert_refused_before_fork 'group2: runtime file mode 0755 instead of 0644' "$g2s2" "$g2o2.stdout" "$g2o2.stderr" 'E_RUNTIME binding'

  # library / jq-program blob mismatch (two cases), reached via a runtime path inside an
  # edited copy of the repository tree.
  for lib_target in scripts/lib/profile-resolution.sh resolver/v1/profile-resolution.jq; do
    lib_tree="$tmp/g2-lib-$(printf '%s' "$lib_target" | /usr/bin/tr '/' '_')"
    copy_repo_tree "$lib_tree"
    /usr/bin/printf '\n' >> "$lib_tree/$lib_target"
    g2out3="$tmp/g2.lib.$(printf '%s' "$lib_target" | /usr/bin/tr '/' '_')"
    build_run_directory "$g2out3"
    g2o3="$g2out3"
    g2s3=0
    "$g2out3/.run/trusted-launch" resolve "$lib_tree/resolver/v1/profile-resolve-runtime.sh" \
      "$g2out3/.run/nofollow-snapshot" "$g2out3/.run/jq" "$synthetic_request" "$synthetic_map" \
      "$g2o3" "$g2out3/.run" > "$g2o3.stdout" 2> "$g2o3.stderr" || g2s3=$?
    assert_refused_before_fork "group2: $lib_target blob mismatch (parent's own copy)" "$g2s3" "$g2o3.stdout" "$g2o3.stderr" 'E_RUNTIME pin'
  done

  # edited jq module under modules/ (this round's case: schema.jq).
  mod_tree="$tmp/g2-module"
  copy_repo_tree "$mod_tree"
  /usr/bin/printf '\n' >> "$mod_tree/core/v2/generations/$core_generation_value/modules/schema.jq"
  g2out4="$tmp/g2.module"; build_run_directory "$g2out4"
  g2o4="$g2out4"
  g2s4=0
  "$g2out4/.run/trusted-launch" resolve "$mod_tree/resolver/v1/profile-resolve-runtime.sh" \
    "$g2out4/.run/nofollow-snapshot" "$g2out4/.run/jq" "$synthetic_request" "$synthetic_map" \
    "$g2o4" "$g2out4/.run" > "$g2o4.stdout" 2> "$g2o4.stderr" || g2s4=$?
  assert_refused_before_fork 'group2: edited schema.jq module refused by parent alone (library unedited)' "$g2s4" "$g2o4.stdout" "$g2o4.stderr" 'E_RUNTIME pin'

  # sibling case: library's own generation constant changed, refused on the library's blob pin.
  gen_tree="$tmp/g2-generation-const"
  copy_repo_tree "$gen_tree"
  /usr/bin/sed -i.bak "s/PROFILE_RESOLUTION_CORE_GENERATION='g-c83c940/PROFILE_RESOLUTION_CORE_GENERATION='g-000000/" \
    "$gen_tree/scripts/lib/profile-resolution.sh" 2>/dev/null || \
    /usr/bin/perl -pi -e "s/PROFILE_RESOLUTION_CORE_GENERATION='g-c83c940/PROFILE_RESOLUTION_CORE_GENERATION='g-000000/" \
    "$gen_tree/scripts/lib/profile-resolution.sh"
  g2out5="$tmp/g2.generation-const"; build_run_directory "$g2out5"
  g2o5="$g2out5"
  g2s5=0
  "$g2out5/.run/trusted-launch" resolve "$gen_tree/resolver/v1/profile-resolve-runtime.sh" \
    "$g2out5/.run/nofollow-snapshot" "$g2out5/.run/jq" "$synthetic_request" "$synthetic_map" \
    "$g2o5" "$g2out5/.run" > "$g2o5.stdout" 2> "$g2o5.stderr" || g2s5=$?
  assert_refused_before_fork "group2: edited library generation constant refused on library's own blob pin" "$g2s5" "$g2o5.stdout" "$g2o5.stderr" 'E_RUNTIME pin'

  # jq SHA-256 mismatch
  g2out6="$tmp/g2.jq-sha256"; build_run_directory "$g2out6" --skip-jq
  /bin/chmod u+w "$g2out6/.run"
  /usr/bin/printf '#!/bin/sh\nexit 0\n' > "$g2out6/.run/jq"; /bin/chmod 0500 "$g2out6/.run/jq" "$g2out6/.run"
  run_direct_refusal_case 'group2: jq SHA-256 mismatch' "$g2out6/.run" "$synthetic_request" "$synthetic_map" "$g2out6" "$g2out6/.run" 'E_RUNTIME jq'

  # jq that does not answer jq-1.6
  g2out7="$tmp/g2.jq-version"; build_run_directory "$g2out7" --skip-jq
  /bin/chmod u+w "$g2out7/.run"
  /usr/bin/printf '#!/bin/sh\necho jq-1.5\n' > "$g2out7/.run/jq"; /bin/chmod 0500 "$g2out7/.run/jq" "$g2out7/.run"
  run_direct_refusal_case 'group2: jq answers the wrong version string' "$g2out7/.run" "$synthetic_request" "$synthetic_map" "$g2out7" "$g2out7/.run" 'E_RUNTIME jq'

  # a valid pinned jq that is not the run directory's own, with a negative marker control
  g2out8="$tmp/g2.jq-identity"; build_run_directory "$g2out8"
  other_dir="$tmp/g2.jq-identity.other"; /bin/mkdir -m 700 "$other_dir"
  /bin/cp "$bound_jq" "$other_dir/jq"; /bin/chmod 0500 "$other_dir/jq"
  /usr/bin/printf '#!/bin/sh\nprintf YSTACK-AWK-MARKER\\\\n\nexit 1\n' > "$other_dir/awk"; /bin/chmod 0500 "$other_dir/awk"
  "$other_dir/awk" > "$tmp/g2.jq-identity.control" 2>&1 || :
  /usr/bin/grep -q YSTACK-AWK-MARKER "$tmp/g2.jq-identity.control" || fail_case 'group2: jq-identity negative control awk did not print its marker'
  g2o8dest="$g2out8"
  g2s8=0
  PATH="$other_dir:/usr/bin:/bin" \
    "$g2out8/.run/trusted-launch" resolve "$runtime" "$g2out8/.run/nofollow-snapshot" \
    "$other_dir/jq" "$synthetic_request" "$synthetic_map" "$g2o8dest" "$g2out8/.run" \
    > "$g2o8dest.stdout" 2> "$g2o8dest.stderr" || g2s8=$?
  assert_refused_before_fork 'group2: valid pinned jq that is not the run directory''s own' "$g2s8" "$g2o8dest.stdout" "$g2o8dest.stderr" 'E_RUNTIME jq'
  /usr/bin/grep -q YSTACK-AWK-MARKER "$g2o8dest.stdout" "$g2o8dest.stderr" 2>/dev/null &&
    fail_case 'group2: caller awk marker leaked into parent run' || :

  # tampered .run/awk (one byte flipped, or on Darwin a third shim line)
  g2out9="$tmp/g2.awk-tamper"; build_run_directory "$g2out9"
  /bin/chmod u+w "$g2out9/.run" "$g2out9/.run/awk"
  case "$platform" in
    Darwin:*) /usr/bin/printf '%s\n' '#!/bin/bash' 'exec /usr/bin/awk "$@"' 'true' > "$g2out9/.run/awk" ;;
    *) /usr/bin/printf '\000' | /bin/dd of="$g2out9/.run/awk" bs=1 seek=0 count=1 conv=notrunc 2>/dev/null ;;
  esac
  /bin/chmod 0500 "$g2out9/.run/awk" "$g2out9/.run"
  run_direct_refusal_case 'group2: tampered .run/awk bytes' "$g2out9/.run" "$synthetic_request" "$synthetic_map" "$g2out9" "$g2out9/.run" 'E_RUNTIME awk'

  # hardlink to the genuine .run/jq at a sibling directory, marker awk beside it
  g2out10="$tmp/g2.jq-hardlink"; build_run_directory "$g2out10"
  hl_dir="$tmp/g2.jq-hardlink.sibling"; /bin/mkdir -m 700 "$hl_dir"
  /bin/ln "$g2out10/.run/jq" "$hl_dir/jq"
  /usr/bin/printf '#!/bin/sh\nprintf YSTACK-AWK-MARKER\\\\n\nexit 1\n' > "$hl_dir/awk"; /bin/chmod 0500 "$hl_dir/awk"
  [ "$(/usr/bin/stat -c '%d:%i' "$hl_dir/jq" 2>/dev/null || /usr/bin/stat -f '%d:%i' "$hl_dir/jq")" = \
    "$(/usr/bin/stat -c '%d:%i' "$g2out10/.run/jq" 2>/dev/null || /usr/bin/stat -f '%d:%i' "$g2out10/.run/jq")" ] ||
    fail_case 'group2: hardlink fixture device/inode mismatch'
  g2o10dest="$g2out10"
  g2s10=0
  PATH="$hl_dir:/usr/bin:/bin" \
    "$g2out10/.run/trusted-launch" resolve "$runtime" "$g2out10/.run/nofollow-snapshot" \
    "$hl_dir/jq" "$synthetic_request" "$synthetic_map" "$g2o10dest" "$g2out10/.run" \
    > "$g2o10dest.stdout" 2> "$g2o10dest.stderr" || g2s10=$?
  assert_refused_before_fork 'group2: hardlinked jq at a sibling directory (directory identity)' "$g2s10" "$g2o10dest.stdout" "$g2o10dest.stderr" 'E_RUNTIME jq'

  # non-absolute / symlinked request and map (four cases). The non-absolute pair
  # fails the copied launcher's unchanged leading-slash shape check
  # (portable-profile-resolution-launcher.c:636), which lives in the E_USAGE
  # argument-parsing branch ahead of deviation 5's E_RUNTIME regular/non-symlink
  # check -- so, unlike every other case in this group, these two expect E_USAGE.
  # Run these two directly rather than inside a "( cd ... && run_direct_refusal_case
  # ... )" subshell: run_direct_refusal_case calls fail_case on a mismatch, and
  # fail_case's "exit 1" inside a subshell only ends that subshell -- it neither
  # fails the overall suite nor advances the outer $total/$passed counters, which
  # is how the previous draft's two non-absolute cases both printed "ok 27" above.
  # A relative request/map argument does not need an actual chdir either: the
  # parent's leading-slash shape check is a plain argv[5][0]/argv[6][0] test, never
  # resolved against a cwd, so the bare basename string is enough on its own.
  g2out11="$tmp/g2.paths"; build_run_directory "$g2out11"
  run_direct_refusal_case 'group2: non-absolute request path' "$g2out11/.run" \
    "$(basename "$synthetic_request")" "$synthetic_map" "$g2out11.dest1" \
    "$g2out11/.run" E_USAGE
  run_direct_refusal_case 'group2: non-absolute map path' "$g2out11/.run" \
    "$synthetic_request" "$(basename "$synthetic_map")" "$g2out11.dest2" \
    "$g2out11/.run" E_USAGE
  sym_request="$tmp/g2.request.symlink"; /bin/ln -s "$synthetic_request" "$sym_request"
  run_direct_refusal_case 'group2: symlinked request path' "$g2out11/.run" "$sym_request" "$synthetic_map" \
    "$g2out11.dest3" "$g2out11/.run" 'E_RUNTIME binding'
  sym_map="$tmp/g2.map.symlink"; /bin/ln -s "$synthetic_map" "$sym_map"
  run_direct_refusal_case 'group2: symlinked map path' "$g2out11/.run" "$synthetic_request" "$sym_map" \
    "$g2out11.dest4" "$g2out11/.run" 'E_RUNTIME binding'

  # allowlisted overlong value: output path near PATH_MAX (parent's copied guard at :641)
  g2out12="$tmp/g2.overlong-output"; build_run_directory "$g2out12"
  long_out_base="$tmp/g2ol"; /bin/mkdir -m 700 "$long_out_base"
  long_out="$long_out_base"
  while [ "${#long_out}" -lt $((long_ceiling - 16)) ]; do
    long_out="$long_out/yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy"
    /bin/mkdir -m 700 "$long_out" 2>/dev/null || break
  done
  if [ "${#long_out}" -ge $((long_ceiling - 16)) ]; then
    # Capture files must live at a short, fixed path: $long_out itself is already
    # within 16 bytes of the platform's real filesystem PATH_MAX, so appending
    # ".stdout"/".stderr" to it (as run_direct_refusal_case's shared helper would)
    # overflows the OS's own path-length limit before the parent is even
    # invoked -- an "ENAMETOOLONG"/"File name too long" shell redirection
    # failure that has nothing to do with the guard under test. Group 1's
    # equivalent overlong-path case (1g, above) avoids the same trap by
    # capturing to a short name under $tmp; mirrored here directly rather than
    # through run_direct_refusal_case, whose capture-path convention this one
    # case cannot use.
    g2o12_stdout="$tmp/g2.overlong-output.stdout"
    g2o12_stderr="$tmp/g2.overlong-output.stderr"
    g2s12=0
    invoke_parent "$g2out12/.run" "$synthetic_request" "$synthetic_map" "$long_out" "$g2out12/.run" \
      > "$g2o12_stdout" 2> "$g2o12_stderr" || g2s12=$?
    assert_refused_before_fork 'group2: allowlisted output path exceeds the fixed buffer' "$g2s12" "$g2o12_stdout" "$g2o12_stderr" 'E_RUNTIME binding'
  else
    fail_case 'group2: overlong output path (platform will not build one)'
  fi

  # compiled parent binary mode not 0500; helper mode not 0500 / outside run dir; run dir not 0500
  g2out13="$tmp/g2.parent-mode"; build_run_directory "$g2out13"
  /bin/chmod u+w "$g2out13/.run"; /bin/chmod 0700 "$g2out13/.run/trusted-launch"; /bin/chmod 0500 "$g2out13/.run"
  run_direct_refusal_case 'group2: compiled parent binary mode is not 0500' "$g2out13/.run" "$synthetic_request" "$synthetic_map" "$g2out13" "$g2out13/.run" 'E_RUNTIME run-directory'

  g2out14="$tmp/g2.helper-mode"; build_run_directory "$g2out14"
  /bin/chmod u+w "$g2out14/.run"; /bin/chmod 0700 "$g2out14/.run/nofollow-snapshot"; /bin/chmod 0500 "$g2out14/.run"
  run_direct_refusal_case 'group2: helper mode is not 0500' "$g2out14/.run" "$synthetic_request" "$synthetic_map" "$g2out14" "$g2out14/.run" 'E_RUNTIME run-directory'

  g2out15="$tmp/g2.helper-outside"; build_run_directory "$g2out15" --skip-helper
  outside_helper="$tmp/g2.helper-outside.helper"
  compile_source "$helper_source" "$outside_helper"; /bin/chmod 0500 "$outside_helper"
  g2o15="$g2out15"
  g2s15=0
  "$g2out15/.run/trusted-launch" resolve "$runtime" "$outside_helper" "$g2out15/.run/jq" \
    "$synthetic_request" "$synthetic_map" "$g2o15" "$g2out15/.run" \
    > "$g2o15.stdout" 2> "$g2o15.stderr" || g2s15=$?
  assert_refused_before_fork 'group2: helper is outside the run directory it was given' "$g2s15" "$g2o15.stdout" "$g2o15.stderr" 'E_RUNTIME run-directory'

  g2out16="$tmp/g2.rundir-mode"; build_run_directory "$g2out16"
  /bin/chmod 0700 "$g2out16/.run"
  run_direct_refusal_case 'group2: run directory mode is not 0500' "$g2out16/.run" "$synthetic_request" "$synthetic_map" "$g2out16" "$g2out16/.run" 'E_RUNTIME run-directory'

  # direct-parent .run name-set cases: extra cat with marker, extra directory, missing
  # helper, helper basename collides with jq.
  g2out17="$tmp/g2.extra-cat"; build_run_directory "$g2out17"
  /bin/chmod u+w "$g2out17/.run"
  /usr/bin/printf '#!/bin/sh\nprintf YSTACK-CAT-MARKER\\\\n\nexit 1\n' > "$g2out17/.run/cat"; /bin/chmod 0500 "$g2out17/.run/cat"
  "$g2out17/.run/cat" > "$tmp/g2.extra-cat.control" 2>&1 || :
  /usr/bin/grep -q YSTACK-CAT-MARKER "$tmp/g2.extra-cat.control" || fail_case 'group2: extra-cat negative control did not print its marker'
  /bin/chmod 0500 "$g2out17/.run"
  g2o17dest="$g2out17"
  g2s17=0
  "$g2out17/.run/trusted-launch" resolve "$runtime" "$g2out17/.run/nofollow-snapshot" "$g2out17/.run/jq" \
    "$synthetic_request" "$synthetic_map" "$g2o17dest" "$g2out17/.run" \
    > "$g2o17dest.stdout" 2> "$g2o17dest.stderr" || g2s17=$?
  assert_refused_before_fork 'group2: extra executable cat in .run' "$g2s17" "$g2o17dest.stdout" "$g2o17dest.stderr" 'E_RUNTIME run-directory'
  /usr/bin/grep -q YSTACK-CAT-MARKER "$g2o17dest.stdout" "$g2o17dest.stderr" 2>/dev/null &&
    fail_case 'group2: extra-cat marker leaked into parent run' || :

  g2out18="$tmp/g2.extra-dir"; build_run_directory "$g2out18"
  /bin/chmod u+w "$g2out18/.run"; /bin/mkdir -m 500 "$g2out18/.run/extra"; /bin/chmod 0500 "$g2out18/.run"
  run_direct_refusal_case 'group2: extra directory in .run' "$g2out18/.run" "$synthetic_request" "$synthetic_map" "$g2out18" "$g2out18/.run" 'E_RUNTIME run-directory'

  # The parent opens the helper via openat(run_fd, basename(argv[3]), ...) -- only
  # the basename is looked up inside .run (trusted-launch.c:1661-1673,1691) -- so
  # this case needs a real, absolute, regular, non-symlink, EXECUTABLE (X_OK; a
  # plain data file fails the E_USAGE argv-shape gate itself) helper argument
  # whose basename is absent from .run's actual listing. run_direct_refusal_case /
  # invoke_parent always point the helper at "<run>/nofollow-snapshot" (which
  # --skip-helper leaves nonexistent, failing E_USAGE before reaching R5's check),
  # so this case is invoked directly with a compiled binary outside .run, under a
  # non-colliding name, to clear the gate and fail R5's exact-four-names lookup.
  g2out19="$tmp/g2.missing-helper"; build_run_directory "$g2out19" --skip-helper
  missing_helper_bin="$tmp/g2.missing-helper.absent-from-run"
  compile_source "$helper_source" "$missing_helper_bin"; /bin/chmod 0500 "$missing_helper_bin"
  g2o19dest="$g2out19"
  g2s19=0
  "$g2out19/.run/trusted-launch" resolve "$runtime" "$missing_helper_bin" "$g2out19/.run/jq" \
    "$synthetic_request" "$synthetic_map" "$g2o19dest" "$g2out19/.run" \
    > "$g2o19dest.stdout" 2> "$g2o19dest.stderr" || g2s19=$?
  assert_refused_before_fork 'group2: missing helper in .run' "$g2s19" "$g2o19dest.stdout" "$g2o19dest.stderr" 'E_RUNTIME run-directory'

  # R5's exact-four-names rule keys the "helper" slot off the *argument's* last path
  # component, not off whatever the file on disk happens to be named. So the collision
  # this case must reproduce is: hand trusted-launch a helper argument whose basename is
  # literally "jq" (the run directory's real jq, left in place), which leaves the
  # untouched, genuinely-required nofollow-snapshot file as an unaccounted-for fifth
  # name in the .run listing -- not a helper file renamed to some other, non-colliding
  # name (a prior draft renamed it to "jq-helper", which does not collide with "jq" at
  # all and so never reached this refusal).
  g2out20="$tmp/g2.helper-basename"; build_run_directory "$g2out20"
  g2o20dest="$g2out20"
  g2s20=0
  "$g2out20/.run/trusted-launch" resolve "$runtime" "$g2out20/.run/jq" "$g2out20/.run/jq" \
    "$synthetic_request" "$synthetic_map" "$g2o20dest" "$g2out20/.run" \
    > "$g2o20dest.stdout" 2> "$g2o20dest.stderr" || g2s20=$?
  assert_refused_before_fork 'group2: helper argument basename collides with jq' "$g2s20" "$g2o20dest.stdout" "$g2o20dest.stderr" 'E_RUNTIME run-directory'

  # .run/awk symlink, directory in its place, wrong-mode copy
  # build_run_directory tightens .run to 0500 unconditionally, --skip-* flags only
  # skip creating that one file -- so, like the two --skip-jq cases above, writing
  # the substitute awk into .run afterwards needs the directory reopened first.
  g2out21="$tmp/g2.awk-symlink"; build_run_directory "$g2out21" --skip-awk
  awk_target="$tmp/g2.awk-symlink.target"; /usr/bin/printf '#!/bin/sh\nexec /usr/bin/awk "$@"\n' > "$awk_target"; /bin/chmod 0500 "$awk_target"
  /bin/chmod u+w "$g2out21/.run"
  /bin/ln -s "$awk_target" "$g2out21/.run/awk"
  /bin/chmod 0500 "$g2out21/.run"
  run_direct_refusal_case 'group2: .run/awk is a symlink' "$g2out21/.run" "$synthetic_request" "$synthetic_map" "$g2out21" "$g2out21/.run" 'E_RUNTIME awk'

  g2out22="$tmp/g2.awk-dir"; build_run_directory "$g2out22" --skip-awk
  /bin/chmod u+w "$g2out22/.run"
  /bin/mkdir -m 500 "$g2out22/.run/awk"
  /bin/chmod 0500 "$g2out22/.run"
  run_direct_refusal_case 'group2: .run/awk is a directory' "$g2out22/.run" "$synthetic_request" "$synthetic_map" "$g2out22" "$g2out22/.run" 'E_RUNTIME awk'

  g2out23="$tmp/g2.awk-wrongmode"; build_run_directory "$g2out23"
  /bin/chmod u+w "$g2out23/.run"; /bin/chmod 0700 "$g2out23/.run/awk"; /bin/chmod 0500 "$g2out23/.run"
  run_direct_refusal_case 'group2: .run/awk wrong-mode copy' "$g2out23/.run" "$synthetic_request" "$synthetic_map" "$g2out23" "$g2out23/.run" 'E_RUNTIME awk'

  # output path itself a symlink to an otherwise valid output directory
  g2out24="$tmp/g2.output-symlink"; build_run_directory "$g2out24"
  real_dest24="$tmp/g2.output-symlink.real"; /bin/mkdir -m 700 "$real_dest24"
  sym_dest24="$tmp/g2.output-symlink.link"; /bin/ln -s "$real_dest24" "$sym_dest24"
  run_direct_refusal_case 'group2: output path is itself a symlink' "$g2out24/.run" "$synthetic_request" "$synthetic_map" \
    "$sym_dest24" "$g2out24/.run" 'E_RUNTIME output'

  # output-directory entry-set cases: extra entry, wrong mode, decoy .run, symlinked
  # .run to a valid run dir, .run as a regular file -- assert the parent touched nothing.
  assert_direct_untouched_refusal() {
    adu_name=$1 adu_run=$2 adu_output=$3
    adu_before=$(/usr/bin/find "$adu_output" -mindepth 1 -print | /usr/bin/sort)
    adu_status=0
    invoke_parent "$adu_run" "$synthetic_request" "$synthetic_map" "$adu_output" \
      > "$adu_output.stdout" 2> "$adu_output.stderr" || adu_status=$?
    assert_refused_before_fork "$adu_name" "$adu_status" "$adu_output.stdout" "$adu_output.stderr" 'E_RUNTIME output'
    adu_after=$(/usr/bin/find "$adu_output" -mindepth 1 -print | /usr/bin/sort)
    [ "$adu_before" = "$adu_after" ] || fail_case "$adu_name: output tree changed"
  }

  g2out25="$tmp/g2.output-extra-entry"; build_run_directory "$g2out25"
  : > "$g2out25.dest.stray" 2>/dev/null || :
  extra_entry_out="$tmp/g2.output-extra-entry.out"; /bin/mkdir -m 700 "$extra_entry_out"; : > "$extra_entry_out/stray"
  assert_direct_untouched_refusal 'group2: output holds an entry other than .run' "$g2out25/.run" "$extra_entry_out"

  wrongmode_out="$tmp/g2.output-wrongmode.out"; /bin/mkdir -m 750 "$wrongmode_out"
  assert_direct_untouched_refusal 'group2: output mode is not 0700' "$g2out25/.run" "$wrongmode_out"

  decoy_out="$tmp/g2.decoy.out"; /bin/mkdir -m 700 "$decoy_out"; /bin/mkdir -m 700 "$decoy_out/.run"
  assert_direct_untouched_refusal 'group2: .run is not the run directory the parent was handed' "$g2out25/.run" "$decoy_out"

  elsewhere="$tmp/g2.elsewhere"; build_run_directory "$elsewhere"
  linked_out="$tmp/g2.linked.out"; /bin/mkdir -m 700 "$linked_out"; /bin/ln -s "$elsewhere/.run" "$linked_out/.run"
  assert_direct_untouched_refusal 'group2: only entry .run is a symlink to a valid run dir' "$g2out25/.run" "$linked_out"

  regular_out="$tmp/g2.regular.out"; /bin/mkdir -m 700 "$regular_out"; : > "$regular_out/.run"
  assert_direct_untouched_refusal 'group2: only entry .run is a regular file' "$g2out25/.run" "$regular_out"

  # output ownership refusal via a portable test-only translation-unit
  # interposition of fstat (R10): compile the unchanged parent source with
  # fstat renamed to test_fstat by a preprocessor macro on the command
  # line, and link the resulting object against a small test-only wrapper
  # TU -- compiled WITHOUT that macro, so its own call to fstat() reaches
  # the real libc one -- that forwards every call unchanged except for the
  # single fd whose real device/inode match a target path named by an
  # environment variable, where it substitutes a different uid and marks
  # that it was reached. No dlsym/RTLD_NEXT, LD_PRELOAD, DYLD_INSERT_LIBRARIES,
  # shipped switch, environment flag read by the shipped parent, or
  # privilege change is involved, so this compiles and runs identically on
  # Linux and Darwin -- there is no platform skip.
  interpose_wrapper_src="$tmp/g2.interpose-wrapper.c"
  cat > "$interpose_wrapper_src" <<'INTERPOSE'
#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
static dev_t target_dev; static ino_t target_ino; static int have_target = -1;
static const char *marker_path;
static void load_target(void) {
  const char *p = getenv("YSTACK_TEST_INTERPOSE_TARGET");
  marker_path = getenv("YSTACK_TEST_INTERPOSE_MARKER");
  have_target = 0;
  if (!p) return;
  struct stat st;
  if (stat(p, &st) == 0) { target_dev = st.st_dev; target_ino = st.st_ino; have_target = 1; }
}
int test_fstat(int fd, struct stat *buf) {
  if (have_target < 0) load_target();
  int rc = fstat(fd, buf);
  if (rc == 0 && have_target == 1 && buf->st_dev == target_dev && buf->st_ino == target_ino) {
    buf->st_uid = buf->st_uid + 1;
    if (marker_path) {
      int mfd = open(marker_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
      if (mfd >= 0) close(mfd);
    }
  }
  return rc;
}
INTERPOSE

  interpose_wrapper_obj="$tmp/g2.interpose-wrapper.o"
  interpose_parent_obj="$tmp/g2.interpose-parent.o"
  interpose_bin="$tmp/g2.interpose-parent"
  # Isolated TMPDIR/HOME for these three compiles, the same way compile_source
  # scopes the entry's own compiles (build_run_directory) -- otherwise clang's
  # own scratch/cache usage lands in the shared Darwin per-user temp dir and
  # trips the later compiler-pollution snapshot (section 11 below), which
  # expects that directory untouched by anything this suite compiles.
  interpose_build_tmp="$tmp/g2.interpose-build.tmp"; /bin/mkdir -m 700 "$interpose_build_tmp"
  interpose_build_home="$tmp/g2.interpose-build.home"; /bin/mkdir -m 700 "$interpose_build_home"
  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C "TMPDIR=$interpose_build_tmp" "HOME=$interpose_build_home" \
    "$compiler" "${compiler_extra_flags[@]}" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -c -o "$interpose_wrapper_obj" "$interpose_wrapper_src"
  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C "TMPDIR=$interpose_build_tmp" "HOME=$interpose_build_home" \
    "$compiler" "${compiler_extra_flags[@]}" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
    -Dfstat=test_fstat -c -o "$interpose_parent_obj" "$parent_source"
  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C "TMPDIR=$interpose_build_tmp" "HOME=$interpose_build_home" \
    "$compiler" "${compiler_extra_flags[@]}" \
    -o "$interpose_bin" "$interpose_parent_obj" "$interpose_wrapper_obj"

  invoke_interpose_parent() {
    # invoke_interpose_parent RUN REQUEST MAP OUTPUT [RUN_OVERRIDE] -- same
    # argv shape as invoke_parent, against the test-only interposed binary
    # built above instead of the shipped, compiled-by-the-entry one.
    iip_run=$1 iip_request=$2 iip_map=$3 iip_output=$4 iip_run_arg=${5:-$1}
    "$interpose_bin" resolve "$runtime" "$iip_run/nofollow-snapshot" "$iip_run/jq" \
      "$iip_request" "$iip_map" "$iip_output" "$iip_run_arg"
  }

  # Positive control first: the SAME kind of valid run/output pair used below,
  # through the interposed binary but with no target env vars set (so
  # test_fstat never substitutes anything), must succeed -- so the refusal
  # case that follows is attributable to the injected ownership metadata,
  # not to some other defect in the pairing or in this test-only binary.
  own_run_ok="$tmp/g2.ownership-control"; build_run_directory "$own_run_ok"
  own_ok_status=0
  invoke_interpose_parent "$own_run_ok/.run" "$synthetic_request" "$synthetic_map" "$own_run_ok" \
    > "$own_run_ok.stdout" 2> "$own_run_ok.stderr" || own_ok_status=$?
  if [ "$own_ok_status" -eq 0 ]; then
    pass_case 'group2: unmodified-owner positive control succeeds'
  else
    fail_case "group2: unmodified-owner positive control failed (status=$own_ok_status): $(cat "$own_run_ok.stderr" 2>/dev/null)"
  fi

  own_run="$tmp/g2.ownership"; build_run_directory "$own_run"
  own_marker="$tmp/g2.ownership.marker"; /bin/rm -f "$own_marker"
  own_before=$(/usr/bin/find "$own_run" -mindepth 1 -print | /usr/bin/sort)
  own_status=0
  YSTACK_TEST_INTERPOSE_TARGET="$own_run" YSTACK_TEST_INTERPOSE_MARKER="$own_marker" \
    invoke_interpose_parent "$own_run/.run" "$synthetic_request" "$synthetic_map" "$own_run" \
    > "$own_run.stdout" 2> "$own_run.stderr" || own_status=$?
  assert_refused_before_fork 'group2: output ownership refused under injected fstat metadata' \
    "$own_status" "$own_run.stdout" "$own_run.stderr" 'E_RUNTIME output'
  [ -e "$own_marker" ] || fail_case 'group2: injected-ownership refusal -- interposed fstat never matched the output descriptor'
  own_after=$(/usr/bin/find "$own_run" -mindepth 1 -print | /usr/bin/sort)
  [ "$own_before" = "$own_after" ] || fail_case 'group2: injected-ownership refusal left writes behind'
else
  fail_case 'group2: parent-owned refusal cases (trusted-launch.c absent)'
fi

# --- 6. Group 3 -- a runtime refusal, labelled as one (spec.md:7442-7447) ---------------

if [ -x "$entry" ]; then
  bad_request="$tmp/group3.bad-request.json"
  /usr/bin/printf '{' > "$bad_request"
  g3out="$tmp/group3.out"; /bin/mkdir -m 700 "$g3out"
  g3status=0
  "$entry" "$bound_jq" "$g3out" "$bad_request" "$synthetic_map" \
    > "$g3out.stdout" 2> "$g3out.stderr" || g3status=$?
  if [ "$g3status" -ne 0 ] && /usr/bin/grep -q '^E_PARSE' "$g3out.stderr"; then
    pass_case 'group3: malformed request document is a runtime refusal, not an R5 case'
  else
    fail_case 'group3: malformed request document'
  fi
else
  fail_case 'group3: malformed request document (entry absent)'
fi

# --- 7. R3 no-copy invariant (spec.md:7449-7494) -----------------------------------------

# Provisioned here (rather than down at section 8's loader-variable case, which is its
# only other consumer) so the Linux branch of the pre-resolver-helper pollution case
# below can exercise the direct-parent invocation with the same marker library, instead
# of skipping that boundary and relying solely on the later entry-level loader case
# (which already scrubs the environment before the parent ever starts).
marker_lib_src="$tmp/marker-lib.c"
cat > "$marker_lib_src" <<'MARKERLIB'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
__attribute__((constructor))
static void ystack_marker_ctor(void) {
  const char *path = getenv("YSTACK_TEST_MARKER_FILE");
  if (!path) return;
  FILE *f = fopen(path, "a");
  if (!f) return;
  fprintf(f, "argv0=? pid=%ld\n", (long)getpid());
  fclose(f);
}
MARKERLIB
case "$platform" in
  Darwin:*) marker_lib="$tmp/marker-lib.dylib"
    /usr/bin/cc -std=c11 -Wall -Wextra -O2 -dynamiclib "$marker_lib_src" -o "$marker_lib" ;;
  *) marker_lib="$tmp/marker-lib.so"
    /usr/bin/cc -std=c11 -Wall -Wextra -O2 -fPIC -shared "$marker_lib_src" -o "$marker_lib" ;;
esac

if [ "$parent_available" -eq 1 ]; then
  # R5's output-directory check requires argv[7] (output root) to contain
  # *exactly* {".run"} and be the same object (st_dev/st_ino) as argv[8] (the run
  # directory) -- so a genuine SUCCESS run, unlike a before-fork refusal, needs
  # OUTPUT to be the directory that directly contains .run. A prior draft pointed
  # OUTPUT at a separate empty directory, so every "clean" call refused at the
  # output check (E_RUNTIME output) and the uncaptured status took the suite down
  # under set -e. Each invocation below gets its own build_run_directory output.
  r3_clean_out="$tmp/r3.clean"; build_run_directory "$r3_clean_out"
  invoke_parent "$r3_clean_out/.run" "$synthetic_request" "$synthetic_map" "$r3_clean_out" \
    > "$r3_clean_out.stdout" 2> "$r3_clean_out.stderr"

  r3_caller_out="$tmp/r3.caller-pollution"; build_run_directory "$r3_caller_out"
  decoy_bin="$tmp/r3.decoy-bin"; /bin/mkdir -m 700 "$decoy_bin"
  marker_script="$tmp/r3.marker.sh"; /usr/bin/printf '#!/bin/sh\nexit 0\n' > "$marker_script"; /bin/chmod 0555 "$marker_script"
  FOO=bar BASH_ENV="$marker_script" ENV="$marker_script" PATH="$decoy_bin:/usr/bin:/bin" \
    YSTACK_RESOLVER_TEST_GIT_WALL_SECONDS=1 YSTACK_RESOLVER_TEST_GIT_STOP=1 \
    invoke_parent "$r3_caller_out/.run" "$synthetic_request" "$synthetic_map" "$r3_caller_out" \
    > "$r3_caller_out.stdout" 2> "$r3_caller_out.stderr"
  if /usr/bin/cmp -s "$r3_clean_out.stdout" "$r3_caller_out.stdout"; then
    pass_case 'R3: caller-environment pollution does not reach the resolver'
  else
    fail_case 'R3: caller-environment pollution leaked into stdout'
  fi

  # pollution of variables the parent's own pre-resolver helpers read
  case "$platform" in
    Darwin:*)
      perl_dir="$tmp/r3.perl"; /bin/mkdir -m 700 "$perl_dir"
      cat > "$perl_dir/strict.pm" <<'PERLMOD'
package strict;
print STDERR "YSTACK-PERL-MARKER\n";
exit 3;
PERLMOD
      r3_perl_status=0
      PERL5LIB="$perl_dir" PERL5OPT=-Mstrict /usr/bin/shasum -a 1 /dev/null \
        > "$tmp/r3.perlcontrol.stdout" 2> "$tmp/r3.perlcontrol.stderr" || r3_perl_status=$?
      if ! { [ "$r3_perl_status" -eq 3 ] && /usr/bin/grep -q YSTACK-PERL-MARKER "$tmp/r3.perlcontrol.stderr"; }; then
        fail_case 'R3: perl-pollution negative control did not fire on this machine'
      fi
      r3_perl_out="$tmp/r3.perl-pollution"; build_run_directory "$r3_perl_out"
      r3_perl_run_status=0
      PERL5LIB="$perl_dir" PERL5OPT=-Mstrict \
        invoke_parent "$r3_perl_out/.run" "$synthetic_request" "$synthetic_map" "$r3_perl_out" \
        > "$r3_perl_out.stdout" 2> "$r3_perl_out.stderr" || r3_perl_run_status=$?
      # A successful run's stderr is never empty -- it always carries the parent's own
      # "runtime-pgid: <pid>" line (see assert_refused_before_fork's converse assertion,
      # which requires that line ABSENT only on a refusal) -- so requiring
      # "[ ! -s ... ]" here, as a prior draft did, would fail every genuinely clean run
      # and made this case indistinguishable from an actual regression. What proves the
      # pollution didn't reach the parent's own SHA tool is the matching stdout, the
      # completed (not early-refused) run, and the marker's total absence.
      if [ "$r3_perl_run_status" -eq 0 ] && /usr/bin/grep -q '^runtime-pgid:' "$r3_perl_out.stderr" &&
         /usr/bin/cmp -s "$r3_clean_out.stdout" "$r3_perl_out.stdout" &&
         ! /usr/bin/grep -q YSTACK-PERL-MARKER "$r3_perl_out.stdout" "$r3_perl_out.stderr" 2>/dev/null; then
        pass_case 'R3: PERL5LIB/PERL5OPT pollution does not reach the parent''s own SHA tool'
      else
        fail_case 'R3: perl-variable pollution'
      fi

      # Darwin equivalent of the Linux LD_PRELOAD-marker case below: exercise the
      # PARENT directly with DYLD_INSERT_LIBRARIES/DYLD_LIBRARY_PATH pollution. Use a
      # locally-compiled, unsigned control binary rather than a system one (e.g.
      # /usr/bin/true) for the negative control -- SIP strips DYLD_* from system
      # binaries' environments unconditionally, which would make the control fire
      # (or not) for reasons unrelated to whether our own, locally-built,
      # non-system-path parent binary respects it.
      r3_dyld_control_src="$tmp/r3.dyld-control.c"
      /usr/bin/printf 'int main(void){return 0;}\n' > "$r3_dyld_control_src"
      r3_dyld_control_bin="$tmp/r3.dyld-control"
      /usr/bin/cc -std=c11 -Wall -Wextra -O2 "$r3_dyld_control_src" -o "$r3_dyld_control_bin"
      r3_dyld_control_marker="$tmp/r3.dyld-control.marker"
      DYLD_INSERT_LIBRARIES="$marker_lib" DYLD_LIBRARY_PATH="$tmp" \
        YSTACK_TEST_MARKER_FILE="$r3_dyld_control_marker" "$r3_dyld_control_bin" 2>/dev/null || :
      if [ ! -f "$r3_dyld_control_marker" ]; then
        skip_case 'R3: DYLD_INSERT_LIBRARIES-marker pollution of the parent'\''s own helpers' \
          'DYLD_INSERT_LIBRARIES did not reach even a locally-built, unsigned control binary on this machine (unexpected -- check SIP/library-validation settings); the Linux LD_PRELOAD-marker case above exercises the same boundary'
      else
        r3_dyld_out="$tmp/r3.dyld-pollution"; build_run_directory "$r3_dyld_out"
        r3_dyld_marker="$tmp/r3.dyld-pollution.marker"
        DYLD_INSERT_LIBRARIES="$marker_lib" DYLD_LIBRARY_PATH="$tmp" YSTACK_TEST_MARKER_FILE="$r3_dyld_marker" \
          invoke_parent_exec "$r3_dyld_out/.run" "$synthetic_request" "$synthetic_map" "$r3_dyld_out" \
          > "$r3_dyld_out.stdout" 2> "$r3_dyld_out.stderr" &
        r3_dyld_pid=$!
        r3_dyld_status=0
        wait "$r3_dyld_pid" 2>/dev/null || r3_dyld_status=$?
        r3_dyld_bad_children=0
        if [ -f "$r3_dyld_marker" ]; then
          /usr/bin/grep -qv "pid=$r3_dyld_pid\$" "$r3_dyld_marker" && r3_dyld_bad_children=1
        fi
        if [ "$r3_dyld_status" -eq 0 ] && /usr/bin/cmp -s "$r3_clean_out.stdout" "$r3_dyld_out.stdout" &&
           [ "$r3_dyld_bad_children" -eq 0 ]; then
          pass_case 'R3: DYLD_INSERT_LIBRARIES-marker pollution of the parent'\''s own helpers is discarded before its SHA/jq children'
        else
          fail_case 'R3: DYLD_INSERT_LIBRARIES-marker pollution reached the parent'\''s helper children'
        fi
      fi
      ;;
    Linux:x86_64)
      # Exercise the PARENT directly (not through $entry, which already clears the
      # environment before the parent ever starts and so cannot prove anything about
      # the parent's own children). LD_PRELOAD is inherited by the dynamic loader that
      # brings up trusted-launch's own process image -- that one marker hit is
      # unavoidable and expected -- so the assertion is that no *other* process picks
      # it up: the parent's SHA (nofollow-snapshot) and jq children must not inherit it.
      r3_ld_control_marker="$tmp/r3.ld-control.marker"
      LD_PRELOAD="$marker_lib" LD_LIBRARY_PATH="$tmp" YSTACK_TEST_MARKER_FILE="$r3_ld_control_marker" \
        /bin/true 2>/dev/null || :
      if [ ! -f "$r3_ld_control_marker" ]; then
        fail_case 'R3: LD_PRELOAD-marker negative control did not fire on this machine'
      fi
      r3_ld_out="$tmp/r3.ld-pollution"; build_run_directory "$r3_ld_out"
      r3_ld_marker="$tmp/r3.ld-pollution.marker"
      LD_PRELOAD="$marker_lib" LD_LIBRARY_PATH="$tmp" YSTACK_TEST_MARKER_FILE="$r3_ld_marker" \
        invoke_parent_exec "$r3_ld_out/.run" "$synthetic_request" "$synthetic_map" "$r3_ld_out" \
        > "$r3_ld_out.stdout" 2> "$r3_ld_out.stderr" &
      r3_ld_pid=$!
      r3_ld_status=0
      wait "$r3_ld_pid" 2>/dev/null || r3_ld_status=$?
      r3_ld_bad_children=0
      if [ -f "$r3_ld_marker" ]; then
        # Every recorded pid must be the direct-parent process itself (its own
        # unavoidable load-time hit); any other pid means a forked child inherited
        # the pollution.
        /usr/bin/grep -qv "pid=$r3_ld_pid\$" "$r3_ld_marker" && r3_ld_bad_children=1
      fi
      if [ "$r3_ld_status" -eq 0 ] && /usr/bin/cmp -s "$r3_clean_out.stdout" "$r3_ld_out.stdout" &&
         [ "$r3_ld_bad_children" -eq 0 ]; then
        pass_case 'R3: LD_PRELOAD-marker pollution of the parent'\''s own helpers is discarded before its SHA/jq children'
      else
        fail_case 'R3: LD_PRELOAD-marker pollution reached the parent'\''s helper children'
      fi
      ;;
  esac
else
  fail_case 'R3: no-copy invariant cases (parent absent)'
fi

# --- 8. Loader-variable case (spec.md:7495-7524) -----------------------------------------

# marker_lib is provisioned back in section 7, alongside its first consumer (the
# Linux direct-parent helper-pollution case).

if [ -x "$entry" ]; then
  marker_file="$tmp/loader.marker"
  loader_clean_out="$tmp/loader.clean"; /bin/mkdir -m 700 "$loader_clean_out"
  "$entry" "$bound_jq" "$loader_clean_out" "$synthetic_request" "$synthetic_map" \
    > "$loader_clean_out.stdout" 2> "$loader_clean_out.stderr"
  loader_polluted_out="$tmp/loader.polluted"; /bin/mkdir -m 700 "$loader_polluted_out"
  LD_PRELOAD="$marker_lib" LD_LIBRARY_PATH="$tmp" \
    DYLD_INSERT_LIBRARIES="$marker_lib" DYLD_LIBRARY_PATH="$tmp" \
    YSTACK_TEST_MARKER_FILE="$marker_file" \
    "$entry" "$bound_jq" "$loader_polluted_out" "$synthetic_request" "$synthetic_map" \
    > "$loader_polluted_out.stdout" 2> "$loader_polluted_out.stderr"
  /usr/bin/cmp -s "$loader_clean_out.stdout" "$loader_polluted_out.stdout" ||
    fail_case 'loader: LD_PRELOAD/DYLD_INSERT_LIBRARIES pollution changed stdout'
  loader_lines=0
  [ -f "$marker_file" ] && loader_lines=$(/usr/bin/wc -l < "$marker_file" | /usr/bin/awk '{print $1}')
  [ "$loader_lines" -le 1 ] ||
    fail_case "loader: marker file holds $loader_lines lines (expected at most one, the caller's own /bin/bash)"
  pass_case 'loader: LD_PRELOAD/DYLD_INSERT_LIBRARIES pollution is bounded to the entry'\''s own first process'
else
  fail_case 'loader: LD_PRELOAD/DYLD_INSERT_LIBRARIES case (entry absent)'
fi

read_runtime_pgid() {
  # read_runtime_pgid STDERR_FILE -> prints pgid or empty after a bounded poll
  rrp_file=$1
  rrp_deadline=$(( $(/bin/date +%s) + 30 ))
  while :; do
    rrp_line=$(/usr/bin/grep -m1 -E '^runtime-pgid: [0-9]+$' "$rrp_file" 2>/dev/null || :)
    [ -n "$rrp_line" ] && { printf '%s\n' "${rrp_line#runtime-pgid: }"; return; }
    [ "$(/bin/date +%s)" -lt "$rrp_deadline" ] || { echo ''; return; }
    /bin/sleep 0.01
  done
}

# Runtime-environment allowlist assertion (spec.md:7495, plan.md's "Check exact Linux
# runtime environment and R10's Darwin alternative"): the resolver runtime must run
# under exactly the eight fixed names trusted-launch.c's child_env builds (HOME, TMPDIR,
# LC_ALL, PATH, YSTACK_RESOLVER_TRUSTED, YSTACK_RESOLVER_HELPER, YSTACK_RESOLVER_JQ,
# GIT_TERMINAL_PROMPT), plus MallocNanoZone on Darwin -- never the caller's own
# environment, and never a superset (the loader-marker case above already proves no
# *values* leak through; this proves no *names* do either).
runtime_env_expected='GIT_TERMINAL_PROMPT
HOME
LC_ALL
PATH
TMPDIR
YSTACK_RESOLVER_HELPER
YSTACK_RESOLVER_JQ
YSTACK_RESOLVER_TRUSTED'

case "$platform" in
  Linux:x86_64)
    if [ -x "$entry" ]; then
      # /proc/<pid>/environ, on the real pinned entry -> parent -> runtime chain: the
      # most direct reading of the actual shipped runtime's actual environment. The
      # runtime is short-lived, so the pgid (which is also its own pid, per the
      # "runtime-pgid:" diagnostic) is read as soon as it is published and /proc is
      # polled immediately and repeatedly for a bounded window rather than once.
      renv_out="$tmp/runtime-env.linux.out"; /bin/mkdir -m 700 "$renv_out"
      renv_stderr="$tmp/runtime-env.linux.stderr"; : > "$renv_stderr"
      set -m
      "$entry" "$bound_jq" "$renv_out" "$real_request" "$real_map" \
        > "$tmp/runtime-env.linux.stdout" 2> "$renv_stderr" &
      renv_pid=$!
      renv_pgid=$(read_runtime_pgid "$renv_stderr")
      renv_names=''
      if [ -n "$renv_pgid" ]; then
        renv_deadline=$(( $(/bin/date +%s) + 5 ))
        while [ -z "$renv_names" ] && [ "$(/bin/date +%s)" -lt "$renv_deadline" ]; do
          renv_names=$(/usr/bin/tr '\0' '\n' < "/proc/$renv_pgid/environ" 2>/dev/null |
            /usr/bin/grep -v '^$' | /usr/bin/cut -d= -f1 | LC_ALL=C /usr/bin/sort || :)
        done
      fi
      wait "$renv_pid" 2>/dev/null || :
      set +m
      if [ -n "$renv_names" ] && [ "$renv_names" = "$runtime_env_expected" ]; then
        pass_case 'mechanism: resolver runtime (Linux, /proc/<pid>/environ) runs under exactly R3''s fixed environment names'
      else
        fail_case "mechanism: resolver runtime environment names (Linux): $(printf '%s' "$renv_names" | /usr/bin/tr '\n' ' ')"
      fi
    else
      fail_case 'mechanism: runtime-environment allowlist (Linux, entry absent)'
    fi
    ;;
  Darwin:*)
    # R10's Darwin alternative -- a source-order proof in place of the Linux
    # case's observed-behavior one (the same observed/source-order split
    # plan.md draws for the cleanup cases): Darwin has no /proc, and reading
    # another process's real environ needs root, which this suite must not
    # require (confirmed locally: "ps eww" prints no environment for a
    # same-user, non-root process on this OS version any more). trusted-launch
    # itself DOES pin the runtime script's own identity (repo_root_from_runtime
    # plus its SHA-1 against the R5 pin set), so -- unlike group 2's other
    # direct-invocation fixtures -- a stand-in runtime cannot be substituted
    # for it either. What IS directly readable is the shipped source: every
    # name child_env is ever assigned, between its first assignment and the
    # NULL-termination/no-NULL-hole check, read verbatim out of
    # trusted-launch.c. This is the exact set R7 fixes execve's envp to, by
    # construction (there is no other path into child_env), so a name-for-name
    # match against R3's expected set is the direct Darwin equivalent of the
    # Linux case's /proc reading, not a weaker proxy for it.
    if [ -f "$parent_source" ]; then
      renv_src_names=$(/usr/bin/sed -n '/child_env\[0\] = environment_value/,/child_env\[child_env_count\] = NULL;/p' "$parent_source" |
        /usr/bin/grep -oE '(environment_value\("[A-Za-z_][A-Za-z0-9_]*"|strdup\("[A-Za-z_][A-Za-z0-9_]*=)' |
        /usr/bin/sed -E 's/^environment_value\("//; s/^strdup\("//; s/"$//; s/=$//' |
        LC_ALL=C /usr/bin/sort -u)
      renv_expected_darwin=$(printf '%s\nMallocNanoZone\n' "$runtime_env_expected" | LC_ALL=C /usr/bin/sort)
      if [ -n "$renv_src_names" ] && [ "$renv_src_names" = "$renv_expected_darwin" ]; then
        pass_case 'mechanism: trusted-launch.c assigns exactly R3''s fixed environment names into child_env (Darwin source-order proof)'
      else
        fail_case "mechanism: resolver runtime environment names (Darwin, source-order): $(printf '%s' "$renv_src_names" | /usr/bin/tr '\n' ' ')"
      fi
    else
      fail_case 'mechanism: runtime-environment allowlist (Darwin, trusted-launch.c absent)'
    fi
    ;;
esac

# --- 9. Forged clean-marker invocation, two halves (spec.md R1 marker branch; spec.md:7566ish) --

if [ -x "$entry" ]; then
  # unsupported half: no -p, clean environment, must refuse with exit 78 and touch nothing
  marker_out="$tmp/marker.unsupported"; /bin/mkdir -m 700 "$marker_out"
  marker_status=0
  /bin/bash "$entry" __resolve_profile_clean "$bound_jq" "$marker_out" \
    "$synthetic_request" "$synthetic_map" > "$marker_out.stdout" 2> "$marker_out.stderr" || marker_status=$?
  if [ "$marker_status" -eq 78 ] && [ -z "$(/usr/bin/find "$marker_out" -mindepth 1 -print)" ]; then
    pass_case 'marker branch: unsupported clean arrival without -p exits 78 and touches nothing'
  else
    fail_case 'marker branch: unsupported clean arrival'
  fi

  # supported half: -p, polluted with shadowing functions and BASH_ENV
  marker_sup_out="$tmp/marker.supported"; /bin/mkdir -m 700 "$marker_sup_out"
  hijack_marker="$tmp/marker.hijack"
  bash_env_script="$tmp/marker.bashenv.sh"
  /usr/bin/printf 'alias ls=true\n' > "$bash_env_script"
  marker_sup_status=0
  # shellcheck disable=SC2329  # invoked indirectly: exported and called by the entry
  # (a separate process) via the builtins they shadow, which shellcheck cannot see across.
  ( pwd() { : > "$hijack_marker"; command pwd; }
    cd() { : > "$hijack_marker"; command cd "$@"; }
    find() { : > "$hijack_marker"; command find "$@"; }
    export -f pwd cd find
    BASH_ENV="$bash_env_script" FOO=bar \
      /bin/bash -p "$entry" __resolve_profile_clean "$bound_jq" "$marker_sup_out" \
      "$synthetic_request" "$synthetic_map"
  ) > "$marker_sup_out.stdout" 2> "$marker_sup_out.stderr" || marker_sup_status=$?
  if [ "$marker_sup_status" -eq 0 ] && [ ! -e "$hijack_marker" ]; then
    pass_case 'marker branch: supported -p arrival ignores hijacked cd/pwd/find and BASH_ENV'
  else
    fail_case 'marker branch: supported -p arrival'
  fi
else
  fail_case 'marker branch cases (entry absent)'
fi

# --- 10. Committed mode of the entry (spec.md:7566-7580) --------------------------------

entry_ls=$(cd "$root" && /usr/bin/git ls-files -s -- resolver/v1/resolve-profile.sh)
if [ -z "$entry_ls" ]; then
  fail_case 'entry mode: resolver/v1/resolve-profile.sh is not tracked'
else
  entry_mode=${entry_ls%% *}
  [ "$entry_mode" = 100755 ] || fail_case "entry mode: git ls-files reports $entry_mode, expected 100755"
  [ -x "$entry" ] || fail_case 'entry mode: checked-out file is not executable'
  pass_case 'entry mode: committed 100755 and checked-out executable'
fi

# relative repo-root invocation
if [ -x "$entry" ]; then
  rel_out="$tmp/relative.out"; /bin/mkdir -m 700 "$rel_out"
  ( cd "$root" && ./resolver/v1/resolve-profile.sh "$bound_jq" "$rel_out" \
      "$synthetic_request" "$synthetic_map" > "$rel_out.stdout" 2> "$rel_out.stderr" )
  rel_after=$(/usr/bin/find "$rel_out" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | /usr/bin/sort || \
              /usr/bin/find "$rel_out" -mindepth 1 -maxdepth 1 | /usr/bin/xargs -n1 basename | /usr/bin/sort)
  if [ "$rel_after" = "$(printf 'child.stderr\nchild.stdout\nhome\ntmp\n')" ]; then
    pass_case 'entry mode: relative repo-root invocation produces the standard sandbox set'
  else
    fail_case 'entry mode: relative invocation'
  fi
else
  fail_case 'entry mode: relative invocation (entry absent)'
fi

# --- 11. Compiler-environment pollution, two halves (spec.md:7608-7710) -----------------

if [ -x "$entry" ]; then
  poison_dir="$tmp/poison"; /bin/mkdir -m 700 "$poison_dir"
  cat > "$poison_dir/stdio.h" <<'POISON'
#error YSTACK-POISONED-STDIO-H-INCLUDED
POISON
  compiler_poll_out="$tmp/compiler.poll"; /bin/mkdir -m 700 "$compiler_poll_out"
  watched_tmp="$tmp/compiler.watched-tmp"; /bin/mkdir -m 700 "$watched_tmp"
  watched_home="$tmp/compiler.watched-home"; /bin/mkdir -m 700 "$watched_home"

  compiler_clean_out="$tmp/compiler.clean"; /bin/mkdir -m 700 "$compiler_clean_out"
  "$entry" "$bound_jq" "$compiler_clean_out" "$synthetic_request" "$synthetic_map" \
    > "$compiler_clean_out.stdout" 2> "$compiler_clean_out.stderr"

  CC=/nonexistent/cc CPATH="$poison_dir" C_INCLUDE_PATH="$poison_dir" LIBRARY_PATH="$poison_dir" \
    SDKROOT=/nonexistent/sdk DEVELOPER_DIR=/nonexistent/dev MACOSX_DEPLOYMENT_TARGET=1.0 \
    TMPDIR="$watched_tmp" HOME="$watched_home" \
    "$entry" "$bound_jq" "$compiler_poll_out" "$synthetic_request" "$synthetic_map" \
    > "$compiler_poll_out.stdout" 2> "$compiler_poll_out.stderr" || :
  if /usr/bin/cmp -s "$compiler_clean_out.stdout" "$compiler_poll_out.stdout" &&
     ! /usr/bin/grep -q YSTACK-POISONED "$compiler_poll_out.stdout" "$compiler_poll_out.stderr" 2>/dev/null &&
     [ -z "$(/usr/bin/find "$watched_tmp" -mindepth 1 -print)" ] &&
     [ -z "$(/usr/bin/find "$watched_home" -mindepth 1 -print)" ]; then
    pass_case 'compiler pollution: entry run is unaffected and watched TMPDIR/HOME stay untouched'
  else
    fail_case 'compiler pollution: entry-driven half'
  fi

  # darwin_snapshot DIR -> "name size mtime" triples for every top-level
  # entry, sorted by name, plus xcrun_db's own state anywhere under DIR
  # ("absent", or "path size mtime sha1" per match) so an in-place same-
  # size, same-second rewrite of its content still shows up. $tmp is rooted
  # under /private/tmp (see its mktemp above), not under DIR, so no entry
  # here is this suite's own scratch; no exemption of any kind is applied.
  darwin_snapshot() {
    ds_dir=$1
    /usr/bin/find "$ds_dir" -maxdepth 1 -mindepth 1 \
      -exec /usr/bin/stat -f '%N %z %m' {} \; 2>/dev/null | /usr/bin/sort
    xdb_hits=$(/usr/bin/find "$ds_dir" -name xcrun_db 2>/dev/null | /usr/bin/sort)
    if [ -z "$xdb_hits" ]; then
      printf 'xcrun_db absent\n'
    else
      while IFS= read -r xdb; do
        printf '%s %s\n' "$(/usr/bin/stat -f '%N %z %m' "$xdb")" \
          "$(/usr/bin/shasum -a 1 "$xdb" | /usr/bin/awk '{print $1}')"
      done <<< "$xdb_hits"
    fi
  }

  # Compare two darwin_snapshot outputs. Equal -> pass. Any difference
  # fails outright (AGENTS.md:34-36 -- no skipped failures): a changed
  # entry, TemporaryItems included, is a failed observation for the
  # operator to rerun, never a silent pass.
  darwin_snapshot_check() {
    local before=$1 after=$2 pass_msg=$3 fail_msg=$4
    if [ "$before" = "$after" ]; then
      pass_case "$pass_msg"; return
    fi
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | /usr/bin/grep -E '^[<>]' >&2 || :
    fail_case "$fail_msg"
  }

  case "$platform" in
    Darwin:*)
      darwin_temp=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)
      before_listing=$(darwin_snapshot "$darwin_temp")
      darwin_run_out="$tmp/compiler.darwin-run"; /bin/mkdir -m 700 "$darwin_run_out"
      "$entry" "$bound_jq" "$darwin_run_out" "$synthetic_request" "$synthetic_map" \
        > "$darwin_run_out.stdout" 2> "$darwin_run_out.stderr"
      after_listing=$(darwin_snapshot "$darwin_temp")
      darwin_snapshot_check "$before_listing" "$after_listing" \
        'compiler pollution (Darwin, operator-run): nothing under the per-user temp dir changes name, size, mtime, or xcrun_db content (no cache-write exemption)' \
        'compiler pollution: Darwin per-user temp dir changed (name/size/mtime/xcrun_db snapshot mismatch)'
      ;;
    Linux:x86_64)
      skip_case 'compiler pollution: Darwin xcrun_db delta measurement' 'Linux has no such shim or cache file'
      ;;
  esac

  # half 2: group-2 style, binaries compared directly, no runtime behind the compiles
  case "$platform" in
    Darwin:*)
      # Same basename in two separate directories, not "compiler.clean.bin"
      # vs "compiler.polluted.bin": on arm64, CommandLineTools' ad-hoc
      # linker signature embeds the OUTPUT BASENAME as the code-signing
      # identifier, so two differently-named outputs produce different
      # bytes (a 351-byte delta covering the embedded CodeDirectory and
      # LC_UUID) even when compiled from byte-identical sources with
      # identical flags -- a false "nondeterminism" that has nothing to do
      # with the poisoned-environment fixture under test. Using the same
      # basename in each of the two directories keeps that identifier
      # identical and isolates the comparison to what compiler-environment
      # pollution can actually change.
      clean_dir="$tmp/compiler.clean.d"; /bin/mkdir -m 700 "$clean_dir"
      clean_bin="$clean_dir/trusted-launch"
      darwin_temp2=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)
      before2=$(darwin_snapshot "$darwin_temp2")
      compile_source "$parent_source" "$clean_bin" "TMPDIR=$tmp" "HOME=$tmp"
      mid2=$(darwin_snapshot "$darwin_temp2")
      polluted_dir="$tmp/compiler.polluted.d"; /bin/mkdir -m 700 "$polluted_dir"
      polluted_bin="$polluted_dir/trusted-launch"
      CC=/nonexistent/cc CPATH="$poison_dir" C_INCLUDE_PATH="$poison_dir" LIBRARY_PATH="$poison_dir" \
        SDKROOT=/nonexistent/sdk DEVELOPER_DIR=/nonexistent/dev MACOSX_DEPLOYMENT_TARGET=1.0 \
        compile_source "$parent_source" "$polluted_bin" "TMPDIR=$tmp" "HOME=$tmp"
      after2=$(darwin_snapshot "$darwin_temp2")
      # No cache-write exemption for the isolated compile/pin path either (plan:
      # PR #328 removed the residual): both the clean and the polluted compile
      # must leave every entry under the per-user temp dir -- xcrun_db included
      # -- with its name, size, and mtime unchanged.
      darwin_snapshot_check "$before2" "$mid2" \
        'compiler pollution (Darwin): per-user temp dir unchanged across the clean isolated compile' \
        'compiler pollution (Darwin): per-user temp dir changed across the clean isolated compile'
      darwin_snapshot_check "$mid2" "$after2" \
        'compiler pollution (Darwin): per-user temp dir unchanged across the polluted isolated compile' \
        'compiler pollution (Darwin): per-user temp dir changed across the polluted isolated compile'
      if [ "$(sha256_file "$clean_bin")" = "$(sha256_file "$polluted_bin")" ]; then
        pass_case 'compiler pollution: clean and polluted compiles produce byte-identical binaries'
      else
        # The current accepted plan selects byte-identical outputs and accepts no
        # nondeterminism relaxation (R10's finding on this exact case): a prior
        # draft converted a digest mismatch into a skip on the theory that
        # CommandLineTools clang/ld64 embeds a fresh random Mach-O LC_UUID on
        # every link. That theory is not a substitute for the plan's own text,
        # which requires byte-identical outputs unless a *separately accepted*
        # plan amendment defines and validates a narrower comparison -- no such
        # amendment exists, so a differing digest is a failure, not a skip.
        fail_case 'compiler pollution: clean and polluted compiles produce different binaries (byte-identical output required; no nondeterminism relaxation accepted without a plan amendment)'
      fi
      unpoisoned_control="$tmp/compiler.control.bin"
      control_status=0
      CC=/nonexistent/cc CPATH="$poison_dir" C_INCLUDE_PATH="$poison_dir" LIBRARY_PATH="$poison_dir" \
        SDKROOT=/nonexistent/sdk DEVELOPER_DIR=/nonexistent/dev MACOSX_DEPLOYMENT_TARGET=1.0 \
        "$compiler" "${compiler_extra_flags[@]}" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
        -o "$unpoisoned_control" "$parent_source" 2> "$tmp/compiler.control.stderr" || control_status=$?
      [ "$control_status" -ne 0 ] || /usr/bin/grep -qi poisoned "$tmp/compiler.control.stderr" ||
        fail_case 'compiler pollution: control compile without env -i did not prove the fixture poisonous'
      ;;
    Linux:x86_64)
      clean_bin2="$tmp/compiler.clean2.bin"
      polluted_bin2="$tmp/compiler.polluted2.bin"
      compile_source "$parent_source" "$clean_bin2" "TMPDIR=$tmp" "HOME=$tmp"
      CC=/nonexistent/cc CPATH="$poison_dir" C_INCLUDE_PATH="$poison_dir" LIBRARY_PATH="$poison_dir" \
        compile_source "$parent_source" "$polluted_bin2" "TMPDIR=$tmp" "HOME=$tmp"
      if [ "$(sha256_file "$clean_bin2")" = "$(sha256_file "$polluted_bin2")" ]; then
        pass_case 'compiler pollution: clean and polluted compiles produce byte-identical binaries (Linux)'
      else
        fail_case 'compiler pollution: binary comparison (Linux)'
      fi
      ;;
  esac
else
  fail_case 'compiler-environment pollution cases (entry absent)'
fi

# --- 12. Cleanup cases (spec.md:7716-7764) ------------------------------------------------
# Case 1 (success) and case 4 (runtime refusal) are new; cases 2 and 3 are the
# wrong-digest-jq and runtime-mode-0755 refusals already asserted above (group 1 / group 2).

if [ -x "$entry" ]; then
  clean_out="$tmp/cleanup.success"; /bin/mkdir -m 700 "$clean_out"
  clean_status=0
  "$entry" "$bound_jq" "$clean_out" "$synthetic_request" "$synthetic_map" \
    > "$clean_out.stdout" 2> "$clean_out.stderr" || clean_status=$?
  [ "$clean_status" -eq 0 ] || fail_case 'cleanup case 1: entry did not exit 0'
  clean_entries=$(cd "$clean_out" && /usr/bin/find . -mindepth 1 -maxdepth 1 | /usr/bin/sort)
  expected_entries=$(printf './child.stderr\n./child.stdout\n./home\n./tmp\n')
  [ "$clean_entries" = "$expected_entries" ] || fail_case "cleanup case 1: unexpected entry set: $clean_entries"
  /usr/bin/cmp -s "$clean_out.stdout" "$clean_out/child.stdout" || fail_case 'cleanup case 1: child.stdout does not match entry stdout'
  [ ! -s "$clean_out/child.stderr" ] || fail_case 'cleanup case 1: child.stderr not empty'
  [ -z "$(/usr/bin/find "$clean_out/tmp" -mindepth 1 -print)" ] || fail_case 'cleanup case 1: tmp not empty'
  pass_case 'cleanup case 1: successful resolution leaves exactly the parent sandbox behind'

  malformed_cleanup_out="$tmp/cleanup.runtime-refusal"; /bin/mkdir -m 700 "$malformed_cleanup_out"
  bad_req2="$tmp/cleanup.bad-request.json"; /usr/bin/printf '{' > "$bad_req2"
  mc_status=0
  "$entry" "$bound_jq" "$malformed_cleanup_out" "$bad_req2" "$synthetic_map" \
    > "$malformed_cleanup_out.stdout" 2> "$malformed_cleanup_out.stderr" || mc_status=$?
  [ "$mc_status" -ne 0 ] || fail_case 'cleanup case 4: expected non-zero exit'
  mc_entries=$(cd "$malformed_cleanup_out" && /usr/bin/find . -mindepth 1 -maxdepth 1 | /usr/bin/sort)
  [ "$mc_entries" = "$expected_entries" ] || fail_case "cleanup case 4: unexpected entry set: $mc_entries"
  [ -s "$malformed_cleanup_out/child.stderr" ] || fail_case 'cleanup case 4: child.stderr empty on runtime refusal'
  [ ! -s "$malformed_cleanup_out/child.stdout" ] || fail_case 'cleanup case 4: child.stdout not empty on runtime refusal'
  [ -z "$(/usr/bin/find "$malformed_cleanup_out/tmp" -mindepth 1 -print)" ] || fail_case 'cleanup case 4: tmp not empty'
  pass_case 'cleanup case 4: a runtime refusal still leaves the parent sandbox and removes .run'

  # Cleanup case 3 (spec.md:7733-7740) through the ENTRY (R11): the group-2 0755
  # runtime-mode case above invokes trusted-launch directly, never the entry's own
  # EXIT trap / .run removal. Reuse copy_repo_tree, chmod the copy's runtime to 0755.
  c3_tree="$tmp/cleanup.case3-tree"; copy_repo_tree "$c3_tree"
  /bin/chmod 0755 "$c3_tree/resolver/v1/profile-resolve-runtime.sh"
  c3_entry="$c3_tree/resolver/v1/resolve-profile.sh"
  c3_out="$tmp/cleanup.case3"; /bin/mkdir -m 700 "$c3_out"
  c3_status=0
  "$c3_entry" "$bound_jq" "$c3_out" "$synthetic_request" "$synthetic_map" \
    > "$c3_out.stdout" 2> "$c3_out.stderr" || c3_status=$?
  [ "$c3_status" -ne 0 ] || fail_case 'cleanup case 3 (entry): expected non-zero exit'
  /usr/bin/grep -qF 'E_RUNTIME binding' "$c3_out.stderr" ||
    fail_case "cleanup case 3 (entry): expected E_RUNTIME binding, got: $(/usr/bin/tail -c 500 "$c3_out.stderr")"
  c3_leftover=$(cd "$c3_out" && /usr/bin/find . -mindepth 1)
  [ -z "$c3_leftover" ] || fail_case "cleanup case 3 (entry): output dir not empty: $c3_leftover"
  pass_case 'cleanup case 3: entry refuses a 0755 runtime script through its own EXIT trap, output dir left empty'
else
  fail_case 'cleanup cases 1, 3 and 4 (entry absent)'
fi

# --- 13. Two-umask case (spec.md:7813-7845) -----------------------------------------------

stat_mode() { /usr/bin/stat -c '%a' "$1" 2>/dev/null || /usr/bin/stat -f '%OLp' "$1"; }

poll_for_home_and_read_modes() {
  # poll_for_home_and_read_modes OUTPUT -> prints "run_mode tmp_mode home_mode" or empty
  pfh_out=$1
  pfh_deadline=$(( $(/bin/date +%s) + 20 ))
  while [ ! -e "$pfh_out/.run/home" ]; do
    [ "$(/bin/date +%s)" -lt "$pfh_deadline" ] || { echo ''; return; }
    /bin/sleep 0.01
  done
  printf '%s %s %s\n' "$(stat_mode "$pfh_out/.run")" "$(stat_mode "$pfh_out/.run/tmp")" "$(stat_mode "$pfh_out/.run/home")"
}

# run_lockdown_modes_ok RUN -> 0 iff RUN/tmp (compiler scratch) is gone and RUN
# plus all four run files are exactly 0500 (plan.md:310-313's completed state).
run_lockdown_modes_ok() {
  rlm_run=$1
  [ ! -e "$rlm_run/tmp" ] || return 1
  for rlm_f in "$rlm_run" "$rlm_run/trusted-launch" "$rlm_run/nofollow-snapshot" "$rlm_run/jq" "$rlm_run/awk"; do
    [ "$(stat_mode "$rlm_f")" = 500 ] || return 1
  done
}

poll_for_lockdown_ok() {
  # poll_for_lockdown_ok OUTPUT -> 0 once the completed lockdown state is
  # reached, 1 on timeout (prints elapsed time and the last observed modes).
  pfl_run=$1/.run
  pfl_start=$(/bin/date +%s); pfl_deadline=$((pfl_start + 20))
  while ! run_lockdown_modes_ok "$pfl_run" 2>/dev/null; do
    [ "$(/bin/date +%s)" -lt "$pfl_deadline" ] || { printf 'lockdown timeout after %ss: run=%s launch=%s snap=%s jq=%s awk=%s tmp=%s\n' \
      "$(( $(/bin/date +%s) - pfl_start ))" \
      "$(stat_mode "$pfl_run" 2>/dev/null)" "$(stat_mode "$pfl_run/trusted-launch" 2>/dev/null)" \
      "$(stat_mode "$pfl_run/nofollow-snapshot" 2>/dev/null)" "$(stat_mode "$pfl_run/jq" 2>/dev/null)" \
      "$(stat_mode "$pfl_run/awk" 2>/dev/null)" "$([ -e "$pfl_run/tmp" ] && echo present || echo gone)" >&2; return 1; }
    /bin/sleep 0.01
  done
}

if [ -x "$entry" ]; then
  for u in 000 777; do
    um_out="$tmp/umask.$u"; /bin/mkdir -m 700 "$um_out"
    if (
      umask "$u"
      "$entry" "$bound_jq" "$um_out" "$synthetic_request" "$synthetic_map" \
        > "$um_out.stdout" 2> "$um_out.stderr" &
      um_pid=$!
      modes=$(poll_for_home_and_read_modes "$um_out")
      poll_for_lockdown_ok "$um_out"; lockdown_ok=$?
      wait "$um_pid"
      um_status=$?
      [ "$um_status" -eq 0 ] || exit 1
      [ "$lockdown_ok" -eq 0 ] || exit 1
      [ "$modes" = '700 700 700' ] || exit 1
      [ "$(stat_mode "$um_out/home")" = 700 ] || exit 1
      [ "$(stat_mode "$um_out/tmp")" = 700 ] || exit 1
      [ "$(stat_mode "$um_out/child.stdout")" = 600 ] || exit 1
      [ "$(stat_mode "$um_out/child.stderr")" = 600 ] || exit 1
    ); then
      pass_case "two-umask: entry run under caller umask $u produces 0700/0700/0700 provisioning tree, 0500 locked-down run files, and 0700/0600 sandbox"
    else
      fail_case "two-umask: umask $u"
    fi
  done
  lockdown_neg_run="$tmp/lockdown-neg/.run"; /bin/mkdir -p "$lockdown_neg_run"
  for lnf in trusted-launch nofollow-snapshot awk; do : > "$lockdown_neg_run/$lnf"; /bin/chmod 0500 "$lockdown_neg_run/$lnf"; done
  : > "$lockdown_neg_run/jq"; /bin/chmod 0700 "$lockdown_neg_run/jq"
  /bin/chmod 0500 "$lockdown_neg_run"
  if run_lockdown_modes_ok "$lockdown_neg_run"; then
    fail_case 'two-umask: run-lockdown mode check failed to reject a writable copied jq (negative control)'
  else
    pass_case 'two-umask: run-lockdown mode check rejects a writable copied jq (negative control)'
  fi
else
  fail_case 'two-umask: entry runs (entry absent)'
fi

if [ "$parent_available" -eq 1 ]; then
  # This is a success-path run (it inspects the sandbox files a completed
  # resolution leaves behind), so -- like R3 above -- OUTPUT must be the
  # directory that directly contains .run, not a separate empty directory.
  um_direct_out="$tmp/umask.direct.out"; build_run_directory "$um_direct_out"
  (
    umask 000
    invoke_parent "$um_direct_out/.run" "$synthetic_request" "$synthetic_map" "$um_direct_out" \
      > "$um_direct_out.stdout" 2> "$um_direct_out.stderr"
  )
  if [ "$(/usr/bin/stat -c '%a' "$um_direct_out/home" 2>/dev/null || /usr/bin/stat -f '%OLp' "$um_direct_out/home")" = 700 ] &&
     [ "$(/usr/bin/stat -c '%a' "$um_direct_out/tmp" 2>/dev/null || /usr/bin/stat -f '%OLp' "$um_direct_out/tmp")" = 700 ] &&
     [ "$(/usr/bin/stat -c '%a' "$um_direct_out/child.stdout" 2>/dev/null || /usr/bin/stat -f '%OLp' "$um_direct_out/child.stdout")" = 600 ]; then
    pass_case 'two-umask: direct-parent run under umask 000 still sets umask(077) itself'
  else
    fail_case 'two-umask: direct-parent run'
  fi
else
  fail_case 'two-umask: direct-parent run (parent absent)'
fi

# --- 14. Descriptor cases (spec.md:7846-7975) ---------------------------------------------

make_fifo_reader() {
  # make_fifo_reader NAME -> sets ${NAME}_fifo, starts /bin/cat>/dev/null reader in bg,
  # sets ${NAME}_reader_flag file that appears once the reader returns.
  #
  # The background GROUP's own stdout redirect matters, not just cat's: this
  # function runs inside a command substitution, a pipe that does not return
  # until every write-end holder closes it. "( /bin/cat ... >/dev/null; : >flag ) &"
  # redirects only cat's stdout -- the grouping subshell still inherits the
  # substitution's pipe on its OWN fd 1, and does not exit until the fifo (opened
  # for writing only after this call returns) gets a writer and a close -- a
  # confirmed live hang. Redirecting the whole group's stdout closes that
  # inherited copy first, matching the usual "$(cmd &)" fix.
  mfr_fifo="$tmp/fifo.$1"
  /usr/bin/mkfifo -m 600 "$mfr_fifo"
  mfr_flag="$tmp/fifo.$1.done"
  ( /bin/cat "$mfr_fifo" > /dev/null; : > "$mfr_flag" ) > /dev/null 2>&1 &
  printf '%s %s\n' "$mfr_fifo" "$mfr_flag"
}

if [ -x "$entry" ]; then
  # run 1: unrelated object on fd 7 -- ordering only
  read -r d1_fifo d1_flag <<< "$(make_fifo_reader d1)"
  d1_out="$tmp/descriptor.d1"; /bin/mkdir -m 700 "$d1_out"
  if (
    exec 7> "$d1_fifo"
    "$entry" "$bound_jq" "$d1_out" "$synthetic_request" "$synthetic_map" \
      > "$d1_out.stdout" 2> "$d1_out.stderr" &
    d1_pid=$!
    exec 7>&-
    d1_saw_run_before_eof=$(poll_run_before_eof "$d1_flag" "$d1_out" 20)
    wait "$d1_pid"
    [ "$d1_saw_run_before_eof" -eq 0 ] || exit 1
  ); then
    pass_case 'descriptor: entry closes an unrelated inherited fd before .run appears'
  else
    fail_case 'descriptor: unrelated object on fd 7'
  fi

  # run 2: caller descriptor is the entry script itself (copy), fd7 fifo + fd8 read-only.
  # The copy must sit at its own full "resolver/v1/resolve-profile.sh" repo-root-
  # relative path, not a bare file in $tmp: the entry derives its repo root from
  # ${BASH_SOURCE[0]} and requires "$entry_repo/scripts/lib/profile-resolution.sh"
  # to exist, so a flat copy fails that binding check first -- confirmed by a live
  # run refusing "E_RUNTIME binding" with .run never created. copy_repo_tree
  # already builds this shape for group 1's cases above.
  #
  # fd8 is opened READ-ONLY on the script (round-4 review, Linux CI diagnostics on
  # a99d7fc): Linux's exec() returns ETXTBSY ("Text file busy") for a script whose
  # interpreter line it must open for reading while ANY process holds it open for
  # writing (append counts) -- Darwin does not enforce this. The case's own point
  # (an extra caller-held descriptor on the entry's own script path is closed like
  # any other) does not depend on that descriptor being open for writing, so a
  # read-only open proves the same thing on both platforms.
  read -r d2_fifo d2_flag <<< "$(make_fifo_reader d2)"
  d2_tree="$tmp/descriptor.d2-tree"; copy_repo_tree "$d2_tree"
  entry_copy="$d2_tree/resolver/v1/resolve-profile.sh"; /bin/chmod 0755 "$entry_copy"
  copy_before_size=$(/usr/bin/wc -c < "$entry_copy" | /usr/bin/awk '{print $1}')
  copy_before_sha=$(sha256_file "$entry_copy")
  d2_out="$tmp/descriptor.d2"; /bin/mkdir -m 700 "$d2_out"
  if (
    exec 7> "$d2_fifo" 8< "$entry_copy"
    "$entry_copy" "$bound_jq" "$d2_out" "$synthetic_request" "$synthetic_map" \
      > "$d2_out.stdout" 2> "$d2_out.stderr" &
    d2_pid=$!
    exec 7>&- 8>&-
    d2_saw_run_before_eof=$(poll_run_before_eof "$d2_flag" "$d2_out" 20)
    wait "$d2_pid"
    d2_status=$?
    d2_after_size=$(/usr/bin/wc -c < "$entry_copy" | /usr/bin/awk '{print $1}')
    d2_after_sha=$(sha256_file "$entry_copy")
    d2_stdout_match=0
    /usr/bin/cmp -s "$clean_out.stdout" "$d2_out.stdout" && d2_stdout_match=1
    if [ "$d2_saw_run_before_eof" -ne 0 ] || [ "$d2_status" -ne 0 ] ||
       [ "$d2_stdout_match" -ne 1 ] || [ "$d2_after_size" -ne "$copy_before_size" ] ||
       [ "$d2_after_sha" != "$copy_before_sha" ]; then
      printf 'descriptor: entry-script-as-descriptor: saw_run_before_eof=%s status=%s(expected 0) stdout_match=%s(expected 1) size=%s(expected %s) sha=%s(expected %s) stderr=[%s]\n' \
        "$d2_saw_run_before_eof" "$d2_status" "$d2_stdout_match" \
        "$d2_after_size" "$copy_before_size" "$d2_after_sha" "$copy_before_sha" \
        "$(/usr/bin/tail -c 2000 "$d2_out.stderr" 2>/dev/null)" >&2
      exit 1
    fi
  ); then
    pass_case 'descriptor: caller descriptor is the running entry script itself (ordering, resolution, file unchanged)'
  else
    fail_case 'descriptor: entry-script-as-descriptor'
  fi

  # run 3: hard limit 63 -- refusal, output stays empty
  d3_out="$tmp/descriptor.d3"; /bin/mkdir -m 700 "$d3_out"
  d3_status=0
  ( ulimit -S -n 63; ulimit -H -n 63
    "$entry" "$bound_jq" "$d3_out" "$synthetic_request" "$synthetic_map" \
      > "$d3_out.stdout" 2> "$d3_out.stderr"
  ) || d3_status=$?
  if [ "$d3_status" -ne 0 ] && [ "$(/usr/bin/wc -l < "$d3_out.stderr" | /usr/bin/awk '{print $1}')" -eq 1 ] &&
     /usr/bin/grep -q '^E_RUNTIME' "$d3_out.stderr" && [ -z "$(/usr/bin/find "$d3_out" -mindepth 1 -print)" ]; then
    pass_case 'descriptor: hard limit 63 refuses before the close loop, output stays empty'
  else
    fail_case 'descriptor: hard limit 63'
  fi

  # run 4: hard limit 64 -- floor, not a wall
  d4_out="$tmp/descriptor.d4"; /bin/mkdir -m 700 "$d4_out"
  d4_status=0
  ( ulimit -S -n 64; ulimit -H -n 64
    "$entry" "$bound_jq" "$d4_out" "$synthetic_request" "$synthetic_map" \
      > "$d4_out.stdout" 2> "$d4_out.stderr"
  ) || d4_status=$?
  if [ "$d4_status" -eq 0 ] && /usr/bin/cmp -s "$clean_out.stdout" "$d4_out.stdout"; then
    pass_case 'descriptor: hard limit 64 is enough headroom, resolution completes byte-identical'
  else
    fail_case 'descriptor: hard limit 64'
  fi

  # run 5: caller has filled the low descriptor numbers -- success
  read -r d5_fifo d5_flag <<< "$(make_fifo_reader d5)"
  d5_out="$tmp/descriptor.d5"; /bin/mkdir -m 700 "$d5_out"
  if (
    ulimit -S -n 1024; ulimit -H -n 1024
    exec 7> "$d5_fifo"
    i=3
    while [ "$i" -le 255 ]; do
      [ "$i" -eq 7 ] || eval "exec $i</dev/null"
      i=$((i + 1))
    done
    "$entry" "$bound_jq" "$d5_out" "$synthetic_request" "$synthetic_map" \
      > "$d5_out.stdout" 2> "$d5_out.stderr" &
    d5_pid=$!
    exec 7>&-
    d5_saw_run_before_eof=$(poll_run_before_eof "$d5_flag" "$d5_out" 20)
    wait "$d5_pid"
    d5_status=$?
    [ "$d5_saw_run_before_eof" -eq 0 ] || exit 1
    [ "$d5_status" -eq 0 ] || exit 1
    /usr/bin/cmp -s "$clean_out.stdout" "$d5_out.stdout" || exit 1
  ); then
    pass_case 'descriptor: caller has filled numbers 3-255 (skipping 7); all closed, run succeeds'
  else
    fail_case 'descriptor: filled low descriptor numbers'
  fi

  # run 6: caller has filled every number the entry can normalise to -- refusal
  d6_out="$tmp/descriptor.d6"; /bin/mkdir -m 700 "$d6_out"
  d6_status=0
  (
    ulimit -S -n 1023; ulimit -H -n 1023
    i=3
    while [ "$i" -le 300 ]; do
      eval "exec $i</dev/null"
      i=$((i + 1))
    done
    "$entry" "$bound_jq" "$d6_out" "$synthetic_request" "$synthetic_map" \
      > "$d6_out.stdout" 2> "$d6_out.stderr"
  ) || d6_status=$?
  d6_e_runtime_lines=$(/usr/bin/grep -c '^E_RUNTIME' "$d6_out.stderr" 2>/dev/null || echo 0)
  d6_leftover=$(/usr/bin/find "$d6_out" -mindepth 1 -print 2>/dev/null)
  if [ "$d6_status" -ne 0 ] && [ "$d6_e_runtime_lines" -eq 1 ] && [ -z "$d6_leftover" ]; then
    pass_case 'descriptor: caller has filled every reachable low number; entry refuses, output stays empty'
  else
    printf 'descriptor: filled every low number: status=%s(expected nonzero) e_runtime_lines=%s(expected 1) leftover=[%s] stderr=[%s]\n' \
      "$d6_status" "$d6_e_runtime_lines" "$d6_leftover" "$(/usr/bin/tail -c 2000 "$d6_out.stderr" 2>/dev/null)" >&2
    fail_case 'descriptor: filled every low number'
  fi
else
  fail_case 'descriptor: entry-side cases (entry absent)'
fi

if [ "$parent_available" -eq 1 ]; then
  # parent half, run 1: fd 7 ordering vs runtime-pgid line
  # Success-path run (it waits for the parent's "runtime-pgid:" line, so a
  # premature E_RUNTIME from a mismatched output/.run pair would make the "never
  # saw it before the flag" assertion pass vacuously) -- OUTPUT must directly
  # contain .run, as in R3 above.
  #
  # The ordering assertion is R10's own ("the reader must return before
  # runtime-pgid: appears"), but *observing* that return depends on the
  # independently-scheduled /bin/cat reader being scheduled promptly -- a direct-
  # parent run with no compile step can finish fast enough that a delayed reader
  # wakeup loses the race even though the real ordering held. Confirmed benign
  # (five standalone repros all measured saw_before=0; a mid-suite false failure
  # left no live process, i.e. the run had already completed correctly). A small
  # bounded retry (sig5's shape above) absorbs scheduler noise without weakening
  # what any single attempt asserts.
  p1_proved=0
  p1_attempt=1
  while [ "$p1_attempt" -le 5 ] && [ "$p1_proved" -eq 0 ]; do
    read -r p1_fifo p1_flag <<< "$(make_fifo_reader "p1.$p1_attempt")"
    p1_out="$tmp/descriptor.p1.out.$p1_attempt"; build_run_directory "$p1_out"
    if (
      exec 7> "$p1_fifo"
      invoke_parent_exec "$p1_out/.run" "$synthetic_request" "$synthetic_map" "$p1_out" \
        > "$p1_out.stdout" 2> "$p1_out.stderr" &
      p1_pid=$!
      exec 7>&-
      p1_saw_before=0
      p1_deadline=$(( $(/bin/date +%s) + 20 ))
      while [ ! -e "$p1_flag" ]; do
        /usr/bin/grep -q '^runtime-pgid:' "$p1_out.stderr" 2>/dev/null && p1_saw_before=1
        [ "$(/bin/date +%s)" -lt "$p1_deadline" ] || break
        /bin/sleep 0.01
      done
      # This subshell is an "if" condition, so errexit is off inside it --
      # a failed wait, a reader that never reached EOF (no flag file), or a
      # parent that refused before ever writing runtime-pgid: must each be
      # caught explicitly, or a refusal-before-fork would pass this ordering
      # assertion vacuously.
      p1_wait_status=0
      wait "$p1_pid" || p1_wait_status=$?
      [ "$p1_wait_status" -eq 0 ] || exit 1
      [ -e "$p1_flag" ] || exit 1
      /usr/bin/grep -q '^runtime-pgid:' "$p1_out.stderr" 2>/dev/null || exit 1
      [ "$p1_saw_before" -eq 0 ] || exit 1
    ); then
      p1_proved=1
    fi
    p1_attempt=$((p1_attempt + 1))
  done
  if [ "$p1_proved" -eq 1 ]; then
    pass_case "descriptor: parent closes an unrelated inherited fd before runtime-pgid is written (attempt $((p1_attempt - 1)))"
  else
    fail_case 'descriptor: parent fd 7 ordering'
  fi

  # parent half, run 2: high descriptor (300) under a soft limit lowered after opening
  p2_proved=0
  p2_attempt=1
  while [ "$p2_attempt" -le 5 ] && [ "$p2_proved" -eq 0 ]; do
    read -r p2_fifo p2_flag <<< "$(make_fifo_reader "p2.$p2_attempt")"
    p2_out="$tmp/descriptor.p2.out.$p2_attempt"; build_run_directory "$p2_out"
    if (
      eval "exec 300> \"$p2_fifo\""
      ulimit -S -n 64
      invoke_parent_exec "$p2_out/.run" "$synthetic_request" "$synthetic_map" "$p2_out" \
        > "$p2_out.stdout" 2> "$p2_out.stderr" &
      p2_pid=$!
      exec 300>&-
      p2_saw_before=0
      p2_deadline=$(( $(/bin/date +%s) + 20 ))
      while [ ! -e "$p2_flag" ]; do
        /usr/bin/grep -q '^runtime-pgid:' "$p2_out.stderr" 2>/dev/null && p2_saw_before=1
        [ "$(/bin/date +%s)" -lt "$p2_deadline" ] || break
        /bin/sleep 0.01
      done
      # Same explicit success/EOF/diagnostic requirements as p1 above.
      p2_wait_status=0
      wait "$p2_pid" || p2_wait_status=$?
      [ "$p2_wait_status" -eq 0 ] || exit 1
      [ -e "$p2_flag" ] || exit 1
      /usr/bin/grep -q '^runtime-pgid:' "$p2_out.stderr" 2>/dev/null || exit 1
      [ "$p2_saw_before" -eq 0 ] || exit 1
    ); then
      p2_proved=1
    fi
    p2_attempt=$((p2_attempt + 1))
  done
  if [ "$p2_proved" -eq 1 ]; then
    pass_case "descriptor: parent normalises to hard limit (300 closed despite lowered soft limit) (attempt $((p2_attempt - 1)))"
  else
    fail_case 'descriptor: parent fd 300 under lowered soft limit'
  fi
else
  fail_case 'descriptor: parent-side cases (parent absent)'
fi

# --- 15. Signal cases (spec.md:7976-8385) --------------------------------------------------

if [ -x "$entry" ]; then
  # signal case 1: mid-run, frozen group
  sig1_stderr="$tmp/signal1.stderr"; : > "$sig1_stderr"
  sig1_out="$tmp/signal1.out"; /bin/mkdir -m 700 "$sig1_out"
  set -m
  "$entry" "$bound_jq" "$sig1_out" "$real_request" "$real_map" \
    > "$tmp/signal1.stdout" 2> "$sig1_stderr" &
  sig1_pid=$!
  sig1_pgid=$(read_runtime_pgid "$sig1_stderr")
  if [ -n "$sig1_pgid" ] && kill -STOP -- "-$sig1_pgid" 2>/dev/null && kill -0 -- "-$sig1_pgid" 2>/dev/null; then
    kill -TERM "$sig1_pid"
    sig1_status=0
    wait "$sig1_pid" || sig1_status=$?
    if kill -0 -- "-$sig1_pgid" 2>/dev/null; then sig1_group_gone=0; else sig1_group_gone=1; fi
    if [ "$sig1_status" -eq 143 ] && [ "$sig1_group_gone" -eq 1 ] && [ ! -e "$sig1_out/.run" ]; then
      pass_case 'signal: mid-run SIGTERM kills a SIGSTOPped resolver group and cleans up (143)'
    else
      fail_case 'signal: mid-run SIGSTOP/SIGTERM'
    fi
  else
    kill -CONT -- "-$sig1_pgid" 2>/dev/null || :
    wait "$sig1_pid" 2>/dev/null || :
    fail_case 'signal: mid-run case never reached a running resolver group on this run (fixture too short)'
  fi
  set +m
else
  fail_case 'signal: mid-run frozen group (entry absent)'
fi

if [ -x "$entry" ]; then
  # signal case 2: repeated signal (TERM,TERM,group-TERM) -- also run the INT variant
  for variant in TERM INT; do
    sig2_stderr="$tmp/signal2.$variant.stderr"; : > "$sig2_stderr"
    sig2_out="$tmp/signal2.$variant.out"; /bin/mkdir -m 700 "$sig2_out"
    set -m
    "$entry" "$bound_jq" "$sig2_out" "$real_request" "$real_map" \
      > "$tmp/signal2.$variant.stdout" 2> "$sig2_stderr" &
    sig2_pid=$!
    sig2_pgid=$(read_runtime_pgid "$sig2_stderr")
    # The entry's diagnostic names parent_pid (the trusted-launch process it
    # backgrounded), not the entry shell's own $$/sig2_pid -- read the real
    # child pid from the process table while the entry is still alive so the
    # assertion below checks the actual recipient of the forwarded signal.
    sig2_parent_pid=$(/bin/ps -A -o pid=,ppid= 2>/dev/null |
      /usr/bin/awk -v p="$sig2_pid" '$2==p{print $1; exit}')
    if [ -z "$sig2_pgid" ] || [ -z "$sig2_parent_pid" ] ||
       ! kill -STOP -- "-$sig2_pgid" 2>/dev/null || ! kill -0 -- "-$sig2_pgid" 2>/dev/null; then
      kill -CONT -- "-$sig2_pgid" 2>/dev/null || :; wait "$sig2_pid" 2>/dev/null || :
      # fail_case never returns (it exits the whole suite); the loop ends here.
      fail_case "signal: repeated-$variant case never reached a running resolver group"
    fi
    kill -TERM "$sig2_pid"
    sig2_run_gone_early=0
    ( /bin/sleep 0.1
      kill -"$variant" "$sig2_pid" 2>/dev/null || :
      /bin/sleep 0.1
      kill -TERM -- "-$(ps -o pgid= -p "$sig2_pid" 2>/dev/null | /usr/bin/tr -d ' ')" 2>/dev/null || :
    ) &
    sig2_watcher=$!
    sig2_deadline=$(( $(/bin/date +%s) + 30 ))
    while kill -0 "$sig2_pid" 2>/dev/null; do
      if [ ! -e "$sig2_out/.run" ] && ! /usr/bin/grep -q '^parent-signal:' "$sig2_stderr" 2>/dev/null; then
        : # not yet armed or already fully gone before parent-signal -- checked below
      fi
      if [ ! -e "$sig2_out/.run" ]; then
        /usr/bin/grep -q '^parent-signal:' "$sig2_stderr" 2>/dev/null || sig2_run_gone_early=1
      fi
      [ "$(/bin/date +%s)" -lt "$sig2_deadline" ] || break
      /bin/sleep 0.005
    done
    wait "$sig2_watcher" 2>/dev/null || :
    sig2_status=0
    wait "$sig2_pid" || sig2_status=$?
    sig2_lines=$(/usr/bin/grep -c '^entry-signal:' "$sig2_stderr" 2>/dev/null || echo 0)
    sig2_line=$(/usr/bin/grep -m1 '^entry-signal:' "$sig2_stderr" 2>/dev/null || :)
    if [ "$sig2_status" -eq 143 ] && [ "$sig2_run_gone_early" -eq 0 ] && [ "$sig2_lines" -eq 1 ] &&
       [ "$sig2_line" = 'entry-signal: TERM forwarded '"$sig2_parent_pid" ] && [ ! -e "$sig2_out/.run" ]; then
      pass_case "signal: repeated $variant then group-TERM: .run never removed while parent alive, one entry-signal line naming TERM"
    else
      fail_case "signal: repeated-$variant case"
    fi
    set +m
  done
else
  fail_case 'signal: repeated signal cases (entry absent)'
fi

if [ -x "$entry" ]; then
  # signal case 3: pre-parent, no-parent branch (pid-targeted TERM)
  sig3_stderr="$tmp/signal3.stderr"; : > "$sig3_stderr"
  sig3_out="$tmp/signal3.out"; /bin/mkdir -m 700 "$sig3_out"
  "$entry" "$bound_jq" "$sig3_out" "$real_request" "$real_map" \
    > "$tmp/signal3.stdout" 2> "$sig3_stderr" &
  sig3_pid=$!
  wait_for_run "$sig3_out"
  if [ -e "$sig3_out/.run" ]; then
    kill -TERM "$sig3_pid"
    # Bounded wait: a watcher kills the entry if it has not exited within 30s (macOS has
    # no `timeout`; a compile on a slow machine is the budget this covers).
    ( /usr/bin/perl -e 'alarm shift; sleep 999' 30 || :
      kill -KILL "$sig3_pid" 2>/dev/null || : ) &
    sig3_watchdog=$!
    sig3_status=0
    wait "$sig3_pid" 2>/dev/null || sig3_status=$?
    kill "$sig3_watchdog" 2>/dev/null || :
    sig3_line=$(/usr/bin/grep -m1 '^entry-signal:' "$sig3_stderr" 2>/dev/null || :)
    if [ "$sig3_status" -eq 143 ] && [ "$sig3_line" = 'entry-signal: TERM no-parent' ] &&
       ! /usr/bin/grep -q '^runtime-pgid:' "$sig3_stderr" 2>/dev/null &&
       [ -z "$(/usr/bin/find "$sig3_out" -mindepth 1 -print)" ]; then
      pass_case 'signal: pre-parent SIGTERM (pid) takes the no-parent branch and cleans up fully'
    else
      fail_case 'signal: pre-parent no-parent branch'
    fi
  else
    wait "$sig3_pid" 2>/dev/null || :
    fail_case 'signal: pre-parent case landed too late -- .run never appeared inside the poll window'
  fi
else
  fail_case 'signal: pre-parent no-parent branch (entry absent)'
fi

if [ -x "$entry" ]; then
  # signal case 4: terminal group signal reaching a compile
  sig4_stderr="$tmp/signal4.stderr"; : > "$sig4_stderr"
  sig4_out="$tmp/signal4.out"; /bin/mkdir -m 700 "$sig4_out"
  set -m
  "$entry" "$bound_jq" "$sig4_out" "$real_request" "$real_map" \
    > "$tmp/signal4.stdout" 2> "$sig4_stderr" &
  sig4_pid=$!
  sig4_pgid=$(ps -o pgid= -p "$sig4_pid" 2>/dev/null | /usr/bin/tr -d ' ')
  wait_for_run "$sig4_out"
  if [ -e "$sig4_out/.run" ]; then
    # give the compile a brief head start so the group signal is likelier to land on it
    /bin/sleep 0.05
    kill -TERM -- "-$sig4_pgid" 2>/dev/null || :
    sig4_status=0
    wait "$sig4_pid" 2>/dev/null || sig4_status=$?
    sig4_line=$(/usr/bin/grep -m1 '^entry-signal:' "$sig4_stderr" 2>/dev/null || :)
    if [ "$sig4_status" -eq 143 ] && [ "$sig4_line" = 'entry-signal: TERM no-parent' ] &&
       ! /usr/bin/grep -q '^E_RUNTIME' "$sig4_stderr" 2>/dev/null &&
       [ -z "$(/usr/bin/find "$sig4_out" -mindepth 1 -print)" ]; then
      pass_case 'signal: terminal group SIGTERM interrupting a compile is a signal exit, never a refusal'
    else
      fail_case 'signal: terminal group signal case'
    fi
  else
    wait "$sig4_pid" 2>/dev/null || :
    fail_case 'signal: group-signal case landed too late -- .run never appeared'
  fi
  set +m
else
  fail_case 'signal: terminal group signal case (entry absent)'
fi

if [ "$parent_available" -eq 1 ]; then
  # signal case 5: stopped-parent, no-runtime branch. STOP must land after
  # handler install (else pending, delivered at CONT, default disposition)
  # but before supervise() publishes runtime-pgid: -- rendezvous on a live
  # pin-phase child with <out>/home still absent, then prove the STOP itself
  # via process state before trusting it (20 attempts, case88-diagnosis.md).
  sig5_proved=0
  sig5_late_stop=0
  sig5_stop_unproved=0
  sig5_missed_window=0
  attempt=1
  while [ "$attempt" -le 20 ] && [ "$sig5_proved" -eq 0 ]; do
    sig5_out="$tmp/signal5.attempt$attempt.out"; build_run_directory "$sig5_out"
    sig5_stderr="$tmp/signal5.attempt$attempt.stderr"
    (
      set +m
      # invoke_parent_exec, not invoke_parent: this case signals $sig5_pid directly
      # (STOP/CONT/TERM), so it has to be trusted-launch's own pid, not a bash
      # wrapper's -- see invoke_parent_exec's comment (same reasoning as p1/p2
      # above, minus the descriptor angle: signalling the wrapper would leave
      # trusted-launch itself running right through the STOP this case depends on).
      invoke_parent_exec "$sig5_out/.run" "$synthetic_request" "$synthetic_map" "$sig5_out" \
        > "$tmp/signal5.attempt$attempt.stdout" 2> "$sig5_stderr" &
      sig5_pid=$!
      /bin/sleep 5 &
      sig5_sentinel=$!
      pgid_parent=$(ps -o pgid= -p "$sig5_pid" 2>/dev/null | /usr/bin/tr -d ' ')
      pgid_sentinel=$(ps -o pgid= -p "$sig5_sentinel" 2>/dev/null | /usr/bin/tr -d ' ')
      pgid_shell=$(ps -o pgid= -p $$ 2>/dev/null | /usr/bin/tr -d ' ')
      sig5_bail() {
        kill "$sig5_sentinel" 2>/dev/null || :; kill -CONT "$sig5_pid" 2>/dev/null || :
        wait "$sig5_pid" 2>/dev/null || :; echo "$1" > "$tmp/signal5.attempt$attempt.outcome"; exit 0
      }
      [ "$pgid_parent" = "$pgid_sentinel" ] && [ "$pgid_parent" = "$pgid_shell" ] || sig5_bail mismatch
      # Rendezvous: a live child (~10s deadline) proves past handler install.
      sig5_tick=0 sig5_child=0
      while [ "$sig5_tick" -lt 1000 ] && [ "$sig5_child" -eq 0 ]; do
        /usr/bin/pgrep -P "$sig5_pid" >/dev/null 2>&1 && sig5_child=1
        [ "$sig5_child" -eq 1 ] || { /bin/sleep 0.01; sig5_tick=$((sig5_tick + 1)); }
      done
      [ "$sig5_child" -eq 1 ] || sig5_bail missed-window
      [ -e "$sig5_out/home" ] && sig5_bail missed-window
      kill -STOP "$sig5_pid" 2>/dev/null || :
      sig5_state='' sig5_stop_tick=0
      while [ "$sig5_stop_tick" -lt 100 ]; do
        sig5_state=$(/bin/ps -o state= -p "$sig5_pid" 2>/dev/null | /usr/bin/tr -d ' ')
        case "$sig5_state" in T*) break ;; esac
        /bin/sleep 0.01
        sig5_stop_tick=$((sig5_stop_tick + 1))
      done
      case "$sig5_state" in T*) ;; *) sig5_bail stop-unproved ;; esac
      { [ ! -e "$sig5_out/home" ] && ! /usr/bin/grep -q '^runtime-pgid:' "$sig5_stderr" 2>/dev/null; } ||
        sig5_bail late-stop
      kill -TERM "$sig5_pid" 2>/dev/null || :
      kill -CONT "$sig5_pid" 2>/dev/null || :
      sig5_status=0
      wait "$sig5_pid" 2>/dev/null || sig5_status=$?
      kill "$sig5_sentinel" 2>/dev/null || :
      echo "$sig5_status" > "$tmp/signal5.attempt$attempt.outcome"
    )
    outcome=$(cat "$tmp/signal5.attempt$attempt.outcome" 2>/dev/null || echo unknown)
    case "$outcome" in
      late-stop) sig5_late_stop=$((sig5_late_stop + 1)) ;;
      stop-unproved) sig5_stop_unproved=$((sig5_stop_unproved + 1)) ;;
      missed-window) sig5_missed_window=$((sig5_missed_window + 1)) ;;
      mismatch) : ;;
      *) [ "$outcome" = 143 ] && /usr/bin/grep -q '^parent-signal: TERM no-runtime$' "$sig5_stderr" &&
         ! /usr/bin/grep -q '^runtime-pgid:' "$sig5_stderr" && sig5_proved=1 ;;
    esac
    attempt=$((attempt + 1))
  done
  if [ "$sig5_proved" -eq 1 ]; then
    pass_case "signal: stopped-parent no-runtime branch proved (attempt $((attempt - 1)); late-stop=$sig5_late_stop stop-unproved=$sig5_stop_unproved missed-window=$sig5_missed_window)"
  else
    fail_case "signal: stopped-parent no-runtime branch never proved in 20 attempts (late-stop=$sig5_late_stop stop-unproved=$sig5_stop_unproved missed-window=$sig5_missed_window)"
  fi
else
  fail_case 'signal: stopped-parent no-runtime branch (parent absent)'
fi

if [ -x "$entry" ]; then
  # signal: O_NONBLOCK restore variant (dup'd pipe, fcntl probe)
  fcntl_probe_src="$tmp/fcntl-probe.c"
  cat > "$fcntl_probe_src" <<'FCNTLPROBE'
#include <fcntl.h>
#include <stdio.h>
int main(void) {
  int flags = fcntl(3, F_GETFL, 0);
  if (flags < 0) { perror("fcntl"); return 2; }
  puts((flags & O_NONBLOCK) ? "nonblock" : "clear");
  return 0;
}
FCNTLPROBE
  fcntl_probe="$tmp/fcntl-probe"
  /usr/bin/cc -std=c11 -Wall -Wextra -O2 "$fcntl_probe_src" -o "$fcntl_probe"

  /usr/bin/mkfifo -m 600 "$tmp/signal6.fifo"
  sig6_out="$tmp/signal6.out"; /bin/mkdir -m 700 "$sig6_out"
  sig6_stderr="$tmp/signal6.stderr"; : > "$sig6_stderr"
  set -m
  exec 9<> "$tmp/signal6.fifo"
  # fd 8 duplicates fd 9's open file description, saved BEFORE the pipe's write
  # end is handed to the entry as its stderr. File-status flags (O_NONBLOCK
  # among them) live on the open file description, so whatever the entry does
  # to its own fd 2 is visible through fd 8 even after the entry exits.
  # Probing fd 9 or the drainer's copy would instead observe process
  # substitution's own, unrelated pipe -- flags never propagate through `tee`.
  exec 8<&9
  ( /bin/cat <&9 > "$sig6_stderr" ) &
  sig6_drainer=$!
  "$entry" "$bound_jq" "$sig6_out" "$real_request" "$real_map" \
    > "$tmp/signal6.stdout" 2>&9 &
  sig6_pid=$!
  wait_for_run "$sig6_out"
  # Wait for a live runtime process (not merely the .run directory, which
  # appears before the parent is even compiled) before signaling, then reap
  # the entry, and only then inspect the retained duplicate descriptor's
  # flags -- otherwise the probe can run before the parent ever sets
  # O_NONBLOCK and the "restored" claim is vacuous.
  sig6_pgid=$(read_runtime_pgid "$sig6_stderr")
  [ -n "$sig6_pgid" ] || fail_case 'signal: O_NONBLOCK restore variant never reached a running resolver group'
  kill -TERM "$sig6_pid" 2>/dev/null || :
  sig6_status=0
  wait "$sig6_pid" 2>/dev/null || sig6_status=$?
  sig6_probe_status=$("$fcntl_probe" 3<&8 2>/dev/null || echo error)
  exec 9>&- 8>&-
  kill "$sig6_drainer" 2>/dev/null || :
  if [ "$sig6_status" -eq 143 ] && [ "$sig6_probe_status" = clear ]; then
    pass_case 'signal: O_NONBLOCK is restored on the entry''s stderr descriptor after a mid-run TERM'
  else
    fail_case 'signal: O_NONBLOCK restore variant'
  fi
  set +m
else
  fail_case 'signal: O_NONBLOCK restore variant (entry absent)'
fi

if [ -x "$entry" ]; then
  # signal: full pipe, entry omits its entry-signal: line rather than block on it
  /usr/bin/mkfifo -m 600 "$tmp/signal7.fifo"
  exec 10<> "$tmp/signal7.fifo"
  sig7_probe=$("$fcntl_probe" 3<&10 2>/dev/null || echo error)
  [ "$sig7_probe" = clear ] || fail_case 'signal: full-pipe case fixture is non-blocking before the filler starts'
  ( /bin/dd if=/dev/zero bs=65536 count=2 1>&10 2>/dev/null ) &
  sig7_filler=$!
  /bin/sleep 1
  kill -0 "$sig7_filler" 2>/dev/null || fail_case 'signal: full-pipe filler exited -- pipe was never full'
  sig7_full_probe=$("$fcntl_probe" 3<&10 2>/dev/null || echo error)
  [ "$sig7_full_probe" = clear ] || fail_case 'signal: full-pipe descriptor unexpectedly non-blocking'
  sig7_out="$tmp/signal7.out"; /bin/mkdir -m 700 "$sig7_out"
  "$entry" "$bound_jq" "$sig7_out" "$real_request" "$real_map" \
    > "$tmp/signal7.stdout" 2>&10 &
  sig7_pid=$!
  wait_for_run "$sig7_out"
  if [ -e "$sig7_out/.run" ]; then
    kill -TERM "$sig7_pid"
    # Bounded wait: a watchdog kills the entry if it has not exited within 30s.
    # fd 10 is closed first so the watchdog's Perl child never holds a writer
    # reference on the FIFO past the kill below -- otherwise it outlives the
    # 30s alarm and the drain never sees EOF.
    ( exec 10>&-
      /usr/bin/perl -e 'alarm shift; sleep 999' 30 || :
      kill -KILL "$sig7_pid" 2>/dev/null || : ) &
    sig7_watchdog=$!
    sig7_wait_status=0
    wait "$sig7_pid" 2>/dev/null || sig7_wait_status=$?
    kill "$sig7_watchdog" 2>/dev/null || :
    # Reap it: kill only sends the signal (fd 10 is already closed above).
    wait "$sig7_watchdog" 2>/dev/null || :
  else
    fail_case 'signal: full-pipe case landed too late -- .run never appeared'
  fi
  # Reap the filler too: its own fd 10 copy must be gone before the close
  # below, or EOF never arrives for the drain.
  kill "$sig7_filler" 2>/dev/null || :
  wait "$sig7_filler" 2>/dev/null || :
  sig7_after=$(/usr/bin/find "$sig7_out" -mindepth 1 -print 2>/dev/null)
  drained="$tmp/signal7.drained"
  drained_flag="$tmp/signal7.drained.done"
  # Round-4 review: the previous background `cat`-after-a-fixed-50ms-sleep was a
  # race -- a slow-to-schedule drainer could still be waiting when this shell
  # closes fd 10, so its read-only open() finds no writer left and blocks
  # forever. Fixed by opening the read end SYNCHRONOUSLY, as fd 11, in THIS
  # shell, before fd 10 (the remaining writer) is closed: the open cannot block
  # since fd 10 is still a live writer, so the reader is provably attached
  # before the last writer goes away. The background `cat` below only reads an
  # already-open fd 11, no longer timing-sensitive.
  exec 11< "$tmp/signal7.fifo"
  exec 10>&-
  ( /bin/cat 0<&11 > "$drained" 2>/dev/null; : > "$drained_flag" ) &
  sig7_drain_pid=$!
  # 30s, matching this file's other post-signal watchdog bounds: the kernel
  # withholds EOF until every writer is closed, and a loaded host's teardown
  # after TERM can lag; 10s was observed too tight though nothing was leaked.
  sig7_drain_deadline=$(( $(/bin/date +%s) + 30 ))
  while [ ! -e "$drained_flag" ]; do
    [ "$(/bin/date +%s)" -lt "$sig7_drain_deadline" ] || break
    /bin/sleep 0.02
  done
  kill "$sig7_drain_pid" 2>/dev/null || :
  exec 11<&-
  if [ "$sig7_wait_status" -eq 143 ] && [ -z "$sig7_after" ] &&
     [ -e "$drained_flag" ] && [ -e "$drained" ] &&
     ! /usr/bin/grep -q '^entry-signal:' "$drained" 2>/dev/null; then
    pass_case 'signal: entry omits its entry-signal line on a full pipe rather than blocking'
  else
    fail_case 'signal: full-pipe omission case'
  fi
else
  fail_case 'signal: full-pipe omission case (entry absent)'
fi

# --- 16. Pinned blob / generation constant assertions (spec.md:8388-8410) ------------------

launcher_blob_expected=f4de7e48c688b6adb3669f69a221d2aa7bf43b15
launcher_blob_actual=$(/usr/bin/git -C "$root" hash-object "$launcher_source")
if [ "$launcher_blob_actual" = "$launcher_blob_expected" ]; then
  pass_case 'baseline launcher blob (portable-profile-resolution-launcher.c) matches the accepted pin'
else
  fail_case "baseline launcher blob mismatch: got $launcher_blob_actual, expected $launcher_blob_expected"
fi

if [ -f "$entry" ]; then
  for f in "$parent_source" "$helper_source" "${loaded_files[@]}"; do
    expected=$(/usr/bin/git -C "$root" hash-object "$f")
    /usr/bin/grep -qF -- "$expected" "$entry" ||
      fail_case "pinned blob missing from entry: $f ($expected)"
  done
  pass_case 'entry (resolve-profile.sh) pins all ten blob ids as literal git hash-object values'
else
  fail_case 'entry pin literals (entry absent)'
fi

if [ -f "$parent_source" ]; then
  for f in "${loaded_files[@]}"; do
    expected=$(/usr/bin/git -C "$root" hash-object "$f")
    /usr/bin/grep -qF -- "$expected" "$parent_source" ||
      fail_case "pinned blob missing from parent: $f ($expected)"
  done
  pass_case 'parent (trusted-launch.c) pins all eight loaded-file blob ids as literal git hash-object values'

  # Pin-liveness (R11): a bare "$core_generation_value" / '2' grep is tautological
  # (both derive from the source under test; a changed PARENT_SCHEMA_MAJOR still
  # passes). Parse each side's own constants and compare against the ACCEPTED
  # LIBRARY (scripts/core-contract.sh), the source the runtime actually resolves.
  core_contract="$root/scripts/core-contract.sh"
  library_generation=$(/usr/bin/grep -oE "PORTABLE_CORE_GENERATION='g-[0-9a-f]{64}'" "$core_contract" |
    /usr/bin/grep -oE 'g-[0-9a-f]{64}')
  library_schema_major=$(/usr/bin/grep -oE "PORTABLE_CORE_SCHEMA_MAJOR='[0-9]+'" "$core_contract" |
    /usr/bin/grep -oE '[0-9]+')

  # extract_parent_pins SRC -> "GENERATION SCHEMA_MAJOR" from a trusted-launch.c
  # source (blank fields on a parse miss).
  extract_parent_pins() {
    /usr/bin/grep -A1 'static const char \*const PARENT_CORE_GENERATION =' "$1" 2>/dev/null |
      /usr/bin/grep -oE 'g-[0-9a-f]{64}' | { read -r g; printf '%s ' "$g"; }
    /usr/bin/grep -oE 'PARENT_SCHEMA_MAJOR = "[0-9]+"' "$1" 2>/dev/null | /usr/bin/grep -oE '[0-9]+'
  }

  read -r parent_generation parent_schema_major <<< "$(extract_parent_pins "$parent_source")"
  if [ "$parent_generation" = "$library_generation" ] && [ "$parent_schema_major" = "$library_schema_major" ]; then
    pass_case 'parent core-generation/schema-major constants match the accepted library'
  else
    fail_case "parent generation/schema-major constants: got $parent_generation/$parent_schema_major, library wants $library_generation/$library_schema_major"
  fi

  # Negative control: PARENT_SCHEMA_MAJOR=9 in a fixture copy must be caught here.
  tampered_parent="$tmp/parent-schema-major-tamper.c"
  /bin/cp "$parent_source" "$tampered_parent"
  /usr/bin/sed -i.bak 's/PARENT_SCHEMA_MAJOR = "2"/PARENT_SCHEMA_MAJOR = "9"/' "$tampered_parent" 2>/dev/null ||
    /usr/bin/perl -pi -e 's/PARENT_SCHEMA_MAJOR = "2"/PARENT_SCHEMA_MAJOR = "9"/' "$tampered_parent"
  read -r tampered_generation tampered_schema_major <<< "$(extract_parent_pins "$tampered_parent")"
  if [ "$tampered_generation" = "$library_generation" ] && [ "$tampered_schema_major" = "$library_schema_major" ]; then
    fail_case 'pin-liveness negative control: a tampered PARENT_SCHEMA_MAJOR went undetected'
  else
    pass_case 'pin-liveness check rejects a fixture PARENT_SCHEMA_MAJOR=9 (negative control)'
  fi
else
  fail_case 'parent pin literals (trusted-launch.c absent)'
fi

if [ -f "$entry" ]; then
  entry_generation=$(/usr/bin/grep -oE '^core_generation=g-[0-9a-f]{64}' "$entry" | /usr/bin/sed -E 's/^core_generation=//')
  entry_schema_major=$(/usr/bin/grep -oE '^core_schema_major=[0-9]+' "$entry" | /usr/bin/sed -E 's/^core_schema_major=//')
  if [ "$entry_generation" = "$library_generation" ] && [ "$entry_schema_major" = "$library_schema_major" ]; then
    pass_case 'entry core-generation/schema-major constants match the accepted library'
  else
    fail_case "entry generation/schema-major constants: got $entry_generation/$entry_schema_major, library wants $library_generation/$library_schema_major"
  fi
fi

# --- Copy-identity: every copy-begin/copy-end span in trusted-launch.c must be a byte-
# for-byte copy of the cited scripts/test/portable-profile-resolution-launcher.c span
# (spec's launcher-copy provenance). The step-3 include split (deviation 2: <dirent.h>
# unconditional, spec R5) replaced the original :1-43 span with :1-17 and :19-43 around
# the inserted include and its comment, dropping the launcher's own blank separator
# line 18 -- this check follows that split rather than the original single span.
if [ -f "$parent_source" ]; then
  copy_bad=0
  copy_checked=0
  while IFS=: read -r begin_line rest; do
    span=${rest#*launcher.c:}
    span=${span%% at *}
    case $span in
      *-*) cs_start=${span%-*}; cs_end=${span#*-} ;;
      *) cs_start=$span; cs_end=$span ;;
    esac
    end_line=$(/usr/bin/awk -v from="$begin_line" 'NR > from && /^\/\* copy-end \*\// { print NR; exit }' "$parent_source")
    [ -n "$end_line" ] || fail_case "copy-identity: no copy-end found after line $begin_line"
    copy_checked=$((copy_checked + 1))
    body_start=$((begin_line + 1))
    body_end=$((end_line - 1))
    if [ "$body_start" -gt "$body_end" ]; then
      copy_body=""
    else
      copy_body=$(/usr/bin/sed -n "${body_start},${body_end}p" "$parent_source")
    fi
    launcher_span=$(/usr/bin/sed -n "${cs_start},${cs_end}p" "$launcher_source")
    if [ "$copy_body" != "$launcher_span" ]; then
      copy_bad=$((copy_bad + 1))
      printf 'copy-identity mismatch: trusted-launch.c:%s-%s vs launcher.c:%s-%s\n' \
        "$body_start" "$body_end" "$cs_start" "$cs_end" >&2
    fi
  done < <(/usr/bin/grep -n '^/\* copy-begin scripts/test/portable-profile-resolution-launcher\.c:' "$parent_source")
  if [ "$copy_checked" -gt 0 ] && [ "$copy_bad" -eq 0 ]; then
    pass_case "copy-identity: all $copy_checked launcher-copy spans in trusted-launch.c match portable-profile-resolution-launcher.c verbatim"
  else
    fail_case "copy-identity: $copy_bad of $copy_checked launcher-copy span(s) in trusted-launch.c mismatch"
  fi
else
  fail_case 'copy-identity: launcher-copy spans (trusted-launch.c absent)'
fi

# --- 17. Mechanism checks: proof-by-reading greps (spec.md:8800-8995) ---------------------
#
# These are the automatable readings R10 specifies: the three-pass allowlist sweep, the
# awk/printf position assertions, and the handler async-signal-safety grep. Several other
# "readings" R10 lists explicitly cannot be a test case at all (the fork/reap windows and
# the signal-delivery-timing claims); those are not implemented here and are named in the
# coder's report rather than silently dropped.

allowlist_words='/bin/bash /bin/mkdir /bin/cp /bin/chmod /bin/rm /bin/cat /usr/bin/uname /usr/bin/printf /usr/bin/env /usr/bin/stat /usr/bin/cc /Library/Developer/CommandLineTools/usr/bin/clang /usr/bin/shasum /usr/bin/sha256sum /usr/bin/sha1sum'
allowlist_data='/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk /usr/bin:/bin /proc /proc/%s/stat /usr/bin/awk /dev/fd /dev/fd/* /dev/fd/2'

# Dynamic-join suffixes: the regex above has no way to see the "$var" a real
# absolute-path token is missing, so a literal like "$run/awk" or
# "$entry_repo/resolver/v1/trusted-launch.c" surfaces here as the bare trailing
# fragment after the last variable interpolation ("/awk", "/resolver/v1/
# trusted-launch.c"). Spec's own words for this: "Do not manufacture host paths
# from dynamic joins, parameter patterns... Preserve dynamic value review" --
# each one below was read at its call site in resolver/v1/resolve-profile.sh
# and confirmed to be exactly that, never a literal leading-slash path in the
# source: "$run/{awk,jq,home,tmp,trusted-launch,nofollow-snapshot}",
# "$entry_repo/{resolver/v1/*.c,resolver/v1/profile-resolution.jq,
# scripts/lib/profile-resolution.sh,core/v$core_schema_major}",
# "$modules_dir/{schema,profile_graph,stage_request,result_facts,result_truth}.jq",
# "$entry_dir/profile-resolve-runtime.sh", and "$output/.run". This
# is a hand-reviewed approximation of the closure the full lexical pass would
# compute, not that pass itself.
allowlist_dynamic_joins='/awk /jq /home /tmp /trusted-launch /nofollow-snapshot /resolver/v1/trusted-launch.c /resolver/v1/nofollow-snapshot.c /resolver/v1/profile-resolution.jq /scripts/lib/profile-resolution.sh /schema.jq /profile_graph.jq /stage_request.jq /result_facts.jq /result_truth.jq /core/v /generations /modules /profile-resolve-runtime.sh /.run'

# "/dev/null" is the same regex-versus-":"/redirect-operator artefact as "/bin"
# below (e.g. "2>/dev/null"): it is not a command word or a manufactured host
# path, and its own roles are independently checked a few hundred lines below
# ("mechanism: /dev/null discard appears only in its enumerated roles").
#
# "/usr/bin"/"/bin" (round-8 finding 3): both halves of the fixed
# "/usr/bin:/bin" PATH splice (resolve-profile.sh:70,77,88,284,401); a colon
# is not a join-context char, so each half is STANDALONE, not dynamic-join.
# "/resolver/v1" is the ${entry_dir%/resolver/v1} trim operand
# (resolve-profile.sh:132), likewise standalone. All literal, not attacker-influenced.
allowlist_data="$allowlist_data /dev/null /usr/bin /bin /resolver/v1"

sweep_absolute_paths() {
  # sweep_absolute_paths FILE -- approximates R10's pass-1 source-role carve-out
  # for full-line comments only: a whole-line "# ..." comment is prose describing
  # the shipped mechanism (copy-provenance headers, path references in doc
  # comments), never an executable command position, so it is excluded before the
  # token scan. This is still an approximation, not the full three-pass lexical
  # extraction spec.md:8801-8940 describes (a trailing same-line comment after
  # real code, and the source-role/quoting/assignment distinctions within actual
  # code, are not attempted here) -- flagged as a known gap rather than claimed as
  # complete, matching this test's own comment above at the mechanism-checks
  # section header.
  #
  # Round-4 review: a token match alone cannot tell a standalone literal path
  # (dangerous in argument position, e.g. a bare "/tmp") from the trailing
  # fragment of a legitimate "$var/join" (the dynamic-join allowlist's whole
  # reason to exist). The pattern below optionally captures ONE character
  # immediately before the leading "/": an identifier character or "}" can
  # only appear there when the match is the tail of a longer "$name/..." or
  # "${name}/..." expression, never at the start of a standalone path literal
  # (which is preceded by whitespace, a quote, "=", start-of-line, etc. --
  # none of which are in the captured class). The caller strips that context
  # character back off before comparing against an allowlist, but uses its
  # presence to pick WHICH allowlist a token may match: a standalone token
  # must be a literal command/data path (allowlist_words / allowlist_data);
  # only a joined token may additionally match a dynamic-join fragment.
  sap_file=$1
  /usr/bin/grep -Ev '^[[:space:]]*#' "$sap_file" 2>/dev/null |
    /usr/bin/grep -Eo '[A-Za-z0-9_}]?(/[A-Za-z0-9_.%*-]+)+' | /usr/bin/sort -u
}

if [ -f "$entry" ]; then
  bad_tokens=0
  set -f
  for tok_raw in $(sweep_absolute_paths "$entry"); do
    case "$tok_raw" in
      /*) tok_role=standalone; tok=$tok_raw ;;
      *) tok_role=joined; tok=${tok_raw#?} ;;
    esac
    match=0
    case "$tok_role" in
      standalone)
        for w in $allowlist_words $allowlist_data; do [ "$tok" = "$w" ] && match=1 && break; done
        ;;
      joined)
        for w in $allowlist_words $allowlist_data $allowlist_dynamic_joins; do [ "$tok" = "$w" ] && match=1 && break; done
        ;;
    esac
    case "$tok" in
      # The required self-path case pattern (R1's `case ${BASH_SOURCE[0]} in /*)`)
      # is classified as a non-path pattern, not an absolute-path token, per spec.
      # Quoted so this arm matches the literal two-character token "/*" and is not
      # itself a glob (an unquoted /* would match almost every token above it).
      '/*') match=1 ;;
    esac
    [ "$match" -eq 1 ] ||
      { printf 'unlisted absolute path token in entry (%s): %s\n' "$tok_role" "$tok" >&2; bad_tokens=$((bad_tokens + 1)); }
  done
  set +f
  if [ "$bad_tokens" -eq 0 ]; then
    pass_case 'mechanism: entry contains no absolute-path token outside the fifteen-command / data / dynamic-join allowlist, role-checked'
  else
    fail_case "mechanism: entry has $bad_tokens unlisted absolute-path token(s)"
  fi

  # Negative controls (round-4 review): a standalone dynamic-join fragment
  # ("/tmp" with no preceding variable), and an out-of-range /dev/fd/N that
  # is not one of the three exact entries the entry itself ever emits, must
  # both be rejected by the role-aware sweep above -- proven by running it
  # through the same function rather than trusting the allowlist by
  # inspection. /usr/bin/awk direct execution (COMMAND position, never
  # ARGUMENT position, for the entry) is proven rejected by the
  # command-position sweep's negative controls further below.
  sap_neg_dir="$tmp/sweep-negative"; /bin/mkdir -m 700 "$sap_neg_dir"

  sap_neg_tmp="$sap_neg_dir/bare-tmp.sh"
  printf '%s\n' '/bin/rm -rf /tmp' > "$sap_neg_tmp"
  sap_neg_tmp_bad=0
  set -f
  for tok_raw in $(sweep_absolute_paths "$sap_neg_tmp"); do
    case "$tok_raw" in
      /*) tok_role=standalone; tok=$tok_raw ;;
      *) tok_role=joined; tok=${tok_raw#?} ;;
    esac
    match=0
    case "$tok_role" in
      standalone) for w in $allowlist_words $allowlist_data; do [ "$tok" = "$w" ] && match=1 && break; done ;;
      joined) for w in $allowlist_words $allowlist_data $allowlist_dynamic_joins; do [ "$tok" = "$w" ] && match=1 && break; done ;;
    esac
    [ "$tok" = '/*' ] && match=1
    [ "$match" -eq 1 ] || sap_neg_tmp_bad=$((sap_neg_tmp_bad + 1))
  done
  set +f
  if [ "$sap_neg_tmp_bad" -gt 0 ]; then
    pass_case 'mechanism: role-aware sweep rejects a bare standalone "/tmp" argument (not a $var/tmp join)'
  else
    fail_case 'mechanism: role-aware sweep failed to reject a bare standalone "/tmp" argument'
  fi

  sap_neg_devfd="$sap_neg_dir/dev-fd-n.sh"
  printf '%s\n' '/bin/cat /dev/fd/42' > "$sap_neg_devfd"
  sap_neg_devfd_bad=0
  set -f
  for tok_raw in $(sweep_absolute_paths "$sap_neg_devfd"); do
    case "$tok_raw" in
      /*) tok_role=standalone; tok=$tok_raw ;;
      *) tok_role=joined; tok=${tok_raw#?} ;;
    esac
    match=0
    case "$tok_role" in
      standalone) for w in $allowlist_words $allowlist_data; do [ "$tok" = "$w" ] && match=1 && break; done ;;
      joined) for w in $allowlist_words $allowlist_data $allowlist_dynamic_joins; do [ "$tok" = "$w" ] && match=1 && break; done ;;
    esac
    [ "$tok" = '/*' ] && match=1
    [ "$match" -eq 1 ] || sap_neg_devfd_bad=$((sap_neg_devfd_bad + 1))
  done
  set +f
  if [ "$sap_neg_devfd_bad" -gt 0 ]; then
    pass_case 'mechanism: role-aware sweep rejects an out-of-range /dev/fd/42 argument (only /dev/fd, /dev/fd/*, /dev/fd/2 are pinned)'
  else
    fail_case 'mechanism: role-aware sweep failed to reject an out-of-range /dev/fd/42 argument'
  fi

  # Round-5 review: the sweep above ran only on the shell entry; R10 also
  # requires the C parent's own pathname strings and exec-family/open-family
  # call sites to be swept, or an unlisted host path or an extra direct exec
  # in trusted-launch.c can escape this gate. Comments are stripped first
  # (multi-line /* */ blocks, C's only comment form here) and #include
  # lines are excluded (a source-role carve-out for system-header names,
  # same idea as the entry's full-line "#" comment carve-out above), then
  # the same context-aware token regex used on the entry is applied to what
  # remains, hand-verified against every quoted absolute-path string
  # literal trusted-launch.c actually contains.
  c_strip_comments_and_includes() {
    /usr/bin/perl -0777 -pe 's{/\*.*?\*/}{}gs' "$1" | /usr/bin/grep -Ev '^[[:space:]]*#include'
  }

  # Standalone C string literals the shell's own allowlists do not already
  # cover: the repo-root suffix constant "/resolver/v1", and "/bin"/
  # "/usr/bin" as they appear split off the parent's fixed
  # "PATH=/usr/bin:/bin" / "%s:/usr/bin:/bin" literals (the shell's own
  # allowlist_data does not list these two standalone -- it only lists them
  # as dynamic-join tail fragments, which does not apply here since these
  # are not "$var/join" tails in the C source).
  allowlist_data_parent="/resolver/v1 /bin /usr/bin"
  # /dev/null is shell-only (plan.md:351-357), never a C path/execve arg.
  allowlist_data_parent_c=${allowlist_data/ \/dev\/null/}
  # The one C-only combined join the shell's per-field joins don't cover:
  # build_pin_path()'s single snprintf spells the whole modules path in one
  # format string, "%s/core/v%s/generations/%s/modules/%s.jq", rather than
  # the entry's separate "$modules_dir/schema.jq" etc. concatenations.
  allowlist_dynamic_joins_parent='/core/v%s/generations/%s/modules/%s.jq'

  sweep_parent_pathnames() {
    spp_file=$1
    spp_stripped=$(c_strip_comments_and_includes "$spp_file")
    { printf '%s\n' "$spp_stripped" | /usr/bin/grep -Eo '[A-Za-z0-9_}%]?(/[A-Za-z0-9_.%*-]+)+'
      # a bare quoted "/" has no char after its slash, invisible above.
      printf '%s\n' "$spp_stripped" | /usr/bin/grep -q '"/"' && printf '/\n'
    } | /usr/bin/sort -u
  }

  parent_callsite_count() {
    c_strip_comments_and_includes "$1" |
      /usr/bin/grep -cEo '\b(execve|execv[a-z]*|posix_spawn[a-z]*|openat|open|fopen|readlink|stat|lstat|fstat|fstatat|access|opendir)[[:space:]]*\(' \
      || :
  }

  # parent_sweep_bad_count FILE -- echoes FILE's unlisted-token count.
  parent_sweep_bad_count() {
    psb_bad=0
    set -f
    for ptok_raw in $(sweep_parent_pathnames "$1"); do
      case "$ptok_raw" in
        /*) ptok_role=standalone; ptok=$ptok_raw ;;
        *) ptok_role=joined; ptok=${ptok_raw#?} ;;
      esac
      pmatch=0
      case "$ptok_role" in
        standalone) psb_list="$allowlist_words $allowlist_data_parent_c $allowlist_data_parent" ;;
        joined) psb_list="$allowlist_words $allowlist_data_parent_c $allowlist_dynamic_joins $allowlist_dynamic_joins_parent" ;;
      esac
      for w in $psb_list; do [ "$ptok" = "$w" ] && pmatch=1 && break; done
      [ "$pmatch" -eq 1 ] ||
        { printf 'unlisted absolute path token in parent (%s): %s\n' "$ptok_role" "$ptok" >&2
          psb_bad=$((psb_bad + 1)); }
    done
    set +f
    printf '%s\n' "$psb_bad"
  }

  if [ -f "$parent_source" ]; then
    parent_bad_tokens=$(parent_sweep_bad_count "$parent_source")
    if [ "$parent_bad_tokens" -eq 0 ]; then
      pass_case 'mechanism: parent (trusted-launch.c) contains no absolute-path string literal outside the hand-verified allowlist'
    else
      fail_case "mechanism: parent has $parent_bad_tokens unlisted absolute-path token(s)"
    fi

    parent_baseline_callsites=$(parent_callsite_count "$parent_source")

    parent_neg_dir="$tmp/parent-sweep-negative"; /bin/mkdir -m 700 "$parent_neg_dir"

    # Negative control: an unlisted absolute path literal must be rejected.
    parent_neg_path="$parent_neg_dir/unlisted-path.c"
    /bin/cp -- "$parent_source" "$parent_neg_path"
    printf '%s\n' 'static const char *const YSTACK_TEST_UNLISTED = "/tmp/evil-unlisted-path";' >> "$parent_neg_path"
    parent_neg_path_bad=$(parent_sweep_bad_count "$parent_neg_path")
    if [ "$parent_neg_path_bad" -gt 0 ]; then
      pass_case 'mechanism: parent pathname sweep rejects an unlisted absolute path literal added to a fixture copy'
    else
      fail_case 'mechanism: parent pathname sweep failed to reject an unlisted absolute path literal'
    fi

    parent_neg_root="$parent_neg_dir/root-path.c"
    /bin/cp -- "$parent_source" "$parent_neg_root"
    printf '%s\n' 'static void ystack_test_root(void) { open("/", O_RDONLY); }' >> "$parent_neg_root"
    parent_neg_root_bad=$(parent_sweep_bad_count "$parent_neg_root")
    if [ "$parent_neg_root_bad" -gt 0 ]; then
      pass_case 'mechanism: parent pathname sweep rejects a quoted root path literal added to a fixture copy'
    else
      fail_case 'mechanism: parent pathname sweep failed to reject a quoted root path literal'
    fi
    parent_neg_devnull="$parent_neg_dir/devnull-path.c"
    /bin/cp -- "$parent_source" "$parent_neg_devnull"
    printf '%s\n' 'static void ystack_test_devnull(void) { open("/dev/null", O_WRONLY); }' >> "$parent_neg_devnull"
    parent_neg_devnull_bad=$(parent_sweep_bad_count "$parent_neg_devnull")
    if [ "$parent_neg_devnull_bad" -gt 0 ]; then
      pass_case 'mechanism: parent pathname sweep rejects a /dev/null pathname literal added to a fixture copy'
    else
      fail_case 'mechanism: parent pathname sweep failed to reject a /dev/null pathname literal'
    fi

    # Negative control: an extra direct exec-family call site (beyond the
    # hand-verified baseline count) must be visible to the call-site
    # inventory, not silently absorbed.
    parent_neg_exec="$parent_neg_dir/extra-execve.c"
    /bin/cp -- "$parent_source" "$parent_neg_exec"
    printf '%s\n' 'static void ystack_test_extra(char **argv, char **envp) { execve("/usr/bin/evil", argv, envp); }' >> "$parent_neg_exec"
    parent_neg_exec_callsites=$(parent_callsite_count "$parent_neg_exec")
    if [ "$parent_neg_exec_callsites" -gt "$parent_baseline_callsites" ]; then
      pass_case 'mechanism: parent exec/open call-site inventory detects an extra execve call site added to a fixture copy'
    else
      fail_case 'mechanism: parent exec/open call-site inventory failed to detect an extra execve call site'
    fi
  else
    fail_case 'mechanism: parent pathname sweep (parent source absent)'
  fi

  builtins=$(/bin/bash -c 'compgen -b')
  reserved=$(/bin/bash -c 'compgen -k')
  # The entry's own two callable-bare functions (spec.md:8801-8940's three-pass
  # extraction has a source-role carve-out for a script's own defined names).
  cps_functions='checkpoint refuse'
  # The two fixed, closed-content arrays this entry uses to env-wrap a real
  # command (clean_env=(/usr/bin/env -i ...), parent_env=(/usr/bin/env -i
  # ...)) -- always exactly /usr/bin/env at runtime (already an allowlisted
  # absolute-path command above), never reassigned, so "${clean_env[@]}" /
  # "${parent_env[@]}" in command position is a recognised, closed idiom
  # rather than an unresolvable bare variable.
  cps_env_wrappers='${clean_env[@]} ${parent_env[@]}'
  # The command word actually launched THROUGH an env wrapper, once it is
  # peeled away rather than short-circuited on: the entry's own fixed,
  # never-reassigned scalar/array references that name an already-verified
  # or already-pinned program ($compiler after the -x check, $jq_arg after
  # its SHA-256/--version identity checks, and the two fixed sha1sum/
  # sha256sum argv arrays) -- a closed idiom the same way the wrappers
  # themselves are. Anything else surfacing here after peeling is a real,
  # unexamined command word and must fall through to ordinary
  # classification.
  cps_verified_vars='$compiler $jq_arg ${sha1_args[@]} ${sha256_args[@]}'
  # Variable-joined suffixes the entry legitimately EXECUTES (command
  # position), a strict subset of allowlist_dynamic_joins above: the entry
  # runs the compiled parent at "$run/trusted-launch" (resolve-profile.sh)
  # and passes "$run/awk", "$run/jq", "$run/nofollow-snapshot" onward as
  # argv strings for the parent to exec, never execing them itself.
  cps_command_dynamic_joins='/trusted-launch'

  # cps_scan_source FILE -- the lexical extraction the prior draft deferred:
  # strips full-line comments and heredoc bodies (data, never a command
  # position), then walks every logical line, recursively queuing the body
  # of each $(...) / `...` command substitution as a further line to scan,
  # and splitting on unquoted ; & | && || into one command position per
  # segment (quote-tracked, so an operator character inside a quoted
  # argument is not mistaken for a separator). Each segment's leading word
  # has one layer of surrounding quotes unwrapped (never skipped wholesale --
  # that let a quoted or variable-led token through unexamined) and any
  # leading VAR=value assignments or exec/command prefix words are peeled
  # so the position actually naming the program is what gets classified.
  # Prints one finding line per rejected or unresolved command word to
  # stdout; silence means the file passed.
  cps_count_trailing_backslashes() {
    # Portable to bash 3.2 (macOS's shipped bash): no negative substring
    # offsets, no mapfile.
    cps_ctb_s=$1 cps_ctb_n=0
    cps_ctb_len=${#cps_ctb_s}
    while [ "$cps_ctb_len" -gt 0 ]; do
      cps_ctb_last=${cps_ctb_s:$((cps_ctb_len - 1)):1}
      [ "$cps_ctb_last" = "\\" ] || break
      cps_ctb_n=$((cps_ctb_n + 1))
      cps_ctb_len=$((cps_ctb_len - 1))
    done
    printf '%s' "$cps_ctb_n"
  }

  cps_classify_command() {
    # Classifies the command whose (quote-tokenized) words are in the global
    # cps_cmd_words array, printing a finding line for anything rejected or
    # unresolved. Called with an empty array between operators (e.g. "a &&
    # && b") and at end-of-line; both are no-ops.
    [ "${#cps_cmd_words[@]}" -gt 0 ] || return 0
    case "${cps_cmd_words[0]}" in
      [A-Za-z_][A-Za-z0-9_]*=\(*|[A-Za-z_][A-Za-z0-9_]*+=\(*)
        # VAR=(...) / VAR+=(...) array-literal assignment: the whole
        # statement IS the assignment, there is no following command word
        # to peel toward (unlike "VAR=value realcmd args"), whether the
        # literal closes on this line (e.g. stat_owner_mode=(-c '%u %a'))
        # or was opened by the multi-line-array skip pass below.
        return 0
        ;;
    esac
    cps_first=''
    cps_wi=0
    while [ "$cps_wi" -lt "${#cps_cmd_words[@]}" ]; do
      cps_w=${cps_cmd_words[$cps_wi]}
      case "$cps_w" in
        \"*) cps_w=${cps_w#\"}; cps_w=${cps_w%\"} ;;
        \'*) cps_w=${cps_w#\'}; cps_w=${cps_w%\'} ;;
      esac
      # A pure descriptor duplication word (">&2", "8<&0", "8>&\"\$saved\"",
      # ...) names no command -- peel it too, same as exec/command/env.
      if [[ $cps_w =~ ^[0-9]*[\<\>]\&?([0-9-]*|[\'\"][^\'\"]*[\'\"])$ ]]; then
        cps_wi=$((cps_wi + 1)); continue
      fi
      case "$cps_w" in
        [A-Za-z_][A-Za-z0-9_]*=*|exec|command|env)
          cps_wi=$((cps_wi + 1)); continue ;;
        # A compound-statement introducer (if/while/until's condition
        # position, then/elif/else/do's body position) names no command
        # itself -- it is not a builtin invocation, it is shell grammar --
        # so it must be peeled the same way exec/command/env are, rather
        # than accepted as a known reserved word with the real command
        # word that follows it left unexamined. "for" is deliberately not
        # here: the word right after "for" is a loop variable name, never
        # a command position (its own body starts after "do", its own
        # separate segment).
        if|then|elif|else|while|until|do)
          cps_wi=$((cps_wi + 1)); continue ;;
      esac
      # An env-wrapper prefix ("${clean_env[@]}"/"${parent_env[@]}") names
      # the wrapper, not the command it launches -- peel it and keep
      # looking, the same as exec/command/env above, rather than accepting
      # the whole statement here: that earlier short-circuit is exactly
      # what let a wrapped unallowlisted command through undetected.
      cps_env_wrapper_match=0
      for cps_wv in $cps_env_wrappers; do [ "$cps_w" = "$cps_wv" ] && cps_env_wrapper_match=1 && break; done
      if [ "$cps_env_wrapper_match" -eq 1 ]; then
        cps_wi=$((cps_wi + 1)); continue
      fi
      cps_first=$cps_w
      break
    done
    [ -n "$cps_first" ] || return 0

    # "eval STRING" and "bash -c STRING" / "sh -c STRING" (bare or
    # absolute-path) run STRING as a further command list, not as data --
    # the same treatment as a trap body or a $(...) substitution above.
    # This runs before the absolute-path early-return below so an
    # absolute-path "/bin/bash -c ..." still gets its STRING argument
    # queued (the /bin/bash word itself is still separately allowlisted).
    case "$cps_first" in
      eval)
        cps_eval_i=$((cps_wi + 1))
        if [ "$cps_eval_i" -lt "${#cps_cmd_words[@]}" ]; then
          cps_eval_arg=${cps_cmd_words[$cps_eval_i]}
          case "$cps_eval_arg" in
            \"*) cps_eval_arg=${cps_eval_arg#\"}; cps_eval_arg=${cps_eval_arg%\"} ;;
            \'*) cps_eval_arg=${cps_eval_arg#\'}; cps_eval_arg=${cps_eval_arg%\'} ;;
          esac
          [ -n "$cps_eval_arg" ] && cps_queue+=("$cps_eval_arg")
        fi
        return 0
        ;;
      bash|sh|*/bash|*/sh)
        cps_shc_i=$((cps_wi + 1))
        if [ "$cps_shc_i" -lt "${#cps_cmd_words[@]}" ] && [ "${cps_cmd_words[$cps_shc_i]}" = '-c' ]; then
          cps_shc_arg_i=$((cps_shc_i + 1))
          if [ "$cps_shc_arg_i" -lt "${#cps_cmd_words[@]}" ]; then
            cps_shc_arg=${cps_cmd_words[$cps_shc_arg_i]}
            case "$cps_shc_arg" in
              \"*) cps_shc_arg=${cps_shc_arg#\"}; cps_shc_arg=${cps_shc_arg%\"} ;;
              \'*) cps_shc_arg=${cps_shc_arg#\'}; cps_shc_arg=${cps_shc_arg%\'} ;;
            esac
            [ -n "$cps_shc_arg" ] && cps_queue+=("$cps_shc_arg")
          fi
        fi
        ;;
    esac

    case "$cps_first" in
      ')'|'{'*|'}'*) return 0 ;;
      # Round-4 review: this file's own COMMAND-position role check.
      # sweep_absolute_paths above is a whole-file token census that cannot
      # tell "/bin/rm" naming a program from "/tmp" naming a doomed
      # argument, so it accepted anything on the combined word/data/join
      # list regardless of role. Here the word IS known to be in command
      # position (that is what this function extracts), so a literal
      # absolute-path command word must be one of the fifteen allowlisted
      # programs -- never merely an allowlisted DATA path or dynamic-join
      # fragment, both of which are legitimate only as arguments.
      /*)
        cps_cmdpath_match=0
        for cps_cwv in $allowlist_words; do [ "$cps_first" = "$cps_cwv" ] && cps_cmdpath_match=1 && break; done
        [ "$cps_cmdpath_match" -eq 1 ] || printf 'unallowlisted absolute-path command word: %s\n' "$cps_first"
        return 0
        ;;
      # A variable-joined command word (e.g. "$run/trusted-launch") is only
      # legitimate in command position for the entry's own pinned helper
      # suffixes it actually execs -- narrower than the full dynamic-join
      # data allowlist above, which also covers suffixes the entry only
      # ever passes as arguments (e.g. "$run/awk", "$run/jq" are exec'd by
      # the parent, not by this shell).
      *'/'*)
        cps_cmdjoin_match=0
        for cps_cjv in $cps_command_dynamic_joins; do
          case "$cps_first" in
            *"$cps_cjv") cps_cmdjoin_match=1; break ;;
          esac
        done
        [ "$cps_cmdjoin_match" -eq 1 ] || printf 'unallowlisted variable-joined command word: %s\n' "$cps_first"
        return 0
        ;;
      # A bare "exec FD>&-" / "exec FD<&-" closes a descriptor and names no
      # command at all -- this tokenizer has no separate redirection-operator
      # handling, so a fd-close target like "${fd_name}>&-" (surfaced once
      # the eval-string case above started queuing "exec ${fd_name}>&-" from
      # the entry's own descriptor-closing loop) lands here as if it were the
      # command word. It is a redirection target, not a command; return 0 the
      # same way the VAR=(...) array-literal case above does.
      *'>&-'|*'<&-') return 0 ;;
    esac
    cps_verified_match=0
    for cps_vv in $cps_verified_vars; do [ "$cps_first" = "$cps_vv" ] && cps_verified_match=1 && break; done
    [ "$cps_verified_match" -eq 1 ] && return 0
    case "$cps_first" in
      \$*)
        printf 'unresolvable variable command word: %s\n' "$cps_first"
        return 0
        ;;
    esac
    case "$cps_first" in
      checkpoint|refuse) return 0 ;;
    esac
    cps_known=0
    for cps_b in $builtins; do [ "$cps_first" = "$cps_b" ] && cps_known=1 && break; done
    if [ "$cps_known" -ne 1 ]; then
      for cps_r in $reserved; do [ "$cps_first" = "$cps_r" ] && cps_known=1 && break; done
    fi
    if [ "$cps_known" -ne 1 ]; then
      for cps_f in $cps_functions; do [ "$cps_first" = "$cps_f" ] && cps_known=1 && break; done
    fi
    if [ "$cps_known" -ne 1 ]; then
      printf 'unallowlisted bare command: %s\n' "$cps_first"
    fi
    return 0
  }

  cps_extract_case_oneline_arms() {
    # cps_extract_case_oneline_arms LINE -- for a self-contained one-line
    # "case WORD in PAT) CMD ;; PAT2) CMD2 ;; esac", queues each arm's
    # command body onto cps_queue (global) so a command hidden in a
    # one-line case arm is classified like any other command position.
    # Quote-tracked throughout, same as the tokenizer above.
    cps_ol_line=$1
    case "$cps_ol_line" in
      'case '*|*' case '*) : ;;
      *) return 0 ;;
    esac
    cps_ol_rest=${cps_ol_line#*case }
    case "$cps_ol_rest" in
      *' in '*) cps_ol_rest=${cps_ol_rest#*' in '} ;;
      *) return 0 ;;
    esac
    while :; do
      # Find the next unquoted ")" -- the end of this arm's pattern.
      cps_ol_i=0 cps_ol_len=${#cps_ol_rest} cps_ol_inq='' cps_ol_paren=0 cps_ol_close=-1
      while [ "$cps_ol_i" -lt "$cps_ol_len" ]; do
        cps_ol_c=${cps_ol_rest:$cps_ol_i:1}
        if [ -n "$cps_ol_inq" ]; then
          [ "$cps_ol_c" = "$cps_ol_inq" ] && cps_ol_inq=''
        else
          case "$cps_ol_c" in
            \'|\") cps_ol_inq=$cps_ol_c ;;
            '(') cps_ol_paren=$((cps_ol_paren + 1)) ;;
            ')')
              if [ "$cps_ol_paren" -gt 0 ]; then
                cps_ol_paren=$((cps_ol_paren - 1))
              else
                cps_ol_close=$cps_ol_i
              fi
              ;;
          esac
        fi
        [ "$cps_ol_close" -ge 0 ] && break
        cps_ol_i=$((cps_ol_i + 1))
      done
      [ "$cps_ol_close" -ge 0 ] || break
      cps_ol_rest=${cps_ol_rest:$((cps_ol_close + 1))}

      # Find the next unquoted ";;" -- the end of this arm's command body
      # -- or, absent one, treat up to "esac" as the last arm's body.
      cps_ol_j=0 cps_ol_jlen=${#cps_ol_rest} cps_ol_inq='' cps_ol_semi=-1
      while [ "$cps_ol_j" -lt "$cps_ol_jlen" ]; do
        cps_ol_c=${cps_ol_rest:$cps_ol_j:1}
        if [ -n "$cps_ol_inq" ]; then
          [ "$cps_ol_c" = "$cps_ol_inq" ] && cps_ol_inq=''
        else
          case "$cps_ol_c" in
            \'|\") cps_ol_inq=$cps_ol_c ;;
            ';')
              [ "${cps_ol_rest:$((cps_ol_j + 1)):1}" = ';' ] && cps_ol_semi=$cps_ol_j
              ;;
          esac
        fi
        [ "$cps_ol_semi" -ge 0 ] && break
        cps_ol_j=$((cps_ol_j + 1))
      done
      if [ "$cps_ol_semi" -ge 0 ]; then
        cps_ol_body=${cps_ol_rest:0:$cps_ol_semi}
        cps_ol_rest=${cps_ol_rest:$((cps_ol_semi + 2))}
      else
        case "$cps_ol_rest" in
          *esac*) cps_ol_body=${cps_ol_rest%%esac*} ;;
          *) cps_ol_body=$cps_ol_rest ;;
        esac
        cps_ol_rest=''
      fi
      [ -n "${cps_ol_body//[[:space:]]/}" ] && cps_queue+=("$cps_ol_body")
    done
    return 0
  }

  cps_scan_source() {
    cps_file=$1

    # Pass 1: join backslash-continued physical lines (an odd number of
    # trailing backslashes is a real continuation; an even number is that
    # many literal, already-escaped backslashes) AND a quoted argument that
    # itself spans multiple physical lines (e.g. the EXIT trap's multi-line
    # single-quoted body below) into one logical line. A quote-span join
    # uses ";" for the erased real newline (a trap body IS decomposed into
    # command positions below, where a newline is a statement separator);
    # a backslash-continuation join keeps the shell's own plain-space splice.
    cps_physical=()
    while IFS= read -r cps_pl || [ -n "$cps_pl" ]; do cps_physical+=("$cps_pl"); done < "$cps_file"
    cps_logical=() cps_acc='' cps_acc_active=0 cps_mlq='' cps_acc_sep=''
    for cps_pl in "${cps_physical[@]}"; do
      if [ "$cps_acc_active" -eq 1 ]; then cps_pl="$cps_acc$cps_acc_sep$cps_pl"; fi
      cps_acc='' cps_acc_active=0

      # Always re-derive quote state from the start of cps_pl, never seeded
      # from cps_mlq: once a line has been joined onto its accumulator, it
      # already contains the full text back to the point the quote first
      # opened, so re-scanning it from scratch is what re-derives the
      # correct state -- seeding with "already inside" here would treat
      # that same, now-repeated opening quote character as the CLOSING one.
      cps_qc_i=0 cps_qc_len=${#cps_pl} cps_qc_inq=''
      while [ "$cps_qc_i" -lt "$cps_qc_len" ]; do
        cps_qc_c=${cps_pl:$cps_qc_i:1}
        if [ -n "$cps_qc_inq" ]; then
          [ "$cps_qc_c" = "$cps_qc_inq" ] && cps_qc_inq=''
        else
          case "$cps_qc_c" in
            \'|\") cps_qc_inq=$cps_qc_c ;;
            '#')
              # An unquoted '#' starting a word (line start, or preceded by
              # whitespace) opens a comment: an apostrophe in ordinary prose
              # after it (e.g. "the entry's own") must never be mistaken for
              # the start of a quoted span. Nothing past it is code, so stop
              # scanning this line for quote balance right here.
              if [ "$cps_qc_i" -eq 0 ]; then
                cps_qc_i=$cps_qc_len
                break
              fi
              case "${cps_pl:$((cps_qc_i - 1)):1}" in
                ' '|$'\t') cps_qc_i=$cps_qc_len; break ;;
              esac
              ;;
          esac
        fi
        cps_qc_i=$((cps_qc_i + 1))
      done
      cps_mlq=$cps_qc_inq
      if [ -n "$cps_mlq" ]; then
        cps_acc=$cps_pl; cps_acc_active=1; cps_acc_sep=';'
        continue
      fi

      case "$cps_pl" in
        *\\)
          if [ $(( $(cps_count_trailing_backslashes "$cps_pl") % 2 )) -eq 1 ]; then
            cps_acc=${cps_pl%?}; cps_acc_active=1; cps_acc_sep=' '
            continue
          fi
          ;;
      esac
      cps_logical+=("$cps_pl")
    done
    [ "$cps_acc_active" -eq 1 ] && cps_logical+=("$cps_acc")

    # Pass 2: strip heredoc bodies (data, never a command position) and the
    # element lines of a multi-line array literal such as
    # "pin_hexes=(\n  hash\n  ...\n)" (also data -- a single-line array
    # literal like "sha1_args=(/usr/bin/sha1sum)" is instead recognised and
    # skipped whole in cps_classify_command above).
    cps_skip_heredoc='' cps_strip_tabs=0 cps_skip_array=0
    cps_queue=()
    for cps_raw in "${cps_logical[@]}"; do
      if [ -n "$cps_skip_heredoc" ]; then
        cps_cmp=$cps_raw
        if [ "$cps_strip_tabs" -eq 1 ]; then
          while [ "${cps_cmp:0:1}" = $'\t' ]; do cps_cmp=${cps_cmp:1}; done
        fi
        [ "$cps_cmp" = "$cps_skip_heredoc" ] && cps_skip_heredoc=''
        continue
      fi
      if [ "$cps_skip_array" -eq 1 ]; then
        cps_trim=${cps_raw#"${cps_raw%%[![:space:]]*}"}
        cps_trim=${cps_trim%"${cps_trim##*[![:space:]]}"}
        [ "$cps_trim" = ')' ] && cps_skip_array=0
        continue
      fi
      if [[ $cps_raw =~ \<\<-?[[:space:]]*[\'\"]?([A-Za-z_][A-Za-z0-9_]*)[\'\"]? ]]; then
        cps_skip_heredoc=${BASH_REMATCH[1]}
        case "$cps_raw" in *'<<-'*) cps_strip_tabs=1 ;; *) cps_strip_tabs=0 ;; esac
      fi
      cps_trim=${cps_raw#"${cps_raw%%[![:space:]]*}"}
      cps_trim=${cps_trim%"${cps_trim##*[![:space:]]}"}
      case "$cps_trim" in
        [A-Za-z_][A-Za-z0-9_]*=\(|[A-Za-z_][A-Za-z0-9_]*+=\() cps_skip_array=1 ;;
      esac
      cps_queue+=("$cps_raw")
    done

    # Pass 3: walk the queue (gaining more entries as $(...) / `...`
    # substitution bodies are found and queued too), tracking case/esac
    # depth so a case arm's pattern ("Linux:x86_64)", "0|1|2)", ...) is
    # recognised and skipped rather than misread as a bare command -- only
    # the text after the pattern's closing, unquoted ")" is a real command
    # position.
    cps_case_depth=0 cps_await_pattern=0
    cps_qi=0
    while [ "$cps_qi" -lt "${#cps_queue[@]}" ]; do
      cps_line=${cps_queue[$cps_qi]}
      cps_qi=$((cps_qi + 1))
      case "$cps_line" in ''|[[:space:]]*'#'*|'#'*) continue ;; esac
      # A function definition header (e.g. "refuse() {") names the function
      # being declared, not a command being invoked.
      case "$cps_line" in *'() {'*) continue ;; esac

      cps_trim=${cps_line#"${cps_line%%[![:space:]]*}"}
      cps_trim=${cps_trim%"${cps_trim##*[![:space:]]}"}

      # A "trap 'BODY' SIG" (or double-quoted) statement's quoted argument
      # is itself a command list that runs later -- by pass 1 above it is
      # already one physical line even when the source wrote it across
      # several, so its content is queued here exactly like a $(...) body,
      # and the executable it names is classified like any other command.
      # A "trap "" SIG..." re-disarm has an empty body and queues nothing.
      case "$cps_trim" in
        trap[[:space:]]*)
          cps_trap_rest=${cps_trim#trap}
          cps_trap_rest=${cps_trap_rest#"${cps_trap_rest%%[![:space:]]*}"}
          cps_trap_body=''
          case "$cps_trap_rest" in
            \'*)
              cps_trap_body=${cps_trap_rest#\'}
              cps_trap_body=${cps_trap_body%%\'*}
              ;;
            \"*)
              cps_trap_body=${cps_trap_rest#\"}
              cps_trap_body=${cps_trap_body%%\"*}
              ;;
          esac
          [ -n "$cps_trap_body" ] && cps_queue+=("$cps_trap_body")
          ;;
      esac

      cps_padded=" $cps_trim "
      cps_has_case=0; case "$cps_padded" in *' case '*) cps_has_case=1 ;; esac
      cps_has_esac=0; case "$cps_padded" in *' esac '*) cps_has_esac=1 ;; esac

      if [ "$cps_has_case" -eq 1 ] && [ "$cps_has_esac" -eq 1 ]; then
        # Self-contained "case ... in PAT) CMD ;; ... esac" all on one
        # physical line: queue each arm's command body (the text after the
        # pattern's closing, unquoted ")" up to the next unquoted ";;" or
        # "esac") for ordinary classification, rather than treating the
        # whole line as opaque -- that wholesale skip is exactly what let a
        # one-line case arm's command through unexamined.
        cps_extract_case_oneline_arms "$cps_line"
        continue
      fi

      cps_rest=$cps_line
      if [ "$cps_case_depth" -gt 0 ] && [ "$cps_await_pattern" -eq 1 ] && [ "$cps_has_case" -eq 0 ]; then
        # Same-physical-line case arms (round-12 review): stripping only
        # the first pattern and tokenizing the rest ordinarily mis-splits
        # "1|2)" on the pipe operator and misreads "2)"/"*)" as bare
        # commands. Reuse the one-line case/esac arm extractor (synthetic
        # "case x in" prefix) so every arm's body is queued correctly.
        cps_extract_case_oneline_arms "case x in $cps_line"
        cps_rest=''
        cps_await_pattern=0
      fi

      if [ "$cps_has_case" -eq 1 ]; then
        case "$cps_trim" in
          *[[:space:]]in) cps_case_depth=$((cps_case_depth + 1)); cps_await_pattern=1 ;;
        esac
      fi
      if [ "$cps_has_esac" -eq 1 ]; then
        [ "$cps_case_depth" -gt 0 ] && cps_case_depth=$((cps_case_depth - 1))
        cps_await_pattern=0
      fi

      # A process substitution (<(...) / >(...)) runs its body as a real
      # command list the same way $(...) does -- it is handed to the
      # calling command as a /dev/fd path, not as data -- so its body is
      # recursively queued here too, alongside command substitution and
      # backticks.
      while [[ $cps_rest =~ \$\(([^\(\)]*)\) ]] || [[ $cps_rest =~ \`([^\`]*)\` ]] ||
            [[ $cps_rest =~ [\<\>]\(([^\(\)]*)\) ]]; do
        cps_sub=${BASH_REMATCH[1]}
        cps_lit=${BASH_REMATCH[0]}
        [ -n "$cps_sub" ] && cps_queue+=("$cps_sub")
        cps_rest=${cps_rest/"$cps_lit"/ }
      done

      # Quote-tracked tokenizer: splits cps_rest into words and operators
      # (; & | && ||), keeping whitespace inside a quoted span from
      # breaking a word (e.g. -c '%u %a' is one word after -c, not two),
      # keeping whitespace inside an unquoted ${...} from doing the same
      # (e.g. ${var%% *} or ${run:?} is one word, not split at its own
      # internal space or ":"), and keeping an operator character inside
      # either from acting as one.
      cps_tok='' cps_toks=() cps_is_op=() cps_inq='' cps_brace=0 cps_paren=0 cps_i=0 cps_n=${#cps_rest}
      while [ "$cps_i" -lt "$cps_n" ]; do
        cps_c=${cps_rest:$cps_i:1}
        if [ -n "$cps_inq" ]; then
          cps_tok="$cps_tok$cps_c"
          [ "$cps_c" = "$cps_inq" ] && cps_inq=''
          cps_i=$((cps_i + 1)); continue
        fi
        if [ "$cps_brace" -gt 0 ]; then
          cps_tok="$cps_tok$cps_c"
          case "$cps_c" in
            '{') cps_brace=$((cps_brace + 1)) ;;
            '}') cps_brace=$((cps_brace - 1)) ;;
          esac
          cps_i=$((cps_i + 1)); continue
        fi
        if [ "$cps_c" = '{' ] && [ "$cps_i" -gt 0 ] && [ "${cps_rest:$((cps_i - 1)):1}" = '$' ]; then
          cps_brace=1
          cps_tok="$cps_tok$cps_c"
          cps_i=$((cps_i + 1)); continue
        fi
        # Parenthesis depth: protects the same way for "(...)" spans left
        # after the $(...) extraction pass above has already pulled out and
        # queued any inner command substitution -- e.g. "$((128 + $(...)))"
        # leaves the outer arithmetic's own "(( ... ))" behind, and its
        # internal space/operator characters ("128 +  )" ) must not be
        # mistaken for word or command-position boundaries.
        if [ "$cps_paren" -gt 0 ]; then
          cps_tok="$cps_tok$cps_c"
          case "$cps_c" in
            '(') cps_paren=$((cps_paren + 1)) ;;
            ')') cps_paren=$((cps_paren - 1)) ;;
          esac
          cps_i=$((cps_i + 1)); continue
        fi
        if [ "$cps_c" = '(' ]; then
          cps_paren=1
          cps_tok="$cps_tok$cps_c"
          cps_i=$((cps_i + 1)); continue
        fi
        case "$cps_c" in
          \'|\") cps_inq=$cps_c; cps_tok="$cps_tok$cps_c"; cps_i=$((cps_i + 1)); continue ;;
          ' '|$'\t')
            [ -n "$cps_tok" ] && { cps_toks+=("$cps_tok"); cps_is_op+=(0); cps_tok=''; }
            cps_i=$((cps_i + 1)); continue
            ;;
          '&')
            # A "&" immediately after ">" or "<" is part of a redirection
            # operator (">&2", "2>&1", "<&3", ...), not the background/AND
            # operator -- it names a target descriptor, never a command
            # position, so it stays part of the current (redirection) word.
            cps_tlen=${#cps_tok}
            cps_tok_last=${cps_tok:$((cps_tlen - 1)):1}
            if [ "$cps_tlen" -gt 0 ] && { [ "$cps_tok_last" = '>' ] || [ "$cps_tok_last" = '<' ]; }; then
              cps_tok="$cps_tok$cps_c"; cps_i=$((cps_i + 1)); continue
            fi
            [ -n "$cps_tok" ] && { cps_toks+=("$cps_tok"); cps_is_op+=(0); cps_tok=''; }
            cps_two=${cps_rest:$cps_i:2}
            case "$cps_two" in
              '&&') cps_toks+=("$cps_two"); cps_is_op+=(1); cps_i=$((cps_i + 2)) ;;
              *) cps_toks+=("$cps_c"); cps_is_op+=(1); cps_i=$((cps_i + 1)) ;;
            esac
            continue
            ;;
          ';'|'|')
            [ -n "$cps_tok" ] && { cps_toks+=("$cps_tok"); cps_is_op+=(0); cps_tok=''; }
            cps_two=${cps_rest:$cps_i:2}
            case "$cps_two" in
              '||') cps_toks+=("$cps_two"); cps_is_op+=(1); cps_i=$((cps_i + 2)) ;;
              *) cps_toks+=("$cps_c"); cps_is_op+=(1); cps_i=$((cps_i + 1)) ;;
            esac
            continue
            ;;
        esac
        cps_tok="$cps_tok$cps_c"
        cps_i=$((cps_i + 1))
      done
      [ -n "$cps_tok" ] && { cps_toks+=("$cps_tok"); cps_is_op+=(0); }

      cps_cmd_words=()
      cps_ti=0
      while [ "$cps_ti" -lt "${#cps_toks[@]}" ]; do
        if [ "${cps_is_op[$cps_ti]}" -eq 1 ]; then
          cps_classify_command
          cps_cmd_words=()
        else
          cps_cmd_words+=("${cps_toks[$cps_ti]}")
        fi
        cps_ti=$((cps_ti + 1))
      done
      cps_classify_command

      case "$cps_line" in *';;'*) [ "$cps_case_depth" -gt 0 ] && cps_await_pattern=1 ;; esac
    done
    return 0
  }

  cps_findings=$(cps_scan_source "$entry")
  if [ -z "$cps_findings" ]; then
    pass_case 'mechanism: bare-word command-position sweep finds no unallowlisted command in the shipped entry'
  else
    printf '%s\n' "$cps_findings" | while IFS= read -r cps_finding; do
      printf 'command-position sweep: %s\n' "$cps_finding" >&2
    done
    cps_violations=$(printf '%s\n' "$cps_findings" | /usr/bin/grep -c .)
    fail_case "mechanism: bare-word command-position sweep found $cps_violations unallowlisted command word(s)"
  fi

  # Prove the sweep can actually reject something, by running the fixture
  # THROUGH the extractor above (not just the bare membership test) -- an
  # indented unallowlisted command, one reached only after peeling an
  # "exec" prefix, and one reached only after an unquoted "&&" separator.
  # Without this, a sweep whose extraction silently drops these shapes (as
  # the prior draft's "${line%% *}" and lack of substitution/operator
  # splitting did) would be indistinguishable from one that genuinely
  # enforces the allowlist.
  cps_neg_dir="$tmp/cps-negative"; /bin/mkdir -m 700 "$cps_neg_dir"

  cps_neg_indented="$cps_neg_dir/indented.sh"
  printf '%s\n' '    an-unallowlisted-indented-command --flag' > "$cps_neg_indented"
  cps_neg_indented_findings=$(cps_scan_source "$cps_neg_indented")
  case "$cps_neg_indented_findings" in
    *an-unallowlisted-indented-command*)
      pass_case 'mechanism: command-position sweep rejects an indented unallowlisted command' ;;
    *)
      fail_case 'mechanism: command-position sweep failed to reject an indented unallowlisted command' ;;
  esac

  cps_neg_exec="$cps_neg_dir/exec.sh"
  printf '%s\n' 'exec an-unallowlisted-exec-target "$@"' > "$cps_neg_exec"
  cps_neg_exec_findings=$(cps_scan_source "$cps_neg_exec")
  case "$cps_neg_exec_findings" in
    *an-unallowlisted-exec-target*)
      pass_case 'mechanism: command-position sweep rejects a command reached via an exec prefix' ;;
    *)
      fail_case 'mechanism: command-position sweep failed to reject a command reached via an exec prefix' ;;
  esac

  cps_neg_and="$cps_neg_dir/and.sh"
  printf '%s\n' 'checkpoint && an-unallowlisted-command-after-and' > "$cps_neg_and"
  cps_neg_and_findings=$(cps_scan_source "$cps_neg_and")
  case "$cps_neg_and_findings" in
    *an-unallowlisted-command-after-and*)
      pass_case 'mechanism: command-position sweep rejects a command reached only after an unquoted &&' ;;
    *)
      fail_case 'mechanism: command-position sweep failed to reject a command reached only after an unquoted &&' ;;
  esac

  # Three more shapes round-2 review found the extractor blind to: the
  # executable an env-wrapper array actually launches, the executable
  # string inside a "trap '...' SIG" body, and a command hidden in a
  # one-line "case ... ) CMD ;; esac" arm.
  cps_neg_envwrap="$cps_neg_dir/envwrap.sh"
  printf '%s\n' '"${clean_env[@]}" unallowlisted_command' > "$cps_neg_envwrap"
  cps_neg_envwrap_findings=$(cps_scan_source "$cps_neg_envwrap")
  case "$cps_neg_envwrap_findings" in
    *unallowlisted_command*)
      pass_case 'mechanism: command-position sweep rejects a command reached only through an env-wrapper array' ;;
    *)
      fail_case 'mechanism: command-position sweep failed to reject a command reached through an env-wrapper array' ;;
  esac

  cps_neg_trap="$cps_neg_dir/trap.sh"
  printf '%s\n' "trap 'unallowlisted_command' EXIT" > "$cps_neg_trap"
  cps_neg_trap_findings=$(cps_scan_source "$cps_neg_trap")
  case "$cps_neg_trap_findings" in
    *unallowlisted_command*)
      pass_case 'mechanism: command-position sweep rejects a command reached only through a trap body' ;;
    *)
      fail_case 'mechanism: command-position sweep failed to reject a command reached through a trap body' ;;
  esac

  cps_neg_case="$cps_neg_dir/case.sh"
  printf '%s\n' 'case "$x" in a) unallowlisted_command ;; esac' > "$cps_neg_case"
  cps_neg_case_findings=$(cps_scan_source "$cps_neg_case")
  case "$cps_neg_case_findings" in
    *unallowlisted_command*)
      pass_case 'mechanism: command-position sweep rejects a command reached only through a one-line case arm' ;;
    *)
      fail_case 'mechanism: command-position sweep failed to reject a command reached through a one-line case arm' ;;
  esac

  # Round-3 review: builtins and reserved words (eval, if/then/etc.) were
  # accepted without inspecting the commands they introduce, and a process
  # substitution's body was never queued at all. Three more shapes, each
  # proven rejectable rather than merely "not obviously mishandled".
  cps_neg_eval="$cps_neg_dir/eval.sh"
  printf '%s\n' "eval 'unallowlisted_command'" > "$cps_neg_eval"
  cps_neg_eval_findings=$(cps_scan_source "$cps_neg_eval")
  case "$cps_neg_eval_findings" in
    *unallowlisted_command*)
      pass_case 'mechanism: command-position sweep rejects a command reached only through an eval string' ;;
    *)
      fail_case 'mechanism: command-position sweep failed to reject a command reached through an eval string' ;;
  esac

  cps_neg_ifbody="$cps_neg_dir/ifbody.sh"
  printf '%s\n' 'if true; then unallowlisted_command; fi' > "$cps_neg_ifbody"
  cps_neg_ifbody_findings=$(cps_scan_source "$cps_neg_ifbody")
  case "$cps_neg_ifbody_findings" in
    *unallowlisted_command*)
      pass_case 'mechanism: command-position sweep rejects a command reached only through an if-body' ;;
    *)
      fail_case 'mechanism: command-position sweep failed to reject a command reached through an if-body' ;;
  esac

  cps_neg_procsub="$cps_neg_dir/procsub.sh"
  printf '%s\n' 'diff <(unallowlisted_command) /dev/null' > "$cps_neg_procsub"
  cps_neg_procsub_findings=$(cps_scan_source "$cps_neg_procsub")
  case "$cps_neg_procsub_findings" in
    *unallowlisted_command*)
      pass_case 'mechanism: command-position sweep rejects a command reached only through a process substitution' ;;
    *)
      fail_case 'mechanism: command-position sweep failed to reject a command reached through a process substitution' ;;
  esac
  cps_neg_mltrap="$cps_neg_dir/mltrap.sh"
  printf '%s\n' $'trap \'\n:\nunallowlisted_command\n\' EXIT' > "$cps_neg_mltrap"
  cps_neg_mltrap_findings=$(cps_scan_source "$cps_neg_mltrap")
  case "$cps_neg_mltrap_findings" in
    *unallowlisted_command*)
      pass_case 'mechanism: command-position sweep rejects an unallowlisted 2nd statement in a multiline trap body' ;;
    *)
      fail_case 'mechanism: command-position sweep failed to reject an unallowlisted statement in a multiline trap body' ;;
  esac

  # Round-4 review: /usr/bin/awk is a legitimate ARGUMENT (e.g. "/bin/cp --
  # /usr/bin/awk \"\$run/awk\"") but the entry never execs it directly; a
  # direct COMMAND-position invocation must be rejected by the
  # allowlist_words-only check added above, not silently accepted the way
  # the old unconditional "/*) return 0" did.
  cps_neg_awk="$cps_neg_dir/awk.sh"
  printf '%s\n' '/usr/bin/awk "$@"' > "$cps_neg_awk"
  cps_neg_awk_findings=$(cps_scan_source "$cps_neg_awk")
  case "$cps_neg_awk_findings" in
    *'/usr/bin/awk'*)
      pass_case 'mechanism: command-position sweep rejects a direct /usr/bin/awk command-word invocation' ;;
    *)
      fail_case 'mechanism: command-position sweep failed to reject a direct /usr/bin/awk command-word invocation' ;;
  esac

  # Shipped entry + parent must still pass with the tightened checks above:
  # its one real variable-joined command word is "$run/trusted-launch",
  # covered by cps_command_dynamic_joins, and it never execs /usr/bin/awk,
  # /bin/rm on a bare "/tmp", or /bin/cat on an arbitrary /dev/fd/N
  # directly -- already proven by the "bare-word command-position sweep
  # finds no unallowlisted command in the shipped entry" pass_case above,
  # which runs cps_scan_source "$entry" through this same, now-stricter
  # cps_classify_command.

  env_i_line=$(/usr/bin/grep -n 'exec /usr/bin/env -i' "$entry" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)
  if [ -n "$env_i_line" ]; then
    bad_printf=0
    # A full-line "# ..." comment above the re-exec that merely names
    # /usr/bin/printf in prose (contrasting it with the entry's own builtin
    # printf, as the header comment above the re-exec does) is not an
    # occurrence of the command; only non-comment lines count.
    while IFS=: read -r n _; do
      [ "$n" -gt "$env_i_line" ] || bad_printf=$((bad_printf + 1))
    done < <(/usr/bin/awk '!/^[[:space:]]*#/ && /\/usr\/bin\/printf/ { print NR ":" $0 }' "$entry")
    if [ "$bad_printf" -eq 0 ]; then
      pass_case 'mechanism: every /usr/bin/printf occurrence sits below the env -i re-exec line'
    else
      fail_case "mechanism: $bad_printf /usr/bin/printf occurrence(s) sit above the env -i re-exec"
    fi
  else
    fail_case 'mechanism: no exec /usr/bin/env -i re-exec line found in entry'
  fi

  # Enumerate plan §6's exact /dev/null roles by full trimmed line content:
  # ulimit ladder, descriptor-close eval, both unset scrub forms, and the
  # signal-forwarding kill (cleanup excluded -- plan.md:351-359).
  devnull_role_bad_count() {
    local file=$1 bad=0 raw trimmed
    while IFS= read -r raw; do
      trimmed=$(printf '%s' "$raw" | /usr/bin/sed -e 's/^[[:space:]]*//')
      case "$trimmed" in
        'ulimit -S -n 1024 2>/dev/null || ulimit -S -n 256 2>/dev/null || ulimit -S -n 64 2>/dev/null || {') ;;
        'eval "exec ${fd_name}>&-" 2>/dev/null || :') ;;
        'builtin unset -f "$inherited_function" 2>/dev/null || :') ;;
        'case "$exported_name" in PATH) ;; *) builtin unset "$exported_name" 2>/dev/null || : ;; esac') ;;
        '*" $parent_pid Running"*) kill -"$entry_signal" "$parent_pid" 2>/dev/null || : ;;') ;;
        *) bad=$((bad + 1)) ;;
      esac
    done < <(/usr/bin/grep '/dev/null' "$file" || :)
    printf '%s\n' "$bad"
  }

  devnull_lines=$(/usr/bin/grep -n '/dev/null' "$entry" || :)
  devnull_bad=$(devnull_role_bad_count "$entry")
  if [ -n "$devnull_lines" ]; then
    if [ "$devnull_bad" -eq 0 ]; then
      pass_case 'mechanism: /dev/null discard appears only in its enumerated roles'
    else
      fail_case "mechanism: /dev/null used outside its enumerated roles ($devnull_bad occurrence(s))"
    fi
  fi

  # Negative controls: the tightened role check must actually be able to
  # reject, not merely happen to pass on the shipped entry.
  devnull_neg_dir="$tmp/devnull-neg"
  /bin/mkdir -p "$devnull_neg_dir"

  devnull_neg_permanent="$devnull_neg_dir/permanent-suppress.sh"
  /bin/cp -- "$entry" "$devnull_neg_permanent"
  printf '%s\n' 'exec 2>/dev/null || :' >> "$devnull_neg_permanent"
  devnull_neg_permanent_bad=$(devnull_role_bad_count "$devnull_neg_permanent")
  if [ "$devnull_neg_permanent_bad" -gt 0 ]; then
    pass_case 'mechanism: /dev/null role check rejects permanent stderr suppression (exec 2>/dev/null || :)'
  else
    fail_case 'mechanism: /dev/null role check failed to reject exec 2>/dev/null || :'
  fi

  devnull_neg_cleanup="$devnull_neg_dir/unlisted-cleanup.sh"
  /bin/cp -- "$entry" "$devnull_neg_cleanup"
  # Shaped like an EXIT-trap cleanup line, on an unlisted target
  # ("${output:?}" instead of "${run:?}") -- cleanup has no enumerated
  # /dev/null role at all now, so any such redirect must be rejected.
  printf '%s\n' '    /bin/rm -rf -- "${output:?}" 2>/dev/null || :' >> "$devnull_neg_cleanup"
  devnull_neg_cleanup_bad=$(devnull_role_bad_count "$devnull_neg_cleanup")
  if [ "$devnull_neg_cleanup_bad" -gt 0 ]; then
    pass_case 'mechanism: /dev/null role check rejects a cleanup redirect outside the enumerated roles'
  else
    fail_case 'mechanism: /dev/null role check failed to reject an unlisted cleanup redirect'
  fi
else
  fail_case 'mechanism: allowlist sweep (entry absent)'
fi

if [ -f "$parent_source" ]; then
  forbidden_calls='snprintf malloc free fprintf strerror nanosleep usleep'
  handler_name=$(/usr/bin/grep -oE '\.sa_(handler|sigaction)[[:space:]]*=[[:space:]]*[A-Za-z_][A-Za-z0-9_]*' "$parent_source" \
    | /usr/bin/sed -E 's/.*=[[:space:]]*//' | /usr/bin/grep -vE '^(SIG_DFL|SIG_IGN)$' | /usr/bin/head -n1)
  # handler_bad_count SRC -> forbidden calls in handler_name's brace-balanced body in SRC.
  handler_bad_count() {
    hbc_body=$(/usr/bin/awk -v name="$handler_name" '
      !f { if ($0 ~ ("(^|[^A-Za-z0-9_])" name "[[:space:]]*\\(")) f = 1; else next }
      { print; d += gsub(/\{/, "{"); d -= gsub(/\}/, "}"); if (d > 0) s = 1; if (s && d == 0) exit }' "$1")
    hbc_n=0
    for f in $forbidden_calls; do hbc_n=$((hbc_n + $(printf '%s\n' "$hbc_body" | /usr/bin/grep -c -- "${f}(" || :))); done
    printf '%s\n' "$hbc_n"
  }
  if [ -z "$handler_name" ]; then
    fail_case 'mechanism: no signal handler resolved from sa_handler/sa_sigaction (also skips its negative control)'
  else
    handler_bad=$(handler_bad_count "$parent_source")
    if [ "$handler_bad" -eq 0 ]; then pass_case 'mechanism: no forbidden non-async-signal-safe call inside the installed signal handler body'
    else fail_case "mechanism: installed signal handler '$handler_name' has $handler_bad forbidden call(s)"; fi
    # Negative control: an injected fprintf in the body must be caught.
    handler_neg_src="$tmp/handler-neg.c"
    /usr/bin/awk -v name="$handler_name" \
      '{ print } !d && $0 ~ ("(^|[^A-Za-z0-9_])" name "[[:space:]]*\\(") { print "    fprintf(stderr, \"x\");"; d = 1 }' \
      "$parent_source" > "$handler_neg_src"
    if [ "$(handler_bad_count "$handler_neg_src")" -gt 0 ]; then pass_case 'mechanism: handler safety check rejects an injected fprintf inside the handler body (negative control)'
    else fail_case 'mechanism: handler safety check failed to reject an injected fprintf inside the handler body'; fi
  fi

  # Word-bounded and comment-stripped: an unbounded "environ" also matches
  # inside identifiers like "environment_value" (this file's own helper for
  # building execve's envp array) and the standalone word "environ" inside a
  # /* ... */ prose comment describing exactly why this grep exists -- neither
  # is the libc extern the grep is meant to catch. C block comments can span
  # multiple lines, so a per-line "#"-style filter (as used for the shell
  # entry elsewhere in this file) does not apply; this tracks block-comment
  # state across lines instead.
  parent_source_nocomments=$(/usr/bin/awk '
    { line = $0 }
    in_comment {
      end = index(line, "*/")
      if (end == 0) { next }
      line = substr(line, end + 2)
      in_comment = 0
    }
    {
      out = ""
      while ((start = index(line, "/*")) > 0) {
        out = out substr(line, 1, start - 1)
        rest = substr(line, start + 2)
        end = index(rest, "*/")
        if (end == 0) { line = ""; in_comment = 1; break }
        line = substr(rest, end + 2)
      }
      print out line
    }
  ' "$parent_source")
  if printf '%s' "$parent_source_nocomments" |
     /usr/bin/grep -qE '(^|[^A-Za-z0-9_])environ([^A-Za-z0-9_]|$)|execv\(|execvp\(|execlp\('; then
    fail_case 'mechanism: parent references environ/execv/execvp/execlp'
  else
    pass_case 'mechanism: parent contains no environ/execv/execvp/execlp'
  fi

  # Parent exec inventory: the command-position sweep above covers the shell
  # entry only; the parent's own two execve() call sites (inside
  # run_pinned_child() and supervise()) must name exactly the fixed pin-check
  # programs and /bin/bash -- no other literal or symbol may reach either
  # call, which would be a fifth, unaudited exec path this sweep exists to
  # catch.
  parent_pinned_calls=$(/usr/bin/grep -E 'run_pinned_child\(' "$parent_source" |
    /usr/bin/grep -v 'static int run_pinned_child' |
    /usr/bin/grep -oE 'run_pinned_child\([A-Za-z_][A-Za-z0-9_]*' |
    /usr/bin/sed -E 's/^run_pinned_child\(//' | /usr/bin/sort -u)
  parent_supervise_calls=$(/usr/bin/grep -oE 'supervise\(out_fd, "[^"]*"' "$parent_source" |
    /usr/bin/sed -E 's/^supervise\(out_fd, "//; s/"$//' | /usr/bin/sort -u)
  expected_pinned_programs='SHA1_PROGRAM SHA256_PROGRAM jq_path'
  parent_exec_bad=0
  for sym in $parent_pinned_calls; do
    match=0
    for w in $expected_pinned_programs; do [ "$sym" = "$w" ] && match=1 && break; done
    [ "$match" -eq 1 ] ||
      { printf 'parent exec inventory: unexpected run_pinned_child() program argument: %s\n' "$sym" >&2
        parent_exec_bad=$((parent_exec_bad + 1)); }
  done
  for sym in $parent_supervise_calls; do
    [ "$sym" = "/bin/bash" ] ||
      { printf 'parent exec inventory: unexpected supervise() program argument: %s\n' "$sym" >&2
        parent_exec_bad=$((parent_exec_bad + 1)); }
  done
  pinned_count=$(printf '%s\n' "$parent_pinned_calls" | /usr/bin/grep -c . || :)
  supervise_count=$(printf '%s\n' "$parent_supervise_calls" | /usr/bin/grep -c . || :)
  if [ "$parent_exec_bad" -eq 0 ] && [ "$pinned_count" -eq 3 ] && [ "$supervise_count" -eq 1 ]; then
    pass_case 'mechanism: parent exec inventory (three pinned pre-resolver programs, one /bin/bash resolver launch) matches the fixed set'
  else
    fail_case "mechanism: parent exec inventory mismatch (pinned=$pinned_count supervise=$supervise_count bad=$parent_exec_bad)"
  fi
else
  fail_case 'mechanism: parent handler-safety grep (trusted-launch.c absent)'
fi

# --- Not mapped to an automated case (spec.md line references) -----------------------------
# - The fork-then-publish sigprocmask window (spec.md:8434-8449): "nothing a test can do
#   puts a signal in it on demand" -- proof by reading only.
# - The reap/kill(-pgid) ordering inside the handlers (spec.md:8483-8500): same reason.
# - The kill(0,...) coincidence and the "few instructions wide" scheduling claims
#   (spec.md:8516-8524, 8460-8470): explicitly not case-able, proof by reading only.
# - Full byte-exact reproduction of the three-pass allowlist grammar (pass 1's source-role
#   carve-outs, pass 3's parameter-name closure) is approximated above rather than
#   reproduced to the letter; a later step should tighten it once the shipped source's
#   actual variable names are fixed (spec.md:8801-8940).

suite_complete=1
printf 'resolver-trusted-launch: %d/%d cases passed\n' "$passed" "$total"
[ "$passed" -eq "$total" ] || exit 1
