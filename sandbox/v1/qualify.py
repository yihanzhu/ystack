#!/usr/bin/env python3
"""qualify.py -- qualification harness (ystack #463, PR 8 of 9; spec R2.3, R2.4, R13.4).

  measure <host-config>        the nine installed slots of R2.3 (never verification_instructions)
  instruction-digest <file>    SHA-256 of one instruction's bytes
  check-kernel-config <file>   the host's R2.4 function
  dry-run <dir>                every batch of <dir>/batches.json against the fake runtime, then aggregate
  run <dir> --batch <k>        batch k once, through each configuration's own host-supervisor.py, reading
                               each receipt as the consumer: one canonical sandbox_qualification_batch
  aggregate <dir> <batch>...   the one canonical sandbox_qualification_record (complete only if every
                               declared case id is covered exactly once by exactly one run of its batch)

Inactive. Under R7.2 CPU and wall are never enforced, so no record is ever `qualified`; a
clean case, a valid result line or a met fixture control waives no other row. Probe output is
untrusted payload: classification reads only the receipt's existing facts and stored payloads
whose digests match the receipt, never searches payload for a plausible result and never
relaxes host-supervisor.py's export validation.
"""
import hashlib
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
spec = importlib.util.spec_from_file_location("_ystack_qualify_host", os.path.join(HERE, "host-supervisor.py"))
hs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hs)


class Invalid(Exception):
    """A refusal; the message is the reason id printed on stderr (exit 1)."""


def sha(data):
    return hashlib.sha256(data).hexdigest()


# --- plan.md PR 7: the closed probe grammar the consumer parses (guest/probe.c) ----------
CHECKS = {
    "candidate-read": ("read",), "candidate-write": ("create",), "tools-write": ("create",),
    "evidence-read": ("read",), "evidence-list": ("list",), "evidence-reopen": ("reopen",),
    "evidence-truncate": ("truncate",), "evidence-link": ("link",), "evidence-rename": ("rename",),
    "scratch-free": ("ftruncate", "fallocate", "madv-remove", "path-truncate", "unlink", "rmdir", "tmpfile"),
    "scratch-fill": ("fill",), "socket-family": ("socket",),
    "host-sentinel": ("open", "read"), "sibling-sentinel": ("open", "read"),
    "environment": ("environment",), "descriptors": ("fd0", "fd1", "fd2", "fd-scan", "fd-leaks"),
    "fork-bomb": ("fork",), "thread-bomb": ("thread",), "cpu-spin-32": ("cpu",),
    "memory-exhaustion": ("memory",), "sleep": ("sleep",),
    "signal-supervisor": ("relationship", "supervisor-signal"), "namespace-escape": ("unshare",),
    "cgroup-escape": ("cgroup-write",), "forged-report-evidence": ("forged-evidence",)}
RAW_MODES = ("output-overflow", "forged-report-stdout")
FORGED = b'{"kind":"sandbox_guest_report","forged":true}\n'
OUTPUT_TARGET = 12582912
NEVER_COMPLETE = ("descriptors", "signal-supervisor")  # a partial census / an unaddressable ancestor
INPUT_ERRORS = {b"YSPROBE1 error=input\n": "diagnostic-input", b"YSPROBE1 error=read\n": "diagnostic-read"}
PRE, OUTCOMES = ("ok", "failed", "unknown"), ("success", "refused", "unsupported", "incomplete", "violation")
# Linux UAPI, aarch64: SOCK_STREAM 1, SOCK_RAW 3, SOCK_CLOEXEC 02000000, AF_NETLINK 16, AF_PACKET 17.
SOCK_STREAM, SOCK_RAW, SOCK_CLOEXEC, AF_NETLINK, AF_PACKET, NETLINK_USERSOCK = 1, 3, 0x80000, 16, 17, 2
SENTINEL_MEANING = {
    "host": "a regular file outside the guest that stands for the host filesystem",
    "sibling": "one synthetic storage resource standing in for a sibling VM; it does not prove "
               "isolation from a live sibling VM's memory or any other resource"}


def uint(text, maximum):
    return re.fullmatch(r"0|[1-9][0-9]{0,19}", text) is not None and int(text) <= maximum   # at most 20 digits


def parse_result(mode, stdout):
    """The whole stdout must be one bounded closed-grammar line; returns its fields."""
    if len(stdout) > 8192 or not stdout.endswith(b"\n") or stdout.count(b"\n") != 1:
        raise Invalid("not-one-bounded-line")
    text = stdout[:-1].decode("latin-1")
    if re.fullmatch(r"[\x20-\x7e]*", text) is None or "" in text.split(" "):
        raise Invalid("malformed")
    parts = text.split(" ")
    if len(parts) < 6 or parts[0] != "YSPROBE1" or parts[1] != mode:
        raise Invalid("malformed")
    digest, checks, domain, count, raw_records = parts[2], parts[3], parts[4], parts[5], parts[6:]
    names = CHECKS[mode]
    domain_ok = (re.fullmatch(r"linux-build-af-v1/([1-9][0-9]{0,4})", domain) is not None
                 and int(domain.rsplit("/", 1)[1]) <= 65536 or domain == "unknown") \
        if mode == "socket-family" else domain == "none"
    if (not re.fullmatch(r"[0-9a-f]{64}", digest) or checks not in ("complete", "incomplete") or not domain_ok
            or not uint(count, 32) or int(count) != len(raw_records) or len(raw_records) != len(names)):
        raise Invalid("malformed")
    records = []
    for name, raw in zip(names, raw_records):
        f = raw.split(":")
        if (len(f) != 10 or f[0] != name or f[1] not in PRE or f[2] not in ("0", "1") or f[3] not in ("0", "1")
                or f[4] not in OUTCOMES or not all(uint(x, 2147483647) for x in f[5:7])
                or not all(uint(x, 2 ** 64 - 1) for x in f[7:])):
            raise Invalid("malformed")
        records.append({"check": name, "prerequisite": f[1], "attempted": f[2] == "1",
                        "completed": f[3] == "1", "outcome": f[4], "cleanup_errno": int(f[6]),
                        "values": [int(x) for x in f[7:]]})
    for r in records:  # state consistency
        if (r["completed"] and not r["attempted"]) or (not r["attempted"] and r["outcome"] not in ("incomplete", "unsupported")) \
                or (r["outcome"] == "refused" and not (r["prerequisite"] == "ok" and r["completed"])):
            raise Invalid("inconsistent-record")
    all_done = all(r["prerequisite"] == "ok" and r["completed"] and r["cleanup_errno"] == 0
                   and r["outcome"] in ("success", "refused", "violation") for r in records)
    if checks == "complete" and not (all_done and domain != "unknown" and mode not in NEVER_COMPLETE):
        raise Invalid("inconsistent-checks")
    return {"digest": digest, "checks": checks, "domain": domain, "records": records, "raw": raw_records}


def run_facts_problem(receipt):
    """None when every existing fact lets a line count as completed-case evidence."""
    life, pay, down = receipt["lifecycle"], receipt["payload"], receipt["teardown"]
    for ok, why in ((life["admission"] == "admitted", "not-admitted"), (life["runtime"] == "completed", "runtime"),
                    (life["control_deadline"] == "met", "control-deadline"),
                    (pay["exit_state"] == "exited" and pay["exit_code"] == 0, "exit"),
                    (down["state"] == "confirmed", "teardown")):
        if not ok:
            return why
    return None


# --- socket-family domain evidence (R13.4: build header domain bound to the selected kernel) --
def domain_evidence_ok(ev):
    """{archive_sha256, kernel_sha256, build_domain_max, kernel_domain_max, families:[{family,aliases}]}: the
    families are exactly 0..kernel_domain_max-1, each once, an alias counted under one family."""
    try:
        fams = ev["families"]
        aliases = [a for f in fams for a in f["aliases"]]
        return (set(ev) == {"archive_sha256", "build_domain_max", "families", "kernel_domain_max", "kernel_sha256"}
                and all(re.fullmatch(r"[0-9a-f]{64}", ev[k]) for k in ("archive_sha256", "kernel_sha256"))
                and all(hs.is_int(ev[k]) and 1 <= ev[k] <= 65536 for k in ("build_domain_max", "kernel_domain_max"))
                and [f["family"] for f in fams] == list(range(ev["kernel_domain_max"]))
                and all(isinstance(a, str) and a for a in aliases) and len(set(aliases)) == len(aliases))
    except (KeyError, TypeError):
        return False


def socket_instruction(family):
    return b"YSPROBE1 socket-family %d\n" % family


def check_socket_cases(instructions, ev):
    """Empty list when `instructions` hold every family of the evidence exactly once."""
    seen = [int(i.split(b" ")[2]) for i in instructions]
    problems = ["duplicate:%d" % n for n in sorted(set(seen)) if seen.count(n) > 1]
    return problems + ["omitted:%d" % n for n in range(ev["kernel_domain_max"]) if n not in seen] \
        + ["unknown-family:%d" % n for n in sorted(set(seen)) if n >= ev["kernel_domain_max"]]


def socket_problem(case, parsed):
    """Why a socket line cannot stand for the evidence's family, else None."""
    ev, family = case.get("domain"), int(case["instruction"].split(b" ")[2])
    if ev is None:
        return "domain-evidence-missing"
    if parsed["domain"] != "linux-build-af-v1/%d" % ev["build_domain_max"]:
        return "domain-unknown" if parsed["domain"] == "unknown" else "domain-mismatch"
    if ev["build_domain_max"] < ev["kernel_domain_max"]:
        return "build-domain-smaller"
    rec = parsed["records"][0]
    raw = family in (AF_NETLINK, AF_PACKET)
    want = [family, (SOCK_RAW if raw else SOCK_STREAM) | SOCK_CLOEXEC, NETLINK_USERSOCK if family == AF_NETLINK else 0]
    if rec["attempted"] and rec["values"] != want:
        return "tuple-mismatch"
    if not rec["attempted"] and rec["values"][0] != family:
        return "tuple-mismatch"
    return None if rec["completed"] else "not-executed"


# --- the output-contract classification --------------------------------------------------
def classify(case, facts):
    """case: {mode, instruction (bytes), instruction_sha256 (the request's), domain?};
    facts: {receipt (receipt body), stdout, stderr, evidence [(name_hex, bytes)]} whose payload
    digests the caller already verified. No class is ever native fulfillment."""
    mode, receipt, out = case["mode"], facts["receipt"], facts["stdout"]
    base = {"native_fulfilled": False, "stdout_bytes": len(out), "stdout_sha256": sha(out)}

    def done(klass, reason=None, **more):
        return dict(base, **{"class": klass, "reason": reason}, **more)

    if receipt["lifecycle"]["admission"] != "admitted":
        return done("not-admitted")
    if receipt["payload"]["exit_state"] == "not-started":
        # No valid export: the host cannot say whether the probe ran, how far it got or why it stopped.
        return done("no-export", "runtime-error-no-export")
    if out in INPUT_ERRORS:
        return done(INPUT_ERRORS[out], "diagnostic-not-an-action")
    if mode in RAW_MODES:
        if facts["stderr"] or facts["evidence"]:
            return done("payload-mismatch", "unexpected-stream")
        if mode == "output-overflow":
            if out and out != b"x" * len(out) or len(out) > OUTPUT_TARGET:
                return done("payload-mismatch", "not-an-x-prefix")
            return done("output-prefix" if out else "payload-empty")
        if out == FORGED:
            return done("forged-complete", "text-never-authority")
        if out and FORGED.startswith(out):
            return done("forged-prefix", "text-never-authority")
        return done("payload-empty" if not out else "payload-mismatch")
    if not out:
        return done("no-result")
    try:
        parsed = parse_result(mode, out)
    except (Invalid, ValueError) as exc:   # ValueError: no conversion of untrusted text may abort the batch
        return done("invalid-result", str(exc))
    if parsed["digest"] != case["instruction_sha256"]:
        return done("binding-mismatch", "instruction-digest")
    problems = list(filter(None, [run_facts_problem(receipt)]))
    if parsed["checks"] != "complete":
        problems.append("checks-incomplete")
    if mode == "socket-family" and socket_problem(case, parsed):
        problems.append(socket_problem(case, parsed))
    evidence = [{"name_hex": n, "sha256": sha(c), "size_bytes": len(c)} for n, c in facts["evidence"]]
    return done("result-incomplete" if problems else "result-complete", ",".join(problems) or None,
                domain=parsed["domain"], records=parsed["raw"], evidence=evidence)


# --- sentinel fixtures: trusted controls outside the guest -------------------------------
def fixture_control(fx, root):
    """The approved exact path and role, a non-symlink regular file, length, digest and a read."""
    path = fx["path"]
    try:
        st = os.lstat(path)
        if (os.path.realpath(path) != path or not path.startswith(os.path.realpath(root) + "/")
                or not stat.S_ISREG(st.st_mode)):
            raise Invalid("fixture-substituted")
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as handle:
            data = handle.read(fx["size_bytes"] + 1)
    except OSError:
        raise Invalid("fixture-missing")
    if len(data) != fx["size_bytes"] or sha(data) != fx["sha256"]:
        raise Invalid("fixture-changed")
    return {"path": path, "role": fx["role"], "size_bytes": len(data), "sha256": fx["sha256"],
            "dev": st.st_dev, "ino": st.st_ino, "represents": SENTINEL_MEANING[fx["role"]]}


def sentinel_controls(fx, root, between):
    pre = fixture_control(fx, root)
    between()
    post = fixture_control(fx, root)
    if post != pre:
        raise Invalid("fixture-substituted")
    return {"pre": pre, "post": post}


def sentinel_instruction(fx):
    return b"YSPROBE1 %s-sentinel %s %d %s\n" % (fx["role"].encode(), fx["path"].encode().hex().encode(),
                                                  fx["size_bytes"], fx["sha256"].encode())


# --- measurement and the two trusted configurations --------------------------------------
def read_config(path):
    fd = -1
    try:
        fd = os.open(path, os.O_RDONLY)
        return hs.load_config(fd)
    except (OSError, hs.Refusal):
        raise Invalid("E_CONFIG")
    finally:
        if fd >= 0:
            os.close(fd)


def measure(config_path):
    body, raw = read_config(config_path)
    ids, rt = body["identity_paths"], body["runtime"]
    fds = {k: os.open(v, os.O_RDONLY) for k, v in ids.items() if k != "dyld_cache_files"}
    fds["dyld_cache_files"] = [os.open(p, os.O_RDONLY) for p in ids["dyld_cache_files"]]
    fds["runtime_vfkit"], fds["runtime_driver"] = os.open(rt["vfkit"], os.O_RDONLY), os.open(rt["driver"], os.O_RDONLY)
    with open(os.path.join(os.path.dirname(os.path.realpath(config_path)), "host-supervisor.py"), "rb") as handle:
        supervisor_raw = handle.read()
    with open(os.path.realpath(sys.executable), "rb") as handle:
        python_raw = handle.read()
    slots = hs.measure_identities(fds, b"", raw, supervisor_raw, python_raw)[0]
    for fd in fds.values():
        for one in (fd if isinstance(fd, list) else [fd]):
            os.close(one)
    del slots["verification_instructions"]
    if any(state != "observed" for state, _ in slots.values()) or len(slots) != 9:
        raise Invalid("E_MEASURE")
    return {slot: digest for slot, (_, digest) in slots.items()}


def configs_differ_exactly(v, p):
    """The two configurations differ in identity_paths.verifier, store_id, store_root, work_root only."""
    def rest(body):
        c = json.loads(json.dumps(body))
        c["identity_paths"].pop("verifier")
        for key in ("store_id", "store_root", "work_root"):
            c.pop(key)
        return c
    return (rest(v) == rest(p) and v["identity_paths"]["verifier"] != p["identity_paths"]["verifier"]
            and all(v[k] != p[k] for k in ("store_id", "store_root", "work_root")))


# --- receipts as the consumer reads them -------------------------------------------------
def load_evidence(cfg, request_raw, attempt_id, instruction_sha256):
    """The receipt body and its payload, every digest verified; any gap is unusable evidence."""
    base = os.path.join(cfg["body"]["store_root"], attempt_id)

    def stored(*parts):
        try:
            with open(os.path.join(base, *parts), "rb") as handle:
                return handle.read()
        except OSError:
            raise Invalid("evidence-unusable:missing")

    raw = stored("receipt.json")
    launch_sha = sha(request_raw)
    try:
        doc = json.loads(raw)
        b = doc["body"]
        shaped = (hs.canonical(doc) == raw and doc["kind"] == "sandbox_enforcement_receipt"
                  and doc["id"] == "receipt." + launch_sha and b["attempt"]["launch_request_sha256"] == launch_sha
                  and b["origin"]["store_id"] == cfg["body"]["store_id"]
                  and b["identities"]["verifier"] == {"state": "observed", "sha256": cfg["slots"]["verifier"]}
                  and b["identities"]["verification_instructions"] == {"state": "observed", "sha256": instruction_sha256})
        stdout, stderr, manifest = stored("payload", "stdout"), stored("payload", "stderr"), \
            stored("payload", "evidence-manifest.json")
        listed = json.loads(manifest)["body"]["files"]
        names = sorted(os.listdir(os.path.join(base, "payload", "evidence"))) \
            if os.path.isdir(os.path.join(base, "payload", "evidence")) else []
        contents = [stored("payload", "evidence", n) for n in names]
        sound = (sha(stdout) == b["payload"]["stdout_sha256"] and sha(stderr) == b["payload"]["stderr_sha256"]
                 and sha(manifest) == b["payload"]["evidence_manifest_sha256"]
                 and sorted((sha(c), len(c)) for c in contents) == sorted((f["sha256"], f["size_bytes"]) for f in listed))
        by_sha = {sha(c): c for c in contents}
        evidence = [(f["name_hex"], by_sha[f["sha256"]]) for f in listed] if sound else []
    except (KeyError, TypeError, ValueError, OSError):
        raise Invalid("evidence-unusable:shape")
    if not shaped:
        raise Invalid("evidence-unusable:binding")
    if not sound:
        raise Invalid("evidence-unusable:payload-digest")
    return {"receipt": b, "receipt_sha256": sha(raw), "stdout": stdout, "stderr": stderr, "evidence": evidence}


def consumer_check(checker, receipt_path, request, launch_sha, evaluation_raw):
    """The unchanged receipt check; only a `valid` verdict lets a case be used."""
    exp = hs.canonical({"body": {"attempt": dict(request["attempt"], launch_request_sha256=launch_sha),
                                 "control": request["control"], "store_id": request["store_id"],
                                 "subject": request["subject"]},
                        "id": "sandbox.expectation.qualify", "kind": "sandbox_receipt_expectation",
                        "schema_version": 1})
    with tempfile.TemporaryDirectory() as tmp:
        tmp = os.path.realpath(tmp)  # the unchanged checker accepts only physical paths
        for name, data in (("expectation.json", exp), ("evaluation.json", evaluation_raw)):
            with open(os.path.join(tmp, name), "wb") as handle:
                handle.write(data)
        proc = subprocess.run([os.path.realpath(checker), "check", os.path.realpath(receipt_path), os.path.join(tmp, "expectation.json"),
                               os.path.join(tmp, "evaluation.json")], capture_output=True, timeout=120)
    try:
        return json.loads(proc.stdout)["body"]["check_verdict"] if proc.returncode == 0 else "error"
    except (ValueError, KeyError, TypeError):
        return "error"


def qualification(cases, domain_ok):
    """Never `qualified` (R7.2); a clean case waives no other row."""
    reasons = {"qualification.cpu-wall-unbounded"}
    if any(c["class"] not in ("result-complete", "verifier-run") for c in cases):
        reasons.add("qualification.case-incomplete")
    if any(c.get("verdict") != "satisfied" for c in cases):
        reasons.add("qualification.receipt-not-satisfied")
    if not domain_ok:
        reasons.add("qualification.domain-evidence-missing")
    if any(c["mode"] in NEVER_COMPLETE for c in cases):
        reasons.add("qualification.native-obligation-unresolved")
    return {"qualification": "not-qualified", "reason_ids": sorted(reasons)}


# --- batches (spec R13.4): each accepted-set slot holds 1-8 digests --------------------------
def read_batches(dirpath):
    """The declared case list and its fixed partition; (body, case_list_sha256)."""
    with open(os.path.join(dirpath, "batches.json"), "rb") as handle:
        raw = handle.read()
    try:
        doc = json.loads(raw)
        body, cases = doc["body"], doc["body"]["cases"]
        digest = {c["case_id"]: c["instruction_sha256"] for c in cases}
        flat = [i for batch in body["batches"] for i in batch]
        ok = (hs.canonical(doc) == raw and set(doc) == {"body", "id", "kind", "schema_version"}
              and doc["kind"] == "sandbox_qualification_batches" and doc["schema_version"] == 1
              and set(body) == {"batches", "cases"} and body["batches"]
              and all(set(c) == {"case_id", "configuration", "instruction_sha256"} and c["configuration"] in ("verifier", "probe")
                      and re.fullmatch(r"[0-9a-f]{64}", c["instruction_sha256"]) for c in cases)
              and len(digest) == len(cases) and sorted(flat) == sorted(digest) and len(set(flat)) == len(flat)
              and all(b == sorted(set(b)) and 1 <= len({digest[i] for i in b}) <= 8 for b in body["batches"]))
    except (KeyError, TypeError, ValueError):
        ok = False
    if not ok:
        raise Invalid("E_CASES")
    return body, sha(raw)


def batch_digests(bplan, k):
    declared = {c["case_id"]: c["instruction_sha256"] for c in bplan["cases"]}
    return sorted({declared[i] for i in bplan["batches"][k]})


def expected_identities(configs, digests):
    """The accepted-set identities of a batch: the union of both configurations' slots."""
    slots = [c["slots"] for c in configs.values()]
    return dict({s: sorted({m[s] for m in slots}) for s in slots[0]}, verification_instructions=digests)


def accepted_check(cfgs, expected, checker):
    """Both installed accepted sets (and the checker tree's copy) must hold exactly `expected`."""
    shas = set()
    for cfg in cfgs.values():
        fd = -1
        try:
            fd = os.open(cfg["body"]["installed_files"]["accepted_set"], os.O_RDONLY)
            digest, envs = hs.check_accepted_set(fd)
        except (OSError, hs.Refusal):
            raise Invalid("E_ACCEPTED")
        entry = next((e for e in envs if e["environment_id"] == cfg["body"]["environment_id"]), None)
        if entry is None or entry["identities"] != expected:
            raise Invalid("E_ACCEPTED")
        shas.add(digest)
    if checker:
        try:
            with open(os.path.join(os.path.dirname(os.path.realpath(checker)), "accepted-identities.json"), "rb") as handle:
                shas.add(sha(handle.read()))
        except OSError:
            raise Invalid("E_ACCEPTED")
    if len(shas) != 1:
        raise Invalid("E_ACCEPTED")
    return shas.pop()


# --- dry-run / run / aggregate ---------------------------------------------------------------
def prepare(dirpath, dry):
    """Validates the whole case list, both configurations, the fixtures and the domain evidence."""
    with open(os.path.join(dirpath, "cases.json"), "rb") as handle:
        plan = json.loads(handle.read())
    bplan, plan_sha = read_batches(dirpath)
    declared = {c["case_id"]: c for c in bplan["cases"]}
    cfgs = {}
    for name in ("verifier", "probe"):
        install = plan["configs"][name]["install_dir"]
        body, _ = read_config(os.path.join(install, "host-config.json"))
        cfgs[name] = {"body": body, "install_dir": install, "launch": plan["configs"][name]["launch"],
                      "slots": measure(os.path.join(install, "host-config.json"))}
    if not configs_differ_exactly(cfgs["verifier"]["body"], cfgs["probe"]["body"]):
        raise Invalid("E_CONFIGS")
    if not dry and not plan.get("checker"):
        raise Invalid("E_CHECKER")
    fixtures = {r: dict(plan["fixtures"][r], role=r) for r in ("host", "sibling")}
    if fixtures["host"]["path"] == fixtures["sibling"]["path"] or fixtures["host"]["sha256"] == fixtures["sibling"]["sha256"]:
        raise Invalid("E_FIXTURES")
    ev = plan.get("domain_evidence")
    if ev is not None and (not domain_evidence_ok(ev) or ev["archive_sha256"] != cfgs["probe"]["slots"]["toolchain"]
                           or ev["kernel_sha256"] != cfgs["probe"]["slots"]["guest_kernel"]):
        raise Invalid("E_DOMAIN")
    if sorted(e["id"] for e in plan["cases"]) != sorted(declared):
        raise Invalid("E_CASES")
    prepared, socket_instructions = {}, []
    for entry in plan["cases"]:
        cfg, pkg_raw = cfgs[entry["config"]], open(os.path.join(dirpath, entry["package"]), "rb").read()
        try:
            named = hs.parse_package(pkg_raw)
        except hs.Refusal:
            raise Invalid("E_CASES")
        request, instruction = json.loads(named["request.json"])["body"], named["instruction"]
        if (request["store_id"] != cfg["body"]["store_id"] or request["instruction_sha256"] != sha(instruction)
                or declared[entry["id"]]["configuration"] != entry["config"]
                or declared[entry["id"]]["instruction_sha256"] != sha(instruction)):
            raise Invalid("E_CASES")
        mode = "verifier"
        if entry["config"] == "probe":
            fields = instruction.decode("ascii").rstrip("\n").split(" ")
            mode = fields[1] if len(fields) > 1 else ""
            if mode not in CHECKS and mode not in RAW_MODES:
                raise Invalid("E_CASES")
        fx = fixtures.get(mode[:-9]) if mode.endswith("-sentinel") else None
        if mode == "socket-family":
            if re.fullmatch(rb"YSPROBE1 socket-family (0|[1-9][0-9]{0,4})\n", instruction) is None:
                raise Invalid("E_CASES")
            socket_instructions.append(instruction)
        if mode.endswith("-sentinel") and instruction != sentinel_instruction(fx):
            raise Invalid("E_CASES")
        prepared[entry["id"]] = (entry, cfg, pkg_raw, named, request, instruction, mode, fx)
    if ev is not None and (not socket_instructions or check_socket_cases(socket_instructions, ev)):
        raise Invalid("E_CASES")
    return {"plan": plan, "bplan": bplan, "plan_sha": plan_sha, "cfgs": cfgs, "ev": ev, "prepared": prepared, "dir": dirpath}


def batch_record(raw_body):
    return hs.canonical({"body": raw_body, "id": "sandbox.qualification-batch", "kind": "sandbox_qualification_batch",
                         "schema_version": 1})


def run_batch(st, k, dry):
    """Launches each case of batch k once; one canonical sandbox_qualification_batch record."""
    plan, cfgs, ev, dirpath = st["plan"], st["cfgs"], st["ev"], st["dir"]
    expected = expected_identities(cfgs, batch_digests(st["bplan"], k))
    accepted_sha = accepted_check(cfgs, expected, plan.get("checker"))
    env = {key: v for key, v in os.environ.items() if not key.startswith("DYLD_")}
    records = []
    for cid in st["bplan"]["batches"][k]:
        entry, cfg, pkg_raw, named, request, instruction, mode, fx = st["prepared"][cid]
        launch_env = dict(env)
        if dry and "scenario" in entry:
            scenario = os.path.join(dirpath, "scenario-%s.json" % entry["id"])
            with open(scenario, "w") as handle:
                json.dump(entry["scenario"], handle)
            launch_env["YSTACK_FAKE_SCENARIO"] = scenario
        status = []

        def launch():
            proc = subprocess.run(cfg["launch"], input=pkg_raw, cwd=cfg["install_dir"], env=launch_env,
                                  capture_output=True, timeout=300)
            status.append((proc.returncode, proc.stderr.decode("utf-8", "replace").strip()))

        attempt = request["attempt"]["attempt_id"]
        record = {"id": entry["id"], "config": entry["config"], "mode": mode, "attempt_id": attempt,
                  "instruction_sha256": sha(instruction), "native_fulfilled": False}
        try:
            if fx:
                record["controls"] = sentinel_controls(fx, plan["sentinel_root"], launch)
            else:
                launch()
            if status[0][0] != 0:
                raise Invalid("launch-refused:" + status[0][1])
            facts = load_evidence(cfg, named["request.json"], attempt, sha(instruction))
            receipt = facts["receipt"]
            record.update(launch_request_sha256=sha(named["request.json"]), receipt_sha256=facts["receipt_sha256"],
                          verdict=receipt["outcome"]["verdict"], outcome_reason_ids=receipt["outcome"]["reason_ids"],
                          stderr_sha256=receipt["payload"]["stderr_sha256"],
                          evidence_manifest_sha256=receipt["payload"]["evidence_manifest_sha256"],
                          accepted_set_sha256=receipt["origin"]["accepted_set_sha256"])
            if plan.get("checker"):
                path = os.path.join(cfg["body"]["store_root"], attempt, "receipt.json")
                record["receipt_check"] = consumer_check(plan["checker"], path, request, record["launch_request_sha256"],
                                                         named["evaluation.json"])
                if record["receipt_check"] != "valid":
                    raise Invalid("receipt-check-" + record["receipt_check"])
            if mode == "verifier":
                record.update({"class": "verifier-run", "reason": None, "exit_state": receipt["payload"]["exit_state"],
                               "exit_code": receipt["payload"]["exit_code"],
                               "stdout_sha256": receipt["payload"]["stdout_sha256"]})
            else:
                record.update(classify({"mode": mode, "instruction": instruction, "instruction_sha256": sha(instruction),
                                        "domain": ev}, facts))
        except Invalid as exc:
            klass = "fixture-invalid" if str(exc).startswith("fixture-") else "unusable"
            record.update({"class": klass, "reason": str(exc)})
        records.append(record)
    return batch_record({"accepted_identities": expected, "accepted_set_sha256": accepted_sha, "cases": records,
                         "case_list_sha256": st["plan_sha"], "dry_run": dry, "k": k,
                         "domain_evidence_sha256": sha(hs.canonical(ev)) if ev is not None else None,
                         "environment_id": cfgs["probe"]["body"]["environment_id"],
                         "configurations": {n: {"store_id": c["body"]["store_id"], "slots": c["slots"]} for n, c in cfgs.items()}})


def install_accepted(st, k):
    """dry-run only: installs batch k's accepted set into the fixture tree."""
    expected = expected_identities(st["cfgs"], batch_digests(st["bplan"], k))
    for path in {c["body"]["installed_files"]["accepted_set"] for c in st["cfgs"].values()}:
        doc = json.load(open(path))
        for env in doc["body"]["environments"]:
            env["identities"] = expected
        os.chmod(path, 0o644)
        with open(path, "wb") as handle:
            handle.write(hs.canonical(doc))
        os.chmod(path, 0o444)


def run_dry(dirpath):
    st = prepare(dirpath, True)
    raws = []
    for k in range(len(st["bplan"]["batches"])):
        install_accepted(st, k)
        raws.append(run_batch(st, k, True))
        with open(os.path.join(dirpath, "batch-%d.json" % k), "wb") as handle:
            handle.write(raws[-1])
    return aggregate(dirpath, raws)


def run_one(dirpath, k):
    st = prepare(dirpath, False)
    if not 0 <= k < len(st["bplan"]["batches"]):
        raise Invalid("E_USAGE")
    accepted_check(st["cfgs"], expected_identities(st["cfgs"], batch_digests(st["bplan"], k)), st["plan"].get("checker"))
    path = os.path.join(dirpath, "batch-%d.json" % k)
    if os.path.exists(path):
        raise Invalid("E_BATCH_EXISTS")
    raw = run_batch(st, k, False)
    with open(path, "xb") as handle:
        handle.write(raw)
    return raw


def aggregate(dirpath, raws):
    """One sandbox_qualification_record, complete only if the batches cover the plan exactly once."""
    bplan, plan_sha = read_batches(dirpath)
    with open(os.path.join(dirpath, "cases.json"), "rb") as handle:
        plan = json.loads(handle.read())
    declared = {c["case_id"]: c for c in bplan["cases"]}
    by_k, reasons = {}, set()
    for raw in raws:
        try:
            doc = json.loads(raw)
            body = doc["body"]
            assert doc["kind"] == "sandbox_qualification_batch" and hs.canonical(doc) == raw and hs.is_int(body["k"])
        except (ValueError, KeyError, TypeError, AssertionError):
            raise Invalid("E_RECORD")
        by_k.setdefault(body["k"], []).append((raw, body))
    firsts = []
    for k in range(len(bplan["batches"])):
        got = by_k.get(k, [])
        if not got:
            reasons.add("qualification.batch-missing")
        else:
            firsts.append(got[0][1])
            if len(got) > 1:
                reasons.add("qualification.batch-duplicate" if len({sha(r) for r, _ in got}) == 1 else "qualification.batch-rerun")
    if not firsts or set(by_k) - set(range(len(bplan["batches"]))):
        reasons.add("qualification.binding-mismatch")
    if not firsts:
        raise Invalid("E_RECORD")
    ref = firsts[0]
    for body in firsts:
        k = body["k"]
        if any(body[key] != ref[key] for key in ("configurations", "domain_evidence_sha256", "dry_run", "environment_id")) \
                or body["case_list_sha256"] != plan_sha or sorted(c["id"] for c in body["cases"]) != bplan["batches"][k] \
                or any(c["config"] != declared[c["id"]]["configuration"] or c["instruction_sha256"] != declared[c["id"]]["instruction_sha256"]
                       for c in body["cases"] if c["id"] in declared):
            reasons.add("qualification.binding-mismatch")
        if body["accepted_identities"] != expected_identities(ref["configurations"], batch_digests(bplan, k)) \
                or any(c.get("accepted_set_sha256", body["accepted_set_sha256"]) != body["accepted_set_sha256"] for c in body["cases"]):
            reasons.add("qualification.accepted-set-mismatch")
    for name in ("verifier", "probe"):   # each store against its own configuration's named attempts only
        named = {c["attempt_id"] for body in firsts for c in body["cases"] if c["config"] == name}
        store = read_config(os.path.join(plan["configs"][name]["install_dir"], "host-config.json"))[0]["store_root"]
        if set(os.listdir(store)) - named:
            reasons.add("qualification.batch-rerun")   # a receipt no batch record names
    order = [c["case_id"] for c in bplan["cases"]]
    cases = sorted((c for body in firsts for c in body["cases"]), key=lambda c: order.index(c["id"]) if c["id"] in order else len(order))
    result = qualification(cases, ref["domain_evidence_sha256"] is not None)
    body = {"batches": len(bplan["batches"]), "case_list_sha256": plan_sha, "cases": cases, "complete": not reasons,
            "configurations": ref["configurations"], "domain_evidence_sha256": ref["domain_evidence_sha256"],
            "dry_run": ref["dry_run"], "environment_id": ref["environment_id"],
            "qualification": result["qualification"], "reason_ids": sorted(set(result["reason_ids"]) | reasons)}
    return hs.canonical({"body": body, "id": "sandbox.qualification-record", "kind": "sandbox_qualification_record",
                         "schema_version": 1})


def main(argv):
    cmd, rest = (argv[0], argv[1:]) if argv else ("", [])
    try:
        if cmd == "measure" and len(rest) == 1:
            sys.stdout.buffer.write(hs.canonical(measure(rest[0])))
        elif cmd == "instruction-digest" and len(rest) == 1:
            with open(rest[0], "rb") as handle:
                sys.stdout.write(sha(handle.read()) + "\n")
        elif cmd == "check-kernel-config" and len(rest) == 1:
            with open(rest[0], "rb") as handle:
                values = hs.kernel_config_values(handle.read())
            missing = [o for o in hs.KERNEL_REQUIRED_OPTIONS if values.get(o) != "y"]
            if missing or len([o for o in hs.KERNEL_HZ_OPTIONS if values.get(o) == "y"]) != 1:
                raise Invalid("E_KERNEL_CONFIG " + " ".join(missing))
        elif cmd == "dry-run" and len(rest) == 1:
            sys.stdout.buffer.write(run_dry(rest[0]))
        elif cmd == "run" and len(rest) == 3 and rest[1] == "--batch" and re.fullmatch("[0-9]{1,4}", rest[2]):
            sys.stdout.buffer.write(run_one(rest[0], int(rest[2])))
        elif cmd == "aggregate" and len(rest) >= 2:
            sys.stdout.buffer.write(aggregate(rest[0], [open(f, "rb").read() for f in rest[1:]]))
        else:
            raise Invalid("E_USAGE")
    except (Invalid, OSError, KeyError, ValueError, TypeError, subprocess.SubprocessError) as exc:
        sys.stderr.write((str(exc) if isinstance(exc, Invalid) else "E_RUNTIME") + "\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
