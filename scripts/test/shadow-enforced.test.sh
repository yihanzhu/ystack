#!/bin/bash
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-shadow-consumer.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() { /bin/chmod -R u+w -- "$tmp" 2>/dev/null || true; /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT
case "$(/usr/bin/uname -s):$(/usr/bin/uname -m)" in
  Darwin:*) jq_asset=jq-osx-amd64 ;;
  Linux:x86_64) jq_asset=jq-linux64 ;;
  *) /usr/bin/printf 'unsupported test host\n' >&2; exit 1 ;;
esac
jq_bin="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset"
[ -x "$jq_bin" ] || { /usr/bin/printf 'missing pinned jq\n' >&2; exit 1; }
jq_bin=$(CDPATH='' cd -P -- "${jq_bin%/*}" && /usr/bin/printf '%s/%s' "$PWD" "${jq_bin##*/}")
/usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 \
  "$root/adapters/local-git-materializer/v1/object-closure.c" -o "$tmp/object-closure"
/bin/chmod 0555 "$tmp/object-closure"

python3 -I -S -B - "$root" "$tmp" "$tmp/object-closure" "$jq_bin" <<'PY'
import hashlib, importlib.util, json, os, pathlib, shutil, stat, sys, tempfile, types

root, base, helper, jq = map(pathlib.Path, sys.argv[1:])
dependency_work = base / "dependency-work"; dependency_work.mkdir()
spec = importlib.util.spec_from_file_location("shadow_consumer", root / "shadow/v1/_consumer.py")
c = importlib.util.module_from_spec(spec); sys.modules[spec.name] = c; spec.loader.exec_module(c)
checks = 0
def ok(value, message):
    global checks
    assert value, message; checks += 1
def refuses(code, call):
    global checks
    try: call()
    except c.Refusal as exc:
        assert exc.code == code, (exc.code, code); checks += 1; return
    raise AssertionError("accepted " + code)
def write(path, raw, mode=0o440):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists(): path.chmod(0o640)
    path.write_bytes(raw); path.chmod(mode)
def sha(raw): return hashlib.sha256(raw).hexdigest()
def document(kind, identifier, body):
    return c.canonical({"schema_version": 1, "kind": kind, "id": identifier, "body": body})
def parent_doc(path, raw):
    return document("shadow_consumer_parent_context", "shadow.parent", {
        "helper_source_sha256": c.HELPER_SOURCE_SHA256, "helper_build_record_sha256": "2" * 64,
        "helper_executable_sha256": sha(raw), "helper_executable_size": len(raw),
        "helper_path": str(path)})

# Parallel shards share TMPDIR. Stabilize only change metadata for ancestors outside this
# fixture; every object at or below the owned fixture root keeps real OS observations.
raw_metadata, raw_named = c._metadata, c._named_metadata
external = {}
def fd_path(fd):
    if sys.platform == "darwin":
        raw = c.fcntl.fcntl(fd, 50, b"\0" * 1024)
        return raw.split(b"\0", 1)[0].decode()
    return os.path.realpath("/proc/self/fd/" + str(fd))
def stable_external(value, path):
    if path == str(base) or path.startswith(str(base) + "/"):
        return value
    key = (value.st_dev, value.st_ino)
    first = external.setdefault(key, (value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns))
    return types.SimpleNamespace(st_dev=value.st_dev, st_ino=value.st_ino, st_mode=value.st_mode,
        st_uid=value.st_uid, st_gid=value.st_gid, st_nlink=first[0],
        st_size=first[1], st_mtime_ns=first[2], st_ctime_ns=first[3])
def stable_metadata(fd): return stable_external(raw_metadata(fd), fd_path(fd))
def stable_named(name, parent_fd):
    path = os.path.normpath(os.path.join(fd_path(parent_fd), name))
    return stable_external(raw_named(name, parent_fd), path)
c._metadata, c._named_metadata = stable_metadata, stable_named

c.verify_helper_source()
physical_python = os.path.realpath(c.sys.executable); c.sys.executable = physical_python
ok(c.isolated_python_argv()[1:4] == ["-I", "-S", "-B"], "isolated Python argv")
context = base / "context"; helper_raw = helper.read_bytes(); write(context, parent_doc(helper, helper_raw), 0o400)
body = c.capture_parent_context(os.open(context, os.O_RDONLY))
ok(body["helper_executable_sha256"] == sha(helper_raw), "trusted parent context")
context.chmod(0o600); refuses("E_PARENT_CONTEXT", lambda: c.capture_parent_context(os.open(context, os.O_RDWR)))
write(context, parent_doc(helper, helper_raw).replace(b'"shadow.parent"', b'"changed"'), 0o400)
refuses("E_PARENT_CONTEXT", lambda: c.capture_parent_context(os.open(context, os.O_RDONLY)))

dep = c.snapshot_dependency(str(helper), sha(helper_raw), len(helper_raw), str(dependency_work / "helper"), "helper")
concurrent = pathlib.Path(tempfile.mkdtemp(prefix="ystack-concurrent-", dir=base.parent))
c.probe_dependency(dep, ["version"], b"ystack-object-closure-v1\n")
shutil.rmtree(concurrent)
ok(True, "external temp churn does not weaken owned fixture checks")
ok(stat.S_IMODE(os.stat(dependency_work / "helper").st_mode) == 0o500, "helper private snapshot")
helper.chmod(0o755); helper.write_bytes(helper_raw + b"\n")
refuses("E_DEPENDENCY", dep.recheck); dep.close(); helper.write_bytes(helper_raw); helper.chmod(0o555)
jq_dep = c.snapshot_jq(str(jq), str(dependency_work / "jq"))
c.probe_dependency(jq_dep, ["--version"], b"jq-1.6\n"); jq_dep.close(); ok(True, "pinned jq admitted and run")
original_jq_pin = c.JQ_SHA256[c.sys.platform]
c.JQ_SHA256[c.sys.platform] = "0" * 64
refuses("E_DEPENDENCY", lambda: c.snapshot_jq(str(jq), str(dependency_work / "wrong-jq")))
c.JQ_SHA256[c.sys.platform] = original_jq_pin
marker = base / "marker"
malicious = base / "malicious"; write(malicious, ("#!/bin/sh\ntouch '%s'\n" % marker).encode(), 0o555)
refuses("E_DEPENDENCY", lambda: c.snapshot_dependency(str(malicious), "0" * 64,
        malicious.stat().st_size, str(dependency_work / "bad"), "helper"))
ok(not marker.exists(), "unapproved executable never ran")

# A helper whose bytes initially match is still checked at the real invocation boundary.
raced_marker = base / "raced-marker"
raced_helper = base / "raced-helper"
raced_raw = ("#!/bin/sh\ntouch '%s'\nprintf 'ystack-object-closure-v1\\n'\n" % raced_marker).encode()
write(raced_helper, raced_raw, 0o555)
raced = c.snapshot_dependency(str(raced_helper), sha(raced_raw), len(raced_raw),
                              str(dependency_work / "raced"), "helper")
raced_helper.chmod(0o755)
raced_helper.write_bytes(raced_raw + b"# replaced\n")
refuses("E_DEPENDENCY", lambda: c.probe_dependency(
    raced, ["version"], b"ystack-object-closure-v1\n"))
ok(not raced_marker.exists(), "raced helper refused before version execution")
raced.close()

# The parent's accepted result is an input. A request-selected digest cannot replace it.
wrong_context = base / "wrong-context"
wrong = json.loads(parent_doc(helper, helper_raw))
wrong["body"]["helper_executable_sha256"] = "3" * 64
write(wrong_context, c.canonical(wrong), 0o400)
wrong_body = c.capture_parent_context(os.open(wrong_context, os.O_RDONLY))
refuses("E_DEPENDENCY", lambda: c.snapshot_dependency(
    str(helper), wrong_body["helper_executable_sha256"], wrong_body["helper_executable_size"],
    str(dependency_work / "wrong-result"), "helper"))
ok(not raced_marker.exists(), "wrong accepted result has no helper effect")

# The bounded reader catches a leaf mutation that happens during its own read.
leaf = base / "leaf-race"
write(leaf, b"stable", 0o600)
leaf_held = c._open_held(str(leaf), False, lambda *_: True, "E_DEPENDENCY")
real_read, changed = c.os.read, [False]
def racing_read(fd, count):
    raw = real_read(fd, count)
    if fd == leaf_held.fd and raw and not changed[0]:
        changed[0] = True
        leaf.write_bytes(b"changed")
    return raw
c.os.read = racing_read
refuses("E_DEPENDENCY", lambda: leaf_held.read(32, "E_DEPENDENCY"))
c.os.read = real_read
leaf_held.close()

walk = base / "walk"; write(walk / "ancestor/input", b"stable", 0o400)
held = c._open_held(str(walk / "ancestor/input"), False, lambda *_: True, "E_DEPENDENCY")
(walk / "ancestor").rename(walk / "moved"); (walk / "ancestor").mkdir(); write(walk / "ancestor/input", b"new", 0o400)
refuses("E_DEPENDENCY", lambda: held.recheck("E_DEPENDENCY")); held.close()
held = c._open_held(str(walk / "moved/input"), False, lambda *_: True, "E_DEPENDENCY")
(walk / "moved").chmod(0o777); refuses("E_DEPENDENCY", lambda: held.recheck("E_DEPENDENCY")); held.close()
fifo = base / "fifo"; os.mkfifo(fifo)
refuses("E_DEPENDENCY", lambda: c._open_held(str(fifo), False, lambda *_: True, "E_DEPENDENCY"))
parent = c._open_held(str(base), True, lambda *_: True, "E_DEPENDENCY")
refuses("E_DEPENDENCY", lambda: c._open_child(parent, "fifo", False, lambda *_: True, "E_DEPENDENCY")); parent.close()

fd = os.open(base, os.O_RDONLY); state = os.fstat(fd); real_acl, real_platform = c._acl_state, c.sys.platform
c.sys.platform = "linux"
c._acl_state = lambda _fd: ([(0x02, 4, 123)], None)
ok(not c._installed_rule(123)(fd, state, False), "Linux named-user ACL refused")
c._acl_state = lambda _fd: (None, [(0x10, 2, 0)])
ok(not c._root_rule(fd, state, False), "Linux default write ACL refused")
c.sys.platform = "darwin"; c._acl_state = lambda _fd: (_ for _ in ()).throw(OSError(13, "acl"))
ok(not c._root_rule(fd, state, False), "ACL observation error refused")
c._acl_state = lambda _fd: ([(1, 0, 1 << 2)], None)
darwin_state = types.SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o555)
ok(c._installed_rule(123)(fd, darwin_state, False), "Darwin root write grant remains trusted")
c._acl_state = lambda _fd: ([(1, 456, 1 << 2)], None)
ok(not c._installed_rule(123)(fd, state, False), "Darwin other-principal write ACL refused")

# Exercise the Darwin API error branch itself, rather than only the rule wrapper.
class Call:
    def __init__(self, result): self.result = result
    def __call__(self, *args):
        if self.result == "entry-error":
            c.ctypes.set_errno(13)
            return -1
        return self.result
class BrokenAclLib:
    def __init__(self):
        self.acl_get_fd_np = Call(1)
        self.acl_get_entry = Call("entry-error")
        self.acl_get_tag_type = Call(0)
        self.acl_get_qualifier = Call(0)
        self.acl_get_permset = Call(0)
        self.acl_get_perm_np = Call(0)
        self.mbr_uuid_to_id = Call(-1)
        self.acl_free = Call(0)
real_cdll = c.ctypes.CDLL
c.ctypes.CDLL = lambda *_args, **_kwargs: BrokenAclLib()
try:
    try: c._darwin_acl(fd)
    except OSError: ok(True, "Darwin entry API error is not empty ACL")
    else: raise AssertionError("Darwin ACL API error accepted")
finally:
    c.ctypes.CDLL = real_cdll

c.sys.platform = "linux"
c._acl_state = lambda _fd: (None, None)
store_state = types.SimpleNamespace(st_mode=stat.S_IFDIR | 0o750, st_uid=123, st_gid=456)
ok(c._store_rule(123, 456, 0o750, True)(fd, store_state, False), "Linux no-ACL store control")
c._acl_state = lambda _fd: ([(0x10, 0, 0)], None)
ok(not c._store_rule(123, 456, 0o750, True)(fd, store_state, False), "store rejects any ACL")
c._acl_state = lambda _fd: (None, None)
wrong_owner = types.SimpleNamespace(st_mode=stat.S_IFDIR | 0o750, st_uid=124, st_gid=456)
wrong_group = types.SimpleNamespace(st_mode=stat.S_IFDIR | 0o750, st_uid=123, st_gid=457)
wrong_mode = types.SimpleNamespace(st_mode=stat.S_IFDIR | 0o770, st_uid=123, st_gid=456)
ok(not c._store_rule(123, 456, 0o750, True)(fd, wrong_owner, False), "store owner exact")
ok(not c._store_rule(123, 456, 0o750, True)(fd, wrong_group, False), "store group exact")
ok(not c._store_rule(123, 456, 0o750, True)(fd, wrong_mode, False), "store mode exact")
c._acl_state, c.sys.platform = real_acl, real_platform; os.close(fd)

source = base / "source"; install = base / "install"; anchor_path = base / "anchor"
for role, relative in c.INSTALLED_SOURCES.items():
    target = source / relative; target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / relative, target)
env_id, target_id, verifier_raw = "env.fixture", "repo.fixture", b"verifier.fixture"
registry = document("shadow_environment_registry", "shadow.environments.v1", {
    "activation_state": "inactive", "registry_version": "v1", "environments": [{
        "description": "fixture", "environment_id": env_id, "evidence_scope": "fixtures-only",
        "proof_state": "unproven", "source_root_commit": "1" * 40,
        "target_repository_id": target_id}]})
identity = {name: [sha(verifier_raw)] for name in c.IDENTITY_SLOTS}
identity["verifier"] = sorted([sha(verifier_raw), sha(b"second accepted verifier")])
accepted = document("sandbox_accepted_identity_set", "sandbox.accepted-identities.v1", {
    "activation_state": "inactive", "set_version": "v1", "environments": [{
        "environment_id": env_id, "identities": identity,
        "mechanisms": {name: ["mechanism." + name] for name in c.MECHANISMS},
        "scratch_bytes": 16777216}]})
write(source / c.INSTALLED_SOURCES["registry"], registry)
write(source / c.INSTALLED_SOURCES["accepted_set"], accepted)
installed = {}
for role, relative in c.INSTALLED_SOURCES.items():
    installed[role] = str(install / role); write(pathlib.Path(installed[role]), (source / relative).read_bytes())
identity_paths = {}
for name in c.IDENTITY_KEYS - {"dyld_cache_files"}:
    identity_paths[name] = str(install / ("identity-" + name)); write(pathlib.Path(identity_paths[name]),
        verifier_raw if name == "verifier" else name.encode())
cache = install / "cache"; write(cache, b"cache"); identity_paths["dyld_cache_files"] = [str(cache)]
store = base / "store"; store.mkdir(mode=0o750); store.chmod(0o750)
config_body = {"consumer_gid": os.getgid(), "environment_id": env_id,
    "identity_paths": identity_paths, "installed_files": installed, "principal_uid": 54321,
    "runtime": {"driver": identity_paths["host_runtime"], "vfkit": identity_paths["vm_service"]},
    "store_id": "store.fixture", "store_root": str(store), "work_root": str(base / "work")}
config = document("sandbox_host_config", "host.fixture", config_body)
write(anchor_path / "host-config.json", config); write(anchor_path / "host-supervisor.py", b"supervisor")

real_metadata, real_named, real_source, real_acl = c._metadata, c._named_metadata, c._source_root, c._acl_state
store_nodes = set()
def remember_store():
    store_nodes.clear()
    for path, dirs, files in os.walk(store):
        for name in [path, *[os.path.join(path, item) for item in dirs + files]]:
            value = os.lstat(name); store_nodes.add((value.st_dev, value.st_ino))
def observed_value(value):
    owned = (value.st_dev, value.st_ino) in store_nodes
    mode = value.st_mode if owned else stat.S_IFMT(value.st_mode) | (0o555 if stat.S_ISDIR(value.st_mode) else 0o444)
    return types.SimpleNamespace(st_dev=value.st_dev, st_ino=value.st_ino, st_mode=mode,
        st_uid=54321 if owned else 0, st_gid=os.getgid(), st_nlink=value.st_nlink,
        st_size=value.st_size, st_mtime_ns=value.st_mtime_ns, st_ctime_ns=value.st_ctime_ns)
def observed(fd): return observed_value(real_metadata(fd))
def observed_named(name, parent_fd): return observed_value(real_named(name, parent_fd))
c._metadata, c._named_metadata = observed, observed_named; c._source_root = lambda: str(source)
c._acl_state = lambda _fd: ([], None) if c.sys.platform == "darwin" else (None, None)
c.ANCHOR = str(anchor_path); c.sys.executable = identity_paths["toolchain"]
helper_source = source / c.HELPER_SOURCE
helper_source.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / c.HELPER_SOURCE, helper_source)
c.verify_helper_source()
source_bytes = helper_source.read_bytes()
write(helper_source, source_bytes + b"\n")
refuses("E_DEPENDENCY", c.verify_helper_source)
write(helper_source, source_bytes)
remember_store(); anchor = c.load_anchor()
observation = json.loads(c.verifier_observation(anchor, env_id, target_id))
ok(set(observation) == {"schema_version", "kind", "id", "body"}
   and observation["schema_version"] == 1
   and observation["kind"] == "sandbox_verifier_observation"
   and observation["id"] == "sandbox.observation.verifier", "closed verifier observation envelope")
ok(set(observation["body"]) == {"environment_id", "environment_entry_sha256",
   "target_repository_id", "accepted_set_sha256", "verifier_sha256"},
   "closed verifier observation body")
ok(observation["body"]["verifier_sha256"] == sha(verifier_raw), "verifier bound to reviewed sets")
ok(observation["body"]["accepted_set_sha256"] == sha(accepted), "accepted-set bytes bound")
ok(observation["body"]["environment_entry_sha256"] == sha(c.canonical(json.loads(registry)["body"]["environments"][0])),
   "selected registry entry digest bound")
refuses("E_RELATION", lambda: c.verifier_observation(anchor, env_id, "repo.other"))
anchor.close()

for role in sorted(c.INSTALLED_SOURCES):
    path = pathlib.Path(installed[role]); original = path.read_bytes(); path.chmod(0o640); path.write_bytes(original + b"x")
    refuses("E_INSTALL", c.load_anchor); path.write_bytes(original); path.chmod(0o440)
ok(True, "every installed role is byte-bound")

# A changed reviewed snapshot does not bless independently unchanged installed bytes.
policy_source = source / c.INSTALLED_SOURCES["control_policy"]
policy_original = policy_source.read_bytes()
write(policy_source, policy_original + b"x")
refuses("E_INSTALL", c.load_anchor)
write(policy_source, policy_original)

# Missing and ambiguous registry/accepted relationships fail closed after exact byte binding.
duplicate_registry = json.loads(registry)
duplicate_registry["body"]["environments"].append(
    dict(duplicate_registry["body"]["environments"][0]))
duplicate_registry_raw = c.canonical(duplicate_registry)
write(source / c.INSTALLED_SOURCES["registry"], duplicate_registry_raw)
write(pathlib.Path(installed["registry"]), duplicate_registry_raw)
ambiguous = c.load_anchor()
refuses("E_RELATION", lambda: c.verifier_observation(ambiguous, env_id, target_id))
ambiguous.close()
write(source / c.INSTALLED_SOURCES["registry"], registry)
write(pathlib.Path(installed["registry"]), registry)

duplicate_accepted = json.loads(accepted)
duplicate_accepted["body"]["environments"].append(
    json.loads(json.dumps(duplicate_accepted["body"]["environments"][0])))
duplicate_accepted_raw = c.canonical(duplicate_accepted)
write(source / c.INSTALLED_SOURCES["accepted_set"], duplicate_accepted_raw)
write(pathlib.Path(installed["accepted_set"]), duplicate_accepted_raw)
ambiguous = c.load_anchor()
refuses("E_RELATION", lambda: c.verifier_observation(ambiguous, env_id, target_id))
ambiguous.close()
write(source / c.INSTALLED_SOURCES["accepted_set"], accepted)
write(pathlib.Path(installed["accepted_set"]), accepted)

malformed_accepted = json.loads(accepted)
malformed_accepted["body"]["environments"][0]["identities"]["verifier"] = ["a" * 64, "a" * 64]
malformed_raw = c.canonical(malformed_accepted)
write(source / c.INSTALLED_SOURCES["accepted_set"], malformed_raw)
write(pathlib.Path(installed["accepted_set"]), malformed_raw)
refuses("E_INSTALL", c.load_anchor)
write(source / c.INSTALLED_SOURCES["accepted_set"], accepted)
write(pathlib.Path(installed["accepted_set"]), accepted)

wrong = json.loads(accepted); wrong["body"]["environments"][0]["identities"]["verifier"] = [sha(b"wrong")]
wrong_raw = c.canonical(wrong)
write(source / c.INSTALLED_SOURCES["accepted_set"], wrong_raw); write(pathlib.Path(installed["accepted_set"]), wrong_raw)
cross = c.load_anchor(); refuses("E_RELATION", lambda: c.verifier_observation(cross, env_id, target_id)); cross.close()
write(source / c.INSTALLED_SOURCES["accepted_set"], accepted); write(pathlib.Path(installed["accepted_set"]), accepted)
empty = json.loads(accepted); empty["body"]["environments"] = []; empty_raw = c.canonical(empty)
write(source / c.INSTALLED_SOURCES["accepted_set"], empty_raw); write(pathlib.Path(installed["accepted_set"]), empty_raw)
empty_anchor = c.load_anchor(); refuses("E_RELATION", lambda: c.verifier_observation(empty_anchor, env_id, target_id)); empty_anchor.close()
write(source / c.INSTALLED_SOURCES["accepted_set"], accepted); write(pathlib.Path(installed["accepted_set"]), accepted)
bad_config = json.loads(config); bad_config["body"]["principal_uid"] = True
refuses("E_CONFIG", lambda: c._parse_config(c.canonical(bad_config)))
bad_config = json.loads(config); bad_config["body"]["store_root"] = "/sandbox/store"
refuses("E_CONFIG", lambda: c._parse_config(c.canonical(bad_config)))
bad_config = json.loads(config); bad_config["body"]["work_root"] = "/sandbox"
refuses("E_CONFIG", lambda: c._parse_config(c.canonical(bad_config)))
bad_config = json.loads(config); bad_config["body"]["consumer_gid"] = False
refuses("E_CONFIG", lambda: c._parse_config(c.canonical(bad_config)))
bad_config = json.loads(config); bad_config["body"]["runtime"]["driver"] = "relative"
refuses("E_CONFIG", lambda: c._parse_config(c.canonical(bad_config)))
bad_config = json.loads(config); bad_config["body"]["identity_paths"]["dyld_cache_files"] = []
refuses("E_CONFIG", lambda: c._parse_config(c.canonical(bad_config)))
bad_config = json.loads(config)
bad_config["body"]["installed_files"]["registry"] = bad_config["body"]["installed_files"]["accepted_set"]
refuses("E_CONFIG", lambda: c._parse_config(c.canonical(bad_config)))
saved = pathlib.Path(installed["registry"]); saved.rename(saved.with_suffix(".missing"))
before = len(os.listdir("/dev/fd")); refuses("E_INSTALL", c.load_anchor)
ok(len(os.listdir("/dev/fd")) == before, "partial anchor failure closes descriptors")
saved.with_suffix(".missing").rename(saved)

old_python = c.sys.executable
c.sys.executable = str(install / "missing-interpreter")
before = len(os.listdir("/dev/fd")); refuses("E_INSTALL", c.load_anchor)
ok(len(os.listdir("/dev/fd")) == before, "late interpreter failure closes descriptors")
c.sys.executable = old_python

before = len(os.listdir("/dev/fd")); anchor = c.load_anchor(); anchor.close()
ok(len(os.listdir("/dev/fd")) == before, "successful anchor ownership closes cleanly")
anchor = c.load_anchor()

def make_attempt(attempt_id="attempt.fixture", evidence_raw=b"proof", name_hex="70726f6f66"):
    attempt = store / attempt_id; payload = attempt / "payload"; payload.mkdir(parents=True, mode=0o750)
    attempt.chmod(0o750); payload.chmod(0o750)
    rows = []
    if evidence_raw is not None:
        rows = [{"name_hex": name_hex, "sha256": sha(evidence_raw), "size_bytes": len(evidence_raw)}]
        (payload / "evidence").mkdir(mode=0o750); (payload / "evidence").chmod(0o750)
        write(payload / "evidence/0000", evidence_raw)
    manifest = document("sandbox_evidence_manifest", "evidence-manifest", {"files": rows})
    for name, raw in (("stdout", b"out"), ("stderr", b"err"), ("evidence-manifest.json", manifest)):
        write(payload / name, raw)
    write(attempt / "receipt.json", document("fixture_receipt", attempt_id, {})); remember_store()
    return attempt, payload
attempt, payload = make_attempt()
snapshots, origin = c.read_store_attempt(anchor, "attempt.fixture")
entries = json.loads(origin)["body"]["entries"]
ok(set(snapshots) == {"receipt.json", "payload/stdout", "payload/stderr",
    "payload/evidence-manifest.json", "payload/evidence/0000"}, "closed store inventory")
ok(sum(row["kind"] == "directory" for row in entries) == 4, "directory provenance retained")
ok(all(row["metadata_before"] == row["metadata_after"] for row in entries),
   "origin metadata stable across snapshots")
ok(c._hex_name("2f") and c._hex_name("00") and c._hex_name("ab" * 255),
   "evidence names retain the exact lowercase frame-name domain")
ok(not c._hex_name("") and not c._hex_name("a")
   and not c._hex_name("AB") and not c._hex_name("ab" * 256),
   "evidence name length and encoding are closed")
write(attempt / "extra", b"x"); remember_store(); refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.fixture")); (attempt / "extra").unlink()
manifest_path = payload / "evidence-manifest.json"; malformed = json.loads(manifest_path.read_bytes())
malformed["body"]["files"][0]["name_hex"] = "not-hex"; write(manifest_path, c.canonical(malformed)); remember_store()
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.fixture"))

# The expected name itself cannot alias another payload object.
shutil.rmtree(attempt)
attempt, payload = make_attempt("attempt.alias", None)
(payload / "stderr").unlink()
os.link(payload / "stdout", payload / "stderr")
remember_store()
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.alias"))

# Manifest errors are independently targeted with internally consistent bytes.
shutil.rmtree(attempt)
attempt, payload = make_attempt("attempt.digest", b"proof")
manifest_path = payload / "evidence-manifest.json"
bad_digest = json.loads(manifest_path.read_bytes())
bad_digest["body"]["files"][0]["sha256"] = "4" * 64
write(manifest_path, c.canonical(bad_digest)); remember_store()
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.digest"))

shutil.rmtree(attempt)
attempt, payload = make_attempt("attempt.size", b"proof")
manifest_path = payload / "evidence-manifest.json"
bad_size = json.loads(manifest_path.read_bytes())
bad_size["body"]["files"][0]["size_bytes"] += 1
write(manifest_path, c.canonical(bad_size)); remember_store()
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.size"))

shutil.rmtree(attempt)
attempt, payload = make_attempt("attempt.uppercase", b"proof", "AA")
remember_store()
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.uppercase"))

shutil.rmtree(attempt)
attempt, payload = make_attempt("attempt.missing", b"proof")
(payload / "evidence/0000").unlink(); remember_store()
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.missing"))

# An inventory race after the first list cannot produce an authenticated observation.
shutil.rmtree(attempt)
attempt, payload = make_attempt("attempt.race", None)
real_listdir, calls = c.os.listdir, [0]
def racing_listdir(fd):
    names = real_listdir(fd)
    calls[0] += 1
    if calls[0] == 2:
        write(attempt / "late-extra", b"x")
        remember_store()
    return names
c.os.listdir = racing_listdir
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.race"))
c.os.listdir = real_listdir

shutil.rmtree(attempt); attempt, payload = make_attempt("attempt.large", b"x" * (5 * 1024 * 1024))
write(payload / "stdout", b"x" * (5 * 1024 * 1024 + 1)); remember_store()
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.large"))
payload.chmod(0o777); remember_store(); refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.large"))

anchor.close(); c._metadata, c._named_metadata = real_metadata, real_named
c._source_root, c._acl_state = real_source, real_acl
print("shadow-enforced: %d checks passed" % checks)
PY
