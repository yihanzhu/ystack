#!/usr/bin/env bash
# Proves the YSFRAME1 frame codec, the R5.2/R8.1 record-name sets, the
# sandbox_guest_plan parser, R5.5 materialization, R6.4 exec wiring and the
# R8.1 export inventory (ystack #463, PRs 1-2). Builds
# scripts/test/sandbox-guest-harness.c with sandbox/v1/guest/common.c using
# the host compiler. See work/vm-launcher-supervisor/plan.md ("PR 1",
# "PR 2") and spec.md R3.2/R5.2/R5.5/R6.4/R8.1. Not run against a real
# guest: this proves the codec and wiring only.
set -euo pipefail
export LC_ALL=C
umask 077
root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
guest_dir="$root/sandbox/v1/guest"
harness_src="$root/scripts/test/sandbox-guest-harness.c"
python=/usr/bin/python3
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-sandbox-guest-test.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() { /bin/chmod -R u+rwX "$tmp" 2>/dev/null || :; /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha_file() { /usr/bin/shasum -a 256 -- "$1" | /usr/bin/awk '{print $1}'; }
cc_build() {
  /usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 -I"$guest_dir" \
    "$harness_src" "$guest_dir/common.c" -o "$1"
}
/bin/mkdir -m 700 "$tmp/build1" "$tmp/build2"
h1="$tmp/build1/harness"; h2="$tmp/build2/harness"
cc_build "$h1"; cc_build "$h2"
cmp -s "$h1" "$h2" || fail 'two host-compiler builds are not byte-identical'
pass 'two host-compiler builds of the harness (guest common code) are byte-identical'
# A second, test-only build with the readdir fault-injection hook compiled
# in (YSTACK_TEST_FAULT_INJECT): never part of the byte-identity check
# above, used only for the readdir-failure case near the inventory tests.
hf="$tmp/build-fault/harness"
/bin/mkdir -m 700 "$tmp/build-fault"
/usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 -DYSTACK_TEST_FAULT_INJECT -I"$guest_dir" \
  "$harness_src" "$guest_dir/common.c" -o "$hf"
h="$h1"
# FIPS 180-4 vectors, through the code (ys_sha256_bytes via `digest`).
: > "$tmp/fips-empty"
/usr/bin/printf 'abc' > "$tmp/fips-abc"
/usr/bin/printf 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq' > "$tmp/fips-448"
"$python" -c "import sys; sys.stdout.write('a' * 1000000)" > "$tmp/fips-million"
check_digest() { [ "$("$h" digest "$1")" = "$2" ] || fail "FIPS vector mismatch: $1"; }
check_digest "$tmp/fips-empty" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
check_digest "$tmp/fips-abc" ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
check_digest "$tmp/fips-448" 248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1
check_digest "$tmp/fips-million" cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0
[ "$("$h" digest "$tmp/fips-abc")" = "$(sha_file "$tmp/fips-abc")" ] || fail 'digest disagrees with shasum -a 256'
pass 'the FIPS 180-4 vectors (empty, abc, 448-bit, one-million-a) match published digests through the code'

# --- helpers ---------------------------------------------------------------
mkframe() { local out=$1; shift; "$h" frame-write "$out" "$@"; }
try_read() { # try_read <frame> [set] [--capacity=N]; writes stderr to $tmp/err
  local frame=$1 dir="$tmp/extract" status=0; shift
  /bin/rm -rf -- "$dir"
  "$h" frame-read "$frame" "$dir" "$@" 2>"$tmp/err" || status=$?
  return "$status"
}
expect_ok() { # expect_ok <desc> <frame> [set]
  local desc=$1 status=0; shift
  try_read "$@" || status=$?
  [ "$status" -eq 0 ] || fail "$desc: expected acceptance, got exit $status ($(cat "$tmp/err"))"
}
expect_err() { # expect_err <desc> <expected-code> <frame> [set]
  local desc=$1 expected=$2 status=0; shift 2
  try_read "$@" || status=$?
  [ "$status" -ne 0 ] || fail "$desc: expected refusal, got exit 0"
  [ "$(cat "$tmp/err")" = "$expected" ] || fail "$desc: expected $expected, got $(cat "$tmp/err")"
}

# --- generic frame codec: truncation, tail, digest, magic (no name set) ----
/usr/bin/printf aaa > "$tmp/r0"; /usr/bin/printf bb > "$tmp/r1"
mkframe "$tmp/f3.bin" x="$tmp/r0" yy="$tmp/r1"
full_size=$(wc -c < "$tmp/f3.bin" | tr -d ' ')
expect_ok 'an untruncated three-record frame' "$tmp/f3.bin"
pass 'an untruncated three-record frame (magic, two records, end) is accepted'
off=0
while [ "$off" -lt "$full_size" ]; do
  /bin/dd if="$tmp/f3.bin" of="$tmp/trunc.bin" bs=1 count="$off" 2>/dev/null
  expect_err "truncation at offset $off of $full_size" E_FRAME_TRUNCATED "$tmp/trunc.bin"
  off=$((off + 1))
done
pass 'every truncation offset (0 through one byte short) of the three-record frame is refused E_FRAME_TRUNCATED, paired against the accepted control above'
"$python" - "$tmp/f3.bin" "$tmp/tail-zero.bin" "$tmp/tail-nonzero.bin" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
open(sys.argv[2], 'wb').write(data + b'\x00' * 16)
open(sys.argv[3], 'wb').write(data + b'\x00' * 15 + b'\x01')
PY
expect_ok 'a zero-only tail past end' "$tmp/tail-zero.bin"
pass 'a zero-only tail past the end record is accepted'
expect_err 'a non-zero tail byte past end' E_FRAME_TAIL "$tmp/tail-nonzero.bin"
pass 'a non-zero tail byte past the end record is refused E_FRAME_TAIL, paired against the zero-tail control'
"$python" -c "
data = bytearray(open('$tmp/f3.bin', 'rb').read())
data[-1] ^= 0xFF
open('$tmp/flip.bin', 'wb').write(data)
"
expect_err 'a flipped end-digest byte' E_FRAME_DIGEST "$tmp/flip.bin"
pass 'a flipped end-digest byte is refused E_FRAME_DIGEST, paired against the accepted three-record frame'
"$python" -c "
data = bytearray(open('$tmp/f3.bin', 'rb').read())
data[0] ^= 0xFF
open('$tmp/badmagic.bin', 'wb').write(data)
"
expect_err 'a corrupted magic byte' E_FRAME_MAGIC "$tmp/badmagic.bin"
pass 'a corrupted magic byte is refused E_FRAME_MAGIC, paired against the accepted three-record frame'
"$python" - "$tmp/len-past.bin" <<'PY'
import struct, sys
def rec(name, data):
    return bytes([len(name)]) + name.encode() + struct.pack('>Q', len(data)) + data
name = b'instruction'
forged = bytes([len(name)]) + name + struct.pack('>Q', 999999) + b'i'
open(sys.argv[1], 'wb').write(b'YSFRAME1' + rec('plan.json', b'p') + forged)
PY
expect_err 'a record length claiming bytes past the device' E_FRAME_TRUNCATED "$tmp/len-past.bin"
pass 'a record whose declared length runs past the device is refused E_FRAME_TRUNCATED'

# --- R5.2 input record-name set: fixed order, contiguous candidate index --
/usr/bin/printf p > "$tmp/plan.json"; /usr/bin/printf i > "$tmp/instruction"
/usr/bin/printf v > "$tmp/verifier"; /usr/bin/printf c0 > "$tmp/c0"; /usr/bin/printf c1 > "$tmp/c1"
mkframe "$tmp/in-good.bin" plan.json="$tmp/plan.json" instruction="$tmp/instruction" \
  verifier="$tmp/verifier" candidate/00000="$tmp/c0" candidate/00001="$tmp/c1"
expect_ok 'a well-formed input-set frame' "$tmp/in-good.bin" input
pass 'a well-formed input-set frame (fixed names in order, contiguous candidate indices) is accepted'
dir="$tmp/roundtrip"
"$h" frame-read "$tmp/in-good.bin" "$dir" input
roundtrip_ok=1
cmp -s "$dir/plan.json" "$tmp/plan.json" || roundtrip_ok=0
cmp -s "$dir/instruction" "$tmp/instruction" || roundtrip_ok=0
cmp -s "$dir/verifier" "$tmp/verifier" || roundtrip_ok=0
cmp -s "$dir/candidate/00000" "$tmp/c0" || roundtrip_ok=0
cmp -s "$dir/candidate/00001" "$tmp/c1" || roundtrip_ok=0
[ "$roundtrip_ok" -eq 1 ] || fail 'round trip: an extracted record differs from its source bytes'
pass 'byte-identical round trip: frame-write then frame-read reproduces every record exactly'
mkframe "$tmp/in-emptyname.bin" ="$tmp/plan.json" instruction="$tmp/instruction" verifier="$tmp/verifier"
expect_err 'an empty record name in place of plan.json' E_FRAME_NAME "$tmp/in-emptyname.bin" input
mkframe "$tmp/in-badname.bin" bogus.json="$tmp/plan.json" instruction="$tmp/instruction" verifier="$tmp/verifier"
expect_err 'an out-of-set record name in place of plan.json' E_FRAME_NAME "$tmp/in-badname.bin" input
pass 'an empty or out-of-set record name is refused E_FRAME_NAME, paired against the accepted well-formed frame'
mkframe "$tmp/in-gap.bin" plan.json="$tmp/plan.json" instruction="$tmp/instruction" verifier="$tmp/verifier" \
  candidate/00000="$tmp/c0" candidate/00002="$tmp/c1"
expect_err 'a candidate index gap (0 then 2)' E_FRAME_INDEX "$tmp/in-gap.bin" input
mkframe "$tmp/in-disorder.bin" plan.json="$tmp/plan.json" instruction="$tmp/instruction" verifier="$tmp/verifier" \
  candidate/00001="$tmp/c1" candidate/00000="$tmp/c0"
expect_err 'a candidate index disorder (1 then 0)' E_FRAME_INDEX "$tmp/in-disorder.bin" input
pass 'a candidate index gap or disorder is refused E_FRAME_INDEX, paired against the accepted contiguous frame'

# --- R8.1 export record-name set (report.json, stdout, stderr, evidence/*) -
/usr/bin/printf r > "$tmp/report.json"; /usr/bin/printf o > "$tmp/stdout"
/usr/bin/printf e > "$tmp/stderr"; /usr/bin/printf ev0 > "$tmp/ev0"
mkframe "$tmp/ex-good.bin" report.json="$tmp/report.json" stdout="$tmp/stdout" \
  stderr="$tmp/stderr" evidence/0000="$tmp/ev0"
expect_ok 'a well-formed export-set frame' "$tmp/ex-good.bin" export
pass 'a well-formed export-set frame (report.json, stdout, stderr, evidence/0000) is accepted'
mkframe "$tmp/ex-bad.bin" report.json="$tmp/report.json" stdout="$tmp/stdout" stderr="$tmp/stderr" \
  "evidence/00000"="$tmp/ev0"
expect_err 'a five-digit evidence index (wrong width for R8.1)' E_FRAME_NAME "$tmp/ex-bad.bin" export
pass 'an evidence name of the wrong digit width is refused E_FRAME_NAME, paired against the accepted export frame'

# --- explicit descriptor capacity (not a regular file's raw st_size) -------
expect_ok 'an explicit --capacity equal to the real size' "$tmp/f3.bin" "--capacity=$full_size"
pass 'an explicit capacity equal to the actual size is accepted (the auto-detected regular-file path above already covers the default)'
expect_err 'an explicit --capacity understating the real size' E_FRAME_TRUNCATED "$tmp/f3.bin" "--capacity=$((full_size - 5))"
pass 'an explicit capacity smaller than the actual bytes is refused E_FRAME_TRUNCATED: the reader trusts the given capacity, not fstat st_size'
expect_err 'an explicit --capacity overstating the real size' E_FRAME_IO "$tmp/f3.bin" "--capacity=$((full_size + 1000))"
pass 'an explicit capacity larger than the actual bytes is refused E_FRAME_IO (a real short read past EOF), never a crash or an out-of-bounds read'

# --- preparation path range: component length bound (<=255 bytes) ---------
"$python" -c "import sys; sys.stdout.buffer.write(b'a' * 255)" > "$tmp/comp255"
"$python" -c "import sys; sys.stdout.buffer.write(b'a' * 256)" > "$tmp/comp256"
"$python" -c "import sys; sys.stdout.buffer.write(('é' * 127 + 'a').encode())" > "$tmp/comp255mb"
"$python" -c "import sys; sys.stdout.buffer.write(('é' * 127 + 'aa').encode())" > "$tmp/comp256mb"
"$h" path-ok "$tmp/comp255" || fail 'a 255-byte path component must be accepted'
if "$h" path-ok "$tmp/comp256" 2>"$tmp/err"; then fail 'a 256-byte path component must be refused'; fi
[ "$(cat "$tmp/err")" = E_PATH_REJECTED ] || fail 'expected E_PATH_REJECTED for a 256-byte component'
pass 'a path component of exactly 255 bytes is accepted and 256 bytes is refused E_PATH_REJECTED (the boundary itself)'
"$h" path-ok "$tmp/comp255mb" || fail 'a 255-byte multibyte path component must be accepted'
if "$h" path-ok "$tmp/comp256mb" 2>"$tmp/err"; then fail 'a 256-byte multibyte path component must be refused'; fi
[ "$(cat "$tmp/err")" = E_PATH_REJECTED ] || fail 'expected E_PATH_REJECTED for a 256-byte multibyte component'
pass 'the same 255/256-byte boundary holds for a component built from multibyte UTF-8 (127 U+00E9 plus ASCII), not just single-byte characters'

# =============================================================================
# PR 2: sandbox_guest_plan parser (R5.2), R5.5 materialization, R6.4 exec
# wiring, R8.1 export inventory.
# =============================================================================
stat_mode() { "$python" -c "import os,sys;print('0'+oct(os.stat(sys.argv[1]).st_mode&0o777)[2:])" "$1"; }
stat_owner() { "$python" -c "import os,sys;print(os.stat(sys.argv[1]).st_uid)" "$1"; }

# --- plan parsing ------------------------------------------------------
cat > "$tmp/genplan.py" <<'PY'
import sys, json
out, mode, entries_file = sys.argv[1], sys.argv[2], sys.argv[3]
entries = json.load(open(entries_file, encoding="utf-8"))
argv = ["/sandbox/tools/verifier", "verify", "--candidate", "/sandbox/candidate",
        "--evidence", "/sandbox/evidence"]
env = ["LANG=C", "LC_ALL=C", "PATH=/sandbox/tools", "TMPDIR=/sandbox/scratch"]
limits = {"bandwidth_slice_us": 1, "cpu_max": 2, "cpu_max_burst": 3, "output_inodes": 4,
          "output_tmpfs_bytes": 5, "pids_max": 6, "scratch_bytes": 7, "scratch_inodes": 8,
          "tree_deadline_ms": 9}
h = "0" * 64
body = {"argv": argv, "entries": entries, "environment": env, "instruction_sha256": h,
        "limits": limits, "verifier_sha256": h}
if mode == "missingkey":
    del body["limits"]
doc = {"body": body, "kind": "sandbox_guest_plan", "schema_version": 1}
text = json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n"
if mode == "unknownkey":
    text = text.replace('"argv"', '"bogus":1,"argv"', 1)
if mode == "dupkey":
    text = text[:-2] + ',"schema_version":1}\n'
if mode == "misorder":
    text = text.replace('"kind":"sandbox_guest_plan","schema_version":1',
                         '"schema_version":1,"kind":"sandbox_guest_plan"')
open(out, "w", encoding="utf-8").write(text)
PY
genplan() { /usr/bin/printf '%s' "$3" > "$tmp/entries.json"; "$python" "$tmp/genplan.py" "$1" "$2" "$tmp/entries.json"; }
expect_plan_ok() { # expect_plan_ok <desc> <file> <expected-entry-count>
  local desc=$1 file=$2 want=$3 got status=0
  got=$("$h" plan "$file" 2>"$tmp/err") || status=$?
  [ "$status" -eq 0 ] || fail "$desc: expected acceptance, got exit $status ($(cat "$tmp/err"))"
  [ "$got" = "$want" ] || fail "$desc: expected entry_count $want, got $got"
}
expect_plan_err() { # expect_plan_err <desc> <file>
  local desc=$1 file=$2 status=0
  "$h" plan "$file" >/dev/null 2>"$tmp/err" || status=$?
  [ "$status" -ne 0 ] || fail "$desc: expected refusal, got exit 0"
  [ "$(cat "$tmp/err")" = E_PLAN_SCHEMA ] || fail "$desc: expected E_PLAN_SCHEMA, got $(cat "$tmp/err")"
}

genplan "$tmp/plan-ok.json" ok '[]'
expect_plan_ok 'a well-formed empty-entries plan' "$tmp/plan-ok.json" 0
pass 'a well-formed sandbox_guest_plan (fixed argv/environment, empty entries, both hashes, all nine limits, canonical trailing LF) is accepted'
for mode in unknownkey dupkey missingkey misorder; do
  genplan "$tmp/plan-$mode.json" "$mode" '[]'
  expect_plan_err "a $mode plan" "$tmp/plan-$mode.json"
done
pass 'an unknown key, a duplicate key, a missing key and a misordered key are each refused E_PLAN_SCHEMA, paired against the accepted well-formed plan'

genplan "$tmp/plan-badescape.json" ok '[{"kind":"directory","mode":"0500","path":"su\u0008b","sha256":null,"size_bytes":null}]'
expect_plan_err 'a raw \u0008 escape where \b is required' "$tmp/plan-badescape.json"
zero64=$(/usr/bin/printf '0%.0s' $(seq 1 64))
genplan "$tmp/plan-quote.json" ok "[{\"kind\":\"file\",\"mode\":\"0400\",\"path\":\"a\\\"b.txt\",\"sha256\":\"$zero64\",\"size_bytes\":0}]"
expect_plan_ok 'a path with a legitimately escaped double quote' "$tmp/plan-quote.json" 1
pass 'a disallowed \u00XX escape (json.dumps would use \b) is refused E_PLAN_SCHEMA, and a path with a properly escaped double quote decodes and is accepted, paired controls'

# --- R5.5 materialization: README.md, a non-ASCII UTF-8 name and a
# 4,096-byte 64-component path, each byte for byte; manifest modes and the
# invoking non-root uid as owner (R13.4 probe: reading as that same uid
# must work, writing/creating/removing must not). ------------------------
cat > "$tmp/matsetup.py" <<'PY'
import sys, json, hashlib, os
candroot, planout, filesout = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(os.path.join(candroot, "candidate"), exist_ok=True)
comps = ["a" * 63] * 63 + ["a" * 64]
big_path = "/".join(comps)
assert len(big_path.encode("utf-8")) == 4096
entries = [{"kind": "directory", "mode": "0500", "path": "/".join(comps[:n]),
            "sha256": None, "size_bytes": None} for n in range(1, 64)]
files = [("README.md", b"# hello\n", "0400"),
         ("namé.txt", "café non-ascii\n".encode("utf-8"), "0500"),
         (big_path, b"deep\n", "0400")]
for i, (path, data, mode) in enumerate(files):
    with open(os.path.join(candroot, "candidate", "%05d" % i), "wb") as fh:
        fh.write(data)
    entries.append({"kind": "file", "mode": mode, "path": path,
                     "sha256": hashlib.sha256(data).hexdigest(), "size_bytes": len(data)})
argv = ["/sandbox/tools/verifier", "verify", "--candidate", "/sandbox/candidate",
        "--evidence", "/sandbox/evidence"]
env = ["LANG=C", "LC_ALL=C", "PATH=/sandbox/tools", "TMPDIR=/sandbox/scratch"]
limits = {"bandwidth_slice_us": 1, "cpu_max": 2, "cpu_max_burst": 3, "output_inodes": 4,
          "output_tmpfs_bytes": 5, "pids_max": 6, "scratch_bytes": 7, "scratch_inodes": 8,
          "tree_deadline_ms": 9}
h = "0" * 64
body = {"argv": argv, "entries": entries, "environment": env, "instruction_sha256": h,
        "limits": limits, "verifier_sha256": h}
doc = {"body": body, "kind": "sandbox_guest_plan", "schema_version": 1}
with open(planout, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n")
with open(filesout, "w", encoding="utf-8") as fh:
    for path, data, mode in files:
        fh.write("%s\t%s\t%s\n" % (path, mode, hashlib.sha256(data).hexdigest()))
PY
"$python" "$tmp/matsetup.py" "$tmp/mat" "$tmp/mat/plan.json" "$tmp/mat/files.tsv"
"$h" materialize "$tmp/mat/plan.json" "$tmp/mat" "$tmp/mat/out" "$(id -u)" "$(id -g)"
# A 4,096-byte relative path exceeds PATH_MAX as one string on every POSIX
# host (that is exactly what open_parent_dir's component walk in
# ys_plan_materialize avoids): this test script walks it the same way,
# opening one path component at a time via os.open(..., dir_fd=...), never
# handing the shell or Python a single long path string either.
cat > "$tmp/deepop.py" <<'PY'
import sys, os, hashlib
root, relpath, op = sys.argv[1], sys.argv[2], sys.argv[3]
parts = relpath.split("/")
fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
for p in parts[:-1]:
    nfd = os.open(p, os.O_RDONLY | os.O_DIRECTORY, dir_fd=fd)
    os.close(fd)
    fd = nfd
leaf = parts[-1]
if op == "read":
    lfd = os.open(leaf, os.O_RDONLY, dir_fd=fd)
    st = os.fstat(lfd)
    data = b"".join(iter(lambda: os.read(lfd, 65536), b""))
    os.close(lfd)
    print(hashlib.sha256(data).hexdigest())
    print("0" + oct(st.st_mode & 0o777)[2:])
    print(st.st_uid)
elif op in ("write", "create", "remove"):
    try:
        if op == "write":
            lfd = os.open(leaf, os.O_WRONLY | os.O_APPEND, dir_fd=fd)
            os.write(lfd, b"x")
            os.close(lfd)
        elif op == "create":
            os.close(os.open("new.txt", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=fd))
        else:
            os.unlink(leaf, dir_fd=fd)
        print("ok")
    except OSError:
        print("fail")
elif op == "exists":
    try:
        os.stat(leaf, dir_fd=fd)
        print("1")
    except FileNotFoundError:
        print("0")
os.close(fd)
PY
deepop() { "$python" "$tmp/deepop.py" "$tmp/mat/out" "$1" "$2"; }
big_path=$("$python" -c "print('/'.join(['a'*63]*63+['a'*64]))")

while IFS=$'\t' read -r relpath mode sha; do
  case "$relpath" in
    */*) read -r got_sha got_mode got_uid <<< "$(deepop "$relpath" read | tr '\n' ' ')" ;;
    *) got_sha=$(sha_file "$tmp/mat/out/$relpath")
       got_mode=$(stat_mode "$tmp/mat/out/$relpath")
       got_uid=$(stat_owner "$tmp/mat/out/$relpath") ;;
  esac
  [ "$got_sha" = "$sha" ] || fail "materialize: $relpath content does not match its manifest sha256"
  [ "$got_mode" = "$mode" ] || fail "materialize: $relpath is mode $got_mode, not $mode"
  [ "$got_uid" = "$(id -u)" ] || fail "materialize: $relpath owner is $got_uid, not the invoking uid"
done < "$tmp/mat/files.tsv"
pass 'README.md, a non-ASCII UTF-8 name and a 4,096-byte 64-component path are each materialized byte for byte, with the manifest mode and the invoking uid as owner'

"$python" -c "
import sys
try:
    fd = open(sys.argv[1], 'ab'); fd.write(b'x'); fd.close(); print('ok')
except OSError:
    print('fail')
" "$tmp/mat/out/README.md" > "$tmp/wr.out"
[ "$(cat "$tmp/wr.out")" = fail ] || fail 'writing to a materialized 0400 file must fail'
[ "$(deepop "$big_path" write)" = fail ] || fail 'writing to the deep materialized 0400 file must fail'
[ "$(deepop "$big_path" create)" = fail ] || fail 'creating a file inside the deep materialized 0500 directory must fail'
[ "$(deepop "$big_path" remove)" = fail ] || fail 'removing the deep file from its materialized 0500 directory must fail'
[ "$(deepop "$big_path" exists)" = 1 ] || fail 'the deep file must still exist after the refused remove'
pass 'as the invoking non-root uid, a write to a materialized file, a create inside a materialized directory and a remove from one all fail; reads above already succeeded'

# --- R6.4 exec wiring: argv, the four environment variables, fd 0 regular,
# fds 1-2 append-only, no other descriptor -------------------------------
/usr/bin/printf 'the instruction bytes' > "$tmp/instr.txt"
: > "$tmp/exec.out"; : > "$tmp/exec.err"
"$h" exec-report "$h" "$tmp/instr.txt" "$tmp/exec.out" "$tmp/exec.err"
expected_report=$'argv:ok\nenv:ok\nfd0:ok\nfd1:ok\nfd2:ok\nextra_fds:0'
[ "$(cat "$tmp/exec.out")" = "$expected_report" ] || fail "exec wiring: unexpected report $(cat "$tmp/exec.out")"
[ ! -s "$tmp/exec.err" ] || fail 'exec wiring: stderr must be empty'
pass 'ys_exec delivers exactly the R6.4 argv and the four environment variables, with fd 0 a regular file, fds 1-2 append-only and every other descriptor closed'

# ys_exec must preserve a source whose value overlaps another destination
# (e.g. stdout_fd == 0, the instruction's own target): a naive sequential
# dup2(instruction_fd,0); dup2(stdout_fd,1); ... would clobber stdout_fd's
# source the moment fd 0 is repointed. "overlap" forces exactly that.
: > "$tmp/exec-ov.out"; : > "$tmp/exec-ov.err"
"$h" exec-report "$h" "$tmp/instr.txt" "$tmp/exec-ov.out" "$tmp/exec-ov.err" overlap
[ "$(cat "$tmp/exec-ov.out")" = "$expected_report" ] ||
  fail "exec wiring (overlapping descriptors): unexpected report $(cat "$tmp/exec-ov.out")"
[ ! -s "$tmp/exec-ov.err" ] || fail 'exec wiring (overlapping descriptors): stderr must be empty'
pass 'ys_exec wires the same argv, environment and fds correctly even when a caller-supplied source overlaps another destination (stdout_fd forced to fd 0, the instruction target)'

# --- R8.1 export inventory: hard-link alias refused, single link accepted -
/bin/mkdir -m 700 "$tmp/ev-good" "$tmp/ev-bad"
/usr/bin/printf ev0 > "$tmp/ev-good/b.bin"; /usr/bin/printf ev1 > "$tmp/ev-good/a.bin"
got=$("$h" inventory "$tmp/ev-good")
[ "$got" = $'a.bin\nb.bin' ] || fail 'inventory: expected sorted single-link names a.bin then b.bin'
pass 'the R8.1 export inventory of single-link evidence files lists them sorted by name (single-link positive control)'
/usr/bin/printf ev0 > "$tmp/ev-bad/c.bin"; /bin/ln "$tmp/ev-bad/c.bin" "$tmp/ev-bad/c-alias.bin"
status=0
"$h" inventory "$tmp/ev-bad" >/dev/null 2>"$tmp/err" || status=$?
[ "$status" -ne 0 ] || fail 'inventory: a same-directory hard-link alias must be refused'
[ "$(cat "$tmp/err")" = E_PLAN_SCHEMA ] || fail "inventory: expected E_PLAN_SCHEMA for a hard-link alias, got $(cat "$tmp/err")"
pass 'the R8.1 export inventory refuses a same-directory hard-link alias of an evidence file, paired against the single-link control above'

# A readdir() failure (e.g. ENOMEM) returns NULL exactly like end-of-
# directory; ys_evidence_inventory must tell the two apart via errno, not
# silently report a partial inventory as YS_PLAN_OK. The fault-injection
# build ($hf) makes the Nth readdir() call fail this way.
"$hf" inventory "$tmp/ev-good" > "$tmp/inv-nofail.out"
[ "$(cat "$tmp/inv-nofail.out")" = $'a.bin\nb.bin' ] ||
  fail 'inventory (fault-injection build, no injected failure): unexpected output'
pass 'the fault-injection build behaves exactly like the normal build when no readdir() failure is injected'
status=0
"$hf" inventory "$tmp/ev-good" 2 >/dev/null 2>"$tmp/err" || status=$?
[ "$status" -ne 0 ] || fail 'inventory: an injected readdir() failure must be refused, not reported as a partial success'
[ "$(cat "$tmp/err")" = E_PLAN_IO ] || fail "inventory: expected E_PLAN_IO for a readdir() failure, got $(cat "$tmp/err")"
pass 'a readdir() failure part way through the directory is refused E_PLAN_IO rather than silently returning a partial inventory as YS_PLAN_OK'

/usr/bin/printf 'total assertions: %s\n' "$passes" >&2