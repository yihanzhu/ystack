#!/bin/bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077
root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
product="$root/telemetry/v1/trace-store.py"
[ -f "$product" ] && [ ! -L "$product" ] || {
  printf '%s\n' 'FAIL P0: trace-store public source missing' >&2
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
  *) printf 'FAIL unsupported trace-store test platform: %s\n' "$platform" >&2; exit 1 ;;
esac
[ -x "$python" ] && [ -x "$git_bin" ] || exit 1
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-trace-store-test.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
download=''
cleanup() {
  status=$?
  [ -z "$download" ] || /bin/rm -f -- "$download"
  if [ "$status" -eq 0 ]; then
    /bin/rm -rf -- "$tmp"
  else
    printf 'trace-store test failed, fixtures retained: %s\n' "$tmp" >&2
  fi
}
trap cleanup EXIT
sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
cache_dir="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$cache_dir"
cache="$cache_dir/$jq_asset"
if [ ! -f "$cache" ] || [ -L "$cache" ] || [ "$(sha_file "$cache")" != "$jq_sha" ]; then
  download=$(/usr/bin/mktemp "$cache_dir/.jq-trace-store.XXXXXX")
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
import importlib.util
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time

PRODUCT, PYTHON, GIT, JQ, REPO = sys.argv[1:6]
GROUPS = {}
PASSES = [0]


def group_name(name):
    GROUPS.setdefault(name, 0)


def record(group, name, condition):
    if not condition:
        raise AssertionError("%s: %s" % (group, name))
    GROUPS[group] = GROUPS.get(group, 0) + 1
    PASSES[0] += 1
    print("ok %s.%d - %s" % (group, GROUPS[group], name), flush=True)


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode("ascii")


def digest(data):
    return hashlib.sha256(data).hexdigest()


ENV = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C", "HOME": "/dev/null"}


def run(args, env=None, timeout=60):
    full_env = dict(env if env is not None else ENV)
    proc = subprocess.run([PYTHON, "-I", "-S", "-B", PRODUCT] + list(args),
                           env=full_env, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    return proc.returncode, proc.stdout, proc.stderr


def new_dir(path, mode=0o700):
    os.makedirs(path, mode=mode, exist_ok=False)
    return str(path)


FACT_KEYS = ["adapter", "cost_microunits", "execution_environment", "gate", "identity",
             "initiative", "latency_ms", "result", "stage", "status", "task_class", "tool",
             "workflow"]


def make_event(session_id, attempt_id, trace_id, event_id, sequence, occurred_at, prior_digest, event_type="probe"):
    facts = {key: {"state": "not-applicable"} for key in FACT_KEYS}
    event = {
        "attempt_id": attempt_id, "event_type": event_type, "facts": facts, "id": event_id,
        "kind": "telemetry_trace_event", "occurred_at": occurred_at, "prior_digest": prior_digest,
        "schema_version": 1, "sequence": sequence, "session_id": session_id, "trace_id": trace_id,
    }
    without = dict(event)
    without_digest = {k: v for k, v in without.items() if k != "record_digest"}
    record_digest = digest(canonical(without_digest))
    event["record_digest"] = record_digest
    return event


def make_ledger(content_id, session_id, attempt_id, trace_id="trace.fixture.one",
                 event_count=1, base_time="2000-01-01T00:00:00Z"):
    events = []
    prior = None
    for i in range(event_count):
        occurred = "2000-01-01T00:%02d:%02dZ" % (i // 60, i % 60)
        event = make_event(session_id, attempt_id, trace_id, "event.%d" % i, i, occurred, prior)
        events.append(event)
        prior = event["record_digest"]
    seal = {"algorithm": "sha256", "canonicalization": "jq-1.6-sort-compact-line",
            "event_count": len(events), "final_digest": events[-1]["record_digest"],
            "first_digest": events[0]["record_digest"]}
    ledger = {"body": {"attempt_id": attempt_id, "events": events, "seal": seal,
                        "session_id": session_id, "trace_ids": [trace_id]},
              "id": content_id, "kind": "telemetry_trace_ledger", "schema_version": 1}
    return ledger


def write_ledger(path, ledger):
    data = canonical(ledger)
    with open(path, "wb") as handle:
        handle.write(data)
    os.chmod(path, 0o600)
    return data


def store_root(tmp, name):
    path = os.path.join(tmp, name)
    os.makedirs(path, mode=0o700)
    return path


def scratch_root(tmp, name):
    path = os.path.join(tmp, name)
    os.makedirs(path, mode=0o700)
    return path


def do(verb, *args, env=None, timeout=60):
    return run([verb] + list(args), env=env, timeout=timeout)


def initialize(store, store_id):
    return do("initialize", store, store_id)


def append(store, store_id, tip, scratch, ledger_path, session_id, attempt_id, env=None, timeout=60):
    return do("append", store, store_id, tip, scratch, JQ, session_id, attempt_id, ledger_path,
               env=env, timeout=timeout)


def read(store, receipt_path, output_path, jq=None):
    return do("read", store, jq or JQ, receipt_path, output_path)


def listing(store, store_id):
    return do("list", store, store_id)


def tip_of(store, store_id):
    code, out, err = listing(store, store_id)
    assert code == 0, (code, out, err)
    return json.loads(out.decode("ascii"))["body"]["tip"]


def sha_file(path):
    return digest(pathlib.Path(path).read_bytes())


def main():
    tmp = tempfile_mkdtemp()
    try:
        run_all(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("# %d assertions passed" % PASSES[0])


def tempfile_mkdtemp():
    import tempfile
    return os.path.realpath(tempfile.mkdtemp(prefix="ystack-trace-store-test."))


def run_all(tmp):
    test_recovery(tmp)
    test_same_attempt(tmp)
    test_replay(tmp)
    test_writers(tmp)
    test_crash_states(tmp)
    test_capacity(tmp)


def test_recovery(tmp):
    g = "P1"
    for which in ("pre", "post"):
        source = os.path.join(REPO, "shadow/evidence/self-host-transition/v1", which,
                               "state/trace-ledger.json")
        store = store_root(tmp, "recover-%s-store" % which)
        scratch = scratch_root(tmp, "recover-%s-scratch" % which)
        code, out, err = initialize(store, "recover.%s" % which)
        record(g, "initialize %s" % which, code == 0)
        ledger_bytes = pathlib.Path(source).read_bytes()
        ledger = json.loads(ledger_bytes)
        session_id = ledger["body"]["session_id"]
        attempt_id = ledger["body"]["attempt_id"]
        scratch_copy = os.path.join(scratch, "ledger.json")
        shutil.copy(source, scratch_copy)
        os.chmod(scratch_copy, 0o600)
        tip = tip_of(store, "recover.%s" % which)
        code, out, err = append(store, "recover.%s" % which, tip, scratch, scratch_copy,
                                 session_id, attempt_id)
        record(g, "append %s" % which, code == 0)
        receipt_path = os.path.join(tmp, "recover-%s-receipt.json" % which)
        pathlib.Path(receipt_path).write_bytes(out)
        os.unlink(scratch_copy)
        output_path = os.path.join(tmp, "recover-%s-output.json" % which)
        code, out2, err2 = read(store, receipt_path, output_path)
        record(g, "read %s after scratch deletion" % which, code == 0)
        read_bytes = pathlib.Path(output_path).read_bytes()
        record(g, "read-back is byte-identical to committed ledger (%s)" % which,
               read_bytes == ledger_bytes)
        record(g, "read-back sha256 matches (%s)" % which, digest(read_bytes) == digest(ledger_bytes))


def test_same_attempt(tmp):
    g = "P2"
    store = store_root(tmp, "same-attempt-store")
    scratch = scratch_root(tmp, "same-attempt-scratch")
    initialize(store, "same.attempt")
    session_id = "incident.same-attempt"
    attempt_id = "attempt.shadow-reproduce"
    ledger_a = make_ledger("fixture.a", session_id, attempt_id, base_time="2000-01-01T00:00:00Z")
    ledger_b = make_ledger("fixture.b", session_id, attempt_id, trace_id="trace.fixture.two",
                            base_time="2000-01-01T00:05:00Z")
    assert ledger_a["body"]["seal"]["final_digest"] != ledger_b["body"]["seal"]["final_digest"]
    path_a = os.path.join(scratch, "a.json")
    path_b = os.path.join(scratch, "b.json")
    write_ledger(path_a, ledger_a)
    write_ledger(path_b, ledger_b)
    tip = tip_of(store, "same.attempt")
    code, out_a, err = append(store, "same.attempt", tip, scratch, path_a, session_id, attempt_id)
    record(g, "store first bundle for session+attempt", code == 0)
    tip = tip_of(store, "same.attempt")
    code, out_b, err = append(store, "same.attempt", tip, scratch, path_b, session_id, attempt_id)
    record(g, "store second bundle, same session+attempt, different final_digest", code == 0)
    code, out, err = listing(store, "same.attempt")
    record(g, "list succeeds", code == 0)
    doc = json.loads(out.decode("ascii"))
    record(g, "both records present", doc["body"]["record_count"] == 2)
    keys = [e["replay_key"] for e in doc["body"]["records"]]
    ordered = sorted(keys, key=lambda k: (k["session_id"], k["attempt_id"], k["final_digest"]))
    record(g, "list is in replay-key byte order", keys == ordered)
    record(g, "no entry carries a newest/recency field",
           all(set(e.keys()) == {"record_key", "replay_key", "event_count", "commit_id",
                                  "record_sha256", "ledger_ref"} for e in doc["body"]["records"]))


def test_replay(tmp):
    g = "P3"
    store = store_root(tmp, "replay-store")
    scratch = scratch_root(tmp, "replay-scratch")
    initialize(store, "replay.store")
    session_id = "incident.replay"
    attempt_id = "attempt.shadow-reproduce"
    ledger = make_ledger("fixture.replay", session_id, attempt_id)
    path = os.path.join(scratch, "ledger.json")
    write_ledger(path, ledger)
    tip = tip_of(store, "replay.store")
    code, receipt1, err = append(store, "replay.store", tip, scratch, path, session_id, attempt_id)
    record(g, "first append", code == 0)

    other = make_ledger("fixture.replay.other", "incident.replay.other", attempt_id)
    other_path = os.path.join(scratch, "other.json")
    write_ledger(other_path, other)
    tip2 = tip_of(store, "replay.store")
    code, _, err = append(store, "replay.store", tip2, scratch, other_path,
                           "incident.replay.other", attempt_id)
    record(g, "a later, unrelated append succeeds", code == 0)

    tip3 = tip_of(store, "replay.store")
    code, receipt2, err = append(store, "replay.store", tip3, scratch, path, session_id, attempt_id)
    record(g, "identical replay after a later append succeeds", code == 0)
    record(g, "identical replay returns identical receipt bytes", receipt1 == receipt2)
    tip4 = tip_of(store, "replay.store")
    record(g, "identical replay adds nothing to the tip", tip3 == tip4)

    lock_path = os.path.join(store, "repository.git/refs/heads/records.lock")
    with open(lock_path, "wb") as handle:
        handle.write(b"")
    os.chmod(lock_path, 0o600)
    code, receipt3, err = append(store, "replay.store", tip4, scratch, path, session_id, attempt_id)
    record(g, "identical replay succeeds even with a stale ref lock present", code == 0)
    record(g, "replay-with-lock-present receipt matches", receipt3 == receipt1)
    os.unlink(lock_path)

    tip5 = tip_of(store, "replay.store")
    code, out, err = append(store, "replay.store", tip5, scratch, path, session_id, attempt_id)
    record(g, "identical replay with a genuinely stale ref lock removed still succeeds", code == 0)


def test_writers(tmp):
    g = "P4"
    store = store_root(tmp, "writers-store")
    scratch = scratch_root(tmp, "writers-scratch")
    initialize(store, "writers.store")
    session_id = "incident.writers"
    attempt_id = "attempt.shadow-reproduce"
    ledger = make_ledger("fixture.writers", session_id, attempt_id)
    path = os.path.join(scratch, "ledger.json")
    write_ledger(path, ledger)
    tip = tip_of(store, "writers.store")
    code, out, err = append(store, "writers.store", tip, scratch, path, session_id, attempt_id)
    record(g, "seed a record", code == 0)

    modified = json.loads(canonical(ledger))
    modified["id"] = "fixture.writers.modified"
    modified_path = os.path.join(scratch, "modified.json")
    write_ledger(modified_path, modified)
    tip2 = tip_of(store, "writers.store")
    code, out, err = append(store, "writers.store", tip2, scratch, modified_path, session_id, attempt_id)
    record(g, "same replay key, different bytes is E_CONFLICT", code == 1 and err == b"E_CONFLICT\n")

    other = make_ledger("fixture.writers.two", "incident.writers.two", attempt_id)
    other_path = os.path.join(scratch, "two.json")
    write_ledger(other_path, other)
    stale_tip = tip
    code, out, err = append(store, "writers.store", stale_tip, scratch, other_path,
                             "incident.writers.two", attempt_id)
    record(g, "EXPECTED_TIP behind the real tip is E_STALE", code == 1 and err == b"E_STALE\n")

    busy_tip = tip_of(store, "writers.store")
    lock_path = os.path.join(store, "store.lock")
    fd = os.open(lock_path, os.O_RDWR)
    import fcntl
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        code, out, err = run(["append", store, "writers.store", busy_tip, scratch, JQ,
                               "incident.writers.two", attempt_id, other_path], timeout=15)
        record(g, "a second writer refused while the store lock is held is E_BUSY",
               code == 1 and err == b"E_BUSY\n")
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
    code, out, err = append(store, "writers.store", busy_tip, scratch, other_path,
                             "incident.writers.two", attempt_id)
    record(g, "the same writer succeeds once the lock is released", code == 0)


def wrapper_path(tmp, name):
    return os.path.join(tmp, name)


def write_wrapper(path, body):
    with open(path, "w") as handle:
        handle.write(body)


KILL_WRAPPER_TEMPLATE = '''
import importlib.util, os, pathlib, signal, sys
path, point, arguments = sys.argv[1], sys.argv[2], sys.argv[3:]
spec = importlib.util.spec_from_file_location("tracestore", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def kill_now():
    os.kill(os.getpid(), signal.SIGKILL)


if point == "run_validator":
    original = module.run_validator
    def wrapped(*a, **kw):
        result = original(*a, **kw)
        kill_now()
        return result
    module.run_validator = wrapped
elif point == "create_object_temporary":
    original = module.create_object_temporary
    state = {"n": 0}
    def wrapped(directory, compressed):
        state["n"] += 1
        result = original(directory, compressed)
        if state["n"] == 1:
            kill_now()
        return result
    module.create_object_temporary = wrapped
elif point == "install_object":
    original = module.install_object
    state = {"n": 0}
    def wrapped(temp, final):
        result = original(temp, final)
        state["n"] += 1
        if state["n"] == 2:
            kill_now()
        return result
    module.install_object = wrapped
elif point == "write_ref_lock_zero":
    def wrapped(descriptor, commit_id):
        kill_now()
    module.write_ref_lock = wrapped
elif point == "write_ref_lock_partial":
    original_write_all = module.write_all
    def wrapped(descriptor, commit_id):
        data = (commit_id + "\\n").encode("ascii")
        os.write(descriptor, data[:20])
        kill_now()
    module.write_ref_lock = wrapped
elif point == "write_ref_lock_full":
    def wrapped(descriptor, commit_id):
        data = (commit_id + "\\n").encode("ascii")
        n = 0
        while n < len(data):
            n += os.write(descriptor, data[n:])
        kill_now()
    module.write_ref_lock = wrapped
elif point == "install_ref_lock":
    original = module.install_ref_lock
    def wrapped(temp, final):
        result = original(temp, final)
        kill_now()
        return result
    module.install_ref_lock = wrapped
elif point == "emit":
    def wrapped(data):
        kill_now()
    module.emit = wrapped
elif point == "hold_lock":
    import time as _time
    original = module.acquire_lock
    marker = arguments[0]
    arguments = arguments[1:]
    def wrapped(descriptor):
        original(descriptor)
        with open(marker, "w") as h:
            h.write("locked\\n")
        _time.sleep(30)
    module.acquire_lock = wrapped
elif point == "initialize_kill":
    original = module.install_ref_lock
    def wrapped(temp, final):
        kill_now()
    module.install_ref_lock = wrapped

sys.argv = [path] + arguments
raise SystemExit(module.main(sys.argv))
'''


def run_wrapped(tmp, point, args, env=None, extra=(), timeout=30):
    wrapper = wrapper_path(tmp, "wrapper-%s.py" % point.replace("/", "_"))
    if not os.path.exists(wrapper):
        write_wrapper(wrapper, KILL_WRAPPER_TEMPLATE)
    full_env = dict(env if env is not None else ENV)
    proc = subprocess.run([PYTHON, "-I", "-S", "-B", wrapper, PRODUCT, point] + list(extra) + list(args),
                           env=full_env, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    return proc.returncode, proc.stdout, proc.stderr


def snapshot_tree(root):
    result = {}
    for dirpath, dirnames, filenames in os.walk(root):
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            state = os.lstat(full)
            if os.path.islink(full):
                result[rel] = ("link", os.readlink(full))
            else:
                result[rel] = ("file", state.st_mode & 0o777, state.st_size,
                                digest(pathlib.Path(full).read_bytes()))
    return result


def test_crash_states(tmp):
    g = "P5"
    store = store_root(tmp, "crash-store")
    scratch = scratch_root(tmp, "crash-scratch")
    initialize(store, "crash.store")
    session_id = "incident.crash"
    attempt_id = "attempt.shadow-reproduce"

    # K1: killed inside run_validator, before any store write.
    ledger_k1 = make_ledger("fixture.k1", session_id, attempt_id)
    path_k1 = os.path.join(scratch, "k1.json")
    write_ledger(path_k1, ledger_k1)
    tip = tip_of(store, "crash.store")
    before = snapshot_tree(store)
    code, out, err = run_wrapped(tmp, "run_validator",
                                  ["append", store, "crash.store", tip, scratch, JQ, session_id, attempt_id, path_k1])
    record(g, "K1: killed inside run_validator leaves the store untouched",
           code != 0 and snapshot_tree(store) == before)
    code, out, err = append(store, "crash.store", tip, scratch, path_k1, session_id, attempt_id)
    record(g, "K1: a fresh append after the kill still succeeds", code == 0)

    # K2: killed while writing an object temporary.
    ledger_k2 = make_ledger("fixture.k2", session_id, attempt_id, trace_id="trace.k2")
    path_k2 = os.path.join(scratch, "k2.json")
    write_ledger(path_k2, ledger_k2)
    tip = tip_of(store, "crash.store")
    code, out, err = run_wrapped(tmp, "create_object_temporary",
                                  ["append", store, "crash.store", tip, scratch, JQ, session_id, attempt_id, path_k2])
    record(g, "K2: killed while writing an object temporary refuses", code != 0)
    tip_after = tip_of(store, "crash.store")
    record(g, "K2: the tip is unchanged", tip_after == tip)
    residue = [p for p in snapshot_tree(store) if "tmp_obj_" in p]
    record(g, "K2: a bounded temporary file remains as residue", len(residue) >= 1)
    code, out, err = append(store, "crash.store", tip, scratch, path_k2, session_id, attempt_id)
    record(g, "K2: a retry against the same tip proceeds", code == 0)

    # K3: killed after some complete objects, before the ref lock.
    ledger_k3 = make_ledger("fixture.k3", session_id, attempt_id, trace_id="trace.k3")
    path_k3 = os.path.join(scratch, "k3.json")
    write_ledger(path_k3, ledger_k3)
    tip = tip_of(store, "crash.store")
    code, out, err = run_wrapped(tmp, "install_object",
                                  ["append", store, "crash.store", tip, scratch, JQ, session_id, attempt_id, path_k3])
    record(g, "K3: killed after some complete objects, before the ref lock, refuses", code != 0)
    tip_after = tip_of(store, "crash.store")
    record(g, "K3: the tip is unchanged", tip_after == tip)
    code, out, err = append(store, "crash.store", tip, scratch, path_k3, session_id, attempt_id)
    record(g, "K3: a retry reuses the unreachable objects and succeeds", code == 0)

    # K4: killed in write_ref_lock, at 0, ~20 and all 41 bytes.
    for variant, label in (("write_ref_lock_zero", "zero"), ("write_ref_lock_partial", "partial"),
                            ("write_ref_lock_full", "all-41")):
        ledger_k4 = make_ledger("fixture.k4.%s" % label, session_id, attempt_id,
                                 trace_id="trace.k4.%s" % label)
        path_k4 = os.path.join(scratch, "k4-%s.json" % label)
        write_ledger(path_k4, ledger_k4)
        tip = tip_of(store, "crash.store")
        code, out, err = run_wrapped(tmp, variant,
                                      ["append", store, "crash.store", tip, scratch, JQ, session_id, attempt_id, path_k4])
        record(g, "K4 (%s bytes): killed writing the ref lock refuses" % label, code != 0)
        tip_after = tip_of(store, "crash.store")
        record(g, "K4 (%s bytes): the old tip stays valid" % label, tip_after == tip)
        record(g, "K4 (%s bytes): the ref lock file remains" % label,
               os.path.lexists(os.path.join(store, "repository.git/refs/heads/records.lock")))
        code, out, err = listing(store, "crash.store")
        record(g, "K4 (%s bytes): list still works" % label, code == 0)
        code, out, err = append(store, "crash.store", tip, scratch, path_k4, session_id, attempt_id)
        record(g, "K4 (%s bytes): a new append is E_LOCKED" % label,
               code == 1 and err == b"E_LOCKED\n")
        os.unlink(os.path.join(store, "repository.git/refs/heads/records.lock"))
        code, out, err = append(store, "crash.store", tip, scratch, path_k4, session_id, attempt_id)
        record(g, "K4 (%s bytes): append succeeds once the operator clears the lock" % label, code == 0)

    # K5: killed after the rename, before stdout.
    ledger_k5 = make_ledger("fixture.k5", session_id, attempt_id, trace_id="trace.k5")
    path_k5 = os.path.join(scratch, "k5.json")
    write_ledger(path_k5, ledger_k5)
    tip = tip_of(store, "crash.store")
    code, out, err = run_wrapped(tmp, "install_ref_lock",
                                  ["append", store, "crash.store", tip, scratch, JQ, session_id, attempt_id, path_k5])
    record(g, "K5: killed after the rename, before stdout, refuses at the CLI level", code != 0)
    tip_after = tip_of(store, "crash.store")
    record(g, "K5: the record was actually committed", tip_after != tip)
    code, receipt_a, err = append(store, "crash.store", tip_after, scratch, path_k5, session_id, attempt_id)
    record(g, "K5: identical replay after the lost reply succeeds", code == 0)

    # K6: killed while holding flock.
    marker = os.path.join(tmp, "k6-marker")
    if os.path.exists(marker):
        os.unlink(marker)
    ledger_k6 = make_ledger("fixture.k6", session_id, attempt_id, trace_id="trace.k6")
    path_k6 = os.path.join(scratch, "k6.json")
    write_ledger(path_k6, ledger_k6)
    tip = tip_of(store, "crash.store")
    wrapper = wrapper_path(tmp, "wrapper-hold_lock.py")
    write_wrapper(wrapper, KILL_WRAPPER_TEMPLATE)
    proc = subprocess.Popen(
        [PYTHON, "-I", "-S", "-B", wrapper, PRODUCT, "hold_lock", marker,
         "list", store, "crash.store"],
        env=dict(ENV), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = time.monotonic() + 10
    while not os.path.exists(marker):
        if time.monotonic() > deadline:
            proc.kill()
            raise AssertionError("K6: child never reached the lock-held marker")
        time.sleep(0.05)
    proc.kill()
    proc.wait(timeout=10)
    record(g, "K6: process killed while holding flock", True)
    record(g, "K6: store.lock file still present after the kernel releases the lock",
           os.path.lexists(os.path.join(store, "store.lock")))
    code, out, err = listing(store, "crash.store")
    record(g, "K6: a new call succeeds (the kernel released the flock)", code == 0)

    # K7: killed during initialize's write_ref_lock, before its ref is published.
    k7_store = store_root(tmp, "crash-k7-store")
    code, out, err = run_wrapped(tmp, "initialize_kill", ["initialize", k7_store, "crash.k7"])
    record(g, "K7: killed during initialize before publication refuses", code != 0)
    for verb_args in (("initialize", [k7_store, "crash.k7"]),
                       ("list", [k7_store, "crash.k7"])):
        verb, args = verb_args
        code, out, err = run([verb] + args)
        record(g, "K7: %s is permanently E_INCOMPLETE" % verb,
               code == 1 and err == b"E_INCOMPLETE\n")


def test_capacity(tmp):
    g = "P8"
    wrapper = wrapper_path(tmp, "wrapper-capacity.py")
    write_wrapper(wrapper, '''
import importlib.util, sys
path = sys.argv[1]
spec = importlib.util.spec_from_file_location("tracestore", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.RECORDS_MAX = 2
sys.argv = [path] + sys.argv[2:]
raise SystemExit(module.main(sys.argv))
''')

    def run_low(args, timeout=30):
        proc = subprocess.run([PYTHON, "-I", "-S", "-B", wrapper, PRODUCT] + list(args),
                               env=dict(ENV), stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        return proc.returncode, proc.stdout, proc.stderr

    store = store_root(tmp, "capacity-store")
    scratch = scratch_root(tmp, "capacity-scratch")
    code, out, err = run_low(["initialize", store, "capacity.store"])
    record(g, "initialize under a lowered RECORDS_MAX", code == 0)
    session_id = "incident.capacity"
    attempt_id = "attempt.shadow-reproduce"
    for i in range(2):
        ledger = make_ledger("fixture.capacity.%d" % i, session_id, attempt_id, trace_id="trace.cap.%d" % i)
        path = os.path.join(scratch, "cap-%d.json" % i)
        write_ledger(path, ledger)
        proc = subprocess.run([PYTHON, "-I", "-S", "-B", wrapper, PRODUCT, "list", store, "capacity.store"],
                               env=dict(ENV), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        tip = json.loads(proc.stdout.decode("ascii"))["body"]["tip"]
        code, out, err = run_low(["append", store, "capacity.store", tip, scratch, JQ,
                                   session_id, attempt_id, path])
        record(g, "fill record %d up to the lowered cap" % i, code == 0)

    proc = subprocess.run([PYTHON, "-I", "-S", "-B", wrapper, PRODUCT, "list", store, "capacity.store"],
                           env=dict(ENV), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    tip = json.loads(proc.stdout.decode("ascii"))["body"]["tip"]
    overflow = make_ledger("fixture.capacity.overflow", session_id, attempt_id, trace_id="trace.cap.of")
    overflow_path = os.path.join(scratch, "overflow.json")
    write_ledger(overflow_path, overflow)
    before = snapshot_tree(store)
    code, out, err = run_low(["append", store, "capacity.store", tip, scratch, JQ,
                               session_id, attempt_id, overflow_path])
    record(g, "an append beyond the lowered RECORDS_MAX is E_CAPACITY",
           code == 1 and err == b"E_CAPACITY\n")
    record(g, "a capacity refusal writes nothing", snapshot_tree(store) == before)

    code, out, err = run_low(["list", store, "capacity.store"])
    record(g, "list still works at full (lowered) capacity", code == 0)
    out_path = os.path.join(tmp, "capacity-read.json")
    ledger0 = make_ledger("fixture.capacity.0", session_id, attempt_id, trace_id="trace.cap.0")
    proc = subprocess.run([PYTHON, "-I", "-S", "-B", wrapper, PRODUCT, "list", store, "capacity.store"],
                           env=dict(ENV), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    entry = json.loads(proc.stdout.decode("ascii"))["body"]["records"][0]
    code, out, err = run_low(["append", store, "capacity.store", tip, scratch, JQ,
                               session_id, attempt_id, os.path.join(scratch, "cap-0.json")])
    record(g, "identical replay still works at full (lowered) capacity", code == 0)

    code, out, err = initialize(store_root(tmp, "capacity-normal-store"), "capacity.normal")
    doc = json.loads(out.decode("ascii"))
    code2, out2, err2 = do("list", tmp + "/capacity-normal-store", "capacity.normal")
    listed = json.loads(out2.decode("ascii"))
    record(g, "a store initialized by the shipped constants lists correctly", code2 == 0)


if __name__ == "__main__":
    main()
PY
"$python" -I -S -B "$tmp/harness.py" "$product" "$python" "$git_bin" "$tmp/bin/jq" "$root"
