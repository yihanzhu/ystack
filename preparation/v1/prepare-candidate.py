#!/usr/bin/env python3
"""Prepare an exact, measured candidate tree from a materializer repository."""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import errno
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import selectors
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time
import unicodedata
from typing import Any, BinaryIO, Iterable, Iterator


LIMITS = {
    "input_bytes": 8 * 1024 * 1024,
    "response_bytes": 1 * 1024 * 1024,
    "receipt_bytes": 64 * 1024,
    "stage_result_bytes": 256 * 1024,
    "json_depth": 32,
    "storage_bytes": 256 * 1024 * 1024,
    "repository_file_bytes": 64 * 1024 * 1024,
    "reverse_index_bytes": 1 * 1024 * 1024,
    "reverse_index_objects": 65_536,
    "repository_entries": 65_536,
    "repository_name_bytes": 8 * 1024 * 1024,
    "config_bytes": 1 * 1024 * 1024,
    "head_ref_bytes": 4 * 1024,
    "commit_bytes": 1 * 1024 * 1024,
    "tree_bytes": 16 * 1024 * 1024,
    "tree_bytes_visited": 16 * 1024 * 1024,
    "tree_visits": 1_024,
    "tree_entries": 65_536,
    "file_paths": 4_096,
    "directories": 1_023,
    "export_path_bytes": 1 * 1024 * 1024,
    "blob_bytes": 8 * 1024 * 1024,
    "export_bytes": 64 * 1024 * 1024,
    "manifest_bytes": 2 * 1024 * 1024,
    "record_bytes": 16 * 1024,
    "dependency_bytes": 32 * 1024 * 1024,
    "scratch_bytes": 384 * 1024 * 1024,
    "bundle_bytes": 80 * 1024 * 1024,
    "child_diagnostic_bytes": 64 * 1024,
    "invocation_diagnostic_bytes": 256 * 1024,
    "result_bytes": 16 * 1024,
    "diagnostic_bytes": 4 * 1024,
    "operation_seconds": 300,
    "child_seconds": 120,
    "chunk_bytes": 64 * 1024,
}

ERRORS = {
    "E_USAGE", "E_IDENTITY", "E_EXISTS", "E_INPUT", "E_DEPENDENCY",
    "E_STORAGE", "E_OBJECT", "E_PATH", "E_LIMIT", "E_IO",
    "E_INCOMPLETE", "E_INTERRUPTED", "E_TIMEOUT",
}
HEX64 = set("0123456789abcdef")
COMPONENT_ID = "candidate-content-preparation.v1"
GIT = "/usr/bin/git"
SELECTED_GENERATION = "g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43"
DEPENDENCIES = {
    "adapters/local-git-materializer/v1/protocol.jq": "232517c19455667cca795769ffc0d8edad7873a9d55be0c21166de5b436bf323",
    "scripts/core-contract.sh": "b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9",
    "core/v2/generation-registry.json": "3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94",
    f"core/v2/generations/{SELECTED_GENERATION}/core-ingress.sh": "dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8",
    f"core/v2/generations/{SELECTED_GENERATION}/contracts.jq": "65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a",
    f"core/v2/generations/{SELECTED_GENERATION}/modules/schema.jq": "8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade",
    f"core/v2/generations/{SELECTED_GENERATION}/modules/profile_graph.jq": "c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207",
    f"core/v2/generations/{SELECTED_GENERATION}/modules/stage_request.jq": "6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e",
    f"core/v2/generations/{SELECTED_GENERATION}/modules/result_facts.jq": "8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281",
    f"core/v2/generations/{SELECTED_GENERATION}/modules/result_truth.jq": "ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46",
}


class Refusal(Exception):
    def __init__(self, token: str, exit_code: int = 1):
        if token not in ERRORS:
            token = "E_IO"
        self.token = token
        self.exit_code = exit_code
        super().__init__(token)


@dataclasses.dataclass(frozen=True)
class FileFact:
    path: str
    mode: int
    size: int
    sha256: str
    dev: int
    ino: int
    uid: int
    nlink: int
    mtime_ns: int
    ctime_ns: int


@dataclasses.dataclass
class Ledger:
    input_bytes: int = 0
    object_bytes: int = 0
    scratch_bytes: int = 0
    bundle_bytes: int = 0
    child_output_bytes: int = 0
    diagnostic_bytes: int = 0
    high_water_chunk: int = 0

    def charge(self, field: str, amount: int, maximum: int) -> None:
        if amount < 0:
            raise Refusal("E_LIMIT")
        value = getattr(self, field) + amount
        if value > maximum:
            raise Refusal("E_LIMIT")
        setattr(self, field, value)


@dataclasses.dataclass
class Context:
    args: argparse.Namespace
    repo_root: Path
    scratch: Path
    copied_repo: Path
    sidecars: Path
    deps_root: Path
    ledger: Ledger
    deadline: float
    source_observation: list[dict[str, Any]] = dataclasses.field(default_factory=list)
    source_facts: dict[str, FileFact] = dataclasses.field(default_factory=dict)
    identities: dict[str, Any] = dataclasses.field(default_factory=dict)
    algorithm: str = ""
    oid_bytes: int = 0

    def remaining(self, child: bool = False) -> float:
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise Refusal("E_TIMEOUT", 75)
        return min(left, LIMITS["child_seconds"]) if child else left


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha_file(path: Path, maximum: int | None = None) -> tuple[str, int]:
    digest = hashlib.sha256()
    total = 0
    try:
        with path.open("rb", buffering=0) as stream:
            while True:
                block = stream.read(LIMITS["chunk_bytes"])
                if not block:
                    break
                total += len(block)
                if maximum is not None and total > maximum:
                    raise Refusal("E_LIMIT")
                digest.update(block)
    except Refusal:
        raise
    except OSError as exc:
        raise Refusal("E_IO") from exc
    return digest.hexdigest(), total


def canonical(value: Any) -> bytes:
    try:
        encoded = json.dumps(value, ensure_ascii=False, sort_keys=True,
                             separators=(",", ":"), allow_nan=False).encode("utf-8") + b"\n"
    except (TypeError, ValueError, UnicodeError) as exc:
        raise Refusal("E_INPUT") from exc
    return encoded


def reject_constant(value: str) -> None:
    raise ValueError(value)


def unique_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate")
        result[key] = value
    return result


def json_depth(value: Any, depth: int = 1) -> int:
    if depth > LIMITS["json_depth"]:
        raise Refusal("E_INPUT")
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise Refusal("E_INPUT")
            json_depth(item, depth + 1)
    elif isinstance(value, list):
        for item in value:
            json_depth(item, depth + 1)
    elif isinstance(value, float) and not math.isfinite(value):
        raise Refusal("E_INPUT")
    return depth


def strict_json(data: bytes, token: str = "E_INPUT") -> Any:
    try:
        if data.startswith(b"\xef\xbb\xbf"):
            raise ValueError("bom")
        text = data.decode("utf-8", "strict")
        if any(0xD800 <= ord(ch) <= 0xDFFF for ch in text):
            raise ValueError("surrogate")
        decoder = json.JSONDecoder(object_pairs_hook=unique_pairs,
                                   parse_constant=reject_constant)
        value, end = decoder.raw_decode(text)
        if text[end:].strip():
            raise ValueError("trailing")
        json_depth(value)
        return value
    except Refusal:
        raise
    except (UnicodeError, ValueError, json.JSONDecodeError) as exc:
        raise Refusal(token) from exc


def exact_keys(value: Any, keys: set[str], token: str = "E_INPUT") -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise Refusal(token)
    return value


def valid_sha(value: Any) -> bool:
    return isinstance(value, str) and len(value) == 64 and set(value) <= HEX64


def read_limited(path: Path, maximum: int, expected_sha: str | None = None) -> bytes:
    try:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        if not getattr(os, "O_NOFOLLOW", 0):
            raise Refusal("E_DEPENDENCY")
        fd = os.open(path, flags)
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_size > maximum:
                raise Refusal("E_INPUT")
            chunks = []
            total = 0
            while True:
                chunk = os.read(fd, min(LIMITS["chunk_bytes"], maximum + 1 - total))
                if not chunk:
                    break
                total += len(chunk)
                if total > maximum:
                    raise Refusal("E_LIMIT")
                chunks.append(chunk)
            data = b"".join(chunks)
            if expected_sha is not None and sha256(data) != expected_sha:
                raise Refusal("E_IDENTITY", 2)
            return data
        finally:
            os.close(fd)
    except Refusal:
        raise
    except OSError as exc:
        raise Refusal("E_IO") from exc


def physical_absolute(value: str) -> Path:
    if not value.startswith("/") or "//" in value or any(part in ("", ".", "..") for part in value.split("/")[1:]):
        raise Refusal("E_USAGE", 2)
    path = Path(value)
    current = Path("/")
    try:
        for part in path.parts[1:]:
            current /= part
            st = os.lstat(current)
            if stat.S_ISLNK(st.st_mode):
                raise Refusal("E_USAGE", 2)
    except FileNotFoundError:
        parent = path.parent
        if not parent.exists() or path != Path(value):
            raise Refusal("E_USAGE", 2)
    except Refusal:
        raise
    except OSError as exc:
        raise Refusal("E_USAGE", 2) from exc
    return path


def require_private_dir(path: Path, *, exists: bool = True) -> os.stat_result | None:
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        if exists:
            raise Refusal("E_IDENTITY", 2)
        return None
    if not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_uid != os.geteuid():
        raise Refusal("E_IDENTITY", 2)
    if stat.S_IMODE(st.st_mode) & 0o077:
        raise Refusal("E_IDENTITY", 2)
    return st


def paths_overlap(paths: list[Path]) -> None:
    normalized = [str(path) for path in paths]
    for index, left in enumerate(normalized):
        for right in normalized[index + 1:]:
            if left == right or left.startswith(right + "/") or right.startswith(left + "/"):
                raise Refusal("E_IDENTITY", 2)


def run_child(ctx: Context, argv: list[str], *, stdin: bytes | None = None,
              output_limit: int = LIMITS["invocation_diagnostic_bytes"],
              env: dict[str, str] | None = None, pass_fds: tuple[int, ...] = ()) -> bytes:
    try:
        process = subprocess.Popen(argv, stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                                   close_fds=True, pass_fds=pass_fds)
    except OSError as exc:
        raise Refusal("E_DEPENDENCY") from exc
    if stdin is not None:
        assert process.stdin is not None
        try:
            process.stdin.write(stdin)
            process.stdin.close()
        except BrokenPipeError:
            pass
    selector = selectors.DefaultSelector()
    assert process.stdout is not None and process.stderr is not None
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    out = bytearray()
    err = bytearray()
    child_deadline = time.monotonic() + ctx.remaining(child=True)
    try:
        while selector.get_map():
            remaining = min(child_deadline, ctx.deadline) - time.monotonic()
            if remaining <= 0:
                process.terminate()
                try:
                    process.wait(2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                raise Refusal("E_TIMEOUT", 75)
            for key, _ in selector.select(min(remaining, 0.25)):
                chunk = os.read(key.fileobj.fileno(), LIMITS["chunk_bytes"])
                ctx.ledger.high_water_chunk = max(ctx.ledger.high_water_chunk, len(chunk))
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                target = out if key.data == "stdout" else err
                if len(target) + len(chunk) > output_limit:
                    process.kill()
                    process.wait()
                    raise Refusal("E_LIMIT")
                target.extend(chunk)
                ctx.ledger.charge("child_output_bytes", len(chunk), LIMITS["invocation_diagnostic_bytes"])
        status = process.wait(timeout=max(0.1, min(child_deadline, ctx.deadline) - time.monotonic()))
    except Refusal:
        raise
    except (OSError, subprocess.TimeoutExpired) as exc:
        with contextlib.suppress(Exception):
            process.kill()
            process.wait()
        raise Refusal("E_IO") from exc
    finally:
        selector.close()
    if status != 0:
        raise Refusal("E_DEPENDENCY")
    return bytes(out)


def clean_git_env(ctx: Context) -> dict[str, str]:
    home = ctx.scratch / "home"
    tmp = ctx.scratch / "tmp"
    hooks = ctx.scratch / "hooks"
    for directory in (home, tmp, hooks):
        directory.mkdir(mode=0o700, exist_ok=True)
    return {
        "HOME": str(home), "TMPDIR": str(tmp), "PATH": "/usr/bin:/bin", "LC_ALL": "C",
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_NO_REPLACE_OBJECTS": "1", "GIT_NO_LAZY_FETCH": "1",
        "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0",
        "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath",
        "GIT_CONFIG_VALUE_0": str(hooks),
    }


def git(ctx: Context, *args: str, limit: int = LIMITS["invocation_diagnostic_bytes"]) -> bytes:
    return run_child(ctx, [GIT, "--no-replace-objects", "--git-dir", str(ctx.copied_repo), *args],
                     output_limit=limit, env=clean_git_env(ctx))


def copy_dependencies(ctx: Context) -> tuple[Path, Path]:
    total = 0
    files = []
    for relative, expected in DEPENDENCIES.items():
        source = ctx.repo_root / relative
        before, size = sha_file(source, LIMITS["dependency_bytes"])
        if before != expected:
            raise Refusal("E_DEPENDENCY")
        destination = ctx.deps_root / relative
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        data = read_limited(source, LIMITS["dependency_bytes"])
        total += len(data)
        if total > LIMITS["dependency_bytes"]:
            raise Refusal("E_LIMIT")
        write_exclusive(destination, data, 0o500 if relative.endswith(".sh") else 0o400)
        copied, copied_size = sha_file(destination)
        after, after_size = sha_file(source)
        if copied != expected or before != after or size != copied_size or size != after_size:
            raise Refusal("E_DEPENDENCY")
        files.append({"path": relative, "sha256": expected})
    jq_data = read_limited(Path(ctx.args.jq), LIMITS["dependency_bytes"])
    total += len(jq_data)
    if total > LIMITS["dependency_bytes"]:
        raise Refusal("E_LIMIT")
    jq_copy = ctx.deps_root / "tools" / "jq"
    jq_copy.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    write_exclusive(jq_copy, jq_data, 0o500)
    jq_version = run_child(ctx, [str(jq_copy), "--version"], output_limit=128).decode("ascii", "strict").strip()
    if jq_version != "jq-1.6":
        raise Refusal("E_DEPENDENCY")
    registry = strict_json(read_limited(ctx.deps_root / "core/v2/generation-registry.json",
                                       LIMITS["dependency_bytes"]), "E_DEPENDENCY")
    matches = [entry for entry in registry if isinstance(entry, dict) and
               entry.get("generation_id") == SELECTED_GENERATION and
               entry.get("semantic_identity") == "core.contracts.v2"] if isinstance(registry, list) else []
    if len(matches) != 1:
        raise Refusal("E_DEPENDENCY")
    ctx.ledger.charge("scratch_bytes", total, LIMITS["scratch_bytes"])
    ctx.identities["jq"] = {"executable_sha256": sha256(jq_data), "version": jq_version}
    ctx.identities["core"] = {"generation_id": SELECTED_GENERATION,
                               "files": sorted(files, key=lambda item: item["path"].encode())}
    return jq_copy, ctx.deps_root / "adapters/local-git-materializer/v1/protocol.jq"


def extract_response(input_value: dict[str, Any], response: dict[str, Any]) -> dict[str, Any]:
    exact_keys(response, {"schema_version", "kind", "stage_result", "payloads",
                          "authority", "qualification", "effects"})
    payloads = response.get("payloads")
    if not isinstance(payloads, list) or len(payloads) != 1:
        raise Refusal("E_INPUT")
    payload = exact_keys(payloads[0], {"content_id", "media_type", "sha256", "data"})
    receipt_text = payload.get("data")
    if not isinstance(receipt_text, str):
        raise Refusal("E_INPUT")
    receipt_bytes = receipt_text.encode("utf-8")
    if len(receipt_bytes) > LIMITS["receipt_bytes"] or not valid_sha(payload.get("sha256")) or \
            sha256(receipt_bytes) != payload["sha256"]:
        raise Refusal("E_INPUT")
    receipt = strict_json(receipt_bytes)
    stage = response.get("stage_result")
    stage_bytes = canonical(stage)
    if len(stage_bytes) > LIMITS["stage_result_bytes"]:
        raise Refusal("E_LIMIT")
    verified = {"content": receipt, "sha256": payload["sha256"]}
    return {"receipt": receipt, "receipt_utf8": receipt_text, "verified_receipt": verified,
            "stage_result_sha256": sha256(stage_bytes), "stage_result_bytes": stage_bytes}


def validate_documents(ctx: Context, input_data: bytes, response_data: bytes,
                       jq_copy: Path, protocol: Path) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    input_value = strict_json(input_data)
    response = strict_json(response_data)
    if canonical(input_value) != input_data:
        raise Refusal("E_INPUT")
    details = extract_response(input_value, response)
    bundle = {"input": input_value, "response": response,
              "verified_receipt": details["verified_receipt"],
              "receipt_utf8": details["receipt_utf8"],
              "stage_result_sha256": details["stage_result_sha256"]}
    command = [str(jq_copy), "-e", "-L", str(protocol.parent), "--arg", "command",
               "validate-response", "-f", str(protocol)]
    if run_child(ctx, command, stdin=canonical(bundle), output_limit=64).strip() != b"true":
        raise Refusal("E_INPUT")
    run_core_validations(ctx, input_value, response, details)
    return input_value, response, details


def write_temp_json(root: Path, name: str, value: Any) -> Path:
    path = root / name
    write_exclusive(path, canonical(value), 0o400)
    return path


def run_core_validations(ctx: Context, input_value: dict[str, Any], response: dict[str, Any],
                         details: dict[str, Any]) -> None:
    validation = ctx.scratch / "validation"
    validation.mkdir(mode=0o700)
    selector = ctx.deps_root / "scripts/core-contract.sh"
    documents: list[Path] = []
    for name, pair in (("profile", input_value["profile"]),
                       ("resolved", input_value["resolved_profile"]),
                       ("request", input_value["stage_request"])):
        path = write_temp_json(validation, f"{name}.json", pair["content"])
        documents.append(path)
    manifests = []
    for index, pair in enumerate(input_value["manifests"]):
        manifests.append(write_temp_json(validation, f"manifest-{index}.json", pair["content"]))
    stage = write_temp_json(validation, "stage-result.json", response["stage_result"])
    pairs = [(documents[0], "profile"), (documents[1], "resolved-profile"),
             (documents[2], "stage-request"), (stage, "stage-result")]
    pairs.extend((path, "adapter-manifest") for path in manifests)
    for path, _kind in pairs:
        run_accounted_core(ctx, selector, ["validate-document", str(path)])
    run_accounted_core(ctx, selector, ["validate-profile-set", str(documents[0]),
                                      str(documents[1]), *map(str, manifests)])
    run_accounted_core(ctx, selector, ["validate-stage-run", str(documents[2]),
                                      str(documents[1]), str(stage)])


def run_accounted_core(ctx: Context, selector: Path, args: list[str]) -> None:
    receipt_r, receipt_w = os.pipe()
    scratch = ctx.scratch / f"core-{time.monotonic_ns()}"
    scratch.mkdir(mode=0o700)
    reserved = 8 * 1024 * 1024
    ctx.ledger.charge("scratch_bytes", reserved, LIMITS["scratch_bytes"])
    env = clean_git_env(ctx)
    command = [str(selector), "--accounted-validation", str(scratch), str(reserved), *args]
    try:
        completed = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, env=env, close_fds=True,
                                     pass_fds=(receipt_w,), preexec_fn=lambda: os.dup2(receipt_w, 3))
        os.close(receipt_w)
        stdout, stderr = completed.communicate(timeout=ctx.remaining(child=True))
        receipt = os.read(receipt_r, 128)
    except (OSError, subprocess.TimeoutExpired) as exc:
        with contextlib.suppress(Exception):
            completed.kill()
            completed.wait()
        raise Refusal("E_DEPENDENCY") from exc
    finally:
        with contextlib.suppress(OSError):
            os.close(receipt_r)
        with contextlib.suppress(OSError):
            os.close(receipt_w)
    if completed.returncode != 0 or stdout or len(stderr) > LIMITS["child_diagnostic_bytes"]:
        raise Refusal("E_DEPENDENCY")
    if not receipt.startswith(b"written-bytes:") or not receipt.endswith(b"\n"):
        raise Refusal("E_DEPENDENCY")
    try:
        written = int(receipt[14:-1])
    except ValueError as exc:
        raise Refusal("E_DEPENDENCY") from exc
    if written < 0 or written > reserved:
        raise Refusal("E_DEPENDENCY")


def file_fact(path: Path, relative: str, maximum: int) -> FileFact:
    try:
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_uid != os.geteuid() or st.st_nlink != 1:
            raise Refusal("E_STORAGE")
        digest, size = sha_file(path, maximum)
        after = os.lstat(path)
        identity = (st.st_dev, st.st_ino, stat.S_IFMT(st.st_mode), st.st_uid, st.st_nlink,
                    st.st_size, st.st_mtime_ns, st.st_ctime_ns)
        identity_after = (after.st_dev, after.st_ino, stat.S_IFMT(after.st_mode), after.st_uid,
                          after.st_nlink, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
        if identity != identity_after:
            raise Refusal("E_STORAGE")
        return FileFact(relative, stat.S_IMODE(st.st_mode), size, digest, st.st_dev, st.st_ino,
                        st.st_uid, st.st_nlink, st.st_mtime_ns, st.st_ctime_ns)
    except Refusal:
        raise
    except OSError as exc:
        raise Refusal("E_STORAGE") from exc


def allowed_storage_path(relative: str, algorithm: str) -> tuple[bool, bool]:
    exact = {"HEAD", "config", "refs/heads/candidate"}
    directories = {"objects", "objects/info", "objects/pack", "refs", "refs/heads", "refs/tags"}
    if relative in exact or relative in directories:
        return True, False
    parts = relative.split("/")
    oid_len = 40 if algorithm == "sha1" else 64
    if len(parts) == 3 and parts[0] == "objects" and len(parts[1]) == 2 and len(parts[2]) == oid_len - 2 and \
            all(ch in HEX64 for ch in parts[1] + parts[2]):
        return True, False
    if len(parts) == 3 and parts[:2] == ["objects", "pack"]:
        name = parts[2]
        if name.startswith("pack-") and len(name) == 5 + oid_len + 4 and name[-4:] in (".pack", ".idx", ".rev") and \
                all(ch in HEX64 for ch in name[5:-4]):
            return True, name.endswith(".rev")
    return False, False


def enumerate_storage(ctx: Context) -> tuple[dict[str, FileFact], list[dict[str, Any]]]:
    repository = Path(ctx.args.candidate_repository)
    root_st = require_private_dir(repository)
    assert root_st is not None
    facts: dict[str, FileFact] = {}
    observation: list[dict[str, Any]] = []
    entry_count = 0
    name_bytes = 0
    storage_bytes = 0
    seen_inodes: set[tuple[int, int]] = set()
    try:
        for current, dirs, files in os.walk(repository, topdown=True, followlinks=False):
            dirs.sort(key=os.fsencode)
            files.sort(key=os.fsencode)
            relative_dir = os.path.relpath(current, repository)
            relative_dir = "" if relative_dir == "." else relative_dir
            current_st = os.lstat(current)
            if not stat.S_ISDIR(current_st.st_mode) or stat.S_ISLNK(current_st.st_mode) or \
                    current_st.st_uid != os.geteuid() or current_st.st_dev != root_st.st_dev:
                raise Refusal("E_STORAGE")
            if relative_dir:
                allowed, _ = allowed_storage_path(relative_dir, ctx.algorithm)
                if not allowed:
                    raise Refusal("E_STORAGE")
                observation.append({"path": relative_dir, "type": "directory",
                                    "mode": f"{stat.S_IMODE(current_st.st_mode):04o}"})
                entry_count += 1
                name_bytes += len(relative_dir.encode("utf-8"))
            for name in files:
                relative = f"{relative_dir}/{name}" if relative_dir else name
                allowed, reverse = allowed_storage_path(relative, ctx.algorithm)
                if not allowed:
                    raise Refusal("E_STORAGE")
                maximum = LIMITS["reverse_index_bytes"] if reverse else LIMITS["repository_file_bytes"]
                fact = file_fact(Path(current) / name, relative, maximum)
                if fact.dev != root_st.st_dev or (fact.dev, fact.ino) in seen_inodes:
                    raise Refusal("E_STORAGE")
                seen_inodes.add((fact.dev, fact.ino))
                facts[relative] = fact
                observation.append({"path": relative, "type": "file", "mode": f"{fact.mode:04o}",
                                    "size_bytes": fact.size, "sha256": fact.sha256})
                entry_count += 1
                name_bytes += len(relative.encode("utf-8"))
                storage_bytes += fact.size
                if entry_count > LIMITS["repository_entries"] or name_bytes > LIMITS["repository_name_bytes"] or \
                        storage_bytes > LIMITS["storage_bytes"]:
                    raise Refusal("E_LIMIT")
    except UnicodeError as exc:
        raise Refusal("E_STORAGE") from exc
    required = {"HEAD", "config", "refs/heads/candidate"}
    if not required <= facts.keys():
        raise Refusal("E_STORAGE")
    observation.sort(key=lambda item: item["path"].encode("utf-8"))
    return facts, observation


def copy_storage(ctx: Context) -> None:
    source = Path(ctx.args.candidate_repository)
    ctx.copied_repo.mkdir(mode=0o700, parents=True)
    ctx.sidecars.mkdir(mode=0o700, parents=True)
    for relative, fact in ctx.source_facts.items():
        source_path = source / relative
        if relative.endswith(".rev"):
            destination = ctx.sidecars / Path(relative).name
        elif relative.startswith("objects/") and relative not in ("objects/info", "objects/pack"):
            destination = ctx.copied_repo / relative
        elif relative.endswith((".pack", ".idx")):
            destination = ctx.copied_repo / relative
        else:
            continue
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        data = read_limited(source_path, LIMITS["repository_file_bytes"])
        if sha256(data) != fact.sha256:
            raise Refusal("E_STORAGE")
        write_exclusive(destination, data, 0o400)
        ctx.ledger.charge("scratch_bytes", len(data), LIMITS["scratch_bytes"])
    validate_pack_sets(ctx)
    config_data = read_limited(source / "config", LIMITS["config_bytes"])
    validate_config(ctx, config_data)
    candidate_ref = read_limited(source / "refs/heads/candidate", LIMITS["head_ref_bytes"])
    expected = ctx.identities["candidate_commit_id"].encode() + b"\n"
    if candidate_ref != expected:
        raise Refusal("E_STORAGE")
    head = read_limited(source / "HEAD", LIMITS["head_ref_bytes"])
    if not head.startswith(b"ref: refs/heads/") or not head.endswith(b"\n") or b"\n" in head[:-1]:
        raise Refusal("E_STORAGE")
    config = b"[core]\n\trepositoryformatversion = " + (b"1" if ctx.algorithm == "sha256" else b"0") + \
             b"\n\tfilemode = true\n\tbare = true\n\tlogallrefupdates = false\n"
    if ctx.algorithm == "sha256":
        config += b"[extensions]\n\tobjectformat = sha256\n"
    write_exclusive(ctx.copied_repo / "config", config, 0o400)
    write_exclusive(ctx.copied_repo / "HEAD", b"ref: refs/heads/candidate\n", 0o400)
    ref = ctx.copied_repo / "refs/heads/candidate"
    ref.parent.mkdir(mode=0o700, parents=True)
    write_exclusive(ref, expected, 0o400)


def validate_config(ctx: Context, data: bytes) -> None:
    temp = ctx.scratch / "candidate-config"
    write_exclusive(temp, data, 0o400)
    output = run_child(ctx, [GIT, "config", "--file", str(temp), "--no-includes", "--null", "--list"],
                       output_limit=LIMITS["config_bytes"], env=clean_git_env(ctx))
    allowed = {"core.repositoryformatversion", "core.filemode", "core.bare", "core.logallrefupdates",
               "core.ignorecase", "core.precomposeunicode", "extensions.objectformat"}
    seen: set[str] = set()
    for record in output.rstrip(b"\0").split(b"\0") if output else []:
        try:
            key_raw, value_raw = record.split(b"\n", 1)
            key = key_raw.decode("ascii").lower()
            value = value_raw.decode("ascii").lower()
        except (ValueError, UnicodeError) as exc:
            raise Refusal("E_STORAGE") from exc
        if key not in allowed or key in seen:
            raise Refusal("E_STORAGE")
        seen.add(key)
        if key == "core.bare" and value != "true":
            raise Refusal("E_STORAGE")
        if key == "extensions.objectformat" and value != ctx.algorithm:
            raise Refusal("E_STORAGE")
    if "core.bare" not in seen or (ctx.algorithm == "sha256") != ("extensions.objectformat" in seen):
        raise Refusal("E_STORAGE")


def validate_pack_sets(ctx: Context) -> None:
    packs: dict[str, set[str]] = {}
    for relative in ctx.source_facts:
        if relative.startswith("objects/pack/pack-"):
            stem, suffix = relative.rsplit(".", 1)
            packs.setdefault(stem, set()).add(suffix)
    for stem, suffixes in packs.items():
        if not {"pack", "idx"} <= suffixes or suffixes - {"pack", "idx", "rev"}:
            raise Refusal("E_STORAGE")
        if "rev" in suffixes:
            validate_reverse_index(ctx, Path(stem).name)


def validate_reverse_index(ctx: Context, basename: str) -> None:
    """Validate observation-only RIDX v1 before Git can read the copied pack."""
    hash_len = ctx.oid_bytes
    hash_id = 1 if ctx.algorithm == "sha1" else 2
    pack = read_limited(ctx.copied_repo / f"objects/pack/{basename}.pack",
                        LIMITS["repository_file_bytes"])
    index = read_limited(ctx.copied_repo / f"objects/pack/{basename}.idx",
                         LIMITS["repository_file_bytes"])
    reverse = read_limited(ctx.sidecars / f"{basename}.rev", LIMITS["reverse_index_bytes"])
    if len(pack) < 12 + hash_len or pack[:4] != b"PACK" or struct.unpack(">I", pack[4:8])[0] not in (2, 3):
        raise Refusal("E_STORAGE")
    count = struct.unpack(">I", pack[8:12])[0]
    if count > LIMITS["reverse_index_objects"] or pack[-hash_len:] != hashlib.new(ctx.algorithm, pack[:-hash_len]).digest():
        raise Refusal("E_STORAGE")
    basename_hash = basename[5:]
    if pack[-hash_len:].hex() != basename_hash:
        raise Refusal("E_STORAGE")
    offsets, index_pack_hash = parse_pack_index(ctx, index, count)
    if index_pack_hash != pack[-hash_len:]:
        raise Refusal("E_STORAGE")
    expected_length = 12 + 4 * count + 2 * hash_len
    if len(reverse) != expected_length or reverse[:4] != b"RIDX":
        raise Refusal("E_STORAGE")
    version, observed_hash_id = struct.unpack(">II", reverse[4:12])
    if version != 1 or observed_hash_id != hash_id:
        raise Refusal("E_STORAGE")
    positions = list(struct.unpack(f">{count}I", reverse[12:12 + 4 * count])) if count else []
    if sorted(positions) != list(range(count)):
        raise Refusal("E_STORAGE")
    if any(offsets[position] >= offsets[positions[index + 1]]
           for index, position in enumerate(positions[:-1])):
        raise Refusal("E_STORAGE")
    if any(offset < 12 or offset >= len(pack) - hash_len for offset in offsets):
        raise Refusal("E_STORAGE")
    pack_checksum = reverse[12 + 4 * count:12 + 4 * count + hash_len]
    reverse_checksum = reverse[-hash_len:]
    if pack_checksum != pack[-hash_len:] or reverse_checksum != hashlib.new(
            ctx.algorithm, reverse[:-hash_len]).digest():
        raise Refusal("E_STORAGE")


def parse_pack_index(ctx: Context, data: bytes, expected_count: int) -> tuple[list[int], bytes]:
    hash_len = ctx.oid_bytes
    if len(data) < 8 + 256 * 4 + 2 * hash_len or data[:4] != b"\xfftOc" or data[4:8] != b"\x00\x00\x00\x02":
        raise Refusal("E_STORAGE")
    fanout = struct.unpack(">256I", data[8:8 + 1024])
    if any(left > right for left, right in zip(fanout, fanout[1:])) or fanout[-1] != expected_count:
        raise Refusal("E_STORAGE")
    count = fanout[-1]
    names_start = 8 + 1024
    crc_start = names_start + count * hash_len
    offsets_start = crc_start + count * 4
    if offsets_start + count * 4 + 2 * hash_len > len(data):
        raise Refusal("E_STORAGE")
    ordinary = struct.unpack(f">{count}I", data[offsets_start:offsets_start + count * 4]) if count else ()
    large_count = sum(1 for offset in ordinary if offset & 0x80000000)
    checksum_start = offsets_start + count * 4 + large_count * 8
    if len(data) != checksum_start + 2 * hash_len:
        raise Refusal("E_STORAGE")
    large = struct.unpack(f">{large_count}Q", data[offsets_start + count * 4:checksum_start]) if large_count else ()
    offsets = []
    for value in ordinary:
        if value & 0x80000000:
            index = value & 0x7fffffff
            if index >= large_count:
                raise Refusal("E_STORAGE")
            offsets.append(large[index])
        else:
            offsets.append(value)
    if data[-hash_len:] != hashlib.new(ctx.algorithm, data[:-hash_len]).digest():
        raise Refusal("E_STORAGE")
    return offsets, data[checksum_start:checksum_start + hash_len]


def git_object(ctx: Context, oid: str, expected_type: str, maximum: int) -> bytes:
    if len(oid) != ctx.oid_bytes * 2 or any(ch not in HEX64 for ch in oid):
        raise Refusal("E_OBJECT")
    type_value = git(ctx, "cat-file", "-t", oid, limit=32).decode("ascii", "strict").strip()
    size_text = git(ctx, "cat-file", "-s", oid, limit=32).decode("ascii", "strict").strip()
    if type_value != expected_type or not size_text.isdigit():
        raise Refusal("E_OBJECT")
    size = int(size_text)
    if size > maximum:
        raise Refusal("E_LIMIT")
    body = git(ctx, "cat-file", expected_type, oid, limit=maximum + 1)
    if len(body) != size:
        raise Refusal("E_OBJECT")
    actual = hashlib.new(ctx.algorithm, f"{expected_type} {size}\0".encode() + body).hexdigest()
    if actual != oid:
        raise Refusal("E_OBJECT")
    ctx.ledger.charge("object_bytes", size, LIMITS["tree_bytes_visited"] + LIMITS["export_bytes"])
    return body


def parse_commit(ctx: Context, oid: str) -> tuple[str, list[str]]:
    body = git_object(ctx, oid, "commit", LIMITS["commit_bytes"])
    header = body.split(b"\n\n", 1)[0]
    tree_oid = None
    parents = []
    for line in header.splitlines():
        if line.startswith(b"tree ") and tree_oid is None:
            tree_oid = line[5:].decode("ascii", "strict")
        elif line.startswith(b"parent "):
            parents.append(line[7:].decode("ascii", "strict"))
    if tree_oid is None:
        raise Refusal("E_OBJECT")
    return tree_oid, parents


def valid_component(raw: bytes) -> str:
    try:
        name = raw.decode("utf-8", "strict")
    except UnicodeError as exc:
        raise Refusal("E_PATH") from exc
    encoded = name.encode("utf-8")
    if not encoded or len(encoded) > 255 or name in (".", "..") or "\\" in name or \
            name.casefold() == ".git" or name.endswith((".", " ")) or \
            any(ord(ch) <= 0x1f or 0x7f <= ord(ch) <= 0x9f for ch in name):
        raise Refusal("E_PATH")
    return name


def parse_tree(ctx: Context, oid: str) -> list[tuple[str, str, str]]:
    data = git_object(ctx, oid, "tree", LIMITS["tree_bytes"])
    entries = []
    cursor = 0
    previous: bytes | None = None
    while cursor < len(data):
        space = data.find(b" ", cursor)
        nul = data.find(b"\0", space + 1)
        if space < 0 or nul < 0 or nul + 1 + ctx.oid_bytes > len(data):
            raise Refusal("E_OBJECT")
        mode_raw = data[cursor:space]
        name_raw = data[space + 1:nul]
        child_oid = data[nul + 1:nul + 1 + ctx.oid_bytes].hex()
        if mode_raw not in (b"40000", b"100644", b"100755"):
            raise Refusal("E_OBJECT")
        sort_key = name_raw + (b"/" if mode_raw == b"40000" else b"")
        if previous is not None and previous >= sort_key:
            raise Refusal("E_OBJECT")
        previous = sort_key
        entries.append(("040000" if mode_raw == b"40000" else mode_raw.decode(),
                        valid_component(name_raw), child_oid))
        cursor = nul + 1 + ctx.oid_bytes
    return entries


def walk_tree(ctx: Context, root_oid: str) -> tuple[list[dict[str, Any]], dict[str, tuple[str, str]]]:
    inventory: list[dict[str, Any]] = []
    files: dict[str, tuple[str, str]] = {}
    aliases: dict[tuple[str, ...], str] = {}
    visits = entries_count = path_bytes = tree_bytes = 0
    stack: list[tuple[str, tuple[str, ...], int]] = [(root_oid, (), 0)]
    while stack:
        oid, prefix, depth = stack.pop()
        visits += 1
        if visits > LIMITS["tree_visits"]:
            raise Refusal("E_LIMIT")
        body_entries = parse_tree(ctx, oid)
        tree_bytes += len(git_object(ctx, oid, "tree", LIMITS["tree_bytes"]))
        if tree_bytes > LIMITS["tree_bytes_visited"] or (prefix and not body_entries):
            raise Refusal("E_OBJECT")
        children = []
        for mode, name, child in body_entries:
            entries_count += 1
            if entries_count > LIMITS["tree_entries"]:
                raise Refusal("E_LIMIT")
            parts = prefix + (name,)
            if len(parts) > 64:
                raise Refusal("E_PATH")
            path = "/".join(parts)
            encoded = path.encode("utf-8")
            if len(encoded) > 4096:
                raise Refusal("E_PATH")
            path_bytes += len(encoded)
            if path_bytes > LIMITS["export_path_bytes"]:
                raise Refusal("E_LIMIT")
            alias = tuple(unicodedata.normalize("NFC", part).casefold() for part in parts)
            if alias in aliases and aliases[alias] != path:
                raise Refusal("E_PATH")
            aliases[alias] = path
            if mode == "040000":
                inventory.append({"path": path, "kind": "directory", "git_mode": mode, "mode": "0500"})
                children.append((child, parts, depth + 1))
            else:
                if len(files) >= LIMITS["file_paths"]:
                    raise Refusal("E_LIMIT")
                files[path] = (mode, child)
        if sum(1 for item in inventory if item["kind"] == "directory") > LIMITS["directories"]:
            raise Refusal("E_LIMIT")
        stack.extend(reversed(children))
    inventory.sort(key=lambda item: item["path"].encode("utf-8"))
    return inventory, files


def changed_paths(source: dict[str, tuple[str, str]], candidate: dict[str, tuple[str, str]]) -> list[str]:
    all_paths = set(source) | set(candidate)
    return sorted((path for path in all_paths if source.get(path) != candidate.get(path)), key=lambda p: p.encode())


def allowed_changed_paths(input_value: dict[str, Any], paths: list[str]) -> None:
    try:
        arguments = input_value["stage_request"]["content"]["body"]["operation"]["arguments"]
        contract_id = arguments["materialization_contract"]["input_id"]
        payload = next(item for item in input_value["payloads"] if item["input_id"] == contract_id)
        contract = strict_json(payload["data"].encode("utf-8"))
        allowed = contract["allowed_paths"]
    except (KeyError, StopIteration, TypeError) as exc:
        raise Refusal("E_INPUT") from exc
    for path in paths:
        if not any(path == prefix or path.startswith(prefix.rstrip("/") + "/") for prefix in allowed):
            raise Refusal("E_OBJECT")


def ensure_directory(root_fd: int, parts: tuple[str, ...]) -> None:
    fd = os.dup(root_fd)
    try:
        for part in parts:
            try:
                os.mkdir(part, 0o700, dir_fd=fd)
            except FileExistsError:
                pass
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            st = os.fstat(next_fd)
            if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid():
                os.close(next_fd)
                raise Refusal("E_PATH")
            os.close(fd)
            fd = next_fd
    except OSError as exc:
        raise Refusal("E_IO") from exc
    finally:
        os.close(fd)


def export_candidate(ctx: Context, candidate_root: Path, directory_entries: list[dict[str, Any]],
                     files: dict[str, tuple[str, str]]) -> list[dict[str, Any]]:
    candidate_root.mkdir(mode=0o700)
    root_fd = os.open(candidate_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    inventory = list(directory_entries)
    total = 0
    try:
        for entry in directory_entries:
            ensure_directory(root_fd, tuple(entry["path"].split("/")))
        for path in sorted(files, key=lambda item: item.encode("utf-8")):
            mode, oid = files[path]
            parts = tuple(path.split("/"))
            ensure_directory(root_fd, parts[:-1])
            parent_fd = os.dup(root_fd)
            try:
                for part in parts[:-1]:
                    next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
                    os.close(parent_fd)
                    parent_fd = next_fd
                fd = os.open(parts[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600,
                             dir_fd=parent_fd)
                digest = hashlib.sha256()
                blob = git_object(ctx, oid, "blob", LIMITS["blob_bytes"])
                total += len(blob)
                if total > LIMITS["export_bytes"]:
                    raise Refusal("E_LIMIT")
                view = memoryview(blob)
                while view:
                    count = os.write(fd, view[:LIMITS["chunk_bytes"]])
                    if count <= 0:
                        raise Refusal("E_IO")
                    digest.update(view[:count])
                    view = view[count:]
                os.fsync(fd)
                os.fchmod(fd, 0o500 if mode == "100755" else 0o400)
                st = os.fstat(fd)
                if st.st_nlink != 1 or st.st_size != len(blob):
                    raise Refusal("E_IO")
                os.close(fd)
                fd = -1
                inventory.append({"path": path, "kind": "file", "git_mode": mode,
                                  "mode": "0500" if mode == "100755" else "0400",
                                  "blob_oid": oid, "size_bytes": len(blob), "sha256": digest.hexdigest()})
            except Refusal:
                raise
            except OSError as exc:
                raise Refusal("E_IO") from exc
            finally:
                if 'fd' in locals() and fd >= 0:
                    os.close(fd)
                os.close(parent_fd)
        for entry in sorted(directory_entries, key=lambda item: item["path"].count("/"), reverse=True):
            os.chmod(candidate_root / entry["path"], 0o500, follow_symlinks=False)
        os.fsync(root_fd)
        os.chmod(candidate_root, 0o500)
    finally:
        os.close(root_fd)
    inventory.sort(key=lambda item: item["path"].encode("utf-8"))
    return inventory


def measure_candidate(ctx: Context, root: Path, expected: list[dict[str, Any]]) -> list[dict[str, Any]]:
    actual = []
    inodes: set[tuple[int, int]] = set()
    try:
        root_st = os.lstat(root)
        if not stat.S_ISDIR(root_st.st_mode) or stat.S_IMODE(root_st.st_mode) != 0o500:
            raise Refusal("E_INCOMPLETE")
        for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
            dirs.sort(key=os.fsencode)
            files.sort(key=os.fsencode)
            relative_dir = os.path.relpath(current, root)
            relative_dir = "" if relative_dir == "." else relative_dir
            for name in dirs:
                path = f"{relative_dir}/{name}" if relative_dir else name
                st = os.lstat(Path(current) / name)
                if not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode) or stat.S_IMODE(st.st_mode) != 0o500:
                    raise Refusal("E_INCOMPLETE")
                if (st.st_dev, st.st_ino) in inodes:
                    raise Refusal("E_INCOMPLETE")
                inodes.add((st.st_dev, st.st_ino))
                actual.append({"path": path, "kind": "directory", "git_mode": "040000", "mode": "0500"})
            for name in files:
                path = f"{relative_dir}/{name}" if relative_dir else name
                st = os.lstat(Path(current) / name)
                if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_nlink != 1 or \
                        stat.S_IMODE(st.st_mode) not in (0o400, 0o500):
                    raise Refusal("E_INCOMPLETE")
                if (st.st_dev, st.st_ino) in inodes:
                    raise Refusal("E_INCOMPLETE")
                inodes.add((st.st_dev, st.st_ino))
                digest, size = sha_file(Path(current) / name, LIMITS["blob_bytes"])
                matching = [entry for entry in expected if entry.get("path") == path and entry.get("kind") == "file"]
                if len(matching) != 1:
                    raise Refusal("E_INCOMPLETE")
                item = dict(matching[0])
                if item["sha256"] != digest or item["size_bytes"] != size or \
                        item["mode"] != f"{stat.S_IMODE(st.st_mode):04o}":
                    raise Refusal("E_INCOMPLETE")
                actual.append(item)
    except Refusal:
        raise
    except (OSError, UnicodeError) as exc:
        raise Refusal("E_INCOMPLETE") from exc
    actual.sort(key=lambda item: item["path"].encode("utf-8"))
    if actual != expected:
        raise Refusal("E_INCOMPLETE")
    return actual


def write_exclusive(path: Path, data: bytes, mode: int) -> None:
    fd = -1
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), mode)
        view = memoryview(data)
        while view:
            count = os.write(fd, view[:LIMITS["chunk_bytes"]])
            if count <= 0:
                raise Refusal("E_IO")
            view = view[count:]
        os.fsync(fd)
        os.fchmod(fd, mode)
    except Refusal:
        raise
    except OSError as exc:
        raise Refusal("E_IO") from exc
    finally:
        if fd >= 0:
            os.close(fd)


def fsync_file(path: Path) -> None:
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError as exc:
        raise Refusal("E_IO") from exc


def fsync_dir(path: Path) -> None:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0))
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError as exc:
        raise Refusal("E_IO") from exc


def publish_record(bundle: Path, record_data: bytes) -> None:
    temporary = bundle / ".record.json.preparing"
    destination = bundle / "record.json"
    if destination.exists() or temporary.exists():
        raise Refusal("E_INCOMPLETE")
    write_exclusive(temporary, record_data, 0o400)
    try:
        os.link(temporary, destination, follow_symlinks=False)
        os.unlink(temporary)
    except OSError as exc:
        raise Refusal("E_IO") from exc
    fsync_file(destination)
    fsync_dir(bundle)
    fsync_dir(bundle.parent)


def manifest_for(inventory: list[dict[str, Any]]) -> dict[str, Any]:
    files = [entry for entry in inventory if entry["kind"] == "file"]
    dirs = [entry for entry in inventory if entry["kind"] == "directory"]
    return {"schema_version": 1, "kind": "candidate_content_manifest", "hash_algorithm": "sha256",
            "entries": inventory, "file_count": len(files), "directory_count": len(dirs),
            "total_file_bytes": sum(entry["size_bytes"] for entry in files)}


def validate_relations(ctx: Context, input_value: dict[str, Any], response: dict[str, Any],
                       details: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, tuple[str, str]]]:
    receipt = details["receipt"]
    try:
        source = receipt["source"]
        candidate = receipt["candidate"]
        outcome = response["stage_result"]["body"]["outcome"]["value"]
        ctx.algorithm = source["hash_algorithm"]
        ctx.oid_bytes = 20 if ctx.algorithm == "sha1" else 32 if ctx.algorithm == "sha256" else 0
        if not ctx.oid_bytes or candidate["hash_algorithm"] != ctx.algorithm:
            raise Refusal("E_OBJECT")
        ctx.identities["candidate_commit_id"] = candidate["commit_id"]
        candidate_tree, candidate_parents = parse_commit(ctx, candidate["commit_id"])
        source_tree, source_parents = parse_commit(ctx, source["commit_id"])
        if candidate_tree != candidate["tree_id"] or source_tree != source["tree_id"]:
            raise Refusal("E_OBJECT")
        if outcome == "changed":
            if candidate_parents != [source["commit_id"]]:
                raise Refusal("E_OBJECT")
        elif outcome == "no-change":
            if candidate["commit_id"] != source["commit_id"] or candidate["tree_id"] != source["tree_id"]:
                raise Refusal("E_OBJECT")
        else:
            raise Refusal("E_OBJECT")
        source_dirs, source_files = walk_tree(ctx, source_tree)
        candidate_dirs, candidate_files = walk_tree(ctx, candidate_tree)
        paths = changed_paths(source_files, candidate_files)
        digest = sha256(canonical(paths))
        if receipt["changed_paths"] != {"count": len(paths), "sha256": digest}:
            raise Refusal("E_OBJECT")
        allowed_changed_paths(input_value, paths)
        return receipt, candidate_dirs, candidate_files
    except (KeyError, TypeError, UnicodeError) as exc:
        raise Refusal("E_OBJECT") from exc


def producer_identity(ctx: Context) -> dict[str, Any]:
    script_sha, _ = sha_file(Path(__file__))
    executable_sha, _ = sha_file(Path(sys.executable))
    git_sha, _ = sha_file(Path(GIT))
    git_version = run_child(ctx, [GIT, "--version"], output_limit=128,
                            env=clean_git_env(ctx)).decode("ascii", "strict").strip()
    python_version = sys.version.splitlines()[0]
    if len(python_version.encode("ascii", "strict")) > 128 or len(git_version) > 128:
        raise Refusal("E_DEPENDENCY")
    return {"component_id": COMPONENT_ID, "source_sha256": script_sha,
            "python": {"executable_sha256": executable_sha, "version": python_version},
            "git": {"executable_sha256": git_sha, "version": git_version},
            "jq": ctx.identities["jq"], "protocol_sha256": DEPENDENCIES["adapters/local-git-materializer/v1/protocol.jq"],
            "core": ctx.identities["core"], "unicode_version": unicodedata.unidata_version}


def completion_envelope(record_data: bytes, manifest_data: bytes) -> bytes:
    value = {"schema_version": 1, "kind": "candidate_content_preparation_result", "status": "completed",
             "record_sha256": sha256(record_data), "manifest_sha256": sha256(manifest_data),
             "authority": "none", "qualification": "unavailable"}
    data = canonical(value)
    if len(data) > LIMITS["result_bytes"]:
        raise Refusal("E_LIMIT")
    return data


def emit_result(data: bytes) -> None:
    try:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    except (BrokenPipeError, OSError) as exc:
        raise Refusal("E_IO") from exc


def recheck_source(ctx: Context) -> None:
    facts, observation = enumerate_storage(ctx)
    if observation != ctx.source_observation or set(facts) != set(ctx.source_facts):
        raise Refusal("E_STORAGE")
    for path, fact in facts.items():
        original = ctx.source_facts[path]
        if fact != original:
            raise Refusal("E_STORAGE")


def make_record(ctx: Context, input_value: dict[str, Any], response: dict[str, Any],
                details: dict[str, Any], receipt: dict[str, Any], manifest_data: bytes) -> dict[str, Any]:
    outcome = response["stage_result"]["body"]["outcome"]["value"]
    candidate = receipt["candidate"]
    source = receipt["source"]
    return {
        "schema_version": 1, "kind": "candidate_content_preparation", "status": "completed",
        "authority": "none", "qualification": "unavailable",
        "input_sha256": ctx.args.input_sha256, "response_sha256": ctx.args.response_sha256,
        "stage_result_sha256": details["stage_result_sha256"],
        "receipt_sha256": details["verified_receipt"]["sha256"],
        "request_ref": receipt["request_ref"], "resolved_profile_ref": receipt["resolved_profile_ref"],
        "attempt": {"attempt_id": receipt["attempt"]["attempt_id"],
                    "attempt_number": receipt["attempt"]["attempt_number"]},
        "source": {"repository_id": source["repository_id"], "hash_algorithm": source["hash_algorithm"],
                   "commit_id": source["commit_id"], "tree_id": source["tree_id"]},
        "candidate": {"hash_algorithm": candidate["hash_algorithm"], "commit_id": candidate["commit_id"],
                      "tree_id": candidate["tree_id"], "parent_commit_id": candidate["parent_commit_id"],
                      "outcome": outcome},
        "manifest_sha256": sha256(manifest_data),
        "storage_observation_sha256": sha256(canonical(ctx.source_observation)),
        "producer": producer_identity(ctx),
        "ownership": {"state": "local-preparation-complete", "immutable": False,
                      "authenticated_receipt": False, "supervisor_handoff": "required"},
    }


def create_context(args: argparse.Namespace) -> Context:
    repo_root = Path(__file__).resolve().parents[2]
    scratch_parent = Path(args.scratch)
    require_private_dir(scratch_parent)
    scratch_name = tempfile.mkdtemp(prefix="candidate-preparation-", dir=scratch_parent)
    os.chmod(scratch_name, 0o700)
    scratch = Path(scratch_name)
    return Context(args=args, repo_root=repo_root, scratch=scratch,
                   copied_repo=scratch / "candidate.git", sidecars=scratch / "observed-sidecars",
                   deps_root=scratch / "dependencies", ledger=Ledger(),
                   deadline=time.monotonic() + LIMITS["operation_seconds"])


def acquire_lock(path: Path, create: bool) -> int:
    flags = os.O_RDWR | os.O_NOFOLLOW
    if create:
        flags |= os.O_CREAT | os.O_EXCL
    try:
        fd = os.open(path, flags, 0o600)
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_uid != os.geteuid():
            raise Refusal("E_IDENTITY", 2)
        fcntl.flock(fd, fcntl.LOCK_EX)
        return fd
    except FileExistsError as exc:
        raise Refusal("E_EXISTS", 2) from exc
    except FileNotFoundError as exc:
        raise Refusal("E_INCOMPLETE") from exc
    except Refusal:
        raise
    except OSError as exc:
        raise Refusal("E_IO") from exc


def load_identity_inputs(ctx: Context) -> tuple[bytes, bytes]:
    input_data = read_limited(Path(ctx.args.input), LIMITS["input_bytes"], ctx.args.input_sha256)
    response_data = read_limited(Path(ctx.args.response), LIMITS["response_bytes"], ctx.args.response_sha256)
    ctx.ledger.charge("input_bytes", len(input_data) + len(response_data),
                      LIMITS["input_bytes"] + LIMITS["response_bytes"])
    return input_data, response_data


def initialize_storage_identity(ctx: Context, details: dict[str, Any]) -> None:
    try:
        receipt = details["receipt"]
        ctx.algorithm = receipt["source"]["hash_algorithm"]
        ctx.oid_bytes = 20 if ctx.algorithm == "sha1" else 32 if ctx.algorithm == "sha256" else 0
        candidate_commit = receipt["candidate"]["commit_id"]
        if not ctx.oid_bytes or len(candidate_commit) != ctx.oid_bytes * 2 or any(ch not in HEX64 for ch in candidate_commit):
            raise Refusal("E_INPUT")
        ctx.identities["candidate_commit_id"] = candidate_commit
    except (KeyError, TypeError) as exc:
        raise Refusal("E_INPUT") from exc


def prepare(ctx: Context) -> bytes:
    bundle = Path(ctx.args.output)
    if os.path.lexists(bundle):
        raise Refusal("E_EXISTS", 2)
    try:
        os.mkdir(bundle, 0o700)
    except FileExistsError as exc:
        raise Refusal("E_EXISTS", 2) from exc
    except OSError as exc:
        raise Refusal("E_IO") from exc
    lock_fd = acquire_lock(bundle / "preparation.lock", True)
    try:
        input_data, response_data = load_identity_inputs(ctx)
        jq_copy, protocol = copy_dependencies(ctx)
        input_value, response, details = validate_documents(ctx, input_data, response_data, jq_copy, protocol)
        initialize_storage_identity(ctx, details)
        ctx.source_facts, ctx.source_observation = enumerate_storage(ctx)
        copy_storage(ctx)
        receipt, directories, files = validate_relations(ctx, input_value, response, details)
        write_exclusive(bundle / "input.json", input_data, 0o400)
        write_exclusive(bundle / "response.json", response_data, 0o400)
        inventory = export_candidate(ctx, bundle / "candidate", directories, files)
        inventory = measure_candidate(ctx, bundle / "candidate", inventory)
        manifest = manifest_for(inventory)
        manifest_data = canonical(manifest)
        if len(manifest_data) > LIMITS["manifest_bytes"]:
            raise Refusal("E_LIMIT")
        write_exclusive(bundle / "manifest.json", manifest_data, 0o400)
        recheck_source(ctx)
        record = make_record(ctx, input_value, response, details, receipt, manifest_data)
        record_data = canonical(record)
        if len(record_data) > LIMITS["record_bytes"]:
            raise Refusal("E_LIMIT")
        for path in (bundle / "input.json", bundle / "response.json", bundle / "manifest.json"):
            fsync_file(path)
        publish_record(bundle, record_data)
        recheck_source(ctx)
        verify_top_level(bundle)
        return completion_envelope(record_data, manifest_data)
    finally:
        os.close(lock_fd)


def verify_top_level(bundle: Path) -> None:
    expected = {"candidate", "input.json", "response.json", "manifest.json", "record.json", "preparation.lock"}
    try:
        observed = set(os.listdir(bundle))
    except OSError as exc:
        raise Refusal("E_INCOMPLETE") from exc
    if observed != expected:
        raise Refusal("E_INCOMPLETE")
    for name in expected - {"candidate"}:
        st = os.lstat(bundle / name)
        mode = 0o600 if name == "preparation.lock" else 0o400
        if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_nlink != 1 or \
                stat.S_IMODE(st.st_mode) != mode:
            raise Refusal("E_INCOMPLETE")


def inspect(ctx: Context) -> bytes:
    bundle = Path(ctx.args.output)
    require_private_dir(bundle)
    lock_fd = acquire_lock(bundle / "preparation.lock", False)
    try:
        verify_top_level(bundle)
        input_data, response_data = load_identity_inputs(ctx)
        if read_limited(bundle / "input.json", LIMITS["input_bytes"]) != input_data or \
                read_limited(bundle / "response.json", LIMITS["response_bytes"]) != response_data:
            raise Refusal("E_IDENTITY", 2)
        jq_copy, protocol = copy_dependencies(ctx)
        input_value, response, details = validate_documents(ctx, input_data, response_data, jq_copy, protocol)
        initialize_storage_identity(ctx, details)
        ctx.source_facts, ctx.source_observation = enumerate_storage(ctx)
        copy_storage(ctx)
        receipt, directories, files = validate_relations(ctx, input_value, response, details)
        manifest_data = read_limited(bundle / "manifest.json", LIMITS["manifest_bytes"])
        manifest = strict_json(manifest_data, "E_INCOMPLETE")
        if canonical(manifest) != manifest_data:
            raise Refusal("E_INCOMPLETE")
        exact_keys(manifest, {"schema_version", "kind", "hash_algorithm", "entries", "file_count",
                              "directory_count", "total_file_bytes"}, "E_INCOMPLETE")
        expected_inventory = []
        for item in directories:
            expected_inventory.append(item)
        for path, (mode, oid) in files.items():
            matching = [entry for entry in manifest["entries"] if entry.get("path") == path]
            if len(matching) != 1 or matching[0].get("git_mode") != mode or matching[0].get("blob_oid") != oid:
                raise Refusal("E_INCOMPLETE")
            expected_inventory.append(matching[0])
        expected_inventory.sort(key=lambda item: item["path"].encode("utf-8"))
        measure_candidate(ctx, bundle / "candidate", expected_inventory)
        if manifest_for(expected_inventory) != manifest:
            raise Refusal("E_INCOMPLETE")
        record_data = read_limited(bundle / "record.json", LIMITS["record_bytes"])
        record = strict_json(record_data, "E_INCOMPLETE")
        if canonical(record) != record_data:
            raise Refusal("E_INCOMPLETE")
        expected_record = make_record(ctx, input_value, response, details, receipt, manifest_data)
        if record != expected_record:
            raise Refusal("E_INCOMPLETE")
        recheck_source(ctx)
        verify_top_level(bundle)
        return completion_envelope(record_data, manifest_data)
    finally:
        os.close(lock_fd)


def parse_args(argv: list[str]) -> argparse.Namespace:
    if not argv or argv[0] not in ("prepare", "inspect"):
        raise Refusal("E_USAGE", 2)
    option_names = [item for item in argv[1:] if item.startswith("--")]
    if len(option_names) != len(set(option_names)):
        raise Refusal("E_USAGE", 2)
    parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False, exit_on_error=False)
    parser.add_argument("operation", choices=("prepare", "inspect"))
    for name in ("input", "input-sha256", "response", "response-sha256",
                 "candidate-repository", "output", "scratch", "jq"):
        parser.add_argument(f"--{name}", required=True)
    try:
        args = parser.parse_args(argv)
    except (argparse.ArgumentError, SystemExit) as exc:
        raise Refusal("E_USAGE", 2) from exc
    for field in ("input", "response", "candidate_repository", "output", "scratch", "jq"):
        setattr(args, field, str(physical_absolute(getattr(args, field))))
    if not valid_sha(args.input_sha256) or not valid_sha(args.response_sha256):
        raise Refusal("E_USAGE", 2)
    input_path, response_path, repository, output, scratch, jq_path = map(
        Path, (args.input, args.response, args.candidate_repository, args.output, args.scratch, args.jq))
    for regular in (input_path, response_path, jq_path):
        try:
            st = os.lstat(regular)
        except OSError as exc:
            raise Refusal("E_USAGE", 2) from exc
        if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_nlink != 1 or st.st_uid != os.geteuid():
            raise Refusal("E_IDENTITY", 2)
    require_private_dir(repository)
    require_private_dir(scratch)
    require_private_dir(output.parent)
    paths_overlap([input_path, response_path, repository, output, scratch, jq_path])
    if sys.version_info < (3, 11) or not sys.flags.isolated:
        raise Refusal("E_DEPENDENCY")
    return args


def main(argv: list[str]) -> int:
    context: Context | None = None
    try:
        args = parse_args(argv)
        context = create_context(args)
        result = prepare(context) if args.operation == "prepare" else inspect(context)
        emit_result(result)
        return 0
    except KeyboardInterrupt:
        refusal = Refusal("E_INTERRUPTED", 75)
    except Refusal as caught:
        refusal = caught
    except Exception:
        refusal = Refusal("E_IO")
    try:
        sys.stderr.write(refusal.token + "\n")
        sys.stderr.flush()
    except OSError:
        pass
    return refusal.exit_code


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(Refusal("E_INTERRUPTED", 75)))
    signal.signal(signal.SIGHUP, lambda *_: (_ for _ in ()).throw(Refusal("E_INTERRUPTED", 75)))
    raise SystemExit(main(sys.argv[1:]))
