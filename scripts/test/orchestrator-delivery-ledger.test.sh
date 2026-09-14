#!/bin/bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077
root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
product="$root/orchestrator/v1/delivery-ledger.py"
[ -f "$product" ] && [ ! -L "$product" ] || {
  printf '%s\n' 'FAIL P1: delivery-ledger public source missing' >&2
  exit 1
}
platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Linux:x86_64) python=/usr/bin/python3; git_bin=/usr/bin/git
    jq_asset=jq-linux64; jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  Darwin:arm64|Darwin:x86_64)
    python=/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python
    git_bin=/Library/Developer/CommandLineTools/usr/bin/git
    jq_asset=jq-osx-amd64; jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  *) printf 'FAIL unsupported ledger platform: %s\n' "$platform" >&2; exit 1 ;;
esac
[ -x "$python" ] && [ -x "$git_bin" ] || exit 1
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-ledger-test.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
download=''
cleanup() {
  [ -z "$download" ] || /bin/rm -f -- "$download"
  /bin/rm -rf -- "$tmp"
}
trap cleanup EXIT
sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
cache_dir="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$cache_dir"
cache="$cache_dir/$jq_asset"
if [ ! -f "$cache" ] || [ "$(sha_file "$cache")" != "$jq_sha" ]; then
  download=$(/usr/bin/mktemp "$cache_dir/.jq-ledger.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 60 \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$download"
  [ "$(sha_file "$download")" = "$jq_sha" ] || exit 1
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$cache"
  download=''
fi
[ "$(sha_file "$cache")" = "$jq_sha" ] || exit 1
/bin/mkdir -m 700 "$tmp/bin"
/bin/cp "$cache" "$tmp/bin/jq"
/bin/chmod 0555 "$tmp/bin/jq"
[ "$(sha_file "$tmp/bin/jq")" = "$jq_sha" ] &&
  [ "$("$tmp/bin/jq" --version)" = jq-1.6 ] || exit 1
cat > "$tmp/harness.py" <<'PY'
import hashlib
import json
import os
import pathlib
import selectors
import signal
import stat
import subprocess
import sys
import time

PRODUCT, ROOT, PYTHON, GIT, JQ = sys.argv[1:]
ROOT = pathlib.Path(ROOT)
GROUPS = {"P%d" % i: 0 for i in range(1, 12)}
START = time.monotonic()
PROTOCOL = "ystack.delivery-ledger.v1"
TIME = "2000-01-01T00:00:00Z"


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"),
                       ensure_ascii=True) + "\n").encode("ascii")


def record(group, name, condition):
    if not condition:
        raise AssertionError("%s: %s" % (group, name))
    GROUPS[group] += 1
    print("ok %s.%d - %s" % (group, GROUPS[group], name), flush=True)


def environment(store):
    return {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C",
            "HOME": "/dev/null", "TMPDIR": str(store)}


def stop_owned(child):
    if child.poll() is not None:
        return
    child.terminate()
    try:
        child.wait(timeout=1)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=1)


def captured(argv, cwd, env, data=None, timeout=120, limits=(524288, 64)):
    if time.monotonic() - START > 1800:
        raise AssertionError("whole focused suite deadline")
    with subprocess.Popen(argv, cwd=str(cwd), env=env,
                          stdin=subprocess.PIPE if data is not None else subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
        selector = selectors.DefaultSelector()
        result = [bytearray(), bytearray()]
        for index, stream in enumerate((child.stdout, child.stderr)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, index)
        if data is not None:
            os.set_blocking(child.stdin.fileno(), False)
            selector.register(child.stdin, selectors.EVENT_WRITE, 2)
        offset = 0
        deadline = time.monotonic() + timeout
        try:
            while selector.get_map():
                if time.monotonic() >= deadline:
                    raise AssertionError("child deadline: " + repr(argv))
                for key, _ in selector.select(0.05):
                    if key.data == 2:
                        count = os.write(key.fd, data[offset:offset + 65536])
                        offset += count
                        if offset == len(data):
                            selector.unregister(key.fileobj)
                            key.fileobj.close()
                        continue
                    block = os.read(key.fd, min(65536, limits[key.data] + 1 - len(result[key.data])))
                    if not block:
                        selector.unregister(key.fileobj)
                    else:
                        result[key.data].extend(block)
                        if len(result[key.data]) > limits[key.data]:
                            raise AssertionError("child output cap")
            status = child.wait(timeout=max(0.01, deadline - time.monotonic()))
        finally:
            selector.close()
            stop_owned(child)
        return status, bytes(result[0]), bytes(result[1])


def request(kind="read", **fields):
    result = {"protocol": PROTOCOL, "store_id": "store.test", "ledger_id": "ledger.test"}
    if kind == "initialize":
        result.update(initialization_id="init.test", recorded_at=TIME)
    result.update(fields)
    return result


def key(**fields):
    result = {"stage_key": {"initiative_id": "initiative.test", "workflow_id": "workflow.test",
                            "stage_id": "stage.test", "task_class_id": "task.test"},
              "request_sha256": "a" * 64, "operation": "dispatch-stage", "attempt_number": 1}
    result.update(fields)
    return result


def invoke(store, verb, value, raw=None):
    path = ROOT / ("request-%d.json" % time.monotonic_ns())
    path.write_bytes(canonical(value) if raw is None else raw)
    return captured([PYTHON, "-I", "-S", "-B", PRODUCT, verb, str(store), str(path)],
                    store, environment(store))


def new_store(name):
    store = ROOT / name
    store.mkdir(mode=0o700)
    return store


def public_protocol():
    store = new_store("protocol")
    status, out, err = invoke(store, "initialize", request("initialize"))
    record("P1", "initialize actual public entry", status == 0 and not err)
    doc = json.loads(out)
    record("P1", "exact canonical stdout", canonical(doc) == out)
    status, read_out, err = invoke(store, "read", request())
    record("P1", "read exact initial tip", status == 0 and not err and
           json.loads(read_out)["current_tip"] == doc["current_tip"])
    return store, doc


public_protocol()
for group, count in GROUPS.items():
    if not count:
        raise AssertionError("required proof group not executed: " + group)
print("ledger proof groups:", json.dumps(GROUPS, sort_keys=True), flush=True)
PY
"$python" -I -S -B "$tmp/harness.py" "$product" "$tmp" "$python" "$git_bin" "$tmp/bin/jq"
