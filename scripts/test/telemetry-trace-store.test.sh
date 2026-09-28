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
import stat
import subprocess
import sys
import time
import zlib

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
    test_invalid_input(tmp)
    test_corruption(tmp)
    test_capacity(tmp)
    test_boundaries(tmp)
    test_isolation(tmp)
    test_canonical_static(tmp)
    test_git_interop(tmp)


# ---------------------------------------------------------------------------

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
    before = snapshot_tree(store)
    code, out, err = append(store, "writers.store", tip2, scratch, modified_path, session_id, attempt_id)
    record(g, "same replay key, different bytes is E_CONFLICT", code == 1 and err == b"E_CONFLICT\n")
    record(g, "store tree unchanged after E_CONFLICT", snapshot_tree(store) == before)

    other = make_ledger("fixture.writers.two", "incident.writers.two", attempt_id)
    other_path = os.path.join(scratch, "two.json")
    write_ledger(other_path, other)
    stale_tip = tip
    before = snapshot_tree(store)
    code, out, err = append(store, "writers.store", stale_tip, scratch, other_path,
                             "incident.writers.two", attempt_id)
    record(g, "EXPECTED_TIP behind the real tip is E_STALE", code == 1 and err == b"E_STALE\n")
    record(g, "store tree unchanged after E_STALE", snapshot_tree(store) == before)

    busy_tip = tip_of(store, "writers.store")
    lock_path = os.path.join(store, "store.lock")
    fd = os.open(lock_path, os.O_RDWR)
    import fcntl
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        before = snapshot_tree(store)
        code, out, err = run(["append", store, "writers.store", busy_tip, scratch, JQ,
                               "incident.writers.two", attempt_id, other_path], timeout=15)
        record(g, "a second writer refused while the store lock is held is E_BUSY",
               code == 1 and err == b"E_BUSY\n")
        record(g, "store tree unchanged after E_BUSY", snapshot_tree(store) == before)
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
    """A byte-level snapshot of every entry under `root`, including the
    root itself and every directory (kind and mode), not only regular
    files: a corruption case that adds/removes/changes the mode of a
    directory, or replaces a directory with a symlink, must be visible to
    an unchanged-tree comparison exactly as a changed file would be. Does
    not follow symlinked directories (records the link target instead of
    descending into it), so it can never escape the tree or loop forever.
    """
    result = {}

    def visit(rel):
        full = os.path.join(root, rel) if rel else root
        state = os.lstat(full)
        key = rel if rel else "."
        if stat.S_ISLNK(state.st_mode):
            result[key] = ("link", os.readlink(full))
            return
        if stat.S_ISDIR(state.st_mode):
            result[key] = ("dir", state.st_mode & 0o777)
            for name in sorted(os.listdir(full)):
                visit(os.path.join(rel, name) if rel else name)
            return
        result[key] = ("file", state.st_mode & 0o777, state.st_size,
                        digest(pathlib.Path(full).read_bytes()))

    visit("")
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
        before = snapshot_tree(k7_store)
        code, out, err = run([verb] + args)
        record(g, "K7: %s is permanently E_INCOMPLETE" % verb,
               code == 1 and err == b"E_INCOMPLETE\n")
        record(g, "K7: %s leaves the partial store tree byte-identical" % verb,
               snapshot_tree(k7_store) == before)


def test_invalid_input(tmp):
    g = "P6"
    store = store_root(tmp, "invalid-store")
    scratch = scratch_root(tmp, "invalid-scratch")
    initialize(store, "invalid.store")
    session_id = "incident.invalid"
    attempt_id = "attempt.shadow-reproduce"

    # Wrong session / attempt -> E_RELATION from the validator.
    ledger = make_ledger("fixture.invalid.relation", session_id, attempt_id)
    path = os.path.join(scratch, "relation.json")
    write_ledger(path, ledger)
    tip = tip_of(store, "invalid.store")

    before = snapshot_tree(store)
    code, out, err = append(store, "invalid.store", tip, scratch, path, "incident.wrong", attempt_id)
    record(g, "wrong session_id is E_INVALID:E_RELATION",
           code == 1 and err == b"E_INVALID:E_RELATION\n")
    record(g, "store tree unchanged after wrong session_id", snapshot_tree(store) == before)

    before = snapshot_tree(store)
    code, out, err = append(store, "invalid.store", tip, scratch, path, session_id, "attempt.wrong")
    record(g, "wrong attempt_id is E_INVALID:E_RELATION",
           code == 1 and err == b"E_INVALID:E_RELATION\n")
    record(g, "store tree unchanged after wrong attempt_id", snapshot_tree(store) == before)

    # E_SHAPE: malformed ledger (missing a required field).
    bad_shape = json.loads(canonical(ledger))
    del bad_shape["body"]["trace_ids"]
    bad_shape_path = os.path.join(scratch, "shape.json")
    write_ledger(bad_shape_path, bad_shape)
    before = snapshot_tree(store)
    code, out, err = append(store, "invalid.store", tip, scratch, bad_shape_path, session_id, attempt_id)
    record(g, "malformed ledger document is E_INVALID:E_SHAPE",
           code == 1 and err == b"E_INVALID:E_SHAPE\n")
    record(g, "store tree unchanged after a malformed ledger document", snapshot_tree(store) == before)

    # E_PARSE: not valid JSON at all.
    parse_path = os.path.join(scratch, "parse.json")
    with open(parse_path, "wb") as handle:
        handle.write(b"not json\n")
    os.chmod(parse_path, 0o600)
    before = snapshot_tree(store)
    code, out, err = append(store, "invalid.store", tip, scratch, parse_path, session_id, attempt_id)
    record(g, "non-JSON ledger is E_INVALID:E_PARSE", code == 1 and err == b"E_INVALID:E_PARSE\n")
    record(g, "store tree unchanged after a non-JSON ledger", snapshot_tree(store) == before)

    # E_CANONICAL: valid JSON but not in jq -S -c form (extra whitespace).
    canonical_path = os.path.join(scratch, "canonical.json")
    with open(canonical_path, "wb") as handle:
        handle.write(canonical(ledger).replace(b'"body"', b'"body" '))
    os.chmod(canonical_path, 0o600)
    before = snapshot_tree(store)
    code, out, err = append(store, "invalid.store", tip, scratch, canonical_path, session_id, attempt_id)
    record(g, "non-canonical ledger bytes are E_INVALID:E_CANONICAL",
           code == 1 and err == b"E_INVALID:E_CANONICAL\n")
    record(g, "store tree unchanged after non-canonical ledger bytes", snapshot_tree(store) == before)

    # E_RELATION: event digests broken (tamper with a fact after computing digest).
    tampered = json.loads(canonical(ledger))
    tampered["body"]["events"][0]["sequence"] = 5
    tampered_path = os.path.join(scratch, "tampered.json")
    write_ledger(tampered_path, tampered)
    before = snapshot_tree(store)
    code, out, err = append(store, "invalid.store", tip, scratch, tampered_path, session_id, attempt_id)
    record(g, "a tampered event breaks its own digest chain: E_INVALID:<code>",
           code == 1 and err.startswith(b"E_INVALID:"))
    record(g, "store tree unchanged after a tampered event", snapshot_tree(store) == before)


def flip_object_byte(store):
    objects_root = os.path.join(store, "repository.git/objects")
    for dirpath, _dirnames, filenames in os.walk(objects_root):
        for name in filenames:
            if name.startswith("tmp_obj_"):
                continue
            full = os.path.join(dirpath, name)
            data = bytearray(pathlib.Path(full).read_bytes())
            if not data:
                continue
            data[-1] ^= 0xFF
            os.chmod(full, 0o600)
            pathlib.Path(full).write_bytes(bytes(data))
            return full
    raise AssertionError("no object file found to corrupt")


def test_corruption(tmp):
    g = "P7"

    def fresh_store(label):
        store = store_root(tmp, "corrupt-%s-store" % label)
        scratch = scratch_root(tmp, "corrupt-%s-scratch" % label)
        initialize(store, "corrupt.%s" % label)
        session_id = "incident.corrupt.%s" % label
        attempt_id = "attempt.shadow-reproduce"
        ledger = make_ledger("fixture.corrupt.%s" % label, session_id, attempt_id)
        path = os.path.join(scratch, "ledger.json")
        write_ledger(path, ledger)
        tip = tip_of(store, "corrupt.%s" % label)
        code, receipt, err = append(store, "corrupt.%s" % label, tip, scratch, path, session_id, attempt_id)
        assert code == 0, (code, receipt, err)
        receipt_path = os.path.join(tmp, "corrupt-%s-receipt.json" % label)
        pathlib.Path(receipt_path).write_bytes(receipt)
        return store, scratch, "corrupt.%s" % label, receipt_path

    def expect_corrupt(label, mutate):
        store, scratch, store_id, receipt_path = fresh_store(label)
        mutate(store)
        baseline = snapshot_tree(store)
        for verb in ("append", "read", "list"):
            if verb == "append":
                ledger = make_ledger("fixture.corrupt.%s.new" % label, "incident.new", "attempt.shadow-reproduce")
                path = os.path.join(scratch, "new.json")
                write_ledger(path, ledger)
                code, out, err = run(["append", store, store_id, "0" * 40, scratch, JQ,
                                       "incident.new", "attempt.shadow-reproduce", path])
            elif verb == "read":
                out_path = os.path.join(tmp, "corrupt-%s-%s-out.json" % (label, verb))
                code, out, err = run(["read", store, JQ, receipt_path, out_path])
            else:
                code, out, err = run(["list", store, store_id])
            record(g, "%s: %s refuses E_CORRUPT" % (label, verb), code == 1 and err == b"E_CORRUPT\n")
            record(g, "%s: %s leaves the (already corrupt) store tree byte-identical" % (label, verb),
                   snapshot_tree(store) == baseline)

    expect_corrupt("changed-object-byte", lambda store: flip_object_byte(store))

    def mutate_record_json_unrehashed(store):
        objects_root = os.path.join(store, "repository.git/objects")
        import zlib
        for dirpath, _dirnames, filenames in os.walk(objects_root):
            for name in filenames:
                if name.startswith("tmp_obj_"):
                    continue
                full = os.path.join(dirpath, name)
                raw = zlib.decompress(pathlib.Path(full).read_bytes())
                header, _, content = raw.partition(b"\0")
                if header.startswith(b"blob") and b'"kind":"telemetry_trace_store_record"' in content:
                    new_content = content.replace(b'"event_count":1', b'"event_count":2', 1)
                    if new_content == content:
                        continue
                    new_raw = header.replace(str(len(content)).encode(), str(len(new_content)).encode()) \
                        + b"\0" + new_content
                    os.chmod(full, 0o600)
                    pathlib.Path(full).write_bytes(zlib.compress(new_raw))
                    return
        raise AssertionError("record.json object not found")

    expect_corrupt("changed-record-json", mutate_record_json_unrehashed)

    def remove_an_object(store):
        objects_root = os.path.join(store, "repository.git/objects")
        for dirpath, _dirnames, filenames in os.walk(objects_root):
            for name in filenames:
                if name.startswith("tmp_obj_"):
                    continue
                os.unlink(os.path.join(dirpath, name))
                return
        raise AssertionError("no object to remove")

    expect_corrupt("missing-object", remove_an_object)

    def add_extra_ref(store):
        extra = os.path.join(store, "repository.git/refs/heads/extra")
        with open(extra, "wb") as handle:
            handle.write(b"0" * 40 + b"\n")
        os.chmod(extra, 0o600)

    expect_corrupt("extra-ref", add_extra_ref)

    def add_packed_refs(store):
        path = os.path.join(store, "repository.git/packed-refs")
        with open(path, "wb") as handle:
            handle.write(b"# pack-refs with: peeled fully-peeled sorted\n")
        os.chmod(path, 0o600)

    expect_corrupt("packed-refs", add_packed_refs)

    def add_symbolic_ref(store):
        path = os.path.join(store, "repository.git/refs/heads/sym")
        os.symlink("records", path)

    expect_corrupt("symbolic-ref", add_symbolic_ref)

    def add_reflog(store):
        os.makedirs(os.path.join(store, "repository.git/logs/refs/heads"), mode=0o700)
        path = os.path.join(store, "repository.git/logs/refs/heads/records")
        with open(path, "wb") as handle:
            handle.write(b"log\n")
        os.chmod(path, 0o600)

    expect_corrupt("reflog", add_reflog)

    def add_alternates(store):
        os.makedirs(os.path.join(store, "repository.git/objects/info"), mode=0o700)
        path = os.path.join(store, "repository.git/objects/info/alternates")
        with open(path, "wb") as handle:
            handle.write(b"/nonexistent\n")
        os.chmod(path, 0o600)

    expect_corrupt("alternates", add_alternates)

    def add_unknown_config_key(store):
        path = os.path.join(store, "repository.git/config")
        os.chmod(path, 0o600)
        with open(path, "ab") as handle:
            handle.write(b"\tbare = extra\n")
        os.chmod(path, 0o600)

    expect_corrupt("unknown-config-key", add_unknown_config_key)

    def add_second_parent(store):
        import re as _re
        objects_root = os.path.join(store, "repository.git/objects")
        import zlib
        for dirpath, _dirnames, filenames in os.walk(objects_root):
            for name in filenames:
                if name.startswith("tmp_obj_"):
                    continue
                full = os.path.join(dirpath, name)
                raw = zlib.decompress(pathlib.Path(full).read_bytes())
                header, _, content = raw.partition(b"\0")
                if header.startswith(b"commit") and b"\nparent " in content:
                    fake_parent = b"0" * 40
                    lines = content.split(b"\n")
                    lines.insert(2, b"parent " + fake_parent)
                    new_content = b"\n".join(lines)
                    new_raw = b"commit " + str(len(new_content)).encode() + b"\0" + new_content
                    os.chmod(full, 0o600)
                    pathlib.Path(full).write_bytes(zlib.compress(new_raw))
                    return
        raise AssertionError("no non-root commit found")

    expect_corrupt("second-parent", add_second_parent)

    def rehash_tip_event_count(store, new_event_count):
        # A "rehashed" corruption: replace record.json with a new, valid
        # git object (correct SHA-1 name for its own new content) that
        # claims a different event_count, then rebuild the tree and the
        # tip commit around it (same fixed author/committer/message, same
        # parent) so the whole chain stays self-consistent at the git
        # level. record.json's own digest/size cross-checks against
        # ledger.json and validation.json still pass unchanged; only the
        # event_count itself has been rehashed to lie. Unlike
        # flip_object_byte (which breaks the object's own SHA-1 name),
        # this specifically exercises the cross-check against the
        # validation document's actual content.
        objects_root = os.path.join(store, "repository.git/objects")
        ref_path = os.path.join(store, "repository.git/refs/heads/records")
        tip = pathlib.Path(ref_path).read_text().strip()
        names = ["ledger.json", "record.json", "store.json", "validation.json"]

        def obj_path(oid):
            return os.path.join(objects_root, oid[:2], oid[2:])

        def read_object(oid):
            raw = zlib.decompress(pathlib.Path(obj_path(oid)).read_bytes())
            header, _, content = raw.partition(b"\0")
            return header.split(b" ")[0].decode(), content

        def write_object(kind, content):
            raw = kind.encode("ascii") + b" " + str(len(content)).encode("ascii") + b"\0" + content
            oid = hashlib.sha1(raw).hexdigest()
            path = obj_path(oid)
            if not os.path.exists(path):
                os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
                with open(path, "wb") as handle:
                    handle.write(zlib.compress(raw))
                os.chmod(path, 0o600)
            return oid

        commit_kind, commit_content = read_object(tip)
        assert commit_kind == "commit"
        lines = commit_content.split(b"\n")
        tree_oid = lines[0][5:].decode()
        parent_oid = None
        for line in lines[1:]:
            if line.startswith(b"parent "):
                parent_oid = line[7:].decode()
        tree_kind, tree_content = read_object(tree_oid)
        assert tree_kind == "tree"
        members = {}
        offset = 0
        for name in names:
            prefix = b"100644 " + name.encode("ascii") + b"\0"
            assert tree_content[offset:offset + len(prefix)] == prefix
            offset += len(prefix)
            members[name] = tree_content[offset:offset + 20].hex()
            offset += 20
        record_kind, record_content = read_object(members["record.json"])
        assert record_kind == "blob"
        record_doc = json.loads(record_content)
        record_doc["body"]["event_count"] = new_event_count
        new_record_oid = write_object("blob", canonical(record_doc))
        new_members = dict(members)
        new_members["record.json"] = new_record_oid
        new_tree_content = b"".join(b"100644 " + name.encode("ascii") + b"\0" +
                                     bytes.fromhex(new_members[name]) for name in names)
        new_tree_oid = write_object("tree", new_tree_content)
        author = b"ystack trace store <trace-store@invalid> 946684800 +0000"
        message = b"ystack trace store\n"
        new_commit_content = b"tree " + new_tree_oid.encode("ascii") + b"\n"
        if parent_oid is not None:
            new_commit_content += b"parent " + parent_oid.encode("ascii") + b"\n"
        new_commit_content += b"author " + author + b"\ncommitter " + author + b"\n\n" + message
        new_commit_oid = write_object("commit", new_commit_content)
        with open(ref_path, "wb") as handle:
            handle.write((new_commit_oid + "\n").encode("ascii"))
        os.chmod(ref_path, 0o600)

    expect_corrupt("rehashed-event-count", lambda store: rehash_tip_event_count(store, 2))

    def add_unreachable_oversized_tree(store):
        # A syntactically valid, correctly-named "tree" object, never
        # referenced by any reachable commit, whose content exceeds
        # TREE_CONTENT_MAX (1024 bytes). inventory() decodes every loose
        # object regardless of reachability; only load_object (called for
        # reachable objects only) previously enforced the per-kind cap.
        content = (b"100644 x\0" + bytes(20)) * 200
        assert len(content) > 1024
        raw = b"tree " + str(len(content)).encode("ascii") + b"\0" + content
        oid = hashlib.sha1(raw).hexdigest()
        path = os.path.join(store, "repository.git/objects", oid[:2], oid[2:])
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(zlib.compress(raw))
        os.chmod(path, 0o600)

    expect_corrupt("unreachable-oversized-tree", add_unreachable_oversized_tree)

    def add_unreachable_oversized_commit(store):
        content = b"tree " + ("0" * 40).encode("ascii") + b"\n" + b"x" * 1200
        assert len(content) > 1024
        raw = b"commit " + str(len(content)).encode("ascii") + b"\0" + content
        oid = hashlib.sha1(raw).hexdigest()
        path = os.path.join(store, "repository.git/objects", oid[:2], oid[2:])
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(zlib.compress(raw))
        os.chmod(path, 0o600)

    expect_corrupt("unreachable-oversized-commit", add_unreachable_oversized_commit)


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

    # Independent exhaustion of each remaining R9 counter (and, since the
    # admission reserve is what reserve()/charge() actually compare against,
    # its reserve headroom too): object files, filesystem entries, regular
    # bytes and inflated bytes, each lowered on its own with every other
    # constant left at the shipped default. Rather than hand-computing the
    # exact byte/entry counts the private layout produces (an implementation
    # detail this test should not need to know), each case fills by real
    # appends until E_CAPACITY appears, then proves the tree is unchanged by
    # that refusal and that read/list/identical-replay still work at the
    # resulting (real) capacity.
    for label, patch, max_attempts in (
        ("object-files", "module.OBJECT_FILES_MAX = 13", 8),
        ("filesystem-entries", "module.FS_ENTRIES_MAX = 50", 8),
        ("regular-bytes", "module.REGULAR_BYTES_MAX = 3146400", 8),
        ("inflated-bytes", "module.INFLATED_BYTES_MAX = 3150000", 8),
    ):
        resource_capacity_case(tmp, label, patch, max_attempts)


def resource_capacity_case(tmp, label, patch, max_attempts):
    g = "P8"
    wrapper = wrapper_path(tmp, "wrapper-capacity-%s.py" % label)
    write_wrapper(wrapper, '''
import importlib.util, sys
path = sys.argv[1]
spec = importlib.util.spec_from_file_location("tracestore", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
%s
sys.argv = [path] + sys.argv[2:]
raise SystemExit(module.main(sys.argv))
''' % patch)

    def run_low(args, timeout=30):
        proc = subprocess.run([PYTHON, "-I", "-S", "-B", wrapper, PRODUCT] + list(args),
                               env=dict(ENV), stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        return proc.returncode, proc.stdout, proc.stderr

    def low_tip(store, store_id):
        code, out, err = run_low(["list", store, store_id])
        assert code == 0, (label, "list", code, out, err)
        return json.loads(out.decode("ascii"))["body"]["tip"]

    store = store_root(tmp, "capacity-%s-store" % label)
    scratch = scratch_root(tmp, "capacity-%s-scratch" % label)
    store_id = "capacity.%s" % label
    session_id = "incident.capacity.%s" % label
    attempt_id = "attempt.shadow-reproduce"

    code, out, err = run_low(["initialize", store, store_id])
    record(g, "%s: initialize under the lowered constant" % label, code == 0)

    stored_paths = []
    exhausted = False
    for i in range(max_attempts):
        ledger = make_ledger("fixture.capacity.%s.%d" % (label, i), session_id, attempt_id,
                              trace_id="trace.cap.%s.%d" % (label, i))
        path = os.path.join(scratch, "cap-%d.json" % i)
        write_ledger(path, ledger)
        tip = low_tip(store, store_id)
        before = snapshot_tree(store)
        code, out, err = run_low(["append", store, store_id, tip, scratch, JQ,
                                   session_id, attempt_id, path])
        if code != 0:
            record(g, "%s: exhaustion refuses E_CAPACITY" % label, err == b"E_CAPACITY\n")
            record(g, "%s: a capacity refusal writes nothing" % label,
                   snapshot_tree(store) == before)
            exhausted = True
            break
        stored_paths.append(path)
    if not exhausted:
        raise AssertionError("%s: never reached E_CAPACITY within %d attempts "
                              "(lowered constant too generous)" % (label, max_attempts))
    record(g, "%s: at least one record was stored before exhaustion" % label,
           len(stored_paths) >= 1)

    code, listing_bytes, err = run_low(["list", store, store_id])
    record(g, "%s: list still works at capacity" % label, code == 0)
    listed = json.loads(listing_bytes.decode("ascii"))
    record(g, "%s: list still reports the stored records" % label,
           listed["body"]["record_count"] == len(stored_paths))

    tip = low_tip(store, store_id)
    code, receipt_bytes, err = run_low(["append", store, store_id, tip, scratch, JQ,
                                         session_id, attempt_id, stored_paths[0]])
    record(g, "%s: identical replay still works at capacity" % label, code == 0)

    receipt_path = os.path.join(tmp, "capacity-%s-receipt.json" % label)
    pathlib.Path(receipt_path).write_bytes(receipt_bytes)
    out_path = os.path.join(tmp, "capacity-%s-out.json" % label)
    code, read_bytes, err = run_low(["read", store, JQ, receipt_path, out_path])
    record(g, "%s: read still works at capacity" % label, code == 0)


def test_boundaries(tmp):
    g = "P9"
    session_id = "incident.boundary"
    attempt_id = "attempt.shadow-reproduce"

    src_tree = os.path.join(tmp, "boundary-src-tree")
    code, out, err = do("initialize", os.path.join(REPO, "telemetry"), "boundary.src")
    record(g, "a store rooted inside the source checkout is E_BOUNDARY",
           code == 1 and err == b"E_BOUNDARY\n")

    nonempty = store_root(tmp, "boundary-nonempty")
    with open(os.path.join(nonempty, "junk"), "wb") as handle:
        handle.write(b"x")
    code, out, err = do("initialize", nonempty, "boundary.nonempty")
    record(g, "initialize on a non-empty, non-store root is E_BOUNDARY",
           code == 1 and err == b"E_BOUNDARY\n")

    wrongmode = store_root(tmp, "boundary-wrongmode")
    os.chmod(wrongmode, 0o755)
    code, out, err = do("initialize", wrongmode, "boundary.mode")
    record(g, "STORE_ROOT with the wrong mode is E_BOUNDARY", code == 1 and err == b"E_BOUNDARY\n")
    os.chmod(wrongmode, 0o700)

    ancestor_dir = os.path.join(tmp, "boundary-git-ancestor")
    os.makedirs(ancestor_dir, mode=0o700)
    with open(os.path.join(ancestor_dir, ".git"), "wb") as handle:
        handle.write(b"gitdir: elsewhere\n")
    nested = os.path.join(ancestor_dir, "nested-store")
    os.makedirs(nested, mode=0o700)
    code, out, err = do("initialize", nested, "boundary.gitfile")
    record(g, "a .git FILE in an ancestor is E_BOUNDARY", code == 1 and err == b"E_BOUNDARY\n")

    ancestor_dir2 = os.path.join(tmp, "boundary-git-ancestor-dir")
    os.makedirs(os.path.join(ancestor_dir2, ".git"), mode=0o700)
    nested2 = os.path.join(ancestor_dir2, "nested-store")
    os.makedirs(nested2, mode=0o700)
    code, out, err = do("initialize", nested2, "boundary.gitdir")
    record(g, "a .git DIRECTORY in an ancestor is E_BOUNDARY", code == 1 and err == b"E_BOUNDARY\n")

    store = store_root(tmp, "boundary-append-store")
    scratch = scratch_root(tmp, "boundary-append-scratch")
    initialize(store, "boundary.append")
    ledger = make_ledger("fixture.boundary", session_id, attempt_id)
    inside_path = os.path.join(scratch, "ledger.json")
    write_ledger(inside_path, ledger)
    tip = tip_of(store, "boundary.append")

    before = snapshot_tree(store)
    code, out, err = do("append", store, "boundary.append", tip, store, JQ, session_id, attempt_id, inside_path)
    record(g, "SCRATCH_ROOT equal to the store root is E_BOUNDARY", code == 1 and err == b"E_BOUNDARY\n")
    record(g, "store tree unchanged after SCRATCH_ROOT==STORE_ROOT E_BOUNDARY",
           snapshot_tree(store) == before)

    outside_ledger = os.path.join(tmp, "boundary-outside-ledger.json")
    write_ledger(outside_ledger, ledger)
    before = snapshot_tree(store)
    code, out, err = do("append", store, "boundary.append", tip, scratch, JQ, session_id, attempt_id,
                         outside_ledger)
    record(g, "LEDGER outside SCRATCH_ROOT is E_BOUNDARY", code == 1 and err == b"E_BOUNDARY\n")
    record(g, "store tree unchanged after LEDGER-outside-SCRATCH_ROOT E_BOUNDARY",
           snapshot_tree(store) == before)

    before = snapshot_tree(store)
    code, out, err = do("read", store, JQ, os.path.join(tmp, "no-such-receipt.json"),
                         os.path.join(tmp, "out-doesnotmatter.json"))
    record(g, "an unreadable STORAGE_RECEIPT is E_RUNTIME", code == 1 and err == b"E_RUNTIME\n")
    record(g, "store tree unchanged after E_RUNTIME (unreadable receipt)",
           snapshot_tree(store) == before)

    initialize2 = append(store, "boundary.append", tip, scratch, inside_path, session_id, attempt_id)
    receipt_path = os.path.join(tmp, "boundary-receipt.json")
    pathlib.Path(receipt_path).write_bytes(initialize2[1])

    before = snapshot_tree(store)
    in_store_output = os.path.join(store, "leak.json")
    code, out, err = do("read", store, JQ, receipt_path, in_store_output)
    record(g, "OUTPUT inside the store is E_OUTPUT", code == 1 and err == b"E_OUTPUT\n")
    record(g, "store tree unchanged after in-store E_OUTPUT", snapshot_tree(store) == before)

    before = snapshot_tree(store)
    parentless_output = os.path.join(tmp, "does-not-exist-dir", "out.json")
    code, out, err = do("read", store, JQ, receipt_path, parentless_output)
    record(g, "OUTPUT with a missing parent directory is E_OUTPUT", code == 1 and err == b"E_OUTPUT\n")
    record(g, "store tree unchanged after parentless E_OUTPUT", snapshot_tree(store) == before)

    existing_output = os.path.join(tmp, "boundary-existing-output.json")
    with open(existing_output, "wb") as handle:
        handle.write(b"x")
    before = snapshot_tree(store)
    code, out, err = do("read", store, JQ, receipt_path, existing_output)
    record(g, "an existing OUTPUT is E_OUTPUT", code == 1 and err == b"E_OUTPUT\n")
    record(g, "store tree unchanged after existing-OUTPUT E_OUTPUT", snapshot_tree(store) == before)

    symlink_target = os.path.join(tmp, "boundary-symlink-target.json")
    symlink_output = os.path.join(tmp, "boundary-symlink-output.json")
    os.symlink(symlink_target, symlink_output)
    before = snapshot_tree(store)
    code, out, err = do("read", store, JQ, receipt_path, symlink_output)
    record(g, "a symlinked OUTPUT is E_OUTPUT", code == 1 and err == b"E_OUTPUT\n")
    record(g, "store tree unchanged after symlinked-OUTPUT E_OUTPUT", snapshot_tree(store) == before)

    good_output = os.path.join(tmp, "boundary-good-output.json")
    code, out, err = do("read", store, JQ, receipt_path, good_output)
    record(g, "a valid OUTPUT still succeeds after the E_OUTPUT cases", code == 0)

    # E_IDENTITY: a STORE_ID argument that does not match the store's own
    # store.json id. Checked on both a read-only verb (list) and a
    # write-attempting verb (append), neither of which should write.
    before = snapshot_tree(store)
    code, out, err = do("list", store, "boundary.append.wrong")
    record(g, "a STORE_ID argument mismatching the store's own id is E_IDENTITY (list)",
           code == 1 and err == b"E_IDENTITY\n")
    record(g, "store tree unchanged after E_IDENTITY (list)", snapshot_tree(store) == before)

    before = snapshot_tree(store)
    code, out, err = do("append", store, "boundary.append.wrong", tip, scratch, JQ, session_id,
                         attempt_id, inside_path)
    record(g, "a STORE_ID argument mismatching the store's own id is E_IDENTITY (append)",
           code == 1 and err == b"E_IDENTITY\n")
    record(g, "store tree unchanged after E_IDENTITY (append)", snapshot_tree(store) == before)

    # E_NOT_FOUND: a structurally valid, internally self-consistent receipt
    # (correct store id/root_commit, a record_key that matches its own
    # replay_key) whose commit_id simply is not on the chain.
    receipt_doc = json.loads(pathlib.Path(receipt_path).read_bytes())
    missing_doc = json.loads(canonical(receipt_doc))
    missing_doc["body"]["commit_id"] = "f" * 40
    missing_receipt_path = os.path.join(tmp, "boundary-missing-receipt.json")
    with open(missing_receipt_path, "wb") as handle:
        handle.write(canonical(missing_doc))
    before = snapshot_tree(store)
    not_found_output = os.path.join(tmp, "boundary-not-found-out.json")
    code, out, err = do("read", store, JQ, missing_receipt_path, not_found_output)
    record(g, "a well-formed receipt whose commit_id is not on the chain is E_NOT_FOUND",
           code == 1 and err == b"E_NOT_FOUND\n")
    record(g, "store tree unchanged after E_NOT_FOUND", snapshot_tree(store) == before)
    record(g, "no OUTPUT file is created for E_NOT_FOUND", not os.path.exists(not_found_output))

    tampered_source = os.path.join(tmp, "boundary-validator-tree")
    shutil.copytree(REPO, tampered_source,
                     ignore=shutil.ignore_patterns(".git", "node_modules"))
    tampered_validator = os.path.join(tampered_source, "telemetry/v1/validate-trace-ledger.sh")
    with open(tampered_validator, "ab") as handle:
        handle.write(b"\n")
    tampered_product = os.path.join(tampered_source, "telemetry/v1/trace-store.py")
    code, out, err = run(["read", store, JQ, receipt_path, os.path.join(tmp, "tampered-out.json")])
    # This call still uses the real product/validator; a genuine E_VALIDATOR
    # case requires reading a record with the tampered tree's copy of the
    # product, which is exercised below.
    before = snapshot_tree(store)
    proc = subprocess.run([PYTHON, "-I", "-S", "-B", tampered_product, "read", store, JQ,
                            receipt_path, os.path.join(tmp, "tampered-out2.json")],
                           env=dict(ENV), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    record(g, "reading with a validator script that differs by one byte is E_VALIDATOR",
           proc.returncode == 1 and proc.stderr == b"E_VALIDATOR\n")
    record(g, "the real store's tree is unchanged by the tampered-validator-tree E_VALIDATOR case",
           snapshot_tree(store) == before)

    # Mutating the validator script between the pre-run digest check and
    # its own execution (a TOCTOU window) must still be refused: run from a
    # disposable copy of the tree so the mutation never touches the real
    # repository, with `read`'s own run_validator step patched to mutate
    # that copy's validator script immediately before actually running it.
    toctou_tree = os.path.join(tmp, "boundary-toctou-tree")
    shutil.copytree(REPO, toctou_tree, ignore=shutil.ignore_patterns(".git", "node_modules"))
    toctou_product = os.path.join(toctou_tree, "telemetry/v1/trace-store.py")
    toctou_validator = os.path.join(toctou_tree, "telemetry/v1/validate-trace-ledger.sh")
    toctou_wrapper = wrapper_path(tmp, "wrapper-toctou-validator.py")
    write_wrapper(toctou_wrapper, '''
import importlib.util, sys
product_path, validator_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("tracestore", product_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original_run_validator = module.run_validator
def mutated_run_validator(*args, **kwargs):
    with open(validator_path, "ab") as handle:
        handle.write(b"\\n")
    return original_run_validator(*args, **kwargs)
module.run_validator = mutated_run_validator
sys.argv = [product_path] + sys.argv[3:]
raise SystemExit(module.main(sys.argv))
''')
    toctou_out = os.path.join(tmp, "boundary-toctou-out.json")
    before = snapshot_tree(store)
    proc = subprocess.run([PYTHON, "-I", "-S", "-B", toctou_wrapper, toctou_product, toctou_validator,
                            "read", store, JQ, receipt_path, toctou_out],
                           env=dict(ENV), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    record(g, "mutating the validator script between the pre-run digest check and its "
              "own execution is still refused E_VALIDATOR, never silently accepted",
           proc.returncode == 1 and proc.stderr == b"E_VALIDATOR\n")
    record(g, "the mid-run mutation case leaves no OUTPUT file behind",
           not os.path.exists(toctou_out))
    record(g, "the real store's tree is unchanged by the mid-run-mutation E_VALIDATOR case",
           snapshot_tree(store) == before)

    # A case-insensitive filesystem folds a differently-cased spelling of a
    # path onto the same directory entry; identity_overlaps/identity_contains
    # must catch this the same way they catch the leading-slash spellings
    # above, since a plain string comparison cannot. Probe for case
    # insensitivity and skip (with a stated reason) rather than fail outright
    # on a case-sensitive test filesystem (typical on Linux CI).
    probe_dir = os.path.join(tmp, "case-probe-dir")
    os.makedirs(probe_dir, mode=0o700)
    probe_upper = os.path.join(tmp, "CASE-PROBE-DIR")
    try:
        case_insensitive_fs = os.path.samefile(probe_dir, probe_upper)
    except OSError:
        case_insensitive_fs = False
    if not case_insensitive_fs:
        record(g, "differently-cased-path aliasing case skipped: this test filesystem is "
                  "case-sensitive (the leading-slash-spelling cases above already exercise "
                  "identity_overlaps/identity_contains on any filesystem)", True)
    else:
        ci_store = store_root(tmp, "boundary-caseinsensitive-store")
        ci_scratch = scratch_root(tmp, "boundary-caseinsensitive-scratch")
        initialize(ci_store, "boundary.ci")
        ci_ledger = make_ledger("fixture.boundary.ci", session_id, attempt_id,
                                 trace_id="trace.boundary.ci")
        ci_inside_path = os.path.join(ci_scratch, "ledger.json")
        write_ledger(ci_inside_path, ci_ledger)
        ci_tip = tip_of(ci_store, "boundary.ci")

        aliased_store = os.path.join(os.path.dirname(ci_store), os.path.basename(ci_store).upper())
        assert os.path.samefile(ci_store, aliased_store)
        code, out, err = do("append", ci_store, "boundary.ci", ci_tip, aliased_store, JQ,
                             session_id, attempt_id, ci_inside_path)
        record(g, "a differently-cased SCRATCH_ROOT spelling that aliases the store root is "
                  "still E_BOUNDARY (case-insensitive filesystem)",
               code == 1 and err == b"E_BOUNDARY\n")

        code, ci_receipt, err = append(ci_store, "boundary.ci", ci_tip, ci_scratch, ci_inside_path,
                                        session_id, attempt_id)
        record(g, "seed a record in the case-insensitive-alias store", code == 0)
        ci_receipt_path = os.path.join(tmp, "boundary-ci-receipt.json")
        pathlib.Path(ci_receipt_path).write_bytes(ci_receipt)
        aliased_leak = os.path.join(os.path.dirname(ci_store), os.path.basename(ci_store).upper(),
                                     "leak.json")
        code, out, err = do("read", ci_store, JQ, ci_receipt_path, aliased_leak)
        record(g, "a differently-cased OUTPUT spelling of an in-store path is still E_OUTPUT "
                  "(case-insensitive filesystem)",
               code == 1 and err == b"E_OUTPUT\n")

    # A leading run of slashes ("//x" or "///x") aliases the same file as a
    # single leading slash on this filesystem, but posixpath.normpath's own
    # historical special case leaves exactly two leading slashes unchanged,
    # so a naive normpath-idempotency check alone would treat "//store" and
    # "/store" as different, unrelated strings. Every boundary/overlap check
    # (in-store OUTPUT, SCRATCH_ROOT/STORE_ROOT overlap, source-tree
    # overlap) must still catch the aliased spelling.
    assert store.startswith("/") and not store.startswith("//")
    doubled_store = "/" + store  # e.g. "/private/tmp/.../boundary-append-store" -> "//private/..."
    assert os.path.samefile(store, doubled_store)

    doubled_output = os.path.join(doubled_store, "leak-doubled.json")
    code, out, err = do("read", store, JQ, receipt_path, doubled_output)
    record(g, "a doubled-leading-slash OUTPUT spelling of an in-store path is still E_OUTPUT",
           code == 1 and err == b"E_OUTPUT\n")

    triple_output = "/" + doubled_output  # three leading slashes
    code, out, err = do("read", store, JQ, receipt_path, triple_output)
    record(g, "a tripled-leading-slash OUTPUT spelling of an in-store path is still E_OUTPUT",
           code == 1 and err == b"E_OUTPUT\n")

    code, out, err = do("append", store, "boundary.append", tip, doubled_store, JQ,
                         session_id, attempt_id, inside_path)
    record(g, "a doubled-leading-slash SCRATCH_ROOT spelling that aliases the store root "
              "is still E_BOUNDARY",
           code == 1 and err == b"E_BOUNDARY\n")

    outside_ledger_doubled = "/" + outside_ledger
    assert os.path.samefile(outside_ledger, outside_ledger_doubled)
    code, out, err = do("append", store, "boundary.append", tip, scratch, JQ, session_id, attempt_id,
                         outside_ledger_doubled)
    record(g, "a doubled-leading-slash LEDGER spelling outside SCRATCH_ROOT is still E_BOUNDARY",
           code == 1 and err == b"E_BOUNDARY\n")

    doubled_root_store = "/" + os.path.join(REPO, "telemetry")
    assert os.path.samefile(os.path.join(REPO, "telemetry"), doubled_root_store)
    code, out, err = do("initialize", doubled_root_store, "boundary.src.doubled")
    record(g, "a doubled-leading-slash STORE_ROOT spelling of a path inside the source tree "
              "is still E_BOUNDARY",
           code == 1 and err == b"E_BOUNDARY\n")


def test_isolation(tmp):
    g = "P10"
    store = store_root(tmp, "isolation-store")
    scratch = scratch_root(tmp, "isolation-scratch")
    code, out, err = initialize(store, "isolation.store")
    record(g, "baseline initialize for isolation tests", code == 0)
    session_id = "incident.isolation"
    attempt_id = "attempt.shadow-reproduce"
    ledger = make_ledger("fixture.isolation", session_id, attempt_id)
    path = os.path.join(scratch, "ledger.json")
    write_ledger(path, ledger)
    tip = tip_of(store, "isolation.store")

    hostile_home = os.path.join(tmp, "hostile-home")
    os.makedirs(hostile_home, mode=0o700)
    marker = os.path.join(tmp, "isolation-marker")
    with open(os.path.join(hostile_home, ".gitconfig"), "w") as handle:
        handle.write("[core]\n\thooksPath = %s\n[filter \"marker\"]\n\tclean = touch %s\n"
                      "[credential]\n\thelper = !touch %s; echo\n" % (hostile_home, marker, marker))
    hooks_dir = os.path.join(hostile_home, "hooks")
    os.makedirs(hooks_dir, mode=0o700)
    for hook in ("pre-commit", "post-commit"):
        hook_path = os.path.join(hooks_dir, hook)
        with open(hook_path, "w") as handle:
            handle.write("#!/bin/sh\ntouch %s\n" % marker)
        os.chmod(hook_path, 0o755)

    env = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C", "HOME": hostile_home}
    code, clean_receipt, err = append(store, "isolation.store", tip, scratch, path, session_id, attempt_id,
                                       env=None)
    record(g, "baseline (clean HOME) append succeeds", code == 0)
    clean_doc = json.loads(clean_receipt.decode("ascii"))

    # R2.2 does not name HOME among the forbidden prefixes (only GIT_*,
    # XDG_*, PYTHON*, LD_* and DYLD_*), so a caller-supplied HOME is not by
    # itself refused; run a real append with this hostile HOME (holding a
    # global .gitconfig with hooksPath, a clean filter and a credential
    # helper, each configured to touch `marker`) and prove the store never
    # triggers any of it, since it never runs Git.
    store2 = store_root(tmp, "isolation-store-hostile")
    scratch2 = scratch_root(tmp, "isolation-scratch-hostile")
    code, out, err = initialize(store2, "isolation.store2")
    record(g, "hostile-HOME comparison store initializes", code == 0)
    path2 = os.path.join(scratch2, "ledger.json")
    write_ledger(path2, ledger)
    tip2 = tip_of(store2, "isolation.store2")
    code, hostile_receipt, err = append(store2, "isolation.store2", tip2, scratch2, path2,
                                         session_id, attempt_id, env=env)
    record(g, "append under a hostile HOME (hooksPath, filter, credential helper) succeeds",
           code == 0)
    hostile_doc = json.loads(hostile_receipt.decode("ascii"))
    record(g, "hostile-HOME record_key equals the clean-HOME record_key for the same bundle",
           hostile_doc["body"]["record_key"] == clean_doc["body"]["record_key"])
    record(g, "hostile-HOME ledger_ref equals the clean-HOME ledger_ref",
           hostile_doc["body"]["ledger_ref"] == clean_doc["body"]["ledger_ref"])
    record(g, "hostile-HOME validation_sha256 equals the clean-HOME validation_sha256",
           hostile_doc["body"]["validation_sha256"] == clean_doc["body"]["validation_sha256"])
    hostile_receipt_path = os.path.join(tmp, "isolation-hostile-receipt.json")
    pathlib.Path(hostile_receipt_path).write_bytes(hostile_receipt)
    hostile_out_path = os.path.join(tmp, "isolation-hostile-out.json")
    code, out, err = read(store2, hostile_receipt_path, hostile_out_path)
    record(g, "reading the hostile-HOME record succeeds", code == 0)
    record(g, "the hostile-HOME read-back equals the original ledger bytes",
           pathlib.Path(hostile_out_path).read_bytes() == canonical(ledger))
    record(g, "no credential/hook/filter marker exists after the clean-HOME append",
           not os.path.exists(marker))
    record(g, "no credential/hook/filter marker exists after the hostile-HOME append either",
           not os.path.exists(marker))

    # A live DYLD_* variable in a spawned process's actual OS-level
    # environment is intercepted by Darwin's dynamic linker before our
    # interpreter ever starts: dyld aborts the child (SIGABRT) if the named
    # library is missing, surfacing as a macOS crash-report dialog on every
    # test run, not merely a clean non-zero exit. To assert the program's
    # own forbidden-prefix check handles DYLD_* exactly like the other five
    # prefixes, without ever letting dyld see the variable, run it through
    # an indirection: launch the wrapper process itself (with the
    # restricted interpreter flags, but a clean environment, so dyld never
    # intercepts anything at launch), and only once it is already running,
    # inject the forbidden variable into that process's own in-memory
    # os.environ (a plain dict update — it does not re-invoke dyld) before
    # calling the product's main() in-process. Works identically, and for
    # the same reason, on Linux, where DYLD_* is not special at all.
    env_injection_wrapper = wrapper_path(tmp, "wrapper-env-injection.py")
    write_wrapper(env_injection_wrapper, '''
import importlib.util, os, sys
product_path, var, value = sys.argv[1], sys.argv[2], sys.argv[3]
os.environ[var] = value
spec = importlib.util.spec_from_file_location("tracestore", product_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
sys.argv = [product_path] + sys.argv[4:]
raise SystemExit(module.main(sys.argv))
''')

    def run_with_injected_env(var, value, args, timeout=30):
        proc = subprocess.run([PYTHON, "-I", "-S", "-B", env_injection_wrapper, PRODUCT, var, value] +
                               list(args), env=dict(ENV), stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        return proc.returncode, proc.stdout, proc.stderr

    for var, value in (("GIT_DIR", "/tmp/x"), ("GIT_CONFIG_NOSYSTEM", "1"),
                        ("XDG_CONFIG_HOME", "/tmp/x"), ("PYTHONPATH", "/tmp/x"),
                        ("LD_PRELOAD", "/tmp/x.so"), ("DYLD_INSERT_LIBRARIES", "/tmp/x.dylib")):
        before = snapshot_tree(store)
        code, out, err = run_with_injected_env(var, value, ["list", store, "isolation.store"])
        record(g, "forbidden variable %s present at start is E_USAGE" % var,
               code == 1 and err == b"E_USAGE\n")
        record(g, "store tree unchanged after E_USAGE (%s)" % var, snapshot_tree(store) == before)


def test_canonical_static(tmp):
    g = "P11"
    store = store_root(tmp, "canonical-store")
    scratch = scratch_root(tmp, "canonical-scratch")
    code, out, err = initialize(store, "canonical.store")
    record(g, "initialize output is canonical", code == 0)
    doc = out
    canon = subprocess.run([JQ, "-S", "-c", "."], input=doc, stdout=subprocess.PIPE)
    record(g, "initialize output equals pinned jq -S -c of itself", canon.stdout == doc)

    session_id = "incident.canonical"
    attempt_id = "attempt.shadow-reproduce"
    ledger = make_ledger("fixture.canonical", session_id, attempt_id)
    path = os.path.join(scratch, "ledger.json")
    write_ledger(path, ledger)
    tip = tip_of(store, "canonical.store")
    code, receipt, err = append(store, "canonical.store", tip, scratch, path, session_id, attempt_id)
    canon = subprocess.run([JQ, "-S", "-c", "."], input=receipt, stdout=subprocess.PIPE)
    record(g, "append receipt equals pinned jq -S -c of itself", canon.stdout == receipt)

    code, listed, err = listing(store, "canonical.store")
    canon = subprocess.run([JQ, "-S", "-c", "."], input=listed, stdout=subprocess.PIPE)
    record(g, "list output equals pinned jq -S -c of itself", canon.stdout == listed)

    receipt_path = os.path.join(tmp, "canonical-receipt.json")
    pathlib.Path(receipt_path).write_bytes(receipt)
    out_path = os.path.join(tmp, "canonical-out.json")
    code, read_out, err = read(store, receipt_path, out_path)
    canon = subprocess.run([JQ, "-S", "-c", "."], input=read_out, stdout=subprocess.PIPE)
    record(g, "read output equals pinned jq -S -c of itself", canon.stdout == read_out)

    import ast
    source = pathlib.Path(PRODUCT).read_text()
    tree = ast.parse(source)
    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imported.add(alias.name.split(".")[0])
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                imported.add(node.module.split(".")[0])
    expected = {"errno", "fcntl", "hashlib", "json", "os", "re", "select", "signal",
                "subprocess", "sys", "zlib"}
    record(g, "the program imports exactly the R2.5 module set", imported == expected)
    record(g, "the program does not import socket", "socket" not in imported)
    bash_literals = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and node.value == "/bin/bash":
            bash_literals.add(node.value)
    record(g, "/bin/bash is the only executable path literal the program names",
           bash_literals == {"/bin/bash"})


def test_git_interop(tmp):
    g = "P12"
    store = store_root(tmp, "gitinterop-store")
    scratch = scratch_root(tmp, "gitinterop-scratch")
    initialize(store, "gitinterop.store")
    session_id = "incident.gitinterop"
    attempt_id = "attempt.shadow-reproduce"
    ledger = make_ledger("fixture.gitinterop", session_id, attempt_id)
    path = os.path.join(scratch, "ledger.json")
    write_ledger(path, ledger)
    tip = tip_of(store, "gitinterop.store")
    code, receipt, err = append(store, "gitinterop.store", tip, scratch, path, session_id, attempt_id)
    record(g, "seed a record for git interoperability checks", code == 0)
    before = snapshot_tree(store)

    closed_copy = os.path.join(tmp, "gitinterop-closed-copy")
    shutil.copytree(store, closed_copy)
    empty_home = os.path.join(tmp, "gitinterop-empty-home")
    os.makedirs(empty_home, mode=0o700)
    git_env = {"HOME": empty_home, "PATH": "/usr/bin:/bin", "LC_ALL": "C",
               "GIT_CONFIG_NOSYSTEM": "1"}
    git_dir = os.path.join(closed_copy, "repository.git")
    proc = subprocess.run([GIT, "--git-dir", git_dir, "fsck", "--strict"],
                           env=git_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    record(g, "git fsck --strict accepts the closed store", proc.returncode == 0)

    proc = subprocess.run([GIT, "--git-dir", git_dir, "rev-list", "--parents", "refs/heads/records"],
                           env=git_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    record(g, "git rev-list shows exact linear history", proc.returncode == 0)
    lines = proc.stdout.decode("ascii").strip().split("\n")
    record(g, "each history line has at most one parent",
           all(len(line.split()) <= 2 for line in lines))

    proc = subprocess.run([GIT, "--git-dir", git_dir, "cat-file", "--batch-check", "--batch-all-objects"],
                           env=git_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    record(g, "git cat-file reads every blob, tree and commit", proc.returncode == 0 and proc.stdout)

    record(g, "the original store tree is unchanged by the git-interoperability checks",
           snapshot_tree(store) == before)


if __name__ == "__main__":
    main()
PY
"$python" -I -S -B "$tmp/harness.py" "$product" "$python" "$git_bin" "$tmp/bin/jq" "$root"
