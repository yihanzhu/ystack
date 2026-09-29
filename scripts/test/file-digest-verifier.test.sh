#!/usr/bin/env bash
# Proves the fixed file-digest verifier (ystack #437) against a test build
# whose only difference from production is its sandbox root. See
# work/fixed-file-digest-verifier/spec.md and plan.md. No privilege, chroot,
# namespace or mount is used; nothing here runs the verifier against a real
# sandbox, accepts its digest, or grants it authority.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
verifier_source="$root/verifiers/file-digest/v1/verifier.c"
build_script="$root/verifiers/file-digest/v1/build.sh"
incident_program="$root/shadow/v1/incident-record.jq"
python=/usr/bin/python3

fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || fail 'refuses to run as uid 0 (R8.1)'
[ ! -e /sandbox ] || fail '/sandbox must not exist for this test'

tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-file-digest-verifier-test.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() { /bin/chmod -R u+rwX "$tmp" 2>/dev/null || :; /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT

passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }

sha_file() { /usr/bin/shasum -a 256 -- "$1" | /usr/bin/awk '{print $1}'; }
sha_stdin() { /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'; }

# --- pinned jq 1.6, as scripts/test/shadow-slice.test.sh:24-51 ---------------
platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_asset=jq-linux64
    jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) fail "unsupported host $platform" ;;
esac
jq_cache_dir="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$jq_cache_dir"
jq_cache="$jq_cache_dir/$jq_asset"
if [ ! -f "$jq_cache" ] || [ -L "$jq_cache" ] ||
   [ "$(sha_file "$jq_cache")" != "$jq_sha" ]; then
  download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$download"
  [ "$(sha_file "$download")" = "$jq_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_cache"
fi
bin="$tmp/bin"
/bin/mkdir -m 700 "$bin"
/bin/cp "$jq_cache" "$bin/jq"
/bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"
[ "$("$jq_bin" --version)" = jq-1.6 ] || fail 'jq identity'
[ -x "$python" ] || fail 'python3 required'

# --- exact-exec helper: execve(path, argv, envp) with no shell in between --
cat > "$tmp/execer.c" <<'EOF'
#define _POSIX_C_SOURCE 200809L
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv)
{
    int sep = -1;
    int i;
    int envc, argvc;
    char **envp, **cargv;
    if (argc < 2) return 125;
    for (i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--") == 0) { sep = i; break; }
    }
    if (sep < 0) return 125;
    envc = sep - 2;
    argvc = argc - sep - 1;
    envp = (char **)malloc((size_t)(envc + 1) * sizeof(char *));
    cargv = (char **)malloc((size_t)(argvc + 1) * sizeof(char *));
    if (envp == NULL || cargv == NULL) return 125;
    for (i = 0; i < envc; i++) envp[i] = argv[2 + i];
    envp[envc] = NULL;
    for (i = 0; i < argvc; i++) cargv[i] = argv[sep + 1 + i];
    cargv[argvc] = NULL;
    execve(argv[1], cargv, envp);
    _exit(126);
}
EOF
/usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 "$tmp/execer.c" -o "$tmp/execer"
execer="$tmp/execer"

# Runs "$@" (already the execer invocation) with stdin from $1, stdout/stderr
# captured, bounded to 20s so a FIFO with no writer cannot hang the suite.
bounded_run() {
  local stdin_file=$1 out=$2 err=$3
  shift 3
  ( "$@" < "$stdin_file" > "$out" 2> "$err" ) &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge 20 ]; then
      kill -9 "$pid" 2>/dev/null || :
      wait "$pid" 2>/dev/null || :
      /usr/bin/printf 'TIMEOUT\n' >> "$err"
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

# --- instruction builder (arbitrary bytes via hex, so malformed framing can
# be built exactly without shell-escaping hazards) -------------------------
cat > "$tmp/mkinstr.py" <<'PY'
import sys, json, binascii
spec = json.load(sys.stdin)
def h(key, default=b""):
    if key not in spec or spec[key] is None:
        return default
    return binascii.unhexlify(spec[key])
if "raw_hex" in spec and spec["raw_hex"] is not None:
    data = h("raw_hex")
else:
    header = h("header_hex", b"ystack.file-digest-instruction.v1")
    sep = h("sep_hex", b"\x0a")
    line2 = h("line2_hex") if "line2_hex" in spec else b"path " + h("path_hex")
    line3 = h("line3_hex") if "line3_hex" in spec else b"sha256 " + spec.get("sha", "0" * 64).encode()
    trailing = h("trailing_hex")
    data = header + sep + line2 + sep + line3 + sep + trailing
sys.stdout.buffer.write(data)
PY
mkinstr() {
  # $1 = output file, $2 = JSON spec (see mkinstr.py)
  "$python" "$tmp/mkinstr.py" > "$1" <<PYIN
$2
PYIN
}
hex_of() { /usr/bin/printf '%s' "$1" | /usr/bin/od -v -An -tx1 | tr -d ' \n'; }

zero_sha="$(printf '0%.0s' $(seq 1 64))"

# --- candidate / evidence scaffolding --------------------------------------
troot="$tmp/troot"
/bin/mkdir -m 700 "$troot"
/bin/mkdir -m 700 "$troot/candidate" "$troot/evidence" "$troot/tools" "$troot/scratch"
candidate="$troot/candidate"
evidence="$troot/evidence"
result_path="$evidence/file-digest-result.json"

fresh_evidence() {
  /bin/rm -rf -- "$evidence"
  /bin/mkdir -m 700 "$evidence"
}

envp_ok=(LANG=C LC_ALL=C "PATH=$troot/tools" "TMPDIR=$troot/scratch")

# run_test_verifier <stdin-file> <out> <err> [argv0] [argv2..argv6 via defaults]
run_test_verifier() {
  local stdin_file=$1 out=$2 err=$3 argv0=${4:-"$test_verifier"}
  bounded_run "$stdin_file" "$out" "$err" \
    "$execer" "$test_verifier" "${envp_ok[@]}" -- \
    "$argv0" verify --candidate "$candidate" --evidence "$evidence"
}

reason_of() { "$jq_bin" -r '.body.reason_id // "null"' "$1"; }
outcome_of() { "$jq_bin" -r '.body.outcome' "$1"; }


# ===========================================================================
# Builds (R1.2, R1.3, R8.1)
# ===========================================================================
out1="$tmp/build1"
out2="$tmp/build2"
bash "$build_script" build "$out1"
bash "$build_script" build "$out2"
[ -f "$out1/verifier" ] && [ -f "$out1/build-record.json" ] || fail 'build.sh did not write expected files'
[ "$(/bin/ls -A "$out1" | sort | tr '\n' ' ')" = "build-record.json verifier " ] || fail 'build.sh wrote extra files'
cmp -s "$out1/verifier" "$out2/verifier" || fail 'two production builds are not byte-identical (R1.3)'
pass 'two production builds are byte-identical'

canon1=$("$jq_bin" -S -c . "$out1/build-record.json")
[ "$canon1" = "$(cat "$out1/build-record.json")" ] || fail 'build-record.json is not its own canonical jq -S -c form'
pass 'build-record.json is canonical jq -S -c'

record_source_sha=$("$jq_bin" -r '.source_sha256' "$out1/build-record.json")
record_build_script_sha=$("$jq_bin" -r '.build_script_sha256' "$out1/build-record.json")
record_exe_sha=$("$jq_bin" -r '.executable_sha256' "$out1/build-record.json")
record_compiler_version_sha=$("$jq_bin" -r '.compiler_version_sha256' "$out1/build-record.json")
record_platform=$("$jq_bin" -r '.platform' "$out1/build-record.json")
record_flags=$("$jq_bin" -c '.flags' "$out1/build-record.json")

[ "$record_source_sha" = "$(sha_file "$verifier_source")" ] || fail 'source_sha256 mismatch'
[ "$record_build_script_sha" = "$(sha_file "$build_script")" ] || fail 'build_script_sha256 mismatch'
[ "$record_exe_sha" = "$(sha_file "$out1/verifier")" ] || fail 'executable_sha256 mismatch'
[ "$record_compiler_version_sha" = "$(/usr/bin/cc --version | sha_stdin)" ] || fail 'compiler_version_sha256 mismatch'
[ "$record_platform" = "$(/usr/bin/uname -s):$(/usr/bin/uname -m)" ] || fail 'platform mismatch'
[ "$record_flags" = '["-std=c11","-Wall","-Wextra","-Werror","-O2"]' ] || fail 'flags mismatch'
[ "$("$jq_bin" -r '.compiler_path' "$out1/build-record.json")" = /usr/bin/cc ] || fail 'compiler_path mismatch'
[ "$("$jq_bin" -r '.kind' "$out1/build-record.json")" = file_digest_verifier_build ] || fail 'kind mismatch'
[ "$("$jq_bin" -r '.schema_version' "$out1/build-record.json")" = 1 ] || fail 'schema_version mismatch'
[ "$("$jq_bin" -r '.sandbox_root' "$out1/build-record.json")" = /sandbox ] || fail 'sandbox_root mismatch'
pass 'build-record.json fields equal recomputed digests and constants'

direct_dir="$tmp/direct"
/bin/mkdir -m 700 "$direct_dir"
(CDPATH='' cd -- "$root/verifiers/file-digest/v1" &&
  /usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 verifier.c -o "$direct_dir/verifier")
cmp -s "$direct_dir/verifier" "$out1/verifier" ||
  fail 'compiling verifier.c directly with the record flags does not equal the production build'
pass 'build.sh adds nothing beyond compiling verifier.c with its recorded flags'

if bash "$build_script" build "$out1" 2>"$tmp/existing.err"; then
  fail 'build.sh must refuse an existing output directory'
fi
pass 'build.sh refuses an existing output directory'

if bash "$build_script" 2>/dev/null; then fail 'build.sh must refuse no arguments'; fi
if bash "$build_script" build 2>/dev/null; then fail 'build.sh must refuse a missing out-dir'; fi
if bash "$build_script" wrong "$tmp/never" 2>/dev/null; then fail 'build.sh must refuse a wrong verb'; fi
if bash "$build_script" build "$tmp/never" extra 2>/dev/null; then fail 'build.sh must refuse extra arguments'; fi
[ ! -e "$tmp/never" ] || fail 'a refused build.sh call must not create its out-dir'
pass 'build.sh refuses a wrong argument list and leaves only verifier and build-record.json'

# Test build: identical flags, only YSTACK_SANDBOX_ROOT changed (R8.1).
test_verifier="$tmp/test-verifier"
(CDPATH='' cd -- "$root/verifiers/file-digest/v1" &&
  /usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 -DYSTACK_SANDBOX_ROOT="\"$troot\"" \
    verifier.c -o "$test_verifier")
pass 'test build compiles with the production flags plus one sandbox-root define'

# ===========================================================================
# R2. Invocation and environment.
# ===========================================================================
empty_stdin="$tmp/empty-stdin"
: > "$empty_stdin"

check_r2_refused() {
  local desc=$1 expected_code=$2
  shift 2
  fresh_evidence
  local out="$tmp/r2.out" err="$tmp/r2.err"
  local status=0
  "$@" < "$empty_stdin" > "$out" 2> "$err" || status=$?
  [ "$status" -eq 64 ] || fail "$desc: expected exit 64, got $status"
  [ "$(cat "$err")" = "$expected_code" ] || fail "$desc: expected $expected_code on stderr, got $(cat "$err")"
  [ ! -e "$result_path" ] || fail "$desc: evidence directory must stay empty"
  [ ! -s "$out" ] || fail "$desc: stdout must be empty"
}

good_argv=(verify --candidate "$candidate" --evidence "$evidence")

# argv deviations: count 5 and 7, each position misspelled, swapped order,
# test-root paths given (they already are the test-root paths here, so a
# deviation is a *different* value than the fixed ones).
declare -a argv_cases_desc=()
declare -a argv_cases_argv=()
add_argv_case() { argv_cases_desc+=("$1"); shift; argv_cases_argv+=("$*"); }

add_argv_case "argc 5 (one too few)" verify --candidate "$candidate" --evidence
add_argv_case "argc 7 (one too many)" verify --candidate "$candidate" --evidence "$evidence" extra
add_argv_case "argv[1] misspelled" verifyx --candidate "$candidate" --evidence "$evidence"
add_argv_case "argv[2] misspelled" verify --candidatex "$candidate" --evidence "$evidence"
add_argv_case "argv[3] wrong path" verify --candidate "$candidate/x" --evidence "$evidence"
add_argv_case "argv[4] misspelled" verify --candidate "$candidate" --evidencex "$evidence"
add_argv_case "argv[5] wrong path" verify --candidate "$candidate" --evidence "$evidence/x"
add_argv_case "swapped order" --candidate "$candidate" verify --evidence "$evidence"

for i in "${!argv_cases_desc[@]}"; do
  # shellcheck disable=SC2086
  set -- ${argv_cases_argv[$i]}
  check_r2_refused "argv deviation: ${argv_cases_desc[$i]}" E_USAGE \
    "$execer" "$test_verifier" "${envp_ok[@]}" -- "$test_verifier" "$@"
done
pass 'every R2.1 argv deviation exits 64 E_USAGE with an empty evidence directory'

# environment deviations: missing, extra, duplicate, wrong value per
# variable, empty environment.
declare -a env_cases_desc=()
declare -a env_cases_env=()
add_env_case() { env_cases_desc+=("$1"); shift; env_cases_env+=("$*"); }

add_env_case "missing LANG" LC_ALL=C "PATH=$troot/tools" "TMPDIR=$troot/scratch"
add_env_case "missing LC_ALL" LANG=C "PATH=$troot/tools" "TMPDIR=$troot/scratch"
add_env_case "missing PATH" LANG=C LC_ALL=C "TMPDIR=$troot/scratch"
add_env_case "missing TMPDIR" LANG=C LC_ALL=C "PATH=$troot/tools"
add_env_case "extra entry" LANG=C LC_ALL=C "PATH=$troot/tools" "TMPDIR=$troot/scratch" EXTRA=1
add_env_case "duplicate entry" LANG=C LANG=C LC_ALL=C "PATH=$troot/tools" "TMPDIR=$troot/scratch"
add_env_case "wrong LANG" LANG=en_US.UTF-8 LC_ALL=C "PATH=$troot/tools" "TMPDIR=$troot/scratch"
add_env_case "wrong LC_ALL" LANG=C LC_ALL=en_US.UTF-8 "PATH=$troot/tools" "TMPDIR=$troot/scratch"
add_env_case "wrong PATH" LANG=C LC_ALL=C "PATH=$troot/tools/x" "TMPDIR=$troot/scratch"
add_env_case "wrong TMPDIR" LANG=C LC_ALL=C "PATH=$troot/tools" "TMPDIR=$troot/scratch/x"
add_env_case "empty environment"

for i in "${!env_cases_desc[@]}"; do
  # shellcheck disable=SC2086
  set -- ${env_cases_env[$i]}
  check_r2_refused "environment deviation: ${env_cases_desc[$i]}" E_ENVIRONMENT \
    "$execer" "$test_verifier" "$@" -- "$test_verifier" "${good_argv[@]}"
done
pass 'every R2.2 environment deviation exits 64 E_ENVIRONMENT with an empty evidence directory'


/usr/bin/printf 'total assertions: %s\n' "$passes" >&2
