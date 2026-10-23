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
        value = json.loads(raw, object_pairs_hook=_unique)
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
    exact(body, REQUEST_FIELDS)
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


def capture_rows(value):
    exact(value, {"pages"})
    rows = value["pages"]
    require(type(rows) is list and 3 <= len(rows) <= PAGE_LIMIT)
    family_index = -1
    previous = None
    index = 0
    seen_cursors = set()
    for row in rows:
        exact(row, {"family", "page_index", "response_status", "input_cursor", "output_cursor"})
        require(row["family"] in FAMILIES)
        selected = FAMILIES.index(row["family"])
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
    require(family_index == len(FAMILIES) - 1 and previous is None)
    return rows


def captured(records, request_raw):
    require(type(records) is list and 4 <= len(records) <= PAGE_LIMIT + 1
            and records[0][0] == b"capture.json")
    rows = capture_rows(document(records[0][1]))
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


def manifest(raw, pages, request_raw):
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
    capture_rows({"pages": capture})
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
