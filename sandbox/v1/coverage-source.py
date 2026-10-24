#!/usr/bin/env python3
"""Fixed, private coverage-read.v1 schemas and raw history normalizer."""
from __future__ import annotations
import datetime
import decimal
import hashlib
import json
import re

DOCUMENT_LIMIT = 1024 * 1024
PAGE_LIMIT = 128
RAW_LIMIT = 64 * DOCUMENT_LIMIT
OPERATION = "coverage-read.v1"
RULE_VERSION = "scope-coverage.v1"
FAMILIES = ("default-branch-history", "publisher-pull-requests", "branch-rule-history")
QUERIES = [{"family": family, "schema_version": 1} for family in FAMILIES]
REQUIRED_RULES = {"deletion", "non-fast-forward", "pull-request", "required-status-check"}


class Refusal(Exception):
    def __init__(self, code="E_COVERAGE"):
        self.code = code
        super().__init__(code)


def require(value):
    if not value:
        raise Refusal()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                      allow_nan=False).encode("utf-8") + b"\n"


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def _unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result


def document(raw, *, raw_page=False):
    require(type(raw) is bytes and 0 < len(raw) <= DOCUMENT_LIMIT)
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique)
        require(type(value) is dict and (raw_page or canonical(value) == raw))
        return value
    except (ValueError, UnicodeError, TypeError, RecursionError):
        raise Refusal() from None


def exact(value, fields):
    require(type(value) is dict and set(value) == set(fields))


def integer(value, low=0, high=2**53 - 1):
    require(type(value) is int and low <= value <= high)


def text(value, maximum=512):
    require(type(value) is str and 0 < len(value.encode("utf-8")) <= maximum
            and all(ord(char) >= 0x20 and ord(char) != 0x7f for char in value))


def identity(value):
    require(type(value) is str and re.fullmatch(r"[a-z0-9][a-z0-9._:-]{0,127}", value) is not None)


def sha(value):
    require(type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value) is not None)


def oid(value, algorithm=None):
    require(type(value) is str and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value) is not None)
    if algorithm is not None:
        require(len(value) == (40 if algorithm == "sha1" else 64))


def revision(value):
    exact(value, {"repository_id", "hash_algorithm", "commit_id"})
    identity(value["repository_id"])
    require(value["hash_algorithm"] in {"sha1", "sha256"})
    oid(value["commit_id"], value["hash_algorithm"])


def reference(value):
    exact(value, {"schema_version", "kind", "id", "sha256"})
    integer(value["schema_version"], 1, 2)
    identity(value["kind"])
    identity(value["id"])
    sha(value["sha256"])


def sorted_unique(values, key=lambda value: value, minimum=0, maximum=128):
    require(type(values) is list and minimum <= len(values) <= maximum)
    keys = [key(value) for value in values]
    require(keys == sorted(keys) and len(set(keys)) == len(keys))


def utc(value):
    require(type(value) is str)
    match = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d{1,9})?Z", value)
    require(match is not None)
    try:
        whole = datetime.datetime.strptime(match[1], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
        seconds = (whole - datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)).days * 86400
        seconds += whole.hour * 3600 + whole.minute * 60 + whole.second
        return decimal.Decimal(seconds) + decimal.Decimal(match[2] or "0")
    except ValueError:
        raise Refusal() from None


def age_ok(terminated_at, completed_at):
    delta = utc(completed_at) - utc(terminated_at)
    return decimal.Decimal(0) <= delta <= decimal.Decimal(2592000)


def envelope(value, kind):
    exact(value, {"schema_version", "kind", "id", "body"})
    require(type(value["schema_version"]) is int and value["schema_version"] == 1 and value["kind"] == kind)
    identity(value["id"])
    require(type(value["body"]) is dict)
    return value["body"]


REQUEST_FIELDS = {"attempt_id", "nonce", "repository_id", "coverage_base", "evaluated_revision",
    "coverage_rule_version", "documents", "qualifying_shadow_record_refs", "current_shadow_record_refs",
    "resolved_profile_ref", "stage_request_ref", "stage_result_ref", "materialization_refs",
    "publisher_request_refs", "post_check_refs", "qualifying_receipt_refs", "git_observation_sha256",
    "source_package_ref", "source_accepted_set_ref"}
DOCUMENT_NAMES = ("scope", "shadow-set", "dashboard", "risk", "kill", "duty", "marker")


def request(raw):
    value = document(raw)
    body = envelope(value, "coverage_source_request")
    require(set(body) in (REQUEST_FIELDS, REQUEST_FIELDS | {"initial_origin_refs", "gate_call_ref"}))
    if "gate_call_ref" in body:
        reference(body["gate_call_ref"])
        sorted_unique(body["initial_origin_refs"], canonical, 1, 128)
        for row in body["initial_origin_refs"]:
            reference(row)
    require(body["attempt_id"] == value["id"])
    sha(body["nonce"])
    require(value["id"] == "coverage." + body["nonce"])
    identity(body["repository_id"])
    revision(body["coverage_base"])
    revision(body["evaluated_revision"])
    require(body["coverage_base"]["repository_id"] == body["evaluated_revision"]["repository_id"] == body["repository_id"]
            and body["coverage_base"]["hash_algorithm"] == body["evaluated_revision"]["hash_algorithm"]
            and body["coverage_rule_version"] == RULE_VERSION)
    exact(body["documents"], DOCUMENT_NAMES)
    for row in body["documents"].values():
        reference(row)
    for name in ("qualifying_shadow_record_refs", "current_shadow_record_refs", "qualifying_receipt_refs"):
        rows = body[name]
        sorted_unique(rows, lambda row: canonical(row), 1, 16)
        for row in rows:
            reference(row)
    for name in ("resolved_profile_ref", "stage_request_ref", "stage_result_ref", "source_package_ref", "source_accepted_set_ref"):
        reference(body[name])
    for name in ("materialization_refs", "publisher_request_refs", "post_check_refs"):
        sorted_unique(body[name], lambda row: row["environment_id"], 1, 8)
        for row in body[name]:
            exact(row, {"environment_id", "sha256"})
            identity(row["environment_id"])
            sha(row["sha256"])
    sha(body["git_observation_sha256"])
    return value


def query(body):
    return {key: body[key] for key in ("repository_id", "coverage_base", "evaluated_revision",
        "coverage_rule_version", "qualifying_shadow_record_refs")} | {"families": QUERIES}


def cursor(value):
    if value is not None:
        text(value, 1024)


def capture_rows(value, families=FAMILIES):
    exact(value, {"pages"})
    rows = value["pages"]
    require(type(rows) is list and len(families) <= len(rows) <= PAGE_LIMIT)
    family_index = -1
    previous = None
    index = 0
    seen_cursors = set()
    for row in rows:
        exact(row, {"family", "page_index", "response_status", "input_cursor", "output_cursor"})
        require(row["family"] in families)
        selected = families.index(row["family"])
        if selected != family_index:
            require(selected == family_index + 1 and previous is None)
            family_index, index = selected, 0
            seen_cursors = set()
        integer(row["page_index"], 0, PAGE_LIMIT - 1)
        require(row["page_index"] == index and type(row["response_status"]) is int
                and row["response_status"] == 200 and row["input_cursor"] == previous)
        cursor(row["input_cursor"])
        cursor(row["output_cursor"])
        if row["output_cursor"] is not None:
            require(row["output_cursor"] not in seen_cursors)
            seen_cursors.add(row["output_cursor"])
        previous = row["output_cursor"]
        index += 1
        if previous is None:
            require(row is rows[-1] or rows[rows.index(row) + 1]["family"] != row["family"])
    require(family_index == len(families) - 1 and previous is None)
    return rows


def captured(records, request_raw, families=FAMILIES):
    require(type(records) is list and 4 <= len(records) <= PAGE_LIMIT + 1
            and records[0][0] == b"capture.json")
    rows = capture_rows(document(records[0][1]), families)
    require(len(rows) == len(records) - 1)
    pages = []
    manifest = []
    for index, (row, record) in enumerate(zip(rows, records[1:])):
        name, raw = record
        require(name == f"raw/{index:04d}".encode() and type(raw) is bytes
                and 0 < len(raw) <= DOCUMENT_LIMIT)
        pages.append(raw)
        manifest.append(row | {"request_sha256": digest(request_raw), "raw_size": len(raw), "raw_sha256": digest(raw)})
    require(sum(map(len, pages)) <= RAW_LIMIT)
    raw_manifest = canonical({"pages": manifest})
    require(len(raw_manifest) <= DOCUMENT_LIMIT)
    return raw_manifest, pages


def manifest(raw, pages, request_raw, families=FAMILIES):
    value = document(raw)
    exact(value, {"pages"})
    require(type(value["pages"]) is list and len(value["pages"]) == len(pages))
    capture = []
    for row, page in zip(value["pages"], pages):
        exact(row, {"family", "page_index", "response_status", "input_cursor", "output_cursor",
                    "request_sha256", "raw_size", "raw_sha256"})
        integer(row["raw_size"], 1, DOCUMENT_LIMIT)
        require(type(page) is bytes and row["raw_size"] == len(page)
                and row["raw_sha256"] == digest(page) and row["request_sha256"] == digest(request_raw))
        capture.append({key: row[key] for key in ("family", "page_index", "response_status", "input_cursor", "output_cursor")})
    require(sum(map(len, pages)) <= RAW_LIMIT)
    capture_rows({"pages": capture}, families)
    return value["pages"]


def rule(value):
    exact(value, {"rule_id", "target_pattern", "enforcement", "bypass_actors", "rule_type", "parameters"})
    text(value["rule_id"], 128)
    text(value["target_pattern"], 256)
    require(value["enforcement"] == "active")
    sorted_unique(value["bypass_actors"], maximum=128)
    for actor in value["bypass_actors"]:
        text(actor, 256)
    text(value["rule_type"], 128)
    require(type(value["parameters"]) is dict and len(canonical(value["parameters"])) <= 16384)


def rules(values):
    sorted_unique(values, lambda value: value["rule_id"], 4, 128)
    for value in values:
        rule(value)
    require(REQUIRED_RULES <= {value["rule_type"] for value in values})


def normalize(raw_manifest, pages, request_raw):
    body = request(request_raw)["body"]
    rows = manifest(raw_manifest, pages, request_raw)
    families = {family: [] for family in FAMILIES}
    for row, raw in zip(rows, pages):
        page = document(raw, raw_page=True)
        require(page.get("schema_version") == 1 and type(page.get("schema_version")) is int)
        families[row["family"]].append(page)
    history = families[FAMILIES[0]]
    first = history[0]
    exact(first, {"schema_version", "repository", "default_branch", "branch_snapshots", "commits"})
    repository, branch, snapshots = first["repository"], first["default_branch"], first["branch_snapshots"]
    exact(repository, {"repository_id", "node_id"})
    identity(repository["repository_id"])
    text(repository["node_id"], 256)
    require(repository["repository_id"] == body["repository_id"])
    exact(branch, {"name", "node_id"})
    text(branch["name"], 256)
    text(branch["node_id"], 256)
    exact(snapshots, {"baseline", "current"})
    for role, revision_key in (("baseline", "coverage_base"), ("current", "evaluated_revision")):
        snapshot = snapshots[role]
        exact(snapshot, {"branch_node_id", "commit_id", "observed_at"})
        require(snapshot["branch_node_id"] == branch["node_id"] and snapshot["commit_id"] == body[revision_key]["commit_id"])
        utc(snapshot["observed_at"])
    require(utc(snapshots["baseline"]["observed_at"]) <= utc(snapshots["current"]["observed_at"]))
    commits = []
    for page in history:
        exact(page, {"schema_version", "repository", "default_branch", "branch_snapshots", "commits"})
        require(page["repository"] == repository and page["default_branch"] == branch
                and page["branch_snapshots"] == snapshots and type(page["commits"]) is list)
        commits.extend(page["commits"])
    require(1 <= len(commits) <= 4096)
    algorithm = body["coverage_base"]["hash_algorithm"]
    seen = set()
    for index, row in enumerate(commits):
        exact(row, {"index", "commit_id", "parent_commit_id", "tree_id"})
        integer(row["index"], 0, 4095)
        require(row["index"] == index and row["commit_id"] not in seen
                and row["parent_commit_id"] == (None if index == 0 else commits[index - 1]["commit_id"]))
        oid(row["commit_id"], algorithm)
        oid(row["tree_id"], algorithm)
        seen.add(row["commit_id"])
    require(commits[0]["commit_id"] == body["coverage_base"]["commit_id"]
            and commits[-1]["commit_id"] == body["evaluated_revision"]["commit_id"])
    pulls = []
    for page in families[FAMILIES[1]]:
        exact(page, {"schema_version", "pull_requests"})
        require(type(page["pull_requests"]) is list)
        pulls.extend(page["pull_requests"])
    sorted_unique(pulls, lambda row: row["number"], maximum=4096)
    nodes = set()
    for row in pulls:
        exact(row, {"node_id", "number", "publisher_identity_ref", "base_commit_id", "head_commit_id",
                    "merge_commit_id", "merged", "merged_at", "source_branch", "scope_id", "changed_paths",
                    "publisher_request_sha256"})
        text(row["node_id"], 256)
        require(row["node_id"] not in nodes)
        nodes.add(row["node_id"])
        integer(row["number"], 1)
        reference(row["publisher_identity_ref"])
        for key in ("base_commit_id", "head_commit_id", "merge_commit_id"):
            oid(row[key], algorithm)
        require(row["merged"] is True)
        utc(row["merged_at"])
        text(row["source_branch"], 256)
        identity(row["scope_id"])
        sorted_unique(row["changed_paths"], minimum=1, maximum=10000)
        for path in row["changed_paths"]:
            text(path, 4096)
            require(not path.startswith("/") and "\\" not in path
                    and all(part not in {"", ".", "..", ".git"} for part in path.split("/")))
        sha(row["publisher_request_sha256"])
    rule_pages = families[FAMILIES[2]]
    baseline, current, events = rule_pages[0].get("baseline"), rule_pages[0].get("current"), []
    rules(baseline)
    rules(current)
    for page in rule_pages:
        exact(page, {"schema_version", "baseline", "current", "events"})
        require(page["baseline"] == baseline and page["current"] == current and type(page["events"]) is list)
        events.extend(page["events"])
    require(len(events) <= 4096)
    event_ids = set()
    previous_time = utc(snapshots["baseline"]["observed_at"])
    state_digests = {row["rule_id"]: digest(canonical(row)) for row in baseline}
    for event in events:
        exact(event, {"event_id", "event_time", "actor_identity", "operation", "rule_id", "before_sha256", "after_sha256"})
        text(event["event_id"], 256)
        require(event["event_id"] not in event_ids)
        event_ids.add(event["event_id"])
        instant = utc(event["event_time"])
        require(previous_time <= instant <= utc(snapshots["current"]["observed_at"]))
        previous_time = instant
        reference(event["actor_identity"])
        text(event["rule_id"], 128)
        require(event["operation"] in {"add", "update", "delete"})
        sha(event["before_sha256"])
        sha(event["after_sha256"])
        # Every intermediate applicable set must remain exactly baseline, including unknown rule kinds.
        require(event["operation"] == "update" and event["rule_id"] in {row["rule_id"] for row in baseline}
                and event["before_sha256"] == event["after_sha256"] == state_digests[event["rule_id"]])
    require(current == baseline)
    result = {"repository": repository, "default_branch": branch, "branch_snapshots": snapshots,
              "first_parent_commits": commits, "publisher_pull_requests": pulls,
              "branch_rules": {"baseline": baseline, "current": current, "events": events}}
    raw = canonical(result)
    require(len(raw) <= DOCUMENT_LIMIT)
    return raw


def doc_ref(raw):
    value = document(raw)
    return {key: value[key] for key in ("schema_version", "kind", "id")} | {"sha256": digest(raw)}


def physical(path):
    text(path, 4096)
    require(path.startswith("/") and all(part not in {"", ".", ".."} for part in path[1:].split("/")))


def source_config(raw, host):
    value = document(raw)
    body = envelope(value, "coverage_source_config")
    exact(body, {"source_id", "operation", "coverage_rule_version", "queries", "source_package_path",
        "source_package_sha256", "collector_path", "collector_sha256", "publisher_identity_ref",
        "accepted_set_path", "accepted_set_sha256", "store_id", "principal_uid", "consumer_gid"})
    identity(body["source_id"])
    require(body["operation"] == OPERATION and body["coverage_rule_version"] == RULE_VERSION and body["queries"] == QUERIES)
    for key in ("source_package_path", "collector_path", "accepted_set_path"):
        physical(body[key])
    for key in ("source_package_sha256", "collector_sha256", "accepted_set_sha256"):
        sha(body[key])
        require(body[key] not in {"0" * 64, "1" * 64})
    reference(body["publisher_identity_ref"])
    for key in ("store_id", "principal_uid", "consumer_gid"):
        require(body[key] == host[key] and type(body[key]) is type(host[key]))
    return value


def package(raw, config):
    require(digest(raw) == config["source_package_sha256"])
    value = document(raw)
    body = envelope(value, "coverage_source_package")
    exact(body, {"operation", "files"})
    require(body["operation"] == OPERATION)
    names = {"normalizer", "collector"} | {"schema." + family for family in FAMILIES}
    rows = body["files"]
    sorted_unique(rows, lambda row: row["role"], 5, 5)
    require({row["role"] for row in rows} == names)
    paths = set()
    for row in rows:
        exact(row, {"role", "path", "sha256"})
        physical(row["path"])
        sha(row["sha256"])
        require(row["sha256"] not in {"0" * 64, "1" * 64} and row["path"] not in paths)
        paths.add(row["path"])
        if row["role"] == "collector":
            require(row["path"] == config["collector_path"] and row["sha256"] == config["collector_sha256"])
    return value


def query_schema(raw, family):
    value = document(raw)
    exact(value, {"schema_version", "family", "operation", "page_fields"})
    fields = {FAMILIES[0]: ["branch_snapshots", "commits", "default_branch", "repository", "schema_version"],
              FAMILIES[1]: ["pull_requests", "schema_version"],
              FAMILIES[2]: ["baseline", "current", "events", "schema_version"]}
    require(value == {"schema_version": 1, "family": family, "operation": OPERATION, "page_fields": fields[family]})


def accepted(raw, config, supervisor_sha256, package_sha256, collector_sha256, normalizer_sha256):
    require(digest(raw) == config["accepted_set_sha256"])
    value = document(raw)
    body = envelope(value, "coverage_source_accepted_identity_set")
    exact(body, {"activation_state", "identities"})
    require(body["activation_state"] == "inactive" and type(body["identities"]) is list and len(body["identities"]) == 1)
    row = body["identities"][0]
    expected = {"source_id": config["source_id"], "operation": OPERATION, "proof_state": "qualified",
        "host_supervisor_sha256": supervisor_sha256, "source_package_sha256": package_sha256,
        "collector_sha256": collector_sha256, "normalizer_sha256": normalizer_sha256}
    require(row == expected)
    for key, value_hash in expected.items():
        if key.endswith("sha256"):
            sha(value_hash)
            require(value_hash not in {"0" * 64, "1" * 64})
    return value


def source_identity(config, accepted_raw, supervisor_sha256, normalizer_sha256):
    return {"source_id": config["source_id"], "host_supervisor_sha256": supervisor_sha256,
            "source_package_sha256": config["source_package_sha256"], "collector_sha256": config["collector_sha256"],
            "normalizer_sha256": normalizer_sha256, "accepted_source_identity_ref": doc_ref(accepted_raw)}


def receipt(raw, request_raw, config, source, raw_manifest, observation):
    requested = request(request_raw)
    value = document(raw)
    body = envelope(value, "forge_coverage_source_receipt")
    exact(body, {"operation", "version", "store_id", "attempt_id", "request_sha256", "nonce", "source_identity",
        "query", "raw_manifest_sha256", "observation_sha256", "started_at", "completed_at", "outcome", "effects"})
    require(value["id"] == requested["id"] and body["operation"] == OPERATION
            and type(body["version"]) is int and body["version"] == 1
            and body["store_id"] == config["store_id"] and body["attempt_id"] == requested["id"]
            and body["request_sha256"] == digest(request_raw) and body["nonce"] == requested["body"]["nonce"]
            and body["source_identity"] == source and body["query"] == query(requested["body"])
            and body["raw_manifest_sha256"] == digest(raw_manifest)
            and body["observation_sha256"] == digest(observation)
            and body["outcome"] == "complete" and body["effects"] == ["read-forge-metadata"])
    require(re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", body["started_at"]) is not None
            and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", body["completed_at"]) is not None
            and utc(body["started_at"]) <= utc(body["completed_at"]))
    return value


KILL_OPERATION = "kill-register-read.v1"
KILL_FAMILIES = ("repository-default-branch", "first-parent-register-history",
                 "default-branch-ref-history", "operator-merges")
KILL_QUERIES = [{"family": family, "schema_version": 1} for family in KILL_FAMILIES]
KILL_BINDINGS = {"basis_ref", "claim_ref", "stage_request_ref", "resolved_profile_ref", "stage_result_ref",
                 "policy_set_ref", "shadow_set_ref", "dashboard_ref", "marker_ref", "runtime_ref",
                 "source_package_ref", "source_accepted_set_ref"}


def kill_bootstrap(value):
    exact(value, {"commit_id", "register_sha256", "revision", "authority_epoch", "owner_identity", "event_sequence"})
    oid(value["commit_id"])
    sha(value["register_sha256"])
    integer(value["revision"], 1)
    identity(value["authority_epoch"])
    reference(value["owner_identity"])
    integer(value["event_sequence"])


def kill_register(raw):
    value = document(raw)
    body = envelope(value, "kill_switch_register")
    exact(body, {"revision", "authority_epoch", "entries", "write_entries"})
    integer(body["revision"], 1)
    identity(body["authority_epoch"])
    sorted_unique(body["entries"], lambda row: (row["scope_kind"], row["scope_id"]), maximum=1024)
    for row in body["entries"]:
        exact(row, {"scope_kind", "scope_id", "state"})
        require(row["scope_kind"] in {"global", "repository", "workflow"})
        if row["scope_kind"] == "global":
            require(row["scope_id"] == "*")
        else:
            identity(row["scope_id"])
        require(row["state"] in {"cleared", "stop"})
    sorted_unique(body["write_entries"], lambda row: row["scope_id"], maximum=1024)
    for row in body["write_entries"]:
        exact(row, {"scope_id", "state"})
        identity(row["scope_id"])
        require(row["state"] in {"cleared", "stop"})
    return value


def kill_request(raw):
    value = document(raw)
    body = envelope(value, "kill_register_source_request")
    exact(body, KILL_BINDINGS | {"operation", "version", "call_id", "nonce", "target_repository_id",
        "control_repository", "default_branch", "bootstrap", "bundle_refs", "initial_origin_refs", "git_observation_sha256"})
    require(body["operation"] == KILL_OPERATION and type(body["version"]) is int and body["version"] == 1)
    sha(body["nonce"])
    require(value["id"] == body["call_id"] == "kill-register." + body["nonce"])
    identity(body["target_repository_id"])
    exact(body["control_repository"], {"repository_id", "node_id", "hash_algorithm"})
    identity(body["control_repository"]["repository_id"])
    text(body["control_repository"]["node_id"], 256)
    require(body["control_repository"]["hash_algorithm"] in {"sha1", "sha256"})
    exact(body["default_branch"], {"name", "node_id"})
    for item in body["default_branch"].values():
        text(item, 256)
    kill_bootstrap(body["bootstrap"])
    for name in KILL_BINDINGS:
        reference(body[name])
    for name in ("bundle_refs", "initial_origin_refs"):
        sorted_unique(body[name], canonical, 1, 128)
        for row in body[name]:
            reference(row)
    sha(body["git_observation_sha256"])
    return value


def _git_object(raw_hex, kind, expected, algorithm):
    require(type(raw_hex) is str and len(raw_hex) <= 2 * DOCUMENT_LIMIT
            and re.fullmatch(r"(?:[0-9a-f]{2})*", raw_hex) is not None)
    raw = bytes.fromhex(raw_hex)
    oid(expected, algorithm)
    framed = kind.encode() + b" " + str(len(raw)).encode() + b"\0" + raw
    require(hashlib.new(algorithm, framed).hexdigest() == expected)
    return raw


def _kill_commit(row, algorithm):
    exact(row, {"commit_id", "commit_hex", "trees", "register_hex"})
    raw = _git_object(row["commit_hex"], "commit", row["commit_id"], algorithm)
    headers, separator, _message = raw.partition(b"\n\n")
    require(separator and b"\0" not in headers)
    lines = headers.split(b"\n")
    require(lines[0].startswith(b"tree "))
    tree_id = lines[0][5:].decode("ascii")
    oid(tree_id, algorithm)
    parents = [line[7:].decode("ascii") for line in lines if line.startswith(b"parent ")]
    for parent in parents:
        oid(parent, algorithm)
    require(len(parents) == len(set(parents)))
    require(type(row["trees"]) is list and len(row["trees"]) == 2)
    wanted = (b"config", b"kill-switch.json")
    for index, proof in enumerate(row["trees"]):
        exact(proof, {"oid", "raw_hex"})
        require(proof["oid"] == tree_id)
        tree = _git_object(proof["raw_hex"], "tree", tree_id, algorithm)
        width = 20 if algorithm == "sha1" else 32
        entries, names = [], set()
        while tree:
            prefix, nul, remaining = tree.partition(b"\0")
            require(nul and len(remaining) >= width)
            mode, space, name = prefix.partition(b" ")
            require(space and name and b"/" not in name and name not in {b".", b".."}
                    and name not in names and mode in {b"40000", b"100644", b"100755", b"120000", b"160000"})
            names.add(name)
            entries.append((name + (b"/" if mode == b"40000" else b""), mode, name, remaining[:width].hex()))
            tree = remaining[width:]
        require([entry[0] for entry in entries] == sorted(entry[0] for entry in entries))
        selected = [entry for entry in entries if entry[2] == wanted[index]]
        require(len(selected) == 1 and selected[0][1] == (b"40000" if index == 0 else b"100644"))
        tree_id = selected[0][3]
    register_raw = _git_object(row["register_hex"], "blob", tree_id, algorithm)
    register = kill_register(register_raw)
    return {"commit_id": row["commit_id"], "parents": parents, "tree_id": lines[0][5:].decode(),
            "register_blob": tree_id, "register_sha256": digest(register_raw), "register": register}, register_raw


def kill_normalize(raw_manifest, pages, request_raw):
    body = kill_request(request_raw)["body"]
    rows = manifest(raw_manifest, pages, request_raw, KILL_FAMILIES)
    grouped = {family: [] for family in KILL_FAMILIES}
    for row, raw in zip(rows, pages):
        page = document(raw, raw_page=True)
        require(type(page.get("schema_version")) is int and page["schema_version"] == 1)
        grouped[row["family"]].append(page)
    require(len(grouped[KILL_FAMILIES[0]]) == 1)
    snapshot = grouped[KILL_FAMILIES[0]][0]
    exact(snapshot, {"schema_version", "repository", "default_branch", "before", "after", "start_sequence", "end_sequence"})
    require(snapshot["repository"] == body["control_repository"] and snapshot["default_branch"] == body["default_branch"])
    algorithm = body["control_repository"]["hash_algorithm"]
    for role in ("before", "after"):
        exact(snapshot[role], {"commit_id", "observed_at"})
        oid(snapshot[role]["commit_id"], algorithm)
        utc(snapshot[role]["observed_at"])
    require(snapshot["before"]["commit_id"] == snapshot["after"]["commit_id"]
            and utc(snapshot["before"]["observed_at"]) <= utc(snapshot["after"]["observed_at"]))
    integer(snapshot["start_sequence"])
    integer(snapshot["end_sequence"], snapshot["start_sequence"])
    require(snapshot["start_sequence"] == body["bootstrap"]["event_sequence"])
    commits, raws = [], []
    for page in grouped[KILL_FAMILIES[1]]:
        exact(page, {"schema_version", "commits"})
        require(type(page["commits"]) is list)
        for row in page["commits"]:
            facts, raw = _kill_commit(row, algorithm)
            commits.append(facts)
            raws.append(raw)
    require(1 <= len(commits) <= 4096 and len({row["commit_id"] for row in commits}) == len(commits)
            and commits[0]["commit_id"] == body["bootstrap"]["commit_id"]
            and commits[-1]["commit_id"] == snapshot["after"]["commit_id"])
    boot = body["bootstrap"]
    require(commits[0]["register_sha256"] == boot["register_sha256"]
            and commits[0]["register"]["body"]["revision"] == boot["revision"])
    changes = []
    for index, row in enumerate(commits):
        register = row["register"]["body"]
        require(register["authority_epoch"] == boot["authority_epoch"])
        if index:
            previous = commits[index - 1]
            require(row["parents"] and row["parents"][0] == previous["commit_id"])
            if raws[index] != raws[index - 1]:
                require(register["revision"] > previous["register"]["body"]["revision"])
                changes.append(row)
    events = []
    for page in grouped[KILL_FAMILIES[2]]:
        exact(page, {"schema_version", "events"})
        require(type(page["events"]) is list)
        events.extend(page["events"])
    require(len(events) == snapshot["end_sequence"] - snapshot["start_sequence"] and len(events) <= 4096)
    cursor_commit = commits[0]["commit_id"]
    positions = {row["commit_id"]: index for index, row in enumerate(commits)}
    previous_time = None
    for sequence, event in enumerate(events, snapshot["start_sequence"] + 1):
        exact(event, {"sequence", "before", "after", "branch_node_id", "actor", "action", "at"})
        require(type(event["sequence"]) is int and event["sequence"] == sequence
                and event["branch_node_id"] == body["default_branch"]["node_id"] and event["action"] == "update"
                and event["before"] == cursor_commit and event["after"] in positions
                and positions[event["after"]] > positions[cursor_commit])
        reference(event["actor"])
        instant = utc(event["at"])
        require((previous_time is None or previous_time <= instant) and instant <= utc(snapshot["after"]["observed_at"]))
        previous_time, cursor_commit = instant, event["after"]
    require(cursor_commit == commits[-1]["commit_id"])
    merges = []
    for page in grouped[KILL_FAMILIES[3]]:
        exact(page, {"schema_version", "merges"})
        require(type(page["merges"]) is list)
        merges.extend(page["merges"])
    require(len(merges) == len(changes))
    seen = set()
    for row, changed in zip(merges, changes):
        exact(row, {"pull_request_id", "repository_node_id", "branch_node_id", "base", "head", "merge", "parents",
                    "path", "blob_oid", "actor", "owner_authorization", "merged_at"})
        text(row["pull_request_id"], 256)
        require(row["pull_request_id"] not in seen)
        seen.add(row["pull_request_id"])
        require(row["repository_node_id"] == body["control_repository"]["node_id"]
                and row["branch_node_id"] == body["default_branch"]["node_id"]
                and row["merge"] == changed["commit_id"] and row["parents"] == changed["parents"]
                and len(row["parents"]) == 2 and row["base"] == row["parents"][0] and row["head"] == row["parents"][1]
                and row["path"] == "config/kill-switch.json" and row["blob_oid"] == changed["register_blob"]
                and row["actor"] == boot["owner_identity"])
        exact(row["owner_authorization"], {"identity", "repository_node_id", "permission", "valid_at"})
        require(row["owner_authorization"] == {"identity": boot["owner_identity"],
            "repository_node_id": body["control_repository"]["node_id"], "permission": "owner", "valid_at": row["merged_at"]})
        require(utc(row["merged_at"]) <= utc(snapshot["after"]["observed_at"]))
        matching = [event for event in events if event["after"] == row["merge"]]
        require(len(matching) == 1 and matching[0]["actor"] == row["actor"] and matching[0]["before"] == row["base"])
    result = {"repository": snapshot["repository"], "default_branch": snapshot["default_branch"],
        "snapshots": {role: snapshot[role] for role in ("before", "after")}, "bootstrap": boot,
        "first_parent_commits": [{key: value for key, value in row.items() if key != "register"} for row in commits],
        "ref_events": events, "operator_merges": merges, "register": commits[-1]["register"],
        "register_sha256": digest(raws[-1])}
    raw = canonical(result)
    require(len(raw) <= DOCUMENT_LIMIT)
    return raw


class _KillNormalizer:
    """The second literal operation shares the existing installed source boundary."""
    OPERATION, FAMILIES, QUERIES = KILL_OPERATION, KILL_FAMILIES, KILL_QUERIES
    DOCUMENT_LIMIT, PAGE_LIMIT, RAW_LIMIT = DOCUMENT_LIMIT, PAGE_LIMIT, RAW_LIMIT
    request = staticmethod(kill_request)
    normalize = staticmethod(kill_normalize)
    doc_ref, digest, require = staticmethod(doc_ref), staticmethod(digest), staticmethod(require)
    source_identity = staticmethod(source_identity)

    @staticmethod
    def captured(records, request_raw):
        return captured(records, request_raw, KILL_FAMILIES)

    @staticmethod
    def query(body, observation):
        observed = document(observation)
        return {key: body[key] for key in ("control_repository", "default_branch", "bootstrap")} | {"families": KILL_QUERIES, "branch_snapshots": observed["snapshots"]}

    @staticmethod
    def source_config(raw, host):
        value = document(raw)
        body = envelope(value, "kill_register_source_config")
        exact(body, {"source_id", "operation", "queries", "source_package_path", "source_package_sha256", "collector_path",
            "collector_sha256", "accepted_set_path", "accepted_set_sha256", "store_id", "principal_uid", "consumer_gid",
            "control_repository", "default_branch", "bootstrap"})
        require(body["operation"] == KILL_OPERATION and body["queries"] == KILL_QUERIES)
        identity(body["source_id"])
        for key in ("source_package_path", "collector_path", "accepted_set_path"):
            physical(body[key])
        for key in ("source_package_sha256", "collector_sha256", "accepted_set_sha256"):
            sha(body[key])
            require(body[key] not in {"0" * 64, "1" * 64})
        for key in ("store_id", "principal_uid", "consumer_gid"):
            require(body[key] == host[key] and type(body[key]) is type(host[key]))
        kill_bootstrap(body["bootstrap"])
        exact(body["control_repository"], {"repository_id", "node_id", "hash_algorithm"})
        identity(body["control_repository"]["repository_id"])
        text(body["control_repository"]["node_id"], 256)
        require(body["control_repository"]["hash_algorithm"] in {"sha1", "sha256"})
        exact(body["default_branch"], {"name", "node_id"})
        for item in body["default_branch"].values():
            text(item, 256)
        return value

    @staticmethod
    def package(raw, config):
        require(digest(raw) == config["source_package_sha256"])
        value = document(raw)
        body = envelope(value, "kill_register_source_package")
        exact(body, {"operation", "files"})
        require(body["operation"] == KILL_OPERATION)
        names = {"normalizer", "collector"} | {"schema." + family for family in KILL_FAMILIES}
        sorted_unique(body["files"], lambda row: row["role"], 6, 6)
        require({row["role"] for row in body["files"]} == names)
        paths = set()
        for row in body["files"]:
            exact(row, {"role", "path", "sha256"})
            physical(row["path"])
            sha(row["sha256"])
            require(row["sha256"] not in {"0" * 64, "1" * 64} and row["path"] not in paths)
            paths.add(row["path"])
            if row["role"] == "collector":
                require(row["path"] == config["collector_path"] and row["sha256"] == config["collector_sha256"])
        return value

    @staticmethod
    def query_schema(raw, family):
        fields = {KILL_FAMILIES[0]: ["after", "before", "default_branch", "end_sequence", "repository", "schema_version", "start_sequence"],
                  KILL_FAMILIES[1]: ["commits", "schema_version"], KILL_FAMILIES[2]: ["events", "schema_version"],
                  KILL_FAMILIES[3]: ["merges", "schema_version"]}
        require(family in fields and document(raw) == {"schema_version": 1, "family": family,
            "operation": KILL_OPERATION, "page_fields": fields[family]})

    @staticmethod
    def accepted(raw, config, supervisor_sha256, package_sha256, collector_sha256, normalizer_sha256):
        require(digest(raw) == config["accepted_set_sha256"])
        body = envelope(document(raw), "kill_register_source_accepted_identity_set")
        exact(body, {"activation_state", "identities"})
        expected = {"source_id": config["source_id"], "operation": KILL_OPERATION, "proof_state": "qualified",
            "host_supervisor_sha256": supervisor_sha256, "source_package_sha256": package_sha256,
            "collector_sha256": collector_sha256, "normalizer_sha256": normalizer_sha256}
        require(body["activation_state"] == "inactive" and body["identities"] == [expected])
        for key, value in expected.items():
            if key.endswith("sha256"):
                sha(value)
                require(value not in {"0" * 64, "1" * 64})

    @staticmethod
    def receipt(raw, request_raw, host, source, raw_manifest, observation):
        requested = kill_request(request_raw)
        value = document(raw)
        body = envelope(value, "kill_register_source_receipt")
        exact(body, {"operation", "version", "store_id", "call_id", "request_sha256", "source_identity", "query",
                     "raw_manifest_sha256", "observation_sha256", "started_at", "completed_at", "outcome", "effects"})
        require(value["id"] == requested["id"] and body["call_id"] == requested["id"]
                and body["operation"] == KILL_OPERATION and type(body["version"]) is int and body["version"] == 1
                and body["store_id"] == host["store_id"] and body["request_sha256"] == digest(request_raw)
                and body["source_identity"] == source and body["query"] == _KillNormalizer.query(requested["body"], observation)
                and body["raw_manifest_sha256"] == digest(raw_manifest) and body["observation_sha256"] == digest(observation)
                and body["outcome"] == "complete" and body["effects"] == ["read-forge-metadata", "read-register"]
                and utc(body["started_at"]) <= utc(body["completed_at"]))
        return value
