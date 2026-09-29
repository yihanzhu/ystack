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

def sha(b):
    return hashlib.sha256(b).hexdigest()

ENV_ID = "env.local-macos-fixture"
TARGET_REPO = "target.fixture"
KERNEL_REQUIRED_OPTIONS = (
    "CONFIG_PCI", "CONFIG_PCI_HOST_GENERIC", "CONFIG_VIRTIO", "CONFIG_VIRTIO_PCI",
    "CONFIG_VIRTIO_BLK", "CONFIG_BLK_DEV_INITRD", "CONFIG_DEVTMPFS", "CONFIG_PROC_FS",
    "CONFIG_SYSFS", "CONFIG_TMPFS", "CONFIG_CGROUPS", "CONFIG_MEMCG",
    "CONFIG_CGROUP_PIDS", "CONFIG_CGROUP_SCHED", "CONFIG_FAIR_GROUP_SCHED",
    "CONFIG_CFS_BANDWIDTH", "CONFIG_PID_NS", "CONFIG_NET_NS", "CONFIG_SECCOMP",
    "CONFIG_SECCOMP_FILTER", "CONFIG_SECURITY_LANDLOCK", "CONFIG_FANOTIFY",
    "CONFIG_FANOTIFY_ACCESS_PERMISSIONS",
)

def main():
    base, src, work_root, placeholder = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
    shutil.rmtree(base, ignore_errors=True)
    os.makedirs(base, mode=0o755)
    install_dir = os.path.join(base, "install")
    os.makedirs(install_dir, mode=0o755)
    shutil.copy(src, os.path.join(install_dir, "host-supervisor.py"))
    os.chmod(os.path.join(install_dir, "host-supervisor.py"), 0o555)

    identity_keys = ["guest_init", "guest_kernel", "guest_kernel_config", "guest_supervisor",
                     "host_runtime", "host_supervisor", "image", "toolchain", "verifier",
                     "vm_service", "dyld_cache"]
    identities_dir = os.path.join(base, "identities")
    os.makedirs(identities_dir, mode=0o755)
    identity_paths = {}
    kernel_config_text = ("\n".join(o + "=y" for o in KERNEL_REQUIRED_OPTIONS) + "\nCONFIG_HZ_250=y\n")
    for k in identity_keys:
        p = os.path.join(identities_dir, k)
        content = kernel_config_text.encode() if k == "guest_kernel_config" else b"synthetic-" + k.encode()
        open(p, "wb").write(content)
        os.chmod(p, 0o444)
        identity_paths[k] = p

    installed_keys = ["accepted_set", "control_decision", "control_policy", "control_policy_set",
                       "evaluator_driver", "evaluator_program", "registry"]
    installed_dir = os.path.join(base, "installed")
    os.makedirs(installed_dir, mode=0o755)
    installed_files = {}
    for k in installed_keys:
        p = os.path.join(installed_dir, k)
        if k != "registry":
            open(p, "wb").write(b"synthetic-" + k.encode())
        installed_files[k] = p

    registry_entry = {"description": "fixture", "environment_id": ENV_ID, "evidence_scope": "fixtures-only",
                       "proof_state": "unproven", "source_root_commit": "a" * 40,
                       "target_repository_id": TARGET_REPO}
    registry_doc = {"body": {"activation_state": "inactive", "environments": [registry_entry],
                              "registry_version": "v1"},
                     "id": "shadow.environments.v1", "kind": "shadow_environment_registry", "schema_version": 1}
    open(installed_files["registry"], "wb").write(canon(registry_doc))

    vfkit_path = os.path.join(base, "vfkit")
    open(vfkit_path, "wb").write(b"fake-vfkit")
    os.chmod(vfkit_path, 0o555)
    driver_path = os.path.join(base, "driver")
    open(driver_path, "wb").write(b"fake-driver")
    os.chmod(driver_path, 0o555)

    # R2.3's composite slots: same formula as host-supervisor.py's own
    # measure_identities, over these same fixture bytes -- everything else
    # (the 6 simple slots) stays a raw sha256 of its installed bytes.
    KERNEL_CONFIG_DEVICES = ["virtio-blk,readonly", "virtio-blk"]
    host_runtime_digest = sha(canon({"files": [
        {"path": "vfkit", "sha256": sha(open(vfkit_path, "rb").read())},
        {"path": "driver", "sha256": sha(open(driver_path, "rb").read())},
        {"path": "vm_service", "sha256": sha(open(identity_paths["vm_service"], "rb").read())},
        {"path": "dyld_cache", "sha256": sha(open(identity_paths["dyld_cache"], "rb").read())}]}))
    guest_kernel_config_digest = sha(canon({
        "command_line": "console= quiet lsm=landlock rdinit=/init", "cpu_count": 1,
        "devices": KERNEL_CONFIG_DEVICES,
        "kernel_build_config_sha256": sha(kernel_config_text.encode()),
        "memory_bytes": 536870912}))

    measured = {k: sha(open(identity_paths[k], "rb").read()) for k in identity_keys
                if k not in ("host_runtime", "guest_kernel_config", "host_supervisor")}
    measured["host_runtime"] = host_runtime_digest
    measured["guest_kernel_config"] = guest_kernel_config_digest
    measured["verification_instructions"] = sha(b"instr")
    accepted_keys = ["guest_init", "guest_kernel", "guest_kernel_config", "guest_supervisor",
                      "host_runtime", "host_supervisor", "image", "toolchain", "verifier"]
    digest = "1" * 64 if placeholder else None  # "1"*64 is ALL_ONES

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

    # host_supervisor's composite needs the config file's own bytes (as
    # written above), the installed host-supervisor.py and the interpreter
    # that will run it -- sys.executable here, since build_tree.py and
    # run_launch are invoked with the same "$python".
    measured["host_supervisor"] = sha(canon({
        "config_sha256": sha(open(config_path, "rb").read()),
        "files": [{"path": "host-supervisor.py",
                   "sha256": sha(open(os.path.join(install_dir, "host-supervisor.py"), "rb").read())}],
        "python_sha256": sha(open(sys.executable, "rb").read())}))

    digest = "1" * 64 if placeholder else None  # "1"*64 is ALL_ONES
    accepted_doc = {"body": {"activation_state": "inactive", "set_version": "v1", "environments": [
        {"environment_id": ENV_ID, "scratch_bytes": 16777216,
         "identities": {k: [digest or measured[k]] for k in accepted_keys + ["verification_instructions"]},
         "mechanisms": {r: ["mechanism.fixture"] for r in
                        ["cpu_time_ms", "memory_bytes", "output_bytes", "process_count",
                         "scratch_bytes", "wall_time_ms"]}}]},
        "id": "sandbox.accepted-identities.v1", "kind": "sandbox_accepted_identity_set", "schema_version": 1}
    open(installed_files["accepted_set"], "wb").write(canon(accepted_doc))
    for k in installed_keys:
        os.chmod(installed_files[k], 0o444)

    print(json.dumps({"install_dir": install_dir, "store_root": store_root,
                       "config_path": config_path, "accepted_set": installed_files["accepted_set"],
                       "driver_path": driver_path, "vfkit_path": vfkit_path,
                       "registry_path": installed_files["registry"],
                       "guest_kernel_config_path": identity_paths["guest_kernel_config"],
                       "toolchain_path": identity_paths["toolchain"],
                       "vm_service_path": identity_paths["vm_service"],
                       "dyld_cache_path": identity_paths["dyld_cache"],
                       "work_root": work_root, "installed_files": installed_files}))

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

ENV_ID = "env.local-macos-fixture"
TARGET_REPO = "target.fixture"

def main():
    supervisor_src, out_path = sys.argv[1], sys.argv[2]
    patch = json.load(sys.stdin)
    spec = importlib.util.spec_from_file_location("hs", supervisor_src)
    hs = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hs)
    sha = hs.sha256_hex
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

    registry_entry = {"description": "fixture", "environment_id": ENV_ID, "evidence_scope": "fixtures-only",
                       "proof_state": "unproven", "source_root_commit": "a" * 40,
                       "target_repository_id": TARGET_REPO}

    record_source = {"repository_id": TARGET_REPO, "hash_algorithm": "sha1",
                      "commit_id": "a" * 40, "tree_id": "b" * 40}
    record_candidate = {"hash_algorithm": "sha1", "commit_id": "c" * 40, "tree_id": "d" * 40,
                        "parent_commit_id": "e" * 40, "outcome": "no-change"}
    candidate_name = patch.get("candidate_name", "README.md")
    candidate_content = patch.get("candidate_content", "hello").encode()
    manifest_entries = [{"path": candidate_name, "kind": "file", "git_mode": "100644", "mode": "0400",
                          "blob_oid": "f" * 40, "size_bytes": len(candidate_content),
                          "sha256": sha(candidate_content)}]
    manifest_doc = {"schema_version": 1, "kind": "candidate_content_manifest", "hash_algorithm": "sha256",
                     "entries": manifest_entries, "file_count": 1, "directory_count": 0,
                     "total_file_bytes": len(candidate_content)}
    for path, value in patch.get("manifest_set", {}).items():
        deep_set(manifest_doc, path, value)
    manifest_bytes = hs.canonical(manifest_doc)

    record_doc = {"schema_version": 1, "kind": "candidate_content_preparation", "status": "completed",
                  "authority": "none", "qualification": "unavailable", "input_sha256": "0" * 64,
                  "response_sha256": "0" * 64, "stage_result_sha256": "0" * 64, "receipt_sha256": "0" * 64,
                  "request_ref": "r", "resolved_profile_ref": "p",
                  "attempt": {"attempt_id": patch.get("attempt_id", "attempt.fixture-0001"),
                              "attempt_number": patch.get("attempt_number", 1)},
                  "source": dict(record_source), "candidate": dict(record_candidate),
                  "manifest_sha256": sha(manifest_bytes), "storage_observation_sha256": "0" * 64,
                  "producer": {"role": "fixture"},
                  "ownership": {"state": "local-preparation-complete", "immutable": False,
                                "authenticated_receipt": False, "supervisor_handoff": "required"}}
    for path, value in patch.get("record_set", {}).items():
        deep_set(record_doc, path, value)
    record_bytes = hs.canonical(record_doc)

    incident_body = {"deploy_authority": "none",
                      "failing_check": {"check_id": "check.fixture", "kind": "named-check"},
                      "git_revision_ref": {"repository_id": TARGET_REPO, "hash_algorithm": "sha1",
                                           "commit_id": "a" * 40},
                      "observed_at": "2026-01-01T00:00:00Z", "observed_symptom": "s",
                      "reporter_actor_ref": "reporter.fixture", "target_repository_id": TARGET_REPO}
    for path, value in patch.get("incident_set", {}).items():
        deep_set(incident_body, path, value)
    incident_doc = {"body": incident_body, "id": "shadow.incident.fixture",
                     "kind": "shadow_incident_record", "schema_version": 1}
    for path, value in patch.get("incident_doc_set", {}).items():
        deep_set(incident_doc, path, value)
    for path in patch.get("incident_doc_delete", []):
        deep_set(incident_doc, path, _DELETE)
    incident_bytes = hs.canonical(incident_doc)

    # The general baseline's "installed" control files (build_tree.py) are
    # arbitrary synthetic bytes; host-side control-mismatch is checked
    # against them, so the default control digests here match THAT, not
    # the real shipped files -- only the shipped-checker cross-check test
    # (control_real=true) copies the real files over the installed ones
    # first and needs the real digests here to match.
    if patch.get("control_real"):
        policy_sha, decision_sha, policy_set_sha = real_policy_sha, real_decision_sha, real_policy_set_sha
        driver_sha, program_sha = real_driver_sha, real_program_sha
    else:
        policy_sha, decision_sha, policy_set_sha = (sha(b"synthetic-control_policy"),
            sha(b"synthetic-control_decision"), sha(b"synthetic-control_policy_set"))
        driver_sha, program_sha = sha(b"synthetic-evaluator_driver"), sha(b"synthetic-evaluator_program")

    evaluation_doc = {"id": "sandbox.evaluation.fixture", "kind": "sandbox_policy_evaluation",
                       "schema_version": 1,
                       "body": {"verdict": "satisfied", "policy_ref": {"sha256": policy_sha},
                                 "decision_ref": {"sha256": decision_sha},
                                 "policy_set": {"sha256": policy_set_sha}}}
    for path, value in patch.get("evaluation_set", {}).items():
        deep_set(evaluation_doc, path, value)
    evaluation_bytes = hs.canonical(evaluation_doc)

    # Malformed-phase-B-document fixtures (R4.2's parsers must yield an
    # invalid-document result, never an uncaught exception, for any of
    # these): unparseable, an embedded NaN, or a JSON-legal lone surrogate
    # escape that canonical()'s own utf-8 encode cannot represent.
    if "raw_manifest" in patch:
        manifest_bytes = patch["raw_manifest"].encode()
    if "raw_incident" in patch:
        incident_bytes = patch["raw_incident"].encode()

    instruction_bytes = patch.get("instruction", "instr").encode()

    control = {"decision_sha256": decision_sha, "evaluator_driver_sha256": driver_sha,
               "evaluator_program_sha256": program_sha, "policy_sha256": policy_sha,
               "policy_set_sha256": policy_set_sha,
               "sandbox_evaluation_sha256": sha(evaluation_bytes)}
    subject = {"environment_id": ENV_ID, "environment_entry_sha256": sha(hs.canonical(registry_entry)),
               "target_repository_id": TARGET_REPO, "source": dict(record_source),
               "candidate": {"preparation_record_sha256": sha(record_bytes),
                             "manifest_sha256": sha(manifest_bytes),
                             "commit_id": record_candidate["commit_id"], "tree_id": record_candidate["tree_id"]},
               "incident_sha256": sha(incident_bytes)}
    body = {"attempt": {"attempt_id": patch.get("attempt_id", "attempt.fixture-0001"),
                        "attempt_number": patch.get("attempt_number", 1)},
            "control": control, "instruction_sha256": sha(instruction_bytes),
            "nonce": patch.get("nonce", "ab" * 32),
            "store_id": patch.get("store_id", "store.fixture.v1"), "subject": subject}
    for path, value in patch.get("set", {}).items():
        deep_set(body, path, value)
    for path in patch.get("delete", []):
        deep_set(body, path, _DELETE)
    request_doc = {"body": body, "id": "sandbox.launch-request.fixture",
                   "kind": "sandbox_launch_request", "schema_version": patch.get("doc_schema_version", 1)}
    if "raw_request_depth" in patch:
        n = patch["raw_request_depth"]  # built flat, so json.dumps never has to recurse either
        request_bytes = b"[" * n + b"1" + b"]" * n
    elif "raw_request" in patch:
        request_bytes = json.dumps(patch["raw_request"], ensure_ascii=False).encode()
    else:
        request_bytes = hs.canonical(request_doc)
    mode = patch.get("frame", "ok")
    if "incident_bytes" in patch:
        incident_bytes = b"i" * patch["incident_bytes"]
    candidates = patch.get("candidates", [candidate_content.decode("latin1")])
    candidate_records = [(("candidate/%05d" % i).encode(), c.encode("latin1") if isinstance(c, str) else c)
                          for i, c in enumerate(candidates)]
    records = ([(b"request.json", request_bytes), (b"evaluation.json", evaluation_bytes),
                (b"incident.json", incident_bytes), (b"record.json", record_bytes),
                (b"manifest.json", manifest_bytes), (b"instruction", instruction_bytes)]
               + candidate_records)
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
    if "evaluation_out" in patch:
        open(patch["evaluation_out"], "wb").write(evaluation_bytes)

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
  vfkit_path=$(printf '%s' "$info" | "$jq_bin" -r .vfkit_path)
  registry_path=$(printf '%s' "$info" | "$jq_bin" -r .registry_path)
  guest_kernel_config_path=$(printf '%s' "$info" | "$jq_bin" -r .guest_kernel_config_path)
  toolchain_path=$(printf '%s' "$info" | "$jq_bin" -r .toolchain_path)
  vm_service_path=$(printf '%s' "$info" | "$jq_bin" -r .vm_service_path)
  dyld_cache_path=$(printf '%s' "$info" | "$jq_bin" -r .dyld_cache_path)
  installed_control_policy=$(printf '%s' "$info" | "$jq_bin" -r .installed_files.control_policy)
  installed_control_decision=$(printf '%s' "$info" | "$jq_bin" -r .installed_files.control_decision)
  installed_control_policy_set=$(printf '%s' "$info" | "$jq_bin" -r .installed_files.control_policy_set)
  installed_evaluator_driver=$(printf '%s' "$info" | "$jq_bin" -r .installed_files.evaluator_driver)
  installed_evaluator_program=$(printf '%s' "$info" | "$jq_bin" -r .installed_files.evaluator_program)
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
expect_phase_b_refused() { # expect_phase_b_refused <desc> <attempt_id> <pkg-file> <expected-reasons-json>
  local desc=$1 attempt_id=$2 pkgfile=$3 expected=$4 status=0 admission reasons
  run_launch "$pkgfile" || status=$?
  [ "$status" -eq 0 ] || fail "$desc: expected exit 0 (a refusal receipt, not a phase A error), got $status ($(cat "$base/err"))"
  [ ! -s "$base/out" ] || fail "$desc: stdout must be empty"
  [ ! -s "$base/err" ] || fail "$desc: stderr must be empty"
  admission=$("$jq_bin" -r '.body.lifecycle.admission' "$store_root/$attempt_id/receipt.json")
  [ "$admission" = refused ] || fail "$desc: expected lifecycle.admission refused, got $admission"
  reasons=$("$jq_bin" -c -S '.reason_ids' "$store_root/$attempt_id/payload/refusal.json")
  [ "$reasons" = "$expected" ] || fail "$desc: expected reason_ids $expected, got $reasons"
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
  # Multi-entry ACL regression (P1): the wrong ACL_NEXT_ENTRY never
  # advanced past the first entry, so a second entry went uninspected.
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

# runtime.driver (P2), like vfkit, must be walked: world-writable refuses.
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

# Same class as the attempt_number bug: every integer field must reject
# bool via is_int (Python's True == 1); expect_refused's own snapshot
# proves no store write happens either.
build_pkg "$base/pkg-bool.json" '{"doc_schema_version":true}'
expect_refused 'E_PACKAGE: request.json schema_version is true, not 1' E_PACKAGE "$base/pkg-bool.json"
build_pkg "$base/pkg-bool.json" '{"attempt_number":true}'
expect_refused 'E_PACKAGE: attempt.attempt_number is true, not 1' E_PACKAGE "$base/pkg-bool.json"
config_bool_filters=('.schema_version = true' '.body.principal_uid = true' '.body.consumer_gid = true')
for filt in "${config_bool_filters[@]}"; do
  "$jq_bin" -c "$filt" "$config_path" > "$base/bad-config.json"
  /bin/chmod 644 "$config_path"; /bin/cp "$base/bad-config.json" "$config_path"; /bin/chmod 444 "$config_path"
  build_pkg "$base/pkg-ok.json" '{}'
  expect_refused "E_CONFIG: host-config.json ($filt) set to true" E_CONFIG "$base/pkg-ok.json"
  build_tree 0; build_pkg "$base/pkg-ok.json" '{}'
done
accepted_bool_filters=('.schema_version = true' '.body.environments[0].scratch_bytes = true')
for filt in "${accepted_bool_filters[@]}"; do
  mutate_accepted_set "$filt"
  build_pkg "$base/pkg-ok.json" '{}'
  expect_refused "E_CONFIG: accepted-set ($filt) set to true" E_CONFIG "$base/pkg-ok.json"
  build_tree 0; build_pkg "$base/pkg-ok.json" '{}'
done
pass 'every integer field the parsers check (request schema_version and attempt_number; host-config.json schema_version, principal_uid, consumer_gid; the accepted set schema_version and scratch_bytes) rejects true (a bool, not an int) with the correct phase A code and no store write'

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

# R9.3: the frozen copies (R5.1) an admitted attempt made are its only
# work_root storage at this stage (no runtime exists before PR 5) -- they
# must be removed and the removal verified before teardown can honestly
# claim storage_destroyed: true.
[ ! -e "$work_root/attempt.fixture-reuse/frozen" ] ||
  fail 'admitted attempt: frozen copies were not removed before storage_destroyed: true'
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/attempt.fixture-reuse/receipt.json")
teardown_destroyed=$("$jq_bin" -r '.body.teardown.storage_destroyed' "$store_root/attempt.fixture-reuse/receipt.json")
[ "$teardown_state" = confirmed ] && [ "$teardown_destroyed" = true ] ||
  fail 'admitted attempt: expected teardown.state confirmed and storage_destroyed true'
pass "an admitted attempt's frozen copies are removed and the removal verified before teardown.state confirmed / storage_destroyed: true"

build_pkg "$base/pkg-td.json" '{"attempt_id":"attempt.fixture-teardown-fail","nonce":"'"$(printf '%064d' 200)"'"}'
status=0
YSTACK_TEST_TEARDOWN_FAIL=1 run_launch "$base/pkg-td.json" || status=$?
[ "$status" -eq 0 ] || fail "teardown failure hook: expected exit 0, got $status ($(cat "$base/err"))"
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/attempt.fixture-teardown-fail/receipt.json")
teardown_destroyed=$("$jq_bin" -r '.body.teardown.storage_destroyed' "$store_root/attempt.fixture-teardown-fail/receipt.json")
outcome_reasons=$("$jq_bin" -c -S '.body.outcome.reason_ids' "$store_root/attempt.fixture-teardown-fail/receipt.json")
[ "$teardown_state" = failed ] && [ "$teardown_destroyed" = false ] ||
  fail 'teardown failure hook: expected teardown.state failed and storage_destroyed false'
printf '%s' "$outcome_reasons" | "$jq_bin" -e 'index("failure.teardown")' >/dev/null ||
  fail "teardown failure hook: expected failure.teardown in outcome.reason_ids, got $outcome_reasons"
pass 'a simulated frozen-copy removal failure (the test-only YSTACK_TEST_TEARDOWN_FAIL hook) is reported honestly: teardown.state failed, storage_destroyed false, failure.teardown in outcome'
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'

# =============================================================================
# the shipped enforcement/v1/check-sandbox-receipt.sh accepts the receipt's
# own shape (R3/R10.3), even though it is refused against the shipped
# (empty) accepted set, matching R10.2's documented behavior exactly.
# =============================================================================
# The installed control files are copied to the real shipped bytes (so
# host-side control-mismatch also passes) and control_real=true makes
# build_pkg use the same real digests -- everything the shipped checker's
# is_control_mismatch/is_evaluation_not_satisfied require, so the
# cross-check below is refused for exactly the three shipped-empty-
# accepted-set reasons, nothing else.
/bin/chmod 644 "$installed_control_policy" "$installed_control_decision" "$installed_control_policy_set" \
  "$installed_evaluator_driver" "$installed_evaluator_program"
/bin/cp "$root/control/v1/sandbox-policy.json" "$installed_control_policy"
/bin/cp "$root/control/v1/sandbox-decision.json" "$installed_control_decision"
/bin/cp "$root/control/v1/control-policy-set.json" "$installed_control_policy_set"
/bin/cp "$root/control/v1/evaluate-sandbox.sh" "$installed_evaluator_driver"
/bin/cp "$root/control/v1/sandbox.jq" "$installed_evaluator_program"
/bin/chmod 444 "$installed_control_policy" "$installed_control_decision" "$installed_control_policy_set" \
  "$installed_evaluator_driver" "$installed_evaluator_program"
build_pkg "$base/pkg-check.json" '{"attempt_id":"attempt.fixture-check","nonce":"3333333333333333333333333333333333333333333333333333333333333333","control_real":true,"expectation_out":"'"$base/expectation.json"'","evaluation_out":"'"$base/evaluation.json"'"}'
expect_admitted 'the attempt used for the shipped-checker cross-check' "$base/pkg-check.json"
check_out=$("$jq_bin" -c . <(PATH="$jq_dir:$PATH" bash "$root/enforcement/v1/check-sandbox-receipt.sh" check \
  "$store_root/attempt.fixture-check/receipt.json" "$base/expectation.json" "$base/evaluation.json"))
[ "$("$jq_bin" -r '.body.check_verdict' <<<"$check_out")" = refused ] || fail 'shipped checker: expected check_verdict refused'
reasons=$("$jq_bin" -c -S '.body.reason_ids' <<<"$check_out")
[ "$reasons" = '["receipt.environment-unlisted","receipt.identity-unaccepted","receipt.stale"]' ] ||
  fail "shipped checker: expected the three shipped-empty-set reasons, got $reasons"
pass 'the shipped check-sandbox-receipt.sh accepts the receipt and expectation shape and refuses it only with the three shipped-empty-accepted-set reasons (receipt.environment-unlisted, receipt.identity-unaccepted, receipt.stale), never receipt.malformed'

# =============================================================================
# R4.2 phase B: every one of the twelve subject and six control leaf fields
# mutated alone, artifacts intact, refused with its own reason and never
# admitted (R15.1). Each case gets its own attempt id/nonce so none of them
# need a tree rebuild in between; a hex value is always built by length so
# none is miscounted.
# =============================================================================
build_tree 0
hex64() { python3 -c "print('9' * 64)"; }
hex40() { python3 -c "print('9' * 40)"; }
n=0
phase_b_case() { # phase_b_case <desc> <patch-json-without-braces> <expected-reasons-json>
  n=$((n + 1))
  local desc=$1 extra=$2 expected=$3 attempt_id="attempt.fixture-pb-$n" nonce
  nonce=$(printf '%064d' "$n")
  build_pkg "$base/pkg-pb.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$nonce"'",'"$extra"'}'
  expect_phase_b_refused "$desc" "$attempt_id" "$base/pkg-pb.json" "$expected"
}
MISMATCH='["launch.subject-mismatch"]'
phase_b_case 'subject.environment_id' '"set":{"subject.environment_id":"env.other-fixture"}' \
  '["launch.environment-unlisted"]'
phase_b_case 'subject.environment_entry_sha256' '"set":{"subject.environment_entry_sha256":"'"$(hex64)"'"}' \
  '["launch.environment-unlisted"]'
# Also trips subject-mismatch: the incident's own target_repository_id
# (unchanged) is cross-checked against this same subject field (R4.2).
phase_b_case 'subject.target_repository_id' '"set":{"subject.target_repository_id":"target.other"}' \
  '["launch.environment-unlisted","launch.subject-mismatch"]'
phase_b_case 'subject.source.repository_id' '"set":{"subject.source.repository_id":"target.other"}' "$MISMATCH"
# hash_algorithm is a closed sha1/sha256 pair: changing it alone would break
# phase A's own oid_ok length check, so commit_id/tree_id are re-shaped to
# stay phase-A valid -- record.json still says sha1, so this still reaches
# phase B as one field's mutation, not a shape change.
# parse_request validates candidate.commit_id/tree_id against this SAME
# hash_algorithm too, so they are re-shaped to 64 hex chars right alongside
# source's, purely to stay phase-A valid (record.json still says sha1, so
# subject-mismatch is still what phase B gives).
phase_b_case 'subject.source.hash_algorithm' \
  '"set":{"subject.source.hash_algorithm":"sha256","subject.source.commit_id":"'"$(hex64)"'","subject.source.tree_id":"'"$(hex64)"'","subject.candidate.commit_id":"'"$(hex64)"'","subject.candidate.tree_id":"'"$(hex64)"'"}' \
  "$MISMATCH"
phase_b_case 'subject.source.commit_id' '"set":{"subject.source.commit_id":"'"$(hex40)"'"}' "$MISMATCH"
phase_b_case 'subject.source.tree_id' '"set":{"subject.source.tree_id":"'"$(hex40)"'"}' "$MISMATCH"
phase_b_case 'subject.candidate.preparation_record_sha256' \
  '"set":{"subject.candidate.preparation_record_sha256":"'"$(hex64)"'"}' '["launch.record-mismatch"]'
phase_b_case 'subject.candidate.manifest_sha256' \
  '"set":{"subject.candidate.manifest_sha256":"'"$(hex64)"'"}' '["launch.manifest-mismatch"]'
phase_b_case 'subject.candidate.commit_id' '"set":{"subject.candidate.commit_id":"'"$(hex40)"'"}' "$MISMATCH"
phase_b_case 'subject.candidate.tree_id' '"set":{"subject.candidate.tree_id":"'"$(hex40)"'"}' "$MISMATCH"
phase_b_case 'subject.incident_sha256' '"set":{"subject.incident_sha256":"'"$(hex64)"'"}' "$MISMATCH"
for field in evaluator_driver_sha256 evaluator_program_sha256 sandbox_evaluation_sha256; do
  phase_b_case "control.$field" '"set":{"control.'"$field"'":"'"$(hex64)"'"}' '["launch.control-mismatch"]'
done
# decision/policy/policy_set also feed evaluation_satisfied's own check
# (against this same, now-tampered, request-echoed control block).
for field in decision_sha256 policy_sha256 policy_set_sha256; do
  phase_b_case "control.$field" '"set":{"control.'"$field"'":"'"$(hex64)"'"}' \
    '["launch.control-mismatch","launch.evaluation-not-satisfied"]'
done
pass 'each of the twelve subject and six control leaf fields, mutated alone in the request with every artifact intact, refuses with its own R4.2 reason and is never admitted'

# The installed registry itself missing the environment entry entirely
# (not just a subject-side field mismatch) is the same launch.environment-
# unlisted reason.
/bin/chmod 644 "$registry_path"
"$jq_bin" -c '.body.environments = []' "$registry_path" > "$base/bad-registry.json"
/bin/cp "$base/bad-registry.json" "$registry_path"
/bin/chmod 444 "$registry_path"
build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-pb-noregentry","nonce":"'"$(printf '%064d' 89)"'"}'
expect_phase_b_refused 'the installed registry has no entry at all for the environment' attempt.fixture-pb-noregentry \
  "$base/pkg-pb.json" '["launch.environment-unlisted"]'
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'
pass 'an installed registry with no entry at all for the environment is refused launch.environment-unlisted the same as a subject-side mismatch'

# =============================================================================
# Every remaining phase B reason, alone: evaluation, candidate transport and
# size, instruction binding, identity and kernel-config.
# =============================================================================
build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-pb-eval","nonce":"'"$(printf '%064d' 90)"'","evaluation_set":{"body.verdict":"unsatisfied"}}'
expect_phase_b_refused 'evaluation not satisfied' attempt.fixture-pb-eval "$base/pkg-pb.json" '["launch.evaluation-not-satisfied"]'

build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-pb-cand","nonce":"'"$(printf '%064d' 91)"'","candidates":["not-hello"]}'
expect_phase_b_refused 'candidate bytes differ from the manifest entry' attempt.fixture-pb-cand "$base/pkg-pb.json" \
  '["launch.candidate-mismatch"]'

oversize_content=$(python3 -c "print('x' * (64 * 1024 * 1024 + 1))")
build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-pb-oversize","nonce":"'"$(printf '%064d' 92)"'","candidates":["'"$oversize_content"'"]}'
expect_phase_b_refused 'candidate bytes above the 64 MiB preparation export limit' attempt.fixture-pb-oversize \
  "$base/pkg-pb.json" '["launch.candidate-mismatch","launch.candidate-oversize"]'
unset oversize_content

build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-pb-instrmis","nonce":"'"$(printf '%064d' 93)"'","set":{"instruction_sha256":"'"$(hex64)"'"}}'
expect_phase_b_refused 'instruction_sha256 alone differs from the supplied instruction bytes' attempt.fixture-pb-instrmis \
  "$base/pkg-pb.json" '["launch.instruction-mismatch"]'

build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-pb-instrunacc","nonce":"'"$(printf '%064d' 94)"'","instruction":"unaccepted-instr"}'
expect_phase_b_refused 'the request and the supplied instruction bytes agree, but that digest is not accepted' \
  attempt.fixture-pb-instrunacc "$base/pkg-pb.json" '["launch.instruction-unaccepted"]'

build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-pb-instrok","nonce":"'"$(printf '%064d' 95)"'"}'
expect_admitted 'instruction binding positive control: an accepted instruction, both digests intact' "$base/pkg-pb.json"

# A real read failure on an already-R10.1-validated, held-open fd has no
# natural trigger short of a genuine I/O fault (chmod down to unreadable
# would instead fail the R10.1 walk itself, E_INSTALL_ACL, before phase B
# ever runs) -- simulated via the test-only YSTACK_TEST_IDENTITY_UNREADABLE
# hook instead.
build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-pb-idmiss","nonce":"'"$(printf '%064d' 96)"'"}'
status=0
YSTACK_TEST_IDENTITY_UNREADABLE=guest_init run_launch "$base/pkg-pb.json" || status=$?
[ "$status" -eq 0 ] || fail "identity-missing: expected exit 0, got $status ($(cat "$base/err"))"
[ ! -s "$base/out" ] || fail 'identity-missing: stdout must be empty'
[ ! -s "$base/err" ] || fail 'identity-missing: stderr must be empty'
admission=$("$jq_bin" -r '.body.lifecycle.admission' "$store_root/attempt.fixture-pb-idmiss/receipt.json")
[ "$admission" = refused ] || fail "identity-missing: expected lifecycle.admission refused, got $admission"
reasons=$("$jq_bin" -c -S '.reason_ids' "$store_root/attempt.fixture-pb-idmiss/payload/refusal.json")
[ "$reasons" = '["launch.identity-missing"]' ] || fail "identity-missing: expected launch.identity-missing alone, got $reasons"
pass 'an installed identity that cannot be read (the test-only YSTACK_TEST_IDENTITY_UNREADABLE hook) is refused launch.identity-missing alone'

/bin/chmod 644 "$toolchain_path"
/usr/bin/printf 'different-toolchain' > "$toolchain_path"
/bin/chmod 444 "$toolchain_path"
build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-pb-idunacc","nonce":"'"$(printf '%064d' 97)"'"}'
expect_phase_b_refused 'a readable identity whose measured digest is not in the accepted list' attempt.fixture-pb-idunacc \
  "$base/pkg-pb.json" '["launch.identity-unaccepted"]'
pass 'every remaining R4.2 phase B reason (evaluation not satisfied, candidate content and size, instruction binding both ways, an unreadable identity and an unaccepted identity) is refused alone with its own reason, paired against an accepted instruction/identity control'
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'

# guest_kernel_config's composite is built from a single read of the same
# fd kernel_config_ok also inspects (:945-949's double-read bug): forcing
# it unreadable must yield launch.identity-missing alone, never a crash
# and never a spurious launch.kernel-config alongside it.
build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-pb-kcfgmiss","nonce":"'"$(printf '%064d' 201)"'"}'
status=0
YSTACK_TEST_IDENTITY_UNREADABLE=guest_kernel_config run_launch "$base/pkg-pb.json" || status=$?
[ "$status" -eq 0 ] || fail "kernel-config unreadable: expected exit 0, got $status ($(cat "$base/err"))"
reasons=$("$jq_bin" -c -S '.reason_ids' "$store_root/attempt.fixture-pb-kcfgmiss/payload/refusal.json")
[ "$reasons" = '["launch.identity-missing"]' ] ||
  fail "kernel-config unreadable: expected launch.identity-missing alone, got $reasons"
pass 'an unreadable guest_kernel_config (the same fd kernel_config_ok inspects) is refused launch.identity-missing alone, reusing the single measured read rather than a second one'

# =============================================================================
# Malformed phase B documents (:774-779): a manifest.json that cannot even
# parse, one with an embedded NaN, and one with a JSON-legal lone-surrogate
# escape (canonical()'s own utf-8 encode cannot represent it) must each
# still yield an ordinary refusal receipt -- never an uncaught exception
# escaping past the attempt directory phase B already claimed.
# =============================================================================
i=0
for raw in '{' '{"a":NaN}' '{"a":"\ud800"}'; do
  i=$((i + 1))
  build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-malformed-'"$i"'","nonce":"'"$(printf '%064d' $((210 + i)))"'","raw_manifest":'"$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$raw")"'}'
  status=0
  run_launch "$base/pkg-pb.json" || status=$?
  [ "$status" -eq 0 ] || fail "malformed manifest.json ($raw): expected exit 0 (a refusal receipt), got $status ($(cat "$base/err"))"
  admission=$("$jq_bin" -r '.body.lifecycle.admission' "$store_root/attempt.fixture-malformed-$i/receipt.json")
  [ "$admission" = refused ] || fail "malformed manifest.json ($raw): expected lifecycle.admission refused, got $admission"
  reasons=$("$jq_bin" -c -S '.reason_ids' "$store_root/attempt.fixture-malformed-$i/payload/refusal.json")
  printf '%s' "$reasons" | "$jq_bin" -e 'index("launch.manifest-mismatch")' >/dev/null ||
    fail "malformed manifest.json ($raw): expected launch.manifest-mismatch among $reasons"
done
pass 'a manifest.json that cannot parse, one with an embedded NaN, and one with a JSON-legal lone-surrogate escape each yield an ordinary refusal receipt (launch.manifest-mismatch), never an uncaught exception'
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'

# =============================================================================
# R4.2's incident envelope key set (:793-799): shadow/v1/incident-record.jq:
# 54-59's exact top-level keys, no more, no fewer.
# =============================================================================
build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-incident-extra","nonce":"'"$(printf '%064d' 220)"'","incident_doc_set":{"extra_field":"x"}}'
expect_phase_b_refused 'an incident.json envelope with an extra top-level key' attempt.fixture-incident-extra \
  "$base/pkg-pb.json" '["launch.subject-mismatch"]'
build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-incident-missing","nonce":"'"$(printf '%064d' 221)"'","incident_doc_delete":["schema_version"]}'
expect_phase_b_refused 'an incident.json envelope missing a required top-level key' attempt.fixture-incident-missing \
  "$base/pkg-pb.json" '["launch.subject-mismatch"]'
pass 'an incident.json envelope with an extra or a missing top-level key (beyond exactly body/id/kind/schema_version) is refused launch.subject-mismatch, never accepted as canonical'
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'

# =============================================================================
# R2.3 candidate transport: the three R15.1 tricky paths admit cleanly (the
# manifest's own "path" field never affects the byte-for-byte content check).
# =============================================================================
build_tree 0
name_63x63=$(python3 -c "print('/'.join(['d' * 63] * 63) + '/' + 'f' * 64)")
i=0
for name in "README.md" "$(python3 -c 'print("é" * 40)')" "$name_63x63"; do
  i=$((i + 1))
  build_pkg "$base/pkg-path.json" '{"attempt_id":"attempt.fixture-path-'"$i"'","nonce":"'"$(printf '%064d' $((100 + i)))"'","candidate_name":"'"$name"'"}'
  expect_admitted "candidate transport: a manifest path of ${#name} bytes" "$base/pkg-path.json"
done
pass 'a candidate transported under README.md, a non-ASCII UTF-8 manifest path and a 4,096-byte 64-component path all admit cleanly: the manifest path never affects the byte-for-byte content check'
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'

# =============================================================================
# R2.4: the closed kernel `=y` set refuses each option absent, and the whole
# set with the last one downgraded to `=m` (kernel-config, paired control).
# =============================================================================
kernel_required_options=(
  CONFIG_PCI CONFIG_PCI_HOST_GENERIC CONFIG_VIRTIO CONFIG_VIRTIO_PCI
  CONFIG_VIRTIO_BLK CONFIG_BLK_DEV_INITRD CONFIG_DEVTMPFS CONFIG_PROC_FS
  CONFIG_SYSFS CONFIG_TMPFS CONFIG_CGROUPS CONFIG_MEMCG
  CONFIG_CGROUP_PIDS CONFIG_CGROUP_SCHED CONFIG_FAIR_GROUP_SCHED
  CONFIG_CFS_BANDWIDTH CONFIG_PID_NS CONFIG_NET_NS CONFIG_SECCOMP
  CONFIG_SECCOMP_FILTER CONFIG_SECURITY_LANDLOCK CONFIG_FANOTIFY
  CONFIG_FANOTIFY_ACCESS_PERMISSIONS
)
build_pkg "$base/pkg-ok.json" '{}'
expect_admitted 'kernel-config control: the full =y set admits' "$base/pkg-ok.json"

/bin/chmod 644 "$guest_kernel_config_path"
/usr/bin/printf 'CONFIG_HZ_250=y\n' > "$guest_kernel_config_path"
/bin/chmod 444 "$guest_kernel_config_path"
build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-kcfg-absent","nonce":"'"$(printf '%064d' 110)"'"}'
expect_phase_b_refused 'every required kernel option absent' attempt.fixture-kcfg-absent "$base/pkg-pb.json" \
  '["launch.identity-unaccepted","launch.kernel-config"]'

/bin/chmod 644 "$guest_kernel_config_path"
: > "$guest_kernel_config_path"
last=$((${#kernel_required_options[@]} - 1))
for idx in "${!kernel_required_options[@]}"; do
  if [ "$idx" -eq "$last" ]; then
    printf '%s=m\n' "${kernel_required_options[$idx]}" >> "$guest_kernel_config_path"
  else
    printf '%s=y\n' "${kernel_required_options[$idx]}" >> "$guest_kernel_config_path"
  fi
done
printf 'CONFIG_HZ_250=y\n' >> "$guest_kernel_config_path"
/bin/chmod 444 "$guest_kernel_config_path"
build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-kcfg-m","nonce":"'"$(printf '%064d' 111)"'"}'
expect_phase_b_refused 'the last required kernel option =m instead of =y' attempt.fixture-kcfg-m "$base/pkg-pb.json" \
  '["launch.identity-unaccepted","launch.kernel-config"]'
pass 'the R2.4 closed =y set refuses launch.kernel-config both when every option is absent and when the set is otherwise complete but the last option is =m, paired against the full =y control'
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'

# =============================================================================
# R2.3 host_runtime composite: each of its four constituents (vfkit, driver,
# the framework's VM service executable, the arm64e dyld shared cache),
# changed alone, moves the composite digest away from what was accepted --
# proving it is built from all four validated files, not a stand-in single
# one (spec.md:60-73).
# =============================================================================
i=0
for target in "$vfkit_path" "$driver_path" "$vm_service_path" "$dyld_cache_path"; do
  i=$((i + 1))
  build_tree 0
  /bin/chmod 644 "$target"
  /usr/bin/printf 'tampered-constituent' > "$target"
  /bin/chmod 444 "$target"
  build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-hostrt-'"$i"'","nonce":"'"$(printf '%064d' $((120 + i)))"'"}'
  expect_phase_b_refused "host_runtime constituent $i tampered alone" "attempt.fixture-hostrt-$i" \
    "$base/pkg-pb.json" '["launch.identity-unaccepted"]'
done
pass 'each of the host_runtime composite'"'"'s four constituents (vfkit, driver, vm_service, dyld_cache), tampered alone, moves the composite away from the accepted digest: launch.identity-unaccepted alone'
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'

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
