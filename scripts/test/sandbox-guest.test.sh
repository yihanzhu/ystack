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

# --- R6.4 exec wiring: argv, the four environment variables, fd 0 regular/read-only,
# fds 1-2 append-only, no other descriptor -------------------------------
/usr/bin/printf 'the instruction bytes' > "$tmp/instr.txt"
: > "$tmp/exec.out"; : > "$tmp/exec.err"
"$h" exec-report "$h" "$tmp/instr.txt" "$tmp/exec.out" "$tmp/exec.err"
expected_report=$'argv:ok\nenv:ok\nfd0:ok\nfd1:ok\nfd2:ok\nextra_fds:0'
[ "$(cat "$tmp/exec.out")" = "$expected_report" ] || fail "exec wiring: unexpected report $(cat "$tmp/exec.out")"
[ ! -s "$tmp/exec.err" ] || fail 'exec wiring: stderr must be empty'
pass 'ys_exec delivers exactly the R6.4 argv and environment, with fd 0 a regular read-only file that rejects writes, fds 1-2 append-only and every other descriptor closed'
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

/bin/cp "$h" "$tmp/verifier-exit126"
/bin/cp "$h" "$tmp/verifier-exit127"
: > "$tmp/exec-126.out"; : > "$tmp/exec-126.err"
"$h" exec-report "$tmp/verifier-exit126" "$tmp/instr.txt" "$tmp/exec-126.out" \
  "$tmp/exec-126.err" exit126
: > "$tmp/exec-127.out"; : > "$tmp/exec-127.err"
"$h" exec-report "$tmp/verifier-exit127" "$tmp/instr.txt" "$tmp/exec-127.out" \
  "$tmp/exec-127.err" exit127
pass 'the close-on-exec outcome channel confirms real verifier exits 126 and 127 without classifying their reserved numbers as pre-exec failure'

: > "$tmp/exec-missing.out"; : > "$tmp/exec-missing.err"
"$h" exec-report "$h" "$tmp/instr.txt" "$tmp/exec-missing.out" "$tmp/exec-missing.err" execfail
[ ! -s "$tmp/exec-missing.out" ] || fail 'execve failure must not run the verifier fixture'
pass 'the outcome channel distinguishes execve failure from a real executable returning 127'

: > "$tmp/exec-eintr.out"; : > "$tmp/exec-eintr.err"
"$hf" exec-report "$hf" "$tmp/instr.txt" "$tmp/exec-eintr.out" "$tmp/exec-eintr.err" eintr
[ "$(cat "$tmp/exec-eintr.out")" = "$expected_report" ] ||
  fail 'an interrupted outcome write must retry and still confirm the executed verifier'
: > "$tmp/exec-reportfail.out"; : > "$tmp/exec-reportfail.err"
"$hf" exec-report "$hf" "$tmp/instr.txt" "$tmp/exec-reportfail.out" \
  "$tmp/exec-reportfail.err" reportfail
pass 'interrupted outcome writes retry, while an unreportable controlled failure terminates by signal and cannot resemble an ordinary verifier exit'

: > "$tmp/exec-predeath.out"; : > "$tmp/exec-predeath.err"
"$h" exec-report "$h" "$tmp/instr.txt" "$tmp/exec-predeath.out" \
  "$tmp/exec-predeath.err" predeath
: > "$tmp/exec-afterreadydeath.out"; : > "$tmp/exec-afterreadydeath.err"
"$h" exec-report "$h" "$tmp/instr.txt" "$tmp/exec-afterreadydeath.out" \
  "$tmp/exec-afterreadydeath.err" afterreadydeath
pass 'a child death both before readiness and after readiness remains distinguishable from a normally exited verifier'

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
# PRs 6-7 of 9: build-guest.py (image determinism, compile's existing-directory
# refusal), the inactive R13.4 probe dispatch, and Linux-only host-compiler
# syntax/semantics gates over the guest sources. See work/vm-launcher-supervisor/
# plan.md ("PR 6", "PR 7") and spec.md R2.5/R13.4. Never runs anything requiring root, a
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

# image refuses to overwrite its deterministic result and refuses either
# missing executable before creating a result.
status=0
"$python" "$build_guest" image "$tmp/img1" >/dev/null 2>"$tmp/err" || status=$?
[ "$status" -ne 0 ] && [ "$(cat "$tmp/err")" = E_BUILD_OUT_EXISTS ] ||
  fail 'build-guest.py image must refuse to overwrite initramfs.cpio'
for absent in init supervisor; do
  /bin/mkdir -m 700 "$tmp/img-missing-$absent"
  if [ "$absent" = init ]; then
    /usr/bin/printf supervisor > "$tmp/img-missing-$absent/supervisor"
  else
    /usr/bin/printf init > "$tmp/img-missing-$absent/init"
  fi
  status=0
  "$python" "$build_guest" image "$tmp/img-missing-$absent" >/dev/null 2>"$tmp/err" || status=$?
  [ "$status" -ne 0 ] && [ "$(cat "$tmp/err")" = E_BUILD_MISSING_INPUT ] &&
    [ ! -e "$tmp/img-missing-$absent/initramfs.cpio" ] ||
    fail "build-guest.py image must refuse a missing $absent without creating output"
done
pass 'image refuses an existing initramfs and each missing required executable without overwriting or creating output'

# --- compile: refuses an existing output directory -------------------------
/bin/mkdir -m 700 "$tmp/compile-out"
status=0
"$python" "$build_guest" compile "$tmp/nonexistent-toolchain" "$tmp/compile-out" >/dev/null 2>"$tmp/err" || status=$?
[ "$status" -ne 0 ] || fail 'build-guest.py compile must refuse an output directory that already exists'
[ "$(cat "$tmp/err")" = E_BUILD_OUT_EXISTS ] ||
  fail "build-guest.py compile: expected E_BUILD_OUT_EXISTS for an existing output directory, got $(cat "$tmp/err")"
pass 'build-guest.py compile refuses an output directory that already exists (checked before any toolchain invocation: an unresolvable toolchain path here would otherwise fail first and mask this case)'

# --- compile: controlled archive extraction and complete provenance --------
/bin/mkdir -m 700 "$tmp/toolchain-a" "$tmp/toolchain-b"
marker="$tmp/compiler-invocations"
"$python" - "$tmp/toolchain-a/toolchain.tar.xz" "$marker" bundled-a <<'PY'
import io, sys, tarfile
archive, marker, bundled = sys.argv[1:]
zig = b'''#!/bin/sh
printf '%s\n' "$0 $*" >> "''' + marker.encode() + b'''"
out=
previous=
for argument do
  if [ "$previous" = -o ]; then out=$argument; fi
  previous=$argument
done
[ -n "$out" ] || exit 41
printf 'synthetic-%s\n' "${out##*/}" > "$out"
'''
with tarfile.open(archive, 'w:xz', format=tarfile.PAX_FORMAT) as tf:
    for name, data, mode in [('zig-fake/zig', zig, 0o755), ('zig-fake/lib/header.h', bundled.encode(), 0o644)]:
        info = tarfile.TarInfo(name)
        info.size, info.mode, info.uid, info.gid, info.mtime = len(data), mode, 0, 0, 0
        tf.addfile(info, io.BytesIO(data))
PY
"$python" - "$tmp/toolchain-b/toolchain.tar.xz" "$marker" bundled-b <<'PY'
import io, sys, tarfile
archive, marker, bundled = sys.argv[1:]
zig = b'''#!/bin/sh
printf '%s\n' "$0 $*" >> "''' + marker.encode() + b'''"
out=
previous=
for argument do
  if [ "$previous" = -o ]; then out=$argument; fi
  previous=$argument
done
[ -n "$out" ] || exit 41
printf 'synthetic-%s\n' "${out##*/}" > "$out"
'''
with tarfile.open(archive, 'w:xz', format=tarfile.PAX_FORMAT) as tf:
    for name, data, mode in [('zig-fake/zig', zig, 0o755), ('zig-fake/lib/header.h', bundled.encode(), 0o644)]:
        info = tarfile.TarInfo(name)
        info.size, info.mode, info.uid, info.gid, info.mtime = len(data), mode, 0, 0, 0
        tf.addfile(info, io.BytesIO(data))
PY
"$python" "$build_guest" compile "$tmp/toolchain-a" "$tmp/build-a"
"$python" "$build_guest" compile "$tmp/toolchain-b" "$tmp/build-b"
"$python" "$build_guest" compile "$tmp/toolchain-a" "$tmp/build-a-repeat"
"$python" - "$tmp/build-a/build-record.json" "$tmp/build-b/build-record.json" \
  "$tmp/toolchain-a/toolchain.tar.xz" "$tmp/toolchain-b/toolchain.tar.xz" "$marker" "$root" <<'PY'
import hashlib, json, os, stat, sys
raw_a = open(sys.argv[1], 'rb').read()
raw_b = open(sys.argv[2], 'rb').read()
record_a = json.loads(raw_a)
record_b = json.loads(raw_b)
digest = lambda path: hashlib.sha256(open(path, 'rb').read()).hexdigest()
body_a, body_b = record_a['body'], record_b['body']
assert record_a['kind'] == 'sandbox_guest_build'
assert record_a['schema_version'] == 1
assert raw_a.endswith(b'\n') and raw_a == (json.dumps(record_a, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n').encode()
assert [item['name'] for item in body_a['executables']] == ['init', 'probe', 'supervisor', 'verifier']
for name in ('init', 'probe', 'supervisor', 'verifier'):
    assert stat.S_IMODE(os.stat(os.path.join(os.path.dirname(sys.argv[1]), name)).st_mode) == 0o555
assert body_a['archive_sha256'] == digest(sys.argv[3])
assert body_b['archive_sha256'] == digest(sys.argv[4])
assert body_a['archive_sha256'] != body_b['archive_sha256'], 'bundled-header change must change archive identity'
source_paths = [item['path'] for item in body_a['sources']]
assert 'verifiers/file-digest/v1/verifier.c' in source_paths
assert {'sandbox/v1/guest/init.c', 'sandbox/v1/guest/probe.c',
        'sandbox/v1/guest/supervisor.c', 'sandbox/v1/guest/common.c',
        'verifiers/file-digest/v1/verifier.c'} == set(source_paths)
assert [item['path'] for item in body_a['headers']] == ['sandbox/v1/guest/common.h']
assert body_a['flags'] == ['-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', '-static', '-target', 'aarch64-linux-musl']
for item in body_a['sources'] + body_a['headers']:
    assert item['sha256'] == digest(os.path.join(sys.argv[6], item['path']))
assert body_a['script_sha256'] == digest(os.path.join(sys.argv[6], 'sandbox/v1/build-guest.py'))
lines = open(sys.argv[5], encoding='utf-8').read().splitlines()
assert len(lines) == 12, 'expected four compiler calls per build, got %d' % len(lines)
assert all('.ystack-toolchain-' in line for line in lines), 'compiler must run from private extraction'
assert all('/toolchain-a/' not in line and '/toolchain-b/' not in line for line in lines)
PY
for target in init probe supervisor verifier; do
  cmp -s "$tmp/build-a/$target" "$tmp/build-b/$target" ||
    fail "synthetic compiler produced different $target bytes across separate archive builds"
done
cmp -s "$tmp/build-a/build-record.json" "$tmp/build-a-repeat/build-record.json" ||
  fail 'identical archives, sources and configuration must produce byte-identical complete build records'
for target in init probe supervisor verifier; do
  cmp -s "$tmp/build-a/$target" "$tmp/build-a-repeat/$target" ||
    fail "identical build inputs produced different repeat $target bytes"
done
pass 'the real compile command privately copies and safely extracts the archive, builds all four mandatory targets, records the complete source/header/digest inventory, and reproduces every target and build record; changing bundled bytes changes archive identity'

unsafe_marker="$tmp/unsafe-compiler-ran"
/bin/mkdir -m 700 "$tmp/toolchain-unsafe"
"$python" - "$tmp/toolchain-unsafe/toolchain.tar.xz" "$unsafe_marker" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], 'w:xz') as tf:
    for name, data, mode in [('zig-fake/zig', ('#!/bin/sh\ntouch %s\n' % sys.argv[2]).encode(), 0o755),
                             ('../escape', b'bad', 0o644)]:
        info = tarfile.TarInfo(name); info.size = len(data); info.mode = mode
        tf.addfile(info, io.BytesIO(data))
PY
status=0
"$python" "$build_guest" compile "$tmp/toolchain-unsafe" "$tmp/build-unsafe" >/dev/null 2>"$tmp/err" || status=$?
[ "$status" -ne 0 ] && [ ! -e "$unsafe_marker" ] && [ ! -e "$tmp/build-unsafe" ] ||
  fail 'unsafe archive member must be refused before compiler invocation and leave no output directory'
pass 'an unsafe toolchain archive member is rejected before compiler invocation and leaves no partial build'

# Every tar member type and topology that could escape or make extraction
# ambiguous is rejected before the synthetic compiler gets control.
archive_attack_marker="$tmp/archive-attack-compiler-ran"
"$python" - "$tmp" "$archive_attack_marker" <<'PY'
import io, os, sys, tarfile
root, marker = sys.argv[1:]
zig = ('#!/bin/sh\ntouch %s\nexit 99\n' % marker).encode()
cases = {
    'absolute': ('file', '/escape', b'x'),
    'symlink': ('symlink', 'zig-fake/link', b''),
    'hardlink': ('hardlink', 'zig-fake/hard', b''),
    'fifo': ('fifo', 'zig-fake/fifo', b''),
    'duplicate': ('duplicate', 'zig-fake/duplicate', b'x'),
    'second-root': ('file', 'other-root/file', b'x'),
    'file-parent': ('file-parent', 'zig-fake/file/child', b'x'),
}
for case, (kind, name, data) in cases.items():
    directory = os.path.join(root, 'toolchain-attack-' + case)
    os.mkdir(directory, 0o700)
    with tarfile.open(os.path.join(directory, 'toolchain.tar.xz'), 'w:xz') as tf:
        info = tarfile.TarInfo('zig-fake/zig'); info.size = len(zig); info.mode = 0o755
        tf.addfile(info, io.BytesIO(zig))
        if kind == 'symlink':
            info = tarfile.TarInfo(name); info.type = tarfile.SYMTYPE; info.linkname = '/tmp'
            tf.addfile(info)
        elif kind == 'hardlink':
            info = tarfile.TarInfo(name); info.type = tarfile.LNKTYPE; info.linkname = 'zig-fake/zig'
            tf.addfile(info)
        elif kind == 'fifo':
            info = tarfile.TarInfo(name); info.type = tarfile.FIFOTYPE
            tf.addfile(info)
        elif kind == 'duplicate':
            for _ in range(2):
                info = tarfile.TarInfo(name); info.size = len(data)
                tf.addfile(info, io.BytesIO(data))
        elif kind == 'file-parent':
            parent = tarfile.TarInfo('zig-fake/file'); parent.size = 1
            tf.addfile(parent, io.BytesIO(b'x'))
            info = tarfile.TarInfo(name); info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
        else:
            info = tarfile.TarInfo(name); info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
PY
for attack in absolute symlink hardlink fifo duplicate second-root file-parent; do
  status=0
  "$python" "$build_guest" compile "$tmp/toolchain-attack-$attack" \
    "$tmp/build-attack-$attack" >/dev/null 2>"$tmp/err" || status=$?
  [ "$status" -ne 0 ] && [ ! -e "$archive_attack_marker" ] &&
    [ ! -e "$tmp/build-attack-$attack" ] ||
    fail "archive attack $attack must be refused before compiler invocation"
done
pass 'absolute paths, links, special files, duplicate names, multiple roots and file-as-parent archive layouts are all refused before compiler invocation'

/bin/mkdir -m 700 "$tmp/toolchain-fail"
"$python" - "$tmp/toolchain-fail/toolchain.tar.xz" <<'PY'
import io, tarfile, sys
zig = b'''#!/bin/sh
out=
previous=
for argument do
  if [ "$previous" = -o ]; then out=$argument; fi
  previous=$argument
done
case "$out" in */supervisor) exit 42;; esac
printf synthetic > "$out"
'''
with tarfile.open(sys.argv[1], 'w:xz') as tf:
    info = tarfile.TarInfo('zig-fake/zig'); info.size = len(zig); info.mode = 0o755
    tf.addfile(info, io.BytesIO(zig))
PY
status=0
"$python" "$build_guest" compile "$tmp/toolchain-fail" "$tmp/build-fail" >/dev/null 2>"$tmp/err" || status=$?
[ "$status" -ne 0 ] && [ ! -e "$tmp/build-fail" ] ||
  fail 'compiler failure must leave no incomplete output directory'
pass 'a compiler failure refuses the incomplete build and removes its private staging directory'

# Archive and compiler preconditions fail closed without promoting a result.
/bin/mkdir -m 700 "$tmp/toolchain-missing" "$tmp/toolchain-symlink" \
  "$tmp/toolchain-corrupt" "$tmp/toolchain-nozig" "$tmp/toolchain-nonexec" \
  "$tmp/toolchain-nooutput" "$tmp/toolchain-symlink-output"
/bin/ln -s "$tmp/toolchain-a/toolchain.tar.xz" "$tmp/toolchain-symlink/toolchain.tar.xz"
/usr/bin/printf 'not an xz tar archive' > "$tmp/toolchain-corrupt/toolchain.tar.xz"
"$python" - "$tmp" <<'PY'
import io, os, sys, tarfile
root = sys.argv[1]
cases = {
    'nozig': ('zig-fake/not-zig', b'not a compiler', 0o755),
    'nonexec': ('zig-fake/zig', b'#!/bin/sh\nexit 99\n', 0o644),
    'nooutput': ('zig-fake/zig', b'#!/bin/sh\nexit 0\n', 0o755),
    'symlink-output': ('zig-fake/zig', b'''#!/bin/sh
out=
previous=
for argument do
  if [ "$previous" = -o ]; then out=$argument; fi
  previous=$argument
done
/bin/ln -s /dev/null "$out"
''', 0o755),
}
for case, (name, data, mode) in cases.items():
    archive = os.path.join(root, 'toolchain-' + case, 'toolchain.tar.xz')
    with tarfile.open(archive, 'w:xz') as tf:
        info = tarfile.TarInfo(name); info.size = len(data); info.mode = mode
        tf.addfile(info, io.BytesIO(data))
PY
for invalid in missing symlink corrupt nozig nonexec nooutput symlink-output; do
  status=0
  "$python" "$build_guest" compile "$tmp/toolchain-$invalid" \
    "$tmp/build-invalid-$invalid" >/dev/null 2>"$tmp/err" || status=$?
  [ "$status" -ne 0 ] && [ ! -e "$tmp/build-invalid-$invalid" ] ||
    fail "invalid toolchain case $invalid must fail without promoting an output directory"
done
pass 'missing, symlinked, corrupt, compiler-less, non-executable, no-output and symlink-output toolchains all fail closed without a partial result'

# Success and every refusal remove the private archive copy, extraction and
# staging directories; their names are observable here only in this test root.
private_left=$(/usr/bin/find "$tmp" -maxdepth 1 \
  \( -name '.ystack-toolchain-*' -o -name '.ystack-build-*' \) -print)
[ -z "$private_left" ] ||
  fail "build-guest.py left private build state behind: $private_left"
pass 'compile removes every private archive copy, extraction directory and staging directory after both success and failure'

for missing in init.c supervisor.c probe.c common.c common.h verifier.c; do
  case_root="$tmp/missing-$missing"
  /bin/mkdir -p "$case_root/sandbox/v1/guest" "$case_root/verifiers/file-digest/v1"
  /bin/chmod 700 "$case_root/sandbox/v1/guest" "$case_root/verifiers/file-digest/v1"
  /bin/cp "$build_guest" "$case_root/sandbox/v1/build-guest.py"
  /bin/cp "$guest_dir/init.c" "$guest_dir/probe.c" "$guest_dir/supervisor.c" "$guest_dir/common.c" \
    "$guest_dir/common.h" "$case_root/sandbox/v1/guest/"
  /bin/cp "$root/verifiers/file-digest/v1/verifier.c" \
    "$case_root/verifiers/file-digest/v1/verifier.c"
  if [ "$missing" = verifier.c ]; then
    /bin/rm "$case_root/verifiers/file-digest/v1/verifier.c"
  else
    /bin/rm "$case_root/sandbox/v1/guest/$missing"
  fi
  before_lines=$(/usr/bin/wc -l < "$marker" | /usr/bin/tr -d ' ')
  status=0
  "$python" "$case_root/sandbox/v1/build-guest.py" compile "$tmp/toolchain-a" \
    "$tmp/build-missing-$missing" >/dev/null 2>"$tmp/err" || status=$?
  after_lines=$(/usr/bin/wc -l < "$marker" | /usr/bin/tr -d ' ')
  [ "$status" -ne 0 ] && [ "$before_lines" = "$after_lines" ] &&
    [ ! -e "$tmp/build-missing-$missing" ] ||
    fail "missing mandatory $missing must be refused before compiler invocation"
done
pass 'compile resolves the four-target source inventory and shared header from the repository root and refuses every previously mandatory input before compiler invocation'

# A present path is insufficient: mandatory sources and headers are repository
# regular files, never links resolved outside the recorded source inventory.
case_root="$tmp/symlink-probe-source"
/bin/mkdir -p "$case_root/sandbox/v1/guest" "$case_root/verifiers/file-digest/v1"
/bin/chmod 700 "$case_root/sandbox/v1/guest" "$case_root/verifiers/file-digest/v1"
/bin/cp "$build_guest" "$case_root/sandbox/v1/build-guest.py"
/bin/cp "$guest_dir/init.c" "$guest_dir/probe.c" "$guest_dir/supervisor.c" \
  "$guest_dir/common.c" "$guest_dir/common.h" "$case_root/sandbox/v1/guest/"
/bin/cp "$root/verifiers/file-digest/v1/verifier.c" \
  "$case_root/verifiers/file-digest/v1/verifier.c"
/bin/mv "$case_root/sandbox/v1/guest/probe.c" "$case_root/probe-real.c"
/bin/ln -s "$case_root/probe-real.c" "$case_root/sandbox/v1/guest/probe.c"
before_lines=$(/usr/bin/wc -l < "$marker" | /usr/bin/tr -d ' ')
status=0
"$python" "$case_root/sandbox/v1/build-guest.py" compile "$tmp/toolchain-a" \
  "$tmp/build-symlink-probe" >/dev/null 2>"$tmp/err" || status=$?
after_lines=$(/usr/bin/wc -l < "$marker" | /usr/bin/tr -d ' ')
[ "$status" -ne 0 ] && [ "$before_lines" = "$after_lines" ] &&
  [ ! -e "$tmp/build-symlink-probe" ] ||
  fail 'a symlinked mandatory probe source must fail before compiler invocation'
pass 'compile rejects a symlinked mandatory probe source before compiler invocation and leaves no build output'

# The private test build uses the production parser, action dispatcher and result
# model. Its compile-time low-level fixture never runs pressure, socket, signal,
# privileged, or host/sibling-sentinel operations on this development host.
/usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 -DYSTACK_PROBE_TEST -I"$guest_dir" \
  "$guest_dir/probe.c" "$guest_dir/common.c" -o "$tmp/probe-production-test"
probe_result=$("$tmp/probe-production-test") || fail 'the probe production-path fixture failed'
[ "$probe_result" = 'probe production parser/action/result fixture: ok' ] ||
  fail "unexpected probe production-path fixture output: $probe_result"
pass 'the bounded probe fixture exercises the closed YSPROBE1 parser, request binding, action/result classification, cleanup preservation and signal target selection without native probe actions'

/usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 -DYSTACK_PROBE_TEST \
  -DYSTACK_TEST_NO_SOCKET_CONSTANTS -I"$guest_dir" \
  "$guest_dir/probe.c" "$guest_dir/common.c" -o "$tmp/probe-missing-socket-facts-test"
missing_facts_result=$("$tmp/probe-missing-socket-facts-test") ||
  fail 'the probe fallback build without Linux socket constants failed'
[ "$missing_facts_result" = 'probe production parser/action/result fixture: ok' ] ||
  fail "unexpected missing-socket-facts fixture output: $missing_facts_result"
pass 'the private socket-facts fallback compiles and runs with Linux header constants unavailable'

# Sanitizers exercise the same bounded private fixture where the host compiler
# supports them. This remains substituted host proof, never native qualification.
/usr/bin/cc -std=c11 -Wall -Wextra -Werror -O1 -g -fno-omit-frame-pointer \
  -fsanitize=address,undefined -DYSTACK_PROBE_TEST -I"$guest_dir" \
  "$guest_dir/probe.c" "$guest_dir/common.c" -o "$tmp/probe-production-sanitized"
if [ "$(/usr/bin/uname -s)" = Darwin ]; then
  ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 \
    "$tmp/probe-production-sanitized" >/dev/null
  /usr/bin/printf 'SKIP (Darwin capability): leak detection is unsupported by the platform ASan runtime; the same bounded fixture ran with ASan memory checks and UBSan. Linux CI runs detect_leaks=1.\n' >&2
else
  ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
    "$tmp/probe-production-sanitized" >/dev/null
fi
pass 'the bounded production-path probe fixture passes ASan/UBSan without executing native qualification actions'

# --- Linux-only: the host compiler as a syntax/semantics gate over
# guest/init.c, guest/supervisor.c and guest/probe.c. Darwin has no <linux/...> headers
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
  /usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 -I"$guest_dir" -c "$guest_dir/probe.c" \
    -o "$tmp/linuxcc/probe.o"
  pass 'guest/init.c, guest/supervisor.c and guest/probe.c each compile with -std=c11 -Wall -Wextra -Werror on Linux (the host compiler as a syntax/semantics gate; PRs 6-7, R2.5/R13.4)'
  /usr/bin/cc -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -DYSTACK_INIT_TEST "$guest_dir/init.c" -o "$tmp/linuxcc/init-production-test"
  ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
    "$tmp/linuxcc/init-production-test"
  pass 'the production init setup path preserves directory and mount order, stops at every injected failure and hands off only to /supervisor'
  /usr/bin/cc -std=c11 -Wall -Wextra -O1 -g -fno-omit-frame-pointer \
    -fsanitize=address,undefined -DYSTACK_SUPERVISOR_TEST -DYSTACK_TEST_FAULT_INJECT -I"$guest_dir" \
    "$guest_dir/supervisor.c" "$guest_dir/common.c" -o "$tmp/linuxcc/supervisor-production-test"
  /bin/mkdir -m 700 "$tmp/supervisor-production"
  ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
    "$tmp/linuxcc/supervisor-production-test" "$tmp/supervisor-production" \
      "$tmp/production-report.json"
  pass 'the production supervisor report writer, filter generator, instruction descriptor, fanotify history, privilege sequence and tmpfs geometry pass their Linux ASan/UBSan helper tests'
  "$python" - "$root/sandbox/v1/host-supervisor.py" "$tmp/production-report.json" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('host_supervisor', sys.argv[1])
host = importlib.util.module_from_spec(spec); spec.loader.exec_module(host)
report = open(sys.argv[2], 'rb').read()
records = [(b'report.json', report), (b'stdout', b''), (b'stderr', b'')]
assert host.validate_export(records, 'a' * 64) is not None
PY
  pass 'a production-built canonical guest report and complete export pass the unchanged host validate_export consumer'
else
  /usr/bin/printf 'SKIP (Linux-only, stated reason): strict guest init/supervisor/probe compilation and the production helper require Linux headers and semantics this Darwin host does not have. ASan/UBSan, generated-filter and actual descriptor-mode tests remain for dispatched CI; this Darwin run does not execute or qualify any R13.4 probe action.\n' >&2
fi

/usr/bin/printf 'total assertions: %s\n' "$passes" >&2
