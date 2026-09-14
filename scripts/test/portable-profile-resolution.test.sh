#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

resolver_root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
resolver_runtime="$resolver_root/resolver/v1/profile-resolve-runtime.sh"
resolver_helper_source="$resolver_root/resolver/v1/nofollow-snapshot.c"
resolver_launcher_source="$resolver_root/scripts/test/portable-profile-resolution-launcher.c"
resolver_loader_source="$resolver_root/scripts/test/portable-profile-resolution-loader-trap.c"
resolver_fixture_builder="$resolver_root/scripts/test/portable-profile-resolution-fixtures.sh"
resolver_core="$resolver_root/scripts/core-contract.sh"
resolver_tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-profile-resolver-test.XXXXXX")
resolver_tmp=$(CDPATH='' cd -P -- "$resolver_tmp" && pwd -P)
resolver_download=''
resolver_passed=0
resolver_total=0
resolver_fingerprint_counter=0
resolver_suite_complete=0
/bin/rm -f /tmp/ystack-profile-resolver-must-not-run

cleanup() {
  if [ -n "$resolver_download" ] && [ -f "$resolver_download" ]; then
    /bin/rm -f -- "$resolver_download"
  fi
  if [ "$resolver_suite_complete" -eq 1 ]; then
    /bin/rm -rf -- "$resolver_tmp"
  else
    printf 'preserved failing fixture: %s\n' "$resolver_tmp" >&2
  fi
  /bin/rm -f /tmp/ystack-profile-resolver-must-not-run
}
trap cleanup EXIT


resolver_component_count=0
resolver_library="$resolver_root/scripts/lib/profile-resolution.sh"

assert_runtime_directories() {
  local sandbox=$1 directory inventory
  for directory in "$sandbox/home" "$sandbox/tmp"; do
    [ -d "$directory" ] && [ ! -L "$directory" ] || {
      printf 'FAIL: missing real runtime directory %s\n' "$directory" >&2
      return 1
    }
    inventory=$(/usr/bin/find "$directory" -mindepth 1 -print) || return 1
    [ -z "$inventory" ] || {
      printf 'FAIL: runtime residue in %s\n%s\n' "$directory" "$inventory" >&2
      return 1
    }
  done
}

check_platform_component() {
  local name=$1 bytes=$2 expected=$3 option=$4 mode=${5:-normal} target=${6:-none}
  local output="$resolver_tmp/component.$resolver_component_count"
  /bin/mkdir -m 700 "$output.files"
  if ! /bin/bash -s -- "$resolver_library" "$bytes" "$expected" "$option" \
      "$mode" "$target" "$output.files" > "$output" 2> "$output.stderr" <<'COMPONENT'
set -eu
library=$1 bytes=$2 expected=$3 option=$4 mode=$5 target=$6 files=$7
set +o pipefail
[ "$option" = off ] || set -o pipefail
IFS=:
before_ifs=$IFS
[ "$option" = off ] || set -f
before=$(set +o)
# shellcheck source=/dev/null
{
  set -x
  source "$library"
  set +x
} 2> "$files/source.trace"
if /usr/bin/grep -E '/usr/bin/uname|/bin/dd|/usr/bin/od|/usr/bin/git|CommandLineTools' "$files/source.trace" >/dev/null; then
  exit 88
fi
[ "$(set +o)" = "$before" ] || exit 89
[ "$IFS" = "$before_ifs" ] || exit 90
for function in producer reader encoder; do
  declare -F "profile_resolution_platform_$function" >/dev/null || exit 90
done
# Keep the actual file predicate for tests against owned fixture types.
predicate=$(declare -f profile_resolution_platform_file)
eval "${predicate/profile_resolution_platform_file/profile_test_original_file}"
: > "$files/regular"
/bin/chmod 0500 "$files/regular"
: > "$files/nonexecutable"
/bin/chmod 0400 "$files/nonexecutable"
/bin/mkdir "$files/directory"
/bin/ln -s "$files/regular" "$files/symlink"
profile_resolution_platform_file() {
  printf '%s\n' "$1" >> "$files/predicates"
  if [ "$1" = "$target" ]; then
    profile_test_original_file "$files/$mode"
  else
    profile_test_original_file "$files/regular"
  fi
}
profile_resolution_platform_producer() {
  : > "$files/producer"
  builtin printf '%b' "$bytes"
  [ "$mode" != producer-fail ]
}
profile_resolution_platform_reader() {
  : > "$files/reader"
  /bin/dd bs=1 count=65 || return $?
  [ "$mode" != reader-fail ]
}
profile_resolution_platform_encoder() {
  : > "$files/encoder"
  case "$mode" in
    rendering-*)
      /usr/bin/od -An -v -tu1 > "$files/raw-decimal" || return $?
      printf '%s\n' "${mode#rendering-}"
      ;;
    *)
      /usr/bin/od -An -v -tu1 > "$files/raw-decimal" || return $?
      /bin/cat "$files/raw-decimal" || return $?
      ;;
  esac
  [ "$mode" != encoder-fail ]
}
exec 3>&2
profile_resolution_git_path=/misleading/inherited
if profile_resolution_initialize_git; then
  [ -n "$expected" ] && [ "$profile_resolution_git_path" = "$expected" ] || exit 91
  : > "$files/git-use"
else
  [ -z "$expected" ] && [ -z "$profile_resolution_git_path" ] || exit 92
fi
[ "$(set +o)" = "$before" ] && [ "$IFS" = "$before_ifs" ] || exit 93
if [ -n "$expected" ]; then
  [ -f "$files/git-use" ] || exit 95
else
  [ ! -e "$files/git-use" ] || exit 96
fi
if [ "$mode" = repeat ]; then
  bytes='unsupported\n'
  if profile_resolution_initialize_git; then exit 97; fi
  [ -z "$profile_resolution_git_path" ] || exit 98
fi
if [ -f "$files/raw-decimal" ]; then
  IFS=$' \t\n'
  count=0
  for byte in $(/bin/cat "$files/raw-decimal"); do count=$((count + 1)); done
  [ "$count" -le 65 ] || exit 99
  printf '%s\n' "$count" > "$files/raw-count"
fi
COMPONENT
  then
    /bin/cat "$output.stderr" >&2
    printf 'FAIL: platform component %s (%s)\n' "$name" "$mode" >&2
    return 1
  fi
  [ ! -s "$output" ] || return 1
  if [ -n "$expected" ] && [ "$mode" != repeat ]; then
    [ ! -s "$output.stderr" ] || return 1
  else
    builtin printf 'E_RUNTIME dependency\n' > "$output.expected"
    /usr/bin/cmp -s "$output.expected" "$output.stderr" || return 1
  fi
  case "$mode" in
    normal|regular|repeat|*-fail|rendering-*)
      for target in producer reader encoder; do [ -f "$output.files/$target" ] || return 1; done
      ;;
  esac
  case "$name" in
    bytes-64) [ "$(/bin/cat "$output.files/raw-count")" = 64 ] || return 1 ;;
    bytes-65|bytes-long) [ "$(/bin/cat "$output.files/raw-count")" = 65 ] || return 1 ;;
  esac
  resolver_component_count=$((resolver_component_count + 1))
  printf 'component ok %s - %s (%s, %s)\n' "$resolver_component_count" "$name" "$option" "$mode"
}

for resolver_component_option in off on; do
  check_platform_component linux 'Linux x86_64\n' /usr/bin/git "$resolver_component_option"
  check_platform_component darwin-intel 'Darwin x86_64\n' \
    /Library/Developer/CommandLineTools/usr/bin/git "$resolver_component_option"
  check_platform_component darwin-arm 'Darwin arm64\n' \
    /Library/Developer/CommandLineTools/usr/bin/git "$resolver_component_option"
  for resolver_bad_platform in '' 'Linux x86_64' 'Linux x86_64\n\n' \
      'Linux x86_64\nextra' 'Linux arm64\n' 'FreeBSD x86_64\n' \
      '\000Linux x86_64\n' 'Linux\000 x86_64\n' 'Linux x86_64\n\000' \
      'prefixLinux x86_64\n' 'Linux x86_64suffix\n' 'Darwin i386\n' \
      'Linux x86_\n' 'L\303\255nux x86_64\n'; do
    check_platform_component malformed "$resolver_bad_platform" '' "$resolver_component_option"
  done
  for resolver_byte_count in 64 65 96; do
    resolver_platform_bytes=''
    for ((resolver_byte=0; resolver_byte<resolver_byte_count; resolver_byte++)); do
      resolver_platform_bytes="${resolver_platform_bytes}x"
    done
    resolver_bytes_name="bytes-$resolver_byte_count"
    [ "$resolver_byte_count" -ne 96 ] || resolver_bytes_name='bytes-long'
    check_platform_component "$resolver_bytes_name" "$resolver_platform_bytes" '' "$resolver_component_option"
  done
  for resolver_failed_stage in producer reader encoder; do
    check_platform_component pipeline-status 'Linux x86_64\n' '' \
      "$resolver_component_option" "$resolver_failed_stage-fail"
    check_platform_component pipeline-positive 'Linux x86_64\n' /usr/bin/git "$resolver_component_option"
  done
  for resolver_bad_decimal in x 00 01 -1 256 999 '76 105 *' ''; do
    check_platform_component decimal-rendering 'Linux x86_64\n' '' \
      "$resolver_component_option" "rendering-$resolver_bad_decimal"
  done
  for resolver_dependency in /usr/bin/uname /bin/dd /usr/bin/od /usr/bin/git; do
    for resolver_file_state in missing directory nonexecutable symlink; do
      check_platform_component file-predicate 'Linux x86_64\n' '' \
        "$resolver_component_option" "$resolver_file_state" "$resolver_dependency"
    done
    check_platform_component file-positive 'Linux x86_64\n' /usr/bin/git \
      "$resolver_component_option" regular "$resolver_dependency"
  done
  for resolver_file_state in missing directory nonexecutable symlink; do
    check_platform_component darwin-file 'Darwin arm64\n' '' \
      "$resolver_component_option" "$resolver_file_state" /Library/Developer/CommandLineTools/usr/bin/git
  done
  check_platform_component clear-second-failure 'Linux x86_64\n' /usr/bin/git \
    "$resolver_component_option" repeat
 done

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

fingerprint_entry() {
  resolver_fingerprint_path=$1
  if [ -L "$resolver_fingerprint_path" ]; then
    /usr/bin/printf 'L\t%s\t%s\n' "$resolver_fingerprint_path" \
      "$(/usr/bin/readlink "$resolver_fingerprint_path")"
  elif [ -d "$resolver_fingerprint_path" ]; then
    /usr/bin/printf 'D\t%s\n' "$resolver_fingerprint_path"
  elif [ -f "$resolver_fingerprint_path" ]; then
    case "$resolver_platform" in
      Linux:x86_64) resolver_fingerprint_stat=$(/usr/bin/stat -c '%a:%s' "$resolver_fingerprint_path") ;;
      Darwin:*) resolver_fingerprint_stat=$(/usr/bin/stat -f '%Lp:%z' "$resolver_fingerprint_path") ;;
    esac
    /usr/bin/printf 'F\t%s\t%s\t%s\n' "$resolver_fingerprint_path" \
      "$resolver_fingerprint_stat" "$(sha256_file "$resolver_fingerprint_path")"
  else
    /usr/bin/printf 'O\t%s\n' "$resolver_fingerprint_path"
  fi
}

repository_fingerprint() {
  resolver_fingerprint_root=$1
  resolver_fingerprint_active=$(/usr/bin/git -C "$resolver_fingerprint_root" rev-parse --absolute-git-dir)
  resolver_fingerprint_common=$(/usr/bin/git --git-dir="$resolver_fingerprint_active" \
    rev-parse --path-format=absolute --git-common-dir)
  resolver_fingerprint_counter=$((resolver_fingerprint_counter + 1))
  resolver_fingerprint_inventory="$resolver_tmp/fingerprint.$resolver_fingerprint_counter"
  {
    /usr/bin/printf 'ROOT\t%s\nACTIVE\t%s\nCOMMON\t%s\n' "$resolver_fingerprint_root" \
      "$resolver_fingerprint_active" "$resolver_fingerprint_common"
    for resolver_fingerprint_fixed in \
      "$resolver_fingerprint_root/.git" "$resolver_fingerprint_active/HEAD" \
      "$resolver_fingerprint_active/config.worktree" "$resolver_fingerprint_active/commondir" \
      "$resolver_fingerprint_active/gitdir" "$resolver_fingerprint_common/HEAD" \
      "$resolver_fingerprint_common/config" "$resolver_fingerprint_common/packed-refs" \
      "$resolver_fingerprint_common/info/grafts"; do
      if [ -e "$resolver_fingerprint_fixed" ] || [ -L "$resolver_fingerprint_fixed" ]; then
        fingerprint_entry "$resolver_fingerprint_fixed"
      fi
    done
    for resolver_fingerprint_tree in "$resolver_fingerprint_common/refs" \
      "$resolver_fingerprint_common/objects"; do
      if [ -d "$resolver_fingerprint_tree" ] && [ ! -L "$resolver_fingerprint_tree" ]; then
        while IFS= read -r -d '' resolver_fingerprint_path; do
          fingerprint_entry "$resolver_fingerprint_path"
        done < <(/usr/bin/find "$resolver_fingerprint_tree" -mindepth 1 -print0 | /usr/bin/sort -z)
      fi
    done
  } > "$resolver_fingerprint_inventory"
  sha256_file "$resolver_fingerprint_inventory"
}

resolver_platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$resolver_platform" in
  Linux:x86_64)
    resolver_jq_asset=jq-linux64
    resolver_jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44
    resolver_compiler=${CC:-/usr/bin/cc}
    resolver_host='Linux:x86_64:execve:cc'
    resolver_loader_flags=(-shared -fPIC)
    ;;
  Darwin:x86_64|Darwin:arm64)
    resolver_jq_asset=jq-osx-amd64
    resolver_jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    resolver_compiler=${CC:-/usr/bin/clang}
    resolver_host="$resolver_platform:execve:Apple-clang:developer-functional"
    resolver_loader_flags=(-dynamiclib)
    ;;
  *) printf 'FAIL: unsupported profile resolver host: %s\n' "$resolver_platform" >&2; exit 1 ;;
esac

resolver_cache="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$resolver_cache"
resolver_jq="$resolver_cache/$resolver_jq_asset"
if [ ! -f "$resolver_jq" ] || [ "$(sha256_file "$resolver_jq")" != "$resolver_jq_sha" ]; then
  resolver_download=$(/usr/bin/mktemp "$resolver_cache/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$resolver_jq_asset" \
    -o "$resolver_download"
  [ "$(sha256_file "$resolver_download")" = "$resolver_jq_sha" ] || {
    printf '%s\n' 'FAIL: jq 1.6 release digest mismatch' >&2
    exit 1
  }
  /bin/chmod 0555 "$resolver_download"
  /bin/mv "$resolver_download" "$resolver_jq"
  resolver_download=''
fi
[ "$("$resolver_jq" --version)" = jq-1.6 ] || {
  printf '%s\n' 'FAIL: jq 1.6 identity' >&2
  exit 1
}

resolver_bin="$resolver_tmp/bin"
/bin/mkdir -m 700 "$resolver_bin"
/bin/cp "$resolver_jq" "$resolver_bin/jq"
/bin/chmod 0555 "$resolver_bin/jq"
resolver_bound_jq="$resolver_bin/jq"
case "$resolver_platform" in
  Linux:x86_64) /bin/cp /usr/bin/awk "$resolver_bin/awk" ;;
  Darwin:*)
    /usr/bin/printf '%s\n' '#!/bin/bash' 'exec /usr/bin/awk "$@"' > "$resolver_bin/awk"
    ;;
esac
/bin/chmod 0555 "$resolver_bin/awk"
[ -f "$resolver_bin/awk" ] && [ ! -L "$resolver_bin/awk" ] || {
  printf '%s\n' 'FAIL: bound core awk must be regular' >&2
  exit 1
}
"$resolver_compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  "$resolver_helper_source" -o "$resolver_bin/nofollow-snapshot"
"$resolver_compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  "$resolver_launcher_source" -o "$resolver_bin/launcher"
"$resolver_compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  "${resolver_loader_flags[@]}" "$resolver_loader_source" -o "$resolver_bin/loader-trap.dylib"

resolver_identity_source_blob() {
  /usr/bin/git -C "$resolver_root" hash-object "$1"
}

record_runtime_identities() {
  local phase=$1 path identity
  printf 'native identity phase=%s platform=%s\n' "$phase" "$resolver_platform"
  for path in /usr/bin/uname /bin/dd /usr/bin/od /bin/bash "$resolver_selected_git" \
      "$resolver_bound_jq" "$resolver_bin/launcher" "$resolver_bin/nofollow-snapshot" \
      "$resolver_runtime" "$resolver_library" "$resolver_helper_source" \
      "$resolver_launcher_source" "$resolver_root/resolver/v1/profile-resolution.jq"; do
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    identity=$(sha256_file "$path") || return 1
    [[ "$identity" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf 'native file %s %s\n' "$identity" "$path"
  done
  for path in scripts/lib/profile-resolution.sh resolver/v1/profile-resolve-runtime.sh \
      resolver/v1/profile-resolution.jq resolver/v1/nofollow-snapshot.c \
      scripts/test/portable-profile-resolution-launcher.c; do
    identity=$(resolver_identity_source_blob "$path") || return 1
    [[ "$identity" =~ ^[0-9a-f]{40}$ ]] || return 1
    printf 'native source %s %s\n' "$identity" "$path"
  done
}
case "$resolver_platform" in
  Linux:x86_64) resolver_selected_git=/usr/bin/git ;;
  Darwin:*) resolver_selected_git=/Library/Developer/CommandLineTools/usr/bin/git ;;
esac
check_identity_record_failures() {
  local stage mode output
  for stage in sha256 source-oid; do
    for mode in failed-status malformed uppercase empty; do
      output="$resolver_tmp/identity-control.$stage.$mode"
      if ! (
        if [ "$stage" = sha256 ]; then
          sha256_file() {
            case "$mode" in
              failed-status) printf '%064d\n' 0; return 1 ;;
              malformed) printf '%s\n' short ;;
              uppercase) printf '%s\n' FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF ;;
              empty) : ;;
            esac
          }
        else
          resolver_identity_source_blob() {
            case "$mode" in
              failed-status) printf '%040d\n' 0; return 1 ;;
              malformed) printf '%s\n' short ;;
              uppercase) printf '%s\n' FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF ;;
              empty) : ;;
            esac
          }
        fi
        if record_runtime_identities negative > "$output"; then exit 1; fi
        case "$stage" in
          sha256) ! /usr/bin/grep '^native file ' "$output" >/dev/null ;;
          source-oid) ! /usr/bin/grep '^native source ' "$output" >/dev/null ;;
        esac
      ); then
        printf 'FAIL: identity recorder accepted %s %s\n' "$stage" "$mode" >&2
        return 1
      fi
      printf 'identity control ok: %s %s\n' "$stage" "$mode"
    done
  done
}
check_identity_record_failures
record_runtime_identities before > "$resolver_tmp/identities.before"
/bin/cat "$resolver_tmp/identities.before"

resolver_fixture="$resolver_tmp/fixture"
PATH="$resolver_bin:/usr/bin:/bin" "$resolver_fixture_builder" "$resolver_fixture" \
  "$resolver_bound_jq" >/dev/null

resolver_variants="$resolver_tmp/repository-variants"
resolver_bare="$resolver_variants/bare"
resolver_linked="$resolver_variants/linked"
/bin/mkdir -p "$resolver_bare" "$resolver_linked"
for resolver_repository_name in assets manifests profile; do
  /usr/bin/git clone -q --bare --no-hardlinks "$resolver_fixture/$resolver_repository_name" \
    "$resolver_bare/$resolver_repository_name.git"
  /usr/bin/git -C "$resolver_fixture/$resolver_repository_name" worktree add -q --detach \
    "$resolver_linked/$resolver_repository_name" HEAD
done
resolver_corrupt_profile="$resolver_variants/corrupt-profile"
/usr/bin/git clone -q --no-hardlinks "$resolver_fixture/profile" "$resolver_corrupt_profile"

resolver_bare_map="$resolver_tmp/map.bare.json"
resolver_linked_map="$resolver_tmp/map.linked.json"
"$resolver_bound_jq" -S -c --arg assets "$resolver_bare/assets.git" \
  --arg manifests "$resolver_bare/manifests.git" --arg profile "$resolver_bare/profile.git" \
  '(.repositories[] | select(.repository_id == "repo.assets").root) = $assets |
   (.repositories[] | select(.repository_id == "repo.manifests").root) = $manifests |
   (.repositories[] | select(.repository_id == "repo.profile").root) = $profile' \
  "$resolver_fixture/map.json" > "$resolver_bare_map"
"$resolver_bound_jq" -S -c --arg assets "$resolver_linked/assets" \
  --arg manifests "$resolver_linked/manifests" --arg profile "$resolver_linked/profile" \
  '(.repositories[] | select(.repository_id == "repo.assets").root) = $assets |
   (.repositories[] | select(.repository_id == "repo.manifests").root) = $manifests |
   (.repositories[] | select(.repository_id == "repo.profile").root) = $profile' \
  "$resolver_fixture/map.json" > "$resolver_linked_map"
resolver_one_segment_request="$resolver_tmp/request.one-segment.json"
"$resolver_bound_jq" -S -c '.profile_source.path = "default.json"' \
  "$resolver_fixture/request.json" > "$resolver_one_segment_request"
resolver_quoted_request="$resolver_tmp/request.quoted.json"
resolver_newline_request="$resolver_tmp/request.newline.json"
"$resolver_bound_jq" -S -c --arg path 'profiles/"quoted".json' \
  '.profile_source.path = $path' "$resolver_fixture/request.json" > "$resolver_quoted_request"
"$resolver_bound_jq" -S -c --arg path $'profiles/new\nline.json' \
  '.profile_source.path = $path' "$resolver_fixture/request.json" > "$resolver_newline_request"

resolver_mapped_roots=(
  "$resolver_fixture/assets" "$resolver_fixture/manifests" "$resolver_fixture/profile"
  "$resolver_bare/assets.git" "$resolver_bare/manifests.git" "$resolver_bare/profile.git"
  "$resolver_linked/assets" "$resolver_linked/manifests" "$resolver_linked/profile"
  "$resolver_corrupt_profile"
)
resolver_fingerprints_before="$resolver_tmp/repository-fingerprints.before"
: > "$resolver_fingerprints_before"
for resolver_mapped_root in "${resolver_mapped_roots[@]}"; do
  /usr/bin/printf '%s\t%s\n' "$resolver_mapped_root" \
    "$(repository_fingerprint "$resolver_mapped_root")" >> "$resolver_fingerprints_before"
done

resolver_loader_marker="$resolver_tmp/loader.marker"
"$resolver_bin/launcher" loader-control "$resolver_bin/loader-trap.dylib" "$resolver_loader_marker"
[ -f "$resolver_loader_marker" ] || {
  printf '%s\n' 'FAIL: loader control did not fire' >&2
  exit 1
}
/bin/rm -f "$resolver_loader_marker"

run_resolver() {
  resolver_sandbox=$1
  resolver_request=$2
  resolver_map=$3
  /bin/mkdir -m 700 "$resolver_sandbox"
  local status=0
  YSTACK_TEST_SANDBOX="$resolver_sandbox" \
    "$resolver_bin/launcher" resolve "$resolver_runtime" "$resolver_bin/nofollow-snapshot" \
    "$resolver_bound_jq" "$resolver_request" "$resolver_map" || status=$?
  assert_runtime_directories "$resolver_sandbox" || return 99
  if [ "$status" -eq 0 ]; then
    [ ! -s "$resolver_sandbox/child.stderr" ] || return 99
  else
    [ ! -s "$resolver_sandbox/child.stdout" ] || return 99
  fi
  return "$status"
}

pass_case() {
  resolver_total=$((resolver_total + 1))
  resolver_passed=$((resolver_passed + 1))
  printf 'ok %d - %s\n' "$resolver_total" "$1"
}

fail_case() {
  resolver_total=$((resolver_total + 1))
  printf 'not ok %d - %s\n' "$resolver_total" "$1" >&2
  exit 1
}

expect_failure() {
  resolver_name=$1
  resolver_expected=$2
  resolver_request=$3
  resolver_map=$4
  resolver_stdout="$resolver_tmp/failure.stdout"
  resolver_stderr="$resolver_tmp/failure.stderr"
  if run_resolver "$resolver_tmp/sandbox.failure.$resolver_total" "$resolver_request" "$resolver_map" \
      > "$resolver_stdout" 2> "$resolver_stderr"; then
    fail_case "$resolver_name"
  else
    resolver_failure_status=$?
  fi
  [ ! -s "$resolver_stdout" ] || fail_case "$resolver_name emitted stdout"
  [ "$(/usr/bin/sed -n '1p' "$resolver_stderr")" = "$resolver_expected" ] || {
    /bin/cat "$resolver_stderr" >&2
    fail_case "$resolver_name error"
  }
  builtin printf '%s\n' "$resolver_expected" > "$resolver_tmp/expected-error"
  /usr/bin/cmp -s "$resolver_tmp/expected-error" "$resolver_stderr" &&
    /usr/bin/cmp -s "$resolver_stderr" "$resolver_sandbox/child.stderr" &&
    [ ! -s "$resolver_sandbox/child.stdout" ] || fail_case "$resolver_name raw diagnostic"
  assert_runtime_directories "$resolver_sandbox" || fail_case "$resolver_name cleanup"
  printf 'native refusal status=%s token=%s raw_stderr_sha=%s home=empty tmp=empty stdout=empty\n' \
    "$resolver_failure_status" "$resolver_expected" "$(sha256_file "$resolver_stderr")"
  pass_case "$resolver_name"
}

expect_launcher_failure() {
  resolver_name=$1
  resolver_mode=$2
  resolver_expected=$3
  resolver_limit_sandbox="$resolver_tmp/limit.$resolver_mode"
  resolver_limit_stdout="$resolver_tmp/limit.$resolver_mode.stdout"
  resolver_limit_stderr="$resolver_tmp/limit.$resolver_mode.stderr"
  /bin/mkdir -m 700 "$resolver_limit_sandbox"
  if "$resolver_bin/launcher" limit-control "$resolver_mode" "$resolver_limit_sandbox" \
      > "$resolver_limit_stdout" 2> "$resolver_limit_stderr"; then
    fail_case "$resolver_name"
  fi
  [ ! -s "$resolver_limit_stdout" ] || fail_case "$resolver_name emitted partial stdout"
  [ "$(/usr/bin/sed -n '1p' "$resolver_limit_stderr")" = "$resolver_expected" ] || {
    /bin/cat "$resolver_limit_stderr" >&2
    fail_case "$resolver_name token"
  }
  pass_case "$resolver_name"
}

expect_git_wall_failure() {
  resolver_wall_sandbox="$resolver_tmp/git-wall-sandbox"
  resolver_wall_stdout="$resolver_tmp/git-wall.stdout"
  resolver_wall_stderr="$resolver_tmp/git-wall.stderr"
  /bin/mkdir -m 700 "$resolver_wall_sandbox"
  resolver_wall_started=$SECONDS
  if YSTACK_TEST_SANDBOX="$resolver_wall_sandbox" \
      "$resolver_bin/launcher" resolve-git-wall "$resolver_runtime" \
      "$resolver_bin/nofollow-snapshot" "$resolver_bound_jq" \
      "$resolver_fixture/request.json" "$resolver_fixture/map.json" \
      > "$resolver_wall_stdout" 2> "$resolver_wall_stderr"; then
    fail_case 'Git wall watchdog'
  fi
  resolver_wall_elapsed=$((SECONDS - resolver_wall_started))
  [ ! -s "$resolver_wall_stdout" ] &&
    [ "$(/usr/bin/sed -n '1p' "$resolver_wall_stderr")" = 'E_LIMIT time-limit' ] &&
    [ "$resolver_wall_elapsed" -lt 10 ] || {
      /bin/cat "$resolver_wall_stderr" >&2
      fail_case 'Git wall watchdog token or duration'
    }
  assert_runtime_directories "$resolver_wall_sandbox" || fail_case 'Git wall cleanup'
  builtin printf 'E_LIMIT time-limit\n' > "$resolver_tmp/wall-expected"
  /usr/bin/cmp -s "$resolver_wall_stderr" "$resolver_tmp/wall-expected" &&
    /usr/bin/cmp -s "$resolver_wall_stderr" "$resolver_wall_sandbox/child.stderr" &&
    [ ! -s "$resolver_wall_sandbox/child.stdout" ] || fail_case 'Git wall raw diagnostic'
  printf 'native cleanup: Git wall elapsed=%s; home=empty; tmp=empty\n' "$resolver_wall_elapsed"
  pass_case 'Git wall watchdog kills and reaps the exact child'
}

expect_missing_dependency() {
  resolver_missing_helper="$resolver_tmp/missing-helper"
  resolver_missing_sandbox="$resolver_tmp/missing-helper-sandbox"
  resolver_missing_stdout="$resolver_tmp/missing-helper.stdout"
  resolver_missing_stderr="$resolver_tmp/missing-helper.stderr"
  /bin/cp "$resolver_bin/nofollow-snapshot" "$resolver_missing_helper"
  /bin/chmod 0555 "$resolver_missing_helper"
  /bin/mkdir -m 700 "$resolver_missing_sandbox"
  if YSTACK_TEST_SANDBOX="$resolver_missing_sandbox" \
      "$resolver_bin/launcher" resolve-missing-helper "$resolver_runtime" \
      "$resolver_missing_helper" "$resolver_bound_jq" "$resolver_fixture/request.json" \
      "$resolver_fixture/map.json" > "$resolver_missing_stdout" 2> "$resolver_missing_stderr"; then
    fail_case 'missing required dependency'
  fi
  [ ! -s "$resolver_missing_stdout" ] && [ ! -e "$resolver_missing_helper" ] ||
    fail_case 'missing dependency emitted output or survived'
  [ "$(/usr/bin/sed -n '1p' "$resolver_missing_stderr")" = 'E_RUNTIME dependency' ] || {
    /bin/cat "$resolver_missing_stderr" >&2
    fail_case 'missing dependency token'
  }
  pass_case 'missing required dependency is sanitized'
}

expect_internal_budget_failure() {
  resolver_name=$1
  resolver_budget_id=$2
  resolver_budget_gitdir=$3
  resolver_budget_algorithm=$4
  resolver_budget_oid=$5
  resolver_budget_value=$6
  resolver_budget_global=$7
  resolver_budget_reason=$8
  resolver_budget_scratch="$resolver_tmp/budget.$resolver_total"
  resolver_budget_result="$resolver_tmp/budget.$resolver_total.result"
  resolver_budget_error="$resolver_tmp/budget.$resolver_total.error"
  /bin/mkdir -m 700 "$resolver_budget_scratch" "$resolver_budget_scratch/object-cache"
  (
    set +e
    # shellcheck source=/dev/null
    source "$resolver_root/scripts/lib/profile-resolution.sh"
    exec 3> "$resolver_budget_error"
    profile_resolution_initialize_git || exit 1
    # shellcheck disable=SC2034
    profile_resolution_scratch=$resolver_budget_scratch
    profile_resolution_snapshots="$resolver_budget_scratch/snapshots.tsv"
    /usr/bin/printf '%s\t%s\tidentity\t%s\n' "$resolver_budget_id" \
      "$resolver_budget_gitdir" "$resolver_budget_algorithm" > "$profile_resolution_snapshots"
    # shellcheck disable=SC2034
    profile_resolution_value_remaining=$resolver_budget_value
    # shellcheck disable=SC2034
    profile_resolution_global_remaining=$resolver_budget_global
    profile_resolution_limit_reason=''
    profile_resolution_verify_object_payload "$resolver_budget_id" "$resolver_budget_algorithm" \
      "$resolver_budget_oid" blob "$resolver_budget_scratch/value"
    resolver_budget_status=$?
    /usr/bin/printf '%s\t%s\n' "$resolver_budget_status" "$profile_resolution_limit_reason"
    profile_resolution_report_object_failure "$resolver_budget_status" >/dev/null
  ) > "$resolver_budget_result" || :
  resolver_budget_expected=$(/usr/bin/printf '50\t%s' "$resolver_budget_reason")
  [ "$(/usr/bin/sed -n '1p' "$resolver_budget_result")" = "$resolver_budget_expected" ] ||
    fail_case "$resolver_name internal status"
  [ "$(/usr/bin/sed -n '1p' "$resolver_budget_error")" = "E_LIMIT $resolver_budget_reason" ] ||
    fail_case "$resolver_name public token"
  pass_case "$resolver_name"
}

expect_cache_reuse() {
  resolver_cache_scratch="$resolver_tmp/cache-reuse"
  resolver_cache_result="$resolver_tmp/cache-reuse.result"
  resolver_cache_size=$(/usr/bin/git --git-dir="$resolver_fixture/profile/.git" \
    cat-file -s "$resolver_small_profile_oid")
  /bin/mkdir -m 700 "$resolver_cache_scratch" "$resolver_cache_scratch/object-cache"
  (
    set +e
    # shellcheck source=/dev/null
    source "$resolver_root/scripts/lib/profile-resolution.sh"
    exec 3>&2
    profile_resolution_initialize_git || exit 1
    profile_resolution_scratch=$resolver_cache_scratch
    profile_resolution_snapshots="$resolver_cache_scratch/snapshots.tsv"
    /usr/bin/printf '%s\t%s\tidentity\tsha1\n' repo.profile \
      "$resolver_fixture/profile/.git" > "$profile_resolution_snapshots"
    profile_resolution_value_remaining=$resolver_cache_size
    profile_resolution_global_remaining=$resolver_cache_size
    profile_resolution_verify_object_payload repo.profile sha1 \
      "$resolver_small_profile_oid" blob "$resolver_cache_scratch/first"
    first_status=$?
    profile_resolution_verify_object_payload repo.profile sha1 \
      "$resolver_small_profile_oid" blob "$resolver_cache_scratch/second"
    second_status=$?
    if [ "$resolver_cache_scratch/first" -ef "$resolver_cache_scratch/second" ]; then
      same_snapshot=true
    else
      same_snapshot=false
    fi
    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' "$first_status" "$second_status" \
      "$profile_resolution_value_remaining" "$profile_resolution_global_remaining" \
      "$same_snapshot"
  ) > "$resolver_cache_result"
  [ "$(/usr/bin/sed -n '1p' "$resolver_cache_result")" = $'0\t0\t0\t0\ttrue' ] || {
    /bin/cat "$resolver_cache_result" >&2
    fail_case 'object cache reuse ledger'
  }
  pass_case 'cache hits reuse one snapshot without another byte write'
}

expect_internal_scratch_ledger() {
  resolver_ledger_scratch="$resolver_tmp/internal-ledger"
  resolver_ledger_result="$resolver_tmp/internal-ledger.result"
  /bin/mkdir -m 700 "$resolver_ledger_scratch"
  (
    set +e
    # shellcheck source=/dev/null
    source "$resolver_root/scripts/lib/profile-resolution.sh"
    profile_resolution_global_remaining=4
    profile_resolution_limit_reason=''
    profile_resolution_write_text "$resolver_ledger_scratch/exact" abc
    exact_status=$?
    profile_resolution_write_text "$resolver_ledger_scratch/over" x
    over_status=$?
    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' "$exact_status" "$over_status" \
      "$profile_resolution_global_remaining" "$profile_resolution_limit_reason" \
      "$([ ! -e "$resolver_ledger_scratch/over" ] && /usr/bin/printf true || /usr/bin/printf false)"
  ) > "$resolver_ledger_result"
  [ "$(/usr/bin/sed -n '1p' "$resolver_ledger_result")" = $'0\t50\t0\tscratch-size\ttrue' ] ||
    fail_case 'pre-write scratch ledger'
  pass_case 'one pre-write ledger admits exact bytes and rejects one over'
}

expect_core_accounted_receipt() {
  resolver_core_scratch="$resolver_tmp/core-accounted"
  resolver_core_result="$resolver_tmp/core-accounted.result"
  resolver_core_error="$resolver_tmp/core-accounted.error"
  /bin/mkdir -m 700 "$resolver_core_scratch"
  (
    set +e
    # shellcheck source=/dev/null
    source "$resolver_root/scripts/lib/profile-resolution.sh"
    exec 3> "$resolver_core_error"
    PATH="$resolver_bin:/usr/bin:/bin"
    export PATH
    # shellcheck disable=SC2034
    profile_resolution_scratch=$resolver_core_scratch
    # shellcheck disable=SC2034
    profile_resolution_core=$resolver_core
    profile_resolution_global_remaining=536870912
    profile_resolution_core_validate validate-document \
      "$resolver_fixture/profile/profiles/default.json"
    core_status=$?
    core_spent=$((536870912 - profile_resolution_global_remaining))
    /usr/bin/printf '%s\t%s\n' "$core_status" "$core_spent"
  ) > "$resolver_core_result"
  resolver_core_status=$(/usr/bin/awk -F '\t' 'NR == 1 { print $1 }' "$resolver_core_result")
  resolver_core_spent=$(/usr/bin/awk -F '\t' 'NR == 1 { print $2 }' "$resolver_core_result")
  [ "$resolver_core_status" = 0 ] && [ "$resolver_core_spent" -gt 0 ] &&
    [ ! -s "$resolver_core_error" ] || fail_case 'accounted core receipt debit'
  pass_case 'core scratch receipt is exact and debited from the parent ledger'
}

resolver_ambient_bin="$resolver_tmp/ambient-bin"
resolver_ambient_request="$resolver_tmp/ambient-awk-request.json"
/bin/mkdir -m 700 "$resolver_ambient_bin"
/bin/ln -s /does/not/exist "$resolver_ambient_bin/awk"
/usr/bin/printf '%s\n' '{' > "$resolver_ambient_request"
PATH="$resolver_ambient_bin:/usr/bin:/bin" expect_failure \
  'symlinked ambient awk is ignored' E_PARSE "$resolver_ambient_request" "$resolver_tmp/no-map.ambient"
expect_missing_dependency

expect_launcher_failure 'launcher sanitizes silent child failure' silent 'E_RUNTIME unexpected'
expect_launcher_failure 'launcher converts file limit to a token' file 'E_LIMIT resource-limit'
expect_launcher_failure 'launcher bounds its process group' process 'E_LIMIT process-limit'
expect_launcher_failure 'launcher bounds each process virtual address space' memory 'E_LIMIT resource-limit'
expect_git_wall_failure
expect_internal_scratch_ledger
expect_core_accounted_receipt

resolver_large_package_oid=$("$resolver_bound_jq" -r \
  '.body.bindings[] | select(.role == "producer") | .package_ref.object_id' \
  "$resolver_fixture/profile/profiles/large.json")
resolver_small_profile_oid=$("$resolver_bound_jq" -r '.profile_source.object_id' \
  "$resolver_fixture/request.json")
expect_cache_reuse
expect_internal_budget_failure 'per-value budget keeps E_LIMIT' repo.assets \
  "$resolver_fixture/assets/.git" sha256 "$resolver_large_package_oid" 67108864 536870912 value-size
expect_internal_budget_failure 'aggregate value budget keeps E_LIMIT' repo.profile \
  "$resolver_fixture/profile/.git" sha1 "$resolver_small_profile_oid" 1 536870912 value-size
expect_internal_budget_failure 'global scratch budget keeps E_LIMIT' repo.profile \
  "$resolver_fixture/profile/.git" sha1 "$resolver_small_profile_oid" 67108864 1 scratch-size

resolver_output="$resolver_tmp/resolved.json"
[ "$("$resolver_bound_jq" -r '.version' "$resolver_fixture/request.json")" = 1 ] &&
  [ "$("$resolver_bound_jq" -r '.version' "$resolver_fixture/map.json")" = 1 ] ||
  fail_case 'resolver transport version'
pass_case 'request and repository-map transport remain version 1'
run_resolver "$resolver_tmp/sandbox.success" "$resolver_fixture/request.json" "$resolver_fixture/map.json" \
  > "$resolver_output" 2> "$resolver_tmp/success.stderr" || {
    /bin/cat "$resolver_tmp/success.stderr" >&2
    fail_case 'cross-hash multi-repository resolution'
  }
[ ! -s "$resolver_tmp/success.stderr" ] || fail_case 'success stderr is empty'
[ ! -e "$resolver_loader_marker" ] || fail_case 'clean resolver child loaded hostile library'
[ "$("$resolver_bound_jq" -r '.schema_version' "$resolver_output")" = 2 ] || fail_case 'output schema major'
"$resolver_bound_jq" -e '
  .body.profile_ref.schema_version == 2 and
  all(.body.bindings[]; .binding.manifest_ref.schema_version == 2)
' "$resolver_output" >/dev/null || fail_case 'output reference schema major'
[ "$("$resolver_bound_jq" -r '.kind' "$resolver_output")" = resolved_profile ] || fail_case 'output kind'
PATH="$resolver_bin:/usr/bin:/bin" /bin/bash "$resolver_core" validate-profile-set \
  "$resolver_fixture/profile/profiles/default.json" "$resolver_output" \
  "$resolver_fixture/manifests/manifests/forge.json" \
  "$resolver_fixture/manifests/manifests/producer.json" \
  "$resolver_fixture/manifests/manifests/publisher.json" \
  "$resolver_fixture/manifests/manifests/reviewer.json" \
  "$resolver_fixture/manifests/manifests/verifier.json"
pass_case 'cross-hash multi-repository resolution and real core validation'

resolver_bare_output="$resolver_tmp/resolved.bare.json"
run_resolver "$resolver_tmp/sandbox.bare" "$resolver_fixture/request.json" "$resolver_bare_map" \
  > "$resolver_bare_output" 2> "$resolver_tmp/bare.stderr"
[ ! -s "$resolver_tmp/bare.stderr" ] || fail_case 'bare public stderr'
/usr/bin/cmp -s "$resolver_output" "$resolver_bare_output" || fail_case 'bare repository determinism'
pass_case 'bare repositories resolve the same exact graph'

resolver_linked_output="$resolver_tmp/resolved.linked.json"
run_resolver "$resolver_tmp/sandbox.linked" "$resolver_fixture/request.json" "$resolver_linked_map" \
  > "$resolver_linked_output" 2> "$resolver_tmp/linked.stderr"
[ ! -s "$resolver_tmp/linked.stderr" ] || fail_case 'linked public stderr'
/usr/bin/cmp -s "$resolver_output" "$resolver_linked_output" || fail_case 'linked worktree determinism'
pass_case 'linked worktrees resolve the same exact graph'

for resolver_layout in normal bare linked; do
  case "$resolver_layout" in
    normal) resolver_reuse_map="$resolver_fixture/map.json"; resolver_first_sandbox="$resolver_tmp/sandbox.success" ;;
    bare) resolver_reuse_map=$resolver_bare_map; resolver_first_sandbox="$resolver_tmp/sandbox.bare" ;;
    linked) resolver_reuse_map=$resolver_linked_map; resolver_first_sandbox="$resolver_tmp/sandbox.linked" ;;
  esac
  resolver_reuse_output="$resolver_tmp/reused.$resolver_layout.stdout"
  resolver_reuse_error="$resolver_tmp/reused.$resolver_layout.stderr"
  resolver_reuse_sandbox="$resolver_tmp/sandbox.reused.$resolver_layout"
  run_resolver "$resolver_reuse_sandbox" "$resolver_fixture/request.json" "$resolver_reuse_map" \
    > "$resolver_reuse_output" 2> "$resolver_reuse_error" || fail_case 'reused native layout'
  /usr/bin/cmp -s "$resolver_output" "$resolver_reuse_output" &&
    /usr/bin/cmp -s "$resolver_output" "$resolver_reuse_sandbox/child.stdout" &&
    /usr/bin/cmp -s "$resolver_output" "$resolver_first_sandbox/child.stdout" &&
    [ ! -s "$resolver_reuse_error" ] && [ ! -s "$resolver_first_sandbox/child.stderr" ] ||
    fail_case 'fresh/reused canonical bytes or raw errors'
  printf 'native reused %s: canonical_sha=%s home=empty tmp=empty raw_stderr=empty\n' \
    "$resolver_layout" "$(sha256_file "$resolver_reuse_output")"
done


resolver_one_segment_output="$resolver_tmp/resolved.one-segment.json"
run_resolver "$resolver_tmp/sandbox.one-segment" "$resolver_one_segment_request" \
  "$resolver_fixture/map.json" > "$resolver_one_segment_output"
[ "$("$resolver_bound_jq" -r '.kind' "$resolver_one_segment_output")" = resolved_profile ] ||
  fail_case 'one-segment profile resolution'
pass_case 'one-segment path verifies its root tree before enumeration'

resolver_quoted_output="$resolver_tmp/resolved.quoted.json"
run_resolver "$resolver_tmp/sandbox.quoted" "$resolver_quoted_request" \
  "$resolver_fixture/map.json" > "$resolver_quoted_output"
[ "$("$resolver_bound_jq" -r '.kind' "$resolver_quoted_output")" = resolved_profile ] ||
  fail_case 'quoted path resolution'
pass_case 'NUL tree parsing matches a quoted path as raw bytes'
expect_failure 'newline path is rejected without confusing tree parsing' 'E_INPUT locator-shape' \
  "$resolver_newline_request" "$resolver_fixture/map.json"

resolver_bare_config="$resolver_bare/profile.git/config"
/bin/cp "$resolver_bare_config" "$resolver_tmp/bare.config.saved"
/usr/bin/printf '%s\n' '[include]' 'path = /private/tmp/ystack-profile-resolver-bare-canary' >> "$resolver_bare_config"
expect_failure 'bare repository rejects config include' 'E_REPOSITORY config-include' \
  "$resolver_fixture/request.json" "$resolver_bare_map"
/bin/cp "$resolver_tmp/bare.config.saved" "$resolver_bare_config"

resolver_linked_gitfile="$resolver_linked/profile/.git"
/bin/cp "$resolver_linked_gitfile" "$resolver_tmp/linked.gitfile.saved"
/usr/bin/printf '%s\n' 'gitdir: /does/not/exist' > "$resolver_linked_gitfile"
expect_failure 'linked worktree rejects a broken gitfile' 'E_REPOSITORY gitfile' \
  "$resolver_fixture/request.json" "$resolver_linked_map"
/bin/cp "$resolver_tmp/linked.gitfile.saved" "$resolver_linked_gitfile"

resolver_profile_commit=$("$resolver_bound_jq" -r '.profile_source.commit_id' "$resolver_fixture/request.json")
resolver_profile_root_tree=$(/usr/bin/git -C "$resolver_fixture/profile" show -s --format=%T "$resolver_profile_commit")
resolver_profile_root_object="$resolver_fixture/profile/.git/objects/${resolver_profile_root_tree:0:2}/${resolver_profile_root_tree:2}"
[ -f "$resolver_profile_root_object" ] && [ ! -L "$resolver_profile_root_object" ] ||
  fail_case 'root tree loose-object fixture'
case "$resolver_platform" in
  Linux:x86_64) resolver_profile_root_mode=$(/usr/bin/stat -c '%a' "$resolver_profile_root_object") ;;
  Darwin:*) resolver_profile_root_mode=$(/usr/bin/stat -f '%Lp' "$resolver_profile_root_object") ;;
esac
/bin/cp "$resolver_profile_root_object" "$resolver_tmp/profile-root-tree.saved"
/bin/chmod 0600 "$resolver_profile_root_object"
/usr/bin/printf '%s\n' corrupt > "$resolver_profile_root_object"
expect_failure 'corrupt root tree fails before one-segment walk' 'E_OBJECT object-path' \
  "$resolver_one_segment_request" "$resolver_fixture/map.json"
/bin/cp "$resolver_tmp/profile-root-tree.saved" "$resolver_profile_root_object"
/bin/chmod "$resolver_profile_root_mode" "$resolver_profile_root_object"

resolver_inline_config="$resolver_fixture/profile/.git/config"
/bin/cp "$resolver_inline_config" "$resolver_tmp/inline.config.saved"
/usr/bin/sed 's/repositoryformatversion = 0/repositoryformatversion = 0 # accepted inline comment/' \
  "$resolver_tmp/inline.config.saved" > "$resolver_inline_config"
/usr/bin/printf '%s\n' '[fixture]' 'value = "literal # and ; characters"' >> "$resolver_inline_config"
resolver_inline_output="$resolver_tmp/resolved.inline-comment.json"
run_resolver "$resolver_tmp/sandbox.inline-comment" "$resolver_fixture/request.json" \
  "$resolver_fixture/map.json" > "$resolver_inline_output"
/usr/bin/cmp -s "$resolver_output" "$resolver_inline_output" || fail_case 'inline comment output drift'
pass_case 'unquoted inline comment is accepted and quoted comment characters stay literal'

/usr/bin/sed 's/repositoryformatversion = 0/repositoryformatversion = "0 # quoted literal"/' \
  "$resolver_tmp/inline.config.saved" > "$resolver_inline_config"
expect_failure 'quoted comment text is not stripped from storage format' 'E_REPOSITORY storage-format' \
  "$resolver_fixture/request.json" "$resolver_fixture/map.json"
/bin/cp "$resolver_tmp/inline.config.saved" "$resolver_inline_config"

resolver_second="$resolver_tmp/resolved.second.json"
resolver_permuted_map="$resolver_tmp/map.permuted.json"
resolver_permuted_request="$resolver_tmp/request.permuted.json"
"$resolver_bound_jq" -S -c '.repositories |= reverse' "$resolver_fixture/map.json" > "$resolver_permuted_map"
"$resolver_bound_jq" -S -c '.manifest_sources |= reverse' "$resolver_fixture/request.json" > "$resolver_permuted_request"
run_resolver "$resolver_tmp/sandbox.second" "$resolver_permuted_request" "$resolver_permuted_map" > "$resolver_second"
/usr/bin/cmp -s "$resolver_output" "$resolver_second" || fail_case 'map-order determinism'
pass_case 'map/source order and physical scratch do not affect output'

if /usr/bin/grep -q 'token-do-not-echo\|ystack-profile-resolver-must-not-run\|/private/' "$resolver_output"; then
  fail_case 'opaque bytes or physical roots leaked into output'
fi
[ ! -e /tmp/ystack-profile-resolver-must-not-run ] || fail_case 'selected content executed'
pass_case 'selected content remains inert and private'

"$resolver_bound_jq" -e --slurpfile request "$resolver_fixture/request.json" \
  '.body.selection_ref == $request[0].selection_ref and
   .body.repository_context_ref == $request[0].repository_context_ref' "$resolver_output" >/dev/null ||
  fail_case 'caller scopes changed'
pass_case 'caller-owned scope refs are copied unchanged'

case "$resolver_platform" in
  Linux:x86_64) resolver_runtime_mode=$(/usr/bin/stat -c '%a' "$resolver_runtime") ;;
  Darwin:*) resolver_runtime_mode=$(/usr/bin/stat -f '%Lp' "$resolver_runtime") ;;
esac
[ "$resolver_runtime_mode" = 644 ] || fail_case 'inactive runtime mode'
pass_case 'runtime payload is inactive mode 0644'

resolver_bad="$resolver_tmp/request.parse.json"
/usr/bin/printf '%s\n' '{' > "$resolver_bad"
expect_failure 'malformed request before map access' E_PARSE "$resolver_bad" "$resolver_tmp/no-map"

resolver_zero="$resolver_tmp/request.zero.json"
"$resolver_bound_jq" -S -c '.manifest_sources=[]' "$resolver_fixture/request.json" > "$resolver_zero"
expect_failure 'zero manifests has fixed precedence' 'E_INPUT manifest-count' "$resolver_zero" "$resolver_tmp/no-map.zero"

resolver_nine="$resolver_tmp/request.nine.json"
"$resolver_bound_jq" -S -c '.manifest_sources[0] as $manifest | .manifest_sources = [range(0;9) | $manifest]' \
  "$resolver_fixture/request.json" > "$resolver_nine"
expect_failure 'nine manifests has fixed precedence' 'E_INPUT manifest-count' "$resolver_nine" "$resolver_tmp/no-map.nine"

resolver_noncanonical="$resolver_tmp/request.noncanonical.json"
"$resolver_bound_jq" . "$resolver_fixture/request.json" > "$resolver_noncanonical"
expect_failure 'noncanonical request' E_CANONICAL "$resolver_noncanonical" "$resolver_fixture/map.json"

resolver_missing_map="$resolver_tmp/map.missing.json"
"$resolver_bound_jq" -S -c '.repositories |= map(select(.repository_id != "repo.profile"))' \
  "$resolver_fixture/map.json" > "$resolver_missing_map"
expect_failure 'locator map missing' 'E_REPOSITORY locator-map-missing' \
  "$resolver_fixture/request.json" "$resolver_missing_map"

resolver_extra_map="$resolver_tmp/map.extra.json"
"$resolver_bound_jq" -S -c --arg root "$resolver_fixture/assets" \
  '.repositories += [{repository_id:"repo.extra",root:$root}]' "$resolver_fixture/map.json" > "$resolver_extra_map"
expect_failure 'unused map rejected after source join' 'E_REPOSITORY map-extra' \
  "$resolver_fixture/request.json" "$resolver_extra_map"

resolver_wrong_oid="$resolver_tmp/request.wrong-oid.json"
"$resolver_bound_jq" -S -c '.profile_source.object_id = ("0" * 40)' \
  "$resolver_fixture/request.json" > "$resolver_wrong_oid"
expect_failure 'wrong selected object id' 'E_OBJECT object-path' "$resolver_wrong_oid" "$resolver_fixture/map.json"

resolver_locator_shape="$resolver_tmp/request.locator-shape.json"
"$resolver_bound_jq" -S -c '.profile_source.commit_id = "main"' \
  "$resolver_fixture/request.json" > "$resolver_locator_shape"
expect_failure 'revision expressions fail before Git' 'E_INPUT locator-shape' \
  "$resolver_locator_shape" "$resolver_fixture/map.json"

resolver_duplicate_map="$resolver_tmp/map.duplicate.json"
"$resolver_bound_jq" -S -c '.repositories += [.repositories[0]]' \
  "$resolver_fixture/map.json" > "$resolver_duplicate_map"
expect_failure 'duplicate logical map id' 'E_INPUT map-shape' \
  "$resolver_fixture/request.json" "$resolver_duplicate_map"

resolver_oversize="$resolver_tmp/request.oversize.json"
/bin/dd if=/dev/zero of="$resolver_oversize" bs=1048576 count=1 2>/dev/null
/usr/bin/printf x >> "$resolver_oversize"
expect_failure 'request one byte over transport limit' E_LIMIT \
  "$resolver_oversize" "$resolver_tmp/no-map.oversize"

expect_failure 'selected value over per-value limit stays E_LIMIT' 'E_LIMIT value-size' \
  "$resolver_fixture/request-value-limit.json" "$resolver_fixture/map.json"

resolver_missing_manifest="$resolver_tmp/request.manifest-missing.json"
"$resolver_bound_jq" -S -c '.manifest_sources = .manifest_sources[0:3]' \
  "$resolver_fixture/request.json" > "$resolver_missing_manifest"
expect_failure 'manifest source join reports missing' 'E_RELATION manifest-source-missing' \
  "$resolver_missing_manifest" "$resolver_fixture/map.json"

/bin/ln -s "$resolver_fixture/profile" "$resolver_tmp/profile-link"
resolver_symlink_map="$resolver_tmp/map.symlink.json"
"$resolver_bound_jq" -S -c --arg root "$resolver_tmp/profile-link" \
  '(.repositories[] | select(.repository_id == "repo.profile").root) = $root' \
  "$resolver_fixture/map.json" > "$resolver_symlink_map"
expect_failure 'symlinked mapped root' 'E_REPOSITORY root' \
  "$resolver_fixture/request.json" "$resolver_symlink_map"

resolver_leak_map="$resolver_tmp/map.leak.json"
"$resolver_bound_jq" -S -c --arg root "$resolver_tmp/does-not-exist-secret-canary" \
  '(.repositories[] | select(.repository_id == "repo.profile").root) = $root' \
  "$resolver_fixture/map.json" > "$resolver_leak_map"
resolver_leak_out="$resolver_tmp/leak.stdout"
resolver_leak_err="$resolver_tmp/leak.stderr"
if run_resolver "$resolver_tmp/sandbox.leak" "$resolver_fixture/request.json" "$resolver_leak_map" \
    > "$resolver_leak_out" 2> "$resolver_leak_err"; then
  fail_case 'private root failure'
fi
[ ! -s "$resolver_leak_out" ] || fail_case 'private root failure stdout'
if /usr/bin/grep -q 'secret-canary\|does-not-exist' "$resolver_leak_err"; then
  fail_case 'physical path leaked'
fi
pass_case 'physical repository paths stay out of errors'

resolver_assets_config="$resolver_fixture/assets/.git/config"
/bin/cp "$resolver_assets_config" "$resolver_tmp/assets.config.saved"
/usr/bin/printf '%s\n' '[include]' 'path = /private/tmp/ystack-profile-resolver-include-canary' >> "$resolver_assets_config"
expect_failure 'mapped config include stays inert' 'E_REPOSITORY config-include' \
  "$resolver_fixture/request.json" "$resolver_fixture/map.json"
/bin/cp "$resolver_tmp/assets.config.saved" "$resolver_assets_config"

resolver_replace_source=$("$resolver_bound_jq" -r '.profile_source.object_id' "$resolver_fixture/request.json")
resolver_replace_target=$(/usr/bin/git -C "$resolver_fixture/profile" rev-parse 'HEAD^{tree}')
/usr/bin/git -C "$resolver_fixture/profile" update-ref "refs/replace/$resolver_replace_source" "$resolver_replace_target"
expect_failure 'replacement refs fail before private Git' 'E_REPOSITORY replacement-state' \
  "$resolver_fixture/request.json" "$resolver_fixture/map.json"
/usr/bin/git -C "$resolver_fixture/profile" update-ref -d "refs/replace/$resolver_replace_source"
/bin/rmdir "$resolver_fixture/profile/.git/refs/replace" 2>/dev/null || :

resolver_helper_out="$resolver_tmp/helper-limit.stdout"
resolver_helper_err="$resolver_tmp/helper-limit.stderr"
if "$resolver_bin/nofollow-snapshot" snapshot-repository "$resolver_fixture/profile" \
    "$resolver_tmp/helper-limit-output" 1 268435456 262144 16777216 536870912 \
    > "$resolver_helper_out" 2> "$resolver_helper_err"; then
  fail_case 'helper admin limit'
fi
if [ -s "$resolver_helper_out" ] || [ -e "$resolver_tmp/helper-limit-output" ] ||
   ! /usr/bin/grep -q '^E_LIMIT ' "$resolver_helper_err"; then
  fail_case 'helper admin limit closure'
fi
pass_case 'native helper enforces budgets before publish'

resolver_fingerprints_after="$resolver_tmp/repository-fingerprints.after"
: > "$resolver_fingerprints_after"
for resolver_mapped_root in "${resolver_mapped_roots[@]}"; do
  /usr/bin/printf '%s\t%s\n' "$resolver_mapped_root" \
    "$(repository_fingerprint "$resolver_mapped_root")" >> "$resolver_fingerprints_after"
done
/usr/bin/cmp -s "$resolver_fingerprints_before" "$resolver_fingerprints_after" || {
  /usr/bin/diff -u "$resolver_fingerprints_before" "$resolver_fingerprints_after" >&2 || :
  fail_case 'mapped repository fingerprint changed'
}
pass_case 'refs, config, and object stores remain byte-identical'

record_runtime_identities after > "$resolver_tmp/identities.after"
/bin/cat "$resolver_tmp/identities.after"
/usr/bin/sed '1d' "$resolver_tmp/identities.before" > "$resolver_tmp/identities.before.files"
/usr/bin/sed '1d' "$resolver_tmp/identities.after" > "$resolver_tmp/identities.after.files"
/usr/bin/cmp -s "$resolver_tmp/identities.before.files" "$resolver_tmp/identities.after.files" ||
  fail_case 'native source or tool identity changed'
printf 'native raw resolved JSON begin\n'
/bin/cat "$resolver_output"
printf 'native raw resolved JSON end\n'
printf 'original cases: %s; added component controls: %s; reused layouts: 3\n' \
  "$resolver_passed" "$resolver_component_count"
[ "$resolver_passed" -eq "$resolver_total" ] || exit 1
printf 'portable profile resolution: %d/%d targeted cases passed\n' "$resolver_passed" "$resolver_total"
printf 'supported tuple: %s; jq=%s; core=%s; helper-source=%s\n' \
  "$resolver_host" "$(sha256_file "$resolver_jq")" \
  "$(/usr/bin/git -C "$resolver_root" hash-object scripts/core-contract.sh)" \
  "$(sha256_file "$resolver_helper_source")"

resolver_suite_complete=1
