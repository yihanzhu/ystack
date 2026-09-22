#!/usr/bin/env python3
"""Private fixture and oracle support for candidate content preparation tests."""

from __future__ import annotations

import argparse
import base64
import binascii
import dataclasses
import hashlib
import importlib.util
import json
import os
import selectors
import signal
import stat
import struct
import subprocess
import sys
import time
import types
import zlib
from pathlib import Path
from typing import Any


CHUNK = 64 * 1024
GIT_MODES = {"100644": 0o400, "100755": 0o500}
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
}


class FixtureError(Exception):
    pass


def canonical_json(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
        + "\n"
    ).encode("utf-8")


def strict_load(path: Path) -> Any:
    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in items:
            if key in result:
                raise FixtureError(f"duplicate JSON member: {key}")
            result[key] = value
        return result

    try:
        raw = path.read_bytes()
        text = raw.decode("utf-8")
        value = json.loads(
            text,
            object_pairs_hook=pairs,
            parse_constant=lambda token: (_ for _ in ()).throw(
                FixtureError(f"invalid JSON number: {token}")
            ),
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise FixtureError(str(exc)) from exc
    reject_surrogates(value)
    return value


def reject_surrogates(value: Any) -> None:
    if isinstance(value, str):
        if any(0xD800 <= ord(char) <= 0xDFFF for char in value):
            raise FixtureError("JSON contains a lone surrogate")
    elif isinstance(value, list):
        for item in value:
            reject_surrogates(item)
    elif isinstance(value, dict):
        for key, item in value.items():
            reject_surrogates(key)
            reject_surrogates(item)


def write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.open("xb") as stream:
        stream.write(data)


def replace_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.open("wb") as stream:
        stream.write(data)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git_hash(algorithm: str, kind: str, body: bytes) -> str:
    header = f"{kind} {len(body)}\0".encode("ascii")
    return hashlib.new(algorithm, header + body).hexdigest()


def entry_bytes(entry: dict[str, Any]) -> bytes:
    choices = [name for name in ("content_base64", "content_hex", "content_utf8") if name in entry]
    if len(choices) != 1:
        raise FixtureError("each file needs exactly one content encoding")
    try:
        if choices[0] == "content_base64":
            return base64.b64decode(entry[choices[0]], validate=True)
        if choices[0] == "content_hex":
            return bytes.fromhex(entry[choices[0]])
        return entry[choices[0]].encode("utf-8")
    except (ValueError, binascii.Error, UnicodeEncodeError) as exc:
        raise FixtureError(f"invalid content encoding for {entry.get('path')}") from exc


def normalized_description(path: Path) -> list[tuple[str, str, bytes]]:
    value = strict_load(path)
    entries = value.get("entries") if isinstance(value, dict) else value
    if not isinstance(entries, list):
        raise FixtureError("description must be an entry list or contain entries")
    result: list[tuple[str, str, bytes]] = []
    seen: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) - {
            "path", "git_mode", "content_base64", "content_hex", "content_utf8"
        }:
            raise FixtureError("invalid oracle entry")
        name = entry.get("path")
        mode = entry.get("git_mode")
        if not isinstance(name, str) or not name or name.startswith("/"):
            raise FixtureError("oracle path must be relative")
        components = name.split("/")
        if any(part in ("", ".", "..") for part in components):
            raise FixtureError(f"invalid oracle path: {name}")
        if name in seen:
            raise FixtureError(f"duplicate oracle path: {name}")
        if mode not in GIT_MODES:
            raise FixtureError(f"invalid oracle Git mode: {mode}")
        name.encode("utf-8")
        seen.add(name)
        result.append((name, mode, entry_bytes(entry)))
    result.sort(key=lambda item: item[0].encode("utf-8"))
    return result


def oracle(entries: list[tuple[str, str, bytes]]) -> dict[str, Any]:
    directories: set[str] = set()
    manifest_entries: list[dict[str, Any]] = []
    for name, git_mode, body in entries:
        pieces = name.split("/")
        for end in range(1, len(pieces)):
            directories.add("/".join(pieces[:end]))
        manifest_entries.append(
            {
                "path": name,
                "kind": "file",
                "git_mode": git_mode,
                "mode": f"{GIT_MODES[git_mode]:04o}",
                "blob_oid": None,
                "size_bytes": len(body),
                "sha256": sha256_bytes(body),
            }
        )
    for name in directories:
        manifest_entries.append(
            {
                "path": name,
                "kind": "directory",
                "git_mode": "040000",
                "mode": "0500",
            }
        )
    manifest_entries.sort(key=lambda item: item["path"].encode("utf-8"))
    return {
        "schema_version": 1,
        "kind": "candidate_content_manifest",
        "hash_algorithm": "sha256",
        "entries": manifest_entries,
        "file_count": len(entries),
        "directory_count": len(directories),
        "total_file_bytes": sum(len(body) for _, _, body in entries),
    }


def add_blob_oids(
    manifest: dict[str, Any], entries: list[tuple[str, str, bytes]], algorithm: str
) -> None:
    bodies = {name: body for name, _, body in entries}
    for entry in manifest["entries"]:
        if entry["kind"] == "file":
            entry["blob_oid"] = git_hash(algorithm, "blob", bodies[entry["path"]])


def build_tree(root: Path, entries: list[tuple[str, str, bytes]], root_mode: int | None) -> None:
    if root.exists() or root.is_symlink():
        raise FixtureError("oracle root already exists")
    root.mkdir(mode=0o700)
    for name, git_mode, body in entries:
        destination = root.joinpath(*name.split("/"))
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        write_bytes(destination, body)
        destination.chmod(GIT_MODES[git_mode])
    directories = sorted(
        (item for item in root.rglob("*") if item.is_dir()),
        key=lambda item: len(item.parts),
        reverse=True,
    )
    for directory in directories:
        directory.chmod(0o500)
    if root_mode is not None:
        root.chmod(root_mode)


def actual_tree(root: Path) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for current, dirnames, filenames in os.walk(root, followlinks=False):
        current_path = Path(current)
        for name in sorted(dirnames + filenames, key=lambda item: os.fsencode(item)):
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            mode = stat.S_IMODE(info.st_mode)
            if stat.S_ISLNK(info.st_mode):
                kind = "symlink"
                digest = None
                size = len(os.readlink(path).encode("utf-8", "surrogateescape"))
            elif stat.S_ISDIR(info.st_mode):
                kind = "directory"
                digest = None
                size = None
            elif stat.S_ISREG(info.st_mode):
                kind = "file"
                digest = hash_file(path, "sha256")
                size = info.st_size
            else:
                kind = "other"
                digest = None
                size = None
            result.append(
                {
                    "path": relative,
                    "kind": kind,
                    "mode": f"{mode:04o}",
                    "size_bytes": size,
                    "sha256": digest,
                }
            )
    result.sort(key=lambda item: item["path"].encode("utf-8"))
    return result


def expected_tree(entries: list[tuple[str, str, bytes]]) -> list[dict[str, Any]]:
    manifest = oracle(entries)
    result: list[dict[str, Any]] = []
    for item in manifest["entries"]:
        result.append(
            {
                "path": item["path"],
                "kind": item["kind"],
                "mode": item["mode"],
                "size_bytes": item.get("size_bytes"),
                "sha256": item.get("sha256"),
            }
        )
    return result


def check_tree_nodes(root: Path) -> None:
    seen: set[tuple[int, int]] = set()
    paths = [root]
    for current, dirnames, filenames in os.walk(root, followlinks=False):
        current_path = Path(current)
        paths.extend(current_path / name for name in dirnames + filenames)
    for path in paths:
        info = path.lstat()
        identity = (info.st_dev, info.st_ino)
        if identity in seen:
            raise FixtureError("actual tree contains aliased inode identities")
        seen.add(identity)
        if stat.S_ISREG(info.st_mode):
            if info.st_nlink != 1:
                raise FixtureError("actual tree contains a linked file")
        elif not stat.S_ISDIR(info.st_mode):
            raise FixtureError("actual tree contains a non-file node")


def hash_file(path: Path, algorithm: str) -> str:
    digest = hashlib.new(algorithm)
    with path.open("rb") as stream:
        while chunk := stream.read(CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


def snapshot_fact(path: Path, relative: str) -> dict[str, Any]:
    info = path.lstat()
    raw_relative = os.fsencode(relative)
    try:
        display_relative: str | None = raw_relative.decode("utf-8")
    except UnicodeDecodeError:
        display_relative = None
    fact: dict[str, Any] = {
        "path": display_relative,
        "path_base64": base64.b64encode(raw_relative).decode("ascii"),
        "mode": f"{stat.S_IMODE(info.st_mode):04o}",
        "uid": info.st_uid,
        "gid": info.st_gid,
        "nlink": info.st_nlink,
        "device": info.st_dev,
        "inode": info.st_ino,
        "size_bytes": info.st_size,
        "mtime_ns": info.st_mtime_ns,
        "ctime_ns": info.st_ctime_ns,
    }
    if stat.S_ISREG(info.st_mode):
        fact.update(kind="file", sha256=hash_file(path, "sha256"))
    elif stat.S_ISDIR(info.st_mode):
        fact.update(kind="directory")
    elif stat.S_ISLNK(info.st_mode):
        target = os.readlink(path)
        fact.update(
            kind="symlink",
            target_base64=base64.b64encode(os.fsencode(target)).decode("ascii"),
        )
    elif stat.S_ISFIFO(info.st_mode):
        fact.update(kind="fifo")
    elif stat.S_ISSOCK(info.st_mode):
        fact.update(kind="socket")
    elif stat.S_ISCHR(info.st_mode):
        fact.update(kind="character-device", rdev=info.st_rdev)
    elif stat.S_ISBLK(info.st_mode):
        fact.update(kind="block-device", rdev=info.st_rdev)
    else:
        fact.update(kind="unknown")
    return fact


def snapshot(root: Path) -> dict[str, Any]:
    info = root.lstat()
    if stat.S_ISREG(info.st_mode):
        entries = [snapshot_fact(root, ".")]
    elif stat.S_ISDIR(info.st_mode):
        entries = [snapshot_fact(root, ".")]
        for current, dirnames, filenames in os.walk(root, followlinks=False):
            current_path = Path(current)
            for name in sorted(dirnames + filenames, key=lambda item: os.fsencode(item)):
                path = current_path / name
                entries.append(snapshot_fact(path, path.relative_to(root).as_posix()))
        entries.sort(key=lambda item: base64.b64decode(item["path_base64"]))
    else:
        raise FixtureError("snapshot root must be a regular file or directory")
    return {"schema_version": 1, "entries": entries}


def parse_index(index_path: Path, algorithm: str) -> tuple[list[int], bytes]:
    hash_size = hashlib.new(algorithm).digest_size
    data = index_path.read_bytes()
    if len(data) < 8 + 256 * 4 + 2 * hash_size or data[:4] != b"\xfftOc":
        raise FixtureError("index is not version 2")
    if struct.unpack(">I", data[4:8])[0] != 2:
        raise FixtureError("index is not version 2")
    fanout_start = 8
    count = struct.unpack(">I", data[fanout_start + 255 * 4:fanout_start + 256 * 4])[0]
    names_end = fanout_start + 256 * 4 + count * hash_size
    crc_end = names_end + count * 4
    offsets_end = crc_end + count * 4
    if offsets_end + 2 * hash_size > len(data):
        raise FixtureError("truncated index")
    raw_offsets = list(struct.unpack(f">{count}I", data[crc_end:offsets_end]))
    large_count = sum(1 for value in raw_offsets if value & 0x80000000)
    expected = offsets_end + large_count * 8 + 2 * hash_size
    if expected != len(data):
        raise FixtureError("invalid index length")
    large = (
        struct.unpack(
            f">{large_count}Q", data[offsets_end:offsets_end + large_count * 8]
        )
        if large_count
        else ()
    )
    offsets: list[int] = []
    for value in raw_offsets:
        if value & 0x80000000:
            position = value & 0x7FFFFFFF
            if position >= len(large):
                raise FixtureError("invalid large-offset position")
            offsets.append(large[position])
        else:
            offsets.append(value)
    calculated = hashlib.new(algorithm, data[:-hash_size]).digest()
    if calculated != data[-hash_size:]:
        raise FixtureError("invalid index checksum")
    return offsets, data[-2 * hash_size:-hash_size]


def make_reverse_index(index_path: Path, pack_path: Path, algorithm: str) -> bytes:
    offsets, index_pack_checksum = parse_index(index_path, algorithm)
    hash_size = hashlib.new(algorithm).digest_size
    pack = pack_path.read_bytes()
    if len(pack) < 12 + hash_size or pack[:4] != b"PACK":
        raise FixtureError("invalid pack")
    count = struct.unpack(">I", pack[8:12])[0]
    if count != len(offsets):
        raise FixtureError("pack/index count mismatch")
    pack_checksum = hashlib.new(algorithm, pack[:-hash_size]).digest()
    if pack_checksum != pack[-hash_size:] or pack_checksum != index_pack_checksum:
        raise FixtureError("pack checksum mismatch")
    positions = sorted(range(len(offsets)), key=lambda position: offsets[position])
    hash_id = 1 if algorithm == "sha1" else 2
    prefix = b"RIDX" + struct.pack(">II", 1, hash_id)
    prefix += b"".join(struct.pack(">I", position) for position in positions)
    prefix += pack_checksum
    return prefix + hashlib.new(algorithm, prefix).digest()


def mutate_reverse(data: bytes, algorithm: str, case: str, rehash: bool) -> bytes:
    hash_size = hashlib.new(algorithm).digest_size
    if len(data) < 12 + 2 * hash_size:
        raise FixtureError("reverse index is too short")
    prefix = bytearray(data[:-hash_size])
    positions_end = len(prefix) - hash_size
    if case == "signature":
        prefix[0:4] = b"BAD!"
    elif case == "version":
        prefix[4:8] = struct.pack(">I", 2)
    elif case == "hash-id":
        prefix[8:12] = struct.pack(">I", 2 if algorithm == "sha1" else 1)
    elif case == "duplicate-position":
        if positions_end < 20:
            raise FixtureError("reverse index needs two positions")
        prefix[16:20] = prefix[12:16]
    elif case == "swap-positions":
        if positions_end < 20:
            raise FixtureError("reverse index needs two positions")
        first = bytes(prefix[12:16])
        prefix[12:16] = prefix[16:20]
        prefix[16:20] = first
    elif case == "out-of-range-position":
        count = (positions_end - 12) // 4
        if count == 0:
            raise FixtureError("reverse index needs one position")
        prefix[12:16] = struct.pack(">I", count)
    elif case == "pack-checksum":
        prefix[-hash_size] ^= 1
    elif case == "reverse-checksum":
        result = bytearray(data)
        result[-1] ^= 1
        return bytes(result)
    elif case == "truncate":
        return data[:-1]
    elif case == "trailing":
        return data + b"X"
    else:
        raise FixtureError(f"unknown reverse-index mutation: {case}")
    checksum = hashlib.new(algorithm, prefix).digest() if rehash else data[-hash_size:]
    return bytes(prefix) + checksum


def encode_tree(entries_path: Path, algorithm: str) -> bytes:
    value = strict_load(entries_path)
    if not isinstance(value, list):
        raise FixtureError("tree entries must be a list")
    oid_size = hashlib.new(algorithm).digest_size
    output = bytearray()
    for entry in value:
        if not isinstance(entry, dict) or set(entry) != {"mode", "name_base64", "oid"}:
            raise FixtureError("invalid tree entry")
        mode = entry["mode"]
        if not isinstance(mode, str) or not mode or any(char not in "01234567" for char in mode):
            raise FixtureError("invalid raw tree mode")
        try:
            name = base64.b64decode(entry["name_base64"], validate=True)
            oid = bytes.fromhex(entry["oid"])
        except (TypeError, ValueError, binascii.Error) as exc:
            raise FixtureError("invalid raw tree entry encoding") from exc
        if len(oid) != oid_size:
            raise FixtureError("wrong raw tree object-id length")
        output.extend(mode.encode("ascii") + b" " + name + b"\0" + oid)
    return bytes(output)


def write_loose(repo: Path, algorithm: str, kind: str, body: bytes) -> str:
    oid = git_hash(algorithm, kind, body)
    location = repo / "objects" / oid[:2] / oid[2:]
    encoded = zlib.compress(f"{kind} {len(body)}\0".encode("ascii") + body)
    if location.exists():
        if zlib.decompress(location.read_bytes()) != zlib.decompress(encoded):
            raise FixtureError("object collision")
    else:
        write_bytes(location, encoded)
    return oid


def nested_json(depth: int) -> Any:
    value: Any = None
    for _ in range(depth):
        value = [value]
    return value


def corrupt_json(source: Path, output: Path, case: str) -> None:
    raw = source.read_bytes()
    if case == "bom":
        result = b"\xef\xbb\xbf" + raw
    elif case == "trailing":
        result = raw.rstrip() + b"\n{}\n"
    elif case == "duplicate-member":
        result = b'{"fixture_duplicate":1,"fixture_duplicate":2}\n'
    elif case == "lone-surrogate":
        result = b'{"fixture":"\\ud800"}\n'
    elif case == "nonfinite":
        result = b'{"fixture":NaN}\n'
    elif case == "depth-33":
        result = canonical_json(nested_json(33))
    elif case == "invalid-utf8":
        result = b'{"fixture":"\xff"}\n'
    else:
        raise FixtureError(f"unknown JSON corruption: {case}")
    write_bytes(output, result)


def load_component(path: Path) -> Any:
    spec = importlib.util.spec_from_file_location("candidate_preparation_fixture_target", path)
    if spec is None or spec.loader is None:
        raise FixtureError("cannot import component")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[spec.name]
        raise
    return module


def command_oracle(args: argparse.Namespace) -> None:
    entries = normalized_description(args.description)
    manifest = oracle(entries)
    add_blob_oids(manifest, entries, args.algorithm)
    if args.action == "build":
        build_tree(args.root, entries, int(args.root_mode, 8) if args.root_mode else None)
    if args.root_mode and stat.S_IMODE(args.root.lstat().st_mode) != int(args.root_mode, 8):
        raise FixtureError("oracle root mode mismatch")
    check_tree_nodes(args.root)
    actual = actual_tree(args.root)
    expected = expected_tree(entries)
    if actual != expected:
        raise FixtureError("actual tree differs from independent oracle")
    if args.manifest is not None and args.action == "build":
        replace_bytes(args.manifest, canonical_json(manifest))
    elif args.manifest is not None and strict_load(args.manifest) != manifest:
        raise FixtureError("manifest differs from independent oracle")
    print(sha256_bytes(canonical_json(manifest)))


def command_snapshot(args: argparse.Namespace) -> None:
    current = snapshot(args.path)
    if args.action == "create":
        replace_bytes(args.snapshot, canonical_json(current))
    elif current != strict_load(args.snapshot):
        raise FixtureError("snapshot mismatch")


def command_object(args: argparse.Namespace) -> None:
    oid = write_loose(args.repository, args.algorithm, args.type, args.body.read_bytes())
    if args.oid_file is not None:
        replace_bytes(args.oid_file, (oid + "\n").encode("ascii"))
    print(oid)


def command_tree(args: argparse.Namespace) -> None:
    replace_bytes(args.output, encode_tree(args.entries, args.algorithm))


def command_reverse(args: argparse.Namespace) -> None:
    if args.action == "make":
        result = make_reverse_index(args.index, args.pack, args.algorithm)
    else:
        result = mutate_reverse(args.input.read_bytes(), args.algorithm, args.case, args.rehash)
    write_bytes(args.output, result)


def command_json(args: argparse.Namespace) -> None:
    corrupt_json(args.input, args.output, args.case)


def command_relation(args: argparse.Namespace) -> None:
    response = strict_load(args.input)
    payload = response["payloads"][0]
    receipt = json.loads(payload["data"])
    if args.case == "request-ref":
        receipt["request_ref"]["sha256"] = "0" * 64
    elif args.case == "candidate-commit":
        value = receipt["candidate"]["commit_id"]
        receipt["candidate"]["commit_id"] = "0" * len(value)
    elif args.case == "parent-commit":
        value = receipt["candidate"]["parent_commit_id"]
        receipt["candidate"]["parent_commit_id"] = "0" * len(value)
    elif args.case == "attempt-number":
        receipt["attempt"]["attempt_number"] += 1
    elif args.case == "receipt-extra":
        receipt["unexpected"] = False
    elif args.case == "response-authority":
        response["authority"] = "local"
    elif args.case == "profile-ref":
        receipt["resolved_profile_ref"]["sha256"] = "0" * 64
    elif args.case == "source-repository":
        receipt["source"]["repository_id"] = "fixture.other"
    elif args.case == "outcome":
        response["stage_result"]["body"]["outcome"]["value"] = "no-change"
    elif args.case == "fake-receipt":
        receipt["kind"] = "candidate_materialization_receipt_fake"
    elif args.case == "numeric-shape":
        receipt["attempt"]["attempt_number"] = 1.0
    elif args.case == "nested-shape":
        receipt["candidate"] = []
    else:
        raise FixtureError("unknown relation mutation")
    if args.case != "response-authority":
        receipt_bytes = canonical_json(receipt)
        payload["data"] = receipt_bytes.decode("utf-8")
        payload["sha256"] = hashlib.sha256(receipt_bytes).hexdigest()
    replace_bytes(args.output, canonical_json(response))


def command_canonical(args: argparse.Namespace) -> None:
    encoded = canonical_json(strict_load(args.input))
    if args.output is None:
        sys.stdout.buffer.write(encoded)
    else:
        replace_bytes(args.output, encoded)


def command_limits(args: argparse.Namespace) -> None:
    selected = LIMITS if args.name is None else {args.name: LIMITS[args.name]}
    rows = [
        {"name": name, "inclusive": maximum, "overflow": maximum + 1}
        for name, maximum in selected.items()
    ]
    sys.stdout.buffer.write(canonical_json({"schema_version": 1, "limits": rows}))


def injected_error(target: str) -> OSError:
    if target == "emit_result":
        return BrokenPipeError(32, "fixture outward pipe failure")
    return OSError(5, "fixture I/O failure")


def command_inject(args: argparse.Namespace) -> None:
    module = load_component(args.component)
    if not hasattr(module, args.target) or not callable(getattr(module, args.target)):
        raise FixtureError(f"component has no callable {args.target}")
    original = getattr(module, args.target)
    calls = 0

    def signal_and_wait() -> None:
        if args.ready is None or args.release is None:
            raise FixtureError("pause injection requires --ready and --release")
        write_bytes(args.ready, b"ready\n")
        deadline = time.monotonic() + args.wait_seconds
        while not args.release.exists():
            if time.monotonic() >= deadline:
                raise TimeoutError("fixture release timeout")
            time.sleep(0.01)

    def replacement(*call_args: Any, **call_kwargs: Any) -> Any:
        nonlocal calls
        calls += 1
        if calls != args.occurrence:
            return original(*call_args, **call_kwargs)
        if args.mode == "before-error":
            raise injected_error(args.target)
        if args.mode == "before-pause":
            signal_and_wait()
            return original(*call_args, **call_kwargs)
        result = original(*call_args, **call_kwargs)
        if args.mode == "after-error":
            raise injected_error(args.target)
        signal_and_wait()
        return result

    setattr(module, args.target, replacement)
    invocation = strict_load(args.argv_json)
    if not isinstance(invocation, list) or not all(isinstance(item, str) for item in invocation):
        raise FixtureError("injected argv must be a JSON string list")
    main_function = getattr(module, "main", None)
    if not callable(main_function):
        raise FixtureError("component has no main callable")
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(module.Refusal("E_INTERRUPTED", 75)))
    signal.signal(signal.SIGHUP, lambda *_: (_ for _ in ()).throw(module.Refusal("E_INTERRUPTED", 75)))
    result = main_function(invocation)
    if calls < args.occurrence:
        raise FixtureError(f"{args.target} was called only {calls} times")
    if result is not None:
        raise SystemExit(result)


def command_child_setup_cleanup(args: argparse.Namespace) -> None:
    module = load_component(args.component)
    selector_factory = module.selectors.DefaultSelector
    popen_factory = module.subprocess.Popen
    children: list[subprocess.Popen[bytes]] = []

    class FailingSelector:
        def __init__(self) -> None:
            self.actual = selector_factory()

        def register(self, *_args: Any, **_kwargs: Any) -> None:
            raise OSError(5, "fixture selector registration failure")

        def close(self) -> None:
            self.actual.close()

    def capture_popen(*call_args: Any, **call_kwargs: Any) -> subprocess.Popen[bytes]:
        child = popen_factory(*call_args, **call_kwargs)
        children.append(child)
        return child

    context = module.Context(
        args=types.SimpleNamespace(), repo_root=Path("/"), scratch=Path("/"),
        copied_repo=Path("/"), sidecars=Path("/"), deps_root=Path("/"),
        ledger=module.Ledger(), deadline=time.monotonic() + 10, boundaries={},
    )
    module.selectors.DefaultSelector = FailingSelector
    module.subprocess.Popen = capture_popen
    try:
        try:
            module.run_child(
                context,
                [sys.executable, "-I", "-c", "import time; time.sleep(30)"],
            )
        except module.Refusal as exc:
            if exc.token != "E_IO":
                raise FixtureError(f"unexpected child setup refusal: {exc.token}") from exc
        else:
            raise FixtureError("child setup fault was accepted")
    finally:
        module.selectors.DefaultSelector = selector_factory
        module.subprocess.Popen = popen_factory
    if len(children) != 1 or children[0].poll() is None:
        raise FixtureError("spawned child was not reaped after setup failure")


def command_child_streaming(args: argparse.Namespace) -> None:
    module = load_component(args.component)
    children: list[subprocess.Popen[bytes]] = []
    popen_factory = module.subprocess.Popen

    def capture_popen(*call_args: Any, **call_kwargs: Any) -> subprocess.Popen[bytes]:
        child = popen_factory(*call_args, **call_kwargs)
        children.append(child)
        return child

    context = module.Context(
        args=types.SimpleNamespace(), repo_root=Path("/"), scratch=Path("/"),
        copied_repo=Path("/"), sidecars=Path("/"), deps_root=Path("/"),
        ledger=module.Ledger(), deadline=time.monotonic() + 10, boundaries={},
    )
    digest = hashlib.sha256()
    payload_size = module.LIMITS["chunk_bytes"] * 4 + 17
    script = (
        "import os,sys\n"
        f"data=b'x'*{payload_size}\n"
        "for at in range(0,len(data),4093):\n"
        " os.write(1,data[at:at+4093]); os.write(2,b'e')\n"
    )
    output = module.run_child(
        context, [sys.executable, "-I", "-c", script], output_limit=payload_size,
        stdout_consumer=digest.update,
    )
    if output or digest.hexdigest() != hashlib.sha256(b"x" * payload_size).hexdigest() or \
            context.ledger.high_water_chunk > module.LIMITS["chunk_bytes"]:
        raise FixtureError("streaming child output was buffered or changed")
    diagnostic_limit = module.LIMITS["child_diagnostic_bytes"]
    diagnostic_script = f"import os;os.write(2,b'e'*{diagnostic_limit})"
    module.run_child(context, [sys.executable, "-I", "-c", diagnostic_script], output_limit=0)
    overflow_script = f"import os;os.write(2,b'e'*{diagnostic_limit + 1})"
    try:
        module.run_child(context, [sys.executable, "-I", "-c", overflow_script], output_limit=0)
    except module.Refusal as exc:
        if exc.token != "E_LIMIT":
            raise FixtureError(f"unexpected diagnostic overflow refusal: {exc.token}") from exc
    else:
        raise FixtureError("diagnostic overflow was accepted")
    aggregate_script = "import os;os.write(2,b'e'*4)"
    for aggregate_limit, expected in ((8, None), (7, "E_LIMIT")):
        aggregate_context = dataclasses.replace(context, ledger=module.Ledger())
        old_invocation_limit = module.LIMITS["invocation_diagnostic_bytes"]
        module.LIMITS["invocation_diagnostic_bytes"] = aggregate_limit
        try:
            module.run_child(aggregate_context, [sys.executable, "-I", "-c", aggregate_script], output_limit=0)
            try:
                module.run_child(aggregate_context, [sys.executable, "-I", "-c", aggregate_script], output_limit=0)
            except module.Refusal as exc:
                if exc.token != expected:
                    raise FixtureError(f"unexpected aggregate diagnostic refusal: {exc.token}") from exc
            else:
                if expected is not None:
                    raise FixtureError("aggregate diagnostic overflow was accepted")
        finally:
            module.LIMITS["invocation_diagnostic_bytes"] = old_invocation_limit
    try:
        module.run_child(
            context, [sys.executable, "-I", "-c", f"import os;os.write(1,b'x'*{payload_size})"],
            output_limit=payload_size - 1, stdout_consumer=lambda _block: None,
        )
    except module.Refusal as exc:
        if exc.token != "E_LIMIT":
            raise FixtureError(f"unexpected stdout overflow refusal: {exc.token}") from exc
    else:
        raise FixtureError("stdout overflow was accepted")
    module.subprocess.Popen = capture_popen
    old_child_seconds = module.LIMITS["child_seconds"]
    module.LIMITS["child_seconds"] = 0.05
    context.deadline = time.monotonic() + 2
    try:
        try:
            module.run_child(context, [sys.executable, "-I", "-c", "import time;time.sleep(30)"])
        except module.Refusal as exc:
            if exc.token != "E_TIMEOUT":
                raise FixtureError(f"unexpected timeout refusal: {exc.token}") from exc
        else:
            raise FixtureError("child deadline was accepted")
    finally:
        module.LIMITS["child_seconds"] = old_child_seconds
        module.subprocess.Popen = popen_factory
    if len(children) != 1 or children[0].poll() is None:
        raise FixtureError("deadline child was not reaped")


def command_raw_probes(args: argparse.Namespace) -> None:
    module = load_component(args.component)
    oid = lambda number: f"{number:040x}"
    raw = lambda mode, name, number: mode + b" " + name + b"\0" + bytes.fromhex(oid(number))
    context = module.Context(
        args=types.SimpleNamespace(), repo_root=Path("/"), scratch=Path("/"), copied_repo=Path("/"),
        sidecars=Path("/"), deps_root=Path("/"), ledger=module.Ledger(),
        deadline=time.monotonic() + 10, algorithm="sha1", oid_bytes=20,
    )

    def refused(token: str, operation: Any) -> None:
        try:
            operation()
        except module.Refusal as exc:
            if exc.token != token:
                raise FixtureError(f"raw probe returned {exc.token}, expected {token}") from exc
        else:
            raise FixtureError(f"raw probe accepted, expected {token}")

    malformed = [
        raw(b"100644", b"a", 1)[:-1],
        raw(b"100644", b"b", 1) + raw(b"100644", b"a", 1),
        raw(b"100644", b"a", 1) * 2,
        raw(b"120000", b"a", 1), raw(b"160000", b"a", 1),
        raw(b"100644", b"", 1), raw(b"100644", b".git", 1),
        raw(b"100644", b"bad\\name", 1), raw(b"100644", b"bad/name", 1),
        raw(b"100644", b"bad.", 1), raw(b"100644", b"bad\x01", 1),
        raw(b"100644", b"\xff", 1), raw(b"100644", b"a" * 256, 1),
    ]
    for body in malformed:
        refused("E_OBJECT" if body in malformed[:5] else "E_PATH",
                lambda body=body: module.parse_tree_bytes(context, body))

    bodies = {
        oid(1): raw(b"40000", b"dir", 2) + raw(b"100644", b"dir/a", 3),
        oid(2): raw(b"100644", b"a", 4),
    }
    original = module.git_object
    module.git_object = lambda _ctx, object_id, kind, _maximum: bodies[object_id]
    try:
        refused("E_PATH", lambda: module.walk_tree(context, oid(1)))
        bodies[oid(1)] = raw(b"100644", "e\u0301".encode(), 3) + raw(b"100644", "é".encode(), 4)
        refused("E_PATH", lambda: module.walk_tree(context, oid(1)))
        bodies[oid(1)] = raw(b"40000", b"a", 2)
        bodies[oid(2)] = raw(b"40000", b"b", 1)
        for name, value in (("tree_visits", 1), ("tree_entries", 0),
                            ("tree_bytes_visited", 1), ("export_path_bytes", 0),
                            ("directories", 0)):
            old = module.LIMITS[name]
            module.LIMITS[name] = value
            refused("E_LIMIT", lambda: module.walk_tree(context, oid(1)))
            module.LIMITS[name] = old
        refused("E_PATH", lambda: module.walk_tree(context, oid(1)))
        bodies[oid(2)] = b""
        refused("E_OBJECT", lambda: module.walk_tree(context, oid(1)))
    finally:
        module.git_object = original


def command_fault_probes(args: argparse.Namespace) -> None:
    module = load_component(args.component)
    args.root.mkdir(mode=0o700)
    original_read, original_write = module.os.read, module.os.write
    original_rename, original_fsync = module.os.rename, module.os.fsync
    read_source = args.root / "read"
    read_source.write_bytes(b"0123456789")
    read_source.chmod(0o400)
    read_calls = 0

    def failed_read(fd: int, count: int) -> bytes:
        nonlocal read_calls
        read_calls += 1
        if read_calls == 1:
            return original_read(fd, min(count, 2))
        raise OSError(5, "fixture read failure")

    module.os.read = failed_read
    try:
        try:
            module.read_limited(read_source, 10)
        except module.Refusal as exc:
            if exc.token != "E_IO" or read_calls != 2:
                raise FixtureError("partial read failure returned the wrong result") from exc
        else:
            raise FixtureError("partial read failure was accepted")
    finally:
        module.os.read = original_read
    if read_source.read_bytes() != b"0123456789":
        raise FixtureError("partial read failure changed its source")

    partial = args.root / "partial"

    def partial_write(fd: int, data: bytes) -> int:
        original_write(fd, data[:max(1, len(data) // 2)])
        raise OSError(5, "fixture partial write")

    module.os.write = partial_write
    try:
        try:
            module.write_exclusive(partial, b"0123456789", 0o400)
        except module.Refusal as exc:
            if exc.token != "E_IO" or partial.stat().st_size >= 10:
                raise FixtureError("partial write did not retain a bounded failed file") from exc
        else:
            raise FixtureError("partial write was accepted")
    finally:
        module.os.write = original_write

    read_fd, write_fd = os.pipe(); saved_stdout = os.dup(sys.stdout.fileno())
    try:
        os.dup2(write_fd, sys.stdout.fileno()); os.close(write_fd)
        module.os.write = lambda fd, data: original_write(fd, data[:2])
        module.emit_result(b"short-write\n")
        os.dup2(saved_stdout, sys.stdout.fileno()); os.close(saved_stdout); saved_stdout = -1
        if os.read(read_fd, 64) != b"short-write\n":
            raise FixtureError("short outward writes changed the envelope")
    finally:
        module.os.write = original_write
        if saved_stdout >= 0:
            os.dup2(saved_stdout, sys.stdout.fileno()); os.close(saved_stdout)
        os.close(read_fd)

    bundle = args.root / "rename"; bundle.mkdir(mode=0o700)
    module.os.rename = lambda *_args, **_kwargs: (_ for _ in ()).throw(OSError(5, "fixture rename"))
    try:
        try:
            module.publish_record(bundle, b"record\n")
        except module.Refusal as exc:
            if exc.token != "E_IO" or not (bundle / ".record.json.preparing").is_file() or \
                    (bundle / "record.json").exists():
                raise FixtureError("rename failure state is wrong") from exc
        else:
            raise FixtureError("rename failure was accepted")
    finally:
        module.os.rename = original_rename

    output = args.root / "nested"; output.mkdir(mode=0o700)
    boundary = module.hold_boundary(output, "directory", time.monotonic() + 10, private_leaf=True)
    context = module.Context(args=types.SimpleNamespace(), repo_root=Path("/"), scratch=output,
        copied_repo=output, sidecars=output, deps_root=output, ledger=module.Ledger(),
        deadline=time.monotonic() + 10, algorithm="sha1", oid_bytes=20, boundaries={"output": boundary})
    oid = git_hash("sha1", "blob", b"x")
    original_git, original_object = module.git, module.git_object
    saw_directory = False

    def fail_directory(fd: int) -> None:
        nonlocal saw_directory
        if stat.S_ISDIR(os.fstat(fd).st_mode):
            saw_directory = True
            raise OSError(5, "fixture nested directory fsync")
        original_fsync(fd)

    module.git = lambda *_args, **_kwargs: b"1\n"
    module.git_object = lambda _ctx, _oid, _kind, _maximum, sink=-1: original_write(sink, b"x") or b""
    module.os.fsync = fail_directory
    try:
        try:
            module.export_candidate(context, output / "candidate",
                [{"path": "nested", "kind": "directory", "git_mode": "040000", "mode": "0500"}],
                {"nested/file": ("100644", oid)})
        except (module.Refusal, OSError) as exc:
            if (isinstance(exc, module.Refusal) and exc.token != "E_IO") or not saw_directory:
                raise FixtureError("nested directory fsync was not exercised") from exc
        else:
            raise FixtureError("nested directory fsync failure was accepted")
    finally:
        module.git, module.git_object, module.os.fsync = original_git, original_object, original_fsync
        boundary.close()


def command_closed_pipe(args: argparse.Namespace) -> None:
    invocation = strict_load(args.argv_json)
    if not isinstance(invocation, list) or not all(isinstance(item, str) for item in invocation):
        raise FixtureError("closed-pipe argv must be a string list")
    process = subprocess.Popen([sys.executable, "-I", str(args.component), *invocation],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert process.stdout is not None and process.stderr is not None
    process.stdout.close()
    diagnostic = process.stderr.read()
    result = process.wait(300)
    if result != 1 or diagnostic != b"E_IO\n":
        raise FixtureError(f"closed pipe returned {result}: {diagnostic!r}")


def command_accounting_probes(args: argparse.Namespace) -> None:
    module = load_component(args.component)
    invocation = strict_load(args.argv_json)
    if not isinstance(invocation, list) or not all(isinstance(item, str) for item in invocation):
        raise FixtureError("accounting argv must be a string list")
    original = module.copy_storage
    observed = False

    def checked_copy(context: Any) -> None:
        nonlocal observed
        before = context.ledger.scratch_bytes
        charges: list[int] = []
        original_charge = context.ledger.charge

        def tracked_charge(field: str, amount: int, maximum: int) -> None:
            if field == "scratch_bytes":
                charges.append(amount)
            original_charge(field, amount, maximum)

        context.ledger.charge = tracked_charge
        try:
            original(context)
        finally:
            context.ledger.charge = original_charge
        copied = [fact for name, fact in context.source_facts.items()
                  if name.endswith((".rev", ".pack", ".idx")) or
                  name.startswith("objects/") and name not in ("objects/info", "objects/pack")]
        sidecars = [fact for name, fact in context.source_facts.items() if name.endswith(".rev")]
        unmatched = list(charges)
        for fact in copied:
            if fact.size not in unmatched:
                raise FixtureError("copied storage lacked its scratch charge")
            unmatched.remove(fact.size)
        if not sidecars or context.ledger.scratch_bytes - before != sum(charges):
            raise FixtureError("copied storage was not charged exactly")
        if list(context.copied_repo.rglob("*.rev")) or not list(context.sidecars.glob("*.rev")):
            raise FixtureError("sidecar crossed the private Git-reading boundary")
        observed = True

    module.copy_storage = checked_copy
    try:
        result = module.main(invocation)
    finally:
        module.copy_storage = original
    if not observed:
        raise FixtureError("storage accounting probe was not reached")
    if result is not None:
        raise SystemExit(result)


def command_limit_invoke(args: argparse.Namespace) -> None:
    module = load_component(args.component)
    if args.name not in module.LIMITS or args.value < 0:
        raise FixtureError("unknown or invalid production limit")
    module.LIMITS[args.name] = args.value
    invocation = strict_load(args.argv_json)
    if not isinstance(invocation, list) or not all(isinstance(item, str) for item in invocation):
        raise FixtureError("limit invocation must be a JSON string list")
    result = module.main(invocation)
    if result is not None:
        raise SystemExit(result)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(allow_abbrev=False)
    commands = result.add_subparsers(dest="command", required=True)

    oracle_parser = commands.add_parser("oracle", allow_abbrev=False)
    oracle_parser.add_argument("action", choices=("build", "check"))
    oracle_parser.add_argument("--description", required=True, type=Path)
    oracle_parser.add_argument("--root", required=True, type=Path)
    oracle_parser.add_argument("--algorithm", required=True, choices=("sha1", "sha256"))
    oracle_parser.add_argument("--manifest", type=Path)
    oracle_parser.add_argument("--root-mode", choices=("0500", "0700"))
    oracle_parser.set_defaults(run=command_oracle)

    snapshot_parser = commands.add_parser("snapshot", allow_abbrev=False)
    snapshot_parser.add_argument("action", choices=("create", "check"))
    snapshot_parser.add_argument("--path", required=True, type=Path)
    snapshot_parser.add_argument("--snapshot", required=True, type=Path)
    snapshot_parser.set_defaults(run=command_snapshot)

    object_parser = commands.add_parser("object", allow_abbrev=False)
    object_parser.add_argument("--repository", required=True, type=Path)
    object_parser.add_argument("--algorithm", required=True, choices=("sha1", "sha256"))
    object_parser.add_argument("--type", required=True, choices=("blob", "tree", "commit"))
    object_parser.add_argument("--body", required=True, type=Path)
    object_parser.add_argument("--oid-file", type=Path)
    object_parser.set_defaults(run=command_object)

    tree_parser = commands.add_parser("tree-body", allow_abbrev=False)
    tree_parser.add_argument("--algorithm", required=True, choices=("sha1", "sha256"))
    tree_parser.add_argument("--entries", required=True, type=Path)
    tree_parser.add_argument("--output", required=True, type=Path)
    tree_parser.set_defaults(run=command_tree)

    reverse_parser = commands.add_parser("reverse-index", allow_abbrev=False)
    reverse_parser.add_argument("action", choices=("make", "mutate"))
    reverse_parser.add_argument("--algorithm", required=True, choices=("sha1", "sha256"))
    reverse_parser.add_argument("--output", required=True, type=Path)
    reverse_parser.add_argument("--index", type=Path)
    reverse_parser.add_argument("--pack", type=Path)
    reverse_parser.add_argument("--input", type=Path)
    reverse_parser.add_argument(
        "--case",
        choices=(
            "signature", "version", "hash-id", "duplicate-position",
            "swap-positions",
            "out-of-range-position", "pack-checksum", "reverse-checksum",
            "truncate", "trailing",
        ),
    )
    reverse_parser.add_argument("--rehash", action="store_true")
    reverse_parser.set_defaults(run=command_reverse)

    json_parser = commands.add_parser("json-case", allow_abbrev=False)
    json_parser.add_argument("--input", required=True, type=Path)
    json_parser.add_argument("--output", required=True, type=Path)
    json_parser.add_argument(
        "--case",
        required=True,
        choices=(
            "bom", "trailing", "duplicate-member", "lone-surrogate",
            "nonfinite", "depth-33", "invalid-utf8",
        ),
    )
    json_parser.set_defaults(run=command_json)

    relation_parser = commands.add_parser("relation-case", allow_abbrev=False)
    relation_parser.add_argument("--input", required=True, type=Path)
    relation_parser.add_argument("--output", required=True, type=Path)
    relation_parser.add_argument("--case", required=True, choices=(
        "request-ref", "candidate-commit", "parent-commit", "attempt-number",
        "receipt-extra", "response-authority", "profile-ref", "source-repository",
        "outcome", "fake-receipt", "numeric-shape", "nested-shape",
    ))
    relation_parser.set_defaults(run=command_relation)

    canonical_parser = commands.add_parser("canonical", allow_abbrev=False)
    canonical_parser.add_argument("--input", required=True, type=Path)
    canonical_parser.add_argument("--output", type=Path)
    canonical_parser.set_defaults(run=command_canonical)

    limits_parser = commands.add_parser("limits", allow_abbrev=False)
    limits_parser.add_argument("--name", choices=tuple(LIMITS))
    limits_parser.set_defaults(run=command_limits)

    inject_parser = commands.add_parser("inject", allow_abbrev=False)
    inject_parser.add_argument("--component", required=True, type=Path)
    inject_parser.add_argument(
        "--target",
        required=True,
        choices=(
            "write_exclusive", "fsync_file", "publish_record", "fsync_dir",
            "emit_result", "read_limited", "load_identity_inputs", "copy_storage",
            "export_candidate", "measure_candidate", "recheck_source", "read_output_file",
        ),
    )
    inject_parser.add_argument(
        "--mode",
        required=True,
        choices=("before-error", "after-error", "before-pause", "after-pause"),
    )
    inject_parser.add_argument("--occurrence", type=int, default=1)
    inject_parser.add_argument("--ready", type=Path)
    inject_parser.add_argument("--release", type=Path)
    inject_parser.add_argument("--wait-seconds", type=float, default=30.0)
    inject_parser.add_argument("--argv-json", required=True, type=Path)
    inject_parser.set_defaults(run=command_inject)

    cleanup_parser = commands.add_parser("child-setup-cleanup", allow_abbrev=False)
    cleanup_parser.add_argument("--component", required=True, type=Path)
    cleanup_parser.set_defaults(run=command_child_setup_cleanup)

    streaming_parser = commands.add_parser("child-streaming", allow_abbrev=False)
    streaming_parser.add_argument("--component", required=True, type=Path)
    streaming_parser.set_defaults(run=command_child_streaming)

    raw_parser = commands.add_parser("raw-probes", allow_abbrev=False)
    raw_parser.add_argument("--component", required=True, type=Path)
    raw_parser.set_defaults(run=command_raw_probes)

    fault_parser = commands.add_parser("fault-probes", allow_abbrev=False)
    fault_parser.add_argument("--component", required=True, type=Path)
    fault_parser.add_argument("--root", required=True, type=Path)
    fault_parser.set_defaults(run=command_fault_probes)

    pipe_parser = commands.add_parser("closed-pipe", allow_abbrev=False)
    pipe_parser.add_argument("--component", required=True, type=Path)
    pipe_parser.add_argument("--argv-json", required=True, type=Path)
    pipe_parser.set_defaults(run=command_closed_pipe)

    accounting_parser = commands.add_parser("accounting-probes", allow_abbrev=False)
    accounting_parser.add_argument("--component", required=True, type=Path)
    accounting_parser.add_argument("--argv-json", required=True, type=Path)
    accounting_parser.set_defaults(run=command_accounting_probes)

    limit_parser = commands.add_parser("limit-invoke", allow_abbrev=False)
    limit_parser.add_argument("--component", required=True, type=Path)
    limit_parser.add_argument("--name", required=True, choices=tuple(LIMITS))
    limit_parser.add_argument("--value", required=True, type=int)
    limit_parser.add_argument("--argv-json", required=True, type=Path)
    limit_parser.set_defaults(run=command_limit_invoke)
    return result


def validate_reverse_args(args: argparse.Namespace) -> None:
    if args.command != "reverse-index":
        return
    if args.action == "make":
        if (
            args.index is None
            or args.pack is None
            or args.input is not None
            or args.case is not None
            or args.rehash
        ):
            raise FixtureError("reverse-index make requires only --index and --pack inputs")
    elif args.input is None or args.case is None or args.index is not None or args.pack is not None:
        raise FixtureError("reverse-index mutate requires only --input and --case inputs")


def main() -> int:
    try:
        args = parser().parse_args()
        if getattr(args, "occurrence", 1) < 1:
            raise FixtureError("occurrence must be positive")
        if getattr(args, "wait_seconds", 1.0) <= 0:
            raise FixtureError("wait-seconds must be positive")
        validate_reverse_args(args)
        args.run(args)
        return 0
    except (FixtureError, KeyError, OSError) as exc:
        print(f"fixture-error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
