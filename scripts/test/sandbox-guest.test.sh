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

# dirfd (harness-created 0700) is itself "every ... directory" per R5.5:
# left untouched, a root-level entry stays deletable/replaceable
# regardless of its own mode (that's the containing directory's mode).
[ "$(stat_mode "$tmp/mat/out")" = 0500 ] || fail 'the candidate root itself must end at mode 0500'
[ "$(stat_owner "$tmp/mat/out")" = "$(id -u)" ] || fail 'the candidate root itself must be owned by the invoking uid'
rootop() { # rootop <remove|create|rename> <arg>...
  "$python" -c "
import sys, os
op, args = sys.argv[1], sys.argv[2:]
try:
    if op == 'remove': os.remove(args[0])
    elif op == 'create': open(args[0], 'wb').close()
    else: os.rename(args[0], args[1])
    print('ok')
except OSError: print('fail')
" "$@"
}
[ "$(rootop remove "$tmp/mat/out/README.md")" = fail ] || fail 'removing a root-level file (README.md) must fail'
[ "$(rootop create "$tmp/mat/out/new-root-file.txt")" = fail ] || fail 'creating a new file at the candidate root must fail'
[ "$(rootop rename "$tmp/mat/out/README.md" "$tmp/mat/out/renamed.md")" = fail ] || fail 'renaming a root-level file must fail'
pass 'the candidate root itself is finalized to mode 0500 and the invoking uid: a root-level remove, create or rename all fail too, not only within a nested materialized directory'

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
# ys_exec's close loop must not be blind to a descriptor above a *lowered*
# soft RLIMIT_NOFILE: sysconf(_SC_OPEN_MAX) alone reflects that soft
# limit, not the hard one. "lowlimit" opens a marker at fd 128, then lowers
# the soft limit to 64 (leaving the hard limit untouched) before ys_exec
# runs; a correct close must still reach fd 128.
: > "$tmp/exec-ll.out"; : > "$tmp/exec-ll.err"
"$h" exec-report "$h" "$tmp/instr.txt" "$tmp/exec-ll.out" "$tmp/exec-ll.err" lowlimit
[ "$(cat "$tmp/exec-ll.out")" = "$expected_report" ] ||
  fail "exec wiring (fd 128, soft RLIMIT_NOFILE lowered to 64): unexpected report $(cat "$tmp/exec-ll.out")"
[ ! -s "$tmp/exec-ll.err" ] || fail 'exec wiring (lowered soft limit): stderr must be empty'
pass 'ys_exec still closes a descriptor (fd 128) above a soft RLIMIT_NOFILE the caller lowered to 64, not just up to sysconf(_SC_OPEN_MAX)'
# ys_exec has no numeric-sweep fallback: if it cannot confirm every
# descriptor was closed (close_range/the /dev/fd walk itself failing), it
# must refuse (_exit(126)) rather than proceed to execve. "closefail"
# (fault-injection build only) forces exactly that failure.
: > "$tmp/exec-cf.out"; : > "$tmp/exec-cf.err"
"$hf" exec-report "$hf" "$tmp/instr.txt" "$tmp/exec-cf.out" "$tmp/exec-cf.err" closefail
[ ! -s "$tmp/exec-cf.out" ] || fail "exec wiring (closefail): the child must never reach the reporter, got $(cat "$tmp/exec-cf.out")"
[ ! -s "$tmp/exec-cf.err" ] || fail 'exec wiring (closefail): stderr must be empty'
pass 'ys_exec refuses (exit 126, execve never reached) rather than proceeding when it cannot confirm every descriptor is closed'

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

# =============================================================================
# guest/host YSFRAME1 codec cross-check (ystack #463, PR 3 of 9): the C
# guest (this harness, via sandbox/v1/guest/common.c) and the Python host
# (sandbox/v1/host-supervisor.py's own frame_write/frame_read, exercised
# through its frame-write/frame-read/digest test-only commands) must agree
# on the wire format byte for byte, in both directions. host-supervisor.py's
# frame-read has no record-name-set restriction (that is host-only, R3.3,
# checked separately by parse_package), so it is compared here against the
# harness's frame-read run with no [input|export] set argument either --
# both then do codec-level extraction only.
# =============================================================================
supervisor_src="$root/sandbox/v1/host-supervisor.py"
/bin/mkdir -m 700 "$tmp/cross"
/usr/bin/printf 'alpha-bytes' > "$tmp/cross/a.json"
/usr/bin/printf 'beta-bytes-here' > "$tmp/cross/b"
/usr/bin/printf '' > "$tmp/cross/empty"
/bin/mkdir -m 700 "$tmp/cross/candidate"
/usr/bin/printf 'cand0' > "$tmp/cross/candidate/00000"
/usr/bin/printf 'cand1' > "$tmp/cross/candidate/00001"

# C encodes, Python decodes.
"$h" frame-write "$tmp/cross/c-encoded.bin" a.json="$tmp/cross/a.json" b="$tmp/cross/b" \
  empty="$tmp/cross/empty" candidate/00000="$tmp/cross/candidate/00000" \
  candidate/00001="$tmp/cross/candidate/00001"
"$python" "$supervisor_src" frame-read "$tmp/cross/c-encoded.bin" "$tmp/cross/py-decoded"
cross_ok=1
cmp -s "$tmp/cross/py-decoded/a.json" "$tmp/cross/a.json" || cross_ok=0
cmp -s "$tmp/cross/py-decoded/b" "$tmp/cross/b" || cross_ok=0
cmp -s "$tmp/cross/py-decoded/empty" "$tmp/cross/empty" || cross_ok=0
cmp -s "$tmp/cross/py-decoded/candidate/00000" "$tmp/cross/candidate/00000" || cross_ok=0
cmp -s "$tmp/cross/py-decoded/candidate/00001" "$tmp/cross/candidate/00001" || cross_ok=0
[ "$cross_ok" -eq 1 ] || fail 'codec cross-check: host-supervisor.py frame-read misdecoded a frame the C guest harness wrote'
pass 'sandbox/v1/host-supervisor.py frame-read decodes, byte for byte, a frame written by the C guest (sandbox/v1/guest/common.c)'

# Python encodes, C decodes (no record-name-set argument: codec only).
"$python" "$supervisor_src" frame-write "$tmp/cross/py-encoded.bin" a.json="$tmp/cross/a.json" \
  b="$tmp/cross/b" empty="$tmp/cross/empty" candidate/00000="$tmp/cross/candidate/00000" \
  candidate/00001="$tmp/cross/candidate/00001"
"$h" frame-read "$tmp/cross/py-encoded.bin" "$tmp/cross/c-decoded"
cross_ok=1
cmp -s "$tmp/cross/c-decoded/a.json" "$tmp/cross/a.json" || cross_ok=0
cmp -s "$tmp/cross/c-decoded/b" "$tmp/cross/b" || cross_ok=0
cmp -s "$tmp/cross/c-decoded/empty" "$tmp/cross/empty" || cross_ok=0
cmp -s "$tmp/cross/c-decoded/candidate/00000" "$tmp/cross/candidate/00000" || cross_ok=0
cmp -s "$tmp/cross/c-decoded/candidate/00001" "$tmp/cross/candidate/00001" || cross_ok=0
[ "$cross_ok" -eq 1 ] || fail 'codec cross-check: the C guest harness frame-read misdecoded a frame host-supervisor.py wrote'
pass 'the C guest harness frame-read decodes, byte for byte, a frame written by sandbox/v1/host-supervisor.py'

# Both encoders must also produce the identical frame for the identical
# record set (not just mutually decodable output).
cmp -s "$tmp/cross/c-encoded.bin" "$tmp/cross/py-encoded.bin" ||
  fail 'codec cross-check: the C guest and Python host encoders produced different bytes for the same record set'
pass 'the C guest and Python host YSFRAME1 encoders produce byte-identical output for the same record set'

# digest agreement, both directions, on a shared file.
py_digest=$("$python" "$supervisor_src" digest "$tmp/cross/c-encoded.bin")
c_digest=$("$h" digest "$tmp/cross/c-encoded.bin")
[ "$py_digest" = "$c_digest" ] && [ "$py_digest" = "$(sha_file "$tmp/cross/c-encoded.bin")" ] ||
  fail 'codec cross-check: host-supervisor.py digest and the C guest harness digest disagree'
pass 'sandbox/v1/host-supervisor.py digest and the C guest harness digest agree on the same bytes'

# =============================================================================
# PR 6 of 9: build-guest.py (image determinism, compile's existing-directory
# refusal) and, Linux-only, the host-compiler syntax/semantics gate over
# guest/init.c and guest/supervisor.c. See work/vm-launcher-supervisor/
# plan.md ("PR 6") and spec.md R2.5. Never runs anything requiring root, a
# VM or a hypervisor: this proves the deterministic build tooling and that
# the guest sources parse and typecheck, nothing about their behavior in a
# real guest (R15.4).
# =============================================================================
build_guest="$root/sandbox/v1/build-guest.py"

# --- image determinism over synthetic inputs, cpio structure asserted -----
/bin/mkdir -m 700 "$tmp/img1" "$tmp/img2"
/usr/bin/printf 'synthetic-init-bytes' > "$tmp/img1/init"
/usr/bin/printf 'synthetic-supervisor-bytes-a-bit-longer' > "$tmp/img1/supervisor"
/bin/cp "$tmp/img1/init" "$tmp/img2/init"
/bin/cp "$tmp/img1/supervisor" "$tmp/img2/supervisor"
"$python" "$build_guest" image "$tmp/img1"
"$python" "$build_guest" image "$tmp/img2"
cmp -s "$tmp/img1/initramfs.cpio" "$tmp/img2/initramfs.cpio" ||
  fail 'build-guest.py image: two builds from byte-identical synthetic inputs are not byte-identical'
pass 'build-guest.py image produces a byte-identical initramfs.cpio for byte-identical synthetic init/supervisor inputs'
"$python" - "$tmp/img1/initramfs.cpio" "$tmp/img1/init" "$tmp/img1/supervisor" <<'PY'
import sys
data, init_bytes, sup_bytes = open(sys.argv[1], 'rb').read(), open(sys.argv[2], 'rb').read(), open(sys.argv[3], 'rb').read()
pos, entries = 0, []
while True:
    assert data[pos:pos + 6] == b'070701', 'bad cpio magic'
    fields = [int(data[pos + 6 + i * 8:pos + 6 + i * 8 + 8], 16) for i in range(13)]
    ino, mode, uid, gid, nlink, mtime, filesize = fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6]
    namesize = fields[11]
    namestart = pos + 110
    name = data[namestart:namestart + namesize - 1].decode('ascii')
    hdrend = namestart + namesize
    hdrend += (4 - hdrend % 4) % 4
    filedata = data[hdrend:hdrend + filesize]
    entries.append((name, ino, uid, gid, mtime, filedata))
    fend = hdrend + filesize
    fend += (4 - fend % 4) % 4
    pos = fend
    if name == 'TRAILER!!!':
        break
names = [e[0] for e in entries]
assert names == ['init', 'supervisor', 'TRAILER!!!'], 'expected exactly init, supervisor, TRAILER!!! in order: got %r' % names
for name, ino, uid, gid, mtime, filedata in entries[:2]:
    assert uid == 0 and gid == 0, '%s: expected uid/gid 0, got %d/%d' % (name, uid, gid)
    assert mtime == 0, '%s: expected mtime 0, got %d' % (name, mtime)
assert entries[0][1] == 1 and entries[1][1] == 2, 'expected fixed inode numbers 1 (init), 2 (supervisor): got %d, %d' % (entries[0][1], entries[1][1])
assert entries[0][5] == init_bytes and entries[1][5] == sup_bytes, 'entry content does not match the source file bytes'
PY
pass 'the initramfs.cpio built above has exactly two newc entries (init, supervisor) plus TRAILER!!!, each uid/gid 0 and mtime 0, with fixed inode numbers 1 and 2 and content matching the source bytes exactly'

# --- compile: refuses an existing output directory -------------------------
/bin/mkdir -m 700 "$tmp/compile-out"
status=0
"$python" "$build_guest" compile "$tmp/nonexistent-toolchain" "$tmp/compile-out" >/dev/null 2>"$tmp/err" || status=$?
[ "$status" -ne 0 ] || fail 'build-guest.py compile must refuse an output directory that already exists'
[ "$(cat "$tmp/err")" = E_BUILD_OUT_EXISTS ] ||
  fail "build-guest.py compile: expected E_BUILD_OUT_EXISTS for an existing output directory, got $(cat "$tmp/err")"
pass 'build-guest.py compile refuses an output directory that already exists (checked before any toolchain invocation: an unresolvable toolchain path here would otherwise fail first and mask this case)'

# --- Linux-only: the host compiler as a syntax/semantics gate over
# guest/init.c and guest/supervisor.c. Darwin has no <linux/...> headers
# (mount(2)'s MS_* flags, seccomp, Landlock, fanotify, clone3), so this case
# is named Linux-only here and proved instead by the manager's Linux CI
# dispatch (scripts/test/run-all.sh:66-69, the six-shard run plan.md's
# Proof section requires); it is not silently skipped, it is stated. -------
if [ "$(/usr/bin/uname -s)" = Linux ]; then
  /bin/mkdir -m 700 "$tmp/linuxcc"
  /usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 -I"$guest_dir" -c "$guest_dir/init.c" \
    -o "$tmp/linuxcc/init.o"
  /usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 -I"$guest_dir" -c "$guest_dir/supervisor.c" \
    -o "$tmp/linuxcc/supervisor.o"
  pass 'guest/init.c and guest/supervisor.c each compile with -std=c11 -Wall -Wextra -Werror on Linux (the host compiler as a syntax/semantics gate; PR 6, R2.5)'
else
  /usr/bin/printf 'SKIP (Linux-only, stated reason): guest/init.c and guest/supervisor.c use Linux-only headers (mount(2) MS_* flags, seccomp, Landlock, fanotify, clone3) this Darwin host does not have; proved by the manager'"'"'s dispatched Linux CI run instead (plan.md Proof section, six-shard run).\n' >&2
fi

/usr/bin/printf 'total assertions: %s\n' "$passes" >&2