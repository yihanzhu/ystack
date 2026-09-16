#!/usr/bin/env python3
"""Run one inactive, offline delivery replay without executing candidate code."""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import select
import signal
import shutil
import stat
import subprocess
import sys
import tempfile
import time


LOADED_DRIVER_BYTES = globals().get("_REPLAY_DRIVER_BYTES")
if LOADED_DRIVER_BYTES is None and __name__ == "__main__":
    try:
        driver_descriptor = os.open(__file__, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(driver_descriptor, "rb") as driver_handle:
            driver_source = driver_handle.read(8 * 1024 * 1024 + 1)
        if len(driver_source) > 8 * 1024 * 1024:
            raise OSError("replay driver exceeds its size limit")
        driver_code = compile(driver_source, __file__, "exec")
    except (OSError, SyntaxError, TypeError, ValueError) as error:
        print(f"delivery replay: loaded replay driver identity is unavailable: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    globals()["_REPLAY_DRIVER_BYTES"] = driver_source
    exec(driver_code, globals())
    raise SystemExit(1)

MAX_INPUT_BYTES = 8 * 1024 * 1024
MAX_OBSERVATION_BYTES = 64 * 1024
MAX_DELIVERY_KEY_BYTES = 4 * 1024
MAX_RESPONSE_BYTES = 1024 * 1024
MAX_STAGE_RESULT_BYTES = 256 * 1024
MAX_RECEIPT_BYTES = 64 * 1024
MAX_JOURNAL_V2_BYTES = 8 * 1024 * 1024
MAX_STDERR_BYTES = 64 * 1024
MAX_GIT_PATH_BYTES = 2 * 1024 * 1024
MAX_JSON_DEPTH = 32
MAX_VERIFIED_BLOB_BYTES = 1024 * 1024
GUARD_ACKNOWLEDGEMENT_SECONDS = 5
MAX_GUARD_LINE_BYTES = 4096
OID = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}\Z")
ACTOR = re.compile(r"[a-z0-9][a-z0-9._:-]{0,127}\Z")
# The core contract's id rule; the source repository id is journaled, so it is
# bounded before anything is written.
REPOSITORY_ID = re.compile(r"[a-z0-9][a-z0-9._:-]{0,127}\Z")
GIT_ENVIRONMENT = {
    "PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_NO_REPLACE_OBJECTS": "1",
    "GIT_NO_LAZY_FETCH": "1", "GIT_TERMINAL_PROMPT": "0",
}
NATIVE_EXECUTABLE_MAGICS = (
    b"\x7fELF", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
)
PACKAGE_FILES = (
    "adapters/local-git-materializer/v1/materialize.sh",
    "adapters/local-git-materializer/v1/protocol.jq",
    "scripts/core-contract.sh",
    "core/v2/generation-registry.json",
)
GENERATION_FILES = (
    "core-ingress.sh",
    "contracts.jq",
    "modules/schema.jq",
    "modules/profile_graph.jq",
    "modules/stage_request.jq",
    "modules/result_facts.jq",
    "modules/result_truth.jq",
)


class ReplayError(Exception):
    pass


class ReplayConflict(ReplayError):
    pass


def digest_bytes(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def canonical_document(value):
    return canonical(value) + b"\n"


def read_bytes(path, limit):
    # Open without blocking and refuse anything but a regular file before the
    # first read, so a FIFO or device cannot stall the replay.
    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ReplayError("input is not readable: %s" % path) from error
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ReplayError("input is not a regular file: %s" % path)
        chunks = []
        remaining = limit + 1
        while remaining:
            chunk = os.read(descriptor, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
    finally:
        os.close(descriptor)
    if len(data) > limit:
        raise ReplayError("input exceeds its size limit")
    return data


def parse_json(data):
    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                raise ReplayError("input contains duplicate JSON members")
            result[key] = value
        return result

    def reject_constant(_value):
        raise ReplayError("input contains a non-finite number")

    def check(value, depth=1):
        if depth > MAX_JSON_DEPTH:
            raise ReplayError("input exceeds its JSON depth limit")
        if isinstance(value, str):
            if any(0xD800 <= ord(char) <= 0xDFFF for char in value):
                raise ReplayError("input contains invalid Unicode")
        elif isinstance(value, float) and not math.isfinite(value):
            raise ReplayError("input contains a non-finite number")
        elif isinstance(value, dict):
            for key, child in value.items():
                check(key, depth + 1)
                check(child, depth + 1)
        elif isinstance(value, list):
            for child in value:
                check(child, depth + 1)

    if data.startswith(b"\xef\xbb\xbf"):
        raise ReplayError("input is not JSON")
    try:
        text = data.decode("utf-8", errors="strict")
        value = json.loads(text, object_pairs_hook=pairs, parse_constant=reject_constant)
        check(value)
        return value
    except ReplayError:
        raise
    except (ValueError, UnicodeDecodeError, RecursionError) as error:
        # Deeply nested input within the byte limit raises RecursionError; it is
        # still just input this program cannot accept, never a crash.
        raise ReplayError("input is not JSON") from error


def exact_object(value, required):
    return isinstance(value, dict) and set(value) == set(required)


def integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def atomic_json_limited(path, value, limit):
    encoded = canonical_document(value)
    if len(encoded) > limit:
        raise ReplayError("state journal exceeds its size limit")
    atomic_bytes(path, encoded)


def private_directory(path):
    value = Path(path)
    stat = value.stat()
    if value.is_symlink() or not value.is_dir() or stat.st_uid != os.getuid():
        raise ReplayError("state directory is not a caller-owned directory")
    if stat.st_mode & 0o077:
        raise ReplayError("state directory is not private")
    return value.resolve()


def trusted_file(path):
    value = Path(path)
    stat = value.stat()
    if value.is_symlink() or not value.is_file() or stat.st_size > MAX_INPUT_BYTES:
        raise ReplayError("trusted tool is unavailable")
    return value.resolve()


def disjoint(*paths):
    resolved = [Path(path).resolve() for path in paths]
    for index, left in enumerate(resolved):
        for right in resolved[index + 1:]:
            if left == right or left in right.parents or right in left.parents:
                raise ReplayError("caller-owned boundaries overlap")


def atomic_json(path, value):
    atomic_bytes(path, canonical(value) + b"\n")


def atomic_bytes(path, encoded):
    descriptor, temporary = tempfile.mkstemp(prefix=".replay-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def safe_path(value):
    if not isinstance(value, str) or not value or len(value) > 4096:
        raise ReplayError("verification path is invalid")
    parts = value.split("/")
    if any(part in {"", ".", "..", ".git"} or part.endswith((".", " ")) for part in parts):
        raise ReplayError("verification path is invalid")
    if any("\\" in part or any(ord(char) < 32 for char in part) for part in parts):
        raise ReplayError("verification path is invalid")
    return value


def package_paths(generation):
    root = f"core/v2/generations/{generation}"
    return PACKAGE_FILES + tuple(f"{root}/{name}" for name in GENERATION_FILES)


def execution_source_bytes(repository, arguments):
    core_relative = "scripts/core-contract.sh"
    core = read_bytes(trusted_file(repository / core_relative), MAX_INPUT_BYTES)
    match = re.search(
        rb"^PORTABLE_CORE_GENERATION='(g-[0-9a-f]{64})'$", core, re.MULTILINE
    )
    if match is None:
        raise ReplayError("materializer package generation is unavailable")
    generation = match.group(1).decode()
    package = {
        relative: core if relative == core_relative else
        read_bytes(trusted_file(repository / relative), MAX_INPUT_BYTES)
        for relative in package_paths(generation)
    }
    dependency_sources = {
        ".dependencies/object-closure": trusted_file(arguments.closure_helper),
        ".dependencies/jq": trusted_file(arguments.jq_bin),
    }
    for source in dependency_sources.values():
        # The snapshot copies dependencies with execute permission, so the caller
        # must already hold an executable file; bytes alone never confer that.
        if not os.access(source, os.X_OK) or not (os.stat(source).st_mode & 0o111):
            raise ReplayError("dependency is not executable")
    dependencies = {
        relative: read_bytes(source, MAX_INPUT_BYTES)
        for relative, source in dependency_sources.items()
    }
    if any(not data.startswith(NATIVE_EXECUTABLE_MAGICS) for data in dependencies.values()):
        raise ReplayError("dependency is not a native executable")
    return package | dependencies


def owned_staging_token(owner_path):
    if not owner_path.exists() or owner_path.is_symlink() or not owner_path.is_file():
        return None
    value = read_bytes(owner_path, 128)
    match = re.fullmatch(rb"ystack-delivery-execution-v1:([0-9a-f]{64})\n", value)
    return match.group(1) if match is not None else None


def create_execution_snapshot(repository, arguments, state_dir):
    root = state_dir / "execution"
    staging = state_dir / ".execution-building"
    owner_path = state_dir / ".execution-building.owner"
    if root.is_symlink() or root.exists():
        if root.is_symlink() or not root.is_dir():
            raise ReplayError("execution bundle is unavailable")
        # An existing bundle is judged by execution_sources_match, so changed or
        # invalid dependencies read as a mismatch there, not as a build failure here.
        return root
    source_bytes = execution_source_bytes(repository, arguments)
    token = owned_staging_token(owner_path)
    if staging.is_symlink() or staging.exists():
        if staging.is_symlink() or not staging.is_dir() or token is None:
            raise ReplayError("execution bundle staging is not program-owned")
        marker = staging / ".owner"
        entries = list(staging.iterdir())
        if entries and (
            marker not in entries or marker.is_symlink() or not marker.is_file() or
            read_bytes(marker, 128) != token + b"\n"
        ):
            raise ReplayError("execution bundle staging is not program-owned")
        shutil.rmtree(staging)
    if token is None:
        if owner_path.exists():
            raise ReplayError("execution bundle staging owner is invalid")
        token = os.urandom(32).hex().encode()
        descriptor = os.open(owner_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                             getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(descriptor, "wb") as owner:
            owner.write(b"ystack-delivery-execution-v1:" + token + b"\n")
            owner.flush()
            os.fsync(owner.fileno())
    os.mkdir(staging, 0o700)
    atomic_bytes(staging / ".owner", token + b"\n")
    os.chmod(staging / ".owner", 0o400)
    for relative, data in source_bytes.items():
        destination = staging / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        atomic_bytes(destination, data)
        mode = 0o500 if relative.endswith(".sh") or relative.startswith(".dependencies/") else 0o400
        os.chmod(destination, mode)
    os.replace(staging, root)
    directory = os.open(state_dir, os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    os.unlink(owner_path)
    return root


def execution_sources_match(repository, arguments, execution):
    try:
        return all(
            digest_bytes(data) == digest_bytes(read_bytes(trusted_file(execution / relative), MAX_INPUT_BYTES))
            for relative, data in execution_source_bytes(repository, arguments).items()
        )
    except (OSError, ReplayError):
        return False


def driver_identity():
    if not isinstance(LOADED_DRIVER_BYTES, bytes) or len(LOADED_DRIVER_BYTES) > MAX_INPUT_BYTES:
        raise ReplayError("loaded replay driver identity is unavailable")
    return digest_bytes(LOADED_DRIVER_BYTES)


def materializer_package_identity(repository):
    core_path = trusted_file(repository / "scripts/core-contract.sh")
    core_bytes = core_path.read_bytes()
    match = re.search(
        rb"^PORTABLE_CORE_GENERATION='(g-[0-9a-f]{64})'$", core_bytes, re.MULTILINE
    )
    if match is None:
        raise ReplayError("materializer package generation is unavailable")
    generation = match.group(1).decode()
    files = {
        relative: digest_bytes(trusted_file(repository / relative).read_bytes())
        for relative in package_paths(generation)
    }
    package = {"generation_id": generation, "files": files}
    package["sha256"] = digest_bytes(canonical(package))
    return package


def validate_delivery_key(value):
    if not exact_object(value, ("stage_key", "request_sha256", "operation", "attempt_number")):
        raise ReplayError("delivery key is malformed")
    stage_key = value.get("stage_key")
    stage_fields = ("initiative_id", "workflow_id", "stage_id", "task_class_id")
    if not exact_object(stage_key, stage_fields) or any(
        not isinstance(stage_key.get(name), str) or not ACTOR.fullmatch(stage_key[name])
        for name in stage_fields
    ) or not isinstance(value.get("request_sha256"), str) or \
       not re.fullmatch(r"[0-9a-f]{64}", value["request_sha256"]) or \
       value.get("operation") != "dispatch-stage" or \
       not integer(value.get("attempt_number")) or value["attempt_number"] != 1:
        raise ReplayError("delivery key is malformed")
    return value


def delivery_key(value, input_value):
    validate_delivery_key(value)
    stage_key = value["stage_key"]
    stage_fields = ("initiative_id", "workflow_id", "stage_id", "task_class_id")
    try:
        body = input_value["stage_request"]["content"]["body"]
        expected = {name: body[name] for name in stage_fields}
        attempt_number = input_value["attempt"]["attempt_number"]
        request_sha = input_value["stage_request"]["sha256"]
    except (KeyError, TypeError) as error:
        raise ReplayError("delivery key cannot be related to the input") from error
    if not integer(attempt_number):
        raise ReplayError("materialization input attempt number is malformed")
    if stage_key != expected or value["request_sha256"] != request_sha or \
       attempt_number != 1 or value["attempt_number"] != attempt_number:
        raise ReplayConflict("delivery key does not match the materialization input")
    return value


def input_identity(input_value, input_sha, arguments, execution, key=None):
    try:
        request = input_value["stage_request"]
        request_sha = request["sha256"]
        body = request["content"]["body"]
        source = body["target_revision"]["value"]
        source_tree_id = next(
            item["value"]["value"]["value"]["object_id"]
            for item in body["inputs"]
            if item["input_id"] == body["operation"]["arguments"]["source_tree_input_id"]
        )
    except (KeyError, StopIteration, TypeError) as error:
        raise ReplayError("materialization input lacks an exact source identity") from error
    if not isinstance(request_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", request_sha):
        raise ReplayError("materialization input request identity is invalid")
    if not isinstance(source_tree_id, str) or not OID.fullmatch(source_tree_id):
        raise ReplayError("materialization input tree identity is invalid")
    if not isinstance(source, dict) or not isinstance(source.get("commit_id"), str) or \
       not OID.fullmatch(source["commit_id"]):
        raise ReplayError("materialization input commit identity is invalid")
    if not isinstance(source.get("hash_algorithm"), str) or \
       source["hash_algorithm"] not in {"sha1", "sha256"}:
        raise ReplayError("materialization input hash algorithm is invalid")
    expected = arguments.expected_sha256
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ReplayError("expected verifier digest is invalid")
    package = materializer_package_identity(execution)
    identity = {
        "input_sha256": input_sha,
        "request_sha256": request_sha,
        "source_commit_id": source["commit_id"],
        "source_tree_id": source_tree_id,
        "source_hash_algorithm": source.get("hash_algorithm"),
        "verifier": {
            "id": "delivery.fixed-content-sha256.v1",
            "path": safe_path(arguments.verify_path),
            "expected_sha256": expected,
        },
        "driver_sha256": driver_identity(),
        "materializer_sha256": package["files"][PACKAGE_FILES[0]],
        "materializer_package": package,
        "closure_helper_sha256": digest_bytes(read_bytes(
            trusted_file(execution / ".dependencies/object-closure"), MAX_INPUT_BYTES
        )),
        "jq_sha256": digest_bytes(read_bytes(
            trusted_file(execution / ".dependencies/jq"), MAX_INPUT_BYTES
        )),
        "source_repository_id": arguments.source_repository_id,
    }
    if key is not None:
        identity["delivery_key"] = key
    identity["run_key"] = digest_bytes(canonical(identity))
    return identity


def materializer_command(arguments, execution, input_path, candidate_root, scratch_root):
    return [
        str(execution / PACKAGE_FILES[0]), "materialize", str(input_path),
        arguments.source_repository_id, str(Path(arguments.source_git_dir).resolve()),
        str(candidate_root), str(scratch_root),
        str(execution / ".dependencies/object-closure"), str(execution / ".dependencies/jq"),
    ]


def run_materializer(arguments, execution, input_path, identity, candidate_root=None, scratch_root=None):
    candidate_root = Path(arguments.candidate_root).resolve() if candidate_root is None else candidate_root
    scratch_root = Path(arguments.scratch_root).resolve() if scratch_root is None else scratch_root
    command = materializer_command(arguments, execution, input_path, candidate_root, scratch_root)
    environment = {"PATH": "/usr/bin:/bin", "LC_ALL": "C"}
    result = subprocess.run(command, env=environment, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False)
    if result.returncode != 0 or len(result.stdout) > MAX_INPUT_BYTES:
        raise ReplayError("materialization did not complete")
    try:
        response = json.loads(result.stdout)
        receipt_text = response["payloads"][0]["data"]
        receipt = json.loads(receipt_text)
        candidate = receipt["candidate"]
        receipt_sha = response["payloads"][0]["sha256"]
        if (
            receipt_sha != digest_bytes(receipt_text.encode()) or
            receipt["request_ref"]["sha256"] != identity["request_sha256"] or
            response["stage_result"]["body"]["request_ref"]["sha256"] != identity["request_sha256"] or
            receipt["source"] != {
                "repository_id": identity["source_repository_id"],
                "hash_algorithm": identity["source_hash_algorithm"],
                "commit_id": identity["source_commit_id"],
                "tree_id": identity["source_tree_id"],
            }
        ):
            raise ReplayError("materializer response does not match the input snapshot")
        return {
            "response_sha256": digest_bytes(result.stdout),
            "receipt_sha256": receipt_sha,
            "candidate_commit_id": candidate["commit_id"],
            "candidate_tree_id": candidate["tree_id"],
            "candidate_parent_commit_id": candidate["parent_commit_id"],
        }
    except (KeyError, IndexError, TypeError, json.JSONDecodeError) as error:
        raise ReplayError("materializer response is malformed") from error


def _capture_fixed_process(command, environment, stdout_limit):
    process = subprocess.Popen(command, env=environment,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    stdout_descriptor = process.stdout.fileno()
    stderr_descriptor = process.stderr.fileno()
    streams = {stdout_descriptor: (process.stdout, stdout_limit + 1),
               stderr_descriptor: (process.stderr, MAX_STDERR_BYTES)}
    captured = {stdout_descriptor: bytearray(), stderr_descriptor: bytearray()}
    try:
        while streams:
            readable, _, _ = select.select(list(streams), [], [])
            for descriptor in readable:
                stream, limit = streams[descriptor]
                chunk = os.read(descriptor, 65536)
                if not chunk:
                    stream.close()
                    del streams[descriptor]
                    continue
                remaining = limit - len(captured[descriptor])
                if remaining > 0:
                    captured[descriptor].extend(chunk[:remaining])
        returncode = process.wait()
    finally:
        try:
            if process.poll() is None:
                process.kill()
                process.wait()
        finally:
            process.stdout.close()
            process.stderr.close()
    return subprocess.CompletedProcess(command, returncode,
                                       bytes(captured[stdout_descriptor]),
                                       bytes(captured[stderr_descriptor]))


def capture_materializer(arguments, execution, input_path):
    command = materializer_command(
        arguments, execution, input_path,
        Path(arguments.candidate_root).resolve(), Path(arguments.scratch_root).resolve()
    )
    captured = _capture_fixed_process(
        command, {"PATH": "/usr/bin:/bin", "LC_ALL": "C"}, MAX_RESPONSE_BYTES
    )
    if len(captured.stdout) > MAX_RESPONSE_BYTES:
        raise ReplayError("materializer response exceeds its size limit")
    if captured.returncode != 0:
        diagnostic = captured.stderr.decode("utf-8", errors="replace").strip()
        raise ReplayError("materialization did not complete" + (f": {diagnostic}" if diagnostic else ""))
    return captured.stdout


def jq_canonical_document(execution, value):
    encoded = canonical_document(value)
    result = subprocess.run(
        [str(execution / ".dependencies/jq"), "-S", "-c", "."],
        input=encoded, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"}
    )
    if result.returncode != 0:
        raise ReplayError("fixed jq could not canonicalize stored evidence")
    return result.stdout


def validate_keyed_input(execution, input_path, input_bytes, input_value):
    if jq_canonical_document(execution, input_value) != input_bytes:
        raise ReplayError("keyed materialization input is not canonical")
    generation = materializer_package_identity(execution)["generation_id"]
    modules = execution / f"core/v2/generations/{generation}/modules"
    checked = subprocess.run([
        str(execution / ".dependencies/jq"), "-e", "-L", str(modules),
        "--arg", "command", "validate-input", "-f",
        str(execution / "adapters/local-git-materializer/v1/protocol.jq"), str(input_path)
    ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
       env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"}, check=False)
    if checked.returncode != 0:
        raise ReplayError("materialization input does not satisfy the fixed protocol")
    pairs = [input_value.get("profile"), input_value.get("resolved_profile"),
             input_value.get("stage_request")] + list(input_value.get("manifests", []))
    if any(not exact_object(pair, ("content", "sha256")) or
           digest_bytes(jq_canonical_document(execution, pair["content"])) != pair["sha256"]
           for pair in pairs):
        raise ReplayError("materialization input document digest is invalid")
    verified = {item.get("input_id"): item for item in
                input_value.get("trust_context", {}).get("verified_payloads", [])}
    for payload in input_value.get("payloads", []):
        item = verified.get(payload.get("input_id"))
        if not isinstance(payload.get("data"), str) or not isinstance(item, dict) or \
           not isinstance(item.get("sha256"), str) or \
           digest_bytes(payload["data"].encode("utf-8")) != item["sha256"]:
            raise ReplayError("materialization input payload digest is invalid")
    try:
        contract_id = input_value["stage_request"]["content"]["body"]["operation"]["arguments"][
            "materialization_contract"
        ]["input_id"]
        contract_text = next(item["data"] for item in input_value["payloads"]
                             if item["input_id"] == contract_id)
        contract = parse_json(contract_text.encode("utf-8"))
    except (KeyError, StopIteration, TypeError, UnicodeEncodeError) as error:
        raise ReplayError("materialization contract is malformed") from error
    if jq_canonical_document(execution, contract).decode("utf-8") != contract_text:
        raise ReplayError("materialization contract is not canonical")


def validate_materializer_response(arguments, execution, input_path, identity, response_bytes):
    if len(response_bytes) > MAX_RESPONSE_BYTES:
        raise ReplayError("materializer response exceeds its size limit")
    response = parse_json(response_bytes)
    if not isinstance(response, dict):
        raise ReplayError("materializer response is malformed")
    try:
        payload = response["payloads"][0]
        receipt_utf8 = payload["data"]
        stage_result = response["stage_result"]
    except (KeyError, IndexError, TypeError) as error:
        raise ReplayError("materializer response is malformed") from error
    if not isinstance(receipt_utf8, str):
        raise ReplayError("materializer receipt is malformed")
    try:
        receipt_bytes = receipt_utf8.encode("utf-8", errors="strict")
    except UnicodeEncodeError as error:
        raise ReplayError("materializer receipt is malformed") from error
    if len(receipt_bytes) > MAX_RECEIPT_BYTES:
        raise ReplayError("materializer receipt exceeds its size limit")
    receipt = parse_json(receipt_bytes)
    receipt_sha = digest_bytes(receipt_bytes)
    stage_bytes = jq_canonical_document(execution, stage_result)
    if len(stage_bytes) > MAX_STAGE_RESULT_BYTES:
        raise ReplayError("materializer stage result exceeds its size limit")
    stage_sha = digest_bytes(stage_bytes)
    verified = {"content": receipt, "sha256": receipt_sha}
    generation = identity["materializer_package"]["generation_id"]
    modules = execution / f"core/v2/generations/{generation}/modules"
    input_value = parse_json(read_bytes(input_path, MAX_INPUT_BYTES))
    validation_bundle = {
        "input": input_value,
        "response": response,
        "verified_receipt": verified,
        "receipt_utf8": receipt_utf8,
        "stage_result_sha256": stage_sha,
    }
    with tempfile.TemporaryDirectory(prefix="ystack-replay-validation-") as temporary:
        validation_path = Path(temporary) / "validation.json"
        atomic_bytes(validation_path, canonical_document(validation_bundle))
        command = [
            str(execution / ".dependencies/jq"), "-e", "-L", str(modules),
            "--arg", "command", "validate-response",
            "-f", str(execution / "adapters/local-git-materializer/v1/protocol.jq"),
            str(validation_path),
        ]
        checked = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                 env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"}, check=False)
    if checked.returncode != 0:
        raise ReplayError("materializer response does not match the frozen input")
    candidate = receipt.get("candidate")
    if not isinstance(candidate, dict):
        raise ReplayError("materializer response candidate is malformed")
    current = candidate_identity(arguments.candidate_root, identity["source_commit_id"])
    expected = {
        "candidate_commit_id": candidate.get("commit_id"),
        "candidate_tree_id": candidate.get("tree_id"),
        "candidate_parent_commit_id": candidate.get("parent_commit_id"),
    }
    if current != expected:
        raise ReplayError("candidate repository does not match the materializer response")
    changed = _capture_fixed_process(
        ["/usr/bin/git", f"--git-dir={Path(arguments.candidate_root).resolve() / 'repository.git'}",
         "diff-tree", "--no-commit-id", "--name-only", "-r",
         identity["source_commit_id"], expected["candidate_commit_id"]],
        GIT_ENVIRONMENT, MAX_GIT_PATH_BYTES
    )
    if changed.returncode != 0 or len(changed.stdout) > MAX_GIT_PATH_BYTES:
        raise ReplayError("candidate changed-path evidence is unavailable")
    paths = changed.stdout.splitlines()
    if paths != sorted(set(paths)) or any(not path for path in paths):
        raise ReplayError("candidate changed-path evidence is malformed")
    try:
        decoded_paths = [path.decode("utf-8", errors="strict") for path in paths]
    except UnicodeDecodeError as error:
        raise ReplayError("candidate changed-path evidence is malformed") from error
    if any(safe_path(path) != path for path in decoded_paths):
        raise ReplayError("candidate changed-path evidence is malformed")
    changed_framing = jq_canonical_document(execution, decoded_paths)
    if receipt.get("changed_paths") != {
        "count": len(paths), "sha256": digest_bytes(changed_framing)
    }:
        raise ReplayError("candidate changed paths do not match the materializer response")
    return ({
        "response_sha256": digest_bytes(response_bytes),
        "receipt_sha256": receipt_sha,
        "candidate_commit_id": expected["candidate_commit_id"],
        "candidate_tree_id": expected["candidate_tree_id"],
        "candidate_parent_commit_id": expected["candidate_parent_commit_id"],
    }, {
        "schema_version": 1, "status": "stored",
        "response_utf8": response_bytes.decode("utf-8"),
        "response_sha256": digest_bytes(response_bytes),
        "stage_result_sha256": stage_sha,
        "receipt_sha256": receipt_sha,
    }, stage_result, payload)


def candidate_identity(candidate_root, source_commit):
    repository = Path(candidate_root).resolve() / "repository.git"
    if not repository.is_dir() or repository.is_symlink():
        return None
    bare = subprocess.run(
        ["/usr/bin/git", f"--git-dir={repository}", "rev-parse", "--is-bare-repository"],
        env=GIT_ENVIRONMENT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False
    )
    if bare.returncode != 0 or bare.stdout != b"true\n":
        return None
    values = []
    for revision in ("refs/heads/candidate", "refs/heads/candidate^{tree}"):
        result = subprocess.run(["/usr/bin/git", f"--git-dir={repository}", "rev-parse", revision],
                                env=GIT_ENVIRONMENT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
        value = result.stdout.decode().strip()
        if result.returncode != 0 or not OID.fullmatch(value):
            return None
        values.append(value)
    if values[0] == source_commit:
        return {"candidate_commit_id": values[0], "candidate_tree_id": values[1],
                "candidate_parent_commit_id": source_commit}
    result = subprocess.run(["/usr/bin/git", f"--git-dir={repository}", "rev-parse", "refs/heads/candidate^"],
                            env=GIT_ENVIRONMENT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    parent = result.stdout.decode().strip()
    if result.returncode != 0 or not OID.fullmatch(parent):
        return None
    return {"candidate_commit_id": values[0], "candidate_tree_id": values[1],
            "candidate_parent_commit_id": parent}


def await_guard_prepared(process):
    # Ownership of the candidate ref comes from git's own transaction
    # acknowledgement, never from the lock file existing: a lock another process
    # holds fails our prepare, and git then closes stdout without "prepare: ok".
    deadline = time.monotonic() + GUARD_ACKNOWLEDGEMENT_SECONDS
    descriptor = process.stdout.fileno()
    pending = b""
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            process.kill()
            raise ReplayError("candidate repository identity guard timed out")
        readable, _, _ = select.select([descriptor], [], [], remaining)
        if not readable:
            process.kill()
            raise ReplayError("candidate repository identity guard timed out")
        chunk = os.read(descriptor, MAX_GUARD_LINE_BYTES)
        if not chunk:
            raise ReplayError("candidate repository identity guard failed")
        lines = (pending + chunk).split(b"\n")
        pending = lines.pop()
        if len(pending) > MAX_GUARD_LINE_BYTES:
            raise ReplayError("candidate repository identity guard failed")
        if b"prepare: ok" in lines:
            return


@contextmanager
def hold_candidate_ref(candidate_root, expected_commit):
    repository = Path(candidate_root).resolve() / "repository.git"
    lock_path = repository / "refs/heads/candidate.lock"
    command = ["/usr/bin/git", f"--git-dir={repository}", "-c", "core.hooksPath=/dev/null",
               "update-ref", "--stdin"]
    process = subprocess.Popen(command, env=GIT_ENVIRONMENT, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        process.stdin.write(
            f"option no-deref\nstart\nverify refs/heads/candidate {expected_commit}\nprepare\n".encode()
        )
        process.stdin.flush()
        await_guard_prepared(process)
        if lock_path.is_symlink() or not lock_path.is_file():
            raise ReplayError("candidate repository identity guard failed")
        symbolic = subprocess.run(
            ["/usr/bin/git", f"--git-dir={repository}", "symbolic-ref", "-q", "refs/heads/candidate"],
            env=GIT_ENVIRONMENT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False
        )
        if symbolic.returncode != 1:
            raise ReplayError("candidate repository identity guard failed")
        yield
    finally:
        if process.poll() is None:
            try:
                process.stdin.write(b"abort\n")
                process.stdin.flush()
            except (BrokenPipeError, OSError):
                pass
        if process.stdin is not None:
            process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=5)
        if process.stdout is not None:
            process.stdout.close()


def reconcile_materialization(arguments, execution, input_path, identity, state_dir):
    existing = candidate_identity(arguments.candidate_root, identity["source_commit_id"])
    if existing is None:
        return None
    # One fixed pair of staging directories, cleared on entry and on exit, so a
    # crash mid-reconcile can never accumulate materialized repositories.
    recovery_candidate = state_dir / "reconcile-candidate"
    recovery_scratch = state_dir / "reconcile-scratch"
    for stale in (recovery_candidate, recovery_scratch):
        if stale.is_symlink() or stale.exists():
            if stale.is_symlink() or not stale.is_dir():
                raise ReplayError("reconcile staging is unavailable")
            shutil.rmtree(stale)
    os.mkdir(recovery_candidate, 0o700)
    os.mkdir(recovery_scratch, 0o700)
    try:
        recomputed = run_materializer(arguments, execution, input_path, identity,
                                      recovery_candidate, recovery_scratch)
    finally:
        shutil.rmtree(recovery_candidate, ignore_errors=True)
        shutil.rmtree(recovery_scratch, ignore_errors=True)
    if existing != {
        "candidate_commit_id": recomputed["candidate_commit_id"],
        "candidate_tree_id": recomputed["candidate_tree_id"],
        "candidate_parent_commit_id": recomputed["candidate_parent_commit_id"],
    }:
        raise ReplayError("existing candidate does not match frozen materialization input")
    return recomputed


def verify_candidate(candidate_root, candidate_tree, path, expected):
    repository = Path(candidate_root).resolve() / "repository.git"
    if not repository.is_dir() or repository.is_symlink() or not OID.fullmatch(candidate_tree):
        raise ReplayError("candidate repository identity is unavailable")
    object_name = f"{candidate_tree}:{path}"
    size = subprocess.run(["/usr/bin/git", f"--git-dir={repository}", "cat-file", "-s", object_name],
                          env=GIT_ENVIRONMENT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    if size.returncode != 0 or not size.stdout.strip().isdigit() or int(size.stdout) > MAX_VERIFIED_BLOB_BYTES:
        raise ReplayError("fixed verifier cannot read the candidate blob")
    blob = subprocess.run(["/usr/bin/git", f"--git-dir={repository}", "cat-file", "blob", object_name],
                          env=GIT_ENVIRONMENT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    if blob.returncode != 0 or len(blob.stdout) != int(size.stdout):
        raise ReplayError("fixed verifier could not read the candidate blob")
    actual = digest_bytes(blob.stdout)
    if actual != expected:
        raise ReplayError("fixed verifier digest mismatch")
    return actual


def revalidate_candidate(arguments, state):
    expected = {
        name: state["materialization"][name]
        for name in ("candidate_commit_id", "candidate_tree_id", "candidate_parent_commit_id")
    }
    if candidate_identity(arguments.candidate_root, state["identity"]["source_commit_id"]) != expected:
        raise ReplayError("candidate repository no longer matches saved materialization")
    verify_candidate(arguments.candidate_root, expected["candidate_tree_id"],
                     state["identity"]["verifier"]["path"],
                     state["identity"]["verifier"]["expected_sha256"])


def observation(path, kind, identity, candidate_commit_id, field):
    if path is None:
        return None
    source = read_bytes(path, MAX_OBSERVATION_BYTES)
    value = parse_json(source)
    source_sha = digest_bytes(source)
    if not isinstance(value, dict) or value.get("schema_version") != 1 or value.get("kind") != kind:
        raise ReplayError("offline observation is malformed")
    if not isinstance(value.get("actor_id"), str) or not ACTOR.fullmatch(value["actor_id"]):
        raise ReplayError("offline observation actor is invalid")
    # Two candidate commits can carry one tree, so the commit binds the
    # observation to this exact candidate and the tree alone never does.
    if value.get("request_sha256") != identity["request_sha256"] or \
       value.get("candidate_tree_id") != identity["candidate_tree_id"] or \
       value.get("candidate_commit_id") != candidate_commit_id:
        raise ReplayError("offline observation does not match this candidate")
    return {"actor_id": value["actor_id"], field: value.get(field), "sha256": source_sha}


def validate_state(state, identity):
    if not isinstance(state, dict) or not integer(state.get("schema_version")) or \
       state["schema_version"] not in {1, 2} or \
       state.get("kind") != "delivery_replay_state" or state.get("authority") != "none" or \
       state.get("qualification") != "unavailable":
        raise ReplayError("state journal is malformed")
    saved = state.get("identity")
    if not isinstance(saved, dict) or any(
        not isinstance(saved.get(name), str) or not re.fullmatch(r"[0-9a-f]{64}", saved[name])
        for name in ("input_sha256", "request_sha256", "driver_sha256", "materializer_sha256",
                     "closure_helper_sha256", "jq_sha256", "run_key")
    ) or not isinstance(saved.get("source_repository_id"), str) or \
       not REPOSITORY_ID.fullmatch(saved["source_repository_id"]) or \
       not isinstance(saved.get("source_hash_algorithm"), str) or \
       saved["source_hash_algorithm"] not in {"sha1", "sha256"} or \
       any(not isinstance(saved.get(name), str) or not OID.fullmatch(saved[name])
           for name in ("source_commit_id", "source_tree_id")) or \
       not exact_object(saved.get("verifier"), ("id", "path", "expected_sha256")) or \
       not isinstance(saved["verifier"].get("id"), str) or \
       not isinstance(saved["verifier"].get("path"), str) or \
       not isinstance(saved["verifier"].get("expected_sha256"), str) or \
       not re.fullmatch(r"[0-9a-f]{64}", saved["verifier"]["expected_sha256"]):
        raise ReplayError("state journal identity is malformed")
    package = saved.get("materializer_package")
    if not isinstance(package, dict) or not isinstance(package.get("generation_id"), str) or \
       not re.fullmatch(r"g-[0-9a-f]{64}", package["generation_id"]) or \
       not isinstance(package.get("files"), dict) or \
       set(package["files"]) != set(package_paths(package["generation_id"])) or any(
           not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value)
           for value in package["files"].values()
       ) or not isinstance(package.get("sha256"), str) or \
       package["sha256"] != digest_bytes(canonical({
           "generation_id": package["generation_id"], "files": package["files"]
       })) or saved["materializer_sha256"] != package["files"][PACKAGE_FILES[0]]:
        raise ReplayError("state journal materializer package is malformed")
    phase = state.get("phase")
    if not isinstance(phase, str) or phase not in {
        "materializing", "verifying", "review-wait", "publish-wait", "completed-offline", "failed"
    }:
        raise ReplayError("state journal phase is malformed")
    version = state["schema_version"]
    receiver = None
    if version == 1:
        if "delivery_key" in saved or "receiver_result" in state:
            raise ReplayError("legacy state journal contains keyed result evidence")
    else:
        allowed_state = {
            "schema_version", "kind", "identity", "phase", "authority", "qualification",
            "receiver_result", "materialization", "verification", "review", "publisher",
            "recoverable", "reason", "recovery",
        }
        if set(state) - allowed_state or set(saved) - (set(identity) | {
            "candidate_commit_id", "candidate_tree_id", "delivery_key"
        }):
            raise ReplayError("state journal contains unknown keyed fields")
        validate_delivery_key(saved.get("delivery_key"))
        receiver = state.get("receiver_result")
        if not isinstance(receiver, dict) or not integer(receiver.get("schema_version")) or \
           receiver["schema_version"] != 1 or not isinstance(receiver.get("status"), str) or \
           receiver["status"] not in {"pending", "stored"}:
            raise ReplayError("state journal receiver result is malformed")
        if receiver["status"] == "pending":
            if receiver != {"schema_version": 1, "status": "pending"} or phase != "materializing":
                raise ReplayError("state journal pending result is malformed")
        elif not exact_object(receiver, (
            "schema_version", "status", "response_utf8", "response_sha256",
            "stage_result_sha256", "receipt_sha256"
        )) or phase == "materializing" or not isinstance(receiver["response_utf8"], str) or any(
            not isinstance(receiver.get(name), str) or not re.fullmatch(r"[0-9a-f]{64}", receiver[name])
            for name in ("response_sha256", "stage_result_sha256", "receipt_sha256")
        ):
            raise ReplayError("state journal stored result is malformed")
    stored_result = receiver is not None and receiver["status"] == "stored"
    if receiver is not None and receiver["status"] == "pending" and (
        set(state) != {
            "schema_version", "kind", "identity", "phase", "authority", "qualification",
            "receiver_result",
        } or set(saved) != (set(identity) | {"delivery_key"})
    ):
        raise ReplayError("state journal pending result is malformed")
    needs_materialization = phase in {
        "verifying", "review-wait", "publish-wait", "completed-offline"
    } or stored_result
    for name in ("candidate_commit_id", "candidate_tree_id"):
        if (needs_materialization and name not in saved) or (
            name in saved and (not isinstance(saved[name], str) or not OID.fullmatch(saved[name]))
        ):
            raise ReplayError("state journal candidate identity is malformed")
    materialization_present = "materialization" in state
    materialization = state.get("materialization")
    if materialization_present and (not exact_object(materialization, (
        "response_sha256", "receipt_sha256", "candidate_commit_id", "candidate_tree_id",
        "candidate_parent_commit_id"
    )) or any(
        not isinstance(materialization.get(name), str) or not OID.fullmatch(materialization[name])
        for name in ("candidate_commit_id", "candidate_tree_id", "candidate_parent_commit_id")
    ) or any(
        not isinstance(materialization.get(name), str) or not re.fullmatch(r"[0-9a-f]{64}", materialization[name])
        for name in ("response_sha256", "receipt_sha256")
    )):
        raise ReplayError("state journal materialization is malformed")
    if needs_materialization and not materialization_present:
        raise ReplayError("state journal materialization is malformed")
    if needs_materialization and any(
        saved[name] != materialization[name]
        for name in ("candidate_commit_id", "candidate_tree_id")
    ):
        raise ReplayError("state journal candidate identity does not match materialization")
    if stored_result and (
        materialization["response_sha256"] != receiver["response_sha256"] or
        materialization["receipt_sha256"] != receiver["receipt_sha256"]
    ):
        raise ReplayError("state journal stored result does not match materialization")
    verification_present = "verification" in state
    verification = state.get("verification")
    if verification_present and (
        not exact_object(verification, ("id", "path", "sha256")) or verification != {
            "id": saved["verifier"]["id"],
            "path": saved["verifier"]["path"],
            "sha256": saved["verifier"]["expected_sha256"],
        }
    ):
        raise ReplayError("state journal verification is malformed")
    if phase in {"review-wait", "publish-wait", "completed-offline"} and not verification_present:
        raise ReplayError("state journal verification is malformed")
    review_present = "review" in state
    review = state.get("review")
    if review_present and (not exact_object(review, ("actor_id", "verdict", "sha256")) or \
       not isinstance(review.get("actor_id"), str) or \
           not ACTOR.fullmatch(review["actor_id"]) or \
       review.get("verdict") != "clean" or not isinstance(review.get("sha256"), str) or \
       not re.fullmatch(r"[0-9a-f]{64}", review["sha256"])):
        raise ReplayError("state journal review is malformed")
    if phase in {"publish-wait", "completed-offline"} and not review_present:
        raise ReplayError("state journal review is malformed")
    publisher_present = "publisher" in state
    publisher = state.get("publisher")
    if publisher_present and (not exact_object(
        publisher, ("actor_id", "disposition", "sha256")
    ) or not isinstance(publisher.get("actor_id"), str) or \
           not ACTOR.fullmatch(publisher["actor_id"]) or \
       publisher.get("disposition") != "offline-simulated" or \
       not isinstance(publisher.get("sha256"), str) or \
       not re.fullmatch(r"[0-9a-f]{64}", publisher["sha256"])):
        raise ReplayError("state journal publisher is malformed")
    if phase == "completed-offline" and not publisher_present:
        raise ReplayError("state journal publisher is malformed")
    if "recoverable" in state and not isinstance(state["recoverable"], bool):
        raise ReplayError("state journal recovery flag is malformed")
    if "reason" in state and not isinstance(state["reason"], str):
        raise ReplayError("state journal failure reason is malformed")
    if "recovery" in state and not isinstance(state["recovery"], str):
        raise ReplayError("state journal recovery instruction is malformed")
    if phase == "failed" and not isinstance(state.get("reason"), str):
        raise ReplayError("state journal failure is malformed")


def read_journal(path):
    encoded = read_bytes(path, MAX_JOURNAL_V2_BYTES)
    value = parse_json(encoded)
    if not isinstance(value, dict):
        raise ReplayError("state journal is malformed")
    version = value.get("schema_version")
    if not integer(version) or version not in {1, 2}:
        raise ReplayError("state journal version is unsupported")
    if version == 1 and len(encoded) > MAX_OBSERVATION_BYTES:
        raise ReplayError("state journal exceeds its size limit")
    return value


def write_journal(path, state):
    limit = MAX_JOURNAL_V2_BYTES if state.get("schema_version") == 2 else MAX_OBSERVATION_BYTES
    atomic_json_limited(path, state, limit)


def root_empty(path):
    root = Path(path)
    if root.is_symlink() or not root.is_dir():
        return False
    try:
        return next(root.iterdir(), None) is None
    except OSError:
        return False


def result(state):
    print(json.dumps({"kind": "delivery_replay_receipt", "authority": "none",
                      "qualification": "unavailable", "offline_simulation": True,
                      "state": state}, sort_keys=True, separators=(",", ":")), flush=True)


def unavailable_materialization(reason):
    print(json.dumps({
        "schema_version": 1,
        "kind": "delivery_replay_materialization_result",
        "status": "unavailable",
        "reason_id": reason,
        "authority": "none",
        "qualification": "unavailable",
        "offline_simulation": True,
    }, sort_keys=True, separators=(",", ":")), flush=True)


def stored_materialization(state, stage_result, payload):
    print(json.dumps({
        "schema_version": 1,
        "kind": "delivery_replay_materialization_result",
        "status": "stored",
        "authority": "none",
        "qualification": "unavailable",
        "offline_simulation": True,
        "delivery_key": state["identity"]["delivery_key"],
        "run_key": state["identity"]["run_key"],
        "response_utf8": state["receiver_result"]["response_utf8"],
        "stage_result": {
            "content": stage_result,
            "sha256": state["receiver_result"]["stage_result_sha256"],
        },
        "receipt": payload,
    }, sort_keys=True, separators=(",", ":")), flush=True)


def validate_stored(arguments, execution, input_path, state):
    receiver = state["receiver_result"]
    try:
        response_bytes = receiver["response_utf8"].encode("utf-8", errors="strict")
    except UnicodeEncodeError as error:
        raise ReplayError("stored materializer response is not valid UTF-8") from error
    if digest_bytes(response_bytes) != receiver["response_sha256"]:
        raise ReplayError("stored materializer response digest changed")
    materialization, validated_receiver, stage_result, payload = validate_materializer_response(
        arguments, execution, input_path, state["identity"], response_bytes
    )
    if receiver != validated_receiver or state.get("materialization") != materialization or any(
        state["identity"].get(name) != materialization[name]
        for name in ("candidate_commit_id", "candidate_tree_id")
    ):
        raise ReplayError("stored materializer result does not match the journal")
    return stage_result, payload


def stop_if_interrupted(state, interrupted):
    if not interrupted["value"]:
        return False
    if state is not None:
        result(state)
    return True


def replay_locked(arguments, state_dir):
    repository = Path(__file__).resolve().parents[2]
    state_path = state_dir / "run.json"
    input_snapshot_path = state_dir / "materialization-input.json"
    lock_path = state_dir / "replay.lock"
    interrupted = {"value": False}
    previous_term = signal.getsignal(signal.SIGTERM)
    previous_int = signal.getsignal(signal.SIGINT)
    read_mode = getattr(arguments, "read_materialization_result", False)
    delivery_key_path = getattr(arguments, "delivery_key", None)
    signal.signal(signal.SIGTERM, lambda *_: interrupted.__setitem__("value", True))
    signal.signal(signal.SIGINT, lambda *_: interrupted.__setitem__("value", True))
    try:
        if read_mode and (
            arguments.review_observation is not None or arguments.publisher_observation is not None
        ):
            raise ReplayError("result read does not accept workflow observations")
        lock_flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
        if not read_mode:
            lock_flags |= os.O_CREAT
        lock_descriptor = os.open(lock_path, lock_flags, 0o600)
        if not stat.S_ISREG(os.fstat(lock_descriptor).st_mode):
            os.close(lock_descriptor)
            raise ReplayError("replay lock is not a regular file")
        with os.fdopen(lock_descriptor, "a+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            execution = state_dir / "execution" if read_mode else \
                create_execution_snapshot(repository, arguments, state_dir)
            if execution.is_symlink() or not execution.is_dir():
                raise ReplayError("execution bundle is unavailable")
            sources_match = execution_sources_match(repository, arguments, execution)
            if not REPOSITORY_ID.fullmatch(arguments.source_repository_id):
                raise ReplayError("source repository id is invalid")
            input_bytes = read_bytes(arguments.input, MAX_INPUT_BYTES)
            input_value = parse_json(input_bytes)
            input_sha = digest_bytes(input_bytes)
            supplied_key = None
            if delivery_key_path is not None:
                supplied_key = delivery_key(
                    parse_json(read_bytes(delivery_key_path, MAX_DELIVERY_KEY_BYTES)), input_value
                )
                validate_keyed_input(execution, Path(arguments.input), input_bytes, input_value)
            identity = input_identity(input_value, input_sha, arguments, execution, supplied_key)
            state = None
            if state_path.exists():
                state = read_journal(state_path)
                validate_state(state, identity)
                if (state["schema_version"] == 1 and supplied_key is not None) or \
                   (state["schema_version"] == 2 and supplied_key is None):
                    result({"phase": "stale", "reason": "journal format and delivery key conflict"})
                    return 2
            if state is not None and any(state["identity"].get(name) != value for name, value in identity.items()):
                result({"phase": "stale", "reason": "run identity changed"})
                return 2
            if not sources_match:
                if state is not None:
                    result({"phase": "stale", "reason": "execution dependencies changed"})
                    return 2
                raise ReplayError("execution bundle does not match current dependencies")
            if stop_if_interrupted(state, interrupted):
                return 75
            fresh_run = state is None
            if read_mode and fresh_run:
                raise ReplayError("state journal is unavailable")
            if fresh_run:
                version = 2 if supplied_key is not None else 1
                state = {"schema_version": version, "kind": "delivery_replay_state", "identity": identity,
                         "phase": "materializing", "authority": "none", "qualification": "unavailable"}
                if version == 2:
                    state["receiver_result"] = {"schema_version": 1, "status": "pending"}
                atomic_bytes(input_snapshot_path, input_bytes)
                write_journal(state_path, state)
            elif not input_snapshot_path.is_file() or input_snapshot_path.is_symlink() or (
                digest_bytes(read_bytes(input_snapshot_path, MAX_INPUT_BYTES)) != identity["input_sha256"]
            ):
                raise ReplayError("saved materialization input snapshot is unavailable")
            if read_mode:
                if state["schema_version"] == 1:
                    unavailable_materialization("replay.legacy-result-unavailable")
                    return 3
                if state["receiver_result"]["status"] == "pending":
                    unavailable_materialization("replay.materialization-result-missing")
                    return 3
                stage_result, payload = validate_stored(
                    arguments, execution, input_snapshot_path, state
                )
                stored_materialization(state, stage_result, payload)
                return 0
            if state["schema_version"] == 2 and state["receiver_result"]["status"] == "stored":
                validate_stored(arguments, execution, input_snapshot_path, state)
            if state["phase"] == "failed":
                if state.get("recoverable"):
                    state["recovery"] = "start a new replay with fresh empty candidate, scratch, and state directories"
                    write_journal(state_path, state)
                result(state)
                return 1
            if state["phase"] == "completed-offline":
                revalidate_candidate(arguments, state)
                if stop_if_interrupted(state, interrupted):
                    return 75
                for supplied, kind, field, recorded in (
                    (arguments.review_observation, "delivery_replay_review_observation", "verdict", state.get("review")),
                    (arguments.publisher_observation, "delivery_replay_publisher_observation", "disposition", state.get("publisher")),
                ):
                    if supplied is not None:
                        supplied_observation = observation(
                            supplied, kind, state["identity"],
                            state["materialization"]["candidate_commit_id"], field
                        )
                        if stop_if_interrupted(state, interrupted):
                            return 75
                        if supplied_observation != recorded:
                            raise ReplayError("supplied offline observation changed after completion")
                result(state)
                return 0
            if state["phase"] == "materializing":
                if state["schema_version"] == 2 and not fresh_run and (
                    not root_empty(arguments.candidate_root) or not root_empty(arguments.scratch_root)
                ):
                    unavailable_materialization("replay.materialization-result-missing")
                    return 3
                try:
                    # Only a resumed run may adopt a candidate that is already in
                    # the candidate root; a fresh run always goes through the
                    # materializer, whose root check refuses a pre-populated root.
                    if state["schema_version"] == 2:
                        response_bytes = capture_materializer(arguments, execution, input_snapshot_path)
                        materialization, receiver, _, _ = validate_materializer_response(
                            arguments, execution, input_snapshot_path, identity, response_bytes
                        )
                        state["materialization"] = materialization
                        state["receiver_result"] = receiver
                    else:
                        reconciled = None if fresh_run else reconcile_materialization(
                            arguments, execution, input_snapshot_path, identity, state_dir
                        )
                        state["materialization"] = reconciled or run_materializer(
                            arguments, execution, input_snapshot_path, identity
                        )
                except ReplayError as error:
                    if stop_if_interrupted(state, interrupted):
                        return 75
                    if state["schema_version"] == 2:
                        raise
                    state.update({"phase": "failed", "recoverable": True, "reason": str(error)})
                    write_journal(state_path, state)
                    result(state)
                    return 1
                state["identity"].update({
                    "candidate_commit_id": state["materialization"]["candidate_commit_id"],
                    "candidate_tree_id": state["materialization"]["candidate_tree_id"],
                })
                state["phase"] = "verifying"
                write_journal(state_path, state)
                if stop_if_interrupted(state, interrupted):
                    return 75
            if state["phase"] == "verifying":
                try:
                    state["verification"] = {"id": identity["verifier"]["id"], "path": identity["verifier"]["path"],
                                             "sha256": verify_candidate(arguments.candidate_root, state["identity"]["candidate_tree_id"],
                                                                        identity["verifier"]["path"], identity["verifier"]["expected_sha256"])}
                except ReplayError as error:
                    if stop_if_interrupted(state, interrupted):
                        return 75
                    state.update({"phase": "failed", "recoverable": False, "reason": str(error)})
                    write_journal(state_path, state)
                    result(state)
                    return 1
                state["phase"] = "review-wait"
                write_journal(state_path, state)
                if stop_if_interrupted(state, interrupted):
                    return 75
            if state["phase"] == "review-wait":
                revalidate_candidate(arguments, state)
                if stop_if_interrupted(state, interrupted):
                    return 75
                review = observation(arguments.review_observation, "delivery_replay_review_observation",
                                     state["identity"], state["materialization"]["candidate_commit_id"], "verdict")
                if stop_if_interrupted(state, interrupted):
                    return 75
                if review is None:
                    result(state)
                    return 0
                if review["verdict"] != "clean":
                    state.update({"phase": "failed", "recoverable": False, "reason": "offline review did not report clean"})
                    write_journal(state_path, state)
                    result(state)
                    return 1
                state["review"] = review
                state["phase"] = "publish-wait"
                write_journal(state_path, state)
            if state["phase"] == "publish-wait":
                with hold_candidate_ref(arguments.candidate_root,
                                        state["materialization"]["candidate_commit_id"]):
                    revalidate_candidate(arguments, state)
                    if stop_if_interrupted(state, interrupted):
                        return 75
                    if arguments.review_observation is not None:
                        supplied_review = observation(arguments.review_observation,
                                                      "delivery_replay_review_observation",
                                                      state["identity"],
                                                      state["materialization"]["candidate_commit_id"], "verdict")
                        if stop_if_interrupted(state, interrupted):
                            return 75
                        if supplied_review != state.get("review"):
                            raise ReplayError("supplied offline review changed after review wait")
                    publisher = observation(arguments.publisher_observation,
                                            "delivery_replay_publisher_observation",
                                            state["identity"],
                                            state["materialization"]["candidate_commit_id"], "disposition")
                    if stop_if_interrupted(state, interrupted):
                        return 75
                    if publisher is None:
                        result(state)
                        return 0
                    if publisher["disposition"] != "offline-simulated":
                        state.update({"phase": "failed", "recoverable": False, "reason": "offline publisher disposition is invalid"})
                        write_journal(state_path, state)
                        result(state)
                        return 1
                    state["publisher"] = publisher
                    state["phase"] = "completed-offline"
                    write_journal(state_path, state)
                    result(state)
                    return 0
            result(state)
            return 1
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        signal.signal(signal.SIGINT, previous_int)


def replay(arguments):
    state_dir = private_directory(arguments.state_dir)
    disjoint(state_dir, arguments.source_git_dir, arguments.candidate_root, arguments.scratch_root)
    return replay_locked(arguments, state_dir)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--source-repository-id", required=True)
    parser.add_argument("--source-git-dir", required=True)
    parser.add_argument("--candidate-root", required=True)
    parser.add_argument("--scratch-root", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--closure-helper", required=True)
    parser.add_argument("--jq-bin", required=True)
    parser.add_argument("--verify-path", required=True)
    parser.add_argument("--expected-sha256", required=True)
    parser.add_argument("--review-observation")
    parser.add_argument("--publisher-observation")
    parser.add_argument("--delivery-key")
    parser.add_argument("--read-materialization-result", action="store_true")
    try:
        return replay(parser.parse_args())
    except ReplayConflict as error:
        print(f"delivery replay: {error}", file=sys.stderr)
        return 2
    except (OSError, ReplayError) as error:
        print(f"delivery replay: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
