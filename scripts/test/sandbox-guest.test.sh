#!/usr/bin/env bash
# Proves the YSFRAME1 frame codec and the R5.2/R8.1 record-name sets
# (ystack #463, PR 1 of 9). Builds scripts/test/sandbox-guest-harness.c with
# sandbox/v1/guest/common.c using the host compiler. See
# work/vm-launcher-supervisor/plan.md ("PR 1") and spec.md R3.2. Not run
# against a real guest: this proves the codec only.
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
try_read() { # try_read <frame> [set]; writes stderr to $tmp/err
  local frame=$1 set=${2:-} dir="$tmp/extract" status=0
  /bin/rm -rf -- "$dir"
  if [ -n "$set" ]; then "$h" frame-read "$frame" "$dir" "$set" 2>"$tmp/err" || status=$?
  else "$h" frame-read "$frame" "$dir" 2>"$tmp/err" || status=$?
  fi
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

/usr/bin/printf 'total assertions: %s\n' "$passes" >&2
