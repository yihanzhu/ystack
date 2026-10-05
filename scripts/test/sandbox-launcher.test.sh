#!/usr/bin/env bash
# Proves sandbox/v1/host-supervisor.py's phase A (R4.1), the R10.1 ACL walk,
# the store root (work/enforcement-evidence-binding/spec.md R2.3), the R10.2
# store writer, the R10.3 receipt/outcome, and (PR 5 of 9) the real launch
# path -- disks, plan.json, the driver interface, the monotonic HardStop/
# SIGKILL clock, export reading -- against scripts/test/sandbox-fake-runtime.py,
# never a real hypervisor. See work/vm-launcher-supervisor/plan.md and
# spec.md R3/R4.1/R5/R7-R9/R10.
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
    base, src, work_root, placeholder, fake_runtime_src = (
        sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1", sys.argv[5])
    shutil.rmtree(base, ignore_errors=True)
    os.makedirs(base, mode=0o755)
    install_dir = os.path.join(base, "install")
    os.makedirs(install_dir, mode=0o755)
    shutil.copy(src, os.path.join(install_dir, "host-supervisor.py"))
    os.chmod(os.path.join(install_dir, "host-supervisor.py"), 0o555)

    identity_keys = ["guest_init", "guest_kernel", "guest_kernel_config", "guest_supervisor",
                     "host_runtime", "host_supervisor", "image", "toolchain", "verifier",
                     "vm_service"]
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

    # dyld_cache_files: a split arm64e shared cache's several subcache
    # files, each walked and included in the host_runtime composite.
    dyld_cache_paths = []
    for i in range(2):
        p = os.path.join(identities_dir, "dyld_cache.%d" % i)
        open(p, "wb").write(b"synthetic-dyld_cache." + str(i).encode())
        os.chmod(p, 0o444)
        dyld_cache_paths.append(p)
    identity_paths["dyld_cache_files"] = dyld_cache_paths

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
    driver_path = os.path.join(base, "driver")
    shutil.copy(fake_runtime_src, driver_path)
    # The driver's own shebang is a source file constant (#!/usr/bin/python3
    # -- an absolute path was already needed since the driver interface's
    # argv/state/stop calls run under an EMPTY environment, so a
    # "#!/usr/bin/env python3" shebang can't resolve python3 via PATH at
    # all). But a hardcoded absolute path is itself a portability risk
    # across hosts/distros (exactly what run this fixture) -- rewrite it
    # to sys.executable, the one interpreter this harness itself is
    # already known to be running under (the same "$python" the bash
    # suite uses everywhere else), so the driver never depends on guessing
    # where python3 happens to live on whatever machine runs the suite.
    with open(driver_path, "rb") as fh:
        driver_bytes = fh.read()
    first_line, _, rest = driver_bytes.partition(b"\n")
    assert first_line.startswith(b"#!"), "fake runtime driver must start with a shebang line"
    with open(driver_path, "wb") as fh:
        fh.write(b"#!" + sys.executable.encode() + b"\n" + rest)
    os.chmod(driver_path, 0o555)
    # findings-477-r16.md finding 1: argv[0] must equal this path -- a
    # second copy of the same rewritten script (never a relocated copy of
    # a signed system binary, which macOS codesign kills on sight).
    shutil.copy(driver_path, vfkit_path)
    os.chmod(vfkit_path, 0o555)
    # the fake driver's own default-success scenario, read whenever a test
    # doesn't set YSTACK_FAKE_SCENARIO (an empty environment is used for the
    # driver argv/state/stop calls themselves, so this is a fallback the
    # fake reads relative to its own path, not via an env var, for those)
    open(os.path.join(base, "scenario.json"), "wb").write(canon({}))

    # R2.3's composite slots: same formula as host-supervisor.py's own
    # measure_identities, over these same fixture bytes -- everything else
    # (the 6 simple slots) stays a raw sha256 of its installed bytes.
    KERNEL_CONFIG_DEVICES = ["virtio-blk,readonly", "virtio-blk"]
    host_runtime_digest = sha(canon({"files": [
        {"path": "vfkit", "sha256": sha(open(vfkit_path, "rb").read())},
        {"path": "driver", "sha256": sha(open(driver_path, "rb").read())},
        {"path": "vm_service", "sha256": sha(open(identity_paths["vm_service"], "rb").read())}]
        + [{"path": "dyld_cache.%d" % i, "sha256": sha(open(p, "rb").read())}
           for i, p in enumerate(dyld_cache_paths)]}))
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
         # "mechanism.unmeasured" is every row's mechanism_id on the
         # refused-path stub receipt and on an admitted-but-guest-is-None
         # row (a freeze failure or a failed R8.2 validation); the other
         # id per row is host-supervisor.py's own LIMIT_MECHANISM_IDS --
         # its R7.1 fixed, unconditional mechanism_id for that row on any
         # real (validated) launch, guest-reported or (for wall) host-only
         # -- both included here so the R15.1 consumer-checker matrix's
         # own is_identity_unaccepted isn't spuriously tripped on any path.
         "mechanisms": {
             "cpu_time_ms": sorted(["mechanism.cpu.single-vcpu-quota-deadline.v1", "mechanism.unmeasured"]),
             "memory_bytes": sorted(["mechanism.memory.vm-ram-ceiling.v1", "mechanism.unmeasured"]),
             "output_bytes": sorted(["mechanism.output.single-tmpfs-append.v1", "mechanism.unmeasured"]),
             "process_count": sorted(["mechanism.tasks.cgroup-pids.v1", "mechanism.unmeasured"]),
             "scratch_bytes": sorted(["mechanism.scratch.tmpfs-no-free.v1", "mechanism.unmeasured"]),
             "wall_time_ms": sorted(["mechanism.wall.host-monotonic-stop.v1", "mechanism.unmeasured"]),
         }}]},
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
                       "dyld_cache_paths": dyld_cache_paths,
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
  info=$("$python" "$base/build_tree.py" "$base/root" "$supervisor_src" "$work_root" "$1" \
    "$root/scripts/test/sandbox-fake-runtime.py")
  install_dir=$(printf '%s' "$info" | "$jq_bin" -r .install_dir)
  export YSTACK_HOST_SUPERVISOR="$install_dir/host-supervisor.py"
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
  dyld_cache_paths=()
  while IFS= read -r line; do dyld_cache_paths+=("$line"); done < <(
    printf '%s' "$info" | "$jq_bin" -r '.dyld_cache_paths[]')
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
expect_phase_a_pass() { # expect_phase_a_pass <desc> <pkg-file> -- phase A only, no admission claim
  local desc=$1 pkgfile=$2 status=0
  run_launch "$pkgfile" || status=$?
  [ "$status" -eq 0 ] || fail "$desc: expected exit 0, got $status ($(cat "$base/err"))"
  [ ! -s "$base/out" ] || fail "$desc: stdout must be empty"
  [ ! -s "$base/err" ] || fail "$desc: stderr must be empty ($(cat "$base/err"))"
}
# Test-only CI diagnostics (stderr, only ever reached on an assertion
# failure that's about to call fail() and exit anyway): the receipt's own
# lifecycle/outcome/payload.exit_state/six limit rows, and runtime.log's
# tail if it's still there (an attempt that made it to a written receipt
# already had remove_frozen delete it as part of teardown, so its
# absence there is itself informative, not a bug in this helper).
dump_receipt_debug() { # dump_receipt_debug <desc> <attempt-id>
  local d=$1 a=$2 receipt="$store_root/$2/receipt.json" log="$work_root/$2/runtime.log"
  {
    printf -- '---- %s: receipt/runtime diagnostics for %s ----\n' "$d" "$a"
    if [ -f "$receipt" ]; then
      printf 'lifecycle: %s\n' "$("$jq_bin" -c '.body.lifecycle' "$receipt" 2>/dev/null)"
      printf 'outcome: %s\n' "$("$jq_bin" -c '.body.outcome' "$receipt" 2>/dev/null)"
      printf 'payload.exit_state/exit_code: %s\n' \
        "$("$jq_bin" -c '{exit_state:.body.payload.exit_state,exit_code:.body.payload.exit_code}' "$receipt" 2>/dev/null)"
      printf 'limits: %s\n' "$("$jq_bin" -c '.body.limits' "$receipt" 2>/dev/null)"
    else
      printf '(no receipt.json at %s)\n' "$receipt"
    fi
    if [ -f "$log" ]; then
      printf -- '---- runtime.log tail ----\n'
      tail -c 4096 "$log"
    else
      printf '(runtime.log not present at %s -- already removed by teardown, or never created)\n' "$log"
    fi
  } >&2
}
expect_admitted() { # expect_admitted <desc> <attempt-id> <pkg-file> -- asserts real admission, not just exit 0
  local desc=$1 attempt_id=$2 pkgfile=$3 admission
  expect_phase_a_pass "$desc" "$pkgfile"
  admission=$("$jq_bin" -r '.body.lifecycle.admission' "$store_root/$attempt_id/receipt.json")
  if [ "$admission" != admitted ]; then
    dump_receipt_debug "$desc" "$attempt_id"
    fail "$desc: expected lifecycle.admission admitted, got $admission"
  fi
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
expect_admitted 'a fully correct install tree, store root and package' attempt.fixture-0001 "$base/pkg-ok.json"
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
  expect_admitted "control: $desc without the ACL entry" attempt.fixture-0001 "$base/pkg-ok.json"
  pass "$desc carrying one ACL entry is refused E_INSTALL_ACL before stdin is read, paired against the same tree without it"
done

if [ "$(/usr/bin/uname -s)" = Darwin ]; then
  # Multi-entry ACL regression (P1): the wrong ACL_NEXT_ENTRY never
  # advanced past the first entry, so a second entry went uninspected.
  build_tree 0
  build_pkg "$base/pkg-ok.json" '{}'
  /bin/chmod +a "$(id -un) deny append" "$config_path"
  /bin/chmod +a "everyone deny write" "$config_path"
  expect_admitted 'two deny-only ACL entries on the trusted config file' attempt.fixture-0001 "$base/pkg-ok.json"
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
expect_admitted 'control: runtime.driver restored to non-writable' attempt.fixture-0001 "$base/pkg-ok.json"
pass 'runtime.driver, alongside runtime.vfkit, is included in the R10.1 config-named walk: a world-writable driver is refused E_CONFIG, paired against the same tree without it'

# A group/other-writable ancestor (no ACL entry, just a bad mode) is
# refused too, not only caught by luck when some other path crosses it.
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'
/bin/chmod 0775 "$base/root"
expect_refused 'E_CONFIG: an ancestor of the install directory is group-writable' E_CONFIG "$base/pkg-ok.json"
/bin/chmod 0755 "$base/root"
expect_admitted 'control: the same ancestor restored to non-group-writable' attempt.fixture-0001 "$base/pkg-ok.json"
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
expect_phase_a_pass 'an incident.json record at exactly the 262,144-byte cap' "$base/pkg-incident.json"
build_pkg "$base/pkg-incident.json" '{"attempt_id":"attempt.fixture-incident-over","incident_bytes":262145}'
expect_refused 'E_PACKAGE: an incident.json record one byte over the 262,144-byte cap' E_PACKAGE "$base/pkg-incident.json"
pass 'the incident.json record size boundary (262,144 bytes accepted, 262,145 refused E_PACKAGE) holds exactly at the cap'

build_pkg "$base/pkg-bad.json" '{"store_id":"store.wrong"}'
expect_refused 'E_STORE_ID: request store_id differs from the configuration' E_STORE_ID "$base/pkg-bad.json"
pass 'a request store_id differing from the configuration is refused E_STORE_ID, paired against the accepted control'

build_pkg "$base/pkg-reuse.json" '{"attempt_id":"attempt.fixture-reuse","nonce":"1111111111111111111111111111111111111111111111111111111111111111"}'
expect_admitted 'first use of a nonce' attempt.fixture-reuse "$base/pkg-reuse.json"
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
# R9.4/R7.2: a real, successful fake-runtime launch is lifecycle.runtime
# completed -- but outcome.verdict is still failed, since the wall row's
# enforcement is permanently "none" (no route to hard in this spec),
# so failure.enforcement-unavailable fires on every admitted receipt.
if [ "$receipt_admission" != admitted ] || [ "$receipt_runtime" != completed ] || [ "$receipt_verdict" != failed ]; then
  dump_receipt_debug 'admitted receipt' attempt.fixture-reuse
  fail "admitted receipt: expected admission admitted, runtime completed, verdict failed -- got $receipt_admission/$receipt_runtime/$receipt_verdict"
fi
pass 'a real (fake-runtime) launch that completes cleanly records lifecycle.admission admitted, lifecycle.runtime completed, and outcome.verdict failed only because of the permanent wall-enforcement-unavailable limitation'

# R9.3: the frozen copies (R5.1) an admitted attempt made are its only
# work_root storage at this stage (no runtime exists before PR 5) -- the
# WHOLE <work_root>/<attempt_id> directory, not just frozen/ within it,
# must be gone before teardown can honestly claim storage_destroyed: true.
[ ! -e "$work_root/attempt.fixture-reuse" ] ||
  fail 'admitted attempt: <work_root>/<attempt_id> was not removed before storage_destroyed: true'
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/attempt.fixture-reuse/receipt.json")
teardown_destroyed=$("$jq_bin" -r '.body.teardown.storage_destroyed' "$store_root/attempt.fixture-reuse/receipt.json")
if [ "$teardown_state" != confirmed ] || [ "$teardown_destroyed" != true ]; then
  dump_receipt_debug 'admitted attempt teardown' attempt.fixture-reuse
  fail "admitted attempt: expected teardown.state confirmed and storage_destroyed true -- got $teardown_state/$teardown_destroyed"
fi
pass "an admitted attempt's whole work_root attempt directory is removed and the removal verified before teardown.state confirmed / storage_destroyed: true"

# Security boundary (R9.3): teardown must unlink only the entries this
# attempt is known to have created, never whatever a directory listing
# happens to find -- an unexpected planted file survives, and that alone
# must flip storage_destroyed to false rather than being silently deleted.
build_pkg "$base/pkg-plant.json" '{"attempt_id":"attempt.fixture-plant","nonce":"'"$(printf '%064d' 240)"'"}'
status=0
YSTACK_TEST_PLANT_EXTRA_FILE=1 run_launch "$base/pkg-plant.json" || status=$?
[ "$status" -eq 0 ] || fail "planted-file hook: expected exit 0, got $status ($(cat "$base/err"))"
[ -e "$work_root/attempt.fixture-plant/frozen/unexpected.txt" ] ||
  fail 'planted-file hook: the unexpected file should survive teardown, not be deleted'
teardown_destroyed=$("$jq_bin" -r '.body.teardown.storage_destroyed' "$store_root/attempt.fixture-plant/receipt.json")
[ "$teardown_destroyed" = false ] ||
  fail 'planted-file hook: expected storage_destroyed false with an unexpected survivor'
pass 'an unexpected file planted alongside the frozen copies survives teardown untouched and is reported as storage_destroyed: false, never silently unlinked'

# R10.4: a freeze failure part way through must never escape as a
# traceback with a claimed store dir and no receipt.
build_pkg "$base/pkg-freezefail.json" '{"attempt_id":"attempt.fixture-freezefail","nonce":"'"$(printf '%064d' 241)"'"}'
status=0
YSTACK_TEST_FREEZE_FAIL=1 run_launch "$base/pkg-freezefail.json" || status=$?
[ "$status" -eq 0 ] || fail "freeze-failure hook: expected exit 0 (a receipt, not a traceback), got $status ($(cat "$base/err"))"
[ ! -e "$work_root/attempt.fixture-freezefail" ] ||
  fail 'freeze-failure hook: the partial attempt directory should be cleaned up'
[ -f "$store_root/attempt.fixture-freezefail/receipt.json" ] ||
  fail 'freeze-failure hook: expected a receipt to still be written'
pass 'a freeze failure part way through (the test-only YSTACK_TEST_FREEZE_FAIL hook) cleans up the partial attempt directory and still writes a receipt, never a traceback'

# Security (R9.3): "nonces" collides with the replay-marker directory --
# reserved E_PACKAGE before the nonce is touched, so markers survive.
/bin/mkdir -p "$work_root/nonces"
marker="$work_root/nonces/pre-existing-marker"
: > "$marker"
build_pkg "$base/pkg-nonces.json" '{"attempt_id":"nonces","nonce":"'"$(printf '%064d' 242)"'"}'
status=0
run_launch "$base/pkg-nonces.json" || status=$?
[ "$status" -eq 65 ] && [ "$(cat "$base/err")" = E_PACKAGE ] ||
  fail "attempt_id \"nonces\": expected exit 65 E_PACKAGE, got $status ($(cat "$base/err"))"
[ -f "$marker" ] || fail 'attempt_id "nonces": a prior nonce marker was destroyed'
pass 'an attempt_id equal to the reserved work_root name "nonces" is refused E_PACKAGE before the nonce is touched; every prior replay marker survives untouched'

# Any other pre-existing work_root entry must refuse E_ATTEMPT_EXISTS
# with nothing removed, never the write-failure cleanup path.
/bin/mkdir -p "$work_root/attempt.fixture-collide/unrelated"
: > "$work_root/attempt.fixture-collide/unrelated/marker"
build_pkg "$base/pkg-collide.json" '{"attempt_id":"attempt.fixture-collide","nonce":"'"$(printf '%064d' 243)"'"}'
status=0
run_launch "$base/pkg-collide.json" || status=$?
[ "$status" -eq 65 ] && [ "$(cat "$base/err")" = E_ATTEMPT_EXISTS ] ||
  fail "pre-existing work_root entry: expected exit 65 E_ATTEMPT_EXISTS, got $status ($(cat "$base/err"))"
[ -f "$work_root/attempt.fixture-collide/unrelated/marker" ] ||
  fail 'pre-existing work_root entry: its unrelated contents were destroyed'
[ ! -e "$store_root/attempt.fixture-collide" ] ||
  fail 'pre-existing work_root entry: the store must never claim an orphan entry for a work-dir collision refused before admission'
pass 'a pre-existing work_root entry sharing an attempt_id refuses E_ATTEMPT_EXISTS before the store is ever claimed, with nothing removed'

# R10.4: a finalization failure (fchown/fchmod/fsync) right after the
# attempt directory's exclusive mkdir must not leave a claimed dir with
# no receipt (exit 1) -- it now falls inside the same E_STORE_WRITE
# handler as the store write itself, exit 70.
build_pkg "$base/pkg-finfail.json" '{"attempt_id":"attempt.fixture-finfail","nonce":"'"$(printf '%064d' 244)"'"}'
status=0
YSTACK_TEST_MKDIR_FINALIZE_FAIL=attempt.fixture-finfail run_launch "$base/pkg-finfail.json" || status=$?
[ "$status" -eq 70 ] && [ "$(cat "$base/err")" = E_STORE_WRITE ] ||
  fail "attempt-dir finalize failure: expected exit 70 E_STORE_WRITE, got $status ($(cat "$base/err"))"
pass 'a finalization failure right after the attempt directory'"'"'s exclusive mkdir is E_STORE_WRITE/exit 70, never an uncaught exit 1'

# Malformed registry bytes (unbalanced, an embedded NaN, a JSON-legal
# lone-surrogate escape) refuse E_CONFIG -- an installed config file,
# never E_PACKAGE (the request's own code), never an uncaught exception.
/bin/chmod 644 "$registry_path"
for raw in '{' '{"a":NaN}' '{"a":"\ud800"}'; do
  python3 -c "import sys; open(sys.argv[1], 'w').write(sys.argv[2])" "$registry_path" "$raw"
  expect_refused "E_CONFIG: malformed registry ($raw)" E_CONFIG "$base/pkg-ok.json"
done
pass 'malformed registry bytes (unbalanced, an embedded NaN, a JSON-legal lone-surrogate escape) each refuse E_CONFIG, never E_PACKAGE or an uncaught exception'
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'

patch_json() { # patch_json <in-file> <out-file> <python-expr-mutating "doc">
  python3 -c "
import json, importlib.util, sys
spec = importlib.util.spec_from_file_location('hs', '$supervisor_src')
hs = importlib.util.module_from_spec(spec); spec.loader.exec_module(hs)
doc = json.loads(open(sys.argv[1], 'rb').read())
$3
open(sys.argv[2], 'wb').write(hs.canonical(doc))
" "$1" "$2"
}
# The registry's envelope id and both body leaf fields must be the exact
# type the shipped checker's fixed_registry_shape_ok requires
# (sandbox-receipt.jq:373-377), not merely present.
for edit in 'doc["id"] = []' 'doc["body"]["activation_state"] = {}' 'doc["body"]["registry_version"] = False'; do
  patch_json "$registry_path" "$base/registry-badshape.json" "$edit"
  /bin/chmod 644 "$registry_path"
  /bin/cp "$base/registry-badshape.json" "$registry_path"
  /bin/chmod 444 "$registry_path"
  expect_refused "E_CONFIG: registry shape ($edit)" E_CONFIG "$base/pkg-ok.json"
done
pass 'a registry envelope id or body leaf field of the wrong type ("id":[], "activation_state":{}, "registry_version":false) is refused E_CONFIG, mirroring the shipped checker'"'"'s own registry_body_schema exactly'

# A config-file read failure (IsADirectoryError, or any other OSError)
# must never escape the guarded block uncaught -- E_CONFIG/exit 65, not
# a bare traceback/exit 1. Tested for two different guarded reads.
/bin/rm -f "$registry_path"
/bin/mkdir "$registry_path"
expect_refused 'E_CONFIG: the registry path is a directory' E_CONFIG "$base/pkg-ok.json"
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'
/bin/rm -f "$accepted_set"
/bin/mkdir "$accepted_set"
expect_refused 'E_CONFIG: the accepted-set path is a directory' E_CONFIG "$base/pkg-ok.json"
pass 'a config-file path that is a directory (the registry, the accepted set) is refused E_CONFIG, never an uncaught exception past the guarded read'
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'

# R2.3 (memory): sha256_fd streams a file through hashlib.sha256 in fixed
# chunks, never accumulating its bytes -- proven against a real (sparse)
# 64 MiB file and shasum, independent of any fixture wiring.
large_path="$base/large-identity-file"
/usr/bin/truncate -s 67108864 "$large_path"
expected_sha=$(/usr/bin/shasum -a 256 "$large_path" | /usr/bin/awk '{print $1}')
streamed_sha=$("$python" -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('hs', '$supervisor_src')
hs = importlib.util.module_from_spec(spec); spec.loader.exec_module(hs)
fd = os.open('$large_path', os.O_RDONLY)
print(hs.sha256_fd(fd))
")
[ "$streamed_sha" = "$expected_sha" ] ||
  fail "sha256_fd: expected $expected_sha, got $streamed_sha"
/bin/rm -f "$large_path"
pass 'sha256_fd streams a 64 MiB file through hashlib.sha256 in fixed chunks and matches shasum exactly, never accumulating the file'"'"'s bytes'
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'

# prepare-candidate.py:1662-1677's closed manifest-entry shape: an
# unsupported kind/mode must not be silently filtered out.
i=0
entry_oid=$(python3 -c "print('f' * 40)")
entry_sha=$(python3 -c "print('a' * 64)")
for entry in '{"path":"README.md","kind":"symlink","git_mode":"120000","mode":"0500","blob_oid":"'"$entry_oid"'","size_bytes":5,"sha256":"'"$entry_sha"'"}' \
             '{"path":"README.md","kind":"file","git_mode":"100644","mode":"0777","blob_oid":"'"$entry_oid"'","size_bytes":5,"sha256":"'"$entry_sha"'"}' \
             '{"path":"README.md","kind":[],"git_mode":"100644","mode":"0400","blob_oid":"'"$entry_oid"'","size_bytes":5,"sha256":"'"$entry_sha"'"}' \
             '{"path":"README.md","kind":"file","git_mode":"100644","mode":{},"blob_oid":"'"$entry_oid"'","size_bytes":5,"sha256":"'"$entry_sha"'"}' \
             '{"kind":"file","git_mode":"100644","mode":"0400","blob_oid":"'"$entry_oid"'","size_bytes":5,"sha256":"'"$entry_sha"'"}'; do
  i=$((i + 1))
  build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-entryshape-'"$i"'","nonce":"'"$(printf '%064d' $((250 + i)))"'","manifest_set":{"entries":['"$entry"']}}'
  expect_phase_b_refused "manifest entry shape ($entry)" "attempt.fixture-entryshape-$i" \
    "$base/pkg-pb.json" '["launch.manifest-mismatch"]'
done
pass 'a manifest entry with an unsupported kind (e.g. symlink), an out-of-set mode (e.g. 0777), a non-string kind/mode (a list, a dict), or a missing path (findings-477-r12.md finding 1 -- otherwise a KeyError in build_plan_json well after the attempt is claimed) is refused launch.manifest-mismatch before candidate selection, never silently filtered out or an uncaught exception'
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'

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
restore_control() { # copies the real shipped control+evaluator files over the installed ones
  /bin/chmod 644 "$installed_control_policy" "$installed_control_decision" "$installed_control_policy_set" \
    "$installed_evaluator_driver" "$installed_evaluator_program"
  /bin/cp "$root/control/v1/sandbox-policy.json" "$installed_control_policy"
  /bin/cp "$root/control/v1/sandbox-decision.json" "$installed_control_decision"
  /bin/cp "$root/control/v1/control-policy-set.json" "$installed_control_policy_set"
  /bin/cp "$root/control/v1/evaluate-sandbox.sh" "$installed_evaluator_driver"
  /bin/cp "$root/control/v1/sandbox.jq" "$installed_evaluator_program"
  /bin/chmod 444 "$installed_control_policy" "$installed_control_decision" "$installed_control_policy_set" \
    "$installed_evaluator_driver" "$installed_evaluator_program"
}
restore_control
build_pkg "$base/pkg-check.json" '{"attempt_id":"attempt.fixture-check","nonce":"3333333333333333333333333333333333333333333333333333333333333333","control_real":true,"expectation_out":"'"$base/expectation.json"'","evaluation_out":"'"$base/evaluation.json"'"}'
expect_admitted 'the attempt used for the shipped-checker cross-check' attempt.fixture-check "$base/pkg-check.json"
check_out=$("$jq_bin" -c . <(PATH="$jq_dir:$PATH" bash "$root/enforcement/v1/check-sandbox-receipt.sh" check \
  "$store_root/attempt.fixture-check/receipt.json" "$base/expectation.json" "$base/evaluation.json"))
[ "$("$jq_bin" -r '.body.check_verdict' <<<"$check_out")" = refused ] || fail 'shipped checker: expected check_verdict refused'
reasons=$("$jq_bin" -c -S '.body.reason_ids' <<<"$check_out")
[ "$reasons" = '["receipt.environment-unlisted","receipt.identity-unaccepted","receipt.stale"]' ] ||
  fail "shipped checker: expected the three shipped-empty-set reasons, got $reasons"
pass 'the shipped check-sandbox-receipt.sh accepts the receipt and expectation shape and refuses it only with the three shipped-empty-accepted-set reasons (receipt.environment-unlisted, receipt.identity-unaccepted, receipt.stale), never receipt.malformed'

# =============================================================================
# R15.1 consumer-checker matrix (spec.md:597-625): a temporary repository
# copy of check-sandbox-receipt.sh carrying THIS fixture's own registry and
# accepted set (not the real shipped ones) proves the host's and the
# checker's independent reason derivations agree -- one representative
# case per class, kept minimal against the review-size budget.
# =============================================================================
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'
# The checker validates control/v1's own JSON shape, so it needs the real
# shipped files (the fixture's own installed control files are synthetic
# placeholder bytes, not JSON) -- all five (including both evaluator
# files, previously missed here, which left every control_real:true case
# below with an unintended launch.control-mismatch) so host-side
# control-mismatch also passes, with control_real=true for every case.
restore_control
checker_root="$base/checker"
/bin/mkdir -p "$checker_root/enforcement/v1" "$checker_root/control/v1" "$checker_root/shadow/v1"
/bin/cp "$root/enforcement/v1/check-sandbox-receipt.sh" "$root/enforcement/v1/sandbox-receipt.jq" \
  "$checker_root/enforcement/v1/"
/bin/cp "$installed_control_policy" "$checker_root/control/v1/sandbox-policy.json"
/bin/cp "$installed_control_decision" "$checker_root/control/v1/sandbox-decision.json"
/bin/cp "$installed_control_policy_set" "$checker_root/control/v1/control-policy-set.json"
/bin/cp "$registry_path" "$checker_root/shadow/v1/shadow-environments.json"
/bin/cp "$accepted_set" "$checker_root/enforcement/v1/accepted-identities.json"
check_case() { # check_case <desc> <attempt-id> <verdict> <reasons-json> <host-reasons: admitted|json> [enforcement-verdict]
  local out ok=1 admission
  admission=$("$jq_bin" -r '.body.lifecycle.admission' "$store_root/$2/receipt.json")
  if [ "$5" = admitted ]; then
    [ "$admission" = admitted ] || ok=0
  else
    [ "$admission" = refused ] &&
      [ "$("$jq_bin" -c -S '.reason_ids' "$store_root/$2/payload/refusal.json" 2>/dev/null)" = "$5" ] || ok=0
  fi
  out=$("$jq_bin" -c . <(PATH="$jq_dir:$PATH" bash "$checker_root/enforcement/v1/check-sandbox-receipt.sh" \
    check "$store_root/$2/receipt.json" "$base/expectation.json" "$base/evaluation.json"))
  [ "$("$jq_bin" -r '.body.check_verdict' <<<"$out")" = "$3" ] || ok=0
  [ "$("$jq_bin" -c -S '.body.reason_ids' <<<"$out")" = "$4" ] || ok=0
  [ -z "${6:-}" ] || [ "$("$jq_bin" -r '.body.enforcement_verdict' <<<"$out")" = "$6" ] || ok=0
  [ "$ok" -eq 1 ] || fail "$1: unexpected output (host admission=$admission) checker=$out"
}
build_pkg "$base/pkg-chk.json" '{"attempt_id":"attempt.fixture-chk-a","nonce":"'"$(printf '%064d' 260)"'","control_real":true,"set":{"subject.environment_entry_sha256":"'"$entry_sha"'"},"expectation_out":"'"$base/expectation.json"'","evaluation_out":"'"$base/evaluation.json"'"}'
run_launch "$base/pkg-chk.json"
check_case 'class (a): environment_entry_sha256' attempt.fixture-chk-a refused '["receipt.environment-unlisted"]' '["launch.environment-unlisted"]'
build_pkg "$base/pkg-chk.json" '{"attempt_id":"attempt.fixture-chk-b","nonce":"'"$(printf '%064d' 261)"'","control_real":true,"expectation_out":"'"$base/expectation.json"'","evaluation_out":"'"$base/evaluation.json"'"}'
YSTACK_TEST_IDENTITY_UNREADABLE=guest_init run_launch "$base/pkg-chk.json"
check_case 'phase-B class (c): identity-missing' attempt.fixture-chk-b valid '["receipt.valid"]' '["launch.identity-missing"]' failed
pass 'the shipped checker, run against this fixture'"'"'s own registry/accepted set, gives the R15.1 class (a) and phase-B class (c) verdicts exactly, matching the host'"'"'s own derivation'

# The rest of the matrix: every remaining class (a) binding refusal, both
# class (b) reasons, looped over fresh fixtures (control_real=true so the
# checker's own control/policy checks agree with the host's).
n=270
chk_case() { # chk_case <desc> <patch-json> <verdict> <reasons-json>
  n=$((n + 1))
  local attempt_id="attempt.fixture-chk-$n"
  build_pkg "$base/pkg-chk.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'","control_real":true,"expectation_out":"'"$base/expectation.json"'","evaluation_out":"'"$base/evaluation.json"'",'"$2"'}'
  run_launch "$base/pkg-chk.json"
  check_case "$1" "$attempt_id" "$3" "$4" "$5"
}
chk_case 'class (a): control-mismatch alone (evaluator_driver_sha256)' \
  '"set":{"control.evaluator_driver_sha256":"'"$entry_sha"'"}' refused '["receipt.control-mismatch"]' \
  '["launch.control-mismatch"]'
chk_case 'class (a): control-mismatch + evaluation-not-satisfied (decision_sha256)' \
  '"set":{"control.decision_sha256":"'"$entry_sha"'"}' refused \
  '["receipt.control-mismatch","receipt.evaluation-not-satisfied"]' \
  '["launch.control-mismatch","launch.evaluation-not-satisfied"]'
chk_case 'class (a): evaluation-not-satisfied alone (evaluation.json verdict)' \
  '"evaluation_set":{"body.verdict":"unsatisfied"}' refused '["receipt.evaluation-not-satisfied"]' \
  '["launch.evaluation-not-satisfied"]'
chk_case 'class (b): identity-unaccepted (unaccepted instruction)' \
  '"instruction":"unaccepted-instr"' refused '["receipt.identity-unaccepted"]' '["launch.instruction-unaccepted"]'

# replayed / origin-mismatch: the expectation, mutated after the fact,
# disagrees with what the receipt actually recorded.
n=$((n + 1))
build_pkg "$base/pkg-chk.json" '{"attempt_id":"attempt.fixture-chk-'"$n"'","nonce":"'"$(printf '%064d' "$n")"'","control_real":true,"expectation_out":"'"$base/expectation.json"'","evaluation_out":"'"$base/evaluation.json"'"}'
run_launch "$base/pkg-chk.json"
patch_json "$base/expectation.json" "$base/expectation.json" \
  "doc['body']['attempt']['attempt_number'] = 99"
check_case 'class (a): replayed (expectation attempt differs)' "attempt.fixture-chk-$n" refused '["receipt.replayed"]' admitted

n=$((n + 1))
build_pkg "$base/pkg-chk.json" '{"attempt_id":"attempt.fixture-chk-'"$n"'","nonce":"'"$(printf '%064d' "$n")"'","control_real":true,"expectation_out":"'"$base/expectation.json"'","evaluation_out":"'"$base/evaluation.json"'"}'
run_launch "$base/pkg-chk.json"
patch_json "$base/expectation.json" "$base/expectation.json" \
  "doc['body']['store_id'] = 'store.other'"
check_case 'class (a): origin-mismatch (expectation store_id differs)' "attempt.fixture-chk-$n" refused '["receipt.origin-mismatch"]' admitted

# stale: the installed accepted set changes after the receipt is written,
# so the checker's own (current) accepted_set_sha256 no longer matches
# what the receipt recorded at admission.
n=$((n + 1))
build_pkg "$base/pkg-chk.json" '{"attempt_id":"attempt.fixture-chk-'"$n"'","nonce":"'"$(printf '%064d' "$n")"'","control_real":true,"expectation_out":"'"$base/expectation.json"'","evaluation_out":"'"$base/evaluation.json"'"}'
run_launch "$base/pkg-chk.json"
/bin/chmod 644 "$accepted_set"
patch_json "$accepted_set" "$accepted_set" \
  "doc['body']['environments'][0]['identities']['toolchain'] = sorted(set(doc['body']['environments'][0]['identities']['toolchain'] + ['$entry_sha']))"
/bin/chmod 444 "$accepted_set"
/bin/rm -f "$checker_root/enforcement/v1/accepted-identities.json"
/bin/cp "$accepted_set" "$checker_root/enforcement/v1/accepted-identities.json"
check_case 'class (a): stale (accepted set changed after admission)' "attempt.fixture-chk-$n" refused '["receipt.stale"]' admitted
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'
restore_control
/bin/rm -f "$checker_root/enforcement/v1/accepted-identities.json"
/bin/cp "$accepted_set" "$checker_root/enforcement/v1/accepted-identities.json"

# placeholder-identity: a copy of an admitted receipt with one identity
# slot's digest set to the all-ones placeholder (is_identity_unaccepted
# explicitly excludes placeholder digests, so this is the sole reason).
n=$((n + 1))
build_pkg "$base/pkg-chk.json" '{"attempt_id":"attempt.fixture-chk-'"$n"'","nonce":"'"$(printf '%064d' "$n")"'","control_real":true,"expectation_out":"'"$base/expectation.json"'","evaluation_out":"'"$base/evaluation.json"'"}'
run_launch "$base/pkg-chk.json"
patch_json "$store_root/attempt.fixture-chk-$n/receipt.json" "$base/receipt-placeholder.json" \
  "doc['body']['identities']['toolchain']['sha256'] = '1' * 64"
out=$("$jq_bin" -c . <(PATH="$jq_dir:$PATH" bash "$checker_root/enforcement/v1/check-sandbox-receipt.sh" \
  check "$base/receipt-placeholder.json" "$base/expectation.json" "$base/evaluation.json"))
[ "$("$jq_bin" -r '.body.check_verdict' <<<"$out")" = refused ] &&
  [ "$("$jq_bin" -c -S '.body.reason_ids' <<<"$out")" = '["receipt.placeholder-identity"]' ] ||
  fail "class (b) placeholder-identity: unexpected checker output $out"
pass 'the remaining R15.1 class (a) binding refusals (control-mismatch alone and paired with evaluation-not-satisfied, evaluation-not-satisfied alone, replayed, origin-mismatch, stale) and class (b) reasons (identity-unaccepted, placeholder-identity) each give exactly their spec-listed receipt.* reason set'
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'

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
expect_admitted 'instruction binding positive control: an accepted instruction, both digests intact' attempt.fixture-pb-instrok "$base/pkg-pb.json"

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
  expect_admitted "candidate transport: a manifest path of ${#name} bytes" "attempt.fixture-path-$i" "$base/pkg-path.json"
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
expect_admitted 'kernel-config control: the full =y set admits' attempt.fixture-0001 "$base/pkg-ok.json"

# Each option (plus the HZ set, via its baseline entry CONFIG_HZ_250)
# checked individually absent or =m, all others valid.
all_kernel_options=("${kernel_required_options[@]}" CONFIG_HZ_250)
i=0
for opt in "${all_kernel_options[@]}"; do
  for mode in absent m; do
    i=$((i + 1))
    /bin/chmod 644 "$guest_kernel_config_path"
    : > "$guest_kernel_config_path"
    for o in "${all_kernel_options[@]}"; do
      if [ "$o" = "$opt" ]; then
        [ "$mode" = absent ] || printf '%s=%s\n' "$o" "$mode" >> "$guest_kernel_config_path"
      else
        printf '%s=y\n' "$o" >> "$guest_kernel_config_path"
      fi
    done
    /bin/chmod 444 "$guest_kernel_config_path"
    build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-kcfg-'"$i"'","nonce":"'"$(printf '%064d' $((150 + i)))"'"}'
    expect_phase_b_refused "kernel option $opt $mode" "attempt.fixture-kcfg-$i" "$base/pkg-pb.json" \
      '["launch.identity-unaccepted","launch.kernel-config"]'
  done
done
pass 'the R2.4 closed =y set refuses launch.kernel-config for every required option (and the HZ set), each checked individually absent or =m with every other option valid, paired against the full =y control'
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'

# =============================================================================
# R2.3 host_runtime composite: each constituent (vfkit, driver, the VM
# service executable, and each of the split arm64e dyld shared cache's
# several subcache files), changed alone, moves the composite digest away
# from what was accepted -- proving it is built from every one of them,
# not a stand-in single file (spec.md:60-73).
# =============================================================================
i=0
for target in "$vfkit_path" "$driver_path" "$vm_service_path" "${dyld_cache_paths[@]}"; do
  i=$((i + 1))
  build_tree 0
  /bin/chmod 644 "$target"
  /usr/bin/printf 'tampered-constituent' > "$target"
  /bin/chmod 444 "$target"
  build_pkg "$base/pkg-pb.json" '{"attempt_id":"attempt.fixture-hostrt-'"$i"'","nonce":"'"$(printf '%064d' $((120 + i)))"'"}'
  expect_phase_b_refused "host_runtime constituent $i tampered alone" "attempt.fixture-hostrt-$i" \
    "$base/pkg-pb.json" '["launch.identity-unaccepted"]'
done
pass 'each host_runtime constituent (vfkit, driver, vm_service, and every dyld_cache_files subcache), tampered alone, moves the composite away from the accepted digest: launch.identity-unaccepted alone'
build_tree 0
build_pkg "$base/pkg-ok.json" '{}'

# An empty dyld_cache_files list is refused E_CONFIG (at least one
# subcache is required).
"$jq_bin" -c '.body.identity_paths.dyld_cache_files = []' "$config_path" > "$base/config-empty-dyld.json"
/bin/chmod 644 "$config_path"
/bin/cp "$base/config-empty-dyld.json" "$config_path"
/bin/chmod 444 "$config_path"
expect_refused 'E_CONFIG: an empty dyld_cache_files list' E_CONFIG "$base/pkg-ok.json"
pass 'an empty identity_paths.dyld_cache_files list is refused E_CONFIG'
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

# =============================================================================
# R15.1 (remainder): the real launch path's own scenarios, driven through
# scripts/test/sandbox-fake-runtime.py's scenario.json -- the row matrix,
# tree_deadline_fired, HardStop, delayed-stop/SIGKILL, self-stop,
# cancellation, a runtime crash, an absent export and a damaged export.
# Small test-only clock overrides (YSTACK_TEST_*_MS) keep every case fast;
# the fake's own 20ms poll tick is well under all of them.
# =============================================================================
build_tree 0
scenario_path="$base/scenario-case.json"
export YSTACK_FAKE_SCENARIO="$scenario_path"
n=500
scenario_case() { # scenario_case <desc> <scenario-json> -- sets $scn_attempt_id (never
  # a $(...) capture around this: a command substitution runs in a subshell, which
  # would silently lose this function's own increment of the outer n counter)
  n=$((n + 1))
  scn_attempt_id="attempt.fixture-scn-$n"
  printf '%s' "$2" > "$scenario_path"
  build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$scn_attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
  expect_admitted "$1 (setup)" "$scn_attempt_id" "$base/pkg-scn.json"
}

# R7.3/R8 row matrix: every one of the five guest-reported rows, in turn,
# across observation complete/partial/unavailable and reached true/false
# -- asserting the exact row record host-supervisor.py derives (bound,
# observed, resolution, observation, enforcement -- forced "none" for
# cpu_time_ms alone (R7.2) -- reached, and mechanism_id, which is always
# the row's own R7.1 FIXED constant regardless of what the guest sends,
# since the fake no longer sends one at all) and the outcome this drives:
# outcome.verdict is always "failed" (the wall row's own enforcement is
# permanently "none", so failure.enforcement-unavailable always fires --
# PR 4/5's documented, permanent limitation, so "violated" is provably
# unreachable), and failure.observation-unavailable appears iff any row
# is partial or unavailable.
# Plain functions, not associative arrays: bash 3.2 (macOS's default
# /bin/bash) has none, and this suite runs under whatever bash is in PATH.
row_mechanism_id() {
  case "$1" in
    cpu_time_ms) echo "mechanism.cpu.single-vcpu-quota-deadline.v1" ;;
    memory_bytes) echo "mechanism.memory.vm-ram-ceiling.v1" ;;
    output_bytes) echo "mechanism.output.single-tmpfs-append.v1" ;;
    process_count) echo "mechanism.tasks.cgroup-pids.v1" ;;
    scratch_bytes) echo "mechanism.scratch.tmpfs-no-free.v1" ;;
  esac
}
row_bound() {
  case "$1" in
    cpu_time_ms) echo 30000 ;;
    memory_bytes) echo 536870912 ;;
    output_bytes) echo 10485760 ;;
    process_count) echo 32 ;;
    scratch_bytes) echo 16777216 ;;
  esac
}
row_matrix_case() { # row_matrix_case <row> <reached> <observation> <enforcement> <observed-or-null>
  local row=$1 reached=$2 observation=$3 enforcement=$4 observed=$5
  scenario_case "row matrix: $row reached=$reached observation=$observation enforcement=$enforcement" \
    '{"limit_overrides":{"'"$row"'":{"reached":'"$reached"',"observation":"'"$observation"'","enforcement":"'"$enforcement"'","observed":'"$observed"',"resolution":1}}}'
  local attempt_id="$scn_attempt_id" receipt="$store_root/$scn_attempt_id/receipt.json"
  local got_reached got_observation got_enforcement got_observed got_resolution got_mechanism got_bound
  local verdict reasons
  got_reached=$("$jq_bin" -r ".body.limits.$row.reached" "$receipt")
  got_observation=$("$jq_bin" -r ".body.limits.$row.observation" "$receipt")
  got_enforcement=$("$jq_bin" -r ".body.limits.$row.enforcement" "$receipt")
  got_observed=$("$jq_bin" -c ".body.limits.$row.observed" "$receipt")
  got_resolution=$("$jq_bin" -r ".body.limits.$row.resolution" "$receipt")
  got_mechanism=$("$jq_bin" -r ".body.limits.$row.mechanism_id" "$receipt")
  got_bound=$("$jq_bin" -r ".body.limits.$row.bound" "$receipt")
  verdict=$("$jq_bin" -r '.body.outcome.verdict' "$receipt")
  reasons=$("$jq_bin" -c -S '.body.outcome.reason_ids' "$receipt")
  local expect_enforcement=$enforcement
  [ "$row" != cpu_time_ms ] || expect_enforcement=none
  local expect_reasons='["failure.enforcement-unavailable"]'
  [ "$observation" = complete ] ||
    expect_reasons='["failure.enforcement-unavailable","failure.observation-unavailable"]'
  [ "$got_reached" = "$reached" ] && [ "$got_observation" = "$observation" ] &&
    [ "$got_enforcement" = "$expect_enforcement" ] && [ "$got_observed" = "$observed" ] &&
    [ "$got_resolution" = 1 ] && [ "$got_mechanism" = "$(row_mechanism_id "$row")" ] &&
    [ "$got_bound" = "$(row_bound "$row")" ] &&
    [ "$verdict" = failed ] && [ "$reasons" = "$expect_reasons" ] ||
    fail "row matrix $row/$reached/$observation/$enforcement: got reached=$got_reached observation=$got_observation enforcement=$got_enforcement observed=$got_observed resolution=$got_resolution mechanism=$got_mechanism bound=$got_bound verdict=$verdict reasons=$reasons"
}
for row in cpu_time_ms memory_bytes output_bytes process_count scratch_bytes; do
  # output_bytes alone is reconciled (R8.2) against stdout + stderr +
  # every declared evidence record's actual size -- all zero in this
  # plain scenario, so its own "complete" observed must be 0, not the
  # arbitrary placeholder the other four rows use.
  complete_observed=7
  [ "$row" != output_bytes ] || complete_observed=0
  row_matrix_case "$row" false complete hard "$complete_observed"
  row_matrix_case "$row" true complete hard "$complete_observed"
  row_matrix_case "$row" false partial unknown 3
  row_matrix_case "$row" false unavailable unknown null
done
pass 'every one of the five guest-reported rows (cpu_time_ms, memory_bytes, output_bytes, process_count, scratch_bytes), across reached true/false and observation complete/partial/unavailable, surfaces the exact row record (bound/observed/resolution/observation/enforcement/reached/mechanism_id -- mechanism_id always the row'"'"'s own R7.1 fixed constant, cpu_time_ms'"'"'s enforcement always forced to none per R7.2) and drives outcome.verdict failed with failure.observation-unavailable present iff the row is not complete'

# R9.1: the guest's own 40s tree-deadline firing is carried into the
# host-only wall row's "reached" (R7.3's wall-row special case).
scenario_case 'guest tree_deadline_fired' '{"report_overrides":{"tree_deadline_fired":true}}'
attempt_id="$scn_attempt_id"
wall_reached=$("$jq_bin" -r '.body.limits.wall_time_ms.reached' "$store_root/$attempt_id/receipt.json")
[ "$wall_reached" = true ] || fail 'tree_deadline_fired: expected limits.wall_time_ms.reached true'
pass "the guest's own tree_deadline_fired is carried into the host-only wall row's reached: true"

# R9.1/R9.2: HardStop, escalation to SIGKILL when the runtime ignores it,
# and the confirmed/unconfirmed stop each of those two paths yields.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"action":"hang"}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_HARDSTOP_MS=150 YSTACK_TEST_SIGKILL_MS=5000 YSTACK_TEST_POLL_INTERVAL_MS=20 \
  run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "HardStop: expected exit 0, got $status ($(cat "$base/err"))"
admission=$("$jq_bin" -r '.body.lifecycle.admission' "$store_root/$attempt_id/receipt.json")
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
wall_reached=$("$jq_bin" -r '.body.limits.wall_time_ms.reached' "$store_root/$attempt_id/receipt.json")
verdict=$("$jq_bin" -r '.body.outcome.verdict' "$store_root/$attempt_id/receipt.json")
reasons=$("$jq_bin" -c -S '.body.outcome.reason_ids' "$store_root/$attempt_id/receipt.json")
expect_reasons='["failure.enforcement-unavailable","failure.observation-unavailable","failure.runtime"]'
[ "$admission" = admitted ] && [ "$runtime" = error ] && [ "$teardown_state" = confirmed ] &&
  [ "$wall_reached" = true ] && [ "$verdict" = failed ] && [ "$reasons" = "$expect_reasons" ] ||
  fail "HardStop: expected admitted/error/confirmed, wall_time_ms.reached true (the receipt-visible proof HardStop actually fired at the deadline), verdict failed, reasons $expect_reasons -- got $admission/$runtime/$teardown_state wall_reached=$wall_reached verdict=$verdict reasons=$reasons"
pass 'a runtime that keeps reporting running past the (test-shortened) HardStop deadline is issued HardStop at that deadline and honors it: lifecycle.runtime error, teardown.state confirmed (the fake process still exits and is reaped, but -- realistically, since a real vfkit HardStop forces the VM off before the guest can sync its export -- writes no export), limits.wall_time_ms.reached true (the one receipt-visible proof HardStop fired), outcome exactly failure.enforcement-unavailable + failure.observation-unavailable + failure.runtime, matching plan.md/spec.md'"'"'s class (c) exactly'

n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"action":"hang","ignore_hardstop_ms":60000}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_HARDSTOP_MS=100 YSTACK_TEST_SIGKILL_MS=250 YSTACK_TEST_POLL_INTERVAL_MS=20 \
  run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "delayed-stop/SIGKILL: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
wall_reached=$("$jq_bin" -r '.body.limits.wall_time_ms.reached' "$store_root/$attempt_id/receipt.json")
verdict=$("$jq_bin" -r '.body.outcome.verdict' "$store_root/$attempt_id/receipt.json")
reasons=$("$jq_bin" -c -S '.body.outcome.reason_ids' "$store_root/$attempt_id/receipt.json")
expect_reasons='["failure.enforcement-unavailable","failure.observation-unavailable","failure.runtime","failure.teardown"]'
[ "$runtime" = error ] && [ "$teardown_state" = unconfirmed ] && [ "$wall_reached" = true ] &&
  [ "$verdict" = failed ] && [ "$reasons" = "$expect_reasons" ] ||
  fail "delayed-stop/SIGKILL: expected runtime error, teardown.state unconfirmed, wall_time_ms.reached true (HardStop was attempted before the SIGKILL escalation), reasons $expect_reasons -- got $runtime/$teardown_state wall_reached=$wall_reached verdict=$verdict reasons=$reasons"
pass 'a runtime that ignores HardStop (still reporting running) past the second, SIGKILL deadline is killed (test-shortened deadlines): lifecycle.runtime error, teardown.state unconfirmed (the process was never confirmed stopped, so the export it never wrote leaves every guest row unavailable too, and teardown itself is not confirmed), limits.wall_time_ms.reached true (HardStop was still attempted first), outcome exactly failure.enforcement-unavailable + failure.observation-unavailable + failure.runtime + failure.teardown'

# Self-stop: the runtime transitions to stopped on its own after a short
# scripted delay, never receiving a HardStop -- a plain, clean completion.
scenario_case 'self-stop after a short scripted delay' '{"self_stop_after_ms":80}'
attempt_id="$scn_attempt_id"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = completed ] && [ "$teardown_state" = confirmed ] ||
  fail "self-stop: expected runtime completed, teardown.state confirmed, got $runtime/$teardown_state"
pass 'a runtime that self-stops on its own after a short scripted delay, never HardStopped, completes cleanly: lifecycle.runtime completed, teardown.state confirmed'

# R9.2: cancellation (SIGTERM after admission) takes the HardStop path
# immediately, same as an unresponsive runtime timing out.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"action":"hang"}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
( CDPATH='' cd -- "$install_dir" \
    && YSTACK_TEST_HARDSTOP_MS=60000 YSTACK_TEST_SIGKILL_MS=65000 YSTACK_TEST_POLL_INTERVAL_MS=20 \
       exec "$python" host-supervisor.py launch ) <"$base/pkg-scn.json" >"$base/out" 2>"$base/err" &
launch_pid=$!
# Poll for the fake runtime's own "running" mailbox write (rest.sock),
# so the signal lands once the host is inside run_vm's poll loop with its
# own SIGINT/SIGTERM/SIGHUP handlers installed -- a blind sleep risked the
# signal arriving before that (killing the process with its default
# disposition, exit 143, rather than exercising R9.2's own HardStop path).
socket_wait="$work_root/$attempt_id/rest.sock"
for _ in $(seq 1 100); do
  [ -e "$socket_wait" ] && grep -q running "$socket_wait" 2>/dev/null && break
  sleep 0.02
done
kill -TERM "$launch_pid" 2>/dev/null || :
status=0
wait "$launch_pid" || status=$?
[ "$status" -eq 0 ] || fail "cancellation: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
verdict=$("$jq_bin" -r '.body.outcome.verdict' "$store_root/$attempt_id/receipt.json")
reasons=$("$jq_bin" -c -S '.body.outcome.reason_ids' "$store_root/$attempt_id/receipt.json")
expect_reasons='["failure.enforcement-unavailable","failure.observation-unavailable","failure.runtime"]'
[ "$runtime" = error ] && [ "$teardown_state" = confirmed ] && [ "$verdict" = failed ] &&
  [ "$reasons" = "$expect_reasons" ] ||
  fail "cancellation: expected lifecycle.runtime error, teardown.state confirmed, verdict failed, reasons $expect_reasons -- got $runtime/$teardown_state verdict=$verdict reasons=$reasons"
pass 'a SIGTERM delivered to the host process mid-launch (R9.2) takes the HardStop path immediately (same as a deadline timeout, so the same no-clean-export consequence applies) and still yields a full receipt: lifecycle.runtime error, teardown.state confirmed, outcome exactly failure.enforcement-unavailable + failure.observation-unavailable + failure.runtime'

# A runtime that crashes (nonzero exit, never writes an export) never
# confirms the tree stopped: teardown.state unconfirmed, runtime error.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"action":"crash"}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "crash: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
verdict=$("$jq_bin" -r '.body.outcome.verdict' "$store_root/$attempt_id/receipt.json")
reasons=$("$jq_bin" -c -S '.body.outcome.reason_ids' "$store_root/$attempt_id/receipt.json")
expect_reasons='["failure.enforcement-unavailable","failure.observation-unavailable","failure.runtime","failure.teardown"]'
[ "$runtime" = error ] && [ "$teardown_state" = unconfirmed ] && [ "$verdict" = failed ] &&
  [ "$reasons" = "$expect_reasons" ] ||
  fail "crash: expected runtime error, teardown.state unconfirmed, reasons $expect_reasons -- got $runtime/$teardown_state verdict=$verdict reasons=$reasons"
pass 'a runtime that crashes (nonzero exit, no export written) never confirms the tree stopped: lifecycle.runtime error, teardown.state unconfirmed, outcome exactly failure.enforcement-unavailable + failure.observation-unavailable + failure.runtime + failure.teardown'

# R8.2: an absent export (the runtime stops cleanly but never writes one)
# and a damaged export (a truncated frame) each refuse validation --
# every guest row unavailable, lifecycle.runtime error -- even though the
# tree itself is confirmed stopped.
scenario_case 'absent export' '{"action":"no_export"}'
attempt_id="$scn_attempt_id"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
cpu_obs=$("$jq_bin" -r '.body.limits.cpu_time_ms.observation' "$store_root/$attempt_id/receipt.json")
verdict=$("$jq_bin" -r '.body.outcome.verdict' "$store_root/$attempt_id/receipt.json")
reasons=$("$jq_bin" -c -S '.body.outcome.reason_ids' "$store_root/$attempt_id/receipt.json")
expect_reasons='["failure.enforcement-unavailable","failure.observation-unavailable","failure.runtime"]'
[ "$runtime" = error ] && [ "$teardown_state" = confirmed ] && [ "$cpu_obs" = unavailable ] &&
  [ "$verdict" = failed ] && [ "$reasons" = "$expect_reasons" ] ||
  fail "absent export: expected runtime error, teardown.state confirmed, limits.cpu_time_ms.observation unavailable, reasons $expect_reasons -- got $runtime/$teardown_state cpu_obs=$cpu_obs verdict=$verdict reasons=$reasons"
pass 'a runtime that stops cleanly but never writes an export refuses validation: lifecycle.runtime error, teardown.state confirmed, every guest row observation unavailable, outcome exactly failure.enforcement-unavailable + failure.observation-unavailable + failure.runtime'

scenario_case 'damaged export' '{"damage_export":true}'
attempt_id="$scn_attempt_id"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
verdict=$("$jq_bin" -r '.body.outcome.verdict' "$store_root/$attempt_id/receipt.json")
reasons=$("$jq_bin" -c -S '.body.outcome.reason_ids' "$store_root/$attempt_id/receipt.json")
expect_reasons='["failure.enforcement-unavailable","failure.observation-unavailable","failure.runtime"]'
[ "$runtime" = error ] && [ "$teardown_state" = confirmed ] && [ "$verdict" = failed ] &&
  [ "$reasons" = "$expect_reasons" ] ||
  fail "damaged export: expected lifecycle.runtime error, teardown.state confirmed, reasons $expect_reasons -- got $runtime/$teardown_state verdict=$verdict reasons=$reasons"
pass 'a truncated (damaged) export frame refuses validation the same way as an absent one: lifecycle.runtime error'

# =============================================================================
# R15.1 class (c) against the merged checker: every launch-path case above,
# rebuilt with control_real:true (so the checker's own control/policy
# checks agree with the host's), cross-checked through
# enforcement/v1/check-sandbox-receipt.sh in the temporary checker_root2 --
# bindings intact so check_verdict is always "valid", and
# enforcement_verdict (the checker's own independent derive_outcome,
# recomputed from the receipt's recorded fields, never trusting
# body.outcome) equals the host's own outcome.verdict in every case.
#
# restore_control (real shipped control/evaluator bytes over the
# installed placeholders) happens here, not earlier: every class (c) pkg
# below sets control_real:true to match, but every scenario_case/manual
# launch test earlier in this section did not, and would mismatch
# (launch.control-mismatch) against real bytes it never declared.
# =============================================================================
restore_control
checker_root2="$base/checker2"
/bin/mkdir -p "$checker_root2/enforcement/v1" "$checker_root2/control/v1" "$checker_root2/shadow/v1"
/bin/cp "$root/enforcement/v1/check-sandbox-receipt.sh" "$root/enforcement/v1/sandbox-receipt.jq" \
  "$checker_root2/enforcement/v1/"
/bin/cp "$installed_control_policy" "$checker_root2/control/v1/sandbox-policy.json"
/bin/cp "$installed_control_decision" "$checker_root2/control/v1/sandbox-decision.json"
/bin/cp "$installed_control_policy_set" "$checker_root2/control/v1/control-policy-set.json"
/bin/cp "$registry_path" "$checker_root2/shadow/v1/shadow-environments.json"
/bin/cp "$accepted_set" "$checker_root2/enforcement/v1/accepted-identities.json"
class_c_setup() { # class_c_setup <scenario-json> -- writes scenario, builds the pkg
  # (control_real, expectation/evaluation out), sets $cc_attempt_id
  n=$((n + 1))
  cc_attempt_id="attempt.fixture-cc-$n"
  printf '%s' "$1" > "$scenario_path"
  build_pkg "$base/pkg-cc.json" '{"attempt_id":"'"$cc_attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'","control_real":true,"expectation_out":"'"$base/expectation.json"'","evaluation_out":"'"$base/evaluation.json"'"}'
}
class_c_check() { # class_c_check <desc> <expect-enforcement-verdict> -- run_launch
  # already done by the caller; asserts checker agreement with the host
  local out cv rv ev host_verdict
  out=$("$jq_bin" -c . <(PATH="$jq_dir:$PATH" bash "$checker_root2/enforcement/v1/check-sandbox-receipt.sh" \
    check "$store_root/$cc_attempt_id/receipt.json" "$base/expectation.json" "$base/evaluation.json"))
  cv=$("$jq_bin" -r '.body.check_verdict' <<<"$out")
  rv=$("$jq_bin" -c -S '.body.reason_ids' <<<"$out")
  ev=$("$jq_bin" -r '.body.enforcement_verdict' <<<"$out")
  host_verdict=$("$jq_bin" -r '.body.outcome.verdict' "$store_root/$cc_attempt_id/receipt.json")
  [ "$cv" = valid ] && [ "$rv" = '["receipt.valid"]' ] && [ "$ev" = "$2" ] && [ "$ev" = "$host_verdict" ] ||
    fail "$1: checker expected valid/[receipt.valid]/$2 matching the host's own $host_verdict -- got $cv/$rv/$ev"
}

class_c_setup '{}'
run_launch "$base/pkg-cc.json"
class_c_check 'class (c): success' failed

class_c_setup '{"limit_overrides":{"memory_bytes":{"reached":true,"observed":536870913}}}'
run_launch "$base/pkg-cc.json"
class_c_check 'class (c): violation (a guest row reached, still failed -- never violated, R7.2)' failed

class_c_setup '{"report_overrides":{"tree_deadline_fired":true}}'
run_launch "$base/pkg-cc.json"
class_c_check 'class (c): guest tree_deadline_fired' failed

class_c_setup '{"action":"hang"}'
YSTACK_TEST_HARDSTOP_MS=150 YSTACK_TEST_SIGKILL_MS=5000 YSTACK_TEST_POLL_INTERVAL_MS=20 \
  run_launch "$base/pkg-cc.json"
class_c_check 'class (c): host HardStop' failed

class_c_setup '{"action":"hang"}'
( CDPATH='' cd -- "$install_dir" \
    && YSTACK_TEST_HARDSTOP_MS=60000 YSTACK_TEST_SIGKILL_MS=65000 YSTACK_TEST_POLL_INTERVAL_MS=20 \
       exec "$python" host-supervisor.py launch ) <"$base/pkg-cc.json" >"$base/out" 2>"$base/err" &
launch_pid=$!
socket_wait="$work_root/$cc_attempt_id/rest.sock"
for _ in $(seq 1 100); do
  [ -e "$socket_wait" ] && grep -q running "$socket_wait" 2>/dev/null && break
  sleep 0.02
done
kill -TERM "$launch_pid" 2>/dev/null || :
wait "$launch_pid" || :
class_c_check 'class (c): cancellation (SIGTERM)' failed

class_c_setup '{"action":"crash"}'
run_launch "$base/pkg-cc.json"
class_c_check 'class (c): runtime error (crash)' failed

class_c_setup '{"damage_export":true}'
run_launch "$base/pkg-cc.json"
class_c_check 'class (c): damaged export' failed

class_c_setup '{"action":"no_export"}'
run_launch "$base/pkg-cc.json"
class_c_check 'class (c): absent export' failed

class_c_setup '{"action":"hang","ignore_hardstop_ms":60000}'
YSTACK_TEST_HARDSTOP_MS=100 YSTACK_TEST_SIGKILL_MS=250 YSTACK_TEST_POLL_INTERVAL_MS=20 \
  run_launch "$base/pkg-cc.json"
class_c_check 'class (c): delayed stop (ignores HardStop, killed at the SIGKILL deadline)' failed

class_c_setup '{}'
YSTACK_TEST_TEARDOWN_FAIL=1 run_launch "$base/pkg-cc.json"
class_c_check 'class (c): storage removal failure' failed

class_c_setup '{"limit_overrides":{"output_bytes":{"observation":"partial","enforcement":"unknown"}}}'
run_launch "$base/pkg-cc.json"
class_c_check 'class (c): a partial row' failed

class_c_setup '{"limit_overrides":{"process_count":{"observation":"unavailable","enforcement":"unknown","observed":null}}}'
run_launch "$base/pkg-cc.json"
class_c_check 'class (c): an unavailable row' failed
pass 'every launch-path class (c) case (success, violation, guest deadline, host HardStop, cancellation, runtime error, damaged export, absent export, delayed stop, storage removal failure, a partial row and an unavailable row), run through the merged check-sandbox-receipt.sh with control_real bindings intact, gives check_verdict valid and enforcement_verdict exactly equal to the host'"'"'s own outcome.verdict (failed in every case here, per R7.2'"'"'s permanent limitation)'

# The edited-hard copies: the same success and violation receipts above,
# with limits.cpu_time_ms.enforcement and limits.wall_time_ms.enforcement
# set to "hard" and body.outcome recomputed to match (host-supervisor.py's
# own derive_outcome, reused so this is the same formula, not a second
# hand-rolled copy) -- the checker's *independent* jq derive_outcome, which
# never trusts the stored body.outcome, must still recompute exactly
# "satisfied" for the untouched-limits copy and "violated" (with the
# matching limit.*-reached reason) for the reached copy, equal to what the
# host would derive if these two rows ever got a route to hard (R7.2).
edit_hard_copy() { # edit_hard_copy <in-receipt> <out-receipt>
  "$python" -c "
import sys, json, importlib.util
spec = importlib.util.spec_from_file_location('hs', '$supervisor_src')
hs = importlib.util.module_from_spec(spec); spec.loader.exec_module(hs)
doc = json.loads(open(sys.argv[1], 'rb').read())
body = doc['body']
body['limits']['cpu_time_ms']['enforcement'] = 'hard'
body['limits']['wall_time_ms']['enforcement'] = 'hard'
body['outcome'] = hs.derive_outcome(body)
open(sys.argv[2], 'wb').write(hs.canonical(doc))
" "$1" "$2"
}
class_c_setup '{}'
run_launch "$base/pkg-cc.json"
edit_hard_copy "$store_root/$cc_attempt_id/receipt.json" "$base/receipt-hard-ok.json"
out=$("$jq_bin" -c . <(PATH="$jq_dir:$PATH" bash "$checker_root2/enforcement/v1/check-sandbox-receipt.sh" \
  check "$base/receipt-hard-ok.json" "$base/expectation.json" "$base/evaluation.json"))
cv=$("$jq_bin" -r '.body.check_verdict' <<<"$out")
ev=$("$jq_bin" -r '.body.enforcement_verdict' <<<"$out")
rv=$("$jq_bin" -c -S '.body.reason_ids' <<<"$out")
[ "$cv" = valid ] && [ "$ev" = satisfied ] && [ "$rv" = '["receipt.valid"]' ] ||
  fail "edited-hard success copy: expected valid/satisfied, got $cv/$ev/$rv"

class_c_setup '{"limit_overrides":{"memory_bytes":{"reached":true,"observed":536870913}}}'
run_launch "$base/pkg-cc.json"
edit_hard_copy "$store_root/$cc_attempt_id/receipt.json" "$base/receipt-hard-violated.json"
out=$("$jq_bin" -c . <(PATH="$jq_dir:$PATH" bash "$checker_root2/enforcement/v1/check-sandbox-receipt.sh" \
  check "$base/receipt-hard-violated.json" "$base/expectation.json" "$base/evaluation.json"))
cv=$("$jq_bin" -r '.body.check_verdict' <<<"$out")
ev=$("$jq_bin" -r '.body.enforcement_verdict' <<<"$out")
host_reasons=$("$python" -c "
import json
print(json.loads(open('$base/receipt-hard-violated.json','rb').read())['body']['outcome']['reason_ids'])
")
[ "$cv" = valid ] && [ "$ev" = violated ] ||
  fail "edited-hard violated copy: expected valid/violated, got $cv/$ev (host's own recomputed reason_ids: $host_reasons)"
pass 'a copy of each of the success and violation receipts above, edited only to set limits.cpu_time_ms/wall_time_ms.enforcement to hard and outcome recomputed by host-supervisor.py'"'"'s own derive_outcome, is independently re-derived by the merged checker'"'"'s own jq derive_outcome (never trusting the stored body.outcome) to exactly satisfied and violated respectively -- the two formulas agree'

# =============================================================================
# Fix round 1 (findings-477-r1.md): one test per finding.
# =============================================================================
# A fresh tree: the round-0 class (c) section above called restore_control
# (real shipped control/evaluator bytes over the installed placeholders),
# but none of these findings tests set control_real:true, so they'd
# otherwise mismatch (launch.control-mismatch) against real bytes they
# never declared -- refused, not admitted, before run_vm is ever reached.
build_tree 0
scenario_path="$base/scenario-case.json"
export YSTACK_FAKE_SCENARIO="$scenario_path"

# Finding 1 [P1]: teardown confirmed only after a successful reap.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"self_stop_after_ms":20}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_REAP_FAIL=1 run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 1: expected exit 0, got $status ($(cat "$base/err"))"
tree_terminated=$("$jq_bin" -r '.body.teardown.tree_terminated' "$store_root/$attempt_id/receipt.json")
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
[ "$tree_terminated" = false ] && [ "$teardown_state" = unconfirmed ] ||
  fail "finding 1: expected teardown.tree_terminated false, state unconfirmed (driver said stopped but the reap -- YSTACK_TEST_REAP_FAIL -- never confirmed it), got $tree_terminated/$teardown_state"
pass 'finding 1: a driver report of stopped whose process is never successfully reaped (YSTACK_TEST_REAP_FAIL simulating a waitpid timeout) is never confirmed terminated: teardown.tree_terminated false, teardown.state unconfirmed, not runtime completed'

# Finding 2 [P1]: cancellation handled throughout the admitted attempt --
# (a) a signal before the runtime is even spawned (during a slowed-down
# disk-prep/runtime-start window) and (b) a signal during finalization,
# after the runtime already stopped cleanly.
# Both delivered deterministically (self-signaled from inside the host
# process at the exact call site, YSTACK_TEST_SELF_SIGNAL_*), not raced
# from an external `kill` against a wall-clock sleep: an external timer
# can't guarantee it lands in the intended window on a slower or more
# loaded host -- exactly what made this flaky on Linux CI (an admitted,
# real Linux run of finding 2b below: the external sleep elapsed while
# the target process was still inside phase A/B/freeze/spawn, so the
# signal landed as a genuine, correct mid-run cancellation instead of
# the finalization-window case it meant to test).
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"action":"hang"}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_SELF_SIGNAL_BEFORE_SPAWN=TERM YSTACK_TEST_HARDSTOP_MS=60000 YSTACK_TEST_SIGKILL_MS=65000 \
  YSTACK_TEST_POLL_INTERVAL_MS=20 run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 2a: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] ||
  fail "finding 2a: expected lifecycle.runtime error (a signal before the runtime was even spawned must still be caught), got $runtime"
pass 'finding 2a: a SIGTERM delivered before the runtime is spawned (self-signaled at the top of run_vm, before disk prep) is still caught -- handlers are installed at admission, before freeze/disk-prep/spawn, not just around the poll loop -- and the eventual launch still takes the HardStop path and yields a receipt: lifecycle.runtime error'

n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_SELF_SIGNAL_AT_FINALIZE=TERM run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 2b: expected exit 0, got $status ($(cat "$base/err"))"
[ -f "$store_root/$attempt_id/receipt.json" ] || fail "finding 2b: expected a receipt to still be written"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = completed ] ||
  fail "finding 2b: expected lifecycle.runtime completed (the runtime had already stopped cleanly before the signal arrived, mid-finalization), got $runtime"
pass 'finding 2b: a SIGTERM delivered during finalization (self-signaled after the runtime already stopped cleanly and storage was removed, only payload/receipt writing left) does not abort finalization: handlers stay installed (a no-op past this point) through cleanup, and the receipt is still written, honestly reflecting the clean run that already happened: lifecycle.runtime completed'

# Finding 3 [P2]: the monotonic clock starts at admission.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_SLOW_RUNTIME_START_MS=300 run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 3: expected exit 0, got $status ($(cat "$base/err"))"
wall_observed=$("$jq_bin" -r '.body.limits.wall_time_ms.observed' "$store_root/$attempt_id/receipt.json")
[ "$wall_observed" -ge 300 ] ||
  fail "finding 3: expected limits.wall_time_ms.observed >= 300 (measured from admission, through a 300ms slowed disk-prep/runtime-start phase, not reset when the runtime actually spawns), got $wall_observed"
pass 'finding 3: limits.wall_time_ms.observed includes a slowed-down disk-prep/runtime-start phase (YSTACK_TEST_SLOW_RUNTIME_START_MS=300ms) -- the clock starts at admission (R9.1), carried into run_vm, not reset when the runtime spawns'

# Finding 4 [P2]: preserve a runtime error/abnormal exit through reaping.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"action":"stopped_then_bad_exit"}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 4: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] ||
  fail "finding 4: expected lifecycle.runtime error (the driver mailbox said stopped, but the process then exited abnormally), got $runtime"
pass 'finding 4: a runtime that reports stopped via the driver mailbox but then exits with an abnormal code anyway is still lifecycle.runtime error, never silently accepted as completed just because the mailbox alone said stopped'

# Finding 5 [P2]: control_deadline exceeded for each of the four windows,
# finalized only after payload writing.
control_deadline_case() { # control_deadline_case <desc> <env-assignments> <scenario-json>
  n=$((n + 1))
  local case_attempt="attempt.fixture-scn-$n" cd_status=0 cd_val reasons
  printf '%s' "$3" > "$scenario_path"
  build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$case_attempt"'","nonce":"'"$(printf '%064d' "$n")"'"}'
  eval "$2 run_launch \"\$base/pkg-scn.json\"" || cd_status=$?
  [ "$cd_status" -eq 0 ] || fail "$1: expected exit 0, got $cd_status ($(cat "$base/err"))"
  cd_val=$("$jq_bin" -r '.body.lifecycle.control_deadline' "$store_root/$case_attempt/receipt.json")
  reasons=$("$jq_bin" -c -S '.body.outcome.reason_ids' "$store_root/$case_attempt/receipt.json")
  local has_timeout=0
  if printf '%s' "$reasons" | grep -q "failure.supervisor-timeout"; then has_timeout=1; fi
  if [ "$cd_val" != exceeded ] || [ "$has_timeout" -ne 1 ]; then
    fail "$1: expected control_deadline exceeded with failure.supervisor-timeout, got $cd_val / $reasons"
  fi
  pass "$1"
}
control_deadline_case 'finding 5a: a slowed runtime start past its (lowered) limit records control_deadline exceeded / failure.supervisor-timeout' \
  'YSTACK_TEST_RUNTIME_START_LIMIT_MS=50 YSTACK_TEST_SLOW_RUNTIME_START_MS=150' '{}'
control_deadline_case 'finding 5b: a slowed export read past its (lowered) limit records control_deadline exceeded / failure.supervisor-timeout' \
  'YSTACK_TEST_EXPORT_READ_LIMIT_MS=50 YSTACK_TEST_SLOW_EXPORT_READ_MS=150' '{}'
control_deadline_case 'finding 5c: a slowed storage removal past its (lowered) limit records control_deadline exceeded / failure.supervisor-timeout' \
  'YSTACK_TEST_STORAGE_REMOVAL_LIMIT_MS=50 YSTACK_TEST_SLOW_STORAGE_REMOVAL_MS=150' '{}'
control_deadline_case 'finding 5d: a slowed payload write past its (lowered) limit records control_deadline exceeded / failure.supervisor-timeout -- the lifecycle is finalized only after payload writing, so this window is included at all' \
  'YSTACK_TEST_PAYLOAD_WRITE_LIMIT_MS=50 YSTACK_TEST_SLOW_PAYLOAD_WRITE_MS=150' '{}'

# Finding 6 [P2]: persist exported evidence bytes before the export disk
# is removed.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"evidence":[{"index":0,"name":"file-digest-result.json","content":"hello evidence"}],"limit_overrides":{"output_bytes":{"observed":14}}}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 6: expected exit 0, got $status ($(cat "$base/err"))"
name_hex=$(printf '%s' "file-digest-result.json" | od -An -tx1 | tr -d ' \n')
[ -f "$store_root/$attempt_id/payload/evidence/0000" ] ||
  fail "finding 6: expected payload/evidence/0000 (stored by index, not by name_hex) to exist in the receipt store"
[ "$(cat "$store_root/$attempt_id/payload/evidence/0000")" = "hello evidence" ] ||
  fail "finding 6: expected the stored evidence file's content to match what the fake runtime exported"
"$jq_bin" -c '.body.files' "$store_root/$attempt_id/payload/evidence-manifest.json" | grep -q "$name_hex" ||
  fail "finding 6: expected the manifest to list $name_hex (the real verifier's own evidence filename, file-digest-result.json, hex-encoded -- 44 characters, not a 64-character digest)"
# findings-477-r6.md finding 3 (spec R10.2): the evidence subdirectory
# and its file carry the same store mode/ownership as every other store
# entry -- 0750 dir, 0440 file, principal_uid:consumer_gid.
"$python" -c "
import os, sys
d = sys.argv[1]; f = sys.argv[2]; uid = int(sys.argv[3]); gid = int(sys.argv[4])
dst, fst = os.lstat(d), os.lstat(f)
assert dst.st_mode & 0o7777 == 0o750, oct(dst.st_mode)
assert dst.st_uid == uid and dst.st_gid == gid
assert fst.st_mode & 0o7777 == 0o440, oct(fst.st_mode)
assert fst.st_uid == uid and fst.st_gid == gid and fst.st_nlink == 1
print('ok')
" "$store_root/$attempt_id/payload/evidence" "$store_root/$attempt_id/payload/evidence/0000" "$(id -u)" "$(id -g)" >/dev/null \
  || fail "finding 3 (r6): expected payload/evidence/ (0750) and payload/evidence/0000 (0440) with the store's owner/group"
pass 'finding 6/3(r6): an exported evidence file'"'"'s actual bytes are persisted into payload/evidence/<index> (stored by index, never by its own -- potentially long -- filename, in the required evidence/ subdirectory at the store'"'"'s standard mode/ownership) in the receipt store before remove_frozen deletes the export disk, with that real filename (file-digest-result.json) recorded in the manifest'

# Finding 7 [P2]: validate every report field's type/range/exit-state
# consistency before use.
for override in '{"evidence_files":null}' '{"exit_code":"0"}' '{"tree_terminated":1}' '{"stdout_bytes":-1}'; do
  n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
  printf '%s' '{"report_overrides":'"$override"'}' > "$scenario_path"
  build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
  status=0
  run_launch "$base/pkg-scn.json" || status=$?
  [ "$status" -eq 0 ] || fail "finding 7 ($override): expected exit 0 (a graceful unavailable-export result, never an uncaught exception), got $status ($(cat "$base/err"))"
  runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
  cpu_obs=$("$jq_bin" -r '.body.limits.cpu_time_ms.observation' "$store_root/$attempt_id/receipt.json")
  [ "$runtime" = error ] && [ "$cpu_obs" = unavailable ] ||
    fail "finding 7 ($override): expected runtime error, cpu_time_ms.observation unavailable, got $runtime/$cpu_obs"
done
pass 'finding 7: a checksummed report with evidence_files: null, a string exit_code, a non-bool tree_terminated or a negative stdout_bytes is each refused as a malformed report (the normal unavailable-export result), never an uncaught TypeError/exception abandoning cleanup and the receipt'

# Finding 8 [P2]: reconcile the reported output total, and require an
# exact evidence inventory.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"stdout":"abc","limit_overrides":{"output_bytes":{"observed":0}}}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 8a: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] ||
  fail "finding 8a: expected lifecycle.runtime error (3 stdout bytes vs. a complete output_bytes.observed of 0 must not reconcile), got $runtime"
pass 'finding 8a: the reported output total (stdout + stderr + every declared evidence record) is reconciled against a complete output_bytes.observed -- a mismatch (3 stdout bytes, observed 0) refuses the whole report'

n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"extra_undeclared_evidence":true}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 8b: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] ||
  fail "finding 8b: expected lifecycle.runtime error (an evidence/9999 frame record never declared in evidence_files must refuse the report), got $runtime"
pass 'finding 8b: an exact evidence inventory is required (R8.2) -- a frame record under evidence/ that evidence_files never declared refuses the whole report, even though every declared entry alone still checks out fine'

# Finding 9 [P2]: refused receipts hash the same stored empty-manifest
# bytes the payload writer produces.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
build_pkg "$base/pkg-refused.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'","instruction":"unaccepted-instr"}'
status=0
run_launch "$base/pkg-refused.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 9: expected exit 0 (a refusal receipt), got $status ($(cat "$base/err"))"
admission=$("$jq_bin" -r '.body.lifecycle.admission' "$store_root/$attempt_id/receipt.json")
[ "$admission" = refused ] || fail "finding 9: expected this fixture to actually be refused, got $admission"
receipt_manifest_sha=$("$jq_bin" -r '.body.payload.evidence_manifest_sha256' "$store_root/$attempt_id/receipt.json")
stored_manifest_sha=$(sha_file "$store_root/$attempt_id/payload/evidence-manifest.json")
[ "$receipt_manifest_sha" = "$stored_manifest_sha" ] ||
  fail "finding 9: expected the refused receipt's payload.evidence_manifest_sha256 ($receipt_manifest_sha) to equal the stored manifest's own digest ($stored_manifest_sha)"
[ "$receipt_manifest_sha" != "$(sha_file /dev/null)" ] ||
  fail "finding 9: expected the nonempty canonical manifest's digest, not the empty-string sha256 regression"
pass "finding 9: a refused receipt's payload.evidence_manifest_sha256 equals the stored (nonempty, canonical) evidence-manifest.json's own digest, not empty_sha256() -- the same PR 4 fix this round's build_receipt rewrite had regressed"

# Finding 10 [P2]: a launch-file write failure is cleaned up and still
# yields a receipt, like a freeze failure, not the exit-70 path.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_LAUNCH_WRITE_FAIL=1 run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 10: expected exit 0 (a receipt, not exit 70), got $status ($(cat "$base/err"))"
[ ! -e "$work_root/$attempt_id" ] || fail "finding 10: expected the partial attempt directory to be cleaned up"
[ -f "$store_root/$attempt_id/receipt.json" ] || fail "finding 10: expected a receipt to still be written"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] || fail "finding 10: expected lifecycle.runtime error, got $runtime"
pass 'finding 10: a launch-file write failure (input.img/export.img/start.json/runtime.log, simulated via YSTACK_TEST_LAUNCH_WRITE_FAIL) is handled exactly like a freeze failure (R10.4): the partial attempt directory is cleaned up and an honest runtime-error receipt is still written, never the outer exit-70/E_STORE_WRITE path'

# Finding 11 [P2]: bound driver output while reading it.
default_scenario_path="$(dirname "$driver_path")/scenario.json"
printf '%s' '{"oversized_argv":true}' > "$default_scenario_path"
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
run_launch "$base/pkg-scn.json" || status=$?
printf '%s' '{}' > "$default_scenario_path"
[ "$status" -eq 0 ] || fail "finding 11: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] ||
  fail "finding 11: expected lifecycle.runtime error (a driver argv call emitting more than the 65,536-byte interface cap must be a hard failure), got $runtime"
pass 'finding 11: a driver whose argv call emits more than the fixed 65,536-byte interface cap is a hard failure (read with a bounded os.read/select loop, never subprocess.run'"'"'s own unbounded PIPE buffering): lifecycle.runtime error via the same stub path as any other argv-parse failure'

# Finding 12 [P2]: wall_time_ms.reached from any issued host stop
# (cancellation included, not just a deadline-issued HardStop).
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"action":"hang"}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
( CDPATH='' cd -- "$install_dir" \
    && YSTACK_TEST_HARDSTOP_MS=60000 YSTACK_TEST_SIGKILL_MS=65000 YSTACK_TEST_POLL_INTERVAL_MS=20 \
       exec "$python" host-supervisor.py launch ) <"$base/pkg-scn.json" >"$base/out" 2>"$base/err" &
launch_pid=$!
socket_wait="$work_root/$attempt_id/rest.sock"
for _ in $(seq 1 100); do
  [ -e "$socket_wait" ] && grep -q running "$socket_wait" 2>/dev/null && break
  sleep 0.02
done
kill -TERM "$launch_pid" 2>/dev/null || :
wait "$launch_pid" || :
wall_reached=$("$jq_bin" -r '.body.limits.wall_time_ms.reached' "$store_root/$attempt_id/receipt.json")
[ "$wall_reached" = true ] ||
  fail "finding 12: expected limits.wall_time_ms.reached true for a cancellation-issued stop (not just a deadline-issued HardStop), got $wall_reached"
pass 'finding 12: wall_time_ms.reached is true for a cancellation-issued stop too, not only a deadline-issued HardStop -- build_limit_rows folds every issued host stop (HardStop or cancellation), the guest deadline, and observed >= bound into reached'

# =============================================================================
# Fix round 2 (findings-477-r2.md): one test per finding.
# =============================================================================
build_tree 0
scenario_path="$base/scenario-case.json"
export YSTACK_FAKE_SCENARIO="$scenario_path"

# Finding 1 [P1]: bounded startup readiness for the REST socket, and
# exit-status confirmation before treating an unavailable endpoint as a
# runtime failure.
scenario_case 'startup delay within the (raised) grace window' \
  '{"startup_delay_ms":100}'
attempt_id="$scn_attempt_id"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = completed ] ||
  fail "finding 1a: expected lifecycle.runtime completed (an unavailable endpoint within the startup grace period is not a failure), got $runtime"
pass 'finding 1a: a driver whose REST endpoint takes a moment to exist after Popen (YSTACK_TEST_STARTUP_MS'"'"'s default grace period) is not treated as a runtime failure -- driver_state()==error is tolerated until the startup deadline, then the run completes normally'

n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"action":"exit_no_mailbox"}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_STARTUP_MS=50 YSTACK_TEST_POLL_INTERVAL_MS=20 run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 1b: expected exit 0, got $status ($(cat "$base/err"))"
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
tree_terminated=$("$jq_bin" -r '.body.teardown.tree_terminated' "$store_root/$attempt_id/receipt.json")
[ "$teardown_state" = confirmed ] && [ "$tree_terminated" = true ] ||
  fail "finding 1b: expected teardown.state confirmed, tree_terminated true (the process exited cleanly, code 0, even though its REST endpoint was never available at all) -- got $teardown_state/$tree_terminated"
pass 'finding 1b: past the startup grace period, an unavailable endpoint is confirmed via proc.poll() first -- a process that exited with stopped_exit_status (even having never created its REST endpoint at all) is a confirmed stop, not a driver failure'

# Finding 2 [P2]: cancellation handlers restored only after receipt
# writing and finalization complete. Self-signaled at the exact call
# site (YSTACK_TEST_SELF_SIGNAL_AT_RECEIPT_WRITE), not raced from an
# external `kill` against a wall-clock sleep -- the external-timer
# version of this exact test was flaky on Linux CI (the sleep elapsed
# too early on a slower/more loaded runner, landing the signal while the
# runtime was still genuinely running rather than during the intended
# post-completion receipt-write window; result["cancelled"] was then
# legitimately true, giving the "runtime: error" seen there, which
# was the test's own timing bug, not the product: signal_seen is read
# nowhere after run_vm returns, so a signal genuinely delivered only
# once reaping has already confirmed termination can never retroactively
# change an already-built receipt's lifecycle/rows).
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_SELF_SIGNAL_AT_RECEIPT_WRITE=TERM run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 2: expected exit 0, got $status ($(cat "$base/err"))"
[ -f "$store_root/$attempt_id/receipt.json" ] || fail "finding 2: expected a receipt to still be written"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = completed ] ||
  fail "finding 2: expected lifecycle.runtime completed (the run had already succeeded and been reaped before the signal, mid-receipt-write -- a signal this late can never alter an already-built receipt), got $runtime"
pass 'finding 2: a SIGTERM delivered during the receipt.json write itself (self-signaled, deterministic on any platform) does not abort it and does not alter the already-final lifecycle/rows -- handlers are restored only after write_receipt_file and finalization complete, not before, and signal_seen is never consulted again once run_vm has returned'

# Finding 3 [P2]: bounded nesting + RecursionError on the guest report.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"raw_report_json_depth":2000}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 3: expected exit 0 (an invalid export, never an escaping RecursionError), got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] ||
  fail "finding 3: expected lifecycle.runtime error (a report.json nested 2,000 levels deep is an invalid export), got $runtime"
pass 'finding 3: a report.json nested 2,000 levels deep is refused as an invalid export (bounded_json_nesting reused, RecursionError also caught) -- never escapes run_vm and aborts the supervisor, storage cleanup and receipt production skipped'

# Finding 4 [P2]: nonnegative observations and reached-vs-bound
# consistency, mirroring the checker's own row_ok.
for override in '{"cpu_time_ms":{"observed":-1}}' '{"memory_bytes":{"observed":536870912,"reached":false}}'; do
  n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
  printf '%s' '{"limit_overrides":'"$override"'}' > "$scenario_path"
  build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
  status=0
  run_launch "$base/pkg-scn.json" || status=$?
  [ "$status" -eq 0 ] || fail "finding 4 ($override): expected exit 0, got $status ($(cat "$base/err"))"
  runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
  cpu_obs=$("$jq_bin" -r '.body.limits.cpu_time_ms.observation' "$store_root/$attempt_id/receipt.json")
  [ "$runtime" = error ] && [ "$cpu_obs" = unavailable ] ||
    fail "finding 4 ($override): expected runtime error, cpu_time_ms.observation unavailable, got $runtime/$cpu_obs"
done
pass 'finding 4: a negative observation, or one at/above its bound with reached: false, each refuse the report -- mirrors enforcement/v1/sandbox-receipt.jq'"'"'s own row_ok, which would otherwise reject an admitted receipt as invalid instead of the intended valid failure receipt'

# Finding 5 [P2]: the export frame's exact fixed records and contiguous
# evidence indexes, validated before dict conversion.
for override in '{"duplicate_stdout_record":true}' '{"unknown_record":true}' '{"omit_stdout_record":true}' '{"omit_stderr_record":true}'; do
  n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
  printf '%s' "$override" > "$scenario_path"
  build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
  status=0
  run_launch "$base/pkg-scn.json" || status=$?
  [ "$status" -eq 0 ] || fail "finding 5 ($override): expected exit 0, got $status ($(cat "$base/err"))"
  runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
  [ "$runtime" = error ] ||
    fail "finding 5 ($override): expected lifecycle.runtime error (a malformed frame record sequence must refuse the export), got $runtime"
done
pass 'finding 5: a duplicate stdout record, an unknown record name, or a missing stdout/stderr record each refuse the export as invalid (checked on the raw record list before a dict conversion would silently collapse a duplicate or default a missing one to empty)'

# Finding 6 [P2]: export consumption gated on confirmed termination.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"hang_after_export":true}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_HARDSTOP_MS=100 YSTACK_TEST_SIGKILL_MS=200 YSTACK_TEST_POLL_INTERVAL_MS=20 \
  run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 6: expected exit 0, got $status ($(cat "$base/err"))"
cpu_obs=$("$jq_bin" -r '.body.limits.cpu_time_ms.observation' "$store_root/$attempt_id/receipt.json")
tree_terminated=$("$jq_bin" -r '.body.teardown.tree_terminated' "$store_root/$attempt_id/receipt.json")
[ "$tree_terminated" = false ] && [ "$cpu_obs" = unavailable ] ||
  fail "finding 6: expected teardown.tree_terminated false and every guest row unavailable (a valid, complete export sitting on disk must never be read/trusted without a confirmed stop), got $tree_terminated/$cpu_obs"
pass 'finding 6: export consumption is gated on tree_terminated -- a runtime that wrote a fully valid, complete export frame but then hung (never confirming a stop) still gets every guest row unavailable, never the payload/observations that frame actually contains (R5.3 stop-before-read)'

# Finding 7 [P2]: the deadline clock starts at the phase-B admission
# boundary (after identity hashing), not before it.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_SLOW_PHASE_B_MS=300 run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 7: expected exit 0, got $status ($(cat "$base/err"))"
wall_observed=$("$jq_bin" -r '.body.limits.wall_time_ms.observed' "$store_root/$attempt_id/receipt.json")
[ "$wall_observed" -lt 300 ] ||
  fail "finding 7: expected limits.wall_time_ms.observed < 300 (a slowed-down phase B, BEFORE admission, must not be counted against the R9.1 clock), got $wall_observed"
pass 'finding 7: a slowed-down phase B (identity hashing/validation, YSTACK_TEST_SLOW_PHASE_B_MS=300ms, before admission) is excluded from limits.wall_time_ms.observed -- the clock starts once phase B actually admits the attempt (R4.3/R9.1), not before it, so slow validation can'"'"'t eat into the VM'"'"'s own execution allowance'

# Finding 8 [P2]: the unconfirmed-stop path finalizes immediately after
# SIGKILL, no further blocking wait.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"action":"hang","ignore_hardstop_ms":60000}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
launch_start=$(date +%s)
status=0
YSTACK_TEST_HARDSTOP_MS=100 YSTACK_TEST_SIGKILL_MS=200 YSTACK_TEST_POLL_INTERVAL_MS=20 \
  run_launch "$base/pkg-scn.json" || status=$?
launch_elapsed=$(( $(date +%s) - launch_start ))
[ "$status" -eq 0 ] || fail "finding 8: expected exit 0, got $status ($(cat "$base/err"))"
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
[ "$teardown_state" = unconfirmed ] ||
  fail "finding 8: expected teardown.state unconfirmed, got $teardown_state"
[ "$launch_elapsed" -le 5 ] ||
  fail "finding 8: expected the whole launch to finish in a few seconds (SIGKILL at the ~200ms deadline, no further wait()), took ${launch_elapsed}s instead -- looks like the old double-wait (up to another 10s) regressed"
pass 'finding 8: after the SIGKILL escalation at the (test-shortened) second deadline, the unconfirmed-stop path finalizes immediately -- terminated_at is the abandonment instant, no further proc.wait() (blocking up to another 10s combined) and no second SIGKILL'

# =============================================================================
# Fix round 3 (findings-477-r3.md): one test per finding.
# =============================================================================
build_tree 0
scenario_path="$base/scenario-case.json"
export YSTACK_FAKE_SCENARIO="$scenario_path"
default_scenario_path="$(dirname "$driver_path")/scenario.json"

# Finding 1 [P2]: the absolute abandonment deadline stays active while
# reaping -- bounded by admission_mono + sigkill_deadline_s(), never a
# fresh 5s wait of its own, and no wait at all once already past it.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"exit_delay_ms":2000}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
launch_start=$(date +%s)
status=0
YSTACK_TEST_HARDSTOP_MS=50000 YSTACK_TEST_SIGKILL_MS=300 YSTACK_TEST_POLL_INTERVAL_MS=20 \
  run_launch "$base/pkg-scn.json" || status=$?
launch_elapsed=$(( $(date +%s) - launch_start ))
[ "$status" -eq 0 ] || fail "finding 1: expected exit 0, got $status ($(cat "$base/err"))"
[ "$launch_elapsed" -le 3 ] ||
  fail "finding 1: expected the whole launch to finish within a few seconds (reap bounded by the absolute 300ms-from-admission SIGKILL deadline, not two fresh 5s waits of its own), took ${launch_elapsed}s instead"
pass 'finding 1: reaping is bounded by the same absolute abandonment deadline (admission_mono + sigkill_deadline_s()) as the poll loop itself, not a fresh 5s wait each time -- a driver stopped report whose process then keeps running well past that deadline still finalizes quickly, never the old two-fixed-waits path that could add up to 10s past it'

# Finding 2 [P2]: accept stopped_exit_status as confirmation even after
# HardStop was requested; the HardStop-caused runtime error is still
# recorded separately.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"action":"hang","hardstop_exit_no_mailbox":true}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_HARDSTOP_MS=150 YSTACK_TEST_SIGKILL_MS=5000 YSTACK_TEST_POLL_INTERVAL_MS=20 \
  run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 2: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
tree_terminated=$("$jq_bin" -r '.body.teardown.tree_terminated' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] && [ "$teardown_state" = confirmed ] && [ "$tree_terminated" = true ] ||
  fail "finding 2: expected lifecycle.runtime error (HardStop was still requested), teardown.state confirmed, tree_terminated true (the process genuinely exited with stopped_exit_status and was reaped, confirmed via exit status alone since it never wrote 'stopped' to the mailbox) -- got $runtime/$teardown_state/$tree_terminated"
pass 'finding 2: a runtime that honors HardStop and exits with stopped_exit_status before ever reporting stopped via the mailbox is still a confirmed, reaped stop (teardown.state confirmed) -- HardStop still makes lifecycle.runtime error, kept as a separate fact, never turning a forced-but-clean stop into a falsely unconfirmed teardown'

# Finding 3 [P2]: evidence names are validated as hex-encoded filenames,
# not digests -- already exercised by finding 6's own default scenario,
# which now uses "file-digest-result.json" (44 hex characters) as the
# evidence name; a dedicated case confirms both boundaries.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"evidence":[{"index":0,"name":"file-digest-result.json","content":"x"}],"limit_overrides":{"output_bytes":{"observed":1}}}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 3a: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = completed ] ||
  fail "finding 3a: expected lifecycle.runtime completed (a 44-character hex-encoded filename, file-digest-result.json, is a valid name_hex -- not a sha256 digest), got $runtime"
pass 'finding 3a: a 44-character hex-encoded evidence filename (file-digest-result.json, the real verifier'"'"'s own output name) is accepted -- name_hex is validated as a hex-encoded filename (hex_name_ok), never required to be exactly a 64-character sha256 digest'

n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"evidence":[{"index":0,"name_hex_override":"xyz","content":"x"}],"limit_overrides":{"output_bytes":{"observed":1}}}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 3b: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] ||
  fail "finding 3b: expected lifecycle.runtime error (name_hex 'xyz' is not valid hex at all), got $runtime"
pass 'finding 3b: a name_hex that is not valid hex at all (odd length, non-hex characters) refuses the report'

# Finding 4 [P2]: each evidence index exactly once.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"evidence":[{"index":0,"content":"x"}],"duplicate_evidence_index":true,"limit_overrides":{"output_bytes":{"observed":1}}}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 4: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] ||
  fail "finding 4: expected lifecycle.runtime error (two evidence_files declarations of index 0, with different names, must refuse -- one exported byte can never manufacture two payload files), got $runtime"
pass 'finding 4: two evidence_files declarations of the same index (different names, the same single frame record) refuse the whole report -- each index is required exactly once, and the output sum is computed from the unique exported records only'

# Finding 5 [P2]: startup overruns are preserved on the driver-argv and
# Popen failure paths too, not reset to "met" by stub_run_result.
printf '%s' '{"oversized_argv":true}' > "$default_scenario_path"
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_RUNTIME_START_LIMIT_MS=50 YSTACK_TEST_SLOW_RUNTIME_START_MS=150 \
  run_launch "$base/pkg-scn.json" || status=$?
printf '%s' '{}' > "$default_scenario_path"
[ "$status" -eq 0 ] || fail "finding 5a: expected exit 0, got $status ($(cat "$base/err"))"
cd_val=$("$jq_bin" -r '.body.lifecycle.control_deadline' "$store_root/$attempt_id/receipt.json")
reasons=$("$jq_bin" -c -S '.body.outcome.reason_ids' "$store_root/$attempt_id/receipt.json")
has_timeout=0
if printf '%s' "$reasons" | grep -q "failure.supervisor-timeout"; then has_timeout=1; fi
if [ "$cd_val" != exceeded ] || [ "$has_timeout" -ne 1 ]; then
  fail "finding 5a: expected control_deadline exceeded / failure.supervisor-timeout on a driver-argv failure after a slowed startup, got $cd_val / $reasons"
fi
pass 'finding 5a: a driver-argv failure (oversized response) after the startup budget was already blown still records control_deadline exceeded / failure.supervisor-timeout, not "met" from stub_run_result'"'"'s own former default'

printf '%s' '{"bad_argv_exe":true}' > "$default_scenario_path"
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_RUNTIME_START_LIMIT_MS=50 YSTACK_TEST_SLOW_RUNTIME_START_MS=150 \
  run_launch "$base/pkg-scn.json" || status=$?
printf '%s' '{}' > "$default_scenario_path"
[ "$status" -eq 0 ] || fail "finding 5b: expected exit 0, got $status ($(cat "$base/err"))"
cd_val=$("$jq_bin" -r '.body.lifecycle.control_deadline' "$store_root/$attempt_id/receipt.json")
reasons=$("$jq_bin" -c -S '.body.outcome.reason_ids' "$store_root/$attempt_id/receipt.json")
has_timeout=0
if printf '%s' "$reasons" | grep -q "failure.supervisor-timeout"; then has_timeout=1; fi
if [ "$cd_val" != exceeded ] || [ "$has_timeout" -ne 1 ]; then
  fail "finding 5b: expected control_deadline exceeded / failure.supervisor-timeout on a Popen failure after a slowed startup, got $cd_val / $reasons"
fi
pass 'finding 5b: a Popen failure (a nonexistent executable in the driver'"'"'s own argv response) after the startup budget was already blown still records control_deadline exceeded / failure.supervisor-timeout'

# Finding 6 [P2]: the required real-time default-deadline cases (no
# YSTACK_TEST_HARDSTOP_MS/SIGKILL_MS overrides -- the actual 50,000/
# 58,000ms production constants). ~58-60s wall clock: run concurrently
# as a background pair so the suite grows by ~60s, not ~120s.
# CI SHARD BUDGETING: this pair alone takes roughly a minute; any CI
# timeout/shard split for this test file must account for it.
n=$((n + 1)); attempt_realtime_delayed="attempt.fixture-scn-$n"
printf '%s' '{"action":"hang","ignore_hardstop_ms":600000}' > "$base/scenario-realtime-delayed.json"
build_pkg "$base/pkg-realtime-delayed.json" \
  '{"attempt_id":"'"$attempt_realtime_delayed"'","nonce":"'"$(printf '%064d' "$n")"'"}'
n=$((n + 1)); attempt_realtime_selfstop="attempt.fixture-scn-$n"
printf '%s' '{"self_stop_after_ms":45000}' > "$base/scenario-realtime-selfstop.json"
build_pkg "$base/pkg-realtime-selfstop.json" \
  '{"attempt_id":"'"$attempt_realtime_selfstop"'","nonce":"'"$(printf '%064d' "$n")"'"}'

( CDPATH='' cd -- "$install_dir" && YSTACK_FAKE_SCENARIO="$base/scenario-realtime-delayed.json" \
    exec "$python" host-supervisor.py launch ) \
  <"$base/pkg-realtime-delayed.json" >"$base/out-realtime-delayed" 2>"$base/err-realtime-delayed" &
realtime_delayed_pid=$!
( CDPATH='' cd -- "$install_dir" && YSTACK_FAKE_SCENARIO="$base/scenario-realtime-selfstop.json" \
    exec "$python" host-supervisor.py launch ) \
  <"$base/pkg-realtime-selfstop.json" >"$base/out-realtime-selfstop" 2>"$base/err-realtime-selfstop" &
realtime_selfstop_pid=$!

status_realtime_delayed=0
wait "$realtime_delayed_pid" || status_realtime_delayed=$?
status_realtime_selfstop=0
wait "$realtime_selfstop_pid" || status_realtime_selfstop=$?

[ "$status_realtime_delayed" -eq 0 ] ||
  fail "finding 6 (real-time delayed-stop): expected exit 0, got $status_realtime_delayed ($(cat "$base/err-realtime-delayed"))"
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_realtime_delayed/receipt.json")
[ "$teardown_state" = unconfirmed ] ||
  fail "finding 6 (real-time delayed-stop): expected teardown.state unconfirmed, got $teardown_state"
elapsed_s=$("$python" -c "
import json, datetime
r = json.load(open('$store_root/$attempt_realtime_delayed/receipt.json'))
t = r['body']['timing']
fmt = '%Y-%m-%dT%H:%M:%SZ'
a = datetime.datetime.strptime(t['admitted_at'], fmt)
b = datetime.datetime.strptime(t['terminated_at'], fmt)
print(int((b - a).total_seconds()))
")
[ "$elapsed_s" -ge 55 ] && [ "$elapsed_s" -le 65 ] ||
  fail "finding 6 (real-time delayed-stop): expected terminated_at - admitted_at within [55,65]s of the real 58,000ms SIGKILL deadline, got ${elapsed_s}s"
pass "finding 6 (real-time, production deadlines, ~60s wall clock): a runtime that ignores HardStop is finalized unconfirmed at the real 58,000ms SIGKILL deadline (terminated_at within [55,65]s of admission), not just at a test-shortened one"

[ "$status_realtime_selfstop" -eq 0 ] ||
  fail "finding 6 (real-time self-stop): expected exit 0, got $status_realtime_selfstop ($(cat "$base/err-realtime-selfstop"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_realtime_selfstop/receipt.json")
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_realtime_selfstop/receipt.json")
wall_observed=$("$jq_bin" -r '.body.limits.wall_time_ms.observed' "$store_root/$attempt_realtime_selfstop/receipt.json")
[ "$runtime" = completed ] && [ "$teardown_state" = confirmed ] ||
  fail "finding 6 (real-time self-stop): expected lifecycle.runtime completed, teardown.state confirmed, got $runtime/$teardown_state"
[ "$wall_observed" -ge 44000 ] && [ "$wall_observed" -le 49000 ] ||
  fail "finding 6 (real-time self-stop): expected limits.wall_time_ms.observed within [44000,49000]ms of the scripted 45,000ms self-stop (safely under the real 50,000ms HardStop deadline, so none fires), got ${wall_observed}ms"
pass "finding 6 (real-time, production deadlines, ~45s wall clock): a runtime that self-stops well under the real 50,000/58,000ms HardStop/SIGKILL deadlines completes cleanly with wall_time_ms.observed matching the real elapsed time -- run concurrently with the delayed-stop case above, so this pair together added roughly one minute, not two, to the suite"

# =============================================================================
# Fix round 4 (findings-477-r4.md): one test per finding, against the
# restructured supervision loop.
# =============================================================================
build_tree 0
scenario_path="$base/scenario-case.json"
export YSTACK_FAKE_SCENARIO="$scenario_path"
default_scenario_path="$(dirname "$driver_path")/scenario.json"

# Finding 1 [P1]: a driver-state error after the grace period keeps the
# loop supervising the live process (HardStop/SIGKILL/cancellation still
# enforced), never a bare break into a blind wait.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"action":"hang","startup_delay_ms":150}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_STARTUP_MS=50 YSTACK_TEST_HARDSTOP_MS=400 YSTACK_TEST_SIGKILL_MS=5000 \
  YSTACK_TEST_POLL_INTERVAL_MS=20 run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 1: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] && [ "$teardown_state" = confirmed ] ||
  fail "finding 1: expected lifecycle.runtime error, teardown.state confirmed (a transient driver-state error -- the mailbox doesn't exist until 150ms, past the 50ms grace -- must not disable HardStop at the 400ms deadline once the endpoint recovers), got $runtime/$teardown_state"
pass 'finding 1: a driver-state error observed after the startup grace period (a transient REST-endpoint gap, here outlasting a shortened grace) does not break the loop into a blind proc.wait() -- HardStop is still issued at its deadline and the eventual stop is still confirmed, once the endpoint recovers and honors it'

# Finding 2 [P2]: pending cancellation is checked before every early
# exit, including the very first poll's "stopped" path.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_SELF_SIGNAL_BEFORE_SPAWN=TERM run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 2: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] ||
  fail "finding 2: expected lifecycle.runtime error (cancellation was pending before the runtime was even spawned; the pending cancellation must still be recorded, never reported as a clean completion), got $runtime"
pass 'finding 2: a cancellation signaled before the runtime is spawned still records lifecycle.runtime error -- signal_seen is checked before every early exit; since findings-477-r6.md finding 1a, a cancellation already pending at this point in fact skips the spawn entirely (see "finding 1(a): cancellation pending" below), so this same signal now also proves the driver'"'"'s run subcommand is never invoked at all'

# Finding 3 [P2]: elapsed is recomputed after every blocking driver call
# and polling is bounded by the time remaining to the next deadline, so
# HardStop/SIGKILL still fire close to their real deadlines even when a
# state poll takes most of its own budget.
printf '%s' '{"slow_state_ms":1700}' > "$default_scenario_path"
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"action":"hang"}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_HARDSTOP_MS=3000 YSTACK_TEST_SIGKILL_MS=15000 YSTACK_TEST_POLL_INTERVAL_MS=20 \
  run_launch "$base/pkg-scn.json" || status=$?
printf '%s' '{}' > "$default_scenario_path"
[ "$status" -eq 0 ] || fail "finding 3: expected exit 0, got $status ($(cat "$base/err"))"
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
[ "$teardown_state" = confirmed ] || fail "finding 3: expected teardown.state confirmed, got $teardown_state"
elapsed_s=$("$python" -c "
import json, datetime
r = json.load(open('$store_root/$attempt_id/receipt.json'))
t = r['body']['timing']
fmt = '%Y-%m-%dT%H:%M:%SZ'
a = datetime.datetime.strptime(t['admitted_at'], fmt)
b = datetime.datetime.strptime(t['terminated_at'], fmt)
print(int((b - a).total_seconds()))
")
[ "$elapsed_s" -le 6 ] ||
  fail "finding 3: expected the whole launch (HardStop issued near its 3,000ms deadline, confirmed on the next ~1,700ms-slow poll) to finish within about 6s despite each state poll taking ~1.7s of its own 2,000ms budget, took ${elapsed_s}s instead -- the old stale-elapsed bug would compound an extra ~1.7-3.4s of unnoticed overshoot per missed deadline check"
pass 'finding 3: elapsed is recomputed fresh after every blocking driver_state() call (never reused from before it), and each poll'"'"'s sleep is bounded by the time remaining to the next deadline -- HardStop still fires close to its real 3,000ms (test-shortened) deadline even though each state poll itself takes ~1,700ms of its own budget, not one or more whole extra polls later'

stop_marker="$base/stop-called.marker"
rm -f "$stop_marker"
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{}' > "$scenario_path"
# findings-477-r12ci.md: deterministic, cross-platform version of this
# race -- the fake driver's own "state" subcommand signals
# host-supervisor.py's pid (its own parent) from exactly the poll that
# is about to report "stopped", rather than a host-side self-signal
# hook firing on every poll regardless of the mailbox's own content
# (which raced against the separate "run" subcommand process's own
# completion speed: reliable on macOS, but landed a poll too early on
# Linux CI, where the first "state" call still saw "running").
printf '%s' '{"stop_marker_path":"'"$stop_marker"'","signal_parent_on_stopped":"TERM"}' > "$default_scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
run_launch "$base/pkg-scn.json" || fail "finding 1: expected exit 0"
printf '%s' '{}' > "$default_scenario_path"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] || fail "finding 1: expected lifecycle.runtime error, got $runtime"
# findings-477-r11.md: a cancellation racing a state poll that returns
# "stopped" the very same iteration issues zero stop calls (the loop
# breaks immediately on "stopped", never reaching the stop-request
# branch) -- wall_time_ms.reached must be false, not true just because
# result["cancelled"] happened to be true too.
[ -e "$stop_marker" ] && fail "finding r11: expected driver_stop() never to be called in this race, but its marker file exists"
wall_reached=$("$jq_bin" -r '.body.limits.wall_time_ms.reached' "$store_root/$attempt_id/receipt.json")
[ "$wall_reached" = false ] ||
  fail "finding r11: expected limits.wall_time_ms.reached false (cancellation observed with zero stop calls issued -- a race, not a real HardStop/cancellation-issued stop), got $wall_reached"
pass 'finding 1: a signal delivered by the fake driver'"'"'s own "state" subcommand, from exactly the poll that reports "stopped" (deterministic on any platform since findings-477-r12ci.md), is still folded into cancelled'
pass 'finding r11 (findings-477-r11.md): the same cancel-during-poll-returns-stopped race issues zero stop calls (proven by the absent stop marker) and records wall_time_ms.reached: false, never true from bare cancellation alone'
control_deadline_case 'finding 2: a launch-file write failure after a slowed startup still records control_deadline exceeded / failure.supervisor-timeout, not "met" from stub_run_result'"'"'s own former default' \
  'YSTACK_TEST_LAUNCH_WRITE_FAIL=1 YSTACK_TEST_RUNTIME_START_LIMIT_MS=50 YSTACK_TEST_SLOW_RUNTIME_START_MS=150' '{}'

# =============================================================================
# Fix round 6 (findings-477-r6.md): one test per finding.
# =============================================================================
default_scenario_path="$(dirname "$driver_path")/scenario.json"

# Finding 1(a) [P1]: a cancellation already pending before the runtime is
# spawned must skip the spawn entirely, never invoking the driver at all.
# Proven with a marker file only the driver's own argv subcommand creates.
argv_marker="$base/argv-called.marker"
rm -f "$argv_marker"
printf '%s' '{"argv_marker_path":"'"$argv_marker"'"}' > "$default_scenario_path"
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
YSTACK_TEST_SELF_SIGNAL_BEFORE_SPAWN=TERM run_launch "$base/pkg-scn.json" || fail "finding 1a: expected exit 0"
[ -e "$argv_marker" ] &&
  fail "finding 1a: expected the driver's argv subcommand never to be invoked for a cancellation pending before spawn, but its marker file exists"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] || fail "finding 1a: expected lifecycle.runtime error, got $runtime"
printf '%s' '{}' > "$default_scenario_path"
pass 'finding 1a: a cancellation already pending at admission is never given a runtime to spawn -- driver_argv (and so Popen) is never invoked, proven by a marker file only that subcommand creates -- and the attempt still finalizes as lifecycle.runtime error'

# Finding 1(b) [P1]: a cancellation arriving right after spawn, while the
# REST endpoint doesn't exist yet, has its stop retried every poll
# iteration until accepted -- not abandoned after one failed attempt.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"action":"hang","startup_delay_ms":300}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_SELF_SIGNAL_AFTER_SPAWN=TERM YSTACK_TEST_STARTUP_MS=5000 YSTACK_TEST_HARDSTOP_MS=10000 \
  YSTACK_TEST_SIGKILL_MS=12000 YSTACK_TEST_POLL_INTERVAL_MS=20 run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 1b: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] && [ "$teardown_state" = confirmed ] ||
  fail "finding 1b: expected lifecycle.runtime error, teardown.state confirmed (a cancellation-issued stop, retried past the runtime's 300ms-delayed REST endpoint, confirms well before the 12,000ms SIGKILL deadline), got $runtime/$teardown_state"
elapsed_s=$("$python" -c "
import json, datetime
r = json.load(open('$store_root/$attempt_id/receipt.json'))
t = r['body']['timing']
fmt = '%Y-%m-%dT%H:%M:%SZ'
a = datetime.datetime.strptime(t['admitted_at'], fmt)
b = datetime.datetime.strptime(t['terminated_at'], fmt)
print(int((b - a).total_seconds()))
")
[ "$elapsed_s" -le 2 ] ||
  fail "finding 1b: expected the retried stop to be accepted (and the attempt to finish) well under the 12s SIGKILL deadline, took ${elapsed_s}s"
pass 'finding 1b: a cancellation signaled right after spawn, while the fake'"'"'s REST endpoint is still 300ms from existing, has driver_stop() retried every poll iteration (rejected while the endpoint is absent) until accepted once it appears -- confirmed stopped in about a second, nowhere near the (test-widened) SIGKILL deadline'

# Finding 2 [P2]: an overdue deadline is checked before any blocking
# driver call each iteration, and each driver_state()/driver_stop() call
# is itself capped by the time remaining to the next deadline -- so a
# slow driver call can't itself run past HardStop or SIGKILL.
printf '%s' '{"slow_state_ms":3000}' > "$default_scenario_path"
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"action":"hang","ignore_hardstop_ms":100000}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_HARDSTOP_MS=300 YSTACK_TEST_SIGKILL_MS=1200 YSTACK_TEST_POLL_INTERVAL_MS=20 \
  run_launch "$base/pkg-scn.json" || status=$?
printf '%s' '{}' > "$default_scenario_path"
[ "$status" -eq 0 ] || fail "finding 2: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] || fail "finding 2: expected lifecycle.runtime error (SIGKILL escalation for a runtime ignoring HardStop), got $runtime"
elapsed_s=$("$python" -c "
import json, datetime
r = json.load(open('$store_root/$attempt_id/receipt.json'))
t = r['body']['timing']
fmt = '%Y-%m-%dT%H:%M:%SZ'
a = datetime.datetime.strptime(t['admitted_at'], fmt)
b = datetime.datetime.strptime(t['terminated_at'], fmt)
print(int((b - a).total_seconds()))
")
[ "$elapsed_s" -le 3 ] ||
  fail "finding 2: expected SIGKILL near its 1,200ms (test-shortened) deadline despite every state poll being scripted to sleep 3,000ms, took ${elapsed_s}s -- an uncapped call (the old flat ~2s-per-call budget) would instead take several seconds longer, escalating well past both deadlines before a single blocking call even returns"
pass 'finding 2: an overdue deadline is checked before any blocking driver call each iteration, and driver_state()/driver_stop() are each capped by the time remaining to the nearer of HardStop/SIGKILL -- SIGKILL still fires close to its real (test-shortened) deadline even though every state poll is scripted to sleep 3,000ms, far past a naive flat per-call budget'

# Finding 3 [P2] (spec R10.2): payload/evidence/<nnnn> already has its own
# dedicated assertion alongside finding 6's test above (the layout, mode
# and ownership of the evidence subdirectory), added directly there so
# the two do not duplicate the same fixture and scenario setup.

# =============================================================================
# Fix round 7 (findings-477-r7.md): one test per finding.
# =============================================================================

# Finding 1 [P2]: cancellation is rechecked immediately before Popen,
# after disk prep (write_launch_disks) and driver_argv() -- both take
# real wall time -- so the runtime is never actually spawned.
run_marker="$base/run-called.marker"
rm -f "$run_marker"
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"run_marker_path":"'"$run_marker"'"}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
YSTACK_TEST_SELF_SIGNAL_DURING_DISK_PREP=TERM run_launch "$base/pkg-scn.json" || fail "finding 1: expected exit 0"
[ -e "$run_marker" ] &&
  fail "finding 1: expected the runtime process never to be spawned for a cancellation pending before Popen, but its marker file exists"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] || fail "finding 1: expected lifecycle.runtime error, got $runtime"
pass 'finding 1: a cancellation signaled during disk prep (write_launch_disks) is still rechecked immediately before Popen -- after disk prep and driver_argv() have both consumed real wall time with no check point of their own -- so the runtime is never spawned at all, proven by a marker file only the driver'"'"'s run subcommand creates'

# Finding 2 [P2]: the deadline budget is recomputed fresh between
# driver_stop() and driver_state() in the same iteration (never a stale
# pre-stop budget), and an overdue deadline discovered there escalates
# immediately -- generalized once via bounded_driver_call, wrapping
# every blocking driver call in the loop.
printf '%s' '{"slow_stop_ms":2000,"slow_state_ms":2000}' > "$default_scenario_path"
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"action":"hang","ignore_hardstop_ms":100000}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_HARDSTOP_MS=200 YSTACK_TEST_SIGKILL_MS=2100 YSTACK_TEST_POLL_INTERVAL_MS=20 \
  run_launch "$base/pkg-scn.json" || status=$?
printf '%s' '{}' > "$default_scenario_path"
[ "$status" -eq 0 ] || fail "finding 2: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] || fail "finding 2: expected lifecycle.runtime error (SIGKILL escalation), got $runtime"
elapsed_s=$("$python" -c "
import json, datetime
r = json.load(open('$store_root/$attempt_id/receipt.json'))
t = r['body']['timing']
fmt = '%Y-%m-%dT%H:%M:%SZ'
a = datetime.datetime.strptime(t['admitted_at'], fmt)
b = datetime.datetime.strptime(t['terminated_at'], fmt)
print(int((b - a).total_seconds()))
")
[ "$elapsed_s" -le 3 ] ||
  fail "finding 2: expected SIGKILL near its 2,100ms (test-shortened) deadline -- a slowed driver_stop() call (2,000ms) leaves ~2,100ms elapsed, at which point the deadline is re-checked BEFORE the next driver_state() call (also scripted slow, 2,000ms) rather than reusing a stale pre-stop budget for it -- took ${elapsed_s}s instead (>3s, roughly the ~4s an uncapped stale-budget call would add), consistent with the old stale-budget bug letting a second full slow call run before ever re-checking"
pass 'finding 2: the remaining deadline budget is recomputed (and an overdue SIGKILL deadline re-checked) between driver_stop() and driver_state() in the same iteration via the shared bounded_driver_call helper -- a slowed stop call alone is enough to reach the SIGKILL deadline, and the following driver_state() call is skipped entirely rather than run with a stale budget'

# =============================================================================
# Fix round 8 (findings-477-r8.md): one test per finding.
# =============================================================================

# Finding 1 [P2]: the 58s abandonment deadline (R9.1), not just
# cancellation, is checked before ever spawning the runtime -- a slowed
# prep phase that alone already burns the whole (test-shortened) window
# must finalize without launching.
run_marker="$base/run-called-r8.marker"
rm -f "$run_marker"
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"run_marker_path":"'"$run_marker"'"}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_SIGKILL_MS=200 YSTACK_TEST_RUNTIME_START_LIMIT_MS=50 YSTACK_TEST_SLOW_RUNTIME_START_MS=400 \
  run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 1: expected exit 0, got $status ($(cat "$base/err"))"
[ -e "$run_marker" ] &&
  fail "finding 1: expected the runtime never to be spawned once the 58s (test-shortened) abandonment deadline had already passed during prep, but its marker file exists"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
reasons=$("$jq_bin" -c -S '.body.outcome.reason_ids' "$store_root/$attempt_id/receipt.json")
has_timeout=0
if printf '%s' "$reasons" | grep -q "failure.supervisor-timeout"; then has_timeout=1; fi
[ "$runtime" = error ] && [ "$has_timeout" -eq 1 ] ||
  fail "finding 1: expected lifecycle.runtime error with failure.supervisor-timeout, got $runtime / $reasons"
pass 'finding 1: a slowed prep phase (write_launch_disks, YSTACK_TEST_SLOW_RUNTIME_START_MS) that alone already exceeds the 58s (test-shortened) abandonment deadline finalizes without ever spawning the runtime -- proven by a marker file only the driver'"'"'s run subcommand creates -- rather than launching a VM only for the poll loop to kill it on its very first iteration'

# Finding 2 [P2] (R7.3): a report claiming tree_terminated: false but a
# "complete" observation on some row is inconsistent (a counter can't be
# complete before the tree it's measuring is confirmed terminated) --
# refused as an invalid export, the spec-faithful choice used throughout
# this function for every other cross-field violation, never silently
# downgraded to partial/unavailable.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"report_overrides":{"tree_terminated":false}}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
run_launch "$base/pkg-scn.json" || fail "finding 2: expected exit 0"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
cpu_obs=$("$jq_bin" -r '.body.limits.cpu_time_ms.observation' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = error ] && [ "$cpu_obs" = unavailable ] ||
  fail "finding 2: expected lifecycle.runtime error and every guest row (e.g. cpu_time_ms) unavailable for a report claiming tree_terminated: false alongside complete observations, got $runtime / $cpu_obs"
pass 'finding 2: a report with tree_terminated: false but limits rows marked complete is refused as an invalid export (R7.3) -- every guest row then unavailable, never a run_vm that copies complete counters collected before the tree it measures was even confirmed terminated'

# Finding 3 [P2] (R10.4): the verifier is read once, during phase B
# (measure_identities), and those bytes are reused directly by the
# admitted path -- never a second read through the same fd afterward,
# which could previously raise Refusal(E_CONFIG)/exit 65 with the
# attempt already claimed and no receipt. Armed for "verifier" here,
# after the attempt is claimed (phase B runs inside the claimed try:
# block): an unreadable verifier still yields an orderly refused
# receipt (launch.identity-missing), never a crash -- and structurally,
# since only one read site exists now at all, the original two-reads
# race this finding described can no longer happen.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_IDENTITY_UNREADABLE=verifier run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 3: expected exit 0 (an orderly refused receipt, never phase-A exit 65), got $status ($(cat "$base/err"))"
[ -f "$store_root/$attempt_id/receipt.json" ] || fail "finding 3: expected a receipt to be written despite the unreadable verifier"
admission=$("$jq_bin" -r '.body.lifecycle.admission' "$store_root/$attempt_id/receipt.json")
reasons=$("$jq_bin" -c -S '.reason_ids' "$store_root/$attempt_id/payload/refusal.json")
[ "$admission" = refused ] && [ "$reasons" = '["launch.identity-missing"]' ] ||
  fail "finding 3: expected lifecycle.admission refused with launch.identity-missing alone, got $admission / $reasons"
pass 'finding 3: an unreadable verifier (armed after the attempt is claimed, inside phase B'"'"'s own single measure_identities read) still yields an orderly launch.identity-missing refused receipt, never an uncaught Refusal/exit 65 with a claimed, receipt-less attempt -- the second read this finding named no longer exists at all'

# Adversarial pass (per the coordinator'"'"'s instruction): a work_root
# name collision inside freeze_by_copy (mkdir_excl's FileExistsError,
# converted internally to Refusal("E_ATTEMPT_EXISTS")) previously escaped
# past the "except OSError:" around its call site -- Refusal is not an
# OSError -- even though the comment right above it already promised "a
# name collision" was covered. Reproduced directly via the existing
# YSTACK_TEST_FREEZE_FAIL-adjacent path is not possible (that hook raises
# OSError, already handled); this one needs freeze_by_copy's OWN
# mkdir_excl(work_fd, attempt_id, ...) to observe a pre-existing
# directory despite the just-passed work_root_attempt_exists check --
# a genuine TOCTOU race with no deterministic trigger from a black-box
# test. Fixed directly (except (OSError, Refusal):) and verified by
# code inspection plus the full adversarial grep pass below; not given
# its own test since it has no deterministic reproduction, consistent
# with this file's own precedent for other unreproducible host-fault
# paths (e.g. the ACL/ownership checks, also inspected rather than
# black-box tested).

# =============================================================================
# Fix round 9 (findings-477-r9.md): one test per finding.
# =============================================================================

# Finding 1 [P1]: freeze_by_copy's own work_root name-collision
# (Refusal("E_ATTEMPT_EXISTS") from its mkdir_excl) must never call
# remove_frozen against a directory this launch didn't create. The real
# trigger is a TOCTOU race between the pre-check (work_root_attempt_exists,
# just above) and freeze_by_copy's own mkdir_excl -- deterministically
# reproduced here by pre-creating the work_root entry with a sentinel
# file and skipping that pre-check (YSTACK_TEST_SKIP_WORK_ROOT_PRECHECK),
# landing exactly on freeze_by_copy's own collision instead.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
other_dir="$work_root/$attempt_id"
mkdir -p "$other_dir"
printf 'sentinel-do-not-touch' > "$other_dir/sentinel.txt"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_SKIP_WORK_ROOT_PRECHECK=1 run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 1: expected exit 0, got $status ($(cat "$base/err"))"
[ -f "$other_dir/sentinel.txt" ] && [ "$(cat "$other_dir/sentinel.txt")" = "sentinel-do-not-touch" ] ||
  fail "finding 1: expected the pre-existing work_root entry's sentinel file to survive untouched"
storage_destroyed=$("$jq_bin" -r '.body.teardown.storage_destroyed' "$store_root/$attempt_id/receipt.json")
[ "$storage_destroyed" = false ] ||
  fail "finding 1: expected teardown.storage_destroyed false (nothing here was ever this launch's to destroy), got $storage_destroyed"
pass 'finding 1: freeze_by_copy'"'"'s own work_root name-collision (a pre-existing work_root entry, deterministically reached with the outer pre-check skipped) never calls remove_frozen against it -- the pre-existing sentinel file survives untouched and the receipt honestly reports storage_destroyed: false, never true'

# Finding 2 [P2]: a clean exit whose REST endpoint vanishes entirely
# (rather than ever reporting "stopped") must still be recognized as a
# confirmed, clean stop via proc.poll()'s own exit code -- never a
# driver failure just because a state poll races ahead and finds no
# endpoint at all.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"vanish_mailbox_on_exit":true}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_STARTUP_MS=0 YSTACK_TEST_POLL_INTERVAL_MS=20 run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding 2: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = completed ] && [ "$teardown_state" = confirmed ] ||
  fail "finding 2: expected lifecycle.runtime completed, teardown.state confirmed (a clean exit whose REST endpoint vanished before a state poll could see stopped must still confirm via proc.poll()'s own exit code), got $runtime/$teardown_state"
pass 'finding 2: a normal run whose REST endpoint disappears entirely on clean exit (never reporting "stopped") is still recognized as a confirmed clean stop via proc.poll()'"'"'s own stopped_exit_status -- driver_state()'"'"'s "error" observation for the now-gone endpoint is not treated as a driver failure once the process has actually already exited cleanly (exit_code is checked first)'

# Finding 3 [P2] (R9.4): a freeze failure that alone already overran the
# startup budget still records control_deadline exceeded /
# failure.supervisor-timeout, exactly like the driver-argv/Popen/
# launch-file-write failure paths -- never the stub's own silent "met"
# default.
control_deadline_case 'finding 3: a freeze failure (YSTACK_TEST_FREEZE_FAIL) that alone already overran the (lowered) startup budget still records control_deadline exceeded / failure.supervisor-timeout, not "met" from stub_run_result'"'"'s own former default' \
  'YSTACK_TEST_FREEZE_FAIL=1 YSTACK_TEST_RUNTIME_START_LIMIT_MS=50 YSTACK_TEST_SLOW_FREEZE_MS=150' '{}'

# Adversarial pass, round 9 (per the coordinator's instruction): every
# remove_*/shutil.rmtree call after the claim was re-audited for proof
# the path it targets was actually created by THIS launch.
#   - remove_only/remove_frozen (freeze-failure and successful-run
#     paths): now gated on created[0] -- fixed above (finding 1).
#   - remove_frozen's own second call (the successful-run path, after
#     run_vm returns): unconditional, but only reached via the "else:"
#     branch of the freeze_by_copy try/except, i.e. only after
#     freeze_by_copy returned normally (no exception) -- which means
#     created[0] is unconditionally true there (freeze_by_copy cannot
#     return without having created and populated the directory first).
#   - No other remove_*/rmtree/unlink call exists anywhere in the
#     post-claim call graph (grepped sandbox/v1/host-supervisor.py for
#     "remove_", "rmtree", "os.unlink", "os.rmdir" -- the only other
#     unlink/rmdir call sites are inside remove_only/remove_frozen
#     themselves, and start.json's own single-file cleanup in run_vm,
#     which unlinks a file this same run_vm call just wrote moments
#     earlier in the very same try block, never anything from an
#     earlier attempt).

# Round 10 (findings-477-r10.md) [P2]: driver_argv bounds nesting and
# filters unspawnable (NUL-containing) argv entries.
driver_argv_fail_case() { # driver_argv_fail_case <desc> <default-scenario-json>
  n=$((n + 1)); local a="attempt.fixture-scn-$n"
  printf '%s' "$2" > "$default_scenario_path"
  build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$a"'","nonce":"'"$(printf '%064d' "$n")"'"}'
  run_launch "$base/pkg-scn.json" || fail "$1: expected exit 0"
  local v t
  v=$("$jq_bin" -r '.body.outcome.verdict' "$store_root/$a/receipt.json")
  t=$("$jq_bin" -r '.body.teardown.state' "$store_root/$a/receipt.json")
  [ "$v" = failed ] && [ "$t" = confirmed ] || fail "$1: expected verdict failed, teardown confirmed, got $v/$t"
  pass "$1"
}
driver_argv_fail_case 'finding: ~2,000 nested arrays in the driver'"'"'s argv response is bounded, never an uncaught RecursionError' '{"deep_nesting_argv":true}'
driver_argv_fail_case 'finding: a NUL byte in an argv entry from the driver'"'"'s argv response is refused, never an uncaught ValueError from Popen' '{"nul_in_argv":true}'

# =============================================================================
# Fix round 12 (findings-477-r12.md): one test per remaining finding
# (finding 1's test was folded into the existing manifest-entry-shape
# loop above, right beside its sibling shape violations).
# =============================================================================
# driver_argv_fail_case above never resets default_scenario_path after
# its own last call (nul_in_argv) -- reset it here so it can't leak into
# either test below (finding r12-3 in particular needs a real, working
# driver_argv() response to ever reach its own poll loop at all).
printf '%s' '{}' > "$default_scenario_path"

# Finding 2 [P2]: created[0] is set the instant os.mkdir succeeds, not
# after mkdir_excl's own later finalization -- a finalization failure
# (YSTACK_TEST_WORKDIR_MKDIR_FAIL, dedicated so it can't also fire on the
# earlier, unrelated store-side attempt-dir mkdir sharing the same name)
# still triggers cleanup, never treating this launch's own just-created
# work_root directory as foreign.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_WORKDIR_MKDIR_FAIL=1 run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding r12-2: expected exit 0, got $status ($(cat "$base/err"))"
storage_destroyed=$("$jq_bin" -r '.body.teardown.storage_destroyed' "$store_root/$attempt_id/receipt.json")
[ "$storage_destroyed" = true ] ||
  fail "finding r12-2: expected teardown.storage_destroyed true (created[0] must already be true when a post-mkdir finalize failure strikes), got $storage_destroyed"
pass 'finding r12-2: a work_root mkdir finalization failure (fchown/fchmod/fsync) striking right after a successful os.mkdir still cleans up (storage_destroyed: true) -- created[0] is set the instant os.mkdir itself succeeds, not after mkdir_excl'"'"'s later finalization'

# Finding 3 [P2]: wall_time_ms is captured at the confirmed-stop instant,
# before the log-drain join, never inflated by a slow drain.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"slow_drain_ms":1500}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
run_launch "$base/pkg-scn.json" || fail "finding r12-3: expected exit 0"
wall_observed=$("$jq_bin" -r '.body.limits.wall_time_ms.observed' "$store_root/$attempt_id/receipt.json")
[ "$wall_observed" -lt 1000 ] ||
  fail "finding r12-3: expected limits.wall_time_ms.observed under 1,000ms (the stop itself completes quickly; a 1,500ms-slow log drain, held open by a grandchild inheriting the pipe, must never inflate it), got ${wall_observed}ms"
pass 'finding r12-3: limits.wall_time_ms.observed is captured immediately at the confirmed-stop instant (alongside terminated_at), before drain.join() -- a 1,500ms-slow log drain (a grandchild process still holding the host'"'"'s pipe open) never inflates the reported wall observation'

# =============================================================================
# Fix round 13 (findings-477-r13.md): one test per finding.
# =============================================================================

# Finding 1 [P2]: the drain worker's own descriptors are never closed
# out from under it -- a worker paused between its own read and write
# still finishes (confirmed via drain_stop plus a bounded second join)
# before finalization ever closes read_fd/log_fd, so a delayed write
# can never land on a reused descriptor number.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"emit_runtime_output":"RUNTIME-OUTPUT-MARKER-R13"}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_DRAIN_PAUSE_MS=2500 run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding r13-1: expected exit 0, got $status ($(cat "$base/err"))"
"$jq_bin" -e . "$store_root/$attempt_id/receipt.json" >/dev/null ||
  fail "finding r13-1: expected receipt.json to be byte-valid JSON"
grep -rl "RUNTIME-OUTPUT-MARKER-R13" "$store_root/$attempt_id" >/dev/null 2>&1 &&
  fail "finding r13-1: expected no store file to contain runtime output (a paused drain worker's delayed write must never land on a reused/closed descriptor)"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = completed ] || fail "finding r13-1: expected lifecycle.runtime completed, got $runtime"
pass 'finding r13-1: a drain worker paused between its own read and write (YSTACK_TEST_DRAIN_PAUSE_MS, well past drain.join()'"'"'s own 2s timeout) is confirmed stopped (drain_stop plus a second bounded join) before read_fd/log_fd are ever closed -- receipt.json stays byte-valid JSON, no store file picks up stray runtime output, and finalization still completes normally: lifecycle.runtime completed'

# Finding 2 [P2]: cmd_run and cmd_stop can both enter write_mailbox
# concurrently (a natural completion racing a host stop) -- the whole
# read-modify-write-replace is now serialized by a flock, so neither
# writer's update is lost and neither raises FileNotFoundError racing
# over a shared tmp path.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
race_marker="$base/stop-race.marker"
rm -f "$race_marker"
printf '%s' '{"concurrent_stop_race":"'"$race_marker"'"}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
run_launch "$base/pkg-scn.json" || fail "finding r13-2: expected exit 0"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = completed ] && [ "$teardown_state" = confirmed ] ||
  fail "finding r13-2: expected lifecycle.runtime completed, teardown.state confirmed (a concurrent, deterministically-ordered mailbox update racing this process's own final write must never make an otherwise-clean exit look abnormal), got $runtime/$teardown_state"
pass 'finding r13-2: a process mimicking a concurrent cmd_stop'"'"'s own write_mailbox(hardstop=true) call, started (via a marker file, not a timing race) before this run'"'"'s own final "stopped" write, never corrupts or loses either update -- the run still completes cleanly: lifecycle.runtime completed, teardown.state confirmed'

# =============================================================================
# Fix round 14 (findings-477-r14.md): the mailbox lock is derived from
# socket_path's own parent directory (an fd flock), not from
# tempfile.gettempdir() -- run_vm spawns cmd_run under scrub_dyld_env()
# (which preserves TMPDIR), but run_driver spawns cmd_stop under env={}
# (no TMPDIR at all), so a lock keyed off tempfile.gettempdir() would
# have resolved to two different files under a non-default TMPDIR,
# leaving the two processes'"'"' mailbox updates fully unsynchronized.
# Forces exactly that mismatch: a custom TMPDIR for the runtime side
# only, with the concurrent update driven through the real driver
# contract (a fresh "stop" subprocess under an explicitly empty
# environment, matching run_driver's own cmd_stop invocation exactly).
# =============================================================================
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
race_marker_r14="$base/stop-race-driver.marker"
rm -f "$race_marker_r14"
custom_tmpdir_r14="$base/r14-custom-tmpdir"
mkdir -p "$custom_tmpdir_r14"
printf '%s' '{"concurrent_stop_race":"'"$race_marker_r14"'","concurrent_stop_race_via_driver":true}' \
  > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
TMPDIR="$custom_tmpdir_r14" run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding r14: expected exit 0, got $status ($(cat "$base/err"))"
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
[ "$runtime" = completed ] && [ "$teardown_state" = confirmed ] ||
  fail "finding r14: expected lifecycle.runtime completed, teardown.state confirmed (cmd_stop invoked through the real driver contract, env={}, must still synchronize with the runtime's own final mailbox write even though the runtime was spawned under a non-default TMPDIR that cmd_stop's own empty environment never sees), got $runtime/$teardown_state"
rm -rf "$custom_tmpdir_r14"
pass 'finding r14: a concurrent mailbox update driven through the real driver contract (a fresh "stop" subprocess under env={}) still correctly serializes against the runtime'"'"'s own final write even though the runtime process was spawned under a non-default TMPDIR that the stop call'"'"'s own empty environment never inherits -- the mailbox lock is derived from socket_path'"'"'s own parent directory, never from tempfile.gettempdir(), so a TMPDIR mismatch between the two real invocation paths can never leave their updates unsynchronized: lifecycle.runtime completed, teardown.state confirmed'

# NOTE: YSTACK_FAKE_SCENARIO stays exported here (round 15's finding
# r15-1 test below still needs it, via the same $scenario_path) -- it is
# unset once, below, only after round 15's own tests are done with it.

# =============================================================================
# Fix round 15 (findings-477-r15.md): one P1, one P2.
# =============================================================================

# Finding 1 [P1]: Thread.start() for the log-drain worker raising
# (host thread/resource exhaustion) after the runtime has already
# spawned must never abort run_vm uncaught and leave that VM
# unsupervised -- the normal driver_stop()/HardStop/reap/teardown/
# receipt machinery must still run to completion exactly as if the
# drain thread had simply never been needed.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
printf '%s' '{"action":"hang"}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
YSTACK_TEST_HARDSTOP_MS=150 YSTACK_TEST_SIGKILL_MS=5000 YSTACK_TEST_POLL_INTERVAL_MS=20 \
  YSTACK_TEST_DRAIN_START_FAIL=1 \
  run_launch "$base/pkg-scn.json" || status=$?
[ "$status" -eq 0 ] || fail "finding r15-1: expected exit 0, got $status ($(cat "$base/err"))"
admission=$("$jq_bin" -r '.body.lifecycle.admission' "$store_root/$attempt_id/receipt.json")
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
teardown_state=$("$jq_bin" -r '.body.teardown.state' "$store_root/$attempt_id/receipt.json")
storage_destroyed=$("$jq_bin" -r '.body.teardown.storage_destroyed' "$store_root/$attempt_id/receipt.json")
verdict=$("$jq_bin" -r '.body.outcome.verdict' "$store_root/$attempt_id/receipt.json")
reasons=$("$jq_bin" -c -S '.body.outcome.reason_ids' "$store_root/$attempt_id/receipt.json")
expect_reasons='["failure.enforcement-unavailable","failure.observation-unavailable","failure.runtime"]'
[ "$admission" = admitted ] && [ "$runtime" = error ] && [ "$teardown_state" = confirmed ] &&
  [ "$storage_destroyed" = true ] && [ "$verdict" = failed ] && [ "$reasons" = "$expect_reasons" ] ||
  fail "finding r15-1: expected admitted/error/confirmed, storage_destroyed true, verdict failed, reasons $expect_reasons -- got $admission/$runtime/$teardown_state storage_destroyed=$storage_destroyed verdict=$verdict reasons=$reasons"
grep -q 'drain thread for .* failed to start' "$base/err" ||
  fail "finding r15-1: expected the drain-thread-start-failure warning on stderr (proving the injected failure was actually exercised, not a scenario that happened to pass on its own)"
pass 'finding r15-1: the log-drain worker'"'"'s own Thread.start() failing (YSTACK_TEST_DRAIN_START_FAIL, standing in for a genuine RuntimeError under host thread exhaustion) right after the runtime has already spawned never aborts run_vm uncaught -- HardStop is still issued at its deadline, honored, reaped and torn down exactly as findings-477-r9.md'"'"'s own HardStop test proves without the injected failure: lifecycle.runtime error, teardown.state confirmed, storage_destroyed true, verdict failed, reasons failure.enforcement-unavailable + failure.observation-unavailable + failure.runtime -- runtime.log capture is the only casualty (a warning on stderr proves it), never the VM'"'"'s own supervision'

# Finding 2 [P2]: run_driver must reject a response it only has because
# its own read timed out (or failed) while a helper the driver forked
# still holds the pipe's write end open -- a driver process that has
# ALREADY exited 0 is not enough on its own to trust whatever partial
# bytes were read by the time the timeout fired -- and must kill the
# whole driver process GROUP (not just the driver's own already-exited
# pid) so that forked-and-abandoned helper is cleaned up too, never
# left running. Exercises run_driver() directly (imported from
# host-supervisor.py exactly as sandbox-fake-runtime.py's own
# load_host_module() does) against a small dedicated fake driver that
# reproduces the exact repro: prints "stopped\n", forks a child that
# holds stdout open while sleeping (recording its own pid to a marker
# file first), and the parent exits 0 immediately.
cat > "$base/fake-driver-pipe-hold.py" <<'PY'
#!/usr/bin/python3
import os, sys, time

def main():
    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == "state":
        marker = args[1]
        sys.stdout.write("stopped\n")
        sys.stdout.flush()
        if os.fork() == 0:
            with open(marker, "w") as fh:
                fh.write(str(os.getpid()))
            time.sleep(30)
            os._exit(0)
        return 0
    return 1

if __name__ == "__main__":
    sys.exit(main())
PY
chmod 555 "$base/fake-driver-pipe-hold.py"
cat > "$base/run_driver_probe.py" <<'PY'
import importlib.util, os, sys, time

def load(path):
    spec = importlib.util.spec_from_file_location("_ystack_probe_host", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def main():
    host_path, driver_path, marker = sys.argv[1], sys.argv[2], sys.argv[3]
    hs = load(host_path)
    rc, out = hs.run_driver(driver_path, ["state", marker], timeout_s=0.5)
    with open(marker) as fh:
        child_pid = int(fh.read().strip())
    alive = True
    for _ in range(75):
        try:
            os.kill(child_pid, 0)
        except OSError:
            alive = False
            break
        time.sleep(0.02)
    print("rc=%r out_len=%d child_pid=%d alive=%s" % (rc, len(out), child_pid, alive))
    sys.exit(0 if (rc is None and out == b"" and not alive) else 1)

main()
PY
pipe_hold_marker="$base/pipe-hold-child.pid"
rm -f "$pipe_hold_marker"
"$python" "$base/run_driver_probe.py" "$install_dir/host-supervisor.py" \
  "$base/fake-driver-pipe-hold.py" "$pipe_hold_marker" > "$base/out" 2>"$base/err"
status=$?
[ "$status" -eq 0 ] || fail "finding r15-2: expected exit 0 (rc is None, out is empty, and the forked helper holding the pipe open is gone), got $status: $(cat "$base/out") $(cat "$base/err")"
pass 'finding r15-2: run_driver() rejects a response it only has because its own read timed out while a forked helper still holds the driver'"'"'s stdout pipe open (a driver reporting stopped then exiting 0, with a child inherited from it never closing that fd) -- returns a rejected, empty response, never the driver'"'"'s exit code plus whatever partial bytes happened to arrive before the timeout, and kills the whole driver process GROUP (not just the already-exited driver pid) so the abandoned helper is confirmed gone, never left running past the call'

# =============================================================================
# Fix round 16 (findings-477-r16.md): two P2s.
# =============================================================================

# Finding 1 [P2]: argv[0] must equal the configured vfkit path exactly.
n=$((n + 1)); attempt_id="attempt.fixture-scn-$n"
run_marker="$base/r16-run.marker"; rm -f "$run_marker"
printf '%s' '{"wrong_argv_exe":true}' > "$default_scenario_path"
printf '%s' '{"run_marker_path":"'"$run_marker"'"}' > "$scenario_path"
build_pkg "$base/pkg-scn.json" '{"attempt_id":"'"$attempt_id"'","nonce":"'"$(printf '%064d' "$n")"'"}'
status=0
run_launch "$base/pkg-scn.json" || status=$?
printf '%s' '{}' > "$default_scenario_path"
[ "$status" -eq 0 ] || fail "finding r16-1: expected exit 0, got $status ($(cat "$base/err"))"
[ ! -e "$run_marker" ] || fail "finding r16-1: expected the runtime to never be spawned"
verdict=$("$jq_bin" -r '.body.outcome.verdict' "$store_root/$attempt_id/receipt.json")
runtime=$("$jq_bin" -r '.body.lifecycle.runtime' "$store_root/$attempt_id/receipt.json")
[ "$verdict" = failed ] && [ "$runtime" = error ] ||
  fail "finding r16-1: expected outcome.verdict failed, lifecycle.runtime error, got $verdict/$runtime"
pass 'finding r16-1: a driver argv response naming an executable different from the configured (measured) vfkit path is rejected before ever calling Popen -- exact string equality, no normalization -- proven by the run marker'"'"'s absence: outcome.verdict failed, lifecycle.runtime error'

# Finding 2 [P2]: overflow rejection also kills the driver process group.
cat > "$base/fake-driver-overflow.py" <<'PY'
#!/usr/bin/python3
import os, sys, time
a = sys.argv[1:]
if len(a) >= 2 and a[0] == "state":
    if os.fork() == 0:
        open(a[1], "w").write(str(os.getpid()))
        time.sleep(30)
        os._exit(0)
    sys.stdout.write("x" * 70000)
else:
    sys.exit(1)
PY
chmod 555 "$base/fake-driver-overflow.py"
pipe_hold_marker2="$base/pipe-hold-child2.pid"; rm -f "$pipe_hold_marker2"
"$python" "$base/run_driver_probe.py" "$install_dir/host-supervisor.py" \
  "$base/fake-driver-overflow.py" "$pipe_hold_marker2" > "$base/out" 2>"$base/err"
status=$?
[ "$status" -eq 0 ] || fail "finding r16-2: expected exit 0 (rc is None, out is empty, and the forked helper is gone), got $status: $(cat "$base/out") $(cat "$base/err")"
pass 'finding r16-2: run_driver()'"'"'s overflow-rejection branch (>65,536 bytes) now kills the whole driver process GROUP too, not just the incomplete-read branch -- a forked helper still holding the pipe open past the driver'"'"'s own oversized write and exit is confirmed gone after the call, never left running for a teardown elsewhere that can never reach it'

# =============================================================================
# PR 8 of 9: runtime-vfkit.py and qualify.py (plan.md "PR 8"). Contract tests only:
# a test-local fake vfkit, the fake runtime and synthetic fixtures; no real vfkit.
# =============================================================================
q_src="$root/sandbox/v1/qualify.py"
vf="$base/vf"
/bin/mkdir -m 0755 "$vf"
vfrun=$(/usr/bin/mktemp -d "/tmp/ysvfk.XXXXXX")
/bin/cp "$root/sandbox/v1/runtime-vfkit.py" "$vf/driver"
printf '{"body":{"runtime":{"driver":"%s/driver","vfkit":"%s/vfkit"}}}\n' "$vf" "$vf" >"$vf/host-config.json"
cat >"$vf/vfkit" <<'PY'
#!/usr/bin/python3
# test-local fake vfkit: records its argv and each REST request, serves /vm/state on --restful-uri
import http.server, json, os, socketserver, sys
args = sys.argv[1:]
path = args[args.index("--restful-uri") + 1][len("unix://"):]
state = {"s": "VirtualMachineStateRunning"}
class H(http.server.BaseHTTPRequestHandler):
    def reply(self, code):
        body = json.dumps({"state": state["s"]}).encode()
        self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def note(self, body):
        with open(path + ".log", "a") as fh: fh.write(json.dumps([self.command, self.path, body.decode()]) + "\n")
    def do_GET(self):
        self.note(b""); self.reply(200)
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"])); self.note(body)
        code = int(os.environ.get("FAKE_VFKIT_STOP_STATUS", "200"))
        if code == 200 and json.loads(body) == {"state": "HardStop"}: state["s"] = "VirtualMachineStateStopped"
        self.reply(code)
    def log_message(self, *a): pass
socketserver.UnixStreamServer(path, H).serve_forever()
PY
/bin/chmod 0755 "$vf/vfkit" "$vf/driver"
"$python" - "$vf" "$vfrun" <<'PY'
import json, os, subprocess, sys, time
vf, run = sys.argv[1:]
def drive(*args):
    p = subprocess.run([vf + "/driver"] + list(args), env={}, stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
    return p.returncode, p.stdout.decode()
def start(sock, **over):
    body = {"command_line": "console= quiet lsm=landlock rdinit=/init", "cpu_count": 1, "export_disk": "/w/a/export.img",
            "initramfs": "/i/initramfs.cpio", "input_disk": "/w/a/input.img", "kernel": "/k/Image",
            "memory_bytes": 536870912, "rest_socket": sock}
    body.update(over)
    with open(run + "/start.json", "w") as fh:
        json.dump({"body": body, "kind": "sandbox_runtime_start", "schema_version": 1}, fh)
    return run + "/start.json"
def spawn(argv, **env):
    proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, env=dict(os.environ, **env))
    sock = argv[-1][len("unix://"):]
    for _ in range(200):
        if os.path.exists(sock): return proc
        time.sleep(0.05)
    raise SystemExit("fake vfkit never listened")
sock = run + "/rest.sock"
rc, out = drive("argv", start(sock))
argv = ["%s/vfkit" % vf, "--cpus", "1", "--memory", "512", "--bootloader",
        'linux,kernel=/k/Image,initrd=/i/initramfs.cpio,cmdline="console= quiet lsm=landlock rdinit=/init"',
        "--device", "virtio-blk,path=/w/a/input.img,readonly", "--device", "virtio-blk,path=/w/a/export.img",
        "--restful-uri", "unix://" + sock]
assert (rc, out) == (0, json.dumps({"argv": argv, "stopped_exit_status": 0}, sort_keys=True, separators=(",", ":")) + "\n"), out
for bad in ({"cpu_count": 2}, {"memory_bytes": 1048576}, {"command_line": "console=ttyS0"}, {"kernel": "/k,x/Image"}, {"kernel": "k/Image"}):
    assert drive("argv", start(sock, **bad)) == (1, ""), bad
long_sock = run + "/" + "s" * (102 - len(run) - 1)
assert len(long_sock) == 102 and drive("argv", start(long_sock + "s"))[0] == 0   # 103 bytes: accepted
assert drive("argv", start(long_sock + "ss")) == (1, "")                        # 104 bytes: refused
proc = spawn(argv)
assert drive("state", sock) == (0, "running\n")
assert drive("stop", sock)[0] == 0 and drive("state", sock) == (0, "stopped\n")
assert [json.loads(l) for l in open(sock + ".log")] == [
    ["GET", "/vm/state", ""], ["POST", "/vm/state", '{"state":"HardStop"}'], ["GET", "/vm/state", ""]]
assert drive("state", run + "/absent.sock") == (0, "error\n") and drive("stop", run + "/absent.sock")[0] == 1
sock2 = run + "/rest2.sock"
refusing = spawn(json.loads(drive("argv", start(sock2))[1])["argv"], FAKE_VFKIT_STOP_STATUS="500")
assert drive("stop", sock2)[0] == 1 and drive("state", sock2) == (0, "running\n")  # a rejected stop never reads as accepted
proc.kill(); refusing.kill()
PY
/bin/rm -rf -- "$vfrun"
pass 'runtime-vfkit.py builds exactly the plan'"'"'s vfkit argv and speaks REST over AF_UNIX against a fake vfkit (GET /vm/state, POST /vm/state HardStop; stopped after the accepted stop, exit 1 for a rejected one or no endpoint); argv is refused for a socket path of 104 bytes and for any start body off the R5.4 values, with the 103-byte path and the exact values as controls'

# --- two trusted configurations: verifier and probe, a test-local echoing fake runtime -----
build_tree 0
qdir="$base/qual"
q_work_v=$(/usr/bin/mktemp -d /tmp/ysvml.XXXXXX)
q_work_p=$(/usr/bin/mktemp -d /tmp/ysvml.XXXXXX)
/bin/mkdir -m 0755 "$qdir"
cat >"$base/build_qual.py" <<'PY'
import copy, importlib.util, json, os, shutil, subprocess, sys
config_path, hs_src, q_src, build_pkg, fake_src, qdir, work_v, work_p, python = sys.argv[1:]
spec = importlib.util.spec_from_file_location("q", q_src); q = importlib.util.module_from_spec(spec); spec.loader.exec_module(q)
sha = q.sha
canon = q.hs.canonical
body0 = json.load(open(config_path))["body"]
root = os.path.dirname(os.path.dirname(config_path))
def put(path, data, mode):
    open(path, "wb").write(data); os.chmod(path, mode)
# The echoing fake: a test-local copy of the fake runtime whose guest stdout is, unless a
# scenario scripts one, the digest of the input disk's own verifier record.
echo = root + "/echo"; os.makedirs(echo, 0o755)
src = open(fake_src).read()
old = 'stdout_bytes = scenario.get("stdout", "").encode()'
assert old in src
src = src.replace(old, 'stdout_bytes = (scenario["stdout"] if "stdout" in scenario else hs.sha256_hex(input_records[b"verifier"])).encode()')
for name in ("driver", "vfkit"):
    put(echo + "/" + name, ("#!" + sys.executable + "\n" + src.partition("\n")[2]).encode(), 0o555)
put(echo + "/scenario.json", b"{}\n", 0o644)
ids = root + "/identities"
put(ids + "/verifier-real", b"synthetic-verifier-real", 0o444)
put(ids + "/verifier-probe", b"synthetic-verifier-probe", 0o444)
configs, stores, measured = {}, {}, {}
for name, verifier, work in (("verifier", ids + "/verifier-real", work_v), ("probe", ids + "/verifier-probe", work_p)):
    inst = root + "/install-" + name; os.makedirs(inst, 0o755)
    put(inst + "/host-supervisor.py", open(hs_src, "rb").read(), 0o555)
    store = root + "/store-" + name; os.makedirs(store, 0o750); os.chmod(store, 0o750); os.chown(store, os.getuid(), os.getgid())
    body = copy.deepcopy(body0)
    body["identity_paths"]["verifier"] = verifier
    body.update(store_id="store.fixture.qualify-%s.v1" % name, store_root=store, work_root=work)
    body["runtime"] = {"driver": echo + "/driver", "vfkit": echo + "/vfkit"}
    put(inst + "/host-config.json", canon({"body": body, "id": "sandbox.host-config.v1", "kind": "sandbox_host_config", "schema_version": 1}), 0o444)
    configs[name], stores[name] = inst, body["store_id"]
    measured[name] = json.loads(subprocess.run([python, q_src, "measure", inst + "/host-config.json"], capture_output=True, check=True).stdout)
sroot = root + "/sentinels"; os.makedirs(sroot, 0o755)
fixtures = {}
for role in ("host", "sibling"):
    data = (role + "-sentinel-content\n").encode()
    put(sroot + "/" + role + ".txt", data, 0o444)
    fixtures[role] = {"path": sroot + "/" + role + ".txt", "size_bytes": len(data), "sha256": sha(data)}
ev = {"archive_sha256": measured["probe"]["toolchain"], "kernel_sha256": measured["probe"]["guest_kernel"], "build_domain_max": 1, "kernel_domain_max": 1,
      "families": [{"family": 0, "aliases": ["AF_TEST0"]}]}
FORGED = q.FORGED.decode()
def rec(name, pre="unknown", att=0, comp=0, out="incomplete", err=0, v=(0, 0, 0)):
    return "%s:%s:%d:%d:%s:%d:0:%d:%d:%d" % ((name, pre, att, comp, out, err) + v)
# The accepted set holds at most 8 instruction digests per environment (digest_list_ok), so one
# dry run launches 8 distinct instructions; classification of every mode is proved below.
cases = [("v-echo", "verifier", b"verify one\n", None, "verifier-run"), ("v-echo-2", "verifier", b"verify one\n", None, "verifier-run"),
         ("p-echo", "probe", b"YSPROBE1 sleep\n", None, "invalid-result"), ("p-echo-2", "probe", b"YSPROBE1 sleep\n", None, "invalid-result")]
for mode in ("candidate-read", "forged-report-evidence", "output-overflow", "tools-write", "scratch-fill", "environment", "forged-report-stdout"):
    cases.append((mode, "probe", ("YSPROBE1 %s\n" % mode).encode(), mode, None))
for role in ("host", "sibling"):
    cases.append((role + "-sentinel", "probe", q.sentinel_instruction(dict(fixtures[role], role=role)), role + "-sentinel", None))
cases.append(("socket-0", "probe", q.socket_instruction(0), "socket-family", None))
# 12 distinct digests (a repeated one in two verifier cases and across batches) over three batches of at most 8
batches = [sorted(b) for b in (["v-echo", "v-echo-2", "p-echo", "candidate-read", "forged-report-evidence"],
           ["output-overflow", "host-sentinel", "sibling-sentinel", "socket-0", "tools-write"],
           ["environment", "forged-report-stdout", "p-echo-2", "scratch-fill"])]
open(qdir + "/batches.json", "wb").write(canon({"body": {"batches": batches, "cases": [{"case_id": c[0], "configuration": c[1], "instruction_sha256": sha(c[2])} for c in cases]},
          "id": "sandbox.qualification-batches", "kind": "sandbox_qualification_batches", "schema_version": 1}))
plan_cases, expected = [], {}
for n, (cid, cfg, instruction, mode, klass) in enumerate(cases):
    scenario = {"limit_overrides": {"output_bytes": {"observed": 64}}}   # the echoed 64-character digest
    if mode:
        text, extra, klass = None, [], "result-incomplete"
        if mode == "output-overflow": text, klass = "x" * 4096, "output-prefix"
        elif mode == "forged-report-stdout": text, klass = FORGED, "forged-complete"
        else:
            names = q.CHECKS[mode]
            recs, checks, domain = [rec(x) for x in names], "incomplete", "none"
            if mode == "candidate-read": recs, checks = [rec("read", "ok", 1, 1, "refused", 13)], "complete"
            if mode == "socket-family":
                recs, checks, domain, klass = [rec("socket", "ok", 1, 1, "refused", 1, (0, 524289, 0))], "complete", "linux-build-af-v1/1", "result-complete"
            if mode == "candidate-read": klass = "result-complete"
            text = "YSPROBE1 %s %s %s %s %d %s\n" % (instruction.decode().split(" ")[1].strip(), sha(instruction), checks, domain, len(recs), " ".join(recs))
            if mode == "forged-report-evidence": extra = [{"index": 0, "name": "forged-report.json", "content": FORGED}]
        scenario = {"stdout": text, "evidence": extra, "limit_overrides": {"output_bytes": {"observed": len(text) + sum(len(e["content"]) for e in extra)}}}
    expected[cid] = klass
    pkg = "pkg-%s.json" % cid
    patch = {"attempt_id": "attempt.q-%03d" % n, "nonce": "%064x" % (n + 1), "store_id": stores[cfg], "instruction": instruction.decode()}
    subprocess.run([python, build_pkg, hs_src, qdir + "/" + pkg], input=json.dumps(patch).encode(), check=True)
    plan_cases.append(dict({"id": cid, "config": cfg, "package": pkg}, **({"scenario": scenario} if scenario else {})))
plan = {"configs": {n: {"install_dir": configs[n], "launch": [python, "host-supervisor.py", "launch"]} for n in configs},
        "checker": None, "domain_evidence": ev, "fixtures": fixtures, "sentinel_root": sroot, "cases": plan_cases}
json.dump(plan, open(qdir + "/cases.json", "w"))
json.dump({"expected": expected, "stores": stores, "configs": configs, "measured": measured}, open(qdir + "/meta.json", "w"))
PY
"$python" "$base/build_qual.py" "$config_path" "$supervisor_src" "$q_src" "$base/build_pkg.py" \
  "$root/scripts/test/sandbox-fake-runtime.py" "$qdir" "$q_work_v" "$q_work_p" "$python"
pass 'two trusted configurations (verifier and probe: distinct verifier files, stores, store ids and work roots, identical otherwise) are built over one echoing fake runtime, with one shared accepted set made from the union of qualify.py measure for each'

cat >"$base/qprelude.py" <<'PY'
import importlib.util, json, os, shutil, sys, tempfile
spec = importlib.util.spec_from_file_location("q", sys.argv[2]); q = importlib.util.module_from_spec(spec); spec.loader.exec_module(q)
sha = q.sha
def facts(stdout=b"", stderr=b"", evidence=(), admission="admitted", runtime="completed", deadline="met",
          state="exited", code=0, teardown="confirmed"):
    return {"receipt": {"lifecycle": {"admission": admission, "runtime": runtime, "control_deadline": deadline},
                        "payload": {"exit_state": state, "exit_code": code}, "teardown": {"state": teardown}},
            "stdout": stdout, "stderr": stderr, "evidence": list(evidence)}
def case(mode, text=None, **more):
    ins = (text or "YSPROBE1 %s\n" % mode).encode()
    return dict({"mode": mode, "instruction": ins, "instruction_sha256": sha(ins)}, **more)
def rec(name, pre="ok", att=1, comp=1, out="success", err=None, clean=0, v=(0, 0, 0)):
    err = (13 if out == "refused" else 0) if err is None else err
    return "%s:%s:%d:%d:%s:%d:%d:%d:%d:%d" % ((name, pre, att, comp, out, err, clean) + tuple(v))
def line(c, checks, records, domain="none", digest=None, mode=None):
    return ("YSPROBE1 %s %s %s %s %d %s\n" % (mode or c["mode"], digest or c["instruction_sha256"], checks, domain,
                                              len(records), " ".join(records))).encode()
def verdict(c, **kw):
    out = q.classify(c, facts(**kw)); return out["class"], out["reason"]
def raises(fn, text):
    try: fn()
    except q.Invalid as exc: assert str(exc) == text, str(exc); return
    raise AssertionError("expected " + text)
PY
qpy() { "$python" -c 'import sys; exec(open(sys.argv[1]).read()); exec(sys.stdin.read())' "$base/qprelude.py" "$q_src"; }

# --- dry-run: the probe list against the fake runtime through host-supervisor.py launch ------
unset YSTACK_FAKE_SCENARIO
"$python" "$q_src" dry-run "$qdir" >"$base/qrec.json" 2>"$base/err" || fail "dry-run: exit $? ($(cat "$base/err"))"
qv_install=$("$jq_bin" -r .configs.verifier "$qdir/meta.json")
qp_install=$("$jq_bin" -r .configs.probe "$qdir/meta.json")
qroot=${qv_install%/*}
QDIR=$qdir QREC=$base/qrec.json qpy <<'PY'
raw = open(os.environ["QREC"], "rb").read(); rec = json.loads(raw); body = rec["body"]
meta = json.load(open(os.environ["QDIR"] + "/meta.json")); plan = json.load(open(os.environ["QDIR"] + "/cases.json"))
assert raw == q.hs.canonical(rec) and rec["kind"] == "sandbox_qualification_record" and body["dry_run"] is True
got = {c["id"]: c["class"] for c in body["cases"]}
assert got == meta["expected"], {k: (got.get(k), v) for k, v in meta["expected"].items() if got.get(k) != v}
assert all(c["verdict"] == "failed" and c["native_fulfilled"] is False for c in body["cases"])
vfile = {n: q.read_config(meta["configs"][n] + "/host-config.json")[0]["identity_paths"]["verifier"] for n in meta["configs"]}
digest = {n: sha(open(vfile[n], "rb").read()) for n in vfile}
assert digest["verifier"] != digest["probe"]
for entry in plan["cases"]:
    cfg = entry["config"]; named = q.hs.parse_package(open(os.environ["QDIR"] + "/" + entry["package"], "rb").read())
    attempt = json.loads(named["request.json"])["body"]["attempt"]["attempt_id"]
    store = q.read_config(meta["configs"][cfg] + "/host-config.json")[0]["store_root"]
    receipt = json.load(open("%s/%s/receipt.json" % (store, attempt)))["body"]
    assert receipt["identities"]["verifier"]["sha256"] == digest[cfg] and receipt["origin"]["store_id"] == meta["stores"][cfg], entry["id"]
    assert receipt["identities"]["verification_instructions"]["sha256"] == sha(named["instruction"])
    if entry["id"] in ("v-echo", "v-echo-2", "p-echo", "p-echo-2"):
        assert receipt["payload"]["stdout_sha256"] == sha(digest[cfg].encode()), entry["id"]
    assert not os.path.exists("%s/%s/receipt.json" % (q.read_config(meta["configs"]["probe" if cfg == "verifier" else "verifier"] + "/host-config.json")[0]["store_root"], attempt))
sentinels = [c for c in body["cases"] if c["mode"].endswith("-sentinel")]
assert len(sentinels) == 2 and all(c["controls"]["pre"] == c["controls"]["post"] and c["controls"]["pre"]["represents"] for c in sentinels)
assert sentinels[0]["controls"]["pre"]["path"] != sentinels[1]["controls"]["pre"]["path"]
ev = next(c for c in body["cases"] if c["id"] == "forged-report-evidence")
assert len(ev["evidence"]) == 1 and ev["class"] == "result-incomplete" and ev["native_fulfilled"] is False
PY
pass 'the dry run launches a real-verifier case, an echo case, both sentinels, a socket family and raw, evidence and ordinary probe modes through each case'"'"'s own configuration: every receipt'"'"'s identities.verifier, stdout_sha256 and origin.store_id match its own configuration and appear in no other store, and each case is classified (complete and incomplete lines, raw prefix, forged text, sentinel controls, evidence) with native_fulfilled false and every verdict failed'

# --- aggregation: complete only if every batch ran once and every case id is covered once -----
QDIR=$qdir QREC=$base/qrec.json qpy <<'PY'
import subprocess
qd = os.environ["QDIR"]; raws = [open("%s/batch-%d.json" % (qd, k), "rb").read() for k in range(3)]
BATCH = {"qualification." + n for n in ("batch-missing", "batch-duplicate", "batch-rerun", "binding-mismatch", "accepted-set-mismatch")}
def agg(rs): return json.loads(q.aggregate(qd, rs))["body"]
def edit(raw, f):
    doc = json.loads(raw); f(doc["body"]); return q.hs.canonical(doc)
def named(rs): return BATCH & set(agg(rs)["reason_ids"])
good = agg(raws)
assert good["complete"] is True and not BATCH & set(good["reason_ids"]) and len(good["cases"]) == 14 and good["batches"] == 3
assert good["qualification"] == "not-qualified" and "qualification.cpu-wall-unbounded" in good["reason_ids"]   # still never qualified
assert q.aggregate(qd, raws) == open(os.environ["QREC"], "rb").read() == subprocess.run([sys.executable, sys.argv[2], "aggregate", qd] + ["%s/batch-%d.json" % (qd, k) for k in range(3)], capture_output=True).stdout
assert "qualification.batch-missing" in named(raws[:1] + raws[2:]) and named(raws + [raws[1]]) == {"qualification.batch-duplicate"}
assert named(raws + [edit(raws[1], lambda b: b["cases"][0].update(receipt_sha256="0" * 64))]) == {"qualification.batch-rerun"}
def store(n): return q.read_config(json.load(open(qd + "/cases.json"))["configs"][n]["install_dir"] + "/host-config.json")[0]["store_root"]
def tamper(path, new):   # aggregate against a changed or missing store file; restored afterwards
    old = open(path, "rb").read(); os.chmod(path, 0o640)
    if new is None: os.remove(path)
    else: open(path, "wb").write(new)
    try: return agg(raws)
    finally: open(path, "wb").write(old); os.chmod(path, 0o440)
for label, cid, cfg, rel, new in (("receipt deleted", "candidate-read", "probe", "receipt.json", None), ("stdout modified", "candidate-read", "probe", "payload/stdout", b"x"),
                                  ("receipt modified after the record", "v-echo", "verifier", "receipt.json", b'{"x":1}\n')):
    attempt = next(c["attempt_id"] for c in good["cases"] if c["id"] == cid)
    r = tamper("%s/%s/%s" % (store(cfg), attempt, rel), new)
    assert r["complete"] is False and next(c for c in r["cases"] if c["id"] == cid)["class"] == "unusable" and "qualification.binding-mismatch" in r["reason_ids"], label
assert agg(raws)["complete"] is True                                                    # control: everything restored
def altered(path, f, rs=None):   # aggregate after the file the batches ran against was changed; restored afterwards
    old = open(path, "rb").read(); d = json.loads(old); f(d)
    open(path, "wb").write(json.dumps(d, sort_keys=True, separators=(",", ":")).encode() + b"\n")
    try: return agg(rs or raws)
    finally: open(path, "wb").write(old)
def forge(cid, cfg, f, body_claim=None, case_claim=None):   # a receipt changed by f, and a batch-0 record that names it
    path = "%s/%s/receipt.json" % (store(cfg), next(c["attempt_id"] for c in good["cases"] if c["id"] == cid))
    old = open(path, "rb").read(); doc = json.loads(old); f(doc["body"]); new = q.hs.canonical(doc)
    def name(b):
        b.update(body_claim or {})
        for c in b["cases"]:
            if c["id"] == cid: c.update(dict(receipt_sha256=q.sha(new), **(case_claim or {})))
    os.chmod(path, 0o640); open(path, "wb").write(new)
    try:
        r = agg([edit(raws[0], name)] + raws[1:]); return r, next(c for c in r["cases"] if c["id"] == cid)
    finally: open(path, "wb").write(old); os.chmod(path, 0o440)
assert forge("v-echo", "verifier", lambda b: None)[0]["complete"] is True                                    # control: a receipt the record names, unchanged
for slot in ("guest_kernel", "host_runtime", "host_supervisor", "image", "toolchain", "verification_instructions"):
    r, c = forge("candidate-read", "probe", lambda b: b["identities"][slot].update(sha256="0" * 64))
    assert r["complete"] is False and c["class"] == "unusable", slot       # every measured identity is compared, whatever the record claims
b0 = json.loads(raws[0])["body"]; env = b0["environment_id"]
broad = q.sha(q.accepted_doc(env, dict(b0["accepted_identities"], verification_instructions=sorted(b0["accepted_identities"]["verification_instructions"] + ["0" * 64]))))
r, c = forge("v-echo", "verifier", lambda b: b["origin"].update(accepted_set_sha256=broad), {"accepted_set_sha256": broad}, {"accepted_set_sha256": broad})
assert r["complete"] is False and "qualification.accepted-set-mismatch" in r["reason_ids"]                      # produced under a broader set
r, c = forge("v-echo", "verifier", lambda b: b["origin"].update(accepted_set_sha256=b0["accepted_set_sha256"]))
assert r["complete"] is True and q.sha(q.accepted_doc(env, b0["accepted_identities"])) == b0["accepted_set_sha256"]   # control: the exact set
def share_package(d):
    e = {x["id"]: x for x in d["cases"]}; e["v-echo-2"]["package"] = e["v-echo"]["package"]
def same_execution(b):
    a, t = (next(c for c in b["cases"] if c["id"] == i) for i in ("v-echo", "v-echo-2"))
    t.update({k: a[k] for k in ("attempt_id", "launch_request_sha256", "receipt_sha256")})
r = altered(qd + "/cases.json", share_package, [edit(raws[0], same_execution), raws[1], raws[2]])
assert r["complete"] is False and next(c for c in r["cases"] if c["id"] == "v-echo-2")["reason"] == "duplicate-attempt"   # one execution counted twice
def bad_env(b):
    for c in b["cases"]:
        if c["id"] == "environment": f(c)
def flip_mode(c): c["mode"] = "verifier"
def drop_receipt(c): del c["receipt_sha256"]
for label, f in (("cached mode flipped to verifier", flip_mode), ("receipt digest removed", drop_receipt), ("attempt id removed", lambda c: c.pop("attempt_id"))):
    r = agg([raws[0], raws[1], edit(raws[2], bad_env)])
    env = next(c for c in r["cases"] if c["id"] == "environment")
    assert r["complete"] is False and env["class"] == "unusable" if f is not flip_mode else env["class"] == "result-incomplete" and env["mode"] == "environment", label
r = altered(qd + "/cases.json", lambda d: d["domain_evidence"].update(build_domain_max=2))
assert r["complete"] is False and "qualification.binding-mismatch" in r["reason_ids"]                       # domain evidence changed after the batches ran
r = altered(qd + "/batches.json", lambda d: d["body"]["cases"].reverse())
assert r["complete"] is False and "qualification.binding-mismatch" in r["reason_ids"]                       # batches.json changed after running
assert agg(raws)["complete"] is True                                                                          # control: both files restored
def claim_complete(b):
    for c in b["cases"]:
        if c["id"] == "environment": c["class"] = "result-complete"
cached = agg([raws[0], raws[1], edit(raws[2], claim_complete)])
assert cached["complete"] and next(c for c in cached["cases"] if c["id"] == "environment")["class"] == "result-incomplete"   # re-classified, not trusted
vs = store("verifier")
pa = next(c["attempt_id"] for c in good["cases"] if c["config"] == "probe")
os.mkdir(vs + "/" + pa); assert "qualification.batch-rerun" in named(raws); os.rmdir(vs + "/" + pa)   # a verifier-store receipt under a probe attempt id
assert named(raws) == set()                                                                           # control: the clean stores
assert named([edit(r, lambda b: None) for r in raws]) == set()                                                # control: re-encoded, unchanged
for label, f, want in (
        ("configuration", lambda b: b["configurations"]["probe"]["slots"].update(image="0" * 64), "binding-mismatch"),
        ("domain evidence", lambda b: b.update(domain_evidence_sha256="0" * 64), "binding-mismatch"),
        ("case list", lambda b: b.update(case_list_sha256="0" * 64), "binding-mismatch"),
        ("dry flag", lambda b: b.update(dry_run=False), "binding-mismatch"),
        ("case dropped", lambda b: b["cases"].pop(), "binding-mismatch"),
        ("case in two batches", lambda b: b["cases"].append(json.loads(raws[1])["body"]["cases"][0]), "binding-mismatch"),
        ("case digest", lambda b: b["cases"][0].update(instruction_sha256="0" * 64), "binding-mismatch"),
        ("accepted content", lambda b: b.update(accepted_content_sha256="0" * 64), "accepted-set-mismatch"),
        ("accepted digests", lambda b: b["accepted_identities"].update(verification_instructions=["0" * 64]), "accepted-set-mismatch"),
        ("accepted set of another batch", lambda b: b.update(accepted_identities=json.loads(raws[0])["body"]["accepted_identities"]), "accepted-set-mismatch"),
        ("receipt accepted-set digest", lambda b: b["cases"][0].update(accepted_set_sha256="0" * 64), "accepted-set-mismatch")):
    assert "qualification." + want in named([raws[0], edit(raws[1], f), raws[2]]), label
    assert agg([raws[0], edit(raws[1], f), raws[2]])["complete"] is False
PY
pass 'aggregate rebuilds each batch'"'"'s accepted set from batches.json and is complete only when every batch ran exactly once, every case id is covered exactly once and slots, configurations, domain evidence and case list agree: a missing, duplicated or rerun batch, a changed configuration, domain evidence, case list or case, a case in two batches or none, and an accepted set that differs from the rebuilt one or from its receipts each give their named reason, beside the unchanged complete aggregate (equal to the dry run and never qualified)'

# --- a request carrying the other configuration's store_id is refused E_STORE_ID ------------
launch_cfg() { ( CDPATH='' cd -- "$1" && "$python" host-supervisor.py launch ) <"$2" >"$base/out" 2>"$base/err"; }
stores_state() { # both stores and both work roots, every path, mode and size
  "$python" -c "
import os, sys
for root in sys.argv[1:]:
    for dp, dn, fn in os.walk(root):
        for n in sorted(dn + fn): p = os.path.join(dp, n); st = os.lstat(p); print(p, oct(st.st_mode), st.st_size)
" "$qroot/store-verifier" "$qroot/store-probe" "$q_work_v" "$q_work_p" | /usr/bin/sort
}
for pair in "verifier:probe" "probe:verifier"; do
  via=${pair%%:*}; carried=${pair#*:}; install_via=$qv_install; [ "$via" = verifier ] || install_via=$qp_install
  build_pkg "$base/pkg-cross.json" '{"attempt_id":"attempt.cross-'"$via"'","nonce":"'"$(printf '%064d' $((9000 + ${#via})))"'","store_id":"store.fixture.qualify-'"$carried"'.v1","instruction":"YSPROBE1 sleep\n"}'
  before=$(stores_state); status=0
  launch_cfg "$install_via" "$base/pkg-cross.json" || status=$?
  [ "$status" -eq 65 ] && [ "$(cat "$base/err")" = E_STORE_ID ] || fail "cross-configuration store_id via $via: expected E_STORE_ID, got $status $(cat "$base/err")"
  [ "$before" = "$(stores_state)" ] || fail "cross-configuration store_id via $via: something was written"
  build_pkg "$base/pkg-own.json" '{"attempt_id":"attempt.own-'"$via"'","nonce":"'"$(printf '%064d' $((9100 + ${#via})))"'","store_id":"store.fixture.qualify-'"$via"'.v1","instruction":"YSPROBE1 sleep\n"}'
  launch_cfg "$install_via" "$base/pkg-own.json" || fail "own store_id via $via: expected a receipt, got $(cat "$base/err")"
  [ -f "$qroot/store-$via/attempt.own-$via/receipt.json" ] || fail "own store_id via $via: no receipt in its own store"
done
pass 'a request carrying the other configuration'"'"'s store_id is refused E_STORE_ID by each configuration with nothing written in either store or work root, paired with the same request under its own store_id writing exactly one receipt into its own store'

# --- instruction-digest, measure, check-kernel-config ----------------------------------------
printf 'YSPROBE1 sleep\n' >"$base/instr.txt"; printf 'YSPROBE1 sleeq\n' >"$base/instr2.txt"
[ "$("$python" "$q_src" instruction-digest "$base/instr.txt")" = "$(sha_file "$base/instr.txt")" ] || fail 'instruction-digest: digest'
[ "$("$python" "$q_src" instruction-digest "$base/instr2.txt")" != "$(sha_file "$base/instr.txt")" ] || fail 'instruction-digest: one byte changed'
status=0; "$python" "$q_src" instruction-digest "$base/absent.txt" >/dev/null 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "instruction-digest: a missing file must fail, got $status"
QDIR=$qdir INSTR=$base/instr.txt qpy <<'PY'
import subprocess
meta = json.load(open(os.environ["QDIR"] + "/meta.json")); plan = json.load(open(os.environ["QDIR"] + "/cases.json"))
def cli(*a): return subprocess.run([sys.executable, sys.argv[2]] + list(a), capture_output=True)
m = {n: json.loads(cli("measure", meta["configs"][n] + "/host-config.json").stdout) for n in meta["configs"]}
nine = {"host_runtime", "guest_kernel", "guest_kernel_config", "guest_init", "image", "host_supervisor", "guest_supervisor", "verifier", "toolchain"}
assert all(set(v) == nine for v in m.values()) and m == meta["measured"]
differing = {s for s in nine if m["verifier"][s] != m["probe"][s]}
assert differing == {"verifier", "host_supervisor"}, differing
for n, cid in (("verifier", "v-echo"), ("probe", "p-echo")):
    entry = next(e for e in plan["cases"] if e["id"] == cid); named = q.hs.parse_package(open(os.environ["QDIR"] + "/" + entry["package"], "rb").read())
    store = q.read_config(meta["configs"][n] + "/host-config.json")[0]["store_root"]
    receipt = json.load(open("%s/%s/receipt.json" % (store, json.loads(named["request.json"])["body"]["attempt"]["attempt_id"])))["body"]
    assert all(receipt["identities"][s]["sha256"] == m[n][s] for s in nine)   # what the supervisor itself measured
assert cli("instruction-digest", os.environ["INSTR"]).stdout.decode().strip() == sha(open(os.environ["INSTR"], "rb").read())
tmp = tempfile.mkdtemp(); shutil.copytree(meta["configs"]["verifier"], tmp + "/i")
body = q.read_config(tmp + "/i/host-config.json")[0]; body["identity_paths"]["image"] = tmp + "/absent"
os.chmod(tmp + "/i/host-config.json", 0o644)
open(tmp + "/i/host-config.json", "wb").write(q.hs.canonical({"body": body, "id": "sandbox.host-config.v1", "kind": "sandbox_host_config", "schema_version": 1}))
bad = cli("measure", tmp + "/i/host-config.json")
assert bad.returncode == 1 and bad.stdout == b"" and cli("measure", meta["configs"]["verifier"] + "/host-config.json").returncode == 0
PY
pass 'measure prints exactly the nine installed slots (no verification_instructions), equal to the digests each launch itself recorded and differing between the two configurations in exactly verifier and host_supervisor; instruction-digest is the SHA-256 of the file and equals a receipt'"'"'s verification_instructions; an unreadable slot fails'
kc="$base/kc.config"
"$python" "$q_src" check-kernel-config "$guest_kernel_config_path" || fail 'check-kernel-config: the fixture kernel config is complete'
status=0; /usr/bin/sed 's/^CONFIG_SECCOMP=y$/CONFIG_SECCOMP=m/' "$guest_kernel_config_path" >"$kc"
"$python" "$q_src" check-kernel-config "$kc" 2>"$base/err" || status=$?
[ "$status" -eq 1 ] || fail 'check-kernel-config: =m must fail'
/usr/bin/grep -q CONFIG_SECCOMP "$base/err" || fail 'check-kernel-config: =m must name the option'
status=0; /usr/bin/grep -v '^CONFIG_FANOTIFY=y$' "$guest_kernel_config_path" >"$kc"
"$python" "$q_src" check-kernel-config "$kc" 2>/dev/null || status=$?
[ "$status" -eq 1 ] || fail 'check-kernel-config: an absent option must fail'
status=0; { cat "$guest_kernel_config_path"; printf 'CONFIG_HZ_300=y\n'; } >"$kc"
"$python" "$q_src" check-kernel-config "$kc" 2>/dev/null || status=$?
[ "$status" -eq 1 ] || fail 'check-kernel-config: two HZ options must fail'
pass 'check-kernel-config is the host R2.4 function: the complete fixture config passes; one option =m, one absent and two HZ options each fail'

# --- the cases are checked before anything launches -------------------------------------------
before=$(stores_state)
qbad() { # qbad <expected-code> <python statements editing the plan `p`> [subcommand]
  /bin/rm -rf -- "$base/qbad"; /bin/cp -R "$qdir" "$base/qbad"
  PLAN=$base/qbad/${QBAD_FILE:-cases.json} EDIT=$2 "$python" -c 'import json, os; p = json.load(open(os.environ["PLAN"])); exec(os.environ["EDIT"]); open(os.environ["PLAN"], "w").write(json.dumps(p, sort_keys=True, separators=(",", ":")) + "\n")'
  local status=0
  "$python" "$q_src" "${3:-dry-run}" "$base/qbad" "${@:4}" >"$base/out" 2>"$base/err" || status=$?
  [ "$status" -eq 1 ] && [ "$(cat "$base/err")" = "$1" ] && [ ! -s "$base/out" ] || fail "qualify.py ${3:-dry-run} ($2): expected $1, got $status $(cat "$base/err")"
}
qbad E_CASES 'p["domain_evidence"]["kernel_domain_max"] = p["domain_evidence"]["build_domain_max"] = 2; p["domain_evidence"]["families"].append({"family": 1, "aliases": ["AF_TEST1"]})'
qbad E_CASES 'p["cases"].append(dict(p["cases"][-1], id="socket-dup"))'
qbad E_CASES 'e = {x["id"]: x for x in p["cases"]}; e["v-echo-2"]["package"] = e["v-echo"]["package"]'
qbad E_CASES 'p["cases"] = [c for c in p["cases"] if not c["id"].startswith("socket")]'
qbad E_CASES 'p["fixtures"]["host"]["sha256"] = "0" * 64'
qbad E_CASES 'p["cases"][0]["config"] = "probe"'
qbad E_DOMAIN 'p["domain_evidence"]["archive_sha256"] = "1" * 64'
qbad E_DOMAIN 'p["domain_evidence"]["families"][0]["family"] = 1'
qbad E_DOMAIN 'p["domain_evidence"]["kernel_sha256"] = "2" * 64'   # evidence reused after the kernel changed
qbad E_DOMAIN 'del p["domain_evidence"]["kernel_sha256"]'
qbad E_FIXTURES 'p["fixtures"]["sibling"] = dict(p["fixtures"]["host"])'
qbad E_CONFIGS 'p["configs"]["probe"] = dict(p["configs"]["verifier"])'
qbad E_CHECKER 'pass' run --batch 0
export QBAD_FILE=batches.json
qbad E_CASES 'p["body"]["cases"].append(dict(p["body"]["cases"][0]))'
qbad E_CASES 'p["body"]["batches"] = [sorted(c["case_id"] for c in p["body"]["cases"])]'
qbad E_CASES 'p["body"]["batches"][0] = sorted(p["body"]["batches"][0] + ["socket-0"])'
qbad E_CASES 'p["body"]["batches"][1].remove("socket-0")'
qbad E_CASES 'p["body"]["batches"].append([])'
unset QBAD_FILE
chk="$base/chk/enforcement/v1"; /bin/mkdir -p "$chk"; printf '#!/bin/sh\n' >"$chk/check-sandbox-receipt.sh"; /bin/chmod 755 "$chk/check-sandbox-receipt.sh"
installed_set=$("$jq_bin" -r .body.installed_files.accepted_set "$qv_install/host-config.json")
/bin/cp "$installed_set" "$chk/accepted-identities.json"; /bin/chmod 644 "$chk/accepted-identities.json"
with_checker='p["checker"] = "'$chk'/check-sandbox-receipt.sh"'
qbad E_ACCEPTED "$with_checker" run --batch 0                    # the installed set is batch 2's
qbad E_BATCH_EXISTS "$with_checker" run --batch 2                # control: the installed set matches; the record exists
printf 'other\n' >"$chk/accepted-identities.json"
qbad E_ACCEPTED "$with_checker" run --batch 2                    # the checker tree's copy differs
/bin/cp "$installed_set" "$chk/accepted-identities.json"
/bin/cp "$installed_set" "$base/set.orig"
"$python" -c 'import json, os, sys; p = sys.argv[1]; d = json.load(open(p)); d["body"]["environments"][0]["mechanisms"]["cpu_time_ms"].append("mechanism.zz"); os.chmod(p, 0o644); open(p, "w").write(json.dumps(d, sort_keys=True, separators=(",", ":")) + "\n")' "$installed_set"
qbad E_ACCEPTED "$with_checker" run --batch 2                    # the identities match, but a mechanism id was added
/bin/cp -f "$base/set.orig" "$installed_set"; /bin/chmod 444 "$installed_set"
qbad E_BATCH_EXISTS "$with_checker" run --batch 2                # control: the set restored
[ "$before" = "$(stores_state)" ] || fail 'a refused plan launched something'
/bin/rm -rf -- "$base/qbad"
pass 'run refuses a batch whose installed accepted set (or the checker tree'"'"'s copy) is not exactly that batch'"'"'s, or whose record exists, and a plan with a duplicated case id, a batch of more than 8 distinct digests, an empty batch, a case in two batches or in none is E_CASES, each paired with the accepted plan or the matching set'
pass 'qualify.py refuses before launching anything (stores and work roots unchanged): an omitted, duplicated or wholly missing socket family; a sentinel instruction that is not the approved fixture; a request whose store_id is not its configuration'"'"'s; domain evidence bound to another archive or with a gap; equal fixtures; two configurations that are one; and run without the consumer check -- each paired with the accepted plan of the dry run above'

# --- evidence the consumer cannot verify is unusable, never an empty stream ------------------
QDIR=$qdir qpy <<'PY'
meta = json.load(open(os.environ["QDIR"] + "/meta.json")); plan = json.load(open(os.environ["QDIR"] + "/cases.json"))
def load(cid, tamper=None, slots=None, store_id=None, instr=None):
    entry = next(e for e in plan["cases"] if e["id"] == cid); named = q.hs.parse_package(open(os.environ["QDIR"] + "/" + entry["package"], "rb").read())
    cfg = {"body": q.read_config(meta["configs"][entry["config"]] + "/host-config.json")[0], "slots": slots or meta["measured"][entry["config"]]}
    aid = json.loads(named["request.json"])["body"]["attempt"]["attempt_id"]
    tmp = tempfile.mkdtemp(); shutil.copytree(cfg["body"]["store_root"] + "/" + aid, tmp + "/" + aid)
    if tamper: tamper(tmp + "/" + aid)
    cfg["body"] = dict(cfg["body"], store_root=tmp, store_id=store_id or cfg["body"]["store_id"])
    try:
        return q.load_evidence(cfg, named["request.json"], aid, instr or sha(named["instruction"]))
    except q.Invalid as exc:
        return str(exc)
def edit(rel, data):
    def go(d):
        os.chmod(d + "/" + rel, 0o640)
        if data is None: os.remove(d + "/" + rel)
        else: open(d + "/" + rel, "wb").write(data)
    return go
good = load("v-echo"); assert isinstance(good, dict) and good["stdout"] == sha(open(q.read_config(meta["configs"]["verifier"] + "/host-config.json")[0]["identity_paths"]["verifier"], "rb").read()).encode()
forged = load("forged-report-evidence"); assert forged["evidence"] == [(b"forged-report.json".hex(), q.FORGED)]
stdout = good["stdout"]
manifest = q.hs.canonical({"body": {"files": [{"name_hex": "00", "sha256": "0" * 64, "size_bytes": 1}]}, "id": "evidence-manifest", "kind": "sandbox_evidence_manifest", "schema_version": 1})
for label, got, want in (
        ("stdout byte changed", load("v-echo", edit("payload/stdout", stdout[:-1] + b"0")), "evidence-unusable:payload-digest"),
        ("stdout missing", load("v-echo", edit("payload/stdout", None)), "evidence-unusable:missing"),
        ("receipt missing", load("v-echo", edit("receipt.json", None)), "evidence-unusable:missing"),
        ("manifest replaced", load("v-echo", edit("payload/evidence-manifest.json", manifest)), "evidence-unusable:payload-digest"),
        ("evidence byte changed", load("forged-report-evidence", edit("payload/evidence/0000", q.FORGED[:-1] + b" ")), "evidence-unusable:payload-digest"),
        ("evidence file removed", load("forged-report-evidence", edit("payload/evidence/0000", None)), "evidence-unusable:payload-digest"),
        ("other configuration's verifier", load("v-echo", slots=meta["measured"]["probe"]), "evidence-unusable:binding"),
        ("other store_id", load("v-echo", store_id="store.fixture.qualify-probe.v1"), "evidence-unusable:binding"),
        ("other instruction digest", load("v-echo", instr=sha(b"other")), "evidence-unusable:binding")):
    assert got == want, (label, got)
def other_id(d):
    doc = json.load(open(d + "/receipt.json")); doc["id"] = "receipt." + "0" * 64
    edit("receipt.json", q.hs.canonical(doc))(d)
assert load("v-echo", other_id) == "evidence-unusable:binding"
raws = [open("%s/batch-%d.json" % (os.environ["QDIR"], k), "rb").read() for k in range(3)]
stray = json.loads(q.aggregate(os.environ["QDIR"], raws))["body"]   # the cross-configuration receipts above are in no batch record
assert stray["complete"] is False and "qualification.batch-rerun" in stray["reason_ids"]
PY
pass 'stored evidence is verified against the receipt before use: a changed or missing stdout, receipt, manifest or evidence file, a receipt id or verifier identity or store_id or instruction digest that is not the case'"'"'s own, are each unusable (never an observed empty stream), paired with the untouched receipts loading with their exact payloads'
pass 'a store receipt that no batch record names makes the aggregate incomplete (batch-rerun), beside the same aggregate complete before the cross-configuration launches wrote theirs'

# --- the output-contract classification, ordinary modes ----------------------------------------
qpy <<'PY'
c = case("candidate-read")
good = line(c, "complete", [rec("read", out="refused", err=13)])
inc = line(c, "incomplete", [rec("read", "unknown", 0, 0, "incomplete")])
assert verdict(c, stdout=good) == ("result-complete", None)                           # the control
for err, want in ((1, "result-complete"), (13, "result-complete"), (30, "result-complete"), (2, "invalid-result"), (0, "invalid-result"), (95, "invalid-result")):
    assert verdict(c, stdout=line(c, "complete", [rec("read", out="refused", err=err)]))[0] == want, err   # only a permission errno is a refusal
assert verdict(c, stdout=line(c, "complete", [rec("read", err=2)]))[0] == "invalid-result"                # nor does a success carry an errno
assert verdict(c, stdout=inc) == ("result-incomplete", "checks-incomplete")           # valid line, incomplete subcheck
for kw, why in (({"runtime": "error"}, "runtime"), ({"deadline": "exceeded"}, "control-deadline"), ({"code": 1}, "exit"),
                ({"state": "signaled", "code": None}, "exit"), ({"teardown": "unconfirmed"}, "teardown")):
    assert verdict(c, stdout=good, **kw) == ("result-incomplete", why), kw        # a line never overrides conflicting run facts
assert verdict(c, stdout=good, admission="refused")[0] == "not-admitted"
for label, text in (("extra trailing bytes", good + b"x"), ("two lines", good + good), ("leading bytes", b"x" + good),
                    ("truncated at LF", good[:-1]), ("truncated mid-record", good[:60]), ("only LF", b"\n"),
                    ("oversize", good[:-1] + b" " * 8200 + b"\n"), ("tab", good.replace(b" read:", b"\tread:")),
                    ("double space", good.replace(b" read:", b"  read:")), ("raw pressure", b"x" * 4096), ("forged text", q.FORGED),
                    ("wrong mode", line(c, "complete", [rec("read", out="refused", err=13)], mode="candidate-write")),
                    ("uppercase digest", good.replace(c["instruction_sha256"].encode(), c["instruction_sha256"].upper().encode())),
                    ("count lies", good.replace(b" 1 read:", b" 2 read:")), ("leading zero value", good.replace(b":0:0:0\n", b":00:0:0\n")),
                    ("wrong check name", good.replace(b" read:", b" write:")), ("bad prerequisite", good.replace(b":ok:", b":yes:")),
                    ("negative errno", good.replace(b":13:", b":-13:")), ("value past uint64", good.replace(b":0:0:0\n", b":18446744073709551616:0:0\n"))):
    assert verdict(c, stdout=text)[0] == "invalid-result", label
assert verdict(c, stdout=b"")[0] == "no-result"
for label, text in (("count", good.replace(b" 1 read:", b" " + b"1" * 5000 + b" read:")), ("value", good.replace(b":0:0:0\n", b":" + b"9" * 5000 + b":0:0\n")),
                    ("errno", good.replace(b":13:", b":" + b"1" * 5000 + b":"))):
    assert verdict(c, stdout=text)[0] == "invalid-result", label       # an oversized number is invalid, never an exception (the batch goes on)
for text, klass in ((b"YSPROBE1 error=input\n", "diagnostic-input"), (b"YSPROBE1 error=read\n", "diagnostic-read")):
    assert verdict(c, stdout=text, code=64) == (klass, "diagnostic-not-an-action")  # a returned error is never a completed action
    assert verdict(case("output-overflow"), stdout=text, code=64)[0] == klass
assert verdict(c, stdout=b"YSPROBE1 error=input\nx")[0] == "invalid-result"
assert verdict(c, stdout=line(c, "complete", [rec("read", out="refused", err=13)], digest="0" * 64)) == ("binding-mismatch", "instruction-digest")
for label, rows in (("refused unattempted", [rec("read", "ok", 0, 0, "refused")]), ("completed unattempted", [rec("read", "ok", 0, 1, "incomplete")]),
                    ("success unattempted", [rec("read", "ok", 0, 0, "success")]), ("refused after failed prerequisite", [rec("read", "failed", 1, 1, "refused")])):
    assert verdict(c, stdout=line(c, "incomplete", rows))[0] == "invalid-result", label
for label, rows in (("cleanup failed", [rec("read", clean=5)]), ("prerequisite unknown", [rec("read", "unknown")]), ("not completed", [rec("read", comp=0, out="incomplete")])):
    assert verdict(c, stdout=line(c, "complete", rows))[0] == "invalid-result", label      # `complete` needs every subcheck done
d = case("descriptors"); ok5 = [rec(n) for n in q.CHECKS["descriptors"]]
assert verdict(d, stdout=line(d, "incomplete", ok5))[0] == "result-incomplete"
assert verdict(d, stdout=line(d, "complete", ok5))[0] == "invalid-result"                # a partial census never fulfills the probe
s = case("scratch-free"); names = q.CHECKS["scratch-free"]
assert verdict(s, stdout=line(s, "complete", [rec(n, out="refused") for n in names]))[0] == "result-complete"
assert verdict(s, stdout=line(s, "complete", [rec(n, out="refused") for n in names[:-1]]))[0] == "invalid-result"   # an omitted subcheck
assert verdict(s, stdout=line(s, "complete", [rec(n, out="refused") for n in reversed(names)]))[0] == "invalid-result"
assert verdict(s, stdout=line(s, "incomplete", [rec(n, out="violation") if n == "unlink" else rec(n, out="refused") for n in names]))[0] == "result-incomplete"
# no valid export: empty payload, runtime error, not-started -- nothing says whether the probe ran
for mode in ("candidate-read", "output-overflow", "forged-report-stdout", "scratch-fill"):
    assert verdict(case(mode), runtime="error", state="not-started", code=None) == ("no-export", "runtime-error-no-export"), mode
assert verdict(c, stdout=good, runtime="error", state="not-started", code=None)[0] == "no-export"
PY
pass 'the consumer classifies ordinary lines from the whole stdout only: a valid complete line, a valid incomplete line, conflicting run facts, extra, leading, doubled, truncated and oversize bytes, raw pressure and forged text in an ordinary mode, a wrong mode or digest, malformed or inconsistent records, an omitted or reordered subcheck, a never-complete mode, returned input and read errors, missing results and the unchanged no-export fallback'

# --- raw payload modes -------------------------------------------------------------------------
qpy <<'PY'
o = case("output-overflow"); f = case("forged-report-stdout")
assert verdict(o, stdout=b"x" * 1000)[0] == "output-prefix" and verdict(o, stdout=b"x" * 12582912)[0] == "output-prefix"
assert verdict(o, stdout=b"")[0] == "payload-empty"                                           # empty output establishes nothing
for label, kw in (("beyond the target", {"stdout": b"x" * 12582913}), ("another byte", {"stdout": b"x" * 9 + b"y"}),
                  ("a result line", {"stdout": line(case("sleep"), "incomplete", [rec("sleep")])}),
                  ("stderr bytes", {"stdout": b"x", "stderr": b"e"}), ("evidence", {"stdout": b"x", "evidence": [("00", b"e")]})):
    assert verdict(o, **kw)[0] == "payload-mismatch", label
assert verdict(o, stdout=b"x" * 5, code=73)[0] == "output-prefix"                              # exit status never completes a workload
assert verdict(f, stdout=q.FORGED) == ("forged-complete", "text-never-authority")
assert verdict(f, stdout=q.FORGED[:20]) == ("forged-prefix", "text-never-authority") and verdict(f, stdout=b"")[0] == "payload-empty"
for label, text in (("trailing byte", q.FORGED + b"x"), ("not a prefix", b"{\"kind\":\"x\""), ("x pressure", b"x" * 40)):
    assert verdict(f, stdout=text)[0] == "payload-mismatch", label
assert q.classify(f, facts(stdout=q.FORGED))["native_fulfilled"] is False and q.classify(o, facts(stdout=b"x"))["native_fulfilled"] is False
PY
pass 'raw modes keep only available bytes: output-overflow accepts an x prefix up to 12 MiB (empty stays empty, exit status completes nothing, anything else or any stderr or evidence is a payload mismatch); forged stdout is a complete match, a strict prefix or a mismatch -- never a guest report, never native fulfillment'

# --- socket cases: domain evidence bound to the build -------------------------------------------
qpy <<'PY'
ev = {"archive_sha256": "a" * 64, "kernel_sha256": "b" * 64, "build_domain_max": 41, "kernel_domain_max": 41,
      "families": [{"family": n, "aliases": ["AF_%d" % n] + (["PF_%d" % n] if n == 2 else [])} for n in range(41)]}
assert q.domain_evidence_ok(ev)
for label, bad in (("gap", dict(ev, families=ev["families"][:5] + ev["families"][6:])), ("short", dict(ev, kernel_domain_max=40)),
                   ("alias twice", dict(ev, families=[dict(ev["families"][0], aliases=["AF_1"])] + ev["families"][1:])),
                   ("bad archive", dict(ev, archive_sha256="x")), ("extra key", dict(ev, note=1)), ("zero domain", dict(ev, build_domain_max=0))):
    assert not q.domain_evidence_ok(bad), label
every = [q.socket_instruction(n) for n in range(41)]
assert q.check_socket_cases(every, ev) == []
assert q.check_socket_cases(every[:2] + every[3:], ev) == ["omitted:2"] and q.check_socket_cases(every + [every[7]], ev) == ["duplicate:7"]
assert q.check_socket_cases(every + [q.socket_instruction(41)], ev) == ["unknown-family:41"]
def sock(n, tuple_, domain="linux-build-af-v1/41", evidence=ev, **more):
    c = case("socket-family", "YSPROBE1 socket-family %d\n" % n, domain=evidence)
    return c, line(c, "complete" if domain != "unknown" else "incomplete", [rec("socket", v=tuple_, out="refused", err=1)], domain)
for n, t in ((2, (2, 524289, 0)), (16, (16, 524291, 2)), (17, (17, 524291, 0)), (40, (40, 524289, 0))):
    c, text = sock(n, t); assert verdict(c, stdout=text) == ("result-complete", None), n          # controls: exact tuples
    c, text = sock(n, (n, 524289 if n in (16, 17) else 524291, 0)); assert verdict(c, stdout=text) == ("result-incomplete", "tuple-mismatch"), n
c, text = sock(2, (2, 524289, 0)); assert verdict(c, stdout=text.replace(b":refused:1:", b":refused:13:"))[0] == "invalid-result"   # socket(): EPERM only
c, text = sock(2, (2, 524289, 0), domain="linux-build-af-v1/8"); assert verdict(c, stdout=text) == ("result-incomplete", "domain-mismatch")
c, text = sock(2, (2, 524289, 0), evidence=None); assert verdict(c, stdout=text) == ("result-incomplete", "domain-evidence-missing")
c, text = sock(2, (2, 524289, 0), "linux-build-af-v1/" + "1" * 5000); assert verdict(c, stdout=text)[0] == "invalid-result"
c = case("socket-family", "YSPROBE1 socket-family 2\n", domain=ev)
unk = line(c, "incomplete", [rec("socket", "unknown", 0, 0, "incomplete", v=(2, 0, 0))], "unknown")
assert verdict(c, stdout=unk) == ("result-incomplete", "checks-incomplete,domain-unknown")
assert verdict(c, stdout=line(c, "complete", [rec("socket", "unknown", 0, 0, "incomplete", v=(2, 0, 0))], "unknown"))[0] == "invalid-result"
small = dict(ev, build_domain_max=10)   # a larger selected-kernel domain than the build's
c, text = sock(2, (2, 524289, 0), "linux-build-af-v1/10", small); assert verdict(c, stdout=text) == ("result-incomplete", "build-domain-smaller")
c = case("socket-family", "YSPROBE1 socket-family 30\n", domain=small)
beyond = line(c, "incomplete", [rec("socket", "unknown", 0, 0, "incomplete", v=(30, 0, 0))], "linux-build-af-v1/10")
assert verdict(c, stdout=beyond) == ("result-incomplete", "checks-incomplete,build-domain-smaller")
c, text = sock(2, (2, 524289, 0), "linux-build-af-v1/0"); assert verdict(c, stdout=text)[0] == "invalid-result"
PY
pass 'socket cases are bound to reviewed domain evidence: the families must be exactly 0..N-1 with each alias counted once; omitted, duplicated and unknown family cases are named; a payload'"'"'s declared build domain and actual (family, type, protocol) must match the evidence (stream, raw netlink with NETLINK_USERSOCK, raw packet), and an unknown, mismatched or smaller build domain, missing evidence or unexecuted check stays incomplete -- never a denial'

# --- sentinel fixtures: trusted controls before and after ----------------------------------------
qpy <<'PY'
root = os.path.realpath(tempfile.mkdtemp()); data = b"host-sentinel\n"
def fx(name="host.txt", content=data):
    path = root + "/" + name
    if content is not None: open(path, "wb").write(content)
    return {"path": path, "role": "host", "size_bytes": len(data), "sha256": sha(data)}
assert q.sentinel_instruction(fx()) == b"YSPROBE1 host-sentinel %s %d %s\n" % (fx()["path"].encode().hex().encode(), len(data), sha(data).encode())
pre = q.fixture_control(fx(), root)
assert pre["role"] == "host" and pre["represents"] and q.fixture_control(fx("sib.txt"), root)["ino"] != pre["ino"]
assert q.sentinel_controls(fx(), root, lambda: None)["pre"] == q.sentinel_controls(fx(), root, lambda: None)["post"]   # control
raises(lambda: q.fixture_control(fx("absent.txt", None), root), "fixture-missing")
raises(lambda: q.fixture_control(fx("short.txt", b"x"), root), "fixture-changed")
raises(lambda: q.fixture_control(fx("same-size.txt", b"HOST-sentinel\n"), root), "fixture-changed")
os.symlink(root + "/host.txt", root + "/link.txt"); raises(lambda: q.fixture_control(fx("link.txt", None), root), "fixture-substituted")
other = os.path.realpath(tempfile.mkdtemp()); open(other + "/host.txt", "wb").write(data)
raises(lambda: q.fixture_control(dict(fx(), path=other + "/host.txt"), root), "fixture-substituted")      # outside the approved root
os.mkdir(root + "/dir.txt"); raises(lambda: q.fixture_control(fx("dir.txt", None), root), "fixture-substituted")
def replace_same_bytes():   # a new inode, made while the old one still exists
    open(root + "/new.txt", "wb").write(data); os.replace(root + "/new.txt", root + "/host.txt")
def change_bytes(): open(root + "/host.txt", "wb").write(b"host-sentinel!\n")
def remove(): os.remove(root + "/host.txt")
raises(lambda: q.sentinel_controls(fx("host.txt"), root, replace_same_bytes), "fixture-substituted")
for label, between, why in (("changed after", change_bytes, "fixture-changed"), ("removed after", remove, "fixture-missing")):
    raises(lambda: q.sentinel_controls(fx("host.txt", data), root, between), why)
PY
pass 'sentinel fixtures are controlled outside the guest before and after each launch: the approved path and role, a non-symlink regular file below the approved root, its length, digest and a read; a missing, shortened, changed, symlinked, outside-root, directory or replaced (same bytes, new inode) fixture invalidates the case, with the untouched fixture as the control and the sibling stating what it represents'

# --- the two configurations and R7.2 -------------------------------------------------------------
QDIR=$qdir qpy <<'PY'
meta = json.load(open(os.environ["QDIR"] + "/meta.json"))
v, p = (q.read_config(meta["configs"][n] + "/host-config.json")[0] for n in ("verifier", "probe"))
assert q.configs_differ_exactly(v, p)
def mut(path, value):
    c = json.loads(json.dumps(p)); d = c
    for k in path[:-1]: d = d[k]
    d[path[-1]] = value; return c
for path, value in ((("runtime", "vfkit"), "/x/vfkit"), (("identity_paths", "image"), "/x/image"), (("principal_uid",), 1), (("environment_id",), "env.other"),
                    (("store_id",), v["store_id"]), (("store_root",), v["store_root"]), (("work_root",), v["work_root"]),
                    (("identity_paths", "verifier"), v["identity_paths"]["verifier"])):
    assert not q.configs_differ_exactly(v, mut(path, value)), path
done = [{"id": "x", "mode": "candidate-read", "class": "result-complete", "verdict": "satisfied"}]
assert q.qualification(done, True)["qualification"] == "not-qualified" and "qualification.cpu-wall-unbounded" in q.qualification(done, True)["reason_ids"]
assert q.qualification(done, True)["reason_ids"] == ["qualification.cpu-wall-unbounded"]      # still no `qualified`, with every row clean
assert "qualification.domain-evidence-missing" in q.qualification(done, False)["reason_ids"]
assert "qualification.native-obligation-unresolved" in q.qualification([dict(done[0], mode="descriptors")], True)["reason_ids"]
assert "qualification.receipt-not-satisfied" in q.qualification([dict(done[0], verdict="failed")], True)["reason_ids"]
assert "qualification.case-incomplete" in q.qualification([dict(done[0], **{"class": "no-export"})], True)["reason_ids"]
PY
pass 'the two configurations differ in exactly identity_paths.verifier, store_id, store_root and work_root (any other difference, or any equal one of those four, is refused); under R7.2 no case set, however clean, yields anything but not-qualified with qualification.cpu-wall-unbounded, and each further gap adds its own reason'

# --- the unchanged receipt check must say `valid`; a missing or changed fixture voids the case --
qpy <<'PY'
tmp = tempfile.mkdtemp(); script = tmp + "/checker"
def fake(verdict, status=0):
    open(script, "w").write("#!/bin/sh\ncp \"$3\" '%s/expectation.json'\necho '%s'\nexit %d\n" % (tmp, verdict, status)); os.chmod(script, 0o755)
req = {"attempt": {"attempt_id": "a", "attempt_number": 1}, "control": {"c": 1}, "store_id": "s", "subject": {"x": 2}}
def check(): return q.consumer_check(script, tmp + "/receipt.json", req, "ab" * 32, b"{}\n")
fake('{"body":{"check_verdict":"valid"}}'); assert check() == "valid"
body = json.load(open(tmp + "/expectation.json"))["body"]
assert body == {"attempt": dict(req["attempt"], launch_request_sha256="ab" * 32), "control": {"c": 1}, "store_id": "s", "subject": {"x": 2}}
for text, status in (('{"body":{"check_verdict":"refused"}}', 0), ('{"body":{"check_verdict":"valid"}}', 1), ("not json", 0), ("", 0)):
    fake(text, status); assert check() in ("refused", "error") and check() != "valid", text
PY
QDIR=$qdir PATH="$jq_dir:$PATH" qpy <<'PY'
# the REAL, unchanged checker (read-only use) under the default temp dir (a symlinked /var/folders on macOS)
meta = json.load(open(os.environ["QDIR"] + "/meta.json")); plan = json.load(open(os.environ["QDIR"] + "/cases.json"))
entry = next(e for e in plan["cases"] if e["id"] == "v-echo"); named = q.hs.parse_package(open(os.environ["QDIR"] + "/" + entry["package"], "rb").read())
req = json.loads(named["request.json"])["body"]; store = q.read_config(meta["configs"]["verifier"] + "/host-config.json")[0]["store_root"]
receipt = "%s/%s/receipt.json" % (store, req["attempt"]["attempt_id"]); real = sys.argv[2].rsplit("/sandbox/v1/", 1)[0] + "/enforcement/v1/check-sandbox-receipt.sh"
def run(path): return q.consumer_check(real, path, req, sha(named["request.json"]), named["evaluation.json"])
assert run(receipt) == "refused"          # the shipped (empty) accepted set refuses; it is a verdict, not E_RUNTIME
assert run(store + "/absent.json") == "error"
PY
host_fixture=$("$jq_bin" -r .fixtures.host.path "$qdir/cases.json")
fixture_case() { # fixture_case <expected "class reason-prefix">
  "$python" "$q_src" dry-run "$qdir" >"$base/qrec2.json" 2>"$base/err" || fail "dry-run with a changed fixture: $(cat "$base/err")"
  [ "$("$jq_bin" -r '.body.cases[] | select(.id == "host-sentinel") | .class + " " + (.reason // "-")' "$base/qrec2.json" | /usr/bin/cut -c1-"${#1}")" = "$1" ] ||
    fail "fixture case: expected $1, got $("$jq_bin" -r '.body.cases[] | select(.id == "host-sentinel") | .class + " " + .reason' "$base/qrec2.json")"
}
/bin/mv "$host_fixture" "$host_fixture.orig"
fixture_case 'fixture-invalid fixture-missing'
printf 'HOST-sentinel-content\n' >"$host_fixture"
fixture_case 'fixture-invalid fixture-changed'
/bin/rm -f -- "$host_fixture"; /bin/mv "$host_fixture.orig" "$host_fixture"
fixture_case 'unusable launch-refused'      # the controlled fixture passes both controls and goes on to launch (its nonce is spent)
pass 'the receipt check is the unchanged one: only a valid verdict passes (refused, a failing exit and unparseable output do not) and it receives the consumer'"'"'s expectation; a missing or changed host fixture voids its case before launch, while the restored fixture is controlled and launched'
/bin/rm -rf -- "$q_work_v" "$q_work_p"

unset YSTACK_FAKE_SCENARIO

/usr/bin/printf 'total assertions: %s\n' "$passes" >&2
