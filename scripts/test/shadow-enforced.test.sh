#!/bin/bash
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-shadow-consumer.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() { /bin/chmod -R u+w -- "$tmp" 2>/dev/null || true; /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT
sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
case "$(/usr/bin/uname -s):$(/usr/bin/uname -m)" in
  Darwin:*) jq_asset=jq-osx-amd64 ;;
  Linux:x86_64) jq_asset=jq-linux64 ;;
  *) /usr/bin/printf 'unsupported test host\n' >&2; exit 1 ;;
esac
jq_bin="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset"
[ -x "$jq_bin" ] || { /usr/bin/printf 'missing pinned jq\n' >&2; exit 1; }
jq_bin=$(CDPATH='' cd -P -- "${jq_bin%/*}" && /usr/bin/printf '%s/%s' "$PWD" "${jq_bin##*/}")
python_bin=$(command -v python3)
case "$python_bin" in /*) ;; *) /usr/bin/printf 'missing physical python\n' >&2; exit 1 ;; esac
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
external_ancestors = set()
cursor = base.parent
while True:
    external_ancestors.add(str(cursor))
    if cursor == cursor.parent: break
    cursor = cursor.parent
def fd_path(fd):
    if sys.platform == "darwin":
        raw = c.fcntl.fcntl(fd, 50, b"\0" * 1024)
        return raw.split(b"\0", 1)[0].decode()
    return os.path.realpath("/proc/self/fd/" + str(fd))
def stable_external(value, path):
    if path not in external_ancestors or not stat.S_ISDIR(value.st_mode):
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
absent_effect = base / "absent-context-effect"
refuses("E_PARENT_CONTEXT", lambda: c.capture_parent_context(-1))
ok(not absent_effect.exists(), "absent parent context has no later effect")
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

fd = os.open(base, os.O_RDONLY); real_acl, real_platform = c._acl_state, c.sys.platform
root_state = types.SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o555)
installed_state = types.SimpleNamespace(st_uid=123, st_mode=stat.S_IFDIR | 0o555)
acl_calls = [0]
def acl_value(value):
    def observe(_fd): acl_calls[0] += 1; return value
    return observe
c.sys.platform = "linux"
c._acl_state = acl_value(([(0x02, 4, 123)], None))
ok(not c._installed_rule(123)(fd, installed_state, False) and acl_calls[0] == 1,
   "Linux named-user ACL reached and refused")
acl_calls[0] = 0; c._acl_state = acl_value((None, [(0x10, 2, 0)]))
ok(not c._root_rule(fd, root_state, False) and acl_calls[0] == 1,
   "Linux default write ACL reached and refused")

class Call:
    def __init__(self, function): self.function = function
    def __call__(self, *args): return self.function(*args)
class FakeAclLib:
    def __init__(self, failure=None):
        self.failure, self.entries = failure, 0
        self.calls = {"entry": 0, "permission": 0, "qualifier": 0}
        self.guid = c.ctypes.create_string_buffer(16)
        self.acl_get_fd_np = Call(lambda *_args: 1)
        self.acl_get_entry = Call(self.get_entry)
        self.acl_get_tag_type = Call(self.get_tag)
        self.acl_get_qualifier = Call(self.get_qualifier)
        self.acl_get_permset = Call(self.get_permset)
        self.acl_get_perm_np = Call(self.get_perm)
        self.mbr_uuid_to_id = Call(self.resolve)
        self.acl_free = Call(lambda _value: 0)
    def get_entry(self, _acl, _selector, _entry):
        self.calls["entry"] += 1
        if self.failure == "entry": c.ctypes.set_errno(13); return -1
        self.entries += 1
        if self.entries == 1: return 0
        c.ctypes.set_errno(0); return -1
    def get_tag(self, _entry, output): output._obj.value = 1; return 0
    def get_permset(self, _entry, output): output._obj.value = 1; return 0
    def get_perm(self, _perms, bit):
        self.calls["permission"] += 1
        if self.failure == "permission": c.ctypes.set_errno(5); return -1
        return int(bit == 1 << 1)
    def get_qualifier(self, _entry):
        self.calls["qualifier"] += 1
        if self.failure == "qualifier": c.ctypes.set_errno(5); return 0
        return c.ctypes.addressof(self.guid)
    def resolve(self, _uuid, value, kind):
        value._obj.value = 0; kind._obj.value = 0; return 0
real_cdll = c.ctypes.CDLL
c.sys.platform = "darwin"; c._acl_state = real_acl
def darwin_rule(failure, installed=False):
    fake = FakeAclLib(failure)
    c.ctypes.CDLL = lambda *_args, **_kwargs: fake
    rule = c._installed_rule(123) if installed else c._root_rule
    state = installed_state if installed else root_state
    return rule(fd, state, False), fake
for installed in (False, True):
    accepted_acl, fake = darwin_rule(None, installed)
    ok(accepted_acl and fake.entries == 2, "Darwin read-only ACL control reached")
    for failure in ("entry", "permission", "qualifier"):
        accepted_acl, fake = darwin_rule(failure, installed)
        ok(not accepted_acl and fake.calls[failure] > 0, "Darwin %s error reached and refused" % failure)
c.ctypes.CDLL = real_cdll
c._acl_state = acl_value(([(1, 456, 1 << 2)], None)); acl_calls[0] = 0
ok(not c._root_rule(fd, root_state, False) and acl_calls[0] == 1,
   "Darwin other-principal ACL reached and refused")

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
ok(c._id("attempt:valid") and not c._id("Attempt") and not c._id("é"),
   "identifier domain is lowercase ASCII with colon")
registry_bool = json.loads(registry); registry_bool["schema_version"] = True
refuses("E_INSTALL", lambda: c._parse_registry(c.canonical(registry_bool)))
accepted_bool = json.loads(accepted); accepted_bool["schema_version"] = True
refuses("E_INSTALL", lambda: c._parse_accepted(c.canonical(accepted_bool)))
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

aggregate_attempt = store / "attempt.aggregate"
aggregate_payload = aggregate_attempt / "payload"
aggregate_evidence = aggregate_payload / "evidence"
aggregate_evidence.mkdir(parents=True, mode=0o750)
for directory in (aggregate_attempt, aggregate_payload, aggregate_evidence): directory.chmod(0o750)
aggregate_rows, aggregate_nodes = [], set()
for index in range(3):
    raw = bytes([index]) * (4 * 1024 * 1024)
    path = aggregate_evidence / ("%04d" % index); write(path, raw)
    aggregate_rows.append({"name_hex": "%02x" % index, "sha256": sha(raw), "size_bytes": len(raw)})
for name, raw in (("stdout", b""), ("stderr", b""),
                  ("evidence-manifest.json", document("sandbox_evidence_manifest",
                   "evidence-manifest", {"files": aggregate_rows}))):
    write(aggregate_payload / name, raw)
write(aggregate_attempt / "receipt.json", document("fixture_receipt", "attempt.aggregate", {}))
for path in [aggregate_payload / "stdout", aggregate_payload / "stderr",
             *[aggregate_evidence / ("%04d" % index) for index in range(3)]]:
    value = path.stat(); aggregate_nodes.add((value.st_dev, value.st_ino))
remember_store(); real_output_read, aggregate_bytes = c.os.read, [0]
def count_output_read(fd, count):
    raw = real_output_read(fd, count)
    value = os.fstat(fd)
    if (value.st_dev, value.st_ino) in aggregate_nodes: aggregate_bytes[0] += len(raw)
    return raw
c.os.read = count_output_read
try: refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.aggregate"))
finally: c.os.read = real_output_read
ok(aggregate_bytes[0] == 0, "aggregate limit refuses before output allocation")

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
colon_attempt, _colon_payload = make_attempt("attempt:valid", None)
colon_snapshots, _colon_origin = c.read_store_attempt(anchor, "attempt:valid")
ok("receipt.json" in colon_snapshots, "colon attempt id reaches controlled store")
manifest_path = payload / "evidence-manifest.json"
manifest_original = manifest_path.read_bytes(); manifest_bool = json.loads(manifest_original)
manifest_bool["schema_version"] = True; write(manifest_path, c.canonical(manifest_bool)); remember_store()
refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.fixture"))
write(manifest_path, manifest_original); remember_store()
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

# Slice 3 keeps launch substitution private while exercising the production
# framing, durable-request, payload, record, inventory and bounded-child code.
"$python_bin" -I -S -B - "$root" "$tmp/slice3" "$jq_bin" <<'PY'
import hashlib, importlib.util, json, os, pathlib, shutil, signal, stat, subprocess, sys, time, types
root, base, jq_bin = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]); base.mkdir(mode=0o700)
spec = importlib.util.spec_from_file_location("enforced", root / "shadow/v1/enforced-reproduction.py")
e = importlib.util.module_from_spec(spec); sys.modules[spec.name] = e; spec.loader.exec_module(e)
checks = 0
def ok(value, message):
    global checks
    if not value: raise AssertionError(message)
    checks += 1; print("ok slice3-%d - %s" % (checks, message))
def refuses(code, action, message):
    try: action()
    except e.Refusal as exc: ok(exc.code == code, message); return
    raise AssertionError("accepted: " + message)
def doc(kind, identity, body):
    return {"schema_version": 1, "kind": kind, "id": identity, "body": body}
def write(path, raw):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_bytes(raw); path.chmod(0o400)
def sha(raw): return hashlib.sha256(raw).hexdigest()

# The frame proof uses an independent parser. It checks every byte in the
# header/content digest, ordered records and the terminal digest record.
def decode(frame):
    ok(frame[:8] == b"YSFRAME1", "frame magic")
    measured = hashlib.sha256(frame[:8]); at = 8; records = []
    while True:
        n = frame[at]; name = frame[at + 1:at + 1 + n]
        size = int.from_bytes(frame[at + 1 + n:at + 9 + n], "big")
        header = frame[at:at + 9 + n]; at += 9 + n
        content = frame[at:at + size]; at += size
        if name == b"end":
            ok(size == 32 and content == measured.digest() and at == len(frame), "frame terminal digest")
            return records
        measured.update(header); measured.update(content); records.append((name, content))
records = [(b"request.json", b"r\n"), (b"evaluation.json", b"e\n"),
           (b"incident.json", b"i\n"), (b"record.json", b"p\n"),
           (b"manifest.json", b"m\n"), (b"instruction", b"x\n"),
           (b"candidate/00000", b"candidate\n")]
frame = e.frame_write(records)
ok(decode(frame) == records, "frame records preserve order and bytes")
refuses("E_LIMIT", lambda: e.frame_write([(b"x" * 256, b"")]), "oversize frame name refused")
refuses("E_LIMIT", lambda: e.frame_write([(b"end", b"")]), "reserved end name refused")
old_limit = e.FRAME_LIMIT; e.FRAME_LIMIT = 30
refuses("E_LIMIT", lambda: e.frame_write([(b"x", b"a" * 40)]), "complete frame ceiling enforced")
exact=8+1+1+8+7+44;e.FRAME_LIMIT=exact
ok(len(e.frame_write([(b"x",b"a"*7)]))==exact,"frame exact cap accepted")
e.FRAME_LIMIT=exact-1
refuses("E_LIMIT",lambda:e.frame_write([(b"x",b"a"*7)]),"frame cap-minus-one refuses before append")
e.FRAME_LIMIT = old_limit

# Bounded children get a clean explicit environment and process group. A
# timeout is failure; truncated stdout/stderr can never be accepted.
env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"}
out = e.run_bounded([sys.executable, "-I", "-S", "-B", "-c", "print('fixed')"], env=env)
ok(out == b"fixed\n", "bounded child success")
refuses("E_RUNTIME", lambda: e.run_bounded([sys.executable, "-I", "-S", "-B", "-c",
    "import time;time.sleep(2)"], timeout=.05, env=env), "bounded child timeout is failure")
refuses("E_LIMIT", lambda: e.run_bounded([sys.executable, "-I", "-S", "-B", "-c",
    "import sys,time;sys.stdout.write('x'*100);sys.stdout.flush();time.sleep(30)"],
    output_limit=8, env=env), "bounded stdout refuses instead of truncating")
refuses("E_LIMIT", lambda: e.run_bounded([sys.executable, "-I", "-S", "-B", "-c",
    "import sys,time;sys.stderr.write('x'*70000);sys.stderr.flush();time.sleep(30)"], env=env),
    "bounded stderr refuses instead of truncating")
refuses("E_RUNTIME", lambda: e.run_bounded([sys.executable, "-I", "-S", "-B", "-c",
    "raise SystemExit(3)"], env=env), "nonzero component exit refuses")
original_popen=e.subprocess.Popen
e.subprocess.Popen=lambda *_args,**_kwargs: (_ for _ in ()).throw(AssertionError("spawned"))
refuses("E_RUNTIME",lambda:e.run_bounded([sys.executable,"-c","pass"],env=env,
        deadline=time.monotonic()-1),"expired overall deadline refuses before spawn")
e.subprocess.Popen=original_popen
setup_ready=base/"setup.ready"
setup_child=original_popen([sys.executable,"-c","import pathlib,sys,time;pathlib.Path(sys.argv[1]).touch();time.sleep(30)",str(setup_ready)],stdin=subprocess.PIPE,
 stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
for _ in range(100):
 if setup_ready.exists():break
 time.sleep(.01)
ok(setup_ready.exists(),"setup child reached owned process group")
original_set_blocking=e.os.set_blocking;e.os.set_blocking=lambda *_args: (_ for _ in ()).throw(OSError("fixture"))
try:e.communicate_bounded(setup_child,b"",8,8,1)
except OSError:ok(True,"setup failure leaves bounded operation")
else:raise AssertionError("setup failure accepted")
e.os.set_blocking=original_set_blocking
for _ in range(100):
 if setup_child.poll() is not None:break
 time.sleep(.01)
ok(setup_child.poll() is not None,"setup-failed child was reaped")
interrupt_ready=base/"interrupt.ready"
interrupt_child=original_popen([sys.executable,"-c","import pathlib,sys,time;pathlib.Path(sys.argv[1]).touch();time.sleep(30)",str(interrupt_ready)],stdin=subprocess.PIPE,
 stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
for _ in range(100):
 if interrupt_ready.exists():break
 time.sleep(.01)
ok(interrupt_ready.exists(),"interrupt child reached owned process group")
original_selector=e.selectors.DefaultSelector
e.selectors.DefaultSelector=lambda: (_ for _ in ()).throw(KeyboardInterrupt())
try:e.communicate_bounded(interrupt_child,b"",8,8,1)
except KeyboardInterrupt:ok(True,"cancellation leaves bounded operation")
else:raise AssertionError("cancellation accepted")
finally:e.selectors.DefaultSelector=original_selector
for _ in range(100):
 if interrupt_child.poll() is not None:break
 time.sleep(.01)
ok(interrupt_child.poll() is not None,"cancelled child was reaped")
signal_wrapper=base/"signal-wrapper.py"
signal_wrapper.write_text('''import importlib.util,pathlib,signal,sys\nroot=pathlib.Path(sys.argv[1]);pid=pathlib.Path(sys.argv[2]);done=pathlib.Path(sys.argv[3])\ns=importlib.util.spec_from_file_location("signaled",root/"shadow/v1/enforced-reproduction.py")\ne=importlib.util.module_from_spec(s);sys.modules[s.name]=e;s.loader.exec_module(e)\nbefore={x:signal.getsignal(x) for x in (signal.SIGTERM,signal.SIGHUP)}\ndef reproduce(*_args):\n e.run_bounded([sys.executable,"-I","-S","-B","-c","import os,pathlib,sys,time;pathlib.Path(sys.argv[1]).write_text(str(os.getpid()));time.sleep(30)",str(pid)],env={"PATH":"/usr/bin:/bin","LC_ALL":"C","LANG":"C"})\ne.reproduce=reproduce\nrc=e.main(["driver","reproduce","request","work","output"])\ndone.write_text(str(rc)+":"+str(all(signal.getsignal(x)==before[x] for x in before)))\n''')
for sent in (signal.SIGTERM,signal.SIGHUP):
 child_pid=base/(sent.name+".pid");done=base/(sent.name+".done")
 wrapper=subprocess.Popen([sys.executable,"-I","-S","-B",str(signal_wrapper),str(root),
  str(child_pid),str(done)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 for _ in range(500):
  if child_pid.exists():break
  if wrapper.poll() is not None:break
  time.sleep(.01)
 ok(child_pid.exists(),sent.name+" production consumer reached owned child")
 owned=int(child_pid.read_text());wrapper.send_signal(sent);stdout,stderr=wrapper.communicate(timeout=15)
 ok(wrapper.returncode==0 and done.read_text()=="1:True" and stderr==b"E_RUNTIME\n",
    sent.name+" is routed through consumer cleanup and handlers are restored")
 gone=False
 for _ in range(500):
  try:os.killpg(owned,0)
  except ProcessLookupError:gone=True;break
  except PermissionError:pass
  time.sleep(.01)
 ok(gone,sent.name+" leaves no owned process group")
pid_file=base/"descendant.pid"
group_program=("import os,pathlib,signal,sys,time;pid=os.fork();"
 "(signal.signal(signal.SIGTERM,signal.SIG_IGN),time.sleep(30)) if pid==0 else "
 "(pathlib.Path(sys.argv[1]).write_text(str(pid)),time.sleep(30))")
started=time.monotonic()
refuses("E_RUNTIME",lambda:e.run_bounded([sys.executable,"-c",group_program,str(pid_file)],
        timeout=.1,env=env),"timeout stops leader and TERM-ignoring descendant")
descendant=int(pid_file.read_text());gone=False
for _ in range(100):
 try:os.kill(descendant,0)
 except ProcessLookupError:gone=True;break
 time.sleep(.01)
ok(gone and time.monotonic()-started<11,"owned process group is gone within one cleanup bound")
bash=e.fixed_bash();bash.recheck();ok(True,"fixed /bin/bash alias and physical bytes recheck")
original_lstat=e.os.lstat
def linux_alias(path):
 state=original_lstat(path)
 if pathlib.Path(path)==pathlib.Path("/bin"):
  return types.SimpleNamespace(st_dev=state.st_dev,st_ino=state.st_ino,
   st_mode=stat.S_IFLNK|0o777,st_uid=0,st_gid=state.st_gid,st_nlink=state.st_nlink,
   st_size=state.st_size,st_mtime_ns=state.st_mtime_ns,st_ctime_ns=state.st_ctime_ns)
 return state
original_readlink=e.os.readlink
physical_bash=pathlib.Path("/bin/bash").resolve();original_resolve=e.Path.resolve
e.os.lstat=linux_alias;e.os.readlink=lambda path:"usr/bin" if pathlib.Path(path)==pathlib.Path("/bin") else original_readlink(path)
e.Path.resolve=lambda self,strict=False:physical_bash if self==pathlib.Path("/bin/bash") else original_resolve(self,strict=strict)
linux_bash=e.fixed_bash();linux_bash.recheck();linux_bash.close()
ok(True,"root-owned Linux-mode bash alias is admitted with physical byte binding")
e.os.lstat=original_lstat;e.os.readlink=original_readlink;e.Path.resolve=original_resolve
def replaced_alias(path):
 state=original_lstat(path)
 if pathlib.Path(path)==pathlib.Path("/bin"):
  return types.SimpleNamespace(st_dev=state.st_dev,st_ino=state.st_ino+1,st_mode=state.st_mode,
   st_uid=state.st_uid,st_gid=state.st_gid,st_nlink=state.st_nlink,st_size=state.st_size,
   st_mtime_ns=state.st_mtime_ns,st_ctime_ns=state.st_ctime_ns)
 return state
e.os.lstat=replaced_alias
refuses("E_DEPENDENCY",bash.recheck,"fixed executable alias replacement refuses")
e.os.lstat=original_lstat
original_read=bash.physical.held.read;bash.physical.held.read=lambda _limit,_code:b"changed"
refuses("E_DEPENDENCY",bash.recheck,"same held executable with changed bytes refuses")
bash.physical.held.read=original_read;bash.close()
fifo = base / "request-fifo"; os.mkfifo(fifo)
refuses("E_SHAPE", lambda: e.read_regular(fifo, e.REQUEST_LIMIT, "E_SHAPE"),
        "request FIFO refuses without blocking")

incident = doc("shadow_incident_record", "incident.fixture", {
    "deploy_authority": "none", "failing_check": {"check_id": "check.fixture",
    "kind": "file-digest", "path": "source.txt", "expected_sha256": "a" * 64},
    "git_revision_ref": {"repository_id": "fixture.target", "hash_algorithm": "sha1",
                         "commit_id": "b" * 40}, "observed_at": "2026-01-01T00:00:00Z",
    "observed_symptom": "changed", "reporter_actor_ref": "actor.fixture",
    "target_repository_id": "fixture.target"})
instruction = e.make_instruction(incident)
ok(instruction == (b"ystack.file-digest-instruction.v1\npath source.txt\nsha256 " + b"a" * 64 + b"\n"),
   "fixed instruction exact bytes")
for patch, message in [({"kind":"named-check"}, "named check refused"),
                       ({"path":"bad\npath"}, "newline path refused"),
                       ({"expected_sha256":"A" * 64}, "non-lowercase digest refused")]:
    changed = json.loads(json.dumps(incident)); changed["body"]["failing_check"].update(patch)
    refuses("E_RELATION", lambda changed=changed: e.make_instruction(changed), message)

# Launch and expectation are derived from one tuple. The only varying field is
# a fresh nonce. The expectation hashes the completed request and carries no
# caller-supplied replacement for store, control or subject.
policy = b'{"p":1}\n'; decision = b'{"d":1}\n'; pset = b'{"s":1}\n'
driver = b'#!/bin/bash\n'; program = b'.\n'; accepted = b'{"a":1}\n'; registry_raw = b'{"r":1}\n'
entry = {"description":"fixture","environment_id":"env.fixture","evidence_scope":"fixtures-only",
         "proof_state":"unproven","source_root_commit":"b"*40,"target_repository_id":"fixture.target"}
installed = {"control_policy":(policy,sha(policy)), "control_decision":(decision,sha(decision)),
 "control_policy_set":(pset,sha(pset)), "evaluator_driver":(driver,sha(driver)),
 "evaluator_program":(program,sha(program)), "accepted_set":(accepted,sha(accepted)),
 "registry":(registry_raw,sha(registry_raw))}
anchor = types.SimpleNamespace(config={"environment_id":"env.fixture","store_id":"store.fixture"},
                               registry=(sha(registry_raw),[entry]), installed=installed)
request = doc("shadow_enforced_request", "attempt.fixture", {"attempt_id":"attempt.fixture"})
record = {"source":{"repository_id":"fixture.target","hash_algorithm":"sha1",
 "commit_id":"b"*40,"tree_id":"c"*40}, "candidate":{"commit_id":"d"*40,"tree_id":"e"*40}}
record_raw=e.canonical(record); manifest_raw=e.canonical({"entries":[]}); evaluation_raw=e.canonical(doc(
 "sandbox_policy_evaluation","evaluation.fixture",{"verdict":"satisfied"}))
observation_raw=e.canonical(doc("sandbox_verifier_observation","observation.fixture",{}))
launch1, expectation1 = e.make_launch(anchor, request, e.canonical(incident), evaluation_raw,
                                      observation_raw, record_raw, manifest_raw, instruction)
launch2, expectation2 = e.make_launch(anchor, request, e.canonical(incident), evaluation_raw,
                                      observation_raw, record_raw, manifest_raw, instruction)
l1,l2=e.parse(launch1),e.parse(launch2); x1,x2=e.parse(expectation1),e.parse(expectation2)
ok(l1["body"]["nonce"] != l2["body"]["nonce"], "launch nonce is fresh")
ok(x1["body"]["attempt"]["launch_request_sha256"] == sha(launch1), "expectation binds completed launch")
ok(x2["body"]["attempt"]["launch_request_sha256"] == sha(launch2), "second expectation binds second launch")
for key in ("control","store_id","subject"):
    ok(x1["body"][key] == l1["body"][key], "expectation copies launch " + key)
ok(set(l1["body"]["control"]) == {"policy_sha256","decision_sha256","policy_set_sha256",
   "evaluator_driver_sha256","evaluator_program_sha256","sandbox_evaluation_sha256"},
   "launch carries all six control bindings")
ok(l1["body"]["subject"]["environment_entry_sha256"] == sha(e.canonical(entry)),
   "launch hashes selected registry entry")

# Persist request and expectation with fsync before a substituted launch is
# entered. This directly exercises the production exclusive writer.
order=[]; real_write=e.write_exclusive; real_fsync=os.fsync
def ordered_write(path, raw, mode=0o400, sync=False):
    real_write(path,raw,mode,sync); order.append((path.name,sync))
def ordered_launch(_anchor,_frame,_deadline):
    ok(order == [("sandbox-request.json",True),("sandbox-expectation.json",True)],
       "request and expectation durable before launch seam")
    return 0
e.write_exclusive=ordered_write
pre=base/"prelaunch"; pre.mkdir(mode=0o700)
e.write_exclusive(pre/"sandbox-request.json", launch1, sync=True)
e.write_exclusive(pre/"sandbox-expectation.json", expectation1, sync=True)
ordered_launch(anchor,frame,time.monotonic()+1)
e.write_exclusive=real_write
refuses("E_RUNTIME", lambda: real_write(pre/"sandbox-request.json",launch1),
        "exclusive persistence refuses overwrite")

# Every caller document is copied through a held no-follow descriptor. The
# original and private copy are both checked again before a completion marker.
input_source=base/"captured-source.json"; write(input_source,e.canonical(doc("fixture","fixture.capture",{})))
captured_dir=base/"captured"; captured_dir.mkdir(mode=0o700)
snapshot=e.snapshot_input(input_source,captured_dir/"incident.json",1024)
ok(snapshot.raw==(captured_dir/"incident.json").read_bytes(),"input snapshot preserves exact bytes")
snapshot.recheck(); ok(True,"unchanged input snapshot rechecks")
(captured_dir/"incident.json").chmod(0o600); (captured_dir/"incident.json").write_bytes(b"{}\n")
refuses("E_RELATION",snapshot.recheck,"private snapshot mutation refused")
snapshot.close()
e.disjoint([base/"a",base/"b"]); ok(True,"sibling workspaces are disjoint")
refuses("E_WORKSPACE",lambda:e.disjoint([base/"a",base/"a/b"]),"nested workspace refused")

# Payload admission compares the real manifest row, fixed filename, observed
# bytes and fixed instruction. All relation mutations are otherwise complete.
result_body={"check":{"path":"source.txt","expected_sha256":"a"*64},
             "instruction_sha256":sha(instruction),
             "observed":{"sha256":"f"*64,"size_bytes":7},
             "outcome":"mismatch","reason_id":"file.mismatch"}
result_raw=e.canonical(doc("file_digest_verifier_payload","file-digest-payload",result_body))
evidence_manifest=doc("sandbox_evidence_manifest","evidence-manifest",{"files":[{
    "name_hex":b"file-digest-result.json".hex(),"sha256":sha(result_raw),"size_bytes":len(result_raw)}]})
prep_manifest={"entries":[{"path":"source.txt","sha256":"f"*64,"size_bytes":7}]}
snapshots={"payload/stdout":b"","payload/stderr":b"","payload/evidence/0000":result_raw}
payload_receipt={"body":{"lifecycle":{"admission":"admitted","runtime":"completed","control_deadline":"met"},
 "teardown":{"state":"confirmed"},"payload":{"exit_state":"exited","exit_code":0,
 "stdout_sha256":sha(b""),"stderr_sha256":sha(b""),
 "evidence_manifest_sha256":sha(e.canonical(evidence_manifest))}}}
raw, result=e.payload_result(snapshots,evidence_manifest,instruction,prep_manifest,payload_receipt)
ok(raw==result_raw and result["outcome"]=="mismatch", "mismatch is completed comparison")
for target,key in (("result","schema_version"),("observed","size_bytes")):
 bad=e.parse(result_raw)
 if target=="result":bad[key]=True
 else:bad["body"]["observed"][key]=True
 bad_raw=e.canonical(bad);ss=dict(snapshots);ss["payload/evidence/0000"]=bad_raw
 mm=json.loads(json.dumps(evidence_manifest));mm["body"]["files"][0].update(sha256=sha(bad_raw),size_bytes=len(bad_raw))
 receipt=json.loads(json.dumps(payload_receipt));receipt["body"]["payload"]["evidence_manifest_sha256"]=sha(e.canonical(mm))
 refuses("E_RELATION",lambda ss=ss,mm=mm,receipt=receipt:e.payload_result(ss,mm,instruction,prep_manifest,receipt),
         "boolean payload "+key+" refused")
for mutate,message in [
 (lambda s,m: s.__setitem__("payload/stdout",b"noise"),"nonempty stdout refused"),
 (lambda s,m: m["body"]["files"][0].__setitem__("name_hex",b"other".hex()),"wrong evidence name refused"),
 (lambda s,m: m["body"]["files"][0].__setitem__("sha256","0"*64),"wrong evidence digest refused")]:
    ss=dict(snapshots); mm=json.loads(json.dumps(evidence_manifest)); mutate(ss,mm)
    refuses("E_RELATION",lambda ss=ss,mm=mm:e.payload_result(ss,mm,instruction,prep_manifest,payload_receipt),message)
changed=e.parse(result_raw); changed["body"]["observed"]["sha256"]="1"*64
changed_raw=e.canonical(changed); ss=dict(snapshots); ss["payload/evidence/0000"]=changed_raw
mm=json.loads(json.dumps(evidence_manifest)); mm["body"]["files"][0].update(
    sha256=sha(changed_raw),size_bytes=len(changed_raw))
changed_receipt=json.loads(json.dumps(payload_receipt))
changed_receipt["body"]["payload"]["evidence_manifest_sha256"]=sha(e.canonical(mm))
refuses("E_RELATION",lambda:e.payload_result(ss,mm,instruction,prep_manifest,changed_receipt),
        "rehashed wrong observed digest refused")
for field,value,message in (("exit_code",1,"nonzero verifier exit refused"),
                            ("exit_state","signaled","signaled verifier refused")):
    bad=json.loads(json.dumps(payload_receipt));bad["body"]["payload"][field]=value
    refuses("E_RELATION",lambda bad=bad:e.payload_result(snapshots,evidence_manifest,instruction,prep_manifest,bad),message)
bad=json.loads(json.dumps(payload_receipt));bad["body"]["teardown"]["state"]="unconfirmed"
refuses("E_RELATION",lambda:e.payload_result(snapshots,evidence_manifest,instruction,prep_manifest,bad),
        "unconfirmed teardown refused")
bad=json.loads(json.dumps(payload_receipt));bad["body"]["lifecycle"]["control_deadline"]="exceeded"
refuses("E_RELATION",lambda:e.payload_result(snapshots,evidence_manifest,instruction,prep_manifest,bad),
        "expired supervisor deadline refused")

# Completion is an exact 29-file inventory with the marker created last. A
# partial write and an unexpected file cannot masquerade as completion.
files={name:(b"" if name.endswith(".txt") else e.canonical(doc("fixture", "fixture."+str(i), {})))
       for i,name in enumerate(e.EVIDENCE_NAMES)}
files["incident.json"]=e.canonical(incident)
out=base/"bundle"; out.mkdir(mode=0o700)
out_hold=e.stable_directory(out)
sync_order=[];order_fsync=e.os.fsync;order_write=e.write_exclusive_at
def tracked_fsync(fd):
 sync_order.append("file" if stat.S_ISREG(os.fstat(fd).st_mode) else "directory");return order_fsync(fd)
def tracked_write(fd,name,raw,mode=0o400,sync=False,**options):
 sync_order.append("write:"+name);return order_write(fd,name,raw,mode,sync,**options)
e.os.fsync=tracked_fsync;e.write_exclusive_at=tracked_write
bundle=e.seal(out,out_hold,files,incident,"enforced-reproduction.v1")
e.os.fsync=order_fsync;e.write_exclusive_at=order_write;out_hold.close()
bundle_doc=e.parse(bundle)
ok([row["name"] for row in bundle_doc["body"]["files"]] == sorted(e.EVIDENCE_NAMES),
   "bundle rows are sorted exact 29-file inventory")
ok(len(bundle_doc["body"]["files"])==29 and set(p.name for p in out.iterdir())==set(e.EVIDENCE_NAMES)|{"bundle.json"},
   "bundle marker closes exact inventory")
ok(all((out/row["name"]).stat().st_size==row["size_bytes"] and
       sha((out/row["name"]).read_bytes())==row["sha256"] for row in bundle_doc["body"]["files"]),
   "bundle sizes and digests bind actual bytes")
ok(len([item for item in out.iterdir() if item.name!="bundle.json"])==29,
   "all evidence bytes precede the completion marker")
ok(sync_order==sum((["write:"+name,"file"] for name in sorted(e.EVIDENCE_NAMES)),[])+
   ["directory","write:bundle.json","file","directory"],
   "each evidence file is durable before directory and last-marker durability")
partial=base/"partial"; partial.mkdir(mode=0o700); write(partial/"incident.json",e.canonical(incident))
ok(not (partial/"bundle.json").exists(),"partial attempt has no completion marker")
extra=base/"extra"; extra.mkdir(mode=0o700); write(extra/"extra",b"x")
extra_hold=e.stable_directory(extra)
refuses("E_RELATION",lambda:e.seal(extra,extra_hold,files,incident,"enforced-reproduction.v1"),
        "preexisting output cannot acquire marker")
ok(not (extra/"bundle.json").exists(),"late inventory refusal leaves no marker");extra_hold.close()
filefail=base/"file-fsync";filefail.mkdir(mode=0o700);filefail_hold=e.stable_directory(filefail)
real_fsync=e.os.fsync;fsync_calls=[0]
def fail_file_fsync(fd):
 if stat.S_ISREG(os.fstat(fd).st_mode):raise OSError("fixture file fsync")
 return real_fsync(fd)
e.os.fsync=fail_file_fsync
try:refuses("E_RUNTIME",lambda:e.seal(filefail,filefail_hold,files,incident,"enforced-reproduction.v1"),
            "evidence file fsync failure refuses before marker")
finally:e.os.fsync=real_fsync
ok(not (filefail/"bundle.json").exists(),"evidence fsync failure leaves no marker");filefail_hold.close()
markerfail=base/"marker-fsync";markerfail.mkdir(mode=0o700);markerfail_hold=e.stable_directory(markerfail)
fsync_calls=[0]
def fail_marker_fsync(fd):
 fsync_calls[0]+=1
 if fsync_calls[0]==31:raise OSError("fixture marker fsync")
 return real_fsync(fd)
e.os.fsync=fail_marker_fsync
try:refuses("E_RUNTIME",lambda:e.seal(markerfail,markerfail_hold,files,incident,"enforced-reproduction.v1"),
            "marker fsync failure refuses")
finally:e.os.fsync=real_fsync
ok(not (markerfail/"bundle.json").exists(),"partial marker is removed through held output")
markerfail_hold.close()
short=base/"short-marker";short.mkdir(mode=0o700);short_fd=os.open(short,os.O_RDONLY|os.O_DIRECTORY)
real_os_write=e.os.write;e.os.write=lambda _fd,_raw:0
try:refuses("E_RUNTIME",lambda:e.write_exclusive_at(short_fd,"bundle.json",b"partial",
        remove_on_failure=True),"short marker write refuses")
finally:e.os.write=real_os_write
os.close(short_fd);ok(not (short/"bundle.json").exists(),"non-OSError marker failure removes owned partial")
preexisting=base/"preexisting-marker";preexisting.mkdir(mode=0o700);write(preexisting/"bundle.json",b"owned")
pre_fd=os.open(preexisting,os.O_RDONLY|os.O_DIRECTORY)
refuses("E_RUNTIME",lambda:e.write_exclusive_at(pre_fd,"bundle.json",b"new",sync=True,
        remove_on_failure=True),"preexisting marker refuses exclusive creation")
os.close(pre_fd);ok((preexisting/"bundle.json").read_bytes()==b"owned","preexisting marker is not removed")
late=base/"late-fsync";late.mkdir(mode=0o700);late_hold=e.stable_directory(late)
fsync_calls=[0]
def fail_final_fsync(fd):
 fsync_calls[0]+=1
 if fsync_calls[0]==32:raise OSError("fixture directory fsync")
 return real_fsync(fd)
e.os.fsync=fail_final_fsync
try:refuses("E_RUNTIME",lambda:e.seal(late,late_hold,files,incident,"enforced-reproduction.v1"),
            "final directory fsync refuses")
finally:e.os.fsync=real_fsync
ok(not (late/"bundle.json").exists(),"directory fsync failure removes marker");late_hold.close()
renamed=base/"renamed";renamed.mkdir(mode=0o700);renamed_hold=e.stable_directory(renamed)
real_write_at=e.write_exclusive_at
def rename_after_marker(fd,name,raw,mode=0o400,sync=False,**options):
 real_write_at(fd,name,raw,mode,sync,**options)
 if name=="bundle.json":renamed.rename(renamed.with_name("renamed-held"));renamed.mkdir(mode=0o700)
e.write_exclusive_at=rename_after_marker
try:refuses("E_RELATION",lambda:e.seal(renamed,renamed_hold,files,incident,"enforced-reproduction.v1"),
            "output replacement after marker write refuses")
finally:e.write_exclusive_at=real_write_at
ok(not (renamed.with_name("renamed-held")/"bundle.json").exists() and
   not (renamed/"bundle.json").exists(),"failed marker cleanup stays bound to held output")
renamed_hold.close()
cancelmark=base/"cancel-marker";cancelmark.mkdir(mode=0o700);cancelmark_hold=e.stable_directory(cancelmark)
def cancel_after_marker(fd,name,raw,mode=0o400,sync=False,**options):
 real_write_at(fd,name,raw,mode,sync,**options)
 if name=="bundle.json":os.kill(os.getpid(),signal.SIGTERM)
e.write_exclusive_at=cancel_after_marker
try:
 with e.CancellationSignals():
  try:e.seal(cancelmark,cancelmark_hold,files,incident,"enforced-reproduction.v1")
  except e.Cancelled:ok(True,"signal after marker creation enters owned cleanup")
  else:raise AssertionError("marker cancellation accepted")
finally:e.write_exclusive_at=real_write_at
ok(not (cancelmark/"bundle.json").exists(),"cancelled marker is removed through held output")
cancelmark_hold.close()

evaluation_fixture=e.canonical(doc("sandbox_policy_evaluation","evaluation.fixture",{}))
checker_fixture=e.canonical(doc("sandbox_receipt_check","check.fixture",{}))
trace=e.trace_ledger(incident,"attempt.fixture","env.fixture","reproduced","tool.verifier",
                     evaluation_fixture,checker_fixture)
t=e.parse(trace)
ok(all(row["record_digest"]==sha(e.canonical({k:v for k,v in row.items() if k!="record_digest"}))
       for row in t["body"]["events"]),"trace event digests exclude their own field")
ok(t["body"]["seal"]["final_digest"]==t["body"]["events"][-1]["record_digest"],
   "trace seal binds final event")
trace_path=base/"trace.json"; write(trace_path,trace)
trace_bin=base/"trace-bin"; trace_bin.mkdir(mode=0o700); shutil.copy2(jq_bin,trace_bin/"jq"); (trace_bin/"jq").chmod(0o500)
trace_env={"PATH":str(trace_bin)+":/usr/bin:/bin","LC_ALL":"C","LANG":"C","TMPDIR":str(base)}
trace_receipt=e.run_bounded(["/bin/bash","-p",str(root/"telemetry/v1/validate-trace-ledger.sh"),
    "validate",incident["id"],"attempt.fixture",str(trace_path)],env=trace_env)
ok(e.parse(trace_receipt)["body"]["ledger_ref"]["sha256"]==sha(trace),
   "real trace validator binds ledger")
trace_none=e.trace_ledger(incident,"attempt.none","env.fixture","inconclusive",None,
                          evaluation_fixture,checker_fixture)
ok(e.parse(trace_none)["body"]["events"][1]["facts"]["tool"]=={"state":"not-applicable"},
   "unexecuted tool is not named")

print("shadow-enforced-slice3: %d checks passed" % checks)
PY


# Exercise the production orchestration with only host identity, child process,
# and native launch boundaries substituted. The component-specific suites run
# each unchanged child interface; this case proves their byte flow and ordering.
"$python_bin" -I -S -B - "$root" "$tmp/slice3-orchestration" <<'PY'
import hashlib, importlib.util, json, os, pathlib, sys, types
root, base = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]); base.mkdir(mode=0o700)
spec=importlib.util.spec_from_file_location("enforced_flow",root/"shadow/v1/enforced-reproduction.py")
e=importlib.util.module_from_spec(spec);sys.modules[spec.name]=e;spec.loader.exec_module(e)
e.sys.executable=str(pathlib.Path(sys.executable).resolve())
def sha(raw): return hashlib.sha256(raw).hexdigest()
def doc(kind,identity,body): return {"schema_version":1,"kind":kind,"id":identity,"body":body}
def write(path,raw,mode=0o400): path.write_bytes(raw);path.chmod(mode)
checks=0
def ok(value,message):
 global checks
 if not value: raise AssertionError(message)
 checks+=1;print("ok flow-%d - %s"%(checks,message))

source=base/"source.git";source.mkdir(mode=0o700)
work=base/"work";output=base/"output";work.mkdir(mode=0o700);output.mkdir(mode=0o700)
helper=base/"object-closure";jq=base/"jq";write(helper,b"helper",0o500);write(jq,b"jq",0o500)
commit,tree,candidate_commit,candidate_tree="b"*40,"c"*40,"d"*40,"e"*40
expected=sha(b"fixed\n")
incident=doc("shadow_incident_record","incident.flow",{"deploy_authority":"none",
 "failing_check":{"check_id":"check.flow","kind":"file-digest","path":"source.txt","expected_sha256":expected},
 "git_revision_ref":{"repository_id":"fixture.target","hash_algorithm":"sha1","commit_id":commit},
 "observed_at":"2026-01-01T00:00:00Z","observed_symptom":"changed",
 "reporter_actor_ref":"actor.fixture","target_repository_id":"fixture.target"})
revision={"repository_id":"fixture.target","hash_algorithm":"sha1","commit_id":commit}
request_content=doc("stage_request","request.flow",{"target_repository_id":"fixture.target",
 "target_revision":{"state":"present","value":revision},
 "source":{"state":"present","value":{"type":"git-object","value":{"revision":revision}}},
 "environment_ref":{"environment_id":"env.fixture","fingerprint_sha256":"PLACEHOLDER"}})
resolved_content=doc("resolved_profile","profile.flow",{})
input_doc={"stage_request":{"content":request_content,"sha256":sha(e.canonical(request_content))},
 "resolved_profile":{"content":resolved_content,"sha256":sha(e.canonical(resolved_content))},
 "payloads":[{"input_id":"input.producer-patch","data":""}],
 "trust_context":{"verified_payloads":[{"input_id":"input.producer-patch","content":{"data":""}}]}}
instruction=e.make_instruction(incident)
identity=doc("qualified_identity","identity.flow",{"stage_request_ref":{"schema_version":1,"kind":"stage_request",
 "id":"request.flow","sha256":input_doc["stage_request"]["sha256"]},"resolved_profile_ref":{
 "schema_version":1,"kind":"resolved_profile","id":"profile.flow","sha256":input_doc["resolved_profile"]["sha256"]},
 "verification_instructions_ref":{"content_id":"instruction.flow","media_type":"text/plain","sha256":sha(instruction)}})
claim=doc("execution_environment_claim","env.fixture",{})
request_content["body"]["environment_ref"]["fingerprint_sha256"]=sha(e.canonical(claim))
input_doc["stage_request"]={"content":request_content,"sha256":sha(e.canonical(request_content))}
identity["body"]["stage_request_ref"]["sha256"]=input_doc["stage_request"]["sha256"]
duty=doc("duty_separation_evaluation","duty.flow",{})
for name,value in (("incident",incident),("claim",claim),("duty",duty),("identity",identity),("input",input_doc)):
 write(base/(name+".json"),e.canonical(value))
request=doc("shadow_enforced_request","attempt.flow",{"attempt_id":"attempt.flow","attempt_number":1,
 "incident":str(base/"incident.json"),"claim":str(base/"claim.json"),"duty_evaluation":str(base/"duty.json"),
 "materialization_input":str(base/"input.json"),"qualified_identity":str(base/"identity.json"),
 "source_git_dir":str(source),"jq":str(jq),"closure_helper":str(helper)})
write(base/"request.json",e.canonical(request))

policy=b'{"policy":true}\n';decision=b'{"decision":true}\n';pset=b'{"set":true}\n'
driver=b'#!/bin/bash\n';program=b'.\n';accepted=b'{"accepted":true}\n';registry_raw=b'{"registry":true}\n'
fake_anchor=base.parent/"flow-installation/supervisor";fake_anchor.mkdir(parents=True,mode=0o700)
entry={"description":"fixture","environment_id":"env.fixture","evidence_scope":"fixtures-only",
 "proof_state":"unproven","source_root_commit":commit,"target_repository_id":"fixture.target"}
installed={"control_policy":(policy,sha(policy)),"control_decision":(decision,sha(decision)),
 "control_policy_set":(pset,sha(pset)),"evaluator_driver":(driver,sha(driver)),
 "evaluator_program":(program,sha(program)),"accepted_set":(accepted,sha(accepted)),
 "registry":(registry_raw,sha(registry_raw))}
class Anchor:
 config={"environment_id":"env.fixture","store_id":"store.fixture","principal_uid":1234,
  "store_root":str(base/"store"),"work_root":str(base/"host-work"),"installed_files":{},
  "identity_paths":{"dyld_cache_files":[]}}
 registry=(sha(registry_raw),[entry]);installed=installed
 held=[types.SimpleNamespace(path=str(fake_anchor/"host-supervisor.py"),read=lambda maximum,code:b"host\n",
  recheck=lambda code:None)]
 def recheck(self,*_args): events.append("anchor-recheck")
 def close(self): events.append("anchor-close")
e.c.ANCHOR=str(fake_anchor)
class Snap:
 def __init__(self,path,digest_value): self.snapshot=types.SimpleNamespace(path=str(path));self.sha256=digest_value
 def recheck(self): events.append("dependency-recheck")
 def close(self): events.append("dependency-close")
events=[]
e.c.snapshot_dependency=lambda path,digest_value,size,private,name: Snap(helper,digest_value)
e.c.snapshot_jq=lambda path,private: Snap(jq,sha(b"jq"))
e.c.verify_helper_source=lambda: events.append("helper-source")
e.c.probe_dependency=lambda snap,args,expected: events.append("probe:"+args[0])
e.c.load_anchor=lambda: Anchor()
e.c.verifier_observation=lambda anchor,environment,target:e.canonical(doc("sandbox_verifier_observation",
 "observation.flow",{"environment_id":environment,"environment_entry_sha256":sha(e.canonical(entry)),
 "target_repository_id":target,"accepted_set_sha256":sha(accepted),"verifier_sha256":"9"*64}))

record={"schema_version":1,"kind":"candidate_content_preparation","status":"completed",
 "source":{"repository_id":"fixture.target","hash_algorithm":"sha1","commit_id":commit,"tree_id":tree},
 "candidate":{"commit_id":commit,"tree_id":tree}}
manifest={"schema_version":1,"kind":"candidate_content_manifest","entries":[{
 "path":"source.txt","mode":"100644","blob_oid":"f"*40,"size_bytes":6,"sha256":sha(b"fixed\n")}],
 "file_count":1,"directory_count":0,"total_file_bytes":6,"hash_algorithm":"sha256"}
materializer_receipt={
 "source":{"repository_id":"fixture.target","hash_algorithm":"sha1","commit_id":commit,"tree_id":tree},
 "candidate":{"commit_id":commit,"tree_id":tree,"parent_commit_id":commit},
 "changed_paths":{"count":0,"sha256":"0"*64}}
stage=doc("stage_result","result.flow",{"outcome":{"family":"change","value":"no-change"}})
response={"schema_version":1,"kind":"adapter_response","stage_result":stage,"payloads":[{
 "content_id":"receipt.materialize","media_type":"application/json","sha256":sha(e.canonical(materializer_receipt)),
 "data":e.canonical(materializer_receipt).decode()}],"authority":"none","qualification":"unavailable","effects":[]}
evaluation=doc("sandbox_policy_evaluation","evaluation.flow",{
 "verdict":"satisfied","reason_ids":["sandbox.declaration-satisfied"]})
checker=doc("sandbox_receipt_check","check.flow",{"check_verdict":"valid","enforcement_verdict":"satisfied"})
result_body={"check":{"path":"source.txt","expected_sha256":expected},
 "instruction_sha256":sha(instruction),"observed":{"sha256":expected,"size_bytes":6},
 "outcome":"match","reason_id":"file.match"}
result_raw=e.canonical(doc("file_digest_verifier_payload","file-digest-payload",result_body))
evidence_manifest=e.canonical(doc("sandbox_evidence_manifest","evidence-manifest",{"files":[{
 "name_hex":b"file-digest-result.json".hex(),"sha256":sha(result_raw),"size_bytes":len(result_raw)}]}))
receipt=doc("sandbox_enforcement_receipt","attempt.flow",{
 "lifecycle":{"admission":"admitted","runtime":"completed","control_deadline":"met"},
 "teardown":{"state":"confirmed"},"payload":{"exit_state":"exited","exit_code":0,
 "stdout_sha256":sha(b""),"stderr_sha256":sha(b""),
 "evidence_manifest_sha256":sha(evidence_manifest)}})
origin=e.canonical(doc("shadow_origin_observation","attempt.flow",{"store_id":"store.fixture",
 "attempt_id":"attempt.flow","entries":[],"result":"authenticated"}))
snapshots={"receipt.json":e.canonical(receipt),"payload/stdout":b"","payload/stderr":b"",
 "payload/evidence-manifest.json":evidence_manifest,"payload/evidence/0000":result_raw}
e.c.read_store_attempt=lambda anchor,attempt:(snapshots,origin)

real_run=e.run_bounded
def child(argv,**kwargs):
 role=pathlib.Path(argv[0]).name+":"+" ".join(argv[1:3]);events.append(role)
 if "validate-input" in argv or "validate-response" in argv: return b"true\n"
 if "validate-incident.sh" in " ".join(argv): return e.canonical(doc("shadow_incident_validation",incident["id"],{}))
 if "qualified-identity.jq" in " ".join(argv): return b""
 if "materialize.sh" in " ".join(argv): return e.canonical(response)
 if "prepare-candidate.py" in " ".join(argv):
  operation=argv[5]; out=pathlib.Path(argv[argv.index("--output")+1])
  events.append(operation)
  if operation=="prepare":
   out.mkdir(mode=0o700)
   write(out/"record.json",e.canonical(record));write(out/"manifest.json",e.canonical(manifest))
   candidate=out/"candidate";candidate.mkdir(mode=0o700);write(candidate/"source.txt",b"fixed\n")
  return b""
 if "evaluate-bound-sandbox.sh" in " ".join(argv): events.append("evaluate");return e.canonical(evaluation)
 if "check-sandbox-receipt.sh" in " ".join(argv): events.append("check-bound");return e.canonical(checker)
 if "validate-trace-ledger.sh" in " ".join(argv):
  trace=pathlib.Path(argv[-1]).read_bytes()
  return e.canonical(doc("telemetry_trace_ledger_validation","shadow-enforced-trace-ledger",{
   "ledger_ref":{"sha256":sha(trace)}}))
 raise AssertionError(argv)
e.run_bounded=child
launch_frames=[]
def launch(anchor,frame,deadline):
 ok((work/"launch/sandbox-request.json").exists() and (work/"launch/sandbox-expectation.json").exists(),
    "durable documents exist when launch seam starts")
 launch_frames.append(frame);events.append("launch");return 0
e._launch=launch
parent={"helper_source_sha256":e.c.HELPER_SOURCE_SHA256,"helper_build_record_sha256":"7"*64,
 "helper_executable_sha256":sha(b"helper"),"helper_executable_size":6,"helper_path":str(helper)}
bundle=e.reproduce(base/"request.json",work,output,parent)
ok(len(launch_frames)==1 and launch_frames[0].startswith(b"YSFRAME1"),"one framed launch")
ok(events.index("launch")>events.index("prepare"),"launch follows preparation")
ok(events.index("launch")>events.index("evaluate"),
   "launch follows actual bound evaluation call")
bundle_doc=e.parse(bundle)
ok(bundle_doc["body"]["record_form"]=="enforced-reproduction.v1","completed bundle record form")
ok(len(bundle_doc["body"]["files"])==29,"orchestration seals 29 evidence files")
record_doc=e.parse((output/"shadow-record.json").read_bytes())
ok(record_doc["body"]["outcome"]=="no-change" and record_doc["body"]["sandbox"]["state"]=="satisfied",
   "match maps to satisfied no-change")
ok(record_doc["body"]["producer_invocations"]==0,"consumer invokes no producer")
ok((output/"payload-stdout.txt").read_bytes()==b"" and (output/"payload-stderr.txt").read_bytes()==b"",
   "empty verifier streams retained")
ok(events.index("check-bound")>events.index("launch"),
   "receipt checker follows controlled-store launch evidence")
ok(events.count("dependency-recheck")>=4 and events.count("anchor-recheck")>=2,
   "dependencies and anchor rechecked through completion")
ok(not any("incident-to-eval" in row for row in events),"slice3 never enters write converter")
changed=json.loads(json.dumps(response));changed["stage_result"]["body"]["outcome"]["value"]="changed"
changed_receipt=json.loads(changed["payloads"][0]["data"])
changed_receipt["candidate"].update(commit_id=candidate_commit,tree_id=candidate_tree)
changed_receipt["changed_paths"]["count"]=1
changed["payloads"][0]["data"]=e.canonical(changed_receipt).decode()
changed["payloads"][0]["sha256"]=sha(e.canonical(changed_receipt))
try:e.require_no_change(e.canonical(changed),incident)
except e.Refusal as exc:ok(exc.code=="E_RELATION","changed materialization response cannot launch")
else:raise AssertionError("changed materialization accepted")
print("shadow-enforced-flow: %d checks passed"%checks)
PY

# Real acyclic prerequisite proof. This invokes the unchanged materializer,
# protocol, duty evaluator, bound evaluator, and receipt checker. Synthetic
# registry/accepted bytes live only in this private fixture package.
real="$tmp/slice3-real"
/bin/mkdir -m 700 "$real" "$real/home" "$real/source.git" "$real/bin"
/bin/cp "$jq_bin" "$real/bin/jq"; /bin/chmod 0500 "$real/bin/jq"; real_jq="$real/bin/jq"
git_fixture() {
  /usr/bin/env -i HOME="$real/home" TMPDIR="$real" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects "$@"
}
git_fixture init -q --bare --object-format=sha1 "$real/source.git"
real_blob=$(/usr/bin/printf 'fixed content\n' | git_fixture --git-dir="$real/source.git" hash-object -w --stdin)
real_tree=$(/usr/bin/printf '100644 blob %s\tsource.txt\n' "$real_blob" | git_fixture --git-dir="$real/source.git" mktree)
real_commit=$(/usr/bin/printf 'source\n' | git_fixture --git-dir="$real/source.git" commit-tree "$real_tree")
git_fixture --git-dir="$real/source.git" update-ref refs/heads/main "$real_commit"
/bin/bash "$root/scripts/test/local-git-materializer-fixtures.sh" build "$real/built" \
  "$real_jq" sha1 "$real_commit" "$real_tree"
empty_sha=$(/usr/bin/printf '' | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
/usr/bin/printf '%s\n' '{"kind":"fixture-declaration","id":"environment.earlier"}' > "$real/declaration.json"
declaration_sha=$(sha_file "$real/declaration.json")
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -S -c --arg empty "$empty_sha" --arg declaration_sha "$declaration_sha" '
  .payloads |= map(if .input_id=="input.producer-patch" then .data="" else . end) |
  .trust_context.verified_payloads |= map(if .input_id=="input.producer-patch"
    then .content.data="" | .sha256=$empty else . end) |
  .stage_request.content.body.inputs |= map(if .input_id=="input.producer-patch"
    then .value.value.value.sha256=$empty else . end)
' "$real/built/input.json" > "$real/prior-stage.json"
"$real_jq" -S -c '.stage_request.content' "$real/prior-stage.json" > "$real/prior-request.json"
prior_request_sha=$(sha_file "$real/prior-request.json")
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -S -c --arg digest "$prior_request_sha" '.stage_request.sha256=$digest' \
  "$real/prior-stage.json" > "$real/prior-input.json"
generation=$("$real_jq" -er '.[-1].generation_id' "$root/core/v2/generation-registry.json")
modules="$root/core/v2/generations/$generation/modules"
protocol="$root/adapters/local-git-materializer/v1/protocol.jq"
"$real_jq" -L "$modules" -e --arg command validate-input -f "$protocol" "$real/prior-input.json" \
  > "$real/prior-input.valid"
/bin/mkdir -m 700 "$real/candidate" "$real/materializer-scratch"
"$root/adapters/local-git-materializer/v1/materialize.sh" materialize "$real/prior-input.json" \
  fixture.target "$real/source.git" "$real/candidate" "$real/materializer-scratch" \
  "$tmp/object-closure" "$real_jq" > "$real/prior-response.json"
"$real_jq" -S -c '.stage_result' "$real/prior-response.json" > "$real/prior-result.json"
"$real_jq" -S -c '.resolved_profile.content' "$real/prior-input.json" > "$real/prior-profile.json"
stage_sha=$(sha_file "$real/prior-result.json")
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -S -c --arg stage_sha "$stage_sha" '
 . as $response | ($response.payloads[0].data|fromjson) as $receipt |
 {input:$input[0],response:$response,
  verified_receipt:{content:$receipt,sha256:$response.payloads[0].sha256},
  receipt_utf8:$response.payloads[0].data,stage_result_sha256:$stage_sha}
' --slurpfile input "$real/prior-input.json" "$real/prior-response.json" > "$real/prior-response-check.json"
"$real_jq" -L "$modules" -e --arg command validate-response -f "$protocol" \
  "$real/prior-response-check.json" > "$real/prior-response.valid"
PATH="$real/bin:/usr/bin:/bin" /bin/bash -p "$root/control/v1/evaluate-duty.sh" evaluate \
  "$root/control/v1/control-policy-set-sandbox-bound.json" "$real/prior-request.json" \
  "$real/prior-profile.json" "$real/prior-result.json" > "$real/duty.json"
"$real_jq" -e '.body.verdict=="satisfied" and .body.reason_ids==["duty.satisfied"]' \
  "$real/duty.json" > /dev/null || fail 'slice3 real bound-set duty'

verifier_root="$real/verifier-root"
/bin/mkdir -m 700 "$verifier_root" "$verifier_root/candidate" "$verifier_root/evidence" \
  "$verifier_root/scratch" "$verifier_root/tools"
/usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 \
  -DYSTACK_SANDBOX_ROOT="\"$verifier_root\"" "$root/verifiers/file-digest/v1/verifier.c" \
  -o "$real/file-digest-verifier"
/bin/chmod 0555 "$real/file-digest-verifier"

fixture="$real/package"
/bin/mkdir -p "$fixture"
for component_dir in adapters core preparation control enforcement shadow telemetry scripts; do
  /bin/cp -R "$root/$component_dir" "$fixture/$component_dir"
done
for name in evaluate-bound-sandbox.sh sandbox-bound.jq sandbox-bound-policy.json \
  sandbox-bound-decision.json control-policy-set-sandbox-bound.json validate.sh policy-set.jq; do
  /bin/cp "$root/control/v1/$name" "$fixture/control/v1/$name"
done
/bin/chmod 0755 "$fixture/control/v1/evaluate-bound-sandbox.sh" "$fixture/control/v1/validate.sh"
env_id=env.local-macos-fixture; verifier_sha=$(sha_file "$real/file-digest-verifier")
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -S -c --arg commit "$real_commit" '
 .body.environments=[(.body.environments[0] | .environment_id="env.local-macos-fixture" |
   .target_repository_id="fixture.target" | .source_root_commit=$commit | .proof_state="unproven")]
' "$root/shadow/v1/shadow-environments.json" > "$fixture/shadow/v1/shadow-environments.json"
registry="$fixture/shadow/v1/shadow-environments.json"
"$real_jq" -S -c '.body.environments[0]' "$registry" > "$real/entry.json"
entry_sha=$(sha_file "$real/entry.json")
accepted="$fixture/enforcement/v1/accepted-identities.json"
expected_sha=$(/usr/bin/printf 'fixed content\n' | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
instruction_sha=$(/usr/bin/printf 'ystack.file-digest-instruction.v1\npath source.txt\nsha256 %s\n' \
  "$expected_sha" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -nSc --arg env "$env_id" --arg verifier "$verifier_sha" --arg verifier_two "$(sha_file "$tmp/object-closure")" \
 --arg instruction "$instruction_sha" --arg guest_init "$(sha_file "$fixture/control/v1/sandbox-bound-policy.json")" \
 --arg guest_kernel "$(sha_file "$fixture/control/v1/sandbox-bound-decision.json")" \
 --arg guest_config "$(sha_file "$fixture/control/v1/control-policy-set-sandbox-bound.json")" \
 --arg guest_supervisor "$(sha_file "$fixture/control/v1/evaluate-bound-sandbox.sh")" \
 --arg host_runtime "$(sha_file "$python_bin")" --arg host_supervisor "$(sha_file "$fixture/shadow/v1/_consumer.py")" \
 --arg image "$(sha_file "$registry")" --arg toolchain "$(sha_file "$real_jq")" '
 def ids:{guest_init:[$guest_init],guest_kernel:[$guest_kernel],guest_kernel_config:[$guest_config],
 guest_supervisor:[$guest_supervisor],host_runtime:[$host_runtime],host_supervisor:[$host_supervisor],
 image:[$image],toolchain:[$toolchain],verification_instructions:[$instruction],verifier:([$verifier,$verifier_two]|sort|unique)};
 def mechanisms:{cpu_time_ms:["mechanism.cpu"],memory_bytes:["mechanism.memory"],
 output_bytes:["mechanism.output"],process_count:["mechanism.process"],
 scratch_bytes:["mechanism.scratch"],wall_time_ms:["mechanism.wall"]};
 {schema_version:1,kind:"sandbox_accepted_identity_set",id:"sandbox.accepted-identities.v1",
 body:{activation_state:"inactive",environments:[{environment_id:$env,identities:ids,
 mechanisms:mechanisms,scratch_bytes:1048576}],set_version:"v1"}}
' > "$accepted"
accepted_sha=$(sha_file "$accepted"); set="$fixture/control/v1/control-policy-set-sandbox-bound.json"
set_sha=$(sha_file "$set"); policy="$fixture/control/v1/sandbox-bound-policy.json"
duty_sha=$(sha_file "$real/duty.json")
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -nSc --arg env "$env_id" --arg d "$verifier_sha" --arg duty "$duty_sha" \
  --arg set_sha "$set_sha" --slurpfile p "$policy" --slurpfile prior "$real/duty.json" '
 def ref($v;$kind;$id;$sha):{schema_version:$v,kind:$kind,id:$id,sha256:$sha};
 {schema_version:1,kind:"execution_environment_claim",id:$env,body:{declaration_status:"complete",
 duty_evaluation_ref:ref(1;"duty_separation_evaluation";$prior[0].id;$duty),
 effects:{external_writes:false,target_writes:false},environment:$p[0].body.environment,
 execution_identity:{adapter_instance_id:"instance.verifier",execution_boundary_id:"boundary.verifier",
 principal_id:"principal.verifier",role:"verifier"},filesystem:$p[0].body.filesystem,
 isolation:$p[0].body.isolation,limits:$p[0].body.limits,network:$p[0].body.network,
 policy_set_ref:ref(1;"control_policy_set";"control-policy-set.sandbox-bound.v1";$set_sha),
 resources:$p[0].body.resources,sensitive_material:$p[0].body.sensitive_material,
 stage_result_ref:$prior[0].body.stage.result_ref,
 tools:[($p[0].body.tools[0]|del(.identity_binding)+{sha256:$d})]}}
' > "$real/claim.json"
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -nSc --arg env "$env_id" --arg entry "$entry_sha" --arg accepted "$accepted_sha" \
  --arg d "$verifier_sha" '{schema_version:1,kind:"sandbox_verifier_observation",
 id:"sandbox.observation.verifier",body:{environment_id:$env,environment_entry_sha256:$entry,
 target_repository_id:"fixture.target",accepted_set_sha256:$accepted,verifier_sha256:$d}}' \
  > "$real/observation.json"
PATH="$real/bin:/usr/bin:/bin" "$fixture/control/v1/evaluate-bound-sandbox.sh" evaluate \
  "$real/duty.json" "$real/claim.json" "$real/observation.json" > "$real/evaluation.json"
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -e --arg duty "$duty_sha" --arg d "$verifier_sha" '
 .body.verdict=="satisfied" and .body.duty_evaluation_ref.sha256==$duty and
 .body.verifier_binding.verifier_sha256==$d
' "$real/evaluation.json" > /dev/null || fail 'slice3 real bound evaluation'

# Q is constructed only after D and C. P and its real R/D bytes stay unchanged.
claim_sha=$(sha_file "$real/claim.json")
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -S -c --arg claim_sha "$claim_sha" '
 .stage_request.content.body.environment_ref={environment_id:"env.local-macos-fixture",fingerprint_sha256:$claim_sha}
' "$real/prior-input.json" > "$real/q-stage.json"
"$real_jq" -S -c '.stage_request.content' "$real/q-stage.json" > "$real/q-request.json"
q_sha=$(sha_file "$real/q-request.json")
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -S -c --arg q "$q_sha" '.stage_request.sha256=$q' "$real/q-stage.json" > "$real/q-input.json"
"$real_jq" -L "$modules" -e --arg command validate-input -f "$protocol" "$real/q-input.json" \
  > "$real/q-input.valid" || {
    /bin/cp "$real/q-input.json" /private/tmp/ystack-shadow-slice3-q-input.failed.json
    fail 'slice3 acyclic consumer request'
  }
/bin/mkdir -m 700 "$real/q-candidate" "$real/q-scratch"
q_status=0
PATH="$real/bin:/usr/bin:/bin" "$fixture/adapters/local-git-materializer/v1/materialize.sh" materialize \
  "$real/q-input.json" fixture.target "$real/source.git" "$real/q-candidate" "$real/q-scratch" \
  "$tmp/object-closure" "$real_jq" > "$real/q-response.json" 2> "$real/q-materializer.err" || q_status=$?
[ "$q_status" -eq 0 ] || { /bin/cp "$real/q-materializer.err" /private/tmp/ystack-shadow-slice3-q-materializer.err; fail "slice3 Q materializer status $q_status"; }
[ "$(sha_file "$real/prior-request.json")" = "$prior_request_sha" ] &&
[ "$(sha_file "$real/duty.json")" = "$duty_sha" ] || fail 'slice3 prerequisite tuple changed'

# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -nSc --arg commit "$real_commit" --arg expected "$expected_sha" '
 {schema_version:1,kind:"shadow_incident_record",id:"incident.shadow-reproduction",
  body:{deploy_authority:"none",target_repository_id:"fixture.target",
   git_revision_ref:{repository_id:"fixture.target",hash_algorithm:"sha1",commit_id:$commit},
   failing_check:{kind:"file-digest",path:"source.txt",expected_sha256:$expected},
   observed_symptom:"fixture digest check",reporter_actor_ref:"actor.fixture-reporter",
   observed_at:"2026-08-30T00:00:04Z"}}
' > "$real/incident.json"
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -nSc --arg commit "$real_commit" --arg blob "$real_blob" \
  --arg instruction "$instruction_sha" --slurpfile input "$real/q-input.json" '
 def pair($p):{schema_version:$p.content.schema_version,kind:$p.content.kind,
   id:$p.content.id,sha256:$p.sha256};
 {schema_version:1,kind:"qualified_identity",id:"identity.shadow-reproduction",body:{
  adapter_config_refs:[{content_id:"producer-config",media_type:"application/json",sha256:("1"*64)}],
  model_request:{effort_id:"high",model_id:"model.fixture",provider_id:"provider.fixture"},
  prompt_refs:[{location:{kind:"path",value:"routines/coder.md"},mode:"100644",
   object_id:$blob,object_type:"blob",revision:{commit_id:$commit,hash_algorithm:"sha1",
   repository_id:"fixture.target"}}],resolved_profile_ref:pair($input[0].resolved_profile),skill_refs:[],
  stage_request_ref:pair($input[0].stage_request),target_revision:{commit_id:$commit,
   hash_algorithm:"sha1",repository_id:"fixture.target"},verification_instructions_ref:{
   content_id:"verification-instructions",media_type:"text/plain",sha256:$instruction}}}
' > "$real/identity.json"
# shellcheck disable=SC2016 # jq expressions are intentionally protected from the shell.
"$real_jq" -nSc --arg real "$real" --arg jq "$real_jq" --arg helper "$tmp/object-closure" '
 {schema_version:1,kind:"shadow_enforced_request",id:"attempt.shadow-reproduction",body:{
  attempt_id:"attempt.shadow-reproduction",attempt_number:1,incident:($real+"/incident.json"),
  claim:($real+"/claim.json"),duty_evaluation:($real+"/duty.json"),
  materialization_input:($real+"/q-input.json"),qualified_identity:($real+"/identity.json"),
  source_git_dir:($real+"/source.git"),jq:$jq,closure_helper:$helper}}
' > "$real/request.json"

/usr/bin/printf 'shadow-enforced-real-chain: materializer/protocol/duty/bound-evaluator passed\n'

"$python_bin" -I -S -B - "$real" "$fixture" "$python_bin" <<'PY'
import dataclasses, hashlib, importlib.util, json, os, pathlib, shutil, stat, subprocess, sys, types
base, package, physical_python = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
module_path=package/"shadow/v1/enforced-reproduction.py"
spec=importlib.util.spec_from_file_location("real_shadow_enforced",module_path)
e=importlib.util.module_from_spec(spec);sys.modules[spec.name]=e;spec.loader.exec_module(e)
e.sys.executable=str(physical_python.resolve())
c=e.c
def sha(raw): return hashlib.sha256(raw).hexdigest()
def canonical(value): return json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()+b"\n"
def write(path,raw,mode):
 path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(raw);path.chmod(mode)
principal=1234;gid=os.getgid();store=base/"store";store.mkdir(mode=0o750)
anchor=base/"installation/supervisor";anchor.mkdir(parents=True,mode=0o755)
installed=base/"installation/installed";installed.mkdir(mode=0o755)
identities=base/"installation/identities";identities.mkdir(mode=0o755)
verifier=base/"file-digest-verifier"; verifier_root=base/"verifier-root"
identity_paths={}
for name in sorted(c.IDENTITY_KEYS-{"dyld_cache_files"}):
 path=verifier if name=="verifier" else identities/name
 if path!=verifier: write(path,(name+"\n").encode(),0o555)
 identity_paths[name]=str(path)
dyld=identities/"dyld-cache";write(dyld,b"dyld\n",0o555);identity_paths["dyld_cache_files"]=[str(dyld)]
installed_paths={}
for role,relative in c.INSTALLED_SOURCES.items():
 source=package/relative;target=installed/(role+".installed")
 write(target,source.read_bytes(),0o444);installed_paths[role]=str(target)
host_script=anchor/"host-supervisor.py";write(host_script,b"# fixture host supervisor\n",0o555)
config={"schema_version":1,"kind":"sandbox_host_config","id":"sandbox.host-config.v1","body":{
 "consumer_gid":gid,"environment_id":"env.local-macos-fixture","identity_paths":identity_paths,
 "installed_files":installed_paths,"principal_uid":principal,
 "runtime":{"driver":str(identities/"host_runtime"),"vfkit":str(identities/"vm_service")},
 "store_id":"store.shadow-fixture","store_root":str(store),"work_root":str(base/"host-work")}}
write(anchor/"host-config.json",canonical(config),0o444)
(base/"host-work").mkdir(mode=0o750)
c.ANCHOR=str(anchor)

# Preserve real kind/device/inode/link/size/change metadata. Substitute only the fixture's
# root/supervisor ownership and unsafe bits that cannot be created by an unprivileged test.
raw_metadata,raw_named,raw_acl=c._metadata,c._named_metadata,c._acl_state
root_ancestors=set();cursor=anchor
while True:
 root_ancestors.add(str(cursor))
 if cursor==cursor.parent: break
 cursor=cursor.parent
external_ancestors=set();cursor=base.parent.parent
while True:
 external_ancestors.add(str(cursor))
 if cursor==cursor.parent: break
 cursor=cursor.parent
external_identity={}
cursor=physical_python.resolve()
while True:
 root_ancestors.add(str(cursor))
 if cursor==cursor.parent: break
 cursor=cursor.parent
def fd_path(fd):
 if sys.platform=="darwin":
  raw=c.fcntl.fcntl(fd,50,b"\0"*1024)
  return raw.split(b"\0",1)[0].decode()
 return os.readlink(f"/proc/self/fd/{fd}")
def observed(state,path):
 path=os.path.realpath(path)
 if path in external_ancestors and stat.S_ISDIR(state.st_mode):
  key=(state.st_dev,state.st_ino)
  fixed=external_identity.setdefault(key,(state.st_nlink,state.st_size,state.st_mtime_ns,state.st_ctime_ns))
  state=types.SimpleNamespace(st_dev=state.st_dev,st_ino=state.st_ino,st_mode=state.st_mode,
   st_uid=state.st_uid,st_gid=state.st_gid,st_nlink=fixed[0],st_size=fixed[1],
   st_mtime_ns=fixed[2],st_ctime_ns=fixed[3])
 uid,gid_value,mode=state.st_uid,state.st_gid,state.st_mode
 if path==str(store) or path.startswith(str(store)+"/"):
  uid,gid_value=principal,gid
 elif (path in root_ancestors or path==str(anchor) or path.startswith(str(anchor)+"/") or
       path==str(installed) or path.startswith(str(installed)+"/") or
       path==str(identities) or path.startswith(str(identities)+"/") or
       path==str(verifier) or path==str(physical_python.resolve())):
  uid=0;mode &= ~(stat.S_IWGRP|stat.S_IWOTH)
 return types.SimpleNamespace(st_dev=state.st_dev,st_ino=state.st_ino,st_mode=mode,
  st_uid=uid,st_gid=gid_value,st_nlink=state.st_nlink,st_size=state.st_size,
  st_mtime_ns=state.st_mtime_ns,st_ctime_ns=state.st_ctime_ns)
def metadata(fd): return observed(raw_metadata(fd),fd_path(fd))
def named(name,parent_fd): return observed(raw_named(name,parent_fd),os.path.join(fd_path(parent_fd),name))
c._metadata,c._named_metadata=metadata,named
c._acl_state=lambda _fd:([],None) if sys.platform=="darwin" else (None,None)

work=base/"consumer-work";output=base/"consumer-output";work.mkdir(mode=0o700);output.mkdir(mode=0o700)
raw_fsync=os.fsync;fsync_paths=[]
def recording_fsync(fd):
 fsync_paths.append(fd_path(fd));return raw_fsync(fd)
e.os.fsync=recording_fsync
request=json.loads((base/"request.json").read_bytes())
instruction=("ystack.file-digest-instruction.v1\npath source.txt\nsha256 "+
 json.loads((base/"incident.json").read_bytes())["body"]["failing_check"]["expected_sha256"]+"\n").encode()
instruction_file=base/"verifier-instruction";write(instruction_file,instruction,0o400)
checks=0
scenario_mode="success";launch_count=0;scenario_output=None;scenario_work=work;scenario_request=None
def ok(value,message):
 global checks
 if not value: raise AssertionError(message)
 checks+=1;print(f"ok real-flow-{checks} - {message}")

def decode(frame):
 cursor=8;rows=[];digest=hashlib.sha256(b"YSFRAME1")
 if frame[:8]!=b"YSFRAME1": raise AssertionError("frame magic")
 while True:
  n=frame[cursor];cursor+=1;name=frame[cursor:cursor+n];cursor+=n
  size=int.from_bytes(frame[cursor:cursor+8],"big");cursor+=8;raw=frame[cursor:cursor+size];cursor+=size
  if name==b"end":
   if size!=32 or raw!=digest.digest() or cursor!=len(frame): raise AssertionError("frame seal")
   return rows
  encoded=bytes([len(name)])+name+len(raw).to_bytes(8,"big")+raw
  digest.update(encoded);rows.append((name,raw))

def launch(anchor_value,frame,_deadline):
 global launch_count
 launch_count+=1
 durable={str(scenario_work/"launch/sandbox-request.json"),
  str(scenario_work/"launch/sandbox-expectation.json"),str(scenario_work/"launch")}
 ok(durable.issubset(set(fsync_paths)),"actual request, expectation, and containing directory are durable before launch")
 if scenario_mode=="cancel": raise e.Refusal("E_RUNTIME")
 for name in ("candidate","evidence","scratch"):
  path=verifier_root/name
  if path.exists(): shutil.rmtree(path)
  path.mkdir(mode=0o700)
 rows=decode(frame);names=[name for name,_raw in rows]
 required=[b"request.json",b"evaluation.json",b"incident.json",b"record.json",b"manifest.json",b"instruction"]
 ok(names[:6]==required and all(name==f"candidate/{i:05d}".encode() for i,name in enumerate(names[6:])),
    "actual frame has fixed records and ordered candidate export")
 values=dict(rows);manifest=json.loads(values[b"manifest.json"])
 for index,row in enumerate(manifest["entries"]):
  raw=values[f"candidate/{index:05d}".encode()]
  if len(raw)!=row["size_bytes"] or sha(raw)!=row["sha256"]: raise AssertionError("candidate binding")
  write(verifier_root/"candidate"/row["path"],raw,0o400)
 instruction_file.chmod(0o600);write(instruction_file,values[b"instruction"],0o400)
 env={"LANG":"C","LC_ALL":"C","PATH":str(verifier_root/"tools"),"TMPDIR":str(verifier_root/"scratch")}
 with instruction_file.open("rb") as stdin:
  run=subprocess.run([str(verifier),"verify","--candidate",str(verifier_root/"candidate"),
    "--evidence",str(verifier_root/"evidence")],stdin=stdin,stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,env=env,check=False,timeout=30)
 ok(run.returncode==0 and run.stdout==b"" and run.stderr==b"","actual fixed verifier completed")
 result=(verifier_root/"evidence/file-digest-result.json").read_bytes()
 result_doc=json.loads(result);ok(result_doc["body"]["instruction_sha256"]==sha(values[b"instruction"]),
   "actual verifier result binds framed instruction")
 launch_doc=json.loads(values[b"request.json"])
 expectation=json.loads((scenario_work/"launch/sandbox-expectation.json").read_bytes())
 ok(expectation["body"]["attempt"]["launch_request_sha256"]==sha(values[b"request.json"]),
   "durable expectation binds actual launch bytes")
 attempt=store/launch_doc["id"];payload=attempt/"payload";evidence=payload/"evidence"
 evidence.mkdir(parents=True,mode=0o750)
 manifest_raw=canonical({"schema_version":1,"kind":"sandbox_evidence_manifest","id":"evidence-manifest",
  "body":{"files":[{"name_hex":b"file-digest-result.json".hex(),"sha256":sha(result),"size_bytes":len(result)}]}})
 write(payload/"stdout",run.stdout,0o440);write(payload/"stderr",run.stderr,0o440)
 write(payload/"evidence-manifest.json",manifest_raw,0o440);write(evidence/"0000",result,0o440)
 accepted=json.loads((package/"enforcement/v1/accepted-identities.json").read_bytes())["body"]["environments"][0]
 identities_rows={key:{"state":"observed","sha256":value[0]} for key,value in accepted["identities"].items()}
 identities_rows["verifier"]={"state":"observed","sha256":sha(verifier.read_bytes())}
 def limit(bound,observed,resolution,mechanism,observer):
  return {"bound":bound,"observed":observed,"resolution":resolution,"observation":"complete",
   "enforcement":"hard","reached":False,"mechanism_id":mechanism,"observer":observer}
 limits={"cpu_time_ms":limit(30000,1000,1,accepted["mechanisms"]["cpu_time_ms"][0],"guest-supervisor"),
  "wall_time_ms":limit(60000,2000,1,accepted["mechanisms"]["wall_time_ms"][0],"host-supervisor"),
  "memory_bytes":limit(536870912,1048576,4096,accepted["mechanisms"]["memory_bytes"][0],"guest-supervisor"),
  "output_bytes":limit(10485760,len(result),1,accepted["mechanisms"]["output_bytes"][0],"guest-supervisor"),
  "process_count":limit(32,1,1,accepted["mechanisms"]["process_count"][0],"guest-supervisor"),
  "scratch_bytes":limit(accepted["scratch_bytes"],4096,4096,accepted["mechanisms"]["scratch_bytes"][0],"guest-supervisor")}
 receipt={"schema_version":1,"kind":"sandbox_enforcement_receipt","id":"receipt."+sha(values[b"request.json"]),
  "body":{"contract_version":"v1","origin":{"producer_role":"host-supervisor",
   "store_id":"store.shadow-fixture","accepted_set_sha256":sha((package/"enforcement/v1/accepted-identities.json").read_bytes())},
   "attempt":expectation["body"]["attempt"],"control":launch_doc["body"]["control"],
   "subject":launch_doc["body"]["subject"],"identities":identities_rows,"limits":limits,
   "teardown":{"state":"confirmed","tree_terminated":True,"storage_destroyed":True},
   "lifecycle":{"admission":"admitted","runtime":"completed","control_deadline":"met"},
   "payload":{"stdout_sha256":sha(run.stdout),"stderr_sha256":sha(run.stderr),
    "evidence_manifest_sha256":sha(manifest_raw),"exit_state":"exited","exit_code":0},
   "timing":{"admitted_at":"2026-08-30T00:00:05Z","terminated_at":"2026-08-30T00:00:06Z"},
   "outcome":{"verdict":"satisfied","reason_ids":["enforcement.satisfied"]}}}
 if scenario_mode=="cpu-none":
  receipt["body"]["limits"]["cpu_time_ms"]["enforcement"]="none"
  receipt["body"]["limits"]["wall_time_ms"]["enforcement"]="none"
 if scenario_mode=="unconfirmed":receipt["body"]["teardown"]["state"]="unconfirmed"
 if scenario_mode!="missing":write(attempt/"receipt.json",canonical(receipt),0o440)
 if scenario_mode=="partial":(evidence/"0000").unlink()
 for directory in (store,attempt,payload,evidence): directory.chmod(0o750)
 if scenario_mode=="replace-output":
  displaced=scenario_output.with_name(scenario_output.name+"-displaced")
  scenario_output.rename(displaced);scenario_output.mkdir(mode=0o700)
 if scenario_mode=="mutate-component":
  component=package/"enforcement/v1/check-sandbox-receipt.sh"
  component.chmod(0o700);component.write_bytes(component.read_bytes()+b"\n")
 if scenario_mode in {"mutate-request","mutate-consumer","mutate-helper-source"}:
  changed={"mutate-request":scenario_request,"mutate-consumer":package/"shadow/v1/_consumer.py",
   "mutate-helper-source":package/"adapters/local-git-materializer/v1/object-closure.c"}[scenario_mode]
  changed.chmod(0o600);changed.write_bytes(changed.read_bytes()+b"\n")
 return 70 if scenario_mode=="incomplete" else 65 if scenario_mode=="refused" else 0
e._launch=launch
parent={"helper_source_sha256":c.HELPER_SOURCE_SHA256,"helper_build_record_sha256":sha(b"fixture-build"),
 "helper_executable_sha256":sha((base.parent/"object-closure").read_bytes()),
 "helper_executable_size":len((base.parent/"object-closure").read_bytes()),
 "helper_path":str(base.parent/"object-closure")}
bundle=e.reproduce(base/"request.json",work,output,parent)
bundle_doc=json.loads(bundle);ok(len(bundle_doc["body"]["files"])==29,"actual reproduce seals 29 evidence files")
record=json.loads((output/"shadow-record.json").read_bytes())
ok(record["body"]["record_form"]=="enforced-reproduction.v1" and
 record["body"]["outcome"]=="no-change" and record["body"]["producer_invocations"]==0,
 "actual reproduce retains enforced no-change record")
check=json.loads((output/"sandbox-check.json").read_bytes())
ok(check["body"]["check_verdict"]=="valid" and check["body"]["enforcement_verdict"]=="satisfied",
 "actual receipt checker accepts controlled-store receipt")
ok(json.loads((output/"file-digest-result.json").read_bytes())["body"]["reason_id"]=="file.match",
 "actual verifier payload is retained unchanged")
ok((output/"bundle.json").exists(),"completion marker written after real chain")
provenance=json.loads((output/"consumer-provenance.json").read_bytes())
roles=[row["role"] for row in provenance["body"]["commands"]]
ok(roles==["helper-version","jq-version","incident-validation","materializer-input-validation",
 "qualified-identity-validation","materialization","materializer-response-validation",
 "candidate-preparation","candidate-inspection","sandbox-bound-evaluation",
 "sandbox-launch-boundary","sandbox-receipt-check","trace-validation"] and
 all(set(row)=={"role","argv_sha256","executable_sha256","component_sha256"}
     for row in provenance["body"]["commands"]),
 "frozen provenance retains every executed role without private argv")
trace=json.loads((output/"trace-ledger.json").read_bytes())
ok(trace["body"]["events"][0]["facts"]["execution_environment"]["value"]=="env.local-macos-fixture" and
 trace["body"]["events"][0]["facts"]["gate"]["source_ref"]["sha256"]==sha((output/"sandbox-evaluation.json").read_bytes()) and
 trace["body"]["events"][1]["facts"]["gate"]["source_ref"]["sha256"]==sha((output/"sandbox-check.json").read_bytes()),
 "trace binds claim environment and distinct declaration and enforcement evidence")
checker_driver=package/"enforcement/v1/check-sandbox-receipt.sh"
checker_env={"PATH":str(base/"bin")+":/usr/bin:/bin","LC_ALL":"C","LANG":"C","TMPDIR":str(base/"checker-tmp")}
(base/"checker-tmp").mkdir(mode=0o700)
accepted=json.loads((package/"enforcement/v1/accepted-identities.json").read_bytes())["body"]["environments"][0]
def check_mutation(name,mutate):
 receipt=json.loads((output/"sandbox-receipt.json").read_bytes());mutate(receipt)
 path=base/(name+"-receipt.json");write(path,canonical(receipt),0o400)
 run=subprocess.run(["/bin/bash","-p",str(checker_driver),"check-bound",str(path),
  str(work/"launch/sandbox-expectation.json"),str(output/"sandbox-evaluation.json"),
  str(work/"observation/observation.json")],stdout=subprocess.PIPE,stderr=subprocess.PIPE,
  env=checker_env,check=False,timeout=30)
 if run.returncode!=0 or run.stderr: raise AssertionError((name,run.returncode,run.stderr))
 return json.loads(run.stdout)
second=next(value for value in accepted["identities"]["verifier"] if value!=sha(verifier.read_bytes()))
cross=check_mutation("cross-verifier",lambda receipt:receipt["body"]["identities"]["verifier"].update(sha256=second))
ok(cross["body"]["check_verdict"]=="refused" and cross["body"]["enforcement_verdict"]=="none"
 and cross["body"]["reason_ids"]==["receipt.control-mismatch","receipt.evaluation-not-satisfied"],
 "two accepted verifier digests cannot substitute for exact measured verifier")
wrong_subject=check_mutation("wrong-subject",lambda receipt:receipt["body"]["subject"]["candidate"].update(manifest_sha256="f"*64))
ok(wrong_subject["body"]["check_verdict"]=="refused" and
 any(reason.startswith("receipt.") for reason in wrong_subject["body"]["reason_ids"]),
 "otherwise valid receipt cannot substitute a candidate subject")

base_request=json.loads((base/"request.json").read_bytes())
base_q=json.loads((base/"q-input.json").read_bytes())
base_identity=json.loads((base/"identity.json").read_bytes())
base_incident=json.loads((base/"incident.json").read_bytes())
def case_documents(name,mutate=None):
 case=base/("case-"+name);case.mkdir(mode=0o700)
 q=json.loads(json.dumps(base_q));identity=json.loads(json.dumps(base_identity))
 incident=json.loads(json.dumps(base_incident));outer=json.loads(json.dumps(base_request))
 if mutate is not None: mutate(outer,q,identity,incident)
 q["stage_request"]["sha256"]=sha(canonical(q["stage_request"]["content"]))
 identity["body"]["stage_request_ref"]["sha256"]=q["stage_request"]["sha256"]
 identity["body"]["verification_instructions_ref"]["sha256"]=sha(e.make_instruction(incident))
 outer["id"]=outer["body"]["attempt_id"]="attempt."+name
 for field,value in (("incident",incident),("materialization_input",q),("qualified_identity",identity)):
  path=case/(field+".json");write(path,canonical(value),0o400);outer["body"][field]=str(path)
 request_path=case/"request.json";write(request_path,canonical(outer),0o400)
 return case,request_path
def prewrite_refusal(name,request_change=None,parent_change=None,work_path=None,source_root=None):
 case,request_path=case_documents(name);case_work=work_path or case/("work-"+name);case_output=case/"output"
 if not case_work.exists():case_work.mkdir(mode=0o700)
 case_output.mkdir(mode=0o700);before_entries=set(case_work.iterdir())
 if request_change is not None:
  outer=json.loads(request_path.read_bytes());request_change(outer,case_work)
  request_path.chmod(0o600);request_path.write_bytes(canonical(outer));request_path.chmod(0o400)
 context=dict(parent);context.update(parent_change or {})
 before=launch_count;old_source=e.SOURCE
 try:
  if source_root is not None:e.SOURCE=source_root
  try:e.reproduce(request_path,case_work,case_output,context)
  except (e.Refusal,c.Refusal):pass
  else:raise AssertionError(name+" accepted")
 finally:e.SOURCE=old_source
 ok(set(case_work.iterdir())==before_entries and not any(case_output.iterdir()) and launch_count==before,
    name+" refuses before workspace writes or launch")
prewrite_refusal("workspace-overlap",lambda outer,workspace:
 outer["body"].__setitem__("incident",str(workspace/"incident.json")))
prewrite_refusal("helper-context-mismatch",parent_change={"helper_path":str(base/"wrong-helper")})
prewrite_refusal("source-exclusion",source_root=base/"case-source-exclusion")
prewrite_refusal("installed-exclusion",work_path=installed/"private-work")
prewrite_refusal("store-exclusion",work_path=store/"private-work")
def refuse_case(name,mode="success",mutate=None,launches=0):
 global scenario_mode,scenario_output,scenario_work,scenario_request
 case,request_path=case_documents(name,mutate);case_work=case/"work";case_output=case/"output"
 case_work.mkdir(mode=0o700);case_output.mkdir(mode=0o700)
 scenario_mode=mode;scenario_output=case_output;scenario_work=case_work;scenario_request=request_path
 before=launch_count
 component=package/"enforcement/v1/check-sandbox-receipt.sh";original=component.read_bytes()
 changed={"mutate-request":request_path,"mutate-consumer":package/"shadow/v1/_consumer.py",
  "mutate-helper-source":package/"adapters/local-git-materializer/v1/object-closure.c"}.get(mode)
 changed_raw=changed.read_bytes() if changed else None
 try:
  try: e.reproduce(request_path,case_work,case_output,parent)
  except (e.Refusal,c.Refusal): pass
  else: raise AssertionError(name+" accepted")
 finally:
  if component.read_bytes()!=original:component.write_bytes(original);component.chmod(0o755)
  if changed is not None:
   changed.chmod(0o600);changed.write_bytes(changed_raw);changed.chmod(0o400 if changed==request_path else 0o644)
 ok(launch_count-before==launches,name+" stops at the intended boundary")
 marker=case_output/"bundle.json"
 displaced=case_output.with_name(case_output.name+"-displaced")/"bundle.json"
 ok(not marker.exists() and not displaced.exists(),name+" cannot expose completion marker")

def changed_patch(_outer,q,_identity,_incident):
 changed="changed content\n";digest=sha(changed.encode())
 for row in q["payloads"]:
  if row["input_id"]=="input.producer-patch": row["data"]=changed
 for row in q["trust_context"]["verified_payloads"]:
  if row["input_id"]=="input.producer-patch": row["content"]["data"]=changed;row["sha256"]=digest
 for row in q["stage_request"]["content"]["body"]["inputs"]:
  if row["input_id"]=="input.producer-patch": row["value"]["value"]["value"]["sha256"]=digest
def wrong_environment(_outer,q,_identity,_incident):
 q["stage_request"]["content"]["body"]["environment_ref"]={"environment_id":"env.unrelated","fingerprint_sha256":"f"*64}
def wrong_identity(_outer,_q,identity,_incident):
 identity["body"]["stage_request_ref"]["id"]="request.unrelated"
 identity["body"]["resolved_profile_ref"]["id"]="profile.unrelated"
def bool_request(outer,_q,_identity,_incident):
 outer["schema_version"]=True;outer["body"]["attempt_number"]=True
def wrong_expected(_outer,_q,_identity,incident):
 incident["body"]["failing_check"]["expected_sha256"]="0"*64

refuse_case("changed-patch",mutate=changed_patch)
refuse_case("wrong-environment",mutate=wrong_environment)
refuse_case("wrong-identity",mutate=wrong_identity)
refuse_case("boolean-request",mutate=bool_request)
for mode in ("incomplete","refused","missing","partial","cpu-none","unconfirmed","cancel",
             "replace-output","mutate-component","mutate-request","mutate-consumer",
             "mutate-helper-source"):
 refuse_case(mode,mode=mode,launches=1)
case,request_path=case_documents("mismatch",wrong_expected)
case_work=case/"work";case_output=case/"output";case_work.mkdir(mode=0o700);case_output.mkdir(mode=0o700)
scenario_mode="success";scenario_output=case_output;scenario_work=case_work
mismatch=json.loads(e.reproduce(request_path,case_work,case_output,parent))
ok(mismatch["body"]["record_form"]=="enforced-reproduction.v1" and
 json.loads((case_output/"shadow-record.json").read_bytes())["body"]["outcome"]=="reproduced",
 "actual mismatch completes only as a reproduced result")
scenario_mode="success";scenario_output=None
print(f"shadow-enforced-real-reproduce: {checks} checks passed")
PY
