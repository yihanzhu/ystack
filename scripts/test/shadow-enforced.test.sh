#!/bin/bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
python3 -I -S -B - "$ROOT" <<'PY'
import hashlib
import importlib.util
import json
import os
import pathlib
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("shadow_consumer", root / "shadow/v1/_consumer.py")
c = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = c
spec.loader.exec_module(c)
checks = 0
def ok(value, message):
    global checks
    assert value, message
    checks += 1
def refuses(code, call):
    global checks
    try:
        call()
    except c.Refusal as exc:
        assert exc.code == code, (exc.code, code)
        checks += 1
        return
    raise AssertionError("accepted: " + code)
def write(path, data, mode=0o440):
    path.write_bytes(data)
    path.chmod(mode)
def parent_doc(path, raw):
    return c.canonical({"schema_version": 1, "kind": "shadow_consumer_parent_context",
        "id": "shadow.parent", "body": {
        "helper_source_sha256": c.HELPER_SOURCE_SHA256,
        "helper_build_record_sha256": "2" * 64,
        "helper_executable_sha256": hashlib.sha256(raw).hexdigest(),
        "helper_executable_size": len(raw), "helper_path": str(path)}})

with tempfile.TemporaryDirectory() as td:
    base = pathlib.Path(td).resolve()
    c.verify_helper_source(str(root))
    invoked_python = c.sys.executable
    c.sys.executable = os.path.realpath(invoked_python)
    ok(c.isolated_python_argv(str(root))[1:4] == ["-I", "-S", "-B"], "isolated Python")
    c.sys.executable = invoked_python
    helper = base / "marker-helper"
    marker = base / "executed"
    helper_raw = ("#!/bin/sh\ntouch %s\n" % marker).encode()
    write(helper, helper_raw, 0o700)
    context = base / "context.json"
    write(context, parent_doc(helper, helper_raw), 0o400)
    body = c.capture_parent_context(os.open(context, os.O_RDONLY))
    ok(body["helper_path"] == str(helper), "parent context")
    ok(not marker.exists(), "unaccepted helper executed")
    context.chmod(0o600)
    writable = os.open(context, os.O_RDWR)
    refuses("E_PARENT_CONTEXT", lambda: c.capture_parent_context(writable))
    refuses("E_PARENT_CONTEXT", lambda: c.capture_parent_context(-1))
    write(context, parent_doc(helper, helper_raw).replace(b'"shadow.parent"', b'"shadow.parent","id":"x"'), 0o400)
    refuses("E_PARENT_CONTEXT", lambda: c.capture_parent_context(os.open(context, os.O_RDONLY)))
    private = base / "private"
    dep = c.snapshot_dependency(str(helper), hashlib.sha256(helper_raw).hexdigest(), len(helper_raw),
                                str(private), "helper")
    ok(dep.snapshot.read(len(helper_raw), "E_DEPENDENCY") == helper_raw, "private snapshot")
    ok(stat_mode := (os.stat(private).st_mode & 0o777) == 0o500, "private mode")
    ok(not marker.exists(), "snapshot did not execute helper")
    helper.chmod(0o700)
    helper.write_bytes(helper_raw + b"# moved\n")
    refuses("E_DEPENDENCY", dep.recheck)
    dep.close()
    race = base / "race"
    write(race, b"stable", 0o600)
    held = c._open_held(str(race), False, lambda _fd, _st, _a: True, "E_DEPENDENCY")
    real_read, changed = c.os.read, [False]
    def racing_read(fd, size):
        data = real_read(fd, size)
        if fd == held.fd and data and not changed[0]:
            changed[0] = True
            race.write_bytes(b"changed")
        return data
    c.os.read = racing_read
    refuses("E_DEPENDENCY", lambda: held.read(32, "E_DEPENDENCY"))
    c.os.read = real_read
    held.close()
    acl_fd = os.open(base, os.O_RDONLY)
    real_acl = c._acl
    c._acl = lambda _fd: [(1, None, 1 << 2)] if sys.platform == "darwin" else [(0x10, 2, 0)]
    ok(not c._root_rule_acl(acl_fd, 12345), "write ACL refused")
    c._acl = real_acl
    os.close(acl_fd)
    alias = base / "alias"
    original = base / "original"
    write(original, b"x", 0o400)
    os.link(original, alias)
    refuses("E_DEPENDENCY", lambda: c.snapshot_dependency(str(alias), hashlib.sha256(b"x").hexdigest(),
                                                            1, str(base / "p2"), "helper"))
    install = base / "install"
    install.mkdir()
    write(install / "host-config.json", b"not json", 0o400)
    write(install / "host-supervisor.py", b"x", 0o400)
    old_anchor, old_root = c.ANCHOR, c._root_rule
    c.ANCHOR = str(install)
    c._root_rule = lambda _fd, _st, _ancestor: False
    refuses("E_INSTALL", c.load_anchor)
    c.ANCHOR, c._root_rule = old_anchor, old_root
    installed = base / "installed"
    installed.mkdir()
    files = {}
    for index, key in enumerate(sorted(c.INSTALLED_KEYS | (c.IDENTITY_KEYS - {"dyld_cache_files"}))):
        path = installed / (str(index) + "-" + key)
        write(path, key.encode(), 0o400)
        files[key] = str(path)
    cache = installed / "cache"
    write(cache, b"cache", 0o400)
    store = base / "store"
    store.mkdir(mode=0o750)
    config_body = {"consumer_gid": os.getgid(), "environment_id": "env.test",
        "identity_paths": {k: ([str(cache)] if k == "dyld_cache_files" else files[k]) for k in c.IDENTITY_KEYS},
        "installed_files": {k: files[k] for k in c.INSTALLED_KEYS}, "principal_uid": 12345,
        "runtime": {"driver": files["host_runtime"], "vfkit": files["vm_service"]},
        "store_id": "store.test", "store_root": str(store), "work_root": str(base / "work")}
    config = {"schema_version": 1, "kind": "sandbox_host_config", "id": "host",
              "body": config_body}
    (install / "host-config.json").chmod(0o600)
    write(install / "host-config.json", c.canonical(config), 0o400)
    old_anchor, old_root, old_installed, old_python = c.ANCHOR, c._root_rule, c._installed_rule, c.sys.executable
    c.ANCHOR = str(install)
    c.sys.executable = files["toolchain"]
    c._root_rule = lambda _fd, _st, _ancestor: True
    c._installed_rule = lambda _uid: (lambda _fd, _st, _ancestor: True)
    anchor = c.load_anchor()
    ok(anchor.config["principal_uid"] == 12345, "root-authenticated config")
    c.ANCHOR, c._root_rule, c._installed_rule, c.sys.executable = old_anchor, old_root, old_installed, old_python
    attempt = store / "attempt.test"
    payload = attempt / "payload"
    payload.mkdir(parents=True, mode=0o750)
    attempt.chmod(0o750)
    evidence = b"proof"
    manifest = c.canonical({"schema_version": 1, "kind": "sandbox_evidence_manifest",
        "id": "evidence-manifest", "body": {"files": [{"name_hex": "70",
        "sha256": hashlib.sha256(evidence).hexdigest(), "size_bytes": len(evidence)}]}})
    for name, raw in (("stdout", b""), ("stderr", b""), ("evidence-manifest.json", manifest)):
        write(payload / name, raw)
    (payload / "evidence").mkdir(mode=0o750)
    write(payload / "evidence/0000", evidence)
    write(attempt / "receipt.json", c.canonical({"receipt": "fixture"}))
    old_store = c._store_rule
    # Keep the production driver real; substitute only its private metadata observer.
    import stat
    c._store_rule = lambda _uid, _gid, mode, directory: (
        lambda _fd, st, ancestor: ancestor or ((stat.S_ISDIR(st.st_mode) if directory else stat.S_ISREG(st.st_mode))
                                                and stat.S_IMODE(st.st_mode) == mode))
    snapshots, observation = c.read_store_attempt(anchor, "attempt.test")
    ok(set(snapshots) == {"receipt.json", "payload/stdout", "payload/stderr",
                          "payload/evidence-manifest.json", "payload/evidence/0000"}, "fixed store inventory")
    ok(json.loads(observation)["body"]["result"] == "authenticated", "origin observation")
    write(payload / "extra", b"x")
    refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.test"))
    (payload / "extra").unlink()
    os.link(payload / "stdout", payload / "alias")
    refuses("E_STORE", lambda: c.read_store_attempt(anchor, "attempt.test"))
    (payload / "alias").unlink()
    c._store_rule = old_store
    anchor.close()
print("shadow-enforced: %d checks passed" % checks)
PY
