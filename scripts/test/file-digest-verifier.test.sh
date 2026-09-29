#!/usr/bin/env bash
# Proves the fixed file-digest verifier (ystack #437) against a test build
# whose only difference from production is its sandbox root (see
# work/fixed-file-digest-verifier/spec.md, plan.md). No privilege, chroot,
# namespace or mount; nothing here runs against a real sandbox, accepts its
# digest, or grants it authority.
# shellcheck disable=SC2016
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
# hex_of_spec: path bytes from a JSON spec in a fixture file, not a command
# substitution of raw bytes (a lone LF is eaten as trailing; NUL cannot
# survive bash at all). spec: {"literal":s} or {"unit":s,"count":n,"suffix":s}.
cat > "$tmp/pathspec.py" <<'PY'
import sys, json, binascii
with open(sys.argv[1], "rb") as fh:
    spec = json.load(fh)
if "literal" in spec:
    s = spec["literal"]
else:
    s = spec["unit"] * spec["count"] + spec.get("suffix", "")
sys.stdout.write(binascii.hexlify(s.encode("utf-8")).decode())
PY
hex_of_spec() {
  local f="$tmp/pathspec.json"
  printf '%s' "$1" > "$f"
  "$python" "$tmp/pathspec.py" "$f"
}

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
# candidate_tree_digest: lstat tree digest (type/mode/size/link/content sha256)
# used by run_test_verifier for R7.2/R8.2 preservation on every case. A file
# the test itself made unreadable (mode 0000) is metadata-only: content is
# never read, its permissions never touched, and the skip is explicit.
cat > "$tmp/treedigest.py" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
lines = []
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    dirnames.sort()
    for name in sorted(filenames) + sorted(dirnames):
        full = os.path.join(dirpath, name)
        rel = os.path.relpath(full, root)
        st = os.lstat(full)
        kind = 'l' if os.path.islink(full) else ('d' if os.path.isdir(full) else 'f')
        entry = f"{rel}\t{kind}\t{oct(st.st_mode)}\t{st.st_size}"
        if os.path.islink(full):
            entry += f"\t{os.readlink(full)}"
        elif os.path.isfile(full) and not os.path.islink(full):
            try:
                with open(full, 'rb') as fh:
                    entry += f"\t{hashlib.sha256(fh.read()).hexdigest()}"
            except PermissionError:
                entry += "\tunreadable-content-skipped"
        lines.append(entry)
lines.sort()
h = hashlib.sha256("\n".join(lines).encode()).hexdigest()
print(h)
PY
candidate_tree_digest() { "$python" "$tmp/treedigest.py" "$candidate"; }

envp_ok=(LANG=C LC_ALL=C "PATH=$troot/tools" "TMPDIR=$troot/scratch")
# run_test_verifier <stdin> <out> <err> [argv0]: snapshots the candidate tree
# before/after every call, requiring it unchanged (R7.2/R8.2) regardless of outcome.
run_test_verifier() {
  local stdin_file=$1 out=$2 err=$3 argv0=${4:-"$test_verifier"}
  local before after status=0
  before=$(candidate_tree_digest)
  bounded_run "$stdin_file" "$out" "$err" \
    "$execer" "$test_verifier" "${envp_ok[@]}" -- \
    "$argv0" verify --candidate "$candidate" --evidence "$evidence" || status=$?
  after=$(candidate_tree_digest)
  [ "$before" = "$after" ] || fail 'the candidate tree changed across a verifier run (R7.2/R8.2)'
  return "$status"
}

reason_of() { "$jq_bin" -r '.body.reason_id // "null"' "$1"; }

outcome_of() { "$jq_bin" -r '.body.outcome' "$1"; }
# require_ok_run <desc> <stdin-file> <out> <err>: runs the verifier and
# requires exit 0 with empty stdout and stderr (R6.4: a consumer uses a
# payload only with exit 0; R6.1: stdout is always empty).
require_ok_run() {
  local desc=$1 stdin_file=$2 out=$3 err=$4 status=0
  run_test_verifier "$stdin_file" "$out" "$err" || status=$?
  [ "$status" -eq 0 ] || fail "$desc: expected exit 0, got $status"
  [ ! -s "$out" ] || fail "$desc: stdout must be empty"
  [ ! -s "$err" ] || fail "$desc: stderr must be empty"
}
# Builds (R1.2, R1.3, R8.1)
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
# R2. Invocation and environment.
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
prod_envp_ok=(LANG=C LC_ALL=C PATH=/sandbox/tools TMPDIR=/sandbox/scratch)
prod_good_argv=(verify --candidate /sandbox/candidate --evidence /sandbox/evidence)
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
  # Same test-root arguments sent to production: never equal its /sandbox
  # literals, so every one must also refuse (R8.2 / plan R2 proof).
  check_r2_refused "argv deviation: ${argv_cases_desc[$i]} (production build, test-root arguments)" E_USAGE \
    "$execer" "$out1/verifier" "${prod_envp_ok[@]}" -- "$out1/verifier" "$@"
done
pass 'every R2.1 argv deviation exits 64 E_USAGE with an empty evidence directory, on both the test build and the production build given test-root arguments'
# argv[0] of "x" still passes (not inspected).
fresh_evidence
argv0_status=0
"$execer" "$test_verifier" "${envp_ok[@]}" -- x "${good_argv[@]}" \
  < "$empty_stdin" > "$tmp/argv0.out" 2> "$tmp/argv0.err" || argv0_status=$?
[ "$argv0_status" -eq 0 ] || fail "argv[0] of x: expected exit 0, got $argv0_status"
[ ! -s "$tmp/argv0.out" ] || fail 'argv[0] of x: stdout must be empty'
[ ! -s "$tmp/argv0.err" ] || fail 'argv[0] of x: stderr must be empty'
[ -e "$result_path" ] || fail 'argv[0] of x must still be accepted'
pass 'argv[0] is not inspected'
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
  # Same test-root env sent to production (correct argv): never equal its
  # /sandbox/tools or /sandbox/scratch literals, so every one must refuse too.
  check_r2_refused "environment deviation: ${env_cases_desc[$i]} (production build, test-root environment)" E_ENVIRONMENT \
    "$execer" "$out1/verifier" "$@" -- "$out1/verifier" "${prod_good_argv[@]}"
done
pass 'every R2.2 environment deviation exits 64 E_ENVIRONMENT with an empty evidence directory, on both the test build and the production build given test-root environment values'
# Production positive control: exact /sandbox vectors, stdin /dev/null, must
# not be a 64 refusal (proves R2 checks argv/env shape only, not existence).
prod_out="$tmp/prod.out" prod_err="$tmp/prod.err"
prod_status=0
"$execer" "$out1/verifier" LANG=C LC_ALL=C PATH=/sandbox/tools TMPDIR=/sandbox/scratch -- \
  "$out1/verifier" verify --candidate /sandbox/candidate --evidence /sandbox/evidence \
  < /dev/null > "$prod_out" 2> "$prod_err" || prod_status=$?
[ "$prod_status" -eq 73 ] || fail "production positive control: expected exit 73, got $prod_status"
[ ! -s "$prod_out" ] || fail 'production positive control: stdout must be empty'
[ "$(cat "$prod_err")" = E_OUTPUT ] || fail 'production positive control: expected E_OUTPUT'
pass 'production build accepts the exact /sandbox vectors past R2 (exit 73, not 64)'
# R3. Trusted instruction transport and framing.

check_refusal() {
  # check_refusal <desc> <stdin-file> <expected-reason> [expect-instr-null]
  local desc=$1 stdin_file=$2 expected=$3 expect_null_instr=${4:-0}
  fresh_evidence
  local out="$tmp/case.out" err="$tmp/case.err"
  require_ok_run "$desc" "$stdin_file" "$out" "$err"
  [ -e "$result_path" ] || fail "$desc: no payload written"
  local outcome reason
  outcome=$(outcome_of "$result_path")
  reason=$(reason_of "$result_path")
  [ "$outcome" = refused ] || fail "$desc: expected outcome refused, got $outcome"
  [ "$reason" = "$expected" ] || fail "$desc: expected reason $expected, got $reason"
  if [ "$expect_null_instr" = 1 ]; then
    [ "$("$jq_bin" -r '.body.instruction_sha256 // "null"' "$result_path")" = null ] ||
      fail "$desc: instruction_sha256 must be null"
  fi
  [ "$("$jq_bin" -r '.body.check // "null"' "$result_path")" = null ] ||
    fail "$desc: check must be null for an instruction.* reason"
  local canon
  canon=$("$jq_bin" -S -c . "$result_path")
  [ "$canon" = "$(cat "$result_path")" ] || fail "$desc: payload is not canonical jq -S -c"
}
# transport-rejected: stdin as a pipe.
mkfifo_pipe="$tmp/instr.pipe"
/usr/bin/mkfifo "$mkfifo_pipe"
( /usr/bin/printf 'x' > "$mkfifo_pipe" ) &
writer_pid=$!
check_refusal 'fd 0 as a pipe' "$mkfifo_pipe" instruction.transport-rejected 1
wait "$writer_pid" 2>/dev/null || :
pass 'a pipe on fd 0 gives instruction.transport-rejected with a null instruction digest'
# oversize: 4,209 bytes.
mkinstr "$tmp/i-oversize.bin" "{\"path_hex\":\"$(hex_of "$(/usr/bin/printf 'a%.0s' $(seq 1 4097))")\",\"sha\":\"$zero_sha\"}"
[ "$(wc -c < "$tmp/i-oversize.bin")" -eq 4209 ] || fail 'oversize fixture wrong size'
check_refusal '4,209-byte instruction' "$tmp/i-oversize.bin" instruction.oversize 1
pass 'a 4,209-byte instruction gives instruction.oversize with a null instruction digest'
# largest valid instruction (4,208 bytes, 4,096-byte path): not instruction.*.
big_path=$(/usr/bin/printf 'a%.0s' $(seq 1 4096))
mkinstr "$tmp/i-4208.bin" "{\"path_hex\":\"$(hex_of "$big_path")\",\"sha\":\"$zero_sha\"}"
[ "$(wc -c < "$tmp/i-4208.bin")" -eq 4208 ] || fail '4,208-byte fixture has the wrong size'
fresh_evidence; require_ok_run '4,208-byte instruction' "$tmp/i-4208.bin" "$tmp/big.out" "$tmp/big.err"
reason=$(reason_of "$result_path")
case "$reason" in
  instruction.*) fail "4,208-byte instruction must not be an instruction.* rejection (got $reason)" ;;
esac
pass 'the longest valid instruction (4,208 bytes) is not an instruction.* rejection'
# trailing: one byte after the third LF.
mkinstr "$tmp/i-trailing.bin" "{\"path_hex\":\"$(hex_of file.txt)\",\"sha\":\"$zero_sha\",\"trailing_hex\":\"78\"}"; check_refusal 'one trailing byte after the third LF' "$tmp/i-trailing.bin" instruction.trailing
pass 'a byte after the third LF gives instruction.trailing'
# fourth line (also trailing, since it is bytes after the third LF).
mkinstr "$tmp/i-fourth.bin" "{\"path_hex\":\"$(hex_of file.txt)\",\"sha\":\"$zero_sha\",\"trailing_hex\":\"$(hex_of $'extra\n')\"}"; check_refusal 'a fourth line' "$tmp/i-fourth.bin" instruction.trailing
pass 'a fourth line gives instruction.trailing'
# malformed: fewer than three LF (missing final LF -- only two LFs present).
mkinstr "$tmp/i-nolf.bin" "{\"raw_hex\":\"$(hex_of "ystack.file-digest-instruction.v1
path file.txt
sha256 $zero_sha")\"}"
check_refusal 'missing final LF' "$tmp/i-nolf.bin" instruction.malformed
pass 'a missing final LF gives instruction.malformed'
# malformed: CRLF framing.
mkinstr "$tmp/i-crlf.bin" "{\"sep_hex\":\"0d0a\",\"path_hex\":\"$(hex_of file.txt)\",\"sha\":\"$zero_sha\"}"; check_refusal 'CRLF framing' "$tmp/i-crlf.bin" instruction.malformed
pass 'CRLF framing gives instruction.malformed'
# malformed: BOM before the header.
mkinstr "$tmp/i-bom.bin" "{\"header_hex\":\"efbbbf79737461636b2e66696c652d6469676573742d696e737472756374696f6e2e7631\",\"path_hex\":\"$(hex_of file.txt)\",\"sha\":\"$zero_sha\"}"; check_refusal 'BOM before the header' "$tmp/i-bom.bin" instruction.malformed
pass 'a BOM before the header gives instruction.malformed'
# malformed: uppercase hex digest.
mkinstr "$tmp/i-upperhex.bin" "{\"path_hex\":\"$(hex_of file.txt)\",\"sha\":\"$(printf 'A%.0s' $(seq 1 64))\"}"; check_refusal 'uppercase hex digest' "$tmp/i-upperhex.bin" instruction.malformed
pass 'an uppercase hex digest gives instruction.malformed'
# malformed: 63 and 65 hex digits.
mkinstr "$tmp/i-63hex.bin" "{\"path_hex\":\"$(hex_of file.txt)\",\"line3_hex\":\"$(hex_of "sha256 $(printf '0%.0s' $(seq 1 63))")\"}"; check_refusal '63 hex digits' "$tmp/i-63hex.bin" instruction.malformed
mkinstr "$tmp/i-65hex.bin" "{\"path_hex\":\"$(hex_of file.txt)\",\"line3_hex\":\"$(hex_of "sha256 $(printf '0%.0s' $(seq 1 65))")\"}"; check_refusal '65 hex digits' "$tmp/i-65hex.bin" instruction.malformed
pass '63 and 65 hex digits both give instruction.malformed'
# malformed: wrong / reordered keys.
mkinstr "$tmp/i-wrongkey.bin" "{\"line2_hex\":\"$(hex_of "route file.txt")\",\"sha\":\"$zero_sha\"}"; check_refusal 'wrong key on line 2' "$tmp/i-wrongkey.bin" instruction.malformed
mkinstr "$tmp/i-reordered.bin" "{\"line2_hex\":\"$(hex_of "sha256 $zero_sha")\",\"line3_hex\":\"$(hex_of "path file.txt")\"}"; check_refusal 'reordered keys' "$tmp/i-reordered.bin" instruction.malformed
pass 'a wrong or reordered key gives instruction.malformed'
# malformed: NUL byte in the path.
mkinstr "$tmp/i-nul.bin" "{\"path_hex\":\"$(hex_of file)00$(hex_of .txt)\",\"sha\":\"$zero_sha\"}"; check_refusal 'a NUL byte' "$tmp/i-nul.bin" instruction.malformed
pass 'a NUL byte gives instruction.malformed'
# malformed: a trailing space before a line's LF.
mkinstr "$tmp/i-trailspace.bin" "{\"path_hex\":\"$(hex_of "file.txt ")\",\"sha\":\"$zero_sha\"}"; check_refusal "line 2's last byte before its LF is a space" "$tmp/i-trailspace.bin" instruction.malformed
pass "a trailing space before a line's LF gives instruction.malformed"
# malformed: each invalid UTF-8 class in the path.
mkinstr "$tmp/i-utf8-lone.bin" "{\"path_hex\":\"ff\",\"sha\":\"$zero_sha\"}"; check_refusal 'a lone 0xff byte' "$tmp/i-utf8-lone.bin" instruction.malformed
mkinstr "$tmp/i-utf8-overlong.bin" "{\"path_hex\":\"c0af\",\"sha\":\"$zero_sha\"}"; check_refusal 'an overlong form' "$tmp/i-utf8-overlong.bin" instruction.malformed
mkinstr "$tmp/i-utf8-surrogate.bin" "{\"path_hex\":\"eda080\",\"sha\":\"$zero_sha\"}"; check_refusal 'a surrogate' "$tmp/i-utf8-surrogate.bin" instruction.malformed
mkinstr "$tmp/i-utf8-above.bin" "{\"path_hex\":\"f4908080\",\"sha\":\"$zero_sha\"}"; check_refusal 'a code point above U+10FFFF' "$tmp/i-utf8-above.bin" instruction.malformed
mkinstr "$tmp/i-utf8-trunc.bin" "{\"path_hex\":\"e282\",\"sha\":\"$zero_sha\"}"; check_refusal 'a truncated sequence' "$tmp/i-utf8-trunc.bin" instruction.malformed
pass 'every invalid UTF-8 class in the path gives instruction.malformed'
# R4 differential: verifier vs. pinned jq's repo_path_ok, and the shape check.
record_skeleton() {
  # $1 is a JSON string literal, passed straight to jq via --argjson so
  # control bytes (LF/CR/NUL) stay in jq's memory, not a bash command
  # substitution (which strips a lone trailing LF and can't carry NUL at all).
  local path_json_literal=$1
  "$jq_bin" -S -c -n --argjson path "$path_json_literal" --arg sha "$zero_sha" '
    {schema_version:1,kind:"shadow_incident_record",id:"incident.r4-differential",
     body:{deploy_authority:"none",target_repository_id:"fixture.target",
       git_revision_ref:{repository_id:"fixture.target",hash_algorithm:"sha1",
         commit_id:("a"*40)},
       failing_check:{kind:"file-digest",path:$path,expected_sha256:$sha},
       observed_symptom:"fixture",
       reporter_actor_ref:"actor.fixture",
       observed_at:"2026-08-30T00:00:04Z"}}'
}

differential_case() {
  # differential_case <desc> <path-hex>
  local desc=$1 path_hex=$2
  local path_json
  path_json=$("$python" - "$path_hex" <<'PY'
import sys, binascii, json
print(json.dumps(binascii.unhexlify(sys.argv[1]).decode("utf-8")))
PY
)
  # jq's own predicate.
  local jq_accepts
  if "$jq_bin" -e --argjson p "$path_json" -n '$p | (
      type == "string" and utf8bytelength >= 1 and utf8bytelength <= 4096 and
      (test("[[:cntrl:]]") | not) and (contains("\\") | not) and
      (startswith("/") | not) and
      (split("/") | length <= 64 and
       all(.[]; . != "" and . != "." and . != ".." and (ascii_downcase != ".git") and
           (endswith(".") | not) and (endswith(" ") | not))))' \
      >/dev/null 2>&1; then
    jq_accepts=1
  else
    jq_accepts=0
  fi
  # shadow/v1/incident-record.jq shape check on the same value.
  local record shape_out shape_accepts
  record=$(record_skeleton "$path_json")
  shape_out=$(printf '%s' "$record" |
    "$jq_bin" -r --arg operation shape --arg record_sha "$zero_sha" -f "$incident_program" 2>/dev/null || true)
  if [ -z "$shape_out" ]; then shape_accepts=1; else shape_accepts=0; fi
  # the verifier, through the test build, over a real candidate root that
  # never contains the path (so acceptance means "reached file.* processing").
  mkinstr "$tmp/diff-instr.bin" "{\"path_hex\":\"$path_hex\",\"sha\":\"$zero_sha\"}"
  fresh_evidence
  require_ok_run "$desc" "$tmp/diff-instr.bin" "$tmp/diff.out" "$tmp/diff.err"
  local reason verifier_accepts
  reason=$(reason_of "$result_path")
  case "$reason" in
    instruction.*) verifier_accepts=0 ;;
    *) verifier_accepts=1 ;;
  esac
  [ "$jq_accepts" = "$shape_accepts" ] || fail "$desc: jq predicate and incident-record shape check disagree"
  [ "$jq_accepts" = "$verifier_accepts" ] || fail "$desc: verifier disagrees with jq's repo_path_ok ($desc)"
}
# Accepted.
differential_case '4,096-byte path' "$(hex_of "$big_path")"
differential_case 'leading U+0020' "$(hex_of " a")"
differential_case 'internal space' "$(hex_of "a b")"
differential_case 'x.git (not .git)' "$(hex_of "x.git")"
differential_case '.gitignore (not .git)' "$(hex_of ".gitignore")"
differential_case 'U+00A0 (accepted non-control)' "$(hex_of "$(printf '\xc2\xa0')")"
differential_case 'U+00AD (accepted non-control)' "$(hex_of "$(printf '\xc2\xad')")"
differential_case 'U+200B (accepted non-control)' "$(hex_of "$(printf '\xe2\x80\x8b')")"
differential_case 'U+2028 (accepted non-control)' "$(hex_of "$(printf '\xe2\x80\xa8')")"
differential_case 'U+FEFF inside the path (accepted non-control)' "$(hex_of "$(printf 'a\xef\xbb\xbfb')")"
differential_case 'U+E000 (accepted non-control)' "$(hex_of "$(printf '\xee\x80\x80')")"
differential_case 'U+FFFF (accepted non-control)' "$(hex_of "$(printf '\xef\xbf\xbf')")"
differential_case 'U+1F600 (accepted, 4-byte)' "$(hex_of "$(printf '\xf0\x9f\x98\x80')")"
differential_case 'U+10FFFF (accepted, 4-byte, max code point)' "$(hex_of "$(printf '\xf4\x8f\xbf\xbf')")"
differential_case '64 components' "$(hex_of "$(printf 'a/%.0s' $(seq 1 63))z")"
differential_case '.GİT (dotted capital I, not .git)' "$(hex_of "$(printf '.G\xc4\xb0T')")"
differential_case '4,096-byte multibyte path (accepted)' \
  "$(hex_of_spec '{"unit":"é","count":2048}')"
# Rejected.
differential_case '.GIT (rejected)' "$(hex_of ".GIT")"
differential_case '.Git (rejected)' "$(hex_of ".Git")"
differential_case '65 components (rejected)' "$(hex_of "$(printf 'a/%.0s' $(seq 1 64))z")"
differential_case '4,097-byte path (rejected, oversize)' "$(hex_of "$(/usr/bin/printf 'a%.0s' $(seq 1 4097))")"
differential_case 'U+0001 (rejected control)' "$(hex_of "$(printf '\x01')")"
differential_case 'U+001F (rejected control)' "$(hex_of "$(printf '\x1f')")"
differential_case 'U+007F (rejected control)' "$(hex_of "$(printf '\x7f')")"
differential_case 'U+0080 (rejected control)' "$(hex_of "$(printf '\xc2\x80')")"
differential_case 'U+0085 (rejected control)' "$(hex_of "$(printf '\xc2\x85')")"
differential_case 'U+009F (rejected control)' "$(hex_of "$(printf '\xc2\x9f')")"
differential_case 'tab (rejected control)' "$(hex_of "$(printf '\t')")"
differential_case 'trailing dot component (rejected)' "$(hex_of "a.")"
differential_case 'trailing space component (rejected)' "$(hex_of "a ")"
differential_case 'LF (rejected control)' "$(hex_of_spec '{"literal":"\n"}')"
differential_case 'CR (rejected control)' "$(hex_of_spec '{"literal":"\r"}')"
differential_case 'NUL (rejected control)' "$(hex_of_spec '{"literal":"\u0000"}')"
differential_case 'leading slash / absolute path (rejected)' "$(hex_of "/a")"
differential_case 'backslash (rejected)' "$(hex_of 'a\b')"
differential_case 'empty component via // (rejected)' "$(hex_of "a//b")"
differential_case '. component (rejected)' "$(hex_of "a/./b")"
differential_case '.. component (rejected)' "$(hex_of "a/../b")"
differential_case '4,097-byte multibyte path (rejected, oversize)' \
  "$(hex_of_spec '{"unit":"é","count":2048,"suffix":"a"}')"
pass 'the R4 differential corpus agrees between the verifier, jq repo_path_ok and the incident shape check'
# R5, R6. Reading the candidate file and writing the payload.
write_case() {
  # write_case <relative-path-under-candidate> <content-file>
  local rel=$1 src=$2
  /bin/mkdir -p "$(dirname "$candidate/$rel")"
  /bin/cp "$src" "$candidate/$rel"
}

digest_check_case() {
  # digest_check_case <desc> <rel-path> <expected-file> <outcome: match|mismatch>
  local desc=$1 rel=$2 content=$3 want=$4
  local real_sha check_sha expected_reason size
  real_sha=$(sha_file "$content")
  size=$(wc -c < "$content" | tr -d ' ')
  if [ "$want" = match ]; then check_sha=$real_sha; expected_reason=file.match
  else check_sha=$(printf '%s' "$real_sha" | tr '0123456789abcdef' '1234567890bcdefa'); expected_reason=file.mismatch
  fi
  mkinstr "$tmp/case-instr.bin" "{\"path_hex\":\"$(hex_of "$rel")\",\"sha\":\"$check_sha\"}"
  fresh_evidence
  require_ok_run "$desc" "$tmp/case-instr.bin" "$tmp/case.out" "$tmp/case.err"
  local instr_sha expected_payload
  instr_sha=$(sha_file "$tmp/case-instr.bin")
  expected_payload=$("$jq_bin" -S -c -n \
    --arg expected_sha256 "$check_sha" --arg path "$rel" --arg instruction_sha256 "$instr_sha" \
    --arg sha256 "$real_sha" --argjson size_bytes "$size" \
    --arg outcome "$want" --arg reason_id "$expected_reason" '
    {body:{check:{expected_sha256:$expected_sha256,path:$path},instruction_sha256:$instruction_sha256,
           observed:{sha256:$sha256,size_bytes:$size_bytes},outcome:$outcome,reason_id:$reason_id},
     id:"file-digest-payload",kind:"file_digest_verifier_payload",schema_version:1}')
  [ "$expected_payload" = "$(cat "$result_path")" ] ||
    fail "$desc: payload does not equal the complete expected object (outcome/reason_id/check/instruction_sha256/observed)"
  local canon
  canon=$("$jq_bin" -S -c . "$result_path")
  [ "$canon" = "$(cat "$result_path")" ] || fail "$desc: payload is not canonical jq -S -c"
  local repeat="$tmp/repeat-result.json"
  /bin/rm -f -- "$repeat"
  /bin/cp "$result_path" "$repeat"
  fresh_evidence
  require_ok_run "$desc (repeat run)" "$tmp/case-instr.bin" "$tmp/case2.out" "$tmp/case2.err"
  cmp -s "$repeat" "$result_path" || fail "$desc: repeat run is not byte-identical"
  [ "$("$python" -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$result_path")" = 0o400 ] ||
    fail "$desc: result mode is not 0400"
}

/bin/mkdir -p "$candidate"

: > "$tmp/f-empty"
write_case empty.bin "$tmp/f-empty"; digest_check_case 'empty file: match' empty.bin "$tmp/f-empty" match
digest_check_case 'empty file: mismatch' empty.bin "$tmp/f-empty" mismatch

"$python" -c 'import sys; sys.stdout.buffer.write(bytes(range(256)))' > "$tmp/f-binary"
write_case binary.bin "$tmp/f-binary"; digest_check_case 'all-256-byte-values file: match' binary.bin "$tmp/f-binary" match

/usr/bin/printf 'alpha\r\nbeta\r\n' > "$tmp/f-crlf"
write_case crlf.bin "$tmp/f-crlf"; digest_check_case 'CRLF file: match' crlf.bin "$tmp/f-crlf" mismatch

/usr/bin/printf 'no newline at end' > "$tmp/f-nonl"
write_case nonl.bin "$tmp/f-nonl"; digest_check_case 'no-final-newline file: match' nonl.bin "$tmp/f-nonl" match

/usr/bin/printf 'trailing newline\n' > "$tmp/f-trailnl"
write_case trailnl.bin "$tmp/f-trailnl"; digest_check_case 'trailing-newline file: match' trailnl.bin "$tmp/f-trailnl" match
pass 'match and mismatch for empty, binary, CRLF, no-final-newline and trailing-newline files, digests checked against shasum -a 256'
# FIPS 180-4 vectors.
: > "$tmp/fips-empty"
/usr/bin/printf 'abc' > "$tmp/fips-abc"
/usr/bin/printf 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq' > "$tmp/fips-448"
"$python" -c "import sys; sys.stdout.write('a' * 1000000)" > "$tmp/fips-million"
[ "$(sha_file "$tmp/fips-empty")" = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ] || fail 'FIPS empty-string vector'
[ "$(sha_file "$tmp/fips-abc")" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ] || fail 'FIPS abc vector'
[ "$(sha_file "$tmp/fips-448")" = 248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1 ] || fail 'FIPS 448-bit vector'
[ "$(sha_file "$tmp/fips-million")" = cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0 ] || fail 'FIPS one-million-a vector'
write_case fips-abc.bin "$tmp/fips-abc"; digest_check_case 'FIPS abc vector against the verifier' fips-abc.bin "$tmp/fips-abc" match
# Run the two-block-boundary and multi-block vectors through the verifier
# too, not just system shasum.
write_case fips-448.bin "$tmp/fips-448"; digest_check_case 'FIPS 448-bit vector against the verifier' fips-448.bin "$tmp/fips-448" match
write_case fips-million.bin "$tmp/fips-million"; digest_check_case 'FIPS one-million-a vector against the verifier' fips-million.bin "$tmp/fips-million" match
pass 'the FIPS 180-4 vectors (empty, abc, 448-bit, one million a) match published digests and the verifier agrees on all four'
# sizes at and past the 1,048,576-byte limit.
"$python" -c "import sys; sys.stdout.buffer.write(b'a' * 1048576)" > "$tmp/f-atlimit"
write_case atlimit.bin "$tmp/f-atlimit"; digest_check_case '1,048,576 bytes (accepted)' atlimit.bin "$tmp/f-atlimit" match
"$python" -c "import sys; sys.stdout.buffer.write(b'a' * 1048577)" > "$tmp/f-overlimit"
write_case overlimit.bin "$tmp/f-overlimit"; mkinstr "$tmp/case-instr.bin" "{\"path_hex\":\"$(hex_of overlimit.bin)\",\"sha\":\"$zero_sha\"}"
fresh_evidence; require_ok_run '1,048,577-byte candidate' "$tmp/case-instr.bin" "$tmp/case.out" "$tmp/case.err"
[ "$(reason_of "$result_path")" = file.oversize ] || fail '1,048,577 bytes must give file.oversize'
pass 'sizes 1,048,576 (accepted) and 1,048,577 (file.oversize) are handled as paired controls'
# missing (final and intermediate), directory, FIFO, socket, symlinks,
# intermediate regular file, mode 0000.
check_file_reason() {
  local desc=$1 rel=$2 expected=$3
  mkinstr "$tmp/case-instr.bin" "{\"path_hex\":\"$(hex_of "$rel")\",\"sha\":\"$zero_sha\"}"
  fresh_evidence
  require_ok_run "$desc" "$tmp/case-instr.bin" "$tmp/case.out" "$tmp/case.err"
  local reason
  reason=$(reason_of "$result_path")
  [ "$reason" = "$expected" ] || fail "$desc: expected $expected, got $reason"
}

check_file_reason 'final component missing' does-not-exist.bin file.missing
/bin/mkdir -p "$candidate/nodir"; check_file_reason 'intermediate component missing' missingdir/child.bin file.missing
/bin/mkdir -p "$candidate/adir"; check_file_reason 'final component is a directory' adir file.not-regular
/usr/bin/mkfifo "$candidate/afifo"; check_file_reason 'final component is a FIFO' afifo file.not-regular
"$python" - "$candidate/asocket" <<'PY'
import socket, sys, os
path = sys.argv[1]
try:
    os.remove(path)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
cwd = os.getcwd()
os.chdir(os.path.dirname(path))
try:
    s.bind(os.path.basename(path))
finally:
    os.chdir(cwd)
PY
check_file_reason 'final component is a Unix socket' asocket file.not-regular
/bin/mkdir -p "$candidate/regparent"; : > "$candidate/regparent/notadir"
check_file_reason 'intermediate component is a regular file' regparent/notadir/child.bin file.not-regular
: > "$candidate/target.bin"; ln -s target.bin "$candidate/finalsymlink"
check_file_reason 'final component is a symlink' finalsymlink file.symlink
ln -s /dev/null "$candidate/nullsymlink"; check_file_reason 'final component is a symlink to /dev/null' nullsymlink file.symlink
/bin/mkdir -p "$candidate/symdir"; ln -s symdir "$candidate/symdirlink"
check_file_reason 'intermediate component is a symlink' symdirlink/child.bin file.symlink
: > "$candidate/noperm.bin"; /bin/chmod 0000 "$candidate/noperm.bin"
check_file_reason 'mode 0000 file' noperm.bin file.read-error
/bin/chmod 0644 "$candidate/noperm.bin"
pass 'file.missing, file.not-regular, file.symlink and file.read-error are each produced by their paired case'
# output collision, and an unwritable evidence directory.
: > "$candidate/collide.bin"
mkinstr "$tmp/case-instr.bin" "{\"path_hex\":\"$(hex_of collide.bin)\",\"sha\":\"$zero_sha\"}"
fresh_evidence; require_ok_run 'output collision: first run' "$tmp/case-instr.bin" "$tmp/first.out" "$tmp/first.err"
[ -e "$result_path" ] || fail 'first run must write a result'
first_bytes=$(sha_file "$result_path")
status=0
run_test_verifier "$tmp/case-instr.bin" "$tmp/second.out" "$tmp/second.err" || status=$?
[ "$status" -eq 73 ] || fail "output collision: expected exit 73, got $status"
[ ! -s "$tmp/second.out" ] || fail 'output collision: stdout must be empty'
[ "$(cat "$tmp/second.err")" = E_OUTPUT_COLLISION ] || fail 'output collision: expected E_OUTPUT_COLLISION'
[ "$(sha_file "$result_path")" = "$first_bytes" ] || fail 'output collision: existing result must be unchanged'
pass 'an existing result gives exit 73 E_OUTPUT_COLLISION and is left byte-identical'

fresh_evidence
/bin/chmod 0500 "$evidence"
status=0
run_test_verifier "$tmp/case-instr.bin" "$tmp/noperm.out" "$tmp/noperm.err" || status=$?
/bin/chmod 0700 "$evidence"
[ "$status" -eq 73 ] || fail "unwritable evidence directory: expected exit 73, got $status"
[ ! -s "$tmp/noperm.out" ] || fail 'unwritable evidence directory: stdout must be empty'
[ "$(cat "$tmp/noperm.err")" = E_OUTPUT ] || fail 'unwritable evidence directory: expected E_OUTPUT'
pass 'a mode 0500 evidence directory gives exit 73 E_OUTPUT'
# ===========================================================================
# Preservation (R7.2, R8.2): every run_test_verifier call above and below
# already snapshots the candidate tree (lstat type/mode/size/link target,
# content sha256, permission-denied files compared by metadata only) before
# and after its own invocation and fails immediately on any change, so
# preservation is asserted per case, not just once at the end.
# ===========================================================================
pass 'the candidate tree is unchanged (bytes, modes and structure) after every verifier run, checked on every case by run_test_verifier'
# Planted manifest.json / expected-digest / instruction-like file: no effect.
plant_case_reason() {
  mkinstr "$tmp/case-instr.bin" "{\"path_hex\":\"$(hex_of collide.bin)\",\"sha\":\"$zero_sha\"}"
  fresh_evidence
  require_ok_run 'planted-file case' "$tmp/case-instr.bin" "$tmp/plant.out" "$tmp/plant.err"
  cat "$result_path"
}
baseline=$(plant_case_reason)
real_sha=$(sha_file "$candidate/collide.bin")
printf '{"paths":{"collide.bin":"%s"}}' "$real_sha" > "$candidate/manifest.json"
printf '%s' "$real_sha" > "$candidate/collide.bin.expected-sha256"
printf 'ystack.file-digest-instruction.v1\npath collide.bin\nsha256 %s\n' "$real_sha" > "$candidate/planted-instruction.txt"
planted=$(plant_case_reason)
/bin/rm -f "$candidate/manifest.json" "$candidate/collide.bin.expected-sha256" "$candidate/planted-instruction.txt"
[ "$baseline" = "$planted" ] || fail 'a planted manifest.json / expected-digest / instruction-like file changed the payload'
pass 'a planted manifest.json, expected-digest file or instruction-like file changes nothing (R7.2)'

/usr/bin/printf '%s\n' \
  '# Honestly unproven here (R8.4): the real /sandbox mount, read-only and' \
  '# write-only mounts, the fixed limits, containment, guest-toolchain' \
  '# identity, a device node at the final component, and file.size-mismatch' \
  '# / file.changed (no deterministic trigger without a timing race). These' \
  '# belong to concern 4 and are not faked by any case above.' \
  > /dev/null
pass 'closing: R8.4 unproven items are named and none is faked by a test case'

/usr/bin/printf 'total assertions: %s\n' "$passes" >&2
