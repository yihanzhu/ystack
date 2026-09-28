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


if __name__ == "__main__":
    main()
PY
"$python" -I -S -B "$tmp/harness.py" "$product" "$python" "$git_bin" "$tmp/bin/jq" "$root"
