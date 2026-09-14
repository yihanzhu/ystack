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
  status=$?
  [ -z "$download" ] || /bin/rm -f -- "$download"
  if [ "$status" -eq 0 ]; then
    /bin/rm -rf -- "$tmp"
  else
    printf 'ledger failed fixtures retained: %s\n' "$tmp" >&2
  fi
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
import shutil
import zlib
import importlib.util
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
    remaining()
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


def remaining(deadline=None):
    end = min(START + 1800, deadline if deadline is not None else START + 1800)
    value = end - time.monotonic()
    assert value > 0, "focused suite or child deadline"
    return value


def close_fd(owned, fd):
    owned.remove(fd)
    os.close(fd)


def cleanup(children, descriptors, selector=None):
    original = sys.exc_info()[1]
    errors = []
    def attempt(operation):
        try:
            operation()
        except BaseException as error:
            errors.append(repr(error))
    while descriptors:
        fd = descriptors.pop()
        attempt(lambda: os.close(fd))
    for child in children:
        if child.stdin is not None and not child.stdin.closed:
            attempt(child.stdin.close)
    for child in children:
        attempt(lambda: stop_owned(child))
    for child in children:
        for stream in (child.stdout, child.stderr):
            if stream is not None and not stream.closed:
                attempt(stream.close)
    if selector is not None:
        attempt(selector.close)
    if errors:
        print("ledger cleanup failures:", errors, "original:", repr(original), file=sys.stderr, flush=True)
        if original is None:
            raise AssertionError("unconfirmed owned cleanup: " + repr(errors))


def captured(argv, cwd, env, data=None, timeout=120, limits=(524288, 64), deadline=None):
    deadline = min(START + 1800, deadline if deadline is not None else START + 1800, time.monotonic() + timeout)
    remaining(deadline)
    children = []
    selector = None
    try:
        child = subprocess.Popen(argv, cwd=str(cwd), env=env,
                                 stdin=subprocess.PIPE if data is not None else subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        children.append(child)
        selector = selectors.DefaultSelector()
        result = [bytearray(), bytearray()]
        for index, stream in enumerate((child.stdout, child.stderr)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, index)
        if data == b"":
            child.stdin.close()
        elif data is not None:
            os.set_blocking(child.stdin.fileno(), False)
            selector.register(child.stdin, selectors.EVENT_WRITE, 2)
        offset = 0
        while selector.get_map():
            for key, _ in selector.select(min(0.05, remaining(deadline))):
                if key.data == 2:
                    count = os.write(key.fd, data[offset:offset + 65536])
                    assert 0 < count <= min(65536, len(data) - offset)
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
                    assert len(result[key.data]) <= limits[key.data], "child output cap"
        status = child.wait(timeout=remaining(deadline))
        return status, bytes(result[0]), bytes(result[1])
    finally:
        cleanup(children, [], selector)


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


def invoke(store, verb, value, raw=None, deadline=None):
    path = ROOT / ("request-%d.json" % time.monotonic_ns())
    path.write_bytes(canonical(value) if raw is None else raw)
    return captured([PYTHON, "-I", "-S", "-B", PRODUCT, verb, str(store), str(path)],
                    store, environment(store), deadline=deadline)


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


def good(store, verb, value, group="P1", name=None, deadline=None):
    status, out, err = invoke(store, verb, value, deadline=deadline)
    if status or err:
        raise AssertionError((group, name or verb, status, out, err))
    doc = json.loads(out)
    record(group, name or verb, canonical(doc) == out)
    return doc


def refused(store, verb, value, code=None, group="P1", name="refusal", raw=None):
    before = inventory(store)
    status, out, err = invoke(store, verb, value, raw)
    record(group, name, status != 0 and not out and
           (err == (code + "\n").encode() if code else err.startswith(b"E_")))
    record(group, name + " leaves bytes", inventory(store) == before)
    return err


def inventory(root):
    result = {}
    paths = [root]
    for path in root.rglob("*"):
        remaining()
        paths.append(path)
    for path in sorted(paths):
        remaining()
        state = path.lstat()
        relative = str(path.relative_to(root))
        value = [stat.S_IFMT(state.st_mode), stat.S_IMODE(state.st_mode), state.st_size if path.is_file() else 0]
        if path.is_symlink():
            value.append(os.readlink(path))
        elif stat.S_ISREG(state.st_mode):
            value.append(hashlib.sha256(path.read_bytes()).hexdigest())
        result[relative] = value
    return result


def update(tip, ordinal=1, action="record-delivery", update_id="update.test", delivery_key=None, **fields):
    return request("apply-update", expected_tip=tip, delivery_key=delivery_key or key(),
                   action=action, update_id=update_id, recorded_at=TIME,
                   delivery_ordinal=ordinal, **fields)


def copy_store(source, name):
    destination = ROOT / name
    remaining()
    def copied_file(source_path, target_path):
        remaining()
        result = shutil.copy2(source_path, target_path)
        remaining()
        return result
    shutil.copytree(source, destination, copy_function=copied_file)
    remaining()
    os.chmod(destination, 0o700)
    return destination


def raw_object(kind, content):
    raw = kind.encode() + b" " + str(len(content)).encode() + b"\0" + content
    return hashlib.sha1(raw).hexdigest(), zlib.compress(raw), raw


def object_put(store, kind, content):
    remaining()
    oid, compressed, raw = raw_object(kind, content)
    directory = store / "repository.git" / "objects" / oid[:2]
    directory.mkdir(mode=0o700, exist_ok=True)
    path = directory / oid[2:]
    if not path.exists():
        path.write_bytes(compressed)
        path.chmod(0o600)
    return oid, len(compressed), len(raw)


def object_read(store, oid):
    raw = zlib.decompress((store / "repository.git" / "objects" / oid[:2] / oid[2:]).read_bytes())
    header, content = raw.split(b"\0", 1)
    kind, size = header.split(b" ", 1)
    assert int(size) == len(content) and hashlib.sha1(raw).hexdigest() == oid
    return kind.decode(), content


def commit_members(store, tip):
    kind, content = object_read(store, tip)
    assert kind == "commit"
    tree = content.splitlines()[0].split()[1].decode()
    kind, content = object_read(store, tree)
    assert kind == "tree"
    members = {}
    offset = 0
    while offset < len(content):
        end = content.index(0, offset)
        mode, name = content[offset:end].split(b" ", 1)
        assert mode == b"100644"
        members[name.decode()] = content[end + 1:end + 21].hex()
        offset = end + 21
    return members


def rewrite_tip(store, changes=None, commit_change=None, tree_change=None):
    ref = store / "repository.git/refs/heads/ledger"
    tip = ref.read_text().strip()
    kind, old = object_read(store, tip)
    members = commit_members(store, tip)
    for name, transform in (changes or {}).items():
        kind, content = object_read(store, members[name])
        members[name] = object_put(store, kind, transform(content))[0]
    tree = b"".join(b"100644 " + name.encode() + b"\0" + bytes.fromhex(members[name]) for name in sorted(members))
    if tree_change:
        tree = tree_change(tree)
    tree_id = object_put(store, "tree", tree)[0]
    content = b"tree " + tree_id.encode() + b"\n" + old.split(b"\n", 1)[1]
    if commit_change:
        content = commit_change(content)
    new_tip = object_put(store, "commit", content)[0]
    ref.write_text(new_tip + "\n")
    return new_tip


def oracle(data, name, group="P1"):
    fixture = ROOT / ("oracle-" + name + ".json")
    fixture.write_bytes(data)
    status, out, err = captured([JQ, "-S", "-c", ".", str(fixture)], ROOT,
                                 environment(ROOT), limits=(524288, 4096))
    record(group, name + " actual jq byte oracle", status == 0 and not err and out == data)


def protocol_cases():
    store, initial = public_protocol()
    oracle(canonical(initial), "initialize-response")
    for name, oid in commit_members(store, initial["current_tip"]).items():
        oracle(object_read(store, oid)[1], "stored-" + name)
    valid = request("initialize")
    invalid = [[], None, 1, True, "text", dict(valid, extra=1), {"protocol": PROTOCOL}]
    for verb, complete in (("initialize", valid), ("read", request()), ("apply-update", update(initial["current_tip"]))):
        for field in complete:
            incomplete = {key: value for key, value in complete.items() if key != field}
            refused(store, verb, incomplete, "E_INPUT", name=verb + " missing " + field)
        refused(store, verb, dict(complete, extra="forbidden"), "E_INPUT", name=verb + " unknown field")
    for field, wrong in (("action", []), ("delivery_key", None), ("delivery_key", []), ("expected_tip", False), ("update_id", {}), ("recorded_at", [])):
        value = update(initial["current_tip"])
        value[field] = wrong
        refused(store, "apply-update", value, "E_INPUT", name="malformed " + field)
    nested = update(initial["current_tip"])
    raw = canonical(nested).replace(b'"stage_id":"stage.test"', b'"stage_id":"stage.test","stage_id":"stage.test"')
    refused(store, "apply-update", nested, "E_INPUT", name="nested duplicate key", raw=raw)
    for index, value in enumerate(invalid):
        refused(store, "initialize", value, "E_INPUT", name="root/field-%d" % index)
    raw_cases = [b"", b"{", canonical(valid)[:-1], b" " + canonical(valid),
                 canonical(valid) + b"{}\n", b"\xef\xbb\xbf" + canonical(valid),
                 canonical(valid).replace(b'"store_id":"store.test"', b'"store_id":"store.test","store_id":"store.test"'),
                 canonical(valid).replace(b"store.test", b"store\\u002etest"),
                 b"[" * 4000 + b"]" * 4000, b"x" * 8192, b"x" * 8193]
    for index, data in enumerate(raw_cases):
        refused(store, "initialize", valid, "E_INPUT", name="raw-%d" % index, raw=data)
    for index, ident in enumerate(["", "A", "a" * 129, "a/b", "\u00e9", "x\n", 1, False]):
        refused(store, "read", request(store_id=ident), "E_INPUT", name="id-%d" % index)
    for ident in ["a", "a" * 128, "a._:-9"]:
        fixture = new_store("id-positive-%d" % len(list(ROOT.glob("id-positive-*"))))
        good(fixture, "initialize", request("initialize", store_id=ident), name="valid ID " + str(len(ident)))
    for index, value in enumerate([False, -1, 1.0, 2147483648, "1"]):
        refused(store, "apply-update", update(initial["current_tip"], value), "E_INPUT", name="ordinal-type-%d" % index)
    for index, data in enumerate([b"-0", b"1e0", b"1.0"]):
        value = update(initial["current_tip"])
        raw = canonical(value).replace(b'"delivery_ordinal":1', b'"delivery_ordinal":' + data)
        refused(store, "apply-update", value, "E_INPUT", name="numeric-encoding-%d" % index, raw=raw)
    for index, date in enumerate(["0000-02-29T00:00:00Z", "2000-02-29T23:59:59Z", "1900-02-28T00:00:00Z"]):
        fixture = new_store("date-%d" % index)
        doc = good(fixture, "initialize", request("initialize", recorded_at=date), name="valid date " + date)
        oracle(canonical(doc), "date-%d" % index)
    for index, date in enumerate(["1900-02-29T00:00:00Z", "2001-02-29T00:00:00Z", "0000-00-01T00:00:00Z",
                                  "2000-13-01T00:00:00Z", "2000-01-00T00:00:00Z", "2000-01-32T00:00:00Z",
                                  "2000-01-01T24:00:00Z", "2000-01-01T00:60:00Z", "2000-01-01T00:00:60Z",
                                  "2000-01-01T00:00:00.1Z", "2000-01-01T00:00:00+00:00"]):
        refused(store, "initialize", request("initialize", recorded_at=date), "E_INPUT", name="invalid date-%d" % index)
    for argv in [[], ["unknown"], ["unknown", str(store), "unread"], ["read"], ["read", str(store), "missing", "extra"]]:
        status, out, err = captured([PYTHON, "-I", "-S", "-B", PRODUCT] + argv, store, environment(store))
        record("P1", "usage " + repr(argv), status == 2 and not out and err == b"E_USAGE\n")
    oracle(b"2147483647\n", "restricted-scalar-max")
    changed = ROOT / "changed-oracle.json"
    changed.write_bytes(b'{ "a":1}\n')
    status, out, err = captured([JQ, "-S", "-c", ".", str(changed)], ROOT, environment(ROOT), limits=(1024, 4096))
    record("P1", "oracle detects deliberate whitespace difference", status == 0 and not err and out != changed.read_bytes())
    variants = [json.dumps(valid, separators=(",", ":")).encode() + b"\n", canonical(valid).replace(b":", b": ", 1), canonical(valid).replace(b"store.test", b"store\\u002etest"), canonical(valid)[:-1]]
    for number, raw in enumerate(variants):
        path = ROOT / ("oracle-public-difference-%d.json" % number)
        path.write_bytes(raw)
        status, out, err = captured([JQ, "-S", "-c", ".", str(path)], ROOT, environment(ROOT), limits=(8192, 4096))
        record("P1", "jq detects public byte difference %d" % number, status == 0 and not err and out == canonical(valid) and out != raw)
        refused(store, "initialize", valid, "E_INPUT", name="actual noncanonical public request %d" % number, raw=raw)
    return store, initial


def transitions(base, initial):
    states = {}
    states["absent"] = (base, initial)
    for state in ("pending", "failed", "acknowledged"):
        store = copy_store(base, "transition-" + state)
        doc = good(store, "apply-update", update(initial["current_tip"]), "P2", state + " seed pending")
        if state != "pending":
            action = "record-failure" if state == "failed" else "acknowledge"
            doc = good(store, "apply-update", update(doc["current_tip"], 1, action, "state." + state), "P2", state + " seed")
        states[state] = (store, doc)
    allowed = {("absent", "record-delivery"): 1, ("pending", "record-delivery"): 2,
               ("failed", "record-delivery"): 2, ("pending", "record-failure"): 1,
               ("pending", "acknowledge"): 1, ("failed", "acknowledge"): 1}
    for state, (source, previous) in states.items():
        for action in ("record-delivery", "record-failure", "acknowledge"):
            store = copy_store(source, "edge-" + state + "-" + action)
            ordinal = allowed.get((state, action), 1)
            value = update(previous["current_tip"], ordinal, action, "edge.test")
            if (state, action) in allowed:
                doc = good(store, "apply-update", value, "P2", state + " -> " + action)
                entry = doc["ledger"]["body"]["entries"][0]
                expected_state = {"record-delivery": "pending", "record-failure": "failed", "acknowledge": "acknowledged"}[action]
                record("P2", "independent transition result", entry["state"] == expected_state and entry["delivery_count"] == ordinal)
            else:
                refused(store, "apply-update", value, "E_TRANSITION", "P2", state + " rejects " + action)
    store = copy_store(states["pending"][0], "late-ack")
    pending = states["pending"][1]
    second = good(store, "apply-update", update(pending["current_tip"], 2, update_id="second"), "P2", "redelivery")
    refused(store, "apply-update", update(second["current_tip"], 1, "record-failure", "old-failure"), "E_TRANSITION", "P2", "obsolete failure")
    for action, ordinals in (("record-delivery", (0, 1, 2, 4)), ("record-failure", (0, 1, 3)), ("acknowledge", (0, 3))):
        for ordinal in ordinals:
            refused(store, "apply-update", update(second["current_tip"], ordinal, action, "bad-ordinal.%s.%d" % (action, ordinal)), "E_TRANSITION", "P2", action + " rejects ordinal " + str(ordinal))
    ack = good(store, "apply-update", update(second["current_tip"], 1, "acknowledge", "late-ack"), "P2", "late acknowledgement")
    record("P2", "late ack keeps newer count", ack["ledger"]["body"]["entries"][0]["delivery_count"] == 2)
    for ordinal in (0, 2, 3, 1001):
        refused(states["pending"][0], "apply-update", update(pending["current_tip"], ordinal, "acknowledge", "bad.%d" % ordinal), "E_TRANSITION", "P2", "ack ordinal %d" % ordinal)
    store = copy_store(base, "key-fields")
    doc = initial
    variants = [key()]
    for field in ("initiative_id", "workflow_id", "stage_id", "task_class_id"):
        item = key()
        item["stage_key"][field] += ".other"
        variants.append(item)
    variants += [key(request_sha256="b" * 64), key(operation="retry-stage"), key(attempt_number=10)]
    for index, item in enumerate(variants):
        doc = good(store, "apply-update", update(doc["current_tip"], update_id="key.%d" % index, delivery_key=item), "P2", "key field %d" % index)
    record("P2", "all seven key fields distinguish entries", len(doc["ledger"]["body"]["entries"]) == 8)
    for attempt in (0, 11):
        refused(store, "apply-update", update(doc["current_tip"], delivery_key=key(attempt_number=attempt)), "E_INPUT", "P2", "attempt %d" % attempt)
    for date in ("2000-01-01T00:00:01Z", "2000-01-01T00:00:01Z"):
        value = update(doc["current_tip"], update_id="time.%d" % len(doc["ledger"]["body"]["entries"]), delivery_key=key(request_sha256=hashlib.sha256(doc["current_tip"].encode()).hexdigest()))
        value["recorded_at"] = date
        doc = good(store, "apply-update", value, "P2", "nondecreasing time")
    value = update(doc["current_tip"], update_id="backdated", delivery_key=key(request_sha256="c" * 64))
    refused(store, "apply-update", value, "E_TRANSITION", "P2", "backdated time")
    return states


def replay_cases(base, initial, states):
    store = copy_store(base, "replay")
    first_request = update(initial["current_tip"])
    first = good(store, "apply-update", first_request, "P3", "original delivery")
    ack = good(store, "apply-update", update(first["current_tip"], 1, "acknowledge", "ack"), "P3", "acknowledge")
    before = inventory(store)
    replay = good(store, "apply-update", first_request, "P3", "historical update replay")
    record("P3", "historical result and current tip distinct", replay["result_tip"] == first["result_tip"] and replay["current_tip"] == ack["current_tip"] and replay["ledger"] == first["ledger"])
    ack_request = update(first["current_tip"], 1, "acknowledge", "ack")
    ack_replay = good(store, "apply-update", ack_request, "P3", "exact terminal acknowledgment replay")
    record("P3", "terminal acknowledgment receipt stable", ack_replay == ack)
    init_replay = good(store, "initialize", request("initialize"), "P3", "initialize replay after updates")
    record("P3", "init historical result", init_replay["result_tip"] == initial["current_tip"] and init_replay["current_tip"] == ack["current_tip"])
    record("P3", "replays do not write", inventory(store) == before)
    refused(store, "apply-update", dict(first_request, delivery_ordinal=2), "E_CONFLICT", "P3", "same ID different bytes")
    refused(store, "initialize", request("initialize", initialization_id="other"), "E_CONFLICT", "P3", "init identity conflict")
    refused(store, "read", request(store_id="other"), "E_IDENTITY", "P3", "store identity")
    refused(store, "read", request(ledger_id="other"), "E_IDENTITY", "P3", "ledger identity")
    refused(store, "apply-update", update(initial["current_tip"], update_id="stale"), "E_STALE", "P3", "stale unseen update")
    return store, first_request


def git_call(repository, arguments, data=None):
    env = environment(repository)
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_SYSTEM="/dev/null", GIT_CONFIG_GLOBAL="/dev/null",
               GIT_NO_REPLACE_OBJECTS="1", GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0", GIT_ATTR_NOSYSTEM="1")
    if arguments and arguments[0] == "commit-tree":
        env.update(GIT_AUTHOR_NAME="ystack ledger", GIT_COMMITTER_NAME="ystack ledger",
                   GIT_AUTHOR_EMAIL="ledger@invalid", GIT_COMMITTER_EMAIL="ledger@invalid",
                   GIT_AUTHOR_DATE="2000-01-01T00:00:00Z", GIT_COMMITTER_DATE="2000-01-01T00:00:00Z")
    return captured([GIT, "--git-dir=" + str(repository), "-c", "core.hooksPath=/dev/null"] + arguments,
                    repository, env, data, timeout=10, limits=(270336 + 1024, 4096))


def interoperability(store):
    repository = ROOT / "interop"
    shutil.copytree(store / "repository.git", repository)
    tip = (repository / "refs/heads/ledger").read_text().strip()
    for path in sorted((repository / "objects").glob("*/*")):
        object_id = path.parent.name + path.name
        if len(object_id) != 40:
            continue
        raw = zlib.decompress(path.read_bytes())
        kind, content = raw.split(b"\0", 1)
        object_type = kind.split()[0].decode()
        status, out, err = git_call(repository, ["cat-file", object_type, object_id])
        record("P10", "Git raw " + object_id, status == 0 and not err and out == content)
        status, out, err = git_call(repository, ["hash-object", "--stdin", "-t", object_type, "--no-filters"], content)
        record("P10", "Git OID " + object_id, status == 0 and not err and out == (object_id + "\n").encode())
    status, out, err = git_call(repository, ["rev-parse", "refs/heads/ledger"])
    record("P10", "Git exact tip", status == 0 and not err and out == (tip + "\n").encode())
    lock = repository / "refs/heads/ledger.lock"
    lock.write_bytes(b"")
    status, out, err = git_call(repository, ["update-ref", "refs/heads/ledger", tip, tip])
    record("P10", "Git held ref lock refusal", status != 0 and not out)
    lock.unlink()
    status, out, err = git_call(repository, ["update-ref", "refs/heads/ledger", tip, "f" * 40])
    record("P10", "Git wrong old OID refusal", status != 0 and not out)
    reverse_repository = ROOT / "reverse-git"
    (reverse_repository / "objects").mkdir(mode=0o700, parents=True)
    (reverse_repository / "refs/heads").mkdir(mode=0o700, parents=True)
    for name in ("HEAD", "config"):
        shutil.copyfile(repository / name, reverse_repository / name)
    chain = []
    current = tip
    while current:
        _, content = object_read(store, current)
        chain.append((current, content))
        current = next((line.split()[1].decode() for line in content.splitlines() if line.startswith(b"parent ")), None)
    prior = None
    for original, commit in reversed(chain):
        members = commit_members(store, original)
        for name, object_id in members.items():
            _, content = object_read(store, object_id)
            status, out, err = git_call(reverse_repository, ["hash-object", "-w", "--stdin", "--no-filters"], content)
            record("P10", "Git writes fresh " + name, status == 0 and out == (object_id + "\n").encode() and not err)
        tree_input = b"".join(("100644 blob %s\t%s\n" % (members[name], name)).encode() for name in sorted(members))
        status, out, err = git_call(reverse_repository, ["mktree"], tree_input)
        tree = commit.splitlines()[0].split()[1].decode()
        record("P10", "Git independently constructs tree", status == 0 and not err and out == (tree + "\n").encode())
        args = ["commit-tree", tree] + (["-p", prior] if prior else [])
        status, out, err = git_call(reverse_repository, args, b"ystack delivery ledger\n")
        record("P10", "Git exact commit serialization", status == 0 and not err and out == (original + "\n").encode())
        prior = original
    status, out, err = git_call(reverse_repository, ["update-ref", "refs/heads/ledger", tip, "0" * 40])
    record("P10", "Git fresh reverse ref publication", status == 0 and not out and not err)
    reverse = new_store("reverse-application")
    shutil.copytree(reverse_repository, reverse / "repository.git")
    (reverse / "store.lock").write_bytes(b"")
    for path in [reverse] + list(reverse.rglob("*")):
        path.chmod(0o700 if path.is_dir() else 0o600)
    doc = good(reverse, "read", request(), "P10", "real Git-created closure in separate application copy")
    record("P10", "reverse exact tip", doc["current_tip"] == tip)


def planner_cases(base, initial):
    source_root = pathlib.Path(PRODUCT).parents[2]
    source = (source_root / "scripts/test/orchestrator-reconciliation-plan.test.sh").read_text()
    start = source.index('"$jq_bin" -S -c -n \'') + len('"$jq_bin" -S -c -n \'')
    end = source.index("' > \"$bundle\"", start)
    program = ROOT / "planner-fixture.jq"
    program.write_text(source[start:end])
    status, out, err = captured([JQ, "-S", "-c", "-n", "-f", str(program)], ROOT, environment(ROOT), limits=(524288, 4096))
    assert status == 0 and not err
    fixture = json.loads(out)["input"]
    wrapper = (source_root / "scripts/core-contract.sh").read_text()
    import re
    generation = re.search(r"^PORTABLE_CORE_GENERATION='([^']+)'$", wrapper, re.M).group(1)
    modules = source_root / "core/v2/generations" / generation / "modules"
    planner = source_root / "orchestrator/v1/reconciliation-plan.jq"
    def plan(doc, wrong=False, absent=False):
        value = json.loads(json.dumps(fixture))
        value["delivery_ledger"] = doc["ledger"]
        value["delivery_ledger_ref"] = dict(doc["ledger_ref"])
        if wrong:
            value["delivery_ledger_ref"]["sha256"] = "0" * 64
        if absent:
            value["observation"]["body"]["classifications"] = []
        path = ROOT / "planner-input.json"
        path.write_bytes(canonical(value))
        status, out, err = captured([JQ, "-L", str(modules), "-S", "-c", "-f", str(planner), str(path)], ROOT, environment(ROOT), limits=(524288, 4096))
        assert status == 0 and not err, (status, err)
        return json.loads(out)
    first = plan(initial)
    record("P4", "actual empty export first dispatch", len(first["body"]["deliveries"]) == 1)
    store = copy_store(base, "planner-store")
    selected = first["body"]["deliveries"][0]["delivery_key"]
    doc = good(store, "apply-update", update(initial["current_tip"], delivery_key=selected), "P4", "record actual planner delivery")
    for expected in ("pending", "failed", "acknowledged"):
        result = plan(doc)
        count = len(result["body"]["deliveries"])
        record("P4", expected + " export behavior", count == (0 if expected == "acknowledged" else 1))
        record("P4", "genuine exported digest " + expected, digest_bytes(canonical(doc["ledger"])) == doc["ledger_ref"]["sha256"])
        oracle(canonical(doc["ledger"]), "planner-" + expected, "P4")
        if expected == "pending":
            record("P4", "pending redelivery no extra slot", result["body"]["concurrency"]["active_pending"] == 1)
            record("P4", "pending key absent consumes slot", plan(doc, absent=True)["body"]["concurrency"]["active_pending"] == 1)
            record("P4", "planner does not recompute supplied digest", plan(doc, wrong=True) is not None)
            action = "record-failure"
        elif expected == "failed":
            action = "acknowledge"
        else:
            break
        doc = good(store, "apply-update", update(doc["current_tip"], 1, action, "planner." + expected, selected), "P4", "planner transition " + expected)
    bad = copy_store(store, "planner-corrupt")
    rewrite_tip(bad, {"receipt.json": lambda data: canonical(dict(json.loads(data), ledger_sha256="0" * 64))})
    refused(bad, "read", request(), "E_STORE", "P4", "real store rejects false digest")


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def invalid_stores(base, initial):
    mutations = [
        ("config", lambda s: (s / "repository.git/config").write_bytes(b"[core]\n\tbare = true\n")),
        ("head", lambda s: (s / "repository.git/HEAD").write_bytes(b"ref: refs/heads/other\n")),
        ("symbolic", lambda s: (s / "repository.git/refs/heads/ledger").write_bytes(b"ref: refs/heads/other\n")),
        ("packed-refs", lambda s: (s / "repository.git/packed-refs").write_bytes(b"")),
        ("extra-ref", lambda s: (s / "repository.git/refs/heads/extra").write_bytes(b"0" * 40 + b"\n")),
        ("hooks", lambda s: (s / "repository.git/hooks").mkdir(mode=0o700)),
        ("pack", lambda s: (s / "repository.git/objects/pack").mkdir(mode=0o700)),
        ("alternate", lambda s: (s / "repository.git/objects/info").mkdir(mode=0o700)),
        ("unknown", lambda s: (s / "unrelated").write_bytes(b"")),
        ("root-mode", lambda s: s.chmod(0o755)),
        ("metadata-mode", lambda s: (s / "repository.git/config").chmod(0o644)),
    ]
    for name, change in mutations:
        store = copy_store(base, "invalid-" + name)
        change(store)
        refused(store, "read", request(), None, "P5", name)
    for name in ("identity.json", "ledger.json", "receipt.json", "request.json"):
        store = copy_store(base, "invalid-doc-" + name)
        rewrite_tip(store, {name: lambda data: canonical(dict(json.loads(data), extra=True))})
        refused(store, "read", request(), "E_STORE", "P5", "closed document " + name)
    for name, transform in (
        ("receipt.json", lambda data: canonical(dict(json.loads(data), ledger_sha256="0" * 64))),
        ("identity.json", lambda data: canonical(dict(json.loads(data), initialization_id="forged"))),
        ("ledger.json", lambda data: canonical(dict(json.loads(data), id="forged"))),
    ):
        store = copy_store(base, "forged-" + name)
        rewrite_tip(store, {name: transform})
        refused(store, "read", request(), "E_STORE", "P5", "valid-shape forgery " + name)
    wrong_count = copy_store(base, "forged-count")
    good(wrong_count, "apply-update", update(initial["current_tip"]), "P5", "forge-count real seed")
    def corrupt_count(data):
        ledger = json.loads(data)
        ledger["body"]["entries"][0]["delivery_count"] = 2
        return canonical(ledger)
    rewrite_tip(wrong_count, {"ledger.json": corrupt_count})
    refused(wrong_count, "read", request(), "E_STORE", "P5", "valid-shape forged transition")
    for index, fields in enumerate((("schema_version",), ("body", "ledger_contract", "declared_entry_count"),
                                    ("body", "entries", 0, "delivery_count"),
                                    ("body", "entries", 0, "delivery_key", "attempt_number"))):
        store = copy_store(base, "stored-bool-%d" % index)
        if index > 1:
            good(store, "apply-update", update(initial["current_tip"]), "P5", "stored bool real update seed")
        def boolean_field(data):
            document = json.loads(data)
            container = document
            for field in fields[:-1]:
                container = container[field]
            assert type(container[fields[-1]]) is int and container[fields[-1]] in (0, 1)
            container[fields[-1]] = bool(container[fields[-1]])
            return canonical(document)
        rewrite_tip(store, {"ledger.json": boolean_field})
        refused(store, "read", request(), "E_STORE", "P5", "real Git closure boolean integer %d" % index)
        refused(store, "initialize", request("initialize"), "E_STORE", "P5", "boolean history replay %d" % index)
    changes = {
        "tree-mode": lambda data: data.replace(b"100644", b"100755", 1),
        "tree-name": lambda data: data.replace(b"ledger.json", b"Ledger.json", 1),
        "tree-trailing": lambda data: data + b"x",
        "tree-reversed": lambda data: data[::-1],
    }
    for name, change in changes.items():
        store = copy_store(base, "invalid-" + name)
        rewrite_tip(store, tree_change=change)
        refused(store, "read", request(), "E_STORE", "P5", name)
    for name, change in {"author": lambda data: data.replace(b"946684800", b"946684801"),
                         "parent": lambda data: data.replace(b"author ", b"parent " + b"f" * 40 + b"\nauthor ", 1),
                         "message": lambda data: data + b"x"}.items():
        store = copy_store(base, "invalid-commit-" + name)
        rewrite_tip(store, commit_change=change)
        refused(store, "read", request(), "E_STORE", "P5", "commit " + name)
    for index, data in enumerate([b"", b"bad", zlib.compress(b"blob 2\0x"),
                                  zlib.compress(b"blob 01\0x"), zlib.compress(b"tag 1\0x"),
                                  zlib.compress(b"blob 1\0x") + b"tail",
                                  zlib.compress(b"blob 1\0x")[:-1],
                                  zlib.compress(b"blob 1\0x") + zlib.compress(b"blob 1\0x")]):
        store = copy_store(base, "invalid-zlib-%d" % index)
        path = next((store / "repository.git/objects").glob("*/*"))
        path.write_bytes(data)
        refused(store, "read", request(), None, "P5", "zlib/header/OID %d" % index)
    store = copy_store(base, "internal-link")
    path = next((store / "repository.git/objects").glob("*/*"))
    alias = path.parent / "tmp_obj_internal"
    os.link(path, alias)
    good(store, "read", request(), "P5", "internal hardlink membership accepted")
    good(store, "initialize", request("initialize"), "P5", "internal hardlink exact replay")
    os.link(path, ROOT / "external-alias")
    refused(store, "read", request(), "E_STORE", "P5", "external hardlink refused")
    for relative in ("repository.git/config", "repository.git/refs/heads/ledger"):
        store = copy_store(base, "symlink-" + relative.rsplit("/", 1)[-1])
        path = store / relative
        content = path.read_bytes()
        target = ROOT / ("symlink-target-" + path.name)
        target.write_bytes(content)
        path.unlink()
        path.symlink_to(target)
        refused(store, "read", request(), "E_STORE", "P5", "symlink " + relative)
    link = ROOT / "store-link"
    link.symlink_to(base, target_is_directory=True)
    status, out, err = invoke(link, "read", request())
    record("P5", "symlink root refused", status != 0 and not out)
    for kind in ("fifo", "directory", "symlink"):
        path = ROOT / ("input-" + kind)
        if kind == "fifo":
            os.mkfifo(path, 0o600)
        elif kind == "directory":
            path.mkdir(mode=0o700)
        else:
            path.symlink_to(ROOT / "request-nonexistent")
        status, out, err = captured([PYTHON, "-I", "-S", "-B", PRODUCT, "read", str(base), str(path)], base, environment(base))
        record("P5", "nonregular input " + kind, status != 0 and not out)
    hardlinked_input = ROOT / "hardlinked-request.json"
    hardlinked_input.write_bytes(canonical(request()))
    os.link(hardlinked_input, ROOT / "hardlinked-request-alias.json")
    before = inventory(base)
    status, out, err = captured([PYTHON, "-I", "-S", "-B", PRODUCT, "read", str(base), str(hardlinked_input)], base, environment(base))
    record("P5", "actual externally hardlinked request refuses", status != 0 and not out and err == b"E_INPUT\n" and inventory(base) == before)
    checkout = ROOT / "checkout"
    checkout.mkdir(mode=0o700)
    (checkout / ".git").write_bytes(b"gitdir: unrelated\n")
    nested = checkout / "store"
    nested.mkdir(mode=0o700)
    status, out, err = invoke(nested, "initialize", request("initialize"))
    record("P5", "checkout ancestry rejected", status != 0 and not out and not list(nested.iterdir()))


OBSERVER = r'''
import errno
import fcntl
import json
import os
import runpy
import sys

source, root, verb, request, event_arg, release_arg, short_arg, fault, pause_arg = sys.argv[1:]
pause = pause_arg == "1"
event_fd, release_fd = int(event_arg), int(release_arg)
short = int(short_arg)
saved = {name: getattr(os, name) for name in ("open", "write", "close", "mkdir", "rename", "replace")}
flock = fcntl.flock
fds = {}
locked = False
sequence = 0
counts = {}

def owned(path):
    return isinstance(path, str) and (path == root or path.startswith(root + "/"))

def event(operation, path, extra=None):
    global sequence
    sequence += 1
    data = {"sequence": sequence, "operation": operation, "path": path,
            "locked": locked, "extra": extra}
    payload = json.dumps(data, sort_keys=True, separators=(",", ":")).encode() + b"\n"
    if len(payload) > 2048:
        os._exit(90)
    offset = 0
    while offset < len(payload):
        count = saved["write"](event_fd, payload[offset:])
        if not 0 < count <= len(payload) - offset:
            os._exit(92)
        offset += count
    if pause and os.read(release_fd, 1) != b"x":
        os._exit(91)

def trip(operation, when):
    key = operation + ":" + when
    counts[key] = counts.get(key, 0) + 1
    if fault == key + ":" + str(counts[key]):
        raise OSError(errno.EIO, "private fault")

def opened(path, flags, *args, **kwargs):
    write = owned(path) and bool(flags & (os.O_WRONLY | os.O_RDWR))
    if write:
        trip("open", "before")
    fd = saved["open"](path, flags, *args, **kwargs)
    if write:
        state = os.fstat(fd)
        fds[fd] = (path, state.st_dev, state.st_ino)
        event("open", path, {"flags": flags, "fd": fd, "device": state.st_dev, "inode": state.st_ino})
    return fd

def written(fd, data):
    if fd not in fds:
        if fd == 1:
            event("response", root)
        return saved["write"](fd, data)
    trip("write", "before")
    actual = data[:short] if short else data
    count = saved["write"](fd, actual)
    state = os.fstat(fd)
    assert (state.st_dev, state.st_ino) == fds[fd][1:]
    event("write", fds[fd][0], {"count": count, "requested": len(data), "size": os.fstat(fd).st_size})
    trip("write", "after")
    return count

def closed(fd):
    global locked
    identity = fds.pop(fd, None)
    path = identity[0] if identity else None
    if path:
        state = os.fstat(fd)
        assert (state.st_dev, state.st_ino) == identity[1:]
        trip("close", "before")
    result = saved["close"](fd)
    if path:
        if path.endswith("/store.lock"):
            locked = False
        event("close", path)
        trip("close", "after")
    return result

def made(path, *args, **kwargs):
    if owned(path):
        trip("mkdir", "before")
    result = saved["mkdir"](path, *args, **kwargs)
    if owned(path):
        event("mkdir", path)
        trip("mkdir", "after")
    return result

def moved(name, source, destination, *args, **kwargs):
    if owned(source):
        trip(name, "before")
    result = saved[name](source, destination, *args, **kwargs)
    if owned(source):
        event(name, destination, {"source": source})
        trip(name, "after")
    return result

def locking(fd, operation):
    global locked
    result = flock(fd, operation)
    if fd in fds:
        locked = True
        event("flock", fds[fd][0])
    return result

def audit(name, args):
    if name.startswith(("subprocess", "os.exec", "os.spawn", "os.fork", "socket.")):
        raise RuntimeError("unexpected product operation " + name)

os.open = opened
os.write = written
os.close = closed
os.mkdir = made
os.rename = lambda source, destination, *args, **kwargs: moved("rename", source, destination, *args, **kwargs)
os.replace = lambda source, destination, *args, **kwargs: moved("replace", source, destination, *args, **kwargs)
fcntl.flock = locking
sys.addaudithook(audit)
sys.argv = [source, verb, root, request]
runpy.run_path(source, run_name="__main__")
'''
OBSERVER_PATH = ROOT / "observer.py"
OBSERVER_PATH.write_text(OBSERVER)


def physical_counts(store, deadline=None):
    paths = [store]
    for path in store.rglob("*"):
        remaining(deadline)
        paths.append(path)
    objects = 0
    regular = 0
    inflated = 0
    temps = 0
    for path in paths:
        remaining(deadline)
        state = path.lstat()
        if stat.S_ISREG(state.st_mode):
            regular += state.st_size
            if "/objects/" in str(path):
                objects += 1
                if path.name.startswith("tmp_obj_"):
                    temps += 1
                    inflated += 270336
                else:
                    inflated += len(zlib.decompress(path.read_bytes()))
    return [objects, len(paths), regular, inflated, temps]


def observed(store, verb, value, name, kill_at=None, short=0, fault="", busy=False, interfere=None, pause=True):
    assert pause or (kill_at is None and not busy and interfere is None)
    deadline = min(START + 1800, time.monotonic() + 120)
    remaining(deadline)
    path = ROOT / (name + ".request.json")
    path.write_bytes(canonical(value))
    descriptors = []
    children = []
    selector = None
    rows = []
    result = [bytearray(), bytearray(), bytearray()]
    killed = False
    status = None
    try:
        event_r, event_w = os.pipe()
        descriptors.extend((event_r, event_w))
        release_r, release_w = os.pipe()
        descriptors.extend((release_r, release_w))
        argv = [PYTHON, "-I", "-S", "-B", str(OBSERVER_PATH), PRODUCT, str(store), verb,
                str(path), str(event_w), str(release_r), str(short), fault, "1" if pause else "0"]
        child = subprocess.Popen(argv, cwd=store, env=environment(store), stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 pass_fds=(event_w, release_r))
        children.append(child)
        close_fd(descriptors, event_w)
        close_fd(descriptors, release_r)
        selector = selectors.DefaultSelector()
        for fd, index in ((child.stdout.fileno(), 0), (child.stderr.fileno(), 1), (event_r, 2)):
            os.set_blocking(fd, False)
            selector.register(fd, selectors.EVENT_READ, index)
        last_event = time.monotonic()
        while selector.get_map():
            event_deadline = min(deadline, last_event + 30)
            for selected, _ in selector.select(min(0.05, remaining(event_deadline))):
                index = selected.data
                cap = (524288, 64, 2048)[index]
                size = cap - len(result[index]) + (0 if index == 2 else 1)
                assert size > 0, "observation record exceeds bound"
                data = os.read(selected.fd, min(65536, size))
                if not data:
                    assert index != 2 or not result[2], "incomplete observation at EOF"
                    selector.unregister(selected.fd)
                    continue
                result[index].extend(data)
                assert len(result[index]) <= cap, "observed output cap"
                if index != 2:
                    continue
                while b"\n" in result[2]:
                    line, _, rest = result[2].partition(b"\n")
                    result[2] = bytearray(rest)
                    item = json.loads(line)
                    assert item["sequence"] == len(rows) + 1
                    last_event = time.monotonic()
                    event_deadline = min(deadline, last_event + 30)
                    item["inventory"] = physical_counts(store, event_deadline) if pause else None
                    rows.append(item)
                    if interfere:
                        interfere(item, event_deadline)
                        remaining(event_deadline)
                    if busy and item["locked"]:
                        code, out, err = invoke(store, "read", request(), deadline=event_deadline)
                        assert code != 0 and not out and err == b"E_BUSY\n", (item, code, err)
                    if kill_at is not None and item["sequence"] == kill_at:
                        assert child.poll() is None
                        child.kill()
                        child.wait(timeout=min(1, remaining(event_deadline)))
                        killed = True
                    elif pause:
                        remaining(event_deadline)
                        assert os.write(release_w, b"x") == 1
                assert len(result[2]) < 2048, "unterminated observation exceeds bound"
        status = child.wait(timeout=remaining(deadline))
    finally:
        try:
            cleanup(children, descriptors, selector)
        finally:
            (ROOT / (name + ".events.json")).write_text(json.dumps(rows, indent=2) + "\n")
            print("ledger actual observation:", json.dumps({"name": name, "status": status,
                  "returncode": children[0].returncode if children else None,
                  "events": rows}, sort_keys=True), flush=True)
    if kill_at is not None:
        assert killed, "requested kill boundary absent"
    return status, bytes(result[0]), bytes(result[1]), rows


def crash_cases(base, initial):
    direct = copy_store(base, "crash-direct")
    value = update(initial["current_tip"])
    expected = good(direct, "apply-update", value, "P8", "ordinary control")
    unpaused = copy_store(base, "crash-unpaused")
    status, out, err, _ = observed(unpaused, "apply-update", value, "crash-unpaused", pause=False)
    record("P8", "no-pause instrumented update equivalence", status == 0 and not err and json.loads(out) == expected and inventory(unpaused) == inventory(direct))
    control = copy_store(base, "crash-instrumented")
    status, out, err, rows = observed(control, "apply-update", value, "control", busy=True)
    record("P8", "instrumented unchanged-main equivalence", status == 0 and not err and json.loads(out) == expected and inventory(control) == inventory(direct))
    record("P9", "all actual mutation classes captured", {row["operation"] for row in rows} >= {"open", "write", "close", "rename", "replace", "flock", "response"})
    start = physical_counts(base)
    for row in rows:
        counts = row["inventory"]
        record("P9", "real peak sequence %d" % row["sequence"], counts[0] <= 8192 and counts[1] <= 16384 and counts[2] <= 128 * 1024 * 1024 and counts[3] <= 128 * 1024 * 1024 and counts[4] <= 1 and all(counts[i] - start[i] <= (8, 32, 1048576, 1048576)[i] for i in range(4)))
    kill_rows = [row for row in rows if row["locked"] and row["operation"] != "flock"]
    for row in kill_rows:
        store = copy_store(base, "kill-%d" % row["sequence"])
        status, out, err, actual = observed(store, "apply-update", value, "kill-%d" % row["sequence"], kill_at=row["sequence"])
        record("P8", "SIGKILL actual boundary %d" % row["sequence"], status == -signal.SIGKILL and not out)
        read = good(store, "read", request(), "P8", "fresh reopen after %d" % row["sequence"])
        published = any(item["operation"] == "replace" for item in actual)
        record("P8", "exact old/new view", read["current_tip"] == (expected["current_tip"] if published else initial["current_tip"]))
        if published:
            replay = good(store, "apply-update", value, "P8", "lost response replay")
            record("P8", "lost response exact result", replay == expected)
        else:
            good(store, "initialize", request("initialize"), "P8", "old initialization replay survives residue")
    partial = copy_store(base, "short-control")
    status, out, err, short_rows = observed(partial, "apply-update", value, "short-control", short=7)
    record("P8", "actual short writes released to completion", status == 0 and not err and json.loads(out) == expected)
    targets = [row for row in short_rows if row["operation"] == "write" and
               ((row["path"].endswith("ledger.lock") and row["extra"]["size"] < 41) or
                ("tmp_obj_" in row["path"] and row["extra"]["count"] < row["extra"]["requested"]))]
    for index, target in enumerate([targets[0], next(row for row in targets if row["path"].endswith("ledger.lock"))]):
        store = copy_store(base, "partial-%d" % index)
        status, out, err, actual = observed(store, "apply-update", value, "partial-%d" % index, kill_at=target["sequence"], short=7)
        record("P8", "kill actual partial write %d" % index, status == -signal.SIGKILL and not out)
        read = good(store, "read", request(), "P8", "partial write old view")
        record("P8", "partial never published", read["current_tip"] == initial["current_tip"])
    for index, fault in enumerate(["open:before:2", "write:before:1", "write:after:1", "close:before:1", "close:after:1", "rename:before:1", "rename:after:1", "replace:before:1", "replace:after:1"]):
        store = copy_store(base, "fault-%d" % index)
        status, out, err, actual = observed(store, "apply-update", value, "fault-%d" % index, fault=fault)
        record("P8", "explicit fault " + fault, status != 0 and not out and err == b"E_IO\n")
        read = good(store, "read", request(), "P8", "fault fresh reopen")
        published = any(row["operation"] == "replace" for row in actual)
        record("P8", "fault old/new closure", read["current_tip"] == (expected["current_tip"] if published else initial["current_tip"]))
    initial_unpaused = new_store("init-unpaused")
    status, out, err, _ = observed(initial_unpaused, "initialize", request("initialize"), "init-unpaused", pause=False)
    record("P8", "no-pause instrumented initialization equivalence", status == 0 and not err and json.loads(out) == initial and inventory(initial_unpaused) == inventory(base))
    initialized = new_store("init-control")
    status, out, err, init_rows = observed(initialized, "initialize", request("initialize"), "init-control")
    record("P8", "actual initialization control", status == 0 and not err)
    for row in init_rows:
        if row["operation"] not in ("mkdir", "write", "replace", "response"):
            continue
        store = new_store("init-kill-%d" % row["sequence"])
        status, out, err, actual = observed(store, "initialize", request("initialize"), "init-kill-%d" % row["sequence"], kill_at=row["sequence"])
        record("P8", "init killed at %d" % row["sequence"], status == -signal.SIGKILL)
        if any(item["operation"] == "replace" for item in actual):
            good(store, "initialize", request("initialize"), "P8", "lost init reply replay")
        else:
            refused(store, "read", request(), "E_INCOMPLETE", "P8", "partial initialization is not recovered")


def concurrency_cases(base, initial):
    store = copy_store(base, "concurrent")
    tips = [good(store, "read", request(), "P7", "independent reader %d" % i)["current_tip"] for i in range(2)]
    record("P7", "readers captured identical tip", tips == [initial["current_tip"]] * 2)
    worker = ROOT / "writer-worker.py"
    worker.write_text('''import os,sys
fd=int(sys.argv[1])
assert os.read(fd,1)==b"g"
os.close(fd)
os.execve(sys.argv[2],sys.argv[2:],dict(os.environ))
''')
    children = []
    controls = []
    values = []
    selector = None
    deadline = min(START + 1800, time.monotonic() + 120)
    remaining(deadline)
    try:
        for i in range(2):
            value = update(tips[i], update_id="concurrent.%d" % i)
            path = ROOT / ("concurrent-%d.json" % i)
            path.write_bytes(canonical(value))
            values.append(value)
            remaining(deadline)
            read_fd, write_fd = os.pipe()
            controls.extend((read_fd, write_fd))
            children.append(subprocess.Popen([PYTHON, "-I", "-S", "-B", str(worker), str(read_fd),
                                             PYTHON, "-I", "-S", "-B", PRODUCT, "apply-update", str(store), str(path)],
                                            cwd=store, env=environment(store), pass_fds=(read_fd,),
                                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE))
            close_fd(controls, read_fd)
        while controls:
            fd = controls[-1]
            remaining(deadline)
            assert os.write(fd, b"g") == 1
            close_fd(controls, fd)
        buffers = [[bytearray(), bytearray()] for _ in children]
        selector = selectors.DefaultSelector()
        for index, child in enumerate(children):
            for stream_index, stream in enumerate((child.stdout, child.stderr)):
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, (index, stream_index))
        while selector.get_map():
            for selected, _ in selector.select(min(0.05, remaining(deadline))):
                index, stream_index = selected.data
                buffer = buffers[index][stream_index]
                cap = 524288 if stream_index == 0 else 64
                data = os.read(selected.fd, min(65536, cap + 1 - len(buffer)))
                if not data:
                    selector.unregister(selected.fileobj)
                else:
                    buffer.extend(data)
                    assert len(buffer) <= cap, "concurrent output cap"
        results = [(child.wait(timeout=remaining(deadline)), bytes(buffers[index][0]), bytes(buffers[index][1])) for index, child in enumerate(children)]
        winners = [i for i, item in enumerate(results) if item[0] == 0]
        record("P7", "exactly one public publisher", len(winners) == 1)
        loser = 1 - winners[0]
        record("P7", "loser busy or stale", results[loser][2] in (b"E_BUSY\n", b"E_STALE\n") and not results[loser][1])
        refused(store, "apply-update", values[loser], "E_STALE", "P7", "deliberate stale retry")
    finally:
        cleanup(children, controls, selector)
    competing = copy_store(base, "cas-competing")
    other = good(competing, "apply-update", update(initial["current_tip"], update_id="competing"), "P7")
    target = copy_store(base, "cas-target")
    changed = []
    def interfere(row, deadline):
        remaining(deadline)
        if row["operation"] == "open" and row["path"].endswith("/refs/heads/ledger.lock") and not changed:
            for path in (competing / "repository.git/objects").rglob("*"):
                remaining(deadline)
                dest = target / path.relative_to(competing)
                if path.is_dir():
                    dest.mkdir(mode=0o700, exist_ok=True)
                elif not dest.exists():
                    shutil.copyfile(path, dest)
                    os.chmod(dest, 0o600)
            remaining(deadline)
            shutil.copyfile(competing / "repository.git/refs/heads/ledger", target / "repository.git/refs/heads/ledger")
            remaining(deadline)
            changed.append(True)
    status, out, err, rows = observed(target, "apply-update", update(initial["current_tip"]), "cas-real", interfere=interfere)
    record("P7", "actual reread detects valid competing ref", changed and status != 0 and not out and err == b"E_STALE\n")
    actual = good(target, "read", request(), "P7", "competing closure remains readable")
    record("P7", "CAS leaves competing tip", actual["current_tip"] == other["current_tip"])


def history_cases(base, initial):
    store = copy_store(base, "long-history")
    current = initial
    checkpoints = {}
    originals = {}
    for count in range(1, 1001):
        value = update(current["current_tip"], count, update_id="sequence.%04d" % count)
        current = good(store, "apply-update", value, "P2", "actual delivery count %d" % count)
        entry = current["ledger"]["body"]["entries"][0]
        record("P2", "independent count %d" % count, entry["delivery_count"] == count and entry["state"] == "pending")
        if count in (1, 999, 1000):
            checkpoints[count] = copy_store(store, "checkpoint-%d" % count)
            originals[count] = (value, current)
            good(checkpoints[count], "read", request(), "P3", "reopen actual checkpoint %d" % count)
    refused(store, "apply-update", update(current["current_tip"], 1001, update_id="sequence.1001"), "E_TRANSITION", "P2", "count 1001 refuses")
    for action in ("record-failure", "acknowledge"):
        branch = copy_store(checkpoints[1000], "count1000-" + action)
        result = good(branch, "apply-update", update(current["current_tip"], 1000, action, "count1000." + action), "P2")
        record("P2", "count1000 preserves count", result["ledger"]["body"]["entries"][0]["delivery_count"] == 1000)
    for number in range(1001, 1025):
        other_key = key(request_sha256=("%064x" % number))
        current = good(store, "apply-update", update(current["current_tip"], 1, update_id="sequence.%04d" % number, delivery_key=other_key), "P3", "actual history update %d" % number)
    refused(store, "apply-update", update(current["current_tip"], 1, update_id="sequence.1025", delivery_key=key(request_sha256="f" * 64)), "E_LIMIT", "P3", "history 1025 refuses")
    replay = good(store, "apply-update", originals[1][0], "P3", "replay before exhausted history")
    record("P3", "historical ledger and receipt retained", replay["ledger"] == originals[1][1]["ledger"] and replay["receipt"] == originals[1][1]["receipt"] and replay["result_tip"] == originals[1][1]["result_tip"] and replay["current_tip"] == current["current_tip"])
    overlong = copy_store(store, "overlong-history")
    value = update(current["current_tip"], 1, update_id="independent.1025", delivery_key=key(request_sha256="e" * 64))
    ledger = json.loads(json.dumps(current["ledger"]))
    ledger["body"]["entries"].append({"delivery_key": value["delivery_key"], "state": "pending", "delivery_count": 1, "last_delivery_at": TIME})
    ledger["body"]["entries"].sort(key=lambda entry: tuple(entry["delivery_key"]["stage_key"][field] for field in ("initiative_id", "workflow_id", "stage_id", "task_class_id")) + (entry["delivery_key"]["request_sha256"], entry["delivery_key"]["operation"], entry["delivery_key"]["attempt_number"]))
    ledger["body"]["ledger_contract"]["declared_entry_count"] = len(ledger["body"]["entries"])
    members = commit_members(store, current["current_tip"])
    _, raw_receipt = object_read(store, members["receipt.json"])
    receipt = json.loads(raw_receipt)
    receipt["request_id"] = value["update_id"]
    receipt["request_sha256"] = hashlib.sha256(canonical(value)).hexdigest()
    receipt["ledger_sha256"] = hashlib.sha256(canonical(ledger)).hexdigest()
    for name, body in (("request.json", value), ("ledger.json", ledger), ("receipt.json", receipt)):
        members[name] = object_put(overlong, "blob", canonical(body))[0]
    tree = object_put(overlong, "tree", b"".join(b"100644 " + name.encode() + b"\0" + bytes.fromhex(members[name]) for name in sorted(members)))[0]
    _, prior_commit = object_read(store, current["current_tip"])
    suffix = prior_commit[prior_commit.index(b"author "):]
    next_commit = b"tree " + tree.encode() + b"\nparent " + current["current_tip"].encode() + b"\n" + suffix
    invalid_tip = object_put(overlong, "commit", next_commit)[0]
    (overlong / "repository.git/refs/heads/ledger").write_text(invalid_tip + "\n")
    refused(overlong, "read", request(), "E_STORE", "P5", "actual 1025-update chain rejected")
    entries = copy_store(base, "entries128")
    result = initial
    for number in range(128):
        value = update(result["current_tip"], update_id="entry.%03d" % number, delivery_key=key(request_sha256="%064x" % number))
        result = good(entries, "apply-update", value, "P2", "entry count %d" % (number + 1))
    record("P2", "128 complete distinct entries", len(result["ledger"]["body"]["entries"]) == 128)
    refused(entries, "apply-update", update(result["current_tip"], update_id="entry.129", delivery_key=key(request_sha256="f" * 64)), "E_TRANSITION", "P2", "entry129 refuses")
    result = good(entries, "apply-update", update(result["current_tip"], 2, update_id="entry.existing", delivery_key=key(request_sha256="%064x" % 0)), "P2", "existing key updates at128")
    oracle(canonical(result), "maximum-actual-entry-snapshot", "P2")
    return entries, result


def resource_cases(base, initial):
    cap = 128 * 1024 * 1024
    threshold = cap - 1048576
    for label, compressible in (("inflated", True), ("physical", False)):
        store = copy_store(base, "capacity-" + label)
        totals = physical_counts(store)
        for number in range(8192):
            index = 3 if compressible else 2
            if totals[index] > threshold:
                break
            needed = threshold + 1 - totals[index]
            length = min(270304, max(64, needed - (13 if compressible else 40)))
            content = (("%016x" % number).encode() + b"x" * (length - 16)) if compressible else os.urandom(length)
            object_put(store, "blob", content)
            totals = physical_counts(store)
        else:
            raise AssertionError("bounded capacity fixture did not reach threshold")
        record("P6", label + " independent reserve separation", totals[index] > threshold and totals[5 - index] <= threshold and max(totals[2:4]) <= cap and totals[0] + 8 <= 8192)
        good(store, "read", request(), "P6", label + " otherwise valid full read")
        good(store, "initialize", request("initialize"), "P6", label + " replay before capacity")
        refused(store, "apply-update", update(initial["current_tip"]), "E_LIMIT", "P6", label + " reserve admission")
    partial = copy_store(base, "capacity-partial-temps")
    fanout = partial / "repository.git/objects/00"
    fanout.mkdir(mode=0o700, exist_ok=True)
    for number in range(493):
        remaining()
        (fanout / ("tmp_obj_retained_%03d" % number)).write_bytes(b"")
    totals = physical_counts(partial)
    record("P6", "empty partial temps charged full inflated size", totals[4] == 493 and totals[3] > threshold and totals[2] < 1048576)
    good(partial, "read", request(), "P6", "partial residue otherwise valid")
    refused(partial, "apply-update", update(initial["current_tip"]), "E_LIMIT", "P6", "partial temps consume real reserve")
    store = copy_store(base, "capacity-objects")
    count = physical_counts(store)[0]
    for number in range(8192):
        if count >= 8184:
            break
        object_put(store, "blob", ("capacity-object-%08d" % number).encode())
        count = physical_counts(store)[0] if number % 512 == 511 else count + 1
    record("P6", "8184 real object boundary", physical_counts(store)[0] == 8184)
    admitted = copy_store(store, "capacity-objects-admit")
    good(admitted, "apply-update", update(initial["current_tip"]), "P6", "8184 admission succeeds")
    object_put(store, "blob", b"one-more-object")
    record("P6", "8185 real objects", physical_counts(store)[0] == 8185)
    good(store, "read", request(), "P6", "object constrained valid read")
    refused(store, "apply-update", update(initial["current_tip"]), "E_LIMIT", "P6", "8185 reserve refuses")
    for number in range(7):
        object_put(store, "blob", ("cap-final-%d" % number).encode())
    root = store / "repository.git/objects"
    for number in range(256):
        remaining()
        (root / ("%02x" % number)).mkdir(mode=0o700, exist_ok=True)
    totals = physical_counts(store)
    record("P6", "valid high-entry closed layout", totals[0] == 8192 and len(list(root.iterdir())) == 256 and totals[1] == 5 + 4 + 256 + 8192)
    good(store, "read", request(), "P6", "actual highest object count reads")
    object_put(store, "blob", b"over-object-cap")
    refused(store, "read", request(), "E_LIMIT", "P6", "8193 actual objects refuse")


def private_boundaries(base, initial):
    descriptor = importlib.util.spec_from_file_location("private_ledger_boundaries", PRODUCT)
    module = importlib.util.module_from_spec(descriptor)
    descriptor.loader.exec_module(module)
    def accept(name, operation):
        operation()
        record("P6", "private defensive " + name, True)
    def reject(name, operation):
        try:
            operation()
        except module.Refusal:
            record("P6", "private defensive " + name, True)
        else:
            raise AssertionError("private boundary did not refuse: " + name)
    obj = module.Store(str(base))
    for entries in (16384, 16385):
        obj.totals = [0, entries, 0, 0]
        (accept if entries == 16384 else reject)("entry counter %d" % entries, obj.check_totals)
    for entries in (16352, 16353):
        obj.totals = [0, entries, 0, 0]
        (accept if entries == 16352 else reject)("entry reservation %d" % entries, obj.reserve)
    for limit in (8192, 262144, 524288):
        data = b'"' + b'a' * (limit - 3) + b'"\n'
        accept("synthetic JSON byte cap %d" % limit, lambda: module.parse(data, limit))
        reject("synthetic JSON byte cap plus one %d" % limit, lambda: module.parse(data + b"\n", limit))
    for value in (0, 2147483647):
        oracle(canonical(value), "private-scalar-%d" % value, "P6")
        accept("integer %d" % value, lambda: module.parse(canonical(value), 8192))
    reject("integer upper overflow", lambda: module.parse(b"2147483648\n", 8192))
    accept("content270304", lambda: module.encode_object("blob", b"x" * 270304))
    reject("content270305", lambda: module.encode_object("blob", b"x" * 270305))
    real_write = module.os.write
    for outcome in ("zero", "oversized", "interrupted"):
        path = ROOT / ("private-write-" + outcome)
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        attempts = []
        def controlled_write(descriptor, data):
            attempts.append(len(data))
            if outcome == "zero":
                return 0
            if outcome == "oversized":
                return len(data) + 1
            if len(attempts) == 1:
                raise InterruptedError()
            return real_write(descriptor, data)
        refused_write = False
        try:
            module.os.write = controlled_write
            try:
                obj.write_all(fd, b"actual-write")
            except module.Refusal:
                refused_write = True
        finally:
            module.os.write = real_write
            os.close(fd)
        record("P8", "private write result " + outcome, (not refused_write and path.read_bytes() == b"actual-write" and len(attempts) == 2) if outcome == "interrupted" else (refused_write and path.read_bytes() == b"" and len(attempts) == 1))
    path = ROOT / "private-new-state-linked"
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.link(path, ROOT / "private-new-state-alias")
    try:
        reject("new state link count", lambda: obj.write_all(fd, b"private-component"))
    finally:
        os.close(fd)
    original_compressor = module.zlib.compressobj
    class OversizedCompressor:
        def compress(self, data):
            return b"x" * (len(data) + 2048)
        def flush(self):
            return b""
    try:
        module.zlib.compressobj = OversizedCompressor
        reject("compressed output cap before file creation", lambda: module.encode_object("blob", b"x" * 64))
    finally:
        module.zlib.compressobj = original_compressor
    oversized = copy_store(base, "oversized-directory")
    for number in range(16385):
        remaining()
        (oversized / ("unknown%05d" % number)).mkdir(mode=0o700)
    refused(oversized, "read", request(), None, "P6", "actual oversized directory")
    for label, raw in (("content-over", b"blob 270305\0" + b"x" * 270305),
                       ("raw-over", b"blob 270400\0" + b"x" * 270400),
                       ("header32", b"blob " + b"0" * 27 + b"\0x"),
                       ("length-mismatch", b"blob 2\0x")):
        store = copy_store(base, "raw-" + label)
        object_id = hashlib.sha1(raw).hexdigest()
        directory = store / "repository.git/objects" / object_id[:2]
        directory.mkdir(mode=0o700, exist_ok=True)
        (directory / object_id[2:]).write_bytes(zlib.compress(raw))
        refused(store, "read", request(), None, "P5", "actual " + label)
    store = copy_store(base, "maximum-valid-object")
    object_id, _, raw_length = object_put(store, "blob", b"x" * 270304)
    record("P6", "real maximum content raw framing", raw_length == 270316)
    good(store, "read", request(), "P6", "maximum valid unreachable content")
    interop = ROOT / "interop-max-content"
    shutil.copytree(store / "repository.git", interop)
    status, out, err = git_call(interop, ["cat-file", "blob", object_id])
    record("P10", "Git maximum content independent oracle", status == 0 and not err and out == b"x" * 270304)
    class SyntheticCycle(module.Store):
        def inventory(self):
            return set(module.DIRECTORIES) | set(module.FIXED_FILES)
        def current_ref(self, absent=False):
            return "1" * 40
        def load_object(self, object_id, kind, cap):
            return module.commit_bytes("2" * 40, "1" * 40)
    reject("synthetic cycle traversal", lambda: SyntheticCycle(str(base)).validate())
    fake = list(os.lstat(base / "repository.git/config"))
    fake[4] = os.getuid() + 1
    reject("synthetic nonprivileged wrong owner", lambda: module.file_state(os.stat_result(fake)))
    for label, target in (("object", "repository.git/objects/" + object_id[:2] + "/" + object_id[2:]),):
        invalid = copy_store(store, "symlink-" + label)
        path = invalid / target
        path.unlink()
        path.symlink_to(store / target)
        refused(invalid, "read", request(), None, "P5", label + " symlink")
    record("P5", "device input rejected", captured([PYTHON, "-I", "-S", "-B", PRODUCT, "read", str(base), "/dev/null"], base, environment(base))[0] != 0)


def tool_identity(path):
    current = pathlib.Path(path)
    links = []
    for _ in range(16):
        if not current.is_symlink():
            break
        target = os.readlink(current)
        links.append({"path": str(current), "target": target})
        current = pathlib.Path(target) if target.startswith("/") else current.parent / target
    else:
        raise AssertionError("tool symlink depth")
    terminal = current.resolve(strict=True)
    state = terminal.stat()
    assert stat.S_ISREG(state.st_mode)
    return {"requested": path, "links": links, "terminal": str(terminal), "sha256": hashlib.sha256(terminal.read_bytes()).hexdigest()}


def observation_metadata(path, content=False):
    state = path.lstat()
    result = {"device": state.st_dev, "inode": state.st_ino,
              "mode": state.st_mode, "uid": state.st_uid, "gid": state.st_gid,
              "nlink": state.st_nlink, "size": state.st_size,
              "mtime_ns": state.st_mtime_ns, "ctime_ns": state.st_ctime_ns}
    if stat.S_ISLNK(state.st_mode):
        result["link_target"] = os.readlink(path)
    elif content and stat.S_ISREG(state.st_mode):
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            while True:
                block = stream.read(65536)
                if not block:
                    break
                digest.update(block)
        result["sha256"] = digest.hexdigest()
        after = path.lstat()
        assert (state.st_dev, state.st_ino, state.st_size, state.st_mtime_ns, state.st_ctime_ns) == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns), "file changed during observation"
    return result


def startup_inventory(roots):
    result = {}
    for root in roots:
        pending = [root]
        while pending:
            path = pending.pop()
            key = str(path)
            if key in result:
                continue
            result[key] = observation_metadata(path, content=True)
            if stat.S_ISDIR(result[key]["mode"]):
                with os.scandir(path) as entries:
                    pending.extend(pathlib.Path(entry.path) for entry in entries)
            if len(result) + len(pending) > 200000:
                raise AssertionError("startup observation inventory cap")
    return result


def ambient_inventory(root):
    result = {str(root): observation_metadata(root)}
    with os.scandir(root) as entries:
        for entry in entries:
            path = pathlib.Path(entry.path)
            result[str(path)] = observation_metadata(path)
            if len(result) > 200000:
                raise AssertionError("ambient observation inventory cap")
    return result


def direct_isolation(base, initial):
    store = new_store("isolated-direct-measurement")
    source = pathlib.Path(PRODUCT).parents[2]
    temporary = pathlib.Path(os.environ.get("TMPDIR", "/tmp")).resolve()
    roots = [source, ROOT]
    runtime_destinations = [store, source, ROOT]
    inputs = []
    original = update(initial["current_tip"])
    for number, (verb, value) in enumerate([("initialize", request("initialize")), ("read", request()), ("apply-update", original), ("read", request()), ("apply-update", original), ("apply-update", update(initial["current_tip"], update_id="isolation.stale"))]):
        path = ROOT / ("isolation-request-%d.json" % number)
        path.write_bytes(canonical(value))
        inputs.append((verb, path))
    tool_before = {name: tool_identity(path) for name, path in (("python", PYTHON), ("Git", GIT), ("jq", JQ))}
    if sys.platform == "darwin":
        framework = pathlib.Path(PYTHON).parents[4] / "Python3"
        tool_before["framework"] = tool_identity(str(framework))
    origins = json.loads((ROOT / "provenance.json").read_bytes())["origins"]
    before = startup_inventory(roots)
    ambient_before = ambient_inventory(temporary)
    executable = hashlib.sha256(pathlib.Path(PYTHON).read_bytes()).hexdigest()
    product = hashlib.sha256(pathlib.Path(PRODUCT).read_bytes()).hexdigest()
    records = []
    for number, (verb, path) in enumerate(inputs):
        argv = [PYTHON, "-I", "-S", "-B", PRODUCT, verb, str(store), str(path)]
        start = time.monotonic()
        status, out, err = captured(argv, store, environment(store))
        records.append({"argv": argv, "environment": environment(store), "cwd": str(store), "stdin": "/dev/null", "elapsed_seconds": time.monotonic() - start, "status": status, "stdout_sha256": hashlib.sha256(out).hexdigest(), "stderr": err.decode("ascii")})
        record("P11", "actual isolated batch %d" % number, (status == 0 and not err and canonical(json.loads(out)) == out) if number < 5 else (status != 0 and not out and err == b"E_STALE\n"))
    after = startup_inventory(roots)
    ambient_after = ambient_inventory(temporary)
    changes = [path for path in before.keys() | after.keys() if before.get(path) != after.get(path)]
    unrelated = [path for path in changes if path != str(store) and not path.startswith(str(store) + "/")]
    ambient_changes = sorted(path for path in ambient_before.keys() | ambient_after.keys() if ambient_before.get(path) != ambient_after.get(path))
    unobserved_subtrees = sorted(path for path, metadata in ambient_after.items() if path != str(temporary) and stat.S_ISDIR(metadata["mode"]) and not any(path == str(root) or path.startswith(str(root) + "/") for root in roots))
    print("ledger complete startup before:", json.dumps(before, sort_keys=True), flush=True)
    print("ledger complete startup after:", json.dumps(after, sort_keys=True), flush=True)
    print("ledger ambient startup before:", json.dumps(ambient_before, sort_keys=True), flush=True)
    print("ledger ambient startup after:", json.dumps(ambient_after, sort_keys=True), flush=True)
    report = {"complete_roots": [str(root) for root in roots], "application_store": str(store),
              "request_files": [str(path) for _, path in inputs], "target_fixtures": [],
              "runtime_write_destinations_observed_recursively": [str(path) for path in runtime_destinations],
              "ambient_root": str(temporary), "ambient_depth": 1,
              "ambient_subtrees_not_observed_recursively": unobserved_subtrees,
              "ambient_symlinks_not_followed": sorted(path for path, metadata in ambient_after.items() if stat.S_ISLNK(metadata["mode"])),
              "boundary_basis": "Fixed isolated no-site no-bytecode Python; empty-start environment; cwd and TMPDIR are the store; closed source writes only the store. Source and all test/request paths are also observed completely. No additional native output destination has been identified for the selected imports. Foreign OS/application subtree contents are not observed and are not claimed unchanged or unwritable.",
              "snapshot_limits": "Metadata and complete-root regular content hashes compare endpoints; they do not prove absence of every transient native write or global host writes. P8/P9 actual held-operation proof is separate.",
              "changed_application_paths": sorted(changes), "unexpected_application_paths": sorted(unrelated),
              "changed_ambient_entries": ambient_changes,
              "source_sha256": product, "executable_sha256": executable, "calls": records}
    print("ledger direct startup observation:", json.dumps(report, sort_keys=True), flush=True)
    record("P11", "complete application roots unchanged outside store", not unrelated)
    record("P11", "ambient depth-one entries and metadata stable", not ambient_changes)
    record("P11", "identified tools and loaded origins stable", all(tool_identity(item["requested"]) == item for item in tool_before.values()) and all(hashlib.sha256(pathlib.Path(item["path"]).read_bytes()).hexdigest() == item["sha256"] for item in origins.values()))
    print("ledger actual tool identities:", json.dumps(tool_before, sort_keys=True), flush=True)
    record("P11", "direct executable and source stable", hashlib.sha256(pathlib.Path(PYTHON).read_bytes()).hexdigest() == executable and hashlib.sha256(pathlib.Path(PRODUCT).read_bytes()).hexdigest() == product)


def startup_cases(base, initial):
    import ast
    tree = ast.parse(pathlib.Path(PRODUCT).read_bytes())
    imports = {alias.name for node in ast.walk(tree) if isinstance(node, ast.Import) for alias in node.names}
    record("P11", "closed source imports", imports == {"errno", "fcntl", "hashlib", "json", "os", "re", "stat", "sys", "zlib"} and not any(isinstance(node, ast.ImportFrom) for node in ast.walk(tree)))
    calls = sorted({node.func.attr for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name) and node.func.value.id == "os"})
    forbidden = {"system", "fork", "execve", "spawnv", "unlink", "remove", "chmod", "link", "symlink", "chdir", "fsync"}
    record("P9", "complete source OS primitive inventory", not forbidden.intersection(calls))
    print("ledger source OS calls:", json.dumps(calls), flush=True)
    poison = {"PYTHONPATH": "/does-not-exist", "PYTHONHOME": "/does-not-exist", "DYLD_INSERT_LIBRARIES": "/does-not-exist", "LD_PRELOAD": "/does-not-exist", "GIT_CONFIG_SYSTEM": "/does-not-exist", "PATH": "/does-not-exist"}
    old = {name: os.environ.get(name) for name in poison}
    try:
        os.environ.update(poison)
        store = new_store("startup-public")
        init = good(store, "initialize", request("initialize"), "P11", "fresh exact empty-start initialize")
        good(store, "read", request(), "P11", "reused exact public read")
        value = update(init["current_tip"])
        good(store, "apply-update", value, "P11", "reused exact public update")
        good(store, "apply-update", value, "P11", "reused exact public replay")
        refused(store, "apply-update", update(init["current_tip"], update_id="stale"), "E_STALE", "P11", "reused exact public refusal")
        record("P11", "no auxiliary startup path", not any(path.name == "xcrun_db" or path.name == "__pycache__" for path in store.rglob("*")))
    finally:
        for name, value in old.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
    loader = ROOT / "provenance.py"
    provenance = ROOT / "provenance.json"
    loader.write_text('''import hashlib,json,os,runpy,sys
source,root,request,output=sys.argv[1:]
flags={name:getattr(sys.flags,name) for name in ("isolated","no_site","dont_write_bytecode")}
sys.argv=[source,"read",root,request]
try:
 runpy.run_path(source,run_name="__main__")
except SystemExit as result:
 status=result.code
origins={}
for name,module in list(sys.modules.items()):
 path=getattr(module,"__file__",None)
 if path and os.path.isfile(path):
  with open(path,"rb") as stream: digest=hashlib.sha256(stream.read()).hexdigest()
  origins[name]={"path":path,"sha256":digest}
with open(output,"w") as stream:
 json.dump({"flags":flags,"executable":sys.executable,"version":sys.version,"platform":list(os.uname()),"origins":origins},stream,sort_keys=True)
sys.exit(status)
''')
    path = ROOT / "provenance-request.json"
    path.write_bytes(canonical(request()))
    status, out, err = captured([PYTHON, "-I", "-S", "-B", str(loader), PRODUCT, str(base), str(path), str(provenance)], base, environment(base))
    data = json.loads(provenance.read_bytes())
    record("P11", "supplementary unchanged source startup", status == 0 and not err and json.loads(out)["current_tip"] == initial["current_tip"])
    record("P11", "actual isolated no-site no-bytecode flags", data["flags"] == {"isolated": 1, "no_site": 1, "dont_write_bytecode": 1})
    record("P11", "native dependencies identified", all(name in data["origins"] for name in ("_hashlib", "zlib", "fcntl")))
    data["source_sha256"] = hashlib.sha256(pathlib.Path(PRODUCT).read_bytes()).hexdigest()
    data["executable_sha256"] = hashlib.sha256(pathlib.Path(PYTHON).read_bytes()).hexdigest()
    print("ledger supplementary provenance:", json.dumps(data, sort_keys=True), flush=True)


def growth_and_bootstrap(base, initial):
    store = new_store("bootstrap-race")
    competing = []
    def acquire_before_creator(row, deadline):
        remaining(deadline)
        if row["operation"] == "open" and row["path"].endswith("/store.lock") and not competing:
            record("P7", "exclusive creator not yet flock owner", row["locked"] is False and list(store.iterdir()) == [store / "store.lock"])
            competing.append(good(store, "initialize", request("initialize"), "P7", "second initializer acquires real lock", deadline=deadline))
    status, out, err, rows = observed(store, "initialize", request("initialize"), "bootstrap-before-flock", interfere=acquire_before_creator)
    record("P7", "creator later replays committed initialization", status == 0 and not err and json.loads(out) == competing[0])
    record("P9", "creator wrote no repository state without flock", not any(row["operation"] in ("mkdir", "write", "rename", "replace") for row in rows))
    store = new_store("growth-maximum")
    identity = {"store_id": "s" * 128, "ledger_id": "l" * 128}
    value = request("initialize", **identity)
    value["initialization_id"] = "i" * 128
    current = good(store, "initialize", value, "P9", "maximum identity initialize")
    for number in range(128):
        delivery_key = key(request_sha256="%064x" % number, operation="recover-stranded-attempt", attempt_number=10)
        delivery_key["stage_key"] = {field: field[0] * 128 for field in delivery_key["stage_key"]}
        value = update(current["current_tip"], update_id="u" * 124 + "%04d" % number, delivery_key=delivery_key)
        value.update(identity)
        current = good(store, "apply-update", value, "P9", "maximum-width entry %d" % number)
    value = update(current["current_tip"], 2, update_id="v" * 128, delivery_key=delivery_key)
    value.update(identity)
    before = physical_counts(store)
    reference = copy_store(store, "growth-direct")
    expected = good(reference, "apply-update", value, "P9", "maximum growth ordinary direct control")
    unpaused = copy_store(store, "growth-unpaused")
    status, out, err, _ = observed(unpaused, "apply-update", value, "growth-unpaused", pause=False)
    record("P9", "maximum no-pause instrumented equivalence", status == 0 and not err and json.loads(out) == expected and inventory(unpaused) == inventory(reference))
    status, out, err, rows = observed(store, "apply-update", value, "growth-observed", busy=True)
    record("P9", "maximum growth unchanged-main equivalence", status == 0 and not err and json.loads(out) == expected and inventory(store) == inventory(reference))
    peaks = [max(row["inventory"][index] for row in rows) for index in range(5)]
    record("P9", "maximum growth all caps", peaks[0] <= 8192 and peaks[1] <= 16384 and peaks[2] <= 134217728 and peaks[3] <= 134217728 and peaks[4] <= 1)
    record("P9", "maximum growth reserved deltas", all(peak - start <= limit for peak, start, limit in zip(peaks, before, (8, 32, 1048576, 1048576))))
    record("P9", "maximum growth every mutation observed under lock", all(row["locked"] for row in rows if row["operation"] in ("mkdir", "write", "rename", "replace")))
    print("ledger maximum growth:", json.dumps({"before": before, "peaks": peaks, "ledger_bytes": len(canonical(expected["ledger"])), "response_bytes": len(canonical(expected))}, sort_keys=True), flush=True)
    oracle(canonical(expected), "maximum-width-response", "P1")







base, initial = protocol_cases()
startup_cases(base, initial)
direct_isolation(base, initial)
print("ledger native startup observation window complete", flush=True)
states = transitions(base, initial)
replay_store, replay_request = replay_cases(base, initial, states)
interoperability(replay_store)
planner_cases(base, initial)
invalid_stores(base, initial)
crash_cases(base, initial)
concurrency_cases(base, initial)
history_cases(base, initial)
resource_cases(base, initial)
growth_and_bootstrap(base, initial)
private_boundaries(base, initial)

remaining()
for group, count in GROUPS.items():
    if not count:
        raise AssertionError("required proof group not executed: " + group)
print("ledger proof groups:", json.dumps(GROUPS, sort_keys=True), flush=True)
print("ledger focused elapsed seconds:", time.monotonic() - START, flush=True)
PY
"$python" -I -S -B "$tmp/harness.py" "$product" "$tmp" "$python" "$git_bin" "$tmp/bin/jq"
