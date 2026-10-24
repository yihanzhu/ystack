#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ystack-publisher-admission.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
sha_file() { shasum -a 256 "$1" | awk '{print $1}'; }
_admission_package_closure() {
  "$python_bin" -I -S -B - "$1" "$2" "$3" <<'PY_ADMISSION_CLOSURE'
import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import sys

package = Path(sys.argv[1])
site, route = sys.argv[2:]
helper = package / "publisher/v1/_admission.py"
assert package.resolve() == package
for path in (helper, helper.parent, helper.parent.parent):
    assert not path.is_symlink()
assert helper.is_file() and stat.S_IMODE(helper.stat().st_mode) == 0o644
original = helper.read_bytes()
original_mode = stat.S_IMODE(helper.stat().st_mode)
source_hash = hashlib.sha256(original).hexdigest()
names = ("ystack_shadow_enforced", "ystack_shadow_consumer", "ystack_publisher_admission",
         "admission_site_writer", "admission_site_reader", "scope_shadow_consumer", "scope_shadow_writer")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def actual_load():
    before = {name: sys.modules.pop(name, None) for name in names}
    owned = []
    try:
        if route == "writer":
            writer = load("admission_site_writer", package / "shadow/v1/write-shadow.py")
        else:
            module = load("admission_site_reader", package / "scope/v1/read-shadow-evidence.py")
            reader = object.__new__(module._Reader)
            reader.owned, reader.inputs, reader.anchor = [], [], None
            reader.package_sources = dict()
            # This is the real reader loader with its actual held package sources.
            for relative in ("publisher/v1/_admission.py", "shadow/v1/write-shadow.py", "shadow/v1/enforced-reproduction.py"):
                item = module.c._hold_bytes(str(package / relative), module.c.EXECUTABLE_LIMIT)
                owned.append(item)
                reader.owned.append(item)
                reader.package_sources[relative] = item
            writer = reader.load_writer()
            reader.recheck()
        owned.append(writer._ADMISSION_SOURCE)
        assert writer._ADMISSION_SOURCE.raw == original
        assert writer._ADMISSION_SHA256 == source_hash
        assert writer.a.c is writer.e.c is writer.c
        assert Path(writer.a.__file__).absolute() == helper
        assert writer.a.__spec__.origin == str(helper)
        writer._ADMISSION_SOURCE.recheck("E_RUNTIME")
    finally:
        for item in reversed(owned):
            item.close()
        for name, previous in before.items():
            if previous is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = previous


def receipt(suffix, phase, actual):
    print("ADMISSION-CLOSURE", json.dumps(dict(case_id=site+suffix, phase=phase, route=route,
        package=str(package), source_sha256=source_hash, expected="REFUSE" if phase=="mutation" else "OK",
        exit=1 if phase=="mutation" else 0, stdout="", stderr="", actual=actual, marker_written=False,
        classification="owned package source closure; original site assertions retained"), sort_keys=True), flush=True)


actual_load()
receipt("a", "exact-helper-after-original-site-assertions", "OK")
for suffix, mutation in (("b", "missing"), ("c", "altered")):
    actual_load()
    receipt(suffix, "baseline", "OK")
    if mutation == "missing":
        helper.unlink()
    else:
        helper.chmod(0o600)
        helper.write_bytes(original + b"\n")
        helper.chmod(original_mode)
    try:
        try:
            actual_load()
        except BaseException as exc:
            assert isinstance(exc, (OSError, SystemExit)) or type(exc).__name__ == "Refusal", type(exc)
            receipt(suffix, "mutation", "REFUSE")
        else:
            raise AssertionError(site + suffix + " changed helper accepted")
    finally:
        helper.write_bytes(original)
        helper.chmod(original_mode)
    actual_load()
    receipt(suffix, "restored", "OK")
assert hashlib.sha256(helper.read_bytes()).hexdigest() == source_hash
print("ADMISSION-CLOSURE", site, "total=3 expected=3 passed=3", flush=True)
PY_ADMISSION_CLOSURE
}

case "$(uname -s):$(uname -m)" in
  Darwin:*) asset=jq-osx-amd64; digest=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) asset=jq-linux64; digest=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) fail 'unsupported pinned runtime platform' ;;
esac
jq_bin="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$asset"
[ -f "$jq_bin" ] && [ ! -L "$jq_bin" ] && [ "$(sha_file "$jq_bin")" = "$digest" ] ||
  fail 'pinned jq cache unavailable; functional NOT RUN'
python_bin=$(command -v python3)
"$python_bin" -I -S -B - "$root" "$tmp" <<'PY_ADMISSION'
from __future__ import annotations
import copy
import dataclasses
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import time

root, area = map(Path, sys.argv[1:])
assert root.resolve() == root and area.resolve() == area
assert sys.version_info >= (3, 11)

# Expectations are literal rows frozen from the accepted finite table.
CASES = {
    'A01': ('W', 'OK', '32-form reaches common call, preserves exact old bytes and withheld result'),
    'A02': ('W', 'OK', '33-form reaches common call, policy bytes/ref and withheld result match'),
    'A03': ('W', 'REFUSE', 'Target common-call refusal propagates before completion'),
    'A04': ('W', 'CAUGHT-MISSING-CALL', 'In owned copy remove only final shared call: A03 required-refusal assertion fails; valid baseline passes'),
    'A05': ('A', 'REFUSE', 'Legal different target_repository_id'),
    'A06': ('A', 'REFUSE', 'Legal different branch'),
    'A07': ('A', 'REFUSE', 'Legal different base_revision'),
    'A08': ('A', 'REFUSE', 'Legal different candidate_tree_id'),
    'A09': ('A', 'REFUSE', 'Legal different title'),
    'A10': ('A', 'REFUSE', 'Different held body with recomputed body_sha256'),
    'A11': ('A', 'REFUSE', 'Envelope incident ID mismatch'),
    'A12': ('A', 'REFUSE', 'Outer scope mismatch'),
    'A13': ('A', 'REFUSE', 'Actual stage workflow mismatch'),
    'A14': ('A', 'REFUSE', 'Actual stage task mismatch'),
    'A15': ('A', 'REFUSE', 'Wrong actual candidate bytes despite coherent claimed rows'),
    'A16': ('A', 'REFUSE', 'Body missing final LF'),
    'A17': ('A', 'REFUSE', 'Body extra final LF'),
    'A18': ('A', 'REFUSE', 'Stale body hash'),
    'A19': ('A', 'REFUSE', 'Wrong canonical request digest'),
    'A20': ('A', 'REFUSE', 'Wrong canonical write-set digest'),
    'A21': ('A', 'REFUSE', 'Changed frozen bundle marker and recomputed surrounding references'),
    'A22': ('A', 'REFUSE', 'Inner marker substituted for outer marker'),
    'A23': ('A', 'REFUSE', 'Outer marker substituted for frozen marker'),
    'A24': ('A', 'REFUSE', 'Altered policy bytes with recomputed outer hashes (33)'),
    'A25': ('A', 'REFUSE', 'Wrong policy reference size with matching name/hash (33)'),
    'A26': ('A', 'REFUSE', 'Backfilled policy in old 32 form'),
    'A27': ('A', 'REFUSE', 'Mixed candidate/outer forms'),
    'A28': ('A', 'REFUSE', 'Extra candidate leaf'),
    'A29': ('A', 'REFUSE', 'Wrong incident root'),
    'A30': ('A', 'REFUSE', 'Case alias of required filename'),
    'A31': ('A', 'REFUSE', 'Nested candidate filename'),
    'A32': ('A', 'REFUSE', 'Duplicate write row'),
    'A33': ('A', 'REFUSE', 'Unsorted write rows'),
    'A34': ('A', 'REFUSE', 'Wrong exact allowed_paths'),
    'A35': ('A', 'REFUSE', 'Changed actual seed differs from retained converter output'),
    'A36': ('A', 'REFUSE', 'Changed README bytes'),
    'A37': ('A', 'REFUSE', 'Publication reports anything other than exact withheld record'),
    'A38': ('A', 'REFUSE', 'Admission record adds authority or changes effect-none'),
    'A39': ('A', 'REFUSE', 'Post-write plan base differs'),
    'A40': ('A', 'REFUSE', 'Post-write plan tree differs'),
    'A41': ('A', 'REFUSE', 'Post-write plan rows differ'),
    'G01': ('G', 'OK', 'Both forms pass actual SHA-1 object database'),
    'G02': ('G', 'OK', 'Both forms pass actual SHA-256 object database'),
    'G03': ('G', 'REFUSE', 'Candidate equals base'),
    'G04': ('G', 'REFUSE', 'Candidate has zero parents'),
    'G05': ('G', 'REFUSE', 'Candidate has two parents'),
    'G06': ('G', 'REFUSE', 'Candidate has one wrong parent'),
    'G07': ('G', 'REFUSE', 'Actual root tree differs from claimed tree'),
    'G08': ('G', 'REFUSE', 'Unrelated existing leaf changed'),
    'G09': ('G', 'REFUSE', 'Unrelated existing leaf deleted'),
    'G10': ('G', 'REFUSE', 'Unrelated existing leaf mode changed'),
    'G11': ('G', 'REFUSE', 'Unrelated existing leaf type changed'),
    'G12': ('G', 'REFUSE', 'Extra added leaf'),
    'G13': ('G', 'REFUSE', 'Extra added empty tree'),
    'G14': ('G', 'REFUSE', 'Incident root already exists at base'),
    'G15': ('G', 'REFUSE', 'Case-folded incident-root alias exists at base'),
    'G16': ('G', 'REFUSE', 'Base root has descendant under incident root'),
    'G17': ('G', 'REFUSE', 'Existing evidence ancestor is a non-tree'),
    'G18': ('G', 'REFUSE', 'Existing evidence ancestor has a case alias'),
    'G19': ('G', 'REFUSE', 'Candidate added symlink'),
    'G20': ('G', 'REFUSE', 'Candidate added submodule'),
    'G21': ('G', 'REFUSE', 'Candidate added executable'),
    'G22': ('G', 'REFUSE', 'Wrong actual row SHA-256'),
    'G23': ('G', 'REFUSE', 'Wrong native row blob OID'),
    'G24': ('G', 'REFUSE', 'Truncated held raw blob/size mismatch'),
    'G25': ('G', 'REFUSE', 'Source inventory changed since captured snapshot'),
    'G26': ('G', 'REFUSE', 'Source repository identity differs from incident'),
    'G27': ('G', 'REFUSE', 'Candidate object algorithm differs'),
    'G28': ('G', 'OK', 'Exactly 1,048,576-byte actual patch passes'),
    'G29': ('G', 'REFUSE', '1,048,577-byte actual patch refuses'),
    'G30': ('G', 'REFUSE', 'Non-UTF-8 candidate blob'),
    'G31': ('G', 'REFUSE', 'NUL/binary candidate blob'),
    'G32': ('G', 'REFUSE', 'Forbidden control in otherwise UTF-8 blob'),
    'L01': ('A', 'REFUSE', 'Path .git segment'),
    'L02': ('A', 'REFUSE', 'Path .ystack segment'),
    'L03': ('A', 'REFUSE', 'Traversal segment'),
    'L04': ('A', 'REFUSE', 'Case alias of protected segment'),
    'L05': ('A', 'REFUSE', 'Held policy protected prefix'),
    'L06': ('A', 'REFUSE', 'Held policy protected root filename via actual write_path_ok'),
    'L07': ('A', 'REFUSE', 'Held policy protected segment'),
    'L08': ('A', 'REFUSE', 'Held mode forbidden path'),
    'L09': ('A', 'REFUSE', 'Held mode forbidden prefix'),
    'L10': ('A', 'REFUSE', 'Absolute path'),
    'L11': ('A', 'REFUSE', 'Backslash path'),
    'L12': ('A', 'REFUSE', 'Empty path segment'),
    'L13': ('A', 'REFUSE', 'Trailing-dot segment'),
    'L14': ('A', 'REFUSE', 'Trailing-space segment'),
    'L15': ('A', 'REFUSE', 'Control-character path'),
    'L16': ('A', 'BOUNDARY', '4096-byte path primitive passes; 4097 refuses'),
    'L17': ('A', 'BOUNDARY', '64-segment primitive passes when otherwise valid; 65 refuses'),
    'I01': ('A', 'REFUSE', 'Incident uppercase'),
    'I02': ('A', 'REFUSE', 'Incident starts punctuation'),
    'I03': ('A', 'REFUSE', 'Incident contains double dot'),
    'I04': ('A', 'REFUSE', 'Incident ends dot'),
    'I05': ('A', 'REFUSE', 'Incident ends .lock'),
    'I06': ('A', 'REFUSE', 'Incident exceeds 128 characters'),
    'I07': ('A', 'REFUSE', 'Incident slash/branch escape'),
    'C01': ('C', 'REFUSE', 'Missing helper'),
    'C02': ('C', 'REFUSE', 'Missing writer pin'),
    'C03': ('C', 'REFUSE', 'Wrong writer pin'),
    'C04': ('C', 'REFUSE', 'Wrong module origin'),
    'C05': ('C', 'REFUSE', 'Symlink helper leaf'),
    'C06': ('C', 'REFUSE', 'Symlink publisher parent'),
    'C07': ('C', 'REFUSE', 'Symlink v1 parent'),
    'C08': ('C', 'REFUSE', 'Helper changed before admission'),
    'C09': ('C', 'REFUSE', 'Helper changed after admission before marker'),
    'C10': ('C', 'REFUSE', 'Held source Git changed after admission'),
    'C11': ('C', 'REFUSE', 'Held candidate Git changed after admission'),
    'C12': ('C', 'REFUSE', 'Held body changed after admission'),
    'C13': ('C', 'REFUSE', 'Foreign consumer instance'),
    'C14': ('C', 'REFUSE', 'Foreign callback/runner field refused by closed input shape'),
    'C15': ('C', 'REFUSE', 'Concrete Git-owner substitution refuses'),
    'M01': ('A', 'REFUSE', 'Remove required candidate `accepted-identities.json`; both forms'),
    'M02': ('A', 'REFUSE', 'Remove required candidate `claim.json`; both forms'),
    'M03': ('A', 'REFUSE', 'Remove required candidate `consumer-provenance.json`; both forms'),
    'M04': ('A', 'REFUSE', 'Remove required candidate `decision.json`; both forms'),
    'M05': ('A', 'REFUSE', 'Remove required candidate `duty-evaluation.json`; both forms'),
    'M06': ('A', 'REFUSE', 'Remove required candidate `evaluator-driver.txt`; both forms'),
    'M07': ('A', 'REFUSE', 'Remove required candidate `evaluator-program.txt`; both forms'),
    'M08': ('A', 'REFUSE', 'Remove required candidate `evidence-manifest.json`; both forms'),
    'M09': ('A', 'REFUSE', 'Remove required candidate `file-digest-result.json`; both forms'),
    'M10': ('A', 'REFUSE', 'Remove required candidate `incident.json`; both forms'),
    'M11': ('A', 'REFUSE', 'Remove required candidate `materialization-input.json`; both forms'),
    'M12': ('A', 'REFUSE', 'Remove required candidate `materialization-response.json`; both forms'),
    'M13': ('A', 'REFUSE', 'Remove required candidate `origin-observation.json`; both forms'),
    'M14': ('A', 'REFUSE', 'Remove required candidate `payload-stderr.txt`; both forms'),
    'M15': ('A', 'REFUSE', 'Remove required candidate `payload-stdout.txt`; both forms'),
    'M16': ('A', 'REFUSE', 'Remove required candidate `policy-set.json`; both forms'),
    'M17': ('A', 'REFUSE', 'Remove required candidate `policy.json`; both forms'),
    'M18': ('A', 'REFUSE', 'Remove required candidate `preparation-manifest.json`; both forms'),
    'M19': ('A', 'REFUSE', 'Remove required candidate `preparation-record.json`; both forms'),
    'M20': ('A', 'REFUSE', 'Remove required candidate `qualified-identity.json`; both forms'),
    'M21': ('A', 'REFUSE', 'Remove required candidate `registry.json`; both forms'),
    'M22': ('A', 'REFUSE', 'Remove required candidate `sandbox-check.json`; both forms'),
    'M23': ('A', 'REFUSE', 'Remove required candidate `sandbox-evaluation.json`; both forms'),
    'M24': ('A', 'REFUSE', 'Remove required candidate `sandbox-expectation.json`; both forms'),
    'M25': ('A', 'REFUSE', 'Remove required candidate `sandbox-receipt.json`; both forms'),
    'M26': ('A', 'REFUSE', 'Remove required candidate `sandbox-request.json`; both forms'),
    'M27': ('A', 'REFUSE', 'Remove required candidate `shadow-record.json`; both forms'),
    'M28': ('A', 'REFUSE', 'Remove required candidate `trace-ledger.json`; both forms'),
    'M29': ('A', 'REFUSE', 'Remove required candidate `trace-receipt.json`; both forms'),
    'M30': ('A', 'REFUSE', 'Remove required candidate `bundle.json`; both forms'),
    'M31': ('A', 'REFUSE', 'Remove required candidate `eval-seed.json`; both forms'),
    'M32': ('A', 'REFUSE', 'Remove required candidate `README.md`; both forms'),
    'M33': ('A', 'REFUSE', 'Remove required candidate `scope-policy.json`; 33 form'),
    'Q1a': ('C', 'OK', 'Exact helper reaches original intended assertions at Q1'),
    'Q1b': ('C', 'REFUSE', 'Missing helper refuses at actual closure at Q1'),
    'Q1c': ('C', 'REFUSE', 'Altered helper refuses at actual closure at Q1'),
    'Q2a': ('C', 'OK', 'Exact helper reaches original intended assertions at Q2'),
    'Q2b': ('C', 'REFUSE', 'Missing helper refuses at actual closure at Q2'),
    'Q2c': ('C', 'REFUSE', 'Altered helper refuses at actual closure at Q2'),
    'Q3a': ('C', 'OK', 'Exact helper reaches original intended assertions at Q3'),
    'Q3b': ('C', 'REFUSE', 'Missing helper refuses at actual closure at Q3'),
    'Q3c': ('C', 'REFUSE', 'Altered helper refuses at actual closure at Q3'),
    'Q4a': ('C', 'OK', 'Exact helper reaches original intended assertions at Q4'),
    'Q4b': ('C', 'REFUSE', 'Missing helper refuses at actual closure at Q4'),
    'Q4c': ('C', 'REFUSE', 'Altered helper refuses at actual closure at Q4'),
    'S1a': ('C', 'OK', 'Exact helper reaches original intended assertions at S1'),
    'S1b': ('C', 'REFUSE', 'Missing helper refuses at actual closure at S1'),
    'S1c': ('C', 'REFUSE', 'Altered helper refuses at actual closure at S1'),
    'S2a': ('C', 'OK', 'Exact helper reaches original intended assertions at S2'),
    'S2b': ('C', 'REFUSE', 'Missing helper refuses at actual closure at S2'),
    'S2c': ('C', 'REFUSE', 'Altered helper refuses at actual closure at S2'),
    'S3a': ('C', 'OK', 'Exact helper reaches original intended assertions at S3'),
    'S3b': ('C', 'REFUSE', 'Missing helper refuses at actual closure at S3'),
    'S3c': ('C', 'REFUSE', 'Altered helper refuses at actual closure at S3'),
}
assert len(CASES) == 166


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


c = load("ystack_shadow_consumer", root / "shadow/v1/_consumer.py")
a = load("ystack_publisher_admission", root / "publisher/v1/_admission.py")
assert a.c is c
canonical, digest = c.canonical, c.digest
receipts = area / "receipts"
receipts.mkdir()
serial = 0


def command(argv, raw=b"", *, env=None, checked=True):
    global serial
    serial += 1
    prefix = receipts / ("command-%06d" % serial)
    record = {"argv": list(map(str, argv)), "start_ns": time.time_ns()}
    result = subprocess.run(argv, input=raw, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=60)
    prefix.with_suffix(".stdout").write_bytes(result.stdout)
    prefix.with_suffix(".stderr").write_bytes(result.stderr)
    record.update(exit=result.returncode, end_ns=time.time_ns(),
                  stdin_sha256=digest(raw))
    prefix.with_suffix(".json").write_bytes(canonical(record))
    if checked:
        assert result.returncode == 0, (argv, result.stderr)
    return result


# Exercise the runner's actual function, before any local positive can fill CI objects.
runner_raw = (root / "scripts/test/portable-core-v3-publisher.test.sh").read_bytes()
start = runner_raw.index(b"_original_plan_provenance() {\n")
end = runner_raw.index(b"\nstatic_case() {", start)
function_raw = runner_raw[start:end]
assert runner_raw.count(b"_original_plan_provenance() {") == 1
assert runner_raw.count(b"      _original_plan_provenance || fail") == 1
(receipts / "provenance-function.raw").write_bytes(function_raw)
provenance_ids = set()


def provenance(ident, checkout, *, altered=None, environment=None, expected="OK"):
    destination = area / (ident + "-provenance")
    destination.mkdir()
    function = function_raw if altered is None else altered
    script = destination / "function.sh"
    script.write_bytes(function + b"\n_original_plan_provenance\n")
    env = dict(os.environ if environment is None else environment)
    # Both globals are shell variables, never a public predicate argument.
    invocation = 'root="$1"; tmp="$2"; source "$3"'
    result = command(["/bin/bash", "-c", invocation, "original-plan", str(checkout), str(destination), str(script)], env=env, checked=False)
    good = result.returncode == 0
    assert good == (expected == "OK"), (ident, result.stderr)
    details = json.loads((destination / "original-plan-provenance/receipt.json").read_bytes())
    target_reasons = {"P03": "original plan tree/blob pin", "P04": "original raw bytes", "P05": "original plan tree/blob pin"}
    if ident in target_reasons:
        assert details.get("reason") == target_reasons[ident], (ident, details)
    if ident != "P07":
        assert details["fetch_count"] == 0
    provenance_ids.add(ident)
    record = {"case_id": ident, "route": "P", "expected": expected,
              "exit": result.returncode, "function_sha256": digest(function),
              "actual_function_sha256": digest(function_raw)}
    (receipts / (ident + ".json")).write_bytes(canonical(record))
    print("PROVENANCE", ident, expected, "PASS", flush=True)
    return destination


no_ci = {key: value for key, value in os.environ.items() if not key.startswith("GITHUB_")}
original_commit = "c6c3f74181ea86f85be87ecf4431e67a5f272d82"
probe_env = dict(os.environ, GIT_NO_LAZY_FETCH="1", GIT_NO_REPLACE_OBJECTS="1")
shallow = command(["git", "-C", str(root), "rev-parse", "--is-shallow-repository"]).stdout == b"true\n"
if os.environ.get("GITHUB_ACTIONS") == "true" and shallow:
    receipt = provenance("P07", root)
    details = json.loads((receipt / "original-plan-provenance/receipt.json").read_bytes())
    if details["fetch_count"] != 1:
        print("PROVENANCE P07 NOTRUN original objects already present; needs authorized normal shallow CI", flush=True)
        raise AssertionError("P07 missing-object fixed-read proof NOTRUN")
    assert details["status"] == "OK"
else:
    provenance_ids.add("P07")
    print("PROVENANCE P07 NOTRUN outside normal shallow exact CI; no fetch", flush=True)


# Separate local databases never inherit checkout credentials or remote object access.
def git(repository, *arguments, raw=b""):
    return command(["/usr/bin/git", "--no-replace-objects", "--git-dir=" + str(repository), *arguments], raw,
        env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "HOME": str(area)}).stdout


def bare(name, algorithm="sha1"):
    path = area / name
    command(["/usr/bin/git", "init", "--bare", "--object-format=" + algorithm, str(path)],
        env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "HOME": str(area)})
    return path


missing = bare("provenance-missing.git")
git(missing, "config", "remote.origin.url", "https://github.com/yihanzhu/ystack.git")
empty_tree = git(missing, "mktree").decode().strip()
commit_raw = ("tree " + empty_tree + "\nauthor Fixture <fixture@example.invalid> 1 +0000\n"
              "committer Fixture <fixture@example.invalid> 1 +0000\n\ncurrent fixture\n").encode()
current = git(missing, "hash-object", "-w", "-t", "commit", "--stdin", raw=commit_raw).decode().strip()
git(missing, "update-ref", "refs/heads/main", current)
git(missing, "symbolic-ref", "HEAD", "refs/heads/main")
(missing / "shallow").write_text(current + "\n")
provenance("P02", missing, environment=no_ci, expected="REFUSE")
full = bare("provenance-full.git")
git(full, "config", "remote.origin.url", "https://github.com/yihanzhu/ystack.git")
head = command(["git", "-C", str(root), "rev-parse", "HEAD"]).stdout.strip()
pack = command(["git", "--no-replace-objects", "-C", str(root), "pack-objects", "--stdout", "--revs"],
    head + b"\n" + original_commit.encode() + b"\n", env=probe_env).stdout
git(full, "unpack-objects", raw=pack)
git(full, "update-ref", "refs/heads/main", head.decode())
git(full, "symbolic-ref", "HEAD", "refs/heads/main")
provenance("P01", full, environment=no_ci)
assert command(["git", "-C", str(root), "hash-object", "work/fixed-evidence-publication/plan.md"]).stdout.strip() != b"d8aa60b213cf7fce29c386b0eac49401c36643ff"
provenance("P03", full, altered=function_raw.replace(b'blob_pin = "d8aa60b213cf7fce29c386b0eac49401c36643ff"', b'blob_pin = "0000000000000000000000000000000000000000"'), environment=no_ci, expected="REFUSE")
provenance("P04", full, altered=function_raw.replace(b'raw_pin = "810ec947448c9731d1cb47e3acb0f26e7e7fe11e982b36b25caaf2a13f4ae4e3"', b'raw_pin = "' + b'0' * 64 + b'"'), environment=no_ci, expected="REFUSE")
parent = head
provenance("P05", full, altered=function_raw.replace(b'commit = "' + original_commit.encode() + b'"', b'commit = "' + parent + b'"'), environment=no_ci, expected="REFUSE")
# Missing required original tree/blob is a distinct object state, not a checkout deletion.
broken = bare("provenance-missing-tree.git")
git(broken, "config", "remote.origin.url", "https://github.com/yihanzhu/ystack.git")
original_raw = command(["git", "--no-replace-objects", "-C", str(root), "cat-file", "commit", original_commit], env=probe_env).stdout
assert git(broken, "hash-object", "-w", "-t", "commit", "--stdin", raw=original_raw).strip() == original_commit.encode()
git(broken, "update-ref", "refs/heads/main", original_commit)
git(broken, "symbolic-ref", "HEAD", "refs/heads/main")
provenance("P06", broken, environment=no_ci, expected="REFUSE")
for label, urls in (("wrong", ["https://example.invalid/other.git"]),
                    ("multiple", ["https://github.com/yihanzhu/ystack.git", "https://github.com/yihanzhu/ystack"])):
    destination = area / ("origin-" + label + ".git")
    shutil.copytree(missing, destination)
    git(destination, "config", "--unset-all", "remote.origin.url")
    for url in urls:
        git(destination, "config", "--add", "remote.origin.url", url)
    provenance("P08-" + label, destination, environment=no_ci, expected="REFUSE")
provenance_ids.discard("P08-wrong")
provenance_ids.discard("P08-multiple")
provenance_ids.add("P08")
for label in ("partial", "promisor", "alternate", "replace", "graft", "environment"):
    destination = area / ("indirection-" + label + ".git")
    shutil.copytree(missing, destination)
    environment = dict(no_ci)
    if label == "partial":
        git(destination, "config", "extensions.partialClone", "origin")
    elif label == "promisor":
        (destination / "objects/pack/fake.promisor").write_bytes(b"")
    elif label == "alternate":
        (destination / "objects/info/alternates").write_text(str(missing / "objects") + "\n")
    elif label == "replace":
        (destination / "refs/replace").mkdir()
    elif label == "graft":
        (destination / "info/grafts").write_text(current + "\n")
    else:
        environment["GIT_OBJECT_DIRECTORY"] = str(missing / "objects")
    ident = "P09-" + label
    receipt = provenance(ident, destination, environment=environment, expected="REFUSE")
    details = json.loads((receipt / "original-plan-provenance/receipt.json").read_bytes())
    assert details["fetch_count"] == 0
    assert not any("cat-file" in row["argv"] or "fetch" in row["argv"] for row in details["commands"])
    provenance_ids.discard(ident)
provenance_ids.add("P09")
assert provenance_ids == {"P%02d" % index for index in range(1, 10)}
print("PROVENANCE total=9 expected=9 accounted=9; P07 retains its actual classification", flush=True)


class Ledger:
    def __init__(self, directory):
        self.directory = directory
        self.inputs = []
        self.commands = []
        self.deadline = time.monotonic() + 120

    def capture(self, name, raw):
        path = self.directory / name
        assert not path.exists()
        path.write_bytes(raw)
        self.inputs.append((path, raw))
        return path

    def execute_git(self, argv, limit):
        assert argv[0] == "/usr/bin/git"
        self.commands.append(list(argv))
        result = command(argv, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1", "HOME": str(area)}, checked=False)
        assert result.returncode == 0, result.stderr
        if len(result.stdout) > limit:
            raise c.Refusal("E_LIMIT")
        return result.stdout


NAMES = (
    "accepted-identities.json", "claim.json", "consumer-provenance.json", "decision.json",
    "duty-evaluation.json", "evaluator-driver.txt", "evaluator-program.txt",
    "evidence-manifest.json", "file-digest-result.json", "incident.json",
    "materialization-input.json", "materialization-response.json", "origin-observation.json",
    "payload-stderr.txt", "payload-stdout.txt", "policy-set.json", "policy.json",
    "preparation-manifest.json", "preparation-record.json", "qualified-identity.json",
    "registry.json", "sandbox-check.json", "sandbox-evaluation.json",
    "sandbox-expectation.json", "sandbox-receipt.json", "sandbox-request.json",
    "shadow-record.json", "trace-ledger.json", "trace-receipt.json",
)
assert NAMES == c.SHADOW_EVIDENCE_NAMES
README = b"Shadow evidence. Publication is withheld.\n"
POLICY = (root / "scope/v1/scope-policy.json").read_bytes()
MODE = (root / "config/construction-mode.json").read_bytes()


def native_oid(raw, kind, algorithm):
    return hashlib.new(algorithm, (kind + " " + str(len(raw)) + "\0").encode() + raw).hexdigest()


def object_write(repository, kind, raw):
    return git(repository, "hash-object", "-w", "-t", kind, "--stdin", raw=raw).decode().strip()


def tree_write(repository, entries):
    directories = {}
    for path, row in entries.items():
        current = directories
        segments = path.split("/")
        for segment in segments[:-1]:
            current = current.setdefault(segment, {})
        assert segments[-1] not in current
        current[segments[-1]] = row

    def emit(directory):
        rows = []
        for name, row in directory.items():
            if isinstance(row, dict):
                mode, kind, oid = "040000", "tree", emit(row)
            else:
                mode, kind, oid = row
            rows.append((name, mode, kind, oid))
        raw = b"".join((mode + " " + kind + " " + oid + "\t" + name).encode() + b"\0"
                       for name, mode, kind, oid in sorted(rows))
        return git(repository, "mktree", "-z", raw=raw).decode().strip()
    return emit(directories)


def commit_write(repository, tree, parents):
    raw = ("tree " + tree + "\n" + "".join("parent " + oid + "\n" for oid in parents)
           + "author Fixture <fixture@example.invalid> 1 +0000\n"
           + "committer Fixture <fixture@example.invalid> 1 +0000\n\nadmission fixture\n").encode()
    return object_write(repository, "commit", raw)


class Fixture:
    def __init__(self, name, *, form="withheld-write.v1", algorithm="sha1", base_rows=None):
        self.directory = area / name
        self.directory.mkdir()
        self.mutations = self.directory / "mutations"
        self.mutations.mkdir()
        self.algorithm = algorithm
        self.form = form
        self.closed = False
        self.owners = []
        self.source = bare(name + "-source.git", algorithm)
        self.base_rows = {"source.txt": ("100644", "blob", object_write(self.source, "blob", b"source baseline\n"))}
        if base_rows is not None:
            for path, mode, kind, raw in base_rows:
                self.base_rows[path] = (mode, kind, object_write(self.source, kind, raw))
        self.base_tree = tree_write(self.source, self.base_rows)
        self.base_commit = commit_write(self.source, self.base_tree, [])
        self.candidate = area / (name + "-candidate.git")
        shutil.copytree(self.source, self.candidate)
        self.revision = {"repository_id": "repository.admission-fixture",
                         "hash_algorithm": algorithm, "commit_id": self.base_commit}
        self.incident = {"schema_version": 1, "kind": "shadow_incident", "id": "incident.admission",
                         "body": {"target_repository_id": self.revision["repository_id"],
                                  "git_revision_ref": self.revision}}
        self.incident_raw = canonical(self.incident)
        self.frozen = {name: canonical({"schema_version": 1, "kind": "fixture", "id": "fixture." + str(index), "body": {}})
                       for index, name in enumerate(NAMES)}
        for name in NAMES:
            if name.endswith(".txt"):
                self.frozen[name] = (name + "\n").encode()
        self.frozen["incident.json"] = self.incident_raw
        self.frozen["bundle.json"] = canonical({"schema_version": 1, "kind": "shadow_consumer_bundle",
            "id": "bundle.fixture", "body": {"files": [
                {"name": name, "size_bytes": len(raw), "sha256": digest(raw)}
                for name, raw in sorted(self.frozen.items())]}})
        self.prefix = "ystack-evidence/incident.admission/"
        self.seed = canonical({"schema_version": 1, "kind": "eval_seed", "id": "seed.fixture", "body": {}})
        self.files = {self.prefix + name: raw for name, raw in self.frozen.items()}
        self.files[self.prefix + "eval-seed.json"] = self.seed
        self.files[self.prefix + "README.md"] = README
        self.outer = {name: self.frozen[name] for name in NAMES}
        if form == "withheld-write-policy.v1":
            self.files[self.prefix + "scope-policy.json"] = POLICY
            self.outer["scope-policy.json"] = POLICY
            self.outer["shadow-record.json"] = canonical({"schema_version": 1, "kind": "fixture",
                "id": "fixture.record", "body": {"scope_policy_ref": {
                    "name": "scope-policy.json", "size_bytes": len(POLICY), "sha256": digest(POLICY)}}})
        self.generated = canonical({"stage_request": {"content": {"body": {
            "workflow_id": "workflow.shadow-evidence-commit", "task_class_id": "task.commit-shadow-evidence"}}}})
        self.candidate_rows = dict(self.base_rows)
        self.rebuild_candidate()
        self.ledger = Ledger(self.directory)
        self.source_owner = c._ReadOnlyGit(str(self.source), self.ledger)
        self.owners.append(self.source_owner)
        self.candidate_owner = c._ReadOnlyGit(str(self.candidate), self.ledger)
        self.owners.append(self.candidate_owner)
        self.inventory = self.source_owner.inventory(self.revision)
        self.inputs = a._AdmissionInputs(
            self.incident_raw, self.response, canonical(self.write), self.generated,
            tuple(sorted(self.frozen.items())), tuple(sorted(self.files.items())), tuple(sorted(self.outer.items())),
            self.seed, form, "scope.admission-fixture", tuple(sorted(self.files)), POLICY, MODE,
            tuple(sorted(self.inventory.items())), self.source_owner, self.candidate_owner)

    def rebuild_candidate(self, *, rows=None, parents=None, claimed_tree=None):
        additions = {}
        for path, raw in self.files.items():
            additions[path] = ("100644", "blob", object_write(self.candidate, "blob", raw))
        entries = dict(self.base_rows, **additions) if rows is None else rows
        self.candidate_rows = entries
        self.tree = tree_write(self.candidate, entries)
        self.commit = commit_write(self.candidate, self.tree, [self.base_commit] if parents is None else parents)
        self.response = canonical({"payloads": [{"data": canonical({"candidate": {
            "parent_commit_id": self.base_commit, "commit_id": self.commit,
            "tree_id": self.tree if claimed_tree is None else claimed_tree}, "changed_paths": {
                "count": 33 if self.form == "withheld-write-policy.v1" else 32}}).decode()}]})
        self.rows = [{"path": path, "mode": "100644", "sha256": digest(raw),
                      "git_blob_oid": native_oid(raw, "blob", self.algorithm), "add_only": True}
                     for path, raw in sorted(self.files.items())]
        title = "Shadow evidence: incident.admission"
        body = b"Shadow evidence for incident.admission. Publication is withheld.\n"
        published_tree = self.tree if claimed_tree is None else claimed_tree
        self.request = {"schema_version": 1, "kind": "shadow_publisher_request", "id": "incident.admission",
            "body": {"target_repository_id": "repository.admission-fixture", "branch": "ystack/evidence/incident.admission",
                "base_revision": self.revision, "candidate_tree_id": published_tree, "title": title,
                "body_sha256": digest(body)}}
        self.outer["publisher-body.txt"] = body
        self.write = {"bundle_ref": {"content_id": "shadow-consumer-bundle",
            "media_type": "application/vnd.ystack.shadow-consumer-bundle+json", "sha256": digest(self.frozen["bundle.json"])},
            "scope_id": "scope.admission-fixture", "workflow_id": "workflow.shadow-evidence-commit",
            "task_class": "task.commit-shadow-evidence", "write_set": self.rows,
            "publisher_request": self.request, "admission": {"state": "checked", "effect": "none",
                "request_sha256": digest(canonical(self.request)), "write_set_sha256": digest(canonical(self.rows))},
            "publication": {"state": "withheld", "reason_id": "shadow.write-not-published"},
            "post_write_verification": {"target_revision": self.revision, "candidate_tree_id": published_tree, "write_set": self.rows}}
        self.outer["shadow-record.json"] = canonical({"schema_version": 1, "kind": "shadow_reproduction_record",
            "id": "incident.admission", "body": {"record_form": self.form, "write": self.write,
                **({"scope_policy_ref": {"name": "scope-policy.json", "size_bytes": len(POLICY), "sha256": digest(POLICY)}}
                   if self.form == "withheld-write-policy.v1" else {})}})

    def rebound(self, original=None, **changes):
        current = self.inputs if original is None else original
        values = {"generated_response_raw": self.response, "write_raw": canonical(self.write),
                  "candidate_files": tuple(sorted(self.files.items())), "outer_files": tuple(sorted(self.outer.items()))}
        values.update(changes)
        outer = dict(values["outer_files"])
        record = json.loads(outer["shadow-record.json"])
        record["body"]["write"] = json.loads(values["write_raw"])
        outer["shadow-record.json"] = canonical(record)
        values["outer_files"] = tuple(sorted(outer.items()))
        return dataclasses.replace(current, **values)

    def object_mutation(self, transform, *, parents=None, claimed_tree=None):
        entries = dict(self.candidate_rows)
        transform(entries)
        self.rebuild_candidate(rows=entries, parents=parents, claimed_tree=claimed_tree)
        return self.rebound()

    def close(self):
        for owner in reversed(self.owners):
            owner.close()
        self.closed = True


observed = {}
execution_counts = {}


def input_hashes(inputs):
    values = {}
    for field in dataclasses.fields(inputs):
        value = getattr(inputs, field.name)
        if isinstance(value, bytes):
            values[field.name] = digest(value)
        elif field.name.endswith("_files"):
            values[field.name] = [{"name": name, "size": len(raw), "sha256": digest(raw)} for name, raw in value]
        elif field.name.endswith("_git"):
            values[field.name] = {"repository": value.repository, "config_sha256": digest(value.config)}
    return values


def checked_call(ident, phase, inputs, expected):
    before = [len(inputs.source_git.held), len(inputs.candidate_git.held)]
    record = {"case_id": ident, "route": "A/G", "phase": phase, "expected": expected,
              "input_hashes": input_hashes(inputs), "holds_before": before,
              "start_ns": time.time_ns(), "marker_present": False, "stdout": "", "stderr": ""}
    result = None
    try:
        result = a.admit_write(inputs)
        status = "OK"
    except c.Refusal as exc:
        status = exc.code
    record.update(status=status, holds_after=[len(inputs.source_git.held), len(inputs.candidate_git.held)],
                  end_ns=time.time_ns(), exit=0 if status == "OK" else 1)
    (receipts / (ident + "-" + phase + ".json")).write_bytes(canonical(record))
    assert (status == "OK") == (expected == "OK"), (ident, phase, status, expected)
    assert before == record["holds_after"]
    if result is not None:
        assert type(result) is a._AdmissionResult
        assert result.body_raw == b"Shadow evidence for incident.admission. Publication is withheld.\n"
        assert json.loads(result.admission_raw)["effect"] == "none"
        assert set(field.name for field in dataclasses.fields(result)) == {
            "base_revision_raw", "candidate_commit_id", "candidate_tree_id", "publisher_request_raw", "title_raw",
            "body_raw", "write_set_raw", "admission_raw", "post_write_plan_raw"}
    return result


def paired(ident, mutate, *, form="withheld-write.v1", algorithm="sha1"):
    assert ident in CASES and ident not in observed
    fixture = Fixture(ident + "-" + form, form=form, algorithm=algorithm)
    try:
        checked_call(ident, "baseline", fixture.inputs, "OK")
        altered = mutate(fixture)
        checked_call(ident, "mutation", altered, CASES[ident][1])
        checked_call(ident, "restored", fixture.inputs, "OK")
    finally:
        fixture.close()
    observed[ident] = CASES[ident][1]
    execution_counts[ident] = 1
    print("ADMISSION", ident, CASES[ident][1], "baseline/mutation/restored PASS", flush=True)


def change_write(fixture, change):
    value = copy.deepcopy(fixture.write)
    change(value)
    # Legal mutations keep all derived digests coherent, except digest-target rows.
    value["admission"]["request_sha256"] = digest(canonical(value["publisher_request"]))
    value["admission"]["write_set_sha256"] = digest(canonical(value["write_set"]))
    outer = dict(fixture.outer)
    record = json.loads(outer["shadow-record.json"])
    record["body"]["write"] = value
    outer["shadow-record.json"] = canonical(record)
    return dataclasses.replace(fixture.inputs, write_raw=canonical(value), outer_files=tuple(sorted(outer.items())))


def changed_field(field, value):
    def mutate(fixture):
        return change_write(fixture, lambda write: write["publisher_request"]["body"].__setitem__(field, value))
    return mutate


paired("A05", changed_field("target_repository_id", "repository.other-valid"))
paired("A06", changed_field("branch", "ystack/evidence/incident.other-valid"))
paired("A07", changed_field("base_revision", {"repository_id": "repository.admission-fixture", "hash_algorithm": "sha1", "commit_id": "1" * 40}))
paired("A08", changed_field("candidate_tree_id", "1" * 40))
paired("A09", changed_field("title", "Shadow evidence: incident.other-valid"))


def altered_body(fixture, raw, *, stale_hash=False):
    outer = dict(fixture.outer, **{"publisher-body.txt": raw})
    value = copy.deepcopy(fixture.write)
    if not stale_hash:
        value["publisher_request"]["body"]["body_sha256"] = digest(raw)
        value["admission"]["request_sha256"] = digest(canonical(value["publisher_request"]))
    record = json.loads(outer["shadow-record.json"])
    record["body"]["write"] = value
    outer["shadow-record.json"] = canonical(record)
    return dataclasses.replace(fixture.inputs, outer_files=tuple(sorted(outer.items())), write_raw=canonical(value))


paired("A10", lambda fixture: altered_body(fixture, b"Other held evidence. Publication is withheld.\n"))
paired("A11", lambda fixture: change_write(fixture, lambda value: value["publisher_request"].update(id="incident.other-valid")))
paired("A12", lambda fixture: change_write(fixture, lambda value: value.update(scope_id="scope.other-valid")))


def stage_change(fixture, field, value):
    generated = json.loads(fixture.inputs.generated_input_raw)
    generated["stage_request"]["content"]["body"][field] = value
    return dataclasses.replace(fixture.inputs, generated_input_raw=canonical(generated))


paired("A13", lambda fixture: stage_change(fixture, "workflow_id", "workflow.other-valid"))
paired("A14", lambda fixture: stage_change(fixture, "task_class_id", "task.other-valid"))


def candidate_bytes_change(fixture):
    original = fixture.candidate
    destination = fixture.mutations / "actual-wrong-blob.git"
    shutil.copytree(original, destination)
    fixture.candidate = destination
    entries = dict(fixture.candidate_rows)
    entries[fixture.prefix + "README.md"] = ("100644", "blob", object_write(destination, "blob", b"Wrong actual Git blob\n"))
    fixture.rebuild_candidate(rows=entries)
    owner = c._ReadOnlyGit(str(destination), fixture.ledger)
    fixture.owners.append(owner)
    altered = fixture.rebound(candidate_git=owner)
    fixture.candidate = original
    return altered


paired("A15", candidate_bytes_change)
paired("A16", lambda fixture: altered_body(fixture, fixture.outer["publisher-body.txt"][:-1]))
paired("A17", lambda fixture: altered_body(fixture, fixture.outer["publisher-body.txt"] + b"\n"))
paired("A18", lambda fixture: altered_body(fixture, b"Different held body\n", stale_hash=True))


def wrong_digest(fixture, field):
    value = copy.deepcopy(fixture.write)
    value["admission"][field] = "1" * 64
    outer = dict(fixture.outer)
    record = json.loads(outer["shadow-record.json"])
    record["body"]["write"] = value
    outer["shadow-record.json"] = canonical(record)
    return dataclasses.replace(fixture.inputs, write_raw=canonical(value), outer_files=tuple(sorted(outer.items())))


paired("A19", lambda fixture: wrong_digest(fixture, "request_sha256"))
paired("A20", lambda fixture: wrong_digest(fixture, "write_set_sha256"))


def changed_frozen(fixture):
    files = dict(fixture.frozen)
    marker = json.loads(files["bundle.json"])
    marker["id"] = "bundle.other-valid"
    files["bundle.json"] = canonical(marker)
    value = copy.deepcopy(fixture.write)
    value["bundle_ref"]["sha256"] = digest(files["bundle.json"])
    outer = dict(fixture.outer)
    record = json.loads(outer["shadow-record.json"])
    record["body"]["write"] = value
    outer["shadow-record.json"] = canonical(record)
    return dataclasses.replace(fixture.inputs, frozen_files=tuple(sorted(files.items())), write_raw=canonical(value), outer_files=tuple(sorted(outer.items())))


paired("A21", changed_frozen)


def marker_swap(fixture, direction):
    marker = canonical({"schema_version": 1, "kind": "shadow_consumer_bundle", "id": "bundle.outer-valid",
        "body": {"files": [{"name": name, "size_bytes": len(raw), "sha256": digest(raw)} for name, raw in sorted(fixture.outer.items())]}})
    frozen = dict(fixture.frozen)
    outer = dict(fixture.outer)
    if direction == "inner-for-outer":
        outer["shadow-record.json"] = frozen["bundle.json"]
    else:
        frozen["bundle.json"] = marker
    return dataclasses.replace(fixture.inputs, frozen_files=tuple(sorted(frozen.items())), outer_files=tuple(sorted(outer.items())))


paired("A22", lambda fixture: marker_swap(fixture, "inner-for-outer"))
paired("A23", lambda fixture: marker_swap(fixture, "outer-for-inner"))


def policy_change(fixture):
    value = json.loads(POLICY)
    value["id"] = "policy.other-valid"
    raw = canonical(value)
    outer = dict(fixture.outer, **{"scope-policy.json": raw})
    record = json.loads(outer["shadow-record.json"])
    record["body"]["scope_policy_ref"] = {"name": "scope-policy.json", "size_bytes": len(raw), "sha256": digest(raw)}
    outer["shadow-record.json"] = canonical(record)
    return dataclasses.replace(fixture.inputs, outer_files=tuple(sorted(outer.items())))


def policy_size(fixture):
    outer = dict(fixture.outer)
    record = json.loads(outer["shadow-record.json"])
    record["body"]["scope_policy_ref"]["size_bytes"] += 1
    outer["shadow-record.json"] = canonical(record)
    return dataclasses.replace(fixture.inputs, outer_files=tuple(sorted(outer.items())))


paired("A24", policy_change, form="withheld-write-policy.v1")
paired("A25", policy_size, form="withheld-write-policy.v1")


def backfill(fixture):
    files = dict(fixture.files, **{fixture.prefix + "scope-policy.json": POLICY})
    return dataclasses.replace(fixture.inputs, candidate_files=tuple(sorted(files.items())))


paired("A26", backfill)
paired("A27", lambda fixture: dataclasses.replace(fixture.inputs, record_form="withheld-write-policy.v1"))
paired("A28", lambda fixture: dataclasses.replace(fixture.inputs, candidate_files=tuple(sorted(dict(fixture.files, **{fixture.prefix + "extra.json": b"{}\n"}).items()))))


def rename_candidate(fixture, replacement):
    files = dict(fixture.files)
    raw = files.pop(fixture.prefix + "README.md")
    files[replacement] = raw
    return dataclasses.replace(fixture.inputs, candidate_files=tuple(sorted(files.items())), allowed_paths=tuple(sorted(files)))


paired("A29", lambda fixture: rename_candidate(fixture, "ystack-evidence/incident.other-valid/README.md"))
paired("A30", lambda fixture: rename_candidate(fixture, fixture.prefix + "Readme.md"))
paired("A31", lambda fixture: rename_candidate(fixture, fixture.prefix + "nested/README.md"))
paired("A32", lambda fixture: change_write(fixture, lambda value: value["write_set"].append(copy.deepcopy(value["write_set"][0]))))
paired("A33", lambda fixture: change_write(fixture, lambda value: value["write_set"].reverse()))
paired("A34", lambda fixture: dataclasses.replace(fixture.inputs, allowed_paths=tuple(sorted(fixture.files))[1:]))
paired("A35", lambda fixture: dataclasses.replace(fixture.inputs, seed_raw=canonical({"schema_version": 1, "kind": "eval_seed", "id": "seed.other-valid", "body": {}})))
paired("A36", lambda fixture: dataclasses.replace(fixture.inputs, candidate_files=tuple(sorted(dict(fixture.files, **{fixture.prefix + "README.md": b"Other evidence.\n"}).items()))))
paired("A37", lambda fixture: change_write(fixture, lambda value: value.update(publication={"state": "published", "reason_id": "shadow.write-not-published"})))
paired("A38", lambda fixture: change_write(fixture, lambda value: value["admission"].update(authority="publish")))
paired("A39", lambda fixture: change_write(fixture, lambda value: value["post_write_verification"].update(target_revision=dict(fixture.revision, commit_id="1" * 40))))
paired("A40", lambda fixture: change_write(fixture, lambda value: value["post_write_verification"].update(candidate_tree_id="1" * 40)))
paired("A41", lambda fixture: change_write(fixture, lambda value: value["post_write_verification"].update(write_set=[])))


# New objects are built in a separate database before its actual fixed owner opens.
def changed_objects(fixture, transform=lambda entries: None, *, parents=None, claimed_tree=None, algorithm=None):
    original_repository = fixture.candidate
    destination = fixture.mutations / "mutation.git"
    if algorithm is None:
        shutil.copytree(original_repository, destination)
    else:
        destination = bare(fixture.mutations / "wrong-format.git", algorithm)
        # A wrong-format owner refuses shape before it can inspect claimed old OIDs.
    fixture.candidate = destination
    if algorithm is None:
        entries = dict(fixture.candidate_rows)
        transform(entries)
        fixture.rebuild_candidate(rows=entries, parents=parents, claimed_tree=claimed_tree)
    owner = c._ReadOnlyGit(str(destination), fixture.ledger)
    fixture.owners.append(owner)
    result = fixture.rebound(candidate_git=owner)
    fixture.candidate = original_repository
    return result


for ident, algorithm in (("G01", "sha1"), ("G02", "sha256")):
    for form in ("withheld-write.v1", "withheld-write-policy.v1"):
        fixture = Fixture(ident + "-" + form, form=form, algorithm=algorithm)
        try:
            checked_call(ident + "-" + form, "positive", fixture.inputs, "OK")
        finally:
            fixture.close()
    observed[ident] = "OK"
    execution_counts[ident] = 2
    print("ADMISSION", ident, "both forms actual", algorithm, "PASS", flush=True)


def equal_base(fixture):
    response = json.loads(fixture.response)
    receipt = json.loads(response["payloads"][0]["data"])
    receipt["candidate"].update(commit_id=fixture.base_commit, tree_id=fixture.base_tree)
    response["payloads"][0]["data"] = canonical(receipt).decode()
    value = copy.deepcopy(fixture.write)
    value["publisher_request"]["body"]["candidate_tree_id"] = fixture.base_tree
    value["admission"]["request_sha256"] = digest(canonical(value["publisher_request"]))
    value["post_write_verification"]["candidate_tree_id"] = fixture.base_tree
    outer = dict(fixture.outer)
    record = json.loads(outer["shadow-record.json"])
    record["body"]["write"] = value
    outer["shadow-record.json"] = canonical(record)
    return dataclasses.replace(fixture.inputs, generated_response_raw=canonical(response), write_raw=canonical(value), outer_files=tuple(sorted(outer.items())))


paired("G03", equal_base)
paired("G04", lambda fixture: changed_objects(fixture, parents=[]))
paired("G05", lambda fixture: changed_objects(fixture, parents=[fixture.base_commit, fixture.base_commit]))


def wrong_parent(fixture):
    destination = fixture.mutations / "parent-source.git"
    shutil.copytree(fixture.source, destination)
    wrong = commit_write(destination, fixture.base_tree, [fixture.base_commit])
    original = fixture.candidate
    # Copy the one real parent object into the owned mutation database's source closure.
    parent_object = git(destination, "cat-file", "commit", wrong)
    temporary = fixture.mutations / "parent-candidate.git"
    shutil.copytree(original, temporary)
    assert object_write(temporary, "commit", parent_object) == wrong
    fixture.candidate = temporary
    result = changed_objects(fixture, parents=[wrong])
    fixture.candidate = original
    return result


paired("G06", wrong_parent)
paired("G07", lambda fixture: changed_objects(fixture, claimed_tree=fixture.base_tree))


def replace_existing(fixture, mode="100644", kind="blob", raw=b"changed existing\n"):
    def mutate(entries):
        oid = object_write(fixture.candidate, kind, raw)
        entries["source.txt"] = (mode, kind, oid)
    return changed_objects(fixture, mutate)


paired("G08", replace_existing)
paired("G09", lambda fixture: changed_objects(fixture, lambda entries: entries.pop("source.txt")))
paired("G10", lambda fixture: changed_objects(fixture, lambda entries: entries.update({"source.txt": ("100755", "blob", fixture.base_rows["source.txt"][2])})))


def old_leaf_to_tree(fixture):
    def mutate(entries):
        entries["source.txt"] = ("040000", "tree", git(fixture.candidate, "mktree").decode().strip())
    return changed_objects(fixture, mutate)


paired("G11", old_leaf_to_tree)


def extra_object(fixture, *, empty_tree=False):
    def mutate(entries):
        if empty_tree:
            entries["unrelated-empty"] = ("040000", "tree", git(fixture.candidate, "mktree").decode().strip())
        else:
            entries["unrelated-extra.txt"] = ("100644", "blob", object_write(fixture.candidate, "blob", b"extra\n"))
    return changed_objects(fixture, mutate)


paired("G12", extra_object)
paired("G13", lambda fixture: extra_object(fixture, empty_tree=True))


# Root and alias mutations need a different real base, with valid companion commits.
def base_case(ident, path, mode="100644", kind="blob", raw=b"existing\n"):
    baseline = Fixture(ident + "-baseline")
    try:
        checked_call(ident, "baseline", baseline.inputs, "OK")
    finally:
        baseline.close()
    altered = Fixture(ident + "-changed-base", base_rows=[(path, mode, kind, raw)])
    try:
        checked_call(ident, "mutation", altered.inputs, "REFUSE")
    finally:
        altered.close()
    restored = Fixture(ident + "-restored")
    try:
        checked_call(ident, "restored", restored.inputs, "OK")
    finally:
        restored.close()
    observed[ident] = "REFUSE"
    execution_counts[ident] = 1
    print("ADMISSION", ident, "real base baseline/mutation/restored PASS", flush=True)


base_case("G14", "ystack-evidence/incident.admission/existing.txt")
base_case("G15", "ystack-evidence/Incident.admission/existing.txt")
base_case("G16", "ystack-evidence/incident.admission/nested/existing.txt")
# For non-tree ancestors, a candidate cannot legally add descendants. Keep its real
# valid candidate database separate; admission must reject the actual base first.
def ancestor_case(ident, path):
    fixture = Fixture(ident + "-baseline")
    try:
        checked_call(ident, "baseline", fixture.inputs, "OK")
        source = bare(fixture.mutations / "source-mutated.git")
        rows = {"source.txt": ("100644", "blob", object_write(source, "blob", b"source baseline\n")),
                path: ("100644", "blob", object_write(source, "blob", b"ancestor is a leaf\n"))}
        commit = commit_write(source, tree_write(source, rows), [])
        owner = c._ReadOnlyGit(str(source), fixture.ledger)
        fixture.owners.append(owner)
        incident = copy.deepcopy(fixture.incident)
        incident["body"]["git_revision_ref"]["commit_id"] = commit
        changed = dataclasses.replace(fixture.inputs, source_git=owner,
            source_inventory=tuple(sorted(owner.inventory(incident["body"]["git_revision_ref"]).items())))
        # Snapshot contains the actual conflicting ancestor and is not a fabricated inventory.
        checked_call(ident, "mutation", changed, "REFUSE")
        checked_call(ident, "restored", fixture.inputs, "OK")
    finally:
        fixture.close()
    observed[ident] = "REFUSE"
    execution_counts[ident] = 1
    print("ADMISSION", ident, "actual conflicting ancestor PASS", flush=True)


ancestor_case("G17", "ystack-evidence")
base_case("G18", "YSTACK-EVIDENCE/other/existing.txt")


def added_mode(fixture, mode, kind="blob"):
    def mutate(entries):
        path = fixture.prefix + "README.md"
        oid = entries[path][2] if kind == "blob" else fixture.base_commit
        entries[path] = (mode, kind, oid)
    return changed_objects(fixture, mutate)


paired("G19", lambda fixture: added_mode(fixture, "120000"))
paired("G20", lambda fixture: added_mode(fixture, "160000", "commit"))
paired("G21", lambda fixture: added_mode(fixture, "100755"))
paired("G22", lambda fixture: change_write(fixture, lambda value: value["write_set"][0].update(sha256="1" * 64)))
paired("G23", lambda fixture: change_write(fixture, lambda value: value["write_set"][0].update(git_blob_oid="1" * 40)))


def truncated(fixture):
    files = dict(fixture.files)
    path = fixture.prefix + "payload-stdout.txt"
    files[path] = files[path][:-1]
    return dataclasses.replace(fixture.inputs, candidate_files=tuple(sorted(files.items())))


paired("G24", truncated)
paired("G25", lambda fixture: dataclasses.replace(fixture.inputs, source_inventory=tuple()))


def repository_mismatch(fixture):
    incident = copy.deepcopy(fixture.incident)
    incident["body"]["git_revision_ref"]["repository_id"] = "repository.other-valid"
    frozen = dict(fixture.frozen, **{"incident.json": canonical(incident)})
    marker = json.loads(frozen["bundle.json"])
    for row in marker["body"]["files"]:
        if row["name"] == "incident.json":
            row.update(size_bytes=len(frozen["incident.json"]), sha256=digest(frozen["incident.json"]))
    frozen["bundle.json"] = canonical(marker)
    files = dict(fixture.files)
    files.update({fixture.prefix + name: raw for name, raw in frozen.items()})
    value = copy.deepcopy(fixture.write)
    value["bundle_ref"]["sha256"] = digest(frozen["bundle.json"])
    value["publisher_request"]["body"]["base_revision"] = incident["body"]["git_revision_ref"]
    value["post_write_verification"]["target_revision"] = incident["body"]["git_revision_ref"]
    value["admission"]["request_sha256"] = digest(canonical(value["publisher_request"]))
    outer = dict(fixture.outer)
    record = json.loads(outer["shadow-record.json"])
    record["body"]["write"] = value
    outer["shadow-record.json"] = canonical(record)
    return dataclasses.replace(fixture.inputs, incident_raw=canonical(incident), frozen_files=tuple(sorted(frozen.items())),
        candidate_files=tuple(sorted(files.items())), write_raw=canonical(value), outer_files=tuple(sorted(outer.items())))


paired("G26", repository_mismatch)
paired("G27", lambda fixture: changed_objects(fixture, algorithm="sha256"))


# The independent encoder sizes fixture patches; expected limits stay literal.
def reference_patch(files, algorithm):
    chunks = []
    for path, raw in sorted(files.items()):
        oid = native_oid(raw, "blob", algorithm)
        header = ("diff --git a/" + path + " b/" + path + "\nnew file mode 100644\nindex "
                  + "0" * len(oid) + ".." + oid + "\n--- /dev/null\n+++ b/" + path + "\n")
        lines = raw.split(b"\n")
        if raw:
            if raw.endswith(b"\n"):
                lines.pop()
            header += "@@ -0,0 +1," + str(len(lines)) + " @@\n"
        chunk = header.encode() + b"".join(b"+" + line + b"\n" for line in lines if raw)
        if raw and not raw.endswith(b"\n"):
            chunk += b"\\ No newline at end of file\n"
        chunks.append(chunk)
    return b"".join(chunks)


def patch_boundary(ident, size, expected):
    fixture = Fixture(ident)
    try:
        checked_call(ident, "baseline", fixture.inputs, "OK")
        frozen = dict(fixture.frozen)
        files = dict(fixture.files)
        for iteration in range(10):
            current = len(reference_patch(files, fixture.algorithm))
            delta = size - current
            if delta == 0:
                break
            raw = frozen["payload-stdout.txt"]
            assert len(raw) + delta >= 1
            frozen["payload-stdout.txt"] = b"x" * (len(raw) + delta - 1) + b"\n"
            marker = json.loads(frozen["bundle.json"])
            for row in marker["body"]["files"]:
                if row["name"] == "payload-stdout.txt":
                    raw = frozen[row["name"]]
                    row.update(size_bytes=len(raw), sha256=digest(raw))
            frozen["bundle.json"] = canonical(marker)
            files.update({fixture.prefix + name: raw for name, raw in frozen.items()})
        assert len(reference_patch(files, fixture.algorithm)) == size
        rows = [{"path": path, "mode": "100644", "sha256": digest(raw),
                 "git_blob_oid": native_oid(raw, "blob", fixture.algorithm), "add_only": True}
                for path, raw in sorted(files.items())]
        if expected == "OK":
            fixture.files = files
            # The new valid snapshot is complete before its held owner is created.
            original = fixture.candidate
            destination = fixture.mutations / "boundary.git"
            shutil.copytree(original, destination)
            fixture.candidate = destination
            fixture.rebuild_candidate()
            owner = c._ReadOnlyGit(str(destination), fixture.ledger)
            fixture.owners.append(owner)
            value = copy.deepcopy(fixture.write)
            value["bundle_ref"]["sha256"] = digest(frozen["bundle.json"])
            changed = fixture.rebound(candidate_git=owner, frozen_files=tuple(sorted(frozen.items())), write_raw=canonical(value))
            fixture.candidate = original
        else:
            value = copy.deepcopy(fixture.write)
            value["bundle_ref"]["sha256"] = digest(frozen["bundle.json"])
            value["write_set"] = rows
            value["post_write_verification"]["write_set"] = rows
            value["admission"]["write_set_sha256"] = digest(canonical(rows))
            outer = dict(fixture.outer)
            record = json.loads(outer["shadow-record.json"])
            record["body"]["write"] = value
            outer["shadow-record.json"] = canonical(record)
            changed = dataclasses.replace(fixture.inputs, frozen_files=tuple(sorted(frozen.items())),
                candidate_files=tuple(sorted(files.items())), write_raw=canonical(value), outer_files=tuple(sorted(outer.items())))
        checked_call(ident, "mutation", changed, expected)
        checked_call(ident, "restored", fixture.inputs, "OK")
    finally:
        fixture.close()
    observed[ident] = expected
    execution_counts[ident] = 1
    print("ADMISSION", ident, "actual patch", size, expected, "PASS", flush=True)


patch_boundary("G28", 1_048_576, "OK")
patch_boundary("G29", 1_048_577, "REFUSE")


def forbidden_blob(fixture, raw):
    files = dict(fixture.files)
    files[fixture.prefix + "payload-stdout.txt"] = raw
    frozen = dict(fixture.frozen, **{"payload-stdout.txt": raw})
    marker = json.loads(frozen["bundle.json"])
    for row in marker["body"]["files"]:
        if row["name"] == "payload-stdout.txt":
            row.update(size_bytes=len(raw), sha256=digest(raw))
    frozen["bundle.json"] = canonical(marker)
    files[fixture.prefix + "bundle.json"] = frozen["bundle.json"]
    value = copy.deepcopy(fixture.write)
    value["bundle_ref"]["sha256"] = digest(frozen["bundle.json"])
    outer = dict(fixture.outer)
    record = json.loads(outer["shadow-record.json"])
    record["body"]["write"] = value
    outer["shadow-record.json"] = canonical(record)
    return dataclasses.replace(fixture.inputs, frozen_files=tuple(sorted(frozen.items())),
        candidate_files=tuple(sorted(files.items())), write_raw=canonical(value), outer_files=tuple(sorted(outer.items())))


paired("G30", lambda fixture: forbidden_blob(fixture, b"\xff\n"))
paired("G31", lambda fixture: forbidden_blob(fixture, b"binary\0bytes\n"))
paired("G32", lambda fixture: forbidden_blob(fixture, b"control\x01text\n"))


policy = json.loads(POLICY)
mode = json.loads(MODE)


def path_case(ident, path):
    assert not c.write_path_ok(path, policy, mode), (ident, path)
    paired(ident, lambda fixture: rename_candidate(fixture, path))
    print("PATH-OWNER", ident, "common exact inventory plus actual write_path_ok refusal", flush=True)


path_case("L01", "ystack-evidence/incident.admission/.git/README.md")
path_case("L02", "ystack-evidence/incident.admission/.ystack/README.md")
path_case("L03", "ystack-evidence/incident.admission/../README.md")
path_case("L04", "ystack-evidence/incident.admission/SECRETS/README.md")


def held_policy(fixture, *, prefix=None, segment=None):
    value = json.loads(POLICY)
    if prefix is not None:
        value["body"]["protected_path_prefixes"].append(prefix)
    if segment is not None:
        value["body"]["protected_path_segments"].append(segment)
    return dataclasses.replace(fixture.inputs, policy_raw=canonical(value))


paired("L05", lambda fixture: held_policy(fixture, prefix="ystack-evidence/"))
print("PATH-OWNER L05 actual held-policy write_path_ok", flush=True)
assert c.write_path_ok("unprotected.txt", policy, mode)
assert not c.write_path_ok("AGENTS.md", policy, mode)
observed["L06"] = "REFUSE"
execution_counts["L06"] = 1
print("ADMISSION L06 actual primitive unprotected/protected/restored PASS", flush=True)
paired("L07", lambda fixture: held_policy(fixture, segment="incident.admission"))
print("PATH-OWNER L07 actual held-policy write_path_ok", flush=True)


def held_mode(fixture, *, prefix=None, path=None):
    value = json.loads(MODE)
    if prefix is not None:
        value["forbidden_prefixes"].append(prefix)
    if path is not None:
        value["forbidden_paths"].append(path)
    return dataclasses.replace(fixture.inputs, mode_raw=canonical(value))


paired("L08", lambda fixture: held_mode(fixture, path=fixture.prefix + "README.md"))
paired("L09", lambda fixture: held_mode(fixture, prefix="ystack-evidence/"))
print("PATH-OWNER L08/L09 actual held-mode write_path_ok", flush=True)
path_case("L10", "/ystack-evidence/incident.admission/README.md")
path_case("L11", "ystack-evidence/incident.admission/other\\README.md")
path_case("L12", "ystack-evidence/incident.admission//README.md")
path_case("L13", "ystack-evidence/incident.admission/other./README.md")
path_case("L14", "ystack-evidence/incident.admission/other /README.md")
path_case("L15", "ystack-evidence/incident.admission/other\x01/README.md")
assert c.write_path_ok("x" * 4096, policy, mode)
assert not c.write_path_ok("x" * 4097, policy, mode)
assert c.write_path_ok("x" * 4096, policy, mode)
observed["L16"] = "BOUNDARY"
execution_counts["L16"] = 2
print("ADMISSION L16 actual primitive 4096/4097/4096 PASS", flush=True)
assert c.write_path_ok("/".join(["x"] * 64), policy, mode)
assert not c.write_path_ok("/".join(["x"] * 65), policy, mode)
assert c.write_path_ok("/".join(["x"] * 64), policy, mode)
observed["L17"] = "BOUNDARY"
execution_counts["L17"] = 2
print("ADMISSION L17 actual primitive 64/65/64 PASS", flush=True)


# Incident changes remain closed-form fixtures and reach the actual construction helper.
def incident_case(ident, identity):
    fixture = Fixture(ident)
    try:
        checked_call(ident, "baseline", fixture.inputs, "OK")
        incident = copy.deepcopy(fixture.incident)
        incident["id"] = identity
        frozen = dict(fixture.frozen, **{"incident.json": canonical(incident)})
        marker = json.loads(frozen["bundle.json"])
        for row in marker["body"]["files"]:
            if row["name"] == "incident.json":
                row.update(size_bytes=len(frozen["incident.json"]), sha256=digest(frozen["incident.json"]))
        frozen["bundle.json"] = canonical(marker)
        prefix = "ystack-evidence/" + identity + "/"
        files = {prefix + path[len(fixture.prefix):]: raw for path, raw in fixture.files.items()}
        files.update({prefix + name: raw for name, raw in frozen.items()})
        changed = dataclasses.replace(fixture.inputs, incident_raw=canonical(incident), frozen_files=tuple(sorted(frozen.items())),
            candidate_files=tuple(sorted(files.items())), allowed_paths=tuple(sorted(files)))
        checked_call(ident, "mutation", changed, "REFUSE")
        checked_call(ident, "restored", fixture.inputs, "OK")
    finally:
        fixture.close()
    observed[ident] = "REFUSE"
    execution_counts[ident] = 1
    print("ADMISSION", ident, "incident baseline/refusal/restored PASS", flush=True)


incident_case("I01", "Incident.admission")
incident_case("I02", ".incident-admission")
incident_case("I03", "incident..admission")
incident_case("I04", "incident.admission.")
incident_case("I05", "incident.admission.lock")
incident_case("I06", "i" * 129)
incident_case("I07", "incident/admission")


# Every name is independently removed, with both supported inventories restored.
missing_names = (
    ("M01", "accepted-identities.json"),
    ("M02", "claim.json"),
    ("M03", "consumer-provenance.json"),
    ("M04", "decision.json"),
    ("M05", "duty-evaluation.json"),
    ("M06", "evaluator-driver.txt"),
    ("M07", "evaluator-program.txt"),
    ("M08", "evidence-manifest.json"),
    ("M09", "file-digest-result.json"),
    ("M10", "incident.json"),
    ("M11", "materialization-input.json"),
    ("M12", "materialization-response.json"),
    ("M13", "origin-observation.json"),
    ("M14", "payload-stderr.txt"),
    ("M15", "payload-stdout.txt"),
    ("M16", "policy-set.json"),
    ("M17", "policy.json"),
    ("M18", "preparation-manifest.json"),
    ("M19", "preparation-record.json"),
    ("M20", "qualified-identity.json"),
    ("M21", "registry.json"),
    ("M22", "sandbox-check.json"),
    ("M23", "sandbox-evaluation.json"),
    ("M24", "sandbox-expectation.json"),
    ("M25", "sandbox-receipt.json"),
    ("M26", "sandbox-request.json"),
    ("M27", "shadow-record.json"),
    ("M28", "trace-ledger.json"),
    ("M29", "trace-receipt.json"),
    ("M30", "bundle.json"),
    ("M31", "eval-seed.json"),
    ("M32", "README.md"),
    ("M33", "scope-policy.json"),
)
for ident, name in missing_names:
    forms = ("withheld-write-policy.v1",) if ident == "M33" else ("withheld-write.v1", "withheld-write-policy.v1")
    for index, form in enumerate(forms):
        fixture = Fixture(ident + "-" + form, form=form)
        try:
            checked_call(ident + "-" + form, "baseline", fixture.inputs, "OK")
            files = dict(fixture.files)
            del files[fixture.prefix + name]
            changed = dataclasses.replace(fixture.inputs, candidate_files=tuple(sorted(files.items())))
            checked_call(ident + "-" + form, "mutation", changed, "REFUSE")
            checked_call(ident + "-" + form, "restored", fixture.inputs, "OK")
        finally:
            fixture.close()
    observed[ident] = "REFUSE"
    execution_counts[ident] = len(forms)
    print("ADMISSION", ident, "missing", name, "forms", len(forms), "PASS", flush=True)


# Loader packages use only exact leaf copies, retaining fixed physical module origins.
loader_names = ("ystack_shadow_enforced", "ystack_shadow_consumer", "ystack_publisher_admission",
                "admission_loader_writer", "admission_loader_reader", "scope_shadow_writer", "scope_shadow_consumer")


def loader_package(name):
    package = area / (name + "-package")
    for relative in ("shadow/v1/_consumer.py", "shadow/v1/enforced-reproduction.py", "shadow/v1/write-shadow.py",
                     "scope/v1/read-shadow-evidence.py", "publisher/v1/_admission.py"):
        source = root / relative
        assert source.is_file() and not any(path.is_symlink() for path in (source, source.parent, source.parent.parent))
        destination = package / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        assert destination.read_bytes() == source.read_bytes()
        assert not destination.is_symlink() and stat.S_ISREG(destination.stat().st_mode)
    return package


def actual_loader(package, *, reader=False):
    state = {name: sys.modules.pop(name, None) for name in loader_names}
    owners = []
    try:
        if not reader:
            writer = load("admission_loader_writer", package / "shadow/v1/write-shadow.py")
            owners.append(writer._ADMISSION_SOURCE)
            assert writer.a.c is writer.e.c is writer.c
            assert writer._ADMISSION_SOURCE.raw == (package / "publisher/v1/_admission.py").read_bytes()
            assert writer._ADMISSION_SHA256 == digest(writer._ADMISSION_SOURCE.raw)
            return writer
        module = load("admission_loader_reader", package / "scope/v1/read-shadow-evidence.py")
        reader_owner = object.__new__(module._Reader)
        reader_owner.owned, reader_owner.inputs, reader_owner.anchor = [], [], None
        reader_owner.package_sources = {}
        # The reader holds the actual helper first, before the writer can execute it.
        for relative in ("publisher/v1/_admission.py", "shadow/v1/write-shadow.py", "shadow/v1/enforced-reproduction.py"):
            held = module.c._hold_bytes(str(package / relative), module.c.EXECUTABLE_LIMIT)
            owners.append(held)
            reader_owner.owned.append(held)
            reader_owner.package_sources[relative] = held
        writer = reader_owner.load_writer()
        owners.append(writer._ADMISSION_SOURCE)
        assert writer.a.c is writer.e.c is writer.c
        reader_owner.recheck()
        return writer
    finally:
        for owner in reversed(owners):
            owner.close()
        for name, previous in state.items():
            if previous is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = previous


def loader_case(ident, mutate):
    package = loader_package(ident)
    actual_loader(package)
    actual_loader(package, reader=True)
    helper = package / "publisher/v1/_admission.py"
    writer = package / "shadow/v1/write-shadow.py"
    before = {"helper": digest(helper.read_bytes()), "writer": digest(writer.read_bytes())}
    restore = mutate(package)
    for route in ("writer", "reader"):
        refused = False
        try:
            actual_loader(package, reader=route == "reader")
        except (c.Refusal, RuntimeError, SystemExit, OSError, KeyError, AttributeError, NameError) as exc:
            refused = True
            status = getattr(exc, "code", str(exc))
        except Exception as exc:
            # The loaded fixed consumer is a separate module instance in this package.
            assert type(exc).__name__ == "Refusal" and getattr(exc, "code", None) in {"E_RUNTIME", "E_RELATION", "E_DEPENDENCY"}
            refused = True
            status = exc.code
        assert refused, (ident, route, "loader accepted changed closure")
        record = {"case_id": ident, "route": route, "expected": "REFUSE", "status": status,
                  "before_hashes": before, "completion_marker_present": False}
        (receipts / (ident + "-" + route + ".json")).write_bytes(canonical(record))
    restore()
    actual_loader(package)
    actual_loader(package, reader=True)
    observed[ident] = "REFUSE"
    execution_counts[ident] = 2
    print("ADMISSION", ident, "actual writer/reader loader baseline/refusal/restored PASS", flush=True)


def missing_helper(package):
    path = package / "publisher/v1/_admission.py"
    raw = path.read_bytes()
    path.unlink()
    return lambda: path.write_bytes(raw)


def writer_pin(package, *, missing=False):
    path = package / "shadow/v1/write-shadow.py"
    raw = path.read_bytes()
    pin = digest((package / "publisher/v1/_admission.py").read_bytes()).encode()
    assert raw.count(pin) == 1
    replacement = raw.replace(b'_ADMISSION_SHA256 = "' + pin + b'"',
        b'_REMOVED_ADMISSION_PIN = "' + pin + b'"') if missing else raw.replace(pin, b"0" * 64)
    path.write_bytes(replacement)
    return lambda: path.write_bytes(raw)


def symlink_component(package, relative):
    path = package / relative
    saved = area / (package.name + "-" + path.name + "-held")
    path.rename(saved)
    path.symlink_to(saved, target_is_directory=saved.is_dir())
    def restore():
        path.unlink()
        saved.rename(path)
    return restore


loader_case("C01", missing_helper)
loader_case("C02", lambda package: writer_pin(package, missing=True))
loader_case("C03", writer_pin)
loader_case("C05", lambda package: symlink_component(package, "publisher/v1/_admission.py"))
loader_case("C06", lambda package: symlink_component(package, "publisher"))
loader_case("C07", lambda package: symlink_component(package, "publisher/v1"))


fixture = Fixture("C13-foreign-consumer")
try:
    checked_call("C13", "baseline", fixture.inputs, "OK")
    foreign = load("foreign_consumer_for_refusal", root / "shadow/v1/_consumer.py")
    sys.modules["ystack_shadow_consumer"] = foreign
    try:
        checked_call("C13", "mutation", fixture.inputs, "REFUSE")
    finally:
        sys.modules["ystack_shadow_consumer"] = c
    checked_call("C13", "restored", fixture.inputs, "OK")
finally:
    fixture.close()
observed["C13"] = "REFUSE"
execution_counts["C13"] = 1
print("ADMISSION C13 foreign consumer instance refuses PASS", flush=True)
fixture = Fixture("C14-closed-fields")
try:
    checked_call("C14", "baseline", fixture.inputs, "OK")
    fields = {field.name: getattr(fixture.inputs, field.name) for field in dataclasses.fields(fixture.inputs)}
    for forbidden in ("consumer", "predicate", "callable", "executor", "runner", "checked"):
        try:
            a._AdmissionInputs(**dict(fields, **{forbidden: True}))
        except TypeError:
            pass
        else:
            raise AssertionError("closed inputs accepted " + forbidden)
    checked_call("C14", "restored", fixture.inputs, "OK")
finally:
    fixture.close()
observed["C14"] = "REFUSE"
execution_counts["C14"] = 6
print("ADMISSION C14 six foreign authority fields refused PASS", flush=True)


class ForeignGitOwner:
    def __init__(self, owner):
        self.owner = owner
    def __getattr__(self, name):
        return getattr(self.owner, name)


paired("C15", lambda fixture: dataclasses.replace(fixture.inputs, candidate_git=ForeignGitOwner(fixture.candidate_owner)))

# Closed-input limits supplement the 166 contract IDs, with independent counts.
limit_fixture = Fixture("closed-input-limits")
limit_checks = 0
try:
    checked_call("closed-input-limits", "baseline", limit_fixture.inputs, "OK")
    for field, maximum in (("incident_raw", 1_048_576), ("generated_response_raw", 1_048_576),
                           ("write_raw", 1_048_576), ("generated_input_raw", 8_388_608),
                           ("seed_raw", 1_048_576), ("policy_raw", 1_048_576), ("mode_raw", 1_048_576)):
        changed = dataclasses.replace(limit_fixture.inputs, **{field: b"x" * (maximum + 1)})
        checked_call("limit-" + field, "over-limit", changed, "REFUSE")
        limit_checks += 1
    for field in ("frozen_files", "candidate_files", "outer_files"):
        changed = dataclasses.replace(limit_fixture.inputs, **{field: list(getattr(limit_fixture.inputs, field))})
        checked_call("immutable-" + field, "list-refused", changed, "REFUSE")
        limit_checks += 1
    try:
        limit_fixture.inputs.scope_id = "scope.mutable"
    except dataclasses.FrozenInstanceError:
        limit_checks += 1
    else:
        raise AssertionError("admission inputs are mutable")
    result = checked_call("closed-input-limits", "restored", limit_fixture.inputs, "OK")
    try:
        result.body_raw = b"mutated"
    except dataclasses.FrozenInstanceError:
        limit_checks += 1
    else:
        raise AssertionError("admission result is mutable")
finally:
    limit_fixture.close()
assert limit_checks == 12
print("ADMISSION-SUPPLEMENT closed-input expected=12 passed=12", flush=True)

# Restore the complete manifest with original modes, then use the actual dependency loader.
restored = area / "manifest-restoration"
restored.mkdir()
manifest = (root / "ci/required-files.txt").read_text().splitlines()
paths = [path for path in manifest if path and not path.startswith("#")]
assert len(paths) == len(set(paths))
assert paths.count("publisher/v1/_admission.py") == 1
assert paths.count("scripts/test/publisher-admission.test.sh") == 1
restoration_rows = []
for relative in paths:
    source = root / relative
    assert source.is_file() and not source.is_symlink(), relative
    entry = command(["git", "-C", str(root), "ls-files", "-s", "--", relative]).stdout.decode()
    assert entry.startswith(("100644 ", "100755 ")), (relative, entry)
    mode = 0o755 if entry.startswith("100755 ") else 0o644
    destination = restored / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(mode)
    assert destination.read_bytes() == source.read_bytes(), relative
    assert stat.S_IMODE(destination.stat().st_mode) == mode, relative
    restoration_rows.append({"path": relative, "mode": format(mode, "o"),
                             "sha256": digest(destination.read_bytes())})
assert stat.S_IMODE((restored / "publisher/v1/_admission.py").stat().st_mode) == 0o644
assert stat.S_IMODE((restored / "scripts/test/publisher-admission.test.sh").stat().st_mode) == 0o755
actual_loader(restored)
actual_loader(restored, reader=True)
assert (restored / "scripts/core-contract.sh").read_bytes() == (root / "scripts/core-contract.sh").read_bytes()
assert digest((restored / "core/v2/generation-registry.json").read_bytes()) == digest((root / "core/v2/generation-registry.json").read_bytes())
(receipts / "manifest-restoration.json").write_bytes(canonical({"files": restoration_rows,
    "helper_writer_reader_closure": "OK", "public_selection": "unchanged v2 wrapper/registry bytes"}))
print("ADMISSION-RESTORATION", len(restoration_rows), "files exact modes/bytes; actual held helper writer/reader loaders PASS", flush=True)

# These exact rows execute in their existing actual writer/private-package owners.
DELEGATED = {
    "A01": "scripts/test/shadow-write.test.sh",
    "A02": "scripts/test/shadow-write.test.sh",
    "A03": "scripts/test/shadow-write.test.sh",
    "A04": "scripts/test/shadow-write.test.sh",
    "C04": "scripts/test/shadow-write.test.sh",
    "C08": "scripts/test/shadow-write.test.sh",
    "C09": "scripts/test/shadow-write.test.sh",
    "C10": "scripts/test/shadow-write.test.sh",
    "C11": "scripts/test/shadow-write.test.sh",
    "C12": "scripts/test/shadow-write.test.sh",
    "Q1a": "scripts/test/scope-qualification.test.sh",
    "Q1b": "scripts/test/scope-qualification.test.sh",
    "Q1c": "scripts/test/scope-qualification.test.sh",
    "Q2a": "scripts/test/scope-qualification.test.sh",
    "Q2b": "scripts/test/scope-qualification.test.sh",
    "Q2c": "scripts/test/scope-qualification.test.sh",
    "Q3a": "scripts/test/scope-qualification.test.sh",
    "Q3b": "scripts/test/scope-qualification.test.sh",
    "Q3c": "scripts/test/scope-qualification.test.sh",
    "Q4a": "scripts/test/scope-qualification.test.sh",
    "Q4b": "scripts/test/scope-qualification.test.sh",
    "Q4c": "scripts/test/scope-qualification.test.sh",
    "S1a": "scripts/test/shadow-enforced.test.sh",
    "S1b": "scripts/test/shadow-enforced.test.sh",
    "S1c": "scripts/test/shadow-enforced.test.sh",
    "S2a": "scripts/test/shadow-write.test.sh",
    "S2b": "scripts/test/shadow-write.test.sh",
    "S2c": "scripts/test/shadow-write.test.sh",
    "S3a": "scripts/test/shadow-write.test.sh",
    "S3b": "scripts/test/shadow-write.test.sh",
    "S3c": "scripts/test/shadow-write.test.sh",
}
assert not (set(observed) & set(DELEGATED))
assert set(observed) | set(DELEGATED) == set(CASES)
for ident, path in DELEGATED.items():
    owner_raw = (root / path).read_bytes()
    if ident[0] in {"Q", "S"}:
        assert ident[:2].encode() in owner_raw and (b"_admission_package_closure" in owner_raw or ident.startswith("Q4")), (ident, "missing actual package site")
    else:
        assert ident.encode() in owner_raw, (ident, "missing delegated actual writer row")
for group in ("A", "G", "L", "I", "C", "M", "Q", "S"):
    expected_ids = {ident for ident in CASES if ident.startswith(group)}
    local_ids = expected_ids & set(observed)
    delegated_ids = expected_ids & set(DELEGATED)
    print("ADMISSION-GROUP", group, "literal_ids", len(expected_ids), "local_passed", len(local_ids),
          "delegated_actual_owner", len(delegated_ids), "executions", sum(execution_counts.get(ident, 0) for ident in local_ids), flush=True)
print("ADMISSION-INVENTORY total=166 local=" + str(len(observed)) + " delegated=" + str(len(DELEGATED)), flush=True)
print("Delegated rows are not local passes; their actual suite raw receipts remain required.", flush=True)
PY_ADMISSION
