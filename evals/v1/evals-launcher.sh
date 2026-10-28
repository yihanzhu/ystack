#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

# work/eval-seeding-deterministic/spec.md: fixed C2 descriptor custody.
c2_program='import ast
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import stat
import struct
import sys
import tempfile

_C2_KINDS = {
    "START": {"kind", "version", "window_sha256", "ordinal", "predecessor_sha256", "mode", "seed_sha256s", "result_sha256s", "case_ids", "root_identity", "before", "tail_reservation"},
    "READY": {"kind", "version", "ordinal", "start_sha256", "input_sha256s", "observed_predecessor_sha256", "acquisition_delta", "leaf_pid", "leaf_ppid"},
    "GO": {"kind", "version", "ordinal", "start_sha256", "ready_sha256", "caller_delta", "tail_reservation"},
    "END": {"kind", "version", "ordinal", "start_sha256", "receipt_sha256", "result_sha256", "outcome", "child_delta", "retained", "errors", "unknown"},
}
_C2_CASES = {"malicious.incident-symptom-text", "malicious.checked-file-bytes", "malicious.commit-message", "malicious.unread-forge-text"}
_C2_SCALARS = ("read_bytes", "write_bytes", "physical_bytes", "files", "export_read_bytes", "export_write_bytes", "export_physical_bytes", "export_files", "close_calls", "held_close_calls", "observation_calls")
_C2_ACCOUNT_FIELDS = ("logical_bytes", "read_bytes", "write_bytes", "physical_bytes", "files", "occurrences")
_C2_CLASSES = ("L", "W", "M", "raw", "unresolved")
_C2_LIMIT = 1048576
_C2_HELPERS_SHA256 = "a2c74b2b394495e98e0ff627434d21bed10a105a12f9943f706d77e5055b2d33"

class C2Refusal(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code

def c2_cancelled(error):
    return isinstance(error, KeyboardInterrupt) or getattr(error, "_scope_signal_cancel", False) or getattr(error, "_D_source_cancel", False)

def c2_first(first, later):
    return later if first is None or c2_cancelled(later) and not c2_cancelled(first) else first

def c2_require(value, code="E_RELATION"):
    if not value:raise C2Refusal(code)

def c2_sha(value, work=None):
    if work is not None:work["seed_processing"]["H"] += len(value)
    return hashlib.sha256(value).hexdigest()

def c2_canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False) + "\n").encode()

def c2_message(value, kind):
    c2_require(type(value) is dict and set(value) == _C2_KINDS[kind]
        and value["kind"] == kind and type(value["version"]) is int and value["version"] == 1)
    c2_require(type(value["ordinal"]) is int and 0 <= value["ordinal"] < 4)
    if kind == "START":
        c2_require(value["mode"] in {"run", "dashboard"} and type(value["case_ids"]) is list
            and 1 <= len(value["case_ids"]) <= 4 and len(set(value["case_ids"])) == len(value["case_ids"])
            and set(value["case_ids"]) <= _C2_CASES)
        c2_require(type(value["seed_sha256s"]) is list and type(value["result_sha256s"]) is list
            and len(value["seed_sha256s"]) == (1 if value["mode"] == "run" else 2)
            and len(value["result_sha256s"]) == (0 if value["mode"] == "run" else 2))
    if kind == "READY":
        c2_require(all(type(value[key]) is int and value[key] > 0 for key in ("leaf_pid", "leaf_ppid")))
    if kind == "END":
        c2_require(value["outcome"] in {"completed", "refused"}
            and (value["result_sha256"] is None) == (value["outcome"] == "refused")
            and all(type(value[key]) is list for key in ("retained", "errors", "unknown")))
    for key in ("window_sha256", "predecessor_sha256", "start_sha256", "ready_sha256", "receipt_sha256", "observed_predecessor_sha256", "result_sha256"):
        if key not in value or value[key] is None:continue
        item = value[key]
        c2_require(type(item) is str and len(item) == 64 and all(char in "0123456789abcdef" for char in item))
    return value

def c2_wire_room(work, amount, field):
    c2_require(type(amount) is int and amount >= 0 and field in {"R", "W"}, "E_LIMIT")
    c2_nonruntime_room(work, amount, False, read_only=field == "R", writing=field == "W", physical=False)
    candidate = dict(work)
    key = "read_bytes" if field == "R" else "write_bytes"
    candidate[key] += amount
    c._capture_copy_room(candidate, 0, False)

def c2_nonruntime_room(work, amount, exported, *, read_only=False, writing=False, files=0,
                       case_before=None, total=None, window_work=None, window_before=None, physical=True):
    fields = ("read_bytes", "write_bytes", "physical_bytes", "files", "export_read_bytes",
              "export_write_bytes", "export_physical_bytes", "export_files")
    admitted = (window_work or work).get("C2_admitted_before")
    reservation = (window_work or work).get("C2_tail_reservation")
    tail_start = (window_work or work).get("C2_tail_start")
    c2_require(tail_start is None or case_before is None, "E_LIMIT")
    planned = {key: 0 for key in fields}
    planned["files"] = files
    if exported:planned["export_files"] = files
    if read_only:
        planned["read_bytes"] = amount
        if exported:planned["export_read_bytes"] = amount
    elif writing:
        planned["write_bytes"] = amount
        if physical:planned["physical_bytes"] = amount
        if exported:
            planned["export_write_bytes"] = amount
            if physical:planned["export_physical_bytes"] = amount
    scopes = []
    if admitted is not None:
        scopes.append((admitted["window"], window_work or work, False, reservation["window"]))
    elif window_before is not None:scopes.append((window_before, window_work, False, None))
    else:scopes.append((None, work, False, None))
    if case_before is not None:
        scopes.append((case_before, total, True, work.get("C2_case_reservation")))
    elif admitted is not None:
        scopes.append((admitted["common"], c2_counters(work)["common"], True, reservation["common"]))
    bindings, tail_rooms = [], []
    for before, current, per_case, reserved in scopes:
        is_common = admitted is not None and case_before is None and per_case
        c2_require(not (before or {}).get("unknown") and not current.get("unknown"), "E_LIMIT")
        candidate = {key: (before[key] if before else 0) + current.get(key, 0)
            + ((work.get(key, 0) - work.get("transferred_" + key, 0)) if current is not work and not is_common else 0)
            for key in fields}
        if not per_case:
            for leaf in (window_work or work).get("C2_case_leaves", {}).values():
                if leaf is work:continue
                for key in fields:
                    current_value, prior_value = leaf.get(key), leaf.get("transferred_" + key, 0)
                    c2_require(type(current_value) is int and type(prior_value) is int and 0 <= prior_value <= current_value, "E_LIMIT")
                    candidate[key] += current_value - prior_value
        if tail_start is not None:
            c2_require(reserved is not None, "E_LIMIT")
            baseline = tail_start["common" if is_common else "window"]
            remaining = {}
            for key in fields:
                value, initial, limit = current.get(key), baseline.get(key), reserved.get(key)
                c2_require(all(type(item) is int and item >= 0 for item in (value, initial, limit))
                    and 0 <= value - initial <= limit, "E_LIMIT")
                remaining[key] = limit - (value - initial)
                c2_require(planned[key] <= remaining[key], "E_LIMIT")
            byte_fields = fields[:3] + fields[4:7]
            room = tuple(remaining[key] for key in byte_fields)
            room += tuple(remaining[key] - remaining["export_" + key] for key in fields[:3])
            room += (remaining["files"], remaining["export_files"])
            c2_require(all(value >= 0 for value in room), "E_LIMIT")
            tail_rooms.append(room)
            occupancy = {key: candidate[key] + remaining[key] for key in fields}
            bindings.append((dict(candidate), per_case))
        else:
            candidate = {key: candidate[key] + (reserved[key] if reserved else 0) for key in fields}
            bindings.append((dict(candidate), per_case))
            occupancy = {key: candidate[key] + planned[key] for key in fields}
        c._capture_copy_room(occupancy, 0, exported, case=per_case)
        c2_require(occupancy["files"] <= 256 and occupancy["export_files"] <= (16 if per_case else 64), "E_LIMIT")
    if len(bindings) == 2:
        baseline, room = c._capture_copy_budget_values(work, tuple(bindings))
        for remaining in tail_rooms:room = tuple(min(limit, unused) for limit, unused in zip(room, remaining))
        work["_capture_copy_budget"] = baseline, room
        c._capture_copy_budget_room(work, 0, exported, files=files)
    else:c2_require("_capture_copy_budget" not in work, "E_LIMIT")

class C2Channel:
    def __init__(self, fd, work):
        self.fd, self.owner, self.work = fd, c, work
        self.received, self.sent = [], []
        self.read_bytes, self.write_bytes = 0, 0
        self.read_fragments = []
    def charge(self, field, amount):
        c2_require(type(amount) is int and amount >= 0)
        key = "read_bytes" if field == "R" else "write_bytes"
        self.work[key] += amount
        self.owner._capture_account(self.work, "M", key, amount)
        counts = self.work.setdefault("seed_processing", {})
        counts[field] = counts.get(field, 0) + amount
        if field == "W":counts["C"] = counts.get("C", 0) + amount
    def read_exact(self, count):
        chunks, remaining = [], count
        while remaining:
            amount = min(65536, remaining)
            c2_wire_room(self.work, amount, "R")
            try:raw = os.read(self.fd, amount)
            except BaseException as error:
                self.work["C2_read_incomplete"] = True
                self.owner._capture_observation_error(self.work, "M", "C2.control.read", error)
                raise
            self.read_fragments.append(raw)
            self.read_bytes += len(raw)
            try:self.charge("R", len(raw))
            except BaseException:
                self.work["C2_read_incomplete"] = True
                raise
            c2_require(raw, "E_RUNTIME")
            chunks.append(raw);remaining -= len(raw)
        c2_wire_room(self.work, count, "R")
        try:result = b"".join(chunks)
        except BaseException:
            self.work["C2_join_incomplete"] = True
            raise
        self.work["read_bytes"] += len(result)
        self.owner._capture_account(self.work, "M", "read_bytes", len(result))
        return result
    def receive(self, kind):
        header = self.read_exact(4)
        size = struct.unpack(">I", header)[0]
        c2_require(0 < size <= _C2_LIMIT, "E_LIMIT")
        raw = self.read_exact(size)
        c2_wire_room(self.work, len(raw), "R")
        self.work["C2_parse_unknown"] = True
        try:value = json.loads(raw)
        except BaseException:
            self.work["C2_parse_incomplete"] = True
            raise
        self.work["C2_parse_unknown"] = False
        self.owner._capture_account(self.work, "M", "read_bytes", len(raw))
        self.work["read_bytes"] += len(raw)
        rebuilt = self.encode(value)
        c2_wire_room(self.work, 2 * len(raw), "R")
        equal = rebuilt == raw
        self.owner._capture_account(self.work, "M", "read_bytes", 2 * len(raw))
        self.work["read_bytes"] += 2 * len(raw)
        c2_require(equal, "E_CANONICAL")
        c2_message(value, kind)
        self.received.append((kind, raw))
        return value, raw
    def encode(self, value):
        before = self.work["read_bytes"]
        first = None
        try:
            raw = self.owner._private_capture_observations(value, self.work, self.work)
            self.owner._capture_account(self.work, "M", "logical_bytes", len(raw))
            self.owner._capture_account(self.work, "M", "occurrences", 1)
            return raw
        except BaseException as error:
            first = error;self.work["C2_encode_incomplete"] = True
            raise
        finally:
            try:self.owner._capture_account(self.work, "M", "read_bytes", self.work["read_bytes"] - before)
            except BaseException as error:
                self.work["C2_encode_accounting_incomplete"] = True
                raise c2_first(first, error)
    def send(self, value):
        c2_message(value, value["kind"])
        raw = self.encode(value)
        c2_require(0 < len(raw) <= _C2_LIMIT, "E_LIMIT")
        header = struct.pack(">I", len(raw))
        self.owner._capture_account(self.work, "M", "logical_bytes", 4)
        self.owner._capture_account(self.work, "M", "occurrences", 1)
        count = 0
        for item in (header, raw):
            view = memoryview(item)
            while view:
                c2_wire_room(self.work, min(65536, len(view)), "W")
                amount = os.write(self.fd, view[:65536])
                c2_require(0 < amount <= min(65536, len(view)), "E_RUNTIME")
                self.charge("W", amount);self.write_bytes += amount;count += amount
                view = view[amount:]
        self.sent.append((value["kind"], raw, count))
        return raw, count

def c2_fresh_work(identity):
    owner = c
    work = {"accounting_owner": identity}
    owner._capture_work_values(work, identity)
    for key in _C2_SCALARS:work.setdefault(key, 0)
    work["runtime"] = {key: 0 for key in owner._RUNTIME_FIELDS}
    work["accounting"] = {kind: {key: 0 for key in _C2_ACCOUNT_FIELDS} for kind in _C2_CLASSES}
    work["seed_processing"] = {key: 0 for key in ("R", "W", "H", "E", "C")}
    return work

def c2_counter_values(work):
    owner = c
    def scalar(values, key):
        value = values.get(key, "UNKNOWN")
        c2_require(value == "UNKNOWN" or type(value) is int and 0 <= value < 1 << 64, "E_LIMIT")
        return value
    result = {key: scalar(work, key) for key in _C2_SCALARS}
    result["runtime"] = {key: scalar(work.get("runtime", {}), key) for key in owner._RUNTIME_FIELDS}
    result["accounting"] = {kind: {key: scalar(work.get("accounting", {}).get(kind, {}), key) for key in _C2_ACCOUNT_FIELDS} for kind in _C2_CLASSES}
    result["seed_processing"] = {key: scalar(work.get("seed_processing", {}), key) for key in ("R", "W", "H", "E", "C")}
    result["incomplete"] = sorted(key for key, value in work.items() if key.endswith("incomplete") and value)
    source = work.get("source_work")
    if source is not None:
        result["source"] = {key: value for key, value in source.items() if type(value) is int}
        result["source"]["failures"] = list(source["failures"])
        result["source"]["failures"].extend({"site": "close", "row": index, "return": row[-2], "errno": row[-1]}
            for index, row in enumerate(source["rows"]) if row[0] == "close" and row[-2] != 0)
        result["source"]["registry_buffer_processing"] = work.get("source_processing_unknown", "UNKNOWN")
        result["source"]["data_and_close_complete"] = source["data_and_close_complete"]
    result["unknown"] = {key: value for key, value in work.items() if key.endswith("_unknown") and value}
    return result

class C2Sources:
    def __init__(self, launcher, target):
        import re, shlex
        self.namespace, self.failure, self.closed = None, None, False
        self.launcher = launcher
        with open(launcher, "rb") as source:
            before = os.fstat(source.fileno())
            c2_require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
                and before.st_uid in {0, os.geteuid()} and not before.st_mode & 0o022
                and before.st_size <= _C2_LIMIT, "E_STALE")
            raw = source.read(_C2_LIMIT + 1)
            after = os.fstat(source.fileno())
            c2_require(len(raw) == before.st_size, "E_STALE")
        self.launcher_raw = raw
        text = raw.decode("utf-8")
        self.helpers = text[text.index("\nemit_error() {"):text.index("\n# Fixed public entry;")]
        c2_require(c2_sha(self.helpers.encode()) == _C2_HELPERS_SHA256, "E_STALE")
        body = text.split("<<'"'"'PY_SHADOW_SOURCE'"'"'\n", 1)[1].split("\nPY_SHADOW_SOURCE", 1)[0]
        c2_require(c2_sha(body.encode()) == "7ffa1e52245e132723fe0c00b1fe16a6b5119448ca45c5119877d342de40e789", "E_STALE")
        table_body = text.split("\nshadow_source_rows() {\n", 1)[1].split("\n}\n", 1)[0]
        table_body = table_body.split(r"/usr/bin/printf '"'"'%s\n'"'"'", 1)[1]
        generation = re.findall(r"^generation=(g-[0-9a-f]{64})$", text, re.M)
        c2_require(len(generation) == 1, "E_STALE")
        entries = shlex.split(table_body.replace("\\\n", ""))
        table = "\n".join(entry.replace("${record_generation}", generation[0]) for entry in entries) + "\n"
        tree = ast.parse(body)
        definitions = []
        for node in tree.body:
            if isinstance(node, ast.For):break
            if isinstance(node, ast.Assign) and any(isinstance(item, ast.Tuple) for item in node.targets):
                if ast.get_source_segment(body, node).startswith("source_root, target_root, table ="):continue
            definitions.append(node)
        namespace = {"__name__": "_ystack_fixed_D84_owner", "source_root": str(Path(launcher).parents[2]),
            "target_root": target, "table": table}
        exec(compile(ast.Module(body=definitions, type_ignores=[]), str(launcher) + ":D84", "exec"), namespace)
        self.namespace = namespace
        original_main = next(node for node in tree.body if isinstance(node, ast.Try))
        self.root_guard = compile(ast.Module(body=[original_main.body[0]], type_ignores=[]), str(launcher) + ":D84-root", "exec")
        self.validate_root(target)
        c2_require(namespace["identity"](before) == namespace["identity"](after), "E_STALE")
        def interrupted(number, frame):
            try:namespace["interrupt"](number, frame)
            except InterruptedError as error:
                error._scope_signal_cancel = True
                raise
        self.interrupted = interrupted
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):signal.signal(number, interrupted)
        namespace["work"]["launcher_definition_bytes"] = len(raw)
        namespace["work"]["read_bytes"] += len(raw)
        namespace["work"]["launcher_definition_hash_bytes"] = len(body.encode()) + len(self.helpers.encode())
        namespace["work"]["sha_bytes"] += namespace["work"]["launcher_definition_hash_bytes"]
        try:
            self.rows = namespace["parse_table"]()
            namespace["source_inputs"](self.rows)
        except BaseException as error:
            self.failure = error
            self.close(error)
            raise
    def validate_root(self, target):
        self.namespace["target_root"] = target
        exec(self.root_guard, self.namespace)
    @property
    def work(self):return self.namespace["work"]
    def load_consumer(self):
        global c
        name = "shadow/v1/_consumer.py"
        row = self.namespace["sources"][name]
        expected, size, _mode = self.rows[name]
        self.namespace["check"](row)
        os.lseek(row["fd"], 0, os.SEEK_SET)
        chunks, remaining = [], size
        while remaining:
            item = self.namespace["read_chunk"](row, min(65536, remaining))
            c2_require(item, "E_STALE");chunks.append(item);remaining -= len(item)
        raw = b"".join(chunks)
        self.work["read_bytes"] += len(raw)
        self.work["sha_bytes"] += len(raw)
        c2_require(c2_sha(raw) == expected, "E_STALE")
        self.namespace["check"](row)
        path = self.namespace["source_root"] + "/" + name
        spec = importlib.util.spec_from_file_location("_ystack_C2_consumer", path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        try:exec(compile(raw, path, "exec"), module.__dict__)
        except BaseException:
            del sys.modules[spec.name];raise
        self.namespace["check"](row)
        c = module
        return module
    def reconcile(self, work):
        previous = self.__dict__.setdefault("transferred", {})
        work["source_work"] = self.work
        fields = (("read_bytes", "read_bytes"), ("write_bytes", "write_bytes"),
            ("physical_bytes", "physical_bytes"), ("created_files", "files"), ("close_calls", "close_calls"))
        try:
            for source, target in fields:
                amount, prior = self.work[source], previous.get(source, 0)
                c2_require(type(amount) is int and amount >= prior, "E_LIMIT")
                delta = amount - prior
                work[target] += delta
                if target in {"read_bytes", "write_bytes", "physical_bytes", "files"}:c._capture_account(work, "L", target, delta)
                previous[source] = amount
            for source, target in (("sha_bytes", "H"), ("equality_bytes", "E"), ("copy_bytes", "C")):
                amount, prior = self.work[source], previous.get(source, 0)
                c2_require(type(amount) is int and amount >= prior, "E_LIMIT")
                work["seed_processing"][target] += amount - prior
                previous[source] = amount
            work["source_processing_unknown"] = "UNKNOWN: original D registry buffer/metadata processing is not completely measured"
        except BaseException:
            work["source_transfer_incomplete"] = True
            raise
    def materialize(self):
        self.namespace["directory"](self.namespace["target_root"], True)
        self.namespace["copy_inputs"](self.rows)
        self.namespace["final_checks"](self.rows)
        self.materialized = True
    def recheck(self):self.namespace["final_checks"](self.rows)
    def close(self, primary=None):
        c2_require(not self.closed, "E_STALE")
        self.closed = True
        first = self.namespace["first_error"]
        failure = first(self.failure, primary) if primary is not None else self.failure
        for row in reversed(self.namespace["owned"]):
            try:self.namespace["close_one"](row, failure)
            except BaseException as error:
                self.namespace["remember"]("close", error)
                failure = c2_first(failure, error)
        self.failure = failure
        self.work["data_and_close_complete"] = failure is None and not self.work.get("accounting_incomplete", False)
        if failure is not None:raise failure

class C2Helpers:
    def __init__(self, sources, scratch, work, unused):
        self.sources, self.scratch, self.work = sources, scratch, work
        self.unused = tuple(unused)
        self.results = []
        self.build_custody = None
    def close(self, primary=None):
        if self.build_custody is not None:self.build_custody.close(primary)
    def _tool(self, role, argv, *, stdin=b"", output_limit=1048576):
        c2_nonruntime_room(self.work, 0, False)
        result = c._c3_run_tool(self.scratch + "/runtime", self.work, role, argv, stdin=stdin,
            output_limit=output_limit, timeout=120, env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"})
        self.results.append(result)
        return result
    def _checked(self, role, argv, *, stdin=b"", output_limit=1048576, error="E_RUNTIME"):
        result = self._tool(role, argv, stdin=stdin, output_limit=output_limit)
        c2_require(result["status"] == 0 and not result["stderr"], error)
        return result["stdout"]
    def _original_filter(self, start, end):
        text = self.sources.helpers
        self.work["C3_source_recipe_processing_unknown"] = "UNKNOWN: fixed source recipe search processing is not fully observed"
        c2_require(text.count(start) == 1, "E_STALE")
        tail = text.split(start, 1)[1]
        c2_require(end in tail, "E_STALE")
        value = tail.split(end, 1)[0]
        raw = value.encode()
        c2_nonruntime_room(self.work, len(raw), False, read_only=True)
        self.work["read_bytes"] += len(raw)
        c._capture_account(self.work, "M", "read_bytes", len(raw))
        self.work["seed_processing"]["R"] += len(raw)
        return value
    def _literal(self, name):
        import re
        rows = re.findall("^" + re.escape(name) + "=([a-zA-Z0-9_.-]+)$", self.sources.helpers, re.M)
        c2_require(len(rows) == 1, "E_STALE")
        return rows[0]
    def _expand(self, value, local=None):
        import re
        values = dict(self.context)
        if local:values.update(local)
        def replace(match):
            name = match.group(1) or match.group(2)
            c2_require(name in values, "E_STALE")
            return values[name]
        result = re.sub(r"\$\{([a-zA-Z_][a-zA-Z0-9_]*)\}|\$([a-zA-Z_][a-zA-Z0-9_]*)", replace, value)
        c2_require("$" not in result and "`" not in result, "E_STALE")
        return result
    def _directory(self, path):
        root = self.build_custody
        path = str(Path(path))
        c2_require(path == self.scratch or path.startswith(self.scratch + "/"), "E_RELATION")
        if path in self.directories:return self.directories[path]
        parent = self._directory(str(Path(path).parent))
        held = root.mkdir(parent, Path(path).name)
        self.directories[path] = held
        return held
    def _source_rule(self):
        leaf = c._installed_rule(os.geteuid(), self.build_custody.resolver)
        def check(fd, state, ancestor):
            return True if ancestor else leaf(fd, state, False)
        check.observations = leaf.observations
        return check
    def _snapshot(self, source, destination, expected=None, maximum=1048576, mode=0o400):
        c2_require(destination.startswith(self.scratch + "/"), "E_RELATION")
        held = c._open_held(source, False, self._source_rule(),
            "E_STALE", recording_work=self.work, accounting_kind="M")
        try:
            c2_require(stat.S_ISREG(held.before.st_mode) and held.before.st_nlink == 1
                and held.before.st_size <= maximum, "E_LIMIT")
            raw = c2_driver_input_read(self.build_custody, held)
            measured = c2_driver_input_sha(self.build_custody, raw)
            c2_require(expected is None or measured == expected, "E_STALE")
            parent = self._directory(str(Path(destination).parent))
            if mode == 0o400:
                output = C2Copies(self.build_custody).copy(held, parent, Path(destination).name,
                    len(raw), measured, "M")
            else:
                installed_sha, output = c2_write_bytes(self.build_custody, parent, Path(destination).name, raw, mode=mode)
                c2_require(installed_sha == measured, "E_STALE")
            held.recheck("E_STALE", self.work, "M")
            self.build_seals.append((output, raw, measured))
            return measured
        finally:held.close()
    def _snapshots(self):
        import shlex
        body = self.sources.helpers.split("\nevals_build() {\n", 1)[1].split(
            '"'"'snapshot_expected "$jq_sha"'"'"', 1)[0].replace("\\\n", "")
        lines = body.splitlines()
        index = 0
        while index < len(lines):
            line = lines[index].strip();index += 1
            if line.startswith("for member in "):
                c2_require(line.endswith("; do"), "E_STALE")
                members = shlex.split(line[len("for member in "):-len("; do")])
                loop = []
                while index < len(lines) and lines[index].strip() != "done":
                    loop.append(lines[index].strip());index += 1
                c2_require(index < len(lines), "E_STALE");index += 1
                calls = [item for item in loop if item.startswith("snapshot_expected ")]
                c2_require(len(calls) == 1, "E_STALE")
                tokens = shlex.split(calls[0].split(" ||", 1)[0])
                for member in members:
                    fields = member.split()
                    c2_require(len(fields) == 2, "E_STALE")
                    values = [self._expand(item, {"name": fields[0], "digest": fields[1]}) for item in tokens[1:]]
                    c2_require(len(values) == 4 and values[3] == "0400", "E_STALE")
                    self._snapshot(values[1], values[2], values[0])
            elif line.startswith("/bin/mkdir -m 0700 "):
                tokens = shlex.split(line.split(" ||", 1)[0])
                for item in tokens[3:]:self._directory(self._expand(item))
            elif line.startswith("snapshot_file ") or line.startswith("snapshot_expected "):
                tokens = shlex.split(line.split(" ||", 1)[0]);values = [self._expand(item) for item in tokens[1:]]
                if tokens[0] == "snapshot_file":
                    c2_require(len(values) == 4 and values[2:] == ["1048576", "0400"], "E_STALE")
                    measured = self._snapshot(values[0], values[1])
                    if values[1].endswith("/bootstrap.sh"):self.context["bootstrap_sha"] = measured
                    elif values[1].endswith("/launcher.sh"):self.context["launcher_sha"] = measured
                else:
                    c2_require(len(values) == 4 and values[3] == "0400", "E_STALE")
                    self._snapshot(values[1], values[2], values[0])
    def build(self, arguments):
        mode, _root, paths = c2_cli(arguments)
        self.context = {"scratch": self.scratch, "runtime": self.scratch + "/runtime",
            "source_dir": str(Path(self.sources.launcher).parent), "self": self.sources.launcher,
            "repo": str(Path(self.sources.launcher).parents[2])}
        for name in ("generation", "program_sha", "driver_sha", "catalog_sha", "review_approval_sha"):
            self.context[name] = self._literal(name)
        self.context["generation_runtime"] = self.context["runtime"] + "/core/v2/generations/" + self.context["generation"]
        resolver = c._DarwinUUIDResolver() if sys.platform == "darwin" else None
        held = c._open_held(self.scratch, True, c._store_rule(os.geteuid(), os.getegid(), 0o700, True, resolver),
            "E_STALE", recording_work=self.work, accounting_kind="M")
        self.build_custody = C2Root(held, self.work, resolver)
        self.directories = {self.scratch: held}
        self.build_seals = []
        system = self._checked("evals-platform", ["/usr/bin/uname", "-s"]).strip().decode("ascii")
        machine = self._checked("evals-platform", ["/usr/bin/uname", "-m"]).strip().decode("ascii")
        platform = {("Linux", "x86_64"): ("linux", "x86_64", "native", "jq-linux64"),
            ("Darwin", "x86_64"): ("darwin", "x86_64", "native", "jq-osx-amd64"),
            ("Darwin", "arm64"): ("darwin", "arm64", "rosetta", "jq-osx-amd64")}.get((system, machine))
        c2_require(platform is not None, "E_RUNTIME")
        host_os, host_arch, execution_mode, asset = platform
        self.context.update(host_os=host_os, host_arch=host_arch, execution_mode=execution_mode,
            jq_arch="x86_64", jq_sha=c.JQ_SHA256[host_os])
        jq_source = None
        for candidate in (os.path.join(os.environ.get("TMPDIR", "/tmp"), "ystack-portable-core-jq16", asset), "/usr/bin/jq"):
            try:
                item = c._open_held(candidate, False, self._source_rule(), "E_RUNTIME",
                    recording_work=self.work, accounting_kind="M")
            except (OSError, c.Refusal):continue
            try:
                raw = item.read(c.EXECUTABLE_LIMIT, "E_RUNTIME", self.work)
                measured = c2_driver_input_sha(self.build_custody, raw)
                if measured == self.context["jq_sha"]:jq_source = candidate
            finally:item.close()
            if jq_source is not None:break
        c2_require(jq_source is not None, "E_RUNTIME")
        self._snapshots()
        self._snapshot(jq_source, self.context["runtime"] + "/bin/jq", self.context["jq_sha"], c.EXECUTABLE_LIMIT, 0o500)
        self.work["helper_internal_work_unknown"] = "UNKNOWN: original tool/compiler/Q work remains incomplete"
        return self._build_values(arguments, mode, paths)

    def _build_values(self, arguments, mode, paths):
        runtime = self.context["runtime"]
        jq = runtime + "/bin/jq"
        source = c._open_held("/bin/bash", False, self._source_rule(),
            "E_RUNTIME", recording_work=self.work, accounting_kind="M")
        try:
            raw = source.read(c.EXECUTABLE_LIMIT, "E_RUNTIME", self.work)
            self.context["bash_sha"] = c2_driver_input_sha(self.build_custody, raw)
        finally:source.close()
        quote = chr(39)
        registry_filter = self._original_filter('"'"'record_generation=$("$runtime/bin/jq" -er '"'"' + quote + "\n",
            "\n" + quote + '"'"' "$runtime/core/v2/generation-registry.json"'"'"')
        record_generation = self._checked("evals-build-values", [jq, "-er", registry_filter,
            runtime + "/core/v2/generation-registry.json"], error="E_STALE").rstrip(b"\n").decode("ascii")
        self.context["record_generation"] = record_generation
        self.context["record_schema"] = "core/v2/generations/" + record_generation + "/modules/schema.jq"
        record_files = self._expand(self._original_filter('"'"'record_files="'"'"', '"'"'"\n}'"'"'))
        for line in record_files.splitlines():
            path, expected = line.split()
            self._snapshot(self.context["repo"] + "/" + path, runtime + "/" + path, expected)
        c2_require(self.context["review_approval_sha"] == "none", "E_RELATION")
        runtime_held = self.directories[runtime]
        c2_write_bytes(self.build_custody, runtime_held, "review-files.tsv", b"")
        if mode == "run":
            self._snapshot(paths[0], self.scratch + "/input.json")
            self.input_document = self.scratch + "/input.json"
            self.driver_input = self.input_document
            seeds = [self.input_document]
        else:
            inputs = self._directory(self.scratch + "/inputs")
            manifest_entries, seeds = [], []
            for pair in range(2):
                seed = self.scratch + "/inputs/seed-" + str(pair) + ".json"
                result = self.scratch + "/inputs/result-" + str(pair) + ".json"
                seed_sha = self._snapshot(paths[2 * pair], seed)
                result_sha = self._snapshot(paths[2 * pair + 1], result)
                seeds.append(seed)
                manifest_entries.append({"result_sha256": result_sha, "seed_sha256": seed_sha})
            raw = C2Channel(9, self.work).encode(manifest_entries)
            manifest = self._checked("evals-build-values", [jq, "-S", "-c", "."], stdin=raw)
            c2_write_bytes(self.build_custody, inputs, "manifest.json", manifest)
            self.driver_input = self.scratch + "/inputs"
            self.input_document = self.driver_input + "/manifest.json"
        self.context["seed_sha"] = self._hash_path(self.input_document)
        for seed in seeds:
            result = self._tool("evals-build-values", [jq, "-r", ".body.seed_source // empty", seed])
            if result["status"] != 0:continue
            source = result["stdout"].rstrip(b"\n")
            c2_require(source != b"reviews.independent-verdicts.v1", "E_RELATION")
        record_filter = self._original_filter('"'"'record_closure=$("$runtime/bin/jq" -R -s -c '"'"' + quote + "\n",
            "\n" + quote + '"'"' <<< "$record_files")'"'"')
        record_closure = self._checked("evals-build-values", [jq, "-R", "-s", "-c", record_filter],
            stdin=(record_files + "\n").encode()).rstrip(b"\n").decode()
        closure_filter = self._original_filter('"'"'shadow_closure=$(shadow_source_rows | "$runtime/bin/jq" -R -s -c '"'"' + quote + "\n",
            "\n" + quote + '"'"')'"'"')
        table = self.sources.namespace["table"].encode()
        shadow_closure = self._checked("evals-build-values", [jq, "-R", "-s", "-c", closure_filter],
            stdin=table).rstrip(b"\n").decode()
        evaluator_filter = self._original_filter('"'"'--arg execution_mode "$execution_mode" '"'"' + quote + "\n",
            "\n" + quote + '"'"' > "$runtime/evaluator.json"'"'"')
        argv = [jq, "-S", "-c", "-n"]
        for name in ("bootstrap_sha", "launcher_sha", "driver_sha", "program_sha", "catalog_sha"):
            argv += ["--arg", name, self.context[name]]
        argv += ["--argjson", "record_closure", record_closure, "--argjson", "shadow_closure", shadow_closure]
        for name in ("jq_sha", "bash_sha", "host_os", "host_arch", "jq_arch", "execution_mode"):
            argv += ["--arg", name, self.context[name]]
        argv.append(evaluator_filter)
        evaluator_raw = self._checked("evals-build-values", argv)
        evaluator_sha, evaluator_held = c2_write_bytes(self.build_custody, runtime_held,
            "evaluator.json", evaluator_raw)
        self.build_seals.append((evaluator_held, evaluator_raw, evaluator_sha))
        self.context["evaluator_sha"] = evaluator_sha
        schema_filter = self._original_filter('"'"'"$runtime/bin/jq" -e --arg path "$record_schema" '"'"' + quote + "\n",
            "\n" + quote + '"'"' "$runtime/evaluator.json"'"'"')
        self._checked("evals-build-values", [jq, "-e", "--arg", "path", self.context["record_schema"],
            schema_filter, runtime + "/evaluator.json"], error="E_STALE")
        return {"status": 0, "stdout": b"", "stderr": b""}
    def _hash_path(self, path):
        held = c._open_held(path, False, self._source_rule(),
            "E_STALE", recording_work=self.work, accounting_kind="M")
        try:
            raw = held.read(c.EXECUTABLE_LIMIT, "E_STALE", self.work)
            return c2_driver_input_sha(self.build_custody, raw)
        finally:held.close()
    def run_and_check(self, arguments, driver_input):
        return self._run_fixed(arguments, driver_input)

    def _driver(self, argv, environment):
        c2_require(type(argv) is list and len(argv) == 9 and argv[:2] == ["/bin/bash", self.scratch + "/runtime/driver.sh"], "E_RELATION")
        descriptors, child, first = [], None, None
        pending, pending_pair = None, None
        chunks = {"stdout": [], "stderr": []}
        lengths = {"stdout": 0, "stderr": 0}
        try:
            pending = os.open("/dev/null", os.O_RDONLY)
            descriptors.append(pending);null = pending;pending = None
            pending_pair = os.pipe()
            for fd in pending_pair:descriptors.append(fd)
            output_r, output_w = pending_pair;pending_pair = None
            pending_pair = os.pipe()
            for fd in pending_pair:descriptors.append(fd)
            error_r, error_w = pending_pair;pending_pair = None
            actions = [(os.POSIX_SPAWN_DUP2, null, 0), (os.POSIX_SPAWN_DUP2, output_w, 1),
                (os.POSIX_SPAWN_DUP2, error_w, 2)]
            actions += [(os.POSIX_SPAWN_CLOSE, fd) for fd in sorted(set((9, 10, *descriptors, *self.unused, *(row["fd"] for row in self.sources.namespace["owned"] if not row["closed"]), *(component.fd for held in self.build_custody.owned for component in held.components)))) if fd not in {0, 1, 2}]
            child = os.posix_spawn("/bin/bash", argv, environment, file_actions=actions)
            c._capture_observe(self.work, "M", "C3.driver-spawn", {"pid": child, "actions": actions})
            for fd in (null, output_w, error_w):
                descriptors.remove(fd)
                c._close_capture_copy(fd, self.work, self.work, "C3.driver-parent-end", None)
            with selectors.DefaultSelector() as selected:
                selected.register(output_r, selectors.EVENT_READ, "stdout")
                selected.register(error_r, selectors.EVENT_READ, "stderr")
                while selected.get_map():
                    for key, _events in selected.select():
                        name = key.data
                        limit = _C2_LIMIT if name == "stdout" else 65536
                        amount = min(65536, limit + 1 - lengths[name])
                        c2_require(amount > 0, "E_LIMIT")
                        c2_wire_room(self.work, amount, "R")
                        raw = os.read(key.fd, amount)
                        self.work["read_bytes"] += len(raw)
                        c._capture_account(self.work, "M", "read_bytes", len(raw))
                        chunks[name].append(raw);lengths[name] += len(raw)
                        c2_require(lengths[name] <= limit, "E_LIMIT")
                        if not raw:selected.unregister(key.fd)
            waited, status = os.waitpid(child, 0)
            c._capture_observe(self.work, "M", "C3.driver-wait", {"pid": waited, "status": status})
            c2_require(waited == child, "E_RUNTIME")
            child = None
            result = {"status": status, "pid": waited}
            for name in ("stdout", "stderr"):
                result[name] = b"".join(chunks[name])
                self.work["read_bytes"] += lengths[name]
                c._capture_account(self.work, "M", "read_bytes", lengths[name])
            self.results.append(result)
            return result
        except BaseException as error:
            first = error
            self.work["C3_driver_incomplete"] = True
            self.work["C3_driver_partial"] = chunks
        finally:
            if child is not None:
                try:
                    os.kill(child, signal.SIGTERM)
                    waited, status = os.waitpid(child, 0)
                    c._capture_observe(self.work, "M", "C3.driver-failed-wait", {"pid": waited, "status": status})
                except BaseException as error:
                    first = c2_first(first, error)
                    self.work["C3_driver_wait_incomplete"] = True
            for fd in ((pending,) if pending is not None else ()) + (pending_pair or ()):
                if fd not in descriptors:
                    try:c._close_capture_copy(fd, self.work, self.work, "C3.driver-pending-close", first)
                    except BaseException as error:first = c2_first(first, error)
            for fd in reversed(descriptors):
                try:c._close_capture_copy(fd, self.work, self.work, "C3.driver-pipe-close", first)
                except BaseException as error:
                    first = c2_first(first, error)
            if first is not None:raise first

    def _prepare_budget(self, custody, destination, descriptor, start, start_raw,
                        ready_raw, go_raw, window_sha, root_identity, original_inputs):
        c2_require("budget" not in self.__dict__, "E_RELATION")
        mode = start["mode"]
        sequences, case_rows, inventories = [], [], {}
        seeds = original_inputs if mode == "run" else original_inputs[::2]
        for pair, seed_raw in enumerate(seeds):
            seed = c._c3_json_values(seed_raw, self.work)
            for case in seed["body"]["cases"]:
                identity = case["case_id"]
                c2_require(identity in c._C3_CASES and identity not in inventories, "E_RELATION")
                slot = c._C3_CASES.index(identity)
                manifest = case["manifest"]["content"]
                manifest_raw = c._c3_encode_values(manifest, self.work)
                core = manifest["inventory_core"]
                core_raw = c._c3_encode_values(core, self.work)
                manifest_sha = c2_driver_input_sha(custody, manifest_raw)
                core_sha = c2_driver_input_sha(custody, core_raw)
                c2_require(manifest_sha == case["manifest"]["sha256"]
                    and core == descriptor["cases"][identity]["inventory_core"]
                    and core_sha == descriptor["cases"][identity]["sha256"], "E_RELATION")
                sequences.append({"slot": slot, "case_id": identity, "pair": None if mode == "run" else pair})
                case_rows.append({"slot": slot, "case_id": identity, "manifest_size": len(manifest_raw),
                    "manifest_sha256": manifest_sha, "core_sha256": core_sha})
                inventories[identity] = core["entries"]
        c2_require([row["case_id"] for row in sequences] == [row["case_id"] for row in case_rows]
            and set(inventories) == set(start["case_ids"]), "E_RELATION")
        replay_root = custody.mkdir(destination, "replay-work")
        c2_require(not custody.namespace(replay_root), "E_RELATION")
        launcher_raw = self.sources.launcher_raw
        table = c._c3_source_closure_values(launcher_raw)
        c2_nonruntime_room(self.work, len(table), False, read_only=True)
        c._c3_processing(self.work, "R", len(table))
        for line in table.decode().splitlines():
            path, digest, length, mode_bits = line.split()
            c2_require(path in self.sources.rows and self.sources.rows[path]
                == (digest, int(length), int(mode_bits, 8) & 0o777), "E_STALE")
        bindings = {"seed_sha256s": list(start["seed_sha256s"]),
            "result_sha256s": list(start["result_sha256s"]),
            "evaluator_sha256": self.context["evaluator_sha"],
            "source_closure_sha256": c2_driver_input_sha(custody, table),
            "cases": case_rows, "work_identity": c._stat_values(replay_root.before)}
        c._c3_input_bindings_values(bindings, 0)
        current = c2_combine(self.work["C2_admitted_before"], c2_counters(self.work, ledger=True))
        cutoff = {"window": c2_named_values(current["window"]),
            "common": c2_cutoff_ledger(current["common"]),
            "cases": {identity: c2_cutoff_ledger(view) for identity, view in current["cases"].items()}}
        c._c3_ledger_complete(cutoff["common"])
        for ledger in cutoff["cases"].values():c._c3_ledger_complete(ledger)
        source_bytes = sum(row[1] for row in self.sources.rows.values())
        source_files = len(self.sources.rows)
        scopes = ["common", *[row["case_id"] for row in sequences]]
        zero = lambda: c._c3_vector_values((0,) * 55)
        grants = []
        common_bootstrap = c2_replay_demand([], source_bytes, source_files,
            sum(len(raw) for raw in original_inputs), "bootstrap")
        common_body = c2_replay_demand([], source_bytes, source_files,
            sum(row["manifest_size"] for row in case_rows), "body")
        common_terminal = c2_replay_demand([], 0, len(sequences),
            sum(row["manifest_size"] for row in case_rows), "terminal")
        driver = {"actor": 0, "scopes": scopes,
            "bootstrap": {scope: zero() for scope in scopes},
            "body": {scope: zero() for scope in scopes},
            "terminal": {scope: zero() for scope in scopes}}
        driver["bootstrap"]["common"] = common_bootstrap
        driver["body"]["common"] = common_body
        driver["terminal"]["common"] = common_terminal
        grants.append(driver)
        for row in case_rows:
            identity = row["case_id"]
            entries = inventories[identity]
            driver["body"][identity] = c2_replay_demand([], 0, len(entries), row["manifest_size"], "body")
            grants.append({"actor": row["slot"] + 1, "scopes": [identity],
                "bootstrap": {identity: c2_replay_demand([], source_bytes, source_files,
                    row["manifest_size"], "bootstrap")},
                "body": {identity: c2_replay_demand(entries, 0, source_files,
                    row["manifest_size"], "body")},
                "terminal": {identity: c2_replay_demand([], 0, len(entries),
                    row["manifest_size"], "terminal")}})
        reserved = {scope: c2_named_values(self.work["C2_tail_reservation"]["common"]
            if scope == "common" else self.work["C2_tail_reservation"]["cases"][scope]) for scope in scopes}
        # The finite bound includes the exact source-shaped cutoff and every fixed numeric/key slot.
        cutoff_bytes = c._c3_encode_values(cutoff, self.work)
        carrier_bound = len(cutoff_bytes) + len(table) + 4096 + 16384 * len(grants)
        parent_need = c2_replay_demand([], 0, source_files + len(case_rows), carrier_bound, "body")
        reserved["common"] = c._c3_values_sum([reserved["common"], parent_need])
        budget = {"version": 1, "window_sha256": window_sha, "ordinal": start["ordinal"], "mode": mode,
            "start_sha256": c2_sha(start_raw, self.work), "ready_sha256": c2_sha(ready_raw, self.work),
            "go_sha256": c2_sha(go_raw, self.work), "predecessor_sha256": start["predecessor_sha256"],
            "root_identity": root_identity, "input_bindings": bindings, "sequence": sequences,
            "cutoff": cutoff, "reserved_parent": reserved, "grants": grants}
        raw = c._c3_encode_values(budget, self.work)
        c2_require(len(raw) <= carrier_bound, "E_LIMIT")
        c._c3_budget_values(raw, 0, start["ordinal"], mode, window_sha, bindings, self.work)
        digest, held = c2_write_bytes(custody, destination, "replay-budget.json", raw)
        self.budget, self.budget_sha, self.budget_hold, self.budget_raw = budget, digest, held, raw
        return held, raw, digest

    def _program_check(self, operation, evaluator, evaluator_sha, seed_sha, seeds,
                       observations, candidate, results, result_shas, observed_at,
                       error="E_RUNTIME"):
        import shlex
        recipe = self._original_filter('"'"'program_check() {\n  [ "$('"'"',
            '"'"' 2>/dev/null)" = true ]\n}'"'"')
        positional = dict(zip(("$" + str(index) for index in range(1, 10)),
            (operation, evaluator, evaluator_sha, seed_sha, seeds, observations,
             candidate, results, result_shas)))
        argv = []
        for token in shlex.split(recipe.replace("\\\n", "")):
            argv.append(positional[token] if token in positional else
                self._expand(token, {"check_observed_at": observed_at}))
        c2_require(argv and argv[0] == self.context["runtime"] + "/bin/jq"
            and argv[-2:] == ["-f", self.context["runtime"] + "/program.jq"], "E_STALE")
        result = self._tool("evals-check-values", argv)
        c2_require(result["status"] == 0 and result["stdout"].rstrip(b"\n") == b"true", error)
        return result

    def _verify_nested_receipts(self, driver_end, driver_pid, replay_root):
        mode = self.budget["mode"]
        root = Path(replay_root)
        inputs = root.parent
        c2_require(root.name == "replay-work" and inputs.name == "driver-input"
            and inputs.parent.name == "I", "E_RELATION")
        def read(path, mode=0o400):
            held = self.build_custody.adopt(c._open_held(str(path), False,
                c._store_rule(os.geteuid(), os.getegid(), mode, False, self.build_custody.resolver),
                "E_RELATION", recording_work=self.work, accounting_kind="M"))
            raw = c2_driver_input_read(self.build_custody, held)
            held.recheck("E_RELATION", self.work, "M")
            return raw
        def same(left, right):
            size = len(left) + len(right)
            c2_nonruntime_room(self.work, size, False, read_only=True)
            c._c3_processing(self.work, "R", size)
            c._c3_processing(self.work, "E", size)
            c2_require(left == right, "E_RELATION")
        def parse(raw):
            c2_nonruntime_room(self.work, len(raw), False, read_only=True)
            c._c3_processing(self.work, "R", len(raw))
            return c._json(raw, _C2_LIMIT, "E_PARSE")
        pairs = [(None, inputs / "seed.json")] if mode == "run" else [
            (0, inputs / "seed-0.json"), (1, inputs / "seed-1.json")]
        sequence, cases, pair_data = [], [], {pair: [] for pair, _path in pairs}
        for pair, seed in pairs:
            seed_value = parse(read(seed))
            for item in seed_value["body"]["cases"]:
                case_id = item["case_id"]
                c2_require(case_id in c._C3_CASES, "E_RELATION")
                slot = c._C3_CASES.index(case_id)
                sequence.append({"slot": slot, "case_id": case_id, "pair": pair})
                cases.append(item)
        c2_require(sequence == self.budget["sequence"]
            and len({row["slot"] for row in sequence}) == len(sequence)
            and len(driver_end["children"]) == len(sequence), "E_RELATION")
        observations = driver_end["own"]["common"]["observations"]
        packets, used_spawns, used_waits = [], set(), set()
        for selected, case, child in zip(sequence, cases, driver_end["children"]):
            slot, case_id = selected["slot"], selected["case_id"]
            actor, pid, status = slot + 1, child["pid"], child["wait_status"]
            c2_require(child["actor"] == actor and type(pid) is int and pid > 0
                and type(status) is int and status == 0, "E_RELATION")
            document = root / ("malicious-case-%d.json" % slot)
            private = root / ("malicious-work-%d" % slot)
            argv = ["/usr/bin/python3", "-I", "-S", "-B",
                self.context["runtime"] + "/evals/v1/replay-malicious.py", self.context["runtime"],
                str(inputs.parent), str(document), str(private)]
            matching = [(index, row) for index, row in enumerate(observations)
                if row["site"] == "C3-driver.spawn" and row["value"]["argv"] == argv]
            c2_require(len(matching) == 1 and matching[0][0] not in used_spawns, "E_RELATION")
            spawn_index, spawn = matching[0]
            c2_require(spawn["owner"] == "C3-driver" and spawn["value"]["pid"] == pid, "E_RELATION")
            waits = [(index, row) for index, row in enumerate(observations)
                if index > spawn_index and row["site"] == "C3-driver.wait"
                and row["value"]["pid"] == pid]
            c2_require(waits and waits[0][0] not in used_waits, "E_RELATION")
            wait_index, waited = waits[0]
            c2_require(waited["owner"] == "C3-driver" and waited["value"]["status"] == status
                and not any(row["site"] == "C3-driver.spawn" and row["value"]["pid"] == pid
                    for row in observations[spawn_index + 1:wait_index]), "E_RELATION")
            used_spawns.add(spawn_index);used_waits.add(wait_index)
            case_raw = read(document, 0o600)
            generated = c._c3_encode_values(case, self.work)
            same(case_raw, generated)
            manifest_raw = c._c3_encode_values(case["manifest"]["content"], self.work)
            core_raw = c._c3_encode_values(case["manifest"]["content"]["inventory_core"], self.work)
            bindings = {"slot": slot, "case_id": case_id,
                "case_document_sha256": c2_driver_input_sha(self.build_custody, case_raw),
                "manifest_sha256": c2_driver_input_sha(self.build_custody, manifest_raw),
                "core_sha256": c2_driver_input_sha(self.build_custody, core_raw),
                "window_sha256": self.budget["window_sha256"]}
            c2_require(bindings["manifest_sha256"] == case["manifest"]["sha256"], "E_RELATION")
            budget_case = self.budget["input_bindings"]["cases"][len(packets)]
            c2_require(budget_case == {key: value for key, value in bindings.items()
                if key in {"slot", "case_id", "manifest_sha256", "core_sha256"}} | {
                    "manifest_size": len(manifest_raw)}, "E_RELATION")
            wire = read(root / ("malicious-%d.out" % slot), 0o600)
            stderr = read(root / ("malicious-%d.err" % slot), 0o600)
            data, end, done, settlement = c._c3_receive_values(wire, stderr, status, pid,
                driver_pid, self.budget, actor, bindings, self.work)
            received = self.work["C3_received"][-1]
            c2_require(received["actor"] == actor and received["pid"] == pid, "E_RELATION")
            c2_nonruntime_room(self.work, len(child["end_hex"]) // 2 + 512, False, read_only=True)
            recorded_end, recorded_done = bytes.fromhex(child["end_hex"]), bytes.fromhex(child["done_hex"])
            c._c3_processing(self.work, "C", len(recorded_end) + len(recorded_done))
            same(received["end_raw"], recorded_end);same(done, recorded_done)
            same(read(root / ("malicious-%d.canonical" % slot), 0o600), data)
            value = c._c3_json_values(data, self.work)
            c2_require(type(value) is dict and value["case_id"] == case_id, "E_RELATION")
            pair_data[selected["pair"]].append(value)
            packets.append({"actor": actor, "pid": pid, "settlement": settlement,
                "end_raw": received["end_raw"], "done_raw": done, "end": end})
        for pair, values in pair_data.items():
            path = root / "observations.json" if pair is None else root / ("pair-%d" % pair) / "observations.json"
            same(read(path, 0o600), c._c3_encode_values(values, self.work))
        c2_require(len(used_spawns) == len(used_waits) == len(sequence), "E_RELATION")
        return packets

    def _settle_actor_once(self, actor, pid, scopes, operation_key):
        c2_require(type(actor) is int and 0 <= actor <= 4 and type(pid) is int and pid > 0
            and type(scopes) is dict and operation_key == self.work["C3_operation_key"], "E_RELATION")
        grants = [row for row in self.budget["grants"] if row["actor"] == actor]
        c2_require(len(grants) == 1 and set(scopes) == set(grants[0]["scopes"]), "E_RELATION")
        registry = self.work.setdefault("C3_actor_imports", {})
        aggregates = self.work.setdefault("C3_case_work", {})
        for scope in grants[0]["scopes"]:
            ledger = c._c3_ledger_complete(scopes[scope])
            key = (operation_key, actor, pid, scope)
            c2_require(key not in registry, "E_RELATION")
            entry = {"state": "pending", "ledger": ledger, "seed_watermarks": {}, "call_watermarks": {}}
            registry[key] = entry
            if scope == "common":
                aggregate = self.work.setdefault("C3_common_work", c2_fresh_work("C3-import-common"))
            else:
                c2_require(scope in self.work["C2_case_totals"], "E_RELATION")
                if scope not in aggregates:aggregates[scope] = c2_fresh_work("C3-import-" + scope)
                aggregate = aggregates[scope]
            c2_require(type(aggregate) is dict and aggregate is not self.work, "E_RELATION")
            source = dict(ledger["values"])
            source.update(calls=ledger["calls"], accounting_rows=ledger["observations"])
            entry["source"] = source
            try:
                c._c3_values_room(c._c3_values_sum([c._c3_work_values(self.work), ledger["values"]]), window=True)
                c._c3_values_room(c._c3_values_sum([c._c3_work_values(aggregate), ledger["values"]]), window=False)
                if scope != "common":
                    c._c3_values_room(c._c3_values_sum([c._c3_work_values(self.work["C2_case_totals"][scope]),
                        ledger["values"]]), window=False)
                c._capture_transfer_work(source, self.work, aggregate)
                for group, watermark_name in (("seed_processing", "seed_watermarks"), ("calls", "call_watermarks")):
                    for name, amount in source[group].items():
                        c2_require(type(amount) is int and 0 <= amount < 1 << 64, "E_LIMIT")
                        marks = entry[watermark_name].setdefault(name, [0, 0])
                        for index, target in enumerate((self.work, aggregate)):
                            c2_require(0 <= marks[index] <= amount, "E_LIMIT")
                            previous = target[group].get(name, 0)
                            delta = amount - marks[index]
                            c2_require(type(previous) is int and previous + delta < 1 << 64, "E_LIMIT")
                            target[group][name] = previous + delta
                            marks[index] = amount
                if scope != "common":
                    target = self.work["C2_case_totals"][scope]
                    c2_require(target is not self.work and target is not aggregate, "E_RELATION")
                    marks = self.work.setdefault("C3_case_mirror_watermarks", {}).setdefault(scope, {})
                    values = c._c3_work_values(aggregate)
                    c._c3_values_room(c._c3_values_sum([c._c3_work_values(target),
                        c._c3_values_delta(values, marks["values"] if "values" in marks else
                            c._c3_work_values(c2_fresh_work("C3-new-mirror")))]), window=False)
                    scalar_marks = marks.setdefault("scalars", {})
                    for field in _C2_SCALARS:
                        previous, amount = scalar_marks.get(field, 0), aggregate[field]
                        c2_require(type(previous) is int and 0 <= previous <= amount, "E_LIMIT")
                        target[field] += amount - previous;scalar_marks[field] = amount
                    for group in ("runtime", "seed_processing", "calls"):
                        group_marks = marks.setdefault(group, {})
                        for field, amount in aggregate[group].items():
                            previous = group_marks.get(field, 0)
                            c2_require(type(previous) is int and 0 <= previous <= amount, "E_LIMIT")
                            if group == "runtime":c._runtime_account(target, field, amount - previous)
                            else:target[group][field] = target[group].get(field, 0) + amount - previous
                            group_marks[field] = amount
                    class_marks = marks.setdefault("accounting", {})
                    for kind, fields in aggregate["accounting"].items():
                        previous_fields = class_marks.setdefault(kind, {})
                        for field, amount in fields.items():
                            previous = previous_fields.get(field, 0)
                            c2_require(type(previous) is int and 0 <= previous <= amount, "E_LIMIT")
                            c._capture_account(target, kind, field, amount - previous)
                            previous_fields[field] = amount
                    marks["values"] = c._c3_values_sum([values])
                self.work.setdefault("C3_scope_ledgers", []).append({"operation": operation_key,
                    "actor": actor, "pid": pid, "scope": scope, "ledger": ledger})
                c2_nonruntime_room(self.work, 0, False)
                entry["state"] = "complete"
            except BaseException:
                entry["state"] = "unknown"
                self.work["C3_actor_import_incomplete"] = True
                aggregate["C3_actor_import_incomplete"] = True
                if scope != "common":self.work["C2_case_totals"][scope]["C3_actor_import_incomplete"] = True
                raise
        return registry

    def _run_fixed(self, arguments, driver_input):
        import re
        import shlex
        c2_require(not self.__dict__.get("run_fixed_started", False), "E_RELATION")
        self.run_fixed_started = True
        mode, _root, _paths = c2_cli(arguments)
        runtime = Path(self.context["runtime"])
        input_path = Path(driver_input)
        inputs = input_path.parent if mode == "run" else input_path
        replay_root = inputs / "replay-work"
        input_document = input_path if mode == "run" else input_path / "manifest.json"
        c2_require(inputs.name == "driver-input" and inputs.parent.name == "I"
            and inputs.parent.parent.parent.name == "operations"
            and inputs.parent.parent.name == str(self.budget["ordinal"])
            and self.budget["mode"] == mode, "E_RELATION")
        observed_at = arguments[2] if mode == "run" else arguments[1]
        def read(path, mode=0o400):
            held = self.build_custody.adopt(c._open_held(str(path), False,
                c._store_rule(os.geteuid(), os.getegid(), mode, False, self.build_custody.resolver),
                "E_RELATION", recording_work=self.work, accounting_kind="M"))
            raw = c2_driver_input_read(self.build_custody, held)
            held.recheck("E_RELATION", self.work, "M")
            return raw
        def same(left, right, token):
            size = len(left) + len(right)
            c2_nonruntime_room(self.work, size, False, read_only=True)
            c._c3_processing(self.work, "R", size);c._c3_processing(self.work, "E", size)
            c2_require(left == right, token)
        def write(path, raw):
            _sha, held = c2_write_bytes(self.build_custody, self._directory(str(path.parent)), path.name, raw)
            return held
        self.sources.recheck();self.sources.reconcile(self.work)
        fresh_input = read(input_document)
        same(fresh_input, read(Path(self.input_document)), "E_RELATION")
        seed_sha = c2_driver_input_sha(self.build_custody, fresh_input)
        c2_require(seed_sha == self.context["seed_sha"], "E_RELATION")
        evaluator_path = runtime / "evaluator.json"
        evaluator_sha = self._hash_path(str(evaluator_path))
        c2_require(evaluator_sha == self.context["evaluator_sha"], "E_STALE")
        budget_raw = read(inputs / "replay-budget.json")
        c2_require(c2_driver_input_sha(self.build_custody, budget_raw) == self.budget_sha, "E_RELATION")
        budget_value = c._c3_budget_values(budget_raw, 0, self.budget["ordinal"], mode,
            self.budget["window_sha256"], self.budget["input_bindings"], self.work)
        c2_require(budget_value == self.budget, "E_RELATION")
        window_raw = read(inputs / "window.json")
        c2_require(c2_driver_input_sha(self.build_custody, window_raw) == self.budget["window_sha256"], "E_RELATION")
        probe = c._open_held(str(replay_root), True,
            c._store_rule(os.geteuid(), os.getegid(), 0o700, True, self.build_custody.resolver),
            "E_RELATION", recording_work=self.work, accounting_kind="M")
        first = None
        try:
            c2_require(not probe.listdir()
                and c._stat_values(probe.before) == self.budget["input_bindings"]["work_identity"], "E_RELATION")
            probe.recheck("E_RELATION", self.work, "M")
        except BaseException as error:first = error
        finally:
            try:probe.close()
            except BaseException as error:
                self.work["C3_work_probe_close_incomplete"] = True
                first = c2_first(first, error)
        if first is not None:raise first
        self._directory(self.scratch + "/work")
        argv = ["/bin/bash", str(runtime / "driver.sh"), mode, str(runtime), str(input_path),
            str(evaluator_path), evaluator_sha, seed_sha, observed_at]
        self.sources.recheck();self.sources.reconcile(self.work)
        result = self._driver(argv, {"LC_ALL": "C", "PATH": "/usr/bin:/bin", "TMPDIR": self.scratch + "/work"})
        c2_require(type(result["status"]) is int and type(result["pid"]) is int and result["pid"] > 0, "E_RUNTIME")
        if result["status"] != 0:
            c2_require(not result["stdout"], "E_RUNTIME")
            token = result["stderr"].rstrip(b"\n")
            allowed = {b"E_RUNTIME", b"E_LIMIT", b"E_PARSE", b"E_CANONICAL", b"E_SHAPE", b"E_RELATION", b"E_STALE"}
            raise C2Refusal(token.decode("ascii") if token in allowed else "E_RUNTIME")
        c2_require(not result["stderr"], "E_RUNTIME")
        self.work["_c3_budget_sha"] = self.budget_sha
        self.work["C3_settlement_incomplete"] = True
        data, driver_end, driver_done, driver_settlement = c._c3_receive_values(
            result["stdout"], result["stderr"], result["status"], result["pid"], os.getpid(),
            self.budget, 0, self.budget["input_bindings"], self.work)
        driver_received = self.work["C3_received"][-1]
        self.work.setdefault("C3_pending_packets", []).append({"actor": 0, "pid": result["pid"],
            "end_raw": driver_received["end_raw"], "done_raw": driver_done, "settlement": driver_settlement})
        nested = self._verify_nested_receipts(driver_end, result["pid"], replay_root)
        self.work["C3_pending_packets"].extend(nested)
        operation_key = (self.budget["window_sha256"], self.budget["ordinal"], self.budget_sha, result["pid"])
        c2_require("C3_operation_key" not in self.work, "E_RELATION")
        self.work["C3_operation_key"] = operation_key
        first, output = None, Path(self.scratch) / "output.json"
        try:
            write(output, data)
            if mode == "run":
                self._program_check("validate-run-result", str(evaluator_path), evaluator_sha, seed_sha,
                    str(input_path), str(replay_root / "observations.json"), str(output),
                    str(replay_root / "observations.json"), "[]", observed_at)
            else:
                for pair in range(2):
                    seed, supplied = inputs / ("seed-%d.json" % pair), inputs / ("result-%d.json" % pair)
                    pair_time = self._checked("evals-check-values", [str(runtime / "bin/jq"), "-r",
                        ".body.observed_at", str(supplied)]).rstrip(b"\n").decode("ascii")
                    observations = replay_root / ("pair-%d" % pair) / "observations.json"
                    read(observations, 0o600)
                    self._program_check("validate-run-result", str(evaluator_path), evaluator_sha,
                        self._hash_path(str(seed)), str(seed), str(observations), str(supplied),
                        str(observations), "[]", pair_time, "E_RELATION")
                    same(read(replay_root / ("pair-%d" % pair) / "run-result.json", 0o600), read(supplied), "E_RELATION")
                result_shas = self._checked("evals-check-values", [str(runtime / "bin/jq"), "-c",
                    "map(.result_sha256)", str(inputs / "manifest.json")]).rstrip(b"\n").decode("ascii")
                self._program_check("validate-dashboard", str(evaluator_path), evaluator_sha, seed_sha,
                    str(replay_root / "seeds.jsonl"), str(replay_root / "pair-0/observations.json"), str(output),
                    str(replay_root / "results.jsonl"), result_shas, observed_at)
            canonical = self._checked("evals-check-values", [str(runtime / "bin/jq"), "-S", "-c", ".", str(output)], error="E_CANONICAL")
            write(Path(self.scratch) / "output.canonical", canonical)
            same(data, canonical, "E_CANONICAL")
            pin_source = self._original_filter('"'"'/usr/bin/cmp -s "$output" "$scratch/output.canonical" || emit_error E_CANONICAL\n'"'"',
                '"'"'\nwhile read -r path digest; do\n'"'"').replace("\\\n", "")
            pattern = r'"'"'\[\s*"\$\(sha256_path\s+("[^"\n]+"|/bin/bash)\)"\s*=\s*("[^"\n]+"|[0-9a-f]{64})\s*\]'"'"'
            pins = re.findall(pattern, pin_source)
            c2_require(pins and len(pins) == pin_source.count("sha256_path"), "E_STALE")
            local = {"input_document": str(input_document), "seed_sha": seed_sha, "evaluator_sha": evaluator_sha}
            for path, expected in pins:
                path = self._expand(shlex.split(path)[0], local)
                expected = self._expand(shlex.split(expected)[0], local)
                try:c2_require(self._hash_path(path) == expected, "E_RUNTIME")
                except BaseException as error:
                    if c2_cancelled(error) or getattr(error, "code", None) == "E_LIMIT":raise
                    raise C2Refusal("E_RUNTIME") from error
            record_files = self._expand(self._original_filter('"'"'record_files="'"'"', '"'"'"\n}'"'"'))
            for line in record_files.splitlines():
                path, expected = line.split()
                c2_require(self._hash_path(str(runtime / path)) == expected, "E_STALE")
            review = read(runtime / "review-files.tsv")
            for line in review.decode().splitlines():
                expected, path = line.split("\t", 1)
                c2_require(self._hash_path(str(runtime / path)) == expected, "E_RELATION")
            if self.context["review_approval_sha"] != "none":
                c2_require(self._hash_path(str(runtime / "evals/v1/seeds/reviewer-severity/approval.json"))
                    == self.context["review_approval_sha"], "E_STALE")
            self.sources.recheck();self.sources.reconcile(self.work)
            same(read(input_document), fresh_input, "E_RELATION")
            same(read(inputs / "replay-budget.json"), budget_raw, "E_RELATION")
            same(read(inputs / "window.json"), window_raw, "E_RELATION")
            self.build_custody.recheck()
        except BaseException as error:
            first = error
        finally:
            for actor, pid, settlement in [(0, result["pid"], driver_settlement),
                    *[(packet["actor"], packet["pid"], packet["settlement"]) for packet in nested]]:
                try:self._settle_actor_once(actor, pid, settlement, operation_key)
                except BaseException as error:
                    first = c2_first(first, error)
                    self.work["C3_settlement_incomplete"] = True
                    break
            else:
                del self.work["C3_settlement_incomplete"]
        if first is not None:raise first
        self.work["C3_run_validated"] = True
        return {"status": result["status"], "pid": result["pid"], "stdout": data, "stderr": result["stderr"]}


class C2Root:
    def __init__(self, held, work, resolver):
        self.root, self.work, self.resolver = held, work, resolver
        self.owned, self.failure, self.closed = [], None, False
        self.created = []
        try:
            c2_require(type(held) is c.HeldPath and held.components)
            held.recording_work, held.accounting_kind = work, "M"
            held.recheck("E_STALE", work, "M")
            self.initial = c._identity(held.before)
            self.owned.append(held)
        except BaseException as error:
            self.fail(error)
            if not any(row is held for row in self.owned):
                try:held.close()
                except BaseException as closing:self.fail(closing)
            else:self.close(self.failure)
            raise self.failure
    def observe(self, site, value):
        c2_nonruntime_room(self.work, 0, False)
        c._capture_observe(self.work, "M", site, value)
    def fail(self, error):
        self.failure = c2_first(self.failure, error)
        self.work["C2_root_incomplete"] = True
        try:c._capture_observation_error(self.work, "M", "C2.root", error)
        except BaseException as observed:self.failure = c2_first(self.failure, observed)
    def adopt(self, held):
        try:self.owned.append(held)
        except BaseException as error:
            self.fail(error)
            if not any(row is held for row in self.owned):
                try:held.close()
                except BaseException as closing:self.fail(closing)
            raise self.failure
        return held
    def recheck(self):
        c2_nonruntime_room(self.work, 0, False)
        c2_require(not self.closed and self.failure is None, "E_STALE")
        for held in self.owned:
            if held.components:held.recheck("E_STALE", self.work, "M")
    def names(self, parent):
        names, size, iterator, failure = [], 0, None, None
        try:
            iterator = os.scandir(parent.fd)
            for entry in iterator:
                c2_require(len(names) < 1024, "E_LIMIT")
                encoded = os.fsencode(entry.name)
                size += len(encoded)
                c2_require(size <= 65536, "E_LIMIT")
                names.append(entry.name)
        except BaseException as error:failure = error
        finally:
            if iterator is not None:
                try:
                    self.work["close_calls"] += 1
                    iterator.close()
                    self.observe("C2.namespace-close", {"return": 0})
                except BaseException as error:failure = c2_first(failure, error)
            if failure is not None:
                self.fail(failure)
                raise self.failure
        self.observe("C2.namespace", {"fd": parent.fd, "names": [os.fsencode(name).hex() for name in names]})
        c2_require(len(names) == len(set(names)), "E_STALE")
        return frozenset(names)
    def namespace(self, parent):
        c2_nonruntime_room(self.work, 0, False)
        parent.recheck("E_STALE", self.work, "M")
        return self.names(parent)
    def created_parent(self, parent, before, names, name):
        current = c._capture_metadata(parent.fd, self.work, "M")
        old = c._identity(before)
        actual = c._identity(current)
        c2_require(actual[:6] == old[:6], "E_STALE")
        c2_require(c._capture_rule(parent.components[-1].rule, parent.fd, current, False, self.work, "M"), "E_STALE")
        after = self.names(parent)
        self.observe("C2.created-namespace", {"fd": parent.fd, "name": os.fsencode(name).hex()})
        c2_require(after == names | {name} and name not in names, "E_STALE")
        # Only this successful exclusive creation may update its exact parent component.
        for held in self.owned:
            for component in held.components:
                if c._identity(component.before) == old:
                    observed = c._capture_metadata(component.fd, self.work, "M")
                    c2_require(c._identity(observed) == actual, "E_STALE")
                    component.before = observed
        parent.recheck("E_STALE", self.work, "M")
    def mkdir(self, parent, name):
        c2_require(type(name) is str and name not in {"", ".", ".."} and "/" not in name)
        self.recheck();names = self.namespace(parent);before = parent.before
        try:
            c2_nonruntime_room(self.work, 0, False, files=1)
            os.mkdir(name, 0o700, dir_fd=parent.fd)
            self.created.append((parent.path, name))
            c._capture_account(self.work, "M", "files", 1)
            self.work["files"] += 1
            self.observe("C2.mkdir", {"fd": parent.fd, "name": name, "return": 0})
            self.created_parent(parent, before, names, name)
            return self.adopt(c._open_child(parent, name, True,
                c._store_rule(os.geteuid(), os.getegid(), 0o700, True, self.resolver), "E_STALE",
                recording_work=self.work, accounting_kind="M"))
        except BaseException as error:
            self.fail(error);raise self.failure
    def layout(self):
        c2_require(not self.namespace(self.root), "E_STALE")
        cases = self.mkdir(self.root, "cases")
        result = {}
        for identity in sorted(_C2_CASES):
            case = self.mkdir(cases, identity)
            result[identity] = self.mkdir(case, "S")
        operations = self.mkdir(self.root, "operations")
        self.recheck()
        self.destinations = result
        return result, operations
    def release_destination(self, held):
        c2_require(any(value is held for value in self.destinations.values()) and held.components, "E_STALE")
        c2_require(not self.namespace(held), "E_STALE")
        # The original assembly has cloned the empty S chain before its first write.
        try:held.close()
        except BaseException as error:
            self.fail(error);raise self.failure
        for index, value in enumerate(self.owned):
            if value is held:
                self.owned.pop(index)
                break
    def bind_descriptor(self, descriptor_fd, start_identity):
        self.recheck()
        observed = c._capture_metadata(descriptor_fd, self.work, "M")
        c2_require(c._identity(observed) == c._identity(self.root.before), "E_STALE")
        c2_require(type(start_identity) is list and tuple(start_identity) == self.initial, "E_STALE")
    def close(self, primary=None):
        c2_require(not self.closed, "E_STALE")
        self.closed = True
        if primary is not None:self.fail(primary)
        while self.owned:
            held = self.owned.pop()
            try:
                if held.components:held.close()
            except BaseException as error:self.fail(error)
        if self.failure is not None:raise self.failure
        c2_require(not c._capture_work_incomplete(self.work), "E_LIMIT")

def c2_clone_root(held, work, resolver):
    rows = c._clone(held, "E_STALE", work, "M")
    cloned = None
    try:
        cloned = c.HeldPath(held.path, rows, recording_work=work, accounting_kind="M")
        return C2Root(cloned, work, resolver)
    except BaseException as error:
        first = error
        if cloned is not None:
            if cloned.components:
                try:cloned.close()
                except BaseException as closing:first = c2_first(first, closing)
        else:
            for row in reversed(rows):
                try:c._close_capture_copy(row.fd, work, work, "C2.clone-root-pending", first)
                except BaseException as closing:first = c2_first(first, closing)
        raise first

class C2Copies:
    def __init__(self, custody, work=None, total=None, window_before=None, case_before=None):
        self.custody, self.work = custody, custody.work if work is None else work
        self.total, self.window_before, self.case_before = total, window_before, case_before
        self.pairs, self.case_copies = [], []
    def runtime(self, field, amount, commit=True):
        if self.total is not None:
            self.work["runtime_case_carry_in"] = {key: self.case_before["runtime"][key] + self.total["runtime"][key] for key in c._RUNTIME_FIELDS}
            self.work["runtime_window_carry_in"] = {key: self.window_before["runtime"][key] + self.custody.work["runtime"][key] for key in c._RUNTIME_FIELDS}
        c._runtime_account(self.work, field, amount, commit=commit)
    def transfer_cases(self):
        for copies in self.case_copies:copies.transfer_cases()
        if self.total is not None:
            c2_require(not getattr(self, "transfer_failed", False), "E_LIMIT")
            try:
                common_before_transfer = c2_counters(self.custody.work)["common"]
                c._capture_transfer_work(self.work, self.custody.work, self.total)
                previous = self.work.setdefault("transferred_seed_processing", {})
                for field, amount in self.work["seed_processing"].items():
                    prior = previous.get(field, 0)
                    c2_require(type(amount) is int and 0 <= prior <= amount, "E_LIMIT")
                    for target in (self.custody.work, self.total):
                        target["seed_processing"][field] += amount - prior
                    previous[field] = amount
                c2_nonruntime_room(self.custody.work, 0, False)
            except BaseException:
                self.transfer_failed = True
                if "common_before_transfer" in locals():self.custody.work["C2_common_cutoff"] = common_before_transfer
                self.custody.work["C2_common_transfer_unknown"] = True
                self.custody.work["C2_case_transfer_incomplete"] = True
                raise
    def room(self, field, amount, kind):
        if kind == "runtime":
            mapping = {"R": "read_bytes", "W": "write_bytes", "H": "sha_bytes", "E": "equality_bytes", "C": "copy_bytes"}
            self.runtime(mapping[field], amount, False)
            if field == "W":self.runtime("physical_bytes", amount, False)
        elif field in {"R", "W"}:
            c2_nonruntime_room(self.work, amount, kind == "export", read_only=field == "R", writing=field == "W",
                case_before=self.case_before, total=self.total, window_work=self.custody.work, window_before=self.window_before)
    def charge(self, field, amount, kind):
        self.work["seed_processing"][field] += amount
        if kind == "runtime":
            mapping = {"R": "read_bytes", "W": "write_bytes", "H": "sha_bytes", "E": "equality_bytes", "C": "copy_bytes"}
            self.runtime(mapping[field], amount)
            if field == "W":self.runtime("physical_bytes", amount)
        elif field in {"R", "W"}:
            key = "read_bytes" if field == "R" else "write_bytes"
            self.work[key] += amount
            if kind == "export":
                self.work["export_" + key] += amount
                if field == "W":self.work["export_physical_bytes"] += amount
            else:c._capture_account(self.work, "raw" if kind == "recorded" else kind, key, amount)
            if field == "W":
                self.work["physical_bytes"] += amount
                if kind != "export":c._capture_account(self.work, "raw" if kind == "recorded" else kind, "physical_bytes", amount)
    def copy(self, source, parent, name, size, expected, kind):
        c2_nonruntime_room(self.work, 0, False, case_before=self.case_before, total=self.total,
            window_work=self.custody.work, window_before=self.window_before)
        c2_require(kind in {"runtime", "recorded", "export", "raw", "M", "W"})
        c2_require(type(source) is c.HeldPath and source.components and type(size) is int and 0 <= size <= 4 << 30)
        source.recheck("E_STALE", self.work, "M")
        c2_require(source.before.st_size == size, "E_STALE")
        names = self.custody.namespace(parent);before = parent.before
        writer, first = None, None
        installed_hash = hashlib.sha256()
        try:
            if kind == "runtime":self.runtime("physical_files", 1, False)
            else:c2_nonruntime_room(self.work, 0, kind == "export", files=1,
                case_before=self.case_before, total=self.total, window_work=self.custody.work, window_before=self.window_before)
            writer = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400, dir_fd=parent.fd)
            if kind == "runtime":self.runtime("physical_files", 1)
            else:
                self.work["files"] += 1
                if kind == "export":self.work["export_files"] += 1
                else:c._capture_account(self.work, "raw" if kind == "recorded" else kind, "files", 1)
            self.custody.observe("C2.copy-create", {"fd": writer, "parent_fd": parent.fd, "name": name})
            self.custody.created_parent(parent, before, names, name)
            c2_nonruntime_room(self.work, 0, False, case_before=self.case_before, total=self.total,
                window_work=self.custody.work, window_before=self.window_before)
            offset = 0
            while offset < size:
                amount = min(65536, size - offset)
                self.room("R", amount, kind)
                raw = os.pread(source.fd, amount, offset)
                self.charge("R", len(raw), kind)
                c2_require(len(raw) == amount, "E_STALE")
                written = 0
                while written < len(raw):
                    self.room("W", len(raw) - written, kind)
                    self.room("C", len(raw) - written, kind)
                    sent = os.write(writer, memoryview(raw)[written:])
                    c2_require(type(sent) is int and 0 < sent <= len(raw) - written, "E_RUNTIME")
                    self.charge("W", sent, kind);self.charge("C", sent, kind)
                    written += sent
                offset += len(raw)
            os.fsync(writer)
            self.custody.observe("C2.copy-fsync", {"fd": writer, "return": 0})
            closing, writer = writer, None
            c._close_capture_copy(closing, self.work, self.work, "C2.copy-writer", None)
            installed = self.custody.adopt(c._open_child(parent, name, False,
                c._store_rule(os.geteuid(), os.getegid(), 0o400, False, self.custody.resolver), "E_STALE",
                recording_work=self.work, accounting_kind="M"))
            c2_require(installed.before.st_size == size, "E_STALE")
            offset = 0
            while offset < size:
                amount = min(65536, size - offset)
                self.room("R", amount, kind);self.room("H", amount, kind)
                raw = os.pread(installed.fd, amount, offset)
                self.charge("R", len(raw), kind)
                installed_hash.update(raw);self.charge("H", len(raw), kind)
                c2_require(len(raw) == amount, "E_STALE")
                offset += amount
            c2_require(installed_hash.hexdigest() == expected, "E_STALE")
            offset = 0
            while offset < size:
                amount = min(65536, size - offset)
                self.room("R", 2 * amount, kind)
                left = os.pread(source.fd, amount, offset)
                self.charge("R", len(left), kind)
                right = os.pread(installed.fd, amount, offset)
                self.charge("R", len(right), kind)
                self.room("E", len(left) + len(right), kind)
                equal = left == right
                self.charge("E", len(left) + len(right), kind)
                c2_require(len(left) == len(right) == amount and equal, "E_STALE")
                offset += amount
            source.recheck("E_STALE", self.work, "M");installed.recheck("E_STALE", self.work, "M")
            self.pairs.append((source, installed, size, expected, kind))
            return installed
        except BaseException as error:
            first = error
            self.custody.fail(error)
        finally:
            if writer is not None:
                closing, writer = writer, None
                try:c._close_capture_copy(closing, self.work, self.work, "C2.copy-failed-writer", first)
                except BaseException as error:self.custody.fail(error)
            if first is not None:raise self.custody.failure
    def final_checks(self):
        for copies in self.case_copies:copies.final_checks()
        self.custody.recheck()
        for source, installed, size, expected, kind in self.pairs:
            source.recheck("E_STALE", self.work, "M");installed.recheck("E_STALE", self.work, "M")
            c2_require(source.before.st_size == installed.before.st_size == size, "E_STALE")
            left_hash, right_hash, offset = hashlib.sha256(), hashlib.sha256(), 0
            while offset < size:
                amount = min(65536, size - offset)
                self.room("R", 2 * amount, kind)
                left = os.pread(source.fd, amount, offset)
                self.charge("R", len(left), kind)
                right = os.pread(installed.fd, amount, offset)
                self.charge("R", len(right), kind)
                self.room("H", len(left) + len(right), kind);self.room("E", len(left) + len(right), kind)
                left_hash.update(left);self.charge("H", len(left), kind)
                right_hash.update(right);self.charge("H", len(right), kind)
                equal = left == right
                self.charge("E", len(left) + len(right), kind)
                c2_require(len(left) == len(right) == amount and equal, "E_STALE")
                offset += amount
            c2_require(left_hash.hexdigest() == right_hash.hexdigest() == expected, "E_STALE")
            source.recheck("E_STALE", self.work, "M");installed.recheck("E_STALE", self.work, "M")

def c2_terminal(work, ordinal, end_size, end_written, values):
    owner = c
    c2_require(type(values) is tuple and len(values) == 50
        and all(type(value) is int and 0 <= value < 1 << 64 for value in values), "E_LIMIT")
    c2_require(not owner._capture_work_incomplete(work)
        and all(value == 0 for value in values[11:20]) and all(value == 0 for value in values[-6:]))
    done = struct.pack(">8s53Q80x", b"YC2DONE1", ordinal, end_size, end_written, *values)
    owner._capture_account(work, "M", "logical_bytes", 512)
    owner._capture_account(work, "M", "occurrences", 1)
    c2_wire_room(work, 512, "W")
    try:result = os.write(9, done)
    except BaseException:os._exit(1)
    if result > 0:
        work["write_bytes"] += result
        owner._capture_account(work, "M", "write_bytes", result)
        processing = work.setdefault("seed_processing", {})
        processing["W"] = processing.get("W", 0) + result
        processing["C"] = processing.get("C", 0) + result
    if result != 512:os._exit(1)
    failure = None
    for fd, site in ((1, "C2.stdout"), (2, "C2.stderr"), (9, "C2.control")):
        try:owner._close_capture_copy(fd, work, work, site, None)
        except BaseException as error:failure = c2_first(failure, error)
    os._exit(1 if failure is not None or owner._capture_work_incomplete(work) else 0)

def c2_vector(work):
    result = tuple(work[key] for key in _C2_SCALARS)
    result += tuple(work["runtime"][key] for key in c._RUNTIME_FIELDS)
    result += tuple(work["accounting"][kind][key] for kind in _C2_CLASSES for key in _C2_ACCOUNT_FIELDS)
    c2_require(len(result) == 50 and all(type(value) is int and 0 <= value < 1 << 64 for value in result), "E_LIMIT")
    return result

def c2_sum_views(values):
    c2_require(values and all(type(value) is dict for value in values), "E_LIMIT")
    def add(items):
        return sum(items) if all(type(item) is int and 0 <= item < 1 << 64 for item in items) else "UNKNOWN"
    result = {key: add([value[key] for value in values]) for key in _C2_SCALARS}
    result["runtime"] = {key: add([value["runtime"][key] for value in values]) for key in c._RUNTIME_FIELDS}
    result["accounting"] = {kind: {key: add([value["accounting"][kind][key] for value in values])
        for key in _C2_ACCOUNT_FIELDS} for kind in _C2_CLASSES}
    result["seed_processing"] = {key: add([value["seed_processing"][key] for value in values]) for key in ("R", "W", "H", "E", "C")}
    result["incomplete"] = [item for value in values for item in value["incomplete"]]
    result["unknown"] = {str(index): value["unknown"] for index, value in enumerate(values) if value["unknown"]}
    if any("ledgers" in value for value in values):
        c2_require(all("ledgers" in value for value in values), "E_RELATION")
        result["ledgers"] = [ledger for value in values for ledger in value["ledgers"]]
        for ledger in result["ledgers"]:c._c3_ledger_check(ledger)
    return result

def c2_case_values(rows):
    distinct = []
    for row in rows:
        c2_require(type(row) is dict, "E_LIMIT")
        if not any(row is original for original in distinct):distinct.append(row)
    values = []
    for row in distinct:
        # These are real initialized recording owners. Use the original counter defaults only.
        c2_require(all(key in row for key in ("read_bytes", "write_bytes", "physical_bytes", "files", "export_read_bytes", "export_write_bytes", "export_physical_bytes", "export_files")), "E_LIMIT")
        view = c2_counter_values(row)
        for key in _C2_SCALARS:
            if key not in row:view[key] = 0
        view["runtime"] = {key: row.get("runtime", {}).get(key, 0) for key in c._RUNTIME_FIELDS}
        view["accounting"] = {kind: {key: row.get("accounting", {}).get(kind, {}).get(key, 0) for key in _C2_ACCOUNT_FIELDS} for kind in _C2_CLASSES}
        view["seed_processing"] = {key: row.get("seed_processing", {}).get(key, 0) for key in ("R", "W", "H", "E", "C")}
        values.append(view)
    return c2_sum_views(values)

def c2_counters(work, *, ledger=False, codec_work=None):
    cases = {}
    bindings = work.get("C2_case_bindings", {})
    for identity, binding in bindings.items():
        c2_require(identity in _C2_CASES and type(binding) is tuple and len(binding) == 2, "E_RELATION")
        primary, rows = binding
        c2_require(type(rows) is list and any(primary is row for row in rows)
            and all(any(row is owner for owner in work.get("cases", {}).values()) for row in rows), "E_RELATION")
        cases[identity] = c2_case_values(rows)
    for identity, leaf in work.get("C2_case_totals", {}).items():
        c2_require(identity in _C2_CASES and identity not in cases, "E_RELATION")
        cases[identity] = c2_counter_values(work.get("C2_case_leaves", {}).get(identity, leaf))
    for identity, leaf in work.get("C3_case_work", {}).items():
        c2_require(identity in cases and (identity in work.get("C2_case_leaves", {})
            or identity in work.get("C2_case_bindings", {})), "E_RELATION")
        cases[identity] = c2_sum_views([cases[identity], c2_counter_values(leaf)])
    window = c2_counter_values(work)
    if "C2_common_case" in work:
        common = c2_counter_values(work["C2_common_case"])
    elif work.get("C2_case_bindings"):
        common = c2_counter_values({"C2_common_missing_unknown": True, "C2_common_missing_incomplete": True})
    elif work.get("C2_common_transfer_unknown"):
        common = dict(work["C2_common_cutoff"])
        common["unknown"] = dict(common["unknown"], C2_common_transfer_unknown=True)
        common["incomplete"] = list(common["incomplete"]) + ["C2_case_transfer_incomplete"]
    else:
        # Only these disjoint new leaves were actually transferred into this work owner.
        transferred = [c2_counter_values(total) for total in work.get("C2_case_totals", {}).values()]
        common = c2_view_delta(window, c2_sum_views(transferred)) if transferred else window
    if ledger:
        def record(owners, view):
            distinct = []
            for owner in owners:
                c2_require(type(owner) is dict, "E_RELATION")
                if not any(owner is previous for previous in distinct):distinct.append(owner)
            snapshots = [c._c3_scope_ledger_values(owner, work if codec_work is None else codec_work) for owner in distinct]
            return dict(view, ledgers=snapshots)
        for identity in cases:
            if identity in bindings:owners = list(bindings[identity][1])
            else:owners = [work.get("C2_case_leaves", {}).get(identity, work["C2_case_totals"][identity])]
            if identity in work.get("C3_case_work", {}):owners.append(work["C3_case_work"][identity])
            cases[identity] = record(owners, cases[identity])
        if "C2_common_case" in work:
            common = record([work["C2_common_case"]], common)
        else:
            projected = dict(work)
            projected.update({key: common[key] for key in _C2_SCALARS})
            for group in ("runtime", "accounting", "seed_processing"):projected[group] = common[group]
            injected = [row for owner in work.get("C2_case_totals", {}).values()
                for row in owner.get("accounting_rows", [])]
            projected["accounting_rows"] = [row for row in work.get("accounting_rows", [])
                if not any(row is transferred for transferred in injected)]
            projected["cases"] = {}
            common = record([projected], common)
    return {"window": window, "cases": cases, "common": common}

def c2_view_delta(current, prior):
    result = {key: current[key] - prior[key] for key in _C2_SCALARS}
    result["runtime"] = {key: current["runtime"][key] - prior["runtime"][key] for key in c._RUNTIME_FIELDS}
    result["accounting"] = {kind: {key: current["accounting"][kind][key] - prior["accounting"][kind][key]
        for key in _C2_ACCOUNT_FIELDS} for kind in _C2_CLASSES}
    result["seed_processing"] = {key: current["seed_processing"][key] - prior["seed_processing"][key] for key in ("R", "W", "H", "E", "C")}
    result["incomplete"], result["unknown"] = current["incomplete"], current["unknown"]
    if "ledgers" in current or "ledgers" in prior:
        c2_require("ledgers" in current and "ledgers" in prior
            and len(current["ledgers"]) >= len(prior["ledgers"]), "E_RELATION")
        result["ledgers"] = [c._c3_ledger_delta(row, prior["ledgers"][index])
            if index < len(prior["ledgers"]) else c._c3_ledger_check(row)
            for index, row in enumerate(current["ledgers"])]
    return result

def c2_delta(current, prior):
    c2_require(set(current) == set(prior) == {"window", "cases", "common"} and set(current["cases"]) == set(prior["cases"]), "E_RELATION")
    return {"window": c2_view_delta(current["window"], prior["window"]),
        "common": c2_view_delta(current["common"], prior["common"]),
        "cases": {identity: c2_view_delta(current["cases"][identity], prior["cases"][identity]) for identity in current["cases"]}}

def c2_combine(before, *deltas):
    inputs = (before, *deltas)
    c2_require(all(set(value) == {"window", "cases", "common"} and type(value["cases"]) is dict
        and set(value["cases"]) <= set(before["cases"]) <= _C2_CASES for value in inputs), "E_RELATION")
    return {"window": c2_sum_views([value["window"] for value in inputs]),
        "common": c2_sum_views([value["common"] for value in inputs]),
        "cases": {identity: c2_sum_views([value["cases"][identity] for value in inputs if identity in value["cases"]]) for identity in before["cases"]}}


def c2_named_values(view):
    return c._c3_vector_values(c._c3_values_vector({key: view[key] for key in c._C3_SCALARS}
        | {group: view[group] for group in ("runtime", "accounting", "seed_processing")}))

def c2_cutoff_ledger(view):
    c2_require("ledgers" in view and type(view["ledgers"]) is list and view["ledgers"], "E_LIMIT")
    ledgers = [c._c3_ledger_check(row) for row in view["ledgers"]]
    work = c2_named_values(view)
    calls = {}
    for ledger in ledgers:
        for name, amount in ledger["calls"].items():calls[name] = calls.get(name, 0) + amount
    work.update(calls=calls, accounting_rows=[row for ledger in ledgers for row in ledger["observations"]])
    receipts = {}
    for slot in c._C3_RECEIPT_SLOTS:
        originals = [ledger["owner_receipts"][slot] for ledger in ledgers]
        if len(originals) == 1:receipts[slot] = originals[0]
        elif all(value == {"state": "not-applicable"} for value in originals):
            receipts[slot] = {"state": "not-applicable"}
        else:receipts[slot] = {"state": "unknown"}
    unknown = [value for ledger in ledgers for value in ledger["unknown"]]
    unknown.extend("C2-multiple-original-" + slot + "-receipts" for slot in c._C3_RECEIPT_SLOTS
        if len(ledgers) > 1 and receipts[slot] == {"state": "unknown"})
    return c._c3_ledger_values(work, receipts,
        [row for ledger in ledgers for row in ledger["retained"]],
        [row for ledger in ledgers for row in ledger["errors"]], unknown)

def c2_replay_demand(entries, source_bytes, source_files, document_bytes, phase):
    c2_require(type(entries) is list and len(entries) <= 256
        and all(type(value) is int and value >= 0 for value in (source_bytes, source_files, document_bytes))
        and phase in {"bootstrap", "body", "terminal"}, "E_LIMIT")
    result = c._c3_vector_values((0,) * 55)
    def add(kind, size, count, passes, *, logical=0):
        c2_require(kind in {"L", "W", "M", "raw", "export", "runtime"}
            and type(size) is int and size >= 0 and type(count) is int and count >= 0, "E_LIMIT")
        for field, multiplier in zip(("R", "W", "H", "E", "C"), passes):
            amount = multiplier * size
            result["seed_processing"][field] += amount
            if kind == "runtime":
                target = {"R": "read_bytes", "W": "write_bytes", "H": "sha_bytes", "E": "equality_bytes", "C": "copy_bytes"}[field]
                result["runtime"][target] += amount
            elif field in {"R", "W"}:
                target = "read_bytes" if field == "R" else "write_bytes"
                result[target] += amount
                if kind == "export":result["export_" + target] += amount
                else:result["accounting"][kind][target] += amount
        physical = passes[1] * size
        if kind == "runtime":
            result["runtime"]["physical_bytes"] += physical
            result["runtime"]["physical_files"] += count if passes[1] else 0
            result["runtime"]["logical_bytes"] += logical
            result["runtime"]["files"] += count if logical else 0
        else:
            result["physical_bytes"] += physical;result["files"] += count if passes[1] else 0
            if kind == "export":
                result["export_physical_bytes"] += physical;result["export_files"] += count if passes[1] else 0
            else:
                result["accounting"][kind]["physical_bytes"] += physical
                result["accounting"][kind]["files"] += count if passes[1] else 0
                result["accounting"][kind]["logical_bytes"] += logical
                result["accounting"][kind]["occurrences"] += count
    if phase == "bootstrap":
        add("L", source_bytes, source_files, (4, 0, 2, 2, 0), logical=source_bytes)
        add("M", document_bytes, 1, (8, 0, 3, 2, 1), logical=document_bytes)
    elif phase == "body":
        for entry in entries:
            c2_require(type(entry) is dict and entry["kind"] in {"runtime", "recorded", "export", "raw", "M", "W"}
                and type(entry["size_bytes"]) is int and 0 <= entry["size_bytes"] <= 4 << 30, "E_RELATION")
            add("raw" if entry["kind"] == "recorded" else entry["kind"], entry["size_bytes"], 1,
                (8, 1, 5, 4, 1), logical=entry["size_bytes"])
        add("L", source_bytes, source_files, (2, 0, 2, 2, 0))
        add("M", document_bytes, 4, (8, 2, 4, 4, 2), logical=2 * document_bytes)
    else:
        # Fixed framing and the two original pipe-close rows use the same codec as actual emission.
        close, _rows = c._c3_close_tail_values(0, 0)
        result = c._c3_values_sum([result, close])
        add("M", document_bytes + 512 + 8, 3, (4, 1, 1, 1, 1), logical=document_bytes + 520)
    metadata = (source_files + len(entries) + 4) * 1024
    add("M", metadata, source_files + len(entries) + 4, (3, 0, 0, 0, 0), logical=metadata)
    result["close_calls"] += 4 * (source_files + len(entries) + 4)
    result["held_close_calls"] += 4 * (source_files + len(entries) + 4)
    result["observation_calls"] += 8 * (source_files + len(entries) + 4)
    c._c3_values_vector(result)
    return result


def c2_reserve_view(before, reservation, window):
    c2_require(type(before) is dict and type(reservation) is dict, "E_LIMIT")
    def complete(value):
        if type(value) is dict:return all(complete(item) for item in value.values())
        return type(value) is int and 0 <= value < 1 << 64
    c2_require(not before["incomplete"] and not before["unknown"] and not reservation["incomplete"] and not reservation["unknown"], "E_LIMIT")
    for value in (before, reservation):
        c2_require(all(type(value[key]) is int and 0 <= value[key] < 1 << 64 for key in _C2_SCALARS), "E_LIMIT")
        c2_require(set(value["runtime"]) == set(c._RUNTIME_FIELDS) and set(value["accounting"]) == set(_C2_CLASSES), "E_LIMIT")
        c2_require(all(set(value["accounting"][kind]) == set(_C2_ACCOUNT_FIELDS) for kind in _C2_CLASSES), "E_LIMIT")
        c2_require(complete(value["runtime"]) and complete(value["accounting"]) and complete(value["seed_processing"]), "E_LIMIT")
    candidate = {key: before[key] + reservation[key] for key in _C2_SCALARS}
    c._capture_copy_room(candidate, 0, False, case=not window)
    c2_require(candidate["files"] <= 256 and candidate["export_files"] <= (64 if window else 16), "E_LIMIT")
    for key, maximum in c._RUNTIME_FIELDS.items():
        c2_require(before["runtime"][key] + reservation["runtime"][key] <= (4 if window else 1) * maximum, "E_LIMIT")
    c2_require(all(before["accounting"]["unresolved"][key] == reservation["accounting"]["unresolved"][key] == 0 for key in _C2_ACCOUNT_FIELDS), "E_LIMIT")
    return candidate

def c2_reserve(before, reservation):
    c2_require(set(before) == set(reservation) == {"window", "cases", "common"}
        and set(reservation["cases"]) <= set(before["cases"]) <= _C2_CASES, "E_RELATION")
    result = c2_reserve_view(before["window"], reservation["window"], True)
    c2_reserve_view(before["common"], reservation["common"], False)
    for identity in before["cases"]:
        c2_require(identity in reservation["cases"], "E_RELATION")
        c2_reserve_view(before["cases"][identity], reservation["cases"][identity], False)
    return result

def c2_cli(arguments):
    c2_require(type(arguments) is list and arguments, "E_USAGE")
    mode = arguments[0]
    if mode == "run":
        c2_require(len(arguments) == 3, "E_USAGE")
        paths, observed = [arguments[1]], arguments[2]
    else:
        c2_require(mode == "dashboard" and len(arguments) == 6, "E_USAGE")
        paths, observed = arguments[2:], arguments[1]
    import re
    c2_require(re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", observed) is not None, "E_USAGE")
    c2_require(all(os.path.isabs(path) and os.path.normpath(path) == path for path in paths), "E_RELATION")
    parent = os.path.dirname(paths[0])
    c2_require(all(os.path.dirname(path) == parent for path in paths), "E_RELATION")
    if mode == "run":c2_require(os.path.basename(paths[0]) in {"seed-a.json", "seed-b.json"}, "E_RELATION")
    else:c2_require([os.path.basename(path) for path in paths] == ["seed-a.json", "run-a.json", "seed-b.json", "run-b.json"], "E_RELATION")
    return mode, parent, paths

def c2_document(custody, parent, name, maximum=_C2_LIMIT):
    held = custody.adopt(c._open_child(parent, name, False,
        c._store_rule(os.geteuid(), os.getegid(), 0o400, False, custody.resolver), "E_RELATION",
        recording_work=custody.work, accounting_kind="M"))
    raw = held.read(maximum, "E_RELATION", custody.work)
    value = c._json(raw, maximum, "E_RELATION")
    custody.work["read_bytes"] += len(raw)
    c._capture_account(custody.work, "M", "read_bytes", len(raw))
    rebuilt = C2Channel(9, custody.work).encode(value)
    equal = rebuilt == raw
    custody.work["read_bytes"] += 2 * len(raw)
    c._capture_account(custody.work, "M", "read_bytes", 2 * len(raw))
    c2_require(equal, "E_CANONICAL")
    custody.work["seed_processing"]["H"] += len(raw)
    measured = c2_sha(raw)
    return value, raw, measured, held

def c2_write_document(custody, parent, name, value):
    channel = C2Channel(9, custody.work)
    raw = channel.encode(value)
    return c2_write_bytes(custody, parent, name, raw, document=True)[0]


def c2_write_bytes(custody, parent, name, raw, *, document=False, mode=0o400):
    c2_require(type(raw) is bytes and len(raw) <= 16 * _C2_LIMIT
        and mode in {0o400, 0o500} and (not document or mode == 0o400), "E_LIMIT")
    before = parent.before;names = custody.namespace(parent)
    writer, first = None, None
    try:
        c2_nonruntime_room(custody.work, 0, False, files=1)
        writer = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=parent.fd)
        custody.work["files"] += 1;c._capture_account(custody.work, "M", "files", 1)
        custody.created_parent(parent, before, names, name)
        offset = 0
        while offset < len(raw):
            amount = min(65536, len(raw) - offset)
            c2_nonruntime_room(custody.work, amount, False, writing=True)
            sent = os.write(writer, memoryview(raw)[offset:offset+amount])
            if type(sent) is int and sent > 0:
                custody.work["write_bytes"] += sent;custody.work["physical_bytes"] += sent
            custody.work["seed_processing"]["W"] += sent;custody.work["seed_processing"]["C"] += sent
            c._capture_account(custody.work, "M", "write_bytes", sent);c._capture_account(custody.work, "M", "physical_bytes", sent)
            c2_require(type(sent) is int and 0 < sent <= amount, "E_RUNTIME")
            offset += sent
        os.fsync(writer);custody.observe("C2.receipt-fsync", {"fd": writer, "return": 0})
        closing, writer = writer, None
        c._close_capture_copy(closing, custody.work, custody.work, "C2.receipt-writer", None)
        if document:
            _value, observed, measured, held = c2_document(custody, parent, name)
        else:
            held = custody.adopt(c._open_child(parent, name, False,
                c._store_rule(os.geteuid(), os.getegid(), mode, False, custody.resolver), "E_STALE",
                recording_work=custody.work, accounting_kind="M"))
            c2_nonruntime_room(custody.work, len(raw), False, read_only=True)
            observed = held.read(len(raw), "E_STALE", custody.work)
            c._capture_account(custody.work, "M", "read_bytes", len(observed))
            custody.work["seed_processing"]["R"] += len(observed)
            measured = c2_driver_input_sha(custody, observed)
        equal = observed == raw
        custody.work["read_bytes"] += len(observed) + len(raw)
        c._capture_account(custody.work, "M", "read_bytes", len(observed) + len(raw))
        c2_require(equal, "E_STALE")
        held.recheck("E_STALE", custody.work, "M")
        return measured, held
    except BaseException as error:
        first = error;custody.fail(error)
    finally:
        if writer is not None:
            closing, writer = writer, None
            try:c._close_capture_copy(closing, custody.work, custody.work, "C2.receipt-failed-writer", first)
            except BaseException as error:custody.fail(error)
        if first is not None:raise custody.failure

def c2_seed_ids(value):
    c2_require(type(value) is dict and type(value.get("schema_version")) is int and value["schema_version"] == 1
        and value.get("kind") == "eval_seed_set" and type(value.get("body")) is dict, "E_SHAPE")
    body = value["body"]
    c2_require(body.get("seed_source") == "shadow.malicious-instructions.v1" and type(body.get("cases")) is list
        and 1 <= len(body["cases"]) <= 4, "E_SHAPE")
    identities = [row["case_id"] for row in body["cases"] if type(row) is dict and "case_id" in row]
    c2_require(len(identities) == len(body["cases"]) and all(type(identity) is str and identity in _C2_CASES for identity in identities)
        and len(set(identities)) == len(identities), "E_SHAPE")
    return set(identities)

def c2_stage(custody, descriptor, case_ids, destination, admitted_scope, copies=None):
    c2_require(type(descriptor) is dict and set(descriptor) == {"cases", "carry_in"}
        and type(descriptor["cases"]) is dict and set(descriptor["cases"]) == _C2_CASES, "E_SHAPE")
    cases = custody.adopt(c._open_child(custody.root, "cases", True,
        c._store_rule(os.geteuid(), os.getegid(), 0o700, True, custody.resolver), "E_STALE",
        recording_work=custody.work, accounting_kind="M"))
    if copies is None:copies = C2Copies(custody)
    for identity in case_ids:
        binding = descriptor["cases"][identity]
        c2_require(type(binding) is dict and set(binding) == {"inventory_core", "sha256"}, "E_SHAPE")
        core = binding["inventory_core"]
        c2_require(type(core) is dict and set(core) == {"case_id", "entries", "originals", "occurrences"}
            and core["case_id"] == identity and type(core["entries"]) is list and 1 <= len(core["entries"]) <= 256, "E_SHAPE")
        raw = C2Channel(9, custody.work).encode(core)
        custody.work["seed_processing"]["H"] += len(raw)
        c2_require(c2_sha(raw) == binding["sha256"], "E_RELATION")
        case = custody.adopt(c._open_child(cases, identity, True,
            c._store_rule(os.geteuid(), os.getegid(), 0o700, True, custody.resolver), "E_STALE",
            recording_work=custody.work, accounting_kind="M"))
        source = custody.adopt(c._open_child(case, "S", True,
            c._store_rule(os.geteuid(), os.getegid(), 0o700, True, custody.resolver), "E_STALE",
            recording_work=custody.work, accounting_kind="M"))
        c2_require(identity in admitted_scope["cases"], "E_RELATION")
        total = custody.work["C2_case_totals"][identity]
        leaf = c2_fresh_work("C2-I-" + identity)
        if "C2_tail_reservation" in custody.work:
            leaf["C2_case_reservation"] = custody.work["C2_tail_reservation"]["cases"][identity]
        custody.work.setdefault("C2_case_leaves", {})[identity] = leaf
        current = C2Copies(custody, leaf, total,
            custody.work.get("C2_admitted_before", admitted_scope)["window"], admitted_scope["cases"][identity])
        copies.case_copies.append(current)
        target = custody.mkdir(destination, identity)
        entries, roles = {}, set()
        for entry in core["entries"]:
            c2_require(type(entry) is dict and set(entry) == {"occurrence", "role", "member", "file", "size_bytes", "sha256", "kind"}, "E_SHAPE")
            c2_require(all(type(entry[key]) is str for key in ("occurrence", "role", "member", "kind")), "E_SHAPE")
            name = entry["file"]
            c2_require(type(name) is str and name not in {"", ".", ".."} and name not in entries
                and ("/" not in name or name in {"exports/reproduction.bin", "exports/write.bin"}
                    and entry["kind"] == "export" and entry["occurrence"] == name[8:-4]
                    and entry["role"] == "capture" and entry["member"].endswith("/sandbox-export.bin")), "E_SHAPE")
            role = (entry["occurrence"], entry["role"], entry["member"])
            c2_require(role not in roles, "E_SHAPE");roles.add(role);entries[name] = entry
        export_names = {name.split("/", 1)[1] for name in entries if name.startswith("exports/")}
        c2_require(custody.namespace(source) == frozenset(name.split("/", 1)[0] for name in entries), "E_RELATION")
        source_exports = target_exports = None
        if export_names:
            source_exports = custody.adopt(c._open_child(source, "exports", True,
                c._store_rule(os.geteuid(), os.getegid(), 0o700, True, custody.resolver), "E_STALE",
                recording_work=custody.work, accounting_kind="M"))
            c2_require(custody.namespace(source_exports) == frozenset(export_names), "E_RELATION")
            target_exports = custody.mkdir(target, "exports")
        for name, entry in entries.items():
            c2_require(entry["kind"] in {"runtime", "recorded", "export", "raw", "M", "W"}, "E_SHAPE")
            parent, output, basename = (source_exports, target_exports, name.split("/", 1)[1]) if name.startswith("exports/") else (source, target, name)
            held = custody.adopt(c._open_child(parent, basename, False,
                c._store_rule(os.geteuid(), os.getegid(), 0o400, False, custody.resolver), "E_STALE",
                recording_work=custody.work, accounting_kind="M"))
            current.copy(held, output, basename, entry["size_bytes"], entry["sha256"], entry["kind"])
        current.transfer_cases()
    return copies

def c2_driver_input_read(custody, held):
    before = custody.work["read_bytes"]
    try:return held.read(_C2_LIMIT, "E_STALE", custody.work)
    finally:custody.work["seed_processing"]["R"] += custody.work["read_bytes"] - before

def c2_driver_input_sha(custody, raw):
    try:measured = c2_sha(raw)
    except BaseException as error:
        try:custody.work["driver_input_hash_unknown"] = "UNKNOWN: driver input hash attempt incomplete"
        except BaseException as observed:raise c2_first(error, observed)
        raise
    custody.work["seed_processing"]["H"] += len(raw)
    return measured

def c2_driver_input_check(custody, seals):
    for installed, raw, expected in seals:
        c2_nonruntime_room(custody.work, 2 * len(raw), False, read_only=True)
        observed = c2_driver_input_read(custody, installed)
        c2_nonruntime_room(custody.work, len(observed) + len(raw), False, read_only=True)
        custody.work["read_bytes"] += len(observed) + len(raw)
        c._capture_account(custody.work, "M", "read_bytes", len(observed) + len(raw))
        custody.work["seed_processing"]["R"] += len(observed) + len(raw)
        custody.work["seed_processing"]["E"] += len(observed) + len(raw)
        c2_require(observed == raw, "E_STALE")
        c2_require(c2_driver_input_sha(custody, observed) == expected, "E_STALE")
        installed.recheck("E_STALE", custody.work, "M")

def c2_driver_input(custody, destination, scratch, mode, original_inputs, expected, window_source=None):
    sources, pending, failure, seals = [], None, None, []
    copies = C2Copies(custody)
    names = ["input.json"] if mode == "run" else ["manifest.json", "seed-0.json", "result-0.json", "seed-1.json", "result-1.json"]
    source_root = scratch if mode == "run" else scratch + "/inputs"
    try:
        c2_require(not custody.namespace(destination), "E_STALE")
        for index, name in enumerate(names):
            c2_nonruntime_room(custody.work, 0, False)
            pending = c._open_held(source_root + "/" + name, False,
                c._store_rule(os.geteuid(), os.getegid(), 0o400, False, custody.resolver), "E_STALE",
                recording_work=custody.work, accounting_kind="M")
            sources.append(pending);source, pending = pending, None
            size = source.before.st_size
            c2_require(0 <= size <= _C2_LIMIT, "E_LIMIT")
            c2_nonruntime_room(custody.work, 2 * size, False, read_only=True)
            raw = c2_driver_input_read(custody, source)
            measured = c2_driver_input_sha(custody, raw)
            if mode == "dashboard" and index == 0:
                c2_nonruntime_room(custody.work, len(raw), False, read_only=True)
                try:manifest = json.loads(raw, object_pairs_hook=c._unique_object)
                except BaseException as error:
                    try:custody.work["driver_input_parse_unknown"] = "UNKNOWN: driver input parse attempt incomplete"
                    except BaseException as observed:raise c2_first(error, observed)
                    if c2_cancelled(error):raise
                    if isinstance(error, (UnicodeDecodeError, UnicodeEncodeError, ValueError, TypeError, RecursionError)):
                        raise C2Refusal("E_RELATION") from None
                    raise
                custody.work["read_bytes"] += len(raw)
                c._capture_account(custody.work, "M", "read_bytes", len(raw))
                custody.work["seed_processing"]["R"] += len(raw)
                rebuilt = C2Channel(9, custody.work).encode(manifest)
                c2_nonruntime_room(custody.work, len(rebuilt) + len(raw), False, read_only=True)
                custody.work["read_bytes"] += len(rebuilt) + len(raw)
                c._capture_account(custody.work, "M", "read_bytes", len(rebuilt) + len(raw))
                custody.work["seed_processing"]["R"] += len(rebuilt) + len(raw)
                custody.work["seed_processing"]["E"] += len(rebuilt) + len(raw)
                c2_require(rebuilt == raw and type(manifest) is list and len(manifest) == 2, "E_RELATION")
                for pair, row in enumerate(manifest):
                    c2_require(type(row) is dict and set(row) == {"seed_sha256", "result_sha256"}
                        and row["seed_sha256"] == expected[2 * pair] and row["result_sha256"] == expected[2 * pair + 1], "E_RELATION")
            else:
                slot = index if mode == "run" else index - 1
                c2_nonruntime_room(custody.work, len(raw) + len(original_inputs[slot]), False, read_only=True)
                custody.work["read_bytes"] += len(raw) + len(original_inputs[slot])
                c._capture_account(custody.work, "M", "read_bytes", len(raw) + len(original_inputs[slot]))
                custody.work["seed_processing"]["R"] += len(raw) + len(original_inputs[slot])
                custody.work["seed_processing"]["E"] += len(raw) + len(original_inputs[slot])
                c2_require(raw == original_inputs[slot] and measured == expected[slot], "E_RELATION")
            installed = copies.copy(source, destination, "seed.json" if mode == "run" else name, size, measured, "M")
            seals.append((installed, raw, measured))
        expected_names = set(["seed.json"] if mode == "run" else names)
        if window_source is not None:
            held, raw, measured = window_source
            c2_require(type(held) is c.HeldPath and type(raw) is bytes and held.components
                and held.before.st_size == len(raw) and c2_driver_input_sha(custody, raw) == measured, "E_RELATION")
            held.recheck("E_STALE", custody.work, "M")
            installed = copies.copy(held, destination, "window.json", len(raw), measured, "M")
            seals.append((installed, raw, measured));expected_names.add("window.json")
            held.recheck("E_STALE", custody.work, "M")
        c2_require(custody.namespace(destination) == frozenset(expected_names), "E_RELATION")
        copies.final_checks()
        c2_driver_input_check(custody, seals)
    except BaseException as error:failure = error
    finally:
        while pending is not None or sources:
            source, pending = (pending, None) if pending is not None else (sources.pop(), None)
            while source.components:
                component = source.components.pop()
                try:c._close_capture_copy(component.fd, custody.work, custody.work, "C2.driver-input-source-close", failure)
                except BaseException as error:
                    failure = c2_first(failure, error)
                    try:custody.work["driver_input_close_unknown"] = "UNKNOWN: driver input source close accounting incomplete"
                    except BaseException as observed:failure = c2_first(failure, observed)
        if failure is not None:raise failure
    return destination.path + "/seed.json" if mode == "run" else destination.path, seals

def c2_scratch_parent(root_path, work=None):
    return os.path.join(tempfile.gettempdir(), "ystack-C2-ephemeral-" + c2_sha(os.fsencode(root_path), work))

def c2_lifecycle(launcher, arguments):
    sources = custody = copies = helpers = root = None
    work = None;failure = None;errors = [];receipt_sha = None;result = None;operation = None;scratch = None;admitted = False
    source_errors = [];driver_seals = None
    try:
        mode, root_path, paths = c2_cli(arguments)
        try:
            sources = C2Sources(launcher, root_path + "/operations/pending/runtime")
            sources.load_consumer()
        except BaseException as error:
            source_errors.append(error)
            raise
        work = c2_fresh_work("C2-terminal")
        sources.reconcile(work)
        c._close_capture_copy(0, work, work, "C2.stdin", None)
        resolver = c._DarwinUUIDResolver() if sys.platform == "darwin" else None
        sources.namespace["directory"](root_path)
        root = c._open_held(root_path, True, c._store_rule(os.geteuid(), os.getegid(), 0o700, True, resolver), "E_STALE",
            recording_work=work, accounting_kind="M")
        custody = C2Root(root, work, resolver)
        channel = C2Channel(9, work)
        start, start_raw = channel.receive("START")
        c2_require(start["mode"] == mode, "E_RELATION")
        c2_reserve(start["before"], start["tail_reservation"])
        c2_require(set(start["case_ids"]) <= set(start["before"]["cases"]), "E_RELATION")
        work["C2_case_totals"] = {identity: c2_fresh_work("C2-I-" + identity) for identity in start["case_ids"]}
        custody.bind_descriptor(10, start["root_identity"])
        descriptor, _window_raw, window_sha, _window = c2_document(custody, root, "window.json")
        c2_require(window_sha == start["window_sha256"], "E_RELATION")
        hashes, seed_cases, original_inputs = [], [], []
        for index, path in enumerate(paths):
            input_value, _raw, digest, _held = c2_document(custody, root, os.path.basename(path))
            hashes.append(digest);original_inputs.append(_raw)
            if mode == "run" or index % 2 == 0:seed_cases.append(c2_seed_ids(input_value))
        actual_cases = set().union(*seed_cases)
        c2_require(actual_cases == set(start["case_ids"]) and sum(len(value) for value in seed_cases) == len(actual_cases), "E_RELATION")
        if mode == "dashboard":c2_require(actual_cases == _C2_CASES, "E_RELATION")
        expected = start["seed_sha256s"] if mode == "run" else [start["seed_sha256s"][0], start["result_sha256s"][0], start["seed_sha256s"][1], start["result_sha256s"][1]]
        c2_require(hashes == expected, "E_RELATION")
        ordinal = start["ordinal"]
        c2_require(ordinal in {0, 1, 2} and (mode == "dashboard") == (ordinal == 2), "E_RELATION")
        if mode == "run":c2_require(os.path.basename(paths[0]) == ("seed-a.json" if ordinal == 0 else "seed-b.json"), "E_RELATION")
        seen = set(actual_cases)
        operations = custody.adopt(c._open_child(root, "operations", True,
            c._store_rule(os.geteuid(), os.getegid(), 0o700, True, resolver), "E_STALE", recording_work=work, accounting_kind="M"))
        if ordinal == 0:c2_require(start["predecessor_sha256"] == window_sha, "E_RELATION")
        else:
            previous = custody.adopt(c._open_child(operations, str(ordinal - 1), True,
                c._store_rule(os.geteuid(), os.getegid(), 0o700, True, resolver), "E_STALE", recording_work=work, accounting_kind="M"))
            prefix, _raw, previous_sha, _held = c2_document(custody, previous, "receipt.json")
            c2_require(previous_sha == start["predecessor_sha256"] and prefix["ordinal"] == ordinal - 1, "E_RELATION")
            prior_cases = set(prefix["seen_case_ids"])
            c2_require(prior_cases <= _C2_CASES and len(prior_cases) == len(prefix["seen_case_ids"]), "E_RELATION")
            if mode == "run":c2_require(not prior_cases & actual_cases and prior_cases | actual_cases == _C2_CASES, "E_RELATION")
            else:c2_require(prior_cases == actual_cases == _C2_CASES, "E_RELATION")
            seen |= prior_cases
        ready = {"kind": "READY", "version": 1, "ordinal": ordinal, "start_sha256": c2_sha(start_raw, work),
            "input_sha256s": hashes, "observed_predecessor_sha256": start["predecessor_sha256"],
            "acquisition_delta": c2_counters(work, ledger=True), "leaf_pid": os.getpid(), "leaf_ppid": os.getppid()}
        ready_raw, _written = channel.send(ready)
        go, _go_raw = channel.receive("GO")
        c2_require(go["ordinal"] == ordinal and go["start_sha256"] == c2_sha(start_raw, work)
            and go["ready_sha256"] == c2_sha(ready_raw, work) and go["tail_reservation"] == start["tail_reservation"], "E_RELATION")
        admitted_scope = c2_combine(start["before"], ready["acquisition_delta"], go["caller_delta"])
        c2_reserve(admitted_scope, go["tail_reservation"])
        work["C2_admitted_before"] = c2_combine(start["before"], go["caller_delta"])
        work["C2_tail_reservation"] = go["tail_reservation"]
        custody.recheck()
        admitted = True
        operation = custody.mkdir(operations, str(ordinal))
        installed = custody.mkdir(operation, "I")
        driver_inputs = custody.mkdir(installed, "driver-input")
        copies = C2Copies(custody)
        c2_stage(custody, descriptor, start["case_ids"], installed, admitted_scope, copies)
        scratch_parent = c2_scratch_parent(root_path, work)
        c2_nonruntime_room(work, 0, False, files=1)
        scratch = tempfile.mkdtemp(prefix="operation-" + str(ordinal) + "-", dir=scratch_parent)
        work["files"] += 1;c._capture_account(work, "M", "files", 1)
        c._capture_observe(work, "M", "C2.scratch-create", {"path": scratch})
        unused = [row["fd"] for row in sources.namespace["owned"] if not row["closed"]]
        unused += [item.fd for held in custody.owned for item in held.components]
        try:sources.validate_root(scratch + "/runtime")
        except BaseException as error:
            source_errors.append(error)
            raise
        helpers = C2Helpers(sources, scratch, work, unused)
        built = helpers.build(arguments)
        c2_require(built["status"] == 0 and not built["stdout"] and not built["stderr"], "E_RUNTIME")
        c2_require(custody.namespace(installed) == frozenset(start["case_ids"]) | {"driver-input"}, "E_RELATION")
        driver_input, driver_seals = c2_driver_input(custody, driver_inputs, scratch, mode, original_inputs, expected,
            (_window, _window_raw, window_sha))
        try:sources.materialize()
        except BaseException as error:
            source_errors.append(error)
            raise
        budget_seal = helpers._prepare_budget(custody, driver_inputs, descriptor, start,
            start_raw, ready_raw, _go_raw, window_sha, start["root_identity"], original_inputs)
        driver_seals.append(budget_seal)
        helpers.unused = tuple(unused + [item.fd for held in custody.owned for item in held.components])
        completed = helpers.run_and_check(arguments, driver_input)
        if completed["status"] != 0:
            c2_require(not completed["stdout"], "E_RUNTIME")
            token = completed["stderr"].rstrip(b"\n").decode("ascii")
            c2_require(token in {"E_RUNTIME", "E_LIMIT", "E_PARSE", "E_CANONICAL", "E_SHAPE", "E_RELATION", "E_STALE"}, "E_RUNTIME")
            raise C2Refusal(token)
        c2_require(not completed["stderr"], "E_RUNTIME")
        result = completed["stdout"]
        prefix = {"ordinal": ordinal, "mode": mode, "case_ids": sorted(actual_cases), "seen_case_ids": sorted(seen),
            "input_sha256s": hashes, "start_sha256": c2_sha(start_raw, work), "predecessor_sha256": start["predecessor_sha256"],
            "cutoff": c2_counters(work, ledger=True), "source_cutoff": sources.work}
        receipt_sha = c2_write_document(custody, operation, "receipt.json", prefix)
    except BaseException as error:
        failure = error
        errors.append({"site": "C2.lifecycle", "category": type(error).__name__, "errno": getattr(error, "errno", None)})
    finally:
        if custody is None and root is not None and root.components:
            try:root.close()
            except BaseException as error:failure = c2_first(failure, error)
        if driver_seals is not None:
            try:c2_driver_input_check(custody, driver_seals)
            except BaseException as error:failure = c2_first(failure, error)
        if copies is not None:
            try:copies.final_checks()
            except BaseException as error:
                failure = c2_first(failure, error)
        if sources is not None and getattr(sources, "materialized", False):
            try:sources.recheck()
            except BaseException as error:
                source_errors.append(error)
                failure = c2_first(failure, error)
        for owner in (helpers, custody, sources):
            if owner is not None:
                try:owner.close(failure)
                except BaseException as error:
                    if owner is sources:source_errors.append(error)
                    failure = c2_first(failure, error)
                    errors.append({"site": "C2.close", "category": type(error).__name__, "errno": getattr(error, "errno", None)})
        if work is not None:
            try:c._close_capture_copy(10, work, work, "C2.root-descriptor", failure)
            except BaseException as error:
                failure = c2_first(failure, error)
        if copies is not None:
            try:copies.transfer_cases()
            except BaseException as error:
                failure = c2_first(failure, error)
                errors.append({"site": "C2.case-transfer", "category": type(error).__name__, "errno": getattr(error, "errno", None)})
        if sources is not None and work is not None:
            try:sources.reconcile(work)
            except BaseException as error:
                failure = c2_first(failure, error)
                errors.append({"site": "C2.source-transfer", "category": type(error).__name__, "errno": getattr(error, "errno", None)})
        if scratch is not None:
            import shutil
            try:
                shutil.rmtree(scratch)
                c._capture_observe(work, "M", "C2.scratch-cleanup", {"path": scratch, "return": 0})
            except BaseException as error:
                failure = c2_first(failure, error)
                work["C2_cleanup_incomplete"] = True
    if work is None or "start" not in locals() or not admitted:
        token = b"E_STALE\n" if any(error is failure for error in source_errors) and not c2_cancelled(failure) else b"E_RUNTIME\n"
        os.write(2, token);os._exit(1)
    work["C2_tail_start"] = c2_counters(work)
    if failure is not None:
        result = None
        token = ("E_STALE" if any(error is failure for error in source_errors) and not c2_cancelled(failure)
            else failure.code if isinstance(failure, (C2Refusal, c.Refusal)) and failure.code in {"E_RUNTIME", "E_LIMIT", "E_PARSE", "E_CANONICAL", "E_SHAPE", "E_RELATION", "E_STALE"} else "E_RUNTIME")
        raw = (token + "\n").encode("ascii")
        c2_wire_room(work, len(raw), "W")
        count = os.write(2, raw)
        work["write_bytes"] += count;c._capture_account(work, "M", "write_bytes", count)
        work["seed_processing"]["W"] += count;work["seed_processing"]["C"] += count
        c2_require(count == len(raw), "E_RUNTIME")
    elif result is not None:
        offset = 0
        while offset < len(result):
            amount = min(65536, len(result)-offset)
            c2_wire_room(work, amount, "W")
            count = os.write(1, memoryview(result)[offset:offset+amount])
            c2_require(0 < count <= amount, "E_RUNTIME")
            work["write_bytes"] += count;c._capture_account(work, "M", "write_bytes", count)
            work["seed_processing"]["W"] += count;work["seed_processing"]["C"] += count;offset += count
    end_start_sha = c2_sha(start_raw, work)
    end_result_sha = None if result is None else c2_sha(result, work)
    terminal_before = c2_vector(work)
    end = {"kind": "END", "version": 1, "ordinal": start["ordinal"], "start_sha256": end_start_sha,
        "receipt_sha256": receipt_sha, "result_sha256": end_result_sha,
        "outcome": "refused" if failure is not None else "completed", "child_delta": c2_counters(work, ledger=True),
        "retained": [] if operation is None else [operation.path], "errors": errors,
        "unknown": [{"site": key, "value": value} for key, value in work.items() if key.endswith("_unknown") and value]}
    terminal_channel = C2Channel(9, work)
    end_raw, end_written = terminal_channel.send(end)
    terminal_after = c2_vector(work)
    delta = tuple(after - before for before, after in zip(terminal_before, terminal_after))
    c2_terminal(work, start["ordinal"], len(end_raw), end_written, delta)

if __name__ == "__main__":
    c2_lifecycle(sys.argv[1], sys.argv[2:])
'
c2_fd9=false
c2_fd10=false
[ ! -e /dev/fd/9 ] || c2_fd9=true
[ ! -e /dev/fd/10 ] || c2_fd10=true
if [ "$c2_fd9" = true ] || [ "$c2_fd10" = true ]; then
  if [ "$c2_fd9" != true ] || [ "$c2_fd10" != true ]; then
    printf '%s\n' E_RUNTIME >&2
    exit 1
  fi
  exec /usr/bin/python3 -I -S -B -c "$c2_program" "${BASH_SOURCE[0]}" "$@"
fi

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|E_STALE)
      /usr/bin/printf '%s\n' "$1" >&2
      ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

sha256_path() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

snapshot_file() {
  /usr/bin/perl -MFcntl=:DEFAULT,:mode -e '
    my ($source,$target,$limit,$mode)=@ARGV;
    sysopen(my $in,$source,O_RDONLY|O_NOFOLLOW) or exit 40;
    my @stat=stat($in);
    @stat && S_ISREG($stat[2]) or exit 40;
    $stat[7] <= $limit or exit 42;
    sysopen(my $out,$target,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,oct($mode))
      or exit 40;
    my $total=0;
    while (1) {
      my $read=sysread($in,my $buffer,65536);
      defined($read) or exit 40;
      last if $read == 0;
      $total += $read;
      $total <= $limit or exit 42;
      my $offset=0;
      while ($offset < $read) {
        my $written=syswrite($out,$buffer,$read-$offset,$offset);
        defined($written) && $written > 0 or exit 40;
        $offset += $written;
      }
    }
    close($in) or exit 40;
    close($out) or exit 40;
    chmod(oct($mode),$target) == 1 or exit 40;
  ' "$1" "$2" "$3" "$4"
}

snapshot_expected() {
  local expected=$1 source=$2 target=$3 mode=$4 status=0
  snapshot_file "$source" "$target" 16777216 "$mode" || status=$?
  [ "$status" -eq 0 ] && [ "$(sha256_path "$target")" = "$expected" ]
}

stage_expected() {
  local digest=$1 source=$2 target=$3 mode=$4 token=$5 parent
  parent=${source%/*}
  while [ "$parent" != / ]; do
    [ -d "$parent" ] && [ ! -L "$parent" ] || emit_error "$token"
    parent=${parent%/*}
    [ -n "$parent" ] || parent=/
  done
  if [ -e "$target" ] || [ -L "$target" ]; then
    [ -f "$target" ] && [ ! -L "$target" ] || emit_error "$token"
    [ "$(sha256_path "$target")" = "$digest" ] || emit_error "$token"
  else
    /bin/mkdir -p "${target%/*}" || emit_error "$token"
    snapshot_expected "$digest" "$source" "$target" "$mode" || emit_error "$token"
  fi
}

shadow_source_rows() {
  [ "$record_generation" = "$generation" ] || return 1
  /usr/bin/printf '%s\n' \
    'adapters/local-git-materializer/v1/materialize.sh 9b806bb5e202f98166aae60d391107c29aa0d19176765bf48fef47155f9fd358 28742 100755' \
    'adapters/local-git-materializer/v1/object-closure.c f1616b908c97e8a091029c24b3f2e1f8827171cbdee4d47195c66afd3e961e27 9312 100644' \
    'adapters/local-git-materializer/v1/protocol.jq 232517c19455667cca795769ffc0d8edad7873a9d55be0c21166de5b436bf323 22709 100644' \
    'config/construction-mode.json 5b3e0bafe63f84134e1b4aa2659e954bbbbd0bcc87d20716b03cd1b9d15a0fda 3178 100644' \
    'control/v1/control-policy-set-sandbox-bound.json a50d1ab32ef5964c9e3074084870bffa264fd138f325d830d166135545e3dc8d 3057 100644' \
    'control/v1/control-policy-set.json a3f9a8d16bd60a0cfc32da3e802a207c1e225013b7ef115030ef567d0ccd366a 3043 100644' \
    'control/v1/credential-policy-decision.json 73877276c868eae2da9dcedf8eb465b0526ce26a66506691b9cedbba15f00615 1583 100644' \
    'control/v1/credential-policy.jq 428ea96f23a18c6938421b9cc709d36ba83b34e2441347d5891a971f92d5ec77 13968 100644' \
    'control/v1/credential-policy.json 2ba0ec54d11ab4e9d02993e9283c5f820c662a20cf33d2bff25b1393a5ee403d 1444 100644' \
    'control/v1/duty-separation-decision.json 4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99 1409 100644' \
    'control/v1/duty-separation-policy.json b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9 2104 100644' \
    'control/v1/duty-separation.jq b4e480748dd4fb7dec769b25f0f7649b0e5dc31f9de438bba690e9eab6ac236c 10060 100644' \
    'control/v1/evaluate-bound-sandbox.sh 710615c6709250f40d0c494914e2577ee84896cde2b5828b4f457940b0347980 11866 100755' \
    'control/v1/evaluate-credential-policy.sh 5c9bab9d00754d63e4ead770489564db8122c53ab1bc8b6e92c27719265c18f7 40417 100755' \
    'control/v1/evaluate-duty.sh 146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa 21883 100755' \
    'control/v1/evaluate-evidence-integrity.sh f0ecbe036601102db082d0a94c860ea868614ff79d06f2b37ec8dcd672c367a2 79982 100755' \
    'control/v1/evaluate-kill-switch.sh ea1d40c50de706fa52198dc09e783ee613933aa0dbea72bfff8072becd79bb3b 19218 100755' \
    'control/v1/evaluate-risk-gates.sh 0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8 18673 100755' \
    'control/v1/evaluate-sandbox.sh 8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb 10018 100755' \
    'control/v1/evidence-integrity-decision.json 03e9225face347f1a4990beb6812f0e839d777cfbc6b95997d8031c4ad85e879 1859 100644' \
    'control/v1/evidence-integrity-policy.json 8e630c4aaee1cf1d97b3c04e96da6bb8408a0a46a2ce42bca2583767ee42f604 914 100644' \
    'control/v1/evidence-integrity.jq 3b57277a3eab151da66801254af65196fb6a71800486fe781232135169f68619 11254 100644' \
    'control/v1/kill-switch-decision.json c6328eb730b9c73c30469b90874c7811adc7b27a512f905f4a8dcdcd356b69cd 1604 100644' \
    'control/v1/kill-switch-policy.json b46eebfeb9de37eb0ebdb8fb297e0e200b537d0ca08dcf28eab7f91ef603e799 503 100644' \
    'control/v1/kill-switch.jq 59378b0049c511160427a113559089a81c17d5501662bf3ac02650bdfaf58817 13863 100644' \
    'control/v1/policy-set.jq 2be97550574ee4522fc0bd14780c92dee3c1b455f2c04b7763b0e437665a8d58 2560 100644' \
    'control/v1/risk-gates-decision.json 8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5 1563 100644' \
    'control/v1/risk-gates-policy.json 3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e 1844 100644' \
    'control/v1/risk-gates.jq d00fccd8e31b770c6df01fba17e3cc315d58edfbbf0a8055d66d537dc6ad21ff 13732 100644' \
    'control/v1/sandbox-bound-decision.json c8685bc8d15bb2375ab2263b0add5c151aa7c763fa3197bbacf886606f87df47 1492 100644' \
    'control/v1/sandbox-bound-policy.json ad1eab67be239e0f06f049bca91d51c475b3abb5917952a85c2a67f0450fbc6f 1875 100644' \
    'control/v1/sandbox-bound.jq 66a90e8847d70d297f6ea73dfc7879ffe44f7cb173a119c091c93a48f5f4b5cc 16172 100644' \
    'control/v1/sandbox-decision.json c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd 1459 100644' \
    'control/v1/sandbox-policy.json 4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e 1829 100644' \
    'control/v1/sandbox.jq 83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3 14949 100644' \
    'control/v1/validate.sh cf173ad0eaa08244bf636e3937845e894b21f14291fc5e66753e8673bdd2bd2a 3189 100755' \
    'core/v2/generation-registry.json 3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94 614 100644' \
    "core/v2/generations/${record_generation}/contracts.jq 65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a 2632 100644" \
    "core/v2/generations/${record_generation}/core-ingress.sh dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8 56400 100644" \
    "core/v2/generations/${record_generation}/modules/profile_graph.jq c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207 13338 100644" \
    "core/v2/generations/${record_generation}/modules/result_facts.jq 8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281 6035 100644" \
    "core/v2/generations/${record_generation}/modules/result_truth.jq ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46 15385 100644" \
    "core/v2/generations/${record_generation}/modules/schema.jq 8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade 16121 100644" \
    "core/v2/generations/${record_generation}/modules/stage_request.jq 6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e 15123 100644" \
    'enforcement/v1/accepted-identities.json c75dcd8d9268cb42677f5aa526fd374c3e45f2ba0fe678f47562ae49ad6851a0 174 100644' \
    'enforcement/v1/check-sandbox-receipt.sh 7db3412a4e740f79bde6af24891837fd5daa27d0811ff970b2f58534fcd59b97 10816 100755' \
    'enforcement/v1/sandbox-receipt.jq 43ab3a97b90444be17958112b7ff63966d1052981313c81bcb463618adae8619 30838 100644' \
    'evals/v1/replay-malicious.py 589614b11c626fd61f3462a93cfad30a354e323b4396174cf2f1d5b7d013c662 520339 100644' \
    'maintenance/v1/bands.jq 594994c057a1130da6727f5f825d2fed3ff01de4a9fafe3a722d9e964f05c8e4 10714 100644' \
    'maintenance/v1/incident-to-eval.jq 2229722267c3e9544d9cf53bd37d6d798f27adebad4a7439294989d0194ad92a 7237 100644' \
    'maintenance/v1/incident-to-eval.sh e000f961d7851c48b650ca36ed0c60fd2bc97ffc32442214b3f8937efc97f967 7449 100755' \
    'preparation/v1/prepare-candidate.py a860891bb3c20f757e2d15934e0ea6577cb3181b19e935a4c781e4f410f9fde5 138141 100644' \
    'sandbox/v1/build-guest.py 9aceb3492800d14d1842132c96ff6c5bf8b1ca83ad37477f9210908a78b08074 11671 100755' \
    'sandbox/v1/coverage-source.py 16b3204ce6a06a31199e585b71a41fc9949c307acd1a2782df5965d00fa8ed25 43901 100644' \
    'sandbox/v1/guest/common.c 731db0f01a72c0e319a36ee668cff16d30e298b4a8a75b2a1a0317c8b738f732 44272 100644' \
    'sandbox/v1/guest/common.h ef192e3fd3f5ae99f8e49b4bfbe58e6b0df6316d77c1690231b4138f4504cdd1 11926 100644' \
    'sandbox/v1/guest/init.c f2de00c7af19291d31160c5d22427c6e5b90f2c5e9702736fa82e6d13533acd3 5039 100644' \
    'sandbox/v1/guest/observation-values.c 21f6df504844b0eac300e52d47991a506e07b594a7ef507c41461e8c75e00bb9 55293 100644' \
    'sandbox/v1/guest/observation-values.h 8253a4e121c374792f86f2cbbdc8e65a39abbb10be2055f8db81b9966779ad96 8028 100644' \
    'sandbox/v1/guest/probe.c ab17cae1f35aa09889c63bcf3758f63c15bdb84bd6be895b685a4317c3199d71 255622 100644' \
    'sandbox/v1/guest/supervisor.c 905b2d57ba21c4a9b5622158135c547578bc7571d8b5ef43d5598e37a6688437 103685 100644' \
    'sandbox/v1/host-supervisor.py a1cdb3115e223f59a408394a78b7a3ba7573133e8ad04cd26c2634686cdcc649 232166 100755' \
    'sandbox/v1/runtime-vfkit.py 50a400dd73e8fa8d46cf93e5f8824ac80d5921cc1bf69d522bf11d4330050a14 6764 100755' \
    'scope/v1/evaluate-scope.sh fe6048b5eada5d86531e085acd0a9f46b73028d348349ab932e8c59f4e2ed66a 25253 100755' \
    'scope/v1/generate-gate-evidence.py 5444903bd219915137370970d60a15143b4e2210fd19706848b5bf8ac68e0864 54055 100755' \
    'scope/v1/read-shadow-evidence.py e4b633b9c0935272fd5193bc25d6ec4fba8763e689d04869e3ac1cf729b76295 165325 100644' \
    'scope/v1/scope-gates.jq 8f0b7cb6f42bc514f466fda710a1bf6fcfa0afe0abbc02d75e77e419a2ff9ed8 57384 100644' \
    'scope/v1/scope-policy.json 5c6db4debedfcd7117735bd1d4bf907293f73972ec8909c4eab9f25cf6417fe5 1181 100644' \
    'scope/v1/validate-scope.sh 99c0abae1bdcc3809dfac535a8b24137842abaec2418b90566b6ac8ff213b406 3194 100755' \
    'scope/v1/workflow-scope.jq 2d1df5f99b7019c4c41aece4f9fb89b00785ca47f9f8a713b2f43b212481366a 9728 100644' \
    'scripts/core-contract.sh b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 9176 100755' \
    'shadow/v1/_cancel_release.c 00ef369edbed569d50471b97f64aef57591b7afb8d9f25c286bffa5725faf015 55056 100644' \
    'shadow/v1/_consumer.py dd8ef865177d4b2714117cb1631bb24d896215be56475544321b2959c024ccee 427686 100644' \
    'shadow/v1/build-cancel-release.sh be1ad0afd99f72ea73fe52cca63c03381793710c587a82b57b9a38ed87c896d4 6169 100755' \
    'shadow/v1/enforced-reproduction.py b1d80c8aac16630e2e8d28303169bd8bb06d475dc6645b0d41ebed5aa942e511 136145 100755' \
    'shadow/v1/incident-record.jq 9ea6e1ec6556f54887ea6937533157856271aab68c74bda6d18dae1354d2687c 3695 100644' \
    'shadow/v1/qualified-identity.jq 33267bca348ad2b4923a5858b4788a6ca6adf1a1e9f471ee4450d7fe06387071 5343 100644' \
    'shadow/v1/shadow-environments.json 655771163e18384904eeaf2b7f22e3999957a037dce845b7fa6fdff2196ac4c7 1471 100644' \
    'shadow/v1/validate-incident.sh c9f907bfd73307c977c4191d65f6783a3bf969c3bb0be988f14aa9cb66ebe262 4870 100755' \
    'shadow/v1/write-materialization-input.jq 467a8f2901f053ff059302974ad80c5aaf1c805c6302e2333e1af0524fb3c510 4907 100644' \
    'shadow/v1/write-shadow.py a49396dc5bf2e636ce560c1da820e07d1c239fe855edac9197327fd724cfef02 70043 100755' \
    'telemetry/v1/trace-ledger.jq 5436deb48eca6d988a24bbce07855628edd3bc60386d9993a1169d6d373a4212 5849 100644' \
    'telemetry/v1/validate-trace-ledger.sh fc4b7cdd36b5d48675ed1d851c7b2d4fe59d0c431a31f3c361d6196f8900e208 8095 100755' \
    'verifiers/file-digest/v1/verifier.c fcf244b70dc6bcbfd1e6983e6c23d5f38a60654aa074adb472b0e749184dcfeb 28827 100644'
}

shadow_source_work_records=()
snapshot_shadow_sources() {
  local rows status=0 last
  rows=$(shadow_source_rows) || return 1
  shadow_source_work=$(/usr/bin/python3 -I -S -B - "$repo" "$runtime" "$rows" <<'PY_SHADOW_SOURCE'
import ctypes
import errno
import hashlib
import json
import os
import re
import signal
import stat
import sys

source_root, target_root, table = sys.argv[1:]
work = {"rows": [], "read_bytes": 0, "write_bytes": 0, "sha_bytes": 0,
        "equality_bytes": 0, "copy_bytes": 0, "physical_bytes": 0,
        "logical_bytes": 0, "logical_occurrences": 0, "reused_files": 0,
        "created_files": 0, "prior_physical_bytes": 0, "close_calls": 0, "observation_bytes": 0,
        "table_bytes": len(table.encode()), "snapshots": [], "snapshot_metadata_bytes": 0,
        "failures": [], "data_and_close_complete": False}
owned, directories, sources, targets = [], {}, {}, {}
library = None

def cancelled(error):
    return isinstance(error, KeyboardInterrupt) or getattr(error, "_D_source_cancel", False)

def first_error(first, later):
    return later if first is None or cancelled(later) and not cancelled(first) else first

def require(value):
    if not value:
        raise ValueError("D_SOURCE")

def note(site, *values):
    row = [site, *values]
    cost = len(json.dumps(row, separators=(",", ":")).encode()) + 1
    require(work["observation_bytes"] + cost <= 1048576 - 65536)
    work["rows"].append(row)
    work["observation_bytes"] += cost

def remember(site, error):
    try:
        work["failures"].append([site, type(error).__name__, getattr(error, "errno", None)])
    except BaseException:
        work["accounting_incomplete"] = True

def identity(value):
    return (value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode), value.st_uid,
            value.st_gid, stat.S_IMODE(value.st_mode), value.st_nlink, value.st_size,
            value.st_mtime_ns, value.st_ctime_ns)

def measured(fd):
    value = os.fstat(fd)
    note("fstat", fd, identity(value))
    return value

def absence(fd):
    global library
    before = identity(measured(fd))
    pointer, failure = None, None
    try:
        if sys.platform == "linux":
            empty = {getattr(errno, key) for key in ("ENODATA", "ENOATTR") if hasattr(errno, key)}
            for key in ("system.posix_acl_access", "system.posix_acl_default"):
                try:
                    value = os.getxattr(fd, key)
                except OSError as error:
                    note("getxattr", fd, key, None, error.errno)
                    if error.errno not in empty:
                        raise
                else:
                    work["read_bytes"] += len(value)
                    note("getxattr", fd, key, len(value), None)
                    raise ValueError("D_ACL_PRESENT")
        elif sys.platform == "darwin":
            if library is None:
                candidate = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
                candidate.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
                candidate.acl_get_fd_np.restype = ctypes.c_void_p
                candidate.acl_free.argtypes = [ctypes.c_void_p]
                candidate.acl_free.restype = ctypes.c_int
                library = candidate
            ctypes.set_errno(0)
            pointer = library.acl_get_fd_np(fd, 0x100)
            saved = ctypes.get_errno()
            note("acl_get_fd_np", fd, pointer, saved)
            require(not pointer and saved == errno.ENOENT)
        else:
            raise ValueError("D_PLATFORM")
        require(identity(measured(fd)) == before)
    except BaseException as error:
        failure = error
        raise
    finally:
        if pointer:
            freeing = None
            try:
                ctypes.set_errno(0)
                result = library.acl_free(pointer)
                saved = ctypes.get_errno()
                note("acl_free", fd, result, saved)
                if result != 0:
                    raise OSError(saved, "D ACL release")
            except BaseException as error:
                freeing = error
                remember("acl-free", error)
            if freeing is not None and first_error(failure, freeing) is freeing:
                raise freeing

def close_fd(fd, primary=None):
    failure = None
    try:
        os.close(fd)
    except BaseException as error:
        failure = error
        remember("close", error)
    try:
        work["close_calls"] += 1
        note("close", fd, 0 if failure is None else -1,
             getattr(failure, "errno", None))
    except BaseException as error:
        work["accounting_incomplete"] = True
        failure = first_error(failure, error)
    if failure is not None and first_error(primary, failure) is failure:
        raise failure

def close_one(row, primary=None):
    if not row["closed"]:
        row["closed"] = True
        close_fd(row["fd"], primary)

def acquire(path, parent, name, flags, mode=0o400):
    if not flags & os.O_DIRECTORY:
        require(hasattr(os, "O_NONBLOCK"))
        flags |= os.O_NONBLOCK
    fd = os.open(name if parent else path, flags, mode,
                 dir_fd=parent["fd"] if parent else None)
    try:
        row = {"fd": fd, "parent": parent, "name": name, "path": path, "closed": False}
        owned.append(row)
    except BaseException as error:
        close_fd(fd, error)
        raise
    note("open", parent["fd"] if parent else None, name, flags, fd)
    row["before"] = measured(fd)
    return row

def check(row):
    require(not row["closed"])
    before = identity(row["before"])
    require(identity(measured(row["fd"])) == before)
    if row["parent"]:
        current = os.stat(row["name"], dir_fd=row["parent"]["fd"], follow_symlinks=False)
        note("named-stat", row["parent"]["fd"], row["name"], identity(current))
        require(identity(current) == before)
    absence(row["fd"])

def trusted_directory(row, private=False):
    value = row["before"]
    require(stat.S_ISDIR(value.st_mode) and value.st_uid in {0, os.geteuid()})
    require(not value.st_mode & 0o022 or value.st_uid == 0 and value.st_mode & stat.S_ISVTX)
    if private:
        require(value.st_uid == os.geteuid() and value.st_gid == os.getegid()
                and stat.S_IMODE(value.st_mode) == 0o700)
    check(row)

def directory(path, create=False):
    if path in directories:
        check(directories[path])
        return directories[path]
    require(path.startswith("/") and os.path.normpath(path) == path)
    if path == "/":
        row = acquire(path, None, None, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    else:
        parent = directory(os.path.dirname(path), create)
        name = os.path.basename(path)
        check(parent)
        if create:
            try:
                os.mkdir(name, 0o700, dir_fd=parent["fd"])
            except FileExistsError:
                pass
            else:
                note("mkdir", parent["fd"], name, 0)
                refresh(parent)
        row = acquire(path, parent, name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    directories[path] = row
    trusted_directory(row, path == target_root or path.startswith(target_root + "/"))
    return row

def refresh(row):
    before, current = identity(row["before"]), measured(row["fd"])
    require(before[:6] == identity(current)[:6])
    row["before"] = current
    check(row)

def read_chunk(row, count):
    value = os.read(row["fd"], count)
    work["read_bytes"] += len(value)
    note("read", row["fd"], count, len(value))
    return value

def scan(rows):
    for folder in ("control/v1", "scope/v1"):
        parent = directory(source_root + "/" + folder)
        names = os.listdir(parent["fd"])
        note("listdir", parent["fd"], names)
        actual = set()
        for name in names:
            if name.endswith((".sh", ".jq", ".json", ".py")):
                value = os.stat(name, dir_fd=parent["fd"], follow_symlinks=False)
                note("scan-stat", parent["fd"], name, identity(value))
                require(stat.S_ISREG(value.st_mode))
                actual.add(folder + "/" + name)
        require(actual == {name for name in rows if name.startswith(folder + "/")})
        check(parent)

def parse_table():
    require(len(table.encode()) <= 1048576)
    entries = table.splitlines()
    require(len(entries) == 84)
    rows = {}
    for entry in entries:
        fields = entry.split(" ")
        require(len(fields) == 4)
        name, digest, size, mode = fields
        require(re.fullmatch(r"[A-Za-z0-9_./-]+", name) and not name.startswith("/")
                and all(part not in {"", ".", ".."} for part in name.split("/"))
                and re.fullmatch(r"[0-9a-f]{64}", digest)
                and re.fullmatch(r"0|[1-9][0-9]*", size)
                and mode in {"100644", "100755"} and name not in rows)
        size = int(size)
        require(size <= 16 * 1024 * 1024)
        rows[name] = (digest, size, int(mode, 8) & 0o777)
    require(sum(row[1] for row in rows.values()) <= 32 * 1024 * 1024)
    return rows

def source_inputs(rows):
    for name, (_digest, size, mode) in rows.items():
        parent = directory(os.path.dirname(source_root + "/" + name))
        item = acquire(source_root + "/" + name, parent, os.path.basename(name), os.O_RDONLY | os.O_NOFOLLOW)
        value = item["before"]
        require(stat.S_ISREG(value.st_mode) and value.st_uid in {0, os.geteuid()}
                and stat.S_IMODE(value.st_mode) == mode and value.st_size == size
                and value.st_nlink == 1)
        check(item)
        sources[name] = item
    scan(rows)
    registry = sources["core/v2/generation-registry.json"]
    registry_size = registry["before"].st_size
    require(registry_size <= 1048576)
    chunks, remaining = [], registry_size
    while remaining:
        chunk = read_chunk(registry, min(65536, remaining))
        require(bool(chunk))
        chunks.append(chunk)
        remaining -= len(chunk)
    raw = b"".join(chunks)
    work["registry_buffer_processing"] = "UNKNOWN: join/JSON processing is not in data-stream counters"
    measured_hash = hashlib.sha256(raw).hexdigest()
    work["sha_bytes"] += len(raw)
    require(measured_hash == rows["core/v2/generation-registry.json"][0])
    value = json.loads(raw)
    work["registry_parse_bytes"] = len(raw)
    require(type(value) is list and len(value) == 2 and value[1] == value[-1])
    keys = {"authorization_comment_id", "concern", "generation_id", "parent_generation_id", "semantic_identity"}
    for row in value:
        require(type(row) is dict and set(row) == keys and row["semantic_identity"] == "core.contracts.v2"
                and type(row["authorization_comment_id"]) is int and row["authorization_comment_id"] > 0
                and type(row["concern"]) is str and bool(row["concern"])
                and re.fullmatch(r"g-[0-9a-f]{64}", row["generation_id"])
                and re.fullmatch(r"g-[0-9a-f]{64}", row["parent_generation_id"]))
    require(value[1]["parent_generation_id"] == value[0]["generation_id"])
    prefix = "core/v2/generations/" + value[1]["generation_id"] + "/"
    require({name for name in rows if name.startswith("core/v2/generations/")} == {
        prefix + suffix for suffix in ("contracts.jq", "core-ingress.sh", "modules/profile_graph.jq",
            "modules/result_facts.jq", "modules/result_truth.jq", "modules/schema.jq", "modules/stage_request.jq")})

def copy_inputs(rows):
    for name, (expected, size, _mode) in rows.items():
        original = sources[name]
        parent = directory(os.path.dirname(target_root + "/" + name), True)
        check(parent)
        try:
            target = acquire(target_root + "/" + name, parent, os.path.basename(name),
                             os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            target = acquire(target_root + "/" + name, parent, os.path.basename(name), os.O_RDONLY | os.O_NOFOLLOW)
            created = False
            work["reused_files"] += 1
            work["prior_physical_bytes"] += target["before"].st_size
            require(target["before"].st_size == size)
        else:
            created = True
            work["created_files"] += 1
            refresh(parent)
        work["logical_bytes"] += size
        work["logical_occurrences"] += 1
        os.lseek(original["fd"], 0, os.SEEK_SET)
        digest, consumed = hashlib.sha256(), 0
        while consumed < size:
            chunk = read_chunk(original, min(65536, size - consumed))
            require(bool(chunk))
            consumed += len(chunk)
            digest.update(chunk)
            work["sha_bytes"] += len(chunk)
            if created:
                view = memoryview(chunk)
                while view:
                    sent = os.write(target["fd"], view)
                    require(sent > 0)
                    work["write_bytes"] += sent
                    work["copy_bytes"] += sent
                    work["physical_bytes"] += sent
                    note("write", target["fd"], len(view), sent)
                    view = view[sent:]
        require(digest.hexdigest() == expected)
        check(original)
        if created:
            os.fchmod(target["fd"], 0o400)
            note("fchmod", target["fd"], 0o400)
            os.fsync(target["fd"])
            note("fsync", target["fd"], 0)
            target["before"] = measured(target["fd"])
            reader = acquire(target["path"], parent, target["name"], os.O_RDONLY | os.O_NOFOLLOW)
            require(identity(reader["before"]) == identity(target["before"]))
            close_one(target)
            target = reader
        state = target["before"]
        require(stat.S_ISREG(state.st_mode) and state.st_uid == os.geteuid()
                and state.st_gid == os.getegid() and state.st_nlink == 1
                and stat.S_IMODE(state.st_mode) == 0o400 and state.st_size == size)
        check(target)
        record = {"path": name, "size_bytes": size, "source_sha256": digest.hexdigest(),
                  "source_identity": identity(original["before"]),
                  "snapshot_identity": identity(target["before"]), "reused": not created}
        work["snapshot_metadata_bytes"] += len(json.dumps(record, separators=(",", ":")).encode())
        work["snapshots"].append(record)
        target["record"] = record
        targets[name] = target

def final_checks(rows):
    scan(rows)
    for row in directories.values():
        check(row)
        if row["path"] == target_root or row["path"].startswith(target_root + "/"):
            os.fsync(row["fd"])
            note("fsync-directory", row["fd"], 0)
    for name, (expected, size, _mode) in rows.items():
        left, right = sources[name], targets[name]
        check(left);check(right)
        os.lseek(left["fd"], 0, os.SEEK_SET);os.lseek(right["fd"], 0, os.SEEK_SET)
        left_hash, right_hash, count = hashlib.sha256(), hashlib.sha256(), 0
        while count < size:
            amount = min(65536, size - count)
            a, b = read_chunk(left, amount), read_chunk(right, amount)
            work["equality_bytes"] += len(a) + len(b)
            left_hash.update(a);right_hash.update(b)
            work["sha_bytes"] += len(a) + len(b)
            require(len(a) == len(b) == amount and a == b)
            count += amount
        require(left_hash.hexdigest() == right_hash.hexdigest() == expected)
        previous_record_size = len(json.dumps(right["record"], separators=(",", ":")).encode())
        right["record"]["final_source_sha256"] = left_hash.hexdigest()
        right["record"]["snapshot_sha256"] = right_hash.hexdigest()
        work["snapshot_metadata_bytes"] += (len(json.dumps(right["record"], separators=(",", ":")).encode())
                                            - previous_record_size)
        check(left);check(right)
    for row in owned:
        if not row["closed"]:
            check(row)

def interrupt(_number, _frame):
    error = InterruptedError("D source acquisition cancelled")
    error._D_source_cancel = True
    raise error

for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(number, interrupt)

failure = None
try:
    require(os.path.isabs(source_root) and os.path.isabs(target_root)
            and os.path.normpath(source_root) == source_root and os.path.normpath(target_root) == target_root
            and source_root != target_root and not source_root.startswith(target_root + "/")
            and not target_root.startswith(source_root + "/"))
    rows = parse_table()
    source_inputs(rows)
    directory(target_root)
    copy_inputs(rows)
    final_checks(rows)
except BaseException as error:
    failure = error
    work["unobserved_call_results"] = "UNKNOWN; failed-operation counters are observed lower bounds"
    if isinstance(error, MemoryError):
        work["accounting_incomplete"] = True
    remember("acquisition", error)
finally:
    for row in reversed(owned):
        try:close_one(row, failure)
        except BaseException as error:
            failure = first_error(failure, error)
    if failure is not None:
        work.setdefault("unobserved_call_results", "UNKNOWN; failed-operation counters are observed lower bounds")
    work["data_and_close_complete"] = failure is None and not work.get("accounting_incomplete", False)

print(json.dumps(work, sort_keys=True, separators=(",", ":")))
raise SystemExit(0 if work["data_and_close_complete"] else 1)
PY_SHADOW_SOURCE
  ) || status=$?
  shadow_source_receipt_bytes=${#shadow_source_work}
  shadow_source_work_records+=("$shadow_source_work")
  last=$(( ${#shadow_source_work_records[@]} - 1 ))
  shadow_source_receipt_total_bytes=$(( ${shadow_source_receipt_total_bytes:-0} + ${#shadow_source_work_records[$last]} ))
  [ "$shadow_source_receipt_bytes" -le 1048576 ] || return 1
  [ "$status" -eq 0 ]
}


evals_initialize() {
# run SEED-SET.json OBSERVED_AT
# dashboard OBSERVED_AT SEED-SET.json RUN-RESULT.json [SEED-SET.json RUN-RESULT.json]...
mode=${1:-}
case "$mode" in
  run)
    [ "$#" -eq 3 ] || emit_error E_USAGE
    input=$2
    observed_at=$3
    pair_files=()
    ;;
  dashboard)
    [ "$#" -ge 4 ] && [ "$#" -le 34 ] && [ $(( ($# - 2) % 2 )) -eq 0 ] || emit_error E_USAGE
    observed_at=$2
    input=''
    shift 2
    pair_files=("$@")
    ;;
  *) emit_error E_USAGE ;;
esac
[[ "$observed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
  emit_error E_USAGE

self=$evals_self
case "$self" in /*) ;; *) self="$(pwd -P)/$self" ;; esac
[ -f "$self" ] && [ ! -L "$self" ] || emit_error E_RUNTIME
source_dir=$(CDPATH='' cd -P -- "${self%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
self="$source_dir/${self##*/}"
[ "$self" = "$source_dir/evals-launcher.sh" ] || emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$source_dir/../.." 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
[ "$source_dir" = "$repo/evals/v1" ] || emit_error E_RUNTIME
if [ "$mode" = run ]; then
  [ -f "$input" ] && [ ! -L "$input" ] || emit_error E_RUNTIME
else
  for pair_file in "${pair_files[@]}"; do
    [ -f "$pair_file" ] && [ ! -L "$pair_file" ] || emit_error E_RUNTIME
  done
fi

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Linux:x86_64)
    host_os=linux; host_arch=x86_64; jq_arch=x86_64; execution_mode=native
    jq_asset=jq-linux64
    jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44
    ;;
  Darwin:x86_64)
    host_os=darwin; host_arch=x86_64; jq_arch=x86_64; execution_mode=native
    jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    ;;
  Darwin:arm64)
    host_os=darwin; host_arch=arm64; jq_arch=x86_64; execution_mode=rosetta
    jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    ;;
  *) emit_error E_RUNTIME ;;
esac

jq_source=''
for candidate in "${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset" "/usr/bin/jq"; do
  if [ -f "$candidate" ] && [ ! -L "$candidate" ] &&
     [ "$(sha256_path "$candidate")" = "$jq_sha" ]; then
    jq_source=$candidate
    break
  fi
done
[ -n "$jq_source" ] || emit_error E_RUNTIME

generation=g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43
program_sha=cdb8365296530b9d6832de176913bd0bb73259f45c6524a4a61845b86cf5730e
review_approval_sha=none
catalog_sha=0239138447a8f9fd420cb3c5da31660d8f75c85099d80d89a040dce2878a4cac
driver_sha=d05c14ba062d799505c1ded6cd65bd7c4524cd83a8314176a5478d610471879e
}

evals_record_context() {
record_generation=$("$runtime/bin/jq" -er '
  if type == "array" and length == 2 and .[1] == .[-1] and all(.[];
    type == "object" and keys == ["authorization_comment_id","concern","generation_id",
      "parent_generation_id","semantic_identity"] and
    (.authorization_comment_id | type == "number" and . == floor and . > 0) and
    (.concern | type == "string" and length > 0) and
    .semantic_identity == "core.contracts.v2" and
    (.generation_id | type == "string" and test("\\Ag-[0-9a-f]{64}\\z")) and
    (.parent_generation_id | type == "string" and test("\\Ag-[0-9a-f]{64}\\z"))) and
    .[1].parent_generation_id == .[0].generation_id
  then .[1].generation_id else error("E_STALE") end
' "$runtime/core/v2/generation-registry.json" 2>/dev/null) || emit_error E_STALE
record_schema="core/v2/generations/$record_generation/modules/schema.jq"
record_files="$record_schema 8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade
evals/v1/framework.jq d164a102919f42ef002e93c8b515b58028604819e6c09b87c6e4afadb0bbcce4
evals/v1/run.sh 51770c5597d55bf05020502796810637bfbe697038a541ea6124530c0fffe55c"
}

evals_build() {
runtime="$scratch/runtime"
/bin/mkdir -m 0700 "$runtime" "$runtime/bin" "$runtime/core" "$runtime/core/v2" \
  "$runtime/core/v2/generations" "$runtime/scripts" "$runtime/orchestrator" \
  "$runtime/orchestrator/v1" "$runtime/control" "$runtime/control/v1" "$runtime/adapters" \
  "$runtime/adapters/codex-native-reviewer" "$runtime/adapters/codex-native-reviewer/v1" \
  "$runtime/adapters/github-actions-ci" "$runtime/adapters/github-actions-ci/v1" \
  "$runtime/adapters/github-forge" "$runtime/adapters/github-forge/v1" \
  "$runtime/adapters/gitlab-forge" "$runtime/adapters/gitlab-forge/v1" \
  "$runtime/adapters/codex-cli-producer" "$runtime/adapters/codex-cli-producer/v1" "$scratch/work" ||
  emit_error E_RUNTIME
generation_runtime="$runtime/core/v2/generations/$generation"
/bin/mkdir -m 0700 "$generation_runtime" "$generation_runtime/modules" ||
  emit_error E_RUNTIME

snapshot_file "$source_dir/run-evals.sh" "$runtime/bootstrap.sh" 1048576 0400 ||
  emit_error E_RUNTIME
bootstrap_sha=$(sha256_path "$runtime/bootstrap.sh") || emit_error E_RUNTIME
snapshot_file "$self" "$runtime/launcher.sh" 1048576 0400 || emit_error E_RUNTIME
launcher_sha=$(sha256_path "$runtime/launcher.sh") || emit_error E_RUNTIME
snapshot_expected "$driver_sha" "$source_dir/evals-driver.sh" "$runtime/driver.sh" 0400 ||
  emit_error E_STALE
snapshot_expected "$program_sha" "$source_dir/evals.jq" "$runtime/program.jq" 0400 ||
  emit_error E_STALE
snapshot_expected "$catalog_sha" "$source_dir/eval-catalog.json" "$runtime/catalog.json" 0400 ||
  emit_error E_STALE
snapshot_expected 3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94 \
  "$repo/core/v2/generation-registry.json" \
  "$runtime/core/v2/generation-registry.json" 0400 || emit_error E_STALE
snapshot_expected 65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a \
  "$repo/core/v2/generations/$generation/contracts.jq" \
  "$generation_runtime/contracts.jq" 0400 || emit_error E_STALE
snapshot_expected dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8 \
  "$repo/core/v2/generations/$generation/core-ingress.sh" \
  "$generation_runtime/core-ingress.sh" 0400 || emit_error E_STALE
for member in \
  'profile_graph.jq c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207' \
  'result_facts.jq 8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281' \
  'result_truth.jq ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46' \
  'schema.jq 8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade' \
  'stage_request.jq 6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e'; do
  read -r name digest <<<"$member"
  snapshot_expected "$digest" \
    "$repo/core/v2/generations/$generation/modules/$name" \
    "$generation_runtime/modules/$name" 0400 || emit_error E_STALE
done
snapshot_expected b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 \
  "$repo/scripts/core-contract.sh" "$runtime/scripts/core-contract.sh" 0400 ||
  emit_error E_STALE
# The inactive state scanner, replayed for the events family from inside the
# private runtime. It reads its core from this runtime's mirror, never the repo.
for member in \
  'reconciliation-plan.jq 03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4' \
  'scan-state.sh 556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5' \
  'state-scanner-driver.sh 5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b' \
  'state-scanner-launcher.sh 9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb' \
  'state-scanner.jq 722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae'; do
  read -r name digest <<<"$member"
  snapshot_expected "$digest" "$repo/orchestrator/v1/$name" \
    "$runtime/orchestrator/v1/$name" 0400 || emit_error E_STALE
done
# The inactive control evaluators replayed here: sandbox policy for the boundaries
# family; risk gates (with the duty-separation evaluator it regenerates) for the
# approval family; that same duty-separation evaluator on its own for the actor
# and re-run identity family. They read only this runtime.
for member in \
  'duty-separation-decision.json 4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99' \
  'duty-separation-policy.json b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9' \
  'duty-separation.jq b4e480748dd4fb7dec769b25f0f7649b0e5dc31f9de438bba690e9eab6ac236c' \
  'evaluate-duty.sh 146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa' \
  'evaluate-risk-gates.sh 0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8' \
  'evaluate-sandbox.sh 8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb' \
  'policy-set.jq 2be97550574ee4522fc0bd14780c92dee3c1b455f2c04b7763b0e437665a8d58' \
  'risk-gates-decision.json 8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5' \
  'risk-gates-policy.json 3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e' \
  'risk-gates.jq d00fccd8e31b770c6df01fba17e3cc315d58edfbbf0a8055d66d537dc6ad21ff' \
  'sandbox-decision.json c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd' \
  'sandbox-policy.json 4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e' \
  'sandbox.jq 83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3' \
  'validate.sh cf173ad0eaa08244bf636e3937845e894b21f14291fc5e66753e8673bdd2bd2a'; do
  read -r name digest <<<"$member"
  snapshot_expected "$digest" "$repo/control/v1/$name" \
    "$runtime/control/v1/$name" 0400 || emit_error E_STALE
done
# The inactive provider-snapshot normalizers, replayed for the adapter family.
for member in \
  'codex-cli-producer dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25' \
  'gitlab-forge ff2ec298eef102f94f28995f5306adeba8e078d19e4c22860c3b167cd9b7c37a' \
  'codex-native-reviewer 7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603' \
  'github-actions-ci 690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7' \
  'github-forge b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be'; do
  read -r name digest <<<"$member"
  snapshot_expected "$digest" "$repo/adapters/$name/v1/normalize.jq" \
    "$runtime/adapters/$name/v1/normalize.jq" 0400 || emit_error E_STALE
done
snapshot_expected "$jq_sha" "$jq_source" "$runtime/bin/jq" 0500 || emit_error E_RUNTIME
bash_sha=$(sha256_path /bin/bash) || emit_error E_RUNTIME
evals_record_context
while read -r path digest; do
  stage_expected "$digest" "$repo/$path" "$runtime/$path" 0400 E_STALE
done <<< "$record_files"
if [ "$review_approval_sha" != none ]; then
  [[ "$review_approval_sha" =~ ^[0-9a-f]{64}$ ]] || emit_error E_STALE
  stage_expected "$review_approval_sha" "$repo/evals/v1/seeds/reviewer-severity/approval.json" \
    "$runtime/evals/v1/seeds/reviewer-severity/approval.json" 0400 E_STALE
fi
: >"$runtime/review-files.tsv" || emit_error E_RUNTIME
snapshot_input() {
  local status=0
  snapshot_file "$1" "$2" 1048576 0400 || status=$?
  [ "$status" -eq 42 ] && emit_error E_LIMIT
  [ "$status" -eq 0 ] || emit_error E_RUNTIME
}
if [ "$mode" = run ]; then
  snapshot_input "$input" "$scratch/input.json"
  driver_input="$scratch/input.json"
  input_document="$scratch/input.json"
else
  # Each (seed set, run result) pair is snapshotted once; a manifest of their
  # digests is the single input document the driver binds to.
  /bin/mkdir -m 0700 "$scratch/inputs" || emit_error E_RUNTIME
  pair_count=$(( ${#pair_files[@]} / 2 ))
  manifest_entries=''
  j=0
  while [ "$j" -lt "$pair_count" ]; do
    snapshot_input "${pair_files[$((j * 2))]}" "$scratch/inputs/seed-$j.json"
    snapshot_input "${pair_files[$((j * 2 + 1))]}" "$scratch/inputs/result-$j.json"
    manifest_entries="$manifest_entries$(/usr/bin/printf '{"result_sha256":"%s","seed_sha256":"%s"}' \
      "$(sha256_path "$scratch/inputs/result-$j.json")" \
      "$(sha256_path "$scratch/inputs/seed-$j.json")")"
    j=$((j + 1))
    [ "$j" -eq "$pair_count" ] || manifest_entries="$manifest_entries,"
  done
  /usr/bin/printf '[%s]' "$manifest_entries" | "$runtime/bin/jq" -S -c . \
    > "$scratch/inputs/manifest.json" 2>/dev/null || emit_error E_RUNTIME
  /bin/chmod 0400 "$scratch/inputs/manifest.json" || emit_error E_RUNTIME
  driver_input="$scratch/inputs"
  input_document="$scratch/inputs/manifest.json"
fi
seed_sha=$(sha256_path "$input_document") || emit_error E_RUNTIME
review_seed_inputs=("$scratch/input.json")
if [ "$mode" = dashboard ]; then
  review_seed_inputs=()
  for ((j=0; j<pair_count; j++)); do review_seed_inputs+=("$scratch/inputs/seed-$j.json"); done
fi
for review_seed in "${review_seed_inputs[@]}"; do
  review_source=$("$runtime/bin/jq" -r '.body.seed_source // empty' "$review_seed" 2>/dev/null) || continue
  if [ "$review_source" = shadow.malicious-instructions.v1 ]; then
    [ "$evals_c2_custody" = true ] || emit_error E_RUNTIME
  fi
  [ "$review_source" = reviews.independent-verdicts.v1 ] || continue
  "$runtime/bin/jq" -e '
    any(.body.families[]; .family_id == "reviewer-severity-false-positive-negative" and
      .seed_status == "seeded" and (.seed_sources | index("reviews.independent-verdicts.v1") != null))
  ' "$runtime/catalog.json" >/dev/null 2>&1 || emit_error E_SHAPE
  "$runtime/bin/jq" -e '
    .body.shared.files | type == "array" and length >= 1 and length <= 16 and
    all(.[]; type == "object" and (keys == ["path","sha256"]) and
      (.path | type == "string" and
       test("\\Aevals/v1/seeds/reviewer-severity/verdicts/[1-9][0-9]*[.]md\\z") and length <= 255) and
      (.sha256 | type == "string" and test("\\A[0-9a-f]{64}\\z")))
  ' "$review_seed" >/dev/null 2>&1 || emit_error E_SHAPE
  "$runtime/bin/jq" -r '.body.shared.files[] | [.sha256,.path] | @tsv' "$review_seed" \
    >"$scratch/review-files.current" || emit_error E_RUNTIME
  while IFS=$'\t' read -r digest path; do
    stage_expected "$digest" "$repo/$path" "$runtime/$path" 0400 E_RELATION
    /usr/bin/printf '%s\t%s\n' "$digest" "$path" >>"$runtime/review-files.tsv" || emit_error E_RUNTIME
  done <"$scratch/review-files.current"
done
record_closure=$("$runtime/bin/jq" -R -s -c '
  split("\n") | map(select(length > 0) | split(" ") | {path:.[0],sha256:.[1]})
' <<< "$record_files") || emit_error E_RUNTIME

shadow_closure=$(shadow_source_rows | "$runtime/bin/jq" -R -s -c '
  split("\n") | map(select(length > 0) | split(" ") | {path:.[0],sha256:.[1]})
') || emit_error E_RUNTIME

"$runtime/bin/jq" -S -c -n \
  --arg bootstrap_sha "$bootstrap_sha" --arg launcher_sha "$launcher_sha" \
  --arg driver_sha "$driver_sha" --arg program_sha "$program_sha" \
  --arg catalog_sha "$catalog_sha" --argjson record_closure "$record_closure" \
  --argjson shadow_closure "$shadow_closure" \
  --arg jq_sha "$jq_sha" --arg bash_sha "$bash_sha" \
  --arg host_os "$host_os" --arg host_arch "$host_arch" \
  --arg jq_arch "$jq_arch" --arg execution_mode "$execution_mode" '
  def ref($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
  {
    schema_version:1,kind:"eval_framework_evaluator",id:"evals.framework.v1",
    body:{
      core_contract:{
        generation_id_sha256:"84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
        package_ref:ref("core-contract-package.v2";
          "application/vnd.ystack.core-contract+json";
          "eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"),
        semantic_identity:"core.contracts.v2"
      },
      core_closure:[
        {path:"core/v2/generation-registry.json",sha256:"3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/contracts.jq",sha256:"65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/core-ingress.sh",sha256:"dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/profile_graph.jq",sha256:"c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_facts.jq",sha256:"8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_truth.jq",sha256:"ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/schema.jq",sha256:"8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/stage_request.jq",sha256:"6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e"},
        {path:"scripts/core-contract.sh",sha256:"b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9"}
      ],
      orchestrator_closure:[
        {path:"orchestrator/v1/reconciliation-plan.jq",sha256:"03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4"},
        {path:"orchestrator/v1/scan-state.sh",sha256:"556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5"},
        {path:"orchestrator/v1/state-scanner-driver.sh",sha256:"5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b"},
        {path:"orchestrator/v1/state-scanner-launcher.sh",sha256:"9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb"},
        {path:"orchestrator/v1/state-scanner.jq",sha256:"722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae"}
      ],
      adapter_closure:[
        {path:"adapters/codex-cli-producer/v1/normalize.jq",sha256:"dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25"},
        {path:"adapters/codex-native-reviewer/v1/normalize.jq",sha256:"7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603"},
        {path:"adapters/github-actions-ci/v1/normalize.jq",sha256:"690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7"},
        {path:"adapters/github-forge/v1/normalize.jq",sha256:"b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be"},
        {path:"adapters/gitlab-forge/v1/normalize.jq",sha256:"ff2ec298eef102f94f28995f5306adeba8e078d19e4c22860c3b167cd9b7c37a"}
      ],
      control_closure:[
        {path:"control/v1/duty-separation-decision.json",sha256:"4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99"},
        {path:"control/v1/duty-separation-policy.json",sha256:"b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9"},
        {path:"control/v1/duty-separation.jq",sha256:"b4e480748dd4fb7dec769b25f0f7649b0e5dc31f9de438bba690e9eab6ac236c"},
        {path:"control/v1/evaluate-duty.sh",sha256:"146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa"},
        {path:"control/v1/evaluate-risk-gates.sh",sha256:"0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8"},
        {path:"control/v1/evaluate-sandbox.sh",sha256:"8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb"},
        {path:"control/v1/policy-set.jq",sha256:"2be97550574ee4522fc0bd14780c92dee3c1b455f2c04b7763b0e437665a8d58"},
        {path:"control/v1/risk-gates-decision.json",sha256:"8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5"},
        {path:"control/v1/risk-gates-policy.json",sha256:"3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e"},
        {path:"control/v1/risk-gates.jq",sha256:"d00fccd8e31b770c6df01fba17e3cc315d58edfbbf0a8055d66d537dc6ad21ff"},
        {path:"control/v1/sandbox-decision.json",sha256:"c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd"},
        {path:"control/v1/sandbox-policy.json",sha256:"4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e"},
        {path:"control/v1/sandbox.jq",sha256:"83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3"},
        {path:"control/v1/validate.sh",sha256:"cf173ad0eaa08244bf636e3937845e894b21f14291fc5e66753e8673bdd2bd2a"}
      ],
      record_closure:$record_closure,
      shadow_closure:$shadow_closure,
      bootstrap_ref:ref("evals-framework-bootstrap.v1";"text/x-shellscript";$bootstrap_sha),
      launcher_ref:ref("evals-framework-launcher.v1";"text/x-shellscript";$launcher_sha),
      driver_ref:ref("evals-framework-driver.v1";"text/x-shellscript";$driver_sha),
      program_ref:ref("evals-framework-program.v1";"text/x-jq";$program_sha),
      catalog_ref:ref("evals-catalog.v1";"application/vnd.ystack.eval-catalog+json";$catalog_sha),
      runtime:{
        host_os:$host_os,host_architecture:$host_arch,jq_architecture:$jq_arch,
        execution_mode:$execution_mode,
        jq_ref:ref("jq-runtime.v1";"application/x-executable";$jq_sha),
        shell_ref:ref("bash-runtime";"application/x-executable";$bash_sha)
      }
    }
  }
' > "$runtime/evaluator.json" 2>/dev/null || emit_error E_RUNTIME
evaluator_sha=$(sha256_path "$runtime/evaluator.json") || emit_error E_RUNTIME
"$runtime/bin/jq" -e --arg path "$record_schema" '
  [.body.core_closure[] | select(.path == $path)] ==
    [{path:$path,sha256:"8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade"}]
' "$runtime/evaluator.json" >/dev/null 2>&1 || emit_error E_STALE

}

evals_run_context() {
runtime="$scratch/runtime"
generation_runtime="$runtime/core/v2/generations/$generation"
bootstrap_sha=$(sha256_path "$runtime/bootstrap.sh") || emit_error E_RUNTIME
launcher_sha=$(sha256_path "$runtime/launcher.sh") || emit_error E_RUNTIME
bash_sha=$(sha256_path /bin/bash) || emit_error E_RUNTIME
evals_record_context
if [ "$mode" = run ]; then
  driver_input="$scratch/input.json"
  input_document="$scratch/input.json"
else
  pair_count=$(( ${#pair_files[@]} / 2 ))
  driver_input="$scratch/inputs"
  input_document="$scratch/inputs/manifest.json"
fi
if [ "$evals_c2_custody" = true ]; then
  driver_input=$evals_c2_driver_input
  if [ "$mode" = run ]; then input_document=$driver_input; else input_document="$driver_input/manifest.json"; fi
fi
seed_sha=$(sha256_path "$input_document") || emit_error E_RUNTIME
evaluator_sha=$(sha256_path "$runtime/evaluator.json") || emit_error E_RUNTIME
}

evals_run_and_check() {
output="$scratch/output.json"
error="$scratch/error"
/usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin TMPDIR="$scratch/work" \
  /bin/bash "$runtime/driver.sh" "$mode" "$runtime" "$driver_input" \
  "$runtime/evaluator.json" "$evaluator_sha" "$seed_sha" "$observed_at" \
  </dev/null >"$output" 2>"$error"
status=$?
if [ "$status" -ne 0 ]; then
  [ ! -s "$output" ] || emit_error E_RUNTIME
  driver_error=$(/bin/cat "$error" 2>/dev/null) || emit_error E_RUNTIME
  case "$driver_error" in
    E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|E_STALE)
      emit_error "$driver_error"
      ;;
    *) emit_error E_RUNTIME ;;
  esac
fi
[ ! -s "$error" ] || emit_error E_RUNTIME

# Independent re-validation of the delivered document against the exact same
# private program and core, after the driver has exited.
# program_check OPERATION EVALUATOR EVALUATOR_SHA SEED_SHA SEEDS OBSERVATIONS CANDIDATE RESULTS RESULT_SHAS
# check_observed_at names the time the candidate was built at; a run result is
# rebuilt at its own recorded time, the dashboard at this invocation's time.
check_observed_at=$observed_at
program_check() {
  [ "$("$runtime/bin/jq" -S -c -n -L "$generation_runtime/modules" \
    --arg evals_operation "$1" \
    --arg program_sha256 "$program_sha" --arg driver_sha256 "$driver_sha" \
    --arg catalog_sha256 "$catalog_sha" --arg evaluator_sha256 "$3" \
    --arg seed_set_sha256 "$4" \
    --arg tool_sha256 b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 \
    --arg scanner_sha256 556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5 \
    --arg planner_sha256 03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4 \
    --arg sandbox_sha256 8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb \
    --argjson normalizer_shas '{"codex-cli-producer":"dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25","codex-native-reviewer":"7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603","github-actions-ci":"690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7","github-forge":"b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be","gitlab-forge":"ff2ec298eef102f94f28995f5306adeba8e078d19e4c22860c3b167cd9b7c37a"}' \
    --arg risk_gates_sha256 0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8 \
    --arg duty_sha256 146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa \
    --arg observed_at "$check_observed_at" \
    --slurpfile catalog_docs "$runtime/catalog.json" \
    --slurpfile seed_set_docs "$5" \
    --slurpfile observation_docs "$6" \
    --slurpfile evaluator_docs "$2" \
    --slurpfile candidate_docs "$7" \
    --slurpfile result_docs "$8" --argjson result_shas "$9" \
    -f "$runtime/program.jq" 2>/dev/null)" = true ]
}
if [ "$mode" = run ]; then
  program_check validate-run-result "$runtime/evaluator.json" "$evaluator_sha" "$seed_sha" \
    "$driver_input" "$scratch/work/observations.json" "$output" \
    "$scratch/work/observations.json" '[]' || emit_error E_RUNTIME
else
  # Every pair is re-validated against the driver's replay, then the dashboard itself.
  j=0
  while [ "$j" -lt "$pair_count" ]; do
    check_observed_at=$("$runtime/bin/jq" -r '.body.observed_at' "$driver_input/result-$j.json") ||
      emit_error E_RUNTIME
    # The driver replayed this seed set into pair-$j; re-validate the supplied
    # result against that fresh observation set and this runtime's evaluator.
    [ -f "$scratch/work/pair-$j/observations.json" ] || emit_error E_RUNTIME
    program_check validate-run-result "$runtime/evaluator.json" "$evaluator_sha" \
      "$(sha256_path "$driver_input/seed-$j.json")" "$driver_input/seed-$j.json" \
      "$scratch/work/pair-$j/observations.json" "$driver_input/result-$j.json" \
      "$scratch/work/pair-$j/observations.json" '[]' || emit_error E_RELATION
    j=$((j + 1))
  done
  check_observed_at=$observed_at
  program_check validate-dashboard "$runtime/evaluator.json" "$evaluator_sha" "$seed_sha" \
    "$scratch/work/seeds.jsonl" "$scratch/work/pair-0/observations.json" "$output" \
    "$scratch/work/results.jsonl" \
    "$("$runtime/bin/jq" -c 'map(.result_sha256)' "$driver_input/manifest.json")" ||
    emit_error E_RUNTIME
fi
"$runtime/bin/jq" -S -c . "$output" > "$scratch/output.canonical" 2>/dev/null ||
  emit_error E_CANONICAL
/usr/bin/cmp -s "$output" "$scratch/output.canonical" || emit_error E_CANONICAL
[ "$(sha256_path "$runtime/bootstrap.sh")" = "$bootstrap_sha" ] &&
[ "$(sha256_path "$runtime/launcher.sh")" = "$launcher_sha" ] &&
[ "$(sha256_path "$runtime/adapters/codex-cli-producer/v1/normalize.jq")" = \
    dc2fff5f40517b3dc7a633f90483c661b9a4b2e7e4f1f40d9aa7c8edcf268f25 ] &&
[ "$(sha256_path "$runtime/adapters/gitlab-forge/v1/normalize.jq")" = \
    ff2ec298eef102f94f28995f5306adeba8e078d19e4c22860c3b167cd9b7c37a ] &&
[ "$(sha256_path "$runtime/adapters/codex-native-reviewer/v1/normalize.jq")" = \
    7baac5c59bc7934abc9512f3f949d1397d89b85f32b389f5c1f8a835e8c24603 ] &&
[ "$(sha256_path "$runtime/adapters/github-actions-ci/v1/normalize.jq")" = \
    690d9a8c35dc49f61a533d1ce1a9041e34895e5d337eb454bafa3a2e4d878df7 ] &&
[ "$(sha256_path "$runtime/adapters/github-forge/v1/normalize.jq")" = \
    b810117fb47c9f90efb0d0ea62efb3d46ff4c8c8e7a278c49a3abe1be57526be ] &&
[ "$(sha256_path "$runtime/control/v1/evaluate-sandbox.sh")" = \
    8c4b50e6ce324bbf8c3b14972356b153a40ab26c0dbcf54687e37d1133e8a3bb ] &&
[ "$(sha256_path "$runtime/control/v1/evaluate-risk-gates.sh")" = \
    0df2094a1a86901d5db8bd463cdeb295f455585b345096719bdc6dcd0b8852e8 ] &&
[ "$(sha256_path "$runtime/control/v1/risk-gates-policy.json")" = \
    3d8f0802777b4d7a63ded72643aca5cc8afd7613b76b5463291ca0ea63607a7e ] &&
[ "$(sha256_path "$runtime/control/v1/risk-gates-decision.json")" = \
    8e13f844fad5280aedc21a7d4c9b4bcf43f8eb0b0dd41a32a5989ce1473e28d5 ] &&
[ "$(sha256_path "$runtime/control/v1/risk-gates.jq")" = \
    d00fccd8e31b770c6df01fba17e3cc315d58edfbbf0a8055d66d537dc6ad21ff ] &&
[ "$(sha256_path "$runtime/control/v1/duty-separation-policy.json")" = \
    b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9 ] &&
[ "$(sha256_path "$runtime/control/v1/duty-separation-decision.json")" = \
    4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99 ] &&
[ "$(sha256_path "$runtime/control/v1/duty-separation.jq")" = \
    b4e480748dd4fb7dec769b25f0f7649b0e5dc31f9de438bba690e9eab6ac236c ] &&
[ "$(sha256_path "$runtime/control/v1/evaluate-duty.sh")" = \
    146e73dc880d363e889f32140ac375997fb709e3101de32b8d9603f1f38ca0fa ] &&
[ "$(sha256_path "$runtime/control/v1/policy-set.jq")" = \
    2be97550574ee4522fc0bd14780c92dee3c1b455f2c04b7763b0e437665a8d58 ] &&
[ "$(sha256_path "$runtime/control/v1/sandbox-decision.json")" = \
    c3e89800147d55f7c726ec66c82031915a4220d3eb7867e143f60d7026223bbd ] &&
[ "$(sha256_path "$runtime/control/v1/sandbox-policy.json")" = \
    4afb62e44fd3ad055d157ee23bfcf2917811b9ec05e4923eaa989d95d53c0a5e ] &&
[ "$(sha256_path "$runtime/control/v1/sandbox.jq")" = \
    83b08ff4817157bbda76aa3c85142cb9f297a0dc8cdb760f7c8eeebf6bbc0ef3 ] &&
[ "$(sha256_path "$runtime/control/v1/validate.sh")" = \
    cf173ad0eaa08244bf636e3937845e894b21f14291fc5e66753e8673bdd2bd2a ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/reconciliation-plan.jq")" = \
    03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4 ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/scan-state.sh")" = \
    556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5 ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/state-scanner-driver.sh")" = \
    5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/state-scanner-launcher.sh")" = \
    9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/state-scanner.jq")" = \
    722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae ] &&
[ "$(sha256_path "$runtime/driver.sh")" = "$driver_sha" ] &&
[ "$(sha256_path "$runtime/program.jq")" = "$program_sha" ] &&
[ "$(sha256_path "$runtime/catalog.json")" = "$catalog_sha" ] &&
[ "$(sha256_path "$runtime/bin/jq")" = "$jq_sha" ] &&
[ "$(sha256_path /bin/bash)" = "$bash_sha" ] &&
[ "$(sha256_path "$input_document")" = "$seed_sha" ] &&
[ "$(sha256_path "$runtime/evaluator.json")" = "$evaluator_sha" ] ||
  emit_error E_RUNTIME
while read -r path digest; do
  [ -f "$runtime/$path" ] && [ ! -L "$runtime/$path" ] &&
    [ "$(sha256_path "$runtime/$path")" = "$digest" ] || emit_error E_STALE
done <<< "$record_files"
while IFS=$'\t' read -r digest path; do
  [ -f "$runtime/$path" ] && [ ! -L "$runtime/$path" ] &&
    [ "$(sha256_path "$runtime/$path")" = "$digest" ] || emit_error E_RELATION
done <"$runtime/review-files.tsv"
if [ "$review_approval_sha" != none ]; then
  [ -f "$runtime/evals/v1/seeds/reviewer-severity/approval.json" ] &&
    [ ! -L "$runtime/evals/v1/seeds/reviewer-severity/approval.json" ] &&
    [ "$(sha256_path "$runtime/evals/v1/seeds/reviewer-severity/approval.json")" = "$review_approval_sha" ] ||
    emit_error E_STALE
fi
/bin/cat "$output" || emit_error E_RUNTIME
}

evals_c2_build() {
  evals_self=$1
  scratch=$2
  shift 2
  evals_c2_custody=true
  evals_initialize "$@"
  evals_build
}

evals_c2_run_and_check() {
  evals_self=$1
  scratch=$2
  evals_c2_driver_input=$3
  shift 3
  evals_c2_custody=true
  evals_initialize "$@"
  evals_run_context
  evals_run_and_check
}

# Fixed public entry; private functions above are not selected by argv or environment.
evals_self=${BASH_SOURCE[0]}
evals_c2_custody=false
evals_initialize "$@"
scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-evals.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM
evals_build
evals_run_and_check
trap - EXIT HUP INT TERM
cleanup
