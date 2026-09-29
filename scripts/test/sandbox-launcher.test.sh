#!/usr/bin/env bash
# Proves sandbox/v1/host-supervisor.py's phase A (R4.1), the R10.1 ACL walk,
# the store root (work/enforcement-evidence-binding/spec.md R2.3), the R10.2
# store writer and the R10.3 receipt/outcome (ystack #463, PR 3 of 9). See
# work/vm-launcher-supervisor/plan.md ("PR 3") and spec.md R3/R4.1/R9.4/R10.
# Not run against a real hypervisor: until PR 5 an admitted attempt ends at
# one stub receipt (the runtime never started).
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
python=/usr/bin/python3
supervisor_src="$root/sandbox/v1/host-supervisor.py"
[ "$(id -u)" -ne 0 ] || { printf 'FAIL: refuses to run as uid 0 (R15.1)\n' >&2; exit 1; }

fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha_file() { /usr/bin/shasum -a 256 -- "$1" | /usr/bin/awk '{print $1}'; }

# The real, shipped control/v1 fixed-file digests (content-addressed, so
# stable across platforms) — must match build_pkg.py's own copies and
# enforcement/v1/sandbox-receipt.jq's policy_pin/decision_pin/policy_set_pin.
real_policy_sha=$(sha_file "$root/control/v1/sandbox-policy.json")
real_decision_sha=$(sha_file "$root/control/v1/sandbox-decision.json")
real_policy_set_sha=$(sha_file "$root/control/v1/control-policy-set.json")

# --- pinned jq 1.6, as scripts/test/shadow-slice.test.sh:24-51 -------------
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
if [ ! -f "$jq_cache" ] || [ -L "$jq_cache" ] || [ "$(sha_file "$jq_cache")" != "$jq_sha" ]; then
  download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$download"
  [ "$(sha_file "$download")" = "$jq_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_cache"
fi

# --- install tree base: $TMPDIR if every ancestor passes R10.1, else $HOME -
probe_r10_1() {
  "$python" -c "
import sys, importlib.util
spec = importlib.util.spec_from_file_location('hs', '$supervisor_src')
hs = importlib.util.module_from_spec(spec); spec.loader.exec_module(hs)
try:
    hs.os.close(hs.secure_walk('$1', hs.os.getuid(), True))
except hs.Refusal:
    sys.exit(1)
"
}
base_parent=""
for candidate_parent in "${TMPDIR:-/tmp}" "$HOME"; do
  probe=$(/usr/bin/mktemp -d "$candidate_parent/ystack-sandbox-launcher-test.XXXXXX" 2>/dev/null) || continue
  if probe_r10_1 "$probe"; then base_parent=$candidate_parent; /bin/rm -rf -- "$probe"; break; fi
  /bin/rm -rf -- "$probe"
done
# On most CI runners neither is clean (/tmp is 1777; $HOME's ancestors are
# out of this test's control). The *product* check is untouched -- a real
# launch still walks from "/" -- but the test makes its own clean anchor
# and points the walk at it via YSTACK_SANDBOX_TRUST_ROOT (verified below).
trust_root=""
if [ -z "$base_parent" ]; then
  trust_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-sandbox-launcher-trust.XXXXXX")
  /bin/chmod 0755 "$trust_root"
  trust_root=$(CDPATH='' cd -P -- "$trust_root" && pwd -P)
  base_parent=$trust_root
fi
export YSTACK_SANDBOX_TRUST_ROOT="$trust_root"
base=$(/usr/bin/mktemp -d "$base_parent/ystack-sandbox-launcher-test.XXXXXX")
base=$(CDPATH='' cd -P -- "$base" && pwd -P)
cleanup() {
  /bin/chmod -R u+rwX "$base" 2>/dev/null || :; /bin/rm -rf -- "$base"
  [ -z "$trust_root" ] || /bin/rm -rf -- "$trust_root"
}
trap cleanup EXIT
jq_dir="$base/bin"
/bin/mkdir -m 0755 "$jq_dir"
/bin/cp "$jq_cache" "$jq_dir/jq"
/bin/chmod 0555 "$jq_dir/jq"
jq_bin="$jq_dir/jq"
[ "$("$jq_bin" --version)" = jq-1.6 ] || fail 'jq identity'

# The hook: refused unless owned by this uid and not group/other-writable.
trust_root_hook_ok() { # trust_root_hook_ok <env-value> <expect: none|some>
  local got
  got=$(YSTACK_SANDBOX_TRUST_ROOT="$1" "$python" -c "
import importlib.util
spec = importlib.util.spec_from_file_location('hs', '$supervisor_src')
hs = importlib.util.module_from_spec(spec); spec.loader.exec_module(hs)
root, fd = hs.trust_root_fd()
print('none' if root is None else 'some')
")
  [ "$got" = "$2" ] || fail "trust-root hook: expected $2 for '$1', got $got"
}
trust_root_hook_ok "" none
trust_root_hook_ok /nonexistent-ystack-trust-root none
trust_root_hook_ok /tmp none
readable_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-trust-probe.XXXXXX")
/bin/chmod 0755 "$readable_dir"
trust_root_hook_ok "$readable_dir" some
/bin/rm -rf -- "$readable_dir"
pass 'YSTACK_SANDBOX_TRUST_ROOT is honored only for a directory already owned by the invoking uid and not group/other-writable; unset, missing or unclean (including /tmp itself) it is refused as an anchor, falling back to "/"'

# work_root: outside R10.1, kept short for socket paths (R15.1).
work_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ysvml.XXXXXX")

# --- fixture install tree builder ------------------------------------------
cat > "$base/build_tree.py" <<'PY'
import sys, os, json, shutil, hashlib

def canon(v):
    return (json.dumps(v, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                        allow_nan=False).encode("utf-8") + b"\n")

def main():
    base, src, work_root, placeholder = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
    shutil.rmtree(base, ignore_errors=True)
    os.makedirs(base, mode=0o755)
    install_dir = os.path.join(base, "install")
    os.makedirs(install_dir, mode=0o755)
    shutil.copy(src, os.path.join(install_dir, "host-supervisor.py"))
    os.chmod(os.path.join(install_dir, "host-supervisor.py"), 0o555)

    identity_keys = ["guest_init", "guest_kernel", "guest_kernel_config", "guest_supervisor",
                     "host_runtime", "host_supervisor", "image", "toolchain", "verifier"]
    identities_dir = os.path.join(base, "identities")
    os.makedirs(identities_dir, mode=0o755)
    identity_paths = {}
    for k in identity_keys:
        p = os.path.join(identities_dir, k)
        open(p, "wb").write(b"synthetic-" + k.encode())
        os.chmod(p, 0o444)
        identity_paths[k] = p

    installed_keys = ["accepted_set", "control_decision", "control_policy", "control_policy_set",
                       "evaluator_driver", "evaluator_program", "registry"]
    installed_dir = os.path.join(base, "installed")
    os.makedirs(installed_dir, mode=0o755)
    installed_files = {}
    for k in installed_keys:
        p = os.path.join(installed_dir, k)
        open(p, "wb").write(b"synthetic-" + k.encode())
        installed_files[k] = p

    digest = "1" * 64 if placeholder else "1234567890abcdef" * 4  # "1"*64 is ALL_ONES
    accepted_doc = {"body": {"activation_state": "inactive", "set_version": "v1", "environments": [
        {"environment_id": "env.local-macos-fixture", "scratch_bytes": 16777216,
         "identities": {k: [digest] for k in identity_keys + ["verification_instructions"]},
         "mechanisms": {r: ["mechanism.fixture"] for r in
                        ["cpu_time_ms", "memory_bytes", "output_bytes", "process_count",
                         "scratch_bytes", "wall_time_ms"]}}]},
        "id": "sandbox.accepted-identities.v1", "kind": "sandbox_accepted_identity_set", "schema_version": 1}
    open(installed_files["accepted_set"], "wb").write(canon(accepted_doc))
    for k in installed_keys:
        os.chmod(installed_files[k], 0o444)

    vfkit_path = os.path.join(base, "vfkit")
    open(vfkit_path, "wb").write(b"fake-vfkit")
    os.chmod(vfkit_path, 0o555)
    driver_path = os.path.join(base, "driver")
    open(driver_path, "wb").write(b"fake-driver")
    os.chmod(driver_path, 0o555)

    store_root = os.path.join(base, "store")
    os.makedirs(store_root, mode=0o750)
    os.chmod(store_root, 0o750)  # os.makedirs's mode is subject to umask (the
                                  # driver sets umask 077); force the exact bits.
    os.chown(store_root, os.getuid(), os.getgid())

    config_body = {
        "consumer_gid": os.getgid(), "environment_id": "env.local-macos-fixture",
        "identity_paths": identity_paths, "installed_files": installed_files,
        "principal_uid": os.getuid(), "runtime": {"driver": driver_path, "vfkit": vfkit_path},
        "store_id": "store.fixture.v1", "store_root": store_root, "work_root": work_root,
    }
    config_doc = {"body": config_body, "id": "sandbox.host-config.v1",
                  "kind": "sandbox_host_config", "schema_version": 1}
    config_path = os.path.join(install_dir, "host-config.json")
    open(config_path, "wb").write(canon(config_doc))
    os.chmod(config_path, 0o444)
    print(json.dumps({"install_dir": install_dir, "store_root": store_root,
                       "config_path": config_path, "accepted_set": installed_files["accepted_set"],
                       "driver_path": driver_path}))

if __name__ == "__main__":
    main()
PY

# --- package/request builder: a JSON patch (body overrides + delete list +
# frame corruption mode) turns the baseline into every phase-A/shape fixture.
cat > "$base/build_pkg.py" <<'PY'
import sys, os, json, importlib.util

def deep_set(d, path, value):
    parts = path.split(".")
    for p in parts[:-1]:
        d = d[p]
    if value is _DELETE:
        del d[parts[-1]]
    else:
        d[parts[-1]] = value

_DELETE = object()

def main():
    supervisor_src, out_path = sys.argv[1], sys.argv[2]
    patch = json.load(sys.stdin)
    spec = importlib.util.spec_from_file_location("hs", supervisor_src)
    hs = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hs)
    # A non-placeholder filler (all-zero/all-one both read as
    # receipt.placeholder-identity by the shipped checker's has_placeholder_identity).
    filler = "c" * 64
    # The real, shipped control/v1 fixed-file digests (content-addressed, so
    # stable across platforms): matches enforcement/v1/sandbox-receipt.jq's
    # own policy_pin/decision_pin/policy_set_pin and the decision's own
    # evaluator driver_ref/program_ref sha256, so a request built with these
    # (plus a matching evaluation.json) does not trip receipt.control-mismatch
    # in the shipped-checker cross-check below.
    real_policy_sha = "4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e"
    real_decision_sha = "c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd"
    real_policy_set_sha = "3fff018a4a7cbd9d8c69339ce1cd20c7f940b7af8080b12afe36e57961757eb8"
    real_driver_sha = "8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb"
    real_program_sha = "83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3"
    control = {"decision_sha256": real_decision_sha, "evaluator_driver_sha256": real_driver_sha,
               "evaluator_program_sha256": real_program_sha, "policy_sha256": real_policy_sha,
               "policy_set_sha256": real_policy_set_sha,
               "sandbox_evaluation_sha256": patch.get("evaluation_sha256", filler)}
    subject = {"environment_id": "env.local-macos-fixture", "environment_entry_sha256": filler,
               "target_repository_id": "target.fixture",
               "source": {"repository_id": "target.fixture", "hash_algorithm": "sha1",
                          "commit_id": "a" * 40, "tree_id": "a" * 40},
               "candidate": {"preparation_record_sha256": filler, "manifest_sha256": filler,
                             "commit_id": "a" * 40, "tree_id": "a" * 40},
               "incident_sha256": filler}
    body = {"attempt": {"attempt_id": patch.get("attempt_id", "attempt.fixture-0001"),
                        "attempt_number": patch.get("attempt_number", 1)},
            "control": control, "instruction_sha256": filler,
            "nonce": patch.get("nonce", "ab" * 32),
            "store_id": patch.get("store_id", "store.fixture.v1"), "subject": subject}
    for path, value in patch.get("set", {}).items():
        deep_set(body, path, value)
    for path in patch.get("delete", []):
        deep_set(body, path, _DELETE)
    request_doc = {"body": body, "id": "sandbox.launch-request.fixture",
                   "kind": "sandbox_launch_request", "schema_version": 1}
    if "raw_request_depth" in patch:
        n = patch["raw_request_depth"]  # built flat, so json.dumps never has to recurse either
        request_bytes = b"[" * n + b"1" + b"]" * n
    elif "raw_request" in patch:
        request_bytes = json.dumps(patch["raw_request"], ensure_ascii=False).encode()
    else:
        request_bytes = hs.canonical(request_doc)
    mode = patch.get("frame", "ok")
    incident_bytes = b"i" * patch["incident_bytes"] if "incident_bytes" in patch else b"{}\n"
    records = [(b"request.json", request_bytes), (b"evaluation.json", b"{}\n"),
               (b"incident.json", incident_bytes), (b"record.json", b"{}\n"),
               (b"manifest.json", b"{}\n"), (b"instruction", b"instr")]
    if mode == "ok":
        data = hs.frame_write(records)
    elif mode == "missing_record":
        data = hs.frame_write(records[:3] + records[4:])
    elif mode == "bad_order":
        data = hs.frame_write([records[1], records[0]] + records[2:])
    elif mode == "bad_magic":
        data = bytearray(hs.frame_write(records)); data[0] ^= 0xFF; data = bytes(data)
    elif mode == "truncated":
        data = hs.frame_write(records)[:-1]
    elif mode == "oversize":
        data = b"x" * (88080384 + 1)
    else:
        raise SystemExit("bad frame mode " + mode)
    with open(out_path, "wb") as fh:
        fh.write(data)
    if "expectation_out" in patch:
        exp_body = {"attempt": {"attempt_id": body["attempt"]["attempt_id"],
                                "attempt_number": body["attempt"]["attempt_number"],
                                "launch_request_sha256": hs.sha256_hex(request_bytes)},
                    "control": control, "store_id": body["store_id"], "subject": subject}
        exp_doc = {"body": exp_body, "id": "sandbox.expectation.fixture",
                   "kind": "sandbox_receipt_expectation", "schema_version": 1}
        open(patch["expectation_out"], "wb").write(hs.canonical(exp_doc))

if __name__ == "__main__":
    main()
PY

build_tree() { # build_tree <placeholder: 0|1>  -> prints paths as JSON, sets globals
  local info
  info=$("$python" "$base/build_tree.py" "$base/root" "$supervisor_src" "$work_root" "$1")
  install_dir=$(printf '%s' "$info" | "$jq_bin" -r .install_dir)
  store_root=$(printf '%s' "$info" | "$jq_bin" -r .store_root)
  config_path=$(printf '%s' "$info" | "$jq_bin" -r .config_path)
  # shellcheck disable=SC2034 # part of build_tree's documented fixture-path globals
  accepted_set=$(printf '%s' "$info" | "$jq_bin" -r .accepted_set)
  driver_path=$(printf '%s' "$info" | "$jq_bin" -r .driver_path)
  /bin/rm -rf -- "${work_root:?}"/*
}
build_pkg() { # build_pkg <out-file> <json-patch>
  printf '%s' "$2" | "$python" "$base/build_pkg.py" "$install_dir/host-supervisor.py" "$1"
}
run_launch() { # run_launch <pkg-file> [--extra-args]; sets status, stdout/stderr in $base/out,$base/err
  ( CDPATH='' cd -- "$install_dir" && "$python" host-supervisor.py launch ) \
    <"$1" >"$base/out" 2>"$base/err"
}
snapshot_store() { # deterministic listing of every store path/mode/owner, for before/after diffs
  "$python" -c "
import os, sys
root = sys.argv[1]
rows = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(dirnames) + sorted(filenames):
        full = os.path.join(dirpath, name)
        st = os.lstat(full)
        rows.append('%s\t%o\t%d\t%d\t%d' % (os.path.relpath(full, root), st.st_mode & 0o7777,
                                             st.st_uid, st.st_gid, st.st_nlink))
print('\n'.join(sorted(rows)))
" "$store_root"
}
expect_refused() { # expect_refused <desc> <expected-code> <pkg-file> [launch-argv-json]
  local desc=$1 expected=$2 pkgfile=$3 before after status=0
  before=$(snapshot_store)
  run_launch "$pkgfile" || status=$?
  after=$(snapshot_store)
  [ "$before" = "$after" ] || fail "$desc: the store changed on a phase A refusal"
  [ "$status" -eq 65 ] || fail "$desc: expected exit 65, got $status"
  [ ! -s "$base/out" ] || fail "$desc: stdout must be empty"
  [ "$(cat "$base/err")" = "$expected" ] || fail "$desc: expected $expected, got $(cat "$base/err")"
}
expect_admitted() { # expect_admitted <desc> <pkg-file> -> leaves receipt path in $receipt_path
  local desc=$1 pkgfile=$2 status=0
  run_launch "$pkgfile" || status=$?
  [ "$status" -eq 0 ] || fail "$desc: expected exit 0, got $status ($(cat "$base/err"))"
  [ ! -s "$base/out" ] || fail "$desc: stdout must be empty"
  [ ! -s "$base/err" ] || fail "$desc: stderr must be empty"
}
canonical_ok() { # canonical_ok <desc> <json-file>
  local desc=$1 file=$2
  [ "$("$jq_bin" -S -c . "$file")" = "$(cat "$file")" ] || fail "$desc: not canonical jq -S -c"
}

# =============================================================================
# R10.1 ACL walk (checked before anything else, usage included)
# =============================================================================
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'
expect_admitted 'a fully correct install tree, store root and package' "$base/pkg-ok.json"
canonical_ok 'the written receipt' "$store_root/attempt.fixture-0001/receipt.json"
pass 'a correctly owned, non-group-writable, ACL-free install tree admits the attempt and writes a canonical receipt'

acl_grant_write() { # Darwin: an ACL entry granting "everyone" write; refused
                     # regardless of effective permission (R10.1 rejects the entry itself).
  if [ "$(/usr/bin/uname -s)" = Darwin ]; then
    /bin/chmod +a "everyone allow write" "$1"
  else
    # Linux: a named-user entry (masked to withhold write) still refuses,
    # because R10.1 rejects any named entry, stricter than effective
    # permission by design; separately, a mask alone granting write refuses.
    "$python" -c "
import os, sys, struct
path = sys.argv[1]
entries = [(0x01, 0x07, 0xffffffff), (0x02, 0x00, 60000), (0x04, 0x05, 0xffffffff),
           (0x10, 0x05, 0xffffffff), (0x20, 0x00, 0xffffffff)]
blob = struct.pack('<I', 2) + b''.join(struct.pack('<HHI', t, p, i) for t, p, i in entries)
os.setxattr(path, 'system.posix_acl_access', blob, follow_symlinks=False)
" "$1"
  fi
}
acl_clear() {
  if [ "$(/usr/bin/uname -s)" = Darwin ]; then
    /bin/chmod -a "everyone allow write" "$1" 2>/dev/null || :
  else
    "$python" -c "import os, sys; os.removexattr(sys.argv[1], 'system.posix_acl_access', follow_symlinks=False)" "$1" 2>/dev/null || :
  fi
}

for target_desc_pair in "$config_path:the trusted config file" "$base/root/install:the install directory" "$base/root:an ancestor of the install directory"; do
  target=${target_desc_pair%%:*}
  desc=${target_desc_pair#*:}
  build_tree 0
  build_pkg "$base/pkg-ok.json" '{}'
  acl_grant_write "$target"
  expect_refused "E_INSTALL_ACL: $desc carries one ACL entry" E_INSTALL_ACL "$base/pkg-ok.json"
  acl_clear "$target"
  expect_admitted "control: $desc without the ACL entry" "$base/pkg-ok.json"
  pass "$desc carrying one ACL entry is refused E_INSTALL_ACL before stdin is read, paired against the same tree without it"
done

if [ "$(/usr/bin/uname -s)" = Darwin ]; then
  # Multi-entry ACL regression for the P1 fix: Darwin's ACL_NEXT_ENTRY is
  # -1, not 1 -- with the wrong constant the entry iterator never advances
  # past the first entry, so a second entry is silently never inspected.
  build_tree 0
  build_pkg "$base/pkg-ok.json" '{}'
  /bin/chmod +a "$(id -un) deny append" "$config_path"
  /bin/chmod +a "everyone deny write" "$config_path"
  expect_admitted 'two deny-only ACL entries on the trusted config file' "$base/pkg-ok.json"
  /bin/chmod -N "$config_path"
  build_tree 0
  build_pkg "$base/pkg-ok.json" '{}'
  /bin/chmod +a "$(id -un) deny append" "$config_path"
  /bin/chmod +a "everyone allow write" "$config_path"
  expect_refused 'E_INSTALL_ACL: two entries, the second an everyone-allow-write grant' E_INSTALL_ACL "$base/pkg-ok.json"
  /bin/chmod -N "$config_path"
  build_tree 0; build_pkg "$base/pkg-ok.json" '{}'
  pass 'a multi-entry ACL is walked in full: two deny-only entries admit, two entries including an everyone-allow-write grant refuse E_INSTALL_ACL -- proving the ACL_NEXT_ENTRY fix actually advances past the first entry'
fi

# runtime.driver, like vfkit, is a config-listed file (R10.1) and must be
# walked: a world-writable driver, outside the install tree, is refused.
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'
/bin/chmod 666 "$driver_path"
expect_refused 'E_CONFIG: runtime.driver itself is world-writable' E_CONFIG "$base/pkg-ok.json"
/bin/chmod 555 "$driver_path"
expect_admitted 'control: runtime.driver restored to non-writable' "$base/pkg-ok.json"
pass 'runtime.driver, alongside runtime.vfkit, is included in the R10.1 config-named walk: a world-writable driver is refused E_CONFIG, paired against the same tree without it'

# A group/other-writable ancestor (no ACL entry, just a bad mode) is
# refused too, not only caught by luck when some other path crosses it.
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'
/bin/chmod 0775 "$base/root"
expect_refused 'E_CONFIG: an ancestor of the install directory is group-writable' E_CONFIG "$base/pkg-ok.json"
/bin/chmod 0755 "$base/root"
expect_admitted 'control: the same ancestor restored to non-group-writable' "$base/pkg-ok.json"
pass 'a group/other-writable ancestor of the install directory, with no ACL entry at all, is refused E_CONFIG, paired against the same tree without it'

# A symlink anywhere in a config-named path's chain, even far from the
# install tree, must be refused rather than silently followed through.
build_tree 0
/bin/mkdir -m 755 "$base/attacker-writable"
/bin/ln -s "$base/identities" "$base/attacker-writable/link"
# shellcheck disable=SC2016 # $p is a jq variable, not a shell expansion
"$jq_bin" -c --arg p "$base/attacker-writable/link/verifier" '.body.identity_paths.verifier = $p' \
  "$config_path" > "$base/bad-config.json"
/bin/chmod 644 "$config_path"; /bin/cp "$base/bad-config.json" "$config_path"; /bin/chmod 444 "$config_path"
build_pkg "$base/pkg-ok.json" '{}'
expect_refused 'E_INSTALL_ACL: a config-named path reached only through a symlink in an otherwise-writable directory' \
  E_INSTALL_ACL "$base/pkg-ok.json"
build_tree 0; build_pkg "$base/pkg-ok.json" '{}'
pass 'a config-named path whose chain passes through a symlink -- even one sitting in a directory that is not itself part of the trusted tree -- is refused E_INSTALL_ACL rather than silently resolved through, paired against the accepted control'

# =============================================================================
# every other phase A error, paired against the accepted control above
# =============================================================================
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'

( CDPATH='' cd -- "$install_dir" && "$python" host-supervisor.py bogus-command </dev/null >"$base/out" 2>"$base/err" ) || status=$?
[ "${status:-0}" -eq 65 ] || fail "E_USAGE: expected exit 65, got ${status:-0}"
[ "$(cat "$base/err")" = E_USAGE ] || fail 'E_USAGE: unexpected stderr'
status=0
pass 'an unrecognized argument is refused E_USAGE (after the same ACL walk as every other invocation)'

"$jq_bin" -c '.body.work_root = "/sandbox/x"' "$config_path" > "$base/bad-config.json"
/bin/chmod 644 "$config_path"; /bin/cp "$base/bad-config.json" "$config_path"; /bin/chmod 444 "$config_path"
expect_refused 'E_CONFIG: work_root under /sandbox' E_CONFIG "$base/pkg-ok.json"
build_tree 0; build_pkg "$base/pkg-ok.json" '{}'
pass 'a configuration whose work_root is under /sandbox is refused E_CONFIG, paired against the accepted control'

build_tree 1
build_pkg "$base/pkg-ok.json" '{}'
expect_refused 'E_CONFIG: a placeholder digest in the accepted set' E_CONFIG "$base/pkg-ok.json"
build_tree 0; build_pkg "$base/pkg-ok.json" '{}'
pass 'a placeholder (all-ones) digest anywhere in the accepted identity set is refused E_CONFIG, paired against the accepted control'

# The full accepted-set schema (sandbox-receipt.jq's fixed_accepted_shape_ok).
mutate_accepted_set() { # mutate_accepted_set <jq-filter>
  "$jq_bin" -S -c "$1" "$accepted_set" > "$base/bad-accepted.json"
  /bin/chmod 644 "$accepted_set"; /bin/cp "$base/bad-accepted.json" "$accepted_set"; /bin/chmod 444 "$accepted_set"
}
accepted_set_filters=(
  '.id = "sandbox.accepted-identities.wrong"'
  '.body.environments[0].identities |= del(.verifier)'
  '.body.environments[0].identities.verifier = ["1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcd","1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcd"]'
  '.body.environments[0].mechanisms.wall_time_ms = ["Mechanism.Bad"]'
)
for filt in "${accepted_set_filters[@]}"; do
  mutate_accepted_set "$filt"
  build_pkg "$base/pkg-ok.json" '{}'
  expect_refused "E_CONFIG: accepted-set deviation ($filt)" E_CONFIG "$base/pkg-ok.json"
  build_tree 0; build_pkg "$base/pkg-ok.json" '{}'
done
pass 'every accepted-set schema deviation (envelope id, a missing identity slot, a duplicate digest, an invalid mechanism id) is refused E_CONFIG, paired against the accepted control'

/bin/chmod 700 "$store_root"
expect_refused 'E_STORE: store root mode 0700, not 0750' E_STORE "$base/pkg-ok.json"
/bin/chmod 750 "$store_root"
pass 'a store root whose mode is not exactly 0750 is refused E_STORE, paired against the accepted control'

for mode in missing_record bad_order bad_magic truncated oversize; do
  build_pkg "$base/pkg-bad.json" "{\"frame\":\"$mode\"}"
  expect_refused "E_PACKAGE: frame $mode" E_PACKAGE "$base/pkg-bad.json"
done
build_pkg "$base/pkg-bad.json" '{"raw_request":{"not":"canonical shape at all"}}'
expect_refused 'E_PACKAGE: request fails its own shape' E_PACKAGE "$base/pkg-bad.json"
build_pkg "$base/pkg-bad.json" '{"delete":["subject.incident_sha256"]}'
expect_refused 'E_PACKAGE: request missing a required field' E_PACKAGE "$base/pkg-bad.json"
build_pkg "$base/pkg-bad.json" '{"set":{"nonce":"nothex"}}'
expect_refused 'E_PACKAGE: request nonce not 64 lowercase hex' E_PACKAGE "$base/pkg-bad.json"
build_pkg "$base/pkg-bad.json" '{"set":{"subject.source.commit_id":null}}'
expect_refused 'E_PACKAGE: subject.source.commit_id is null' E_PACKAGE "$base/pkg-bad.json"
build_pkg "$base/pkg-bad.json" "{\"set\":{\"subject.source.tree_id\":\"$(python3 -c 'print("a"*39)')\"}}"
expect_refused 'E_PACKAGE: subject.source.tree_id is 39 hex chars, not the 40 sha1 selects' E_PACKAGE "$base/pkg-bad.json"
build_pkg "$base/pkg-bad.json" "{\"set\":{\"subject.candidate.commit_id\":\"$(python3 -c 'print("a"*41)')\"}}"
expect_refused 'E_PACKAGE: subject.candidate.commit_id is 41 hex chars, not the 40 sha1 selects' E_PACKAGE "$base/pkg-bad.json"
build_pkg "$base/pkg-bad.json" '{"set":{"attempt.attempt_number":true}}'
expect_refused 'E_PACKAGE: attempt_number is a bool, not an int (Python bool is an int subclass)' E_PACKAGE "$base/pkg-bad.json"
pass 'every frame and request-shape deviation (including a null or wrong-length source/candidate commit_id or tree_id, and a boolean attempt_number) is refused E_PACKAGE, paired against the accepted control'

build_pkg "$base/pkg-bad.json" '{"raw_request_depth":2000}'
expect_refused 'E_PACKAGE: request.json nested 2,000 levels deep is bounded, not a RecursionError traceback' E_PACKAGE "$base/pkg-bad.json"
pass 'a request.json with far more nesting than the 32-level cap is refused E_PACKAGE (the pre-parse bounded_json_nesting scan), never a RecursionError exiting 1'

build_pkg "$base/pkg-incident.json" '{"incident_bytes":262144}'
expect_admitted 'an incident.json record at exactly the 262,144-byte cap' "$base/pkg-incident.json"
build_pkg "$base/pkg-incident.json" '{"attempt_id":"attempt.fixture-incident-over","incident_bytes":262145}'
expect_refused 'E_PACKAGE: an incident.json record one byte over the 262,144-byte cap' E_PACKAGE "$base/pkg-incident.json"
pass 'the incident.json record size boundary (262,144 bytes accepted, 262,145 refused E_PACKAGE) holds exactly at the cap'

build_pkg "$base/pkg-bad.json" '{"store_id":"store.wrong"}'
expect_refused 'E_STORE_ID: request store_id differs from the configuration' E_STORE_ID "$base/pkg-bad.json"
pass 'a request store_id differing from the configuration is refused E_STORE_ID, paired against the accepted control'

build_pkg "$base/pkg-reuse.json" '{"attempt_id":"attempt.fixture-reuse","nonce":"1111111111111111111111111111111111111111111111111111111111111111"}'
expect_admitted 'first use of a nonce' "$base/pkg-reuse.json"
build_pkg "$base/pkg-reuse2.json" '{"attempt_id":"attempt.fixture-reuse-2","nonce":"1111111111111111111111111111111111111111111111111111111111111111"}'
expect_refused 'E_NONCE_REUSED: the same nonce bytes again' E_NONCE_REUSED "$base/pkg-reuse2.json"
pass 'reusing the same nonce is refused E_NONCE_REUSED even for a different attempt id, paired against the first (accepted) use'

build_pkg "$base/pkg-again.json" '{"attempt_id":"attempt.fixture-reuse","nonce":"2222222222222222222222222222222222222222222222222222222222222222"}'
expect_refused 'E_ATTEMPT_EXISTS: the attempt id already has a store entry' E_ATTEMPT_EXISTS "$base/pkg-again.json"
pass 'an attempt id that already exists in the store is refused E_ATTEMPT_EXISTS, nothing touched, paired against its first (accepted) use'

# =============================================================================
# R10.2/R10.3: store modes, owner, group, link counts and the receipt
# =============================================================================
"$python" -c "
import os, sys, json
root = sys.argv[1]; uid = int(sys.argv[2]); gid = int(sys.argv[3])
assert os.path.isdir(root), root
checked = 0
for dirpath, dirnames, filenames in os.walk(root):
    for name in dirnames:
        st = os.lstat(os.path.join(dirpath, name))
        assert st.st_mode & 0o7777 == 0o750, (name, oct(st.st_mode))
        assert st.st_uid == uid and st.st_gid == gid, name
        checked += 1
    for name in filenames:
        st = os.lstat(os.path.join(dirpath, name))
        assert st.st_mode & 0o7777 == 0o440, (name, oct(st.st_mode))
        assert st.st_uid == uid and st.st_gid == gid, name
        assert st.st_nlink == 1, name
        checked += 1
assert checked > 0, 'nothing under ' + root
print('ok')
" "$store_root/attempt.fixture-reuse" "$(id -u)" "$(id -g)" >/dev/null
pass 'every store directory is 0750 and every store file is 0440, owned by principal_uid:consumer_gid, with link count 1'

# R8.3: the receipt's payload.evidence_manifest_sha256 must be the digest of
# the exact bytes written to payload/evidence-manifest.json, not a
# separately-hashed empty string.
receipt_manifest_sha256=$("$jq_bin" -r '.body.payload.evidence_manifest_sha256' \
  "$store_root/attempt.fixture-reuse/receipt.json")
stored_manifest_sha256=$(sha_file "$store_root/attempt.fixture-reuse/payload/evidence-manifest.json")
[ "$receipt_manifest_sha256" = "$stored_manifest_sha256" ] ||
  fail "receipt payload.evidence_manifest_sha256 ($receipt_manifest_sha256) does not match the stored manifest's own digest ($stored_manifest_sha256)"
[ "$receipt_manifest_sha256" != "$(sha_file /dev/null)" ] ||
  fail 'receipt payload.evidence_manifest_sha256 is the empty-string digest, not the stored (nonempty, canonical) manifest'
pass "the receipt's payload.evidence_manifest_sha256 equals the stored evidence-manifest.json's own digest, not an empty-string placeholder"

receipt_verdict=$("$jq_bin" -r '.body.outcome.verdict' "$store_root/attempt.fixture-reuse/receipt.json")
receipt_admission=$("$jq_bin" -r '.body.lifecycle.admission' "$store_root/attempt.fixture-reuse/receipt.json")
receipt_runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/attempt.fixture-reuse/receipt.json")
[ "$receipt_admission" = admitted ] && [ "$receipt_runtime" = error ] && [ "$receipt_verdict" = failed ] ||
  fail 'stub receipt: expected admission admitted, runtime error, verdict failed'
pass 'the stub receipt for an admitted attempt records lifecycle.admission admitted, runtime error (the runtime never started) and outcome failed'

# =============================================================================
# the shipped enforcement/v1/check-sandbox-receipt.sh accepts the receipt's
# own shape (R3/R10.3), even though it is refused against the shipped
# (empty) accepted set, matching R10.2's documented behavior exactly.
# =============================================================================
# Built first (and fed back into the request's control.sandbox_evaluation_sha256
# below) so the receipt's control block matches this file's own digest, the
# real shipped control/v1 fixed-file digests, and a "satisfied" evaluation
# shape: everything the shipped checker's is_control_mismatch/
# is_evaluation_not_satisfied require, so the cross-check below is refused
# for exactly the three shipped-empty-accepted-set reasons, nothing else.
"$python" -c "
import json
h = {'id': 'sandbox.evaluation.fixture', 'kind': 'sandbox_policy_evaluation', 'schema_version': 1,
     'body': {'verdict': 'satisfied',
       'policy_ref': {'sha256': '$real_policy_sha'},
       'decision_ref': {'sha256': '$real_decision_sha'},
       'policy_set': {'sha256': '$real_policy_set_sha'}}}
open('$base/evaluation.json', 'w').write(json.dumps(h, sort_keys=True, separators=(',', ':')) + chr(10))
"
evaluation_sha256=$(sha_file "$base/evaluation.json")
build_pkg "$base/pkg-check.json" '{"attempt_id":"attempt.fixture-check","nonce":"3333333333333333333333333333333333333333333333333333333333333333","evaluation_sha256":"'"$evaluation_sha256"'","expectation_out":"'"$base/expectation.json"'"}'
expect_admitted 'the attempt used for the shipped-checker cross-check' "$base/pkg-check.json"
check_out=$("$jq_bin" -c . <(PATH="$jq_dir:$PATH" bash "$root/enforcement/v1/check-sandbox-receipt.sh" check \
  "$store_root/attempt.fixture-check/receipt.json" "$base/expectation.json" "$base/evaluation.json"))
[ "$("$jq_bin" -r '.body.check_verdict' <<<"$check_out")" = refused ] || fail 'shipped checker: expected check_verdict refused'
reasons=$("$jq_bin" -c -S '.body.reason_ids' <<<"$check_out")
[ "$reasons" = '["receipt.environment-unlisted","receipt.identity-unaccepted","receipt.stale"]' ] ||
  fail "shipped checker: expected the three shipped-empty-set reasons, got $reasons"
pass 'the shipped check-sandbox-receipt.sh accepts the receipt and expectation shape and refuses it only with the three shipped-empty-accepted-set reasons (receipt.environment-unlisted, receipt.identity-unaccepted, receipt.stale), never receipt.malformed'

# R2.3/store-write descriptor pinning: renaming store_root aside and
# symlinking a replacement in between admission and the write must not
# redirect the write. Simulated via the test-only YSTACK_TEST_SWAP_STORE_
# ANCESTOR hook (no real concurrency in a single synchronous launch).
build_tree 0
build_pkg "$base/pkg-swap.json" '{"attempt_id":"attempt.fixture-swap"}'
/bin/mkdir -m 0700 "$store_root.ystack-test-swapped"
status=0
YSTACK_TEST_SWAP_STORE_ANCESTOR=1 run_launch "$base/pkg-swap.json" || status=$?
[ "$status" -eq 0 ] || fail "store swap: expected exit 0, got $status ($(cat "$base/err"))"
[ -e "$store_root.ystack-test-orig/attempt.fixture-swap/receipt.json" ] ||
  fail 'store swap: the write did not land in the originally-validated directory'
[ ! -e "$store_root.ystack-test-swapped/attempt.fixture-swap" ] ||
  fail 'store swap: the write followed the swapped-in path instead of the held-open descriptor'
pass 'a store_root renamed aside and replaced with a symlink between admission and the write (an ancestor swap mid-run) does not redirect the write: it still lands in the originally-validated directory, through the descriptor write_store holds open'

/usr/bin/printf 'total assertions: %s\n' "$passes" >&2
